unit PasclawAccessibility;
(*
  Microsoft Active Accessibility (MSAA) for PasClaw Studio.

  FMX draws its own controls. A screen reader asking Windows what is inside
  the Studio window gets one opaque client area and nothing else -- NVDA and
  Narrator announce the title bar and then fall silent. MSAA is the oldest
  and most universally supported of the Windows accessibility APIs, and the
  one every reader still consumes, so it is the cheapest way to make the app
  legible.

  Two halves:

    TFmxAccessible   an IAccessible over one FMX control (or the form
                     itself, which is the root). Answers name / role /
                     value / state / screen rect and walks parent and
                     children.

    Hooking          the form's HWND is subclassed so WM_GETOBJECT with
                     lParam = OBJID_CLIENT returns the root object through
                     LresultFromObject. Every other object id falls through
                     to the original window proc, which is what keeps the
                     title bar, system menu and caret behaving normally.

  Windows-only by construction: the entire body sits inside {$IFDEF
  MSWINDOWS}, and the two public entry points compile to empty procedures
  elsewhere so callers need no conditionals of their own. There is no
  existing platform guard anywhere in studio/ to copy, so this establishes
  the shape: guard the implementation, never the call site.

  NOT covered, deliberately: UI Automation. UIA is the richer API and the
  one Microsoft prefers, but it needs a provider per control plus a fair
  amount of COM plumbing, and every reader that speaks UIA also speaks MSAA
  through the built-in bridge. MSAA first is the smaller change that makes
  the app usable; UIA is a follow-up, not a prerequisite.
*)

interface

uses
  System.Classes, FMX.Forms;

{ Install the MSAA hook on Form's native window. Safe to call more than once
  -- the second call is a no-op. No-op on non-Windows. }
procedure InstallAccessibility(Form: TCommonCustomForm);

{ Remove the hook and drop the cached root. Call before the form is
  destroyed so the subclass does not outlive the window. No-op on
  non-Windows. }
procedure UninstallAccessibility(Form: TCommonCustomForm);

implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows, Winapi.Messages, Winapi.ActiveX, Winapi.Oleacc,
  System.SysUtils, System.Types, System.Variants, System.UITypes,
  System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Platform.Win,
  FMX.StdCtrls, FMX.Edit, FMX.Memo, FMX.ListBox, FMX.TabControl,
  FMX.Objects;

