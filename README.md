# Lingua Canvas 🖌️ 🇯🇵 🇺🇸

[![CI Backend](https://github.com/duyphan0503/lingua_canvas/actions/workflows/ci-backend.yml/badge.svg)](https://github.com/duyphan0503/lingua_canvas/actions/workflows/ci-backend.yml)
[![CI Frontend](https://github.com/duyphan0503/lingua_canvas/actions/workflows/ci-flutter.yml/badge.svg)](https://github.com/duyphan0503/lingua_canvas/actions/workflows/ci-flutter.yml)
[![Security Scan](https://github.com/duyphan0503/lingua_canvas/actions/workflows/security-scan.yml/badge.svg)](https://github.com/duyphan0503/lingua_canvas/actions/workflows/security-scan.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

An enterprise-ready, cross-platform language learning application tailored for IT workplace communication in Japanese (Kanji/Kana, Keigo, tech jargon) and English (Agile rituals, PR reviews, standups). Combines an interactive handwriting canvas, the Free Spaced Repetition Scheduler (FSRS v4.5), and local AI-assisted roleplay dialogues.

---

## 🏛️ Monorepo Architecture

```
lingua_canvas/
├── app/                           # Flutter Frontend Mobile Application
│   ├── lib/                       # UI components, handwriting canvas, FSRS engine
│   ├── test/                      # Unit and widget test suite
│   └── pubspec.yaml               # Flutter SDK (>=3.10.3) & Dart dependencies
├── server/                        # Rust Axum Backend REST API
│   ├── src/                       # Axum routes, FSRS-4.5 logic, AI client, DB pool
│   ├── migrations/                # SQLx PostgreSQL schema migrations
│   ├── tests/                     # Integration tests (ServiceExt::oneshot)
│   ├── Cargo.toml                 # Rust dependencies (Axum 0.7, Tokio, SQLx 0.8)
│   └── Dockerfile                 # Multi-stage production container build
├── tests/e2e/                     # 4-Tier Opaque-Box E2E Testing Suite
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
- (Optional for native dev) **Flutter** 3.38+ / Dart 3.10+
- (Optional for native dev) **Python** 3.10+ (for E2E tests)

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
dart format --output=none --set-exit-if-changed .

# Static code analysis
flutter analyze

# Run widget and unit tests
flutter test --coverage
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
| `POST` | `/api/v1/ai/roleplay` | Generate interactive IT workplace dialogue with breakdown |

---

## 📄 License

This project is licensed under the MIT License.
