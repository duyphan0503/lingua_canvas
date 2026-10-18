# Đặc Tả Kỹ Thuật & Kế Hoạch Thực Thi Cho AI Agent: Mở Rộng Giai Đoạn 3 (Trải Nghiệm Học Tập) & Giai Đoạn 4 (Hạ Tầng Kỹ Thuật)

Tài liệu này là bản đặc tả kỹ thuật chi tiết nối tiếp sau khi dự án **Lingua Canvas** đã hoàn tất Giai đoạn 1 & 2. Tài liệu được thiết kế để AI Coding Agent thực thi tuần tự **cả hai định hướng mở rộng lớn (Giai đoạn 3 & Giai đoạn 4)** mà **không cần cài đặt thêm bất kỳ thư viện bên ngoài nào** (đảm bảo tương thích 100% với môi trường CI/sandbox không có mạng và giữ nguyên tính toàn vẹn của `Cargo.lock` / `pubspec.lock`):

1. **Giai đoạn 3 — Chiều sâu Trải nghiệm Học tập (Learning Experience Track)**:
   - Mở rộng giáo trình chuyên sâu **JLPT N4 & TOEIC Business** kèm bộ lọc trên UI.
   - **Hoạt ảnh thứ tự nét vẽ trực quan (Kanji/Kana Stroke-Order Animation)** ngay trên `HandwritingCanvas`.
   - **Luyện nói & Chấm điểm phát âm (Speech-to-Text Pronunciation Practice)** sử dụng kênh native Android `SpeechRecognizer` kết hợp bộ mô phỏng cho Linux/CI.
2. **Giai đoạn 4 — Tối ưu Hạ tầng Kỹ thuật & Đồng bộ Đa thiết bị (Infrastructure & Scale Track)**:
   - **Loại bỏ khóa toàn cục PostgreSQL** (`pg_advisory_xact_lock(0, 1)`) bằng con trỏ tuần tự `sync_seq` (`BIGSERIAL`) kết hợp khóa mịn theo từng thẻ.
   - **Tích hợp Redis Cache & Rate-Limiting** (`server/src/redis_cache.rs`) giao tiếp trực tiếp qua giao thức RESP2 trên `tokio::net::TcpStream` (kèm bộ nhớ đệm dự phòng in-memory khi offline).
   - **Quản lý Tài khoản & Đồng bộ Đa thiết bị (Android ↔ Linux Desktop)** qua mã đồng bộ (`sync_token`) hoặc tài khoản PIN nhẹ.

## 1. Quy Tắc Bắt Buộc Khi Thực Thi Mã Nguồn (Agent Guardrails)

- **Toolchain cố định (`.fvmrc`)**: Luôn sử dụng `./tools/flutter` (từ thư mục gốc) hoặc `../tools/flutter` (từ thư mục `app/`) tương ứng với **Flutter `3.47.6`** và **Dart `3.13.5`**.
- **Không thêm phụ thuộc mạng bên ngoài**:
  - Không chạy `cargo add` hoặc `flutter pub add` yêu cầu tải gói mới từ internet.
  - Mọi tính năng mới đều sử dụng các crate đã có sẵn trong `server/Cargo.toml` (`tokio`, `sqlx`, `axum`, `serde`, `chrono`, `reqwest`, `rand`) và các gói đã có trong `app/pubspec.yaml` cùng `MethodChannel` gốc của Android (`MainActivity.kt`).
- **Quy trình GitNexus (`AGENTS.md`)**:
  - Trước khi sửa một symbol hiện có: `node .gitnexus/run.cjs impact "<symbolName>" --direction upstream --repo .`
  - Trước khi hoàn tất/commit: `node .gitnexus/run.cjs detect-changes --scope all --repo .` (đảm bảo không có cờ `partial: true` hoặc `truncated: true`).
- **Tương thích ngược 100% với E2E Suite**: Mọi thay đổi trên API (`/api/v1/lessons`, `/api/v1/fsrs/*`, `/api/v1/ai/*`, `/api/v1/sync`, `/api/v1/sync/pull`) phải giữ nguyên tính tương thích ngược với 47 bài kiểm thử trong `tests/e2e/`. Khi client không gửi `user_id` hoặc `X-Sync-Token`, hệ thống mặc định sử dụng `'default_user'`.

## 2. Ma Trận Tổng Quan Các Hạng Mục Thực Thi (Giai Đoạn 3 & 4)

