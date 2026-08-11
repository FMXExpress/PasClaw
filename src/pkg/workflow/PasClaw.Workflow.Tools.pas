(*
  PasClaw.Workflow.Tools - the agent-facing workflow tools:

    workflow_save   author/replace a workflow from a JSON spec (validated)
    workflow_list   list saved workflows
    workflow_run    run a saved workflow by name with inputs

  These let the agent BUILD a workflow ("make me a generate->upscale chain")
  and RUN it, and let cron invoke a saved chain. Nodes call MCP tools through
  the bridge's structured seam (MCPCallStructured), so one tool's real output
  feeds the next. Registered after RegisterSkills at each registry-build site,
  gated by config.workflows_enabled.
*)
unit PasClaw.Workflow.Tools;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  PasClaw.Tools.Registry,
  PasClaw.Workflow;          { TWorkflowSpec, for the exposed output seam }

{ Register workflow_save / workflow_list / workflow_run on Reg. }
procedure RegisterWorkflowTools(Reg: TToolRegistry);

{ Exposed for the unit tests: the output-writing seam takes client-supplied
  names and directories, so its refusals are contract, not detail. }
function WriteRunOutputs(const Spec: TWorkflowSpec;
  const OutputJSON, RunStamp: string; out WrittenDir, WriteErr: string): Boolean;
function SanitizeWorkflowFileName(const Name: string): string;

implementation

uses
  SysUtils, Classes,
  PasClaw.JSON,
  PasClaw.Tools.Types,
  PasClaw.Tools.Sandbox,       { ResolveWorkspacePath / PathInsideDirectory }
  PasClaw.Workflow.Store,
  PasClaw.Workflow.Dispatch;   { WorkflowDispatch -- routes MCP / llm / registry nodes }

{ An output NAME becomes a file name, and names come from client-authored
  specs -- so anything path-ish is flattened rather than trusted. }
