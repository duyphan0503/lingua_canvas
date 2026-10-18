import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/backup_file_transport.dart';

class BackupSettingsPanel extends StatefulWidget {
  final ApiService apiService;
  final BackupFileTransport? transport;
  final VoidCallback? onProfileDataChanged;

  const BackupSettingsPanel({
    super.key,
    required this.apiService,
    this.transport,
    this.onProfileDataChanged,
  });

  @override
  State<BackupSettingsPanel> createState() => _BackupSettingsPanelState();
}

class _BackupSettingsPanelState extends State<BackupSettingsPanel> {
  late final BackupFileTransport _transport =
      widget.transport ?? createBackupFileTransport();
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;
  ProfileMergePreview? _preview;
  late Future<Map<String, dynamic>> _statsFuture;

  @override
  void initState() {
    super.initState();
    _statsFuture = widget.apiService.getFSRSStats();
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      // exportProfileBackup releases its profile lock before the file dialog.
      final backup = await widget.apiService.exportProfileBackup();
      final bytes = backup.toBytes();
      final saved = await _transport.saveBackup(
        bytes,
        suggestedName:
            'lingua-canvas-backup-${DateTime.now().toIso8601String().substring(0, 10)}.json',
      );
      if (!mounted) return;
      setState(() {
        _message = saved ? 'Đã lưu bản sao lưu.' : 'Đã hủy lưu tệp.';
        _messageIsError = false;
      });
    } catch (error) {
      _setError(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _message = null;
      _preview = null;
    });
    try {
      final Uint8List? bytes = await _transport.pickBackup();
      if (bytes == null) return;
      final backup = ProfileBackup.fromBytes(bytes);
      final preview = await widget.apiService.previewProfileBackup(backup);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _message = 'Kiểm tra nội dung trước khi gộp vào hồ sơ hiện tại.';
        _messageIsError = false;
      });
    } catch (error) {
      _setError(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmMerge(ProfileMergePreview preview) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Gộp bản sao lưu?'),
        content: Text(
          'Dữ liệu sẽ được gộp vào hồ sơ hiện tại theo mã từ. Hàng đợi đồng bộ và tiến độ ôn đang chờ được giữ lại. Lịch sử không chạy lại qua thuật toán ôn tập.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Quay lại'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Xác nhận gộp'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.apiService.mergeProfileBackup(preview);
      if (!mounted) return;
      widget.onProfileDataChanged?.call();
      if (!mounted) return;
      setState(() {
        _statsFuture = widget.apiService.getFSRSStats();
        _preview = null;
        _message = 'Đã gộp dữ liệu vào hồ sơ hiện tại.';
        _messageIsError = false;
      });
    } on StaleProfileMergeException {
      try {
        final refreshed = await widget.apiService.previewProfileBackup(
          preview.backup,
        );
        if (!mounted) return;
        setState(() {
          _preview = refreshed;
          _message =
              'Hồ sơ đã thay đổi. Hãy kiểm tra bản xem trước mới và xác nhận lại.';
          _messageIsError = true;
        });
      } catch (error) {
        _setError(_friendlyError(error));
      }
    } catch (error) {
      _setError(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(Object error) {
    if (error is FormatException) return error.message;
    if (error is BackupFileTransportException) return error.message;
    return 'Không thể hoàn tất thao tác. Kiểm tra dung lượng rồi thử lại.';
  }

  void _setError(String message) {
    if (mounted) {
      setState(() {
        _message = message;
        _messageIsError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.backup_outlined,
                size: 18,
                color: Color(0xFF38BDF8),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Sao lưu & khôi phục',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Cập nhật trạng thái đồng bộ',
                visualDensity: VisualDensity.compact,
                onPressed: _busy
                    ? null
                    : () => setState(
                        () => _statsFuture = widget.apiService.getFSRSStats(),
                      ),
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Tệp sao lưu gồm từ cá nhân và tiến độ của hồ sơ hiện tại. Thông tin đăng nhập và cấu hình máy chủ không được đưa vào tệp.',
            style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _export,
                icon: const Icon(Icons.save_alt_rounded, size: 16),
                label: const Text('Xuất bản sao lưu'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _import,
                icon: const Icon(Icons.file_open_rounded, size: 16),
                label: const Text('Nhập sao lưu'),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
          ],
          if (_preview case final preview?) ...[
            const SizedBox(height: 12),
            _PreviewCounts(preview: preview),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : () => _confirmMerge(preview),
              icon: const Icon(Icons.merge_type_rounded),
              label: const Text('Gộp dữ liệu đã xem trước'),
            ),
          ],
          FutureBuilder<Map<String, dynamic>>(
            future: _statsFuture,
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const SizedBox.shrink();
              final stats = snapshot.data!;
              final pending =
                  (stats['pending_review_mutations'] as num? ?? 0) +
                  (stats['pending_private_lesson_mutations'] as num? ?? 0) +
                  (stats['pending_progress_imports'] as num? ?? 0);
              final conflicts = stats['private_lesson_conflicts'] ?? 0;
              final retry = stats['retry_sync_mutations'] ?? 0;
              final upgrade = stats['private_sync_upgrade_required'] == true;
              final error = stats['sync_queue_error'];
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Đang chờ đồng bộ: $pending • Xung đột từ: $conflicts • Thử lại: $retry',
                      style: const TextStyle(
                        color: Color(0xFFCBD5E1),
                        fontSize: 12,
                      ),
                    ),
                    if (upgrade)
                      const Text(
                        'Máy chủ cần được nâng cấp để đồng bộ từ cá nhân. Dữ liệu đang chờ vẫn được giữ.',
                        style: TextStyle(
                          color: Color(0xFFFBBF24),
                          fontSize: 12,
                        ),
                      ),
                    if (error is String && error.isNotEmpty)
                      Text(
                        'Đồng bộ đang chờ xử lý: $error',
                        style: const TextStyle(
                          color: Color(0xFFFBBF24),
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          if (_message != null) ...[
            const SizedBox(height: 8),
            Text(
              _message!,
              key: const Key('backup-message'),
              style: TextStyle(
                color: _messageIsError
                    ? const Color(0xFFFBBF24)
                    : const Color(0xFF34D399),
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PreviewCounts extends StatelessWidget {
  final ProfileMergePreview preview;
  const _PreviewCounts({required this.preview});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF0F172A),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFF334155)),
    ),
    child: Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        Text('Thêm: ${preview.additions}'),
        Text('Cập nhật: ${preview.updates}'),
        Text('Bỏ qua: ${preview.skips}'),
        Text('Xung đột: ${preview.conflicts}'),
      ],
    ),
  );
}
