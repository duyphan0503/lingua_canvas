import 'package:app/services/storage/credential_vault.dart';
import 'dart:convert';
import 'dart:io';
import 'package:app/models/lesson_item.dart';
import 'package:app/models/public_lesson_ids.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final testCredentialVault = InMemoryCredentialVault();

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late LocalDatabase database;
  setUp(() async {
    database = LocalDatabase.instance;
    await database.initCustom(
      credentialVault: testCredentialVault,
      customPath: inMemoryDatabasePath,
    );
  });
  tearDown(() async => database.close());

  test(
    'custom word is persisted, normalized and reused across launches',
    () async {
      final service = ApiService(
        localDb: database,
        baseUrl: 'http://127.0.0.1:9/api/v1',
      );
      final lesson = await service.ensureLessonForWord(
        word: '  pull request  ',
        language: 'en',
        meaningVi: ' Yêu cầu hợp nhất ',
      );
      expect(lesson.category, 'custom');
      expect(lesson.targetText, 'pull request');
      expect(lesson.meaningVi, 'Yêu cầu hợp nhất');
      expect(lesson.strokeOrderHints, isNotEmpty);
      final reopened = ApiService(
        localDb: database,
        baseUrl: 'http://127.0.0.1:9/api/v1',
      );
      final same = await reopened.ensureLessonForWord(
        word: 'PULL REQUEST',
        language: 'en',
      );
      expect(same.id, lesson.id);
      expect((await database.getLessons(category: 'custom')).length, 1);
      final distinct = await service.ensureLessonForWord(
        word: 'pull_request',
        language: 'en',
      );
      expect(distinct.id, isNot(lesson.id));
      await expectLater(
        service.ensureLessonForWord(word: ' ', language: 'en'),
        throwsArgumentError,
      );
      await expectLater(
        service.ensureLessonForWord(word: 'Hallo', language: 'de'),
        throwsArgumentError,
      );
    },
  );

  test('online curriculum retains locally created custom words', () async {
    final offline = ApiService(
      localDb: database,
      baseUrl: 'http://127.0.0.1:9/api/v1',
    );
    final custom = await offline.ensureLessonForWord(
      word: '定例相談メモ',
      language: 'ja',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          request.uri.queryParameters['language'] == 'en'
              ? []
              : [
                  {
                    ...custom.toJson(),
                    'language': 'custom',
                    'target_text': custom.id,
                    'meaning_vi': 'Custom card',
                  },
                ],
        ),
      );
      await request.response.close();
    });
    final online = ApiService(
      localDb: database,
      baseUrl: 'http://127.0.0.1:${server.port}/api/v1',
    );
    expect((await online.getLessons()).map((l) => l.id), contains(custom.id));
    expect((await online.getLessons()).single.targetText, '定例相談メモ');
    expect((await database.getLesson(custom.id))!.language, 'ja');
    expect(await online.getLessons(language: 'en'), isEmpty);
  });

  test('offline curriculum contains the expanded learning path', () async {
    final service = ApiService(
      localDb: database,
      baseUrl: 'http://127.0.0.1:9/api/v1',
    );
    final lessons = await service.getLessons();
    expect(lessons, hasLength(355));
    expect(lessons.map((lesson) => lesson.id).toSet(), publicLessonIds);
    expect(
      lessons.where((l) => l.id.startsWith('ja_extra_')).length,
      greaterThanOrEqualTo(30),
    );
    expect(
      lessons.where((l) => l.id.startsWith('en_extra_')).length,
      greaterThanOrEqualTo(15),
    );
    for (final word in [
      'コード',
      '進捗',
      '報告',
      '連絡',
      '相談',
      'standup',
      'idempotent',
      'followup',
    ]) {
      expect(lessons.any((l) => l.targetText == word), isTrue, reason: word);
    }
    for (final lesson in lessons.where((l) => l.id.contains('_extra_'))) {
      expect(lesson.phoneticOrKana, isNotEmpty);
      expect(lesson.workplaceContext, isNotEmpty);
      expect(lesson.workplaceContextVi, isNotEmpty);
      expect(lesson.strokeOrderHints.length, greaterThanOrEqualTo(2));
      expect(lesson.difficultyLevel, inInclusiveRange(1, 3));
    }
  });

  test(
    'sync placeholders cannot overwrite complete local custom lessons',
    () async {
      final api = ApiService(
        localDb: database,
        baseUrl: 'http://127.0.0.1:9/api/v1',
      );
      final custom = await api.ensureLessonForWord(
        word: 'release checklist',
        language: 'en',
        meaningVi: 'Danh sách phát hành',
        workplaceContext: 'Check the release checklist.',
      );
      await database.saveLessons([
        LessonItem.fromJson({
          ...custom.toJson(),
          'language': 'custom',
          'target_text': custom.id,
          'meaning_vi': 'Custom card',
        }),
      ]);
      final restored = (await database.getLesson(custom.id))!;
      expect(restored.targetText, 'release checklist');
      expect(restored.meaningVi, 'Danh sách phát hành');
      expect(restored.workplaceContext, 'Check the release checklist.');
      expect(restored.language, 'en');
    },
  );

  test(
    'old offline cache receives missing bundled lessons without overwriting existing content',
    () async {
      await database.saveLessons([
        LessonItem(
          id: 'ja_hira_a',
          language: 'ja',
          category: 'alphabet',
          targetText: 'あ',
          phoneticOrKana: 'a',
          meaningVi: 'Nghĩa đã lưu',
          workplaceContext: '',
          workplaceContextVi: '',
          strokeOrderHints: [],
          difficultyLevel: 1,
        ),
      ]);
      final api = ApiService(
        localDb: database,
        baseUrl: 'http://127.0.0.1:9/api/v1',
      );
      final lessons = await api.getLessons();
      expect(lessons.any((l) => l.targetText == 'idempotent'), isTrue);
      expect(
        lessons.firstWhere((l) => l.id == 'ja_hira_a').meaningVi,
        'Nghĩa đã lưu',
      );
      expect((await database.getLessons()).length, lessons.length);
    },
  );

  test(
    'custom metadata survives real PostgreSQL review sync and reload',
    () async {
      final base = Platform.environment['TEST_SYNC_API_BASE_URL'];
      if (base == null) return;
      final api = ApiService(localDb: database, baseUrl: base);
      final custom = await api.ensureLessonForWord(
        word: 'review sync metadata',
        language: 'en',
        meaningVi: 'Giữ nội dung sau đồng bộ',
        workplaceContext: 'Preserve this custom example.',
      );
      await api.submitReview(itemId: custom.id, rating: FSRSRating.good);
      final sync = await api.sync();
      expect(sync.success, isTrue, reason: sync.error);
      expect(await database.getPendingMutations(), isEmpty);
      final reloaded = (await api.getLessons()).firstWhere(
        (l) => l.id == custom.id,
      );
      expect(reloaded.language, 'en');
      expect(reloaded.targetText, 'review sync metadata');
      expect(reloaded.meaningVi, 'Giữ nội dung sau đồng bộ');
      expect(reloaded.workplaceContext, 'Preserve this custom example.');
    },
  );

  test('review is durable locally before any network sync', () async {
    final service = ApiService(localDb: database);
    await service.submitReview(itemId: 'ja_kata_bug', rating: FSRSRating.good);

    expect((await database.getCard('ja_kata_bug'))?.reps, 1);
    expect((await database.getPendingMutations()).single.payload['rating'], 3);
    expect(await service.getCompletedCount(), 1);
  });

  test('lessons fetched offline are cached for the next launch', () async {
    final service = ApiService(localDb: database);
    final lessons = await service.getLessons();
    expect(lessons, isNotEmpty);
    expect((await database.getLessons()).length, lessons.length);
  });
}
