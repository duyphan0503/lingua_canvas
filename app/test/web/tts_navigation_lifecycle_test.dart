import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/screens/main_shell_screen.dart';
import 'package:app/screens/settings_screen.dart';
import 'package:app/services/tts_service.dart';
import '../screens/main_navigation_test.dart'
    show MockNavigationApiService, MockNavigationInkEngine;
import 'responsive_navigation_test.dart' show LocalOnlyAccount;

void main() {
  for (final width in [390.0, 1440.0]) {
    testWidgets('navigation stops speech at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = MockNavigationApiService();
      final engine = MockTTSEngine();
      final tts = TtsService(engine: engine);
      await tester.pumpWidget(
        MaterialApp(
          home: MainShellScreen(
            apiService: api,
            accountService: LocalOnlyAccount(api),
            digitalInkEngine: MockNavigationInkEngine(),
            ttsService: tts,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tts.speak('Test utterance');
      expect(engine.wasStopped, isFalse);
      await tester.tap(find.text('Cài Đặt').last);
      await tester.pumpAndSettle();
      expect(engine.wasStopped, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('profile/reset callbacks and shell disposal stop speech', (
    tester,
  ) async {
    final api = MockNavigationApiService();
    final engine = MockTTSEngine();
    final tts = TtsService(engine: engine);
    await tester.pumpWidget(
      MaterialApp(
        home: MainShellScreen(
          apiService: api,
          accountService: LocalOnlyAccount(api),
          digitalInkEngine: MockNavigationInkEngine(),
          ttsService: tts,
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final reset in [false, true]) {
      await tts.speak('Old profile utterance');
      expect(engine.wasStopped, isFalse);
      final settings = tester.widget<SettingsScreen>(
        find.byType(SettingsScreen, skipOffstage: false),
      );
      (reset ? settings.onResetData : settings.onAccountChanged)!();
      await tester.pumpAndSettle();
      expect(engine.wasStopped, isTrue);
    }
    await tts.speak('Leaving shell');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(engine.wasStopped, isTrue);
  });
}
