import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:app/services/local_database.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/sync_coordinator.dart';
import 'package:app/services/fsrs_engine.dart';

void main() {
  late LocalDatabase db;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = LocalDatabase.instance;
    await db.initCustom(customPath: inMemoryDatabasePath);
  });
  tearDown(() => db.close());
  final alice = {
    'user_id': 'usr_a',
    'username': 'alice',
    'sync_token': 'lct_a',
    'server_url': 'http://test/api/v1',
  };
  test(
    'profile switching preserves each queue and cursor without crossing accounts',
    () async {
      final sync = SyncCoordinator(localDb: db, baseUrl: 'http://test/api/v1');
      await sync.reviewCardOffline(
        itemId: 'local_word',
        rating: FSRSRating.good,
      );
      await sync.changeAccount(alice);
      expect(await db.getCard('local_word'), isNull);
      expect(await db.getPendingMutations(), isEmpty);
      await sync.reviewCardOffline(
        itemId: 'alice_word',
        rating: FSRSRating.easy,
      );
      await db.setSyncSequence(19);
      await sync.changeAccount(null);
      expect(
        (await db.getPendingMutations()).single.payload['item_id'],
        'local_word',
      );
      expect(await db.getSyncSequence(), isNull);
      await sync.changeAccount(alice);
      expect(
        (await db.getPendingMutations()).single.payload['item_id'],
        'alice_word',
      );
      expect(await db.getSyncSequence(), 19);
    },
  );
  test(
    'sync authenticates both legs and advances sequence only from completed pull',
    () async {
      late SyncCoordinator sync;
      final requests = <http.Request>[];
      sync = SyncCoordinator(
        localDb: db,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient((r) async {
          requests.add(r);
          expect(r.followRedirects, isFalse);
          expect(
            r.headers['X-Sync-Token'] ?? r.headers['x-sync-token'],
            'lct_a',
          );
          if (r.method == 'POST') {
            expect(jsonDecode(r.body)['user_id'], 'usr_a');
            return http.Response(
              jsonEncode({
                'synced_reviews': 1,
                'synced_lessons': 1,
                'updated_cards': [],
                'latest_sync_seq': 999,
              }),
              200,
            );
          }
          expect(r.url.queryParameters['since_seq'], '5');
          return http.Response(
            jsonEncode({
              'cards': [],
              'lessons': [],
              'completed_lessons': [],
              'latest_sync_seq': 8,
            }),
            200,
          );
        }),
      );
      await sync.changeAccount(alice);
      await db.setSyncSequence(5);
      await sync.reviewCardOffline(itemId: 'word', rating: FSRSRating.good);
      expect((await sync.synchronize()).success, isTrue);
      expect(requests.length, 2);
      expect(await db.getSyncSequence(), 8);
    },
  );
  test('changing profiles waits for the old sync to finish', () async {
    final started = Completer<void>();
    final reply = Completer<http.Response>();
    final sync = SyncCoordinator(
      localDb: db,
      baseUrl: 'http://test/api/v1',
      httpClient: MockClient((r) async {
        if (r.method == 'POST') {
          started.complete();
          return reply.future;
        }
        return http.Response(
          jsonEncode({'cards': [], 'lessons': [], 'latest_sync_seq': 9}),
          200,
        );
      }),
    );
    await sync.changeAccount(alice);
    await sync.reviewCardOffline(itemId: 'alice_old', rating: FSRSRating.good);
    final syncing = sync.synchronize();
    await started.future;
    final changing = sync.changeAccount({
      ...alice,
      'user_id': 'usr_b',
      'username': 'bob',
      'sync_token': 'lct_b',
    });
    await Future<void>.delayed(Duration.zero);
    expect((await db.getAccount())!['user_id'], 'usr_a');
    reply.complete(http.Response(jsonEncode({'updated_cards': []}), 200));
    expect((await syncing).success, isTrue);
    await changing;
    expect(await db.getCard('alice_old'), isNull);
    expect(await db.getSyncSequence(), isNull);
  });
  test(
    'reset waits for in-flight reconciliation then clears every profile',
    () async {
      final started = Completer<void>();
      final reply = Completer<http.Response>();
      final sync = SyncCoordinator(
        localDb: db,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient((r) async {
          started.complete();
          return reply.future;
        }),
      );
      await sync.changeAccount(alice);
      final syncing = sync.synchronize();
      await started.future;
      final clearing = db.clearAll();
      await Future<void>.delayed(Duration.zero);
      expect((await db.getAccount())?['user_id'], 'usr_a');
      reply.complete(
        http.Response(
          jsonEncode({'cards': [], 'lessons': [], 'latest_sync_seq': 99}),
          200,
        ),
      );
      await syncing;
      await clearing;
      expect(await db.getAccount(), isNull);
      expect(await db.getSyncSequence(), isNull);
    },
  );
  test('custom lesson creation completes in its original profile', () async {
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    final sync = SyncCoordinator(localDb: db, baseUrl: 'http://test/api/v1');
    await sync.changeAccount(alice);
    final creating = http.runWithClient(
      () => ApiService(
        localDb: db,
        baseUrl: 'http://test/api/v1',
      ).ensureLessonForWord(word: 'private phrase', language: 'en'),
      () => MockClient((r) async {
        requested.complete();
        return response.future;
      }),
    );
    await requested.future;
    final changing = sync.changeAccount({
      ...alice,
      'user_id': 'usr_b',
      'sync_token': 'lct_b',
    });
    await Future<void>.delayed(Duration.zero);
    expect((await db.getAccount())!['user_id'], 'usr_a');
    response.complete(http.Response('[]', 200));
    final lesson = await creating;
    await changing;
    expect(await db.getLessons(category: 'custom'), isEmpty);
    await sync.changeAccount(alice);
    expect((await db.getLessons(category: 'custom')).single.id, lesson.id);
  });
  test(
    'completed lessons from a second device update the local progress',
    () async {
      final sync = SyncCoordinator(
        localDb: db,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient(
          (r) async => http.Response(
            jsonEncode({
              'cards': [],
              'lessons': [],
              'completed_lessons': [
                {
                  'lesson_id': 'from_other_device',
                  'completed_at': '2026-10-14T00:00:00Z',
                  'score': 0.9,
                },
                {
                  'lesson_id': 'from_other_device',
                  'completed_at': '2026-10-13T00:00:00Z',
                  'score': 0.5,
                },
              ],
              'latest_sync_seq': 12,
            }),
            200,
          ),
        ),
      );
      await sync.changeAccount(alice);
      expect((await sync.synchronize()).success, isTrue);
      expect(
        (await db.getCompletedLessons()).single.lessonId,
        'from_other_device',
      );
      expect((await db.getCompletedLessons()).single.synced, 1);
      expect((await db.getCompletedLessons()).single.score, 0.9);
    },
  );
  test(
    'changing backend never sends stored account credentials or reviews to a new server',
    () async {
      var sent = 0;
      final sync = SyncCoordinator(
        localDb: db,
        baseUrl: 'http://other/api/v1',
        httpClient: MockClient((r) async {
          sent++;
          return http.Response('{}', 200);
        }),
      );
      await sync.changeAccount(alice);
      await sync.reviewCardOffline(itemId: 'private', rating: FSRSRating.good);
      expect((await sync.synchronize()).success, isFalse);
      expect(sent, 0);
    },
  );
}
