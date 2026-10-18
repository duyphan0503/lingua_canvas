import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/screens/ai_roleplay_screen.dart';
import 'package:app/services/api_service.dart';

class MockRoleplayApiService extends ApiService {
  @override
  Future<Map<String, dynamic>> sendRoleplayMessage({
    required String targetLanguage,
    required String topic,
    required String message,
    String profession = 'it',
    String userLevel = 'beginner',
  }) async {
    return {
      'reply': 'テスト返信です (Test response)',
      'romaji': 'Tesuto henshin desu',
      'reply_translation_vi': 'Đây là câu trả lời thử nghiệm',
      'breakdown': [
        {
          'word': '返信',
          'meaning_vi': 'Hồi đáp / Trả lời',
          'kana_or_phonetic': 'へんしん',
        },
      ],
      'writing_challenge': '返信',
    };
  }

  @override
  Future<Map<String, dynamic>> generateDialogue({
    required String targetLanguage,
    required String topic,
    String profession = 'IT',
    String level = 'beginner',
    int turnCount = 4,
  }) async {
    return {
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
}

void main() {
  group('AIRoleplayScreen Widget Tests', () {
    testWidgets('profession and level can be selected for roleplay', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AIRoleplayScreen(apiService: MockRoleplayApiService()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profession-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kinh doanh').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('level-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nâng cao').last);
      await tester.pumpAndSettle();
      expect(find.text('Kinh doanh'), findsOneWidget);
      expect(find.text('Nâng cao'), findsOneWidget);
    });

    testWidgets('English dialogue offers working handwriting actions', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(394, 853);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? practicedWord;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: AIRoleplayScreen(
            apiService: MockRoleplayApiService(),
            onPracticeWord: (word, language) => practicedWord = word,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Tiếng Anh'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I completed the API integration yesterday.'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Thử thách viết'), findsOneWidget);
      expect(find.byIcon(Icons.draw_rounded), findsWidgets);
      await tester.tap(find.textContaining('Thử thách viết'));
      expect(practicedWord, '返信');
    });

    testWidgets('renders roleplay chat and sends interactive message', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final service = MockRoleplayApiService();
      String? practicedWord;

      await tester.pumpWidget(
        MaterialApp(
          home: AIRoleplayScreen(
            apiService: service,
            onPracticeWord: (word, lang) => practicedWord = word,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify AI initial greeting is displayed
      expect(find.text('AI Workplace Role-Play'), findsOneWidget);
      expect(find.textContaining('進捗'), findsWidgets);

      // Tap quick suggestion chip
      final chip = find.textContaining('今日の進捗を報告します');
      expect(chip, findsOneWidget);
      await tester.tap(chip);
      await tester.pump();
      await tester.pumpAndSettle();

      // Verify user message and AI response
      expect(find.text('今日の進捗を報告します。'), findsOneWidget);
      expect(find.text('テスト返信です (Test response)'), findsOneWidget);
      expect(find.text('Dịch: Đây là câu trả lời thử nghiệm'), findsOneWidget);

      // Verify writing challenge triggers onPracticeWord
      final challengeBtn = find.textContaining('Thử thách viết: "返信"');
      expect(challengeBtn, findsOneWidget);
      await tester.tap(challengeBtn);
      expect(practicedWord, '返信');
    });

    testWidgets('switches to dialogue script tab and fetches sample script', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final service = MockRoleplayApiService();
      await tester.pumpWidget(
        MaterialApp(home: AIRoleplayScreen(apiService: service)),
      );
      await tester.pumpAndSettle();

      // Switch to Dialogue Script Tab
      final scriptTab = find.text('Kịch Bản Tình Huống');
      await tester.tap(scriptTab);
      await tester.pumpAndSettle();

      // Tap generate dialogue button
      final genBtn = find.text('Sinh kịch bản với AI Local');
      expect(genBtn, findsOneWidget);
      await tester.tap(genBtn);
      await tester.pump();
      await tester.pumpAndSettle();

      // Verify generated script turns and vocabulary
      expect(find.text('進捗はどうですか？'), findsOneWidget);
      expect(find.text('• Tiến độ thế nào?'), findsOneWidget);
    });
  });
}
