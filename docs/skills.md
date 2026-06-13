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

## Roadmap

Subsequent phases will add `scripts/` (callable helpers) + `references/` (lazy-loaded context) runtime support, matching the picoclaw / nanobot / Anthropic agent-skills evolution.

## See also

- [Configuration](./configuration.md) for the legacy `skills[]` config block.
- [Tools](./tools.md#promptware-defense) for how SKILL.md descriptions are scanned for prompt injection.
