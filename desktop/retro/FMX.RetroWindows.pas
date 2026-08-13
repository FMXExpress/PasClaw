unit FMX.RetroWindows;

{ Retro window manager for FireMonkey.

  TRetroDesktop  - fullscreen "desktop" container styled by 'retrodesktopstyle'
  TRetroWindow   - draggable/resizable window with retro chrome, styled by
                   'retrowindowstyle' (title bar, caption buttons, frame)
  TRetroTaskbar  - the desktop's bar, styled by 'retrotaskbarstyle'. Its
                   SHAPE follows the style: a Windows taskbar, a NeXTSTEP
                   Dock, a BeOS corner Deskbar, an Amiga screen title, a
                   GEM/Mac menu bar or an OS/2 WarpCenter tray
                   (see TRetroBarKind)

  All visuals come from the .style files in FMXStyles/Retro; these controls
  only implement behavior (drag, 8-direction resize, z-order, activation,
  minimize/maximize/close). Apply a style app-wide with
  TStyleManager.SetStyleFromFile or through a TStyleBook. }

interface

uses
  System.Classes, System.SysUtils, System.Types, System.UITypes, System.Math,
  System.Generics.Collections, FMX.Types, FMX.Controls, FMX.Objects,
  FMX.StdCtrls, FMX.Layouts, FMX.Graphics;

