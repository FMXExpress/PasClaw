program prompt_batching_tests;
(*
  Pins the "batch independent investigation" rule to the behaviour it
  promises.

  Why this exists
  ===============

  The tool loop has been able to dispatch a round's read-only calls in
  parallel for a long time (PasClaw.Tools.ToolLoop: tcReadOnly calls
  coalesce into one batch, each mutating call is a batch of one). But a
  batch only forms when the MODEL emits several tool_use blocks in a
  single response -- and nothing in the system prompt ever asked it to.
  The machinery was built and under-fed: it fired only when the model
  happened to batch on its own.

  The prompt now names the tools that run in parallel. That creates the
  failure mode this file exists to prevent: the prompt asserts a
  CATEGORY that a different unit owns. Flip read_file to tcMutating and
  the prompt starts advertising parallelism the loop will never deliver
  -- the same "two owners of one decision" shape that has bitten this
  codebase repeatedly, except here it degrades silently into wasted
  round trips rather than a visible break.

  So: for every tool the rule names as parallel-safe, assert the
  registry actually categorises it tcReadOnly, and for the ones it names
  as batch-splitting, assert they are not. The rule text and the
  registry cannot drift apart without this failing.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.FS,
  PasClaw.Agent.Prompt;

var
  Failures: Integer = 0;

procedure Check(const Name: string; Cond: Boolean);
begin
  if Cond then
    WriteLn('  ok    ', Name)
  else
  begin
    WriteLn('  FAIL  ', Name);
    Inc(Failures);
  end;
end;

{ The tools the rule advertises as running in parallel. Keep in step with
  the rule text in PasClaw.Agent.Prompt -- that is the point of the file. }
const
  PARALLEL_TOOLS: array[0..3] of string =
    ('read_file', 'list_dir', 'grep_files', 'find_files');
  { Named in the rule as state-changing, i.e. they split the batch. }
  SERIAL_TOOLS: array[0..3] of string =
    ('write_file', 'append_file', 'edit_file', 'apply_patch');

procedure TestRuleIsInThePrompt;
var
  Cfg: TConfig;
  P: string;
  Rule: string;
begin
  WriteLn('the rule reaches the model');
  Cfg := TConfig.Create;
  try
    P := BuildSystemPrompt(Cfg, '');
  finally
    Cfg.Free;
  end;
  Check('prompt carries the batching rule',
    Pos('Batch independent investigation', P) > 0);
  { The whole value is the model knowing these arrive together. }
  Check('rule names parallel dispatch', Pos('IN PARALLEL', P) > 0);
  Check('rule warns that mutations split the batch',
    Pos('SPLITS the batch', P) > 0);
  { gather -> edit -> verify, not gather -> edit -> gather -> edit }
  Check('rule keeps the dependent half sequential',
    (Pos('sequential', P) > 0) and (Pos('one focused check', P) > 0));

  { The rule must name tools that EXIST. The first draft said
    `run_command`, which is registered nowhere -- RegisterShellTool
    exposes the command tool as `shell_exec` (Codex P2 on PR #537). A
    model told to watch for a phantom tool cannot recognise the thing
    that actually splits its batch. }
  Check('names the real shell tool', Pos('`shell_exec`', P) > 0);
  Check('does not name a phantom run_command', Pos('run_command', P) = 0);

  { memory_search is registered tcReadOnly, so ToolLoop WILL batch it --
    but Tool_MemorySearch calls IMemoryIndex.SyncDir, which reindexes and
    deletes rows in .index.db. Two of them in one batch are two writers
    on one SQLite file. The category cannot simply be corrected either:
    tcReadOnly doubles as the plan-mode dispatch gate (see
    PasClaw.Tools.PlanWrite), so flipping it would break memory_search in
    plan mode. Until that overload is untangled, THIS RULE must not invite
    the model to batch it.

    Scoped to rule 7 on purpose: rule 5 tells the model to call
    memory_search before answering from prior conversations, which is a
    perfectly good instruction. Only the batching claim is the problem. }
  Rule := Copy(P, Pos('Batch independent investigation', P), MaxInt);
  Check('rule 7 was located', Rule <> '');
  Check('rule 7 does not advertise memory_search as parallel-safe',
    Pos('memory_search', Rule) = 0);
  Check('rule 7 does not advertise kb_search as parallel-safe',
    Pos('kb_search', Rule) = 0);
end;

procedure TestPromiseMatchesRegistry;
var
  Reg: TToolRegistry;
  T: TTool;
  i: Integer;
begin
  WriteLn('every tool the rule calls parallel-safe really is');
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);
    for i := 0 to High(PARALLEL_TOOLS) do
    begin
      if not Reg.Find(PARALLEL_TOOLS[i], T) then
      begin
        Check(PARALLEL_TOOLS[i] + ' is registered', False);
        Continue;
      end;
      { tcReadOnly is what makes ToolLoop coalesce it into one batch. }
      Check(PARALLEL_TOOLS[i] + ' is tcReadOnly (so it actually batches)',
        T.Category = tcReadOnly);
    end;

    WriteLn('every tool the rule calls batch-splitting really is');
    for i := 0 to High(SERIAL_TOOLS) do
    begin
      if not Reg.Find(SERIAL_TOOLS[i], T) then
      begin
        Check(SERIAL_TOOLS[i] + ' is registered', False);
        Continue;
      end;
      Check(SERIAL_TOOLS[i] + ' is NOT tcReadOnly (so it stays serial)',
        T.Category <> tcReadOnly);
    end;
  finally
    Reg.Free;
  end;
end;

begin
  WriteLn('prompt batching rule');
  TestRuleIsInThePrompt;
  TestPromiseMatchesRegistry;
  WriteLn;
  if Failures = 0 then
    WriteLn('all prompt batching tests passed')
  else
  begin
    WriteLn(Failures, ' prompt batching test(s) FAILED');
    Halt(1);
  end;
end.
