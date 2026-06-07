(*
  Onboard — initialise config and workspace. Creates ~/.pasclaw, a
  starter config.json, and walks the user through picking a provider
  from the catalog (PasClaw.Providers.Catalog). Selection by number
  populates the saved TProviderConfig with the catalog's default base
  URL and default model; the user is prompted for the API key only when
  the provider's auth scheme requires one (skipped for local providers
  like Ollama and vLLM).
*)
unit PasClaw.Cmd.Onboard;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Onboard_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Providers.Catalog,
  PasClaw.Providers.Models,
  PasClaw.MCP.Catalog,
  PasClaw.Cmd.Memory;

function ReadLineEcho(const Prompt: string): string;
begin
  Print(Prompt);
  ReadLn(Result);
end;

procedure PrintCatalog(const Catalog: TProviderSpecArray);
var
  i: Integer;
begin
  PrintLn(Ansi.Bold + 'Choose a provider:' + Ansi.Reset);
  for i := 0 to High(Catalog) do
    PrintLn(Format(' %2d. %-22s %s', [i + 1, Catalog[i].DisplayName, Catalog[i].Notes]));
end;

function PickFromCatalog(const Catalog: TProviderSpecArray;
                         const DefaultKind: string;
                         out Spec: TProviderSpec): Boolean;
var
  Input: string;
  Idx, DefaultIdx, i: Integer;
begin
  Result := False;
  DefaultIdx := -1;
  for i := 0 to High(Catalog) do
    if SameText(Catalog[i].Kind, DefaultKind) then
    begin
      DefaultIdx := i;
      Break;
    end;
  PrintCatalog(Catalog);
  if DefaultIdx >= 0 then
    Input := ReadLineEcho(Format('Pick [1-%d] (default %d=%s): ',
              [Length(Catalog), DefaultIdx + 1, Catalog[DefaultIdx].DisplayName]))
  else
    Input := ReadLineEcho(Format('Pick [1-%d]: ', [Length(Catalog)]));
  Input := Trim(Input);
  if (Input = '') and (DefaultIdx >= 0) then
  begin
    Spec := Catalog[DefaultIdx];
    Exit(True);
  end;
  if not TryStrToInt(Input, Idx) then Exit;
  if (Idx < 1) or (Idx > Length(Catalog)) then Exit;
  Spec := Catalog[Idx - 1];
  Result := True;
end;

