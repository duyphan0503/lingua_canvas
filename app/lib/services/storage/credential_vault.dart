import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Native account secrets are stored outside the learning database.
abstract interface class CredentialVault {
  Future<String?> read(String reference);
  Future<void> write(String reference, String token);
  Future<void> delete(String reference);
}

class NativeCredentialVault implements CredentialVault {
  final FlutterSecureStorage storage;
  const NativeCredentialVault({
    this.storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(resetOnError: false, migrateWithBackup: true),
    ),
  });

  String _key(String reference) => 'lingua_canvas.sync.$reference';

  @override
  Future<String?> read(String reference) => storage.read(key: _key(reference));
  @override
  Future<void> write(String reference, String token) =>
      storage.write(key: _key(reference), value: token);
  @override
  Future<void> delete(String reference) => storage.delete(key: _key(reference));
}

/// Explicit test dependency. Production never falls back to memory storage.
class InMemoryCredentialVault implements CredentialVault {
  final Map<String, String> tokens = {};
  @override
  Future<String?> read(String reference) async => tokens[reference];
  @override
  Future<void> write(String reference, String token) async {
    tokens[reference] = token;
  }

  @override
  Future<void> delete(String reference) async {
    tokens.remove(reference);
  }
}
