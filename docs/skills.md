# Skills

A skill is a markdown manifest under `$PASCLAW_HOME/workspace/skills/`. The system prompt lists each installed skill (name + one-line description + path); the model reads the full body with `fs_read` when a matching task comes up. Skills tagged `kind: shell` or `kind: prompt` also register as a callable `skill_<name>` tool.

## Commands

```sh
pasclaw skills list
pasclaw skills install owner/repo                         # GitHub repo root
pasclaw skills install owner/repo/path/to/skill           # GitHub subdirectory
pasclaw skills install owner/repo/path/to/skill@v1.2.3    # GitHub at a pinned ref
pasclaw skills install clawhub:code-review                # ClawHub: latest version
pasclaw skills install clawhub:code-review@1.2.3          # ClawHub: pinned version
pasclaw skills search "code review"                       # query both hubs
pasclaw skills install my-skill                           # legacy: record name in config.json
pasclaw skills remove my-skill                            # delete workspace dir + config entry
```

## On-disk layout

PasClaw accepts two layouts:

### Per-directory `SKILL.md` (preferred)

Same format picoclaw, nanobot, ClawHub, and Anthropic agent-skills use:

```
workspace/skills/my-skill/
└── SKILL.md     ← YAML frontmatter + markdown body
```

```yaml
---
name: my-skill
description: One-line summary the model uses to pick the skill
# Omit `kind` for knowledge-only skills (most common); set `kind: shell`
# or `kind: prompt` to register a callable `skill_<name>` tool.
---

# My skill

Markdown body. The system prompt advertises this SKILL.md path; the
model loads the full body with `fs_read` when the matching task comes
up.
```

A copy-pasteable starter lives at [`samples/skills/hello/SKILL.md`](../samples/skills/hello/SKILL.md).

### Legacy single `*.json`

Still loaded for backwards compat. Per-directory `SKILL.md` entries shadow same-named JSON entries; new skills should use the directory layout. JSON shape mirrors the frontmatter:

```json
{
  "name": "my-skill",
  "description": "One-line summary the model uses to pick the skill",
  "kind": "shell",
  "schema": "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}"
}
```

`kind` and `schema` are only needed for callable skills; knowledge-only skills carry just `name` + `description`.

## Skill kinds

| `kind` | Behaviour |
|---|---|
| (omitted) | **Knowledge only.** Body advertised in the system prompt; model reads via `fs_read` on demand. No tool registered. |
| `shell` | **Callable shell skill.** `skill_<name>` tool registered. The model passes JSON args matching `schema`; PasClaw substitutes them into the skill body's shell template and runs the result via the shell backend. |
| `prompt` | **Callable prompt skill.** `skill_<name>` tool registered. The model passes JSON args; PasClaw renders the body as a prompt template, runs one provider request, and returns the response as the tool result. |

`kind: shell` skills participate in the `ShellAllowed` denylist — `rm -rf` inside a skill body is refused identically to inline `shell_exec`.

## Arguments and slash commands

A prompt skill's template can take command-style arguments as well as JSON keys:

