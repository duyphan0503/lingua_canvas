import 'dart:async';

import 'package:flutter/material.dart';

import '../services/local_practice_audio.dart';

/// Small local-only recording controls that can sit beside a TTS speaker.
class LocalPracticeAudioControls extends StatefulWidget {
  final LocalPracticeAudio? audio;

  const LocalPracticeAudioControls({super.key, this.audio});

  @override
  State<LocalPracticeAudioControls> createState() =>
      _LocalPracticeAudioControlsState();
}

class _LocalPracticeAudioControlsState
    extends State<LocalPracticeAudioControls> {
  late final LocalPracticeAudio _audio;
  late final bool _ownsAudio;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ownsAudio = widget.audio == null;
    _audio = widget.audio ?? PluginLocalPracticeAudio();
  }

  @override
  void dispose() {
    if (_ownsAudio) unawaited(_audio.dispose());
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Ghi âm và nghe lại trên thiết bị',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 2,
          children: [
            IconButton(
              tooltip: _audio.isRecording ? 'Dừng ghi âm' : 'Ghi âm cục bộ',
              onPressed: _busy
                  ? null
                  : () => _run(_audio.isRecording ? _audio.stop : _audio.start),
              icon: Icon(
                _audio.isRecording
                    ? Icons.stop_circle_outlined
                    : Icons.mic_none,
                size: 19,
              ),
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              tooltip: 'Nghe lại bản ghi',
              onPressed: _busy || !_audio.hasRecording
                  ? null
                  : () => _run(_audio.replay),
              icon: const Icon(Icons.play_arrow_rounded, size: 19),
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              tooltip: 'Xóa bản ghi trên thiết bị',
              onPressed: _busy || !_audio.hasRecording
                  ? null
                  : () => _run(_audio.deleteRecording),
              icon: const Icon(Icons.delete_outline, size: 18),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        if (_audio.hasRecording && !_audio.isRecording)
          const Text(
            'Bản ghi chỉ lưu tạm trên thiết bị.',
            style: TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
          ),
        if (_error != null)
          Text(
            _error!,
            style: const TextStyle(fontSize: 10, color: Color(0xFFFCA5A5)),
          ),
      ],
    ),
  );
}
