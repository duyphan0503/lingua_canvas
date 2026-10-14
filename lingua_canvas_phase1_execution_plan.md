# Đặc Tả Kỹ Thuật & Kế Hoạch Thực Thi Cho AI Agent: Hoàn Tất Giai Đoạn 1 & Mở Rộng Trải Nghiệm Học Tập (Lingua Canvas)

Tài liệu này là bản đặc tả kỹ thuật chi tiết dành cho AI Coding Agent để trực tiếp triển khai mã nguồn trên kho lưu trữ **Lingua Canvas** (`v0.2.0` — Gen 2). Mục tiêu gồm hai phần nối tiếp:
1. **Giai đoạn 1 (Ưu tiên số 1 — Khép kín M4 & Vá lỗi đồng bộ UI/Backend)**: Xử lý triệt để 6 điểm lệch giữa giao diện Flutter, máy chủ Rust Axum, Docker Compose và quy trình CI/CD.
2. **Giai đoạn 2 (Hướng 1 — Nâng cấp Trải nghiệm Học tập Gen 3)**: Mở rộng kho giáo trình (Katakana, JLPT N5/N4, TOEIC), bổ sung tính năng tự tạo thẻ từ vựng cá nhân và trực quan hóa hướng dẫn nét viết trên Canvas.

## 1. Quy Tắc Bắt Buộc Khi Thực Thi Mã Nguồn (Agent Guardrails)

Mọi thay đổi trên kho lưu trữ phải tuân thủ nghiêm ngặt các quy định kỹ thuật từ `PROJECT.md`, `AGENTS.md` và `TEST_INFRA.md`:

- **Sử dụng đúng bộ công cụ Flutter đã ghim (`.fvmrc`)**: Dự án ghim cứng **Flutter `3.47.6`** và **Dart `3.13.5`**. Luôn gọi lệnh qua trình bọc `./tools/flutter` (từ thư mục gốc) hoặc `../tools/flutter` (từ thư mục `app/`). Nền tảng mục tiêu chỉ gồm **Android** và **Linux Desktop**.
- **Phân tích đồ thị mã nguồn GitNexus trước và sau khi sửa (`AGENTS.md`)**:
  - Trước khi chỉnh sửa bất kỳ hàm, lớp hoặc phương thức nào, bắt buộc chạy phân tích phạm vi ảnh hưởng:
    ```bash
    node .gitnexus/run.cjs impact "<symbolName>" --direction upstream --repo .
    ```
  - Trước khi commit, bắt buộc kiểm tra thay đổi trên toàn bộ đồ thị và đảm bảo kết quả không có cờ `partial: true` hay `truncated: true`:
    ```bash
    node .gitnexus/run.cjs detect-changes --scope all --repo .
    ```
- **Bảo toàn nguyên tắc Offline-First và không gian lận kiểm thử (`TEST_INFRA.md`)**:
  - Mọi thao tác ôn tập FSRS hoặc tạo thẻ bài học mới phải ghi xuống SQLite cục bộ (`LocalDatabase`) trước khi đẩy vào hàng đợi đồng bộ (`SyncCoordinator`).
  - Không làm hỏng các bài kiểm thử hiện có (82 Flutter tests, 38 Rust tests, 47 kịch bản E2E 4 tầng).

## 2. Ma Trận 6 Hạng Mục Thực Thi Giai Đoạn 1 (M4 Closure & UI/Backend Alignment)

