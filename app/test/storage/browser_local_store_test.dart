import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:app/services/storage/browser_local_store.dart';
import 'package:app/services/storage/snapshot_persistence.dart';
import 'package:app/services/sync_coordinator.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/phase3_lessons.dart';
import '../helpers/memory_snapshot_persistence.dart';

void main() {
  late MemorySnapshotPersistence disk;
  late BrowserLocalStore store;
  late SyncCoordinator sync;
  final alice = {
    'user_id': 'usr_a',
    'sync_token': 'lct_a',
    'server_url': 'http://test/api/v1',
  };
  setUp(() async {
    disk = MemorySnapshotPersistence();
    store = BrowserLocalStore(
      persistence: disk,
      initialBackend: 'http://test/api/v1',
    );
    await store.initialize();
    sync = SyncCoordinator(localDb: store, baseUrl: 'http://test/api/v1');
  });
  test(
    'review commits all records and survives reopening with stable IDs',
    () async {
      final id = await store.getOrCreateClientId();
      await sync.reviewCardOffline(itemId: 'word', rating: FSRSRating.good);
      final mutation = (await store.getPendingMutations()).single;
      final reopened = BrowserLocalStore(persistence: disk);
      await reopened.initialize();
      expect(await reopened.getOrCreateClientId(), id);
      expect((await reopened.getCard('word'))!.reps, 1);
      expect(
        (await reopened.getReviewLogs()).single.id,
        mutation.payload['review_id'],
      );
      expect((await reopened.getPendingMutations()).single.id, mutation.id);
      expect(await reopened.getCompletedCount(), 1);
      expect((await reopened.getStudyStreak()).currentStreak, 1);
    },
  );
  test(
    'quota abort leaves no partial card log completion queue or activity',
    () async {
      disk.nextSaveError = const BrowserStorageException('quota', 'full');
      await expectLater(
        sync.reviewCardOffline(itemId: 'lost', rating: FSRSRating.good),
        throwsA(isA<BrowserStorageException>()),
      );
      expect(await store.getAllCards(), isEmpty);
      expect(await store.getReviewLogs(), isEmpty);
      expect(await store.getCompletedLessons(), isEmpty);
      expect(await store.getPendingMutations(), isEmpty);
      expect((await store.getStudyStreak()).currentStreak, 0);
      await sync.reviewCardOffline(itemId: 'retry', rating: FSRSRating.good);
      expect((await store.getAllCards()).single.itemId, 'retry');
    },
  );
  test(
    'account and anonymous backend profiles retain independent queues',
    () async {
      await sync.reviewCardOffline(itemId: 'anonA', rating: FSRSRating.good);
      await sync.changeAccount(alice);
      await sync.reviewCardOffline(itemId: 'alice', rating: FSRSRating.good);
      await store.setSyncSequence(22);
      await store.withProfileLock(
        () => store.selectBackend('http://other/api/v1'),
      );
      expect(await store.getAccount(), isNull);
      expect(await store.getPendingMutations(), isEmpty);
      await store.enqueueMutation(
        mutationType: 'review',
        payload: {'item_id': 'anonB'},
      );
      await store.withProfileLock(
        () => store.selectBackend('http://test/api/v1'),
      );
      expect((await store.getAccount())!['user_id'], 'usr_a');
      expect(await store.getSyncSequence(), 22);
      await sync.changeAccount(null);
      expect(
        (await store.getPendingMutations()).single.payload['item_id'],
        'anonA',
      );
    },
  );
  test(
    'scoped reset keeps inactive profile and installation identity',
    () async {
      final id = await store.getOrCreateClientId();
      await sync.reviewCardOffline(itemId: 'anon', rating: FSRSRating.good);
      await sync.changeAccount(alice);
      await sync.reviewCardOffline(itemId: 'alice', rating: FSRSRating.good);
      await store.clearCurrentProfile();
      expect(await store.getAllCards(), isEmpty);
      expect((await store.getAccount())!['user_id'], 'usr_a');
      await sync.changeAccount(null);
      expect((await store.getAllCards()).single.itemId, 'anon');
      expect(await store.getOrCreateClientId(), id);
    },
  );
  test(
    'queue retries recover without changing canonical review identity',
    () async {
      await sync.reviewCardOffline(itemId: 'retry', rating: FSRSRating.again);
      final first = (await store.getPendingMutations()).single;
      await store.markMutationsInProgress([first.id]);
      expect(await store.getPendingMutations(), isEmpty);
      await store.recoverInterruptedMutations();
      await store.resetFailedMutations([first.id]);
      final next = (await store.getPendingMutations()).single;
      expect(next.payload['review_id'], first.payload['review_id']);
      expect(next.retryCount, 1);
      await store.deleteMutations([first.id]);
      expect(await store.getPendingMutations(), isEmpty);
    },
  );
  test(
    'lesson filters and returned objects cannot mutate durable state',
    () async {
      await store.saveLessons(phase3Lessons);
      final ja = await store.getLessons(language: 'ja', category: 'jlpt_n4');
      expect(ja.length, 10);
      ja.first.strokeOrderHints.clear();
      expect(
        (await store.getLesson(ja.first.id))!.strokeOrderHints,
        isNotEmpty,
      );
      await store.setMetadata('settings', 'value');
      expect(await store.getMetadata('settings'), 'value');
    },
  );
  test(
    'multi-device completion reconciliation keeps the newest and sequence',
    () async {
      final coordinator = SyncCoordinator(
        localDb: store,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient(
          (r) async => http.Response(
            jsonEncode({
              'cards': [],
              'lessons': [],
              'latest_sync_seq': 12,
              'completed_lessons': [
                {
                  'lesson_id': 'remote',
                  'completed_at': '2026-10-15T00:00:00Z',
                  'score': 0.9,
                },
                {
                  'lesson_id': 'remote',
                  'completed_at': '2026-10-14T00:00:00Z',
                  'score': 0.3,
                },
              ],
            }),
            200,
          ),
        ),
      );
      expect((await coordinator.synchronize()).success, isTrue);
      expect((await store.getCompletedLessons()).single.score, 0.9);
      expect(await store.getSyncSequence(), 12);
    },
  );
  test(
    'switch waits for old reconciliation and never moves its queue',
    () async {
      final started = Completer<void>();
      final reply = Completer<http.Response>();
      final coordinator = SyncCoordinator(
        localDb: store,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient((r) async {
          started.complete();
          return reply.future;
        }),
      );
      final pulling = coordinator.synchronize();
      await started.future;
      final changing = coordinator.changeAccount(alice);
      reply.complete(
        http.Response('{"cards":[],"lessons":[],"latest_sync_seq":5}', 200),
      );
      await pulling;
      await changing;
      expect(await store.getSyncSequence(), isNull);
      await coordinator.changeAccount(null);
      expect(await store.getSyncSequence(), 5);
    },
  );
  test('unknown schema fails without erasing original storage', () async {
    final original = {'version': 900, 'private': 'preserve'};
    disk.data = original;
    final corrupt = BrowserLocalStore(persistence: disk);
    await expectLater(
      corrupt.initialize(),
      throwsA(isA<BrowserStorageException>()),
    );
    expect(disk.data, original);
  });
  test(
    'quiet streak and due boundaries use proper local dates and UTC times',
    () async {
      final today = DateTime(2026, 10, 15);
      await store.logDailyActivity(DateTime(2026, 10, 14), 2);
      await store.logDailyActivity(DateTime(2026, 10, 13), 3);
      final streak = await store.getStudyStreak(asOf: today);
      expect(streak.currentStreak, 2);
      expect(streak.longestStreak, 2);
      expect(streak.activityHistory.length, 30);
      final card = FSRSCard.initial('due');
      await store.saveCard(card);
      expect(await store.getDueCardIds(card.nextReview), ['due']);
    },
  );
}
