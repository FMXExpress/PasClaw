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
  PasClaw.Utils,           { GetHome / JoinPath -- to pin the test workspace }
  PasClaw.Config,          { TSandboxPolicy }
  PasClaw.Tools.Sandbox,   { ConfigureSandbox }
  PasClaw.Workflow,
  PasClaw.Workflow.Store,
  PasClaw.Workflow.Tools,
  PasClaw.Workflow.Dispatch;

var
  Failures: Integer = 0;
  GUpscaleArgs: string = '';   { captured resolved args of the upscale node }
  GPollCount: Integer = 0;     { await test: number of poll calls }
  GLastPollArgs: string = '';  { await test: last resolved poll args }
  GLoopCount: Integer = 0;     { loop test: number of DAG passes }
  GUntilCount: Integer = 0;    { until-loop test: number of DAG passes }

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
  { Tolerance: a stale "structuredContent." prefix resolves against the
    unwrapped top-level payload (agent-authored Replicate selectors). }
  Check(EvalSelector('{"output":["https://x/b.png"]}',
                     'structuredContent.output[0]', V), 'selector: tolerates stale structuredContent prefix');
  Check(V = 'https://x/b.png', 'selector: stale-prefix correct value (got ' + V + ')');
  { But a real structuredContent wrapper is still honoured (not stripped). }
  Check(EvalSelector('{"structuredContent":{"output":["https://x/c.png"]}}',
                     'structuredContent.output[0]', V), 'selector: real wrapper still works');
  Check(V = 'https://x/c.png', 'selector: real-wrapper value (got ' + V + ')');
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

{ The store REBUILDS the document from the typed spec (SaveWorkflow ->
  WorkflowToJSON), so anything the parser drops is erased on every save.
  That bit the editors' layout state once (Codex P1 on PR #513): pan and
  IN/OUT positions saved under "ui" vanished on the next gateway round trip.
  Pin the full editor payload -- ui, output_dir, node x/y -- through the
  actual save/load seam, not just the serializer pair. }
procedure TestEditorStateRoundTrip;
const
  WF_WITH_UI =
    '{"id":"uiwf","name":"uiwf","output_dir":"art/renders",' +
    '"ui":{"pan_x":-120,"pan_y":40,"in_x":8,"in_y":200,"out_x":640,"out_y":200},' +
    '"nodes":[{"id":"gen","tool":"x","args":{},"x":260,"y":140}]}';
var
  Spec, Loaded: TWorkflowSpec;
  Err: string;
begin
  Check(ParseWorkflow(WF_WITH_UI, Spec, Err), 'ui: parse (' + Err + ')');
  Check(Spec.UiJSON <> '', 'ui: parser carries the ui object');
  Check(Spec.OutputDir = 'art/renders', 'ui: output_dir parsed');
  Check(SaveWorkflow(Spec, Err), 'ui: save (' + Err + ')');
  Check(LoadWorkflow('uiwf', Loaded, Err), 'ui: load (' + Err + ')');
  Check(Pos('"pan_x"', Loaded.UiJSON) > 0, 'ui: pan survives the store round trip');
  Check(Pos('"in_x"', Loaded.UiJSON) > 0, 'ui: IO positions survive the store round trip');
  Check(Loaded.OutputDir = 'art/renders', 'ui: output_dir survives the store round trip');
  Check((Length(Loaded.Nodes) = 1) and (Loaded.Nodes[0].X = 260) and (Loaded.Nodes[0].Y = 140),
        'ui: node x/y survive the store round trip');
  { a spec with NO editor state must not grow the keys }
  Check(Pos('"ui"', WorkflowToJSON(Loaded)) > 0, 'ui: serializer emits ui when present');
  DeleteWorkflow('uiwf', Err);
  Check(ParseWorkflow('{"name":"plain","nodes":[{"id":"a","tool":"x","args":{}}]}', Spec, Err),
        'ui: plain parse (' + Err + ')');
  Check(Pos('"ui"', WorkflowToJSON(Spec)) = 0, 'ui: absent state writes no ui key');
  Check(Pos('"output_dir"', WorkflowToJSON(Spec)) = 0, 'ui: absent output_dir writes no key');
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

{ Loop stub: an "echo" node that appends "!" to its resolved "v" arg, so the
  value grows one bang per pass when the output is fed back into the input. }