| Mã | Hạng mục công việc | Tệp tin mục tiêu | Dòng mã hiện tại | Vấn đề cốt lõi cần giải quyết | Tiêu chí nghiệm thu (Acceptance Criteria) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **T1** | Mở khóa Canvas luyện viết và ML Kit cho Tiếng Anh (`en`) | `app/lib/screens/canvas_practice_screen.dart`<br>`app/lib/screens/ai_roleplay_screen.dart` | `162, 184, 197, 223–267, 275, 294–301, 360, 369, 477, 718`<br>`698, 721, 1030` | UI đang khóa cứng `lesson.language == 'ja'`, ẩn vùng vẽ và nút luyện viết đối với các bài học tiếng Anh (`en`). | Bài học `en` hiển thị đầy đủ vùng vẽ `HandwritingCanvas`, hướng dẫn nét viết, trạng thái model `en-US`, và chấm điểm nhận diện. |
| **T2** | Bổ sung bộ lọc danh mục `jlpt_n5` và `custom` | `app/lib/screens/curriculum_screen.dart` | `32, 248–270, 349` | Dữ liệu có danh mục `jlpt_n5` (10 chữ Kanji) và `custom`, nhưng thanh lọc chỉ có `alphabet` và `it_workplace`. | Thanh lọc hiển thị đủ chip `Bảng chữ cái`, `JLPT N5 (Kanji)`, `IT Chuyên ngành`, và `Từ tự tạo`; lọc chính xác theo danh mục. |
| **T3** | Khởi tạo bài luyện viết động (Ad-hoc Lesson) từ AI Roleplay | `app/lib/screens/main_shell_screen.dart`<br>`app/lib/screens/ai_roleplay_screen.dart`<br>`app/lib/services/api_service.dart` | `48–69`<br>`8, 698–762, 1030–1044`<br>`1351–1375` | Bấm vào từ vựng do AI sinh ra (như `"進捗"`, `"禁煙"`) bị báo lỗi *"chưa có bài luyện viết"* nếu từ đó chưa nằm trong giáo trình tĩnh. | Tự động khởi tạo `LessonItem` thuộc danh mục `custom`, lưu vào SQLite (`local_lessons`) và mở ngay trên `CanvasPracticeScreen`. |
| **T4** | Mở khóa chọn Ngành nghề (`Profession`) và Cấp độ (`Level`) | `app/lib/screens/ai_roleplay_screen.dart`<br>`app/lib/services/api_service.dart` | `29, 145–149, 176–181, 278–390`<br>`1392–1415, 1475–1497` | `_selectedProfession` bị gán `final String = 'IT'` và `user_level` bị gán cứng `'beginner'` trong `ApiService`. | Người dùng chọn được 4 ngành (`it`, `hospitality`, `business`, `general`) và 3 cấp độ (`beginner`, `intermediate`, `advanced`) trên UI. |
| **T5** | Đồng bộ hóa `ai-stub` trong Docker Compose | `docker-compose.yml` | `18–21, 83–96` | `server` gọi `POST /v1/chat/completions` (`llama_cpp`) nhưng `ai-stub` chỉ lắng nghe `POST /api/generate` (trả về 404). | `ai-stub` phản hồi HTTP 200 hợp lệ cho cả `/api/generate` và `/v1/chat/completions` với JSON đúng schema của backend. |
| **T6** | Xử lý cảnh báo `cargo-audit` (`RUSTSEC-2023-0071`) | `server/Cargo.toml`<br>`server/.cargo/audit.toml`<br>`.github/workflows/security-scan.yml` | `Cargo.toml: 26`<br>`security-scan.yml: 44–48` | Crate `rsa 0.9.10` nằm trong nhánh phụ thuộc tùy chọn không dùng tới của `sqlx` làm bước `cargo audit` trên CI thất bại. | `cargo audit` trong thư mục `server/` thoát với mã `0`, có cấu hình kiểm soát minh bạch và không ảnh hưởng tới PostgreSQL. |

## 3. Hướng Dẫn Triển Khai Chi Tiết Từng Hạng Mục (Giai Đoạn 1)

### Task 1 (T1): Mở khóa Canvas luyện viết và ML Kit Model cho Tiếng Anh (`en`)

