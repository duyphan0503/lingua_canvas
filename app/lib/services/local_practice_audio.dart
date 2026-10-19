import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'local_recording_cleanup_stub.dart'
    if (dart.library.io) 'local_recording_cleanup_io.dart';
import 'local_recording_source_stub.dart'
    if (dart.library.io) 'local_recording_source_io.dart'
    if (dart.library.js_interop) 'local_recording_source_web.dart';

abstract interface class LocalPracticeAudio {
  bool get isRecording;
  bool get hasRecording;
  Future<void> start();
  Future<void> stop();
  Future<void> replay();
  Future<void> deleteRecording();
  Future<void> dispose();
}

class LocalPracticeAudioException implements Exception {
  final String message;
  const LocalPracticeAudioException(this.message);
  @override
  String toString() => message;
}

/// Captures and plays a temporary local clip. It never uploads audio.
class PluginLocalPracticeAudio implements LocalPracticeAudio {
  AudioRecorder? _recorder;
  AudioPlayer? _player;
  String? _path;
  bool _recording = false;

  PluginLocalPracticeAudio({AudioRecorder? recorder, AudioPlayer? player})
    : _recorder = recorder,
      _player = player;

  @override
  bool get isRecording => _recording;
  @override
  bool get hasRecording => _path != null;

  @override
  Future<void> start() async {
    final recorder = _recorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) {
      throw const LocalPracticeAudioException(
        'Cần cấp quyền microphone để ghi âm.',
      );
    }
    await deleteRecording();
    final name = 'lingua-practice-${DateTime.now().microsecondsSinceEpoch}.wav';
    final destination = kIsWeb
        ? name
        : path.join((await getTemporaryDirectory()).path, name);
    await recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav),
      path: destination,
    );
    _recording = true;
  }

  @override
  Future<void> stop() async {
    if (!_recording) return;
    final recordedPath = await _recorder?.stop();
    _recording = false;
    if (recordedPath == null || recordedPath.isEmpty) {
      throw const LocalPracticeAudioException('Không lưu được bản ghi âm.');
    }
    _path = recordedPath;
  }

  @override
  Future<void> replay() async {
    final recordedPath = _path;
    if (recordedPath == null) return;
    final player = _player ??= AudioPlayer();
    await player.play(localRecordingSource(recordedPath));
  }

  @override
  Future<void> deleteRecording() async {
    if (_recording) {
      await _recorder?.cancel();
      _recording = false;
    }
    await _player?.stop();
    final recordedPath = _path;
    _path = null;
    if (recordedPath != null && !kIsWeb) {
      await deleteLocalRecordingFile(recordedPath);
    }
  }

  @override
  Future<void> dispose() async {
    await deleteRecording();
    await _player?.dispose();
    _player = null;
    await _recorder?.dispose();
    _recorder = null;
  }
}
