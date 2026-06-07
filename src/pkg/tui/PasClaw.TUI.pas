(*
  PasClaw.TUI - terminal UI for `pasclaw tui`.

  Two implementations behind the same TTUI class shape:

    {$IFNDEF FPC}  Delphi build: positioned full-screen TUI built on
                   MVCFramework.Console (vendored in
                   src/pkg/vendor/dmvcframework/, Apache-2.0). Two
                   panes — session list on the left, chat scrollback +
                   input on the right — themed via ConsoleThemeDefault.
                   Per-frame redraw (~30 fps), KeyPressed/GetKey loop,
                   background TRunToolLoopThread for the LLM call so
                   the chat pane stays responsive (spinner + steering
                   counter visible while the loop runs).

    {$IFDEF FPC}   FPC build: original line-based ANSI renderer.
                   Works in any vt100-class terminal including
                   tmux/screen scrollback. No external deps. Session
                   integration not wired here — `pasclaw tui` on FPC
                   stays in-memory; Delphi build gets the full session
                   list / persistence. (Cmd_TUI_Run sets SessionId
                   regardless; the FPC branch ignores it.)

  Both share the same loop shape (TRunToolLoopThread + DoneEvent).
  The differences are visual + how chat history is presented.
*)
unit PasClaw.TUI;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types,
  PasClaw.Providers.Models,        { TModelInfoArray is referenced from the
                                     TTUI class declaration (FModelMenuModels);
                                     Delphi requires the type to be visible
                                     from the interface section's uses, not
                                     just the implementation's. FPC was
                                     permissive about this; dcc64 is not. }
  PasClaw.Tools.Registry,
  PasClaw.Session.Store;

type
  {$IFNDEF FPC}
  TFocus = (foSessions, foChat);
  {$ENDIF}

  TTUI = class
  private
    FProvider: ILLMProvider;
    FRegistry: TToolRegistry;
    FModel:    string;
    FQuit:     Boolean;
    {$IFNDEF FPC}
    { positioned-TUI state — see Run() for the per-frame loop }
    FFocus:             TFocus;
    FSession:           TSession;
    FSessions:          TSessionMetaArray;
    FSelSessIdx:        Integer;
    FSessScroll:        Integer;
    FChatScroll:        Integer;       { lines back from the bottom; 0 = pinned to latest }
    FInputBuf:          string;
    FLoopThread:        TObject;       { TRunToolLoopThread — opaque here to avoid forward-decl gymnastics }
    FLoopStartedAt:     TDateTime;
    FSpinnerFrame:      Integer;
    FConfirmDelete:     Boolean;
    FLastSessRefresh:   TDateTime;
    FLastResizeW:       Integer;
    FLastResizeH:       Integer;
    FStatusFlash:       string;        { one-line transient message shown in footer }
    FStatusFlashUntil:  TDateTime;
    FLoopSessionId:     string;        { id of the session that originated the
                                         in-flight loop — Codex P1 on PR #122:
                                         if the user swaps sessions while a
                                         loop is running, the result must land
                                         in the ORIGINATING session, never in
                                         whatever FSession now points at }
    FMenuOpen:          Boolean;       { theme picker overlay active }
    FMenuSelIdx:        Integer;       { highlighted theme in the menu }
    FMenuOrigTheme:     string;        { theme name to revert to on Escape }
    FCurrentTheme:      string;        { last-applied theme name (committed) }
    { Model picker overlay — opens on `/model`. Parallel state to the
      theme menu rather than refactoring `FMenuOpen` into a kind enum.
      Only one menu is open at a time; OpenModelMenu / OpenThemeMenu
      assert that and close the other if needed. }
    FModelMenuOpen:     Boolean;
    FModelMenuSelIdx:   Integer;
    FModelMenuModels:   TModelInfoArray;
    FModelMenuProvider: string;        { provider name for cache lookup +
                                         the "no cache — run refresh" hint }
    FModelMenuSource:   string;        { one-liner under the title, e.g.
                                         "cached 3 days ago" }
    FModelMenuOrigModel: string;       { revert to on Esc }
    { Async /v1/models refresh kicked off by /model when the cache
      is empty / missing. Spec/Base/Key were already resolved when
      the thread was spawned — we just hold them long enough to
      finish on the main thread (SaveCachedModels + open overlay).
      Polling lives in Run() right next to PollLoopWorker. }
    FModelRefreshThread:   TObject;    { TModelRefreshThread; opaque to
                                         avoid forward decls }
    FModelRefreshProvider: string;
    FModelRefreshStartedAt: TDateTime;
    procedure DrawFrame;
    procedure DrawHeaderBar(W: Integer);
    procedure DrawSessionPane(X, Y, W, H: Integer);
    procedure DrawChatPane(X, Y, W, H: Integer);
    procedure DrawFooterBar(Y, W: Integer);
    procedure DrawThemeMenu;
    procedure DrawModelMenu;
    procedure OpenModelMenu;
    procedure OpenModelOverlay(const Provider: string;
                               const R: TModelDiscoveryResult);
    procedure StartModelRefresh(const Provider: string);
    procedure PollModelRefresh;
    function  ActiveProviderName: string;
    procedure HandleModelMenuKey(Key: Integer);
    procedure ApplyModelSelection(const ModelId: string);
    procedure HandleKey(Key: Integer);
    procedure HandleSessionKey(Key: Integer);
    procedure HandleChatKey(Key: Integer);
    procedure HandleMenuKey(Key: Integer);
    procedure OpenThemeMenu;
    procedure ApplyTheme(const Name: string; ForcePreview: Boolean);
    procedure SubmitInput;
    procedure StartTurn(const UserText: string);
    procedure PollLoopWorker;
    procedure RefreshSessions;
    procedure SelectSession(Id: string);
    procedure StartNewSession;
    procedure DeleteSelectedSession;
    procedure PersistSession;
    procedure Flash(const Msg: string);
    function CurrentSpinnerChar: Char;
    {$ENDIF}
    procedure DrawHeader;
    procedure ShowHelp;
    procedure ShowTools;
    procedure HandleSlashCommand(const Cmd: string);
    procedure HandleUserInput(const Text: string);
  public
    (* Operator's prompt-cache settings. Defaults to default-on (matches
       DefaultChatOptions). Cmd_TUI_Run copies Cfg.PromptCache into this
       after construction so `prompt_cache.enabled: false` in config.json
       turns caching off here too — see PasClaw.Config.ApplyPromptCacheConfig
       and Codex P2 on PR #118. *)
    PromptCacheEnabled: Boolean;
    PromptCacheTTL:     string;
    (* When True, the assistant's reply is run through
       PasClaw.Markdown.Render before being printed — headings and
       fenced code blocks get ANSI styling, raw stars and hashes
       disappear. On by default for the TUI; Cmd_TUI_Run forwards
       Cfg.RenderMarkdown here. *)
    RenderMarkdownEnabled: Boolean;
    (* Initial session to load. Empty = auto-allocate a fresh id (Delphi
       branch only; FPC branch ignores it). Cmd_TUI_Run forwards
       --session here, mirroring `pasclaw agent --session <id>`. *)
    SessionId:          string;
    (* Initial colour theme. One of:
         'default' (default) | 'navy' | 'matrix' | 'sunset' | 'ocean' |
         'midnight' | 'classic'
       Unknown names fall back silently to 'default'. Cmd_TUI_Run
       forwards --theme here. Live switching via the in-TUI menu
       (/theme) does NOT persist back — this PR is the picker UX
       only; durable per-user theme config is a follow-up. FPC branch
       ignores. *)
    ThemeName:          string;
    constructor Create(Provider: ILLMProvider; Registry: TToolRegistry; const Model: string);
    {$IFNDEF FPC}destructor Destroy; override;{$ENDIF}
    procedure Run;
  end;

implementation

uses
  Classes,
  SyncObjs,
  DateUtils,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Tools.ToolLoop,
  PasClaw.Agent.Steering,
  PasClaw.Markdown.Render,
  PasClaw.Providers.Catalog,       { TProviderSpec — for TModelRefreshThread }
  PasClaw.Config
  { PasClaw.Providers.Models is in the interface uses already — needed
    from there so dcc64 can see TModelInfoArray when it compiles the
    TTUI class declaration. }
  {$IFNDEF FPC}
  , Math, StrUtils,
  MVCFramework.Console, LoggerPro.AnsiColors
  {$ENDIF}
  ;