| Mã | Nhánh | Hạng mục công việc | Tệp tin tạo mới / chỉnh sửa | Tiêu chí nghiệm thu (Acceptance Criteria) |
| :--- | :--- | :--- | :--- | :--- |
| **G3-T1** | Học tập | Mở rộng kho giáo trình `jlpt_n4` và `toeic_business` | `server/src/data.rs`<br>`app/lib/services/api_service.dart`<br>`app/lib/screens/curriculum_screen.dart` | Bổ sung tối thiểu 20 bài học `jlpt_n4` (Kanji & Keigo công sở) và `toeic_business` (Email, Đàm phán, Báo cáo); lọc được trên `CurriculumScreen`. |
| **G3-T2** | Học tập | Hoạt ảnh thứ tự nét vẽ Kanji/Kana (Stroke Animation) | `app/lib/services/stroke_guide_service.dart` *(mới)*<br>`app/lib/widgets/handwriting_canvas.dart`<br>`app/lib/screens/canvas_practice_screen.dart` | Có nút **"Xem nét mẫu"** trên Canvas; phát hoạt ảnh từng nét vẽ theo thứ tự kèm số hiệu nét (`①`, `②`, `③`) và mũi tên hướng bút. |
| **G3-T3** | Học tập | Luyện nói & Chấm điểm phát âm (STT Pronunciation) | `app/android/app/src/main/AndroidManifest.xml`<br>`app/android/app/src/main/kotlin/com/linguacanvas/app/MainActivity.kt`<br>`app/lib/services/speech_practice_service.dart` *(mới)*<br>`app/lib/screens/canvas_practice_screen.dart`<br>`app/lib/screens/ai_roleplay_screen.dart` | Người dùng thu âm giọng đọc (qua `SpeechRecognizer` trên Android hoặc bộ mô phỏng trên Linux/Test), nhận điểm phát âm (`0–100%`) và phản hồi chi tiết; hỗ trợ nhập giọng nói trong AI Roleplay. |
| **G4-T1** | Hạ tầng | Loại bỏ khóa toàn cục PostgreSQL & nâng cấp con trỏ `sync_seq` | `server/migrations/20261001000003_gen3_sync_and_accounts.sql` *(mới)*<br>`server/src/routes.rs`<br>`server/src/routes/sync.rs`<br>`server/src/db.rs` | Loại bỏ `pg_advisory_xact_lock(0, 1)`; sử dụng sequence `sync_change_seq` (`sync_seq BIGINT`) và khóa mịn theo `(user_id, item_id)` mà không làm hỏng LWW hay 47 bài test E2E. |
| **G4-T2** | Hạ tầng | Tích hợp Redis Cache & Rate-Limiting cho AI Endpoints | `server/src/redis_cache.rs` *(mới)*<br>`server/src/lib.rs`<br>`server/src/routes.rs`<br>`server/src/main.rs` | Giao tiếp với `REDIS_URL` qua giao thức RESP2 trên `tokio::net::TcpStream` (fallback sang RAM khi Redis tắt); cache kết quả `/ai/dialogue` và `/ai/roleplay` (TTL 3600s), trả kèm header `X-Cache: HIT/MISS`. |
| **G4-T3** | Hạ tầng | Quản lý Tài khoản & Đồng bộ Đa thiết bị (`user_id` / `sync_token`) | `server/src/routes/auth.rs` *(mới)*<br>`server/src/models.rs`<br>`app/lib/services/sync_coordinator.dart`<br>`app/lib/screens/settings_screen.dart` | Đăng ký/đăng nhập bằng `username` + `pin` hoặc `sync_token`; liên kết nhiều thiết bị (Android & Linux Desktop) cùng đồng bộ tiến độ FSRS theo `user_id`. |

## 3. Đặc Tả Chi Tiết Giai Đoạn 3: Phát Triển Trải Nghiệm Học Tập Chuyên Sâu

### Hạng mục G3-T1: Mở rộng Kho Giáo Trình `jlpt_n4` và `toeic_business`

