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
    pfRelay,       { pull-worker pattern -- external workers connect
                     INBOUND via /v1/relay/poll and serve inference on
                     their own hardware. The provider has no outbound
                     URL; the queue is in-process. See
                     PasClaw.Providers.Relay + PasClaw.Gateway.RelayQueue. }
    pfPlaceholder  { kind known, no implementation yet -- Bedrock/Azure/etc. }
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
    ChatPath:     string;            { path appended to the base for chat
                                       completions; '/v1/chat/completions' for
                                       OpenAI-shaped APIs, but e.g. Perplexity
                                       uses '/chat/completions' (no /v1) }
  end;

  TProviderSpecArray = array of TProviderSpec;

{ Returns True and fills Spec when Kind matches a catalog entry
  (case-insensitive). Returns False otherwise. }
function LookupProvider(const Kind: string; out Spec: TProviderSpec): Boolean;

{ Returns a copy of every catalog entry, ordered by DisplayName, suitable
  for menus. The list is small (~19 entries) and rebuilt on each call --
  callers are not expected to call this in a hot loop. }
function AllProviderSpecs: TProviderSpecArray;

{ Helper that returns the default base URL for a kind, or '' if no such
  kind exists. Convenience for callers that don't need the full spec. }
function DefaultBaseFor(const Kind: string): string;

(* The quick, cheap model of a provider family, or '' when we do not know
   one.

   Some work does not need the good model. A one-shot search page is a
   summarise-and-format job: the flagship costs more, takes longer, and
   produces a page no better than the small model's -- which is why the
   hosted assistants people compare this to run their quick answers on a
   Flash Lite or a mini. Deep research is the opposite and keeps the main
   model; it plans, reads several sources and synthesises, which is exactly
   the reasoning the big model is for.

   Names, not capability probes: there is no API that answers "which of
   your models is cheapest", so this is a table, and a table goes stale.
   It is therefore the LAST resort -- an explicit fast_model, then the
   auto-router's easy tier, then this -- and an unknown provider returns ''
   so the caller keeps the model it already had rather than guessing. *)
function FastModelFor(const Kind: string): string;

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
                const Auth: TAuthScheme; const Notes: string;
                const ChatPath: string = '/v1/chat/completions'): TProviderSpec;
begin
  Result.Kind         := Kind;
  Result.DisplayName  := DisplayName;
  Result.Family       := Family;
  Result.DefaultBase  := DefaultBase;
  Result.DefaultModel := DefaultModel;
  Result.Auth         := Auth;
  Result.Notes        := Notes;
  Result.ChatPath     := ChatPath;
end;

{ The catalog. New providers go here -- one entry per row, no other code
  change required for OpenAI-compatible endpoints. }
