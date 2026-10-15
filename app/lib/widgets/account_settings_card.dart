import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/account_service.dart';

class AccountSettingsCard extends StatefulWidget {
  final AccountService service;
  final VoidCallback? onAccountChanged;
  const AccountSettingsCard({
    super.key,
    required this.service,
    this.onAccountChanged,
  });
  @override
  State<AccountSettingsCard> createState() => _AccountSettingsCardState();
}

class _AccountSettingsCardState extends State<AccountSettingsCard> {
  Map<String, dynamic>? _account;
  List<Map<String, dynamic>> _devices = [];
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final account = await widget.service.currentAccount();
      if (!mounted) return;
      setState(() {
        _account = account;
        _devices = ((account?['devices'] as List?) ?? [])
            .map((d) => Map<String, dynamic>.from(d as Map))
            .toList();
        _busy = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Không thể đọc hồ sơ cục bộ. Vui lòng thử lại.';
        });
      }
    }
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool changed = false,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      if (changed) await _load();
      if (changed && mounted) widget.onAccountChanged?.call();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is AccountException
              ? error.message
              : 'Không thể kết nối tài khoản. Vui lòng thử lại.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _authenticate(bool register) async {
    final credentials = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _AccountDialog(register: register),
    );
    if (credentials == null || !mounted) return;
    await _run(
      () => register
          ? widget.service.register(
              username: credentials['username']!,
              pin: credentials['pin']!,
              displayName: credentials['display_name'],
            )
          : widget.service.login(
              username: credentials['username'],
              pin: credentials['pin'],
              syncToken: credentials['sync_token'],
            ),
      changed: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    final mismatch = account != null && !widget.service.matchesServer(account);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tài Khoản & Đồng Bộ Đa Thiết Bị (Android ↔ Linux ↔ Web)',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            if (account == null) ...[
              const Text('Đang dùng hồ sơ cục bộ (Chưa liên kết tài khoản)'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton(
                    onPressed: _busy ? null : () => _authenticate(true),
                    child: const Text('Tạo Tài Khoản Đồng Bộ'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _authenticate(false),
                    child: const Text('Liên Kết Thiết Bị Đã Có'),
                  ),
                ],
              ),
            ] else ...[
              Text('Username: ${account['username']}'),
              SelectableText(
                'User ID: ${account['user_id']}',
                style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12),
              ),
              if (mismatch) ...[
                const SizedBox(height: 8),
                const Text(
                  'Hồ sơ thuộc máy chủ khác. Liên kết lại với máy chủ hiện tại hoặc đăng xuất hồ sơ.',
                  style: TextStyle(color: Color(0xFFFBBF24)),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _authenticate(false),
                  child: const Text('Liên Kết Thiết Bị Đã Có'),
                ),
              ],
              const SizedBox(height: 8),
              for (final device in _devices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${device['device_name']} (${switch (device['platform']) {
                      'android' => 'Android',
                      'linux' => 'Linux Desktop',
                      'web' => 'Web Browser',
                      _ => 'Thiết bị khác',
                    }})\nLần cuối: ${device['last_seen_at'] ?? 'Chưa đồng bộ'} • Seq: ${device['last_sync_seq']}',
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy || mismatch
                        ? null
                        : () async {
                            await Clipboard.setData(
                              ClipboardData(
                                text: account['sync_token'] as String,
                              ),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Đã sao chép Sync Token.'),
                                ),
                              );
                            }
                          },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Sao chép Sync Token'),
                  ),
                  OutlinedButton(
                    onPressed: _busy || mismatch
                        ? null
                        : () => _run(() async {
                            final devices = await widget.service
                                .refreshDevices();
                            if (mounted) setState(() => _devices = devices);
                          }),
                    child: const Text('Cập nhật thiết bị'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(widget.service.logout, changed: true),
                    child: const Text('Đăng xuất hồ sơ'),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Color(0xFFF87171))),
            ],
          ],
        ),
      ),
    );
  }
}

class _AccountDialog extends StatefulWidget {
  final bool register;
  const _AccountDialog({required this.register});
  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  final _username = TextEditingController();
  final _pin = TextEditingController();
  final _name = TextEditingController();
  final _token = TextEditingController();
  bool _useToken = false;
  @override
  void dispose() {
    _username.dispose();
    _pin.dispose();
    _name.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.register ? 'Tạo Tài Khoản Đồng Bộ' : 'Liên Kết Thiết Bị Đã Có',
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.register)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Dùng Sync Token'),
              value: _useToken,
              onChanged: (value) => setState(() => _useToken = value),
            ),
          if (_useToken)
            TextField(
              controller: _token,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Sync Token'),
            )
          else ...[
            TextField(
              controller: _username,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            TextField(
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'PIN'),
            ),
            if (widget.register)
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Tên hiển thị (tùy chọn)',
                ),
              ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          _useToken
              ? {'sync_token': _token.text}
              : {
                  'username': _username.text,
                  'pin': _pin.text,
                  'display_name': _name.text,
                },
        ),
        child: Text(widget.register ? 'Tạo tài khoản' : 'Liên kết'),
      ),
    ],
  );
}
