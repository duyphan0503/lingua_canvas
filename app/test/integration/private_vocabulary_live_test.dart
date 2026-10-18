@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/lesson_item.dart';
import 'package:app/services/account_service.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/storage/local_database_native.dart';

const backend = String.fromEnvironment('PRIVATE_VOCABULARY_TEST_API_BASE');

void main() {
  test(
    'SQLite devices synchronize private edits, conflicts, tombstones and progress through PostgreSQL',
    () async {
      final nonce = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
      final directory = await Directory.systemTemp.createTemp(
        'lingua-private-live-',
      );
      addTearDown(() => directory.delete(recursive: true));

      Future<(LocalDatabase, ApiService)> openDevice(String suffix) async {
        final db = LocalDatabase.instance;
        await db.initCustom(customPath: '${directory.path}/$suffix.sqlite');
        await db.initialize();
        final api = ApiService(baseUrl: backend, localDb: db);
        await api.configureServer(backend);
        return (db, api);
      }

      final (sourceDb, source) = await openDevice('source');
      addTearDown(sourceDb.close);
      await AccountService(
        apiService: source,
      ).register(username: 'priv_$nonce', pin: '123456');
      final token = (await sourceDb.getAccount())!['sync_token'] as String;
      final created = await source.createPrivateLesson(
        word: '予約確認$nonce',
        language: 'ja',
        meaningVi: 'Cụm từ riêng $nonce',
        phoneticOrKana: 'よやくかくにん',
        workplaceContext: '明日の予約を確認します。',
        workplaceContextVi: 'Tôi sẽ xác nhận lịch hẹn ngày mai.',
        strokeOrderHints: const ['Đọc câu', 'Xác nhận thông tin'],
        difficultyLevel: 3,
      );
      final initialPush = await source.syncCoordinator.synchronize();
      expect(initialPush.success, isTrue, reason: initialPush.error);
      expect((await source.getPrivateLesson(created.id))!.revision, 1);

      await sourceDb.close();
      final (secondDb, second) = await openDevice('second');
      addTearDown(secondDb.close);
      await AccountService(apiService: second).login(syncToken: token);
      final initialPull = await second.syncCoordinator.synchronize();
      expect(initialPull.success, isTrue, reason: initialPull.error);
      expect(
        (await second.getPrivateLesson(created.id))!.lesson.meaningVi,
        'Cụm từ riêng $nonce',
      );

      final serverEdit = _copyLesson(
        created,
        targetText: '予約を変更$nonce',
        meaningVi: 'Bản chỉnh sửa từ thiết bị hai',
      );
      await second.savePrivateLesson(serverEdit);
      expect((await second.syncCoordinator.synchronize()).success, isTrue);
      await secondDb.close();

      final (sourceDb2, reopenedSource) = await openDevice('source');
      addTearDown(sourceDb2.close);
      final staleEdit = _copyLesson(
        created,
        targetText: '予約を取り消す$nonce',
        meaningVi: 'Bản chỉnh sửa ngoại tuyến từ thiết bị một',
      );
      await reopenedSource.savePrivateLesson(staleEdit);
      final conflictSync = await reopenedSource.syncCoordinator.synchronize();
      expect(conflictSync.success, isTrue, reason: conflictSync.error);
      final conflict = (await reopenedSource.getPrivateLesson(created.id))!;
      expect(conflict.conflict, isNotNull);
      expect(conflict.conflict!.local.lesson.meaningVi, staleEdit.meaningVi);
      expect(conflict.conflict!.remote!.lesson.meaningVi, serverEdit.meaningVi);

      await reopenedSource.resolvePrivateLessonConflict(
        created.id,
        keepLocal: true,
      );
      expect(
        (await reopenedSource.syncCoordinator.synchronize()).success,
        isTrue,
      );
      await sourceDb2.close();

      final (secondDb2, secondAfterConflict) = await openDevice('second');
      addTearDown(secondDb2.close);
      expect(
        (await secondAfterConflict.syncCoordinator.synchronize()).success,
        isTrue,
      );
      expect(
        (await secondAfterConflict.getPrivateLesson(
          created.id,
        ))!.lesson.meaningVi,
        staleEdit.meaningVi,
      );

      final reviewAt = DateTime.now().toUtc().subtract(
        const Duration(seconds: 3),
      );
      await secondAfterConflict.syncCoordinator.reviewCardOffline(
        itemId: created.id,
        rating: FSRSRating.good,
        reviewTime: reviewAt,
      );
      expect(
        (await secondAfterConflict.syncCoordinator.synchronize()).success,
        isTrue,
      );
      final repsAfterReview = (await secondAfterConflict.localDatabase.getCard(
        created.id,
      ))!.reps;
      expect(repsAfterReview, 1);
      final sourceHistoryBeforeDelete = await secondDb2.getReviewLogs();
      expect(
        sourceHistoryBeforeDelete.where((r) => r.itemId == created.id),
        hasLength(1),
      );
      await secondDb2.close();

      final (sourceDb3, sourceAfterReview) = await openDevice('source');
      addTearDown(sourceDb3.close);
      await sourceAfterReview.deletePrivateLesson(created.id);
      expect(
        (await sourceAfterReview.syncCoordinator.synchronize()).success,
        isTrue,
      );
      expect(await sourceAfterReview.getPrivateLessons(), isEmpty);
      await sourceDb3.close();

      final (secondDb3, secondAfterDelete) = await openDevice('second');
      addTearDown(secondDb3.close);
      expect(
        (await secondAfterDelete.syncCoordinator.synchronize()).success,
        isTrue,
      );
      expect(await secondAfterDelete.getPrivateLessons(), isEmpty);
      expect(
        (await secondAfterDelete.getPrivateLessons(
          includeDeleted: true,
        )).single.deleted,
        isTrue,
      );
      expect(
        (await secondAfterDelete.localDatabase.getCard(created.id))!.reps,
        repsAfterReview,
      );
      expect(
        (await secondDb3.getReviewLogs()).where((r) => r.itemId == created.id),
        hasLength(1),
      );
      await secondAfterDelete.restorePrivateLesson(created.id);
      expect(
        (await secondAfterDelete.syncCoordinator.synchronize()).success,
        isTrue,
      );
      await secondDb3.close();

      final (sourceDb4, sourceAfterRestore) = await openDevice('source');
      addTearDown(sourceDb4.close);
      expect(
        (await sourceAfterRestore.syncCoordinator.synchronize()).success,
        isTrue,
      );
      expect(
        (await sourceAfterRestore.getPrivateLesson(created.id))!.deleted,
        isFalse,
      );
      await sourceDb4.close();

      final thirdDb = LocalDatabase.instance;
      await thirdDb.close();
      await thirdDb.initCustom(customPath: '${directory.path}/isolated.sqlite');
      await thirdDb.initialize();
      addTearDown(thirdDb.close);
      final third = ApiService(baseUrl: backend, localDb: thirdDb);
      await third.configureServer(backend);
      await AccountService(
        apiService: third,
      ).register(username: 'other_$nonce', pin: '654321');
      expect((await third.syncCoordinator.synchronize()).success, isTrue);
      expect(await third.getPrivateLessons(includeDeleted: true), isEmpty);
      expect(
        (await third.getLessons()).where((l) => l.id == created.id),
        isEmpty,
      );
      expect(await third.getLessons(), hasLength(155));
    },
    skip: backend.isEmpty
        ? 'Use tests/private_vocabulary/run_live_tests.sh with disposable PostgreSQL'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

LessonItem _copyLesson(
  LessonItem lesson, {
  required String targetText,
  required String meaningVi,
}) => LessonItem(
  id: lesson.id,
  language: lesson.language,
  category: lesson.category,
  targetText: targetText,
  phoneticOrKana: lesson.phoneticOrKana,
  meaningVi: meaningVi,
  workplaceContext: lesson.workplaceContext,
  workplaceContextVi: lesson.workplaceContextVi,
  strokeOrderHints: lesson.strokeOrderHints,
  difficultyLevel: lesson.difficultyLevel,
);
