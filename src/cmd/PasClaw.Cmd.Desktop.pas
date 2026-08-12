(*
  PasClaw.Cmd.Desktop - the `workspace` and `project` CLI commands.

  The desktop clients drive the same store over HTTP; these exist so the
  terminal is not a second-class citizen. Work started at the prompt shows up
  on the desktop tree and vice versa, because both are reading the same
  manifests under the active workspace.

    pasclaw workspace list
    pasclaw workspace new [label]
    pasclaw workspace use <name>

    pasclaw project list
    pasclaw project new <title>
    pasclaw project show <name>
    pasclaw project rm <name>
    pasclaw project seed              (install the system suite)
    pasclaw project export <name>     (blueprint to stdout)
    pasclaw project import <file>
*)
unit PasClaw.Cmd.Desktop;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Workspace_Run(const Argv: array of string): Integer;
function Cmd_Project_Run(const Argv: array of string): Integer;
function Cmd_Mail_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.CliUI,
  PasClaw.Utils,
  PasClaw.Workspaces,
  PasClaw.Projects.Store,
  PasClaw.Apps,
  PasClaw.Suite,
  PasClaw.Suite.Mail;

{ Conditional string. StrUtils has one, but a local helper keeps this unit's
  uses clause to the things it actually depends on. }
function IfThen_(Cond: Boolean; const Yes, No: string): string;
begin
  if Cond then Result := Yes else Result := No;
end;

{ ------------------------------------------------------------ workspace -- }

procedure WorkspaceUsage;
begin
  PrintLn('Usage: pasclaw workspace <list|new|use> [args]');
  PrintLn('');
  PrintLn('  list              show every workspace and which is active');
  PrintLn('  new [label]       create the next workspace (workspace2, ...)');
  PrintLn('  use <name>        switch the active workspace');
  PrintLn('  bind <name> <profile>   the profile this workspace works under');
  PrintLn('                          ("" clears; CLI --profile still wins)');
  PrintLn('');
  PrintLn('A workspace is an isolated agent world: its own memory, sessions,');
  PrintLn('skills and projects. The original workspace/ directory is #1.');
  PrintLn('$PASCLAW_WORKSPACE overrides the active one for a single process.');
end;

function Cmd_Workspace_Run(const Argv: array of string): Integer;
var
  Sub, Name_, Err, Mark: string;
  Rows: TWorkspaceInfoArray;
  I: Integer;
begin
  Result := 0;
  Sub := '';
  if Length(Argv) > 0 then Sub := LowerCase(Argv[0]);

  if (Sub = '') or (Sub = 'list') or (Sub = 'ls') then
  begin
    Rows := ListWorkspaces;
    for I := 0 to High(Rows) do
    begin
      if Rows[I].Active then Mark := '*' else Mark := ' ';
      PrintLn(Format('%s %-12s %-20s %d project(s)%s',
        [Mark, Rows[I].Name, Rows[I].Label_, Rows[I].Projects,
         IfThen_(DirectoryExists(Rows[I].Path), '', '   (not created yet)')]));
    end;
    Exit;
  end;

  if (Sub = 'new') or (Sub = 'create') then
  begin
    Name_ := '';
    if Length(Argv) > 1 then Name_ := Argv[1];
    Name_ := CreateWorkspace(Name_);
    PrintLn('Created ' + Name_ + ' (' + WorkspaceLabel(Name_) + ')');
    PrintLn('Switch to it with: pasclaw workspace use ' + Name_);
    Exit;
  end;

  if Sub = 'bind' then
  begin
    if Length(Argv) < 3 then
    begin
      PrintLn('Usage: pasclaw workspace bind <name> <profile>');
      Exit(1);
    end;
    if not IsWorkspaceName(Argv[1]) then
    begin
      PrintLn('error: not a workspace name: ' + Argv[1]);
      Exit(1);
    end;
    if not BindWorkspaceProfile(Argv[1], Argv[2], Err) then
    begin
      PrintLn('error: ' + Err);
      Exit(1);
    end;
    if Argv[2] = '' then
      PrintLn('Cleared the profile binding for ' + Argv[1])
    else
      PrintLn(Argv[1] + ' now works under the "' + Argv[2] + '" profile.');
    Exit;
  end;

  if (Sub = 'use') or (Sub = 'switch') then
  begin
    if Length(Argv) < 2 then
    begin
      PrintLn('Usage: pasclaw workspace use <name>');
      Exit(1);
    end;
    if not SetActiveWorkspace(Argv[1], Err) then
    begin
      PrintLn('error: ' + Err);
      Exit(1);
    end;
    PrintLn('Active workspace is now ' + ActiveWorkspaceName +
            ' (' + WorkspaceLabel(ActiveWorkspaceName) + ')');
    if Err <> '' then
      PrintLn('note: ' + Err);
    Exit;
  end;

  WorkspaceUsage;
  Result := 1;
