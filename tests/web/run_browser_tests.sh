#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${TEST_DATABASE_URL:?Set an explicit disposable PostgreSQL URL (database lingua_web_test_*)}"
: "${CHROME_EXECUTABLE:?Set an installed Chromium/Chrome executable}"
export CHROME_EXECUTABLE
python3 - "$TEST_DATABASE_URL" <<'PY'
import sys
from urllib.parse import urlsplit
u = urlsplit(sys.argv[1])
if u.scheme not in ('postgres', 'postgresql') or not u.path.removeprefix('/').startswith('lingua_web_test_'):
    sys.exit('Refusing database: name must start lingua_web_test_')
PY
API_PORT=${WEB_TEST_API_PORT:-28191}
PROXY_PORT=${WEB_TEST_PROXY_PORT:-28190}
python3 - "$API_PORT" "$PROXY_PORT" <<'PY'
import socket, sys
sockets=[]
try:
    for port in sys.argv[1:]:
        s=socket.socket(); s.bind(('127.0.0.1',int(port))); sockets.append(s)
finally:
    for s in sockets: s.close()
PY
cargo build --manifest-path server/Cargo.toml --offline
LOG_DIR=$(mktemp -d /tmp/lingua-web-test.XXXXXX)
API_PID=''
PROXY_PID=''
cleanup() {
  for pid in "$PROXY_PID" "$API_PID"; do
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  done
  echo "Browser integration logs: $LOG_DIR"
}
trap cleanup EXIT INT TERM
DATABASE_URL="$TEST_DATABASE_URL" PORT="$API_PORT" AI_ENDPOINT='http://127.0.0.1:9' AI_FALLBACK_ENABLED=true REDIS_URL='' RUST_LOG=info server/target/debug/server >"$LOG_DIR/api.log" 2>&1 &
API_PID=$!
python3 -B tools/serve_web.py --directory app/build/web --port "$PROXY_PORT" --api-origin "http://127.0.0.1:$API_PORT" >"$LOG_DIR/proxy.log" 2>&1 &
PROXY_PID=$!
python3 - "$PROXY_PORT" <<'PY'
import json, sys, time, urllib.request
url=f'http://127.0.0.1:{sys.argv[1]}/api/v1/health'
for _ in range(80):
    try:
        with urllib.request.urlopen(url, timeout=1) as r:
            data=json.load(r)
            if r.status==200: break
    except (OSError, ValueError): pass
    time.sleep(.25)
else: sys.exit('API/proxy health timeout')
PY
# PostgreSQL startup/migrations must succeed, not silently use memory fallback.
if ! rg -q 'PostgreSQL connection pool and migrations ready' "$LOG_DIR/api.log"; then
  echo 'PostgreSQL initialization was not confirmed; inspect API log' >&2; exit 1
fi
cd app
../tools/flutter --no-version-check test --no-pub --platform chrome \
  --dart-define="WEB_TEST_API_BASE=http://127.0.0.1:$PROXY_PORT/api/v1" \
  test/web/live_sync_test.dart
