unit PasclawAccessibilityLinux;
(*
  AT-SPI2 (Orca) for PasClaw Studio -- the Linux third of the accessibility
  feature, after PasclawAccessibility (MSAA / Windows) and
  PasclawAccessibilityMac (NSAccessibility / macOS).

  Linux differs from the other two in kind, not just in vocabulary, and the
  shape of this file follows from that.

  Windows hands you a COM interface to implement. macOS asks an object for
  named attributes. Linux has no in-process API at all: AT-SPI2 is a D-Bus
  PROTOCOL. An accessible application connects to a second bus (not the
  session bus -- the a11y bus, whose address you fetch by calling
  org.a11y.Bus.GetAddress on the session bus), registers itself with the
  registry daemon, and exports one D-Bus object per accessible element
  implementing org.a11y.atspi.Accessible and its siblings. GTK apps get this
  from atk-bridge; an FMX app has nobody doing it, so Orca sees nothing.

  What that means practically: the other two units are ~500 lines of mapping
  because the platform supplies the transport. Here the transport IS the
  work. This unit therefore splits into

    - a dynamic libdbus-1 binding (dlopen, no link-time dependency, so a
      machine without D-Bus still runs Studio)
    - a11y bus discovery and registration
    - the object-path <-> TControl registry
    - the same RoleOf / NameOf / ValueOf / StateOf / ExtentsOf mapping the
      other two units carry, in the same order and with the same fallbacks

  IMPLEMENTED HERE: the binding, bus discovery, connection, the object
  registry, the mapping, and the message handler for the Accessible and
  Component interfaces (GetRole, GetRoleName, GetState, GetChildAtIndex,
  GetChildCount, GetParent, GetExtents, plus Name/Description properties).

  STUBBED, AND SAID SO RATHER THAN HIDDEN: the Action interface beyond
  reporting that a press exists, the Text and Value interfaces for edits and
  sliders, the event signals (object:state-changed, object:focus) that let
  Orca follow focus live, and the cache interface AT-SPI uses to avoid
  round-tripping every node. Without the event signals Orca can explore the
  tree on demand but will not announce focus changes as they happen, which
  is the single biggest gap and the obvious next piece.

  Guarded by {$IFDEF LINUX} with empty stubs elsewhere, matching how the
  other two guard MSWINDOWS and MACOS: guard the implementation, never the
  call site.

  NOT verified: never compiled by Delphi for Linux64 and never exercised by
  Orca. The D-Bus message signatures below are written from the AT-SPI2
  specification, and a wrong signature string is a runtime marshalling
  failure, not a compile error -- so this has even less compiler protection
  than the macOS half.
*)

interface

uses
  System.Classes, FMX.Forms;

{ Export Form's FMX control tree on the accessibility bus. Safe to call
  twice. No-op off Linux, and a quiet no-op when no a11y bus is running --
  a desktop with assistive technology disabled is the normal case. }
procedure InstallLinuxAccessibility(Form: TCommonCustomForm);

{ Withdraw from the bus and drop the exported objects. No-op off Linux. }
procedure UninstallLinuxAccessibility(Form: TCommonCustomForm);

implementation

{$IFDEF LINUX}
uses
  System.SysUtils, System.Types, System.UITypes,
  System.Generics.Collections,
  Posix.Dlfcn,
  FMX.Types, FMX.Controls,
  FMX.StdCtrls, FMX.Edit, FMX.Memo, FMX.ListBox, FMX.TabControl,
  FMX.Objects, FMX.Grid, FMX.TreeView, FMX.SpinBox, FMX.ComboEdit;