function LoopStub(const ToolName, ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
var p, q: Integer; s, v: string;
begin
  ResultText := ''; ResultJSON := '{}'; ErrMsg := '';
  Inc(GLoopCount);
  { args are a one-field object with a string value (spacing varies) -- grab the
    quoted value after the colon; the value never contains a quote here. }
  v := '';
  p := Pos(':', ArgsJSON);
  if p > 0 then
  begin
    s := Copy(ArgsJSON, p + 1, MaxInt);
    p := Pos('"', s);
    if p > 0 then
    begin
      s := Copy(s, p + 1, MaxInt);
      q := Pos('"', s);
      if q > 0 then v := Copy(s, 1, q - 1);
    end;
  end;
  ResultText := v + '!';
  Result := True;
end;

{ Bounded looping (Phase 3): max cap, feedback output->input, JSON round-trip. }
procedure TestLoop;
const
  LOOP_WF =
    '{"name":"loopwf","inputs":[{"name":"x"}],' +
    '"outputs":[{"name":"out","value":"{{nodes.step}}"}],' +
    '"nodes":[{"id":"step","tool":"echo","args":{"v":"{{inputs.x}}"}}],' +
    '"loop":{"max":3,"feedback":[{"output":"out","input":"x"}]}}';
var
  Spec, Spec2: TWorkflowSpec;
  Err, SJSON: string;
  Res: TWorkflowNodeResultArray;
begin
  GLoopCount := 0;
  Check(ParseWorkflow(LOOP_WF, Spec, Err), 'loop: parse (' + Err + ')');
  Check(Spec.Loop.Enabled, 'loop: enabled parsed');
  Check(Spec.Loop.MaxIterations = 3, 'loop: max parsed');
  Check((Length(Spec.Loop.Feedback) = 1) and (Spec.Loop.Feedback[0].OutputName = 'out')
        and (Spec.Loop.Feedback[0].InputName = 'x'), 'loop: feedback parsed');
  Check(RunWorkflowRepeated(Spec, '{"x":"a"}', LoopStub, Res, Err), 'loop: runs (' + Err + ')');
  Check(GLoopCount = 3, 'loop: ran max passes (got ' + IntToStr(GLoopCount) + ')');
  { a -> a! -> a!! -> a!!! as the output feeds back into x each pass. }
  Check((Length(Res) = 1) and (Res[0].Text = 'a!!!'),
        'loop: feedback accumulated (got ' + Res[0].Text + ')');
  { Loop block survives a JSON round-trip. }
  SJSON := WorkflowToJSON(Spec);
  Check(ParseWorkflow(SJSON, Spec2, Err) and Spec2.Loop.Enabled, 'loop: survives round-trip');
end;

{ until-loop stub: returns "go" until the 2nd pass, then "done" -- so a loop
  whose "until" reads this node's text stops early (at pass 2) rather than
  running to max. }
function UntilStub(const ToolName, ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
begin
  ResultJSON := '{}'; ErrMsg := '';
  Inc(GUntilCount);
  if GUntilCount >= 2 then ResultText := 'done' else ResultText := 'go';
  Result := True;
end;

{ Loop stops early when the until-condition resolves to an affirmative marker,
  well before the max cap. }
procedure TestLoopUntil;
const
  UNTIL_WF =
    '{"name":"untilwf","inputs":[{"name":"x"}],' +
    '"outputs":[{"name":"out","value":"{{nodes.step}}"}],' +
    '"nodes":[{"id":"step","tool":"echo","args":{"v":"{{inputs.x}}"}}],' +
    '"loop":{"max":10,"until":"{{nodes.step}}","feedback":[{"output":"out","input":"x"}]}}';
var
  Spec: TWorkflowSpec;
  Err: string;
  Res: TWorkflowNodeResultArray;
begin
  GUntilCount := 0;
  Check(ParseWorkflow(UNTIL_WF, Spec, Err), 'until: parse (' + Err + ')');
  Check(Spec.Loop.UntilTemplate <> '', 'until: template parsed');
  Check(RunWorkflowRepeated(Spec, '{"x":"a"}', UntilStub, Res, Err), 'until: runs (' + Err + ')');
  { pass 1 -> "go" (continue), pass 2 -> "done" (until satisfied -> stop). }
  Check(GUntilCount = 2, 'until: stopped early, not at max (got ' + IntToStr(GUntilCount) + ')');
end;

{ Without this, ResolveWorkspacePath falls back to the process CWD and the
  output-writing test litters run directories into whatever folder the tests
  were launched from -- which turned out to be the repo checkout. Pin the
  sandbox workspace to the same isolated home the store uses ($PASCLAW_HOME,
  set by `make test-workflow`). }
procedure PinWorkspaceToTestHome;
var
  Pol: TSandboxPolicy;
  WS: string;
begin
  Pol.RestrictToWorkspace       := False;
  Pol.AllowReadOutsideWorkspace := True;
  Pol.Workspace                 := '';
  SetLength(Pol.AllowReadPaths, 0);
  SetLength(Pol.AllowWritePaths, 0);
  SetLength(Pol.CustomShellDeny, 0);
  Pol.ShellDenyEnabled          := False;
  Pol.BlockPrivateNetworks      := False;
  WS := JoinPath(GetHome, 'workspace');
  ForceDirectories(WS);
  ConfigureSandbox(Pol, WS);
end;

{ ---- output writing: refusals are the contract ---------------------------- }
procedure TestOutputWriting;
var
  Spec: TWorkflowSpec;
  Dir, Dir2, Err: string;
  SL: TStringList;
  SR: TSearchRec;
  Found: Boolean;
begin
  FillChar(Spec, SizeOf(Spec), 0);
  Spec.Id := 'wf-out-test';
  Spec.OutputDir := '';

  { default dir: workflows/<id>/<stamp>, output.json + per-output text file }
  Check(WriteRunOutputs(Spec, '{"story":"once upon a time","n":"42"}',
    '20260811T000000', Dir, Err), 'default output dir writes: ' + Err);
  Check(FileExists(IncludeTrailingPathDelimiter(Dir) + 'output.json'),
    'output.json exists');
  Check(FileExists(IncludeTrailingPathDelimiter(Dir) + 'story.txt'),
    'textual output becomes its own file');
  Check(Pos('workflows', Dir) > 0, 'default lands under workflows/');

  { a second run must not clobber the first }
  Check(WriteRunOutputs(Spec, '{"story":"again"}', '20260811T000001', Dir, Err),
    'second run writes');
  Check(FileExists(IncludeTrailingPathDelimiter(Dir) + 'output.json'),
    'second run has its own folder');

  { the stamp has second resolution, so two runs CAN share one -- each must
    still get its own directory (Codex P2: same-second runs interleaved) }
  Check(WriteRunOutputs(Spec, '{"story":"first"}', '20260811T111111', Dir, Err),
    'same-stamp run 1 writes: ' + Err);
  Check(WriteRunOutputs(Spec, '{"story":"second"}', '20260811T111111', Dir2, Err),
    'same-stamp run 2 writes: ' + Err);
  Check(Dir <> Dir2, 'same-stamp runs land in distinct dirs (' + Dir2 + ')');
  Check(Pos('20260811T111111', Dir2) > 0, 'collision dir keeps the stamp prefix');
  SL := TStringList.Create;
  try
    SL.LoadFromFile(IncludeTrailingPathDelimiter(Dir) + 'story.txt');
    Check(Pos('first', SL.Text) > 0, 'first same-stamp run not clobbered');
  finally
    SL.Free;
  end;

  { end to end: an output NAMED like a traversal must land INSIDE the run
    dir -- the sanitizer at the write site is the guard, so prove it there,
    not only as a string property }
  Check(WriteRunOutputs(Spec, '{"../../hostile":"gotcha"}',
    '20260811T000003', Dir, Err), 'hostile-named output run writes: ' + Err);
  Check(not FileExists(ExpandFileName(IncludeTrailingPathDelimiter(Dir) +
    '../../hostile.txt')), 'no file escaped the run dir');
  Found := False;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.txt', faAnyFile, SR) = 0 then
  begin
    repeat
      if Pos('hostile', SR.Name) > 0 then Found := True;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  Check(Found, 'hostile name flattened into a file inside the run dir');

  { hostile output_dir refused }
  Spec.OutputDir := '../../outside';
  Check(not WriteRunOutputs(Spec, '{"a":"b"}', '20260811T000002', Dir, Err),
    'traversal refused');
  Check(Pos('escapes', Err) > 0, 'refusal names the reason');

  { hostile output NAME flattened, not trusted }
  { assert the PROPERTIES, not an exact string: what matters is that no
    path separator or dot survives, not the underscore count }
  Check((Pos('/', SanitizeWorkflowFileName('../../etc/passwd')) = 0) and
        (Pos('.', SanitizeWorkflowFileName('../../etc/passwd')) = 0) and
        (Pos('\\', SanitizeWorkflowFileName('..\\evil')) = 0),
    'path-ish output name flattened');
  Check(SanitizeWorkflowFileName('') = 'output', 'empty name gets a default');
end;

begin
  PinWorkspaceToTestHome;
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
  TestEditorStateRoundTrip;
  TestOutputs;
  TestLoop;
  TestLoopUntil;
  TestOutputWriting;

  if Failures = 0 then WriteLn('workflow_tests: OK')
  else 

begin WriteLn('workflow_tests: ', Failures, ' failure(s)'); Halt(1); end;
end.
