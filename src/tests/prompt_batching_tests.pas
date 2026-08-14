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
  PasClaw.Providers.Types,   { TToolCall }
  PasClaw.Tools.ToolLoop,    { PartitionToolBatches -- the decision under test }
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

    { The tools the rule advertises must ALSO not be SerialOnly, or they
      would be named parallel-safe while opting out of batching. }
    WriteLn('advertised tools are not opted out of batching');
    for i := 0 to High(PARALLEL_TOOLS) do
      if Reg.Find(PARALLEL_TOOLS[i], T) then
        Check(PARALLEL_TOOLS[i] + ' is not SerialOnly', not T.SerialOnly);

    { todo_write writes the checklist file. It stays tcReadOnly so the
      progress ledger keeps discounting it, and is SerialOnly so two
      whole-file replacements cannot land at once -- the two meanings
      Category used to conflate. }
    WriteLn('writers that pass the plan gate still refuse to share a batch');
    if Reg.Find('todo_write', T) then
    begin
      Check('todo_write is still tcReadOnly (ledger + plan gate)',
        T.Category = tcReadOnly);
      Check('todo_write is SerialOnly (it rewrites a file)', T.SerialOnly);
    end
    else
      Check('todo_write is registered', False);
  finally
    Reg.Free;
  end;
end;

{ The decision itself, not the flags that feed it. A writer sharing a batch
  with anything else is the actual defect; everything above is indirection
  toward this. }
procedure TestWritersDoNotShareABatch;
var
  Reg: TToolRegistry;
  Calls: array of TToolCall;
  Batches: TToolBatchArray;

  procedure Call_(Idx: Integer; const Name: string);
  begin
    Calls[Idx].Id        := 'c' + IntToStr(Idx);
    Calls[Idx].Kind      := 'function';
    Calls[Idx].Func.Name := Name;
    Calls[Idx].Func.Arguments := '{}';
  end;

begin
  WriteLn('the batcher keeps writers out of shared batches');
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);

    { three reads in a row are exactly what rule 7 asks for }
    SetLength(Calls, 3);
    Call_(0, 'read_file'); Call_(1, 'list_dir'); Call_(2, 'grep_files');
    Batches := PartitionToolBatches(Calls, Reg);
    Check('three independent reads coalesce into ONE batch',
      (Length(Batches) = 1) and (Length(Batches[0]) = 3));

    { todo_write writes a file: it must interrupt the run, not join it.
      Before SerialOnly this produced a single batch of three, running the
      writer concurrently with the reads. }
    SetLength(Calls, 3);
    Call_(0, 'read_file'); Call_(1, 'todo_write'); Call_(2, 'read_file');
    Batches := PartitionToolBatches(Calls, Reg);
    Check('a tcReadOnly WRITER splits the batch (3 batches, not 1)',
      Length(Batches) = 3);
    if Length(Batches) = 3 then
      Check('the writer is alone in its batch', Length(Batches[1]) = 1);

  finally
    Reg.Free;
  end;
end;

function StubHandler(const ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := ''; Result := '';
end;

{ Most registration sites build TTool as a BARE stack record and assign
  fields one at a time -- they never touch SerialOnly, so it holds whatever
  the stack held. The batcher reads that field, so an unassigned byte could
  decide whether a tool runs concurrently: a parallel-safe tool that
  happened to read True would silently stop batching (Codex P2, PR #538).

  The registry therefore derives the field from ToolIsSerialOnly and
  IGNORES the incoming value. These cases set it to the WRONG value on
  purpose -- standing in for stack garbage in both directions -- and assert
  registration corrects it. }
procedure TestRegistryNormalizesSerialOnly;
var
  Reg: TToolRegistry;
  T: TTool;          { deliberately NOT Default(TTool) -- that is the point }
  Calls: array of TToolCall;
  Batches: TToolBatchArray;
begin
  WriteLn('registration fixes the field the callers never set');
  Reg := TToolRegistry.Create;
  try
    { a plain read-only tool arriving with a garbage-True SerialOnly }
    T.Name        := 'fake_reader';
    T.Description := 'stub';
    T.Schema      := '{"type":"object","properties":{}}';
    T.Handler     := StubHandler;
    T.HandlerObj  := nil;
    T.IsCore      := False;
    T.Category    := tcReadOnly;
    T.IsDeferred  := False;
    T.Hidden      := False;
    T.SerialOnly  := True;          { <- the stack garbage stand-in }
    Reg.Register(T);
    Check('a garbage True is cleared for a tool not on the list',
      Reg.Find('fake_reader', T) and (not T.SerialOnly));

    { and the reverse: a listed writer arriving with False must come back
      True, so forgetting the field cannot un-protect a writer }
    T.Name        := 'memory_search';
    T.Description := 'stub';
    T.Schema      := '{"type":"object","properties":{}}';
    T.Handler     := StubHandler;
    T.HandlerObj  := nil;
    T.IsCore      := False;
    T.Category    := tcReadOnly;
    T.IsDeferred  := False;
    T.Hidden      := False;
    T.SerialOnly  := False;         { <- caller never set it }
    Reg.Register(T);
    Check('a listed writer is marked SerialOnly regardless of the caller',
      Reg.Find('memory_search', T) and T.SerialOnly);

    { the decision that matters: the stack-built reader still batches }
    SetLength(Calls, 2);
    Calls[0].Func.Name := 'fake_reader'; Calls[0].Func.Arguments := '{}';
    Calls[1].Func.Name := 'fake_reader'; Calls[1].Func.Arguments := '{}';
    Batches := PartitionToolBatches(Calls, Reg);
    Check('a stack-registered read-only tool still coalesces',
      (Length(Batches) = 1) and (Length(Batches[0]) = 2));

    { ...and two memory_searches do not }
    SetLength(Calls, 2);
    Calls[0].Func.Name := 'memory_search'; Calls[0].Func.Arguments := '{}';
    Calls[1].Func.Name := 'memory_search'; Calls[1].Func.Arguments := '{}';
    Batches := PartitionToolBatches(Calls, Reg);
    Check('two memory_search calls never share a batch',
      Length(Batches) = 2);
  finally
    Reg.Free;
  end;
end;

begin
  WriteLn('prompt batching rule');
  TestRuleIsInThePrompt;
  TestPromiseMatchesRegistry;
  TestWritersDoNotShareABatch;
  TestRegistryNormalizesSerialOnly;
  WriteLn;
  if Failures = 0 then
    WriteLn('all prompt batching tests passed')
  else
  begin
    WriteLn(Failures, ' prompt batching test(s) FAILED');
    Halt(1);
  end;
end.
