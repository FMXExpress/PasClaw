(*
  PasClaw.Workflow - the workflow engine: a DAG of tool calls with typed data
  flowing along edges. Built for chaining MCP tools (e.g. Replicate
  generate -> upscale), but tool-agnostic.

  A workflow is JSON:

    {
      "id": "gen_upscale",
      "name": "gen_upscale",              // -> registers workflow_gen_upscale
      "description": "generate then upscale",
      "inputs": [ {"name":"prompt","type":"string","required":true} ],
      "nodes": [
        {"id":"gen","tool":"replicate",
         "args":{"version":"<id>","input":{"prompt":"{{inputs.prompt}}"}}},
        {"id":"up","tool":"replicate",
         "args":{"version":"<id>","input":{"image":"{{nodes.gen}}"}}}
      ],
      "edges": [ {"from":"gen","to":"up"} ]
    }

  The "replicate" node is sugar: it creates the prediction, polls until done,
  and lifts the result URL into the node's output -- so a bare {{nodes.gen}}
  downstream is the image URL, with no create/get/await/selector wiring.

  Templates in a node's args:
    {{inputs.NAME}}            - a workflow input value
    {{nodes.ID}}               - an upstream node's output (its text/URL)
    {{nodes.ID.SELECTOR}}      - a value pulled from an upstream node's raw
                                 result JSON via a dotted/[i] selector, e.g.
                                 output[0] or content[0].text

  Execution is a topological walk. Dependencies come from BOTH explicit edges
  AND {{nodes.ID..}} references, so ordering is correct even if an edge was
  omitted. Each node calls an INJECTED TWorkflowToolCaller -- production wires
  it to the MCP bridge (MCPCallStructured); tests pass a stub, so the engine is
  exercised with zero live network.
*)
unit PasClaw.Workflow;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TWorkflowInput = record
    Name: string;
    InputType: string;   { "string" | "number" | ... (advisory in v1) }
    Required: Boolean;
  end;

  { Optional poll-until-done step for async tools. Many tools (e.g. Replicate's
    create_prediction) return a PENDING handle immediately, not the final
    output. When Enabled, after the node's tool call the engine repeatedly calls
    PollTool until the status field reaches a terminal state, and the node's
    result becomes the last poll response (so downstream selectors read the
    completed output). Fully tool-agnostic -- nothing here is Replicate-specific.
    In PollArgsJSON, the self.* template kind refers to the node's own initial
    (create) result. }
  TWorkflowAwait = record
    Enabled: Boolean;
    PollTool: string;          { tool to poll, e.g. replicate__get_predictions }
    PollArgsJSON: string;      { poll args template; self.* = the create result }
    StatusSelector: string;    { dotted/[i] path to the status field in a poll result }
    Success: array of string;  { statuses that mean done }
    Failure: array of string;  { statuses that mean failed }
    IntervalMs: Integer;       { delay between polls (0 = no sleep) }
    TimeoutMs: Integer;        { give up after this much accumulated interval }
    OutputSelector: string;    { after a successful poll, extract this dotted/[i]
                                 path from the final result into the node's Text
                                 so a bare node reference downstream yields the
                                 output (non-fatal: unresolved leaves Text as-is) }
  end;

  TWorkflowNode = record
    Id: string;
    Tool: string;
    ArgsJSON: string;    { args object as a JSON string, with double-brace templates }
    Await: TWorkflowAwait;
    X, Y: Integer;       { canvas position for the editor; -1 = unset (auto-layout) }
  end;

  TWorkflowEdge = record
    FromId: string;
    ToId: string;
  end;

  TWorkflowSpec = record
    Id: string;
    Name: string;
    Description: string;
    Inputs: array of TWorkflowInput;
    Nodes: array of TWorkflowNode;
    Edges: array of TWorkflowEdge;
  end;

  { Result of running one node. }
  TWorkflowNodeResult = record
    NodeId: string;
    Tool: string;
    Ok: Boolean;
    Text: string;        { flattened tool text }
    JSON: string;        { raw result object JSON (selector source) }
    Error: string;
  end;
  TWorkflowNodeResultArray = array of TWorkflowNodeResult;

  { Injected tool invoker. Production: MCPCallStructured. Tests: a stub. }
  TWorkflowToolCaller = function(const ToolName, ArgsJSON: string;
    out ResultText, ResultJSON, ErrMsg: string): Boolean of object;

  { Plain-procedure variant so a non-method function can be injected too. }
  TWorkflowToolCallerFn = function(const ToolName, ArgsJSON: string;
    out ResultText, ResultJSON, ErrMsg: string): Boolean;

{ Parse a workflow spec from JSON. Returns False (with Err) on malformed JSON
  or a missing required field (name/nodes). }
function ParseWorkflow(const JSON: string; out Spec: TWorkflowSpec; out Err: string): Boolean;

{ Serialize back to canonical JSON (for the store). }
function WorkflowToJSON(const Spec: TWorkflowSpec): string;

