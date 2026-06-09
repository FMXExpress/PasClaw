/*
 * coi-serviceworker — enable cross-origin isolation on static hosts that
 * cannot set response headers (e.g. GitHub Pages).
 *
 * The container2wasm emulator needs SharedArrayBuffer, which browsers only
 * expose when the page is "cross-origin isolated" (COOP: same-origin +
 * COEP: require-corp). On a host where you control headers you don't need
 * this file — set those headers directly on the host instead.
 * On a header-less host, including this script re-fetches responses through
 * a service worker that adds the headers, then reloads once so isolation
 * takes effect.
 *
 * Minimal faithful reimplementation of gzuidhof/coi-serviceworker (MIT).
 * Note: service workers require a secure context (https:// or
 * http://localhost) — they do NOT run from file://, which is why a
 * double-clicked .html cannot work.
 */
if (typeof window === 'undefined') {
  self.addEventListener('install', () => self.skipWaiting());
  self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
  self.addEventListener('fetch', (event) => {
    const req = event.request;
    // Only GETs need the isolation headers. Leave POSTs and other methods
    // (e.g. Cloudflare's /cdn-cgi/rum analytics beacon) completely alone —
    // their responses often have null-body statuses that can't be rewrapped.
    if (req.method !== 'GET') return;
    if (req.cache === 'only-if-cached' && req.mode !== 'same-origin') return;
    event.respondWith(
      fetch(req)
        .then((res) => {
          // Don't rebuild responses that legally can't carry a body
          // (1xx / 204 / 205 / 304) or opaque/redirect (status 0) —
          // constructing a new Response with a body for those throws
          // "Response with null body status cannot have body".
          if (res.status === 0 || res.type === 'opaqueredirect' ||
              res.status === 101 || res.status === 103 ||
              res.status === 204 || res.status === 205 || res.status === 304) {
            return res;
          }
          const headers = new Headers(res.headers);
          headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
          headers.set('Cross-Origin-Opener-Policy', 'same-origin');
          headers.set('Cross-Origin-Resource-Policy', 'cross-origin');
          return new Response(res.body, {
            status: res.status,
            statusText: res.statusText,
            headers,
          });
        })
        // Never resolve respondWith with undefined (that throws "Failed to
        // convert value to 'Response'"); surface a network error instead.
        .catch((e) => { console.error('[coi]', e); return Response.error(); })
    );
  });
} else {
  (() => {
    // Already isolated (host sent the headers itself) — nothing to do.
    if (window.crossOriginIsolated !== false) return;
    if (!window.isSecureContext) {
      console.warn('[coi] needs https:// or http://localhost — file:// will not work.');
      return;
    }
    if (!navigator.serviceWorker) {
      console.warn('[coi] no service worker support; SharedArrayBuffer unavailable.');
      return;
    }
    navigator.serviceWorker
      .register(window.document.currentScript.src)
      .then((reg) => {
        reg.addEventListener('updatefound', () => window.location.reload());
        if (reg.active && !navigator.serviceWorker.controller) window.location.reload();
      })
      .catch((e) => console.error('[coi] registration failed:', e));
  })();
}
