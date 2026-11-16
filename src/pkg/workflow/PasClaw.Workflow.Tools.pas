(*
  PasClaw.Workflow.Tools - the agent-facing workflow tools:

    workflow_save   author/replace a workflow from a JSON spec (validated);
                    staged for the operator's approval unless
                    workflows_auto_approve
    workflow_list   list saved workflows
    workflow_run    run a saved workflow by name with inputs
    wf_<name>       one tool per saved workflow, its parameters the
                    workflow's inputs -- in every registry that has the
                    workflow tools, so also in PasClaw's MCP server. A live
                    source: a workflow saved, approved or deleted by any
                    process is a tool (or gone) on the next lookup, no
                    restart.

  Every run goes through the dispatch gates node by node (see
  PasClaw.Workflow.Dispatch): from an agent turn with the turn's own
  dispatcher, from anywhere else with a headless one.

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
  PasClaw.Tools.Types,       { TToolList }
  PasClaw.Tools.Registry,
  PasClaw.Workflow;          { TWorkflowSpec, for the exposed output seam }

{ Register workflow_save / workflow_list / workflow_run on Reg. }
procedure RegisterWorkflowTools(Reg: TToolRegistry);

{ The wf_<name> tools for the saved workflows right now (the live source
  RegisterWorkflowTools adds). Exposed for tests. }
function SavedWorkflowTools: TToolList;
{ wf_<id> with every character a provider rejects in a tool name made '_',
  cut to 64. }
function WorkflowToolName(const Id: string): string;

{ Exposed for the unit tests: the output-writing seam takes client-supplied
  names and directories, so its refusals are contract, not detail. }
function WriteRunOutputs(const Spec: TWorkflowSpec;
  const OutputJSON, RunStamp: string; out WrittenDir, WriteErr: string): Boolean;
function SanitizeWorkflowFileName(const Name: string): string;

implementation

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.JSON,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Tools.Sandbox,       { ResolveWorkspacePath / PathInsideDirectory }
  PasClaw.Permissions,         { TAskAnswer -- workflow_save asks the operator }
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
  i, Suffix: Integer;
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

  try
    ForceDirectories(Base);
    { The run stamp has second resolution, so two runs in the same second
      would select the SAME directory and interleave their files -- exactly
      the clobbering the per-run subfolder exists to prevent. CreateDir is
      the reservation: mkdir is atomic, it fails when the name is already
      taken, and the loser walks to -2, -3, ... until a name is its own. }
    RunDir := IncludeTrailingPathDelimiter(Base) + RunStamp;
    Suffix := 1;
    while not CreateDir(RunDir) do
    begin
      if not DirectoryExists(RunDir) then
        raise Exception.Create('cannot create run directory ' + RunDir);
      Inc(Suffix);
      if Suffix > 10000 then
        raise Exception.Create('run directory suffixes exhausted for ' + RunStamp);
      RunDir := IncludeTrailingPathDelimiter(Base) + RunStamp + '-' + IntToStr(Suffix);
    end;
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
    '"name":{"type":"string","description":"workflow name; once saved (and approved) it is also the tool wf_<name>"},' +
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

{ What the operator is asked when the agent saves a workflow: what it will
  be called, and every step with its arguments -- the thing to read before
  saying yes. Each surface shows Reason (the TUI and CLI print it, the web
  UI's card and ACP's title start with it); the web UI also draws the
  steps from the arguments. }
function WorkflowSaveQuestion(const Spec: TWorkflowSpec): string;
var
  i: Integer;
  A: string;
begin
  Result := Format('save the workflow "%s" -- it becomes the tool %s',
                   [Spec.Name, WorkflowToolName(Spec.Id)]);
  if WorkflowExists(Spec.Id) then Result := Result + ', replacing the saved one';
  Result := Result + ':';
  for i := 0 to High(Spec.Nodes) do
  begin
    A := Spec.Nodes[i].ArgsJSON;
    if Length(A) > 160 then A := Copy(A, 1, 157) + '...';
    Result := Result + sLineBreak + Format('  %d. %s: %s %s',
      [i + 1, Spec.Nodes[i].Id, Spec.Nodes[i].Tool, A]);
  end;
end;

function SavedMessage(const Spec: TWorkflowSpec; const How: string): string;
begin
  Result := Format('saved workflow "%s" (%d node(s))%s -> %s. Run it with ' +
                   '%s or workflow_run({"name":"%s"}); read it back with workflow_get.',
                   [Spec.Name, Length(Spec.Nodes), How,
                    WorkflowPath(Spec.Id), WorkflowToolName(Spec.Id), Spec.Name]);
end;

function ToolWorkflowSave(const ArgsJSON: string; out ErrMsg: string): string;
var
  Spec: TWorkflowSpec;
  Err, Errs, Ignored: string;
  Ans: TAskAnswer;
begin
  ErrMsg := '';
  if not ParseWorkflow(ArgsJSON, Spec, Err) then
  begin ErrMsg := 'workflow_save: ' + Err; Exit(''); end;
  if not ValidateWorkflow(Spec, nil, Errs) then
  begin ErrMsg := 'workflow_save: invalid workflow:' + sLineBreak + Errs; Exit(''); end;
  { The store files a spec with no id under its name; say that id below. }
  if Trim(Spec.Id) = '' then Spec.Id := Spec.Name;
  if not IsSafeWorkflowId(Spec.Id) then
  begin ErrMsg := Format('workflow_save: unsafe workflow id "%s" (use letters, digits, - _ .)', [Spec.Id]); Exit(''); end;
  { Refused by the store anyway; refuse before asking anyone about it. }
  if SameText(Spec.Id, 'pending') then
  begin ErrMsg := 'workflow_save: "pending" is reserved; name the workflow something else'; Exit(''); end;

  (* The operator says yes before what the agent wrote runs or becomes a
     tool, as with a skill it writes -- unless they turned that off. In a
     chat they are asked there and then, through the same asker an `ask`
     rule uses (the web UI's card in the chat, the TUI footer, the CLI
     prompt, the editor's dialog over ACP). Only when nobody can be asked
     -- an MCP client, an API call with no UI, a standing agent's turn, an
     ask nobody answered -- is it staged for later: `pasclaw workflow
     approve`, or the web UI's approvals list. *)
  if (WorkflowConfig <> nil) and WorkflowConfig.WorkflowsAutoApprove then
  begin
    if not SaveWorkflow(Spec, Err) then
    begin ErrMsg := 'workflow_save: ' + Err; Exit(''); end;
    Exit(SavedMessage(Spec, ''));
  end;

  Ans := aaNobody;
  if Assigned(GAskOperator) then
    Ans := GAskOperator('workflow_save', ArgsJSON, Spec.Id, WorkflowSaveQuestion(Spec));
  case Ans of
    aaAllowOnce, aaAllowSession:
      begin
        if not SaveWorkflow(Spec, Err) then
        begin ErrMsg := 'workflow_save: ' + Err; Exit(''); end;
        { A version staged earlier is superseded by the one just approved. }
        if PendingWorkflowSha(Spec.Id) <> '' then RejectPendingWorkflow(Spec.Id, Ignored);
        Result := SavedMessage(Spec, ', approved by the user');
      end;
    aaDeny:
      Result := Format('not saved: the user declined to save the workflow "%s". ' +
                       'Nothing was saved or staged. Do not save it again unchanged; ' +
                       'ask the user what they would prefer.', [Spec.Name]);
  else
    begin
      if not StagePendingWorkflow(Spec, Err) then
      begin ErrMsg := 'workflow_save: ' + Err; Exit(''); end;
      Result := Format('staged workflow "%s" (%d node(s)) for the user''s approval -- ' +
                       'no one could be asked just now. It does not run and is not a ' +
                       'tool until approved (the web UI''s approvals list, or ' +
                       '`pasclaw workflow approve %s`).',
                       [Spec.Name, Length(Spec.Nodes), Spec.Id]);
      if WorkflowExists(Spec.Id) then
        Result := Result + ' The saved version keeps running until then.';
    end;
  end;
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

{ Run Spec with InputsJSON, each node through the gates, and render the
  result. Called on the tool's dispatching thread: the turn's dispatcher is
  captured here, so a node's `ask` reaches the operator like the turn's
  own calls. Outside a turn there is none and nodes get the headless gate. }
function RunSavedWorkflow(const Spec: TWorkflowSpec; const InputsJSON: string;
  out ErrMsg: string): string;
var
  Root, O: TJsonObject;
  Err, OutErrs: string;
  OutJSON, OutDirWritten, OutDirErr: string;
  Res: TWorkflowNodeResultArray;
  Arr: TJsonArray;
  i: Integer;
  Ok: Boolean;
  Disp: IToolDispatcher;
  Saved: Pointer;
begin
  ErrMsg := '';
  Result := '';
  Disp := nil;
  if Assigned(GCaptureDispatcher) then Disp := GCaptureDispatcher();
  EnterWorkflowRun(Disp, Saved);
  try
    Ok := RunWorkflowRepeated(Spec, InputsJSON, @WorkflowDispatch, Res, Err);
  finally
    LeaveWorkflowRun(Saved);
  end;

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

function ToolWorkflowRun(const ArgsJSON: string; out ErrMsg: string): string;
var
  Args, InputsObj: TJsonObject;
  Name, InputsJSON, Err: string;
  Spec: TWorkflowSpec;
begin
  ErrMsg := '';
  Result := '';
  Name := ''; InputsJSON := '{}';
  try Args := TJsonObject.Parse(ArgsJSON); except Args := nil; end;
  if Args = nil then begin ErrMsg := 'workflow_run: bad arguments'; Exit; end;
  try
    Name := Args.GetStr('name', '');
    InputsObj := Args.ChildObject('inputs');
    if InputsObj <> nil then
    try
      InputsJSON := InputsObj.ToJSON;
    finally
      InputsObj.Free;
    end;
  finally
    Args.Free;
  end;
  if Name = '' then begin ErrMsg := 'workflow_run: "name" is required'; Exit; end;
  if not LoadWorkflow(Name, Spec, Err) then
  begin ErrMsg := 'workflow_run: ' + Err; Exit; end;
  Result := RunSavedWorkflow(Spec, InputsJSON, ErrMsg);
end;

{ ---- wf_<name>: one tool per saved workflow ---- }

type
  { Holds the workflow id a wf_ tool runs; handlers are methods, the id
    cannot ride in a plain function pointer. One per id ever seen, kept
    for the process's life (a call in flight may hold it). }
  TWfRunner = class
  public
    Id: string;
    function Run(const ArgsJSON: string; out ErrMsg: string): string;
  end;

var
  GWfLock: TCriticalSection;
  GWfRunners: TStringList;      { id -> TWfRunner, owned }
  GWfSig: string;               { the store as last listed }
  GWfTools: TToolList;          { the tools built from it }

function TWfRunner.Run(const ArgsJSON: string; out ErrMsg: string): string;
var
  Spec: TWorkflowSpec;
  Err, Inputs: string;
begin
  Result := '';
  ErrMsg := '';
  if not LoadWorkflow(Id, Spec, Err) then
  begin ErrMsg := WorkflowToolName(Id) + ': ' + Err; Exit; end;
  Inputs := Trim(ArgsJSON);
  if Inputs = '' then Inputs := '{}';
  Result := RunSavedWorkflow(Spec, Inputs, ErrMsg);
end;

function WorkflowToolName(const Id: string): string;
var
  i: Integer;
begin
  Result := 'wf_' + Id;
  for i := 1 to Length(Result) do
    if not CharInSet(Result[i], ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then
      Result[i] := '_';
  if Length(Result) > 64 then SetLength(Result, 64);
end;

function RunnerFor(const Id: string): TWfRunner;
var
  i: Integer;
begin
  i := GWfRunners.IndexOf(Id);
  if i >= 0 then Exit(TWfRunner(GWfRunners.Objects[i]));
  Result := TWfRunner.Create;
  Result.Id := Id;
  GWfRunners.AddObject(Id, Result);
end;

function JsonSchemaType(const T: string): string;
var
  L: string;
begin
  L := LowerCase(Trim(T));
  if (L = 'number') or (L = 'integer') or (L = 'boolean') or (L = 'object') or (L = 'array') then
    Result := L
  else if L = 'bool' then
    Result := 'boolean'
  else
    Result := 'string';
end;

{ Is one call a workflow makes read-only? An llm step is a provider call;
  anything else must be a registered read-only tool -- an MCP tool, another
  workflow or an unknown name counts as writing. }
function StepIsReadOnly(Reg: TToolRegistry; const Tool: string): Boolean;
var
  T: TTool;
begin
  if (Tool = 'llm') or (Tool = 'provider') then Exit(True);
  Result := (Reg <> nil) and Reg.FindStatic(Tool, T) and (T.Category = tcReadOnly);
end;

(* The tool for one saved workflow. Read-only only when the whole run is:
     - every node's tool is read-only (StepIsReadOnly);
     - so is every await's poll tool -- the engine calls it through the
       same caller, so a read-only node polling with a writing tool writes
       (Codex P1 on #648). The `replicate` sugar's synthesised poll needs
       no check here: its node names an MCP tool, mutating already;
     - it declares no outputs: a run writes those to workflows/<id>/<stamp>/
       (WriteRunOutputs), outside any node's gate (Codex P2 on #648).
   The category is what plan mode and a read-only /mcp go by. *)
function ToolForWorkflow(const Spec: TWorkflowSpec): TTool;
var
  Root, Props, P: TJsonObject;
  Req: TJsonArray;
  i: Integer;
  ReadOnly: Boolean;
  Steps: string;
  Reg: TToolRegistry;
begin
  Result := Default(TTool);
  Result.Name := WorkflowToolName(Spec.Id);
  Root := TJsonObject.Create;
  try
    Root.PutStr('type', 'object');
    Props := TJsonObject.Create;
    Req := TJsonArray.Create;
    for i := 0 to High(Spec.Inputs) do
    begin
      P := TJsonObject.Create;
      P.PutStr('type', JsonSchemaType(Spec.Inputs[i].InputType));
      Props.PutObject(Spec.Inputs[i].Name, P);
      if Spec.Inputs[i].Required then Req.AddStr(Spec.Inputs[i].Name);
    end;
    Root.PutObject('properties', Props);
    if Req.Count > 0 then Root.PutArray('required', Req) else Req.Free;
    Result.Schema := Root.ToJSON;
  finally
    Root.Free;
  end;
  ReadOnly := Length(Spec.Nodes) > 0;
  Steps := '';
  Reg := WorkflowRegistry;
  for i := 0 to High(Spec.Nodes) do
  begin
    if Steps <> '' then Steps := Steps + ' -> ';
    Steps := Steps + Spec.Nodes[i].Tool;
    if not StepIsReadOnly(Reg, Spec.Nodes[i].Tool) then ReadOnly := False;
    if Spec.Nodes[i].Await.Enabled and (Trim(Spec.Nodes[i].Await.PollTool) <> '') and
       not StepIsReadOnly(Reg, Spec.Nodes[i].Await.PollTool) then
      ReadOnly := False;
  end;
  if Length(Spec.Outputs) > 0 then ReadOnly := False;
  if ReadOnly then Result.Category := tcReadOnly else Result.Category := tcMutating;
  Result.Description := Trim(Spec.Description);
  if Result.Description = '' then Result.Description := 'Run the saved workflow "' + Spec.Name + '".';
  Result.Description := Result.Description + ' (Saved workflow "' + Spec.Name + '": ' + Steps +
    '. Each step meets the same permission rules as a direct call; returns {ok, output, nodes}.)';
  Result.HandlerObj := RunnerFor(Spec.Id).Run;
end;

{ The workflows directory as a signature: this process's store generation,
  then file names, sizes and times (another process -- `pasclaw workflow
  approve` while the gateway runs -- shows up only there). One listing per
  lookup; the tools are rebuilt only when it changes. }
function StoreSignature: string;
var
  Info: TSearchRec;
begin
  Result := IntToStr(WorkflowStoreGeneration) + '|';
  if not DirectoryExists(WorkflowsDir) then Exit;
  if FindFirst(JoinPath(WorkflowsDir, '*.json'), faAnyFile, Info) = 0 then
  try
    repeat
      if (Info.Attr and faDirectory) = 0 then
        Result := Result + Info.Name + ':' + IntToStr(Info.Size) + ':' +
                  IntToStr(Info.Time) + ';';
    until FindNext(Info) <> 0;
  finally
    FindClose(Info);
  end;
end;

function SavedWorkflowTools: TToolList;
var
  Sig, Err: string;
  Sums: TWorkflowSummaryArray;
  Spec: TWorkflowSpec;
  i, j: Integer;
  T: TTool;
  Dup: Boolean;
begin
  Sig := StoreSignature;
  GWfLock.Acquire;
  try
    if (Sig = GWfSig) and (GWfTools <> nil) then Exit(Copy(GWfTools));
    SetLength(GWfTools, 0);
    Sums := ListWorkflows;
    for i := 0 to High(Sums) do
    begin
      if not LoadWorkflow(Sums[i].Id, Spec, Err) then Continue;
      Spec.Id := Sums[i].Id;
      T := ToolForWorkflow(Spec);
      { Two ids that differ only in a character a tool name cannot hold
        would share a name: the first keeps it. }
      Dup := False;
      for j := 0 to High(GWfTools) do
        if GWfTools[j].Name = T.Name then begin Dup := True; Break; end;
      if Dup then Continue;
      SetLength(GWfTools, Length(GWfTools) + 1);
      GWfTools[High(GWfTools)] := T;
    end;
    GWfSig := Sig;
    Result := Copy(GWfTools);
  finally
    GWfLock.Release;
  end;
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
    'order and pass output between each other. Each saved workflow is also ' +
    'its own tool, wf_<name>, taking the workflow''s inputs directly.',
    RUN_SCHEMA, ToolWorkflowRun, tcMutating);

  { wf_<name> for each saved workflow, live. }
  Reg.AddDynamicSource(@SavedWorkflowTools);
end;

initialization
  GWfLock := TCriticalSection.Create;
  GWfRunners := TStringList.Create;
  GWfRunners.OwnsObjects := True;
  GWfRunners.Sorted := True;
  GWfRunners.CaseSensitive := True;

finalization
  GWfRunners.Free;
  GWfLock.Free;

end.
