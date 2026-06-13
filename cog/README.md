# PasClaw Replicate Cog

This directory contains the Replicate Cog configuration (`cog.yaml`) and prediction shim (`predict.py`) to build, run, and push PasClaw as a serverless machine learning model on Replicate.

## Architecture

*   **Base Image**: Debian 12 Slim (`debian:bookworm-slim`), matching PasClaw's official runtime environment.
*   **Compilation**: Built directly inside the container during Cog image build using the Free Pascal Compiler (FPC).
*   **Security & Isolation**: The Python predict shim runs each incoming request inside an ephemeral, fully-isolated `$PASCLAW_HOME` directory. This guarantees that API keys, cache files, and system states never leak between sequential prediction runs.

## Directory Files

*   `cog.yaml`: The Cog configuration outlining system dependencies, Python environments, and compilation steps.
*   `predict.py`: The Python entrypoint defining optional inputs for various LLM API keys and routing them to `pasclaw agent`.
*   `setup_cog.sh`: Helper script to copy current repository sources into this folder so Cog can access them during build.
*   `.dockerignore`: Excludes compiled Pascal object units (`.o`, `.ppu`, `.dcu`) and cache files to keep image layer footprints low.

## Quick Start

### 1. Stage Current Files
To allow `cog`'s build context to see and compile your local edits, run the setup script:
```bash
./setup_cog.sh
```

### 2. Build the Cog Image
Build the local docker image containing the Compiled binary and dependencies:
```bash
cog build
```

### 3. Test a Prediction Locally
Run a quick test using any of your configured API keys:
```bash
cog predict \
  -i message="What are the main goals of the agent?" \
  -i openai_api_key="your_openai_key"
```

To run on a different provider (e.g. Anthropic, Gemini, DeepSeek, Groq, OpenRouter), supply its respective API key:
```bash
cog predict \
  -i message="Explain quantum computing in one sentence." \
  -i deepseek_api_key="your_deepseek_key"
```

## Pushing to Replicate

Once verified, you can authenticate and publish the model:
```bash
cog login
cog push r8.im/your-username/pasclaw
```
