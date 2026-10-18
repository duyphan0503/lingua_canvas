import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'backup_file_transport_common.dart';

class NativeBackupFileTransport extends SelectorBackupFileTransport {
  factory NativeBackupFileTransport({
    bool? isAndroid,
    MethodChannel? channel,
    Future<XFile?> Function()? pickFile,
    Future<FileSaveLocation?> Function(String suggestedName)? pickSaveLocation,
  }) {
    final android = isAndroid ?? Platform.isAndroid;
    final backupChannel =
        channel ?? const MethodChannel('com.linguacanvas.app/backup');
    return NativeBackupFileTransport._(
      pickFile:
          pickFile ??
          (android
              ? () async {
                  final bytes = await backupChannel.invokeMethod<Uint8List>(
                    'pickBackup',
                  );
                  return bytes == null ? null : XFile.fromData(bytes);
                }
              : pickBackupFile),
      saveFile: (bytes, {required suggestedName}) async {
        if (android) {
          final saved = await backupChannel.invokeMethod<bool>('saveBackup', {
            'bytes': bytes,
            'suggestedName': suggestedName,
          });
          if (saved == null) {
            throw const BackupFileTransportException(
              'invalid_result',
              'Không nhận được kết quả lưu tệp sao lưu.',
            );
          }
          return saved;
        }
        final location = await (pickSaveLocation ?? _pickSaveLocation)(
          suggestedName,
        );
        if (location == null) return false;
        await XFile.fromData(
          bytes,
          mimeType: 'application/json',
        ).saveTo(location.path);
        return true;
      },
    );
  }

  NativeBackupFileTransport._({
    required super.pickFile,
    required super.saveFile,
  });
}

Future<FileSaveLocation?> _pickSaveLocation(String suggestedName) =>
    getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: backupFileTypes,
    );

BackupFileTransport createBackupFileTransport() => NativeBackupFileTransport();
