import 'platform_identity_native.dart'
    if (dart.library.js_interop) 'platform_identity_web.dart'
    as identity;

String normalizeApiBaseUrl(
  String value, {
  required bool isWeb,
  required Uri pageUri,
}) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'Địa chỉ máy chủ phải là URL HTTP hoặc HTTPS hợp lệ.',
    );
  }
  if (isWeb && pageUri.scheme == 'https' && uri.scheme != 'https') {
    throw const FormatException('Trang HTTPS cần máy chủ API HTTPS.');
  }
  return uri.toString().replaceFirst(RegExp(r'/+$'), '');
}

String resolveApiBaseUrl({
  required bool isWeb,
  required Uri pageUri,
  String configured = '',
}) => normalizeApiBaseUrl(
  configured.isNotEmpty
      ? configured
      : isWeb
      ? '${pageUri.origin}/api/v1'
      : 'http://127.0.0.1:8080/api/v1',
  isWeb: isWeb,
  pageUri: pageUri,
);
String devicePlatform() => identity.currentDevicePlatform();
String deviceName() => switch (devicePlatform()) {
  'web' => 'Web Browser',
  'android' => 'Android',
  _ => 'Linux Desktop',
};