1. **Cập nhật dữ liệu hạt giống (`server/src/data.rs` & `app/lib/services/api_service.dart`)**:
   - Giữ nguyên toàn bộ các bài học hiện có để đảm bảo các bài kiểm thử cũ không bị ảnh hưởng.
   - Bổ sung ít nhất **10 bài học Tiếng Nhật thuộc danh mục `"jlpt_n4"`** tập trung vào Kanji công sở nâng cao và kính ngữ (Keigo):
     - `ja_n4_kaigi` (`会議` — Hội nghị / Cuộc họp), `ja_n4_renraku` (`連絡` — Liên lạc), `ja_n4_soudan` (`相談` — Thảo luận / Xin ý kiến), `ja_n4_houkoku` (`報告` — Báo cáo), `ja_n4_shounin` (`承認` — Phê duyệt), `ja_n4_kigen` (`期限` — Thời hạn), `ja_n4_sekinin` (`責任` — Trách nhiệm), `ja_n4_kaizen` (`改善` — Cải tiến), `ja_n4_shouchi` (`承知いたしました` — Tôi đã rõ / Khiêm nhường ngữ), `ja_n4_irai` (`依頼` — Yêu cầu / Nhờ vả).
   - Bổ sung ít nhất **10 bài học Tiếng Anh thuộc danh mục `"toeic_business"`** tập trung vào giao tiếp thương mại, viết email và đàm phán:
     - `en_biz_negotiate` (`negotiate` — Đàm phán), `en_biz_agenda` (`agenda` — Chương trình nghị sự), `en_biz_proposal` (`proposal` — Bản đề xuất), `en_biz_invoice` (`invoice` — Hóa đơn thương mại), `en_biz_consensus` (`consensus` — Sự đồng thuận), `en_biz_delegate` (`delegate` — Ủy quyền / Giao phó), `en_biz_compliance` (`compliance` — Sự tuân thủ quy định), `en_biz_postpone` (`postpone` — Hoãn lịch), `en_biz_acknowledge` (`acknowledge` — Xác nhận đã nhận), `en_biz_objective` (`objective` — Mục tiêu trọng tâm).
2. **Cập nhật bộ lọc trên `CurriculumScreen` (`app/lib/screens/curriculum_screen.dart`)**:
   - Bổ sung 2 chip lọc danh mục mới trên `_buildFilterBar()`:
     - `'jlpt_n4'` → `'JLPT N4 (Công sở)'`
     - `'toeic_business'` → `'TOEIC & Business'`

### Hạng mục G3-T2: Hoạt Ảnh Thứ Tự Nét Vẽ Kanji/Kana (Stroke-Order Animation)

1. **Tạo dịch vụ tọa độ nét mẫu `app/lib/services/stroke_guide_service.dart`**:
   - Định nghĩa cấu trúc dữ liệu `StrokeGuidePath`:
     ```dart
     class StrokeGuidePath {
       final int strokeNumber; // 1-indexed
       final List<Offset> normalizedPoints; // Tọa độ chuẩn hóa trong khoảng [0.0, 1.0] x [0.0, 1.0]
       final String hintText;
       const StrokeGuidePath({
         required this.strokeNumber,
         required this.normalizedPoints,
         this.hintText = '',
       });
     }
     ```
   - Xây dựng `StrokeGuideService`:
     - Cung cấp bản đồ tọa độ nét chuẩn (`Map<String, List<List<Offset>>>`) cho các chữ Hiragana cơ bản (`あ`, `い`, `う`, `え`, `お`, `か`, `き`, `く`, `け`, `こ`...) và các chữ Kanji trọng tâm (`日`, `月`, `木`, `水`, `金`, `土`, `山`, `川`, `人`, `本`, `開`, `発`, `確`, `認`, `会`, `議`, `連`, `絡`, `相`, `談`, `報`, `告`).
     - Đối với các từ ghép hoặc từ chưa có trong từ điển tọa độ tĩnh, xây dựng bộ sinh quỹ đạo tự động (`generateFallbackGuides(String targetText, List<String> strokeOrderHints)`) phân tích từ khoá trong từng câu `strokeOrderHints` (như *"Nét ngang"*, *"Nét sổ thẳng"*, *"Nét phẩy"*, *"Nét mác"*, *"Nét cong"*, *"Vòng tròn"*) để sinh ra danh sách `StrokeGuidePath` tương ứng với đúng số lượng nét trong `strokeOrderHints`.
