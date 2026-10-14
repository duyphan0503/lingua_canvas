# Lingua Canvas Web Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver browser learning across all five existing screens, durable local review queues and account progress shared with Android/Linux.

**Architecture:** Reuse Flutter screens, models, FSRS and Rust APIs. Extract a platform-neutral local-store contract; retain native SQLite and implement a transactional IndexedDB browser store behind conditional exports. Use one writer tab per origin, browser audio adapters and responsive navigation.

**Tech Stack:** Flutter 3.47.6 / Dart 3.13.5; existing http/flutter_tts packages; Dart JS interop, IndexedDB, Web Locks and Web Speech; Rust Axum/PostgreSQL; static hosting with same-origin API proxy.

**Spec:** `docs/superpowers/specs/2026-10-15-web-platform-design.md` (approved by user on 2026-10-15).

## Global Constraints

- Branch `codex/web-platform`, current checkout; do not create another worktree. Base implementation `0c72beb`; design commit `c5600f9`.
- Use `tools/flutter` from root or `../tools/flutter` from app; Flutter 3.47.6 / Dart 3.13.5.
- “Do not add dependencies or change lockfiles for this design.” Use `--no-pub` for checks after confirming the existing package configuration.
- “Preserve Android/Linux behavior.” Native SQLite schema/version 4 and native test hooks remain compatible.
- “Offline reviews work after the app has loaded and synchronize on a later explicit sync.” Cold-start offline/PWA installation is outside this release.
- “Only one tab per origin may mutate learning/profile state.” Unsupported durable storage or locking produces an actionable blocked state, never a silent memory fallback.
- “Never store a PIN, log a token or place credentials in URLs.” Tokens stay backend-scoped; authenticated requests disable redirects.
- “No completion claim is based solely on a successful web compile.” Execute a real browser, persistence and isolation tests.
- Run GitNexus upstream impact before editing existing symbols; report callers/processes/risk. UNKNOWN requires source confirmation; warn on HIGH/CRITICAL. Before every commit, stage new files and run complete detect_changes without partial/truncated flags. The CLI runner works where MCP storage versions differ.
- Use TDD; preserve RED/GREEN evidence and decisions in this plan's Superpowers ledger. Do not commit failing intermediate code or unrelated changes.
- No public deployment, DNS changes or merge. At delivery, preserve prior GitHub push preference and create a reviewed feature PR based on the current Phase 3–4 branch if it remains unmerged.

## Review Focus

1. Storage quota/transaction abort after a successful request callback: UI must not claim a saved review; previous durable state remains. Tests: Tasks 2, 3, 6.
2. Delayed sync/custom-word response while switching account/backend/resetting: old data never enters a new profile; old pending queues survive. Tests: Tasks 2, 4, 7.
3. A second tab opens, closes or retries after writer exit: exactly one writer owns storage; unavailable locks/storage never silently degrade. Tests: Tasks 3, 4, 7.
4. HTTPS frontend with HTTP/redirecting backend, malformed URL or cross-origin preflight: reject unsafe configuration without sending a token or changing profile state. Tests: Tasks 4, 7.
5. Microphone permission denied, unsupported API or late result after leaving a screen: no stuck recorder, stale transcript or fake score. Tests: Tasks 5, 6.

## File map and dependencies

| Unit | Files / responsibility |
| --- | --- |
| Shared storage | `app/lib/services/storage/local_models.dart`, `local_store.dart`: domain types and contract |
| Native storage | `storage/local_database_native.dart`: existing SQLite implementation and test hooks |
| Browser domain storage | `storage/browser_local_store.dart`, `snapshot_persistence.dart`: JSON-safe profile state and atomic changes |
| Browser persistence | `storage/indexed_db_persistence.dart`, `browser_writer_lease.dart`, `local_database_web.dart`: JS boundary, origin lease and facade |
| Facade | `app/lib/services/local_database.dart`: shared exports + conditional native/web selection |
| Platform/bootstrap | `services/platform_capabilities.dart`, `platform_bootstrap.dart`, `platform_bootstrap_native.dart`, `platform_bootstrap_web.dart`; `widgets/platform_bootstrap_gate.dart` |
| Ink | `models/handwriting_stroke.dart`, `services/ink/digital_ink_common.dart`, `digital_ink_native.dart`, `ink_factory_native.dart`, `ink_factory_web.dart`; existing facade/recognizer |
| Speech | `services/speech/speech_types.dart`, `speech_native.dart`, `browser_speech_engine.dart`, `browser_speech_bridge_contract.dart`, `browser_speech_bridge.dart`, `speech_factory_native.dart`, `speech_factory_web.dart` |
| UI | Existing main/shell/Canvas/Roleplay/Settings plus `widgets/web_capability_card.dart` |
| Web assets/hosting | `app/web/index.html`, `flutter_bootstrap.js`, `manifest.json`; `deploy/web/nginx.conf`, `Dockerfile`, `README.md`; `tools/serve_web.py` |
| Tests | `app/test/storage/`, `app/test/web/`, `app/test/services/`, `server/tests/web_platform.rs`, `tests/web/` |

