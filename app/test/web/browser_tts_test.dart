@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:app/services/tts_service.dart';

class BrowserTestTts extends FlutterTts {
  @override
  Future<dynamic> isLanguageAvailable(String language) async => true;
  @override
  Future<dynamic> stop() async => 1;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'web audio uses the browser plugin and never an Android channel',
    () async {
      var nativeCalls = 0;
      const native = MethodChannel('lingua_test_native_tts');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, (call) async {
            nativeCalls++;
            return false;
          });
      final engine = PlatformTTSEngine(
        ttsOverride: BrowserTestTts(),
        nativeChannelOverride: native,
      );
      expect(await engine.isLanguageAvailable('ja'), isTrue);
      expect(await engine.openSettings(), isFalse);
      await engine.stop();
      expect(nativeCalls, 0);
      engine.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, null);
    },
  );
}
