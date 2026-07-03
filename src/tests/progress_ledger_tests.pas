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
    procedure AddTruncated(const Text: string; const Finish: string = 'length');
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

procedure TScripted.AddTruncated(const Text: string; const Finish: string);
{ A no-tool-call turn that failed recoverably: text content, no tool call,
  finish_reason = length (output ceiling) or MALFORMED_FUNCTION_CALL. }
var
  R: TLLMResponse;
begin
  R := Default(TLLMResponse);
  R.StatusCode := 200;
  R.FinishReason := Finish;
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

procedure RunRecoveryCase(const Finish: string);
{ A no-tool-call turn that failed for `Finish` in a tool-enabled build
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
    P.AddTruncated('Let me build this. ### Bullets: procedure DrawBullet(X,Y: Integer); begin', Finish);
    P.AddToolRound([MkCall('write_file', '{"path":"' + FileA + '","content":"ok"}')]);
    P.AddStop('done');

    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'build a small demo in the workspace');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran (' + Finish + ')');
    AssertTrue(Length(P.Prompts) = 3,
      Finish + ': failed turn retried, then wrote, then stopped (3 calls)');
    AssertHas(P.Prompts[1], 'no usable tool call',
      Finish + ': retry prompt carries the recovery nudge');
    AssertHas(P.Prompts[1], 'write_file', Finish + ': nudge names the writing tool');
    AssertTrue(FileExists(FileA), Finish + ': deliverable landed after recovery');
    AssertNot(Loop.Content, 'DrawBullet', Finish + ': final content is not the ramble');
  finally
    Reg.Free;
  end;
end;

procedure TestTruncationRecoveryWithTools;
begin
  RunRecoveryCase('length');                    { output-ceiling truncation }
  RunRecoveryCase('MALFORMED_FUNCTION_CALL');   { Gemini malformed call + narration }
  WriteLn('  ok: tool-enabled length + MALFORMED_FUNCTION_CALL turns recover, nudge, and deliver');
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

procedure TestElideLargeToolArgsUnit;
{ Direct: a big string field is stubbed, small fields survive, and small
  args are returned verbatim. }
var
  Big, Small, Outp: string;
begin
  Big := '{"path":"index.html","content":"' + StringOfChar('x', 5000) + '"}';
  Outp := ElideLargeToolArgs(Big, 2048);
  AssertHas(Outp, 'index.html', 'path survives elision');
  AssertHas(Outp, 'elided', 'oversized content is elided');
  AssertTrue(Pos(StringOfChar('x', 3000), Outp) = 0, 'the 5000-char blob is gone');
  AssertTrue(Length(Outp) < 300, 'elided args are compact (got ' + IntToStr(Length(Outp)) + ')');

  Small := '{"path":"a.txt","content":"hello","plain":true}';
  AssertTrue(ElideLargeToolArgs(Small, 2048) = Small, 'small args returned verbatim');

  { A large `patch` is NEVER elided -- Session.Store working-state and the
    web UI parse the envelope's file paths back out of it. }
  Big := '{"patch":"*** Begin Patch\n' + StringOfChar('p', 5000) + '\n*** End Patch"}';
  AssertTrue(ElideLargeToolArgs(Big, 2048) = Big, 'a large patch field is preserved');
  WriteLn('  ok: ElideLargeToolArgs stubs big content, keeps small + structural (patch) fields');
end;

procedure TestHistoryElidesBigWrite;
{ End-to-end: a big write_file lands FULL content on disk (dispatch uses
  the real args) but the assistant turn kept in Loop.FinalMessages carries
  the elided stub, so it won't be re-shipped verbatim next turn. }
var
  P: TScripted;
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
  i, k: Integer;
  Elided: Boolean;
  Disk, Err: string;
begin
  if FileExists(FileA) then DeleteFile(FileA);
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);
    P := TScripted.Create;
    Cfg := BaseCfg(P);
    Cfg.Registry := Reg;
    P.AddToolRound([MkCall('write_file',
      '{"path":"' + FileA + '","content":"' + StringOfChar('Z', 5000) + '"}')]);
    P.AddStop('done');
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'write a big file');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran');

    Elided := False;
    for i := 0 to High(Loop.FinalMessages) do
      for k := 0 to High(Loop.FinalMessages[i].ToolCalls) do
        if Pos('elided', Loop.FinalMessages[i].ToolCalls[k].Func.Arguments) > 0 then
          Elided := True;
    AssertTrue(Elided, 'big write_file args are elided in the persisted history');

    Disk := Reg.RunTool('read_file', '{"path":"' + FileA + '","plain":true}', Err);
    AssertTrue(Length(Disk) >= 5000,
      'file on disk got the FULL content -- dispatch used the real args (got ' +
      IntToStr(Length(Disk)) + ')');
    WriteLn('  ok: big write elided in history, full content still written to disk');
  finally
    Reg.Free;
  end;
