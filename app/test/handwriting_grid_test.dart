import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/handwriting_canvas.dart';

void main() {
  testWidgets(
    'English guides have four baselines; Japanese guides cross the center',
    (tester) async {
      for (final grid in HandwritingGrid.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 200,
              height: 200,
              child: HandwritingCanvas(
                strokes: const [],
                onStrokesChanged: (_) {},
                grid: grid,
              ),
            ),
          ),
        );
        final paint = tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(HandwritingCanvas),
            matching: find.byType(CustomPaint),
          ),
        );
        final recorder = ui.PictureRecorder();
        paint.painter!.paint(Canvas(recorder), const Size(200, 200));
        final picture = recorder.endRecording();
        final pixels = (await tester.runAsync(() async {
          final image = await picture.toImage(200, 200);
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return data;
        }))!;
        int alpha(int x, int y) => pixels.getUint8((y * 200 + x) * 4 + 3);
        if (grid == HandwritingGrid.english) {
          for (final y in [60, 90, 130, 160]) {
            expect(alpha(40, y), greaterThan(0), reason: 'guide at $y');
          }
          expect(alpha(100, 110), 0, reason: 'no vertical guide in English');
        } else {
          expect(alpha(40, 60), 0);
          expect(alpha(40, 100), greaterThan(0));
          expect(alpha(100, 40), greaterThan(0));
        }
        picture.dispose();
      }
    },
  );
}
