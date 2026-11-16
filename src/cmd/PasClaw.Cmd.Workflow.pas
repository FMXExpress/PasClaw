(*
  PasClaw.Cmd.Workflow -- `pasclaw workflow list | pending | show | approve | reject`.

  A workflow the agent saves (workflow_save) is staged for the operator,
  not saved, unless config.workflows_auto_approve is on: it runs, and is
  served as the tool wf_<name>, only after an approve here, over HTTP
  (POST /v1/workflows/pending/approve) or from the web UI's Workflow tab.
  `show` prints what each step would call with which arguments, which is
  the thing to read before approving.
*)
unit PasClaw.Cmd.Workflow;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Workflow_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.CliUI,
  PasClaw.Workflow,
  PasClaw.Workflow.Store,
  PasClaw.Workflow.Tools;   { WorkflowToolName }

procedure Help;
begin
  PrintLn('Usage: pasclaw workflow list');
  PrintLn('       pasclaw workflow pending');
  PrintLn('       pasclaw workflow show <id>');
  PrintLn('       pasclaw workflow approve <id> [--sha256 <hex>]');
  PrintLn('       pasclaw workflow reject <id>');
  PrintLn;
  PrintLn('  list     Saved workflows, each with the tool name it is served as.');
  PrintLn('  pending  Workflows the agent saved that wait for your approval.');
  PrintLn('  show     Every step of a workflow: the tool it calls and the arguments.');
  PrintLn('           Shows the staged version when one is waiting, else the saved one.');
  PrintLn('  approve  Save the staged workflow: it runs, and becomes the tool wf_<id>.');
  PrintLn('           --sha256 refuses if the staged file changed since `show`.');
  PrintLn('  reject   Discard the staged workflow.');
end;

function DoList: Integer;
var
  Sums: TWorkflowSummaryArray;
  i: Integer;
begin
  Sums := ListWorkflows;
  if Length(Sums) = 0 then
  begin
    PrintLn('(no saved workflows)');
    Exit(0);
  end;
  for i := 0 to High(Sums) do
    PrintLn(Format('  %-28s %-32s %d step(s)  %s',
      [Sums[i].Id, WorkflowToolName(Sums[i].Id), Sums[i].NodeCount, Sums[i].Description]));
  Result := 0;
end;

function DoPending: Integer;
var
  Sums: TWorkflowSummaryArray;
  i: Integer;
  Note: string;
begin
  Sums := ListPendingWorkflows;
  if Length(Sums) = 0 then
  begin
    PrintLn('(no workflows waiting for approval)');
    Exit(0);
  end;
  for i := 0 to High(Sums) do
  begin
    if WorkflowExists(Sums[i].Id) then Note := '  (replaces the saved one)' else Note := '';
    PrintLn(Format('  %-28s %d step(s)  %s%s',
      [Sums[i].Id, Sums[i].NodeCount, Sums[i].Description, Note]));
  end;
  PrintLn;
  PrintLn(Ansi.Dim + 'Read: pasclaw workflow show <id>   Approve: pasclaw workflow approve <id>   ' +
          'Discard: pasclaw workflow reject <id>' + Ansi.Reset);
  Result := 0;
end;

procedure PrintSpec(const Spec: TWorkflowSpec);
var
  i: Integer;
  Req: string;
