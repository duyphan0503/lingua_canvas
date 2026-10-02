import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/lesson_item.dart';
import 'package:app/screens/canvas_practice_screen.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/digital_ink_engine.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/handwriting_recognizer.dart';
import 'package:app/services/sync_coordinator.dart';
import 'package:app/widgets/handwriting_canvas.dart';

class PracticeApiService extends ApiService {
  int completed = 0;
  int syncAttempts = 0;
  int pulledLessons = 0;

  @override
  Future<SyncResult> sync() async {
    syncAttempts++;
    return SyncResult(success: true, pulledLessons: pulledLessons);
  }

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
    LessonItem(
      id: 'en_it_deploy',
      language: 'en',
      category: 'it_workplace',
      targetText: 'deploy',
      phoneticOrKana: '',
      meaningVi: 'Triển khai phần mềm lên server',
      workplaceContext: '',
      workplaceContextVi: '',
      strokeOrderHints: [],
      difficultyLevel: 1,
    ),
  ];

  @override
  Future<int> getCompletedCount() async => completed;

  @override
  Future<void> submitReview({
    required String itemId,
    required FSRSRating rating,
  }) async {
    completed++;
  }
}

class TrackingDigitalInkEngine extends MockDigitalInkEngine {
  final checkedLanguages = <String>[];
  final recognizedLanguages = <String>[];

  @override
  Future<bool> isModelDownloaded(String languageTag) {
    checkedLanguages.add(languageTag);
    return super.isModelDownloaded(languageTag);
  }

  @override
  Future<List<String>> getCandidates(
    List<HandwritingStroke> strokes,
    String languageTag,
  ) {
    recognizedLanguages.add(languageTag);
    return super.getCandidates(strokes, languageTag);
  }
}

