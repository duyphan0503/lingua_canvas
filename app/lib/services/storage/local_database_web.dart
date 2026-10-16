import 'dart:js_interop';
import 'browser_local_store.dart';
import 'browser_writer_lease.dart';
import 'indexed_db_persistence.dart';

@JS('location.origin')
external JSString get _origin;

/// Browser facade: no learning screen can write before owning the origin lease.
class LocalDatabase extends BrowserLocalStore {
  static final LocalDatabase instance = LocalDatabase._();
  BrowserWriterLease? _lease;
  Future<void>? _initializing;
  LocalDatabase._()
    : super(
        persistence: IndexedDbSnapshotPersistence(),
        initialBackend: '${_origin.toDart}/api/v1',
      );
  @override
  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      _lease ??= await BrowserWriterLease.acquire();
      await super.initialize();
    } catch (_) {
      await _lease?.release();
      _lease = null;
      _initializing = null;
      await persistence.close();
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    try {
      await super.close();
    } finally {
      await _lease?.release();
      _lease = null;
      _initializing = null;
    }
  }
}
