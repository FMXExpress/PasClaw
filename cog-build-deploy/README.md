# PasClaw BUILD + DEPLOY cog

A Replicate [cog](https://github.com/replicate/cog) that runs `pasclaw build` to completion, then (optionally) deploys the resulting workspace to a Cloudflare Workers **temporary account** via `wrangler deploy --temporary` — no Cloudflare API token needed on the cog side.

Sibling to [`/cog-build/`](../cog-build/) (the same multi-iter agent + workspace.zip handshake) with one extra post-step. Use this when the agent's task is "build me a Worker" and you want a live URL on the prediction's output for the human to verify before deciding whether to keep it.

## Why temporary accounts

[Cloudflare's temporary accounts feature](https://blog.cloudflare.com/temporary-accounts/) is built for this exact flow:

- No pre-existing Cloudflare account or API token on the deploying side.
- `wrangler deploy --temporary` issues a throwaway account on demand, deploys the Worker, and prints both the live URL and a claim URL.
- 60-minute lifetime. Auto-deleted unless the human follows the claim URL to convert it to a permanent account.

Combined with `pasclaw build`'s "agent writes a Worker" flow you get **task → live URL → human verifies → claim if good** without ever needing to hand the cog a Cloudflare credential.

## Inputs

Every input from `/cog-build/` is inherited unchanged. New on top:

| Name | Type | Default | Description |
|---|---|---|---|
| `deploy_to_cloudflare` | `bool` | `True` | Run `wrangler deploy --temporary` after the build. Set `False` to skip the deploy step entirely. |
| `wrangler_project_path` | `str` | `""` | **Not required.** Path inside the workspace to the directory containing a wrangler config. Default empty = auto-detect the shallowest `wrangler.toml` / `wrangler.json` / `wrangler.jsonc` under `$PASCLAW_HOME/workspace/`. Both `src/my-worker` (a dir) and `src/my-worker/wrangler.jsonc` (the file) work. Absolute paths are stripped so the operator can't escape the workspace. |
| `install_deps_before_deploy` | `bool` | `True` | Run `npm install` (and `npm run build` when the project's `package.json` declares a `build` script) in the wrangler project dir before deploying. **Required for any project with dependencies or a bundler step** — `wrangler deploy` bundles the entry point but does *not* install `node_modules` or run build scripts, so without this a dep-using Worker fails to bundle (`Could not resolve <pkg>`) or deploys broken and crashes at runtime. Set `False` only for a hand-written, zero-dependency single-file Worker. |

The auto-detect path means **no agent-side instructions are needed** — if the build produced any wrangler config (TOML / JSON / JSONC — Cloudflare recommends `.jsonc` for new projects), it'll get found and deployed. If multiple exist (rare), set `wrangler_project_path` explicitly to disambiguate.

**Plan-only predictions never deploy.** When `mode="plan"` is used the build step is skipped, so the deploy block is also skipped even with `deploy_to_cloudflare=True` — a planning-only run can't accidentally publish stale code from a `workspace_in` that happened to contain a wrangler config. Slots `[2]` / `[3]` carry `(no deployment attempted -- plan-only mode)` in that case.

**Dependencies + build step.** `wrangler deploy` bundles the entry point with esbuild but doesn't install `node_modules` or run a project's build script — so a project that imports an npm package, or serves a built `dist/` (Vite, Workers Sites), would otherwise fail to bundle or deploy a broken Worker that crashes at runtime. With `install_deps_before_deploy=True` (the default) the cog runs `npm install` (and `npm run build` if a `build` script is declared) in the project dir first. This was validated against a real Hono + TypeScript Worker: raw deploy fails `Could not resolve "hono"`; install → build → deploy serves both `/` and `/api/hello` live. `node_modules` / `dist` are created in the live workspace *after* `pasclaw build` already wrote `workspace_out.zip`, so they don't bloat the returned archive.

## Outputs

A list of **four** file URLs (was two on `/cog-build/`):

```jsonc
[
  "https://replicate.delivery/.../workspace_out_xxxx.zip",     // [0] new PASCLAW_HOME
  "https://replicate.delivery/.../reply_out_xxxx.txt",         // [1] model's final reply
  "https://replicate.delivery/.../deployed_url_xxxx.txt",      // [2] live Workers URL
  "https://replicate.delivery/.../claim_url_xxxx.txt"          // [3] claim URL
]
```

Slots `[2]` and `[3]` always exist — empty fields would silently disappear on some Cog runtimes, so failures and skips ship a placeholder string instead:

| Body | Meaning |
|---|---|
| `https://...workers.dev` (slot 2) | Successful deploy. URL is live for 60 min. |
| `https://dash.cloudflare.com/...` (slot 3) | Follow this URL to claim the temp account before it expires. |
| `(no deployment attempted)` | `deploy_to_cloudflare=False`. |
| `(no deployment attempted -- plan-only mode)` | `mode="plan"` -- the build step ran no agent loop, so the deploy step is skipped too even with the toggle on. |
| `(no wrangler.toml in workspace -- nothing to deploy)` | Agent didn't produce a wrangler config (TOML / JSON / JSONC); deploy was skipped automatically. |
| `(deploy failed: npm install exit N)\n<tail>` | `npm install` failed in the project dir (bad/unreachable dependency, etc.). Deploy not attempted. |
| `(deploy failed: npm run build exit N)\n<tail>` | The project's `build` script failed. Deploy not attempted. |
| `(deploy failed: wrangler exit N)\n<stderr tail>` | wrangler returned non-zero. Workspace + reply still come back, the prediction itself doesn't fail. |
| `(deploy failed: wrangler timed out after 5 min)` | Deploy hit the 5-minute timeout. |
| `(deploy failed: wrangler CLI not found -- rebuild the cog image)` | The image was built without wrangler. Check `cog.yaml`. |

## Typical control loop

```python
import replicate

out = replicate.run(
    "your-handle/pasclaw-build-deploy",
    input={
        "message": "Write a Cloudflare Worker that returns 'hello' on GET /",
        "anthropic_api_key": {"$secret": "ANTHROPIC_KEY"},
        # deploy_to_cloudflare defaults to True
    },
)

workspace_url, reply_url, deployed_url, claim_url = out
deployed = requests.get(deployed_url).text
claim    = requests.get(claim_url).text

print("workspace:", workspace_url)
print("reply:",     requests.get(reply_url).text)
if deployed.startswith("https://"):
    print(f"Live at:   {deployed}")
    print(f"Claim:     {claim}   (60-min window)")
else:
    print(f"Deploy status: {deployed}")
```

## Test plan if you fork this

The Python helper logic (`_find_wrangler_project`, `_extract_urls`) is unit-testable without a Cog runtime — see the test snippet in the corresponding PR description for the shape. Running the actual deploy requires a real Cog environment with the image built (node + wrangler must land in the image; check `cog.yaml`'s `run:` block for the install steps).

## Isolation between predictions

Cog can keep a built container warm across multiple predictions. Wrangler reuses cached temporary-account state while the claim URL is still valid, so a naive setup would let prediction *N* deploy into prediction *N-1*'s temp account — and surface a claim URL that *N-1*'s caller has access to.

This cog runs wrangler with a **per-prediction `HOME`** under that call's scratch tempdir (which Cog wipes when `predict()` returns), and **strips any inherited Cloudflare auth env** (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_API_KEY`, `CLOUDFLARE_ACCOUNT_ID`, `CF_API_TOKEN`, `WRANGLER_API_TOKEN`, etc.) before invoking the CLI. Each prediction gets a fresh wrangler cache and can only use the `--temporary` flow — a real-account auth env can't accidentally route the deploy into a permanent account.

`CI=1` is also set so wrangler refuses interactive prompts that would hang the subprocess.

## Wrangler version

The image pins `wrangler@^4.102` because `--temporary` requires Wrangler 4.102.0 or later per [Cloudflare's docs](https://blog.cloudflare.com/temporary-accounts/). Earlier majors (including 3.x) fail with "unknown flag `--temporary`" and the whole deploy step dead-letters. Bump the pin only when you've verified the flag shape didn't change.

## What it doesn't do

- **Not a Cloudflare-account-management tool.** It pushes one Worker via temporary accounts; it doesn't manage KV / R2 / D1 bindings, deploy multiple Workers in one shot, or chain into other Cloudflare services. If the agent's task includes those, the operator follows the claim URL after the prediction and configures them by hand.
- **Doesn't claim the account for you.** That's the whole point — the human follows the claim URL when they're ready. Walking the OAuth claim flow programmatically would defeat the security model.
- **Doesn't keep the deploy alive.** 60 minutes after wrangler creates the temp account, Cloudflare deletes everything if no claim has happened. Plan for that in any automation around this cog.
