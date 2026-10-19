import 'dart:convert';
import 'package:app/services/storage/credential_vault.dart';
import 'package:app/services/storage/local_database_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> account(
  String user,
  String token, {
  String server = 'http://a/api/v1',
}) => {
  'user_id': user,
  'username': user,
  'display_name': user,
  'server_url': server,
  'sync_token': token,
  'devices': <Map<String, dynamic>>[],
};

class FailingVault extends InMemoryCredentialVault {
  bool fail = false;
  bool failReadBack = false;
  @override
  Future<String?> read(String reference) async =>
      failReadBack ? null : super.read(reference);
  @override
  Future<void> write(String reference, String token) async {
    if (fail) throw StateError('vault unavailable');
    return super.write(reference, token);
  }
}

void main() {
  late LocalDatabase store;
  late FailingVault vault;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    store = LocalDatabase.instance;
    vault = FailingVault();
    await store.initCustom(
      customPath: inMemoryDatabasePath,
      credentialVault: vault,
    );
  });
  tearDown(() => store.close());

  test(
    'new native accounts keep tokens solely in the injected vault',
    () async {
      await store.switchAccount(account('alice', 'secret_alice'));
      expect((await store.getAccount())!['sync_token'], 'secret_alice');
      final db = await store.database;
      expect(
        jsonEncode(await db.query('local_sync_metadata')),
        isNot(contains('secret_alice')),
      );
      expect(
        jsonEncode(await db.query('local_profile_snapshots')),
        isNot(contains('secret_alice')),
      );
      expect(vault.tokens.values, contains('secret_alice'));
      await store.selectBackend('http://b/api/v1');
      await store.switchAccount(
        account('bob', 'secret_bob', server: 'http://b/api/v1'),
      );
      await store.selectBackend('http://a/api/v1');
      expect((await store.getAccount())!['sync_token'], 'secret_alice');
    },
  );

  test('vault failure leaves current account and progress intact', () async {
    await store.switchAccount(account('alice', 'secret_alice'));
    await store.saveCompletedLesson('lesson_a');
    vault.fail = true;
    await expectLater(
      store.switchAccount(account('bob', 'secret_bob')),
      throwsStateError,
    );
    expect((await store.getAccount())!['user_id'], 'alice');
    expect((await store.getAccount())!['sync_token'], 'secret_alice');
    expect(await store.getCompletedCount(), 1);
  });

  test(
    'migration scrubs active and archived accounts only after vault success',
    () async {
      final db = await store.database;
      final alice = account('alice', 'legacy_alice');
      final bob = account('bob', 'legacy_bob', server: 'http://b/api/v1');
      await db.insert('local_sync_metadata', {
        'key': 'account',
        'value': jsonEncode(alice),
      });
      await db.insert('local_sync_metadata', {
        'key': '__active_accounts',
        'value': jsonEncode({'http://a/api/v1': alice, 'http://b/api/v1': bob}),
      });
      await db.insert('local_profile_snapshots', {
        'profile_key': jsonEncode(['http://b/api/v1', 'bob']),
        'payload': jsonEncode({
          'metadata': [
            {'key': 'account', 'value': jsonEncode(bob)},
            {
              'key': '__active_accounts',
              'value': jsonEncode({'http://a/api/v1': alice}),
            },
          ],
        }),
      });
      await store.saveCompletedLesson('lesson_a');
      // Reopen initialization against the existing database, as on app upgrade.
      vault.fail = true;
      await expectLater(
        store.initCustom(customDb: db, credentialVault: vault),
        throwsStateError,
      );
      expect(
        jsonEncode(await db.query('local_sync_metadata')),
        contains('legacy_alice'),
      );
      expect(
        jsonEncode(await db.query('local_profile_snapshots')),
        contains('legacy_bob'),
      );
      vault.fail = false;
      await store.initCustom(customDb: db, credentialVault: vault);
      final stored = jsonEncode([
        await db.query('local_sync_metadata'),
        await db.query('local_profile_snapshots'),
      ]);
      expect(stored, isNot(contains('legacy_alice')));
      expect(stored, isNot(contains('legacy_bob')));
      expect((await store.getAccount())!['sync_token'], 'legacy_alice');
      expect(await store.getCompletedCount(), 1);
      await store.selectBackend('http://b/api/v1');
      expect((await store.getAccount())!['sync_token'], 'legacy_bob');
    },
  );

  test('SQL migration rollback keeps original token recoverable', () async {
    final db = await store.database;
    await db.insert('local_sync_metadata', {
      'key': 'account',
      'value': jsonEncode(account('alice', 'legacy_secret')),
    });
    await db.execute(
      "CREATE TRIGGER fail_credential_migration BEFORE UPDATE ON local_sync_metadata BEGIN SELECT RAISE(ABORT, 'quota'); END",
    );
    await expectLater(
      store.initCustom(customDb: db, credentialVault: vault),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      jsonEncode(await db.query('local_sync_metadata')),
      contains('legacy_secret'),
    );
    await db.execute('DROP TRIGGER fail_credential_migration');
    await store.initCustom(customDb: db, credentialVault: vault);
    expect((await store.getAccount())!['sync_token'], 'legacy_secret');
    expect(
      jsonEncode(await db.query('local_sync_metadata')),
      isNot(contains('legacy_secret')),
    );
  });

  test('migration verifies vault readback before deleting plaintext', () async {
    final db = await store.database;
    await db.insert('local_sync_metadata', {
      'key': 'account',
      'value': jsonEncode(account('alice', 'legacy_secret')),
    });
    vault.failReadBack = true;
    await expectLater(
      store.initCustom(customDb: db, credentialVault: vault),
      throwsStateError,
    );
    expect(
      jsonEncode(await db.query('local_sync_metadata')),
      contains('legacy_secret'),
    );
    vault.failReadBack = false;
    await store.initCustom(customDb: db, credentialVault: vault);
    expect((await store.getAccount())!['sync_token'], 'legacy_secret');
  });
}