{ Validate structure. ToolExists may be nil (skips the tool-existence check --
  useful before the registry is built). Returns True + empty Errors when valid;
  otherwise False and Errors holds one line per problem. }
function ValidateWorkflow(const Spec: TWorkflowSpec;
  ToolExists: TWorkflowToolCallerFn; out Errors: string): Boolean;

{ Evaluate a dotted/[i] selector against a JSON value string. Supports
  key.key, key[i], and chains (structuredContent.output[0].url). Returns the
  leaf as an unquoted string (objects/arrays come back as their JSON). False
  when the path does not resolve. }
function EvalSelector(const JSON, Selector: string; out Value: string): Boolean;

{ Normalize an MCP tool result to its payload object for selector use. MCP
  servers return a tool's data three ways: as top-level JSON, under
  structuredContent, or (Replicate) as a JSON STRING inside a text content
  block. When the flattened Text is itself a JSON object, that IS the payload,
  so return it -- otherwise id/status/output live buried in content[].text and
  selectors like self.id never resolve. Falls back to RawJSON. }
function UnwrapResult(const RawJSON, Text: string): string;

{ Resolve inputs.* / nodes.* double-brace templates in ArgsTemplate against the
  provided input values and prior node results. Missing references become an
  error (Err set, Result=False) rather than a silent empty string. }
function ResolveArgs(const ArgsTemplate, InputsJSON: string;
  const Prior: TWorkflowNodeResultArray; out Resolved, Err: string): Boolean; overload;
{ Variant that also resolves the self.* template kind against SelfJSON (a node's
  own create result), used by the await poll loop. }
function ResolveArgs(const ArgsTemplate, InputsJSON, SelfJSON: string;
  const Prior: TWorkflowNodeResultArray; out Resolved, Err: string): Boolean; overload;

{ Topologically order the node ids using edges + node-reference templates.
  False (with Err) on a cycle or an edge to an unknown node. }
function TopoOrder(const Spec: TWorkflowSpec; out Order: TStringList; out Err: string): Boolean;

{ Run the whole workflow. InputsJSON is an object of input name -> value.
  Executes nodes in topo order, resolving each node's args from prior results,
  calling Caller per node. Stops at the first node error (fail-fast). Returns
  the per-node results (in execution order) regardless; Ok is False if any node
  failed or setup errored. }
function RunWorkflow(const Spec: TWorkflowSpec; const InputsJSON: string;
  Caller: TWorkflowToolCallerFn; out Results: TWorkflowNodeResultArray;
  out Err: string): Boolean;

implementation

uses
  PasClaw.JSON;

{ ---------- parse / serialize ---------- }

procedure ParseAwait(AObj: TJsonObject; out A: TWorkflowAwait);
var SArr: TJsonArray; ArgsObj: TJsonObject; k: Integer;
begin
  A.Enabled := False;
  A.PollTool := '';
  A.PollArgsJSON := '{}';
  A.StatusSelector := 'status';
  A.IntervalMs := 2000;
  A.TimeoutMs := 300000;
  A.OutputSelector := '';
  SetLength(A.Success, 0);
  SetLength(A.Failure, 0);
  if AObj = nil then Exit;
  A.Enabled := True;
  A.PollTool := AObj.GetStr('tool', '');
  ArgsObj := AObj.ChildObject('args');
  if ArgsObj <> nil then A.PollArgsJSON := ArgsObj.ToJSON;
  A.StatusSelector := AObj.GetStr('status_selector', 'status');
  A.OutputSelector := AObj.GetStr('output_selector', '');
  A.IntervalMs := AObj.GetInt('interval_ms', 2000);
  A.TimeoutMs  := AObj.GetInt('timeout_ms', 300000);
  SArr := AObj.ChildArray('success');
  if SArr <> nil then
    for k := 0 to SArr.Count - 1 do
    begin SetLength(A.Success, Length(A.Success) + 1); A.Success[High(A.Success)] := SArr.ItemStr(k, ''); end;
  SArr := AObj.ChildArray('failure');
  if SArr <> nil then
    for k := 0 to SArr.Count - 1 do
    begin SetLength(A.Failure, Length(A.Failure) + 1); A.Failure[High(A.Failure)] := SArr.ItemStr(k, ''); end;
  if Length(A.Success) = 0 then begin SetLength(A.Success, 1); A.Success[0] := 'succeeded'; end;
  if Length(A.Failure) = 0 then begin SetLength(A.Failure, 2); A.Failure[0] := 'failed'; A.Failure[1] := 'canceled'; end;
end;

function ParseWorkflow(const JSON: string; out Spec: TWorkflowSpec; out Err: string): Boolean;
var
  Root, NObj: TJsonObject;
  NArr, EArr, IArr: TJsonArray;
  i: Integer;
  ArgsObj: TJsonObject;
