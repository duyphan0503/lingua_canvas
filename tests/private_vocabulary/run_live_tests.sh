#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

: "${TEST_DATABASE_URL:?Set TEST_DATABASE_URL to a disposable PostgreSQL database named lingua_private_test_*}"
: "${CHROME_EXECUTABLE:?Set CHROME_EXECUTABLE to an installed Chromium/Chrome executable}"
python3 - "$TEST_DATABASE_URL" <<'PY'
import sys
from urllib.parse import urlsplit
url = urlsplit(sys.argv[1])
database = url.path.lstrip("/")
if url.scheme not in ("postgres", "postgresql"):
    sys.exit("Refusing database: TEST_DATABASE_URL must use PostgreSQL")
if url.hostname not in ("localhost", "127.0.0.1", "::1"):
    sys.exit("Refusing database: live integration only accepts loopback PostgreSQL")
if not database.startswith("lingua_private_test_"):
    sys.exit("Refusing database: name must start lingua_private_test_")
PY

API_PORT="${PRIVATE_VOCABULARY_API_PORT:-28241}"
python3 - "$API_PORT" <<'PY'
import socket, sys
sock = socket.socket()
try:
    sock.bind(("127.0.0.1", int(sys.argv[1])))
except OSError as exc:
    sys.exit(f"API port is not available: {exc}")
finally:
    sock.close()
PY

LOG_DIR="$(mktemp -d /tmp/lingua-private-vocabulary.XXXXXX)"
API_PID=''
if [[ -n "${FLUTTER_ROOT:-}" && -x "$FLUTTER_ROOT/bin/flutter" ]]; then
  flutter_bin="$FLUTTER_ROOT/bin/flutter"
else
  flutter_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["flutter"])' "$repo_root/.fvmrc")"
  flutter_bin="$repo_root/.toolchains/flutter/$flutter_version/flutter/bin/flutter"
  if [[ ! -x "$flutter_bin" ]]; then
    flutter_bin="$repo_root/tools/flutter"
  fi
fi
cleanup() {
  if [[ -n "$API_PID" ]]; then
    kill "$API_PID" 2>/dev/null || true
    wait "$API_PID" 2>/dev/null || true
  fi
  echo "Private vocabulary integration logs: $LOG_DIR"
}
trap cleanup EXIT INT TERM

echo "Running strict PostgreSQL live router test."
TEST_DATABASE_URL="$TEST_DATABASE_URL" cargo test \
  --manifest-path server/Cargo.toml \
  --test private_vocabulary_live -- --ignored --nocapture

echo "Building the API server against PostgreSQL."
cargo build --manifest-path server/Cargo.toml --offline --release
DATABASE_URL="$TEST_DATABASE_URL" \
PORT="$API_PORT" \
AI_ENDPOINT='http://127.0.0.1:9' \
AI_FALLBACK_ENABLED=true \
REDIS_URL='' \
RUST_LOG=info \
server/target/release/server >"$LOG_DIR/api.log" 2>&1 &
API_PID=$!

python3 - "$API_PORT" "$LOG_DIR/api.log" <<'PY'
import json, pathlib, sys, time, urllib.request
port, log_path = sys.argv[1], pathlib.Path(sys.argv[2])
url = f"http://127.0.0.1:{port}/api/v1/health"
for _ in range(120):
    try:
        with urllib.request.urlopen(url, timeout=1) as response:
            if response.status == 200:
                break
    except (OSError, ValueError):
        pass
    if log_path.exists() and "PostgreSQL connection pool and migrations ready" not in log_path.read_text(errors="replace"):
        pass
    time.sleep(0.25)
else:
    print(log_path.read_text(errors="replace") if log_path.exists() else "missing API log")
    sys.exit("PostgreSQL-backed API health check timed out")
if "PostgreSQL connection pool and migrations ready" not in log_path.read_text(errors="replace"):
    print(log_path.read_text(errors="replace"))
    sys.exit("API did not confirm PostgreSQL initialization")
PY

export PRIVATE_VOCABULARY_TEST_API_BASE="http://127.0.0.1:$API_PORT/api/v1"
cd app

echo "Running actual SQLite → HTTP → PostgreSQL → second SQLite device integration."
"$flutter_bin" --no-version-check test --no-pub \
  --dart-define="PRIVATE_VOCABULARY_TEST_API_BASE=$PRIVATE_VOCABULARY_TEST_API_BASE" \
  test/integration/private_vocabulary_live_test.dart

echo "Running actual IndexedDB → HTTP → PostgreSQL → second browser device integration."
CHROME_EXECUTABLE="$CHROME_EXECUTABLE" \
  "$flutter_bin" --no-version-check test --no-pub --platform chrome \
  --dart-define="PRIVATE_VOCABULARY_TEST_API_BASE=$PRIVATE_VOCABULARY_TEST_API_BASE" \
  test/integration/private_vocabulary_indexeddb_live_test.dart
