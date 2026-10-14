import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/tts_service.dart';
import '../widgets/tts_speaker_button.dart';

class AIRoleplayScreen extends StatefulWidget {
  final ApiService? apiService;
  final Function(String targetWord, String language)? onPracticeWord;
  final TtsService? ttsService;

  const AIRoleplayScreen({
    super.key,
    this.apiService,
    this.onPracticeWord,
    this.ttsService,
  });

  @override
  State<AIRoleplayScreen> createState() => _AIRoleplayScreenState();
}

class _AIRoleplayScreenState extends State<AIRoleplayScreen>
    with SingleTickerProviderStateMixin {
  late final ApiService _apiService;
  late final TabController _tabController;

  String _selectedLanguage = 'ja'; // 'ja' or 'en'
  String _selectedTopic = 'Daily Standup';
  final String _selectedProfession = 'IT';
  bool _isLoading = false;
  bool _showTranslation = true;

  // Interactive Chat State
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  final List<Map<String, dynamic>> _messages = [];

  // Dialogue Script State
  Map<String, dynamic>? _generatedDialogue;
  bool _isLoadingDialogue = false;
  int _conversationEpoch = 0;

  static const Map<String, List<String>> _topicsByLang = {
    'ja': [
      'Daily Standup',
      'Báo cáo Bug & Giải pháp',
      'Thảo luận Code Review',
      'Phỏng vấn IT Tiếng Nhật',
      'Chào hỏi & Xin phép nghỉ',
      'Nhà hàng & Khách sạn',
    ],
    'en': [
      'Daily Standup',
      'Bug Triage & Root Cause',
      'Code Review & Architecture',
      'Tech Job Interview',
      'Client Requirements Meeting',
      'Hospitality & Ordering',
    ],
  };

  static const Map<String, List<String>> _quickPrompts = {
    'ja': [
      '今日の進捗を報告します。 (Báo cáo tiến độ)',
      'バグの修正が完了しました。 (Đã fix xong bug)',
      'コードレビューをお願いできますか？ (Nhờ review PR)',
      '仕様について質問があります。 (Hỏi về specs)',
    ],
    'en': [
      'I completed the API integration yesterday.',
      'We identified a memory leak in the worker thread.',
      'Could you take a look at my pull request?',
      'Let’s schedule a quick sync to unblock this task.',
    ],
  };

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? ApiService();
    _tabController = TabController(length: 2, vsync: this);
    _initInitialMessages();
  }

  void _initInitialMessages() {
    _conversationEpoch++;
    _isLoading = false;
    _isLoadingDialogue = false;
    _messages.clear();
    if (_selectedLanguage == 'ja') {
      _messages.add({
        'sender': 'ai',
        'text': 'こんにちは！今日のデイリースタンドアップを始めましょう。昨日の進捗と今日の予定を教えてください。',
        'romaji':
            'Konnichiwa! Kyou no deirii sutandoappu wo hajimemashou. Kinou no shinchoku to kyou no yotei wo oshiete kudasai.',
        'translation_vi':
            'Xin chào! Hãy bắt đầu buổi họp standup hôm nay. Hãy cho tôi biết tiến độ hôm qua và kế hoạch hôm nay của bạn.',
        'breakdown': [
          {'word': '進捗', 'meaning_vi': 'Tiến độ', 'phonetic': 'しんちょく'},
          {'word': '予定', 'meaning_vi': 'Kế hoạch / Dự định', 'phonetic': 'よてい'},
        ],
        'writing_challenge': '進捗',
      });
    } else {
      _messages.add({
        'sender': 'ai',
        'text':
            'Good morning! Let’s start our daily standup meeting. What did you work on yesterday and what is your plan for today?',
        'romaji': '/ɡʊd ˈmɔːrnɪŋ! lets stɑːrt ˈaʊər ˈdeɪli ˈstændʌp/',
        'translation_vi':
            'Chào buổi sáng! Hãy bắt đầu buổi họp standup hàng ngày. Bạn đã làm gì hôm qua và kế hoạch hôm nay là gì?',
        'breakdown': [
          {
            'word': 'standup',
            'meaning_vi': 'họp nhanh đầu ngày',
            'phonetic': '/ˈstænd.ʌp/',
          },
          {'word': 'plan', 'meaning_vi': 'kế hoạch', 'phonetic': '/plæn/'},
        ],
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _messageController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage([String? presetText]) async {
    final text = presetText ?? _messageController.text.trim();
    if (text.isEmpty || _isLoading) return;

    setState(() {
      _messages.add({'sender': 'user', 'text': text});
      _isLoading = true;
    });
    _messageController.clear();
    _scrollToBottom();
    final epoch = _conversationEpoch;

    try {
      final response = await _apiService.sendRoleplayMessage(
        targetLanguage: _selectedLanguage,
        topic: _selectedTopic,
        message: text,
      );

      if (mounted && epoch == _conversationEpoch) {
        setState(() {
          _messages.add({
            'sender': 'ai',
            'text': response['reply'] ?? '',
            'romaji': response['romaji'] ?? '',
            'translation_vi': response['reply_translation_vi'] ?? '',
            'breakdown': response['breakdown'] ?? [],
            'writing_challenge': response['writing_challenge'],
          });
          _isLoading = false;
        });
        _scrollToBottom();
      }
    } catch (_) {
      if (mounted && epoch == _conversationEpoch) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _fetchDialogueScript() async {
    setState(() => _isLoadingDialogue = true);
    final epoch = _conversationEpoch;
    try {
      final res = await _apiService.generateDialogue(
        targetLanguage: _selectedLanguage,
        topic: _selectedTopic,
        profession: _selectedProfession,
        turnCount: 4,
      );
      if (mounted && epoch == _conversationEpoch) {
        setState(() {
          _generatedDialogue = res;
          _isLoadingDialogue = false;
        });
      }
    } catch (_) {
      if (mounted && epoch == _conversationEpoch) {
        setState(() => _isLoadingDialogue = false);
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.smart_toy_rounded, color: Color(0xFF818CF8), size: 22),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'AI Workplace Role-Play',
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
            icon: Icon(
              _showTranslation ? Icons.translate : Icons.g_translate_outlined,
              color: _showTranslation
                  ? const Color(0xFF38BDF8)
                  : const Color(0xFF94A3B8),
            ),
            tooltip: _showTranslation
                ? 'Ẩn bản dịch tiếng Việt'
                : 'Hiện bản dịch tiếng Việt',
            onPressed: () =>
                setState(() => _showTranslation = !_showTranslation),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF6366F1),
          labelColor: Colors.white,
          unselectedLabelColor: const Color(0xFF94A3B8),
          tabs: const [
            Tab(
              icon: Icon(Icons.chat_bubble_outline_rounded, size: 18),
              text: 'Đối Thoại Trực Tiếp',
            ),
            Tab(
              icon: Icon(Icons.menu_book_rounded, size: 18),
              text: 'Kịch Bản Tình Huống',
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          _buildConfigurationHeader(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [_buildInteractiveChatTab(), _buildDialogueScriptTab()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigurationHeader() {
    final topics = _topicsByLang[_selectedLanguage] ?? [];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        border: Border(bottom: BorderSide(color: Color(0xFF334155))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Language Switch
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'ja',
                    label: Text('Tiếng Nhật', style: TextStyle(fontSize: 12)),
                  ),
                  ButtonSegment(
                    value: 'en',
                    label: Text('Tiếng Anh', style: TextStyle(fontSize: 12)),
                  ),
                ],
                selected: {_selectedLanguage},
                onSelectionChanged: (set) {
                  setState(() {
                    _selectedLanguage = set.first;
                    _selectedTopic = _topicsByLang[_selectedLanguage]!.first;
                    _initInitialMessages();
                    _generatedDialogue = null;
                  });
                },
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    return states.contains(WidgetState.selected)
                        ? const Color(0xFF4F46E5)
                        : const Color(0xFF0F172A);
                  }),
                ),
              ),
              // Profession indicator
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.code, size: 14, color: Color(0xFF38BDF8)),
                    const SizedBox(width: 4),
                    Text(
                      'Ngành: $_selectedProfession',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF38BDF8),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Topic scrollable selector
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: topics.map((t) {
                final isSel = t == _selectedTopic;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(
                      t,
                      style: TextStyle(
                        fontSize: 11,
                        color: isSel ? Colors.white : const Color(0xFF94A3B8),
                      ),
                    ),
                    selected: isSel,
                    selectedColor: const Color(0xFF4F46E5),
                    backgroundColor: const Color(0xFF0F172A),
                    side: BorderSide(
                      color: isSel
                          ? const Color(0xFF6366F1)
                          : const Color(0xFF334155),
                    ),
                    onSelected: (_) {
                      setState(() {
                        _selectedTopic = t;
                        _initInitialMessages();
                        _generatedDialogue = null;
                      });
                    },
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInteractiveChatTab() {
    final prompts = _quickPrompts[_selectedLanguage] ?? [];

    return Column(
      children: [
        // Message list
        Expanded(
          child: ListView.builder(
            controller: _chatScrollController,
            padding: const EdgeInsets.all(12),
            itemCount: _messages.length + (_isLoading ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == _messages.length && _isLoading) {
                return _buildAiTypingIndicator();
              }
              final msg = _messages[index];
              final isUser = msg['sender'] == 'user';
              return isUser
                  ? _buildUserBubble(msg['text'])
                  : _buildAiBubble(msg);
            },
          ),
        ),

        // Quick suggestions bar
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: prompts.map((p) {
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  label: Text(
                    p,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFCBD5E1),
                    ),
                  ),
                  backgroundColor: const Color(0xFF1E293B),
                  side: const BorderSide(color: Color(0xFF334155)),
                  onPressed: () => _sendMessage(p.split(' (').first),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 4),

        // Input bar
        Container(
          padding: const EdgeInsets.all(10),
          decoration: const BoxDecoration(
            color: Color(0xFF1E293B),
            border: Border(top: BorderSide(color: Color(0xFF334155))),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _messageController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: _selectedLanguage == 'ja'
                        ? 'Nhập câu trả lời (tiếng Nhật hoặc Romaji)...'
                        : 'Type your message in English...',
                    hintStyle: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 13,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(color: Color(0xFF334155)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(color: Color(0xFF334155)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(color: Color(0xFF6366F1)),
                    ),
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: const Icon(Icons.send_rounded, size: 18),
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF4F46E5),
                  foregroundColor: Colors.white,
                ),
                onPressed: _isLoading ? null : () => _sendMessage(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUserBubble(String text) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10, left: 40),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF4F46E5),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ),
    );
  }

  Widget _buildAiBubble(Map<String, dynamic> msg) {
    final text = msg['text'] as String? ?? '';
    final romaji = msg['romaji'] as String? ?? '';
    final translation = msg['translation_vi'] as String? ?? '';
    final breakdown = (msg['breakdown'] as List<dynamic>?) ?? [];
    final writingChallenge = msg['writing_challenge'] as String?;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12, right: 30),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomRight: Radius.circular(14),
          ),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Speaker header
            const Row(
              children: [
                Icon(
                  Icons.smart_toy_rounded,
                  size: 14,
                  color: Color(0xFF818CF8),
                ),
                SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'AI Mentor (Colleague)',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF818CF8),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Main dialogue line
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      height: 1.4,
                    ),
                  ),
                ),
                TtsSpeakerButton(
                  text: text,
                  language: _selectedLanguage,
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  tooltip: 'Phát âm câu thoại',
                  ttsService: widget.ttsService,
                ),
              ],
            ),

            // Romaji or Phonetic subtitle
            if (romaji.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                romaji,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF38BDF8),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],

            // Vietnamese translation
            if (_showTranslation && translation.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Dịch: $translation',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF94A3B8),
                  ),
                ),
              ),
            ],

            // Vocabulary Breakdown Badges
            if (breakdown.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Từ vựng trọng tâm trong câu:',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFCBD5E1),
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: breakdown.map((item) {
                  final word = item['word']?.toString() ?? '';
                  final meaning = item['meaning_vi']?.toString() ?? '';
                  final phonetic =
                      item['kana_or_phonetic']?.toString() ??
                      item['phonetic']?.toString() ??
                      '';
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          word,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF34D399),
                          ),
                        ),
                        if (phonetic.isNotEmpty) ...[
                          Text(
                            '($phonetic)',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF38BDF8),
                            ),
                          ),
                        ],
                        Text(
                          '• $meaning',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                        TtsChipSpeakerIcon(
                          text: word,
                          language: _selectedLanguage,
                          size: 14,
                          ttsService: widget.ttsService,
                        ),
                        if (_selectedLanguage == 'ja' &&
                            widget.onPracticeWord != null) ...[
                          InkWell(
                            onTap: () =>
                                widget.onPracticeWord!(word, _selectedLanguage),
                            child: const Padding(
                              padding: EdgeInsets.all(2),
                              child: Icon(
                                Icons.draw_rounded,
                                size: 14,
                                color: Color(0xFF818CF8),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],

            // Writing challenge banner
            if (_selectedLanguage == 'ja' &&
                writingChallenge != null &&
                widget.onPracticeWord != null) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () =>
                    widget.onPracticeWord!(writingChallenge, _selectedLanguage),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF312E81),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF6366F1)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.gesture,
                        size: 16,
                        color: Color(0xFF818CF8),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Thử thách viết: "$writingChallenge" (Chạm để mở Canvas)',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAiTypingIndicator() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF818CF8),
              ),
            ),
            SizedBox(width: 8),
            Text(
              'AI đang suy nghĩ phản hồi...',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDialogueScriptTab() {
    if (_generatedDialogue == null && !_isLoadingDialogue) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.auto_stories_rounded,
              size: 48,
              color: Color(0xFF64748B),
            ),
            const SizedBox(height: 12),
            Text(
              'Chưa có kịch bản mẫu cho chủ đề: "$_selectedTopic"',
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
            ),
            const SizedBox(height: 14),
            ElevatedButton.icon(
              onPressed: _fetchDialogueScript,
              icon: const Icon(Icons.auto_awesome_rounded, size: 18),
              label: const Text('Sinh kịch bản với AI Local'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4F46E5),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_isLoadingDialogue) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFF818CF8)),
            SizedBox(height: 12),
            Text(
              'Đang tạo kịch bản đối thoại với AI...',
              style: TextStyle(color: Color(0xFF94A3B8)),
            ),
          ],
        ),
      );
    }

    final turns = (_generatedDialogue!['turns'] as List<dynamic>?) ?? [];
    final vocab =
        (_generatedDialogue!['key_vocabulary'] as List<dynamic>?) ?? [];

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Kịch bản: ${_generatedDialogue!['topic'] ?? _selectedTopic}',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Colors.white,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded, color: Color(0xFF818CF8)),
              tooltip: 'Tạo lại kịch bản khác',
              onPressed: _fetchDialogueScript,
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Turns list
        ...turns.map((turn) {
          final speaker = turn['speaker']?.toString() ?? '';
          final text = turn['text']?.toString() ?? '';
          final phonetic = turn['romaji_or_phonetic']?.toString() ?? '';
          final trans = turn['translation_vi']?.toString() ?? '';

          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color:
                            speaker.contains('Lead') ||
                                speaker.contains('Leader')
                            ? const Color(0xFF0284C7)
                            : const Color(0xFF4F46E5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        speaker,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        text,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    TtsSpeakerButton(
                      text: text,
                      language: _selectedLanguage,
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      tooltip: 'Phát âm câu thoại',
                      ttsService: widget.ttsService,
                    ),
                  ],
                ),
                if (phonetic.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    phonetic,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF38BDF8),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                if (_showTranslation && trans.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '• $trans',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ],
            ),
          );
        }),

        // Key vocabulary section
        if (vocab.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text(
            'Từ vựng trọng tâm trong bài:',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Color(0xFF34D399),
            ),
          ),
          const SizedBox(height: 8),
          ...vocab.map((v) {
            final word = v['word']?.toString() ?? '';
            final meaning = v['meaning_vi']?.toString() ?? '';
            final pho =
                v['kana_or_phonetic']?.toString() ??
                v['phonetic']?.toString() ??
                '';

            return Card(
              color: const Color(0xFF0F172A),
              margin: const EdgeInsets.only(bottom: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: Color(0xFF334155)),
              ),
              child: ListTile(
                dense: true,
                title: Text(
                  word,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    fontSize: 14,
                  ),
                ),
                subtitle: Text(
                  pho.isNotEmpty ? '$pho • $meaning' : meaning,
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 12,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TtsSpeakerButton(
                      text: word,
                      language: _selectedLanguage,
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      tooltip: 'Phát âm "$word"',
                      ttsService: widget.ttsService,
                    ),
                    if (_selectedLanguage == 'ja' &&
                        widget.onPracticeWord != null)
                      TextButton.icon(
                        icon: const Icon(Icons.draw_rounded, size: 14),
                        label: const Text(
                          'Luyện viết',
                          style: TextStyle(fontSize: 11),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF818CF8),
                        ),
                        onPressed: () =>
                            widget.onPracticeWord!(word, _selectedLanguage),
                      ),
                  ],
                ),
              ),
            );
          }),
        ],
      ],
    );
  }
}
