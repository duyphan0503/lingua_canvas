import 'dart:convert';
import 'package:app/services/storage/snapshot_persistence.dart';

class MemorySnapshotPersistence implements SnapshotPersistence {
  Map<String, dynamic>? data;
  Object? nextSaveError;
  @override
  Future<Map<String, dynamic>?> load() async => data == null
      ? null
      : Map<String, dynamic>.from(jsonDecode(jsonEncode(data)) as Map);
  @override
  Future<void> save(Map<String, dynamic> snapshot) async {
    final error = nextSaveError;
    nextSaveError = null;
    if (error != null) throw error;
    data = Map<String, dynamic>.from(jsonDecode(jsonEncode(snapshot)) as Map);
  }

  @override
  Future<void> close() async {}
}
