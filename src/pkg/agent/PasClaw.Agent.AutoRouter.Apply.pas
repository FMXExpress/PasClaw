(*
  PasClaw.Agent.AutoRouter.Apply - applies the task-difficulty auto-router to
  a freshly-built TToolLoopConfig, in place, just before RunToolLoop.

  The routing DECISION lives in PasClaw.Agent.AutoRouter (ClassifyTask /
  RouteProvider). This unit centralises the APPLICATION of that decision so
  every surface gets it identically: CLI (one-shot + interactive), TUI, the
  embeddable component (TPasClawAgent), and the gateway (serve / gateway).
  Previously only the CLI wired it, so an embedder, the TUI, and every
  /v1/chat caller silently ran on the primary provider even with the router
  enabled.

  Kept as a plain function (not a callback baked into RunToolLoop) because
  FPC 3.2.2 has no `reference to` closures, and the provider RESOLUTION
  (name -> ILLMProvider via the factory) belongs in this layer, not the
  low-level loop. Each surface calls it on the loop config it already builds.
*)
unit PasClaw.Agent.AutoRouter.Apply;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Tools.ToolLoop;

{ Route this turn to the cheap provider when the router is enabled and the
  latest user message in Messages classifies easy AND the easy provider
  resolves. On a route: LoopCfg.Provider/Model are swapped to the cheap
  provider and the original primary is prepended to LoopCfg.Fallbacks (so a
  routing-fooled turn falls back to the provider the operator would have used
  anyway). Returns True + the routed provider name; False leaves LoopCfg
  untouched (and RoutedProviderName empty). Never raises. }
function ApplyAutoRoute(var LoopCfg: TToolLoopConfig; const Cfg: TConfig;
                        const Messages: array of TMessage;
                        out RoutedProviderName: string): Boolean; overload;

{ As above, plus the computed structural complexity score (0..1) for
  transparency -- surface it in a "(routed -> x [score=...])" line / a
  response header. RoutedScore is -1 when the router short-circuits before
  scoring (disabled / nil provider / empty message). }
function ApplyAutoRoute(var LoopCfg: TToolLoopConfig; const Cfg: TConfig;
                        const Messages: array of TMessage;
                        out RoutedProviderName: string;
                        out RoutedScore: Double): Boolean; overload;

implementation

uses
  SysUtils,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory,
  PasClaw.Tools.Registry,
  PasClaw.Agent.Mode,            { TPasClawMode / pmPlan -- plan-mode skip }
  PasClaw.Logger,
  PasClaw.Agent.AutoRouter;

function LatestUserMessage(const Messages: array of TMessage): string;
var
  i: Integer;
begin
  Result := '';
  for i := High(Messages) downto Low(Messages) do
    if Messages[i].Role = mrUser then
      Exit(Messages[i].Content);
end;

{ Fingerprint of every input NewProviderFromConfig captures into the easy
  provider object. Used to bust the per-thread cache when a /v1/config
  hot-swap changes any of them without changing the provider name. Beyond the
  per-provider entry (kind / base / key / model), NewProviderFromConfig also
  bakes provider-WIDE settings into the object -- the Anthropic/OpenAI/Gemini
  server-tool toggles and the relay wait timeout -- so those must be in the
  key too, or a config that only flips e.g. web_search would keep reusing a
  stale provider on a same-thread surface. Empty when the name is unknown. }
function EasyProviderFingerprint(const Cfg: TConfig; const Name: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Cfg.Providers) do
    if SameText(Cfg.Providers[i].Name, Name) then
    begin
      Result := Cfg.Providers[i].Kind + '|' + Cfg.Providers[i].APIBase + '|' +
                Cfg.Providers[i].APIKey + '|' + Cfg.Providers[i].Model + '|' +
                BoolToStr(Cfg.AnthropicServerTools.WebSearch, True) + ',' +
                IntToStr(Cfg.AnthropicServerTools.WebSearchMaxUses) + ',' +
                BoolToStr(Cfg.AnthropicServerTools.WebFetch, True) + ',' +
                IntToStr(Cfg.AnthropicServerTools.WebFetchMaxUses) + '|' +
                BoolToStr(Cfg.OpenAIServerTools.WebSearch, True) + '|' +
                BoolToStr(Cfg.GeminiServerTools.GoogleSearch, True) + '|' +
                IntToStr(Cfg.RelayWaitTimeoutMs);
      Exit;
    end;
end;

{ Per-thread cache of the last-constructed easy provider. Routing the same easy
  provider every turn (the common case) reused one object across the session in
  the old CLI inline code; this restores that for all surfaces without sharing
  state across threads (the gateway routes from worker threads -- no locking,
  each thread caches independently). Keyed on name + config fingerprint so a
  hot-swap rebuilds correctly. }
threadvar
  GEasyName:        string;
  GEasyFingerprint: string;
  GEasyProv:        ILLMProvider;

function ApplyAutoRoute(var LoopCfg: TToolLoopConfig; const Cfg: TConfig;
                        const Messages: array of TMessage;
                        out RoutedProviderName: string;
                        out RoutedScore: Double): Boolean;
