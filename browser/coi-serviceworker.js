/*
 * coi-serviceworker — enable cross-origin isolation on static hosts that
 * cannot set response headers (e.g. GitHub Pages).
 *
 * The container2wasm emulator needs SharedArrayBuffer, which browsers only
 * expose when the page is "cross-origin isolated" (COOP: same-origin +
 * COEP: require-corp). On a host where you control headers you don't need
 * this file — set those headers directly (see ../serve.py for local use).
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
    if (req.cache === 'only-if-cached' && req.mode !== 'same-origin') return;
    event.respondWith(
      fetch(req)
        .then((res) => {
          if (res.status === 0) return res; // opaque — leave as-is
          const headers = new Headers(res.headers);
          headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
          headers.set('Cross-Origin-Opener-Policy', 'same-origin');
          return new Response(res.body, {
            status: res.status,
            statusText: res.statusText,
            headers,
          });
        })
        .catch((e) => console.error(e))
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
