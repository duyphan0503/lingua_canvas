import 'speech_types.dart';
import 'browser_speech_bridge.dart';
import 'browser_speech_engine.dart';

SpeechPracticeEngine createSpeechPracticeEngine() =>
    BrowserSpeechPracticeEngine(bridge: WebSpeechBridge());
