program progress_ledger_tests;
(*
  Covers the RunToolLoop progress ledger (goal anchor + todo checklist +
  resume summary):

    * Iteration 1's system prompt is pristine (no ledger -- keeps the
      cross-turn prefix-cache hit); iteration 2+ carries the
      "[progress ledger" block with the goal, the files written so far,
      and the model's todo_write checklist.
    * The base system prompt is preserved: the fold is appended after it
      and restored afterwards (Loop.FinalSystemPrompt = base).
    * The nothing-written nudge fires only after LedgerNudgeAfter (8)
      tool calls with zero mutating calls -- and not before.
    * A max-iterations stop fills Loop.LedgerSummary (files written, reads)
      and FormatMaxIterNotice appends it with the do-NOT-redo instruction.
    * The goal is the last SUBSTANTIVE user message -- a trailing
      "continue" micro-turn does not become the goal.
    * DisableProgressLedger switches all of it off.

  Strategy: scripted ILLMProvider that records each provider call's
  Options.SystemPrompt and returns canned tool-call rounds against a real
  registry (RegisterFSTools on a temp workspace), so the write_file /
  read_file / todo_write dispatches the ledger harvests are the real ones.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Agent.Mode,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.Sandbox,
  PasClaw.Tools.FS,
  PasClaw.Tools.ToolLoop;

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertHas(const Hay, Needle, Msg: string);
begin
  if Pos(Needle, Hay) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing from "' + Copy(Hay, 1, 400) + '")');
end;

procedure AssertNot(const Hay, Needle, Msg: string);
begin
  if Pos(Needle, Hay) > 0 then
    Fail_(Msg + ' (unexpected "' + Needle + '" in "' + Copy(Hay, 1, 400) + '")');
end;