begin
  PrintLn(Ansi.Bold + Spec.Name + Ansi.Reset);
  if Spec.Description <> '' then PrintLn('  ' + Spec.Description);
  if Length(Spec.Inputs) > 0 then
  begin
    PrintLn('Inputs:');
    for i := 0 to High(Spec.Inputs) do
    begin
      if Spec.Inputs[i].Required then Req := ' (required)' else Req := '';
      PrintLn(Format('  %s: %s%s', [Spec.Inputs[i].Name, Spec.Inputs[i].InputType, Req]));
    end;
  end;
  PrintLn('Steps:');
  for i := 0 to High(Spec.Nodes) do
  begin
    PrintLn(Format('  %s  %s', [Spec.Nodes[i].Id, Spec.Nodes[i].Tool]));
    PrintLn('      ' + Spec.Nodes[i].ArgsJSON);
    if Spec.Nodes[i].Await.Enabled then
      PrintLn('      then polls ' + Spec.Nodes[i].Await.PollTool + ' ' +
              Spec.Nodes[i].Await.PollArgsJSON);
  end;
  if Length(Spec.Edges) > 0 then
  begin
    PrintLn('Order:');
    for i := 0 to High(Spec.Edges) do
      PrintLn('  ' + Spec.Edges[i].FromId + ' -> ' + Spec.Edges[i].ToId);
  end;
  if Spec.Loop.Enabled then
    PrintLn(Format('Repeats up to %d times, until %s',
      [Spec.Loop.MaxIterations, Spec.Loop.UntilTemplate]));
  if Spec.OutputDir <> '' then PrintLn('Writes outputs to: ' + Spec.OutputDir);
end;

function DoShow(const Argv: array of string): Integer;
var
  Spec: TWorkflowSpec;
  Err, Id: string;
begin
  if Length(Argv) < 2 then begin PrintLn('Usage: pasclaw workflow show <id>'); Exit(1); end;
  Id := Argv[1];
  if LoadPendingWorkflow(Id, Spec, Err) then
  begin
    PrintLn(Ansi.Yellow + 'Waiting for approval' + Ansi.Reset +
            ' -- sha256 ' + PendingWorkflowSha(Id));
    if WorkflowExists(Id) then
      PrintLn('Approving replaces the saved workflow "' + Id + '".');
    PrintSpec(Spec);
    Exit(0);
  end;
  if not LoadWorkflow(Id, Spec, Err) then
  begin
    PrintErr(Err);
    Exit(1);
  end;
  PrintLn('Saved -- served as the tool ' + WorkflowToolName(Id));
  PrintSpec(Spec);
  Result := 0;
end;

function DoApprove(const Argv: array of string): Integer;
var
  Id, Sha, Err: string;
  i: Integer;
begin
  Id := '';
  Sha := '';
  i := 1;
  while i <= High(Argv) do
  begin
    if (Argv[i] = '--sha256') and (i < High(Argv)) then
    begin
      Sha := Argv[i + 1];
      Inc(i, 2);
      Continue;
    end;
    if Id = '' then Id := Argv[i];
    Inc(i);
  end;
  if Id = '' then begin PrintLn('Usage: pasclaw workflow approve <id> [--sha256 <hex>]'); Exit(1); end;
  if not ApprovePendingWorkflow(Id, Sha, Err) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'approve failed: ' + Err);
    Exit(1);
  end;
  PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'approved ' + Id + ' -- it runs now, and is the tool ' +
          WorkflowToolName(Id) + ' (no restart needed)');
  Result := 0;
end;

function DoReject(const Argv: array of string): Integer;
var
  Err: string;
begin
  if Length(Argv) < 2 then begin PrintLn('Usage: pasclaw workflow reject <id>'); Exit(1); end;
  if not RejectPendingWorkflow(Argv[1], Err) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'reject failed: ' + Err);
    Exit(1);
  end;
  PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'discarded the staged ' + Argv[1]);
  Result := 0;
end;

function Cmd_Workflow_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then begin Help; Exit(1); end;
  Sub := Argv[0];
  if      Sub = 'list'    then Result := DoList
  else if Sub = 'pending' then Result := DoPending
  else if Sub = 'show'    then Result := DoShow(Argv)
  else if Sub = 'approve' then Result := DoApprove(Argv)
  else if Sub = 'reject'  then Result := DoReject(Argv)
  else if (Sub = 'help') or (Sub = '-h') or (Sub = '--help') then
  begin
    Help;
    Result := 0;
  end
  else
  begin
    PrintErr('unknown subcommand: ' + Sub);
    Help;
    Result := 1;
  end;
end;

end.
