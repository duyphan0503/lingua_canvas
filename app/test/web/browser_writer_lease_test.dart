@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'dart:js_interop';
import 'package:app/services/storage/browser_writer_lease.dart';
import 'package:app/services/storage/snapshot_persistence.dart';

void main() {
  test('missing lock API is a visible unsupported state', () async {
    await expectLater(
      BrowserWriterLease.acquire(navigatorForTesting: JSObject()),
      throwsA(
        isA<BrowserStorageException>().having(
          (e) => e.code,
          'code',
          'unsupported',
        ),
      ),
    );
  });
  test(
    'one origin writer at a time and ownership recovers after release',
    () async {
      final name = 'lingua_lease_${DateTime.now().microsecondsSinceEpoch}';
      final first = await BrowserWriterLease.acquire(name: name);
      await expectLater(
        BrowserWriterLease.acquire(name: name),
        throwsA(
          isA<BrowserStorageException>().having((e) => e.code, 'code', 'busy'),
        ),
      );
      await first.release();
      final next = await BrowserWriterLease.acquire(name: name);
      await next.release();
      await next.release();
    },
  );
}
