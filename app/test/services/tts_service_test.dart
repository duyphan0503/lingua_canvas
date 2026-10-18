import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/lesson_item.dart';
import 'package:app/screens/canvas_practice_screen.dart';
import 'package:app/screens/ai_roleplay_screen.dart';
import 'package:app/screens/curriculum_screen.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/digital_ink_engine.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/local_database.dart';
import 'package:app/services/tts_service.dart';
import 'package:app/widgets/tts_speaker_button.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockTestApiService extends ApiService {
  @override
  Future<List<LessonItem>> getLessons({String? language}) async => [
    LessonItem(
      id: 'ja_test_a',
      language: 'ja',
      category: 'alphabet',
      targetText: 'あ',
      phoneticOrKana: 'a',
      meaningVi: 'Chữ cái A',
      workplaceContext: '',
      workplaceContextVi: '',
      strokeOrderHints: ['Nét 1'],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: 'en_test_deploy',
      language: 'en',
      category: 'it_workplace',
      targetText: 'deploy',
      phoneticOrKana: '/dɪˈplɔɪ/',
      meaningVi: 'Triển khai phần mềm',
      workplaceContext: 'Deploy to production',
      workplaceContextVi: 'Triển khai',
      strokeOrderHints: [],
      difficultyLevel: 1,
    ),
  ];

  @override
  Future<List<FSRSCard>> getAllCards() async => [];

  @override
  Future<int> getCompletedCount() async => 1;

  @override
  Future<Map<String, dynamic>> sendRoleplayMessage({
    required String targetLanguage,
    required String topic,
    required String message,
    String profession = 'it',
    String userLevel = 'beginner',
  }) async => {
    'reply': '了解しました。',
    'romaji': 'Ryoukai shimashita.',
    'reply_translation_vi': 'Tôi đã hiểu.',
    'breakdown': [
      {'word': '了解', 'meaning_vi': 'Hiểu / Đồng ý', 'phonetic': 'りょうかい'},
    ],
    'writing_challenge': '了解',
  };

  @override
  Future<Map<String, dynamic>> generateDialogue({
    required String targetLanguage,
    required String topic,
    String profession = 'IT',
    String level = 'beginner',
    int turnCount = 4,
  }) async => {
    'topic': topic,
    'turns': [
      {
        'speaker': 'Leader',
        'text': '進捗はどうですか？',
        'romaji_or_phonetic': 'Shinchoku wa dou desu ka?',
        'translation_vi': 'Tiến độ thế nào?',
      },
    ],
    'key_vocabulary': [
      {'word': '進捗', 'meaning_vi': 'Tiến độ', 'phonetic': 'しんちょく'},
    ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('TTS Language Tag Normalization', () {
    test('normalizes Japanese language tags to ja-JP', () {
      expect(normalizeTtsLanguage('ja'), equals('ja-JP'));
      expect(normalizeTtsLanguage('ja-JP'), equals('ja-JP'));
      expect(normalizeTtsLanguage('ja_JP'), equals('ja-JP'));
      expect(normalizeTtsLanguage('JA'), equals('ja-JP'));
    });

    test('normalizes English language tags to en-US', () {
      expect(normalizeTtsLanguage('en'), equals('en-US'));
      expect(normalizeTtsLanguage('en-US'), equals('en-US'));
      expect(normalizeTtsLanguage('en_US'), equals('en-US'));
      expect(normalizeTtsLanguage('EN'), equals('en-US'));
    });

    test('preserves unknown language tags with trimmed whitespace', () {
      expect(normalizeTtsLanguage('fr-FR'), equals('fr-FR'));
      expect(normalizeTtsLanguage('  de-DE  '), equals('de-DE'));
    });
  });

  group('MockTTSEngine Unit Tests', () {
    late MockTTSEngine engine;

    setUp(() {
      engine = MockTTSEngine();
    });

    tearDown(() {
      engine.dispose();
    });

    test('initial state is stopped and language support is valid', () async {
      expect(engine.state, equals(TTSState.stopped));
      expect(await engine.isLanguageAvailable('ja'), isTrue);
      expect(await engine.isLanguageAvailable('ja-JP'), isTrue);
      expect(await engine.isLanguageAvailable('en-US'), isTrue);
      expect(await engine.isLanguageAvailable('vi-VN'), isFalse);
    });

    test('speaks text and records history', () async {
      final success = await engine.speak('こんにちは', languageTag: 'ja-JP');
      expect(success, isTrue);
      expect(engine.spokenTexts, contains('こんにちは'));
      expect(engine.spokenLanguages, contains('ja-JP'));
      expect(engine.state, equals(TTSState.speaking));

      await engine.stop();
      expect(engine.wasStopped, isTrue);
      expect(engine.state, equals(TTSState.stopped));
    });

    test('ignores empty or whitespace text', () async {
      final success = await engine.speak('   ', languageTag: 'ja-JP');
      expect(success, isFalse);
      expect(engine.spokenTexts, isEmpty);
      expect(engine.state, equals(TTSState.stopped));
    });

    test('handles speech rate, volume, and pitch adjustments', () async {
      await engine.setSpeechRate(0.8);
      expect(engine.speechRate, equals(0.8));

      await engine.setVolume(0.5);
      expect(engine.volume, equals(0.5));

      await engine.setPitch(1.2);
      expect(engine.pitch, equals(1.2));
    });

    test('handles engine unavailability and failures gracefully', () async {
      engine.isAvailable = false;
      expect(await engine.isLanguageAvailable('ja'), isFalse);

      final failSpeak = await engine.speak('テスト', languageTag: 'ja-JP');
      expect(failSpeak, isFalse);
      expect(engine.state, equals(TTSState.error));

      engine.isAvailable = true;
      engine.shouldFail = true;
      final failShould = await engine.speak('テスト', languageTag: 'ja-JP');
      expect(failShould, isFalse);
      expect(engine.state, equals(TTSState.error));
    });

    test('emits state changes to stateStream', () async {
      final states = <TTSState>[];
      final subscription = engine.stateStream.listen(states.add);

      await engine.speak('挨拶', languageTag: 'ja-JP');
      await engine.stop();

      await Future.delayed(const Duration(milliseconds: 10));
      expect(states, equals([TTSState.speaking, TTSState.stopped]));
      await subscription.cancel();
    });
  });

  group('PlatformTTSEngine MethodChannel Tests', () {
    const channel = MethodChannel('flutter_tts');
    const nativeChannel = MethodChannel('com.linguacanvas.app/tts_native');
    late PlatformTTSEngine engine;
    final List<MethodCall> channelLog = [];
    bool throwMissingPlugin = false;
    bool throwPlatformException = false;
    dynamic languageResult = 1;
    dynamic speakResult = 1;

    setUp(() {
      channelLog.clear();
      throwMissingPlugin = false;
      throwPlatformException = false;
      languageResult = 1;
      speakResult = 1;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            channelLog.add(call);
            if (throwMissingPlugin) {
              throw MissingPluginException(
                'No implementation found for method ${call.method}',
              );
            }
            if (throwPlatformException) {
              throw PlatformException(code: 'TTS_ERROR', message: 'Failed');
            }

            switch (call.method) {
              case 'isLanguageAvailable':
                return (call.arguments == 'ja-JP' || call.arguments == 'en-US')
                    ? 1
                    : 0;
              case 'speak':
                return speakResult;
              case 'setLanguage':
                return languageResult;
              case 'stop':
              case 'setSpeechRate':
              case 'setVolume':
              case 'setPitch':
                return 1;
              default:
                return null;
            }
          });

      engine = PlatformTTSEngine();
    });

    tearDown(() async {
      await engine.stop();
      engine.dispose();
      await Future<void>.delayed(Duration.zero);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'interacts with method channel on speak, setLanguage, and stop',
      () async {
        final available = await engine.isLanguageAvailable('ja');
        expect(available, isTrue);

        final success = await engine.speak('おはよう', languageTag: 'ja');
        expect(success, isTrue);
        expect(engine.state, equals(TTSState.speaking));

        await engine.stop();
        expect(engine.state, equals(TTSState.stopped));

        await engine.setSpeechRate(0.9);
        await engine.setVolume(0.8);
        await engine.setPitch(1.1);

        final methods = channelLog.map((c) => c.method).toList();
        expect(methods, contains('isLanguageAvailable'));
        expect(methods, contains('setLanguage'));
        expect(methods, contains('speak'));
        expect(methods, contains('stop'));
        expect(methods, contains('setSpeechRate'));
        expect(methods, contains('setVolume'));
        expect(methods, contains('setPitch'));
      },
    );

    test(
      'native playback passes settings and reports asynchronous errors',
      () async {
        final nativeCalls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativeChannel, (call) async {
              nativeCalls.add(call);
              return true;
            });
        await engine.setSpeechRate(0.8);
        await engine.setVolume(0.6);
        await engine.setPitch(1.2);
        channelLog.clear();
        expect(await engine.speak('進捗', languageTag: 'ja'), isTrue);
        expect(channelLog, isEmpty);
        expect(nativeCalls.last.arguments, {
          'text': '進捗',
          'language': 'ja-JP',
          'rate': 0.8,
          'volume': 0.6,
          'pitch': 1.2,
        });
        final error = const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onSpeakError'),
        );
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(nativeChannel.name, error, (_) {});
        expect(engine.state, TTSState.error);
        expect(await engine.openSettings(), isTrue);
      },
    );

    test(
      'unsupported fallback language never speaks in the wrong voice',
      () async {
        languageResult = 0;
        expect(await engine.speak('日本語', languageTag: 'ja'), isFalse);
        expect(channelLog.map((call) => call.method), isNot(contains('speak')));
        expect(engine.state, TTSState.error);
      },
    );

    test(
      'fallback uses chosen settings and rejects null playback result',
      () async {
        await engine.setSpeechRate(0.8);
        await engine.setVolume(0.6);
        await engine.setPitch(1.2);
        channelLog.clear();
        speakResult = null;
        expect(await engine.speak('test', languageTag: 'en'), isFalse);
        expect(
          channelLog.singleWhere((c) => c.method == 'setSpeechRate').arguments,
          0.4,
        );
        expect(
          channelLog.singleWhere((c) => c.method == 'setVolume').arguments,
          0.6,
        );
        expect(
          channelLog.singleWhere((c) => c.method == 'setPitch').arguments,
          1.2,
        );
        expect(engine.state, TTSState.error);
      },
    );

    test('handles MissingPluginException without crashing', () async {
      throwMissingPlugin = true;

      final available = await engine.isLanguageAvailable('ja-JP');
      expect(available, isFalse);

      final success = await engine.speak('エラーテスト', languageTag: 'ja-JP');
      expect(success, isFalse);
      expect(engine.state, equals(TTSState.error));

      // stop should also not throw
      await engine.stop();
    });

    test('handles PlatformException without crashing', () async {
      throwPlatformException = true;

      final available = await engine.isLanguageAvailable('en-US');
      expect(available, isFalse);

      final success = await engine.speak('crash test', languageTag: 'en-US');
      expect(success, isFalse);
      expect(engine.state, equals(TTSState.error));
    });
  });

  group('TtsService Pronunciation Service Tests', () {
    late MockTTSEngine mockEngine;
    late TtsService service;

    setUp(() {
      mockEngine = MockTTSEngine();
      service = TtsService(engine: mockEngine);
    });

    tearDown(() {
      service.dispose();
    });

    test('speakJapanese uses ja-JP normalization', () async {
      final success = await service.speakJapanese('進捗');
      expect(success, isTrue);
      expect(mockEngine.spokenTexts.last, equals('進捗'));
      expect(mockEngine.spokenLanguages.last, equals('ja-JP'));
    });

    test('speakEnglish uses en-US normalization', () async {
      final success = await service.speakEnglish('production deploy');
      expect(success, isTrue);
      expect(mockEngine.spokenTexts.last, equals('production deploy'));
      expect(mockEngine.spokenLanguages.last, equals('en-US'));
    });

    test('speak with custom tag normalizes properly', () async {
      await service.speak('test', language: 'en');
      expect(mockEngine.spokenLanguages.last, equals('en-US'));

      await service.speak('test2', language: 'ja');
      expect(mockEngine.spokenLanguages.last, equals('ja-JP'));
    });

    test('empty string returns false without speaking', () async {
      final success = await service.speak('   ');
      expect(success, isFalse);
      expect(mockEngine.spokenTexts, isEmpty);
    });

    test('reflects state and isSpeaking flag', () async {
      expect(service.isSpeaking, isFalse);
      await service.speak('あ');
      expect(service.isSpeaking, isTrue);
      await service.stop();
      expect(service.isSpeaking, isFalse);
    });
  });

  group('Audio Playback UI Widget Tests', () {
    late MockTTSEngine mockEngine;
    late TtsService ttsService;
    late MockTestApiService apiService;

    setUp(() async {
      await LocalDatabase.instance.initCustom(customPath: inMemoryDatabasePath);
      mockEngine = MockTTSEngine();
      ttsService = TtsService(engine: mockEngine);
      apiService = MockTestApiService();
    });

    tearDown(() async {
      ttsService.dispose();
      await LocalDatabase.instance.close();
    });

    testWidgets('TtsSpeakerButton triggers speak and highlights active icon', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TtsSpeakerButton(
              text: 'あ',
              language: 'ja',
              ttsService: ttsService,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final button = find.byType(TtsSpeakerButton);
      expect(button, findsOneWidget);

      await tester.tap(button);
      await tester.pump();

      expect(mockEngine.spokenTexts, contains('あ'));
      expect(mockEngine.spokenLanguages, contains('ja-JP'));

      // Settle timer
      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets(
      'speaker stays active until playback stops, and can stop speech',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TtsSpeakerButton(
                text: '長い文章',
                language: 'ja',
                ttsService: ttsService,
              ),
            ),
          ),
        );
        await tester.tap(find.byType(TtsSpeakerButton));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
        await tester.tap(find.byType(TtsSpeakerButton));
        await tester.pump();
        expect(mockEngine.wasStopped, isTrue);
        expect(find.byIcon(Icons.volume_up_outlined), findsOneWidget);
      },
    );

    for (final chip in [false, true]) {
      testWidgets('failed playback shows voice setup for chip=$chip', (
        tester,
      ) async {
        mockEngine.shouldFail = true;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: chip
                  ? TtsChipSpeakerIcon(
                      text: '日本語',
                      language: 'ja',
                      ttsService: ttsService,
                    )
                  : TtsSpeakerButton(
                      text: '日本語',
                      language: 'ja',
                      ttsService: ttsService,
                    ),
            ),
          ),
        );
        await tester.tap(find.byIcon(Icons.volume_up_outlined));
        await tester.pumpAndSettle();
        expect(find.text('Cài đặt giọng'), findsOneWidget);
        expect(find.byIcon(Icons.volume_up_outlined), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets(
      'CanvasPracticeScreen renders speaker button and plays target audio',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: CanvasPracticeScreen(
              apiService: apiService,
              digitalInkEngine: MockDigitalInkEngine(),
              ttsService: ttsService,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Find speaker button next to 'あ'
        final speakerButtons = find.byType(TtsSpeakerButton);
        expect(speakerButtons, findsWidgets);

        await tester.tap(speakerButtons.first);
        await tester.pump();

        expect(mockEngine.spokenTexts, contains('あ'));
        expect(mockEngine.spokenLanguages, contains('ja-JP'));
        await tester.pump(const Duration(milliseconds: 700));
      },
    );

    testWidgets(
      'AIRoleplayScreen renders speaker buttons for dialogue and vocabulary',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: AIRoleplayScreen(
              apiService: apiService,
              ttsService: ttsService,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Check speaker buttons in interactive chat tab
        final dialogueSpeakers = find.byType(TtsSpeakerButton);
        expect(dialogueSpeakers, findsWidgets);

        final chipSpeakers = find.byType(TtsChipSpeakerIcon);
        expect(chipSpeakers, findsWidgets);

        // Tap the dialogue turn speaker button
        await tester.tap(dialogueSpeakers.first);
        await tester.pump();
        expect(mockEngine.spokenTexts.isNotEmpty, isTrue);

        await mockEngine.stop();
        await tester.pump();
        // Tap vocabulary chip speaker icon
        final previousCount = mockEngine.spokenTexts.length;
        await tester.tap(chipSpeakers.first);
        await tester.pump();
        expect(mockEngine.spokenTexts.length, greaterThan(previousCount));

        // Switch to Dialogue Script Tab
        await tester.tap(find.text('Kịch Bản Tình Huống'));
        await tester.pumpAndSettle();

        // Tap create script button
        final createScriptBtn = find.text('Sinh kịch bản với AI Local');
        expect(createScriptBtn, findsOneWidget);
        await tester.tap(createScriptBtn);
        await tester.pumpAndSettle();

        // Verify speaker button on dialogue script turns and vocabulary card
        expect(find.byType(TtsSpeakerButton), findsWidgets);
        final turnSpeaker = find.byTooltip('Phát âm câu thoại');
        expect(turnSpeaker, findsWidgets);
        await tester.tap(turnSpeaker.first);
        await tester.pump();
        expect(mockEngine.spokenTexts, contains('進捗はどうですか？'));

        await tester.pump(const Duration(milliseconds: 700));
      },
    );

    testWidgets('CurriculumScreen renders speaker button on vocabulary card', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: CurriculumScreen(
            apiService: apiService,
            ttsService: ttsService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final speakerButtons = find.byType(TtsSpeakerButton);
      expect(speakerButtons, findsWidgets);

      // Tap first speaker button on card ('あ')
      await tester.tap(speakerButtons.first);
      await tester.pump();
      expect(mockEngine.spokenTexts, contains('あ'));
      expect(mockEngine.spokenLanguages, contains('ja-JP'));

      await mockEngine.stop();
      await tester.pump();
      // Tap second speaker button on card ('deploy')
      await tester.tap(speakerButtons.at(1));
      await tester.pump();
      expect(mockEngine.spokenTexts, contains('deploy'));
      expect(mockEngine.spokenLanguages, contains('en-US'));

      await tester.pump(const Duration(milliseconds: 700));
    });
  });
}
