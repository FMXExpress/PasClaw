(*
  PasClaw.Agent.Subagent -- `spawn` tool for fan-out to specialist
  subagents.

  When the model calls `spawn(agent="researcher", prompt="...")`,
  TSpawnTool runs a focused RunToolLoop against:

    * the parent's provider + fallback chain (no new HTTPS handshake
      to a different API)
    * a filtered registry holding only the tools the named subagent
      is allowed to use (per TSubagentSpec.Tools -- and never the
      `spawn` tool itself, so nested sub-subagents aren't a thing
      in v1)
    * the subagent's specialisation system prompt instead of the
      parent's
    * the subagent's model override or, when empty, the parent's
      default

  This is intentionally NOT a child TPasClawAgent instance -- the
  parent's "single live instance per process" constraint (rooted in
  PasClaw.MCP.Bridge / PasClaw.Skills.Loader holding their state
  in module-level arrays) would otherwise have to be lifted. By
  running a bare RunToolLoop call instead, the subagent pays no
  startup cost (no MCP reconnect, no skills reload) and shares the
  parent's already-built provider + registry foundations.

  Mirrors picoclaw's SubTurn coordination, nanobot's subagent
  module, and openclaw's multi-agent routing -- same "planner agent
  fans out to specialists" pattern, smaller surface.

  Configuration: TConfig.Subagents (config.json "subagents": [...]).
*)
unit PasClaw.Agent.Subagent;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.Obj;

