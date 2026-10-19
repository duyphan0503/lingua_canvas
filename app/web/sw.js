/* Bump SHELL_CACHE when the app shell or offline routing contract changes. */
const SHELL_CACHE = 'lingua-shell-v1';
const MAX_CACHE_BYTES = 32 * 1024 * 1024;
const MAX_ENTRY_BYTES = 12 * 1024 * 1024;
const SHELL_URLS = [
  './',
  'index.html',
  'manifest.json',
  'flutter_bootstrap.js',
  'flutter.js',
  'main.dart.js',
  'canvaskit/canvaskit.js',
  'canvaskit/canvaskit.wasm',
  'canvaskit/chromium/canvaskit.js',
  'canvaskit/chromium/canvaskit.wasm',
  'assets/AssetManifest.bin.json',
  'assets/AssetManifest.bin',
  'assets/AssetManifest.json',
  'assets/FontManifest.json',
  'assets/fonts/fallback/Roboto-Regular.ttf',
  'assets/assets/kanjivg/strokes.json',
];

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(SHELL_CACHE);
    await Promise.all(SHELL_URLS.map(async (url) => {
      const request = new Request(new URL(url, self.registration.scope), {
        cache: 'reload',
      });
      const response = await fetch(request);
      if (!response.ok) {
        if (url.startsWith('assets/') || url === 'flutter.js' || url === 'main.dart.js') return;
        throw new Error(`Cannot cache app shell: ${url}`);
      }
      const size = Number(response.headers.get('content-length'));
      if (!Number.isFinite(size) || size < 0 || size > MAX_ENTRY_BYTES) return;
      await cache.put(request, response);
    }));
    await trimCache(cache, '');
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names
      .filter((name) => name.startsWith('lingua-shell-') && name !== SHELL_CACHE)
      .map((name) => caches.delete(name)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== self.location.origin) return;
  // User data, credentials and sync responses must always go to the live API.
  if (url.pathname.includes('/api/')) return;
  if (request.mode === 'navigate') {
    event.respondWith(networkFirstNavigation(request));
    return;
  }
  if (!['script', 'style', 'font', 'image', 'worker'].includes(request.destination)) return;
  event.respondWith(cacheFirstAsset(request));
});

async function networkFirstNavigation(request) {
  const cache = await caches.open(SHELL_CACHE);
  try {
    const response = await fetchWithTimeout(request, 2500);
    if (response.ok) await cache.put(request, response.clone());
    return response;
  } catch (_) {
    return (await cache.match(request)) ||
      (await cache.match(new URL('index.html', self.registration.scope))) ||
      Response.error();
  }
}

async function cacheFirstAsset(request) {
  const cache = await caches.open(SHELL_CACHE);
  const cached = await cache.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  if (response.ok && response.type === 'basic') {
    const size = Number(response.headers.get('content-length'));
    if (Number.isFinite(size) && size >= 0 && size <= MAX_ENTRY_BYTES) {
      await cache.put(request, response.clone());
      await trimCache(cache, request.url);
    }
  }
  return response;
}

async function fetchWithTimeout(request, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(request, { signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function trimCache(cache, newestUrl) {
  const keys = await cache.keys();
  let total = 0;
  const entries = [];
  for (const request of keys) {
    const response = await cache.match(request);
    const size = Number(response?.headers.get('content-length'));
    if (!Number.isFinite(size) || size < 0) continue;
    total += size;
    entries.push({ request, size });
  }
  for (const entry of entries) {
    if (total <= MAX_CACHE_BYTES) break;
    if (entry.request.url === newestUrl) continue;
    await cache.delete(entry.request);
    total -= entry.size;
  }
}
