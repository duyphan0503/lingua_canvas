import 'package:app/services/local_practice_audio.dart';
import 'package:app/widgets/local_practice_audio_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLocalPracticeAudio implements LocalPracticeAudio {
  bool recording = false;
  bool saved = false;
  int replayCount = 0;
  @override
  bool get isRecording => recording;
  @override
  bool get hasRecording => saved;
  @override
  Future<void> start() async {
    recording = true;
  }

  @override
  Future<void> stop() async {
    recording = false;
    saved = true;
  }

  @override
  Future<void> replay() async {
    replayCount++;
  }

  @override
  Future<void> deleteRecording() async {
    saved = false;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('records, replays, and deletes a local clip', (tester) async {
    final audio = _FakeLocalPracticeAudio();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LocalPracticeAudioControls(audio: audio)),
      ),
    );

    expect(find.byTooltip('Nghe lại bản ghi'), findsOneWidget);
    await tester.tap(find.byTooltip('Ghi âm cục bộ'));
    await tester.pumpAndSettle();
    expect(audio.isRecording, isTrue);

    await tester.tap(find.byTooltip('Dừng ghi âm'));
    await tester.pumpAndSettle();
    expect(audio.hasRecording, isTrue);

    await tester.tap(find.byTooltip('Nghe lại bản ghi'));
    await tester.pumpAndSettle();
    expect(audio.replayCount, 1);

    await tester.tap(find.byTooltip('Xóa bản ghi trên thiết bị'));
    await tester.pumpAndSettle();
    expect(audio.hasRecording, isFalse);
  });
}
