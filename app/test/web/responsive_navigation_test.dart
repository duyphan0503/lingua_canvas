import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/screens/main_shell_screen.dart';
import 'package:app/services/account_service.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/tts_service.dart';
import '../screens/main_navigation_test.dart'
    show MockNavigationApiService, MockNavigationInkEngine;

class LocalOnlyAccount extends AccountService {
  LocalOnlyAccount(ApiService api) : super(apiService: api);
  @override
  Future<Map<String, dynamic>?> currentAccount() async => null;
}

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(768, 1024),
    const Size(1440, 900),
    const Size(1440, 600),
  ]) {
    testWidgets('five screens fit ${size.width}x${size.height}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = MockNavigationApiService();
      final tts = TtsService(engine: MockTTSEngine());
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
      expect(
        find.byType(size.width >= 900 ? NavigationRail : NavigationBar),
        findsOneWidget,
      );
      for (final label in [
        'AI Đối Thoại',
        'Giáo Trình',
        'Thống Kê',
        'Cài Đặt',
        'Học & Ôn tập',
      ]) {
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        if (label == 'Thống Kê') {
          await tester.scrollUntilVisible(
            find.text('Đồng bộ tiến độ với máy chủ'),
            250,
            scrollable: find
                .byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down,
                )
                .first,
          );
          expect(find.text('Đồng bộ tiến độ với máy chủ'), findsOneWidget);
          expect(find.textContaining('khớp với Cloud'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('resizing preserves selected screen', (tester) async {
    tester.view.physicalSize = const Size(768, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = MockNavigationApiService();
    await tester.pumpWidget(
      MaterialApp(
        home: MainShellScreen(
          apiService: api,
          accountService: LocalOnlyAccount(api),
          digitalInkEngine: MockNavigationInkEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Giáo Trình').last);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      2,
    );
    expect(find.text('Thư Viện Giáo Trình & Từ Vựng'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
