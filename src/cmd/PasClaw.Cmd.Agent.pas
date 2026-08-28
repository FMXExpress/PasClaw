{
  Agent -- chat with the assistant.

  Two modes:
    pasclaw agent -m "single query"   one-shot
    pasclaw agent                     interactive

  Always wires the built-in tools registry (fs_read, fs_write, fs_list,
  shell_exec). Falls back to an offline preview if no provider is configured.
}
unit PasClaw.Cmd.Agent;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Agent_Run(const Argv: array of string): Integer;

implementation

uses
  PasClaw.Workspaces,
  SysUtils, Classes,
  PasClaw.Config, PasClaw.Utils, PasClaw.CliUI, PasClaw.Logger,
  PasClaw.Memory.AutoDistill,
  PasClaw.Memory.Facts.Embed,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory,
  PasClaw.Tools.Registry,
  PasClaw.Tools.FS,
  PasClaw.Tools.Shell,
  PasClaw.Tools.ExecuteCode,
  PasClaw.Tools.Memory,
  PasClaw.Tools.KB,
  PasClaw.Tools.DelphiBuild,
  PasClaw.Tools.SessionSearch,
  PasClaw.Tools.PlanWrite,
  PasClaw.Tools.SendMessage,
  PasClaw.Tools.DB,
  PasClaw.Tools.Cron,
  PasClaw.Projects.Tools,
  PasClaw.Agents.Tools,           { agent -- standing agents and their mailbox }
  PasClaw.Tools.WebSearch,
  PasClaw.Search.Factory,
  PasClaw.Tools.WebFetch,
  PasClaw.Tools.MemoryFetch,
  PasClaw.Tools.Vault,
  PasClaw.Tools.OutputCache,
  PasClaw.Tools.ToolLoop,
  PasClaw.Agent.Compact,
  PasClaw.Agent.Prune,
  PasClaw.MCP.Bridge,
  PasClaw.MCP.Disclosure,   { tool_search must exist even with --no-mcp }
  PasClaw.Skills.Loader,
  PasClaw.Skills.Manage,
  PasClaw.Skills.Disclosure,
  PasClaw.Agent.SkillDistiller,
  PasClaw.Agent.Mode,
  PasClaw.Agent.Prompt,
  PasClaw.Agent.Subagent,
  PasClaw.Agent.SubagentBg,
  PasClaw.Agent.AutoRouter,
  PasClaw.Agent.AutoRouter.Apply,
  PasClaw.Session.Store,
  PasClaw.Tools.Sandbox,
  PasClaw.Shell.Backend,           { StartShellSession / CloseShellSession +
                                     SetCurrentSessionId -- so the
                                     active shell backend (docker, ssh,
                                     local) knows which session is
                                     running and dispatches Exec to the
                                     right container. }
  PasClaw.Shell.Backend.Factory,   { InstallShellBackend -- called once
                                     from Cmd_Agent_Run with the loaded
                                     Cfg + the optional --backend
                                     override. Sets the process-wide
                                     active backend. }
  PasClaw.Identity,
  PasClaw.Agent.Steering,
  PasClaw.Checkpoints,
  PasClaw.Agent.Goals,
  PasClaw.Markdown.Render;

{ Every path that creates a persisted session goes through here, so the
  profile stamp cannot be forgotten on one of them. Codex on #551 caught
  exactly that: the stamp started life inline in RunInteractive, which left
  `agent --session <id> -m ...` and interactive /new writing sessions with no
  profile -- and an unstamped session resumes under the ambient profile,
  silently dropping the sandbox it was created under.

  Only stamps when empty: a session records the profile it was CREATED under
  and keeps it, so an explicit --profile for one invocation does not rewrite
  the binding. }
function NewStampedSession(const Id: string; const Cfg: TConfig): TSession;
begin
  Result := TSession.Create(Id);
  if Result.Meta.Profile = '' then Result.Meta.Profile := Cfg.ProfileName;
end;

{ ', profile X' for the session banner, or '' when the session runs on
  stock defaults -- no profile line for the case that needs no words. }
function ProfileSuffix(const Name: string): string;
begin
  if Name = '' then Result := '' else Result := ', profile ' + Name;
end;

