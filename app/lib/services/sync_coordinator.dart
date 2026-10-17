import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/lesson_item.dart';
import '../models/private_lesson_state.dart';
import 'fsrs_engine.dart';
import 'local_database.dart';
import 'storage/local_store.dart';

class SyncResult {
  final bool success;
  final bool upgradeRequired;
  final int conflicts;
  final int syncedReviews;
  final int syncedLessons;
  final int pulledCards;
  final int pulledLessons;
  final String? error;

  SyncResult({
    required this.success,
    this.upgradeRequired = false,
    this.conflicts = 0,
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
  final LocalStore localDb;
  final FSRSEngine fsrsEngine;
  final http.Client httpClient;
  final String baseUrl;
  final String? clientId;

  DateTime? lastSyncTime;
  Future<SyncResult>? _syncInFlight;

  SyncCoordinator({
    LocalStore? localDb,
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
    return localDb.withProfileLock(() async {
      if ((await localDb.getPrivateLesson(itemId))?.deleted == true) {
        throw StateError(
          'Từ đã chuyển vào thùng rác. Hãy khôi phục để học tiếp.',
        );
      }
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
    });
  }

  Future<void> changeAccount(Map<String, dynamic>? account) =>
      localDb.withProfileLock(() async {
        await localDb.switchAccount(account);
        lastSyncTime = null;
      });

  /// Bidirectional synchronization with the Axum server:
  /// 1. Flushes pending sync mutations to `POST /api/v1/sync`
  /// 2. Pulls delta updates from `GET /api/v1/sync/pull`
  /// 3. Resolves conflicts using Last-Write-Wins (LWW) based on `last_review`
  Future<SyncResult> synchronize() => _syncInFlight ??= _runSync();

  Future<SyncResult> _runSync() async {
    try {
      return await localDb.withProfileLock(_performSync);
    } finally {
      _syncInFlight = null;
    }
  }

  Future<SyncResult> _performSync() async {
    final account = await localDb.getAccount();
    if (account != null && account['server_url'] != baseUrl) {
      return SyncResult(
        success: false,
        error: 'Hồ sơ thuộc máy chủ khác. Hãy liên kết lại tài khoản.',
      );
    }
    final headers = <String, String>{
      if (account != null) 'X-Sync-Token': account['sync_token'] as String,
    };
    final sequence = await localDb.getSyncSequence();
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
    bool upgradeRequired = false;
    String? queueError;
    final attempted = <int>{};
    while (true) {
      final allPending = await localDb.getPendingMutations();
      final pending = allPending
          .where((q) => !attempted.contains(q.id))
          .toList();
      final firstMetadata = <String, int>{};
      for (final q in allPending.where(
        (q) => q.mutationType == 'custom_lesson',
      )) {
        firstMetadata.putIfAbsent(
          (q.payload['lesson'] as Map)['id'] as String,
          () => q.id,
        );
      }
      if (pending.isEmpty) break;
      final privateStates = {
        for (final s in await localDb.getPrivateLessons(includeDeleted: true))
          s.lesson.id: s,
      };
      final custom = <Map<String, dynamic>>[];
      final imports = <Map<String, dynamic>>[];
      final reviews = <Map<String, dynamic>>[];
      final completed = <Map<String, dynamic>>[];
      final batch = <SyncQueueItem>[];
      final bodyBase = <String, dynamic>{
        'client_id': clientId ?? await localDb.getOrCreateClientId(),
        if (account != null) 'user_id': account['user_id'],
        'since_seq': ?sequence,
        if (lastSyncTime != null)
          'last_sync_time': lastSyncTime!.toIso8601String(),
      };
      Map<String, dynamic> body() => {
        ...bodyBase,
        'reviews': reviews,
        'completed_lessons': completed,
        if (custom.isNotEmpty) 'custom_lesson_mutations': custom,
        if (imports.isNotEmpty) 'progress_imports': imports,
      };
      bool blocked(String id) => privateStates[id]?.conflict != null;
      // A word has at most one metadata mutation in a request. Descendants wait
      // until its ACK establishes the next base revision.
      final words = <String>{};
      for (final q in pending) {
        if (batch.length >= 50) break;
        final p = q.payload;
        var target = '';
        switch (q.mutationType) {
          case 'custom_lesson':
            target = (p['lesson'] as Map)['id'] as String;
            if (account == null || blocked(target)) {
              attempted.add(q.id);
              continue;
            }
            if (firstMetadata[target] != q.id) {
              // The oldest identity is either in this batch or remains unACKed.
              // Only defer until the next iteration when this batch sends it.
              if (!words.contains(target)) attempted.add(q.id);
              continue;
            }
            words.add(target);
            custom.add({
              for (final k in [
                'mutation_id',
                'base_revision',
                'lesson',
                'deleted',
              ])
                k: p[k],
            });
          case 'progress_import':
            final ids = [
              ...(p['cards'] as List? ?? []).map((c) => c['item_id'] as String),
              ...(p['completed_lessons'] as List? ?? []).map(
                (c) => c['lesson_id'] as String,
              ),
            ];
            if (account == null || ids.any(blocked)) {
              attempted.add(q.id);
              continue;
            }
            imports.add({
              for (final k in ['mutation_id', 'cards', 'completed_lessons'])
                k: p[k],
            });
          case 'review':
            target = p['item_id'] as String;
            if (blocked(target)) {
              attempted.add(q.id);
              continue;
            }
            reviews.add({
              'review_id': p['review_id'] as String? ?? 'rev_${q.id}',
              'item_id': target,
              'rating': p['rating'],
              'state': p['state'],
              'review_time': p['review_time'],
              'elapsed_days': p['elapsed_days'],
              'scheduled_days': p['scheduled_days'],
              if (p['client_card_snapshot'] != null)
                'client_card_snapshot': p['client_card_snapshot'],
            });
            completed.add({
              'lesson_id': target,
              'completed_at': p['review_time'],
              'score': p['completion_score'] ?? 1.0,
            });
          default:
            attempted.add(q.id);
            continue;
        }
        if (((custom.isNotEmpty || imports.isNotEmpty) &&
                (custom.length +
                        imports.length +
                        reviews.length +
                        completed.length) >
                    50) ||
            utf8.encode(jsonEncode(body())).length > 512 * 1024) {
          if (q.mutationType == 'custom_lesson') custom.removeLast();
          if (q.mutationType == 'progress_import') imports.removeLast();
          if (q.mutationType == 'review') {
            reviews.removeLast();
            completed.removeLast();
          }
          if (batch.isEmpty) {
            queueError =
                'Một mục quá lớn để đồng bộ. Hãy rút gọn nội dung rồi thử lại.';
            attempted.add(q.id);
            continue;
          }
          break;
        }
        batch.add(q);
      }
      if (batch.isEmpty) {
        if (pending.every((q) => attempted.contains(q.id))) break;
        continue;
      }
      final ids = batch.map((q) => q.id).toList();
      attempted.addAll(ids);
      await localDb.markMutationsInProgress(ids);
      try {
        final response = await _send(
          'POST',
          Uri.parse('$baseUrl/sync'),
          headers: {...headers, 'Content-Type': 'application/json'},
          body: jsonEncode(body()),
        ).timeout(const Duration(seconds: 4));
        if (response.statusCode != 200) {
          await localDb.resetFailedMutations(ids);
          return SyncResult(
            success: false,
            error:
                'Server returned HTTP ${response.statusCode}: ${response.body}',
          );
        }
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final capabilities = data['capabilities'] as Map?;
        final privateSupported = capabilities?['private_vocabulary_sync'] == 1;
        final importSupported = capabilities?['progress_import'] == 1;
        upgradeRequired |=
            (custom.isNotEmpty && !privateSupported) ||
            (imports.isNotEmpty && !importSupported);
        await localDb.setMetadata(
          'private_sync_upgrade_required',
          upgradeRequired ? '1' : '0',
        );
        final reviewIds = data.containsKey('synced_review_ids')
            ? List<String>.from(data['synced_review_ids'] as List)
            : reviews.map((r) => r['review_id'] as String).toList();
        final sentReviewIds = reviews
            .map((r) => r['review_id'] as String)
            .toSet();
        for (final raw in data['updated_cards'] as List? ?? []) {
          await _reconcileCardWithLww(
            raw as Map<String, dynamic>,
            acknowledgedReviewIds: reviewIds
                .where(sentReviewIds.contains)
                .toSet(),
          );
        }
        final acks = privateSupported
            ? (data['custom_lesson_acks'] as List? ?? [])
                  .map(
                    (r) => PrivateLessonAck.fromJson(r as Map<String, dynamic>),
                  )
                  .toList()
            : <PrivateLessonAck>[];
        final conflicts = privateSupported
            ? (data['custom_lesson_conflicts'] as List? ?? [])
                  .map(
                    (r) => PrivateLessonSyncConflict.fromJson(
                      r as Map<String, dynamic>,
                    ),
                  )
                  .toList()
            : <PrivateLessonSyncConflict>[];
        final importAcks = importSupported
            ? List<String>.from(data['progress_import_acks'] as List? ?? [])
            : <String>[];
        // Typed response acknowledgments apply only to identities in this request.
        final customIds = custom.map((r) => r['mutation_id']).toSet();
        final importIds = imports.map((r) => r['mutation_id']).toSet();
        await localDb.applyPrivateLessonSync(
          acks: acks.where((a) => customIds.contains(a.mutationId)).toList(),
          conflicts: conflicts
              .where((c) => customIds.contains(c.mutationId))
              .toList(),
          progressImportAcks: importAcks.where(importIds.contains).toList(),
        );
        final lessonIds = data.containsKey('synced_completed_lesson_ids')
            ? List<String>.from(data['synced_completed_lesson_ids'] as List)
            : completed.map((r) => r['lesson_id'] as String).toList();
        final ackedReviews = batch
            .where(
              (q) =>
                  q.mutationType == 'review' &&
                  reviewIds.contains(
                    q.payload['review_id'] as String? ?? 'rev_${q.id}',
                  ),
            )
            .toList();
        await localDb.markReviewLogsSynced(
          ackedReviews
              .map((q) => q.payload['review_id'] as String? ?? 'rev_${q.id}')
              .toList(),
        );
        await localDb.markCompletedLessonsSynced(lessonIds);
        await localDb.deleteMutations(ackedReviews.map((q) => q.id).toList());
        syncedReviewsCount += ackedReviews.length;
        syncedLessonsCount += lessonIds.length;
        // Reset only unacknowledged identities; metadata ACKs were removed atomically.
        await localDb.recoverInterruptedMutations();
        if (privateSupported &&
            custom.isNotEmpty &&
            acks.isEmpty &&
            conflicts.isEmpty) {
          queueError =
              'Máy chủ chưa xác nhận từ cá nhân. Dữ liệu vẫn đang chờ gửi.';
        }
        if (importSupported && imports.isNotEmpty && importAcks.isEmpty) {
          queueError =
              'Máy chủ chưa xác nhận tiến độ nhập. Dữ liệu vẫn đang chờ gửi.';
        }
        // Legacy review batching keeps its previous one-request pacing. Private
        // metadata can continue across bounded batches for a complete sync.
        if (custom.isEmpty &&
            imports.isEmpty &&
            !pending.any(
              (q) =>
                  q.mutationType == 'custom_lesson' ||
                  q.mutationType == 'progress_import',
            )) {
          break;
        }
      } catch (error) {
        await localDb.resetFailedMutations(ids);
        return SyncResult(success: false, error: error.toString());
      }
    }

    await localDb.setMetadata('private_sync_error', queueError ?? '');

    // -------------------------------------------------------------
    // Phase 2: Pull updates from backend (Delta Pull)
    // -------------------------------------------------------------
    try {
      final pullParams = <String, String>{
        'client_id': clientId ?? await localDb.getOrCreateClientId(),
      };
      if (sequence != null) pullParams['since_seq'] = '$sequence';
      if (account != null) pullParams['user_id'] = account['user_id'] as String;
      if (pullSince != null && sequence == null) {
        pullParams['since'] = pullSince.toIso8601String();
      }
      final pullUri = Uri.parse(
        '$baseUrl/sync/pull',
      ).replace(queryParameters: pullParams.isNotEmpty ? pullParams : null);

      final pullResponse = await _send(
        'GET',
        pullUri,
        headers: headers,
      ).timeout(const Duration(seconds: 4));

      if (pullResponse.statusCode == 200) {
        final Map<String, dynamic> pullData = jsonDecode(pullResponse.body);

        final privateDeltas = (pullData['private_lessons'] as List? ?? [])
            .map(
              (r) => PrivateLessonWireState.fromJson(r as Map<String, dynamic>),
            )
            .toList();
        if (account != null && privateDeltas.isNotEmpty) {
          await localDb.applyPrivateLessonSync(deltas: privateDeltas);
        }

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

        final localCompletions = {
          for (final completion in await localDb.getCompletedLessons())
            completion.lessonId: completion,
        };
        for (final raw
            in pullData['completed_lessons'] as List<dynamic>? ?? []) {
          final completion = raw as Map<String, dynamic>;
          final lessonId = completion['lesson_id'] as String;
          final completedAt = DateTime.parse(
            completion['completed_at'] as String,
          ).toUtc();
          final local = localCompletions[lessonId];
          if (local != null &&
              (local.synced == 0 || !completedAt.isAfter(local.completedAt))) {
            continue;
          }
          await localDb.saveCompletedLesson(
            lessonId,
            completedAt: completedAt,
            score: (completion['score'] as num?)?.toDouble() ?? 1.0,
            synced: 1,
          );
          localCompletions[lessonId] = LocalCompletedLesson(
            lessonId: lessonId,
            completedAt: completedAt,
            score: (completion['score'] as num?)?.toDouble() ?? 1.0,
            synced: 1,
          );
        }

        final latestSequence = pullData['latest_sync_seq'];
        if (latestSequence is num) {
          await localDb.setSyncSequence(latestSequence.toInt());
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
      success: queueError == null,
      upgradeRequired: upgradeRequired,
      conflicts: (await localDb.getPrivateLessons(
        includeDeleted: true,
      )).where((s) => s.conflict != null).length,
      error: queueError,
      syncedReviews: syncedReviewsCount,
      syncedLessons: syncedLessonsCount,
      pulledCards: pulledCardsCount,
      pulledLessons: pulledLessonsCount,
    );
  }

  Future<http.Response> _send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    String? body,
  }) async {
    final request = http.Request(method, uri)..followRedirects = false;
    request.headers.addAll(headers);
    if (body != null) request.body = body;
    return http.Response.fromStream(await httpClient.send(request));
  }

  /// Reconciles a card from the server with local card using Last-Write-Wins (LWW).
  /// If server card is newer or local card doesn't exist, overwrites local card.
  /// If local card has a newer review timestamp, retains local card.
  Future<bool> _reconcileCardWithLww(
    Map<String, dynamic> json, {
    Set<String> acknowledgedReviewIds = const {},
  }) async {
    final itemId = (json['item_id'] ?? json['itemId']) as String;
    final serverLastReview = DateTime.parse(
      (json['last_review'] ?? json['lastReview']) as String,
    );

    final profile = await localDb.readPrivateProfile();
    final pending = (profile['queue'] as Map).values.map(
      (r) => SyncQueueItem.fromMap(r as Map<String, dynamic>),
    );
    if (pending.any(
      (mutation) =>
          mutation.mutationType == 'review' &&
          !acknowledgedReviewIds.contains(
            mutation.payload['review_id'] as String? ?? 'rev_${mutation.id}',
          ) &&
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
