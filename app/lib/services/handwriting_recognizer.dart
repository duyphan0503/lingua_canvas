import 'dart:math';
import 'digital_ink_engine.dart';
import 'stroke_guide_service.dart';
import '../models/handwriting_stroke.dart';
export '../models/handwriting_stroke.dart';

/// Evaluated evaluation outcome produced by [HandwritingRecognizer].
class RecognitionResult {
  final bool isAccurate;
  final double similarityScore; // 0.0 to 1.0
  final String recognizedText;
  final String feedbackMessage;
  final List<String> candidates;

  RecognitionResult({
    required this.isAccurate,
    required this.similarityScore,
    required this.recognizedText,
    required this.feedbackMessage,
    this.candidates = const [],
  });
}

/// Multi-tier handwriting recognizer and scoring engine.
///
/// Combines Google ML Kit candidates, Levenshtein distance matching,
/// stroke count verification penalties, and bounding box quality checks.
class HandwritingRecognizer {
  final DigitalInkEngine engine;

  HandwritingRecognizer({DigitalInkEngine? engine})
    : engine = engine ?? createDigitalInkEngine();

  /// Computes the Levenshtein edit distance between two strings.
  static int levenshteinDistance(String s, String t) {
    if (s == t) return 0;
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;

    final v0 = List<int>.generate(t.length + 1, (i) => i);
    final v1 = List<int>.filled(t.length + 1, 0);

    for (int i = 0; i < s.length; i++) {
      v1[0] = i + 1;
      for (int j = 0; j < t.length; j++) {
        final cost = s.codeUnitAt(i) == t.codeUnitAt(j) ? 0 : 1;
        v1[j + 1] = min(v1[j] + 1, min(v0[j + 1] + 1, v0[j] + cost));
      }
      for (int j = 0; j <= t.length; j++) {
        v0[j] = v1[j];
      }
    }
    return v0[t.length];
  }

  /// Computes the normalized Levenshtein similarity ratio between 0.0 and 1.0.
  static double levenshteinRatio(String s, String t) {
    final maxLen = max(s.length, t.length);
    if (maxLen == 0) return 1.0;
    final dist = levenshteinDistance(s, t);
    return max(0.0, 1.0 - (dist / maxLen));
  }