Execution is sequential: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. All tasks share interfaces or validation; concurrent ownership is unnecessary. Each task has its own RED/GREEN cycle and commit. Task 4 is the first browser application build; before it, browser storage tests are independently executable.

## Task 1: Isolate native storage and establish the local-store contract

**Files:** Create `app/lib/services/storage/local_models.dart`, `local_store.dart`, `local_database_native.dart`; modify `local_database.dart`, `api_service.dart`, `sync_coordinator.dart`; test `app/test/storage/native_store_contract_test.dart`.

**Interfaces:** Consume current LocalDatabase domain methods. Produce `abstract interface class LocalStore` with the exact contract in Appendix A; `LocalDatabase implements LocalStore` in the native implementation. `ApiService` constructor's `localDb`, its getter, and `SyncCoordinator.localDb` accept `LocalStore`; default remains `LocalDatabase.instance`. SQL handles and static FFI/testing hooks stay native-only and outside the contract.

- [ ] Obtain impact for LocalDatabase, ApiService and SyncCoordinator before extraction; confirm graph UNKNOWN test hooks with source. Read existing storage/profile/sync tests.
- [ ] Write the native contract test first:

```dart
final LocalStore store = LocalDatabase.instance;
await LocalDatabase.instance.initCustom(customPath: inMemoryDatabasePath);
final lesson = phase3Lessons.first;
await store.saveLesson(lesson);
expect((await store.getLesson(lesson.id))!.toJson(), lesson.toJson());
await store.setSyncSequence(7);
expect(await store.getSyncSequence(), 7);
await store.clearCurrentProfile();
expect(await store.getLessons(), isEmpty);
expect(await store.getSyncSequence(), isNull);
```

Imports: flutter_test, sqflite_common_ffi, local_database, storage/local_store and phase3_lessons. Initialize FFI in setUp and close in tearDown. Add account/snapshot preservation to clearCurrentProfile tests: preserve account/client ID and an inactive account's queue; existing clearAll still deletes everything as before.

- [ ] Run `cd app && ../tools/flutter --no-version-check test --no-pub test/storage/native_store_contract_test.dart`; expect RED: contract/clearCurrentProfile missing.
- [ ] Move LocalReviewLog, SyncQueueItem, LocalCompletedLesson and StudyStreak unchanged to local_models. Move the SQLite implementation to storage/local_database_native, adjusting relative imports; do not rename symbols. Keep the facade:

```dart
export 'storage/local_models.dart';
export 'storage/local_database_native.dart';
```

Add contract implementation and `initialize() => database.then((_) {})`. Native `selectBackend(String)` is a no-op preserving existing native routing; browser semantics are introduced in Task 2. Native clearCurrentProfile runs under withProfileLock, deletes the six active learning tables and last_pull_time/latest_sync_seq in one SQLite transaction, preserving account/client_id and inactive snapshots. Keep clearAll unchanged.

- [ ] Change shared consumers to LocalStore, retaining the facade's StudyStreak export. Run native contract plus existing service/profile/sync tests, then full native suite. Expected GREEN: original 194 tests plus new tests; record actual count rather than hard-coding a future total.
- [ ] Stage only Task 1, complete graph change check and commit `refactor: isolate native storage behind local store contract`.

## Task 2: Implement atomic browser profile and review storage in pure Dart

**Files:** Create `storage/snapshot_persistence.dart`, `browser_local_store.dart`; test `app/test/storage/browser_local_store_test.dart`, `app/test/helpers/memory_snapshot_persistence.dart`.

**Interfaces:** `BrowserLocalStore implements LocalStore`, constructor `BrowserLocalStore({required SnapshotPersistence persistence, String initialBackend = 'http://127.0.0.1:8080/api/v1'})`. Persistence contract (also define the platform-neutral BrowserStorageException(code,message) here so VM tests can import it):

```dart
class BrowserStorageException implements Exception {
  final String code;
  final String message;
  const BrowserStorageException(this.code, this.message);
  @override String toString() => message;
}

abstract interface class SnapshotPersistence {
  Future<Map<String, dynamic>?> load();
  Future<void> save(Map<String, dynamic> snapshot);
  Future<void> close();
}
```

MemorySnapshotPersistence implements that contract with deep JSON copies and an injectable `Object? nextSaveError`; fail the next save before replacing stored state. This is a test helper, never a production fallback.

- [ ] Write tests for save/reopen, atomic review rollback and profile/backend isolation before implementation:

