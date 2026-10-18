import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/platform_capabilities.dart';
import 'package:app/services/storage/browser_local_store.dart';
import 'package:app/services/fsrs_engine.dart';
import '../helpers/memory_snapshot_persistence.dart';

void main() {
  test(
    'API defaults follow browser origin and preserve native/override defaults',
    () {
      expect(
        resolveApiBaseUrl(
          isWeb: true,
          pageUri: Uri.parse('https://learn.test/study/'),
        ),
        'https://learn.test/api/v1',
      );
      expect(
        resolveApiBaseUrl(
          isWeb: false,
          pageUri: Uri.parse('https://learn.test'),
        ),
        'http://127.0.0.1:8080/api/v1',
      );
      expect(
        resolveApiBaseUrl(
          isWeb: true,
          pageUri: Uri.parse('https://learn.test'),
          configured: 'https://api.test/api/v1',
        ),
        'https://api.test/api/v1',
      );
    },
  );
  test('mixed content malformed URLs and userinfo are rejected', () {
    for (final url in [
      'http://api.test/api/v1',
      'https://user:secret@api.test/api/v1',
      'https://api.test/api/v1?token=x',
      'ftp://api.test/',
    ]) {
      expect(
        () => normalizeApiBaseUrl(
          url,
          isWeb: true,
          pageUri: Uri.parse('https://learn.test'),
        ),
        throwsFormatException,
      );
    }
  });
  test('backend change isolates anonymous queues and restores them', () async {
    final store = BrowserLocalStore(
      persistence: MemorySnapshotPersistence(),
      initialBackend: 'http://a.test/api/v1',
    );
    await store.initialize();
    final api = ApiService(localDb: store, baseUrl: 'http://a.test/api/v1');
    await api.submitReview(itemId: 'a_private', rating: FSRSRating.good);
    await api.configureServer('http://b.test/api/v1/');
    expect(api.baseUrl, 'http://b.test/api/v1');
    expect(await store.getPendingMutations(), isEmpty);
    await api.submitReview(itemId: 'b_private', rating: FSRSRating.good);
    await api.configureServer('http://a.test/api/v1');
    expect(
      (await store.getPendingMutations()).single.payload['item_id'],
      'a_private',
    );
  });
  test(
    'failed storage leaves configured server and old queue unchanged',
    () async {
      final disk = MemorySnapshotPersistence();
      final store = BrowserLocalStore(
        persistence: disk,
        initialBackend: 'http://a.test/api/v1',
      );
      await store.initialize();
      final api = ApiService(localDb: store, baseUrl: 'http://a.test/api/v1');
      await api.submitReview(itemId: 'private', rating: FSRSRating.good);
      disk.nextSaveError = StateError('quota');
      await expectLater(
        api.configureServer('http://b.test/api/v1'),
        throwsStateError,
      );
      expect(api.baseUrl, 'http://a.test/api/v1');
      expect(
        (await store.getPendingMutations()).single.payload['item_id'],
        'private',
      );
    },
  );
}
