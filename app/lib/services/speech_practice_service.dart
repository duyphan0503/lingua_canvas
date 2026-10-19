import 'dart:math' as math;
import 'speech/speech_types.dart';
import 'speech/speech_factory_native.dart'
    if (dart.library.js_interop) 'speech/speech_factory_web.dart';
export 'speech/speech_types.dart';
export 'speech/speech_factory_native.dart'
    if (dart.library.js_interop) 'speech/speech_factory_web.dart';

class SpeechPracticeService {
  // IndexedStack keeps multiple practice screens alive. They must share one
  // channel handler and recording lifecycle rather than replace one another.
  static final SpeechPracticeEngine _platformEngine =
      createSpeechPracticeEngine();
  final SpeechPracticeEngine _engine;

  SpeechPracticeService({SpeechPracticeEngine? engine})
    : _engine = engine ?? _platformEngine;

  Future<bool> isAvailable() => _engine.isAvailable();
  Future<String> listen({required String language}) =>
      _engine.listen(language: language);
  Future<void> stop() => _engine.stop();

  PronunciationResult evaluatePronunciation({
    required String recognized,
    required String targetText,
    required String phoneticOrKana,
    required String language,
  }) {
    final heard = _normalize(recognized);
    final candidates = [
      targetText,
      phoneticOrKana,
    ].map(_normalize).where((text) => text.isNotEmpty);
    var accuracy = 0.0;
    if (heard.isNotEmpty) {
      for (final target in candidates) {
        accuracy = math.max(accuracy, _similarity(heard, target));
      }
    }
    final percent = (accuracy * 100).round();
    final passed = accuracy >= 0.75;
    final mismatches = _transcriptMismatches(
      recognized,
      targetText,
      japanese: language.toLowerCase().startsWith('ja'),
    );
    final String feedback;
    if (heard.isEmpty) {
      feedback =
          'Chưa có văn bản nhận diện (0%). Đây là đối chiếu transcript, không đo trực tiếp chất lượng âm thanh.';
    } else if (passed) {
      final mismatchText = mismatches.isEmpty
          ? ''
          : ' Chưa khớp ở: ${mismatches.join(', ')}.';
      feedback =
          'Văn bản nhận diện khớp $percent% với câu mẫu.$mismatchText Chỉ số này không chẩn đoán âm thanh hay âm vị.';
    } else {
      final mismatchText = mismatches.isEmpty
          ? ''
          : ' Chưa khớp ở: ${mismatches.join(', ')}.';
      feedback =
          'Bản nhận diện “$recognized” khớp $percent% với câu mẫu “$targetText”.$mismatchText Đây là đối chiếu transcript, không chẩn đoán âm thanh hay âm vị.';
    }
    return PronunciationResult(
      recognizedTranscript: recognized,
      targetText: targetText,
      accuracyScore: accuracy,
      isPassed: passed,
      feedbackVi: feedback,
      mismatchedSegments: mismatches,
    );
  }

  static String _normalize(String text) => text.toLowerCase().replaceAll(
    RegExp(
      r'''[\s\u2000-\u206F\u3000-\u303F\uFF01-\uFF0F\uFF1A-\uFF20\uFF3B-\uFF40\uFF5B-\uFF65!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~]''',
    ),
    '',
  );

  static double _similarity(String first, String second) {
    final a = first.runes.toList();
    final b = second.runes.toList();
    var previous = List<int>.generate(b.length + 1, (index) => index);
    for (var i = 0; i < a.length; i++) {
      final current = <int>[i + 1];
      for (var j = 0; j < b.length; j++) {
        current.add(
          math.min(
            math.min(current[j] + 1, previous[j + 1] + 1),
            previous[j] + (a[i] == b[j] ? 0 : 1),
          ),
        );
      }
      previous = current;
    }
    return 1 - previous.last / math.max(a.length, b.length);
  }

  static List<String> _transcriptMismatches(
    String transcript,
    String target, {
    required bool japanese,
  }) {
    final cleanTarget = _normalize(target);
    final cleanTranscript = _normalize(transcript);
    if (cleanTarget.isEmpty || cleanTranscript.isEmpty) return const [];
    final expected = japanese
        ? cleanTarget.runes.map(String.fromCharCode).toList()
        : target
              .split(RegExp(r'\s+'))
              .map(_normalize)
              .where((part) => part.isNotEmpty)
              .toList();
    final actual = japanese
        ? cleanTranscript.runes.map(String.fromCharCode).toList()
        : transcript
              .split(RegExp(r'\s+'))
              .map(_normalize)
              .where((part) => part.isNotEmpty)
              .toList();
    final rows = expected.length + 1;
    final columns = actual.length + 1;
    final distance = List.generate(rows, (_) => List<int>.filled(columns, 0));
    for (var i = 0; i < rows; i++) {
      distance[i][0] = i;
    }
    for (var j = 0; j < columns; j++) {
      distance[0][j] = j;
    }
    for (var i = 1; i < rows; i++) {
      for (var j = 1; j < columns; j++) {
        distance[i][j] = math.min(
          math.min(distance[i - 1][j] + 1, distance[i][j - 1] + 1),
          distance[i - 1][j - 1] + (expected[i - 1] == actual[j - 1] ? 0 : 1),
        );
      }
    }
    final mismatches = <String>[];
    var i = expected.length;
    var j = actual.length;
    while (i > 0 || j > 0) {
      if (i > 0 && j > 0 && expected[i - 1] == actual[j - 1]) {
        i--;
        j--;
      } else if (i > 0 && j > 0 &&
          distance[i][j] == distance[i - 1][j - 1] + 1) {
        mismatches.add(expected[i - 1]);
        i--;
        j--;
      } else if (i > 0 && distance[i][j] == distance[i - 1][j] + 1) {
        mismatches.add(expected[i - 1]);
        i--;
      } else {
        j--;
      }
    }
    return mismatches.reversed.toSet().toList();
  }
}

/// Explicit injection for tests; unsupported devices never select this engine.
class MockSpeechPracticeEngine implements SpeechPracticeEngine {
  final String transcript;
  final bool available;

  MockSpeechPracticeEngine({this.transcript = '', this.available = true});

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<String> listen({required String language}) async {
    if (!available) {
      throw const SpeechPracticeException(
        'unavailable',
        'Nhận dạng giọng nói không khả dụng.',
      );
    }
    return transcript;
  }

  @override
  Future<void> stop() async {}
}
