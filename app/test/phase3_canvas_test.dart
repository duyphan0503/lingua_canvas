import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/screens/canvas_practice_screen.dart';
import 'package:app/widgets/handwriting_canvas.dart';
import 'package:app/services/stroke_guide_service.dart';
import 'package:app/services/speech_practice_service.dart';
import 'widget_test.dart' show PracticeApiService;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    expect(await StrokeGuideService.initialize(), isTrue);
  });

  testWidgets('guide animation completes and leaves user strokes untouched', (
    tester,
  ) async {
    var completed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 300,
          child: HandwritingCanvas(
            strokes: const [],
            onStrokesChanged: (_) {},
            guidePaths: [
              StrokeGuidePath(
                strokeNumber: 1,
                normalizedPoints: [Offset(.2, .5), Offset(.8, .5)],
              ),
            ],
            isAnimatingGuide: true,
            onGuideAnimationCompleted: () => completed++,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 325));
    expect(completed, 0);
    await tester.pump(const Duration(milliseconds: 400));
    expect(completed, 1);
    expect(
      tester.widget<HandwritingCanvas>(find.byType(HandwritingCanvas)).strokes,
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('sample button starts guides and pen input stops them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: CanvasPracticeScreen(apiService: PracticeApiService())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xem nét mẫu'));
    await tester.pump();
    expect(
      tester
          .widget<HandwritingCanvas>(find.byType(HandwritingCanvas))
          .isAnimatingGuide,
      isTrue,
    );
    final pen = await tester.startGesture(
      tester.getCenter(find.byType(HandwritingCanvas)),
    );
    await tester.pump();
    expect(
      tester
          .widget<HandwritingCanvas>(find.byType(HandwritingCanvas))
          .isAnimatingGuide,
      isFalse,
    );
    await pen.up();
    await tester.pumpAndSettle();
  });
  testWidgets('speaking practice scores injected transcript visibly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasPracticeScreen(
          apiService: PracticeApiService(),
          speechService: SpeechPracticeService(
            engine: MockSpeechPracticeEngine(transcript: 'あ'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Luyện nói'));
    await tester.pumpAndSettle();
    expect(find.textContaining('100%'), findsWidgets);
  });
}
