import 'dart:convert';
import 'package:app/services/storage/browser_local_store.dart';
import 'package:app/services/sync_coordinator.dart';
import 'package:app/models/lesson_item.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../helpers/memory_snapshot_persistence.dart';
import '../storage/private_vocabulary_test.dart' show word;

void main() {
  test(
    'catalog version is persisted after its snapshot and scoped to backend',
    () async {
      final store = BrowserLocalStore(
        persistence: MemorySnapshotPersistence(),
        initialBackend: 'http://test/api/v1',
      );
      await store.initialize();
      var pulls = 0;
      final sync = SyncCoordinator(
        localDb: store,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient((r) async {
          expect(r.method, 'GET');
          if (pulls++ == 0) {
            expect(r.url.queryParameters['catalog_version'], '0');
            return http.Response(
              jsonEncode({
                'catalog_version': 'catalog1',
                'catalog_complete': true,
                'lessons': [
                  {...word('ja_public').toJson(), 'category': 'hiragana'},
                ],
                'latest_sync_seq': 3,
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          expect(r.url.queryParameters['catalog_version'], 'catalog1');
          return http.Response(
            jsonEncode({
              'catalog_version': 'catalog1',
              'lessons': [],
              'latest_sync_seq': 3,
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final initial = await sync.synchronize();
      expect(initial.success, isTrue, reason: initial.error);
      expect(await store.getMetadata('catalog_version'), 'catalog1');
      expect((await sync.synchronize()).pulledLessons, 0);
      await store.selectBackend('http://other/api/v1');
      expect(await store.getMetadata('catalog_version'), isNull);
      await store.selectBackend('http://test/api/v1');
      expect(await store.getMetadata('catalog_version'), 'catalog1');
    },
  );

  test(
    'failed catalog snapshot commit does not acknowledge its version',
    () async {
      final persistence = MemorySnapshotPersistence();
      final store = BrowserLocalStore(
        persistence: persistence,
        initialBackend: 'http://test/api/v1',
      );
      await store.initialize();
      await store.setMetadata('catalog_version', 'old');
      final sync = SyncCoordinator(
        localDb: store,
        baseUrl: 'http://test/api/v1',
        httpClient: MockClient((r) async {
          persistence.nextSaveError = StateError('quota exceeded');
          return http.Response(
            jsonEncode({
              'catalog_version': 'new',
              'catalog_complete': true,
              'lessons': [
                {...word('ja_public').toJson(), 'category': 'hiragana'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      expect((await sync.synchronize()).success, isFalse);
      expect(await store.getMetadata('catalog_version'), 'old');
      expect(await store.getLesson('ja_public'), isNull);
    },
  );

  test('authoritative empty catalog removes public rows and preserves private data and pending work', () async {
    final store = BrowserLocalStore(persistence: MemorySnapshotPersistence(), initialBackend: 'http://test/api/v1');
    await store.initialize();
    await store.saveLessons([LessonItem.fromJson({...word('ja_removed').toJson(), 'category':'hiragana'})]);
    await store.savePrivateLesson(word('custom_personal'));
    await store.saveCard(FSRSCard.initial('ja_removed'));
    await store.enqueueMutation(mutationType: 'future_operation', payload: {'keep':'pending'});
    final sync = SyncCoordinator(localDb: store, baseUrl:'http://test/api/v1', httpClient: MockClient((r) async => http.Response(jsonEncode({'catalog_version':'empty','catalog_complete':true,'lessons':[]}),200)));
    expect((await sync.synchronize()).success, isTrue);
    expect(await store.getLesson('ja_removed'), isNull);
    expect(await store.getPrivateLesson('custom_personal'), isNotNull);
    expect(await store.getCard('ja_removed'), isNotNull);
    expect((await store.getPendingMutations()).single.payload['keep'], 'pending');
    expect(await store.getMetadata('catalog_version'), 'empty');
  });
}
