unit uDesktopMain;

(*
  PasClaw Desktop -- the FireMonkey client.

  Built on the RetroDesktop demo from Cross-Platform-Retro-OS-Styles:
  TRetroDesktop / TRetroWindow / TRetroTaskbar / TRetroDesktopIcon do the
  window management and take their entire appearance from the .style file in
  use, so switching styles reskins the shell, chrome included, at runtime.

  This is the twin of the browser client at <gateway>/desktop. Both drive the
  same HTTP surface through PasClaw.Client.Api, so a project built in one
  shows up in the other; both take their colors from the same generated
  palette table. What differs is only what a native shell can do better:
  real OS windows behind a real style engine, and F11 kiosk mode so the app
  can BE the desktop.

  Both halves of that are vendored so the app works from a plain checkout:
  the window manager under desktop/retro/, and the 27 styles with their
  skins under desktop/FMXStyles/Retro/. FindStyleDir still honours
  $RETRO_STYLES_DIR and a sibling checkout of the styles repo, for anyone
  developing the styles themselves.
*)

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  System.IOUtils, System.StrUtils, System.Generics.Collections,
  System.SyncObjs,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs,
  FMX.StdCtrls, FMX.Layouts, FMX.ListBox, FMX.Edit, FMX.Memo, FMX.Styles,
  FMX.Objects, FMX.TreeView, FMX.WebBrowser, FMX.ScrollBox,
  FMX.Controls.Presentation, FMX.TabControl,
  FMX.RetroWindows, FMX.RetroSkins,
  PasClaw.Client.Api,
  PasClaw.Client.Markdown;

