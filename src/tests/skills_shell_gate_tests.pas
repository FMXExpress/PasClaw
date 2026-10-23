program skills_shell_gate_tests;
(*
  A skill's shell is still a shell.

  Before: kind `shell` skills ran RunOneShot directly -- no ShellAllowed,
  not through the shell backend, Category unset (so plan mode let them
  through). Pinned here:

    - a shell skill registers as tcMutating, a prompt skill as tcReadOnly
    - a rendered command that trips the denylist is refused with the
      skill's name in the error and never runs
    - a benign shell skill still runs and returns its output
    - the command goes through the ACTIVE shell backend (a recording
      backend sees it), not the host shell directly
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Shell.Backend,
  PasClaw.Skills.Loader;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '" in: ' + Copy(Hay, 1, 200)); end;

type
  TRecordingBackend = class(TInterfacedObject, IShellBackend)
  public
    Seen: TStringList;
    constructor Create;
    destructor Destroy; override;
    function Name: string;
    function Describe: string;
    procedure StartSession(const SessionId: string);
    procedure CloseSession(const SessionId: string);
    function Exec(const SessionId, Cmd, WorkDir: string; ExtraEnv: TStringList;
                  out Output: string): Integer;
  end;

constructor TRecordingBackend.Create; begin inherited Create; Seen := TStringList.Create; end;
destructor TRecordingBackend.Destroy; begin Seen.Free; inherited; end;
function TRecordingBackend.Name: string; begin Result := 'recording'; end;
function TRecordingBackend.Describe: string; begin Result := 'records'; end;
procedure TRecordingBackend.StartSession(const SessionId: string); begin end;
procedure TRecordingBackend.CloseSession(const SessionId: string); begin end;
function TRecordingBackend.Exec(const SessionId, Cmd, WorkDir: string; ExtraEnv: TStringList;
                                out Output: string): Integer;
begin
  Seen.Add(Cmd);
  Output := 'recorded:' + Cmd;
  Result := 0;
end;

function Spec(const AName, AKind, AShell, APrompt: string): TSkillSpec;
begin
  Result := Default(TSkillSpec);
  Result.Name := AName;
  Result.Description := AName;
  Result.Kind := AKind;
  Result.Shell := AShell;
  Result.Prompt := APrompt;
  Result.Schema := '{"type":"object","properties":{"p":{"type":"string"}}}';
end;

var
  Reg: TToolRegistry;
  Skills: TSkillSpecArray;
  T: TTool;
  Err, Out_: string;
  Rec: TRecordingBackend;
  RecI: IShellBackend;
begin
  Reg := TToolRegistry.Create;
  try
    SetLength(Skills, 3);
    Skills[0] := Spec('nuke',  'shell',  'rm -rf {{p}}', '');
    Skills[1] := Spec('greet', 'shell',  'echo hello {{p}}', '');
    Skills[2] := Spec('tmpl',  'prompt', '', 'Say hi to {{p}}');
    RegisterSkills(Reg, Skills);

    AssertTrue(Reg.Find('skill_nuke', T), 'shell skill registered');
    AssertTrue(T.Category = tcMutating, 'shell skill is tcMutating');
    AssertTrue(Reg.Find('skill_tmpl', T), 'prompt skill registered');
    AssertTrue(T.Category = tcReadOnly, 'prompt skill is tcReadOnly');

    { Denylist: the rendered command, args from the "model". }
    Out_ := RunSkill(Reg, 'nuke', '{"p":"/"}', Err);
    AssertTrue(Err <> '', 'rm -rf / through a skill is refused');
    AssertContains(Err, 'skill nuke', 'refusal names the skill');
    AssertTrue(Out_ = '', 'nothing ran');

    { Benign skill through the real local shell. }
    Out_ := RunSkill(Reg, 'greet', '{"p":"world"}', Err);
    AssertTrue(Err = '', 'benign skill runs: ' + Err);
    AssertContains(Out_, 'hello world', 'output returned');

    { Through the ACTIVE backend. }
    Rec := TRecordingBackend.Create;
    RecI := Rec;
    SetActiveShellBackend(RecI);
    try
      Out_ := RunSkill(Reg, 'greet', '{"p":"backend"}', Err);
      AssertTrue(Err = '', 'skill via backend: ' + Err);
      AssertTrue(Rec.Seen.Count = 1, 'the backend saw exactly one command');
      AssertContains(Rec.Seen[0], 'echo hello backend', 'the backend saw the rendered command');
      AssertContains(Out_, 'recorded:', 'the backend produced the output');
      { Still gated before reaching the backend. }
      Out_ := RunSkill(Reg, 'nuke', '{"p":"/tmp"}', Err);
      AssertTrue(Err <> '', 'denylist still applies with a backend');
      AssertTrue(Rec.Seen.Count = 1, 'refused command never reached the backend');
    finally
      SetActiveShellBackend(nil);
      RecI := nil;
    end;
  finally
    Reg.Free;
  end;
  WriteLn('  ok: shell skills gated by the denylist, categorised, routed through the backend');
  WriteLn('PASS');
end.