2. **Tích hợp bộ phát hoạt ảnh vào `HandwritingCanvas` (`app/lib/widgets/handwriting_canvas.dart`)**:
   - Bổ sung các thuộc tính tùy chọn cho `HandwritingCanvas`:
     - `final List<StrokeGuidePath>? guidePaths;`
     - `final bool isAnimatingGuide;`
     - `final VoidCallback? onGuideAnimationCompleted;`
   - Sử dụng `SingleTickerProviderStateMixin` và `AnimationController` trong `_HandwritingCanvasState`:
     - Khi `isAnimatingGuide` chuyển sang `true`, chạy `AnimationController` với thời lượng `Duration(milliseconds: 650 * guidePaths.length)`.
     - Trong `_CanvasPainter.paint()`, nếu `guidePaths != null && isAnimatingGuide`:
       - Vẽ các nét mẫu đã hoàn thành trước tiến độ hiện tại bằng màu tím nhạt (`Color(0x80818CF8)`).
       - Vẽ nét đang chạy theo tỷ lệ nội suy (`progress`) bằng cọ sáng (`Color(0xFF38BDF8)`) kèm điểm tròn phát sáng ở đầu ngòi bút.
       - Tại điểm bắt đầu của mỗi nét mẫu (`normalizedPoints.first`), vẽ vòng tròn nhỏ đánh số thứ tự (`1`, `2`, `3`...) để người học nhìn rõ điểm đặt bút.
3. **Bổ sung nút điều khiển trên `CanvasPracticeScreen` (`app/lib/screens/canvas_practice_screen.dart`)**:
   - Trên thanh công cụ của `_buildCanvasSection`, thêm nút `TextButton.icon` hoặc `IconButton`:
     - Icon: `Icons.play_circle_outline_rounded` (khi đang phát thì hiển thị `Icons.stop_circle_outlined`).
     - Nhãn / Tooltip: `'Xem nét mẫu'` (`'Dừng mẫu'`).
     - Khi người dùng bắt đầu đặt bút vẽ lên Canvas (`_onPointerDown`), tự động dừng hoạt ảnh nét mẫu để không cản trở thao tác viết.

### Hạng mục G3-T3: Luyện Nói & Chấm Điểm Phát Âm (Speech-to-Text Pronunciation Practice)

1. **Cập nhật quyền và kênh Native Android (`AndroidManifest.xml` & `MainActivity.kt`)**:
   - Trong `app/android/app/src/main/AndroidManifest.xml`:
     - Thêm quyền `<uses-permission android:name="android.permission.RECORD_AUDIO"/>`.
     - Trong khối `<queries>`, thêm `<intent><action android:name="android.speech.RecognitionService"/></intent>`.
   - Trong `app/android/app/src/main/kotlin/com/linguacanvas/app/MainActivity.kt`:
     - Khai báo kênh `private val STT_CHANNEL = "com.linguacanvas.app/stt_native"`.
     - Xử lý các phương thức trên `STT_CHANNEL`:
       - `"isAvailable"`: trả về `SpeechRecognizer.isRecognitionAvailable(applicationContext)`.
       - `"startListening"`: nhận tham số `language` (`"ja-JP"` hoặc `"en-US"`), khởi tạo `SpeechRecognizer` trên Main Thread với `Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)` (`EXTRA_LANGUAGE`, `EXTRA_PARTIAL_RESULTS = true`, `EXTRA_MAX_RESULTS = 5`), và gửi sự kiện `"onSpeechResult"` / `"onSpeechError"` về Flutter qua `MethodChannel`.
       - `"stopListening"`: dừng thu âm và giải phóng `SpeechRecognizer`.
2. **Tạo dịch vụ `app/lib/services/speech_practice_service.dart`**:
   - Định nghĩa kết quả chấm điểm phát âm `PronunciationResult`:
     ```dart
     class PronunciationResult {
       final String recognizedTranscript;
       final String targetText;
       final double accuracyScore; // 0.0 -> 1.0
       final bool isPassed; // accuracyScore >= 0.75
       final String feedbackVi;
       const PronunciationResult({
         required this.recognizedTranscript,
         required this.targetText,
         required this.accuracyScore,
         required this.isPassed,
         required this.feedbackVi,
       });
     }
     ```
   - Định nghĩa interface `SpeechPracticeEngine` với 2 cài đặt:
     - `PlatformSpeechPracticeEngine`: gọi kênh `com.linguacanvas.app/stt_native` trên Android; nếu chạy trên Linux Desktop hoặc thiết bị không có microphone, cho phép nhập chuỗi phát âm kiểm thử hoặc sử dụng chế độ mô phỏng.
     - `MockSpeechPracticeEngine`: phục vụ kiểm thử tự động (Unit/Widget test) với đầu ra xác định (`deterministic transcript`).
   - Xây dựng hàm chấm điểm `evaluatePronunciation({required String recognized, required String targetText, required String phoneticOrKana, required String language})`:
     - Chuẩn hóa dấu câu, khoảng trắng, chữ hoa/thường.
     - Tính tỷ lệ tương đồng `HandwritingRecognizer.levenshteinRatio` giữa `recognized` với cả `targetText` (ví dụ Kanji `"開発"`) và `phoneticOrKana` (ví dụ Kana/Romaji `"かいはつ"` / `"kaihatsu"`), lấy điểm cao nhất để không phạt người học khi STT trả về Kana thay vì Kanji.
     - Sinh nhận xét tiếng Việt cụ thể (ví dụ: *"Phát âm chuẩn xác (92%)!"* hoặc *"Bạn phát âm là '...' — hãy chú ý âm cuối / trường âm của '...'"*).
