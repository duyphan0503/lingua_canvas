import 'package:app/services/account_service.dart';
import 'package:app/services/api_service.dart';
import 'package:app/widgets/account_settings_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class NoGuestApi extends ApiService {
  @override
  Future<ProfileBackup> exportGuestBackup({Set<String>? lessonIds}) async =>
      throw StateError('no guest snapshot');
}

class ControlAccountService extends AccountService {
  ControlAccountService() : super(apiService: NoGuestApi());
  final actions = <String>[];
  @override
  Future<Map<String, dynamic>?> currentAccount() async => {
    'user_id': 'alice',
    'username': 'alice',
    'sync_token': 'secret',
    'devices': [
      {
        'device_id': 'other',
        'device_name': 'Other Linux',
        'platform': 'linux',
        'last_sync_seq': 1,
        'last_seen_at': null,
      },
    ],
  };
  @override
  bool matchesServer(Map<String, dynamic> account) => true;
  @override
  Future<void> rotateToken({required String currentPin}) async {
    actions.add('rotate:$currentPin');
  }

  @override
  Future<void> changePin({
    required String currentPin,
    required String newPin,
  }) async {
    actions.add('pin:$currentPin:$newPin');
  }

  @override
  Future<void> revokeDevice(String deviceId) async {
    actions.add('revoke:$deviceId');
  }
}

void main() {
  testWidgets('account controls collect PINs and confirm device revocation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = ControlAccountService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccountSettingsCard(service: service)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Đổi Sync Token'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'PIN hiện tại'),
      '1234',
    );
    await tester.tap(find.text('Xác nhận'));
    await tester.pumpAndSettle();
    expect(service.actions, ['rotate:1234']);
    await tester.tap(find.text('Đổi PIN'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'PIN hiện tại'),
      '1234',
    );
    await tester.enterText(find.widgetWithText(TextField, 'PIN mới'), '5678');
    await tester.tap(find.text('Xác nhận'));
    await tester.pumpAndSettle();
    expect(service.actions.last, 'pin:1234:5678');
    await tester.tap(find.byTooltip('Thu hồi thiết bị'));
    await tester.pumpAndSettle();
    expect(service.actions, hasLength(2));
    await tester.tap(find.text('Thu hồi'));
    await tester.pumpAndSettle();
    expect(service.actions.last, 'revoke:other');
  });
}
