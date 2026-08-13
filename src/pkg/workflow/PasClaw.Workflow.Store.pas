{
  PasClaw.Workflow.Store - persistence for saved workflows, one JSON file per
  workflow under $PASCLAW_HOME/workspace/workflows/<id>.json. Mirrors the
  sessions store: a flat directory of JSON docs that rides the workspace
  export zip automatically.
}
unit PasClaw.Workflow.Store;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, PasClaw.Workflow;

type
  TWorkflowSummary = record
    Id: string;
    Name: string;
    Description: string;
    NodeCount: Integer;
  end;
  TWorkflowSummaryArray = array of TWorkflowSummary;

{ Absolute path of the workflows directory (created on demand by save). }
function WorkflowsDir: string;

{ Absolute path of the JSON file for a given id ('' if the id is unsafe). }
function WorkflowPath(const Id: string): string;

{ Id sanitizer -- same rules as sessions (alnum, -, _, ., no leading dot, no
  traversal). Guards the file path built from a client-supplied id. }
function IsSafeWorkflowId(const Id: string): Boolean;

{ List saved workflows (summaries only; cheap). }
function ListWorkflows: TWorkflowSummaryArray;

{ Load one workflow by id. False (with Err) when missing / unsafe id / bad JSON. }
function LoadWorkflow(const Id: string; out Spec: TWorkflowSpec; out Err: string): Boolean;

{ Save (create or replace). Uses Spec.Id (falls back to Spec.Name). False on an
  unsafe id or write failure. }
function SaveWorkflow(const Spec: TWorkflowSpec; out Err: string): Boolean;

{ Delete by id. False (with Err) on unsafe id; True (no error) if already gone. }
function DeleteWorkflow(const Id: string; out Err: string): Boolean;

implementation

uses
  PasClaw.Workspaces,
  PasClaw.Utils, PasClaw.Config;

function WorkflowsDir: string;
begin
  Result := JoinPath(GetHome, ActiveWorkspaceName + '/workflows');
end;

function IsSafeWorkflowId(const Id: string): Boolean;
var i: Integer; C: Char;
begin
  Result := False;
  if (Id = '') or (Length(Id) > 128) then Exit;
  if (Id = '.') or (Id = '..') then Exit;
  if Id[1] = '.' then Exit;
  for i := 1 to Length(Id) do
  begin
    C := Id[i];
    if not (((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
            ((C >= '0') and (C <= '9')) or (C = '-') or (C = '_') or (C = '.')) then
      Exit;
  end;
  Result := True;
end;

function PathFor(const Id: string): string;
begin
  Result := JoinPath(WorkflowsDir, Id + '.json');
end;

function WorkflowPath(const Id: string): string;
begin
  if not IsSafeWorkflowId(Id) then Exit('');
  Result := PathFor(Id);
end;

function ListWorkflows: TWorkflowSummaryArray;
var
  Dir: string;
  Info: TSearchRec;
  Id, Body, Err: string;
  Spec: TWorkflowSpec;
begin
  SetLength(Result, 0);
  Dir := WorkflowsDir;
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(JoinPath(Dir, '*.json'), faAnyFile, Info) = 0 then
  try
    repeat
      if (Info.Attr and faDirectory) <> 0 then Continue;
      Id := ChangeFileExt(Info.Name, '');
      if not IsSafeWorkflowId(Id) then Continue;
      try Body := ReadFileText(PathFor(Id)); except Body := ''; end;
      if Body = '' then Continue;
      if not ParseWorkflow(Body, Spec, Err) then Continue;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)].Id          := Id;
      Result[High(Result)].Name        := Spec.Name;
      Result[High(Result)].Description := Spec.Description;
      Result[High(Result)].NodeCount   := Length(Spec.Nodes);
    until FindNext(Info) <> 0;
  finally
    FindClose(Info);
  end;
end;

function LoadWorkflow(const Id: string; out Spec: TWorkflowSpec; out Err: string): Boolean;
var Path, Body: string;
begin
  Result := False;
  Err := '';
  if not IsSafeWorkflowId(Id) then begin Err := 'unsafe workflow id'; Exit; end;
  Path := PathFor(Id);
  if not FileExists(Path) then begin Err := Format('workflow "%s" not found', [Id]); Exit; end;
  try Body := ReadFileText(Path); except on E: Exception do begin Err := E.Message; Exit; end; end;
  Result := ParseWorkflow(Body, Spec, Err);
end;

function SaveWorkflow(const Spec: TWorkflowSpec; out Err: string): Boolean;
var Id: string;
begin
  Result := False;
  Err := '';
  Id := Spec.Id;
  if Trim(Id) = '' then Id := Spec.Name;
  if not IsSafeWorkflowId(Id) then
  begin Err := Format('unsafe workflow id "%s" (use letters, digits, - _ .)', [Id]); Exit; end;
  try
    ForceDirectories(WorkflowsDir);
    WriteFileText(PathFor(Id), WorkflowToJSON(Spec));
    Result := True;
  except
    on E: Exception do Err := E.Message;
  end;
end;

function DeleteWorkflow(const Id: string; out Err: string): Boolean;
var Path: string;
begin
  Result := False;
  Err := '';
  if not IsSafeWorkflowId(Id) then begin Err := 'unsafe workflow id'; Exit; end;
  Path := PathFor(Id);
  if FileExists(Path) then
    if not DeleteFile(Path) then begin Err := 'delete failed'; Exit; end;
  Result := True;
end;

end.
