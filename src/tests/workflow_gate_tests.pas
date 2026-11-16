program workflow_gate_tests;
(*
  Workflows meet the gates, are tools, and wait for approval.

  1. Every node goes through the same gates a direct call does: a deny rule
     stops a registry node and an MCP node; an `ask` with nobody to ask is
     refused; plan mode refuses a mutating node; a BeforeToolCall hook can
     cancel one; a refused node fails the run instead of feeding its refusal
     to the next node; and with no gate at all a node does not run.
  2. Each saved workflow is the tool wf_<id> -- with its inputs as the
     schema, read-only only when every step is -- appearing and disappearing
     as the store changes, with no re-registration, in the registry and in
     an MCP server's tools/list; tools/call runs it.
  3. workflow_save stages what the agent writes; approve (checked against the
     sha256 the operator read) makes it a workflow and a tool; reject drops
     it; workflows_auto_approve skips the step; the file tools cannot write
     a spec or a staged spec directly.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.JSON,
  PasClaw.Providers.Types,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.Sandbox,
  PasClaw.Tools.ToolLoop,
  PasClaw.Permissions,
  PasClaw.Agent.Mode,
  PasClaw.Agent.Hooks,
  PasClaw.MCP.Server,
  PasClaw.Workflow,
  PasClaw.Workflow.Store,
  PasClaw.Workflow.Tools,
  PasClaw.Workflow.Dispatch;

var
  Failures: Integer = 0;
  GReadCalls: Integer = 0;
  GWriteCalls: Integer = 0;
  GAsked: Integer = 0;
  GLastReadArgs: string = '';
  GLastAskTool, GLastAskResource, GLastAskReason: string;
  Reg: TToolRegistry;
  Cfg: TConfig;

procedure Check(Cond: Boolean; const Why: string);
begin
  if not Cond then begin WriteLn('FAIL: ', Why); Inc(Failures); end;
end;

function ToolRead(const ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := '';
  Inc(GReadCalls);
  GLastReadArgs := ArgsJSON;
  Result := 'read:' + ArgsJSON;
end;

function ToolWrite(const ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := '';
  Inc(GWriteCalls);
  Result := 'wrote';
end;

procedure Add(const AName: string; AHandler: TToolHandler; ACat: TToolCategory);
var
  T: TTool;
begin
  T := Default(TTool);
  T.Name := AName;
  T.Description := 'test tool ' + AName;
  T.Schema := '{"type":"object","properties":{}}';
  T.Handler := AHandler;
  T.Category := ACat;
  Reg.Register(T);
end;

procedure Rules(const JSON: string);
begin
  SetPermissionRules(ParsePermissionRules(JSON, 'test'));
end;

type
  TAsker = class
    Answer: TAskAnswer;
    function Ask(const ToolName, ArgsJSON, Resource, Reason: string): TAskAnswer;
  end;

  TCancelWrites = class(TPasClawHook)
  public
    procedure BeforeToolCall(const ToolCall: TToolCall; var Cancel: Boolean;
                             var SyntheticResult: string); override;
  end;

function TAsker.Ask(const ToolName, ArgsJSON, Resource, Reason: string): TAskAnswer;
begin
  Inc(GAsked);
  GLastAskTool := ToolName;
  GLastAskResource := Resource;
  GLastAskReason := Reason;
  Result := Answer;
end;

procedure TCancelWrites.BeforeToolCall(const ToolCall: TToolCall; var Cancel: Boolean;
  var SyntheticResult: string);
begin
  if ToolCall.Func.Name = 't_write' then
  begin
    Cancel := True;
    SyntheticResult := 'hook said no';
  end;
end;

const
  { read, then write fed from the read }
  READ_WRITE =
    '{"id":"rw","name":"rw","nodes":[' +
    '{"id":"a","tool":"t_read","args":{"q":"{{inputs.q}}"}},' +
    '{"id":"b","tool":"t_write","args":{"x":"{{nodes.a}}"}},' +
    '{"id":"c","tool":"t_read","args":{"y":"{{nodes.b}}"}}],' +
    '"edges":[{"from":"a","to":"b"},{"from":"b","to":"c"}],' +
    '"inputs":[{"name":"q","type":"string","required":true}]}';

function Spec(const JSON: string): TWorkflowSpec;
var
  Err: string;
begin
  if not ParseWorkflow(JSON, Result, Err) then
    WriteLn('FAIL: test spec does not parse: ', Err);
end;

{ Run READ_WRITE through whatever dispatcher is entered (nil = headless). }
function RunRW(const Disp: IToolDispatcher; out Res: TWorkflowNodeResultArray;
  out Err: string): Boolean;
var
  Saved: Pointer;
begin
  EnterWorkflowRun(Disp, Saved);
  try
    Result := RunWorkflow(Spec(READ_WRITE), '{"q":"hi"}', @WorkflowDispatch, Res, Err);
  finally
    LeaveWorkflowRun(Saved);
  end;
end;

function NodeErr(const Res: TWorkflowNodeResultArray; const Id: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Res) do
    if Res[i].NodeId = Id then Exit(Res[i].Error);
end;

procedure ResetCounts;
begin
  GReadCalls := 0;
  GWriteCalls := 0;
  GAsked := 0;
end;

procedure TestHeadlessGates;
var
  Res: TWorkflowNodeResultArray;
  Err: string;
begin
  { No rules: everything runs. }
  Rules('[]');
  ResetCounts;
  Check(RunRW(nil, Res, Err), 'no rules: the run succeeds: ' + Err);
  Check((GReadCalls = 2) and (GWriteCalls = 1), 'no rules: every node ran');

  { deny t_write: the write node fails with the refusal, never runs, and
    the node after it does not run on "refused: ..." either. }
  Rules('[{"tool":"t_write","effect":"deny"}]');
  ResetCounts;
  Check(not RunRW(nil, Res, Err), 'deny: the run fails');
  Check(GWriteCalls = 0, 'deny: the denied tool never ran');
  Check(GReadCalls = 1, 'deny: the node after the refusal did not run (reads=' +
        IntToStr(GReadCalls) + ')');
  Check(Pos('t_write', NodeErr(Res, 'b')) > 0, 'deny: the node error is the refusal: ' +
        NodeErr(Res, 'b'));

  { ask with no operator (web UI run, cron, MCP client): refused. }
  Rules('[{"tool":"t_write","effect":"ask"}]');
  ResetCounts;
  Check(not RunRW(nil, Res, Err), 'headless ask: the run fails');
  Check(GWriteCalls = 0, 'headless ask: the tool never ran');
  Check(NodeErr(Res, 'b') <> '', 'headless ask: the node says why');
  Rules('[]');
end;

procedure TestTurnGates;
var
  Res: TWorkflowNodeResultArray;
  Err: string;
  LC: TToolLoopConfig;
  Asker: TAsker;
  Hook: TCancelWrites;
begin
  Asker := TAsker.Create;
  Hook := TCancelWrites.Create;
  try
    { In a turn: an ask reaches the operator, and their answer holds. }
    Rules('[{"tool":"t_write","effect":"ask"}]');
    LC := Default(TToolLoopConfig);
    LC.Registry := Reg;
    LC.OnAsk := Asker.Ask;
    Asker.Answer := aaAllowOnce;
    ResetCounts;
    Check(RunRW(MakeLoopDispatcher(LC), Res, Err), 'turn ask allowed: the run succeeds: ' + Err);
    Check((GAsked = 1) and (GWriteCalls = 1), 'turn ask allowed: asked once, ran once');
    Asker.Answer := aaDeny;
    ResetCounts;
    Check(not RunRW(MakeLoopDispatcher(LC), Res, Err), 'turn ask declined: the run fails');
    Check((GAsked = 1) and (GWriteCalls = 0), 'turn ask declined: asked, did not run');
    { Nobody answered (no terminal, no UI, a timeout): refused, and saying so. }
    Asker.Answer := aaNobody;
    ResetCounts;
    Check(not RunRW(MakeLoopDispatcher(LC), Res, Err), 'turn ask unanswered: the run fails');
    Check(GWriteCalls = 0, 'turn ask unanswered: did not run');
    Check(Pos('nobody answered', NodeErr(Res, 'b')) > 0,
          'turn ask unanswered: says nobody answered, not that the user declined: ' + NodeErr(Res, 'b'));
    Rules('[]');

    { Plan mode: the mutating node is refused, the read-only one runs. }
    LC := Default(TToolLoopConfig);
    LC.Registry := Reg;
    LC.Mode := pmPlan;
    ResetCounts;
    Check(not RunRW(MakeLoopDispatcher(LC), Res, Err), 'plan mode: the run fails');
    Check((GWriteCalls = 0) and (GReadCalls = 1), 'plan mode: the write was refused, the read ran');
    Check(NodeErr(Res, 'b') <> '', 'plan mode: the node says why');

    { A BeforeToolCall hook cancels the write. }
    LC := Default(TToolLoopConfig);
    LC.Registry := Reg;
    SetLength(LC.Hooks, 1);
    LC.Hooks[0] := Hook;
    ResetCounts;
    Check(not RunRW(MakeLoopDispatcher(LC), Res, Err), 'hook cancel: the run fails');
    Check(GWriteCalls = 0, 'hook cancel: the write did not run');
    Check(Pos('hook said no', NodeErr(Res, 'b')) > 0, 'hook cancel: the hook''s reason is the error: ' +
          NodeErr(Res, 'b'));
  finally
    Hook.Free;
    Asker.Free;
  end;
end;

{ The output cap is for what reaches the model; a step's output is the next
  step's input and must arrive whole. }
procedure TestNoCapBetweenSteps;
var
  Res: TWorkflowNodeResultArray;
  Err, Long: string;
  LC: TToolLoopConfig;
  Saved: Pointer;
  Disp: IToolDispatcher;
begin
  Rules('[]');
  Long := StringOfChar('x', 400);
  LC := Default(TToolLoopConfig);
  LC.Registry := Reg;
  LC.ToolOutputCap := 50;
  Disp := MakeLoopDispatcher(LC);
  EnterWorkflowRun(Disp, Saved);
  try
    Check(RunWorkflow(Spec('{"id":"chain","name":"chain","nodes":[' +
      '{"id":"a","tool":"t_read","args":{"q":"' + Long + '"}},' +
      '{"id":"b","tool":"t_read","args":{"y":"{{nodes.a}}"}}],' +
      '"edges":[{"from":"a","to":"b"}]}'), '{}', @WorkflowDispatch, Res, Err),
      'cap: the chain runs: ' + Err);
  finally
    LeaveWorkflowRun(Saved);
  end;
  Check(Pos(Long, GLastReadArgs) > 0, 'cap: the second step got the first step''s whole output (' +
        IntToStr(Length(GLastReadArgs)) + ' bytes)');
end;

procedure TestMCPNodeGated;
var
  t, j, e: string;
begin
  { Allowed: reaches the MCP bridge (no server here, so its error). }
  Rules('[]');
  Check(not WorkflowDispatch('srv__tool', '{}', t, j, e), 'mcp node: fails without a server');
  Check(Pos('MCP', e) > 0, 'mcp node: allowed, so it reached the bridge: ' + e);
  { Denied: the refusal, not the bridge. }
  Rules('[{"tool":"srv__*","effect":"deny"}]');
  Check(not WorkflowDispatch('srv__tool', '{}', t, j, e), 'mcp node denied: fails');
  Check((Pos('srv__tool', e) > 0) and (Pos('MCP', e) = 0),
        'mcp node denied: the error is the refusal, the bridge was not called: ' + e);
  Rules('[]');
end;

procedure TestFailClosed;
var
  Saved: THeadlessDispatcherFn;
  t, j, e: string;
begin
  Saved := GHeadlessDispatcher;
  GHeadlessDispatcher := nil;
  try
    ResetCounts;
    Check(not WorkflowDispatch('t_read', '{}', t, j, e), 'no gate: the node fails');
    Check(GReadCalls = 0, 'no gate: the tool did not run');
    Check(Pos('no dispatch gate', e) > 0, 'no gate: says so: ' + e);
  finally
    GHeadlessDispatcher := Saved;
  end;
end;

procedure SaveSpec(const JSON: string);
var
  Err: string;
begin
  Check(SaveWorkflow(Spec(JSON), Err), 'save: ' + Err);
end;

function HasName(const Names: TStringArray; const N: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Names) do
    if Names[i] = N then Exit(True);
end;

procedure TestWorkflowTools;
var
  T: TTool;
  Out_, Err: string;
  Defs: TToolDefinitionArray;
  i: Integer;
  Found: Boolean;
begin
  Rules('[]');
  Check(not Reg.Find('wf_lookup', T), 'no wf_lookup before it is saved');
  SaveSpec('{"id":"lookup","name":"lookup","description":"look a thing up",' +
           '"inputs":[{"name":"q","type":"string","required":true},{"name":"n","type":"number"}],' +
           '"nodes":[{"id":"a","tool":"t_read","args":{"q":"{{inputs.q}}"}}]}');
  { No re-registration: the store changed, the registry sees it. }
  Check(Reg.Find('wf_lookup', T), 'wf_lookup appears once saved');
  Check(T.Category = tcReadOnly, 'every step read-only -> the tool is read-only');
  Check(Pos('"q"', T.Schema) > 0, 'schema lists the input q: ' + T.Schema);
  Check(Pos('"number"', T.Schema) > 0, 'schema keeps the input type');
  Check(Pos('["q"]', StringReplace(T.Schema, ' ', '', [rfReplaceAll])) > 0,
        'schema marks q required: ' + T.Schema);
  Check(Pos('"required":["q"]', StringReplace(T.Schema, ' ', '', [rfReplaceAll])) > 0,
        'schema marks only q required: ' + T.Schema);
  Check(Pos('look a thing up', T.Description) > 0, 'description is the workflow''s');
  Check(HasName(Reg.Names, 'wf_lookup'), 'Names lists it');
  Check(not Reg.FindStatic('wf_lookup', T), 'it is not a static registration');
  Defs := Reg.ToProviderDefs;
  Found := False;
  for i := 0 to High(Defs) do
    if Defs[i].Name = 'wf_lookup' then Found := True;
  Check(Found, 'the model is offered it');

  { Calling it runs the workflow with its arguments as the inputs. }
  ResetCounts;
  Out_ := Reg.RunTool('wf_lookup', '{"q":"cats"}', Err);
  Check(Err = '', 'wf_lookup runs: ' + Err);
  Check((GReadCalls = 1) and (Pos('cats', Out_) > 0), 'it ran the step with the input: ' + Out_);
  Check(JsonReadBool(Out_, 'ok', False), 'it returns the run result: ' + Out_);

  { A step that writes makes the tool mutating. }
  SaveSpec('{"id":"scribe","name":"scribe","nodes":[{"id":"w","tool":"t_write","args":{}}]}');
  Check(Reg.Find('wf_scribe', T) and (T.Category = tcMutating), 'a write step -> mutating');
  { An await's poll tool is called too: a read-only node that polls with a
    writing tool writes (Codex P1 on #648); polling with a read-only one
    does not. }
  SaveSpec('{"id":"pollw","name":"pollw","nodes":[{"id":"a","tool":"t_read","args":{},' +
           '"await":{"tool":"t_write","args":{}}}]}');
  Check(Reg.Find('wf_pollw', T) and (T.Category = tcMutating), 'a writing await poll tool -> mutating');
  SaveSpec('{"id":"pollr","name":"pollr","nodes":[{"id":"a","tool":"t_read","args":{},' +
           '"await":{"tool":"t_read","args":{}}}]}');
  Check(Reg.Find('wf_pollr', T) and (T.Category = tcReadOnly), 'a read-only await poll tool stays read-only');
  { Declared outputs are written to workflows/<id>/<stamp>/ on every run
    (Codex P2 on #648). }
  SaveSpec('{"id":"outw","name":"outw","nodes":[{"id":"a","tool":"t_read","args":{}}],' +
           '"outputs":[{"name":"o","value":"{{nodes.a}}"}]}');
  Check(Reg.Find('wf_outw', T) and (T.Category = tcMutating), 'declared outputs (written to disk) -> mutating');
  { An MCP step (unknown here) counts as mutating too. }
  SaveSpec('{"id":"remote","name":"remote","nodes":[{"id":"m","tool":"srv__x","args":{}}]}');
  Check(Reg.Find('wf_remote', T) and (T.Category = tcMutating), 'an MCP step -> mutating');

  { A rewrite in the same second with the same size is still picked up. }
  SaveSpec('{"id":"lookup","name":"lookup","description":"look a thing UP",' +
           '"inputs":[{"name":"q","type":"string","required":true},{"name":"n","type":"number"}],' +
           '"nodes":[{"id":"a","tool":"t_read","args":{"q":"{{inputs.q}}"}}]}');
  Check(Reg.Find('wf_lookup', T) and (Pos('look a thing UP', T.Description) > 0),
        'a same-size rewrite is seen: ' + T.Description);

  { Deleted: gone, again without re-registration. }
  Check(DeleteWorkflow('scribe', Err), 'delete: ' + Err);
  Check(not Reg.Find('wf_scribe', T), 'wf_scribe gone once deleted');
  Check(DeleteWorkflow('remote', Err), 'delete: ' + Err);
  DeleteWorkflow('pollr', Err);

  Check(WorkflowToolName('a b/c') = 'wf_a_b_c', 'tool names hold only safe characters');
end;

function Rpc(Srv: TMCPServerCore; const Body: string): string;
begin
  Result := Srv.HandleRequest(Body);
end;

procedure TestMCPServes;
var
  Srv, SrvW: TMCPServerCore;
  R, Err: string;
begin
  Srv := TMCPServerCore.Create(Reg, False, '');
  SrvW := TMCPServerCore.Create(Reg, True, '');
  try
    R := Rpc(Srv, '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
    Check(Pos('"wf_lookup"', R) > 0, 'MCP tools/list serves the read-only workflow');
    SaveSpec('{"id":"later","name":"later","nodes":[{"id":"a","tool":"t_read","args":{}}]}');
    R := Rpc(Srv, '{"jsonrpc":"2.0","id":2,"method":"tools/list"}');
    Check(Pos('"wf_later"', R) > 0, 'a workflow saved after the server started is listed');
    SaveSpec('{"id":"scribe","name":"scribe","nodes":[{"id":"w","tool":"t_write","args":{}}]}');
    R := Rpc(Srv, '{"jsonrpc":"2.0","id":3,"method":"tools/list"}');
    Check(Pos('"wf_scribe"', R) = 0, 'a writing workflow is not served read-only');
    Check((Pos('"wf_pollw"', R) = 0) and (Pos('"wf_outw"', R) = 0),
          'nor one that polls with a writing tool, nor one that writes its outputs');
    R := Rpc(SrvW, '{"jsonrpc":"2.0","id":4,"method":"tools/list"}');
    Check(Pos('"wf_scribe"', R) > 0, 'it is served when writes are allowed');
    ResetCounts;
    R := Rpc(Srv, '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"wf_lookup","arguments":{"q":"dogs"}}}');
    Check((GReadCalls = 1) and (Pos('dogs', R) > 0), 'MCP tools/call runs the workflow: ' + Copy(R, 1, 300));
    { Rules still hold for a caller from outside. }
    Rules('[{"tool":"t_read","effect":"deny"}]');
    ResetCounts;
    R := Rpc(Srv, '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"wf_lookup","arguments":{"q":"dogs"}}}');
    Check(GReadCalls = 0, 'MCP tools/call: a denied step does not run');
    Check(Pos('isError', R) > 0, 'MCP tools/call: the call reports the failure: ' + Copy(R, 1, 300));
    Rules('[]');
    Check(DeleteWorkflow('later', Err), 'cleanup: ' + Err);
    DeleteWorkflow('pollw', Err);
    DeleteWorkflow('outw', Err);
  finally
    SrvW.Free;
    Srv.Free;
  end;
end;

procedure TestApproval;
var
  Out_, Err, Sha: string;
  T: TTool;
  Sums: TWorkflowSummaryArray;
const
  AGENT_SPEC = '{"name":"fresh","nodes":[{"id":"a","tool":"t_read","args":{}}]}';
begin
  { Off (the default): staged, not saved, not a tool. }
  Cfg.WorkflowsAutoApprove := False;
  SetWorkflowConfig(Cfg);
  Out_ := Reg.RunTool('workflow_save', AGENT_SPEC, Err);
  Check(Err = '', 'workflow_save stages: ' + Err);
  Check(Pos('approv', Out_) > 0, 'the agent is told it waits for approval: ' + Out_);
  Check(Pos('approve fresh', Out_) > 0, 'and the id to approve: ' + Out_);
  Check(not WorkflowExists('fresh'), 'staged is not saved');
  Check(not Reg.Find('wf_fresh', T), 'staged is not a tool');
  Sums := ListPendingWorkflows;
  Check((Length(Sums) = 1) and (Sums[0].Id = 'fresh'), 'it is listed as pending');
  Check(Reg.RunTool('workflow_run', '{"name":"fresh"}', Err) = '', 'workflow_run cannot run it');
  Check(Err <> '', 'workflow_run says it is not found');

  { Approve against a hash that is not the staged file's: refused. }
  Sha := PendingWorkflowSha('fresh');
  Check(Length(Sha) = 64, 'the staged file has a sha256');
  Check(not ApprovePendingWorkflow('fresh', StringOfChar('0', 64), Err), 'a stale sha is refused');
  Check(Pos('changed', Err) > 0, 'and says why: ' + Err);
  Check(not WorkflowExists('fresh'), 'nothing was saved');
  Check(ApprovePendingWorkflow('fresh', Sha, Err), 'approve with the sha read: ' + Err);
  Check(WorkflowExists('fresh'), 'approved is saved');
  Check(Reg.Find('wf_fresh', T), 'approved is a tool, without a restart');
  Check(Length(ListPendingWorkflows) = 0, 'the staged copy is gone');

  { An update to a saved workflow is staged too; the saved one stays. }
  Out_ := Reg.RunTool('workflow_save',
    '{"name":"fresh","description":"changed","nodes":[{"id":"w","tool":"t_write","args":{}}]}', Err);
  Check(Pos('keeps running', Out_) > 0, 'the agent is told the saved version stays: ' + Out_);
  Check(Reg.Find('wf_fresh', T) and (T.Category = tcReadOnly), 'the saved version is unchanged');
  Check(RejectPendingWorkflow('fresh', Err), 'reject: ' + Err);
  Check(Length(ListPendingWorkflows) = 0, 'rejected is gone');
  Check(Reg.Find('wf_fresh', T) and (T.Category = tcReadOnly), 'rejecting left the saved one');

  { The route's name is reserved. }
  Check(Reg.RunTool('workflow_save', '{"name":"pending","nodes":[{"id":"a","tool":"t_read","args":{}}]}', Err) = '',
        '"pending" is refused');
  Check(Pos('reserved', Err) > 0, 'and says why: ' + Err);

  { auto_approve: saved straight away. }
  Cfg.WorkflowsAutoApprove := True;
  Out_ := Reg.RunTool('workflow_save', '{"name":"direct","nodes":[{"id":"a","tool":"t_read","args":{}}]}', Err);
  Check((Err = '') and WorkflowExists('direct'), 'auto-approve saves: ' + Err);
  Check(Reg.Find('wf_direct', T), 'and it is a tool at once');
  Cfg.WorkflowsAutoApprove := False;

  { No config in this context: staged, not saved. }
  SetWorkflowConfig(nil);
  Reg.RunTool('workflow_save', '{"name":"noconf","nodes":[{"id":"a","tool":"t_read","args":{}}]}', Err);
  Check(not WorkflowExists('noconf'), 'no config: not saved');
  Check(RejectPendingWorkflow('noconf', Err), 'no config: staged');
  SetWorkflowConfig(Cfg);
end;

{ In a chat, workflow_save asks the operator there and then -- the same
  asker an `ask` rule uses -- and does what they say. }
procedure TestSaveAsksInChat;
var
  LC: TToolLoopConfig;
  Asker: TAsker;
  Disp: IToolDispatcher;
  Out_, Err: string;
  T: TTool;
const
  SPEC_A = '{"name":"chatflow","description":"made in a chat","nodes":[' +
           '{"id":"look","tool":"t_read","args":{"q":"{{inputs.q}}"}},' +
           '{"id":"put","tool":"t_write","args":{"x":"{{nodes.look}}"}}],' +
           '"edges":[{"from":"look","to":"put"}],' +
           '"inputs":[{"name":"q","type":"string"}]}';
begin
  Rules('[]');
  Cfg.WorkflowsAutoApprove := False;
  SetWorkflowConfig(Cfg);
  Asker := TAsker.Create;
  try
    LC := Default(TToolLoopConfig);
    LC.Registry := Reg;
    LC.SteeringKey := 'sess-wf-ask';
    LC.OnAsk := Asker.Ask;

    { Allow: saved and a tool at once; nothing staged. }
    Asker.Answer := aaAllowOnce;
    ResetCounts;
    Disp := MakeLoopDispatcher(LC);
    Out_ := Disp.Dispatch('workflow_save', SPEC_A, Err);
    Check(GAsked = 1, 'chat save: the operator was asked');
    Check((GLastAskTool = 'workflow_save') and (GLastAskResource = 'chatflow'),
          'chat save: asked about workflow_save on the workflow''s id');
    Check((Pos('wf_chatflow', GLastAskReason) > 0) and (Pos('t_read', GLastAskReason) > 0) and
          (Pos('t_write', GLastAskReason) > 0) and (Pos('{{nodes.look}}', GLastAskReason) > 0),
          'chat save: the question shows the tool name and every step with its arguments: ' + GLastAskReason);
    Check(WorkflowExists('chatflow') and Reg.Find('wf_chatflow', T), 'chat save allowed: saved and a tool: ' + Out_ + Err);
    Check(Length(ListPendingWorkflows) = 0, 'chat save allowed: nothing staged');
    Check(Pos('approved by the user', Out_) > 0, 'chat save allowed: the agent is told: ' + Out_);
    Check(Pos('replacing the saved one', GLastAskReason) = 0, 'a new workflow is not "replacing"');

    { Deny: neither saved nor staged; the saved version is untouched. }
    Asker.Answer := aaDeny;
    ResetCounts;
    Out_ := Disp.Dispatch('workflow_save',
      '{"name":"chatflow","description":"CHANGED","nodes":[{"id":"w","tool":"t_write","args":{}}]}', Err);
    Check(GAsked = 1, 'chat save denied: asked');
    Check(Pos('replacing the saved one', GLastAskReason) > 0, 'an update says it replaces the saved one');
    Check(Pos('declined', Out_) > 0, 'chat save denied: the agent is told: ' + Out_);
    Check(Length(ListPendingWorkflows) = 0, 'chat save denied: not staged either');
    Check(Reg.Find('wf_chatflow', T) and (Pos('made in a chat', T.Description) > 0),
          'chat save denied: the saved version is unchanged');

    { Nobody answered: staged for later, as with no chat at all. }
    Asker.Answer := aaNobody;
    Out_ := Disp.Dispatch('workflow_save', '{"name":"later2","nodes":[{"id":"a","tool":"t_read","args":{}}]}', Err);
    Check(not WorkflowExists('later2') and (PendingWorkflowSha('later2') <> ''),
          'chat save unanswered: staged, not saved: ' + Out_);

    { Approving in the chat supersedes a version staged earlier. }
    Asker.Answer := aaAllowOnce;
    Out_ := Disp.Dispatch('workflow_save', '{"name":"later2","nodes":[{"id":"a","tool":"t_read","args":{}}]}', Err);
    Check(WorkflowExists('later2') and (PendingWorkflowSha('later2') = ''),
          'chat save allowed: an earlier staged copy is dropped: ' + Out_);

    { Allow for this chat: not asked again about the same workflow in the
      same session; asked about another one. }
    Asker.Answer := aaAllowSession;
    ResetCounts;
    Disp.Dispatch('workflow_save', '{"name":"sticky","nodes":[{"id":"a","tool":"t_read","args":{}}]}', Err);
    Disp.Dispatch('workflow_save', '{"name":"sticky","description":"v2","nodes":[{"id":"a","tool":"t_read","args":{}}]}', Err);
    Check(GAsked = 1, 'allow for this chat: asked once for two saves of one workflow (asked ' + IntToStr(GAsked) + ')');
    Check(Reg.Find('wf_sticky', T) and (Pos('v2', T.Description) > 0), 'the second save landed');
    Asker.Answer := aaDeny;
    Disp.Dispatch('workflow_save', '{"name":"other","nodes":[{"id":"a","tool":"t_read","args":{}}]}', Err);
    Check(GAsked = 2, 'another workflow is asked about');

    { No asker on the turn (a team agent, an API call): staged. }
    LC.OnAsk := nil;
    ResetCounts;
    Out_ := MakeLoopDispatcher(LC).Dispatch('workflow_save', '{"name":"noasker","nodes":[{"id":"a","tool":"t_read","args":{}}]}', Err);
    Check((GAsked = 0) and (PendingWorkflowSha('noasker') <> ''), 'no asker: staged: ' + Out_);

    RejectPendingWorkflow('noasker', Err);
    DeleteWorkflow('chatflow', Err);
    DeleteWorkflow('later2', Err);
    DeleteWorkflow('sticky', Err);
  finally
    Asker.Free;
  end;
end;

procedure TestFileToolsCannotWriteSpecs;
var
  Why, Dir: string;
begin
  Dir := WorkflowsDir;
  Check(not CanWritePath(JoinPath(Dir, 'lookup.json'), Why), 'a spec is not writable by file tools');
  Check(Pos('workflow_save', Why) > 0, 'the refusal points at workflow_save: ' + Why);
  Check(not CanWritePath(JoinPath(Dir, 'new.json'), Why), 'nor a new spec');
  Check(not CanWritePath(JoinPath(PendingWorkflowsDir, 'x.json'), Why), 'nor a staged one');
  Check(not CanWritePath(PendingWorkflowsDir, Why), 'nor the staging directory');
  Check(not CanWritePath(JoinPath(Dir, '.PENDING/x.json'), Why), 'nor under another case of it');
  Check(CanWritePath(JoinPath(Dir, 'lookup/20260101T000000/output.json'), Why),
        'a run''s outputs stay writable: ' + Why);
  Check(CanWritePath(JoinPath(Dir, 'notes.txt'), Why), 'a non-spec file stays writable: ' + Why);
end;

procedure PinWorkspace;
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

begin
  PinWorkspace;
  Cfg := TConfig.Create;
  Reg := TToolRegistry.Create;
  try
    Add('t_read', ToolRead, tcReadOnly);
    Add('t_write', ToolWrite, tcMutating);
    RegisterWorkflowTools(Reg);
    SetWorkflowConfig(Cfg);
    TestHeadlessGates;
    TestTurnGates;
    TestNoCapBetweenSteps;
    TestMCPNodeGated;
    TestFailClosed;
    TestWorkflowTools;
    TestMCPServes;
    TestApproval;
    TestSaveAsksInChat;
    TestFileToolsCannotWriteSpecs;
  finally
    SetWorkflowConfig(nil);
    SetWorkflowRegistry(nil);
    Reg.Free;
    Cfg.Free;
  end;
  if Failures = 0 then WriteLn('workflow_gate_tests: OK')
  else
  begin
    WriteLn('workflow_gate_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