3. **Tích hợp giao diện Luyện nói vào `CanvasPracticeScreen` và `AIRoleplayScreen`**:
   - Trên `_buildLessonInfoCard` của `CanvasPracticeScreen`: cạnh nút loa nghe mẫu (`TtsSpeakerButton`), thêm nút **Luyện phát âm** (`Icons.mic_none_rounded`, nhãn `'Luyện nói'`). Khi bấm vào, thu âm giọng đọc và hiển thị thẻ kết quả `PronunciationResult` ngay dưới thẻ thông tin bài học.
   - Trên thanh nhập tin nhắn của `AIRoleplayScreen` (`_buildInteractiveChatTab` dòng `451–496`): thêm nút Microphone cạnh ô `TextField` để người học có thể nói trực tiếp câu trả lời tiếng Nhật/tiếng Anh vào khung chat đối thoại với AI.

## 4. Đặc Tả Chi Tiết Giai Đoạn 4: Tối Ưu Hạ Tầng Kỹ Thuật & Đồng Bộ Đa Thiết Bị

### Hạng mục G4-T1: Loại Bỏ Khóa Toàn Cục PostgreSQL & Nâng Cấp Con Trỏ `sync_seq`

**Nguyên nhân gốc rễ**:
Tại `server/src/routes/sync.rs` (dòng `65` và `353`) và `server/src/routes.rs` (dòng `125`), mọi giao dịch ghi và kéo dữ liệu đều gọi `SELECT pg_advisory_xact_lock(0, 1)`. Khóa toàn cục này buộc tất cả người dùng và thiết bị phải xếp hàng tuần tự.

**Các bước sửa mã nguồn**:
1. **Tạo migration `server/migrations/20261001000003_gen3_sync_and_accounts.sql`**:
   ```sql
   -- 1. Bảng quản lý tài khoản và thiết bị
   CREATE TABLE IF NOT EXISTS user_accounts (
       user_id VARCHAR(64) PRIMARY KEY,
       username VARCHAR(64) UNIQUE NOT NULL,
       display_name TEXT NOT NULL DEFAULT '',
       pin_hash VARCHAR(128) NOT NULL,
       sync_token VARCHAR(128) UNIQUE NOT NULL,
       created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
   );

   INSERT INTO user_accounts (user_id, username, display_name, pin_hash, sync_token)
   VALUES ('default_user', 'default', 'Default Learner', 'none', 'token_default_user')
   ON CONFLICT (user_id) DO NOTHING;

   CREATE TABLE IF NOT EXISTS user_devices (
       device_id VARCHAR(64) PRIMARY KEY,
       user_id VARCHAR(64) NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
       device_name TEXT NOT NULL DEFAULT 'Lingua Client',
       platform VARCHAR(32) NOT NULL DEFAULT 'unknown',
       last_sync_seq BIGINT NOT NULL DEFAULT 0,
       last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
   );

   -- 2. Sequence tuần tự toàn cục cho đồng bộ delta không cần khóa bảng
   CREATE SEQUENCE IF NOT EXISTS sync_change_seq START WITH 1 INCREMENT BY 1;

   ALTER TABLE lessons
       ADD COLUMN IF NOT EXISTS sync_seq BIGINT NOT NULL DEFAULT nextval('sync_change_seq');

   ALTER TABLE fsrs_cards
       ADD COLUMN IF NOT EXISTS user_id VARCHAR(64) NOT NULL DEFAULT 'default_user',
       ADD COLUMN IF NOT EXISTS sync_seq BIGINT NOT NULL DEFAULT nextval('sync_change_seq');

   ALTER TABLE review_logs
       ADD COLUMN IF NOT EXISTS user_id VARCHAR(64) NOT NULL DEFAULT 'default_user',
       ADD COLUMN IF NOT EXISTS sync_seq BIGINT NOT NULL DEFAULT nextval('sync_change_seq');

   ALTER TABLE completed_lessons
       ADD COLUMN IF NOT EXISTS user_id VARCHAR(64) NOT NULL DEFAULT 'default_user',
       ADD COLUMN IF NOT EXISTS sync_seq BIGINT NOT NULL DEFAULT nextval('sync_change_seq');

   CREATE INDEX IF NOT EXISTS idx_fsrs_cards_user_seq ON fsrs_cards(user_id, sync_seq);
   CREATE INDEX IF NOT EXISTS idx_lessons_sync_seq ON lessons(sync_seq);
   ```
