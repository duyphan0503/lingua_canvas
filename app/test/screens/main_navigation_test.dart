import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/lesson_item.dart';
import 'package:app/screens/main_shell_screen.dart';
import 'package:app/widgets/handwriting_canvas.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/digital_ink_engine.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/local_database.dart';
import 'package:app/services/sync_coordinator.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockNavigationApiService extends ApiService {
  final customLessons = <LessonItem>[];

  @override
  Future<LessonItem> ensureLessonForWord({
    required String word,
    required String language,
    String? phoneticOrKana,
    String? meaningVi,
    String? workplaceContext,
    String? workplaceContextVi,
  }) async {
    final lesson = await super.ensureLessonForWord(
      word: word,
      language: language,
      phoneticOrKana: phoneticOrKana,
      meaningVi: meaningVi,
      workplaceContext: workplaceContext,
      workplaceContextVi: workplaceContextVi,
    );
    customLessons.add(lesson);
    return lesson;
  }

  @override
  Future<List<FSRSCard>> getAllCards() async => [];

  @override
  Future<List<LessonItem>> getDueLessons() async => [];

  @override
  Future<SyncResult> sync() async =>
      SyncResult(success: true, pulledLessons: 0);

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
      strokeOrderHints: [],
      difficultyLevel: 1,
    ),
    ...customLessons,
  ];

  @override
  Future<int> getCompletedCount() async => 3;

  @override
  Future<Map<String, dynamic>> getFSRSStats() async => {
    'total_cards': 10,
    'total_completed': 3,
    'due_today': 2,
    'pending_sync_mutations': 0,
    'avg_stability': 4.5,
    'estimated_retention': 90,
    'state_breakdown': {'new': 4, 'learning': 2, 'review': 3, 'relearning': 1},
  };

  @override
  Future<bool> checkBackendHealth() async => true;

  @override
  Future<StudyStreak> getStudyStreak({DateTime? asOf}) async =>
      const StudyStreak(
        currentStreak: 0,
        longestStreak: 0,
        activityHistory: {},
      );
}

class MockNavigationInkEngine extends HeuristicDigitalInkEngine {
  @override
  Future<bool> isModelDownloaded(String languageTag) async => true;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late MockNavigationApiService service;

  setUp(() async {
    await LocalDatabase.instance.initCustom(customPath: inMemoryDatabasePath);
    service = MockNavigationApiService();
  });

  tearDown(() async {
    await LocalDatabase.instance.close();
  });

  group('MainShellScreen Navigation Tests', () {
    testWidgets(
      'unknown roleplay word is saved and opens its custom writing lesson',
      (tester) async {
        tester.view.physicalSize = const Size(394, 853);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: MainShellScreen(
              apiService: service,
              digitalInkEngine: MockNavigationInkEngine(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('AI Đối Thoại'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final writingChallenge = find.textContaining('Thử thách viết: "進捗"');
        await tester.ensureVisible(writingChallenge);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() async {
          await tester.tap(writingChallenge);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(find.text('進捗'), findsOneWidget);
        expect(find.byType(HandwritingCanvas), findsOneWidget);
        final lessons = (await tester.runAsync(
          () => service.localDatabase.getLessons(category: 'custom'),
        ))!;
        expect(lessons.single.targetText, '進捗');
      },
    );

    testWidgets('all tabs fit a narrow viewport with larger text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: MainShellScreen(
            apiService: service,
            digitalInkEngine: MockNavigationInkEngine(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);

      for (final tab in ['AI Đối Thoại', 'Giáo Trình', 'Thống Kê', 'Cài Đặt']) {
        await tester.tap(find.text(tab));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull, reason: 'Overflow in $tab');
      }
    });

    testWidgets(
      'renders all 5 bottom navigation tabs and switches between them',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: MainShellScreen(
              apiService: service,
              digitalInkEngine: MockNavigationInkEngine(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // 1. Initial tab: Luyện Viết (Canvas)
        expect(find.text('Học & Ôn tập'), findsOneWidget);
        expect(find.text('AI Đối Thoại'), findsOneWidget);
        expect(find.text('Giáo Trình'), findsOneWidget);
        expect(find.text('Thống Kê'), findsOneWidget);
        expect(find.text('Cài Đặt'), findsOneWidget);
        expect(find.text('Lingua Canvas'), findsOneWidget);

        // 2. Switch to AI Đối Thoại
        await tester.tap(find.text('AI Đối Thoại'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('AI Workplace Role-Play'), findsOneWidget);
        expect(find.text('Đối Thoại Trực Tiếp'), findsOneWidget);

        // 3. Switch to Giáo Trình
        await tester.tap(find.text('Giáo Trình'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Thư Viện Giáo Trình & Từ Vựng'), findsOneWidget);

        // 4. Switch to Thống Kê
        await tester.tap(find.text('Thống Kê'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Thống Kê & Trí Nhớ FSRS'), findsOneWidget);
        expect(find.text('90%'), findsOneWidget);

        // 5. Switch to Cài Đặt
        await tester.tap(find.text('Cài Đặt'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Cài Đặt & Kết Nối Hệ Thống'), findsOneWidget);
        expect(
          find.text('Địa Chỉ Máy Chủ Backend (Rust Axum)'),
          findsOneWidget,
        );
      },
    );

    testWidgets('Curriculum "Luyện viết ngay" navigates to Canvas tab', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: MainShellScreen(
            apiService: service,
            digitalInkEngine: MockNavigationInkEngine(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Navigate to Curriculum
      await tester.tap(find.text('Giáo Trình'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Tap 'Luyện viết ngay' button on the first card
      final practiceBtn = find.text('Luyện viết ngay');
      expect(practiceBtn, findsOneWidget);
      await tester.tap(practiceBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Should automatically switch back to Canvas tab
      expect(find.text('Lingua Canvas'), findsOneWidget);
      expect(find.text('あ'), findsOneWidget);
    });
  });
}
