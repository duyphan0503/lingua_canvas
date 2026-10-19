import 'dart:convert';
import 'package:flutter/services.dart';

/// A canonical pen-down trajectory, in character-cell coordinates and writing order.
class StrokeGuidePath {
  final int strokeNumber;
  final List<Offset> normalizedPoints;
  final String hintText;

  /// Retained for callers displaying their own explicitly illustrative paths.
  /// Paths returned by [StrokeGuideService] are always canonical KanjiVG data.
  final bool isIllustrative;

  StrokeGuidePath({
    required this.strokeNumber,
    required List<Offset> normalizedPoints,
    this.hintText = '',
    this.isIllustrative = false,
  }) : normalizedPoints = List.unmodifiable(normalizedPoints);
}

/// Coverage is explicit: a partial word never supplies a misleading stroke count.
class StrokeGuideCoverage {
  final bool dataAvailable;
  final List<String> unsupportedCharacters;
  final int? expectedStrokeCount;

  StrokeGuideCoverage({
    required this.dataAvailable,
    required List<String> unsupportedCharacters,
    required this.expectedStrokeCount,
  }) : unsupportedCharacters = List.unmodifiable(unsupportedCharacters);

  bool get isComplete => dataAvailable && expectedStrokeCount != null;
}

/// Offline KanjiVG base glyphs, derived under CC BY-SA 3.0 (see bundled NOTICE).
///
/// Await [initialize] at startup. Loading failure is explicitly unavailable;
/// unknown characters return no guides rather than invented stroke shapes.
class StrokeGuideService {
  static const assetPath = 'assets/kanjivg/strokes.json';
  static const sourceCommit = '70a0b7ae0c18ceb5cb358274b029cce0234a43bc';
  static const attribution = 'KanjiVG © Ulrich Apel — CC BY-SA 3.0';
  static Map<String, dynamic>? _characters;
  static Future<bool>? _loading;
  static bool get isAvailable => _characters != null;

  /// Explicit bundle injection supports offline tests without filesystem APIs.
  /// A supplied bundle can retry a failed default load; valid data stays cached.
  static Future<bool> initialize({AssetBundle? bundle}) {
    if (bundle != null) return _load(bundle);
    if (isAvailable) return Future.value(true);
    return _loading ??= _load(rootBundle);
  }

  static Future<bool> _load(AssetBundle bundle) async {
    try {
      final data = jsonDecode(await bundle.loadString(assetPath)) as Map;
      if (data['version'] != 1 ||
          data['quantization'] != 10000 ||
          (data['source'] as Map)['commit'] != sourceCommit ||
          (data['source'] as Map)['license'] != 'CC-BY-SA-3.0') {
        return false;
      }
      final characters = Map<String, dynamic>.from(data['characters'] as Map);
      if (characters.isEmpty) return false;
      for (final entry in characters.entries) {
        if (entry.key.runes.length != 1 ||
            entry.value is! List ||
            (entry.value as List).isEmpty) {
          return false;
        }
        for (final path in entry.value as List) {
          if (path is! List ||
              path.length < 4 ||
              path.length.isOdd ||
              path.any(
                (value) => value is! int || value < 0 || value > 10000,
              )) {
            return false;
          }
        }
      }
      // Publish only a completely parsed and validated dataset.
      _characters = Map.unmodifiable(characters);
      return true;
    } catch (_) {
      return false;
    }
  }

  static List<String> _textCharacters(String text) => text
      .trim()
      .runes
      .map(String.fromCharCode)
      .where((character) => character.trim().isNotEmpty)
      .toList();

  static StrokeGuideCoverage coverageFor(String targetText) {
    final characters = _textCharacters(targetText);
    final unsupported = characters
        .where((character) => !(_characters?.containsKey(character) ?? false))
        .toSet()
        .toList();
    return StrokeGuideCoverage(
      dataAvailable: isAvailable,
      unsupportedCharacters: unsupported,
      expectedStrokeCount:
          !isAvailable || characters.isEmpty || unsupported.isNotEmpty
          ? null
          : characters.fold<int>(
              0,
              (sum, character) =>
                  sum + (_characters![character] as List).length,
            ),
    );
  }

  static List<StrokeGuidePath> guidesFor(
    String targetText, {
    List<String> strokeOrderHints = const [],
  }) {
    if (!coverageFor(targetText).isComplete) return const [];
    final characters = _textCharacters(targetText);
    final result = <StrokeGuidePath>[];
    for (var cell = 0; cell < characters.length; cell++) {
      final character = characters[cell];
      final paths = _characters![character] as List;
      for (var stroke = 0; stroke < paths.length; stroke++) {
        final points = paths[stroke] as List;
        result.add(
          StrokeGuidePath(
            strokeNumber: result.length + 1,
            normalizedPoints: [
              for (var i = 0; i < points.length; i += 2)
                Offset(
                  (cell + .04 + .92 * (points[i] as int) / 10000) /
                      characters.length,
                  (points[i + 1] as int) / 10000,
                ),
            ],
            hintText: characters.length == 1 && stroke < strokeOrderHints.length
                ? strokeOrderHints[stroke]
                : '$character · Nét ${stroke + 1}',
          ),
        );
      }
    }
    return List.unmodifiable(result);
  }

  /// Compatibility entry point: hints are prose, never a source of glyph geometry.
  @Deprecated('Use coverageFor to report unsupported characters')
  static List<StrokeGuidePath> generateFallbackGuides(
    String targetText,
    List<String> strokeOrderHints,
  ) => const [];
}
