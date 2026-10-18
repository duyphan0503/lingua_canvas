import 'dart:async';
import 'dart:io';

import 'package:app/services/backup_file_transport_common.dart';
import 'package:app/services/backup_file_transport_native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SelectorBackupFileTransport transportFor(XFile? file) =>
      SelectorBackupFileTransport(
        pickFile: () async => file,
        saveFile: (bytes, {required suggestedName}) async => true,
      );

  test('picker cancellation returns null', () async {
    expect(await transportFor(null).pickBackup(), isNull);
  });

  test('reads a selected backup as original bytes without decoding', () async {
    expect(
      await transportFor(
        XFile.fromData(Uint8List.fromList([0, 255, 123, 125])),
      ).pickBackup(),
      [0, 255, 123, 125],
    );
  });

  test('rejects over 10 MiB from metadata before opening a stream', () async {
    final file = _TrackedFile(10 * 1024 * 1024 + 1, const []);
    await expectLater(
      transportFor(file).pickBackup(),
      throwsA(_hasCode('too_large')),
    );
    expect(file.streamOpened, isFalse);
  });

  test('accepts the 10 MiB boundary', () async {
    final bytes = Uint8List(10 * 1024 * 1024);
    final actual = await transportFor(XFile.fromData(bytes)).pickBackup();
    expect(actual!.length, 10 * 1024 * 1024);
  });

  test(
    'stream growth beyond declared length rejects and cancels read',
    () async {
      var cancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final file = _TrackedFile(1, const [], stream: stream.stream);
      final reading = transportFor(file).pickBackup();
      final failure = expectLater(reading, throwsA(_hasCode('too_large')));
      stream.add(Uint8List(10 * 1024 * 1024));
      stream.add([1]);
      await failure;
      expect(cancelled, isTrue);
      await stream.close();
    },
  );

  test(
    'read failure stays visible and releases the pending operation',
    () async {
      var calls = 0;
      final transport = SelectorBackupFileTransport(
        pickFile: () async {
          if (++calls == 1) throw const FileSystemException('Cannot open');
          return null;
        },
        saveFile: (bytes, {required suggestedName}) async => true,
      );
      await expectLater(
        transport.pickBackup(),
        throwsA(isA<FileSystemException>()),
      );
      expect(await transport.pickBackup(), isNull);
    },
  );

  test(
    'stream read errors propagate without returning truncated bytes',
    () async {
      final file = _TrackedFile(
        2,
        const [],
        stream: Stream<List<int>>.error(
          const FileSystemException('Read failed'),
        ),
      );
      await expectLater(
        transportFor(file).pickBackup(),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'pending picker rejects another pick or save then permits retry',
    () async {
      final picked = Completer<XFile?>();
      final transport = SelectorBackupFileTransport(
        pickFile: () => picked.future,
        saveFile: (bytes, {required suggestedName}) async => true,
      );
      final first = transport.pickBackup();
      await expectLater(transport.pickBackup(), throwsA(_hasCode('busy')));
      await expectLater(
        transport.saveBackup(Uint8List(1), suggestedName: 'backup.json'),
        throwsA(_hasCode('busy')),
      );
      picked.complete(null);
      expect(await first, isNull);
      expect(
        await transport.saveBackup(Uint8List(1), suggestedName: 'backup.json'),
        isTrue,
      );
    },
  );

  test('oversize export rejects before invoking a save dialog', () async {
    var dialogOpened = false;
    final transport = SelectorBackupFileTransport(
      saveFile: (bytes, {required suggestedName}) async {
        dialogOpened = true;
        return true;
      },
    );
    await expectLater(
      transport.saveBackup(
        Uint8List(10 * 1024 * 1024 + 1),
        suggestedName: 'backup.json',
      ),
      throwsA(_hasCode('too_large')),
    );
    expect(dialogOpened, isFalse);
  });

  test(
    'Linux save cancellation returns false without creating a file',
    () async {
      final transport = NativeBackupFileTransport(
        isAndroid: false,
        pickSaveLocation: (name) async => null,
      );
      expect(
        await transport.saveBackup(Uint8List(1), suggestedName: 'backup.json'),
        isFalse,
      );
    },
  );

  test('Linux writes exact backup bytes to the chosen location', () async {
    final directory = await Directory.systemTemp.createTemp(
      'backup-transport-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/selected.json');
    final transport = NativeBackupFileTransport(
      isAndroid: false,
      pickSaveLocation: (name) async {
        expect(name, 'suggested.json');
        return FileSaveLocation(file.path);
      },
    );
    expect(
      await transport.saveBackup(
        Uint8List.fromList([123, 34, 255, 125]),
        suggestedName: 'suggested.json',
      ),
      isTrue,
    );
    expect(await file.readAsBytes(), [123, 34, 255, 125]);
  });

  test(
    'Linux write failure remains an error instead of a cancellation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'backup-transport-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final transport = NativeBackupFileTransport(
        isAndroid: false,
        pickSaveLocation: (name) async =>
            FileSaveLocation('${directory.path}/missing/backup.json'),
      );
      await expectLater(
        transport.saveBackup(Uint8List(1), suggestedName: 'backup.json'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  group('Android SAF channel', () {
    const channel = MethodChannel('com.linguacanvas.app/backup');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('imports through the bounded Android document channel', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pickBackup');
        expect(call.arguments, isNull);
        return Uint8List.fromList([0, 255, 123, 125]);
      });
      expect(await NativeBackupFileTransport(isAndroid: true).pickBackup(), [
        0,
        255,
        123,
        125,
      ]);
    });

    test(
      'import cancellation returns null and permits the next operation',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async => null);
        expect(
          await NativeBackupFileTransport(isAndroid: true).pickBackup(),
          isNull,
        );
      },
    );

    test(
      'native import limit error remains visible and permits retry',
      () async {
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (++calls == 1) {
            throw PlatformException(code: 'too_large', message: 'Over 10 MiB');
          }
          return Uint8List.fromList([123, 125]);
        });
        final transport = NativeBackupFileTransport(isAndroid: true);
        await expectLater(
          transport.pickBackup(),
          throwsA(
            isA<PlatformException>().having((e) => e.code, 'code', 'too_large'),
          ),
        );
        expect(await transport.pickBackup(), [123, 125]);
      },
    );

    test('sends bytes and suggested name through the backup channel', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'saveBackup');
        expect(call.arguments, {
          'bytes': Uint8List.fromList([123, 125]),
          'suggestedName': 'personal.json',
        });
        return true;
      });
      final transport = NativeBackupFileTransport(isAndroid: true);
      expect(
        await transport.saveBackup(
          Uint8List.fromList([123, 125]),
          suggestedName: 'personal.json',
        ),
        isTrue,
      );
    });

    test(
      'document cancellation returns false and a subsequent save works',
      () async {
        var calls = 0;
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => ++calls > 1,
        );
        final transport = NativeBackupFileTransport(isAndroid: true);
        expect(
          await transport.saveBackup(
            Uint8List(1),
            suggestedName: 'backup.json',
          ),
          isFalse,
        );
        expect(
          await transport.saveBackup(
            Uint8List(1),
            suggestedName: 'backup.json',
          ),
          isTrue,
        );
      },
    );

    test(
      'native write failure propagates and the operation can be retried',
      () async {
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (++calls == 1) {
            throw PlatformException(code: 'write_failed', message: 'No space');
          }
          return true;
        });
        final transport = NativeBackupFileTransport(isAndroid: true);
        await expectLater(
          transport.saveBackup(Uint8List(1), suggestedName: 'backup.json'),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'write_failed',
            ),
          ),
        );
        expect(
          await transport.saveBackup(
            Uint8List(1),
            suggestedName: 'backup.json',
          ),
          isTrue,
        );
      },
    );

    test(
      'an absent native result is an error, not user cancellation',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async => null);
        await expectLater(
          NativeBackupFileTransport(
            isAndroid: true,
          ).saveBackup(Uint8List(1), suggestedName: 'backup.json'),
          throwsA(_hasCode('invalid_result')),
        );
      },
    );
  });
}

Matcher _hasCode(String code) => isA<BackupFileTransportException>().having(
  (error) => error.code,
  'code',
  code,
);

class _TrackedFile extends XFile {
  _TrackedFile(this.declaredLength, this.chunks, {this.stream})
    : super.fromData(Uint8List(0));

  final int declaredLength;
  final List<List<int>> chunks;
  final Stream<List<int>>? stream;
  bool streamOpened = false;

  @override
  Future<int> length() async => declaredLength;

  @override
  Stream<Uint8List> openRead([int? start, int? end]) {
    streamOpened = true;
    return (stream ?? Stream.fromIterable(chunks)).map(Uint8List.fromList);
  }
}
