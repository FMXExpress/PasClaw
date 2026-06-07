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

function PickModelInteractive(const Spec: TProviderSpec;
                              const APIKey: string): string;
{ Strategy:
    1. Try a live fetch against /v1/models (or /v1beta/models for
       Gemini). Bounded at 8s — onboarding is interactive and a
       provider with a slow status page shouldn't make the user
       wait 30s before they can pick a model.
    2. If discovery succeeds with >0 models, save the cache + show
       a numbered picker over the top N. Default selection keeps the
       catalog's static DefaultModel.
    3. If discovery fails (no key, network down, provider 5xx) or
       the list is empty, fall through to the pre-PR-#171 text input
       so onboarding never gets stuck behind a broken /models
       endpoint.
  Returns the model id the user picked, or the catalog default when
  the user just hit Enter. }
const
  TIMEOUT_SEC    = 8;
  VISIBLE_TOP_N  = 12;     { mirror what ChatGPT / Claude do on their
                             pickers — long enough to cover the
                             useful tier, short enough to fit on a
                             single screen }
var
  R: TModelDiscoveryResult;
  i, N, Pick: Integer;
  Label_, Input, Default: string;
begin
  Default := Spec.DefaultModel;

  { Caller may pass Key='' for asNone providers. Those still have
    /v1/models endpoints (Ollama serves it without auth) so we try
    anyway; DiscoverModels short-circuits Key-required providers and
    we'll fall through to the text input. }
  if (Spec.Family = pfPlaceholder) or
     ((Spec.Auth.Kind <> asNone) and (Trim(APIKey) = '')) then
  begin
    if Default <> '' then
      Result := ReadLineEcho(Format('Default model [%s]: ', [Default]))
    else
      repeat
        Result := ReadLineEcho('Default model (provider does not advertise one — required): ');
      until Trim(Result) <> '';
    if Trim(Result) = '' then Result := Default;
    Exit;
  end;

  PrintLn(Ansi.Dim + 'Fetching available models from ' + Spec.DisplayName +
          ' ...' + Ansi.Reset);
  R := DiscoverModels(Spec, Spec.DefaultBase, APIKey, TIMEOUT_SEC);

  if (not R.Ok) or (Length(R.Models) = 0) then
  begin
    if R.ErrMsg <> '' then
      PrintLn(Ansi.Dim + '  (live fetch failed: ' + R.ErrMsg +
              ' — falling back to text input)' + Ansi.Reset);
    if Default <> '' then
      Result := ReadLineEcho(Format('Default model [%s]: ', [Default]))
    else
      repeat
        Result := ReadLineEcho('Default model (provider does not advertise one — required): ');
      until Trim(Result) <> '';
    if Trim(Result) = '' then Result := Default;
    Exit;
  end;

  { Cache the full result, keyed on Spec.Kind because that's the
    Provider Name UpsertProvider is about to set on the new config
    entry (Name := Spec.Kind for both the upsert and insert paths
    in this file). Same key future `pasclaw model refresh` and
    `model list` invocations against this provider will use,
    keeping the cache addressable from any of those sites. Codex
    P2 on PR #171 — see PasClaw.Cmd.Model for the corresponding
    cache-key shift on the refresh side. }
  SaveCachedModels(Spec.Kind, R);
  SortModelsByDate(R.Models);

  N := Length(R.Models);
  if N > VISIBLE_TOP_N then N := VISIBLE_TOP_N;

  PrintLn(Format('Available models (showing %d of %d, newest first):',
                 [N, Length(R.Models)]));
  for i := 0 to N - 1 do
  begin
    Label_ := R.Models[i].Id;
    if (R.Models[i].Display <> '') and (R.Models[i].Display <> R.Models[i].Id) then
      Label_ := Label_ + Ansi.Dim + '  (' + R.Models[i].Display + ')' + Ansi.Reset;
    PrintLn(Format('  %d) %s', [i + 1, Label_]));
  end;
  if Length(R.Models) > N then
    PrintLn(Ansi.Dim +
            Format('  (+ %d more — see `pasclaw model list %s`)',
                   [Length(R.Models) - N, Spec.Kind]) +
            Ansi.Reset);

  if Default <> '' then
    Input := ReadLineEcho(Format(
      'Pick a number, type a name, or Enter for default [%s]: ', [Default]))
  else
    Input := ReadLineEcho('Pick a number or type a name: ');

  Input := Trim(Input);
  if (Input = '') and (Default <> '') then
    Exit(Default);

  Pick := StrToIntDef(Input, 0);
  if (Pick >= 1) and (Pick <= N) then
    Exit(R.Models[Pick - 1].Id);

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
  Key, Model: string;
  Catalog: TProviderSpecArray;
  Spec: TProviderSpec;
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
      Key := ReadSecretLine(Spec.DisplayName + ' API key (leave blank to skip): ');
    end;

    Model := PickModelInteractive(Spec, Key);

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