type
  (* --orient / --no-orient: per-invocation override of
     Cfg.OrientTaskAware (task-aware MEMORY slicing, PasClaw.Agent.Orient).
     ooUnset = leave whatever config.json / the profile resolved to;
     ooOn = force task-aware slicing on for this run; ooOff = force whole-
     file injection. The feature ships off on every profile, so --orient
     is the normal way to try it without editing config.json. *)
  TOrientOverride = (ooUnset, ooOn, ooOff);

  TAgentArgs = record
    Message:       string;
    Model:         string;
    Provider:      string;
    SystemPrompt:  string;
    Thinking:      string;
    MaxTokens:     Integer;
    MaxIterations: Integer;
    NoTools:       Boolean;
    NoMCP:         Boolean;
    NoHashline:    Boolean;
    { --no-plan -- opt out of the workspace/PLAN.md auto-pickup
      added in PR-cycle "pasclaw plan / pasclaw build" Phase 2.
      Default False; when True, BuildActivePlanSection emits empty
      so PLAN.md is ignored for this run. Cmd.Build also reads this
      from A.Forwarded to skip its post-success archival step. }
    NoPlan:        Boolean;
    { --goal-objective "<text>" -- Phase 3 of the plan/build pairing.
      When non-empty in the one-shot -m path, RunSingleTurnGoalDriven
      drives the Ralph judge loop (PasClaw.Agent.Goals.TGoalRunner)
      against the objective instead of doing a single-shot turn. Empty
      -> single-shot. Set by Cmd.Build --goal after parsing PLAN.md's
      "## Goal" section. Interactive mode does NOT consume this --
      operators in REPL use the /goal slash command instead. }
    GoalObjective: string;
    { --goal-max-iters N -- override the Ralph budget for the
      --goal-objective driver. Defaults to
      PasClaw.Agent.Goals.DefaultGoalMaxIter. Ignored when
      GoalObjective is empty. }
    GoalMaxIters:  Integer;
    { Session id to resume. Empty (the default) = interactive mode
      auto-allocates a fresh id and persists from turn 1, so a Ctrl-C
      / crash never drops the conversation. Non-empty AND existing on
      disk = load history + system-prompt override from
      workspace/sessions/<id>.json. Non-empty AND missing on disk =
      create that session id with empty history (so a script can
      pre-seed an id like "daily-2026-06-01"). RunSingleTurn (one-shot
      -m) USED TO ignore this; as of PR #292 P1, when --session <id>
      is supplied alongside -m the one-shot turn is persisted to that
      id so scripted callers (notably `pasclaw profile bench`) can
      read back per-turn stats. Callers that don't pass --session keep
      the original "single turns aren't persisted" behaviour. }
    Session:       string;
    { --backend local|docker. Empty = use Cfg.ShellBackend. Override
      is per-invocation; we don't persist it to config. }
    BackendOverride: string;
    (* --quiet / -q: machine-friendly output. RunSingleTurn drops the
       `assistant (provider/model):` header, every tool-call /
       tool-result preview line, and the trailing dim
       [tokens in=... out=... iters=...] line, leaving only the
       assistant's final reply on stdout (followed by a single
       newline). PrintBanner is also skipped at the dpr level via
       IsQuietInvocation. Designed for Replicate / Lambda / curl
       pipelines where the caller wants the model's answer as the
       sole stdout payload. Interactive mode ignores this; quiet
       only makes sense for one-shot -m. *)
    Quiet: Boolean;
    (* --verbose / --brief: controls how much of each tool call's args and
       result is echoed. Verbose (the default) shows a generous preview so you
       can see what the agent is actually doing -- close to what --debug gives,
       minus the HTTP/provider chatter. --brief clips back to a short one-liner
       per call; --quiet (above) suppresses the per-tool lines entirely and
       wins over both. *)
    Verbose: Boolean;
    (* --mode plan|build|improve (PR #290). Default Build (full tool access).
       Plan refuses tcMutating tools at dispatch time -- the model gets
       analysis-only access. The interactive loop also re-checks the
       current value before each turn so an in-session /mode switch
       takes effect immediately. *)
    Mode: TPasClawMode;
    (* --profile <name> (PR #291). Overrides PASCLAW_PROFILE / the
       config.json "profile" field for this invocation. Empty string
       means "fall through to the env var / config.json / no-profile
       chain". *)
    Profile: string;
    { --orient / --no-orient override of Cfg.OrientTaskAware. See
      TOrientOverride. ooUnset = honour config/profile. }
    OrientOverride: TOrientOverride;
  end;

  TLoopHandlers = class
    Quiet: Boolean;    { when True, OnToolCall / OnToolResult emit nothing.
                         Set by Cmd_Agent_Run before passing to BuildLoopConfig
                         so machine-friendly callers (-q / --quiet) get the
                         assistant reply on stdout with no per-tool decoration. }
    Verbose: Boolean;  { when True (the default), show a generous preview of
                         each call's args + result; when False (--brief), clip
                         to a short one-liner. Ignored under Quiet. }
    MetaRef: PSessionMeta; { the persisted session's meta, when there is one.
                             Compaction flushes working state into it before
                             dropping history; nil (one-shot runs) disables
                             the flush, not the compaction. }
    procedure OnToolCall(const Name, ArgsJSON: string);
    procedure OnToolResult(const Name, ResultText, Err: string);
    procedure OnBeforeCompact(const Messages: array of TMessage);
    procedure OnBeforePrune(const Messages: array of TMessage);
  end;

const
  BriefPreviewChars   = 200;    { --brief: a terse one-liner per call/result   }
  VerbosePreviewChars = 2000;   { default: fuller args/results, close to --debug }

{ Clip S to Max chars, appending an ellipsis when truncated. Byte-oriented like
  the previous inline Copy() -- a multi-byte codepoint may straddle the cut, but
  the terminal tolerates it and this matches the pre-existing behaviour. }
function PreviewCap(const S: string; Max: Integer): string;
begin
  if Length(S) <= Max then Result := S
  else Result := Copy(S, 1, Max) + '…';
end;

(* Fired by CompactMessages with the FULL history, just before the
   older half is summarised away. UpdateWorkingStateAfterTurn normally
   runs at end of turn -- so a mid-turn compaction used to drop tool
   calls the working state had never seen, and the paths they edited
   were gone from the transcript AND from the snapshot built to
   outlive it. Flushing here closes that gap. Persisting is left to
   the ordinary end-of-turn PersistSession; this only updates the
   in-memory meta the turn will save anyway. *)
procedure TLoopHandlers.OnBeforeCompact(const Messages: array of TMessage);
var
  Arr: TMessageArray;
  i: Integer;
begin
  if MetaRef = nil then Exit;
  SetLength(Arr, Length(Messages));
  for i := 0 to High(Messages) do Arr[i] := Messages[i];
  UpdateWorkingStateAfterTurn(MetaRef^, Arr);
end;

(* Fired by PruneMessages just before it deletes anything.

   Pruning removes messages from the history the turn will persist, so
   the deleted turns leave the session file and every export of it.
   That is right for the LIVE file -- it is the resume state, and a
   resume that replayed the pruned messages would undo the prune -- but
   the record of what the agent actually saw should not be a casualty
   of context management. So the transcript is copied once, on the
   first prune, to <id>.orig.json; `session export --full` reads it
   back. Once, because the point is the ORIGINAL: a copy taken on the
   second prune is already missing what the first one removed. *)
procedure TLoopHandlers.OnBeforePrune(const Messages: array of TMessage);
begin
  if MetaRef = nil then Exit;          { one-shot run: no session file }
  if ArchiveSessionOnce(MetaRef^.Id) then
    LogInfo('session: archived %s before its first prune', [MetaRef^.Id]);
end;

procedure TLoopHandlers.OnToolCall(const Name, ArgsJSON: string);
var
  Cap: Integer;
begin
  if Quiet then Exit;
  if Verbose then Cap := VerbosePreviewChars else Cap := BriefPreviewChars;
  PrintLn(Ansi.Magenta + '› tool ' + Name + Ansi.Reset + ' ' + PreviewCap(ArgsJSON, Cap));
end;

procedure TLoopHandlers.OnToolResult(const Name, ResultText, Err: string);
var
  Cap: Integer;
begin
  if Quiet then Exit;
  if Err <> '' then
    PrintLn(Ansi.Red + '  ✗ ' + Err + Ansi.Reset)
  else
  begin
    if Verbose then Cap := VerbosePreviewChars else Cap := BriefPreviewChars;
    PrintLn(Ansi.Dim + '  ✓ ' + PreviewCap(ResultText, Cap) + Ansi.Reset);
  end;
end;

function DefaultAgentArgs: TAgentArgs;
begin
  Result.Message       := '';
  Result.Model         := '';
  Result.Provider      := '';
  Result.SystemPrompt  := '';
  Result.Thinking      := '';
  Result.MaxTokens     := 8192;   { see DefaultChatOptions in PasClaw.Providers.Types -- same rationale }
  Result.MaxIterations := 8;
  Result.NoTools       := False;
  Result.NoMCP         := False;
  Result.NoHashline    := False;
  Result.NoPlan        := False;
  Result.GoalObjective := '';
  Result.GoalMaxIters  := 0;  { 0 = use DefaultGoalMaxIter }
  Result.Quiet         := False;
  Result.Verbose       := True;   { fuller tool-call previews by default }
  Result.OrientOverride := ooUnset;
end;

function ParseArgs(const Argv: array of string; var A: TAgentArgs): Boolean;
var
  i: Integer;
begin
  Result := True;
  A := DefaultAgentArgs;
  i := 0;
  while i <= High(Argv) do
  begin
    if (Argv[i] = '-m') or (Argv[i] = '--message') then
    begin
      if i = High(Argv) then Exit(False);
      A.Message := Argv[i + 1]; Inc(i, 2); Continue;
    end;
    if Argv[i] = '--model'    then begin if i = High(Argv) then Exit(False); A.Model := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--provider' then begin if i = High(Argv) then Exit(False); A.Provider := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--system'   then begin if i = High(Argv) then Exit(False); A.SystemPrompt := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--thinking' then begin if i = High(Argv) then Exit(False); A.Thinking := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--max-tokens'     then begin if i = High(Argv) then Exit(False); A.MaxTokens     := StrToIntDef(Argv[i + 1], A.MaxTokens);     Inc(i, 2); Continue; end;
    if Argv[i] = '--max-iterations' then begin if i = High(Argv) then Exit(False); A.MaxIterations := StrToIntDef(Argv[i + 1], A.MaxIterations); Inc(i, 2); Continue; end;
    if Argv[i] = '--no-tools'    then begin A.NoTools    := True; Inc(i); Continue; end;
    if Argv[i] = '--no-mcp'      then begin A.NoMCP      := True; Inc(i); Continue; end;
    if Argv[i] = '--no-hashline' then begin A.NoHashline := True; Inc(i); Continue; end;
    if Argv[i] = '--orient'      then begin A.OrientOverride := ooOn;  Inc(i); Continue; end;
    if Argv[i] = '--no-orient'   then begin A.OrientOverride := ooOff; Inc(i); Continue; end;
    if Argv[i] = '--no-plan'     then begin A.NoPlan     := True; Inc(i); Continue; end;
    if Argv[i] = '--goal-objective' then begin if i = High(Argv) then Exit(False); A.GoalObjective := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--goal-max-iters' then begin if i = High(Argv) then Exit(False); A.GoalMaxIters := StrToIntDef(Argv[i + 1], A.GoalMaxIters); Inc(i, 2); Continue; end;
    if (Argv[i] = '--quiet') or (Argv[i] = '-q') then begin A.Quiet := True; Inc(i); Continue; end;
    if Argv[i] = '--verbose'     then begin A.Verbose := True;  Inc(i); Continue; end;
    if Argv[i] = '--brief'       then begin A.Verbose := False; Inc(i); Continue; end;
    if Argv[i] = '--session'     then begin if i = High(Argv) then Exit(False); A.Session := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--backend'     then begin if i = High(Argv) then Exit(False); A.BackendOverride := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--mode'        then
    begin
      if i = High(Argv) then Exit(False);
      if not ParseMode(Argv[i + 1], A.Mode) then
      begin
        PrintLnErr('invalid --mode "' + Argv[i + 1] + '" (expected plan|build|improve)');
        Exit(False);
      end;
      Inc(i, 2); Continue;
    end;
    if Argv[i] = '--plan'        then begin A.Mode := pmPlan;  Inc(i); Continue; end;
    if Argv[i] = '--build'       then begin A.Mode := pmBuild; Inc(i); Continue; end;
    if Argv[i] = '--profile'     then begin if i = High(Argv) then Exit(False); A.Profile := Argv[i + 1]; Inc(i, 2); Continue; end;
    Inc(i);
  end;
end;

function PickProvider(Cfg: TConfig; const A: TAgentArgs;
                      out Provider: ILLMProvider; out Err: string): Boolean;
var
  Name: string;
begin
  if A.Provider <> '' then Name := A.Provider else Name := Cfg.DefaultProvider;
  if Name = '' then
  begin
    Err := 'no provider configured';
    Exit(False);
  end;
  Result := NewProviderFromConfig(Cfg, Name, Provider, Err);
end;

function NewBuiltinRegistry(UseHashline: Boolean = True;
                            EnableVault: Boolean = False;
                            EnableWebSearch: Boolean = False;
                            EnableWebFetch: Boolean = False;
                            EnableOutputCache: Boolean = False;
                            EnableCron: Boolean = False;
                            const DBConfigJSON: string = '';
                            EnableDesktopTools: Boolean = False): TToolRegistry;
var
  Skills: TSkillSpecArray;
begin
  Result := TToolRegistry.Create;
  RegisterFSTools(Result, UseHashline);
  RegisterShellTool(Result);
  RegisterExecuteCodeTool(Result);
  RegisterMemoryTools(Result);
  RegisterKBTools(Result);
  { delphi_build self-gates: registers only when a RAD Studio install is
    found (so it's invisible on non-Delphi hosts). Runs host-side, which is
    the point -- the compiler lives on the host even when shell_exec is in
    a docker container. }
  RegisterDelphiBuildTool(Result);
  RegisterSessionSearchTool(Result);
  { web_search registers only when a real provider is configured
    (Brave / Tavily / Perplexity / Gemini key, or SearXNG base URL).
    Callers compute the flag via PasClaw.Search.Factory's
    HasConfiguredWebSearchProvider and pass it here. The DDG scrape
    fallback is intentionally hidden from the model because DDG's
    bot-detection wall refuses non-browser TLS fingerprints in 2026. }
  if EnableWebSearch then RegisterWebSearchTool(Result)
  else                    LogWebSearchSkipOnce;
  { web_fetch is opt-in (Cfg.WebFetchEnabled). Off by default
    because picoclaw's model fetches URLs via shell+curl and we
    don't want to silently divert that traffic. Operators on
    container/sandboxed deploys without curl can flip this in
    config.json. }
  if EnableWebFetch then RegisterWebFetchTool(Result);
  { memory_fetch piggybacks on the same WebFetch enable: it uses
    the same HTTP machinery + SSRF gate, and an operator who's
    declined to enable URL fetching shouldn't get a second tool
    that also fetches URLs. }
  if EnableWebFetch then RegisterMemoryFetchTool(Result);
  { Vault tools register only when explicitly enabled -- callers pass
    Cfg.VaultToolsEnabled. Off-by-default per the onboarding opt-in
    flow; flipping the config flag (or re-running `pasclaw onboard`)
    is the way to turn it on. }
  if EnableVault then RegisterVaultTools(Result);
  { tool_output_get gets registered alongside the rest when the
    operator has flipped on Cfg.ToolOutputCap. The tool's only
    useful while truncation is active, so the flag gates both. }
  if EnableOutputCache then RegisterOutputCacheTool(Result);
  { cron tool: opt-in (Cfg.CronToolEnabled). Lets the model schedule an
    existing skill on a cron; off by default since it grants background
    autonomy. In `agent` there's no live scheduler, so additions apply the
    next time serve/gateway runs. }
  if EnableCron then RegisterCronTool(Result);
  (* project/task: the desktop board. OPT-IN (Cfg.DesktopToolsEnabled).

     The desktop clients drive this board over HTTP and do not need the
     tools to exist; they are here only for when you want the MODEL to
     manage the board itself. Off by default because PasClaw's behaviour
     should not change for someone who never opens a desktop -- two extra
     tools in the schema is two extra tools the model reads every turn. *)
  if EnableDesktopTools then
    RegisterProjectTools(Result);
  (* agent: standing agents and the mailbox between them. Gates itself on
     the loaded config rather than taking a parameter -- the same shape
     send_message uses below, and it keeps the CLI in step with `gateway`
     and `serve` without threading a flag through every caller of this
     function. Without it, an operator who set agent_tools_enabled got
     the tool on the gateway and silently nothing on the CLI. *)
  if LoadConfig.AgentToolsEnabled then
    RegisterAgentTools(Result);
  { plan_write registers when running in pmPlan mode (Cmd.Plan and
    `pasclaw agent --mode plan` both arrive here with the flag set).
    The tool is tcReadOnly even though it writes the one plan-meta
    file -- see PasClaw.Tools.PlanWrite for the rationale. }
  { Unconditional (Codex P1 on PR #595). This used to be gated on
    --mode plan, which left every other surface without the tool --
    fatal for SPACE mode, whose dispatch gate refuses mutating tools
    until plan_write succeeds: the refusal named a tool the registry
    did not carry, and the session was permanently read-only. The
    gateway makes the conditional unfixable in principle: its registry
    is built once at boot while the mode arrives per-request. And the
    tool is harmless everywhere -- tcReadOnly, one fixed path, and the
    PLAN.md it writes is picked up by the Active Plan section in every
    mode except pmPlan itself. }
  RegisterPlanWriteTool(Result);
  (* send_message gates itself: it registers only when config.json
     declares named channels (a "channels" array of name/kind/target
     entries), so there's no flag to thread through here. The model
     can only post to operator-declared targets -- see
     PasClaw.Tools.SendMessage. Paren-star delimiters because the
     literal braces of a JSON object example inside curly-brace
     comments terminate the comment early on dcc64; FPC tolerated
     it but Delphi closes on the first '}'. *)
  RegisterSendMessageTool(Result);
  Skills := LoadSkillManifests(GetHome);
  RegisterSkills(Result, Skills);
  { Install the configured db_* connections (inert when the "database" section
    is absent). Process-global, so one call per surface suffices. }
  SetDBConfigFromJSON(DBConfigJSON);
end;

{ When the operator declared subagents in config.json, install the
  `spawn` tool into the registry -- once MCP tools have already been
  bridged in so subagents can include them in their allowlist.
  Returns the created spawn tool so the caller can `Free` it during
  cleanup; nil when no subagents are configured. }
function MaybeRegisterSpawnTool(Cfg: TConfig; Provider: ILLMProvider;
                                 Reg: TToolRegistry; const Model: string): TSpawnTool;
var
  Ctx: TSubagentContext;
  Specs: TSubagentSpecArray;
begin
  Result := nil;
  Specs := ResolveSubagentSpecs(Cfg);   { configured + built-in general-purpose; empty when disabled }
  if (Reg = nil) or (Length(Specs) = 0) then Exit;
  Ctx.Provider       := Provider;
  Ctx.Fallbacks      := ResolveFallbacks(Cfg, Ctx.FallbackModels);
  Ctx.ParentRegistry := Reg;
  Ctx.DefaultModel   := Model;
  Ctx.PromptCache    := Cfg.PromptCache;
  Ctx.Cfg            := Cfg;   { subagent inherits MCP progressive disclosure }
  Result := RegisterSpawnTool(Reg, Ctx, Specs);
end;

function MaybeRegisterBackgroundSpawnTools(Cfg: TConfig; Provider: ILLMProvider;
                                            Reg: TToolRegistry;
                                            const Model: string)
                                            : TBackgroundSpawnCoordinator;
var
  Ctx: TSubagentContext;
  Specs: TSubagentSpecArray;
begin
  Result := nil;
  Specs := ResolveSubagentSpecs(Cfg);
  if (Reg = nil) or (Length(Specs) = 0) then Exit;
  Ctx.Provider       := Provider;
  Ctx.Fallbacks      := ResolveFallbacks(Cfg, Ctx.FallbackModels);
  Ctx.ParentRegistry := Reg;
  Ctx.DefaultModel   := Model;
  Ctx.PromptCache    := Cfg.PromptCache;
  Ctx.Cfg            := Cfg;   { subagent inherits MCP progressive disclosure }
  Result := RegisterBackgroundSpawnTools(Reg, Ctx, Specs);
end;

function ConnectMCP(Cfg: TConfig; Reg: TToolRegistry; NoMCP: Boolean): TMCPClientList;
begin
  SetLength(Result, 0);
  if Reg = nil then Exit;
  if NoMCP then
  begin
    { --no-mcp still needs the disclosure surface. tool_search is the only
      way to load a deferred schema, and built-in long-tail deferral is on
      by default, so skipping this would hide spawn*/db_*/workflow_* AND
      remove the tool that reveals them -- undiscoverable, not just
      invisible (Codex P1, PR #547). Registering it also latches the
      deferral, so the two can never come apart. }
    RegisterMCPDisclosureTools(Reg, Cfg);
    Exit;
  end;
  Result := ConnectMCPServers(Cfg, Reg);
end;

function BuildLoopConfig(const Cfg: TConfig;
                         Provider: ILLMProvider; Reg: TToolRegistry;
                         const Model: string; const A: TAgentArgs;
                         Handlers: TLoopHandlers;
                         const TaskHint: string = ''): TToolLoopConfig;
begin
  { Function results of record type are as uninitialized as locals: any
    field this builder doesn't set (e.g. DisableProgressLedger) would read
    garbage and flip features at random on the CLI path. Same fix shape as
    the gateway/TUI Default-inits. }
  Result := Default(TToolLoopConfig);
  Result.Provider      := Provider;
  Result.Registry      := Reg;
  Result.Model         := Model;
  (* Plan mode runs on the plan model, when one is configured.

     plan_model existed nowhere until pruning needed a name for "the
     model that thinks rather than does" -- and a setting called
     plan_model that plan mode itself ignored would be a lie. An
     explicit --model still wins: it is the more specific instruction,
     and Model already carries it by the time we get here. *)
  if (A.Mode = pmPlan) and (Cfg.PlanModel <> '') and (A.Model = '') then
    Result.Model := Cfg.PlanModel;
  Result.MaxIterations := A.MaxIterations;
  Result.Parallel := True;
  Result.Fallbacks     := ResolveFallbacks(Cfg, Result.FallbackModels);
  Result.Options       := DefaultChatOptions;
  { ToolsEnabled tracks the registry we are about to hand RunToolLoop
    so the system prompt stays in sync with what the model can
    actually call. Reg is nil when --no-tools is set (RunBuilder
    passes nil; see Run* call sites above) -- deriving from the
    registry, not from A.NoTools, also handles the case where future
    callers nil out Reg for other reasons.

    TaskHint is the current user message where the call site has it
    (one-shot Prompt, the interactive Line, the goal turn's UserMsg)
    -- only consulted when Cfg.OrientTaskAware is on, in which case
    the MEMORY section slices to task-relevant sections instead of
    whole files. }
  Result.Options.SystemPrompt  := BuildSystemPrompt(Cfg, A.SystemPrompt,
                                                    Reg <> nil, TaskHint,
                                                    A.Mode, A.NoPlan);
  Result.Mode := A.Mode;
  Result.Options.ThinkingLevel := A.Thinking;
  if A.MaxTokens > 0 then Result.Options.MaxTokens := A.MaxTokens;
  { Prompt caching threads through TChatOptions so each provider
    builder can decide what to emit (Anthropic: cache_control on
    system + last tool; OpenAI: prompt_cache_key). CacheKey is set
    per-turn in RunInteractive (it's the persistent session id);
    RunSingleTurn leaves it empty since one-shots aren't worth
    keying. }
  ApplyPromptCacheConfig(Result.Options, Cfg.PromptCache);
  { Identity for the CLI path. $USER on POSIX, %USERNAME% on Windows;
    falls back to 'local' so the canonical id is never empty. Channels
    + gateway override this with their platform-specific sender. }
  Result.Identity := MakeIdentity('cli',
    GetEnvironmentVariable({$IFDEF MSWINDOWS}'USERNAME'{$ELSE}'USER'{$ENDIF}));
  if Result.Identity.UserId = '' then Result.Identity.UserId := 'local';
  Result.OnText        := nil;
  Result.OnToolCall    := Handlers.OnToolCall;
  Result.OnToolResult  := Handlers.OnToolResult;
  { Conversation-history compaction: on by default, tunable via the
    "compaction" block in config.json. The tool loop only pays the
    cost of a summariser round when the running history actually
    trips the threshold, so short conversations are unaffected. }
  Result.CompactEnabled := Cfg.Compaction.Enabled;
  Result.CompactOpts    := DefaultCompactOptions;
  Result.CompactOpts.ThresholdTokens    := Cfg.Compaction.ThresholdTokens;
  Result.CompactOpts.RetainBudgetTokens := Cfg.Compaction.RetainBudgetTokens;
  Result.CompactOpts.KeepRecentTurns    := Cfg.Compaction.KeepRecentTurns;
  Result.CompactOpts.SummaryBudget      := Cfg.Compaction.SummaryBudget;
  { Before a compaction drops the transcript's older half, refresh
    the session's working state from it -- the paths edited and
    commands run in that half would otherwise vanish from both the
    history AND the cross-turn snapshot that exists to outlive it.
    Only wired when a session is being persisted; MetaRef is nil on
    one-shot runs, and the handler does nothing then. }
  Result.CompactOpts.OnBefore := Handlers.OnBeforeCompact;
  { LLM-guided pruning ahead of compaction. Off unless configured; the
    pruner runs on the PLAN model, because deciding what a session still
    needs is a judgement rather than a transformation -- the same reason
    plan mode exists. Empty plan_model falls back to the loop's own. }
  Result.PruneEnabled       := Cfg.Prune.Enabled;
  Result.PruneMinIterations := Cfg.Prune.MinIterations;
  Result.PruneOpts          := DefaultPruneOptions;
  Result.PruneOpts.Enabled            := Cfg.Prune.Enabled;
  Result.PruneOpts.ThresholdTokens    := Cfg.Prune.ThresholdTokens;
  Result.PruneOpts.ProtectTailTokens  := Cfg.Prune.ProtectTailTokens;
  Result.PruneOpts.MinCandidateTokens := Cfg.Prune.MinCandidateTokens;
  Result.PruneOpts.PreviewChars       := Cfg.Prune.PreviewChars;
  Result.PruneOpts.Model              := Cfg.PlanModel;
  Result.PruneOpts.OnBefore           := Handlers.OnBeforePrune;
  { Forward the tool-output truncation cap (per-tool-result bytes)
    from config. 0 = off (legacy verbatim behaviour); when an
    operator sets it, RunToolLoop diverts oversize results to the
    OutputCache and replaces them with head+tail+handle. The
    `tool_output_get` tool is registered alongside the other core
    tools in RegisterFSTools' caller (Cmd.Agent / Cmd.TUI). }
  Result.ToolOutputCap := Cfg.ToolOutputCap;
  Result.ProviderRetryAttempts  := Cfg.ProviderRetryAttempts;
  Result.ProviderRetryBackoffMs := Cfg.ProviderRetryBackoffMs;
  { Stream-reliability: same default-shape pattern -- forwarded as
    a struct copy so the loop's primary Provider.Chat call goes
    through ChatWithEmptyRetry. Loop-side fallback walk is
    unaffected; this only catches the empty-turn brownout shape. }
  Result.StreamReliability := Cfg.StreamReliability;
end;

{ One-line per-turn token summary. Cache fields only appear when
  non-zero so a non-Anthropic / cache-disabled run stays clean.
  cache_w = cache_creation (a one-time write cost -- 25% premium on
  Anthropic but only on the first turn); cache_r = cache_read
  (the win -- 90% discount on Anthropic, 50% on OpenAI). }
function FormatTokenLine(const U: TUsageInfo; Iterations: Integer): string;
begin
  Result := Format('  [tokens in=%d out=%d', [U.InputTokens, U.OutputTokens]);
  if U.CacheReadTokens    > 0 then Result := Result + Format(' cache_r=%d', [U.CacheReadTokens]);
  if U.CacheCreatedTokens > 0 then Result := Result + Format(' cache_w=%d', [U.CacheCreatedTokens]);
  Result := Result + Format(', iters=%d]', [Iterations]);
end;

(* Total prompt tokens the model actually saw, summed across cached
   and uncached portions. Anthropic reports input_tokens EXCLUDING
   cached/written tokens (those are separate fields), so a Reads +
   InputTokens denominator is needed for a correct hit-rate. OpenAI
   reports cached_tokens as a SUBSET of prompt_tokens -- InputTokens
   alone is the right denominator. We distinguish by provider name
   because cache_creation_tokens can be zero on a pure-read turn,
   so "presence of CacheCreatedTokens" isn't a reliable Anthropic
   marker. Codex P2 on PR #118. *)
function TotalPromptTokens(const U: TUsageInfo; const ProviderName: string): Int64;
begin
  if ProviderName = 'anthropic' then
    Result := Int64(U.InputTokens) + U.CacheReadTokens + U.CacheCreatedTokens
  else
    Result := U.InputTokens;
end;

function MaybeRender(const Cfg: TConfig; const S: string): string; inline;
{ Wraps the LLM's output in PasClaw.Markdown.Render when the
  operator hasn't turned it off (Cfg.RenderMarkdown, default True).
  Markdown rendering targets terminal surfaces -- pasclaw agent and
  pasclaw tui -- and is opt-out for operators who pipe the output
  through other tools that want the raw markdown. }
begin
  if Cfg.RenderMarkdown then Result := RenderMarkdown(S)
  else                       Result := S;
end;

function RunSingleTurn(const Cfg: TConfig; const A: TAgentArgs;
                       const Prompt: string): Boolean;
(* Returns True on a clean turn (provider resolved, RunToolLoop
   returned True) and False on either failure mode. Cmd_Agent_Run
   maps False -> process exit code 1 so scripts using --quiet (or
   anything else parsing $?) treat a missing provider or a failed
   tool loop as a failed invocation. PR #243 P2: prior behaviour
   always exited 0 even when the assistant produced no reply,
   which silently masked provider-config errors in machine-readable
   pipelines. *)
var
  Provider: ILLMProvider;
  Err: string;
  Msgs: array of TMessage;
  Reg: TToolRegistry;
  Handlers: TLoopHandlers;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  Model: string;
  MCPClients: TMCPClientList;
  Spawn: TSpawnTool;
  BgCoord: TBackgroundSpawnCoordinator;
  OneShotSessionId: string;
  PersistedSession: TSession;       { non-nil only when A.Session is set (PR #292 P1) }
  i: Integer;
  RoutedNm: string;
begin
  { Default to True; only flip to False on a known failure path.
    Any code path that hits Exit before producing a real assistant
    reply MUST set Result := False first so Cmd_Agent_Run can map
    it to a non-zero process exit. }
  Result := True;
  if not PickProvider(Cfg, A, Provider, Err) then
  begin
    Result := False;
    if A.Quiet then
      { Quiet mode: a single undecorated line so scripts have
        SOMETHING on stdout to surface, without the banner-y "(offline
        preview)" / "You: ..." mock-conversation rendering. Exit
        code (non-zero, via Cmd_Agent_Run) is the authoritative
        success signal. }
      PrintLn('pasclaw error: provider not configured (' + Err + ')')
    else
    begin
      PrintLn(Ansi.Yellow + '(offline preview -- ' + Err + ')' + Ansi.Reset);
      PrintLn('You: ' + Prompt);
      PrintLn('Assistant: <provider not configured; run `pasclaw onboard`>');
    end;
    Exit;
  end;

  { Resolve the effective model BEFORE registering the spawn tool.
    MaybeRegisterSpawnTool captures Model into the TSubagentContext
    by value; if we hand it an empty string the child subagent loop
    will fall back to the provider's GetDefaultModel instead of the
    user's --model selection. RunInteractive already does this in the
    right order -- fixing the asymmetry here. (Codex P2 on PR #107.) }
  if A.Model <> '' then Model := A.Model else Model := Cfg.DefaultModel;

  Reg := nil;
  if not A.NoTools then
  begin
    Reg := NewBuiltinRegistry((not A.NoHashline) and Cfg.HashlineEnabled,
                              Cfg.VaultToolsEnabled,
                              HasConfiguredWebSearchProvider(Cfg),
                              Cfg.WebFetchEnabled,
                              (Cfg.ToolOutputCap > 0)
                                or Cfg.CondenseReversible,
                              Cfg.CronToolEnabled,
                              Cfg.DatabaseJSON,
                              Cfg.DesktopToolsEnabled);
    RegisterSkillManageTool(Reg, Cfg);
    RegisterSkillDisclosureTools(Reg, Cfg);
  end;
  MCPClients := ConnectMCP(Cfg, Reg, A.NoMCP);
  Spawn := MaybeRegisterSpawnTool(Cfg, Provider, Reg, Model);
  BgCoord := MaybeRegisterBackgroundSpawnTools(Cfg, Provider, Reg, Model);
  Handlers := TLoopHandlers.Create;
  { Propagate --quiet so the per-tool decoration the loop fires
    through the OnToolCall / OnToolResult callbacks no-ops. Combined
    with the header + token-line skips below, the only thing
    RunSingleTurn writes to stdout in quiet mode is the assistant's
    final reply (plus a single trailing newline). }
  Handlers.Quiet := A.Quiet;
  Handlers.Verbose := A.Verbose;
  { Allocate a one-shot session id so the active shell backend
    (docker, ssh, ...) actually isolates this turn. Codex P1 on
    PR #233: an empty SessionId let the docker backend fall back to
    RunOneShot ON THE HOST, bypassing isolation -- so we always set a
    real id here. The id is purely for the backend (one-shot turns
    aren't persisted as PasClaw sessions); short prefix avoids docker's
    64-char container-name cap.
    Lazy docker (PR #286): we set the current session id but no longer
    pre-spawn the container -- TDockerShellBackend.Exec spawns it on the
    first shell tool call, so a turn that never shells out never touches
    Docker and `pasclaw agent` doesn't stall at startup when Docker is
    down/slow. }
  (* Codex PR #292 P1: when --session <id> is supplied alongside -m,
     persist the one-shot turn to that session file. Previously the
     one-shot path ignored A.Session entirely and used an internal
     `oneshot-...` id purely for shell-backend isolation, so a
     scripted caller (notably `pasclaw profile bench`) reading back
     workspace/sessions/<id>.json would find nothing -- token /
     turn / tool-call columns silently stayed at zero even when
     stats_collection_enabled was on. Honouring --session here doesn't
     change pre-existing behaviour for callers that don't pass it. *)
  PersistedSession := nil;
  if A.Session <> '' then
  begin
    PersistedSession := NewStampedSession(A.Session, Cfg);
    Handlers.MetaRef := @PersistedSession.Meta;
    OneShotSessionId := A.Session;
  end
  else
    OneShotSessionId := 'oneshot-' + FormatDateTime('yyyymmdd-hhnnss', Now) +
                        '-' + IntToHex(Random(1 shl 24), 6);
  SetCurrentSessionId(OneShotSessionId);
  try
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, Prompt);

    LoopCfg := BuildLoopConfig(Cfg, Provider, Reg, Model, A, Handlers, Prompt);
    { Auto-router (opt-in) on the one-shot path too -- shared helper, no-op
      unless Cfg.AutoRouter.Enabled. }
    ApplyAutoRoute(LoopCfg, Cfg, Msgs, RoutedNm);

    if not A.Quiet then
      PrintLn(Ansi.Cyan + 'assistant' + Ansi.Reset +
              ' (' + Provider.GetName + '/' + Model + '):');
    if RunToolLoop(LoopCfg, Msgs, Loop) then
    begin
      { In quiet mode skip MaybeRender -- the markdown renderer adds
        ANSI styling that defeats the "machine-readable plain text"
        contract --quiet promises. The model's raw reply text goes
        straight to stdout, no decoration. }
      if A.Quiet then
        PrintLn(Loop.Content)
      else
        PrintLn(MaybeRender(Cfg, Loop.Content));
      { The tool loop stopped at the iteration cap mid-task -- tell the
        operator instead of letting the partial answer look complete. In
        quiet mode route it to stderr so stdout stays machine-readable.
        One-shot history only carries over when --session is set, so the
        "reply continue" hint is gated on that. }
      if Loop.HitMaxIterations then
        if A.Quiet then
          PrintErr(FormatMaxIterNotice(Loop, A.MaxIterations, '--max-iterations N', A.Session <> '') + sLineBreak)
        else
          PrintLn(Ansi.Yellow + FormatMaxIterNotice(Loop, A.MaxIterations, '--max-iterations N', A.Session <> '') + Ansi.Reset);
      { Self-improving skills: after the user-facing reply is printed,
        consider distilling this turn into a reusable skill. No-op
        unless the distiller is enabled and the turn was non-trivial. }
      MaybeDistillTurn(Cfg, Provider, Model, Prompt, Loop.Content,
                       DistillTranscriptFromMessages(Loop.FinalMessages),
                       Loop.ToolCallsDispatched);
    end
    else
    begin
      Result := False;
      { Failed loop: a "(loop failed)" sentinel still goes to stdout
        in both modes so a caller eyeballing the output sees what
        happened, but Result := False bubbles up so Cmd_Agent_Run
        exits non-zero (PR #243 P2 fix). }
      PrintLn('(loop failed)');
    end;
    if (not A.Quiet) and
       (Loop.TotalUsage.InputTokens + Loop.TotalUsage.OutputTokens > 0) then
      PrintLn(Ansi.Dim + FormatTokenLine(Loop.TotalUsage, Loop.Iterations) + Ansi.Reset);

    (* Persist the one-shot session when the operator asked. Includes
       user prompt + final assistant content + tool history, plus
       AccumulateTurnStats when stats_collection_enabled so the bench
       harness (and any other reader) sees real token / turn / tool-
       call counters. *)
    if PersistedSession <> nil then
    begin
      SetLength(PersistedSession.Messages, Length(Loop.FinalMessages));
      for i := 0 to High(Loop.FinalMessages) do
        PersistedSession.Messages[i] := Loop.FinalMessages[i];
      PersistedSession.Meta.Model    := Model;
      if Provider <> nil then
        PersistedSession.Meta.Provider := Provider.GetName;
      if Cfg.StatsCollectionEnabled then
        AccumulateTurnStats(PersistedSession.Meta,
                            Loop.TotalUsage.InputTokens,
                            Loop.TotalUsage.OutputTokens,
                            Loop.TotalUsage.CacheReadTokens,
                            Loop.TotalUsage.CacheCreatedTokens,
                            Loop.ToolCallsDispatched,
                            Loop.TruncatedBytesSaved);
      PersistedSession.AutoTitle;
      PersistedSession.Touch;
      PersistedSession.Save;
    end;
  finally
    CloseShellSession(OneShotSessionId);
    SetCurrentSessionId('');
    if PersistedSession <> nil then PersistedSession.Free;
    Handlers.Free;
    FreeMCPClients(MCPClients);
    if Spawn <> nil then Spawn.Free;
    Reg.Free;
  end;
end;

{ ============================================================
  Goal-driven one-shot path (Phase 3 of plan/build pairing).

  RunSingleTurnGoalDriven wraps the one-shot RunToolLoop call in a
  PasClaw.Agent.Goals.TGoalRunner instead of running it once. The
  Ralph judge loop pumps turns: agent runs -> judge verdicts
  (MET / CONTINUE / FAILED) -> next iteration with the judge's
  suggestion as the new user message, up to MaxIters.

  Cmd.Build --goal sets A.GoalObjective to PLAN.md's parsed Goal
  line, and `pasclaw agent --goal-objective "<text>"` lets operators
  drive the same machinery directly. Interactive mode does NOT
  consume A.GoalObjective -- REPL operators use /goal instead.

  Deliberately skipped vs the regular RunSingleTurn:
    - Session persistence: a goal-driven run doesn't write to
      workspace/sessions/. Operators wanting goal results in their
      session history can re-pipe via `pasclaw agent --session <id>`
      after the fact. Future work could add per-iteration persistence.
    - SkillDistiller post-turn hook: the distiller assumes one
      coherent task per turn; goal loops produce N iterations and
      the right distillation moment is unclear. Skipped for V1.
    - Auto-router per-iteration: goal CONTINUE turns are mid-task
      and shouldn't route to a cheaper tier. Stays on the primary
      model. Mirrors the interactive /goal handler.
  ============================================================ }

type
  TOneShotGoalCallbacks = class
    Cfg:      TConfig;
    A:        TAgentArgs;
    Provider: ILLMProvider;
    Reg:      TToolRegistry;
    Model:    string;
    Handlers: TLoopHandlers;
    function  TurnFn(const UserMsg: string;
                      var Hist: TMessageArray;
                      out Reply: string): Boolean;
    procedure Progress(IterNo, MaxIter: Integer; const Reply: string);
  end;

function TOneShotGoalCallbacks.TurnFn(const UserMsg: string;
                                       var Hist: TMessageArray;
                                       out Reply: string): Boolean;
{ TGoalTurnFn implementation -- one agent turn during the Ralph loop.
  Slimmed-down counterpart to TGoalCmdCallbacks.TurnFn in the
  interactive path: no session, no background-spawn drain key, no
  systems-prompt-override threading (the goal-driven one-shot doesn't
  persist across turns by design). }
var
  Loop:    TToolLoopResult;
  LoopCfg: TToolLoopConfig;
begin
  Result := False;
  Reply  := '';
  SetLength(Hist, Length(Hist) + 1);
  Hist[High(Hist)] := MakeMessage(mrUser, UserMsg);

  LoopCfg := BuildLoopConfig(Cfg, Provider, Reg, Model, A, Handlers, UserMsg);
  if not RunToolLoop(LoopCfg, Hist, Loop) then Exit;

  { Mirror the RunSingleTurn / interactive convention: RunToolLoop
    returns Hist with tool transcripts but the final assistant text
    in Loop.Content -- append it explicitly so the judge call (which
    reads the most recent assistant message) sees it. Codex P1 on
    PR #223 covers the original interactive fix; same shape here. }
  Hist := Loop.FinalMessages;
  if Trim(Loop.Content) <> '' then
  begin
    SetLength(Hist, Length(Hist) + 1);
    Hist[High(Hist)] := MakeMessage(mrAssistant, Loop.Content);
  end;
  Reply := Loop.Content;
  if Trim(Reply) = '' then Reply := '(no reply)';
  Result := True;
end;

procedure TOneShotGoalCallbacks.Progress(IterNo, MaxIter: Integer;
                                          const Reply: string);
begin
  { Quiet mode: no per-iteration chatter, just the final reply.
    Verbose mode: per-iteration banner so a long goal loop doesn't
    sit silent for tens of seconds. }
  if A.Quiet then Exit;
  PrintLn;
  PrintLn(Ansi.Dim + Format('— goal iter %d/%d —', [IterNo, MaxIter]) + Ansi.Reset);
  if Trim(Reply) <> '' then
    PrintLn(MaybeRender(Cfg, Reply));
end;

function VerdictName(V: TGoalVerdict): string;
begin
  case V of
    gvMet:              Result := 'MET';
    gvFailed:           Result := 'FAILED';
    gvBudgetExhausted:  Result := 'BUDGET-EXHAUSTED';
    gvAborted:          Result := 'ABORTED';
  else
    Result := 'UNKNOWN';
  end;
end;

function RunSingleTurnGoalDriven(const Cfg: TConfig; const A: TAgentArgs;
                                  const Prompt: string): Boolean;
{ Goal-driven counterpart to RunSingleTurn. Setup mirrors the regular
  one-shot path but the per-iteration RunToolLoop call is wrapped in
  TGoalRunner.

  Returns True when the loop ended with MET or BUDGET-EXHAUSTED (the
  latter is "we tried hard but ran out of turns" -- still a successful
  best-effort run). Returns False on FAILED, ABORTED, or any
  setup-time failure (no provider, etc.) so Cmd_Agent_Run maps it to
  exit 1. Phase 3 of the plan/build pairing. }
var
  Provider:   ILLMProvider;
  Err, Model: string;
  Reg:        TToolRegistry;
  Handlers:   TLoopHandlers;
  MCPClients: TMCPClientList;
  Spawn:      TSpawnTool;
  BgCoord:    TBackgroundSpawnCoordinator;
  Msgs:       TMessageArray;
  Callbacks:  TOneShotGoalCallbacks;
  Runner:     TGoalRunner;
  MaxIter:    Integer;
  R:          TGoalResult;
  OneShotSessionId: string;
begin
  Result := False;
  if not PickProvider(Cfg, A, Provider, Err) then
  begin
    PrintErr(Err);
    Exit;
  end;
  if A.Model <> '' then Model := A.Model else Model := Cfg.DefaultModel;

  Reg := nil;
  if not A.NoTools then
  begin
    Reg := NewBuiltinRegistry((not A.NoHashline) and Cfg.HashlineEnabled,
                              Cfg.VaultToolsEnabled,
                              HasConfiguredWebSearchProvider(Cfg),
                              Cfg.WebFetchEnabled,
                              (Cfg.ToolOutputCap > 0)
                                or Cfg.CondenseReversible,
                              Cfg.CronToolEnabled,
                              Cfg.DatabaseJSON,
                              Cfg.DesktopToolsEnabled);
    RegisterSkillManageTool(Reg, Cfg);
    RegisterSkillDisclosureTools(Reg, Cfg);
  end;
  MCPClients := ConnectMCP(Cfg, Reg, A.NoMCP);
  Spawn      := MaybeRegisterSpawnTool(Cfg, Provider, Reg, Model);
  BgCoord    := MaybeRegisterBackgroundSpawnTools(Cfg, Provider, Reg, Model);
  Handlers   := TLoopHandlers.Create;
  { Propagate --quiet so per-tool decoration fired through
    OnToolCall / OnToolResult no-ops. Mirrors RunSingleTurn at
    Cmd.Agent.pas:572. Codex P2 reviewer on PR #317: without this,
    pasclaw build --goal would print tool-call/result previews to
    stdout during each Ralph iteration even though Cmd.Build always
    injects -q, polluting cog reply.txt and other subprocess
    consumers that rely on -q meaning "only the final assistant
    reply". The verbose banner + verdict lines are still gated on
    `not A.Quiet` further down so non-quiet operators still see
    them. }
  Handlers.Quiet := A.Quiet;
  Handlers.Verbose := A.Verbose;

  { Per-process shell-backend session id, same shape as RunSingleTurn.
    Lazy docker container -- only spawned on the first shell tool call. }
  OneShotSessionId := 'oneshot-goal-' + FormatDateTime('yyyymmdd-hhnnss', Now) +
                      '-' + IntToHex(Random(1 shl 24), 6);
  SetCurrentSessionId(OneShotSessionId);

  try
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, Prompt);

    MaxIter := A.GoalMaxIters;
    if MaxIter <= 0 then MaxIter := DefaultGoalMaxIter;

    if not A.Quiet then
    begin
      PrintLn(Ansi.Bold + '— goal —' + Ansi.Reset + ' ' + A.GoalObjective +
              Ansi.Dim + Format('  (budget=%d)', [MaxIter]) + Ansi.Reset);
      PrintLn(Ansi.Cyan + 'assistant' + Ansi.Reset +
              ' (' + Provider.GetName + '/' + Model + '):');
    end;

    Callbacks := TOneShotGoalCallbacks.Create;
    Callbacks.Cfg      := Cfg;
    Callbacks.A        := A;
    Callbacks.Provider := Provider;
    Callbacks.Reg      := Reg;
    Callbacks.Model    := Model;
    Callbacks.Handlers := Handlers;
    try
      Runner := TGoalRunner.Create(Provider, Model, MaxIter, Callbacks.TurnFn);
      try
        Runner.OnProgress := Callbacks.Progress;
        R := Runner.Run(A.GoalObjective, Msgs);
      finally
        Runner.Free;
      end;
    finally
      Callbacks.Free;
    end;

    { Final reply. Quiet mode emits the last assistant text only (cog
      caller pipes it); verbose mode emits a verdict banner + reason. }
    if A.Quiet then
      PrintLn(R.LastReply)
    else
    begin
      PrintLn;
      PrintLn(Ansi.Bold + '— verdict —' + Ansi.Reset + ' ' + VerdictName(R.Verdict) +
              ' (iterations=' + IntToStr(R.Iterations) + ')');
      if R.Reason <> '' then
        PrintLn(Ansi.Dim + R.Reason + Ansi.Reset);
    end;

    Result := R.Verdict in [gvMet, gvBudgetExhausted];
  finally
    CloseShellSession(OneShotSessionId);
    SetCurrentSessionId('');
    Handlers.Free;
    FreeMCPClients(MCPClients);
    if Spawn <> nil then Spawn.Free;
    if Reg <> nil then Reg.Free;
  end;
end;

type
  PMessageArray = ^TMessageArray;
  PStringRef    = ^string;

  { Bundles the per-/goal-call state that GoalRunner's of-object
    callbacks need into a real method-of-object form. The
    TGoalTurnFn / TGoalProgressFn callbacks in PasClaw.Agent.Goals
    are `of object`; Delphi (dcc64) rejects assigning a nested
    procedure to an of-object type (FPC tolerates it via the
    `is nested` calling convention, but Delphi has no equivalent),
    so the /goal handler bundles the captures into this helper and
    hands TurnFn / Progress as proper method pointers. The pMsgs /
    pSysPromptOverride fields point back at RunInteractive's local
    vars so the runner can mutate them in place, matching what the
    original nested-procedure form did via lexical capture. }
  TGoalCmdCallbacks = class
    Cfg:                TConfig;
    A:                  TAgentArgs;
    Provider:           ILLMProvider;
    Reg:                TToolRegistry;
    Model:              string;
    Handlers:           TLoopHandlers;
    Session:            TSession;
    BgCoord:            TBackgroundSpawnCoordinator;
    pMsgs:              PMessageArray;
    pSysPromptOverride: PStringRef;
    procedure PersistSessionCb;
    function  TurnFn(const UserMsg: string;
                      var Hist: TMessageArray;
                      out Reply: string): Boolean;
    procedure Progress(IterNo, MaxIter: Integer; const Reply: string);
  end;

procedure TGoalCmdCallbacks.PersistSessionCb;
var j: Integer;
begin
  if Session = nil then Exit;
  SetLength(Session.Messages, Length(pMsgs^));
  for j := 0 to High(pMsgs^) do Session.Messages[j] := pMsgs^[j];
  Session.Meta.SystemPromptOverride := pSysPromptOverride^;
  Session.Meta.Model := Model;
  if Provider <> nil then Session.Meta.Provider := Provider.GetName;
  Session.AutoTitle;
  Session.Touch;
  Session.Save;
end;

function TGoalCmdCallbacks.TurnFn(const UserMsg: string;
                                   var Hist: TMessageArray;
                                   out Reply: string): Boolean;
{ TGoalTurnFn implementation -- one agent turn during the Ralph loop.
  Mirrors the relevant subset of RunInteractive's main `while Inputs
  do` body: append user message, build the same LoopCfg, run BeginTurn
  (checkpoints) then RunToolLoop, swap Hist for the loop's compaction-
  aware history. Compaction summary survives across iterations because
  pSysPromptOverride^ is the enclosing RunInteractive's var.

  Deliberately skips a couple of bells the main loop has on each user-
  typed turn (auto-router, working-state prefix, /think one-shot):
  those depend on UI state that doesn't apply to the judge-driven
  Continue stream. Operators who want them per-turn on a goal run
  should drive each step interactively. }
var
  GLoop: TToolLoopResult;
  GCfg:  TToolLoopConfig;
  k:     Integer;
begin
  Result := False;
  Reply := '';
  SetLength(Hist, Length(Hist) + 1);
  Hist[High(Hist)] := MakeMessage(mrUser, UserMsg);

  GCfg := BuildLoopConfig(Cfg, Provider, Reg, Model, A, Handlers, UserMsg);
  if pSysPromptOverride^ <> '' then
    GCfg.Options.SystemPrompt := pSysPromptOverride^;
  if Session <> nil then
  begin
    GCfg.Options.CacheKey := Session.Meta.Id;
    GCfg.SteeringKey      := Session.Meta.Id;
    if BgCoord <> nil then
    begin
      BgCoord.SetKey(Session.Meta.Id);
      GCfg.BackgroundDrainKey := Session.Meta.Id;
    end;
  end;

  BeginTurn;
  if not RunToolLoop(GCfg, Hist, GLoop) then Exit;

  { RunToolLoop returns FinalMessages BEFORE the final non-tool
    assistant text -- the regular CLI / TUI paths explicitly append
    Loop.Content afterwards. Mirror that here, otherwise the
    assistant's actual answer gets dropped from history and the next
    judge-driven turn (and the persisted session) only see the tool
    transcript. Codex P1 on PR #223. }
  Hist := GLoop.FinalMessages;
  if Trim(GLoop.Content) <> '' then
  begin
    SetLength(Hist, Length(Hist) + 1);
    Hist[High(Hist)] := MakeMessage(mrAssistant, GLoop.Content);
  end;
  Reply := GLoop.Content;
  if Trim(Reply) = '' then Reply := '(no reply)';
  if GLoop.FinalSystemPrompt <> '' then
    pSysPromptOverride^ := GLoop.FinalSystemPrompt;

  { Mirror Msgs from the local var the main loop reads on subsequent
    iterations. The goal runner walks Hist; copy it back so a follow-
    up user turn (after the goal loop ends) picks up the same compacted
    state. pMsgs^ is the enclosing RunInteractive's array; rebuilding
    it keeps /undo, /compact, /status all consistent. }
  SetLength(pMsgs^, Length(Hist));
  for k := 0 to High(Hist) do pMsgs^[k] := Hist[k];
  PersistSessionCb;
  Result := True;
end;

procedure TGoalCmdCallbacks.Progress(IterNo, MaxIter: Integer; const Reply: string);
begin
  PrintLn(Ansi.Dim + Format('— goal iter %d/%d —', [IterNo, MaxIter]) + Ansi.Reset);
  PrintLn(Ansi.Cyan + 'assistant' + Ansi.Reset + ': ' +
          MaybeRender(Cfg, Reply));
end;

procedure RunInteractive(const Cfg: TConfig; var A: TAgentArgs);
var
  Line: string;
  Provider: ILLMProvider;
  Err: string;
  Msgs: TMessageArray;
  Reg: TToolRegistry;
  Handlers: TLoopHandlers;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  Model: string;
  Offline: Boolean;
  i: Integer;
  Names: TStringArray;
  MCPClients: TMCPClientList;
  Spawn: TSpawnTool;
  BgCoord: TBackgroundSpawnCoordinator;
  SystemPromptOverride: string;   { tracks the compacted system prompt across turns }
  WorkingStateBlock: string;       { per-turn prefix from Session.Meta.WorkingState }
  ThinkingOn: Boolean;             { toggled by /think; cleared each turn after sending }
  { Auto-router state. PrimaryProvider keeps the originally-picked
    provider so we can restore after a routed turn, and so the
    routed turn can prepend it to the fallback list. EasyProvider
    is built lazily on first need, cached for the rest of the
    session. PrimaryFallbacks remembers the fallback chain we'd
    use on a non-routed turn so we can swap it out for the routed
    chain ("original primary + original fallbacks") and back. }
  PrimaryProvider:   ILLMProvider;
  EasyProvider:      ILLMProvider;
  PrimaryFallbacks:  TLLMProviderArray;
  RoutedProviderNm:  string;
  RoutedModelOverride: string;
  RoutedScoreVal:    Double;
  RoutedThisTurn:    Boolean;
  CompactOptsLocal: TCompactOptions;
  CompactedLiveOpts: TChatOptions;
  Session: TSession;               { always non-nil in interactive mode }
  TotalCacheRead, TotalCacheWrite, TotalPrompt: Int64;   { cumulative across turns for /status }

  procedure PersistSession;
  var j: Integer;
  begin
    if Session = nil then Exit;
    SetLength(Session.Messages, Length(Msgs));
    for j := 0 to High(Msgs) do Session.Messages[j] := Msgs[j];
    Session.Meta.SystemPromptOverride := SystemPromptOverride;
    Session.Meta.Model := Model;
    if Provider <> nil then Session.Meta.Provider := Provider.GetName;
    Session.AutoTitle;
    Session.Touch;
    Session.Save;
  end;

  procedure RewireCheckpoints;
  { Point the checkpoints module at the active session. No-op when
    the operator hasn't opted in. Called every time Session is
    swapped (initial create, /reset --> new id, /new). The per-turn
    BeginTurn call before RunToolLoop fires the actual snapshot
    boundary; this just sets the session subdir. Mirrors the TUI's
    RewireCheckpoints. }
  var
    CC: TCheckpointConfig;
  begin
    if Session = nil then Exit;
    CC.Enabled   := Cfg.CheckpointsEnabled;
    CC.SessionId := Session.Meta.Id;
    CC.Root      := JoinPath(JoinPath(GetHome, ActiveWorkspaceName), 'checkpoints');
    CC.KeepLast  := Cfg.CheckpointsKeepLast;
    InitCheckpoints(CC);
  end;

  procedure HandleGoalCommand(const Args: string);
  { /goal <objective> or /goal --max N <objective>. Spins up a
    TGoalRunner that pumps Callbacks.TurnFn through up to MaxIter
    judge-arbitrated turns. The judge model defaults to the
    primary Model -- the operator can wire a cheaper one via
    Cfg.AutoRouter.EasyModel in a follow-up.

    Callbacks wraps the per-turn / per-progress state in a method-
    of-object form because TGoalTurnFn / TGoalProgressFn are
    `of object` and dcc64 refuses to assign a nested procedure to
    an of-object type. See TGoalCmdCallbacks above. }
  var
    Runner: TGoalRunner;
    Callbacks: TGoalCmdCallbacks;
    Trimmed, Goal: string;
    MaxIter: Integer;
    R: TGoalResult;
    SpacePos: Integer;
    NumStr: string;
    HistAlias: TMessageArray;
    k: Integer;
  begin
    Trimmed := Trim(Args);
    MaxIter := DefaultGoalMaxIter;
    if Copy(Trimmed, 1, 6) = '--max ' then
    begin
      Trimmed := Trim(Copy(Trimmed, 7, MaxInt));
      SpacePos := Pos(' ', Trimmed);
      if SpacePos > 0 then
      begin
        NumStr := Copy(Trimmed, 1, SpacePos - 1);
        MaxIter := StrToIntDef(NumStr, DefaultGoalMaxIter);
        if MaxIter <= 0 then MaxIter := DefaultGoalMaxIter;
        Goal := Trim(Copy(Trimmed, SpacePos + 1, MaxInt));
      end
      else
        Goal := '';
    end
    else
      Goal := Trimmed;
    if Goal = '' then
    begin
      PrintLn(Ansi.Yellow + '/goal: needs an objective. Usage: /goal [--max N] <objective>' + Ansi.Reset);
      Exit;
    end;
    if Provider = nil then
    begin
      PrintLn(Ansi.Yellow + '/goal: no provider configured (offline mode)' + Ansi.Reset);
      Exit;
    end;
    PrintLn(Ansi.Bold + '— goal —' + Ansi.Reset + ' ' + Goal +
            Ansi.Dim + Format('  (budget=%d)', [MaxIter]) + Ansi.Reset);

    Callbacks := TGoalCmdCallbacks.Create;
    Callbacks.Cfg                := Cfg;
    Callbacks.A                  := A;
    Callbacks.Provider           := Provider;
    Callbacks.Reg                := Reg;
    Callbacks.Model              := Model;
    Callbacks.Handlers           := Handlers;
    Callbacks.Session            := Session;
    Callbacks.BgCoord            := BgCoord;
    Callbacks.pMsgs              := @Msgs;
    Callbacks.pSysPromptOverride := @SystemPromptOverride;

    Runner := TGoalRunner.Create(Provider, Model, MaxIter, Callbacks.TurnFn);
    try
     try
      Runner.OnProgress := Callbacks.Progress;
      HistAlias := nil;
      SetLength(HistAlias, Length(Msgs));
      for k := 0 to High(Msgs) do HistAlias[k] := Msgs[k];
      R := Runner.Run(Goal, HistAlias);
      SetLength(Msgs, Length(HistAlias));
      for k := 0 to High(HistAlias) do Msgs[k] := HistAlias[k];

      case R.Verdict of
        gvMet:
          PrintLn(Ansi.Green + '✓ goal met' + Ansi.Reset +
                  Format(' after %d iter(s)', [R.Iterations]));
        gvFailed:
          PrintLn(Ansi.Red + '✗ judged FAILED' + Ansi.Reset +
                  Format(' after %d iter(s)', [R.Iterations]));
        gvBudgetExhausted:
          PrintLn(Ansi.Yellow + '… budget exhausted' + Ansi.Reset +
                  Format(' (%d iter(s))', [R.Iterations]));
        gvAborted:
          PrintLn(Ansi.Yellow + '… aborted' + Ansi.Reset +
                  Format(' after %d iter(s)', [R.Iterations]));
      end;
      if Trim(R.Reason) <> '' then
        PrintLn(Ansi.Dim + '  judge: ' + Trim(R.Reason) + Ansi.Reset);
     finally
      Runner.Free;
     end;
    finally
      Callbacks.Free;
    end;
  end;

  procedure HandleUndoCommand(const Args: string);
  { `/undo` -> rewind 1 turn; `/undo N` -> rewind N turns. Restores
    file contents captured at the start of each rewound turn. Files
    the model created inside the rewound window are left in place
    (v1 conservative semantic). Mirrors the TUI's HandleUndoCommand
    so both interactive surfaces feel the same. }
  var
    N, k: Integer;
    Restored: TRestoredFileArray;
    UndoErr, Trimmed: string;
  begin
    Trimmed := Trim(Args);
    if Trimmed = '' then
      N := 1
    else
      N := StrToIntDef(Trimmed, -1);
    if N <= 0 then
    begin
      PrintLn(Ansi.Yellow + '/undo: argument must be a positive turn count' + Ansi.Reset);
      Exit;
    end;
    if not UndoTurns(N, Restored, UndoErr) then
    begin
      PrintLn(Ansi.Yellow + '/undo: ' + UndoErr + Ansi.Reset);
      Exit;
    end;
    if Length(Restored) = 0 then
      PrintLn(Ansi.Dim + Format('/undo %d: no files to restore', [N]) + Ansi.Reset)
    else
    begin
      PrintLn(Ansi.Green + Format('/undo %d: restored %d file(s)',
                                   [N, Length(Restored)]) + Ansi.Reset);
      for k := 0 to High(Restored) do
        PrintLn(Ansi.Dim + '  - ' + Restored[k].Path + Ansi.Reset);
    end;
  end;

begin
  SystemPromptOverride := '';
  Session := nil;
  TotalCacheRead  := 0;
  TotalCacheWrite := 0;
  TotalPrompt     := 0;
  Offline := not PickProvider(Cfg, A, Provider, Err);
  if Offline then
    PrintLn(Ansi.Yellow + '(offline preview -- ' + Err + ')' + Ansi.Reset);
  PrimaryProvider     := Provider;
  EasyProvider        := nil;       { lazy }
  RoutedThisTurn      := False;
  RoutedProviderNm    := '';
  RoutedModelOverride := '';
  PrintLn(Ansi.Dim + 'PasClaw interactive chat. /help for commands, /quit to exit.' + Ansi.Reset);

  if A.Model <> '' then Model := A.Model else Model := Cfg.DefaultModel;
  Reg := nil;
  if not A.NoTools then
  begin
    Reg := NewBuiltinRegistry((not A.NoHashline) and Cfg.HashlineEnabled,
                              Cfg.VaultToolsEnabled,
                              HasConfiguredWebSearchProvider(Cfg),
                              Cfg.WebFetchEnabled,
                              (Cfg.ToolOutputCap > 0)
                                or Cfg.CondenseReversible,
                              Cfg.CronToolEnabled,
                              Cfg.DatabaseJSON,
                              Cfg.DesktopToolsEnabled);
    RegisterSkillManageTool(Reg, Cfg);
    RegisterSkillDisclosureTools(Reg, Cfg);
  end;
  MCPClients := ConnectMCP(Cfg, Reg, A.NoMCP);
  Spawn := MaybeRegisterSpawnTool(Cfg, Provider, Reg, Model);
  BgCoord := MaybeRegisterBackgroundSpawnTools(Cfg, Provider, Reg, Model);
  Handlers := TLoopHandlers.Create;
  try
    SetLength(Msgs, 0);
    ThinkingOn := False;

    { Persistence is on by default in interactive mode -- a passed
      --session resumes that id (or starts fresh under it when the
      file doesn't exist), an empty --session auto-allocates a new
      id so the conversation survives Ctrl-C / crash regardless.
      Codex P1 on PR #117: making this opt-in defeated the whole
      "history survives restarts" point. }
    Session := NewStampedSession(A.Session, Cfg);
    Handlers.MetaRef := @Session.Meta;
    RewireCheckpoints;
    { Tell the active shell backend a session is starting so docker
      can spawn its per-session container BEFORE the first tool
      call. SetCurrentSessionId makes shell_exec / execute_code
      dispatch through the right container (or fall back cleanly
      on local). The matching CloseShellSession runs in the
      finally below. }
    StartShellSession(Session.Meta.Id);
    SetCurrentSessionId(Session.Meta.Id);
    if Session.MetaExists then
    begin
      SetLength(Msgs, Length(Session.Messages));
      for i := 0 to High(Session.Messages) do Msgs[i] := Session.Messages[i];
      SystemPromptOverride := Session.Meta.SystemPromptOverride;
      PrintLn(Ansi.Dim + '(resumed session ' + Session.Meta.Id +
              ' -- ' + IntToStr(Length(Msgs)) + ' messages' +
              ProfileSuffix(Session.Meta.Profile) + ')' + Ansi.Reset);
    end
    else
      PrintLn(Ansi.Dim + '(new session ' + Session.Meta.Id +
              ' -- pasclaw resume ' + Session.Meta.Id + ' to continue later' +
              ProfileSuffix(Session.Meta.Profile) + ')' + Ansi.Reset);

    while True do
    begin
      Print(Ansi.Bold + '> ' + Ansi.Reset);
      if EOF then Break;
      ReadLn(Line);
      Line := Trim(Line);
      if (Line = '/quit') or (Line = '/exit') then Break;
      if (Line = '/reset') or (Line = '/new') then
      begin
        SetLength(Msgs, 0);
        SystemPromptOverride := '';   { drop the compacted summary too }
        { /new starts a brand-new session id so the existing one
          stays on disk for resume; /reset keeps the current session
          but clears its messages in place. Distinction matches
          openclaw and nanobot semantics. }
        if Line = '/new' then
        begin
          { Old session's queue might have leftover pending steering
            messages -- drop them before re-keying so the fresh session
            doesn't pick up the previous conversation's interrupts. }
          ClearSteering(Session.Meta.Id);
          Session.Free;
          Session := NewStampedSession('', Cfg);   { fresh id }
          { MetaRef pointed into the freed session; re-aim it before
            any compaction can flush working state into dead memory. }
          Handlers.MetaRef := @Session.Meta;
          RewireCheckpoints;
          PrintLn(Ansi.Dim + '(new session ' + Session.Meta.Id + ')' + Ansi.Reset);
        end
        else
        begin
          ClearSteering(Session.Meta.Id);
          PersistSession;   { writes empty Msgs + cleared override }
          PrintLn(Ansi.Dim + '(history cleared)' + Ansi.Reset);
        end;
        Continue;
      end;
      if Copy(Line, 1, 7) = '/steer ' then
      begin
        { Same-process steering -- handy for testing, but the real
          win is `pasclaw steer <id> "..."` from another terminal
          while a long loop is mid-execution. }
        if PushSteering(Session.Meta.Id, Copy(Line, 8, MaxInt)) then
          PrintLn(Ansi.Dim + '(queued; injects at top of next iteration)' + Ansi.Reset)
        else
          PrintLn(Ansi.Red + '(steer push failed)' + Ansi.Reset);
        Continue;
      end;
      if Line = '/tools' then
      begin
        if Reg = nil then
          PrintLn('(tools disabled -- restart without --no-tools)')
        else
        begin
          Names := Reg.Names;
          for i := 0 to High(Names) do PrintLn('  ' + Names[i]);
        end;
        Continue;
      end;
      if (Line = '/help') or (Line = '/?') then
      begin
        PrintLn('  /help        show this list');
        PrintLn('  /status      model + provider + message count + thinking state');
        PrintLn('  /new         clear conversation history (alias: /reset)');
        PrintLn('  /reset       clear conversation history');
        PrintLn('  /compact     force a one-shot summariser pass on the history now');
        PrintLn('  /think       toggle extended thinking on the next turn (if the provider supports it)');
        PrintLn('  /tools       list registered tools');
        PrintLn('  /mode [plan|build|improve]  show or set the mode (plan = read-only, build = full access, improve = measure-first loop)');
        PrintLn('  /steer <msg> queue a mid-loop steering message for the NEXT iteration');
        PrintLn('  /undo [N]    rewind N turns by restoring file checkpoints (default 1)');
        PrintLn('  /goal [--max N] <objective>');
        PrintLn('               auto-continue turns until a judge model says MET / FAILED (budget N, default 5)');
        PrintLn('  /quit        exit (alias: /exit)');
        Continue;
      end;
      if (Line = '/mode') or (Copy(Line, 1, 6) = '/mode ') then
      begin
        if Line = '/mode' then
          PrintLn('  mode: ' + ModeName(A.Mode) +
                  '  (/mode plan -> read-only; build -> full; improve -> measure first)')
        else
        begin
          if not ParseMode(Trim(Copy(Line, 7, MaxInt)), A.Mode) then
            PrintLn('  invalid mode -- use plan|build|improve')
          else
          begin
            { Re-build the system prompt so the next turn announces the new
              mode to the model. The dispatch gate is the authority; this
              keeps the model's own behaviour aligned. }
            LoopCfg.Mode := A.Mode;
            LoopCfg.Options.SystemPrompt :=
              BuildSystemPrompt(Cfg, A.SystemPrompt, Reg <> nil, '',
                                A.Mode, A.NoPlan);
            PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
                    ' mode -> ' + ModeName(A.Mode));
          end;
        end;
        Continue;
      end;
      if (Line = '/undo') or (Copy(Line, 1, 6) = '/undo ') then
      begin
        HandleUndoCommand(Copy(Line, 7, MaxInt));
        Continue;
      end;
      if (Line = '/goal') or (Copy(Line, 1, 6) = '/goal ') then
      begin
        HandleGoalCommand(Copy(Line, 7, MaxInt));
        Continue;
      end;
      if Line = '/status' then
      begin
        if Provider <> nil then
          PrintLn('  provider:  ' + Provider.GetName)
        else
          PrintLn('  provider:  (offline)');
        PrintLn('  model:     ' + Model);
        PrintLn('  messages:  ' + IntToStr(Length(Msgs)));
        if Reg <> nil then
          PrintLn('  tools:     ' + IntToStr(Reg.Count))
        else
          PrintLn('  tools:     (disabled)');
        if ThinkingOn then
          PrintLn('  thinking:  on (next turn)')
        else
          PrintLn('  thinking:  off');
        if SystemPromptOverride <> '' then
          PrintLn('  compacted: yes (summary in system prompt)')
        else
          PrintLn('  compacted: no');
        if Cfg.PromptCache.Enabled then
        begin
          if TotalPrompt > 0 then
            PrintLn(Format('  cache:     on, %d read / %d written (%d%% hit on prompt so far)',
                           [TotalCacheRead, TotalCacheWrite,
                            (TotalCacheRead * 100) div TotalPrompt]))
          else
            PrintLn('  cache:     on, no turns yet');
        end
        else
          PrintLn('  cache:     off (prompt_cache.enabled=false in config)');
        if Session <> nil then
        begin
          i := PendingSteeringCount(Session.Meta.Id);
          if i > 0 then
            PrintLn('  steering:  ' + IntToStr(i) + ' pending (folded at next iteration)')
          else
            PrintLn('  steering:  none queued');
        end;
        Continue;
      end;
      if Line = '/think' then
      begin
        if (Provider <> nil) and (not Provider.SupportsThinking) then
        begin
          PrintLn(Ansi.Yellow + 'provider ' + Provider.GetName +
                  ' does not support extended thinking -- flag ignored.' + Ansi.Reset);
          Continue;
        end;
        ThinkingOn := not ThinkingOn;
        if ThinkingOn then
          PrintLn(Ansi.Dim + '(thinking on for next turn)' + Ansi.Reset)
        else
          PrintLn(Ansi.Dim + '(thinking off)' + Ansi.Reset);
        Continue;
      end;
      if Line = '/compact' then
      begin
        if Length(Msgs) = 0 then
        begin
          PrintLn(Ansi.Dim + '(no history to compact)' + Ansi.Reset);
          Continue;
        end;
        if Offline then
        begin
          PrintLn(Ansi.Yellow + '/compact needs a configured provider to summarise.' + Ansi.Reset);
          Continue;
        end;
        CompactOptsLocal := DefaultCompactOptions;
        CompactOptsLocal.RetainBudgetTokens := Cfg.Compaction.RetainBudgetTokens;
        CompactOptsLocal.KeepRecentTurns    := Cfg.Compaction.KeepRecentTurns;
        CompactOptsLocal.SummaryBudget      := Cfg.Compaction.SummaryBudget;
        CompactOptsLocal.OnBefore           := Handlers.OnBeforeCompact;
        CompactOptsLocal.ThresholdTokens := 1;  { force the slice }
        CompactedLiveOpts := DefaultChatOptions;
        ApplyPromptCacheConfig(CompactedLiveOpts, Cfg.PromptCache);
        if SystemPromptOverride <> '' then
          CompactedLiveOpts.SystemPrompt := SystemPromptOverride;
        Msgs := CompactMessages(Provider, Model, Msgs,
                                 CompactedLiveOpts, CompactOptsLocal);
        SystemPromptOverride := CompactedLiveOpts.SystemPrompt;
        { Persist the compacted state immediately -- otherwise a
          /quit or Ctrl-C before the next LLM turn loses the
          summary and resume replays the full transcript. Codex P2
          on PR #117. }
        PersistSession;
        PrintLn(Ansi.Dim + '(history compacted; summary folded into system prompt)' + Ansi.Reset);
        Continue;
      end;
      if Line = '' then Continue;

      SetLength(Msgs, Length(Msgs) + 1);
      Msgs[High(Msgs)] := MakeMessage(mrUser, Line);

      if Offline then
      begin
        PrintLn(Ansi.Cyan + 'assistant' + Ansi.Reset + ' (offline): I would respond once a provider is configured.');
        SetLength(Msgs, Length(Msgs) + 1);
        Msgs[High(Msgs)] := MakeMessage(mrAssistant, '(no response -- offline)');
        Continue;
      end;

      LoopCfg := BuildLoopConfig(Cfg, Provider, Reg, Model, A, Handlers, Line);
      { After the first compaction the summary lives in
        LiveOptions.SystemPrompt inside RunToolLoop and gets returned
        via Loop.FinalSystemPrompt. We override here so the next turn
        ships the summary back to the provider; without it
        BuildSystemPrompt rebuilds the original prompt and the
        compacted summary leaks out of the conversation. }
      if SystemPromptOverride <> '' then
        LoopCfg.Options.SystemPrompt := SystemPromptOverride;
      { Working-state snapshot from prior turns goes BEFORE the
        compacted summary (or the freshly-built default system
        prompt) so the model sees structured edit/shell/error
        context at the top of every turn. Empty string when the
        snapshot is empty -- pre-feature sessions stay verbatim. }
      WorkingStateBlock := FormatWorkingStateBlock(Session.Meta);
      if WorkingStateBlock <> '' then
        LoopCfg.Options.SystemPrompt :=
          WorkingStateBlock + sLineBreak + LoopCfg.Options.SystemPrompt;
      { Anchor OpenAI's prompt_cache_key to the persistent session
        id so the cache bucket lines up across turns of THIS chat
        (not someone else's parallel session that happens to share a
        prefix). Anthropic ignores the field; OpenAI uses it to pin
        prefix routing on the back-end. }
      if Session <> nil then
      begin
        LoopCfg.Options.CacheKey := Session.Meta.Id;
        { Steering queue key -- RunToolLoop drains it at iteration
          top and folds pending messages into history as
          "[user steering] ..." system notes. The other terminal's
          `pasclaw steer <session-id> "..."` writes to the same
          file the loop is about to read. }
        LoopCfg.SteeringKey := Session.Meta.Id;
        { Background subagents: bind the coordinator to this session
          on first turn (idempotent re-binds are cheap), and let
          RunToolLoop fold finished results into the system prompt
          via the same channel steering uses. }
        if BgCoord <> nil then
        begin
          BgCoord.SetKey(Session.Meta.Id);
          LoopCfg.BackgroundDrainKey := Session.Meta.Id;
        end;
      end;
      { /think: apply ThinkingLevel for this turn, then clear so
        subsequent turns reset (matches the OpenClaw /think model --
        single-turn extended thinking). The user can /think again
        to keep it on. }
      if ThinkingOn then
      begin
        LoopCfg.Options.ThinkingLevel := 'medium';
        ThinkingOn := False;
      end;

      { Auto-router: classify the latest user message and, if it looks easy
        enough, swap LoopCfg.Provider to the cheap provider for this turn (and
        prepend the primary to the fallback chain). Shared with the TUI /
        gateway / component via ApplyAutoRoute -- one implementation, all
        surfaces. No-op unless Cfg.AutoRouter.Enabled. }
      RoutedThisTurn := False;
      if (not Offline) and (PrimaryProvider <> nil) then
        if ApplyAutoRoute(LoopCfg, Cfg, Msgs, RoutedProviderNm, RoutedScoreVal) then
        begin
          RoutedThisTurn      := True;
          RoutedModelOverride := LoopCfg.Model;   { for the assistant label }
          PrintLn(Ansi.Dim + '(routed -> ' + RoutedProviderNm +
                  ' [score=' + FormatFloat('0.00', RoutedScoreVal) + '])' + Ansi.Reset);
        end;

      { Open a fresh checkpoints turn so any fs_write / fs_edit_hashline
        this loop fires lands in turn-NNNN/ under this session. No-op
        when checkpoints aren't enabled. The checkpoints module owns
        its turn counter internally (resumed from on-disk state at
        InitCheckpoints), so the FPC line-based agent and the TUI
        agree on what /undo N rolls back to. }
      BeginTurn;

      if RunToolLoop(LoopCfg, Msgs, Loop) then
      begin
        if RoutedThisTurn then
          PrintLn(Ansi.Cyan + 'assistant' + Ansi.Reset + ' (' +
                  RoutedProviderNm + '/' + RoutedModelOverride +
                  ', auto-routed):')
        else
          PrintLn(Ansi.Cyan + 'assistant' + Ansi.Reset + ' (' + Provider.GetName + '/' + Model + '):');
        PrintLn(MaybeRender(Cfg, Loop.Content));
        { Stopped at the iteration cap mid-task -- surface it so the
          operator knows the answer is partial and can just type "continue"
          (the interactive history carries over to the next turn). }
        if Loop.HitMaxIterations then
          PrintLn(Ansi.Yellow + FormatMaxIterNotice(Loop, A.MaxIterations,
                  '--max-iterations N', {Resumable=} True) + Ansi.Reset);
        if Loop.TotalUsage.InputTokens + Loop.TotalUsage.OutputTokens > 0 then
        begin
          { Surface aggregate usage across every provider call in the
            turn (incl. tool-using rounds), not just the final reply.
            Codex P2 on PR #118. }
          PrintLn(Ansi.Dim + FormatTokenLine(Loop.TotalUsage, Loop.Iterations) + Ansi.Reset);
          Inc(TotalPrompt,     TotalPromptTokens(Loop.TotalUsage, Provider.GetName));
          Inc(TotalCacheRead,  Loop.TotalUsage.CacheReadTokens);
          Inc(TotalCacheWrite, Loop.TotalUsage.CacheCreatedTokens);
        end;
        if Cfg.StatsCollectionEnabled and (Session <> nil) then
          AccumulateTurnStats(Session.Meta,
                              Loop.TotalUsage.InputTokens,
                              Loop.TotalUsage.OutputTokens,
                              Loop.TotalUsage.CacheReadTokens,
                              Loop.TotalUsage.CacheCreatedTokens,
                              Loop.ToolCallsDispatched,
                              Loop.TruncatedBytesSaved);

        { Opt-in distilled memory: background-distil the latest exchange
          into the fact store. Best-effort, non-blocking; needs a session
          for provenance. Uses the chat provider, no ONNX. }
        if Cfg.MemoryDistillEnabled and (Session <> nil) then
          ScheduleDistill(Provider, Model, GetHome, Session.Meta.Id,
            BuildRecentTranscript(Loop.FinalMessages, Loop.Content, DefaultRecentMsgs));

        { Pick up the compacted history from RunToolLoop so the next
          interactive turn starts from the summarised state, not the
          full pre-compaction transcript (Codex PR #87 P2). If
          compaction didn't fire this turn, Loop.FinalMessages mirrors
          Msgs + new assistant/tool entries -- same growth path as
          before. If it DID fire, Msgs shrinks to the compacted view
          and SystemPromptOverride below preserves the summary across
          subsequent BuildLoopConfig calls. }
        if Length(Loop.FinalMessages) > 0 then
        begin
          SetLength(Msgs, Length(Loop.FinalMessages) + 1);
          for i := 0 to High(Loop.FinalMessages) do
            Msgs[i] := Loop.FinalMessages[i];
          Msgs[High(Msgs)] := MakeMessage(mrAssistant, Loop.Content);
        end
        else
        begin
          SetLength(Msgs, Length(Msgs) + 1);
          Msgs[High(Msgs)] := MakeMessage(mrAssistant, Loop.Content);
        end;
        SystemPromptOverride := Loop.FinalSystemPrompt;
        { Strip the per-turn working-state prefix we prepended in
          BuildLoopConfig -- if compaction didn't fire, the prefix
          comes back verbatim and persisting it would re-prepend
          on every subsequent turn, accumulating stale snapshots.
          When compaction DID fire, the summariser may have
          rewritten the whole prompt; in that case the prefix
          comparison fails and we keep the compacted text as-is.
          Codex P2 on PR #180. }
        if WorkingStateBlock <> '' then
        begin
          if (Length(SystemPromptOverride) >
              Length(WorkingStateBlock) + Length(sLineBreak))
             and (Copy(SystemPromptOverride, 1,
                       Length(WorkingStateBlock) + Length(sLineBreak)) =
                  WorkingStateBlock + sLineBreak) then
            SystemPromptOverride := Copy(SystemPromptOverride,
              Length(WorkingStateBlock) + Length(sLineBreak) + 1,
              MaxInt);
        end;

        { Refresh the working-state snapshot from this turn's final
          history (fs_write/fs_edit paths, shell commands, tool
          errors). Updates Session.Meta.WorkingState in place;
          PersistSession below writes it out so a /quit-then-resume
          picks up the same context next time. }
        if Length(Loop.FinalMessages) > 0 then
          UpdateWorkingStateAfterTurn(Session.Meta, Loop.FinalMessages);

        { Persist after every successful turn -- crash / Ctrl-C in
          the middle of the NEXT user prompt only loses what they
          were typing, not the existing conversation. }
        PersistSession;
      end;
    end;
  finally
    Handlers.Free;
    FreeMCPClients(MCPClients);
    if Spawn <> nil then Spawn.Free;
    Reg.Free;
    if Session <> nil then
    begin
      { Stop the per-session container before freeing the session
        meta. The Local backend's CloseSession is a no-op; the
        Docker backend issues `docker stop <name>` (which --rm
        cleans up). }
      CloseShellSession(Session.Meta.Id);
      SetCurrentSessionId('');
      Session.Free;
    end;
  end;
end;

function Cmd_Agent_Run(const Argv: array of string): Integer;
var
  A: TAgentArgs;
  Cfg: TConfig;
  KindSelected: TShellBackendKind;
  BackendDesc, SessionProfile: string;
begin
  if not ParseArgs(Argv, A) then
  begin
    PrintLnErr('usage: pasclaw agent [-m "msg"] [--model M] [--provider P] [--system S]');
    PrintLnErr('                     [--thinking low|medium|high] [--max-tokens N]');
    PrintLnErr('                     [--max-iterations N] [--no-tools] [-q|--quiet] [--verbose|--brief]');
    PrintLnErr('                     [--orient|--no-orient] [--mode plan|build|improve] [--plan|--build]');
    PrintLnErr('                     [--profile baseline|low-token|security|max-build|all-on|<custom>]');
    Exit(1);
  end;

  (* Profile precedence for this run:

       1. --profile             (typed for this invocation)
       2. $PASCLAW_PROFILE      (ambient, set once per shell)
       3. the resumed session's own recorded profile
       4. the workspace binding / global "profile" field

     Layers 1, 2 and 4 already live inside LoadConfig; layer 3 is added
     here by passing the session's profile as the override when nothing
     more explicit was given. Doing it this way keeps Config unaware of
     sessions -- Config sits underneath the session store, so the
     dependency can only point this direction -- and an empty result
     falls straight through to LoadConfig's own chain.

     The point: a session started under `security` resumes sandboxed,
     even from a shell whose config.json names something else. *)
  SessionProfile := A.Profile;
  if (SessionProfile = '') and (GetEnvironmentVariable('PASCLAW_PROFILE') = '')
     and (A.Session <> '') then
    SessionProfile := PeekSessionProfile(A.Session);

  Cfg := LoadConfig(SessionProfile);
  { --orient / --no-orient override task-aware MEMORY slicing for this
    run, on top of whatever config.json / the profile resolved to. The
    feature ships off on every profile, so --orient is the no-edit way
    to try it. }
  if A.OrientOverride = ooOn  then Cfg.OrientTaskAware := True
  else if A.OrientOverride = ooOff then Cfg.OrientTaskAware := False;
  { Phase 4c: best-effort load the semantic fact embedder once per run
    (no-op when distill off or ONNX unprovisioned). }
  if Cfg.MemoryDistillEnabled then
    EnableFactEmbeddings(GetHome);
  ConfigureSandbox(Cfg.Sandbox, '');
  { Install the active shell backend BEFORE any session can spawn a
    container or build its tool registry (shell_exec's description
    advertises the backend). Surfaces docker-daemon errors here
    with the right command-line context so the operator sees what
    --backend they picked. }
  try
    InstallShellBackend(Cfg, A.BackendOverride, KindSelected, BackendDesc);
  except
    on E: Exception do
    begin
      PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + E.Message);
      Exit(1);
    end;
  end;
  try
    if A.Message <> '' then
    begin
      { One-shot path: RunSingleTurn returns False on (a) no provider
        configured or (b) a failed tool loop. Map either to exit 1 so
        `pasclaw agent --quiet -m "..."` callers checking $? see real
        failures instead of a silently-zero exit code that lies about
        success. PR #243 P2. Interactive mode has no equivalent
        return -- session lifecycle is the user's signal there.

        Phase 3 of plan/build: --goal-objective (set by Cmd.Build
        --goal after parsing PLAN.md's Goal line) routes the one-shot
        path through RunSingleTurnGoalDriven instead, wrapping
        RunToolLoop in TGoalRunner so the Ralph judge loop pumps
        iterations until MET / FAILED / BUDGET-EXHAUSTED. }
      if A.GoalObjective <> '' then
      begin
        if RunSingleTurnGoalDriven(Cfg, A, A.Message) then
          Result := 0
        else
          Result := 1;
      end
      else if RunSingleTurn(Cfg, A, A.Message) then
        Result := 0
      else
        Result := 1;
    end
    else
    begin
      RunInteractive(Cfg, A);
      Result := 0;
    end;
  finally
    Cfg.Free;
  end;
end;

end.
