# Test Infrastructure & Dual-Track E2E Architecture

## 1. Overview & Architectural Philosophy
Lingua Canvas employs a **Dual-Track Testing Architecture**:
1. **White-Box Unit & Integration Tests**: Co-located in `server/src/` (Rust unit tests & integration tests) and `app/test/` (Flutter widget and engine unit tests).
2. **Opaque-Box 4-Tier End-to-End (E2E) Test Suite**: Located in `tests/e2e/`, verifying live HTTP endpoints, state transitions, client-server contracts and simulated learning workflows. Tier 1 also runs Flutter analysis and unit/widget tests.

### Anti-Cheating & Integrity Mandate
API scenarios use a real Rust server and HTTP requests. Flutter unit/widget tests use SQLite FFI, mocked HTTP transports and injected Digital Ink engines where appropriate. The separate runner lifecycle unit tests mock process creation. These tests do not establish native Android/iOS ML Kit accuracy; device checks are required. PostgreSQL persistence coverage requires a real database, as used in the 2026-10-02 verification recorded in `TEST_READY.md`.

---

## 2. 4-Tier Test Hierarchy & Coverage

```
tests/e2e/
├── run_e2e_tests.sh           # Master CLI runner with server lifecycle management
├── common.py                  # Standard library test harness, HTTP client & assertions
├── tier1_feature_coverage.py  # Tier 1: Feature Coverage (14 tests)
├── tier2_boundary_cases.py    # Tier 2: Boundary & Corner Cases (23 tests)
├── tier3_cross_feature.py     # Tier 3: Cross-Feature Combinations (7 tests)
└── tier4_real_world.py        # Tier 4: Real-World Scenarios (3 scenarios / 16 steps)
```

### Tier 1: Feature Coverage (`tests/e2e/tier1_feature_coverage.py` - 14 tests)
Validates baseline features and environment cleanliness:
- **Git Baseline**: Monorepo root `.git` presence, `.gitignore` exclusions (`target/`, `.dart_tool/`, `build/`, `.env*`) and remote origin configuration. This check is not a secret scanner.
- **Multi-Environment Configurations**: Existence and non-emptiness of `.env.example`, `.env.development.example`, `.env.staging.example`, and `.env.production.example`.
- **Flutter Client Health**: Automated `flutter analyze` and `flutter test` execution (82 tests in the verification record).
- **Docker Configuration**: Syntactic validation of `docker-compose.yml` and `Dockerfile` (Progressive Testability aware).
- **Axum REST API Endpoints**:
  - `GET /api/v1/health` -> HTTP 200, valid service metadata schema.
  - `GET /api/v1/lessons` -> HTTP 200, validates full schema for all `LessonItem` records.
  - `GET /api/v1/lessons?language=ja` / `?category=it_workplace` -> Filter query verification.
  - `GET /api/v1/lessons/:id` -> Single lesson retrieval.
  - `POST /api/v1/fsrs/review` -> FSRS card rating submission.
  - `GET /api/v1/fsrs/due` -> Due reviews queue.
  - `POST /api/v1/ai/roleplay` -> AI dialogue and handwriting challenge generation.
  - `POST /api/v1/ai/dialogue` -> Full curriculum dialogue generation schema (`title`, `title_vi`, `lines`, `vocabulary`, `grammar_hints`, `suggested_writing_targets`) across Japanese and English.
  - `POST /api/v1/sync` & `GET /api/v1/sync/pull` -> Batch review synchronization ingestion and delta retrieval schema.

