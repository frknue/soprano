// Service worker: keeps the app shell for a start without the Mac in reach. Network first, so a
// new Soprano build and a changed theme show on the next load; /api/* is never cached.

const CACHE = 'soprano-mobile-shell-v2';

const SHELL = [
  '/',
  '/app.css',
  '/manifest.webmanifest',
  '/apple-touch-icon.png',
  '/icon-192.png',
  '/icon-512.png',
  '/js/main.js',
  '/js/api.js',
  '/js/cards.js',
  '/js/diff.js',
  '/js/dom.js',
  '/js/markdown.js',
  '/js/model.js',
  '/js/nav.js',
  '/js/socket.js',
  '/js/store.js',
  '/js/timeline.js',
  '/js/screens/common.js',
  '/js/screens/inbox.js',
  '/js/screens/new-thread.js',
  '/js/screens/pair.js',
  '/js/screens/thread.js',
];

const NETWORK_TIMEOUT = 4000;

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (key !== CACHE) await caches.delete(key);
    }
    await self.clients.claim();
  })());
});

async function networkFirst(request, cacheKey) {
  const cache = await caches.open(CACHE);
  try {
    // Past the HTTP cache: the Mac answers with what its running build ships.
    const response = await Promise.race([
      fetch(new Request(request.url, { cache: 'no-cache', credentials: 'same-origin' })),
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), NETWORK_TIMEOUT)),
    ]);
    if (response.ok && response.type === 'basic') cache.put(cacheKey, response.clone());
    return response;
  } catch (error) {
    const cached = await cache.match(cacheKey);
    if (cached) return cached;
    throw error;
  }
}

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin || url.pathname.startsWith('/api/')) return;
  // The pairing link's /pair is the app shell too.
  const key = request.mode === 'navigate' ? '/' : url.pathname;
  event.respondWith(networkFirst(request, key));
});
