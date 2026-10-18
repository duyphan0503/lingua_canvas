import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/account_service.dart';
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
  final AccountService? accountService;
  final DigitalInkEngine? digitalInkEngine;
  final HandwritingRecognizer? recognizer;
  final TtsService? ttsService;

  const MainShellScreen({
    super.key,
    this.apiService,
    this.accountService,
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
  int _profileGeneration = 0;
  int _profileDataGeneration = 0;
  String? _targetLessonId;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? ApiService();
  }

  void _navigateToCanvasWithLesson(String lessonId) {
    _stopPlayback();
    setState(() {
      _targetLessonId = lessonId;
      _currentIndex = 0;
    });
  }

  void _stopPlayback() {
    unawaited((widget.ttsService ?? TtsService.defaultInstance).stop());
  }

  void _handleProfileDataChanged() {
    _stopPlayback();
    setState(() {
      _profileDataGeneration++;
      _targetLessonId = null;
    });
  }

  void _selectDestination(int index) {
    if (index != _currentIndex) _stopPlayback();
    setState(() => _currentIndex = index);
  }

  @override
  void dispose() {
    _stopPlayback();
    super.dispose();
  }

  Future<void> _navigateToCanvasWithWord(String word, String language) async {
    final generation = _profileGeneration;
    try {
      final lesson = await _apiService.ensureLessonForWord(
        word: word,
        language: language,
      );
      if (!mounted || generation != _profileGeneration) return;
      _navigateToCanvasWithLesson(lesson.id);
      return;
    } catch (_) {
      if (!mounted) return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '“$word” không thể lưu bài luyện viết. Vui lòng thử lại.',
          ),
        ),
      );
    }
  }

  static const List<NavigationDestination> _destinations = [
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
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        return Scaffold(
          backgroundColor: const Color(0xFF0B0F19),
          body: Row(
            children: [
              SizedBox(
                width: wide ? 200 : 0,
                child: wide
                    ? NavigationRail(
                        extended: true,
                        minExtendedWidth: 200,
                        backgroundColor: const Color(0xFF1E293B),
                        selectedIndex: _currentIndex,
                        onDestinationSelected: _selectDestination,
                        destinations: [
                          for (final destination in _destinations)
                            NavigationRailDestination(
                              icon: destination.icon,
                              selectedIcon: destination.selectedIcon,
                              label: Text(destination.label),
                            ),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1200),
                    child: IndexedStack(
                      key: ValueKey(_profileGeneration),
                      index: _currentIndex,
                      children: [
                        // 0. Canvas Practice Screen
                        CanvasPracticeScreen(
                          key: ValueKey(
                            'canvas_${_profileDataGeneration}_$_targetLessonId',
                          ),
                          isActive: _currentIndex == 0,
                          apiService: _apiService,
                          digitalInkEngine: widget.digitalInkEngine,
                          recognizer: widget.recognizer,
                          initialLessonId: _targetLessonId,
                          ttsService: widget.ttsService,
                        ),

                        // 1. AI Roleplay & Conversational Dialogue Screen
                        AIRoleplayScreen(
                          isActive: _currentIndex == 1,
                          apiService: _apiService,
                          onPracticeWord: _navigateToCanvasWithWord,
                          ttsService: widget.ttsService,
                        ),

                        // 2. Curriculum & Word Vault Screen
                        CurriculumScreen(
                          key: ValueKey('curriculum_$_profileDataGeneration'),
                          apiService: _apiService,
                          onSelectLesson: (lesson) =>
                              _navigateToCanvasWithLesson(lesson.id),
                          ttsService: widget.ttsService,
                        ),

                        // 3. FSRS Memory Analytics Dashboard
                        AnalyticsScreen(
                          key: ValueKey('analytics_$_profileDataGeneration'),
                          apiService: _apiService,
                          onPracticeDueLesson: (lesson) =>
                              _navigateToCanvasWithLesson(lesson.id),
                        ),

                        // 4. Settings & Backend Connection
                        SettingsScreen(
                          apiService: _apiService,
                          accountService: widget.accountService,
                          onProfileDataChanged: _handleProfileDataChanged,
                          onAccountChanged: () {
                            _stopPlayback();
                            setState(() {
                              _profileGeneration++;
                              _targetLessonId = null;
                            });
                          },
                          onResetData: () {
                            _stopPlayback();
                            setState(() {
                              _profileGeneration++;
                              _apiService.syncCoordinator.lastSyncTime = null;
                              _targetLessonId = null;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar: wide
              ? null
              : Container(
                  decoration: const BoxDecoration(
                    color: Color(0xFF1E293B),
                    border: Border(top: BorderSide(color: Color(0xFF334155))),
                  ),
                  child: NavigationBar(
                    selectedIndex: _currentIndex,
                    onDestinationSelected: _selectDestination,
                    backgroundColor: const Color(0xFF1E293B),
                    indicatorColor: const Color(0xFF4F46E5),
                    destinations: _destinations,
                  ),
                ),
        );
      },
    );
  }
}