type
  TRunToolLoopThread = class(TThread)
  private
    FCfg: TToolLoopConfig;
    FMsgs: array of TMessage;
    FLoop: TToolLoopResult;
    FOk: Boolean;
    FErr: string;
    FDone: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const ACfg: TToolLoopConfig; const AMsgs: array of TMessage);
    destructor Destroy; override;
    property LoopResult: TToolLoopResult read FLoop;
    property Ok: Boolean read FOk;
    property Err: string read FErr;
    property DoneEvent: TEvent read FDone;
  end;

  { Background /v1/models discovery for the TUI's `/model` overlay.
    Same shape as TRunToolLoopThread — Execute drives a single
    synchronous call (DiscoverModels), TEvent signals completion,
    the main Run() loop polls every frame. Lets us auto-refresh the
    cache when /model is hit with an empty / missing cache without
    freezing the UI thread on the HTTP round-trip. }
  TModelRefreshThread = class(TThread)
  private
    FSpec: TProviderSpec;
    FBase, FKey: string;
    FResult: TModelDiscoveryResult;
    FDone: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASpec: TProviderSpec; const ABase, AKey: string);
    destructor Destroy; override;
    property DiscoveryResult: TModelDiscoveryResult read FResult;
    property DoneEvent: TEvent read FDone;
  end;

function ResolveRequestTimeoutSeconds: Integer;
var
  V: string;
  N: Integer;
begin
  Result := 120;
  V := Trim(GetEnvironmentVariable('PASCLAW_REQUEST_TIMEOUT'));
  if V = '' then Exit;
  if TryStrToInt(V, N) and (N > 0) then
    Result := N;
end;

constructor TRunToolLoopThread.Create(const ACfg: TToolLoopConfig; const AMsgs: array of TMessage);
var
  i: Integer;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCfg := ACfg;
  SetLength(FMsgs, Length(AMsgs));
  for i := 0 to High(AMsgs) do
    FMsgs[i] := AMsgs[i];
  FDone := TEvent.Create(nil, True, False, '');
end;

destructor TRunToolLoopThread.Destroy;
begin
  FDone.Free;
  inherited Destroy;
end;

procedure TRunToolLoopThread.Execute;
begin
  try
    FOk := RunToolLoop(FCfg, FMsgs, FLoop);
  except
    on E: Exception do
    begin
      FOk := False;
      FErr := E.Message;
    end;
  end;
  FDone.SetEvent;
end;

