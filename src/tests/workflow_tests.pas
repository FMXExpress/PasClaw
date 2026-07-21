program workflow_tests;
(*
  Exercises the workflow engine (PasClaw.Workflow) with an INJECTED stub tool
  caller -- no live MCP / network. Proves the core promise: a generate->upscale
  chain runs in topo order and the upscale node receives the generate node's
  structured output URL. Plus parse/validate/selector/cycle coverage, and the
  store round-trip.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Workflow,
  PasClaw.Workflow.Store,
  PasClaw.Workflow.Dispatch;

var
  Failures: Integer = 0;
  GUpscaleArgs: string = '';   { captured resolved args of the upscale node }
  GPollCount: Integer = 0;     { await test: number of poll calls }
  GLastPollArgs: string = '';  { await test: last resolved poll args }

procedure Check(Cond: Boolean; const Why: string);
begin
  if not Cond then begin WriteLn('FAIL: ', Why); Inc(Failures); end;
end;

const
  GEN_UPSCALE =
    '{"id":"gen_upscale","name":"gen_upscale","description":"gen then upscale",' +
    '"inputs":[{"name":"prompt","type":"string","required":true}],' +
    '"nodes":[' +
    '{"id":"gen","tool":"replicate__create_prediction","args":{"input":{"prompt":"{{inputs.prompt}}"}}},' +
    '{"id":"up","tool":"replicate__create_prediction","args":{"input":{"image":"{{nodes.gen.structuredContent.output[0]}}","scale":4}}}' +
    '],' +
    '"edges":[{"from":"gen","to":"up"}]}';

{ Stub caller: the generate step returns a fixed output URL; the upscale step
  (identified by an "image" arg) captures its resolved args and returns a
  second URL. Matches TWorkflowToolCallerFn. }
function StubCaller(const ToolName, ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
begin
  ResultText := '';
  ResultJSON := '';
  ErrMsg := '';
  if Pos('"image"', ArgsJSON) > 0 then
  begin
    GUpscaleArgs := ArgsJSON;
    ResultJSON := '{"structuredContent":{"output":["https://x/upscaled.png"]}}';
    ResultText := 'https://x/upscaled.png';
  end
  else
  begin
    ResultJSON := '{"structuredContent":{"output":["https://x/generated.png"]}}';
    ResultText := 'https://x/generated.png';
  end;
  Result := True;
end;

{ ToolExists probe for validation: only the replicate tool "exists". }
function ToolExistsStub(const ToolName, ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
begin
  ResultText := ''; ResultJSON := ''; ErrMsg := '';
  Result := ToolName = 'replicate__create_prediction';
end;

procedure TestParse;
var Spec: TWorkflowSpec; Err: string;
begin
  Check(ParseWorkflow(GEN_UPSCALE, Spec, Err), 'parse: succeeds (' + Err + ')');
  Check(Spec.Name = 'gen_upscale', 'parse: name');
  Check(Length(Spec.Nodes) = 2, 'parse: 2 nodes');
  Check(Length(Spec.Edges) = 1, 'parse: 1 edge');
  Check(Length(Spec.Inputs) = 1, 'parse: 1 input');
end;

procedure TestValidate;
var Spec: TWorkflowSpec; Err, Errs: string;
begin
  ParseWorkflow(GEN_UPSCALE, Spec, Err);
  Check(ValidateWorkflow(Spec, ToolExistsStub, Errs), 'validate: clean spec ok (' + Errs + ')');

  { Unknown tool -> invalid. }
  Spec.Nodes[1].Tool := 'does_not_exist';
  Check(not ValidateWorkflow(Spec, ToolExistsStub, Errs), 'validate: unknown tool rejected');
  Check(Pos('not registered', Errs) > 0, 'validate: names the missing tool');
end;

procedure TestTopoAndCycle;
var Spec: TWorkflowSpec; Err: string; Order: TStringList;
begin
  ParseWorkflow(GEN_UPSCALE, Spec, Err);
  Check(TopoOrder(Spec, Order, Err), 'topo: orders (' + Err + ')');
  Check((Order <> nil) and (Order.IndexOf('gen') < Order.IndexOf('up')),
        'topo: gen before up');
  if Order <> nil then Order.Free;

  { Inject a back-edge to force a cycle. }
  SetLength(Spec.Edges, 2);
  Spec.Edges[1].FromId := 'up';
  Spec.Edges[1].ToId := 'gen';
  Check(not TopoOrder(Spec, Order, Err), 'topo: cycle detected');
  Check(Pos('cycle', Err) > 0, 'topo: says cycle');
  if Order <> nil then Order.Free;
end;

procedure TestSelector;
var V: string;
begin
  Check(EvalSelector('{"structuredContent":{"output":["https://x/a.png"]}}',
                     'structuredContent.output[0]', V), 'selector: resolves');
  Check(V = 'https://x/a.png', 'selector: correct value (got ' + V + ')');
  Check(not EvalSelector('{"a":{}}', 'a.missing.deep', V), 'selector: missing path fails');
end;

procedure TestRunChains;
var Spec: TWorkflowSpec; Err: string; Res: TWorkflowNodeResultArray;
begin
  GUpscaleArgs := '';
  ParseWorkflow(GEN_UPSCALE, Spec, Err);
  Check(RunWorkflow(Spec, '{"prompt":"a cat"}', StubCaller, Res, Err),
        'run: succeeds (' + Err + ')');
  Check(Length(Res) = 2, 'run: two node results');
  { The core assertion: the upscale node received the generate node's URL. }
  Check(Pos('https://x/generated.png', GUpscaleArgs) > 0,
        'run: upscale args carry the generate output URL (chain works)');
  Check((Length(Res) = 2) and (Pos('upscaled.png', Res[1].JSON) > 0),
        'run: final node produced the upscaled URL');
end;

const
  AWAIT_WF =
    '{"name":"await_test","nodes":[' +
    '{"id":"gen","tool":"replicate__create_prediction","args":{},' +
     '"await":{"tool":"replicate__get","args":{"id":"{{self.id}}"},' +
              '"status_selector":"status","success":["succeeded"],"failure":["failed"],' +
              '"interval_ms":0,"timeout_ms":0}}' +
    ']}';

{ Async stub: create returns a PENDING prediction; the poll tool returns
  "processing" once, then "succeeded" with the final output. }
function AwaitStub(const ToolName, ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
begin
  ResultText := ''; ResultJSON := ''; ErrMsg := '';
  if ToolName = 'replicate__create_prediction' then
    ResultJSON := '{"id":"pred1","status":"starting"}'
  else if ToolName = 'replicate__get' then
  begin
    GLastPollArgs := ArgsJSON;
    Inc(GPollCount);
    if GPollCount >= 2 then
      ResultJSON := '{"status":"succeeded","output":["https://x/done.png"]}'
    else
      ResultJSON := '{"status":"processing"}';
  end;
  Result := True;
end;

procedure TestAwaitPolling;
var Spec: TWorkflowSpec; Err: string; Res: TWorkflowNodeResultArray;
begin
  GPollCount := 0; GLastPollArgs := '';
  Check(ParseWorkflow(AWAIT_WF, Spec, Err), 'await: parse (' + Err + ')');
  Check(Spec.Nodes[0].Await.Enabled, 'await: parsed the await block');
  Check(RunWorkflow(Spec, '{}', AwaitStub, Res, Err), 'await: run succeeds (' + Err + ')');
  Check(GPollCount >= 2, 'await: polled until terminal (>=2 polls)');
  Check(Pos('pred1', GLastPollArgs) > 0, 'await: poll args carried the pending id via self.id');
  { The node result must be the COMPLETED poll output, not the pending create. }
  Check((Length(Res) = 1) and (Pos('done.png', Res[0].JSON) > 0),
        'await: node result is the finished output');
  Check((Length(Res) = 1) and (Pos('starting', Res[0].JSON) = 0),
        'await: pending create result was replaced by the completed one');
end;

procedure TestRunMissingInput;
var Spec: TWorkflowSpec; Err: string; Res: TWorkflowNodeResultArray;
begin
  ParseWorkflow(GEN_UPSCALE, Spec, Err);
  Check(not RunWorkflow(Spec, '{}', StubCaller, Res, Err),
        'run: missing required input fails');
  Check(Pos('input', Err) > 0, 'run: error names the missing input');
end;

const
  REPLICATE_WF =
    '{"name":"repl","inputs":[{"name":"prompt","required":true}],' +
    '"nodes":[{"id":"gen","tool":"replicate",' +
      '"args":{"version":"v1","input":{"prompt":"{{inputs.prompt}}"}}}]}';

var
  GReplPoll: Integer = 0;
  GReplCreateArgs: string = '';

{ Stub the Replicate lifecycle: create_predictions returns a PENDING id, then
  get_predictions returns processing once, then succeeded with an output array. }
function ReplStub(const ToolName, ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
begin
  ResultText := ''; ResultJSON := ''; ErrMsg := '';
  { Real Replicate MCP shape (confirmed via a live run): the prediction object
    is at the TOP level of the result JSON -- id / status / output, no
    structuredContent wrapper. }
  if ToolName = 'replicate__create_predictions' then
  begin
    GReplCreateArgs := ArgsJSON;
    ResultJSON := '{"id":"p9","status":"starting","output":null}';
  end
  else if ToolName = 'replicate__get_predictions' then
  begin
    Inc(GReplPoll);
    if GReplPoll >= 2 then
      ResultJSON := '{"id":"p9","status":"succeeded","output":["https://x/final.png"]}'
    else
      ResultJSON := '{"id":"p9","status":"processing","output":null}';
  end;
  Result := True;
end;

procedure TestReplicateNode;
var Spec: TWorkflowSpec; Err: string; Res: TWorkflowNodeResultArray;
begin
  GReplPoll := 0; GReplCreateArgs := '';
  Check(ParseWorkflow(REPLICATE_WF, Spec, Err), 'replicate: parse (' + Err + ')');
  { The "replicate" node is sugar -- one node, no await/get/selector wiring. }
  Check(RunWorkflow(Spec, '{"prompt":"a horse"}', ReplStub, Res, Err),
        'replicate: run succeeds (' + Err + ')');
  Check(GReplPoll >= 2, 'replicate: auto-polled get_predictions until terminal');
  Check(Pos('a horse', GReplCreateArgs) > 0, 'replicate: create got the templated input');
  { output[0] lifted into the node text so a bare downstream node ref is the URL. }
  Check((Length(Res) = 1) and (Res[0].Text = 'https://x/final.png'),
        'replicate: node text is the finished output URL (got "' +
        Res[0].Text + '")');
end;

function AbortStub(const ToolName, ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
begin
  ResultText := ''; ResultJSON := ''; ErrMsg := '';
  if ToolName = 'replicate__create_predictions' then
    ResultJSON := '{"id":"p9","status":"starting","output":null}'
  else if ToolName = 'replicate__get_predictions' then
  begin
    Inc(GReplPoll);
    { Replicate can abort before the model starts -- a terminal state. }
    ResultJSON := '{"id":"p9","status":"aborted","output":null}';
  end;
  Result := True;
end;

{ Real Replicate MCP shape: the prediction JSON is returned as a STRING in a
  text content block -- ResultText is the payload, ResultJSON is the wrapper. }
function TextBlockStub(const ToolName, ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
begin
  ResultJSON := '{"content":[{"type":"text","text":"..."}]}';   { wrapper (no top-level id) }
  ErrMsg := '';
  if ToolName = 'replicate__create_predictions' then
    ResultText := '{"id":"p9","status":"starting","output":null}'
  else
  begin
    Inc(GReplPoll);
    if GReplPoll >= 2 then
      ResultText := '{"id":"p9","status":"succeeded","output":["https://x/tb.png"]}'
    else
      ResultText := '{"id":"p9","status":"processing","output":null}';
  end;
  Result := True;
end;

procedure TestReplicateTextBlockUnwrap;
var Spec: TWorkflowSpec; Err: string; Res: TWorkflowNodeResultArray;
begin
  GReplPoll := 0;
  ParseWorkflow('{"name":"tb","inputs":[{"name":"prompt","required":true}],' +
    '"nodes":[{"id":"gen","tool":"replicate","args":{"input":{"prompt":"{{inputs.prompt}}"}}}]}', Spec, Err);
  Check(RunWorkflow(Spec, '{"prompt":"a horse"}', TextBlockStub, Res, Err),
        'textblock: run succeeds -- {{self.id}} resolves from the text-block payload (' + Err + ')');
  Check(GReplPoll >= 2, 'textblock: polled to completion');
  Check((Length(Res) = 1) and (Res[0].Text = 'https://x/tb.png'),
        'textblock: node output is the finished URL (got "' + Res[0].Text + '")');
end;

procedure TestReplicateAbortedFailsFast;
var Spec: TWorkflowSpec; Err: string; Res: TWorkflowNodeResultArray;
begin
  GReplPoll := 0;
  ParseWorkflow('{"name":"ab","nodes":[{"id":"gen","tool":"replicate",' +
    '"args":{"input":{}}}]}', Spec, Err);
  Check(not RunWorkflow(Spec, '{}', AbortStub, Res, Err),
        'aborted: run fails');
  Check(GReplPoll <= 2, 'aborted: terminal status fails fast (no timeout spin), polls=' + IntToStr(GReplPoll));
  Check(Pos('aborted', Err) > 0, 'aborted: error names the terminal status');
end;

procedure TestRawCreateAutoPolls;
{ A raw replicate__create_predictions node (no await) must auto-poll too --
  this is the shape the agent built in the field, which returned a pending
  prediction (status starting / output null) before this fix. }
var Spec: TWorkflowSpec; Err: string; Res: TWorkflowNodeResultArray;
begin
  GReplPoll := 0;
  Check(ParseWorkflow(
    '{"name":"raw","inputs":[{"name":"prompt","required":true}],' +
    '"nodes":[{"id":"gen","tool":"replicate__create_predictions",' +
      '"args":{"input":{"prompt":"{{inputs.prompt}}"}}}]}', Spec, Err),
    'raw: parse (' + Err + ')');
  Check(RunWorkflow(Spec, '{"prompt":"a horse"}', ReplStub, Res, Err),
        'raw: run succeeds (' + Err + ')');
  Check(GReplPoll >= 2, 'raw: bare create_predictions auto-polled to completion');
  Check((Length(Res) = 1) and (Res[0].Text = 'https://x/final.png'),
        'raw: node text is the finished output (got "' + Res[0].Text + '")');
end;

procedure TestDispatchRouting;
{ WorkflowDispatch routes by name: __ -> MCP, llm -> provider, else -> registry.
  With no registry/config set, each branch returns its own clear error, which
  proves the routing decision without any network. }
var t, j, e: string;
begin
  SetWorkflowRegistry(nil);
  SetWorkflowConfig(nil);

  { llm branch -> provider layer (no config set) }
  Check(not WorkflowDispatch('llm', '{"prompt":"hi"}', t, j, e), 'dispatch: llm without config fails');
  Check(Pos('provider config', e) > 0, 'dispatch: llm routed to the provider layer');

  { MCP branch -> bridge (no servers connected) }
  Check(not WorkflowDispatch('replicate__x', '{}', t, j, e), 'dispatch: MCP name fails without servers');
  Check(Pos('MCP', e) > 0, 'dispatch: __ name routed to the MCP bridge');

  { fallthrough with no registry -> unknown-tool error }
  Check(not WorkflowDispatch('web_fetch', '{}', t, j, e), 'dispatch: unknown non-MCP tool fails w/o registry');
  Check(Pos('unknown tool', e) > 0, 'dispatch: else-branch reports unknown tool');
end;

procedure TestStoreRoundTrip;
var Spec, Loaded: TWorkflowSpec; Err: string; Sums: TWorkflowSummaryArray; i: Integer; Found: Boolean;
begin
  ParseWorkflow(GEN_UPSCALE, Spec, Err);
  Check(SaveWorkflow(Spec, Err), 'store: save (' + Err + ')');
  Check(LoadWorkflow('gen_upscale', Loaded, Err), 'store: load (' + Err + ')');
  Check(Loaded.Name = 'gen_upscale', 'store: round-trip name');
  Check(Length(Loaded.Nodes) = 2, 'store: round-trip nodes');
  Sums := ListWorkflows;
  Found := False;
  for i := 0 to High(Sums) do if Sums[i].Id = 'gen_upscale' then Found := True;
  Check(Found, 'store: list includes it');
  Check(DeleteWorkflow('gen_upscale', Err), 'store: delete');
  Check(not IsSafeWorkflowId('../etc/passwd'), 'store: rejects path traversal id');
end;

{ Declared outputs (the "Output box"): parse + round-trip + resolution. }
procedure TestOutputs;
var
  Spec: TWorkflowSpec;
  Err, OutJSON: string;
  Res: TWorkflowNodeResultArray;
begin
  Check(ParseWorkflow(
    '{"name":"wf","outputs":[{"name":"url","value":"{{nodes.gen.output[0]}}"},' +
    '{"name":"echo","value":"{{inputs.prompt}}"}],' +
    '"nodes":[{"id":"gen","tool":"x","args":{}}]}', Spec, Err),
    'outputs: parse (' + Err + ')');
  Check(Length(Spec.Outputs) = 2, 'outputs: parsed 2');
  { Survive a JSON round-trip. (Serialize to a local first -- passing
    WorkflowToJSON(Spec) directly as arg 1 while Spec is arg 3's `out` param
    aliases the record FPC zeroes on entry.) }
  OutJSON := WorkflowToJSON(Spec);
  Check(ParseWorkflow(OutJSON, Spec, Err), 'outputs: reparse (' + Err + ')');
  Check(Length(Spec.Outputs) = 2, 'outputs: survive round-trip');
  { Resolve against synthetic results + inputs. }
  SetLength(Res, 1);
  Res[0].NodeId := 'gen'; Res[0].Ok := True;
  Res[0].JSON := '{"output":["https://x/img.png"]}';
  OutJSON := ResolveWorkflowOutputs(Spec, '{"prompt":"a cat"}', Res);
  Check(Pos('https://x/img.png', OutJSON) > 0, 'outputs: node url resolved (got ' + OutJSON + ')');
  Check(Pos('a cat', OutJSON) > 0, 'outputs: input echoed (got ' + OutJSON + ')');
end;

begin
  TestParse;
  TestValidate;
  TestTopoAndCycle;
  TestSelector;
  TestRunChains;
  TestAwaitPolling;
  TestReplicateNode;
  TestReplicateTextBlockUnwrap;
  TestReplicateAbortedFailsFast;
  TestRawCreateAutoPolls;
  TestDispatchRouting;
  TestRunMissingInput;
  TestStoreRoundTrip;
  TestOutputs;

  if Failures = 0 then WriteLn('workflow_tests: OK')
  else begin WriteLn('workflow_tests: ', Failures, ' failure(s)'); Halt(1); end;
end.