type
  TRetroDesktop = class;
  TRetroTaskbar = class;

  TRetroWindowState = (rwsNormal, rwsMinimized, rwsMaximized);

  { Which screen edge a taskbar / launch bar docks to. Windows-style bars
    sit at the bottom; Mac OS 9, Apple System and OS/2 Warp put theirs at
    the top, and those styles tag themselves so the default follows the
    look (see TRetroDesktop.PreferredBarEdge). }
  TRetroBarEdge = (rbeTop, rbeBottom, rbeLeft, rbeRight);

  { The SHAPE of the bar, which differs between these systems far more than
    its edge does. A Windows taskbar is only one of the answers:

      rbkTaskbar      launcher at the near end, one button per window
                      (Windows 95 onward, Photon's shelf)
      rbkDock         vertical strip of app tiles, no launcher
                      (NeXTSTEP's Dock, on the right edge)
      rbkCorner       small panel anchored in a corner, apps stacked
                      vertically under the launcher, clock at the foot
                      (BeOS's Deskbar, top-right). FLOATS: it reserves no
                      space, so windows may pass under it
      rbkScreenTitle  status text at the left, depth gadgets at the right,
                      no launcher and no per-window buttons
                      (the Amiga Workbench screen title bar)
      rbkMenuBar      menu titles at the left, running apps and the clock
                      at the right (GEM, Mac OS 9's menu bar)
      rbkTray         launcher and apps at the left, clock at the right
                      (OS/2 Warp 4's WarpCenter) }
  TRetroBarKind = (rbkTaskbar, rbkDock, rbkCorner, rbkScreenTitle,
                   rbkMenuBar, rbkTray);

  TResizeEdge = (reNone, reLeft, reTop, reRight, reBottom,
    reTopLeft, reTopRight, reBottomLeft, reBottomRight);

  TRetroWindow = class(TStyledControl)
  private
    FCaption: string;
    FActive: Boolean;
    FWindowState: TRetroWindowState;
    FCollapsed: Boolean;
    FExpandedHeight: Single;
    FShadeCollapse: Boolean;
    FRestoreBounds: TRectF;
    FSizeable: Boolean;
    FShowClose, FShowMin, FShowMax: Boolean;
    FOnClose: TNotifyEvent;
    FOnActiveChanged: TNotifyEvent;
    FShieldForwarding: Boolean;
    FClient: TLayout;
    FShield: TLayout;
    FResizeGrip: TLayout;   { our own control -- see the note in Create }
    FDesktop: TRetroDesktop;
    { style parts }
    FCaptionText, FInactiveCaption: TText;
    FInactiveOverlay: TControl;
    FFrameInactive: TControl;
    FTitleBar: TControl;
    FFrameLayout: TControl;
    FCloseButton, FMinButton, FMaxButton, FSysMenuButton: TCustomButton;
    { drag/resize state }
    FDragging: Boolean;
    FDragUnsnapped: Boolean;
    FResizeEdge: TResizeEdge;
    FDownPos: TPointF;      // in desktop coordinates
    FDownLocal: TPointF;
    FDownBounds: TRectF;
    procedure SetCaption(const Value: string);
    procedure SetActive(const Value: Boolean);
    procedure SetSizeable(const Value: Boolean);
    procedure SetShowClose(const Value: Boolean);
    procedure SetShowMin(const Value: Boolean);
    procedure SetShowMax(const Value: Boolean);
    procedure CloseClick(Sender: TObject);
    procedure MinClick(Sender: TObject);
    procedure MaxClick(Sender: TObject);
    procedure ShieldMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure ShieldMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Single);
    procedure ShieldMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure UpdateShield;
    procedure GripMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure GripMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Single);
    procedure GripMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    function LocalFrom(Sender: TObject; X, Y: Single): TPointF;
    procedure UpdateGrip;
    function TitleBarHeight: Single;
    function FrameSize: Single;
    function EdgeAt(const ALocal: TPointF): TResizeEdge;
    function PointInDesktop(const ALocal: TPointF): TPointF;
    procedure UpdateButtons;
  protected
    function GetDefaultStyleLookupName: string; override;
    procedure ApplyStyle; override;
    procedure FreeStyle; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Single); override;
    procedure DoMouseLeave; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Close;
    procedure Minimize;
    procedure Restore;
    procedure ToggleMaximize;
    procedure ToggleCollapse;
    procedure Reposition;
    property Collapsed: Boolean read FCollapsed;
    property Client: TLayout read FClient;
    property Desktop: TRetroDesktop read FDesktop;
    property WindowState: TRetroWindowState read FWindowState;
  published
    property Caption: string read FCaption write SetCaption;
    property Active: Boolean read FActive write SetActive;
    property Sizeable: Boolean read FSizeable write SetSizeable default True;
    property ShowClose: Boolean read FShowClose write SetShowClose
      default True;
    property ShowMin: Boolean read FShowMin write SetShowMin default True;
    property ShowMax: Boolean read FShowMax write SetShowMax default True;
    property OnClose: TNotifyEvent read FOnClose write FOnClose;
    property OnActiveChanged: TNotifyEvent read FOnActiveChanged
      write FOnActiveChanged;
  end;

  { A desktop icon styled by 'retrodesktopiconstyle'. Double-click fires
    OnOpen. }
  TRetroDesktopIcon = class(TStyledControl)
  private
    FCaption: string;
    FCaptionText: TText;
    FSelectedText: TText;
    FSelection: TControl;
    FOnOpen: TNotifyEvent;
    FDragging: Boolean;
    FMoved: Boolean;
    FDownPos: TPointF;      { pointer at mouse-down, in desktop coords }
    FStartPos: TPointF;     { icon position at mouse-down }
    procedure SetCaption(const Value: string);
    procedure UpdateSelection;
    function DesktopOf: TRetroDesktop;
    function PointInDesktop(X, Y: Single): TPointF;
  protected
    function GetDefaultStyleLookupName: string; override;
    procedure ApplyStyle; override;
    procedure FreeStyle; override;
    procedure DblClick; override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Single); override;
  public
    constructor Create(AOwner: TComponent); override;
    { pull the icon back inside the desktop's usable area -- called when the
      desktop resizes or the taskbar moves to another edge }
    procedure Reposition;
  published
    property Caption: string read FCaption write SetCaption;
    property OnOpen: TNotifyEvent read FOnOpen write FOnOpen;
  end;

  TRetroTaskbar = class(TStyledControl)
  private
    FDesktop: TRetroDesktop;
    FMenuButton: TButton;
    FContent: TLayout;
    FEdge: TRetroBarEdge;
    FEdgeExplicit: Boolean;
    FKind: TRetroBarKind;
    FKindExplicit: Boolean;
    FButtons: TDictionary<TRetroWindow, TButton>;
    FOrder: TList<TButton>;          { task buttons in creation order }
    FTitles: TList<TButton>;         { menu titles, rbkMenuBar only }
    FStatus: TLabel;                 { screen title text, rbkScreenTitle }
    FGadgets: TLayout;
    FFrontGadget, FBackGadget: TButton;
    FClock: TLabel;
    FClockTimer: TTimer;
    FStatusText: string;
    procedure TaskButtonClick(Sender: TObject);
    procedure FrontGadgetClick(Sender: TObject);
    procedure BackGadgetClick(Sender: TObject);
    procedure ClockTick(Sender: TObject);
    procedure SetEdge(const Value: TRetroBarEdge);
    procedure SetKind(const Value: TRetroBarKind);
    procedure SetStatusText(const Value: string);
    procedure LayoutBar;
    procedure LayoutTaskButton(AButton: TButton; AIndex: Integer);
  protected
    function GetDefaultStyleLookupName: string; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure AddWindowButton(AWindow: TRetroWindow);
    procedure RemoveWindowButton(AWindow: TRetroWindow);
    procedure UpdateWindowButton(AWindow: TRetroWindow);
    { A menu title for rbkMenuBar. Registering titles is harmless under any
      other kind -- they are simply hidden. }
    function AddMenuTitle(const ACaption: string): TButton;
    function IsVertical: Boolean;
    { True when the bar reserves no room on the desktop (the BeOS Deskbar
      floats above the windows rather than pushing them aside). }
    function Floats: Boolean;
    { False for the kinds that carried no per-window buttons, so the desktop
      knows to fall back to minimized icons. }
    function ShowsWindowButtons: Boolean;
    { Re-run the bar's layout -- the desktop calls this when it resizes,
      since a floating panel is positioned rather than aligned. }
    procedure Relayout;
    { Refresh a screen-title bar's left-hand text (the desktop calls this
      when the active window changes). }
    procedure UpdateStatus;
    { Applied when a style loads. Neither counts as an explicit choice, so
      an edge or kind the app sets itself keeps winning across switches. }
    procedure SetEdgeFromStyle(AEdge: TRetroBarEdge);
    procedure SetKindFromStyle(AKind: TRetroBarKind);
    property EdgeIsExplicit: Boolean read FEdgeExplicit;
    property KindIsExplicit: Boolean read FKindExplicit;
    { The launcher button. Deliberately generic -- it reads 'Menu' with a
      hamburger glyph rather than any vendor's wordmark or logo. Hidden
      under the kinds whose systems had no launcher. }
    property MenuButton: TButton read FMenuButton;
    property Desktop: TRetroDesktop read FDesktop write FDesktop;
    { Left-hand text of a screen-title bar. Empty means the desktop fills in
      the active window's caption, which is what Workbench does. }
    property StatusText: string read FStatusText write SetStatusText;
  published
    property Edge: TRetroBarEdge read FEdge write SetEdge default rbeBottom;
    property Kind: TRetroBarKind read FKind write SetKind default rbkTaskbar;
  end;

  TRetroDesktop = class(TStyledControl)
  private
    FWindows: TList<TRetroWindow>;
    FIcons: TList<TRetroDesktopIcon>;
    FMinIcons: TDictionary<TRetroWindow, TRetroDesktopIcon>;
    FActiveWindow: TRetroWindow;
    FTaskbar: TRetroTaskbar;
    FCascade: Integer;
    FEdgeMaximize: Boolean;
    function GetWindow(Index: Integer): TRetroWindow;
    function GetWindowCount: Integer;
    procedure MinIconOpen(Sender: TObject);
    procedure KeepBarOnTop;
  protected
    function GetDefaultStyleLookupName: string; override;
    procedure ApplyStyle; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Single); override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function CreateWindow(const ACaption: string;
      AWidth: Single = 360; AHeight: Single = 280): TRetroWindow;
    function CreateIcon(const ACaption: string): TRetroDesktopIcon;
    procedure NotifyMinimized(AWindow: TRetroWindow);
    procedure NotifyRestored(AWindow: TRetroWindow);
    procedure ActivateWindow(AWindow: TRetroWindow);
    procedure RemoveWindow(AWindow: TRetroWindow);
    function EnsureTaskbar: TRetroTaskbar;
    function CreateTaskbar: TRetroTaskbar; overload;
    function CreateTaskbar(AEdge: TRetroBarEdge): TRetroTaskbar; overload;
    function PreferredBarEdge: TRetroBarEdge;
    function PreferredBarKind: TRetroBarKind;
    { Amiga depth gadgets: cycle the window at the back to the front, or
      push the active one behind everything else. }
    procedure BringBottomToFront;
    procedure SendActiveToBack;
    function WindowArea: TRectF;
    { pull every desktop icon back inside WindowArea }
    procedure RepositionIcons;
    { re-grid the icons from the top-left of the usable area }
    procedure ArrangeIcons;
    property ActiveWindow: TRetroWindow read FActiveWindow;
    { drag a window against the top edge to maximize it (wm.js behavior) }
    property EdgeMaximize: Boolean read FEdgeMaximize write FEdgeMaximize;
    property Taskbar: TRetroTaskbar read FTaskbar;
    property WindowCount: Integer read GetWindowCount;
    property Windows[Index: Integer]: TRetroWindow read GetWindow;
  end;

procedure Register;

implementation

const
  EdgeMargin = 6;
  MinWindowWidth = 120;
  MinWindowHeight = 60;
  IconDragThreshold = 4;   { px of slop before a click becomes a drag }
  IconGridX = 88;
  IconGridY = 82;
  IconGridMargin = 16;

procedure Register;
begin
  RegisterComponents('Retro', [TRetroDesktop, TRetroWindow, TRetroTaskbar,
    TRetroDesktopIcon]);
end;

{ TRetroWindow }

constructor TRetroWindow.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FSizeable := True;
  FShowClose := True;
  FShowMin := True;
  FShowMax := True;
  FActive := False;
  FWindowState := rwsNormal;
  CanFocus := False;
  AutoCapture := True;
  HitTest := True;
  Width := 360;
  Height := 280;
  FClient := TLayout.Create(Self);
  FClient.Stored := False;
  FClient.Align := TAlignLayout.Client;
  FClient.HitTest := False;
  FClient.Parent := Self;
  // Bottom-right resize grip. This is deliberately NOT a style part: a
  // style object sits below the content layer in hit order, so app content
  // (a status bar, a memo) would swallow the drag, and on a short or
  // collapsed window it would overlap the title bar and steal clicks from
  // the caption buttons. Created after FClient so it hit-tests above the
  // content, and before FShield so activation still wins.
  FResizeGrip := TLayout.Create(Self);
  FResizeGrip.Stored := False;
  FResizeGrip.Cursor := crSizeNWSE;
  FResizeGrip.HitTest := True;
  FResizeGrip.AutoCapture := True;
  FResizeGrip.OnMouseDown := GripMouseDown;
  FResizeGrip.OnMouseMove := GripMouseMove;
  FResizeGrip.OnMouseUp := GripMouseUp;
  FResizeGrip.Parent := Self;
  // Transparent click-catcher shown while the window is inactive so a
  // click anywhere on the window (not just the title bar) activates it.
  FShield := TLayout.Create(Self);
  FShield.Stored := False;
  FShield.Align := TAlignLayout.Contents;
  FShield.HitTest := True;
  FShield.AutoCapture := True;
  FShield.Visible := False;
  FShield.OnMouseDown := ShieldMouseDown;
  FShield.OnMouseMove := ShieldMouseMove;
  FShield.OnMouseUp := ShieldMouseUp;
  FShield.Parent := Self;
end;

procedure TRetroWindow.ShieldMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  // The shield covers the whole window, so its local coordinates match the
  // window's. Activate, then forward into the window's own mouse handling
  // so a single click can also start a title-bar drag or an edge resize.
  FShieldForwarding := True;
  if FDesktop <> nil then
    FDesktop.ActivateWindow(Self)
  else
    Active := True;
  if Button = TMouseButton.mbLeft then
    MouseDown(Button, Shift, X, Y)
  else
  begin
    FShieldForwarding := False;
    UpdateShield;
  end;
end;

procedure TRetroWindow.ShieldMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Single);
begin
  if FShieldForwarding then
    MouseMove(Shift, X, Y);
end;

procedure TRetroWindow.ShieldMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  if FShieldForwarding then
  begin
    FShieldForwarding := False;
    MouseUp(Button, Shift, X, Y);
    UpdateShield;
  end;