type
  { One accessible node. FControl nil means "the form itself" -- the root
    object MSAA hands to the client for OBJID_CLIENT. }
  TFmxAccessible = class(TInterfacedObject, IDispatch, IAccessible)
  private
    FForm: TCommonCustomForm;
    FControl: TControl;
    function ChildControl(Index: Integer): TControl;
    function VisibleChildCount: Integer;
    function SelfRoleId: Integer;
    function SelfName: string;
    function SelfValue: string;
    function SelfState: Integer;
    { varChild is 0 for "this object" and 1..n for a child handled without
      its own IAccessible. Resolve once, here, so every method agrees. }
    function Resolve(varChild: OleVariant; out Target: TControl): Boolean;
  public
    constructor Create(AForm: TCommonCustomForm; AControl: TControl);

    { IDispatch -- MSAA clients reach IAccessible through it, but none of
      them need real late binding from us. }
    function GetTypeInfoCount(out Count: Integer): HResult; stdcall;
    function GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult; stdcall;
    function GetIDsOfNames(const IID: TGUID; Names: Pointer;
      NameCount, LocaleID: Integer; DispIDs: Pointer): HResult; stdcall;
    function Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
      Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult; stdcall;

    { IAccessible }
    function Get_accParent(out ppdispParent: IDispatch): HResult; stdcall;
    function Get_accChildCount(out pcountChildren: Integer): HResult; stdcall;
    function Get_accChild(varChild: OleVariant; out ppdispChild: IDispatch): HResult; stdcall;
    function Get_accName(varChild: OleVariant; out pszName: WideString): HResult; stdcall;
    function Get_accValue(varChild: OleVariant; out pszValue: WideString): HResult; stdcall;
    function Get_accDescription(varChild: OleVariant; out pszDescription: WideString): HResult; stdcall;
    function Get_accRole(varChild: OleVariant; out pvarRole: OleVariant): HResult; stdcall;
    function Get_accState(varChild: OleVariant; out pvarState: OleVariant): HResult; stdcall;
    function Get_accHelp(varChild: OleVariant; out pszHelp: WideString): HResult; stdcall;
    function Get_accHelpTopic(out pszHelpFile: WideString; varChild: OleVariant;
      out pidTopic: Integer): HResult; stdcall;
    function Get_accKeyboardShortcut(varChild: OleVariant; out pszKeyboardShortcut: WideString): HResult; stdcall;
    function Get_accFocus(out pvarChild: OleVariant): HResult; stdcall;
    function Get_accSelection(out pvarChildren: OleVariant): HResult; stdcall;
    function Get_accDefaultAction(varChild: OleVariant; out pszDefaultAction: WideString): HResult; stdcall;
    function accSelect(flagsSelect: Integer; varChild: OleVariant): HResult; stdcall;
    function accLocation(out pxLeft, pyTop, pcxWidth, pcyHeight: Integer;
      varChild: OleVariant): HResult; stdcall;
    function accNavigate(navDir: Integer; varStart: OleVariant;
      out pvarEndUpAt: OleVariant): HResult; stdcall;
    function accHitTest(xLeft, yTop: Integer; out pvarChild: OleVariant): HResult; stdcall;
    function accDoDefaultAction(varChild: OleVariant): HResult; stdcall;
    function Set_accName(varChild: OleVariant; const pszName: WideString): HResult; stdcall;
    function Set_accValue(varChild: OleVariant; const pszValue: WideString): HResult; stdcall;
  end;

  THookRec = record
    Wnd: HWND;
    OldProc: Pointer;
    Root: IAccessible;
  end;

var
  GHooks: TDictionary<HWND, THookRec>;

{ ---------------- control -> accessible facts ---------------- }

{ Role for the control class. Anything unrecognised is a grouping, which is
  the honest answer -- ROLE_SYSTEM_CLIENT would claim more than we know. }
function RoleOf(C: TControl): Integer;
begin
  if C = nil then Exit(ROLE_SYSTEM_CLIENT);
  if C is TButton        then Exit(ROLE_SYSTEM_PUSHBUTTON);
  if C is TCheckBox      then Exit(ROLE_SYSTEM_CHECKBUTTON);
  if C is TRadioButton   then Exit(ROLE_SYSTEM_RADIOBUTTON);
  if C is TEdit          then Exit(ROLE_SYSTEM_TEXT);
  if C is TMemo          then Exit(ROLE_SYSTEM_TEXT);
  if C is TComboBox      then Exit(ROLE_SYSTEM_COMBOBOX);
  if C is TListBox       then Exit(ROLE_SYSTEM_LIST);
  if C is TListBoxItem   then Exit(ROLE_SYSTEM_LISTITEM);
  if C is TTabControl    then Exit(ROLE_SYSTEM_PAGETABLIST);
  if C is TTabItem       then Exit(ROLE_SYSTEM_PAGETAB);
  if C is TLabel         then Exit(ROLE_SYSTEM_STATICTEXT);
  if C is TText          then Exit(ROLE_SYSTEM_STATICTEXT);
  if C is TTrackBar      then Exit(ROLE_SYSTEM_SLIDER);
  if C is TProgressBar   then Exit(ROLE_SYSTEM_PROGRESSBAR);
  if C is TScrollBar     then Exit(ROLE_SYSTEM_SCROLLBAR);
  Result := ROLE_SYSTEM_GROUPING;
end;

{ The label a reader speaks. Prefer an explicit hint (FMX's nearest thing to
  an accessible name), then the visible text, then the design-time control
  name -- which is poor but better than an unnamed node the user cannot
  distinguish from its siblings. }
