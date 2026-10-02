import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/local_database.dart';
import 'package:app/services/sync_coordinator.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late LocalDatabase localDb;

  setUp(() async {
    localDb = LocalDatabase.instance;
    await localDb.initCustom(customPath: inMemoryDatabasePath);
    await localDb.clearAll();
  });

  tearDown(() async {
    await localDb.close();
  });

  group('SyncCoordinator - Offline Review & Queuing', () {
    test(
      'reviewCardOffline calculates FSRS and commits atomic transaction',
      () async {
        final coordinator = SyncCoordinator(
          localDb: localDb,
          clientId: 'test_device_1',
        );

        final reviewTime = DateTime.parse('2026-10-01T12:00:00Z');
        final card = await coordinator.reviewCardOffline(
          itemId: 'ja_kata_bug',
          rating: FSRSRating.good,
          reviewTime: reviewTime,
          completionScore: 0.95,
        );

        // 1. Verify returned card
        expect(card.itemId, 'ja_kata_bug');
        expect(card.state, FSRSState.review);
        expect(card.reps, 1);
        expect(card.stability, closeTo(3.1262, 0.001));
        expect(card.lastReview, reviewTime);

        // 2. Verify local database card state
        final savedCard = await localDb.getCard('ja_kata_bug');
        expect(savedCard, isNotNull);
        expect(savedCard!.reps, 1);
        expect(savedCard.stability, closeTo(3.1262, 0.001));

        // 3. Verify review log
        final logs = await localDb.getReviewLogs();
        expect(logs.length, 1);
        expect(logs.first.itemId, 'ja_kata_bug');
        expect(logs.first.rating, 3);
        expect(logs.first.synced, 0);

        // 4. Verify completed lessons
        final completed = await localDb.getCompletedLessons();
        expect(completed.length, 1);
        expect(completed.first.lessonId, 'ja_kata_bug');
        expect(completed.first.score, 0.95);

        // 5. Verify sync queue
        final queue = await localDb.getPendingMutations();
        expect(queue.length, 1);
        expect(queue.first.mutationType, 'review');
        expect(queue.first.payload['item_id'], 'ja_kata_bug');
        expect(queue.first.payload['rating'], 3);
      },
    );
  });

  group('SyncCoordinator - Online Push Sync', () {
    test(
      'malformed push card does not discard an unprocessed review',
      () async {
        final client = MockClient((request) async {
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode({
                'synced_reviews': 1,
                'synced_lessons': 1,
                'updated_cards': [
                  {'item_id': 'ja_kata_bug'},
                ],
              }),
              200,
            );
          }
          return http.Response('unreachable', 500);
        });
        final coordinator = SyncCoordinator(
          localDb: localDb,
          httpClient: client,
        );
        await coordinator.reviewCardOffline(
          itemId: 'ja_kata_bug',
          rating: FSRSRating.good,
        );

        expect((await coordinator.synchronize()).success, isFalse);
        expect((await localDb.getPendingMutations()).length, 1);
        expect((await localDb.getReviewLogs(synced: 0)).length, 1);
      },
    );
    test('uses one persisted installation ID across coordinators', () async {
      final clientIds = <String>[];
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          clientIds.add(
            (jsonDecode(request.body) as Map<String, dynamic>)['client_id']
                as String,
          );
          return http.Response(
            jsonEncode({
              'synced_reviews': 1,
              'synced_lessons': 1,
              'updated_cards': [],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'cards': [],
            'lessons': [],
            'server_time': '2026-10-01T16:00:00Z',
          }),
          200,
        );
      });
      for (var i = 0; i < 2; i++) {
        final coordinator = SyncCoordinator(
          localDb: localDb,
          httpClient: client,
        );
        await coordinator.reviewCardOffline(
          itemId: 'lesson_$i',
          rating: FSRSRating.good,
        );
        expect((await coordinator.synchronize()).success, isTrue);
      }
      expect(clientIds.length, 2);
      expect(clientIds.first, clientIds.last);
      expect(clientIds.first, isNot('client_device_default'));
    });
    test('coalesces overlapping synchronization attempts', () async {
      var pushes = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          pushes++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response(
            jsonEncode({
              'synced_reviews': 1,
              'synced_lessons': 1,
              'updated_cards': [],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'cards': [],
            'lessons': [],
            'server_time': '2026-10-01T16:00:00Z',
          }),
          200,
        );
      });
      final coordinator = SyncCoordinator(localDb: localDb, httpClient: client);
      await coordinator.reviewCardOffline(
        itemId: 'ja_kata_bug',
        rating: FSRSRating.good,
      );
      final results = await Future.wait([
        coordinator.synchronize(),
        coordinator.synchronize(),
      ]);
      expect(results.every((result) => result.success), isTrue);
      expect(pushes, 1);
    });
    test('retries a review left in progress by an interrupted run', () async {
      var pushed = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          pushed++;
          return http.Response(
            jsonEncode({
              'synced_reviews': 1,
              'synced_lessons': 1,
              'updated_cards': [],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'cards': [],
            'lessons': [],
            'server_time': '2026-10-01T16:00:00Z',
          }),
          200,
        );
      });
      final coordinator = SyncCoordinator(localDb: localDb, httpClient: client);
      await coordinator.reviewCardOffline(
        itemId: 'ja_kata_bug',
        rating: FSRSRating.good,
      );
      final id = (await localDb.getPendingMutations()).single.id;
      await localDb.markMutationsInProgress([id]);

      expect((await coordinator.synchronize()).success, isTrue);
      expect(pushed, 1);
      expect(await localDb.getPendingMutations(), isEmpty);
    });
    test(
      'flushes pending queue to POST /api/v1/sync and cleans up queue',
      () async {
        http.Request? capturedPushRequest;

        final mockClient = MockClient((request) async {
          if (request.url.path.endsWith('/sync') && request.method == 'POST') {
            capturedPushRequest = request;
            return http.Response(
              jsonEncode({
                'server_time': '2026-10-01T12:05:00Z',
                'synced_reviews': 1,
                'synced_lessons': 1,
                'updated_cards': [
                  {
                    'item_id': 'ja_kata_bug',
                    'state': 2,
                    'stability': 3.1262,
                    'difficulty': 6.84,
                    'reps': 1,
                    'lapses': 0,
                    'last_review': '2026-10-01T12:00:00Z',
                    'next_review': '2026-10-04T12:00:00Z',
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          } else if (request.url.path.endsWith('/sync/pull')) {
            return http.Response(
              jsonEncode({
                'cards': [],
                'lessons': [],
                'server_time': '2026-10-01T12:05:00Z',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('Not Found', 404);
        });

        final coordinator = SyncCoordinator(
          localDb: localDb,
          httpClient: mockClient,
          clientId: 'test_device_push',
        );

        // Perform offline review
        await coordinator.reviewCardOffline(
          itemId: 'ja_kata_bug',
          rating: FSRSRating.good,
          reviewTime: DateTime.parse('2026-10-01T12:00:00Z'),
        );

        // Check pending before sync
        expect((await localDb.getPendingMutations()).length, 1);

        // Perform sync
        final result = await coordinator.synchronize();
        expect(result.success, isTrue);
        expect(result.syncedReviews, 1);

        // Verify captured push payload
        expect(capturedPushRequest, isNotNull);
        final body =
            jsonDecode(capturedPushRequest!.body) as Map<String, dynamic>;
        expect(body['client_id'], 'test_device_push');
        final reviews = body['reviews'] as List<dynamic>;
        expect(reviews.length, 1);
        expect(reviews.first['item_id'], 'ja_kata_bug');
        expect(reviews.first['rating'], 3);
        expect(reviews.first.containsKey('id'), isFalse);

        // Verify queue is now empty and logs marked synced
        expect(await localDb.getPendingMutations(), isEmpty);
        final logs = await localDb.getReviewLogs(synced: 1);
        expect(logs.length, 1);
      },
    );

    test(
      'reverts in_progress mutations to pending if push request fails',
      () async {
        final mockClient = MockClient((request) async {
          return http.Response('Internal Server Error', 500);
        });

        final coordinator = SyncCoordinator(
          localDb: localDb,
          httpClient: mockClient,
        );

        await coordinator.reviewCardOffline(
          itemId: 'ja_kata_bug',
          rating: FSRSRating.again,
        );

        final result = await coordinator.synchronize();
        expect(result.success, isFalse);
        expect(result.error, contains('500'));

        // Queue items must be reverted to pending so they can be retried
        final pending = await localDb.getPendingMutations();
        expect(pending.length, 1);
        expect(pending.first.retryCount, 1);
      },
    );
  });

  group('SyncCoordinator - Pull Sync & Last-Write-Wins (LWW)', () {
    test('keeps a local card whose review is still queued', () async {
      final time = DateTime.parse('2026-10-01T12:00:00Z');
      for (var i = 0; i < 50; i++) {
        await localDb.enqueueMutation(
          mutationType: 'review',
          payload: {
            'review_id': 'queued_$i',
            'item_id': 'other_$i',
            'rating': 3,
            'review_time': time.toIso8601String(),
          },
        );
      }
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({
              'synced_reviews': 50,
              'synced_lessons': 50,
              'updated_cards': [],
              'server_time': '2026-10-01T16:00:00Z',
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'cards': [
              {
                'item_id': 'ja_kata_bug',
                'state': 2,
                'stability': 10.0,
                'difficulty': 4.0,
                'reps': 99,
                'lapses': 0,
                'last_review': '2026-10-01T15:00:00Z',
                'next_review': '2026-10-15T15:00:00Z',
              },
            ],
            'lessons': [],
            'server_time': '2026-10-01T16:00:00Z',
          }),
          200,
        );
      });
      final coordinator = SyncCoordinator(localDb: localDb, httpClient: client);
      await coordinator.reviewCardOffline(
        itemId: 'ja_kata_bug',
        rating: FSRSRating.good,
        reviewTime: time,
      );

      expect((await coordinator.synchronize()).success, isTrue);
      expect((await localDb.getCard('ja_kata_bug'))?.reps, 1);
      expect(
        (await localDb.getPendingMutations()).single.payload['item_id'],
        'ja_kata_bug',
      );
    });
    test('pull cursor survives coordinator recreation', () async {
      final pullUris = <Uri>[];
      final client = MockClient((request) async {
        pullUris.add(request.url);
        return http.Response(
          jsonEncode({
            'cards': [],
            'lessons': [],
            'server_time': '2026-10-01T15:00:00Z',
          }),
          200,
        );
      });

      expect(
        (await SyncCoordinator(
          localDb: localDb,
          httpClient: client,
        ).synchronize()).success,
        isTrue,
      );
      expect(
        (await SyncCoordinator(
          localDb: localDb,
          httpClient: client,
        ).synchronize()).success,
        isTrue,
      );
      expect(pullUris.first.queryParameters['since'], isNull);
      expect(
        pullUris.last.queryParameters['since'],
        '2026-10-01T15:00:00.000Z',
      );
    });

    test(
      'push timestamp does not skip changes in the subsequent pull',
      () async {
        Uri? pullUri;
        final client = MockClient((request) async {
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode({
                'synced_reviews': 1,
                'synced_lessons': 1,
                'updated_cards': [],
                'server_time': '2026-10-01T16:00:00Z',
              }),
              200,
            );
          }
          pullUri = request.url;
          return http.Response(
            jsonEncode({
              'cards': [],
              'lessons': [],
              'server_time': '2026-10-01T16:00:00Z',
            }),
            200,
          );
        });
        final coordinator = SyncCoordinator(
          localDb: localDb,
          httpClient: client,
        );
        await coordinator.reviewCardOffline(
          itemId: 'ja_kata_bug',
          rating: FSRSRating.good,
          reviewTime: DateTime.parse('2026-10-01T12:00:00Z'),
        );

        expect((await coordinator.synchronize()).success, isTrue);
        expect(pullUri?.queryParameters['since'], isNull);
      },
    );

    test(
      'pull updates local card when server has newer review timestamp',
      () async {
        final mockClient = MockClient((request) async {
          if (request.url.path.endsWith('/sync/pull')) {
            return http.Response(
              jsonEncode({
                'cards': [
                  {
                    'item_id': 'ja_kata_bug',
                    'state': 2,
                    'stability': 10.5,
                    'difficulty': 4.2,
                    'reps': 5,
                    'lapses': 0,
                    'last_review': '2026-10-01T15:00:00Z', // newer
                    'next_review': '2026-10-15T15:00:00Z',
                  },
                ],
                'lessons': [
                  {
                    'id': 'en_it_remote',
                    'language': 'en',
                    'category': 'it_workplace',
                    'target_text': 'remote',
                    'phonetic_or_kana': '/rɪˈmoʊt/',
                    'meaning_vi': 'Làm việc từ xa',
                    'workplace_context': 'We have a remote-first culture.',
                    'workplace_context_vi': 'Chúng tôi có văn hóa remote.',
                    'stroke_order_hints': ['r-e-m-o-t-e'],
                    'difficulty_level': 1,
                  },
                ],
                'server_time': '2026-10-01T15:05:00Z',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('OK', 200);
        });

        final coordinator = SyncCoordinator(
          localDb: localDb,
          httpClient: mockClient,
        );

        // Local card reviewed earlier at 12:00
        await coordinator.reviewCardOffline(
          itemId: 'ja_kata_bug',
          rating: FSRSRating.good,
          reviewTime: DateTime.parse('2026-10-01T12:00:00Z'),
        );
        // Clean queue to focus test on pull
        await localDb.deleteMutations([1]);

        final result = await coordinator.synchronize();
        expect(result.success, isTrue);
        expect(result.pulledCards, 1);
        expect(result.pulledLessons, 1);

        // Check that server card overwritten local card due to LWW (15:00 > 12:00)
        final localCard = await localDb.getCard('ja_kata_bug');
        expect(localCard, isNotNull);
        expect(localCard!.reps, 5);
        expect(localCard.stability, closeTo(10.5, 0.001));

        // Check pulled lesson saved
        final lesson = await localDb.getLesson('en_it_remote');
        expect(lesson, isNotNull);
        expect(lesson!.targetText, 'remote');
      },
    );

    test(
      'retains local card when local review is newer than server card (LWW)',
      () async {
        final mockClient = MockClient((request) async {
          if (request.url.path.endsWith('/sync/pull')) {
            return http.Response(
              jsonEncode({
                'cards': [
                  {
                    'item_id': 'ja_kata_bug',
                    'state': 1,
                    'stability': 1.0,
                    'difficulty': 7.0,
                    'reps': 1,
                    'lapses': 0,
                    'last_review': '2026-10-01T10:00:00Z', // older
                    'next_review': '2026-10-02T10:00:00Z',
                  },
                ],
                'lessons': [],
                'server_time': '2026-10-01T16:00:00Z',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('OK', 200);
        });

        final coordinator = SyncCoordinator(
          localDb: localDb,
          httpClient: mockClient,
        );

        // Local card reviewed later at 14:00
        await coordinator.reviewCardOffline(
          itemId: 'ja_kata_bug',
          rating: FSRSRating.good,
          reviewTime: DateTime.parse('2026-10-01T14:00:00Z'),
        );
        await localDb.deleteMutations([1]);

        final result = await coordinator.synchronize();
        expect(result.success, isTrue);
        expect(result.pulledCards, 0); // Not applied because local is newer

        final localCard = await localDb.getCard('ja_kata_bug');
        expect(localCard, isNotNull);
        expect(localCard!.lastReview, DateTime.parse('2026-10-01T14:00:00Z'));
      },
    );
  });
}
