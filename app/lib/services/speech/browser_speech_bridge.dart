import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'speech_types.dart';
import 'browser_speech_bridge_contract.dart';

@JS('globalThis')
external JSObject get _global;

class WebSpeechBridge implements BrowserSpeechBridge {
  final JSFunction? constructorForTesting;
  JSObject? _recognizer;
  WebSpeechBridge({this.constructorForTesting});
  JSFunction? get _constructor {
    if (constructorForTesting != null) {
      return constructorForTesting;
    }
    final value =
        _global.getProperty<JSAny?>('SpeechRecognition'.toJS) ??
        _global.getProperty<JSAny?>('webkitSpeechRecognition'.toJS);
    return value as JSFunction?;
  }

  @override
  bool get available => _constructor != null;
  @override
  Future<void> start(
    String language, {
    required void Function(String) onFinal,
    required void Function(String, String) onError,
  }) async {
    await abort();
    final constructor = _constructor;
    if (constructor == null) {
      throw const SpeechPracticeException(
        'unavailable',
        'Trình duyệt chưa hỗ trợ nhận diện giọng nói.',
      );
    }
    final recognizer = constructor.callAsConstructor<JSObject>();
    _recognizer = recognizer;
    var settled = false;
    bool current() => identical(_recognizer, recognizer) && !settled;
    recognizer.setProperty('lang'.toJS, language.toJS);
    recognizer.setProperty('interimResults'.toJS, true.toJS);
    recognizer.setProperty('maxAlternatives'.toJS, 5.toJS);
    recognizer.setProperty('continuous'.toJS, false.toJS);
    recognizer.setProperty(
      'onresult'.toJS,
      ((JSObject event) {
        if (!current()) {
          return;
        }
        final results = event.getProperty<JSObject>('results'.toJS);
        final count = results.getProperty<JSNumber>('length'.toJS).toDartInt;
        final start = event.getProperty<JSNumber>('resultIndex'.toJS).toDartInt;
        final parts = <String>[];
        for (var i = start; i < count; i++) {
          final result = results.getProperty<JSObject>(i.toJS);
          if (result.getProperty<JSBoolean>('isFinal'.toJS).toDart) {
            parts.add(
              result
                  .getProperty<JSObject>(0.toJS)
                  .getProperty<JSString>('transcript'.toJS)
                  .toDart,
            );
          }
        }
        if (parts.isNotEmpty) {
          settled = true;
          onFinal(parts.join(' '));
        }
      }).toJS,
    );
    recognizer.setProperty(
      'onerror'.toJS,
      ((JSObject event) {
        if (!current()) {
          return;
        }
        settled = true;
        final value = event.getProperty<JSString>('error'.toJS).toDart;
        final code = ['not-allowed', 'service-not-allowed'].contains(value)
            ? 'permission_denied'
            : value == 'aborted'
            ? 'cancelled'
            : 'recognition_failed';
        onError(
          code,
          code == 'permission_denied'
              ? 'Không có quyền microphone. Bạn có thể nhập bản phiên âm.'
              : 'Không nhận được giọng nói. Hãy thử lại.',
        );
      }).toJS,
    );
    recognizer.setProperty(
      'onend'.toJS,
      ((JSAny? event) {
        if (current()) {
          settled = true;
          onError(
            'recognition_failed',
            'Không nhận được lời đọc. Hãy thử lại.',
          );
        }
      }).toJS,
    );
    try {
      recognizer.callMethod<JSAny?>('start'.toJS);
    } catch (_) {
      await abort();
      throw const SpeechPracticeException(
        'recognition_failed',
        'Không thể bắt đầu microphone.',
      );
    }
  }

  @override
  Future<void> abort() async {
    final previous = _recognizer;
    _recognizer = null;
    if (previous == null) {
      return;
    }
    for (final name in ['onresult', 'onerror', 'onend']) {
      previous.setProperty(name.toJS, null);
    }
    try {
      previous.callMethod<JSAny?>('abort'.toJS);
    } catch (_) {}
  }
}
