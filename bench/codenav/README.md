# bench/codenav — finding your way around a codebase

`make bench-codenav` (from the repository root).

## Why this exists

An agent working in a codebase spends calls finding where things are
before it can read or change them. Measured on one long session on this
repository (2,957 tool calls, from its transcript):

| what the calls were | share |
|---|---|
| reading code, mostly code about to change | 25% |
| running and verifying (make, benches) | 23% |
| changing code | 23% |
| searching inside a file already known ("which line") | 13% |
| searching the repository ("which file is X in") | **7%** |

Most of that 7% asked where a name is *defined*, with
`grep -rn "function X"`. A literal search answers that with every use as
well, or with nothing when the guessed keyword is wrong. Aider's answer
is a repository map in every request. PasClaw's is `code_outline`, a map
made on demand, which costs only its schema until it is called:

- `symbol=NAME`: where NAME is declared or defined under `path`
  (functions, methods, classes, types, constants), not where it is used;
- `path=FILE`: the file's declarations, with line numbers;
- `path=DIR`: each source file's purpose (the first paragraph of its
  leading comment) and the names it declares, with subdirectories one
  line each.

The tool lives in `src/pkg/tools/PasClaw.Tools.Outline.pas` and is
registered beside `grep_files`.

## What it measures

The 34 lookups are real: names whose definitions were searched for during
that session. Each has the file(s) that define it, found independently by
`grep -E "^(function|procedure|constructor) (T*.)?NAME"`, not by the tool
under test. Every lookup goes through the tool registry, the way a
model's call would, three ways:

- **grep-name**: `grep_files` for the bare name. One call returns every
  use, with the definition somewhere among them.
- **grep-def**: `grep_files` guessing the definition's keyword
  (`function NAME`, then `procedure`, `constructor`, `NAME =`) until a
  defining file shows up. This is what an agent actually does.
- **outline**: `code_outline symbol=NAME`, one call.

It is a measure of information cost for fixed strategies: calls, bytes,
and whether the answer is in the result. Whether a model *chooses* the
tool is a question for a live run.

## Results

| 34 definition lookups | calls | bytes returned | lines returned | answered |
|---|---|---|---|---|
| grep-name | 34 | 47,778 | 870 | 34/34 |
| grep-def | 52 | 8,499 | | 31/34 |
| **outline** | **34** | **7,021** | **69** | **34/34** |

- **Compared with grep-name**, outline returns 85% fewer bytes in the same
  number of calls, with 69 lines instead of 870. There is nothing to pick
  through: the declaration comes with its section and line, and for a
  Pascal unit the body's line is listed as `Name (body)`.
- **Compared with grep-def**, it takes a third fewer calls and answers
  every lookup. grep-def misses three, because a method is declared as
  `function  DeferredNames` (two spaces) or defined as
  `TToolRegistry.DeferredNames`, and a literal search for
  `function DeferredNames` finds neither. The grep-def bytes include
  `grep_files`' new hint on such a miss (below); without it they were
  6,690.

Outlining instead of reading:

| | read the whole file | outline |
|---|---|---|
| `PasClaw.Teams.pas` | 84,613 | 4,093 (4.8%) |
| `PasClaw.Projects.Tools.pas` | 81,048 | 4,624 (5.7%) |
| `PasClaw.Gateway.Desktop.pas` | 142,287 | 5,226 (3.7%) |
| `PasClaw.Tools.Registry.pas` | 22,667 | 3,293 (14.5%) |

A directory's outline is larger than `list_dir`'s list of names
(`src/pkg/projects`: 3,786 bytes against 356) because it carries what each
file is for and what it declares, which a name list does not.

**The price.** The schema is 411 bytes (406 before the live run made the `symbol` example generic), and it rides on every request once
the tool is registered. On the team-board replays that came to 483 bytes
per call with the JSON wrapping: duo 951,641 → 965,648 (+1.47%), security
sweep 1,572,620 → 1,591,457 (+1.2%). Those teams build small apps and
never call it. One lookup that would otherwise have been a name grep
returns about 1,200 fewer bytes, and those bytes would have stayed in the
history for every later call of the session.

## Changes the bench made

- **Symbol mode printed every Pascal signature twice**, once for the
  declaration and once for the body. The body is now `Name (body)` with
  its line, and outline's total dropped from 8,727 to 7,021 bytes.
- **The schema was trimmed from 594 to 406 bytes**, because every request
  pays for it.
