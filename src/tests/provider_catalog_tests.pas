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

  { Cloudflare AI Gateway: OpenAI family, Bearer auth, /chat/completions
    (no /v1 -- the /v1 lives in the operator-supplied api_base prefix).
    DefaultBase empty because the URL embeds the operator's account id
    (same pattern as mimo / litellm). DefaultModel is a Workers AI
    flagship with the @cf/ prefix. }
  Expect(LookupProvider('cloudflare', Spec), 'cloudflare not in catalog');
  Expect(Spec.Family = pfOpenAI,             'cloudflare should be pfOpenAI');
  Expect(Spec.Auth.Kind = asBearer,          'cloudflare should be bearer auth');
  Expect(Spec.DefaultBase = '',
         'cloudflare DefaultBase must be empty (operator supplies URL): ' + Spec.DefaultBase);
  Expect(Spec.DefaultModel = '@cf/meta/llama-3.3-70b-instruct-fp8-fast',
         'cloudflare DefaultModel wrong: ' + Spec.DefaultModel);
  Expect(Spec.ChatPath = '/chat/completions',
         'cloudflare ChatPath must be /chat/completions (no /v1), got: ' + Spec.ChatPath);
  Expect(Spec.DisplayName = 'Cloudflare AI Gateway',
         'cloudflare DisplayName wrong: ' + Spec.DisplayName);

  { Case-insensitive lookup works for the new row too. }
  Expect(LookupProvider('Cloudflare', Spec),
         'cloudflare lookup not case-insensitive');

  { Cloudflare AI Gateway -- Anthropic passthrough. Family pfAnthropic
    because the wire shape is Anthropic's /v1/messages, not OpenAI's.
    Auth is asHeader 'x-api-key' (forwarded to api.anthropic.com
    upstream by the gateway). DefaultBase empty because the URL embeds
    the operator's account id and gateway id. }
  Expect(LookupProvider('cloudflare-anthropic', Spec),
         'cloudflare-anthropic not in catalog');
  Expect(Spec.Family = pfAnthropic,
         'cloudflare-anthropic should be pfAnthropic');
  Expect(Spec.Auth.Kind = asHeader,
         'cloudflare-anthropic should be asHeader auth');
  Expect(Spec.Auth.HeaderName = 'x-api-key',
         'cloudflare-anthropic header name wrong: ' + Spec.Auth.HeaderName);
  Expect(Spec.DefaultBase = '',
         'cloudflare-anthropic DefaultBase must be empty: ' + Spec.DefaultBase);
  Expect(Spec.DefaultModel = 'claude-opus-4-7',
         'cloudflare-anthropic DefaultModel wrong: ' + Spec.DefaultModel);
  Expect(Spec.DisplayName = 'Cloudflare AI Gateway (Anthropic)',
         'cloudflare-anthropic DisplayName wrong: ' + Spec.DisplayName);

  { Cloudflare AI Gateway -- Gemini passthrough. Family pfGemini, auth
    asHeader 'x-goog-api-key' (Gemini's own auth, forwarded by the
    gateway). DefaultBase empty (operator URL embeds the account id). }
  Expect(LookupProvider('cloudflare-gemini', Spec),
         'cloudflare-gemini not in catalog');
  Expect(Spec.Family = pfGemini,
         'cloudflare-gemini should be pfGemini');
  Expect(Spec.Auth.Kind = asHeader,
         'cloudflare-gemini should be asHeader auth');
  Expect(Spec.Auth.HeaderName = 'x-goog-api-key',
         'cloudflare-gemini header name wrong: ' + Spec.Auth.HeaderName);
  Expect(Spec.DefaultBase = '',
         'cloudflare-gemini DefaultBase must be empty: ' + Spec.DefaultBase);
  Expect(Spec.DefaultModel = 'gemini-3.5-flash',
         'cloudflare-gemini DefaultModel wrong: ' + Spec.DefaultModel);
  Expect(Spec.DisplayName = 'Cloudflare AI Gateway (Gemini)',
         'cloudflare-gemini DisplayName wrong: ' + Spec.DisplayName);

  WriteLn('provider_catalog_tests: OK');
end.
