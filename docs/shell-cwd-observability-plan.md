# The wrong-directory failure, and how to end it

## The problem, stated precisely

A `shell_exec` result never says which directory the command ran in. So a
command that ran in the wrong place is **indistinguishable from a command
that failed on its merits**, and the most natural reading of the error is
the wrong one:

```
exit=2
make: *** No rule to make target 'test-orient'.  Stop.
```

That reads as *"there is no such make target."* It is actually *"you are not
in the repo."* Nothing in the result contradicts the wrong reading, so the
agent proceeds on it — usually by rewording the command rather than moving.

### Correcting an earlier, sloppier framing of this

I previously described this as *"the relay's shell cwd is the workspace not
the repo … the thing most worth fixing in the harness."* That framing is
wrong in a way that would have produced the wrong fix, and it is worth being
explicit about why:

- **The default is correct.** `shell_exec` defaults to the workspace
  deliberately, so relative paths land somewhere predictable and so the cwd
  pins the sandbox boundary alongside the `cd`/`chdir` denylist. Changing it
  would break both. This plan does not touch it.
- **The disclosure already exists — three times over.** A `cwd` argument was
  added in `e7cec9a` ("*because a 20-turn task ran every command in the wrong
  directory*"). The tool description documents the default: *"Defaults to the
  workspace — set this when the files you are working on live somewhere
  else."* And the system prompt states it outright: *"Your working directory
  is: /…/workspace."*

So the fix is not "tell the model where it is." The model **was** told, three
times, up front — and got it wrong anyway, repeatedly. That is the actual
finding, and it is a more interesting one.

### Why three correct disclosures still fail

All three are **ante-hoc**: they appear in the prompt and the schema, before
any command runs. The failure is **post-hoc**: it surfaces many turns later,
inside a tool result, at a moment when the model is reasoning about make
targets and not about geography. By then the cwd statement is thousands of
tokens back, competing with everything since.

The one place the information would be decisive — the failing result itself —
is the one place it does not appear.

This is exactly the defect `docs/verification-scope-prompts-plan.md` is about,
in miniature: **the tool reports what happened, but not the context that
determines whether what happened means what it appears to mean.** A scope-less
`exit=2` is the same species of half-truth as a green test run that never says
which cases it skipped.

## Evidence

Counted from the persisted relay sessions under
`research/workspace/sessions/` (the gateway session store, so these are real
agent turns, not reconstructions):

| Signature | Count |
|---|---|
| `No rule to make target` | 12 |
| `… No such file or directory` (grep/awk/ls on repo-relative paths) | 10 |
| **Total wrong-cwd failures** | **22** |
| Distinct sessions affected | 5 |

Every one cost at least one round trip: a full model call, the tool
execution, and the correction turn. Several cost two, because the first
correction re-ran the command with the same missing prefix.

## The fix

Three changes, smallest first. Only the first is load-bearing.

### 1. Echo the cwd in every `shell_exec` result

Today (`PasClaw.Tools.Shell.pas`):

```pascal
Result := Format('exit=%d'#10'%s', [ExitCode, Out_]);
```

Becomes a result whose **second** line names the directory:

```
exit=2
cwd=/tmp/…/research/workspace
make: *** No rule to make target 'test-orient'.  Stop.
```

**Line 1 must stay byte-identical**, and this is a hard constraint discovered
by reading the consumers, not assumed:

- `PasClaw.Cmd.Learn.pas` matches `Pos('exit=1', L) = 1` and `'exit=2'` at
  **position 1** — SCARS failure-mining breaks if anything precedes it.
- `PasClaw.Tools.ToolLoop.pas` takes everything up to the first `#10` as the
  progress-ledger line and tests `Copy(ExitLine, 1, 5) = 'exit='`.

Putting the cwd on line 2 satisfies both without touching either. Appending
to line 1 would technically survive the prefix tests but would widen every
ledger entry, so line 2 it is.

Always, not only on failure. The tool's own description already warns that a
command can "run in the wrong place and report success anyway" — a silent
wrong-directory *success* is the worse case, because nothing prompts a second
look. Cost is one short line per shell call.

### 2. A targeted hint when the failure smells like geography

When **all** of these hold — non-zero exit, `cwd` was *not* explicitly passed,
and the output matches a known wrong-directory signature (`No rule to make
target`, `No such file or directory`, `not a git repository`) — append one
line:

```
hint: cwd was not specified, so this ran in the workspace. If these paths are
relative to a different root, pass cwd, or use an absolute path.
```

Narrow on purpose. It fires only where the evidence is strong, and it says
what to do rather than restating the error.

### 3. Tests, asserting both directions

- The cwd line is present on success and on failure, and line 1 is still
  exactly `exit=N`.
- Explicit `cwd` is echoed as the resolved directory, not the argument.
- The hint fires for `No rule to make target` with a defaulted cwd.
- **The negative controls, which matter as much:** the hint does *not* fire
  when `cwd` was explicitly passed (the model already thought about it), and
  does *not* fire on an unrelated failure such as a compile error. A hint on
  every red result is noise, and noise is how a real signal gets ignored —
  the same lesson as an SSRF guard that blocks all of IPv6.
- Pin the two consumer contracts directly: a `learn` fixture whose tool text
  now carries the extra line is still classified as a failure, and a ledger
  line is unchanged.

## Sequencing

| Step | Change | Size |
|---|---|---|
| 1 | cwd on line 2 of every shell result | a few lines |
| 2 | wrong-cwd hint on matching failures | small |
| 3 | `shell_cwd_report_tests` incl. negative controls | one test file |

## What this deliberately does not change

- **The workspace default stays.** It is a sandbox decision, not an accident.
- **No new prompt text.** The prompt already says the right thing; adding a
  fourth ante-hoc disclosure would be treating the symptom that already
  failed three times.
- **It does not make the agent choose correctly** — it makes the wrong choice
  *self-evident at the moment it is made*, which is the only intervention the
  evidence supports.

## How we will know it worked

Re-run a relay pass that touches the repo from a workspace-rooted gateway. The
current signature is a wrong-cwd failure followed by a re-run with the same
missing prefix. Success is a wrong-cwd failure followed by a **corrected**
command on the next turn — the count of *repeated* wrong-cwd failures within
one session going to zero. The first failure is acceptable; the second one is
the bug.
