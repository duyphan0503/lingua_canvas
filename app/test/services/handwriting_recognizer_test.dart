import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/handwriting_recognizer.dart';

void main() {
  group('HandwritingRecognizer Heuristics Tests', () {
    test(
      'returns zero similarity and prompting feedback when strokes are empty',
      () {
        final result = HandwritingRecognizer.evaluate(
          strokes: [],
          targetText: 'あ',
          strokeOrderHints: ['Nét 1', 'Nét 2', 'Nét 3'],
        );

        expect(result.isAccurate, isFalse);
        expect(result.similarityScore, equals(0.0));
        expect(result.recognizedText, isEmpty);
        expect(result.feedbackMessage, contains('Hãy viết lên màn hình'));
      },
    );

    test('rejects strokes with fewer than 10 total points as too short', () {
      final shortStroke = HandwritingStroke(
        points: [
          StrokePoint(x: 10, y: 10, timestamp: 100),
          StrokePoint(x: 20, y: 20, timestamp: 200),
        ],
      );

      final result = HandwritingRecognizer.evaluate(
        strokes: [shortStroke],
        targetText: 'い',
        strokeOrderHints: ['Nét 1', 'Nét 2'],
      );

      expect(result.isAccurate, isFalse);
      expect(result.similarityScore, equals(0.2));
      expect(result.feedbackMessage, contains('Nét chữ quá ngắn'));
    });

    test(
      'evaluates correctly proportioned drawing matching expected stroke count as accurate',
      () {
        // 2 strokes matching target 'い' with 2 stroke hints, > 10 points, box >= 30x30
        final stroke1 = HandwritingStroke(
          points: List.generate(
            8,
            (i) => StrokePoint(
              x: 50.0 + i * 2,
              y: 50.0 + i * 10,
              timestamp: 100 + i * 10,
            ),
          ),
        );
        final stroke2 = HandwritingStroke(
          points: List.generate(
            8,
            (i) => StrokePoint(
              x: 120.0 + i * 2,
              y: 60.0 + i * 8,
              timestamp: 300 + i * 10,
            ),
          ),
        );

        final result = HandwritingRecognizer.evaluate(
          strokes: [stroke1, stroke2],
          targetText: 'い',
          strokeOrderHints: ['Nét 1 cong trái', 'Nét 2 cong phải'],
        );

        expect(result.isAccurate, isTrue);
        expect(result.similarityScore, greaterThanOrEqualTo(0.75));
        expect(result.recognizedText, equals('い'));
        expect(result.feedbackMessage, contains('Tuyệt vời'));
      },
    );

    test(
      'identifies missing strokes when stroke count is less than expected',
      () {
        // 1 stroke drawn, but 3 expected for 'あ'
        final stroke1 = HandwritingStroke(
          points: List.generate(
            15,
            (i) => StrokePoint(
              x: 50.0 + i * 5,
              y: 50.0 + i * 5,
              timestamp: 100 + i * 10,
            ),
          ),
        );

        final result = HandwritingRecognizer.evaluate(
          strokes: [stroke1],
          targetText: 'あ',
          strokeOrderHints: ['Nét 1', 'Nét 2', 'Nét 3'],
        );

        expect(result.isAccurate, isFalse);
        expect(result.feedbackMessage, contains('Còn thiếu nét'));
        expect(result.feedbackMessage, contains('1/3 nét'));
      },
    );

    test(
      'identifies excessive strokes when stroke count exceeds expected + 2',
      () {
        // Expected: 2 strokes, drawn: 5 strokes
        final strokes = List.generate(
          5,
          (sIdx) => HandwritingStroke(
            points: List.generate(
              4,
              (pIdx) => StrokePoint(
                x: 50.0 + sIdx * 20 + pIdx * 5,
                y: 50.0 + sIdx * 10 + pIdx * 5,
                timestamp: sIdx * 500 + pIdx * 50,
              ),
            ),
          ),
        );

        final result = HandwritingRecognizer.evaluate(
          strokes: strokes,
          targetText: 'い',
          strokeOrderHints: ['Nét 1', 'Nét 2'],
        );

        expect(result.isAccurate, isFalse);
        expect(result.feedbackMessage, contains('Hơi nhiều nét thừa'));
        expect(result.feedbackMessage, contains('5 nét'));
      },
    );

    test('penalizes tiny bounding box under 30x30 pixels', () {
      // Drawn in tiny 10x10 area with 15 points
      final tinyStroke = HandwritingStroke(
        points: List.generate(
          15,
          (i) => StrokePoint(
            x: 100.0 + (i % 3) * 2,
            y: 100.0 + (i ~/ 3) * 2,
            timestamp: 100 + i * 10,
          ),
        ),
      );

      final result = HandwritingRecognizer.evaluate(
        strokes: [tinyStroke],
        targetText: 'A',
        strokeOrderHints: ['Nét 1'],
      );

      // Score should be lower because sizeScore is 0.5
      expect(result.similarityScore, lessThan(1.0));
      expect(result.isAccurate, isTrue); // 1.0 * 0.7 + 0.5 * 0.3 = 0.85 >= 0.75
    });
  });
}
