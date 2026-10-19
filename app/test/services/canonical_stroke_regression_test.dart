import 'package:app/services/stroke_guide_service.dart';
import 'package:app/services/handwriting_recognizer.dart';
import 'package:app/services/digital_ink_engine.dart';
import 'package:flutter_test/flutter_test.dart';

List<HandwritingStroke> trace(
  String target, {
  bool reverse = false,
  double scale = 300,
  double shift = 20,
}) => [
  for (final guide in StrokeGuideService.guidesFor(target))
    HandwritingStroke(
      points: [
        for (final point
            in reverse
                ? guide.normalizedPoints.reversed
                : guide.normalizedPoints)
          StrokePoint(
            x: shift + point.dx * scale,
            y: shift + point.dy * scale,
            timestamp: 0,
          ),
      ],
    ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    expect(await StrokeGuideService.initialize(), isTrue);
  });
  test(
    '発 stroke four uses the upstream down-right stroke before the second flick',
    () {
      final paths = StrokeGuideService.guidesFor('発');
      // KanjiVG 0767a-s4: M49.25,20.26 ... 96.25,56.68, on a 109px cell.
      expect(
        paths[3].normalizedPoints.first.dx,
        closeTo(.04 + .92 * 49.25 / 109, .0001),
      );
      expect(
        paths[3].normalizedPoints.last.dx,
        closeTo(.04 + .92 * 96.25 / 109, .0001),
      );
      expect(paths.every((path) => !path.isIllustrative), isTrue);
    },
  );

  test(
    'compound 開発 counts twenty-one strokes despite two prose hints',
    () async {
      final engine = MockDigitalInkEngine()..setCandidates(['開発']);
      final result = await HandwritingRecognizer(engine: engine).evaluate(
        strokes: trace('開発'),
        targetText: '開発',
        strokeOrderHints: ['開: 門', '発: 癶'],
      );
      expect(result.similarityScore, greaterThan(.90));
      engine.dispose();
    },
  );

  test(
    'reversing canonical strokes receives direction feedback and lower score',
    () async {
      final engine = MockDigitalInkEngine()..setCandidates(['木']);
      final recognizer = HandwritingRecognizer(engine: engine);
      final forward = await recognizer.evaluate(
        strokes: trace('木'),
        targetText: '木',
        strokeOrderHints: [],
      );
      final backward = await recognizer.evaluate(
        strokes: trace('木', reverse: true),
        targetText: '木',
        strokeOrderHints: [],
      );
      expect(backward.similarityScore, lessThan(forward.similarityScore));
      expect(backward.feedbackMessage, contains('hướng'));
      engine.dispose();
    },
  );
  test(
    'correct direction score survives scale and translation changes',
    () async {
      final engine = MockDigitalInkEngine()..setCandidates(['木']);
      final recognizer = HandwritingRecognizer(engine: engine);
      final small = await recognizer.evaluate(
        strokes: trace('木', scale: 150, shift: 80),
        targetText: '木',
        strokeOrderHints: [],
      );
      final large = await recognizer.evaluate(
        strokes: trace('木', scale: 450, shift: -100),
        targetText: '木',
        strokeOrderHints: [],
      );
      expect(small.isAccurate, isTrue);
      expect(large.isAccurate, isTrue);
      expect(small.similarityScore, closeTo(large.similarityScore, .000001));
      engine.dispose();
    },
  );

  test(
    'compound without prose hints still uses the canonical twenty-one strokes',
    () async {
      final engine = MockDigitalInkEngine()..setCandidates(['開発']);
      final result = await HandwritingRecognizer(
        engine: engine,
      ).evaluate(strokes: trace('開発'), targetText: '開発', strokeOrderHints: []);
      expect(result.similarityScore, closeTo(.965, .000001));
      engine.dispose();
    },
  );

  test(
    'unavailable glyphs and English keep prior candidate and hint scoring',
    () async {
      final strokes = [
        HandwritingStroke(
          points: List.generate(
            15,
            (i) => StrokePoint(x: 50 + i * 10.0, y: 50 + i * 5.0, timestamp: i),
          ),
        ),
      ];
      final engine = MockDigitalInkEngine();
      for (final entry in {'🦄': 'ja', 'deploy': 'en'}.entries) {
        engine.setCandidates([entry.key]);
        final result = await HandwritingRecognizer(engine: engine).evaluate(
          strokes: strokes,
          targetText: entry.key,
          strokeOrderHints: ['one hint'],
          languageTag: entry.value,
        );
        expect(result.isAccurate, isTrue);
        expect(result.similarityScore, closeTo(.965, .000001));
      }
      engine.dispose();
    },
  );
}
