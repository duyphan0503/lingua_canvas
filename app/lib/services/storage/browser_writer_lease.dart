import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'snapshot_persistence.dart';

@JS('globalThis')
external JSObject get _global;

/// The pending request promise holds a browser-origin exclusive writer lease.
class BrowserWriterLease {
  final Completer<JSAny?> _released = Completer<JSAny?>();
  Future<void>? _finished;
  BrowserWriterLease._();
  static Future<BrowserWriterLease> acquire({
    String name = 'lingua_canvas_writer',
    JSObject? navigatorForTesting,
  }) async {
    final lease = BrowserWriterLease._();
    final ready = Completer<BrowserWriterLease>();
    try {
      final navigator =
          navigatorForTesting ??
          _global.getProperty<JSObject>('navigator'.toJS);
      final locks = navigator.getProperty<JSAny?>('locks'.toJS);
      if (locks == null) {
        throw const BrowserStorageException(
          'unsupported',
          'Trình duyệt cần HTTPS hoặc localhost và hỗ trợ Web Locks.',
        );
      }
      final callback = ((JSObject? lock) {
        if (lock == null) {
          ready.completeError(
            const BrowserStorageException(
              'busy',
              'Một tab Lingua Canvas khác đang hoạt động. Đóng tab đó rồi thử lại.',
            ),
          );
          return Future<JSAny?>.value(null).toJS;
        }
        ready.complete(lease);
        return lease._released.future.toJS;
      }).toJS;
      final promise = (locks as JSObject).callMethod<JSPromise<JSAny?>>(
        'request'.toJS,
        name.toJS,
        {'mode': 'exclusive', 'ifAvailable': true}.jsify(),
        callback,
      );
      lease._finished = promise.toDart.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (!ready.isCompleted) {
            ready.completeError(
              const BrowserStorageException(
                'unsupported',
                'Không lấy được khóa lưu trữ. Hãy dùng HTTPS hoặc localhost.',
              ),
              stack,
            );
          }
        },
      );
      return await ready.future;
    } on BrowserStorageException {
      rethrow;
    } catch (_) {
      throw const BrowserStorageException(
        'unsupported',
        'Không hỗ trợ khóa lưu trữ trình duyệt.',
      );
    }
  }

  Future<void> release() async {
    if (!_released.isCompleted) {
      _released.complete(null);
    }
    await _finished;
  }
}