end;

procedure TRetroWindow.UpdateGrip;
const
  GripSize = 20;
var
  F: Single;
begin
  if FResizeGrip = nil then
    Exit;
  // only meaningful on a normal, resizable window: a collapsed window is
  // barely taller than its title bar, so a grip there would cover the
  // caption buttons (and show a resize cursor over them)
  FResizeGrip.Visible := FSizeable and not FCollapsed and
    (FWindowState = rwsNormal);
  if not FResizeGrip.Visible then
    Exit;
  F := FrameSize;
  FResizeGrip.SetBounds(Width - F - GripSize, Height - F - GripSize,
    GripSize, GripSize);
  FResizeGrip.BringToFront;
  if FShield <> nil then
    FShield.BringToFront;    // activation still takes precedence
end;

procedure TRetroWindow.Resize;
begin
  inherited;
  UpdateGrip;
end;

procedure TRetroWindow.UpdateShield;
begin
  if FShield = nil then
    Exit;
  // keep the shield alive while it is forwarding a drag so mouse capture
  // is not lost mid-gesture; it is hidden on mouse-up instead
  if FShieldForwarding then
    Exit;
  FShield.Visible := (FDesktop <> nil) and not FActive;
  if FShield.Visible then
    FShield.BringToFront;
end;

function TRetroWindow.GetDefaultStyleLookupName: string;
begin
  Result := 'retrowindowstyle';
end;

procedure TRetroWindow.ApplyStyle;
var
  Part: TFmxObject;
begin
  inherited ApplyStyle;
  Part := FindStyleResource('caption');
  if Part is TText then
  begin
    FCaptionText := TText(Part);
    FCaptionText.Text := FCaption;
  end;
  Part := FindStyleResource('inactivecaption');
  if Part is TText then
  begin
    FInactiveCaption := TText(Part);
    FInactiveCaption.Text := FCaption;
  end;
  Part := FindStyleResource('inactiveoverlay');
  if Part is TControl then
  begin
    FInactiveOverlay := TControl(Part);
    FInactiveOverlay.Opacity := IfThen(FActive, 0, 1);
  end;
  // optional whole-frame inactive layer (Motif recolors the entire border)
  Part := FindStyleResource('frameinactive');
  if Part is TControl then
  begin
    FFrameInactive := TControl(Part);
    FFrameInactive.Opacity := IfThen(FActive, 0, 1);
  end;
  Part := FindStyleResource('titlebar');
  if Part is TControl then
    FTitleBar := TControl(Part);
  Part := FindStyleResource('frame');
  if Part is TControl then
    FFrameLayout := TControl(Part);
  Part := FindStyleResource('closebutton');
  if Part is TCustomButton then
  begin
    FCloseButton := TCustomButton(Part);
    FCloseButton.OnClick := CloseClick;
  end;
  Part := FindStyleResource('minbutton');
  if Part is TCustomButton then
  begin
    FMinButton := TCustomButton(Part);
    FMinButton.OnClick := MinClick;
  end;
  Part := FindStyleResource('maxbutton');
  if Part is TCustomButton then
  begin
    FMaxButton := TCustomButton(Part);
    FMaxButton.OnClick := MaxClick;
  end;
  // Motif/Win 3.1 window-menu button; closing is its only action here.
  Part := FindStyleResource('sysmenubutton');
  if Part is TCustomButton then
  begin
    FSysMenuButton := TCustomButton(Part);
    FSysMenuButton.OnClick := CloseClick;
  end;
  // Mac styles mark themselves for windowshade collapse instead of minimize
  FShadeCollapse := FindStyleResource('collapsemarker') <> nil;
  UpdateButtons;
  UpdateGrip;
  UpdateShield;
  // Reserve the frame + title bar area for client content.
  FClient.Margins.Rect :=
    TRectF.Create(FrameSize + 2, FrameSize + TitleBarHeight + 4,
      FrameSize + 2, FrameSize + 2);
end;

procedure TRetroWindow.FreeStyle;
begin
  FCaptionText := nil;
  FInactiveCaption := nil;
  FInactiveOverlay := nil;
  FFrameInactive := nil;
  FTitleBar := nil;
  FFrameLayout := nil;
  FCloseButton := nil;
  FMinButton := nil;
  FMaxButton := nil;
  FSysMenuButton := nil;
  inherited FreeStyle;
end;

procedure TRetroWindow.UpdateButtons;
begin
  if FCloseButton <> nil then
    FCloseButton.Visible := FShowClose;
  if FMinButton <> nil then
    FMinButton.Visible := FShowMin;
  if FMaxButton <> nil then
    FMaxButton.Visible := FShowMax;
end;

function TRetroWindow.LocalFrom(Sender: TObject; X, Y: Single): TPointF;
begin
  // translate a style part's local coordinates into window-local ones
  if Sender is TControl then
    Result := AbsoluteToLocal(
      TControl(Sender).LocalToAbsolute(TPointF.Create(X, Y)))
  else
    Result := TPointF.Create(X, Y);
end;

procedure TRetroWindow.GripMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  if (Button <> TMouseButton.mbLeft) or not FSizeable or
     (FWindowState = rwsMaximized) or FCollapsed then
    Exit;
  if FDesktop <> nil then
    FDesktop.ActivateWindow(Self);
  // drive the window's own resize machinery from the corner grip
  FDragging := False;
  FResizeEdge := reBottomRight;
  FDownPos := PointInDesktop(LocalFrom(Sender, X, Y));
  FDownBounds := BoundsRect;
end;

procedure TRetroWindow.GripMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Single);
var
  P: TPointF;
begin
  if FResizeEdge = reNone then
    Exit;
  P := LocalFrom(Sender, X, Y);
  MouseMove(Shift, P.X, P.Y);
end;

procedure TRetroWindow.GripMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  FDragging := False;
  FResizeEdge := reNone;
  Reposition;
end;

procedure TRetroWindow.SetCaption(const Value: string);
begin
  if FCaption <> Value then
  begin
    FCaption := Value;
    if FCaptionText <> nil then
      FCaptionText.Text := Value;
    if FInactiveCaption <> nil then
      FInactiveCaption.Text := Value;
    if (FDesktop <> nil) and (FDesktop.Taskbar <> nil) then
      FDesktop.Taskbar.UpdateWindowButton(Self);
  end;
end;

procedure TRetroWindow.SetActive(const Value: Boolean);
begin
  if FActive <> Value then
  begin
    FActive := Value;
    if FInactiveOverlay <> nil then
      FInactiveOverlay.Opacity := IfThen(FActive, 0, 1);
    if FFrameInactive <> nil then
      FFrameInactive.Opacity := IfThen(FActive, 0, 1);
    if Assigned(FOnActiveChanged) then
      FOnActiveChanged(Self);
  end;
  UpdateShield;
end;

procedure TRetroWindow.SetSizeable(const Value: Boolean);
begin
  FSizeable := Value;
  UpdateGrip;
end;

procedure TRetroWindow.SetShowClose(const Value: Boolean);
begin
  FShowClose := Value;
  UpdateButtons;
end;

procedure TRetroWindow.SetShowMin(const Value: Boolean);
begin
  FShowMin := Value;
  UpdateButtons;
end;

procedure TRetroWindow.SetShowMax(const Value: Boolean);
begin
  FShowMax := Value;
  UpdateButtons;
end;

procedure TRetroWindow.CloseClick(Sender: TObject);
begin
  Close;
end;

procedure TRetroWindow.MinClick(Sender: TObject);
begin
  if FShadeCollapse then
    ToggleCollapse
  else
    Minimize;
end;

procedure TRetroWindow.ToggleCollapse;
begin
  if FCollapsed then
  begin
    FCollapsed := False;
    FClient.Visible := True;
    Height := FExpandedHeight;
  end
  else
  begin
    FExpandedHeight := Height;
    FCollapsed := True;
    FClient.Visible := False;
    Height := TitleBarHeight + FrameSize * 2;
  end;
  UpdateGrip;
end;

procedure TRetroWindow.MaxClick(Sender: TObject);
begin
  ToggleMaximize;
end;

procedure TRetroWindow.Close;
begin
  if Assigned(FOnClose) then
    FOnClose(Self);
  if FDesktop <> nil then
    FDesktop.RemoveWindow(Self)
  else
    Visible := False;
