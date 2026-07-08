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
  PasClaw.Workflow.Store;

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

begin
  TestParse;
  TestValidate;
  TestTopoAndCycle;
  TestSelector;
  TestRunChains;
  TestAwaitPolling;
  TestRunMissingInput;
  TestStoreRoundTrip;

  if Failures = 0 then WriteLn('workflow_tests: OK')
  else begin WriteLn('workflow_tests: ', Failures, ' failure(s)'); Halt(1); end;
end.
