(*
  PasClaw.Workflow.Share - importing a portable workflow file.

  The file (PasClaw.Workflow.Export.ExportWorkflowFile) is a versioned
  envelope:

    {"format": "pasclaw-workflow", "version": 1,
     "exported_at": "...", "pasclaw_version": "...",
     "workflow": { ...the spec, exactly as PasClaw saves it... },
     "requires": {"mcp_servers": [...], "providers": [...],
                  "tools": [...], "replicate_models": [...]}}

  An imported workflow can run shell, file and MCP tools, so it never
  becomes runnable on its own: it is STAGED for approval exactly like a
  workflow the agent saves (workflows/.pending/<id>.json, approved with
  `pasclaw workflow approve`, the web UI's approvals list, or
  POST /v1/workflows/pending/approve). Only `pasclaw workflow import
  --approve` -- the operator at their own terminal -- saves it directly.

  What the workflow needs and this machine lacks (an MCP server not
  configured, a provider missing, a built-in tool not registered) is
  reported, not refused: the operator decides.
*)
unit PasClaw.Workflow.Share;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Workflow;

type
  { Is a built-in tool registered here? nil = do not check. }
  TWorkflowToolProbe = function(const Name: string): Boolean of object;

  TWorkflowImportResult = record
    Id: string;
    Staged: Boolean;        { False: saved (--approve) }
    Replaces: Boolean;      { a saved or staged workflow of this id is replaced }
    Clash: Boolean;         { refused: the id is taken (no replace / as) }
    Missing: TStringArray;  { what this machine lacks, one line each }
  end;

{ Parse and validate a workflow file. Err says what is wrong with it. }
function ParseWorkflowFile(const Body: string; out Spec: TWorkflowSpec;
  out RequiresJSON, Err: string): Boolean;

