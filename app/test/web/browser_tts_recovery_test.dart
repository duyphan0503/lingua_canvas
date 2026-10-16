@TestOn('browser')
library;

import 'package:app/services/tts_service.dart';
import 'package:app/widgets/tts_speaker_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final chip in [false, true]) {
    testWidgets(
      'failed browser playback offers browser recovery for chip=$chip',
      (tester) async {
        final engine = MockTTSEngine()..shouldFail = true;
        final service = TtsService(engine: engine);
        addTearDown(service.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: chip
                  ? TtsChipSpeakerIcon(
                      text: '日本語',
                      language: 'ja',
                      ttsService: service,
                    )
                  : TtsSpeakerButton(
                      text: '日本語',
                      language: 'ja',
                      ttsService: service,
                    ),
            ),
          ),
        );
        await tester.tap(find.byIcon(Icons.volume_up_outlined));
        await tester.pumpAndSettle();

        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.textContaining('trình duyệt'), findsOneWidget);
        expect(find.textContaining('tiếng Nhật/Anh'), findsOneWidget);
        expect(find.text('Cài đặt giọng'), findsNothing);
        expect(find.textContaining('Android'), findsNothing);
        expect(find.byType(SnackBarAction), findsNothing);
        expect(find.byIcon(Icons.volume_up_outlined), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
