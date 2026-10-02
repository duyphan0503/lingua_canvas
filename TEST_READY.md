# Lingua Canvas verification record

Date: 2026-10-02. Implementation and functional automated checks are verified; native device checks, live-provider inference, dependency audit clearance and remote integration remain pending.

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
| Android debug APK build | Passed with isolated SDK 36; device installation untested |
| Gen 2 GitNexus full change analysis | Complete without partial/truncated flags; aggregate risk CRITICAL |
| Gitleaks 8.30.1 | No findings in five-commit history and a current source snapshot |
| cargo-audit 0.22.2 after dependency patch | One unpatched optional-lockfile advisory remains: RUSTSEC-2023-0071 (`rsa` 0.9.10) |
| Security workflow audit failure propagation | YAML parsed; simulated audit exit 7 fails the step |

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

The Android debug APK build is verified. iOS compilation, device installation, handwriting recognition accuracy and airplane-mode recovery on a device remain unverified. iOS configuration is aligned to ML Kit's 15.5 minimum and needs macOS/Xcode for its build. Android debug builds allow local HTTP; release builds should use HTTPS.

The debug APK was built using official Android tooling in an isolated SDK with compile SDK 36, NDK 28.2.13676358 and CMake 3.22.1. Network-enabled Gradle resolved the missing dependencies. Its SHA-256 is `9f983261247484ab11709c26e6ae78ed0f9513670277025547d597b50297f5df`; ZIP integrity passed. The artifact is `app/build/app/outputs/flutter-apk/app-debug.apk` (175,895,374 bytes), package `com.linguacanvas.app`, minimum Android SDK 24. Temporary SDK/Gradle/Flutter copies were removed and `local.properties` restored. The host's original `/usr/lib/android-sdk` still lacks platforms/build-tools, so another native build requires completing SDK setup first.

Official Gitleaks 8.30.1 was verified against its release SHA-256. It found no leaks in the five-commit Git history at `e55287c` or a snapshot of current source files (tracked files plus non-ignored additions). Ignored build caches and local credentials are outside this source-scan scope.

`cargo-audit` 0.22.2 scanned 260 lockfile dependencies using the fetched RustSec database. `quinn-proto` was patched from 0.11.14 to 0.11.15 for [RUSTSEC-2026-0185](https://github.com/RustSec/advisory-db/blob/main/crates/quinn-proto/RUSTSEC-2026-0185.md). The audit still exits 1 for [RUSTSEC-2023-0071](https://rustsec.org/advisories/RUSTSEC-2023-0071.html): `rsa` 0.9.10 has no fixed release. It remains in optional SQLx MySQL lock dependencies; `cargo tree --locked --target all -i rsa` prints no active dependency with the current feature set. No advisory was suppressed. The security workflow now propagates audit failures, so this remaining finding will fail its audit step until resolved or an explicit audit policy is adopted.

Real-host checks found no Ollama/llama.cpp binary or process. The expected local provider endpoints refused connections. No Android device was attached, and this Linux host has no Xcode. Follow [DEVICE_VALIDATION.md](DEVICE_VALIDATION.md) for the remaining recognition, offline recovery and fallback-disabled provider scenarios.

The PostgreSQL timestamp cursor currently relies on a global advisory lock, so writes and pulls serialize. Review batches commit per review; retry IDs prevent earlier committed reviews from being applied twice after a later batch failure. In-memory fallback does not survive a server restart.
