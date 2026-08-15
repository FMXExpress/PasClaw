unit PasclawAccessibilityMac;
(*
  NSAccessibility (VoiceOver) for PasClaw Studio -- the macOS half of
  PasclawAccessibility.

  Same problem as Windows: FMX draws its own controls, so VoiceOver sees one
  opaque NSView and announces nothing inside it. Same shape of answer: walk
  the FMX control tree and expose each control as an accessibility element
  with a role, a label, a value, state and a screen frame.

  Deliberately mirrors the Windows unit -- RoleOf / NameOf / ValueOf /
  StateOf / ScreenRectOf and an Install/Uninstall pair -- so the two read as
  one feature rather than two independent ports. Where they differ, they
  differ because the platforms do:

    Attribute model, not an interface. MSAA asks one IAccessible a fixed set
    of questions. NSAccessibility asks an object for named attributes, so
    the element answers accessibilityAttributeNames and then a value per
    name. That is why this file has a string-keyed dispatch where the
    Windows one has a vtable.

    The Y axis is flipped. macOS screen coordinates put the origin at the
    BOTTOM-left of the primary display; FMX and Windows put it top-left. A
    frame handed to NSAccessibility without that conversion is not slightly
    off, it is mirrored -- VoiceOver's cursor lands at the bottom of the
    window when the control is at the top. ScreenFrameOf does the flip
    against NSScreen's height, and it is the single most likely thing to be
    wrong here if this is ever tested for real.

    Actions instead of DoDefaultAction. VoiceOver presses things through
    accessibilityActionNames / accessibilityPerformAction, so a button gets
    NSAccessibilityPressAction rather than the single default action MSAA
    exposes.

  Windows-only guarded by {$IFDEF MACOS} with empty stubs elsewhere, exactly
  as the Windows unit does with MSWINDOWS -- guard the implementation, never
  the call site.

  NOT verified: this has never been compiled by Delphi for macOS and never
  been read by VoiceOver. See the note at the end of the Windows unit; the
  same caveat applies with more force here, because the Objective-C bridge
  gives the compiler fewer chances to catch a mistake than a COM vtable does.
*)

interface

uses
  System.Classes, FMX.Forms;

{ Expose Form's FMX control tree to VoiceOver. Safe to call twice. No-op off
  macOS. }
procedure InstallMacAccessibility(Form: TCommonCustomForm);

{ Drop the exposed tree. Call before the form is destroyed. No-op off
  macOS. }
procedure UninstallMacAccessibility(Form: TCommonCustomForm);

implementation

{$IFDEF MACOS}
uses
  Macapi.ObjectiveC, Macapi.Foundation, Macapi.AppKit, Macapi.CocoaTypes,
  Macapi.Helpers,
  System.SysUtils, System.Types, System.UITypes, System.Rtti,
  System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Platform.Mac,
  FMX.StdCtrls, FMX.Edit, FMX.Memo, FMX.ListBox, FMX.TabControl,
  FMX.Objects, FMX.Grid, FMX.TreeView, FMX.SpinBox, FMX.ComboEdit;

type
  { The Objective-C face of one element. NSAccessibility is an informal
    protocol -- the runtime asks for these selectors by name -- so the
    interface exists to give the bridge something to publish. }
  IPasclawAXElement = interface(NSObject)
    ['{7B1C4F2E-9A44-4E38-9C1B-2F6D0A5E7C31}']
    function accessibilityAttributeNames: NSArray; cdecl;
    function accessibilityAttributeValue(attribute: NSString): Pointer; cdecl;
    function accessibilityIsAttributeSettable(attribute: NSString): Boolean; cdecl;
    function accessibilityActionNames: NSArray; cdecl;
    function accessibilityPerformAction(action: NSString): Pointer; cdecl;
    function accessibilityIsIgnored: Boolean; cdecl;
    function accessibilityHitTest(point: NSPoint): Pointer; cdecl;
    function accessibilityFocusedUIElement: Pointer; cdecl;
  end;

  { One node over one FMX control, or over the form when FControl is nil. }
  TPasclawAXElement = class(TOCLocal, IPasclawAXElement)
  private
    FForm: TCommonCustomForm;
    FControl: TControl;
    FChildren: TList<TPasclawAXElement>;
    procedure RebuildChildren;
  public
    constructor Create(AForm: TCommonCustomForm; AControl: TControl);
    destructor Destroy; override;
    function GetObjectiveCClass: PTypeInfo; override;

    function accessibilityAttributeNames: NSArray; cdecl;
    function accessibilityAttributeValue(attribute: NSString): Pointer; cdecl;
    function accessibilityIsAttributeSettable(attribute: NSString): Boolean; cdecl;
    function accessibilityActionNames: NSArray; cdecl;
    function accessibilityPerformAction(action: NSString): Pointer; cdecl;
    function accessibilityIsIgnored: Boolean; cdecl;
    function accessibilityHitTest(point: NSPoint): Pointer; cdecl;
    function accessibilityFocusedUIElement: Pointer; cdecl;
  end;

