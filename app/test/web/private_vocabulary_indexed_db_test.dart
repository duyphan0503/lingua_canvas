@TestOn('browser')
library;

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/storage/browser_local_store.dart';
import 'package:app/services/storage/indexed_db_persistence.dart';
import 'package:app/services/storage/snapshot_persistence.dart';
import '../storage/private_vocabulary_test.dart' show word;

void main() {
  String name() => 'lingua_private_${DateTime.now().microsecondsSinceEpoch}';
  test(
    'real IndexedDB private CRUD and transaction abort preserve durable word/outbox',
    () async {
      final dbName = name();
      final disk = await IndexedDbSnapshotPersistence.open(
        databaseName: dbName,
      );
      final store = BrowserLocalStore(
        persistence: disk,
        initialBackend: 'http://test/api/v1',
      );
      await store.initialize();
      await store.switchAccount({
        'user_id': 'alice',
        'server_url': 'http://test/api/v1',
        'sync_token': 'secret',
      });
      await store.savePrivateLesson(word('custom_ja_a'));
      disk.abortNextSaveForTesting = true;
      await expectLater(
        store.deletePrivateLesson('custom_ja_a'),
        throwsA(isA<BrowserStorageException>()),
      );
      expect((await store.getPrivateLessons()).single.deleted, isFalse);
      expect((await store.getPendingMutations()).length, 1);
      await store.close();
      final reopened = BrowserLocalStore(
        persistence: await IndexedDbSnapshotPersistence.open(
          databaseName: dbName,
        ),
      );
      await reopened.initialize();
      expect(
        (await reopened.getPrivateLessons()).single.lesson.workplaceContextVi,
        'Tôi sẽ trao đổi',
      );
      expect(
        (await reopened.getPendingMutations()).single.payload['deleted'],
        isFalse,
      );
      await reopened.close();
    },
  );
  test(
    'real IndexedDB aborted v1 migration preserves old snapshot then retries all profiles',
    () async {
      final dbName = name();
      final disk = await IndexedDbSnapshotPersistence.open(
        databaseName: dbName,
      );
      final old = 'custom_ja_${'x' * 90}';
      Map<String, dynamic> profile() => {
        'metadata': <String, dynamic>{},
        'lessons': {old: word(old).toJson()},
        'cards': <String, dynamic>{},
        'logs': <String, dynamic>{},
        'queue': <String, dynamic>{},
        'completions': <String, dynamic>{},
        'activity': <String, dynamic>{},
        'next_queue_id': 1,
      };
      await disk.save({
        'version': 1,
        'client_id': 'client_original',
        'active_backend': 'http://test/api/v1',
        'active_profiles': {'http://test/api/v1': 'alice'},
        'profiles': {
          jsonEncode(['http://test/api/v1', 'default_user']): profile(),
          jsonEncode(['http://test/api/v1', 'alice']): profile(),
        },
      });
      final store = BrowserLocalStore(persistence: disk);
      disk.abortNextSaveForTesting = true;
      await expectLater(
        store.initialize(),
        throwsA(isA<BrowserStorageException>()),
      );
      expect((await disk.load())!['version'], 1);
      await store.initialize();
      expect((await disk.load())!['version'], 2);
      expect(
        (await store.getPrivateLessons()).single.lesson.id.length,
        lessThanOrEqualTo(64),
      );
      expect(
        (await store.getPendingMutations()).single.mutationType,
        'custom_lesson',
      );
      await store.switchAccount(null);
      expect(
        (await store.getPrivateLessons()).single.lesson.id.length,
        lessThanOrEqualTo(64),
      );
      expect(await store.getPendingMutations(), isEmpty);
      expect(await store.getOrCreateClientId(), 'client_original');
      await store.close();
    },
  );
  test(
    'real IndexedDB backup merge abort leaves target and guest source untouched',
    () async {
      final dbName = name();
      final disk = await IndexedDbSnapshotPersistence.open(
        databaseName: dbName,
      );
      final store = BrowserLocalStore(
        persistence: disk,
        initialBackend: 'http://test/api/v1',
      );
      await store.initialize();
      await store.savePrivateLesson(word('custom_ja_a'));
      await store.switchAccount({
        'user_id': 'alice',
        'server_url': 'http://test/api/v1',
        'sync_token': 'secret',
      });
      final backup = await store.exportGuestBackup();
      final preview = await store.previewProfileBackup(backup);
      disk.abortNextSaveForTesting = true;
      await expectLater(
        store.mergeProfileBackup(preview),
        throwsA(isA<BrowserStorageException>()),
      );
      expect(await store.getPrivateLessons(), isEmpty);
      expect(
        (await store.exportGuestBackup()).privateLessons.single.lesson.id,
        'custom_ja_a',
      );
      await store.close();
    },
  );
}
