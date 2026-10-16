import 'package:flutter/material.dart';

/// Represents a single 2D touch or pen coordinate with a millisecond timestamp.
class StrokePoint {
  final double x;
  final double y;
  final int timestamp;

  const StrokePoint({
    required this.x,
    required this.y,
    required this.timestamp,
  });
}

/// Represents a continuous handwriting stroke composed of sequential [StrokePoint]s.
class HandwritingStroke {
  final List<StrokePoint> points;
  final Color color;
  final double strokeWidth;

  HandwritingStroke({
    required this.points,
    this.color = const Color(0xFF6366F1),
    this.strokeWidth = 4.0,
  });
}
