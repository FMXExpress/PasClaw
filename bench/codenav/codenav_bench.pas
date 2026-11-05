(*
  bench/codenav -- what finding your way around a codebase costs, with
  and without code_outline.

  The lookups are real: 34 names whose definition was searched for during
  one long session on this repository (taken from its transcript), each
  with the file(s) that define it, found independently by
  grep -E "^(function|procedure|constructor) (T*.)?NAME" -- not by the tool
  under test. Each lookup goes through the tool registry, the way a
  model's call would, three ways:

    grep-name  grep_files for the bare name: one call, every use of it,
               the definition somewhere among them.
    grep-def   grep_files guessing the definition's keyword -- "function
               NAME", then "procedure NAME", "constructor NAME", "NAME =" --
               until a defining file shows up. What an agent (and this
               repository's own sessions) actually does.
    outline    code_outline symbol=NAME: one call, declarations only.

  Then the shape of things: a large unit read whole versus outlined, and a
  directory listed versus outlined. And the price: code_outline's schema,
  which every request carries once the tool is registered.

  What this measures is information cost -- calls, bytes, whether the
  answer is in the result -- for fixed strategies. It does not measure
  whether a model chooses the tool; that is a live run's question.

    make bench-codenav      # from the repository root
*)
program codenav_bench;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils, Classes,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.FS;

type
  TLookup = record
    Name: string;
    Defined: string;   { defining file(s), comma-separated }
  end;

const
  Lookups: array[0..33] of TLookup = (
    (Name: 'RegisterProjectTools'; Defined: 'src/pkg/projects/PasClaw.Projects.Tools.pas'),
    (Name: 'RegisterAgentTools';   Defined: 'src/pkg/agent/PasClaw.Agents.Tools.pas'),
    (Name: 'ListTeamStates';       Defined: 'src/pkg/agent/PasClaw.Teams.pas'),
    (Name: 'TerminateProcessTree'; Defined: 'src/pkg/platform/PasClaw.Platform.pas'),
    (Name: 'AgentMessages';        Defined: 'src/pkg/agent/PasClaw.Agents.pas'),
    (Name: 'WaitForAgentMail';     Defined: 'src/pkg/agent/PasClaw.Agents.pas'),
    (Name: 'AnnounceNewTask';      Defined: 'src/pkg/projects/PasClaw.Projects.Tools.pas'),
    (Name: 'AskPermission';        Defined: 'src/pkg/gateway/PasClaw.Gateway.Server.pas,src/pkg/tui/PasClaw.TUI.pas'),
    (Name: 'EnsureWorktree';       Defined: 'src/pkg/tools/PasClaw.Tools.Worktree.pas'),
    (Name: 'RouteTeams';           Defined: 'src/pkg/gateway/PasClaw.Gateway.Desktop.pas'),
    (Name: 'IsAgentTurn';          Defined: 'src/pkg/tools/PasClaw.Tools.Registry.pas'),
    (Name: 'RulesJSON';            Defined: 'src/pkg/projects/PasClaw.Projects.Tools.pas'),
    (Name: 'BuildFilteredRegistry'; Defined: 'src/pkg/agent/PasClaw.Agent.Subagent.pas'),
    (Name: 'PermissionGate';       Defined: 'src/pkg/tools/PasClaw.Tools.ToolLoop.pas'),
    (Name: 'ArrayHasAction';       Defined: 'src/pkg/projects/PasClaw.Projects.Tools.pas'),
    (Name: 'RefreshPolicies';      Defined: 'src/pkg/config/PasClaw.Permissions.pas'),
    (Name: 'RegisterDesktopTool';  Defined: 'src/pkg/projects/PasClaw.Projects.Tools.pas'),
    (Name: 'Tool_Task';            Defined: 'src/pkg/projects/PasClaw.Projects.Tools.pas'),
    (Name: 'LaneMatches';          Defined: 'src/pkg/projects/PasClaw.Projects.Tools.pas'),
    (Name: 'ResumeParkedTeams';    Defined: 'src/pkg/agent/PasClaw.Teams.pas'),
    (Name: 'DesktopConsent';       Defined: 'src/pkg/projects/PasClaw.Projects.Tools.pas'),
    (Name: 'CopyPreservingMode';   Defined: 'src/pkg/agent/PasClaw.Agent.Subagent.pas'),
    (Name: 'FindProofPair';        Defined: 'src/pkg/projects/PasClaw.Projects.Tools.pas'),
    (Name: 'RegisterFSTools';      Defined: 'src/pkg/tools/PasClaw.Tools.FS.pas'),
    (Name: 'PushSteering';         Defined: 'src/pkg/agent/PasClaw.Agent.Steering.pas'),
    (Name: 'UpdateTask';           Defined: 'src/pkg/projects/PasClaw.Projects.Store.pas,src/pkg/component/PasClaw.Client.Api.pas'),
    (Name: 'DeferredNames';        Defined: 'src/pkg/tools/PasClaw.Tools.Registry.pas'),
    (Name: 'ToProviderDefs';       Defined: 'src/pkg/tools/PasClaw.Tools.Registry.pas'),
    (Name: 'LoadSkillManifests';   Defined: 'src/pkg/skills/PasClaw.Skills.Loader.pas'),
    (Name: 'HandleResponses';      Defined: 'src/pkg/gateway/PasClaw.Gateway.Server.pas'),
    (Name: 'TaskReviewers';        Defined: 'src/pkg/agent/PasClaw.Teams.pas'),
    (Name: 'IsDesktopPath';        Defined: 'src/pkg/gateway/PasClaw.Gateway.Desktop.pas'),
    (Name: 'TakeSnapshot';         Defined: 'src/pkg/projects/PasClaw.Projects.Snapshots.pas'),
    (Name: 'ShellAllowed';         Defined: 'src/pkg/tools/PasClaw.Tools.Sandbox.pas')
  );

  BigFiles: array[0..3] of string = (
    'src/pkg/agent/PasClaw.Teams.pas',
    'src/pkg/projects/PasClaw.Projects.Tools.pas',
    'src/pkg/gateway/PasClaw.Gateway.Desktop.pas',
    'src/pkg/tools/PasClaw.Tools.Registry.pas');

  Dirs: array[0..1] of string = ('src/pkg/projects', 'src/pkg/tools');

  DefKeywords: array[0..3] of string = ('function ', 'procedure ', 'constructor ', '');

var
  R: TToolRegistry;

function Run(const Tool, Args: string): string;
var
  Err: string;
begin
  Result := R.RunTool(Tool, Args, Err);
  if Err <> '' then Result := 'ERROR: ' + Err;
end;

function J(const S: string): string;
begin
  Result := '"' + StringReplace(StringReplace(S, '\', '\\', [rfReplaceAll]),
                                '"', '\"', [rfReplaceAll]) + '"';
end;

{ Every defining file is named in Output. }
function Answers(const Output, Defined: string): Boolean;
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    L.CommaText := Defined;
    Result := L.Count > 0;
    for I := 0 to L.Count - 1 do
      if Pos(L[I], StringReplace(Output, '\', '/', [rfReplaceAll])) = 0 then Result := False;
  finally
    L.Free;
  end;
end;

function Lines(const S: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Length(S) do
    if S[I] = #10 then Inc(Result);
end;

function FileBytes(const Path: string): Int64;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(Path, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    FindClose(SR);
  end;
end;

var
  I, K, Calls, GnLines, OlLines: Integer;
  Out_, Pat: string;
  Found: Boolean;
  GnBytes, GdBytes, OlBytes, B: Int64;
  TGn, TGd, TOl, TGdCalls, OkGn, OkGd, OkOl, TGnLines, TOlLines: Int64;
  T: TTool;
begin
  if not DirectoryExists('src/pkg') then
  begin
    WriteLn('run from the repository root (make bench-codenav)');
    Halt(2);
  end;
  R := TToolRegistry.Create;
  try
    RegisterFSTools(R);
    TGn := 0; TGd := 0; TOl := 0; TGdCalls := 0;
    OkGn := 0; OkGd := 0; OkOl := 0; TGnLines := 0; TOlLines := 0;
    WriteLn('Where is NAME defined?   bytes returned (calls)        lines returned');
    WriteLn(Format('%-22s %9s %13s %9s   %9s %8s', ['name', 'grep-name', 'grep-def',
                   'outline', 'grep-name', 'outline']));
    for I := 0 to High(Lookups) do
    begin
      { grep-name }
      Out_ := Run('grep_files', '{"path":"src","pattern":' + J(Lookups[I].Name) + '}');
      GnBytes := Length(Out_);
      GnLines := Lines(Out_);
      if Answers(Out_, Lookups[I].Defined) then Inc(OkGn);
      { grep-def: keyword guesses until a defining file shows up }
      GdBytes := 0;
      Calls := 0;
      Found := False;
      for K := 0 to High(DefKeywords) do
      begin
        if DefKeywords[K] = '' then Pat := Lookups[I].Name + ' ='
        else Pat := DefKeywords[K] + Lookups[I].Name;
        Out_ := Run('grep_files', '{"path":"src","pattern":' + J(Pat) + '}');
        Inc(Calls);
        Inc(GdBytes, Length(Out_));
        if Answers(Out_, Lookups[I].Defined) then
        begin
          Found := True;
          Break;
        end;
      end;
      if Found then Inc(OkGd);
      { outline }
      Out_ := Run('code_outline', '{"path":"src","symbol":' + J(Lookups[I].Name) + '}');
      OlBytes := Length(Out_);
      OlLines := Lines(Out_);
      if Answers(Out_, Lookups[I].Defined) then Inc(OkOl)
      else WriteLn('  MISSED by outline: ', Lookups[I].Name, ' -> ', Out_);
      Inc(TGn, GnBytes); Inc(TGd, GdBytes); Inc(TOl, OlBytes); Inc(TGdCalls, Calls);
      Inc(TGnLines, GnLines); Inc(TOlLines, OlLines);
      WriteLn(Format('%-22s %9d %9d (%d) %9d   %9d %8d',
                     [Lookups[I].Name, GnBytes, GdBytes, Calls, OlBytes, GnLines, OlLines]));
    end;
    WriteLn(Format('%-22s %9d %9d (%d) %9d   %9d %8d',
                   ['TOTAL', TGn, TGd, TGdCalls, TOl, TGnLines, TOlLines]));
    WriteLn(Format('answered (all defining files in the result): grep-name %d/%d, ' +
                   'grep-def %d/%d, outline %d/%d',
                   [OkGn, Length(Lookups), OkGd, Length(Lookups), OkOl, Length(Lookups)]));
    WriteLn;

    WriteLn('What is in this file?      read whole (file bytes)   outline');
    for I := 0 to High(BigFiles) do
    begin
      B := FileBytes(BigFiles[I]);
      Out_ := Run('code_outline', '{"path":' + J(BigFiles[I]) + '}');
      WriteLn(Format('  %-46s %8d  %8d  (%.1f%%)',
                     [BigFiles[I], B, Length(Out_), 100.0 * Length(Out_) / B]));
    end;
    WriteLn;
    WriteLn('What is in this directory?   list_dir   outline (purposes and names)');
    for I := 0 to High(Dirs) do
      WriteLn(Format('  %-24s %8d  %8d', [Dirs[I],
        Length(Run('list_dir', '{"path":' + J(Dirs[I]) + '}')),
        Length(Run('code_outline', '{"path":' + J(Dirs[I]) + '}'))]));
    WriteLn;

    if R.Find('code_outline', T) then
      WriteLn(Format('code_outline schema, carried by every request: %d bytes ' +
                     '(name %d + description %d + parameters %d)',
                     [Length(T.Name) + Length(T.Description) + Length(T.Schema),
                      Length(T.Name), Length(T.Description), Length(T.Schema)]));
    WriteLn(Format('{"lookups":%d,"grep_name_bytes":%d,"grep_def_bytes":%d,' +
                   '"grep_def_calls":%d,"outline_bytes":%d,"outline_calls":%d,' +
                   '"answered":{"grep_name":%d,"grep_def":%d,"outline":%d}}',
                   [Length(Lookups), TGn, TGd, TGdCalls, TOl, Length(Lookups),
                    OkGn, OkGd, OkOl]));
    if OkOl < Length(Lookups) then Halt(1);
  finally
    R.Free;
  end;
end.
