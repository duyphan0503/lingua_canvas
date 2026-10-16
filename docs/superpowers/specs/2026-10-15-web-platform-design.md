# Lingua Canvas Web — design for review

Date: 2026-10-15 (Asia/Ho_Chi_Minh).
Branch: `codex/web-platform`, based on `0c72beb` (Phase 3–4).
Status: scope confirmed; detailed design awaiting user review. Product implementation has not started.

## User intent and success

The user selected browser learning with all five existing screens and progress synchronized with Android/Linux. This is an additional target of the existing learning application: Canvas, AI Roleplay, Curriculum, Analytics and Settings.

Proposed defaults: reuse the existing dark theme, 155 lessons, FSRS rules, account/token model and Rust API. Preserve Android/Linux behavior. Support recent desktop Chrome/Edge first, plus responsive browser layouts; other browsers retain core learning and explicit capability fallbacks. Storage persists across reloads on the same origin/browser profile. Offline reviews work after the app has loaded and synchronize on a later explicit sync. An installable PWA and guaranteed cold-start offline loading are separate work, outside this first release.

## Approach and alternatives

1. **Selected: shared Flutter Web with platform adapters.** Keep screens, models, FSRS and sync rules shared. Isolate native SQLite/FFI/ML Kit from the browser compilation graph, and add browser storage/speech implementations. This minimizes duplicate product logic; storage and browser lifecycle need real integration tests.
2. Separate HTML/JavaScript frontend: offers independent web presentation but duplicates learning, queue and profile behavior. Rejected for this release.
3. Online-only shared Flutter Web: simpler storage, but loses offline review and reload durability. Rejected because the browser target should preserve these existing learning capabilities.

Prefer the pinned Flutter/Dart SDK and existing dependencies. Browser integration uses supported Dart JS interop; do not add dependencies or change lockfiles for this design. Do not emulate arbitrary SQL in JavaScript or bundle a new SQLite/Wasm runtime.

## Architecture

Shared UI → platform-neutral local-store contract → native SQLite or browser IndexedDB.
Shared UI → existing API/sync coordinator → existing Rust/PostgreSQL account APIs.
Speech/TTS and handwriting expose platform capabilities through the existing service interfaces.

Extract shared storage models from native imports. Keep the `LocalDatabase` public domain operations usable by existing callers while selecting a native/browser implementation with conditional imports/exports. Native-only database testing hooks remain available to native tests; browser production code must not import FFI, access `Platform.environment`, or depend on a SQL handle. Avoid unrelated API/service refactoring.

Use a small browser interop boundary for IndexedDB, capability checks and SpeechRecognition. Pure Dart storage rules remain testable without a browser. Keep schema/serialization, browser event handling and UI responsibilities separate.

## Browser persistence and account safety

Use versioned IndexedDB object stores for app metadata and profile state. Profile keys incorporate backend URL and user ID; the local legacy profile is also separated by backend URL on web. Persist lessons/custom lesson metadata, FSRS cards, review logs, queue state/IDs, completed lessons, daily activity and sync cursors. Keep a stable browser installation ID outside account profiles, and identify devices as `web` / `Web Browser` in account registration and display.

A review's card, review log, completion, activity and queued mutation must commit atomically. A failed transaction must not acknowledge a durable review. Reset and profile switches must not lose another profile's pending queue or reconcile a delayed response into a different profile. Preserve pending-local/LWW rules and advance a sequence cursor only after the associated pull data has been committed.

For the initial browser release, only one tab per origin may mutate learning/profile state. Use an origin-scoped Web Lock for the active writer session, acquired without waiting. A second tab displays a recoverable “another tab is active” state and can retry after the first tab closes/releases the lock; it must not initialize a second writable session or silently overwrite state. This is a deliberate first-release restriction rather than multi-tab merge logic. If the browser lacks the required durable storage or lock capability, show an actionable unsupported-storage state and retry; do not silently fall back to memory while claiming saved progress.

IndexedDB transaction success means transaction completion, not individual request success. Surface quota, blocked upgrade, denied/private storage and corrupt-version errors. Close a database on version-change events so another tab can upgrade. Browser storage eviction or clearing site data can remove unsynchronized progress; explain this in Settings storage help. Never store a PIN, log a token or place credentials in URLs.

## Five screens and browser behavior

| Screen | First web release |
| --- | --- |
| Canvas | Existing handwriting, undo/clear/grid, lesson selection and animated stroke guides; mouse, pen and touch; browser-available TTS and speech practice |
| AI Roleplay | Existing dialogue/chat, profession/level, vocabulary-to-canvas and dictation where available; existing offline AI fallback |
| Curriculum | All 155 lessons, filters, custom local words, TTS and navigation to practice |
| Analytics | Local account progress, streak, due cards, pending queue and explicit synchronization |
| Settings | Backend configuration, account creation/link/logout, token copy, devices, storage/capability status and reset |

