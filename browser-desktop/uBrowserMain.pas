(*
  uBrowserMain - the PasClaw Browser (browser-desktop/): tabs of WebView2 with a PasClaw chat
  beside each, where the agent can read the page and change it.

  Delphi 11+ / FMX / Windows. Compiled blind in this repository -- there is
  no Delphi in CI -- so everything that can be wrong in an interesting way
  lives BELOW this unit in FPC-compilable units with tests:

    PasClaw.Browser.Bridge    IBrowserBridge + the WebView2 quoting quirk
    PasClaw.Browser.Tools     the six page tools
    PasClaw.Browser.Hooks     page context per turn, confirm-before-mutate
    PasClaw.Browser.Session   per-tab history, persisted as JSON

  This unit is the glue: one TBrowserTab per tab holding a TWebBrowser, a
  TPasClawAgent with the tools and hooks bound to THAT tab's bridge, and
  the tab's own session. "Each tab is its own session" is literal -- the
  agent for a tab only ever sees that tab's history, and the page context
  stamped on each message is that tab's page.

  THREADS. TPasClawAgent runs its loop on the calling thread, so a turn
  runs on a TTask; every tool's Run and every hook fires there. The
  bridge marshals EvaluateJavaScript to the UI thread and waits on an
  event with a timeout. OnText also arrives on the task thread and is
  queued to the memo. The bridge refuses to be called FROM the UI thread
  rather than deadlock: a Queue-and-wait on the thread that must run the
  queued work never returns.

  THE ENGINE-ORDER RULE. WindowsEngine is assigned before Parent. Parent
  creates the native handle and the engine is chosen at that moment; the
  other order compiles, runs, and silently uses the IE-era engine. The
  desktop learned this the hard way; scripts/check-browser-shape.py now
  fails the build on it.
*)
unit uBrowserMain;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  System.Threading, System.SyncObjs, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs,
  FMX.TabControl, FMX.WebBrowser, FMX.StdCtrls, FMX.Edit, FMX.Memo,
  FMX.Layouts, FMX.Controls.Presentation, FMX.ScrollBox, FMX.Memo.Types,
  FMX.DialogService.Sync,
  PasClaw.Agent,
  PasClaw.Providers.Types,
  PasClaw.Browser.Bridge,
  PasClaw.Browser.Tools,
  PasClaw.Browser.Hooks,
  PasClaw.Browser.Session;