var
  UserMsg, RoutedModel, Err, OrigModel, Fingerprint: string;
  Names: TStringArray;
  EasyProvider, PrimaryProvider: ILLMProvider;
  PrimaryFallbacks: TLLMProviderArray;
  PrimaryFallbackModels: TStringArray;
  i: Integer;
begin
  Result := False;
  RoutedProviderName := '';
  RoutedScore := -1;
  { Cheap outs first so the non-routing path stays free. }
  if not Cfg.AutoRouter.Enabled then Exit;
  if LoopCfg.Provider = nil then Exit;
  { Plan mode is "big thinking": never route a planning/architecture turn to
    the cheap model, however it scores. The strong (primary) model owns
    plan-mode turns; routing resumes automatically in Build mode. Surfaces
    that don't set a mode default to pmBuild, so this is a no-op for them.

    Improve mode is exempt for the same reason and a sharper one: its
    turns are judgement -- read this profile, decide what to change,
    decide whether the number moved -- and the router scores by surface
    shape, so a short "re-run the benchmark" reads as easy and would be
    handed to the cheap model precisely when the answer matters most. }
  if (LoopCfg.Mode = pmPlan) or (LoopCfg.Mode = pmImprove) then Exit;
  UserMsg := LatestUserMessage(Messages);
  if UserMsg = '' then Exit;

  if LoopCfg.Registry <> nil then
    Names := LoopCfg.Registry.Names
  else
    SetLength(Names, 0);

  if not RouteProvider(Cfg, UserMsg, Names, RoutedProviderName, RoutedModel, RoutedScore) then
  begin
    RoutedProviderName := '';
    Exit;
  end;

  { Resolve the easy provider, reusing the per-thread cached object when the
    name and config fingerprint are unchanged so a long routed session doesn't
    reconstruct it every turn. On a build failure (catalog drift, missing key)
    log once and stay on the primary -- never crash a turn over a router
    misconfiguration. }
  Fingerprint := EasyProviderFingerprint(Cfg, RoutedProviderName);
  if (GEasyProv <> nil) and (GEasyName = RoutedProviderName)
     and (GEasyFingerprint = Fingerprint) then
    EasyProvider := GEasyProv
  else
  begin
    if not NewProviderFromConfig(Cfg, RoutedProviderName, EasyProvider, Err) then
    begin
      LogWarn('auto-router: easy provider "%s" unresolvable: %s -- staying on primary',
              [RoutedProviderName, Err]);
      RoutedProviderName := '';
      Exit;
    end;
    GEasyName        := RoutedProviderName;
    GEasyFingerprint := Fingerprint;
    GEasyProv        := EasyProvider;
  end;

  PrimaryProvider       := LoopCfg.Provider;
  PrimaryFallbacks      := LoopCfg.Fallbacks;
  PrimaryFallbackModels := LoopCfg.FallbackModels;
  { Capture the caller's pre-route model BEFORE we overwrite it. This is the
    model the operator actually asked for (--model, the TUI picker, or an
    OpenAI-compatible request model). When the routed call fails and we fall
    back to the primary, RunToolLoop must retry with THIS model, not the
    primary's catalog default -- otherwise auto-routing silently downgrades
    an explicit model choice on every routing-fooled turn. }
  OrigModel        := LoopCfg.Model;
  LoopCfg.Provider := EasyProvider;
  { RouteProvider guarantees a non-empty model when it routes (explicit
    EasyModel -> per-provider Model -> catalog default), so the cheap
    endpoint never receives the primary's model name. }
  if RoutedModel <> '' then
    LoopCfg.Model := RoutedModel;
  { Prepend the original primary so a failed routed call drops cleanly back to
    it before walking the rest of the chain, carrying OrigModel as its
    per-fallback override so the caller's requested model is preserved. }
  SetLength(LoopCfg.Fallbacks, Length(PrimaryFallbacks) + 1);
  LoopCfg.Fallbacks[0] := PrimaryProvider;
  for i := 0 to High(PrimaryFallbacks) do
    LoopCfg.Fallbacks[i + 1] := PrimaryFallbacks[i];
  { Parallel FallbackModels: [0] = the caller's pre-route model for the
    re-prepended primary; the rest carry over any prior per-fallback
    overrides (empty entries fall through to GetDefaultModel as before). }
  SetLength(LoopCfg.FallbackModels, Length(PrimaryFallbacks) + 1);
  LoopCfg.FallbackModels[0] := OrigModel;
  { Bound on Fallbacks (the array we sized to), not PrimaryFallbackModels:
    a caller that set FallbackModels longer than Fallbacks would otherwise
    write past the end. Indices without a prior override stay '' (the
    GetDefaultModel fall-through). }
  for i := 0 to High(PrimaryFallbacks) do
    if i <= High(PrimaryFallbackModels) then
      LoopCfg.FallbackModels[i + 1] := PrimaryFallbackModels[i];

  Result := True;
end;

function ApplyAutoRoute(var LoopCfg: TToolLoopConfig; const Cfg: TConfig;
                        const Messages: array of TMessage;
                        out RoutedProviderName: string): Boolean;
var
  IgnoredScore: Double;
begin
  Result := ApplyAutoRoute(LoopCfg, Cfg, Messages, RoutedProviderName, IgnoredScore);
end;

end.