```dart
final disk = MemorySnapshotPersistence();
final store = BrowserLocalStore(persistence: disk);
await store.initialize();
final card = FSRSEngine().review(
  FSRSCard.initial('ja_n4_kaigi'), FSRSRating.good, DateTime.utc(2026, 10, 15));
disk.nextSaveError = StateError('quota exceeded');
await expectLater(store.recordReviewTransaction(
  updatedCard: card, rating: FSRSRating.good,
  reviewTime: DateTime.utc(2026, 10, 15), elapsedDays: 0, scheduledDays: 3),
  throwsStateError);
expect(await store.getCard(card.itemId), isNull);
expect(await store.getPendingMutations(), isEmpty);
expect(await store.getCompletedCount(), 0);
```

Run `../tools/flutter --no-version-check test --no-pub test/storage/browser_local_store_test.dart`; expect missing class/API, then observed rollback failures while implementing.

- [ ] Define schema version 1 root: `version`, `client_id`, `active_backend`, `active_profiles` (backend→user), `profiles` (JSON-encoded `[backend,user]` key→profile). Each profile has `metadata`, lesson/card/log/completion maps, queue keyed by integer ID, `next_queue_id`, and local-date activity map. Store dates as ISO-8601, payloads using existing sync field names. Default user is `default_user`; stable client ID uses Random.secure once per installation.
- [ ] Implement serialized copy/save/publish updates. The mutation queue is separate from the higher-level withProfileLock queue; individual CRUD calls never reacquire the outer profile queue. Core algorithm:

```dart
Future<void> persistEdit(void Function(Map<String, dynamic>) edit) {
  final operation = mutationTail.then((_) async {
    final candidate = Map<String, dynamic>.from(jsonDecode(jsonEncode(state)) as Map);
    edit(candidate);
    await persistence.save(candidate);
    state = candidate;
  });
  mutationTail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
  return operation;
}
```

Fields `state`, `mutationTail = Future<void>.value()` and injected `persistence` belong to BrowserLocalStore; initialize them lazily in the actual async execution zone. Reject non-1 schema/corrupt maps before mutation; never erase unrecognized data automatically.

- [ ] Implement every Appendix A operation using this state, preserving native sorting/filter semantics and defensive copies. recordReviewTransaction writes card, random review ID, completion, stable queue mutation and one activity increment in one persistEdit; preserve client_card_snapshot and rating.index+1. Pending queue reads are ID-ordered; interrupted in_progress reviews return to pending; retries preserve review_id. LocalStore getters are read-only.
- [ ] Implement selectBackend and switchAccount under the caller's withProfileLock. Backend selection atomically stores active_backend and restores its last active profile; new backend starts anonymous. Logout selects that backend's anonymous profile without discarding the prior account. getAccount reads metadata.account; PIN never enters root. clearCurrentProfile resets active learning/cursors while preserving account/client ID/inactive profiles. clearAll remains a full explicit reset for maintenance/tests; web UI uses clearCurrentProfile in Task 6.
- [ ] Add tests for two accounts with same item ID, two anonymous backend URLs, duplicate server completions newest-first/oldest-first through SyncCoordinator, in-flight switch/reset, seed/custom metadata, filtering, due UTC boundaries, streak across midnight, mark/delete/retry queue operations, corrupt version, read-only alias mutation and reopening. For switch tests use Completer-controlled HTTP replies and assert the previous account remains active until reconciliation finishes.
- [ ] Run pure-browser-store tests and existing native tests GREEN. Complete graph analysis and commit `feat: add atomic browser learning profiles and review queues`.

## Task 3: Persist state in IndexedDB and enforce one writer tab

**Files:** Create `storage/indexed_db_persistence.dart`, `browser_writer_lease.dart`, `local_database_web.dart`; modify facade; test `app/test/web/indexed_db_test.dart`, `browser_writer_lease_test.dart`.

**Interfaces:** `IndexedDbSnapshotPersistence implements SnapshotPersistence`; constructor `IndexedDbSnapshotPersistence({String databaseName = 'lingua_canvas_web'})` is lazy; static `Future<IndexedDbSnapshotPersistence> open({String databaseName = 'lingua_canvas_web'})` constructs and opens immediately for tests. load/save ensure the connection is open. `BrowserWriterLease.acquire({String name = 'lingua_canvas_writer'}) → Future<BrowserWriterLease>` and `Future<void> release()`. The shared `BrowserStorageException(code,message)` from snapshot_persistence.dart covers busy, unsupported, blocked, quota, corrupt and transaction errors. Web facade `class LocalDatabase extends BrowserLocalStore` supplies singleton `instance` using the lazy persistence constructor. Its initialize acquires the writer lease before super.initialize; close releases it in finally. Storage initialization failure also closes/releases acquired resources before retry. Native facade exports remain available only on native:

```dart
export 'storage/local_models.dart';
export 'storage/local_database_native.dart'
    if (dart.library.js_interop) 'storage/local_database_web.dart';
```

- [ ] Write real browser tests before the adapter:

```dart
final persistence = await IndexedDbSnapshotPersistence.open(databaseName: 'lingua_test_reload');
await persistence.save({'version': 1, 'client_id': 'test', 'active_backend': 'http://test/api/v1',
  'active_profiles': <String, dynamic>{}, 'profiles': <String, dynamic>{}});
await persistence.close();
final reopened = await IndexedDbSnapshotPersistence.open(databaseName: 'lingua_test_reload');
expect((await reopened.load())!['client_id'], 'test');
await reopened.close();
```

Also acquire two independent leases of the same name; second must fail busy promptly, then succeed after first release. Use unique test DB/lock names and close/release in finally.

- [ ] Run `CHROME_EXECUTABLE=/snap/bin/chromium ../tools/flutter --no-version-check test --no-pub --platform chrome test/web/indexed_db_test.dart test/web/browser_writer_lease_test.dart`; expect RED missing implementations. If that launcher cannot run in the environment, locate an installed Chromium executable; do not skip browser verification or add product dependencies. Record runner limitations explicitly.
- [ ] Bind browser APIs using dart:js_interop and dart:js_interop_unsafe in these browser-only files. Acquire exclusive navigator.locks.request with ifAvailable=true. The callback returns a pending JSPromise held until release/close; a separate readiness completer resolves after lock acquisition. Do not await the request's final completion before returning the acquired lease. Missing API/insecure context/lock denial returns a typed error.
- [ ] Open IndexedDB version 1 with metadata and profiles stores. Split root metadata from profile records; compose on load. Save deletes obsolete profile keys and writes metadata/profile entries inside one readwrite transaction over both stores. Issue all requests while the transaction is active; resolve save only from oncomplete, reject onabort/onerror even after put. Pre-serialize candidate JSON before opening the transaction. Do not await network/timers inside an IDB transaction. Close on versionchange and report blocked upgrade with retry guidance.
- [ ] Add a narrow injectable fault seam around transaction completion for deterministic quota/abort tests; assert no partial metadata/profile snapshot becomes visible after reopening. Test unsupported factory/locks, busy lock, blocked open, corrupt version and lock release after close. In real browser tests, exercise an actual transaction abort as well as fake callbacks.
- [ ] Run browser storage tests and VM storage tests GREEN. Stage, graph analysis, commit `feat: persist browser profiles with IndexedDB and writer leases`.

## Task 4: Boot the five-screen app on web with scoped backend/accounts

**Files:** Create platform bootstrap/capability files from file map, `widgets/platform_bootstrap_gate.dart`, ink common/native/factory files, `models/handwriting_stroke.dart`, `app/web/index.html`, `flutter_bootstrap.js`, `manifest.json`; modify main.dart, api_service.dart, account_service.dart, digital_ink_engine.dart, handwriting_recognizer.dart, Canvas and Settings; test `app/test/web/platform_bootstrap_test.dart`, `app/test/services/web_backend_scope_test.dart`, and update `app/test/widget_test.dart` for the explicit bootstrap lifecycle.

**Interfaces:** `Future<void> initializePlatformStorage(LocalStore store)` selected by conditional platform bootstrap; native calls initialize, web opens durable storage/writer and restores configured backend. `Future<void> ApiService.configureServer(String url)` validates, awaits withProfileLock/selectBackend and then applies normalized URL; existing setBaseUrl remains the validated synchronous low-level setter. All production Settings backend changes use configureServer. `String devicePlatform()` and `String deviceName()` return web/Web Browser or prior native values. `DigitalInkEngine createDigitalInkEngine()` selects ML Kit on Android and heuristic on browser/Linux.

- [ ] Write default URL, invalid URL and token-scope tests first. Define `resolveApiBaseUrl({required bool isWeb, required Uri pageUri, String configured = ''})` in platform_capabilities.dart; explicit override wins, native default stays http://127.0.0.1:8080/api/v1, browser default is page origin + /api/v1:

```dart
expect(resolveApiBaseUrl(isWeb: true, pageUri: Uri.parse('https://learn.test/study/')),
  'https://learn.test/api/v1');
expect(resolveApiBaseUrl(isWeb: false, pageUri: Uri.parse('https://learn.test/')),
  'http://127.0.0.1:8080/api/v1');
```

Inject an in-flight authenticated sync into configureServer; after completion the new backend has its own anonymous queue/profile. Invalid URL/HTTPS→HTTP configuration leaves URL/profile unchanged and never makes HTTP requests. Preserve redirects=false assertions from existing account/profile tests.