2. **Loại bỏ `pg_advisory_xact_lock(0, 1)` trong `server/src/routes.rs` và `server/src/routes/sync.rs`**:
   - Xóa dòng gọi `SELECT pg_advisory_xact_lock(0, 1)` ở cả 3 vị trí (`routes.rs:125`, `routes/sync.rs:65`, `routes/sync.rs:353`).
   - Giữ lại khóa mịn theo `review_id` (`pg_advisory_xact_lock(1, hashtext($1))`) và khóa mịn theo tổ hợp `user_id + item_id` (`pg_advisory_xact_lock(2, hashtext($1))`) khi cập nhật từng thẻ để chống race-condition trên cùng một thẻ mà không chặn các thẻ hoặc người dùng khác.
   - Khi `INSERT ... ON CONFLICT (item_id) DO UPDATE` trên bảng `fsrs_cards`, cập nhật `sync_seq = nextval('sync_change_seq')` và `updated_at = clock_timestamp()`.
   - Trong `GET /api/v1/sync/pull`:
     - Hỗ trợ thêm tham số truy vấn tùy chọn `since_seq: Option<i64>` bên cạnh `since: Option<DateTime<Utc>>`.
     - Trả về thêm trường `latest_sync_seq: i64` trong `SyncPullResponse` và `SyncPushResponse` (giữ nguyên toàn bộ các trường JSON hiện có để không ảnh hưởng tới E2E tests).

### Hạng mục G4-T2: Tích Hợp Redis Cache & Rate-Limiting Không Cần Crate Ngoài (`server/src/redis_cache.rs`)

**Thiết kế kiến trúc**:
Để tận dụng container `lingua-redis` (`REDIS_URL=redis://redis:6379` đã có trong `docker-compose.yml` và `.env*`) mà không làm thay đổi `Cargo.lock`, xây dựng module `server/src/redis_cache.rs` giao tiếp trực tiếp bằng giao thức chuẩn **RESP2 (Redis Serialization Protocol)** qua `tokio::net::TcpStream`, kết hợp bộ nhớ đệm dự phòng trong RAM (`Arc<RwLock<HashMap<String, CacheEntry>>>`) khi chạy không có Redis.

**Các bước triển khai**:
1. **Tạo tệp `server/src/redis_cache.rs`**:
   - Phân tích biến môi trường `REDIS_URL` (ví dụ `redis://127.0.0.1:6379` hoặc `redis://redis:6379`) để lấy `host:port`.
   - Cài đặt các hàm bất đồng bộ với timeout kết nối `300ms`:
     - `pub async fn get(&self, key: &str) -> Option<String>`: gửi lệnh RESP2 `*2\r\n$3\r\nGET\r\n$<len>\r\n<key>\r\n` qua `TcpStream` (nếu kết nối thành công) hoặc đọc từ `memory_fallback` (kiểm tra hạn `expires_at`).
     - `pub async fn set_ex(&self, key: &str, value: &str, ttl_secs: u64)`: gửi lệnh `SETEX` tới Redis và đồng thời lưu vào `memory_fallback`.
     - `pub async fn check_rate_limit(&self, client_key: &str, max_requests: u32, window_secs: u64) -> bool`: đếm số lượng request theo cửa sổ thời gian bằng lệnh `INCR` + `EXPIRE` (hoặc bộ đếm in-memory).
     - `pub async fn ping(&self) -> bool`: gửi `*1\r\n$4\r\nPING\r\n` và kiểm tra phản hồi `+PONG`.
