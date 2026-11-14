# PasClaw for Chrome

A Manifest V3 Chrome extension that puts your PasClaw agent in Chrome's side panel. It talks to a running `pasclaw gateway` (or `pasclaw serve`, or the Docker image).

- **Chat**: replies stream from `/v1/chat/completions`. Tool calls (`⏺ read_file(…)` / `⎿ …`) appear as collapsible cards, and Markdown and code blocks are rendered.
- **Page context**: turn on **📄 Page** to attach the active tab's title, URL and text (or your selection) to the next message. Right-click a selection, a page or a link and choose **Ask PasClaw…**.
- **Server-held sessions**: by default each chat is a real PasClaw session (`X-PasClaw-Session` + `session_context`). Only new turns are sent, compaction persists, and the chat appears in `pasclaw session list` and can be continued with `pasclaw resume chrome-…`.
- **Browse mode (page control)**: choose **Browse** in the mode menu and tell PasClaw what to do on the current tab. It reads the page, then clicks, types, picks options, presses keys, scrolls and navigates. It asks you before every action that changes the page. See [Browse mode](#browse-mode) below.
- **Web UI tab**: the gateway's full embedded UI (Memory, Files, MCP, Cron, Skills, Logs, Settings, Stats) runs inside the panel. **↗** opens it in a tab.
- **Plan / Build** mode and a **model** picker that reads `/v1/models`.
- A toolbar badge shows **!** when the gateway can't be reached. **Alt+Shift+P** opens the panel.

## Install

1. Start a gateway: `pasclaw gateway` (default `http://127.0.0.1:8088`), or `docker run -p 8088:8088 fmxexpress/pasclaw`.
2. Open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked** and choose this `chrome-extension/` folder.
3. Click the PasClaw toolbar icon. If your gateway is not at `http://127.0.0.1:8088`, or it needs a token, click **⚙** and use **Test connection**.

Requires Chrome 116 or later. There is no build step: the extension is plain ES modules.

## Browse mode

Browse mode lets PasClaw operate the tab you're on, with your approval.

**Tools.** The model gets these tools:

| Tool | What it does | Asks first? |
|---|---|---|
| `get_page` | Reads the URL, title, interactive elements as numbered refs (`[12] button "Sign in"`) and visible text. Takes an optional filter. | no |
| `scroll` | Scrolls up, down, to the top or bottom, or to an element. | no |
| `wait` | Waits a number of seconds, or until some text appears. | no |
| `click` | Clicks an element. | **yes** |
| `type_text` | Types into a text box, text area or rich-text editor, optionally then pressing Enter. | **yes** |
| `select_option` | Chooses an option in a `<select>`. | **yes** |
| `press_key` | Presses Enter, Escape, the arrow keys and so on. | **yes** |
| `navigate` | Opens a URL, or goes `back`. | **yes, always** |

**Approvals.** Each action that changes the page shows a card in the panel. It says what PasClaw wants to do, on which element and site, and why. It warns you about password fields, form submits and leaving the site. You choose **Allow**, **Allow on *site*** (for the rest of this task) or **Deny**. Navigating always asks. If a page moves to a site the extension can't access yet, PasClaw asks for that site first.

**Stopping.** While a task runs, the tab shows a *PasClaw is controlling this tab* banner with a **Stop** button. The panel's stop button works too.

**Safety.** The model is told that page text is untrusted data, not instructions. It is also told not to enter payment details, and to ask you in plain text before anything irreversible. Your approvals are the real gate.

**How it works.** The agent loop runs in the extension, against the gateway's `/v1/responses` tool passthrough (the route Codex CLI uses). The extension sends the browser tools, runs the calls the model returns in the tab with `chrome.scripting`, and posts the results back.

**Limitations.**
- **PasClaw's own tools are off in this mode.** The passthrough skips them, along with PasClaw's system prompt. In Browse mode the model works only with the page, using PasClaw's provider, keys and fallbacks. Switch back to Build for memory, files, skills and MCP.
- **Separate history.** Browse turns keep their own history in the extension. They don't join the gateway session.
- **Page scope.** It only works on `http(s)` and `file` pages. Content inside cross-origin iframes and closed shadow roots is not visible.
- **No screenshots.** Tool results are text only.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Gateway URL | `http://127.0.0.1:8088` | `localhost` and `127.0.0.1` work without asking. For any other host, Chrome asks once for access to that origin. |
| Gateway token | empty | The value of `PASCLAW_GATEWAY_TOKEN` / `gateway.token`, sent as `Authorization: Bearer …`. It is stored in `chrome.storage.local` for this profile. |
| Page text limit | 20 000 chars | The most page text attached per message. |
| Let PasClaw hold the conversation | on | Turn this off to send the whole history on every request, OpenAI-style (for gateways older than `session_context`). |

## Security notes

- **Token-less gateways.** Without a token, the gateway refuses any request whose `Origin` is not its own. This is `PasClaw.Gateway.Auth.LocalRequestRefusal`, and it stops web pages from driving your agent. Chrome stamps the extension's POSTs with `Origin: chrome-extension://<id>`. The extension therefore installs one `declarativeNetRequest` rule that removes the `Origin` header **only** on requests that **this extension** sends to **the configured gateway URL**. The rule matches `initiatorDomains: [<extension id>]`, so web pages in tabs stay blocked exactly as before. If you set a gateway token, the token is the gate and the rule has no effect. A token is the better choice for any gateway that is not on loopback.
- **`tabs` permission.** This lets the panel see the active tab's title and URL, so it can show what Browse mode will control and ask for the right site. Chrome lists it as "Read your browsing history".
- **Page access.** The extension reads a page only when you ask: the **Page** toggle, or a context-menu entry. It uses `activeTab` for the tab you clicked from. When that isn't enough, it shows **Allow access to this site** and asks for that one origin, never `<all_urls>` up front.
- **Page text is labelled as untrusted.** Attached text is wrapped in a block that says it is page content, not instructions from you. Even so, a hostile page can try prompt injection. Attach pages you trust, and keep `permissions` rules (see `docs/security.md`) on tools such as `shell_exec`.
- **Permission prompts.** The extension does not subscribe to `/v1/desktop/events`. A `permissions` rule that says `ask` is therefore denied during side-panel turns, as it is for any client without a subscriber. Answer prompts in the **Web UI** tab or in `/desktop`.

## Files

```
manifest.json      MV3 manifest (side panel, context menus, DNR, optional host access)
background.js      service worker: panel behaviour, context menus, Origin rule, health badge
sidepanel.html/js  chat + Web UI tabs, Browse-mode approvals
options.html/js    settings + connection test
lib/config.js      settings, gateway fetch, Origin rule, page extractor
lib/markdown.js    escaping Markdown + tool-transcript renderer
lib/icons.js       inline SVG icon set
lib/page-tools.js  Browse-mode tool schemas, in-page snapshot/act/banner functions, executor
lib/agent.js       Browse-mode loop over /v1/responses tool passthrough
ui.css             shared styles (dark/light, colours from the gateway web UI)
icons/             16/32/48/128 px
```
