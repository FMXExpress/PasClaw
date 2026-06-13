# Chat channels

PasClaw can run as a chatbot on multiple messaging platforms. Each channel translates inbound platform-specific messages into the agent loop and outbound agent replies back to the platform.

## Bidirectional channels

| Channel | Transport | Implementation |
|---|---|---|
| **Telegram** | Long-poll bot | `--telegram --token <BOT_TOKEN>` |
| **Discord** | Bot polling | `--discord --token <BOT_TOKEN>` |
| **LINE** | Webhook | `--line` + `$PASCLAW_LINE_TOKEN` + `$PASCLAW_LINE_SECRET` |
| **WhatsApp** | Cloud API webhook | `--whatsapp` + `$PASCLAW_WHATSAPP_{TOKEN,PHONE_ID,VERIFY_TOKEN,APP_SECRET}` |
| **Slack** | Events API webhook + Incoming Webhook reply | `--slack` |
| **Matrix** | REST `/sync` long-poll (federated, self-hostable) | `--matrix` + `$PASCLAW_MATRIX_HOMESERVER` + `$PASCLAW_MATRIX_TOKEN` |
| **IRC** | `TIdIRC` | `--irc` + `$PASCLAW_IRC_{SERVER,NICK,CHANNEL}` |
| **Email** | SMTP send + IMAP poll | `--email`, env-var configured (see `PasClaw.Channels.Email`) |

## Outbound-only

| Channel | Use case |
|---|---|
| **Microsoft Teams** | Incoming Webhook URL — post agent replies into a channel. |
| **Generic Webhook** | Arbitrary POST sink for custom integrations. |

## Running

```sh
pasclaw gateway --telegram --token <BOT_TOKEN>
pasclaw gateway --line
pasclaw gateway --whatsapp
pasclaw gateway --matrix
pasclaw gateway --irc
pasclaw gateway --discord --token <BOT_TOKEN>
pasclaw gateway --slack
pasclaw gateway --email
```

You can run multiple channels in one gateway:

```sh
pasclaw gateway --telegram --token $TG_TOKEN --matrix --irc
```

Each channel polls / serves on its own thread; inbound messages serialise through the agent loop one at a time per channel (parallel across channels).

## Sender identity

Every channel tags inbound messages with a canonical `<platform>:<id>`:

- `slack:U12345`
- `telegram:5551234`
- `matrix:@eli:matrix.org`
- `email:eli@example.com`
- `irc:eli`
- `discord:9876543210`
- `cli:$USER`

