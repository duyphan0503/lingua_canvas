import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import '../services/account_service.dart';
import '../models/profile_backup.dart';

class AccountSettingsCard extends StatefulWidget {
  final AccountService service;
  final VoidCallback? onAccountChanged;
  final VoidCallback? onProfileDataChanged;
  const AccountSettingsCard({
    super.key,
    required this.service,
    this.onAccountChanged,
    this.onProfileDataChanged,
  });
  @override
  State<AccountSettingsCard> createState() => _AccountSettingsCardState();
}

class _AccountSettingsCardState extends State<AccountSettingsCard> {
  Map<String, dynamic>? _account;
  List<Map<String, dynamic>> _devices = [];
  bool _busy = true;
  String? _error;
  ProfileBackup? _guestBackup;
  bool _guestTransferDone = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final account = await widget.service.currentAccount();
      if (!mounted) return;
      if (_account?['user_id'] != account?['user_id']) {
        _guestTransferDone = false;
      }
      setState(() {
        _account = account;
        _devices = ((account?['devices'] as List?) ?? [])
            .map((d) => Map<String, dynamic>.from(d as Map))
            .toList();
        _busy = false;
      });
      if (account != null && widget.service.matchesServer(account)) {
        await _loadGuestTransferOffer();
      } else if (mounted) {
        setState(() => _guestBackup = null);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Không thể đọc hồ sơ cục bộ. Vui lòng thử lại.';
        });
      }
    }
  }

  Future<void> _loadGuestTransferOffer() async {
    try {
      final backup = await widget.service.apiService.exportGuestBackup();
      if (!mounted) return;
      setState(() {
        _guestBackup = backup.privateLessons.isEmpty ? null : backup;
      });
    } catch (_) {
      // A missing or unavailable guest snapshot should not block account use.
      if (mounted) setState(() => _guestBackup = null);
    }
  }

  Future<void> _offerGuestTransfer() async {
    final source = _guestBackup;
    if (source == null || _busy) return;
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _GuestWordSelectionDialog(backup: source),
    );
    if (selected == null || selected.isEmpty || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final selectedBackup = await widget.service.apiService.exportGuestBackup(
        lessonIds: selected,
      );
      var preview = await widget.service.apiService.previewProfileBackup(
        selectedBackup,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      while (mounted) {
        final confirmed = await _confirmGuestMerge(preview);
        if (confirmed != true || !mounted) return;
        setState(() => _busy = true);
        try {
          await widget.service.apiService.mergeProfileBackup(preview);
          if (!mounted) return;
          widget.onProfileDataChanged?.call();
          if (!mounted) return;
          setState(() => _guestTransferDone = true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Đã gộp dữ liệu đã chọn. Hồ sơ khách ban đầu vẫn được giữ.',
              ),
            ),
          );
          return;
        } on StaleProfileMergeException {
          preview = await widget.service.apiService.previewProfileBackup(
            selectedBackup,
          );
          if (!mounted) return;
          setState(() {
            _busy = false;
            _error =
                'Hồ sơ đã thay đổi. Kiểm tra bản xem trước mới và xác nhận lại.';
          });
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is FormatException
              ? error.message
              : 'Chưa thể chuyển dữ liệu. Hồ sơ khách vẫn được giữ nguyên.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmGuestMerge(
    ProfileMergePreview preview,
  ) => showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Xem trước dữ liệu hồ sơ khách'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Thêm: ${preview.additions}'),
            Text('Cập nhật: ${preview.updates}'),
            Text('Bỏ qua: ${preview.skips}'),
            Text('Xung đột cần chọn: ${preview.conflicts}'),
            const SizedBox(height: 12),
            const Text(
              'Chỉ dữ liệu đã chọn được gộp. Bản gốc và hàng đợi của hồ sơ khách sẽ được giữ lại.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Để sau'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Xác nhận gộp'),
        ),
      ],
    ),
  );

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

  Future<void> _changeCredentials(bool changePin) async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _CredentialChangeDialog(changePin: changePin),
    );
    if (values == null || !mounted) return;
    await _run(
      () => changePin
          ? widget.service.changePin(
              currentPin: values['current_pin']!,
              newPin: values['new_pin']!,
            )
          : widget.service.rotateToken(currentPin: values['current_pin']!),
      changed: true,
    );
  }

  Future<void> _revokeDevice(Map<String, dynamic> device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Thu hồi thiết bị?'),
        content: Text(
          '${device['device_name']} sẽ cần liên kết lại để đồng bộ. '
          'Dữ liệu học cục bộ vẫn được giữ.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Thu hồi'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      () => widget.service.revokeDevice(device['device_id'] as String),
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
            if (kIsWeb)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Web lưu thông tin đăng nhập trong hồ sơ trình duyệt; '
                  'không có bảo vệ khóa hệ điều hành như Android/Linux. '
                  'Chỉ liên kết trên trình duyệt bạn tin cậy.',
                ),
              ),
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
              if (!mismatch && !_guestTransferDone && _guestBackup != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Từ hồ sơ khách trên thiết bị này',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_guestBackup!.privateLessons.length} từ cá nhân có thể được chuyển cùng tiến độ liên quan.',
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _offerGuestTransfer,
                        icon: const Icon(Icons.move_up_rounded, size: 16),
                        label: const Text('Xem và chọn dữ liệu để gộp'),
                      ),
                      const Text(
                        'Không có dữ liệu nào được chuyển nếu bạn chưa xác nhận.',
                        style: TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              for (final device in _devices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${device['device_name']} (${switch (device['platform']) {
                            'android' => 'Android',
                            'linux' => 'Linux Desktop',
                            'web' => 'Web Browser',
                            _ => 'Thiết bị khác',
                          }})\nLần cuối: ${device['last_seen_at'] ?? 'Chưa đồng bộ'} • Seq: ${device['last_sync_seq']}',
                        ),
                      ),
                      IconButton(
                        tooltip: 'Thu hồi thiết bị',
                        onPressed: _busy || mismatch
                            ? null
                            : () => _revokeDevice(device),
                        icon: const Icon(Icons.link_off),
                      ),
                    ],
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _busy || mismatch
                        ? null
                        : () => _changeCredentials(false),
                    child: const Text('Đổi Sync Token'),
                  ),
                  OutlinedButton(
                    onPressed: _busy || mismatch
                        ? null
                        : () => _changeCredentials(true),
                    child: const Text('Đổi PIN'),
                  ),
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

