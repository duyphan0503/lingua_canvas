import 'dart:math' as math;
import 'dart:ui';

/// A pen-down trajectory, in character-cell coordinates, in writing order.
class StrokeGuidePath {
  final int strokeNumber;
  final List<Offset> normalizedPoints;
  final String hintText;

  /// True for schematic trajectories that must be labelled as illustrative.
  final bool isIllustrative;

  StrokeGuidePath({
    required this.strokeNumber,
    required List<Offset> normalizedPoints,
    this.hintText = '',
    this.isIllustrative = false,
  }) : normalizedPoints = List.unmodifiable(normalizedPoints);
}

/// Local, dependency-free pen trajectories. Curves are sampled polylines.
///
/// Basic glyphs use hand-authored stroke sequences. Complex glyphs assembled
/// from components are explicitly illustrative pending a reviewed reference
/// dataset; they must not be presented as authoritative calligraphy models.
class StrokeGuideService {
  static final Map<String, List<List<Offset>>> _characters = _buildCharacters();
  static const _illustrativeCharacters = {
    '発',
    '確',
    '認',
    '議',
    '連',
    '絡',
    '談',
    '報',
  };

  static List<StrokeGuidePath> guidesFor(
    String targetText, {
    List<String> strokeOrderHints = const [],
  }) {
    final characters = targetText
        .trim()
        .runes
        .map(String.fromCharCode)
        .where((character) => character.trim().isNotEmpty)
        .toList();
    if (characters.isEmpty) return const [];
    if (!characters.any(_characters.containsKey)) {
      return generateFallbackGuides(targetText, strokeOrderHints);
    }
    final result = <StrokeGuidePath>[];
    for (var cell = 0; cell < characters.length; cell++) {
      final character = characters[cell];
      final paths = _characters[character];
      final guides = paths == null
          ? generateFallbackGuides(character, strokeOrderHints)
          : [
              for (var i = 0; i < paths.length; i++)
                StrokeGuidePath(
                  strokeNumber: i + 1,
                  normalizedPoints: paths[i],
                  hintText:
                      characters.length == 1 && i < strokeOrderHints.length
                      ? strokeOrderHints[i]
                      : '$character · Nét ${i + 1}',
                  isIllustrative: _illustrativeCharacters.contains(character),
                ),
            ];
      for (final guide in guides) {
        result.add(
          StrokeGuidePath(
            strokeNumber: result.length + 1,
            normalizedPoints: [
              for (final point in guide.normalizedPoints)
                Offset(
                  (cell + .04 + .92 * point.dx) / characters.length,
                  point.dy,
                ),
            ],
            hintText: guide.hintText,
            isIllustrative: guide.isIllustrative,
          ),
        );
      }
    }
    return List.unmodifiable(result);
  }

  /// Generates one schematic path per hint, never a claimed glyph outline.
  static List<StrokeGuidePath> generateFallbackGuides(
    String targetText,
    List<String> strokeOrderHints,
  ) {
    if (targetText.trim().isEmpty) return const [];
    return List.unmodifiable([
      for (var i = 0; i < strokeOrderHints.length; i++)
        StrokeGuidePath(
          strokeNumber: i + 1,
          normalizedPoints: _hintPath(strokeOrderHints[i], i),
          hintText: strokeOrderHints[i],
          isIllustrative: true,
        ),
    ]);
  }

  static List<Offset> _hintPath(String hint, int index) {
    final text = hint.toLowerCase();
    final row = .25 + (index % 4) * .15;
    if (text.contains('vòng') || text.contains('tròn')) {
      return [
        for (var i = 0; i <= 24; i++)
          Offset(
            .5 + .25 * math.cos(i * math.pi / 12),
            .5 + .25 * math.sin(i * math.pi / 12),
          ),
      ];
    }
    if (text.contains('cong') || text.contains('móc')) {
      return _s([.3, .2, .6, .25, .72, .45, .65, .7, .45, .8]);
    }
    if (text.contains('phẩy')) return _s([.7, .2, .5, .55, .25, .8]);
    if (text.contains('mác')) return _s([.3, .2, .5, .55, .8, .8]);
    if (text.contains('ngang')) return _s([.2, row, .8, row]);
    if (text.contains('sổ') || text.contains('dọc') || text.contains('thẳng')) {
      return _s([.5, .2, .5, .8]);
    }
    return _s([.2, row, .8, row]);
  }