type
  { Scripted provider: returns Script[i] on call i (clamping to the last
    entry) and records every call's Options.SystemPrompt. }
  TScripted = class(TInterfacedObject, ILLMProvider)
  public
    Script:  array of TLLMResponse;
    Prompts: array of string;
    procedure AddToolRound(const Calls: array of TToolCall);
    procedure AddStop(const Text: string);
    procedure AddTruncated(const Text: string);
    function Chat(const Messages: array of TMessage;
                  const Tools:    array of TToolDefinition;
                  const Model:    string;
                  const Options:  TChatOptions): TLLMResponse;
    function ChatStream(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
  end;

procedure TScripted.AddToolRound(const Calls: array of TToolCall);
var
  R: TLLMResponse;
  i: Integer;
begin
  R := Default(TLLMResponse);
  R.StatusCode := 200;
  R.FinishReason := 'tool_calls';
  SetLength(R.ToolCalls, Length(Calls));
  for i := 0 to High(Calls) do R.ToolCalls[i] := Calls[i];
  SetLength(Script, Length(Script) + 1);
  Script[High(Script)] := R;
end;

procedure TScripted.AddStop(const Text: string);
var
  R: TLLMResponse;
begin
  R := Default(TLLMResponse);
  R.StatusCode := 200;
  R.FinishReason := 'stop';
  R.Content := Text;
  SetLength(Script, Length(Script) + 1);
  Script[High(Script)] := R;
end;

procedure TScripted.AddTruncated(const Text: string);
{ A turn that hit the output ceiling: text content, no tool call,
  finish_reason=length. }
var
  R: TLLMResponse;
begin
  R := Default(TLLMResponse);
  R.StatusCode := 200;
  R.FinishReason := 'length';
  R.Content := Text;
  SetLength(Script, Length(Script) + 1);
  Script[High(Script)] := R;
end;

function TScripted.Chat(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions): TLLMResponse;
var
  Idx: Integer;
begin
  SetLength(Prompts, Length(Prompts) + 1);
  Prompts[High(Prompts)] := Options.SystemPrompt;
  Idx := High(Prompts);
  if Idx > High(Script) then Idx := High(Script);
  if Idx < 0 then
  begin
    Result := Default(TLLMResponse);
    Result.StatusCode := 200;
    Result.FinishReason := 'stop';
    Exit;
  end;
  Result := Script[Idx];
end;

function TScripted.ChatStream(const Messages: array of TMessage;
                              const Tools:    array of TToolDefinition;
                              const Model:    string;
                              const Options:  TChatOptions;
                              OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

function TScripted.GetDefaultModel: string;      begin Result := 'scripted'; end;
function TScripted.GetName: string;              begin Result := 'scripted'; end;
function TScripted.SupportsThinking: Boolean;     begin Result := False; end;
function TScripted.SupportsNativeSearch: Boolean; begin Result := False; end;
function TScripted.SupportsStreaming: Boolean;    begin Result := False; end;

function MkCall(const Name, ArgsJSON: string): TToolCall;
begin
  Result := Default(TToolCall);
  Result.Id := 'c_' + Name;
  Result.Kind := 'function';
  Result.Func.Name := Name;
  Result.Func.Arguments := ArgsJSON;
end;

var
  WsDir, FileA: string;

function BaseCfg(P: TScripted): TToolLoopConfig;
begin
  Result := Default(TToolLoopConfig);
  Result.Provider      := P;
  Result.Model         := 'scripted';
  Result.MaxIterations := 10;
  Result.Options       := DefaultChatOptions;
  Result.Options.SystemPrompt := 'BASE-PROMPT';
  Result.Parallel      := False;
  Result.Mode          := pmBuild;
end;

procedure TestFoldGoalFilesChecklist;
var
  P: TScripted;
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);
    P := TScripted.Create;
    Cfg := BaseCfg(P);
    Cfg.Registry := Reg;
    P.AddToolRound([
      MkCall('write_file', '{"path":"' + FileA + '","content":"hello"}'),
      MkCall('todo_write', '{"checklist":"- [x] write a.txt\n- [ ] verify it"}')
    ]);
    P.AddToolRound([MkCall('read_file', '{"path":"' + FileA + '","plain":true}')]);
    P.AddStop('done');

    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'build me a small demo page in the workspace please');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran');
    AssertTrue(Length(P.Prompts) = 3, 'three provider calls');

    { Iteration 1: pristine prompt (cache-friendly, nothing to report). }
    AssertHas(P.Prompts[0], 'BASE-PROMPT', 'call 1 carries the base prompt');
    AssertNot(P.Prompts[0], '[progress ledger', 'no ledger on iteration 1');

    { Iteration 2: ledger with goal + written file + checklist, appended
      after the base prompt. }
    AssertHas(P.Prompts[1], 'BASE-PROMPT', 'call 2 keeps the base prompt');
    AssertHas(P.Prompts[1], '[progress ledger', 'ledger folded on iteration 2');
    AssertHas(P.Prompts[1], 'build me a small demo page', 'goal anchored');
    AssertHas(P.Prompts[1], 'a.txt', 'written file listed');
    AssertHas(P.Prompts[1], '- [ ] verify it', 'todo_write checklist folded');
    AssertNot(P.Prompts[1], 'Progress check', 'no nudge -- a mutating call landed');

    { Ephemeral: the fold never leaks into the persisted prompt. }
    AssertTrue(Loop.FinalSystemPrompt = 'BASE-PROMPT',
      'FinalSystemPrompt restored to the base (fold is ephemeral)');
    WriteLn('  ok: fold carries goal + files + checklist from iteration 2, ephemerally');
  finally
    Reg.Free;
  end;
end;

procedure TestNudgeAfterReadOnlyCalls;
var
  P: TScripted;
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
  ListCall: TToolCall;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);
    P := TScripted.Create;
    Cfg := BaseCfg(P);
    Cfg.Registry := Reg;
    ListCall := MkCall('list_dir', '{"path":"' + WsDir + '"}');
    { 3 rounds x 3 read-only calls = 9 >= LedgerNudgeAfter (8). }
    P.AddToolRound([ListCall, ListCall, ListCall]);
    P.AddToolRound([ListCall, ListCall, ListCall]);
    P.AddToolRound([ListCall, ListCall, ListCall]);
    P.AddStop('answer');

    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'please build the demo site now, files required');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran');
    AssertTrue(Length(P.Prompts) = 4, 'four provider calls');
    AssertNot(P.Prompts[1], 'Progress check', 'no nudge at 3 calls');
    AssertNot(P.Prompts[2], 'Progress check', 'no nudge at 6 calls');
    AssertHas(P.Prompts[3], 'Progress check', 'nudge fires at 9 read-only calls');
    AssertHas(P.Prompts[3], '(none yet)', 'files line reports none written');
    WriteLn('  ok: nothing-written nudge fires only past the threshold');
  finally
    Reg.Free;
  end;
