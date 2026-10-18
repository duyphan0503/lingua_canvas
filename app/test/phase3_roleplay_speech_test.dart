import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/screens/ai_roleplay_screen.dart';
import 'package:app/services/speech_practice_service.dart';
import 'screens/ai_roleplay_screen_test.dart' show MockRoleplayApiService;

class DelayedSpeechEngine implements SpeechPracticeEngine {
  final available = Completer<bool>();
  int starts = 0;
  @override
  Future<bool> isAvailable() => available.future;
  @override
  Future<String> listen({required String language}) async {
    starts++;
    return 'late';
  }

  @override
  Future<void> stop() async {}
}

void main() {
  testWidgets('leaving the screen during availability never starts recording', (
    tester,
  ) async {
    final engine = DelayedSpeechEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: AIRoleplayScreen(
          apiService: MockRoleplayApiService(),
          speechService: SpeechPracticeService(engine: engine),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Nhập bằng giọng nói'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    engine.available.complete(true);
    await tester.pumpAndSettle();
    expect(engine.starts, 0);
  });
  testWidgets('dictation fills the roleplay input without sending it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: AIRoleplayScreen(
          apiService: MockRoleplayApiService(),
          speechService: SpeechPracticeService(
            engine: MockSpeechPracticeEngine(transcript: '会議を始めましょう'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Nhập bằng giọng nói'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '会議を始めましょう',
    );
    expect(find.text('テスト返信です (Test response)'), findsNothing);
  });
}
