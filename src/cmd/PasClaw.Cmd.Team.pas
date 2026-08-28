(*
  PasClaw.Cmd.Team -- `pasclaw team ...`: ready-made agent teams.

    pasclaw team list
    pasclaw team up <template> --goal "..." | --project <name> [--parked]
    pasclaw team status
    pasclaw team down <template>
    pasclaw team export <file> [name]

  The CLI works straight on the workspace stores, like `pasclaw
  project`: seeding, the kickoff message and the state file all happen
  here. What the CLI cannot do is START a run -- turns run in the
  gateway -- so `team up` from a terminal leaves the kickoff in the
  lead's mailbox and the wake loop in the state file, and the running
  gateway's tick picks both up within a minute. With no gateway
  running, the team simply waits, fully formed.
*)
unit PasClaw.Cmd.Team;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Team_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.CliUI,
  PasClaw.Workspaces,
  PasClaw.Projects.Store,
  PasClaw.Agents,
  PasClaw.Teams;

{ Conditional string, same local helper Cmd.Desktop keeps. }
function IfThen_(Cond: Boolean; const Yes, No: string): string;
begin
  if Cond then Result := Yes else Result := No;
end;

procedure Usage;
begin
  PrintLn('Usage: pasclaw team <command>');
  PrintLn('  list                      the template catalogue (built-in + workspace/teams/)');
  PrintLn('  up <template> --goal "..."      seed the team and point it at a goal');
  PrintLn('  up <template> --project <name>  seed the team and point it at an existing board');
  PrintLn('     [--parked]             seed without the wake loop (enable later with up)');
  PrintLn('  status                    every team that is up, and its board');
  PrintLn('  down <template>           park a team: agents and board stay, the clock stops');
  PrintLn('  export <file> [name]      write the live roster as a template file');
end;

function TeamUp(const Argv: array of string): Integer;
var
  T: TTeamTemplate;
  S: TTeamState;
  Created, Skipped, Leads: TStringArray;
  Name_, Goal, Project, Err, Delivered, Kick: string;
  I: Integer;
  Parked: Boolean;
begin
  Result := 1;
  if Length(Argv) < 2 then
  begin
    Usage;
    Exit;
  end;
  Name_ := Argv[1];
  Goal := ''; Project := ''; Parked := False;
  I := 2;
  while I <= High(Argv) do
  begin
    if (Argv[I] = '--goal') and (I < High(Argv)) then
    begin
      Goal := Argv[I + 1]; Inc(I, 2);
    end
    else if (Argv[I] = '--project') and (I < High(Argv)) then
    begin
      Project := Argv[I + 1]; Inc(I, 2);
    end
    else if Argv[I] = '--parked' then
    begin
      Parked := True; Inc(I);
    end
    else
    begin
      PrintLn('error: unknown argument "' + Argv[I] + '"');
      Exit;
    end;
  end;

  if not FindTeamTemplate(Name_, T) then
  begin
    PrintLn('error: no team template called "' + Name_ +
            '" -- pasclaw team list shows them');
    Exit;
  end;
  if (Goal = '') and (Project = '') then
  begin
    PrintLn('error: point the team at work -- --goal "..." or --project <name>');
    Exit;
  end;
  if (Project <> '') and not ProjectExists(Project) then
  begin
    PrintLn('error: no project called "' + Project + '"');
    Exit;
  end;

  if not SeedTeam(T, Created, Skipped, Err) then
  begin
    PrintLn('error: ' + Err);
    Exit;
  end;
  for I := 0 to High(Created) do
    PrintLn('  created  ' + Created[I]);
  for I := 0 to High(Skipped) do
    PrintLn('  kept     ' + Skipped[I] + '  (already existed; role and ' +
            'conversation untouched)');

  if Project = '' then
  begin
    Project := CreateProject(Goal, '', 'Team ' + T.Name + ': ' + Goal, Err);
    if Project = '' then
    begin
      PrintLn('error: seeded the agents but could not create the goal ' +
              'project: ' + Err);
      Exit;
    end;
    PrintLn('  project  ' + Project);
  end;

  S := Default(TTeamState);
  S.Name        := T.Name;
  S.Project     := Project;
  S.Goal        := Goal;
  S.Enabled     := not Parked;
  S.WakeMinutes := T.WakeMinutes;
  S.WakeWho     := T.WakeWho;
  if Length(S.WakeWho) = 0 then S.WakeWho := TeamWakeList(T);
  if not SaveTeamState(S, Err) then
  begin
    PrintLn('error: ' + Err);
    Exit;
  end;

  Kick := TeamKickoffText(T, Goal, Project);
  Leads := TeamLeads(T);
  for I := 0 to High(Leads) do
    if AgentSend(Leads[I], 'operator', Kick, Delivered, Err) then
      PrintLn('  kickoff  -> ' + Leads[I] + ' (' + Delivered + ')');

  if Parked then
    PrintLn('Team ' + T.Name + ' is up and PARKED on ' + Project +
            ' -- run `pasclaw team up ' + T.Name + ' --project ' + Project +
            '` again without --parked to start the clock.')
  else
    PrintLn('Team ' + T.Name + ' is up on ' + Project + '. The gateway''s ' +
            'wake loop takes it from here (waking every ' +
            IntToStr(S.WakeMinutes) + 'm); if no gateway is running, ' +
            'start one and the kickoff is waiting in the lead''s mailbox.');
  Result := 0;
