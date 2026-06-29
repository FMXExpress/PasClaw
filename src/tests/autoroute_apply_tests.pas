program autoroute_apply_tests;
(*
  Covers ApplyAutoRoute -- the shared helper that applies the task-difficulty
  auto-router to a TToolLoopConfig before RunToolLoop, now used by every
  surface (CLI, TUI, gateway/serve, component) instead of CLI-only inline code.

  Contracts pinned:
    - Router OFF (the default) -> returns False, LoopCfg untouched. This is
      the safety property that keeps all wired surfaces no-op by default.
    - nil primary provider -> returns False (nothing to route from).
    - Router ON + an easy message + a resolvable easy provider -> returns True,
      swaps LoopCfg.Provider/Model to the easy provider, and prepends the
      original primary to LoopCfg.Fallbacks.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.ToolLoop,
  PasClaw.Agent.AutoRouter.Apply;

type
  { Minimal stand-in for the primary provider so we can assert the swap. }
  TFakeProvider = class(TInterfacedObject, ILLMProvider)
  private
    FName: string;
  public
    constructor Create(const AName: string);
    function Chat(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                  const Model: string; const Options: TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                        const Model: string; const Options: TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

constructor TFakeProvider.Create(const AName: string); begin inherited Create; FName := AName; end;
function TFakeProvider.Chat(const Messages: array of TMessage; const Tools: array of TToolDefinition;
  const Model: string; const Options: TChatOptions): TLLMResponse; begin Result := Default(TLLMResponse); end;
function TFakeProvider.GetDefaultModel: string; begin Result := 'fake-model'; end;
function TFakeProvider.GetName: string; begin Result := FName; end;
function TFakeProvider.SupportsThinking: Boolean; begin Result := False; end;
function TFakeProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TFakeProvider.SupportsStreaming: Boolean; begin Result := False; end;
function TFakeProvider.ChatStream(const Messages: array of TMessage; const Tools: array of TToolDefinition;
  const Model: string; const Options: TChatOptions; OnChunk: TStreamCallback): TLLMResponse;
begin Result := Default(TLLMResponse); end;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;

function EasyMsgs: TArray<TMessage>;
begin
  SetLength(Result, 1);
  Result[0] := MakeMessage(mrUser, 'what is the capital of France');  { "what is" -> easy }
end;

var
  Cfg: TConfig;
  LoopCfg: TToolLoopConfig;
  Primary: ILLMProvider;
  Routed: string;
  Msgs: TArray<TMessage>;
begin
  Primary := TFakeProvider.Create('primary-anthropic');
  Msgs := EasyMsgs;

  Cfg := TConfig.Create;
  try
    { ---- Default config: AutoRouter.Enabled is True but EasyProvider is
      empty, so routing is inert -- no-op, LoopCfg untouched. This is the
      safety property that keeps every wired surface unchanged until an
      operator actually configures an easy provider. ---- }
    LoopCfg := Default(TToolLoopConfig);
    LoopCfg.Provider := Primary;
    LoopCfg.Model    := 'claude-opus-4-7';
    AssertTrue(Cfg.AutoRouter.EasyProvider = '', 'default EasyProvider is empty');
    AssertTrue(not ApplyAutoRoute(LoopCfg, Cfg, Msgs, Routed),
      'default (no easy provider) -> ApplyAutoRoute returns False');
    AssertTrue(LoopCfg.Provider = Primary, 'default -> provider untouched');
    AssertTrue(LoopCfg.Model = 'claude-opus-4-7', 'default -> model untouched');
    AssertTrue(Length(LoopCfg.Fallbacks) = 0, 'default -> fallbacks untouched');

    { ---- nil primary -> False. ---- }
    LoopCfg := Default(TToolLoopConfig);
    Cfg.AutoRouter.Enabled := True;
    Cfg.AutoRouter.EasyProvider := 'groq';
    AssertTrue(not ApplyAutoRoute(LoopCfg, Cfg, Msgs, Routed),
      'nil primary -> ApplyAutoRoute returns False');

    { ---- Router ON + easy msg + resolvable easy provider -> route. ---- }
    Cfg.AutoRouter.Enabled      := True;
    Cfg.AutoRouter.EasyProvider := 'groq';
    Cfg.AutoRouter.EasyModel    := 'llama-3.3-70b-versatile';  { non-empty so routing isn't refused }
    SetLength(Cfg.Providers, 1);
    Cfg.Providers[0].Name   := 'groq';
    Cfg.Providers[0].Kind   := 'groq';
    Cfg.Providers[0].APIKey := 'gsk-test';   { construction only; no network }

    LoopCfg := Default(TToolLoopConfig);
    LoopCfg.Provider := Primary;
    LoopCfg.Model    := 'claude-opus-4-7';
    AssertTrue(ApplyAutoRoute(LoopCfg, Cfg, Msgs, Routed),
      'enabled + easy + resolvable -> routes');
    AssertTrue(Routed = 'groq', 'routed provider name reported');
    AssertTrue(LoopCfg.Provider <> Primary, 'provider swapped off the primary');
    AssertTrue(LoopCfg.Provider.GetName = 'groq', 'provider swapped to the easy provider');
    AssertTrue(LoopCfg.Model = 'llama-3.3-70b-versatile', 'model swapped to the easy model');
    AssertTrue((Length(LoopCfg.Fallbacks) = 1) and (LoopCfg.Fallbacks[0] = Primary),
      'original primary prepended to the fallback chain');
    { Review fix: the prepended primary must carry the caller's pre-route
      model so a routing-fooled turn retries the primary with the model the
      operator actually requested, not the primary's catalog default. }
    AssertTrue((Length(LoopCfg.FallbackModels) = 1)
               and (LoopCfg.FallbackModels[0] = 'claude-opus-4-7'),
      'caller pre-route model preserved as the primary fallback override');
  finally
    Cfg.Free;
  end;

  WriteLn('  ok: ApplyAutoRoute (off=no-op, nil-primary, routes + prepends primary)');
  WriteLn('PASS');
end.