The identity rides on `TToolLoopConfig.Identity` from the channel boundary down through hooks and audit logs. Embedder hooks can gate per-sender behaviour via `Self.Identity` (see [Embedding](./embedding.md#hooks)).

## Allowlist

```json
"allow_senders": ["slack:U-eli", "telegram:*", "cli:*"]
```

Patterns: exact ids or `<platform>:*` wildcards. `*` allows anyone (escape hatch). Empty array (default) = no gate.

Each channel calls `IsAllowedSender` before invoking the agent — non-matching senders are dropped at the boundary with a log line, the model never sees them.

## Per-channel notes

### Telegram

Long-poll bot. Set up a bot via @BotFather, get the token, run:

```sh
PASCLAW_TELEGRAM_TOKEN=...
pasclaw gateway --telegram --token $PASCLAW_TELEGRAM_TOKEN
```

Inbound messages: `getUpdates`. Outbound: `sendMessage`. Markdown is rendered (passes `parse_mode: MarkdownV2` and escapes Telegram-specific chars).

### LINE

Webhook. Requires:

- A LINE bot channel with the Messaging API enabled.
- `$PASCLAW_LINE_TOKEN` — channel access token.
- `$PASCLAW_LINE_SECRET` — channel secret (used to verify `X-Line-Signature` on inbound events).

Point LINE's webhook URL at `https://<your-gateway>/v1/line/webhook`.

### WhatsApp

Meta's Cloud API. Requires:

- `$PASCLAW_WHATSAPP_TOKEN` — system-user access token.
- `$PASCLAW_WHATSAPP_PHONE_ID` — phone-number ID (the numeric ID, not the phone number itself).
- `$PASCLAW_WHATSAPP_VERIFY_TOKEN` — user-chosen string used to verify Meta's `GET /webhooks/whatsapp` subscription handshake.
- `$PASCLAW_WHATSAPP_APP_SECRET` — Meta App Secret used to validate `X-Hub-Signature-256` on inbound events.

Point Meta's webhook URL at `https://<your-gateway>/v1/whatsapp/webhook`.

### Slack

Events API webhook + Incoming Webhook reply. Inbound events go to `https://<your-gateway>/v1/slack/events`. The bot replies via the channel's Incoming Webhook URL (set via `app.config` or the per-channel config).

For environments behind a firewall, use Slack's Socket Mode connector running on a public host that proxies to your gateway.

### Matrix

REST `/sync` long-poll against a Matrix homeserver. Federated — works against any Matrix homeserver, public or self-hosted. Required env:

- `$PASCLAW_MATRIX_HOMESERVER` — base URL (e.g. `https://matrix.org`).
- `$PASCLAW_MATRIX_TOKEN` — access token (provisioned out-of-band via `/login` or the homeserver admin UI).

PasClaw auto-joins rooms it gets invited to (configurable). Outbound replies go via `/rooms/<roomId>/send/m.room.message/<txnId>` with `m.text` content.

### IRC

Classic IRC bot using Indy's `TIdIRC`. Required env:

- `$PASCLAW_IRC_SERVER` — hostname (e.g. `irc.libera.chat`).
- `$PASCLAW_IRC_PORT` — port (default `6667`).
- `$PASCLAW_IRC_NICK` — nickname.
- `$PASCLAW_IRC_CHANNEL` — channel to join (must start with `#`).
- `$PASCLAW_IRC_PASSWORD` — optional NickServ / server password.

NickServ handshake is the operator's problem — the channel issues `IDENTIFY` on the connect event but doesn't manage registration.

### Email

SMTP send + IMAP poll. Configured via `--email` and `$PASCLAW_EMAIL_*` env vars (see `PasClaw.Channels.Email` for the full list). One inbound email = one agent turn; the reply is sent back via SMTP to the `From:` address.

Threading is preserved via `In-Reply-To` and `References` headers so a multi-turn email conversation lands in the same thread.

## `send_message` (model-facing)

The agent can also push messages mid-task via the `send_message` tool. Configure named channel sinks in `config.json`:

```json
"channels": [
  { "name": "ops",    "kind": "discord", "target": "https://discord.com/api/webhooks/..." },
  { "name": "alerts", "kind": "slack",   "target": "https://hooks.slack.com/..." }
]
```

The model addresses channels strictly by `name` — it can only reach endpoints the operator pre-declared (no model-supplied URLs).

Registered only when `channels[]` is non-empty.

### Channel kinds for `send_message`

| Kind | Target | Auth source |
|---|---|---|
| `discord` | webhook URL | — |
| `slack` | webhook URL | — |
| `teams` | Microsoft Teams Incoming Webhook URL | — |
| `webhook` | generic webhook URL | — |
| `line` | LINE userId | `$PASCLAW_LINE_TOKEN` |
| `whatsapp` | phone number | `$PASCLAW_WHATSAPP_TOKEN` + `$PASCLAW_WHATSAPP_PHONE_ID` |

These are the same channel kinds [cron](./cron.md#channel-kinds) uses.

## `pasclaw post` (one-shot send)

```sh
pasclaw post discord  <webhook-url> "hello"
pasclaw post slack    <webhook-url> "hello"
pasclaw post teams    <webhook-url> "hello"
pasclaw post webhook  <url>         "hello"
pasclaw post line     <userId>      "hello"
pasclaw post whatsapp <phone>       "hello"
```

No agent loop. Useful for scripts: `pasclaw learn --write && pasclaw post slack $URL "Learn run completed"`.

## See also

- [Configuration](./configuration.md#environment-variables) — channel env vars.
- [Security and sandbox](./security.md#channel-sender-identity) — identity allowlist details.
- [Tools](./tools.md) — `send_message` schema.