- [ ] Write bootstrap widget tests: init busy/unsupported/error shows retry and does not mount MainShell; successful init mounts all five screens. Retry completes once and never opens competing storage sessions. Inject initialized fake storage in root widget tests; real SQLite initialization must use tester.runAsync rather than waiting for FFI inside a fake clock. Run targeted tests RED.
- [ ] Implement browser capabilities without dart:io; replace Platform references in account service, Canvas and handwriting recognizer. Extract stroke/point data classes from handwriting_recognizer to the model file and re-export them for compatibility. Move heuristic/mock/interface ink code to common and ML Kit implementation/imports to native file. Change default engine construction to factory; preserve native tests importing MlKitDigitalInkEngine through conditional facade exports.
- [ ] Add bootstrap gate before MainShell, so storage cannot be used before durable initialization/lease. Keep native root widget compatibility. Browser startup restores the preferred backend from active_backend unless compile-time API_BASE_URL overrides it; scope browser profile before creating ApiService. Guard late init after dispose and retry errors.
- [ ] configureServer validates http/https, nonempty host, no userInfo/query/fragment and no mixed content on HTTPS frontend before touching store. Under profile lock await selectBackend, then update API/coordinator. Settings clears cached screen generation after backend changes. Account request platform is web with existing stable installation ID. Root initialization failures remain recoverable UI states, not swallowed exceptions.
- [ ] Add web index with UTF-8, viewport, title, Flutter `$FLUTTER_BASE_HREF` base token and flutter_bootstrap.js. Bootstrap uses `{{flutter_js}}`, `{{flutter_build_config}}` and `_flutter.loader.load()`; no remote scripts or service worker registration. Manifest declares Lingua Canvas name/theme/start URL; avoid nonexistent icon entries.
- [ ] Run targeted VM and Chromium tests GREEN, then `../tools/flutter --no-version-check build web --no-pub --release --no-web-resources-cdn --pwa-strategy=none`. Expected successful build; check web import graph excludes SQLite/FFI/native ML Kit and application dart:io access. Stage, graph analysis and commit `feat: enable Flutter web startup and backend-scoped accounts`.

## Task 5: Add browser speech practice and capability-aware audio

**Files:** Create speech files from file map; modify speech_practice_service.dart, tts_service.dart and speech_capture_dialog.dart; test `app/test/services/browser_speech_engine_test.dart`, `app/test/web/browser_speech_bridge_test.dart`.

**Interfaces:** Keep SpeechPracticeEngine/SpeechPracticeService/PronunciationResult public signatures. Extract shared types and native channel implementation without renaming existing classes. `BrowserSpeechPracticeEngine({required BrowserSpeechBridge bridge, Duration timeout = const Duration(seconds:30)}) implements SpeechPracticeEngine`. Bridge contract lives in browser_speech_bridge_contract.dart (pure Dart); the JS implementation alone lives in browser_speech_bridge.dart. BrowserSpeechPracticeEngine and VM tests import only the pure contract:

```dart
abstract interface class BrowserSpeechBridge {
  bool get available;
  Future<void> start(String language, {
    required void Function(String transcript) onFinal,
    required void Function(String code, String message) onError,
  });
  Future<void> abort();
}
```

`speech_factory_native.dart` and `speech_factory_web.dart` each produce `SpeechPracticeEngine createSpeechPracticeEngine()`. Keep one shared platform engine for both live screens, as in the existing service.

- [ ] Write pure-engine cancellation/final/timeout tests with FakeBrowserSpeechBridge implementing the declared contract and retaining passed callbacks. Example:

```dart
final pending = engine.listen(language: 'ja');
final oldFinal = bridge.onFinal!;
await engine.stop();
await expectLater(pending, throwsA(isA<SpeechPracticeException>()));
final next = engine.listen(language: 'en');
oldFinal('stale');
bridge.onFinal!('meeting');
expect(await next, 'meeting');
```

Register expectation before stop if needed to prevent an unhandled async error. Assert ja/en normalize to ja-JP/en-US, partial results do not resolve, denial maps to permission_denied, unavailable to unavailable, no speech/timeout/cancel codes settle once and dispose/screen epochs reject late events. Run VM tests RED.

- [ ] Implement browser engine session counter, pending completer and timer; abort superseded sessions, detach callbacks and settle each future once. Map JS errors to typed existing exceptions. Shared normalization/scoring remains unchanged.
- [ ] Implement JS bridge with feature-detected SpeechRecognition/webkitSpeechRecognition, lang, interimResults=true, maxAlternatives=5 and continuous=false. Final results resolve joined final text; onerror maps not-allowed/service-not-allowed to permission_denied, no-speech to recognition_failed, aborted to cancelled. onend without final result must settle with a bounded no-speech error, never hang. Abort detaches handlers first. Browser test installs a fake JS constructor, exercises actual callbacks, then restores the previous global value in teardown.
- [ ] TTS uses existing FlutterTts web support; ensure native channel paths are guarded with !kIsWeb. Missing voice returns unavailable, and stop works after tab/profile switch. For unsupported/denied speech offer the explicit typed transcript dialog, with no acoustic-quality or offline claim. Keep the existing post-availability isCurrent check.
- [ ] Run original 19 speech tests, new engine/bridge tests and UI dictation tests GREEN; rebuild web. Graph analysis and commit `feat: add browser speech practice with explicit capability fallbacks`.