### Tier 2: Boundary & Corner Cases (`tests/e2e/tier2_boundary_cases.py` - 23 tests)
Validates system resilience against malformed inputs and hostile boundaries:
- **Invalid Rating Values**: Rejection of ratings outside 1–4 (0, 5, 100, 255, string types) with HTTP 400 Bad Request.
- **Non-Existent Resources**: Missing lesson IDs return HTTP 404 Not Found.
- **Dynamic Card Creation**: Reviewing unknown/custom item IDs creates a new card cleanly without crashing.
- **Malformed & Truncated Payloads**: Truncated JSON, missing required fields (`item_id`, `rating`), and empty objects correctly rejected with HTTP 400 or 422.
- **Offline AI Resilience**: When local LLM service (Ollama) is offline or unreachable, server does NOT return 500; it falls back cleanly to the contextual mock engine returning Japanese/English workplace dialogues.
- **Unicode, Diacritics & Emojis**: Japanese Kanji/Kana, Vietnamese tone marks, quotes, tags, and emojis handled with pristine UTF-8 integrity.
- **Query Parameter Boundary**: Unknown query parameters or non-existent filters return empty collections rather than 500 errors.
- **Malformed Sync Payloads**: Invalid ratings (0, 5, 99, 255) inside sync review arrays rejected with HTTP 400.
- **Missing Sync Fields & Bad Types**: Missing `item_id`, non-ISO datetime formats, and truncated JSON in `/sync` rejected with HTTP 400/422.
- **Empty Sync Payloads**: Empty review/lesson arrays handled gracefully with HTTP 200 and zero mutation.
- **Clock Skew Clamping**: Future review timestamps (> 5 minutes ahead) clamped to server `now`, preventing timestamp spoofing.
- **Dialogue Profession Fallbacks**: Non-standard or custom professions (e.g. "astronaut", "doctor", empty string) cleanly normalized to standard fallbacks with HTTP 200.

### Tier 3: Cross-Feature Combinations (`tests/e2e/tier3_cross_feature.py` - 7 tests)
Validates state machine transitions, concurrent safety, and cross-tier alignment:
- **FSRS Queue State Transitions**: Reviewing a due card with rating 3 (Good) reschedules it 3 days in the future, automatically evicting it from the immediate due queue and sliding in the next queued lesson.
- **Complete FSRS Card Lifecycle**:
  - `New` -> `Review` on initial Good rating.
  - Consecutive Good ratings expand stability and interval.
  - Forgetting (`Again` rating 1) triggers state lapse transition to `Relearning` and reschedules card for 10 minutes out.
- **Mathematical Bound Clamping**: Continuous extreme ratings (all 4s or all 1s) maintain difficulty clamped within [1.0, 10.0].
- **Multi-Environment Key Parity**: Confirms required keys (`PORT`, `DATABASE_URL`, `AI_ENDPOINT`, `AI_MODEL`, `RUST_LOG`) are present and aligned across `.env.example`, `.env.development.example`, `.env.staging.example`, `.env.production.example`.
- **Concurrency & Thread Safety**: 16 concurrent review requests executed simultaneously via thread pool verify `RwLock<HashMap<String, FSRSCard>>` thread safety with 0 deadlocks or race conditions.
- **Docker Service Dependency Hierarchy**: Verifies service startup dependencies (`server` -> `postgres`, `redis`, `ai-stub`).
- **Batch Sync Push -> Delta Pull -> LWW Conflict Resolution**:
  - Pushes initial batch review at `t_base` (10:00 UTC).
  - Retrieves delta via `GET /sync/pull?since=...`.
  - Simulates offline conflicting review from another client with older timestamp `t_older` (08:00 UTC) rating 1 (Again). Verifies Last-Write-Wins (LWW) prevents state regression.
  - Simulates newer review `t_newer` (12:00 UTC) rating 3 (Good), verifying state advancement to reps 2.
  - Confirms high-water mark delta pull reflects the latest reconciled state.

### Tier 4: Real-World Scenarios (`tests/e2e/tier4_real_world.py` - 3 scenarios)
Simulates authentic end-to-end learning workflows:
- **Scenario 1 (Japanese IT Workplace)**:
  1. Health check & latency benchmark: Verifies server responds to `/health` in < 100ms.
  2. Curriculum exploration: Retrieves Japanese IT lessons ("バグ" and "開発").
  3. Canvas handwriting practice & review: Learner rates "バグ" Good (3) -> scheduled for 3 days later.
  4. Complex kanji stroke practice & lapse: Learner rates "開発" Again (1) -> scheduled for 10 minutes later.
  5. Interactive AI roleplay: Learner reports bug progress in daily standup -> receives reply, Vietnamese breakdown, and challenge word ("進捗").
  6. Challenge word review: Rates challenge word Easy (4) -> scheduled for 15 days later.
  7. Due queue verification: Confirms "バグ" is evicted from immediate queue.
