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
  Map<String, PrivateLessonState> _privateStates = {};
  Map<String, FSRSCard> _cardMap = {};
  bool _isLoading = true;

  String _selectedLanguage = 'all'; // 'all', 'ja', 'en'
  String _selectedCategory =
      'all'; // all, alphabet, jlpt_n5, it_workplace, custom
  bool _showTrash = false;
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
      final privateStates = await _apiService.getPrivateLessons(
        includeDeleted: true,
      );
      final map = {for (var c in cards) c.itemId: c};
      final states = {
        for (final state in privateStates) state.lesson.id: state,
      };
      final allById = {for (final lesson in lessons) lesson.id: lesson};
      for (final state in privateStates) {
        allById[state.lesson.id] = state.lesson;
      }

      if (mounted) {
        setState(() {
          _allLessons = allById.values.toList();
          _privateStates = states;
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
      final state = _privateStates[item.id];
      if (_showTrash) {
        if (state?.deleted != true) return false;
      } else if (state?.deleted == true) {
        return false;
      }
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

  Future<void> _createCustomLesson() async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _CustomLessonDialog(
        initialLanguage: _selectedLanguage == 'en' ? 'en' : 'ja',
      ),
    );
    if (values == null || !mounted) return;
    try {
      final lesson = await _apiService.createPrivateLesson(
        word: values['word']!,
        language: values['language']!,
        meaningVi: values['meaning']!.trim(),
        phoneticOrKana: values['phonetic']!.trim(),
        workplaceContext: values['context']!.trim(),
        workplaceContextVi: values['contextVi']!.trim(),
      );
      if (!mounted) return;
      await _loadLessonsAndCards();
      if (!mounted) return;
      widget.onSelectLesson?.call(lesson);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Không thể lưu từ mới. Vui lòng thử lại.'),
          ),
        );
      }
    }
  }

  Future<void> _editPrivateLesson(LessonItem lesson) async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) =>
          _CustomLessonDialog(initialLanguage: lesson.language, lesson: lesson),
    );
    if (values == null || !mounted) return;
    try {
      await _apiService.savePrivateLesson(
        LessonItem(
          id: lesson.id,
          language: values['language']!,
          category: 'custom',
          targetText: values['word']!.trim(),
          phoneticOrKana: values['phonetic']!.trim(),
          meaningVi: values['meaning']!.trim(),
          workplaceContext: values['context']!.trim(),
          workplaceContextVi: values['contextVi']!.trim(),
          strokeOrderHints: lesson.strokeOrderHints,
          difficultyLevel: lesson.difficultyLevel,
        ),
      );
      if (mounted) await _loadLessonsAndCards();
    } catch (_) {
      _showMessage('Chưa lưu được thay đổi. Từ vẫn được giữ nguyên.');
    }
  }

  Future<void> _deletePrivateLesson(LessonItem lesson) async {
    try {
      await _apiService.deletePrivateLesson(lesson.id);
      if (!mounted) return;
      await _loadLessonsAndCards();
      _showMessage('Đã chuyển từ vào thùng rác. Lịch sử học vẫn được giữ.');
    } catch (_) {
      _showMessage('Chưa chuyển được từ vào thùng rác.');
    }
  }

  Future<void> _restorePrivateLesson(LessonItem lesson) async {
    try {
      await _apiService.restorePrivateLesson(lesson.id);
      if (!mounted) return;
      setState(() => _showTrash = false);
      await _loadLessonsAndCards();
      _showMessage('Đã khôi phục từ.');
    } catch (_) {
      _showMessage('Chưa khôi phục được từ.');
    }
  }

  Future<void> _resolveConflict(PrivateLessonState state) async {
    final conflict = state.conflict;
    if (conflict == null) return;
    final keepLocal = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Chọn nội dung muốn giữ'),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ConflictVersionCard(
                  title: 'Bản trên thiết bị này',
                  lesson: conflict.local.lesson,
                  deleted: conflict.local.deleted,
                ),
                const SizedBox(height: 8),
                if (conflict.remote == null)
                  const Card(
                    margin: EdgeInsets.zero,
                    color: Color(0xFF0F172A),
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Bản trên máy chủ',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 6),
                          Text('Máy chủ chưa có bản lưu cho từ này.'),
                        ],
                      ),
                    ),
                  )
                else
                  _ConflictVersionCard(
                    title: 'Bản trên máy chủ',
                    lesson: conflict.remote!.lesson,
                    deleted: conflict.remote!.deleted,
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Để sau'),
          ),
          if (conflict.remote != null)
            OutlinedButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Giữ bản máy chủ'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Giữ bản trên thiết bị'),
          ),
        ],
      ),
    );
    if (keepLocal == null || !mounted) return;
    try {
      await _apiService.resolvePrivateLessonConflict(
        state.lesson.id,
        keepLocal: keepLocal,
      );
      if (mounted) await _loadLessonsAndCards();
    } catch (_) {
      _showMessage(
        'Chưa giải quyết được xung đột. Hãy đồng bộ lại rồi thử tiếp.',
      );
    }
  }

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      floatingActionButton: _showTrash
          ? null
          : FloatingActionButton.extended(
              onPressed: _createCustomLesson,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Thêm từ mới'),
            ),
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
                for (final category in {
                  'jlpt_n5': 'JLPT N5 (Kanji)',
                  'jlpt_n4': 'JLPT N4 (Công sở)',
                  'toeic_business': 'TOEIC & Business',
                  'business_toeic': 'Business / TOEIC',
                  'custom': 'Từ tự tạo',
                }.entries) ...[
                  _buildFilterChip(
                    category.value,
                    _selectedCategory == category.key,
                    () {
                      _selectedCategory = _selectedCategory == category.key
                          ? 'all'
                          : category.key;
                      _applyFilters();
                    },
                  ),
                  const SizedBox(width: 6),
                ],
                _buildFilterChip('Thùng rác', _showTrash, () {
                  setState(() {
                    _showTrash = !_showTrash;
                    _filteredLessons = _computeFiltered();
                  });
                }),
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
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
      itemCount: _filteredLessons.length,
      itemBuilder: (context, index) {
        final item = _filteredLessons[index];
        final privateState = _privateStates[item.id];
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
                    Chip(
                      label: Text(switch (item.category) {
                        'alphabet' => 'Bảng chữ cái',
                        'jlpt_n5' => 'JLPT N5 (Kanji)',
                        'jlpt_n4' => 'JLPT N4 (Công sở)',
                        'toeic_business' => 'TOEIC & Business',
                        'business_toeic' => 'Business / TOEIC',
                        'custom' => 'Từ tự tạo',
                        _ => 'IT Chuyên ngành',
                      }),
                    ),
                    _buildFSRSBadge(isMastered, isLearning, card),
                  ],
                ),
                if (privateState?.conflict != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0x33D97706),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFD97706)),
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Icon(
                          Icons.sync_problem,
                          color: Color(0xFFFBBF24),
                        ),
                        const Text(
                          'Có hai phiên bản. Chọn nội dung muốn giữ.',
                          style: TextStyle(color: Color(0xFFFDE68A)),
                        ),
                        TextButton(
                          onPressed: () => _resolveConflict(privateState!),
                          child: const Text('So sánh'),
                        ),
                      ],
                    ),
                  ),
                ],
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
                    if (privateState?.deleted == true)
                      OutlinedButton.icon(
                        key: ValueKey('restore-${item.id}'),
                        onPressed: () => _restorePrivateLesson(item),
                        icon: const Icon(Icons.restore_rounded, size: 16),
                        label: const Text('Khôi phục'),
                      ),
                    if (privateState != null && !privateState.deleted) ...[
                      IconButton(
                        tooltip: 'Sửa từ',
                        onPressed: () => _editPrivateLesson(item),
                        icon: const Icon(
                          Icons.edit_outlined,
                          color: Color(0xFF93C5FD),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Chuyển vào thùng rác',
                        onPressed: () => _deletePrivateLesson(item),
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Color(0xFFF87171),
                        ),
                      ),
                    ],
                    ElevatedButton.icon(
                      onPressed: privateState?.deleted == true
                          ? null
                          : () {
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

class _CustomLessonDialog extends StatefulWidget {
  final String initialLanguage;
  final LessonItem? lesson;
  const _CustomLessonDialog({required this.initialLanguage, this.lesson});

  @override
  State<_CustomLessonDialog> createState() => _CustomLessonDialogState();
}

class _CustomLessonDialogState extends State<_CustomLessonDialog> {
  final _formKey = GlobalKey<FormState>();
  final _word = TextEditingController();
  final _meaning = TextEditingController();
  final _phonetic = TextEditingController();
  final _context = TextEditingController();
  final _contextVi = TextEditingController();
  late String _language = widget.initialLanguage;

  @override
  void initState() {
    super.initState();
    final lesson = widget.lesson;
    if (lesson != null) {
      _word.text = lesson.targetText;
      _meaning.text = lesson.meaningVi;
      _phonetic.text = lesson.phoneticOrKana;
      _context.text = lesson.workplaceContext;
      _contextVi.text = lesson.workplaceContextVi;
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _word,
      _meaning,
      _phonetic,
      _context,
      _contextVi,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      title: Text(widget.lesson == null ? 'Thêm từ mới' : 'Sửa từ cá nhân'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _language,
                  decoration: const InputDecoration(labelText: 'Ngôn ngữ'),
                  items: const [
                    DropdownMenuItem(
                      value: 'ja',
                      child: Text('Tiếng Nhật (ja)'),
                    ),
                    DropdownMenuItem(
                      value: 'en',
                      child: Text('Tiếng Anh (en)'),
                    ),
                  ],
                  onChanged: (value) => setState(() => _language = value!),
                ),
                TextFormField(
                  key: const Key('custom-word'),
                  controller: _word,
                  decoration: const InputDecoration(
                    labelText: 'Từ vựng / Chữ cần luyện viết',
                  ),
                  validator: (value) => value?.trim().isNotEmpty == true
                      ? null
                      : 'Vui lòng nhập từ vựng',
                ),
                TextFormField(
                  key: const Key('custom-phonetic'),
                  controller: _phonetic,
                  decoration: const InputDecoration(
                    labelText: 'Phiên âm / Kana',
                  ),
                ),
                TextFormField(
                  key: const Key('custom-meaning'),
                  controller: _meaning,
                  decoration: const InputDecoration(
                    labelText: 'Nghĩa tiếng Việt',
                  ),
                  validator: (value) => value?.trim().isNotEmpty == true
                      ? null
                      : 'Vui lòng nhập nghĩa tiếng Việt',
                ),
                TextFormField(
                  key: const Key('custom-context'),
                  controller: _context,
                  decoration: const InputDecoration(
                    labelText: 'Câu ví dụ công sở',
                  ),
                ),
                TextFormField(
                  key: const Key('custom-context-vi'),
                  controller: _contextVi,
                  decoration: const InputDecoration(
                    labelText: 'Dịch nghĩa câu ví dụ',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop(context, {
              'word': _word.text,
              'language': _language,
              'meaning': _meaning.text,
              'phonetic': _phonetic.text,
              'context': _context.text,
              'contextVi': _contextVi.text,
            });
          },
          child: Text(
            widget.lesson == null ? 'Lưu & Luyện viết' : 'Lưu thay đổi',
          ),
        ),
      ],
    );
  }
}

class _ConflictVersionCard extends StatelessWidget {
  final String title;
  final LessonItem? lesson;
  final bool deleted;

  const _ConflictVersionCard({
    required this.title,
    required this.lesson,
    required this.deleted,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      color: const Color(0xFF0F172A),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              deleted ? 'Đã xóa' : (lesson?.targetText ?? 'Không có từ'),
              style: const TextStyle(fontSize: 18, color: Colors.white),
            ),
            if (!deleted && lesson != null) ...[
              Text(lesson!.phoneticOrKana),
              Text(lesson!.meaningVi),
              if (lesson!.workplaceContext.isNotEmpty)
                Text(lesson!.workplaceContext),
              if (lesson!.workplaceContextVi.isNotEmpty)
                Text(lesson!.workplaceContextVi),
            ],
          ],
        ),
      ),
    );
  }
}
