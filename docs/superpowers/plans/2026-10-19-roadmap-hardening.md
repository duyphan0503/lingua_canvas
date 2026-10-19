# Lingua Canvas next roadmap implementation

> **For agentic workers:** Use Superpowers executing-plans task by task; independent repairs may use dispatching-parallel-agents. The user has requested execution of the attached roadmap.

**Goal:** Execute the four-stage roadmap from `ke_hoach_phat_trien_lingua_canvas.pdf`, starting with security and sync correctness.

**Architecture:** Preserve Flutter 3.47.6/Dart 3.13.5, Rust Axum, FSRS, profile-isolated LocalStore and additive sync compatibility. Implement and verify each independent subsystem before integration. Keep Android, Linux and Web; exclude native Apple platforms while allowing browser compatibility improvements on iPhone/iPad.

**Source:** User PDF dated 2026-10-18, six pages, and the user's explicit iOS exclusion. Its audit claims are hypotheses to verify against current source, not evidence of present test results.

## Global constraints

- Work from updated `origin/develop` on `codex/roadmap-hardening`, in the existing checkout as previously requested.
- Do not merge, deploy production, erase user data, automatically transfer guest profiles, or fabricate hardware/latency/learning-retention results.
- Preserve account isolation, pending review queues, private metadata CAS/ACK receipts, FSRS behavior and existing public lesson IDs.
- GitNexus impact before code edits; full detect-changes before commits. MCP has incompatible graph storage versions; compatible CLI plus source corroboration is the fallback.

## Stage 1: stabilization and security

### Task 1: authentication lifecycle
- [x] RED/GREEN: test and implement register/token-login socket rate limits, spoofed forwarding headers, separate device tokens, expiry, revocation isolation, rotation and PIN reauthentication.
- [x] Implement hashed, expiring device sessions and bounded legacy-token transition in `server/src/routes/auth.rs`, `pin.rs`, migration `20261019000005_auth_sessions.sql`; register new routes in `lib.rs`.
- [x] Initialize session store in AppState constructors; production entry point supplies socket ConnectInfo.
- [x] GREEN: auth security and all-target Rust tests pass. Live PostgreSQL cases remain separately marked when a disposable DB is required.

### Task 2: Redis reuse
- [x] RED/GREEN: fake RESP server proves sequential reuse, concurrent request isolation, cancellation/timeout eviction, reconnect and no ambiguous mutation retry.
- [x] Replace per-command sockets in `server/src/redis_cache.rs` with bounded persistent connection access, retaining the 300 ms complete-operation deadline and existing memory limits.
- [x] GREEN: focused socket tests and all-target Rust suite pass when loopback sockets are permitted.

### Task 3: review batches and public catalog delta
- [x] RED/GREEN: unchanged catalog suppression, independent `catalog_version`, legacy pulls, SQL rollback and lock ordering tests.
- [x] Add transactional public-catalog revision tracking in migration `20261019000006_catalog_version.sql`. Pull holds a shared catalog revision barrier until its matching catalog snapshot is read.
- [x] Extend `SyncPullQuery`/`SyncPullResponse` with optional-request/required-response `catalog_version`. Client persists the version only after successful reconciliation in profile/backend-scoped metadata.
- [x] Execute reviews in one PostgreSQL transaction with deterministic advisory-lock ordering, retaining review-id idempotence and imported progress baselines.
- [x] GREEN: Rust memory tests and Flutter catalog tests pass; DB-only rollback coverage is available through the disposable-Postgres runner.

### Task 4: Canvas refresh
- [x] RED/GREEN: private-only, card-only, completion-only and deleted selected lesson refresh regressions.
- [x] Refresh local Canvas data on successful sync even without public lessons in `canvas_practice_screen.dart`.
- [x] GREEN: canvas regressions and full Flutter VM suite pass.

### Task 5: native credential vault and account controls
- [x] RED/GREEN: vault migration, failed vault write, inactive profiles, backend switching, logout/revocation/rotation, PIN validation and UI behavior.
- [x] Add `flutter_secure_storage` behind a small injectable token-vault contract for Android Keystore/Linux Secret Service. Keep account identity/preferences in LocalStore, migrate tokens before deleting plaintext references. Preserve rollback and fail closed when a required vault cannot be opened.
- [x] Wire revoke/rotate/change-PIN controls to AccountService and account settings, scoped to the current backend/profile. Browser storage capabilities are represented honestly; no claim that JS-accessible storage resists XSS.
- [x] GREEN: storage/service/widget tests and Android/browser checks pass. Linux release build also passes with the pinned workspace sysroot and the host's installed GStreamer runtime libraries.

