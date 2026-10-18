import 'dart:convert';
import 'package:app/screens/settings_screen.dart';
import 'package:app/services/account_service.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/local_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class HealthyApi extends ApiService {
  HealthyApi(LocalDatabase db)
    : super(localDb: db, baseUrl: 'http://test/api/v1');
  @override
  Future<bool> checkBackendHealth() async => true;
}

void main() {
  testWidgets(
    'settings registers, copies token, logs out and links a persisted account',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late LocalDatabase db;
      await tester.runAsync(() async {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        db = LocalDatabase.instance;
        await db.initCustom(customPath: inMemoryDatabasePath);
      });
      addTearDown(() => db.close());
      final api = HealthyApi(db);
      var changes = 0;
      final service = AccountService(
        apiService: api,
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'user_id': 'usr_a',
              'username': 'alice',
              'display_name': 'Alice',
              'sync_token': 'lct_secret',
              'devices': [
                {
                  'device_id': 'one',
                  'device_name': 'Linux Desktop',
                  'platform': 'linux',
                  'last_sync_seq': 1,
                  'last_seen_at': '2026-10-14T00:00:00Z',
                },
              ],
            }),
            200,
          ),
        ),
      );
      Future<void> settleIo() async {
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            apiService: api,
            accountService: service,
            onAccountChanged: () => changes++,
          ),
        ),
      );
      await settleIo();
      expect(
        find.text('Tài Khoản & Đồng Bộ Đa Thiết Bị (Android ↔ Linux ↔ Web)'),
        findsOneWidget,
      );
      await tester.tap(find.text('Tạo Tài Khoản Đồng Bộ'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Username'),
        'alice',
      );
      await tester.enterText(find.widgetWithText(TextField, 'PIN'), '1234');
      await tester.tap(find.text('Tạo tài khoản'));
      await settleIo();
      expect(find.textContaining('usr_a'), findsOneWidget);
      expect(find.textContaining('Linux Desktop'), findsOneWidget);
      await tester.runAsync(() async {
        expect((await db.getAccount())!['sync_token'], 'lct_secret');
      });
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'];
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.text('Sao chép Sync Token'));
      await tester.pump();
      expect(copied, 'lct_secret');
      await tester.tap(find.text('Đăng xuất hồ sơ'));
      await settleIo();
      await tester.runAsync(() async {
        expect(await db.getAccount(), isNull);
      });
      await tester.tap(find.text('Liên Kết Thiết Bị Đã Có'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dùng Sync Token'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Sync Token'),
        'lct_secret',
      );
      await tester.tap(find.text('Liên kết'));
      await settleIo();
      await tester.runAsync(() async {
        expect((await db.getAccount())!['username'], 'alice');
      });
      expect(changes, 3);
    },
  );
}