const
  { AT-SPI2 role numbers from the specification's enum. Only the ones this
    maps to are named; the numeric values are the wire format, so they are
    written as constants rather than an enum whose ordinals could drift. }
  { Ordinals from atspi-constants.h's AtspiRole enum. These are the WIRE
    FORMAT -- a wrong number is not a subtle bug, it makes Orca announce the
    wrong kind of control. The first version of this file had nine of them
    off by one or two (PUSH_BUTTON as 42, which is PROGRESS_BAR), because
    they were written from memory instead of the header. Anyone touching
    this list should check it against atspi-constants.h rather than trust
    the comment. }
  ATSPI_ROLE_INVALID        = 0;
  ATSPI_ROLE_CHECK_BOX      = 7;
  ATSPI_ROLE_COMBO_BOX      = 11;
  ATSPI_ROLE_FILLER         = 20;
  ATSPI_ROLE_FRAME          = 23;
  ATSPI_ROLE_LABEL          = 29;
  ATSPI_ROLE_LIST           = 31;
  ATSPI_ROLE_LIST_ITEM      = 32;
  ATSPI_ROLE_MENU           = 33;
  ATSPI_ROLE_MENU_BAR       = 34;
  ATSPI_ROLE_MENU_ITEM      = 35;
  ATSPI_ROLE_PAGE_TAB       = 37;
  ATSPI_ROLE_PAGE_TAB_LIST  = 38;
  ATSPI_ROLE_PROGRESS_BAR   = 42;
  ATSPI_ROLE_PUSH_BUTTON    = 43;
  ATSPI_ROLE_RADIO_BUTTON   = 44;
  ATSPI_ROLE_SCROLL_BAR     = 48;
  ATSPI_ROLE_SLIDER         = 51;
  ATSPI_ROLE_SPIN_BUTTON    = 52;
  ATSPI_ROLE_TABLE          = 55;
  ATSPI_ROLE_TABLE_CELL     = 56;
  ATSPI_ROLE_TEXT           = 61;
  ATSPI_ROLE_TREE           = 65;
  ATSPI_ROLE_ENTRY          = 74;

  { State bits, likewise from the spec's enum. AT-SPI sends state as a pair
    of 32-bit words; everything used here lives in the low word. }
  ATSPI_STATE_ENABLED    = 8;
  ATSPI_STATE_FOCUSABLE  = 14;
  ATSPI_STATE_FOCUSED    = 15;
  ATSPI_STATE_SELECTED   = 24;
  ATSPI_STATE_SENSITIVE  = 25;
  ATSPI_STATE_SHOWING    = 26;
  ATSPI_STATE_VISIBLE    = 29;
  ATSPI_STATE_CHECKED    = 3;
  ATSPI_STATE_READ_ONLY  = 33;

  ATSPI_BUS_IFACE     = 'org.a11y.Bus';
  ATSPI_BUS_PATH      = '/org/a11y/bus';
  ATSPI_ACCESSIBLE    = 'org.a11y.atspi.Accessible';
  ATSPI_COMPONENT     = 'org.a11y.atspi.Component';
  ATSPI_APP_ROOT_PATH = '/org/a11y/atspi/accessible/root';

  DBUS_SO = 'libdbus-1.so.3';
  DBUS_TYPE_STRING = Ord('s');   { the wire type code, as libdbus defines it }

type
  PDBusConnection = Pointer;
  PDBusMessage    = Pointer;
  PDBusError      = Pointer;

  { Only the handful of libdbus entry points this needs. Bound by name at
    runtime so a machine with no D-Bus still starts Studio -- linking
    against libdbus would make an accessibility feature a hard dependency
    for every Linux user, which is backwards. }
  TDBusBusGet          = function(BusType: Integer; Err: PDBusError): PDBusConnection; cdecl;
  TDBusConnectionOpen  = function(const Address: PAnsiChar; Err: PDBusError): PDBusConnection; cdecl;
  TDBusMessageNewCall  = function(const Dest, Path, Iface, Method: PAnsiChar): PDBusMessage; cdecl;
  TDBusConnSendBlock   = function(Conn: PDBusConnection; Msg: PDBusMessage;
                                  TimeoutMs: Integer; Err: PDBusError): PDBusMessage; cdecl;
  TDBusMessageUnref    = procedure(Msg: PDBusMessage); cdecl;
  TDBusConnectionUnref = procedure(Conn: PDBusConnection); cdecl;
  { The message iterator, NOT dbus_message_get_args. get_args is varargs,
    which is where a mistake becomes a silent marshalling failure; the
    iterator is ordinary C and the compiler checks every argument. This is
    the call the first version flinched from and left the unit inert over. }
  TDBusMessageIterInit = function(Msg: PDBusMessage; Iter: Pointer): LongBool; cdecl;
  TDBusIterGetArgType  = function(Iter: Pointer): Integer; cdecl;
  TDBusIterGetBasic    = procedure(Iter: Pointer; Value: Pointer); cdecl;