begin
  Result := False;
  Err := '';
  FillChar(Spec, SizeOf(Spec), 0);
  SetLength(Spec.Inputs, 0); SetLength(Spec.Nodes, 0); SetLength(Spec.Edges, 0);
  try
    Root := TJsonObject.Parse(JSON);
  except
    on E: Exception do begin Err := 'invalid workflow JSON: ' + E.Message; Exit; end;
  end;
  if Root = nil then begin Err := 'invalid workflow JSON'; Exit; end;
  try
    Spec.Id          := Root.GetStr('id', '');
    Spec.Name        := Trim(Root.GetStr('name', ''));
    Spec.Description := Root.GetStr('description', '');
    if Spec.Id = '' then Spec.Id := Spec.Name;
    if Spec.Name = '' then begin Err := 'workflow: "name" is required'; Exit; end;

    IArr := Root.ChildArray('inputs');
    if IArr <> nil then
      for i := 0 to IArr.Count - 1 do
      begin
        NObj := IArr.ItemObject(i);
        if NObj = nil then Continue;
        SetLength(Spec.Inputs, Length(Spec.Inputs) + 1);
        Spec.Inputs[High(Spec.Inputs)].Name      := NObj.GetStr('name', '');
        Spec.Inputs[High(Spec.Inputs)].InputType := NObj.GetStr('type', 'string');
        Spec.Inputs[High(Spec.Inputs)].Required  := NObj.GetBool('required', False);
      end;

    NArr := Root.ChildArray('nodes');
    if NArr <> nil then
      for i := 0 to NArr.Count - 1 do
      begin
        NObj := NArr.ItemObject(i);
        if NObj = nil then Continue;
        SetLength(Spec.Nodes, Length(Spec.Nodes) + 1);
        Spec.Nodes[High(Spec.Nodes)].Id   := NObj.GetStr('id', '');
        Spec.Nodes[High(Spec.Nodes)].Tool := NObj.GetStr('tool', '');
        ArgsObj := NObj.ChildObject('args');
        if ArgsObj <> nil then
          Spec.Nodes[High(Spec.Nodes)].ArgsJSON := ArgsObj.ToJSON
        else
          Spec.Nodes[High(Spec.Nodes)].ArgsJSON := '{}';
        ParseAwait(NObj.ChildObject('await'), Spec.Nodes[High(Spec.Nodes)].Await);
        Spec.Nodes[High(Spec.Nodes)].X := NObj.GetInt('x', -1);
        Spec.Nodes[High(Spec.Nodes)].Y := NObj.GetInt('y', -1);
      end;

    EArr := Root.ChildArray('edges');
    if EArr <> nil then
      for i := 0 to EArr.Count - 1 do
      begin
        NObj := EArr.ItemObject(i);
        if NObj = nil then Continue;
        SetLength(Spec.Edges, Length(Spec.Edges) + 1);
        Spec.Edges[High(Spec.Edges)].FromId := NObj.GetStr('from', '');
        Spec.Edges[High(Spec.Edges)].ToId   := NObj.GetStr('to', '');
      end;

    if Length(Spec.Nodes) = 0 then begin Err := 'workflow: at least one node is required'; Exit; end;
    Result := True;
  finally
    Root.Free;
  end;
end;

function AwaitToJSON(const A: TWorkflowAwait): string;
var O: TJsonObject; SArr: TJsonArray; k: Integer;
begin
  O := TJsonObject.Create;
  try
    O.PutStr('tool', A.PollTool);
    O.PutRaw('args', A.PollArgsJSON);
    O.PutStr('status_selector', A.StatusSelector);
    if A.OutputSelector <> '' then O.PutStr('output_selector', A.OutputSelector);
    O.PutInt('interval_ms', A.IntervalMs);
    O.PutInt('timeout_ms', A.TimeoutMs);
    SArr := TJsonArray.Create;
    for k := 0 to High(A.Success) do SArr.AddStr(A.Success[k]);
    O.PutArray('success', SArr);
    SArr := TJsonArray.Create;
    for k := 0 to High(A.Failure) do SArr.AddStr(A.Failure[k]);
    O.PutArray('failure', SArr);
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function WorkflowToJSON(const Spec: TWorkflowSpec): string;
var
  Root, O: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('id', Spec.Id);
    Root.PutStr('name', Spec.Name);
    Root.PutStr('description', Spec.Description);

    Arr := TJsonArray.Create;
    for i := 0 to High(Spec.Inputs) do
    begin
      O := TJsonObject.Create;
      O.PutStr('name', Spec.Inputs[i].Name);
      O.PutStr('type', Spec.Inputs[i].InputType);
      O.PutBool('required', Spec.Inputs[i].Required);
      Arr.AddObject(O);
    end;
    Root.PutArray('inputs', Arr);

    Arr := TJsonArray.Create;
    for i := 0 to High(Spec.Nodes) do
    begin
      O := TJsonObject.Create;
      O.PutStr('id', Spec.Nodes[i].Id);
      O.PutStr('tool', Spec.Nodes[i].Tool);
      O.PutRaw('args', Spec.Nodes[i].ArgsJSON);
      if Spec.Nodes[i].Await.Enabled then
        O.PutRaw('await', AwaitToJSON(Spec.Nodes[i].Await));
      if Spec.Nodes[i].X >= 0 then O.PutInt('x', Spec.Nodes[i].X);
      if Spec.Nodes[i].Y >= 0 then O.PutInt('y', Spec.Nodes[i].Y);
      Arr.AddObject(O);
    end;
    Root.PutArray('nodes', Arr);

    Arr := TJsonArray.Create;
    for i := 0 to High(Spec.Edges) do
    begin
      O := TJsonObject.Create;
      O.PutStr('from', Spec.Edges[i].FromId);
      O.PutStr('to', Spec.Edges[i].ToId);
      Arr.AddObject(O);
    end;
    Root.PutArray('edges', Arr);

    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