var
  GRoots: TObjectDictionary<TCommonCustomForm, TPasclawAXElement>;

{ ---------------- control -> accessibility facts ----------------
  Same four questions the Windows unit asks, answered with Cocoa's
  vocabulary. Kept in the same order and with the same fallbacks so a change
  to one platform's mapping is obvious when read against the other. }

function RoleOf(C: TControl): NSString;
begin
  if C = nil then Exit(StrToNSStr(NSAccessibilityWindowRole));
  { Most-specific first, and TCustomButton rather than TButton so
    TSpeedButton inherits it -- Embarcadero's FMX accessibility table maps
    both to PUSHBUTTON, and the leaf check dropped TSpeedButton into
    GROUPING. Cocoa has no spin-button role, so TSpinBox uses the
    incrementor, which is what AppKit's own stepper reports. }
  if C is TCustomGrid  then Exit(StrToNSStr(NSAccessibilityCellRole));
  if C is TTreeView    then Exit(StrToNSStr(NSAccessibilityOutlineRole));
  if C is TTreeViewItem then Exit(StrToNSStr(NSAccessibilityRowRole));
  if C is TSpinBox     then Exit(StrToNSStr(NSAccessibilityIncrementorRole));
  if C is TComboEdit   then Exit(StrToNSStr(NSAccessibilityComboBoxRole));
  if C is TCustomButton then Exit(StrToNSStr(NSAccessibilityButtonRole));
  if C is TCheckBox    then Exit(StrToNSStr(NSAccessibilityCheckBoxRole));
  if C is TRadioButton then Exit(StrToNSStr(NSAccessibilityRadioButtonRole));
  if C is TEdit        then Exit(StrToNSStr(NSAccessibilityTextFieldRole));
  if C is TMemo        then Exit(StrToNSStr(NSAccessibilityTextAreaRole));
  if C is TComboBox    then Exit(StrToNSStr(NSAccessibilityPopUpButtonRole));
  if C is TListBox     then Exit(StrToNSStr(NSAccessibilityListRole));
  if C is TListBoxItem then Exit(StrToNSStr(NSAccessibilityRowRole));
  if C is TTabControl  then Exit(StrToNSStr(NSAccessibilityTabGroupRole));
  { A tab is a radio button to Cocoa: one of a set, exactly one chosen.
    VoiceOver announces it correctly and users expect the arrow-key model
    that role implies. }
  if C is TTabItem     then Exit(StrToNSStr(NSAccessibilityRadioButtonRole));
  if C is TLabel       then Exit(StrToNSStr(NSAccessibilityStaticTextRole));
  if C is TText        then Exit(StrToNSStr(NSAccessibilityStaticTextRole));
  if C is TCustomTrack then Exit(StrToNSStr(NSAccessibilitySliderRole));
  if C is TProgressBar then Exit(StrToNSStr(NSAccessibilityProgressIndicatorRole));
  if C is TScrollBar   then Exit(StrToNSStr(NSAccessibilityScrollBarRole));
  Result := StrToNSStr(NSAccessibilityGroupRole);
end;

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

function ValueOf(C: TControl): string;
begin
  Result := '';
  if C = nil then Exit;
  if C is TEdit     then Exit(TEdit(C).Text);
  if C is TMemo     then Exit(TMemo(C).Text);
  if C is TComboBox then
  begin
    if TComboBox(C).ItemIndex >= 0 then
      Exit(TComboBox(C).Items[TComboBox(C).ItemIndex]);
    Exit('');
  end;
  if C is TTrackBar then Exit(FloatToStr(TTrackBar(C).Value));
  { Cocoa reads a checkbox's value as 1/0 rather than through a state mask,
    which is where this diverges from the Windows StateOf. }
  if C is TCheckBox then
    if TCheckBox(C).IsChecked then Exit('1') else Exit('0');
  if C is TRadioButton then
    if TRadioButton(C).IsChecked then Exit('1') else Exit('0');
  if C is TTabItem then
    if TTabItem(C).IsSelected then Exit('1') else Exit('0');
end;

(* Screen frame, with the Y flip that makes or breaks this file.

   FMX gives absolute coordinates in the form's space, origin top-left, and
   AbsoluteRect is in logical units. Cocoa wants a frame in SCREEN
   coordinates with the origin at the bottom-left of the primary display.
   So: convert to screen space, then subtract from the screen height and
   subtract the height again, because NSRect's origin is its bottom-left
   corner rather than its top-left one.

   Getting this wrong does not produce a small offset -- it mirrors the
   window vertically, so VoiceOver's cursor sits at the bottom for a control
   at the top. *)
function ScreenFrameOf(Form: TCommonCustomForm; C: TControl): NSRect;
var
  R: TRectF;
  P: TPointF;
  ScreenH: Single;
begin
  Result := MakeNSRect(0, 0, 0, 0);
  if Form = nil then Exit;
  ScreenH := TNSScreen.Wrap(TNSScreen.OCClass.mainScreen).frame.size.height;
  if C = nil then
  begin
    Result := MakeNSRect(Form.Left,
                         ScreenH - Form.Top - Form.Height,
                         Form.Width, Form.Height);
    Exit;
  end;
  R := C.AbsoluteRect;
  P := Form.ClientToScreen(PointF(R.Left, R.Top));
  Result := MakeNSRect(P.X, ScreenH - P.Y - R.Height, R.Width, R.Height);
end;

{ ---------------- TPasclawAXElement ---------------- }

constructor TPasclawAXElement.Create(AForm: TCommonCustomForm; AControl: TControl);
begin
  inherited Create;
  FForm := AForm;
  FControl := AControl;
  FChildren := TList<TPasclawAXElement>.Create;
end;

destructor TPasclawAXElement.Destroy;
var
  i: Integer;
begin
  for i := 0 to FChildren.Count - 1 do FChildren[i].Free;
  FChildren.Free;
  inherited Destroy;
end;

function TPasclawAXElement.GetObjectiveCClass: PTypeInfo;
begin
  Result := TypeInfo(IPasclawAXElement);
end;

{ Children are rebuilt on demand rather than cached across calls: the Studio
  UI adds and removes controls as tabs change, and a stale child list is how
  a reader ends up announcing a control that is no longer on screen. }
procedure TPasclawAXElement.RebuildChildren;
var
  i: Integer;
  Parent: TFmxObject;
begin
  for i := 0 to FChildren.Count - 1 do FChildren[i].Free;
  FChildren.Clear;
  if FControl <> nil then Parent := FControl else Parent := FForm;
  if Parent = nil then Exit;
  for i := 0 to Parent.ChildrenCount - 1 do
    if (Parent.Children[i] is TControl) and TControl(Parent.Children[i]).Visible then
      FChildren.Add(TPasclawAXElement.Create(FForm, TControl(Parent.Children[i])));
end;

function TPasclawAXElement.accessibilityAttributeNames: NSArray;
var
  Names: NSMutableArray;
begin
  Names := TNSMutableArray.Create;
  Names.addObject(NSObjectToID(StrToNSStr(NSAccessibilityRoleAttribute)));
  Names.addObject(NSObjectToID(StrToNSStr(NSAccessibilityRoleDescriptionAttribute)));
  Names.addObject(NSObjectToID(StrToNSStr(NSAccessibilityTitleAttribute)));
  Names.addObject(NSObjectToID(StrToNSStr(NSAccessibilityValueAttribute)));
  Names.addObject(NSObjectToID(StrToNSStr(NSAccessibilityEnabledAttribute)));
  Names.addObject(NSObjectToID(StrToNSStr(NSAccessibilityFocusedAttribute)));
  Names.addObject(NSObjectToID(StrToNSStr(NSAccessibilityPositionAttribute)));
  Names.addObject(NSObjectToID(StrToNSStr(NSAccessibilitySizeAttribute)));
  Names.addObject(NSObjectToID(StrToNSStr(NSAccessibilityChildrenAttribute)));
  Names.addObject(NSObjectToID(StrToNSStr(NSAccessibilityParentAttribute)));
  Result := Names;
end;

function TPasclawAXElement.accessibilityAttributeValue(attribute: NSString): Pointer;
var
  Attr: string;
  Frame: NSRect;
  Kids: NSMutableArray;
  i: Integer;
begin
  Result := nil;
  Attr := NSStrToStr(attribute);

  if Attr = NSAccessibilityRoleAttribute then
    Exit(NSObjectToID(RoleOf(FControl)));

  if Attr = NSAccessibilityRoleDescriptionAttribute then
    Exit(NSObjectToID(StrToNSStr(
      NSStrToStr(NSAccessibilityRoleDescription(RoleOf(FControl), nil)))));

  if Attr = NSAccessibilityTitleAttribute then
  begin
    if FControl = nil then
    begin
      if FForm <> nil then Exit(NSObjectToID(StrToNSStr(FForm.Caption)));
      Exit(NSObjectToID(StrToNSStr('')));
    end;
    Exit(NSObjectToID(StrToNSStr(NameOf(FControl))));
  end;

  if Attr = NSAccessibilityValueAttribute then
    Exit(NSObjectToID(StrToNSStr(ValueOf(FControl))));

  if Attr = NSAccessibilityEnabledAttribute then
    Exit(NSObjectToID(TNSNumber.Wrap(TNSNumber.OCClass.numberWithBool(
      (FControl = nil) or FControl.Enabled))));

  if Attr = NSAccessibilityFocusedAttribute then
    Exit(NSObjectToID(TNSNumber.Wrap(TNSNumber.OCClass.numberWithBool(
      (FControl <> nil) and FControl.IsFocused))));

  if Attr = NSAccessibilityPositionAttribute then
  begin
    Frame := ScreenFrameOf(FForm, FControl);
    Exit(NSObjectToID(TNSValue.Wrap(TNSValue.OCClass.valueWithPoint(
      MakeNSPoint(Frame.origin.x, Frame.origin.y)))));
  end;

  if Attr = NSAccessibilitySizeAttribute then
  begin
    Frame := ScreenFrameOf(FForm, FControl);
    Exit(NSObjectToID(TNSValue.Wrap(TNSValue.OCClass.valueWithSize(
      MakeNSSize(Frame.size.width, Frame.size.height)))));
  end;

  if Attr = NSAccessibilityChildrenAttribute then
  begin
    RebuildChildren;
    Kids := TNSMutableArray.Create;
    for i := 0 to FChildren.Count - 1 do
      Kids.addObject(FChildren[i].GetObjectID);
    Exit(NSObjectToID(Kids));
  end;

  if Attr = NSAccessibilityParentAttribute then
  begin
    { The root's parent is the window, which AppKit supplies. }
    if FControl = nil then Exit(nil);
    Exit(nil);
  end;
end;

function TPasclawAXElement.accessibilityIsAttributeSettable(attribute: NSString): Boolean;
begin
  { Nothing here is writable. A reader renaming our controls, or setting a
    value behind the app's back, is not something to honour. }
  Result := False;
end;

function TPasclawAXElement.accessibilityActionNames: NSArray;
var
  Actions: NSMutableArray;
begin
  Actions := TNSMutableArray.Create;
  if (FControl is TButton) or (FControl is TTabItem) or
     (FControl is TListBoxItem) or (FControl is TCheckBox) or
     (FControl is TRadioButton) then
    Actions.addObject(NSObjectToID(StrToNSStr(NSAccessibilityPressAction)));
  Result := Actions;
end;

function TPasclawAXElement.accessibilityPerformAction(action: NSString): Pointer;
begin
  Result := nil;
  if NSStrToStr(action) <> NSAccessibilityPressAction then Exit;
  if FControl is TButton then
  begin
    if Assigned(TButton(FControl).OnClick) then
      TButton(FControl).OnClick(FControl);
    Exit;
  end;
  if FControl is TCheckBox then
  begin
    TCheckBox(FControl).IsChecked := not TCheckBox(FControl).IsChecked;
    Exit;
  end;
  if FControl is TTabItem then
  begin
    if TTabItem(FControl).TabControl <> nil then
      TTabItem(FControl).TabControl.ActiveTab := TTabItem(FControl);
    Exit;
  end;
end;

{ A group with no title carries no information a reader can use, so let
  VoiceOver skip straight past it to the children. Anything with a role of
  its own stays visible. }
function TPasclawAXElement.accessibilityIsIgnored: Boolean;
begin
  Result := (FControl <> nil)
            and (NSStrToStr(RoleOf(FControl)) = NSAccessibilityGroupRole)
            and (NameOf(FControl) = '');
end;

function TPasclawAXElement.accessibilityHitTest(point: NSPoint): Pointer;
var
  i: Integer;
  F: NSRect;
begin
  Result := GetObjectID;
  RebuildChildren;
  for i := 0 to FChildren.Count - 1 do
  begin
    F := ScreenFrameOf(FForm, FChildren[i].FControl);
    if (point.x >= F.origin.x) and (point.x < F.origin.x + F.size.width) and
       (point.y >= F.origin.y) and (point.y < F.origin.y + F.size.height) then
      Exit(FChildren[i].accessibilityHitTest(point));
  end;
end;

function TPasclawAXElement.accessibilityFocusedUIElement: Pointer;
var
  i: Integer;
begin
  Result := GetObjectID;
  RebuildChildren;
  for i := 0 to FChildren.Count - 1 do
    if (FChildren[i].FControl <> nil) and FChildren[i].FControl.IsFocused then
      Exit(FChildren[i].accessibilityFocusedUIElement);
end;

{ ---------------- install / uninstall ---------------- }

(* Attach Root to the window's content view, then announce it.

   The first version only retained Root in a dictionary and posted a
   creation notification, which does nothing to make the object reachable:
   VoiceOver walks window -> contentView -> accessibilityChildren, and
   nothing in that chain returned our root, so it still found only the
   opaque FMX view. A notification advertises an element that is already in
   the hierarchy; it cannot put one there. (Codex P1 on #557.)

   setAccessibilityChildren: on the content view is the attachment point --
   it replaces what the view would otherwise report, which is exactly what
   we want, because what it otherwise reports is nothing useful. *)
procedure InstallMacAccessibility(Form: TCommonCustomForm);
var
  Root: TPasclawAXElement;
  Win: NSWindow;
  View: NSView;
  Kids: NSMutableArray;
begin
  if Form = nil then Exit;
  if GRoots.ContainsKey(Form) then Exit;   { idempotent, as on Windows }

  Win := WindowHandleToPlatform(Form.Handle).Wnd;
  if Win = nil then Exit;
  View := Win.contentView;
  if View = nil then Exit;

  Root := TPasclawAXElement.Create(Form, nil);
  GRoots.Add(Form, Root);

  Kids := TNSMutableArray.Create;
  Kids.addObject(Root.GetObjectID);
  View.setAccessibilityChildren(Kids);

  { Only now is the announcement meaningful -- the element it names is
    reachable from the window. }
  NSAccessibilityPostNotification(Root.GetObjectID,
    StrToNSStr(NSAccessibilityCreatedNotification));
end;

procedure UninstallMacAccessibility(Form: TCommonCustomForm);
var
  Root: TPasclawAXElement;
  Win: NSWindow;
  View: NSView;
begin
  if Form = nil then Exit;
  if not GRoots.TryGetValue(Form, Root) then Exit;
  NSAccessibilityPostNotification(Root.GetObjectID,
    StrToNSStr(NSAccessibilityUIElementDestroyedNotification));
  { Detach before freeing, or the view keeps a reference to an element whose
    Delphi side is gone. }
  Win := WindowHandleToPlatform(Form.Handle).Wnd;
  if Win <> nil then
  begin
    View := Win.contentView;
    if View <> nil then View.setAccessibilityChildren(nil);
  end;
  GRoots.Remove(Form);   { owns the value; the dictionary frees it }
end;

initialization
  GRoots := TObjectDictionary<TCommonCustomForm, TPasclawAXElement>.Create([doOwnsValues]);

finalization
  GRoots.Free;

{$ELSE}

procedure InstallMacAccessibility(Form: TCommonCustomForm);
begin
  { NSAccessibility is a macOS API; Windows has its own half in
    PasclawAccessibility, and callers stay unconditional. }
end;

procedure UninstallMacAccessibility(Form: TCommonCustomForm);
begin
end;

{$ENDIF}

end.