### Task 6: real-device QA
- [ ] Real-device Android, microphone/playback and provider QA remains pending; no attached physical device or configured provider was available. Mocks are not reported as hardware evidence.
- [x] Run the available disposable-database integration suite; actual physical-device scenarios remain listed in DEVICE_VALIDATION.md.

## Stage 2: learning core
- [x] Vendor licensed canonical KanjiVG paths for covered public Japanese words/kana with provenance and deterministic asset validation; no fabricated SVG guides.
- [x] Correct compound-word stroke counts and start/end-direction scoring, with unknown coverage explicitly handled.
- [x] Add optional active recall/cloze mode preserving the current default and FSRS review semantics.
- [x] Expand structured curriculum to 355 stable IDs with Japanese/English workplace contexts, translations and quality/coverage tests while preserving the original 155.

## Stage 3: AI and speech
- [x] Add bounded recent conversation turns and tested SSE transport, cancellation/drop handling, fallback paths and safe rendering. Upstream AI generation is currently buffered before SSE frames are emitted; it is not provider-token streaming.
- [x] Include account-scoped due vocabulary in roleplay prompts without leaking private words between accounts.
- [x] Add local recording/replay beside TTS; distinguish transcript accuracy from acoustic diagnosis. Hardware QA remains pending.
- [x] Add verified Japanese pitch-accent metadata/contours from the pinned Kanjium CC BY-SA 4.0 source, exact reading matching, explicit unknown handling and transcript word mismatch feedback.

## Stage 4: browser offline and operations
- [x] Versioned app-shell caching with controlled updates and cold-start-offline Chromium tests; bounded KanjiVG shell asset.
- [x] Evaluate licensed browser handwriting candidates; no model meeting size, license and verified Japanese vector-stroke coverage criteria was found. The UI retains its explicit geometric-assessment label. See `docs/browser-handwriting-recognition-evaluation.md`.
- [x] Add bounded-cardinality Prometheus metrics for cache/AI outcomes and HTTP routes, private endpoint policy and tests.
- [x] Add reviewable production Compose + TLS reverse-proxy configuration and operational documentation. No deployment performed.
- [x] Automated responsive tests cover phone-to-desktop widths. Physical iOS Safari/device validation remains pending; no native Apple build was added.

## Review focus

1. Legacy credentials cannot remain a back door after revocation/PIN change.
2. Reordered concurrent SQL batches cannot deadlock by inconsistent lock acquisition or partially advance FSRS.
3. Catalog revisions cannot skip a public lesson that commits after a private/account cursor advances.
4. Vault failures cannot silently log out an inactive profile or destroy pending local data.
5. Offline shell/model updates cannot erase profiles, expose credentials in caches, or execute mismatched app assets.

## Execution record

- Base: `68142a6` (`origin/develop`, PR #5 integrated). The attached PDF is user-owned and left untracked.
- Ruling: execution follows the PDF's stage order; native iOS/iPadOS/macOS work is excluded by user request. iOS browser behavior remains in the Web scope.
- Initial environment: GitHub CLI API authentication returned 401 while git fetch succeeded; this does not block local implementation. ADB daemon was denied by sandbox; real device status needs an approved read outside sandbox. No `ollama` executable found.
- Verification: Flutter 3.47.6/Dart 3.13.5 full suite **328 passed, 1 skipped**; analyzer clean. Web release, Android debug APK, and Linux release builds succeeded. Chromium cold-start offline test passed. Rust all-target suite passed; its 2 disposable-DB cases are explicitly ignored in that command and both were exercised by `tests/private_vocabulary/run_live_tests.sh`, along with actual SQLite→HTTP→PostgreSQL→SQLite and IndexedDB→HTTP→PostgreSQL→second-browser-device flows.
- Fresh `cargo audit` reports RustSec `RUSTSEC-2023-0071` on locked `rsa 0.9.10`, with no fixed version. `cargo tree --target all -i rsa` returns no active dependency path; it is included through SQLx's optional, unused MySQL driver. `rustls` is locked to patched `0.23.46`; no audit exception was added. Keep this documented as the sole audit finding until upstream removes or fixes it.
- Hardware microphone/playback/provider validation and physical iOS Safari checks remain pending; no native Apple build or deployment was performed.