Use a navigation rail on wide layouts and the existing bottom navigation on narrow layouts. Preserve readable content widths and scrolling; verify 390px, 768px and 1440px viewports, including short desktop windows. Keyboard focus, text entry, copy and navigation must work in the browser. Retain the same five flows; do not add marketing pages or an administration portal.

## Handwriting and audio capabilities

Browser Canvas uses the existing local heuristic recognizer; label feedback as geometric practice assessment, not ML Kit or accurate character OCR. Hide native model download controls on web and replace them with a capability explanation. Keep illustrative stroke-guide labels. Real browser handwriting OCR is outside this release.

Reuse the web implementation of the existing `flutter_tts` dependency when voices are available; expose missing-voice/unsupported states. Add a browser `SpeechPracticeEngine` using `SpeechRecognition` or its supported prefixed form, feature-detected at runtime. Only start after an explicit user action. Use ja-JP/en-US, final transcript scoring and the existing recognized-text similarity rule. Stop/abort on tab change, language/lesson change, account change, disposal and cancellation; reject late events by session ID/epoch. Bound pending recognition and handle permission denied, no speech, audio errors and unavailable API.

When recognition is unsupported or denied, offer the existing explicitly labeled typed transcript comparison. Browser recognition can use the browser vendor's network service; do not claim on-device/offline speech recognition or send audio to the Lingua Canvas backend. Microphone availability and voice quality depend on browser/OS capabilities.

## Backend and delivery

Keep the current API contracts and default-user compatibility. The auth backend already accepts platform strings; verify web device registration/link/list rather than introduce another account system. Preserve strict token identity assertions and private custom-word catalog exclusion.

On web, use `API_BASE_URL` as an optional compile-time override; otherwise derive `/api/v1` from the app's origin. Settings can configure a server explicitly. Reject unusable URLs and explain HTTPS mixed-content failures. Keep token scope bound to the selected backend and redirects disabled; the installed http 1.6.0 browser client maps this to Fetch redirect=error.

Provide a static web hosting configuration with a same-origin `/api/v1` reverse proxy, plus local development instructions. Cross-origin development must support preflight for Content-Type/X-Sync-Token and expose X-Cache if used by browser diagnostics. Do not broaden authentication or move tokens into query parameters to bypass CORS. Retain the existing server API architecture.

Add Flutter web bootstrap/index/manifest and local build instructions. Host generated assets from the configured static deployment; configure Flutter build to avoid runtime CanvasKit CDN dependencies. Add `flutter build web --release` and browser tests to CI without removing Android/Linux checks. Producing build/hosting configuration is in scope; deploying publicly or changing DNS is outside this release.

## Verification and acceptance

1. Existing native Flutter/Rust tests, formatting and analysis remain green; no dependency/lockfile changes.
2. Release web build succeeds with the pinned SDK. The web import graph excludes native SQLite/FFI and unsafe dart:io usage.
3. Shared storage contract tests exercise native and browser implementations: seeding/filtering, custom words, atomic review transaction, queue retry/recovery, completion LWW, activity, profile switch/reset and cursors.
4. Real Chromium tests verify IndexedDB save/reload, offline review after load, reconnect sync, two accounts, a browser device sharing progress with another client, denied storage, transaction failure and writer-tab locking/recovery.
5. Browser UI checks cover all five screens, mouse/touch Canvas, viewport sizes, navigation, Settings account/token actions, sample animation and fallback labels.
6. Speech tests cover unavailable/permission/error/final transcript, timeout and late events after tab/profile changes. Test browser event integration with deterministic fake recognition; manually verify microphone/TTS where a real browser/OS supports them.
7. A controlled local Rust/PostgreSQL integration verifies browser-auth preflight, two-device FSRS/completion synchronization and no cross-account data disclosure. Existing 47 E2E tests and 59 adversarial tests remain compatible.
8. GitNexus impact analysis before existing-symbol changes, full reindex and non-partial change analysis before commits, whole-branch review, and an execution report stating tested browsers and remaining device checks.

No completion claim is based solely on a successful web compile: persistence, profile isolation and browser execution must be demonstrated.

## References and verified baseline

- Current repo index at `0c72beb`: LocalDatabase is native SQLite/FFI; no app/web exists. AccountService directly reads Platform.isAndroid; native ink is Android-only and speech currently excludes web. Existing flutter_tts and shared_preferences packages include web implementations. Rust already accepts arbitrary bounded device platform strings.
- [Flutter web support](https://docs.flutter.dev/platform-integration/web)
- [Flutter web FAQ and conditional imports](https://docs.flutter.dev/platform-integration/web/faq)
- [Dart JavaScript interoperability](https://dart.dev/interop/js-interop)
- [IndexedDB transactions and origin storage](https://developer.mozilla.org/en-US/docs/Web/API/IndexedDB_API)
- [SpeechRecognition availability and behavior](https://developer.mozilla.org/en-US/docs/Web/API/SpeechRecognition)
- [Web Locks API](https://developer.mozilla.org/en-US/docs/Web/API/Web_Locks_API)
