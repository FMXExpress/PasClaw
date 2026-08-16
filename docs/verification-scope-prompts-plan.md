# Scope reporting in the PasClaw prompts

The survey's "gap nobody has": **no surveyed system reports what its
verification did not cover.** Every tool answers *did this succeed*; none
answers *what did I not look at*. The field's remedies are all more
verification — never honest reporting of verification's scope.

This is a plan to put that honesty into the **prompts** — the checks and
balances the model is asked to hold itself to — not into new tooling. A
companion plan (`docs/verification-scope-plan.md`, if present on its branch)
covers the code side: scope envelopes on tool results, a defined-but-never-
called test lint, trace-coverage counters. The two are complementary. This
one needs no new engine code — only prompt text and one already-existing
injection path — so it can ship first and cheaply.

## Why the prompt is the right layer

PasClaw already carries two prompt-level *honesty loops*, and the survey found
neither anywhere else in the field:

- **`--mode improve`** (`BuildImproveModeSection`, `PasClaw.Agent.Prompt.pas`)
  forbids a claim the model is otherwise very good at making: a speedup it
  never measured. "A change you did not re-measure is not an improvement, it
  is a hope." That is already a scope rule — it just guards *one* axis
  (performance numbers).
- **SCARS** (`learn --write-scars` → `SCARS.md` → injected into the prompt)
  feeds the model its own past failures so it stops repeating them.

Scope reporting is the third member of that family: the model telling the
truth about **what it did not look at**. It belongs beside them, in the same
prompt, for the same reason — it is a discipline, not a capability, so it
needs words in the system prompt rather than a tool.

## The evidence this is needed is this repo, this month

Every item below is a real failure from recent PasClaw work where a check
reported success while its scope was silently narrower than the claim:

1. **`make test-json-utf8-roundtrip` printed OK on five tests that never
   ran** — defined but not called from the main block. The runner verified
   its exit code and had no concept of "cases defined vs cases executed."
2. **Four `[P]` ("checked against the repo") survey rows were wrong**, each
   from reading one call-site and generalising. The mark recorded *that* a
   check happened, never *how far it looked*.
3. **A stale `.ppu` made a disabled security guard test as passing** — the
   source on disk said one thing, the linked binary another, and "green"
   couldn't tell them apart.
4. **The first IPv6 SSRF parser blocked every attack case for the wrong
   reason** (a parse bug refused everything, including public IPv6). The
   attack half of the suite was all green; only the *must-not-block* half
   exposed it.

In four separate rounds this session, the fix's own commit message ended up
carrying a hand-written "**what I did NOT check**" paragraph — OAuth siblings
left unaudited, `SameInode` absent on Windows, the untested cross-compile
branch, the search fetchers out of scope. That paragraph was written in prose,
by hand, every time, because nothing in the prompt asked for it. This plan
makes it structural.

## Principle, in the model's voice

> A result is a verdict **and its scope**. When you report success, name the
> check you ran and the thing it did not cover. A green check whose scope you
> leave unstated reads as "all clear" — and that is the exact failure this
> harness is trying not to ship.

Three properties, mirroring the improve-mode rules that already work:

- **Cheap.** One or two sentences at the end of a result, not a section.
- **Falsifiable.** "I ran X; it does not cover Y" is checkable; "I verified
  it" is not.
- **Default, not on request.** A scope note the user has to ask for won't be
  asked for. Improve mode is default-on for its `mode`; scope reporting is
  default-on for the base prompt.

## The changes, smallest first

### 1. Extend base Rule 3 "Verify changes" (`BuildBuildRulesSection`)

Today it ends at *did the edit land*:

> **Verify changes** — after editing code, re-read what you wrote or run a
> targeted check (build, test, search). Do not assume the edit landed
> correctly because the tool returned success.

Add one clause, in the same voice:

> …And when you report the check, say what it did **not** cover: the case the
> test does not exercise, the platform the build did not target, the path the
> grep did not reach. "Tests pass" is a claim about the tests that ran, not
> the ones that exist. A green result with unstated scope is how this project
> has shipped four silent regressions — name the edge you left unchecked so
> the next reader knows where to look.