  static List<Offset> _s(List<double> coordinates) => [
    for (var i = 0; i < coordinates.length; i += 2)
      Offset(coordinates[i], coordinates[i + 1]),
  ];

  static List<List<Offset>> _place(
    List<List<Offset>> strokes,
    double x,
    double y,
    double width,
    double height,
  ) => [
    for (final stroke in strokes)
      [
        for (final point in stroke)
          Offset(x + point.dx * width, y + point.dy * height),
      ],
  ];

  static Map<String, List<List<Offset>>> _buildCharacters() {
    final wood = [
      _s([.15, .35, .85, .35]),
      _s([.5, .12, .5, .9]),
      _s([.48, .37, .35, .59, .12, .8]),
      _s([.52, .37, .65, .59, .88, .8]),
    ];
    final mouth = [
      _s([.2, .2, .2, .85]),
      _s([.2, .2, .8, .2, .8, .85]),
      _s([.2, .85, .8, .85]),
    ];
    final day = [
      _s([.25, .15, .25, .85]),
      _s([.25, .15, .75, .15, .75, .85]),
      _s([.25, .5, .75, .5]),
      _s([.25, .85, .75, .85]),
    ];
    final eye = [
      day[0],
      day[1],
      _s([.25, .38, .75, .38]),
      _s([.25, .62, .75, .62]),
      day[3],
    ];
    final fire = [
      _s([.22, .35, .3, .52]),
      _s([.8, .28, .65, .48]),
      _s([.5, .12, .48, .5, .36, .7, .15, .85]),
      _s([.5, .48, .65, .7, .86, .85]),
    ];
    final speech = [
      _s([.47, .08, .57, .18]),
      _s([.12, .27, .88, .27]),
      _s([.25, .4, .75, .4]),
      _s([.25, .53, .75, .53]),
      ..._place(mouth, .12, .58, .76, .4),
    ];
    final person = [
      _s([.52, .15, .42, .52, .15, .88]),
      _s([.5, .38, .65, .68, .87, .88]),
    ];
    final vehicle = [
      _s([.13, .14, .87, .14]),
      _s([.23, .28, .23, .66]),
      _s([.23, .28, .77, .28, .77, .66]),
      _s([.23, .47, .77, .47]),
      _s([.23, .66, .77, .66]),
      _s([.08, .8, .92, .8]),
      _s([.5, .06, .5, .94]),
    ];
    final thread = [
      _s([.55, .08, .27, .35, .58, .35]),
      _s([.67, .22, .25, .6, .72, .57]),
      _s([.64, .46, .78, .64]),
      _s([.5, .6, .5, .93]),
      _s([.32, .68, .17, .88]),
      _s([.67, .68, .82, .88]),
    ];
    final each = [
      _s([.45, .05, .3, .22, .15, .31]),
      _s([.36, .18, .77, .18, .58, .39, .15, .57]),
      _s([.32, .28, .58, .46, .9, .57]),
      ..._place(mouth, .16, .56, .68, .43),
    ];
    final sheep = [
      _s([.25, .06, .35, .2]),
      _s([.74, .06, .64, .2]),
      _s([.18, .25, .82, .25]),
      _s([.25, .46, .75, .46]),
      _s([.12, .68, .88, .68]),
      _s([.5, .25, .5, .95]),
    ];
    final self = [
      _s([.38, .08, .18, .2]),
      _s([.1, .34, .65, .34]),
      _s([.36, .17, .36, .87, .28, .9]),
      _s([.1, .65, .62, .47]),
      _s([.56, .08, .59, .47, .7, .76, .85, .9, .9, .72]),
      _s([.86, .38, .7, .65, .52, .86]),
      _s([.74, .1, .86, .23]),
    ];
    final knifeHeart = [
      _s([.2, .12, .8, .12, .74, .44, .6, .46]),
      _s([.5, .12, .42, .34, .2, .49]),
      _s([.39, .22, .6, .35]),
      _s([.2, .65, .12, .84]),
      _s([.35, .57, .35, .84, .47, .91, .75, .88, .79, .77]),
      _s([.48, .57, .59, .69]),
      _s([.77, .6, .9, .78]),
    ];
    final roof = [
      _s([.14, .1, .14, .31]),
      _s([.14, .14, .86, .14, .82, .29]),
    ];
    final bird = [
      _s([.35, .1, .18, .4]),
      _s([.26, .3, .26, .92]),
      _s([.58, .1, .67, .23]),
      _s([.27, .3, .88, .3]),
      _s([.58, .3, .58, .87]),
      _s([.27, .49, .82, .49]),
      _s([.27, .68, .82, .68]),
      _s([.27, .87, .9, .87]),
    ];
    final stone = [
      _s([.12, .18, .9, .18]),
      _s([.48, .18, .33, .44, .12, .64]),
      ..._place(mouth, .23, .42, .68, .56),
    ];
    final gate = [
      _s([.12, .12, .12, .9]),
      _s([.12, .12, .42, .12, .42, .4]),
      _s([.12, .26, .42, .26]),
      _s([.12, .4, .42, .4]),
      _s([.58, .12, .58, .4]),
      _s([.58, .12, .88, .12, .88, .88, .78, .9]),
      _s([.58, .26, .88, .26]),
      _s([.58, .4, .88, .4]),
    ];
    final opening = [
      _s([.33, .52, .67, .52]),
      _s([.25, .66, .75, .66]),
      _s([.4, .52, .4, .76, .31, .86]),
      _s([.61, .52, .61, .86]),
    ];
    final happiness = [
      _s([.22, .15, .78, .15]),
      _s([.5, .05, .5, .29]),
      _s([.1, .3, .9, .3]),
      _s([.28, .36, .38, .47]),
      _s([.73, .36, .63, .47]),
      _s([.12, .51, .88, .51]),
      _s([.2, .71, .8, .71]),
      _s([.5, .51, .5, .95]),
    ];
    final reportRight = [
      _s([.12, .1, .85, .1, .85, .4, .58, .4]),
      _s([.12, .1, .12, .91]),
      _s([.2, .48, .8, .48, .59, .76, .27, .91]),
      _s([.3, .51, .54, .77, .9, .91]),
    ];
    return {
      'あ': [
        _s([.2, .28, .5, .27, .78, .23]),
        _s([.46, .1, .43, .36, .43, .63, .51, .86]),
        _s([
          .65,
          .38,
          .57,
          .62,
          .37,
          .82,
          .2,
          .81,
          .14,
          .68,
          .23,
          .53,
          .5,
          .45,
          .74,
          .5,
          .85,
          .66,
          .8,
          .81,
          .66,
          .88,
        ]),
      ],
      'い': [
        _s([.25, .18, .23, .48, .29, .75, .38, .83, .47, .68]),
        _s([.68, .22, .77, .39, .8, .61]),
      ],
      'う': [
        _s([.39, .12, .58, .17, .66, .15]),
        _s([
          .21,
          .37,
          .46,
          .29,
          .69,
          .32,
          .79,
          .45,
          .73,
          .64,
          .58,
          .81,
          .38,
          .9,
        ]),
      ],
      'え': [
        _s([.4, .11, .58, .18, .66, .16]),
        _s([
          .22,
          .37,
          .72,
          .3,
          .46,
          .57,
          .19,
          .85,
          .43,
          .64,
          .57,
          .65,
          .57,
          .82,
          .73,
          .88,
          .86,
          .84,
        ]),
      ],
      'お': [
        _s([.17, .31, .47, .29, .65, .23]),
        _s([
          .44,
          .1,
          .44,
          .84,
          .34,
          .88,
          .19,
          .75,
          .22,
          .62,
          .48,
          .49,
          .73,
          .52,
          .82,
          .68,
          .76,
          .82,
          .62,
          .86,
        ]),
        _s([.7, .16, .83, .26, .88, .34]),
      ],
      'か': [
        _s([.14, .37, .53, .31, .62, .36, .58, .68, .49, .85, .36, .79]),
        _s([.46, .12, .4, .43, .25, .73, .14, .87]),
        _s([.7, .24, .83, .42, .87, .56]),
      ],
      'き': [
        _s([.23, .28, .71, .2]),
        _s([.16, .48, .8, .38]),
        _s([.44, .09, .51, .38, .68, .63, .56, .59]),
        _s([.3, .64, .23, .74, .33, .85, .59, .89, .76, .86]),
      ],
      'く': [
        _s([.7, .12, .3, .49, .7, .88]),
      ],
      'け': [
        _s([.23, .15, .19, .48, .21, .77, .28, .68]),
        _s([.42, .36, .83, .32]),
        _s([.66, .1, .68, .53, .63, .76, .49, .89]),
      ],
      'こ': [
        _s([.27, .24, .69, .23, .75, .26, .65, .37]),
        _s([.28, .62, .22, .73, .3, .82, .57, .85, .78, .81]),
      ],
      '日': day,
      '月': [
        _s([.26, .12, .26, .63, .2, .84, .12, .92]),
        _s([.26, .12, .78, .12, .78, .88, .64, .91]),
        _s([.26, .38, .78, .38]),
        _s([.26, .63, .78, .63]),
      ],
      '木': wood,
      '水': [
        _s([.5, .1, .5, .88, .39, .92]),
        _s([.12, .38, .36, .38, .27, .62, .1, .8]),
        _s([.84, .25, .65, .43]),
        _s([.55, .34, .68, .61, .89, .81]),
      ],
      '金': [
        ..._place(person, .04, .01, .92, .43),
        _s([.28, .4, .72, .4]),
        _s([.18, .54, .82, .54]),
        _s([.5, .4, .5, .89]),
        _s([.26, .64, .35, .8]),
        _s([.74, .64, .65, .8]),
        _s([.12, .9, .88, .9]),
      ],
      '土': [
        _s([.22, .38, .78, .38]),
        _s([.5, .13, .5, .86]),
        _s([.12, .86, .88, .86]),
      ],
      '山': [
        _s([.5, .1, .5, .83]),
        _s([.18, .35, .18, .83, .82, .83]),
        _s([.82, .35, .82, .83]),
      ],
      '川': [
        _s([.22, .13, .22, .65, .13, .87]),
        _s([.49, .19, .49, .79]),
        _s([.78, .1, .78, .89]),
      ],
      '人': person,
      '本': [
        ...wood,
        _s([.3, .71, .7, .71]),
      ],
      '開': [...gate, ...opening],
      '発': [
        _s([.17, .1, .47, .1, .34, .29, .11, .45]),
        _s([.12, .2, .24, .32]),
        _s([.69, .08, .55, .22]),
        _s([.85, .17, .7, .31]),
        _s([.52, .13, .7, .34, .91, .43]),
        _s([.32, .43, .68, .43]),
        _s([.2, .58, .8, .58]),
        _s([.4, .43, .4, .66, .3, .83, .15, .91]),
        _s([.62, .43, .62, .84, .7, .9, .88, .88, .9, .75]),
      ],
      '確': [
        ..._place(stone, .02, .17, .36, .74),
        ..._place(roof, .39, .03, .6, .28),
        ..._place(bird, .39, .2, .6, .78),
      ],
      '認': [
        ..._place(speech, .01, .04, .36, .92),
        ..._place(knifeHeart, .39, .02, .6, .96),
      ],
      '会': [
        ..._place(person, .02, .01, .96, .48),
        _s([.28, .43, .72, .43]),
        _s([.16, .59, .84, .59]),
        _s([.46, .59, .25, .86, .76, .83]),
        _s([.65, .7, .83, .9]),
      ],
      '議': [
        ..._place(speech, .01, .04, .33, .92),
        ..._place(sheep, .35, .02, .64, .46),
        ..._place(self, .35, .44, .64, .55),
      ],
      '連': [
        ..._place(vehicle, .28, .02, .68, .78),
        _s([.1, .15, .21, .26]),
        _s([.05, .38, .2, .38, .13, .56, .22, .68, .14, .8]),
        _s([.03, .86, .16, .8, .32, .9, .63, .93, .94, .9]),
      ],
      '絡': [
        ..._place(thread, .01, .02, .36, .95),
        ..._place(each, .39, .02, .6, .94),
      ],
      '相': [
        ..._place(wood, .01, .03, .45, .93),
        ..._place(eye, .47, .02, .52, .94),
      ],
      '談': [
        ..._place(speech, .01, .04, .36, .92),
        ..._place(fire, .39, .01, .6, .49),
        ..._place(fire, .39, .47, .6, .52),
      ],
      '報': [
        ..._place(happiness, .01, .02, .45, .94),
        ..._place(reportRight, .48, .03, .5, .93),
      ],
      '告': [
        _s([.31, .1, .2, .31]),
        _s([.28, .24, .76, .24]),
        _s([.5, .07, .5, .45]),
        _s([.12, .46, .88, .46]),
        ..._place(mouth, .12, .51, .76, .45),
      ],
    };
  }
}