end;

{ -------------------------------------------------------------- project -- }

procedure ProjectUsage;
begin
  PrintLn('Usage: pasclaw project <list|new|show|rm|seed|export|import> [args]');
  PrintLn('');
  PrintLn('  list                 projects in the active workspace');
  PrintLn('  new <title>          create a project');
  PrintLn('  show <name>          its tasks, jobs and app');
  PrintLn('  rm <name>            delete a project and everything in it');
  PrintLn('  seed                 install the system suite (Notes, To Do, Brain,');
  PrintLn('                       Calendar, Library, Cookbook, Mail)');
  PrintLn('  export <name>        write its blueprint to stdout');
  PrintLn('  import <file>        create a project from a blueprint file');
  PrintLn('');
  PrintLn('Projects hold the apps PasClaw builds for you, and the tasks and');
  PrintLn('jobs it works through. The desktop clients show the same board.');
end;

function ShowProject(const Name: string): Integer;
var
  P: TProjectInfo;
  Tasks: TTaskInfoArray;
  Jobs: TJobInfoArray;
  App: TAppInfo;
  I, J: Integer;
begin
  if not GetProject(Name, P) then
  begin
    PrintLn('error: no such project: ' + Name);
    Exit(1);
  end;
  Result := 0;
  PrintLn(P.Title + '  (' + P.Name + ')');
  if P.Description <> '' then PrintLn('  ' + P.Description);
  PrintLn('  created ' + P.Created);

  if GetApp(Name, App) and App.Exists then
  begin
    PrintLn('');
    PrintLn('  app: ' + App.Name + '  [' + AppKindToStr(App.Kind) + ']  ' +
            App.Entry + IfThen_(App.EntryExists, '', '  (entry missing)'));
    if App.Network <> '' then PrintLn('    network: ' + App.Network);
    if App.EnvKeys <> '' then PrintLn('    env: ' + App.EnvKeys);
  end;

  Tasks := ListTasks(Name);
  PrintLn('');
  if Length(Tasks) = 0 then
    PrintLn('  no tasks')
  else
    for I := 0 to High(Tasks) do
    begin
      PrintLn(Format('  %s  [%s]  %s', [Tasks[I].Id,
        TaskStatusToStr(Tasks[I].Status), Tasks[I].Title]));
      if Tasks[I].Notes <> '' then
        PrintLn('        ' + Tasks[I].Notes);
      Jobs := ListJobs(Name, Tasks[I].Id);
      for J := 0 to High(Jobs) do
        PrintLn(Format('        %s  %s%s', [Jobs[J].Id,
          JobStatusToStr(Jobs[J].Status),
          IfThen_(Jobs[J].Summary = '', '', '  -- ' + Jobs[J].Summary)]));
    end;
end;

function Cmd_Project_Run(const Argv: array of string): Integer;
var
  Sub, Name_, Err, Body: string;
  Rows: TProjectInfoArray;
  I, N: Integer;
