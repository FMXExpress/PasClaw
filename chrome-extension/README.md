# PasClaw for Chrome

A Manifest V3 Chrome extension that puts your PasClaw agent in Chrome's side panel. It talks to a running `pasclaw gateway` (or `pasclaw serve`, or the Docker image).

- **Chat**: replies stream from `/v1/chat/completions`. Tool calls (`⏺ read_file(…)` / `⎿ …`) appear as collapsible cards, and Markdown and code blocks are rendered.
- **Page context**: turn on **📄 Page** to attach the active tab's title, URL and text (or your selection) to the next message. Right-click a selection, a page or a link and choose **Ask PasClaw…**.
- **Server-held sessions**: by default each chat is a real PasClaw session (`X-PasClaw-Session` + `session_context`). Only new turns are sent, compaction persists, and the chat appears in `pasclaw session list` and can be continued with `pasclaw resume chrome-…`.
- **Web UI tab**: the gateway's full embedded UI (Memory, Files, MCP, Cron, Skills, Logs, Settings, Stats) runs inside the panel. **↗** opens it in a tab.
- **Plan / Build** mode and a **model** picker that reads `/v1/models`.
- A toolbar badge shows **!** when the gateway can't be reached. **Alt+Shift+P** opens the panel.

## Install

1. Start a gateway: `pasclaw gateway` (default `http://127.0.0.1:8088`), or `docker run -p 8088:8088 fmxexpress/pasclaw`.
2. Open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked** and choose this `chrome-extension/` folder.
3. Click the PasClaw toolbar icon. If your gateway is not at `http://127.0.0.1:8088`, or it needs a token, click **⚙** and use **Test connection**.

Requires Chrome 116 or later. There is no build step: the extension is plain ES modules.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Gateway URL | `http://127.0.0.1:8088` | `localhost` and `127.0.0.1` work without asking. For any other host, Chrome asks once for access to that origin. |
| Gateway token | empty | The value of `PASCLAW_GATEWAY_TOKEN` / `gateway.token`, sent as `Authorization: Bearer …`. It is stored in `chrome.storage.local` for this profile. |
| Page text limit | 20 000 chars | The most page text attached per message. |
| Let PasClaw hold the conversation | on | Turn this off to send the whole history on every request, OpenAI-style (for gateways older than `session_context`). |

## Security notes

- **Token-less gateways.** Without a token, the gateway refuses any request whose `Origin` is not its own. This is `PasClaw.Gateway.Auth.LocalRequestRefusal`, and it stops web pages from driving your agent. Chrome stamps the extension's POSTs with `Origin: chrome-extension://<id>`. The extension therefore installs one `declarativeNetRequest` rule that removes the `Origin` header **only** on requests that **this extension** sends to **the configured gateway URL**. The rule matches `initiatorDomains: [<extension id>]`, so web pages in tabs stay blocked exactly as before. If you set a gateway token, the token is the gate and the rule has no effect. A token is the better choice for any gateway that is not on loopback.
- **Page access.** The extension reads a page only when you ask: the **Page** toggle, or a context-menu entry. It uses `activeTab` for the tab you clicked from. When that isn't enough, it shows **Allow access to this site** and asks for that one origin, never `<all_urls>` up front.
- **Page text is labelled as untrusted.** Attached text is wrapped in a block that says it is page content, not instructions from you. Even so, a hostile page can try prompt injection. Attach pages you trust, and keep `permissions` rules (see `docs/security.md`) on tools such as `shell_exec`.
- **Permission prompts.** The extension does not subscribe to `/v1/desktop/events`. A `permissions` rule that says `ask` is therefore denied during side-panel turns, as it is for any client without a subscriber. Answer prompts in the **Web UI** tab or in `/desktop`.

## Files

```
manifest.json      MV3 manifest (side panel, context menus, DNR, optional host access)
background.js      service worker: panel behaviour, context menus, Origin rule, health badge
sidepanel.html/js  chat + Web UI tabs
options.html/js    settings + connection test
lib/config.js      settings, gateway fetch, Origin rule, page extractor
lib/markdown.js    escaping Markdown + tool-transcript renderer
ui.css             shared styles (dark/light, colours from the gateway web UI)
icons/             16/32/48/128 px
```
