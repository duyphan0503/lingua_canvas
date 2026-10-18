import 'dart:convert';
import 'package:app/services/storage/browser_local_store.dart';
import 'package:app/models/lesson_item.dart';
import 'package:app/services/sync_coordinator.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../helpers/memory_snapshot_persistence.dart';
import '../storage/private_vocabulary_test.dart' show word, remote;

void main() {
  late BrowserLocalStore store;
  setUp(() async {
    store = BrowserLocalStore(
      persistence: MemorySnapshotPersistence(),
      initialBackend: 'http://test/api/v1',
    );
    await store.initialize();
    await store.switchAccount({
      'user_id': 'alice',
      'server_url': 'http://test/api/v1',
      'sync_token': 'secret',
    });
  });
  test(
    'old server retains private queues while legacy review sync works',
    () async {
      await store.savePrivateLesson(word('custom_ja_a'));
      final sync = SyncCoordinator(
        localDb: store,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient(
          (r) async => http.Response(
            jsonEncode(
              r.method == 'POST'
                  ? {'synced_reviews': 1, 'updated_cards': []}
                  : {'cards': [], 'lessons': []},
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      await sync.reviewCardOffline(
        itemId: 'ja_hira_a',
        rating: FSRSRating.good,
      );
      final result = await sync.synchronize();
      expect(result.upgradeRequired, isTrue);
      final queue = await store.getPendingMutations();
      expect(queue.single.mutationType, 'custom_lesson');
      expect((await store.getPrivateLesson('custom_ja_a'))!.pending, isTrue);
    },
  );
  test(
    'explicit custom ACK only removes matching mutation and preserves complete metadata',
    () async {
      await store.savePrivateLesson(word('custom_ja_a'));
      await store.savePrivateLesson(word('custom_ja_b'));
      final sync = SyncCoordinator(
        localDb: store,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient((r) async {
          if (r.method == 'GET') {
            return http.Response('{"cards":[],"lessons":[]}', 200);
          }
          final data = jsonDecode(r.body) as Map;
          final entries = data['custom_lesson_mutations'] as List;
          expect(
            (entries.first['lesson'] as Map)['workplace_context_vi'],
            'Tôi sẽ trao đổi',
          );
          expect(
            r.headers['X-Sync-Token'] ?? r.headers['x-sync-token'],
            'secret',
          );
          return http.Response(
            jsonEncode({
              'capabilities': {
                'private_vocabulary_sync': 1,
                'progress_import': 1,
              },
              'custom_lesson_acks': [
                {
                  'mutation_id': entries.first['mutation_id'],
                  'state': remote(word(entries.first['lesson']['id']), 1),
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final result = await sync.synchronize();
      expect(result.success, isTrue, reason: result.error);
      expect((await store.getPendingMutations()).length, 1);
      expect((await store.getPrivateLesson('custom_ja_a'))!.revision, 1);
    },
  );
  test(
    'batches stay below entry and byte limits and oversize stays visible',
    () async {
      for (var i = 0; i < 55; i++) {
        await store.savePrivateLesson(word('custom_ja_$i'));
      }
      var pushes = 0;
      final sync = SyncCoordinator(
        localDb: store,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient((r) async {
          if (r.method == 'GET') {
            return http.Response('{"cards":[],"lessons":[]}', 200);
          }
          pushes++;
          expect(utf8.encode(r.body).length, lessThanOrEqualTo(512 * 1024));
          final rows =
              (jsonDecode(r.body) as Map)['custom_lesson_mutations'] as List;
          expect(rows.length, lessThanOrEqualTo(50));
          return http.Response(
            jsonEncode({
              'capabilities': {
                'private_vocabulary_sync': 1,
                'progress_import': 1,
              },
              'custom_lesson_acks': [
                for (final e in rows)
                  {
                    'mutation_id': e['mutation_id'],
                    'state': remote(word(e['lesson']['id']), 1),
                  },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final result = await sync.synchronize();
      expect(result.success, isTrue, reason: result.error);
      expect(pushes, 2);
      expect(await store.getPendingMutations(), isEmpty);
    },
  );
  test('deleted private word cannot accept a stale practice review', () async {
    await store.savePrivateLesson(word('custom_ja_a'));
    await store.deletePrivateLesson('custom_ja_a');
    final sync = SyncCoordinator(localDb: store, baseUrl: 'http://test/api/v1');
    await expectLater(
      sync.reviewCardOffline(itemId: 'custom_ja_a', rating: FSRSRating.good),
      throwsStateError,
    );
    expect(await store.getCard('custom_ja_a'), isNull);
  });
  test(
    'equal timestamp server progress is reconciled deterministically',
    () async {
      final timestamp = DateTime.utc(2026, 10, 1);
      await store.saveCard(
        FSRSCard(
          itemId: 'ja_hira_a',
          state: FSRSState.review,
          stability: 8,
          difficulty: 5,
          reps: 10,
          lapses: 0,
          lastReview: timestamp,
          nextReview: timestamp.add(const Duration(days: 8)),
        ),
      );
      await store.saveCompletedLesson(
        'ja_hira_a',
        completedAt: timestamp,
        score: 1,
        synced: 1,
      );
      final sync = SyncCoordinator(
        localDb: store,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient((r) async {
          if (r.method == 'POST') return http.Response('{}', 200);
          return http.Response(
            jsonEncode({
              'cards': [
                {
                  'item_id': 'ja_hira_a',
                  'state': 'Review',
                  'stability': 3,
                  'difficulty': 6,
                  'reps': 7,
                  'lapses': 0,
                  'last_review': timestamp.toIso8601String(),
                  'next_review': timestamp
                      .add(const Duration(days: 3))
                      .toIso8601String(),
                },
              ],
              'completed_lessons': [
                {
                  'lesson_id': 'ja_hira_a',
                  'completed_at': timestamp.toIso8601String(),
                  'score': 0.5,
                },
              ],
            }),
            200,
          );
        }),
      );
      await sync.synchronize();
      expect((await store.getCard('ja_hira_a'))!.reps, 7);
      expect((await store.getCompletedLessons()).single.score, 0.5);
      await sync.synchronize();
      expect((await store.getCard('ja_hira_a'))!.reps, 7);
      expect((await store.getCompletedLessons()).single.score, 0.5);
    },
  );
  test(
    'unacknowledged in-progress review protects card from unrelated push response',
    () async {
      final sync = SyncCoordinator(
        localDb: store,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient((r) async {
          if (r.method == 'GET') {
            return http.Response('{"cards":[],"lessons":[]}', 200);
          }
          return http.Response(
            jsonEncode({
              'synced_review_ids': <String>[],
              'synced_completed_lesson_ids': <String>[],
              'updated_cards': [
                {
                  'item_id': 'ja_hira_a',
                  'state': 'Review',
                  'stability': 99,
                  'difficulty': 5,
                  'reps': 99,
                  'lapses': 0,
                  'last_review': '2026-10-02T00:00:00Z',
                  'next_review': '2026-10-10T00:00:00Z',
                },
              ],
            }),
            200,
          );
        }),
      );
      await sync.reviewCardOffline(
        itemId: 'ja_hira_a',
        rating: FSRSRating.good,
        reviewTime: DateTime.utc(2026, 10, 1),
      );
      await sync.synchronize();
      expect((await store.getCard('ja_hira_a'))!.reps, 1);
      expect((await store.getPendingMutations()).single.mutationType, 'review');
    },
  );

  test('mixed reviews and metadata obey fifty top-level entries', () async {
    final fixture = SyncCoordinator(localDb: store);
    for (var i = 0; i < 26; i++) {
      await fixture.reviewCardOffline(
        itemId: 'review_$i',
        rating: FSRSRating.good,
      );
    }
    await store.savePrivateLesson(word('custom_ja_a'));
    var posts = 0;
    final sync = SyncCoordinator(
      localDb: store,
      baseUrl: 'http://test/api/v1',
      httpClient: MockClient((r) async {
        if (r.method == 'GET') {
          return http.Response('{"cards":[],"lessons":[]}', 200);
        }
        posts++;
        final body = jsonDecode(r.body) as Map;
        final custom = body['custom_lesson_mutations'] as List? ?? [];
        if (custom.isNotEmpty) {
          expect(
            (body['reviews'] as List).length +
                (body['completed_lessons'] as List).length +
                custom.length,
            lessThanOrEqualTo(50),
          );
        }
        return http.Response(
          jsonEncode({
            'capabilities': {
              'private_vocabulary_sync': 1,
              'progress_import': 1,
            },
            'custom_lesson_acks': [
              for (final e in custom)
                {
                  'mutation_id': e['mutation_id'],
                  'state': remote(word(e['lesson']['id']), 1),
                },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    await sync.synchronize();
    expect(posts, 2);
    expect(await store.getPendingMutations(), isEmpty);
  });
  test(
    'retry ACK rebases and sends unsent descendant in next bounded batch',
    () async {
      await store.savePrivateLesson(word('custom_ja_a'));
      final first = (await store.getPendingMutations()).single;
      await store.markMutationsInProgress([first.id]);
      await store.resetFailedMutations([first.id]);
      await store.savePrivateLesson(word('custom_ja_a', 'new local'));
      final second = (await store.getPendingMutations()).last;
      var pushes = 0;
      final sync = SyncCoordinator(
        localDb: store,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient((r) async {
          if (r.method == 'GET') {
            return http.Response('{"cards":[],"lessons":[]}', 200);
          }
          final entries =
              (jsonDecode(r.body) as Map)['custom_lesson_mutations'] as List;
          expect(entries.length, 1);
          pushes++;
          final e = entries.single as Map;
          expect(
            e['mutation_id'],
            pushes == 1
                ? first.payload['mutation_id']
                : second.payload['mutation_id'],
          );
          expect(e['base_revision'], pushes - 1);
          return http.Response(
            jsonEncode({
              'capabilities': {
                'private_vocabulary_sync': 1,
                'progress_import': 1,
              },
              'custom_lesson_acks': [
                {
                  'mutation_id': e['mutation_id'],
                  'state': remote(
                    word('custom_ja_a', e['lesson']['target_text']),
                    pushes,
                  ),
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final result = await sync.synchronize();
      expect(result.success, isTrue, reason: result.error);
      expect(pushes, 2);
      expect(await store.getPendingMutations(), isEmpty);
      expect((await store.getPrivateLesson('custom_ja_a'))!.revision, 2);
    },
  );

  test(
    'one oversize metadata entry remains queued with a durable visible error',
    () async {
      final raw = word('custom_ja_large').toJson();
      raw['stroke_order_hints'] = List.filled(64, 'x' * 16384);
      await store.savePrivateLesson(LessonItem.fromJson(raw));
      var pushes = 0;
      final sync = SyncCoordinator(
        localDb: store,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient((r) async {
          if (r.method == 'POST') pushes++;
          return http.Response('{"cards":[],"lessons":[]}', 200);
        }),
      );
      final result = await sync.synchronize();
      expect(result.success, isFalse);
      expect(result.error, contains('quá lớn'));
      expect(pushes, 0);
      expect((await store.getPendingMutations()).length, 1);
      expect(await store.getMetadata('private_sync_error'), result.error);
    },
  );
}
