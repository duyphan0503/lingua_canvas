import 'dart:math';
import 'package:flutter/material.dart';

class StrokePoint {
  final double x;
  final double y;
  final int timestamp;

  StrokePoint({required this.x, required this.y, required this.timestamp});
}

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

class RecognitionResult {
  final bool isAccurate;
  final double similarityScore; // 0.0 to 1.0
  final String recognizedText;
  final String feedbackMessage;

  RecognitionResult({
    required this.isAccurate,
    required this.similarityScore,
    required this.recognizedText,
    required this.feedbackMessage,
  });
}

class HandwritingRecognizer {
  /// Evaluates the user's drawn strokes against the target text & hints.
  static RecognitionResult evaluate({
    required List<HandwritingStroke> strokes,
    required String targetText,
    required List<String> strokeOrderHints,
  }) {
    if (strokes.isEmpty) {
      return RecognitionResult(
        isAccurate: false,
        similarityScore: 0.0,
        recognizedText: "",
        feedbackMessage: "Hãy viết lên màn hình để bắt đầu luyện tập.",
      );
    }

    final totalStrokes = strokes.length;
    final totalPoints = strokes.fold<int>(0, (sum, s) => sum + s.points.length);

    if (totalPoints < 10) {
      return RecognitionResult(
        isAccurate: false,
        similarityScore: 0.2,
        recognizedText: "...",
        feedbackMessage: "Nét chữ quá ngắn. Hãy hoàn thành trọn vẹn nét chữ.",
      );
    }

    // Expected strokes heuristic
    int expectedStrokes = strokeOrderHints.isNotEmpty
        ? strokeOrderHints.length
        : targetText.length;
    if (expectedStrokes == 0) expectedStrokes = 1;

    // Calculate stroke difference penalty
    final strokeDiff = (totalStrokes - expectedStrokes).abs();
    double strokeScore = max(0.0, 1.0 - (strokeDiff * 0.2));

    // Calculate bounding box aspect ratio and bounds
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;

    for (var stroke in strokes) {
      for (var pt in stroke.points) {
        if (pt.x < minX) minX = pt.x;
        if (pt.x > maxX) maxX = pt.x;
        if (pt.y < minY) minY = pt.y;
        if (pt.y > maxY) maxY = pt.y;
      }
    }

    final width = maxX - minX;
    final height = maxY - minY;

    double sizeScore = 1.0;
    if (width < 30 || height < 30) {
      sizeScore = 0.5;
    }

    final similarityScore = ((strokeScore * 0.7) + (sizeScore * 0.3)).clamp(
      0.0,
      1.0,
    );
    final isAccurate =
        similarityScore >= 0.75 &&
        totalStrokes >= expectedStrokes &&
        totalStrokes <= expectedStrokes + 2;

    String feedback;
    if (isAccurate) {
      feedback = "Tuyệt vời! Thứ tự và tỷ lệ nét chữ viết rất chuẩn.";
    } else if (totalStrokes < expectedStrokes) {
      feedback =
          "Còn thiếu nét (Đã viết: $totalStrokes/$expectedStrokes nét). Hãy viết đủ các nét.";
    } else if (totalStrokes > expectedStrokes + 2) {
      feedback =
          "Hơi nhiều nét thừa ($totalStrokes nét). Hãy thử viết dứt khoát hơn.";
    } else {
      feedback = "Nét vẽ khá tốt! Hãy chú ý tỷ lệ khung hình cân đối hơn.";
    }

    return RecognitionResult(
      isAccurate: isAccurate,
      similarityScore: similarityScore,
      recognizedText: targetText,
      feedbackMessage: feedback,
    );
  }
}