end;

procedure TestMaxIterSummaryAndNotice;
var
  P: TScripted;
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
  Notice: string;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);
    P := TScripted.Create;
    Cfg := BaseCfg(P);
    Cfg.Registry := Reg;
    Cfg.MaxIterations := 2;
    P.AddToolRound([MkCall('write_file', '{"path":"' + FileA + '","content":"x"}')]);
    P.AddToolRound([MkCall('read_file', '{"path":"' + FileA + '","plain":true}')]);

    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'multi step task that will hit the iteration cap');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran');
    AssertTrue(Loop.HitMaxIterations, 'hit the cap');
    AssertHas(Loop.LedgerSummary, 'a.txt', 'summary lists the written file');
    AssertHas(Loop.LedgerSummary, 'read 1 file', 'summary counts the read');

    Notice := FormatMaxIterNotice(Loop, 2, '--max-iter', True);
    AssertHas(Notice, 'do NOT redo', 'notice forbids redoing completed work');
    AssertHas(Notice, 'a.txt', 'notice carries the ledger detail');
    AssertHas(Notice, 'continue', 'notice still offers the resume');
    WriteLn('  ok: max-iter stop carries the resume ledger into the notice');
  finally
    Reg.Free;
  end;
end;

procedure TestGoalSkipsMicroTurns;
var
  P: TScripted;
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);
    P := TScripted.Create;
    Cfg := BaseCfg(P);
    Cfg.Registry := Reg;
    P.AddToolRound([MkCall('list_dir', '{"path":"' + WsDir + '"}')]);
    P.AddStop('done');

    SetLength(Msgs, 3);
    Msgs[0] := MakeMessage(mrUser, 'refactor the parser module to use the new tokenizer');
    Msgs[1] := MakeMessage(mrAssistant, '[stopped: hit the tool-call limit]');
    Msgs[2] := MakeMessage(mrUser, 'continue');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran');
    AssertHas(P.Prompts[1], 'refactor the parser module',
      'goal anchors to the substantive task, not to "continue"');
    WriteLn('  ok: goal extraction skips trailing micro-turns');
  finally
    Reg.Free;
  end;
end;

procedure TestRepeatReadDedup;
{ C3: a second identical read of the same unchanged file within one loop
  is swapped for a one-line stub; a range read (different body) is not. }
var
  P: TScripted;
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
  i, Full, Stub: Integer;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);
    P := TScripted.Create;
    Cfg := BaseCfg(P);
    Cfg.Registry := Reg;
    P.AddToolRound([MkCall('write_file', '{"path":"' + FileA + '","content":"same body here"}')]);
    P.AddToolRound([MkCall('read_file', '{"path":"' + FileA + '","plain":true}')]);
    P.AddToolRound([MkCall('read_file', '{"path":"' + FileA + '","plain":true}')]);
    P.AddStop('done');

    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'read the file twice for no reason at all');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran');
    Full := 0; Stub := 0;
    for i := 0 to High(Loop.FinalMessages) do
      if Loop.FinalMessages[i].Role = mrTool then
      begin
        if Pos('same body here', Loop.FinalMessages[i].Content) > 0 then Inc(Full);
        if Pos('unchanged since the earlier read', Loop.FinalMessages[i].Content) > 0 then Inc(Stub);
      end;
    AssertTrue(Full = 1, Format('exactly one full body in history (got %d)', [Full]));
    AssertTrue(Stub = 1, Format('the repeat read became a stub (got %d)', [Stub]));
    WriteLn('  ok: repeat read of an unchanged file dedups to a stub');
  finally
    Reg.Free;
  end;
end;

