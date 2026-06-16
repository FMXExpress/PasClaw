program provider_catalog_tests;
(*
  Pins the provider catalog rows that matter for the ChatPath override:
  Perplexity (OpenAI-shaped but at /chat/completions, no /v1) and that
  every other OpenAI-family row keeps the default /v1/chat/completions.
  A wrong path here silently sends chat requests to a 404.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Providers.Catalog;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure Expect(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

var
  Spec: TProviderSpec;
begin
  { Perplexity: OpenAI family, bearer, sonar default, no-/v1 chat path. }
  Expect(LookupProvider('perplexity', Spec), 'perplexity not in catalog');
  Expect(Spec.Family = pfOpenAI,            'perplexity should be pfOpenAI');
  Expect(Spec.Auth.Kind = asBearer,         'perplexity should be bearer auth');
  Expect(Spec.DefaultBase = 'https://api.perplexity.ai',
         'perplexity base wrong: ' + Spec.DefaultBase);
  Expect(Spec.DefaultModel = 'sonar',       'perplexity default model wrong: ' + Spec.DefaultModel);
  Expect(Spec.ChatPath = '/chat/completions',
         'perplexity ChatPath must be /chat/completions (no /v1), got: ' + Spec.ChatPath);

  { Case-insensitive lookup still works. }
  Expect(LookupProvider('Perplexity', Spec), 'perplexity lookup not case-insensitive');

  { Existing rows keep the default /v1/chat/completions path. }
  Expect(LookupProvider('openai', Spec), 'openai not in catalog');
  Expect(Spec.ChatPath = '/v1/chat/completions',
         'openai ChatPath default regressed: ' + Spec.ChatPath);
  Expect(LookupProvider('groq', Spec), 'groq not in catalog');
  Expect(Spec.ChatPath = '/v1/chat/completions',
         'groq ChatPath default regressed: ' + Spec.ChatPath);

  WriteLn('provider_catalog_tests: OK');
end.