**Nguyên nhân gốc rễ**:
Tầng dịch vụ `MlKitDigitalInkEngine`, `HeuristicDigitalInkEngine` (`app/lib/services/digital_ink_engine.dart` dòng `13–18`, `104–108`, `280–285`) và `HandwritingRecognizer` (`app/lib/services/handwriting_recognizer.dart` dòng `128–163`) đã hỗ trợ đầy đủ cả `'ja'` (`ja-JP`) và `'en'` (`en-US`). Tuy nhiên, tầng giao diện `CanvasPracticeScreen` và `AIRoleplayScreen` lại chặn bằng điều kiện `== 'ja'`.

**Các bước sửa mã nguồn**:
1. Trong `app/lib/screens/canvas_practice_screen.dart`:
   - Tạo một getter hỗ trợ kiểm tra ngôn ngữ luyện viết hợp lệ:
     ```dart
     bool _supportsHandwriting(String? lang) => lang == 'ja' || lang == 'en';
     ```
   - Tại `_loadInitialData()` (dòng `162`), `_focusLessonById()` (dòng `184`, `197`), `_onLanguageSelected()` (dòng `275`), `_goToPreviousLesson()` (dòng `360`), và `_goToNextLesson()` (dòng `369`): Thay điều kiện `if (_currentLesson?.language == 'ja') _checkModelStatus();` bằng `if (_supportsHandwriting(_currentLesson?.language)) _checkModelStatus();`.
   - Tại `_checkModelStatus()` (dòng `223–247`) và `_downloadModel()` (dòng `249–267`): Thay điều kiện `lang != 'ja'` bằng `!_supportsHandwriting(lang)`.
   - Tại `_evaluateHandwriting()` (dòng `294–301`): Thay `lesson.language != 'ja'` bằng `!_supportsHandwriting(lesson.language)`.
   - Tại `build()` (dòng `477–480`): Hiển thị `_buildCanvasSection(lesson)` cho mọi bài học thỏa mãn `_supportsHandwriting(lesson.language)` (hoặc hiển thị mặc định cho tất cả bài học `ja` và `en`).
   - Tại `_buildLessonInfoCard()` (dòng `651–667` và `718–720`):
     - Cập nhật nhãn badge danh mục để hiển thị đúng theo `lesson.category` (ví dụ: `JA • Bảng chữ cái`, `JA • JLPT N5`, `JA • IT Workplace`, `EN • IT Workplace`, `Custom`).
     - Bỏ điều kiện `lesson.language == 'ja'` ở dòng `718`, chỉ cần kiểm tra `lesson.strokeOrderHints.isNotEmpty` để hiển thị accordion *"Hướng dẫn thứ tự nét viết"* cho cả tiếng Anh và tiếng Nhật.
2. Trong `app/lib/screens/ai_roleplay_screen.dart`:
   - Tại `_buildAiBubble()` (dòng `698` và `721`) và `_buildDialogueScriptTab()` (dòng `1030`): Bỏ điều kiện `_selectedLanguage == 'ja' &&`, cho phép hiển thị nút icon luyện viết (`Icons.draw_rounded`) và banner thử thách viết (`writingChallenge`) cho cả tiếng Nhật (`ja`) và tiếng Anh (`en`) khi `widget.onPracticeWord != null`.

### Task 2 (T2): Bổ sung Bộ lọc Danh mục `jlpt_n5` và `custom` trên Màn hình Giáo trình

**Nguyên nhân gốc rễ**:
Trong `server/src/data.rs` (dòng `801–964`), 10 bài học Kanji có `category: "jlpt_n5"`, và các thẻ tự sinh có `category: "custom"`. Nhưng `app/lib/screens/curriculum_screen.dart` (dòng `248–269`) chỉ có 2 chip lọc danh mục.

