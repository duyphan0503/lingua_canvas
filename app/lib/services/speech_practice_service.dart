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
    final String feedback;
    if (heard.isEmpty) {
      feedback = 'Chưa nghe được lời đọc (0%). Hãy đọc lại “$targetText”.';
    } else if (passed) {
      feedback = 'Phát âm chuẩn xác ($percent%)! Bạn đã đọc “$recognized”.';
    } else {
      final hint = language.toLowerCase().startsWith('ja')
          ? 'Chú ý trường âm, âm ngắt và từng âm tiết'
          : 'Chú ý âm cuối và trọng âm';
      feedback =
          'Bạn đọc “$recognized” ($percent%). $hint của “$targetText” rồi thử lại.';
    }
    return PronunciationResult(
      recognizedTranscript: recognized,
      targetText: targetText,
      accuracyScore: accuracy,
      isPassed: passed,
      feedbackVi: feedback,
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
