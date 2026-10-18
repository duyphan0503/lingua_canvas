import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

abstract interface class BackupFileTransport {
  /// Returns raw bytes, or null when the user cancels the picker.
  Future<Uint8List?> pickBackup();

  /// Returns false only when the user cancels the save dialog.
  Future<bool> saveBackup(Uint8List bytes, {required String suggestedName});
}

const maxBackupFileBytes = 10 * 1024 * 1024;

const backupFileTypes = <XTypeGroup>[
  XTypeGroup(
    label: 'JSON backup',
    extensions: ['json'],
    mimeTypes: ['application/json'],
    uniformTypeIdentifiers: ['public.json'],
  ),
];

Future<XFile?> pickBackupFile() =>
    openFile(acceptedTypeGroups: backupFileTypes);

class BackupFileTransportException implements Exception {
  const BackupFileTransportException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

typedef BackupFileSaver =
    Future<bool> Function(Uint8List bytes, {required String suggestedName});

class SelectorBackupFileTransport implements BackupFileTransport {
  SelectorBackupFileTransport({
    Future<XFile?> Function()? pickFile,
    required BackupFileSaver saveFile,
    void Function(XFile file)? releaseFile,
  }) : _pickFile = pickFile ?? pickBackupFile,
       _saveFile = saveFile,
       _releaseFile = releaseFile;

  final Future<XFile?> Function() _pickFile;
  final BackupFileSaver _saveFile;
  final void Function(XFile file)? _releaseFile;
  bool _pending = false;

  @override
  Future<Uint8List?> pickBackup() => _withPending(() async {
    final file = await _pickFile();
    if (file == null) return null;
    try {
      _checkSize(await file.length());
      final bytes = BytesBuilder(copy: false);
      // Do not use readAsBytes: a native file may grow after the metadata check.
      // await-for also cancels the subscription when the limit/read check throws.
      await for (final chunk in file.openRead()) {
        _checkSize(bytes.length + chunk.length);
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      _releaseFile?.call(file);
    }
  });

  @override
  Future<bool> saveBackup(Uint8List bytes, {required String suggestedName}) =>
      _withPending(() async {
        _checkSize(bytes.length);
        return _saveFile(bytes, suggestedName: suggestedName);
      });

  Future<T> _withPending<T>(Future<T> Function() operation) async {
    if (_pending) {
      throw const BackupFileTransportException(
        'busy',
        'Một thao tác tệp sao lưu đang chờ hoàn tất.',
      );
    }
    _pending = true;
    try {
      return await operation();
    } finally {
      _pending = false;
    }
  }

  static void _checkSize(int size) {
    if (size > maxBackupFileBytes || size < 0) {
      throw const BackupFileTransportException(
        'too_large',
        'Tệp sao lưu phải nhỏ hơn hoặc bằng 10 MiB.',
      );
    }
  }
}
