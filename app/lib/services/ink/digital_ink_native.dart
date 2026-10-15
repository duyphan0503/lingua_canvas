import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;
import '../../models/handwriting_stroke.dart';
import 'digital_ink_common.dart';

/// Google ML Kit production implementation wrapping on-device neural recognizers.
///
/// Uses the direct native Android MethodChannel for 100% reliable model downloading
/// and on-device digital ink recognition, gracefully falling back to plugin or
/// [HeuristicDigitalInkEngine] if running on unsupported platforms or unit test runners.
class MlKitDigitalInkEngine implements DigitalInkEngine {
  MlKitDigitalInkEngine({
    bool? supportedPlatformForTesting,
    MethodChannel? channelOverride,
  }) : _supportedPlatformOverride = supportedPlatformForTesting,
       _channel =
           channelOverride ??
           const MethodChannel('com.linguacanvas.app/digital_ink_native');

  final bool? _supportedPlatformOverride;
  final MethodChannel _channel;
  final mlkit.DigitalInkRecognizerModelManager _pluginModelManager =
      mlkit.DigitalInkRecognizerModelManager();
  final Map<String, mlkit.DigitalInkRecognizer> _recognizers = {};
  final HeuristicDigitalInkEngine _heuristic = HeuristicDigitalInkEngine();

  bool get _isSupportedPlatform =>
      _supportedPlatformOverride ?? (!kIsWeb && Platform.isAndroid);

  @override
  Future<bool> isModelDownloaded(String languageTag) async {
    if (!_isSupportedPlatform) {
      return false;
    }
    final tag = normalizeLanguageTag(languageTag);
    try {
      final downloaded = await _channel.invokeMethod<bool>(
        'isModelDownloaded',
        {'model': tag},
      );
      if (downloaded == true) return true;
      if (tag == 'ja') {
        final jaJpDownloaded = await _channel.invokeMethod<bool>(
          'isModelDownloaded',
          {'model': 'ja-JP'},
        );
        if (jaJpDownloaded == true) return true;
      } else if (tag == 'en') {
        final enUsDownloaded = await _channel.invokeMethod<bool>(
          'isModelDownloaded',
          {'model': 'en-US'},
        );
        if (enUsDownloaded == true) return true;
      }
      return false;
    } catch (e) {
      debugPrint(
        'Native isModelDownloaded check failed: $e, trying plugin manager',
      );
      try {
        final downloaded = await _pluginModelManager.isModelDownloaded(tag);
        if (downloaded) return true;
        if (tag == 'ja') {
          return await _pluginModelManager.isModelDownloaded('ja-JP');
        } else if (tag == 'en') {
          return await _pluginModelManager.isModelDownloaded('en-US');
        }
        return false;
      } catch (e2) {
        debugPrint('ML Kit plugin isModelDownloaded check failed: $e2');
        return false;
      }
    }
  }

  @override
  Future<bool> downloadModel(String languageTag) async {
    if (!_isSupportedPlatform) {
      return false;
    }
    final tag = normalizeLanguageTag(languageTag);
    try {
      debugPrint('Starting native ML Kit model download for tag: $tag');
      final result = await _channel.invokeMethod<bool>('downloadModel', {
        'model': tag,
      });
      if (result == true) return true;

      final altTag = tag == 'ja' ? 'ja-JP' : 'en-US';
      debugPrint(
        'Retrying native ML Kit model download with alternate tag: $altTag',
      );
      final altResult = await _channel.invokeMethod<bool>('downloadModel', {
        'model': altTag,
      });
      return altResult == true;
    } catch (e) {
      debugPrint(
        'Native ML Kit downloadModel exception: $e, trying plugin manager',
      );
      try {
        final result = await _pluginModelManager.downloadModel(tag);
        if (result) return true;
        final altTag = tag == 'ja' ? 'ja-JP' : 'en-US';
        return await _pluginModelManager.downloadModel(altTag);
      } catch (e2) {
        debugPrint('ML Kit plugin downloadModel exception: $e2');
        return false;
      }
    }
  }

  @override
  Future<bool> deleteModel(String languageTag) async {
    if (!_isSupportedPlatform) {
      return false;
    }
    final tag = normalizeLanguageTag(languageTag);
    try {
      final result = await _channel.invokeMethod<bool>('deleteModel', {
        'model': tag,
      });
      return result == true;
    } catch (e) {
      debugPrint('Native deleteModel error: $e');
      try {
        return await _pluginModelManager.deleteModel(tag);
      } catch (e2) {
        return false;
      }
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
        return await _heuristic.getCandidates(strokes, languageTag);
      }

      // 1. Try direct native Android recognizer first
      try {
        final strokesData = strokes
            .map(
              (s) => {
                'points': s.points
                    .map((p) => {'x': p.x, 'y': p.y, 't': p.timestamp})
                    .toList(),
              },
            )
            .toList();

        final rawList = await _channel.invokeListMethod<dynamic>(
          'recognizeInk',
          {'model': tag, 'strokes': strokesData},
        );

        if (rawList != null && rawList.isNotEmpty) {
          final candidates = <String>[];
          for (final item in rawList) {
            if (item is Map && item.containsKey('text')) {
              final text = item['text']?.toString();
              if (text != null && text.isNotEmpty) {
                candidates.add(text);
              }
            } else if (item is String && item.isNotEmpty) {
              candidates.add(item);
            }
          }
          if (candidates.isNotEmpty) {
            return candidates;
          }
        }
      } catch (e) {
        debugPrint('Native recognizeInk failed: $e, trying plugin recognizer');
      }

      // 2. Fallback to Flutter plugin recognizer
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
        return await _heuristic.getCandidates(strokes, languageTag);
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
