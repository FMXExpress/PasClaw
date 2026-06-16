"""
PasClaw BUILD cog: multi-iteration agent run with workspace.zip handshake.

Inputs
------
  message          : str  -- the build task ("add a --foo flag", "port X to Y", ...)
  max_iters        : int  -- tool-loop iteration budget (default 50)
  timeout_seconds  : int  -- subprocess timeout (default 3600 = 1 h)
  workspace_in     : Path -- optional zip from a previous build. Replicate
                             materialises HTTP URLs and direct uploads via the
                             Path type; large URL-backed inputs are fetched
                             through pget for parallelism.
  workspace_in_url : str  -- explicit URL form. When set, takes precedence
                             over `workspace_in` and is downloaded with pget.
                             Useful when the caller already has the file in
                             cloud storage and wants the fastest fetch path.
  provider, model, ... API keys -- same shape as the sibling /cog/ predictor.

Outputs
-------
A pydantic BaseModel with two fields:
  workspace : Path -- the new workspace.zip (full PASCLAW_HOME, includes
                       memory/, sessions/, kb.db, checkpoints/<id>/archive.zpaq,
                       skills/, plus whatever files the agent wrote into cwd).
                       Caller passes this back as `workspace_in` next call to
                       continue building on top of the prior state.
  text      : str  -- the model's final reply, stdout-captured from
                       `pasclaw build`. Same shape as `pasclaw agent -q`.
                       Useful for deciding whether to feed the workspace
                       back in for another build pass.

Notes
-----
- Workspace cap: 4 GiB. Replicate timeouts the upload before that anyway,
  but we fail fast with a clean error if a runaway caller hands us one.
- Everything in PASCLAW_HOME ships back -- tmp/, logs, kb-files/*.bin --
  because the point of the handshake is "ship the whole brain". The
  pasclaw build command honors a small denylist (.git, .DS_Store,
  Thumbs.db, kb.db-journal) to keep zip-build noise out.
- `pget` is invoked for explicit URL inputs only; cog's Path handles
  the regular upload + URL paths transparently.
"""

import os
import shutil
import subprocess
import tempfile
import zipfile
from typing import Optional

from cog import BasePredictor, BaseModel, Input, Path


# 4 GiB. Mirror the Pascal-side cap in PasClaw.Cmd.Build's
# PASCLAW_WORKSPACE_ZIP_CAP so both ends fail with the same message.
WORKSPACE_ZIP_CAP_BYTES = 4 * 1024 * 1024 * 1024