type
  TBrowserTab = class;

  (* IBrowserBridge over one TWebBrowser. Lives with the tab; the tools
     and hooks hold it by interface. Every method here may be called from
     the agent's task thread and never from the UI thread. *)
  TFmxBridge = class(TInterfacedObject, IBrowserBridge)
  private
    FTab:      TBrowserTab;     { not owned }
    FLoadDone: TEvent;          { set by OnDidFinishLoad }
    function OnUIThread: Boolean;
  public
    constructor Create(ATab: TBrowserTab);
    destructor Destroy; override;
    procedure SignalLoadDone;
    function Eval(const JS: string; TimeoutMs: Integer; out Value, Err: string): Boolean;
    function Navigate(const URL: string; TimeoutMs: Integer; out Err: string): Boolean;
    function CurrentURL: string;
    function CurrentTitle: string;
  end;

  TBrowserTab = class
  private
    FItem:      TTabItem;
    FBrowser:   TWebBrowser;
    FAddress:   TEdit;
    FTranscript: TMemo;
    FInput:     TEdit;
    FSend:      TButton;
    FConfirm:   TCheckBox;
    FStatus:    TLabel;
    FSession:   TBrowserSession;
    FAgent:     TPasClawAgent;
    FBridge:    IBrowserBridge;
    FBridgeObj: TFmxBridge;
    FConfirmHook: TConfirmMutationHook;
    FBusy:      Boolean;
    FURL:       string;     { cached on the UI thread by OnDidFinishLoad }
    FTitle:     string;
    FHome:      string;
    procedure BuildUI(Owner: TComponent; Host: TTabControl);
    procedure OnDidFinishLoad(ASender: TObject);
    procedure OnGo(Sender: TObject);
    procedure OnAddressKey(Sender: TObject; var Key: Word; var KeyChar: Char; Shift: TShiftState);
    procedure OnSendClick(Sender: TObject);
    procedure OnInputKey(Sender: TObject; var Key: Word; var KeyChar: Char; Shift: TShiftState);
    procedure OnAgentText(Sender: TObject; const Text: string);
    procedure OnAgentToolCall(Sender: TObject; const Name, ArgsJSON: string);
    procedure OnAgentError(Sender: TObject; const Msg: string);
    function  AskConfirm(const ToolName, ArgsJSON, Host: string): TConfirmAnswer;
    procedure AppendLine(const S: string);
    procedure SetBusy(B: Boolean);
    procedure RefreshTitle;
  public
    constructor Create(Owner: TComponent; Host: TTabControl; const Home: string;
                       const SessionId: string = '');
    destructor Destroy; override;
    procedure NavigateTo(const URL: string);
    procedure SendMessage(const Text: string);
    property Item: TTabItem read FItem;
    property Browser: TWebBrowser read FBrowser;
    property Session: TBrowserSession read FSession;
  end;

  TFormMain = class(TForm)
    TopBar: TLayout;
    Tabs: TTabControl;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
  private
    FTabs: TObjectList<TBrowserTab>;
    FHome: string;
    FNewTab, FCloseTab, FBack, FFwd, FReload: TButton;
    procedure OnNewTab(Sender: TObject);
    procedure OnCloseTab(Sender: TObject);
    procedure OnBack(Sender: TObject);
    procedure OnFwd(Sender: TObject);
    procedure OnReload(Sender: TObject);
    function  ActiveTab: TBrowserTab;
    procedure AddTab(const URL: string);
  end;

var
  FormMain: TFormMain;

implementation

{$R *.fmx}

uses
  PasClaw.Config;   { GetHome -- the user's PASCLAW_HOME, shared with the CLI }

const
  HomePage = 'https://github.com/FMXExpress/PasClaw';

{ ================================================================ bridge }

constructor TFmxBridge.Create(ATab: TBrowserTab);
begin
  inherited Create;
  FTab := ATab;
  FLoadDone := TEvent.Create(nil, True, False, '');
end;

destructor TFmxBridge.Destroy;
begin
  FLoadDone.Free;
  inherited;
end;

function TFmxBridge.OnUIThread: Boolean;
begin
  Result := TThread.CurrentThread.ThreadID = MainThreadID;
end;

procedure TFmxBridge.SignalLoadDone;
begin
  FLoadDone.SetEvent;
end;

function TFmxBridge.Eval(const JS: string; TimeoutMs: Integer;
                         out Value, Err: string): Boolean;
var
  Done: TEvent;
  Res:  string;
begin
  Value := '';
  Err := '';
  Result := False;
  if (FTab = nil) or (FTab.FBrowser = nil) then
  begin
    Err := 'no browser';
    Exit;
  end;
  if OnUIThread then
  begin
    { Queue-and-wait from the thread that runs the queue is a deadlock.
      The agent always calls from its task, so reaching here is a bug in
      the caller; say so instead of hanging the app. }
    Err := 'bridge called on the UI thread';
    Exit;
  end;

  Done := TEvent.Create(nil, True, False, '');
  try
    Res := '';
    TThread.Queue(nil,
      procedure
      begin
        try
          (* Delphi 11+: the overload that returns the completion value.
             The callback runs later, on the UI thread, when the engine
             has the result. This is the one line that ties the unit to
             a Delphi version. *)
          FTab.FBrowser.EvaluateJavaScript(JS,
            procedure(const AResult: string)
            begin
              Res := AResult;
              Done.SetEvent;
            end);
        except
          on E: Exception do
          begin
            Res := '';
            Done.SetEvent;
          end;
        end;
      end);
    if Done.WaitFor(TimeoutMs) <> wrSignaled then
    begin
      Err := Format('script did not complete within %d ms', [TimeoutMs]);
      Exit;
    end;
    { One layer of JSON quoting off, per the bridge contract. }
    Value := UnwrapJsString(Res);
    Result := True;
  finally
    Done.Free;
  end;
end;

function TFmxBridge.Navigate(const URL: string; TimeoutMs: Integer;
                             out Err: string): Boolean;
begin
  Err := '';
  Result := False;
  if (FTab = nil) or (FTab.FBrowser = nil) then
  begin
    Err := 'no browser';
    Exit;
  end;
  if OnUIThread then
  begin
    Err := 'bridge called on the UI thread';
    Exit;
  end;
  FLoadDone.ResetEvent;
  TThread.Queue(nil,
    procedure
    begin
      if URL = 'back:' then FTab.FBrowser.GoBack
      else if URL = 'forward:' then FTab.FBrowser.GoForward
      else if URL = 'reload:' then FTab.FBrowser.Reload
      else FTab.FBrowser.Navigate(URL);
    end);
  if FLoadDone.WaitFor(TimeoutMs) <> wrSignaled then
  begin
    Err := Format('page did not finish loading within %d ms', [TimeoutMs]);
    Exit;
  end;
  Result := True;
end;

function TFmxBridge.CurrentURL: string;
begin
  if FTab = nil then Result := '' else Result := FTab.FURL;
end;

function TFmxBridge.CurrentTitle: string;
begin
  if FTab = nil then Result := '' else Result := FTab.FTitle;
end;

{ ================================================================ tab }

constructor TBrowserTab.Create(Owner: TComponent; Host: TTabControl;
                               const Home, SessionId: string);
var
  Id: string;
begin
  inherited Create;
  FHome := Home;
  if SessionId = '' then Id := NewBrowserSessionId else Id := SessionId;
  FSession := TBrowserSession.Create(Id);
  FSession.LoadFromFile(SessionFilePath(FHome, Id));   { False for a new tab; fine }

  BuildUI(Owner, Host);

  { The bridge is owned by interface reference; keep the object pointer
    too so OnDidFinishLoad can signal it without a cast. }
  FBridgeObj := TFmxBridge.Create(Self);
  FBridge := FBridgeObj;

  (* One agent per tab, on the user's own PASCLAW_HOME: LoadConfigFromDisk
     stays True, so the provider, memory, facts and AGENTS.md are the same
     ones the CLI and web UI use. What is per-tab is the history, the
     tools' bridge, and the hooks' bridge -- which is what makes the agent
     act on THIS page and remember THIS conversation. *)
  FAgent := TPasClawAgent.Create(nil);
  FAgent.OnText     := OnAgentText;
  FAgent.OnToolCall := OnAgentToolCall;
  FAgent.OnError    := OnAgentError;

  FAgent.RegisterTool(TBrowserPageTool.Create(FBridge));
  FAgent.RegisterTool(TBrowserFindTool.Create(FBridge));
  FAgent.RegisterTool(TBrowserNavigateTool.Create(FBridge));
  FAgent.RegisterTool(TBrowserClickTool.Create(FBridge));
  FAgent.RegisterTool(TBrowserFillTool.Create(FBridge));
  FAgent.RegisterTool(TBrowserEvalTool.Create(FBridge));

  FAgent.RegisterHook(TPageContextHook.Create(FBridge, True));
  FConfirmHook := TConfirmMutationHook.Create(FBridge, AskConfirm);
  FAgent.RegisterHook(FConfirmHook);   { agent owns it from here }

  { Replay the saved transcript into the memo so a reopened tab reads
    like it did before. }
  if FSession.TurnCount > 0 then
  begin
    var Hist := FSession.HistoryCopy;
    for var M in Hist do
      if M.Role = mrUser then AppendLine('You: ' + M.Content)
      else if M.Role = mrAssistant then AppendLine('PasClaw: ' + M.Content);
  end;
end;

destructor TBrowserTab.Destroy;
begin
  FSession.SaveToFile(SessionFilePath(FHome, FSession.Id));
  FAgent.Free;          { frees the tools and hooks it owns }
  FBridgeObj := nil;
  FBridge := nil;       { releases the bridge }
  FSession.Free;
  { FItem and everything parented to it are owned by the form. }
  inherited;
end;

procedure TBrowserTab.BuildUI(Owner: TComponent; Host: TTabControl);
var
  Split: TSplitter;
  Right, Bottom: TLayout;
  Go: TButton;
begin
  FItem := Host.Add(TTabItem);
  FItem.Text := 'New tab';

  { ---- left: address + browser ---- }
  var Left := TLayout.Create(Owner);
  Left.Parent := FItem;
  Left.Align := TAlignLayout.Client;

  var AddrBar := TLayout.Create(Owner);
  AddrBar.Parent := Left;
  AddrBar.Align := TAlignLayout.Top;
  AddrBar.Height := 32;

  Go := TButton.Create(Owner);
  Go.Parent := AddrBar;
  Go.Align := TAlignLayout.Right;
  Go.Width := 48;
  Go.Text := 'Go';
  Go.OnClick := OnGo;

  FAddress := TEdit.Create(Owner);
  FAddress.Parent := AddrBar;
  FAddress.Align := TAlignLayout.Client;
  FAddress.TextPrompt := 'Enter a URL';
  FAddress.OnKeyDown := OnAddressKey;

  FBrowser := TWebBrowser.Create(Owner);
{$IFDEF MSWINDOWS}
  (* BEFORE Parent -- see the unit header and check-browser-shape.py. *)
  FBrowser.WindowsEngine := TWindowsEngine.EdgeIfAvailable;
{$ENDIF}
  FBrowser.Parent := Left;
  FBrowser.Align := TAlignLayout.Client;
  FBrowser.OnDidFinishLoad := OnDidFinishLoad;

  { ---- splitter ---- }
  Split := TSplitter.Create(Owner);
  Split.Parent := FItem;
  Split.Align := TAlignLayout.Right;
  Split.Width := 6;

  { ---- right: chat ---- }
  Right := TLayout.Create(Owner);
  Right.Parent := FItem;
  Right.Align := TAlignLayout.Right;
  Right.Width := 420;

  FStatus := TLabel.Create(Owner);
  FStatus.Parent := Right;
  FStatus.Align := TAlignLayout.Top;
  FStatus.Height := 22;
  FStatus.Text := 'PasClaw';

  FConfirm := TCheckBox.Create(Owner);
  FConfirm.Parent := Right;
  FConfirm.Align := TAlignLayout.Top;
  FConfirm.Height := 24;
  FConfirm.Text := 'Confirm before the agent changes the page';
  FConfirm.IsChecked := True;

  Bottom := TLayout.Create(Owner);
  Bottom.Parent := Right;
  Bottom.Align := TAlignLayout.Bottom;
  Bottom.Height := 32;

  FSend := TButton.Create(Owner);
  FSend.Parent := Bottom;
  FSend.Align := TAlignLayout.Right;
  FSend.Width := 64;
  FSend.Text := 'Send';
  FSend.OnClick := OnSendClick;

  FInput := TEdit.Create(Owner);
  FInput.Parent := Bottom;
  FInput.Align := TAlignLayout.Client;
  FInput.TextPrompt := 'Ask about this page, or tell PasClaw to change it';
  FInput.OnKeyDown := OnInputKey;

  FTranscript := TMemo.Create(Owner);
  FTranscript.Parent := Right;
  FTranscript.Align := TAlignLayout.Client;
  FTranscript.ReadOnly := True;
  FTranscript.WordWrap := True;
end;

procedure TBrowserTab.NavigateTo(const URL: string);
var
  U: string;
begin
  U := Trim(URL);
  if U = '' then Exit;
  if Pos('://', U) = 0 then U := 'https://' + U;
  FAddress.Text := U;
  FBrowser.Navigate(U);
end;

procedure TBrowserTab.OnGo(Sender: TObject);
begin
  NavigateTo(FAddress.Text);
end;

procedure TBrowserTab.OnAddressKey(Sender: TObject; var Key: Word;
                                   var KeyChar: Char; Shift: TShiftState);
begin
  if Key = vkReturn then
  begin
    Key := 0;
    NavigateTo(FAddress.Text);
  end;
end;

procedure TBrowserTab.RefreshTitle;
begin
  { document.title needs a script; cache it once per load so the hook's
    CurrentTitle is a field read, not a round-trip. }
  FBrowser.EvaluateJavaScript('document.title',
    procedure(const AResult: string)
    var
      T: string;
    begin
      T := UnwrapJsString(AResult);
      if T = '' then T := FURL;
      FTitle := T;
      if Length(T) > 28 then T := Copy(T, 1, 27) + '…';
      FItem.Text := T;
      FSession.Title := FTitle;
    end);
end;

procedure TBrowserTab.OnDidFinishLoad(ASender: TObject);
begin
  FURL := FBrowser.URL;
  FAddress.Text := FURL;
  FSession.URL := FURL;
  RefreshTitle;
  if FBridgeObj <> nil then FBridgeObj.SignalLoadDone;
end;

procedure TBrowserTab.AppendLine(const S: string);
begin
  FTranscript.Lines.Add(S);
  FTranscript.GoToTextEnd;
end;

procedure TBrowserTab.SetBusy(B: Boolean);
begin
  FBusy := B;
  FSend.Enabled := not B;
  FInput.Enabled := not B;
  if B then FStatus.Text := 'PasClaw is working…' else FStatus.Text := 'PasClaw';
end;

procedure TBrowserTab.OnSendClick(Sender: TObject);
begin
  SendMessage(FInput.Text);
end;

procedure TBrowserTab.OnInputKey(Sender: TObject; var Key: Word;
                                 var KeyChar: Char; Shift: TShiftState);
begin
  if Key = vkReturn then
  begin
    Key := 0;
    SendMessage(FInput.Text);
  end;
end;

procedure TBrowserTab.SendMessage(const Text: string);
var
  Msg: string;
  Hist: TMessageArray;
begin
  Msg := Trim(Text);
  if (Msg = '') or FBusy then Exit;
  FInput.Text := '';
  FSession.AppendUser(Msg);
  AppendLine('You: ' + Msg);
  AppendLine('PasClaw: ');
  SetBusy(True);

  { The whole transcript goes in every turn; the component keeps nothing.
    Copy now, on the UI thread, so the task owns a snapshot. }
  Hist := FSession.HistoryCopy;

  TTask.Run(
    procedure
    var
      Reply, Err: string;
      Ok: Boolean;
    begin
      Ok := FAgent.ChatHistory(Hist, Reply, Err);
      TThread.Queue(nil,
        procedure
        begin
          if Ok then
          begin
            FSession.AppendAssistant(Reply);
            { OnText streamed the reply into the memo already; make sure the
              final text is what is recorded in case streaming was partial. }
            if FTranscript.Lines.Count > 0 then
              FTranscript.Lines[FTranscript.Lines.Count - 1] := 'PasClaw: ' + Reply;
          end
          else
            AppendLine('[error] ' + Err);
          FSession.SaveToFile(SessionFilePath(FHome, FSession.Id));
          SetBusy(False);
        end);
    end);
end;

procedure TBrowserTab.OnAgentText(Sender: TObject; const Text: string);
begin
  { Task thread. Append the chunk to the last memo line. }
  TThread.Queue(nil,
    procedure
    begin
      if FTranscript.Lines.Count = 0 then
        FTranscript.Lines.Add('PasClaw: ' + Text)
      else
        FTranscript.Lines[FTranscript.Lines.Count - 1] :=
          FTranscript.Lines[FTranscript.Lines.Count - 1] + Text;
      FTranscript.GoToTextEnd;
    end);
end;

procedure TBrowserTab.OnAgentToolCall(Sender: TObject; const Name, ArgsJSON: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      FStatus.Text := 'PasClaw: ' + Name;
    end);
end;

procedure TBrowserTab.OnAgentError(Sender: TObject; const Msg: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      AppendLine('[error] ' + Msg);
    end);
end;

function TBrowserTab.AskConfirm(const ToolName, ArgsJSON, Host: string): TConfirmAnswer;
var
  Answer: TConfirmAnswer;
  Prompt: string;
begin
  { Task thread. Everything that touches a control -- the checkbox read
    included -- happens inside the Synchronize; a control property is not
    a thread-safe field just because it is a Boolean. }
  Prompt := Format('PasClaw wants to run %s on %s.%s%s%sAllow it?' + sLineBreak +
                   '(Yes = this once, Yes to All = always on this site, No = decline)',
                   [ToolName, Host, sLineBreak, Copy(ArgsJSON, 1, 400), sLineBreak]);
  Answer := caDeny;
  TThread.Synchronize(nil,
    procedure
    begin
      { The checkbox is the master switch; off means allow without asking. }
      if not FConfirm.IsChecked then
      begin
        Answer := caAllowOnce;
        Exit;
      end;
      { Synchronous dialog, so the task thread gets a real answer. }
      case TDialogServiceSync.MessageDialog(Prompt, TMsgDlgType.mtConfirmation,
             [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbYesToAll, TMsgDlgBtn.mbNo],
             TMsgDlgBtn.mbNo, 0) of
        mrYes:      Answer := caAllowOnce;
        mrYesToAll: Answer := caAllowHost;
      else
        Answer := caDeny;
      end;
    end);
  Result := Answer;
end;

{ ================================================================ form }

procedure TFormMain.FormCreate(Sender: TObject);
  function Btn(const Text: string; W: Single; Handler: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := TopBar;
    Result.Align := TAlignLayout.Left;
    Result.Width := W;
    Result.Text := Text;
    Result.OnClick := Handler;
    Result.Margins.Right := 4;
  end;
begin
  FHome := GetHome;
  FTabs := TObjectList<TBrowserTab>.Create(True);

  (* WebView2 reads its profile directory from this variable at first use.
     Under PASCLAW_HOME rather than %LOCALAPPDATA%, so logins persist
     alongside the rest of the workspace and travel with it. Must be set
     before the first TWebBrowser is created. *)
  SetEnvironmentVariable('WEBVIEW2_USER_DATA_FOLDER',
    PChar(IncludeTrailingPathDelimiter(FHome) + 'workspace\browser\webview2'));

  FBack    := Btn('◀', 36, OnBack);
  FFwd     := Btn('▶', 36, OnFwd);
  FReload  := Btn('↻', 36, OnReload);
  FNewTab  := Btn('+ Tab', 64, OnNewTab);
  FCloseTab := Btn('✕ Tab', 64, OnCloseTab);

  AddTab(HomePage);
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  FTabs.Free;   { each tab's destructor saves its session }
end;

procedure TFormMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
var
  T: TBrowserTab;
begin
  CanClose := True;
  for T in FTabs do
    if T.FBusy then
    begin
      CanClose := TDialogServiceSync.MessageDialog(
        'PasClaw is still working in a tab. Close anyway?',
        TMsgDlgType.mtConfirmation, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo],
        TMsgDlgBtn.mbNo, 0) = mrYes;
      Exit;
    end;
end;

function TFormMain.ActiveTab: TBrowserTab;
var
  T: TBrowserTab;
begin
  Result := nil;
  for T in FTabs do
    if T.Item = Tabs.ActiveTab then Exit(T);
end;

procedure TFormMain.AddTab(const URL: string);
var
  T: TBrowserTab;
begin
  T := TBrowserTab.Create(Self, Tabs, FHome);
  FTabs.Add(T);
  Tabs.ActiveTab := T.Item;
  T.NavigateTo(URL);
end;

procedure TFormMain.OnNewTab(Sender: TObject);
begin
  AddTab(HomePage);
end;

procedure TFormMain.OnCloseTab(Sender: TObject);
var
  T: TBrowserTab;
  Idx: Integer;
begin
  T := ActiveTab;
  if (T = nil) or (FTabs.Count <= 1) then Exit;
  if T.FBusy then Exit;
  Idx := FTabs.IndexOf(T);
  T.Item.Free;          { the FMX item and its children }
  FTabs.Delete(Idx);    { owns T -> frees it -> saves its session }
  if Tabs.TabCount > 0 then
    Tabs.ActiveTab := Tabs.Tabs[Tabs.TabCount - 1];
end;

procedure TFormMain.OnBack(Sender: TObject);
begin
  if ActiveTab <> nil then ActiveTab.Browser.GoBack;
end;

procedure TFormMain.OnFwd(Sender: TObject);
begin
  if ActiveTab <> nil then ActiveTab.Browser.GoForward;
end;

procedure TFormMain.OnReload(Sender: TObject);
begin
  if ActiveTab <> nil then ActiveTab.Browser.Reload;
end;

end.
