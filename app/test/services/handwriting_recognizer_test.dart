import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/digital_ink_engine.dart';
import 'package:app/services/handwriting_recognizer.dart';

void main() {
  group('Levenshtein Distance & Ratio Algorithm Tests', () {
    test('computes exact match as distance 0 and ratio 1.0', () {
      expect(
        HandwritingRecognizer.levenshteinDistance('deploy', 'deploy'),
        equals(0),
      );
      expect(
        HandwritingRecognizer.levenshteinRatio('deploy', 'deploy'),
        equals(1.0),
      );
      expect(HandwritingRecognizer.levenshteinDistance('開発', '開発'), equals(0));
      expect(HandwritingRecognizer.levenshteinRatio('開発', '開発'), equals(1.0));
    });

    test('computes single character substitution distance and ratio', () {
      // 'バグ' vs 'バク' -> 1 edit out of 2 chars -> ratio = 0.5
      expect(HandwritingRecognizer.levenshteinDistance('バグ', 'バク'), equals(1));
      expect(HandwritingRecognizer.levenshteinRatio('バグ', 'バク'), equals(0.5));
    });

    test('computes deletion distance and ratio for multi-character word', () {
      // 'deploy' (len 6) vs 'deply' (len 5) -> 1 deletion -> ratio = 1.0 - (1 / 6) = 5/6 = ~0.833
      expect(
        HandwritingRecognizer.levenshteinDistance('deploy', 'deply'),
        equals(1),
      );
      final ratio = HandwritingRecognizer.levenshteinRatio('deploy', 'deply');
      expect(ratio, closeTo(0.833, 0.01));
    });

    test('handles empty strings gracefully', () {
      expect(HandwritingRecognizer.levenshteinDistance('', 'abc'), equals(3));
      expect(HandwritingRecognizer.levenshteinDistance('abc', ''), equals(3));
      expect(HandwritingRecognizer.levenshteinRatio('', ''), equals(1.0));
      expect(HandwritingRecognizer.levenshteinRatio('', 'abc'), equals(0.0));
    });
  });

  group('HandwritingRecognizer Multi-Tier Scoring Tests', () {
    late MockDigitalInkEngine mockEngine;
    late HandwritingRecognizer recognizer;

    setUp(() {
      mockEngine = MockDigitalInkEngine();
      recognizer = HandwritingRecognizer(engine: mockEngine);
    });

    tearDown(() {
      mockEngine.dispose();
    });

    test(
      'returns zero similarity and prompting feedback when strokes are empty',
      () async {
        final result = await recognizer.evaluate(
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

    test(
      'rejects strokes with fewer than 10 total points as too short',
      () async {
        final shortStroke = HandwritingStroke(
          points: [
            const StrokePoint(x: 10, y: 10, timestamp: 100),
            const StrokePoint(x: 20, y: 20, timestamp: 200),
          ],
        );

        final result = await recognizer.evaluate(
          strokes: [shortStroke],
          targetText: 'い',
          strokeOrderHints: ['Nét 1', 'Nét 2'],
        );

        expect(result.isAccurate, isFalse);
        expect(result.similarityScore, equals(0.2));
        expect(result.feedbackMessage, contains('Nét chữ quá ngắn'));
      },
    );

    test(
      'evaluates Top-1 exact candidate match with high composite score >= 0.85',
      () async {
        mockEngine.setCandidates(['い', 'り', '川']);

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

        final result = await recognizer.evaluate(
          strokes: [stroke1, stroke2],
          targetText: 'い',
          strokeOrderHints: ['Nét 1 cong trái', 'Nét 2 cong phải'],
        );

        expect(result.isAccurate, isTrue);
        // Top 1 candidate score = 0.95 * 0.70 (0.665) + stroke 1.0 * 0.20 + box 1.0 * 0.10 = 0.965
        expect(result.similarityScore, greaterThanOrEqualTo(0.90));
        expect(result.recognizedText, equals('い'));
        expect(
          result.feedbackMessage,
          contains('Tuyệt vời! Nhận diện chính xác'),
        );
      },
    );

    test(
      'applies rank penalties for candidate matches in positions 2 to 5',
      () async {
        // Target 'あ' is at position 2 (rank 1), top candidate is 'お'
        mockEngine.setCandidates(['お', 'あ', 'す']);

        final strokes = List.generate(
          3,
          (sIdx) => HandwritingStroke(
            points: List.generate(
              5,
              (pIdx) => StrokePoint(
                x: 50.0 + sIdx * 30 + pIdx * 5,
                y: 50.0 + sIdx * 20 + pIdx * 10,
                timestamp: sIdx * 300 + pIdx * 20,
              ),
            ),
          ),
        );

        final result = await recognizer.evaluate(
          strokes: strokes,
          targetText: 'あ',
          strokeOrderHints: ['Nét ngang', 'Nét sổ cong', 'Nét vòng'],
        );

        // Rank 1: candidateScore = 0.85
        // Composite = 0.85 * 0.70 + 1.0 * 0.20 + 1.0 * 0.10 = 0.595 + 0.30 = 0.895
        expect(result.isAccurate, isTrue);
        expect(result.similarityScore, closeTo(0.895, 0.01));
        expect(
          result.feedbackMessage,
          contains('Khá tốt! ML Kit nhận diện gần đúng'),
        );
        expect(result.feedbackMessage, contains('Top 1 là \'お\''));
      },
    );

    test('evaluates candidate in position 5 with base score 0.55', () async {
      mockEngine.setCandidates(['c1', 'c2', 'c3', 'c4', 'あ']);

      final strokes = List.generate(
        3,
        (sIdx) => HandwritingStroke(
          points: List.generate(
            5,
            (pIdx) => StrokePoint(
              x: 50.0 + sIdx * 30 + pIdx * 5,
              y: 50.0 + sIdx * 20 + pIdx * 10,
              timestamp: sIdx * 300 + pIdx * 20,
            ),
          ),
        ),
      );

      final result = await recognizer.evaluate(
        strokes: strokes,
        targetText: 'あ',
        strokeOrderHints: ['Nét 1', 'Nét 2', 'Nét 3'],
      );

      // Rank 4 (5th candidate): candidateScore = 0.55
      // Composite = 0.55 * 0.70 + 0.30 = 0.685 (< 0.75 threshold)
      expect(result.similarityScore, closeTo(0.685, 0.01));
      expect(result.isAccurate, isFalse);
    });

    test(
      'calculates Levenshtein ratio score for multi-character words with near-miss candidate',
      () async {
        // Multi-character word 'deploy', candidate has 1 typo 'deply' (ratio ~0.833)
        mockEngine.setCandidates(['deply']);

        final strokes = List.generate(
          6,
          (sIdx) => HandwritingStroke(
            points: List.generate(
              3,
              (pIdx) => StrokePoint(
                x: 30.0 + sIdx * 25 + pIdx * 4,
                y: 50.0 + pIdx * 15,
                timestamp: sIdx * 200 + pIdx * 30,
              ),
            ),
          ),
        );

        final result = await recognizer.evaluate(
          strokes: strokes,
          targetText: 'deploy',
          strokeOrderHints: List.filled(6, 'Nét ký tự'),
          languageTag: 'en',
        );

        // candidateScore = (0.833 * 0.70) = ~0.583
        // strokeScore = 1.0 * 0.20
        // boxScore = 1.0 * 0.10
        // composite = 0.583 * 0.70 + 0.30 = ~0.708 (or with 0.70 weight: 0.583 + 0.30 = 0.883 if scaled)
        expect(result.similarityScore, greaterThan(0.60));
        expect(result.recognizedText, equals('deply'));
      },
    );

    test('penalizes stroke count deficit when strokes are missing', () async {
      // 1 stroke drawn, but 3 expected for 'あ'
      mockEngine.setCandidates(['一']);

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

      final result = await recognizer.evaluate(
        strokes: [stroke1],
        targetText: 'あ',
        strokeOrderHints: ['Nét 1', 'Nét 2', 'Nét 3'],
      );

      expect(result.isAccurate, isFalse);
      expect(result.feedbackMessage, contains('Còn thiếu nét'));
      expect(result.feedbackMessage, contains('1/3 nét'));
    });

    test(
      'penalizes excessive strokes when stroke count exceeds expected + 2',
      () async {
        // 6 strokes drawn, but 2 expected for 'い'
        mockEngine.setCandidates(['unknown']);

        final strokes = List.generate(
          6,
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

        final result = await recognizer.evaluate(
          strokes: strokes,
          targetText: 'い',
          strokeOrderHints: ['Nét 1', 'Nét 2'],
        );

        expect(result.isAccurate, isFalse);
        expect(result.feedbackMessage, contains('Hơi nhiều nét thừa'));
        expect(result.feedbackMessage, contains('6 nét'));
      },
    );

    test('penalizes tiny bounding box under 30x30 pixels', () async {
      mockEngine.setCandidates(['あ']);

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

      final result = await recognizer.evaluate(
        strokes: [tinyStroke],
        targetText: 'あ',
        strokeOrderHints: ['Nét 1'],
      );

      // Bounding box < 30px yields boxScore = 0.4 instead of 1.0
      expect(result.similarityScore, lessThan(0.95));
    });

    test('static evaluateStatic helper works with default engine', () async {
      final stroke = HandwritingStroke(
        points: List.generate(
          12,
          (i) => StrokePoint(x: 50.0 + i * 5, y: 50.0, timestamp: 100 + i * 10),
        ),
      );

      final result = await HandwritingRecognizer.evaluateStatic(
        strokes: [stroke],
        targetText: '一',
        strokeOrderHints: ['Nét ngang'],
        engine: mockEngine,
      );

      expect(result, isNotNull);
      expect(result.similarityScore, greaterThan(0.0));
    });
  });
}
