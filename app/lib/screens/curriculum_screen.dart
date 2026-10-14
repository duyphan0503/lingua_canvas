import 'package:flutter/material.dart';
import '../models/lesson_item.dart';
import '../services/api_service.dart';
import '../services/fsrs_engine.dart';
import '../services/tts_service.dart';
import '../widgets/tts_speaker_button.dart';

class CurriculumScreen extends StatefulWidget {
  final ApiService? apiService;
  final Function(LessonItem lesson)? onSelectLesson;
  final TtsService? ttsService;

  const CurriculumScreen({
    super.key,
    this.apiService,
    this.onSelectLesson,
    this.ttsService,
  });

  @override
  State<CurriculumScreen> createState() => _CurriculumScreenState();
}

class _CurriculumScreenState extends State<CurriculumScreen> {
  late final ApiService _apiService;
  List<LessonItem> _allLessons = [];
  List<LessonItem> _filteredLessons = [];
  Map<String, FSRSCard> _cardMap = {};
  bool _isLoading = true;

  String _selectedLanguage = 'all'; // 'all', 'ja', 'en'
  String _selectedCategory = 'all'; // 'all', 'alphabet', 'it_workplace'
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? ApiService();
    _loadLessonsAndCards();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadLessonsAndCards() async {
    setState(() => _isLoading = true);
    try {
      final lessons = await _apiService.getLessons();
      final cards = await _apiService.getAllCards();
      final map = {for (var c in cards) c.itemId: c};

      if (mounted) {
        setState(() {
          _allLessons = lessons;
          _cardMap = map;
          _filteredLessons = _computeFiltered();
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<LessonItem> _computeFiltered() {
    return _allLessons.where((item) {
      // Language filter
      if (_selectedLanguage != 'all' && item.language != _selectedLanguage) {
        return false;
      }
      // Category filter
      if (_selectedCategory != 'all' && item.category != _selectedCategory) {
        return false;
      }
      // Search query filter
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchesTarget = item.targetText.toLowerCase().contains(q);
        final matchesPhonetic = item.phoneticOrKana.toLowerCase().contains(q);
        final matchesMeaning = item.meaningVi.toLowerCase().contains(q);
        final matchesContext =
            item.workplaceContext.toLowerCase().contains(q) ||
            item.workplaceContextVi.toLowerCase().contains(q);
        return matchesTarget ||
            matchesPhonetic ||
            matchesMeaning ||
            matchesContext;
      }
      return true;
    }).toList();
  }

  void _applyFilters() {
    setState(() {
      _filteredLessons = _computeFiltered();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.menu_book_rounded, color: Color(0xFF38BDF8), size: 22),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Thư Viện Giáo Trình & Từ Vựng',
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
            tooltip: 'Tải lại danh sách',
            onPressed: _loadLessonsAndCards,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildFilterBar(),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF818CF8)),
                  )
                : _filteredLessons.isEmpty
                ? _buildEmptyState()
                : _buildLessonList(),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        border: Border(bottom: BorderSide(color: Color(0xFF334155))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search TextField
          TextField(
            controller: _searchController,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Tìm kiếm theo từ vựng, kanji, nghĩa tiếng Việt...',
              hintStyle: const TextStyle(
                color: Color(0xFF64748B),
                fontSize: 13,
              ),
              prefixIcon: const Icon(
                Icons.search,
                color: Color(0xFF64748B),
                size: 20,
              ),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(
                        Icons.clear,
                        color: Color(0xFF64748B),
                        size: 18,
                      ),
                      onPressed: () {
                        _searchController.clear();
                        _searchQuery = '';
                        _applyFilters();
                      },
                    )
                  : null,
              filled: true,
              fillColor: const Color(0xFF0F172A),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF334155)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF334155)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF6366F1)),
              ),
            ),
            onChanged: (val) {
              _searchQuery = val.trim();
              _applyFilters();
            },
          ),
          const SizedBox(height: 8),

          // Filter Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterChip('Tất cả', _selectedLanguage == 'all', () {
                  _selectedLanguage = 'all';
                  _applyFilters();
                }),
                const SizedBox(width: 6),
                _buildFilterChip(
                  'Tiếng Nhật (JA)',
                  _selectedLanguage == 'ja',
                  () {
                    _selectedLanguage = 'ja';
                    _applyFilters();
                  },
                ),
                const SizedBox(width: 6),
                _buildFilterChip(
                  'Tiếng Anh (EN)',
                  _selectedLanguage == 'en',
                  () {
                    _selectedLanguage = 'en';
                    _applyFilters();
                  },
                ),
                const SizedBox(width: 12),
                Container(height: 16, width: 1, color: const Color(0xFF475569)),
                const SizedBox(width: 12),
                _buildFilterChip(
                  'Bảng chữ cái',
                  _selectedCategory == 'alphabet',
                  () {
                    _selectedCategory = _selectedCategory == 'alphabet'
                        ? 'all'
                        : 'alphabet';
                    _applyFilters();
                  },
                ),
                const SizedBox(width: 6),
                _buildFilterChip(
                  'IT Chuyên ngành',
                  _selectedCategory == 'it_workplace',
                  () {
                    _selectedCategory = _selectedCategory == 'it_workplace'
                        ? 'all'
                        : 'it_workplace';
                    _applyFilters();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, bool isSelected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: const Color(0xFF4F46E5),
      backgroundColor: const Color(0xFF0F172A),
      labelStyle: TextStyle(
        fontSize: 11,
        color: isSelected ? Colors.white : const Color(0xFF94A3B8),
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
      side: BorderSide(
        color: isSelected ? const Color(0xFF6366F1) : const Color(0xFF334155),
      ),
      onSelected: (_) => onTap(),
    );
  }

  Widget _buildLessonList() {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _filteredLessons.length,
      itemBuilder: (context, index) {
        final item = _filteredLessons[index];
        final card = _cardMap[item.id];
        final isMastered = card != null && card.stability > 14.0;
        final isLearning = card != null && card.reps > 0 && !isMastered;

        return Card(
          color: const Color(0xFF1E293B),
          margin: const EdgeInsets.only(bottom: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF334155)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // Target character / word in bold box
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF334155)),
                      ),
                      child: Text(
                        item.targetText,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    TtsSpeakerButton(
                      text: item.targetText,
                      language: item.language,
                      iconSize: 20,
                      tooltip: 'Phát âm "${item.targetText}"',
                      ttsService: widget.ttsService,
                    ),
                    _buildFSRSBadge(isMastered, isLearning, card),
                  ],
                ),
                if (item.phoneticOrKana.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    item.phoneticOrKana,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF38BDF8),
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  item.meaningVi,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFE2E8F0),
                  ),
                ),
                if (item.workplaceContext.isNotEmpty ||
                    item.workplaceContextVi.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (item.workplaceContext.isNotEmpty)
                          Text(
                            item.workplaceContext,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFCBD5E1),
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        if (item.workplaceContextVi.isNotEmpty)
                          Text(
                            item.workplaceContextVi,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      item.language == 'ja'
                          ? '${item.strokeOrderHints.length} nét hướng dẫn'
                          : 'Từ vựng công việc',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () {
                        if (widget.onSelectLesson != null) {
                          widget.onSelectLesson!(item);
                        }
                      },
                      icon: Icon(
                        item.language == 'ja'
                            ? Icons.gesture
                            : Icons.menu_book_rounded,
                        size: 16,
                      ),
                      label: Text(
                        item.language == 'ja'
                            ? 'Luyện viết ngay'
                            : 'Học & ôn ngay',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4F46E5),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 48),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFSRSBadge(bool isMastered, bool isLearning, FSRSCard? card) {
    if (isMastered) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0x33059669),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFF059669)),
        ),
        child: const Text(
          'Đã thuộc',
          style: TextStyle(
            fontSize: 10,
            color: Color(0xFF34D399),
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }
    if (isLearning) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0x33D97706),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFFD97706)),
        ),
        child: Text(
          'Đang học (${card?.reps ?? 0} lần)',
          style: const TextStyle(
            fontSize: 10,
            color: Color(0xFFFBBF24),
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF334155),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'Chưa học',
        style: TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.search_off_rounded,
            size: 48,
            color: Color(0xFF64748B),
          ),
          const SizedBox(height: 12),
          const Text(
            'Không tìm thấy từ vựng nào.',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () {
              _searchController.clear();
              _searchQuery = '';
              _selectedLanguage = 'all';
              _selectedCategory = 'all';
              _applyFilters();
            },
            child: const Text('Đặt lại bộ lọc'),
          ),
        ],
      ),
    );
  }
}