## Task 6: Adapt all five screens and surface durable-save failures

**Files:** Modify main_shell_screen.dart, canvas_practice_screen.dart, ai_roleplay_screen.dart, curriculum_screen.dart, analytics_screen.dart, settings_screen.dart and account_settings_card.dart; create web_capability_card.dart; test `app/test/web/responsive_navigation_test.dart`, `web_capability_ui_test.dart`, `durable_review_ui_test.dart`.

**Interfaces:** Same five navigation destinations and callbacks. MainShell uses NavigationRail at width >=900 and current NavigationBar below it, sharing selectedIndex/profileGeneration. Web capability card shows storage, heuristic handwriting, TTS and speech availability. Browser reset calls LocalStore.clearCurrentProfile; native reset continues clearAll. Profile-change callbacks invalidate all cached screen states.

- [ ] Write parameterized widget tests for 390x844, 768x1024, 1440x900 and 1440x600. Inject existing mock services, settle only finite animations, visit five screens and assert no layout errors:

```dart
for (final size in [const Size(390,844), const Size(768,1024), const Size(1440,600)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MaterialApp(home: MainShellScreen(apiService: service)));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}
```

Use one test per size or reset tree between cases; restore view in teardown. Assert selected screen survives navigation layout change; keyboard focus and Enter/Space activate controls.

- [ ] Write quota failure UI regression using an ApiService fake whose submitReview throws BrowserStorageException('quota', 'storage full'). Tap Good, assert no “Đã lưu đánh giá”/auto-advance and an actionable unsaved message; retry after fake recovers and assert exactly one review. Write reset test with Alice/Bob pending queues, confirm web reset only clears Alice learning progress and preserves Bob/account/client ID. Run RED.
- [ ] Implement responsive shell; constrain reading areas to useful widths using LayoutBuilder/ConstrainedBox while Canvas retains writing space and scrolling on short windows. Preserve IndexedStack isActive flags so hidden screens do not record speech or animate guides.
- [ ] Hide native model-download controls on web; show geometric-assessment and illustrative-guide labels. Show speech network/capability description near the relevant help. Web Settings device icon supports web and label Web Browser; storage help states same-origin scope, eviction risk and one active writer tab.
- [ ] Catch durable save failures in _submitFSRSRating and expose retry without changing counts or scheduling transition. Ensure logout/backend/reset errors remain visible and do not update UI to an uncommitted profile. Set browser reset confirmation text to current profile, call clearCurrentProfile, and reset cached UI/coordinator time.
- [ ] Run new widget tests, existing navigation/Canvas/Roleplay/Settings tests and browser smoke GREEN. Graph check and commit `feat: adapt five learning screens for browser interaction`.

## Task 7: Package static hosting and prove real browser synchronization

**Files:** Create `tools/serve_web.py`, `deploy/web/nginx.conf`, `deploy/web/Dockerfile`, `deploy/web/README.md`, `tests/web/test_serve_web.py`, `tests/web/run_browser_tests.sh`, `app/test/web/live_sync_test.dart`, `server/tests/web_platform.rs`; modify server/src/lib.rs only for exposed X-Cache header if needed.

**Interfaces:** Dev server CLI `python3 tools/serve_web.py --directory app/build/web --port 28190 --api-origin http://127.0.0.1:28191`. Same-origin /api/v1 proxy, bounded request bodies/timeouts, ordinary static assets and index fallback. Browser live test consumes `--dart-define=WEB_TEST_API_BASE=http://127.0.0.1:28190/api/v1`. Script never points tests at a user's existing database/server implicitly.

- [ ] Write Python tests for static content, correct .wasm MIME, /api/v1 forwarding of status/body/X-Sync-Token and HEAD, unknown API path 404 without index fallback, oversized body rejection and traversal denial. Use unittest + http.server fixtures, no Python packages. Run `python3 -B -m unittest discover -s tests/web -p 'test_*.py' -v` RED.
- [ ] Implement bounded standard-library dev proxy/static server. Do not log tokens/bodies; strip hop-by-hop headers, preserve Content-Type and X-Cache, handle API errors as API errors. Add nginx same-origin location /api/v1/ proxy to server:8080, SPA assets/index handling, wasm MIME and sensible no-cache for index/bootstrap plus cacheable immutable assets. Dockerfile consumes prebuilt app/build/web copied into nginx; no Flutter download in image build.
- [ ] Write Rust preflight/web-device tests using existing AppState test fixtures: OPTIONS with Origin/Access-Control-Request-Headers=x-sync-token,content-type succeeds; register Android A, review two seed cards, login web B, since_seq=0 returns both states/completions, next pull empty; Alice/Bob remain isolated. X-Cache is exposed if diagnostics consume it. Run targeted Rust test RED, implement only missing browser contract support, then GREEN.
- [ ] Add actual browser integration using conditional web LocalDatabase and SyncCoordinator. Register unique account, make offline reviews in IndexedDB, close/reopen store, sync through local proxy and assert queue empty; another independently initialized client with the same token pulls both cards/completions. Reuse the first installation ID on reopen; a second device ID must differ. Test wrong token/cross-account and newest completion LWW. Example assertions after controlled setup:

