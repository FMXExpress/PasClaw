(*
  PasClaw.Providers.Catalog - single source of truth for the list of
  supported LLM providers and how to wire each one up.

  The CLI's previous if/else over Kind only covered anthropic + a loose
  openai-compat family. Most of the 23+ providers picoclaw supports are
  actually OpenAI Chat Completions speakers with just a different base
  URL (and occasionally a different auth-header convention). One catalog
  table + a couple of helpers replaces the dispatch and turns "add a new
  provider" into a one-row change.

  Protocol families wired up so far:

    pfOpenAI      - POST <base>/v1/chat/completions, JSON shape OpenAI
                    defined; covers the long tail.
    pfAnthropic   - POST <base>/v1/messages with x-api-key header.
    pfGemini      - POST <base>/v1beta/models/<model>:generateContent
                    with x-goog-api-key header.
    pfPlaceholder - kind reserved in the catalog so configs validate,
                    but no provider implementation bundled yet (used
                    for Bedrock / Azure / GitHub Copilot / Antigravity
                    until each follow-up PR lands).

  Three auth schemes:

    asBearer    - Authorization: Bearer <key>
    asNone      - no auth header (Ollama, vLLM local deployments)
    asHeader    - send the raw key in a named header. The header name
                  lives in TAuthScheme.HeaderName. Reserved for Azure's
                  api-key style; no entry uses it yet in Phase A but the
                  field exists so adding Azure later does not break the
                  TProviderSpec layout.
*)
unit PasClaw.Providers.Catalog;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

type
  TProtocolFamily = (
    pfOpenAI,
    pfAnthropic,
    pfGemini,
    pfPlaceholder  { kind known, no implementation yet — Bedrock/Azure/etc. }
  );

  TAuthSchemeKind = (asBearer, asNone, asHeader);

  TAuthScheme = record
    Kind:       TAuthSchemeKind;
    HeaderName: string;   { used only when Kind = asHeader; otherwise '' }
  end;

  TProviderSpec = record
    Kind:         string;            { canonical id, lowercase, matches TProviderConfig.Kind }
    DisplayName:  string;            { e.g. 'Anthropic', 'Groq' }
    Family:       TProtocolFamily;
    DefaultBase:  string;
    DefaultModel: string;            { empty when the provider has no obvious default }
    Auth:         TAuthScheme;
    Notes:        string;            { one-line description, shown in onboard menus }
  end;

  TProviderSpecArray = array of TProviderSpec;

{ Returns True and fills Spec when Kind matches a catalog entry
  (case-insensitive). Returns False otherwise. }
function LookupProvider(const Kind: string; out Spec: TProviderSpec): Boolean;

{ Returns a copy of every catalog entry, ordered by DisplayName, suitable
  for menus. The list is small (~19 entries) and rebuilt on each call —
  callers are not expected to call this in a hot loop. }
function AllProviderSpecs: TProviderSpecArray;

