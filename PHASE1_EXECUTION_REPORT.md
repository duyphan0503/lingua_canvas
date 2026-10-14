# Báo cáo thực thi Lingua Canvas — 2026-10-14

Nhánh: `codex/phase1-learning-expansion`, tách từ `develop` tại `b9c1ea6` theo lựa chọn của người dùng.

Đã hoàn tất T1–T9: canvas tiếng Anh, bộ lọc danh mục, bài luyện viết động từ AI, chọn ngành nghề/cấp độ, sửa AI stub, chính sách audit, 52 bài học mới, form tạo thẻ và lưới/Undo. Reviewer độc lập tìm thấy 5 lỗi Important; tất cả đã có test tái hiện thất bại trước khi sửa và đạt sau sửa.

## Latest verification — 2026-10-14

All nine tasks in `lingua_canvas_phase1_execution_plan.md` are implemented on `codex/phase1-learning-expansion`.

- Flutter 3.47.6 / Dart 3.13.5: **145 unit/widget tests passed**, analyzer clean, repository-wide formatting passed.
- Rust: **41 tests passed**, including opt-in PostgreSQL 16 tests and the seed-upgrade regression; formatting, check and Clippy with warnings denied passed.
- Four E2E tiers: **47/47 passed** against a freshly seeded, disposable PostgreSQL 16 database and an isolated localhost backend. The pinned Flutter SDK was first on PATH.
- Adversarial provider/parser/timeout suite: **59/59 passed**. E2E runner/stub Python unit tests: **5/5 passed**. Docker Compose configuration validated.
- Live Flutter SQLite → Rust HTTP → PostgreSQL review sync → lesson reload passed, preserving custom word, language, meaning and example metadata.
- GitNexus indexing and complete change analysis passed without partial/truncated flags. Aggregate graph risk is HIGH because the shared lesson persistence/loading and canvas lifecycle paths changed; these paths have regression coverage.
- Both catalogs now contain **135 lessons**, including **52 additions**. Existing lesson IDs/content are retained; upgrades insert missing IDs rather than relying on total row counts.
- `cargo audit` exits **0**. `quinn-proto` is patched to **0.11.18**. `server/.cargo/audit.toml` explicitly ignores only `RUSTSEC-2023-0071` for inactive optional `rsa`; `cargo tree --locked --target all -i rsa` confirms no active dependency. Re-evaluate the exception if SQLx features/database support change.

Custom lesson metadata is protected locally against server ID-only placeholders. Full metadata transfer to another device is not added by this plan. The canvas counter still derives suggested strokes from the number of hint paragraphs; explicit expected-stroke metadata is a deferred minor UX improvement.

Native Android ML Kit/download behavior, physical-device handwriting accuracy, Linux desktop launch, and a real Ollama/Llama.cpp deployment remain device/live-provider checks. This verification used controlled local providers; it does not replace those checks.

## Quyết định thực thi

- Ruling: Execute in the current checkout on a new branch — user explicitly selected it — isolation relies on branch rather than worktree.
- Ruling: Use CLI graph analysis — MCP reader storage version 40 cannot open index version 42 — CLI 1.6.12 opens it successfully.
- Task 3: Ruling: Use URI-encoded normalized word for stable IDs instead of replacing whitespace with underscores — avoids collisions between 'pull request' and 'pull_request' — ID format differs from illustrative example.
- Task 3: Ruling: Merge local custom lessons into successful server responses — otherwise newly created words disappear online — local custom cards remain device-local until reviewed/synchronized by existing flow.
- Task 6: Ruling: Current audit reveals five additional quinn-proto advisories requiring >=0.11.18 — update only quinn-proto alongside the verified inactive-rsa exception — lockfile patch exceeds the historical plan but is necessary for the audit gate.
- Ruling: E2E runs use pinned Flutter PATH and a fresh localhost backend on port 18081 — global Flutter rewrites dependency resolution, pre-existing server contains review state — checks remain unchanged and production service is untouched.
- Ruling: Retain formatter changes required by pinned Dart across existing files — repository-wide format gate otherwise fails — formatting-only diff increases review size.
- Final: Ruling: Protect complete local lessons against server language=custom placeholders at SQLite ingestion and prefer retained local custom data in GET results — server sync only carries IDs — metadata is preserved locally but full metadata transfer between devices remains outside this plan.
- Final: Ruling: Seed missing IDs independently of total row count in PostgreSQL and SQLite — custom rows and old caches otherwise hide the new curriculum — startup scans the bounded bundled catalog.
- Final: Ruling: Use Flutter UI theme-platform detection for model controls, keeping native engine host-gated — permits delayed native-flow regression tests without a phone — actual device model download still requires device validation.

## Điểm nhỏ hoãn lại

Bộ đếm nét hiện dùng số đoạn hướng dẫn làm số nét gợi ý; chưa có metadata số nét chuẩn riêng cho từng từ/ký tự.