end;

procedure TestSignedToolCallNotElided;
{ Gemini 3 signs its tool calls (ProviderSignature). Mutating the args
  would invalidate the echoed signature, so a signed call's big content is
  left intact even above the threshold. }
var
  P: TScripted;
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
  Call: TToolCall;
  i, k: Integer;
  FullKept: Boolean;
begin
  if FileExists(FileA) then DeleteFile(FileA);
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);
    P := TScripted.Create;
    Cfg := BaseCfg(P);
    Cfg.Registry := Reg;
    Call := MkCall('write_file',
      '{"path":"' + FileA + '","content":"' + StringOfChar('S', 5000) + '"}');
    Call.ProviderSignature := 'gemini-thought-sig';
    P.AddToolRound([Call]);
    P.AddStop('done');
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'write a big signed file');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran');

    FullKept := False;
    for i := 0 to High(Loop.FinalMessages) do
      for k := 0 to High(Loop.FinalMessages[i].ToolCalls) do
        if (Loop.FinalMessages[i].ToolCalls[k].ProviderSignature <> '') and
           (Pos(StringOfChar('S', 4000),
                Loop.FinalMessages[i].ToolCalls[k].Func.Arguments) > 0) then
          FullKept := True;
    AssertTrue(FullKept,
      'a signed tool call keeps its full args so the thoughtSignature stays valid');
    WriteLn('  ok: signed (Gemini 3) tool call args are NOT elided');
  finally
    Reg.Free;
  end;
end;

procedure TestSupersededReadStubbed;
{ A read_file result made stale by a LATER write of the same path is stubbed
  in the replayed/persisted history so its obsolete bytes don't ride along. }
var
  P: TScripted;
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
  i: Integer;
  Err: string;
  Stubbed, StaleBody: Boolean;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);
    { Seed FileA with >200 bytes so its read result is worth stubbing. }
    Reg.RunTool('write_file',
      '{"path":"' + FileA + '","content":"' + StringOfChar('A', 500) + '"}', Err);
    P := TScripted.Create;
    Cfg := BaseCfg(P);
    Cfg.Registry := Reg;
    P.AddToolRound([MkCall('read_file', '{"path":"' + FileA + '","plain":true}')]);
    P.AddToolRound([MkCall('write_file', '{"path":"' + FileA + '","content":"rewritten"}')]);
    P.AddStop('done');
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'read then rewrite the file');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran');

    Stubbed := False;
    StaleBody := False;
    for i := 0 to High(Loop.FinalMessages) do
    begin
      if (Loop.FinalMessages[i].Role = mrTool) and
         (Pos('superseded read_file', Loop.FinalMessages[i].Content) > 0) then
        Stubbed := True;
      if Pos(StringOfChar('A', 300), Loop.FinalMessages[i].Content) > 0 then
        StaleBody := True;
    end;
    AssertTrue(Stubbed, 'the pre-write read_file result was stubbed as superseded');
    AssertTrue(not StaleBody, 'the stale 500-byte read body is gone from history');
    AssertTrue(FileExists(FileA), 'file still exists after rewrite (dispatch unaffected)');
    WriteLn('  ok: read_file result superseded by a later write is stubbed');
  finally
    Reg.Free;
  end;
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
  TestElideLargeToolArgsUnit;
  TestHistoryElidesBigWrite;
  TestSignedToolCallNotElided;
  TestSupersededReadStubbed;

  if FileExists(FileA) then DeleteFile(FileA);
  RemoveDir(WsDir);
  WriteLn('PASS');
end.
