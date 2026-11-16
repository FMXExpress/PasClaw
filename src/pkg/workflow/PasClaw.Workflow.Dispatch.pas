(*
  PasClaw.Workflow.Dispatch - the workflow node tool caller.

  The engine calls every node through a TWorkflowToolCallerFn. This unit is the
  production caller. It routes by tool name:

    server__tool   -> the MCP bridge (MCPCallStructured)
    llm            -> a configured LLM provider (any provider with an API key):
                      args {provider, model, prompt} -> Chat -> text
    anything else  -> the tool registry (RunTool) -- so web_fetch and any other
                      registered tool can be a workflow node too

  So a workflow can chain MCP tools, LLM calls, and built-in tools freely. The
  registry and config are set once at startup (SetWorkflowRegistry from the
  shared RegisterSkills hook; SetWorkflowConfig from the gateway / CLI), the
  same module-global pattern PasClaw.Tools.Sandbox uses -- because the engine's
  caller is a plain function pointer that can't capture an instance.

  Every MCP and registry node goes through the SAME gates a direct tool call
  does: plan / space mode, the ordered permission rules, the hooks, the
  promptware scan. Before this, nodes called RunTool / MCPCallStructured
  directly, so `deny shell_exec` did not stop a workflow node calling it.
    - Run from an agent turn (workflow_run, a wf_<name> tool): the turn's
      gated dispatcher, captured where the run starts (EnterWorkflowRun) --
      an `ask` reaches the operator the way the turn's own calls do.
    - Run from anywhere else (the web UI, cron, an MCP client): a headless
      dispatcher -- the rules apply, and an `ask` is refused, there being
      no one to ask.
    - No gate in the binary at all (a test harness without the tool loop):
      the node fails. A node never runs ungated.
  A refused node fails with the refusal as its error, so a workflow stops
  there instead of feeding "refused: ..." to the next node. llm nodes are a
  provider call, not a tool, and meet no tool gate.
*)
unit PasClaw.Workflow.Dispatch;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  PasClaw.Config,
  PasClaw.Tools.Registry;

{ Bracket a run with the dispatcher its nodes go through -- the caller's
  turn's (GCaptureDispatcher, called on the dispatching thread), or nil for
  the headless one. Disp must stay referenced by the caller until
  LeaveWorkflowRun; runs nest (a node can run a workflow), so Leave restores
  what Enter replaced. }
procedure EnterWorkflowRun(const Disp: IToolDispatcher; out Saved: Pointer);
procedure LeaveWorkflowRun(Saved: Pointer);

