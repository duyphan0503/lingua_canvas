import 'dart:convert';
import 'platform_capabilities.dart';
import 'package:http/http.dart' as http;
import 'api_service.dart';

class AccountException implements Exception {
  final String message;
  const AccountException(this.message);
  @override
  String toString() => message;
}

/// Credentials belong to one configured server and never include the PIN.
class AccountService {
  final ApiService apiService;
  final http.Client? _httpClient;
  AccountService({required this.apiService, http.Client? httpClient})
    : _httpClient = httpClient;

  Future<Map<String, dynamic>?> currentAccount() =>
      apiService.localDatabase.getAccount();

  bool matchesServer(Map<String, dynamic> account) =>
      account['server_url'] == apiService.baseUrl;

  Future<Map<String, String>> currentHeaders({String? serverUrl}) async {
    final account = await currentAccount();
    if (account == null ||
        account['server_url'] != (serverUrl ?? apiService.baseUrl)) {
      return {};
    }
    final token = account['sync_token'];
    if (token is! String || !_validToken(token)) return {};
    return {'X-Sync-Token': token};
  }

  Future<void> register({
    required String username,
    required String pin,
    String? displayName,
  }) async {
    _validateCredentials(username, pin);
    await _authenticate('register', {
      'username': username.trim(),
      'pin': pin,
      'display_name': displayName?.trim().isNotEmpty == true
          ? displayName!.trim()
          : username.trim(),
    });
  }

  Future<void> login({String? username, String? pin, String? syncToken}) async {
    if (syncToken != null) {
      if (!_validToken(syncToken.trim())) {
        throw const AccountException('Sync Token không hợp lệ.');
      }
      await _authenticate('login', {'sync_token': syncToken.trim()});
    } else {
      _validateCredentials(username ?? '', pin ?? '');
      await _authenticate('login', {'username': username!.trim(), 'pin': pin});
    }
  }

  void _validateCredentials(String username, String pin) {
    if (!RegExp(r'^[A-Za-z0-9_-]{3,32}$').hasMatch(username.trim())) {
      throw const AccountException(
        'Username cần 3–32 ký tự: chữ, số, _ hoặc -.',
      );
    }
    if (!RegExp(r'^[0-9]{4,12}$').hasMatch(pin)) {
      throw const AccountException('PIN cần 4–12 chữ số.');
    }
  }

