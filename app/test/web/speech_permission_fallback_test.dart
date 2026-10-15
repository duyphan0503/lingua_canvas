import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/speech_practice_service.dart';
import 'package:app/widgets/speech_capture_dialog.dart';

class DeniedSpeech implements SpeechPracticeEngine {
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<String> listen({required String language}) async =>
      throw const SpeechPracticeException('permission_denied', 'denied');
  @override
  Future<void> stop() async {}
}

void main() {
  testWidgets('permission denial offers explicit typed comparison', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              await captureSpeechTranscript(
                context,
                SpeechPracticeService(engine: DeniedSpeech()),
                'ja',
                isCurrent: () => context.mounted,
              );
            },
            child: const Text('Speak'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Speak'));
    await tester.pumpAndSettle();
    expect(find.text('Nhập bản phiên âm'), findsOneWidget);
    expect(find.textContaining('không thu âm'), findsOneWidget);
    await tester.tap(find.text('Hủy'));
    await tester.pumpAndSettle();
  });
}
