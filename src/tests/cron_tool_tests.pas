program cron_tool_tests;
(*
  Pins the model-callable `cron` tool: it edits config.json's crons[] to
  list/add/remove jobs, validates the cron spec and that the skill exists,
  and refuses bad input. Runs against a temp PASCLAW_HOME with one seeded
  skill. (The live-scheduler mtime reload that activates additions on a
  running server is verified by inspection -- no socket/thread here.)
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Config,        { GetConfigPath, GetHome }
  PasClaw.Utils,         { ReadFileText / WriteFileText / JoinPath }
  PasClaw.Tools.Cron;    { Tool_Cron }

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

function Cron(const Args: string; out Err: string): string;
begin
  Result := Tool_Cron(Args, Err);
end;

procedure ExpectOK(const Args, Needle, Msg: string);
var Out_, Err: string;
begin
  Out_ := Cron(Args, Err);
  if Err <> '' then Fail_(Msg + ' -- unexpected error: ' + Err);
  if (Needle <> '') and (Pos(Needle, Out_) = 0) then
    Fail_(Msg + ' -- output missing "' + Needle + '": ' + Out_);
end;

procedure ExpectErr(const Args, ErrNeedle, Msg: string);
var Out_, Err: string;
begin
  Out_ := Cron(Args, Err);
  if Err = '' then Fail_(Msg + ' -- expected an error, got: ' + Out_);
  if (ErrNeedle <> '') and (Pos(ErrNeedle, Err) = 0) then
    Fail_(Msg + ' -- error missing "' + ErrNeedle + '": ' + Err);
end;

procedure ConfigContains(const Needle, Msg: string);
var Body: string;
begin
  if not FileExists(GetConfigPath) then Fail_(Msg + ' -- config.json missing');
  Body := ReadFileText(GetConfigPath);
  if Pos(Needle, Body) = 0 then
    Fail_(Msg + ' -- config.json missing "' + Needle + '": ' + Body);
end;

procedure ConfigMissing(const Needle, Msg: string);
var Body: string;
begin
  if not FileExists(GetConfigPath) then Exit;
  Body := ReadFileText(GetConfigPath);
  if Pos(Needle, Body) > 0 then
    Fail_(Msg + ' -- config.json still has "' + Needle + '"');
end;

var
  SkillDir: string;
begin
  { Seed one installed skill so add's skill-existence check passes. }
  SkillDir := JoinPath(JoinPath(JoinPath(GetHome, 'workspace'), 'skills'), 'hello');
  ForceDirectories(SkillDir);
  WriteFileText(JoinPath(SkillDir, 'SKILL.md'),
    '---'#10 + 'name: hello'#10 + 'description: test skill'#10 + '---'#10 + 'body'#10);

  { Empty to start. }
  ExpectOK('{"action":"list"}', 'no cron jobs', 'list empty');

  { Add a valid job. }
  ExpectOK('{"action":"add","spec":"0 9 * * *","skill":"hello","id":"job1"}',
           'Scheduled', 'add valid');
  ConfigContains('job1', 'config has job id');
  ConfigContains('hello', 'config has skill');

  { It shows up in the list. }
  ExpectOK('{"action":"list"}', 'job1', 'list shows the job');

  { Duplicate id is refused. }
  { Phase 8: a new entry is stamped with the workspace it was created in,
    so it fires AS that workspace forever after -- not as whatever world
    happens to be open at fire time. }
  ConfigContains('"workspace"', 'the entry carries its creating workspace');

  ExpectErr('{"action":"add","spec":"0 9 * * *","skill":"hello","id":"job1"}',
            'already exists', 'duplicate id refused');

  { Invalid cron expression is refused (before the skill check). }
  ExpectErr('{"action":"add","spec":"not a cron","skill":"hello"}',
            'invalid cron', 'bad spec refused');

  { Unknown skill is refused. }
  ExpectErr('{"action":"add","spec":"0 9 * * *","skill":"does-not-exist"}',
            'unknown skill', 'unknown skill refused');

  { Missing required fields. }
  ExpectErr('{"action":"add"}', 'requires', 'add missing fields');

  { Remove the job. }
  ExpectOK('{"action":"remove","id":"job1"}', 'Removed', 'remove existing');
  ConfigMissing('job1', 'config no longer has the job');

  { Remove a non-existent job. }
  ExpectErr('{"action":"remove","id":"nope"}', 'no cron', 'remove missing');

  { Unknown / missing action. }
  ExpectErr('{"action":"frobnicate"}', 'unknown action', 'unknown action');
  ExpectErr('{}', 'action', 'missing action');

  WriteLn('cron_tool_tests: OK');
end.
