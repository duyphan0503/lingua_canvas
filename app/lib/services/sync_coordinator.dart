import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/lesson_item.dart';
import 'fsrs_engine.dart';
import 'local_database.dart';

class SyncResult {
  final bool success;
  final int syncedReviews;
  final int syncedLessons;
  final int pulledCards;
  final int pulledLessons;
  final String? error;

  SyncResult({
    required this.success,
    this.syncedReviews = 0,
    this.syncedLessons = 0,
    this.pulledCards = 0,
    this.pulledLessons = 0,
    this.error,
  });

  @override
  String toString() {
    return 'SyncResult(success: $success, syncedReviews: $syncedReviews, '
        'syncedLessons: $syncedLessons, pulledCards: $pulledCards, '
        'pulledLessons: $pulledLessons, error: $error)';
  }
}

class SyncCoordinator {
  final LocalDatabase localDb;
  final FSRSEngine fsrsEngine;
  final http.Client httpClient;
  final String baseUrl;
  final String? clientId;

  DateTime? lastSyncTime;
  Future<SyncResult>? _syncInFlight;

  SyncCoordinator({
    LocalDatabase? localDb,
    FSRSEngine? fsrsEngine,
    http.Client? httpClient,
    this.baseUrl = 'http://127.0.0.1:8080/api/v1',
    this.clientId,
  }) : localDb = localDb ?? LocalDatabase.instance,
       fsrsEngine = fsrsEngine ?? FSRSEngine(),
       httpClient = httpClient ?? http.Client();

  /// Performs offline review computation with FSRSEngine,
  /// saves the resulting card into SQLite, appends to review logs,
  /// updates completed lessons, and enqueues a sync mutation atomically.
  Future<FSRSCard> reviewCardOffline({
    required String itemId,
    required FSRSRating rating,
    DateTime? reviewTime,
    double completionScore = 1.0,
  }) async {
    final time = reviewTime ?? DateTime.now().toUtc();
    final existingCard = await localDb.getCard(itemId);
    final card = existingCard ?? FSRSCard.initial(itemId);

    final updatedCard = fsrsEngine.review(card, rating, time);

    final elapsedDays =
        time
            .difference(card.lastReview)
            .inSeconds
            .clamp(0, double.maxFinite.toInt()) /
        86400.0;
    final scheduledDays =
        (updatedCard.nextReview.difference(time).inSeconds / 86400.0).round();

    await localDb.recordReviewTransaction(
      updatedCard: updatedCard,
      rating: rating,
      reviewTime: time,
      elapsedDays: elapsedDays,
      scheduledDays: scheduledDays,
      completionScore: completionScore,
    );

    return updatedCard;
  }

  /// Bidirectional synchronization with the Axum server:
  /// 1. Flushes pending sync mutations to `POST /api/v1/sync`
  /// 2. Pulls delta updates from `GET /api/v1/sync/pull`
  /// 3. Resolves conflicts using Last-Write-Wins (LWW) based on `last_review`
  Future<SyncResult> synchronize() => _syncInFlight ??= _runSync();

  Future<SyncResult> _runSync() async {
    try {
      return await _performSync();
    } finally {
      _syncInFlight = null;
    }
  }