end;

procedure TRetroWindow.Minimize;
begin
  if FWindowState = rwsMinimized then
    Exit;
  if FWindowState = rwsNormal then
    FRestoreBounds := BoundsRect;
  FWindowState := rwsMinimized;
  Visible := False;
  if FDesktop <> nil then
  begin
    if FDesktop.Taskbar <> nil then
      FDesktop.Taskbar.UpdateWindowButton(Self);
    FDesktop.NotifyMinimized(Self);
    if FDesktop.ActiveWindow = Self then
      FDesktop.ActivateWindow(nil);
  end;
end;

procedure TRetroWindow.Restore;
begin
  Visible := True;
  if FDesktop <> nil then
    FDesktop.NotifyRestored(Self);
  if FWindowState = rwsMinimized then
    FWindowState := rwsNormal
  else if FWindowState = rwsMaximized then
  begin
    SetBounds(FRestoreBounds.Left, FRestoreBounds.Top,
      FRestoreBounds.Width, FRestoreBounds.Height);
    FWindowState := rwsNormal;
  end;
  UpdateGrip;
  if FDesktop <> nil then
    FDesktop.ActivateWindow(Self);
end;

procedure TRetroWindow.ToggleMaximize;
var
  Area: TRectF;
begin
  if FWindowState = rwsMaximized then
    Restore
  else
  begin
    FRestoreBounds := BoundsRect;
    FWindowState := rwsMaximized;
    if FDesktop <> nil then
      Area := FDesktop.WindowArea
    else if ParentControl <> nil then
      Area := TRectF.Create(0, 0, ParentControl.Width, ParentControl.Height)
    else
      Area := TRectF.Create(0, 0, Width, Height);
    SetBounds(Area.Left, Area.Top, Area.Width, Area.Height);
  end;
end;

function TRetroWindow.TitleBarHeight: Single;
begin
  if FTitleBar <> nil then
    Result := FTitleBar.Height
  else
    Result := 20;
end;

function TRetroWindow.FrameSize: Single;
begin
  if FFrameLayout <> nil then
    Result := FFrameLayout.Margins.Left
  else
    Result := 4;
end;

function TRetroWindow.EdgeAt(const ALocal: TPointF): TResizeEdge;
var
  L, T, R, B: Boolean;
begin
  if not FSizeable or FCollapsed or (FWindowState = rwsMaximized) then
    Exit(reNone);
  L := ALocal.X <= EdgeMargin;
  T := ALocal.Y <= EdgeMargin;
  R := ALocal.X >= Width - EdgeMargin;
  B := ALocal.Y >= Height - EdgeMargin;
  if T and L then Exit(reTopLeft);
  if T and R then Exit(reTopRight);
  if B and L then Exit(reBottomLeft);
  if B and R then Exit(reBottomRight);
  if L then Exit(reLeft);
  if T then Exit(reTop);
  if R then Exit(reRight);
  if B then Exit(reBottom);
  Result := reNone;
end;

function TRetroWindow.PointInDesktop(const ALocal: TPointF): TPointF;
begin
  Result := ALocal + Position.Point;
end;

procedure TRetroWindow.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Single);
var
  Local: TPointF;
begin
  inherited;
  if FDesktop <> nil then
    FDesktop.ActivateWindow(Self);
  if Button <> TMouseButton.mbLeft then
    Exit;
  Local := TPointF.Create(X, Y);
  FResizeEdge := EdgeAt(Local);
  FDownPos := PointInDesktop(Local);
  FDownLocal := Local;
  FDownBounds := BoundsRect;
  if FResizeEdge <> reNone then
    Exit;
  // Title bar area (caption buttons capture their own clicks)
  if Local.Y <= FrameSize + TitleBarHeight then
  begin
    if ssDouble in Shift then
    begin
      // double-click on the title bar: windowshade on Mac styles,
      // maximize everywhere else (wm.js behavior)
      FDragging := False;
      if FShadeCollapse then
        ToggleCollapse
      else
        ToggleMaximize;
      Exit;
    end;
    FDragging := True;
    FDragUnsnapped := FWindowState <> rwsMaximized;
  end;
end;

procedure TRetroWindow.MouseMove(Shift: TShiftState; X, Y: Single);
var
  P, Delta: TPointF;
  NewBounds: TRectF;
  Edge: TResizeEdge;
  NewCursor: TCursor;
begin
  inherited;
  P := PointInDesktop(TPointF.Create(X, Y));
  if FDragging then
  begin
    Delta := P - FDownPos;
    if not FDragUnsnapped then
    begin
      // dragging a maximized window: 10px threshold, then restore with the
      // grab point kept proportional so the window doesn't jump (wm.js)
      if Delta.Length < 10 then
        Exit;
      FWindowState := rwsNormal;
      FDownBounds := FRestoreBounds;
      FDownBounds.SetLocation(
        P.X - FRestoreBounds.Width * (P.X / Max(1, Width)),
        P.Y - FDownLocal.Y);
      SetBounds(FDownBounds.Left, FDownBounds.Top,
        FDownBounds.Width, FDownBounds.Height);
      FDownPos := P;
      Delta := TPointF.Zero;
      FDragUnsnapped := True;
    end;
    // drag against the desktop's top edge to maximize
    if (FDesktop <> nil) and FDesktop.EdgeMaximize and (P.Y < 5) and
       (FWindowState <> rwsMaximized) then
    begin
      FDragging := False;
      ToggleMaximize;
      Exit;
    end;
    SetBounds(FDownBounds.Left + Delta.X, FDownBounds.Top + Delta.Y,
      FDownBounds.Width, FDownBounds.Height);
    Exit;
  end;
  if FResizeEdge <> reNone then
  begin
    Delta := P - FDownPos;
    NewBounds := FDownBounds;
    case FResizeEdge of
      reLeft, reTopLeft, reBottomLeft:
        NewBounds.Left := Min(FDownBounds.Left + Delta.X,
          FDownBounds.Right - MinWindowWidth);
      reRight, reTopRight, reBottomRight:
        NewBounds.Right := Max(FDownBounds.Right + Delta.X,
          FDownBounds.Left + MinWindowWidth);
    end;
    case FResizeEdge of
      reTop, reTopLeft, reTopRight:
        NewBounds.Top := Min(FDownBounds.Top + Delta.Y,
          FDownBounds.Bottom - MinWindowHeight);
      reBottom, reBottomLeft, reBottomRight:
        NewBounds.Bottom := Max(FDownBounds.Bottom + Delta.Y,
          FDownBounds.Top + MinWindowHeight);
    end;
    SetBounds(NewBounds.Left, NewBounds.Top, NewBounds.Width,
      NewBounds.Height);
    Exit;
  end;
  // update cursor feedback; assign only on change -- cursor writes walk
  // the whole child tree (RefreshInheritedCursorForChildren) and must be
  // avoided while the control is being destroyed or restyled
  if csDestroying in ComponentState then
    Exit;
  Edge := EdgeAt(TPointF.Create(X, Y));
  case Edge of
    reLeft, reRight: NewCursor := crSizeWE;
    reTop, reBottom: NewCursor := crSizeNS;
    reTopLeft, reBottomRight: NewCursor := crSizeNWSE;
    reTopRight, reBottomLeft: NewCursor := crSizeNESW;
  else
    NewCursor := crDefault;
  end;
  if Cursor <> NewCursor then
    Cursor := NewCursor;
end;

procedure TRetroWindow.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Single);
begin
  inherited;
  FDragging := False;
  FResizeEdge := reNone;
  Reposition;
end;

procedure TRetroWindow.Reposition;
var
  Area: TRectF;
  NewX, NewY: Single;
begin
  // keep the window reachable: title bar never above the top, and at least
  // a strip of the window visible on every side (wm.js reposition())
  if FDesktop = nil then
    Exit;
  Area := FDesktop.WindowArea;
  if FWindowState = rwsMaximized then
  begin
    SetBounds(Area.Left, Area.Top, Area.Width, Area.Height);
    Exit;
  end;
  if FWindowState = rwsMinimized then
    Exit;
  NewX := Position.X;
  NewY := Position.Y;
  // clamp against the usable area, which may be inset on any side
  // depending on where the taskbar is docked
  if NewY < Area.Top then
    NewY := Area.Top
  else if NewY + 30 > Area.Bottom then
    NewY := Area.Bottom - 30;
  if NewX + Width < Area.Left + 50 then
    NewX := Area.Left + 50 - Width
  else if NewX + 30 > Area.Right then
    NewX := Area.Right - 30;
  if (NewX <> Position.X) or (NewY <> Position.Y) then
    SetBounds(NewX, NewY, Width, Height);
