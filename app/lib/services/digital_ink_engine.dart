import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;
import 'handwriting_recognizer.dart';

/// Normalizes language tags to BCP-47 identifiers recognized by ML Kit.
///
/// 'ja', 'ja-JP', 'ja_JP' -> 'ja'
/// 'en', 'en-US', 'en_US' -> 'en'
String normalizeLanguageTag(String tag) {
  final lower = tag.trim().toLowerCase().replaceAll('_', '-');
  if (lower.startsWith('ja')) return 'ja';
  if (lower.startsWith('en')) return 'en';
  return lower;
}

/// Abstract contract for Digital Ink recognition and model management.
abstract class DigitalInkEngine {
  /// Checks whether the recognition model for [languageTag] is already downloaded.
  Future<bool> isModelDownloaded(String languageTag);

  /// Downloads the recognition model for [languageTag].
  Future<bool> downloadModel(String languageTag);

  /// Deletes the downloaded model for [languageTag] to reclaim storage.
  Future<bool> deleteModel(String languageTag);

  /// Recognizes the provided handwriting strokes and returns candidate strings in rank order.
  Future<List<String>> getCandidates(
    List<HandwritingStroke> strokes,
    String languageTag,
  );

  /// Releases platform resources held by the engine.
  void dispose();
}

/// Heuristic-based fallback engine analyzing geometric density, stroke count,
/// and bounding box aspect ratio when offline or running without a neural model.
class HeuristicDigitalInkEngine implements DigitalInkEngine {
  final Map<String, bool> _downloadedModels = {'ja': false, 'en': false};

  @override
  Future<bool> isModelDownloaded(String languageTag) async {
    final tag = normalizeLanguageTag(languageTag);
    return _downloadedModels[tag] ?? false;
  }

  @override
  Future<bool> downloadModel(String languageTag) async {
    final tag = normalizeLanguageTag(languageTag);
    _downloadedModels[tag] = true;
    return true;
  }

  @override
  Future<bool> deleteModel(String languageTag) async {
    final tag = normalizeLanguageTag(languageTag);
    _downloadedModels[tag] = false;
    return true;
  }

  @override
  Future<List<String>> getCandidates(
    List<HandwritingStroke> strokes,
    String languageTag,
  ) async {
    if (strokes.isEmpty) return [];

    final tag = normalizeLanguageTag(languageTag);
    final strokeCount = strokes.length;

    // 1. Calculate bounding box
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    double totalPathLength = 0.0;

    for (final stroke in strokes) {
      final points = stroke.points;
      for (int i = 0; i < points.length; i++) {
        final pt = points[i];
        if (pt.x < minX) minX = pt.x;
        if (pt.x > maxX) maxX = pt.x;
        if (pt.y < minY) minY = pt.y;
        if (pt.y > maxY) maxY = pt.y;

        if (i > 0) {
          final prev = points[i - 1];
          totalPathLength += sqrt(
            pow(pt.x - prev.x, 2) + pow(pt.y - prev.y, 2),
          );
        }
      }
    }

    final width = maxX > minX ? maxX - minX : 1.0;
    final height = maxY > minY ? maxY - minY : 1.0;
    final aspectRatio = width / height;

    // 2. Classify candidates based on language, stroke count, and geometry
    if (tag == 'en') {
      return _classifyEnglish(strokeCount, aspectRatio, totalPathLength);
    } else {
      return _classifyJapanese(strokeCount, aspectRatio, totalPathLength);
    }
  }

  List<String> _classifyJapanese(
    int strokeCount,
    double aspectRatio,
    double pathLength,
  ) {
    switch (strokeCount) {
      case 1:
        if (aspectRatio > 1.3) {
          return ['一', 'へ', 'ー', 'つ'];
        } else if (aspectRatio < 0.7) {
          return ['し', 'ノ', '1', 'l'];
        } else {
          return ['つ', 'く', 'ん', 'o', 'O'];
        }
      case 2:
        if (aspectRatio > 1.2) {
          return ['二', 'こ', 'ご'];
        } else if (aspectRatio < 0.8) {
          return ['い', 'り', '川', '十'];
        } else {
          return ['い', '十', '八', '人', '入', '九', '七', 'う', '力'];
        }
      case 3:
        if (aspectRatio > 1.2) {
          return ['三', 'さ', 'す'];
        } else {
          return ['あ', 'す', 'さ', 'お', 'え', '川', '山', '口', '女', '大'];
        }
      case 4:
        return ['木', '日', '月', '水', '火', '文', 'た', 'ね', '心', '手'];
      case 5:
        return ['本', '田', '白', '目', '生', 'な', '出', '立', '右', '左'];
      default:
        return ['開発', 'バグ', '年', '気', '語', '学', '車', '金', 'コード'];
    }
  }

  List<String> _classifyEnglish(
    int strokeCount,
    double aspectRatio,
    double pathLength,
  ) {
    switch (strokeCount) {
      case 1:
        if (aspectRatio < 0.6) {
          return ['l', 'I', '1', 'j', 'i'];
        } else {
          return ['o', 'c', 'e', 's', 'u', 'v', 'O', 'C'];
        }
      case 2:
        if (aspectRatio < 0.7) {
          return ['t', 'l', 'T', 'L'];
        } else {
          return ['t', 'x', 'X', 'T', 'L', 'P', 'r', 'n'];
        }
      case 3:
        return ['A', 'H', 'F', 'k', 'N', 'Y', 'Z', 'K'];
      case 4:
        return ['E', 'M', 'W', 'B'];
      default:
        return ['deploy', 'bug', 'code', 'test', 'server', 'commit', 'build'];
    }
  }

