import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/account_service.dart';
import '../widgets/account_settings_card.dart';

class SettingsScreen extends StatefulWidget {
  final ApiService? apiService;
  final VoidCallback? onResetData;
  final AccountService? accountService;
  final VoidCallback? onAccountChanged;

  const SettingsScreen({
    super.key,
    this.apiService,
    this.onResetData,
    this.accountService,
    this.onAccountChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final ApiService _apiService;
  late final AccountService _accountService;
  final TextEditingController _urlController = TextEditingController();
  bool _isChecking = false;
  bool? _isServerHealthy;
  String? _healthStatusText;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? ApiService();
    _accountService =
        widget.accountService ?? AccountService(apiService: _apiService);
    _urlController.text = _apiService.baseUrl;
    _checkServer();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _checkServer() async {
    setState(() {
      _isChecking = true;
      _healthStatusText = 'Đang kiểm tra kết nối...';
    });

    final isHealthy = await _apiService.checkBackendHealth();
    if (mounted) {
      setState(() {
        _isChecking = false;
        _isServerHealthy = isHealthy;
        _healthStatusText = isHealthy
            ? 'Kết nối Máy chủ Rust Axum thành công (Healthy) ⚡'
            : 'Máy chủ đang Offline hoặc không phản hồi (Sử dụng Offline Mode).';
      });
    }
  }

  Future<void> _saveUrl(String newUrl) async {
    try {
      await _apiService.configureServer(newUrl.trim());
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is FormatException
                ? 'Địa chỉ máy chủ không hợp lệ. Nhập URL http hoặc https đầy đủ.'
                : 'Không thể áp dụng máy chủ. Kiểm tra bộ nhớ rồi thử lại.',
          ),
          backgroundColor: const Color(0xFF991B1B),
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() {});
    _checkServer();
    widget.onAccountChanged?.call();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đã cập nhật API Base URL: $newUrl'),
        backgroundColor: const Color(0xFF065F46),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.settings_rounded, color: Color(0xFF94A3B8), size: 22),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Cài Đặt & Kết Nối Hệ Thống',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildServerConfigSection(),
          const SizedBox(height: 16),
          AccountSettingsCard(
            key: ValueKey(_apiService.baseUrl),
            service: _accountService,
            onAccountChanged: widget.onAccountChanged,
          ),
          const SizedBox(height: 16),
          _buildAIEngineSection(),
          const SizedBox(height: 16),
          _buildStorageManagementSection(),
          const SizedBox(height: 16),
          _buildAboutSection(),
        ],
      ),
    );
  }

  Widget _buildServerConfigSection() {
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
          const Row(
            children: [
              Icon(Icons.dns_rounded, size: 18, color: Color(0xFF38BDF8)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Địa Chỉ Máy Chủ Backend (Rust Axum)',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'monospace',
            ),
            decoration: InputDecoration(
              labelText: 'API Base URL',
              labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
              filled: true,
              fillColor: const Color(0xFF0F172A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF334155)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF334155)),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Presets
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _buildPresetChip(
                'Localhost (127.0.0.1:8080)',
                'http://127.0.0.1:8080/api/v1',
              ),
              _buildPresetChip(
                'USB / adb reverse (127.0.0.1:8080)',
                'http://127.0.0.1:8080/api/v1',
              ),
              _buildPresetChip(
                'Wi-Fi LAN IP (192.168.1.48:8080)',
                'http://192.168.1.48:8080/api/v1',
              ),
              _buildPresetChip(
                'Emulator (10.0.2.2:8080)',
                'http://10.0.2.2:8080/api/v1',
              ),
            ],
          ),
          const SizedBox(height: 12),

          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: () => _saveUrl(_urlController.text),
                icon: const Icon(Icons.save_rounded, size: 16),
                label: const Text('Lưu & Áp dụng'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4F46E5),
                  foregroundColor: Colors.white,
                ),
              ),
              OutlinedButton.icon(
                onPressed: _isChecking ? null : _checkServer,
                icon: _isChecking
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.network_check_rounded, size: 16),
                label: const Text('Kiểm tra kết nối'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF38BDF8),
                ),
              ),
            ],
          ),
          if (_healthStatusText != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _isServerHealthy == true
                    ? const Color(0x33059669)
                    : const Color(0x33DC2626),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _isServerHealthy == true
                      ? const Color(0xFF059669)
                      : const Color(0xFFDC2626),
                ),
              ),
              child: Text(
                _healthStatusText!,
                style: TextStyle(
                  fontSize: 12,
                  color: _isServerHealthy == true
                      ? const Color(0xFF34D399)
                      : const Color(0xFFF87171),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPresetChip(String label, String url) {
    return ActionChip(
      label: Text(
        label,
        style: const TextStyle(fontSize: 11, color: Color(0xFFCBD5E1)),
      ),
      backgroundColor: const Color(0xFF0F172A),
      side: const BorderSide(color: Color(0xFF334155)),
      onPressed: () {
        _urlController.text = url;
        _saveUrl(url);
      },
    );
  }

  Widget _buildAIEngineSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.psychology_alt_rounded,
                size: 18,
                color: Color(0xFF818CF8),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Mô Hình AI & Nhận Diện',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          _SettingInfoRow(
            label: 'Local LLM Engine',
            value: 'Llama.cpp (OpenAI-compatible) + Matrix Fallback',
          ),
          _SettingInfoRow(
            label: 'Nhận diện nét viết (Handwriting)',
            value: 'Google ML Kit On-device + Heuristic Engine',
          ),
          _SettingInfoRow(
            label: 'Thuật toán lặp lại ngắt quãng',
            value: 'FSRS v4 (Free Spaced Repetition Scheduler)',
          ),
        ],
      ),
    );
  }

  Widget _buildStorageManagementSection() {
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
          const Row(
            children: [
              Icon(Icons.storage_rounded, size: 18, color: Color(0xFFF59E0B)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Bộ Nhớ Cục Bộ (SQLite Database)',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Dữ liệu bài học, thẻ FSRS và tiến độ ôn tập được lưu trữ an toàn trong SQLite cục bộ trên thiết bị của bạn.',
            style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: const Color(0xFF1E293B),
                    title: const Text('Xác nhận đặt lại dữ liệu?'),
                    content: const Text(
                      'Toàn bộ lịch sử ôn tập cục bộ sẽ được xóa và khởi tạo lại theo mặc định.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Hủy'),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFEF4444),
                        ),
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Xác nhận Xóa'),
                      ),
                    ],
                  ),
                );

                if (confirmed == true) {
                  await _apiService.localDatabase.clearAll();
                  if (widget.onResetData != null) widget.onResetData!();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Đã đặt lại cơ sở dữ liệu SQLite thành công.',
                        ),
                      ),
                    );
                  }
                }
              },
              icon: const Icon(
                Icons.delete_outline_rounded,
                size: 16,
                color: Color(0xFFEF4444),
              ),
              label: const Text(
                'Đặt lại cơ sở dữ liệu',
                style: TextStyle(color: Color(0xFFEF4444), fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAboutSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: Color(0xFF94A3B8),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Thông Tin Ứng Dụng',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          _SettingInfoRow(
            label: 'Ứng dụng',
            value: 'Lingua Canvas — Smart Language Studio',
          ),
          _SettingInfoRow(label: 'Phiên bản', value: 'v0.2.0 (Phase 2 Pro)'),
          _SettingInfoRow(
            label: 'Kiến trúc',
            value: 'Flutter Client • Rust Axum Backend • Local AI',
          ),
          _SettingInfoRow(
            label: 'Bản quyền',
            value: '© 2026 Duy Phan (duyphan0503)',
          ),
        ],
      ),
    );
  }
}

class _SettingInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _SettingInfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label:',
            style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFFE2E8F0),
            ),
          ),
        ],
      ),
    );
  }
}
