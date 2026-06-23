"""
PasClaw BUILD + DEPLOY cog: build + optional Cloudflare-temp deployment.

Variant of /cog-build/. Same multi-iter agent + workspace.zip handshake
as the base; new post-step: after `pasclaw build` completes, scan the
workspace for a `wrangler.toml` and (if present and deploy_to_cloudflare
is on) run `wrangler deploy --temporary` to push the result to a
Cloudflare Workers temporary account.

Why temporary accounts -- https://blog.cloudflare.com/temporary-accounts/:
  - No Cloudflare API token on the cog side. wrangler issues a
    throwaway account when invoked with --temporary.
  - 60-minute lifetime. Auto-deleted unless the human follows the
    claim URL to convert to a real account.
  - Designed exactly for the agent-built-a-thing-let-the-human-verify
    flow: `pasclaw build` writes a Worker -> deploy lands a live URL
    in the prediction output -> caller opens it -> claims if good.

Inputs (new vs cog-build):
  deploy_to_cloudflare : bool   -- default True; set False to skip
                                    the deploy step even if a
                                    wrangler.toml is present.
  wrangler_project_path: str    -- optional explicit path (under the
                                    workspace) to the wrangler project
                                    directory. Default = auto-detect
                                    the first wrangler.toml under
                                    PASCLAW_HOME/workspace/.

Outputs
-------
A list with FOUR file URLs (was two on /cog-build/):
  [0] workspace_<random>.zip       -- same as /cog-build/.
  [1] reply_<random>.txt           -- same as /cog-build/.
  [2] deployed_url_<random>.txt    -- the Cloudflare Workers URL the
                                       agent's output is now serving
                                       at. "(no deployment attempted)"
                                       when deploy_to_cloudflare is
                                       False or no wrangler.toml was
                                       found; "(deploy failed: ...)"
                                       when wrangler returned non-zero.
  [3] claim_url_<random>.txt       -- the Cloudflare dashboard URL the
                                       human follows to convert the
                                       60-minute temp account into a
                                       permanent one. Same blank /
                                       failure placeholders as [2].

A failed or skipped deploy never fails the whole prediction -- the
workspace + reply still come back. The text files in slots [2]/[3]
just carry placeholder strings the caller can detect.

Notes
-----
- wrangler is a Node CLI; the image installs node 20 + wrangler@3 in
  cog.yaml's `run:` block.
- `wrangler deploy --temporary` prints both URLs to stdout. We
  capture the full output, regex out the worker URL (matches
  *.workers.dev) and the claim URL (dash.cloudflare.com path).
  Robust to wrangler text-output drift across versions: we capture
  all https URLs and categorise.
- 4 GiB workspace cap inherited from /cog-build/.
- See /cog-build/predict.py for the rest of the rationale that didn't
  change (Secret inputs, pget, profile handling, mode chaining,
  list[Path] vs BaseModel choice, etc.).
"""

import os
import re
import shutil
import subprocess
import tempfile
import zipfile
from typing import Optional

from cog import BasePredictor, BaseModel, Input, Path, Secret


# 4 GiB. Mirror the Pascal-side cap in PasClaw.Cmd.Build's
# PASCLAW_WORKSPACE_ZIP_CAP so both ends fail with the same message.
WORKSPACE_ZIP_CAP_BYTES = 4 * 1024 * 1024 * 1024


def _secret_str(s: Optional[Secret]) -> str:
    """Extract the cleartext value from an Optional[Secret] input.

    Cog's Secret type wraps Pydantic SecretStr; .get_secret_value() returns
    the underlying string. None inputs (operator left the field blank)
    become empty strings so the rest of the predictor's "if key:" logic
    doesn't need to special-case None.
    """
    if s is None:
        return ""
    return s.get_secret_value()


