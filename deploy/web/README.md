# Web hosting

Build with the pinned SDK from the repository root:

```sh
cd app
../tools/flutter --no-version-check build web --no-pub --release --no-web-resources-cdn --pwa-strategy=none
cd ..
python3 tools/serve_web.py --directory app/build/web --port 28190 --api-origin http://127.0.0.1:28191
```

The development server binds loopback by default. Start the Rust API separately on port 28191. Browser requests use `/api/v1` on the page origin; no CORS setup or embedded credentials are required. Requests are bounded to 1 MiB, upstream responses to 16 MiB and incoming socket I/O to five seconds and upstream I/O to fifteen seconds. The proxy preserves authentication headers but never follows redirects or logs credentials.

The installed web app registers `app/web/sw.js`. It versions its app-shell cache,
keeps API traffic out of Cache Storage, and applies byte and entry limits to
runtime assets. It pre-caches the page entry points and offline KanjiVG guide;
other learned assets enter the cache only when loaded. Bump `SHELL_CACHE` in
`app/web/sw.js` when changing the offline shell contract. Browser storage can be
evicted at any time, so offline access is best effort and sync is still needed.

Run the cold-start offline browser check after building the web release:

```sh
CHROME_EXECUTABLE=/path/to/chromium python3 -m unittest tests.web.test_offline_shell
```

For containers, build from the repository root after compiling the assets:

```sh
docker build -f deploy/web/Dockerfile -t lingua-canvas-web .
```

Attach the container to the API network with the API DNS name `server` on port 8080. Terminate HTTPS at your ingress. IndexedDB and Web Locks require a secure context (HTTPS or localhost). Runtime assets are bundled; entry points are not cached and unversioned assets have a one-hour cache. There is no service worker, installable PWA or cold-start offline guarantee. A browser can evict local storage; sync before clearing site data. Only one tab per origin may write at once.

Run real browser synchronization tests against an explicitly disposable PostgreSQL database:

```sh
TEST_DATABASE_URL=postgres://dp@127.0.0.1:56784/lingua_web_test_local CHROME_EXECUTABLE=/snap/bin/chromium bash tests/web/run_browser_tests.sh
```

The runner requires the database name to begin `lingua_web_test_`, starts its own API/proxy, and cleans up those processes. It does not create or delete databases, deploy containers, or send audio to a speech vendor. Real microphone/voice quality remains manual device QA.
