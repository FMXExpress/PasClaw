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

  Requires a sibling checkout of the styles repo -- see desktop/README.md.
  Nothing from it is vendored here.
*)

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  System.IOUtils, System.StrUtils, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs,
  FMX.StdCtrls, FMX.Layouts, FMX.ListBox, FMX.Edit, FMX.Memo, FMX.Styles,
  FMX.Objects, FMX.TreeView, FMX.WebBrowser, FMX.ScrollBox,
  FMX.Controls.Presentation, FMX.Objects,
  FMX.RetroWindows, FMX.RetroSkins,
  PasClaw.Client.Api;

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
    FDock: TLayout;
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
    { One chat / app / log window per project, so reopening focuses rather
      than stacking duplicates. Windows announce their own death through
      FreeNotification -- see Notification. }
    FChatWins: TDictionary<string, TRetroWindow>;
    FAppWins: TDictionary<string, TRetroWindow>;
    FChatLogs: TDictionary<string, TMemo>;
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
    FBrowserSearch, FBrowserDeep, FBrowserPromote: TButton;
    FCurrentPage: string;

    { ---- deep-research progress ----
      A research turn runs for minutes across many searches. The label shows
      what the agent is doing RIGHT NOW, fed by page-progress events, because
      a dialog that says nothing for that long is indistinguishable from a
      hang. }
    FProgressText: TLabel;
    FProgressLine: string;

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
    { True while RestoreDesktopState is opening windows, so restoring does
      not immediately save a half-built layout back over the real one. }
    FRestoring: Boolean;

    function FindStyleDir: string;
    procedure BuildDesktop;
    procedure BuildDock;
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
    procedure BrowserSearchClick(Sender: TObject);
    procedure BrowserDeepClick(Sender: TObject);
    procedure BrowserPromoteClick(Sender: TObject);
    procedure RunPageQuery(Kind: TPageKindSel);
    procedure ShowPage(const PageId: string);
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
    procedure RestoreDesktopState;
    { Mark the layout changed; the event timer flushes it. Saving inline on
      every open and close would put a blocking PUT in the middle of opening
      a window. }
    procedure MarkLayoutDirty;

    procedure FilesClick(Sender: TObject);
    procedure BrowserClick(Sender: TObject);
    procedure SendChat(Sender: TObject);
    procedure ChatChunk(const Chunk: string; var Abort: Boolean);

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

const
  NoSkin = '(style default)';
  DefaultGateway = 'http://127.0.0.1:8088';

{ The chat window whose stream is currently being pumped. Set around the
  blocking Chat call so ChatChunk knows where to append. }