**Các bước sửa mã nguồn**:
1. Trong `app/lib/screens/curriculum_screen.dart`:
   - Cập nhật chú thích biến `_selectedCategory` (dòng `32`): hỗ trợ `'all'`, `'alphabet'`, `'jlpt_n5'`, `'it_workplace'`, `'custom'`.
   - Trong `_buildFilterBar()` (dòng `248–269`), bổ sung thêm các `ChoiceChip` danh mục sau vạch ngăn cách:
     - `'alphabet'` → `'Bảng chữ cái'`
     - `'jlpt_n5'` → `'JLPT N5 (Kanji)'`
     - `'it_workplace'` → `'IT Chuyên ngành'`
     - `'custom'` → `'Từ tự tạo'`
   - Trong `_buildLessonList()` (khoảng dòng `348–351`), thêm một badge nhỏ hiển thị danh mục của từng thẻ bài học để người học dễ phân biệt.

### Task 3 (T3): Hỗ trợ Khởi tạo Bài luyện viết Động (Ad-hoc Custom Lesson) từ AI Roleplay

**Nguyên nhân gốc rễ**:
Trong `app/lib/screens/main_shell_screen.dart` (dòng `48–69`), `_navigateToCanvasWithWord(String word, String language)` chỉ tìm kiếm tuyến tính trong danh sách `getLessons()`. Nếu người dùng bấm vào một từ mới do AI gợi ý (như `"進捗"`, `"相談"`, `"実装"`, `"commit"`, `"standup"`), ứng dụng không tìm thấy và chỉ hiện `SnackBar` báo lỗi. Trong khi đó, cả SQLite cục bộ (`local_lessons`) lẫn PostgreSQL (`server/src/db.rs` dòng `225–238`) đều đã được thiết kế để chấp nhận thẻ bài học tùy chỉnh (`custom`).

**Các bước sửa mã nguồn**:
1. Trong `app/lib/services/api_service.dart`:
   - Bổ sung phương thức `ensureLessonForWord`:
     ```dart
     Future<LessonItem> ensureLessonForWord({
       required String word,
       required String language,
       String? phoneticOrKana,
       String? meaningVi,
       String? workplaceContext,
       String? workplaceContextVi,
     }) async
     ```
   - Quy trình xử lý trong `ensureLessonForWord`:
     - Tìm trong `await getLessons()` xem đã có bài học nào khớp `lesson.language == language && lesson.targetText.trim().toLowerCase() == word.trim().toLowerCase()` chưa. Nếu có, trả về bài học đó ngay.
     - Nếu chưa có, tạo một đối tượng `LessonItem` mới:
       - `id`: tạo ID ổn định, ví dụ `'custom_${language}_${word.trim().toLowerCase().replaceAll(RegExp(r"\\s+"), "_")}'`.
       - `language`: `language` (`'ja'` hoặc `'en'`).
       - `category`: `'custom'`.
       - `targetText`: `word.trim()`.
       - `phoneticOrKana`: `phoneticOrKana?.trim() ?? ''`.
       - `meaningVi`: `(meaningVi != null && meaningVi.trim().isNotEmpty) ? meaningVi.trim() : 'Từ vựng thực chiến từ AI Roleplay'`.
       - `workplaceContext`: `workplaceContext?.trim() ?? ''`.
       - `workplaceContextVi`: `workplaceContextVi?.trim() ?? ''`.
       - `strokeOrderHints`: sinh gợi ý mặc định dựa theo ngôn ngữ (ví dụ với `'ja'`: `['Viết từng ký tự của "$word" theo thứ tự từ trái sang phải, từ trên xuống dưới']`; với `'en'`: `['Viết thường "${word.trim()}" liền mạch trong khung vẽ']`).
       - `difficultyLevel`: `2`.
     - Lưu bài học mới xuống SQLite bằng `await _localDb.saveLessons([newLesson]);` và trả về `newLesson`.