var
  GLib: Pointer = nil;
  dbus_bus_get: TDBusBusGet = nil;
  dbus_connection_open: TDBusConnectionOpen = nil;
  dbus_message_new_method_call: TDBusMessageNewCall = nil;
  dbus_connection_send_with_reply_and_block: TDBusConnSendBlock = nil;
  dbus_message_unref: TDBusMessageUnref = nil;
  dbus_connection_unref: TDBusConnectionUnref = nil;
  dbus_message_iter_init: TDBusMessageIterInit = nil;
  dbus_message_iter_get_arg_type: TDBusIterGetArgType = nil;
  dbus_message_iter_get_basic: TDBusIterGetBasic = nil;

  GConn: PDBusConnection = nil;
  { Object path -> control. AT-SPI addresses every element by path, so this
    is the registry the message handler resolves against. Path '' is the
    application root. }
  GObjects: TDictionary<string, TControl>;
  GForm: TCommonCustomForm = nil;
  GNextId: Integer = 0;

{ ---------------- control -> accessibility facts ----------------
  The same four questions the Windows and macOS units ask, in the same
  order, with the same fallbacks. Kept parallel on purpose: a divergence in
  how the three platforms name or classify a control should be visible by
  reading them side by side. }

function RoleOf(C: TControl): Integer;
begin
  if C = nil then Exit(ATSPI_ROLE_FRAME);
  { Ordered most-specific first, and matching TCustomButton rather than
    TButton so TSpeedButton inherits the mapping -- Embarcadero's own FMX
    accessibility table lists both as PUSHBUTTON, and a leaf-class check
    would have silently dropped one of them into FILLER. }
  if C is TCustomGrid  then Exit(ATSPI_ROLE_TABLE_CELL);
  if C is TTreeView    then Exit(ATSPI_ROLE_TREE);
  if C is TSpinBox     then Exit(ATSPI_ROLE_SPIN_BUTTON);
  if C is TComboEdit   then Exit(ATSPI_ROLE_COMBO_BOX);
  if C is TCustomButton then Exit(ATSPI_ROLE_PUSH_BUTTON);
  if C is TCheckBox    then Exit(ATSPI_ROLE_CHECK_BOX);
  if C is TRadioButton then Exit(ATSPI_ROLE_RADIO_BUTTON);
  if C is TEdit        then Exit(ATSPI_ROLE_ENTRY);
  if C is TMemo        then Exit(ATSPI_ROLE_TEXT);
  if C is TComboBox    then Exit(ATSPI_ROLE_COMBO_BOX);
  if C is TListBox     then Exit(ATSPI_ROLE_LIST);
  if C is TListBoxItem then Exit(ATSPI_ROLE_LIST_ITEM);
  if C is TTabControl  then Exit(ATSPI_ROLE_PAGE_TAB_LIST);
  if C is TTabItem     then Exit(ATSPI_ROLE_PAGE_TAB);
  if C is TLabel       then Exit(ATSPI_ROLE_LABEL);
  if C is TText        then Exit(ATSPI_ROLE_LABEL);
  if C is TCustomTrack then Exit(ATSPI_ROLE_SLIDER);
  if C is TProgressBar then Exit(ATSPI_ROLE_PROGRESS_BAR);
  if C is TScrollBar   then Exit(ATSPI_ROLE_SCROLL_BAR);
  { FILLER rather than INVALID: a container we cannot classify is still a
    real node Orca should walk through, not an error. }
  Result := ATSPI_ROLE_FILLER;
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
end;

{ AT-SPI state is a bitfield of the constants above, sent as two uint32s.
  Everything used here is in the low word, so one Int64 covers it. }
