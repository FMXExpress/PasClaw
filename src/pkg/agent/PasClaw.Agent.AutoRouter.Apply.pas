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
                        out RoutedProviderName: string): Boolean;

implementation

uses
  SysUtils,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory,
  PasClaw.Tools.Registry,
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

function ApplyAutoRoute(var LoopCfg: TToolLoopConfig; const Cfg: TConfig;
                        const Messages: array of TMessage;
                        out RoutedProviderName: string): Boolean;
var
  UserMsg, RoutedModel, Err, OrigModel: string;
  Names: TStringArray;
  EasyProvider, PrimaryProvider: ILLMProvider;
  PrimaryFallbacks: TLLMProviderArray;
  PrimaryFallbackModels: TStringArray;
  i: Integer;
begin
  Result := False;
  RoutedProviderName := '';
  { Cheap outs first so the non-routing path stays free. }
  if not Cfg.AutoRouter.Enabled then Exit;
  if LoopCfg.Provider = nil then Exit;
  UserMsg := LatestUserMessage(Messages);
  if UserMsg = '' then Exit;

  if LoopCfg.Registry <> nil then
    Names := LoopCfg.Registry.Names
  else
    SetLength(Names, 0);

  if not RouteProvider(Cfg, UserMsg, Names, RoutedProviderName, RoutedModel) then
  begin
    RoutedProviderName := '';
    Exit;
  end;

  { Build the easy provider on demand. On failure (catalog drift, missing
    key) log once and stay on the primary -- never crash a turn over a router
    misconfiguration. }
  if not NewProviderFromConfig(Cfg, RoutedProviderName, EasyProvider, Err) then
  begin
    LogWarn('auto-router: easy provider "%s" unresolvable: %s -- staying on primary',
            [RoutedProviderName, Err]);
    RoutedProviderName := '';
    Exit;
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
  for i := 0 to High(PrimaryFallbackModels) do
    LoopCfg.FallbackModels[i + 1] := PrimaryFallbackModels[i];

  Result := True;
end;

end.
