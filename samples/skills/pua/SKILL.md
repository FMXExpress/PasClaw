---
name: pua
description: When you suspect you're stuck (retrying the same thing, blaming the user, ignoring tools, busywork, or stopping without verification) read this skill and apply its anti-pattern recovery procedure
---

# Stuck-loop recovery skill

Adapted from the [`tanweai/pua`](https://github.com/tanweai/pua)
Claude Code skill (MIT). The upstream's framing is humorous, the
substance is real: there are five concrete failure patterns an
agent slides into when a task is hard, and a short checklist that
gets you out of each.

You should consult this skill the moment any of the following is
true about the turn you're currently in:

- You've run the same `shell_exec` / `execute_code` / `fs_write`
  command twice in a row with no new information between calls.
- You're about to tell the operator "this isn't working, can you
  check X?" without having read the relevant files / logs / errors
  first.
- You can name a tool you have access to that you haven't used yet
  this turn, even though it would clearly apply.
- You've rewritten the same function three times and each version
  is "almost right" but you haven't read what's actually calling it.
- A fix went green but you haven't run the verification step (build,
  test, grep, status) that proves it.

If none of those describe you, you're not stuck. Carry on.

If any of them does, this skill is the recovery procedure. Apply it
in order, mark items off as you do them, and only escalate to the
operator after every applicable item is checked.

## The five anti-patterns

### 1. Brute-force retry

> Re-running the same command, expecting different results.

**Recover:**
1. Quote the exact command you just ran and its exit code / output.
2. Identify *one variable* you'll change before the next attempt
   (env var, working directory, argument, file content). Name it.
3. Read the file or doc that explains why that variable matters
   (`fs_read` man pages, README, log output) before the next call.
4. If you can't name a variable to change, **stop** and re-frame:
   the problem is not what you thought it was.

### 2. Blame-shifting

> Asking the operator to look at something you haven't looked at
> yourself.

**Recover:** before any "could you check / can you confirm / is X
configured?" message, you must have already done all of:

- [ ] `fs_grep` for the symbol / config key in the project.
- [ ] `fs_read` of the relevant config / module / dotfile.
- [ ] `shell_exec` or `execute_code` for the command whose output
      you'd ask the operator to paste.
- [ ] `kb_search` and `memory_search` for the same term — past
      sessions may have hit and resolved this.

If you've done all four and still need clarification, ask — and
quote the specific output you got, not a generic "doesn't work".

### 3. Idle tools

> Having capabilities and not using them.

**Recover:** stop and list, out loud in the next assistant message,
the tools you have available that you have *not* called this turn.
For each one, decide: would it apply to the current problem? If
yes, use it before continuing. Common skips:

| Skip | When it applies |
|------|------------------|
| `fs_grep` | Anywhere you need to find usages, definitions, configs. |
| `kb_search` / `kb_get` | The operator's indexed reference docs. |
| `memory_search` | Past sessions on the same codebase. |
| `web_search` / `web_fetch` | Vendor API behaviour, error codes, library docs. |
| `execute_code` | Multi-line scripts that need real shell. |
| `session_search` | Recurring failure patterns across your past runs. |
| `tool_output_get` | The full output of a tool whose result was capped. |

### 4. Busywork

> Tweaking the same code without new information.

**Recover:**
1. Stop editing. Read the *callers* of the function you're
   rewriting (`fs_grep` for the function name).
2. Read the *tests* that exercise it (`fs_grep` for the function
   inside `*_tests.pas` / `test_*.py` / `*_test.go` / etc.).
3. State what the function is *supposed* to do, in one sentence,
   based on what you read in steps 1 and 2.
4. Compare against what it *currently* does. If they match,
   you're done — the bug is upstream. If they don't, the right
   rewrite is now obvious.

### 5. Passive waiting

> Fix went green, you stopped without verifying.

**Recover:** every fix must end with the explicit verification
that *proves* it green. Pick the strongest one you have:

| Domain | Verification |
|--------|--------------|
| Code change | Run `make`, `pasclaw delphi_build`, the language's compiler, or the project's test target. |
| Config change | Run the command the config affects and inspect output. |
| Memory / KB update | `memory_search` or `kb_search` for the term you just added; confirm the new content surfaces. |
| Build deps | `pasclaw status` or the language equivalent (`go list`, `cargo check`, `npm ls`). |

A fix is not done until the verification ran in the same turn and
returned the expected state.

## The recovery routine, condensed

When you notice yourself in any anti-pattern, run through the
checklist above for that pattern. Don't skip steps. The whole list
is short enough to apply every time without grinding the user's
patience. If you finish the list and the problem persists, *then*
escalate — and the escalation message will contain real, specific
information because the checklist forced you to gather it.

## What this skill is not

- Not a tool. It's a markdown document the agent reads when
  triggered. There's no `skill_pua` to call.
- Not a global rule. The agent's normal flow is "do the thing, be
  terse." This skill kicks in only when one of the five patterns
  is active.
- Not personality. The five patterns are about *behaviour*, not
  tone. You don't need to apologise or be hard on yourself; you
  just need to do the next concrete thing in the list.

## Installation

```sh
# From this repo, copy to your PasClaw skills dir
cp -r samples/skills/pua ~/.pasclaw/workspace/skills/

# Or install from the PasClaw catalogue (if/when this lands there)
pasclaw skills install FMXExpress/PasClaw/samples/skills/pua

# Verify it loaded
pasclaw skills list | grep pua
```

After install the next `pasclaw agent`, `pasclaw build`, `pasclaw
tui`, or gateway session will see this skill listed in the
SKILLS section of the system prompt with the single-line
description above. The model decides to `fs_read` the full body
when one of the five trigger conditions applies.

## Credit

Concept and the five-pattern taxonomy adapted from
<https://github.com/tanweai/pua> by tanweai, MIT-licensed.
PasClaw port adds the tool-list mapping (PasClaw uses `fs_grep` /
`fs_read` / `shell_exec` / `execute_code` / `kb_search` /
`memory_search` etc., not Claude Code's bash/glob/grep) and drops
the upstream's hook-based always-on machinery in favour of the
on-demand load PasClaw skills already give you.
