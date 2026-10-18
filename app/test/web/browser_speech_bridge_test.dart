@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/speech/browser_speech_bridge.dart';

@JS('Function')
external JSFunction get _function;
JSFunction constructorFor(JSObject fake) =>
    _function
            .callAsConstructor<JSFunction>(
              'speech'.toJS,
              'return function SpeechRecognition(){ return speech; };'.toJS,
            )
            .callAsFunction(null, fake)
        as JSFunction;
void main() {
  late JSObject fake;
  late WebSpeechBridge bridge;
  setUp(() {
    fake = JSObject();
    fake.setProperty('start'.toJS, (() {}).toJS);
    fake.setProperty('abort'.toJS, (() {}).toJS);
    bridge = WebSpeechBridge(constructorForTesting: constructorFor(fake));
  });
  void emit(String event, Map<String, dynamic> value) {
    fake
        .getProperty<JSFunction>(event.toJS)
        .callAsFunction(null, value.jsify());
  }

  test(
    'actual JS events ignore partial text and deliver a final transcript',
    () async {
      String? result;
      await bridge.start(
        'ja-JP',
        onFinal: (value) => result = value,
        onError: (code, message) => fail('$code $message'),
      );
      expect(fake.getProperty<JSString>('lang'.toJS).toDart, 'ja-JP');
      emit('onresult', {
        'resultIndex': 0,
        'results': [
          {
            'isFinal': false,
            '0': {'transcript': 'partial'},
          },
        ],
      });
      expect(result, isNull);
      emit('onresult', {
        'resultIndex': 0,
        'results': [
          {
            'isFinal': true,
            '0': {'transcript': '会議'},
          },
        ],
      });
      expect(result, '会議');
      await bridge.abort();
    },
  );
  test(
    'permission errors map correctly and detached late events are rejected',
    () async {
      String? code;
      var results = 0;
      await bridge.start(
        'en-US',
        onFinal: (_) => results++,
        onError: (value, _) => code = value,
      );
      final oldResult = fake.getProperty<JSFunction>('onresult'.toJS);
      emit('onerror', {'error': 'not-allowed'});
      expect(code, 'permission_denied');
      await bridge.abort();
      oldResult.callAsFunction(
        null,
        {
          'resultIndex': 0,
          'results': [
            {
              'isFinal': true,
              '0': {'transcript': 'stale'},
            },
          ],
        }.jsify(),
      );
      expect(results, 0);
    },
  );
  test('end without a final transcript reports no speech', () async {
    String? code;
    await bridge.start(
      'en-US',
      onFinal: (_) => fail('unexpected result'),
      onError: (value, _) => code = value,
    );
    emit('onend', {});
    expect(code, 'recognition_failed');
    await bridge.abort();
  });
}