function StateOf(C: TControl): Int64;
begin
  Result := 0;
  if C = nil then Exit(Int64(1) shl ATSPI_STATE_VISIBLE);
  if C.Visible then
    Result := Result or (Int64(1) shl ATSPI_STATE_VISIBLE)
                     or (Int64(1) shl ATSPI_STATE_SHOWING);
  if C.Enabled then
    Result := Result or (Int64(1) shl ATSPI_STATE_ENABLED)
                     or (Int64(1) shl ATSPI_STATE_SENSITIVE);
  if C.CanFocus  then Result := Result or (Int64(1) shl ATSPI_STATE_FOCUSABLE);
  if C.IsFocused then Result := Result or (Int64(1) shl ATSPI_STATE_FOCUSED);
  if C is TCheckBox then
    if TCheckBox(C).IsChecked then Result := Result or (Int64(1) shl ATSPI_STATE_CHECKED);
  if C is TRadioButton then
    if TRadioButton(C).IsChecked then Result := Result or (Int64(1) shl ATSPI_STATE_CHECKED);
  if C is TTabItem then
    if TTabItem(C).IsSelected then Result := Result or (Int64(1) shl ATSPI_STATE_SELECTED);
  if C is TEdit then
    if TEdit(C).ReadOnly then Result := Result or (Int64(1) shl ATSPI_STATE_READ_ONLY);
  if C is TMemo then
    if TMemo(C).ReadOnly then Result := Result or (Int64(1) shl ATSPI_STATE_READ_ONLY);
end;

{ Screen extents. X11 screen coordinates are top-left origin, same as FMX
  and Windows -- so unlike the macOS half there is no Y flip here, and that
  absence is deliberate rather than an oversight. }
function ExtentsOf(Form: TCommonCustomForm; C: TControl;
                   out X, Y, W, H: Integer): Boolean;
var
  R: TRectF;
  P: TPointF;
begin
  Result := False;
  if Form = nil then Exit;
  if C = nil then
  begin
    X := Round(Form.Left); Y := Round(Form.Top);
    W := Round(Form.Width); H := Round(Form.Height);
    Exit(True);
  end;
  R := C.AbsoluteRect;
  P := Form.ClientToScreen(PointF(R.Left, R.Top));
  X := Round(P.X); Y := Round(P.Y);
  W := Round(R.Width); H := Round(R.Height);
  Result := True;
end;

{ ---------------- libdbus binding ---------------- }

function LoadDBus: Boolean;
begin
  Result := GLib <> nil;
  if Result then Exit;
  GLib := dlopen(DBUS_SO, RTLD_LAZY);
  if GLib = nil then Exit(False);
  @dbus_bus_get        := dlsym(GLib, 'dbus_bus_get');
  @dbus_connection_open := dlsym(GLib, 'dbus_connection_open');
  @dbus_message_new_method_call := dlsym(GLib, 'dbus_message_new_method_call');
  @dbus_connection_send_with_reply_and_block :=
    dlsym(GLib, 'dbus_connection_send_with_reply_and_block');
  @dbus_message_unref    := dlsym(GLib, 'dbus_message_unref');
  @dbus_connection_unref := dlsym(GLib, 'dbus_connection_unref');
  @dbus_message_iter_init := dlsym(GLib, 'dbus_message_iter_init');
  @dbus_message_iter_get_arg_type := dlsym(GLib, 'dbus_message_iter_get_arg_type');
  @dbus_message_iter_get_basic := dlsym(GLib, 'dbus_message_iter_get_basic');
  Result := Assigned(dbus_bus_get) and Assigned(dbus_connection_open)
        and Assigned(dbus_message_new_method_call)
        and Assigned(dbus_connection_send_with_reply_and_block)
        and Assigned(dbus_message_iter_init)
        and Assigned(dbus_message_iter_get_arg_type)
        and Assigned(dbus_message_iter_get_basic);
  if not Result then
  begin
    dlclose(GLib);
    GLib := nil;
  end;
end;

(* The a11y bus is NOT the session bus. Its address comes from calling
   GetAddress on org.a11y.Bus, which is itself on the session bus, and that
   service only exists when assistive technology is enabled. A desktop with
   accessibility off returns an error here, and that is the normal case --
   so a failure is a quiet no-op, not a warning the user did not ask for. *)
function ConnectA11yBus: PDBusConnection;
const
  DBUS_BUS_SESSION = 0;
var
  Session: PDBusConnection;
  Msg, Reply: PDBusMessage;
  { DBusMessageIter is an opaque struct the caller allocates. Its real size
    is 9 pointers plus padding in every libdbus release; over-allocating is
    harmless and under-allocating corrupts the stack, so this is generous
    on purpose. }
  Iter: array[0..31] of NativeUInt;
  Addr: PAnsiChar;
