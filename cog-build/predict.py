"""
PasClaw BUILD cog: multi-iteration agent run with workspace.zip handshake.

Inputs
------
  message            : str         -- the build task ("add a --foo flag", ...)
  max_iters          : int         -- tool-loop iteration budget (default 50)
  timeout_seconds    : int         -- subprocess timeout (default 3600 = 1 h)
  workspace_in       : Path?       -- previous-build workspace archive. Cog
                                      handles both upload and URL via Path.
                                      Optional -- leave empty for a fresh run.
  workspace_in_url   : str         -- explicit URL form. When set, takes
                                      precedence over `workspace_in` and is
                                      downloaded with pget for parallelism.
  *_api_key          : Secret?     -- provider credentials. Cog Secret inputs
                                      (https://replicate.com/changelog/
                                      2024-06-07-secret-inputs-for-models)
                                      so keys are stored encrypted and never
                                      surface in the prediction's input log.
  provider, model    : str         -- same as the sibling /cog/ predictor.

Output
------
A list with exactly two file URLs:
  [0] workspace_<random>.zip  -- new PASCLAW_HOME archive. Caller passes
                                  this back as `workspace_in` (or
                                  `workspace_in_url`) next call to continue
                                  building on top of prior state.
  [1] reply_<random>.txt      -- the model's final reply, stdout-captured
                                  from `pasclaw build`. Same shape as
                                  `pasclaw agent -q`. A single HTTP GET
                                  fetches the body for the next-call
                                  decision.

We deliberately do NOT use a Pydantic BaseModel output with `workspace: Path`
+ `text: str`. Cog's nested-Path upload path was flaky in older runtimes
(see https://github.com/replicate/cog issues around BaseModel + Path) and
fell back to base64-encoding the workspace zip inline.  `list[Path]` gets
uploaded reliably -- each entry becomes a CDN URL.

Notes
-----
- Workspace cap: 4 GiB.  Replicate timeouts the upload before that anyway,
  but we fail fast with a clean error if a runaway caller hands us one.
- Everything in PASCLAW_HOME ships back -- tmp/, logs, kb-files/*.bin --
  because the point of the handshake is "ship the whole brain". The
  pasclaw build command honors a small denylist (.git, .DS_Store,
  Thumbs.db, kb.db-journal) to keep zip-build noise out.
- `pget` is invoked for explicit URL inputs only; cog's Path handles
  the regular upload + URL paths transparently.
- `pasclaw build` is passed `-q` so the ASCII banner is suppressed and
  reply.txt contains only the model's final message text.
- API keys are Secret inputs so Replicate's UI and logs mask them.
- HOME is per-prediction AND a SIBLING of PASCLAW_HOME under
  scratch (scratch/tool-home, not scratch/home). Anything the
  agent's tools write under $HOME -- npm caches, ~/.gitconfig,
  ~/.ssh, ~/.cache, pip caches, etc. -- lives in tool-home and
  gets wiped on predict() return by the TemporaryDirectory.
  Critically, HOME is NOT inside PASCLAW_HOME: pasclaw build
  packs the entire PASCLAW_HOME into workspace_out.zip, so if
  HOME lived there too, tool dotfiles would ride workspace.zip
  into the next prediction -- serialising the leak instead of
  isolating it. Cog can keep a built container warm across
  predictions, so without this isolation prediction N-1's
  artifacts would be visible to prediction N. Same shape
  cog-build-deploy gives wrangler.
"""

import os
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
            # Per-prediction OS HOME -- a SIBLING of home_dir, NOT
            # under it. Critical: pasclaw build packs the entire
            # PASCLAW_HOME into workspace_out.zip (only a tiny
            # denylist excludes .git / Thumbs.db / etc.). If HOME
            # also lived inside PASCLAW_HOME, every tool dotfile +
            # cache (~/.npm, ~/.gitconfig, ~/.ssh, ~/.cache/pip,
            # ~/.cargo, ...) would land in the zip and ride the
            # workspace handshake into the next prediction --
            # turning the supposed "isolation" into "now we
            # serialize the leak across the prediction chain."
            # Codex P2 review on PR #339.
            tool_home_dir = os.path.join(scratch, "tool-home")
            os.makedirs(tool_home_dir, exist_ok=True)
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
            # Per-prediction HOME so anything the agent's tools spawn
            # under shell_exec / execute_code (npm, git, pip, cargo,
            # ssh, etc.) writes its dotfiles + caches under THIS
            # prediction's scratch instead of the cog container's
            # actual HOME. On a warm Cog container Replicate keeps
            # the process around between predictions, so without this
            # ~/.npm, ~/.cache/pip, ~/.gitconfig, ~/.ssh, ... from
            # prediction N-1 would be visible to prediction N. Same
            # treatment cog-build-deploy gives wrangler (PR #338).
            # The TemporaryDirectory wipes everything on predict()
            # return, so nothing escapes the scratch boundary.
            env["HOME"] = tool_home_dir
            # XDG paths some tools consult; force them under the
            # per-prediction tool-home for the same reason -- and
            # crucially OUTSIDE PASCLAW_HOME so they don't get
            # serialized into workspace_out.zip.
            env["XDG_CONFIG_HOME"] = os.path.join(tool_home_dir, ".config")
            env["XDG_CACHE_HOME"]  = os.path.join(tool_home_dir, ".cache")
            env["XDG_DATA_HOME"]   = os.path.join(tool_home_dir, ".local", "share")
            env["XDG_STATE_HOME"]  = os.path.join(tool_home_dir, ".local", "state")

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

            # Validate the workspace archive and surface the REAL failure.
            #
            # A run that accomplished nothing -- almost always because every
            # provider call errored (bad key, wrong model id, rate limit,
            # network) -- leaves an empty PASCLAW_HOME. pasclaw exits 0 and
            # packs that as an empty zip; historically it was a corrupt 0-byte
            # file, which Cog then failed to upload with an OPAQUE error that
            # hid the actual cause. The real cause is in the model's reply
            # (text_out), e.g. "gemini error 426: ...". Detect the empty /
            # unreadable archive here and raise WITH that reply, so the
            # prediction fails legibly instead of shipping a useless artifact.
            try:
                with zipfile.ZipFile(out_zip_path) as _zf:
                    _entries = _zf.namelist()
            except zipfile.BadZipFile:
                _entries = None
            if not _entries:
                reply_tail = (text_out or "").strip()[-1500:]
                raise RuntimeError(
                    f"pasclaw {mode_norm} produced an empty workspace -- the run "
                    f"accomplished nothing, so there is no artifact to return. "
                    f"This is almost always a provider/model error. The model's "
                    f"final output was:\n"
                    f"{reply_tail or '(no reply text captured)'}"
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

            return [Path(persist_workspace.name), Path(persist_reply.name)]
