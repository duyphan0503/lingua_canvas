import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:app/services/local_database.dart';
import 'package:app/services/storage/local_store.dart';
import 'package:app/services/phase3_lessons.dart';
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
  test(
    'shared contract saves lessons and clears only current learning',
    () async {
      final LocalStore store = db;
      final lesson = phase3Lessons.first;
      await store.saveLesson(lesson);
      await store.setSyncSequence(7);
      expect((await store.getLesson(lesson.id))!.toJson(), lesson.toJson());
      await store.clearCurrentProfile();
      expect(await store.getLessons(), isEmpty);
      expect(await store.getSyncSequence(), isNull);
    },
  );
  test(
    'scoped reset preserves account installation and inactive queue',
    () async {
      final sync = SyncCoordinator(localDb: db);
      final client = await db.getOrCreateClientId();
      await sync.reviewCardOffline(
        itemId: 'anonymous',
        rating: FSRSRating.good,
      );
      final account = {
        'user_id': 'usr_a',
        'sync_token': 'lct_a',
        'server_url': 'http://test/api/v1',
      };
      await sync.changeAccount(account);
      await sync.reviewCardOffline(itemId: 'alice', rating: FSRSRating.good);
      await db.clearCurrentProfile();
      expect((await db.getAccount())!['user_id'], 'usr_a');
      expect(await db.getOrCreateClientId(), client);
      expect(await db.getPendingMutations(), isEmpty);
      await sync.changeAccount(null);
      expect(
        (await db.getPendingMutations()).single.payload['item_id'],
        'anonymous',
      );
    },
  );
}