function SanitizeWorkflowFileName(const Name: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(Name) do
    if CharInSet(Name[i], ['a'..'z', 'A'..'Z', '0'..'9', '-', '_']) then
      Result := Result + Name[i]
    else
      Result := Result + '_';
  if Result = '' then
    Result := 'output';
end;

{ Write a run's resolved outputs to disk, ComfyUI-style: results become
  files you can find, not text scrolled off a results pane.

    <workspace>/<output_dir or workflows/<id>>/<yyyymmddThhmmss>/
        output.json            always: the typed name -> value object
        <name>.txt|.md         one per output whose value is textual

  The per-run timestamped subfolder is deliberate: a re-run must never
  clobber the previous run's artifacts. URL-valued outputs stay in
  output.json as URLs -- downloading remote artifacts is its own feature,
  not smuggled in here.

  output_dir comes from CLIENTS, so it is canonicalised and refused if it
  escapes the workspace -- same posture as the store's id guard. Failure to
  write is reported in the run result but does not fail the run: the
  outputs still exist in the result JSON. }
function WriteRunOutputs(const Spec: TWorkflowSpec;
  const OutputJSON, RunStamp: string; out WrittenDir, WriteErr: string): Boolean;
var
  Rel, Base, RunDir, Name, Val, Ext: string;
  Root: TJsonObject;
  Keys: TStringList;
  i: Integer;
  SL: TStringList;
begin
  Result := False;
  WrittenDir := '';
  WriteErr := '';
  Rel := Spec.OutputDir;
  if Rel = '' then
    Rel := 'workflows/' + Spec.Id;

  Base := ResolveWorkspacePath(Rel);
  if not PathInsideDirectory(Base, ResolveWorkspacePath('.')) then
  begin
    WriteErr := 'output_dir escapes the workspace: ' + Spec.OutputDir;
    Exit;
  end;

  RunDir := IncludeTrailingPathDelimiter(Base) + RunStamp;
  try
    ForceDirectories(RunDir);
    SL := TStringList.Create;
    try
      SL.Text := OutputJSON;
      SL.SaveToFile(IncludeTrailingPathDelimiter(RunDir) + 'output.json',
        TEncoding.UTF8);
    finally
      SL.Free;
    end;

    Root := nil;
    try
      Root := TJsonObject.Parse(OutputJSON);
    except
      Root := nil;   { non-object output: output.json alone is the record }
    end;
    if Root <> nil then
    try
      Keys := Root.Keys;
      try
        for i := 0 to Keys.Count - 1 do
        begin
          Name := Keys[i];
          { only textual scalars become their own files }
          if (Root.ChildObject(Name) <> nil) or (Root.ChildArray(Name) <> nil) then
            Continue;
          Val := Root.GetStr(Name, '');
          if Val = '' then
            Continue;
          { crude but honest sniff; the authoritative copy is output.json }
          if (Pos('# ', Val) = 1) or (Pos(#10'#', Val) > 0) then
            Ext := '.md'
          else
            Ext := '.txt';
          SL := TStringList.Create;
          try
            SL.Text := Val;
            SL.SaveToFile(IncludeTrailingPathDelimiter(RunDir) +
              SanitizeWorkflowFileName(Name) + Ext, TEncoding.UTF8);
          finally
            SL.Free;
          end;
        end;
      finally
        Keys.Free;
      end;
    finally
      Root.Free;
    end;

    WrittenDir := RunDir;
    Result := True;
  except
    on E: Exception do
      WriteErr := 'output write failed: ' + E.Message;
  end;
end;

const
  SAVE_SCHEMA =
    '{"type":"object","properties":{' +
    '"name":{"type":"string","description":"workflow name; registers workflow_<name>"},' +
    '"description":{"type":"string"},' +
    '"inputs":{"type":"array","items":{"type":"object","properties":{' +
      '"name":{"type":"string"},"type":{"type":"string"},"required":{"type":"boolean"}}}},' +
    '"nodes":{"type":"array","description":"DAG nodes",' +
      '"items":{"type":"object","properties":{' +
        '"id":{"type":"string"},"tool":{"type":"string","description":"registered tool, e.g. replicate__create_prediction"},' +
        '"args":{"type":"object","description":"tool args; use {{inputs.NAME}} and {{nodes.ID.selector}} templates"}}}},' +
    '"edges":{"type":"array","items":{"type":"object","properties":{' +
      '"from":{"type":"string"},"to":{"type":"string"}}}}' +
    '},"required":["name","nodes"]}';

  RUN_SCHEMA =
    '{"type":"object","properties":{' +
    '"name":{"type":"string","description":"saved workflow name"},' +
    '"inputs":{"type":"object","description":"values for the workflow inputs"}' +
    '},"required":["name"]}';

  LIST_SCHEMA = '{"type":"object","properties":{}}';

  GET_SCHEMA =
    '{"type":"object","properties":{' +
    '"name":{"type":"string","description":"saved workflow name"}' +
    '},"required":["name"]}';

function ToolWorkflowSave(const ArgsJSON: string; out ErrMsg: string): string;
var
  Spec: TWorkflowSpec;
  Err, Errs: string;
begin
  ErrMsg := '';
  if not ParseWorkflow(ArgsJSON, Spec, Err) then
  begin ErrMsg := 'workflow_save: ' + Err; Exit(''); end;
  if not ValidateWorkflow(Spec, nil, Errs) then
  begin ErrMsg := 'workflow_save: invalid workflow:' + sLineBreak + Errs; Exit(''); end;
  if not SaveWorkflow(Spec, Err) then
  begin ErrMsg := 'workflow_save: ' + Err; Exit(''); end;
  Result := Format('saved workflow "%s" (%d node(s)) -> %s. Run it with ' +
                   'workflow_run({"name":"%s"}); read it back with workflow_get.',
                   [Spec.Name, Length(Spec.Nodes),
                    WorkflowPath(Spec.Id), Spec.Name]);
end;

function ToolWorkflowGet(const ArgsJSON: string; out ErrMsg: string): string;
var
  Args: TJsonObject;
  Name, Err: string;
  Spec: TWorkflowSpec;
begin
  ErrMsg := '';
  Name := '';
  try Args := TJsonObject.Parse(ArgsJSON); except Args := nil; end;
  if Args <> nil then
    try Name := Args.GetStr('name', ''); finally Args.Free; end;
  if Name = '' then begin ErrMsg := 'workflow_get: "name" is required'; Exit(''); end;
  if not LoadWorkflow(Name, Spec, Err) then
  begin ErrMsg := 'workflow_get: ' + Err; Exit(''); end;
  Result := WorkflowToJSON(Spec);
end;

function ToolWorkflowList(const ArgsJSON: string; out ErrMsg: string): string;
var
  Sums: TWorkflowSummaryArray;
  Root: TJsonObject;
  Arr: TJsonArray;
  O: TJsonObject;
  i: Integer;
begin
  ErrMsg := '';
  Sums := ListWorkflows;
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    for i := 0 to High(Sums) do
    begin
      O := TJsonObject.Create;
      O.PutStr('id', Sums[i].Id);
      O.PutStr('name', Sums[i].Name);
      O.PutStr('description', Sums[i].Description);
      O.PutInt('nodes', Sums[i].NodeCount);
      Arr.AddObject(O);
    end;
    Root.PutArray('workflows', Arr);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function ToolWorkflowRun(const ArgsJSON: string; out ErrMsg: string): string;
var
  Args, InputsObj, Root, O: TJsonObject;
  Name, InputsJSON, Err, OutErrs: string;
  OutJSON, OutDirWritten, OutDirErr: string;
  Spec: TWorkflowSpec;
  Res: TWorkflowNodeResultArray;
  Arr: TJsonArray;
  i: Integer;
  Ok: Boolean;
begin
  ErrMsg := '';
  Result := '';
  Name := ''; InputsJSON := '{}';
  try Args := TJsonObject.Parse(ArgsJSON); except Args := nil; end;
  if Args = nil then begin ErrMsg := 'workflow_run: bad arguments'; Exit; end;
  try
    Name := Args.GetStr('name', '');
    InputsObj := Args.ChildObject('inputs');
    if InputsObj <> nil then InputsJSON := InputsObj.ToJSON;
  finally
    Args.Free;
  end;
  if Name = '' then begin ErrMsg := 'workflow_run: "name" is required'; Exit; end;

  if not LoadWorkflow(Name, Spec, Err) then
  begin ErrMsg := 'workflow_run: ' + Err; Exit; end;

  Ok := RunWorkflowRepeated(Spec, InputsJSON, @WorkflowDispatch, Res, Err);

  Root := TJsonObject.Create;
  try
    Root.PutBool('ok', Ok);
    if not Ok then Root.PutStr('error', Err);
    Arr := TJsonArray.Create;
    for i := 0 to High(Res) do
    begin
      O := TJsonObject.Create;
      O.PutStr('node', Res[i].NodeId);
      O.PutStr('tool', Res[i].Tool);
      O.PutBool('ok', Res[i].Ok);
      if Res[i].Error <> '' then O.PutStr('error', Res[i].Error);
      if Res[i].Text  <> '' then O.PutStr('text', Res[i].Text);
      { Surface the raw result for structured-only nodes (e.g. an MCP tool that
        returns only structuredContent / an image URL, so Text is empty) --
        otherwise the model sees an "ok" node with no observable payload. }
      if (Res[i].Text = '') and (Res[i].JSON <> '') then
        O.PutRaw('result', Res[i].JSON);
      Arr.AddObject(O);
    end;
    Root.PutArray('nodes', Arr);
    { Declared outputs (the "Output box") -> a structured name -> value object,
      so the workflow reads back as a typed function result. Falls back to the
      heuristic "text of the last node that produced one" when no outputs are
      declared, so existing workflows are unchanged. Any output whose template
      does not resolve is surfaced under "output_errors" (rather than silently
      blank) so a mistyped selector is diagnosable. }
    if Length(Spec.Outputs) > 0 then
    begin
      OutJSON := ResolveWorkflowOutputs(Spec, InputsJSON, Res, OutErrs);
      Root.PutRaw('output', OutJSON);
      if OutErrs <> '' then Root.PutStr('output_errors', OutErrs);
      { the direct ask: results land in a findable workspace folder }
      if WriteRunOutputs(Spec, OutJSON,
           FormatDateTime('yyyymmdd"T"hhnnss', Now), OutDirWritten, OutDirErr) then
        Root.PutStr('output_dir', OutDirWritten)
      else if OutDirErr <> '' then
        Root.PutStr('output_dir_error', OutDirErr);
    end
    else
      for i := High(Res) downto 0 do
        if Res[i].Text <> '' then
        begin Root.PutStr('output', Res[i].Text); Break; end;
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
  if not Ok then ErrMsg := Err;   { surface failure to the loop too }
end;

procedure Reg1(Reg: TToolRegistry; const AName, ADesc, ASchema: string;
  AHandler: TToolHandler; ACat: TToolCategory);
var T: TTool;
begin
  { Set every field explicitly -- FillChar on a record with managed strings
    corrupts refcounts. }
  T.Name        := AName;
  T.Description := ADesc;
  T.Schema      := ASchema;
  T.Handler     := AHandler;
  T.HandlerObj  := nil;
  T.IsCore      := False;
  T.Category    := ACat;
  T.IsDeferred  := False;
  T.Hidden      := False;
  Reg.Register(T);
end;

procedure RegisterWorkflowTools(Reg: TToolRegistry);
begin
  if Reg = nil then Exit;
  { Let workflow nodes reach any registered tool (web_fetch, etc.), not just
    MCP + llm. Config for llm nodes is set separately by the gateway / CLI. }
  SetWorkflowRegistry(Reg);

  Reg1(Reg, 'workflow_save',
    'Author or replace a workflow: a DAG of nodes whose outputs feed the next. ' +
    'Pass the full spec (name, nodes[], edges[], optional inputs[]); it is ' +
    'saved under $PASCLAW_HOME/workspace/workflows/<name>.json and the tool ' +
    'returns the exact path. PREFER these two node types for chaining models: ' +
    '(1) tool "replicate" -- run ONE Replicate model: args {version|model, ' +
    'input:{...}}; the engine creates the prediction, polls until done, and the ' +
    'node output is the result URL (no create/get/await/selector wiring needed). ' +
    '(2) tool "llm" -- call a configured provider: args {provider, model, ' +
    'prompt}; output is the reply text. You can also use any raw MCP tool or ' +
    'registered tool as a node. Wire data between nodes with {{inputs.NAME}} ' +
    'and {{nodes.ID}} (the upstream node''s output) or {{nodes.ID.selector}} ' +
    'for a dotted/[i] path into its JSON. For a raw Replicate model node the ' +
    'output is the prediction object with fields at the TOP level -- reference ' +
    'the image/video URL as {{nodes.ID.output[0]}} (NOT structuredContent.output[0]). ' +
    'Optional "outputs":[{"name","value":"<template>"}] declares a typed result ' +
    '(workflow_run returns {name:value}). Optional "loop":{"max":N,"until":"<template>",' +
    '"feedback":[{"output","input"}]} re-runs the WHOLE DAG up to N times (hard cap ' +
    '100), feeding outputs back into inputs each pass. NOTE: every pass re-runs every ' +
    'node, so a loop over paid model nodes multiplies their cost/latency N-fold -- keep ' +
    'max small. Looping stops early only when the "until" template resolves to one of: ' +
    'true / yes / done / 1 / stop / complete (case-insensitive); author it to evaluate ' +
    'to one of those, otherwise the loop always runs to max.',
    SAVE_SCHEMA, ToolWorkflowSave, tcMutating);

  Reg1(Reg, 'workflow_list',
    'List saved workflows (id, name, description, node count). Workflows live ' +
    'under $PASCLAW_HOME/workspace/workflows/.',
    LIST_SCHEMA, ToolWorkflowList, tcReadOnly);

  Reg1(Reg, 'workflow_get',
    'Read back a saved workflow''s full JSON spec by name (use this to inspect ' +
    'or verify a workflow instead of searching the filesystem).',
    GET_SCHEMA, ToolWorkflowGet, tcReadOnly);

  Reg1(Reg, 'workflow_run',
    'Run a saved workflow by name with inputs. Returns {ok, output (the final ' +
    'result URL/text), nodes:[per-node status]}. Nodes execute in dependency ' +
    'order and pass output between each other.',
    RUN_SCHEMA, ToolWorkflowRun, tcMutating);
end;

end.
