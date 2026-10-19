import 'generated_pitch_accent.dart';

/// Exact word-reading entries selected from the pinned Kanjium source.
class JapanesePitchAccentRepository {
  const JapanesePitchAccentRepository();

  static const String provenance =
      'Kanjium, Uros O. · CC BY-SA 4.0 · source commit 9ebca458';
  static const int coveredPairs = 56;
  static const int coveredPatterns = 60;

  JapanesePitchAccent? lookup(String word, {String? reading}) {
    final entries = lookupAll(word, reading: reading);
    return entries.isEmpty ? null : entries.first;
  }

  List<JapanesePitchAccent> lookupAll(String word, {String? reading}) =>
      List.unmodifiable(
        generatedPitchAccentEntries
            .where(
              (entry) =>
                  entry['word'] == word &&
                  (reading == null || entry['reading'] == reading),
            )
            .map(
              (entry) => JapanesePitchAccent(
                word: entry['word']! as String,
                reading: entry['reading']! as String,
                downstep: entry['downstep']! as int,
              ),
            ),
      );
}

class JapanesePitchAccent {
  final String word;
  final String reading;
  final int downstep;

  const JapanesePitchAccent({
    required this.word,
    required this.reading,
    required this.downstep,
  });

  List<String> get morae {
    const smallKana = {
      'ぁ', 'ぃ', 'ぅ', 'ぇ', 'ぉ', 'ゃ', 'ゅ', 'ょ', 'ゎ', 'ゕ', 'ゖ',
    };
    final result = <String>[];
    for (final rune in reading.runes) {
      final character = String.fromCharCode(rune);
      if (smallKana.contains(character) && result.isNotEmpty) {
        result[result.length - 1] += character;
      } else {
        result.add(character);
      }
    }
    return result;
  }

  String get patternName {
    if (downstep == 0) return 'Heiban';
    if (downstep == 1) return 'Atamadaka';
    if (downstep == morae.length) return 'Odaka';
    return 'Nakadaka';
  }

  List<bool> get highPitchByMora {
    final count = morae.length;
    return List.generate(count + 1, (index) {
      if (index == count) return downstep == 0;
      if (downstep == 0) return index > 0;
      if (downstep == 1) return index == 0;
      if (index == 0) return false;
      return index <= downstep;
    }, growable: false);
  }
}