{ The production node caller (matches TWorkflowToolCallerFn). }
function WorkflowDispatch(const ToolName, ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;

{ Set the tool registry used for non-MCP, non-llm nodes. Called from
  RegisterWorkflowTools so it is wired at every registry-build site. }
procedure SetWorkflowRegistry(Reg: TToolRegistry);

{ Set the config used to resolve llm nodes to a provider (with its API key).
  A reference, not owned -- the caller must outlive workflow runs (the gateway
  / command owns it for its lifetime). llm nodes error clearly when unset. }
procedure SetWorkflowConfig(Cfg: TConfig);
{ What SetWorkflowConfig set (nil when nothing did). }
function WorkflowConfig: TConfig;
{ What SetWorkflowRegistry set (nil when nothing did). }
function WorkflowRegistry: TToolRegistry;

implementation

uses
  SysUtils,
  PasClaw.JSON,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory,
  PasClaw.MCP.Bridge;

var
  GWfReg: TToolRegistry = nil;
  GWfCfg: TConfig = nil;

threadvar
  { The current run's dispatcher, as a raw pointer: the IToolDispatcher is
    held alive by the caller between Enter and Leave. }
  GWfDisp: Pointer;

procedure EnterWorkflowRun(const Disp: IToolDispatcher; out Saved: Pointer);
begin
  Saved := GWfDisp;
  GWfDisp := Pointer(Disp);
end;

procedure LeaveWorkflowRun(Saved: Pointer);
begin
  GWfDisp := Saved;
end;

{ The dispatcher this node goes through: the run's, or a headless one. nil
  only when no gate exists in this binary. }
function NodeDispatcher: IToolDispatcher;
begin
  if GWfDisp <> nil then
    Result := IToolDispatcher(GWfDisp)
  else if Assigned(GHeadlessDispatcher) and (GWfReg <> nil) then
    Result := GHeadlessDispatcher(GWfReg)
  else
    Result := nil;
end;

procedure SetWorkflowRegistry(Reg: TToolRegistry);
begin
  GWfReg := Reg;
end;

procedure SetWorkflowConfig(Cfg: TConfig);
begin
  GWfCfg := Cfg;
end;

function WorkflowConfig: TConfig;
begin
  Result := GWfCfg;
end;

function WorkflowRegistry: TToolRegistry;
begin
  Result := GWfReg;
end;

function TextWrap(const S: string): string;
begin
  { Wrap plain text as a one-key object so a downstream selector can use
    `.text`, while a bare node reference with no selector still yields the
    node's Text directly. }
  Result := '{"text":"' + JsonEscape(S) + '"}';
end;

function LlmNodeCall(const ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
var
  Args: TJsonObject;
  ProvName, Model, Prompt, System_: string;
  Prov: ILLMProvider;
  Msgs: array of TMessage;
  Resp: TLLMResponse;
  Opts: TChatOptions;
  N: Integer;
begin
  Result := False;
  ResultText := ''; ResultJSON := ''; ErrMsg := '';
  if GWfCfg = nil then
  begin ErrMsg := 'llm node: no provider config in this context'; Exit; end;

  try Args := TJsonObject.Parse(ArgsJSON); except Args := nil; end;
  if Args = nil then begin ErrMsg := 'llm node: bad args JSON'; Exit; end;
  try
    ProvName := Trim(Args.GetStr('provider', ''));
    Model    := Trim(Args.GetStr('model', ''));
    Prompt   := Args.GetStr('prompt', '');
    System_  := Args.GetStr('system', '');
  finally
    Args.Free;
  end;

  if Prompt = '' then begin ErrMsg := 'llm node: "prompt" is required'; Exit; end;
  if ProvName = '' then ProvName := GWfCfg.DefaultProvider;
  if not NewProviderFromConfig(GWfCfg, ProvName, Prov, ErrMsg) then Exit;
  if Model = '' then Model := Prov.GetDefaultModel;

  N := 0;
  if System_ <> '' then Inc(N);
  Inc(N);
  SetLength(Msgs, N);
  N := 0;
  if System_ <> '' then
  begin
    Msgs[N].Role := mrSystem; Msgs[N].Content := System_; Inc(N);
  end;
  Msgs[N].Role := mrUser; Msgs[N].Content := Prompt;

  Opts := DefaultChatOptions;
  try
    Resp := Prov.Chat(Msgs, [], Model, Opts);
  except
    on E: Exception do begin ErrMsg := 'llm node: ' + E.Message; Exit; end;
  end;

  if (Resp.StatusCode = -1) or (Resp.StatusCode >= 400) then
  begin
    ErrMsg := Format('llm node: provider "%s" returned status %d', [ProvName, Resp.StatusCode]);
    Exit;
  end;
  ResultText := Resp.Content;
  ResultJSON := TextWrap(Resp.Content);
  Result := True;
end;

function WorkflowDispatch(const ToolName, ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
var
  Disp: IToolDispatcher;
  Gate: IToolGate;
  Refusal: string;
  Refused: Boolean;
begin
  ResultText := ''; ResultJSON := ''; ErrMsg := '';
  if (ToolName = 'llm') or (ToolName = 'provider') then
  begin
    Result := LlmNodeCall(ArgsJSON, ResultText, ResultJSON, ErrMsg);
    Exit;
  end;
  if (Pos('__', ToolName) = 0) and (GWfReg = nil) then
  begin
    ErrMsg := Format('workflow: unknown tool "%s" (no MCP prefix, not "llm", and no registry)', [ToolName]);
    Exit(False);
  end;
  Disp := NodeDispatcher;
  if (Disp = nil) or not Supports(Disp, IToolGate, Gate) then
  begin
    ErrMsg := Format('workflow: node "%s" not run -- no dispatch gate in this context', [ToolName]);
    Exit(False);
  end;
  if Pos('__', ToolName) > 0 then
  begin
    { MCP: admitted by the gates, then called for its structured JSON. }
    if not Gate.Admit(ToolName, ArgsJSON, Refusal) then
    begin
      ErrMsg := Refusal;
      Exit(False);
    end;
    Result := MCPCallStructured(ToolName, ArgsJSON, ResultText, ResultJSON, ErrMsg);
    Gate.Finish(ToolName, ArgsJSON, ResultText, ErrMsg);
    Result := Result and (ErrMsg = '');
  end
  else
  begin
    { A registered tool: through every gate, a refusal failing the node. }
    ResultText := Gate.DispatchChecked(ToolName, ArgsJSON, Refused, ErrMsg);
    if Refused then
    begin
      ErrMsg := ResultText;
      ResultText := '';
      Exit(False);
    end;
    ResultJSON := TextWrap(ResultText);
    Result := ErrMsg = '';
  end;
end;

end.
