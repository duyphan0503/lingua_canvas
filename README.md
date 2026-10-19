# Lingua Canvas 🖌️ 🇯🇵 🇺🇸

[![CI Backend](https://github.com/duyphan0503/lingua_canvas/actions/workflows/ci-backend.yml/badge.svg)](https://github.com/duyphan0503/lingua_canvas/actions/workflows/ci-backend.yml)
[![CI Frontend](https://github.com/duyphan0503/lingua_canvas/actions/workflows/ci-flutter.yml/badge.svg)](https://github.com/duyphan0503/lingua_canvas/actions/workflows/ci-flutter.yml)
[![Security Scan](https://github.com/duyphan0503/lingua_canvas/actions/workflows/security-scan.yml/badge.svg)](https://github.com/duyphan0503/lingua_canvas/actions/workflows/security-scan.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

An Android, Linux and browser language learning application for workplace communication in Japanese (Kanji/Kana, Keigo, tech jargon, hospitality) and English (Agile rituals, PR reviews, standups, customer service). It combines an interactive handwriting canvas with Google ML Kit Digital Ink recognition on Android, local SQLite persistent caching, bidirectional sync with Last-Write-Wins (LWW) conflict resolution, Free Spaced Repetition Scheduler (FSRS v4.5), and local AI-assisted roleplay dialogues (Ollama / Llama.cpp connector).

---

## Learning and multi-device accounts

The catalog has 155 lessons, including workplace JLPT N4 and TOEIC Business filters. Canvas offers animated stroke examples and spoken practice; roleplay supports Android dictation. Linux uses an explicit typed-transcript fallback. Speech scores compare recognized text, and approximate stroke examples are labeled illustrative.

In Settings, register with a username and 4–12 digit PIN, or link another device with your Sync Token. Each account keeps separate local progress and offline queues. Copy the token on the first device and enter it on the second using the same backend URL. Tokens are credentials; use HTTPS for a remotely hosted backend. Logout restores the previous local profile. Custom word descriptions remain local; their review progress syncs.

Set `REDIS_URL` for shared AI caching and rate limits; unavailable Redis falls back to bounded memory storage. AI responses include `X-Cache: HIT/MISS`. PostgreSQL stores accounts and device history across restarts; memory-only mode lasts for the server process.

## Web platform

All five screens run in the browser: Canvas, roleplay, curriculum, analytics and settings. The layout uses bottom navigation on narrow windows and a sidebar at 900px. Browser profiles and offline review queues are committed atomically to IndexedDB; Android/Linux retain SQLite. Accounts and server URLs isolate progress, queues and credentials. One tab per origin owns the writer lease; other tabs show a retry screen.

```sh
cd app
../tools/flutter --no-version-check build web --no-pub --release --no-web-resources-cdn --pwa-strategy=none
cd ..
python3 tools/serve_web.py --directory app/build/web --port 28190 --api-origin http://127.0.0.1:28191
```

Run the Rust API on port 28191 and open `http://127.0.0.1:28190`. Production hosting needs HTTPS and the same-origin `/api/v1` proxy; see [hosting instructions](deploy/web/README.md). `--dart-define=API_BASE_URL=https://your-api.example/api/v1` is an optional compile-time override. Browser handwriting uses approximate geometry; microphone recognition and TTS depend on browser APIs and installed voices. Speech may use a vendor network service. Denied/unsupported recognition offers explicit typed text. There is no service worker or cold-start offline guarantee; browsers can evict local data.

See [web verification](WEB_PLATFORM_EXECUTION_REPORT.md) and [approved implementation plan](docs/superpowers/plans/2026-10-15-web-platform.md).

## 🏛️ Monorepo Architecture

```
lingua_canvas/
├── app/                           # Flutter application for Android, Linux and Web
│   ├── lib/                       # UI components, ML Kit canvas, FSRS engine, SQLite sync
│   │   ├── screens/               # Canvas practice & study screens
│   │   ├── services/              # DigitalInkEngine, ModelManager, LocalDatabase, SyncCoordinator
│   │   └── widgets/               # HandwritingCanvas with velocity tapering & smoothing
│   ├── test/                      # Unit and widget tests, SQLite and sync regressions
│   └── pubspec.yaml               # Flutter and Dart dependencies
├── server/                        # Rust Axum Backend REST API
│   ├── src/                       # Axum routes, FSRS-4.5 logic, Local AI client, Sync handlers
│   ├── migrations/                # SQLx PostgreSQL schema migrations (lessons, fsrs_cards, review_logs)
│   ├── tests/                     # API integration tests, including opt-in PostgreSQL tests
│   ├── Cargo.toml                 # Rust dependencies (Axum 0.7, Tokio, SQLx 0.8)
│   └── Dockerfile                 # Multi-stage production container build
├── tests/e2e/                     # 4-Tier Opaque-Box E2E Testing Suite (47 tests)
│   ├── run_e2e_tests.sh           # Master test runner with automated server lifecycle
│   ├── tier1_feature_coverage.py  # Feature coverage, git cleanliness, endpoint schemas
│   ├── tier2_boundary_cases.py    # Boundary, corner cases, error codes, offline fallback
│   ├── tier3_cross_feature.py     # Cross-feature state transitions, FSRS lifecycle, concurrency
│   └── tier4_real_world.py        # Real-world workplace IT learning scenarios
├── .github/workflows/             # GitHub Actions Automation
│   ├── ci-backend.yml             # Rust fmt, clippy, test, and dependency audit
│   ├── ci-flutter.yml             # Flutter pub get, dart format, analyze, test
│   └── security-scan.yml          # Gitleaks secret scanning and vulnerability checks
├── docker-compose.yml             # Full-stack orchestration (Server, Postgres, Redis, AI Stub)
├── .env.example                   # Baseline environment variable template
├── .env.development.example       # Development environment configuration
├── .env.staging.example           # Staging environment configuration
├── .env.production.example        # Production environment configuration
└── .gitignore                     # Monorepo git hygiene exclusions
```

---

## 🚀 Quickstart Guide

### Prerequisites
- **Docker** (>= 24.0) & **Docker Compose** (v2 or v5)
- (Optional for native dev) **Rust** 1.85+ / 1.92+ (`rustup`)
- **Flutter** 3.47.6 / **Dart** 3.13.5 (pinned in `.fvmrc`; use `tools/flutter`)
- For Android builds: Android SDK and Java 21
- For Linux desktop builds: Flutter's Linux desktop prerequisites plus `libsecret-1-dev` (Debian/Ubuntu). Running the app requires `libsecret-1-0` and an unlocked Secret Service keyring, such as GNOME Keyring or KWallet with Secret Service enabled.
- (Optional for native dev) **Python** 3.10+ (for E2E tests)

Native account credentials use Android Keystore or Linux Secret Service through
[`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage).
For a Debian/Ubuntu Linux desktop, install the development/runtime prerequisites:

```bash
sudo apt-get install libsecret-1-dev libsecret-1-0 gnome-keyring
```

Start the app within your normal desktop/D-Bus session and unlock its login
keyring. A headless shell without Secret Service cannot exercise native account
storage. If storage is unavailable, restore/unlock the keyring and retry; do not
delete the SQLite database. Credential migration verifies each vault write before
scrubbing plaintext metadata, so a failed migration can be retried while retaining
local lessons, reviews and queued changes. Android automatic backup is disabled
to prevent restoring encrypted credential files without their Keystore keys.

Account settings support device revocation, token rotation and PIN changes.
Device tokens expire after 30 days; rotation requires the current PIN and replaces
that device's token. Changing the PIN revokes other sessions. Existing server
tokens have a seven-day migration/exchange window and should be exchanged by
signing in again. If a remote rotation succeeds but local vault persistence fails,
sign in again with the PIN; learning data remains local. Browser credentials remain
accessible to the browser origin and do not have native Keystore/Secret Service
protection.

### 1. Environment Setup

Copy one of the environment templates according to your target stage:

```bash
# For local development
cp .env.development.example .env

# Or baseline
cp .env.example .env
```

Key environment configurations available:
- `PORT`: Axum REST API server port (default `8080`)
- `DATABASE_URL`: PostgreSQL connection string (`postgres://lingua:lingua_pass@postgres:5432/lingua_canvas`)
- `REDIS_URL`: Redis connection URL (`redis://redis:6379`)
- `AI_ENDPOINT`: Ollama / Local AI generation endpoint (`http://ai-stub:11434/api/generate`)
- `AI_MODEL`: Local LLM model tag (`qwen2.5:3b`)
- `RUST_LOG`: Tracing filter (`info,server=debug`)

### 2. Run with Docker Compose

Launch the complete stack (Axum backend, PostgreSQL 16, Redis 7, Local AI stub):

```bash
docker compose up --build -d
```

Verify service status and healthchecks:

```bash
docker compose ps
```

All services will transition to `healthy`:
- `lingua-postgres`: PostgreSQL ready for SQL queries on port `5432`
- `lingua-redis`: Redis cache ready on port `6379`
- `lingua-ai-stub`: Lightweight mock Ollama server ready on port `11434`
- `lingua-server`: Axum REST API healthy on `http://localhost:8080`

Test backend health endpoint:

```bash
curl http://localhost:8080/api/v1/health
# Returns: {"service":"lingua_canvas_server","status":"healthy","version":"0.1.0"}
```

To stop containers:

```bash
docker compose down
```

### 3. Run the Flutter App

Set the API URL for the device running the app:

```bash
cd app
# Android emulator: the host computer is reachable at 10.0.2.2.
../tools/flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080/api/v1
```

For an Android phone connected over USB, use `adb reverse tcp:8080 tcp:8080` and `http://127.0.0.1:8080/api/v1`. For Linux desktop, run `../tools/flutter run -d linux`. On physical Android devices, use the backend computer's LAN address when USB reverse forwarding is unavailable. Release builds should use HTTPS; Android local HTTP is enabled only in debug builds. Platform support is Android and Linux; ML Kit handwriting recognition requires Android.

Reviews are saved to SQLite before network work. The app retries synchronization at startup, on resume, after a review, and periodically while foregrounded. A successful pull persists its cursor for the next launch.

---

## 🧪 Testing & Verification Guide

### 1. Master 4-Tier E2E Test Suite

The project features a comprehensive opaque-box test runner validating system behavior against live endpoints:

```bash
# Execute all 4 tiers end-to-end
./tests/e2e/run_e2e_tests.sh --all

# Or target specific tiers
./tests/e2e/run_e2e_tests.sh --tier=1  # Feature coverage, git, configs, endpoints
./tests/e2e/run_e2e_tests.sh --tier=2  # Boundary cases, validation errors, offline AI
./tests/e2e/run_e2e_tests.sh --tier=3  # FSRS state transitions, concurrency, compose deps
./tests/e2e/run_e2e_tests.sh --tier=4  # Full IT workplace simulation session
```

### 2. Backend Unit & Integration Tests (Rust)

```bash
cd server

# Verify formatting
cargo fmt -- --check

# Run static analysis
cargo clippy --all-targets -- -D warnings

# Execute test suite
cargo test --all-targets
```

### 3. Frontend Unit & Widget Tests (Flutter)

```bash
cd app

# Verify code formatting
../.toolchains/flutter/3.47.6/flutter/bin/dart format --output=none --set-exit-if-changed .

# Static code analysis
../tools/flutter analyze

# Run widget and unit tests
../tools/flutter test --coverage
```

### 4. Container Configuration Verification

```bash
# Validate docker-compose syntax and service dependency graph
docker compose config
```

---

## 🔒 Security & Git Hygiene

- **Secrets Protection**: Root `.gitignore` prevents leaks of `.env*` credentials, build binaries (`target/`, `.dart_tool/`, `build/`), IDE directories, and keystores.
- **CI Secret Detection**: Automated Gitleaks action scans every commit and pull request.
- **Non-Root Containers**: Backend Dockerfile executes under a dedicated `lingua:lingua` unprivileged system user.
- **Graceful DB Fallback**: Backend gracefully falls back to thread-safe in-memory state if database credentials or network connectivity are unavailable during early bootstrapping.

---

## 📡 Core API Contracts

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/v1/health` | Service health status and version |
| `GET` | `/api/v1/lessons` | List curriculum lessons (filter by `language`, `category`) |
| `GET` | `/api/v1/lessons/:id` | Retrieve single lesson item by UUID |
| `POST` | `/api/v1/fsrs/review` | Submit card review rating (`1: Again`, `2: Hard`, `3: Good`, `4: Easy`) |
| `GET` | `/api/v1/fsrs/due` | Retrieve cards currently due for review |
| `POST` | `/api/v1/ai/roleplay` | Generate workplace roleplay replies, vocabulary and writing challenges |
| `POST` | `/api/v1/ai/dialogue` | Generate structured Japanese or English workplace dialogues |
| `POST` | `/api/v1/sync` | Push queued reviews and completed lessons with review-ID deduplication |
| `GET` | `/api/v1/sync/pull` | Pull account cards/completions using `since_seq`; save `latest_sync_seq` only after reconciliation |
| `POST` | `/api/v1/auth/register` | Create username/PIN account and register device |
| `POST` | `/api/v1/auth/login` | Link device using username/PIN or `sync_token` |
| `GET` | `/api/v1/auth/devices` | List authenticated account devices |

---

Authenticated requests use `X-Sync-Token` or `Authorization: Bearer`; `user_id` only asserts the authenticated identity. Missing credentials retain the shared legacy `default_user` profile. Invalid credentials return 401.

## 📄 License

This project is licensed under the MIT License.
