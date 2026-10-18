import 'dart:async';

import 'package:app/services/speech_practice_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pronunciation scoring', () {
    final service = SpeechPracticeService(engine: MockSpeechPracticeEngine());
    PronunciationResult score(
      String recognized,
      String target, [
      String kana = '',
    ]) => service.evaluatePronunciation(
      recognized: recognized,
      targetText: target,
      phoneticOrKana: kana,
      language: 'ja',
    );

    test('normalizes punctuation case and whitespace', () {
      expect(score('  Hello,\n WORLD！ ', 'hello world').accuracyScore, 1);
      expect(score('開 発。', '開発').accuracyScore, 1);
    });

    test('accepts kana and romaji alternatives', () {
      expect(score('かいはつ', '開発', 'かいはつ').isPassed, isTrue);
      expect(score('KAIHATSU', '開発', 'kaihatsu').accuracyScore, 1);
    });

    test('uses actual edit distance and a 75 percent passing threshold', () {
      final result = score('cat', 'cart');
      expect(result.accuracyScore, 0.75);
      expect(result.isPassed, isTrue);
      expect(result.feedbackVi, contains('75%'));
      expect(score('cut', 'cart').isPassed, isFalse);
    });

    test('empty transcript or empty targets cannot score perfect', () {
      expect(score('', '').accuracyScore, 0);
      expect(score('', '開発').accuracyScore, 0);
      expect(score('hello', '').accuracyScore, 0);
      expect(score('!', '?', '').isPassed, isFalse);
    });

    test('low score feedback identifies heard and expected text', () {
      final result = score('dog', 'cat');
      expect(result.feedbackVi, contains('dog'));
      expect(result.feedbackVi, contains('cat'));
      expect(result.recognizedTranscript, 'dog');
      expect(result.targetText, 'cat');
    });
  });

  group('platform recognition contract', () {
    const channel = MethodChannel('test/speech');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late PlatformSpeechPracticeEngine engine;
    late List<Map<String, dynamic>> starts;
    late List<int> stopped;

    Future<void> emit(String method, Map<String, Object> event) async {
      final done = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, event)),
        (_) => done.complete(),
      );
      await done.future;
    }

    Future<void> flush() => Future<void>.delayed(Duration.zero);
    Matcher errorCode(String code) => isA<SpeechPracticeException>().having(
      (error) => error.code,
      'code',
      code,
    );

    setUp(() {
      starts = [];
      stopped = [];
      engine = PlatformSpeechPracticeEngine(
        channel: channel,
        platform: TargetPlatform.android,
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isAvailable') return true;
        if (call.method == 'startListening') {
          starts.add(Map<String, dynamic>.from(call.arguments as Map));
          return true;
        }
        if (call.method == 'stopListening') {
          stopped.add((call.arguments as Map)['sessionId'] as int);
          return true;
        }
        throw MissingPluginException();
      });
    });

    tearDown(() async {
      await engine.stop();
      messenger.setMockMethodCallHandler(channel, null);
    });

    test(
      'listening waits for final transcript and normalizes language',
      () async {
        expect(await engine.isAvailable(), isTrue);
        final transcript = engine.listen(language: 'ja');
        await flush();
        final id = starts.single['sessionId'] as int;
        expect(starts.single['language'], 'ja-JP');
        await emit('onSpeechPartial', {'sessionId': id, 'transcript': 'かい'});
        await emit('onSpeechResult', {'sessionId': id, 'transcript': '開発'});
        expect(await transcript, '開発');
      },
    );

    test(
      'late events from superseded recording cannot complete a new one',
      () async {
        final first = engine.listen(language: 'ja');
        final cancelled = expectLater(first, throwsA(errorCode('cancelled')));
        await flush();
        final firstId = starts.single['sessionId'] as int;
        final second = engine.listen(language: 'en');
        await cancelled;
        await flush();
        final secondId = starts.last['sessionId'] as int;
        expect(starts.last['language'], 'en-US');
        await emit('onSpeechResult', {
          'sessionId': firstId,
          'transcript': 'old',
        });
        await emit('onSpeechError', {
          'sessionId': firstId,
          'code': 'permission_denied',
        });
        await emit('onSpeechResult', {
          'sessionId': secondId,
          'transcript': 'new',
        });
        expect(await second, 'new');
      },
    );

    test(
      'stop rejects pending recording and cancels its native session',
      () async {
        final future = engine.listen(language: 'en-US');
        final rejected = expectLater(future, throwsA(errorCode('cancelled')));
        await flush();
        final id = starts.single['sessionId'] as int;
        await engine.stop();
        await rejected;
        expect(stopped, contains(id));
        await emit('onSpeechResult', {'sessionId': id, 'transcript': 'late'});
      },
    );

    test('permission denial becomes actionable typed error', () async {
      final future = engine.listen(language: 'ja');
      final rejected = expectLater(
        future,
        throwsA(errorCode('permission_denied')),
      );
      await flush();
      await emit('onSpeechError', {
        'sessionId': starts.single['sessionId'] as int,
        'code': 'permission_denied',
        'message': 'Microphone permission denied',
      });
      await rejected;
    });

    test('start failures reject without waiting for a callback', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'unavailable',
          message: 'No recognition service',
        );
      });
      await expectLater(
        engine.listen(language: 'ja'),
        throwsA(errorCode('unavailable')),
      );
    });

    test(
      'native start rejection and empty results produce typed failures',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async => false);
        await expectLater(
          engine.listen(language: 'en'),
          throwsA(errorCode('recognition_failed')),
        );
      },
    );

    test(
      'empty final transcript is rejected and a later recording still works',
      () async {
        final empty = engine.listen(language: 'ja');
        final rejected = expectLater(
          empty,
          throwsA(errorCode('recognition_failed')),
        );
        await flush();
        await emit('onSpeechResult', {
          'sessionId': starts.single['sessionId'] as int,
          'transcript': '  ',
        });
        await rejected;
        final retry = engine.listen(language: 'ja');
        await flush();
        await emit('onSpeechResult', {
          'sessionId': starts.last['sessionId'] as int,
          'transcript': '開発',
        });
        expect(await retry, '開発');
      },
    );

    test('late failed start cannot cancel a newer recording', () async {
      final nativeStart = Completer<bool>();
      var count = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startListening') {
          starts.add(Map<String, dynamic>.from(call.arguments as Map));
          if (++count == 1) return nativeStart.future;
        }
        return true;
      });
      final first = engine.listen(language: 'ja');
      final cancelled = expectLater(first, throwsA(errorCode('cancelled')));
      await flush();
      final second = engine.listen(language: 'en');
      await cancelled;
      await flush();
      nativeStart.completeError(PlatformException(code: 'recognition_failed'));
      await flush();
      await emit('onSpeechResult', {
        'sessionId': starts.last['sessionId'] as int,
        'transcript': 'hello',
      });
      expect(await second, 'hello');
    });

    test('missing native plugin reports unavailable', () async {
      messenger.setMockMethodCallHandler(channel, null);
      expect(await engine.isAvailable(), isFalse);
      await expectLater(
        engine.listen(language: 'ja'),
        throwsA(errorCode('unavailable')),
      );
    });

    test('unknown native errors produce a safe recognition error', () async {
      final future = engine.listen(language: 'ja');
      final rejected = expectLater(
        future,
        throwsA(errorCode('recognition_failed')),
      );
      await flush();
      await emit('onSpeechError', {
        'sessionId': starts.single['sessionId'] as int,
        'code': 'network_error',
      });
      await rejected;
    });

    test(
      'timeout cancels native session and late result does not bleed',
      () async {
        engine = PlatformSpeechPracticeEngine(
          channel: channel,
          platform: TargetPlatform.android,
          timeout: const Duration(milliseconds: 20),
        );
        await expectLater(
          engine.listen(language: 'ja'),
          throwsA(errorCode('timeout')),
        );
        final oldId = starts.single['sessionId'] as int;
        await flush();
        expect(stopped, contains(oldId));
        final next = engine.listen(language: 'en');
        await flush();
        await emit('onSpeechResult', {'sessionId': oldId, 'transcript': 'old'});
        await emit('onSpeechResult', {
          'sessionId': starts.last['sessionId'] as int,
          'transcript': 'next',
        });
        expect(await next, 'next');
      },
    );

    test('Linux is unavailable and never invents a transcript', () async {
      final linux = PlatformSpeechPracticeEngine(
        platform: TargetPlatform.linux,
      );
      expect(await linux.isAvailable(), isFalse);
      await expectLater(
        linux.listen(language: 'ja'),
        throwsA(errorCode('unavailable')),
      );
    });
  });

  test(
    'default services share a handler when multiple screens stay mounted',
    () async {
      const nativeChannel = MethodChannel('com.linguacanvas.app/stt_native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      int? sessionId;
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        if (call.method == 'startListening') {
          sessionId = (call.arguments as Map)['sessionId'] as int;
        }
        return true;
      });
      final first = SpeechPracticeService();
      try {
        final transcript = first.listen(language: 'ja');
        await Future<void>.delayed(Duration.zero);
        final second = SpeechPracticeService();
        expect(await second.isAvailable(), isTrue);
        final delivered = Completer<void>();
        messenger.handlePlatformMessage(
          nativeChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('onSpeechResult', {
              'sessionId': sessionId,
              'transcript': '開発',
            }),
          ),
          (_) => delivered.complete(),
        );
        await delivered.future;
        expect(await transcript, '開発');
      } finally {
        await first.stop();
        messenger.setMockMethodCallHandler(nativeChannel, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  test(
    'injected engine supplies deterministic transcript for real scoring',
    () async {
      final service = SpeechPracticeService(
        engine: MockSpeechPracticeEngine(transcript: 'かいはつ'),
      );
      expect(await service.isAvailable(), isTrue);
      final heard = await service.listen(language: 'ja');
      expect(
        service
            .evaluatePronunciation(
              recognized: heard,
              targetText: '開発',
              phoneticOrKana: 'かいはつ',
              language: 'ja',
            )
            .accuracyScore,
        1,
      );
      await service.stop();
    },
  );
}
