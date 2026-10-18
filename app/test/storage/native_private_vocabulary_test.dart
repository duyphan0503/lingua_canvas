import 'dart:convert';
import 'dart:io';
import 'package:app/services/local_database.dart';
import 'package:app/models/private_lesson_state.dart';
import 'package:app/models/profile_backup.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'private_vocabulary_test.dart' show word, remote;

void main() {
  late LocalDatabase db;
  setUp(() async {
    LocalDatabase.initFfiIfNeeded();
    db = LocalDatabase.instance;
    await db.initCustom(customPath: inMemoryDatabasePath);
  });
  tearDown(() => db.close());
  test(
    'SQLite private metadata, tombstones, ACK and profile isolation survive',
    () async {
      await db.selectBackend('http://test/api/v1');
      await db.savePrivateLesson(word('custom_ja_guest'));
      await db.saveCard(FSRSCard.initial('custom_ja_guest'));
      await db.switchAccount({
        'user_id': 'alice',
        'server_url': 'http://test/api/v1',
        'sync_token': 'secret',
      });
      await db.savePrivateLesson(word('custom_ja_a'));
      final q = (await db.getPendingMutations()).single;
      await db.markMutationsInProgress([q.id]);
      await db.deletePrivateLesson('custom_ja_a');
      await db.applyPrivateLessonSync(
        acks: [
          PrivateLessonAck(
            mutationId: q.payload['mutation_id'],
            state: PrivateLessonWireState.fromJson(
              remote(word('custom_ja_a'), 1),
            ),
          ),
        ],
      );
      expect((await db.getPrivateLesson('custom_ja_a'))!.deleted, isTrue);
      expect(
        (await db.getPendingMutations()).single.payload['base_revision'],
        1,
      );
      await db.restorePrivateLesson('custom_ja_a');
      expect((await db.getLesson('custom_ja_a'))!.targetText, '相談');
      expect(
        (await db.exportGuestBackup()).privateLessons.single.lesson.id,
        'custom_ja_guest',
      );
      await db.selectBackend('http://other/api/v1');
      expect(await db.getPrivateLessons(), isEmpty);
      await db.savePrivateLesson(word('custom_ja_other'));
      await db.selectBackend('http://test/api/v1');
      expect((await db.getPrivateLessons()).single.lesson.id, 'custom_ja_a');
      await db.switchAccount(null);
      expect((await db.getCard('custom_ja_guest'))!.reps, 0);
    },
  );
  test(
    'SQLite v4 migration rewrites inactive snapshot IDs and durable aliases',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lingua_migration_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/legacy.db';
      // Build the actual old schema from a current store then remove additive v5 structures.
      await db.close();
      await db.initCustom(customPath: path);
      await db.selectBackend('http://test/api/v1');
      final oldId = 'custom_ja_${'x' * 90}';
      await db.saveLesson(word(oldId));
      await db.saveCard(FSRSCard.initial(oldId));
      await db.enqueueMutation(
        mutationType: 'review',
        payload: {'review_id': 'immutable', 'item_id': oldId},
      );
      await db.switchAccount({
        'user_id': 'alice',
        'server_url': 'http://test/api/v1',
        'sync_token': 'secret',
      });
      final sql = await db.database;
      await sql.execute('DROP TABLE local_private_profile');
      await sql.execute('ALTER TABLE local_sync_queue DROP COLUMN sent');
      await sql.setVersion(4);
      await db.close();
      await db.initCustom(customPath: path);
      expect(await (await db.database).getVersion(), 5);
      await db.switchAccount(null);
      final state = (await db.getPrivateLessons()).single;
      expect(state.lesson.id.length, lessThanOrEqualTo(64));
      expect((await db.getCard(state.lesson.id))!.itemId, state.lesson.id);
      final queue = (await db.getPendingMutations()).single;
      expect(queue.payload['item_id'], state.lesson.id);
      expect(queue.payload['review_id'], 'immutable');
      final p = await db.readPrivateProfile();
      expect((p['aliases'] as Map)[oldId], state.lesson.id);
      expect(jsonEncode(p), isNot(contains('"item_id":"$oldId"')));
    },
  );
  test(
    'SQLite failed v4 upgrade leaves original database version and rows retryable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lingua_failed_upgrade_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/legacy.db';
      await db.close();
      await db.initCustom(customPath: path);
      await db.saveLesson(word('custom_ja_legacy'));
      final sql = await db.database;
      await sql.execute('DROP TABLE local_private_profile');
      await sql.execute('ALTER TABLE local_sync_queue DROP COLUMN sent');
      await sql.execute(
        "CREATE TRIGGER prevent_migration BEFORE DELETE ON local_lessons BEGIN SELECT RAISE(ABORT, 'simulated save failure'); END",
      );
      await sql.setVersion(4);
      await db.close();
      await expectLater(
        db.initCustom(customPath: path),
        throwsA(isA<DatabaseException>()),
      );
      final original = await databaseFactory.openDatabase(path);
      expect(await original.getVersion(), 4);
      expect(
        (await original.query('local_lessons')).single['id'],
        'custom_ja_legacy',
      );
      expect(
        (await original.rawQuery(
          "SELECT name FROM sqlite_master WHERE name='local_private_profile'",
        )),
        isEmpty,
      );
      await original.execute('DROP TRIGGER prevent_migration');
      await original.close();
      await db.initCustom(customPath: path);
      expect(
        (await db.getPrivateLessons()).single.lesson.id,
        'custom_ja_legacy',
      );
    },
  );

  test('SQLite profile reset invalidates an empty preview', () async {
    final preview = await db.previewProfileBackup(
      await db.exportProfileBackup(),
    );
    await db.clearCurrentProfile();
    await expectLater(
      db.mergeProfileBackup(preview),
      throwsA(isA<StaleProfileMergeException>()),
    );
  });
}
