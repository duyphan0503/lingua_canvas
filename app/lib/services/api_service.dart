import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import '../models/lesson_item.dart';
import 'phase3_lessons.dart';
import 'account_service.dart';
import 'fsrs_engine.dart';
import 'local_database.dart';
import 'sync_coordinator.dart';

export 'local_database.dart' show StudyStreak;

class ApiService {
  static const String _configuredBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
  );
  static String defaultBaseUrl = _configuredBaseUrl.isNotEmpty
      ? _configuredBaseUrl
      : 'http://127.0.0.1:8080/api/v1';

  String _baseUrl;
  final FSRSEngine _fsrsEngine;
  final LocalDatabase _localDb;
  late SyncCoordinator _syncCoordinator;

  ApiService({
    String? baseUrl,
    FSRSEngine? fsrsEngine,
    LocalDatabase? localDb,
    SyncCoordinator? syncCoordinator,
  }) : _baseUrl = baseUrl ?? defaultBaseUrl,
       _fsrsEngine = fsrsEngine ?? FSRSEngine(),
       _localDb = localDb ?? LocalDatabase.instance {
    _syncCoordinator =
        syncCoordinator ??
        SyncCoordinator(
          localDb: _localDb,
          fsrsEngine: _fsrsEngine,
          baseUrl: _baseUrl,
        );
  }

  String get baseUrl => _baseUrl;

  void setBaseUrl(String newUrl) {
    final uri = Uri.tryParse(newUrl.trim());
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException(
        'Địa chỉ máy chủ phải là URL HTTP hoặc HTTPS hợp lệ.',
      );
    }
    _baseUrl = uri.toString().replaceFirst(RegExp(r'/+$'), '');
    _syncCoordinator = SyncCoordinator(
      localDb: _localDb,
      fsrsEngine: _fsrsEngine,
      baseUrl: _baseUrl,
    );
  }

  SyncCoordinator get syncCoordinator => _syncCoordinator;
  LocalDatabase get localDatabase => _localDb;

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
          "Cảm ơn quý khách/anh chị rất nhiều (câu cửa miệng trong môi trường làm việc)",
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
      workplaceContextVi: "Không sao, tôi ổn/mọi thứ ổn",
      strokeOrderHints: [
        "Nét 1: Nét cong bên trái, có móc nhẹ hất lên ở đuôi",
        "Nét 2: Nét cong ngắn hơn bên phải hướng xuống",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_u",
      language: "ja",
      category: "alphabet",
      targetText: "う",
      phoneticOrKana: "u",
      meaningVi: "Chữ cái Hiragana: U",
      workplaceContext: "うまく動作しています (Umaku dousa shite imasu)",
      workplaceContextVi: "Hệ thống đang hoạt động trơn tru/tốt đẹp",
      strokeOrderHints: [
        "Nét 1: Dấu phẩy ngắn chéo nhẹ ở trên",
        "Nét 2: Đường cong lớn hình cung mở sang trái",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_e",
      language: "ja",
      category: "alphabet",
      targetText: "え",
      phoneticOrKana: "e",
      meaningVi: "Chữ cái Hiragana: E",
      workplaceContext: "エラーが発生しました (Eraa ga hassei shimashita)",
      workplaceContextVi: "Đã phát sinh thông báo lỗi",
      strokeOrderHints: [
        "Nét 1: Dấu phẩy ngắn nằm chéo bên trên",
        "Nét 2: Nét zic-zac kéo xuống rồi lượn sóng ngang phía dưới",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_o",
      language: "ja",
      category: "alphabet",
      targetText: "お",
      phoneticOrKana: "o",
      meaningVi: "Chữ cái Hiragana: O",
      workplaceContext: "お疲れ様です (Otsukaresama desu)",
      workplaceContextVi:
          "Anh/chị đã vất vả rồi (lời chào quen thuộc trong công ty)",
      strokeOrderHints: [
        "Nét 1: Nét ngang ngắn",
        "Nét 2: Nét sổ thẳng cắt ngang nét 1 rồi vòng bụng lớn sang phải",
        "Nét 3: Dấu chấm chéo bên phải trên",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ka",
      language: "ja",
      category: "alphabet",
      targetText: "か",
      phoneticOrKana: "ka",
      meaningVi: "Chữ cái Hiragana: Ka",
      workplaceContext: "開発が順調です (Kaihatsu ga junchou desu)",
      workplaceContextVi: "Tiến độ phát triển đang diễn ra thuận lợi",
      strokeOrderHints: [
        "Nét 1: Nét cong có móc sang trái",
        "Nét 2: Nét chéo thẳng cắt ngang thân",
        "Nét 3: Dấu phẩy ngắn bên phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ki",
      language: "ja",
      category: "alphabet",
      targetText: "き",
      phoneticOrKana: "ki",
      meaningVi: "Chữ cái Hiragana: Ki",
      workplaceContext: "基本設計をまとめます (Kihon sekkei wo matomemasu)",
      workplaceContextVi: "Tổng hợp tài liệu thiết kế cơ bản",
      strokeOrderHints: [
        "Nét 1: Nét ngang trên hơi dốc lên",
        "Nét 2: Nét ngang dưới song song",
        "Nét 3: Nét chéo cắt hai nét ngang và lượn cung hở",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ku",
      language: "ja",
      category: "alphabet",
      targetText: "く",
      phoneticOrKana: "ku",
      meaningVi: "Chữ cái Hiragana: Ku",
      workplaceContext: "クライアントの要望です (Kuraianto no youbou desu)",
      workplaceContextVi: "Đây là yêu cầu từ phía khách hàng",
      strokeOrderHints: [
        "Nét 1: Nét gập góc nhọn mở sang phải hình dấu ngoặc nhỏ",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ke",
      language: "ja",
      category: "alphabet",
      targetText: "け",
      phoneticOrKana: "ke",
      meaningVi: "Chữ cái Hiragana: Ke",
      workplaceContext: "結果を報告します (Kekka wo houkoku shimasu)",
      workplaceContextVi: "Tôi xin báo cáo kết quả kiểm thử",
      strokeOrderHints: [
        "Nét 1: Nét sổ hơi cong có móc bên trái",
        "Nét 2: Nét ngang ngắn bên phải",
        "Nét 3: Nét sổ thẳng hơi cong bên phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ko",
      language: "ja",
      category: "alphabet",
      targetText: "こ",
      phoneticOrKana: "ko",
      meaningVi: "Chữ cái Hiragana: Ko",
      workplaceContext: "コードをコミットしました (Koodo wo komitto shimashita)",
      workplaceContextVi: "Tôi đã commit mã nguồn lên repo",
      strokeOrderHints: [
        "Nét 1: Nét ngang trên có móc nhẹ",
        "Nét 2: Nét ngang dưới hơi cong vòng lên",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_sa",
      language: "ja",
      category: "alphabet",
      targetText: "さ",
      phoneticOrKana: "sa",
      meaningVi: "Chữ cái Hiragana: Sa",
      workplaceContext: "サーバーが再起動しました (Saabaa ga saikidou shimashita)",
      workplaceContextVi: "Máy chủ đã khởi động lại thành công",
      strokeOrderHints: [
        "Nét 1: Nét ngang hơi dốc lên",
        "Nét 2: Nét chéo cắt ngang có móc",
        "Nét 3: Nét cong mở phía dưới",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_shi",
      language: "ja",
      category: "alphabet",
      targetText: "し",
      phoneticOrKana: "shi",
      meaningVi: "Chữ cái Hiragana: Shi",
      workplaceContext: "仕様を確認します (Shiyou wo kakunin shimasu)",
      workplaceContextVi: "Tôi sẽ xác nhận lại thông số đặc tả",
      strokeOrderHints: [
        "Nét 1: Nét sổ thẳng từ trên xuống rồi cong móc lên sang phải như hình lưỡi câu",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_su",
      language: "ja",
      category: "alphabet",
      targetText: "す",
      phoneticOrKana: "su",
      meaningVi: "Chữ cái Hiragana: Su",
      workplaceContext: "すぐに修正します (Sugu ni shuusei shimasu)",
      workplaceContextVi: "Tôi sẽ sửa lỗi này ngay lập tức",
      strokeOrderHints: [
        "Nét 1: Nét ngang dài",
        "Nét 2: Nét sổ cắt ngang cuộn một vòng tròn nhỏ rồi kéo đuôi xuống",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_se",
      language: "ja",
      category: "alphabet",
      targetText: "せ",
      phoneticOrKana: "se",
      meaningVi: "Chữ cái Hiragana: Se",
      workplaceContext: "セキュリティ対策が必要です (Sekyuriti taisaku ga hitsuyou desu)",
      workplaceContextVi: "Cần thực hiện các biện pháp an ninh bảo mật",
      strokeOrderHints: [
        "Nét 1: Nét ngang dài",
        "Nét 2: Nét sổ ngắn bên phải gập ngang sang trái",
        "Nét 3: Nét sổ đứng bên trái có móc",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_so",
      language: "ja",
      category: "alphabet",
      targetText: "そ",
      phoneticOrKana: "so",
      meaningVi: "Chữ cái Hiragana: So",
      workplaceContext: "その問題について相談します (Sono mondai ni tsuite soudan shimasu)",
      workplaceContextVi: "Tôi xin phép trao đổi thảo luận về vấn đề đó",
      strokeOrderHints: [
        "Nét 1: Nét zic-zac gập nối liền nét cong cung tròn phía dưới",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ta",
      language: "ja",
      category: "alphabet",
      targetText: "た",
      phoneticOrKana: "ta",
      meaningVi: "Chữ cái Hiragana: Ta",
      workplaceContext: "タスクを完了しました (Tasuku wo kanryou shimashita)",
      workplaceContextVi: "Tôi đã hoàn thành xong nhiệm vụ được giao",
      strokeOrderHints: [
        "Nét 1: Nét ngang ngắn",
        "Nét 2: Nét chéo cắt nét 1",
        "Nét 3, 4: Hai nét nhỏ giống chữ こ bên phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_chi",
      language: "ja",
      category: "alphabet",
      targetText: "ち",
      phoneticOrKana: "chi",
      meaningVi: "Chữ cái Hiragana: Chi",
      workplaceContext: "チームと共有します (Chiimu to kyouyuu shimasu)",
      workplaceContextVi: "Tôi sẽ chia sẻ thông tin này với toàn đội ngũ",
      strokeOrderHints: [
        "Nét 1: Nét ngang ngắn",
        "Nét 2: Nét sổ chéo cắt nét 1 rồi uốn vòng bụng lớn sang phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_tsu",
      language: "ja",
      category: "alphabet",
      targetText: "つ",
      phoneticOrKana: "tsu",
      meaningVi: "Chữ cái Hiragana: Tsu",
      workplaceContext: "ツールを導入します (Tsuuru wo dounyuu shimasu)",
      workplaceContextVi: "Áp dụng công cụ mới vào quy trình làm việc",
      strokeOrderHints: ["Nét 1: Nét cong lớn hình lưỡi liềm mở sang trái"],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_te",
      language: "ja",
      category: "alphabet",
      targetText: "て",
      phoneticOrKana: "te",
      meaningVi: "Chữ cái Hiragana: Te",
      workplaceContext: "テストを実施します (Tesuto wo jisshi shimasu)",
      workplaceContextVi: "Tiến hành thực thi các ca kiểm thử",
      strokeOrderHints: [
        "Nét 1: Nét ngang hơi lượn rồi uốn cong tròn nửa cung sang phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_to",
      language: "ja",
      category: "alphabet",
      targetText: "と",
      phoneticOrKana: "to",
      meaningVi: "Chữ cái Hiragana: To",
      workplaceContext: "ドキュメントをまとめました (Dokyumento wo matomemashita)",
      workplaceContextVi: "Tôi đã tổng hợp tài liệu đầy đủ",
      strokeOrderHints: [
        "Nét 1: Nét chéo ngắn từ trái sang phải",
        "Nét 2: Nét cong hình chữ C mở sang trái tiếp giáp",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_na",
      language: "ja",
      category: "alphabet",
      targetText: "な",
      phoneticOrKana: "na",
      meaningVi: "Chữ cái Hiragana: Na",
      workplaceContext: "何名で参加しますか (Nanmei de sanka shimasu ka)",
      workplaceContextVi: "Bên mình sẽ có bao nhiêu người tham dự cuộc họp?",
      strokeOrderHints: [
        "Nét 1: Nét ngang ngắn",
        "Nét 2: Nét chéo cắt nét 1",
        "Nét 3: Dấu phẩy nhỏ",
        "Nét 4: Nét cuộn thắt vòng bên dưới",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ni",
      language: "ja",
      category: "alphabet",
      targetText: "に",
      phoneticOrKana: "ni",
      meaningVi: "Chữ cái Hiragana: Ni",
      workplaceContext: "日程を調整しましょう (Nittei wo chousei shimashou)",
      workplaceContextVi: "Chúng ta cùng sắp xếp lại lịch trình nhé",
      strokeOrderHints: [
        "Nét 1: Nét sổ hơi cong bên trái",
        "Nét 2, 3: Hai nét ngang song song ngắn bên phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_nu",
      language: "ja",
      category: "alphabet",
      targetText: "ぬ",
      phoneticOrKana: "nu",
      meaningVi: "Chữ cái Hiragana: Nu",
      workplaceContext: "抜け漏れがないか確認します (Nukemore ga nai ka kakunin shimasu)",
      workplaceContextVi: "Kiểm tra kỹ xem có bị thiếu sót điểm nào không",
      strokeOrderHints: [
        "Nét 1: Nét chéo từ trái sang phải",
        "Nét 2: Nét uốn vòng bao quanh và thắt nút tròn ở đuôi",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ne",
      language: "ja",
      category: "alphabet",
      targetText: "ね",
      phoneticOrKana: "ne",
      meaningVi: "Chữ cái Hiragana: Ne",
      workplaceContext: "ネットワークの疎通確認 (Nettowaaku no sotsuu kakunin)",
      workplaceContextVi: "Kiểm tra kết nối thông mạng",
      strokeOrderHints: [
        "Nét 1: Nét sổ dọc bên trái",
        "Nét 2: Nét zic-zac kéo sang rồi uốn thắt nút vòng tròn nhỏ ở đuôi",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_no",
      language: "ja",
      category: "alphabet",
      targetText: "の",
      phoneticOrKana: "no",
      meaningVi: "Chữ cái Hiragana: No",
      workplaceContext: "納期の遵守をお願いします (Nouki no junshu wo onegai shimasu)",
      workplaceContextVi: "Xin vui lòng tuân thủ đúng thời hạn bàn giao dự án",
      strokeOrderHints: [
        "Nét 1: Một nét cong xoắn tròn duy nhất từ giữa vòng qua phải sang trái",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ha",
      language: "ja",
      category: "alphabet",
      targetText: "は",
      phoneticOrKana: "ha",
      meaningVi: "Chữ cái Hiragana: Ha",
      workplaceContext: "はい、承知いたしました (Hai, shouchi itashimashita)",
      workplaceContextVi: "Vâng, tôi đã hiểu rõ yêu cầu",
      strokeOrderHints: [
        "Nét 1: Nét sổ hơi cong bên trái",
        "Nét 2: Nét ngang ngắn bên phải",
        "Nét 3: Nét sổ cắt nét 2 cuộn vòng tròn thắt nút",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_hi",
      language: "ja",
      category: "alphabet",
      targetText: "ひ",
      phoneticOrKana: "hi",
      meaningVi: "Chữ cái Hiragana: Hi",
      workplaceContext: "引き継ぎを完了しました (Hikitsugi wo kanryou shimashita)",
      workplaceContextVi: "Đã hoàn thành bàn giao công việc",
      strokeOrderHints: [
        "Nét 1: Một nét duy nhất: ngang ngắn, vòng đáy cong sâu rồi móc lên nhẹ",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_fu",
      language: "ja",
      category: "alphabet",
      targetText: "ふ",
      phoneticOrKana: "fu",
      meaningVi: "Chữ cái Hiragana: Fu",
      workplaceContext: "不具合を調査中です (Fuguai wo chousachuu desu)",
      workplaceContextVi: "Đang trong quá trình điều tra nguyên nhân sự cố",
      strokeOrderHints: [
        "Nét 1: Dấu chấm phẩy ở trên",
        "Nét 2: Nét móc cong ở giữa",
        "Nét 3, 4: Hai nét phẩy hai bên",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_he",
      language: "ja",
      category: "alphabet",
      targetText: "へ",
      phoneticOrKana: "he",
      meaningVi: "Chữ cái Hiragana: He",
      workplaceContext: "変更履歴を記録します (Henkou rireki wo kiroku shimasu)",
      workplaceContextVi: "Ghi lại nhật ký lịch sử thay đổi",
      strokeOrderHints: [
        "Nét 1: Nét gập hình mái nhà từ trái chếch lên rồi dốc xuống sang phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ho",
      language: "ja",
      category: "alphabet",
      targetText: "ほ",
      phoneticOrKana: "ho",
      meaningVi: "Chữ cái Hiragana: Ho",
      workplaceContext: "報告書を作成しました (Houkokusho wo sakusei shimashita)",
      workplaceContextVi: "Tôi đã soạn thảo xong bản báo cáo",
      strokeOrderHints: [
        "Nét 1: Nét sổ bên trái",
        "Nét 2, 3: Hai nét ngang ngắn bên phải",
        "Nét 4: Nét sổ cắt nét dưới cuộn thắt vòng tròn",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ma",
      language: "ja",
      category: "alphabet",
      targetText: "ま",
      phoneticOrKana: "ma",
      meaningVi: "Chữ cái Hiragana: Ma",
      workplaceContext: "まずは仕様を確認しましょう (Mazu wa shiyou wo kakunin shimashou)",
      workplaceContextVi: "Trước hết hãy cùng làm rõ tài liệu yêu cầu nhé",
      strokeOrderHints: [
        "Nét 1, 2: Hai nét ngang song song",
        "Nét 3: Nét sổ cắt hai nét ngang rồi cuộn vòng tròn phía dưới",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_mi",
      language: "ja",
      category: "alphabet",
      targetText: "み",
      phoneticOrKana: "mi",
      meaningVi: "Chữ cái Hiragana: Mi",
      workplaceContext: "見積もりを提出します (Mitsumori wo teishutsu shimasu)",
      workplaceContextVi: "Gửi bản báo giá/ước lượng khối lượng công việc",
      strokeOrderHints: [
        "Nét 1: Nét ngang hơi cong thắt nút rồi kéo chéo sang phải",
        "Nét 2: Nét phẩy cong cắt nét chéo",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_mu",
      language: "ja",
      category: "alphabet",
      targetText: "む",
      phoneticOrKana: "mu",
      meaningVi: "Chữ cái Hiragana: Mu",
      workplaceContext: "無理のないスケジュールです (Muri no nai sukejuuru desu)",
      workplaceContextVi: "Lịch trình này rất hợp lý và khả thi",
      strokeOrderHints: [
        "Nét 1: Nét ngang ngắn",
        "Nét 2: Nét sổ xuống thắt vòng rồi hất lên bên phải",
        "Nét 3: Dấu chấm bên phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_me",
      language: "ja",
      category: "alphabet",
      targetText: "め",
      phoneticOrKana: "me",
      meaningVi: "Chữ cái Hiragana: Me",
      workplaceContext: "メールで連絡します (Meeru de renraku shimasu)",
      workplaceContextVi: "Tôi sẽ liên hệ trao đổi chi tiết qua email",
      strokeOrderHints: [
        "Nét 1: Nét chéo từ trái trên xuống phải",
        "Nét 2: Nét uốn vòng từ trên qua trái rồi bao quanh",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_mo",
      language: "ja",
      category: "alphabet",
      targetText: "も",
      phoneticOrKana: "mo",
      meaningVi: "Chữ cái Hiragana: Mo",
      workplaceContext: "問題ありません (Mondai arimasen)",
      workplaceContextVi: "Không có vấn đề gì phát sinh cả",
      strokeOrderHints: [
        "Nét 1: Nét sổ cong móc lên như lưỡi câu",
        "Nét 2, 3: Hai nét ngang cắt ngang thân nét sổ",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ya",
      language: "ja",
      category: "alphabet",
      targetText: "や",
      phoneticOrKana: "ya",
      meaningVi: "Chữ cái Hiragana: Ya",
      workplaceContext: "役職と担当業務 (Yakushoku to tantou gyoumu)",
      workplaceContextVi: "Vị trí chức danh và nghiệp vụ phụ trách",
      strokeOrderHints: [
        "Nét 1: Nét cong móc trên",
        "Nét 2: Nét phẩy ngắn phía trên nét cong",
        "Nét 3: Nét chéo cắt thân",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_yu",
      language: "ja",
      category: "alphabet",
      targetText: "ゆ",
      phoneticOrKana: "yu",
      meaningVi: "Chữ cái Hiragana: Yu",
      workplaceContext: "ユーザーのフィードバック (Yuuzaa no fiidobakku)",
      workplaceContextVi: "Ý kiến đóng góp từ người dùng",
      strokeOrderHints: [
        "Nét 1: Nét sổ hơi cong vòng dưới rồi kéo lên cắt ngang",
        "Nét 2: Nét sổ thẳng cắt ngang nét 1",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_yo",
      language: "ja",
      category: "alphabet",
      targetText: "よ",
      phoneticOrKana: "yo",
      meaningVi: "Chữ cái Hiragana: Yo",
      workplaceContext: "よろしくお願いします (Yoroshiku onegai shimasu)",
      workplaceContextVi: "Rất mong nhận được sự hỗ trợ từ anh/chị",
      strokeOrderHints: [
        "Nét 1: Nét ngang ngắn",
        "Nét 2: Nét sổ xuống thắt nút xoay tròn sang trái rồi kéo sang",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ra",
      language: "ja",
      category: "alphabet",
      targetText: "ら",
      phoneticOrKana: "ra",
      meaningVi: "Chữ cái Hiragana: Ra",
      workplaceContext: "来週リリース予定です (Raishuu ririisu yotei desu)",
      workplaceContextVi: "Dự kiến sẽ phát hành tính năng vào tuần tới",
      strokeOrderHints: [
        "Nét 1: Dấu phẩy ngắn phía trên",
        "Nét 2: Nét cong mở sang trái phía dưới",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ri",
      language: "ja",
      category: "alphabet",
      targetText: "り",
      phoneticOrKana: "ri",
      meaningVi: "Chữ cái Hiragana: Ri",
      workplaceContext: "リリース判定会議 (Ririisu hantei kaigi)",
      workplaceContextVi: "Cuộc họp thẩm định đủ điều kiện phát hành sản phẩm",
      strokeOrderHints: [
        "Nét 1: Nét sổ ngắn bên trái có móc",
        "Nét 2: Nét sổ dài hơi cong bên phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ru",
      language: "ja",
      category: "alphabet",
      targetText: "る",
      phoneticOrKana: "ru",
      meaningVi: "Chữ cái Hiragana: Ru",
      workplaceContext: "ルールに従って開発します (Ruuru ni shitagatte kaihatsu shimasu)",
      workplaceContextVi: "Phát triển tuân thủ đúng quy tắc dự án đề ra",
      strokeOrderHints: [
        "Nét 1: Một nét liên tục: ngang rồi chéo rồi vòng cung tròn thắt nút nhỏ bên trong",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_re",
      language: "ja",
      category: "alphabet",
      targetText: "れ",
      phoneticOrKana: "re",
      meaningVi: "Chữ cái Hiragana: Re",
      workplaceContext: "連絡をお待ちしております (Renraku wo omachi shite orimasu)",
      workplaceContextVi:
          "Chúng tôi rất mong sớm nhận được phản hồi từ quý đối tác",
      strokeOrderHints: [
        "Nét 1: Nét sổ dọc bên trái",
        "Nét 2: Nét zic-zac kéo sang rồi hất móc nhọn ra ngoài",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_ro",
      language: "ja",
      category: "alphabet",
      targetText: "ろ",
      phoneticOrKana: "ro",
      meaningVi: "Chữ cái Hiragana: Ro",
      workplaceContext: "ログを確認してください (Rogu wo kakunin shite kudasai)",
      workplaceContextVi: "Xin vui lòng kiểm tra tệp log hệ thống",
      strokeOrderHints: [
        "Nét 1: Một nét liên tục giống chữ る nhưng không có vòng thắt nút ở đuôi",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_wa",
      language: "ja",
      category: "alphabet",
      targetText: "わ",
      phoneticOrKana: "wa",
      meaningVi: "Chữ cái Hiragana: Wa",
      workplaceContext: "わかりました (Wakarimashita)",
      workplaceContextVi: "Tôi đã hiểu rõ vấn đề",
      strokeOrderHints: [
        "Nét 1: Nét sổ dọc bên trái",
        "Nét 2: Nét zic-zac kéo sang và cuộn vòng tròn bụng to sang phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_wo",
      language: "ja",
      category: "alphabet",
      targetText: "を",
      phoneticOrKana: "wo",
      meaningVi: "Chữ cái Hiragana: Wo",
      workplaceContext: "本番環境を監視します (Honban kankyou wo kanshi shimasu)",
      workplaceContextVi: "Giám sát chặt chẽ môi trường production",
      strokeOrderHints: [
        "Nét 1: Nét ngang ngắn",
        "Nét 2: Nét chéo gập góc",
        "Nét 3: Nét cong chữ C cắt ngang",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_hira_n",
      language: "ja",
      category: "alphabet",
      targetText: "ん",
      phoneticOrKana: "n",
      meaningVi: "Chữ cái Hiragana: N",
      workplaceContext: "進捗はどうですか (Shinchoku wa dou desu ka)",
      workplaceContextVi: "Tiến độ công việc hiện tại như thế nào rồi?",
      strokeOrderHints: [
        "Nét 1: Nét chéo xuống rồi uốn cong hình sóng hất nhẹ lên đuôi",
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
      workplaceContext:
          "この機能に重大なバグが発生しました (Kono kinou ni juudai na bagu ga hassei shimashita)",
      workplaceContextVi:
          "Chức năng này đã phát sinh một con bug nghiêm trọng.",
      strokeOrderHints: [
        "Chữ バ (Ba): Viết nét ハ (Ha) rồi thêm 2 dấu phẩy đục âm ゛",
        "Chữ グ (Gu): Viết nét ク (Ku) rồi thêm 2 dấu phẩy ゛",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_kata_server",
      language: "ja",
      category: "it_workplace",
      targetText: "サーバー",
      phoneticOrKana: "saabaa",
      meaningVi: "Máy chủ hệ thống (Server)",
      workplaceContext:
          "クラウドサーバーの負荷が増加しています (Kuraudo saabaa no fuka ga zouka shite imasu)",
      workplaceContextVi: "Tải của máy chủ đám mây đang tăng cao.",
      strokeOrderHints: [
        "Chữ サ (Sa): Nét ngang và hai nét sổ ngắn",
        "Chữ ー: Nét trường âm ngang kéo dài",
        "Chữ バ (Ba): Nét ハ có âm đục ゛",
        "Chữ ー: Nét trường âm ngang",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_kata_deploy",
      language: "ja",
      category: "it_workplace",
      targetText: "デプロイ",
      phoneticOrKana: "depuroi",
      meaningVi: "Triển khai phần mềm (Deploy)",
      workplaceContext:
          "ステージング環境へのデプロイが完了しました (Suteejingu kankyou e no depuroi ga kanryou shimashita)",
      workplaceContextVi: "Đã hoàn tất việc triển khai lên môi trường staging.",
      strokeOrderHints: [
        "Chữ デ (De): Chữ テ (Te) thêm 2 dấu âm đục ゛",
        "Chữ プ (Pu): Chữ フ (Fu) thêm dấu tròn bán đục âm ゜",
        "Chữ ロ (Ro): Viết hình hộp chữ nhật khép kín",
        "Chữ イ (I): Nét phẩy bên trái và nét sổ đứng bên phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_kata_release",
      language: "ja",
      category: "it_workplace",
      targetText: "リリース",
      phoneticOrKana: "ririisu",
      meaningVi: "Phát hành phiên bản (Release)",
      workplaceContext:
          "新バージョンのリリース日は来週の月曜日です (Shin baajon no ririisubi wa raishuu no getsuyoubi desu)",
      workplaceContextVi: "Ngày phát hành phiên bản mới là thứ Hai tuần tới.",
      strokeOrderHints: [
        "Chữ リ (Ri): Nét sổ ngắn trái, nét sổ cong dài phải",
        "Chữ ー: Nét trường âm gạch ngang",
        "Chữ ス (Su): Nét gập góc ngang-chéo và nét phẩy",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_kata_test",
      language: "ja",
      category: "it_workplace",
      targetText: "テスト",
      phoneticOrKana: "tesuto",
      meaningVi: "Kiểm thử phần mềm (Test)",
      workplaceContext:
          "単体テストと結合テストをすべてパスしました (Tantai tesuto to ketsugou tesuto wo subete pasu shimashita)",
      workplaceContextVi: "Đã vượt qua toàn bộ unit test và integration test.",
      strokeOrderHints: [
        "Chữ テ (Te): Hai nét ngang trên dưới và một nét cong chéo",
        "Chữ ス (Su): Nét gập ngang chéo rồi nét phẩy",
        "Chữ ト (To): Nét sổ dọc và nét chéo chấm sang phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_kata_review",
      language: "ja",
      category: "it_workplace",
      targetText: "レビュー",
      phoneticOrKana: "rebyuu",
      meaningVi: "Đánh giá, duyệt mã nguồn (Review)",
      workplaceContext:
          "コードレビューの指摘事項を反映しました (Koodo rebyuu no shitekijikou wo han'ei shimashita)",
      workplaceContextVi:
          "Tôi đã cập nhật sửa đổi theo các góp ý trong code review.",
      strokeOrderHints: [
        "Chữ レ (Re): Nét sổ thẳng gập hất chéo lên sang phải",
        "Chữ ビ (Bi): Chữ ヒ (Hi) thêm 2 dấu âm đục ゛",
        "Chữ ュ (Yu nhỏ): Chữ ユ viết kích thước nhỏ",
        "Chữ ー: Nét trường âm gạch ngang kéo dài",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_n5_nichi",
      language: "ja",
      category: "jlpt_n5",
      targetText: "日",
      phoneticOrKana: "ひ / にち (hi / nichi)",
      meaningVi: "Ngày, Mặt trời (Nhật)",
      workplaceContext: "リリース日は明日です (Ririisubi wa ashita desu)",
      workplaceContextVi: "Ngày phát hành sản phẩm là ngày mai.",
      strokeOrderHints: [
        "Nét 1: Nét sổ thẳng bên trái",
        "Nét 2: Nét ngang gập móc bên phải",
        "Nét 3: Nét ngang ở giữa",
        "Nét 4: Nét ngang đóng đáy",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_n5_getsu",
      language: "ja",
      category: "jlpt_n5",
      targetText: "月",
      phoneticOrKana: "つき / げつ (tsuki / getsu)",
      meaningVi: "Tháng, Mặt trăng (Nguyệt)",
      workplaceContext:
          "来月のスプリント計画を立てます (Raigetsu no supurinto keikaku wo tatemasu)",
      workplaceContextVi: "Lập kế hoạch sprint cho tháng tới.",
      strokeOrderHints: [
        "Nét 1: Nét phẩy cong dài bên trái",
        "Nét 2: Nét ngang gập có móc bên phải",
        "Nét 3, 4: Hai nét ngang song song bên trong",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_n5_moku",
      language: "ja",
      category: "jlpt_n5",
      targetText: "木",
      phoneticOrKana: "き / もく (ki / moku)",
      meaningVi: "Cây, Gỗ, Thứ năm (Mộc)",
      workplaceContext: "木曜日の定例ミーティング (Mokuyoubi no teirei miitingu)",
      workplaceContextVi: "Cuộc họp định kỳ vào thứ Năm.",
      strokeOrderHints: [
        "Nét 1: Nét ngang",
        "Nét 2: Nét sổ thẳng đứng cắt ngang nét 1",
        "Nét 3: Nét phẩy chéo trái",
        "Nét 4: Nét mác chéo phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_n5_sui",
      language: "ja",
      category: "jlpt_n5",
      targetText: "水",
      phoneticOrKana: "みず / すい (mizu / sui)",
      meaningVi: "Nước, Thứ tư (Thủy)",
      workplaceContext:
          "水曜日にデプロイを実施します (Suiyoubi ni depuroi wo jisshi shimasu)",
      workplaceContextVi: "Thực hiện triển khai hệ thống vào thứ Tư.",
      strokeOrderHints: [
        "Nét 1: Nét sổ móc ở giữa",
        "Nét 2: Nét ngang gập bên trái",
        "Nét 3: Nét phẩy chéo ngắn",
        "Nét 4: Nét mác sang phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_n5_kin",
      language: "ja",
      category: "jlpt_n5",
      targetText: "金",
      phoneticOrKana: "かね / きん (kane / kin)",
      meaningVi: "Vàng, Tiền, Thứ sáu (Kim)",
      workplaceContext:
          "金曜日の夕方にコードフリーズします (Kinyoubi no yuugata ni koodo furiizu shimasu)",
      workplaceContextVi: "Đóng băng mã nguồn (code freeze) vào chiều thứ Sáu.",
      strokeOrderHints: [
        "Nét 1: Nét phẩy trái trên cùng",
        "Nét 2: Nét mác phải",
        "Nét 3, 4: Hai nét ngang",
        "Nét 5: Nét sổ giữa",
        "Nét 6, 7: Hai nét chấm hai bên",
        "Nét 8: Nét ngang đáy",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_n5_do",
      language: "ja",
      category: "jlpt_n5",
      targetText: "土",
      phoneticOrKana: "つち / ど (tsuchi / do)",
      meaningVi: "Đất, Thứ bảy (Thổ)",
      workplaceContext: "土曜日の定期メンテナンス (Doyoubi no teiki mentenansu)",
      workplaceContextVi: "Bảo trì định kỳ hệ thống vào thứ Bảy.",
      strokeOrderHints: [
        "Nét 1: Nét ngang ngắn ở trên",
        "Nét 2: Nét sổ thẳng đứng cắt nét 1",
        "Nét 3: Nét ngang dài ở đáy",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_n5_yama",
      language: "ja",
      category: "jlpt_n5",
      targetText: "山",
      phoneticOrKana: "やま / さん (yama / san)",
      meaningVi: "Núi (Sơn)",
      workplaceContext: "課題が山積みになっています (Kadai ga yamazumi ni natte imasu)",
      workplaceContextVi: "Các vấn đề tồn đọng đang chất chồng như núi.",
      strokeOrderHints: [
        "Nét 1: Nét sổ thẳng đứng ở giữa",
        "Nét 2: Nét sổ trái gập ngang sang phải",
        "Nét 3: Nét sổ thẳng bên phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_n5_kawa",
      language: "ja",
      category: "jlpt_n5",
      targetText: "川",
      phoneticOrKana: "かわ / せん (kawa / sen)",
      meaningVi: "Sông, Dòng chảy (Xuyên)",
      workplaceContext: "データの流れを図解します (Deeta no nagare wo zukai shimasu)",
      workplaceContextVi: "Vẽ sơ đồ dòng chảy luân chuyển của dữ liệu.",
      strokeOrderHints: [
        "Nét 1: Nét sổ hơi cong nhẹ bên trái",
        "Nét 2: Nét sổ ngắn ở giữa",
        "Nét 3: Nét sổ thẳng dài bên phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_n5_hito",
      language: "ja",
      category: "jlpt_n5",
      targetText: "人",
      phoneticOrKana: "ひと / じん (hito / jin)",
      meaningVi: "Người, Nhân lực (Nhân)",
      workplaceContext:
          "開発リソースの人員を補強します (Kaihatsu risoosu no jin'in wo hokyou shimasu)",
      workplaceContextVi:
          "Tăng cường thêm nhân sự cho tài nguyên phát triển dự án.",
      strokeOrderHints: [
        "Nét 1: Nét phẩy vuốt cong từ trên xuống trái",
        "Nét 2: Nét mác tiếp giáp vuốt sang phải",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_n5_hon",
      language: "ja",
      category: "jlpt_n5",
      targetText: "本",
      phoneticOrKana: "ほん (hon)",
      meaningVi: "Sách, Bản gốc, Gốc rễ (Bản)",
      workplaceContext:
          "本番環境のデータベースをバックアップします (Honban kankyou no deetabeesu wo bakkuappu shimasu)",
      workplaceContextVi:
          "Sao lưu cơ sở dữ liệu trên môi trường thật (production).",
      strokeOrderHints: [
        "Nét 1: Nét ngang trên",
        "Nét 2: Nét sổ giữa cắt nét 1",
        "Nét 3: Nét phẩy trái",
        "Nét 4: Nét mác phải",
        "Nét 5: Nét gạch ngang ngắn ở thân dưới",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_it_kaihatsu",
      language: "ja",
      category: "it_workplace",
      targetText: "開発",
      phoneticOrKana: "かいはつ (kaihatsu)",
      meaningVi: "Phát triển (Development)",
      workplaceContext:
          "新しいシステムの開発チームに参加します (Atarashii shisutemu no kaihatsu chiimu ni sanka shimasu)",
      workplaceContextVi:
          "Tôi sẽ tham gia vào đội ngũ phát triển hệ thống mới.",
      strokeOrderHints: [
        "Chữ 開 (Khai): Bộ môn 門 bao ngoài, bên trong viết chữ khai",
        "Chữ 発 (Phát): Viết bộ bát bên trên, sau đó các nét cung và phẩy bên dưới",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_it_shiyousho",
      language: "ja",
      category: "it_workplace",
      targetText: "仕様書",
      phoneticOrKana: "しようしょ (shiyousho)",
      meaningVi: "Tài liệu đặc tả yêu cầu (Specification document)",
      workplaceContext:
          "仕様書を確認してから実装してください (Shiyousho wo kakunin shite kara jissou shite kudasai)",
      workplaceContextVi:
          "Hãy đọc xác nhận tài liệu đặc tả trước khi bắt tay vào code.",
      strokeOrderHints: [
        "Chữ 仕 (Sĩ): Bộ nhân đứng bên trái, chữ sĩ bên phải",
        "Chữ 様 (Dạng): Bộ mộc bên trái, chữ dương bên phải",
        "Chữ 書 (Thư): Các nét ngang song song, nét sổ giữa, bộ nhật bên dưới",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_it_kakunin",
      language: "ja",
      category: "it_workplace",
      targetText: "確認",
      phoneticOrKana: "かくにん (kakunin)",
      meaningVi: "Kiểm tra, xác nhận (Check / Confirm)",
      workplaceContext:
          "プルリクエストのご確認をお願いします (Puru rikuesuto no gokakunin wo onegai shimasu)",
      workplaceContextVi:
          "Nhờ anh/chị kiểm tra giúp em cái Pull Request này nhé ạ.",
      strokeOrderHints: [
        "Chữ 確 (Xác): Bộ thạch bên trái, chữ hạc bên phải",
        "Chữ 認 (Nhận): Bộ ngôn bên trái, chữ nhẫn bên phải",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_it_sent_shiyousho",
      language: "ja",
      category: "it_workplace",
      targetText: "仕様書を確認してください",
      phoneticOrKana: "しようしょをかくにんしてください (Shiyousho wo kakunin shite kudasai)",
      meaningVi: "Xin vui lòng kiểm tra tài liệu đặc tả yêu cầu",
      workplaceContext:
          "仕様書を確認してください。不明点があれば質問してください (Shiyousho wo kakunin shite kudasai. Fumeiten ga areba shitsumon shite kudasai)",
      workplaceContextVi:
          "Xin vui lòng đọc kỹ tài liệu đặc tả, nếu có điểm nào chưa rõ hãy hỏi ngay.",
      strokeOrderHints: [
        "Gồm từ vựng 仕様書 (Shiyousho - Đặc tả)",
        "Trợ từ を (wo)",
        "Từ vựng 確認 (Kakunin - Xác nhận)",
        "Đuôi câu lịch sự してください (kudasai - xin hãy làm)",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_it_sent_pr",
      language: "ja",
      category: "it_workplace",
      targetText: "プルリクエストを作成しました",
      phoneticOrKana: "プルリクエストをさくせいしました (Puru rikuesuto wo sakusei shimashita)",
      meaningVi: "Tôi đã tạo Pull Request rồi",
      workplaceContext:
          "修正が完了したので、プルリクエストを作成しました (Shuusei ga kanryou shita node, puru rikuesuto wo sakusei shimashita)",
      workplaceContextVi:
          "Vì đã hoàn tất sửa lỗi nên tôi đã tạo Pull Request rồi.",
      strokeOrderHints: [
        "Cụm Katakana プルリクエスト (Pull Request)",
        "Trợ từ を (wo)",
        "Động từ 作成 (Sakusei - Tạo/Soạn thảo)",
        "Dạng quá khứ lịch sự しました (shimashita - đã làm)",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_it_sent_deploy",
      language: "ja",
      category: "it_workplace",
      targetText: "本番環境にデプロイします",
      phoneticOrKana: "ほんばんかんきょうにデプロイします (Honban kankyou ni depuroi shimasu)",
      meaningVi: "Tôi sẽ triển khai lên môi trường Production",
      workplaceContext:
          "承認が得られたので、本番環境にデプロイします (Shounin ga erareta node, honban kankyou ni depuroi shimasu)",
      workplaceContextVi:
          "Sau khi được phê duyệt, tôi sẽ triển khai lên môi trường production.",
      strokeOrderHints: [
        "Cụm từ 本番環境 (Honban kankyou - Môi trường production)",
        "Trợ từ đích đến に (ni)",
        "Katakana デプロイ (Deploy)",
        "Động từ lịch sự します (shimasu - sẽ làm)",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_it_deploy",
      language: "en",
      category: "it_workplace",
      targetText: "deploy",
      phoneticOrKana: "/dɪˈplɔɪ/",
      meaningVi: "Triển khai hệ thống/phần mềm lên server",
      workplaceContext:
          "We are ready to deploy the release to production tonight.",
      workplaceContextVi:
          "Chúng tôi đã sẵn sàng triển khai phiên bản mới lên môi trường production tối nay.",
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
      meaningVi: "Hạn chót, thời hạn hoàn thành công việc",
      workplaceContext:
          "Can we extend the deadline for this sprint task by two days?",
      workplaceContextVi:
          "Chúng ta có thể gia hạn thời hạn nhiệm vụ sprint này thêm hai ngày được không?",
      strokeOrderHints: [
        "Viết thường 'd-e-a-d-l-i-n-e'",
        "Nối các ký tự liền mạch để ghi nhớ từ vựng theo cụm chữ cái",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "en_it_resolve",
      language: "en",
      category: "it_workplace",
      targetText: "resolve",
      phoneticOrKana: "/rɪˈzɑːlv/",
      meaningVi: "Giải quyết triệt để (vấn đề, bug, ticket)",
      workplaceContext:
          "I will investigate and resolve the API timeout issue before lunch.",
      workplaceContextVi:
          "Tôi sẽ điều tra và xử lý dứt điểm sự cố timeout của API trước giờ ăn trưa.",
      strokeOrderHints: ["Viết thường 'r-e-s-o-l-v-e'"],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "en_it_requirement",
      language: "en",
      category: "it_workplace",
      targetText: "requirement",
      phoneticOrKana: "/rɪˈkwaɪər.mənt/",
      meaningVi: "Yêu cầu kỹ thuật, yêu cầu nghiệp vụ của dự án",
      workplaceContext:
          "The client changed the authentication requirement in the latest meeting.",
      workplaceContextVi:
          "Khách hàng đã thay đổi yêu cầu phần xác thực trong cuộc họp gần nhất.",
      strokeOrderHints: [
        "Viết 'r-e-q-u-i-r-e-m-e-n-t'",
        "Phân tách: require + ment",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_it_incident",
      language: "en",
      category: "it_workplace",
      targetText: "incident",
      phoneticOrKana: "/ˈɪn.sɪ.dənt/",
      meaningVi: "Sự cố kỹ thuật đột xuất, gián đoạn dịch vụ",
      workplaceContext:
          "The on-call team responded to the database incident within 5 minutes.",
      workplaceContextVi:
          "Đội ngũ trực on-call đã phản hồi sự cố cơ sở dữ liệu trong vòng 5 phút.",
      strokeOrderHints: ["Viết thường 'i-n-c-i-d-e-n-t'"],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_it_endpoint",
      language: "en",
      category: "it_workplace",
      targetText: "endpoint",
      phoneticOrKana: "/ˈend.pɔɪnt/",
      meaningVi: "Điểm cuối API kết nối giao tiếp dịch vụ",
      workplaceContext:
          "The client application makes authenticated requests to the REST endpoint.",
      workplaceContextVi:
          "Ứng dụng client gửi các yêu cầu đã xác thực tới endpoint REST.",
      strokeOrderHints: ["Viết 'e-n-d-p-o-i-n-t'", "Từ ghép: end + point"],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "en_it_database",
      language: "en",
      category: "it_workplace",
      targetText: "database",
      phoneticOrKana: "/ˈdeɪ.tə.beɪs/",
      meaningVi: "Cơ sở dữ liệu lưu trữ có cấu trúc",
      workplaceContext:
          "We run database migrations before starting the application service.",
      workplaceContextVi:
          "Chúng tôi chạy migration cơ sở dữ liệu trước khi khởi động dịch vụ ứng dụng.",
      strokeOrderHints: ["Viết 'd-a-t-a-b-a-s-e'", "Từ ghép: data + base"],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "en_it_latency",
      language: "en",
      category: "it_workplace",
      targetText: "latency",
      phoneticOrKana: "/ˈleɪ.tən.si/",
      meaningVi: "Độ trễ truyền tải dữ liệu mạng",
      workplaceContext:
          "Caching frequently requested items significantly reduces network latency.",
      workplaceContextVi:
          "Lưu bộ nhớ đệm các mục hay truy vấn giúp giảm đáng kể độ trễ mạng.",
      strokeOrderHints: ["Viết 'l-a-t-e-n-c-y'", "Gốc từ: late -> latency"],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_it_pipeline",
      language: "en",
      category: "it_workplace",
      targetText: "pipeline",
      phoneticOrKana: "/ˈpaɪp.laɪn/",
      meaningVi: "Đường ống tự động hóa CI/CD hoặc luồng xử lý dữ liệu",
      workplaceContext:
          "The CI/CD pipeline runs unit tests, lints the code, and builds artifacts automatically.",
      workplaceContextVi:
          "Đường ống CI/CD tự động chạy kiểm thử đơn vị, kiểm tra chuẩn mã và build sản phẩm đóng gói.",
      strokeOrderHints: ["Viết 'p-i-p-e-l-i-n-e'", "Từ ghép: pipe + line"],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_it_container",
      language: "en",
      category: "it_workplace",
      targetText: "container",
      phoneticOrKana: "/kənˈteɪ.nər/",
      meaningVi: "Thùng chứa ảo hóa ứng dụng (như Docker container)",
      workplaceContext:
          "Each microservice is packaged into an isolated lightweight container.",
      workplaceContextVi:
          "Mỗi microservice được đóng gói vào một container nhẹ độc lập.",
      strokeOrderHints: ["Viết 'c-o-n-t-a-i-n-e-r'", "Gốc từ: contain + er"],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_it_refactor",
      language: "en",
      category: "it_workplace",
      targetText: "refactor",
      phoneticOrKana: "/ˌriːˈfæk.tər/",
      meaningVi: "Tái cấu trúc mã nguồn mà không thay đổi hành vi bên ngoài",
      workplaceContext:
          "We need to refactor the legacy payment module to improve maintainability.",
      workplaceContextVi:
          "Chúng ta cần tái cấu trúc module thanh toán cũ để cải thiện khả năng bảo trì.",
      strokeOrderHints: [
        "Viết 'r-e-f-a-c-t-o-r'",
        "Tiền tố 're-' nghĩa là làm lại",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_it_repository",
      language: "en",
      category: "it_workplace",
      targetText: "repository",
      phoneticOrKana: "/rɪˈpɑː.zə.tɔːr.i/",
      meaningVi: "Kho lưu trữ mã nguồn phiên bản (Git repo)",
      workplaceContext:
          "Clone the Git repository to your local development machine.",
      workplaceContextVi:
          "Hãy clone kho lưu trữ Git về máy tính phát triển cá nhân của bạn.",
      strokeOrderHints: [
        "Viết 'r-e-p-o-s-i-t-o-r-y'",
        "Thường được gọi tắt là 'repo'",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_it_middleware",
      language: "en",
      category: "it_workplace",
      targetText: "middleware",
      phoneticOrKana: "/ˈmɪd.əl.weər/",
      meaningVi: "Phần mềm trung gian xử lý request và response",
      workplaceContext:
          "The logging middleware records response times for every incoming HTTP request.",
      workplaceContextVi:
          "Middleware ghi log lưu lại thời gian phản hồi cho từng HTTP request đến.",
      strokeOrderHints: [
        "Viết 'm-i-d-d-l-e-w-a-r-e'",
        "Từ ghép: middle + ware",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_it_authentication",
      language: "en",
      category: "it_workplace",
      targetText: "authentication",
      phoneticOrKana: "/ɔːˌθen.tɪˈkeɪ.ʃən/",
      meaningVi: "Xác thực danh tính người dùng hoặc máy khách",
      workplaceContext:
          "Multi-factor authentication is required to access sensitive production environments.",
      workplaceContextVi:
          "Xác thực đa yếu tố được yêu cầu bắt buộc để truy cập môi trường production nhạy cảm.",
      strokeOrderHints: [
        "Viết 'a-u-t-h-e-n-t-i-c-a-t-i-o-n'",
        "Phân tách: authenticate + ion, viết tắt là 'Auth'",
      ],
      difficultyLevel: 3,
    ),
    LessonItem(
      id: "en_it_asynchronous",
      language: "en",
      category: "it_workplace",
      targetText: "asynchronous",
      phoneticOrKana: "/eɪˈsɪŋ.krə.nəs/",
      meaningVi: "Bất đồng bộ (xử lý không chặn luồng chính)",
      workplaceContext:
          "Use asynchronous message queues to handle heavy background processing tasks.",
      workplaceContextVi:
          "Sử dụng hàng đợi thông điệp bất đồng bộ để xử lý các tác vụ nền nặng.",
      strokeOrderHints: [
        "Viết 'a-s-y-n-c-h-r-o-n-o-u-s'",
        "Thường gọi tắt là 'async'",
      ],
      difficultyLevel: 3,
    ),
    LessonItem(
      id: "ja_extra_kata_0",
      language: "ja",
      category: "alphabet",
      targetText: "ア",
      phoneticOrKana: "a",
      meaningVi: "Katakana A",
      workplaceContext: "「ア」を練習します。",
      workplaceContextVi: "Tôi luyện viết chữ ア.",
      strokeOrderHints: [
        "Quan sát mẫu ア, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_extra_kata_1",
      language: "ja",
      category: "alphabet",
      targetText: "イ",
      phoneticOrKana: "i",
      meaningVi: "Katakana I",
      workplaceContext: "「イ」を練習します。",
      workplaceContextVi: "Tôi luyện viết chữ イ.",
      strokeOrderHints: [
        "Quan sát mẫu イ, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_extra_kata_2",
      language: "ja",
      category: "alphabet",
      targetText: "ウ",
      phoneticOrKana: "u",
      meaningVi: "Katakana U",
      workplaceContext: "「ウ」を練習します。",
      workplaceContextVi: "Tôi luyện viết chữ ウ.",
      strokeOrderHints: [
        "Quan sát mẫu ウ, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_extra_kata_3",
      language: "ja",
      category: "alphabet",
      targetText: "エ",
      phoneticOrKana: "e",
      meaningVi: "Katakana E",
      workplaceContext: "「エ」を練習します。",
      workplaceContextVi: "Tôi luyện viết chữ エ.",
      strokeOrderHints: [
        "Quan sát mẫu エ, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_extra_kata_4",
      language: "ja",
      category: "alphabet",
      targetText: "オ",
      phoneticOrKana: "o",
      meaningVi: "Katakana O",
      workplaceContext: "「オ」を練習します。",
      workplaceContextVi: "Tôi luyện viết chữ オ.",
      strokeOrderHints: [
        "Quan sát mẫu オ, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_extra_kata_5",
      language: "ja",
      category: "alphabet",
      targetText: "カ",
      phoneticOrKana: "ka",
      meaningVi: "Katakana KA",
      workplaceContext: "「カ」を練習します。",
      workplaceContextVi: "Tôi luyện viết chữ カ.",
      strokeOrderHints: [
        "Quan sát mẫu カ, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_extra_kata_6",
      language: "ja",
      category: "alphabet",
      targetText: "キ",
      phoneticOrKana: "ki",
      meaningVi: "Katakana KI",
      workplaceContext: "「キ」を練習します。",
      workplaceContextVi: "Tôi luyện viết chữ キ.",
      strokeOrderHints: [
        "Quan sát mẫu キ, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_extra_kata_7",
      language: "ja",
      category: "alphabet",
      targetText: "ク",
      phoneticOrKana: "ku",
      meaningVi: "Katakana KU",
      workplaceContext: "「ク」を練習します。",
      workplaceContextVi: "Tôi luyện viết chữ ク.",
      strokeOrderHints: [
        "Quan sát mẫu ク, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_extra_kata_8",
      language: "ja",
      category: "alphabet",
      targetText: "ケ",
      phoneticOrKana: "ke",
      meaningVi: "Katakana KE",
      workplaceContext: "「ケ」を練習します。",
      workplaceContextVi: "Tôi luyện viết chữ ケ.",
      strokeOrderHints: [
        "Quan sát mẫu ケ, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_extra_kata_9",
      language: "ja",
      category: "alphabet",
      targetText: "コ",
      phoneticOrKana: "ko",
      meaningVi: "Katakana KO",
      workplaceContext: "「コ」を練習します。",
      workplaceContextVi: "Tôi luyện viết chữ コ.",
      strokeOrderHints: [
        "Quan sát mẫu コ, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 1,
    ),
    LessonItem(
      id: "ja_extra_loan_0",
      language: "ja",
      category: "it_workplace",
      targetText: "コード",
      phoneticOrKana: "kōdo",
      meaningVi: "Mã nguồn",
      workplaceContext: "コードを確認してください。",
      workplaceContextVi: "Vui lòng kiểm tra mã nguồn.",
      strokeOrderHints: [
        "Quan sát mẫu コード, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_loan_1",
      language: "ja",
      category: "it_workplace",
      targetText: "タスク",
      phoneticOrKana: "tasuku",
      meaningVi: "Tác vụ",
      workplaceContext: "タスクを分けましょう。",
      workplaceContextVi: "Hãy chia nhỏ tác vụ.",
      strokeOrderHints: [
        "Quan sát mẫu タスク, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_loan_2",
      language: "ja",
      category: "it_workplace",
      targetText: "エラー",
      phoneticOrKana: "erā",
      meaningVi: "Lỗi",
      workplaceContext: "エラーを直しました。",
      workplaceContextVi: "Tôi đã sửa lỗi.",
      strokeOrderHints: [
        "Quan sát mẫu エラー, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_loan_3",
      language: "ja",
      category: "it_workplace",
      targetText: "データ",
      phoneticOrKana: "dēta",
      meaningVi: "Dữ liệu",
      workplaceContext: "データを保存します。",
      workplaceContextVi: "Tôi sẽ lưu dữ liệu.",
      strokeOrderHints: [
        "Quan sát mẫu データ, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_loan_4",
      language: "ja",
      category: "it_workplace",
      targetText: "メール",
      phoneticOrKana: "mēru",
      meaningVi: "Thư điện tử",
      workplaceContext: "メールを送りました。",
      workplaceContextVi: "Tôi đã gửi email.",
      strokeOrderHints: [
        "Quan sát mẫu メール, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_loan_5",
      language: "ja",
      category: "it_workplace",
      targetText: "スケジュール",
      phoneticOrKana: "sukejūru",
      meaningVi: "Lịch trình",
      workplaceContext: "スケジュールを変更します。",
      workplaceContextVi: "Tôi sẽ thay đổi lịch trình.",
      strokeOrderHints: [
        "Quan sát mẫu スケジュール, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_loan_6",
      language: "ja",
      category: "it_workplace",
      targetText: "ミーティング",
      phoneticOrKana: "mītingu",
      meaningVi: "Cuộc họp",
      workplaceContext: "ミーティングは十時です。",
      workplaceContextVi: "Cuộc họp lúc mười giờ.",
      strokeOrderHints: [
        "Quan sát mẫu ミーティング, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_loan_7",
      language: "ja",
      category: "it_workplace",
      targetText: "クライアント",
      phoneticOrKana: "kuraianto",
      meaningVi: "Khách hàng",
      workplaceContext: "クライアントに連絡します。",
      workplaceContextVi: "Tôi sẽ liên hệ khách hàng.",
      strokeOrderHints: [
        "Quan sát mẫu クライアント, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_0",
      language: "ja",
      category: "jlpt_n4",
      targetText: "社",
      phoneticOrKana: "しゃ",
      meaningVi: "Công ty",
      workplaceContext: "会社で働いています。",
      workplaceContextVi: "Tôi làm việc tại công ty.",
      strokeOrderHints: [
        "Quan sát mẫu 社, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_1",
      language: "ja",
      category: "jlpt_n5",
      targetText: "会",
      phoneticOrKana: "かい",
      meaningVi: "Gặp gỡ, hội họp",
      workplaceContext: "会議は午後です。",
      workplaceContextVi: "Cuộc họp vào buổi chiều.",
      strokeOrderHints: [
        "Quan sát mẫu 会, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_2",
      language: "ja",
      category: "jlpt_n4",
      targetText: "事",
      phoneticOrKana: "じ",
      meaningVi: "Sự việc, công việc",
      workplaceContext: "仕事を始めます。",
      workplaceContextVi: "Tôi bắt đầu làm việc.",
      strokeOrderHints: [
        "Quan sát mẫu 事, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_3",
      language: "ja",
      category: "jlpt_n4",
      targetText: "仕",
      phoneticOrKana: "し",
      meaningVi: "Làm, phục vụ",
      workplaceContext: "仕事が終わりました。",
      workplaceContextVi: "Công việc đã xong.",
      strokeOrderHints: [
        "Quan sát mẫu 仕, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_4",
      language: "ja",
      category: "jlpt_n4",
      targetText: "業",
      phoneticOrKana: "ぎょう",
      meaningVi: "Nghề nghiệp, nghiệp vụ",
      workplaceContext: "作業を確認します。",
      workplaceContextVi: "Tôi sẽ kiểm tra tác vụ.",
      strokeOrderHints: [
        "Quan sát mẫu 業, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_5",
      language: "ja",
      category: "jlpt_n4",
      targetText: "働",
      phoneticOrKana: "はたらく",
      meaningVi: "Làm việc",
      workplaceContext: "ここで働きます。",
      workplaceContextVi: "Tôi làm việc ở đây.",
      strokeOrderHints: [
        "Quan sát mẫu 働, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_6",
      language: "ja",
      category: "jlpt_n4",
      targetText: "場",
      phoneticOrKana: "ば",
      meaningVi: "Địa điểm",
      workplaceContext: "職場は駅の近くです。",
      workplaceContextVi: "Nơi làm việc gần nhà ga.",
      strokeOrderHints: [
        "Quan sát mẫu 場, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_7",
      language: "ja",
      category: "jlpt_n4",
      targetText: "員",
      phoneticOrKana: "いん",
      meaningVi: "Nhân viên",
      workplaceContext: "新しい社員です。",
      workplaceContextVi: "Tôi là nhân viên mới.",
      strokeOrderHints: [
        "Quan sát mẫu 員, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_8",
      language: "ja",
      category: "jlpt_n4",
      targetText: "所",
      phoneticOrKana: "ところ",
      meaningVi: "Nơi chốn",
      workplaceContext: "事務所にいます。",
      workplaceContextVi: "Tôi đang ở văn phòng.",
      strokeOrderHints: [
        "Quan sát mẫu 所, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_9",
      language: "ja",
      category: "jlpt_n4",
      targetText: "使",
      phoneticOrKana: "つかう",
      meaningVi: "Sử dụng",
      workplaceContext: "この道具を使います。",
      workplaceContextVi: "Tôi sử dụng công cụ này.",
      strokeOrderHints: [
        "Quan sát mẫu 使, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_10",
      language: "ja",
      category: "jlpt_n4",
      targetText: "作",
      phoneticOrKana: "つくる",
      meaningVi: "Tạo, làm",
      workplaceContext: "資料を作ります。",
      workplaceContextVi: "Tôi tạo tài liệu.",
      strokeOrderHints: [
        "Quan sát mẫu 作, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_11",
      language: "ja",
      category: "jlpt_n4",
      targetText: "急",
      phoneticOrKana: "いそぐ",
      meaningVi: "Vội, gấp",
      workplaceContext: "急いで確認します。",
      workplaceContextVi: "Tôi sẽ kiểm tra ngay.",
      strokeOrderHints: [
        "Quan sát mẫu 急, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_12",
      language: "ja",
      category: "jlpt_n4",
      targetText: "待",
      phoneticOrKana: "まつ",
      meaningVi: "Chờ đợi",
      workplaceContext: "返事を待っています。",
      workplaceContextVi: "Tôi đang chờ phản hồi.",
      strokeOrderHints: [
        "Quan sát mẫu 待, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_13",
      language: "ja",
      category: "jlpt_n4",
      targetText: "持",
      phoneticOrKana: "もつ",
      meaningVi: "Cầm, mang",
      workplaceContext: "資料を持ってきます。",
      workplaceContextVi: "Tôi sẽ mang tài liệu tới.",
      strokeOrderHints: [
        "Quan sát mẫu 持, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_kanji_14",
      language: "ja",
      category: "jlpt_n4",
      targetText: "知",
      phoneticOrKana: "しる",
      meaningVi: "Biết",
      workplaceContext: "予定を知っています。",
      workplaceContextVi: "Tôi biết lịch trình.",
      strokeOrderHints: [
        "Quan sát mẫu 知, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "ja_extra_hourensou_0",
      language: "ja",
      category: "it_workplace",
      targetText: "進捗",
      phoneticOrKana: "しんちょく",
      meaningVi: "Tiến độ",
      workplaceContext: "進捗を報告してください。",
      workplaceContextVi: "Vui lòng báo cáo tiến độ.",
      strokeOrderHints: [
        "Quan sát mẫu 進捗, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 3,
    ),
    LessonItem(
      id: "ja_extra_hourensou_1",
      language: "ja",
      category: "it_workplace",
      targetText: "報告",
      phoneticOrKana: "ほうこく",
      meaningVi: "Báo cáo",
      workplaceContext: "結果を報告します。",
      workplaceContextVi: "Tôi sẽ báo cáo kết quả.",
      strokeOrderHints: [
        "Quan sát mẫu 報告, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 3,
    ),
    LessonItem(
      id: "ja_extra_hourensou_2",
      language: "ja",
      category: "it_workplace",
      targetText: "連絡",
      phoneticOrKana: "れんらく",
      meaningVi: "Liên lạc",
      workplaceContext: "問題があれば連絡してください。",
      workplaceContextVi: "Nếu có vấn đề hãy liên lạc.",
      strokeOrderHints: [
        "Quan sát mẫu 連絡, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 3,
    ),
    LessonItem(
      id: "ja_extra_hourensou_3",
      language: "ja",
      category: "it_workplace",
      targetText: "相談",
      phoneticOrKana: "そうだん",
      meaningVi: "Trao đổi, tham vấn",
      workplaceContext: "上司に相談します。",
      workplaceContextVi: "Tôi sẽ trao đổi với cấp trên.",
      strokeOrderHints: [
        "Quan sát mẫu 相談, viết từng ký tự từ trái sang phải.",
        "Giữ kích thước đều trong ô vuông; đi nét từ trên xuống dưới.",
      ],
      difficultyLevel: 3,
    ),
    LessonItem(
      id: "en_extra_work_0",
      language: "en",
      category: "it_workplace",
      targetText: "standup",
      phoneticOrKana: "/ˈstænd.ʌp/",
      meaningVi: "Họp nhanh đầu ngày",
      workplaceContext: "Share your progress at standup.",
      workplaceContextVi: "Hãy chia sẻ tiến độ trong họp đầu ngày.",
      strokeOrderHints: [
        "Viết standup từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_extra_work_1",
      language: "en",
      category: "it_workplace",
      targetText: "blocker",
      phoneticOrKana: "/ˈblɒk.ər/",
      meaningVi: "Vấn đề cản trở",
      workplaceContext: "This bug is a blocker for release.",
      workplaceContextVi: "Lỗi này cản trở việc phát hành.",
      strokeOrderHints: [
        "Viết blocker từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_extra_work_2",
      language: "en",
      category: "it_workplace",
      targetText: "milestone",
      phoneticOrKana: "/ˈmaɪl.stəʊn/",
      meaningVi: "Cột mốc",
      workplaceContext: "We reached the first milestone.",
      workplaceContextVi: "Chúng ta đã đạt cột mốc đầu tiên.",
      strokeOrderHints: [
        "Viết milestone từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_extra_work_3",
      language: "en",
      category: "it_workplace",
      targetText: "rollback",
      phoneticOrKana: "/ˈrəʊl.bæk/",
      meaningVi: "Hoàn tác bản triển khai",
      workplaceContext: "Prepare a rollback before deploying.",
      workplaceContextVi: "Hãy chuẩn bị hoàn tác trước khi triển khai.",
      strokeOrderHints: [
        "Viết rollback từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_extra_work_4",
      language: "en",
      category: "it_workplace",
      targetText: "scalability",
      phoneticOrKana: "/ˌskeɪ.ləˈbɪl.ə.ti/",
      meaningVi: "Khả năng mở rộng",
      workplaceContext: "Test the scalability of this service.",
      workplaceContextVi: "Hãy kiểm tra khả năng mở rộng dịch vụ này.",
      strokeOrderHints: [
        "Viết scalability từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 3,
    ),
    LessonItem(
      id: "en_extra_work_5",
      language: "en",
      category: "it_workplace",
      targetText: "throughput",
      phoneticOrKana: "/ˈθruː.pʊt/",
      meaningVi: "Thông lượng",
      workplaceContext: "The new worker improves throughput.",
      workplaceContextVi: "Worker mới cải thiện thông lượng.",
      strokeOrderHints: [
        "Viết throughput từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 3,
    ),
    LessonItem(
      id: "en_extra_work_6",
      language: "en",
      category: "it_workplace",
      targetText: "idempotent",
      phoneticOrKana: "/ˌaɪ.demˈpəʊ.tənt/",
      meaningVi: "Lặp lại vẫn cho cùng kết quả",
      workplaceContext: "Make the payment handler idempotent.",
      workplaceContextVi:
          "Hãy đảm bảo xử lý thanh toán lặp lại vẫn cùng kết quả.",
      strokeOrderHints: [
        "Viết idempotent từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 3,
    ),
    LessonItem(
      id: "en_extra_work_7",
      language: "en",
      category: "it_workplace",
      targetText: "regression",
      phoneticOrKana: "/rɪˈɡreʃ.ən/",
      meaningVi: "Lỗi tái phát",
      workplaceContext: "Add a regression test for this bug.",
      workplaceContextVi: "Hãy thêm kiểm thử chống tái phát lỗi này.",
      strokeOrderHints: [
        "Viết regression từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 3,
    ),
    LessonItem(
      id: "en_extra_work_8",
      language: "en",
      category: "it_workplace",
      targetText: "payload",
      phoneticOrKana: "/ˈpeɪ.ləʊd/",
      meaningVi: "Dữ liệu gửi kèm",
      workplaceContext: "Validate the request payload.",
      workplaceContextVi: "Hãy kiểm tra dữ liệu yêu cầu.",
      strokeOrderHints: [
        "Viết payload từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 3,
    ),
    LessonItem(
      id: "en_extra_work_9",
      language: "en",
      category: "it_workplace",
      targetText: "deprecated",
      phoneticOrKana: "/ˈdep.rə.keɪ.tɪd/",
      meaningVi: "Không còn được khuyến nghị",
      workplaceContext: "This API is deprecated.",
      workplaceContextVi: "API này không còn được khuyến nghị.",
      strokeOrderHints: [
        "Viết deprecated từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 3,
    ),
    LessonItem(
      id: "en_extra_work_10",
      language: "en",
      category: "business_toeic",
      targetText: "onboarding",
      phoneticOrKana: "/ˈɒn.bɔː.dɪŋ/",
      meaningVi: "Hướng dẫn người mới",
      workplaceContext: "Update the onboarding guide.",
      workplaceContextVi: "Hãy cập nhật hướng dẫn cho người mới.",
      strokeOrderHints: [
        "Viết onboarding từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_extra_work_11",
      language: "en",
      category: "business_toeic",
      targetText: "stakeholder",
      phoneticOrKana: "/ˈsteɪkˌhəʊl.dər/",
      meaningVi: "Bên liên quan",
      workplaceContext: "Confirm the scope with the stakeholder.",
      workplaceContextVi: "Hãy xác nhận phạm vi với bên liên quan.",
      strokeOrderHints: [
        "Viết stakeholder từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_extra_work_12",
      language: "en",
      category: "business_toeic",
      targetText: "estimate",
      phoneticOrKana: "/ˈes.tɪ.meɪt/",
      meaningVi: "Ước lượng",
      workplaceContext: "Estimate the work before planning.",
      workplaceContextVi: "Hãy ước lượng công việc trước khi lập kế hoạch.",
      strokeOrderHints: [
        "Viết estimate từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_extra_work_13",
      language: "en",
      category: "business_toeic",
      targetText: "prioritize",
      phoneticOrKana: "/praɪˈɒr.ə.taɪz/",
      meaningVi: "Ưu tiên",
      workplaceContext: "Prioritize the customer issue.",
      workplaceContextVi: "Hãy ưu tiên vấn đề của khách hàng.",
      strokeOrderHints: [
        "Viết prioritize từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 2,
    ),
    LessonItem(
      id: "en_extra_work_14",
      language: "en",
      category: "business_toeic",
      targetText: "followup",
      phoneticOrKana: "/ˈfɒl.əʊ.ʌp/",
      meaningVi: "Trao đổi tiếp theo",
      workplaceContext: "Schedule a followup with the client.",
      workplaceContextVi: "Hãy lên lịch trao đổi tiếp với khách hàng.",
      strokeOrderHints: [
        "Viết followup từ trái sang phải, giữ khoảng cách đều.",
        "Căn chữ thường theo baseline, phân biệt nét cao và nét đuôi.",
      ],
      difficultyLevel: 2,
    ),
    ...phase3Lessons,
  ];

  Future<List<LessonItem>> getLessons({String? language}) async {
    try {
      final uri = Uri.parse(
        '$baseUrl/lessons${language != null ? '?language=$language' : ''}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 2));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        final fetched = data.map((json) => LessonItem.fromJson(json)).toList();
        await _localDb.saveLessons(fetched);
        final custom = await _localDb.getLessons(
          language: language,
          category: 'custom',
        );
        return {
          for (final lesson in [...fetched, ...custom]) lesson.id: lesson,
        }.values.toList();
      }
    } catch (_) {
      // Backend is offline or not reachable, use offline data
    }

    final cached = await _localDb.getLessons(language: language);
    final cachedIds = cached.map((lesson) => lesson.id).toSet();
    final missing = _fallbackLessons
        .where(
          (lesson) =>
              (language == null || lesson.language == language) &&
              !cachedIds.contains(lesson.id),
        )
        .toList();
    await _localDb.saveLessons(missing);
    return [...cached, ...missing];
  }

  /// Reuses curriculum words or durably creates a local practice lesson.
  Future<LessonItem> ensureLessonForWord({
    required String word,
    required String language,
    String? phoneticOrKana,
    String? meaningVi,
    String? workplaceContext,
    String? workplaceContextVi,
  }) => _localDb.withProfileLock(() async {
    final target = word.trim();
    if (target.isEmpty || !const ['ja', 'en'].contains(language)) {
      throw ArgumentError('Cần từ vựng và ngôn ngữ ja hoặc en.');
    }
    final normalized = target.toLowerCase();
    final lessons = await getLessons();
    for (final lesson in lessons) {
      if (lesson.language == language &&
          lesson.targetText.trim().toLowerCase() == normalized) {
        return lesson;
      }
    }
    // Encoding is stable and keeps spaces distinct from literal underscores.
    final lesson = LessonItem(
      id: 'custom_${language}_${Uri.encodeComponent(normalized)}',
      language: language,
      category: 'custom',
      targetText: target,
      phoneticOrKana: phoneticOrKana?.trim() ?? '',
      meaningVi: meaningVi?.trim().isNotEmpty == true
          ? meaningVi!.trim()
          : 'Từ vựng thực chiến từ AI Roleplay',
      workplaceContext: workplaceContext?.trim() ?? '',
      workplaceContextVi: workplaceContextVi?.trim() ?? '',
      strokeOrderHints: language == 'ja'
          ? [
              'Viết từng ký tự của "$target" từ trái sang phải.',
              'Căn chỉnh ký tự theo ô vuông, viết từ trên xuống dưới.',
            ]
          : [
              'Viết "$target" liền mạch trong khung vẽ.',
              'Căn chữ theo dòng kẻ và giữ khoảng cách đều.',
            ],
      difficultyLevel: 2,
    );
    await _localDb.saveLessons([lesson]);
    return lesson;
  });

  Future<void> submitReview({
    required String itemId,
    required FSRSRating rating,
  }) async {
    await _syncCoordinator.reviewCardOffline(itemId: itemId, rating: rating);
  }

  Future<int> getCompletedCount() async {
    return _localDb.getCompletedCount();
  }

  Future<SyncResult> sync() async {
    return await _syncCoordinator.synchronize();
  }

  Future<Map<String, dynamic>> sendRoleplayMessage({
    required String targetLanguage,
    required String topic,
    required String message,
    String profession = 'it',
    String userLevel = 'beginner',
  }) async {
    try {
      final requestBaseUrl = baseUrl;
      final uri = Uri.parse('$requestBaseUrl/ai/roleplay');
      final response = await AccountService.sendRequest(
        method: 'POST',
        uri: uri,
        headers: {
          'Content-Type': 'application/json',
          ...await AccountService(
            apiService: this,
          ).currentHeaders(serverUrl: requestBaseUrl),
        },
        body: jsonEncode({
          'target_language': targetLanguage,
          'topic': topic,
          'profession': profession.toLowerCase(),
          'user_level': userLevel.toLowerCase(),
          'user_message': message,
        }),
      ).timeout(const Duration(seconds: 12));

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

  Future<bool> checkBackendHealth() async {
    try {
      final healthUri = Uri.parse(
        _baseUrl.replaceAll('/api/v1', '/api/v1/health'),
      );
      final response = await http
          .get(healthUri)
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> generateDialogue({
    required String targetLanguage,
    required String topic,
    String profession = 'IT',
    String level = 'beginner',
    int turnCount = 4,
  }) async {
    try {
      final requestBaseUrl = baseUrl;
      final uri = Uri.parse('$requestBaseUrl/ai/dialogue');
      final response = await AccountService.sendRequest(
        method: 'POST',
        uri: uri,
        headers: {
          'Content-Type': 'application/json',
          ...await AccountService(
            apiService: this,
          ).currentHeaders(serverUrl: requestBaseUrl),
        },
        body: jsonEncode({
          'target_language': targetLanguage,
          'profession': profession.toLowerCase(),
          'difficulty_level': level.toLowerCase(),
          'topic': topic,
          'turn_count': turnCount,
        }),
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final payload = jsonDecode(response.body) as Map<String, dynamic>;
        return {
          ...payload,
          'turns':
              ((payload['lines'] ?? payload['turns']) as List<dynamic>? ?? [])
                  .map(
                    (line) => {
                      ...Map<String, dynamic>.from(line as Map),
                      'translation_vi':
                          line['translation_vi'] ?? line['translation'] ?? '',
                      'romaji_or_phonetic':
                          line['phonetic_or_romaji'] ??
                          line['romaji_or_phonetic'] ??
                          line['romaji'] ??
                          '',
                    },
                  )
                  .toList(),
          'key_vocabulary':
              payload['vocabulary'] ?? payload['key_vocabulary'] ?? [],
        };
      }
    } catch (_) {
      // Local fallback
    }

    if (targetLanguage == 'ja') {
      return {
        'topic': topic,
        'turns': [
          {
            'speaker': 'Leader',
            'text': '今日のデイリースタンドアップを始めます。進捗はどうですか？',
            'romaji_or_phonetic':
                'Kyou no deirii sutandoappu wo hajimemasu. Shinchoku wa dou desu ka?',
            'translation_vi':
                'Chúng ta bắt đầu buổi họp standup hôm nay. Tiến độ của bạn thế nào?',
          },
          {
            'speaker': 'Developer',
            'text': '昨日はAPIの認証機能を実装しました。今日は単体テストを書く予定です。',
            'romaji_or_phonetic':
                'Kinou wa API no ninshou kinou wo jissou shimashita. Kyou wa tantai tesuto wo kaku yotei desu.',
            'translation_vi':
                'Hôm qua tôi đã triển khai tính năng xác thực API. Hôm nay tôi dự định viết unit test.',
          },
          {
            'speaker': 'Leader',
            'text': '何かブロッカーや困っているバグはありますか？',
            'romaji_or_phonetic':
                'Nanika burokkaa ya komatte iru bagu wa arimasu ka?',
            'translation_vi': 'Có vướng mắc hay con bug nào làm khó bạn không?',
          },
          {
            'speaker': 'Developer',
            'text': '特に問題ありません。予定通りリリース準備を進めます。',
            'romaji_or_phonetic':
                'Tokuni mondai arimasen. Yotei doori ririisu junbi wo susumemasu.',
            'translation_vi':
                'Không có vấn đề gì đặc biệt ạ. Tôi sẽ tiến hành chuẩn bị release đúng kế hoạch.',
          },
        ],
        'key_vocabulary': [
          {'word': '進捗', 'meaning_vi': 'Tiến độ', 'phonetic': 'しんちょく'},
          {
            'word': '実装',
            'meaning_vi': 'Triển khai / Cài đặt code',
            'phonetic': 'じっそう',
          },
          {'word': '単体テスト', 'meaning_vi': 'Unit test', 'phonetic': 'たんたいてすと'},
          {'word': '予定通り', 'meaning_vi': 'Đúng kế hoạch', 'phonetic': 'よていどおり'},
        ],
      };
    } else {
      return {
        'topic': topic,
        'turns': [
          {
            'speaker': 'Tech Lead',
            'text': 'Good morning team! Let’s start our daily sprint standup.',
            'romaji_or_phonetic':
                '/ɡʊd ˈmɔːrnɪŋ tiːm! lets stɑːrt ˈaʊər ˈdeɪli sprɪnt ˈstændʌp/',
            'translation_vi':
                'Chào buổi sáng cả nhóm! Hãy bắt đầu buổi họp standup của sprint.',
          },
          {
            'speaker': 'Software Engineer',
            'text':
                'Yesterday I fixed the database connection leak and raised a pull request.',
            'romaji_or_phonetic':
                '/ˈjestərdeɪ aɪ fɪkst ðə ˈdeɪtəbeɪs kəˈnekʃn liːk/',
            'translation_vi':
                'Hôm qua tôi đã sửa lỗi rò rỉ kết nối database và tạo một pull request.',
          },
          {
            'speaker': 'Tech Lead',
            'text':
                'Great! Are there any blockers preventing us from deploying to staging?',
            'romaji_or_phonetic':
                '/ɡreɪt! ɑːr ðer ˈeni ˈblɑːkərz prɪˈventɪŋ ʌs frəm dɪˈplɔɪɪŋ/',
            'translation_vi':
                'Tuyệt vời! Có điều gì ngăn cản việc deploy lên môi trường staging không?',
          },
          {
            'speaker': 'Software Engineer',
            'text':
                'No blockers. All CI tests are green and ready for code review.',
            'romaji_or_phonetic':
                '/noʊ ˈblɑːkərz. ɔːl siː-aɪ tests ɑːr ɡriːn ænd ˈredi fər koʊd rɪˈvjuː/',
            'translation_vi':
                'Không có trở ngại nào. Tất cả test CI đều xanh và sẵn sàng cho code review.',
          },
        ],
        'key_vocabulary': [
          {
            'word': 'standup',
            'meaning_vi': 'Họp nhanh đầu ngày',
            'phonetic': '/ˈstænd.ʌp/',
          },
          {
            'word': 'pull request',
            'meaning_vi': 'Yêu cầu ghép code (PR)',
            'phonetic': '/pʊl rɪˈkwest/',
          },
          {
            'word': 'blocker',
            'meaning_vi': 'Vấn đề gây tắc nghẽn tiến độ',
            'phonetic': '/ˈblɑː.kɚ/',
          },
          {
            'word': 'deploy',
            'meaning_vi': 'Triển khai lên máy chủ',
            'phonetic': '/dɪˈplɔɪ/',
          },
        ],
      };
    }
  }

  Future<List<LessonItem>> getDueLessons() async {
    final now = DateTime.now().toUtc();
    final dueIds = await _localDb.getDueCardIds(now);
    final allLessons = await getLessons();
    return allLessons.where((l) => dueIds.contains(l.id)).toList();
  }

  Future<List<FSRSCard>> getAllCards() => _localDb.getAllCards();

  Future<Map<String, dynamic>> getFSRSStats() async {
    final allCards = await getAllCards();
    final totalCompleted = await _localDb.getCompletedCount();
    final pendingQueue = await _localDb.getPendingMutations();
    final now = DateTime.now().toUtc();
    final dueIds = await _localDb.getDueCardIds(now);

    int newCount = 0;
    int learningCount = 0;
    int reviewCount = 0;
    int relearningCount = 0;
    double totalStability = 0.0;

    for (final card in allCards) {
      totalStability += card.stability;
      switch (card.state) {
        case FSRSState.newCard:
          newCount++;
          break;
        case FSRSState.learning:
          learningCount++;
          break;
        case FSRSState.review:
          reviewCount++;
          break;
        case FSRSState.relearning:
          relearningCount++;
          break;
      }
    }

    final avgStability = allCards.isNotEmpty
        ? totalStability / allCards.length
        : 0.0;
    final learnedCards = allCards.where((card) => card.stability > 0).toList();
    final estimatedRetention = learnedCards.isEmpty
        ? 0.0
        : learnedCards.fold<double>(0.0, (total, card) {
                final elapsedDays = math.max(
                  0.0,
                  now.difference(card.lastReview).inSeconds / 86400.0,
                );
                return total +
                    math
                        .pow(1.0 + 0.19 * elapsedDays / card.stability, -0.5)
                        .toDouble();
              }) /
              learnedCards.length;

    return {
      'total_cards': allCards.length,
      'total_completed': totalCompleted,
      'due_today': dueIds.length,
      'pending_sync_mutations': pendingQueue.length,
      'avg_stability': avgStability,
      'estimated_retention': (estimatedRetention * 100).round(),
      'state_breakdown': {
        'new': newCount,
        'learning': learningCount,
        'review': reviewCount,
        'relearning': relearningCount,
      },
    };
  }

  Future<StudyStreak> getStudyStreak({DateTime? asOf}) {
    return _localDb.getStudyStreak(asOf: asOf);
  }

  Future<void> logDailyActivity(DateTime date, int itemsCount) {
    return _localDb.logDailyActivity(date, itemsCount);
  }
}
