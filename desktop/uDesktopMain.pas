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
  System.IOUtils, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs,
  FMX.StdCtrls, FMX.Layouts, FMX.ListBox, FMX.Edit, FMX.Memo, FMX.Styles,
  FMX.Objects, FMX.TreeView, FMX.WebBrowser, FMX.ScrollBox,
  FMX.Controls.Presentation,
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

    FProjects: TProjectRows;
    FWorkspaces: TWorkspaceRows;
    { The live dialog, its edit, and the handler its OK button runs. Only one
      dialog of each kind is open at a time, so fields are enough. }
    FDialogWin: TRetroWindow;
    FDialogEdit: TEdit;
    FDialogAccept: TNotifyEvent;
    FPendingProject: string;

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
    procedure SendChat(Sender: TObject);
    procedure ChatChunk(const Chunk: string; var Abort: Boolean);

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
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  FreeAndNil(FClient);
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
  Bar: TLayout;
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

  B := TButton.Create(Self);
  B.Parent := Bar;
  B.Align := TAlignLayout.Client;
  B.Margins.Left := 4;
  B.Text := 'WS >';
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

procedure TFormMain.NextWorkspaceClick(Sender: TObject);
var
  I, Cur: Integer;
begin
  if Length(FWorkspaces) = 0 then Exit;
  Cur := 0;
  for I := 0 to High(FWorkspaces) do
    if FWorkspaces[I].Active then Cur := I;
  Cur := (Cur + 1) mod Length(FWorkspaces);

  { Switching desktops closes this one's windows -- they belong to the
    workspace, not to the client. }
  while FDesktop.WindowCount > 0 do
    FDesktop.Windows[0].Close;
  FStylePicker := nil;
  FLibraryWin := nil;
  FChatWins.Clear; FChatLogs.Clear; FChatInputs.Clear; FAppWins.Clear;

  if not FClient.ActivateWorkspace(FWorkspaces[Cur].Name) then
  begin
    Say('Could not switch workspace: ' + FClient.LastError);
    Exit;
  end;
  RefreshWorkspaces;
  RefreshProjects;
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

{ ------------------------------------------------------------------ chat -- }

procedure TFormMain.OpenChat(const Project: string);
var
  W: TRetroWindow;
  Log, Input: TMemo;
  Bar: TLayout;
  Send: TButton;
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
  Project, Text, Reply, Hist, Inner: string;
  Log, Input: TMemo;
  Row: TProjectRow;
  App: TAppRow;
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
  Log.Lines.Add('');

  Hist := Copy(Hist, 1, Length(Hist) - 1) +
          ',{"role":"assistant","content":"' + JsonStr(Reply) + '"}]';
  FChatHistory.AddOrSetValue(Project, Hist);

  { Did the turn leave a runnable app behind? Ask the gateway rather than
    trusting the transcript. }
  RefreshProjects;
  if FClient.App(Project, App) and App.Exists and App.Ready and App.Servable then
  begin
    Log.Lines.Add('>> "' + App.Name + '" is ready. Opening it.');
    OpenApp(Project);
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