  /// Evaluates user's drawn strokes against [targetText] and [strokeOrderHints].
  Future<RecognitionResult> evaluate({
    required List<HandwritingStroke> strokes,
    required String targetText,
    required List<String> strokeOrderHints,
    String languageTag = 'ja',
  }) async {
    if (strokes.isEmpty) {
      return RecognitionResult(
        isAccurate: false,
        similarityScore: 0.0,
        recognizedText: "",
        feedbackMessage: "Hãy viết lên màn hình để bắt đầu luyện tập.",
        candidates: const [],
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
        candidates: const [],
      );
    }

    // 1. Digital Ink Engine candidates
    final candidates = await engine.getCandidates(strokes, languageTag);
    final topCandidate = candidates.isNotEmpty ? candidates.first.trim() : "";
    final normTarget = targetText.trim();
    final isEn = languageTag.startsWith('en');

    // 2. Candidate Match Score (70% weight base)
    // Checks exact and case-insensitive matches across top candidates
    int matchRank = -1;
    for (int i = 0; i < min(candidates.length, 5); i++) {
      final cand = candidates[i].trim();
      final isMatch = isEn
          ? cand.toLowerCase() == normTarget.toLowerCase()
          : cand == normTarget;
      if (isMatch) {
        matchRank = i;
        break;
      }
    }

    double candidateScore = 0.0;
    double bestLevRatio = 0.0;

    if (matchRank != -1) {
      // Top 1: 0.95; Top 2: 0.85; Top 3: 0.75; Top 4: 0.65; Top 5: 0.55
      candidateScore = 0.95 - (matchRank * 0.10);
    } else {
      // Fuzzy / Levenshtein matching for multi-character words ("バグ", "deploy", "開発")
      for (final candidate in candidates.take(5)) {
        final cand = candidate.trim();
        final ratio = levenshteinRatio(
          isEn ? cand.toLowerCase() : cand,
          isEn ? normTarget.toLowerCase() : normTarget,
        );
        if (ratio > bestLevRatio) {
          bestLevRatio = ratio;
        }
      }
      candidateScore = (bestLevRatio * 0.70).clamp(0.0, 0.70);
    }

    // Canonical counts take priority over prose hints, especially for compounds.
    // Other languages and unavailable glyphs retain the existing scoring fallback.
    if (languageTag.startsWith('ja')) await StrokeGuideService.initialize();
    final canonicalCount = languageTag.startsWith('ja')
        ? StrokeGuideService.coverageFor(normTarget).expectedStrokeCount
        : null;
    int expectedStrokes =
        canonicalCount ??
        (strokeOrderHints.isNotEmpty
            ? strokeOrderHints.length
            : targetText.length);
    if (expectedStrokes <= 0) expectedStrokes = 1;

    final strokeDiff = (totalStrokes - expectedStrokes).abs();
    final strokeScore = max(0.0, 1.0 - (strokeDiff * 0.20));

    // 4. Bounding Box & Aspect Ratio (10% weight)
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;

    for (final stroke in strokes) {
      for (final pt in stroke.points) {
        if (pt.x < minX) minX = pt.x;
        if (pt.x > maxX) maxX = pt.x;
        if (pt.y < minY) minY = pt.y;
        if (pt.y > maxY) maxY = pt.y;
      }
    }

    final width = maxX > minX ? maxX - minX : 0.0;
    final height = maxY > minY ? maxY - minY : 0.0;

    double boxScore = 1.0;
    if (width < 30 || height < 30) {
      boxScore = 0.4;
    } else {
      final aspectRatio = width / (height > 0 ? height : 1.0);
      if (aspectRatio >= 0.25 && aspectRatio <= 4.0) {
        boxScore = 1.0;
      } else {
        boxScore = 0.7;
      }
    }

    // A start/end vector is invariant under translation and positive uniform scale.
    // Skip nearly closed strokes and mismatched counts: alignment is ambiguous.
    final guides = canonicalCount == null
        ? const <StrokeGuidePath>[]
        : StrokeGuideService.guidesFor(normTarget);
    var reversedStrokes = 0;
    var comparableStrokes = 0;
    if (guides.length == strokes.length) {
      for (var i = 0; i < guides.length; i++) {
        final points = strokes[i].points;
        if (points.length < 2) continue;
        final expected =
            guides[i].normalizedPoints.last - guides[i].normalizedPoints.first;
        final dx = points.last.x - points.first.x;
        final dy = points.last.y - points.first.y;
        if (expected.distance < .025 || sqrt(dx * dx + dy * dy) < 2) continue;
        comparableStrokes++;
        // Angles above 90 degrees identify a basic reversed direction while
        // allowing substantial slant and imperfect pen endpoints.
        if (dx * expected.dx + dy * expected.dy < 0) reversedStrokes++;
      }
    }
    final directionPenalty = comparableStrokes == 0
        ? 0.0
        : .20 * reversedStrokes / comparableStrokes;

    // Preserve the original formula when canonical direction data is unavailable.
    final similarityScore =
        ((candidateScore * 0.70) +
                (strokeScore * 0.20) +
                (boxScore * 0.10) -
                directionPenalty)
            .clamp(0.0, 1.0);

    // Accuracy threshold: composite score >= 0.75 and either exact match in top 5 or Levenshtein ratio >= 0.80
    final isAccurate =
        similarityScore >= 0.75 &&
        (matchRank >= 0 || bestLevRatio >= 0.80) &&
        reversedStrokes == 0;

    // 6. Contextual Vietnamese Feedback
    String feedback;
    if (reversedStrokes > 0) {
      feedback =
          "Có $reversedStrokes nét ngược hướng. Hãy viết theo hướng đầu đến cuối của nét mẫu.";
    } else if (isAccurate) {
      if (matchRank == 0) {
        feedback =
            "Tuyệt vời! Nhận diện chính xác '$normTarget'. Nét chữ rất chuẩn.";
      } else if (matchRank > 0) {
        feedback =
            "Khá tốt! ML Kit nhận diện gần đúng (Top 1 là '$topCandidate'). Chú ý nắn nót hơn.";
      } else {
        feedback =
            "Rất tốt! Nhận diện '$topCandidate' đạt độ tương đồng cao với '$normTarget'.";
      }
    } else {
      if (totalStrokes < expectedStrokes && matchRank == -1) {
        feedback =
            "Còn thiếu nét (Đã viết: $totalStrokes/$expectedStrokes nét). Hãy viết đủ các nét theo hướng dẫn.";
      } else if (totalStrokes > expectedStrokes + 3 && matchRank == -1) {
        feedback =
            "Hơi nhiều nét thừa ($totalStrokes nét). Hãy thử viết dứt khoát hơn.";
      } else if (width < 25 || height < 25) {
        feedback =
            "Khung chữ quá nhỏ (dưới 25px). Hãy viết to và rõ ràng hơn trong khung canvas.";
      } else if (topCandidate.isNotEmpty) {
        feedback =
            "Chưa nhận diện được '$normTarget'. ML Kit nhận diện: '$topCandidate'. Hãy thử lại.";
      } else {
        feedback = "Chưa nhận diện được nét chữ. Hãy thử viết lại rõ ràng hơn.";
      }
    }

    final recognizedText = matchRank >= 0
        ? normTarget
        : (topCandidate.isNotEmpty ? topCandidate : "...");

    return RecognitionResult(
      isAccurate: isAccurate,
      similarityScore: similarityScore,
      recognizedText: recognizedText,
      feedbackMessage: feedback,
      candidates: candidates,
    );
  }

  /// Default static singleton recognizer for backwards-compatible or lightweight call sites.
  static final HandwritingRecognizer _defaultInstance = HandwritingRecognizer();

  /// Static helper delegating to the default or specified [engine].
  static Future<RecognitionResult> evaluateStatic({
    required List<HandwritingStroke> strokes,
    required String targetText,
    required List<String> strokeOrderHints,
    String languageTag = 'ja',
    DigitalInkEngine? engine,
  }) {
    if (engine != null) {
      return HandwritingRecognizer(engine: engine).evaluate(
        strokes: strokes,
        targetText: targetText,
        strokeOrderHints: strokeOrderHints,
        languageTag: languageTag,
      );
    }
    return _defaultInstance.evaluate(
      strokes: strokes,
      targetText: targetText,
      strokeOrderHints: strokeOrderHints,
      languageTag: languageTag,
    );
  }
}
