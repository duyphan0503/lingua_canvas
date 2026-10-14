# Phase 3–4 execution report

Date: 2026-10-14. Branch: `codex/phase3-4-learning-and-sync`.
Base: `33cde5ee10a003ffbe7c73d1aa2afffb42983056` (Phase 1 PR #1).
Plan: `lingua_canvas_phase3_4_expansion_plan.md`. No new dependencies or lockfile changes.

## Delivered

| Task | Result |
| --- | --- |
| G3-T1 | 20 exact new lesson IDs, server/offline parity, 155 total lessons, N4 and TOEIC filters; old 135 preserved |
| G3-T2 | Defensive immutable guide paths, compound layout, 650ms/stroke animation, numbers/arrows, cancellation on pen/lesson/tab |
| G3-T3 | Android native SpeechRecognizer and runtime permission, session-safe channel events, pronunciation transcript comparison, roleplay dictation, explicit Linux typed fallback |
| G4-T1 | Per-account shared writer/exclusive pull barriers, per-card locks, sequence cursors, isolated cards/reviews/completions; legacy default profile supported |
| G4-T2 | RESP2 Redis with total 300ms IO deadline, 3600s AI cache, X-Cache, atomic account rate limits, bounded memory fallback |
| G4-T3 | Salted PIN accounts/token linking, device lists, Settings UI, server-scoped credentials, SQLite profile snapshots and independent offline queues |

## Verification

- Pinned Flutter 3.47.6 / Dart 3.13.5: **194 tests**, analyzer clean; production/test formatting checked.
- Rust: **56 tests**, including actual PostgreSQL 16 concurrency, accounts, restart persistence, devices, cursor and privacy regressions. `cargo fmt`, offline check and warnings-denied Clippy pass.
- Actual Redis tests pass for UTF-8/CRLF framing, TTL expiry, cross-client counters, offline fallback, bounds and timeout. Final 56-test rerun used PostgreSQL; live Redis had passed separately with unchanged cache code.
- **47/47 E2E**, all four tiers, against an isolated backend and newly seeded disposable PostgreSQL database; pinned Flutter first on PATH.
- **59/59 adversarial tests**; **5/5 Python harness tests**; Compose config valid.
- Android Kotlin compile succeeded offline using cached Gradle 8.14, JDK 21 and local Android SDK (124 tasks).
- Cached `cargo audit --no-fetch --stale` exited 0 with a registry lock warning. Advisory data was not refreshed. Existing inactive optional RSA exception remains unchanged.
- Fresh-context review found four important defects, each reproduced by failing tests then fixed: private custom-word disclosure, reset racing reconciliation, delayed availability starting recording after cancellation, and older duplicate completion overriding newer data. Focused re-review found no residual important defect in these fixes.
- GitNexus refreshed; aggregate change risk is **CRITICAL** because authentication, native lifecycle, sync and shared curriculum paths changed. Staged change analysis covered 47 files, 439 changed symbols and 61 affected processes without partial/truncated result flags. The analyzer warns that process discovery caps some paths; absent paths are not treated as evidence of safety. Relevant flows were additionally reviewed and exercised by regressions.

## Decisions and limitations

A SQL sequence allocates values before commit, so a plain BIGSERIAL cursor can skip an uncommitted earlier writer. Writers share an account barrier, and pull takes the exclusive account barrier before sampling its snapshot. Other accounts remain independent. Catalog changes have no account commit barrier, so sequence pulls deliberately send the complete public catalog; account card/completion data remains incremental. Push does not advance the client cursor; only a successfully reconciled pull does.

Profile changes, local reviews, reset and network reconciliation share a SQLite operation queue. Switching waits for the bounded old sync before saving its old profile and loading the new one. Custom-word creation also holds the profile queue, so an in-flight Roleplay save cannot write into a newly selected account. Its regression failed before the fix and passed afterwards. Pending local completions retain priority; newer remote completions win irrespective of device-row order. Authenticated HTTP requests disable redirects and never send stored tokens to another configured backend.

Synthetic custom lesson rows remain internal foreign-key placeholders and are hidden from the public catalog, direct lookup and sync lesson arrays. Their account-scoped review state still synchronizes. Full custom lesson descriptions remain local.

PIN derivation uses self-contained PBKDF2-HMAC-SHA256 (600,000 iterations, random 128-bit salt), published SHA/HMAC/PBKDF2 vectors, constant-work comparison and blocking-pool execution. Account IDs/tokens use 192 random bits. Dependency freeze requires dedicated cryptographic code, increasing maintenance/review burden. This is a lightweight account system; password recovery/token revocation and encrypted local credential storage are outside this plan. PostgreSQL is required for persistence beyond a server restart.

Scores measure similarity between recognized text and target/Kana, not acoustic phoneme quality. Eight complex glyphs (発 確 認 議 連 絡 談 報) and generated unknown-word paths are labeled illustrative. Physical Android microphone permissions, recognizer availability and real speech accuracy still need device QA, along with the existing ML Kit/download, Linux desktop launch and real AI-provider checks.

No merge or production deployment is performed. Phase 3–4 depends on the still-open Phase 1 PR #1; a stacked PR keeps its review scoped to this phase.

Delivery CI: pull-request branch filters also accept `codex/**`, allowing stacked feature PRs to run the same backend, Flutter and security checks. Push filters and job permissions remain unchanged.