  Future<SyncResult> _performSync() async {
    await localDb.recoverInterruptedMutations();
    lastSyncTime ??= await localDb.getLastPullTime();
    final pullSince = lastSyncTime;
    int syncedReviewsCount = 0;
    int syncedLessonsCount = 0;
    int pulledCardsCount = 0;
    int pulledLessonsCount = 0;

    // -------------------------------------------------------------
    // Phase 1: Push pending local mutations to backend
    // -------------------------------------------------------------
    final pendingMutations = await localDb.getPendingMutations(limit: 50);

    if (pendingMutations.isNotEmpty) {
      final mutationIds = pendingMutations.map((m) => m.id).toList();
      await localDb.markMutationsInProgress(mutationIds);

      final List<Map<String, dynamic>> reviewsPayload = [];
      final List<Map<String, dynamic>> completedLessonsPayload = [];
      final List<String> reviewLogIds = [];
      final List<String> lessonIds = [];

      for (final mutation in pendingMutations) {
        final p = mutation.payload;
        if (mutation.mutationType == 'review') {
          final reviewId = p['review_id'] as String? ?? 'rev_${mutation.id}';
          reviewLogIds.add(reviewId);
          final itemId = p['item_id'] as String;
          lessonIds.add(itemId);

          reviewsPayload.add({
            'review_id': reviewId,
            'item_id': itemId,
            'rating': p['rating'],
            'state': p['state'],
            'review_time': p['review_time'],
            'elapsed_days': p['elapsed_days'],
            'scheduled_days': p['scheduled_days'],
            if (p['client_card_snapshot'] != null)
              'client_card_snapshot': p['client_card_snapshot'],
          });

          completedLessonsPayload.add({
            'lesson_id': itemId,
            'completed_at': p['review_time'],
            'score': p['completion_score'] ?? 1.0,
          });
        }
      }

      final pushBody = jsonEncode({
        'client_id': clientId ?? await localDb.getOrCreateClientId(),
        if (lastSyncTime != null)
          'last_sync_time': lastSyncTime!.toIso8601String(),
        'reviews': reviewsPayload,
        'completed_lessons': completedLessonsPayload,
      });

      try {
        final pushUri = Uri.parse('$baseUrl/sync');
        final response = await httpClient
            .post(
              pushUri,
              headers: {'Content-Type': 'application/json'},
              body: pushBody,
            )
            .timeout(const Duration(seconds: 4));

        if (response.statusCode == 200) {
          final Map<String, dynamic> data = jsonDecode(response.body);

          syncedReviewsCount =
              (data['synced_reviews'] as num?)?.toInt() ??
              reviewsPayload.length;
          syncedLessonsCount =
              (data['synced_lessons'] as num?)?.toInt() ??
              completedLessonsPayload.length;

          // Process returned updated cards using LWW
          final updatedCardsRaw = data['updated_cards'] as List<dynamic>? ?? [];
          for (final cardJson in updatedCardsRaw) {
            await _reconcileCardWithLww(cardJson as Map<String, dynamic>);
          }
          await localDb.markReviewLogsSynced(reviewLogIds);
          await localDb.markCompletedLessonsSynced(lessonIds);
          await localDb.deleteMutations(mutationIds);
        } else {
          await localDb.resetFailedMutations(mutationIds);
          return SyncResult(
            success: false,
            error:
                'Server returned HTTP ${response.statusCode}: ${response.body}',
          );
        }
      } catch (e) {
        await localDb.resetFailedMutations(mutationIds);
        return SyncResult(success: false, error: e.toString());
      }
    }

    // -------------------------------------------------------------
    // Phase 2: Pull updates from backend (Delta Pull)
    // -------------------------------------------------------------
    try {
      final pullParams = <String, String>{};
      if (pullSince != null) {
        pullParams['since'] = pullSince.toIso8601String();
      }
      final pullUri = Uri.parse(
        '$baseUrl/sync/pull',
      ).replace(queryParameters: pullParams.isNotEmpty ? pullParams : null);

      final pullResponse = await httpClient
          .get(pullUri)
          .timeout(const Duration(seconds: 4));

      if (pullResponse.statusCode == 200) {
        final Map<String, dynamic> pullData = jsonDecode(pullResponse.body);

        final cardsList =
            (pullData['cards'] ?? pullData['updated_cards'])
                as List<dynamic>? ??
            [];
        for (final cardJson in cardsList) {
          final applied = await _reconcileCardWithLww(
            cardJson as Map<String, dynamic>,
          );
          if (applied) pulledCardsCount++;
        }

        final lessonsList =
            (pullData['lessons'] ?? pullData['new_lessons'])
                as List<dynamic>? ??
            [];
        final List<LessonItem> lessonsToSave = [];
        for (final lessonJson in lessonsList) {
          lessonsToSave.add(
            LessonItem.fromJson(lessonJson as Map<String, dynamic>),
          );
        }
        if (lessonsToSave.isNotEmpty) {
          await localDb.saveLessons(lessonsToSave);
          pulledLessonsCount = lessonsToSave.length;
        }

        final serverTime = pullData['server_time'] ?? pullData['timestamp'];
        if (serverTime != null) {
          final pulledAt = DateTime.parse(serverTime as String).toUtc();
          await localDb.setLastPullTime(pulledAt);
          lastSyncTime = pulledAt;
        }
      } else {
        return SyncResult(
          success: false,
          syncedReviews: syncedReviewsCount,
          syncedLessons: syncedLessonsCount,
          error:
              'Pull failed with HTTP ${pullResponse.statusCode}: ${pullResponse.body}',
        );
      }
    } catch (e) {
      return SyncResult(
        success: false,
        syncedReviews: syncedReviewsCount,
        syncedLessons: syncedLessonsCount,
        error: e.toString(),
      );
    }

    return SyncResult(
      success: true,
      syncedReviews: syncedReviewsCount,
      syncedLessons: syncedLessonsCount,
      pulledCards: pulledCardsCount,
      pulledLessons: pulledLessonsCount,
    );
  }

  /// Reconciles a card from the server with local card using Last-Write-Wins (LWW).
  /// If server card is newer or local card doesn't exist, overwrites local card.
  /// If local card has a newer review timestamp, retains local card.
  Future<bool> _reconcileCardWithLww(Map<String, dynamic> json) async {
    final itemId = (json['item_id'] ?? json['itemId']) as String;
    final serverLastReview = DateTime.parse(
      (json['last_review'] ?? json['lastReview']) as String,
    );

    final pending = await localDb.getPendingMutations();
    if (pending.any(
      (mutation) =>
          mutation.mutationType == 'review' &&
          mutation.payload['item_id'] == itemId,
    )) {
      return false;
    }

    final localCard = await localDb.getCard(itemId);
    if (localCard == null || serverLastReview.isAfter(localCard.lastReview)) {
      final stateVal = json['state'];
      FSRSState state;
      if (stateVal is int) {
        state =
            FSRSState.values[stateVal.clamp(0, FSRSState.values.length - 1)];
      } else if (stateVal is String) {
        switch (stateVal.toLowerCase()) {
          case 'learning':
            state = FSRSState.learning;
            break;
          case 'review':
            state = FSRSState.review;
            break;
          case 'relearning':
            state = FSRSState.relearning;
            break;
          default:
            state = FSRSState.newCard;
        }
      } else {
        state = FSRSState.newCard;
      }

      final updatedCard = FSRSCard(
        itemId: itemId,
        state: state,
        stability: (json['stability'] as num).toDouble(),
        difficulty: (json['difficulty'] as num).toDouble(),
        reps: (json['reps'] as num).toInt(),
        lapses: (json['lapses'] as num).toInt(),
        lastReview: serverLastReview,
        nextReview: DateTime.parse(
          (json['next_review'] ?? json['nextReview']) as String,
        ),
      );

      await localDb.saveCard(updatedCard);
      return true;
    }

    // Local card has newer timestamp -> keep local card
    return false;
  }
}
