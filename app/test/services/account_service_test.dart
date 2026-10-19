import 'package:app/services/storage/credential_vault.dart';
import 'dart:convert';
import 'package:app/services/account_service.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final testCredentialVault = InMemoryCredentialVault();

Map<String, dynamic> accountPayload() => {
  'user_id': 'usr_alice',
  'username': 'alice',
  'display_name': 'Alice',
  'sync_token': 'lct_secret',
  'devices': [
    {
      'device_id': 'device_a',
      'device_name': 'Linux Desktop',
      'platform': 'linux',
      'last_sync_seq': 3,
      'last_seen_at': '2026-10-14T00:00:00Z',
    },
  ],
};
void main() {
  late LocalDatabase db;
  late ApiService api;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = LocalDatabase.instance;
    await db.initCustom(
      credentialVault: testCredentialVault,
      customPath: inMemoryDatabasePath,
    );
    api = ApiService(localDb: db, baseUrl: 'http://test/api/v1');
  });
  tearDown(() => db.close());
  test(
    'registration persists account and stable device identity without PIN',
    () async {
      final service = AccountService(
        apiService: api,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/auth/register');
          expect(request.followRedirects, isFalse);
          final body = jsonDecode(request.body);
          expect(body['device_id'], await db.getOrCreateClientId());
          expect(body['platform'], 'linux');
          expect(body['pin'], '1234');
          return http.Response(jsonEncode(accountPayload()), 201);
        }),
      );
      await service.register(
        username: 'alice',
        pin: '1234',
        displayName: 'Alice',
      );
      final stored = await db.getAccount();
      expect(stored!['sync_token'], 'lct_secret');
      expect(stored['server_url'], api.baseUrl);
      expect(stored.containsKey('pin'), isFalse);
      expect((await service.currentHeaders())['X-Sync-Token'], 'lct_secret');
      await service.logout();
      expect(await db.getAccount(), isNull);
    },
  );
  test(
    'token linking and refreshing devices authenticate and persist metadata',
    () async {
      final service = AccountService(
        apiService: api,
        httpClient: MockClient((request) async {
          expect(request.followRedirects, isFalse);
          if (request.method == 'POST') {
            expect(jsonDecode(request.body)['sync_token'], 'lct_secret');
            return http.Response(jsonEncode(accountPayload()), 200);
          }
          expect(request.headers['X-Sync-Token'], 'lct_secret');
          return http.Response(
            jsonEncode({'devices': accountPayload()['devices']}),
            200,
          );
        }),
      );
      await service.login(syncToken: 'lct_secret');
      expect((await service.refreshDevices()).length, 1);
      api.setBaseUrl('http://another/api/v1');
      expect(await service.currentHeaders(), isEmpty);
      await expectLater(
        service.refreshDevices(),
        throwsA(isA<AccountException>()),
      );
      await service.logout();
      expect(await db.getAccount(), isNull);
    },
  );
  test(
    'invalid credentials, status and malformed server payload leave local profile intact',
    () async {
      var calls = 0;
      final service = AccountService(
        apiService: api,
        httpClient: MockClient((request) async {
          calls++;
          return http.Response('{"user_id":"bad"}', calls == 1 ? 401 : 200);
        }),
      );
      await expectLater(
        service.register(username: 'a', pin: '12'),
        throwsA(isA<AccountException>()),
      );
      await expectLater(
        service.login(syncToken: 'bad\nheader'),
        throwsA(isA<AccountException>()),
      );
      expect(calls, 0);
      await expectLater(
        service.login(username: 'alice', pin: '1234'),
        throwsA(isA<AccountException>()),
      );
      await expectLater(
        service.login(username: 'alice', pin: '1234'),
        throwsA(isA<AccountException>()),
      );
      expect(await db.getAccount(), isNull);
    },
  );
  test(
    'AI requests use same-server account header and never leak it after URL change',
    () async {
      await api.syncCoordinator.changeAccount({
        ...accountPayload(),
        'server_url': api.baseUrl,
      });
      final requests = <http.Request>[];
      await http.runWithClient(
        () async {
          await api.sendRoleplayMessage(
            targetLanguage: 'ja',
            topic: 'work',
            message: 'Hi',
          );
          await api.generateDialogue(targetLanguage: 'ja', topic: 'work');
          api.setBaseUrl('http://another/api/v1');
          await api.sendRoleplayMessage(
            targetLanguage: 'ja',
            topic: 'work',
            message: 'Hi',
          );
        },
        () => MockClient((request) async {
          requests.add(request);
          return http.Response('{"reply":"ok","lines":[]}', 200);
        }),
      );
      expect(requests.length, 3);
      for (final request in requests) {
        expect(
          request.headers['X-Sync-Token'],
          request.url.host == 'test' ? 'lct_secret' : isNull,
        );
        expect(request.followRedirects, isFalse);
      }
    },
  );
}
