# Contributing

## Repository layout

```
src/
  pasclaw/          Program entry point (PasClaw.dpr)
  cmd/              CLI command units — one PasClaw.Cmd.<Name>.pas per top-level command
  pkg/
    agent/          RunToolLoop's compaction / hooks / steering / subagent helpers
    channels/       Telegram, Discord, Slack, Teams, generic webhook, LINE, WhatsApp, Matrix, IRC, Email
    cliui/          ANSI styling, banner, command help rendering
    component/      TPasClawAgent / TPasClawServer TComponent wrappers
    condense/       JSON condensation for tool outputs
    config/         TConfig record + JSON load/save
    cron/           Cron scheduler (PasClaw.Cron.Scheduler)
    gateway/        Indy HTTP server, OpenAI-compatible API, embedded web UI, tool-view formatter
    hashline/       Hashline patch/edit format (PasClaw.Hashline)
    identity/       <platform>:<id> canonical strings + allowlist
    json/           Project-local JSON DOM (PasClaw.JSON)
    kb/             Knowledgebase index + tools
    logger/         Levelled logging + ring buffer + SSE listeners
    mcp/            MCP stdio + HTTP clients + tool bridge
    membench/       Memory benchmark helpers
    memory/         Memory log storage; sub: memory/localvector/ for ONNX + sqlite-vec
    net/            SSRF guard (IPv4 blocklist + DNS re-resolution)
    otel/           PasClaw.Otel — OpenTelemetry traces (OTLP/HTTP+JSON)
    platform/       Platform helpers (Windows OEM decode, etc.)
    providers/      Provider catalog + Anthropic / OpenAI / Gemini HTTP clients + factory
    search/         Web-search providers (DuckDuckGo, Brave, Tavily, SearXNG, Perplexity, Gemini) + HTML→text
    session/        Session store (workspace/sessions/<id>.json)
    shell/          IShellBackend interface + local + docker implementations
    skills/         Skill manifest loading + tool registration + ZIP unpack
    stream/         Streaming reliability (empty-turn retry, idle-timeout)
    tokenizer/      Token counting helpers
    tools/          Built-in tool catalog (fs_*, shell, web, memory, kb, session_search, ...) + RunToolLoop
    tui/            Full-screen terminal UI (Delphi: two-pane; FPC: line-based)
    updater/        GitHub release self-update support
    utils/          Path, file, and string helpers
    vendor/         Vendored deps (dmvcframework for the TUI, etc.)
samples/
  component-console/   Three sample binaries (SampleConsole, SampleSimple, SampleServer)
  skills/hello/        Starter SKILL.md
src/tests/             Pure-Pascal test programs (one per feature)
docs/                  This documentation tree
vendor/Indy/           Vendored Indy (FPC builds only — Delphi has Indy in RAD Studio)
```

## Build conventions

### FPC

```sh
make get-indy        # one-time clone of IndySockets/Indy into vendor/Indy
make smoke           # build + run a fast subset to catch obvious compile breaks
make all             # build the binary
make clean
```

The Makefile autodetects FPC unit paths on Debian / Homebrew. Overrides:

```sh
make FCLDB_DIR=/opt/fpc/units/x86_64-linux/fcl-db \
     SQLITE_DIR=/opt/fpc/units/x86_64-linux/sqlite \
     LAZUTILS_DIR=/usr/lib/lazarus/3.0/components/lazutils
```

Cross-compile (Windows-on-ARM64):

```sh
make CROSS_TARGET=aarch64-win64 \
     FPC_UNITS_DIR=/opt/fpc/units/aarch64-win64 \
     FPC='fpc -Twin64 -Paarch64' \
     BIN=build/pasclaw-arm64.exe
```

### Delphi

```bat
build-delphi.bat
```

Or open `src/pasclaw/PasClaw.dproj` in the IDE. The `.dproj` keeps `DCC_UnitSearchPath` in sync with the Makefile's `UNIT_DIRS`. When you add a new package directory under `src/pkg/`, you must update **both**:

1. Append the directory to `Makefile`'s `UNIT_DIRS`.
2. Append `..\pkg\<dir>` to `src/pasclaw/PasClaw.dproj`'s `DCC_UnitSearchPath` (single XML element).

A PR that updates one but not the other fails the next dcc64 build:

```
PasClaw.<Caller>.pas(N): F2613 Unit 'PasClaw.<Newpackage>' not found.
```

## Test conventions

### One test program per feature

Each test is a standalone Pascal program under `src/tests/`:

```
src/tests/
  fs_grep_tier1_4_tests.pas      ← pins the tier 1-4 fs_grep optimisations
  fs_grep_tier5_6_tests.pas      ← pins tier 5-6 (byte walker + BMH)
  otel_tests.pas                 ← OpenTelemetry trace export shape
  logger_level_quiet_tests.pas   ← --quiet clamp + suppression contract
  shell_filters_tests.pas        ← per-command shell-output condensers
  ...
```

Each compiles to its own binary under `build/`, runs in isolation, exits 0 on success, exits 1 with `FAIL: <msg>` on failure.

### Makefile targets

Every feature test has its own target:

```sh
make test-fs-grep-tier1-4
make test-fs-grep-tier5-6
make test-otel
make test-logger-level-quiet
make test-shell-filters
...
```

`make test` is the aggregate — runs the full battery. `make smoke` is the cheapest sanity check (smoke build only; no test compile).

### Regression test naming

Pin every shipped fix to a named regression test. Test name says **what's pinned**, not the implementation:

| Good | Bad |
|---|---|
| `TestSkipsLargeFileDirectPath` | `TestSizeCheck` |
| `TestRunRootCommandPreservesQuietClamp` | `TestNoOverride` |
| `TestDirectFilePathRespectsCap` | `TestPR240` |

