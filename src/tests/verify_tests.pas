program verify_tests;
(*
  PasClaw.Agent.Verify and the tool loop's verification rounds.

    - ListScenarios: sorted, skips hidden files and README*, '' for a
      missing dir; ScenarioCommand picks sh / python3 / direct
    - RunScenarios against a temp dir: a passing and a failing script,
      exit codes and captured output; feedback and summary wording
    - the loop: a fake model answers "done" without writing the file the
      scenario checks; the scenario fails; the feedback turn arrives;
      the model writes the file; the next round passes -> Verified,
      VerifyRounds = 2, the feedback turn is in the history
    - max_rounds = 1: one failing round, no feedback turn, Verified False
    - no ScenariosDir: no rounds, nothing changes

  PASCLAW_HOME must be a scratch dir (the Makefile target arranges it).
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.Sandbox,
  PasClaw.Tools.FS,
  PasClaw.Tools.ToolLoop,
  PasClaw.Agent.Verify;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '" in: ' + Copy(Hay, 1, 300)); end;

var
  Root, Ws, Scen: string;

procedure TestPureAndRun;
var
  Files: TStringArray;
  R: TScenarioResults;
  Ok: Boolean;
  Fb: string;
begin
  ForceDirectories(Scen);
  WriteFileText(JoinPath(Scen, 'README.md'), 'not a scenario');
  WriteFileText(JoinPath(Scen, '.hidden.sh'), 'exit 1');
  WriteFileText(JoinPath(Scen, '02_bad.sh'), 'echo boom; echo "cwd=$(pwd)"; exit 3');
  WriteFileText(JoinPath(Scen, '01_ok.sh'), 'test -d . && echo fine');
  Files := ListScenarios(Scen);
  AssertEqInt(Length(Files), 2, 'two scenarios listed');
  AssertTrue(ExtractFileName(Files[0]) = '01_ok.sh', 'sorted by name');
  AssertEqInt(Length(ListScenarios(JoinPath(Root, 'nope'))), 0, 'missing dir -> none');
  AssertContains(ScenarioCommand('/x/a.sh'), 'sh ', 'sh runner');
  AssertContains(ScenarioCommand('/x/a.py'), 'python3 ', 'python runner');
  AssertTrue(Pos('sh ', ScenarioCommand('/x/check')) <> 1, 'direct runner');

  Ok := RunScenarios(Scen, Ws, R);
  AssertTrue(not Ok, 'one failed');
  AssertEqInt(Length(R), 2, 'two results');
  AssertTrue(R[0].Passed and (R[0].ExitCode = 0), '01_ok passed');
  AssertTrue((not R[1].Passed) and (R[1].ExitCode = 3), '02_bad failed with exit 3');
  AssertContains(R[1].Output, 'boom', 'output captured');
  AssertContains(R[1].Output, 'cwd=' + Ws, 'scenario ran in the workspace');
  AssertEqInt(CountPassed(R), 1, 'count');
  Fb := FormatVerificationFeedback(R, 1, 2);
  AssertContains(Fb, '[verification] 1 of 2', 'feedback header');
  AssertContains(Fb, '02_bad.sh: FAILED (exit 3)', 'names the failure');
  AssertContains(Fb, 'boom', 'includes the output');
  AssertContains(Fb, '01_ok.sh: passed', 'lists the pass');
  AssertContains(Fb, 're-run automatically', 'tells the model not to re-run its own tests');
  AssertContains(FormatVerificationSummary(R, 1, 2), 'verification: 1/2 scenarios passed (round 1 of 2)', 'summary');
  WriteLn('  ok: list / command / run / feedback / summary');
end;

{ ---- the loop ---- }