class Predictor(BasePredictor):
    def setup(self) -> None:
        self.binary_path = "/opt/pasclaw/pasclaw"
        if not os.path.exists(self.binary_path):
            self.binary_path = "pasclaw"

        # `pget` install verification -- non-fatal if absent so a host
        # that opts out can still use the upload-via-cog path.
        self.pget_path = shutil.which("pget") or "/usr/local/bin/pget"
        if not os.path.exists(self.pget_path):
            print(
                f"Warning: pget not found at {self.pget_path}. "
                "Explicit-URL workspace inputs will fall back to single-stream "
                "download via urllib; multi-GB workspaces will be slow."
            )
            self.pget_path = None

        try:
            result = subprocess.run(
                [self.binary_path, "version"],
                capture_output=True, text=True, check=True,
            )
            print(f"PasClaw binary verified: {result.stdout.strip()}")
        except Exception as e:
            print(
                f"Warning: failed to verify pasclaw binary at "
                f"{self.binary_path}: {e}. Ensure it is built and on PATH."
            )

    # ------------------------------------------------------------------
    # download / unzip helpers
    # ------------------------------------------------------------------

    def _download_via_pget(self, url: str, dest: str) -> None:
        """Multi-connection download of a single URL to dest."""
        if self.pget_path is None:
            # Fallback: stream via urllib so the URL path still works
            # without pget. Single-stream so it's slower but functional.
            import urllib.request

            with urllib.request.urlopen(url) as r, open(dest, "wb") as f:
                shutil.copyfileobj(r, f)
            return
        subprocess.run(
            [self.pget_path, url, dest], check=True, capture_output=True
        )

    def _resolve_workspace_in(
        self,
        workspace_in: Optional[Path],
        workspace_in_url: str,
        scratch_dir: str,
    ) -> Optional[str]:
        """Return a local path to the input zip, or None when no input was given.

        Order of precedence (matches the cog convention where explicit URL
        inputs beat the Path-typed input):
          1. workspace_in_url (downloaded via pget)
          2. workspace_in     (already materialised on disk by cog)
        """
        if workspace_in_url:
            local = os.path.join(scratch_dir, "workspace_in.zip")
            print(f"build: downloading workspace via pget: {workspace_in_url}")
            self._download_via_pget(workspace_in_url, local)
            return local
        if workspace_in is not None:
            # cog's Path is os.PathLike -- str() gives the local path.
            return str(workspace_in)
        return None

    # ------------------------------------------------------------------
    # main entry
    # ------------------------------------------------------------------

    def predict(
        self,
        message: str = Input(
            description="Build task. The agent runs up to max_iters "
            "tool-using iterations to satisfy it."
        ),
        max_iters: int = Input(
            description="Tool-loop iteration budget. One iteration ~= one "
            "model response (which may include multiple tool calls).",
            default=50, ge=1, le=500,
        ),
        timeout_seconds: int = Input(
            description="Subprocess timeout in seconds. Default 3600 = 1 h. "
            "Set high for long horizon builds; Replicate enforces its own "
            "container ceiling on top of this.",
            default=3600, ge=30, le=24 * 3600,
        ),
        workspace_in: Optional[Path] = Input(
            description="Workspace archive from a previous build. "
            "Leave empty for a fresh run. Replicate handles both "
            "file-uploads and URL inputs through this. For very "
            "large URL-backed workspaces, prefer workspace_in_url "
            "to get parallel pget download.",
            default=None,
        ),
        workspace_in_url: str = Input(
            description="Explicit URL to a previous-build workspace "
            "archive. Leave empty for a fresh run. When set, "
            "downloaded via pget for parallelism; takes precedence "
            "over workspace_in.",
            default="",
        ),
        openai_api_key: Optional[Secret] = Input(
            description="OpenAI API key. Stored encrypted; never surfaces in logs.",
            default=None,
        ),
        anthropic_api_key: Optional[Secret] = Input(
            description="Anthropic API key. Stored encrypted; never surfaces in logs.",
            default=None,
        ),
        gemini_api_key: Optional[Secret] = Input(
            description="Google Gemini API key. Stored encrypted; never surfaces in logs.",
            default=None,
        ),
        groq_api_key: Optional[Secret] = Input(
            description="Groq API key. Stored encrypted; never surfaces in logs.",
            default=None,
        ),
        openrouter_api_key: Optional[Secret] = Input(
            description="OpenRouter API key. Stored encrypted; never surfaces in logs.",
            default=None,
        ),
        deepseek_api_key: Optional[Secret] = Input(
            description="DeepSeek API key. Stored encrypted; never surfaces in logs.",
            default=None,
        ),

        # --- Local / self-hosted OpenAI-compatible servers ---
        #
        # These three providers exist in PasClaw's catalog with
        # asNone auth -- they don't take API keys, they just need a
        # base URL.  Inside the Replicate container "localhost" is
        # the cog itself, so for any of these to be useful the
        # operator has to expose their local server publicly: ngrok,
        # cloudflared, Tailscale Funnel, a self-hosted box on a
        # public IP, etc.  Leave empty to skip registering that
        # provider.
        ollama_url: str = Input(
            description="Base URL of an Ollama server reachable from the cog "
            "container (e.g. an ngrok tunnel to a laptop's local "
            "instance). Leave empty to skip.",
            default="",
        ),
        lmstudio_url: str = Input(
            description="Base URL of an LM Studio server reachable from the "
            "cog container (default LM Studio port is 1234). Leave "
            "empty to skip.",
            default="",
        ),
        vllm_url: str = Input(
            description="Base URL of a vLLM server reachable from the cog "
            "container (default vLLM port is 8000). Leave empty to skip.",
            default="",
        ),

        # --- Generic OpenAI-compatible escape hatch ---
        #
        # For any provider that's OpenAI-compatible but not surfaced
        # as a dedicated input.  Mistral, xAI, Cerebras, Moonshot,
        # Qwen, Zhipu, Perplexity, NVIDIA NIM, Volcengine, MiniMax,
        # Novita, LiteLLM, MiMo -- all of these are in PasClaw's
        # catalog and speak the OpenAI request shape; the operator
        # just needs to name the kind and URL.  Also handles any
        # in-house OpenAI-compatible endpoint not in the catalog
        # (kind = "openai-compat" gets aliased to "openai" by
        # PasClaw.Providers.Factory.NormalizeProviderKind).
        custom_provider_kind: str = Input(
            description="Catalog kind for a custom provider (e.g. mistral, "
            "xai, cerebras, moonshot, qwen, zhipu, perplexity, "
            "nvidia, volcengine, minimax, novita, litellm, mimo). "
            "Use 'openai-compat' for any other OpenAI-compatible "
            "endpoint not in PasClaw's catalog. Leave empty to skip.",
            default="",
        ),
        custom_provider_url: str = Input(
            description="api_base URL for the custom provider. Required when "
            "custom_provider_kind is set.",
            default="",
        ),
        custom_provider_key: Optional[Secret] = Input(
            description="API key for the custom provider. Stored encrypted; "
            "never surfaces in logs. Leave empty if the endpoint "
            "needs no auth.",
            default=None,
        ),
        custom_provider_model: str = Input(
            description="Default model id for the custom provider. Leave "
            "empty to let the provider pick (some servers route "
            "missing model ids to whatever is currently loaded).",
            default="",
        ),

        provider: str = Input(
            default="",
            description="LLM provider to route through. One of openai, "
            "anthropic, gemini, groq, openrouter, deepseek, ollama, "
            "lmstudio, vllm, or whatever you put in "
            "custom_provider_kind. Empty = first configured "
            "provider wins.",
        ),
        model: str = Input(
            default="",
            description="Override model id. Empty = provider's catalog default.",
        ),
        mode: str = Input(
            description=(
                "What to run. "
                "'build' (default) runs `pasclaw build` -- one-shot multi-iter "
                "agent run with workspace.zip handshake (the historical "
                "behavior of this cog). "
                "'plan' runs `pasclaw plan` -- generates workspace/PLAN.md as "
                "a structured markdown deliverable (Goal / Files / Steps / "
                "Open questions / Risks) and stops. The PLAN.md is inside the "
                "returned workspace zip. "
                "'plan build' chains the two: first generates PLAN.md, then "
                "runs build with PLAN.md auto-loaded into the system prompt "
                "as authoritative guidance. After the build succeeds, the "
                "plan is archived to workspace/memory/plans/<timestamp>.md "
                "and you get a browsable history alongside the artifact. "
                "'plan build goal' is the same as 'plan build' but the build "
                "step uses the Ralph judge loop (parses '## Goal' from "
                "PLAN.md as the objective; iterations pump until the judge "
                "model says MET / FAILED, capped by --goal-max-iters)."
            ),
            choices=["build", "plan", "plan build", "plan build goal"],
            default="build",
        ),
        profile: str = Input(
            default="max-build",
            description="PasClaw config profile applied on top of stock "
            "defaults. `max-build` (default) turns on web_fetch, "
            "vector_search, auto_router, prompt_cache, task-aware "
            "memory orientation, promptware guard, the self-improving-"
            "skills suite, and bumps tool_output_cap to 16 KB -- the "
            "richest unattended-build toolset. (Note: web_search is a "
            "max-build *flag*, but the tool only registers when "
            "PasClaw is also configured with a search provider. This "
            "cog doesn't supply one, so web_search isn't available "
            "out of the box -- use web_fetch.) Other choices: "
            "`baseline` (everything off, useful for A/B), `low-token` "
            "(cheaper, smaller context window), `security` (workspace "
            "restriction + shell deny + private-network block), "
            "`all-on` (max-build plus every remaining flag flipped "
            "on). Empty to skip profile application.",
        ),
        deploy_to_cloudflare: bool = Input(
            description="After pasclaw build completes, run `wrangler "
            "deploy --temporary` against any wrangler.toml the agent "
            "produced in the workspace. Cloudflare's temporary-accounts "
            "feature (https://blog.cloudflare.com/temporary-accounts/) "
            "gives you a 60-minute throwaway account + a claim URL to "
            "convert it to permanent, with no API key required on the "
            "cog side. Skipped silently if no wrangler.toml is in the "
            "workspace. Set False to skip the deploy step entirely.",
            default=True,
        ),
        wrangler_project_path: str = Input(
            description="Path INSIDE the workspace to the directory "
            "containing wrangler.toml. Default empty = auto-detect "
            "the first wrangler.toml found under "
            "$PASCLAW_HOME/workspace/. Use this when the agent "
            "produces multiple wrangler projects and you want a "
            "specific one deployed.",
            default="",
        ),
    ) -> list[Path]:
        """
        Run `pasclaw build` against the unzipped workspace, then ship the
        resulting PASCLAW_HOME back as workspace_out.zip and the model's
        final reply as reply.txt -- both as separate file URLs.
        """

        # --- collect every configured provider ---
        #
        # Three categories produce entries in providers_list:
        #
        #   1. Cloud providers with an API key (Secret inputs).
        #   2. Local / self-hosted OpenAI-compatible servers with a
        #      URL (no API key -- PasClaw catalog uses asNone auth).
        #   3. The generic escape hatch (custom_provider_kind + url
        #      + optional key + optional model).
        #
        # A provider is "available" if its corresponding input
        # group is populated. `selected_provider` (the operator's
        # `provider` flag, or the first-available fallback) must
        # name one of these.

        # 1. Cloud-key catalog -- shape matches cog/predict.py.
        cloud_keys = {
            "openai":     _secret_str(openai_api_key),
            "anthropic":  _secret_str(anthropic_api_key),
            "gemini":     _secret_str(gemini_api_key),
            "groq":       _secret_str(groq_api_key),
            "openrouter": _secret_str(openrouter_api_key),
            "deepseek":   _secret_str(deepseek_api_key),
        }
        catalog_defaults = {
            "openai":     {"kind": "openai",    "api_base": "https://api.openai.com",                 "model": "gpt-4o-mini"},
            "anthropic":  {"kind": "anthropic", "api_base": "https://api.anthropic.com",              "model": "claude-opus-4-7"},
            "gemini":     {"kind": "gemini",    "api_base": "https://generativelanguage.googleapis.com", "model": "gemini-3.5-flash"},
            "groq":       {"kind": "openai",    "api_base": "https://api.groq.com/openai",            "model": "qwen-max"},
            "openrouter": {"kind": "openai",    "api_base": "https://openrouter.ai/api",              "model": "gpt-4o-mini"},
            "deepseek":   {"kind": "openai",    "api_base": "https://api.deepseek.com",               "model": "deepseek-chat"},
        }

        providers_list = []
        available_providers = []

        # Cloud providers (need an API key).
        for prov_name, api_key in cloud_keys.items():
            if not api_key:
                continue
            spec = catalog_defaults[prov_name]
            providers_list.append({
                "name": prov_name, "kind": spec["kind"],
                "api_base": spec["api_base"], "api_key": api_key,
                "model": spec["model"],
            })
            available_providers.append(prov_name)

        # 2. Local / self-hosted OpenAI-compatible servers (need a URL,
        #    no key).  PasClaw's catalog already has these kinds with
        #    asNone auth, so leaving api_key empty is the right shape.
        local_servers = [
            ("ollama",   ollama_url),
            ("lmstudio", lmstudio_url),
            ("vllm",     vllm_url),
        ]
        for prov_name, url in local_servers:
            if not url:
                continue
            providers_list.append({
                "name": prov_name, "kind": prov_name,
                "api_base": url, "api_key": "",
                # Empty model = PasClaw + the local server figure it
                # out (LM Studio routes missing model ids to the
                # currently-loaded one; Ollama needs an explicit pick
                # via the `model` input or `provider` selection).
                "model": "",
            })
            available_providers.append(prov_name)

        # 3. Generic escape hatch.  The kind goes through PasClaw's
        #    NormalizeProviderKind ("openai-compat" -> "openai"), so
        #    any OpenAI-shaped endpoint not in the named-input set
        #    (mistral, xai, cerebras, moonshot, qwen, zhipu,
        #    perplexity, nvidia, volcengine, minimax, novita,
        #    litellm, mimo, or an in-house gateway) plugs in here.
        custom_kind = custom_provider_kind.lower().strip()
        if custom_kind:
            if not custom_provider_url:
                raise ValueError(
                    "custom_provider_kind is set but "
                    "custom_provider_url is empty. Provide both."
                )
            providers_list.append({
                "name": custom_kind, "kind": custom_kind,
                "api_base": custom_provider_url,
                "api_key": _secret_str(custom_provider_key),
                "model": custom_provider_model,
            })
            available_providers.append(custom_kind)

        if not available_providers:
            raise ValueError(
                "No provider configured. Supply at least one of: a cloud "
                "API key (openai_api_key, anthropic_api_key, ...), a "
                "local-server URL (ollama_url, lmstudio_url, vllm_url), "
                "or the custom_provider_* set."
            )

        # --- pick the active provider ---
        selected_provider = provider.lower().strip() if provider else available_providers[0]
        if selected_provider not in available_providers:
            raise ValueError(
                f"Provider '{selected_provider}' is not configured. "
                f"Configured providers: {available_providers}"
            )

        # If the operator passed a model override AND it's for the
        # selected provider, patch it into providers_list. Same shape
        # the previous code achieved via the per-entry conditional.
        if model:
            for entry in providers_list:
                if entry["name"] == selected_provider:
                    entry["model"] = model
                    break

        # default_model: model override wins; else catalog default for
        # cloud providers; else the providers_list entry's model
        # (covers local + custom).
        default_model = model or catalog_defaults.get(selected_provider, {}).get("model", "")
        if not default_model:
            for entry in providers_list:
                if entry["name"] == selected_provider:
                    default_model = entry["model"]
                    break

        # PasClaw applies the profile (with _inherits resolved) BEFORE
        # this config layer, so any explicit field below wins over the
        # profile's defaults. We deliberately set checkpoints_enabled
        # outside the profile so /undo + /redo work even under profiles
        # that don't enable them (baseline / security).
        #
        # Sandbox fields are NOT seeded here. Codex P2 on PR #304: an
        # explicit sandbox block would override `profile=security`'s
        # hardening (which sets restrict_to_workspace / block_private_
        # networks / etc.). PasClaw's TConfig defaults are already
        # appropriate for a cloud container -- RestrictToWorkspace=False,
        # ShellDenyEnabled=True, BlockPrivateNetworks=True -- and the
        # security profile correctly tightens them when chosen. An
        # operator who wants a custom sandbox can still author a
        # user-shadow profile that sets those fields.
        config_data = {
            "default_provider": selected_provider,
            "default_model":    default_model,
            "providers":        providers_list,
            "render_markdown":  False,
            "stats_collection_enabled": False,
            "checkpoints_enabled": True,    # zpaq backend: /undo + /redo survive the zip round-trip
        }

        # Apply the profile when non-empty. PasClaw's selection
        # precedence (PasClaw.Config.LoadConfig) is:
        #   1. --profile CLI flag           (we don't use this)
        #   2. PASCLAW_PROFILE env var      (we don't use this either)
        #   3. "profile" field in config.json   <-- this path
        #   4. None
        # Setting it in the seeded config means a fresh run gets the
        # richer toolset; the operator's `profile` override flows
        # through unchanged for baseline / low-token / security / etc.
        profile_normalised = profile.strip()
        if profile_normalised:
            config_data["profile"] = profile_normalised

        # --- workspace handshake setup ---

        with tempfile.TemporaryDirectory(prefix="pasclaw_build_cog_") as scratch:

            in_zip = self._resolve_workspace_in(
                workspace_in, workspace_in_url, scratch
            )

            if in_zip is not None:
                size = os.path.getsize(in_zip)
                if size > WORKSPACE_ZIP_CAP_BYTES:
                    raise ValueError(
                        f"workspace_in is {size} bytes (> "
                        f"{WORKSPACE_ZIP_CAP_BYTES} cap). Split the workspace "
                        "by skill or session before sending."
                    )
                if not zipfile.is_zipfile(in_zip):
                    raise ValueError(
                        "workspace_in is not a valid zip file. "
                        "Did the upload truncate?"
                    )

            home_dir = os.path.join(scratch, "home")
            os.makedirs(home_dir, exist_ok=True)
            out_zip_path = os.path.join(scratch, "workspace_out.zip")

            # Write config.json OUTSIDE home_dir and point PasClaw at it
            # via the PASCLAW_CONFIG env var so API keys never enter the
            # output workspace.zip.  See the in-source comment for the
            # full rationale.
            config_path = os.path.join(scratch, "config.json")
            import json as _json
            with open(config_path, "w") as f:
                _json.dump(config_data, f, indent=2)

            env = os.environ.copy()
            env["PASCLAW_HOME"]   = home_dir
            env["PASCLAW_CONFIG"] = config_path

            # Phase 4 of the plan/build pairing: dispatch on `mode` to
            # decide which pasclaw subcommand(s) to invoke.
            #
            # build              -> pasclaw build
            # plan               -> pasclaw plan
            # plan build         -> pasclaw plan then pasclaw build
            # plan build goal    -> pasclaw plan then pasclaw build --goal
            #
            # For the chained variants, an intermediate "mid_zip"
            # carries PLAN.md from plan -> build through the existing
            # workspace.zip handshake. The build step's workspace-out
            # becomes the cog's final return artifact.
            mode_norm = mode.strip().lower()
            mid_zip_path = os.path.join(scratch, "workspace_mid.zip")
            do_plan  = mode_norm in ("plan", "plan build", "plan build goal")
            do_build = mode_norm in ("build", "plan build", "plan build goal")
            do_goal  = mode_norm == "plan build goal"

            def invoke_pasclaw(subcmd, extra_args, in_zip_arg, out_zip_arg,
                                label):
                """One pasclaw <subcmd> invocation with consistent error
                surfacing. -q suppresses the ASCII banner (else PrintBanner
                would land in reply.txt). Returns the captured stdout text;
                raises on non-zero exit or timeout. """
                cmd_ = [
                    self.binary_path, subcmd,
                    "-q",
                    "-d", message,
                    "--home", home_dir,
                ] + extra_args
                if in_zip_arg is not None:
                    cmd_ += ["--workspace-in", in_zip_arg]
                if out_zip_arg is not None:
                    cmd_ += ["--workspace-out", out_zip_arg]

                print(
                    f"{label}: invoking {self.binary_path} {subcmd} "
                    f"timeout={timeout_seconds}s "
                    f"provider={selected_provider} model={default_model} "
                    f"profile={profile_normalised or '(none)'} "
                    f"workspace_in={'yes' if in_zip_arg else 'no'}"
                )
                try:
                    res = subprocess.run(
                        cmd_, env=env, capture_output=True, text=True,
                        check=True, timeout=timeout_seconds,
                    )
                    return res.stdout.strip()
                except subprocess.CalledProcessError as e:
                    raise RuntimeError(
                        f"pasclaw {subcmd} exited non-zero (mode={mode_norm}).\n"
                        f"STDOUT:\n{e.stdout}\n"
                        f"STDERR:\n{e.stderr}"
                    )
                except subprocess.TimeoutExpired:
                    raise RuntimeError(
                        f"pasclaw {subcmd} timed out after {timeout_seconds}s. "
                        "Re-run with a higher timeout_seconds, or split into "
                        "smaller calls."
                    )

            text_out = ""

            # --- Plan step (runs first for plan / plan build / plan build goal).
            #
            # When chaining, plan writes to mid_zip; build later reads it as
            # workspace-in. For "plan" alone, plan writes directly to the
            # cog's final out_zip.
            if do_plan:
                plan_args = []
                # plan uses its own Pascal-side default max-iters (12); the
                # operator's max_iters input is build's budget, NOT plan's.
                plan_in   = in_zip
                plan_out  = mid_zip_path if do_build else out_zip_path
                text_out  = invoke_pasclaw("plan", plan_args, plan_in,
                                            plan_out, "plan")

            # --- Build step.
            #
            # When chained with plan, reads mid_zip as input. When standalone,
            # reads the original workspace_in. --goal forwards PLAN.md's
            # parsed Goal as the Ralph objective (Phase 3 wiring).
            if do_build:
                build_args = ["--max-iters", str(max_iters)]
                if do_goal:
                    build_args.append("--goal")
                build_in = mid_zip_path if do_plan else in_zip
                # When build runs after plan, the mid_zip is what was just
                # produced -- pass it explicitly. When build runs standalone,
                # in_zip may be None (fresh run).
                if do_plan and not os.path.exists(mid_zip_path):
                    raise RuntimeError(
                        "pasclaw plan claimed to finish but produced no "
                        "intermediate workspace zip; cannot proceed with build."
                    )
                text_out = invoke_pasclaw("build", build_args, build_in,
                                          out_zip_path, "build")

            if not os.path.exists(out_zip_path):
                raise RuntimeError(
                    f"pasclaw {mode_norm} did not produce workspace_out.zip "
                    f"(missing flag? out path unwritable?)."
                )

            # --- persist both outputs outside scratch ---
            #
            # Cog reads the returned Path values AFTER predict() returns,
            # which is AFTER the `with TemporaryDirectory` cleanup. Any
            # file still inside `scratch/` at that point has already been
            # unlinked, and Cog's serializer fails with:
            #
            #   "Failed to read FileOutput ... No such file or directory"
            #
            # The fix is to shutil.move both files to NamedTemporaryFile
            # paths (delete=False) before returning.

            # 1. Workspace zip
            persist_workspace = tempfile.NamedTemporaryFile(
                suffix=".zip", delete=False, prefix="workspace_out_"
            )
            persist_workspace.close()
            shutil.move(out_zip_path, persist_workspace.name)

            # 2. Reply text. Always write something so the file is never
            #    zero-bytes -- some Cog runtimes silently skip empty
            #    file uploads, leaving the caller with a one-element
            #    output list.
            inner_reply = os.path.join(scratch, "reply.txt")
            with open(inner_reply, "w") as f:
                f.write(text_out or
                        "(no reply text captured -- the agent finished "
                        "without a terminating model message; check "
                        "workspace/sessions/<id>.json for tool-call "
                        "history)")

            persist_reply = tempfile.NamedTemporaryFile(
                suffix=".txt", delete=False, prefix="reply_out_"
            )
            persist_reply.close()
            shutil.move(inner_reply, persist_reply.name)

            # ---------- Cloudflare deploy step (BUILD+DEPLOY) ----------
            #
            # Only fire when the operator left deploy_to_cloudflare on
            # AND the agent's output contains a wrangler.toml somewhere.
            # Either condition false -> placeholders go into the URL
            # files so the caller can detect skip-vs-failure-vs-success
            # by inspecting the body.
            #
            # We deliberately do NOT fail the whole prediction on a
            # deploy error: the workspace + reply are still useful
            # artifacts. The two URL slots carry one of:
            #   - the live URL (success)
            #   - "(no deployment attempted)" (skipped)
            #   - "(deploy failed: <stderr tail>)" (wrangler returned non-zero)
            deployed_url = "(no deployment attempted)"
            claim_url    = "(no deployment attempted)"
            if deploy_to_cloudflare:
                deployed_url, claim_url = self._deploy_to_cloudflare(
                    home_dir, wrangler_project_path
                )

            inner_dep_url = os.path.join(scratch, "deployed_url.txt")
            inner_claim   = os.path.join(scratch, "claim_url.txt")
            with open(inner_dep_url, "w") as f: f.write(deployed_url)
            with open(inner_claim,   "w") as f: f.write(claim_url)
            persist_dep = tempfile.NamedTemporaryFile(
                suffix=".txt", delete=False, prefix="deployed_url_"
            )
            persist_dep.close()
            shutil.move(inner_dep_url, persist_dep.name)
            persist_cl = tempfile.NamedTemporaryFile(
                suffix=".txt", delete=False, prefix="claim_url_"
            )
            persist_cl.close()
            shutil.move(inner_claim, persist_cl.name)

            return [
                Path(persist_workspace.name),
                Path(persist_reply.name),
                Path(persist_dep.name),
                Path(persist_cl.name),
            ]

    # ------------------------------------------------------------------
    # Cloudflare temporary-deploy helpers
    # ------------------------------------------------------------------

    def _find_wrangler_project(self, home_dir, operator_override):
        """Locate the directory containing wrangler.toml inside the workspace.

        Order of precedence:
          1. operator_override (must be a path RELATIVE to
             $PASCLAW_HOME/workspace/, joined here -- absolute paths
             are rejected so the operator can't escape the workspace)
          2. shallowest wrangler.toml under $PASCLAW_HOME/workspace/

        Returns the project directory (the parent of wrangler.toml), or
        None when nothing matches.
        """
        ws_root = os.path.join(home_dir, "workspace")
        if not os.path.isdir(ws_root):
            return None

        if operator_override:
            # Reject absolute paths -- operator-provided overrides must
            # land inside the workspace, no exceptions.
            ovr = operator_override.lstrip("/")
            candidate = os.path.join(ws_root, ovr)
            if os.path.isfile(os.path.join(candidate, "wrangler.toml")):
                return candidate
            if os.path.isfile(candidate) and candidate.endswith("wrangler.toml"):
                return os.path.dirname(candidate)
            print(
                f"deploy: wrangler_project_path={operator_override!r} "
                f"did not resolve to a wrangler.toml under "
                f"$PASCLAW_HOME/workspace/. Falling back to auto-detect."
            )

        # Auto-detect: shallowest wrangler.toml wins (depth sorts
        # nested projects naturally below repo-root layouts).
        best = None
        best_depth = 1 << 30
        for root, _, files in os.walk(ws_root):
            if "wrangler.toml" in files:
                depth = root[len(ws_root):].count(os.sep)
                if depth < best_depth:
                    best       = root
                    best_depth = depth
        return best

    def _extract_urls(self, blob):
        """Pull every https:// URL out of wrangler's text output.

        wrangler 3.x prints the deployed Worker URL and the claim URL
        as plain text in stdout. Format has drifted between versions,
        so we just scan for the patterns. Returns (deployed, claim);
        either may be empty when wrangler didn't print one.
        """
        urls = re.findall(r'https://[^\s<>"\'`]+', blob)
        deployed = ""
        claim    = ""
        for u in urls:
            # Worker URLs land on *.workers.dev. Skip dashboard /
            # claim URLs even if they share the pattern.
            low = u.lower()
            if ("workers.dev" in low) and ("dash.cloudflare.com" not in low):
                if not deployed:
                    deployed = u
            elif ("dash.cloudflare.com" in low) or ("claim" in low):
                if not claim:
                    claim = u
        return deployed, claim

    def _deploy_to_cloudflare(self, home_dir, operator_override):
        """Run `wrangler deploy --temporary` and parse the URLs out of stdout."""
        proj = self._find_wrangler_project(home_dir, operator_override)
        if proj is None:
            print(
                "deploy: no wrangler.toml found under "
                "$PASCLAW_HOME/workspace/; skipping the deploy step."
            )
            return ("(no wrangler.toml in workspace -- nothing to deploy)",
                    "(no wrangler.toml in workspace -- nothing to deploy)")

        print(f"deploy: running `wrangler deploy --temporary` in {proj}")
        try:
            res = subprocess.run(
                ["wrangler", "deploy", "--temporary"],
                cwd=proj, capture_output=True, text=True,
                timeout=300,    # 5 min cap on the deploy itself
            )
        except subprocess.TimeoutExpired:
            return ("(deploy failed: wrangler timed out after 5 min)",
                    "(deploy failed: wrangler timed out after 5 min)")
        except FileNotFoundError:
            return ("(deploy failed: wrangler CLI not found -- "
                    "rebuild the cog image)",
                    "(deploy failed: wrangler CLI not found -- "
                    "rebuild the cog image)")

        combined = (res.stdout or "") + "\n" + (res.stderr or "")
        if res.returncode != 0:
            tail = combined.strip().splitlines()[-8:] if combined.strip() else []
            return (f"(deploy failed: wrangler exit {res.returncode})\n"
                    + "\n".join(tail),
                    f"(deploy failed: wrangler exit {res.returncode})\n"
                    + "\n".join(tail))

        deployed, claim = self._extract_urls(combined)
        if not deployed:
            return ("(deploy completed but no Workers URL parsed from "
                    "wrangler output -- check the prediction log)\n"
                    + combined.strip()[-500:],
                    claim or
                    "(deploy completed but no claim URL parsed -- "
                    "check the prediction log)")
        if not claim:
            claim = ("(deploy completed but no claim URL parsed -- "
                     "the temp account will auto-delete in 60 minutes)")
        print(f"deploy: live at {deployed}")
        return deployed, claim
