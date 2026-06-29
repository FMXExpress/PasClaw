program fallback_models_tests;
(*
  Covers the per-fallback model override (TConfig.FallbackModels) end to end:
    - config round-trip: fallback_models serializes only when populated and
      parses back parallel to fallbacks;
    - ResolveFallbacks(Cfg, out Models) returns the models in LOCKSTEP with the
      resolved providers, including when an unresolvable entry is skipped;
    - an empty / missing override leaves that slot blank (the loop then falls
      through to the provider's catalog default).

  This is what makes a same-provider fallback useful -- "Opus tapped -> Sonnet
  on one key" -- since per-model rate/capacity limits are real on both the
  subscription and the API.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

{ Seed a groq provider so NewProviderFromConfig resolves without network. }
procedure SeedGroq(Cfg: TConfig);
begin
  SetLength(Cfg.Providers, 1);
  Cfg.Providers[0].Name   := 'groq';
  Cfg.Providers[0].Kind   := 'groq';
  Cfg.Providers[0].APIKey := 'gsk-test';   { construction only; no network }
end;

procedure TestRoundTrip;
var
  Cfg, Cfg2: TConfig;
  S: string;
begin
  Cfg := TConfig.Create;
  try
    SetLength(Cfg.Fallbacks, 2);
    Cfg.Fallbacks[0] := 'anthropic';
    Cfg.Fallbacks[1] := 'groq';
    SetLength(Cfg.FallbackModels, 2);
    Cfg.FallbackModels[0] := 'claude-sonnet-4-6';
    Cfg.FallbackModels[1] := '';   { blank -> catalog default for groq }
    S := Cfg.ToJSON;
    AssertTrue(Pos('fallback_models', S) > 0, 'fallback_models emitted when populated');

    Cfg2 := TConfig.Create;
    try
      Cfg2.FromJSON(S);
      AssertTrue(Length(Cfg2.FallbackModels) = 2, 'fallback_models parses with 2 entries');
      AssertEqStr(Cfg2.FallbackModels[0], 'claude-sonnet-4-6', 'override[0] round-trips');
      AssertEqStr(Cfg2.FallbackModels[1], '', 'blank override[1] round-trips');
      AssertEqStr(Cfg2.Fallbacks[0], 'anthropic', 'fallbacks still parse');
    finally
      Cfg2.Free;
    end;
  finally
    Cfg.Free;
  end;
end;

procedure TestNotEmittedWhenAllBlank;
var
  Cfg: TConfig;
  S: string;
begin
  Cfg := TConfig.Create;
  try
    SetLength(Cfg.Fallbacks, 1);
    Cfg.Fallbacks[0] := 'groq';
    SetLength(Cfg.FallbackModels, 1);
    Cfg.FallbackModels[0] := '';   { all blank -> don't clutter the file }
    S := Cfg.ToJSON;
    AssertTrue(Pos('fallback_models', S) = 0,
               'all-blank fallback_models is not emitted');
  finally
    Cfg.Free;
  end;
end;

procedure TestResolveLockstep;
var
  Cfg: TConfig;
  Provs: TLLMProviderArray;
  Models: array of string;
begin
  Cfg := TConfig.Create;
  try
    SeedGroq(Cfg);
    SetLength(Cfg.Fallbacks, 1);
    Cfg.Fallbacks[0] := 'groq';
    SetLength(Cfg.FallbackModels, 1);
    Cfg.FallbackModels[0] := 'llama-3.1-8b-instant';
    Provs := ResolveFallbacks(Cfg, Models);
    AssertTrue(Length(Provs) = 1, 'one provider resolved');
    AssertEqStr(Provs[0].GetName, 'groq', 'resolved provider is groq');
    AssertTrue(Length(Models) = 1, 'one model in lockstep');
    AssertEqStr(Models[0], 'llama-3.1-8b-instant', 'override carried in lockstep');
  finally
    Cfg.Free;
  end;
end;

procedure TestResolveSkipKeepsAlignment;
{ An unresolvable first entry must be skipped from BOTH arrays so the model
  stays aligned with its provider. }
var
  Cfg: TConfig;
  Provs: TLLMProviderArray;
  Models: array of string;
begin
  Cfg := TConfig.Create;
  try
    SeedGroq(Cfg);
    SetLength(Cfg.Fallbacks, 2);
    Cfg.Fallbacks[0] := 'phantom';   { unresolvable -> skipped }
    Cfg.Fallbacks[1] := 'groq';
    SetLength(Cfg.FallbackModels, 2);
    Cfg.FallbackModels[0] := 'ignored-because-phantom-skipped';
    Cfg.FallbackModels[1] := 'llama-3.1-8b-instant';
    Provs := ResolveFallbacks(Cfg, Models);
    AssertTrue(Length(Provs) = 1, 'only groq resolves');
    AssertTrue(Length(Models) = 1, 'models compacted in lockstep');
    AssertEqStr(Provs[0].GetName, 'groq', 'surviving provider is groq');
    AssertEqStr(Models[0], 'llama-3.1-8b-instant',
                'surviving model stays aligned with its provider');
  finally
    Cfg.Free;
  end;
end;

procedure TestBackCompatOverloadStillWorks;
var
  Cfg: TConfig;
  Provs: TLLMProviderArray;
begin
  Cfg := TConfig.Create;
  try
    SeedGroq(Cfg);
    SetLength(Cfg.Fallbacks, 1);
    Cfg.Fallbacks[0] := 'groq';
    Provs := ResolveFallbacks(Cfg);   { old no-models overload }
    AssertTrue(Length(Provs) = 1, 'back-compat overload resolves providers');
  finally
    Cfg.Free;
  end;
end;

begin
  TestRoundTrip;
  TestNotEmittedWhenAllBlank;
  TestResolveLockstep;
  TestResolveSkipKeepsAlignment;
  TestBackCompatOverloadStillWorks;
  WriteLn('fallback_models_tests: OK');
end.
