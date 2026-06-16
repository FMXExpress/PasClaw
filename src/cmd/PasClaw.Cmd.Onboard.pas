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
  Choice := Trim(LowerCase(ReadLineEcho('  Cap tool output [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    Input := Trim(ReadLineEcho('  Cap (bytes) [8192]: '));
    Cap := StrToIntDef(Input, 8192);
    if Cap < 256 then Cap := 256;
    Cfg.ToolOutputCap := Cap;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset + Format(' tool output cap = %d bytes', [Cap]));
  end
  else
  begin
    Cfg.ToolOutputCap := 0;
    PrintLn('  ' + Ansi.Dim + '(skipped -- tool output is uncapped; flip tool_output_cap in config.json to enable later)' + Ansi.Reset);
  end;
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

function FilterCatalogExcluding(const Catalog: TProviderSpecArray;
                                const ExcludeKind: string): TProviderSpecArray;
{ Drop the primary provider from the picker we show for the cheap
  fallback -- the operator already picked it once and a same-as-
  primary fallback wouldn't do anything useful. }
var
  i, n: Integer;
begin
  SetLength(Result, Length(Catalog));
  n := 0;
  for i := 0 to High(Catalog) do
    if not SameText(Catalog[i].Kind, ExcludeKind) then
    begin
      Result[n] := Catalog[i];
      Inc(n);
    end;
  SetLength(Result, n);
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
  AlreadyInFallbacks: Boolean;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'Cheap fallback provider' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'Optional: add a second provider PasClaw retries on if the primary fails,' +
    Ansi.Reset);
  PrintLn(Ansi.Dim +
    'and optionally route simple questions to it to save cost on cheap-tier models.' +
    Ansi.Reset);
  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho('  Set up a cheap fallback now [y/N]: ')));
  if (Choice <> 'y') and (Choice <> 'yes') then
  begin
    PrintLn('  ' + Ansi.Dim +
            '(skipped -- `pasclaw auth fallback <name>` or re-run onboard later)' +
            Ansi.Reset);
    Exit;
  end;

  Catalog := AllProviderSpecs;
  Pool := FilterCatalogExcluding(Catalog, Cfg.DefaultProvider);
  if Length(Pool) = 0 then
  begin
    PrintLn('  ' + Ansi.Yellow +
            'no other provider in the catalog; skipping' + Ansi.Reset);
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
  UpsertProvider(Cfg, Spec, Model, Key);

  { Append to Cfg.Fallbacks unless it's already there. The retry
    chain is keyed on Name == Spec.Kind by NewProviderFromConfig,
    so we de-dupe by Kind. }
  AlreadyInFallbacks := False;
  for i := 0 to High(Cfg.Fallbacks) do
    if SameText(Cfg.Fallbacks[i], Spec.Kind) then
    begin
      AlreadyInFallbacks := True;
      Break;
    end;
  if not AlreadyInFallbacks then
  begin
    SetLength(Cfg.Fallbacks, Length(Cfg.Fallbacks) + 1);
    Cfg.Fallbacks[High(Cfg.Fallbacks)] := Spec.Kind;
  end;
  PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
          ' added ' + Spec.DisplayName + ' to fallback chain');

  PrintLn;
  Choice := Trim(LowerCase(ReadLineEcho(
    '  Auto-route simple tasks (summarise / list / explain) to this fallback [y/N]: ')));
  if (Choice = 'y') or (Choice = 'yes') then
  begin
    Cfg.AutoRouter.Enabled       := True;
    Cfg.AutoRouter.EasyProvider  := Spec.Kind;
    if Model <> '' then Cfg.AutoRouter.EasyModel := Model;
    PrintLn('  ' + Ansi.Green + '✓' + Ansi.Reset +
            ' auto-router on; easy turns route to ' + Spec.Kind);
  end
  else
    PrintLn('  ' + Ansi.Dim +
            '(router off -- fallback still used on primary errors. ' +
            'Flip auto_router.enabled in config.json to enable.)' + Ansi.Reset);
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
    if Model <> '' then Cfg.DefaultModel := Model;

    UpsertProvider(Cfg, Spec, Model, Key);

    { Built-in MCP catalog -- opt-in per entry. Picoclaw's rule is
      "never preloaded"; we keep the same default-off prompt so a
      user pressing Enter through onboarding doesn't install
      anything they didn't explicitly say yes to. Auth tokens
      captured here land in config.json as a literal Authorization
      header value (same shape pasclaw mcp install writes when an
      env var is set). }
    PromptMCPInstalls(Cfg);
    PromptVaultTools(Cfg);
    PromptVectorSearch(Cfg);
    PromptKnowledgebase(Cfg);
    { Loop-shaping prompts (PR #289). Order is intentional: each
      successive prompt is less likely to be wanted by an operator
      who said yes to the previous one, so a quick "enter, enter,
      enter" leaves the minimal-surprise defaults in place. }
    PromptWebFetch(Cfg);
    PromptPromptware(Cfg);
    PromptCondenseReversible(Cfg);
    PromptToolOutputCap(Cfg);
    PromptOrientTaskAware(Cfg);
    PromptSelfImprovingSkills(Cfg);
    PromptStatsCollection(Cfg);
    PromptCheckpoints(Cfg);
    PromptShellBackend(Cfg);
    PromptHeartbeat(Cfg);
    PromptAutoRouter(Cfg);

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
