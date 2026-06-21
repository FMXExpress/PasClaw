"""
PasClaw RELAY cog: lends a cog deployment's provider compute to a
remote PasClaw gateway via the pull-worker pattern.

What it does
------------
Each prediction call:
  1. Seeds a PasClaw config.json with the operator's chosen provider
     (cloud API key, local-server URL, or custom-OpenAI-compat).
  2. Spawns `pasclaw relay --gateway-url ... --gateway-token ...`
     as a subprocess. The worker opens an SSE long-poll to the
     remote gateway's /v1/relay/poll, drains inference jobs from
     the queue, runs each through the locally-configured provider,
     and POSTs results back to /v1/relay/respond/<id>.
  3. Lets the worker run for `lifetime_seconds`, then sends SIGTERM
     to let the SSE socket close cleanly. Captures stdout, returns
     the log summary as the prediction's text output.

Why this is useful
------------------
Decouples LLM credentials from the gateway. Put a $500-budget OpenAI
key on the cog (which is the credential boundary), point a gateway
on your laptop / home server / CI runner at the cog -- the gateway
gets the LLM's capacity without ever holding the key.

Loop semantics
--------------
One prediction = one polling window. For continuous coverage drop
the cog in a deployment and have a wrapper script call predict()
back-to-back -- each call lasts `lifetime_seconds`, so a 1-hour
deployment with `lifetime_seconds=300` ends up doing 12 calls.

Input
-----
  gateway_url        : str           -- required; remote PasClaw gateway URL
  gateway_token      : Secret        -- required; bearer for /v1/relay/*
  lifetime_seconds   : int           -- how long to poll (default 300)
  worker_id          : str           -- optional identity label
  *_api_key          : Optional[Secret]  -- one of these or a local URL is required
  ollama_url         : str           -- self-hosted OpenAI-compat URL
  lmstudio_url       : str
  vllm_url           : str
  custom_provider_*  : str / Secret  -- generic escape hatch
  provider           : str           -- which configured provider to forward through
  model              : str           -- capability to advertise (default: provider's default)

Output
------
A single str: the captured worker log. Tail it post-hoc to see how many
jobs were dispatched. Use `jobs_served` (search for "completed" lines)
as the success metric.
"""

import os
import shutil
import signal
import subprocess
import tempfile
from typing import Optional

from cog import BasePredictor, Input, Secret


# Grace period after SIGTERM before SIGKILL. The worker just needs to
# close the SSE socket -- which is one TCP teardown -- so 3 s is plenty.
_TERMINATE_GRACE_S = 3


def _secret_str(s: Optional[Secret]) -> str:
    """Extract cleartext from an Optional[Secret] input. None -> ''."""
    if s is None:
        return ""
    return s.get_secret_value()