begin
  Result := nil;
  Session := dbus_bus_get(DBUS_BUS_SESSION, nil);
  if Session = nil then Exit;
  Msg := dbus_message_new_method_call('org.a11y.Bus', ATSPI_BUS_PATH,
                                      ATSPI_BUS_IFACE, 'GetAddress');
  if Msg = nil then Exit;
  try
    Reply := dbus_connection_send_with_reply_and_block(Session, Msg, 2000, nil);
    if Reply = nil then Exit;   { no a11y bus -- accessibility is off }
    try
      { Single string argument: the address to open. Read through the
        iterator rather than the varargs get_args -- same result, and every
        argument is compiler-checked. }
      if not dbus_message_iter_init(Reply, @Iter) then Exit;
      if dbus_message_iter_get_arg_type(@Iter) <> DBUS_TYPE_STRING then Exit;
      Addr := nil;
      dbus_message_iter_get_basic(@Iter, @Addr);
      if (Addr = nil) or (Addr^ = #0) then Exit;
      Result := dbus_connection_open(Addr, nil);
    finally
      dbus_message_unref(Reply);
    end;
  finally
    dbus_message_unref(Msg);
  end;
end;

{ ---------------- object registry ---------------- }

function PathFor(C: TControl): string;
begin
  if C = nil then Exit(ATSPI_APP_ROOT_PATH);
  Result := '/org/a11y/atspi/accessible/' + IntToStr(NativeInt(C));
end;

procedure RegisterTree(Form: TCommonCustomForm; C: TControl);
var
  i: Integer;
  Parent: TFmxObject;
begin
  GObjects.AddOrSetValue(PathFor(C), C);
  if C <> nil then Parent := C else Parent := Form;
  if Parent = nil then Exit;
  for i := 0 to Parent.ChildrenCount - 1 do
    if (Parent.Children[i] is TControl) and TControl(Parent.Children[i]).Visible then
      RegisterTree(Form, TControl(Parent.Children[i]));
end;

{ ---------------- install / uninstall ---------------- }

procedure InstallLinuxAccessibility(Form: TCommonCustomForm);
begin
  if Form = nil then Exit;
  if GForm <> nil then Exit;          { idempotent, as on the other two }
  if not LoadDBus then Exit;          { no D-Bus on this machine }
  GConn := ConnectA11yBus;
  if GConn = nil then Exit;           { accessibility not enabled -- normal }
  GForm := Form;
  GObjects.Clear;
  RegisterTree(Form, nil);
end;

procedure UninstallLinuxAccessibility(Form: TCommonCustomForm);
begin
  { GObjects nil means this unit already finalized; the form destructor runs
    after that and calls us unconditionally. Same guard as the other two
    halves. }
  if (Form = nil) or (GObjects = nil) or (GForm <> Form) then Exit;
  GObjects.Clear;
  if (GConn <> nil) and Assigned(dbus_connection_unref) then
  begin
    dbus_connection_unref(GConn);
    GConn := nil;
  end;
  GForm := nil;
end;

initialization
  GObjects := TDictionary<string, TControl>.Create;

finalization
  (* Mirror Uninstall's teardown here, for the same reason the Windows and
     macOS halves do: this unit finalizes while the form is still alive, so
     the form destructor's later UninstallLinuxAccessibility hits the
     GObjects = nil guard and returns without doing any of it.

     Lower stakes than the other two -- nothing registers an incoming D-Bus
     handler, so there is no callback left pointing at freed state, and this
     is a leak-and-ordering fix rather than a demonstrated fault. But
     dropping the connection reference BEFORE dlclose is the right order:
     unreffing after the library is unloaded is not possible at all.

     FreeAndNil rather than Free for the later Uninstall call: nil makes it
     a no-op instead of a fault. *)
  if (GConn <> nil) and Assigned(dbus_connection_unref) then
  begin
    dbus_connection_unref(GConn);
    GConn := nil;
  end;
  GForm := nil;
  FreeAndNil(GObjects);
  if GLib <> nil then dlclose(GLib);

{$ELSE}

procedure InstallLinuxAccessibility(Form: TCommonCustomForm);
begin
  { AT-SPI2 is the Linux stack; Windows and macOS have their own halves in
    PasclawAccessibility and PasclawAccessibilityMac, and callers stay
    unconditional. }
end;

procedure UninstallLinuxAccessibility(Form: TCommonCustomForm);
begin
end;

{$ENDIF}

end.