end;

function Cmd_Team_Run(const Argv: array of string): Integer;
var
  Sub, Err, Path, Name_: string;
  All: TTeamTemplateArray;
  States: TTeamStateArray;
  S: TTeamState;
  Tasks: TTaskInfoArray;
  I, J, OpenN: Integer;
begin
  Result := 0;
  Sub := '';
  if Length(Argv) > 0 then Sub := LowerCase(Argv[0]);

  if (Sub = '') or (Sub = 'list') or (Sub = 'ls') then
  begin
    All := TeamTemplates;
    for I := 0 to High(All) do
    begin
      PrintLn(Format('  %-16s %-16s %d agent(s)  wake %dm',
        [All[I].Name, All[I].Title, Length(All[I].Agents),
         All[I].WakeMinutes]));
      PrintLn('      ' + All[I].Description);
    end;
    PrintLn('Up a team: pasclaw team up <template> --goal "..." | --project <name>');
    Exit;
  end;

  if Sub = 'up' then
    Exit(TeamUp(Argv));

  if Sub = 'status' then
  begin
    States := ListTeamStates;
    if Length(States) = 0 then
    begin
      PrintLn('No teams are up in ' + ActiveWorkspaceName + '.');
      Exit;
    end;
    for I := 0 to High(States) do
    begin
      OpenN := 0;
      Tasks := ListTasks(States[I].Project);
      for J := 0 to High(Tasks) do
        if Tasks[J].Status <> tsDone then Inc(OpenN);
      PrintLn(Format('  %-16s %-20s %s  %d task(s), %d open  last tick %s',
        [States[I].Name, States[I].Project,
         IfThen_(States[I].Enabled, 'waking every ' +
                 IntToStr(States[I].WakeMinutes) + 'm', 'PARKED'),
         Length(Tasks), OpenN,
         IfThen_(States[I].LastTick <> '', States[I].LastTick, '(never)')]));
    end;
    Exit;
  end;

  if Sub = 'down' then
  begin
    if Length(Argv) < 2 then
    begin
      PrintLn('Usage: pasclaw team down <template>');
      Exit(1);
    end;
    if not LoadTeamState(Argv[1], S) then
    begin
      PrintLn('error: no team called "' + Argv[1] + '" is up');
      Exit(1);
    end;
    S.Enabled := False;
    if not SaveTeamState(S, Err) then
    begin
      PrintLn('error: ' + Err);
      Exit(1);
    end;
    PrintLn('Team ' + S.Name + ' parked: agents, conversations and the ' +
            'board stay; nothing wakes until you up it again.');
    Exit;
  end;

  if Sub = 'export' then
  begin
    if Length(Argv) < 2 then
    begin
      PrintLn('Usage: pasclaw team export <file> [name]');
      Exit(1);
    end;
    Path := Argv[1];
    if Length(Argv) > 2 then Name_ := Argv[2]
                        else Name_ := ChangeFileExt(ExtractFileName(Path), '');
    WriteFileText(Path, ExportRosterJSON(Name_, Name_));
    PrintLn('Wrote the live roster (' + IntToStr(Length(ListAgents)) +
            ' agent(s)) to ' + Path);
    PrintLn('Drop it in ' + TeamStateDir + '/../ to make it a template ' +
            'in this workspace.');
    Exit;
  end;

  Usage;
  Result := 1;
end;

end.
