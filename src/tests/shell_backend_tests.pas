program shell_backend_tests;
(*
  Covers PasClaw.Shell.Backend + PasClaw.Shell.Backend.Local +
  the dispatch wrappers Tool_Shell / Tool_ExecuteCode call.

  The Docker backend isn't exercised end-to-end here -- spawning a
  container costs ~500ms per test and needs Docker on the box.
  Integration coverage of docker lives in a separate harness
  (test-shell-backend-docker) that's only run when Docker is
  available.

  This test pins the interface contracts:
    - GetActiveShellBackend nil-safe before SetActive is called;
      RunOneShotViaBackend falls back to PasClaw.Platform.RunOneShot
    - SetActiveShellBackend(TLocalShellBackend) -> Exec round-trips
      a real command
    - Per-session lifecycle (StartShellSession / CloseShellSession)
      is idempotent on the local backend
    - GetCurrentSessionId round-trips after SetCurrentSessionId
    - A recording mock backend (TRecordingBackend) used by the
      shell+execute_code tests proves the dispatch path actually
      goes through the active backend instead of the host shell
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Shell.Backend,
  PasClaw.Shell.Backend.Local,
  PasClaw.Shell.Backend.Docker;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' +
          Copy(Want, 1, 200) + '")');
end;

type
  TRecordingBackend = class(TInterfacedObject, IShellBackend)
  private
    FLog: TStringList;   { one entry per Exec/Start/Close call }
  public
    constructor Create;
    destructor  Destroy; override;
    function Name: string;
    function Describe: string;
    procedure StartSession(const SessionId: string);
    procedure CloseSession(const SessionId: string);
    function Exec(const SessionId, Cmd, WorkDir: string;
                  ExtraEnv: TStringList;
                  out Output: string): Integer;
    property Log: TStringList read FLog;
  end;

constructor TRecordingBackend.Create;
begin
  inherited Create;
  FLog := TStringList.Create;
end;

destructor TRecordingBackend.Destroy;
begin
  FLog.Free;
  inherited Destroy;
end;

function TRecordingBackend.Name: string;
begin
  Result := 'recording';
end;

function TRecordingBackend.Describe: string;
begin
  Result := 'records every call for tests';
end;

procedure TRecordingBackend.StartSession(const SessionId: string);
begin
  FLog.Add('start:' + SessionId);
end;

procedure TRecordingBackend.CloseSession(const SessionId: string);
begin
  FLog.Add('close:' + SessionId);
end;

function TRecordingBackend.Exec(const SessionId, Cmd, WorkDir: string;
                                ExtraEnv: TStringList;
                                out Output: string): Integer;
begin
  FLog.Add(Format('exec[%s][%s]: %s', [SessionId, WorkDir, Cmd]));
  Output := '(recorded: ' + Cmd + ')';
  Result := 0;
end;

procedure TestNoBackendFallsBackToHost;
{ Before SetActiveShellBackend, the wrappers must still work so
  the legacy test harnesses + the standalone Tool_ExecuteCode
  legacy entry behave the same as before this PR. }
var
  Out_: string;
  ExitCode: Integer;
begin
  SetActiveShellBackend(nil);
  AssertTrue(GetActiveShellBackend = nil, 'no backend installed');
  ExitCode := RunOneShotViaBackend('', 'echo hello-host', '', Out_);
  AssertTrue(ExitCode = 0, 'host echo exit 0');
  AssertTrue(Pos('hello-host', Out_) > 0,
             'host echo round-trips its argument');
end;

procedure TestLocalBackendInstall;
var
  Local: TLocalShellBackend;
  LocalIfc: IShellBackend;
  Out_: string;
  ExitCode: Integer;
begin
  Local := TLocalShellBackend.Create;
  LocalIfc := Local;
  try
    SetActiveShellBackend(LocalIfc);
    AssertTrue(GetActiveShellBackend <> nil, 'local backend installed');
    AssertEqStr(GetActiveShellBackend.Name, 'local',
                'Name returns "local"');
    StartShellSession('test-session-1');
    StartShellSession('test-session-1');   { idempotent }
    ExitCode := RunOneShotViaBackend('test-session-1',
                                     'echo via-local', '', Out_);
    AssertTrue(ExitCode = 0, 'local exec exit 0');
    AssertTrue(Pos('via-local', Out_) > 0, 'output contains argument');
    CloseShellSession('test-session-1');
    CloseShellSession('test-session-1');   { idempotent }
  finally
    SetActiveShellBackend(nil);
  end;
end;

procedure TestCurrentSessionIdRoundTrips;
begin
  SetCurrentSessionId('');
  AssertEqStr(GetCurrentSessionId, '', 'starts empty');
  SetCurrentSessionId('hello-world');
  AssertEqStr(GetCurrentSessionId, 'hello-world',
              'round-trips a non-empty id');
  SetCurrentSessionId('');
