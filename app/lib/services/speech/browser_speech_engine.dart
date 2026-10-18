import 'dart:async';
import 'speech_types.dart';
import 'browser_speech_bridge_contract.dart';

/// Serializes start/abort; session epochs reject events from cancelled recorders.
class BrowserSpeechPracticeEngine implements SpeechPracticeEngine {
  final BrowserSpeechBridge bridge;
  final Duration timeout;
  Future<void>? _starting;
  Completer<String>? _pending;
  Timer? _timer;
  int _epoch = 0;
  BrowserSpeechPracticeEngine({
    required this.bridge,
    this.timeout = const Duration(seconds: 30),
  });
  @override
  Future<bool> isAvailable() async => bridge.available;
  static SpeechPracticeException _error(
    String code, [
    String? message,
  ]) => SpeechPracticeException(
    code,
    message ??
        switch (code) {
          'permission_denied' =>
            'Không có quyền microphone. Có thể nhập bản phiên âm để đối chiếu.',
          'cancelled' => 'Đã hủy thu âm.',
          'timeout' => 'Hết thời gian thu âm. Hãy thử lại.',
          'unavailable' => 'Trình duyệt chưa hỗ trợ nhận diện giọng nói.',
          _ => 'Không nhận được lời đọc. Hãy thử lại.',
        },
  );
  void _finish(
    int epoch, {
    String? transcript,
    SpeechPracticeException? error,
  }) {
    if (epoch != _epoch || _pending == null) {
      return;
    }
    final pending = _pending!;
    _pending = null;
    _timer?.cancel();
    _timer = null;
    final cleanup = ++_epoch;
    if (error != null) {
      pending.completeError(error);
    } else {
      pending.complete(transcript!);
    }
    unawaited(_abortWhenReady(cleanup));
  }

  Future<void> _abortWhenReady(int epoch) async {
    await _starting;
    if (epoch == _epoch) {
      try {
        await bridge.abort();
      } catch (_) {}
    }
  }

  @override
  Future<String> listen({required String language}) {
    if (!bridge.available) {
      return Future.error(_error('unavailable'));
    }
    final previous = _pending;
    _pending = null;
    previous?.completeError(_error('cancelled'));
    _timer?.cancel();
    final epoch = ++_epoch;
    final pending = Completer<String>();
    _pending = pending;
    _timer = Timer(timeout, () => _finish(epoch, error: _error('timeout')));
    final normalized = language.toLowerCase().startsWith('ja')
        ? 'ja-JP'
        : 'en-US';
    final start = (_starting ?? Future<void>.value()).then((_) async {
      if (epoch != _epoch) {
        return;
      }
      await bridge.abort();
      if (epoch != _epoch) {
        return;
      }
      await bridge.start(
        normalized,
        onFinal: (text) {
          if (text.trim().isEmpty) {
            _finish(epoch, error: _error('recognition_failed'));
          } else {
            _finish(epoch, transcript: text.trim());
          }
        },
        onError: (code, message) =>
            _finish(epoch, error: _error(code, message)),
      );
    });
    _starting = start.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) => _finish(
        epoch,
        error: error is SpeechPracticeException
            ? error
            : _error('recognition_failed'),
      ),
    );
    return pending.future;
  }

  @override
  Future<void> stop() async {
    final epoch = ++_epoch;
    _timer?.cancel();
    _timer = null;
    final pending = _pending;
    _pending = null;
    pending?.completeError(_error('cancelled'));
    await _abortWhenReady(epoch);
  }
}
