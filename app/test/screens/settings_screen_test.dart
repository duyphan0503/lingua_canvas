import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/screens/settings_screen.dart';
import 'package:app/services/api_service.dart';

class MockSettingsApiService extends ApiService {
  bool healthResult = true;

  @override
  Future<bool> checkBackendHealth() async => healthResult;
}

void main() {
  group('SettingsScreen Widget Tests', () {
    testWidgets('invalid server URL is rejected without changing connection', (
      tester,
    ) async {
      final service = MockSettingsApiService();
      final initialUrl = service.baseUrl;
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(apiService: service)),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'not a URL');
      await tester.tap(find.text('Lưu & Áp dụng'));
      await tester.pump();

      expect(service.baseUrl, initialUrl);
      expect(
        find.textContaining('Địa chỉ máy chủ không hợp lệ'),
        findsOneWidget,
      );
    });

    testWidgets('renders configuration and checks server health', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final service = MockSettingsApiService();

      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(apiService: service)),
      );
      await tester.pumpAndSettle();

      // Verify sections
      expect(find.text('Cài Đặt & Kết Nối Hệ Thống'), findsOneWidget);
      expect(find.text('Địa Chỉ Máy Chủ Backend (Rust Axum)'), findsOneWidget);
      expect(find.text('Mô Hình AI & Nhận Diện'), findsOneWidget);
      expect(find.text('Bộ Nhớ Cục Bộ (SQLite Database)'), findsOneWidget);

      // Verify server health message
      expect(
        find.textContaining('Kết nối Máy chủ Rust Axum thành công'),
        findsOneWidget,
      );

      // Tap preset chip
      final presetChip = find.text('Localhost (127.0.0.1:8080)');
      await tester.tap(presetChip);
      await tester.pumpAndSettle();
      expect(service.baseUrl, 'http://127.0.0.1:8080/api/v1');
    });
  });
}
