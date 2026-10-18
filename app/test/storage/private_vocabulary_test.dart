import 'dart:convert';
import 'package:app/models/lesson_item.dart';
import 'package:app/models/private_lesson_state.dart';
import 'package:app/services/storage/browser_local_store.dart';
import 'package:app/services/storage/snapshot_persistence.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/memory_snapshot_persistence.dart';

LessonItem word(String id, [String text = '相談']) => LessonItem(
  id: id,
  language: 'ja',
  category: 'custom',
  targetText: text,
  phoneticOrKana: 'そうだん',
  meaningVi: 'Trao đổi',
  workplaceContext: '相談します',
  workplaceContextVi: 'Tôi sẽ trao đổi',
  strokeOrderHints: ['Nét 1'],
  difficultyLevel: 2,
);
Map<String, dynamic> remote(
  LessonItem lesson,
  int revision, {
  bool deleted = false,
}) => {
  'lesson': lesson.toJson(),
  'revision': revision,
  'deleted': deleted,
  'updated_at': '2026-10-01T00:00:00Z',
};
void main() {
  late MemorySnapshotPersistence persistence;
  late BrowserLocalStore store;
  setUp(() async {
    persistence = MemorySnapshotPersistence();
    store = BrowserLocalStore(
      persistence: persistence,
      initialBackend: 'http://test/api/v1',
    );
    await store.initialize();
  });
  Future<void> account() => store.switchAccount({
    'user_id': 'alice',
    'server_url': 'http://test/api/v1',
    'sync_token': 'secret',
  });
  test(
    'guest CRUD is durable, tombstones hide practice and restore card',
    () async {
      final lesson = word('custom_ja_one');
      await store.savePrivateLesson(lesson);
      expect(
        (await store.getPrivateLessons()).single.lesson.meaningVi,
        'Trao đổi',
      );
      expect(await store.getPendingMutations(), isEmpty);
      await store.deletePrivateLesson(lesson.id);
      expect(await store.getLessons(), isEmpty);
      expect(await store.getLesson(lesson.id), isNull);
      expect(
        (await store.getPrivateLessons(includeDeleted: true)).single.deleted,
        isTrue,
      );
      await store.restorePrivateLesson(lesson.id);
      expect((await store.getLesson(lesson.id))!.targetText, '相談');
      final reopened = BrowserLocalStore(persistence: persistence);
      await reopened.initialize();
      expect((await reopened.getPrivateLessons()).single.lesson.id, lesson.id);
    },
  );
  test(
    'late ACK preserves newer edit and rebases descendant identity',
    () async {
      await account();
      await store.savePrivateLesson(word('custom_ja_one'));
      final first = (await store.getPendingMutations()).single;
      await store.markMutationsInProgress([first.id]);
      await store.savePrivateLesson(word('custom_ja_one', '会議'));
      final second = (await store.getPendingMutations()).single;
      await store.applyPrivateLessonSync(
        acks: [
          PrivateLessonAck(
            mutationId: first.payload['mutation_id'],
            state: PrivateLessonWireState.fromJson(
              remote(word('custom_ja_one'), 1),
            ),
          ),
        ],
      );
      expect(
        (await store.getPrivateLesson('custom_ja_one'))!.lesson.targetText,
        '会議',
      );
      final queue = (await store.getPendingMutations()).single;
      expect(queue.id, second.id);
      expect(queue.payload['base_revision'], 1);
      expect(queue.payload['mutation_id'], second.payload['mutation_id']);
    },
  );
  test(
    'conflict blocks only the word, refreshes remote, and user chooses server',
    () async {
      await account();
      await store.savePrivateLesson(word('custom_ja_one'));
      final first = (await store.getPendingMutations()).single;
      await store.applyPrivateLessonSync(
        conflicts: [
          PrivateLessonSyncConflict(
            mutationId: first.payload['mutation_id'],
            server: PrivateLessonWireState.fromJson(
              remote(word('custom_ja_one', 'server'), 2),
            ),
          ),
        ],
      );
      await store.applyPrivateLessonSync(
        deltas: [
          PrivateLessonWireState.fromJson(
            remote(word('custom_ja_one', 'new server'), 3),
          ),
        ],
      );
      final conflict = (await store.getPrivateLesson(
        'custom_ja_one',
      ))!.conflict!;
      expect(conflict.local.lesson.targetText, '相談');
      expect(conflict.remote!.lesson.targetText, 'new server');
      await store.resolvePrivateLessonConflict(
        'custom_ja_one',
        keepLocal: false,
      );
      expect(
        (await store.getPrivateLesson('custom_ja_one'))!.lesson.targetText,
        'new server',
      );
      expect(await store.getPendingMutations(), isEmpty);
    },
  );
  test('failed atomic save publishes neither word nor outbox', () async {
    await account();
    persistence.nextSaveError = const BrowserStorageException('quota', 'full');
    await expectLater(
      store.savePrivateLesson(word('custom_ja_one')),
      throwsA(isA<BrowserStorageException>()),
    );
    expect(await store.getPrivateLessons(), isEmpty);
    expect(await store.getPendingMutations(), isEmpty);
  });
  test('catalog cache cannot overwrite personal metadata', () async {
    await store.savePrivateLesson(word('custom_ja_one'));
    await store.saveLessons([word('custom_ja_one', 'placeholder')]);
    expect((await store.getLesson('custom_ja_one'))!.targetText, '相談');
  });
  test(
    'v1 migrates inactive long IDs with every reference and immutable review ID',
    () async {
      final legacy = word('custom_ja_${'x' * 80}');
      await store.saveLessons([legacy]);
      await store.enqueueMutation(
        mutationType: 'review',
        payload: {'review_id': 'unchanged', 'item_id': legacy.id},
      );
      await account();
      final root =
          jsonDecode(jsonEncode(persistence.data)) as Map<String, dynamic>;
      root['version'] = 1;
      for (final p in (root['profiles'] as Map).values) {
        (p as Map).remove('private_lessons');
      }
      persistence.data = root;
      final migrated = BrowserLocalStore(persistence: persistence);
      await migrated.initialize();
      await migrated.switchAccount(null);
      final state = (await migrated.getPrivateLessons()).single;
      expect(state.lesson.id.length, lessThanOrEqualTo(64));
      expect(
        (await migrated.getPendingMutations()).single.payload['item_id'],
        state.lesson.id,
      );
      expect(
        (await migrated.getPendingMutations()).single.payload['review_id'],
        'unchanged',
      );
      expect(persistence.data!['version'], 2);
    },
  );
  test(
    'unknown response identity and mismatched conflict word never consume queue',
    () async {
      await account();
      await store.savePrivateLesson(word('custom_ja_a'));
      final q = (await store.getPendingMutations()).single;
      await store.applyPrivateLessonSync(
        acks: [
          PrivateLessonAck(
            mutationId: 'unknown',
            state: PrivateLessonWireState.fromJson(
              remote(word('custom_ja_a'), 1),
            ),
          ),
        ],
      );
      expect((await store.getPendingMutations()).length, 1);
      await expectLater(
        store.applyPrivateLessonSync(
          conflicts: [
            PrivateLessonSyncConflict(
              mutationId: q.payload['mutation_id'],
              server: PrivateLessonWireState.fromJson(
                remote(word('custom_ja_other'), 2),
              ),
            ),
          ],
        ),
        throwsFormatException,
      );
      expect((await store.getPrivateLesson('custom_ja_a'))!.conflict, isNull);
    },
  );
  test(
    'out of order ACK cannot erase a conflict from a newer server delta',
    () async {
      await account();
      await store.savePrivateLesson(word('custom_ja_a'));
      final first = (await store.getPendingMutations()).single;
      await store.markMutationsInProgress([first.id]);
      await store.savePrivateLesson(word('custom_ja_a', 'new local'));
      await store.applyPrivateLessonSync(
        deltas: [
          PrivateLessonWireState.fromJson(
            remote(word('custom_ja_a', 'remote2'), 2),
          ),
        ],
      );
      await store.applyPrivateLessonSync(
        acks: [
          PrivateLessonAck(
            mutationId: first.payload['mutation_id'],
            state: PrivateLessonWireState.fromJson(
              remote(word('custom_ja_a'), 1),
            ),
          ),
        ],
      );
      final conflict = (await store.getPrivateLesson('custom_ja_a'))!.conflict!;
      expect(conflict.local.lesson.targetText, 'new local');
      expect(conflict.remote!.revision, 2);
      await store.resolvePrivateLessonConflict('custom_ja_a', keepLocal: true);
      expect(
        (await store.getPendingMutations()).single.payload['base_revision'],
        2,
      );
      expect(
        (await store.getPrivateLesson('custom_ja_a'))!.lesson.targetText,
        'new local',
      );
    },
  );

  test(
    'incomplete v2 snapshot is rejected without overwriting durable data',
    () async {
      final root =
          jsonDecode(jsonEncode(persistence.data)) as Map<String, dynamic>;
      for (final p in (root['profiles'] as Map).values) {
        (p as Map).remove('private_lessons');
      }
      persistence.data = root;
      final broken = BrowserLocalStore(persistence: persistence);
      await expectLater(
        broken.initialize(),
        throwsA(isA<BrowserStorageException>()),
      );
      expect(persistence.data, root);
    },
  );
}