type
  { TSubagentSpecArray now lives in PasClaw.Config alongside
    TSubagentSpec -- see comment there for the dcc64 named-type
    rationale. The use clause above pulls it in. }

  { Everything the spawn tool needs from its parent -- captured at
    registration time so the tool handler can run a child loop
    without reaching back into the parent's TPasClawAgent state. }
  TSubagentContext = record
    Provider:       ILLMProvider;
    Fallbacks:      TLLMProviderArray;
    FallbackModels: TStringArray;   { lockstep per-fallback model overrides }
    ParentRegistry: TToolRegistry;
    DefaultModel:   string;
    (* Operator's prompt-cache config propagated from the parent so
       `prompt_cache.enabled: false` reaches subagents too. Codex P2
       on PR #118 -- see PasClaw.Config.ApplyPromptCacheConfig. *)
    PromptCache:    TPromptCacheConfig;
    (* The parent's config -- so a subagent whose registry inherited deferred
       MCP tools (via '*') can get its OWN registry-bound tool_search +
       "## Deferred Tools" prompt section, i.e. the same progressive disclosure
       the parent has. nil-safe: when unset, subagents simply skip the MCP
       disclosure wiring. *)
    Cfg:            TConfig;
  end;

  { The spawn tool itself. Subclasses TPasClawTool so the OOP
    Install path (set up in PR #93) handles registration; the model
    sees one tool named `spawn` whose schema enumerates the
    available subagent names. }
  TSpawnTool = class(TPasClawTool)
  private
    FCtx:   TSubagentContext;
    FSpecs: TSubagentSpecArray;
    function BuildSchema: string;
    function BuildDescription: string;
    function FindSpec(const N: string; out S: TSubagentSpec): Boolean;
    function JoinSpecNames: string;
  public
    constructor Create(const ACtx: TSubagentContext;
                       const ASpecs: TSubagentSpecArray);
    function Name:        string; override;
    function Description: string; override;
    function Schema:      string; override;
    function Category:    TToolCategory; override;
    function Run(const ArgsJSON: string; out ErrMsg: string): string; override;
    { Refresh the captured TSubagentContext. Embedders that swap
      providers mid-session (TPasClawAgent.SetProvider after the
      first Chat) call this so the next spawn() dispatch picks up
      the new ILLMProvider / Fallbacks / DefaultModel -- without it
      the spawn tool would keep using the stale provider that was
      live when the registry was first installed. (Codex P2 on
      PR #107.) }
    procedure SetContext(const ACtx: TSubagentContext);
  end;

(* Build a TToolRegistry holding a subset of the source registry,
   keyed by name. Tools not present in the source are silently
   skipped (logged as a warning so the operator notices a typo).
   The 'spawn' tool is always excluded so the subagent can't recurse
   into another spawn. Caller owns the returned registry and must
   free it. *)
function BuildFilteredRegistry(Source: TToolRegistry;
                               const Names: array of string): TToolRegistry;

(* Convenience for the standard registration flow: when Specs is
   non-empty, create a TSpawnTool against the given context+specs
   and Install it into Reg. The tool's lifetime is tied to Reg
   (the spawn tool holds a method-pointer handler into itself; the
   registry's RunTool dispatches through it). For callers that
   already manage their own OOP-tool ownership via FOwnedTools,
   pass the result up to register ownership; otherwise the leaked
   tool is reaped at process exit, which is fine for the CLI / one-
   shot path. Returns the created tool (or nil when Specs is empty)
   so the caller can take ownership. *)
function RegisterSpawnTool(Reg: TToolRegistry;
                            const Ctx: TSubagentContext;
                            const Specs: TSubagentSpecArray): TSpawnTool;

(* The built-in "general-purpose" subagent, available out of the box so `spawn`
   works with no `subagents` configured. Its Tools list is the single wildcard
   '*' -- BuildFilteredRegistry expands that to the parent's active toolset
   (every non-deferred tool except the spawn family and tool_search). *)
function DefaultSubagentSpec: TSubagentSpec;

(* The effective subagent specs for registration: empty when
   Cfg.SubagentsEnabled is False; otherwise the operator's configured
   subagents plus the built-in general-purpose default (unless they defined
   their own agent named "general-purpose"). One place so every surface --
   CLI, TUI, embedder -- resolves the same set. *)
function ResolveSubagentSpecs(const Cfg: TConfig): TSubagentSpecArray;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.MCP.Disclosure,   { TMCPDisclosure / per-registry tool_search for subagents }
  PasClaw.Tools.ToolLoop;

function RegisterSpawnTool(Reg: TToolRegistry;
                            const Ctx: TSubagentContext;
                            const Specs: TSubagentSpecArray): TSpawnTool;
begin
  Result := nil;
  if (Reg = nil) or (Length(Specs) = 0) then Exit;
  Result := TSpawnTool.Create(Ctx, Specs);
  Result.Install(Reg);
end;

function IsSpawnFamily(const N: string): Boolean;
begin
  { spawn, spawn_background, spawn_status, spawn_wait, spawn_cancel -- a
    subagent never gets any of them (no nested sub-subagents in v1). }
  Result := (N = 'spawn') or (Copy(N, 1, 6) = 'spawn_');
end;

function BuildFilteredRegistry(Source: TToolRegistry;
                               const Names: array of string): TToolRegistry;
var
  i: Integer;
  T: TTool;
  AllNames: TStringArray;
  Wildcard: Boolean;
begin
  Result := TToolRegistry.Create;
  if Source = nil then Exit;

  Wildcard := False;
  for i := 0 to High(Names) do
    if Names[i] = '*' then Wildcard := True;

  if Wildcard then
  begin
    { Inherit the parent's whole toolset except the spawn family and the
      parent's tool_search (the child gets its OWN registry-bound tool_search
      from the spawn handler). Deferred MCP tools are copied PRESERVING their
      deferred status, so the subagent gets the same progressive disclosure as
      the parent -- lean prompt, load on demand via its own tool_search -- not
      a dump of every MCP schema. }
    AllNames := Source.Names;
    for i := 0 to High(AllNames) do
    begin
      if IsSpawnFamily(AllNames[i]) then Continue;
      if AllNames[i] = 'tool_search' then Continue;
      if not Source.Find(AllNames[i], T) then Continue;
      if T.IsDeferred then
        Result.RegisterDeferred(T, True)
      else
        Result.Register(T);
    end;
    Exit;
  end;

  for i := 0 to High(Names) do
  begin
    if IsSpawnFamily(Names[i]) then Continue;  { no nested sub-subagents }
    if not Source.Find(Names[i], T) then
    begin
      LogWarn('subagent: source registry has no tool named "%s" -- skipping', [Names[i]]);
      Continue;
    end;
    Result.Register(T);
  end;
end;

function DefaultSubagentSpec: TSubagentSpec;
begin
  Result.Name        := 'general-purpose';
  Result.Description := 'General-purpose subagent: completes one focused, '
    + 'self-contained sub-task using the same tools as the main agent. Use it '
    + 'to fan out independent work (research, multi-file search, drafting, '
    + 'analysis) without cluttering the main thread; it returns only its final '
    + 'answer.';
  Result.SystemPrompt := 'You are a focused sub-agent spawned to complete ONE '
    + 'self-contained task and report back. Work autonomously with the tools '
    + 'you have; do not ask the caller questions. Finish with a concise result '
    + 'the caller can use directly. Do not try to spawn further sub-agents.';
  SetLength(Result.Tools, 1);
  Result.Tools[0] := '*';   { expanded by BuildFilteredRegistry to the parent toolset }
  Result.Model    := '';    { inherit the parent's default model }
  Result.MaxIter  := 0;     { -> handler default }
end;

function ResolveSubagentSpecs(const Cfg: TConfig): TSubagentSpecArray;
var
  i: Integer;
  HasGeneral: Boolean;
begin
  SetLength(Result, 0);
  if not Cfg.SubagentsEnabled then Exit;
  SetLength(Result, Length(Cfg.Subagents));
  HasGeneral := False;
  for i := 0 to High(Cfg.Subagents) do
  begin
    Result[i] := Cfg.Subagents[i];
    if SameText(Cfg.Subagents[i].Name, 'general-purpose') then HasGeneral := True;
  end;
  if not HasGeneral then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := DefaultSubagentSpec;
  end;
end;

constructor TSpawnTool.Create(const ACtx: TSubagentContext;
                              const ASpecs: TSubagentSpecArray);
var
  i: Integer;
begin
  inherited Create;
  FCtx := ACtx;
  SetLength(FSpecs, Length(ASpecs));
  for i := 0 to High(ASpecs) do FSpecs[i] := ASpecs[i];
end;

procedure TSpawnTool.SetContext(const ACtx: TSubagentContext);
begin
  FCtx := ACtx;
end;

function TSpawnTool.Name: string;
begin
  Result := 'spawn';
end;

function TSpawnTool.Description: string;
begin
  Result := BuildDescription;
end;

function TSpawnTool.Schema: string;
begin
  Result := BuildSchema;
end;

function TSpawnTool.Category: TToolCategory;
begin
  { Mutating in the parallel-batching sense -- a spawn call drives
    another LLM round trip + tool dispatch, has its own side
    effects, and shouldn't run in parallel with the parent's other
    tool calls. The agent loop treats it as a batch of one. }
  Result := tcMutating;
end;

function TSpawnTool.BuildDescription: string;
var
  i: Integer;
begin
  Result := 'Fan out to a focused specialist subagent. Pass the agent name '
          + 'and the prompt; the subagent runs its own short tool loop and '
          + 'returns its reply as the tool_result.';
  if Length(FSpecs) > 0 then
  begin
    Result := Result + ' Available subagents:';
    for i := 0 to High(FSpecs) do
    begin
      Result := Result + ' "' + FSpecs[i].Name + '"';
      if FSpecs[i].Description <> '' then
        Result := Result + ' (' + FSpecs[i].Description + ')';
      if i < High(FSpecs) then Result := Result + ',';
    end;
    Result := Result + '.';
  end;
end;

function TSpawnTool.BuildSchema: string;
var
  Obj, Props, Agent, Prompt: TJsonObject;
  Enum: TJsonArray;
  Req: TJsonArray;
  i: Integer;
begin
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('type', 'object');

    Props := TJsonObject.Create;
    try
      Agent := TJsonObject.Create;
      try
        Agent.PutStr('type', 'string');
        Agent.PutStr('description', 'Name of the subagent to spawn.');
        if Length(FSpecs) > 0 then
        begin
          Enum := TJsonArray.Create;
          for i := 0 to High(FSpecs) do
            Enum.AddStr(FSpecs[i].Name);
          Agent.PutArray('enum', Enum);
        end;
      finally
        Props.PutObject('agent', Agent);
      end;

      Prompt := TJsonObject.Create;
      try
        Prompt.PutStr('type', 'string');
        Prompt.PutStr('description', 'The prompt to hand the subagent.');
      finally
        Props.PutObject('prompt', Prompt);
      end;
    finally
      Obj.PutObject('properties', Props);
    end;

    Req := TJsonArray.Create;
    Req.AddStr('agent');
    Req.AddStr('prompt');
    Obj.PutArray('required', Req);

    Result := Obj.ToJSON;
  finally
    Obj.Free;
  end;
end;

function TSpawnTool.FindSpec(const N: string; out S: TSubagentSpec): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FSpecs) do
    if SameText(FSpecs[i].Name, N) then
    begin
      S := FSpecs[i];
      Exit(True);
    end;
  Result := False;
end;

function TSpawnTool.Run(const ArgsJSON: string; out ErrMsg: string): string;
var
  Args: TJsonObject;
  AgentName, Prompt: string;
  Spec: TSubagentSpec;
  ChildCfg: TToolLoopConfig;
  ChildReg: TToolRegistry;
  ChildDisc: TMCPDisclosure;
  SysPrompt, DeferredSec: string;
  ChildHist: TMessageArray;
  Loop: TToolLoopResult;
  Model: string;
  MaxIter: Integer;
begin
  Result := '';
  ErrMsg := '';
  Args := TJsonObject.Parse(ArgsJSON);
  if Args = nil then
  begin
    ErrMsg := 'spawn: invalid arguments JSON';
    Exit;
  end;
  try
    AgentName := Args.GetStr('agent', '');
    Prompt    := Args.GetStr('prompt', '');
  finally
    Args.Free;
  end;
  if AgentName = '' then
  begin
    ErrMsg := 'spawn: agent name required';
    Exit;
  end;
  if Prompt = '' then
  begin
    ErrMsg := 'spawn: prompt required';
    Exit;
  end;
  if not FindSpec(AgentName, Spec) then
  begin
    ErrMsg := Format('spawn: no subagent named "%s" -- available: %s',
                     [AgentName, JoinSpecNames]);
    Exit;
  end;

  Model := Spec.Model;
  if Model = '' then Model := FCtx.DefaultModel;
  MaxIter := Spec.MaxIter;
  if MaxIter <= 0 then MaxIter := 4;

  ChildReg := BuildFilteredRegistry(FCtx.ParentRegistry, Spec.Tools);
  ChildDisc := nil;
  try
    { If the child inherited deferred MCP tools (via '*'), give it its OWN
      registry-bound tool_search and append the "## Deferred Tools" section to
      its prompt, so the subagent has the same progressive disclosure the
      parent does. ChildDisc is freed below (it's bound to ChildReg, which we
      also free). }
    SysPrompt := Spec.SystemPrompt;
    if (FCtx.Cfg <> nil) and (Length(ChildReg.DeferredNames) > 0) then
    begin
      ChildDisc := RegisterMCPDisclosureTools(ChildReg, FCtx.Cfg, False);
      DeferredSec := BuildDeferredToolsSection(ChildReg);
      if DeferredSec <> '' then
        SysPrompt := SysPrompt + sLineBreak + sLineBreak + DeferredSec;
    end;

    ChildCfg.Provider      := FCtx.Provider;
    ChildCfg.Registry      := ChildReg;
    ChildCfg.Model         := Model;
    ChildCfg.MaxIterations := MaxIter;
    ChildCfg.Parallel      := True;
    ChildCfg.Fallbacks     := FCtx.Fallbacks;
    ChildCfg.FallbackModels := FCtx.FallbackModels;
    ChildCfg.Options       := DefaultChatOptions;
    ApplyPromptCacheConfig(ChildCfg.Options, FCtx.PromptCache);
    ChildCfg.Options.SystemPrompt := SysPrompt;
    ChildCfg.OnText        := nil;
    ChildCfg.OnToolCall    := nil;
    ChildCfg.OnToolResult  := nil;

    SetLength(ChildHist, 1);
    ChildHist[0] := MakeMessage(mrUser, Prompt);

    LogInfo('subagent spawn: name=%s model=%s tools=%d',
            [AgentName, Model, ChildReg.Count]);
    if RunToolLoop(ChildCfg, ChildHist, Loop) then
      Result := Loop.Content
    else
      ErrMsg := Format('spawn: subagent "%s" failed', [AgentName]);
  finally
    ChildReg.Free;
    ChildDisc.Free;   { non-primary disclosure -- this handler owns it }
  end;
end;

function TSpawnTool.JoinSpecNames: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(FSpecs) do
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + FSpecs[i].Name;
  end;
  if Result = '' then Result := '(none configured)';
end;

end.