function BuildCatalog: TProviderSpecArray;
begin
  SetLength(Result, 26);
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
  (* Moonshot model defaults are time-sensitive -- Codex P2 on PR #163
     caught the previous catalog rolling forward to kimi-k2, which
     Moonshot discontinued the entire k2 series on 2026-05-25
     (per https://platform.kimi.ai/docs/models). The active line at
     time of writing is k2.5 / k2.6 / k2-thinking; default to k2.6
     which Moonshot lists as the current flagship. Refresh this row
     when Moonshot rolls the next generation. *)
  Result[8]  := MkSpec('moonshot',   'Moonshot (Kimi)',
                       pfOpenAI,     'https://api.moonshot.cn',
                       'kimi-k2.6',
                       MkAuth(asBearer),
                       'Kimi K2.6 / K2.5 / K2-Thinking');
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
  (* LM Studio runs an OpenAI-compatible server on port 1234 by
     default and emits the same /v1/chat/completions shape -- same
     pfOpenAI + asNone profile as Ollama. DefaultModel left empty
     because the loaded model id depends on whatever the operator
     downloaded inside the LM Studio UI; the onboarding prompt
     surfaces the catalog default so blank picks up whichever
     model is loaded at request time (LM Studio routes a missing
     model id to the currently-loaded one). *)
  Result[16] := MkSpec('lmstudio',   'LM Studio (local)',
                       pfOpenAI,     'http://localhost:1234',
                       '',
                       MkAuth(asNone),
                       'Local OpenAI-compatible server (default port 1234)');
  Result[17] := MkSpec('vllm',       'vLLM (local)',
                       pfOpenAI,     'http://localhost:8000',
                       '',
                       MkAuth(asNone),
                       'OpenAI-compatible local deployment');
  Result[18] := MkSpec('litellm',    'LiteLLM proxy',
                       pfOpenAI,     '',
                       '',
                       MkAuth(asBearer),
                       'Proxy for 100+ providers (set api_base)');
  Result[19] := MkSpec('gemini',     'Google Gemini',
                       pfGemini,     'https://generativelanguage.googleapis.com',
                       'gemini-3.5-flash',
                       MkAuth(asHeader, 'x-goog-api-key'),
                       'Gemini 3.1 Pro / 3 Flash / 3.1 Flash Lite / 3.1 Flash Image');
  (* xAI Grok exposes a strict OpenAI-compatible chat-completions API
     at https://api.x.ai/v1/chat/completions, Bearer auth, identical
     request/response shape. The pfOpenAI provider talks to it
     unchanged. Default points at grok-4-fast -- operator can override
     to grok-3 / grok-code-fast-1 / grok-2 / etc. via config or the
     onboarding prompt. *)
  Result[20] := MkSpec('xai',        'xAI (Grok)',
                       pfOpenAI,     'https://api.x.ai',
                       'grok-4-fast',
                       MkAuth(asBearer),
                       'Grok 4 Fast / Grok 3 / Grok Code Fast 1');
  { Perplexity speaks the OpenAI chat shape but at /chat/completions
    (no /v1) -- handled via the ChatPath override. Sonar models are
    web-grounded; no separate /models discovery endpoint, so the catalog
    DefaultModel stands in. }
  Result[21] := MkSpec('perplexity', 'Perplexity (Sonar)',
                       pfOpenAI,     'https://api.perplexity.ai',
                       'sonar',
                       MkAuth(asBearer),
                       'Sonar / Sonar Pro / Sonar Reasoning (web-grounded)',
                       '/chat/completions');
  (* Cloudflare AI Gateway. Two URL shapes operators paste into
     api_base, both OpenAI Chat Completions compatible:

       AI Gateway compat proxy (caching, rate limits, analytics,
       multi-provider routing -- the headline feature, and what this
       catalog row is named after):
         https://gateway.ai.cloudflare.com/v1/{ACCOUNT_ID}/{GATEWAY_ID}/compat
         + ChatPath /chat/completions
         => POST .../{GATEWAY_ID}/compat/chat/completions

       Workers AI direct (no gateway features; bypasses the AI Gateway
       entirely and hits Workers AI's own OpenAI-compat endpoint):
         https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/ai/v1
         + ChatPath /chat/completions
         => POST .../ai/v1/chat/completions

     Both expect Authorization: Bearer <CLOUDFLARE_API_TOKEN>; both
     return the same OpenAI-shaped response. ChatPath is /chat/completions
     (no /v1) -- like Perplexity -- because the /v1 segment is part of
     the Cloudflare URL prefix, not the OpenAI path. DefaultBase empty
     because the URL embeds the operator's account_id (same as mimo /
     litellm).

     DefaultModel uses the compat endpoint's {provider}/{model} routing
     format (Codex P2 on PR #316 -- the bare `@cf/...` form the row
     shipped with works for the direct path but the compat path
     rejects unprefixed model ids because it has to pick which upstream
     to forward to). `workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast`
     routes through Workers AI on the compat path AND is overridable
     to any other compat-supported upstream (openai/gpt-5.2,
     anthropic/claude-sonnet-4-5, google-ai-studio/gemini-2.5-flash,
     etc.) via the per-request model field. Operators on the direct
     Workers AI path override the model to bare `@cf/...` (or use the
     cloudflare-workers-ai sibling row if one ever lands). Docs:
     https://developers.cloudflare.com/ai-gateway/usage/chat-completion/
     + https://developers.cloudflare.com/workers-ai/. *)
  Result[22] := MkSpec('cloudflare', 'Cloudflare AI Gateway',
                       pfOpenAI,     '',
                       'workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast',
                       MkAuth(asBearer),
                       'AI Gateway proxy (set api_base to .../compat; Bearer = CLOUDFLARE_API_TOKEN; model uses {provider}/{model} routing -- workers-ai/@cf/..., openai/..., anthropic/..., google-ai-studio/...)',
                       '/chat/completions');
  (* Cloudflare AI Gateway -- Anthropic passthrough. Routes Anthropic-
     shaped requests through a named gateway for caching / rate
     limiting / analytics, then forwards to api.anthropic.com upstream.
     The pfAnthropic provider appends /v1/messages to api_base, so:

       api_base = https://gateway.ai.cloudflare.com/v1/{ACCT}/{GW}/anthropic
       URL      = .../anthropic/v1/messages

     Auth is the operator's ANTHROPIC api key in x-api-key (Cloudflare
     forwards the upstream auth header unmodified). Operators with
     "Authenticated Gateway" set on their CF gateway also need a
     `cf-aig-authorization` header -- not supported here in V1, so
     leave the gateway unauthenticated or wait for follow-up. *)
  Result[23] := MkSpec('cloudflare-anthropic', 'Cloudflare AI Gateway (Anthropic)',
                       pfAnthropic,  '',
                       'claude-opus-4-7',
                       MkAuth(asHeader, 'x-api-key'),
                       'AI Gateway proxy to Anthropic (set api_base to .../gateway/anthropic; x-api-key = your Anthropic key)');
  (* Cloudflare AI Gateway -- Gemini passthrough. Same pattern as the
     Anthropic row but the upstream slug is "google-ai-studio" and
     the path the pfGemini provider appends is
     /v1beta/models/<model>:generateContent:

       api_base = https://gateway.ai.cloudflare.com/v1/{ACCT}/{GW}/google-ai-studio
       URL      = .../google-ai-studio/v1beta/models/<model>:generateContent

     Auth is the operator's GEMINI api key in x-goog-api-key. *)
  Result[24] := MkSpec('cloudflare-gemini',    'Cloudflare AI Gateway (Gemini)',
                       pfGemini,     '',
                       'gemini-3.5-flash',
                       MkAuth(asHeader, 'x-goog-api-key'),
                       'AI Gateway proxy to Gemini (set api_base to .../gateway/google-ai-studio; x-goog-api-key = your Gemini key)');
  (* Relay (pull-worker) -- external workers connect INBOUND to
     `pasclaw gateway`'s /v1/relay/poll SSE endpoint, advertise the
     models they can serve, pull pending requests off the queue, run
     inference on their own hardware, and POST results back. The
     provider has no api_base because the queue is in-process; the
     worker uses the existing PASCLAW_GATEWAY_TOKEN for auth on the
     poll/respond endpoints. DefaultModel empty -- whatever the
     connected workers advertise via X-Relay-Capabilities. Operators
     wire up a reference HTML worker (tools/relay-worker/index.html)
     or roll their own HTTP+SSE client (llama.cpp wrapper, mlc-llm,
     Transformers.js, WebLLM, ...). See PasClaw.Providers.Relay +
     PasClaw.Gateway.RelayQueue + docs/providers-relay.md. *)
  Result[25] := MkSpec('relay',       'Relay (Pull-Worker)',
                       pfRelay,       '',
                       '',
                       MkAuth(asNone),
                       'Pull-worker pattern: external apps connect to the gateway and serve inference locally. No outbound HTTP from PasClaw; model name matches what the worker advertises.');
  (* Cohere intentionally not in this catalog: their chat API lives at
     /v2/chat with a non-OpenAI request/response body, so the ChatPath
     override alone isn't enough -- it needs a real TCohereProvider (or
     pfOpenAI body adapters). Until then a placeholder row is more
     confusing than helpful. *)
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
  { Simple insertion sort by DisplayName -- list is small and we'd rather
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

function FastModelFor(const Kind: string): string;
var
  K: string;
begin
  K := LowerCase(Trim(Kind));
  if K = 'gemini' then Result := 'gemini-3.5-flash-lite'
  else if K = 'anthropic' then Result := 'claude-haiku-4-5-20251001'
  else if K = 'openai' then Result := 'gpt-4o-mini'
  else if K = 'groq' then Result := 'llama-3.1-8b-instant'
  else if K = 'mistral' then Result := 'mistral-small-latest'
  else if K = 'deepseek' then Result := 'deepseek-chat'
  else if K = 'together' then Result := 'meta-llama/Llama-3.2-3B-Instruct-Turbo'
  else if K = 'openrouter' then Result := 'google/gemini-2.5-flash-lite'
  else
    { Unknown, or a proxy whose model names are the upstream's (litellm,
      ollama, lmstudio, a local server): no guess is better than a wrong
      one, and the caller keeps whatever it had. }
    Result := '';
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