type
  { What a tree node stands for -- the tree carries projects, their tasks and
    their jobs in one control, so each node remembers its own identity. }
  TNodeKind = (nkProject, nkTask, nkJob);

  TNodeRef = class(TObject)
    Kind: TNodeKind;
    Project: string;
    TaskId: string;
    JobId: string;
    HasApp: Boolean;
  end;

  TFormMain = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word;
      var KeyChar: WideChar; Shift: TShiftState);
  private
    FClient: TPasClawClient;
    FDesktop: TRetroDesktop;
    FTree: TTreeView;
    FStatus: TLabel;
    FNodeRefs: TObjectList<TNodeRef>;

    FStyleDir: string;
    FStyleFile: string;
    FSkinFile: string;
    FSkinFiles: TArray<string>;
    FStyleList: TListBox;
    FSkinList: TListBox;
    FFillingLists: Boolean;

    FStylePicker: TRetroWindow;
    FLibraryWin: TRetroWindow;
    FFilesWin: TRetroWindow;
    FBrowserWin: TRetroWindow;
    FProgressWin: TRetroWindow;

    { ---- the Menu ----
      A popup built as a window, because everything else here is: it wears
      the current style like the rest of the shell instead of arriving as an
      out-of-period native menu. One at a time, closed on choice. }
    FMenuWin: TRetroWindow;
    { Action per row, indexed by the Tag each row button carries. }
    FMenuActions: TStringList;

    { ---- the Projects window ----
      The tree used to be a permanent left dock with no chrome, sitting
      under the desktop icons it duplicates. It is a window now, opened from
      the Menu like everything else. }
    FTreeWin: TRetroWindow;

    { ---- Library ---- }
    FLibraryList: TListBox;
    FLibraryKinds: TStringList;   { "page:<id>" / "session:<id>", by row }

    { ---- Log ---- }
    FLogWin: TRetroWindow;
    FLogMemo: TMemo;
    FLogThread: TThread;
    FLogPending: TStringList;     { worker appends, timer drains }
    FLogLock: TCriticalSection;
    FLogStop: Boolean;
    { The segment currently being written, so a header is emitted only when
      the origin actually changes. Decided at DRAIN time, on the main
      thread: queueing happens from several threads and the order they
      interleave in is only settled once they are in the list. }
    FLogSegment: string;

    { ---- hex viewer ----
      A binary file is worth looking at; "(binary file)" is not a viewer.
      Paged over /v1/fs/peek so opening a huge one costs a window, not a
      download. }
    FHexWin: TRetroWindow;
    FHexMemo: TMemo;
    FHexPath: string;
    FHexOffset: Int64;
    FHexTotal: Int64;
    FHexPos: TLabel;
    { One chat / app / log window per project, so reopening focuses rather
      than stacking duplicates. Windows announce their own death through
      FreeNotification -- see Notification. }
    FChatWins: TDictionary<string, TRetroWindow>;
    FAppWins: TDictionary<string, TRetroWindow>;
    FChatLogs: TDictionary<string, TMemo>;
    (* The transcript as DATA, plus the browser that renders it.

       Chat used to be a TMemo, which shows markdown as its own asterisks
       and hashes and cannot do much with a code block. Turns are kept as
       role + text here and re-rendered to HTML when one completes, so the
       window shows formatted prose without the client having to lay out
       rich text itself.

       The memo stays, for streaming only: chunks arrive many times a
       second and rebuilding a document per chunk would be unusable. It is
       shown while a turn is in flight and hidden once the finished turn
       joins the transcript. *)
    FChatTurns: TObjectDictionary<string, TStringList>;
    FChatViews: TDictionary<string, TWebBrowser>;
    FChatInputs: TDictionary<string, TMemo>;
    FChatHistory: TDictionary<string, string>;
    FBrowsers: TObjectList<TWebBrowser>;
    FSnapshots: TDictionary<TWebBrowser, TImage>;

    { ---- File Manager ---- }
    FFilesList: TListBox;
    FFilesPath: TEdit;
    FFilesDir: TDirListing;

    { ---- Browser ---- }
    FBrowserQuery: TEdit;
    FBrowserView: TWebBrowser;
    FBrowserStatus: TLabel;
    FBrowserSearch, FBrowserDeep, FBrowserPromote, FBrowserNew: TButton;
    FCurrentPage: string;
    (* Tabs over ONE browser control.

       Not one control per tab: TWebBrowser is a native window that paints
       above all FMX content, which is why an inactive one has to be swapped
       for a snapshot -- multiplying that by the number of open tabs
       multiplies the trick and the ways it goes wrong. A tab is a page id;
       switching one navigates the single view.

       This is also what makes follow-up questions work. With a page in the
       current tab, asking again REVISES it; New opens an empty tab, where
       asking starts a fresh page. Two obvious gestures instead of a mode. *)
    FBrowserTabs: TTabControl;
    FBrowserTabPages: TStringList;   { page id per tab, by index }
    FBrowserSwitching: Boolean;

    { ---- deep-research progress ----
      A research turn runs for minutes across many searches. The label shows
      what the agent is doing RIGHT NOW, fed by page-progress events, because
      a dialog that says nothing for that long is indistinguishable from a
      hang. }
    FProgressText: TLabel;
    FProgressLine: string;
    { The research conversation, and the report it last produced. }
    FResearchKey: string;
    FResearchPage: string;
    FResearchRunning: Boolean;
    FResearchLastLine: string;

    { ---- process apps ----
      One Run window per project, same rule as chat and app windows. }
    FRunWins: TDictionary<string, TRetroWindow>;
    FRunLogs: TDictionary<string, TMemo>;
    FRunHeads: TDictionary<string, TLabel>;
    FRunTimer: TTimer;

    (* ---- artifact versions ----
       What each turn's app body was, newest last, per project. A card in the
       transcript is only meaningful if it can still show what THAT turn
       produced -- the app directory holds one file and every turn overwrites
       it, so if this does not capture it, nothing can. *)
    FVersions: TObjectDictionary<string, TStringList>;
    FVersionWin: TRetroWindow;
    FVersionBody: string;
    FVersionProject: string;

    FProjects: TProjectRows;
    FWorkspaces: TWorkspaceRows;
    { The live dialog, its edit, and the handler its OK button runs. Only one
      dialog of each kind is open at a time, so fields are enough. }
    FDialogWin: TRetroWindow;
    FDialogEdit: TEdit;
    FDialogAccept: TNotifyEvent;
    FPendingProject: string;

    { The live wizard: its steps, where we are, and the project whose board
      Finish will add tasks to. }
    FWizWin: TRetroWindow;
    FWizSteps: TUISteps;
    FWizIndex: Integer;
    FWizProject: string;
    FWizTitle: string;
    FWizPage: TLayout;
    FWizBack, FWizNext: TButton;

    { Events arrive on a worker thread; the UI is touched only from the main
      one. The worker sets a flag, a timer drains it. }
    FEventThread: TThread;
    FEventDirty: Boolean;
    FEventTimer: TTimer;
    FLayoutDirty: Boolean;
    { Set the moment teardown begins. Notification and the timers consult it
      so nothing touches state that FormDestroy has already released. }
    FClosing: Boolean;
    { True once RestoreDesktopState has opened at least one window, so a
      first run can tell "nothing was saved" from "the user closed it all". }
    FRestoredAnything: Boolean;
    { True while RestoreDesktopState is opening windows, so restoring does
      not immediately save a half-built layout back over the real one. }
    FRestoring: Boolean;

    function FindStyleDir: string;
    procedure BuildDesktop;
    procedure BuildStylePicker;
    procedure RefreshWorkspaces;
    procedure RefreshProjects;
    procedure RebuildTree;

    procedure MenuClick(Sender: TObject);
    procedure NewProjectClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure NextWorkspaceClick(Sender: TObject);
    procedure NextDesktopClick(Sender: TObject);
    procedure TreeDblClick(Sender: TObject);
    procedure IconOpen(Sender: TObject);
    procedure StyleChange(Sender: TObject);
    procedure SkinChange(Sender: TObject);
    procedure ApplyCurrentStyle;
    procedure FillSkinList;
    procedure BrowserActiveChanged(Sender: TObject);

    { Period-correct dialogs rather than InputQuery / MessageDlg: they are
      TRetroWindows, so they wear the current style like everything else --
      and the agent's own questions can use the same furniture (the plan's
      "speaks through dialog boxes" idea). Non-modal, so each carries what to
      do on OK. }
    function AskText(const ACaption, APrompt, ADefault: string;
      AOnAccept: TNotifyEvent): TRetroWindow;
    function Confirm(const ACaption, AMessage: string;
      AOnYes: TNotifyEvent): TRetroWindow;
    procedure DialogOK(Sender: TObject);
    procedure DialogCancel(Sender: TObject);
    procedure NewProjectAccepted(Sender: TObject);
    procedure OpenAppConfirmed(Sender: TObject);
    procedure LibraryClick(Sender: TObject);

    procedure OpenChat(const Project: string);
    procedure OpenApp(const Project: string);
    procedure OpenJobLog(const Project, TaskId, JobId: string);
    procedure OpenLibrary;
    procedure LibraryDblClick(Sender: TObject);
    procedure OpenSessionChat(const SessionId: string);

    { ---- the Menu ---- }
    (* Built fresh on every open rather than once at startup: half of it is
       the live project list, with each project's apps under it, and a menu
       that showed yesterday's projects would be worse than no menu. *)
    procedure BuildMenu;
    procedure MenuPick(Sender: TObject);
    procedure CloseMenu;
    procedure OpenTree;
    procedure OpenPlainChat;
    procedure PickWorkspaceClick(Sender: TObject);
    procedure NewWorkspaceClick(Sender: TObject);
    procedure NewWorkspaceAccepted(Sender: TObject);
    procedure PickWorkspaceAccepted(Sender: TObject);
    procedure OpenDisplayProperties;

    { ---- Log ---- }
    procedure OpenLog;
    procedure LogLine(const Level, Text_: string; var Stop: Boolean);
    procedure ClientTrace(const Origin, Method, Path: string;
      Status, Millis: Integer; const Note: string);
    procedure QueueLogEntry(const Kind, Origin, Text_: string);
    procedure DrainLogLines;
    procedure StopLogWatch;

    { ---- hex viewer ---- }
    procedure OpenHex(const Path: string);
    procedure HexRender;
    procedure HexPrevClick(Sender: TObject);
    procedure HexNextClick(Sender: TObject);

    { ---- File Manager ---- }
    procedure OpenFiles;
    procedure FilesShow(const Path: string);
    procedure FilesOpenSel(Sender: TObject);
    procedure FilesUpClick(Sender: TObject);
    procedure FilesHomeClick(Sender: TObject);
    procedure FilesPathKey(Sender: TObject; var Key: Word;
      var KeyChar: WideChar; Shift: TShiftState);
    procedure OpenFileView(const Path, Name: string);

    { ---- Browser ---- }
    procedure OpenBrowser(const PageId: string);
    procedure BrowserNewTabClick(Sender: TObject);
    procedure ShowBlankTab;
    procedure BrowserTabChange(Sender: TObject);
    function NewBrowserTab(const Caption: string): Integer;
    procedure BrowserSearchClick(Sender: TObject);
    procedure BrowserDeepClick(Sender: TObject);
    procedure StartResearch(const Query, RevisePageId: string);
    procedure BrowserPromoteClick(Sender: TObject);
    procedure RunPageQuery(Kind: TPageKindSel);
    procedure ShowPage(const PageId: string);
    procedure ShowPageInTab(const PageId: string; TabIndex: Integer);
    procedure ShowProgress(const Caption, Text_: string);
    procedure CloseProgress;

    { ---- process apps ---- }
    procedure OpenRun(const Project: string);
    procedure RunStartClick(Sender: TObject);
    procedure RunStopClick(Sender: TObject);
    procedure RunConfirmed(Sender: TObject);
    procedure RunTimerTick(Sender: TObject);
    procedure RefreshRun(const Project: string);

    { ---- artifact versions ---- }
    procedure CaptureVersion(const Project: string);
    procedure AddArtifactCard(const Project: string);
    procedure ViewVersionClick(Sender: TObject);
    procedure RestoreVersionClick(Sender: TObject);
    procedure RestoreConfirmed(Sender: TObject);

    { ---- desktop state ---- }
    procedure SaveDesktopState;
    procedure SaveDesktopStateTo(Desk: Integer);
    procedure RestoreDesktopState;
    procedure CloseAllWindows;
    { Mark the layout changed; the event timer flushes it. Saving inline on
      every open and close would put a blocking PUT in the middle of opening
      a window. }
    procedure MarkLayoutDirty;

    procedure FilesClick(Sender: TObject);
    procedure BrowserClick(Sender: TObject);
    procedure SendChat(Sender: TObject);
    procedure ChatChunk(const Chunk: string; var Abort: Boolean);
    procedure ChatTool(const Kind, Name, Detail: string; IsErr: Boolean);
    { ---- transcript rendering ---- }
    function StyleColor(const Role, Fallback: string): string;
    procedure AppendTurn(const Project, Role, Text_: string);
    procedure RenderTranscript(const Project: string);
    procedure ShowStreaming(const Project: string; Streaming: Boolean);

    { Live board updates. The client subscribes to /v1/desktop/events on its
      own thread and refreshes when something it displays changes, so the
      tree moves while the agent works instead of waiting for a click. }
    procedure StartEventWatch;
    procedure OnDesktopEvent(const Ev: TDesktopEvent; var Stop: Boolean);
    procedure ApplyPendingEvents;
    procedure EventTimerTick(Sender: TObject);

    { Period-native output, same convention as the web client -- the parsing
      is shared (PasClaw.Client.Api.ParseUIBlocks), only the rendering is
      FireMonkey. }
    procedure RenderUIBlocks(const Project: string; const Blocks: TUIBlocks);
    procedure ShowWizard(const Project: string; const Block: TUIBlock);
    procedure ShowAsk(const Project: string; const Block: TUIBlock);
    procedure WizardBack(Sender: TObject);
    procedure WizardNext(Sender: TObject);
    procedure AskButtonClick(Sender: TObject);
    procedure PaintWizard;

    procedure Say(const Msg: string);
    function TrackWindow(AWindow: TRetroWindow): TRetroWindow;
    function ProjectByName(const Name: string; out Row: TProjectRow): Boolean;
  protected
    procedure Notification(AComponent: TComponent;
      Operation: TOperation); override;
  end;

var
  FormMain: TFormMain;

implementation

{$R *.fmx}

type
  (* FMX.Objects declares a TPath too -- the vector shape control -- and it
     comes after System.IOUtils in this unit's uses clause, so a bare TPath
     resolves to the shape, and Combine on it is "undeclared identifier".
     Alias the one we mean rather than depending on uses-clause order, which
     is the kind of thing a later edit silently breaks. *)
  TIOPath = System.IOUtils.TPath;

const
  NoSkin = '(style default)';
  DefaultGateway = 'http://127.0.0.1:8088';
  { The key the project-less chat window is filed under. A colon cannot
    appear in a project slug, so this can never collide with a real one. }
  PlainChatKey = ':chat';
  { A conversation reopened from the Library, filed under its session id.
    Same reserved-colon rule as above. }
  SessionChatPrefix = ':session:';
  { The research conversation. Reserved-colon like the others, so it can
    never collide with a project slug. }
  ResearchChatKey = ':research';
  { One menu row: tall enough to hit with a mouse, short enough that the
    whole launcher fits without scrolling on an ordinary board. }
  MenuRowHeight = 22;
  { Marks a chat transcript that is hidden because its turn is streaming. }
  StreamingTag = 'streaming';

{ Conditional string. StrUtils has one; a local helper keeps this unit's
  uses clause to what it actually needs. Declared here, above every caller,
  because Pascal resolves top-down. }
function IfThenStr(Cond: Boolean; const Yes, No: string): string;
begin
  if Cond then Result := Yes else Result := No;
end;

{ True for the synthetic chat keys -- the project-less window and any
  reopened Library session. A project slug can never start with a colon, so
  this cannot swallow a real project. }
function IsSyntheticChat(const Key: string): Boolean;
begin
  Result := (Key = '') or ((Length(Key) > 0) and (Key[1] = ':'));
end;


{ The chat window whose stream is currently being pumped. Set around the
  blocking Chat call so ChatChunk knows where to append. }
var
  GStreamingLog: TMemo = nil;
  { Which conversation the streaming turn belongs to, so tool lines can join
    its transcript as well as its live view. }
  GStreamingProject: string = '';

{ ------------------------------------------------------------- lifecycle -- }

function TFormMain.FindStyleDir: string;
var
  Dir, Env: string;
  I: Integer;
begin
  { An explicit override wins -- a developer with the styles repo somewhere
    unusual shouldn't have to move it. }
  Env := GetEnvironmentVariable('RETRO_STYLES_DIR');
  if (Env <> '') and TDirectory.Exists(Env) then
    Exit(Env);

  { Otherwise walk up from the exe. The styles ship in desktop\FMXStyles\
    Retro, which this finds three levels up from the default
    desktop\<Platform>\<Config>\ output directory; the second form still
    picks up a sibling checkout of the styles repo, the way the RetroDesktop
    demo does, so a developer working from that checkout is unaffected. }
  Dir := ExtractFilePath(ParamStr(0));
  for I := 1 to 7 do
  begin
    if TDirectory.Exists(TIOPath.Combine(Dir, 'FMXStyles' + PathDelim + 'Retro')) then
      Exit(TIOPath.Combine(Dir, 'FMXStyles' + PathDelim + 'Retro'));
    if TDirectory.Exists(TIOPath.Combine(Dir,
         'Cross-Platform-Retro-OS-Styles' + PathDelim + 'FMXStyles' +
         PathDelim + 'Retro')) then
      Exit(TIOPath.Combine(Dir, 'Cross-Platform-Retro-OS-Styles' + PathDelim +
         'FMXStyles' + PathDelim + 'Retro'));
    Dir := ExtractFilePath(ExcludeTrailingPathDelimiter(Dir));
    if Dir = '' then Break;
  end;
  Result := '';
end;

procedure TFormMain.FormCreate(Sender: TObject);
var
  Gateway, Win95, Ver: string;
begin
  Caption := 'PasClaw Desktop';

  FNodeRefs   := TObjectList<TNodeRef>.Create(True);
  FChatWins   := TDictionary<string, TRetroWindow>.Create;
  FAppWins    := TDictionary<string, TRetroWindow>.Create;
  FChatLogs   := TDictionary<string, TMemo>.Create;
  FChatTurns  := TObjectDictionary<string, TStringList>.Create([doOwnsValues]);
  FChatViews  := TDictionary<string, TWebBrowser>.Create;
  FChatInputs := TDictionary<string, TMemo>.Create;
  FChatHistory := TDictionary<string, string>.Create;
  FBrowsers   := TObjectList<TWebBrowser>.Create(False);
  FSnapshots  := TDictionary<TWebBrowser, TImage>.Create;
  FRunWins    := TDictionary<string, TRetroWindow>.Create;
  FRunLogs    := TDictionary<string, TMemo>.Create;
  FRunHeads   := TDictionary<string, TLabel>.Create;
  { Owns its lists: each holds one project's captured app bodies. }
  FVersions   := TObjectDictionary<string, TStringList>.Create([doOwnsValues]);

  { One poll for every Run window. A child's output arrives when it arrives,
    and N timers would be N of the same question. Off until something runs. }
  FRunTimer := TTimer.Create(Self);
  FRunTimer.Interval := 1200;
  FRunTimer.Enabled := False;
  FRunTimer.OnTimer := RunTimerTick;

  Gateway := GetEnvironmentVariable('PASCLAW_GATEWAY');
  if Gateway = '' then Gateway := DefaultGateway;
  FClient := TPasClawClient.Create(Gateway);
  FClient.Token := GetEnvironmentVariable('PASCLAW_TOKEN');
  { Always on. Tracing you have to enable is tracing you do not have when
    the thing you wanted to see already happened; the Log window is where
    it surfaces, and nothing accumulates while that window is closed. }
  FClient.OnTrace := ClientTrace;

  FStyleDir := FindStyleDir;
  BuildDesktop;
  BuildStylePicker;

  if FStyleDir <> '' then
  begin
    Win95 := TIOPath.Combine(FStyleDir, 'Win95.style');
    if TFile.Exists(Win95) then
    begin
      FStyleFile := Win95;
      FillSkinList;
      TStyleManager.SetStyleFromFile(Win95);
    end;
  end;

  if not FClient.Ping(Ver) then
  begin
    Say('No gateway at ' + Gateway + '. Start one with: pasclaw gateway');
    Exit;
  end;
  Say('Connected to PasClaw ' + Ver + ' at ' + Gateway);
  RefreshWorkspaces;
  RefreshProjects;
  StartEventWatch;
  { The layout this workspace was left in, from whichever client left it. }
  RestoreDesktopState;
  (* A first run has no saved layout and would otherwise open to bare
     wallpaper with no way in that is not the Menu. Give it the project
     window; anyone who closes it has said what they want and gets an empty
     desktop from then on.

     Asked as "did the restore open anything", not "are there no windows":
     BuildStylePicker has already created the (hidden) Display Properties
     window by this point, so a window count is never zero and the test
     would never fire. *)
  if not FRestoredAnything then
    OpenTree;
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  (* Order matters here, and getting it wrong is an access violation on
     close rather than anything subtle.

     1. Say we are closing, so Notification stops doing bookkeeping against
        fields that are about to be freed -- it fires once per owned
        component as the form comes apart, which is after this runs.
     2. Stop the timers, or a tick lands mid-teardown and repaints windows
        that are going away.
     3. Stop the watcher threads, which read through the client.
     4. Save, while the client still exists -- the layout lives on the
        gateway, so there is no writing it afterwards.
     5. Only then free anything. *)
  FClosing := True;

  if FEventTimer <> nil then FEventTimer.Enabled := False;
  if FRunTimer <> nil then FRunTimer.Enabled := False;

  { Stop the watchers before the client they read through goes away. }
  if FEventThread <> nil then
  begin
    FEventThread.Terminate;
    FEventThread.WaitFor;
    FreeAndNil(FEventThread);
  end;
  StopLogWatch;
  { Save before the client goes: the layout is stored on the gateway, so
    there is no writing it once the connection is gone. }
  try
    SaveDesktopState;
  except
    { A desktop that cannot record its layout still closes. }
  end;
  FreeAndNil(FClient);
  FreeAndNil(FVersions);
  FreeAndNil(FRunHeads);
  FreeAndNil(FRunLogs);
  FreeAndNil(FRunWins);
  FreeAndNil(FSnapshots);
  FreeAndNil(FBrowsers);
  FreeAndNil(FChatHistory);
  FreeAndNil(FChatInputs);
  FreeAndNil(FChatViews);
  FreeAndNil(FChatTurns);
  FreeAndNil(FChatLogs);
  FreeAndNil(FAppWins);
  FreeAndNil(FChatWins);
  FreeAndNil(FNodeRefs);
  FreeAndNil(FLogPending);
  FreeAndNil(FLogLock);
  FreeAndNil(FMenuActions);
  FreeAndNil(FLibraryKinds);
  FreeAndNil(FBrowserTabPages);
end;

procedure TFormMain.FormKeyDown(Sender: TObject; var Key: Word;
  var KeyChar: WideChar; Shift: TShiftState);
begin
  { F11 = the whole point of the native client: the app becomes the desktop. }
  if Key = vkF11 then
    FullScreen := not FullScreen
  else if (Key = vkRight) and (ssCtrl in Shift) and (ssAlt in Shift) then
    NextWorkspaceClick(nil);
end;

{ Closing a window frees it, which would leave every field and dictionary
  entry here dangling. FreeNotification is the standard answer and survives
  RemoveWindow detaching ownership -- the window tells us as it dies. }
function TFormMain.TrackWindow(AWindow: TRetroWindow): TRetroWindow;
begin
  Result := AWindow;
  if AWindow <> nil then
    AWindow.FreeNotification(Self);
end;

procedure TFormMain.Notification(AComponent: TComponent;
  Operation: TOperation);
var
  Key: string;
  Keys: TArray<string>;
  I: Integer;
begin
  inherited;
  if Operation <> TOperation.opRemove then Exit;

  (* Teardown.

     This fires for every component the form owns as the form is destroyed
     -- which happens AFTER FormDestroy has freed the dictionaries below.
     Reading them then dereferences nil, and closing the app raised an
     access violation every time. FormDestroy sets FClosing before it frees
     anything, so from that point the bookkeeping here is not merely
     unnecessary but wrong: everything it would tidy up is already gone. *)
  if FClosing then Exit;

  { A window closing is a layout change like any other. }
  if AComponent is TRetroWindow then MarkLayoutDirty;

  if AComponent = FStylePicker then
  begin
    FStylePicker := nil;
    FStyleList := nil;    { owned by the picker, dying with it }
    FSkinList := nil;
    Exit;
  end;

  if AComponent = FMenuWin then
  begin
    FMenuWin := nil;
    Exit;
  end;

  if AComponent = FTreeWin then
  begin
    FTreeWin := nil;
    FTree := nil;         { owned by the window }
    FStatus := nil;
    Exit;
  end;

  if AComponent = FLogWin then
  begin
    FLogWin := nil;
    FLogMemo := nil;
    { Closing the window ends the subscription: an unread tail is a
      connection the gateway holds open for nobody. }
    StopLogWatch;
    Exit;
  end;

  if AComponent = FHexWin then
  begin
    FHexWin := nil;
    FHexMemo := nil;
    FHexPos := nil;
    Exit;
  end;
  if AComponent = FLibraryWin then
  begin
    FLibraryWin := nil;
    Exit;
  end;
  if AComponent = FFilesWin then
  begin
    FFilesWin := nil;
    FFilesList := nil;    { owned by the window, dying with it }
    FFilesPath := nil;
    Exit;
  end;
  if AComponent = FBrowserWin then
  begin
    FBrowserWin := nil;
    FBrowserQuery := nil;
    FBrowserStatus := nil;
    FBrowserSearch := nil;
    FBrowserDeep := nil;
    FBrowserPromote := nil;
    { The view is also in FBrowsers/FSnapshots; the loop below clears those. }
    FBrowserView := nil;
    FBrowserNew := nil;
    FBrowserTabs := nil;
    if FBrowserTabPages <> nil then FBrowserTabPages.Clear;
    FCurrentPage := '';
    Exit;
  end;
  if AComponent = FProgressWin then
  begin
    FProgressWin := nil;
    FProgressText := nil;
    Exit;
  end;
  if AComponent = FVersionWin then
  begin
    FVersionWin := nil;
    Exit;
  end;

  { Streamed before FormCreate ran, so nothing below exists yet. They are
    all constructed together, so one check covers the three loops. }
  if FRunWins = nil then Exit;

  Keys := FRunWins.Keys.ToArray;
  for I := 0 to High(Keys) do
  begin
    Key := Keys[I];
    if FRunWins[Key] = AComponent then
    begin
      FRunWins.Remove(Key);
      FRunLogs.Remove(Key);       { memo and label were owned by the window }
      FRunHeads.Remove(Key);
    end;
  end;

  Keys := FChatWins.Keys.ToArray;
  for I := 0 to High(Keys) do
  begin
    Key := Keys[I];
    if FChatWins[Key] = AComponent then
    begin
      FChatWins.Remove(Key);
      FChatLogs.Remove(Key);      { memos were owned by the window }
      FChatViews.Remove(Key);
      FChatTurns.Remove(Key);
      FChatInputs.Remove(Key);
    end;
  end;

  Keys := FAppWins.Keys.ToArray;
  for I := 0 to High(Keys) do
  begin
    Key := Keys[I];
    if FAppWins[Key] = AComponent then
      FAppWins.Remove(Key);
  end;
end;

procedure TFormMain.Say(const Msg: string);
begin
  if FStatus <> nil then
    FStatus.Text := Msg;
end;

{ ----------------------------------------------------------------- shell -- }

procedure TFormMain.BuildDesktop;
begin
  FDesktop := TRetroDesktop.Create(Self);
  FDesktop.Parent := Self;
  FDesktop.CreateTaskbar;
  FDesktop.Taskbar.MenuButton.OnClick := MenuClick;
  { Menu-bar styles (GEM, Mac OS 9, Apple System) show titles instead of a
    launcher button; the bar hides these under every other kind. }
  FDesktop.Taskbar.AddMenuTitle('PasClaw').OnClick := MenuClick;
  FDesktop.Taskbar.AddMenuTitle('Project').OnClick := NewProjectClick;
  FDesktop.Taskbar.AddMenuTitle('View').OnClick := RefreshClick;
end;

(* The Projects window.

   This was a permanent left dock: a bare TLayout with no chrome, pinned to
   the edge, sitting on top of the desktop icons that name the same
   projects. Two lists of one thing, one of them unmovable and neither of
   them looking like part of the shell.

   It is a window now, opened from the Menu like Files or Library, so it can
   be moved, sized, closed and restored -- and the icons have the desktop to
   themselves. The status line moved into it; a shell with nowhere to speak
   would have to fall back on message boxes. *)
procedure TFormMain.OpenTree;
var
  Bar: TLayout;
  B: TButton;
begin
  if FTreeWin <> nil then
  begin
    FTreeWin.Restore;
    Exit;
  end;
  FTreeWin := TrackWindow(FDesktop.CreateWindow('Projects', 260, 420));
  MarkLayoutDirty;

  Bar := TLayout.Create(FTreeWin);
  Bar.Parent := FTreeWin.Client;
  Bar.Align := TAlignLayout.Bottom;
  Bar.Height := 30;

  B := TButton.Create(FTreeWin);
  B.Parent := Bar;
  B.Align := TAlignLayout.Left;
  B.Width := 108;
  B.Text := 'New Project';
  B.OnClick := NewProjectClick;

  B := TButton.Create(FTreeWin);
  B.Parent := Bar;
  B.Align := TAlignLayout.Client;
  B.Margins.Left := 4;
  B.Text := 'Refresh';
  B.OnClick := RefreshClick;

  FStatus := TLabel.Create(FTreeWin);
  FStatus.Parent := FTreeWin.Client;
  FStatus.Align := TAlignLayout.Bottom;
  FStatus.Height := 32;
  FStatus.Margins.Bottom := 2;
  FStatus.WordWrap := True;
  FStatus.Text := '';

  FTree := TTreeView.Create(FTreeWin);
  FTree.Parent := FTreeWin.Client;
  FTree.Align := TAlignLayout.Client;
  FTree.OnDblClick := TreeDblClick;

  RebuildTree;
end;
procedure TFormMain.RefreshWorkspaces;
var
  I: Integer;
begin
  try
    FWorkspaces := FClient.Workspaces;
  except
    on E: Exception do
    begin
      Say('Could not list workspaces: ' + E.Message);
      Exit;
    end;
  end;
  for I := 0 to High(FWorkspaces) do
    if FWorkspaces[I].Active then
      Caption := 'PasClaw Desktop -- ' + FWorkspaces[I].Label_;
end;

procedure TFormMain.RefreshProjects;
var
  I: Integer;
  Icon: TRetroDesktopIcon;
begin
  SetClientContext('Board');
  try
    FProjects := FClient.Projects;
  except
    on E: Exception do
    begin
      Say('Could not list projects: ' + E.Message);
      Exit;
    end;
  end;
  RebuildTree;

  { Desktop icons, one per project. Rebuilt wholesale: the set is small and
    a diff would be more code than it saves. }
  for I := FDesktop.ChildrenCount - 1 downto 0 do
    if FDesktop.Children[I] is TRetroDesktopIcon then
      TRetroDesktopIcon(FDesktop.Children[I]).Free;

  for I := 0 to High(FProjects) do
  begin
    Icon := FDesktop.CreateIcon(FProjects[I].Title);
    Icon.Tag := I;
    Icon.OnOpen := IconOpen;
    (* Behind the windows.

       FMX z-order is creation order, and this list is rebuilt every time
       the board changes -- so icons made after a window exists land on top
       of it, which is how they ended up painted over Display Properties at
       startup. The window manager already assumes icons sit below every
       window: its cycle-windows code refuses SendToBack for exactly this
       reason, since that would drop the window behind them. This keeps the
       assumption true after a refresh. *)
    Icon.SendToBack;
  end;
  FDesktop.ArrangeIcons;
  Say(Format('%d project(s)', [Length(FProjects)]));
end;

procedure TFormMain.RebuildTree;
var
  I, J, K: Integer;
  PNode, TNode, JNode: TTreeViewItem;
  Tasks: TTaskRows;
  Jobs: TJobRows;
  Ref: TNodeRef;

  function NewRef(AKind: TNodeKind; const P, T, Jb: string;
    AHasApp: Boolean): TNodeRef;
  begin
    Result := TNodeRef.Create;
    Result.Kind := AKind;
    Result.Project := P;
    Result.TaskId := T;
    Result.JobId := Jb;
    Result.HasApp := AHasApp;
    FNodeRefs.Add(Result);
  end;

begin
  { The tree lives in a window that can be closed. Nothing else here needs
    it to exist, so a closed Projects window means there is simply nothing
    to rebuild -- not a reason for the board refresh to fault. }
  if FTree = nil then Exit;
  FTree.Clear;
  FNodeRefs.Clear;   { owns the refs; clearing frees the previous generation }

  for I := 0 to High(FProjects) do
  begin
    PNode := TTreeViewItem.Create(FTree);
    PNode.Parent := FTree;
    PNode.Text := FProjects[I].Title;
    if FProjects[I].OpenTasks > 0 then
      PNode.Text := PNode.Text + '  (' + IntToStr(FProjects[I].OpenTasks) + ')';
    Ref := NewRef(nkProject, FProjects[I].Name, '', '',
                  FProjects[I].HasApp and FProjects[I].AppReady);
    PNode.TagObject := Ref;

    Tasks := nil;
    try
      Tasks := FClient.Tasks(FProjects[I].Name);
    except
      { a project whose tasks fail to load still belongs in the tree }
    end;

    for J := 0 to High(Tasks) do
    begin
      TNode := TTreeViewItem.Create(FTree);
      TNode.Parent := PNode;
      TNode.Text := Tasks[J].Id + '  [' + Tasks[J].Status + ']  ' + Tasks[J].Title;
      TNode.TagObject := NewRef(nkTask, FProjects[I].Name, Tasks[J].Id, '', False);

      if Tasks[J].Jobs = 0 then Continue;
      Jobs := nil;
      try
        Jobs := FClient.Jobs(FProjects[I].Name, Tasks[J].Id);
      except
      end;
      for K := 0 to High(Jobs) do
      begin
        JNode := TTreeViewItem.Create(FTree);
        JNode.Parent := TNode;
        JNode.Text := Jobs[K].Id + '  ' + Jobs[K].Status;
        if Jobs[K].Summary <> '' then
          JNode.Text := JNode.Text + '  -- ' + Jobs[K].Summary;
        JNode.TagObject := NewRef(nkJob, FProjects[I].Name, Tasks[J].Id,
                                  Jobs[K].Id, False);
      end;
    end;
    PNode.IsExpanded := Length(Tasks) > 0;
  end;
end;

function TFormMain.ProjectByName(const Name: string;
  out Row: TProjectRow): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FProjects) do
    if FProjects[I].Name = Name then
    begin
      Row := FProjects[I];
      Exit(True);
    end;
  Result := False;
end;

{ --------------------------------------------------------------- dialogs -- }

procedure TFormMain.DialogCancel(Sender: TObject);
begin
  if FDialogWin <> nil then
    FDialogWin.Close;
  FDialogWin := nil;
  FDialogEdit := nil;
  FDialogAccept := nil;
end;

procedure TFormMain.DialogOK(Sender: TObject);
var
  Handler: TNotifyEvent;
  Win: TRetroWindow;
begin
  { Take a copy of the handler and the window first: running the handler may
    open the NEXT dialog, which overwrites both fields. }
  Handler := FDialogAccept;
  Win := FDialogWin;
  FDialogAccept := nil;
  if Assigned(Handler) then
    Handler(Sender);
  if Win <> nil then
    Win.Close;
  if FDialogWin = Win then
  begin
    FDialogWin := nil;
    FDialogEdit := nil;
  end;
end;

function TFormMain.AskText(const ACaption, APrompt, ADefault: string;
  AOnAccept: TNotifyEvent): TRetroWindow;
var
  W: TRetroWindow;
  L: TLabel;
  E: TEdit;
  Row: TLayout;
  B: TButton;
begin
  W := TrackWindow(FDesktop.CreateWindow(ACaption, 340, 150));
  W.ShowMax := False;
  W.ShowMin := False;
  W.Sizeable := False;
  FDialogWin := W;

  Row := TLayout.Create(W);
  Row.Parent := W.Client;
  Row.Align := TAlignLayout.Bottom;
  Row.Height := 34;

  B := TButton.Create(W);
  B.Parent := Row;
  B.Align := TAlignLayout.Right;
  B.Width := 80;
  B.Margins.Rect := TRectF.Create(4, 4, 8, 4);
  B.Text := 'Cancel';
  B.OnClick := DialogCancel;

  B := TButton.Create(W);
  B.Parent := Row;
  B.Align := TAlignLayout.Right;
  B.Width := 80;
  B.Margins.Rect := TRectF.Create(4, 4, 0, 4);
  B.Text := 'OK';
  B.Default := True;
  B.OnClick := DialogOK;

  L := TLabel.Create(W);
  L.Parent := W.Client;
  L.Align := TAlignLayout.Top;
  L.Height := 26;
  L.Margins.Rect := TRectF.Create(8, 8, 8, 0);
  L.Text := APrompt;
  L.WordWrap := True;

  E := TEdit.Create(W);
  E.Parent := W.Client;
  E.Align := TAlignLayout.Top;
  E.Margins.Rect := TRectF.Create(8, 6, 8, 0);
  E.Text := ADefault;
  FDialogEdit := E;

  FDialogAccept := AOnAccept;
  Result := W;
end;

function TFormMain.Confirm(const ACaption, AMessage: string;
  AOnYes: TNotifyEvent): TRetroWindow;
var
  W: TRetroWindow;
  L: TLabel;
  Row: TLayout;
  B: TButton;
begin
  W := TrackWindow(FDesktop.CreateWindow(ACaption, 380, 170));
  W.ShowMax := False;
  W.ShowMin := False;
  W.Sizeable := False;
  FDialogWin := W;

  Row := TLayout.Create(W);
  Row.Parent := W.Client;
  Row.Align := TAlignLayout.Bottom;
  Row.Height := 34;

  B := TButton.Create(W);
  B.Parent := Row;
  B.Align := TAlignLayout.Right;
  B.Width := 80;
  B.Margins.Rect := TRectF.Create(4, 4, 8, 4);
  B.Text := 'No';
  B.OnClick := DialogCancel;

  B := TButton.Create(W);
  B.Parent := Row;
  B.Align := TAlignLayout.Right;
  B.Width := 80;
  B.Margins.Rect := TRectF.Create(4, 4, 0, 4);
  B.Text := 'Yes';
  B.Default := True;
  B.OnClick := DialogOK;

  L := TLabel.Create(W);
  L.Parent := W.Client;
  L.Align := TAlignLayout.Client;
  L.Margins.Rect := TRectF.Create(10, 10, 10, 4);
  L.Text := AMessage;
  L.WordWrap := True;

  FDialogAccept := AOnYes;
  Result := W;
end;

procedure TFormMain.LibraryClick(Sender: TObject);
begin
  OpenLibrary;
end;

{ --------------------------------------------------------------- commands -- }

(* The Menu.

   A list in a small window rather than a native TPopupMenu: a native one
   arrives in the host OS's own chrome, which on a shell whose entire point
   is wearing a 1995 face is the one wrong-looking thing on screen. This is
   a TRetroWindow like every other, so it is skinned by the same .style.

   Rebuilt on every open because the bottom half is live: every project, and
   under each one its app. That is also the answer to "I built three apps
   and cannot find them" -- Notes, Calendar and the rest are ordinary
   projects with ordinary apps, and this is where you reach them without
   knowing that. *)
procedure TFormMain.MenuClick(Sender: TObject);
begin
  if FMenuWin <> nil then
  begin
    CloseMenu;      { second click on Menu closes it, as a Start button does }
    Exit;
  end;
  BuildMenu;
end;

procedure TFormMain.CloseMenu;
begin
  if FMenuWin <> nil then
  begin
    FMenuWin.Close;
    FMenuWin := nil;
  end;
end;

(* Build the Menu.

   Rows are BUTTONS in a scrolled layout, not a TListBox. A list box tracks
   a selection -- it highlights what you clicked and keeps highlighting it,
   with no notion of what the pointer is over -- so the menu had no hover
   focus, which is most of what makes a launcher feel like one. Buttons get
   rollover from the style engine, and every .style in the set paints its
   own period-correct hover, so this follows the skin instead of inventing
   a highlight colour that would be wrong in 26 looks out of 27.

   Rebuilt on every open because the bottom half is live: every project and
   its app. A menu showing yesterday's projects is worse than none. *)
procedure TFormMain.BuildMenu;
var
  I, H: Integer;
  Apps: TAppRow;
  Row: TProjectRow;
  Box: TVertScrollBox;
  Content: TLayout;
  Y: Single;

  procedure Item(const Caption, Action: string; Indent: Boolean);
  var
    B: TButton;
    L: Single;
  begin
    if Indent then L := 18 else L := 2;
    B := TButton.Create(FMenuWin);
    B.Parent := Content;
    B.Position.Point := PointF(L, Y);
    B.Width := 230 - L;
    B.Height := MenuRowHeight;
    B.Text := Caption;
    { Left-aligned like a menu, not centred like a dialog button. }
    B.StyledSettings := B.StyledSettings - [TStyledSetting.Other];
    B.TextSettings.HorzAlign := TTextAlign.Leading;
    { The row carries its own index, so there is no selection to consult
      and nothing to go stale if the menu is rebuilt underneath it. }
    B.Tag := FMenuActions.Count;
    B.OnClick := MenuPick;
    FMenuActions.Add(Action);
    Y := Y + MenuRowHeight + 1;
  end;

  procedure Sep;
  var
    Ln: TLine;
  begin
    Ln := TLine.Create(FMenuWin);
    Ln.Parent := Content;
    Ln.LineType := TLineType.Top;
    Ln.Position.Point := PointF(6, Y + 3);
    Ln.Width := 222;
    Ln.Height := 2;
    Y := Y + 9;
  end;

begin
  SetClientContext('Menu');
  if FMenuActions = nil then FMenuActions := TStringList.Create;
  FMenuActions.Clear;

  FMenuWin := TrackWindow(FDesktop.CreateWindow('PasClaw', 250, 420));
  FMenuWin.ShowMax := False;

  { Scrolled: the project list has no fixed length, and a menu taller than
    the screen is not a menu. }
  Box := TVertScrollBox.Create(FMenuWin);
  Box.Parent := FMenuWin.Client;
  Box.Align := TAlignLayout.Client;

  Content := TLayout.Create(FMenuWin);
  Content.Parent := Box;
  Content.Align := TAlignLayout.Top;
  Content.Width := 238;

  Y := 2;
  Item('Chat',            'chat',       False);
  Item('Browser',         'browser',    False);
  Item('Files',           'files',      False);
  Item('Library',         'library',    False);
  Item('Log',             'log',        False);
  Sep;
  Item('Projects',        'tree',       False);
  Item('New Project...',  'newproject', False);
  Sep;

  { The live half: every project, with its app under it. This is how the
    seeded suite -- Notes, Calendar, Mail -- is reachable without knowing
    they are ordinary projects. }
  for I := 0 to High(FProjects) do
  begin
    Row := FProjects[I];
    Item(Row.Title, 'project:' + Row.Name, False);
    if not Row.HasApp then Continue;
    if not FClient.App(Row.Name, Apps) then Continue;
    if not Apps.Exists then Continue;
    { Runnable, not "not servable": an app with no run command belongs on
      the open path even when its kind says otherwise. }
    if Apps.Runnable then
      Item(Apps.Name + '  (run)', 'run:' + Row.Name, True)
    else
      Item(Apps.Name, 'app:' + Row.Name, True);
  end;
  if Length(FProjects) > 0 then Sep;

  Item('Switch Workspace...', 'pickws',  False);
  Item('New Workspace...',    'newws',   False);
  Item('Display Properties',  'display', False);

  Content.Height := Y + 4;

  { Bottom-left, where a launcher belongs, and only as tall as it needs. }
  H := Round(Y) + 44;
  if H > Round(FDesktop.Height) - 60 then H := Round(FDesktop.Height) - 60;
  if H < 140 then H := 140;
  FMenuWin.Height := H;
  FMenuWin.Position.Point := PointF(8, FDesktop.Height - H - 44);
end;

procedure TFormMain.MenuPick(Sender: TObject);
var
  Idx, I: Integer;
  Action, Arg: string;
begin
  if not (Sender is TButton) then Exit;
  Idx := TButton(Sender).Tag;
  if (FMenuActions = nil) or (Idx < 0) or (Idx >= FMenuActions.Count) then Exit;
  Action := FMenuActions[Idx];
  if Action = '' then Exit;

  Arg := '';
  I := Pos(':', Action);
  if I > 0 then
  begin
    Arg := Copy(Action, I + 1, MaxInt);
    Action := Copy(Action, 1, I - 1);
  end;

  { Close first: every branch below opens a window, and the menu should be
    gone by the time it appears. }
  CloseMenu;

  if Action = 'chat' then OpenPlainChat
  else if Action = 'browser' then OpenBrowser('')
  else if Action = 'files' then OpenFiles
  else if Action = 'library' then OpenLibrary
  else if Action = 'log' then OpenLog
  else if Action = 'tree' then OpenTree
  else if Action = 'newproject' then NewProjectClick(nil)
  else if Action = 'pickws' then PickWorkspaceClick(nil)
  else if Action = 'newws' then NewWorkspaceClick(nil)
  else if Action = 'display' then OpenDisplayProperties
  else if (Action = 'project') and (Arg <> '') then OpenChat(Arg)
  else if (Action = 'app') and (Arg <> '') then OpenApp(Arg)
  else if (Action = 'run') and (Arg <> '') then OpenRun(Arg);
end;

procedure TFormMain.OpenDisplayProperties;
begin
  if FStylePicker = nil then
    BuildStylePicker;
  if FStylePicker <> nil then
    FStylePicker.Restore;
end;

(* A chat with no project attached.

   Every other chat window here is a BUILDER: it sends a system prompt that
   says "your deliverable is an app in this project's directory", which is
   the right default for a desktop whose premise is software-not-text, and
   the wrong one for "what is the syntax for a Pascal set". This is the
   plain one -- no project, no builder prompt, just a conversation. It uses
   the reserved key below so it cannot collide with a project named 'chat'
   (project names are slugs and cannot contain a colon). *)
procedure TFormMain.OpenPlainChat;
begin
  OpenChat(PlainChatKey);
end;

procedure TFormMain.PickWorkspaceClick(Sender: TObject);
var
  I: Integer;
  Menu: string;
begin
  RefreshWorkspaces;
  if Length(FWorkspaces) = 0 then Exit;
  Menu := '';
  for I := 0 to High(FWorkspaces) do
  begin
    Menu := Menu + IntToStr(FWorkspaces[I].Slot) + ': ' + FWorkspaces[I].Label_;
    if FWorkspaces[I].Active then Menu := Menu + ' (current)';
    Menu := Menu + sLineBreak;
  end;
  { A workspace is a wall, not a view -- name the consequence in the prompt
    rather than after the fact. }
  AskText('Switch Workspace',
          'This changes what PasClaw remembers: memory, sessions, skills' +
          sLineBreak + 'and files are all per workspace.' + sLineBreak +
          sLineBreak + Menu + 'Number:',
          '', PickWorkspaceAccepted);
end;

procedure TFormMain.PickWorkspaceAccepted(Sender: TObject);
var
  I, Slot: Integer;
begin
  if FDialogEdit = nil then Exit;
  Slot := StrToIntDef(Trim(FDialogEdit.Text), 0);
  DialogCancel(Sender);
  if Slot <= 0 then Exit;
  for I := 0 to High(FWorkspaces) do
    if (FWorkspaces[I].Slot = Slot) and (not FWorkspaces[I].Active) then
    begin
      SaveDesktopState;
      CloseAllWindows;
      FVersions.Clear;
      if not FClient.ActivateWorkspace(FWorkspaces[I].Name) then
      begin
        Say('Could not switch workspace: ' + FClient.LastError);
        Exit;
      end;
      RefreshWorkspaces;
      RefreshProjects;
      RestoreDesktopState;
      Exit;
    end;
end;

procedure TFormMain.NewWorkspaceClick(Sender: TObject);
begin
  AskText('New Workspace', 'What should this workspace be called?', '',
          NewWorkspaceAccepted);
end;

procedure TFormMain.NewWorkspaceAccepted(Sender: TObject);
var
  Name_: string;
begin
  if FDialogEdit = nil then Exit;
  Name_ := Trim(FDialogEdit.Text);
  DialogCancel(Sender);
  if Name_ = '' then Exit;
  if FClient.CreateWorkspace(Name_) = '' then
  begin
    Say('Could not create workspace: ' + FClient.LastError);
    Exit;
  end;
  RefreshWorkspaces;
  Say('Workspace "' + Name_ + '" created. Switch to it from the Menu.');
end;

procedure TFormMain.NewProjectClick(Sender: TObject);
begin
  AskText('New Project', 'What should this project be called?', '',
          NewProjectAccepted);
end;

procedure TFormMain.NewProjectAccepted(Sender: TObject);
var
  Title, Slug: string;
begin
  if FDialogEdit = nil then Exit;
  Title := Trim(FDialogEdit.Text);
  if Title = '' then Exit;
  try
    Slug := FClient.CreateProject(Title);
    if Slug = '' then
    begin
      Say('Could not create the project: ' + FClient.LastError);
      Exit;
    end;
    RefreshProjects;
    OpenChat(Slug);
  except
    on E: Exception do Say('Could not create the project: ' + E.Message);
  end;
end;

procedure TFormMain.RefreshClick(Sender: TObject);
begin
  RefreshWorkspaces;
  RefreshProjects;
end;

(* Cycle desktops: save the arrangement being left, advance (wrapping,
   creating desktop 2 the first time), restore the one entered. Cheap and
   invisible to the agent -- the whole difference from WS >. *)
procedure TFormMain.NextDesktopClick(Sender: TObject);
var
  Cur, Cnt, Target, Leaving: Integer;
begin
  if not FClient.Desktops(Cur, Cnt) then Exit;
  Leaving := Cur;
  { Named, not "current": the switch below moves what current means, and an
    autosave queued by the closing windows would otherwise land here. }
  SaveDesktopStateTo(Leaving);
  if Cnt < 2 then Target := 2         { first press creates a second desktop }
  else if Cur >= Cnt then Target := 1
  else Target := Cur + 1;
  if not FClient.SwitchDesktop(Target, Cur, Cnt) then Exit;
  CloseAllWindows;
  RestoreDesktopState;
  Say(Format('Desktop %d of %d', [Cur, Cnt]));
end;

(* Tear down every window and forget every handle to one.

   Three call sites needed this and each kept its own list of fields to nil,
   which is a bug waiting for the next window kind: miss one and it becomes
   a dangling pointer the next Restore walks into. One place to update.

   FRestoring is held for the duration so the closes cannot mark the layout
   dirty -- the layout was already saved, deliberately, to a named desk. *)
procedure TFormMain.CloseAllWindows;
var
  WasRestoring: Boolean;
begin
  WasRestoring := FRestoring;
  FRestoring := True;
  try
    while FDesktop.WindowCount > 0 do
      FDesktop.Windows[0].Close;
  finally
    FRestoring := WasRestoring;
  end;
  FChatWins.Clear; FChatLogs.Clear; FChatInputs.Clear; FChatHistory.Clear;
  FChatViews.Clear; FChatTurns.Clear;
  FAppWins.Clear;
  FRunWins.Clear; FRunLogs.Clear; FRunHeads.Clear;
  FStylePicker := nil; FStyleList := nil; FSkinList := nil;
  FLibraryWin := nil; FLibraryList := nil;
  FTreeWin := nil; FTree := nil;
  FLogWin := nil; FLogMemo := nil;
  FFilesWin := nil; FFilesList := nil; FFilesPath := nil;
  FHexWin := nil; FHexMemo := nil;
  FBrowserWin := nil; FBrowserQuery := nil; FBrowserStatus := nil;
  FBrowserSearch := nil; FBrowserDeep := nil; FBrowserPromote := nil;
  FBrowserNew := nil; FBrowserTabs := nil;
  FBrowserView := nil; FCurrentPage := '';
  if FBrowserTabPages <> nil then FBrowserTabPages.Clear;
  FProgressWin := nil; FProgressText := nil;
  FVersionWin := nil;
  FMenuWin := nil;
  { The layout is now empty by construction; do not let that be written
    over the desk we are about to arrive at before it is restored. }
  FLayoutDirty := False;
end;

procedure TFormMain.NextWorkspaceClick(Sender: TObject);
var
  I, Cur: Integer;
begin
  if Length(FWorkspaces) = 0 then Exit;
  Cur := 0;
  for I := 0 to High(FWorkspaces) do
    if FWorkspaces[I].Active then Cur := I;
  Cur := (Cur + 1) mod Length(FWorkspaces);

  { Save THIS workspace's arrangement before leaving it -- switching is
    meant to feel like walking into a different room, which only works if
    the room you left is still as you left it. The state route is per
    workspace, so this lands on the one we are still in. }
  SaveDesktopState;

  { Switching workspaces closes this one's windows -- they belong to the
    workspace, not to the client. }
  CloseAllWindows;
  { Versions belong to a conversation, and the conversations just closed. }
  FVersions.Clear;

  if not FClient.ActivateWorkspace(FWorkspaces[Cur].Name) then
  begin
    Say('Could not switch workspace: ' + FClient.LastError);
    Exit;
  end;
  RefreshWorkspaces;
  RefreshProjects;
  RestoreDesktopState;
end;

procedure TFormMain.IconOpen(Sender: TObject);
var
  Idx: Integer;
begin
  Idx := (Sender as TComponent).Tag;
  if (Idx < 0) or (Idx > High(FProjects)) then Exit;
  { Open means "show me the thing": the app when there is one, otherwise the
    conversation that will build it. }
  if FProjects[Idx].HasApp and FProjects[Idx].AppReady then
    OpenApp(FProjects[Idx].Name)
  else
    OpenChat(FProjects[Idx].Name);
end;

procedure TFormMain.TreeDblClick(Sender: TObject);
var
  Ref: TNodeRef;
begin
  if FTree = nil then Exit;
  if (FTree.Selected = nil) or (FTree.Selected.TagObject = nil) then Exit;
  Ref := FTree.Selected.TagObject as TNodeRef;
  case Ref.Kind of
    nkProject:
      if Ref.HasApp then OpenApp(Ref.Project) else OpenChat(Ref.Project);
    nkTask: OpenChat(Ref.Project);
    nkJob:  OpenJobLog(Ref.Project, Ref.TaskId, Ref.JobId);
  end;
end;

{ ------------------------------------------------------------- live board -- }

type
  { Runs TPasClawClient.WatchEvents, which blocks. Terminating the thread
    stops the subscription through the callback's Stop flag. }
  TEventWatchThread = class(TThread)
  private
    FForm: TFormMain;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TFormMain);
  end;

  { The same pattern for /v1/logs. Only alive while the Log window is open:
    an idle subscription costs the gateway a held connection, and nobody is
    reading it. }
  TLogWatchThread = class(TThread)
  private
    FForm: TFormMain;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TFormMain);
  end;

constructor TEventWatchThread.Create(AForm: TFormMain);
begin
  inherited Create(True);
  FForm := AForm;
  FreeOnTerminate := False;
end;

procedure TEventWatchThread.Execute;
begin
  while not Terminated do
  begin
    { WatchEvents returns when the connection drops. Reconnect, because a
      gateway restart should not leave the desktop silently stale. }
    try
      FForm.FClient.WatchEvents(FForm.OnDesktopEvent);
    except
      { a dead gateway is not an error worth a dialog -- retry quietly }
    end;
    if Terminated then Break;
    Sleep(3000);
  end;
end;

constructor TLogWatchThread.Create(AForm: TFormMain);
begin
  inherited Create(True);
  FForm := AForm;
  FreeOnTerminate := False;
end;

procedure TLogWatchThread.Execute;
begin
  while not Terminated do
  begin
    try
      FForm.FClient.WatchLogs(FForm.LogLine);
    except
      { same deal as events: a dead gateway is a retry, not a dialog }
    end;
    if Terminated then Break;
    Sleep(3000);
  end;
end;

(* The Log window.

   /v1/logs is the gateway's own ring buffer replayed and then tailed live,
   which is the same thing `pasclaw gateway` prints to its terminal -- worth
   having on the desktop when the gateway is on another machine, or started
   by something that swallowed its output.

   What it CANNOT do is show more than the gateway recorded. Log level is a
   server-side filter applied before the buffer, so a debug line that was
   never emitted cannot be recovered by asking differently here. The header
   says so, because the alternative is a level control that appears to do
   something and does not. *)
procedure TFormMain.OpenLog;
var
  Head: TLabel;
begin
  if FLogWin <> nil then
  begin
    FLogWin.Restore;
    Exit;
  end;
  FLogWin := TrackWindow(FDesktop.CreateWindow('Log', 620, 380));
  MarkLayoutDirty;

  Head := TLabel.Create(FLogWin);
  Head.Parent := FLogWin.Client;
  Head.Align := TAlignLayout.Top;
  Head.Height := 32;
  Head.WordWrap := True;
  Head.Text := 'Live from the gateway. Debug lines appear here only when ' +
               'the GATEWAY runs at debug -- set gateway.log_level to ' +
               '"debug" in config.json and restart it.';

  FLogMemo := TMemo.Create(FLogWin);
  FLogMemo.Parent := FLogWin.Client;
  FLogMemo.Align := TAlignLayout.Client;
  FLogMemo.ReadOnly := True;
  FLogMemo.WordWrap := False;

  if FLogPending = nil then FLogPending := TStringList.Create;
  if FLogLock = nil then FLogLock := TCriticalSection.Create;
  FLogStop := False;
  if FLogThread = nil then
  begin
    FLogThread := TLogWatchThread.Create(Self);
    FLogThread.Start;
  end;
end;

(* Queue one line for the Log window.

   Called from several threads -- the gateway tail has its own, a research
   turn traces from another -- so this only appends. Kind and Origin travel
   with the text rather than being rendered in, because whether a line needs
   a segment header depends on what came immediately before it, and that is
   only knowable once the interleaving is settled. *)
procedure TFormMain.QueueLogEntry(const Kind, Origin, Text_: string);
begin
  if (FLogLock = nil) or (FLogPending = nil) then Exit;
  FLogLock.Acquire;
  try
    FLogPending.Add(Kind + #9 + Origin + #9 + Text_);
    { A busy gateway can outrun the timer; the window is a tail, so dropping
      the oldest queued lines beats growing without bound. }
    while FLogPending.Count > 2000 do FLogPending.Delete(0);
  finally
    FLogLock.Release;
  end;
end;

procedure TFormMain.LogLine(const Level, Text_: string; var Stop: Boolean);
begin
  { Worker thread. Queue and return -- the timer paints. }
  Stop := FLogStop or FClosing;
  if Stop then Exit;
  QueueLogEntry('S', '', '[' + Level + '] ' + Text_);
end;

(* Every request the client makes, as it completes.

   This is the half the gateway's own log cannot give you. Its log is
   filtered server-side before anything is recorded, so a client cannot ask
   it for more; and even at debug it reports what the SERVER did, never
   which window wanted it. Here the origin is known exactly, because the
   caller set it before making the call.

   Runs on whichever thread made the request, so it queues like the rest. *)
procedure TFormMain.ClientTrace(const Origin, Method, Path: string;
  Status, Millis: Integer; const Note: string);
var
  Line: string;
begin
  if FClosing then Exit;
  Line := Format('%-6s %s', [Method, Path]);
  if Status > 0 then
    Line := Line + '  ' + IntToStr(Status)
  else
    Line := Line + '  ---';        { never got an answer }
  Line := Line + Format('  %dms', [Millis]);
  if Trim(Note) <> '' then Line := Line + '  ' + Note;
  QueueLogEntry('C', Origin, Line);
end;

procedure TFormMain.DrainLogLines;
var
  Batch: TStringList;
  I, T1, T2: Integer;
  Entry, Kind, Origin, Text_, Rest, Seg: string;
begin
  if (FLogLock = nil) or (FLogPending = nil) then Exit;
  if FLogMemo = nil then Exit;
  Batch := TStringList.Create;
  try
    FLogLock.Acquire;
    try
      if FLogPending.Count = 0 then Exit;
      Batch.Assign(FLogPending);
      FLogPending.Clear;
    finally
      FLogLock.Release;
    end;
    FLogMemo.Lines.BeginUpdate;
    try
      for I := 0 to Batch.Count - 1 do
      begin
        Entry := Batch[I];
        { kind TAB origin TAB text -- see QueueLogEntry }
        T1 := Pos(#9, Entry);
        if T1 = 0 then Continue;
        Kind := Copy(Entry, 1, T1 - 1);
        Rest := Copy(Entry, T1 + 1, MaxInt);
        T2 := Pos(#9, Rest);
        if T2 = 0 then Continue;
        Origin := Copy(Rest, 1, T2 - 1);
        Text_ := Copy(Rest, T2 + 1, MaxInt);

        (* Segment blocks. Client traffic is grouped under whoever made it
           and gateway lines under the gateway, with a header only when the
           source actually changes -- a header per line would be noise, and
           none at all is the undifferentiated stream this exists to
           replace. *)
        if Kind = 'S' then Seg := 'gateway'
        else if Origin = '' then Seg := 'client'
        else Seg := Origin;
        if Seg <> FLogSegment then
        begin
          FLogSegment := Seg;
          FLogMemo.Lines.Add('');
          if Length(Seg) < 58 then
            FLogMemo.Lines.Add('---- ' + Seg + ' ' +
              StringOfChar('-', 58 - Length(Seg)))
          else
            FLogMemo.Lines.Add('---- ' + Seg + ' ----');
        end;
        FLogMemo.Lines.Add('  ' + Text_);
      end;
      while FLogMemo.Lines.Count > 5000 do FLogMemo.Lines.Delete(0);
    finally
      FLogMemo.Lines.EndUpdate;
    end;
    FLogMemo.GoToTextEnd;
  finally
    Batch.Free;
  end;
end;

procedure TFormMain.StopLogWatch;
begin
  FLogStop := True;
  if FLogThread = nil then Exit;
  FLogThread.Terminate;
  (* Cut the socket BEFORE joining.

     The flag above is only consulted when a line arrives, and /v1/logs
     parks silently between log records -- it sends no keepalive, unlike
     the desktop event stream. With no read timeout, which is correct for
     a tail, a quiet gateway leaves the watcher blocked inside Indy with
     nothing to wake it, and joining it here would hang the UI for as long
     as the gateway stayed quiet: closing the Log window, switching
     workspace or quitting would all appear to freeze. Cancelling reaches
     the socket, so the read fails immediately and the thread unwinds. *)
  if FClient <> nil then FClient.CancelLogs;
  FLogThread.WaitFor;
  FreeAndNil(FLogThread);
end;

procedure TFormMain.OnDesktopEvent(const Ev: TDesktopEvent; var Stop: Boolean);
begin
  { Worker thread: touch NOTHING but the flag. FMX controls are main-thread
    only, and a repaint from here would be a race at best. }
  Stop := (FEventThread = nil) or FEventThread.CheckTerminated;
  if Ev.EvType = '' then Exit;
  if (Ev.EvType = 'hello') or (Ev.EvType = 'joblog') then Exit;
  (* Research narration. Still worker-thread rules -- this only writes a
     string; the timer paints it. Without this a deep-research run shows a
     dialog that says nothing for minutes, which is indistinguishable from a
     hang. *)
  if Ev.EvType = 'page-progress' then
  begin
    FProgressLine := Ev.Status;
    if Ev.Line <> '' then FProgressLine := FProgressLine + ': ' + Ev.Line;
    Exit;
  end;
  FEventDirty := True;
end;

procedure TFormMain.MarkLayoutDirty;
begin
  if not FRestoring then FLayoutDirty := True;
end;

procedure TFormMain.ApplyPendingEvents;
var
  ResLog: TMemo;
begin
  if FLayoutDirty then
  begin
    FLayoutDirty := False;
    try
      SaveDesktopState;
    except
      { A desktop that cannot record its layout still works. }
    end;
  end;
  { Main thread: safe to paint. }
  if (FProgressText <> nil) and (FProgressText.Text <> FProgressLine) then
    FProgressText.Text := FProgressLine;

  (* The same narration, into the research conversation. Research runs for
     minutes; a window that said nothing for that long would be
     indistinguishable from a hang, which is the reason the progress feed
     exists at all. *)
  if FResearchRunning and (FProgressLine <> FResearchLastLine) then
  begin
    FResearchLastLine := FProgressLine;
    if FChatLogs.TryGetValue(FResearchKey, ResLog) and (ResLog <> nil) then
    begin
      ResLog.Lines.Add(FProgressLine);
      ResLog.GoToTextEnd;
    end;
  end;
  if not FEventDirty then Exit;
  FEventDirty := False;
  { Coarse on purpose: the board is small and re-reading it is cheap, so a
    full refresh beats maintaining an incremental model that can drift. }
  RefreshProjects;
end;

procedure TFormMain.EventTimerTick(Sender: TObject);
begin
  ApplyPendingEvents;
  { Log lines arrive on their own thread and are painted here, on the main
    one, for the same reason board events are. }
  DrainLogLines;
end;

procedure TFormMain.StartEventWatch;
begin
  FEventTimer := TTimer.Create(Self);
  FEventTimer.Interval := 700;
  FEventTimer.OnTimer := EventTimerTick;
  FEventTimer.Enabled := True;

  FEventThread := TEventWatchThread.Create(Self);
  FEventThread.Start;
end;

{ -------------------------------------------------- period-native output -- }

procedure TFormMain.RenderUIBlocks(const Project: string;
  const Blocks: TUIBlocks);
var
  I: Integer;
begin
  for I := 0 to High(Blocks) do
    case Blocks[I].Kind of
      ubWizard:            ShowWizard(Project, Blocks[I]);
      ubMessage, ubAsk:    ShowAsk(Project, Blocks[I]);
    end;
end;

procedure TFormMain.PaintWizard;
var
  Lbl: TLabel;
  I: Integer;
  Side: TRectangle;
begin
  if (FWizPage = nil) or (FWizWin = nil) then Exit;
  while FWizPage.ChildrenCount > 0 do
    FWizPage.Children[0].Free;

  { The blue side panel: every wizard of the era had one, and it is what
    makes this read as a wizard rather than a form. }
  Side := TRectangle.Create(FWizPage);
  Side.Parent := FWizPage;
  Side.Align := TAlignLayout.Left;
  Side.Width := 78;
  Side.Margins.Rect := TRectF.Create(0, 0, 10, 0);
  Side.Stroke.Kind := TBrushKind.None;

  Lbl := TLabel.Create(FWizPage);
  Lbl.Parent := FWizPage;
  Lbl.Align := TAlignLayout.Top;
  Lbl.Height := 22;
  Lbl.StyledSettings := Lbl.StyledSettings - [TStyledSetting.Style];
  Lbl.TextSettings.Font.Style := [TFontStyle.fsBold];
  Lbl.Text := FWizSteps[FWizIndex].Title;

  Lbl := TLabel.Create(FWizPage);
  Lbl.Parent := FWizPage;
  Lbl.Align := TAlignLayout.Top;
  Lbl.Height := 44;
  Lbl.WordWrap := True;
  Lbl.Text := FWizSteps[FWizIndex].Body;

  { The whole plan stays visible while one step is approved. }
  for I := 0 to High(FWizSteps) do
  begin
    Lbl := TLabel.Create(FWizPage);
    Lbl.Parent := FWizPage;
    Lbl.Align := TAlignLayout.Top;
    Lbl.Height := 18;
    Lbl.Text := IntToStr(I + 1) + '. ' + FWizSteps[I].Title;
    if I = FWizIndex then
    begin
      Lbl.StyledSettings := Lbl.StyledSettings - [TStyledSetting.Style];
      Lbl.TextSettings.Font.Style := [TFontStyle.fsBold];
    end;
  end;

  FWizBack.Enabled := FWizIndex > 0;
  if FWizIndex = High(FWizSteps) then
    FWizNext.Text := 'Finish'
  else
    FWizNext.Text := 'Next >';
  FWizWin.Caption := Format('%s -- step %d of %d',
    [FWizTitle, FWizIndex + 1, Length(FWizSteps)]);
end;

procedure TFormMain.WizardBack(Sender: TObject);
begin
  if FWizIndex > 0 then
  begin
    Dec(FWizIndex);
    PaintWizard;
  end;
end;

procedure TFormMain.WizardNext(Sender: TObject);
var
  I: Integer;
  Ignored: string;
begin
  if FWizIndex < High(FWizSteps) then
  begin
    Inc(FWizIndex);
    PaintWizard;
    Exit;
  end;
  { Finish: the approved plan becomes the board. That gesture -- Next, Next,
    Finish -> real tasks -- is the whole point of rendering it as a wizard. }
  for I := 0 to High(FWizSteps) do
    if Trim(FWizSteps[I].Title) <> '' then
      FClient.CreateTask(FWizProject, FWizSteps[I].Title);
  Ignored := '';
  if FWizWin <> nil then FWizWin.Close;
  FWizWin := nil;
  RefreshProjects;
  Say(Format('%d task(s) added to %s.', [Length(FWizSteps), FWizProject]));
end;

procedure TFormMain.ShowWizard(const Project: string; const Block: TUIBlock);
var
  Wrap, Foot: TLayout;
  B: TButton;
begin
  if Length(Block.Steps) = 0 then Exit;
  if FWizWin <> nil then FWizWin.Close;

  FWizProject := Project;
  FWizSteps := Block.Steps;
  FWizIndex := 0;
  FWizTitle := Block.Title;
  if FWizTitle = '' then FWizTitle := 'Plan';

  FWizWin := TrackWindow(FDesktop.CreateWindow(FWizTitle, 460, 320));
  FWizWin.ShowMax := False;

  Wrap := TLayout.Create(FWizWin);
  Wrap.Parent := FWizWin.Client;
  Wrap.Align := TAlignLayout.Client;

  Foot := TLayout.Create(FWizWin);
  Foot.Parent := FWizWin.Client;
  Foot.Align := TAlignLayout.Bottom;
  Foot.Height := 34;

  B := TButton.Create(FWizWin);
  B.Parent := Foot;
  B.Align := TAlignLayout.Right;
  B.Width := 80;
  B.Margins.Rect := TRectF.Create(4, 4, 8, 4);
  B.Text := 'Cancel';
  B.OnClick := DialogCancel;

  FWizNext := TButton.Create(FWizWin);
  FWizNext.Parent := Foot;
  FWizNext.Align := TAlignLayout.Right;
  FWizNext.Width := 80;
  FWizNext.Margins.Rect := TRectF.Create(4, 4, 0, 4);
  FWizNext.Text := 'Next >';
  FWizNext.Default := True;
  FWizNext.OnClick := WizardNext;

  FWizBack := TButton.Create(FWizWin);
  FWizBack.Parent := Foot;
  FWizBack.Align := TAlignLayout.Right;
  FWizBack.Width := 80;
  FWizBack.Margins.Rect := TRectF.Create(4, 4, 0, 4);
  FWizBack.Text := '< Back';
  FWizBack.OnClick := WizardBack;

  FWizPage := TLayout.Create(FWizWin);
  FWizPage.Parent := Wrap;
  FWizPage.Align := TAlignLayout.Client;
  FWizPage.Padding.Rect := TRectF.Create(8, 8, 8, 4);

  PaintWizard;
end;

procedure TFormMain.AskButtonClick(Sender: TObject);
var
  Answer, Project: string;
  Input: TMemo;
begin
  Answer := (Sender as TButton).TagString;
  Project := FPendingProject;
  if FDialogWin <> nil then FDialogWin.Close;
  FDialogWin := nil;
  if (Project = '') or (Answer = '') then Exit;
  { The chosen label continues the conversation -- the dialog IS the turn. }
  if FChatInputs.TryGetValue(Project, Input) and (Input <> nil) then
  begin
    Input.Text := Answer;
    OpenChat(Project);
  end;
end;

procedure TFormMain.ShowAsk(const Project: string; const Block: TUIBlock);
var
  W: TRetroWindow;
  L: TLabel;
  Row: TLayout;
  B: TButton;
  I: Integer;
begin
  FPendingProject := Project;
  W := TrackWindow(FDesktop.CreateWindow(
    IfThenStr(Block.Title <> '', Block.Title, 'PasClaw'), 380, 170));
  W.ShowMax := False;
  W.ShowMin := False;
  W.Sizeable := False;
  FDialogWin := W;

  Row := TLayout.Create(W);
  Row.Parent := W.Client;
  Row.Align := TAlignLayout.Bottom;
  Row.Height := 34;

  for I := High(Block.Buttons) downto 0 do
  begin
    B := TButton.Create(W);
    B.Parent := Row;
    B.Align := TAlignLayout.Right;
    B.Width := 88;
    B.Margins.Rect := TRectF.Create(4, 4, 4, 4);
    B.Text := Block.Buttons[I].Caption;
    B.TagString := Block.Buttons[I].Value;
    B.OnClick := AskButtonClick;
    if I = 0 then B.Default := True;
  end;

  L := TLabel.Create(W);
  L.Parent := W.Client;
  L.Align := TAlignLayout.Client;
  L.Margins.Rect := TRectF.Create(10, 10, 10, 4);
  L.WordWrap := True;
  L.Text := Block.Text;
end;

{ ------------------------------------------------------------------ chat -- }

procedure TFormMain.OpenChat(const Project: string);
var
  W: TRetroWindow;
  Log, Input: TMemo;
  Bar: TLayout;
  Send, Vers: TButton;
  Row: TProjectRow;
  Title: string;
  View: TWebBrowser;
  ChatHost: TLayout;
  ChatSnap: TImage;
begin
  if FChatWins.TryGetValue(Project, W) and (W <> nil) then
  begin
    W.Restore;
    Exit;
  end;

  if Project = ResearchChatKey then
    Title := 'Research'
  else if Project = PlainChatKey then
    Title := 'PasClaw'
  else if Copy(Project, 1, Length(SessionChatPrefix)) = SessionChatPrefix then
    Title := 'Session ' + Copy(Project, Length(SessionChatPrefix) + 1, MaxInt)
  else
  begin
    Title := Project;
    if ProjectByName(Project, Row) then Title := Row.Title;
  end;
  W := TrackWindow(FDesktop.CreateWindow(Title + ' -- Chat', 520, 420));
  FChatWins.AddOrSetValue(Project, W);

  Bar := TLayout.Create(W);
  Bar.Parent := W.Client;
  Bar.Align := TAlignLayout.Bottom;
  Bar.Height := 64;
  Bar.Padding.Rect := TRectF.Create(2, 2, 2, 2);

  Send := TButton.Create(W);
  Send.Parent := Bar;
  Send.Align := TAlignLayout.Right;
  Send.Width := 68;
  Send.Margins.Left := 4;
  Send.Text := 'Send';
  Send.TagString := Project;
  Send.OnClick := SendChat;

  { Every turn that touches the app leaves a version behind; this opens the
    most recent earlier one. The transcript names them, so the button is the
    door rather than the record. }
  Vers := TButton.Create(W);
  Vers.Parent := Bar;
  Vers.Align := TAlignLayout.Right;
  Vers.Width := 76;
  Vers.Margins.Left := 4;
  Vers.Text := 'Versions';
  Vers.TagString := Project;
  Vers.OnClick := ViewVersionClick;
  MarkLayoutDirty;

  Input := TMemo.Create(W);
  Input.Parent := Bar;
  Input.Align := TAlignLayout.Client;
  Input.TextSettings.WordWrap := True;
  FChatInputs.AddOrSetValue(Project, Input);

  (* Host + snapshot, the same arrangement the app and Browser windows use.

     TWebBrowser is a NATIVE control: it paints above all FMX content, so an
     inactive window would keep showing its transcript on top of whatever
     covers it. BrowserActiveChanged freezes it into a TImage when the
     window loses focus -- but only for browsers it can find, which means
     living inside a host layout under W.Client, being registered in
     FSnapshots, and the window actually raising the event. Adding it to
     FBrowsers alone did none of those. *)
  W.OnActiveChanged := BrowserActiveChanged;

  ChatHost := TLayout.Create(W);
  ChatHost.Parent := W.Client;
  ChatHost.Align := TAlignLayout.Client;

  ChatSnap := TImage.Create(W);
  ChatSnap.Parent := ChatHost;
  ChatSnap.Align := TAlignLayout.Client;
  ChatSnap.WrapMode := TImageWrapMode.Stretch;
  ChatSnap.Visible := False;

  { The settled transcript, formatted. }
  View := TWebBrowser.Create(W);
  View.Parent := ChatHost;
  View.Align := TAlignLayout.Client;
  FChatViews.AddOrSetValue(Project, View);
  FBrowsers.Add(View);
  FSnapshots.AddOrSetValue(View, ChatSnap);

  { The live one. Same slot, shown only while a turn is in flight. }
  Log := TMemo.Create(W);
  Log.Parent := ChatHost;
  Log.Align := TAlignLayout.Client;
  Log.ReadOnly := True;
  Log.TextSettings.WordWrap := True;
  Log.Visible := False;
  FChatLogs.AddOrSetValue(Project, Log);

  if not FChatHistory.ContainsKey(Project) then
    FChatHistory.AddOrSetValue(Project, '[]');

  if not FChatTurns.ContainsKey(Project) then
  begin
    if IsSyntheticChat(Project) then
      AppendTurn(Project, 'assistant',
        'Ask PasClaw anything. This window is not tied to a project, so ' +
        'nothing here builds an app.')
    else
      AppendTurn(Project, 'assistant',
        'Describe the app you want. PasClaw builds it into this project ' +
        'and it opens as a window.');
  end;
  RenderTranscript(Project);
  ShowStreaming(Project, False);
end;



{ Escape a string for embedding in a JSON literal. Chat text routinely
  carries newlines and quotes, and an unescaped control character would make
  the whole request unparseable at the gateway. }
function JsonStr(const S: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '"':  Result := Result + '\"';
      '\': Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      if C < ' ' then
        Result := Result + '\u' + LowerCase(IntToHex(Ord(C), 4))
      else
        Result := Result + C;
    end;
  end;
end;

{ The builder overlay. Same text the browser client sends, for the same
  reason: the deliverable is software, not an essay. }
(* The system prompt a chat sends.

   Empty for every synthetic key, not just the plain-chat one. A session
   reopened from the Library is filed under ':session:<id>', and sending the
   builder prompt for it told the model to write an app into
   projects/:session:<id>/app/ -- a path that cannot exist -- instead of
   just continuing the conversation. The gateway's own default prompt
   applies to these, which is the point of them. *)
function BuilderPrompt(const Project: string): string;
begin
  if IsSyntheticChat(Project) then Exit('');
  Result :=
    'You are working inside the PasClaw Desktop project "' + Project + '".' + sLineBreak +
    'Deliverables are APPS, not essays. When the user asks for something, ' +
    'build it as software they can open in a window.' + sLineBreak + sLineBreak +
    'Write the app into projects/' + Project + '/app/ inside the workspace, ' +
    'and maintain projects/' + Project + '/app/app.json with name, kind ' +
    '(page|html|python), entry and window size.' + sLineBreak +
    'Choose the lightest kind that works: "page" (a static document, no ' +
    'scripts), then "html" (a self-contained page WITH scripts), then ' +
    '"python".' + sLineBreak +
    'An html app persists data through the desktop SDK -- include ' +
    '<script src="pasclaw.js"> and call pasclaw.getJSON / pasclaw.setJSON. ' +
    'Do not fetch the API directly; the app is sandboxed and it will be ' +
    'blocked.' + sLineBreak + sLineBreak +
    'Keep the board current with the project and task tools as you work, ' +
    'and be brief in chat -- the app is the answer.';
end;


(* One colour of the current theme, as "#rrggbb".

   The chat pane is an HTML document, so it needs real colour values rather
   than a style lookup -- and a pane that stayed white inside a Windows 3.1
   desktop would be the one thing on screen ignoring the theme.

   Two sources, both already in the tree. With a skin selected, the .skin
   file IS a palette: "face=C0C0C0" and friends. Without one, the style's
   own colours live in the .style, and its .rolemap records the byte offset
   of every colour literal -- which is how the skin engine patches them, and
   just as good for reading one out. Falls back to the caller's value when
   neither is available, so a missing styles directory costs the theme, not
   the window. *)
function TFormMain.StyleColor(const Role, Fallback: string): string;
var
  Lines: TStringList;
  I, Ofs: Integer;
  Key, Val, MapFile, Line: string;
  FS: TFileStream;
  Buf: array[0..8] of Byte;
begin
  Result := Fallback;

  { A skin, if one is chosen: plain name=RRGGBB text. }
  if (FSkinFile <> '') and TFile.Exists(FSkinFile) then
  begin
    Lines := TStringList.Create;
    try
      try
        Lines.LoadFromFile(FSkinFile);
      except
        Exit;
      end;
      for I := 0 to Lines.Count - 1 do
      begin
        Line := Trim(Lines[I]);
        if (Line = '') or (Line[1] = ';') or (Line[1] = '[') then Continue;
        Key := Trim(Copy(Line, 1, Pos('=', Line) - 1));
        if not SameText(Key, Role) then Continue;
        Val := Trim(Copy(Line, Pos('=', Line) + 1, MaxInt));
        if Length(Val) = 6 then Exit('#' + Val);
      end;
    finally
      Lines.Free;
    end;
    Exit;
  end;

  { Otherwise the style itself, at the offset its role map records. }
  if (FStyleFile = '') or not TFile.Exists(FStyleFile) then Exit;
  MapFile := ChangeFileExt(FStyleFile, '.rolemap');
  if not TFile.Exists(MapFile) then Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(MapFile);
    except
      Exit;
    end;
    Ofs := -1;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if Pos('=', Line) = 0 then Continue;
      Key := Trim(Copy(Line, 1, Pos('=', Line) - 1));
      if not SameText(Key, Role) then Continue;
      Val := Trim(Copy(Line, Pos('=', Line) + 1, MaxInt));
      if Pos(',', Val) > 0 then Val := Copy(Val, 1, Pos(',', Val) - 1);
      Ofs := StrToIntDef(Trim(Val), -1);
      Break;
    end;
    if Ofs < 0 then Exit;
    try
      FS := TFileStream.Create(FStyleFile, fmOpenRead or fmShareDenyWrite);
      try
        if Ofs + 9 > FS.Size then Exit;
        FS.Position := Ofs;
        FS.ReadBuffer(Buf, 9);
      finally
        FS.Free;
      end;
    except
      Exit;
    end;
    { The literal is xAARRGGBB; the alpha byte is not ours to keep. }
    if Chr(Buf[0]) <> 'x' then Exit;
    Result := '#' + Chr(Buf[3]) + Chr(Buf[4]) + Chr(Buf[5]) +
                    Chr(Buf[6]) + Chr(Buf[7]) + Chr(Buf[8]);
  finally
    Lines.Free;
  end;
end;

{ Record a completed turn. Role is 'user', 'assistant' or 'tool'. }
procedure TFormMain.AppendTurn(const Project, Role, Text_: string);
var
  L: TStringList;
begin
  if FChatTurns = nil then Exit;
  if not FChatTurns.TryGetValue(Project, L) then
  begin
    L := TStringList.Create;
    FChatTurns.Add(Project, L);
  end;
  { Tab-separated so a turn containing newlines stays one entry. }
  L.Add(Role + #9 + StringReplace(Text_, #9, '  ', [rfReplaceAll]));
end;

(* Rebuild the whole transcript as an HTML document.

   Whole-document rather than incremental: a conversation is tens of turns,
   the markdown pass is string work, and the alternative is maintaining a
   DOM through a browser control's scripting bridge for no visible gain. *)
procedure TFormMain.RenderTranscript(const Project: string);
var
  View: TWebBrowser;
  L: TStringList;
  I, T: Integer;
  Body, Role, Text_, Entry: string;
begin
  if not FChatViews.TryGetValue(Project, View) then Exit;
  if View = nil then Exit;
  Body := '';
  if FChatTurns.TryGetValue(Project, L) then
    for I := 0 to L.Count - 1 do
    begin
      Entry := L[I];
      T := Pos(#9, Entry);
      if T = 0 then Continue;
      Role  := Copy(Entry, 1, T - 1);
      Text_ := Copy(Entry, T + 1, MaxInt);
      if Role = 'user' then
        Body := Body + '<div class="turn"><span class="who">You</span><br>' +
                MarkdownToHTML(Text_) + '</div>'
      else if Role = 'tool' then
        Body := Body + '<div class="tool">' + HtmlEscape(Text_) + '</div>'
      else if Role = 'toolerr' then
        Body := Body + '<div class="tool err">' + HtmlEscape(Text_) + '</div>'
      else
        Body := Body + '<div class="turn">' + MarkdownToHTML(Text_) + '</div>';
    end;
  View.LoadFromStrings(
    ChatDocumentHTML(Body,
      StyleColor('face',   '#c0c0c0'),
      StyleColor('text',   '#000000'),
      StyleColor('titleA', '#000080'),
      StyleColor('light',  '#e8e8e8')), '');
end;

{ Streaming shows the live memo; a settled transcript shows the document. }
procedure TFormMain.ShowStreaming(const Project: string; Streaming: Boolean);
var
  M: TMemo;
  View: TWebBrowser;
begin
  if FChatLogs.TryGetValue(Project, M) and (M <> nil) then
    M.Visible := Streaming;
  if FChatViews.TryGetValue(Project, View) and (View <> nil) then
  begin
    View.Visible := not Streaming;
    { Marked so the focus handler does not un-hide the transcript over the
      live memo when the window is clicked mid-turn. }
    if Streaming then View.TagString := StreamingTag else View.TagString := '';
  end;
end;

procedure TFormMain.ChatChunk(const Chunk: string; var Abort: Boolean);
begin
  Abort := False;
  if GStreamingLog = nil then Exit;
  { The client's Chat call blocks this thread, so paint as we go rather than
    leaving the window frozen until the turn finishes. }
  GStreamingLog.Text := GStreamingLog.Text + Chunk;
  GStreamingLog.GoToTextEnd;
  Application.ProcessMessages;
end;

(* What the model is DOING, in the transcript.

   Asking for an app used to look like a long silence and then a sentence,
   with no sign of the file writes, the manifest edit and the board updates
   that were the actual work -- and when it went wrong, nothing to look at.
   Each call is one line in, its result one line out, indented so the prose
   still reads as the conversation.

   Deliberately terse: the gateway already caps args and results before they
   reach here, and a chat window is not a log viewer. The Log window is, and
   it is one Menu item away. *)
procedure TFormMain.ChatTool(const Kind, Name, Detail: string; IsErr: Boolean);
var
  Line: string;
begin
  if GStreamingLog = nil then Exit;
  if Kind = 'call' then
  begin
    Line := '  * ' + Name;
    if Trim(Detail) <> '' then Line := Line + ' ' + Detail;
  end
  else if IsErr then
    Line := '    ! ' + Trim(Detail)
  else
  begin
    Line := Trim(Detail);
    if Line = '' then Exit;      { a silent success needs no second line }
    Line := '    ' + Line;
  end;
  GStreamingLog.Lines.Add(Line);
  GStreamingLog.GoToTextEnd;
  { Also kept, so the settled transcript still shows what the turn did. }
  if GStreamingProject <> '' then
  begin
    if IsErr then
      AppendTurn(GStreamingProject, 'toolerr', Trim(Line))
    else
      AppendTurn(GStreamingProject, 'tool', Trim(Line));
  end;
  Application.ProcessMessages;
end;

procedure TFormMain.SendChat(Sender: TObject);
var
  Project, Text, Reply, Hist, Inner, Visible, SessId: string;
  Log, Input: TMemo;
  Row: TProjectRow;
  App: TAppRow;
  Blocks: TUIBlocks;
  Conflict: Boolean;
begin
  SetClientContext('Chat');
  Project := (Sender as TButton).TagString;
  if not FChatLogs.TryGetValue(Project, Log) then Exit;
  if not FChatInputs.TryGetValue(Project, Input) then Exit;
  Text := Trim(Input.Text);
  if Text = '' then Exit;
  Input.Text := '';

  (* In the research window, a follow-up is more research -- and it revises
     the report already on screen, which is what "ask another question here"
     promised. Sending it to the chat endpoint instead would answer in prose
     and quietly abandon the document. *)
  if Project = ResearchChatKey then
  begin
    if FResearchRunning then
    begin
      AppendTurn(Project, 'toolerr', 'still working -- one at a time');
      RenderTranscript(Project);
      Exit;
    end;
    StartResearch(Text, FResearchPage);
    Exit;
  end;

  { The turn joins the transcript; the memo is only the live view of the
    reply being streamed, so it starts empty each time. }
  AppendTurn(Project, 'user', Text);
  RenderTranscript(Project);
  Log.Text := '';
  ShowStreaming(Project, True);

  { History as a JSON array of role/content objects -- the shape
    /v1/chat/completions wants. Built by hand so this unit needs no JSON
    dependency of its own. }
  if not FChatHistory.TryGetValue(Project, Hist) then Hist := '[]';
  Inner := Trim(Hist);
  if (Length(Inner) >= 2) and (Inner[1] = '[') then
    Inner := Copy(Inner, 2, Length(Inner) - 2)
  else
    Inner := '';
  if Trim(Inner) <> '' then Inner := Inner + ',';
  Hist := '[' + Inner + '{"role":"user","content":"' + JsonStr(Text) + '"}]';

  GStreamingLog := Log;
  GStreamingProject := Project;
  try
    (Sender as TButton).Enabled := False;
    try
      Reply := FClient.Chat(Hist, BuilderPrompt(Project), ChatChunk, ChatTool);
    finally
      (Sender as TButton).Enabled := True;
    end;
  finally
    GStreamingLog := nil;
    GStreamingProject := '';
  end;

  if (Reply = '') and (FClient.LastError <> '') then
    AppendTurn(Project, 'toolerr', FClient.LastError);

  { Period-native output: a plan renders as a wizard, a question as a dialog,
    and the block itself never appears as text. Same parser the web client
    uses -- see PasClaw.Client.Api.ParseUIBlocks. }
  ParseUIBlocks(Reply, Visible, Blocks);
  { The reply joins the transcript WITHOUT its ui blocks -- those became
    windows, and showing their JSON as well would be showing the machinery
    twice. }
  if Trim(Visible) <> '' then
    AppendTurn(Project, 'assistant', Visible)
  else if (Reply <> '') and (Length(Blocks) = 0) then
    AppendTurn(Project, 'assistant', Reply);
  if Length(Blocks) > 0 then
  begin
    AppendTurn(Project, 'tool',
      Format('%d dialog(s) opened', [Length(Blocks)]));
    RenderUIBlocks(Project, Blocks);
  end;

  { Back to the formatted view, now that the turn has settled. }
  RenderTranscript(Project);
  ShowStreaming(Project, False);

  Hist := Copy(Hist, 1, Length(Hist) - 1) +
          ',{"role":"assistant","content":"' + JsonStr(Reply) + '"}]';
  FChatHistory.AddOrSetValue(Project, Hist);

  (* A reopened session has to be written back, or it was never really
     reopened: chat completions is stateless, so the continued conversation
     lives only in the dictionary above and dies with the window. The
     gateway refuses (409) when the session holds a rich agent transcript --
     flattening tool and system turns to role/content would destroy what
     terminal resume needs -- and that refusal is worth reporting rather
     than retrying or hiding. *)
  if Copy(Project, 1, Length(SessionChatPrefix)) = SessionChatPrefix then
  begin
    SessId := Copy(Project, Length(SessionChatPrefix) + 1, MaxInt);
    if not FClient.SaveSessionHistory(SessId, Hist, '', Conflict) then
    begin
      if Conflict then
        AppendTurn(Project, 'toolerr',
          'this session has tool turns from an agent run; new messages ' +
          'here are not being saved into it')
      else
        AppendTurn(Project, 'toolerr',
          'could not save this turn into the session: ' + FClient.LastError);
      RenderTranscript(Project);
    end;
  end;

  { Did the turn leave a runnable app behind? Ask the gateway rather than
    trusting the transcript. }
  RefreshProjects;
  if FClient.App(Project, App) and App.Exists and App.Ready then
  begin
    { Pin what this turn produced to the turn that produced it, so scrolling
      back through the conversation is scrolling back through versions. }
    AddArtifactCard(Project);
    if App.Servable then
    begin
      Log.Lines.Add('>> "' + App.Name + '" is ready. Opening it.');
      OpenApp(Project);
    end
    else
    begin
      { python/fpc/delphi: a program, not a document. It gets the Run window
        rather than a browser view, and nothing starts without consent. }
      Log.Lines.Add(Format('>> "%s" is a %s app -- opening its Run window.',
                           [App.Name, App.Kind]));
      OpenRun(Project);
    end;
  end
  else if ProjectByName(Project, Row) and Row.HasApp then
    Log.Lines.Add('>> The app was written but has no runnable entry yet.');
end;

{ ------------------------------------------------------------------- app -- }

procedure TFormMain.BrowserActiveChanged(Sender: TObject);
var
  W: TRetroWindow;
  I: Integer;
  B: TWebBrowser;
  Snap: TImage;
  Bmp: TBitmap;
begin
  { TWebBrowser is a native control that draws above all FMX content, so an
    inactive window would still show its browser on top of whatever covers
    it. Freeze it into a TImage while inactive and swap the live control back
    when the window is focused -- the RetroDesktop demo's technique. }
  if csDestroying in ComponentState then Exit;
  W := Sender as TRetroWindow;
  for I := 0 to FBrowsers.Count - 1 do
  begin
    B := FBrowsers[I];
    if (B = nil) or (B.Parent = nil) then Continue;
    if B.Parent.Parent <> W.Client then Continue;
    if not FSnapshots.TryGetValue(B, Snap) then Continue;
    if W.Active then
    begin
      Snap.Visible := False;
      { A chat window streaming a reply is showing its memo; restoring the
        transcript here would paint it over the live text. }
      B.Visible := B.TagString <> StreamingTag;
    end
    else
    begin
      Bmp := B.MakeScreenshot;
      try
        Snap.Bitmap.Assign(Bmp);
      finally
        Bmp.Free;
      end;
      Snap.Visible := True;
      B.Visible := False;
    end;
  end;
end;

(* Reopen a saved conversation from the Library.

   Its history comes back from the gateway so the next message continues it
   rather than starting over; the transcript is replayed into the window so
   there is something to read on arrival. Filed under a key derived from the
   session id, which cannot collide with a project slug (slugs have no
   colon), so a reopened session and a project chat can be open at once. *)
procedure TFormMain.OpenSessionChat(const SessionId: string);
var
  Key: string;
  Log: TMemo;
  Hist: string;
  Msgs: TChatMessages;
  I: Integer;
begin
  if Trim(SessionId) = '' then Exit;
  Key := SessionChatPrefix + SessionId;
  OpenChat(Key);

  { Already open and already populated -- focusing it is the whole job. }
  if FChatHistory.TryGetValue(Key, Hist) and (Trim(Hist) <> '[]') and
     (Trim(Hist) <> '') then Exit;

  Hist := FClient.SessionHistory(SessionId);
  if Trim(Hist) = '' then Hist := '[]';
  FChatHistory.AddOrSetValue(Key, Hist);

  if not FChatLogs.TryGetValue(Key, Log) then Exit;
  if Log = nil then Exit;

  (* Decoded by the client library, through the real JSON parser.

     The hand-rolled scanner this replaces knew \n and \" but not \uXXXX,
     so every accented letter, dash and emoji in a reopened conversation
     arrived as literal escape text -- and model prose is made of those. *)
  Msgs := ParseChatMessages(Hist);
  if Length(Msgs) = 0 then
  begin
    Log.Lines.Add('(this session has no messages)');
    Exit;
  end;
  Log.Lines.Clear;
  for I := 0 to High(Msgs) do
  begin
    { Tool and system turns are machinery, not conversation. }
    if (Msgs[I].Role <> 'user') and (Msgs[I].Role <> 'assistant') then Continue;
    if Msgs[I].Role = 'user' then
      Log.Lines.Add('> ' + Msgs[I].Content)
    else
      Log.Lines.Add(Msgs[I].Content);
    Log.Lines.Add('');
  end;
  Log.GoToTextEnd;
end;

procedure TFormMain.OpenApp(const Project: string);
var
  W: TRetroWindow;
  App: TAppRow;
  Host: TLayout;
  Browser: TWebBrowser;
  Snap: TImage;
begin
  SetClientContext('App: ' + Project);
  if FAppWins.TryGetValue(Project, W) and (W <> nil) then
  begin
    W.Restore;
    Exit;
  end;
  if not FClient.App(Project, App) then
  begin
    Say('Could not read the app manifest: ' + FClient.LastError);
    Exit;
  end;
  if not App.Exists then
  begin
    Say('This project has no app yet -- ask PasClaw to build one.');
    OpenChat(Project);
    Exit;
  end;
  if not App.Servable then
  begin
    Say(Format('"%s" is kind %s, which runs as a process rather than in a window.',
               [App.Name, App.Kind]));
    Exit;
  end;
  { Declared permissions are shown BEFORE the app opens, not buried in a
    manifest nobody reads. The answer arrives asynchronously, so the rest of
    the open happens in OpenAppConfirmed. }
  if App.Network <> '' then
  begin
    FPendingProject := Project;
    Confirm('Open app',
      Format('"%s" declares network access to:' + sLineBreak + '  %s' +
             sLineBreak + sLineBreak + 'Open it?', [App.Name, App.Network]),
      OpenAppConfirmed);
    Exit;
  end;

  W := TrackWindow(FDesktop.CreateWindow(App.Name, App.Width, App.Height + 24));
  FAppWins.AddOrSetValue(Project, W);
  W.OnActiveChanged := BrowserActiveChanged;

  Host := TLayout.Create(W);
  Host.Parent := W.Client;
  Host.Align := TAlignLayout.Client;

  Snap := TImage.Create(W);
  Snap.Parent := Host;
  Snap.Align := TAlignLayout.Client;
  Snap.WrapMode := TImageWrapMode.Stretch;
  Snap.Visible := False;

  Browser := TWebBrowser.Create(W);
  Browser.Parent := Host;
  Browser.Align := TAlignLayout.Client;
{$IFDEF MSWINDOWS}
  { WebView2 where it exists: the legacy engine renders modern pages badly
    enough to misrepresent an app the agent just wrote. Must be set before
    the handle exists, i.e. before Parent. }
  Browser.WindowsEngine := TWindowsEngine.EdgeIfAvailable;
{$ENDIF}
  Browser.URL := FClient.AppURL(Project);
  FBrowsers.Add(Browser);
  FSnapshots.AddOrSetValue(Browser, Snap);
  MarkLayoutDirty;
end;

{ Yes on the permission dialog: reopen with the prompt suppressed. The
  suppression is one shot -- reopening the app later asks again. }
procedure TFormMain.OpenAppConfirmed(Sender: TObject);
var
  Project: string;
  W: TRetroWindow;
  App: TAppRow;
  Host: TLayout;
  Browser: TWebBrowser;
  Snap: TImage;
begin
  Project := FPendingProject;
  FPendingProject := '';
  if Project = '' then Exit;
  if not FClient.App(Project, App) then Exit;
  if not (App.Exists and App.Servable) then Exit;

  W := TrackWindow(FDesktop.CreateWindow(App.Name, App.Width, App.Height + 24));
  FAppWins.AddOrSetValue(Project, W);
  W.OnActiveChanged := BrowserActiveChanged;

  Host := TLayout.Create(W);
  Host.Parent := W.Client;
  Host.Align := TAlignLayout.Client;

  Snap := TImage.Create(W);
  Snap.Parent := Host;
  Snap.Align := TAlignLayout.Client;
  Snap.WrapMode := TImageWrapMode.Stretch;
  Snap.Visible := False;

  Browser := TWebBrowser.Create(W);
  Browser.Parent := Host;
  Browser.Align := TAlignLayout.Client;
{$IFDEF MSWINDOWS}
  Browser.WindowsEngine := TWindowsEngine.EdgeIfAvailable;
{$ENDIF}
  Browser.URL := FClient.AppURL(Project);
  FBrowsers.Add(Browser);
  FSnapshots.AddOrSetValue(Browser, Snap);
end;

procedure TFormMain.OpenJobLog(const Project, TaskId, JobId: string);
var
  W: TRetroWindow;
  M: TMemo;
begin
  W := TrackWindow(FDesktop.CreateWindow(
    Format('%s %s/%s', [Project, TaskId, JobId]), 520, 300));
  M := TMemo.Create(W);
  M.Parent := W.Client;
  M.Align := TAlignLayout.Client;
  M.ReadOnly := True;
  M.Text := FClient.JobLog(Project, TaskId, JobId);
  if Trim(M.Text) = '' then
    M.Text := '(no output yet)';
end;

(* The Library: what this workspace has accumulated.

   Two kinds of thing, because they answer different questions. Pages are
   what you looked up; sessions are what you talked about. Listing only the
   first made the window look like a search history and left every past
   conversation unreachable from the UI.

   Rows are inert without somewhere to go, so each one is double-clickable:
   a page opens in the Browser, a session opens as a chat. FLibraryKinds
   runs parallel to the visible list because the caption is for reading and
   the id is for acting on -- packing an id into the caption and parsing it
   back out is how you end up with a project named "-- 3 source(s)". *)
procedure TFormMain.OpenLibrary;
var
  Pages: TPageRows;
  Sess: TSessionRows;
  I: Integer;
  Title: string;
begin
  SetClientContext('Library');
  if FLibraryWin <> nil then
  begin
    FLibraryWin.Restore;
    Exit;
  end;
  FLibraryWin := TrackWindow(FDesktop.CreateWindow('Library', 460, 380));
  MarkLayoutDirty;
  if FLibraryKinds = nil then FLibraryKinds := TStringList.Create;
  FLibraryKinds.Clear;

  FLibraryList := TListBox.Create(FLibraryWin);
  FLibraryList.Parent := FLibraryWin.Client;
  FLibraryList.Align := TAlignLayout.Client;
  FLibraryList.OnDblClick := LibraryDblClick;

  FLibraryList.Items.Add('-- Pages --');
  FLibraryKinds.Add('');
  try
    Pages := FClient.Pages;
  except
    SetLength(Pages, 0);
  end;
  if Length(Pages) = 0 then
  begin
    FLibraryList.Items.Add('  (none yet -- ask something in the Browser)');
    FLibraryKinds.Add('');
  end
  else
    for I := 0 to High(Pages) do
    begin
      FLibraryList.Items.Add(Format('  %s -- %d source(s)  %s',
        [Pages[I].Title, Pages[I].SourceCount, Pages[I].Created]));
      FLibraryKinds.Add('page:' + Pages[I].Id);
    end;

  FLibraryList.Items.Add('');
  FLibraryKinds.Add('');
  FLibraryList.Items.Add('-- Sessions --');
  FLibraryKinds.Add('');
  try
    Sess := FClient.Sessions;
  except
    SetLength(Sess, 0);
  end;
  if Length(Sess) = 0 then
  begin
    FLibraryList.Items.Add('  (none yet)');
    FLibraryKinds.Add('');
  end
  else
    for I := 0 to High(Sess) do
    begin
      Title := Sess[I].Title;
      if Trim(Title) = '' then Title := Sess[I].Id;
      FLibraryList.Items.Add('  ' + Title +
        IfThenStr(Sess[I].Model <> '', '  [' + Sess[I].Model + ']', ''));
      FLibraryKinds.Add('session:' + Sess[I].Id);
    end;
end;

procedure TFormMain.LibraryDblClick(Sender: TObject);
var
  Idx, C: Integer;
  Kind, Id: string;
begin
  if (FLibraryList = nil) or (FLibraryKinds = nil) then Exit;
  Idx := FLibraryList.ItemIndex;
  if (Idx < 0) or (Idx >= FLibraryKinds.Count) then Exit;
  Kind := FLibraryKinds[Idx];
  if Kind = '' then Exit;          { a heading, not a row }
  C := Pos(':', Kind);
  if C = 0 then Exit;
  Id := Copy(Kind, C + 1, MaxInt);
  Kind := Copy(Kind, 1, C - 1);
  if Kind = 'page' then OpenBrowser(Id)
  else if Kind = 'session' then OpenSessionChat(Id);
end;

{ ----------------------------------------------------- process apps -- }


(*
  The Run window.

  A `python`/`fpc`/`delphi` app is a program the agent wrote, and starting it
  is arbitrary code execution -- the same deal shell_exec already makes. So
  the window shows the exact command BEFORE asking, names which of the three
  places it will run in, and keeps a live tail of its output.
*)
procedure TFormMain.OpenRun(const Project: string);
var
  W: TRetroWindow;
  Bar: TLayout;
  B: TButton;
  Head: TLabel;
  M: TMemo;
  RunApp_: TAppRow;
begin
  (* An app the runner would refuse does not get a Run window.

     This window is for process apps -- python, fpc, delphi -- which are
     programs to start and stop. Asking it to run a document produced
     "app.json has no run command", a 400 the user can do nothing with, in
     a window whose only control was the button that caused it.

     Asked as "would the runner start something", not "is this a page":
     a manifest whose kind the model wrote as "web" or left out entirely is
     neither, and the previous test -- servable -- let exactly that case
     through to the dead button. If there is nothing to run, the thing to
     do with an app is open it. *)
  if FClient.App(Project, RunApp_) and RunApp_.Exists and
     (not RunApp_.Runnable) then
  begin
    if RunApp_.Servable then
      OpenApp(Project)
    else
      { Neither servable nor runnable: say what is wrong with the manifest
        rather than opening an empty window about it. }
      Say(Format('%s has an app PasClaw cannot open or run: kind="%s", ' +
                 'entry="%s", no run command.',
                 [Project, RunApp_.Kind, RunApp_.Entry]));
    Exit;
  end;

  if FRunWins.TryGetValue(Project, W) and (W <> nil) then
  begin
    W.Restore;
    RefreshRun(Project);
    Exit;
  end;
  W := TrackWindow(FDesktop.CreateWindow(Project + ' -- Run', 520, 360));
  FRunWins.AddOrSetValue(Project, W);

  Head := TLabel.Create(W);
  Head.Parent := W.Client;
  Head.Align := TAlignLayout.Top;
  Head.Height := 56;
  Head.Margins.Rect := TRectF.Create(8, 6, 8, 0);
  Head.WordWrap := True;
  FRunHeads.AddOrSetValue(Project, Head);

  Bar := TLayout.Create(W);
  Bar.Parent := W.Client;
  Bar.Align := TAlignLayout.Top;
  Bar.Height := 30;

  B := TButton.Create(W);
  B.Parent := Bar;
  B.Align := TAlignLayout.Left;
  B.Width := 60;
  B.Margins.Rect := TRectF.Create(6, 3, 0, 3);
  B.Text := 'Run';
  B.TagString := Project;
  B.OnClick := RunStartClick;

  B := TButton.Create(W);
  B.Parent := Bar;
  B.Align := TAlignLayout.Left;
  B.Width := 60;
  B.Margins.Rect := TRectF.Create(6, 3, 0, 3);
  B.Text := 'Stop';
  B.TagString := Project;
  B.OnClick := RunStopClick;

  M := TMemo.Create(W);
  M.Parent := W.Client;
  M.Align := TAlignLayout.Client;
  M.ReadOnly := True;
  FRunLogs.AddOrSetValue(Project, M);

  RefreshRun(Project);
end;

{ Where an app runs, in the words a person would use. Three genuinely
  different places, and a remote daemon is the one that surprises people:
  the app's files and ports are on a machine that is neither this one nor
  necessarily the gateway's. }
function BackendPhrase(const Backend: string): string;
begin
  if Backend = 'docker-remote' then
    Result := 'in a container on a REMOTE Docker host'
  else if Backend = 'docker' then
    Result := 'in a container on the PasClaw host'
  else
    Result := 'as a process on the PasClaw host';
end;

procedure TFormMain.RefreshRun(const Project: string);
var
  Run: TRunRow;
  Head: TLabel;
  M: TMemo;
  Log, Kind: string;
  AppRow: TAppRow;
begin
  SetClientContext('Run: ' + Project);
  if not FClient.RunState(Project, Run) then Exit;
  { Name the kind. A Run button that does nothing is a puzzle; "this app
    declares kind=python" is a fact you can act on -- usually by fixing a
    manifest the model wrote wrong. }
  Kind := '';
  if FClient.App(Project, AppRow) and AppRow.Exists then Kind := AppRow.Kind;
  if FRunHeads.TryGetValue(Project, Head) and (Head <> nil) then
    Head.Text := Format('%s -- runs %s%s%s%s',
      [Run.State, BackendPhrase(Run.Backend),
       IfThenStr(Kind <> '', '   [kind=' + Kind + ']', ''),
       IfThenStr(Run.URL <> '', sLineBreak + Run.URL, ''),
       IfThenStr(Run.Error <> '', sLineBreak + Run.Error, '')]);
  if FRunLogs.TryGetValue(Project, M) and (M <> nil) then
  begin
    Log := FClient.RunLog(Project);
    { Only touch the memo when it changed: reassigning Text every second
      would fight the user's scroll position for no reason. }
    if M.Text <> Log then M.Text := Log;
  end;
end;

procedure TFormMain.RunStartClick(Sender: TObject);
var
  Project, Cmd: string;
  Run: TRunRow;
  App: TAppRow;
begin
  if not (Sender is TButton) then Exit;
  Project := TButton(Sender).TagString;
  if Project = '' then Exit;

  { Ask WITHOUT consent first, purely to get the command back. A
    confirmation that hides what it is confirming is theatre. }
  if not FClient.PlannedCommand(Project, Cmd) then
    Cmd := '(the gateway did not say)';
  FClient.App(Project, App);
  { The run record carries the backend even when nothing is running, so the
    consent dialog can name where it WILL run rather than where it did. }
  FClient.RunState(Project, Run);
  FPendingProject := Project;
  Confirm('Run app',
    Format('This runs a program PasClaw wrote:' + sLineBreak + sLineBreak +
           '  %s' + sLineBreak + sLineBreak +
           'It runs %s.%s' + sLineBreak + sLineBreak + 'Run it?',
      [Cmd, BackendPhrase(Run.Backend),
       IfThenStr(App.Network <> '',
                 sLineBreak + 'It declares network access to: ' + App.Network,
                 '')]),
    RunConfirmed);
end;

procedure TFormMain.RunConfirmed(Sender: TObject);
var
  Run: TRunRow;
  Err: string;
begin
  if FPendingProject = '' then Exit;
  if not FClient.RunApp(FPendingProject, Run, Err) then
    Say('Could not start it: ' + Err)
  else
  begin
    RefreshRun(FPendingProject);
    if FRunTimer <> nil then FRunTimer.Enabled := True;
  end;
  FPendingProject := '';
end;

procedure TFormMain.RunStopClick(Sender: TObject);
var
  Project: string;
begin
  if not (Sender is TButton) then Exit;
  Project := TButton(Sender).TagString;
  if Project = '' then Exit;
  FClient.StopApp(Project);
  RefreshRun(Project);
end;

{ One timer for every Run window: a child's output arrives whenever it
  arrives, and N timers would be N of the same poll. }
procedure TFormMain.RunTimerTick(Sender: TObject);
var
  Key: string;
  Keys: TArray<string>;
  W: TRetroWindow;
begin
  if FRunWins.Count = 0 then
  begin
    if FRunTimer <> nil then FRunTimer.Enabled := False;
    Exit;
  end;
  Keys := FRunWins.Keys.ToArray;
  for Key in Keys do
    if FRunWins.TryGetValue(Key, W) and (W <> nil) then
      RefreshRun(Key);
end;

{ ------------------------------------------------ artifact versions -- }

(*
  Every turn that leaves a runnable app behind adds a card to the chat, and
  the card holds the body THAT turn produced. Scrolling back through a
  conversation is then scrolling back through versions.

  The capture has to happen at the time, because there is nowhere to get it
  from later: the app directory holds one file and each turn overwrites it.
*)
procedure TFormMain.CaptureVersion(const Project: string);
var
  L: TStringList;
  Body: string;
begin
  Body := FClient.AppEntry(Project);
  if Body = '' then Exit;
  if not FVersions.TryGetValue(Project, L) or (L = nil) then
  begin
    L := TStringList.Create;
    FVersions.AddOrSetValue(Project, L);
  end;
  { Identical bodies are not a new version -- a turn that talked without
    touching the app should not look like one that rewrote it. }
  if (L.Count > 0) and (L[L.Count - 1] = Body) then Exit;
  L.Add(Body);
end;

procedure TFormMain.AddArtifactCard(const Project: string);
var
  Log: TMemo;
  App: TAppRow;
  L: TStringList;
  N: Integer;
begin
  if not FClient.App(Project, App) then Exit;
  if not (App.Exists and App.Ready) then Exit;
  CaptureVersion(Project);
  if not FChatLogs.TryGetValue(Project, Log) or (Log = nil) then Exit;

  N := 0;
  if FVersions.TryGetValue(Project, L) and (L <> nil) then N := L.Count;

  (* The transcript is a TMemo, so a "card" is a line, not a widget. It says
     which version it is, and the Versions button on the chat window opens
     the one you pick. Poorer than the web client's card, honestly -- but a
     line that tells the truth beats a widget that cannot exist in a memo. *)
  Log.Lines.Add('');
  Log.Lines.Add(Format('[%s] %s -- version %d. Use "Versions" to open it.',
                       [App.Kind, App.Name, N]));
end;

procedure TFormMain.ViewVersionClick(Sender: TObject);
var
  Project: string;
  L: TStringList;
  W: TRetroWindow;
  M: TMemo;
  Row: TLayout;
  B: TButton;
  Idx: Integer;
begin
  if not (Sender is TButton) then Exit;
  Project := TButton(Sender).TagString;
  if not FVersions.TryGetValue(Project, L) or (L = nil) or (L.Count = 0) then
  begin
    Say('No earlier versions captured in this conversation yet.');
    Exit;
  end;
  { The most recent EARLIER one -- the current app is already open. }
  Idx := L.Count - 2;
  if Idx < 0 then Idx := 0;
  FVersionBody := L[Idx];
  FVersionProject := Project;

  W := TrackWindow(FDesktop.CreateWindow('Earlier version', 560, 420));
  FVersionWin := W;

  Row := TLayout.Create(W);
  Row.Parent := W.Client;
  Row.Align := TAlignLayout.Bottom;
  Row.Height := 32;

  B := TButton.Create(W);
  B.Parent := Row;
  B.Align := TAlignLayout.Right;
  B.Width := 150;
  B.Margins.Rect := TRectF.Create(4, 3, 6, 3);
  B.Text := 'Restore this version';
  B.TagString := Project;
  B.OnClick := RestoreVersionClick;

  { Source rather than a rendered view. A TWebBrowser can only load a URL,
    and this body is not at one -- writing it to a temp file to render it
    would put model output on disk outside the app directory, which is
    exactly what the containment rules exist to prevent. }
  M := TMemo.Create(W);
  M.Parent := W.Client;
  M.Align := TAlignLayout.Client;
  M.ReadOnly := True;
  M.Text := FVersionBody;
end;

procedure TFormMain.RestoreVersionClick(Sender: TObject);
begin
  if FVersionBody = '' then Exit;
  Confirm('Restore version',
    'Put this version back as the current app?' + sLineBreak +
    'The version on disk now will be replaced.', RestoreConfirmed);
end;

procedure TFormMain.RestoreConfirmed(Sender: TObject);
begin
  if (FVersionProject = '') or (FVersionBody = '') then Exit;
  if not FClient.PutAppEntry(FVersionProject, FVersionBody) then
  begin
    Say('Could not restore it: ' + FClient.LastError);
    Exit;
  end;
  if FVersionWin <> nil then
    FVersionWin.Close;
  FVersionWin := nil;
  OpenApp(FVersionProject);
end;

{ -------------------------------------------------- desktop state -- }

(*
  The window layout belongs to the WORKSPACE, and both desktops read the
  same document on the gateway -- so a layout arranged in the web client is
  the layout this one opens with, and switching workspaces really does feel
  like walking into a different room.

  Only windows that can be reconstructed are saved. A progress dialog or a
  confirmation is tied to work that is over; reopening one would be a lie
  about state.
*)
procedure TFormMain.SaveDesktopState;
begin
  { Unnumbered means "wherever we are", which is right for an autosave
    during ordinary work. Switching desks must not use this -- see
    SaveDesktopStateTo. }
  SaveDesktopStateTo(0);
end;

(* Write the layout to a NAMED desktop.

   Paging desks is save-here-then-switch-there, and "here" stops being
   current the moment the switch lands. Saving to "current" therefore races
   the switch: an autosave queued by the closing windows fires afterwards
   and writes an empty layout over the desk the user just left, which is
   exactly how an arrangement disappears. Naming the number retires the
   question instead of trying to order around it.

   Geometry travels with each window now. Reopening the right windows in
   the wrong places is still losing your desktop, just less obviously. *)
procedure TFormMain.SaveDesktopStateTo(Desk: Integer);
var
  Body, Key: string;
  Keys: TArray<string>;
  W: TRetroWindow;
  First: Boolean;

  procedure Add(const Fn, Arg: string; Win: TRetroWindow);
  begin
    if not First then Body := Body + ',';
    First := False;
    Body := Body + '{"fn":"' + Fn + '","arg":"' + JsonStr(Arg) + '"';
    if Win <> nil then
      Body := Body + Format(',"x":%d,"y":%d,"w":%d,"h":%d',
        [Round(Win.Position.X), Round(Win.Position.Y),
         Round(Win.Width), Round(Win.Height)]);
    Body := Body + '}';
  end;

begin
  if FClient = nil then Exit;
  Body := '';
  First := True;
  if FTreeWin    <> nil then Add('projects', '', FTreeWin);
  if FLibraryWin <> nil then Add('library', '', FLibraryWin);
  if FFilesWin   <> nil then Add('files', FFilesDir.Path, FFilesWin);
  if FBrowserWin <> nil then Add('browser', FCurrentPage, FBrowserWin);
  if FLogWin     <> nil then Add('log', '', FLogWin);
  Keys := FChatWins.Keys.ToArray;
  for Key in Keys do
    if FChatWins.TryGetValue(Key, W) and (W <> nil) then Add('chat', Key, W);
  Keys := FAppWins.Keys.ToArray;
  for Key in Keys do
    if FAppWins.TryGetValue(Key, W) and (W <> nil) then Add('app', Key, W);
  Keys := FRunWins.Keys.ToArray;
  for Key in Keys do
    if FRunWins.TryGetValue(Key, W) and (W <> nil) then Add('run', Key, W);
  FClient.SetDesktopStateFor(Desk,
    '{"v":1,"client":"fmx","windows":[' + Body + ']}');
end;

procedure TFormMain.RestoreDesktopState;
var
  State, Fn, Arg, Geo: string;
  P, Q, R, Brace: Integer;
  Opened: TRetroWindow;

  { One integer field out of the record we are standing in. Absent means
    "wherever the window manager wants it", which is what a layout saved
    before geometry existed gets. }
  function GeoInt(const Name: string; Def: Integer): Integer;
  var
    A, B: Integer;
  begin
    Result := Def;
    A := Pos('"' + Name + '":', Geo);
    if A = 0 then Exit;
    Inc(A, Length(Name) + 3);
    B := A;
    while (B <= Length(Geo)) and
          (CharInSet(Geo[B], ['0'..'9', '-'])) do Inc(B);
    if B > A then Result := StrToIntDef(Copy(Geo, A, B - A), Def);
  end;

  procedure PlaceIt(W: TRetroWindow);
  var
    X, Y, Wd, Ht: Integer;
  begin
    if W = nil then Exit;
    X  := GeoInt('x', -1);
    Y  := GeoInt('y', -1);
    Wd := GeoInt('w', -1);
    Ht := GeoInt('h', -1);
    if (Wd > 40) and (Ht > 40) then
    begin
      W.Width  := Wd;
      W.Height := Ht;
    end;
    if (X >= 0) and (Y >= 0) then
      W.Position.Point := PointF(X, Y);
  end;

begin
  if FClient = nil then Exit;
  State := FClient.DesktopState;
  if (State = '') or (Pos('"windows"', State) = 0) then Exit;

  (* Hand-scan rather than parse. The client library has a JSON parser and
     this could use it -- but the shape here is fixed and flat, and one
     malformed layout must not be able to stop the desktop from opening. *)
  FRestoring := True;
  try
    P := 1;
    repeat
      P := PosEx('{"fn":"', State, P);
      if P = 0 then Break;
      Inc(P, 7);
      Q := PosEx('"', State, P);
      if Q = 0 then Break;
      Fn := Copy(State, P, Q - P);

      Arg := '';
      P := PosEx('"arg":"', State, Q);
      if P > 0 then
      begin
        Inc(P, 7);
        Q := PosEx('"', State, P);
        if Q > 0 then
        begin
          Arg := Copy(State, P, Q - P);
          P := Q;
        end;
      end
      else
        P := Q;

      { The rest of this record is where the window goes. Bounded to the
        record we are in so the next window's numbers cannot be read as
        this one's. }
      Brace := PosEx('}', State, P);
      R := PosEx('{"fn":"', State, P);
      if (R > 0) and ((Brace = 0) or (R < Brace)) then Brace := R;
      if Brace > P then Geo := Copy(State, P, Brace - P) else Geo := '';

      Opened := nil;
      if Fn = 'library' then begin OpenLibrary; Opened := FLibraryWin; end
      else if Fn = 'projects' then begin OpenTree; Opened := FTreeWin; end
      else if Fn = 'files' then
      begin
        { The saved directory, not the default one. }
        if Arg <> '' then FFilesDir.Path := Arg;
        OpenFiles;
        Opened := FFilesWin;
      end
      else if Fn = 'log' then begin OpenLog; Opened := FLogWin; end
      else if Fn = 'browser' then begin OpenBrowser(Arg); Opened := FBrowserWin; end
      else if (Fn = 'chat') and (Arg <> '') then
      begin
        OpenChat(Arg);
        if not FChatWins.TryGetValue(Arg, Opened) then Opened := nil;
      end
      else if (Fn = 'app') and (Arg <> '') then
      begin
        OpenApp(Arg);
        if not FAppWins.TryGetValue(Arg, Opened) then Opened := nil;
      end
      else if (Fn = 'run') and (Arg <> '') then
      begin
        OpenRun(Arg);
        if not FRunWins.TryGetValue(Arg, Opened) then Opened := nil;
      end;
      if Opened <> nil then FRestoredAnything := True;
      PlaceIt(Opened);
    until P = 0;
  finally
    FRestoring := False;
  end;
end;

{ ---------------------------------------------------------- browser -- }

(*
  Browser -- a question in, a page out.

  Two buttons because they are two different acts. Search is one pass and
  comes back quickly. Research is the named three-phase mode -- plan the
  sub-questions, read several independent sources, synthesise -- which runs
  for minutes and therefore narrates.
*)
procedure TFormMain.OpenBrowser(const PageId: string);
var
  Bar: TLayout;
  Host: TLayout;
  Snap: TImage;
begin
  if FBrowserWin <> nil then
  begin
    FBrowserWin.Restore;
    if PageId <> '' then ShowPage(PageId);
    Exit;
  end;
  FBrowserWin := TrackWindow(FDesktop.CreateWindow('Browser', 620, 460));
  FBrowserWin.OnActiveChanged := BrowserActiveChanged;

  Bar := TLayout.Create(FBrowserWin);
  Bar.Parent := FBrowserWin.Client;
  Bar.Align := TAlignLayout.Top;
  Bar.Height := 30;

  FBrowserSearch := TButton.Create(FBrowserWin);
  FBrowserSearch.Parent := Bar;
  FBrowserSearch.Align := TAlignLayout.Right;
  FBrowserSearch.Width := 70;
  FBrowserSearch.Margins.Rect := TRectF.Create(0, 3, 3, 3);
  FBrowserSearch.Text := 'Search';
  FBrowserSearch.OnClick := BrowserSearchClick;

  FBrowserDeep := TButton.Create(FBrowserWin);
  FBrowserDeep.Parent := Bar;
  FBrowserDeep.Align := TAlignLayout.Right;
  FBrowserDeep.Width := 80;
  FBrowserDeep.Margins.Rect := TRectF.Create(0, 3, 3, 3);
  FBrowserDeep.Text := 'Research';
  FBrowserDeep.Hint := 'Plan, read several sources, and write a longer sourced report';
  FBrowserDeep.OnClick := BrowserDeepClick;

  FBrowserPromote := TButton.Create(FBrowserWin);
  FBrowserPromote.Parent := Bar;
  FBrowserPromote.Align := TAlignLayout.Right;
  FBrowserPromote.Width := 110;
  FBrowserPromote.Margins.Rect := TRectF.Create(0, 3, 3, 3);
  FBrowserPromote.Text := 'Make interactive';
  FBrowserPromote.Enabled := False;
  FBrowserPromote.OnClick := BrowserPromoteClick;

  FBrowserNew := TButton.Create(FBrowserWin);
  FBrowserNew.Parent := Bar;
  FBrowserNew.Align := TAlignLayout.Right;
  FBrowserNew.Width := 44;
  FBrowserNew.Margins.Rect := TRectF.Create(0, 3, 3, 3);
  FBrowserNew.Text := 'New';
  FBrowserNew.Hint := 'Open an empty tab -- the next question starts a new page';
  FBrowserNew.OnClick := BrowserNewTabClick;

  FBrowserQuery := TEdit.Create(FBrowserWin);
  FBrowserQuery.Parent := Bar;
  FBrowserQuery.Align := TAlignLayout.Client;
  FBrowserQuery.Margins.Rect := TRectF.Create(3, 3, 3, 3);
  FBrowserQuery.TextPrompt := 'Ask anything -- the answer comes back as a page';

  if FBrowserTabPages = nil then FBrowserTabPages := TStringList.Create;
  FBrowserTabPages.Clear;
  FBrowserTabs := TTabControl.Create(FBrowserWin);
  FBrowserTabs.Parent := FBrowserWin.Client;
  FBrowserTabs.Align := TAlignLayout.Top;
  FBrowserTabs.Height := 26;
  FBrowserTabs.TabPosition := TTabPosition.Top;
  FBrowserTabs.OnChange := BrowserTabChange;

  FBrowserStatus := TLabel.Create(FBrowserWin);
  FBrowserStatus.Parent := FBrowserWin.Client;
  FBrowserStatus.Align := TAlignLayout.Bottom;
  FBrowserStatus.Height := 20;
  FBrowserStatus.Margins.Rect := TRectF.Create(6, 0, 6, 2);
  FBrowserStatus.Text := '';

  Host := TLayout.Create(FBrowserWin);
  Host.Parent := FBrowserWin.Client;
  Host.Align := TAlignLayout.Client;

  { Same snapshot trick the app windows use: TWebBrowser is a native control
    that draws above all FMX content, so an inactive window has to show a
    picture of itself instead. }
  Snap := TImage.Create(FBrowserWin);
  Snap.Parent := Host;
  Snap.Align := TAlignLayout.Client;
  Snap.WrapMode := TImageWrapMode.Stretch;
  Snap.Visible := False;

  FBrowserView := TWebBrowser.Create(FBrowserWin);
  FBrowserView.Parent := Host;
  FBrowserView.Align := TAlignLayout.Client;
{$IFDEF MSWINDOWS}
  FBrowserView.WindowsEngine := TWindowsEngine.EdgeIfAvailable;
{$ENDIF}
  FBrowsers.Add(FBrowserView);
  FSnapshots.AddOrSetValue(FBrowserView, Snap);
  MarkLayoutDirty;

  NewBrowserTab('New tab');
  if PageId <> '' then ShowPage(PageId);
end;

(* Add a tab and select it. The tab items hold no content -- the single
   browser below them does -- so this is bookkeeping plus a caption. *)
function TFormMain.NewBrowserTab(const Caption: string): Integer;
var
  Item: TTabItem;
begin
  Result := -1;
  if (FBrowserTabs = nil) or (FBrowserTabPages = nil) then Exit;
  FBrowserSwitching := True;
  try
    Item := FBrowserTabs.Add;
    Item.Text := Caption;
    FBrowserTabPages.Add('');
    FBrowserTabs.ActiveTab := Item;
    Result := FBrowserTabs.TabCount - 1;
  finally
    FBrowserSwitching := False;
  end;
end;

{ What an empty tab looks like. Shared by New and by selecting one, which
  is what stopped the two from drifting apart. }
procedure TFormMain.ShowBlankTab;
begin
  FCurrentPage := '';
  if FBrowserView <> nil then
    FBrowserView.LoadFromStrings(
      ChatDocumentHTML('<p>Ask a question. The answer comes back as a page.</p>',
        StyleColor('face', '#c0c0c0'), StyleColor('text', '#000000'),
        StyleColor('titleA', '#000080'), StyleColor('light', '#e8e8e8')), '');
  if FBrowserPromote <> nil then FBrowserPromote.Enabled := False;
  if FBrowserStatus <> nil then FBrowserStatus.Text := '';
  if FBrowserWin <> nil then FBrowserWin.Caption := 'Browser';
end;

procedure TFormMain.BrowserNewTabClick(Sender: TObject);
begin
  NewBrowserTab('New tab');
  ShowBlankTab;
  if FBrowserQuery <> nil then FBrowserQuery.SetFocus;
end;

procedure TFormMain.BrowserTabChange(Sender: TObject);
var
  I: Integer;
begin
  { Ignore the change we caused ourselves while building a tab. }
  if FBrowserSwitching then Exit;
  if (FBrowserTabs = nil) or (FBrowserTabPages = nil) then Exit;
  I := FBrowserTabs.TabIndex;
  if (I < 0) or (I >= FBrowserTabPages.Count) then Exit;
  if FBrowserTabPages[I] = '' then
  begin
    { Clear the VIEW too, not just the bookkeeping. Leaving the last page
      on screen under an empty tab meant the user could ask a follow-up
      while apparently looking at that page, and get a new topic instead --
      the one thing tabs exist to make unambiguous. }
    ShowBlankTab;
    Exit;
  end;
  ShowPage(FBrowserTabPages[I]);
end;

(* Put a finished page in the tab that asked for it.

   Selecting that tab as well, deliberately: the answer is what the user
   asked for and hiding it in a background tab to avoid disturbing them
   would be its own surprise. What must NOT happen is the result landing in
   a tab that asked something else. When the tab is gone -- closed while the
   turn ran -- the page still opens, in whatever is current, rather than
   being thrown away. *)
procedure TFormMain.ShowPageInTab(const PageId: string; TabIndex: Integer);
begin
  if (FBrowserTabs <> nil) and (TabIndex >= 0) and
     (TabIndex < FBrowserTabs.TabCount) and
     (FBrowserTabs.TabIndex <> TabIndex) then
  begin
    FBrowserSwitching := True;      { this is not a user tab change }
    try
      FBrowserTabs.TabIndex := TabIndex;
    finally
      FBrowserSwitching := False;
    end;
  end;
  ShowPage(PageId);
end;

procedure TFormMain.ShowPage(const PageId: string);
var
  Pages: TPageRows;
  I: Integer;
  N: Integer;
begin
  FCurrentPage := PageId;
  if FBrowserView <> nil then
    FBrowserView.URL := FClient.PageURL(PageId);
  if FBrowserPromote <> nil then FBrowserPromote.Enabled := PageId <> '';

  { The active tab now holds this page, so switching away and back returns
    to it and a follow-up question knows what it is revising. }
  if (FBrowserTabs <> nil) and (FBrowserTabPages <> nil) then
  begin
    I := FBrowserTabs.TabIndex;
    if (I >= 0) and (I < FBrowserTabPages.Count) then
      FBrowserTabPages[I] := PageId;
  end;

  { The sources strip, echoed into the status bar. A page that could not be
    grounded says so on its face; saying it here too means the user sees it
    without scrolling to the footer. }
  N := -1;
  Pages := FClient.Pages;
  for I := 0 to High(Pages) do
    if Pages[I].Id = PageId then
    begin
      N := Pages[I].SourceCount;
      if FBrowserWin <> nil then FBrowserWin.Caption := Pages[I].Title;
      { Name the tab after the page, trimmed -- a tab strip of full titles
        is a tab strip you cannot read. }
      if (FBrowserTabs <> nil) and (FBrowserTabs.TabIndex >= 0) and
         (FBrowserTabs.TabIndex < FBrowserTabs.TabCount) then
        FBrowserTabs.Tabs[FBrowserTabs.TabIndex].Text :=
          Copy(Pages[I].Title, 1, 22);
      Break;
    end;
  if FBrowserStatus = nil then Exit;
  if N < 0 then FBrowserStatus.Text := ''
  else if N = 0 then FBrowserStatus.Text := 'UNGROUNDED -- no sources'
  else FBrowserStatus.Text := Format('GROUNDED -- %d source(s)', [N]);
end;

(*
  Ask for a page, off the UI thread.

  This HAS to be threaded. The gateway holds the request open for the whole
  turn -- minutes, for research -- and Indy's client blocks. Doing it inline
  would freeze the form, which means the progress dialog this mode exists to
  show could never repaint: the user would get a frozen window with a stale
  label, which is worse than no dialog at all.

  So: the request runs on its own thread, the event timer keeps painting
  progress on the main one, and the result is marshalled back with
  TThread.Queue.
*)
procedure TFormMain.RunPageQuery(Kind: TPageKindSel);
var
  Query, Revise: string;
  Deep: Boolean;
  FromTab: Integer;
begin
  if FBrowserQuery = nil then Exit;
  Query := Trim(FBrowserQuery.Text);
  if Query = '' then Exit;
  Deep := Kind = pkeResearch;

  (* A question asked with a page open is a follow-up to THAT page, and the
     answer belongs to the TAB it was asked from.

     Both captured here, on the UI thread. A research turn runs for minutes
     and the user is free to switch tabs or open a new one meanwhile;
     capturing only the page meant the result landed in whatever tab
     happened to be in front when it arrived, replacing an unrelated page
     and leaving the next follow-up revising the wrong one. *)
  Revise := FCurrentPage;
  FromTab := -1;
  if FBrowserTabs <> nil then FromTab := FBrowserTabs.TabIndex;

  FBrowserSearch.Enabled := False;
  FBrowserDeep.Enabled := False;
  if Deep then
  begin
    FProgressLine := 'Planning...';
    ShowProgress('Deep research', Query);
  end
  else if FBrowserStatus <> nil then
  begin
    if Revise <> '' then
      FBrowserStatus.Text := 'Revising this page...'
    else
      FBrowserStatus.Text := 'Searching...';
  end;

  TThread.CreateAnonymousThread(
    procedure
    var
      Id, Err: string;
      Ok: Boolean;
      Marshal: TThreadProcedure;
    begin
      { Set INSIDE the thread: the context is per thread, so tagging it on
        the caller would attribute this call to whatever the main thread
        was doing when the button was pressed. }
      if Kind = pkeResearch then
        SetClientContext('Browser (research)')
      else
        SetClientContext('Browser');
      Ok := False;
      Err := '';
      try
        { Revise is the page in the tab this question was asked from. An
          empty tab means a new page, which is what New is for. }
        Ok := FClient.CreatePageOfKind(Query, Kind, Revise, Id);
        if not Ok then Err := FClient.LastError;
      except
        on E: Exception do Err := E.Message;
      end;
      { Typed local rather than an inline literal: Queue is overloaded on
        TThreadMethod and TThreadProcedure, and an anonymous method written
        straight into the call is ambiguous between them (E2250). Naming the
        type leaves exactly one candidate. }
      Marshal :=
        procedure
        begin
          CloseProgress;
          if FBrowserSearch <> nil then FBrowserSearch.Enabled := True;
          if FBrowserDeep <> nil then FBrowserDeep.Enabled := True;
          if Ok then
            ShowPageInTab(Id, FromTab)
          else if FBrowserStatus <> nil then
            FBrowserStatus.Text := 'Could not produce a page: ' + Err;
        end;
      TThread.Queue(nil, Marshal);
    end).Start;
end;

procedure TFormMain.BrowserSearchClick(Sender: TObject);
begin
  RunPageQuery(pkeSearch);
end;

(* Research opens a CONVERSATION, not a progress box.

   Search is "question in, page out" -- seconds, one shot, and the little
   dialog suits it. Research is the other thing entirely: it plans, reads
   several sources and synthesises, running for minutes and narrating as it
   goes. That is a conversation with a long first turn, and a modal box that
   disappears when it finishes throws away the narration along with any
   ability to ask a follow-up.

   So the report lands in a chat window: the plan and each step arrive as
   they happen, the finished page arrives as a line you can click, and the
   next question continues from there rather than starting over. *)
procedure TFormMain.BrowserDeepClick(Sender: TObject);
var
  Query: string;
begin
  if FBrowserQuery = nil then Exit;
  Query := Trim(FBrowserQuery.Text);
  if Query = '' then Exit;
  FBrowserQuery.Text := '';
  StartResearch(Query, FCurrentPage);
end;

procedure TFormMain.StartResearch(const Query, RevisePageId: string);
var
  Log: TMemo;
begin
  FResearchKey := ResearchChatKey;
  OpenChat(FResearchKey);
  AppendTurn(FResearchKey, 'user', Query);
  if RevisePageId <> '' then
    AppendTurn(FResearchKey, 'tool',
      'revising the open page rather than starting a new one')
  else
    AppendTurn(FResearchKey, 'tool', 'planning');
  RenderTranscript(FResearchKey);

  { The live view carries the narration while the turn runs. }
  if FChatLogs.TryGetValue(FResearchKey, Log) and (Log <> nil) then
  begin
    Log.Text := '';
    Log.Lines.Add('> ' + Query);
    Log.Lines.Add('');
  end;
  ShowStreaming(FResearchKey, True);
  FResearchRunning := True;
  FProgressLine := 'Planning...';

  TThread.CreateAnonymousThread(
    procedure
    var
      Id, Err: string;
      Ok: Boolean;
      Done_: TThreadProcedure;
    begin
      SetClientContext('Research');
      Ok := False;
      Err := '';
      try
        Ok := FClient.CreatePageOfKind(Query, pkeResearch, RevisePageId, Id);
        if not Ok then Err := FClient.LastError;
      except
        on E: Exception do Err := E.Message;
      end;
      Done_ :=
        procedure
        begin
          FResearchRunning := False;
          if Ok then
          begin
            AppendTurn(FResearchKey, 'assistant',
              'The report is ready: **' + Query + '**' + sLineBreak +
              sLineBreak + 'It is open in the Browser. Ask another ' +
              'question here and it revises that report.');
            FResearchPage := Id;
            OpenBrowser(Id);
          end
          else
            AppendTurn(FResearchKey, 'toolerr',
              'the research turn failed: ' + Err);
          RenderTranscript(FResearchKey);
          ShowStreaming(FResearchKey, False);
        end;
      TThread.Queue(nil, Done_);
    end).Start;
end;

(* "Make interactive" -- the page becomes an app you own.

   A copy, deliberately: a page is the record of an answer at a time, so
   editing it in place would falsify the history. The page stays in the
   Library; the app is the part that changes. *)
procedure TFormMain.BrowserPromoteClick(Sender: TObject);
var
  Project: string;
begin
  if FCurrentPage = '' then Exit;
  if not FClient.PromotePage(FCurrentPage, Project) then
  begin
    if FBrowserStatus <> nil then
      FBrowserStatus.Text := 'Could not promote it: ' + FClient.LastError;
    Exit;
  end;
  RefreshProjects;
  OpenApp(Project);
  if FBrowserStatus <> nil then
    FBrowserStatus.Text := 'Now a project: ' + Project +
                           ' -- ask PasClaw to change it';
end;

procedure TFormMain.ShowProgress(const Caption, Text_: string);
var
  L: TLabel;
begin
  CloseProgress;
  FProgressWin := TrackWindow(FDesktop.CreateWindow(Caption, 360, 150));
  FProgressWin.ShowMax := False;
  FProgressWin.ShowMin := False;
  FProgressWin.Sizeable := False;

  L := TLabel.Create(FProgressWin);
  L.Parent := FProgressWin.Client;
  L.Align := TAlignLayout.Top;
  L.Height := 44;
  L.Margins.Rect := TRectF.Create(10, 10, 10, 0);
  L.Text := Text_;
  L.WordWrap := True;

  FProgressText := TLabel.Create(FProgressWin);
  FProgressText.Parent := FProgressWin.Client;
  FProgressText.Align := TAlignLayout.Client;
  FProgressText.Margins.Rect := TRectF.Create(10, 4, 10, 10);
  FProgressText.Text := FProgressLine;
  FProgressText.WordWrap := True;
end;

procedure TFormMain.CloseProgress;
begin
  { Close, not Free: the desktop owns its windows and RemoveWindow is what
    unhooks one properly. Notification clears the fields when it goes. }
  if FProgressWin <> nil then
    FProgressWin.Close;
  FProgressWin := nil;
  FProgressText := nil;
end;

procedure TFormMain.BrowserClick(Sender: TObject);
begin
  OpenBrowser('');
end;

{ ------------------------------------------------------------ files -- }

(*
  File Manager -- the workspace directory, as a directory.

  The plan's "files are alive": the agent's own working files sit on the
  desktop rather than behind a tool call. Read-only on purpose. /v1/fs is
  sandbox-checked and filters secret-bearing files (config.json, .env, TLS
  keys) server-side, so this window shows exactly what the operator surface
  is willing to show -- and a browse window is not the place to invent a
  delete button.
*)
procedure TFormMain.OpenFiles;
var
  Bar: TLayout;
  B: TButton;
begin
  SetClientContext('Files');
  if FFilesWin <> nil then
  begin
    FFilesWin.Restore;
    Exit;
  end;
  FFilesWin := TrackWindow(FDesktop.CreateWindow('File Manager', 560, 400));

  Bar := TLayout.Create(FFilesWin);
  Bar.Parent := FFilesWin.Client;
  Bar.Align := TAlignLayout.Top;
  Bar.Height := 30;

  B := TButton.Create(FFilesWin);
  B.Parent := Bar;
  B.Align := TAlignLayout.Left;
  B.Width := 50;
  B.Margins.Rect := TRectF.Create(3, 3, 0, 3);
  B.Text := 'Up';
  B.OnClick := FilesUpClick;

  B := TButton.Create(FFilesWin);
  B.Parent := Bar;
  B.Align := TAlignLayout.Left;
  B.Width := 84;
  B.Margins.Rect := TRectF.Create(3, 3, 0, 3);
  B.Text := 'Workspace';
  B.OnClick := FilesHomeClick;

  FFilesPath := TEdit.Create(FFilesWin);
  FFilesPath.Parent := Bar;
  FFilesPath.Align := TAlignLayout.Client;
  FFilesPath.Margins.Rect := TRectF.Create(3, 3, 3, 3);
  FFilesPath.OnKeyDown := FilesPathKey;

  FFilesList := TListBox.Create(FFilesWin);
  FFilesList.Parent := FFilesWin.Client;
  FFilesList.Align := TAlignLayout.Client;
  FFilesList.OnDblClick := FilesOpenSel;
  MarkLayoutDirty;

  { Empty path = "wherever you think I should start". The gateway answers
    with the workspace when it can read it, which is the useful default on a
    fresh install where nothing else exists yet. }
  FilesShow('');
end;

procedure TFormMain.FilesShow(const Path: string);
var
  I: Integer;
  Row: TFileRow;
  Line: string;
begin
  SetClientContext('Files');
  if FFilesList = nil then Exit;
  if not FClient.ListDir(Path, FFilesDir) then
  begin
    Say('Could not read that directory: ' + FClient.LastError);
    Exit;
  end;
  if FFilesPath <> nil then FFilesPath.Text := FFilesDir.Path;
  FFilesList.Items.Clear;
  if Length(FFilesDir.Rows) = 0 then
  begin
    FFilesList.Items.Add('(empty)');
    Exit;
  end;
  { Directories first, then files -- the order every one of these managers
    used, and the order that makes double-clicking predictable. }
  for I := 0 to High(FFilesDir.Rows) do
  begin
    Row := FFilesDir.Rows[I];
    if not Row.IsDir then Continue;
    FFilesList.Items.Add('[' + Row.Name + ']');
  end;
  for I := 0 to High(FFilesDir.Rows) do
  begin
    Row := FFilesDir.Rows[I];
    if Row.IsDir then Continue;
    Line := Row.Name;
    while Length(Line) < 40 do Line := Line + ' ';
    FFilesList.Items.Add(Line + IntToStr(Row.Size));
  end;
end;

{ The selected row's name, or '' -- undoing the display formatting above. }
function SelectedFileName(LB: TListBox; out IsDir: Boolean): string;
var
  S: string;
  P: Integer;
begin
  Result := '';
  IsDir := False;
  if (LB = nil) or (LB.ItemIndex < 0) then Exit;
  S := LB.Items[LB.ItemIndex];
  if S = '(empty)' then Exit;
  if (Length(S) > 1) and (S[1] = '[') and (S[Length(S)] = ']') then
  begin
    IsDir := True;
    Result := Copy(S, 2, Length(S) - 2);
    Exit;
  end;
  { A file row is "<name padded to 40><size>"; the name ends at the run of
    spaces we added. A name containing a double space would confuse this, so
    take everything up to the LAST double space rather than the first. }
  P := Pos('  ', S);
  if P > 0 then Result := TrimRight(Copy(S, 1, P - 1)) else Result := TrimRight(S);
end;

procedure TFormMain.FilesOpenSel(Sender: TObject);
var
  Name_: string;
  IsDir: Boolean;
  Base: string;
begin
  Name_ := SelectedFileName(FFilesList, IsDir);
  if Name_ = '' then Exit;
  Base := FFilesDir.Path;
  if (Base <> '') and (Base[Length(Base)] <> '/') and
     (Base[Length(Base)] <> '\') then
    Base := Base + '/';
  if IsDir then FilesShow(Base + Name_)
  else OpenFileView(Base + Name_, Name_);
end;

procedure TFormMain.FilesUpClick(Sender: TObject);
var
  S: string;
  I, Cut: Integer;
begin
  S := FFilesDir.Path;
  if S = '' then Exit;
  { Walk back to the last separator, without assuming which one the server
    used -- this client talks to Windows gateways too. }
  Cut := 0;
  for I := 1 to Length(S) - 1 do
    if (S[I] = '/') or (S[I] = '\') then Cut := I;
  if Cut > 1 then FilesShow(Copy(S, 1, Cut - 1));
end;

procedure TFormMain.FilesHomeClick(Sender: TObject);
begin
  if FFilesDir.WorkspaceRoot <> '' then FilesShow(FFilesDir.WorkspaceRoot);
end;

procedure TFormMain.FilesPathKey(Sender: TObject; var Key: Word;
  var KeyChar: WideChar; Shift: TShiftState);
begin
  if (Key = vkReturn) and (FFilesPath <> nil) then
    FilesShow(Trim(FFilesPath.Text));
end;

(* A file, in a document window. Binary files say so rather than rendering as
   mojibake, and a truncated read admits it -- a viewer that quietly shows
   the first slice of a log is worse than one that says it did. *)
(* Open a file the way its contents deserve.

   Three viewers, chosen by what the thing is rather than by one fallback
   for everything:

     .html / .htm -> the Browser, rendered. The desktop already has a
       browser window and a page IS a document; showing its source in a
       memo was the client refusing to do the obvious thing.
     binary       -> the hex view. "(binary file)" is a diagnosis, not a
       viewer, and the gateway already serves byte windows for exactly
       this (the classic web UI has had a hex dump over the same route
       all along).
     anything else-> text, as before. *)
procedure TFormMain.OpenFileView(const Path, Name: string);
var
  W: TRetroWindow;
  M: TMemo;
  Body, Ext: string;
  Binary, Truncated: Boolean;
begin
  Ext := LowerCase(ExtractFileExt(Name));
  if (Ext = '.html') or (Ext = '.htm') then
  begin
    (* Read it THROUGH the gateway and hand the browser the markup.

       Path is a path on the gateway's filesystem, which is only also this
       machine's when the gateway happens to be local -- point
       PASCLAW_GATEWAY at another box and a file:// URL asks the local
       browser for a file that is not there. Going through /v1/fs keeps
       remote gateways working, carries the bearer token the browser
       control cannot set, and sidesteps escaping every space and hash in
       the path into a URL. *)
    if not FClient.ReadFile_(Path, Body, Binary, Truncated) then
    begin
      Say('Could not read ' + Name + ': ' + FClient.LastError);
      Exit;
    end;
    OpenBrowser('');
    if FBrowserView <> nil then
    begin
      FBrowserView.LoadFromStrings(Body, Path);
      if FBrowserStatus <> nil then
      begin
        if Truncated then
          FBrowserStatus.Text := Path + '  [truncated]'
        else
          FBrowserStatus.Text := Path;
      end;
    end;
    Exit;
  end;

  if not FClient.ReadFile_(Path, Body, Binary, Truncated) then
  begin
    W := TrackWindow(FDesktop.CreateWindow(Name, 560, 420));
    M := TMemo.Create(W);
    M.Parent := W.Client;
    M.Align := TAlignLayout.Client;
    M.ReadOnly := True;
    M.Text := 'Could not read it: ' + FClient.LastError;
    Exit;
  end;

  if Binary then
  begin
    OpenHex(Path);
    Exit;
  end;

  W := TrackWindow(FDesktop.CreateWindow(Name, 560, 420));
  M := TMemo.Create(W);
  M.Parent := W.Client;
  M.Align := TAlignLayout.Client;
  M.ReadOnly := True;
  if Truncated then
    M.Text := Body + sLineBreak + sLineBreak + '[truncated]'
  else
    M.Text := Body;
end;

(* The hex view.

   Paged over /v1/fs/peek: one window of bytes at a time, so opening a
   500 MB file costs a window rather than a download. The gateway caps a
   window at 64 KB; this asks for a screenful. *)
procedure TFormMain.OpenHex(const Path: string);
var
  Bar: TLayout;
  B: TButton;
begin
  FHexPath := Path;
  FHexOffset := 0;
  if FHexWin = nil then
  begin
    FHexWin := TrackWindow(FDesktop.CreateWindow('Hex', 620, 400));

    Bar := TLayout.Create(FHexWin);
    Bar.Parent := FHexWin.Client;
    Bar.Align := TAlignLayout.Bottom;
    Bar.Height := 30;

    B := TButton.Create(FHexWin);
    B.Parent := Bar;
    B.Align := TAlignLayout.Left;
    B.Width := 70;
    B.Text := '< Prev';
    B.OnClick := HexPrevClick;

    B := TButton.Create(FHexWin);
    B.Parent := Bar;
    B.Align := TAlignLayout.Left;
    B.Margins.Left := 4;
    B.Width := 70;
    B.Text := 'Next >';
    B.OnClick := HexNextClick;

    FHexPos := TLabel.Create(FHexWin);
    FHexPos.Parent := Bar;
    FHexPos.Align := TAlignLayout.Client;
    FHexPos.Margins.Left := 8;

    FHexMemo := TMemo.Create(FHexWin);
    FHexMemo.Parent := FHexWin.Client;
    FHexMemo.Align := TAlignLayout.Client;
    FHexMemo.ReadOnly := True;
    FHexMemo.WordWrap := False;
  end;
  FHexWin.Caption := 'Hex -- ' + ExtractFileName(Path);
  FHexWin.Restore;
  HexRender;
end;

procedure TFormMain.HexRender;
const
  Window_ = 1024;      { 64 rows of 16 -- a screenful, not a download }
  Row = 16;
var
  Data: TBytes;
  Total: Int64;
  I, J, N: Integer;
  Hex, Asc, Line: string;
  Lines: TStringList;
  B: Byte;
begin
  if (FHexMemo = nil) or (FClient = nil) then Exit;
  if not FClient.PeekFile(FHexPath, FHexOffset, Window_, Data, Total) then
  begin
    FHexMemo.Text := 'Could not read it: ' + FClient.LastError;
    Exit;
  end;
  FHexTotal := Total;
  N := Length(Data);
  Lines := TStringList.Create;
  try
    I := 0;
    while I < N do
    begin
      Hex := '';
      Asc := '';
      for J := 0 to Row - 1 do
      begin
        if I + J < N then
        begin
          B := Data[I + J];
          Hex := Hex + IntToHex(B, 2) + ' ';
          { Printable ASCII only -- a control byte rendered as itself would
            reflow the column it is supposed to sit in. }
          if (B >= 32) and (B < 127) then
            Asc := Asc + Chr(B)
          else
            Asc := Asc + '.';
        end
        else
          Hex := Hex + '   ';
        if J = 7 then Hex := Hex + ' ';
      end;
      Line := IntToHex(FHexOffset + I, 8) + '  ' + Hex + ' |' + Asc + '|';
      Lines.Add(Line);
      Inc(I, Row);
    end;
    if Lines.Count = 0 then Lines.Add('(empty)');
    FHexMemo.Text := Lines.Text;
  finally
    Lines.Free;
  end;
  if FHexPos <> nil then
    FHexPos.Text := Format('%d - %d of %d bytes',
      [FHexOffset, FHexOffset + N, FHexTotal]);
end;

procedure TFormMain.HexPrevClick(Sender: TObject);
begin
  FHexOffset := FHexOffset - 1024;
  if FHexOffset < 0 then FHexOffset := 0;
  HexRender;
end;

procedure TFormMain.HexNextClick(Sender: TObject);
begin
  if FHexOffset + 1024 >= FHexTotal then Exit;
  FHexOffset := FHexOffset + 1024;
  HexRender;
end;

procedure TFormMain.FilesClick(Sender: TObject);
begin
  OpenFiles;
end;

{ ---------------------------------------------------------- style picker -- }

procedure TFormMain.ApplyCurrentStyle;
var
  StyleFile, SkinFile: string;
  Deferred: TThreadProcedure;
begin
  StyleFile := FStyleFile;
  SkinFile := FSkinFile;
  if StyleFile = '' then Exit;
  { Defer the switch until the current event has unwound: applying a style
    mid-event frees the style objects under the mouse and FMX's hover refresh
    then walks freed memory. Typed local for the same overload reason as
    TThread.Queue in RunPageQuery. }
  Deferred :=
    procedure
    begin
      TRetroSkins.Apply(StyleFile, SkinFile);
    end;
  TThread.ForceQueue(nil, Deferred);
end;

procedure TFormMain.FillSkinList;
var
  SkinFile: string;
  I: Integer;
begin
  if FSkinList = nil then Exit;
  FSkinFiles := TRetroSkins.SkinsFor(FStyleFile);
  FFillingLists := True;
  try
    FSkinList.Clear;
    FSkinList.Items.Add(NoSkin);
    for SkinFile in FSkinFiles do
      FSkinList.Items.Add(TRetroSkins.SkinName(SkinFile));
    FSkinList.ItemIndex := 0;
    for I := 0 to High(FSkinFiles) do
      if SameText(FSkinFiles[I], FSkinFile) then
      begin
        FSkinList.ItemIndex := I + 1;
        Break;
      end;
  finally
    FFillingLists := False;
  end;
end;

procedure TFormMain.StyleChange(Sender: TObject);
var
  StyleFile: string;
begin
  if FFillingLists or (FStyleList = nil) or (FStyleList.ItemIndex < 0) or
     (FStyleDir = '') then Exit;
  StyleFile := TIOPath.Combine(FStyleDir,
    FStyleList.Items[FStyleList.ItemIndex] + '.style');
  if not TFile.Exists(StyleFile) then Exit;
  FStyleFile := StyleFile;
  FSkinFile := '';
  FillSkinList;
  ApplyCurrentStyle;
end;

procedure TFormMain.SkinChange(Sender: TObject);
var
  Index: Integer;
begin
  if FFillingLists or (FSkinList = nil) then Exit;
  Index := FSkinList.ItemIndex;
  if (Index <= 0) or (Index > Length(FSkinFiles)) then
    FSkinFile := ''
  else
    FSkinFile := FSkinFiles[Index - 1];
  ApplyCurrentStyle;
end;

procedure TFormMain.BuildStylePicker;
var
  LB: TListBox;
  Pane: TLayout;
  Lbl: TLabel;
  FileName, Item: string;
begin
  FStylePicker := TrackWindow(
    FDesktop.CreateWindow('Display Properties', 260, 420));
  FStylePicker.ShowMax := False;

  Pane := TLayout.Create(FStylePicker);
  Pane.Align := TAlignLayout.Bottom;
  Pane.Height := 190;
  Pane.Parent := FStylePicker.Client;

  { No stray Library button here any more -- Display Properties is where
    you pick a look, and the Library has its own Menu item. }
  Lbl := TLabel.Create(FStylePicker);
  Lbl.Align := TAlignLayout.Top;
  Lbl.Height := 18;
  Lbl.Text := 'Color scheme';
  Lbl.Parent := Pane;

  FSkinList := TListBox.Create(FStylePicker);
  FSkinList.Align := TAlignLayout.Client;
  FSkinList.Parent := Pane;
  FSkinList.OnChange := SkinChange;

  LB := TListBox.Create(FStylePicker);
  LB.Align := TAlignLayout.Client;
  LB.Parent := FStylePicker.Client;
  if FStyleDir <> '' then
    for FileName in TDirectory.GetFiles(FStyleDir, '*.style') do
    begin
      Item := TIOPath.GetFileNameWithoutExtension(FileName);
      LB.Items.Add(Item);
    end
  else
    LB.Items.Add('(FMXStyles/Retro not found -- see desktop/README.md)');
  LB.OnChange := StyleChange;
  FStyleList := LB;

  FFillingLists := True;
  try
    if FStyleFile <> '' then
      LB.ItemIndex := LB.Items.IndexOf(
        TIOPath.GetFileNameWithoutExtension(FStyleFile));
  finally
    FFillingLists := False;
  end;
  FillSkinList;
end;

end.
