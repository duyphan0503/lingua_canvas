import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/lesson_item.dart';
import 'package:app/screens/curriculum_screen.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/local_database.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockCurriculumApiService extends ApiService {
  @override
  Future<List<FSRSCard>> getAllCards() async => [];

  @override
  Future<List<LessonItem>> getLessons({String? language}) async => [
    LessonItem(
      id: 'ja_hira_a',
      language: 'ja',
      category: 'alphabet',
      targetText: 'あ',
      phoneticOrKana: 'a',
      meaningVi: 'Chữ cái Hiragana: A',
      workplaceContext: '',
      workplaceContextVi: '',
      strokeOrderHints: ['Nét 1'],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: 'en_it_deploy',
      language: 'en',
      category: 'it_workplace',
      targetText: 'deploy',
      phoneticOrKana: '/dɪˈplɔɪ/',
      meaningVi: 'Triển khai phần mềm',
      workplaceContext: 'Deploy to production',
      workplaceContextVi: 'Triển khai lên máy chủ',
      strokeOrderHints: [],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: 'ja_n5_day',
      language: 'ja',
      category: 'jlpt_n5',
      targetText: '日',
      phoneticOrKana: 'にち',
      meaningVi: 'Ngày',
      workplaceContext: '',
      workplaceContextVi: '',
      strokeOrderHints: [],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: 'custom_en_commit',
      language: 'en',
      category: 'custom',
      targetText: 'commit',
      phoneticOrKana: '',
      meaningVi: 'Lưu thay đổi',
      workplaceContext: '',
      workplaceContextVi: '',
      strokeOrderHints: [],
      difficultyLevel: 2,
    ),
  ];
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late MockCurriculumApiService service;

  setUp(() async {
    await LocalDatabase.instance.initCustom(customPath: inMemoryDatabasePath);
    service = MockCurriculumApiService();
  });

  tearDown(() async {
    await LocalDatabase.instance.close();
  });

  group('CurriculumScreen Widget Tests', () {
    testWidgets(
      'custom builder validates fields and persists before opening practice',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        LessonItem? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: CurriculumScreen(
              apiService: service,
              onSelectLesson: (lesson) => selected = lesson,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() => tester.tap(find.text('Thêm từ mới')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Lưu & Luyện viết'));
        await tester.pumpAndSettle();
        expect(find.text('Vui lòng nhập từ vựng'), findsOneWidget);
        expect(find.text('Vui lòng nhập nghĩa tiếng Việt'), findsOneWidget);
        expect(selected, isNull);
        await tester.enterText(find.byKey(const Key('custom-word')), '相談');
        await tester.enterText(
          find.byKey(const Key('custom-meaning')),
          'Trao đổi với cấp trên',
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('Lưu & Luyện viết'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
        expect(selected?.targetText, '相談');
        final stored = (await tester.runAsync(
          () => LocalDatabase.instance.getLessons(category: 'custom'),
        ))!;
        expect(stored.single.meaningVi, 'Trao đổi với cấp trên');
      },
    );

    testWidgets('N5 and custom categories filter the lesson list', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: CurriculumScreen(apiService: service)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'JLPT N5 (Kanji)'));
      await tester.pumpAndSettle();
      expect(find.text('日'), findsOneWidget);
      expect(find.text('あ'), findsNothing);
      expect(find.text('commit'), findsNothing);
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Từ tự tạo'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Từ tự tạo'));
      await tester.pumpAndSettle();
      expect(find.text('commit'), findsOneWidget);
      expect(find.text('日'), findsNothing);
      expect(find.text('deploy'), findsNothing);
    });

    testWidgets(
      'renders curriculum items and filters by search query and chips',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        LessonItem? selectedLesson;

        await tester.pumpWidget(
          MaterialApp(
            home: CurriculumScreen(
              apiService: service,
              onSelectLesson: (l) => selectedLesson = l,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Verify both items rendered
        expect(find.text('あ'), findsOneWidget);
        expect(find.text('deploy'), findsOneWidget);

        // Filter by language: Japanese
        final jaChip = find.text('Tiếng Nhật (JA)');
        await tester.tap(jaChip);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('あ'), findsOneWidget);
        expect(find.text('deploy'), findsNothing);

        // Search by keyword
        final searchInput = find.byType(TextField);
        await tester.enterText(searchInput, 'triển khai');
        await tester.pump(const Duration(milliseconds: 100));

        // 'deploy' matches meaning but language was JA, reset to All
        final allChip = find.text('Tất cả');
        await tester.tap(allChip);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('deploy'), findsOneWidget);
        expect(find.text('あ'), findsNothing);

        // English opens study and review without a writing exercise.
        final practiceBtn = find.text('Học & ôn ngay');
        await tester.tap(practiceBtn);
        await tester.pump(const Duration(milliseconds: 100));
        expect(selectedLesson?.id, 'en_it_deploy');
      },
    );
  });
}
