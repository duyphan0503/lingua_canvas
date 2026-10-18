class BrowserStorageException implements Exception {
  final String code;
  final String message;
  const BrowserStorageException(this.code, this.message);
  @override
  String toString() => message;
}

abstract interface class SnapshotPersistence {
  Future<Map<String, dynamic>?> load();
  Future<void> save(Map<String, dynamic> snapshot);
  Future<void> close();
}
