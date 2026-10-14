import 'package:app/services/stroke_guide_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  test('mapped characters have complete ordered normalized stroke guides', () {
    for (final entry in counts.entries) {
      final guides = StrokeGuideService.guidesFor(entry.key);
      expect(guides, hasLength(entry.value), reason: entry.key);
      for (var i = 0; i < guides.length; i++) {
        expect(guides[i].strokeNumber, i + 1);
        expect(guides[i].normalizedPoints.length, greaterThanOrEqualTo(2));
        for (final point in guides[i].normalizedPoints) {
          expect(point.dx, inInclusiveRange(0.0, 1.0));
          expect(point.dy, inInclusiveRange(0.0, 1.0));
        }
      }
    }
  });

  test(
    'basic character guides preserve pen direction and final cross stroke',
    () {
      final day = StrokeGuideService.guidesFor('日');
      expect(
        day.first.normalizedPoints.first.dy,
        lessThan(day.first.normalizedPoints.last.dy),
      );
      expect(
        day[1].normalizedPoints.first.dx,
        lessThan(day[1].normalizedPoints[1].dx),
      );
      final book = StrokeGuideService.guidesFor('本');
      expect(
        book.last.normalizedPoints.first.dx,
        lessThan(book.last.normalizedPoints.last.dx),
      );
      expect(
        book.last.normalizedPoints.first.dy,
        book.last.normalizedPoints.last.dy,
      );
    },
  );

  test(
    'known compound uses separate cells instead of generic hint strokes',
    () {
      final guides = StrokeGuideService.guidesFor(
        '開発',
        strokeOrderHints: ['左', '右'],
      );
      expect(guides, hasLength(21));
      expect(
        guides
            .take(12)
            .expand((g) => g.normalizedPoints)
            .every((p) => p.dx < 0.5),
        isTrue,
      );
      expect(
        guides
            .skip(12)
            .expand((g) => g.normalizedPoints)
            .every((p) => p.dx > 0.5),
        isTrue,
      );
      expect(guides.last.strokeNumber, 21);
    },
  );

  test('fallback respects hint count, keywords and illustrative metadata', () {
    final hints = [
      'Nét ngang',
      'Nét sổ thẳng',
      'Nét phẩy',
      'Nét mác',
      'Nét cong',
      'Vòng tròn',
    ];
    final guides = StrokeGuideService.generateFallbackGuides('?', hints);
    expect(guides, hasLength(6));
    expect(guides.every((g) => g.isIllustrative), isTrue);
    expect(guides.map((g) => g.hintText), hints);
    final horizontal = guides[0].normalizedPoints;
    expect(horizontal.first.dy, horizontal.last.dy);
    expect(horizontal.first.dx, lessThan(horizontal.last.dx));
    final vertical = guides[1].normalizedPoints;
    expect(vertical.first.dx, vertical.last.dx);
    expect(vertical.first.dy, lessThan(vertical.last.dy));
    final left = guides[2].normalizedPoints;
    expect(left.first.dx, greaterThan(left.last.dx));
    final right = guides[3].normalizedPoints;
    expect(right.first.dx, lessThan(right.last.dx));
    expect(guides[4].normalizedPoints.length, greaterThan(2));
    final circle = guides[5].normalizedPoints;
    expect((circle.first - circle.last).distance, lessThan(0.001));
  });

  test(
    'unknown input is safe without hints and empty target has no guides',
    () {
      expect(StrokeGuideService.guidesFor(''), isEmpty);
      expect(StrokeGuideService.guidesFor('  '), isEmpty);
      expect(
        StrokeGuideService.generateFallbackGuides('', ['Nét ngang']),
        isEmpty,
      );
      expect(StrokeGuideService.guidesFor('?'), isEmpty);
    },
  );

  test('known characters survive alongside an unknown character', () {
    final guides = StrokeGuideService.guidesFor(
      '日?',
      strokeOrderHints: ['Nét cong'],
    );
    expect(guides, hasLength(5));
    expect(guides.last.isIllustrative, isTrue);
    expect(guides.last.normalizedPoints.every((p) => p.dx > .5), isTrue);
  });

  test('public paths do not allow callers to corrupt subsequent guides', () {
    final guides = StrokeGuideService.guidesFor('日');
    expect(
      () => guides.first.normalizedPoints.add(Offset.zero),
      throwsUnsupportedError,
    );
    expect(StrokeGuideService.guidesFor('日'), hasLength(4));
  });
  test('horizontal keyword wins over a straight-line qualifier', () {
    final path = StrokeGuideService.generateFallbackGuides('?', [
      'Nét ngang thẳng',
    ]).single.normalizedPoints;
    expect(path.first.dy, path.last.dy);
    expect(path.first.dx, lessThan(path.last.dx));
  });

  test(
    'component sketches retain explicit illustrative metadata in compounds',
    () {
      final guides = StrokeGuideService.guidesFor('日議');
      expect(guides.take(4).every((g) => !g.isIllustrative), isTrue);
      expect(guides.skip(4).every((g) => g.isIllustrative), isTrue);
      expect(() => guides.clear(), throwsUnsupportedError);
    },
  );
  test('an unknown word produces one illustrative stroke per hint', () {
    final hints = ['Nét ngang', 'Nét sổ thẳng'];
    final guides = StrokeGuideService.guidesFor(
      'objective',
      strokeOrderHints: hints,
    );
    expect(guides, hasLength(2));
    expect(guides.map((g) => g.hintText), hints);
    expect(guides.every((g) => g.isIllustrative), isTrue);
  });
}
