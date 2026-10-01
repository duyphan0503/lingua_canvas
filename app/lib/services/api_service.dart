import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/lesson_item.dart';
import 'fsrs_engine.dart';

class ApiService {
  static const String baseUrl = 'http://127.0.0.1:8080/api/v1';

  final FSRSEngine _fsrsEngine = FSRSEngine();

  /// Default fallback lessons in case backend is offline
  final List<LessonItem> _fallbackLessons = [
    LessonItem(
      id: "ja_hira_a",
      language: "ja",
      category: "alphabet",
      targetText: "あ",
      phoneticOrKana: "a",
      meaningVi: "Chữ cái Hiragana: A",
      workplaceContext: "ありがとうございます (Arigatou gozaimasu)",
      workplaceContextVi:
          "Cảm ơn quý khách/anh chị rất nhiều (môi trường công sở)",
      strokeOrderHints: [
        "Nét 1: Gạch ngang ngắn từ trái sang phải",
        "Nét 2: Nét dọc hơi cong từ trên xuống cắt nét 1",
        "Nét 3: Vòng tròn mở phía dưới bắt đầu từ trái cuộn sang phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_i",
      language: "ja",
      category: "alphabet",
      targetText: "い",
      phoneticOrKana: "i",
      meaningVi: "Chữ cái Hiragana: I",
      workplaceContext: "いいえ、大丈夫です (Iie, daijoubu desu)",
      workplaceContextVi: "Không sao, mọi thứ ổn",
      strokeOrderHints: [
        "Nét 1: Nét cong bên trái, có móc nhẹ hất lên ở đuôi",
        "Nét 2: Nét cong ngắn hơn bên phải hướng xuống",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_kata_bug",
      language: "ja",
      category: "it_workplace",
      targetText: "バグ",
      phoneticOrKana: "bagu",
      meaningVi: "Lỗi phần mềm (Bug)",
      workplaceContext: "この機能に重大なバグが発生しました",
      workplaceContextVi:
          "Chức năng này đã phát sinh một con bug nghiêm trọng.",
      strokeOrderHints: [
        "Chữ バ (Ba): Viết nét ハ (Ha) rồi thêm 2 dấu phẩy đục âm ゛",
        "Chữ グ (Gu): Viết nét ク (Ku) rồi thêm 2 dấu phẩy ゛",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_it_kaihatsu",
      language: "ja",
      category: "it_workplace",
      targetText: "開発",
      phoneticOrKana: "かいはつ (kaihatsu)",
      meaningVi: "Phát triển phần mềm (Development)",
      workplaceContext: "新しいシステムの開発チームに参加します",
      workplaceContextVi:
          "Tôi sẽ tham gia vào đội ngũ phát triển hệ thống mới.",
      strokeOrderHints: [
        "Chữ 開 (Khai): Bộ môn 門 bao ngoài, bên trong chữ khai",
        "Chữ 発 (Phát): Bộ bát bên trên, các nét cung phẩy bên dưới",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_it_deploy",
      language: "en",
      category: "it_workplace",
      targetText: "deploy",
      phoneticOrKana: "/dɪˈplɔɪ/",
      meaningVi: "Triển khai phần mềm lên server",
      workplaceContext:
          "We are ready to deploy the release to production tonight.",
      workplaceContextVi:
          "Chúng tôi đã sẵn sàng triển khai phiên bản mới lên production tối nay.",
      strokeOrderHints: [
        "Viết thường 'd-e-p-l-o-y'",
        "Chú ý nét đuôi chữ 'p' và 'y' kéo xuống dưới dòng kẻ",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "en_it_deadline",
      language: "en",
      category: "it_workplace",
      targetText: "deadline",
      phoneticOrKana: "/ˈded.laɪn/",
      meaningVi: "Hạn chót hoàn thành công việc",
      workplaceContext:
          "Can we extend the deadline for this sprint task by two days?",
      workplaceContextVi:
          "Chúng ta có thể gia hạn deadline thêm hai ngày được không?",
      strokeOrderHints: [
        "Viết 'd-e-a-d-l-i-n-e'",
        "Nối các ký tự liền mạch để ghi nhớ cơ bắp",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "en_it_resolve",
      language: "en",
      category: "it_workplace",
      targetText: "resolve",
      phoneticOrKana: "/rɪˈzɑːlv/",
      meaningVi: "Giải quyết triệt để (bug, vấn đề)",
      workplaceContext:
          "I will investigate and resolve the API timeout issue before lunch.",
      workplaceContextVi:
          "Tôi sẽ điều tra và xử lý dứt điểm sự cố timeout trước bữa trưa.",
      strokeOrderHints: ["Viết thường 'r-e-s-o-l-v-e'"],
      difficultyLevel: 1,
    ),
  ];

  Future<List<LessonItem>> getLessons({String? language}) async {
    try {
      final uri = Uri.parse(
        '$baseUrl/lessons${language != null ? '?language=$language' : ''}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 2));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => LessonItem.fromJson(json)).toList();
      }
    } catch (_) {
      // Backend is offline or not reachable, use offline data
    }

    if (language != null) {
      return _fallbackLessons.where((l) => l.language == language).toList();
    }
    return _fallbackLessons;
  }

  Future<void> submitReview({
    required String itemId,
    required FSRSRating rating,
  }) async {
    // 1. Try sync with Rust server
    try {
      final uri = Uri.parse('$baseUrl/fsrs/review');
      await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'item_id': itemId, 'rating': rating.index + 1}),
          )
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Offline fallback
    }

    // 2. Save locally with SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final cardJsonStr = prefs.getString('fsrs_card_$itemId');
    FSRSCard card;
    if (cardJsonStr != null) {
      card = FSRSCard.fromJson(jsonDecode(cardJsonStr));
    } else {
      card = FSRSCard.initial(itemId);
    }

    final updatedCard = _fsrsEngine.review(
      card,
      rating,
      DateTime.now().toUtc(),
    );
    await prefs.setString(
      'fsrs_card_$itemId',
      jsonEncode(updatedCard.toJson()),
    );

    // Increment completed handwriting counter
    final currentCount = prefs.getInt('handwriting_completed_count') ?? 0;
    await prefs.setInt('handwriting_completed_count', currentCount + 1);
  }

  Future<int> getCompletedCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('handwriting_completed_count') ?? 0;
  }

  Future<Map<String, dynamic>> sendRoleplayMessage({
    required String targetLanguage,
    required String topic,
    required String message,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/ai/roleplay');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'target_language': targetLanguage,
              'topic': topic,
              'user_level': 'beginner',
              'user_message': message,
            }),
          )
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (_) {
      // Local fallback
    }

    if (targetLanguage == 'ja') {
      return {
        'reply': 'お疲れ様です！進捗はどうですか？何かバグや問題があればいつでも相談してください。',
        'reply_translation_vi':
            'Chào bạn, vất vả rồi! Tiến độ thế nào rồi? Có khó khăn gì cứ trao đổi nhé.',
        'breakdown': [
          {
            'word': '進捗',
            'meaning_vi': 'Tiến độ công việc',
            'kana_or_phonetic': 'しんちょく',
          },
          {
            'word': '相談',
            'meaning_vi': 'Trao đổi, thảo luận',
            'kana_or_phonetic': 'そうだん',
          },
        ],
        'writing_challenge': '進捗',
      };
    } else {
      return {
        'reply':
            'Good morning! Did you push the latest commit to Git? We should test the build before our standup meeting.',
        'reply_translation_vi':
            'Chào buổi sáng! Bạn đã đẩy commit mới nhất lên Git chưa? Chúng ta nên kiểm tra bản build trước buổi họp standup.',
        'breakdown': [
          {
            'word': 'commit',
            'meaning_vi': 'lưu code trong Git',
            'kana_or_phonetic': '/kəˈmɪt/',
          },
          {
            'word': 'standup',
            'meaning_vi': 'họp nhanh đầu ngày',
            'kana_or_phonetic': '/ˈstænd.ʌp/',
          },
        ],
        'writing_challenge': 'commit',
      };
    }
  }
}
