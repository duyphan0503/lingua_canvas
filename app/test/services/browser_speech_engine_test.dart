import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/speech_practice_service.dart';
import 'package:app/services/speech/browser_speech_engine.dart';
import 'package:app/services/speech/browser_speech_bridge_contract.dart';

class FakeBrowserSpeechBridge implements BrowserSpeechBridge {
  @override
  bool available = true;
  String? language;
  int aborts = 0;
  void Function(String)? onFinal;
  void Function(String, String)? onError;
  @override
  Future<void> start(
    String language, {
    required void Function(String) onFinal,
    required void Function(String, String) onError,
  }) async {
    this.language = language;
    this.onFinal = onFinal;
    this.onError = onError;
  }

  @override
  Future<void> abort() async {
    aborts++;
  }
}

void main() {
  late FakeBrowserSpeechBridge bridge;
  late BrowserSpeechPracticeEngine engine;
  setUp(() {
    bridge = FakeBrowserSpeechBridge();
    engine = BrowserSpeechPracticeEngine(
      bridge: bridge,
      timeout: const Duration(milliseconds: 50),
    );
  });
  test('normalizes language and resolves final transcript once', () async {
    final pending = engine.listen(language: 'ja');
    await Future<void>.delayed(Duration.zero);
    expect(bridge.language, 'ja-JP');
    bridge.onFinal!('会議');
    expect(await pending, '会議');
  });
  test('cancelled result cannot overwrite a newer session', () async {
    final pending = engine.listen(language: 'ja');
    final cancelled = expectLater(
      pending,
      throwsA(
        isA<SpeechPracticeException>().having(
          (e) => e.code,
          'code',
          'cancelled',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final old = bridge.onFinal!;
    await engine.stop();
    await cancelled;
    final next = engine.listen(language: 'en');
    await Future<void>.delayed(Duration.zero);
    old('stale');
    bridge.onFinal!('meeting');
    expect(await next, 'meeting');
    expect(bridge.language, 'en-US');
  });
  test('denied permission settles and stops recognition', () async {
    final pending = engine.listen(language: 'en');
    final denied = expectLater(
      pending,
      throwsA(
        isA<SpeechPracticeException>().having(
          (e) => e.code,
          'code',
          'permission_denied',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    bridge.onError!('permission_denied', 'denied');
    await denied;
    expect(bridge.aborts, greaterThan(0));
  });
  test('missing API and timeout fail explicitly', () async {
    bridge.available = false;
    expect(await engine.isAvailable(), isFalse);
    await expectLater(
      engine.listen(language: 'ja'),
      throwsA(
        isA<SpeechPracticeException>().having(
          (e) => e.code,
          'code',
          'unavailable',
        ),
      ),
    );
    bridge.available = true;
    await expectLater(
      engine.listen(language: 'ja'),
      throwsA(
        isA<SpeechPracticeException>().having((e) => e.code, 'code', 'timeout'),
      ),
    );
  });
  test('starting another session cancels the previous recorder', () async {
    final first = engine.listen(language: 'ja');
    final cancelled = expectLater(
      first,
      throwsA(isA<SpeechPracticeException>()),
    );
    await Future<void>.delayed(Duration.zero);
    final second = engine.listen(language: 'en');
    await Future<void>.delayed(Duration.zero);
    await cancelled;
    bridge.onFinal!('hello');
    expect(await second, 'hello');
  });
}