class Output(BaseModel):
    workspace: Path
    text: str


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
        workspace_in: Path = Input(
            description="Optional workspace.zip from a previous build. "
            "Replicate handles both file-uploads and URL inputs through "
            "this. For very large URL-backed workspaces, prefer "
            "workspace_in_url to get parallel pget download.",
            default=None,
        ),
        workspace_in_url: str = Input(
            description="Optional explicit URL to a workspace.zip. When "
            "set, downloaded via pget for parallelism; takes precedence "
            "over workspace_in.",
            default="",
        ),
        openai_api_key: str = Input(default="", description="Optional"),
        anthropic_api_key: str = Input(default="", description="Optional"),
        gemini_api_key: str = Input(default="", description="Optional"),
        groq_api_key: str = Input(default="", description="Optional"),
        openrouter_api_key: str = Input(default="", description="Optional"),
        deepseek_api_key: str = Input(default="", description="Optional"),
        provider: str = Input(
            default="",
            description="LLM provider (openai/anthropic/gemini/groq/openrouter/deepseek). "
            "Empty = first configured key wins.",
        ),
        model: str = Input(
            default="",
            description="Override model id. Empty = provider's catalog default.",
        ),
    ) -> Output:
        """
        Run `pasclaw build` with the configured provider against the
        unzipped workspace, then ship the resulting PASCLAW_HOME back
        as workspace.zip alongside the model's final reply text.
        """

        # --- validate inputs ---
        keys = {
            "openai": openai_api_key,
            "anthropic": anthropic_api_key,
            "gemini": gemini_api_key,
            "groq": groq_api_key,
            "openrouter": openrouter_api_key,
            "deepseek": deepseek_api_key,
        }
        available_providers = [p for p, k in keys.items() if k]
        if not available_providers:
            raise ValueError(
                "No API keys provided -- supply at least one of "
                "openai_api_key / anthropic_api_key / gemini_api_key / "
                "groq_api_key / openrouter_api_key / deepseek_api_key."
            )

        selected_provider = provider.lower().strip() if provider else available_providers[0]
        if selected_provider not in keys:
            raise ValueError(
                f"Unsupported provider '{selected_provider}'. "
                f"Choose from: {list(keys.keys())}"
            )
        if not keys[selected_provider]:
            raise ValueError(
                f"Provider '{selected_provider}' selected but its API key is empty."
            )

        # Catalog defaults -- same shape as cog/predict.py
        catalog_defaults = {
            "openai":     {"kind": "openai",    "api_base": "https://api.openai.com",                 "model": "gpt-4o-mini"},
            "anthropic":  {"kind": "anthropic", "api_base": "https://api.anthropic.com",              "model": "claude-opus-4-7"},
            "gemini":     {"kind": "gemini",    "api_base": "https://generativelanguage.googleapis.com", "model": "gemini-3.5-flash"},
            "groq":       {"kind": "openai",    "api_base": "https://api.groq.com/openai",            "model": "qwen-max"},
            "openrouter": {"kind": "openai",    "api_base": "https://openrouter.ai/api",              "model": "gpt-4o-mini"},
            "deepseek":   {"kind": "openai",    "api_base": "https://api.deepseek.com",               "model": "deepseek-chat"},
        }

        providers_list = []
        for prov_name, api_key in keys.items():
            if api_key:
                spec = catalog_defaults.get(prov_name, {"kind": prov_name, "api_base": "", "model": ""})
                prov_model = model if (prov_name == selected_provider and model) else spec["model"]
                providers_list.append({
                    "name": prov_name, "kind": spec["kind"],
                    "api_base": spec["api_base"], "api_key": api_key,
                    "model": prov_model,
                })

        default_model = model or catalog_defaults.get(selected_provider, {}).get("model", "")

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

        # Two scratch dirs: one for the (possibly pget-downloaded) input
        # zip, one for the output zip. PASCLAW_HOME is created and
        # managed by `pasclaw build` itself.
        with tempfile.TemporaryDirectory(prefix="pasclaw_build_cog_") as scratch:

            in_zip = self._resolve_workspace_in(
                workspace_in, workspace_in_url, scratch
            )

            # Size cap check (mirrors the Pascal-side
            # PASCLAW_WORKSPACE_ZIP_CAP). Replicate's upload+container
            # limits would catch this too but we fail fast with a
            # clean error message.
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

            # Pre-seed config.json inside the home dir BEFORE `pasclaw
            # build` runs. If the input zip also carries one, the
            # extraction will overwrite ours -- that's fine, the cog
            # caller's intent ("use the workspace I sent") wins. But
            # if there's no input zip we need a config so the agent
            # has provider creds.
            config_path = os.path.join(home_dir, "config.json")
            import json as _json
            with open(config_path, "w") as f:
                _json.dump(config_data, f, indent=2)

            env = os.environ.copy()
            env["PASCLAW_HOME"] = home_dir

            cmd = [
                self.binary_path, "build",
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

            # Move the output zip to a path Replicate will keep alive
            # past the TemporaryDirectory cleanup. cog's Output Path
            # serialiser copies it out as the prediction completes.
            persist = tempfile.NamedTemporaryFile(
                suffix=".zip", delete=False, prefix="workspace_out_"
            )
            persist.close()
            shutil.move(out_zip_path, persist.name)

            return Output(
                workspace=Path(persist.name),
                text=text_out,
            )
