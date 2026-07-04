(*
  Onboard -- initialise config and workspace. Creates ~/.pasclaw, a
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
  PasClaw.Config.Profile,    { ResolveProfileBodies for PromptStarterProfile -- PR #291 }
  PasClaw.Utils,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Providers.Catalog,
  PasClaw.Providers.Models,
  PasClaw.MCP.Catalog,
  PasClaw.KB.Index,
  PasClaw.Shell.Backend,  { TShellBackendKind for the PromptShellBackend
                            assignment to Cfg.ShellBackend }
  PasClaw.Cmd.Memory;

function ReadLineEcho(const Prompt: string): string;
begin
  Print(Prompt);
  ReadLn(Result);
end;

function IsCloudflareKind(const Kind: string): Boolean;
{ Any of the three Cloudflare AI Gateway catalog specs -- the OpenAI-compat
  'cloudflare' plus the '-anthropic' / '-gemini' passthroughs. The picker
  collapses all three into ONE row and asks which upstream in a follow-up.
  The catalog itself is untouched (config / tests resolve all three by kind). }
begin
  Result := SameText(Kind, 'cloudflare') or
            SameText(Kind, 'cloudflare-anthropic') or
            SameText(Kind, 'cloudflare-gemini');
end;

function CatalogHasKind(const Catalog: TProviderSpecArray;
                        const Kind: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Catalog) do
    if SameText(Catalog[i].Kind, Kind) then Exit(True);
end;

function BuildDisplayCatalog(const Full: TProviderSpecArray): TProviderSpecArray;
{ Collapse every Cloudflare AI Gateway variant present into a SINGLE
  "Cloudflare AI Gateway" anchor row (the first one encountered), so the
  family shows up whenever any variant is in Full -- even when the catalog
  has been filtered (e.g. the fallback picker drops the primary provider,
  which could itself be a Cloudflare variant). The follow-up
  PickCloudflareVariant then offers only the variants Full actually holds. }
var
  i, n: Integer;
  SeenCf: Boolean;
begin
  SetLength(Result, Length(Full));
  n := 0;
  SeenCf := False;
  for i := 0 to High(Full) do
  begin
    if IsCloudflareKind(Full[i].Kind) then
    begin
      if SeenCf then Continue;          { already emitted the collapsed row }
      SeenCf := True;
      Result[n] := Full[i];
      Result[n].DisplayName := 'Cloudflare AI Gateway';   { generic family label }
      Inc(n);
      Continue;
    end;
    Result[n] := Full[i];
    Inc(n);
  end;
  SetLength(Result, n);
end;

function PickCloudflareVariant(const Catalog: TProviderSpecArray;
                               out Spec: TProviderSpec): Boolean;
{ Second step after the operator picks "Cloudflare AI Gateway": choose the
  upstream the gateway proxies. Offers ONLY the variants present in Catalog,
  so a filtered catalog (e.g. the fallback picker, which excludes the
  primary provider) can't let the user re-select the excluded primary and
  defeat the point of a fallback. Auto-selects when only one variant is
  available. }
const
  Kinds:  array[0..2] of string = (
    'cloudflare', 'cloudflare-anthropic', 'cloudflare-gemini');
  Labels: array[0..2] of string = (
    'OpenAI-compatible  (compat endpoint -- OpenAI, Workers AI, most models)',
    'Anthropic passthrough  (Claude via /anthropic)',
    'Gemini passthrough  (Google AI Studio via /google-ai-studio)');
var
  Avail: array of Integer;   { indices into Kinds/Labels present in Catalog }
  i, Idx: Integer;
  Input: string;
begin
  Result := False;
  SetLength(Avail, 0);
  for i := 0 to High(Kinds) do
    if CatalogHasKind(Catalog, Kinds[i]) then
    begin
      SetLength(Avail, Length(Avail) + 1);
      Avail[High(Avail)] := i;
    end;
  if Length(Avail) = 0 then Exit;                  { nothing to offer }
  if Length(Avail) = 1 then                        { only one -- don't ask }
    Exit(LookupProvider(Kinds[Avail[0]], Spec));

  PrintLn;
  PrintLn(Ansi.Bold + 'Cloudflare AI Gateway -- which upstream?' + Ansi.Reset);
  for i := 0 to High(Avail) do
    PrintLn(Format('  %d. %s', [i + 1, Labels[Avail[i]]]));
  Input := Trim(ReadLineEcho(Format('Pick [1-%d] (default 1): ', [Length(Avail)])));
  if Input = '' then Input := '1';
  if not TryStrToInt(Input, Idx) then Exit;
  if (Idx < 1) or (Idx > Length(Avail)) then Exit;
  Result := LookupProvider(Kinds[Avail[Idx - 1]], Spec);
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
  Display: TProviderSpecArray;
  Input: string;
  Idx, DefaultIdx, i: Integer;
begin
  Result := False;
  { Collapse the Cloudflare AI Gateway siblings into one picker row. }
  Display := BuildDisplayCatalog(Catalog);
  DefaultIdx := -1;
  for i := 0 to High(Display) do
    if SameText(Display[i].Kind, DefaultKind) then
    begin
      DefaultIdx := i;
      Break;
    end;
  PrintCatalog(Display);
  if DefaultIdx >= 0 then
    Input := ReadLineEcho(Format('Pick [1-%d] (default %d=%s): ',
              [Length(Display), DefaultIdx + 1, Display[DefaultIdx].DisplayName]))
  else
    Input := ReadLineEcho(Format('Pick [1-%d]: ', [Length(Display)]));
  Input := Trim(Input);
  if (Input = '') and (DefaultIdx >= 0) then
    Spec := Display[DefaultIdx]
  else
  begin
    if not TryStrToInt(Input, Idx) then Exit;
    if (Idx < 1) or (Idx > Length(Display)) then Exit;
    Spec := Display[Idx - 1];
  end;
  { Drill into the upstream choice once the collapsed gateway row is picked.
    Match the whole family (the anchor row's Kind is whichever variant came
    first in Catalog), and pass Catalog so the sub-pick stays within it. }
  if IsCloudflareKind(Spec.Kind) then
    Result := PickCloudflareVariant(Catalog, Spec)
  else
    Result := True;
end;

function CompareModelsByDate(const A, B: TModelInfo): Integer;
{ Sort newest first (CreatedAt desc). When neither model exposes a
  creation time the sort collapses to no-op which preserves the
  /models response order -- that's what the provider considered
  "natural" so it's a fine fallback. }
begin
  if A.CreatedAt = B.CreatedAt then Exit(0);
  if A.CreatedAt < B.CreatedAt then Exit(1);
  Result := -1;
end;

procedure SortModelsByDate(var M: TModelInfoArray);
{ Insertion sort -- N is small (typically <50), avoids dragging in
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
  value, NOT Length(Models) -- typing 47 against a 12-row visible list
  would otherwise silently pick a model the user can't see. Codex P2
  on PR #172. }
const
  VISIBLE_TOP_N = 12;     { mirror what ChatGPT / Claude do on their
                            pickers -- long enough to cover the
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
            Format('  (+ %d more -- see `pasclaw model list %s`)',
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
       refresh ("API key not entered -- showing the cached roster.
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
    same reason as below -- onboarding's Name == Spec.Kind invariant. }
  HaveCache := LoadCachedModels(Spec.Kind, Cached) and (Length(Cached.Models) > 0);

  { Step 2: live fetch when a key is available. Placeholder kinds and
    keyless providers without a /models endpoint silently skip live
    discovery; the cache is still our fallback. The relay family is
    intentionally excluded too -- its "API" is an in-process queue
    that no external worker has joined yet at onboarding time, so
    there is nothing to discover. The catalog DefaultModel is empty
    on purpose for relay -- means "accept any model the connected
    worker advertises" -- and the prompt below honours that. }
  HaveLive := False;
  if HaveKey and (Spec.Family <> pfPlaceholder) and (Spec.Family <> pfRelay) then
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
      SourceLabel := 'API key not entered -- showing the cached roster (refreshed ' +
                     HumanAge(Cached.FetchedAt) + '). Re-run with a key to refresh.';
  end
  else
  begin
    { No live, no cache → original text-input prompt. Make the lack
      of picker explicit so the operator isn't left wondering. }
    if not HaveKey then
      PrintLn(Ansi.Dim +
              'API key not entered -- using the catalog default. ' +
              'Run `pasclaw model refresh ' + ProviderName +
              '` later to populate the picker for next time.' + Ansi.Reset);
    if Default <> '' then
      Result := ReadLineEcho(Format('Default model [%s]: ', [Default]))
    else if Spec.Family = pfRelay then
    begin
      { Relay wildcard: empty model means "whatever the connected
        worker advertises." The earlier hard loop until non-empty
        was wrong for this family -- no worker is connected during
        onboarding, the operator has no model name to type, and the
        catalog DefaultModel is empty on purpose. Accept Enter as
        the documented wildcard and tell the operator what they
        just picked so it isn't a silent surprise later. }
      PrintLn(Ansi.Dim +
              'Relay providers accept any model the connected worker advertises. ' +
              'Press Enter to leave empty (wildcard), or pin a specific model id ' +
              'to make the gateway only dispatch matching requests.' + Ansi.Reset);
      Result := ReadLineEcho('Default model (Enter for wildcard): ');
    end
    else
      repeat
        Result := ReadLineEcho('Default model (provider does not advertise one -- required): ');
      until Trim(Result) <> '';
    if Trim(Result) = '' then Result := Default;
    Exit;
  end;

  SortModelsByDate(Models);
  VisibleN := ShowPicker(Models, ProviderName, SourceLabel,
                         { FetchedAt unused by ShowPicker -- kept on the
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
    to silently pick an off-screen model -- Codex P2 on PR #172. Numbers
    outside the visible range fall through to the free-form-id branch
    below, same as any non-numeric input. }
  Pick := StrToIntDef(Input, 0);
  if (Pick >= 1) and (Pick <= VisibleN) then
    Exit(Models[Pick - 1].Id);

  { Anything else gets taken as a free-form model id -- operator may
    know about a model the cache doesn't list yet. }
  Result := Input;
end;

procedure UpsertProvider(Cfg: TConfig; const Spec: TProviderSpec;
                         const Model, Key: string);
var
  i, Idx: Integer;
  Found: Boolean;
begin
  Found := False;
  for i := 0 to High(Cfg.Providers) do
    if SameText(Cfg.Providers[i].Name, Spec.Kind) then
    begin
      if Key <> '' then Cfg.Providers[i].APIKey := Key;
      { Empty Model normally means "operator left the prompt blank,
        keep the existing per-provider model." For the relay family
        empty is the deliberate wildcard sentinel and must overwrite
        a previously-pinned value -- otherwise re-onboarding can't
        clear it. Same exemption the DefaultModel assignment in
        Cmd_Onboard_Run uses, kept in sync here so the per-provider
        record and the top-level Cfg.DefaultModel don't drift apart. }
      if (Model <> '') or (Spec.Family = pfRelay) then
        Cfg.Providers[i].Model := Model;
      Cfg.Providers[i].Kind := Spec.Kind;
      if Cfg.Providers[i].APIBase = '' then
        Cfg.Providers[i].APIBase := Spec.DefaultBase;
      Found := True;
      Break;
    end;
  if Found then Exit;

  { Append a fresh entry.

    Do NOT use `with Cfg.Providers[High(...)] do` here -- the with
    block shadows the `Model` and `Key` parameters with the record's
    Model and APIKey fields, so the subsequent `if Model <> ''` check
    looks at the just-SetLength'd entry's empty Model field instead
    of the parameter. The else branch then fires and the entry
    silently gets Spec.DefaultModel ('' for the relay catalog row,
    which is what surfaced in the bug report). For providers with a
    seeded entry the update loop above short-circuits before this
    code runs, which is why the with-shadow trap hid behind a "works
    for everything except relay-from-cold" facade. Fully-qualifying
    each field assignment closes the shadow. }
  Idx := Length(Cfg.Providers);
  SetLength(Cfg.Providers, Idx + 1);
  Cfg.Providers[Idx].Name    := Spec.Kind;
  Cfg.Providers[Idx].Kind    := Spec.Kind;
  Cfg.Providers[Idx].APIBase := Spec.DefaultBase;
  Cfg.Providers[Idx].APIKey  := Key;
  if Model <> '' then
    Cfg.Providers[Idx].Model := Model
  else
    Cfg.Providers[Idx].Model := Spec.DefaultModel;
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
  { Mirrors Cmd.MCP.DoInstall's upsert -- if an entry for this catalog
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
  HTTP GETs against a curated registry -- no execution path. User
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
    '(samples, components, libraries) on pasclaw.dev -- read-only HTTP GETs.' +
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
    PrintLn('  ' + Ansi.Dim + '(skipped -- flip vault_tools_enabled in config.json to enable later)' + Ansi.Reset);
  end;
end;

procedure PromptCheckpoints(Cfg: TConfig);
{ Opt-in toggle for per-edit checkpoints + `/undo`. Off by default
  because it can be heavy -- a turn that fs_writes a 5 MB generated
  file copies the whole 5 MB into the per-turn snapshot dir. Bounded
  by checkpoints_keep_last (default 32) but the upper bound is still
  controlled by the operator's intent, so we ask. }
var
  Choice: string;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Checkpoints + /undo' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Auto-snapshot files BEFORE fs_write / fs_edit_hashline mutates them. ' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    'The TUI ' + Ansi.Reset + Ansi.Bold + '/undo' + Ansi.Reset +
    Ansi.Dim + ' [N] command rewinds N turns by restoring those captures.' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Storage: workspace/checkpoints/<session>/turn-NNNN/ (the last 32 turns).' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    '(Off by default -- can be heavy when the model writes large files. ' +
    'No rollback story without this.)' +
    Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable checkpoints [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.CheckpointsEnabled := True;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
            ' checkpoints enabled (last 32 turns kept per session)');
  end
  else
  begin
    Cfg.CheckpointsEnabled := False;
    PrintLn('  ' + Ansi.Dim +
            '(skipped -- flip checkpoints_enabled in config.json to enable later)' +
            Ansi.Reset);
  end;
end;

procedure PromptMemoryDistill(Cfg: TConfig);
{ Opt-in (default N): auto-distil durable facts from each turn into
  workspace/memory/facts.db. Uses the chat model -- NOT the embedding
  model -- so it needs no `memory provision` / ONNX download, and is
  independent of vector search. Off by default because it spends ~one
  extra LLM call per turn. }
var
  Choice: string;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Distilled memory (auto-facts)' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'After each turn, run one LLM pass that extracts durable facts ' +
    '(preferences, decisions, current focus) and stores them in ' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    'workspace/memory/facts.db -- recalled later via memory_search.' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Uses your chat model (no extra download, independent of vector ' +
    'search); costs ~one extra LLM call per turn.' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    '(Off by default. Manage with `pasclaw memory facts` / ' +
    '`pasclaw memory distill`.)' +
    Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable distilled memory [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.MemoryDistillEnabled := True;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
            ' distilled memory enabled (facts captured each turn)');
  end
  else
  begin
    Cfg.MemoryDistillEnabled := False;
    PrintLn('  ' + Ansi.Dim +
            '(skipped -- flip memory_distill_enabled in config.json to enable later)' +
            Ansi.Reset);
  end;
end;

procedure PromptShellBackend(Cfg: TConfig);
{ Pick where shell_exec / execute_code run. Local (default) =
  /bin/sh in the host process, same as PasClaw has shipped to date.
  Docker = a per-session container with workspace bind-mounted at
  the same path so files the model writes are visible to the
  operator on the host. Phase 2 will add ssh. }
var
  Choice, Image, Network: string;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Shell backend' + Ansi.Reset +
          ' -- where ' + Ansi.Bold + 'shell_exec' + Ansi.Reset +
          ' and ' + Ansi.Bold + 'execute_code' + Ansi.Reset + ' run');
  PrintLn(Ansi.Dim +
    '  local:  /bin/sh in the host process (current behaviour)' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    '  docker: docker exec into a per-session container; workspace' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    '          bind-mounted at the same path so the model sees the' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    '          same files you do on the host. Requires `docker` CLI' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    '          + a running daemon.' + Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Pick [local/docker] (default local): ')));
  if Choice = 'docker' then
  begin
    Cfg.ShellBackend := sbDocker;
    Image := Trim(ReadLineEcho('  Docker image [debian:bookworm-slim]: '));
    if Image <> '' then Cfg.ShellBackendDocker.Image := Image;
    Network := Trim(LowerCase(ReadLineEcho(
                '  Network mode [bridge/host/none] (default bridge): ')));
    if (Network = 'host') or (Network = 'none') then
      Cfg.ShellBackendDocker.Network := Network
    else
      Cfg.ShellBackendDocker.Network := 'bridge';
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
            ' docker backend configured (image=' + Cfg.ShellBackendDocker.Image +
            ', network=' + Cfg.ShellBackendDocker.Network + ')');
    PrintLn('  ' + Ansi.Dim +
            'Test with: ' + Ansi.Reset + Ansi.Bold + 'pasclaw agent -m "echo hello from $(uname -n)"' +
            Ansi.Reset);
  end
  else
  begin
    Cfg.ShellBackend := sbLocal;
    PrintLn('  ' + Ansi.Dim +
            '(local backend -- legacy behaviour. Change in config.json or ' +
            'pass --backend docker per-run.)' + Ansi.Reset);
  end;
end;

function PickStrChan(const Channel: string): string;
{ Tiny inline helper used by the heartbeat onboarding line only. }
begin
  if Channel = '' then Result := ', log-only'
  else                 Result := ', posts to "' + Channel + '"';
end;

procedure PromptHeartbeat(Cfg: TConfig);
{ Heartbeat = proactive periodic wake-up: a background `pasclaw
  heartbeat` daemon reads workspace/heartbeat.md every N minutes
  and runs the agent on its body. Off by default because it
  produces unsolicited model calls -- "the agent talks to itself"
  surprises operators who didn't ask for it, and on metered
  providers each tick is real spend.

  When the operator opts in, prompt for the interval and the
  channel name. Default channel name is empty (log only); the
  operator can still wire one up later by editing config.json.
  We don't surface "channels" as an onboarding concept here --
  that lives in send_message / cron / channel docs. }
var
  Choice, IntervalIn, ChannelIn: string;
  Mins: Integer;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Heartbeat -- proactive periodic wake-up' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'A background `pasclaw heartbeat` daemon reads ' + Ansi.Reset +
    Ansi.Bold + 'workspace/heartbeat.md' + Ansi.Reset + Ansi.Dim +
    ' every N' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'minutes and runs the agent on its body (e.g. "check the build status; if' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'red over an hour, send_message to ops"). Result can post to a configured' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'channel. Off by default -- unsolicited model spend opts in by hand.' + Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable heartbeat [y/N]: ')));
  if (Choice <> 'y') and (Choice <> 'yes') then
  begin
    Cfg.Heartbeat.Enabled := False;
    PrintLn('  ' + Ansi.Dim +
            '(skipped -- flip heartbeat.enabled in config.json to enable later)' +
            Ansi.Reset);
    Exit;
  end;
  Cfg.Heartbeat.Enabled := True;
  IntervalIn := Trim(ReadLineEcho('  Interval in minutes [30]: '));
  Mins := StrToIntDef(IntervalIn, 30);
  if Mins < 1 then Mins := 30;
  Cfg.Heartbeat.IntervalMins := Mins;
  ChannelIn := Trim(ReadLineEcho('  Post result to channel (empty = log only): '));
  Cfg.Heartbeat.Channel := ChannelIn;
  PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
          Format(' heartbeat enabled (every %d min', [Mins]) +
          PickStrChan(ChannelIn) + ')');
  PrintLn('  ' + Ansi.Dim +
          'Create workspace/heartbeat.md with your tick prompt, then run:' +
          Ansi.Reset);
  PrintLn('  ' + Ansi.Dim + '  pasclaw heartbeat' + Ansi.Reset);
end;

(* ---------------- Loop-shaping prompts (PR #289) ----------------

   Six knobs that change what the model sees in its tool loop. The
   PR-#289 audit found these were the loop-affecting features without
   an onboarding question; each is wired in here defaulting to its
   TConfig.Create value so pressing Enter through onboarding leaves the
   defaults intact.

     PromptCondenseReversible   default N  (Cfg default off)
     PromptToolOutputCap        default N  (Cfg default off / 0)
     PromptOrientTaskAware      default N  (Cfg default off)
     PromptPromptware           default Y  (Cfg default on)
     PromptWebFetch             default Y  (Cfg default on)
     PromptSelfImprovingSkills  4 nested questions, all default N

   All six follow the existing PromptStatsCollection / PromptVaultTools
   shape: a bold header, two dim explainer lines, the y/N or Y/n
   prompt, and a green ✓ / dim "(skipped)" tail line on either branch. *)

procedure PromptCondenseReversible(Cfg: TConfig);
{ Reversible condensation (CCR) -- when a JSON or shell-filter
  condenser actually shrinks a tool result, stash the original under a
  fresh tool_output_get handle and replace the in-context body with a
  structural view + a footer naming the handle. Off by default since
  PR #289: silently rewriting `ls -l` or `grep -r` output into a
  shape view surprised operators on fresh deploys. The condenser
  itself is harmless; the visibility change isn't. }
var
  Choice: string;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Condense long tool output' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Replace long ls/grep/JSON tool results with a structural summary + a ' +
    'handle the' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'model can dereference. Off by default -- the raw output goes to the ' +
    'model verbatim.' + Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable reversible condensation [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.CondenseReversible := True;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + ' reversible condensation enabled');
  end
  else
  begin
    Cfg.CondenseReversible := False;
    PrintLn('  ' + Ansi.Dim + '(skipped -- raw tool output preserved; flip condense_reversible in config.json to enable later)' + Ansi.Reset);
  end;
end;

procedure PromptToolOutputCap(Cfg: TConfig);
{ Byte cap on per-tool-result bytes that enter the LLM context. When
  > 0, RunToolLoop diverts overlong tool outputs into PasClaw.Tools.
  OutputCache and replaces the in-context body with a head + tail
  snippet plus a handle. Off by default; 8 KiB is the recommended
  starting point (~2K tokens). Independent of CondenseReversible --
  the cap is structural (cap N bytes), the condenser is semantic
  (compress an N-byte JSON to a shape). }
var
  Choice, Input: string;
  Cap: Integer;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Cap tool output size' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Truncate any tool result above N bytes to head + tail + a handle the ' +
    'model' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'can read back. Useful when a runaway grep can dump megabytes into the ' +
    'context.' + Ansi.Reset);
  PrintLn;
  { Default-on since the cap flipped to DefaultToolOutputCap: Enter keeps
    the default, y customises the byte count, n disables (explicit 0,
    which round-trips). }
  Choice := Trim(LowerCase(ReadLineEcho(Format(
    '  Cap tool output at %d bytes [Y/n/y=custom]: ', [DefaultToolOutputCap]))));
  if (Choice = 'n') or (Choice = 'no') then
  begin
    Cfg.ToolOutputCap := 0;
    PrintLn('  ' + Ansi.Dim + '(uncapped -- set tool_output_cap in config.json to re-enable)' + Ansi.Reset);
  end
  else if (Choice = 'y') or (Choice = 'yes') then
  begin
    Input := Trim(ReadLineEcho(Format('  Cap (bytes) [%d]: ', [DefaultToolOutputCap])));
    Cap := StrToIntDef(Input, DefaultToolOutputCap);
    if Cap < 256 then Cap := 256;
    Cfg.ToolOutputCap := Cap;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + Format(' tool output cap = %d bytes', [Cap]));
  end
  else
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
            Format(' tool output cap = %d bytes (default)', [DefaultToolOutputCap]));
end;

procedure PromptOrientTaskAware(Cfg: TConfig);
{ Task-aware MEMORY orientation: instead of injecting the whole
  MEMORY.md + daily notes into the system prompt, slice them to the
  sections that lexically overlap the user's task hint. Off by
  default -- the whole-file injection is the documented contract;
  this is a context-budget optimisation for operators with large
  MEMORY.md files. }
var
  Choice: string;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Task-aware MEMORY slicing' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Slice MEMORY.md + daily notes to the sections that overlap the task ' +
    'instead of' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'injecting whole files. Useful once your MEMORY.md outgrows the always-inject ' +
    'budget.' + Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable task-aware orient [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.OrientTaskAware := True;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + ' task-aware orient enabled');
  end
  else
  begin
    Cfg.OrientTaskAware := False;
    PrintLn('  ' + Ansi.Dim + '(skipped -- whole-file MEMORY injection stays the default)' + Ansi.Reset);
  end;
end;

procedure PromptPromptware(Cfg: TConfig);
{ Prompt-injection scan (PasClaw.Promptware). Lowercase substring
  scan over tool output / recalled memory / skill descriptions that
  annotates matches with a warning banner. On by default -- it's a
  free defense layer; the prompt exists so an operator wanting raw
  unannotated tool output can flip it off without grepping config. }
var
  Choice: string;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Promptware defense' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Annotate tool output / recalled memory / skill descriptions matching ' +
    'known' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'prompt-injection patterns ("ignore previous instructions" etc.) with a ' +
    'warning.' + Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable promptware scan [Y/n]: ')));
  if (Choice = '') or (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.PromptwareEnabled := True;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + ' promptware scan enabled');
  end
  else
  begin
    Cfg.PromptwareEnabled := False;
    PrintLn('  ' + Ansi.Dim + '(skipped -- raw tool output passes through unannotated)' + Ansi.Reset);
  end;
end;

procedure PromptWebFetch(Cfg: TConfig);
{ web_fetch / memory_fetch tools. On by default since PR #289 --
  picoclaw historically uses shell + curl, but PasClaw runs in
  sandboxed containers where curl isn't always available. The
  prompt is so operators not wanting outbound HTTP from the agent
  can flip it off. }
var
  Choice: string;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'web_fetch tool' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Let the agent fetch URLs through a tracked tool (size cap, save_to, ' +
    'tracing)' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'instead of shelling out to curl. memory_fetch is registered alongside ' +
    'when on.' + Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable web_fetch [Y/n]: ')));
  if (Choice = '') or (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.WebFetchEnabled := True;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + ' web_fetch / memory_fetch enabled');
  end
  else
  begin
    Cfg.WebFetchEnabled := False;
    PrintLn('  ' + Ansi.Dim + '(skipped -- the model uses shell + curl for outbound HTTP)' + Ansi.Reset);
  end;
end;

procedure PromptHashline(Cfg: TConfig);
{ fs_edit_hashline tool registration. Default Y (matches TConfig.Create);
  Enter-through keeps the surgical-patch tool. Small-model operators
  (Haiku-class) answer N to drop the tool -- the bench found those
  models mis-author the anchor/payload format and burn turns recovering.
  NOTE: fs_grep is NOT gated by this -- it registers unconditionally
  because its ripgrep-inspired optimisations win on real codebases and
  on Windows there's no shell grep at all. }
var
  Choice: string;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'edit_file hashline mode (surgical patches)' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'edit_file always offers old_text->new_text string edits. This adds its ' +
    'advanced' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'hashline-anchored patch mode (+ line-numbered read_file output). Big ' +
    'models use' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'it correctly; smaller models (Haiku, gpt-4o-mini, Llama 3.x 8B) sometimes ' +
    'mis-author' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'the anchor/payload format. Answer N on small-model deployments; the agent ' +
    'then' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'uses string edits + write_file rewrites instead. grep_files is always on.' +
    Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable edit_file hashline mode [Y/n]: ')));
  if (Choice = '') or (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.HashlineEnabled := True;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + ' edit_file hashline mode enabled');
  end
  else
  begin
    Cfg.HashlineEnabled := False;
    PrintLn('  ' + Ansi.Dim + '(skipped -- the model uses string edits + write_file)' + Ansi.Reset);
  end;
end;

procedure PromptMCPProgressiveDisclosure(Cfg: TConfig);
{ Hermes-style lazy reveal for MCP tools. Default Y -- fat catalogs
  (Replicate MCP ~50 tools, GitHub MCP ~50+, stacks easily hit 100+)
  make lazy reveal the right floor. The question is asked only when
  at least one MCP server is configured; with zero servers the flag
  is inert and the prompt would just be confusing noise. Operators
  with one or two tiny servers answer N to keep every schema in the
  per-request tools array (saves the +1 turn cost on first use of
  each tool, at the price of larger every-turn prompts). }
var
  Choice: string;
  Enabled, i: Integer;
begin
  Enabled := 0;
  for i := 0 to High(Cfg.MCPServers) do
    if Cfg.MCPServers[i].Enabled then Inc(Enabled);
  if Enabled = 0 then
  begin
    { No MCP servers -- the flag is inert at runtime (tool_search
      registers but DeferredNames is empty). Leave whatever the
      operator (or the default) has and skip the question. Do NOT
      force False here: a fresh-install with the True default has
      MCPProgressiveDisclosure=True and that's fine. }
    Exit;
  end;

  PrintLn;
  PrintLn(Ansi.Bold + 'MCP progressive disclosure' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    Format('You have %d MCP server(s) enabled. Progressive disclosure ' +
           'withholds', [Enabled]) + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'their tool schemas from the per-request `tools` array; the model ' +
    'discovers' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'tools by name in the system prompt and loads schemas on demand via ' +
    '`tool_search`.' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Default Y -- recommended for fat catalogs (Replicate / GitHub MCP). ' +
    'Answer N' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'if you have one or two tiny servers and the +1 turn per first-use ' +
    'isn''t worth' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'the prompt savings.' + Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable MCP progressive disclosure [Y/n]: ')));
  if (Choice = '') or (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.MCPProgressiveDisclosure := True;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
            ' tool_search registered; MCP tool schemas withheld until loaded');
  end
  else
  begin
    Cfg.MCPProgressiveDisclosure := False;
    PrintLn('  ' + Ansi.Dim +
            '(disabled -- every MCP tool''s schema sent in the per-request tools array)' +
            Ansi.Reset);
  end;
end;

procedure PromptSelfImprovingSkills(Cfg: TConfig);
{ Four nested toggles for the Hermes-style self-improving skills
  (PR #288). Each defaults N because the feature touches:
    - what tools the model has (skills_manage)
    - how the system prompt is built (progressive disclosure)
    - whether an extra LLM call happens per qualifying turn (distiller)
    - the auto-approve gate on every model-authored skill write
  An operator opting in for one piece usually doesn't want the
  others by default. So we ask separately. Skipping the top-level
  switch skips all four. }
var
  Choice: string;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Self-improving skills' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Let the agent author / edit / refine skills on disk during a turn ' +
    '(Hermes-style).' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Off by default. See docs/skills.md for the safety model.' +
    Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Configure self-improving skills now [y/N]: ')));
  if not ((Choice = 'y') or (Choice = 'yes')) then
  begin
    { Codex PR #289 P2: re-running onboarding on a config that already
      had any sub-flag on must be able to turn them off. The original
      "Exit" left previously-set True values intact, so a user who
      enabled the feature once couldn't ever disable it via onboarding.
      Reset all four explicitly. }
    Cfg.SelfImprovingSkills.SelfManage            := False;
    Cfg.SelfImprovingSkills.ProgressiveDisclosure := False;
    Cfg.SelfImprovingSkills.Distiller.Enabled     := False;
    Cfg.SelfImprovingSkills.AutoApprove           := False;
    PrintLn('  ' + Ansi.Dim + '(skipped -- all four sub-flags reset to off)' + Ansi.Reset);
    Exit;
  end;

  { Same preserve-old-true bug at each nested else: explicitly assign
    False when the operator answers N, so a previously-on sub-flag
    actually flips off on the re-run. }
  Choice := Trim(LowerCase(ReadLineEcho('  Register skills_manage so the model can author skills [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.SelfImprovingSkills.SelfManage := True;
    PrintLn('    ' + Ansi.Green + '✓' + Ansi.Reset + ' skills_manage registered');
  end
  else
  begin
    Cfg.SelfImprovingSkills.SelfManage := False;
    PrintLn('    ' + Ansi.Dim + '(skipped)' + Ansi.Reset);
  end;

  Choice := Trim(LowerCase(ReadLineEcho('  Use progressive disclosure (skills_list/skills_view) instead of the full SKILLS prompt [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.SelfImprovingSkills.ProgressiveDisclosure := True;
    PrintLn('    ' + Ansi.Green + '✓' + Ansi.Reset + ' progressive disclosure on');
  end
  else
  begin
    Cfg.SelfImprovingSkills.ProgressiveDisclosure := False;
    PrintLn('    ' + Ansi.Dim + '(skipped)' + Ansi.Reset);
  end;

  Choice := Trim(LowerCase(ReadLineEcho('  Enable the post-turn distiller (one extra LLM call per qualifying turn) [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.SelfImprovingSkills.Distiller.Enabled := True;
    PrintLn('    ' + Ansi.Green + '✓' + Ansi.Reset + ' distiller enabled (min_tool_calls=5; model inherits the turn)');
  end
  else
  begin
    Cfg.SelfImprovingSkills.Distiller.Enabled := False;
    PrintLn('    ' + Ansi.Dim + '(skipped)' + Ansi.Reset);
  end;

  Choice := Trim(LowerCase(ReadLineEcho('  Auto-approve agent-authored skill writes [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.SelfImprovingSkills.AutoApprove := True;
    PrintLn('    ' + Ansi.Green + '✓' + Ansi.Reset + ' auto-approve on (writes commit straight to workspace/skills/)');
  end
  else
  begin
    Cfg.SelfImprovingSkills.AutoApprove := False;
    PrintLn('    ' + Ansi.Dim + '(skipped -- writes stage under .pending/; run "pasclaw skills approve" to commit)' + Ansi.Reset);
  end;
end;

(* PR #291: starter profile picker. Sits at the top of the
   loop-shaping block; when the operator picks a profile, every
   loop-shaping prompt below it is skipped (the profile encapsulates
   those choices) AND the profile name is persisted into config.json
   so a later `pasclaw agent` invocation re-applies the bundle. The
   default is "skip", which leaves the per-feature prompts behind
   wired exactly like the pre-PR-#291 flow.

   PickedAProfile is OUT True when the operator chose a real profile
   (1-6); callers use this to short-circuit the loop-shaping prompts
   below. *)
procedure PromptStarterProfile(Cfg: TConfig; out PickedAProfile: Boolean);
const
  ChoiceLabels: array[0..5] of string = (
    'stock      -- explicit no-op profile mirroring TConfig.Create defaults',
    'baseline   -- everything off; A/B reference',
    'low-token  -- condenser, output cap, cache, progressive disclosure, auto-router',
    'security   -- sandbox tight, no outbound HTTP, agent skill writes staged',
    'max-build  -- opinionated coding setup; low-token + web_fetch + vault + checkpoints + ...',
    'all-on     -- every flag on; surface-area testing only'
  );
  ChoiceNames: array[0..5] of string = (
    'stock', 'baseline', 'low-token', 'security', 'max-build', 'all-on'
  );
var
  Input: string;
  Idx: Integer;
  Bodies: TProfileBodyArray;
  Err: string;
  i: Integer;
begin
  PickedAProfile := False;
  PrintLn;
  PrintLn(Ansi.Bold + 'Starter profile' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'A profile bundles loop-shaping defaults (condenser, output cap, ' +
    'skills, etc).' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Pick one to skip the per-feature prompts below, or skip to choose ' +
    'à la carte.' + Ansi.Reset);
  PrintLn;
  for i := 0 to High(ChoiceLabels) do
    PrintLn(Format('  %d. %s', [i + 1, ChoiceLabels[i]]));
  PrintLn('  7. skip   -- per-feature prompts (default)');
  PrintLn;
  Input := Trim(ReadLineEcho('  Pick [1-7] (default 7): '));
  if Input = '' then Idx := 7
  else if not TryStrToInt(Input, Idx) then Idx := 7;
  if (Idx < 1) or (Idx > 6) then
  begin
    PrintLn('  ' + Ansi.Dim + '(skipped -- per-feature prompts continue)' + Ansi.Reset);
    Exit;
  end;

  { Apply the profile body chain so the operator can SEE the chosen
    bundle in /v1/config + so other prompts that DON'T have profile
    coverage (KB / stats / checkpoints / shell backend / heartbeat /
    auto-router) get sensible defaults relative to the profile. Even
    though Cfg.Profile is persisted and LoadConfig re-applies it on
    every run, applying here makes the rest of onboarding consistent
    with what's about to ship. }
  if not ResolveProfileBodies(GetHome, ChoiceNames[Idx - 1], Bodies, Err) then
  begin
    PrintLn('  ' + Ansi.Red + '✗ ' + Ansi.Reset +
            'profile lookup failed (' + Err + ') -- falling back to per-feature prompts');
    Exit;
  end;
  for i := 0 to High(Bodies) do
  try
    Cfg.FromJSON(Bodies[i]);
  except
    { Bad profile body: leave Cfg as-is and bail. Shouldn't happen for
      built-ins; protective for user profiles. }
    PrintLn('  ' + Ansi.Yellow + '! ' + Ansi.Reset +
            'profile layer ' + IntToStr(i + 1) + ' failed to apply -- partial state');
  end;
  Cfg.Profile := ChoiceNames[Idx - 1];
  PickedAProfile := True;
  PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + ' profile = ' +
          ChoiceNames[Idx - 1] + Ansi.Dim +
          '  (LoadConfig re-applies it on every run; override with --profile <other>)' +
          Ansi.Reset);
end;

procedure PromptStatsCollection(Cfg: TConfig);
{ Opt-in toggle for persisting per-session usage stats (tokens,
  turns, tool calls, truncation savings) into the session JSON so
  the gateway / web UI's /v1/stats endpoint can aggregate across
  sessions. Default NO -- some operators don't want a per-session
  token ledger on disk (privacy, multi-tenant deploys, etc.). The
  TUI /stats overlay is independent of this and keeps working
  either way (it uses an in-process accumulator). }
var
  Choice: string;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Stats collection' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Persist per-session token / tool-call counts into the session JSON so the' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    'web UI can show "tokens by provider", "top tools", "cost trend" etc.' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    '(Off by default. The TUI /stats overlay works regardless of this flag.)' +
    Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable stats collection [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.StatsCollectionEnabled := True;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + ' stats persisted to session JSON; visible at /v1/stats');
  end
  else
  begin
    Cfg.StatsCollectionEnabled := False;
    PrintLn('  ' + Ansi.Dim + '(skipped -- flip stats_collection_enabled in config.json to enable later)' + Ansi.Reset);
  end;
end;

{ Append (or update) a fallback entry plus its per-fallback model override,
  keeping Cfg.Fallbacks and Cfg.FallbackModels aligned by index. De-dupes by
  name: an existing entry just gets its model override refreshed. A non-empty
  Model is what makes a SAME-provider fallback useful -- "anthropic" +
  "claude-sonnet-4-6" retries Sonnet on one key when Opus is rate-limited
  (#398). Empty Model -> the fallback uses its catalog/stored default. }
procedure AppendFallbackWithModel(Cfg: TConfig; const Name, Model: string);
var
  i: Integer;
begin
  { Pad FallbackModels up to Fallbacks length so index assignment stays aligned
    even if an earlier path appended a bare fallback. }
  while Length(Cfg.FallbackModels) < Length(Cfg.Fallbacks) do
  begin
    SetLength(Cfg.FallbackModels, Length(Cfg.FallbackModels) + 1);
    Cfg.FallbackModels[High(Cfg.FallbackModels)] := '';
  end;
  for i := 0 to High(Cfg.Fallbacks) do
    if SameText(Cfg.Fallbacks[i], Name) then
    begin
      if Model <> '' then Cfg.FallbackModels[i] := Model;
      Exit;
    end;
  SetLength(Cfg.Fallbacks, Length(Cfg.Fallbacks) + 1);
  Cfg.Fallbacks[High(Cfg.Fallbacks)] := Name;
  SetLength(Cfg.FallbackModels, Length(Cfg.Fallbacks));
  Cfg.FallbackModels[High(Cfg.FallbackModels)] := Model;
end;


procedure PromptAutoRouter(Cfg: TConfig);
{ Configure a cheap-tier fallback + the auto-router (UltraCode-Shim
  shape). Two-question flow so the operator can opt into the
  fallback without opting into the router (handy if they just want
  retry-on-error coverage without per-message routing). Default NO
  to both -- the router is a "yes I understand this trades cost
  for occasional fumble" feature, not a default-on optimisation.

  The fallback we add here goes into BOTH Cfg.Fallbacks (so existing
  retry-on-error chains pick it up) AND Cfg.AutoRouter.EasyProvider
  (so the router knows which one to route easy tasks to). Skipping
  the router question still leaves a useful retry chain. }
var
  Choice, Key, Model, EffectiveKey: string;
  Catalog, Pool: TProviderSpecArray;
  Spec: TProviderSpec;
  i: Integer;
  SameAsPrimary: Boolean;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Cheaper model for simple turns' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Optional: pick a cheaper model the auto-router sends easy turns to.' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    'It can be YOUR PRIMARY provider with a smaller/cheaper model (e.g. a' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    'mini/haiku tier on the same key), or a second provider -- a local model' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    'or another cloud account that also doubles as a retry fallback on errors.' +
    Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Set up a cheaper easy-turn model now [y/N]: ')));
  if (Choice <> 'y') and (Choice <> 'yes') then
  begin
    PrintLn('  ' + Ansi.Dim +
            '(skipped -- `pasclaw auth fallback <name>` or re-run onboard later)' +
            Ansi.Reset);
    Exit;
  end;

  Catalog := AllProviderSpecs;
  { Include the primary in the pool: routing easy turns to the same provider
    with a smaller model (Opus -> Haiku on one key) is a first-class choice,
    not a no-op. A different provider additionally serves as an error-retry
    fallback; the same-provider pick is router-only. }
  Pool := Catalog;
  if Length(Pool) = 0 then
  begin
    PrintLn('  ' + Ansi.Yellow +
            'no providers in the catalog; skipping' + Ansi.Reset);
    Exit;
  end;

  PrintLn;
  if not PickFromCatalog(Pool, '', Spec) then
  begin
    PrintLn('  ' + Ansi.Dim + '(no selection -- skipped)' + Ansi.Reset);
    Exit;
  end;

  Key := '';
  if Spec.Auth.Kind <> asNone then
    { No-echo: pasted credentials land in terminal scrollback / screen
      recordings otherwise. Codex P2 on PR #203 -- the primary
      provider path uses ReadSecretLine for the identical prompt; the
      fallback prompt needs the same treatment. }
    Key := Trim(ReadSecretLine('  ' + Spec.DisplayName +
                                ' API key (leave blank to keep existing): '));

  EffectiveKey := Key;
  if (EffectiveKey = '') and (Spec.Auth.Kind <> asNone) then
    for i := 0 to High(Cfg.Providers) do
      if SameText(Cfg.Providers[i].Name, Spec.Kind) and
         (Cfg.Providers[i].APIKey <> '') then
      begin
        EffectiveKey := Cfg.Providers[i].APIKey;
        Break;
      end;

  Model := PickModelInteractive(Spec, EffectiveKey);
  SameAsPrimary := SameText(Spec.Kind, Cfg.DefaultProvider);

  if SameAsPrimary then
  begin
    { Same provider as the primary. Upsert with an EMPTY model: for a non-relay
      provider UpsertProvider only writes Model when it's non-empty, so this
      preserves the primary's model while STILL saving a rotated/just-entered
      API key (dropping the key here would leave routed turns authenticating
      with the old/blank primary key until a separate re-onboard). The cheaper
      model lives only on AutoRouter.EasyModel. We also skip adding a
      same-provider entry to the error-retry chain -- a same-endpoint/key retry
      buys no resilience, and the router already prepends the primary at route
      time. }
    if Key <> '' then
      UpsertProvider(Cfg, Spec, '', Key);
    if SameText(Model, Cfg.DefaultModel) then
      PrintLn('  ' + Ansi.Yellow +
              'note: that matches your primary model -- routing would be a no-op; ' +
              'pick a smaller model to actually save cost.' + Ansi.Reset)
    else
      PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
              ' will route easy turns to ' + Spec.DisplayName + ' / ' + Model);
  end
  else
  begin
    UpsertProvider(Cfg, Spec, Model, Key);

    { Add to the error-retry chain, recording the picked model as the
      per-fallback override so the chain retries exactly that model (de-dupes
      by name). }
    AppendFallbackWithModel(Cfg, Spec.Kind, Model);
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
            ' added ' + Spec.DisplayName + ' to fallback chain');
  end;

  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho(
    '  Auto-route simple tasks (summarise / list / explain) to this model [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.AutoRouter.Enabled       := True;
    Cfg.AutoRouter.EasyProvider  := Spec.Kind;
    { Same wildcard rule as the primary-provider DefaultModel
      assignment above -- relay's empty model is a deliberate
      sentinel, not "operator left blank, keep the previous value." }
    if (Model <> '') or (Spec.Family = pfRelay) then
      Cfg.AutoRouter.EasyModel := Model;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
            ' auto-router on; easy turns route to ' + Spec.Kind);
  end
  else if not SameAsPrimary then
    PrintLn('  ' + Ansi.Dim +
            '(router off -- fallback still used on primary errors. ' +
            'Flip auto_router.enabled in config.json to enable.)' + Ansi.Reset);

  { Same-provider capacity fallback (#398). Retrying the SAME provider only
    helps when it's a DIFFERENT model -- "Opus rate-limited -> Sonnet on one
    key" -- since per-model rate/capacity limits are real on subscription and
    API. A different provider already went into the chain above. Offer it only
    when the picked model is distinct and non-empty (else it's a same-model
    retry, which buys nothing). }
  if SameAsPrimary and (Model <> '') and (not SameText(Model, Cfg.DefaultModel)) then
  begin
    PrintLn;
    Choice := Trim(LowerCase(ReadLineEcho(
      '  Also retry ' + Model +
      ' when your primary is rate-limited (capacity fallback)? [y/N]: ')));
    if (Choice = 'y') or (Choice = 'yes') then
    begin
      AppendFallbackWithModel(Cfg, Spec.Kind, Model);
      PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
              ' capacity fallback on; ' + Spec.DisplayName + ' retries ' + Model +
              ' when the primary is rate-limited');
    end;
  end;
end;

procedure PromptVectorSearch(Cfg: TConfig);
{ Opt-in toggle for hybrid FTS+vector memory_search. Default YES
  because the hybrid index is what picoclaw / nanobot ship and it's
  what memory_search "should" feel like. The vector half adds local
  ANN search via sqlite-vec + an ONNX-runtime'd BERT embedder
  (MiniLM by default), fused with FTS5 BM25 through Reciprocal Rank
  Fusion -- same shape as picoclaw.

  After the user opts in we offer to provision the runtime artifacts
  (sqlite-vec extension, ONNX Runtime, MiniLM weights ~91 MB) right
  now via `pasclaw memory provision`. Default NO on that follow-up
  question because (a) the download is fat enough to deserve an
  explicit "yes" and (b) a user with no internet at onboard time can
  defer it. When they decline, memory_search still works -- it falls
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
    'fused via Reciprocal Rank Fusion -- matches picoclaw / nanobot memory_search.' +
    Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable vector search for memory_search [Y/n]: ')));
  if not ((Choice = '') or (Choice = 'y') or (Choice = 'yes')) then
  begin
    Cfg.VectorSearchEnabled := False;
    PrintLn('  ' + Ansi.Dim +
      '(skipped -- memory_search will use FTS5 keyword search only)' + Ansi.Reset);
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
      '(deferred -- run `pasclaw memory provision` when ready)' + Ansi.Reset);

  { Optional second stage: cross-encoder reranking. Offered right after
    vector search because it rescores the SAME candidate pool for sharper
    ordering. Default NO -- it adds another ~90 MB model download and a
    per-query scoring pass, so it deserves an explicit opt-in. Reuses the
    ONNX Runtime the embedder already needs. }
  PrintLn;
  PrintLn(Ansi.Bold + 'Memory: cross-encoder reranking (optional)' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Rescore memory_search / kb_search candidates with a local cross-encoder' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    'for sharper ordering than embeddings alone. Also serves /v1/rerank.' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    '    reranker model + vocab   (HuggingFace, ~90 MB; reuses ONNX Runtime)' +
    Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Enable reranking for retrieval [y/N]: ')));
  if not ((Choice = 'y') or (Choice = 'yes')) then
  begin
    PrintLn('  ' + Ansi.Dim +
      '(skipped -- enable later with rerank_search_enabled + ' +
      '`pasclaw memory provision --rerank`)' + Ansi.Reset);
    Exit;
  end;

  Cfg.RerankSearchEnabled := True;
  PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + ' reranking enabled');
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Download reranker now? [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    PrintLn;
    Cmd_Memory_Run(['provision', '--rerank']);
  end
  else
    PrintLn('  ' + Ansi.Dim +
      '(deferred -- run `pasclaw memory provision --rerank` when ready; ' +
      'until then retrieval keeps the RRF order)' + Ansi.Reset);
end;

procedure PromptKnowledgebase(Cfg: TConfig);
{ KB (RAG) opt-in. Gated on VectorSearchEnabled: the knowledgebase
  still works FTS-only, but the natural moment to offer "index my
  documents" is right after the user opted into local semantic search
  -- that's the capability that makes a doc corpus worth pointing the
  agent at. If they declined vectors we stay quiet and let them reach
  it later via `pasclaw kb add`.

  Adds operator-chosen director(ies)/file(s) as KB sources (indexed in
  place, never copied) and runs one Sync. Default NO and an explicit
  blank-to-finish loop: indexing reads real files (and, once the
  embedding runtime is provisioned, embeds every chunk), so nothing is
  touched unless the user asks. Missing libsqlite3 degrades to a
  one-line skip -- same philosophy as the rest of onboarding. }
var
  Choice, Path, Abs, Err: string;
  Idx: IKBIndex;
  Added, Files, Chunks: Integer;
begin
  if not Cfg.VectorSearchEnabled then Exit;

  PrintLn;
  PrintLn(Ansi.Bold + 'Knowledgebase (RAG over your documents)' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Index reference docs -- markdown, text, source code -- so the agent can' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    'retrieve them with kb_search. Indexed in place; PDFs unsupported (convert first).' +
    Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Add documents to the knowledgebase now? [y/N]: ')));
  if not ((Choice = 'y') or (Choice = 'yes')) then
  begin
    PrintLn('  ' + Ansi.Dim +
      '(skipped -- add later with `pasclaw kb add <path>`)' + Ansi.Reset);
    Exit;
  end;

  Idx := NewKBIndex;
  if not Idx.Open(DefaultKBDbPath) then
  begin
    Idx := nil;
    PrintLn('  ' + Ansi.Red + '✗' + Ansi.Reset +
      ' knowledgebase unavailable (libsqlite3 missing) -- skipped');
    Exit;
  end;
  try
    Added := 0;
    repeat
      Path := Trim(ReadLineEcho('  Directory or file to add (blank to finish): '));
      if Path = '' then Break;
      Abs := ExpandHome(Path);   { ReadLine has no shell, so expand ~ ourselves }
      if Idx.AddSource(Abs, Err) then
      begin
        PrintLn('    ' + Ansi.Green + '+' + Ansi.Reset + ' ' + ExpandFileName(Abs));
        Inc(Added);
      end
      else
        PrintLn('    ' + Ansi.Dim + 'skip: ' + Err + Ansi.Reset);
    until False;

    if Added = 0 then
    begin
      PrintLn('  ' + Ansi.Dim + '(nothing added)' + Ansi.Reset);
      Exit;
    end;

    { Persist the vector opt-in before indexing. Sync's TryEnsureVector
      reloads config.json from disk to decide whether to build the vector
      sidecar; onboarding's own SaveConfig runs later (end of
      Cmd_Onboard_Run), so on a re-run that just flipped
      vector_search_enabled false->true the on-disk value would still be
      stale here and the sidecar would be skipped. Writing now makes the
      flag Sync reads match what the user just chose (we only reach here
      when VectorSearchEnabled is true). The trailing SaveConfig stays
      and is idempotent. }
    SaveConfig(Cfg);

    PrintLn('  indexing...');
    Idx.Sync(Files, Chunks);
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
      Format(' indexed %d file(s), %d chunk(s)', [Files, Chunks]));
    PrintLn('  ' + Ansi.Dim +
      '(kb_search activates for the agent; `pasclaw kb sync` after documents change)' +
      Ansi.Reset);
  finally
    Idx := nil;
  end;
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
    'Skip what you don''t want -- you can install later with ' +
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
      PrintLn('  ' + Ansi.Green + '(already installed -- skipping)' + Ansi.Reset);
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

    { Prefer the env var when it's already set -- same path
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
      { No-echo input -- pasted tokens stay out of terminal scrollback
        and any screen recordings / shared sessions. Codex P2 on
        PR #126. }
      Token := Trim(ReadSecretLine('  ' + Entry.EnvVar + ' (paste, or blank to skip auth): '));
      HeaderVal := FormatAuthHeaderFromToken(Entry, Token);
      if HeaderVal = '' then
        PrintLn('  ' + Ansi.Yellow + '!' + Ansi.Reset +
                ' installing with no auth header -- set ' + Entry.EnvVar +
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
  PickedAProfile: Boolean;
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
      PrintLn(Ansi.Yellow + 'no valid selection -- config not changed' + Ansi.Reset);
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
      { No-echo for the same reason as the MCP token path below --
        Codex P2 on PR #126 was scoped to MCP but the provider-key
        prompt has the identical exposure (pasted credential lands
        in terminal scrollback / screen recordings). }
      Key := ReadSecretLine(Spec.DisplayName +
        ' API key (leave blank to keep existing): ');
    end;

    { Re-onboard case: when the operator leaves the prompt blank they
      almost always mean "keep my existing key" -- they're re-running
      onboard to tweak something else, not to wipe their auth. Pull
      the existing key out of Cfg.Providers so PickModelInteractive
      can still do a live /v1/models fetch with it. UpsertProvider
      already treats Key='' as "preserve existing" further down, so
      we don't need to copy this back into the saved Key variable --
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
    (* `if Model <> '' then` is the right guard for ordinary
       providers (where empty means "operator left the prompt blank,
       keep whatever DefaultModel already has"). For the relay
       family empty is the deliberate wildcard sentinel meaning
       "accept any model the connected worker advertises", and
       Cfg.DefaultModel is what the agent loop ultimately threads
       into TRelayProvider.Chat -- so without the explicit assign
       here, the cold-onboarded relay config keeps TConfig.Create's
       claude-opus-4-7 default, the queue matches against
       claude-opus-4-7, and workers advertising their actual local
       model id never get dispatched. Same path also re-onboarders
       can use to clear a previously-pinned relay model back to
       wildcard. Codex P1 review on PR #329. *)
    if (Model <> '') or (Spec.Family = pfRelay) then
      Cfg.DefaultModel := Model;

    UpsertProvider(Cfg, Spec, Model, Key);

    { Built-in MCP catalog -- opt-in per entry. Picoclaw's rule is
      "never preloaded"; we keep the same default-off prompt so a
      user pressing Enter through onboarding doesn't install
      anything they didn't explicitly say yes to. Auth tokens
      captured here land in config.json as a literal Authorization
      header value (same shape pasclaw mcp install writes when an
      env var is set). }
    PromptMCPInstalls(Cfg);
    { PR #291: starter profile picker. When the operator picks a real
      profile, the loop-shaping prompts below are skipped (the profile
      bundle encapsulates those choices). VaultTools / Vector / KB /
      Stats / Checkpoints / Shell / Heartbeat / AutoRouter still run
      unconditionally -- those touch operator-environment concerns the
      profile doesn't cover. }
    PromptStarterProfile(Cfg, PickedAProfile);
    PromptVaultTools(Cfg);
    PromptVectorSearch(Cfg);
    PromptKnowledgebase(Cfg);
    { Distilled memory: conceptually "memory", so it reads naturally after
      the vector/KB prompts -- but it's independent (chat model, no ONNX),
      so it's NOT gated on vector search. }
    PromptMemoryDistill(Cfg);
    if not PickedAProfile then
    begin
      { Loop-shaping prompts (PR #289). Order is intentional: each
        successive prompt is less likely to be wanted by an operator
        who said yes to the previous one, so a quick "enter, enter,
        enter" leaves the minimal-surprise defaults in place. }
      PromptWebFetch(Cfg);
      PromptHashline(Cfg);
      PromptPromptware(Cfg);
      PromptCondenseReversible(Cfg);
      PromptToolOutputCap(Cfg);
      PromptOrientTaskAware(Cfg);
      PromptSelfImprovingSkills(Cfg);
    end;
    PromptStatsCollection(Cfg);
    PromptCheckpoints(Cfg);
    PromptShellBackend(Cfg);
    PromptHeartbeat(Cfg);
    PromptAutoRouter(Cfg);
    PromptMCPProgressiveDisclosure(Cfg);

    SaveConfig(Cfg);
    PrintLn;
    PrintLn(Ansi.Green + '✓' + Ansi.Reset + ' wrote ' + CfgPath);
    PrintLn('Next: ' + Ansi.Bold + 'pasclaw agent -m "hello"' + Ansi.Reset);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
