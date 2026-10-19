abstract interface class SpeechPracticeEngine {
  Future<bool> isAvailable();
  Future<String> listen({required String language});
  Future<void> stop();
}

class SpeechPracticeException implements Exception {
  final String code;
  final String message;

  const SpeechPracticeException(this.code, this.message);

  @override
  String toString() => message;
}

class PronunciationResult {
  final String recognizedTranscript;
  final String targetText;
  final double accuracyScore;
  final bool isPassed;
  final String feedbackVi;
  /// Text segments that the recognizer transcript could not align to the target.
  /// These are not an acoustic or phoneme-level diagnosis.
  final List<String> mismatchedSegments;

  const PronunciationResult({
    required this.recognizedTranscript,
    required this.targetText,
    required this.accuracyScore,
    required this.isPassed,
    required this.feedbackVi,
    this.mismatchedSegments = const [],
  });
}