```dart
expect((await browserCoordinator.synchronize()).success, isTrue);
expect(await browserStore.getPendingMutations(), isEmpty);
expect((await secondDeviceCoordinator.synchronize()).success, isTrue);
expect((await secondDeviceStore.getAllCards()).map((c) => c.itemId), containsAll(['ja_hira_a','ja_hira_i']));
```

Set up these named stores/coordinators in the test using BrowserLocalStore, unique IndexedDbSnapshotPersistence DB names and real HTTP clients. Use different DB/lock names for simulated devices; production default origin locking remains tested separately. No in-memory substitute for browser persistence.
- [ ] Runner requires an installed Chromium via CHROME_EXECUTABLE, an explicit disposable TEST_DATABASE_URL and free isolated API/proxy ports. Start built backend/proxy with unreachable controlled AI endpoint, wait health, run browser tests, and clean only owned child processes in finally/trap. Denied storage and two independent writer sessions are covered by browser tests; use real tabs for final manual writer handover check if the test harness lacks multi-tab driving. Report the exact boundary.
- [ ] Run real browser tests GREEN, inspect all five screens in the browser and record actual viewport/keyboard/mouse/touch results. Verify rendering with external network disabled after initial page load; do not claim cold-start offline behavior. Graph check and commit `feat: package web hosting and verify browser device sync`.

## Task 8: Add CI, run final gates and deliver a reviewed branch

**Files:** Modify `.github/workflows/ci-flutter.yml`, PROJECT.md, README.md, TEST_READY.md, TEST_INFRA.md; create WEB_PLATFORM_EXECUTION_REPORT.md.

**Interfaces:** Existing CI checks retained; add release web build, Chromium browser tests and uploaded static build artifact. Report exact automated/browser/manual coverage and limitations.

- [ ] Confirm CI has a Chrome executable and set CHROME_EXECUTABLE for browser tests. Add commands already proven locally:

```yaml
- name: Run browser storage and speech tests
  run: flutter test --platform chrome test/web/indexed_db_test.dart test/web/browser_writer_lease_test.dart test/web/browser_speech_bridge_test.dart
- name: Build web release
  run: flutter build web --release --no-web-resources-cdn --pwa-strategy=none
```

Keep native VM tests from attempting browser-only files: browser-only tests use `@TestOn('browser')` followed by `library;` and import flutter_test (which exports TestOn); VM suite includes pure browser-store/engine logic. Conversely browser command lists only compatible tests. Keep Android/Linux build checks and existing version pin.
- [ ] Add web build artifact upload scoped to app/build/web, excluding source credentials; no deploy job. Include relevant web/hosting paths in workflow triggers. Validate exact YAML trigger/step changes and browser-only test annotations.
- [ ] Run complete gates with pinned SDK and disposable infrastructure; save full outputs and inspect exits:

```bash
cargo fmt --manifest-path server/Cargo.toml -- --check
cargo check --manifest-path server/Cargo.toml --offline
cargo clippy --manifest-path server/Cargo.toml --offline --all-targets -- -D warnings
cargo test --manifest-path server/Cargo.toml --offline --all-targets
cd app
../.toolchains/flutter/3.47.6/flutter/bin/dart format --output=none --set-exit-if-changed .
../tools/flutter --no-version-check analyze --no-pub
../tools/flutter --no-version-check test --no-pub
../tools/flutter --no-version-check test --no-pub --platform chrome test/web/indexed_db_test.dart test/web/browser_writer_lease_test.dart test/web/browser_speech_bridge_test.dart
../tools/flutter --no-version-check build web --no-pub --release --no-web-resources-cdn --pwa-strategy=none
cd ..
docker compose config -q
python3 -B -m unittest discover -s tests/e2e -p 'test_*.py' -v
python3 -B -m unittest discover -s tests/web -p 'test_*.py' -v
./tests/web/run_browser_tests.sh
./tests/e2e/run_e2e_tests.sh --all
ADVERSARIAL_PORT_OFFSET=23000 python3 -B tests/adversarial_suite.py
```

