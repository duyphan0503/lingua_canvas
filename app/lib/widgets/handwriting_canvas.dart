import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../services/handwriting_recognizer.dart';

/// Interactive touch/pen canvas for handwriting practice.
///
/// Features:
/// - 3-point moving average smoothing to eliminate sensor jitter
/// - Dynamic velocity-dependent stroke width tapering for Japanese/English calligraphy
/// - 750ms debounced recognition callback on finger lift
class HandwritingCanvas extends StatefulWidget {
  final List<HandwritingStroke> strokes;
  final ValueChanged<List<HandwritingStroke>> onStrokesChanged;
  final VoidCallback? onStrokeCompleted;
  final VoidCallback? onDebouncedEvaluation;
  final Duration debounceDuration;
  final String? watermarkText;
  final Color strokeColor;
  final double strokeWidth;
  final bool isReadOnly;

  const HandwritingCanvas({
    super.key,
    required this.strokes,
    required this.onStrokesChanged,
    this.onStrokeCompleted,
    this.onDebouncedEvaluation,
    this.debounceDuration = const Duration(milliseconds: 750),
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
  Timer? _debounceTimer;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  /// Applies a 3-point moving average filter:
  /// P_i' = 0.25 * P_{i-1} + 0.50 * P_i + 0.25 * P_{i+1}
  static List<StrokePoint> smoothPoints(List<StrokePoint> raw) {
    if (raw.length <= 2) return List.from(raw);
    final smoothed = <StrokePoint>[raw.first];

    for (int i = 1; i < raw.length - 1; i++) {
      final prev = raw[i - 1];
      final curr = raw[i];
      final next = raw[i + 1];

      smoothed.add(
        StrokePoint(
          x: 0.25 * prev.x + 0.50 * curr.x + 0.25 * next.x,
          y: 0.25 * prev.y + 0.50 * curr.y + 0.25 * next.y,
          timestamp: curr.timestamp,
        ),
      );
    }

    smoothed.add(raw.last);
    return smoothed;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (widget.isReadOnly) return;
    _debounceTimer?.cancel();

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
      // Apply 3-point moving average smoothing to the completed stroke
      final smoothedPoints = smoothPoints(_currentStroke!.points);
      final smoothedStroke = HandwritingStroke(
        points: smoothedPoints,
        color: _currentStroke!.color,
        strokeWidth: _currentStroke!.strokeWidth,
      );

      final updated = List<HandwritingStroke>.from(widget.strokes);
      final existingIndex = updated.indexOf(_currentStroke!);
      if (existingIndex >= 0) {
        updated[existingIndex] = smoothedStroke;
      } else {
        updated.add(smoothedStroke);
      }

      widget.onStrokesChanged(updated);
      _currentStroke = null;
    }

    widget.onStrokeCompleted?.call();

    // Trigger debounced evaluation after finger lift
    _debounceTimer?.cancel();
    _debounceTimer = Timer(widget.debounceDuration, () {
      if (mounted) {
        widget.onDebouncedEvaluation?.call();
      }
    });
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

    // 3. Render strokes with velocity-dependent width tapering and quadratic Bézier
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
    final points = stroke.points;
    if (points.isEmpty) return;

    final baseWidth = stroke.strokeWidth;

    if (points.length == 1) {
      final dotPaint = Paint()
        ..color = stroke.color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;
      canvas.drawCircle(
        Offset(points[0].x, points[0].y),
        baseWidth / 2,
        dotPaint,
      );
      return;
    }

    if (points.length == 2) {
      final p0 = points[0];
      final p1 = points[1];
      final dt = max((p1.timestamp - p0.timestamp).abs(), 1);
      final dist = sqrt(pow(p1.x - p0.x, 2) + pow(p1.y - p0.y, 2));
      final velocity = dist / dt;
      final vNorm = (velocity / 2.0).clamp(0.0, 1.0);
      final width = (baseWidth * (1.0 - 0.4 * vNorm)).clamp(
        0.6 * baseWidth,
        1.3 * baseWidth,
      );

      final linePaint = Paint()
        ..color = stroke.color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;

      canvas.drawLine(Offset(p0.x, p0.y), Offset(p1.x, p1.y), linePaint);
      return;
    }

    // Multiple points: draw segments with velocity-tapered width and Bézier curves
    for (int i = 1; i < points.length - 1; i++) {
      final p0 = points[i - 1];
      final p1 = points[i];
      final p2 = points[i + 1];

      final mid1X = (p0.x + p1.x) / 2;
      final mid1Y = (p0.y + p1.y) / 2;
      final mid2X = (p1.x + p2.x) / 2;
      final mid2Y = (p1.y + p2.y) / 2;

      // Velocity-dependent tapering
      final dt = max((p1.timestamp - p0.timestamp).abs(), 1);
      final dist = sqrt(pow(p1.x - p0.x, 2) + pow(p1.y - p0.y, 2));
      final velocity = dist / dt;
      final vNorm = (velocity / 2.0).clamp(0.0, 1.0);
      final segmentWidth = (baseWidth * (1.0 - 0.4 * vNorm)).clamp(
        0.6 * baseWidth,
        1.3 * baseWidth,
      );

      final segPaint = Paint()
        ..color = stroke.color
        ..strokeWidth = segmentWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;

      final segPath = Path();
      if (i == 1) {
        segPath.moveTo(p0.x, p0.y);
        segPath.quadraticBezierTo(p1.x, p1.y, mid2X, mid2Y);
      } else if (i == points.length - 2) {
        segPath.moveTo(mid1X, mid1Y);
        segPath.quadraticBezierTo(p1.x, p1.y, p2.x, p2.y);
      } else {
        segPath.moveTo(mid1X, mid1Y);
        segPath.quadraticBezierTo(p1.x, p1.y, mid2X, mid2Y);
      }
      canvas.drawPath(segPath, segPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter oldDelegate) {
    return oldDelegate.strokes != strokes ||
        oldDelegate.watermarkText != watermarkText;
  }
}
