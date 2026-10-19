import 'package:app/services/storage/credential_vault.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native Android vault reports errors without requesting credential reset',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      Map? options;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            options = call.arguments['options'] as Map;
            throw PlatformException(code: 'KeyStoreUnavailable');
          });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      await expectLater(
        const NativeCredentialVault().write('reference', 'secret'),
        throwsA(isA<PlatformException>()),
      );
      expect(options!['resetOnError'], 'false');
      expect(options!['migrateWithBackup'], 'true');
    },
  );
}
