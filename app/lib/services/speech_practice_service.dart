import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class SpeechPracticeEngine {
  Future<bool> isAvailable();
  Future<String> listen({required String language});
  Future<void> stop();
}

class SpeechPracticeException implements Exception {
  final String code;
  final String message;

  const SpeechPracticeException(this.code, this.message);

  @override
  String toString() => message;
}

class PronunciationResult {
  final String recognizedTranscript;
  final String targetText;
  final double accuracyScore;
  final bool isPassed;
  final String feedbackVi;

  const PronunciationResult({
    required this.recognizedTranscript,
    required this.targetText,
    required this.accuracyScore,
    required this.isPassed,
    required this.feedbackVi,
  });
}

class SpeechPracticeService {
  // IndexedStack keeps multiple practice screens alive. They must share one
  // channel handler and recording lifecycle rather than replace one another.
  static final SpeechPracticeEngine _platformEngine =
      PlatformSpeechPracticeEngine();
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

class PlatformSpeechPracticeEngine implements SpeechPracticeEngine {
  final MethodChannel _channel;
  final TargetPlatform? _platform;
  final Duration _timeout;
  static int _nextSessionId = 0;
  int? _sessionId;
  Completer<String>? _pending;
  Timer? _timer;

  PlatformSpeechPracticeEngine({
    MethodChannel? channel,
    TargetPlatform? platform,
    Duration timeout = const Duration(seconds: 30),
  }) : _channel =
           channel ?? const MethodChannel('com.linguacanvas.app/stt_native'),
       _platform = platform,
       _timeout = timeout {
    _channel.setMethodCallHandler(_onSpeechEvent);
  }

  bool get _supported =>
      !kIsWeb && (_platform ?? defaultTargetPlatform) == TargetPlatform.android;

  @override
  Future<bool> isAvailable() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String> listen({required String language}) {
    if (!_supported) {
      return Future.error(
        const SpeechPracticeException(
          'unavailable',
          'Thiết bị này chưa hỗ trợ nhận dạng giọng nói. Hãy nhập nội dung đã đọc.',
        ),
      );
    }
    final previousId = _sessionId;
    _fail(
      const SpeechPracticeException('cancelled', 'Đã hủy lượt thu âm trước.'),
    );
    final id = ++_nextSessionId;
    final pending = Completer<String>();
    _sessionId = id;
    _pending = pending;
    _timer = Timer(_timeout, () {
      if (_sessionId != id) return;
      _fail(
        const SpeechPracticeException(
          'timeout',
          'Hết thời gian thu âm. Hãy thử lại.',
        ),
      );
      unawaited(_stopSession(id));
    });
    final locale = language.toLowerCase().startsWith('ja') ? 'ja-JP' : 'en-US';
    unawaited(_start(id, previousId, locale));
    return pending.future;
  }

  Future<void> _start(int id, int? previousId, String locale) async {
    if (previousId != null) await _stopSession(previousId);
    if (_sessionId != id) return;
    try {
      final started = await _channel.invokeMethod<bool>('startListening', {
        'language': locale,
        'sessionId': id,
      });
      if (_sessionId == id && started != true) {
        _fail(
          const SpeechPracticeException(
            'recognition_failed',
            'Không thể bắt đầu thu âm.',
          ),
        );
        unawaited(_stopSession(id));
      }
    } on MissingPluginException {
      if (_sessionId == id) {
        _fail(
          const SpeechPracticeException(
            'unavailable',
            'Nhận dạng giọng nói không khả dụng.',
          ),
        );
      }
    } on PlatformException catch (error) {
      if (_sessionId == id) _fail(_exception(error.code, error.message));
    } catch (_) {
      if (_sessionId == id) {
        _fail(
          const SpeechPracticeException(
            'recognition_failed',
            'Không thể bắt đầu thu âm.',
          ),
        );
      }
    }
  }

  Future<void> _onSpeechEvent(MethodCall call) async {
    final event = call.arguments;
    if (event is! Map || _pending == null || event['sessionId'] != _sessionId) {
      return;
    }
    if (call.method == 'onSpeechResult') {
      final transcript = event['transcript'];
      if (transcript is! String || transcript.trim().isEmpty) {
        _fail(
          const SpeechPracticeException(
            'recognition_failed',
            'Chưa nghe được lời đọc. Hãy thử lại.',
          ),
        );
        return;
      }
      final pending = _pending!;
      _clear();
      pending.complete(transcript);
    } else if (call.method == 'onSpeechError') {
      _fail(
        _exception(
          event['code'] as String? ?? 'recognition_failed',
          event['message'] as String?,
        ),
      );
    }
  }

  static SpeechPracticeException _exception(String code, String? message) {
    const messages = {
      'unavailable': 'Nhận dạng giọng nói không khả dụng.',
      'permission_denied':
          'Hãy cho phép sử dụng microphone trong cài đặt ứng dụng rồi thử lại.',
      'cancelled': 'Đã hủy thu âm.',
      'timeout': 'Hết thời gian thu âm. Hãy thử lại.',
      'recognition_failed': 'Không nhận dạng được lời đọc. Hãy thử lại.',
    };
    final knownCode = messages.containsKey(code) ? code : 'recognition_failed';
    return SpeechPracticeException(knownCode, messages[knownCode]!);
  }

  void _clear() {
    _timer?.cancel();
    _timer = null;
    _sessionId = null;
    _pending = null;
  }

  void _fail(SpeechPracticeException error) {
    final pending = _pending;
    _clear();
    pending?.completeError(error);
  }

  Future<void> _stopSession(int id) async {
    try {
      await _channel.invokeMethod<void>('stopListening', {'sessionId': id});
    } on MissingPluginException {
      // An unavailable platform has no recorder to clean up.
    } on PlatformException {
      // Cancellation must still release the Dart session if native is closing.
    }
  }

  @override
  Future<void> stop() async {
    final id = _sessionId;
    _fail(const SpeechPracticeException('cancelled', 'Đã hủy thu âm.'));
    if (id != null) await _stopSession(id);
  }
}