void main() {
  late PracticeApiService service;
  setUp(() => service = PracticeApiService());

  group('Lingua Canvas Widget Tests', () {
    testWidgets('syncs on launch and when app resumes', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: CanvasPracticeScreen(apiService: service)),
      );
      await tester.pumpAndSettle();
      expect(service.syncAttempts, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(service.syncAttempts, 2);
    });
    testWidgets('retries sync in foreground and stops while paused', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: CanvasPracticeScreen(apiService: service)),
      );
      await tester.pumpAndSettle();
      expect(service.syncAttempts, 1);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(service.syncAttempts, 2);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 30));
      expect(service.syncAttempts, 2);
    });

    testWidgets('background lesson refresh preserves the active drawing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: CanvasPracticeScreen(apiService: service)),
      );
      await tester.pumpAndSettle();
      final canvas = find.byType(HandwritingCanvas);
      final gesture = await tester.startGesture(tester.getCenter(canvas));
      await gesture.moveBy(const Offset(20, 20));
      await tester.pump();
      expect(tester.widget<HandwritingCanvas>(canvas).strokes, isNotEmpty);

      service.pulledLessons = 1;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(tester.widget<HandwritingCanvas>(canvas).strokes, isNotEmpty);
      await gesture.up();
    });
    testWidgets('Canvas practice screen smoke test renders core UI elements', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(home: CanvasPracticeScreen(apiService: service)),
      );
      await tester.pumpAndSettle();

      // 1. Verify App Bar header
      expect(find.text('Lingua Canvas'), findsOneWidget);
      expect(find.text('IT Workplace Language Practice'), findsOneWidget);
      expect(find.textContaining('Đã luyện:'), findsOneWidget);

      // 2. Verify Lesson Info Card (First fallback item: Hiragana A)
      expect(find.text('あ'), findsOneWidget);
      expect(find.text('Chữ cái Hiragana: A'), findsOneWidget);

      // 3. Verify Interactive Canvas area
      expect(find.byType(HandwritingCanvas), findsOneWidget);
      expect(find.text('Vùng Luyện Viết (Canvas)'), findsOneWidget);
      expect(find.text('Xóa'), findsOneWidget);
      expect(find.text('Đánh giá'), findsOneWidget);

      // 4. Verify Model status indicator
      expect(find.text('Mô hình AI: Sẵn sàng (On-device)'), findsOneWidget);

      // 5. Verify FSRS Spaced Repetition rating buttons
      expect(find.text('Again'), findsOneWidget);
      expect(find.text('Hard'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);
      expect(find.text('Easy'), findsOneWidget);
    });

    testWidgets(
      'Drawing strokes on canvas and evaluating recognition feedback',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(home: CanvasPracticeScreen(apiService: service)),
        );
        await tester.pumpAndSettle();

        final canvasFinder = find.byType(HandwritingCanvas);
        expect(canvasFinder, findsOneWidget);

        // Perform drawing gesture across the canvas
        final center = tester.getCenter(canvasFinder);
        final gesture = await tester.startGesture(center);
        for (int i = 0; i < 15; i++) {
          await gesture.moveBy(const Offset(3.0, 3.0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 800));
        await tester.pumpAndSettle();

        // Verify evaluation results / feedback are displayed
        expect(find.textContaining('Độ tương đồng:'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                (widget.data?.contains('Đạt chuẩn') == true ||
                    widget.data?.contains('Cần cải thiện') == true),
          ),
          findsOneWidget,
        );

        // Verify Clear button resets canvas
        final clearButton = find.text('Xóa');
        await tester.tap(clearButton);
        await tester.pumpAndSettle();
        expect(find.textContaining('Độ tương đồng:'), findsNothing);
      },
    );

    testWidgets(
      'Switching language filter updates lesson curriculum to IT workplace',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(home: CanvasPracticeScreen(apiService: service)),
        );
        await tester.pumpAndSettle();

        // Switch to English IT Workplace
        final enChip = find.text('Tiếng Anh (IT)');
        expect(enChip, findsOneWidget);
        await tester.tap(enChip);
        await tester.pumpAndSettle();

        // Should display English IT lesson: 'deploy'
        expect(find.text('deploy'), findsOneWidget);
        expect(find.text('Triển khai phần mềm lên server'), findsOneWidget);
        expect(find.byType(HandwritingCanvas), findsNothing);
        expect(find.textContaining('Mô hình AI:'), findsNothing);

        // Switch to Japanese IT Workplace
        final jaChip = find.text('Tiếng Nhật (IT)');
        expect(jaChip, findsOneWidget);
        await tester.tap(jaChip);
        await tester.pumpAndSettle();

        // Should display Japanese lessons
        expect(find.text('JA • JLPT/IT'), findsOneWidget);
      },
    );

    testWidgets('Submitting FSRS review updates completed status', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(home: CanvasPracticeScreen(apiService: service)),
      );
      await tester.pumpAndSettle();

      // Tap 'Good' rating button
      final goodButton = find.text('Good');
      expect(goodButton, findsOneWidget);
      await tester.tap(goodButton);
      await tester.pump();

      // Status notification banner should show confirmation
      expect(find.textContaining('Đã lưu đánh giá: Good'), findsOneWidget);

      // Advance clock for auto-transition
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    });

    testWidgets('Model status indicator shows ready when model is downloaded', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final engine = MockDigitalInkEngine(
        initialDownloadedModels: {'ja': true, 'en': true},
      );

      await tester.pumpWidget(
        MaterialApp(
          home: CanvasPracticeScreen(
            apiService: service,
            digitalInkEngine: engine,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Mô hình AI: Sẵn sàng (On-device)'), findsOneWidget);
    });

    testWidgets(
      'Offline model indicator shows download button and downloads model upon tap',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final engine = MockDigitalInkEngine(
          initialDownloadedModels: {'ja': false, 'en': false},
        );

        await tester.pumpWidget(
          MaterialApp(
            home: CanvasPracticeScreen(
              apiService: service,
              digitalInkEngine: engine,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Verify offline model status and download button
        expect(find.text('Mô hình AI: Ngoại tuyến'), findsOneWidget);
        final downloadBtn = find.text('Tải mô hình');
        expect(downloadBtn, findsOneWidget);

        // Tap download button
        await tester.tap(downloadBtn);
        await tester.pumpAndSettle();

        // Status should transition to downloaded / ready
        expect(find.text('Mô hình AI: Sẵn sàng (On-device)'), findsOneWidget);
        expect(
          find.textContaining('Đã tải thành công mô hình'),
          findsOneWidget,
        );
      },
    );

    testWidgets('drawing keeps lesson scroll offset fixed', (tester) async {
      tester.view.physicalSize = const Size(394, 853);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(home: CanvasPracticeScreen(apiService: service)),
      );
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      final canvas = find.byType(HandwritingCanvas);
      final before = scrollable.position.pixels;
      final gesture = await tester.startGesture(tester.getCenter(canvas));
      await gesture.moveBy(const Offset(0, -90));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(scrollable.position.pixels, before);
      expect(tester.widget<HandwritingCanvas>(canvas).strokes, isNotEmpty);
    });

    testWidgets('narrow viewport and enlarged text do not overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: CanvasPracticeScreen(apiService: service),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Tiếng Anh (IT)'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(HandwritingCanvas), findsNothing);
    });

    testWidgets('English study never requests a handwriting model', (
      tester,
    ) async {
      final engine = TrackingDigitalInkEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasPracticeScreen(
            apiService: service,
            digitalInkEngine: engine,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(engine.checkedLanguages, ['ja']);

      await tester.tap(find.text('Tiếng Anh (IT)'));
      await tester.pumpAndSettle();
      expect(find.byType(HandwritingCanvas), findsNothing);
      expect(find.textContaining('Mô hình AI:'), findsNothing);
      expect(engine.checkedLanguages, ['ja']);
      expect(engine.recognizedLanguages, isEmpty);
    });
  });
}
