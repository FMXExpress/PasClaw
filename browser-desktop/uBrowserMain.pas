(*
  uBrowserMain - the PasClaw Browser (browser-desktop/): tabs of WebView2 with a PasClaw chat
  beside each, where the agent can read the page and change it.

  Delphi 11+ / FMX / Windows. Compiled blind in this repository -- there is
  no Delphi in CI -- so everything that can be wrong in an interesting way
  lives BELOW this unit in FPC-compilable units with tests:

    PasClaw.Browser.Bridge    IBrowserBridge, TSwitchingBridge, the WebView2
                              quoting quirk
    PasClaw.Browser.Tools     the six page tools
    PasClaw.Browser.Hooks     page context per turn, confirm-before-mutate
    PasClaw.Browser.Session   per-tab history, persisted as JSON

  This unit is the glue. ONE TPasClawAgent for the whole app -- the
  component is one-per-process, its constructor raises EPasClawInstance on
  a second live instance -- with the six tools and two hooks registered
  once against a TSwitchingBridge. One TBrowserTab per tab holds a
  TWebBrowser, its own bridge over that control, and its own session.
  "Each tab is its own session" is literal: the history handed to the
  agent for a turn is that tab's history and nothing else, and the page
  context stamped on each message is that tab's page. What is shared is
  the engine, not the conversation.

  TURNS RUN ONE AT A TIME, on a single worker thread (TTurnWorker). A tab
  that sends while another tab's turn is running is queued and says so.
  Before each turn the worker points the switching bridge at the tab's
  real bridge; after, it clears it. The agent loop, every tool's Run and
  every hook fire on the worker thread. OnText and friends arrive there
  too and are queued to the UI, tagged with the worker so they can be
  discarded wholesale at shutdown.

  EVAL LIFETIME. The bridge marshals EvaluateJavaScript to the UI thread
  and waits on an event with a timeout. The engine's completion callback
  may fire AFTER the timeout -- a slow page finishes eventually -- so the
  event must outlive the wait. It lives in a refcounted TEvalWaiter that
  the callback closure holds; the last holder frees it. Nothing is freed
  while a callback can still reach it.

  SHUTDOWN. Closing the window while a turn is in flight is a two-step:
  the switching bridge is shut down so every further page call fails at
  once with "the application is closing", queued turns are dropped, and
  the window stays open with a status line until the in-flight turn
  returns; then it closes itself. FormDestroy therefore always finds the
  worker idle, joins it, and frees the agent and the tabs in that order.
  A second close while waiting offers an immediate exit, which saves the
  sessions and ends the process without running destructors -- the one
  honest way out of a provider call that will not return.

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
  System.SyncObjs, System.Generics.Collections,
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
  TFormMain   = class;

  (* Holds the completion of one EvaluateJavaScript call. Refcounted so
     the engine's callback -- which may run after the waiter has given up
     -- always finds a live object. Complete after Wait has returned is a
     harmless no-op; Wait after Complete returns at once. *)
  IEvalWaiter = interface
    ['{A5E7C1D2-6B3F-4C8A-9D0E-2F1B7A4C9E63}']
    procedure Complete(const AResult: string);
    function  Wait(TimeoutMs: Integer; out AResult: string): Boolean;
  end;

  TEvalWaiter = class(TInterfacedObject, IEvalWaiter)
  private
    FDone:   TEvent;
    FLock:   TCriticalSection;
    FResult: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Complete(const AResult: string);
    function  Wait(TimeoutMs: Integer; out AResult: string): Boolean;
  end;

  (* IBrowserBridge over one TWebBrowser. Lives with the tab. The tools
     never hold it directly -- they hold the form's TSwitchingBridge, which
     points here only while this tab's turn is running. Every method may
     be called from the worker thread and never from the UI thread. *)
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

  { One queued turn: which tab, and the history snapshot it was sent with. }
  TTurnRequest = class
  public
    Tab:     TBrowserTab;
    History: TMessageArray;
  end;

  (* The single thread every turn runs on. A FIFO of requests, a wake
     event, and a Running flag; the form's RunTurn does the work. Owned by
     the form and only ever freed when idle. *)
  TTurnWorker = class(TThread)
  private
    FForm:    TFormMain;
    FQueue:   TObjectList<TTurnRequest>;
    FLock:    TCriticalSection;
    FWake:    TEvent;
    FRunning: Boolean;
    function  Pop: TTurnRequest;
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;
  public
    constructor Create(AForm: TFormMain);
    destructor Destroy; override;
    { Returns how many requests are ahead of this one, 0 = runs now. }
    function  Push(Req: TTurnRequest): Integer;
    { Drop every request not yet started; returns their tabs. }
    function  DiscardQueued: TArray<TBrowserTab>;
    function  IsIdle: Boolean;
    function  IsBusy: Boolean;
  end;

  TBrowserTab = class
  private
    FForm:      TFormMain;      { not owned }
    FItem:      TTabItem;
    FBrowser:   TWebBrowser;
    FAddress:   TEdit;
    FTranscript: TMemo;
    FInput:     TEdit;
    FSend:      TButton;
    FConfirm:   TCheckBox;
    FStatus:    TLabel;
    FSession:   TBrowserSession;
    FBridge:    IBrowserBridge;
    FBridgeObj: TFmxBridge;
    FBusy:      Boolean;        { queued or running; UI thread only }
    FURL:       string;         { cached on the UI thread by OnDidFinishLoad }
    FTitle:     string;
    FHome:      string;
    FPendingUser: string;       { the message of the turn in flight }
    procedure BuildUI(Owner: TComponent; Host: TTabControl);
    procedure OnDidFinishLoad(ASender: TObject);
    procedure OnGo(Sender: TObject);
    procedure OnAddressKey(Sender: TObject; var Key: Word; var KeyChar: Char; Shift: TShiftState);
    procedure OnSendClick(Sender: TObject);
    procedure OnInputKey(Sender: TObject; var Key: Word; var KeyChar: Char; Shift: TShiftState);
    procedure AppendLine(const S: string);
    procedure SetBusy(B: Boolean; const Status: string = '');
    procedure RefreshTitle;
    procedure SaveSession;
  public
    constructor Create(AForm: TFormMain; Host: TTabControl; const Home: string;
                       const SessionId: string = '');
    destructor Destroy; override;
    procedure NavigateTo(const URL: string);
    procedure SendMessage(const Text: string);
    { ---- called by the form, on the UI thread, around a turn ---- }
    procedure TurnStarted;
    procedure TurnFinished(Ok: Boolean; const Reply, Err: string);
    procedure TurnDropped;
    { ---- called by the form from the worker thread; each queues to the UI ---- }
    procedure StreamText(const Text: string);
    procedure ShowToolCall(const Name: string);
    procedure ShowError(const Msg: string);
    function  AskConfirm(const ToolName, ArgsJSON, Host: string): TConfirmAnswer;
    property Item:    TTabItem read FItem;
    property Browser: TWebBrowser read FBrowser;
    property Session: TBrowserSession read FSession;
    property Bridge:  IBrowserBridge read FBridge;
    property Busy:    Boolean read FBusy;
  end;

  TFormMain = class(TForm)
    TopBar: TLayout;
    Tabs: TTabControl;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
  private
    FTabs:    TObjectList<TBrowserTab>;
    FHome:    string;
    FAgent:   TPasClawAgent;          { the one per process }
    FSwitch:  TSwitchingBridge;       { object pointer; FSwitchI keeps it alive }
    FSwitchI: IBrowserBridge;
    FWorker:  TTurnWorker;
    FRunningTab: TBrowserTab;         { set/cleared on the worker thread }
    FClosing: Boolean;                { UI thread }
    FNewTab, FCloseTab, FBack, FFwd, FReload: TButton;
    procedure OnNewTab(Sender: TObject);
    procedure OnCloseTab(Sender: TObject);
    procedure OnBack(Sender: TObject);
    procedure OnFwd(Sender: TObject);
    procedure OnReload(Sender: TObject);
    function  ActiveTab: TBrowserTab;
    procedure AddTab(const URL: string);
    { agent events; worker thread; forwarded to the running tab }
    procedure AgentText(Sender: TObject; const Text: string);
    procedure AgentToolCall(Sender: TObject; const Name, ArgsJSON: string);
    procedure AgentError(Sender: TObject; const Msg: string);
    function  AgentConfirm(const ToolName, ArgsJSON, Host: string): TConfirmAnswer;
    procedure SaveAllSessions;
  public
    { Called by the worker thread for each request. }
    procedure RunTurn(Req: TTurnRequest);
    { Called by a tab on the UI thread; returns the queue position. }
    function  Enqueue(Tab: TBrowserTab; const History: TMessageArray): Integer;
  end;

var
  FormMain: TFormMain;

implementation

{$R *.fmx}

uses
  PasClaw.Config;   { GetHome -- the user's PASCLAW_HOME, shared with the CLI }

const
  HomePage = 'https://github.com/FMXExpress/PasClaw';
  StatusIdle      = 'PasClaw';
  StatusWorking   = 'PasClaw is working…';
  StatusQueued    = 'Waiting for another tab''s turn to finish…';
  StatusClosing   = 'Finishing the current reply, then closing…';

{ ================================================================ waiter }

constructor TEvalWaiter.Create;
begin
  inherited Create;
  FDone := TEvent.Create(nil, True, False, '');
  FLock := TCriticalSection.Create;
end;

destructor TEvalWaiter.Destroy;
begin
  FLock.Free;
  FDone.Free;
  inherited;
end;

procedure TEvalWaiter.Complete(const AResult: string);
begin
  FLock.Enter;
  try
    FResult := AResult;
  finally
    FLock.Leave;
  end;
  FDone.SetEvent;
end;

function TEvalWaiter.Wait(TimeoutMs: Integer; out AResult: string): Boolean;
begin
  AResult := '';
  Result := FDone.WaitFor(TimeoutMs) = wrSignaled;
  if Result then
  begin
    FLock.Enter;
    try
      AResult := FResult;
    finally
      FLock.Leave;
    end;
  end;
end;

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
  W:   IEvalWaiter;
  Res: string;
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
      The agent always calls from the worker, so reaching here is a bug in
      the caller; say so instead of hanging the app. }
    Err := 'bridge called on the UI thread';
    Exit;
  end;

  (* W is captured by both closures below. Anonymous methods keep their
     captured frame alive for as long as any of them exists, so the waiter
     -- and the TEvent inside it -- outlives a callback that fires after
     the timeout. There is nothing here to free early. *)
  W := TEvalWaiter.Create;
  TThread.Queue(TThread.CurrentThread,
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
            W.Complete(AResult);
          end);
      except
        on E: Exception do
          W.Complete('');
      end;
    end);
  if not W.Wait(TimeoutMs, Res) then
  begin
    Err := Format('script did not complete within %d ms', [TimeoutMs]);
    Exit;
  end;
  { One layer of JSON quoting off, per the bridge contract. }
  Value := UnwrapJsString(Res);
  Result := True;
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
  TThread.Queue(TThread.CurrentThread,
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

{ ================================================================ worker }

constructor TTurnWorker.Create(AForm: TFormMain);
begin
  FForm  := AForm;
  FQueue := TObjectList<TTurnRequest>.Create(True);
  FLock  := TCriticalSection.Create;
  FWake  := TEvent.Create(nil, False, False, '');
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TTurnWorker.Destroy;
begin
  { Terminate + wake, then the inherited WaitFor. The form only frees us
    when idle, so this returns promptly; see FormCloseQuery. }
  Terminate;
  FWake.SetEvent;
  WaitFor;                          { joins the thread; idle, so immediate }
  TThread.RemoveQueuedEvents(Self); { anything still queued to the UI from this thread }
  inherited;
  FQueue.Free;
  FLock.Free;
  FWake.Free;
end;

procedure TTurnWorker.TerminatedSet;
begin
  inherited;
  if FWake <> nil then FWake.SetEvent;
end;

function TTurnWorker.Push(Req: TTurnRequest): Integer;
begin
  FLock.Enter;
  try
    FQueue.Add(Req);
    Result := FQueue.Count - 1;
    if FRunning then Inc(Result);
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

function TTurnWorker.Pop: TTurnRequest;
begin
  FLock.Enter;
  try
    if FQueue.Count = 0 then Exit(nil);
    Result := FQueue.Extract(FQueue[0]);
    FRunning := True;
  finally
    FLock.Leave;
  end;
end;

function TTurnWorker.DiscardQueued: TArray<TBrowserTab>;
var
  i: Integer;
begin
  FLock.Enter;
  try
    SetLength(Result, FQueue.Count);
    for i := 0 to FQueue.Count - 1 do
      Result[i] := FQueue[i].Tab;
    FQueue.Clear;
  finally
    FLock.Leave;
  end;
end;

function TTurnWorker.IsIdle: Boolean;
begin
  FLock.Enter;
  try
    Result := (not FRunning) and (FQueue.Count = 0);
  finally
    FLock.Leave;
  end;
end;

function TTurnWorker.IsBusy: Boolean;
begin
  Result := not IsIdle;
end;

procedure TTurnWorker.Execute;
var
  Req: TTurnRequest;
begin
  while not Terminated do
  begin
    Req := Pop;
    if Req = nil then
    begin
      FWake.WaitFor(INFINITE);
      Continue;
    end;
    try
      FForm.RunTurn(Req);
    finally
      Req.Free;
      FLock.Enter;
      try
        FRunning := False;
      finally
        FLock.Leave;
      end;
    end;
  end;
end;

{ ================================================================ tab }

constructor TBrowserTab.Create(AForm: TFormMain; Host: TTabControl;
                               const Home, SessionId: string);
var
  Id: string;
begin
  inherited Create;
  FForm := AForm;
  FHome := Home;
  if SessionId = '' then Id := NewBrowserSessionId else Id := SessionId;
  FSession := TBrowserSession.Create(Id);
  FSession.LoadFromFile(SessionFilePath(FHome, Id));   { False for a new tab; fine }

  BuildUI(AForm, Host);

  { The bridge is owned by interface reference; keep the object pointer
    too so OnDidFinishLoad can signal it without a cast. The form's
    switching bridge points at this one only while our turn runs. }
  FBridgeObj := TFmxBridge.Create(Self);
  FBridge := FBridgeObj;

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
  SaveSession;
  FBridgeObj := nil;
  FBridge := nil;       { releases the bridge }
  FSession.Free;
  { FItem and everything parented to it are owned by the form. }
  inherited;
end;

procedure TBrowserTab.SaveSession;
begin
  FSession.SaveToFile(SessionFilePath(FHome, FSession.Id));
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
  FStatus.Text := StatusIdle;

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

procedure TBrowserTab.SetBusy(B: Boolean; const Status: string);
begin
  FBusy := B;
  FSend.Enabled := not B;
  FInput.Enabled := not B;
  if Status <> '' then FStatus.Text := Status
  else if B then FStatus.Text := StatusWorking
  else FStatus.Text := StatusIdle;
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
  Msg:  string;
  Hist: TMessageArray;
  Ahead: Integer;
begin
  Msg := Trim(Text);
  if (Msg = '') or FBusy then Exit;
  if FForm.FClosing then
  begin
    AppendLine('[not sent: the application is closing]');
    Exit;
  end;
  FInput.Text := '';
  AppendLine('You: ' + Msg);
  AppendLine('PasClaw: ');

  { The whole transcript plus this message goes in the turn; the component
    keeps nothing. The session itself is only appended to when the turn
    comes back, so a dropped or failed turn leaves no half-exchange in the
    saved history. Snapshot on the UI thread; the worker owns the copy. }
  Hist := FSession.HistoryCopy;
  SetLength(Hist, Length(Hist) + 1);
  Hist[High(Hist)] := MakeMessage(mrUser, Msg);
  FPendingUser := Msg;

  Ahead := FForm.Enqueue(Self, Hist);
  if Ahead < 0 then Exit;   { refused: closing; Enqueue already said so }
  if Ahead > 0 then SetBusy(True, StatusQueued) else SetBusy(True);
end;

procedure TBrowserTab.TurnStarted;
begin
  SetBusy(True);
end;

procedure TBrowserTab.TurnFinished(Ok: Boolean; const Reply, Err: string);
begin
  if Ok then
  begin
    FSession.AppendUser(FPendingUser);
    FSession.AppendAssistant(Reply);
    { StreamText put the reply into the memo already; make sure the final
      text is what is recorded in case streaming was partial. }
    if FTranscript.Lines.Count > 0 then
      FTranscript.Lines[FTranscript.Lines.Count - 1] := 'PasClaw: ' + Reply;
  end
  else
    AppendLine('[error] ' + Err);
  FPendingUser := '';
  SaveSession;
  SetBusy(False);
end;

procedure TBrowserTab.TurnDropped;
begin
  AppendLine('[not sent: the application is closing]');
  FPendingUser := '';
  SetBusy(False);
end;

procedure TBrowserTab.StreamText(const Text: string);
begin
  { Worker thread. Append the chunk to the last memo line. Tagged with the
    worker so a pending chunk is discarded with it at shutdown. }
  TThread.Queue(TThread.CurrentThread,
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

procedure TBrowserTab.ShowToolCall(const Name: string);
begin
  TThread.Queue(TThread.CurrentThread,
    procedure
    begin
      FStatus.Text := 'PasClaw: ' + Name;
    end);
end;

procedure TBrowserTab.ShowError(const Msg: string);
begin
  TThread.Queue(TThread.CurrentThread,
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
  { Worker thread. Everything that touches a control -- the checkbox read
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
      { Bring the asking tab forward so the dialog is about what is seen. }
      FForm.Tabs.ActiveTab := FItem;
      { Synchronous dialog, so the worker thread gets a real answer. }
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

  (* The one agent, on the user's own PASCLAW_HOME: LoadConfigFromDisk
     stays True, so the provider, memory, facts and AGENTS.md are the same
     ones the CLI and web UI use. The tools and hooks are registered once,
     against the switching bridge; RunTurn points it at a tab per turn. *)
  FSwitch  := TSwitchingBridge.Create;
  FSwitchI := FSwitch;

  FAgent := TPasClawAgent.Create(nil);
  FAgent.OnText     := AgentText;
  FAgent.OnToolCall := AgentToolCall;
  FAgent.OnError    := AgentError;

  FAgent.RegisterTool(TBrowserPageTool.Create(FSwitchI));
  FAgent.RegisterTool(TBrowserFindTool.Create(FSwitchI));
  FAgent.RegisterTool(TBrowserNavigateTool.Create(FSwitchI));
  FAgent.RegisterTool(TBrowserClickTool.Create(FSwitchI));
  FAgent.RegisterTool(TBrowserFillTool.Create(FSwitchI));
  FAgent.RegisterTool(TBrowserEvalTool.Create(FSwitchI));

  FAgent.RegisterHook(TPageContextHook.Create(FSwitchI, True));
  FAgent.RegisterHook(TConfirmMutationHook.Create(FSwitchI, AgentConfirm));

  FWorker := TTurnWorker.Create(Self);

  FBack    := Btn('◀', 36, OnBack);
  FFwd     := Btn('▶', 36, OnFwd);
  FReload  := Btn('↻', 36, OnReload);
  FNewTab  := Btn('+ Tab', 64, OnNewTab);
  FCloseTab := Btn('✕ Tab', 64, OnCloseTab);

  AddTab(HomePage);
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  { Order matters. FormCloseQuery guarantees the worker is idle here, so
    joining it is immediate; then the agent (which frees the tools and
    hooks holding the switching bridge); then the tabs, whose bridges
    nothing can reach any more. }
  FreeAndNil(FWorker);
  FreeAndNil(FAgent);
  FSwitch := nil;
  FSwitchI := nil;
  FTabs.Free;   { each tab's destructor saves its session }
end;

procedure TFormMain.SaveAllSessions;
var
  T: TBrowserTab;
begin
  for T in FTabs do T.SaveSession;
end;

procedure TFormMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
var
  Dropped: TArray<TBrowserTab>;
  T: TBrowserTab;
begin
  if (FWorker = nil) or FWorker.IsIdle then
  begin
    CanClose := True;
    Exit;
  end;

  CanClose := False;
  if FClosing then
  begin
    { Second close while the in-flight turn is still out. The only thing
      that cannot be made to return is a provider call; offer the exit
      that is actually safe: save, then end the process without ever
      destroying the form under a live worker. Halt runs unit
      finalization, not component destructors. }
    if TDialogServiceSync.MessageDialog(
         'PasClaw is still finishing its last reply. Quit now without waiting?' + sLineBreak +
         'Open conversations are saved first; the reply in progress is lost.',
         TMsgDlgType.mtConfirmation, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo],
         TMsgDlgBtn.mbNo, 0) = mrYes then
    begin
      SaveAllSessions;
      Halt(0);
    end;
    Exit;
  end;

  if TDialogServiceSync.MessageDialog(
       'PasClaw is still working in a tab. Stop and close?',
       TMsgDlgType.mtConfirmation, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo],
       TMsgDlgBtn.mbNo, 0) <> mrYes then
    Exit;

  (* Wind down, do not tear down. From here every page call the in-flight
     turn makes fails at once, so it ends within a few tool calls instead
     of ten seconds of timeouts each; queued turns never start; and the
     window closes itself from RunTurn's completion when the worker is
     idle. *)
  FClosing := True;
  FSwitch.Shutdown;
  Dropped := FWorker.DiscardQueued;
  for T in Dropped do T.TurnDropped;
  for T in FTabs do
    if T.Busy then T.SetBusy(True, StatusClosing);
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
  if T.Busy then Exit;   { its bridge may be the switching bridge's target }
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

{ ---------------------------------------------------------------- turns }

function TFormMain.Enqueue(Tab: TBrowserTab; const History: TMessageArray): Integer;
var
  Req: TTurnRequest;
begin
  if FClosing then
  begin
    Tab.TurnDropped;
    Exit(-1);
  end;
  Req := TTurnRequest.Create;
  Req.Tab := Tab;
  Req.History := History;
  Result := FWorker.Push(Req);
end;

procedure TFormMain.RunTurn(Req: TTurnRequest);
var
  Tab: TBrowserTab;
  Reply, Err: string;
  Ok: Boolean;
begin
  { Worker thread. }
  Tab := Req.Tab;
  FRunningTab := Tab;
  FSwitch.SetCurrent(Tab.Bridge);   { ignored once Shutdown has run; the turn then fails fast }
  TThread.Queue(TThread.CurrentThread,
    procedure
    begin
      if not FClosing then Tab.TurnStarted;
    end);
  try
    try
      Ok := FAgent.ChatHistory(Req.History, Reply, Err);
    except
      on E: Exception do
      begin
        Ok := False;
        Err := E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    FSwitch.SetCurrent(nil);
    FRunningTab := nil;
  end;
  TThread.Queue(TThread.CurrentThread,
    procedure
    begin
      Tab.TurnFinished(Ok, Reply, Err);
      { The close the user asked for, now that nothing is in flight. }
      if FClosing and FWorker.IsIdle then Close;
    end);
end;

procedure TFormMain.AgentText(Sender: TObject; const Text: string);
begin
  if FRunningTab <> nil then FRunningTab.StreamText(Text);
end;

procedure TFormMain.AgentToolCall(Sender: TObject; const Name, ArgsJSON: string);
begin
  if FRunningTab <> nil then FRunningTab.ShowToolCall(Name);
end;

procedure TFormMain.AgentError(Sender: TObject; const Msg: string);
begin
  if FRunningTab <> nil then FRunningTab.ShowError(Msg);
end;

function TFormMain.AgentConfirm(const ToolName, ArgsJSON, Host: string): TConfirmAnswer;
begin
  { Worker thread. Deny without a dialog once we are closing: the hook
    tells the model, the turn ends, the window can go. }
  if FSwitch.IsClosing or (FRunningTab = nil) then
    Exit(caDeny);
  Result := FRunningTab.AskConfirm(ToolName, ArgsJSON, Host);
end;

end.