end;

procedure TRetroWindow.DoMouseLeave;
begin
  inherited;
  // Guard the cursor reset: DoMouseLeave fires during style switches and
  // teardown, when a cursor write would traverse partially-freed children
  // (reported access violation in FMX.Controls.RefreshInheritedCursor).
  if (csDestroying in ComponentState) or (Root = nil) then
    Exit;
  if not FDragging and (FResizeEdge = reNone) and (Cursor <> crDefault) then
    Cursor := crDefault;
end;

{ TRetroDesktopIcon }

constructor TRetroDesktopIcon.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 76;
  Height := 66;
  HitTest := True;
  // focusable: clicking selects the icon (inverted label via the style's
  // 'selection' part); clicking elsewhere deselects
  CanFocus := True;
  // keep receiving moves once a drag starts, even outside the icon
  AutoCapture := True;
end;

function TRetroDesktopIcon.GetDefaultStyleLookupName: string;
begin
  Result := 'retrodesktopiconstyle';
end;

procedure TRetroDesktopIcon.ApplyStyle;
var
  Part: TFmxObject;
begin
  inherited ApplyStyle;
  Part := FindStyleResource('text');
  if Part is TText then
  begin
    FCaptionText := TText(Part);
    FCaptionText.Text := FCaption;
  end;
  Part := FindStyleResource('selection');
  if Part is TControl then
    FSelection := TControl(Part);
  Part := FindStyleResource('selectedtext');
  if Part is TText then
  begin
    FSelectedText := TText(Part);
    FSelectedText.Text := FCaption;
  end;
  UpdateSelection;
end;

procedure TRetroDesktopIcon.FreeStyle;
begin
  FCaptionText := nil;
  FSelectedText := nil;
  FSelection := nil;
  inherited FreeStyle;
end;

procedure TRetroDesktopIcon.UpdateSelection;
begin
  if FSelection <> nil then
    FSelection.Opacity := IfThen(IsFocused, 1, 0);
end;

function TRetroDesktopIcon.DesktopOf: TRetroDesktop;
begin
  if Parent is TRetroDesktop then
    Result := TRetroDesktop(Parent)
  else
    Result := nil;
end;

function TRetroDesktopIcon.PointInDesktop(X, Y: Single): TPointF;
var
  D: TRetroDesktop;
begin
  D := DesktopOf;
  if D = nil then
    Result := TPointF.Create(X, Y)
  else
    Result := D.AbsoluteToLocal(LocalToAbsolute(TPointF.Create(X, Y)));
end;

procedure TRetroDesktopIcon.Reposition;
var
  D: TRetroDesktop;
  Area: TRectF;
  P: TPointF;
begin
  D := DesktopOf;
  if D = nil then
    Exit;
  Area := D.WindowArea;
  P := Position.Point;
  P.X := Min(Max(P.X, Area.Left), Max(Area.Left, Area.Right - Width));
  P.Y := Min(Max(P.Y, Area.Top), Max(Area.Top, Area.Bottom - Height));
  if (P.X <> Position.X) or (P.Y <> Position.Y) then
    Position.Point := P;
end;

procedure TRetroDesktopIcon.MouseDown(Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  inherited;
  // take focus explicitly -- selection is focus-driven and some click
  // paths (styled-control hit on a non-input control) do not focus
  if (Button = TMouseButton.mbLeft) and CanFocus and not IsFocused then
    SetFocus;
  if Button <> TMouseButton.mbLeft then
    Exit;
  // Deltas are measured in desktop coordinates against the position the
  // icon had at mouse-down: local coordinates move with the icon, so
  // accumulating them drifts.
  FDragging := True;
  FMoved := False;
  FDownPos := PointInDesktop(X, Y);
  FStartPos := Position.Point;
end;

procedure TRetroDesktopIcon.MouseMove(Shift: TShiftState; X, Y: Single);
var
  D: TRetroDesktop;
  Area: TRectF;
  Delta, P: TPointF;
begin
  inherited;
  if not FDragging then
    Exit;
  Delta := PointInDesktop(X, Y) - FDownPos;
  if not FMoved then
  begin
    // a plain click must still select, and a double-click must still open,
    // so ignore the jitter between the two
    if (Abs(Delta.X) < IconDragThreshold) and
       (Abs(Delta.Y) < IconDragThreshold) then
      Exit;
    FMoved := True;
  end;
  P := FStartPos + Delta;
  D := DesktopOf;
  if D <> nil then
  begin
    Area := D.WindowArea;
    P.X := Min(Max(P.X, Area.Left), Max(Area.Left, Area.Right - Width));
    P.Y := Min(Max(P.Y, Area.Top), Max(Area.Top, Area.Bottom - Height));
  end;
  Position.Point := P;
end;

procedure TRetroDesktopIcon.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Single);
begin
  FDragging := False;
  inherited;
end;

procedure TRetroDesktopIcon.DoEnter;
begin
  inherited;
  UpdateSelection;
end;

procedure TRetroDesktopIcon.DoExit;
begin
  inherited;
  UpdateSelection;
end;

procedure TRetroDesktopIcon.SetCaption(const Value: string);
begin
  if FCaption <> Value then
  begin
    FCaption := Value;
    if FCaptionText <> nil then
      FCaptionText.Text := Value;
    if FSelectedText <> nil then
      FSelectedText.Text := Value;
  end;
end;

procedure TRetroDesktopIcon.DblClick;
begin
  inherited;
  if Assigned(FOnOpen) then
    FOnOpen(Self);
end;

{ TRetroTaskbar }

constructor TRetroTaskbar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FButtons := TDictionary<TRetroWindow, TButton>.Create;
  FOrder := TList<TButton>.Create;
  FTitles := TList<TButton>.Create;
  FEdge := rbeBottom;
  FKind := rbkTaskbar;
  Padding.Rect := TRectF.Create(2, 3, 2, 3);
  FMenuButton := TButton.Create(Self);
  FMenuButton.Stored := False;
  FMenuButton.StyleLookup := 'retromenubuttonstyle';
  FMenuButton.Text := 'Menu';
  FMenuButton.Parent := Self;
  // Screen-title furniture (Amiga). Created once and shown by kind, so a
  // style switch never has to build or free controls.
  FStatus := TLabel.Create(Self);
  FStatus.Stored := False;
  FStatus.HitTest := False;
  FStatus.Visible := False;
  FStatus.Parent := Self;
  FGadgets := TLayout.Create(Self);
  FGadgets.Stored := False;
  FGadgets.Visible := False;
  FGadgets.Width := 44;
  FGadgets.Parent := Self;
  FBackGadget := TButton.Create(Self);
  FBackGadget.Stored := False;
  FBackGadget.StyleLookup := 'retrobarbackstyle';
  FBackGadget.Align := TAlignLayout.Right;
  FBackGadget.Width := 20;
  FBackGadget.OnClick := BackGadgetClick;
  FBackGadget.Parent := FGadgets;
  FFrontGadget := TButton.Create(Self);
  FFrontGadget.Stored := False;
  FFrontGadget.StyleLookup := 'retrobarfrontstyle';
  FFrontGadget.Align := TAlignLayout.Right;
  FFrontGadget.Width := 20;
  FFrontGadget.Margins.Right := 2;
  FFrontGadget.Position.X := -1000;   // docks left of the back gadget
  FFrontGadget.OnClick := FrontGadgetClick;
  FFrontGadget.Parent := FGadgets;
  FClock := TLabel.Create(Self);
  FClock.Stored := False;
  FClock.HitTest := False;
  FClock.StyledSettings := FClock.StyledSettings - [TStyledSetting.Other];
  FClock.TextSettings.HorzAlign := TTextAlign.Center;
  FClock.Visible := False;
  FClock.Parent := Self;
  FClockTimer := TTimer.Create(Self);
  FClockTimer.Interval := 1000;
  FClockTimer.OnTimer := ClockTick;
  FClockTimer.Enabled := False;
  // Task buttons live in their own client-aligned layout so they can never
  // land before the menu button, regardless of creation order.
  FContent := TLayout.Create(Self);
  FContent.Stored := False;
  FContent.Align := TAlignLayout.Client;
  FContent.HitTest := False;
  FContent.Parent := Self;
  LayoutBar;
