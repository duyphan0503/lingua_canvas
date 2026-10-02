import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/digital_ink_engine.dart';
import 'package:app/services/handwriting_recognizer.dart';

void main() {
  group('Language Tag Normalization Tests', () {
    test('normalizes Japanese tags correctly', () {
      expect(normalizeLanguageTag('ja'), equals('ja'));
      expect(normalizeLanguageTag('ja-JP'), equals('ja'));
      expect(normalizeLanguageTag('ja_JP'), equals('ja'));
      expect(normalizeLanguageTag('JA'), equals('ja'));
    });

    test('normalizes English tags correctly', () {
      expect(normalizeLanguageTag('en'), equals('en'));
      expect(normalizeLanguageTag('en-US'), equals('en'));
      expect(normalizeLanguageTag('en_US'), equals('en'));
      expect(normalizeLanguageTag('EN'), equals('en'));
    });

    test('handles other tags gracefully', () {
      expect(normalizeLanguageTag('fr-FR'), equals('fr-fr'));
    });
  });

  group('MockDigitalInkEngine Tests', () {
    late MockDigitalInkEngine engine;

    setUp(() {
      engine = MockDigitalInkEngine(
        initialDownloadedModels: {'ja': true, 'en': false},
      );
    });

    tearDown(() {
      engine.dispose();
    });

    test('returns correct initial model download status', () async {
      expect(await engine.isModelDownloaded('ja'), isTrue);
      expect(await engine.isModelDownloaded('ja-JP'), isTrue);
      expect(await engine.isModelDownloaded('en'), isFalse);
    });

    test('downloads model and updates status', () async {
      expect(await engine.isModelDownloaded('en'), isFalse);
      final success = await engine.downloadModel('en');
      expect(success, isTrue);
      expect(await engine.isModelDownloaded('en'), isTrue);
    });

    test('deletes model and updates status', () async {
      expect(await engine.isModelDownloaded('ja'), isTrue);
      final success = await engine.deleteModel('ja');
      expect(success, isTrue);
      expect(await engine.isModelDownloaded('ja'), isFalse);
    });

    test('returns empty candidate list when strokes are empty', () async {
      final candidates = await engine.getCandidates([], 'ja');
      expect(candidates, isEmpty);
    });

    test(
      'returns deterministic simulated candidates when configured',
      () async {
        engine.setCandidates(['あ', 'お', 'め']);

        final stroke = HandwritingStroke(
          points: [
            const StrokePoint(x: 10, y: 10, timestamp: 100),
            const StrokePoint(x: 20, y: 20, timestamp: 200),
          ],
        );

        final candidates = await engine.getCandidates([stroke], 'ja');
        expect(candidates, equals(['あ', 'お', 'め']));
      },
    );

    test(
      'falls back to heuristic recognition when no mock candidates are set',
      () async {
        final stroke = HandwritingStroke(
          points: [
            const StrokePoint(x: 10, y: 50, timestamp: 100),
            const StrokePoint(x: 100, y: 50, timestamp: 200),
          ],
        );

        final candidates = await engine.getCandidates([stroke], 'ja');
        expect(candidates, isNotEmpty);
        expect(candidates, contains('一'));
      },
    );
  });

  group('HeuristicDigitalInkEngine Tests', () {
    late HeuristicDigitalInkEngine engine;

    setUp(() {
      engine = HeuristicDigitalInkEngine();
    });

    tearDown(() {
      engine.dispose();
    });

    test(
      'isModelDownloaded returns false by default for offline mode',
      () async {
        expect(await engine.isModelDownloaded('ja'), isFalse);
        expect(await engine.isModelDownloaded('en'), isFalse);
      },
    );

    test('download and delete models manage in-memory state', () async {
      expect(await engine.downloadModel('ja'), isTrue);
      expect(await engine.isModelDownloaded('ja'), isTrue);

      expect(await engine.deleteModel('ja'), isTrue);
      expect(await engine.isModelDownloaded('ja'), isFalse);
    });

    test('returns empty candidates for empty stroke input', () async {
      final candidates = await engine.getCandidates([], 'ja');
      expect(candidates, isEmpty);
    });

    test('classifies single horizontal stroke as 一 in Japanese', () async {
      // Horizontal stroke: width (90) >> height (5) -> aspectRatio > 1.3
      final stroke = HandwritingStroke(
        points: [
          const StrokePoint(x: 10, y: 50, timestamp: 100),
          const StrokePoint(x: 100, y: 55, timestamp: 200),
        ],
      );

      final candidates = await engine.getCandidates([stroke], 'ja');
      expect(candidates, isNotEmpty);
      expect(candidates.first, equals('一'));
    });

    test('classifies single vertical stroke as し in Japanese', () async {
      // Vertical stroke: height (90) >> width (5) -> aspectRatio < 0.7
      final stroke = HandwritingStroke(
        points: [
          const StrokePoint(x: 50, y: 10, timestamp: 100),
          const StrokePoint(x: 55, y: 100, timestamp: 200),
        ],
      );

      final candidates = await engine.getCandidates([stroke], 'ja');
      expect(candidates, isNotEmpty);
      expect(candidates.first, equals('し'));
    });

    test('classifies 2 strokes in Japanese with い and り', () async {
      // Vertical parallel strokes for 'い'
      final stroke1 = HandwritingStroke(
        points: [
          const StrokePoint(x: 40, y: 20, timestamp: 100),
          const StrokePoint(x: 45, y: 100, timestamp: 200),
        ],
      );
      final stroke2 = HandwritingStroke(
        points: [
          const StrokePoint(x: 80, y: 30, timestamp: 300),
          const StrokePoint(x: 85, y: 90, timestamp: 400),
        ],
      );

      final candidates = await engine.getCandidates([stroke1, stroke2], 'ja');
      expect(candidates, isNotEmpty);
      expect(candidates, contains('い'));
    });

    test('classifies 3 strokes in Japanese with あ, さ, す', () async {
      final s1 = HandwritingStroke(
        points: [
          const StrokePoint(x: 20, y: 30, timestamp: 100),
          const StrokePoint(x: 80, y: 30, timestamp: 150),
        ],
      );
      final s2 = HandwritingStroke(
        points: [
          const StrokePoint(x: 50, y: 10, timestamp: 200),
          const StrokePoint(x: 50, y: 90, timestamp: 250),
        ],
      );
      final s3 = HandwritingStroke(
        points: [
          const StrokePoint(x: 40, y: 40, timestamp: 300),
          const StrokePoint(x: 60, y: 80, timestamp: 350),
        ],
      );

      final candidates = await engine.getCandidates([s1, s2, s3], 'ja');
      expect(candidates, isNotEmpty);
      expect(candidates, contains('あ'));
    });

    test('classifies English strokes for IT workplace keywords', () async {
      final strokes = List.generate(
        6,
        (i) => HandwritingStroke(
          points: [
            StrokePoint(x: 10.0 + i * 15, y: 20, timestamp: i * 100),
            StrokePoint(x: 10.0 + i * 15, y: 60, timestamp: i * 100 + 50),
          ],
        ),
      );

      final candidates = await engine.getCandidates(strokes, 'en');
      expect(candidates, isNotEmpty);
      expect(candidates, contains('deploy'));
    });
  });

  group('MlKitDigitalInkEngine Fallback Tests', () {
    test('native model failure does not report a downloaded model', () async {
      final engine = MlKitDigitalInkEngine(supportedPlatformForTesting: true);
      expect(await engine.downloadModel('ja'), isFalse);
      expect(await engine.isModelDownloaded('ja'), isFalse);
      expect(await engine.deleteModel('ja'), isFalse);
      engine.dispose();
    });
    test(
      'handles MissingPluginException safely in headless test environment',
      () async {
        final engine = MlKitDigitalInkEngine();

        // In Linux test sandbox without native ML Kit library,
        // it must not throw unhandled exception and must fallback cleanly
        final isDownloaded = await engine.isModelDownloaded('ja');
        expect(isDownloaded, isA<bool>());

        final stroke = HandwritingStroke(
          points: [
            const StrokePoint(x: 10, y: 50, timestamp: 100),
            const StrokePoint(x: 100, y: 50, timestamp: 200),
          ],
        );

        final candidates = await engine.getCandidates([stroke], 'ja');
        expect(candidates, isNotEmpty);

        engine.dispose();
      },
    );
  });
}