Tests pin **observable behaviour**, not internal mechanisms — so a refactor of the mechanism doesn't break the test as long as the behaviour holds.

### Locking in user-facing regressions

When a code review or user report catches a bug, the fix's regression test should pin **both** halves of the sequence: the path that's correct now AND the path that was buggy. Pattern in `logger_level_quiet_tests.pas`'s `TestRunRootCommandPreservesQuietClamp`:

```pascal
// With the fix
SetLogLevel(llError);
LogInfo(MarkerWithFix);
AssertTrue(not BufferTailHas(MarkerWithFix), 'fix preserves clamp');

// Without the fix (simulated)
SetLogLevel(llError);
SetLogLevelFromString('info');   // the bug
LogInfo(MarkerWithoutFix);
AssertTrue(BufferTailHas(MarkerWithoutFix), 'documents the regression');
```

A future PR that drops the guard fails this test instead of silently reintroducing the bug.

### Test seams

When external state is hard to control in-test (HTTP, env vars, the wall clock), the production unit exposes a swap point:

- `PasClaw.Otel.SetExportTransport(@MyCaptureFunc)` — swap the OTLP/HTTP POST for an in-process callback.
- `PasClaw.Tools.Shell.SetShellRunner(@MyMock)` — swap `RunOneShot` for a scripted mock.

Restore the default after the test (`SetExportTransport(nil)`) so subsequent tests in the same binary aren't affected.

## Comment conventions

PasClaw favours long-form block comments explaining **why** a piece of code exists. Patterns that pay back:

### Unit header

Every `src/pkg/<topic>/PasClaw.<Topic>.pas` opens with a multi-paragraph `(* ... *)` block stating:

1. What the unit's responsibility is in one sentence.
2. The shape of its public API (`Register<Thing>`, `T<Thing>` types).
3. Any non-obvious design choices the reader will hit.
4. Cross-references to related units.

### Inline "WHY" comments

Comment the non-obvious. Skip the obvious. Bad:

```pascal
{ Increment the counter. }
Inc(N);
```

Good:

```pascal
{ FPC 3.2 BaseUnix doesn't ship FpSetenv — only 3.3+ trunk does.
  Call libc setenv(3) via cdecl to stay portable across both. }
function libc_setenv(N, V: PAnsiChar; O: LongInt): LongInt; cdecl;
  external 'c' name 'setenv';
```

### Codex / PR-review attribution

When a code-review caught a bug, the inline fix carries an attribution:

```pascal
{ Codex P2 on PR #119: without this guard, OnError would skip
  exactly the cases an audit/alerting hook most wants to see. }
if (Length(Cfg.Hooks) > 0) and
   ((Resp.StatusCode < 200) or (Resp.StatusCode >= 300)) then
  HooksOnError(...);
```

Future readers grep for `Codex P[12] on PR #N` to find the review thread.

## Commit + PR conventions

### Commit message shape

```
<topic>: <one-line summary>

<body explaining WHY this change exists>

<observable behaviour pinned, if applicable>

<known limitations / follow-ups>
```

Example:

```
fs_grep: ripgrep tier 5+6 -- byte walker + Boyer-Moore-Horspool

Two more ripgrep-inspired wins for fs_grep on top of tier 1-4:
byte-level walker replacing TStringList/StringReplace, and BMH
substring search replacing Pos() with a 256-entry shift table.

Observable behaviour pinned by src/tests/fs_grep_tier5_6_tests.pas:
line numbers exact across the byte walker, CRLF trimming inline,
no-trailing-newline final-line match, multi-match-per-file with
single hashline header, BMH overlapping patterns, m=1 degenerate,
m > n early exit, empty/all-newline bodies don't crash.

Parallel-tool workers still don't propagate the parent's threadvar
span context across the worker boundary — follow-up.
```

### PR description shape

Same skeleton — summary, why, test plan, known limitations / follow-ups. The PR body is the user-facing record of why the change exists; the inline comments are the future-maintainer record.

### Review-fix commits

When a code review on an open PR catches a bug, the follow-up commit names the PR + finding:

```
PR #240 review fix: honor max_file_bytes on direct-file grep

Code review caught that the size cap was only enforced during
directory walk; the direct-file branch missed it. Fix: stat via
FindFirst and skip if SR.Size > MaxFileBytes. Same cost as Walk's
check; no body read on the skip path.

Pin both directions in TestDirectFilePathRespectsCap: oversize
direct-file gets (no matches) at the default 10 MiB cap, and the
same file IS scanned when max_file_bytes is raised.
```

Future readers can `git log --grep "PR #240"` to find every fix related to PR #240.

## Filing issues

The repo's issue tracker lives at https://github.com/FMXExpress/PasClaw/issues. For bug reports, include:

- The `pasclaw version` output.
- The OS + compiler (`fpc -i` or Delphi release).
- The command you ran (with `--quiet` redacted-API-key style, or full output if relevant).
- What you expected vs. what happened.

For feature requests, sketch the use case and the smallest API change that would unlock it.

## Releasing

Releases follow GitHub Releases convention. The updater (`pasclaw update`) hits the GitHub Releases API and downloads the asset matching the host platform.

Tag a release:

```sh
git tag v0.2.0
git push --tags
```

CI builds the asset matrix (Linux x86_64 / aarch64, macOS x86_64 / arm64, Windows x64 / aarch64) and attaches the binaries to the tag.

## See also

- [Architecture](./architecture.md) for the system-level orientation map.
- [Troubleshooting](./troubleshooting.md) for issues that have already been hit and fixed (so you can grep for "this looks familiar").
