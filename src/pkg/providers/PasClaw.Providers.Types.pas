{
  PasClaw.Providers.Types - protocol type records shared by every LLM provider.
  Mirrors pkg/providers/protocoltypes in picoclaw.
}
unit PasClaw.Providers.Types;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  { Role for a chat message. }
  TMsgRole = (mrSystem, mrUser, mrAssistant, mrTool);

  { One function-call requested by the model. }
  TFunctionCall = record
    Name:      string;
    Arguments: string;   { raw JSON }
  end;

  TToolCall = record
    Id:       string;
    Kind:     string;    { "function" for now }
    Func:     TFunctionCall;
    { Opaque provider-specific blob the assistant must echo back
      when sending the matching function/tool result. Currently used
      only by Gemini 3+ (the `thoughtSignature` on functionCall
      parts) -- Gemini 3 rejects the follow-up request with a 400
      "Function call is missing a thought_signature" if it's
      dropped. Empty for other providers and for Gemini 2.x. }
    ProviderSignature: string;
  end;

  { A chat message. The Content field holds plain text; ToolCalls and
    ToolCallId are non-empty for assistant tool-call responses and tool-result
    inputs respectively. }
  TMessage = record
    Role:       TMsgRole;
    Content:    string;
    Name:       string;
    ToolCallId: string;
    ToolCalls:  array of TToolCall;
  end;

  { A tool exposed to the model (OpenAI-compatible function shape; Anthropic
    translates this at the edge). }
  TToolDefinition = record
    Name:        string;
    Description: string;
    Schema:      string;   { JSON schema for parameters }
  end;

  TToolDefinitionArray = array of TToolDefinition;
  TMessageArray        = array of TMessage;
  TToolCallArray       = array of TToolCall;

  TUsageInfo = record
    InputTokens:        Integer;
    OutputTokens:       Integer;
    CacheReadTokens:    Integer;
    CacheCreatedTokens: Integer;
  end;

  TLLMResponse = record
    Content:    string;
    ToolCalls:  array of TToolCall;
    FinishReason: string;
    Usage:      TUsageInfo;
    Model:      string;
    { HTTP status code from the upstream provider. 0 means "not set"
      (older providers that haven't been updated to populate it).
      Used by the tool loop's provider-fallback logic to detect
      retryable errors (429 / 5xx) and walk the configured fallback
      chain. Successful responses set StatusCode := 200; non-HTTP
      errors (DNS, TLS, socket) set StatusCode := -1. }
    StatusCode: Integer;
  end;

  TStreamChunk = record
    Kind:     string;     { "text" | "tool_call" | "usage" | "done" }
    Text:     string;
    ToolCall: TToolCall;
    Usage:    TUsageInfo;
  end;

  { Generic chat options handed to a provider. Anything provider-specific is
    JSON-encoded into the Extra field rather than baking another type alias. }
  TChatOptions = record
    Temperature:   Double;
    MaxTokens:     Integer;
    Stream:        Boolean;
    SystemPrompt:  string;
    ThinkingLevel: string;   { "", "low", "medium", "high" }
    ToolChoice:    string;   { Tool-selection control. Recognised values:
                                 ""         -- do not emit; provider default
                                               (typically "auto" with tools)
                                 "auto"     -- model decides
                                 "none"     -- must not call a tool
                                 "required" -- must call some tool
                                 <tool name> -- force that specific tool.
                               Any non-empty value that isn't one of the three
                               keywords is treated as a tool/function NAME to
                               force; each provider emits its native object
                               shape (OpenAI type=function with function.name,
                               Anthropic type=tool with name). Gemini ignores
                               tool_choice entirely. }
    (* Prompt caching. When CacheEnabled, the Anthropic builder tags
       the system prompt and the trailing tools-array entry with an
       ephemeral cache_control breakpoint; the OpenAI builder emits
       prompt_cache_key so the back-end keys its automatic cache on
       a stable session id. Defaults: enabled, default TTL, empty
       key (no key = no OpenAI cache anchor, falls back to automatic
       prefix matching). CacheTTL accepts "" / "5m" / "1h" -- "1h"
       passes through as the Anthropic extended-TTL hint; other
       values are emitted verbatim. CacheKey should be stable across
       turns of the same conversation (e.g. the session id) so the
       cache prefix lines up. *)
    CacheEnabled:  Boolean;
    CacheTTL:      string;
    CacheKey:      string;
    Extra:         string;   { provider-specific JSON object }
  end;

function MsgRoleToString(R: TMsgRole): string;
function MsgRoleFromString(const S: string): TMsgRole;
function DefaultChatOptions: TChatOptions;
function MakeMessage(Role: TMsgRole; const Content: string): TMessage;

implementation

function MsgRoleToString(R: TMsgRole): string;
begin
  case R of
    mrSystem:    Result := 'system';
    mrUser:      Result := 'user';
    mrAssistant: Result := 'assistant';
    mrTool:      Result := 'tool';
  else
    Result := 'user';
  end;
end;

function MsgRoleFromString(const S: string): TMsgRole;
begin
  if      S = 'system'    then Result := mrSystem
  else if S = 'assistant' then Result := mrAssistant
  else if S = 'tool'      then Result := mrTool
  else                         Result := mrUser;
end;

function DefaultChatOptions: TChatOptions;
begin
  { Temperature defaults to 0 ("not set"). The Anthropic and OpenAI
    request builders only emit the `temperature` field when this is
    > 0, so a caller that never picks a value lets the provider use
    its server-side default. This avoids hitting Anthropic's
    "`temperature` is deprecated for this model" 400 on the newer
    Claude models, which reject the field outright. }
  Result.Temperature   := 0;
  { 8192 matches picoclaw's config.example.json and the recommended
    setting across nanobot's docs / examples (HKUDS/nanobot and
    nanobot-ai/nanobot both ship 8192 in their config examples).
    The previous 4096 was too tight for code-writing tool calls: a
    typical Pascal/TS unit easily exceeds 4k tokens in a single
    tool_use input, and Anthropic returns the partial JSON when the
    budget runs out -- see PR #41 for the fs_write fallout that
    motivated this. Callers can still override per-call via
    --max-tokens or the gateway's max_tokens request field. }
  Result.MaxTokens     := 8192;
  Result.Stream        := False;
  Result.SystemPrompt  := '';
  Result.ThinkingLevel := '';
  Result.ToolChoice    := '';
  { Prompt caching on by default -- Anthropic and OpenAI both no-op
    silently when the prefix is too short to be worth caching, so
    flipping this on costs nothing for short prompts and saves ~10x
    on long ones. Disable per-call via TPromptCacheConfig.Enabled
    (config.json) when you want to A/B without it. }
  Result.CacheEnabled  := True;
  Result.CacheTTL      := '';
  Result.CacheKey      := '';
  Result.Extra         := '';
end;

function MakeMessage(Role: TMsgRole; const Content: string): TMessage;
begin
  Result.Role       := Role;
  Result.Content    := Content;
  Result.Name       := '';
  Result.ToolCallId := '';
  SetLength(Result.ToolCalls, 0);
end;

end.
