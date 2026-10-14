import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/digital_ink_engine.dart';
import '../services/handwriting_recognizer.dart';
import '../services/tts_service.dart';
import 'ai_roleplay_screen.dart';
import 'analytics_screen.dart';
import 'canvas_practice_screen.dart';
import 'curriculum_screen.dart';
import 'settings_screen.dart';

class MainShellScreen extends StatefulWidget {
  final ApiService? apiService;
  final DigitalInkEngine? digitalInkEngine;
  final HandwritingRecognizer? recognizer;
  final TtsService? ttsService;

  const MainShellScreen({
    super.key,
    this.apiService,
    this.digitalInkEngine,
    this.recognizer,
    this.ttsService,
  });

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen> {
  late final ApiService _apiService;
  int _currentIndex = 0;
  String? _targetLessonId;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? ApiService();
  }

  void _navigateToCanvasWithLesson(String lessonId) {
    setState(() {
      _targetLessonId = lessonId;
      _currentIndex = 0;
    });
  }

  Future<void> _navigateToCanvasWithWord(String word, String language) async {
    try {
      final lessons = await _apiService.getLessons();
      if (!mounted) return;
      for (final lesson in lessons) {
        if (lesson.language == language &&
            lesson.targetText.trim() == word.trim()) {
          _navigateToCanvasWithLesson(lesson.id);
          return;
        }
      }
    } catch (_) {
      if (!mounted) return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('“$word” chưa có bài luyện viết trong giáo trình.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          // 0. Canvas Practice Screen
          CanvasPracticeScreen(
            key: ValueKey('canvas_$_targetLessonId'),
            apiService: _apiService,
            digitalInkEngine: widget.digitalInkEngine,
            recognizer: widget.recognizer,
            initialLessonId: _targetLessonId,
            ttsService: widget.ttsService,
          ),

          // 1. AI Roleplay & Conversational Dialogue Screen
          AIRoleplayScreen(
            apiService: _apiService,
            onPracticeWord: _navigateToCanvasWithWord,
            ttsService: widget.ttsService,
          ),

          // 2. Curriculum & Word Vault Screen
          CurriculumScreen(
            apiService: _apiService,
            onSelectLesson: (lesson) => _navigateToCanvasWithLesson(lesson.id),
            ttsService: widget.ttsService,
          ),

          // 3. FSRS Memory Analytics Dashboard
          AnalyticsScreen(
            apiService: _apiService,
            onPracticeDueLesson: (lesson) =>
                _navigateToCanvasWithLesson(lesson.id),
          ),

          // 4. Settings & Backend Connection
          SettingsScreen(
            apiService: _apiService,
            onResetData: () {
              setState(() {
                _targetLessonId = null;
              });
            },
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E293B),
          border: Border(top: BorderSide(color: Color(0xFF334155))),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            setState(() => _currentIndex = index);
          },
          backgroundColor: const Color(0xFF1E293B),
          indicatorColor: const Color(0xFF4F46E5),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.gesture_rounded, color: Color(0xFF94A3B8)),
              selectedIcon: Icon(Icons.gesture_rounded, color: Colors.white),
              label: 'Học & Ôn tập',
            ),
            NavigationDestination(
              icon: Icon(Icons.smart_toy_outlined, color: Color(0xFF94A3B8)),
              selectedIcon: Icon(Icons.smart_toy_rounded, color: Colors.white),
              label: 'AI Đối Thoại',
            ),
            NavigationDestination(
              icon: Icon(Icons.menu_book_outlined, color: Color(0xFF94A3B8)),
              selectedIcon: Icon(Icons.menu_book_rounded, color: Colors.white),
              label: 'Giáo Trình',
            ),
            NavigationDestination(
              icon: Icon(Icons.insights_rounded, color: Color(0xFF94A3B8)),
              selectedIcon: Icon(Icons.insights_rounded, color: Colors.white),
              label: 'Thống Kê',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined, color: Color(0xFF94A3B8)),
              selectedIcon: Icon(Icons.settings_rounded, color: Colors.white),
              label: 'Cài Đặt',
            ),
          ],
        ),
      ),
    );
  }
}
