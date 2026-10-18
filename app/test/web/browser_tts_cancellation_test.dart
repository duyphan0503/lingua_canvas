@TestOn('browser')
library;

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:app/services/tts_service.dart';

class DelayedVoiceTts extends FlutterTts {
  final settingLanguage = Completer<void>();
  final ready = Completer<int>();
  int utterances = 0;
  @override
  Future<dynamic> setLanguage(String language) {
    settingLanguage.complete();
    return ready.future;
  }

  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;
  @override
  Future<dynamic> setVolume(double volume) async => 1;
  @override
  Future<dynamic> setPitch(double pitch) async => 1;
  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    utterances++;
    return 1;
  }

  @override
  Future<dynamic> stop() async => 1;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('stop rejects playback awaiting browser voice configuration', () async {
    final plugin = DelayedVoiceTts();
    final engine = PlatformTTSEngine(ttsOverride: plugin);
    final speaking = engine.speak('Old profile text', languageTag: 'en-US');
    await plugin.settingLanguage.future;
    await engine.stop();
    plugin.ready.complete(1);
    expect(await speaking, isFalse);
    expect(plugin.utterances, 0);
    expect(engine.state, TTSState.stopped);
    engine.dispose();
  });
}