  @override
  void dispose() {}
}

/// Deterministic mock engine for automated unit and widget testing in Linux CI.
///
/// Prevents [MissingPluginException] by bypassing native Android/iOS channels.
class MockDigitalInkEngine implements DigitalInkEngine {
  final Map<String, bool> downloadedModels;
  List<String> mockCandidates;
  final HeuristicDigitalInkEngine _heuristic = HeuristicDigitalInkEngine();

  MockDigitalInkEngine({
    Map<String, bool>? initialDownloadedModels,
    List<String>? mockCandidates,
  }) : downloadedModels = initialDownloadedModels ?? {'ja': true, 'en': true},
       mockCandidates = mockCandidates ?? [];

  /// Helper to dynamically set expected candidate outputs during test assertions.
  void setCandidates(List<String> candidates) {
    mockCandidates = List.from(candidates);
  }

  @override
  Future<bool> isModelDownloaded(String languageTag) async {
    final tag = normalizeLanguageTag(languageTag);
    return downloadedModels[tag] ?? false;
  }

  @override
  Future<bool> downloadModel(String languageTag) async {
    final tag = normalizeLanguageTag(languageTag);
    downloadedModels[tag] = true;
    return true;
  }

  @override
  Future<bool> deleteModel(String languageTag) async {
    final tag = normalizeLanguageTag(languageTag);
    downloadedModels[tag] = false;
    return true;
  }

  @override
  Future<List<String>> getCandidates(
    List<HandwritingStroke> strokes,
    String languageTag,
  ) async {
    if (strokes.isEmpty) return [];

    if (mockCandidates.isNotEmpty) {
      return List.from(mockCandidates);
    }

    // Default to geometric heuristic if no explicit mock candidates were specified
    return _heuristic.getCandidates(strokes, languageTag);
  }

  @override
  void dispose() {
    _heuristic.dispose();
  }
}

/// Google ML Kit production implementation wrapping on-device neural recognizers.
///
/// Gracefully falls back to [HeuristicDigitalInkEngine] if platform channel
/// throws [MissingPluginException] or if running in an unsupported desktop sandbox.
class MlKitDigitalInkEngine implements DigitalInkEngine {
  MlKitDigitalInkEngine({bool? supportedPlatformForTesting})
    : _supportedPlatformOverride = supportedPlatformForTesting;

  final bool? _supportedPlatformOverride;
  final mlkit.DigitalInkRecognizerModelManager _modelManager =
      mlkit.DigitalInkRecognizerModelManager();
  final Map<String, mlkit.DigitalInkRecognizer> _recognizers = {};
  final HeuristicDigitalInkEngine _heuristic = HeuristicDigitalInkEngine();

  bool get _isSupportedPlatform =>
      _supportedPlatformOverride ??
      (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  @override
  Future<bool> isModelDownloaded(String languageTag) async {
    if (!_isSupportedPlatform) {
      return false;
    }
    try {
      final tag = normalizeLanguageTag(languageTag);
      return await _modelManager.isModelDownloaded(tag);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> downloadModel(String languageTag) async {
    if (!_isSupportedPlatform) {
      return false;
    }
    try {
      final tag = normalizeLanguageTag(languageTag);
      return await _modelManager.downloadModel(tag);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> deleteModel(String languageTag) async {
    if (!_isSupportedPlatform) {
      return false;
    }
    try {
      final tag = normalizeLanguageTag(languageTag);
      return await _modelManager.deleteModel(tag);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<String>> getCandidates(
    List<HandwritingStroke> strokes,
    String languageTag,
  ) async {
    if (strokes.isEmpty) return [];
    if (!_isSupportedPlatform) {
      return _heuristic.getCandidates(strokes, languageTag);
    }

    final tag = normalizeLanguageTag(languageTag);

    try {
      final isDownloaded = await isModelDownloaded(tag);
      if (!isDownloaded) {
        return _heuristic.getCandidates(strokes, languageTag);
      }

      final recognizer = _recognizers.putIfAbsent(
        tag,
        () => mlkit.DigitalInkRecognizer(languageCode: tag),
      );

      final mlkitInk = mlkit.Ink();
      for (final stroke in strokes) {
        final mlkitStroke = mlkit.Stroke();
        for (final pt in stroke.points) {
          mlkitStroke.points.add(
            mlkit.StrokePoint(x: pt.x, y: pt.y, t: pt.timestamp),
          );
        }
        mlkitInk.strokes.add(mlkitStroke);
      }

      final candidates = await recognizer.recognize(mlkitInk);
      if (candidates.isEmpty) {
        return _heuristic.getCandidates(strokes, languageTag);
      }
      return candidates.map((c) => c.text).toList();
    } catch (_) {
      // Fallback gracefully to geometric heuristic on any error
      return _heuristic.getCandidates(strokes, languageTag);
    }
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers.values) {
      recognizer.close();
    }
    _recognizers.clear();
    _heuristic.dispose();
  }
}