function NameOf(C: TControl): string;
begin
  if C = nil then Exit('');
  if C.Hint <> '' then Exit(C.Hint);
  if C is TButton      then Exit(TButton(C).Text);
  if C is TCheckBox    then Exit(TCheckBox(C).Text);
  if C is TRadioButton then Exit(TRadioButton(C).Text);
  if C is TLabel       then Exit(TLabel(C).Text);
  if C is TText        then Exit(TText(C).Text);
  if C is TTabItem     then Exit(TTabItem(C).Text);
  if C is TListBoxItem then Exit(TListBoxItem(C).Text);
  Result := C.Name;
end;

{ The value a reader reads out after the name. Only the controls that carry
  user data have one; for the rest MSAA wants S_FALSE and an empty string,
  which Get_accValue turns this into. }
function ValueOf(C: TControl): string;
begin
  Result := '';
  if C = nil then Exit;
  if C is TEdit     then Exit(TEdit(C).Text);
  if C is TMemo     then Exit(TMemo(C).Text);
  if C is TComboBox then
  begin
    if TComboBox(C).ItemIndex >= 0 then Exit(TComboBox(C).Items[TComboBox(C).ItemIndex]);
    Exit('');
  end;
  if C is TTrackBar then Exit(FloatToStr(TTrackBar(C).Value));
end;

function StateOf(C: TControl): Integer;
begin
  Result := 0;
  if C = nil then Exit;
  if not C.Visible then Result := Result or STATE_SYSTEM_INVISIBLE;
  if not C.Enabled then Result := Result or STATE_SYSTEM_UNAVAILABLE;
  if C.IsFocused  then Result := Result or STATE_SYSTEM_FOCUSED;
  if C.CanFocus   then Result := Result or STATE_SYSTEM_FOCUSABLE;
  if C is TCheckBox then
    if TCheckBox(C).IsChecked then Result := Result or STATE_SYSTEM_CHECKED;
  if C is TRadioButton then
    if TRadioButton(C).IsChecked then Result := Result or STATE_SYSTEM_CHECKED;
  if C is TEdit then
    if TEdit(C).ReadOnly then Result := Result or STATE_SYSTEM_READONLY;
  if C is TMemo then
    if TMemo(C).ReadOnly then Result := Result or STATE_SYSTEM_READONLY;
  if C is TTabItem then
    if TTabItem(C).IsSelected then Result := Result or STATE_SYSTEM_SELECTED;
end;

