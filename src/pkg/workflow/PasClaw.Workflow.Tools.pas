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
  PasClaw.Tools.Registry;

{ Register workflow_save / workflow_list / workflow_run on Reg. }
procedure RegisterWorkflowTools(Reg: TToolRegistry);

implementation

uses
  SysUtils,
  PasClaw.JSON,
  PasClaw.Tools.Types,
  PasClaw.Workflow,
  PasClaw.Workflow.Store,
  PasClaw.Workflow.Dispatch;   { WorkflowDispatch -- routes MCP / llm / registry nodes }

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
  Result := Format('saved workflow "%s" (%d node(s)). Run it with workflow_run.',
                   [Spec.Name, Length(Spec.Nodes)]);
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
  Name, InputsJSON, Err: string;
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

  Ok := RunWorkflow(Spec, InputsJSON, @WorkflowDispatch, Res, Err);

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
      Arr.AddObject(O);
    end;
    Root.PutArray('nodes', Arr);
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
    'Author or replace a workflow: a DAG of tool calls whose outputs feed the ' +
    'next node. Pass the full spec (name, nodes[], edges[], optional inputs[]). ' +
    'A node''s "tool" is an MCP tool (e.g. replicate__create_prediction), the ' +
    'special "llm" node which calls a configured provider with ' +
    'args {provider, model, prompt} and returns its text, or any other ' +
    'registered tool. Wire data with {{inputs.NAME}} and ' +
    '{{nodes.ID.selector}} templates in a node''s args, where selector is a ' +
    'dotted/[i] path into the upstream tool''s JSON result (e.g. ' +
    'structuredContent.output[0]). For an ASYNC tool that returns a pending ' +
    'handle (e.g. Replicate create_prediction), add an "await" block to the ' +
    'node: {tool, args (use {{self.SELECTOR}} for the create result, e.g. ' +
    '{{self.id}}), status_selector, success[], failure[], interval_ms, ' +
    'timeout_ms} -- the engine polls until a terminal status and the node''s ' +
    'result becomes the completed output.',
    SAVE_SCHEMA, ToolWorkflowSave, tcMutating);

  Reg1(Reg, 'workflow_list',
    'List saved workflows (id, name, description, node count).',
    LIST_SCHEMA, ToolWorkflowList, tcReadOnly);

  Reg1(Reg, 'workflow_run',
    'Run a saved workflow by name with inputs; returns per-node status. Nodes ' +
    'execute in dependency order and pass structured output between each other.',
    RUN_SCHEMA, ToolWorkflowRun, tcMutating);
end;

end.