  static bool _validToken(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{4,256}$').hasMatch(value);

  Future<void> _authenticate(
    String endpoint,
    Map<String, dynamic> credentials,
  ) async {
    final baseUrl = apiService.baseUrl;
    final generation = await apiService.localDatabase.getMetadata(
      '__generation',
    );
    final deviceId = await apiService.localDatabase.getOrCreateClientId();
    final platform = devicePlatform();
    final body = jsonEncode({
      ...credentials,
      'device_id': deviceId,
      'platform': platform,
      'device_name': deviceName(),
    });
    final uri = Uri.parse('$baseUrl/auth/$endpoint');
    final response = await sendRequest(
      method: 'POST',
      uri: uri,
      client: _httpClient,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );
    _checkStatus(response);
    final payload = _object(response.body);
    for (final field in ['user_id', 'username', 'display_name', 'sync_token']) {
      if (payload[field] is! String || (payload[field] as String).isEmpty) {
        throw const AccountException('Máy chủ trả về tài khoản không hợp lệ.');
      }
    }
    if (!_validToken(payload['sync_token'] as String)) {
      throw const AccountException('Máy chủ trả về Sync Token không hợp lệ.');
    }
    final devices = _devices(payload['devices']);
    if (apiService.baseUrl != baseUrl) {
      throw const AccountException(
        'Máy chủ đã thay đổi. Vui lòng liên kết lại.',
      );
    }
    await apiService.localDatabase.withProfileLock(() async {
      final currentGeneration = await apiService.localDatabase.getMetadata(
        '__generation',
      );
      if (apiService.baseUrl != baseUrl || currentGeneration != generation) {
        throw const AccountException(
          'Hồ sơ đã thay đổi. Vui lòng liên kết lại.',
        );
      }
      await apiService.localDatabase.switchAccount({
        'user_id': payload['user_id'],
        'username': payload['username'],
        'display_name': payload['display_name'],
        'sync_token': payload['sync_token'],
        'devices': devices,
        'server_url': baseUrl,
      });
      apiService.syncCoordinator.lastSyncTime = null;
    });
  }

  Future<void> rotateToken({required String currentPin}) =>
      _changeCredentials('token/rotate', {'current_pin': currentPin});

  Future<void> changePin({
    required String currentPin,
    required String newPin,
  }) async {
    _validatePin(newPin);
    await _changeCredentials('pin/change', {
      'current_pin': currentPin,
      'new_pin': newPin,
    });
  }

  static void _validatePin(String pin) {
    if (!RegExp(r'^[0-9]{4,12}$').hasMatch(pin)) {
      throw const AccountException('PIN cần 4–12 chữ số.');
    }
  }

  Future<void> _changeCredentials(
    String endpoint,
    Map<String, String> body,
  ) async {
    _validatePin(body['current_pin']!);
    await apiService.localDatabase.withProfileLock(() async {
      final baseUrl = apiService.baseUrl;
      final account = await _requireAccount(baseUrl);
      _checkServer(baseUrl);
      final response = await sendRequest(
        method: 'POST',
        uri: Uri.parse('$baseUrl/auth/$endpoint'),
        client: _httpClient,
        headers: {
          'X-Sync-Token': account['sync_token'] as String,
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      _checkStatus(response);
      _checkServer(baseUrl);
      final payload = _object(response.body);
      for (final field in [
        'user_id',
        'username',
        'display_name',
        'sync_token',
      ]) {
        if (payload[field] is! String || (payload[field] as String).isEmpty) {
          throw const AccountException(
            'Máy chủ trả về tài khoản không hợp lệ.',
          );
        }
      }
      if (payload['user_id'] != account['user_id'] ||
          !_validToken(payload['sync_token'] as String)) {
        throw const AccountException('Máy chủ trả về tài khoản không hợp lệ.');
      }
      final devices = _devices(payload['devices']);
      try {
        await apiService.localDatabase.switchAccount({
          for (final field in [
            'user_id',
            'username',
            'display_name',
            'sync_token',
          ])
            field: payload[field],
          'devices': devices,
          'server_url': baseUrl,
        });
      } catch (_) {
        throw const AccountException(
          'Máy chủ đã đổi thông tin đăng nhập nhưng kho an toàn chưa lưu được. '
          'Dữ liệu học vẫn được giữ. Hãy liên kết lại bằng PIN.',
        );
      }
      apiService.syncCoordinator.lastSyncTime = null;
    });
  }

  Future<Map<String, dynamic>> _requireAccount(String baseUrl) async {
    final account = await currentAccount();
    if (account == null ||
        account['server_url'] != baseUrl ||
        account['sync_token'] is! String ||
        !_validToken(account['sync_token'] as String)) {
      throw const AccountException(
        'Liên kết lại tài khoản với máy chủ hiện tại.',
      );
    }
    return account;
  }

  void _checkServer(String baseUrl) {
    if (apiService.baseUrl != baseUrl) {
      throw const AccountException(
        'Máy chủ đã thay đổi. Vui lòng liên kết lại.',
      );
    }
  }

  Future<void> revokeDevice(String deviceId) async {
    if (deviceId.isEmpty || deviceId.length > 256) {
      throw const AccountException('Thiết bị không hợp lệ.');
    }
    await apiService.localDatabase.withProfileLock(() async {
      final baseUrl = apiService.baseUrl;
      final account = await _requireAccount(baseUrl);
      _checkServer(baseUrl);
      final response = await sendRequest(
        method: 'DELETE',
        uri: Uri.parse(
          '$baseUrl/auth/devices/${Uri.encodeComponent(deviceId)}',
        ),
        client: _httpClient,
        headers: {'X-Sync-Token': account['sync_token'] as String},
      );
      if (response.statusCode != 204) {
        _checkStatus(response);
        throw const AccountException('Máy chủ chưa xác nhận thu hồi thiết bị.');
      }
      _checkServer(baseUrl);
      if (deviceId == await apiService.localDatabase.getOrCreateClientId()) {
        await apiService.localDatabase.switchAccount(null);
        apiService.syncCoordinator.lastSyncTime = null;
      } else {
        await apiService.localDatabase.switchAccount({
          ...account,
          'devices': (account['devices'] as List)
              .where((device) => device['device_id'] != deviceId)
              .toList(),
        });
      }
    });
  }

  Future<List<Map<String, dynamic>>> refreshDevices() async {
    return apiService.localDatabase.withProfileLock(() async {
      final account = await currentAccount();
      if (account == null || !matchesServer(account)) {
        throw const AccountException(
          'Liên kết lại tài khoản với máy chủ hiện tại hoặc đăng xuất hồ sơ.',
        );
      }
      final baseUrl = apiService.baseUrl;
      final headers = await currentHeaders(serverUrl: baseUrl);
      if (headers.isEmpty) {
        throw const AccountException('Sync Token không hợp lệ.');
      }
      final uri = Uri.parse('$baseUrl/auth/devices');
      final response = await sendRequest(
        method: 'GET',
        uri: uri,
        client: _httpClient,
        headers: headers,
      );
      _checkStatus(response);
      _checkServer(baseUrl);
      return _devices(_object(response.body)['devices']);
    });
  }

  Future<void> logout() => apiService.syncCoordinator.changeAccount(null);

  /// Redirect responses are handled as errors: credentials must stay on the
  /// explicitly configured server, including when that server redirects.
  static Future<http.Response> sendRequest({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
    http.Client? client,
  }) async {
    final transport = client ?? http.Client();
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll(headers);
    if (body != null) request.body = body;
    try {
      final streamed = await transport
          .send(request)
          .timeout(const Duration(seconds: 12));
      return await http.Response.fromStream(
        streamed,
      ).timeout(const Duration(seconds: 12));
    } finally {
      if (client == null) transport.close();
    }
  }

  static Map<String, dynamic> _object(String body) {
    try {
      final value = jsonDecode(body);
      if (value is Map<String, dynamic>) return value;
    } catch (_) {
      /* Converted to a safe user-facing error below. */
    }
    throw const AccountException('Dữ liệu máy chủ không hợp lệ.');
  }

  static List<Map<String, dynamic>> _devices(dynamic value) {
    if (value is! List) {
      throw const AccountException('Danh sách thiết bị không hợp lệ.');
    }
    return value.map((device) {
      if (device is! Map<String, dynamic> ||
          device['device_id'] is! String ||
          device['platform'] is! String ||
          device['device_name'] is! String ||
          device['last_sync_seq'] is! int ||
          (device['last_seen_at'] != null &&
              device['last_seen_at'] is! String)) {
        throw const AccountException('Thông tin thiết bị không hợp lệ.');
      }
      return Map<String, dynamic>.from(device);
    }).toList();
  }

  static void _checkStatus(http.Response response) {
    if (response.statusCode == 200 || response.statusCode == 201) return;
    throw AccountException(switch (response.statusCode) {
      401 || 403 => 'Thông tin đăng nhập không đúng.',
      409 => 'Username đã được sử dụng.',
      429 => 'Quá nhiều yêu cầu. Vui lòng thử lại sau.',
      _ => 'Không thể kết nối tài khoản (HTTP ${response.statusCode}).',
    });
  }
}
