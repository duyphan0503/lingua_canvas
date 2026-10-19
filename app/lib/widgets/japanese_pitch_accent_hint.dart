import 'package:flutter/material.dart';

import '../services/japanese_pitch_accent.dart';

class JapanesePitchAccentHint extends StatelessWidget {
  final String word;
  final String? reading;
  const JapanesePitchAccentHint({super.key, required this.word, this.reading});

  @override
  Widget build(BuildContext context) {
    final entries = const JapanesePitchAccentRepository().lookupAll(
      word,
      reading: reading,
    );
    if (entries.isEmpty) {
      return Semantics(
        label: 'Chưa có dữ liệu cao độ từ đã kiểm chứng cho $word',
        child: const Text(
          'Cao độ từ: chưa có dữ liệu đã kiểm chứng',
          style: TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
        ),
      );
    }

    final patterns = entries
        .map((entry) => '${entry.reading} ${entry.patternName}')
        .join(', ');
    return Semantics(
      label:
          'Cao độ từ $word: $patterns. ${JapanesePitchAccentRepository.provenance}',
      child: Wrap(
        spacing: 6,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final entry in entries) _PitchPattern(entry: entry),
          const Text(
            'Kanjium · CC BY-SA 4.0',
            style: TextStyle(fontSize: 9, color: Color(0xFF94A3B8)),
          ),
        ],
      ),
    );
  }
}

class _PitchPattern extends StatelessWidget {
  final JapanesePitchAccent entry;
  const _PitchPattern({required this.entry});

  @override
  Widget build(BuildContext context) {
    final morae = entry.morae;
    final width = (morae.length + 1) * 10.0 + 4;
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '${entry.reading} · ${entry.patternName}',
          style: const TextStyle(fontSize: 9, color: Color(0xFFCBD5E1)),
        ),
        const SizedBox(width: 2),
        CustomPaint(
          key: const ValueKey('japanese-pitch-contour'),
          size: Size(width, 20),
          painter: _PitchContourPainter(entry.highPitchByMora),
        ),
      ],
    );
  }
}

class _PitchContourPainter extends CustomPainter {
  final List<bool> highPitchByMora;
  const _PitchContourPainter(this.highPitchByMora);

  @override
  void paint(Canvas canvas, Size size) {
    if (highPitchByMora.length < 2) return;
    final paint = Paint()
      ..color = const Color(0xFF38BDF8)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final left = 2.0;
    final gap = (size.width - left * 2) / (highPitchByMora.length - 1);
    double yAt(int index) => highPitchByMora[index] ? 4 : size.height - 4;
    final path = Path()..moveTo(left, yAt(0));
    for (var index = 1; index < highPitchByMora.length; index++) {
      final x = left + gap * index;
      path
        ..lineTo(x, yAt(index - 1))
        ..lineTo(x, yAt(index));
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _PitchContourPainter oldDelegate) =>
      oldDelegate.highPitchByMora != highPitchByMora;
}