end;

destructor TRetroTaskbar.Destroy;
begin
  FTitles.Free;
  FOrder.Free;
  FButtons.Free;
  inherited;
end;

function TRetroTaskbar.IsVertical: Boolean;
begin
  // a corner panel stacks its apps downward whatever edge it is nearest
  Result := (FEdge in [rbeLeft, rbeRight]) or (FKind in [rbkDock, rbkCorner]);
end;

function TRetroTaskbar.Floats: Boolean;
begin
  Result := FKind = rbkCorner;
end;

procedure TRetroTaskbar.SetEdge(const Value: TRetroBarEdge);
begin
  FEdgeExplicit := True;
  if FEdge = Value then
    Exit;
  FEdge := Value;
  LayoutBar;
end;

procedure TRetroTaskbar.SetEdgeFromStyle(AEdge: TRetroBarEdge);
begin
  if FEdge = AEdge then
    Exit;
  FEdge := AEdge;
  LayoutBar;
end;

procedure TRetroTaskbar.SetKind(const Value: TRetroBarKind);
begin
  FKindExplicit := True;
  if FKind = Value then
    Exit;
  FKind := Value;
  LayoutBar;
end;

procedure TRetroTaskbar.SetKindFromStyle(AKind: TRetroBarKind);
begin
  if FKind = AKind then
    Exit;
  FKind := AKind;
  LayoutBar;
end;

procedure TRetroTaskbar.SetStatusText(const Value: string);
begin
  if FStatusText = Value then
    Exit;
  FStatusText := Value;
  UpdateStatus;
end;

procedure TRetroTaskbar.UpdateStatus;
var
  S: string;
begin
  if FStatus = nil then
    Exit;
  S := FStatusText;
  if S = '' then
    if (FDesktop <> nil) and (FDesktop.ActiveWindow <> nil) then
      S := FDesktop.ActiveWindow.Caption
    else
      S := 'Workbench Screen';
  FStatus.Text := S;
end;

procedure TRetroTaskbar.ClockTick(Sender: TObject);
begin
  if FClock <> nil then
    FClock.Text := FormatDateTime('h:nn', Now);
end;

procedure TRetroTaskbar.FrontGadgetClick(Sender: TObject);
begin
  if FDesktop <> nil then
    FDesktop.BringBottomToFront;
end;

procedure TRetroTaskbar.BackGadgetClick(Sender: TObject);
begin
  if FDesktop <> nil then
    FDesktop.SendActiveToBack;
end;

function TRetroTaskbar.AddMenuTitle(const ACaption: string): TButton;
begin
  Result := TButton.Create(Self);
  Result.Stored := False;
  Result.StyleLookup := 'retrobartitlestyle';
  Result.Text := ACaption;
  Result.Align := TAlignLayout.Left;
  Result.Width := 8 + Length(ACaption) * 8;
  Result.Position.X := FTitles.Count * 1000;
  Result.Visible := FKind = rbkMenuBar;
  Result.Parent := Self;
  FTitles.Add(Result);
  LayoutBar;
end;

procedure TRetroTaskbar.Relayout;
begin
  LayoutBar;
end;

function TRetroTaskbar.ShowsWindowButtons: Boolean;
begin
  // the Amiga screen title carried no per-window furniture at all, so
  // minimized windows fall back to desktop icons there
  Result := FKind <> rbkScreenTitle;
end;

procedure TRetroTaskbar.LayoutBar;
const
  BarThickness = 30;   // height when horizontal
  BarWidth = 110;      // width when vertical
  DockWidth = 96;      // a NeXTSTEP dock tile was 64 px square, plus text
  CornerWidth = 124;
  CornerClockH = 18;
  TitleThickness = 22;
  MenuThickness = 24;
  TrayThickness = 28;
var
  I, Apps: Integer;
  Thickness: Single;
begin
  // The bar docks with plain FMX alignment, so the desktop's client area
  // adjusts itself; the launcher and task buttons then stack along the
  // bar's long axis. A corner panel is the exception: it is positioned
  // rather than docked, because it reserves no space (see Floats).
  case FKind of
    rbkDock: Thickness := DockWidth;
    rbkScreenTitle: Thickness := TitleThickness;
    rbkMenuBar: Thickness := MenuThickness;
    rbkTray: Thickness := TrayThickness;
  else
    if IsVertical then
      Thickness := BarWidth
    else
      Thickness := BarThickness;
  end;

  if FKind = rbkCorner then
  begin
    // BeOS's Deskbar: a panel in the top-right corner, as deep as the
    // number of running apps needs, floating above the windows.
    Apps := 0;
    if FOrder <> nil then
      Apps := FOrder.Count;
    Align := TAlignLayout.None;
    Anchors := [TAnchorKind.akTop, TAnchorKind.akRight];
    Width := CornerWidth;
    Height := 30 + Apps * 29 + CornerClockH + 6;
    if ParentControl <> nil then
      Position.Point := TPointF.Create(ParentControl.Width - Width, 0)
    else
      Position.Point := TPointF.Create(0, 0);
  end
  else
    case FEdge of
      rbeTop:
        begin
          Align := TAlignLayout.Top;
          Height := Thickness;
        end;
      rbeBottom:
        begin
          Align := TAlignLayout.Bottom;
          Height := Thickness;
        end;
      rbeLeft:
        begin
          Align := TAlignLayout.Left;
          Width := Thickness;
        end;
      rbeRight:
        begin
          Align := TAlignLayout.Right;
          Width := Thickness;
        end;
    end;

  // launcher: NeXTSTEP's Dock had none, the Amiga screen title had none,
  // and a menu bar's leftmost title is the launcher
  if FMenuButton <> nil then
  begin
    FMenuButton.Visible := FKind in [rbkTaskbar, rbkCorner, rbkTray];
    // same reason as in LayoutTaskButton: trimming has to be set here
    FMenuButton.StyledSettings :=
      FMenuButton.StyledSettings - [TStyledSetting.Other];
    FMenuButton.TextSettings.Trimming := TTextTrimming.Character;
    if IsVertical then
    begin
      FMenuButton.Align := TAlignLayout.Top;
      FMenuButton.Height := 26;
      FMenuButton.Margins.Rect := TRectF.Create(0, 0, 0, 4);
    end
    else
    begin
      FMenuButton.Align := TAlignLayout.Left;
      FMenuButton.Width := 78;   // hamburger strip + 'Menu'
      FMenuButton.Margins.Rect := TRectF.Create(0, 0, 4, 0);
    end;
  end;

  if FTitles <> nil then
    for I := 0 to FTitles.Count - 1 do
      FTitles[I].Visible := FKind = rbkMenuBar;

  if FStatus <> nil then
  begin
    FStatus.Visible := FKind = rbkScreenTitle;
    FStatus.Align := TAlignLayout.Left;
    FStatus.Width := 320;
    FStatus.Margins.Left := 4;
    if FStatus.Visible then
      UpdateStatus;
  end;
  if FGadgets <> nil then
  begin
    FGadgets.Visible := FKind = rbkScreenTitle;
    FGadgets.Align := TAlignLayout.Right;
  end;

  if FClock <> nil then
  begin
    FClock.Visible := FKind in [rbkCorner, rbkMenuBar, rbkTray];
    if FKind = rbkCorner then
    begin
      FClock.Align := TAlignLayout.Bottom;
      FClock.Height := CornerClockH;
    end
    else
    begin
      FClock.Align := TAlignLayout.Right;
      FClock.Width := 56;
    end;
    if FClockTimer <> nil then
      FClockTimer.Enabled := FClock.Visible;
    if FClock.Visible then
      ClockTick(Self);
  end;

  if FContent <> nil then
    FContent.Visible := ShowsWindowButtons;
  if FOrder <> nil then
    for I := 0 to FOrder.Count - 1 do
      LayoutTaskButton(FOrder[I], I);
  // the usable desktop changed shape, so windows and icons may need
  // pulling back inside it
  if FDesktop <> nil then
  begin
    for I := 0 to FDesktop.WindowCount - 1 do
      FDesktop.Windows[I].Reposition;
    FDesktop.RepositionIcons;
  end;