function CompareModelsByDate(const A, B: TModelInfo): Integer;
{ Sort newest first (CreatedAt desc). When neither model exposes a
  creation time the sort collapses to no-op which preserves the
  /models response order — that's what the provider considered
  "natural" so it's a fine fallback. }
begin
  if A.CreatedAt = B.CreatedAt then Exit(0);
  if A.CreatedAt < B.CreatedAt then Exit(1);
  Result := -1;
end;

procedure SortModelsByDate(var M: TModelInfoArray);
{ Insertion sort — N is small (typically <50), avoids dragging in
  Generics.Defaults just to compare two Int64s. }
var
  i, j: Integer;
  Tmp: TModelInfo;
begin
  for i := 1 to High(M) do
  begin
    Tmp := M[i];
    j := i - 1;
    while (j >= 0) and (CompareModelsByDate(Tmp, M[j]) < 0) do
    begin
      M[j + 1] := M[j];
      Dec(j);
    end;
    M[j + 1] := Tmp;
  end;
end;

function ShowPicker(const Models: TModelInfoArray;
                    const ProviderName: string;
                    SourceLabel: string;
                    FetchedAt: Int64): Integer;
{ Prints the numbered picker over the top N models. SourceLabel is the
  one-liner above the list ('Fetched live from ...', 'From cache
  (refreshed 3 days ago)', etc.) so the user knows where the list came
  from and whether it might be stale.

  Returns the number of rows actually printed (the visible count, N).
  Caller MUST validate any typed numeric pick against this returned
  value, NOT Length(Models) — typing 47 against a 12-row visible list
  would otherwise silently pick a model the user can't see. Codex P2
  on PR #172. }
const
  VISIBLE_TOP_N = 12;     { mirror what ChatGPT / Claude do on their
                            pickers — long enough to cover the
                            useful tier, short enough to fit on a
                            single screen }
var
  i: Integer;
  Label_: string;
begin
  Result := Length(Models);
  if Result > VISIBLE_TOP_N then Result := VISIBLE_TOP_N;

  if SourceLabel <> '' then
    PrintLn(Ansi.Dim + SourceLabel + Ansi.Reset);
  PrintLn(Format('Available models (showing %d of %d, newest first):',
                 [Result, Length(Models)]));
  for i := 0 to Result - 1 do
  begin
    Label_ := Models[i].Id;
    if (Models[i].Display <> '') and (Models[i].Display <> Models[i].Id) then
      Label_ := Label_ + Ansi.Dim + '  (' + Models[i].Display + ')' + Ansi.Reset;
    PrintLn(Format('  %d) %s', [i + 1, Label_]));
  end;
  if Length(Models) > Result then
    PrintLn(Ansi.Dim +
            Format('  (+ %d more — see `pasclaw model list %s`)',
                   [Length(Models) - Result, ProviderName]) +
            Ansi.Reset);
end;

function PickModelInteractive(const Spec: TProviderSpec;
                              const APIKey: string): string;
{ Strategy (revised after first-user feedback that the picker silently
  disappeared when the API key prompt was skipped):

    1. Load the cached model roster up-front. If a previous onboard /
       `pasclaw model refresh` populated one, we have a list whether
       or not the operator just entered a fresh key.

    2. When the operator entered an API key, attempt the live fetch
       too. Success → save cache + present picker over the LIVE
       list. Failure → fall back to the cache (if any) with a clear
       "live fetch failed, showing cache from N days ago" note. The
       cache file is never overwritten by a failed live fetch.

    3. When the operator left the key blank AND a cache exists, show
       the cached list with a one-liner explaining why we didn't
       refresh ("API key not entered — showing the cached roster.
       Re-run with a key to refresh"). Better than silently dropping
       to the text-input prompt which is what tripped up the first
       user.

    4. Only when there's no key AND no cache do we fall through to
       the original text-input prompt, with an explicit note that
       no list is available so the operator knows what's happening
       rather than wondering why the picker they expected isn't
       there.

  Returns the model id the operator picked, or the catalog default
  when they just hit Enter. }
const
  TIMEOUT_SEC = 8;
var
  Live, Cached: TModelDiscoveryResult;
  HaveCache, HaveLive, HaveKey: Boolean;
  Models: TModelInfoArray;
  ProviderName, SourceLabel, Input, Default: string;
  Pick, VisibleN: Integer;
begin
  Default      := Spec.DefaultModel;
  ProviderName := Spec.Kind;     { same Name UpsertProvider will set;
                                   see comment further down for the
                                   PR #171 cache-key invariant }
  HaveKey      := (Spec.Auth.Kind = asNone) or (Trim(APIKey) <> '');

  { Step 1: see if a cached roster exists. Keyed on Spec.Kind for the
    same reason as below — onboarding's Name == Spec.Kind invariant. }
  HaveCache := LoadCachedModels(Spec.Kind, Cached) and (Length(Cached.Models) > 0);

  { Step 2: live fetch when a key is available. Placeholder kinds and
    keyless providers without a /models endpoint silently skip live
    discovery; the cache is still our fallback. }
  HaveLive := False;
  if HaveKey and (Spec.Family <> pfPlaceholder) then
  begin
    PrintLn(Ansi.Dim + 'Fetching available models from ' + Spec.DisplayName +
            ' ...' + Ansi.Reset);
    Live := DiscoverModels(Spec, Spec.DefaultBase, APIKey, TIMEOUT_SEC);
    if Live.Ok and (Length(Live.Models) > 0) then
    begin
      SaveCachedModels(Spec.Kind, Live);
      HaveLive := True;
    end
    else if Live.ErrMsg <> '' then
      PrintLn(Ansi.Dim + '  (live fetch failed: ' + Live.ErrMsg + ')' +
              Ansi.Reset);
  end;

  { Step 3 / 4: pick the data source for the picker. Live wins over
    cache; cache wins over no-data. }
  if HaveLive then
  begin
    Models      := Live.Models;
    SourceLabel := 'Fetched live from ' + Spec.DisplayName + '.';
  end
  else if HaveCache then
  begin
    Models := Cached.Models;
    if HaveKey then
      SourceLabel := 'Showing the cached roster (refreshed ' +
                     HumanAge(Cached.FetchedAt) + ').'
    else
      SourceLabel := 'API key not entered — showing the cached roster (refreshed ' +
                     HumanAge(Cached.FetchedAt) + '). Re-run with a key to refresh.';
  end
  else
  begin
    { No live, no cache → original text-input prompt. Make the lack
      of picker explicit so the operator isn't left wondering. }
    if not HaveKey then
      PrintLn(Ansi.Dim +
              'API key not entered — using the catalog default. ' +
              'Run `pasclaw model refresh ' + ProviderName +
              '` later to populate the picker for next time.' + Ansi.Reset);
    if Default <> '' then
      Result := ReadLineEcho(Format('Default model [%s]: ', [Default]))
    else
      repeat
        Result := ReadLineEcho('Default model (provider does not advertise one — required): ');
      until Trim(Result) <> '';
    if Trim(Result) = '' then Result := Default;
    Exit;
  end;

  SortModelsByDate(Models);
  VisibleN := ShowPicker(Models, ProviderName, SourceLabel,
                         { FetchedAt unused by ShowPicker — kept on the
                           signature for future "stale by N days,
                           refresh?" prompts } 0);

  if Default <> '' then
    Input := ReadLineEcho(Format(
      'Pick a number, type a name, or Enter for default [%s]: ', [Default]))
  else
    Input := ReadLineEcho('Pick a number or type a name: ');

  Input := Trim(Input);
  if (Input = '') and (Default <> '') then
    Exit(Default);

  { Validate against VisibleN (the count ShowPicker actually printed),
    NOT Length(Models). Typing 47 against a 12-row visible list used
    to silently pick an off-screen model — Codex P2 on PR #172. Numbers
    outside the visible range fall through to the free-form-id branch
    below, same as any non-numeric input. }
  Pick := StrToIntDef(Input, 0);
  if (Pick >= 1) and (Pick <= VisibleN) then
    Exit(Models[Pick - 1].Id);

  { Anything else gets taken as a free-form model id — operator may
    know about a model the cache doesn't list yet. }
  Result := Input;
end;

procedure UpsertProvider(Cfg: TConfig; const Spec: TProviderSpec;
                         const Model, Key: string);
var
  i: Integer;
  Found: Boolean;
begin
  Found := False;
  for i := 0 to High(Cfg.Providers) do
    if SameText(Cfg.Providers[i].Name, Spec.Kind) then
    begin
      if Key <> '' then Cfg.Providers[i].APIKey := Key;
      if Model <> '' then Cfg.Providers[i].Model := Model;
      Cfg.Providers[i].Kind := Spec.Kind;
      if Cfg.Providers[i].APIBase = '' then
        Cfg.Providers[i].APIBase := Spec.DefaultBase;
      Found := True;
      Break;
    end;
  if Found then Exit;

  SetLength(Cfg.Providers, Length(Cfg.Providers) + 1);
  with Cfg.Providers[High(Cfg.Providers)] do
  begin
    Name    := Spec.Kind;
    Kind    := Spec.Kind;
    APIBase := Spec.DefaultBase;
    APIKey  := Key;
    if Model <> '' then
      Cfg.Providers[High(Cfg.Providers)].Model := Model
    else
      Cfg.Providers[High(Cfg.Providers)].Model := Spec.DefaultModel;
  end;
end;

function IsMCPInstalled(Cfg: TConfig; const Name: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Cfg.MCPServers) do
    if SameText(Cfg.MCPServers[i].Name, Name) then Exit(True);
end;

procedure UpsertCatalogMCP(Cfg: TConfig; const Entry: TMCPCatalogEntry;
                           const HeaderVal: string);
var
  i: Integer;
begin
  { Mirrors Cmd.MCP.DoInstall's upsert — if an entry for this catalog
    name already exists, refresh URL/auth/enabled in place rather than
    duplicating. The MCP Cmd field stores the URL (HTTP MCP transport
    uses it directly); Args stores the literal Authorization header
    value the client puts on every request. }
  for i := 0 to High(Cfg.MCPServers) do
    if SameText(Cfg.MCPServers[i].Name, Entry.Name) then
    begin
      Cfg.MCPServers[i].Cmd     := Entry.URL;
      Cfg.MCPServers[i].Args    := HeaderVal;
      Cfg.MCPServers[i].Enabled := True;
      Exit;
    end;
  SetLength(Cfg.MCPServers, Length(Cfg.MCPServers) + 1);
  with Cfg.MCPServers[High(Cfg.MCPServers)] do
  begin
    Name    := Entry.Name;
    Cmd     := Entry.URL;
    Args    := HeaderVal;
    Env     := '';
    Enabled := True;
  end;
end;

procedure PromptVaultTools(Cfg: TConfig);
{ Opt-in toggle for the agent-callable vault_search / vault_get
  tools. Default YES because pressing Enter through onboarding
  should land a useful agent, and the vault tools are read-only
  HTTP GETs against a curated registry — no execution path. User
  can flip back later by editing config.json or re-running
  onboard. }
var
  Choice: string;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Code Vault tools' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'vault_search / vault_get let the agent discover Object Pascal source code' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    '(samples, components, libraries) on pasclaw.dev — read-only HTTP GETs.' +
    Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable vault tools for the agent [Y/n]: ')));
  if (Choice = '') or (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.VaultToolsEnabled := True;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + ' vault_search / vault_get enabled');
  end
  else
  begin
    Cfg.VaultToolsEnabled := False;
    PrintLn('  ' + Ansi.Dim + '(skipped — flip vault_tools_enabled in config.json to enable later)' + Ansi.Reset);
  end;
end;

procedure PromptVectorSearch(Cfg: TConfig);
{ Opt-in toggle for hybrid FTS+vector memory_search. Default YES
  because the hybrid index is what picoclaw / nanobot ship and it's
  what memory_search "should" feel like. The vector half adds local
  ANN search via sqlite-vec + an ONNX-runtime'd BERT embedder
  (MiniLM by default), fused with FTS5 BM25 through Reciprocal Rank
  Fusion — same shape as picoclaw.

  After the user opts in we offer to provision the runtime artifacts
  (sqlite-vec extension, ONNX Runtime, MiniLM weights ~91 MB) right
  now via `pasclaw memory provision`. Default NO on that follow-up
  question because (a) the download is fat enough to deserve an
  explicit "yes" and (b) a user with no internet at onboard time can
  defer it. When they decline, memory_search still works — it falls
  back to the FTS-only path until the artifacts arrive. }
var
  Choice: string;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Memory: hybrid FTS + vector search' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Hybrid keyword (FTS5 BM25) + semantic (local embeddings, no API calls)' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    'fused via Reciprocal Rank Fusion — matches picoclaw / nanobot memory_search.' +
    Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable vector search for memory_search [Y/n]: ')));
  if not ((Choice = '') or (Choice = 'y') or (Choice = 'yes')) then
  begin
    Cfg.VectorSearchEnabled := False;
    PrintLn('  ' + Ansi.Dim +
      '(skipped — memory_search will use FTS5 keyword search only)' + Ansi.Reset);
    Exit;
  end;

  Cfg.VectorSearchEnabled := True;
  PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + ' vector search enabled');

  { Offer to fetch the runtime artifacts immediately. Default NO so a
    user hitting Enter through the onboard doesn't get hit by a
    91 MB download they didn't expect. If they decline, the same
    download fires lazily on the first memory_search after they run
    `pasclaw memory provision` themselves. }
  PrintLn;
  PrintLn(Ansi.Dim +
    '  The hybrid backend needs three artifacts (~91 MB total):' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    '    sqlite-vec extension     (asg017/sqlite-vec, ~150 KB)' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    '    MiniLM model + vocab     (HuggingFace, ~90 MB)' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    '    ONNX Runtime             (auto-download win-x64 only;' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    '                              elsewhere install via system pkg mgr)' +
    Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Download now? [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    PrintLn;
    Cmd_Memory_Run(['provision']);
  end
  else
    PrintLn('  ' + Ansi.Dim +
      '(deferred — run `pasclaw memory provision` when ready)' + Ansi.Reset);
end;

procedure PromptMCPInstalls(Cfg: TConfig);
var
  Entries: TMCPCatalogEntryArray;
  Entry: TMCPCatalogEntry;
  i: Integer;
  Choice, Token, HeaderVal, EnvTok: string;
  AlreadyInstalled: Boolean;
begin
  Entries := KnownMCPServers;
  if Length(Entries) = 0 then Exit;

  PrintLn;
  PrintLn(Ansi.Bold + 'Optional: enable built-in MCP servers' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'These give the agent extra capabilities via the MCP protocol.' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Skip what you don''t want — you can install later with ' +
    Ansi.Reset + '`pasclaw mcp install <name>`' + Ansi.Dim + '.' + Ansi.Reset);
  PrintLn;

  for i := 0 to High(Entries) do
  begin
    Entry := Entries[i];
    AlreadyInstalled := IsMCPInstalled(Cfg, Entry.Name);

    PrintLn(Ansi.Bold + '  ' + Entry.Name + Ansi.Reset);
    PrintLn('  ' + Ansi.Dim + Entry.Desc + Ansi.Reset);
    if Entry.Docs <> '' then
      PrintLn('  ' + Ansi.Dim + Entry.Docs + Ansi.Reset);
    if AlreadyInstalled then
    begin
      PrintLn('  ' + Ansi.Green + '(already installed — skipping)' + Ansi.Reset);
      PrintLn;
      Continue;
    end;

    Choice := Trim(LowerCase(ReadLineEcho('  Enable [y/N]: ')));
    if (Choice <> 'y') and (Choice <> 'yes') then
    begin
      PrintLn;
      Continue;
    end;

    { Auth-less entries (runpod-docs today) install with no token. }
    if Entry.EnvVar = '' then
    begin
      UpsertCatalogMCP(Cfg, Entry, '');
      PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + ' installed ' +
              Entry.Name + ' ' + Ansi.Dim + '(no auth)' + Ansi.Reset);
      PrintLn;
      Continue;
    end;

    { Prefer the env var when it's already set — same path
      pasclaw mcp install takes today. }
    EnvTok := GetEnvironmentVariable(Entry.EnvVar);
    if EnvTok <> '' then
    begin
      PrintLn('  ' + Ansi.Dim + 'using ' + Entry.EnvVar +
              ' from environment' + Ansi.Reset);
      HeaderVal := FormatAuthHeaderFromToken(Entry, EnvTok);
    end
    else
    begin
      { No-echo input — pasted tokens stay out of terminal scrollback
        and any screen recordings / shared sessions. Codex P2 on
        PR #126. }
      Token := Trim(ReadSecretLine('  ' + Entry.EnvVar + ' (paste, or blank to skip auth): '));
      HeaderVal := FormatAuthHeaderFromToken(Entry, Token);
      if HeaderVal = '' then
        PrintLn('  ' + Ansi.Yellow + '!' + Ansi.Reset +
                ' installing with no auth header — set ' + Entry.EnvVar +
                ' and re-run `pasclaw mcp install ' + Entry.Name +
                '` later to refresh.');
    end;

    UpsertCatalogMCP(Cfg, Entry, HeaderVal);
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + ' installed ' + Entry.Name);
    PrintLn;
  end;
end;

function Cmd_Onboard_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Home, CfgPath: string;
  Key, EffectiveKey, Model: string;
  Catalog: TProviderSpecArray;
  Spec: TProviderSpec;
  ExistingIdx, i: Integer;
begin
  Home    := GetHome;
  CfgPath := GetConfigPath;

  PrintLn(Ansi.Bold + 'Onboarding PasClaw' + Ansi.Reset);
  PrintLn('  home:   ' + Home);
  PrintLn('  config: ' + CfgPath);
  PrintLn;

  if not EnsureDir(Home) then
  begin
    LogError('failed to create home dir: %s', [Home]);
    Exit(1);
  end;
  EnsureDir(JoinPath(Home, 'workspace'));
  EnsureDir(JoinPath(Home, 'workspace/memory'));
  EnsureDir(JoinPath(Home, 'workspace/skills'));
  EnsureDir(JoinPath(Home, 'logs'));

  if FileExists(CfgPath) then
  begin
    Cfg := LoadConfig;
    PrintLn('Existing config detected; updating in place.');
  end
  else
    Cfg := TConfig.Create;

  try
    Catalog := AllProviderSpecs;
    if not PickFromCatalog(Catalog, 'anthropic', Spec) then
    begin
      PrintLn(Ansi.Yellow + 'no valid selection — config not changed' + Ansi.Reset);
      Exit(1);
    end;

    { Auth FIRST so we can use the key to fetch the live model list.
      Pre-PR-#171 the order was model → key, which made `/v1/models`
      discovery impossible without a second prompt loop. The key is
      still required only when the catalog spec says so (Ollama /
      vLLM / LM Studio sit at asNone and skip this step). }
    case Spec.Auth.Kind of
      asNone:
        Key := '';
    else
      { No-echo for the same reason as the MCP token path below —
        Codex P2 on PR #126 was scoped to MCP but the provider-key
        prompt has the identical exposure (pasted credential lands
        in terminal scrollback / screen recordings). }
      Key := ReadSecretLine(Spec.DisplayName +
        ' API key (leave blank to keep existing): ');
    end;

    { Re-onboard case: when the operator leaves the prompt blank they
      almost always mean "keep my existing key" — they're re-running
      onboard to tweak something else, not to wipe their auth. Pull
      the existing key out of Cfg.Providers so PickModelInteractive
      can still do a live /v1/models fetch with it. UpsertProvider
      already treats Key='' as "preserve existing" further down, so
      we don't need to copy this back into the saved Key variable —
      just feed the picker the effective key. }
    EffectiveKey := Key;
    if (EffectiveKey = '') and (Spec.Auth.Kind <> asNone) then
    begin
      ExistingIdx := -1;
      for i := 0 to High(Cfg.Providers) do
        if SameText(Cfg.Providers[i].Name, Spec.Kind) then
        begin
          ExistingIdx := i;
          Break;
        end;
      if (ExistingIdx >= 0) and (Cfg.Providers[ExistingIdx].APIKey <> '') then
        EffectiveKey := Cfg.Providers[ExistingIdx].APIKey;
    end;

    Model := PickModelInteractive(Spec, EffectiveKey);

    Cfg.DefaultProvider := Spec.Kind;
    if Model <> '' then Cfg.DefaultModel := Model;

    UpsertProvider(Cfg, Spec, Model, Key);

    { Built-in MCP catalog — opt-in per entry. Picoclaw's rule is
      "never preloaded"; we keep the same default-off prompt so a
      user pressing Enter through onboarding doesn't install
      anything they didn't explicitly say yes to. Auth tokens
      captured here land in config.json as a literal Authorization
      header value (same shape pasclaw mcp install writes when an
      env var is set). }
    PromptMCPInstalls(Cfg);
    PromptVaultTools(Cfg);
    PromptVectorSearch(Cfg);

    SaveConfig(Cfg);
    PrintLn;
    PrintLn(Ansi.Green + '✓' + Ansi.Reset + ' wrote ' + CfgPath);
    PrintLn('Next: ' + Ansi.Bold + 'pasclaw agent "hello"' + Ansi.Reset);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
