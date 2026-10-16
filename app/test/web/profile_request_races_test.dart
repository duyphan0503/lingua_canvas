import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:app/models/lesson_item.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/storage/browser_local_store.dart';
import 'package:app/services/sync_coordinator.dart';
import '../helpers/memory_snapshot_persistence.dart';

class DelayedSnapshot extends MemorySnapshotPersistence {
  Completer<void>? started;
  Completer<void>? release;
  void delayNextSave() {
    started = Completer<void>();
    release = Completer<void>();
  }

  @override
  Future<void> save(Map<String, dynamic> snapshot) async {
    if (started != null && !started!.isCompleted) {
      started!.complete();
      await release!.future;
    }
    await super.save(snapshot);
  }
}

void main() {
  const a = 'http://a.test/api/v1';
  const b = 'http://b.test/api/v1';
  test('sync during durable backend switch never sends B queue to A', () async {
    final disk = DelayedSnapshot();
    final store = BrowserLocalStore(persistence: disk, initialBackend: b);
    await store.initialize();
    await SyncCoordinator(
      localDb: store,
    ).reviewCardOffline(itemId: 'b_private', rating: FSRSRating.good);
    await store.selectBackend(a);
    final requests = <http.Request>[];
    await http.runWithClient(
      () async {
        final api = ApiService(localDb: store, baseUrl: a);
        disk.delayNextSave();
        final switching = api.configureServer(b);
        await disk.started!.future;
        final syncing = api.sync();
        disk.release!.complete();
        await switching;
        await syncing;
        expect(requests.map((r) => r.url.host), isNot(contains('a.test')));
        expect(
          (await store.getPendingMutations()).single.payload['item_id'],
          'b_private',
        );
      },
      () => MockClient((r) async {
        requests.add(r);
        return http.Response('{}', 503);
      }),
    );
    await store.close();
  });
  test(
    'catalogue response cannot overwrite the next backend profile',
    () async {
      final store = BrowserLocalStore(
        persistence: MemorySnapshotPersistence(),
        initialBackend: a,
      );
      await store.initialize();
      final started = Completer<void>();
      final response = Completer<http.Response>();
      await http.runWithClient(
        () async {
          final api = ApiService(localDb: store, baseUrl: a);
          final loading = api.getLessons();
          await started.future;
          var switched = false;
          final switching = api.configureServer(b).then((_) => switched = true);
          await Future<void>.delayed(Duration.zero);
          response.complete(
            http.Response(
              jsonEncode([
                LessonItem(
                  id: 'a_only',
                  language: 'en',
                  category: 'custom',
                  targetText: 'private',
                  phoneticOrKana: '',
                  meaningVi: 'A private',
                  workplaceContext: '',
                  workplaceContextVi: '',
                  strokeOrderHints: const [],
                  difficultyLevel: 1,
                ).toJson(),
              ]),
              200,
            ),
          );
          await loading;
          await switching;
          expect(switched, isTrue);
          expect(
            (await store.getLessons()).map((l) => l.id),
            isNot(contains('a_only')),
          );
          await api.configureServer(a);
          expect(
            (await store.getLessons())
                .singleWhere((l) => l.id == 'a_only')
                .meaningVi,
            'A private',
          );
        },
        () => MockClient((r) {
          started.complete();
          return response.future;
        }),
      );
      await store.close();
    },
  );
}