2. Trong `app/lib/screens/main_shell_screen.dart` và `app/lib/screens/ai_roleplay_screen.dart`:
   - Cập nhật `_navigateToCanvasWithWord` trong `MainShellScreen` để gọi `_apiService.ensureLessonForWord(...)` (có thể nhận thêm các tham số tùy chọn `meaningVi`, `phonetic`, `contextSentence`, `contextVi` hoặc tra cứu từ tin nhắn AI hiện tại), sau đó gọi `_navigateToCanvasWithLesson(lesson.id)` để mở ngay bài luyện viết trên `CanvasPracticeScreen`.
   - Trong `CanvasPracticeScreen._loadInitialData()` và `_focusLessonById()`, đảm bảo khi `initialLessonId` được truyền vào, danh sách `_allLessons` được làm mới từ `_apiService.getLessons()` nếu chưa tìm thấy `initialLessonId` trong bộ nhớ đệm của màn hình.

### Task 4 (T4): Mở khóa Bộ chọn Ngành nghề (`Profession`) và Cấp độ (`Difficulty Level`) trong AI Roleplay

**Nguyên nhân gốc rễ**:
Backend (`server/src/ai.rs` và `server/src/models.rs`) đã xử lý đầy đủ `profession` (`"it"`, `"hospitality"`, `"business"`, `"general"`) và `user_level`/`difficulty_level` (`"beginner"`, `"intermediate"`, `"advanced"`). Tuy nhiên:
- `ApiService.sendRoleplayMessage` (`app/lib/services/api_service.dart` dòng `1392–1410`) chưa có tham số `profession` và đang gán cứng `'user_level': 'beginner'`.
- `AIRoleplayScreen` (`app/lib/screens/ai_roleplay_screen.dart` dòng `29`) khai báo `final String _selectedProfession = 'IT';` và không có biến trạng thái cho cấp độ khó.

**Các bước sửa mã nguồn**:
1. Trong `app/lib/services/api_service.dart`:
   - Cập nhật chữ ký `sendRoleplayMessage`:
     ```dart
     Future<Map<String, dynamic>> sendRoleplayMessage({
       required String targetLanguage,
       required String topic,
       required String message,
       String profession = 'it',
       String userLevel = 'beginner',
     }) async
     ```
   - Truyền `'profession': profession.toLowerCase()` và `'user_level': userLevel.toLowerCase()` vào payload JSON của `POST $baseUrl/ai/roleplay`.
2. Trong `app/lib/screens/ai_roleplay_screen.dart`:
   - Đổi `final String _selectedProfession = 'IT';` thành biến trạng thái `String _selectedProfession = 'it';` và thêm `String _selectedLevel = 'beginner';`.
   - Cập nhật danh sách chủ đề `_topicsByLang` hoặc bổ sung bộ chọn `DropdownButton` / `PopupMenuButton` / `ChoiceChip` nhỏ gọn ngay trên `_buildConfigurationHeader()` (dòng `325–349`) cho phép đổi:
     - **Ngành nghề**: `IT` (`it`), `Nhà hàng - Khách sạn` (`hospitality`), `Kinh doanh` (`business`), `Giao tiếp chung` (`general`).
     - **Cấp độ**: `Sơ cấp` (`beginner`), `Trung cấp` (`intermediate`), `Nâng cao` (`advanced`).
   - Truyền `_selectedProfession` và `_selectedLevel` vào cả `_apiService.sendRoleplayMessage(...)` và `_apiService.generateDialogue(...)`.

### Task 5 (T5): Đồng bộ hóa `ai-stub` trong `docker-compose.yml`

**Nguyên nhân gốc rễ**:
Trong `docker-compose.yml`, dịch vụ `server` được cấu hình `AI_PROVIDER=llama_cpp` và `AI_ENDPOINT=http://ai-stub:11434/v1/chat/completions` (dòng `18–19`), nhưng container `ai-stub` (dòng `85`) chỉ kiểm tra `if self.path == "/api/generate":` và trả về `404` cho mọi đường dẫn khác.