{ What Spec (with the file's requires) needs that this machine lacks. }
function MissingRequirements(const Spec: TWorkflowSpec; const RequiresJSON: string;
  Cfg: TConfig; ToolProbe: TWorkflowToolProbe): TStringArray;

{ Import a workflow file: stage it (or save it with Approve). AsId renames
  it; an id already saved or staged is refused unless Replace. False with
  Err on a bad file, a bad id or a clash (R.Clash). }
function ImportWorkflowFile(const Body, AsId: string; Replace, Approve: Boolean;
  Cfg: TConfig; ToolProbe: TWorkflowToolProbe;
  out R: TWorkflowImportResult; out Err: string): Boolean;

{ GET an http(s) URL through the SSRF guard (every redirect checked too),
  at most MaxBytes. }
function FetchWorkflowURL(const URL: string; MaxBytes: Integer;
  out Body, Err: string): Boolean;

const
  WORKFLOW_FILE_MAX_BYTES = 1024 * 1024;

implementation

uses
  PasClaw.JSON,
  PasClaw.Net.SSRF,
  PasClaw.Providers.HTTP,
  PasClaw.Workflow.Store,
  PasClaw.Workflow.Export;

function ParseWorkflowFile(const Body: string; out Spec: TWorkflowSpec;
  out RequiresJSON, Err: string): Boolean;
var
  Root, W, Rq: TJsonObject;
  Fmt, Errs: string;
  Ver: Int64;
begin
  Result := False;
  RequiresJSON := '{}';
  Err := '';
  Spec := Default(TWorkflowSpec);
  if Length(Body) > WORKFLOW_FILE_MAX_BYTES then
  begin
    Err := Format('the file is larger than %d bytes', [WORKFLOW_FILE_MAX_BYTES]);
    Exit;
  end;
  Root := JsonTryParse(Body);
  if Root = nil then
  begin
    Err := 'not a workflow file: the body is not a JSON object';
    Exit;
  end;
  try
    Fmt := Root.GetStr('format', '');
    if Fmt <> WORKFLOW_FILE_FORMAT then
    begin
      if Fmt = '' then
        Err := 'not a workflow file: "format" is missing (want "' + WORKFLOW_FILE_FORMAT + '")'
      else
        Err := 'not a workflow file: "format" is "' + Fmt + '" (want "' + WORKFLOW_FILE_FORMAT + '")';
      Exit;
    end;
    Ver := Root.GetInt('version', 0);
    if Ver <> WORKFLOW_FILE_VERSION then
    begin
      Err := Format('workflow file version %d is not supported (this PasClaw reads version %d)',
                    [Ver, WORKFLOW_FILE_VERSION]);
      Exit;
    end;
    W := Root.ChildObject('workflow');
    if W = nil then
    begin
      Err := 'the workflow file has no "workflow" object';
      Exit;
    end;
    try
      if not ParseWorkflow(W.ToJSON, Spec, Err) then
      begin
        Err := 'the workflow in the file does not parse: ' + Err;
        Exit;
      end;
    finally
      W.Free;
    end;
    Rq := Root.ChildObject('requires');
    if Rq <> nil then
    try
      RequiresJSON := Rq.ToJSON;
    finally
      Rq.Free;
    end;
  finally
    Root.Free;
  end;
  if Trim(Spec.Id) = '' then Spec.Id := Spec.Name;
  if not ValidateWorkflow(Spec, nil, Errs) then
  begin
    Err := 'the workflow in the file is not valid: ' + Trim(Errs);
    Exit;
  end;
  Result := True;
end;

function HasServer(Cfg: TConfig; const Name: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if Cfg = nil then Exit;
  for i := 0 to High(Cfg.MCPServers) do
    if (Cfg.MCPServers[i].Name = Name) and Cfg.MCPServers[i].Enabled then Exit(True);
end;

function HasProvider(Cfg: TConfig; const Name: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if Cfg = nil then Exit;
  for i := 0 to High(Cfg.Providers) do
    if Cfg.Providers[i].Name = Name then Exit(True);
end;

procedure AddLine(var A: TStringArray; const S: string);
var
  i: Integer;
begin
  for i := 0 to High(A) do
    if A[i] = S then Exit;
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

function MissingRequirements(const Spec: TWorkflowSpec; const RequiresJSON: string;
  Cfg: TConfig; ToolProbe: TWorkflowToolProbe): TStringArray;
var
  Rq, O: TJsonObject;
  Arr, Sub: TJsonArray;
  i, k: Integer;
  Name, How: string;
  Here: TWorkflowRequirements;
begin
  SetLength(Result, 0);
  { the file's own list says how to add a server; the spec says what is used }
  Rq := JsonTryParse(RequiresJSON);
  if Rq <> nil then
  try
    Arr := Rq.ChildArray('mcp_servers');
    if Arr <> nil then
    try
      for i := 0 to Arr.Count - 1 do
      begin
        O := Arr.ItemObject(i);
        if O = nil then Continue;
        try
          Name := O.GetStr('name', '');
          if (Name = '') or HasServer(Cfg, Name) then Continue;
          How := O.GetStr('url', '');
          if How = '' then
          begin
            How := O.GetStr('command', '');
            Sub := O.ChildArray('args');
            if Sub <> nil then
            try
              for k := 0 to Sub.Count - 1 do How := How + ' ' + Sub.ItemStr(k, '');
            finally
              Sub.Free;
            end;
          end;
          if How <> '' then
            AddLine(Result, Format('MCP server "%s" is not configured here (the author ran: %s)', [Name, Trim(How)]))
          else
            AddLine(Result, Format('MCP server "%s" is not configured here', [Name]));
        finally
          O.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
  finally
    Rq.Free;
  end;
  Here := CollectWorkflowRequirements(Spec, Cfg);
  for i := 0 to High(Here.MCP) do
    if not HasServer(Cfg, Here.MCP[i].Name) then
      AddLine(Result, Format('MCP server "%s" is not configured here', [Here.MCP[i].Name]));
  for i := 0 to High(Here.Providers) do
    if (Here.Providers[i].Name <> '') and not HasProvider(Cfg, Here.Providers[i].Name) then
      AddLine(Result, Format('provider "%s" is not configured here', [Here.Providers[i].Name]))
    else if Here.Providers[i].Name = '' then
      AddLine(Result, 'an llm step needs a provider, and none is the default here');
  if Assigned(ToolProbe) then
    for i := 0 to High(Here.Tools) do
      if not ToolProbe(Here.Tools[i]) then
        AddLine(Result, Format('built-in tool "%s" is not available here', [Here.Tools[i]]));
end;

function ImportWorkflowFile(const Body, AsId: string; Replace, Approve: Boolean;
  Cfg: TConfig; ToolProbe: TWorkflowToolProbe;
  out R: TWorkflowImportResult; out Err: string): Boolean;
var
  Spec: TWorkflowSpec;
  RequiresJSON, Ignored: string;
  Taken: Boolean;
begin
  Result := False;
  R := Default(TWorkflowImportResult);
  if not ParseWorkflowFile(Body, Spec, RequiresJSON, Err) then Exit;
  if Trim(AsId) <> '' then Spec.Id := Trim(AsId);
  R.Id := Spec.Id;
  if not IsSafeWorkflowId(Spec.Id) then
  begin
    Err := Format('unsafe workflow id "%s" (use letters, digits, - _ .)', [Spec.Id]);
    Exit;
  end;
  if SameText(Spec.Id, 'pending') then
  begin
    Err := '"pending" is reserved; import it under another id';
    Exit;
  end;
  Taken := WorkflowExists(Spec.Id) or (PendingWorkflowSha(Spec.Id) <> '');
  if Taken and not Replace then
  begin
    R.Clash := True;
    if WorkflowExists(Spec.Id) then
      Err := Format('a workflow "%s" is already saved here: import it under another id (--as) or replace it (--replace)', [Spec.Id])
    else
      Err := Format('a workflow "%s" is already waiting for approval: import it under another id (--as) or replace it (--replace)', [Spec.Id]);
    Exit;
  end;
  R.Replaces := Taken;
  R.Missing := MissingRequirements(Spec, RequiresJSON, Cfg, ToolProbe);
  if Approve then
  begin
    if not SaveWorkflow(Spec, Err) then Exit;
    if PendingWorkflowSha(Spec.Id) <> '' then RejectPendingWorkflow(Spec.Id, Ignored);
    R.Staged := False;
  end
  else
  begin
    if not StagePendingWorkflow(Spec, Err) then Exit;
    R.Staged := True;
  end;
  Result := True;
end;

type
  TImportRedirectGuard = class
    procedure OnRedirect(var Dest: string; var Allow: Boolean; var Reason: string);
  end;

procedure TImportRedirectGuard.OnRedirect(var Dest: string; var Allow: Boolean; var Reason: string);
var
  Why: string;
begin
  Allow := True;
  if not (SameText(Copy(Dest, 1, 7), 'http://') or SameText(Copy(Dest, 1, 8), 'https://')) then
  begin
    if Copy(Dest, 1, 2) = '//' then
      if URLIsLocal('http:' + Dest, Why) then
      begin
        Allow := False;
        Reason := 'SSRF: redirect to ' + Dest + ' refused (' + Why + ')';
      end;
    Exit;
  end;
  if URLIsLocal(Dest, Why) then
  begin
    Allow := False;
    Reason := 'SSRF: redirect to ' + Dest + ' refused (' + Why + ')';
  end;
end;

function FetchWorkflowURL(const URL: string; MaxBytes: Integer;
  out Body, Err: string): Boolean;
var
  Why: string;
  G: TImportRedirectGuard;
  Resp: THTTPResult;
begin
  Result := False;
  Body := '';
  Err := '';
  if not (SameText(Copy(URL, 1, 7), 'http://') or SameText(Copy(URL, 1, 8), 'https://')) then
  begin
    Err := 'only http:// and https:// URLs can be imported';
    Exit;
  end;
  if URLIsLocal(URL, Why) then
  begin
    Err := 'SSRF: ' + URL + ' refused (' + Why + ')';
    Exit;
  end;
  G := TImportRedirectGuard.Create;
  try
    Resp := GetURL(URL, [], 30, '', 'application/json, */*', G.OnRedirect);
  finally
    G.Free;
  end;
  if Resp.ErrorMsg <> '' then begin Err := Resp.ErrorMsg; Exit; end;
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    Err := Format('%s answered HTTP %d', [URL, Resp.StatusCode]);
    Exit;
  end;
  if Length(Resp.Body) > MaxBytes then
  begin
    Err := Format('%s is larger than %d bytes', [URL, MaxBytes]);
    Exit;
  end;
  Body := Resp.Body;
  Result := True;
end;

end.
