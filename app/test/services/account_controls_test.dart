import 'dart:async';
import 'dart:convert';
import 'package:app/services/account_service.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/storage/credential_vault.dart';
import 'package:app/services/storage/local_database_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../storage/native_credential_vault_test.dart' show account;

void main() {
  late LocalDatabase db;
  late ApiService api;
  late String ownDevice;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = LocalDatabase.instance;
    await db.initCustom(
      customPath: inMemoryDatabasePath,
      credentialVault: InMemoryCredentialVault(),
    );
    api = ApiService(localDb: db, baseUrl: 'http://a/api/v1');
    await db.switchAccount(account('alice', 'old_secret'));
    ownDevice = await db.getOrCreateClientId();
  });
  tearDown(() => db.close());

  for (final changePin in [false, true]) {
    test(
      '${changePin ? "PIN change" : "rotation"} authenticates and stores fresh token',
      () async {
        await db.saveCompletedLesson('lesson_a');
        final service = AccountService(
          apiService: api,
          httpClient: MockClient((request) async {
            expect(
              request.url.path,
              changePin
                  ? '/api/v1/auth/pin/change'
                  : '/api/v1/auth/token/rotate',
            );
            expect(request.headers['X-Sync-Token'], 'old_secret');
            expect(request.followRedirects, isFalse);
            expect(
              jsonDecode(request.body),
              changePin
                  ? {'current_pin': '1234', 'new_pin': '5678'}
                  : {'current_pin': '1234'},
            );
            return http.Response(
              jsonEncode(account('alice', 'new_secret')),
              200,
            );
          }),
        );
        if (changePin) {
          await service.changePin(currentPin: '1234', newPin: '5678');
        } else {
          await service.rotateToken(currentPin: '1234');
        }
        expect((await db.getAccount())!['sync_token'], 'new_secret');
        expect(await db.getCompletedCount(), 1);
        expect(
          jsonEncode(await (await db.database).query('local_sync_metadata')),
          isNot(contains('new_secret')),
        );
      },
    );
  }

  test(
    'revoke another device keeps local profile; revoke self logs out safely',
    () async {
      final service = AccountService(
        apiService: api,
        httpClient: MockClient((request) async {
          expect(request.method, 'DELETE');
          expect(request.headers['X-Sync-Token'], 'old_secret');
          return http.Response('', 204);
        }),
      );
      await db.saveCompletedLesson('lesson_a');
      await service.revokeDevice('other_device');
      expect((await db.getAccount())!['user_id'], 'alice');
      await service.revokeDevice(ownDevice);
      expect(await db.getAccount(), isNull);
      await db.switchAccount(account('alice', 'relinked_secret'));
      expect(await db.getCompletedCount(), 1);
    },
  );

  test(
    'backend change during rotation cannot install response on another server',
    () async {
      final response = Completer<http.Response>();
      final started = Completer<void>();
      final service = AccountService(
        apiService: api,
        httpClient: MockClient((request) {
          started.complete();
          return response.future;
        }),
      );
      final operation = service.rotateToken(currentPin: '1234');
      final expected = expectLater(operation, throwsA(isA<AccountException>()));
      await started.future;
      api.setBaseUrl('http://b/api/v1');
      response.complete(
        http.Response(jsonEncode(account('alice', 'wrong_server_secret')), 200),
      );
      await expected;
      expect((await db.getAccount())!['sync_token'], 'old_secret');
    },
  );

  test('invalid PIN and rejected requests preserve credentials', () async {
    var calls = 0;
    final service = AccountService(
      apiService: api,
      httpClient: MockClient((_) async {
        calls++;
        return http.Response('{}', 401);
      }),
    );
    await expectLater(
      service.changePin(currentPin: '1234', newPin: 'bad'),
      throwsA(isA<AccountException>()),
    );
    expect(calls, 0);
    await expectLater(
      service.rotateToken(currentPin: '1234'),
      throwsA(isA<AccountException>()),
    );
    expect((await db.getAccount())!['sync_token'], 'old_secret');
  });

  test(
    'rotation finishes in original profile before queued account switch',
    () async {
      final response = Completer<http.Response>();
      final started = Completer<void>();
      final service = AccountService(
        apiService: api,
        httpClient: MockClient((request) {
          started.complete();
          return response.future;
        }),
      );
      final rotation = service.rotateToken(currentPin: '1234');
      await started.future;
      final switching = api.syncCoordinator.changeAccount(
        account('bob', 'bob_secret'),
      );
      response.complete(
        http.Response(jsonEncode(account('alice', 'fresh_alice')), 200),
      );
      await rotation;
      await switching;
      expect((await db.getAccount())!['user_id'], 'bob');
      expect((await db.getAccount())!['sync_token'], 'bob_secret');
    },
  );

  test('pending login cannot restore an account after logout', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    final service = AccountService(
      apiService: api,
      httpClient: MockClient((request) {
        started.complete();
        return response.future;
      }),
    );
    final login = service.login(username: 'alice', pin: '1234');
    final expected = expectLater(login, throwsA(isA<AccountException>()));
    await started.future;
    await service.logout();
    response.complete(
      http.Response(jsonEncode(account('alice', 'stale_secret')), 200),
    );
    await expected;
    expect(await db.getAccount(), isNull);
  });

  test('device refresh rejects a response after backend changes', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    final service = AccountService(
      apiService: api,
      httpClient: MockClient((request) {
        started.complete();
        return response.future;
      }),
    );
    final refresh = service.refreshDevices();
    final expected = expectLater(refresh, throwsA(isA<AccountException>()));
    await started.future;
    api.setBaseUrl('http://b/api/v1');
    response.complete(http.Response('{"devices":[]}', 200));
    await expected;
  });
}