class _CredentialChangeDialog extends StatefulWidget {
  final bool changePin;
  const _CredentialChangeDialog({required this.changePin});
  @override
  State<_CredentialChangeDialog> createState() =>
      _CredentialChangeDialogState();
}

class _CredentialChangeDialogState extends State<_CredentialChangeDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.changePin ? 'Đổi PIN' : 'Đổi Sync Token'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.changePin
                ? 'Đổi PIN sẽ đăng xuất các phiên khác. Thiết bị này nhận Sync Token mới.'
                : 'Sync Token hiện tại sẽ hết hiệu lực. Thiết bị này nhận token mới.',
          ),
          TextField(
            controller: _current,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'PIN hiện tại'),
          ),
          if (widget.changePin)
            TextField(
              controller: _next,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'PIN mới'),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'current_pin': _current.text,
          if (widget.changePin) 'new_pin': _next.text,
        }),
        child: const Text('Xác nhận'),
      ),
    ],
  );
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

class _GuestWordSelectionDialog extends StatefulWidget {
  final ProfileBackup backup;
  const _GuestWordSelectionDialog({required this.backup});

  @override
  State<_GuestWordSelectionDialog> createState() =>
      _GuestWordSelectionDialogState();
}

class _GuestWordSelectionDialogState extends State<_GuestWordSelectionDialog> {
  late final Set<String> _selected = {
    for (final state in widget.backup.privateLessons) state.lesson.id,
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Chọn từ cần gộp'),
    content: SizedBox(
      width: 520,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Text(
              'Tiến độ và lịch sử liên quan sẽ đi cùng từng từ được chọn.',
            ),
            const SizedBox(height: 8),
            for (final state in widget.backup.privateLessons)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _selected.contains(state.lesson.id),
                title: Text(state.lesson.targetText),
                subtitle: Text(
                  state.deleted
                      ? 'Đã xóa • ${state.lesson.meaningVi}'
                      : state.lesson.meaningVi,
                ),
                onChanged: (selected) => setState(() {
                  if (selected == true) {
                    _selected.add(state.lesson.id);
                  } else {
                    _selected.remove(state.lesson.id);
                  }
                }),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      FilledButton(
        onPressed: _selected.isEmpty
            ? null
            : () => Navigator.pop(context, Set<String>.of(_selected)),
        child: const Text('Xem trước'),
      ),
    ],
  );
}
