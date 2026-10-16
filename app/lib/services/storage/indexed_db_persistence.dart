import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'snapshot_persistence.dart';

@JS('globalThis')
external JSObject get _global;

/// Two object stores committed in one transaction; request success is not commit.
class IndexedDbSnapshotPersistence implements SnapshotPersistence {
  final String databaseName;
  final JSObject? _factoryForTesting;
  bool abortNextSaveForTesting = false;
  JSObject? _db;
  Future<JSObject>? _opening;
  int _generation = 0;
  IndexedDbSnapshotPersistence({
    this.databaseName = 'lingua_canvas_web',
    JSObject? factoryForTesting,
  }) : _factoryForTesting = factoryForTesting;
  static Future<IndexedDbSnapshotPersistence> open({
    String databaseName = 'lingua_canvas_web',
  }) async {
    final result = IndexedDbSnapshotPersistence(databaseName: databaseName);
    await result._connection();
    return result;
  }

  Future<JSObject> _connection() {
    return _opening ??= _open();
  }

  Future<JSObject> _open() async {
    final result = Completer<JSObject>();
    Timer? timer;
    final generation = _generation;
    try {
      final factory =
          _factoryForTesting ?? _global.getProperty<JSAny?>('indexedDB'.toJS);
      if (factory == null) {
        throw const BrowserStorageException(
          'unsupported',
          'Trình duyệt không hỗ trợ lưu dữ liệu bền vững IndexedDB.',
        );
      }
      final request = (factory as JSObject).callMethod<JSObject>(
        'open'.toJS,
        databaseName.toJS,
        1.toJS,
      );
      request.setProperty(
        'onupgradeneeded'.toJS,
        ((JSAny? event) {
          final db = request.getProperty<JSObject>('result'.toJS);
          db.callMethod<JSAny?>('createObjectStore'.toJS, 'metadata'.toJS);
          db.callMethod<JSAny?>('createObjectStore'.toJS, 'profiles'.toJS);
        }).toJS,
      );
      request.setProperty(
        'onsuccess'.toJS,
        ((JSAny? event) {
          final db = request.getProperty<JSObject>('result'.toJS);
          if (result.isCompleted || generation != _generation) {
            db.callMethod<JSAny?>('close'.toJS);
            if (!result.isCompleted) {
              result.completeError(
                const BrowserStorageException(
                  'closed',
                  'Kho dữ liệu đã đóng. Hãy thử lại.',
                ),
              );
            }
            return;
          }
          _db = db;
          db.setProperty(
            'onversionchange'.toJS,
            ((JSAny? event) {
              db.callMethod<JSAny?>('close'.toJS);
              _db = null;
              _opening = null;
            }).toJS,
          );
          result.complete(db);
        }).toJS,
      );
      request.setProperty(
        'onerror'.toJS,
        ((JSAny? event) {
          if (!result.isCompleted) {
            result.completeError(_error(request));
          }
        }).toJS,
      );
      request.setProperty(
        'onblocked'.toJS,
        ((JSAny? event) {
          if (!result.isCompleted) {
            result.completeError(
              const BrowserStorageException(
                'blocked',
                'Một tab cũ đang giữ dữ liệu. Đóng tab đó rồi thử lại.',
              ),
            );
          }
        }).toJS,
      );
      timer = Timer(const Duration(seconds: 5), () {
        if (!result.isCompleted) {
          result.completeError(
            const BrowserStorageException(
              'blocked',
              'Mở kho dữ liệu quá thời gian. Đóng các tab cũ rồi thử lại.',
            ),
          );
        }
      });
      return await result.future;
    } on BrowserStorageException {
      _opening = null;
      rethrow;
    } catch (_) {
      _opening = null;
      throw const BrowserStorageException(
        'unsupported',
        'Không mở được IndexedDB. Kiểm tra quyền lưu trữ trình duyệt.',
      );
    } finally {
      timer?.cancel();
    }
  }

  static BrowserStorageException _error(JSObject object) {
    final error = object.getProperty<JSAny?>('error'.toJS);
    final name = error == null
        ? ''
        : (error as JSObject)
                  .getProperty<JSAny?>('name'.toJS)
                  ?.dartify()
                  ?.toString() ??
              '';
    return BrowserStorageException(
      name == 'QuotaExceededError' ? 'quota' : 'transaction',
      name == 'QuotaExceededError'
          ? 'Bộ nhớ trình duyệt đã đầy. Tiến độ chưa được lưu.'
          : 'Giao dịch lưu trữ thất bại. Tiến độ chưa được lưu.',
    );
  }