Smallest possible change, touches every mode, and it is the rule the four
incidents above would each have tripped. This is the whole plan's minimum
viable version — ship this clause alone and the rest is refinement.

### 2. Add a scope rule to improve mode (`BuildImproveModeSection`)

Improve mode already has two "rules about outcomes." Add a third, so the mode
that demands the *number* also demands the *scope of the number*:

> - **State what the measurement did not measure.** A benchmark covers the
>   path it exercised and no other. Say which inputs, sizes, or code paths
>   the number does not speak for — a 2× on the cached path is not a 2× if
>   most calls miss the cache. The honest form is "X→Y on «this exact
>   workload», not measured for «that one»."

Text-only; sits naturally with "never state a speedup you did not measure."

### 3. Add a one-line SCARS-family scar

`learn --write-scars` mines *observed* failures across sessions. Seed the
concept with a standing entry so the discipline is present even before it
recurs — a general "scope scar" injected the same way SCARS.md is:

> §SCOPE — When you report a check as passing, you have repeatedly failed to
> say what it did not cover: tests defined-but-not-run, a `[P]` mark from one
> call-site, a stale artifact masking a disabled guard. Report the verdict
> **and** the unchecked edge, every time.

This rides the existing injection path (no new code) and, unlike the prompt
rules, is phrased as *your own past mistake*, which the SCARS design already
shows the model responds to more sharply than an instruction.

### 4. Completion-report convention (documentation, not code)

The user-facing "done" message is where scope matters most to a human. Codify
what this session already did by hand as the expected shape of a completion
report, in `CLAUDE.md` / the contributor prompt:

> A completion report states, in one or two sentences: what was verified and
> how (the command, the platform), and what was **not** — anything asserted
> by reasoning rather than run, any platform not built, any case the tests
> skip. "Not checked" is not an admission of sloppiness; it is the most
> useful sentence in the report, because it is the only one that tells the
> reader where the risk still lives.

## Sequencing

| Step | Change | Surface | Size |
|---|---|---|---|
| 1 | Rule 3 scope clause | base build prompt (all modes) | one paragraph |
| 2 | Improve-mode scope rule | `--mode improve` | one bullet |
| 3 | §SCOPE standing scar | SCARS injection path | one entry |
| 4 | Completion-report convention | CLAUDE.md / contributor doc | one paragraph |

Steps 1–3 are edits to `PasClaw.Agent.Prompt.pas` and the SCARS source; step 4
is docs. No engine changes, no new tools.

## How we'll know it worked

Prompt changes are hard to unit-test, so the acceptance criteria are
behavioural and deliberately concrete:

- **Regression-transcript check.** Re-run the four incidents above through the
  relay in improve mode against the *new* prompt and confirm the model now
  volunteers the scope line unprompted — e.g. after "tests pass" it names the
  cases the suite does not exercise. A canned transcript per incident, stored
  under `bench/`, is the closest thing to a test this can have.
- **The negative control matters as much as the positive.** A scope note that
  fires on everything is noise, not signal — the same failure as an SSRF guard
  that blocks all of IPv6. Confirm the model does *not* append an empty "I
  checked everything" boilerplate to trivial turns; the note should appear
  when there is a real unchecked edge and be absent when the work is complete
  and small.
- **Dogfood on the open branches.** The next security or improve pass should
  produce its "what I did not check" paragraph because the *prompt* asked for
  it, not because the operator did. When that paragraph stops being
  hand-written, the plan has landed.

## What this deliberately does not do

It does not make the model's scope claims *true* — a model can under-report
what it missed just as it can over-claim success. Prompts raise the floor;
they are not a proof system. The code-side plan (scope envelopes computed by
the tools themselves, a lint that counts defined-vs-run tests) is what turns
"the model says it checked X" into "the tool reports it covered X," and the
two are meant to ship together. This half is the cheap half — and it is the
half that would have caught, in prose, every scope failure this project has
shipped this month.
