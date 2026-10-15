abstract interface class BrowserSpeechBridge {
  bool get available;
  Future<void> start(
    String language, {
    required void Function(String transcript) onFinal,
    required void Function(String code, String message) onError,
  });
  Future<void> abort();
}
