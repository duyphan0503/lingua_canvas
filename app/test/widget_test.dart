import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app/main.dart';
import 'package:app/widgets/handwriting_canvas.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Lingua Canvas Widget Tests', () {
    testWidgets('Canvas practice screen smoke test renders core UI elements', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle();

      // 1. Verify App Bar header
      expect(find.text('Lingua Canvas'), findsOneWidget);
      expect(find.text('IT Workplace Handwriting Practice'), findsOneWidget);
      expect(find.textContaining('Đã luyện:'), findsOneWidget);

      // 2. Verify Lesson Info Card (First fallback item: Hiragana A)
      expect(find.text('あ'), findsOneWidget);
      expect(find.text('Chữ cái Hiragana: A'), findsOneWidget);

      // 3. Verify Interactive Canvas area
      expect(find.byType(HandwritingCanvas), findsOneWidget);
      expect(find.text('Vùng Luyện Viết (Canvas)'), findsOneWidget);
      expect(find.text('Xóa'), findsOneWidget);
      expect(find.text('Đánh giá'), findsOneWidget);

      // 4. Verify FSRS Spaced Repetition rating buttons
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

        await tester.pumpWidget(const MyApp());
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

        await tester.pumpWidget(const MyApp());
        await tester.pumpAndSettle();

        // Switch to English IT Workplace
        final enChip = find.text('Tiếng Anh (IT)');
        expect(enChip, findsOneWidget);
        await tester.tap(enChip);
        await tester.pumpAndSettle();

        // Should display English IT lesson: 'deploy'
        expect(find.text('deploy'), findsOneWidget);
        expect(find.text('Triển khai phần mềm lên server'), findsOneWidget);

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

      await tester.pumpWidget(const MyApp());
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
  });
}