**Các bước sửa mã nguồn**:
1. Trong `docker-compose.yml` (dòng `79–108`), cập nhật `do_POST` của `AIHandler` trong `ai-stub`:
   - Chấp nhận cả `self.path == "/api/generate"` và `self.path == "/v1/chat/completions"`.
   - Tạo một chuỗi JSON hợp lệ chứa đầy đủ các trường (`reply`, `opening_line`, `reply_translation_vi`, `breakdown`, `writing_challenge`, `title`, `title_vi`, `lines`, `vocabulary`, `grammar_hints`, `suggested_writing_targets`).
   - Nếu `self.path == "/v1/chat/completions"`, trả về cấu trúc chuẩn OpenAI:
     ```json
     {
       "choices": [
         {
           "message": {
             "role": "assistant",
             "content": "<chuỗi JSON hợp lệ>"
           }
         }
       ]
     }
     ```
   - Nếu `self.path == "/api/generate"`, trả về cấu trúc chuẩn Ollama:
     ```json
     {
       "response": "<chuỗi JSON hợp lệ>"
     }
     ```
2. Chạy `docker compose config` và bộ kiểm thử E2E Tier 1 & Tier 3 để đảm bảo cấu hình `docker-compose.yml` hợp lệ 100%.

### Task 6 (T6): Xử lý Cảnh báo Bảo mật `cargo-audit` (`RUSTSEC-2023-0071`)

**Nguyên nhân gốc rễ**:
Theo `TEST_READY.md` (dòng `26`, `77`), `cargo-audit` báo lỗi `RUSTSEC-2023-0071` đối với crate `rsa 0.9.10` nằm trong cây phụ thuộc tùy chọn `sqlx-mysql` của `sqlx`, mặc dù `server/Cargo.toml` chỉ bật feature `"postgres"` và `cargo tree --locked --target all -i rsa` xác nhận `rsa` hoàn toàn không được biên dịch vào binary của dự án.

**Các bước sửa mã nguồn**:
1. Kiểm tra lại cây phụ thuộc trong `server/`:
   ```bash
   cd server && cargo tree --locked --target all -i rsa
   ```
2. Tạo tệp cấu hình `server/.cargo/audit.toml` với nội dung tường minh, ghi rõ lý do miễn trừ kỹ thuật (hoặc cập nhật `.github/workflows/security-scan.yml`):
   ```toml
   [advisories]
   # RUSTSEC-2023-0071 (rsa 0.9.10) hanya xuất hiện trong metadata Cargo.lock của sqlx-mysql (không được kích hoạt).
   # Dự án sử dụng default-features = false và chỉ bật postgres + tls-rustls.
   # Đã xác minh bằng: cargo tree --locked --target all -i rsa (0 active dependencies).
   ignore = ["RUSTSEC-2023-0071"]
   ```
3. Cập nhật tài liệu `TEST_READY.md` và `PROJECT.md` ghi nhận chính sách audit đã được thiết lập tường minh trong `server/.cargo/audit.toml`.

## 4. Đặc Tả Giai Đoạn 2: Nâng Cấp Trải Nghiệm Học Tập (Hướng 1 — Learning UX Expansion)

Sau khi hoàn tất và vượt qua toàn bộ bài kiểm thử của Giai đoạn 1, triển khai tiếp 3 tính năng nâng cấp trải nghiệm người học dưới đây:

### Task 7 (T7): Mở rộng Kho Giáo Trình Chuẩn (`server/src/data.rs` & `app/lib/services/api_service.dart`)