- **Scenario 2 (English IT Workplace)**:
  1. Retrieves English IT curriculum ("deploy", "deadline", "resolve").
  2. Reviews "deploy" with Good (3).
  3. Participates in English standup roleplay.
  4. Verifies queue state updates correctly.
- **Scenario 3 (Hospitality Worker Japanese Dialogue & Offline Review Sync)**:
  1. Requests dialogue generation via `/api/v1/ai/dialogue` for `hospitality` hotel check-in.
  2. Verifies hotel reception dialogue, vocabulary ("禁煙", "確認", "用意"), and suggested writing targets.
  3. Simulates offline handwriting practice on mobile terminal, accumulating batch reviews and completed lessons.
  4. Reconnects to network and flushes queue to `POST /api/v1/sync`.
  5. Verifies multi-device pull delta via `GET /api/v1/sync/pull` and confirms future scheduling with FSRS intervals.

---

## 3. Test Runner & Execution Guide

### Master Command
```bash
./tests/e2e/run_e2e_tests.sh --all
```

### Running Individual Tiers
```bash
# Tier 1 only: Feature Coverage
./tests/e2e/run_e2e_tests.sh --tier=1

# Tier 2 only: Boundary & Corner Cases
./tests/e2e/run_e2e_tests.sh --tier=2

# Tier 3 only: Cross-Feature Combinations
./tests/e2e/run_e2e_tests.sh --tier=3

# Tier 4 only: Real-World Application Scenarios
./tests/e2e/run_e2e_tests.sh --tier=4
```

### Standalone Python Execution
Each tier can also be executed directly via Python:
```bash
python3 tests/e2e/tier1_feature_coverage.py
python3 tests/e2e/tier2_boundary_cases.py
python3 tests/e2e/tier3_cross_feature.py
python3 tests/e2e/tier4_real_world.py
```

---

## 4. Server Lifecycle Automation
The test runner handles the Axum backend process automatically:
1. Probes `${API_BASE_URL}/health` (default `http://127.0.0.1:8080/api/v1/health`).
2. If already running, tests run against the active instance.
3. If not running, it always builds `server/target/debug/server` before launching it on the port from `API_BASE_URL`, logging to `tests/e2e/server.log`.
4. Traps `EXIT`, `INT`, and `TERM` signals to cleanly shut down any background processes it spawned, ensuring zero dangling processes or port conflicts.

---

## 5. Quality Thresholds & Gates
| Metric | Threshold | Verification Method |
|---|---|---|
| **E2E Pass Rate** | 100% (47/47 passing) | `./tests/e2e/run_e2e_tests.sh --all` exit code 0 |
| **Health API Latency** | < 100 ms | Measured during Tier 4 health check |
| **Flutter Analysis** | 0 warnings, 0 errors | `flutter analyze` verified in Tier 1 |
| **Flutter Tests** | 100% pass (82/82) | `flutter test` verified in Tier 1 |
| **Backend Tests** | 100% pass (38/38) | `TEST_DATABASE_URL=... cargo test --all-targets` in `server/` |
| **Backend Lints** | 0 warnings, 0 errors | `cargo clippy --all-targets -- -D warnings` |
| **Security Hygiene** | Required `.gitignore` exclusions; no Gitleaks findings | Tier 1 checks exclusions; Gitleaks history/current source scans are recorded in `TEST_READY.md` |
| **Sync Conflict Resolution** | Last-Write-Wins (LWW) | Validated in Tier 3 cross-feature test |
| **Clock Skew Safety** | Clamped to <= 5 min future | Validated in Tier 2 boundary test |
| **FSRS Difficulty** | Clamped in [1.0, 10.0] | Validated in Tier 3 under extreme ratings |
| **Offline Resilience** | 0 unhandled 500 errors | Verified in Tier 2 offline AI fallback |
