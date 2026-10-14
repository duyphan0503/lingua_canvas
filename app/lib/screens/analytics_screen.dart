import 'package:flutter/material.dart';
import '../models/lesson_item.dart';
import '../services/api_service.dart';

class AnalyticsScreen extends StatefulWidget {
  final ApiService? apiService;
  final Function(LessonItem lesson)? onPracticeDueLesson;

  const AnalyticsScreen({super.key, this.apiService, this.onPracticeDueLesson});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  late final ApiService _apiService;
  Map<String, dynamic>? _stats;
  StudyStreak? _streak;
  List<LessonItem> _dueLessons = [];
  bool _isLoading = true;
  bool _isSyncing = false;
  String? _syncMessage;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? ApiService();
    _loadAnalytics();
  }

  Future<void> _loadAnalytics() async {
    setState(() => _isLoading = true);
    try {
      final stats = await _apiService.getFSRSStats();
      final due = await _apiService.getDueLessons();
      final streak = await _apiService.getStudyStreak();
      if (mounted) {
        setState(() {
          _stats = stats;
          _dueLessons = due;
          _streak = streak;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _triggerManualSync() async {
    setState(() {
      _isSyncing = true;
      _syncMessage = null;
    });

    try {
      final result = await _apiService.sync();
      await _loadAnalytics();
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _syncMessage = result.success
              ? 'Đồng bộ hoàn tất! (Đẩy: ${result.syncedReviews}, Nhận: ${result.pulledCards})'
              : 'Đồng bộ ngoại tuyến (Đang lưu cục bộ)';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _syncMessage = 'Không thể kết nối đến máy chủ Rust.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.analytics_rounded, color: Color(0xFF34D399), size: 22),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Thống Kê & Trí Nhớ FSRS',
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
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF94A3B8)),
            tooltip: 'Làm mới thống kê',
            onPressed: _loadAnalytics,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF34D399)),
            )
          : RefreshIndicator(
              onRefresh: _loadAnalytics,
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  _buildQuietStreakCard(),
                  const SizedBox(height: 14),
                  _buildRetentionOverviewCard(),
                  const SizedBox(height: 14),
                  _buildMetricsGrid(),
                  const SizedBox(height: 14),
                  _buildStateBreakdownCard(),
                  const SizedBox(height: 14),
                  _buildSyncStatusCard(),
                  const SizedBox(height: 14),
                  _buildDueQueueSection(),
                ],
              ),
            ),
    );
  }

  Widget _buildQuietStreakCard() {
    final currentStreak = _streak?.currentStreak ?? 0;
    final longestStreak = _streak?.longestStreak ?? 0;
    final history = _streak?.activityHistory ?? {};

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final List<MapEntry<DateTime, int>> last14Days = [];
    int totalReviewed = 0;

    for (int i = 13; i >= 0; i--) {
      final date = DateTime(today.year, today.month, today.day - i);
      final key =
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final count = history[key] ?? 0;
      last14Days.add(MapEntry(date, count));
      totalReviewed += count;
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF131B2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0x26F59E0B),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0x4DF59E0B)),
                ),
                child: const Icon(
                  Icons.local_fire_department_rounded,
                  color: Color(0xFFF59E0B),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Chuỗi ngày học tập: $currentStreak ngày liên tục 🔥',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Kỷ lục: $longestStreak ngày  •  14 ngày qua: $totalReviewed thẻ đã ôn',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  'Lịch sử ôn tập (14 ngày)',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFCBD5E1),
                  ),
                ),
              ),
              Text(
                'Hôm nay: ${last14Days.last.value} thẻ',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: last14Days.last.value > 0
                      ? const Color(0xFF34D399)
                      : const Color(0xFF64748B),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildHeatmapGrid(last14Days),
        ],
      ),
    );
  }

  Widget _buildHeatmapGrid(List<MapEntry<DateTime, int>> days) {
    int maxCount = 1;
    for (final e in days) {
      if (e.value > maxCount) maxCount = e.value;
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: days.asMap().entries.map((entry) {
            final idx = entry.key;
            final date = entry.value.key;
            final count = entry.value.value;
            final isToday = idx == days.length - 1;

            Color barColor;
            if (count == 0) {
              barColor = const Color(0xFF1E293B);
            } else if (count <= 3) {
              barColor = const Color(0xFF065F46);
            } else if (count <= 8) {
              barColor = const Color(0xFF059669);
            } else if (count <= 15) {
              barColor = const Color(0xFF10B981);
            } else {
              barColor = const Color(0xFF34D399);
            }

            final double barHeight = count == 0
                ? 8.0
                : (12.0 + (count / maxCount) * 26.0).clamp(12.0, 38.0);

            return Container(
              width: 22,
              margin: const EdgeInsets.symmetric(horizontal: 2.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 14,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        count > 0 ? '$count' : '',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: isToday
                              ? const Color(0xFF34D399)
                              : const Color(0xFF94A3B8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Tooltip(
                    message: '${date.day}/${date.month}: $count thẻ',
                    child: Container(
                      height: barHeight,
                      decoration: BoxDecoration(
                        color: barColor,
                        borderRadius: BorderRadius.circular(4),
                        border: isToday
                            ? Border.all(
                                color: const Color(0xFF34D399),
                                width: 1.2,
                              )
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      isToday
                          ? 'Nay'
                          : const [
                              'T2',
                              'T3',
                              'T4',
                              'T5',
                              'T6',
                              'T7',
                              'CN',
                            ][date.weekday - 1],
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: isToday
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isToday
                            ? const Color(0xFF34D399)
                            : const Color(0xFF64748B),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildRetentionOverviewCard() {
    final retention = _stats?['estimated_retention'] ?? 85;
    final avgStability = ((_stats?['avg_stability'] as num?)?.toDouble() ?? 0.0)
        .toStringAsFixed(1);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E1B4B), Color(0xFF1E293B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF4338CA)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.psychology_rounded,
                      color: Color(0xFF818CF8),
                      size: 20,
                    ),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Ước tính Tỷ lệ Ghi nhớ',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFFCBD5E1),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '$retention%',
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF34D399),
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Độ bền trí nhớ trung bình: $avgStability ngày',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF94A3B8),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0x334F46E5),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF6366F1), width: 2),
            ),
            child: const Icon(
              Icons.auto_graph_rounded,
              color: Color(0xFF818CF8),
              size: 36,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsGrid() {
    final totalCards = _stats?['total_cards'] ?? 0;
    final totalCompleted = _stats?['total_completed'] ?? 0;
    final dueToday = _stats?['due_today'] ?? 0;

    return Row(
      children: [
        Expanded(
          child: _buildMetricTile(
            label: 'Tổng thẻ từ',
            value: '$totalCards',
            icon: Icons.layers_rounded,
            color: const Color(0xFF38BDF8),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildMetricTile(
            label: 'Cần ôn hôm nay',
            value: '$dueToday',
            icon: Icons.schedule_rounded,
            color: const Color(0xFFF59E0B),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildMetricTile(
            label: 'Đã hoàn thành',
            value: '$totalCompleted',
            icon: Icons.task_alt_rounded,
            color: const Color(0xFF10B981),
          ),
        ),
      ],
    );
  }

  Widget _buildMetricTile({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
          ),
        ],
      ),
    );
  }

  Widget _buildStateBreakdownCard() {
    final breakdown = _stats?['state_breakdown'] as Map<String, dynamic>? ?? {};
    final newCount = breakdown['new'] ?? 0;
    final learningCount = breakdown['learning'] ?? 0;
    final reviewCount = breakdown['review'] ?? 0;
    final relearningCount = breakdown['relearning'] ?? 0;
    final total = (newCount + learningCount + reviewCount + relearningCount)
        .clamp(1, 999999);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Phân bố Trạng thái Thẻ FSRS',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          // Multi-color progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 10,
              child: Row(
                children: [
                  Expanded(
                    flex: (newCount * 100 ~/ total).clamp(0, 100),
                    child: Container(color: const Color(0xFF94A3B8)),
                  ),
                  Expanded(
                    flex: (learningCount * 100 ~/ total).clamp(0, 100),
                    child: Container(color: const Color(0xFFF59E0B)),
                  ),
                  Expanded(
                    flex: (reviewCount * 100 ~/ total).clamp(0, 100),
                    child: Container(color: const Color(0xFF10B981)),
                  ),
                  Expanded(
                    flex: (relearningCount * 100 ~/ total).clamp(0, 100),
                    child: Container(color: const Color(0xFFEF4444)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              _buildLegendItem(
                'Mới (New)',
                '$newCount',
                const Color(0xFF94A3B8),
              ),
              _buildLegendItem(
                'Đang học (Learning)',
                '$learningCount',
                const Color(0xFFF59E0B),
              ),
              _buildLegendItem(
                'Ôn tập (Review)',
                '$reviewCount',
                const Color(0xFF10B981),
              ),
              _buildLegendItem(
                'Học lại (Lapses)',
                '$relearningCount',
                const Color(0xFFEF4444),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(String label, String count, Color color) {
    return Wrap(
      spacing: 4,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        Text(
          '$label: $count',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildSyncStatusCard() {
    final pending = _stats?['pending_sync_mutations'] ?? 0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Icon(
                Icons.sync_rounded,
                size: 18,
                color: Color(0xFF38BDF8),
              ),
              const Text(
                'Đồng Bộ Hóa SQLite & Backend',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              ElevatedButton.icon(
                onPressed: _isSyncing ? null : _triggerManualSync,
                icon: _isSyncing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.cloud_sync_rounded, size: 16),
                label: Text(_isSyncing ? 'Đang sync...' : 'Đồng bộ ngay'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4F46E5),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            pending > 0
                ? 'Có $pending thao tác ôn tập đang xếp hàng chờ đồng bộ lên máy chủ.'
                : 'Cơ sở dữ liệu cục bộ đã đồng bộ khớp với Cloud.',
            style: TextStyle(
              fontSize: 12,
              color: pending > 0
                  ? const Color(0xFFFBBF24)
                  : const Color(0xFF94A3B8),
            ),
          ),
          if (_syncMessage != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _syncMessage!,
                style: const TextStyle(fontSize: 12, color: Color(0xFF34D399)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDueQueueSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Danh sách Bài Cần Ôn Tập (Due Queue)',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            Text(
              '${_dueLessons.length} bài',
              style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_dueLessons.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.check_circle_outline_rounded,
                  color: Color(0xFF34D399),
                  size: 24,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Tuyệt vời! Bạn không còn thẻ nào cần ôn tập trong hôm nay.',
                    style: TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
                  ),
                ),
              ],
            ),
          )
        else
          ..._dueLessons.map((item) {
            return Card(
              color: const Color(0xFF1E293B),
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: Color(0xFF334155)),
              ),
              child: ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    item.targetText,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                title: Text(
                  item.meaningVi,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                subtitle: Text(
                  item.phoneticOrKana,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF38BDF8),
                  ),
                ),
                trailing: ElevatedButton.icon(
                  icon: const Icon(Icons.gesture, size: 14),
                  label: const Text('Ôn ngay', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4F46E5),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                  ),
                  onPressed: () {
                    if (widget.onPracticeDueLesson != null) {
                      widget.onPracticeDueLesson!(item);
                    }
                  },
                ),
              ),
            );
          }),
      ],
    );
  }
}
