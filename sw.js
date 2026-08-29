// Minimal service worker — its only job is to make the app installable and
// let the shell reload when briefly offline. It deliberately does NOT try to
// cache Supabase API calls: this is a live, multi-user app, so serving stale
// trade/journal data would be worse than just failing the request offline.
const CACHE_NAME = "a-plus-trades-shell-v1";
const SHELL_URLS = ["./", "./index.html", "./manifest.json", "./icons/icon-192.png", "./icons/icon-512.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_URLS)));
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))))
  );
  self.clients.claim();
});

// Network-first: always try live first so data stays fresh; only fall back
// to the cached shell when there's genuinely no connection.
self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  event.respondWith(fetch(event.request).catch(() => caches.match(event.request)));
});