| Placeholder | Filled with |
|---|---|
| `{{key}}` | the JSON argument `key` (the model's tool call) |
| `$ARGUMENTS` (or `$0`) | the whole free-text argument string |
| `$1` … `$9` | the Nth token, split like a shell (`"double"` and `'single'` quotes group, `\` escapes); the highest `$N` the template uses absorbs the rest, so `Deploy $1 with $2` given `staging --fast --quiet` sees `$2 = --fast --quiet` |

The free text arrives as the JSON key `arguments`. A template that uses `$ARGUMENTS` / `$N` and declares no schema gets a one-string `arguments` schema automatically, so the model can call `skill_deploy` with the same text an operator would type.

Only placeholders written in the template are filled. A substituted value is text, never template: `Pay {{amount}}` with `{"amount":"$50"}` renders `Pay $50`, and an argument string containing `{{key}}` stays literal. A `$5` written in the template itself is a placeholder, so put a literal dollar amount in through a JSON key.

**Slash commands.** In `pasclaw agent` and the TUI, `/name rest of line` runs the installed prompt skill `name` (case-insensitive; `-` and `_` match) with `rest of line` as its arguments. Built-in commands (`/help`, `/mode`, …) win on a name clash. `/help` lists the prompt skills it knows. Three optional frontmatter fields say where the result runs:

```yaml
---
name: deploy
description: Deploy an environment
kind: prompt
prompt: Deploy $1 with flags $2. Report what changed.
agent: ops          # run through the `spawn` tool on this subagent spec
model: claude-haiku # model for that run (or for this turn, when it runs inline)
subagent: true      # no agent named: run in a fresh child loop on the current tools
---
```

In the line REPL `agent:` goes through `spawn`, `subagent:` runs a child loop, and both record the typed command plus the child's reply in the transcript (not the child's tool traffic). The TUI honours `model:` and turns `agent:` / `subagent:` into an instruction at the top of the message. Prompt skills answer to `/name` in `pasclaw tui --no-tools` too; only their `skill_<name>` tools need the registry.

`model:` applies to the turn the command starts, and only that turn. The auto-router leaves that turn alone (it would otherwise swap in its easy model for a short command). In the TUI, a skill typed while a turn is running joins that turn as steering, on the model it already has, and the footer says so. Source: `src/pkg/skills/PasClaw.Skills.Slash.pas`, `RenderSkillArguments` in `PasClaw.Skills.Loader`.

## Install from GitHub

`pasclaw skills install owner/repo[/path][@ref]`:

- Fetches a zip snapshot from `codeload.github.com`.
- Extracts it via the bundled zip library — `Zipper.TUnZipper` under FPC, `System.Zip.TZipFile` under Delphi. No tar dependency.
- Locates `SKILL.md` at the requested subpath and validates it through `ParseSkillMD`.
- Copies the containing directory tree into `$PASCLAW_HOME/workspace/skills/<dest>/`, where `<dest>` is the last segment of the subpath, or the repo name when no subpath was given.
- When `@ref` is omitted, tries `main` first and falls back to `master`.
- Refuses to overwrite an existing skill directory — run `pasclaw skills remove <name>` first to reinstall.

## Install from ClawHub

`pasclaw skills install clawhub:<slug>[@<version>]` talks to ClawHub (`https://clawhub.ai`), the slug-based registry picoclaw and nanobot standardised on:

- `GET /api/v1/skills/<slug>` — fetches metadata, surfaces moderation flags, resolves `latestVersion` when no `@<version>` is pinned.
- `GET /api/v1/download?slug=<slug>&version=<version>` — pulls the zip, runs it through the same `PasClaw.Skills.Zip` + `ParseSkillMD` validation pipeline as the GitHub install path.
- Malware-flagged skills are refused; suspicious-flagged install with a warning.
- Slugs are lowercase alphanumerics with `-` or `_`.
- The `clawhub:` prefix is required. A bare slug-shaped name like `my-skill` still falls through to the legacy `config.json`-only record, so pre-Phase-3 install scripts keep working unchanged.

## Search

`pasclaw skills search <query>` queries both hubs (pasclaw.dev first, ClawHub deduped) and prints `slug / version / display-name / summary` rows.

## Removal

`pasclaw skills remove my-skill` deletes `workspace/skills/my-skill/` AND the matching `skills[]` entry in `config.json`. Idempotent — running twice on a missing skill is a no-op.

## What the system prompt looks like

With one skill installed, the system prompt grows a section like:

```
## Available skills

- code-review (~/.pasclaw/workspace/skills/code-review/SKILL.md)
  Code review specialist. Reads diff hunks, returns prioritised findings.

When a task matches a skill, fs_read the listed path for the full body.
```

For `kind: shell` / `kind: prompt` skills the section also notes the registered tool name:

```
- generate-tests (~/.pasclaw/workspace/skills/generate-tests/SKILL.md)
  Generate FPCUnit tests for a given source file.
  Tool: skill_generate_tests
```

## Self-improving skills (agent-authored)

PasClaw can let the agent **write its own skills** — the model captures a non-trivial workflow it just performed so a future turn can reuse it. Modelled on [Nous Research's hermes-agent](https://github.com/nousresearch/hermes-agent). Every part is **opt-in**; the default config behaves exactly as before.

Enable the pieces you want under `self_improving_skills` in `config.json`:

```json
"self_improving_skills": {
  "self_manage": true,
  "progressive_disclosure": true,
  "auto_approve": false,
  "guard_deny": ["my-forbidden-command"],
  "distiller": { "enabled": true, "min_tool_calls": 5, "model": "claude-haiku-4-5" }
}
```

### `self_manage` — the `skills_manage` tool

Registers a `skills_manage` tool with four actions the model can call mid-turn:

| action | args | effect |
|---|---|---|
| `create` | `name`, `content` (full SKILL.md) — or structured `description`/`kind`/`shell`/`body` | new skill (refuses to overwrite an existing one) |
| `edit`   | `name`, `content` | full SKILL.md rewrite of an existing skill |
| `patch`  | `name`, `old_string`, `new_string` | unique-occurrence substitution (token-cheap) |
| `remove` | `name` | delete a skill |

Writes are **staged for approval** by default (see `auto_approve`). Like a hub install, an approved/committed skill is picked up on the **next agent start** — the tool registry is built once at boot, not mutated mid-session.

### `progressive_disclosure` — `skills_list` / `skills_view`

Instead of inlining every skill's name + description into the system prompt on every turn, advertise two read-only tools and let the model pull what it needs:

- `skills_list()` → metadata index (name, description, kind, source).
- `skills_view(name)` → the full SKILL.md (or `skills_view(name, path)` for a file under the skill dir, e.g. `references/api.md`).

The SKILLS section of the prompt shrinks to a one-line pointer, keeping the prompt small no matter how many skills accrue. `skills_view` confines reads to the skill's own directory.

### `distiller` — autonomous skill creation

After a qualifying turn (one that dispatched at least `min_tool_calls` tool calls), a small follow-up LLM call decides whether the work is a reusable procedure and, if so, drafts a SKILL.md. It runs **after** the user-facing reply, so it never adds latency. A Jaccard-similarity check against existing skill descriptions drops near-duplicates. Point `distiller.model` at a cheap model to keep the tax negligible. The draft goes through the same guard + staging path as `skills_manage`.

### Approval workflow

When `auto_approve` is **false** (recommended), staged writes land under `workspace/skills/.pending/<id>/` and wait for an operator. **You** are the quality judge — there is no automated utility evaluator.

```sh
pasclaw skills pending          # list staged, agent-authored skills
pasclaw skills diff <id>        # show the proposed SKILL.md
pasclaw skills approve <id>     # commit it (effective next agent run)
pasclaw skills reject <id>      # discard it
```

The gateway exposes the same surface for the web UI (bearer-gated like every `/v1/*` route):

- `GET  /v1/skills/pending`
- `POST /v1/skills/pending/approve` — JSON body `{"id": "..."}`
- `POST /v1/skills/pending/reject`  — JSON body `{"id": "..."}`

The web UI's **Skills** tab renders a "Pending approval" block with a SKILL.md preview and Approve / Reject buttons.

With `auto_approve: true`, writes commit straight to `workspace/skills/<name>/` (still effective only on the next start).

### Safety

- **Path confinement** — every write resolves under `workspace/skills/` (or `.pending/`); names with slashes, `..`, or drive letters are rejected.
- **Dangerous-pattern guard** — a model-authored `shell:` skill is scanned against a built-in denylist (`rm -rf`, `curl | sh`, fork bombs, `mkfs`, …) plus any `guard_deny` substrings, both at stage time and again at approve time.
- **Prompt-injection scan** — the description + body go through [PasClaw.Promptware](./tools.md#promptware-defense) so an injected "ignore previous instructions" can't ride into the system prompt catalog.

## Roadmap

Subsequent phases will add `scripts/` (callable helpers) + `references/` (lazy-loaded context) runtime support, matching the picoclaw / nanobot / Anthropic agent-skills evolution.

## See also

- [Configuration](./configuration.md) for the legacy `skills[]` config block.
- [Tools](./tools.md#promptware-defense) for how SKILL.md descriptions are scanned for prompt injection.