Set TEST_DATABASE_URL/TEST_REDIS_URL for opt-in actual infrastructure tests; isolate E2E data from unit tests. Put pinned Flutter first on PATH for Python E2E. Reuse cached cargo audit if network unavailable and label advisory freshness honestly. Record unavailable device/build environments rather than falsely marking their checks passed.
- [ ] Inspect `git diff -- app/pubspec.lock server/Cargo.lock` (must be empty), no generated build files staged, and final browser console/network errors. Update docs with actual counts, web configuration, HTTPS/localhost requirement, one writer tab, heuristic recognition and non-PWA scope. Correct the preexisting M5/M6 placement in PROJECT's milestone table as part of the feature inventory update.
- [ ] Run GitNexus reindex, stage final files, full detect_changes and inspect risk/coverage. Dispatch one whole-branch reviewer if Native execution was selected, or follow per-task/whole review gates of subagent execution. Give reviewer this plan/spec, change range and evidence; fix important findings with reproduced RED/GREEN tests. Record minor limitations.
- [ ] Commit `ci: validate and document the Flutter web platform`; push feature branch and create/update its scoped PR, attaching it with the app artifact tool. Verify remote SHA matches local, working tree clean and CI actually triggered. No merge. Preserve execution report; remove only this plan's scratch workspace after review and delivery.

## Appendix A: exact shared storage contract

Import LessonItem and FSRS types plus local_models.dart. Native-only SQL/test hooks are deliberately excluded. Additional operations initialize/selectBackend/clearCurrentProfile have the semantics defined in Tasks 1–2.

```dart
abstract interface class LocalStore {
  Future<void> initialize();
  Future<void> selectBackend(String baseUrl);
  Future<void> clearCurrentProfile();
Future<void> saveLessons(List<LessonItem> lessons);
Future<void> saveLesson(LessonItem lesson);
Future<List<LessonItem>> getLessons({
    String? language,
    String? category,
  });
Future<LessonItem?> getLesson(String id);
Future<void> saveCard(FSRSCard card);
Future<FSRSCard?> getCard(String itemId);
Future<List<FSRSCard>> getAllCards();
Future<List<String>> getDueCardIds(DateTime asOf);
Future<void> insertReviewLog(LocalReviewLog log);
Future<List<LocalReviewLog>> getReviewLogs({int? synced, int? limit});
Future<void> markReviewLogsSynced(List<String> ids);
Future<int> enqueueMutation({
    required String mutationType,
    required Map<String, dynamic> payload,
    DateTime? createdAt,
  });
Future<List<SyncQueueItem>> getPendingMutations({int? limit});
Future<void> recoverInterruptedMutations();
Future<T> withProfileLock<T>(Future<T> Function() operation);
Future<String?> getMetadata(String key);
Future<void> setMetadata(String key, String value);
Future<Map<String, dynamic>?> getAccount();
Future<int?> getSyncSequence();
Future<void> setSyncSequence(int sequence);
Future<void> switchAccount(Map<String, dynamic>? account);
Future<DateTime?> getLastPullTime();
Future<String> getOrCreateClientId();
Future<void> setLastPullTime(DateTime time);
Future<void> markMutationsInProgress(List<int> ids);
Future<void> deleteMutations(List<int> ids);
Future<void> resetFailedMutations(List<int> ids);
Future<void> saveCompletedLesson(
    String lessonId, {
    DateTime? completedAt,
    double score = 1.0,
    int synced = 0,
  });
Future<List<LocalCompletedLesson>> getCompletedLessons({int? synced});
Future<int> getCompletedCount();
Future<void> markCompletedLessonsSynced(List<String> lessonIds);
Future<String> recordReviewTransaction({
    required FSRSCard updatedCard,
    required FSRSRating rating,
    required DateTime reviewTime,
    required double elapsedDays,
    required int scheduledDays,
    double completionScore = 1.0,
  });
Future<void> logDailyActivity(DateTime date, int itemsCount);
Future<StudyStreak> getStudyStreak({DateTime? asOf});
Future<void> clearAll();
Future<void> close();}
```

## Pre-flight interface rulings

- LocalStore accepts native and browser stores; existing tests constructing LocalDatabase keep native-only static hooks and schema 4. Tests needing a real SQLite handle import only the native target.
- Browser clearCurrentProfile is a new scoped operation; it implements the spec's protection of inactive profiles without silently changing native clearAll/reset behavior.
- Higher-level withProfileLock serializes sync/account/backend/reset/custom-word creation. The browser persistence mutation queue is distinct, so nested domain CRUD does not deadlock on the same queue.
- Model extraction retains exports and names; moves are not symbol renames. Break the current ink/recognizer dependency cycle by extracting stroke models rather than adding another cycle.
- Browser-only tests are explicitly annotated and excluded from the native VM run; pure Dart browser storage/speech tests still run in that VM suite.
- Static hosting is a configuration/build deliverable; public deployment is not authorized by this plan.

## Self-review record

Coverage: persistence/account safety→1–4; all five screens/responsive→4,6; handwriting→4,6; speech/TTS→5–6; backend/hosting→4,7; real-browser/infrastructure verification→3,7–8; CI/docs/review/delivery→8. The five Review Focus conditions have concrete tests in their owning tasks. No new package, undefined storage interface, SQL emulation or silent persistence fallback is planned.
