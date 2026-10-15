@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/account_service.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/storage/browser_local_store.dart';
import 'package:app/services/storage/indexed_db_persistence.dart';

const backend = String.fromEnvironment('WEB_TEST_API_BASE');

void main() {
  test(
    'durable browser reviews synchronize through HTTP and PostgreSQL',
    () async {
      final nonce = DateTime.now().microsecondsSinceEpoch.toString();
      Future<BrowserLocalStore> open(String name) async {
        final store = BrowserLocalStore(
          persistence: await IndexedDbSnapshotPersistence.open(
            databaseName: name,
          ),
          initialBackend: backend,
        );
        await store.initialize();
        addTearDown(store.close);
        return store;
      }

      var first = await open('web_live_${nonce}_a');
      var api = ApiService(baseUrl: backend, localDb: first);
      await AccountService(
        apiService: api,
      ).register(username: 'web_$nonce', pin: '123456');
      final account = (await first.getAccount())!;
      expect((account['devices'] as List).single['platform'], 'web');
      final clientId = await first.getOrCreateClientId();
      final now = DateTime.now().toUtc();
      for (final item in ['ja_hira_a', 'ja_hira_i']) {
        await api.syncCoordinator.reviewCardOffline(
          itemId: item,
          rating: FSRSRating.good,
          reviewTime: now,
        );
      }
      expect((await first.getPendingMutations()).length, 2);
      await first.close();
      first = await open('web_live_${nonce}_a');
      expect(await first.getOrCreateClientId(), clientId);
      expect((await first.getPendingMutations()).length, 2);
      api = ApiService(baseUrl: backend, localDb: first);
      final pushed = await api.syncCoordinator.synchronize();
      expect(pushed.success, isTrue, reason: pushed.error);
      expect(await first.getPendingMutations(), isEmpty);
      final second = await open('web_live_${nonce}_b');
      expect(await second.getOrCreateClientId(), isNot(clientId));
      final api2 = ApiService(baseUrl: backend, localDb: second);
      await AccountService(
        apiService: api2,
      ).login(syncToken: account['sync_token'] as String);
      final pulled = await api2.syncCoordinator.synchronize();
      expect(pulled.success, isTrue, reason: pulled.error);
      expect(
        (await second.getAllCards()).map((c) => c.itemId),
        containsAll(['ja_hira_a', 'ja_hira_i']),
      );
      expect(await second.getCompletedCount(), 2);
      expect((await api2.syncCoordinator.synchronize()).pulledCards, 0);
      await api2.syncCoordinator.reviewCardOffline(
      itemId: 'ja_hira_a', rating: FSRSRating.easy,
      reviewTime: now.add(const Duration(seconds: 2)), completionScore: 0.95,
    );
    expect((await api2.syncCoordinator.synchronize()).success, isTrue);
      expect((await api.syncCoordinator.synchronize()).success, isTrue);
      expect(
        (await first.getCompletedLessons())
            .firstWhere((l) => l.lessonId == 'ja_hira_a')
            .score,
        0.95,
      );
      final isolated = await open('web_live_${nonce}_c');
      final api3 = ApiService(baseUrl: backend, localDb: isolated);
      await AccountService(
        apiService: api3,
      ).register(username: 'other_$nonce', pin: '654321');
      expect((await api3.syncCoordinator.synchronize()).success, isTrue);
      expect(await isolated.getAllCards(), isEmpty);
      await expectLater(
        AccountService(apiService: api3).login(syncToken: 'invalid_token'),
        throwsA(isA<AccountException>()),
      );
    },
    skip: backend.isEmpty
        ? 'Run tests/web/run_browser_tests.sh with disposable PostgreSQL'
        : false,
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