begin
  Result := 0;
  Sub := '';
  if Length(Argv) > 0 then Sub := LowerCase(Argv[0]);

  if (Sub = '') or (Sub = 'list') or (Sub = 'ls') then
  begin
    Rows := ListProjects;
    if Length(Rows) = 0 then
    begin
      PrintLn('No projects in ' + ActiveWorkspaceName + '.');
      PrintLn('Create one with: pasclaw project new "My App"');
      PrintLn('Or install the system suite: pasclaw project seed');
      Exit;
    end;
    for I := 0 to High(Rows) do
      PrintLn(Format('  %-24s %-28s %d task(s), %d open%s',
        [Rows[I].Name, Rows[I].Title, Rows[I].TaskCount, Rows[I].OpenTasks,
         IfThen_(Rows[I].HasApp, '   [app]', '')]));
    Exit;
  end;

  if (Sub = 'new') or (Sub = 'create') then
  begin
    if Length(Argv) < 2 then
    begin
      PrintLn('Usage: pasclaw project new <title>');
      Exit(1);
    end;
    Name_ := CreateProject(Argv[1], '', '', Err);
    if Name_ = '' then
    begin
      PrintLn('error: ' + Err);
      Exit(1);
    end;
    PrintLn('Created project ' + Name_);
    PrintLn('Its app goes in ' + ProjectAppDir(Name_));
    Exit;
  end;

  if Sub = 'show' then
  begin
    if Length(Argv) < 2 then
    begin
      PrintLn('Usage: pasclaw project show <name>');
      Exit(1);
    end;
    Exit(ShowProject(Argv[1]));
  end;

  if (Sub = 'rm') or (Sub = 'delete') then
  begin
    if Length(Argv) < 2 then
    begin
      PrintLn('Usage: pasclaw project rm <name>');
      Exit(1);
    end;
    if not DeleteProject(Argv[1], Err) then
    begin
      PrintLn('error: ' + Err);
      Exit(1);
    end;
    PrintLn('Deleted ' + Argv[1]);
    Exit;
  end;

  if Sub = 'seed' then
  begin
    N := SeedSuite(Err);
    if N = 0 then
      PrintLn('The system suite is already installed in ' + ActiveWorkspaceName + '.')
    else
      PrintLn(Format('Installed %d suite app(s) in %s.', [N, ActiveWorkspaceName]));
    if Err <> '' then PrintLn('note: ' + Err);
    PrintLn('They are ordinary projects -- open one and ask PasClaw to change it.');
    Exit;
  end;

  if Sub = 'export' then
  begin
    if Length(Argv) < 2 then
    begin
      PrintLn('Usage: pasclaw project export <name>   (blueprint to stdout)');
      Exit(1);
    end;
    Body := ExportBlueprint(Argv[1], Err);
    if Body = '' then
    begin
      PrintLn('error: ' + Err);
      Exit(1);
    end;
    { Straight to stdout so it pipes: pasclaw project export notes > notes.json }
    Print(Body);
    Exit;
  end;

  if Sub = 'import' then
  begin
    if Length(Argv) < 2 then
    begin
      PrintLn('Usage: pasclaw project import <file>');
      Exit(1);
    end;
    if not FileExists(Argv[1]) then
    begin
      PrintLn('error: no such file: ' + Argv[1]);
      Exit(1);
    end;
    Name_ := '';
    if Length(Argv) > 2 then Name_ := Argv[2];
    Name_ := ImportBlueprint(ReadFileText(Argv[1]), Name_, Err);
    if Name_ = '' then
    begin
      PrintLn('error: ' + Err);
      Exit(1);
    end;
    PrintLn('Imported as project ' + Name_);
    Exit;
  end;

  ProjectUsage;
  Result := 1;
end;

{ ----------------------------------------------------------------- mail -- }

{
  pasclaw mail sync

  The same bridge the Mail app's Sync button drives, at the prompt -- which
  is what makes it schedulable:

    pasclaw cron add "*/15 * * * *" "pasclaw mail sync"

  It reads headers with BODY.PEEK[] and files them into the Mail app's list.
  Nothing is sent, nothing is answered, and nothing is marked read on the
  server. That last part is why this can run beside the Email channel
  without stealing its unseen set.
}
function Cmd_Mail_Run(const Argv: array of string): Integer;
var
  Sub, Err: string;
  Filed: Integer;
begin
  Sub := '';
  if Length(Argv) > 0 then Sub := LowerCase(Argv[0]);

  if (Sub = '') or (Sub = 'sync') then
  begin
    if not MailConfigured then
    begin
      PrintLn('IMAP is not configured.');
      PrintLn('Set PASCLAW_EMAIL_IMAP_HOST, _USER and _PASS (the same');
      PrintLn('credentials the email channel uses) and run this again.');
      Exit(1);
    end;
    if not SyncMail(Filed, Err) then
    begin
      PrintLn('error: ' + Err);
      Exit(1);
    end;
    if Filed = 0 then
      PrintLn('No new mail.')
    else
      PrintLn(Format('Filed %d new message(s) into the Mail app.', [Filed]));
    Exit(0);
  end;

  PrintLn('Usage: pasclaw mail sync');
  PrintLn('');
  PrintLn('Fills the Mail app''s inbox from IMAP and triages each subject.');
  PrintLn('Read-only: it never marks anything \Seen and never sends.');
  Result := 1;
end;

end.
