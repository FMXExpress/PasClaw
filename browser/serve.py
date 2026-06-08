#!/usr/bin/env python3
"""Local launcher for the PasClaw c2w browser bundle.

Serves a directory over http://localhost with the COOP/COEP headers that
WebAssembly + the c2w emulator's SharedArrayBuffer require. This is the
"no-setup" way to try the bundle locally.

    python3 browser/serve.py [dir] [port]      # defaults: browser/site 8080

Then open the printed http://localhost URL.

Why a server at all? A double-clicked file:// page CANNOT work: browsers
only enable SharedArrayBuffer under cross-origin isolation, which requires
these headers, which only an http(s) server can send.
"""
import functools
import http.server
import sys

directory = sys.argv[1] if len(sys.argv) > 1 else "browser/site"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8080


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript",
    }

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


if __name__ == "__main__":
    h = functools.partial(Handler, directory=directory)
    print(f"PasClaw c2w bundle: http://localhost:{port}/   (serving {directory}/)")
    print("Ctrl-C to stop.")
    http.server.ThreadingHTTPServer(("127.0.0.1", port), h).serve_forever()
