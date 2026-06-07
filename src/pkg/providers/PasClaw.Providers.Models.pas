(*
  PasClaw.Providers.Models — live `/v1/models` discovery + on-disk cache.

  Three providers / one shape, all driven off TProviderSpec.Family:

    pfOpenAI     GET <base>/v1/models with Bearer auth (or no auth for
                 Ollama/vLLM/LM Studio with asNone). Response shape:
                 { "data": [ { "id":"gpt-4o-mini", "created":<unix>,
                               "owned_by":"openai" }, ... ] }
                 Used by openai, openrouter, groq, deepseek, mistral,
                 xai, qwen, zhipu, cerebras, moonshot, ollama, vllm,
                 lmstudio, litellm — anything pfOpenAI-family. Each row
                 in the catalog shares this parser.

    pfAnthropic  GET <base>/v1/models with x-api-key auth +
                 anthropic-version header. Response shape:
                 { "data": [ { "id":"claude-opus-4-7",
                               "display_name":"Claude Opus 4.7",
                               "created_at":"2026-...Z" }, ... ] }

    pfGemini     GET <base>/v1beta/models?key=<key>. Response shape:
                 { "models": [ { "name":"models/gemini-3-flash",
                                 "displayName":"Gemini 3 Flash",
                                 "supportedGenerationMethods":["generateContent",...] },
                               ... ] }
                 We strip the "models/" prefix to get the wire id, and
                 filter out entries that don't list "generateContent" —
                 catalog rows like embedding-only or counter-only
                 models would 404 the chat path anyway.

  Cache lives at $PASCLAW_HOME/cache/models/<provider-name>.json with
  a fetched_at timestamp; LoadCachedModels signals staleness so
  `pasclaw model show` can suggest a refresh and onboarding can decide
  whether to refetch silently in the background.

  Cache key is the operator-facing TProviderConfig.Name (NOT the
  catalog Spec.Kind), so two named providers sharing one Kind but
  pointing at different APIBase/keys — supported by
  NewProviderFromConfig — each get their own roster file and don't
  clobber one another (Codex P2 on PR #171).

  Discovery never raises. Failure modes:
    - HTTP non-2xx          Ok=False, Source='', ErrMsg=<status>
    - JSON parse error      Ok=False, ErrMsg=<parse>
    - Empty model list      Ok=True with Length=0 (caller's choice)
    - Placeholder family    Ok=False, ErrMsg='not supported'

  The catalog's static DefaultModel still wins when discovery fails —
  Tools.Memory's "fall back to FTS5" pattern, applied to onboarding's
  model picker.
*)
unit PasClaw.Providers.Models;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Catalog;

type
  TModelInfo = record
    Id:        string;       { wire id used in the chat request }
    Display:   string;       { human label if the provider gives one,
                               else Id verbatim }
    CreatedAt: Int64;        { unix seconds; 0 when the provider doesn't
                               expose creation time. Used for sort order
                               in the onboarding picker — newest first. }
  end;
  TModelInfoArray = array of TModelInfo;

  TModelDiscoveryResult = record
    Ok:        Boolean;       { True iff Models is the authoritative list
                                from the provider — even if Length=0 }
    Models:    TModelInfoArray;
    Source:    string;        { 'live' / 'cache' / 'fallback' — used for
                                the show command's "(cached 3 days ago)"
                                style annotation }
    ErrMsg:    string;        { populated when Ok=False; safe to surface
                                to the operator }
    FetchedAt: Int64;         { unix seconds; the cache's "as of" date }
  end;

(* Returns the cache file path even when the file doesn't exist. Caller
   doesn't need to create $PASCLAW_HOME/cache/models/ first;
   SaveCachedModels handles that. *)
function ModelCachePath(const Provider: string): string;

(* Returns False when no cache exists. When True, Result.Ok=True,
   Result.Source='cache', Result.FetchedAt is the original fetch's
   timestamp. *)
function LoadCachedModels(const Provider: string;
                          out R: TModelDiscoveryResult): Boolean;

procedure SaveCachedModels(const Provider: string;
                           const R: TModelDiscoveryResult);

(* Live discovery against the provider's /v1/models (or equivalent).
   Pass the resolved APIBase + APIKey from the operator's TConfig —
   the catalog default is fine when the operator hasn't overridden.
   Times out after TimeoutSec seconds; returns Ok=False with ErrMsg
   populated on any failure. *)
function DiscoverModels(const Spec: TProviderSpec;
                        const APIBase, APIKey: string;
                        TimeoutSec: Integer = 10): TModelDiscoveryResult;

(* Human-readable "5 days ago" / "23 minutes ago" / "just now" for
   the cache freshness annotation. Caps at "1+ year ago" so old
   caches don't get a misleading huge number. *)
function HumanAge(UnixSeconds: Int64): string;

implementation

uses
  DateUtils,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.JSON,
  PasClaw.Providers.HTTP,
  PasClaw.Providers.Types;

const
  CACHE_SUBDIR = 'cache';          { two-segment subpath so JoinPath gets
                                     the host PathDelim right — same trap
                                     PR #169 fixed elsewhere }
  CACHE_LEAF   = 'models';
  ANTHROPIC_VERSION_HEADER_VALUE = '2023-06-01';

{ ============================ path helpers ============================ }

function CacheDir: string;
begin
  Result := JoinPath(JoinPath(GetHome, CACHE_SUBDIR), CACHE_LEAF);
end;

function ModelCachePath(const Provider: string): string;
begin
  Result := JoinPath(CacheDir, LowerCase(Provider) + '.json');
end;

{ ============================ cache IO ============================ }

function SerializeCache(const R: TModelDiscoveryResult): string;
var
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Root.PutInt('fetched_at', R.FetchedAt);
    Arr := TJsonArray.Create;
    for i := 0 to High(R.Models) do
    begin
      Item := TJsonObject.Create;
      Item.PutStr('id', R.Models[i].Id);
      if R.Models[i].Display <> '' then
        Item.PutStr('display', R.Models[i].Display);
      if R.Models[i].CreatedAt > 0 then
        Item.PutInt('created_at', R.Models[i].CreatedAt);
      Arr.AddObject(Item);
    end;
    Root.PutArray('models', Arr);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function DeserializeCache(const S: string; out R: TModelDiscoveryResult): Boolean;
var
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
  M: TModelInfo;
begin
  Result := False;
  R := Default(TModelDiscoveryResult);
  try
    Root := TJsonObject.Parse(S);
  except
    Exit;
  end;
  if Root = nil then Exit;
  try
    R.FetchedAt := Root.GetInt('fetched_at', 0);
    Arr := Root.ChildArray('models');
    if Arr = nil then Exit;
    try
      SetLength(R.Models, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          M.Id        := Item.GetStr('id', '');
          M.Display   := Item.GetStr('display', M.Id);
          M.CreatedAt := Item.GetInt('created_at', 0);
          R.Models[i] := M;
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
    R.Ok     := True;
    R.Source := 'cache';
    Result   := True;
  finally
    Root.Free;
  end;
end;

function LoadCachedModels(const Provider: string;
                          out R: TModelDiscoveryResult): Boolean;
var
  Path, Body: string;
begin
  R := Default(TModelDiscoveryResult);
  Path := ModelCachePath(Provider);
  if not FileExists(Path) then Exit(False);
  try
    Body := ReadFileText(Path);
  except
    on E: Exception do
    begin
      LogDebug('model cache: read failed for %s — %s', [Path, E.Message]);
      Exit(False);
    end;
  end;
  Result := DeserializeCache(Body, R);
end;

procedure SaveCachedModels(const Provider: string;
                           const R: TModelDiscoveryResult);
var
  Path: string;
begin
  Path := ModelCachePath(Provider);
  try
    EnsureDir(ExtractFilePath(Path));
    WriteFileText(Path, SerializeCache(R));
  except
    on E: Exception do
      LogDebug('model cache: write failed for %s — %s', [Path, E.Message]);
  end;
end;

{ ============================ HTTP helpers ============================ }

function StripTrailingSlash(const S: string): string;
begin
  if (S <> '') and (S[Length(S)] = '/') then
    Result := Copy(S, 1, Length(S) - 1)
  else
    Result := S;
end;

function FetchURL(const URL: string; const Headers: array of THeaderPair;
                  TimeoutSec: Integer; out Body: string; out Status: Integer): Boolean;
var
  Resp: THTTPResult;
begin
  Result := False;
  Body   := '';
  Status := 0;
  try
    Resp := GetJSONURL(URL, Headers, TimeoutSec);
  except
    on E: Exception do
    begin
      Body := E.Message;
      Exit;
    end;
  end;
  Status := Resp.StatusCode;
  Body   := Resp.Body;
  Result := (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
end;

{ Parse an ISO-8601 timestamp to unix seconds. Returns 0 on any failure
  — the caller treats 0 as "no creation time" which is the same fallback
  used by providers that don't surface created_at at all. We don't need
  millisecond accuracy; the field is only used for picker sort order. }
function ParseISO8601(const S: string): Int64;
var
  DT: TDateTime;
  Year, Month, Day, Hour, Min, Sec: Word;
  Tmp: string;
begin
  Result := 0;
  if Length(S) < 19 then Exit;
  try
    Tmp := Copy(S, 1, 19);
    Year  := StrToInt(Copy(Tmp, 1,  4));
    Month := StrToInt(Copy(Tmp, 6,  2));
    Day   := StrToInt(Copy(Tmp, 9,  2));
    Hour  := StrToInt(Copy(Tmp, 12, 2));
    Min   := StrToInt(Copy(Tmp, 15, 2));
    Sec   := StrToInt(Copy(Tmp, 18, 2));
    DT := EncodeDate(Year, Month, Day) +
          EncodeTime(Hour, Min, Sec, 0);
    Result := DateTimeToUnix(DT, {AInputIsUTC=} True);
  except
    Result := 0;
  end;
end;

{ Strip the "models/" namespace prefix Gemini wraps everything in. The
  chat path takes the bare id (e.g. "gemini-3-flash") but /v1beta/models
  reports it as "models/gemini-3-flash". }
function StripModelsPrefix(const S: string): string;
const
  PREFIX = 'models/';
begin
  if Pos(PREFIX, S) = 1 then
    Result := Copy(S, Length(PREFIX) + 1, MaxInt)
  else
    Result := S;
end;

{ ============================ family parsers ============================ }

procedure ParseOpenAIShape(const Body: string;
                           var R: TModelDiscoveryResult);
var
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  i, N: Integer;
  M: TModelInfo;
begin
  try
    Root := TJsonObject.Parse(Body);
  except
    on E: Exception do
    begin
      R.ErrMsg := 'JSON parse: ' + E.Message;
      Exit;
    end;
  end;
  if Root = nil then
  begin
    R.ErrMsg := 'empty response';
    Exit;
  end;
  try
    Arr := Root.ChildArray('data');
    if Arr = nil then
    begin
      R.ErrMsg := 'response has no "data" array';
      Exit;
    end;
    try
      N := Arr.Count;
      SetLength(R.Models, N);
      for i := 0 to N - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          M.Id        := Item.GetStr('id', '');
          M.Display   := M.Id;             { OpenAI-shape never exposes display name }
          M.CreatedAt := Item.GetInt('created', 0);
          R.Models[i] := M;
        finally
          Item.Free;
        end;
      end;
      R.Ok := True;
    finally
      Arr.Free;
    end;
  finally
    Root.Free;
  end;
end;

procedure ParseAnthropicShape(const Body: string;
                              var R: TModelDiscoveryResult);
var
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  i, N: Integer;
  M: TModelInfo;
begin
  try
    Root := TJsonObject.Parse(Body);
  except
    on E: Exception do
    begin
      R.ErrMsg := 'JSON parse: ' + E.Message;
      Exit;
    end;
  end;
  if Root = nil then
  begin
    R.ErrMsg := 'empty response';
    Exit;
  end;
  try
    Arr := Root.ChildArray('data');
    if Arr = nil then
    begin
      R.ErrMsg := 'response has no "data" array';
      Exit;
    end;
    try
      N := Arr.Count;
      SetLength(R.Models, N);
      for i := 0 to N - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          M.Id        := Item.GetStr('id', '');
          M.Display   := Item.GetStr('display_name', M.Id);
          M.CreatedAt := ParseISO8601(Item.GetStr('created_at', ''));
          R.Models[i] := M;
        finally
          Item.Free;
        end;
      end;
      R.Ok := True;
    finally
      Arr.Free;
    end;
  finally
    Root.Free;
  end;
end;

procedure ParseGeminiShape(const Body: string;
                           var R: TModelDiscoveryResult);
var
  Root, Item: TJsonObject;
  Arr, Methods: TJsonArray;
  i, j, N, Kept: Integer;
  M: TModelInfo;
  SupportsChat: Boolean;
  Method: string;
begin
  try
    Root := TJsonObject.Parse(Body);
  except
    on E: Exception do
    begin
      R.ErrMsg := 'JSON parse: ' + E.Message;
      Exit;
    end;
  end;
  if Root = nil then
  begin
    R.ErrMsg := 'empty response';
    Exit;
  end;
  try
    Arr := Root.ChildArray('models');
    if Arr = nil then
    begin
      R.ErrMsg := 'response has no "models" array';
      Exit;
    end;
    try
      N := Arr.Count;
      SetLength(R.Models, N);
      Kept := 0;
      for i := 0 to N - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          { Filter to chat-capable rows. /v1beta/models lists embedders,
            counters, and aspirational previews alongside the chat models;
            anything missing generateContent in supportedGenerationMethods
            would 404 the chat path. }
          SupportsChat := False;
          Methods := Item.ChildArray('supportedGenerationMethods');
          if Methods <> nil then
          try
            for j := 0 to Methods.Count - 1 do
            begin
              Method := Methods.ItemStr(j, '');
              if SameText(Method, 'generateContent') then
              begin
                SupportsChat := True;
                Break;
              end;
            end;
          finally
            Methods.Free;
          end;
          if not SupportsChat then Continue;

          M.Id        := StripModelsPrefix(Item.GetStr('name', ''));
          M.Display   := Item.GetStr('displayName', M.Id);
          M.CreatedAt := 0;           { Gemini doesn't expose creation time }
          R.Models[Kept] := M;
          Inc(Kept);
        finally
          Item.Free;
        end;
      end;
      SetLength(R.Models, Kept);
      R.Ok := True;
    finally
      Arr.Free;
    end;
  finally
    Root.Free;
  end;
end;

{ ============================ family fetchers ============================ }

procedure FetchOpenAIFamily(const Spec: TProviderSpec;
                            const APIBase, APIKey: string;
                            TimeoutSec: Integer;
                            var R: TModelDiscoveryResult);
var
  URL, Body: string;
  Status: Integer;
  Headers: array of THeaderPair;
begin
  URL := StripTrailingSlash(APIBase) + '/v1/models';
  case Spec.Auth.Kind of
    asNone:
      SetLength(Headers, 0);
    asBearer:
      begin
        SetLength(Headers, 1);
        Headers[0] := MakeHeader('Authorization', 'Bearer ' + APIKey);
      end;
  else
    SetLength(Headers, 1);
    Headers[0] := MakeHeader(Spec.Auth.HeaderName, APIKey);
  end;

  if not FetchURL(URL, Headers, TimeoutSec, Body, Status) then
  begin
    R.ErrMsg := Format('GET %s → %d', [URL, Status]);
    if Body <> '' then R.ErrMsg := R.ErrMsg + ' (' + Body + ')';
    Exit;
  end;
  ParseOpenAIShape(Body, R);
end;

procedure FetchAnthropicFamily(const Spec: TProviderSpec;
                               const APIBase, APIKey: string;
                               TimeoutSec: Integer;
                               var R: TModelDiscoveryResult);
var
  URL, Body: string;
  Status: Integer;
  Headers: array of THeaderPair;
begin
  URL := StripTrailingSlash(APIBase) + '/v1/models';
  SetLength(Headers, 2);
  Headers[0] := MakeHeader('x-api-key', APIKey);
  Headers[1] := MakeHeader('anthropic-version', ANTHROPIC_VERSION_HEADER_VALUE);

  if not FetchURL(URL, Headers, TimeoutSec, Body, Status) then
  begin
    R.ErrMsg := Format('GET %s → %d', [URL, Status]);
    if Body <> '' then R.ErrMsg := R.ErrMsg + ' (' + Body + ')';
    Exit;
  end;
  ParseAnthropicShape(Body, R);
end;

procedure FetchGeminiFamily(const Spec: TProviderSpec;
                            const APIBase, APIKey: string;
                            TimeoutSec: Integer;
                            var R: TModelDiscoveryResult);
var
  URL, Body: string;
  Status: Integer;
  Headers: array of THeaderPair;
begin
  { Gemini takes the key via x-goog-api-key header — same shape as the
    chat path so the Auth.HeaderName from the catalog applies. Path
    is /v1beta/models, NOT /v1/models. }
  URL := StripTrailingSlash(APIBase) + '/v1beta/models';
  SetLength(Headers, 1);
  Headers[0] := MakeHeader(Spec.Auth.HeaderName, APIKey);

  if not FetchURL(URL, Headers, TimeoutSec, Body, Status) then
  begin
    R.ErrMsg := Format('GET %s → %d', [URL, Status]);
    if Body <> '' then R.ErrMsg := R.ErrMsg + ' (' + Body + ')';
    Exit;
  end;
  ParseGeminiShape(Body, R);
end;

{ ============================ entry point ============================ }

function DiscoverModels(const Spec: TProviderSpec;
                        const APIBase, APIKey: string;
                        TimeoutSec: Integer): TModelDiscoveryResult;
var
  Base: string;
begin
  Result := Default(TModelDiscoveryResult);
  Result.FetchedAt := DateTimeToUnix(Now, {AInputIsUTC=} False);

  if Spec.Family = pfPlaceholder then
  begin
    Result.ErrMsg := 'discovery not supported for placeholder kind "' + Spec.Kind + '"';
    Exit;
  end;

  if (Spec.Auth.Kind <> asNone) and (Trim(APIKey) = '') then
  begin
    Result.ErrMsg := 'API key required for ' + Spec.DisplayName + ' /models endpoint';
    Exit;
  end;

  Base := APIBase;
  if Base = '' then Base := Spec.DefaultBase;
  if Base = '' then
  begin
    Result.ErrMsg := 'no API base — set Cfg.Providers[].APIBase or the catalog DefaultBase';
    Exit;
  end;

  case Spec.Family of
    pfOpenAI:    FetchOpenAIFamily   (Spec, Base, APIKey, TimeoutSec, Result);
    pfAnthropic: FetchAnthropicFamily(Spec, Base, APIKey, TimeoutSec, Result);
    pfGemini:    FetchGeminiFamily   (Spec, Base, APIKey, TimeoutSec, Result);
  else
    Result.ErrMsg := 'unknown protocol family for ' + Spec.Kind;
    Exit;
  end;
  if Result.Ok then Result.Source := 'live';
end;

function HumanAge(UnixSeconds: Int64): string;
var
  Delta: Int64;
begin
  if UnixSeconds <= 0 then Exit('unknown');
  Delta := DateTimeToUnix(Now, False) - UnixSeconds;
  if Delta < 0 then Delta := 0;
  if Delta < 60 then
    Exit('just now')
  else if Delta < 3600 then
    Exit(Format('%d minute(s) ago', [Delta div 60]))
  else if Delta < 86400 then
    Exit(Format('%d hour(s) ago', [Delta div 3600]))
  else if Delta < 86400 * 365 then
    Exit(Format('%d day(s) ago', [Delta div 86400]))
  else
    Exit('over a year ago');
end;

end.
