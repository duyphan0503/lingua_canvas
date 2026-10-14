import 'dart:async';
import 'package:flutter/material.dart';
import '../services/tts_service.dart';

/// Interactive audio speaker button that pronounces text using [TtsService].
class TtsSpeakerButton extends StatefulWidget {
  final String text;
  final String language;
  final double iconSize;
  final Color? color;
  final Color? activeColor;
  final EdgeInsetsGeometry padding;
  final BoxConstraints? constraints;
  final VisualDensity visualDensity;
  final String? tooltip;
  final TtsService? ttsService;

  const TtsSpeakerButton({
    super.key,
    required this.text,
    required this.language,
    this.iconSize = 20,
    this.color,
    this.activeColor,
    this.padding = const EdgeInsets.all(4),
    this.constraints,
    this.visualDensity = VisualDensity.compact,
    this.tooltip,
    this.ttsService,
  });

  @override
  State<TtsSpeakerButton> createState() => _TtsSpeakerButtonState();
}

class _TtsSpeakerButtonState extends State<TtsSpeakerButton> {
  bool _isPlaying = false;
  bool _ownsPlayback = false;
  StreamSubscription<TTSState>? _subscription;

  TtsService get _service => widget.ttsService ?? TtsService.defaultInstance;

  @override
  void initState() {
    super.initState();
    _listenToPlayback();
  }

  @override
  void didUpdateWidget(covariant TtsSpeakerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ttsService != widget.ttsService) {
      _subscription?.cancel();
      _ownsPlayback = false;
      _isPlaying = false;
      _listenToPlayback();
    }
  }

  void _listenToPlayback() {
    _subscription = _service.stateStream.listen((state) {
      if (!mounted || !_ownsPlayback) return;
      setState(() => _isPlaying = state == TTSState.speaking);
      if (state == TTSState.error) _showPlaybackError();
      if (state != TTSState.speaking) _ownsPlayback = false;
    });
  }

  void _showPlaybackError() {
    if (!_ownsPlayback || !mounted) return;
    _ownsPlayback = false;
    setState(() => _isPlaying = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: const Text(
          'Không phát được âm thanh. Hãy chọn bộ máy đọc và tải giọng '
          'tiếng Nhật/Anh trong cài đặt giọng đọc.',
        ),
        action: SnackBarAction(
          label: 'Cài đặt giọng',
          onPressed: () async {
            final opened = await _service.openSettings();
            if (!opened && mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text(
                    'Mở Cài đặt Android → Chuyển văn bản thành giọng nói.',
                  ),
                ),
              );
            }
          },
        ),
      ),
    );
  }

  Future<void> _handleSpeak() async {
    if (widget.text.trim().isEmpty) return;
    if (_isPlaying) {
      await _service.stop();
      return;
    }
    _ownsPlayback = true;
    setState(() => _isPlaying = true);
    try {
      final success = await _service.speak(
        widget.text,
        language: widget.language,
      );
      if (!success) _showPlaybackError();
    } catch (_) {
      _showPlaybackError();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final defaultColor = widget.color ?? const Color(0xFF38BDF8);
    final highlightColor = widget.activeColor ?? const Color(0xFF34D399);

    return IconButton(
      icon: Icon(
        _isPlaying ? Icons.volume_up_rounded : Icons.volume_up_outlined,
        size: widget.iconSize,
        color: _isPlaying ? highlightColor : defaultColor,
      ),
      padding: widget.padding,
      constraints:
          widget.constraints ??
          const BoxConstraints(minWidth: 32, minHeight: 32),
      visualDensity: widget.visualDensity,
      tooltip: widget.tooltip ?? 'Phát âm "${widget.text}"',
      onPressed: _handleSpeak,
    );
  }
}

/// Compact inline speaker icon for tight vocabulary chips.
class TtsChipSpeakerIcon extends StatefulWidget {
  final String text;
  final String language;
  final double size;
  final Color? color;
  final TtsService? ttsService;

  const TtsChipSpeakerIcon({
    super.key,
    required this.text,
    required this.language,
    this.size = 14,
    this.color,
    this.ttsService,
  });

  @override
  State<TtsChipSpeakerIcon> createState() => _TtsChipSpeakerIconState();
}

class _TtsChipSpeakerIconState extends State<TtsChipSpeakerIcon> {
  bool _isPlaying = false;
  bool _ownsPlayback = false;
  StreamSubscription<TTSState>? _subscription;

  TtsService get _service => widget.ttsService ?? TtsService.defaultInstance;

  @override
  void initState() {
    super.initState();
    _listenToPlayback();
  }

  @override
  void didUpdateWidget(covariant TtsChipSpeakerIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ttsService != widget.ttsService) {
      _subscription?.cancel();
      _ownsPlayback = false;
      _isPlaying = false;
      _listenToPlayback();
    }
  }

  void _listenToPlayback() {
    _subscription = _service.stateStream.listen((state) {
      if (!mounted || !_ownsPlayback) return;
      setState(() => _isPlaying = state == TTSState.speaking);
      if (state == TTSState.error) _showPlaybackError();
      if (state != TTSState.speaking) _ownsPlayback = false;
    });
  }

  void _showPlaybackError() {
    if (!_ownsPlayback || !mounted) return;
    _ownsPlayback = false;
    setState(() => _isPlaying = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: const Text(
          'Không phát được âm thanh. Hãy chọn bộ máy đọc và tải giọng '
          'tiếng Nhật/Anh trong cài đặt giọng đọc.',
        ),
        action: SnackBarAction(
          label: 'Cài đặt giọng',
          onPressed: () async {
            final opened = await _service.openSettings();
            if (!opened && mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text(
                    'Mở Cài đặt Android → Chuyển văn bản thành giọng nói.',
                  ),
                ),
              );
            }
          },
        ),
      ),
    );
  }

  Future<void> _handleSpeak() async {
    if (widget.text.trim().isEmpty) return;
    if (_isPlaying) {
      await _service.stop();
      return;
    }
    _ownsPlayback = true;
    setState(() => _isPlaying = true);
    try {
      final success = await _service.speak(
        widget.text,
        language: widget.language,
      );
      if (!success) _showPlaybackError();
    } catch (_) {
      _showPlaybackError();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = widget.color ?? const Color(0xFF38BDF8);
    return Tooltip(
      message: 'Nghe phát âm',
      child: InkWell(
        onTap: _handleSpeak,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            _isPlaying ? Icons.volume_up_rounded : Icons.volume_up_outlined,
            size: widget.size,
            color: _isPlaying ? const Color(0xFF34D399) : iconColor,
          ),
        ),
      ),
    );
  }
}