end;

procedure TRetroTaskbar.LayoutTaskButton(AButton: TButton; AIndex: Integer);
begin
  // Alignment, wrapping and trimming come from the CONTROL, not the style,
  // unless TStyledSetting.Other is in StyledSettings -- and it is not, by
  // default. So the Trimming the .style files set on the task button's text
  // never applied, and a caption wider than its button simply overflowed
  // both ends of it. A narrow bar (the NeXTSTEP Dock is 96 px) makes that
  // obvious, but it was true of every bar.
  AButton.StyledSettings := AButton.StyledSettings - [TStyledSetting.Other];
  AButton.TextSettings.HorzAlign := TTextAlign.Center;
  AButton.TextSettings.Trimming := TTextTrimming.Character;
  // Dock tiles are deep enough for two lines, so wrap there and clip
  // everywhere else
  AButton.TextSettings.WordWrap := FKind = rbkDock;
  // the seeded position makes same-aligned siblings dock in creation order
  if IsVertical then
  begin
    AButton.Align := TAlignLayout.Top;
    // Dock tiles are square-ish app tiles; a Deskbar entry is a row
    if FKind = rbkDock then
      AButton.Height := 48
    else
      AButton.Height := 26;
    AButton.Margins.Rect := TRectF.Create(0, 0, 0, 3);
    AButton.Position.Y := AIndex * 1000 + 1000;
  end
  else if FKind = rbkMenuBar then
  begin
    // Mac OS 9 listed the running applications at the RIGHT of the menu
    // bar, so these dock from that end inward
    AButton.Align := TAlignLayout.Right;
    AButton.Width := 104;
    AButton.Margins.Rect := TRectF.Create(3, 0, 0, 0);
    AButton.Position.X := -(AIndex * 1000 + 1000);
  end
  else
  begin
    AButton.Align := TAlignLayout.Left;
    AButton.Width := 120;
    AButton.Margins.Rect := TRectF.Create(0, 0, 3, 0);
    AButton.Position.X := AIndex * 1000 + 1000;
  end;
end;

function TRetroTaskbar.GetDefaultStyleLookupName: string;
begin
  Result := 'retrotaskbarstyle';
end;

procedure TRetroTaskbar.AddWindowButton(AWindow: TRetroWindow);
var
  B: TButton;
begin
  if FButtons.ContainsKey(AWindow) then
    Exit;
  B := TButton.Create(Self);
  B.Stored := False;
  B.StyleLookup := 'retrotaskbuttonstyle';
  B.Text := AWindow.Caption;
  B.TagObject := AWindow;
  B.OnClick := TaskButtonClick;
  B.Parent := FContent;
  FButtons.Add(AWindow, B);
  FOrder.Add(B);
  LayoutTaskButton(B, FOrder.Count - 1);
  if FKind = rbkCorner then    // the panel is as deep as the app list
    LayoutBar;
end;

procedure TRetroTaskbar.RemoveWindowButton(AWindow: TRetroWindow);
var
  B: TButton;
  I: Integer;
begin
  if FButtons.TryGetValue(AWindow, B) then
  begin
    FButtons.Remove(AWindow);
    FOrder.Remove(B);
    B.Free;
    for I := 0 to FOrder.Count - 1 do    // close the gap
      LayoutTaskButton(FOrder[I], I);
    if FKind = rbkCorner then
      LayoutBar;
  end;
end;

procedure TRetroTaskbar.UpdateWindowButton(AWindow: TRetroWindow);
var
  B: TButton;
begin
  if FButtons.TryGetValue(AWindow, B) then
    B.Text := AWindow.Caption;
end;

procedure TRetroTaskbar.TaskButtonClick(Sender: TObject);
var
  W: TRetroWindow;
begin
  if (Sender is TButton) and (TButton(Sender).TagObject is TRetroWindow) then
  begin
    W := TRetroWindow(TButton(Sender).TagObject);
    if W.Visible and (W.Desktop <> nil) and (W.Desktop.ActiveWindow = W) then
      W.Minimize
    else
      W.Restore;
  end;
end;

{ TRetroDesktop }

constructor TRetroDesktop.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FWindows := TList<TRetroWindow>.Create;
  FIcons := TList<TRetroDesktopIcon>.Create;
  FMinIcons := TDictionary<TRetroWindow, TRetroDesktopIcon>.Create;
  FEdgeMaximize := True;
  HitTest := True;
  // focusable so clicking bare desktop steals focus from icons,
  // deselecting them
  CanFocus := True;
  Align := TAlignLayout.Client;
end;

procedure TRetroDesktop.Resize;
var
  W: TRetroWindow;
begin
  inherited;
  if FWindows = nil then
    Exit;
  // a floating panel is positioned, not aligned, so it has to follow
  if (FTaskbar <> nil) and FTaskbar.Floats then
    FTaskbar.Relayout;
  for W in FWindows do
    W.Reposition;
  RepositionIcons;
end;

destructor TRetroDesktop.Destroy;
begin
  FMinIcons.Free;
  FIcons.Free;
  FWindows.Free;
  inherited;
end;

procedure TRetroDesktop.NotifyMinimized(AWindow: TRetroWindow);
var
  Icon: TRetroDesktopIcon;
begin
  // Without a taskbar (Windows 3.1 / CDE style desktops) -- or with a bar
  // that carries no per-window buttons, like the Amiga screen title --
  // minimized windows become icons along the bottom of the desktop.
  if FMinIcons.ContainsKey(AWindow) then
    Exit;
  if (FTaskbar <> nil) and FTaskbar.ShowsWindowButtons then
    Exit;
  Icon := TRetroDesktopIcon.Create(Self);
  Icon.Stored := False;
  Icon.Caption := AWindow.Caption;
  Icon.TagObject := AWindow;
  Icon.OnOpen := MinIconOpen;
  Icon.Position.Point := TPointF.Create(
    WindowArea.Left + 16 + FMinIcons.Count * 88, WindowArea.Bottom - 82);
  Icon.Parent := Self;
  FMinIcons.Add(AWindow, Icon);
  KeepBarOnTop;
end;

procedure TRetroDesktop.NotifyRestored(AWindow: TRetroWindow);
var
  Icon: TRetroDesktopIcon;
begin
  if FMinIcons.TryGetValue(AWindow, Icon) then
  begin
    FMinIcons.Remove(AWindow);
    Icon.Free;
  end;
end;

procedure TRetroDesktop.MinIconOpen(Sender: TObject);
begin
  if (Sender is TRetroDesktopIcon) and
     (TRetroDesktopIcon(Sender).TagObject is TRetroWindow) then
    TRetroWindow(TRetroDesktopIcon(Sender).TagObject).Restore;
end;

function TRetroDesktop.CreateIcon(const ACaption: string): TRetroDesktopIcon;
var
  Area: TRectF;
begin
  Area := WindowArea;
  Result := TRetroDesktopIcon.Create(Self);
  Result.Stored := False;
  Result.Caption := ACaption;
  Result.Position.Point := TPointF.Create(
    Area.Left + IconGridMargin + (FIcons.Count div 6) * IconGridX,
    Area.Top + IconGridMargin + (FIcons.Count mod 6) * IconGridY);
  Result.Parent := Self;
  FIcons.Add(Result);
  KeepBarOnTop;
end;

procedure TRetroDesktop.ArrangeIcons;
var
  Area: TRectF;
  I: Integer;
begin
  if FIcons = nil then
    Exit;
  Area := WindowArea;
  for I := 0 to FIcons.Count - 1 do
    FIcons[I].Position.Point := TPointF.Create(
      Area.Left + IconGridMargin + (I div 6) * IconGridX,
      Area.Top + IconGridMargin + (I mod 6) * IconGridY);
end;

procedure TRetroDesktop.RepositionIcons;
var
  Icon: TRetroDesktopIcon;
begin
  if FIcons = nil then
    Exit;
  for Icon in FIcons do
    Icon.Reposition;
  if FMinIcons <> nil then
    for Icon in FMinIcons.Values do
      Icon.Reposition;
end;