  static Future<JSAny?> _request(JSObject request) {
    final result = Completer<JSAny?>();
    request.setProperty(
      'onsuccess'.toJS,
      ((JSAny? event) {
        if (!result.isCompleted) {
          result.complete(request.getProperty<JSAny?>('result'.toJS));
        }
      }).toJS,
    );
    request.setProperty(
      'onerror'.toJS,
      ((JSAny? event) {
        if (!result.isCompleted) {
          result.completeError(_error(request));
        }
      }).toJS,
    );
    return result.future;
  }

  static Future<void> _committed(JSObject tx) {
    final result = Completer<void>();
    tx.setProperty(
      'oncomplete'.toJS,
      ((JSAny? event) {
        if (!result.isCompleted) {
          result.complete();
        }
      }).toJS,
    );
    final failed = ((JSAny? event) {
      if (!result.isCompleted) {
        result.completeError(_error(tx));
      }
    }).toJS;
    tx.setProperty('onabort'.toJS, failed);
    tx.setProperty('onerror'.toJS, failed);
    return result.future;
  }

  @override
  Future<Map<String, dynamic>?> load() async {
    final db = await _connection();
    final tx = db.callMethod<JSObject>(
      'transaction'.toJS,
      ['metadata', 'profiles'].jsify(),
      'readonly'.toJS,
    );
    final committed = _committed(tx);
    final metadata = tx.callMethod<JSObject>(
      'objectStore'.toJS,
      'metadata'.toJS,
    );
    final profiles = tx.callMethod<JSObject>(
      'objectStore'.toJS,
      'profiles'.toJS,
    );
    final requests = [
      _request(metadata.callMethod<JSObject>('get'.toJS, 'root'.toJS)),
      _request(profiles.callMethod<JSObject>('getAllKeys'.toJS)),
      _request(profiles.callMethod<JSObject>('getAll'.toJS)),
    ];
    // Attach error handling to the transaction at once, including request failures.
    final outputs = await Future.wait<Object?>([
      Future.wait(requests),
      committed,
    ]);
    final values = outputs.first as List<JSAny?>;
    final keys = (values[1] as JSArray<JSAny?>).toDart;
    final rows = (values[2] as JSArray<JSAny?>).toDart;
    if (values[0] == null) {
      if (rows.isNotEmpty) {
        throw const BrowserStorageException(
          'corrupt',
          'Thiếu thông tin kho dữ liệu. Dữ liệu cũ vẫn được giữ.',
        );
      }
      return null;
    }
    try {
      final root = Map<String, dynamic>.from(
        jsonDecode((values[0] as JSString).toDart) as Map,
      );
      root['profiles'] = {
        for (var i = 0; i < keys.length; i++)
          (keys[i] as JSString).toDart: jsonDecode(
            (rows[i] as JSString).toDart,
          ),
      };
      return root;
    } catch (_) {
      throw const BrowserStorageException(
        'corrupt',
        'Không đọc được dữ liệu đã lưu. Chưa xóa dữ liệu.',
      );
    }
  }

  @override
  Future<void> save(Map<String, dynamic> snapshot) async {
    final root = Map<String, dynamic>.from(snapshot);
    final profiles = root.remove('profiles') as Map<String, dynamic>;
    final encoded = jsonEncode(root);
    final entries = {
      for (final entry in profiles.entries) entry.key: jsonEncode(entry.value),
    };
    final db = await _connection();
    final tx = db.callMethod<JSObject>(
      'transaction'.toJS,
      ['metadata', 'profiles'].jsify(),
      'readwrite'.toJS,
    );
    final committed = _committed(tx);
    final meta = tx.callMethod<JSObject>('objectStore'.toJS, 'metadata'.toJS);
    final store = tx.callMethod<JSObject>('objectStore'.toJS, 'profiles'.toJS);
    meta.callMethod<JSAny?>('put'.toJS, encoded.toJS, 'root'.toJS);
    store.callMethod<JSAny?>('clear'.toJS);
    for (final entry in entries.entries) {
      store.callMethod<JSAny?>('put'.toJS, entry.value.toJS, entry.key.toJS);
    }
    if (abortNextSaveForTesting) {
      abortNextSaveForTesting = false;
      tx.callMethod<JSAny?>('abort'.toJS);
    }
    await committed;
  }

  @override
  Future<void> close() async {
    _generation++;
    _opening = null;
    _db?.callMethod<JSAny?>('close'.toJS);
    _db = null;
  }
}
