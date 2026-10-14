import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_tts/flutter_tts.dart';

/// Playback and readiness states for the TTS engine.
enum TTSState { stopped, speaking, error }

/// Normalizes language tags to BCP-47 identifiers recognized by TTS engines.
///
/// 'ja', 'ja-JP', 'ja_JP' -> 'ja-JP'
/// 'en', 'en-US', 'en_US' -> 'en-US'
String normalizeTtsLanguage(String tag) {
  final lower = tag.trim().toLowerCase().replaceAll('_', '-');
  if (lower.startsWith('ja')) return 'ja-JP';
  if (lower.startsWith('en')) return 'en-US';
  return tag.trim();
}

/// Abstract contract for Text-To-Speech engine.
abstract class TTSEngine {
  /// Checks whether TTS voice data for [languageTag] is installed/available.
  Future<bool> isLanguageAvailable(String languageTag);

  /// Speaks the provided [text] in [languageTag]. Returns true on success.
  Future<bool> speak(String text, {required String languageTag});

  /// Stops current speech output.
  Future<void> stop();

  /// Sets playback speech rate (default 1.0; 0.5 is slower, 2.0 is faster).
  Future<void> setSpeechRate(double rate);

  /// Sets audio volume between 0.0 and 1.0.
  Future<void> setVolume(double volume);

  /// Sets audio pitch (1.0 is default).
  Future<void> setPitch(double pitch);

  /// Current state of the engine.
  TTSState get state;

  /// Stream of state changes.
  Stream<TTSState> get stateStream;

  /// Disposes resources held by the engine.
  void dispose();
}

/// Production implementation using native Android TextToSpeech with FlutterTts fallback.
class PlatformTTSEngine implements TTSEngine {
  final FlutterTts _flutterTts;
  final MethodChannel _nativeChannel;
  TTSState _state = TTSState.stopped;
  double _speechRate = 0.9;
  double _volume = 1.0;
  double _pitch = 1.0;
  final StreamController<TTSState> _stateController =
      StreamController<TTSState>.broadcast();

  PlatformTTSEngine({
    FlutterTts? ttsOverride,
    MethodChannel? nativeChannelOverride,
  }) : _flutterTts = ttsOverride ?? FlutterTts(),
       _nativeChannel =
           nativeChannelOverride ??
           const MethodChannel('com.linguacanvas.app/tts_native') {
    _initHandlers();
  }

  void _initHandlers() {
    try {
      _nativeChannel.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'onSpeakStart':
            _updateState(TTSState.speaking);
            break;
          case 'onSpeakDone':
            _updateState(TTSState.stopped);
            break;
          case 'onSpeakError':
            _updateState(TTSState.error);
            break;
        }
      });
    } catch (_) {}

    try {
      _flutterTts.setStartHandler(() {
        _updateState(TTSState.speaking);
      });
      _flutterTts.setCompletionHandler(() {
        _updateState(TTSState.stopped);
      });
      _flutterTts.setCancelHandler(() {
        _updateState(TTSState.stopped);
      });
      _flutterTts.setErrorHandler((msg) {
        debugPrint('FlutterTTS error: $msg');
        _updateState(TTSState.error);
      });
    } catch (e) {
      debugPrint('Error setting FlutterTTS handlers: $e');
    }
  }

  void _updateState(TTSState newState) {
    if (_state != newState) {
      _state = newState;
      if (!_stateController.isClosed) {
        _stateController.add(_state);
      }
    }
  }

  @override
  TTSState get state => _state;

  @override
  Stream<TTSState> get stateStream => _stateController.stream;

  @override
  Future<bool> isLanguageAvailable(String languageTag) async {
    final lang = normalizeTtsLanguage(languageTag);
    try {
      final bool? res = await _nativeChannel.invokeMethod<bool>(
        'isLanguageAvailable',
        {'language': lang},
      );
      if (res != null) return res;
    } catch (e) {
      debugPrint(
        'Native TTS isLanguageAvailable check failed: $e, trying flutter_tts',
      );
    }

    try {
      final dynamic res = await _flutterTts.isLanguageAvailable(lang);
      if (res is bool) return res;
      if (res is num) return res == 1;
      return false;
    } catch (e) {
      debugPrint('TTS isLanguageAvailable error: $e');
      return false;
    }
  }

  @override
  Future<bool> speak(String text, {required String languageTag}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    final lang = normalizeTtsLanguage(languageTag);

    // 1. Try Direct Android OS Native TextToSpeech
    try {
      final bool? nativeRes = await _nativeChannel.invokeMethod<bool>('speak', {
        'text': trimmed,
        'language': lang,
        'rate': _speechRate,
        'pitch': _pitch,
        'volume': _volume,
      });
      if (nativeRes == true) {
        _updateState(TTSState.speaking);
        return true;
      }
    } catch (e) {
      debugPrint('Native TTS speak error: $e, falling back to flutter_tts');
    }

    // 2. Fallback to FlutterTts plugin
    try {
      final dynamic languageResult = await _flutterTts.setLanguage(lang);
      if (languageResult != 1 && languageResult != true) {
        _updateState(TTSState.error);
        return false;
      }
      await _flutterTts.setSpeechRate((_speechRate / 2).clamp(0.0, 1.0));
      await _flutterTts.setVolume(_volume);
      await _flutterTts.setPitch(_pitch);
      _updateState(TTSState.speaking);
      final dynamic res = await _flutterTts.speak(trimmed);
      final success = res == 1 || res == true;
      if (!success) {
        _updateState(TTSState.error);
      }
      return success;
    } catch (e) {
      debugPrint('TTS speak error: $e');
      _updateState(TTSState.error);
      return false;
    }
  }

  Future<bool> openSettings() async {
    try {
      return await _nativeChannel.invokeMethod<bool>('openSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _nativeChannel.invokeMethod('stop');
    } catch (_) {}
    try {
      await _flutterTts.stop();
    } catch (e) {
      debugPrint('TTS stop error: $e');
    }
    _updateState(TTSState.stopped);
  }

  @override
  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate;
    try {
      await _flutterTts.setSpeechRate(rate);
    } catch (e) {
      debugPrint('TTS setSpeechRate error: $e');
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    try {
      await _flutterTts.setVolume(volume);
    } catch (e) {
      debugPrint('TTS setVolume error: $e');
    }
  }

  @override
  Future<void> setPitch(double pitch) async {
    _pitch = pitch;
    try {
      await _flutterTts.setPitch(pitch);
    } catch (e) {
      debugPrint('TTS setPitch error: $e');
    }
  }

  @override
  void dispose() {
    _nativeChannel.setMethodCallHandler(null);
    unawaited(stop());
    _stateController.close();
  }
}

