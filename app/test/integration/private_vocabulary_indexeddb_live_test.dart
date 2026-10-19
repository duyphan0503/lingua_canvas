@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/lesson_item.dart';
import 'package:app/services/account_service.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/storage/browser_local_store.dart';
import 'package:app/services/storage/indexed_db_persistence.dart';

const backend = String.fromEnvironment('PRIVATE_VOCABULARY_TEST_API_BASE');

void main() {
  test(
    'IndexedDB devices sync private state and idempotent backup progress through PostgreSQL',
    () async {
      final nonce = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
      Future<BrowserLocalStore> open(String suffix) async {
        final store = BrowserLocalStore(
          persistence: await IndexedDbSnapshotPersistence.open(
            databaseName: 'private_live_${nonce}_$suffix',
          ),
          initialBackend: backend,
        );
        await store.initialize();
        addTearDown(store.close);
        return store;
      }

      final sourceDb = await open('source');
      final source = ApiService(baseUrl: backend, localDb: sourceDb);
      await AccountService(
        apiService: source,
      ).register(username: 'webp_$nonce', pin: '123456');
      final token = (await sourceDb.getAccount())!['sync_token'] as String;
      final first = await source.createPrivateLesson(
        word: '予約確認$nonce',
        language: 'ja',
        meaningVi: 'Nghĩa riêng $nonce',
        phoneticOrKana: 'よやくかくにん',
        workplaceContext: '明日の予約を確認します。',
        workplaceContextVi: 'Tôi sẽ xác nhận lịch hẹn ngày mai.',
        strokeOrderHints: const ['Đọc câu', 'Xác nhận thông tin'],
        difficultyLevel: 3,
      );
      final secondWord = await source.createPrivateLesson(
        word: '在庫確認$nonce',
        language: 'ja',
        meaningVi: 'Kiểm tra tồn kho $nonce',
        phoneticOrKana: 'ざいこかくにん',
        workplaceContext: '在庫を確認します。',
        workplaceContextVi: 'Tôi sẽ kiểm tra tồn kho.',
        strokeOrderHints: const ['Kiểm tra số lượng'],
        difficultyLevel: 2,
      );
      expect((await source.syncCoordinator.synchronize()).success, isTrue);

      final secondDb = await open('second');
      final second = ApiService(baseUrl: backend, localDb: secondDb);
      await AccountService(apiService: second).login(syncToken: token);
      expect((await second.syncCoordinator.synchronize()).success, isTrue);
      expect((await second.getPrivateLessons()), hasLength(2));

      final remoteEdit = _copyLesson(
        first,
        targetText: '予約を変更$nonce',
        meaningVi: 'Sửa từ thiết bị trình duyệt thứ hai',
      );
      await second.savePrivateLesson(remoteEdit);
      expect((await second.syncCoordinator.synchronize()).success, isTrue);
      final localEdit = _copyLesson(
        first,
        targetText: '予約を取り消す$nonce',
        meaningVi: 'Sửa ngoại tuyến ở trình duyệt thứ nhất',
      );
      await source.savePrivateLesson(localEdit);
      final conflictResult = await source.syncCoordinator.synchronize();
      expect(conflictResult.success, isTrue, reason: conflictResult.error);
      expect((await source.getPrivateLesson(first.id))!.conflict, isNotNull);
      await source.resolvePrivateLessonConflict(first.id, keepLocal: true);
      expect((await source.syncCoordinator.synchronize()).success, isTrue);
      expect((await second.syncCoordinator.synchronize()).success, isTrue);
      expect(
        (await second.getPrivateLesson(first.id))!.lesson.meaningVi,
        localEdit.meaningVi,
      );

      final firstReviewAt = DateTime.now().toUtc().subtract(
        const Duration(seconds: 4),
      );
      await source.syncCoordinator.reviewCardOffline(
        itemId: first.id,
        rating: FSRSRating.good,
        reviewTime: firstReviewAt,
      );
      final firstBackup = ProfileBackup.fromBytes(
        (await source.exportProfileBackup()).toBytes(),
      );
      final preview = await second.previewProfileBackup(firstBackup);
      await second.mergeProfileBackup(preview);
      expect((await second.syncCoordinator.synchronize()).success, isTrue);
      expect((await second.localDatabase.getCard(first.id))!.reps, 1);
      expect((await source.syncCoordinator.synchronize()).success, isTrue);
      expect((await second.syncCoordinator.synchronize()).success, isTrue);
      expect((await second.localDatabase.getCard(first.id))!.reps, 1);

      final secondReviewAt = DateTime.now().toUtc().subtract(
        const Duration(seconds: 2),
      );
      await source.syncCoordinator.reviewCardOffline(
        itemId: secondWord.id,
        rating: FSRSRating.good,
        reviewTime: secondReviewAt,
      );
      final secondBackup = ProfileBackup.fromBytes(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode((await source.exportProfileBackup()).toJson()),
          ),
        ),
      );
      expect((await source.syncCoordinator.synchronize()).success, isTrue);
      final secondPreview = await second.previewProfileBackup(secondBackup);
      await second.mergeProfileBackup(secondPreview);
      expect((await second.syncCoordinator.synchronize()).success, isTrue);
      final repeatPreview = await second.previewProfileBackup(secondBackup);
      await second.mergeProfileBackup(repeatPreview);
      expect((await second.syncCoordinator.synchronize()).success, isTrue);
      expect((await second.localDatabase.getCard(secondWord.id))!.reps, 1);
      expect((await second.localDatabase.getCard(first.id))!.reps, 1);
      final history = await secondDb.getReviewLogs();
      expect(history.where((r) => r.itemId == first.id), hasLength(1));
      expect(history.where((r) => r.itemId == secondWord.id), hasLength(1));

      await source.deletePrivateLesson(first.id);
      expect((await source.syncCoordinator.synchronize()).success, isTrue);
      expect((await second.syncCoordinator.synchronize()).success, isTrue);
      expect(await second.getPrivateLessons(), hasLength(1));
      expect(
        (await second.getPrivateLessons(
          includeDeleted: true,
        )).singleWhere((s) => s.lesson.id == first.id).deleted,
        isTrue,
      );
      expect((await second.localDatabase.getCard(first.id))!.reps, 1);
      expect(
        (await secondDb.getReviewLogs()).where((r) => r.itemId == first.id),
        hasLength(1),
      );
      await second.restorePrivateLesson(first.id);
      expect((await second.syncCoordinator.synchronize()).success, isTrue);
      expect((await source.syncCoordinator.synchronize()).success, isTrue);
      expect((await source.getPrivateLesson(first.id))!.deleted, isFalse);

      final isolatedDb = await open('isolated');
      final isolated = ApiService(baseUrl: backend, localDb: isolatedDb);
      await AccountService(
        apiService: isolated,
      ).register(username: 'webq_$nonce', pin: '654321');
      expect((await isolated.syncCoordinator.synchronize()).success, isTrue);
      expect(await isolated.getPrivateLessons(includeDeleted: true), isEmpty);
      expect(
        (await isolated.getLessons()).where(
          (lesson) => lesson.id == first.id || lesson.id == secondWord.id,
        ),
        isEmpty,
      );
      expect(await isolated.getLessons(), hasLength(355));

      final crossAccountPreview = await isolated.previewProfileBackup(
        ProfileBackup.fromBytes(firstBackup.toBytes()),
      );
      expect(crossAccountPreview.additions, greaterThan(0));
      expect(await isolated.getPrivateLessons(), isEmpty);
      await isolated.mergeProfileBackup(crossAccountPreview);
      expect(await isolated.getPrivateLessons(), hasLength(2));
      expect((await isolated.syncCoordinator.synchronize()).success, isTrue);
      expect((await isolated.localDatabase.getCard(first.id))!.reps, 1);
      expect(await isolated.localDatabase.getCard(secondWord.id), isNull);
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
