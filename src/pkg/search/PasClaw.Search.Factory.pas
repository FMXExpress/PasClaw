(*
  PasClaw.Search.Factory - resolves the configured ISearchProvider
  from TConfig + env vars.

  Resolution order:
    1. cfg.WebSearch.Provider explicitly set: use that adapter, fail
       fast if a key (or base URL) is required but missing.
    2. Empty / unset: fall back to DuckDuckGo (no key needed).

  Env overrides win over cfg fields, matching how `pasclaw post` and
  the channel bots read $PASCLAW_* -- keeps secrets out of
  config.json for users who'd rather not commit them.

  Wave 1: duckduckgo, brave, tavily.
  Wave 2: searxng, perplexity.
  Wave 3: gemini (Google Search grounding via the Gemini Generative
          Language API). GLM (Zhipu) and Baidu (Qianfan) intentionally
          skipped -- narrower Delphi/FPC audience for those auth
          ceremonies.
*)
unit PasClaw.Search.Factory;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Search.Types;

function NewSearchProvider(const Cfg: TConfig; out ErrMsg: string): ISearchProvider;

{ True when the operator has a real (non-DDG) provider configured --
  either via Cfg.WebSearch.Provider + the required credential, or via
  a known env-var API key alone (auto-detected). The web_search tool
  gates registration on this so the model doesn't see a tool that
  will silently come back empty when our zero-config fallback hits
  DDG's anomaly wall. }
function HasConfiguredWebSearchProvider(const Cfg: TConfig): Boolean;

{ Log a one-time-per-process explanation that web_search was skipped
  because no real provider is configured. Callers gating the tool's
  registration should invoke this in their `else` branch so the
  operator sees an actionable nudge in the boot log without us
  spamming on every multi-registry pass. }
procedure LogWebSearchSkipOnce;

implementation

uses
  PasClaw.Logger,
  PasClaw.Search.DuckDuckGo,
  PasClaw.Search.Brave,
  PasClaw.Search.Tavily,
  PasClaw.Search.SearXNG,
  PasClaw.Search.Perplexity,
  PasClaw.Search.Gemini;

function PickKey(const FromCfg, EnvName: string): string;
var
  Env: string;
begin
  Env := GetEnvironmentVariable(EnvName);
  if Env <> '' then Result := Env
  else              Result := FromCfg;
end;

function AutoDetectFromEnv: string;
{ When the user set an API key but never set web_search.provider in
  config.json, pick a sensible default. Priority is "key-only
  providers first" -- operators tend to set the Brave / Tavily /
  Perplexity / Gemini keys when they want web search, and it'd be a
  bad surprise to ignore that just because they didn't also touch
  the Provider field. SearXNG isn't auto-detected because its
  base_url is non-secret and lives in config.json proper. }
begin
  if GetEnvironmentVariable('PASCLAW_BRAVE_API_KEY')      <> '' then Exit('brave');
  if GetEnvironmentVariable('PASCLAW_TAVILY_API_KEY')     <> '' then Exit('tavily');
  if GetEnvironmentVariable('PASCLAW_PERPLEXITY_API_KEY') <> '' then Exit('perplexity');
  if GetEnvironmentVariable('PASCLAW_GEMINI_API_KEY')     <> '' then Exit('gemini');
  if GetEnvironmentVariable('PASCLAW_GOOGLE_API_KEY')     <> '' then Exit('gemini');
  Result := '';
end;

function NewSearchProvider(const Cfg: TConfig; out ErrMsg: string): ISearchProvider;
var
  Kind, Key: string;
begin
  ErrMsg := '';
  Kind := LowerCase(Trim(Cfg.WebSearch.Provider));

  if Kind = '' then
  begin
    { Auto-detect a real provider from env keys before falling all
      the way back to DDG. Only fires when the operator hasn't named
      a provider -- explicit "duckduckgo"/"ddg" below is respected
      verbatim so a paid env key (left over from another tool's
      config) can't silently hijack searches the operator meant to
      send to DDG. Codex P2 on PR #143. }
    Kind := AutoDetectFromEnv;
    if Kind = '' then
    begin
      Result := NewDuckDuckGoProvider;
      Exit;
    end;
  end
  else if (Kind = 'duckduckgo') or (Kind = 'ddg') then
  begin
    Result := NewDuckDuckGoProvider;
    Exit;
  end;

  if Kind = 'brave' then
  begin
    Key := PickKey(Cfg.WebSearch.APIKey, 'PASCLAW_BRAVE_API_KEY');
    if Key = '' then
    begin
      ErrMsg := 'brave: api key missing (set $PASCLAW_BRAVE_API_KEY)';
      Result := nil;
      Exit;
    end;
    Result := NewBraveProvider(Key);
    Exit;
  end;

  if Kind = 'tavily' then
  begin
    Key := PickKey(Cfg.WebSearch.APIKey, 'PASCLAW_TAVILY_API_KEY');
    if Key = '' then
    begin
      ErrMsg := 'tavily: api key missing (set $PASCLAW_TAVILY_API_KEY)';
      Result := nil;
      Exit;
    end;
    Result := NewTavilyProvider(Key);
    Exit;
  end;

  if Kind = 'searxng' then
  begin
    if Cfg.WebSearch.BaseURL = '' then
    begin
      ErrMsg := 'searxng: base_url missing (set web_search.base_url in config.json, ' +
                'e.g. https://searx.be)';
      Result := nil;
      Exit;
    end;
    { Optional API key -- most public instances don't need one. }
    Key := PickKey(Cfg.WebSearch.APIKey, 'PASCLAW_SEARXNG_API_KEY');
    Result := NewSearXNGProvider(Cfg.WebSearch.BaseURL, Key);
    Exit;
  end;

  if Kind = 'perplexity' then
  begin
    Key := PickKey(Cfg.WebSearch.APIKey, 'PASCLAW_PERPLEXITY_API_KEY');
    if Key = '' then
    begin
      ErrMsg := 'perplexity: api key missing (set $PASCLAW_PERPLEXITY_API_KEY)';
      Result := nil;
      Exit;
    end;
    Result := NewPerplexityProvider(Key);
    Exit;
  end;

  if (Kind = 'gemini') or (Kind = 'google_search') then
  begin
    Key := PickKey(Cfg.WebSearch.APIKey, 'PASCLAW_GEMINI_API_KEY');
    if Key = '' then
    begin
      ErrMsg := 'gemini: api key missing (set $PASCLAW_GEMINI_API_KEY ' +
                'or $PASCLAW_GOOGLE_API_KEY)';
      Result := nil;
      { Try the Google-branded env var too. Some users have it set
        from gcloud / aistudio defaults rather than the explicit
        Gemini key name. }
      Key := GetEnvironmentVariable('PASCLAW_GOOGLE_API_KEY');
      if Key = '' then Exit;
      ErrMsg := '';
    end;
    Result := NewGeminiProvider(Key);
    Exit;
  end;

  LogWarn('search.factory: unknown provider %s -- falling back to duckduckgo', [Kind]);
  Result := NewDuckDuckGoProvider;
end;

var
  GLogged: Boolean = False;

procedure LogSkipOnceImpl;
{ One-line info per process the first time web_search registration is
  skipped, so the operator understands why the model doesn't see the
  tool and how to flip it on. Subsequent skips during the same
  process are silenced -- multi-registry boots (cmd then component-
  embedded refresh, etc.) shouldn't spam. }
begin
  if GLogged then Exit;
  GLogged := True;
  { Headline states the fact; the remedy detail is one level down. The
    single-paragraph form ran to five lines of env-var names at startup,
    which buried every line around it. }
  LogInfo('web_search disabled: no provider configured ' +
          '(set a key, or web_search.provider in config.json)', []);
  LogDebug('web_search: accepted keys are $PASCLAW_BRAVE_API_KEY / ' +
           '$PASCLAW_TAVILY_API_KEY / $PASCLAW_PERPLEXITY_API_KEY / ' +
           '$PASCLAW_GEMINI_API_KEY; or set web_search.provider = "searxng" ' +
           'plus base_url. The DDG scrape fallback stays off -- its bot ' +
           'detection refuses non-browser requests at the TLS-fingerprint level.');
end;

function HasConfiguredWebSearchProvider(const Cfg: TConfig): Boolean;
var
  Kind: string;
begin
  Kind := LowerCase(Trim(Cfg.WebSearch.Provider));

  { Explicit non-DDG provider: counts as "configured" iff its required
    credential is reachable (env or cfg). The factory enforces the
    same rule at NewSearchProvider time; mirror it here so the gate
    decision lines up. }
  if Kind = 'brave' then
    Exit(PickKey(Cfg.WebSearch.APIKey, 'PASCLAW_BRAVE_API_KEY') <> '');
  if Kind = 'tavily' then
    Exit(PickKey(Cfg.WebSearch.APIKey, 'PASCLAW_TAVILY_API_KEY') <> '');
  if Kind = 'perplexity' then
    Exit(PickKey(Cfg.WebSearch.APIKey, 'PASCLAW_PERPLEXITY_API_KEY') <> '');
  if (Kind = 'gemini') or (Kind = 'google_search') then
    Exit((PickKey(Cfg.WebSearch.APIKey, 'PASCLAW_GEMINI_API_KEY') <> '') or
         (GetEnvironmentVariable('PASCLAW_GOOGLE_API_KEY') <> ''));
  if Kind = 'searxng' then
    Exit(Cfg.WebSearch.BaseURL <> '');

  { Empty provider: fall back to "does the operator have any
    auto-detectable env key set?". Without that, the only real
    option is the DDG scrape, which we've decided not to expose. }
  if Kind = '' then
    Exit(AutoDetectFromEnv <> '');

  { Explicit 'duckduckgo'/'ddg': the operator chose the broken-
    by-bot-wall scrape backend deliberately. Don't second-guess
    them by sending requests to whatever paid key happens to be in
    the env -- and don't register the tool either, since DDG won't
    deliver results. Codex P2 on PR #143. }
  if (Kind = 'duckduckgo') or (Kind = 'ddg') then
    Exit(False);

  { Unknown Kind -- the factory logs a warning and falls back to DDG,
    so for the gate decision treat it as "not configured". }
  Result := False;
end;

procedure LogWebSearchSkipOnce;
begin
  LogSkipOnceImpl;
end;

end.