{ ---------- template scanning ---------- }

{ Enumerate double-brace placeholders in S, returning the inner text of each. }
procedure ScanPlaceholders(const S: string; Out_: TStringList);
var
  i, n: Integer;
  Inner: string;
begin
  i := 1; n := Length(S);
  while i < n do
  begin
    if (S[i] = '{') and (S[i + 1] = '{') then
    begin
      Inner := '';
      Inc(i, 2);
      while (i < n) and not ((S[i] = '}') and (S[i + 1] = '}')) do
      begin
        Inner := Inner + S[i];
        Inc(i);
      end;
      if (i < n) and (S[i] = '}') and (S[i + 1] = '}') then
      begin
        Out_.Add(Trim(Inner));
        Inc(i, 2);
      end;
    end
    else
      Inc(i);
  end;
end;

{ ---------- selector eval ---------- }

{ Split a selector into accessors. "structuredContent.output[0].url" ->
  ["structuredContent","output","#0","url"] where "#N" marks an array index. }
procedure SplitSelector(const Selector: string; Out_: TStringList);
var
  i, n: Integer;
  Tok, Num: string;
begin
  i := 1; n := Length(Selector);
  Tok := '';
  while i <= n do
  begin
    case Selector[i] of
      '.':
        begin
          if Tok <> '' then begin Out_.Add(Tok); Tok := ''; end;
          Inc(i);
        end;
      '[':
        begin
          if Tok <> '' then begin Out_.Add(Tok); Tok := ''; end;
          Inc(i);
          Num := '';
          while (i <= n) and (Selector[i] <> ']') do begin Num := Num + Selector[i]; Inc(i); end;
          if (i <= n) and (Selector[i] = ']') then Inc(i);
          Out_.Add('#' + Trim(Num));
        end;
    else
      begin Tok := Tok + Selector[i]; Inc(i); end;
    end;
  end;
  if Tok <> '' then Out_.Add(Tok);
end;

function EvalSelector(const JSON, Selector: string; out Value: string): Boolean;
var
  Steps: TStringList;
  Cur: string;
  i, Idx: Integer;
  Obj: TJsonObject;
  Arr: TJsonArray;
  Child: TJsonObject;
  ChildArr: TJsonArray;
  Step, Leaf: string;
  Consumed: Boolean;
