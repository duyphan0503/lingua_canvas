import 'package:app/services/stroke_guide_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class MissingBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => throw StateError('missing asset');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'missing asset exposes unavailable coverage and never makes a shape',
    () async {
      expect(
        await StrokeGuideService.initialize(bundle: MissingBundle()),
        isFalse,
      );
      expect(StrokeGuideService.isAvailable, isFalse);
      final coverage = StrokeGuideService.coverageFor('日');
      expect(coverage.dataAvailable, isFalse);
      expect(coverage.expectedStrokeCount, isNull);
      expect(
        StrokeGuideService.guidesFor('日', strokeOrderHints: ['Nét ngang']),
        isEmpty,
      );
    },
  );

  group('bundled canonical paths', () {
    setUpAll(() async {
      expect(await StrokeGuideService.initialize(), isTrue);
    });

    const counts = {
      'あ': 3,
      'い': 2,
      'う': 2,
      'え': 2,
      'お': 3,
      'か': 3,
      'き': 4,
      'く': 1,
      'け': 3,
      'こ': 2,
      '日': 4,
      '月': 4,
      '木': 4,
      '水': 4,
      '金': 8,
      '土': 3,
      '山': 3,
      '川': 3,
      '人': 2,
      '本': 5,
      '開': 12,
      '発': 9,
      '確': 15,
      '認': 14,
      '会': 6,
      '議': 20,
      '連': 10,
      '絡': 12,
      '相': 9,
      '談': 15,
      '報': 12,
      '告': 7,
    };

    test(
      'known glyph counts, order, bounds and canonical metadata are complete',
      () {
        for (final entry in counts.entries) {
          final guides = StrokeGuideService.guidesFor(entry.key);
          expect(guides, hasLength(entry.value), reason: entry.key);
          expect(
            StrokeGuideService.coverageFor(entry.key).expectedStrokeCount,
            entry.value,
          );
          for (var i = 0; i < guides.length; i++) {
            expect(guides[i].strokeNumber, i + 1);
            expect(guides[i].isIllustrative, isFalse);
            expect(guides[i].normalizedPoints.length, greaterThanOrEqualTo(2));
            for (final point in guides[i].normalizedPoints) {
              expect(point.dx, inInclusiveRange(0.0, 1.0));
              expect(point.dy, inInclusiveRange(0.0, 1.0));
            }
          }
        }
      },
    );

    test(
      'compound characters occupy separate cells and use canonical totals',
      () {
        final guides = StrokeGuideService.guidesFor(
          '開発',
          strokeOrderHints: ['開', '発'],
        );
        expect(guides, hasLength(21));
        expect(
          guides
              .take(12)
              .expand((g) => g.normalizedPoints)
              .every((p) => p.dx < .5),
          isTrue,
        );
        expect(
          guides
              .skip(12)
              .expand((g) => g.normalizedPoints)
              .every((p) => p.dx > .5),
          isTrue,
        );
        expect(guides.last.strokeNumber, 21);
      },
    );

    test(
      'unsupported compounds explicitly report gaps instead of partial or invented strokes',
      () {
        final coverage = StrokeGuideService.coverageFor('日🦄');
        expect(coverage.dataAvailable, isTrue);
        expect(coverage.isComplete, isFalse);
        expect(coverage.unsupportedCharacters, ['🦄']);
        expect(coverage.expectedStrokeCount, isNull);
        expect(
          StrokeGuideService.guidesFor('日🦄', strokeOrderHints: ['Nét ngang']),
          isEmpty,
        );
        expect(
          StrokeGuideService.guidesFor('🦄', strokeOrderHints: ['Nét ngang']),
          isEmpty,
        );
        expect(StrokeGuideService.guidesFor('  '), isEmpty);
      },
    );

    test('canonical basic strokes preserve pen direction', () {
      final day = StrokeGuideService.guidesFor('日');
      expect(
        day.first.normalizedPoints.first.dy,
        lessThan(day.first.normalizedPoints.last.dy),
      );
      final book = StrokeGuideService.guidesFor('本');
      expect(
        book.last.normalizedPoints.first.dx,
        lessThan(book.last.normalizedPoints.last.dx),
      );
    });

    test('public paths and coverage cannot be mutated', () {
      final guides = StrokeGuideService.guidesFor('日');
      expect(
        () => guides.first.normalizedPoints.add(Offset.zero),
        throwsUnsupportedError,
      );
      expect(() => guides.clear(), throwsUnsupportedError);
      expect(
        () =>
            StrokeGuideService.coverageFor('🦄').unsupportedCharacters.clear(),
        throwsUnsupportedError,
      );
      expect(StrokeGuideService.guidesFor('日'), hasLength(4));
    });
  });
}
