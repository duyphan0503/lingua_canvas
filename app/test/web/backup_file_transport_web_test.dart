@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:app/services/backup_file_transport.dart' as platform;
import 'package:app/services/backup_file_transport_web.dart';
import 'package:app/services/backup_file_transport_common.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';

@JS('URL')
external JSObject get _url;

@JS('HTMLAnchorElement.prototype')
external JSObject get _anchorPrototype;

@JS('document')
external JSObject get _document;

@JS('fetch')
external JSPromise<JSObject> _fetch(String url);

void main() {
  for (final oversize in [false, true]) {
    test(
      'web import revokes picker Blob URL after size check: oversize=$oversize',
      () async {
        final file = XFile.fromData(
          oversize
              ? Uint8List(10 * 1024 * 1024 + 1)
              : Uint8List.fromList([123, 125]),
        );
        final originalRevoke = _url.getProperty<JSFunction>(
          'revokeObjectURL'.toJS,
        );
        final revoked = <String>[];
        _url.setProperty(
          'revokeObjectURL'.toJS,
          ((JSString url) {
            revoked.add(url.toDart);
            originalRevoke.callAsFunction(_url, url);
          }).toJS,
        );
        addTearDown(() {
          originalRevoke.callAsFunction(_url, file.path.toJS);
          _url.setProperty('revokeObjectURL'.toJS, originalRevoke);
        });
        final transport = WebBackupFileTransport(pickFile: () async => file);
        if (oversize) {
          await expectLater(
            transport.pickBackup(),
            throwsA(isA<BackupFileTransportException>()),
          );
        } else {
          expect(await transport.pickBackup(), [123, 125]);
        }
        expect(revoked, [file.path]);
      },
    );
  }

  test(
    'web downloads original Blob bytes with a name and revokes its URL',
    () async {
      final originalCreate = _url.getProperty<JSFunction>(
        'createObjectURL'.toJS,
      );
      final originalRevoke = _url.getProperty<JSFunction>(
        'revokeObjectURL'.toJS,
      );
      final originalClick = _anchorPrototype.getProperty<JSFunction>(
        'click'.toJS,
      );
      String? created;
      String? downloadedName;
      String? downloadedUrl;
      final revoked = <String>[];
      final originalAnchorCount = _document
          .callMethod<JSObject>('querySelectorAll'.toJS, 'a[download]'.toJS)
          .getProperty<JSNumber>('length'.toJS)
          .toDartInt;
      _url.setProperty(
        'createObjectURL'.toJS,
        ((JSObject blob) {
          created =
              originalCreate.callAsFunction(_url, blob)!.dartify() as String;
          return created!.toJS;
        }).toJS,
      );
      _url.setProperty(
        'revokeObjectURL'.toJS,
        ((JSString url) {
          revoked.add(url.toDart);
          originalRevoke.callAsFunction(_url, url);
        }).toJS,
      );
      // Prevent a browser download; retain real Blob/URL/document behavior.
      _anchorPrototype.setProperty(
        'click'.toJS,
        (() {
          final anchor = _document.callMethod<JSObject>(
            'querySelector'.toJS,
            'a[download]'.toJS,
          );
          downloadedName = anchor.getProperty<JSString>('download'.toJS).toDart;
          downloadedUrl = anchor.getProperty<JSString>('href'.toJS).toDart;
        }).toJS,
      );
      addTearDown(() {
        _url.setProperty('createObjectURL'.toJS, originalCreate);
        _url.setProperty('revokeObjectURL'.toJS, originalRevoke);
        _anchorPrototype.setProperty('click'.toJS, originalClick);
      });

      final transport = platform.createBackupFileTransport();
      expect(
        await transport.saveBackup(
          Uint8List.fromList([0, 255, 123, 125]),
          suggestedName: 'private-vocabulary.json',
        ),
        isTrue,
      );
      expect(created, startsWith('blob:'));
      expect(downloadedUrl, created);
      expect(downloadedName, 'private-vocabulary.json');
      final response = await _fetch(created!).toDart;
      final buffer = await response
          .callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS)
          .toDart;
      expect(buffer.toDart.asUint8List(), [0, 255, 123, 125]);
      expect(
        _document
            .callMethod<JSObject>('querySelectorAll'.toJS, 'a[download]'.toJS)
            .getProperty<JSNumber>('length'.toJS)
            .toDartInt,
        originalAnchorCount,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(revoked, [created]);
    },
  );

  test(
    'web download error removes the anchor and immediately revokes URL',
    () async {
      final originalCreate = _url.getProperty<JSFunction>(
        'createObjectURL'.toJS,
      );
      final originalRevoke = _url.getProperty<JSFunction>(
        'revokeObjectURL'.toJS,
      );
      final originalClick = _anchorPrototype.getProperty<JSFunction>(
        'click'.toJS,
      );
      String? created;
      final revoked = <String>[];
      _url.setProperty(
        'createObjectURL'.toJS,
        ((JSObject blob) {
          created =
              originalCreate.callAsFunction(_url, blob)!.dartify() as String;
          return created!.toJS;
        }).toJS,
      );
      _url.setProperty(
        'revokeObjectURL'.toJS,
        ((JSString url) {
          revoked.add(url.toDart);
          originalRevoke.callAsFunction(_url, url);
        }).toJS,
      );
      void blockedDownload() => throw StateError('Download blocked');
      _anchorPrototype.setProperty('click'.toJS, blockedDownload.toJS);
      addTearDown(() {
        _url.setProperty('createObjectURL'.toJS, originalCreate);
        _url.setProperty('revokeObjectURL'.toJS, originalRevoke);
        _anchorPrototype.setProperty('click'.toJS, originalClick);
      });

      await expectLater(
        WebBackupFileTransport().saveBackup(
          Uint8List.fromList([123, 125]),
          suggestedName: 'private-vocabulary.json',
        ),
        throwsA(anything),
      );
      expect(created, isNotNull);
      expect(revoked, [created]);
      expect(
        _document.callMethod<JSAny?>('querySelector'.toJS, 'a[download]'.toJS),
        isNull,
      );
    },
  );
}
