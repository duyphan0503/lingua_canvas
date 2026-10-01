import 'package:flutter/material.dart';
import '../services/handwriting_recognizer.dart';

/// Interactive touch/pen canvas for handwriting practice.
/// Uses CustomPaint and GestureDetector to capture and render smooth strokes.
class HandwritingCanvas extends StatefulWidget {
  final List<HandwritingStroke> strokes;
  final ValueChanged<List<HandwritingStroke>> onStrokesChanged;
  final VoidCallback? onStrokeCompleted;
  final String? watermarkText;
  final Color strokeColor;
  final double strokeWidth;
  final bool isReadOnly;

  const HandwritingCanvas({
    super.key,
    required this.strokes,
    required this.onStrokesChanged,
    this.onStrokeCompleted,
    this.watermarkText,
    this.strokeColor = const Color(0xFF38BDF8),
    this.strokeWidth = 4.5,
    this.isReadOnly = false,
  });

  @override
  State<HandwritingCanvas> createState() => _HandwritingCanvasState();
}

class _HandwritingCanvasState extends State<HandwritingCanvas> {
  HandwritingStroke? _currentStroke;

  void _onPointerDown(PointerDownEvent event) {
    if (widget.isReadOnly) return;
    final initialPoint = StrokePoint(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      timestamp: event.timeStamp.inMilliseconds,
    );

    final newStroke = HandwritingStroke(
      points: [initialPoint],
      color: widget.strokeColor,
      strokeWidth: widget.strokeWidth,
    );
    _currentStroke = newStroke;

    final updated = List<HandwritingStroke>.from(widget.strokes)
      ..add(newStroke);
    widget.onStrokesChanged(updated);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (widget.isReadOnly || _currentStroke == null) return;
    final newPoint = StrokePoint(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      timestamp: event.timeStamp.inMilliseconds,
    );

    _currentStroke!.points.add(newPoint);
    if (!widget.strokes.contains(_currentStroke)) {
      final updated = List<HandwritingStroke>.from(widget.strokes)
        ..add(_currentStroke!);
      widget.onStrokesChanged(updated);
    } else {
      widget.onStrokesChanged(List<HandwritingStroke>.from(widget.strokes));
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (widget.isReadOnly) return;
    if (_currentStroke != null) {
      if (!widget.strokes.contains(_currentStroke)) {
        final updated = List<HandwritingStroke>.from(widget.strokes)
          ..add(_currentStroke!);
        widget.onStrokesChanged(updated);
      }
      _currentStroke = null;
    }
    widget.onStrokeCompleted?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        behavior: HitTestBehavior.opaque,
        child: CustomPaint(
          size: Size.infinite,
          painter: _CanvasPainter(
            strokes: widget.strokes,
            watermarkText: widget.watermarkText,
          ),
        ),
      ),
    );
  }
}

class _CanvasPainter extends CustomPainter {
  final List<HandwritingStroke> strokes;
  final String? watermarkText;

  _CanvasPainter({required this.strokes, this.watermarkText});

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Background grid guides (subtle quadrant crosshairs for character alignment)
    _drawGridGuides(canvas, size);

    // 2. Faint watermark guide text if available
    if (watermarkText != null && watermarkText!.isNotEmpty) {
      _drawWatermark(canvas, size, watermarkText!);
    }

    // 3. Render strokes with smooth quadratic bezier curves
    for (final stroke in strokes) {
      _drawSmoothStroke(canvas, stroke);
    }
  }

  void _drawGridGuides(Canvas canvas, Size size) {
    final guidePaint = Paint()
      ..color =
          const Color(0x1A94A3B8) // Slate 400 with ~10% opacity
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Outer border
    final borderRect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(16),
    );
    canvas.drawRRect(borderRect, guidePaint);

    // Horizontal center dashed line
    final midY = size.height / 2;
    _drawDashedLine(
      canvas,
      Offset(20, midY),
      Offset(size.width - 20, midY),
      guidePaint,
    );

    // Vertical center dashed line
    final midX = size.width / 2;
    _drawDashedLine(
      canvas,
      Offset(midX, 20),
      Offset(midX, size.height - 20),
      guidePaint,
    );
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    const dashWidth = 6.0;
    const dashSpace = 4.0;
    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final distance = (dx * dx + dy * dy);
    if (distance <= 0) return;
    final length = (dx != 0 ? dx.abs() : dy.abs());
    final isHorizontal = dy == 0;

    double current = 0;
    while (current < length) {
      if (isHorizontal) {
        final startX = p1.dx + current;
        final endX = (startX + dashWidth).clamp(p1.dx, p2.dx);
        canvas.drawLine(Offset(startX, p1.dy), Offset(endX, p1.dy), paint);
      } else {
        final startY = p1.dy + current;
        final endY = (startY + dashWidth).clamp(p1.dy, p2.dy);
        canvas.drawLine(Offset(p1.dx, startY), Offset(p1.dx, endY), paint);
      }
      current += dashWidth + dashSpace;
    }
  }

  void _drawWatermark(Canvas canvas, Size size, String text) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size.height * 0.45,
          fontWeight: FontWeight.bold,
          color: const Color(0x1FFFFFFF), // Faint white watermark
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);

    final offset = Offset(
      (size.width - textPainter.width) / 2,
      (size.height - textPainter.height) / 2,
    );
    textPainter.paint(canvas, offset);
  }

  void _drawSmoothStroke(Canvas canvas, HandwritingStroke stroke) {
    if (stroke.points.isEmpty) return;

    final paint = Paint()
      ..color = stroke.color
      ..strokeWidth = stroke.strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke;

    final points = stroke.points;
    if (points.length == 1) {
      canvas.drawCircle(
        Offset(points[0].x, points[0].y),
        stroke.strokeWidth / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }

    if (points.length == 2) {
      canvas.drawLine(
        Offset(points[0].x, points[0].y),
        Offset(points[1].x, points[1].y),
        paint,
      );
      return;
    }

    final path = Path();
    path.moveTo(points[0].x, points[0].y);

    for (int i = 1; i < points.length - 1; i++) {
      final midX = (points[i].x + points[i + 1].x) / 2;
      final midY = (points[i].y + points[i + 1].y) / 2;
      path.quadraticBezierTo(points[i].x, points[i].y, midX, midY);
    }

    path.lineTo(points.last.x, points.last.y);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter oldDelegate) {
    return oldDelegate.strokes != strokes ||
        oldDelegate.watermarkText != watermarkText;
  }
}