class Predictor(BasePredictor):
    def setup(self) -> None:
        self.binary_path = "/opt/pasclaw/pasclaw"
        if not os.path.exists(self.binary_path):
            self.binary_path = "pasclaw"
        try:
            result = subprocess.run(
                [self.binary_path, "version"],
                capture_output=True, text=True, check=True,
            )
            print(f"PasClaw binary verified: {result.stdout.strip()}")
        except Exception as e:
            print(
                f"Warning: failed to verify pasclaw binary at "
                f"{self.binary_path}: {e}."
            )

    def predict(
        self,
        gateway_url: str = Input(
            description="Remote PasClaw gateway base URL "
            "(e.g. https://my-gateway.example.com:8888). The worker "
            "opens SSE to <url>/v1/relay/poll and POSTs results to "
            "<url>/v1/relay/respond/<id>.",
        ),
        gateway_token: Secret = Input(
            description="Bearer token for the remote gateway's "
            "PASCLAW_GATEWAY_TOKEN. Stored encrypted on Replicate; "
            "never surfaces in prediction logs.",
        ),
        lifetime_seconds: int = Input(
            description="How long to poll before this prediction "
            "returns. One prediction = one polling window. For "
            "continuous coverage, wrap predict() in a loop or use a "
            "Replicate deployment with a wrapper script. Replicate's "
            "container ceiling caps this on top.",
            default=300, ge=10, le=24 * 3600,
        ),
        worker_id: str = Input(
            description="Worker identity surfaced on the gateway's "
            "/v1/relay/status panel. Leave empty for auto-generated "
            "(`cog-relay-<random>`).",
            default="",
        ),

        # --- Cloud provider keys (any one is enough) ---
        openai_api_key: Optional[Secret] = Input(
            description="OpenAI API key. Stored encrypted.",
            default=None,
        ),
        anthropic_api_key: Optional[Secret] = Input(
            description="Anthropic API key. Stored encrypted.",
            default=None,
        ),
        gemini_api_key: Optional[Secret] = Input(
            description="Google Gemini API key. Stored encrypted.",
            default=None,
        ),
        groq_api_key: Optional[Secret] = Input(
            description="Groq API key. Stored encrypted.",
            default=None,
        ),
        openrouter_api_key: Optional[Secret] = Input(
            description="OpenRouter API key. Stored encrypted.",
            default=None,
        ),
        deepseek_api_key: Optional[Secret] = Input(
            description="DeepSeek API key. Stored encrypted.",
            default=None,
        ),

        # --- Local / self-hosted OpenAI-compatible servers ---
        ollama_url: str = Input(
            description="Base URL of a publicly-reachable Ollama "
            "server (ngrok / cloudflared / public IP). Leave empty "
            "to skip.",
            default="",
        ),
        lmstudio_url: str = Input(
            description="Base URL of a publicly-reachable LM Studio "
            "server (default LM Studio port is 1234). Leave empty "
            "to skip.",
            default="",
        ),
        vllm_url: str = Input(
            description="Base URL of a publicly-reachable vLLM "
            "server. Leave empty to skip.",
            default="",
        ),

        # --- Generic OpenAI-compatible escape hatch ---
        custom_provider_kind: str = Input(
            description="Catalog kind for a custom provider (mistral, "
            "xai, cerebras, moonshot, qwen, zhipu, perplexity, "
            "nvidia, volcengine, minimax, novita, litellm, mimo, or "
            "'openai-compat' for in-house OpenAI-shaped endpoints). "
            "Leave empty to skip.",
            default="",
        ),
        custom_provider_url: str = Input(
            description="api_base URL for the custom provider. "
            "Required when custom_provider_kind is set.",
            default="",
        ),
        custom_provider_key: Optional[Secret] = Input(
            description="API key for the custom provider. Leave "
            "empty if the endpoint needs no auth.",
            default=None,
        ),
        custom_provider_model: str = Input(
            description="Default model id for the custom provider.",
            default="",
        ),

        provider: str = Input(
            description="Which configured provider to forward jobs "
            "through. Empty = first configured wins.",
            default="",
        ),
        model: str = Input(
            description="Capability the worker advertises to the "
            "gateway's queue. Empty = use the provider's default "
            "model. Pass a deliberate non-default string to make this "
            "worker only handle requests for that model id.",
            default="",
        ),
    ) -> str:
        """
        Run `pasclaw relay` for lifetime_seconds, then return the
        captured stdout/stderr as a single log string.
        """

        # ---------- 1. Build provider config (same shape as cog-build).

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

        for prov_name, url in (
            ("ollama",   ollama_url),
            ("lmstudio", lmstudio_url),
            ("vllm",     vllm_url),
        ):
            if not url:
                continue
            providers_list.append({
                "name": prov_name, "kind": prov_name,
                "api_base": url, "api_key": "",
                "model": "",
            })
            available_providers.append(prov_name)

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
                "No provider configured. Supply at least one of: a "
                "cloud API key, a local-server URL, or the "
                "custom_provider_* set. The relay worker forwards "
                "jobs THROUGH a provider -- it needs one."
            )

        selected_provider = (
            provider.lower().strip() if provider else available_providers[0]
        )
        if selected_provider not in available_providers:
            raise ValueError(
                f"Provider '{selected_provider}' is not configured. "
                f"Configured providers: {available_providers}"
            )

        if model:
            for entry in providers_list:
                if entry["name"] == selected_provider:
                    entry["model"] = model
                    break

        default_model = model or catalog_defaults.get(
            selected_provider, {}
        ).get("model", "")
        if not default_model:
            for entry in providers_list:
                if entry["name"] == selected_provider:
                    default_model = entry["model"]
                    break

        # The relay worker never uses workspace / memory / KB / tools
        # locally -- it's a thin Provider.Chat() bridge. Suppress
        # PasClaw subsystems that would just waste setup time.
        config_data = {
            "default_provider": selected_provider,
            "default_model":    default_model,
            "providers":        providers_list,
            "render_markdown":  False,
            "stats_collection_enabled": False,
            "checkpoints_enabled": False,
        }

        # ---------- 2. Spawn `pasclaw relay`.

        with tempfile.TemporaryDirectory(prefix="pasclaw_relay_cog_") as scratch:
            home_dir = os.path.join(scratch, "home")
            os.makedirs(home_dir, exist_ok=True)
            config_path = os.path.join(scratch, "config.json")
            import json as _json
            with open(config_path, "w") as f:
                _json.dump(config_data, f, indent=2)

            env = os.environ.copy()
            env["PASCLAW_HOME"]   = home_dir
            env["PASCLAW_CONFIG"] = config_path
            # PASCLAW_GATEWAY_URL / PASCLAW_GATEWAY_TOKEN are read by
            # `pasclaw relay` when --gateway-url / --gateway-token are
            # omitted; we pass them via flags so the call site is
            # explicit on the command line for log review.

            cmd = [
                self.binary_path, "relay",
                "--gateway-url",   gateway_url,
                "--gateway-token", _secret_str(gateway_token),
            ]
            if worker_id:
                cmd += ["--worker-id", worker_id]
            if model:
                cmd += ["--model", model]

            print(
                f"relay: spawning worker -> {gateway_url} "
                f"(provider={selected_provider}, model={default_model or '(default)'}, "
                f"lifetime={lifetime_seconds}s)"
            )

            # Use Popen so we can send SIGTERM at lifetime expiry
            # rather than relying on subprocess.run's TimeoutExpired
            # SIGKILL. Worker should drain anything in flight, close
            # the SSE socket, log a final line.
            proc = subprocess.Popen(
                cmd, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True,
            )
            try:
                stdout, _ = proc.communicate(timeout=lifetime_seconds)
            except subprocess.TimeoutExpired:
                proc.send_signal(signal.SIGTERM)
                try:
                    stdout, _ = proc.communicate(timeout=_TERMINATE_GRACE_S)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    stdout, _ = proc.communicate()

        # Strip the ASCII banner so the returned log starts at the
        # first informational line. The banner is 6 lines of ANSI
        # escapes that aren't useful in the prediction output.
        lines = (stdout or "").splitlines()
        for i, line in enumerate(lines):
            if "pasclaw relay worker" in line or "relay worker:" in line:
                return "\n".join(lines[i:])
        return stdout or "(no output -- worker exited before producing any logs)"