begin
  Result := False;
  Value := '';
  Steps := TStringList.Create;
  try
    SplitSelector(Selector, Steps);
    if Steps.Count = 0 then Exit;
    Cur := JSON;
    { Tolerance: agent-authored selectors (and stale examples) often lead with
      "structuredContent." even though the node output is already the unwrapped
      top-level payload -- Replicate returns id/status/output at the TOP level
      (see PlanNode + UnwrapResult), so the wrapper isn't there. If the object
      has no structuredContent key, drop that leading step and resolve the rest
      against the top level, so `structuredContent.output[0]` still finds
      `output[0]`. Only strips when absent, so builds that DO wrap are untouched. }
    if (Steps.Count >= 1) and (Steps[0] = 'structuredContent') then
    begin
      try Obj := TJsonObject.Parse(Cur); except Obj := nil; end;
      if Obj <> nil then
      try
        if not Obj.Has('structuredContent') then Steps.Delete(0);
      finally
        Obj.Free;
      end;
      if Steps.Count = 0 then Exit;
    end;
    for i := 0 to Steps.Count - 1 do
    begin
      Step := Steps[i];
      Consumed := False;
      if (Step <> '') and (Step[1] = '#') then
      begin
        { array index }
        Idx := StrToIntDef(Copy(Step, 2, MaxInt), -1);
        if Idx < 0 then Exit;
        try Arr := TJsonArray.Parse(Cur); except Arr := nil; end;
        if Arr = nil then Exit;
        try
          if Idx >= Arr.Count then Exit;
          Child := Arr.ItemObject(Idx);
          if Child <> nil then begin Cur := Child.ToJSON; Consumed := True; end
          else
          begin
            ChildArr := Arr.ItemArray(Idx);
            if ChildArr <> nil then begin Cur := ChildArr.ToJSON; Consumed := True; end
            else begin Leaf := Arr.ItemStr(Idx, #0); Cur := Leaf; Consumed := True; end;
          end;
        finally
          Arr.Free;
        end;
      end
      else
      begin
        { object key }
        try Obj := TJsonObject.Parse(Cur); except Obj := nil; end;
        if Obj = nil then Exit;
        try
          if not Obj.Has(Step) then Exit;
          Child := Obj.ChildObject(Step);
          if Child <> nil then begin Cur := Child.ToJSON; Consumed := True; end
          else
          begin
            ChildArr := Obj.ChildArray(Step);
            if ChildArr <> nil then begin Cur := ChildArr.ToJSON; Consumed := True; end
            else begin Leaf := Obj.GetStr(Step, #0); Cur := Leaf; Consumed := True; end;
          end;
        finally
          Obj.Free;
        end;
      end;
      if not Consumed then Exit;
    end;
    if Cur = #0 then Exit;   { GetStr/ItemStr sentinel for a wrong-typed scalar }
    Value := Cur;
    Result := True;
  finally
    Steps.Free;
  end;
end;

{ ---------- template resolution ---------- }

function FindNodeResult(const Prior: TWorkflowNodeResultArray; const Id: string;
  out R: TWorkflowNodeResult): Boolean;
var i: Integer;
begin
  Result := False;
  for i := 0 to High(Prior) do
    if Prior[i].NodeId = Id then
    begin R := Prior[i]; Exit(True); end;
end;

function ResolveArgs(const ArgsTemplate, InputsJSON: string;
  const Prior: TWorkflowNodeResultArray; out Resolved, Err: string): Boolean;
begin
  Result := ResolveArgs(ArgsTemplate, InputsJSON, '', Prior, Resolved, Err);
end;

function ResolveArgs(const ArgsTemplate, InputsJSON, SelfJSON: string;
  const Prior: TWorkflowNodeResultArray; out Resolved, Err: string): Boolean;
var
  Placeholders: TStringList;
  i, Dot: Integer;
  Inner, Kind, Rest, Val, NodeId, Selector: string;
  Inputs: TJsonObject;
  NR: TWorkflowNodeResult;
begin
  Result := False;
  Err := '';
  Resolved := ArgsTemplate;
  Placeholders := TStringList.Create;
  Inputs := nil;
  try
    ScanPlaceholders(ArgsTemplate, Placeholders);
    if Placeholders.Count = 0 then begin Result := True; Exit; end;

    if InputsJSON <> '' then
      try Inputs := TJsonObject.Parse(InputsJSON); except Inputs := nil; end;

    for i := 0 to Placeholders.Count - 1 do
    begin
      Inner := Placeholders[i];
      Dot := Pos('.', Inner);
      if Dot = 0 then begin Err := Format('bad template "{{%s}}"', [Inner]); Exit; end;
      Kind := Copy(Inner, 1, Dot - 1);
      Rest := Copy(Inner, Dot + 1, MaxInt);

      if Kind = 'inputs' then
      begin
        if (Inputs = nil) or (not Inputs.Has(Rest)) then
        begin Err := Format('missing input "%s" for {{%s}}', [Rest, Inner]); Exit; end;
        Val := Inputs.GetStr(Rest, '');
      end
      else if Kind = 'self' then
      begin
        if not EvalSelector(SelfJSON, Rest, Val) then
        begin Err := Format('{{%s}}: selector "%s" did not resolve in this node''s result',
                            [Inner, Rest]); Exit; end;
      end
      else if Kind = 'nodes' then
      begin
        Selector := '';
        NodeId := Rest;
        Dot := Pos('.', Rest);
        if Dot > 0 then
        begin
          NodeId   := Copy(Rest, 1, Dot - 1);
          Selector := Copy(Rest, Dot + 1, MaxInt);
        end;
        if not FindNodeResult(Prior, NodeId, NR) then
        begin Err := Format('{{%s}} references node "%s" that has not run', [Inner, NodeId]); Exit; end;
        if Selector = '' then
          Val := NR.Text
        else if not EvalSelector(NR.JSON, Selector, Val) then
        begin Err := Format('{{%s}}: selector "%s" did not resolve in node "%s" output',
                            [Inner, Selector, NodeId]); Exit; end;
      end
      else
      begin Err := Format('unknown template kind "%s" in {{%s}}', [Kind, Inner]); Exit; end;

      { Replace the literal double-brace occurrence with the JSON-escaped
        value. Placeholders sit inside JSON string literals, so escaping keeps
        the args valid JSON. }
      Resolved := StringReplace(Resolved, '{{' + Inner + '}}', JsonEscape(Val),
                                [rfReplaceAll]);
    end;
    Result := True;
  finally
    Placeholders.Free;
    Inputs.Free;
  end;
end;

{ ---------- topo order ---------- }

function NodeExists(const Spec: TWorkflowSpec; const Id: string): Boolean;
var i: Integer;
begin
  Result := False;
  for i := 0 to High(Spec.Nodes) do
    if Spec.Nodes[i].Id = Id then Exit(True);
end;

function TopoOrder(const Spec: TWorkflowSpec; out Order: TStringList; out Err: string): Boolean;
var
  n, i, j, Progress: Integer;
  Indeg: array of Integer;
  Dep: array of array of Boolean;   { Dep[a][b] = a depends on b }
  Done: array of Boolean;
  Placeholders: TStringList;
  Inner, NodeId: string;
  Dot, DepIdx: Integer;

  function IndexOfNode(const Id: string): Integer;
  var k: Integer;
  begin
    Result := -1;
    for k := 0 to High(Spec.Nodes) do
      if Spec.Nodes[k].Id = Id then Exit(k);
  end;

begin
  Result := False;
  Err := '';
  Order := TStringList.Create;
  n := Length(Spec.Nodes);
  SetLength(Dep, n, n);
  SetLength(Indeg, n);
  SetLength(Done, n);

  { edges: from -> to  means `to` depends on `from` }
  for i := 0 to High(Spec.Edges) do
  begin
    if not NodeExists(Spec, Spec.Edges[i].FromId) then
    begin Err := Format('edge from unknown node "%s"', [Spec.Edges[i].FromId]); Order.Free; Order := nil; Exit; end;
    if not NodeExists(Spec, Spec.Edges[i].ToId) then
    begin Err := Format('edge to unknown node "%s"', [Spec.Edges[i].ToId]); Order.Free; Order := nil; Exit; end;
    Dep[IndexOfNode(Spec.Edges[i].ToId)][IndexOfNode(Spec.Edges[i].FromId)] := True;
  end;

  { implicit deps from node-reference templates in each node's args }
  Placeholders := TStringList.Create;
  try
    for i := 0 to n - 1 do
    begin
      Placeholders.Clear;
      ScanPlaceholders(Spec.Nodes[i].ArgsJSON, Placeholders);
      for j := 0 to Placeholders.Count - 1 do
      begin
        Inner := Placeholders[j];
        if Copy(Inner, 1, 6) = 'nodes.' then
        begin
          NodeId := Copy(Inner, 7, MaxInt);
          Dot := Pos('.', NodeId);
          if Dot > 0 then NodeId := Copy(NodeId, 1, Dot - 1);
          DepIdx := IndexOfNode(NodeId);
          if DepIdx < 0 then
          begin Err := Format('node "%s" references unknown node "%s"', [Spec.Nodes[i].Id, NodeId]);
                Order.Free; Order := nil; Exit; end;
          if DepIdx = i then
          begin Err := Format('node "%s" references itself', [Spec.Nodes[i].Id]);
                Order.Free; Order := nil; Exit; end;
          Dep[i][DepIdx] := True;
        end;
      end;
    end;
  finally
    Placeholders.Free;
  end;

  for i := 0 to n - 1 do
  begin
    Indeg[i] := 0;
    for j := 0 to n - 1 do
      if Dep[i][j] then Inc(Indeg[i]);
  end;

  { Kahn: repeatedly emit a node with no unmet deps. }
  Progress := 0;
  while Progress < n do
  begin
    j := -1;
    for i := 0 to n - 1 do
      if (not Done[i]) and (Indeg[i] = 0) then begin j := i; Break; end;
    if j < 0 then
    begin Err := 'workflow has a cycle'; Order.Free; Order := nil; Exit; end;
    Done[j] := True;
    Order.Add(Spec.Nodes[j].Id);
    Inc(Progress);
    for i := 0 to n - 1 do
      if (not Done[i]) and Dep[i][j] then Dec(Indeg[i]);
  end;
  Result := True;
end;

{ ---------- validate ---------- }

function ValidateWorkflow(const Spec: TWorkflowSpec;
  ToolExists: TWorkflowToolCallerFn; out Errors: string): Boolean;
var
  i, j: Integer;
  Order: TStringList;
  Err, DummyT, DummyJ, DummyE, T: string;
  Errs: TStringList;
begin
  Errs := TStringList.Create;
  try
    if Trim(Spec.Name) = '' then Errs.Add('name is required');

    { unique ids, non-empty tool }
    for i := 0 to High(Spec.Nodes) do
    begin
      if Trim(Spec.Nodes[i].Id) = '' then Errs.Add(Format('node %d has an empty id', [i]));
      if Trim(Spec.Nodes[i].Tool) = '' then
        Errs.Add(Format('node "%s" has no tool', [Spec.Nodes[i].Id]));
      for j := i + 1 to High(Spec.Nodes) do
        if Spec.Nodes[i].Id = Spec.Nodes[j].Id then
          Errs.Add(Format('duplicate node id "%s"', [Spec.Nodes[i].Id]));
      { "llm" and "replicate" are reserved synthetic node types (handled by the
        dispatcher / engine), not registered tools -- don't probe them. }
      T := LowerCase(Trim(Spec.Nodes[i].Tool));
      if Assigned(ToolExists) and (T <> '') and (T <> 'llm') and (T <> 'replicate') then
        if not ToolExists(Spec.Nodes[i].Tool, '', DummyT, DummyJ, DummyE) then
          Errs.Add(Format('node "%s": tool "%s" is not registered',
                          [Spec.Nodes[i].Id, Spec.Nodes[i].Tool]));
    end;

    { DAG + reference resolution (TopoOrder validates edges + node refs) }
    if not TopoOrder(Spec, Order, Err) then
      Errs.Add(Err)
    else
      Order.Free;

    Errors := Errs.Text;
    Result := Errs.Count = 0;
  finally
    Errs.Free;
  end;
end;

{ ---------- run ---------- }

function UnwrapResult(const RawJSON, Text: string): string;
var T: string; Obj: TJsonObject;
begin
  Result := RawJSON;
  T := Trim(Text);
  { Replicate (and many MCP servers) return the payload as a JSON object string
    in a text content block, so the flattened Text IS the payload. Prefer it
    when it parses as an object -- otherwise the wrapper's top level has no
    id/status/output and selectors miss. }
  if (T <> '') and (T[1] = '{') then
  begin
    Obj := nil;
    try Obj := TJsonObject.Parse(T); except Obj := nil; end;
    if Obj <> nil then begin Obj.Free; Exit(T); end;
  end;
end;

function InStrArray(const S: string; const A: array of string): Boolean;
var k: Integer;
begin
  Result := False;
  for k := 0 to High(A) do if A[k] = S then Exit(True);
end;

{ Poll A.PollTool until StatusSelector reaches a terminal state. CreateJSON is
  the node's initial (create) result -- available in the poll args template as
  the self.* kind. On success, FinalText/FinalJSON hold the completed result so
  downstream selectors read the finished output. Elapsed time is approximated
  by accumulating IntervalMs (deterministic; no wall-clock dependency), with a
  hard poll ceiling as a backstop. }
function PollUntilDone(const A: TWorkflowAwait;
  const CreateJSON, InputsJSON: string; const Prior: TWorkflowNodeResultArray;
  Caller: TWorkflowToolCallerFn; out FinalText, FinalJSON, Err: string): Boolean;
const
  MAX_POLLS = 100000;
var
  PollArgs, PText, PJSON, CErr, Status: string;
  Elapsed, Polls: Integer;
begin
  Result := False;
  FinalText := ''; FinalJSON := ''; Err := '';
  Elapsed := 0; Polls := 0;
  if Trim(A.PollTool) = '' then begin Err := 'await: no poll tool'; Exit; end;
  while True do
  begin
    if not ResolveArgs(A.PollArgsJSON, InputsJSON, CreateJSON, Prior, PollArgs, Err) then Exit;
    if not Caller(A.PollTool, PollArgs, PText, PJSON, CErr) then
    begin Err := 'await: poll call failed: ' + CErr; Exit; end;
    PJSON := UnwrapResult(PJSON, PText);   { reach into a text-block payload }
    if not EvalSelector(PJSON, A.StatusSelector, Status) then
    begin Err := Format('await: status selector "%s" did not resolve in poll result', [A.StatusSelector]); Exit; end;
    if InStrArray(Status, A.Success) then
    begin FinalText := PText; FinalJSON := PJSON; Exit(True); end;
    if InStrArray(Status, A.Failure) then
    begin FinalText := PText; FinalJSON := PJSON;
          Err := Format('await: terminal failure status "%s"', [Status]); Exit; end;
    Inc(Polls);
    if A.IntervalMs > 0 then Inc(Elapsed, A.IntervalMs);
    if (A.TimeoutMs > 0) and (Elapsed >= A.TimeoutMs) then
    begin Err := Format('await: timed out after %d ms (last status "%s")', [Elapsed, Status]); Exit; end;
    if Polls >= MAX_POLLS then begin Err := 'await: exceeded max polls'; Exit; end;
    if A.IntervalMs > 0 then Sleep(A.IntervalMs);
  end;
end;

procedure PlanNode(const Node: TWorkflowNode; out EffTool: string; out Aw: TWorkflowAwait);
{ Resolve a node's effective execution tool + await plan. A node whose tool is
  the reserved word "replicate" is sugar for "run a Replicate model": it expands
  to create_predictions + an auto-poll of get_predictions until terminal + an
  output_selector, so the author writes one node carrying the create args
  (version/model + input) instead of hand-wiring create + get + await +
  selectors. An explicit await on the node overrides the synthesized one. All
  the Replicate names/paths are defaults here -- override per-node if a build
  differs. }
var
  T: string;
begin
  EffTool := Node.Tool;
  Aw := Node.Await;
  T := LowerCase(Trim(Node.Tool));
  if T = 'replicate' then EffTool := 'replicate__create_predictions';
  { Both the "replicate" sugar node AND a raw replicate__create_predictions node
    kick off an ASYNC prediction that returns immediately with status "starting"
    and output null. Chaining that pending handle is never what's wanted, so
    auto-poll to completion unless the author set an explicit await. }
  if ((T = 'replicate') or (T = 'replicate__create_predictions')) and (not Aw.Enabled) then
  begin
    Aw.Enabled        := True;
    Aw.PollTool       := 'replicate__get_predictions';
    { Confirmed against the live Replicate MCP: create/get return the prediction
      object with id / status / output at the TOP level of the result JSON (not
      wrapped in structuredContent). Select there. Override via an explicit
      await block if a different MCP build wraps the fields. }
    Aw.PollArgsJSON   := '{"prediction_id":"{{self.id}}"}';
    Aw.StatusSelector := 'status';
    Aw.OutputSelector := 'output[0]';   { image models return output: [url] }
    Aw.IntervalMs     := 2000;
    Aw.TimeoutMs      := 300000;
    SetLength(Aw.Success, 1); Aw.Success[0] := 'succeeded';
    { Replicate terminal-failure states: failed, canceled, and aborted (fail
      fast on any of them rather than polling to the timeout). }
    SetLength(Aw.Failure, 3);
    Aw.Failure[0] := 'failed'; Aw.Failure[1] := 'canceled'; Aw.Failure[2] := 'aborted';
  end;
end;

function RunWorkflow(const Spec: TWorkflowSpec; const InputsJSON: string;
  Caller: TWorkflowToolCallerFn; out Results: TWorkflowNodeResultArray;
  out Err: string): Boolean;
var
  Order: TStringList;
  i, ni: Integer;
  NodeArgs, ResolvedArgs, Text, JSON, CallErr: string;
  CreateJSON, FinalText, FinalJSON, EffTool, OutVal: string;
  Aw: TWorkflowAwait;
  NR: TWorkflowNodeResult;

  function NodeIndex(const Id: string): Integer;
  var k: Integer;
  begin
    Result := -1;
    for k := 0 to High(Spec.Nodes) do
      if Spec.Nodes[k].Id = Id then Exit(k);
  end;

begin
  Result := False;
  Err := '';
  SetLength(Results, 0);
  if not Assigned(Caller) then begin Err := 'no tool caller provided'; Exit; end;

  if not TopoOrder(Spec, Order, Err) then Exit;
  try
    for i := 0 to Order.Count - 1 do
    begin
      ni := NodeIndex(Order[i]);
      NodeArgs := Spec.Nodes[ni].ArgsJSON;

      if not ResolveArgs(NodeArgs, InputsJSON, Results, ResolvedArgs, CallErr) then
      begin
        Err := Format('node "%s": %s', [Spec.Nodes[ni].Id, CallErr]);
        Exit;
      end;

      PlanNode(Spec.Nodes[ni], EffTool, Aw);

      Text := ''; JSON := ''; CallErr := '';
      NR.NodeId := Spec.Nodes[ni].Id;
      NR.Tool   := Spec.Nodes[ni].Tool;   { report the authored tool (e.g. "replicate") }
      NR.Ok     := Caller(EffTool, ResolvedArgs, Text, JSON, CallErr);
      NR.Text   := Text;
      { Normalize a text-block payload so downstream node selectors and the
        poll's self.id select against the actual object, not the wrapper. }
      JSON      := UnwrapResult(JSON, Text);
      NR.JSON   := JSON;
      NR.Error  := CallErr;

      { Async tools return a pending handle; poll until terminal so the node's
        stored result is the COMPLETED output that downstream nodes select on. }
      if NR.Ok and Aw.Enabled then
      begin
        CreateJSON := JSON;   { unwrapped create result -- self.id resolves }
        if PollUntilDone(Aw, CreateJSON, InputsJSON, Results,
                         Caller, FinalText, FinalJSON, CallErr) then
        begin
          NR.Ok := True; NR.Text := FinalText; NR.JSON := FinalJSON; NR.Error := '';
          { Lift the completed output into Text so a bare node reference
            downstream works. Non-fatal: unresolved leaves the poll text. }
          if Aw.OutputSelector <> '' then
            if EvalSelector(FinalJSON, Aw.OutputSelector, OutVal) then NR.Text := OutVal;
        end
        else
        begin NR.Ok := False; NR.Error := CallErr; NR.Text := FinalText; NR.JSON := FinalJSON; end;
      end;

      SetLength(Results, Length(Results) + 1);
      Results[High(Results)] := NR;

      if not NR.Ok then
      begin
        Err := Format('node "%s" (%s) failed: %s',
                      [NR.NodeId, NR.Tool, NR.Error]);
        Exit;
      end;
    end;
    Result := True;
  finally
    Order.Free;
  end;
end;

end.
