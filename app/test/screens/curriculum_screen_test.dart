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
