import 'package:flutter/material.dart';
import '../models/lesson_item.dart';
import '../services/api_service.dart';
import '../services/fsrs_engine.dart';
import '../services/handwriting_recognizer.dart';
import '../widgets/handwriting_canvas.dart';

/// Main interactive Canvas Practice Screen for IT workplace Japanese and English.
class CanvasPracticeScreen extends StatefulWidget {
  final ApiService? apiService;

  const CanvasPracticeScreen({super.key, this.apiService});

  @override
  State<CanvasPracticeScreen> createState() => _CanvasPracticeScreenState();
}

class _CanvasPracticeScreenState extends State<CanvasPracticeScreen> {
  late final ApiService _apiService;
  List<LessonItem> _allLessons = [];
  List<LessonItem> _filteredLessons = [];
  int _currentIndex = 0;
  String _selectedLanguage = 'all'; // 'all', 'ja', 'en'
  bool _isLoading = true;
  int _completedCount = 0;

  List<HandwritingStroke> _strokes = [];
  RecognitionResult? _recognitionResult;
  bool _showWatermark = true;
  bool _showHints = true;
  String? _statusNotification;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? ApiService();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);
    final lessons = await _apiService.getLessons();
    final count = await _apiService.getCompletedCount();

    if (!mounted) return;
    setState(() {
      _allLessons = lessons;
      _completedCount = count;
      _filterLessons();
      _isLoading = false;
    });
  }

  void _filterLessons() {
    if (_selectedLanguage == 'all') {
      _filteredLessons = List.from(_allLessons);
    } else {
      _filteredLessons = _allLessons
          .where((l) => l.language == _selectedLanguage)
          .toList();
    }
    _currentIndex = 0;
    _clearCanvas();
  }

  void _onLanguageSelected(String lang) {
    if (_selectedLanguage == lang) return;
    setState(() {
      _selectedLanguage = lang;
      _filterLessons();
    });
  }

  LessonItem? get _currentLesson {
    if (_filteredLessons.isEmpty || _currentIndex >= _filteredLessons.length) {
      return null;
    }
    return _filteredLessons[_currentIndex];
  }

  void _clearCanvas() {
    setState(() {
      _strokes = [];
      _recognitionResult = null;
      _statusNotification = null;
    });
  }

  void _evaluateHandwriting() {
    final lesson = _currentLesson;
    if (lesson == null) return;

    final result = HandwritingRecognizer.evaluate(
      strokes: _strokes,
      targetText: lesson.targetText,
      strokeOrderHints: lesson.strokeOrderHints,
    );

    setState(() {
      _recognitionResult = result;
    });
  }

  Future<void> _submitFSRSRating(FSRSRating rating) async {
    final lesson = _currentLesson;
    if (lesson == null) return;

    await _apiService.submitReview(itemId: lesson.id, rating: rating);
    final updatedCount = await _apiService.getCompletedCount();

    if (!mounted) return;
    final ratingLabel = switch (rating) {
      FSRSRating.again => 'Again (Học lại)',
      FSRSRating.hard => 'Hard (Khó)',
      FSRSRating.good => 'Good (Tốt)',
      FSRSRating.easy => 'Easy (Dễ)',
    };

    setState(() {
      _completedCount = updatedCount;
      _statusNotification = 'Đã lưu đánh giá: $ratingLabel';
    });

    // Automatically transition to next card after a brief moment
    Future.delayed(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      _goToNextLesson();
    });
  }

  void _goToPreviousLesson() {
    if (_filteredLessons.isEmpty) return;
    setState(() {
      _currentIndex =
          (_currentIndex - 1 + _filteredLessons.length) %
          _filteredLessons.length;
      _clearCanvas();
    });
  }

  void _goToNextLesson() {
    if (_filteredLessons.isEmpty) return;
    setState(() {
      _currentIndex = (_currentIndex + 1) % _filteredLessons.length;
      _clearCanvas();
    });
  }

  @override
  Widget build(BuildContext context) {
    final lesson = _currentLesson;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19), // Deep dark workspace slate
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0x336366F1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.draw_rounded,
                color: Color(0xFF818CF8),
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Lingua Canvas',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),
                Text(
                  'IT Workplace Handwriting Practice',
                  style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                ),
              ],
            ),
          ],
        ),
        actions: [
          // Completed badge
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  color: Color(0xFF10B981),
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  'Đã luyện: $_completedCount',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE2E8F0),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF6366F1)),
            )
          : lesson == null
          ? _buildEmptyState()
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Language Filter & Lesson Navigation Bar
                  _buildHeaderControls(),
                  const SizedBox(height: 12),

                  // Lesson Target Info Card
                  _buildLessonInfoCard(lesson),
                  const SizedBox(height: 12),

                  // Interactive Drawing Canvas Container
                  _buildCanvasSection(lesson),
                  const SizedBox(height: 12),

                  // Recognition Feedback Banner
                  if (_recognitionResult != null) ...[
                    _buildRecognitionFeedback(_recognitionResult!),
                    const SizedBox(height: 12),
                  ],

                  // Status notification toast/banner
                  if (_statusNotification != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF065F46),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.check_circle,
                            color: Color(0xFF34D399),
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _statusNotification!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Spaced Repetition (FSRS) Rating Action Bar
                  _buildFSRSRatingBar(),
                ],
              ),
            ),
    );
  }

  Widget _buildHeaderControls() {
    return Row(
      children: [
        // Language filter chips
        Wrap(
          spacing: 6,
          children: [
            _buildLanguageChip('all', 'Tất cả'),
            _buildLanguageChip('ja', 'Tiếng Nhật (IT)'),
            _buildLanguageChip('en', 'Tiếng Anh (IT)'),
          ],
        ),
        const Spacer(),
        // Lesson navigation counters
        IconButton(
          icon: const Icon(Icons.chevron_left, color: Color(0xFF94A3B8)),
          onPressed: _goToPreviousLesson,
          tooltip: 'Bài trước',
        ),
        Text(
          '${_currentIndex + 1}/${_filteredLessons.length}',
          style: const TextStyle(
            color: Color(0xFF94A3B8),
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right, color: Color(0xFF94A3B8)),
          onPressed: _goToNextLesson,
          tooltip: 'Bài tiếp theo',
        ),
      ],
    );
  }

  Widget _buildLanguageChip(String lang, String label) {
    final isSelected = _selectedLanguage == lang;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: const Color(0xFF4F46E5),
      backgroundColor: const Color(0xFF1E293B),
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        color: isSelected ? Colors.white : const Color(0xFF94A3B8),
      ),
      side: BorderSide(
        color: isSelected ? const Color(0xFF6366F1) : const Color(0xFF334155),
      ),
      onSelected: (_) => _onLanguageSelected(lang),
    );
  }

  Widget _buildLessonInfoCard(LessonItem lesson) {
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
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Target text in high-contrast bold
              Text(
                lesson.targetText,
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(width: 12),
              // Phonetic / kana pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF475569)),
                ),
                child: Text(
                  lesson.phoneticOrKana,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF38BDF8),
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const Spacer(),
              // Language / Category badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: lesson.language == 'ja'
                      ? const Color(0x33BE185D)
                      : const Color(0x330284C7),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  lesson.language == 'ja'
                      ? 'JA • JLPT/IT'
                      : 'EN • IT Workplace',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: lesson.language == 'ja'
                        ? const Color(0xFFF472B6)
                        : const Color(0xFF38BDF8),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Vietnamese meaning
          Text(
            lesson.meaningVi,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFFE2E8F0),
            ),
          ),
          const SizedBox(height: 8),
          // Workplace Context
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ngữ cảnh công sở: ${lesson.workplaceContext}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFFCBD5E1),
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  lesson.workplaceContextVi,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF94A3B8),
                  ),
                ),
              ],
            ),
          ),

          // Stroke Order Hints Accordion
          if (lesson.strokeOrderHints.isNotEmpty) ...[
            const SizedBox(height: 10),
            InkWell(
              onTap: () => setState(() => _showHints = !_showHints),
              child: Row(
                children: [
                  Icon(
                    _showHints
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 18,
                    color: const Color(0xFF818CF8),
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'Hướng dẫn thứ tự nét viết',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF818CF8),
                    ),
                  ),
                ],
              ),
            ),
            if (_showHints) ...[
              const SizedBox(height: 6),
              ...lesson.strokeOrderHints.map(
                (hint) => Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '• ',
                        style: TextStyle(
                          color: Color(0xFF818CF8),
                          fontSize: 13,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          hint,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildCanvasSection(LessonItem lesson) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        children: [
          // Canvas toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF1E293B),
              borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
            ),
            child: Row(
              children: [
                const Icon(Icons.gesture, size: 16, color: Color(0xFF38BDF8)),
                const SizedBox(width: 6),
                const Text(
                  'Vùng Luyện Viết (Canvas)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE2E8F0),
                  ),
                ),
                const Spacer(),
                // Watermark trace guide toggle
                IconButton(
                  icon: Icon(
                    _showWatermark
                        ? Icons.visibility
                        : Icons.visibility_off_outlined,
                    color: _showWatermark
                        ? const Color(0xFF38BDF8)
                        : const Color(0xFF64748B),
                    size: 18,
                  ),
                  tooltip: _showWatermark ? 'Tắt chữ mẫu' : 'Bật chữ mẫu mờ',
                  onPressed: () =>
                      setState(() => _showWatermark = !_showWatermark),
                ),
                // Clear button
                TextButton.icon(
                  onPressed: _strokes.isEmpty ? null : _clearCanvas,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Xóa', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFEF4444),
                  ),
                ),
                // Evaluate button
                ElevatedButton.icon(
                  onPressed: _strokes.isEmpty ? null : _evaluateHandwriting,
                  icon: const Icon(Icons.spellcheck_rounded, size: 16),
                  label: const Text('Đánh giá', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4F46E5),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Handwriting canvas area (Height 280)
          SizedBox(
            height: 280,
            width: double.infinity,
            child: HandwritingCanvas(
              strokes: _strokes,
              watermarkText: _showWatermark ? lesson.targetText : null,
              onStrokesChanged: (newStrokes) {
                setState(() => _strokes = newStrokes);
              },
              onStrokeCompleted: _evaluateHandwriting,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecognitionFeedback(RecognitionResult result) {
    final scorePercent = (result.similarityScore * 100).toInt();
    final isAccurate = result.isAccurate;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isAccurate ? const Color(0x66064E3B) : const Color(0x6678350F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isAccurate ? const Color(0xFF059669) : const Color(0xFFD97706),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isAccurate ? Icons.verified_rounded : Icons.info_outline_rounded,
            color: isAccurate
                ? const Color(0xFF34D399)
                : const Color(0xFFFBBF24),
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      isAccurate ? 'Đạt chuẩn' : 'Cần cải thiện',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: isAccurate
                            ? const Color(0xFF34D399)
                            : const Color(0xFFFBBF24),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Độ tương đồng: $scorePercent%',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFE2E8F0),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  result.feedbackMessage,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFFCBD5E1),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFSRSRatingBar() {
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
          const Row(
            children: [
              Icon(Icons.schedule_rounded, size: 16, color: Color(0xFF818CF8)),
              SizedBox(width: 6),
              Text(
                'Đánh Giá Ôn Tập FSRS (Spaced Repetition)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFE2E8F0),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildRatingButton(
                  label: 'Again',
                  subtitle: '< 10p',
                  color: const Color(0xFFEF4444),
                  onTap: () => _submitFSRSRating(FSRSRating.again),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildRatingButton(
                  label: 'Hard',
                  subtitle: '1-2 ngày',
                  color: const Color(0xFFF59E0B),
                  onTap: () => _submitFSRSRating(FSRSRating.hard),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildRatingButton(
                  label: 'Good',
                  subtitle: '3-5 ngày',
                  color: const Color(0xFF3B82F6),
                  onTap: () => _submitFSRSRating(FSRSRating.good),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildRatingButton(
                  label: 'Easy',
                  subtitle: '> 7 ngày',
                  color: const Color(0xFF10B981),
                  onTap: () => _submitFSRSRating(FSRSRating.easy),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRatingButton({
    required String label,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.15),
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.5)),
        padding: const EdgeInsets.symmetric(vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        elevation: 0,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.8)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.menu_book_rounded,
            size: 48,
            color: Color(0xFF64748B),
          ),
          const SizedBox(height: 12),
          const Text(
            'Không tìm thấy bài học nào phù hợp.',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 15),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => _onLanguageSelected('all'),
            child: const Text('Xem tất cả bài học'),
          ),
        ],
      ),
    );
  }
}