- **`grep_files` now points a failed definition hunt at `code_outline`.**
  When a definition-shaped pattern (`function X`, `def X`, `class X`, …)
  finds nothing, the result names the call that would have found it.
  This costs nothing per request and appears exactly where keyword
  guessing fails.

## From review (#626)

- **A string holding `/*` opened a comment that swallowed every declaration
  after it** in JS/TS, Go, Rust and PHP, and a `//` in a string cut its
  line. String literals are now skipped before comments are looked for,
  with each language's quotes:
  - JS: `'`, `"` and template backticks, which may span lines;
  - PHP: `'` and `"`, either of which may span lines;
  - Go: `"`, raw backtick strings that may span lines, and runes that
    close within a few bytes;
  - Rust: `"`, which may span lines, and `'` read as a char literal only
    when it closes within a few bytes, so a lifetime (`'a`) opens nothing.

  `desktop.html` outlines the same 154 functions before and after.
- **A directory made only of directories was unbounded**: 3,000
  subdirectories came to 425 KB. The subdirectory list is now held to the
  same budget and says how many it left out.

## Live run: does a model pick it?

The bench measures fixed strategies. Whether a model *chooses*
`code_outline` was measured live: chat turns through `pasclaw serve` on the
relay provider, against a copy of this repository. The model's decisions
came from fresh subagents that saw only what the model sees:
- the system prompt;
- the tool list (names, descriptions, parameters);
- the conversation.

Each was told only to answer as that model would, with nothing about
`code_outline` or what was being measured. Every call went to a new
subagent with the whole request, because a model is stateless. The
control arm ran the same tasks on `main`'s binary, which has no
`code_outline`.

| task | arm | model calls | request bytes | tool-result bytes | picked `code_outline` |
|---|---|---|---|---|---|
| "who may give the verdict? file, function, rule" | with | 3 | 156,165 | 42,299 | no |
| | without | 3 | 149,871 | 39,671 | — |
| "change the orient slicer's default budget from 4096 to 6144" | with | 6 | 350,998 | 52,180 | no |
| | without | 6 | 320,834 | 69,493 | — |
| "one line on what each unit under src/pkg/kb does" | with | 3 | 81,036 | 4,972 | **yes, first move** |
| | with, after the fix below | **2** | **50,546** | **980** | **yes, first move** |
| | without | 3 | 86,473 | 11,960 | — |

What it shows:
- **The model picked the tool unprompted where it fits best: a
  directory's overview.** After the fix below, it answered in 2 calls
  instead of 3, with 42% fewer request bytes and 92% fewer result bytes.
- **It searched by concept for "find the code that does X"**, grepping
  `verdict` and `reviewer`, then read the lines the hits named. Symbol mode
  needs a name, and the model had none yet; the grep turned one up and the
  targeted reads that followed were direct. The arms did not differ.
- **It grepped the literal value for "change this value"**: `4096` found
  the constant at once, and again the arms did not differ.
- **The cost:** the request-byte difference on the first two tasks is the
  schema (483 bytes a call) plus the run-to-run spread between two
  different stand-ins. In the "without" arm of the second task, a test
  build also failed for lack of Indy, which this run's repository copy
  did not include.

One stand-in per task per arm is a small sample: this says the tool is
found and used, not how often.

Fixed from the run:
- **The `symbol` parameter's description gave `TaskReviewers` as its
  example**, which was this repository's answer to the run's first
  question. The first trial read it off the schema, so that trial was
  discarded and rerun. The description is now generic ("A name, or
  Type.Name for a method"), and a test asserts that no real name appears
  in the schema.
- **Three of the four `kb` units had no purpose line in the outline.**
  Their header comment comes after `unit X;`, a common Delphi layout, and
  the summary reader stopped at the first line of code. The model spent
  a call reading each header. The reader now steps over a Pascal
  `unit`/`program`/`library`/`package` line, which is what made the
  2-call run.

## Not done

- **Hiding the tool behind `tool_search`** would save the 483 bytes per
  call. But a deferred built-in reaches the model as a bare name, and
  [LIVE.md](../teamboard/LIVE.md) records that hidden tools are mostly
  never chosen. `code_outline` is registered visible, like `grep_files`
  and `find_files`. If the per-request cost matters more, adding it to
  `ToolIsLongTail` is a one-line change.
- **A live run where a model picks the tool on its own** has not been
  measured.