{ Screen rectangle in pixels. FMX works in logical units, so the form's
  scale has to be applied or every rect is wrong on a HiDPI display -- the
  case where a screen reader's focus highlight being off is most visible. }
function ScreenRectOf(Form: TCommonCustomForm; C: TControl;
                      out L, T, W, H: Integer): Boolean;
var
  R: TRectF;
  P: TPointF;
  Scale: Single;
begin
  Result := False;
  if Form = nil then Exit;
  Scale := Form.Handle.Scale;
  if C = nil then
  begin
    L := Round(Form.Left * Scale);
    T := Round(Form.Top * Scale);
    W := Round(Form.Width * Scale);
    H := Round(Form.Height * Scale);
    Exit(True);
  end;
  R := C.AbsoluteRect;
  P := Form.ClientToScreen(PointF(R.Left, R.Top));
  L := Round(P.X * Scale);
  T := Round(P.Y * Scale);
  W := Round(R.Width  * Scale);
  H := Round(R.Height * Scale);
  Result := True;
end;

{ ---------------- TFmxAccessible ---------------- }

constructor TFmxAccessible.Create(AForm: TCommonCustomForm; AControl: TControl);
begin
  inherited Create;
  FForm := AForm;
  FControl := AControl;
end;

{ Children are the visible controls one level down. Invisible ones are
  skipped rather than reported with STATE_SYSTEM_INVISIBLE, because a
  reader's child index has to stay stable with what the user can reach. }
function TFmxAccessible.VisibleChildCount: Integer;
var
  i: Integer;
  Parent: TFmxObject;
begin
  Result := 0;
  if FControl <> nil then Parent := FControl else Parent := FForm;
  if Parent = nil then Exit;
  for i := 0 to Parent.ChildrenCount - 1 do
    if (Parent.Children[i] is TControl) and TControl(Parent.Children[i]).Visible then
      Inc(Result);
end;

function TFmxAccessible.ChildControl(Index: Integer): TControl;
var
  i, n: Integer;
  Parent: TFmxObject;
begin
  Result := nil;
  if FControl <> nil then Parent := FControl else Parent := FForm;
  if Parent = nil then Exit;
  n := 0;
  for i := 0 to Parent.ChildrenCount - 1 do
    if (Parent.Children[i] is TControl) and TControl(Parent.Children[i]).Visible then
    begin
      Inc(n);
      if n = Index then Exit(TControl(Parent.Children[i]));
    end;
end;

function TFmxAccessible.Resolve(varChild: OleVariant; out Target: TControl): Boolean;
var
  Idx: Integer;
begin
  Target := FControl;
  Result := True;
  if VarIsNull(varChild) or VarIsEmpty(varChild) then Exit;
  Idx := Integer(varChild);
  if Idx = CHILDID_SELF then Exit;
  Target := ChildControl(Idx);
  Result := Target <> nil;
end;

function TFmxAccessible.SelfRoleId: Integer; begin Result := RoleOf(FControl); end;
function TFmxAccessible.SelfValue: string;   begin Result := ValueOf(FControl); end;
function TFmxAccessible.SelfState: Integer;  begin Result := StateOf(FControl); end;

function TFmxAccessible.SelfName: string;
begin
  if FControl = nil then
  begin
    if FForm <> nil then Result := FForm.Caption else Result := '';
    Exit;
  end;
  Result := NameOf(FControl);
end;

{ ---- IDispatch: present but inert. ---- }

function TFmxAccessible.GetTypeInfoCount(out Count: Integer): HResult;
begin
  Count := 0;
  Result := S_OK;
end;

function TFmxAccessible.GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult;
begin
  Pointer(TypeInfo) := nil;
  Result := E_NOTIMPL;
end;

function TFmxAccessible.GetIDsOfNames(const IID: TGUID; Names: Pointer;
  NameCount, LocaleID: Integer; DispIDs: Pointer): HResult;
begin
  Result := E_NOTIMPL;
end;

function TFmxAccessible.Invoke(DispID: Integer; const IID: TGUID;
  LocaleID: Integer; Flags: Word; var Params; VarResult, ExcepInfo,
  ArgErr: Pointer): HResult;
begin
  Result := E_NOTIMPL;
end;

{ ---- IAccessible ---- }

function TFmxAccessible.Get_accParent(out ppdispParent: IDispatch): HResult;
var
  P: TFmxObject;
begin
  ppdispParent := nil;
  { The root's parent is the window itself, which oleacc supplies. }
  if FControl = nil then Exit(S_FALSE);
  P := FControl.Parent;
  if (P = nil) or (not (P is TControl)) then
    ppdispParent := TFmxAccessible.Create(FForm, nil) as IDispatch
  else
    ppdispParent := TFmxAccessible.Create(FForm, TControl(P)) as IDispatch;
  Result := S_OK;
end;

function TFmxAccessible.Get_accChildCount(out pcountChildren: Integer): HResult;
begin
  pcountChildren := VisibleChildCount;
  Result := S_OK;
end;

function TFmxAccessible.Get_accChild(varChild: OleVariant;
  out ppdispChild: IDispatch): HResult;
var
  C: TControl;
begin
  ppdispChild := nil;
  C := ChildControl(Integer(varChild));
  if C = nil then Exit(S_FALSE);
  ppdispChild := TFmxAccessible.Create(FForm, C) as IDispatch;
  Result := S_OK;
end;

function TFmxAccessible.Get_accName(varChild: OleVariant;
  out pszName: WideString): HResult;
var
  C: TControl;
begin
  pszName := '';
  if not Resolve(varChild, C) then Exit(E_INVALIDARG);
  if C = FControl then pszName := SelfName else pszName := NameOf(C);
  if pszName = '' then Result := S_FALSE else Result := S_OK;
end;

function TFmxAccessible.Get_accValue(varChild: OleVariant;
  out pszValue: WideString): HResult;
var
  C: TControl;
begin
  pszValue := '';
  if not Resolve(varChild, C) then Exit(E_INVALIDARG);
  pszValue := ValueOf(C);
  if pszValue = '' then Result := S_FALSE else Result := S_OK;
end;

function TFmxAccessible.Get_accDescription(varChild: OleVariant;
  out pszDescription: WideString): HResult;
begin
  pszDescription := '';
  Result := S_FALSE;
end;

function TFmxAccessible.Get_accRole(varChild: OleVariant;
  out pvarRole: OleVariant): HResult;
var
  C: TControl;
begin
  if not Resolve(varChild, C) then Exit(E_INVALIDARG);
  if C = FControl then pvarRole := SelfRoleId else pvarRole := RoleOf(C);
  Result := S_OK;
end;

function TFmxAccessible.Get_accState(varChild: OleVariant;
  out pvarState: OleVariant): HResult;
var
  C: TControl;
begin
  if not Resolve(varChild, C) then Exit(E_INVALIDARG);
  if C = FControl then pvarState := SelfState else pvarState := StateOf(C);
  Result := S_OK;
end;

function TFmxAccessible.Get_accHelp(varChild: OleVariant;
  out pszHelp: WideString): HResult;
begin
  pszHelp := '';
  Result := S_FALSE;
end;

function TFmxAccessible.Get_accHelpTopic(out pszHelpFile: WideString;
  varChild: OleVariant; out pidTopic: Integer): HResult;
begin
  pszHelpFile := '';
  pidTopic := 0;
  Result := S_FALSE;
end;

function TFmxAccessible.Get_accKeyboardShortcut(varChild: OleVariant;
  out pszKeyboardShortcut: WideString): HResult;
begin
  pszKeyboardShortcut := '';
  Result := S_FALSE;
end;

{ Depth-first search for the focused control anywhere below Root.

  Immediate children are not enough. Studio nests every actionable control
  under layouts, so the form root's direct children are containers that are
  never themselves focused -- a child-index scan returns Null while an edit
  or button genuinely has focus, and NVDA/Narrator lose the caret entirely.
  (Codex P1 on #557.) }
function FindFocusedDescendant(Root: TFmxObject): TControl;
var
  i: Integer;
  Kid: TFmxObject;
  Found: TControl;
begin
  Result := nil;
  if Root = nil then Exit;
  for i := 0 to Root.ChildrenCount - 1 do
  begin
    Kid := Root.Children[i];
    if not (Kid is TControl) then Continue;
    if not TControl(Kid).Visible then Continue;
    if TControl(Kid).IsFocused then Exit(TControl(Kid));
    Found := FindFocusedDescendant(Kid);
    if Found <> nil then Exit(Found);
  end;
end;

function TFmxAccessible.Get_accFocus(out pvarChild: OleVariant): HResult;
var
  i: Integer;
  C, Focused: TControl;
  Root: TFmxObject;
begin
  pvarChild := Null;
  if (FControl <> nil) and FControl.IsFocused then
  begin
    pvarChild := CHILDID_SELF;
    Exit(S_OK);
  end;

  { A direct child answers as a child id, which is the cheapest form and the
    one clients handle best. }
  for i := 1 to VisibleChildCount do
  begin
    C := ChildControl(i);
    if (C <> nil) and C.IsFocused then
    begin
      pvarChild := i;
      Exit(S_OK);
    end;
  end;

  { Otherwise hand back a full object for the focused descendant. MSAA
    allows pvarChild to carry an IDispatch precisely so a container can
    point past its own child list. }
  if FControl <> nil then Root := FControl else Root := FForm;
  Focused := FindFocusedDescendant(Root);
  if Focused <> nil then
  begin
    pvarChild := TFmxAccessible.Create(FForm, Focused) as IDispatch;
    Exit(S_OK);
  end;
  Result := S_OK;
end;

function TFmxAccessible.Get_accSelection(out pvarChildren: OleVariant): HResult;
begin
  pvarChildren := Null;
  Result := S_FALSE;
end;

function TFmxAccessible.Get_accDefaultAction(varChild: OleVariant;
  out pszDefaultAction: WideString): HResult;
var
  C: TControl;
begin
  pszDefaultAction := '';
  if not Resolve(varChild, C) then Exit(E_INVALIDARG);
  if (C is TButton) or (C is TTabItem) or (C is TListBoxItem) then
  begin
    pszDefaultAction := 'Press';
    Exit(S_OK);
  end;
  if (C is TCheckBox) or (C is TRadioButton) then
  begin
    pszDefaultAction := 'Toggle';
    Exit(S_OK);
  end;
  Result := S_FALSE;
end;

function TFmxAccessible.accSelect(flagsSelect: Integer;
  varChild: OleVariant): HResult;
var
  C: TControl;
begin
  if not Resolve(varChild, C) then Exit(E_INVALIDARG);
  if C = nil then Exit(S_FALSE);
  Result := S_FALSE;
  { TAKESELECTION is what a reader sends to move through a list; ignoring it
    left arrow-key navigation dead for exactly the lists Studio navigates
    with. Both flags can arrive together. }
  if (flagsSelect and SELFLAG_TAKESELECTION) <> 0 then
  begin
    if C is TListBoxItem then
    begin
      if TListBoxItem(C).ListBox <> nil then
        TListBoxItem(C).ListBox.ItemIndex := TListBoxItem(C).Index
      else
        TListBoxItem(C).IsSelected := True;
      Result := S_OK;
    end
    else if C is TTabItem then
    begin
      if TTabItem(C).TabControl <> nil then
        TTabItem(C).TabControl.ActiveTab := TTabItem(C);
      Result := S_OK;
    end;
  end;
  if ((flagsSelect and SELFLAG_TAKEFOCUS) <> 0) and C.CanFocus then
  begin
    C.SetFocus;
    Result := S_OK;
  end;
end;

function TFmxAccessible.accLocation(out pxLeft, pyTop, pcxWidth,
  pcyHeight: Integer; varChild: OleVariant): HResult;
var
  C: TControl;
begin
  pxLeft := 0; pyTop := 0; pcxWidth := 0; pcyHeight := 0;
  if not Resolve(varChild, C) then Exit(E_INVALIDARG);
  if not ScreenRectOf(FForm, C, pxLeft, pyTop, pcxWidth, pcyHeight) then
    Exit(S_FALSE);
  Result := S_OK;
end;

function TFmxAccessible.accNavigate(navDir: Integer; varStart: OleVariant;
  out pvarEndUpAt: OleVariant): HResult;
var
  Disp: IDispatch;
begin
  pvarEndUpAt := Null;
  case navDir of
    NAVDIR_FIRSTCHILD:
      begin
        if VisibleChildCount = 0 then Exit(S_FALSE);
        if Get_accChild(1, Disp) <> S_OK then Exit(S_FALSE);
        pvarEndUpAt := Disp;
        Exit(S_OK);
      end;
    NAVDIR_LASTCHILD:
      begin
        if VisibleChildCount = 0 then Exit(S_FALSE);
        if Get_accChild(VisibleChildCount, Disp) <> S_OK then Exit(S_FALSE);
        pvarEndUpAt := Disp;
        Exit(S_OK);
      end;
  end;
  { NEXT / PREVIOUS / UP / DOWN are left to the client, which can walk the
    child list it already has. Returning S_FALSE is the documented way to
    say "no such neighbour" and readers handle it. }
  Result := S_FALSE;
end;

function TFmxAccessible.accHitTest(xLeft, yTop: Integer;
  out pvarChild: OleVariant): HResult;
var
  i, L, T, W, H: Integer;
  C: TControl;
begin
  pvarChild := Null;
  for i := 1 to VisibleChildCount do
  begin
    C := ChildControl(i);
    if C = nil then Continue;
    if not ScreenRectOf(FForm, C, L, T, W, H) then Continue;
    if (xLeft >= L) and (xLeft < L + W) and (yTop >= T) and (yTop < T + H) then
    begin
      pvarChild := i;
      Exit(S_OK);
    end;
  end;
  pvarChild := CHILDID_SELF;
  Result := S_OK;
end;

function TFmxAccessible.accDoDefaultAction(varChild: OleVariant): HResult;
var
  C: TControl;
begin
  if not Resolve(varChild, C) then Exit(E_INVALIDARG);
  if C is TButton then
  begin
    if Assigned(TButton(C).OnClick) then TButton(C).OnClick(C);
    Exit(S_OK);
  end;
  if C is TCheckBox then
  begin
    TCheckBox(C).IsChecked := not TCheckBox(C).IsChecked;
    Exit(S_OK);
  end;
  if C is TTabItem then
  begin
    if TTabItem(C).TabControl <> nil then
      TTabItem(C).TabControl.ActiveTab := TTabItem(C);
    Exit(S_OK);
  end;
  { List items were advertising a Press action that landed here and fell
    through to S_FALSE. Studio drives session, file and config navigation
    off list-item selection, so a reader could see the action, invoke it,
    and get nothing. Select through the owning ListBox -- that is what a
    mouse click does, and it is what fires the OnChange the UI listens to
    -- then run the item's own OnClick if it has one. (Codex P1 on #557.) }
  if C is TListBoxItem then
  begin
    if TListBoxItem(C).ListBox <> nil then
      TListBoxItem(C).ListBox.ItemIndex := TListBoxItem(C).Index
    else
      TListBoxItem(C).IsSelected := True;
    if Assigned(TListBoxItem(C).OnClick) then TListBoxItem(C).OnClick(C);
    Exit(S_OK);
  end;
  Result := S_FALSE;
end;

{ The two setters exist because IAccessible declares them. A screen reader
  renaming our controls is not something we want to honour. }
function TFmxAccessible.Set_accName(varChild: OleVariant;
  const pszName: WideString): HResult;
begin
  Result := E_NOTIMPL;
end;

function TFmxAccessible.Set_accValue(varChild: OleVariant;
  const pszValue: WideString): HResult;
begin
  Result := E_NOTIMPL;
end;

{ ---------------- window hook ---------------- }

function AccWndProc(Wnd: HWND; Msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  Rec: THookRec;
begin
  if not GHooks.TryGetValue(Wnd, Rec) then
    Exit(DefWindowProc(Wnd, Msg, wParam, lParam));

  { OBJID_CLIENT is the only id we answer. OBJID_WINDOW (title bar, system
    menu) and the caret / cursor ids belong to the default proc, and taking
    them would break behaviour we get for free. }
  if (Msg = WM_GETOBJECT) and (Integer(lParam) = Integer(OBJID_CLIENT)) then
  begin
    if Rec.Root <> nil then
      Exit(LresultFromObject(IID_IAccessible, wParam, Rec.Root));
  end;

  Result := CallWindowProc(Rec.OldProc, Wnd, Msg, wParam, lParam);
end;

procedure InstallAccessibility(Form: TCommonCustomForm);
var
  Wnd: HWND;
  Rec: THookRec;
begin
  if Form = nil then Exit;
  Wnd := FormToHWND(Form);
  if Wnd = 0 then Exit;
  if GHooks.ContainsKey(Wnd) then Exit;   { idempotent }

  Rec.Wnd := Wnd;
  Rec.Root := TFmxAccessible.Create(Form, nil) as IAccessible;
  Rec.OldProc := Pointer(SetWindowLongPtr(Wnd, GWL_WNDPROC,
                                          NativeInt(@AccWndProc)));
  if Rec.OldProc = nil then Exit;         { subclass refused; leave it alone }
  GHooks.Add(Wnd, Rec);
end;

procedure UninstallAccessibility(Form: TCommonCustomForm);
var
  Wnd: HWND;
  Rec: THookRec;
begin
  if Form = nil then Exit;
  Wnd := FormToHWND(Form);
  if Wnd = 0 then Exit;
  if not GHooks.TryGetValue(Wnd, Rec) then Exit;
  SetWindowLongPtr(Wnd, GWL_WNDPROC, NativeInt(Rec.OldProc));
  GHooks.Remove(Wnd);
end;

initialization
  GHooks := TDictionary<HWND, THookRec>.Create;

finalization
  GHooks.Free;

{$ELSE}

procedure InstallAccessibility(Form: TCommonCustomForm);
begin
  { MSAA is a Windows API; every other platform has its own accessibility
    stack, and the callers stay unconditional. }
end;

procedure UninstallAccessibility(Form: TCommonCustomForm);
begin
end;

{$ENDIF}

end.
