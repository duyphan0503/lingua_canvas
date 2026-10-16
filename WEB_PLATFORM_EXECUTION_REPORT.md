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
| Flutter VM unit/widget suite | 231 passed after final review fixes |
| Chromium IndexedDB / Web Locks / JS speech / web TTS | 10 passed, including late playback cancellation |
| Live Chromium IndexedDB → proxy → Rust → PostgreSQL → second device | 1 passed |
| Rust all targets with disposable PostgreSQL 16 + Redis | 58 passed |
| Rust formatting / check / Clippy warnings denied | Passed |
| Dart formatting / analyzer | 95 files unchanged / no issues |
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


## Final review — 2026-10-16

One independent whole-branch review completed on `0c72beb..edb4493`. The original reviewer was interrupted by its usage limit after reporting the backend/coordinator race; a replacement resumed that interrupted review. No second opinion or post-fix re-review was dispatched.

Three important findings were reproduced with failing tests and fixed in one pass:

1. A sync requested during a durable backend switch could retain the old coordinator and send the new anonymous profile queue to the old server. `ApiService.sync` now waits for queued backend configurations before selecting its coordinator. Regression asserts that B's private queue never sends a request to A.
2. A delayed catalogue response could write A's lessons into B's profile. Catalogue HTTP + persistence now share the profile lock. Nested catalogue calls from custom-word creation share the API operation's zone context so the non-reentrant store lock is acquired once, while preserving public method overrides. Existing custom-builder and Roleplay→Canvas regressions passed after this compatibility check.
3. TTS survived navigation/profile changes, including voice configuration completing after stop. The shell stops playback on narrow/desktop navigation, practice navigation, profile/reset callbacks and disposal. Platform TTS invalidates pending startup using an epoch checked across awaited configuration steps. Three widget regressions and an actual Chromium delayed-voice regression cover the behavior.

Focused regression: 12 tests passed; full Flutter suite: 231 passed; Chromium: 10 passed; analyzer and formatting clean. Important findings have RED→GREEN evidence; no important finding was deferred.

Deferred minor: speaker failure recovery still offers Android voice settings on web. The capability card correctly identifies missing browser voices, but the speaker recovery copy should become browser-specific in a follow-up.

Additional ruling: the live runner uses an optimized release backend after debug PBKDF2 exceeded the client's twelve-second deadline during concurrent builds. Password hashing rounds and API deadlines remain unchanged. Cost: first test-run release compilation takes longer; production-equivalent hashing avoids a debug-performance false failure.

Additional ruling: catalogue requests hold the profile lock through the bounded HTTP request and persistence; a zone-scoped API helper permits safe nested reads and preserves overrides. Cost: a profile/backend switch may wait up to the catalogue request timeout plus its durable save.


Final source verification on 2026-10-16: web release, Linux release and Android debug builds passed after the request-lock compatibility change; live release-backend Chromium/PostgreSQL sync passed. Final focused change analysis: 33 symbols / nine files / 30 affected, CRITICAL; complete branch comparison: 554 symbols / 82 files / 126 affected, CRITICAL. Neither result was partial/truncated. The CRITICAL rating reflects the shared catalogue/sync paths and is retained, not waived by shared axes.

Tooling limitation: the final graph rebuild completed, but GitNexus's full-text/BM25 search index failed. A bounded `analyze --repair-fts` attempt also failed (`Function.function_fts` missing). Structural graph impact and both complete change analyses succeeded. Full-text search needs a separate force rebuild/tool diagnosis; absent search results must not be read as unused code.


## Foundation follow-up — 2026-10-16

The deferred speaker recovery issue above is resolved for both the standard and chip speaker widgets. Browser failures now advise checking Japanese/English voices in the browser and operating system; no Android settings action is offered on web. The shared recovery helper preserves native voice-settings recovery. Two actual Chromium widget regressions failed before the fix and passed afterwards; CI now includes the browser-only recovery file.

The dependency lock updates only rustls 0.23.45 → 0.23.46 and its checksum, addressing RUSTSEC-2026-0346, RUSTSEC-2026-0347, RUSTSEC-2026-0348 and RUSTSEC-2026-0349. Fresh `cargo audit` fetched 1,329 advisories, scanned 260 lockfile dependencies and exited 0; the fetched advisory database was `479c888ce4401313bca61ba4aba2d0f6244c4a09`. No exceptions were added; the existing inactive optional RSA exception is unchanged.

Verification used the pinned Flutter 3.47.6 / Dart 3.13.5 through `tools/flutter`: 231 Flutter VM tests passed, four focused Chromium TTS tests passed, analyzer reported no issues and both edited Dart files passed formatting. Rust formatting, locked compilation and all-target Clippy with warnings denied passed. All 58 Rust tests passed with disposable PostgreSQL 16 and the opt-in live Redis tests enabled. An initial harness run incorrectly used `REDIS_URL`, causing independent test apps to share anonymous rate-limit counters and fail `ai_limiter_counts_hits_and_separates_accounts` (429 instead of 200). The corrected complete run unset `REDIS_URL` and used `TEST_REDIS_URL`; no product change was needed for that harness error.

Pre-edit GitNexus retained the standard speaker HIGH warning (seven direct dependents / three affected flows); chip speaker analysis was LOW (four direct / one flow). Workflow impact was UNKNOWN because YAML is not indexed; source inspection confirmed the sole change appends this browser test to the existing Chrome command. Complete full-scope change analysis found four changed code symbols and two affected settings-recovery flows, MEDIUM, with no partial/truncated result. The graph rebuild retained its existing dropped-flow and failed full-text/BM25 limitations; missing graph results remain inconclusive. Browser voice availability and vendor playback quality still require device QA.