procedure TestDisableSwitch;
var
  P: TScripted;
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
  i: Integer;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);
    P := TScripted.Create;
    Cfg := BaseCfg(P);
    Cfg.Registry := Reg;
    Cfg.DisableProgressLedger := True;
    Cfg.MaxIterations := 2;
    P.AddToolRound([MkCall('write_file', '{"path":"' + FileA + '","content":"x"}')]);
    P.AddToolRound([MkCall('read_file', '{"path":"' + FileA + '","plain":true}')]);

    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'a long enough task message for goal capture');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran');
    for i := 0 to High(P.Prompts) do
      AssertNot(P.Prompts[i], '[progress ledger', 'no ledger when disabled');
    AssertTrue(Loop.LedgerSummary = '', 'no summary when disabled');
    WriteLn('  ok: DisableProgressLedger turns the ledger off');
  finally
    Reg.Free;
  end;
end;

procedure TestTruncationRecoveryWithTools;
{ A truncated (finish=length) no-tool-call turn in a tool-enabled build
  session must NOT end the loop: fold a nudge, retry, and let the write land. }
var
  P: TScripted;
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
begin
  if FileExists(FileA) then DeleteFile(FileA);
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);
    P := TScripted.Create;
    Cfg := BaseCfg(P);
    Cfg.Registry := Reg;
    P.AddTruncated('Let me build this. ### Bullets: procedure DrawBullet(X,Y: Integer); begin');
    P.AddToolRound([MkCall('write_file', '{"path":"' + FileA + '","content":"ok"}')]);
    P.AddStop('done');

    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'build a small demo in the workspace');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran');
    AssertTrue(Length(P.Prompts) = 3,
      'truncated turn retried, then wrote, then stopped (3 calls)');
    AssertHas(P.Prompts[1], 'cut off at the output token limit',
      'retry prompt carries the truncation nudge');
    AssertHas(P.Prompts[1], 'write_file', 'nudge names the writing tool');
    AssertTrue(FileExists(FileA), 'deliverable landed after recovery');
    AssertNot(Loop.Content, 'DrawBullet', 'final content is not the truncated prose');
    WriteLn('  ok: tool-enabled truncated turn recovers, nudges, and delivers');
  finally
    Reg.Free;
  end;
end;

procedure TestTruncationNoToolsReturnsContent;
{ Review fix (P2 on #420): with no writing tool available (Registry=nil /
  UseTools=False / plan mode), a truncated no-tool-call turn is a long TEXT
  answer -- its content is the deliverable. It must be returned as-is, NOT
  dropped and retried against tools that don't exist. }
var
  P: TScripted;
  Cfg: TToolLoopConfig;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
begin
  P := TScripted.Create;
  Cfg := BaseCfg(P);   { Registry stays nil -> no tools on offer }
  P.AddTruncated('Here is a long explanation that got cut off at the limit');
  P.AddStop('SHOULD-NOT-REACH');
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'explain this topic at length');
  AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran');
  AssertTrue(Length(P.Prompts) = 1,
    'no-tools truncated turn is returned, not retried (single provider call)');
  AssertHas(Loop.Content, 'long explanation that got cut off',
    'the truncated text is returned as the deliverable');
  WriteLn('  ok: no-tools truncated answer returned as-is, no nudge, no retry');
end;

var
  Pol: TSandboxPolicy;
begin
  WsDir := IncludeTrailingPathDelimiter(GetTempDir) + 'pcledger';
  ForceDirectories(WsDir);
  FileA := WsDir + PathDelim + 'a.txt';
  Pol := Default(TSandboxPolicy);
  Pol.RestrictToWorkspace := False;
  ConfigureSandbox(Pol, WsDir);

  TestFoldGoalFilesChecklist;
  TestNudgeAfterReadOnlyCalls;
  TestMaxIterSummaryAndNotice;
  TestGoalSkipsMicroTurns;
  TestRepeatReadDedup;
  TestDisableSwitch;
  TestTruncationRecoveryWithTools;
  TestTruncationNoToolsReturnsContent;

  if FileExists(FileA) then DeleteFile(FileA);
  RemoveDir(WsDir);
  WriteLn('PASS');
end.