constructor TModelRefreshThread.Create(const ASpec: TProviderSpec;
                                       const ABase, AKey: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FSpec := ASpec;
  FBase := ABase;
  FKey  := AKey;
  FDone := TEvent.Create(nil, True, False, '');
end;

destructor TModelRefreshThread.Destroy;
begin
  FDone.Free;
  inherited Destroy;
end;

procedure TModelRefreshThread.Execute;
begin
  try
    FResult := DiscoverModels(FSpec, FBase, FKey);
  except
    on E: Exception do
    begin
      FResult.Ok     := False;
      FResult.ErrMsg := E.Message;
    end;
  end;
  FDone.SetEvent;
end;


constructor TTUI.Create(Provider: ILLMProvider; Registry: TToolRegistry; const Model: string);
begin
  inherited Create;
  FProvider := Provider;
  FRegistry := Registry;
  FModel    := Model;
  PromptCacheEnabled := True;
  PromptCacheTTL     := '';
  RenderMarkdownEnabled := True;
end;

function StatusLine(Provider: ILLMProvider; const Model: string;
                    Registry: TToolRegistry): string;
begin
  if Provider <> nil then
    Result := Provider.GetName + '/' + Model
  else
    Result := 'offline';
  if Registry <> nil then
    Result := Result + '  tools:' + IntToStr(Registry.Count);
end;

{ ============================== Delphi (rich) ============================== }
{$IFNDEF FPC}

destructor TTUI.Destroy;
const
  CleanupWaitMs = 250;
var
  Worker: TRunToolLoopThread;
  RefreshWorker: TModelRefreshThread;
begin
  if FLoopThread <> nil then
  begin
    Worker := TRunToolLoopThread(FLoopThread);
    Worker.Terminate;
    { Bounded wait — RunToolLoop doesn't poll Terminated, so a slow
      provider HTTP call or hung shell-tool can block WaitFor
      indefinitely. Give it a quarter second to wrap up cleanly,
      otherwise hand ownership to the OS via FreeOnTerminate and
      let the process teardown reap it. Codex P2 on PR #122. }
    if Worker.DoneEvent.WaitFor(CleanupWaitMs) = wrSignaled then
    begin
      Worker.WaitFor;
      Worker.Free;
    end
    else
      Worker.FreeOnTerminate := True;
    FLoopThread := nil;
  end;
  { Same bounded-wait pattern for the /model refresh worker. The
    HTTP client there can also block past Terminate, so hand off to
    the OS on timeout. }
  if FModelRefreshThread <> nil then
  begin
    RefreshWorker := TModelRefreshThread(FModelRefreshThread);
    RefreshWorker.Terminate;
    if RefreshWorker.DoneEvent.WaitFor(CleanupWaitMs) = wrSignaled then
    begin
      RefreshWorker.WaitFor;
      RefreshWorker.Free;
    end
    else
      RefreshWorker.FreeOnTerminate := True;
    FModelRefreshThread := nil;
  end;
  FSession.Free;
  inherited Destroy;
end;

procedure TTUI.Flash(const Msg: string);
begin
  FStatusFlash := Msg;
  FStatusFlashUntil := IncSecond(Now, 3);
end;

{ The seven themes vendored DMVCFramework ships in
  src/pkg/vendor/dmvcframework/MVCFramework.Console.pas. Order here is
  the menu's display order; 'default' first since it's the default. }
const
  THEME_NAMES: array[0..6] of string = (
    'default', 'navy', 'matrix', 'sunset', 'ocean', 'midnight', 'classic'
  );

function ResolveTheme(const Name: string): TConsoleColorStyle;
begin
  if      SameText(Name, 'navy')     then Result := ConsoleThemeNavy
  else if SameText(Name, 'matrix')   then Result := ConsoleThemeMatrix
  else if SameText(Name, 'sunset')   then Result := ConsoleThemeSunset
  else if SameText(Name, 'ocean')    then Result := ConsoleThemeOcean
  else if SameText(Name, 'midnight') then Result := ConsoleThemeMidnight
  else if SameText(Name, 'classic')  then Result := ConsoleThemeClassic
  else                                    Result := ConsoleThemeDefault;
end;

function CanonicalThemeName(const Name: string): string;
var
  i: Integer;
begin
  for i := 0 to High(THEME_NAMES) do
    if SameText(Name, THEME_NAMES[i]) then Exit(THEME_NAMES[i]);
  Result := 'default';
end;

procedure TTUI.ApplyTheme(const Name: string; ForcePreview: Boolean);
begin
  SetConsoleTheme(ResolveTheme(Name));
  { Force a full repaint — old theme's background fill might leave
    ink in cells the new theme doesn't overwrite. Same trick as the
    resize path. The ForcePreview flag is purely documentation —
    every call needs the repaint, but separating "commit" vs
    "preview" callers makes the intent clearer at the call site. }
  ClrScr;
  FLastResizeW := -1;
end;

procedure TTUI.OpenThemeMenu;
var
  i: Integer;
begin
  { Mutual exclusion: only one overlay at a time. }
  FModelMenuOpen := False;
  FMenuOrigTheme := FCurrentTheme;
  FMenuSelIdx := 0;
  for i := 0 to High(THEME_NAMES) do
    if SameText(THEME_NAMES[i], FCurrentTheme) then
    begin
      FMenuSelIdx := i;
      Break;
    end;
  FMenuOpen := True;
end;

function TTUI.ActiveProviderName: string;
{ Provider name used for /model cache lookup and post-refresh apply
  decisions: prefer the active session's recorded provider, else
  the global default from config.json. Empty string when nothing
  is configured anywhere — callers flash an onboard hint in that
  case. Shared between OpenModelMenu (entry) and PollModelRefresh
  (completion) so they agree on "is this the same context the
  refresh started against". }
var
  Cfg: TConfig;
begin
  Result := '';
  if (FSession <> nil) and (FSession.Meta.Provider <> '') then
    Result := FSession.Meta.Provider
  else
  begin
    Cfg := LoadConfig;
    try
      Result := Cfg.DefaultProvider;
    finally
      Cfg.Free;
    end;
  end;
end;

procedure TTUI.OpenModelMenu;
{ Entry point for the /model slash command. Cache-first: if the
  on-disk roster has models, populate the overlay and open it
  immediately. Empty / missing cache → kick off an async refresh
  (TModelRefreshThread) so the operator no longer has to quit the
  TUI, run `pasclaw model refresh`, and restart. Completion is
  picked up by PollModelRefresh in the Run() loop. The cache file
  is keyed on the operator-facing Name (PR #171 Codex P2). }
var
  R: TModelDiscoveryResult;
  Provider: string;
begin
  if FModelRefreshThread <> nil then
  begin
    Flash('still fetching models for ' + FModelRefreshProvider + '...');
    Exit;
  end;

  Provider := ActiveProviderName;
  if Provider = '' then
  begin
    Flash('no provider configured -- run `pasclaw onboard` first');
    Exit;
  end;

  if LoadCachedModels(Provider, R) and (Length(R.Models) > 0) then
  begin
    OpenModelOverlay(Provider, R);
    Exit;
  end;

  { Empty / missing cache. Kick off a background fetch instead of
    making the operator bounce out to the CLI. }
  StartModelRefresh(Provider);
end;

procedure TTUI.OpenModelOverlay(const Provider: string;
                                const R: TModelDiscoveryResult);
{ Populate the overlay state from a discovery result (cache or
  freshly fetched) and raise it. Pulled out of OpenModelMenu so the
  async PollModelRefresh path can call the same body when the
  worker thread completes. }
var
  i: Integer;
begin
  FMenuOpen           := False;          { close any theme menu first }
  FModelMenuModels    := R.Models;
  FModelMenuProvider  := Provider;
  FModelMenuSource    := Format('cached %d models (refreshed %s)',
                                [Length(R.Models), HumanAge(R.FetchedAt)]);
  FModelMenuOrigModel := FModel;

  FModelMenuSelIdx := 0;
  for i := 0 to High(FModelMenuModels) do
    if SameText(FModelMenuModels[i].Id, FModel) then
    begin
      FModelMenuSelIdx := i;
      Break;
    end;

  FModelMenuOpen := True;
end;

procedure TTUI.StartModelRefresh(const Provider: string);
{ Resolve the provider's catalog spec + APIBase + APIKey from
  config.json (same path `pasclaw model refresh` walks) and spawn
  a background worker that hits /v1/models. The overlay does NOT
  open here — PollModelRefresh raises it once the worker completes
  successfully. Failures flash an error and leave the operator in
  the existing TUI screen. }
var
  Cfg: TConfig;
  Spec: TProviderSpec;
  Base, Key, Err: string;
  Worker: TModelRefreshThread;
begin
  Cfg := LoadConfig;
  try
    if not ResolveProviderSpecForName(Cfg, Provider, Spec, Base, Key, Err) then
    begin
      Flash(Err);
      Exit;
    end;
  finally
    Cfg.Free;
  end;

  Worker := TModelRefreshThread.Create(Spec, Base, Key);
  Worker.Start;
  FModelRefreshThread    := Worker;
  FModelRefreshProvider  := Provider;
  FModelRefreshStartedAt := Now;
  Flash('fetching models from ' + Spec.DisplayName + '...');
end;

procedure TTUI.PollModelRefresh;
{ Called every Run() tick. Picks up the TModelRefreshThread result
  when it's ready, writes the cache file, and opens the overlay
  (same shape as if the cache had been warm to begin with). Also
  enforces an 15-second wall clock so a stuck HTTP doesn't pin the
  refresh slot forever. }
const
  REFRESH_TIMEOUT_SEC = 15;
var
  Worker: TModelRefreshThread;
  R: TModelDiscoveryResult;
  Provider: string;
begin
  if FModelRefreshThread = nil then Exit;
  Worker := TModelRefreshThread(FModelRefreshThread);

  if (SecondsBetween(Now, FModelRefreshStartedAt) >= REFRESH_TIMEOUT_SEC)
     and (Worker.DoneEvent.WaitFor(0) <> wrSignaled) then
  begin
    LogWarn('tui /model refresh timeout after %ds (provider=%s)',
            [REFRESH_TIMEOUT_SEC, FModelRefreshProvider]);
    Worker.Terminate;
    Worker.FreeOnTerminate := True;
    FModelRefreshThread   := nil;
    Flash('models refresh timed out -- check connectivity');
    FModelRefreshProvider := '';
    Exit;
  end;

  if Worker.DoneEvent.WaitFor(0) <> wrSignaled then Exit;
  Worker.WaitFor;

  R        := Worker.DiscoveryResult;
  Provider := FModelRefreshProvider;
  Worker.Free;
  FModelRefreshThread   := nil;
  FModelRefreshProvider := '';

  if (not R.Ok) or (Length(R.Models) = 0) then
  begin
    if R.ErrMsg <> '' then
      Flash('refresh failed: ' + R.ErrMsg)
    else
      Flash('refresh returned no models for ' + Provider);
    Exit;
  end;

  { Always save the cache — the HTTP succeeded, the roster is now
    authoritative for this provider regardless of what the operator
    is currently looking at. }
  SaveCachedModels(Provider, R);

  { Only raise the picker overlay if the active session's provider
    still matches the one we refreshed. If the operator swapped
    sessions mid-fetch (A using openai → B using anthropic), the
    overlay would show openai's roster, ApplyModelSelection would
    write the pick into B's Meta.Model, and B silently ends up
    talking to its anthropic provider with an openai model id.
    Codex P2 on this PR — same shape as the FLoopSessionId fix
    from PR #122. Cache is safe to keep; the open is what's not. }
  if SameText(ActiveProviderName, Provider) then
    OpenModelOverlay(Provider, R)
  else
    Flash(Format('%s models refreshed (%d) -- switch to a session using %s to pick',
                 [Provider, Length(R.Models), Provider]));
end;

procedure TTUI.ApplyModelSelection(const ModelId: string);
{ Switches the active model for the running TUI. Updates FModel (used
  by StartTurn) and FSession.Meta.Model (persisted on the next turn's
  PersistSession so a /quit-after-/model survives). Does NOT touch
  config.json — that's `pasclaw model set` from the CLI. }
begin
  if ModelId = '' then Exit;
  FModel := ModelId;
  if FSession <> nil then
  begin
    FSession.Meta.Model := ModelId;
    PersistSession;
  end;
end;

function TTUI.CurrentSpinnerChar: Char;
const
  Frames: array[0..3] of Char = ('|', '/', '-', '\');
begin
  if FLoopThread = nil then
    Result := ' '
  else
    Result := Frames[FSpinnerFrame mod 4];
end;

procedure TTUI.RefreshSessions;
var
  i: Integer;
begin
  FSessions := ListSessions;
  FLastSessRefresh := Now;
  { Keep selection on the same session id when possible. }
  if (FSession <> nil) and (Length(FSessions) > 0) then
  begin
    FSelSessIdx := -1;
    for i := 0 to High(FSessions) do
      if FSessions[i].Id = FSession.Meta.Id then
      begin
        FSelSessIdx := i;
        Break;
      end;
    if FSelSessIdx < 0 then FSelSessIdx := 0;
  end
  else if FSelSessIdx < 0 then
    FSelSessIdx := 0
  else if FSelSessIdx >= Length(FSessions) then
    FSelSessIdx := Length(FSessions) - 1;
end;

procedure TTUI.PersistSession;
begin
  if FSession = nil then Exit;
  FSession.Meta.Model := FModel;
  if FProvider <> nil then FSession.Meta.Provider := FProvider.GetName;
  FSession.AutoTitle;
  FSession.Touch;
  FSession.Save;
end;

procedure TTUI.SelectSession(Id: string);
begin
  { Persist anything pending on the current session before swapping. }
  if (FSession <> nil) and (Length(FSession.Messages) > 0) then
    PersistSession;
  FSession.Free;
  if Id = '' then Id := NewSessionId;
  FSession := TSession.Create(Id);
  FChatScroll := 0;
  FInputBuf := '';
  Flash('session: ' + FSession.Meta.Id);
  RefreshSessions;
end;

procedure TTUI.StartNewSession;
begin
  SelectSession('');
end;

procedure TTUI.DeleteSelectedSession;
var
  Id: string;
begin
  if (FSelSessIdx < 0) or (FSelSessIdx >= Length(FSessions)) then Exit;
  Id := FSessions[FSelSessIdx].Id;
  if (FSession <> nil) and (FSession.Meta.Id = Id) then
  begin
    { Deleting the currently-loaded session: drop it, spawn a fresh
      one to fill the vacancy. Matches `pasclaw session delete` +
      `/new` semantics. }
    FSession.Free;
    FSession := nil;
  end;
  if DeleteSession(Id) then
  begin
    ClearSteering(Id);
    Flash('deleted ' + Id);
  end
  else
    Flash('delete failed: ' + Id);
  if FSession = nil then
  begin
    FSession := TSession.Create('');
    FInputBuf := '';
    FChatScroll := 0;
  end;
  RefreshSessions;
  FConfirmDelete := False;
end;

procedure TTUI.StartTurn(const UserText: string);
var
  Cfg: TToolLoopConfig;
  Worker: TRunToolLoopThread;
begin
  if (FProvider = nil) or (Trim(UserText) = '') then Exit;
  if FLoopThread <> nil then Exit;   { already in flight }

  { Append the user's turn to history BEFORE kicking off the loop so
    it shows up in the chat pane immediately (next redraw). }
  SetLength(FSession.Messages, Length(FSession.Messages) + 1);
  FSession.Messages[High(FSession.Messages)] := MakeMessage(mrUser, UserText);

  Cfg.Provider      := FProvider;
  Cfg.Registry      := FRegistry;
  Cfg.Model         := FModel;
  Cfg.MaxIterations := 6;
  Cfg.Parallel      := True;
  Cfg.Options       := DefaultChatOptions;
  Cfg.Options.CacheEnabled := PromptCacheEnabled;
  Cfg.Options.CacheTTL     := PromptCacheTTL;
  if FSession <> nil then
  begin
    Cfg.Options.CacheKey := FSession.Meta.Id;
    Cfg.SteeringKey      := FSession.Meta.Id;
  end;
  Cfg.OnText        := nil;
  Cfg.OnToolCall    := nil;
  Cfg.OnToolResult  := nil;

  Worker := TRunToolLoopThread.Create(Cfg, FSession.Messages);
  Worker.Start;
  FLoopThread     := Worker;
  FLoopSessionId  := FSession.Meta.Id;
  FLoopStartedAt  := Now;
  FChatScroll     := 0;
end;

{ Apply a completed loop result back to its ORIGINATING session.
  When the originating session is still the currently-loaded one
  (FSession.Meta.Id matches), update FSession in place and persist.
  When the user has swapped sessions while the loop was in flight,
  open the originating session by id, append + persist, free —
  the currently-loaded FSession is never touched. Codex P1 on PR
  #122: without this gate a parallel turn would overwrite a fresh
  conversation with another session's history. }
procedure ApplyLoopResultTo(const SessionId: string; const Loop: TToolLoopResult;
                            CurrentSession: TSession);
var
  Target: TSession;
  i: Integer;
  OwnsTarget: Boolean;
begin
  if (CurrentSession <> nil) and (CurrentSession.Meta.Id = SessionId) then
  begin
    Target := CurrentSession;
    OwnsTarget := False;
  end
  else
  begin
    Target := TSession.Create(SessionId);
    OwnsTarget := True;
  end;
  try
    if Length(Loop.FinalMessages) > 0 then
    begin
      SetLength(Target.Messages, Length(Loop.FinalMessages) + 1);
      for i := 0 to High(Loop.FinalMessages) do
        Target.Messages[i] := Loop.FinalMessages[i];
      Target.Messages[High(Target.Messages)] :=
        MakeMessage(mrAssistant, Loop.Content);
    end
    else
    begin
      SetLength(Target.Messages, Length(Target.Messages) + 1);
      Target.Messages[High(Target.Messages)] :=
        MakeMessage(mrAssistant, Loop.Content);
    end;
    Target.AutoTitle;
    Target.Touch;
    Target.Save;
  finally
    if OwnsTarget then Target.Free;
  end;
end;

procedure AppendErrorTo(const SessionId: string; const ErrText: string;
                       CurrentSession: TSession);
var
  Target: TSession;
  OwnsTarget: Boolean;
begin
  if (CurrentSession <> nil) and (CurrentSession.Meta.Id = SessionId) then
  begin
    Target := CurrentSession;
    OwnsTarget := False;
  end
  else
  begin
    Target := TSession.Create(SessionId);
    OwnsTarget := True;
  end;
  try
    SetLength(Target.Messages, Length(Target.Messages) + 1);
    Target.Messages[High(Target.Messages)] := MakeMessage(mrAssistant, ErrText);
    Target.Touch;
    Target.Save;
  finally
    if OwnsTarget then Target.Free;
  end;
end;

procedure TTUI.PollLoopWorker;
var
  Worker: TRunToolLoopThread;
  Loop: TToolLoopResult;
  TimeoutSec: Integer;
  Elapsed: Integer;
begin
  if FLoopThread = nil then Exit;
  Worker := TRunToolLoopThread(FLoopThread);

  TimeoutSec := ResolveRequestTimeoutSeconds;
  Elapsed := SecondsBetween(Now, FLoopStartedAt);
  if (Elapsed >= TimeoutSec)
     and (Worker.DoneEvent.WaitFor(0) <> wrSignaled) then
  begin
    LogWarn('tui tool-loop timeout after %ds', [TimeoutSec]);
    Worker.Terminate;
    Worker.FreeOnTerminate := True;
    AppendErrorTo(FLoopSessionId,
      Format('(request timed out after %ds)', [TimeoutSec]),
      FSession);
    FLoopThread := nil;
    FLoopSessionId := '';
    Flash(Format('timed out after %ds', [TimeoutSec]));
    RefreshSessions;
    Exit;
  end;

  if Worker.DoneEvent.WaitFor(0) <> wrSignaled then Exit;
  Worker.WaitFor;

  if Worker.Ok then
  begin
    Loop := Worker.LoopResult;
    ApplyLoopResultTo(FLoopSessionId, Loop, FSession);
    if FLoopSessionId <> FSession.Meta.Id then
      Flash('result -> ' + FLoopSessionId);
    RefreshSessions;
  end
  else
  begin
    LogWarn('tui tool-loop failed: %s', [Worker.Err]);
    AppendErrorTo(FLoopSessionId, '(tool loop failed)', FSession);
    RefreshSessions;
  end;

  Worker.Free;
  FLoopThread := nil;
  FLoopSessionId := '';
end;

procedure TTUI.SubmitInput;
var
  Text: string;
begin
  Text := Trim(FInputBuf);
  if Text = '' then Exit;

  { Slash-command shortcuts — without these the model gets "/quit"
    as a literal user message because StartTurn doesn't filter. The
    new TUI exposes most of these as dedicated keys (Q for quit,
    N for new session) but users coming from `pasclaw agent` reach
    for the slashes by reflex. Common ones; others flash a hint. }
  if (Length(Text) > 0) and (Text[1] = '/') then
  begin
    if (Text = '/quit') or (Text = '/exit') or (Text = '/q') then
      FQuit := True
    else if Text = '/new' then
      StartNewSession
    else if Text = '/clear' then
    begin
      if FSession <> nil then
      begin
        SetLength(FSession.Messages, 0);
        PersistSession;
        Flash('history cleared');
      end;
    end
    else if Text = '/help' then
      Flash('keys: Tab swap pane | N new | D del | Q quit | /theme | /model')
    else if (Text = '/tools') and (FRegistry <> nil) then
      Flash(Format('registered tools: %d', [FRegistry.Count]))
    else if Text = '/theme' then
      OpenThemeMenu
    else if Text = '/model' then
      OpenModelMenu
    else
      Flash('unknown: ' + Text);
    FInputBuf := '';
    Exit;
  end;

  { When a loop is already running, queue the input as steering so
    the running loop can pick it up at the top of its next iteration
    (PR #120 mechanism). Route to FLoopSessionId — the originating
    session — not FSession.Meta.Id, in case the user swapped panes
    while the loop was in flight. Same Codex P1 fix as PollLoopWorker. }
  if FLoopThread <> nil then
  begin
    if PushSteering(FLoopSessionId, Text) then
      Flash('steering queued')
    else
      Flash('steer push failed');
    FInputBuf := '';
    Exit;
  end;

  StartTurn(Text);
  FInputBuf := '';
end;

procedure TTUI.HandleSessionKey(Key: Integer);
begin
  { Delete-confirm mode short-circuits — Y deletes, anything else
    (including N from the [Y]es/[N]o footer hint) just dismisses
    the prompt. Without this gate, N would dismiss AND start a new
    session, which contradicts the advertised "N cancel" footer.
    Codex P2 on PR #122. }
  if FConfirmDelete then
  begin
    case Key of
      Ord('y'), Ord('Y'):
        DeleteSelectedSession;
    else
      FConfirmDelete := False;
    end;
    Exit;
  end;

  case Key of
    Ord('q'), Ord('Q'):
      { Q only quits from the session pane — chat-pane input must
        be able to contain the letter (Codex P1 on PR #122). }
      FQuit := True;
    KEY_UP:
      if FSelSessIdx > 0 then Dec(FSelSessIdx);
    KEY_DOWN:
      if FSelSessIdx < High(FSessions) then Inc(FSelSessIdx);
    KEY_ENTER:
      if (FSelSessIdx >= 0) and (FSelSessIdx <= High(FSessions)) then
        SelectSession(FSessions[FSelSessIdx].Id);
    Ord('n'), Ord('N'):
      StartNewSession;
    Ord('r'), Ord('R'):
      begin
        RefreshSessions;
        Flash('refreshed');
      end;
    Ord('d'), Ord('D'):
      begin
        FConfirmDelete := True;
        Flash('delete? y/n');
      end;
  end;
end;

procedure TTUI.HandleChatKey(Key: Integer);
var
  Ch: Char;
begin
  { Q with an empty input buffer quits — discoverability path so
    users coming from the session pane don't have to learn that
    Escape is the universal quit. With any input typed, Q falls
    through to the default-char branch so words like "question"
    work. Codex P1 on PR #122. }
  if ((Key = Ord('q')) or (Key = Ord('Q'))) and (FInputBuf = '') then
  begin
    FQuit := True;
    Exit;
  end;

  case Key of
    KEY_ENTER:
      SubmitInput;
    KEY_UP:
      { Arrow keys aren't useful in a single-line input buffer, so
        repurpose them as chat-scrollback paging. PgUp/PgDn aren't
        wired because DMVCFramework returns 33/34 for them on
        Windows, colliding with the printable '!' and '"' input
        bytes returned on Linux — no portable disambiguation. }
      Inc(FChatScroll, 5);
    KEY_DOWN:
      begin
        Dec(FChatScroll, 5);
        if FChatScroll < 0 then FChatScroll := 0;
      end;
    8, 127:   { Backspace — code differs by terminal; accept both }
      if Length(FInputBuf) > 0 then
        SetLength(FInputBuf, Length(FInputBuf) - 1);
  else
    { Printable ASCII / latin-1: append. We don't try to handle
      escape sequences or multi-byte UTF-8 here — DMVCFramework's
      GetKey on Linux returns the raw byte for printable chars, on
      Windows the VK_ codes for special keys; the printable range
      32..126 is safe everywhere. Higher bytes pass through and
      will render as their byte value on most terminals. }
    if (Key >= 32) and (Key < 256) then
    begin
      Ch := Chr(Key);
      FInputBuf := FInputBuf + Ch;
    end;
  end;
end;

procedure TTUI.HandleMenuKey(Key: Integer);
begin
  case Key of
    KEY_UP:
      if FMenuSelIdx > 0 then
      begin
        Dec(FMenuSelIdx);
        { Live preview — apply the highlighted theme as the user
          arrows through. Esc reverts to FMenuOrigTheme; Enter
          commits whatever's currently applied. }
        ApplyTheme(THEME_NAMES[FMenuSelIdx], True);
      end;
    KEY_DOWN:
      if FMenuSelIdx < High(THEME_NAMES) then
      begin
        Inc(FMenuSelIdx);
        ApplyTheme(THEME_NAMES[FMenuSelIdx], True);
      end;
    KEY_ENTER:
      begin
        FCurrentTheme := THEME_NAMES[FMenuSelIdx];
        FMenuOpen := False;
        Flash('theme: ' + FCurrentTheme);
      end;
    KEY_ESCAPE:
      begin
        ApplyTheme(FMenuOrigTheme, False);
        FCurrentTheme := FMenuOrigTheme;
        FMenuOpen := False;
      end;
  end;
end;

procedure TTUI.HandleModelMenuKey(Key: Integer);
{ Same shape as the theme menu but no "live preview" — switching the
  model in-flight on each arrow press would re-bake the running
  session's provider state, which is the wrong moment for that. Apply
  on Enter only; Esc cancels and leaves FModel unchanged.

  Down-key bound is the FULL roster length, not the visible window —
  DrawModelMenu windows the printed rows around FModelMenuSelIdx, so
  the user can scroll into models past the first page. (Codex P2 on
  this PR. The earlier "visible cap" mirrored the onboard picker's PR
  #172 fix, but that picker is line-based and never scrolls; this one
  re-paints every frame and does.) }
begin
  case Key of
    KEY_UP:
      if FModelMenuSelIdx > 0 then
        Dec(FModelMenuSelIdx);
    KEY_DOWN:
      if FModelMenuSelIdx < Length(FModelMenuModels) - 1 then
        Inc(FModelMenuSelIdx);
    KEY_ENTER:
      begin
        if (FModelMenuSelIdx >= 0) and
           (FModelMenuSelIdx < Length(FModelMenuModels)) then
        begin
          ApplyModelSelection(FModelMenuModels[FModelMenuSelIdx].Id);
          Flash('model: ' + FModel);
        end;
        FModelMenuOpen := False;
      end;
    KEY_ESCAPE:
      begin
        { ApplyModelSelection wasn't called on the navigation path, so
          there's nothing to revert — just close the overlay. }
        FModelMenuOpen := False;
      end;
  end;
end;

procedure TTUI.HandleKey(Key: Integer);
const
  KEY_TAB = 9;
begin
  { Menu intercepts first — Esc cancels the menu (reverts theme)
    instead of quitting the TUI, Up/Down navigates with live
    preview, Enter commits the selection. Model menu intercept piggybacks
    on the same gate; only one overlay can be open per the mutual-exclusion
    contract enforced in OpenThemeMenu / OpenModelMenu. }
  if FModelMenuOpen then
  begin
    HandleModelMenuKey(Key);
    Exit;
  end;
  if FMenuOpen then
  begin
    HandleMenuKey(Key);
    Exit;
  end;
  { Escape is the only global quit — Q/q reach the focused pane so
    the chat input can include the letter (typing "question" used
    to immediately quit the TUI). Codex P1 on PR #122. }
  if Key = KEY_ESCAPE then
  begin
    FQuit := True;
    Exit;
  end;
  if Key = KEY_TAB then
  begin
    if FFocus = foSessions then FFocus := foChat else FFocus := foSessions;
    FConfirmDelete := False;
    Exit;
  end;
  case FFocus of
    foSessions: HandleSessionKey(Key);
    foChat:     HandleChatKey(Key);
  end;
end;

procedure TTUI.DrawHeaderBar(W: Integer);
var
  Title, TimeStr, Line: string;
begin
  TimeStr := FormatDateTime('hh:nn:ss', Now);
  Title := ' PasClaw  ' + StatusLine(FProvider, FModel, FRegistry);
  Line := Title;
  if Length(Line) > W - Length(TimeStr) - 2 then
    Line := Copy(Line, 1, W - Length(TimeStr) - 2);
  while Length(Line) < W - Length(TimeStr) - 1 do
    Line := Line + ' ';
  Line := Line + TimeStr + ' ';
  if Length(Line) > W then Line := Copy(Line, 1, W);
  GotoXY(0, 0);
  WriteAnsiText(ConsoleTheme.HighlightText, Line);
end;

procedure TTUI.DrawFooterBar(Y, W: Integer);
var
  Hint, Status: string;
begin
  if FConfirmDelete then
    Hint := ' [Y]es delete  [N]o cancel  '
  else if FFocus = foSessions then
    Hint := ' [Tab] chat  [Up/Dn] nav  [Enter] open  [N]ew  [D]elete  [R]efresh  [Q]uit '
  else
    Hint := ' [Tab] sessions  [Enter] send  [Up/Dn] scroll  [Q]uit ';

  if Length(Hint) > W then Hint := Copy(Hint, 1, W);
  while Length(Hint) < W do Hint := Hint + ' ';
  GotoXY(0, Y);
  WriteAnsiText(ConsoleTheme.HighlightText, Hint);

  if (FStatusFlash <> '') and (CompareDateTime(Now, FStatusFlashUntil) <= 0) then
    Status := ' ' + FStatusFlash
  else
    Status := '';
  while Length(Status) < W do Status := Status + ' ';
  if Length(Status) > W then Status := Copy(Status, 1, W);
  GotoXY(0, Y + 1);
  WriteAnsiText(ConsoleTheme.Symbols, Status);
end;

procedure TTUI.DrawSessionPane(X, Y, W, H: Integer);
var
  i, Row, MaxRows: Integer;
  Header, Line, IdShort, Title: string;
  Sess: TSessionMeta;
  IsSelected: Boolean;
  Marker: string;
begin
  { Header row. }
  Header := ' Sessions';
  while Length(Header) < W do Header := Header + ' ';
  if Length(Header) > W then Header := Copy(Header, 1, W);
  GotoXY(X, Y);
  WriteAnsiText(ConsoleTheme.HighlightText, Header);

  { Reserve the last row for the count. Body rows = H - 2. }
  MaxRows := H - 2;
  if MaxRows < 1 then MaxRows := 1;

  { Auto-scroll so the selected item is visible. }
  if FSelSessIdx < FSessScroll then
    FSessScroll := FSelSessIdx
  else if FSelSessIdx >= FSessScroll + MaxRows then
    FSessScroll := FSelSessIdx - MaxRows + 1;
  if FSessScroll < 0 then FSessScroll := 0;

  for Row := 0 to MaxRows - 1 do
  begin
    i := FSessScroll + Row;
    GotoXY(X, Y + 1 + Row);
    if (i < 0) or (i > High(FSessions)) then
    begin
      WriteAnsiText(ConsoleTheme.Text, StringOfChar(' ', W));
      Continue;
    end;
    Sess := FSessions[i];
    IsSelected := (i = FSelSessIdx);

    { Compact id — yyyymmddTHHMMSS is 14 chars; show the date portion
      mm-dd plus the random tail. }
    IdShort := Copy(Sess.Id, 5, 4);
    if Length(IdShort) = 4 then
      IdShort := Copy(IdShort, 1, 2) + '-' + Copy(IdShort, 3, 2)
    else
      IdShort := Copy(Sess.Id, 1, 5);

    Title := Sess.Title;
    if Title = '' then Title := '(untitled)';

    if IsSelected and (FFocus = foSessions) then
      Marker := '>'
    else if IsSelected then
      Marker := '*'
    else
      Marker := ' ';

    Line := Format(' %s %s %s', [Marker, IdShort, Title]);
    if Length(Line) > W then Line := Copy(Line, 1, W);
    while Length(Line) < W do Line := Line + ' ';
    if IsSelected then
      WriteAnsiText(ConsoleTheme.Highlight, Line)
    else
      WriteAnsiText(ConsoleTheme.Text, Line);
  end;

  { Footer of session pane: count + provider hint. }
  Line := Format(' %d sessions', [Length(FSessions)]);
  if Length(Line) > W then Line := Copy(Line, 1, W);
  while Length(Line) < W do Line := Line + ' ';
  GotoXY(X, Y + H - 1);
  WriteAnsiText(ConsoleTheme.Symbols, Line);
end;

procedure RenderMsgLines(const Msg: TMessage; W: Integer; var Acc: TArray<string>);
var
  Header, Body, Line: string;
  Lines: TArray<string>;
  i: Integer;
begin
  case Msg.Role of
    mrUser:      Header := 'user';
    mrAssistant: Header := 'assistant';
    mrSystem:    Header := 'system';
    mrTool:      Header := 'tool';
  else
    Header := 'msg';
  end;
  if (Msg.Role = mrTool) and (Length(Msg.Name) > 0) then
    Header := Header + ' ' + Msg.Name;

  SetLength(Acc, Length(Acc) + 1);
  Acc[High(Acc)] := '__HDR__' + Header;

  Body := Msg.Content;
  if Trim(Body) = '' then
  begin
    if Length(Msg.ToolCalls) > 0 then
    begin
      for i := 0 to High(Msg.ToolCalls) do
      begin
        SetLength(Acc, Length(Acc) + 1);
        Acc[High(Acc)] := '  -> ' + Msg.ToolCalls[i].Func.Name + '(' +
                          Copy(Msg.ToolCalls[i].Func.Arguments, 1, W - 12) + ')';
      end;
    end;
  end
  else
  begin
    Lines := Body.Split([sLineBreak, #10, #13], TStringSplitOptions.None);
    for Line in Lines do
    begin
      if Length(Line) <= W - 2 then
      begin
        SetLength(Acc, Length(Acc) + 1);
        Acc[High(Acc)] := '  ' + Line;
      end
      else
      begin
        i := 1;
        while i <= Length(Line) do
        begin
          SetLength(Acc, Length(Acc) + 1);
          Acc[High(Acc)] := '  ' + Copy(Line, i, W - 2);
          Inc(i, W - 2);
        end;
      end;
    end;
  end;
  { Blank separator between messages. }
  SetLength(Acc, Length(Acc) + 1);
  Acc[High(Acc)] := '';
end;

procedure TTUI.DrawChatPane(X, Y, W, H: Integer);
const
  INPUT_ROWS = 2;   { divider + input }
var
  ChatTop, ChatH, ChatBottom: Integer;
  Lines: TArray<string>;
  i, Row, Pending: Integer;
  Line, RoleColor, InputLine, DividerLine: string;
  ShownFrom: Integer;
begin
  ChatTop := Y;
  ChatH := H - INPUT_ROWS;
  if ChatH < 1 then ChatH := 1;
  ChatBottom := ChatTop + ChatH - 1;

  { Render every message to a string list, then window into it. }
  SetLength(Lines, 0);
  if FSession <> nil then
    for i := 0 to High(FSession.Messages) do
      RenderMsgLines(FSession.Messages[i], W, Lines);

  { Clip scroll to valid range. }
  if FChatScroll < 0 then FChatScroll := 0;
  if FChatScroll > Length(Lines) - ChatH then
    FChatScroll := Length(Lines) - ChatH;
  if FChatScroll < 0 then FChatScroll := 0;

  if Length(Lines) > ChatH then
    ShownFrom := Length(Lines) - ChatH - FChatScroll
  else
    ShownFrom := 0;
  if ShownFrom < 0 then ShownFrom := 0;

  for Row := 0 to ChatH - 1 do
  begin
    i := ShownFrom + Row;
    GotoXY(X, ChatTop + Row);
    if (i < 0) or (i >= Length(Lines)) then
    begin
      WriteAnsiText(ConsoleTheme.Text, StringOfChar(' ', W));
      Continue;
    end;
    Line := Lines[i];
    if Pos('__HDR__', Line) = 1 then
    begin
      Line := Copy(Line, Length('__HDR__') + 1, MaxInt);
      if      Line = 'user'      then RoleColor := FORE_CYAN + STYLE_BRIGHT
      else if AnsiStartsStr('assistant', Line) then RoleColor := FORE_MAGENTA + STYLE_BRIGHT
      else if AnsiStartsStr('tool', Line)      then RoleColor := FORE_YELLOW
      else                                          RoleColor := FORE_GRAY;
      Line := ' ' + Line;
    end
    else
      RoleColor := ConsoleTheme.Text;
    if Length(Line) > W then Line := Copy(Line, 1, W);
    while Length(Line) < W do Line := Line + ' ';
    WriteAnsiText(RoleColor, Line);
  end;

  { Divider with steering counter + spinner + token meter. }
  if FSession <> nil then
    Pending := PendingSteeringCount(FSession.Meta.Id)
  else
    Pending := 0;
  DividerLine := Format(' steering: %d   %s ', [Pending, CurrentSpinnerChar]);
  while Length(DividerLine) < W do DividerLine := DividerLine + '-';
  if Length(DividerLine) > W then DividerLine := Copy(DividerLine, 1, W);
  GotoXY(X, ChatBottom + 1);
  WriteAnsiText(ConsoleTheme.Symbols, DividerLine);

  { Input line. Append a soft cursor when chat pane is focused. }
  if FFocus = foChat then
    InputLine := ' > ' + FInputBuf + '_'
  else
    InputLine := ' > ' + FInputBuf;
  if Length(InputLine) > W then
    InputLine := Copy(InputLine, Length(InputLine) - W + 1, W);
  while Length(InputLine) < W do InputLine := InputLine + ' ';
  GotoXY(X, ChatBottom + 2);
  WriteAnsiText(ConsoleTheme.Text, InputLine);
end;

procedure TTUI.DrawFrame;
var
  Size: TMVCConsoleSize;
  W, H, SessW, ChatX, ChatW, PaneH, ry: Integer;
  NarrowMsg: string;
begin
  Size := GetConsoleSize;
  W := Integer(Size.Columns);
  H := Integer(Size.Rows);

  { Detect resize → full ClrScr to drop any leftover characters. }
  if (W <> FLastResizeW) or (H <> FLastResizeH) then
  begin
    ClrScr;
    FLastResizeW := W;
    FLastResizeH := H;
  end;

  if (W < 60) or (H < 12) then
  begin
    GotoXY(0, 0);
    NarrowMsg := Format('(terminal too small: %dx%d; need 60x12+)', [W, H]);
    WriteAnsiText(ConsoleTheme.Symbols, NarrowMsg);
    Exit;
  end;

  SessW := 32;
  if W div 3 < SessW then SessW := W div 3;
  if SessW < 24 then SessW := 24;
  ChatX := SessW + 1;
  ChatW := W - ChatX;
  PaneH := H - 3;   { header row + 2 footer rows }
  if PaneH < 4 then PaneH := 4;

  DrawHeaderBar(W);
  DrawSessionPane(0, 1, SessW, PaneH);

  { Vertical divider between panes. }
  for ry := 1 to PaneH do
  begin
    GotoXY(SessW, ry);
    WriteAnsiText(ConsoleTheme.Symbols, '|');
  end;

  DrawChatPane(ChatX, 1, ChatW, PaneH);
  DrawFooterBar(H - 2, W);

  { Modal overlay drawn last so it sits on top of both panes. Only one
    can be open at a time (the Open* methods enforce mutual exclusion). }
  if FMenuOpen      then DrawThemeMenu;
  if FModelMenuOpen then DrawModelMenu;
end;

procedure TTUI.DrawThemeMenu;
const
  BoxW = 32;
var
  Size: TMVCConsoleSize;
  W, H, BoxX, BoxY, i, Row, BoxH: Integer;
  Label_, Top, Bottom, Side, EmptyLine: string;
begin
  Size := GetConsoleSize;
  W := Integer(Size.Columns);
  H := Integer(Size.Rows);
  BoxH := Length(THEME_NAMES) + 4;   { title + sep + rows + footer }
  BoxX := (W - BoxW) div 2;
  BoxY := (H - BoxH) div 2;
  if BoxX < 0 then BoxX := 0;
  if BoxY < 0 then BoxY := 0;

  Top    := '+' + StringOfChar('-', BoxW - 2) + '+';
  Bottom := Top;
  Side   := '|';
  EmptyLine := '|' + StringOfChar(' ', BoxW - 2) + '|';

  GotoXY(BoxX, BoxY);
  WriteAnsiText(ConsoleTheme.HighlightText, Top);

  { Title row. }
  GotoXY(BoxX, BoxY + 1);
  Label_ := ' theme — Up/Dn  Enter to apply  Esc to cancel ';
  if Length(Label_) > BoxW - 2 then Label_ := Copy(Label_, 1, BoxW - 2);
  while Length(Label_) < BoxW - 2 do Label_ := Label_ + ' ';
  WriteAnsiText(ConsoleTheme.HighlightText, Side + Label_ + Side);

  { Separator row. }
  GotoXY(BoxX, BoxY + 2);
  WriteAnsiText(ConsoleTheme.HighlightText,
                Side + StringOfChar('-', BoxW - 2) + Side);

  for i := 0 to High(THEME_NAMES) do
  begin
    Row := BoxY + 3 + i;
    if Row >= H - 1 then Break;
    GotoXY(BoxX, Row);
    Label_ := '   ' + THEME_NAMES[i];
    while Length(Label_) < BoxW - 2 do Label_ := Label_ + ' ';
    if i = FMenuSelIdx then
      WriteAnsiText(ConsoleTheme.Highlight, Side + Label_ + Side)
    else
      WriteAnsiText(ConsoleTheme.Text, Side + Label_ + Side);
  end;

  GotoXY(BoxX, BoxY + BoxH - 1);
  WriteAnsiText(ConsoleTheme.HighlightText, Bottom);
end;

procedure TTUI.DrawModelMenu;
{ Model picker overlay. Vertical list of cached model IDs centred on
  screen; subtitle line shows cache freshness so the operator knows
  whether to drop out and run `pasclaw model refresh`. The list is
  windowed when it's longer than the visible box — Up/Dn step by one,
  so a simple "scroll when the cursor falls off the edge" suffices.
  HandleModelMenuKey's down-bound is the full roster length (not the
  visible window count) so the user can scroll into rows past the
  first page. }
const
  BoxW       = 64;
  MaxBoxRows = 20;
var
  Size: TMVCConsoleSize;
  W, H, BoxX, BoxY, BoxH, AvailRows, VisibleCount, Start, i, Row: Integer;
  Label_, Top, Bottom, Side, IdText, DispText, RowText: string;
begin
  Size := GetConsoleSize;
  W := Integer(Size.Columns);
  H := Integer(Size.Rows);

  { Frame is 5 rows (top border, title, subtitle, separator, bottom
    border) + VisibleCount data rows. Cap so BoxH fits in H. }
  AvailRows := H - 5 - 2;
  if AvailRows < 1 then AvailRows := 1;
  if AvailRows > MaxBoxRows then AvailRows := MaxBoxRows;
  VisibleCount := Length(FModelMenuModels);
  if VisibleCount > AvailRows then VisibleCount := AvailRows;
  { Window the list so the selected row stays in view. }
  Start := 0;
  if FModelMenuSelIdx >= VisibleCount then
    Start := FModelMenuSelIdx - VisibleCount + 1;
  if Start + VisibleCount > Length(FModelMenuModels) then
    Start := Length(FModelMenuModels) - VisibleCount;
  if Start < 0 then Start := 0;

  BoxH := VisibleCount + 5;
  BoxX := (W - BoxW) div 2;
  BoxY := (H - BoxH) div 2;
  if BoxX < 0 then BoxX := 0;
  if BoxY < 0 then BoxY := 0;

  Top    := '+' + StringOfChar('-', BoxW - 2) + '+';
  Bottom := Top;
  Side   := '|';

  GotoXY(BoxX, BoxY);
  WriteAnsiText(ConsoleTheme.HighlightText, Top);

  GotoXY(BoxX, BoxY + 1);
  Label_ := ' model -- Up/Dn  Enter to apply  Esc to cancel ';
  if Length(Label_) > BoxW - 2 then Label_ := Copy(Label_, 1, BoxW - 2);
  while Length(Label_) < BoxW - 2 do Label_ := Label_ + ' ';
  WriteAnsiText(ConsoleTheme.HighlightText, Side + Label_ + Side);

  GotoXY(BoxX, BoxY + 2);
  Label_ := ' ' + FModelMenuSource;
  if Length(Label_) > BoxW - 2 then Label_ := Copy(Label_, 1, BoxW - 2);
  while Length(Label_) < BoxW - 2 do Label_ := Label_ + ' ';
  WriteAnsiText(ConsoleTheme.HighlightText, Side + Label_ + Side);

  GotoXY(BoxX, BoxY + 3);
  WriteAnsiText(ConsoleTheme.HighlightText,
                Side + StringOfChar('-', BoxW - 2) + Side);

  for i := 0 to VisibleCount - 1 do
  begin
    Row := BoxY + 4 + i;
    if Row >= H - 1 then Break;
    GotoXY(BoxX, Row);

    IdText   := FModelMenuModels[Start + i].Id;
    DispText := FModelMenuModels[Start + i].Display;
    if (DispText = '') or SameText(DispText, IdText) then
      RowText := '   ' + IdText
    else
      RowText := '   ' + IdText + '   (' + DispText + ')';
    if Length(RowText) > BoxW - 2 then
      RowText := Copy(RowText, 1, BoxW - 2);
    while Length(RowText) < BoxW - 2 do RowText := RowText + ' ';

    if (Start + i) = FModelMenuSelIdx then
      WriteAnsiText(ConsoleTheme.Highlight, Side + RowText + Side)
    else
      WriteAnsiText(ConsoleTheme.Text, Side + RowText + Side);
  end;

  GotoXY(BoxX, BoxY + BoxH - 1);
  WriteAnsiText(ConsoleTheme.HighlightText, Bottom);
end;

procedure TTUI.Run;
var
  Key: Integer;
begin
  EnableUTF8Console;
  EnableANSIColorConsole;
  FCurrentTheme := CanonicalThemeName(ThemeName);
  SetConsoleTheme(ResolveTheme(FCurrentTheme));
  HideCursor;
  ClrScr;

  FFocus := foChat;
  FQuit  := False;
  FInputBuf := '';
  FChatScroll := 0;
  FConfirmDelete := False;
  FStatusFlash := '';
  FMenuOpen := False;
  FMenuSelIdx := 0;
  FModelMenuOpen := False;
  FModelMenuSelIdx := 0;
  FModelRefreshThread   := nil;
  FModelRefreshProvider := '';
  FLastResizeW := -1; FLastResizeH := -1;

  { Always allocate a session (PR #117 default-persist semantics).
    SessionId from --session is honoured: empty = fresh id; existing
    on disk = resume; missing on disk = pre-seed at that id. }
  FSession := TSession.Create(SessionId);
  RefreshSessions;

  Flash('session: ' + FSession.Meta.Id);

  try
    while not FQuit do
    begin
      PollLoopWorker;
      PollModelRefresh;

      { Periodic ListSessions refresh so cron-side / parallel-CLI
        session changes show up without keystrokes. 3s cadence. }
      if SecondsBetween(Now, FLastSessRefresh) >= 3 then
        RefreshSessions;

      Inc(FSpinnerFrame);
      DrawFrame;

      if KeyPressed then
      begin
        Key := GetKey;
        HandleKey(Key);
      end
      else
        Sleep(50);
    end;
  finally
    ShowCursor;
    ClrScr;
    ResetConsole;
  end;
end;

{ The slash-command + Help/Tools surface from the old REPL stays
  available — but it's invoked from inside the input buffer now
  (typing "/help" + Enter) so users don't have to learn a new
  dispatch model. Empty stubs here keep the FPC-shared interface
  happy without re-implementing the legacy box renderer. }

procedure TTUI.DrawHeader;     begin end;
procedure TTUI.ShowHelp;       begin end;
procedure TTUI.ShowTools;      begin end;
procedure TTUI.HandleSlashCommand(const Cmd: string); begin end;
procedure TTUI.HandleUserInput(const Text: string);   begin end;

{$ELSE}
{ ============================= FPC (line-based) ============================ }

{$IFDEF UNIX}
const
  { TIOCGWINSZ encoding differs per OS. Linux picked a low number
    in the legacy unencoded range; Darwin/BSD use the IOCTL macro
    encoding _IOR('t', 104, struct winsize) = 0x40087468. Passing
    the wrong magic to ioctl() returns -1 and we silently fall
    back to the default 80-column width — which is what was
    happening on macOS before this gate landed. }
  {$IFDEF DARWIN}
  TIOCGWINSZ = $40087468;
  {$ELSE}
  TIOCGWINSZ = $5413;
  {$ENDIF}
type
  Twinsize = record
    ws_row, ws_col, ws_xpixel, ws_ypixel: Word;
  end;
function FpIoctl(fd: Integer; req: Cardinal; argp: Pointer): Integer; cdecl;
  external 'c' name 'ioctl';
{$ENDIF}

function TermWidth: Integer;
{$IFDEF UNIX}
var
  ws: Twinsize;
{$ENDIF}
begin
  Result := 80;
  {$IFDEF UNIX}
  FillChar(ws, SizeOf(ws), 0);
  if FpIoctl(1, TIOCGWINSZ, @ws) = 0 then
    if ws.ws_col > 0 then Result := ws.ws_col;
  {$ENDIF}
end;

procedure TTUI.DrawHeader;
var
  Left, Right: string;
  Pad, W: Integer;
begin
  Left  := Ansi.BoldBlue + 'PAS' + Ansi.BoldRed + 'CLAW' + Ansi.Reset;
  Right := Ansi.Dim + StatusLine(FProvider, FModel, FRegistry) + Ansi.Reset;
  W := TermWidth;
  Pad := W - 7 - Length(StatusLine(FProvider, FModel, FRegistry));
  if Pad < 2 then Pad := 2;
  PrintLn;
  PrintLn(Left + StringOfChar(' ', Pad) + Right);
  PrintLn(Ansi.Dim + StringOfChar('-', TermWidth) + Ansi.Reset);
end;

procedure TTUI.ShowHelp;
begin
  PrintLn(Ansi.Bold + 'TUI commands:' + Ansi.Reset);
  PrintLn('  /help          show this');
  PrintLn('  /tools         list registered tools');
  PrintLn('  /clear         clear the screen');
  PrintLn('  /model         list cached models for the default provider');
  PrintLn('  /model <id>    switch the active model for this session');
  PrintLn('  /quit          exit');
end;

procedure ShowCachedModelsFPC(var FModel: string; const Arg: string);
{ Line-based equivalent of the Delphi DrawModelMenu overlay. With no
  argument: print the cached roster + the currently-selected model so
  the operator can pick one. With an `<id>` argument: switch FModel
  immediately (no validation against the cache — the user might know
  about a model the cache hasn't seen yet). Cache lookup keys on the
  operator-facing provider Name, same as the Delphi path.

  Cache miss → synchronous DiscoverModels right here. The FPC build
  is line-based (blocking ReadLn loop), so a few seconds of HTTP
  doesn't fight a render thread the way it would on the Delphi
  positioned UI; sync is the right shape for this surface. }
var
  Cfg: TConfig;
  R: TModelDiscoveryResult;
  Provider: string;
  Spec: TProviderSpec;
  Base, Key, Err: string;
  i: Integer;
  IdText, DispText: string;
begin
  if Arg <> '' then
  begin
    FModel := Arg;
    PrintLn(Ansi.Green + 'model: ' + Ansi.Reset + FModel);
    Exit;
  end;

  Cfg := LoadConfig;
  try
    Provider := Cfg.DefaultProvider;

    if Provider = '' then
    begin
      PrintLn(Ansi.Yellow + 'no provider configured -- run `pasclaw onboard` first' + Ansi.Reset);
      Exit;
    end;

    if not LoadCachedModels(Provider, R) or (Length(R.Models) = 0) then
    begin
      if not ResolveProviderSpecForName(Cfg, Provider, Spec, Base, Key, Err) then
      begin
        PrintLn(Ansi.Yellow + Err + Ansi.Reset);
        Exit;
      end;
      PrintLn(Ansi.Dim + 'fetching /models from ' + Spec.DisplayName + '...' + Ansi.Reset);
      R := DiscoverModels(Spec, Base, Key);
      if (not R.Ok) or (Length(R.Models) = 0) then
      begin
        if R.ErrMsg <> '' then
          PrintLn(Ansi.Yellow + 'refresh failed: ' + R.ErrMsg + Ansi.Reset)
        else
          PrintLn(Ansi.Yellow + 'refresh returned no models for ' + Provider + Ansi.Reset);
        Exit;
      end;
      SaveCachedModels(Provider, R);
    end;
  finally
    Cfg.Free;
  end;

  PrintLn(Ansi.Bold + Provider + Ansi.Reset + Ansi.Dim +
          ' (' + IntToStr(Length(R.Models)) + ' cached, refreshed ' +
          HumanAge(R.FetchedAt) + ')' + Ansi.Reset);
  for i := 0 to High(R.Models) do
  begin
    IdText   := R.Models[i].Id;
    DispText := R.Models[i].Display;
    if (DispText = '') or SameText(DispText, IdText) then
      PrintLn('  ' + IdText)
    else
      PrintLn('  ' + IdText + Ansi.Dim + '   (' + DispText + ')' + Ansi.Reset);
  end;
  PrintLn(Ansi.Dim + 'current: ' + FModel +
          ' -- type `/model <id>` to switch' + Ansi.Reset);
end;

procedure TTUI.ShowTools;
var
  i: Integer;
  Names: TStringArray;
begin
  if FRegistry = nil then
  begin
    PrintLn(Ansi.Dim + '(no registry)' + Ansi.Reset);
    Exit;
  end;
  Names := FRegistry.Names;
  PrintLn(Ansi.Bold + 'tools (' + IntToStr(Length(Names)) + '):' + Ansi.Reset);
  for i := 0 to High(Names) do PrintLn('  ' + Names[i]);
end;

procedure TTUI.HandleSlashCommand(const Cmd: string);
var
  Arg: string;
begin
  if (Cmd = '/quit') or (Cmd = '/exit') or (Cmd = '/q') then begin FQuit := True; Exit; end;
  if Cmd = '/clear' then begin Print(#27'[2J' + #27'[H'); DrawHeader; Exit; end;
  if Cmd = '/tools' then begin ShowTools; Exit; end;
  if Cmd = '/help'  then begin ShowHelp;  Exit; end;
  if Cmd = '/model' then begin ShowCachedModelsFPC(FModel, ''); Exit; end;
  if (Length(Cmd) > 7) and (Copy(Cmd, 1, 7) = '/model ') then
  begin
    Arg := Trim(Copy(Cmd, 8, Length(Cmd) - 7));
    ShowCachedModelsFPC(FModel, Arg);
    Exit;
  end;
  PrintLn(Ansi.Yellow + 'unknown command: ' + Cmd + Ansi.Reset);
end;

procedure TTUI.HandleUserInput(const Text: string);
var
  Msgs: array of TMessage;
  Loop: TToolLoopResult;
  Cfg: TToolLoopConfig;
  W: TRunToolLoopThread;
  TimeoutSec: Integer;
  WaitRes: TWaitResult;
begin
  if FProvider = nil then
  begin
    PrintLn(Ansi.Yellow + 'pasclaw  > ' + Ansi.Reset +
            '(offline - no provider configured)');
    Exit;
  end;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, Text);

  Cfg.Provider      := FProvider;
  Cfg.Registry      := FRegistry;
  Cfg.Model         := FModel;
  Cfg.MaxIterations := 6;
  Cfg.Parallel := True;
  Cfg.Options       := DefaultChatOptions;
  Cfg.Options.CacheEnabled := PromptCacheEnabled;
  Cfg.Options.CacheTTL     := PromptCacheTTL;
  Cfg.OnText        := nil;
  Cfg.OnToolCall    := nil;
  Cfg.OnToolResult  := nil;
  TimeoutSec        := ResolveRequestTimeoutSeconds;

  LogDebug('tool-loop start model=%s timeout=%ds', [FModel, TimeoutSec]);
  PrintLn(Ansi.Dim + '         [hint: press Ctrl+C to interrupt]' + Ansi.Reset);
  W := TRunToolLoopThread.Create(Cfg, Msgs);
  W.Start;
  WaitRes := W.DoneEvent.WaitFor(TimeoutSec * 1000);
  if WaitRes = wrTimeout then
  begin
    LogWarn('tool-loop timeout after %ds (possible slow model response or deadlocked tool call)', [TimeoutSec]);
    PrintLn(Ansi.Red + 'pasclaw  > ' + Ansi.Reset + Format('(request timed out after %ds)', [TimeoutSec]));
    W.Terminate;
    W.FreeOnTerminate := True;
    Exit;
  end;
  W.WaitFor;
  if not W.Ok then
  begin
    LogWarn('tool-loop failed: %s', [W.Err]);
    PrintLn(Ansi.Red + 'pasclaw  > ' + Ansi.Reset + '(tool loop failed)');
    W.Free;
    Exit;
  end;
  Loop := W.LoopResult;
  W.Free;
  LogDebug('tool-loop end ok iters=%d', [Loop.Iterations]);
  Print(Ansi.BoldBlue + 'pasclaw' + Ansi.Reset + '  > ');
  if Self.RenderMarkdownEnabled then
    PrintLn(RenderMarkdown(Loop.Content))
  else
    PrintLn(Loop.Content);
  if Loop.LastResp.Usage.InputTokens + Loop.LastResp.Usage.OutputTokens > 0 then
    PrintLn(Ansi.Dim + '         ' +
      Format('[tokens in=%d out=%d, iters=%d]',
        [Loop.LastResp.Usage.InputTokens, Loop.LastResp.Usage.OutputTokens, Loop.Iterations]) +
      Ansi.Reset);
end;

procedure TTUI.Run;
var
  Line: string;
begin
  Print(#27'[2J' + #27'[H');
  DrawHeader;
  PrintLn(Ansi.Dim + '/help for commands, /quit to exit' + Ansi.Reset);
  PrintLn;
  FQuit := False;
  while not FQuit do
  begin
    Print(Ansi.BoldBlue + 'you' + Ansi.Reset + '      > ');
    if EOF then Break;
    ReadLn(Line);
    Line := Trim(Line);
    if Line = '' then Continue;
    if (Line[1] = '/') then
    begin
      HandleSlashCommand(Line);
      Continue;
    end;
    HandleUserInput(Line);
  end;
  PrintLn(Ansi.Dim + 'goodbye.' + Ansi.Reset);
end;

{$ENDIF}

end.
