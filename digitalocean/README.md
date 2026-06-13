# PasClaw on DigitalOcean App Platform

A minimal "just basic" deployment scaffolding — Dockerfile + App Spec + entrypoint that runs `pasclaw gateway` as a single web service on DigitalOcean App Platform. About $5/month for the smallest instance.

Deliberately strips the optional layers openclaw's [`openclaw-appplatform`](https://github.com/digitalocean-labs/openclaw-appplatform) wires in (ngrok, Tailscale, Spaces+Restic backup). If you need them, layer them on top of this baseline.

## What you get

One service, one public hostname, **both the web UI and the OpenAI-compatible API** are served from the same URL:

| Path | What's there | Auth |
|---|---|---|
| `GET /` | Embedded web UI HTML (`src/pkg/gateway/webui.html`) | none |
| `GET /v1/health` | Health probe | none (exempt) |
| `GET /v1/version` | Build metadata | none (exempt) |
| `POST /v1/chat/completions` | OpenAI Chat Completions (streaming + non-streaming) | Bearer required |
| `POST /v1/responses` | OpenAI Responses API (string or message-array input) | Bearer required |
| `POST /v1/chat` | PasClaw JSON chat (`{"message":"..."}`) | Bearer required |
| `GET /v1/models` | Model list | Bearer required |
| `GET /v1/status`, `/v1/tools`, `/v1/mcp`, `/v1/cron`, `/v1/skills`, `/v1/memory`, `/v1/fs`, `/v1/logs`, `/v1/stats`, `/v1/config` | Read-only inspection routes | Bearer required |

DO App Platform terminates TLS in front of the container's port 8088; **publicly your endpoint is `https://your-app.ondigitalocean.app/`** (port 443, standard HTTPS). Inside the container the gateway listens on `0.0.0.0:8088`.

- OpenTelemetry traces (opt-in via `OTEL_EXPORTER_OTLP_ENDPOINT`).

## What you don't get (deliberately)

- **Persistent state** by default. `$PASCLAW_HOME` lives in the container's ephemeral disk; sessions, memory, and KB reset on every restart / redeploy. See [Persistent state](#persistent-state) below to opt in.
- **Public tunnel** (ngrok). Not needed — App Platform already gives you a public URL.
- **Private VPN** (Tailscale). Add it yourself if you want to combine PasClaw with a private mesh.
- **Backup** (Spaces + Restic). Wire your own backup of the persistent volume if you take that path.
- **CHEATSHEET / AI-ASSISTED-SETUP / CLAUDE.md.** This README is the docs.

## Files

```
digitalocean/
├── README.md                  ← this file
├── Dockerfile                 ← two-stage FPC build → ~80 MB runtime image
├── entrypoint.sh              ← stamps config.json from template on first boot, execs pasclaw gateway
├── config.template.json       ← config.json with ${VAR_NAME} markers (resolved at LoadConfig)
├── .env.example               ← every env var the App Spec references, with comments
├── Makefile                   ← local `docker build` + `docker run` smoke
└── .do/
    └── app.yaml               ← App Spec
```

## Deploy

### Option A: paste the spec (no `doctl` required)

1. Go to https://cloud.digitalocean.com/apps/new/spec.
2. Paste the contents of [`.do/app.yaml`](./.do/app.yaml). Edit `github.repo` if you forked.
3. On the **Environment Variables** screen, fill in the SECRET-marked vars:
   - `PASCLAW_GATEWAY_TOKEN` — generate with `openssl rand -hex 32`.
   - `ANTHROPIC_API_KEY` — your Anthropic key (`sk-ant-...`).
   - Optional: `OPENAI_API_KEY`, `PASCLAW_BRAVE_API_KEY`, `OTEL_EXPORTER_OTLP_ENDPOINT`.
4. Click **Create Resources**. First build takes ~5 minutes.
5. Wait for the deploy. The dashboard shows a green health badge once `/v1/health` returns 200.
6. Smoke test:
   ```sh
   curl https://your-app.ondigitalocean.app/v1/health
   ```

### Option B: `doctl` CLI

```sh
# Fork the repo and edit digitalocean/.do/app.yaml's github.repo if you
# haven't already.

doctl apps create --spec digitalocean/.do/app.yaml

# Note the App ID returned. Set the secrets:
doctl apps update <app-id> --spec digitalocean/.do/app.yaml
# (the dashboard secrets flow is friendlier; this updates the non-secret bits)

# Tail the build:
doctl apps logs <app-id> --type=build --follow

# Tail the runtime:
doctl apps logs <app-id> --type=run --follow
```

## Using it

Once the deploy is green, the gateway accepts standard OpenAI-compatible calls:

```sh
TOKEN=<your PASCLAW_GATEWAY_TOKEN>
URL=https://your-app.ondigitalocean.app

# Health (unauthenticated — exempt from bearer-token gate)
curl $URL/v1/health

# Chat completion (Authorization: Bearer required)
curl $URL/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","messages":[{"role":"user","content":"hello"}]}'
```

From an OpenAI client (Python / JS / etc.) point `base_url` at `https://your-app.ondigitalocean.app/v1` and pass the gateway token as `api_key`.