- **Mục tiêu**: Mở rộng danh sách bài học hạt giống (`get_seed_lessons()` trong `server/src/data.rs` và `_fallbackLessons` trong `app/lib/services/api_service.dart`) để phủ kín lộ trình từ mất gốc đến đi làm:
  1. **Danh mục `katakana` (hoặc mở rộng `alphabet`)**: Bổ sung các ký tự Katakana cốt lõi và cụm từ mượn thông dụng trong công sở (`コード`, `タスク`, `エラー`, `データ`, `メール`, `スケジュール`, `ミーティング`, `クライアント`).
  2. **Danh mục `jlpt_n5` & `jlpt_n4`**: Bổ sung ít nhất 15 chữ Kanji và từ ghép thông dụng trong môi trường làm việc (`社`, `会`, `事`, `仕`, `업/業`, `프/進`, `捗`, `報`, `告`, `連`, `絡`, `相`, `談` — bộ quy tắc *Hou-Ren-Sou: 報告・連絡・相談*).
  3. **Danh mục `it_workplace` & `business_toeic` (Tiếng Anh)**: Bổ sung ít nhất 15 từ vựng thực chiến trong họp Agile, PR Review và giao tiếp khách hàng (`standup`, `blocker`, `milestone`, `rollback`, `scalability`, `throughput`, `idempotent`, `regression`, `payload`, `deprecated`, `onboarding`, `stakeholder`, `estimate`, `prioritize`, `followup`).
- **Ràng buộc**:
  - Giữ nguyên toàn bộ ID và dữ liệu của các bài học hiện có để không ảnh hưởng tới các bài kiểm thử E2E Tier 1–4 đang kiểm tra các ID cố định (`ja_hira_a`, `ja_kata_bug`, `ja_it_kaihatsu`, `en_it_deploy`, `en_it_deadline`, `en_it_resolve`).
  - Mỗi bài học mới phải có đầy đủ `target_text`, `phonetic_or_kana`, `meaning_vi`, `workplace_context`, `workplace_context_vi`, `stroke_order_hints` (ít nhất 2 gợi ý), và `difficulty_level` (`1..=3`).

### Task 8 (T8): Tính năng Tự Tạo Thẻ Từ Vựng Cá Nhân (Custom Flashcard Builder)

- **Mục tiêu**: Cho phép người học chủ động thêm từ vựng/câu mới của riêng mình ngay trên màn hình `CurriculumScreen`.
- **Thiết kế chi tiết**:
  - Thêm nút `FloatingActionButton` (`Icons.add_rounded`, nhãn `"Thêm từ mới"`) trên `CurriculumScreen`.
  - Khi bấm vào, mở hộp thoại (`showModalBottomSheet` hoặc `AlertDialog`) theo phong cách Dark-mode của ứng dụng gồm các trường:
    - Ngôn ngữ: `Tiếng Nhật (ja)` / `Tiếng Anh (en)`
    - Từ vựng / Chữ cần luyện viết (`targetText` — bắt buộc)
    - Phiên âm / Kana (`phoneticOrKana`)
    - Nghĩa tiếng Việt (`meaningVi` — bắt buộc)
    - Câu ví dụ công sở (`workplaceContext`) & Dịch nghĩa câu ví dụ (`workplaceContextVi`)
  - Khi người dùng bấm **Lưu & Luyện viết**:
    - Gọi `_apiService.ensureLessonForWord(...)` để lưu vào bảng `local_lessons` với `category: 'custom'`.
    - Khởi tạo thẻ FSRS ban đầu hoặc chuyển trực tiếp sang `CanvasPracticeScreen` để người dùng luyện viết ngay.

### Task 9 (T9): Nâng Cấp Trực Quan Hóa Luyện Viết trên `HandwritingCanvas`

- **Mục tiêu**: Giúp người mới học viết Kanji/Kana và tiếng Anh căn chỉnh tỷ lệ chữ chuẩn xác hơn trên màn hình cảm ứng.
- **Thiết kế chi tiết**:
  - Trong `app/lib/widgets/handwriting_canvas.dart` và `app/lib/screens/canvas_practice_screen.dart`:
    - Bổ sung chế độ lưới luyện viết chuẩn **Ô vuông Genkouyoushi 4 phần** (dành cho tiếng Nhật: đường kẻ ngang/dọc chia tâm có nét đứt mờ) và **Dòng kẻ Baseline 4 đường** (dành cho tiếng Anh: đường kẻ ascender, midline, baseline, descender) để hỗ trợ trí nhớ cơ bắp.
    - Thêm nút hoàn tác nét vẽ vừa viết (**Undo Stroke** — xóa nét cuối cùng trong `_strokes` và kích hoạt lại đánh giá) bên cạnh nút **Xóa toàn bộ (Clear)** trên thanh công cụ Canvas.
    - Hiển thị số thứ tự nét đang viết (`Nét đã viết: X / Y nét gợi ý`) trực tiếp trên góc thanh trạng thái của Canvas.

