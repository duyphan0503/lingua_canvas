import 'dart:convert';
import 'dart:typed_data';
import 'package:app/models/profile_backup.dart';
import 'package:app/services/storage/browser_local_store.dart';
import 'package:app/services/storage/snapshot_persistence.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/models/private_lesson_state.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/memory_snapshot_persistence.dart';
import 'private_vocabulary_test.dart' show word;

void main() {
  late BrowserLocalStore store;
  late MemorySnapshotPersistence persistence;
  setUp(() async {
    persistence = MemorySnapshotPersistence();
    store = BrowserLocalStore(
      persistence: persistence,
      initialBackend: 'http://test/api/v1',
    );
    await store.initialize();
  });
  test(
    'backup excludes credentials and raw queue; merge is explicit and idempotent',
    () async {
      await store.savePrivateLesson(word('custom_ja_a'));
      await store.saveCard(FSRSCard.initial('custom_ja_a'));
      final backup = await store.exportProfileBackup();
      expect(utf8.decode(backup.toBytes()), isNot(contains('sync_token')));
      expect(utf8.decode(backup.toBytes()), isNot(contains('queue')));
      await store.switchAccount({
        'user_id': 'alice',
        'server_url': 'http://test/api/v1',
        'sync_token': 'secret',
      });
      final preview = await store.previewProfileBackup(backup);
      expect(await store.getPrivateLessons(), isEmpty);
      expect(preview.additions, greaterThan(0));
      await store.mergeProfileBackup(preview);
      expect((await store.getPrivateLessons()).single.lesson.id, 'custom_ja_a');
      final before = (await store.getPendingMutations()).length;
      await store.mergeProfileBackup(await store.previewProfileBackup(backup));
      expect((await store.getPendingMutations()).length, before);
      expect(
        (await store.exportGuestBackup()).privateLessons.single.lesson.id,
        'custom_ja_a',
      );
    },
  );
  test(
    'preview binding rejects content change and switch away and back',
    () async {
      await store.savePrivateLesson(word('custom_ja_a'));
      final backup = await store.exportProfileBackup();
      final preview = await store.previewProfileBackup(backup);
      await store.savePrivateLesson(word('custom_ja_b'));
      await expectLater(
        store.mergeProfileBackup(preview),
        throwsA(isA<StaleProfileMergeException>()),
      );
      final fresh = await store.previewProfileBackup(backup);
      await store.switchAccount({
        'user_id': 'alice',
        'server_url': 'http://test/api/v1',
        'sync_token': 'secret',
      });
      await store.switchAccount(null);
      await expectLater(
        store.mergeProfileBackup(fresh),
        throwsA(isA<StaleProfileMergeException>()),
      );
    },
  );
  test(
    'invalid and unknown backup reject whole payload before write',
    () async {
      await expectLater(
        Future(
          () => ProfileBackup.fromBytes(
            Uint8List.fromList(
              utf8.encode('{"format":"lingua_canvas_backup","version":9}'),
            ),
          ),
        ),
        throwsFormatException,
      );
      await expectLater(
        Future(() => ProfileBackup.fromBytes(Uint8List(10 * 1024 * 1024 + 1))),
        throwsFormatException,
      );
      await store.savePrivateLesson(word('custom_ja_a'));
      final json =
          jsonDecode(utf8.decode((await store.exportProfileBackup()).toBytes()))
              as Map<String, dynamic>;
      json['cards'] = [
        {'item_id': 'unknown'},
      ];
      await expectLater(
        Future(
          () => ProfileBackup.fromBytes(
            Uint8List.fromList(utf8.encode(jsonEncode(json))),
          ),
        ),
        throwsFormatException,
      );
      expect((await store.getPrivateLessons()).length, 1);
    },
  );
  test('atomic merge rollback leaves destination unchanged on quota', () async {
    await store.savePrivateLesson(word('custom_ja_a'));
    final backup = await store.exportProfileBackup();
    await store.switchAccount({
      'user_id': 'alice',
      'server_url': 'http://test/api/v1',
      'sync_token': 'secret',
    });
    final preview = await store.previewProfileBackup(backup);
    persistence.nextSaveError = const BrowserStorageException('quota', 'full');
    await expectLater(
      store.mergeProfileBackup(preview),
      throwsA(isA<BrowserStorageException>()),
    );
    expect(await store.getPrivateLessons(), isEmpty);
    expect(await store.getPendingMutations(), isEmpty);
  });
  test(
    'guest selection includes only selected word and associated progress',
    () async {
      await store.savePrivateLesson(word('custom_ja_a'));
      await store.savePrivateLesson(word('custom_ja_b'));
      await store.saveCard(FSRSCard.initial('custom_ja_b'));
      await store.switchAccount({
        'user_id': 'alice',
        'server_url': 'http://test/api/v1',
        'sync_token': 'secret',
      });
      final selected = await store.exportGuestBackup(
        lessonIds: {'custom_ja_a'},
      );
      expect(selected.privateLessons.single.lesson.id, 'custom_ja_a');
      expect(selected.cards, isEmpty);
      expect(await store.getPrivateLessons(), isEmpty);
    },
  );
  test(
    'import metadata conflict chooses imported version and queues destination revision',
    () async {
      await store.savePrivateLesson(word('custom_ja_a', 'imported'));
      final backup = await store.exportProfileBackup();
      await store.switchAccount({
        'user_id': 'alice',
        'server_url': 'http://test/api/v1',
        'sync_token': 'secret',
      });
      await store.savePrivateLesson(word('custom_ja_a', 'destination'));
      await store.mergeProfileBackup(await store.previewProfileBackup(backup));
      expect(
        (await store.getPrivateLesson('custom_ja_a'))!.conflict,
        isNotNull,
      );
      await store.resolvePrivateLessonConflict('custom_ja_a', keepLocal: false);
      expect(
        (await store.getPrivateLesson('custom_ja_a'))!.lesson.targetText,
        'imported',
      );
      final queue = await store.getPendingMutations();
      expect(queue.single.payload['lesson']['target_text'], 'imported');
      expect(queue.single.payload['base_revision'], 0);
    },
  );
  test('server delta refreshes remote candidate in backup conflict', () async {
    await store.savePrivateLesson(word('custom_ja_a', 'guest copy'));
    final backup = await store.exportProfileBackup();
    await store.switchAccount({
      'user_id': 'alice',
      'server_url': 'http://test/api/v1',
      'sync_token': 'secret',
    });
    await store.savePrivateLesson(word('custom_ja_a', 'account copy'));
    await store.mergeProfileBackup(await store.previewProfileBackup(backup));
    await store.applyPrivateLessonSync(
      deltas: [
        PrivateLessonWireState(
          lesson: word('custom_ja_a', 'latest server copy'),
          revision: 5,
          deleted: false,
          updatedAt: DateTime.utc(2026, 10, 1),
        ),
      ],
    );
    final conflict = (await store.getPrivateLesson('custom_ja_a'))!.conflict!;
    expect(conflict.fromBackup, isTrue);
    expect(conflict.remote!.revision, 5);
    await store.resolvePrivateLessonConflict('custom_ja_a', keepLocal: false);
    expect(
      (await store.getPrivateLesson('custom_ja_a'))!.lesson.targetText,
      'latest server copy',
    );
    expect((await store.getPrivateLesson('custom_ja_a'))!.revision, 5);
  });

  test(
    'local-calendar daily activity date is not treated as a future instant',
    () async {
      final backup = ProfileBackup(
        backupId: 'calendar-boundary',
        createdAt: DateTime.utc(2026, 10, 16, 21),
        privateLessons: const [],
        cards: const [],
        reviewLogs: const [],
        completedLessons: const [],
        dailyActivity: const {'2026-10-17': 1},
      );
      expect(
        ProfileBackup.fromJson(
          backup.toJson(),
          now: DateTime.utc(2026, 10, 16, 22),
        ).dailyActivity,
        {'2026-10-17': 1},
      );
    },
  );
  test(
    'merge preserves destination pending review and imports immutable history without replay',
    () async {
      await store.savePrivateLesson(word('custom_ja_a'));
      await store.saveCard(
        FSRSCard(
          itemId: 'custom_ja_a',
          state: FSRSState.review,
          stability: 12,
          difficulty: 5,
          reps: 12,
          lapses: 2,
          lastReview: DateTime.utc(2026, 10, 1),
          nextReview: DateTime.utc(2026, 10, 15),
        ),
      );
      final backup = await store.exportProfileBackup();
      await store.switchAccount({
        'user_id': 'alice',
        'server_url': 'http://test/api/v1',
        'sync_token': 'secret',
      });
      await store.savePrivateLesson(word('custom_ja_a'));
      await store.saveCard(FSRSCard.initial('custom_ja_a'));
      await store.enqueueMutation(
        mutationType: 'review',
        payload: {'review_id': 'destination', 'item_id': 'custom_ja_a'},
      );
      await store.mergeProfileBackup(await store.previewProfileBackup(backup));
      expect((await store.getCard('custom_ja_a'))!.reps, 0);
      expect(
        (await store.getPendingMutations()).where(
          (q) => q.mutationType == 'progress_import',
        ),
        isEmpty,
      );
    },
  );

  test(
    'preview source is bound even if caller mutates nested lesson hints',
    () async {
      await store.savePrivateLesson(word('custom_ja_a'));
      final source = await store.exportProfileBackup();
      final preview = await store.previewProfileBackup(source);
      preview.backup.privateLessons.single.lesson.strokeOrderHints.add(
        'Changed after preview',
      );
      await expectLater(
        store.mergeProfileBackup(preview),
        throwsA(isA<StaleProfileMergeException>()),
      );
    },
  );
  test(
    'imported progress is split by entity so unrelated words can synchronize',
    () async {
      await store.savePrivateLesson(word('custom_ja_a'));
      await store.savePrivateLesson(word('custom_ja_b'));
      await store.saveCard(FSRSCard.initial('custom_ja_a'));
      await store.saveCard(FSRSCard.initial('custom_ja_b'));
      final source = await store.exportProfileBackup();
      await store.switchAccount({
        'user_id': 'alice',
        'server_url': 'http://test/api/v1',
        'sync_token': 'secret',
      });
      await store.mergeProfileBackup(await store.previewProfileBackup(source));
      final imports = (await store.getPendingMutations())
          .where((q) => q.mutationType == 'progress_import')
          .toList();
      expect(imports.length, 2);
      for (final q in imports) {
        expect(
          (q.payload['cards'] as List).length +
              (q.payload['completed_lessons'] as List).length,
          1,
        );
      }
      expect(imports.map((q) => q.payload['mutation_id']).toSet().length, 2);
    },
  );

  test(
    'backup rejects malformed stroke hints instead of converting them to strings',
    () async {
      await store.savePrivateLesson(word('custom_ja_a'));
      final raw = (await store.exportProfileBackup()).toJson();
      ((raw['private_lessons'] as List).single['lesson']
          as Map)['stroke_order_hints'] = [
        42,
      ];
      expect(() => ProfileBackup.fromJson(raw), throwsFormatException);
    },
  );
  test(
    'reusing backup identity with different content rejects atomically',
    () async {
      await store.savePrivateLesson(word('custom_ja_a'));
      final source = await store.exportProfileBackup();
      await store.switchAccount({
        'user_id': 'alice',
        'server_url': 'http://test/api/v1',
        'sync_token': 'secret',
      });
      await store.mergeProfileBackup(await store.previewProfileBackup(source));
      final changed = source.toJson();
      ((changed['private_lessons'] as List).single['lesson']
              as Map)['meaning_vi'] =
          'Changed payload';
      await expectLater(
        store.previewProfileBackup(ProfileBackup.fromJson(changed)),
        throwsFormatException,
      );
      expect(
        (await store.getPrivateLesson('custom_ja_a'))!.lesson.meaningVi,
        'Trao đổi',
      );
    },
  );

  test(
    'empty-profile reset invalidates a preview even when content is unchanged',
    () async {
      final backup = await store.exportProfileBackup();
      final preview = await store.previewProfileBackup(backup);
      await store.clearAll();
      await expectLater(
        store.mergeProfileBackup(preview),
        throwsA(isA<StaleProfileMergeException>()),
      );
    },
  );
}
