import os
import subprocess
import json
import tempfile
from typing import Any
from cog import BasePredictor, Input, Path

class Predictor(BasePredictor):
    def setup(self) -> None:
        """Verify that the compiled PasClaw binary is present and working"""
        self.binary_path = "/opt/pasclaw/pasclaw"
        if not os.path.exists(self.binary_path):
            self.binary_path = "pasclaw"
        
        try:
            result = subprocess.run([self.binary_path, "version"], capture_output=True, text=True, check=True)
            print(f"PasClaw binary verified: {result.stdout.strip()}")
        except Exception as e:
            print(f"Warning: Failed to verify pasclaw binary: {e}. Ensure it is built and in the path.")

    def run(
        self,
        message: str = Input(
            description="Message or prompt to send to the PasClaw agent."
        ),
        openai_api_key: str = Input(
            description="Optional OpenAI API Key.",
            default=""
        ),
        anthropic_api_key: str = Input(
            description="Optional Anthropic API Key.",
            default=""
        ),
        gemini_api_key: str = Input(
            description="Optional Google Gemini API Key.",
            default=""
        ),
        groq_api_key: str = Input(
            description="Optional Groq API Key.",
            default=""
        ),
        openrouter_api_key: str = Input(
            description="Optional OpenRouter API Key.",
            default=""
        ),
        deepseek_api_key: str = Input(
            description="Optional DeepSeek API Key.",
            default=""
        ),
        provider: str = Input(
            description="LLM provider to run on (openai, anthropic, gemini, groq, openrouter, deepseek). "
                        "If left empty, defaults to the first configured API key.",
            default=""
        ),
        model: str = Input(
            description="Optional model override to use (e.g. gpt-4o, claude-3-5-sonnet, gemini-1.5-pro, deepseek-chat). "
                        "If empty, defaults to the selected provider's standard catalog default model.",
            default=""
        ),
    ) -> str:
        """Run a single interaction with the PasClaw agent using the provided keys and prompt"""
        
        # Mapping input keys to provider configuration
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
                "No API keys provided! You must supply at least one optional API key "
                "(openai_api_key, anthropic_api_key, gemini_api_key, groq_api_key, "
                "openrouter_api_key, or deepseek_api_key) to run the PasClaw agent."
            )
            
        selected_provider = provider
        if not selected_provider:
            # Auto-default to the first provider we have a key for
            selected_provider = available_providers[0]
        else:
            selected_provider = selected_provider.lower().strip()
            if selected_provider not in keys:
                raise ValueError(
                    f"Unsupported provider specified: '{selected_provider}'. "
                    f"Choose from: {list(keys.keys())}"
                )
            if not keys[selected_provider]:
                raise ValueError(
                    f"You selected provider '{selected_provider}', but did not supply its API key."
                )

        # Catalog defaults matching PasClaw.Providers.Catalog.pas
        catalog_defaults = {
            "openai": {"kind": "openai", "api_base": "https://api.openai.com", "model": "gpt-4o-mini"},
            "anthropic": {"kind": "anthropic", "api_base": "https://api.anthropic.com", "model": "claude-opus-4-7"},
            "gemini": {"kind": "gemini", "api_base": "https://generativelanguage.googleapis.com", "model": "gemini-3.5-flash"},
            "groq": {"kind": "openai", "api_base": "https://api.groq.com/openai", "model": "qwen-max"},
            "openrouter": {"kind": "openai", "api_base": "https://openrouter.ai/api", "model": "gpt-4o-mini"},
            "deepseek": {"kind": "openai", "api_base": "https://api.deepseek.com", "model": "deepseek-chat"},
        }

        # Build isolated configuration data
        providers_list = []
        for prov_name, api_key in keys.items():
            if api_key:
                spec = catalog_defaults.get(prov_name, {"kind": prov_name, "api_base": "", "model": ""})
                prov_model = model if (prov_name == selected_provider and model) else spec["model"]
                providers_list.append({
                    "name": prov_name,
                    "kind": spec["kind"],
                    "api_base": spec["api_base"],
                    "api_key": api_key,
                    "model": prov_model
                })

        default_model = model
        if not default_model:
            default_model = catalog_defaults.get(selected_provider, {}).get("model", "")

        # Structure matches TConfig
        config_data = {
            "default_provider": selected_provider,
            "default_model": default_model,
            "providers": providers_list,
            "render_markdown": False,
            "stats_collection_enabled": False,
            "checkpoints_enabled": False,
            "sandbox": {
                "restrict_to_workspace": False,
                "allow_read_outside_workspace": True,
                "shell_deny_enabled": True,
                "block_private_networks": False,
                "allow_read_paths": [],
                "allow_write_paths": [],
                "custom_shell_deny": []
            }
        }

        # Run PasClaw in a clean, fully-isolated temporary environment
        with tempfile.TemporaryDirectory() as temp_home:
            # Write config.json
            config_path = os.path.join(temp_home, "config.json")
            with open(config_path, "w") as f:
                json.dump(config_data, f, indent=2)

            # Create workspace directory
            os.makedirs(os.path.join(temp_home, "workspace"), exist_ok=True)

            # Environment context
            env = os.environ.copy()
            env["PASCLAW_HOME"] = temp_home
            env["PASCLAW_CONFIG"] = config_path

            # Invoke pasclaw agent
            cmd = [self.binary_path, "agent", "-q", "-m", message]
            try:
                # Execute single agent run (120s timeout ensures no hanging in prediction loops)
                result = subprocess.run(cmd, env=env, capture_output=True, text=True, check=True, timeout=120)
                return result.stdout.strip()
            except subprocess.CalledProcessError as e:
                # Package both stdout and stderr for transparent debugging in Replicate's logs
                error_msg = f"Error running PasClaw agent:\nSTDOUT:\n{e.stdout}\nSTDERR:\n{e.stderr}"
                raise RuntimeError(error_msg)
            except subprocess.TimeoutExpired:
                raise RuntimeError("PasClaw agent execution timed out after 120 seconds.")