{ Helper that returns the default base URL for a kind, or '' if no such
  kind exists. Convenience for callers that don't need the full spec. }
function DefaultBaseFor(const Kind: string): string;

implementation

uses
  SysUtils;

function MkAuth(Kind: TAuthSchemeKind; const HeaderName: string = ''): TAuthScheme;
begin
  Result.Kind       := Kind;
  Result.HeaderName := HeaderName;
end;

function MkSpec(const Kind, DisplayName: string; Family: TProtocolFamily;
                const DefaultBase, DefaultModel: string;
                const Auth: TAuthScheme; const Notes: string): TProviderSpec;
begin
  Result.Kind         := Kind;
  Result.DisplayName  := DisplayName;
  Result.Family       := Family;
  Result.DefaultBase  := DefaultBase;
  Result.DefaultModel := DefaultModel;
  Result.Auth         := Auth;
  Result.Notes        := Notes;
end;

{ The catalog. New providers go here — one entry per row, no other code
  change required for OpenAI-compatible endpoints. }
function BuildCatalog: TProviderSpecArray;
begin
  SetLength(Result, 21);
  Result[0]  := MkSpec('anthropic',  'Anthropic',
                       pfAnthropic,  'https://api.anthropic.com',
                       'claude-opus-4-7',
                       MkAuth(asHeader, 'x-api-key'),
                       'Claude Opus / Sonnet / Haiku');
  Result[1]  := MkSpec('openai',     'OpenAI',
                       pfOpenAI,     'https://api.openai.com',
                       'gpt-4o-mini',
                       MkAuth(asBearer),
                       'GPT-4o, GPT-5, o3 family');
  Result[2]  := MkSpec('openrouter', 'OpenRouter',
                       pfOpenAI,     'https://openrouter.ai/api',
                       '',
                       MkAuth(asBearer),
                       '200+ models, unified API');
  Result[3]  := MkSpec('zhipu',      'Zhipu (GLM)',
                       pfOpenAI,     'https://open.bigmodel.cn/api/paas',
                       'glm-4',
                       MkAuth(asBearer),
                       'GLM-4, GLM-5');
  Result[4]  := MkSpec('deepseek',   'DeepSeek',
                       pfOpenAI,     'https://api.deepseek.com',
                       'deepseek-chat',
                       MkAuth(asBearer),
                       'DeepSeek-V3, DeepSeek-R1');
  Result[5]  := MkSpec('volcengine', 'Volcengine (Doubao/Ark)',
                       pfOpenAI,     'https://ark.cn-beijing.volces.com/api',
                       '',
                       MkAuth(asBearer),
                       'ByteDance Doubao / Ark models');
  Result[6]  := MkSpec('qwen',       'Qwen (DashScope)',
                       pfOpenAI,     'https://dashscope.aliyuncs.com/compatible-mode',
                       'qwen-max',
                       MkAuth(asBearer),
                       'Qwen3 / Qwen-Max');
  Result[7]  := MkSpec('groq',       'Groq',
                       pfOpenAI,     'https://api.groq.com/openai',
                       '',
                       MkAuth(asBearer),
                       'Fast inference (Llama-4, Kimi K2, Qwen3, compound-beta)');
  Result[8]  := MkSpec('moonshot',   'Moonshot (Kimi)',
                       pfOpenAI,     'https://api.moonshot.cn',
                       'kimi-k2',
                       MkAuth(asBearer),
                       'Kimi K2 / K2.5 / K2-Thinking');
  Result[9]  := MkSpec('minimax',    'MiniMax',
                       pfOpenAI,     'https://api.minimax.chat',
                       '',
                       MkAuth(asBearer),
                       'MiniMax abab / hailuo');
  Result[10] := MkSpec('mistral',    'Mistral',
                       pfOpenAI,     'https://api.mistral.ai',
                       'mistral-large-latest',
                       MkAuth(asBearer),
                       'Mistral Large / Magistral / Devstral / Voxtral / Codestral');
  Result[11] := MkSpec('nvidia',     'NVIDIA NIM',
                       pfOpenAI,     'https://integrate.api.nvidia.com',
                       '',
                       MkAuth(asBearer),
                       'NVIDIA-hosted models');
  Result[12] := MkSpec('cerebras',   'Cerebras',
                       pfOpenAI,     'https://api.cerebras.ai',
                       '',
                       MkAuth(asBearer),
                       'Fast inference');
  Result[13] := MkSpec('novita',     'Novita AI',
                       pfOpenAI,     'https://api.novita.ai',
                       '',
                       MkAuth(asBearer),
                       'Various open models');
  Result[14] := MkSpec('mimo',       'Xiaomi MiMo',
                       pfOpenAI,     '',
                       '',
                       MkAuth(asBearer),
                       'MiMo (set api_base in config)');
  Result[15] := MkSpec('ollama',     'Ollama (local)',
                       pfOpenAI,     'http://localhost:11434',
                       '',
                       MkAuth(asNone),
                       'Local models, self-hosted');
  Result[16] := MkSpec('vllm',       'vLLM (local)',
                       pfOpenAI,     'http://localhost:8000',
                       '',
                       MkAuth(asNone),
                       'OpenAI-compatible local deployment');
  Result[17] := MkSpec('litellm',    'LiteLLM proxy',
                       pfOpenAI,     '',
                       '',
                       MkAuth(asBearer),
                       'Proxy for 100+ providers (set api_base)');
  Result[18] := MkSpec('gemini',     'Google Gemini',
                       pfGemini,     'https://generativelanguage.googleapis.com',
                       'gemini-3.5-flash',
                       MkAuth(asHeader, 'x-goog-api-key'),
                       'Gemini 3.1 Pro / 3 Flash / 3.1 Flash Lite / 3.1 Flash Image');
  (* xAI Grok exposes a strict OpenAI-compatible chat-completions API
     at https://api.x.ai/v1/chat/completions, Bearer auth, identical
     request/response shape. The pfOpenAI provider talks to it
     unchanged. Default points at grok-4-fast — operator can override
     to grok-3 / grok-code-fast-1 / grok-2 / etc. via config or the
     onboarding prompt. *)
  Result[19] := MkSpec('xai',        'xAI (Grok)',
                       pfOpenAI,     'https://api.x.ai',
                       'grok-4-fast',
                       MkAuth(asBearer),
                       'Grok 4 Fast / Grok 3 / Grok Code Fast 1');
  (* Cohere v2 ships its chat API at https://api.cohere.com/v2/chat —
     same Bearer auth as OpenAI but a different URL path
     (/v2/chat vs /v1/chat/completions). The pfOpenAI provider
     hard-codes the OpenAI path, so Cohere can't piggyback on it
     without a path-override knob. Registered as pfPlaceholder so
     the kind validates in config.json and shows up in
     `pasclaw onboard`, with a clear "implementation not yet
     bundled" error when actually selected. Future PR can add a
     dedicated TCohereProvider that mirrors the v2 wire shape
     (messages array, tool_calls similar to OpenAI, citations
     surfaced on assistant turns). *)
  Result[20] := MkSpec('cohere',     'Cohere',
                       pfPlaceholder, 'https://api.cohere.com',
                       'command-a-03-2025',
                       MkAuth(asBearer),
                       'Command A 03-2025 / Command A Reasoning / Command A Vision');
end;

function LookupProvider(const Kind: string; out Spec: TProviderSpec): Boolean;
var
  Cat: TProviderSpecArray;
  i: Integer;
  Lower: string;
begin
  Result := False;
  Lower := LowerCase(Trim(Kind));
  if Lower = '' then Exit;
  Cat := BuildCatalog;
  for i := 0 to High(Cat) do
    if Cat[i].Kind = Lower then
    begin
      Spec := Cat[i];
      Exit(True);
    end;
end;

function CompareSpecs(const A, B: TProviderSpec): Integer;
begin
  Result := CompareText(A.DisplayName, B.DisplayName);
end;

function AllProviderSpecs: TProviderSpecArray;
var
  i, j: Integer;
  Tmp: TProviderSpec;
begin
  Result := BuildCatalog;
  { Simple insertion sort by DisplayName — list is small and we'd rather
    avoid pulling in System.Generics.Collections just for this. }
  for i := 1 to High(Result) do
  begin
    Tmp := Result[i];
    j := i;
    while (j > 0) and (CompareSpecs(Result[j - 1], Tmp) > 0) do
    begin
      Result[j] := Result[j - 1];
      Dec(j);
    end;
    Result[j] := Tmp;
  end;
end;

function DefaultBaseFor(const Kind: string): string;
var
  Spec: TProviderSpec;
begin
  if LookupProvider(Kind, Spec) then
    Result := Spec.DefaultBase
  else
    Result := '';
end;

end.
