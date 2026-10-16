import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'speech_types.dart';

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
