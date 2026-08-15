unit PasClaw.Cmd.Doctor;
(*
  PasClaw.Cmd.Doctor -- `pasclaw doctor`, an install diagnostic.

  Six checks, each reporting PASS / WARN / FAIL plus a one-line reason:

    config      config.json exists, parses, and names a resolvable
                default provider
    workspace   the active workspace directory exists and is writable
    memory      the memory directory, and whether MEMORY.md / SCARS.md
                are present
    profile     the profile this process resolved, and whether it applied
    toolchain   fpc on PATH -- skills may build code
    sessions    how many sessions are saved, and whether the newest parses

  Exit code is 0 when nothing FAILs, 1 otherwise. A WARN never fails the
  run: it is the level for "works, but you are missing something optional"
  (no SCARS.md yet, no compiler when you may never build).

  --json emits the same six results as a JSON array instead of text, so a
  CI step or the desktop UI can consume it without scraping.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Doctor_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Config.Profile,
  PasClaw.Utils,
  PasClaw.CliUI,
  PasClaw.JSON,
  PasClaw.Workspaces,
  PasClaw.Session.Store;

type
  TCheckLevel = (clPass, clWarn, clFail);

  TCheckResult = record
    Name:   string;
    Level:  TCheckLevel;
    Reason: string;
  end;
  TCheckResultArray = array of TCheckResult;

function LevelName(L: TCheckLevel): string;
begin
  case L of
    clPass: Result := 'PASS';
    clWarn: Result := 'WARN';
  else
    Result := 'FAIL';
  end;
end;

function LevelColour(L: TCheckLevel): string;
begin
  case L of
    clPass: Result := Ansi.Green;
    clWarn: Result := Ansi.Yellow;
  else
    Result := Ansi.Red;
  end;
end;

procedure AddResult(var Arr: TCheckResultArray; const Name: string;
                    Level: TCheckLevel; const Reason: string);
begin
  SetLength(Arr, Length(Arr) + 1);
  Arr[High(Arr)].Name   := Name;
  Arr[High(Arr)].Level  := Level;
  Arr[High(Arr)].Reason := Reason;
end;

{ Is Dir writable? Probing with a real file beats checking mode bits --
  a read-only mount and a root-owned directory both look fine in the
  metadata and fail at the first write the agent attempts. }
function DirIsWritable(const Dir: string): Boolean;
var
  Probe: string;
  F: TextFile;
begin
  Result := False;
  if not DirectoryExists(Dir) then Exit;
  Probe := JoinPath(Dir, '.pasclaw-doctor-probe');
  try
    AssignFile(F, Probe);
    Rewrite(F);
    WriteLn(F, 'probe');
    CloseFile(F);
    Result := True;
  except
    Exit;
  end;
  try DeleteFile(Probe); except end;
end;

{ First directory on PATH holding an executable called Name, or ''. }
function WhichExecutable(const Name: string): string;
var
  Dirs: TStringList;
  i: Integer;
  P: string;
begin
  Result := '';
  Dirs := TStringList.Create;
  try
    Dirs.Delimiter := {$IFDEF MSWINDOWS}';'{$ELSE}':'{$ENDIF};
    Dirs.StrictDelimiter := True;
    Dirs.DelimitedText := GetEnvironmentVariable('PATH');
    for i := 0 to Dirs.Count - 1 do
    begin
      if Dirs[i] = '' then Continue;
      P := JoinPath(Dirs[i], Name);
      if FileExists(P) then Exit(P);
      {$IFDEF MSWINDOWS}
      if FileExists(P + '.exe') then Exit(P + '.exe');
      {$ENDIF}
    end;
  finally
    Dirs.Free;
  end;
end;

procedure CheckConfig(var Arr: TCheckResultArray; const Cfg: TConfig);
var
  Path: string;
  i: Integer;
  Found: Boolean;
begin
  Path := JoinPath(GetHome, 'config.json');
  if not FileExists(Path) then
  begin
    { Not a failure: a fresh install runs on TConfig.Create's defaults. }
    AddResult(Arr, 'config', clWarn,
              'no config.json at ' + Path + ' -- running on built-in defaults');
    Exit;
  end;
  if Trim(Cfg.DefaultProvider) = '' then
  begin
    AddResult(Arr, 'config', clFail, 'config.json names no default provider');
    Exit;
  end;
  Found := False;
  for i := 0 to High(Cfg.Providers) do
    if SameText(Cfg.Providers[i].Name, Cfg.DefaultProvider) then
    begin
      Found := True;
      Break;
    end;
  if not Found then
    AddResult(Arr, 'config', clFail,
              'default provider "' + Cfg.DefaultProvider +
              '" has no matching entry in providers[]')
  else
    AddResult(Arr, 'config', clPass,
              'parsed; default provider "' + Cfg.DefaultProvider + '" resolves');
end;

procedure CheckWorkspace(var Arr: TCheckResultArray);
var
  Dir: string;
begin
  Dir := JoinPath(GetHome, ActiveWorkspaceName);
  if not DirectoryExists(Dir) then
  begin
    AddResult(Arr, 'workspace', clFail, 'missing: ' + Dir);
    Exit;
  end;
  if not DirIsWritable(Dir) then
    AddResult(Arr, 'workspace', clFail, 'not writable: ' + Dir)
  else
    AddResult(Arr, 'workspace', clPass, Dir);
end;

procedure CheckMemory(var Arr: TCheckResultArray);
var
  Dir, Note: string;
  HasMem, HasScars: Boolean;
begin
  Dir := JoinPath(JoinPath(GetHome, ActiveWorkspaceName), 'memory');
  if not DirectoryExists(Dir) then
  begin
    AddResult(Arr, 'memory', clWarn, 'no memory directory yet: ' + Dir);
    Exit;
  end;
  HasMem   := FileExists(JoinPath(Dir, 'MEMORY.md'));
  HasScars := FileExists(JoinPath(Dir, 'SCARS.md'));
  if HasMem then Note := 'MEMORY.md present' else Note := 'no MEMORY.md';
  if HasScars then
    Note := Note + ', SCARS.md present'
  else
    Note := Note + ', no SCARS.md (run `pasclaw learn --write-scars`)';
  if HasMem then
    AddResult(Arr, 'memory', clPass, Note)
  else
    AddResult(Arr, 'memory', clWarn, Note);
end;

procedure CheckProfile(var Arr: TCheckResultArray; const Cfg: TConfig);
var
  Raw, Named, PErr: string;
  Bodies: TProfileBodyArray;
begin
  Raw := '';
  if FileExists(JoinPath(GetHome, 'config.json')) then
    Raw := ReadFileText(JoinPath(GetHome, 'config.json'));
  Named := ResolveProfileName(Raw, '');
  if Named = '' then
  begin
    AddResult(Arr, 'profile', clPass, 'none named -- stock defaults');
    Exit;
  end;
  { A name that does not resolve is the gap worth reporting: the operator
    believes they are running under `security` and they are not. }
  if ResolveProfileBodies(GetHome, Named, Bodies, PErr) then
    AddResult(Arr, 'profile', clPass,
              Named + ' resolves (' + IntToStr(Length(Bodies)) + ' layer(s))')
  else
    AddResult(Arr, 'profile', clFail,
              'profile "' + Named + '" is named but does not resolve: ' + PErr);
end;

procedure CheckToolchain(var Arr: TCheckResultArray);
var
  P: string;
begin
  P := WhichExecutable('fpc');
  if P = '' then
    AddResult(Arr, 'toolchain', clWarn,
              'fpc not on PATH -- skills that build code will fail')
  else
    AddResult(Arr, 'toolchain', clPass, 'fpc at ' + P);
end;

procedure CheckSessions(var Arr: TCheckResultArray);
var
  Metas: TSessionMetaArray;
  Newest: TSession;
  Dir: string;
begin
  Dir := SessionsDir;
  if not DirectoryExists(Dir) then
  begin
    AddResult(Arr, 'sessions', clWarn, 'no sessions directory yet: ' + Dir);
    Exit;
  end;
  Metas := ListSessions;
  if Length(Metas) = 0 then
  begin
    AddResult(Arr, 'sessions', clPass, '0 saved');
    Exit;
  end;
  { ListSessions returns newest first; re-open it to prove the file still
    parses rather than trusting the listing, which reads only meta. }
  Newest := TSession.Create(Metas[0].Id);
  try
    if not Newest.MetaExists then
      AddResult(Arr, 'sessions', clFail,
                IntToStr(Length(Metas)) + ' saved, but the newest (' +
                Metas[0].Id + ') does not parse')
    else
      AddResult(Arr, 'sessions', clPass,
                IntToStr(Length(Metas)) + ' saved, newest ' + Metas[0].Id +
                ' parses');
  finally
    Newest.Free;
  end;
end;

function EmitJSON(const Arr: TCheckResultArray): string;
var
  A: TJsonArray;
  O: TJsonObject;
  i: Integer;
begin
  A := TJsonArray.Create;
  try
    for i := 0 to High(Arr) do
    begin
      O := TJsonObject.Create;
      O.PutStr('check',  Arr[i].Name);
      O.PutStr('level',  LevelName(Arr[i].Level));
      O.PutStr('reason', Arr[i].Reason);
      A.AddObject(O);
    end;
    Result := A.ToJSON;
  finally
    A.Free;
  end;
end;

function Cmd_Doctor_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Results_: TCheckResultArray;
  AsJSON: Boolean;
  i: Integer;
  Failed: Boolean;
begin
  AsJSON := False;
  for i := 0 to High(Argv) do
    if (Argv[i] = '--json') or (Argv[i] = '-j') then AsJSON := True
    else if (Argv[i] = '-h') or (Argv[i] = '--help') then
    begin
      PrintLn('usage: pasclaw doctor [--json]');
      PrintLn;
      PrintLn('Diagnoses this install: config, workspace, memory, profile,');
      PrintLn('toolchain and sessions. Exits 1 when any check FAILs.');
      Exit(0);
    end;

  Cfg := LoadConfig('');
  try
    SetLength(Results_, 0);
    CheckConfig(Results_, Cfg);
    CheckWorkspace(Results_);
    CheckMemory(Results_);
    CheckProfile(Results_, Cfg);
    CheckToolchain(Results_);
    CheckSessions(Results_);
  finally
    Cfg.Free;
  end;

  if AsJSON then
    PrintLn(EmitJSON(Results_))
  else
  begin
    PrintLn(Ansi.Bold + 'pasclaw doctor' + Ansi.Reset);
    PrintLn;
    for i := 0 to High(Results_) do
      PrintLn(LevelColour(Results_[i].Level) +
              Format('%-5s', [LevelName(Results_[i].Level)]) + Ansi.Reset +
              ' ' + Format('%-10s', [Results_[i].Name]) + Results_[i].Reason);
    PrintLn;
  end;

  Failed := False;
  for i := 0 to High(Results_) do
    if Results_[i].Level = clFail then Failed := True;
  if Failed then Result := 1 else Result := 0;
end;

end.