/// Deterministic mock TTS engine for unit and widget testing in Linux CI.
///
/// Records spoken texts and languages, allows injecting failures, and
/// updates state deterministically.
class MockTTSEngine implements TTSEngine {
  final List<String> spokenTexts = [];
  final List<String> spokenLanguages = [];
  final Set<String> availableLanguages;
  bool isAvailable;
  bool shouldFail;
  bool wasStopped = false;
  double speechRate = 1.0;
  double volume = 1.0;
  double pitch = 1.0;

  TTSState _state = TTSState.stopped;
  final StreamController<TTSState> _stateController =
      StreamController<TTSState>.broadcast();

  MockTTSEngine({
    Set<String>? availableLanguages,
    this.isAvailable = true,
    this.shouldFail = false,
  }) : availableLanguages = availableLanguages ?? {'ja-JP', 'en-US'};

  @override
  TTSState get state => _state;

  @override
  Stream<TTSState> get stateStream => _stateController.stream;

  void _updateState(TTSState newState) {
    if (_state != newState) {
      _state = newState;
      if (!_stateController.isClosed) {
        _stateController.add(_state);
      }
    }
  }

  @override
  Future<bool> isLanguageAvailable(String languageTag) async {
    if (!isAvailable) return false;
    final lang = normalizeTtsLanguage(languageTag);
    return availableLanguages.contains(lang);
  }

  @override
  Future<bool> speak(String text, {required String languageTag}) async {
    if (!isAvailable || shouldFail) {
      _updateState(TTSState.error);
      return false;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final lang = normalizeTtsLanguage(languageTag);
    spokenTexts.add(trimmed);
    spokenLanguages.add(lang);
    wasStopped = false;
    _updateState(TTSState.speaking);
    return true;
  }

  @override
  Future<void> stop() async {
    wasStopped = true;
    _updateState(TTSState.stopped);
  }

  @override
  Future<void> setSpeechRate(double rate) async {
    speechRate = rate;
  }

  @override
  Future<void> setVolume(double vol) async {
    volume = vol;
  }

  @override
  Future<void> setPitch(double p) async {
    pitch = p;
  }

  @override
  void dispose() {
    _stateController.close();
  }
}

/// Lightweight pronunciation audio service for Lingua Canvas.
///
/// Supports Japanese (`ja-JP`) and English (`en-US`) text with graceful
/// handling if TTS is unavailable on the device.
class TtsService {
  final TTSEngine engine;
  static TtsService? _defaultInstance;

  /// Global default instance of [TtsService].
  static TtsService get defaultInstance => _defaultInstance ??= TtsService();

  /// Setter for injecting mock instance during tests.
  static set defaultInstance(TtsService instance) {
    _defaultInstance = instance;
  }

  TtsService({TTSEngine? engine}) : engine = engine ?? PlatformTTSEngine();

  /// Speaks [text] in [language] (defaults to 'ja-JP').
  ///
  /// Automatically normalizes language tags like 'ja' -> 'ja-JP' and 'en' -> 'en-US'.
  /// Returns true if speech was successfully started, false otherwise.
  Future<bool> speak(String text, {String? language}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final lang = normalizeTtsLanguage(language ?? 'ja-JP');
    return engine.speak(trimmed, languageTag: lang);
  }

  /// Helper to speak Japanese workplace words or character readings.
  Future<bool> speakJapanese(String text) => speak(text, language: 'ja-JP');

  /// Helper to speak English workplace phrases or vocabulary.
  Future<bool> speakEnglish(String text) => speak(text, language: 'en-US');

  /// Stops current speech playback.
  Future<void> stop() => engine.stop();

  /// Checks if TTS language voice is supported and installed.
  Future<bool> isLanguageAvailable(String language) =>
      engine.isLanguageAvailable(language);

  /// Opens Android's voice engine and voice data settings.
  Future<bool> openSettings() async {
    final platformEngine = engine;
    return platformEngine is PlatformTTSEngine
        ? platformEngine.openSettings()
        : false;
  }

  /// Current state of the underlying TTS engine.
  TTSState get state => engine.state;

  /// Whether audio is currently being spoken.
  bool get isSpeaking => engine.state == TTSState.speaking;

  /// Stream of state changes.
  Stream<TTSState> get stateStream => engine.stateStream;

  /// Disposes resources.
  void dispose() {
    engine.dispose();
  }
}
