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

  const PronunciationResult({
    required this.recognizedTranscript,
    required this.targetText,
    required this.accuracyScore,
    required this.isPassed,
    required this.feedbackVi,
  });
}
