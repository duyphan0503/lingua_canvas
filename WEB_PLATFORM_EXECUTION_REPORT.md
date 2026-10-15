# Web platform execution — 2026-10-15

Implemented on `codex/web-platform`, based on Phase 3–4 (`0c72beb`). Approved design: `docs/superpowers/specs/2026-10-15-web-platform-design.md`; execution plan: `docs/superpowers/plans/2026-10-15-web-platform.md`.

## Delivered behavior

All five learning screens run on the browser. Bottom navigation switches to a sidebar at 900px; selection survives resizing. Native SQLite is isolated behind LocalStore while browser profiles use IndexedDB transactions and an exclusive origin Web Lock. Startup fails visibly with retry when durable storage or the lease is unavailable. There is no silent memory fallback. Reviews, logs, completions and queue entries publish only after the durable transaction commits; save failure leaves the current card unsaved for retry.

Backend URL + account scope local data, queues, tokens and cursors. Browser reset clears the current learning profile while preserving other profiles, identity and account linkage. Browser devices register as `web` and use existing PostgreSQL synchronization. URL validation rejects malformed and HTTPS→HTTP configuration; authenticated transports disable redirects.

Browser handwriting is geometric assessment, explicitly approximate. Browser speech recognition is feature-detected and request-driven; denied/unsupported APIs offer explicit typed text. Late/cancelled sessions cannot inject stale transcripts. TTS uses the existing web plugin and avoids Android channels. Transcript scores compare text, not acoustic pronunciation.

Static assets, a bounded loopback development proxy and a prebuilt-assets nginx container are supplied. Default browser API path is same-origin `/api/v1`; production needs HTTPS. No service worker, PWA install or cold-start offline claim is added. No dependencies or lockfiles changed.

## Verification

Pinned Flutter 3.47.6 / Dart 3.13.5; Chromium Snap 155.0.8059.39.

| Check | Actual result |
| --- | --- |
| Flutter VM unit/widget suite | 226 passed |
| Chromium IndexedDB / Web Locks / JS speech / web TTS | 9 passed |
| Live Chromium IndexedDB → proxy → Rust → PostgreSQL → second device | 1 passed |
| Rust all targets with disposable PostgreSQL 16 + Redis | 58 passed |
| Rust formatting / check / Clippy warnings denied | Passed |
| Dart formatting / analyzer | 92 files unchanged / no issues |
| Web release, bundled runtime resources, no service worker | Passed |
| Linux release build | Passed |
| Android debug build | Passed (`app-debug.apk`); existing AGP/Kotlin/SDK XML upgrade warnings retained |
| Four E2E tiers, fresh PostgreSQL | 47 passed (14 / 23 / 7 / 3) |
| Adversarial provider/parser/timeout suite | 59 passed |
| Python E2E runner/stub regressions | 5 passed |
| Python static/proxy tests | 7 passed |
| Docker Compose configuration | Passed |
| Cached cargo audit (`--no-fetch --stale`) | Exit 0; 1310 cached advisories, crates.io index inaccessible; inactive optional RSA exception retained |

The browser live test creates isolated named IndexedDB stores and a disposable PostgreSQL database, proves stable installation ID after reopen, offline review durability, queue draining, second-device pull, empty next delta, newer completion resolution, cross-account isolation and invalid-token rejection. Production lease ownership is separately exercised by real browser tests. SQL row counts independently confirmed persisted reviews, completions and devices. The runner refuses a database not named `lingua_web_test_*` and requires a PostgreSQL-ready startup log, so memory fallback cannot masquerade as database coverage.

Browser review inspected Canvas, roleplay, 155-item curriculum, analytics and settings in the actual release build. Widget tests visit all five screens at 390×844, 768×1024, 1440×900 and 1440×600; actual Browser inspection confirmed narrow navigation and desktop sidebar. Enter activates Roleplay; Space activates Analytics. Two real tabs show the writer-conflict screen, then retry succeeds after closing the first writer. A 248px Due Queue title overflow was reproduced and fixed with bounded layout. Missing installed browser voices were displayed honestly; microphone permission was not granted. No JavaScript console errors were observed during the inspected flows.

Physical touch, microphone/voice quality, vendor speech networking, real Android ML Kit behavior and cold-start offline loading remain manual QA. Browser connector has no network-disable control; bundled runtime build is not a substitute for that manual check. Existing flutter_tts emits Wasm dry-run cast warnings; this delivery is the successfully compiled JavaScript web target. Missing optional Cupertino font warning remains. Browser storage can be evicted. Full custom-word metadata remains local while progress synchronizes.

## Execution rulings

- Continued inline in the current checkout after the user reaffirmed approval; diagnosed the specific repeated approval stall from visible conversation instead of producing a whole-session diagnostic bundle. Cost if wrong: a broader diagnostic cause remains unexamined.
- Used constructor injection of JS factory/navigator for deterministic unavailable API tests without mutating browser globals. Cost if wrong: browser-specific behaviors still need manual coverage.
- Added preferred-backend restoration only to BrowserLocalStore, leaving native SQL hooks/schema intact. Cost if wrong: native and web settings persistence need separate maintenance.
- Recorded already-run complete test commands/results in the ledger instead of rerunning them through task-done. Cost if wrong: command transcription rather than duplicate execution is the record.
- Increased bounded upstream proxy I/O timeout from five to fifteen seconds after measuring debug PIN hashing at 10.004s and proxy failure at 5.007s; inbound timeout and request limit remain five seconds / 1 MiB. Cost if wrong: failed upstream requests take longer to return.
- Kept unversioned Flutter assets cacheable for one hour instead of immutable; entry points use no-cache. Cost if wrong: extra asset requests.
- Reported unsupported manual touch/network-disable/vendor voice checks explicitly. Cost if wrong: those environments can still reveal device-specific defects.

## Graph and delivery

GitNexus impact preceded implementation edits; UNKNOWN results were checked against source. ApiService was HIGH risk (13 direct dependents / four flows) and that warning was reported before the storage refactor. Task 7's aggregate change analysis was HIGH because the shared API constructor and harness changed; full server regression passed. Complete detect_changes checks had no partial/truncated flags. The index itself reports dropped/unexplored execution flows; absent graph edges are not an all-clear.

GitHub delivery uses a scoped PR against `codex/phase3-4-learning-and-sync` while PR #2 remains open. CI retains native checks and adds Chromium tests, release web build and the static artifact. This branch is not merged or publicly deployed. Final review and remote verification are recorded below.