type
  TFixOnFeedback = class(TInterfacedObject, ILLMProvider)
  public
    Calls: Integer;
    SawFeedback: Boolean;
    function Chat(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                  const Model: string; const Options: TChatOptions): TLLMResponse;
    function ChatStream(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                        const Model: string; const Options: TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
  end;

function TFixOnFeedback.Chat(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                             const Model: string; const Options: TChatOptions): TLLMResponse;
var
  Last: string;
begin
  Inc(Calls);
  Result := Default(TLLMResponse);
  Result.StatusCode := 200;
  Last := '';
  if Length(Messages) > 0 then Last := Messages[High(Messages)].Content;
  if (Messages[High(Messages)].Role = mrUser) and (Pos('[verification]', Last) = 1) then
  begin
    SawFeedback := True;
    SetLength(Result.ToolCalls, 1);
    Result.ToolCalls[0].Id := 'fix';
    Result.ToolCalls[0].Kind := 'function';
    Result.ToolCalls[0].Func.Name := 'fs_write';
    Result.ToolCalls[0].Func.Arguments := '{"path":"marker.txt","content":"present"}';
    Result.FinishReason := 'tool_calls';
    Exit;
  end;
  Result.Content := 'done';
  Result.FinishReason := 'stop';
end;

function TFixOnFeedback.ChatStream(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                                   const Model: string; const Options: TChatOptions;
                                   OnChunk: TStreamCallback): TLLMResponse;
begin Result := Chat(Messages, Tools, Model, Options); end;
function TFixOnFeedback.GetDefaultModel: string; begin Result := 'fake'; end;
function TFixOnFeedback.GetName: string; begin Result := 'fake-fix'; end;
function TFixOnFeedback.SupportsThinking: Boolean; begin Result := False; end;
function TFixOnFeedback.SupportsNativeSearch: Boolean; begin Result := False; end;
function TFixOnFeedback.SupportsStreaming: Boolean; begin Result := False; end;

procedure TestLoop;
var
  Reg: TToolRegistry;
  P: TFixOnFeedback;
  PI: ILLMProvider;
  Cfg: TToolLoopConfig;
  Msgs: array of TMessage;
  Loop: TToolLoopResult;
  Scen2: string;
  i, FbTurns: Integer;
begin
  Scen2 := JoinPath(Root, 'scen2');
  ForceDirectories(Scen2);
  WriteFileText(JoinPath(Scen2, 'marker.sh'), 'test -f marker.txt || { echo "marker.txt missing"; exit 1; }');
  Reg := TToolRegistry.Create;
  P := TFixOnFeedback.Create;
  PI := P;
  try
    RegisterFSTools(Reg, False);
    Cfg := Default(TToolLoopConfig);
    Cfg.Provider := PI; Cfg.Registry := Reg; Cfg.Model := 'fake'; Cfg.MaxIterations := 6;
    Cfg.Options := DefaultChatOptions;
    Cfg.ScenariosDir := Scen2;
    Cfg.VerifyMaxRounds := 2;
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'make marker.txt');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran');
    AssertTrue(P.SawFeedback, 'the model received the feedback turn');
    AssertTrue(Loop.Verified, 'verified after the fix');
    AssertEqInt(Loop.VerifyRounds, 2, 'two rounds');
    AssertEqInt(Loop.VerifyPassed, 1, 'one passed');
    AssertEqInt(Loop.VerifyFailed, 0, 'none failed');
    AssertContains(Loop.VerifyReport, '1/1 scenarios passed (round 2 of 2)', 'report');
    AssertTrue(FileExists(JoinPath(Ws, 'marker.txt')), 'the fix landed in the workspace');
    FbTurns := 0;
    for i := 0 to High(Loop.FinalMessages) do
      if (Loop.FinalMessages[i].Role = mrUser) and (Pos('[verification]', Loop.FinalMessages[i].Content) = 1) then Inc(FbTurns);
    AssertEqInt(FbTurns, 1, 'one feedback turn in the history');
    AssertEqInt(P.Calls, 3, 'done, fix, done');

    { max_rounds = 1: judged once, not fed back. }
    DeleteFile(JoinPath(Ws, 'marker.txt'));
    P.Calls := 0; P.SawFeedback := False;
    Cfg.VerifyMaxRounds := 1;
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'make marker.txt');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran (1 round)');
    AssertTrue(not Loop.Verified, 'not verified');
    AssertEqInt(Loop.VerifyRounds, 1, 'one round');
    AssertEqInt(Loop.VerifyFailed, 1, 'the failure counted');
    AssertTrue(not P.SawFeedback, 'no feedback turn when no rounds remain');
    AssertEqInt(P.Calls, 1, 'one model call');

    { Off: nothing happens. }
    Cfg.ScenariosDir := '';
    P.Calls := 0;
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'make marker.txt');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop ran (off)');
    AssertEqInt(Loop.VerifyRounds, 0, 'no rounds when off');
    AssertTrue(not Loop.Verified, 'Verified false when off');
  finally
    Reg.Free;
  end;
  WriteLn('  ok: loop rounds: fail -> feedback -> fix -> verified; one-round; off');
end;

procedure TestConfig;
var
  Cfg: TConfig;
begin
  Cfg := TConfig.Create;
  try
    AssertTrue(ResolveScenariosDir(Cfg) = '', 'off by default');
    Cfg.FromJSON('{"verification":{"scenarios":"scenarios","max_rounds":3}}');
    AssertEqInt(Cfg.Verification.MaxRounds, 3, 'rounds parsed');
    AssertContains(ResolveScenariosDir(Cfg), JoinPath(GetHome, 'scenarios'), 'relative under home');
    AssertContains(Cfg.ToJSON, '"verification"', 'emitted');
    Cfg.FromJSON('{"verification":{"scenarios":"/abs/dir","max_rounds":0}}');
    AssertTrue(ResolveScenariosDir(Cfg) = '/abs/dir', 'absolute kept');
    AssertEqInt(Cfg.Verification.MaxRounds, 1, 'rounds floor 1');
  finally
    Cfg.Free;
  end;
  WriteLn('  ok: config round-trip and resolution');
end;

begin
  Root := JoinPath(GetTempDir, 'pasclaw-verify-' + IntToStr(GetProcessID));
  Ws := JoinPath(Root, 'ws');
  Scen := JoinPath(Root, 'scen');
  ForceDirectories(Ws);
  ConfigureSandbox(Default(TSandboxPolicy), Ws);
  TestPureAndRun;
  TestLoop;
  TestConfig;
  WriteLn('PASS');
end.