var
  GStreamingLog: TMemo = nil;

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

  { Otherwise walk up from the exe looking for the sibling checkout, the same
    way the RetroDesktop demo does. }
  Dir := ExtractFilePath(ParamStr(0));
  for I := 1 to 7 do
  begin
    if TDirectory.Exists(TPath.Combine(Dir, 'FMXStyles' + PathDelim + 'Retro')) then
      Exit(TPath.Combine(Dir, 'FMXStyles' + PathDelim + 'Retro'));
    if TDirectory.Exists(TPath.Combine(Dir,
         'Cross-Platform-Retro-OS-Styles' + PathDelim + 'FMXStyles' +
         PathDelim + 'Retro')) then
      Exit(TPath.Combine(Dir, 'Cross-Platform-Retro-OS-Styles' + PathDelim +
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

  FStyleDir := FindStyleDir;
  BuildDesktop;
  BuildDock;
  BuildStylePicker;

  if FStyleDir <> '' then
  begin
    Win95 := TPath.Combine(FStyleDir, 'Win95.style');
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
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  { Stop the watcher before the client it reads through goes away. }
  if FEventThread <> nil then
  begin
    FEventThread.Terminate;
    FEventThread.WaitFor;
    FreeAndNil(FEventThread);
  end;
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
  FreeAndNil(FChatLogs);
  FreeAndNil(FAppWins);
  FreeAndNil(FChatWins);
  FreeAndNil(FNodeRefs);
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
  { A window closing is a layout change like any other. }
  if AComponent is TRetroWindow then MarkLayoutDirty;

  if AComponent = FStylePicker then
  begin
    FStylePicker := nil;
    FStyleList := nil;    { owned by the picker, dying with it }
    FSkinList := nil;
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

procedure TFormMain.BuildDock;
var
  Head: TLabel;
  Bar, Bar2: TLayout;
  B: TButton;
begin
  { The dock is a plain left-aligned layout rather than a TRetroWindow: it is
    the shell's permanent edge, the same decision the browser client made. }
  FDock := TLayout.Create(Self);
  FDock.Parent := FDesktop;
  FDock.Align := TAlignLayout.Left;
  FDock.Width := 240;
  FDock.Padding.Rect := TRectF.Create(4, 4, 4, 4);

  Head := TLabel.Create(Self);
  Head.Parent := FDock;
  Head.Align := TAlignLayout.Top;
  Head.Height := 20;
  Head.Text := 'Projects';
  Head.StyledSettings := Head.StyledSettings - [TStyledSetting.Style];
  Head.TextSettings.Font.Style := [TFontStyle.fsBold];

  Bar := TLayout.Create(Self);
  Bar.Parent := FDock;
  Bar.Align := TAlignLayout.Bottom;
  Bar.Height := 30;

  B := TButton.Create(Self);
  B.Parent := Bar;
  B.Align := TAlignLayout.Left;
  B.Width := 108;
  B.Text := 'New Project';
  B.OnClick := NewProjectClick;

  B := TButton.Create(Self);
  B.Parent := Bar;
  B.Align := TAlignLayout.Left;
  B.Margins.Left := 4;
  B.Width := 64;
  B.Text := 'Refresh';
  B.OnClick := RefreshClick;

  { A second row: the windows that are not per project. }
  Bar2 := TLayout.Create(Self);
  Bar2.Parent := FDock;
  Bar2.Align := TAlignLayout.Bottom;
  Bar2.Height := 30;

  B := TButton.Create(Self);
  B.Parent := Bar2;
  B.Align := TAlignLayout.Left;
  B.Width := 74;
  B.Text := 'Browser';
  B.OnClick := BrowserClick;

  B := TButton.Create(Self);
  B.Parent := Bar2;
  B.Align := TAlignLayout.Left;
  B.Margins.Left := 4;
  B.Width := 60;
  B.Text := 'Files';
  B.OnClick := FilesClick;

  B := TButton.Create(Self);
  B.Parent := Bar2;
  B.Align := TAlignLayout.Client;
  B.Margins.Left := 4;
  B.Text := 'Library';
  B.OnClick := LibraryClick;

  B := TButton.Create(Self);
  B.Parent := Bar;
  B.Align := TAlignLayout.Left;
  B.Margins.Left := 4;
  B.Width := 64;
  B.Text := 'Desk >';
  B.Hint := 'Next desktop -- same workspace, different arrangement';
  B.OnClick := NextDesktopClick;

  B := TButton.Create(Self);
  B.Parent := Bar;
  B.Align := TAlignLayout.Client;
  B.Margins.Left := 4;
  B.Text := 'WS >';
  B.Hint := 'Next WORKSPACE -- changes what PasClaw remembers';
  B.Hint := 'Next workspace (Ctrl+Alt+Right)';
  B.OnClick := NextWorkspaceClick;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := FDock;
  FStatus.Align := TAlignLayout.Bottom;
  FStatus.Height := 32;
  FStatus.Margins.Bottom := 2;
  FStatus.WordWrap := True;
  FStatus.Text := '';

  FTree := TTreeView.Create(Self);
  FTree.Parent := FDock;
  FTree.Align := TAlignLayout.Client;
  FTree.OnDblClick := TreeDblClick;
end;

{ --------------------------------------------------------------- refresh -- }

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

procedure TFormMain.MenuClick(Sender: TObject);
begin
  if FStylePicker = nil then
    BuildStylePicker;
  if FStylePicker <> nil then
    FStylePicker.Restore;
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
  Cur, Cnt, Target: Integer;
begin
  if not FClient.Desktops(Cur, Cnt) then Exit;
  SaveDesktopState;
  if Cnt < 2 then Target := 2         { first press creates a second desktop }
  else if Cur >= Cnt then Target := 1
  else Target := Cur + 1;
  if not FClient.SwitchDesktop(Target, Cur, Cnt) then Exit;
  while FDesktop.WindowCount > 0 do
    FDesktop.Windows[0].Close;
  FChatWins.Clear; FChatLogs.Clear; FChatInputs.Clear; FAppWins.Clear;
  FRunWins.Clear; FRunLogs.Clear; FRunHeads.Clear;
  FStylePicker := nil; FLibraryWin := nil;
  FFilesWin := nil; FFilesList := nil; FFilesPath := nil;
  FBrowserWin := nil; FBrowserQuery := nil; FBrowserStatus := nil;
  FBrowserSearch := nil; FBrowserDeep := nil; FBrowserPromote := nil;
  FBrowserView := nil; FCurrentPage := '';
  RestoreDesktopState;
  Say(Format('Desktop %d of %d', [Cur, Cnt]));
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
    the room you left is still as you left it. }
  SaveDesktopState;

  { Switching desktops closes this one's windows -- they belong to the
    workspace, not to the client. }
  while FDesktop.WindowCount > 0 do
    FDesktop.Windows[0].Close;
  FStylePicker := nil;
  FLibraryWin := nil;
  FFilesWin := nil; FFilesList := nil; FFilesPath := nil;
  FBrowserWin := nil; FBrowserQuery := nil; FBrowserStatus := nil;
  FBrowserSearch := nil; FBrowserDeep := nil; FBrowserPromote := nil;
  FBrowserView := nil; FCurrentPage := '';
  FProgressWin := nil; FProgressText := nil;
  FVersionWin := nil;
  FChatWins.Clear; FChatLogs.Clear; FChatInputs.Clear; FAppWins.Clear;
  FRunWins.Clear; FRunLogs.Clear; FRunHeads.Clear;
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
  if not FEventDirty then Exit;
  FEventDirty := False;
  { Coarse on purpose: the board is small and re-reading it is cheap, so a
    full refresh beats maintaining an incremental model that can drift. }
  RefreshProjects;
end;

procedure TFormMain.EventTimerTick(Sender: TObject);
begin
  ApplyPendingEvents;
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
begin
  if FChatWins.TryGetValue(Project, W) and (W <> nil) then
  begin
    W.Restore;
    Exit;
  end;

  Title := Project;
  if ProjectByName(Project, Row) then Title := Row.Title;
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

  Log := TMemo.Create(W);
  Log.Parent := W.Client;
  Log.Align := TAlignLayout.Client;
  Log.ReadOnly := True;
  Log.TextSettings.WordWrap := True;
  FChatLogs.AddOrSetValue(Project, Log);

  if not FChatHistory.ContainsKey(Project) then
    FChatHistory.AddOrSetValue(Project, '[]');

  Log.Lines.Add('Describe the app you want. PasClaw builds it into this ' +
                'project and it opens as a window.');
  Log.Lines.Add('');
end;

function IfThenStr(Cond: Boolean; const Yes, No: string): string;
begin
  if Cond then Result := Yes else Result := No;
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
function BuilderPrompt(const Project: string): string;
begin
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

procedure TFormMain.SendChat(Sender: TObject);
var
  Project, Text, Reply, Hist, Inner, Visible: string;
  Log, Input: TMemo;
  Row: TProjectRow;
  App: TAppRow;
  Blocks: TUIBlocks;
begin
  Project := (Sender as TButton).TagString;
  if not FChatLogs.TryGetValue(Project, Log) then Exit;
  if not FChatInputs.TryGetValue(Project, Input) then Exit;
  Text := Trim(Input.Text);
  if Text = '' then Exit;
  Input.Text := '';

  Log.Lines.Add('you: ' + Text);
  Log.Lines.Add('');
  Log.Lines.Add('pasclaw: ');

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
  try
    (Sender as TButton).Enabled := False;
    try
      Reply := FClient.Chat(Hist, BuilderPrompt(Project), ChatChunk);
    finally
      (Sender as TButton).Enabled := True;
    end;
  finally
    GStreamingLog := nil;
  end;

  if (Reply = '') and (FClient.LastError <> '') then
    Log.Lines.Add('(' + FClient.LastError + ')');

  { Period-native output: a plan renders as a wizard, a question as a dialog,
    and the block itself never appears as text. Same parser the web client
    uses -- see PasClaw.Client.Api.ParseUIBlocks. }
  ParseUIBlocks(Reply, Visible, Blocks);
  if Length(Blocks) > 0 then
  begin
    { Rewrite the streamed text without the block. }
    Log.Lines.Add('  [' + IntToStr(Length(Blocks)) + ' dialog(s) opened]');
    RenderUIBlocks(Project, Blocks);
  end;
  Log.Lines.Add('');

  Hist := Copy(Hist, 1, Length(Hist) - 1) +
          ',{"role":"assistant","content":"' + JsonStr(Reply) + '"}]';
  FChatHistory.AddOrSetValue(Project, Hist);

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
      B.Visible := True;
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

procedure TFormMain.OpenApp(const Project: string);
var
  W: TRetroWindow;
  App: TAppRow;
  Host: TLayout;
  Browser: TWebBrowser;
  Snap: TImage;
begin
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

procedure TFormMain.OpenLibrary;
var
  LB: TListBox;
  Pages: TPageRows;
  I: Integer;
begin
  if FLibraryWin <> nil then
  begin
    FLibraryWin.Restore;
    Exit;
  end;
  FLibraryWin := TrackWindow(FDesktop.CreateWindow('Library', 420, 340));
  MarkLayoutDirty;
  LB := TListBox.Create(FLibraryWin);
  LB.Parent := FLibraryWin.Client;
  LB.Align := TAlignLayout.Client;
  try
    Pages := FClient.Pages;
  except
    on E: Exception do
    begin
      LB.Items.Add('Could not list pages: ' + E.Message);
      Exit;
    end;
  end;
  if Length(Pages) = 0 then
    LB.Items.Add('(no pages yet)')
  else
    for I := 0 to High(Pages) do
      LB.Items.Add(Format('%s -- %d source(s)  %s',
        [Pages[I].Title, Pages[I].SourceCount, Pages[I].Created]));
end;

{ ----------------------------------------------------- process apps -- }

{ Conditional string. StrUtils has one; a local helper keeps this unit's
  uses clause to what it actually needs. }
function IfThenStr(Cond: Boolean; const Yes, No: string): string;
begin
  if Cond then Result := Yes else Result := No;
end;


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
begin
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
  Log: string;
begin
  if not FClient.RunState(Project, Run) then Exit;
  if FRunHeads.TryGetValue(Project, Head) and (Head <> nil) then
    Head.Text := Format('%s -- runs %s%s%s',
      [Run.State, BackendPhrase(Run.Backend),
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
var
  Body, Key: string;
  Keys: TArray<string>;
  W: TRetroWindow;
  First: Boolean;

  procedure Add(const Fn, Arg: string);
  begin
    if not First then Body := Body + ',';
    First := False;
    Body := Body + '{"fn":"' + Fn + '","arg":"' + Arg + '"}';
  end;

begin
  if FClient = nil then Exit;
  Body := '';
  First := True;
  if FLibraryWin <> nil then Add('library', '');
  if FFilesWin <> nil then Add('files', FFilesDir.Path);
  if FBrowserWin <> nil then Add('browser', FCurrentPage);
  Keys := FChatWins.Keys.ToArray;
  for Key in Keys do
    if FChatWins.TryGetValue(Key, W) and (W <> nil) then Add('chat', Key);
  Keys := FAppWins.Keys.ToArray;
  for Key in Keys do
    if FAppWins.TryGetValue(Key, W) and (W <> nil) then Add('app', Key);
  FClient.SetDesktopState('{"v":1,"client":"fmx","windows":[' + Body + ']}');
end;

procedure TFormMain.RestoreDesktopState;
var
  State, Fn, Arg: string;
  P, Q: Integer;
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

      if Fn = 'library' then OpenLibrary
      else if Fn = 'files' then OpenFiles
      else if Fn = 'browser' then OpenBrowser(Arg)
      else if (Fn = 'chat') and (Arg <> '') then OpenChat(Arg)
      else if (Fn = 'app') and (Arg <> '') then OpenApp(Arg);
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

  FBrowserQuery := TEdit.Create(FBrowserWin);
  FBrowserQuery.Parent := Bar;
  FBrowserQuery.Align := TAlignLayout.Client;
  FBrowserQuery.Margins.Rect := TRectF.Create(3, 3, 3, 3);
  FBrowserQuery.TextPrompt := 'Ask anything -- the answer comes back as a page';

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

  if PageId <> '' then ShowPage(PageId);
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
  Query: string;
  Deep: Boolean;
begin
  if FBrowserQuery = nil then Exit;
  Query := Trim(FBrowserQuery.Text);
  if Query = '' then Exit;
  Deep := Kind = pkeResearch;

  FBrowserSearch.Enabled := False;
  FBrowserDeep.Enabled := False;
  if Deep then
  begin
    FProgressLine := 'Planning...';
    ShowProgress('Deep research', Query);
  end
  else if FBrowserStatus <> nil then
    FBrowserStatus.Text := 'Searching...';

  TThread.CreateAnonymousThread(
    procedure
    var
      Id, Err: string;
      Ok: Boolean;
    begin
      Ok := False;
      Err := '';
      try
        Ok := FClient.CreatePageOfKind(Query, Kind, Id);
        if not Ok then Err := FClient.LastError;
      except
        on E: Exception do Err := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        begin
          CloseProgress;
          if FBrowserSearch <> nil then FBrowserSearch.Enabled := True;
          if FBrowserDeep <> nil then FBrowserDeep.Enabled := True;
          if Ok then
            ShowPage(Id)
          else if FBrowserStatus <> nil then
            FBrowserStatus.Text := 'Could not produce a page: ' + Err;
        end);
    end).Start;
end;

procedure TFormMain.BrowserSearchClick(Sender: TObject);
begin
  RunPageQuery(pkeSearch);
end;

procedure TFormMain.BrowserDeepClick(Sender: TObject);
begin
  RunPageQuery(pkeResearch);
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
procedure TFormMain.OpenFileView(const Path, Name: string);
var
  W: TRetroWindow;
  M: TMemo;
  Body: string;
  Binary, Truncated: Boolean;
begin
  W := TrackWindow(FDesktop.CreateWindow(Name, 560, 420));
  M := TMemo.Create(W);
  M.Parent := W.Client;
  M.Align := TAlignLayout.Client;
  M.ReadOnly := True;
  if not FClient.ReadFile_(Path, Body, Binary, Truncated) then
  begin
    M.Text := 'Could not read it: ' + FClient.LastError;
    Exit;
  end;
  if Binary then
    M.Text := '(binary file)'
  else if Truncated then
    M.Text := Body + sLineBreak + sLineBreak + '[truncated]'
  else
    M.Text := Body;
end;

procedure TFormMain.FilesClick(Sender: TObject);
begin
  OpenFiles;
end;

{ ---------------------------------------------------------- style picker -- }

procedure TFormMain.ApplyCurrentStyle;
var
  StyleFile, SkinFile: string;
begin
  StyleFile := FStyleFile;
  SkinFile := FSkinFile;
  if StyleFile = '' then Exit;
  { Defer the switch until the current event has unwound: applying a style
    mid-event frees the style objects under the mouse and FMX's hover refresh
    then walks freed memory. }
  TThread.ForceQueue(nil,
    procedure
    begin
      TRetroSkins.Apply(StyleFile, SkinFile);
    end);
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
  StyleFile := TPath.Combine(FStyleDir,
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
  B: TButton;
begin
  FStylePicker := TrackWindow(
    FDesktop.CreateWindow('Display Properties', 260, 420));
  FStylePicker.ShowMax := False;

  Pane := TLayout.Create(FStylePicker);
  Pane.Align := TAlignLayout.Bottom;
  Pane.Height := 190;
  Pane.Parent := FStylePicker.Client;

  B := TButton.Create(FStylePicker);
  B.Parent := Pane;
  B.Align := TAlignLayout.Bottom;
  B.Height := 26;
  B.Text := 'Library';
  B.OnClick := LibraryClick;

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
      Item := TPath.GetFileNameWithoutExtension(FileName);
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
        TPath.GetFileNameWithoutExtension(FStyleFile));
  finally
    FFillingLists := False;
  end;
  FillSkinList;
end;

end.