procedure TRetroDesktop.KeepBarOnTop;
begin
  // Windows and icons are positioned children, so plain child order decides
  // what covers what -- and activating a window brings it to the front.
  // The bar is chrome and always belongs above them.
  if (FTaskbar <> nil) and (FTaskbar.Parent = Self) then
    FTaskbar.BringToFront;
end;

function TRetroDesktop.GetDefaultStyleLookupName: string;
begin
  Result := 'retrodesktopstyle';
end;

procedure TRetroDesktop.ApplyStyle;
begin
  inherited;
  // A style switch lands here, and only here is the new style's marker
  // readable -- PreferredBarEdge queried any earlier still sees the old
  // style. Move the bar unless the app pinned an edge itself.
  if FTaskbar <> nil then
  begin
    // kind first: it decides which edge the style prefers
    if not FTaskbar.KindIsExplicit then
      FTaskbar.SetKindFromStyle(PreferredBarKind);
    if not FTaskbar.EdgeIsExplicit then
      FTaskbar.SetEdgeFromStyle(PreferredBarEdge);
    FTaskbar.Relayout;
  end;
  RepositionIcons;
  KeepBarOnTop;
end;

function TRetroDesktop.GetWindow(Index: Integer): TRetroWindow;
begin
  Result := FWindows[Index];
end;

function TRetroDesktop.GetWindowCount: Integer;
begin
  Result := FWindows.Count;
end;

function TRetroDesktop.WindowArea: TRectF;
begin
  Result := TRectF.Create(0, 0, Width, Height);
  if (FTaskbar <> nil) and FTaskbar.Visible and not FTaskbar.Floats then
    case FTaskbar.Edge of
      rbeTop: Result.Top := Result.Top + FTaskbar.Height;
      rbeBottom: Result.Bottom := Result.Bottom - FTaskbar.Height;
      rbeLeft: Result.Left := Result.Left + FTaskbar.Width;
      rbeRight: Result.Right := Result.Right - FTaskbar.Width;
    end;
end;

function TRetroDesktop.PreferredBarEdge: TRetroBarEdge;
begin
  // Styles for systems whose bar lived at the top of the screen (Mac OS 9
  // and Apple System's menu bar, OS/2 Warp's WarpCenter) tag their desktop
  // style with a 'bartop' marker; everything else defaults to the bottom.
  // A kind that implies its own edge wins: the Dock was on the right, the
  // Deskbar in the top-right corner, and a screen title or menu bar is by
  // definition the top line of the screen.
  case PreferredBarKind of
    rbkDock: Result := rbeRight;
    rbkCorner, rbkScreenTitle, rbkMenuBar, rbkTray: Result := rbeTop;
  else
    if FindStyleResource('bartop') <> nil then
      Result := rbeTop
    else
      Result := rbeBottom;
  end;
end;

function TRetroDesktop.PreferredBarKind: TRetroBarKind;
begin
  // The style names the SHAPE of its bar with a marker part, the same way
  // it names the edge -- see the barkind palette key in the generator.
  if FindStyleResource('bardock') <> nil then
    Result := rbkDock
  else if FindStyleResource('barcorner') <> nil then
    Result := rbkCorner
  else if FindStyleResource('barscreentitle') <> nil then
    Result := rbkScreenTitle
  else if FindStyleResource('barmenubar') <> nil then
    Result := rbkMenuBar
  else if FindStyleResource('bartray') <> nil then
    Result := rbkTray
  else
    Result := rbkTaskbar;
end;

procedure TRetroDesktop.BringBottomToFront;
var
  I: Integer;
  C: TControl;
begin
  // Workbench's front gadget cycles: whatever is furthest back comes up.
  // Z-order is child order, so the backmost window is simply the first
  // TRetroWindow in the list.
  for I := 0 to ControlsCount - 1 do
  begin
    C := Controls[I];
    if (C is TRetroWindow) and C.Visible and (C <> FActiveWindow) then
    begin
      ActivateWindow(TRetroWindow(C));
      Exit;
    end;
  end;
end;

procedure TRetroDesktop.SendActiveToBack;
var
  W, Front: TRetroWindow;
  Others: TList<TRetroWindow>;
  I: Integer;
  C: TControl;
begin
  W := FActiveWindow;
  if W = nil then
    Exit;
  // Not W.SendToBack: that would drop the window behind the desktop icons
  // as well. Bringing the others forward in their existing order leaves W
  // at the bottom of the window stack and the icons below all of them.
  Others := TList<TRetroWindow>.Create;
  try
    for I := 0 to ControlsCount - 1 do
    begin
      C := Controls[I];
      if (C is TRetroWindow) and C.Visible and (C <> W) then
        Others.Add(TRetroWindow(C));
    end;
    Front := nil;
    for I := 0 to Others.Count - 1 do
    begin
      Others[I].BringToFront;
      Front := Others[I];
    end;
  finally
    Others.Free;
  end;
  if Front <> nil then
    ActivateWindow(Front);
  KeepBarOnTop;
end;

function TRetroDesktop.EnsureTaskbar: TRetroTaskbar;
var
  W: TRetroWindow;
begin
  if FTaskbar = nil then
  begin
    FTaskbar := TRetroTaskbar.Create(Self);
    FTaskbar.Stored := False;
    FTaskbar.Desktop := Self;
    FTaskbar.Parent := Self;
    for W in FWindows do
      FTaskbar.AddWindowButton(W);
  end;
  Result := FTaskbar;
end;

function TRetroDesktop.CreateTaskbar: TRetroTaskbar;
begin
  // follows the style, now and on every later style switch
  Result := EnsureTaskbar;
  Result.SetEdgeFromStyle(PreferredBarEdge);
end;

function TRetroDesktop.CreateTaskbar(AEdge: TRetroBarEdge): TRetroTaskbar;
begin
  Result := EnsureTaskbar;
  Result.Edge := AEdge;   // an explicit choice: styles stop overriding it
end;

function TRetroDesktop.CreateWindow(const ACaption: string;
  AWidth, AHeight: Single): TRetroWindow;
begin
  Result := TRetroWindow.Create(Self);
  Result.Stored := False;
  Result.FDesktop := Self;
  Result.Caption := ACaption;
  Result.SetBounds(WindowArea.Left + 24 + FCascade * 26,
    WindowArea.Top + 24 + FCascade * 26, AWidth, AHeight);
  FCascade := (FCascade + 1) mod 8;
  Result.Parent := Self;
  FWindows.Add(Result);
  if FTaskbar <> nil then
    FTaskbar.AddWindowButton(Result);
  ActivateWindow(Result);      // brings the bar back on top
end;

procedure TRetroDesktop.ActivateWindow(AWindow: TRetroWindow);
var
  W: TRetroWindow;
begin
  FActiveWindow := AWindow;
  for W in FWindows do
  begin
    W.Active := W = AWindow;
    W.UpdateShield;
  end;
  if AWindow <> nil then
    AWindow.BringToFront;
  if FTaskbar <> nil then
    FTaskbar.UpdateStatus;
  KeepBarOnTop;
end;

procedure TRetroDesktop.RemoveWindow(AWindow: TRetroWindow);
begin
  FWindows.Remove(AWindow);
  NotifyRestored(AWindow);
  if FTaskbar <> nil then
    FTaskbar.RemoveWindowButton(AWindow);
  if FActiveWindow = AWindow then
  begin
    if FWindows.Count > 0 then
      ActivateWindow(FWindows.Last)
    else
      ActivateWindow(nil);
  end;
  // Deferred destruction: the call originates from the window's own
  // close-button click, so it cannot be freed synchronously. The window
  // must stay PARENTED until the deferred Free runs -- unparenting first
  // leaves the form's hover/capture references pointing at the clicked
  // caption button with no cleanup path (invalid pointer on the next
  // mouse event). Only the OWNER link is detached, so if the app exits
  // before the queue drains, the desktop (as parent) frees the window
  // exactly once.
  AWindow.Visible := False;
  RemoveComponent(AWindow);
  TThread.ForceQueue(nil,
    procedure
    begin
      AWindow.Free;
    end);
end;

procedure TRetroDesktop.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Single);
begin
  inherited;
  // Clicking bare desktop deactivates all windows (like real desktops)
  ActivateWindow(nil);
end;

end.
