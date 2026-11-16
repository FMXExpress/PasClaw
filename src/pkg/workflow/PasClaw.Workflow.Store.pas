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

(* Approval. A workflow the AGENT saves is staged, not saved: it lands in
   workflows/.pending/<id>.json and runs (or becomes a tool) only once the
   operator approves it -- the same contract as an agent-authored skill.
   The operator's own saves (the web editor, the API) are not staged. *)

{ workflows/.pending -- never listed as a workflow, never a tool. }
function PendingWorkflowsDir: string;
{ Stage Spec for approval, replacing an earlier staged version. }
function StagePendingWorkflow(const Spec: TWorkflowSpec; out Err: string): Boolean;
function ListPendingWorkflows: TWorkflowSummaryArray;
function LoadPendingWorkflow(const Id: string; out Spec: TWorkflowSpec; out Err: string): Boolean;
{ Validate the staged spec again and save it as a workflow; the staged copy
  is removed. Replaces a saved workflow of the same id. }
function ApprovePendingWorkflow(const Id: string; out Err: string): Boolean; overload;
{ The same, refusing when the staged file no longer hashes to ExpectedSha
  (empty = no check): what is approved is what the operator read, not a
  version the agent staged over it since. }
function ApprovePendingWorkflow(const Id, ExpectedSha: string; out Err: string): Boolean; overload;
{ SHA-256 (hex) of the staged file, '' when there is none. }
function PendingWorkflowSha(const Id: string): string;
{ Discard the staged spec. }
function RejectPendingWorkflow(const Id: string; out Err: string): Boolean;
{ Is there a saved (approved) workflow with this id? }
function WorkflowExists(const Id: string): Boolean;

{ Bumped by every save, delete and approval in this process: with the
  directory listing it tells a cache the store changed, even when a
  rewrite keeps a file's size and lands in the same second. }
function WorkflowStoreGeneration: Integer;

implementation

uses
  PasClaw.Workspaces,
  PasClaw.Utils, PasClaw.Config,
  PasClaw.Crypto.HMAC;   { SHA256Bytes }

var
  GStoreGen: Integer = 0;

function WorkflowStoreGeneration: Integer;
begin
  Result := GStoreGen;
end;

procedure StoreChanged;
begin
  InterlockedIncrement(GStoreGen);
end;

{ "pending" is the approval list's route (/v1/workflows/pending): a
  workflow saved under that id could never be read back over HTTP. }
function ReservedWorkflowId(const Id: string): Boolean;
begin
  Result := SameText(Id, 'pending');
end;

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
  if ReservedWorkflowId(Id) then
  begin Err := Format('"%s" is reserved; name the workflow something else', [Id]); Exit; end;
  try
    ForceDirectories(WorkflowsDir);
    WriteFileText(PathFor(Id), WorkflowToJSON(Spec));
    StoreChanged;
    Result := True;
  except
    on E: Exception do Err := E.Message;
  end;
end;

function PendingWorkflowsDir: string;
begin
  Result := JoinPath(WorkflowsDir, '.pending');
end;

function SpecId(const Spec: TWorkflowSpec): string;
begin
  Result := Spec.Id;
  if Trim(Result) = '' then Result := Spec.Name;
end;

function StagePendingWorkflow(const Spec: TWorkflowSpec; out Err: string): Boolean;
var
  Id: string;
begin
  Result := False;
  Err := '';
  Id := SpecId(Spec);
  if not IsSafeWorkflowId(Id) then
  begin Err := Format('unsafe workflow id "%s" (use letters, digits, - _ .)', [Id]); Exit; end;
  if ReservedWorkflowId(Id) then
  begin Err := Format('"%s" is reserved; name the workflow something else', [Id]); Exit; end;
  try
    ForceDirectories(PendingWorkflowsDir);
    WriteFileText(JoinPath(PendingWorkflowsDir, Id + '.json'), WorkflowToJSON(Spec));
    Result := True;
  except
    on E: Exception do Err := E.Message;
  end;
end;

function ListPendingWorkflows: TWorkflowSummaryArray;
var
  Info: TSearchRec;
  Id, Body, Err: string;
  Spec: TWorkflowSpec;
begin
  SetLength(Result, 0);
  if not DirectoryExists(PendingWorkflowsDir) then Exit;
  if FindFirst(JoinPath(PendingWorkflowsDir, '*.json'), faAnyFile, Info) = 0 then
  try
    repeat
      if (Info.Attr and faDirectory) <> 0 then Continue;
      Id := ChangeFileExt(Info.Name, '');
      if not IsSafeWorkflowId(Id) then Continue;
      try Body := ReadFileText(JoinPath(PendingWorkflowsDir, Info.Name)); except Body := ''; end;
      if (Body = '') or not ParseWorkflow(Body, Spec, Err) then Continue;
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

function LoadPendingWorkflow(const Id: string; out Spec: TWorkflowSpec; out Err: string): Boolean;
var
  Path, Body: string;
begin
  Result := False;
  Err := '';
  if not IsSafeWorkflowId(Id) then begin Err := 'unsafe workflow id'; Exit; end;
  Path := JoinPath(PendingWorkflowsDir, Id + '.json');
  if not FileExists(Path) then begin Err := Format('no workflow "%s" waiting for approval', [Id]); Exit; end;
  try Body := ReadFileText(Path); except on E: Exception do begin Err := E.Message; Exit; end; end;
  Result := ParseWorkflow(Body, Spec, Err);
end;

function PendingWorkflowSha(const Id: string): string;
var
  Path: string;
begin
  Result := '';
  if not IsSafeWorkflowId(Id) then Exit;
  Path := JoinPath(PendingWorkflowsDir, Id + '.json');
  if not FileExists(Path) then Exit;
  try
    Result := BytesToHexLower(SHA256Bytes(StringToBytes(ReadFileText(Path))));
  except
    Result := '';
  end;
end;

function ApprovePendingWorkflow(const Id: string; out Err: string): Boolean;
begin
  Result := ApprovePendingWorkflow(Id, '', Err);
end;

function ApprovePendingWorkflow(const Id, ExpectedSha: string; out Err: string): Boolean;
var
  Spec: TWorkflowSpec;
  Errs: string;
begin
  Result := False;
  if not LoadPendingWorkflow(Id, Spec, Err) then Exit;
  if (ExpectedSha <> '') and not SameText(ExpectedSha, PendingWorkflowSha(Id)) then
  begin
    Err := Format('the staged "%s" changed since it was read; read it again before approving', [Id]);
    Exit;
  end;
  if not ValidateWorkflow(Spec, nil, Errs) then
  begin
    Err := 'invalid workflow:' + sLineBreak + Errs;
    Exit;
  end;
  Spec.Id := Id;
  if not SaveWorkflow(Spec, Err) then Exit;
  if not DeleteFile(JoinPath(PendingWorkflowsDir, Id + '.json')) then
  begin
    Err := 'saved, but the staged copy could not be removed';
    Exit;
  end;
  Result := True;
end;

function RejectPendingWorkflow(const Id: string; out Err: string): Boolean;
var
  Path: string;
begin
  Result := False;
  Err := '';
  if not IsSafeWorkflowId(Id) then begin Err := 'unsafe workflow id'; Exit; end;
  Path := JoinPath(PendingWorkflowsDir, Id + '.json');
  if not FileExists(Path) then begin Err := Format('no workflow "%s" waiting for approval', [Id]); Exit; end;
  if not DeleteFile(Path) then begin Err := 'delete failed'; Exit; end;
  Result := True;
end;

function WorkflowExists(const Id: string): Boolean;
begin
  Result := IsSafeWorkflowId(Id) and FileExists(PathFor(Id));
end;

function DeleteWorkflow(const Id: string; out Err: string): Boolean;
var Path: string;
begin
  Result := False;
  Err := '';
  if not IsSafeWorkflowId(Id) then begin Err := 'unsafe workflow id'; Exit; end;
  Path := PathFor(Id);
  if FileExists(Path) then
  begin
    if not DeleteFile(Path) then begin Err := 'delete failed'; Exit; end;
    StoreChanged;
  end;
  Result := True;
end;

end.
