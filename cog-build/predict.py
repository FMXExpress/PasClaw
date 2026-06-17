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

        config_data = {
            "default_provider": selected_provider,
            "default_model":    default_model,
            "providers":        providers_list,
            "render_markdown":  False,
            "stats_collection_enabled": False,
            "checkpoints_enabled": True,    # zpaq backend: /undo + /redo survive the zip round-trip
            "sandbox": {
                "restrict_to_workspace":      False,
                "allow_read_outside_workspace": True,
                "shell_deny_enabled":         True,
                "block_private_networks":     False,
                "allow_read_paths":           [],
                "allow_write_paths":          [],
                "custom_shell_deny":          [],
            },
        }

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

            # NOTE: `-q` is forwarded so the early-exit banner scan in
            # PasClaw.dpr's IsQuietInvocation skips PrintBanner.
            # Without it, the ASCII PASCLAW banner ends up in
            # result.stdout and pollutes reply.txt.
            cmd = [
                self.binary_path, "build",
                "-q",
                "-d", message,
                "--max-iters", str(max_iters),
                "--home", home_dir,
                "--workspace-out", out_zip_path,
            ]
            if in_zip is not None:
                cmd += ["--workspace-in", in_zip]

            print(
                f"build: invoking {self.binary_path} build "
                f"max_iters={max_iters} timeout={timeout_seconds}s "
                f"provider={selected_provider} model={default_model} "
                f"workspace_in={'yes' if in_zip else 'no'}"
            )

            try:
                result = subprocess.run(
                    cmd, env=env, capture_output=True, text=True,
                    check=True, timeout=timeout_seconds,
                )
                text_out = result.stdout.strip()
            except subprocess.CalledProcessError as e:
                # Surface stdout (model's partial reply, if any) +
                # stderr (PasClaw's diagnostic log lines) so the
                # operator can debug from Replicate logs.
                raise RuntimeError(
                    "pasclaw build exited non-zero.\n"
                    f"STDOUT:\n{e.stdout}\n"
                    f"STDERR:\n{e.stderr}"
                )
            except subprocess.TimeoutExpired:
                raise RuntimeError(
                    f"pasclaw build timed out after {timeout_seconds}s. "
                    "Re-run with a higher timeout_seconds, or split the "
                    "build into smaller calls and re-feed workspace_in."
                )

            if not os.path.exists(out_zip_path):
                raise RuntimeError(
                    "pasclaw build did not produce workspace_out.zip "
                    "(build flag missed? out path unwritable?)."
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
