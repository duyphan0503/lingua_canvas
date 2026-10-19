import 'dart:io';

Future<void> deleteLocalRecordingFile(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
}
