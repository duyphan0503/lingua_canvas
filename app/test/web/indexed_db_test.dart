@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'dart:js_interop';
import 'package:app/services/storage/indexed_db_persistence.dart';
import 'package:app/services/storage/browser_local_store.dart';
import 'package:app/services/storage/snapshot_persistence.dart';
import 'package:app/services/sync_coordinator.dart';
import 'package:app/services/fsrs_engine.dart';

void main() {
  test('unavailable IndexedDB never falls back to memory', () async {
    final disk = IndexedDbSnapshotPersistence(factoryForTesting: JSObject());
    await expectLater(
      disk.load(),
      throwsA(
        isA<BrowserStorageException>().having(
          (e) => e.code,
          'code',
          'unsupported',
        ),
      ),
    );
    await disk.close();
  });
  String name() => 'lingua_test_${DateTime.now().microsecondsSinceEpoch}';
  test('IndexedDB commits state and reopens it', () async {
    final dbName = name();
    final disk = await IndexedDbSnapshotPersistence.open(databaseName: dbName);
    final store = BrowserLocalStore(persistence: disk);
    await store.initialize();
    final client = await store.getOrCreateClientId();
    await SyncCoordinator(
      localDb: store,
    ).reviewCardOffline(itemId: 'ja_hira_a', rating: FSRSRating.good);
    await store.close();
    final reopened = BrowserLocalStore(
      persistence: await IndexedDbSnapshotPersistence.open(
        databaseName: dbName,
      ),
    );
    await reopened.initialize();
    expect((await reopened.getCard('ja_hira_a'))!.reps, 1);
    expect(await reopened.getOrCreateClientId(), client);
    expect((await reopened.getPendingMutations()).length, 1);
    await reopened.close();
  });
  test(
    'actual aborted transaction preserves the previous durable snapshot',
    () async {
      final dbName = name();
      final disk = await IndexedDbSnapshotPersistence.open(
        databaseName: dbName,
      );
      final store = BrowserLocalStore(persistence: disk);
      await store.initialize();
      disk.abortNextSaveForTesting = true;
      await expectLater(
        SyncCoordinator(
          localDb: store,
        ).reviewCardOffline(itemId: 'lost', rating: FSRSRating.good),
        throwsA(isA<BrowserStorageException>()),
      );
      expect(await store.getAllCards(), isEmpty);
      await store.close();
      final reopened = BrowserLocalStore(
        persistence: await IndexedDbSnapshotPersistence.open(
          databaseName: dbName,
        ),
      );
      await reopened.initialize();
      expect(await reopened.getAllCards(), isEmpty);
      expect(await reopened.getPendingMutations(), isEmpty);
      await reopened.close();
    },
  );
}