## 5. Quy Trình Kiểm Thử & Cổng Nghiệm Thu Bắt Buộc (Verification Gates)

Sau khi hoàn thành các hạng mục trên, AI Agent phải bổ sung kiểm thử tự động cho các tính năng mới và chạy toàn bộ chuỗi lệnh nghiệm thu dưới đây. Không được kết thúc nhiệm vụ nếu bất kỳ lệnh nào trả về mã lỗi khác `0`.

### 5.1. Các bài kiểm thử mới cần viết thêm (`app/test/`)
1. **Test Canvas Tiếng Anh (`app/test/widget_test.dart` hoặc tệp test chuyên biệt)**:
   - Chọn bài học tiếng Anh (ví dụ `en_it_deploy`), xác nhận widget `HandwritingCanvas` được hiển thị, vẽ nét chữ giả lập và xác nhận nút **Đánh giá** hoạt động.
2. **Test Bộ lọc Danh mục & Tạo Thẻ Tự Chọn (`CurriculumScreen`)**:
   - Xác nhận các chip lọc `JLPT N5 (Kanji)` và `Từ tự tạo` lọc đúng danh sách bài học.
   - Kiểm thử luồng `ensureLessonForWord` tạo thẻ `custom`, lưu vào SQLite FFI và mở được trên `CanvasPracticeScreen`.
3. **Test Nút Undo Stroke trên Canvas**:
   - Vẽ 2 nét lên `HandwritingCanvas`, bấm nút **Hoàn tác (Undo)**, xác nhận còn đúng 1 nét.

### 5.2. Danh sách lệnh kiểm tra bắt buộc (Chạy tuần tự)

```bash
# 1. Kiểm tra định dạng, trình biên dịch, Clippy và Unit Tests của Backend Rust
cd server
cargo fmt -- --check
cargo check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets

# 2. Kiểm tra bảo mật phụ thuộc Rust (với cấu hình audit.toml)
cargo audit

# 3. Kiểm tra định dạng, phân tích tĩnh và toàn bộ Unit/Widget Tests của Flutter
cd ../app
../.toolchains/flutter/3.47.6/flutter/bin/dart format --output=none --set-exit-if-changed .
../tools/flutter analyze
../tools/flutter test

# 4. Kiểm tra cú pháp Docker Compose và Unit Tests của trình chạy E2E
cd ..
docker compose config -q
python3 -B -m unittest discover -s tests/e2e -p 'test_*.py' -v

# 5. Chạy bộ kiểm thử 4 tầng E2E (47 kịch bản) và Adversarial Suite
AI_ENDPOINT=http://127.0.0.1:9/v1/chat/completions \
AI_FALLBACK_ENABLED=true \
./tests/e2e/run_e2e_tests.sh --all

ADVERSARIAL_PORT_OFFSET=10000 python3 -B tests/adversarial_suite.py

# 6. Phân tích thay đổi đồ thị mã nguồn GitNexus trước khi hoàn tất
node .gitnexus/run.cjs analyze --index-only
node .gitnexus/run.cjs detect-changes --scope all --repo .
```

### 5.3. Cập nhật tài liệu trạng thái dự án
Sau khi toàn bộ lệnh ở mục `5.2` vượt qua 100%:
- Cập nhật số lượng bài kiểm thử mới nhất vào `PROJECT.md`, `TEST_READY.md`, và `TEST_INFRA.md`.
- Đảm bảo `git status` sạch sẽ, không chứa các tệp rác sinh ra trong quá trình chạy thử nghiệm (`server.log`, `.db` tạm, v.v.).