The embedded web UI is at `https://your-app.ondigitalocean.app/`. Note: the web UI doesn't yet pass the gateway token from JS to its `/v1/*` fetches, so chat/stats/logs panels return 401 when the token is set. Either leave `PASCLAW_GATEWAY_TOKEN` unset (unauthenticated mode — only safe if the app is behind a private network) or wait for the follow-up that adds web-UI auth.

## Persistent state

The basic config above uses **ephemeral storage**. Every container restart wipes `$PASCLAW_HOME/workspace/` — that means sessions, memory notes, knowledgebase index, OTel trace buffers all reset.

To add a persistent volume, add this under the service in `.do/app.yaml`:

```yaml
    persistent_disk:
      mount_path: /data/pasclaw
      size: 1Gi
```

DO charges ~$0.10/GB/month for the volume on top of the instance cost. 1 GB is plenty for personal use; bump to 5–10 GB if you're indexing large reference corpora into the knowledgebase.

## Cost

| Component | Approximate monthly cost |
|---|---|
| `basic-xxs` instance (512 MB / 1 vCPU) | $5 |
| `basic-xs` instance (1 GB / 1 vCPU) — if you want headroom | $12 |
| `basic-s` instance (2 GB / 2 vCPU) — heavy parallel tool use | $25 |
| 1 GB persistent disk (optional) | ~$1 |
| Bandwidth (egress) | first 100 GB free, then ~$0.01/GB |

For comparison: provider API costs (Anthropic, OpenAI, etc.) typically dwarf the hosting cost.

## Updating

`deploy_on_push: true` in the App Spec means every push to `main` of the configured repo triggers a rebuild + redeploy. Roughly 3 minutes for an incremental build.

To pin to a specific commit, change `branch: main` to `branch: <commit-sha-tag>` and tag manually, or disable `deploy_on_push` and use `doctl apps create-deployment <app-id>` for manual rolls.

## Local testing

The Makefile in this directory builds the image locally and runs it on `localhost:8088`:

```sh
# From the repo root:
make -f digitalocean/Makefile build       # build the image (~5 min first time)

# Copy .env.example -> .env and fill in your real keys
cp digitalocean/.env.example digitalocean/.env
vi digitalocean/.env

make -f digitalocean/Makefile run         # run with --env-file=digitalocean/.env
make -f digitalocean/Makefile health      # curl /v1/health
TOKEN=$(grep PASCLAW_GATEWAY_TOKEN digitalocean/.env | cut -d= -f2) \
  make -f digitalocean/Makefile smoke     # 401 without token, 200 with
```

## What the entrypoint does

On every container start `entrypoint.sh`:

1. Ensures `$PASCLAW_HOME/workspace/` exists.
2. If `$PASCLAW_HOME/config.json` is missing, copies the bundled `config.template.json` into place. The template carries `${VAR_NAME}` markers that PasClaw's config loader resolves from environment variables at startup — so the secrets live in env vars, never in the image.
3. Execs `pasclaw gateway --addr 0.0.0.0 --port $PORT`. The `--addr` / `--port` flags override whatever's in `config.json`, so changes to App Spec env (e.g. switching ports) don't require a config edit.

Want a custom config? Mount your own `config.json` into `$PASCLAW_HOME/config.json` (via the persistent volume) — the entrypoint never clobbers an existing file.

## Security notes

- **`PASCLAW_GATEWAY_TOKEN` is the only thing standing between the public internet and an agent that can read/write files in `$PASCLAW_HOME` and execute shell commands.** Generate a strong one (`openssl rand -hex 32`), keep it secret.
- **Sandbox defaults**: the template enables `sandbox.restrict_to_workspace`, sets `sandbox.workspace` explicitly to `/data/pasclaw/workspace`, and turns on `sandbox.shell_deny_enabled` + `sandbox.block_private_networks`. Even if a model escapes the bearer-token check (which would require the operator to leak the token), it can only touch `/data/pasclaw/workspace/` and `web_fetch` can't reach the DO metadata endpoint at `169.254.169.254`.
- **Provider keys** in the App Spec's `envs:` section are stored encrypted by DO and never written to disk by PasClaw — the `${VAR_NAME}` substitution path resolves at load time, in-memory only.

## Known issues

- **OpenSSL 1.0.2 from snapshot.debian.org.** The vendored Indy only knows about OpenSSL 1.0.x SO names — Bookworm's default `libssl3` doesn't load. The Dockerfile pulls `libssl1.0.2_1.0.2u-1~deb9u8_amd64.deb` from `snapshot.debian.org` (Debian's long-term archive) and `dpkg -i`'s it. If snapshot.debian.org changes its URL pattern in the future, the build fails and the Dockerfile needs the new URL. Symptom of a wrong/missing libssl1.0 at runtime: `EIdOSSLCouldNotLoadSSLLibrary` on the first HTTPS provider call. The longer-term fix is for PasClaw to migrate to a newer Indy variant with `TIdSSLIOHandlerSocketOpenSSL11` — out of scope for this PR.

## See also

- [PasClaw root README](../README.md) — what PasClaw is.
- [`docs/gateway.md`](../docs/gateway.md) — full route table, auth contract, web UI tabs.
- [`docs/configuration.md`](../docs/configuration.md) — every config field PasClaw understands.
- [`docs/security.md`](../docs/security.md) — sandbox details.
- [openclaw-appplatform](https://github.com/digitalocean-labs/openclaw-appplatform) — the reference deployment this is modelled on.
