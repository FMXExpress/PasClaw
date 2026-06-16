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

  No network / no provider keys -- the synthetic provider is a small
  ILLMProvider implementor in this file.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Agent.Mode,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
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
end;

procedure TestCycleAndName;
begin
  AssertTrue(CycleMode(pmBuild) = pmPlan, 'cycle build->plan');
  AssertTrue(CycleMode(pmPlan)  = pmBuild, 'cycle plan->build');
  AssertEqS(ModeName(pmBuild), 'build', 'name build');
  AssertEqS(ModeName(pmPlan),  'plan',  'name plan');
end;

procedure TestParseModeFromBody;
begin
  AssertTrue(ParseModeFromBody('{"mode":"plan"}') = pmPlan, 'body plan');
  AssertTrue(ParseModeFromBody('{"mode":"build"}') = pmBuild, 'body build');
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

begin
  TestParseMode;
  TestCycleAndName;
  TestParseModeFromBody;
  TestRefusalText;
  TestDispatchGate;
  WriteLn('ok - plan/build mode tests passed');
end.