end;

procedure TestDispatchGoesThroughActiveBackend;
{ Critical contract: when an alternate backend is installed, the
  dispatch wrappers MUST route through it instead of spawning on
  the host. A docker backend that silently fell back to host would
  defeat the security promise. }
var
  Rec: TRecordingBackend;
  Ifc: IShellBackend;
  Out_: string;
  ExitCode: Integer;
begin
  Rec := TRecordingBackend.Create;
  Ifc := Rec;
  try
    SetActiveShellBackend(Ifc);
    StartShellSession('record-1');
    ExitCode := RunOneShotViaBackend('record-1', 'pretend-cmd', '/tmp', Out_);
    AssertTrue(ExitCode = 0, 'recording backend returns 0');
    AssertEqStr(Out_, '(recorded: pretend-cmd)',
                'output is the recorded marker, not host shell output');
    AssertTrue(Rec.Log.IndexOf('start:record-1') >= 0,
               'StartSession recorded');
    AssertTrue(Rec.Log.IndexOf('exec[record-1][/tmp]: pretend-cmd') >= 0,
               'Exec recorded with session id and cwd');
    CloseShellSession('record-1');
    AssertTrue(Rec.Log.IndexOf('close:record-1') >= 0,
               'CloseSession recorded');
  finally
    SetActiveShellBackend(nil);
  end;
end;

procedure TestRunOneShotWithEnvDispatch;
var
  Rec: TRecordingBackend;
  Ifc: IShellBackend;
  Env: TStringList;
  Out_: string;
begin
  Rec := TRecordingBackend.Create;
  Ifc := Rec;
  try
    SetActiveShellBackend(Ifc);
    Env := TStringList.Create;
    try
      Env.Add('FOO=bar');
      RunOneShotWithEnvViaBackend('s1', 'cmd-with-env', '', Env, Out_);
      AssertTrue(Rec.Log.IndexOf('exec[s1][]: cmd-with-env') >= 0,
                 'with-env dispatch records exec line');
    finally
      Env.Free;
    end;
  finally
    SetActiveShellBackend(nil);
  end;
end;

procedure TestDockerRefusesEmptySessionId;
{ Codex P1 on PR #233: the previous empty-SessionId fallback ran
  commands on the HOST when no session id was set, defeating the
  isolation the operator picked docker for. Pin the new contract:
  StartSession refuses empty ids with a clear error, and Exec
  returns -1 + a diagnostic Output rather than silently dispatching
  to RunOneShot.

  We construct the backend WITHOUT calling DockerCliReachable so
  the test runs even when docker isn't on the box -- the validation
  paths we're testing all fail before any docker subprocess. }
var
  Opts: TDockerBackendOptions;
  Backend: TDockerShellBackend;
  Ifc: IShellBackend;
  Out_: string;
  ExitCode: Integer;
  Raised: Boolean;
begin
  Opts := DefaultDockerBackendOptions;
  Backend := TDockerShellBackend.Create(Opts);
  Ifc := Backend;
  try
    Raised := False;
    try
      Backend.StartSession('');
    except
      on E: Exception do
      begin
        Raised := True;
        AssertTrue(Pos('empty SessionId', E.Message) > 0,
                   'StartSession error names the bad arg: ' + E.Message);
      end;
    end;
    AssertTrue(Raised, 'StartSession('''') raises rather than no-opping');

    { Exec('') must NOT spawn anything host-side; it must surface an
      explicit error so a forgotten lifecycle call is visible. }
    ExitCode := Backend.Exec('', 'echo should-not-run-on-host', '',
                             nil, Out_);
    AssertTrue(ExitCode = -1,
               'Exec('''') returns -1, not 0 from a successful host run');
    AssertTrue(Pos('empty SessionId', Out_) > 0,
               'Exec('''') Output explains the contract: ' + Out_);
    AssertTrue(Pos('should-not-run-on-host', Out_) = 0,
               'the model''s command does NOT appear in the output ' +
               '(would mean it ran on the host)');
  finally
    SetActiveShellBackend(nil);
  end;
end;

begin
  TestNoBackendFallsBackToHost;
  WriteLn('  ok: no backend -> host fallback works');
  TestLocalBackendInstall;
  WriteLn('  ok: local backend installs + Exec round-trips');
  TestCurrentSessionIdRoundTrips;
  WriteLn('  ok: current session id round-trips');
  TestDispatchGoesThroughActiveBackend;
  WriteLn('  ok: dispatch goes through active backend (recording mock)');
  TestRunOneShotWithEnvDispatch;
  WriteLn('  ok: with-env wrapper dispatches through active backend');
  TestDockerRefusesEmptySessionId;
  WriteLn('  ok: docker backend refuses empty SessionId (no host fallback)');
  WriteLn('PASS');
end.
