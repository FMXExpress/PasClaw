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
*)
unit PasClaw.Workflow.Dispatch;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  PasClaw.Config,
  PasClaw.Tools.Registry;

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

procedure SetWorkflowRegistry(Reg: TToolRegistry);
begin
  GWfReg := Reg;
end;

procedure SetWorkflowConfig(Cfg: TConfig);
begin
  GWfCfg := Cfg;
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
begin
  ResultText := ''; ResultJSON := ''; ErrMsg := '';
  if Pos('__', ToolName) > 0 then
    Result := MCPCallStructured(ToolName, ArgsJSON, ResultText, ResultJSON, ErrMsg)
  else if (ToolName = 'llm') or (ToolName = 'provider') then
    Result := LlmNodeCall(ArgsJSON, ResultText, ResultJSON, ErrMsg)
  else if GWfReg <> nil then
  begin
    ResultText := GWfReg.RunTool(ToolName, ArgsJSON, ErrMsg);
    ResultJSON := TextWrap(ResultText);
    Result := ErrMsg = '';
  end
  else
  begin
    ErrMsg := Format('workflow: unknown tool "%s" (no MCP prefix, not "llm", and no registry)', [ToolName]);
    Result := False;
  end;
end;

end.
