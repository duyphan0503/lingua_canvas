import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:app/models/lesson_item.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/local_database.dart';

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

  group('LocalDatabase Table Schema and Initial State', () {
    test('verifies all 5 tables exist in SQLite database', () async {
      final db = await localDb.database;
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      );
      final tableNames = tables.map((t) => t['name'] as String).toSet();

      expect(tableNames, contains('local_lessons'));
      expect(tableNames, contains('local_fsrs_cards'));
      expect(tableNames, contains('local_review_logs'));
      expect(tableNames, contains('local_sync_queue'));
      expect(tableNames, contains('local_completed_lessons'));
    });
  });

  group('Lesson Storage and Retrieval', () {
    final testLesson1 = LessonItem(
      id: 'ja_kata_test',
      language: 'ja',
      category: 'it_workplace',
      targetText: 'テスト',
      phoneticOrKana: 'tesuto',
      meaningVi: 'Kiểm thử phần mềm',
      workplaceContext: '単体テストを実行します',
      workplaceContextVi: 'Tôi sẽ chạy unit test.',
      strokeOrderHints: ['Nét 1', 'Nét 2'],
      difficultyLevel: 1,
    );

    final testLesson2 = LessonItem(
      id: 'en_it_build',
      language: 'en',
      category: 'it_workplace',
      targetText: 'build',
      phoneticOrKana: '/bɪld/',
      meaningVi: 'Biên dịch phần mềm',
      workplaceContext: 'Trigger the production build',
      workplaceContextVi: 'Kích hoạt bản build production',
      strokeOrderHints: ['b-u-i-l-d'],
      difficultyLevel: 2,
    );

    test('saves and retrieves lessons with filtering', () async {
      await localDb.saveLessons([testLesson1, testLesson2]);

      final allLessons = await localDb.getLessons();
      expect(allLessons.length, 2);

      final jaLessons = await localDb.getLessons(language: 'ja');
      expect(jaLessons.length, 1);
      expect(jaLessons.first.id, 'ja_kata_test');
      expect(jaLessons.first.strokeOrderHints, ['Nét 1', 'Nét 2']);

      final enLessons = await localDb.getLessons(language: 'en');
      expect(enLessons.length, 1);
      expect(enLessons.first.id, 'en_it_build');

      final single = await localDb.getLesson('ja_kata_test');
      expect(single, isNotNull);
      expect(single!.targetText, 'テスト');

      final notFound = await localDb.getLesson('non_existent');
      expect(notFound, isNull);
    });
  });

  group('FSRS Cards Storage and Due Queries', () {
    test('saves and retrieves FSRS cards', () async {
      final now = DateTime.now().toUtc();
      final card = FSRSCard(
        itemId: 'ja_kata_test',
        state: FSRSState.review,
        stability: 3.5,
        difficulty: 5.2,
        reps: 2,
        lapses: 0,
        lastReview: now.subtract(const Duration(days: 1)),
        nextReview: now.add(const Duration(days: 3)),
      );

      await localDb.saveCard(card);
      final retrieved = await localDb.getCard('ja_kata_test');

      expect(retrieved, isNotNull);
      expect(retrieved!.itemId, 'ja_kata_test');
      expect(retrieved.state, FSRSState.review);
      expect(retrieved.stability, closeTo(3.5, 0.001));
      expect(retrieved.difficulty, closeTo(5.2, 0.001));
      expect(retrieved.reps, 2);
    });

    test('filters due card item IDs accurately by timestamp', () async {
      final now = DateTime.now().toUtc();
      final dueCard = FSRSCard(
        itemId: 'card_due',
        state: FSRSState.learning,
        stability: 1.0,
        difficulty: 6.0,
        reps: 1,
        lapses: 0,
        lastReview: now.subtract(const Duration(hours: 2)),
        nextReview: now.subtract(const Duration(minutes: 30)), // past due
      );

      final futureCard = FSRSCard(
        itemId: 'card_future',
        state: FSRSState.review,
        stability: 4.0,
        difficulty: 5.0,
        reps: 3,
        lapses: 0,
        lastReview: now,
        nextReview: now.add(const Duration(days: 4)), // future
      );

      await localDb.saveCard(dueCard);
      await localDb.saveCard(futureCard);

      final dueIds = await localDb.getDueCardIds(now);
      expect(dueIds, contains('card_due'));
      expect(dueIds, isNot(contains('card_future')));
    });
  });

  group('Review Logs and Sync Queue', () {
    test('inserts review logs and filters by synced status', () async {
      final now = DateTime.now().toUtc();
      final log1 = LocalReviewLog(
        id: 'rev_1',
        itemId: 'ja_kata_test',
        rating: 3,
        state: 2,
        reviewTime: now,
        elapsedDays: 1.0,
        scheduledDays: 3,
        synced: 0,
      );

      await localDb.insertReviewLog(log1);
      var pendingLogs = await localDb.getReviewLogs(synced: 0);
      expect(pendingLogs.length, 1);
      expect(pendingLogs.first.id, 'rev_1');

      await localDb.markReviewLogsSynced(['rev_1']);
      pendingLogs = await localDb.getReviewLogs(synced: 0);
      expect(pendingLogs, isEmpty);

      final syncedLogs = await localDb.getReviewLogs(synced: 1);
      expect(syncedLogs.length, 1);
    });

    test(
      'sync queue lifecycle: enqueue, get, in_progress, and delete',
      () async {
        final id = await localDb.enqueueMutation(
          mutationType: 'review',
          payload: {'item_id': 'ja_kata_test', 'rating': 3},
        );
        expect(id, greaterThan(0));

        final pending = await localDb.getPendingMutations();
        expect(pending.length, 1);
        expect(pending.first.mutationType, 'review');
        expect(pending.first.payload['item_id'], 'ja_kata_test');

        await localDb.markMutationsInProgress([pending.first.id]);
        expect(await localDb.getPendingMutations(), isEmpty);

        await localDb.deleteMutations([pending.first.id]);
        final db = await localDb.database;
        final rows = await db.rawQuery(
          'SELECT COUNT(*) as count FROM local_sync_queue',
        );
        final count = (rows.first['count'] as num?)?.toInt() ?? 0;
        expect(count, 0);
      },
    );
  });

  group('Atomic Review Transaction', () {
    test(
      'two reviews of one card at the same instant retain distinct log IDs',
      () async {
        final time = DateTime.parse('2026-10-01T12:00:00Z');
        final card = FSRSCard.initial('ja_kata_bug');
        final first = await localDb.recordReviewTransaction(
          updatedCard: card,
          rating: FSRSRating.good,
          reviewTime: time,
          elapsedDays: 0,
          scheduledDays: 3,
        );
        final second = await localDb.recordReviewTransaction(
          updatedCard: card,
          rating: FSRSRating.good,
          reviewTime: time,
          elapsedDays: 0,
          scheduledDays: 3,
        );
        expect(second, isNot(first));
        expect((await localDb.getReviewLogs()).length, 2);
      },
    );
    test(
      'recordReviewTransaction performs atomic write across card, log, completed, and queue',
      () async {
        final now = DateTime.now().toUtc();
        final card = FSRSCard(
          itemId: 'atomic_test_card',
          state: FSRSState.review,
          stability: 3.12,
          difficulty: 6.84,
          reps: 1,
          lapses: 0,
          lastReview: now,
          nextReview: now.add(const Duration(days: 3)),
        );

        final logId = await localDb.recordReviewTransaction(
          updatedCard: card,
          rating: FSRSRating.good,
          reviewTime: now,
          elapsedDays: 0.0,
          scheduledDays: 3,
          completionScore: 0.95,
        );

        expect(logId, startsWith('rev_'));

        // Check card
        final savedCard = await localDb.getCard('atomic_test_card');
        expect(savedCard, isNotNull);
        expect(savedCard!.stability, closeTo(3.12, 0.001));

        // Check review log
        final logs = await localDb.getReviewLogs();
        expect(logs.length, 1);
        expect(logs.first.id, logId);
        expect(logs.first.itemId, 'atomic_test_card');

        // Check completed lessons count
        final completedCount = await localDb.getCompletedCount();
        expect(completedCount, 1);

        // Check sync queue
        final queue = await localDb.getPendingMutations();
        expect(queue.length, 1);
        expect(queue.first.mutationType, 'review');
        expect(queue.first.payload['review_id'], logId);
        expect(queue.first.payload['rating'], 3);
      },
    );
  });
}