2. **Tích hợp vào `AppState` và các route AI (`server/src/routes.rs`)**:
   - Thêm `pub cache: Arc<RedisCache>` vào `AppState`.
   - Trong `POST /api/v1/ai/dialogue` (`generate_dialogue`) và `POST /api/v1/ai/roleplay` (`roleplay_chat`):
     - Tạo khóa cache chuẩn hóa từ request:
       - Với dialogue: `format!("ai:dlg:{}:{}:{}:{}:{}", lang, prof, level, topic, turns)`
       - Với roleplay: `format!("ai:rp:{}:{}:{}:{}:{}", lang, prof, level, topic, user_msg_hash)`
     - Nếu tìm thấy bản ghi hợp lệ trong `state.cache.get(&cache_key).await`, giải tuần tự hóa và trả về ngay với HTTP header `X-Cache: HIT`.
     - Nếu chưa có (`MISS`), gọi `state.ai.generate_...`, lưu kết quả vào `state.cache.set_ex(&cache_key, &json_str, 3600).await`, và trả về kèm HTTP header `X-Cache: MISS`.
   - Trong `GET /api/v1/health`: giữ nguyên các trường `"status": "healthy"`, `"service": "lingua_canvas_server"`, `"version": "0.1.0"` và có thể bổ sung trường thông tin trạng thái kết nối DB/Cache mà không phá vỡ kiểm thử schema.

### Hạng mục G4-T3: Quản Lý Tài Khoản & Đồng Bộ Đa Thiết Bị (Android ↔ Linux Desktop)

1. **Tạo module xác thực & quản lý thiết bị `server/src/routes/auth.rs` (đăng ký trong `server/src/lib.rs`)**:
   - `POST /api/v1/auth/register`:
     - Input: `{ "username": "string", "display_name": "string", "pin": "string", "device_id": "string", "platform": "android" | "linux" }`
     - Kiểm tra `username` hợp lệ (3–32 ký tự) và `pin` (4–12 ký tự). Băm mã PIN bằng thuật toán băm nội bộ kết hợp salt, sinh `user_id` (`usr_<hex>`) và `sync_token` (`lct_<hex>`).
     - Lưu vào bảng `user_accounts` và `user_devices` (hoặc bộ nhớ in-memory khi chạy không có DB).
     - Output (HTTP 200/201): `{ "user_id": "...", "username": "...", "display_name": "...", "sync_token": "...", "devices": [...] }`.
   - `POST /api/v1/auth/login`:
     - Input: hỗ trợ đăng nhập bằng `{ "username": "...", "pin": "...", "device_id": "...", "platform": "..." }` HOẶC `{ "sync_token": "...", "device_id": "...", "platform": "..." }`.
     - Liên kết `device_id` mới vào `user_id` tương ứng và trả về thông tin tài khoản + danh sách thiết bị đã liên kết.
   - `GET /api/v1/auth/devices`:
     - Nhận `sync_token` qua query `?sync_token=...` hoặc header `Authorization: Bearer <sync_token>` / `X-Sync-Token`, trả về danh sách các thiết bị đang liên kết với tài khoản.
2. **Hỗ trợ định danh tài khoản trong `SyncCoordinator` (`app/lib/services/sync_coordinator.dart` & `local_database.dart`)**:
   - Lưu trữ `user_id`, `username`, và `sync_token` trong bảng `local_sync_metadata` của SQLite (`LocalDatabase`).
   - Khi thực hiện `POST /api/v1/sync` và `GET /api/v1/sync/pull`:
     - Gửi kèm `user_id` và `since_seq` (nếu có), đồng thời đính kèm header `X-Sync-Token: <sync_token>`.
     - Lưu lại `latest_sync_seq` do server trả về vào `local_sync_metadata`.
3. **Bổ sung giao diện Quản lý Tài khoản Đa thiết bị trên `SettingsScreen` (`app/lib/screens/settings_screen.dart`)**:
   - Thêm thẻ **"Tài Khoản & Đồng Bộ Đa Thiết Bị (Android ↔ Linux)"** ngay dưới phần Cấu hình Máy chủ:
     - Khi chưa đăng nhập: hiển thị trạng thái *"Đang dùng hồ sơ cục bộ (Chưa liên kết tài khoản)"*, kèm 2 nút **"Tạo Tài Khoản Đồng Bộ"** (nhập Username + PIN 4 số) và **"Liên Kết Thiết Bị Đã Có"** (nhập Username + PIN hoặc dán `Sync Token`).
     - Khi đã đăng nhập: hiển thị `Username`, `User ID`, nút sao chép `Sync Token`, danh sách các thiết bị đã liên kết (`Android`, `Linux Desktop` kèm thời점 đồng bộ cuối), và nút **"Đăng xuất hồ sơ"**.

## 5. Kế Hoạch Kiểm Thử Tự Động & Cổng Nghiệm Thu (Verification Gates)

AI Agent bắt buộc phải viết bổ sung các bài kiểm thử tự động cho toàn bộ tính năng của Giai đoạn 3 & 4 trước khi chạy cổng nghiệm thu tổng thể:

### 5.1. Kiểm thử Backend Rust cần bổ sung (`server/tests/` hoặc unit tests trong `server/src/`)
1. **Unit Tests cho `redis_cache.rs`**:
   - Kiểm thử lưu/đọc TTL cache, kiểm thử hết hạn TTL, kiểm thử `check_rate_limit` chặn khi vượt ngưỡng, và kiểm thử tự động fallback sang RAM khi cổng Redis không phản hồi.
2. **Integration Tests cho `/api/v1/auth/*` và Đa thiết bị Sync**:
   - Đăng ký tài khoản trên Thiết bị A (`android`), đẩy (push) 2 lượt ôn tập FSRS.
   - Đăng nhập cùng tài khoản trên Thiết bị B (`linux`), kéo (pull) dữ liệu về bằng `since_seq = 0`, xác nhận Thiết bị B nhận đủ 2 thẻ FSRS với đúng trạng thái `stability` và `reps`.
3. **Test Cache Header trên AI Endpoints**:
   - Gọi `POST /api/v1/ai/dialogue` 2 lần liên tiếp với cùng tham số: xác nhận lần 1 trả về `X-Cache: MISS` và lần 2 trả về `X-Cache: HIT` với nội dung JSON đồng nhất.

### 5.2. Kiểm thử Frontend Flutter cần bổ sung (`app/test/`)
1. **Unit & Widget Tests cho `StrokeGuideService` & Hoạt ảnh Nét vẽ**:
   - Xác nhận `StrokeGuideService` trả về đúng số lượng `StrokeGuidePath` cho cả chữ Kanji có sẵn (`日`, `本`, `開`) và từ vựng bất kỳ qua cơ chế sinh tự động từ `strokeOrderHints`.
   - Kiểm thử bấm nút **"Xem nét mẫu"** trên `CanvasPracticeScreen` kích hoạt trạng thái hoạt ảnh trên `HandwritingCanvas`.
2. **Unit & Widget Tests cho `SpeechPracticeService` (Luyện nói phát âm)**:
   - Sử dụng `MockSpeechPracticeEngine` trả về transcript khớp (`"かいはつ"`) và lệch (`"かいこく"`) cho bài học `"開発"`, xác nhận `PronunciationResult` tính điểm chính xác và hiển thị phản hồi trên UI.
3. **Widget Test cho Quản lý Tài khoản trên `SettingsScreen`**:
   - Kiểm thử hiển thị thẻ *"Tài Khoản & Đồng Bộ Đa Thiết Bị"*, nhập thông tin đăng ký/đăng nhập giả lập và xác nhận `sync_token` được lưu vào `LocalDatabase`.

### 5.3. Chuỗi lệnh nghiệm thu bắt buộc (Exit Code = 0 cho mọi bước)

```bash
# 1. Kiểm tra định dạng, Clippy, Unit/Integration Tests và Security Audit của Backend Rust
cd server
cargo fmt -- --check
cargo check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
cargo audit

# 2. Kiểm tra định dạng, phân tích tĩnh và toàn bộ Unit/Widget Tests của Flutter
cd ../app
../.toolchains/flutter/3.47.6/flutter/bin/dart format --output=none --set-exit-if-changed .
../tools/flutter analyze
../tools/flutter test

# 3. Kiểm tra cấu hình Docker Compose và chạy toàn bộ 4 tầng E2E + Adversarial Suite
cd ..
docker compose config -q
python3 -B -m unittest discover -s tests/e2e -p 'test_*.py' -v

AI_ENDPOINT=http://127.0.0.1:9/v1/chat/completions \
AI_FALLBACK_ENABLED=true \
./tests/e2e/run_e2e_tests.sh --all

ADVERSARIAL_PORT_OFFSET=10000 python3 -B tests/adversarial_suite.py

# 4. Cập nhật chỉ mục và kiểm tra đồ thị mã nguồn GitNexus
node .gitnexus/run.cjs analyze --index-only
node .gitnexus/run.cjs detect-changes --scope all --repo .
```

### 5.4. Cập nhật tài liệu sau khi hoàn tất
- Cập nhật danh sách tính năng Gen 3 (M5: Learning UX Expansion, M6: Infrastructure & Multi-Device Sync) cùng số lượng bài kiểm thử mới vào `PROJECT.md`, `README.md`, `TEST_READY.md` và `TEST_INFRA.md`.
- Đảm bảo `git status` không còn tệp tạm trước khi kết thúc phiên làm việc.
