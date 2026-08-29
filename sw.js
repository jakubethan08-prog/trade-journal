// This service worker turned out to break the app: intercepting the
// cross-origin CDN <script> requests (React/Babel/Supabase-js) caused them
// to fail on reload, producing a blank white page for real users.
// Rather than risk getting the fetch-passthrough edge cases right a second
// time, this version's only job is to remove itself from everyone who
// already has the broken one registered, and reload their tab so it loads
// fresh with no service worker involved at all.
self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      await self.registration.unregister();
      const clientsList = await self.clients.matchAll({ type: "window" });
      clientsList.forEach((client) => client.navigate(client.url));
    })()
  );
});
