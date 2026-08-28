program plan_build_mode_tests;
(*
  PR #290: Plan / Build mode plumbing.

  Coverage:
    - PasClaw.Agent.Mode: ParseMode aliases, CycleMode, refusal text,
      ParseModeFromBody pulls "mode" out of a chat-request JSON body
      and defaults to pmBuild on absent / invalid input.
    - Dispatch gate (integration): build a registry with one tcReadOnly
      and one tcMutating tool, run the loop with a synthetic provider
      that issues both tool calls, and verify:
        * pmBuild dispatches both
        * pmPlan dispatches the read tool but refuses the write tool
          with the standard refusal string + Err = 'plan mode'
    - SPACE-mode gate (docs/space-mode-plan.md): under pmSpace a
      mutating tool is refused UNTIL plan_write succeeds, unlocked
      after, left closed by a FAILED plan_write, and pre-opened when
      workspace/PLAN.md already exists (the resume seeding). Requires
      $PASCLAW_HOME pointing at a scratch dir -- the Makefile target
      supplies one -- because the seeding reads ResolvePlanPath.

  No network / no provider keys -- the synthetic provider is a small
  ILLMProvider implementor in this file.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Agent.Mode,
  PasClaw.Agent.Prompt,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.PlanWrite,   { ResolvePlanPath -- the SPACE gate's seed key }
  PasClaw.Tools.ToolLoop;

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertEqS(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;

(* ----- Synthetic provider: round 1 issues both tool calls, round 2
   returns final content. ----- *)
type
  TFakeProvider = class(TInterfacedObject, ILLMProvider)
  private
    FRound: Integer;
  public
    function Chat(const Messages: array of TMessage;
                  const Tools: array of TToolDefinition;
                  const Model: string;
                  const Options: TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage;
                        const Tools: array of TToolDefinition;
                        const Model: string;
                        const Options: TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

function TFakeProvider.GetDefaultModel: string; begin Result := 'fake'; end;
function TFakeProvider.GetName: string;         begin Result := 'fake'; end;
function TFakeProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TFakeProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TFakeProvider.SupportsStreaming: Boolean;    begin Result := False; end;

function TFakeProvider.Chat(const Messages: array of TMessage;
                            const Tools: array of TToolDefinition;
                            const Model: string;
                            const Options: TChatOptions): TLLMResponse;
begin
  Inc(FRound);
  Result := Default(TLLMResponse);
  Result.StatusCode := 200;
  if FRound = 1 then
  begin
    SetLength(Result.ToolCalls, 2);
    Result.ToolCalls[0].Id            := 't1';
    Result.ToolCalls[0].Kind          := 'function';
    Result.ToolCalls[0].Func.Name     := 'fake_read';
    Result.ToolCalls[0].Func.Arguments := '{}';
    Result.ToolCalls[1].Id            := 't2';
    Result.ToolCalls[1].Kind          := 'function';
    Result.ToolCalls[1].Func.Name     := 'fake_write';
    Result.ToolCalls[1].Func.Arguments := '{}';
    Result.FinishReason := 'tool_calls';
  end
  else
  begin
    Result.Content := 'done';
    Result.FinishReason := 'stop';
  end;
end;

function TFakeProvider.ChatStream(const Messages: array of TMessage;
                                  const Tools: array of TToolDefinition;
                                  const Model: string;
                                  const Options: TChatOptions;
                                  OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

(* Tool handlers. *)
function HandleFakeRead(const A: string; out E: string): string;
begin E := ''; Result := 'READ OK'; end;
function HandleFakeWrite(const A: string; out E: string): string;
begin E := ''; Result := 'WRITE OK'; end;

(* Scripted provider for the SPACE scenarios: each round issues the
   entries given for that round as tool calls (call ids r<round>c<idx>),
   then a final stop round. An entry is 'name' or 'name|argsjson' --
   the split lets the REAL plan_write be driven with real content,
   which matters because the first version of this suite registered a
   FAKE under that name and thereby hid a real integration failure:
   plan_write was not registered outside --mode plan at all, so every
   real SPACE session was permanently read-only (Codex P1 on PR #595). *)
type
  TScriptProvider = class(TInterfacedObject, ILLMProvider)
  private
    FRound: Integer;
    FScript: array of TArray<string>;
  public
    constructor Create(const Script: array of TArray<string>);
    function Chat(const Messages: array of TMessage;
                  const Tools: array of TToolDefinition;
                  const Model: string;
                  const Options: TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage;
                        const Tools: array of TToolDefinition;
                        const Model: string;
                        const Options: TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

constructor TScriptProvider.Create(const Script: array of TArray<string>);
var
  i: Integer;
begin
  inherited Create;
  SetLength(FScript, Length(Script));
  for i := 0 to High(Script) do FScript[i] := Script[i];
end;

function TScriptProvider.GetDefaultModel: string; begin Result := 'fake'; end;
function TScriptProvider.GetName: string;         begin Result := 'fake'; end;
function TScriptProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TScriptProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TScriptProvider.SupportsStreaming: Boolean;    begin Result := False; end;

function TScriptProvider.Chat(const Messages: array of TMessage;
                              const Tools: array of TToolDefinition;
                              const Model: string;
                              const Options: TChatOptions): TLLMResponse;
var
  i, Bar: Integer;
  Entry: string;
begin
  Inc(FRound);
  Result := Default(TLLMResponse);
  Result.StatusCode := 200;
  if FRound <= Length(FScript) then
  begin
    SetLength(Result.ToolCalls, Length(FScript[FRound - 1]));
    for i := 0 to High(FScript[FRound - 1]) do
    begin
      Result.ToolCalls[i].Id        := Format('r%dc%d', [FRound, i]);
      Result.ToolCalls[i].Kind      := 'function';
      Entry := FScript[FRound - 1][i];
      Bar := Pos('|', Entry);
      if Bar > 0 then
      begin
        Result.ToolCalls[i].Func.Name      := Copy(Entry, 1, Bar - 1);
        Result.ToolCalls[i].Func.Arguments := Copy(Entry, Bar + 1, MaxInt);
      end
      else
      begin
        Result.ToolCalls[i].Func.Name      := Entry;
        Result.ToolCalls[i].Func.Arguments := '{}';
      end;
    end;
    Result.FinishReason := 'tool_calls';
  end
  else
  begin
    Result.Content := 'done';
    Result.FinishReason := 'stop';
  end;
end;

function TScriptProvider.ChatStream(const Messages: array of TMessage;
                                    const Tools: array of TToolDefinition;
                                    const Model: string;
                                    const Options: TChatOptions;
                                    OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

procedure TestParseMode;
var
  M: TPasClawMode;
begin
  AssertTrue(ParseMode('build', M) and (M = pmBuild), 'parse build');
  AssertTrue(ParseMode('plan', M)  and (M = pmPlan),  'parse plan');
  AssertTrue(ParseMode('p', M)     and (M = pmPlan),  'parse short p');
  AssertTrue(ParseMode('B', M)     and (M = pmBuild), 'parse short B (case-insens)');
  AssertTrue(ParseMode('', M)      and (M = pmBuild), 'parse empty -> build');
  AssertTrue(ParseMode('read-only', M) and (M = pmPlan), 'parse read-only alias');
  AssertTrue(not ParseMode('whatever', M), 'invalid mode rejected');

  { Improve: build's tool access, a method instead of a gate. The
    aliases are the words people actually reach for when describing
    the loop -- a mode you cannot name is a mode you will not use. }
  AssertTrue(ParseMode('improve', M)  and (M = pmImprove), 'parse improve');
  AssertTrue(ParseMode('i', M)        and (M = pmImprove), 'parse short i');
  AssertTrue(ParseMode('research', M) and (M = pmImprove), 'research alias');
  AssertTrue(ParseMode('auto', M)     and (M = pmImprove), 'auto alias');
  AssertTrue(ParseMode('optimise', M) and (M = pmImprove), 'optimise alias');
  AssertTrue(ParseMode('IMPROVE', M)  and (M = pmImprove), 'case-insensitive');

  { Space: Search, Plan, Assert, Code, Evaluate. }
  AssertTrue(ParseMode('space', M) and (M = pmSpace), 'parse space');
  AssertTrue(ParseMode('s', M)     and (M = pmSpace), 'parse short s');
  AssertTrue(ParseMode('tdd', M)   and (M = pmSpace), 'tdd alias');
  AssertTrue(ParseMode('spec', M)  and (M = pmSpace), 'spec alias');
  AssertTrue(ParseMode('SPACE', M) and (M = pmSpace), 'case-insensitive space');
end;

procedure TestCycleAndName;
var
  M: TPasClawMode;
begin
  AssertTrue(CycleMode(pmBuild)   = pmPlan,    'cycle build->plan');
  AssertTrue(CycleMode(pmPlan)    = pmImprove, 'cycle plan->improve');
  AssertTrue(CycleMode(pmImprove) = pmSpace,   'cycle improve->space');
  AssertTrue(CycleMode(pmSpace)   = pmBuild,   'cycle space->build');
  AssertEqS(ModeName(pmBuild),   'build',   'name build');
  AssertEqS(ModeName(pmPlan),    'plan',    'name plan');
  AssertEqS(ModeName(pmImprove), 'improve', 'name improve');
  AssertEqS(ModeName(pmSpace),   'space',   'name space');
  { Round-trip: every mode's name parses back to itself, so no surface
    can print a mode it cannot then be given. }
  AssertTrue(ParseMode(ModeName(pmBuild), M)   and (M = pmBuild),   'round-trip build');
  AssertTrue(ParseMode(ModeName(pmPlan), M)    and (M = pmPlan),    'round-trip plan');
  AssertTrue(ParseMode(ModeName(pmImprove), M) and (M = pmImprove), 'round-trip improve');
  AssertTrue(ParseMode(ModeName(pmSpace), M)   and (M = pmSpace),   'round-trip space');
end;

(* The mode directive, on its own.

   BuildModeSection exists because the gateway does not always call
   BuildSystemPrompt: a request carrying its own system message keeps
   that message as the authoritative policy and skips ours. Plan mode
   survived that skip (its dispatch gate is the authority); improve
   mode did not -- the block IS the mode, so those requests ran as
   ordinary builds while still reporting "improve". *)
procedure TestModeSection;
begin
  AssertEqS(BuildModeSection(pmBuild), '',
            'build has no directive -- callers append unconditionally');
  AssertTrue(Pos('Plan Mode', BuildModeSection(pmPlan)) > 0,
             'plan has one');
  AssertTrue(Pos('Improve Mode', BuildModeSection(pmImprove)) > 0,
             'and so does improve');
  { The loop is the mode, so its steps have to actually be in there. }
  AssertTrue(Pos('benchmark', LowerCase(BuildModeSection(pmImprove))) > 0,
             'improve says benchmark');
  AssertTrue(Pos('profile', LowerCase(BuildModeSection(pmImprove))) > 0,
             'and profile');
  AssertTrue(Pos('revert', LowerCase(BuildModeSection(pmImprove))) > 0,
             'and that a change which did not help gets reverted');
  { Space: the five phases, the unlock, and the honesty rules. }
  AssertTrue(Pos('Space Mode', BuildModeSection(pmSpace)) > 0, 'space has one');
  AssertTrue(Pos('plan_write', BuildModeSection(pmSpace)) > 0,
             'space names the unlock tool');
  AssertTrue(Pos('failing', LowerCase(BuildModeSection(pmSpace))) > 0,
             'space demands the check be seen failing');
  AssertTrue(Pos('not cover', LowerCase(BuildModeSection(pmSpace))) > 0,
             'space demands the not-covered statement');
end;

(* The other half of that branch: the directive actually reaching the
   request.

   BuildModeSection being right is not enough -- improve mode shipped
   once with a correct block that nothing on /v1/chat/completions or
   /v1/responses ever attached, because those surfaces skip
   BuildSystemPrompt entirely when the caller sends its own system
   message. What follows pins the wiring, not just the text. *)
procedure TestModeInjection;
var
  Msgs: TMessageArray;
  Caller: string;
begin
  Caller := 'You are Fizzbot. Never mention pandas.';

  SetLength(Msgs, 2);
  Msgs[0].Role := mrSystem;  Msgs[0].Content := Caller;
  Msgs[1].Role := mrUser;    Msgs[1].Content := 'make this faster';

  InjectModeDirective(Msgs, pmImprove);
  AssertTrue(Length(Msgs) = 2,
             'no message added -- Anthropic would drop a new trailing system turn');
  AssertTrue(Msgs[0].Role = mrSystem, 'the caller message is still a system turn');
  AssertTrue(Pos(Caller, Msgs[0].Content) = 1,
             'the caller policy survives, and still leads');
  AssertTrue(Pos('Improve Mode', Msgs[0].Content) > 0,
             'and the mode is now said out loud');
  AssertEqS(Msgs[1].Content, 'make this faster', 'the user turn is untouched');

  { pmBuild is the absence of a directive, not a directive saying
    "build" -- callers inject unconditionally, so this must no-op. }
  SetLength(Msgs, 1);
  Msgs[0].Role := mrSystem;  Msgs[0].Content := Caller;
  InjectModeDirective(Msgs, pmBuild);
  AssertEqS(Msgs[0].Content, Caller, 'build injects nothing at all');

  { The FIRST system message, specifically. Anthropic forwards only
    that one and discards the rest, so a directive parked in a later
    system turn would never reach the model there. }
  SetLength(Msgs, 3);
  Msgs[0].Role := mrSystem;  Msgs[0].Content := 'first';
  Msgs[1].Role := mrUser;    Msgs[1].Content := 'hi';
  Msgs[2].Role := mrSystem;  Msgs[2].Content := 'second';
  InjectModeDirective(Msgs, pmPlan);
  AssertTrue(Pos('Plan Mode', Msgs[0].Content) > 0, 'first system turn gets it');
  AssertEqS(Msgs[2].Content, 'second', 'later system turns are left alone');

  { Defensive: the gateway only calls this when a system message
    exists, but a no-system array must not fall over or grow one. }
  SetLength(Msgs, 1);
  Msgs[0].Role := mrUser;  Msgs[0].Content := 'hi';
  InjectModeDirective(Msgs, pmImprove);
  AssertTrue(Length(Msgs) = 1, 'nothing to append to, nothing appended');
  AssertEqS(Msgs[0].Content, 'hi', 'and the user turn is not touched');
end;

procedure TestParseModeFromBody;
begin
  AssertTrue(ParseModeFromBody('{"mode":"plan"}') = pmPlan, 'body plan');
  AssertTrue(ParseModeFromBody('{"mode":"build"}') = pmBuild, 'body build');
  AssertTrue(ParseModeFromBody('{"mode":"improve"}') = pmImprove, 'body improve');
  AssertTrue(ParseModeFromBody('{"mode":"research"}') = pmImprove, 'body research alias');
  AssertTrue(ParseModeFromBody('{"mode":"space"}') = pmSpace, 'body space');
  AssertTrue(ParseModeFromBody('{}') = pmBuild, 'absent mode defaults to build');
  AssertTrue(ParseModeFromBody('') = pmBuild, 'empty body defaults to build');
  AssertTrue(ParseModeFromBody('not-json') = pmBuild, 'garbage defaults to build');
  AssertTrue(ParseModeFromBody('{"mode":"yolo"}') = pmBuild, 'unknown mode defaults to build');
end;

procedure TestRefusalText;
var
  S: string;
begin
  S := PlanModeRefusal('fs_write');
  AssertTrue(Pos('fs_write', S) > 0,        'refusal names the tool');
  AssertTrue(Pos('build mode', S) > 0,      'refusal mentions build mode');
  AssertTrue(Pos('Tab', S) > 0,             'refusal mentions TUI Tab');
  AssertTrue(Pos('--mode build', S) > 0,    'refusal mentions CLI flag');

  { The space refusal is an unlock recipe, not a mode switch. }
  S := SpaceModeRefusal('fs_write');
  AssertTrue(Pos('fs_write', S) > 0,    'space refusal names the tool');
  AssertTrue(Pos('plan_write', S) > 0,  'space refusal names the unlock');
  AssertTrue(Pos('space mode', S) > 0,  'space refusal names the mode');
end;

(* Run RunToolLoop with a synthetic provider + a registry that has one
   read-only and one mutating tool. Verify the dispatch gate. *)
procedure TestDispatchGate;
var
  Reg: TToolRegistry;
  Provider: ILLMProvider;
  Cfg: TToolLoopConfig;
  Loop: TToolLoopResult;
  Msgs: array of TMessage;
  T: TTool;
  i, ReadIdx, WriteIdx: Integer;

  procedure RegisterTools;
  begin
    T.Name := 'fake_read';
    T.Description := 'read sample';
    T.Schema := '{"type":"object"}';
    T.Handler := HandleFakeRead;
    T.HandlerObj := nil;
    T.IsCore := False;
    T.Category := tcReadOnly;
    Reg.Register(T);

    T.Name := 'fake_write';
    T.Description := 'write sample';
    T.Schema := '{"type":"object"}';
    T.Handler := HandleFakeWrite;
    T.HandlerObj := nil;
    T.IsCore := False;
    T.Category := tcMutating;
    Reg.Register(T);
  end;

  function FindToolMessageByCallId(const CallId: string): string;
  var
    j: Integer;
  begin
    Result := '';
    for j := 0 to High(Loop.FinalMessages) do
      if (Loop.FinalMessages[j].Role = mrTool) and
         (Loop.FinalMessages[j].ToolCallId = CallId) then
        Exit(Loop.FinalMessages[j].Content);
  end;

begin
  Reg := TToolRegistry.Create;
  try
    RegisterTools;
    Provider := TFakeProvider.Create;

    { ----- Build mode: both tools dispatch normally. ----- }
    Cfg := Default(TToolLoopConfig);
    Cfg.Provider      := Provider;
    Cfg.Registry      := Reg;
    Cfg.Model         := 'fake';
    Cfg.MaxIterations := 4;
    Cfg.Mode          := pmBuild;
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'do both');

    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop succeeds in build');
    AssertEqS(FindToolMessageByCallId('t1'),  'READ OK',  'build: read dispatches');
    AssertEqS(FindToolMessageByCallId('t2'), 'WRITE OK', 'build: write dispatches');

    { ----- Plan mode: read dispatches; write is refused. ----- }
    Provider := nil;                          { release previous provider }
    Provider := TFakeProvider.Create;         { fresh round counter }
    Cfg := Default(TToolLoopConfig);
    Cfg.Provider      := Provider;
    Cfg.Registry      := Reg;
    Cfg.Model         := 'fake';
    Cfg.MaxIterations := 4;
    Cfg.Mode          := pmPlan;
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'do both');

    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop succeeds in plan (refusal is a tool result, not a fatal error)');
    AssertEqS(FindToolMessageByCallId('t1'), 'READ OK', 'plan: read still dispatches');
    AssertTrue(Pos('refused', FindToolMessageByCallId('t2')) > 0,
               'plan: write refused');
    AssertTrue(Pos('build mode', FindToolMessageByCallId('t2')) > 0,
               'plan: refusal mentions build mode');
  finally
    Reg.Free;
  end;
end;

(* SPACE-mode gate, end to end through RunToolLoop.

   Four scenarios, each a fresh loop over the scripted provider:
     1. locked:    fake_write before any plan_write -> space refusal
                   (and fake_read flows freely in the same round)
     2. unlock:    plan_write succeeds, then fake_write dispatches
     3. no-unlock: plan_write FAILS, fake_write stays refused
     4. seeded:    workspace/PLAN.md already on disk -> fake_write
                   dispatches from round one (the resume case)

   The gate seeds from ResolvePlanPath at loop entry, so scenarios
   1-3 must run with NO PLAN.md on disk and 4 creates one; both
   manipulations go through ResolvePlanPath so the test and the gate
   cannot disagree about the path. Refuses to run without a scratch
   $PASCLAW_HOME -- scenario 4 writes into it. *)
procedure TestSpaceGate;
(* SPACE-mode gate, end to end through RunToolLoop with the REAL
   plan_write (RegisterPlanWriteTool) -- not a stand-in. The first
   version faked it and thereby hid that the real tool was never
   registered outside --mode plan (Codex P1 on PR #595); the fake is
   gone and the blank-content rule (Codex P2) is pinned against the
   real handler.

   Scenarios, each a fresh loop over the scripted provider:
     1. locked:       a mutating call before any plan gets the space
                      refusal (read-only flows freely alongside)
     2. blank plan:   plan_write with whitespace content ERRORS and
                      the gate stays closed
     3. unlock:       plan_write with a real plan writes PLAN.md and
                      the next mutating call dispatches
     4. seeded:       a non-blank PLAN.md on disk unlocks round one
     5. blank seed:   a WHITESPACE-ONLY PLAN.md does NOT unlock

   Refuses to run without a scratch $PASCLAW_HOME -- scenarios write
   real files under it. *)
var
  Reg: TToolRegistry;
  Provider: ILLMProvider;
  Cfg: TToolLoopConfig;
  Loop: TToolLoopResult;
  Msgs: array of TMessage;
  T: TTool;
  L: TStringList;

  procedure RegisterTools;
  begin
    T := Default(TTool);
    T.Name := 'fake_read';   T.Description := 'r'; T.Schema := '{"type":"object"}';
    T.Handler := HandleFakeRead;  T.Category := tcReadOnly; Reg.Register(T);
    T.Name := 'fake_write';  T.Description := 'w'; T.Schema := '{"type":"object"}';
    T.Handler := HandleFakeWrite; T.Category := tcMutating; Reg.Register(T);
    { The real thing. Its registration in every surface's registry is
      what makes SPACE mode possible at all; a lint in the Makefile
      target guards the unconditional call in NewBuiltinRegistry. }
    RegisterPlanWriteTool(Reg);
  end;

  function ToolMsg(const CallId: string): string;
  var
    j: Integer;
  begin
    Result := '';
    for j := 0 to High(Loop.FinalMessages) do
      if (Loop.FinalMessages[j].Role = mrTool) and
         (Loop.FinalMessages[j].ToolCallId = CallId) then
        Exit(Loop.FinalMessages[j].Content);
  end;

  procedure FreshCfg;
  begin
    Cfg := Default(TToolLoopConfig);
    Cfg.Provider      := Provider;
    Cfg.Registry      := Reg;
    Cfg.Model         := 'fake';
    Cfg.MaxIterations := 6;
    Cfg.Mode          := pmSpace;
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'go');
  end;

  procedure WritePlanFile(const Body: string);
  begin
    L := TStringList.Create;
    try
      L.Text := Body;
      ForceDirectories(ExtractFileDir(ResolvePlanPath));
      L.SaveToFile(ResolvePlanPath);
    finally
      L.Free;
    end;
  end;

begin
  if GetEnvironmentVariable('PASCLAW_HOME') = '' then
    Fail_('TestSpaceGate needs a scratch $PASCLAW_HOME (use: make test-plan-build-mode)');
  if FileExists(ResolvePlanPath) then DeleteFile(ResolvePlanPath);

  Reg := TToolRegistry.Create;
  try
    RegisterTools;
    AssertTrue(Reg.Find('plan_write', T),
               'the real plan_write registers');

    { 1: locked. }
    Provider := TScriptProvider.Create([TArray<string>.Create('fake_read', 'fake_write')]);
    FreshCfg;
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'space locked: loop succeeds');
    AssertEqS(ToolMsg('r1c0'), 'READ OK', 'space locked: read flows freely');
    AssertTrue(Pos('space mode', ToolMsg('r1c1')) > 0,
               'space locked: write refused with the space refusal');
    AssertTrue(Pos('plan_write', ToolMsg('r1c1')) > 0,
               'space locked: refusal carries the unlock recipe');

    { 2: a BLANK plan must not unlock -- Codex P2 on PR #595. }
    Provider := TScriptProvider.Create(
      [TArray<string>.Create('plan_write|{"content":"   "}'),
       TArray<string>.Create('fake_write')]);
    FreshCfg;
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'space blank: loop succeeds');
    AssertTrue(Pos('empty plan refused', ToolMsg('r1c0')) > 0,
               'space blank: whitespace content is an error');
    AssertTrue(Pos('space mode', ToolMsg('r2c0')) > 0,
               'space blank: gate stays closed after a blank plan_write');
    AssertTrue(not FileExists(ResolvePlanPath),
               'space blank: no PLAN.md written');

    { 3: unlock with a real plan, through the real handler. }
    Provider := TScriptProvider.Create(
      [TArray<string>.Create('plan_write|{"content":"# Plan\n- step 1: assert X\n- step 2: code X"}'),
       TArray<string>.Create('fake_write')]);
    FreshCfg;
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'space unlock: loop succeeds');
    AssertTrue(Pos('space mode', ToolMsg('r1c0')) = 0,
               'space unlock: plan_write itself passes the gate');
    AssertEqS(ToolMsg('r2c0'), 'WRITE OK',
              'space unlock: write dispatches after the plan');
    AssertTrue(FileExists(ResolvePlanPath),
               'space unlock: PLAN.md really written');
    DeleteFile(ResolvePlanPath);

    { 4: seeded by a real plan on disk -- the resume case. }
    WritePlanFile('# Plan' + sLineBreak + '- carry on');
    Provider := TScriptProvider.Create([TArray<string>.Create('fake_write')]);
    FreshCfg;
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'space seeded: loop succeeds');
    AssertEqS(ToolMsg('r1c0'), 'WRITE OK',
              'space seeded: non-blank PLAN.md opens the gate from round one');
    DeleteFile(ResolvePlanPath);

    { 5: a whitespace-only PLAN.md must NOT seed the gate open. }
    WritePlanFile('   ');
    Provider := TScriptProvider.Create([TArray<string>.Create('fake_write')]);
    FreshCfg;
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'space blank-seed: loop succeeds');
    AssertTrue(Pos('space mode', ToolMsg('r1c0')) > 0,
               'space blank-seed: an empty file does not open the gate');
    DeleteFile(ResolvePlanPath);
  finally
    Reg.Free;
  end;
end;

begin
  TestParseMode;
  TestCycleAndName;
  TestModeSection;
  TestModeInjection;
  TestParseModeFromBody;
  TestRefusalText;
  TestDispatchGate;
  TestSpaceGate;
  WriteLn('ok - plan/build mode tests passed');
end.
