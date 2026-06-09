/* PasClaw browser-bundle UI helper. Additive, framework-free; injected into
   the upstream container2wasm example index.html by browser/build.sh.
   Three jobs:
     1. Guarantee ?net=browser (else the guest has no network egress).
     2. Add a small PasClaw header bar + favicon.
     3. Show a boot screen that auto-dismisses on the first terminal output.
   It only reads/writes page chrome and standard xterm.js DOM; it never
   touches how the emulator boots, so if anything here misbehaves you can
   drop the two injected <link>/<script> tags and the page still works. */
(function () {
  'use strict';

  /* 1) Network mode guard — runs synchronously, before the ~160MB runtime
        starts downloading, so a wrong URL redirects cheaply. */
  try {
    var params = new URLSearchParams(location.search);
    if (params.get('net') !== 'browser') {
      params.set('net', 'browser');
      location.replace(location.pathname + '?' + params.toString() + location.hash);
      return;
    }
  } catch (e) { /* URLSearchParams unsupported — harmless, fall through */ }

  function onReady(fn) {
    if (document.readyState !== 'loading') fn();
    else document.addEventListener('DOMContentLoaded', fn);
  }

  onReady(function () {
    document.title = 'PasClaw';

    /* favicon (data URI, avoids a 404 under COEP) */
    var icon = document.createElement('link');
    icon.rel = 'icon';
    icon.href = 'data:image/svg+xml,' + encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">' +
      '<rect width="16" height="16" rx="3" fill="#050611"/>' +
      '<rect x="3" y="3" width="5" height="10" fill="#20f6ff"/>' +
      '<rect x="8" y="3" width="5" height="10" fill="#ff37d5"/></svg>');
    document.head.appendChild(icon);

    /* 2) header bar */
    var header = document.createElement('header');
    header.className = 'pc-header';
    header.innerHTML =
      '<span class="pc-logo"><span class="pc-blue">PAS</span><span class="pc-red">CLAW</span></span>' +
      '<span class="pc-tag">agent in your browser</span>' +
      '<span class="pc-spacer"></span>' +
      '<a class="pc-link" href="https://github.com/FMXExpress/PasClaw" target="_blank" rel="noopener">GitHub</a>';
    document.body.insertBefore(header, document.body.firstChild);

    /* 3) boot overlay */
    var ov = document.createElement('div');
    ov.className = 'pc-boot';
    ov.innerHTML =
      '<div class="pc-boot-inner">' +
        '<div class="pc-boot-logo"><span class="pc-blue">PAS</span><span class="pc-red">CLAW</span></div>' +
        '<div class="pc-spin"></div>' +
        '<div class="pc-boot-msg">Booting…</div>' +
        '<div class="pc-boot-sub">Downloading the runtime and starting Linux in your browser. ' +
          'First load is large; it is cached afterwards. You’ll be asked for your provider ' +
          'and API key, then dropped into the agent.</div>' +
        '<div class="pc-boot-skip">click anywhere to skip</div>' +
      '</div>';
    document.body.appendChild(ov);

    var done = false;
    function hideBoot() {
      if (done) return;
      done = true;
      ov.classList.add('pc-hide');
      setTimeout(function () { if (ov.parentNode) ov.parentNode.removeChild(ov); }, 400);
    }

    /* dismiss as soon as the terminal prints anything */
    var term = document.getElementById('terminal');
    if (term && window.MutationObserver) {
      var mo = new MutationObserver(function () {
        var rows = term.querySelector('.xterm-rows');
        if (rows && rows.textContent && rows.textContent.trim().length > 0) {
          mo.disconnect();
          hideBoot();
        }
      });
      mo.observe(term, { childList: true, subtree: true, characterData: true });
    }

    /* fallbacks so the overlay can never trap the user */
    ov.addEventListener('click', hideBoot);
    setTimeout(hideBoot, 90000);
  });
})();
