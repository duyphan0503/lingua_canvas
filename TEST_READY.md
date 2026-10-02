# Lingua Canvas verification record

Date: 2026-10-02. Local implementation and automated verification are complete; native device checks and remote integration remain pending.

## Verified results

| Check | Result |
| --- | --- |
| Rust unit and API tests, with temporary PostgreSQL 16 | 38 passed |
| Rust formatting, `cargo check`, Clippy with warnings denied | Passed |
| Flutter unit/widget tests | 82 passed |
| Flutter analysis and app-wide Dart formatting | Passed |
| Four E2E tiers against clean PostgreSQL | 47 passed: 14 / 23 / 7 / 3 |
| AI provider, parser and timeout fixture suite | 59 passed |
| Adversarial HTTP challenge, including 100 concurrent requests | 42 passed |
| E2E runner lifecycle unit tests | 3 passed |
| Live Flutter SQLite → Rust HTTP → PostgreSQL smoke | 1 passed |
| iOS 15.5 configuration consistency and whitespace checks | Passed |
| Android debug APK build | Blocked by missing Android SDK platforms/build-tools and uncached Gradle dependencies |
| GitNexus full change analysis | Complete without partial/truncated flags; aggregate risk CRITICAL |

The live Flutter smoke saved one offline review, synchronized its actual payload, confirmed a persisted server card with one FSRS repetition, cleared the local queue, and repeated sync without advancing the card again.

## Reproduce the checks

```bash
cd server
cargo fmt -- --check
cargo check
cargo clippy --all-targets -- -D warnings
# Use a disposable database: these tests write test rows.
TEST_DATABASE_URL=postgres://USER@127.0.0.1:5432/lingua_test cargo test --all-targets
cd ../app
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
cd ..
python3 -B -m unittest discover -s tests/e2e -p 'test_*.py' -v
```

Run E2E against a fresh database. The final verification used port 18086 and a temporary PostgreSQL instance on 55432:

```bash
API_BASE_URL=http://127.0.0.1:18086/api/v1 \
DATABASE_URL=postgres://USER@127.0.0.1:55432/lingua_e2e_final \
AI_ENDPOINT=http://127.0.0.1:9/v1/chat/completions \
AI_FALLBACK_ENABLED=true \
./tests/e2e/run_e2e_tests.sh --all
```

The unavailable AI endpoint exercises curated fallback. The runner builds before starting a server, derives its port from the API URL, writes server logs to a file and stops the server it started. When reusing an existing server, the caller is responsible for building the intended code and using fresh data.

```bash
# Local fixture servers and isolated ports; checks provider JSON and timeouts.
ADVERSARIAL_PORT_OFFSET=10000 python3 -B tests/adversarial_suite.py
# Requires a running backend.
API_BASE_URL=http://127.0.0.1:18080/api/v1 python3 -B tests/adversarial_challenge.py
```

## Verification scope and remaining work

Flutter tests use SQLite FFI and injected HTTP/recognition engines; native ML Kit recognition is not exercised on Linux. The AI fixture suite uses controlled local HTTP providers, while the four E2E tiers exercised offline fallback. A real Ollama/Llama.cpp deployment remains to be checked.

Android/iOS builds, handwriting recognition accuracy and airplane-mode recovery on a device remain unverified. iOS configuration is aligned to ML Kit's 15.5 minimum and needs macOS/Xcode for its build. Android debug builds allow local HTTP; release builds should use HTTPS.

The Android debug build resolved Flutter packages, but no APK was produced. A bounded offline Gradle diagnostic failed because Android Gradle Plugin dependencies were absent from cache. The configured `/usr/lib/android-sdk` contains only `platform-tools`, with no `platforms` or `build-tools`; this Flutter version requests compile SDK 36. Complete the SDK and Gradle dependency setup before retrying `flutter build apk --debug` from `app/`.

A lightweight scan found no common private-key/token patterns in source files; this is not a complete secret or dependency audit. `cargo-audit` and Gitleaks were unavailable locally.

The PostgreSQL timestamp cursor currently relies on a global advisory lock, so writes and pulls serialize. Review batches commit per review; retry IDs prevent earlier committed reviews from being applied twice after a later batch failure. In-memory fallback does not survive a server restart.
