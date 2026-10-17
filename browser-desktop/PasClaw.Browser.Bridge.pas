(*
  PasClaw.Browser.Bridge - the seam between the browser tools and the
  control that actually runs JavaScript.

  Everything the agent knows about a page arrives through one call:
  evaluate a script, get its completion value back as text. The tools in
  PasClaw.Browser.Tools are written against this interface and nothing
  else, which is what lets them compile and run under FPC with a fake
  bridge while the real one -- TWebBrowser on WebView2, Delphi only --
  lives in the FMX form.

  Threading is the bridge implementation's problem, not the tools'. The
  agent loop runs the tools on a background thread; EvaluateJavaScript is
  UI-thread-only and returns through a callback. A real bridge marshals to
  the UI thread, waits on an event with a timeout, and returns. The tools
  see a blocking call that either produced a value or an error. The
  timeout is part of the contract: a page that never finishes a script must
  not hang the turn.

  ONE QUIRK the contract absorbs. WebView2 hands the completion value back
  JSON-encoded: a script that returns the string  hello  arrives as the
  four bytes  "hello"  including the quotes. The tools always return
  JSON.stringify(...) from their scripts so the value is a JSON document;
  on WebView2 it is that document wrapped in one more layer of string
  quoting. UnwrapJsString removes exactly one layer when present, and every
  bridge implementation is expected to apply it before returning, so the
  tools never see the difference between engines.
*)
unit PasClaw.Browser.Bridge;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SyncObjs;

const
  { Per-script wait. Long enough for a heavy page's synchronous script,
    short enough that a wedged tab fails the tool call rather than the
    turn. Tools may pass their own; this is the default. }
  DefaultEvalTimeoutMs = 10000;

  { Navigation wait -- a page load is slower than a script. }
  DefaultNavigateTimeoutMs = 30000;

type
  IBrowserBridge = interface
    ['{5B0C7E2A-4D3F-4A9B-8E11-9C6F2D7A3B14}']
    (* Run JS in the top-level document and return its completion value
       as text, with one layer of JSON string quoting removed (see the
       unit header). False with Err set on timeout, on a script exception,
       or when no page is loaded. *)
    function Eval(const JS: string; TimeoutMs: Integer;
                  out Value, Err: string): Boolean;

    (* Navigate and block until the document has finished loading, or
       TimeoutMs elapses. Back/forward/reload are spelled as the URLs
       'back:', 'forward:' and 'reload:' so the interface stays one call. *)
    function Navigate(const URL: string; TimeoutMs: Integer;
                      out Err: string): Boolean;

    { Cheap reads the hooks use every turn without a script. }
    function CurrentURL: string;
    function CurrentTitle: string;
  end;

  (* One bridge the tools and hooks hold for the life of the process,
     pointed at whichever tab's bridge owns the turn that is running.

     Why this exists: TPasClawAgent is one-per-process (PasClaw.MCP.Bridge
     and PasClaw.Skills.Loader keep module-level state, and the constructor
     raises EPasClawInstance on a second live instance). So the browser
     has ONE agent, registers the six tools and two hooks ONCE, and runs
     tabs' turns one at a time. The tools cannot be rebound per turn --
     the agent owns them -- so instead they hold this object, and the
     turn runner sets Current to the tab's real bridge before ChatHistory
     and clears it after.

     Thread-safety: Current is read on the agent's worker thread and
     written by the turn runner on that same thread, but Shutdown is
     called from the UI thread while a turn may be in flight, so every
     access goes through the lock and each method works on a snapshot.

     Shutdown is the "application is closing" switch: from then on every
     call fails immediately with a clear error instead of touching a
     control that is about to be freed, which lets an in-flight turn wind
     down in a few tool calls rather than ten seconds of timeouts each. *)
  TSwitchingBridge = class(TInterfacedObject, IBrowserBridge)
  private
    FLock:     TCriticalSection;
    FCurrent:  IBrowserBridge;
    FClosing:  Boolean;
    function Snapshot(out Err: string): IBrowserBridge;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetCurrent(const ABridge: IBrowserBridge);
    procedure Shutdown;
    function IsClosing: Boolean;
    function Eval(const JS: string; TimeoutMs: Integer; out Value, Err: string): Boolean;
    function Navigate(const URL: string; TimeoutMs: Integer; out Err: string): Boolean;
    function CurrentURL: string;
    function CurrentTitle: string;
  end;

const
  NoActiveTabError  = 'no tab is running a turn';
  AppClosingError   = 'the application is closing; the page can no longer be reached';

{ Remove exactly one layer of JSON string quoting if S is a quoted JSON
  string; otherwise return S unchanged. Pure; exposed for tests and for
  every bridge implementation to share. }
function UnwrapJsString(const S: string): string;

implementation

uses
  SysUtils;

{ ---------------------------------------------------------- switching }

constructor TSwitchingBridge.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TSwitchingBridge.Destroy;
begin
  FCurrent := nil;
  FLock.Free;
  inherited;
end;

procedure TSwitchingBridge.SetCurrent(const ABridge: IBrowserBridge);
begin
  FLock.Enter;
  try
    if not FClosing then FCurrent := ABridge;
  finally
    FLock.Leave;
  end;
end;

procedure TSwitchingBridge.Shutdown;
begin
  FLock.Enter;
  try
    FClosing := True;
    FCurrent := nil;
  finally
    FLock.Leave;
  end;
end;

function TSwitchingBridge.IsClosing: Boolean;
begin
  FLock.Enter;
  try
    Result := FClosing;
  finally
    FLock.Leave;
  end;
end;

function TSwitchingBridge.Snapshot(out Err: string): IBrowserBridge;
begin
  Err := '';
  FLock.Enter;
  try
    Result := FCurrent;
    if FClosing then Err := AppClosingError
    else if Result = nil then Err := NoActiveTabError;
  finally
    FLock.Leave;
  end;
  if Err <> '' then Result := nil;
end;

function TSwitchingBridge.Eval(const JS: string; TimeoutMs: Integer;
                               out Value, Err: string): Boolean;
var
  B: IBrowserBridge;
begin
  Value := '';
  B := Snapshot(Err);
  if B = nil then Exit(False);
  Result := B.Eval(JS, TimeoutMs, Value, Err);
end;

function TSwitchingBridge.Navigate(const URL: string; TimeoutMs: Integer;
                                   out Err: string): Boolean;
var
  B: IBrowserBridge;
begin
  B := Snapshot(Err);
  if B = nil then Exit(False);
  Result := B.Navigate(URL, TimeoutMs, Err);
end;

function TSwitchingBridge.CurrentURL: string;
var
  B: IBrowserBridge;
  Err: string;
begin
  B := Snapshot(Err);
  if B = nil then Exit('');
  Result := B.CurrentURL;
end;

function TSwitchingBridge.CurrentTitle: string;
var
  B: IBrowserBridge;
  Err: string;
begin
  B := Snapshot(Err);
  if B = nil then Exit('');
  Result := B.CurrentTitle;
end;

{ ------------------------------------------------------------- unwrap }

function UnwrapJsString(const S: string): string;
var
  i, n: Integer;
  T: string;
  C: Char;
  W: UnicodeString;   { one code point, or a surrogate pair, before UTF-8 encoding }
begin
  T := Trim(S);
  n := Length(T);
  if (n < 2) or (T[1] <> '"') or (T[n] <> '"') then
    Exit(S);

  { Decode the JSON escapes a stringified document can contain. This is
    the inverse of JSON.stringify on a string, no more: \uXXXX for the
    BMP, the short escapes, and pass-through for anything else. }
  Result := '';
  i := 2;
  while i < n do
  begin
    C := T[i];
    if (C = '\') and (i + 1 < n) then
    begin
      Inc(i);
      case T[i] of
        '"':  Result := Result + '"';
        '\':  Result := Result + '\';
        '/':  Result := Result + '/';
        'b':  Result := Result + #8;
        'f':  Result := Result + #12;
        'n':  Result := Result + #10;
        'r':  Result := Result + #13;
        't':  Result := Result + #9;
        'u':
          if i + 4 < n then
          begin
            (* Not Chr(): on FPC `string` is UTF-8 bytes here, so Chr(233)
               for é would emit one byte where two are needed and the
               result is a broken sequence. Go through UnicodeString and
               UTF8Encode, which is right on both compilers -- Delphi
               converts the UTF-8 back to UTF-16 on assignment, FPC keeps
               the bytes -- and which also handles a surrogate pair
               (😀) when both halves are present. *)
            W := UnicodeString(WideChar(StrToIntDef('$' + Copy(T, i + 1, 4), Ord('?'))));
            Inc(i, 4);
            if (Word(W[1]) >= $D800) and (Word(W[1]) <= $DBFF) and
               (i + 6 < n) and (T[i + 1] = '\') and (T[i + 2] = 'u') then
            begin
              W := W + UnicodeString(WideChar(StrToIntDef('$' + Copy(T, i + 3, 4), Ord('?'))));
              Inc(i, 6);
            end;
            Result := Result + UTF8Encode(W);
          end;
      else
        Result := Result + '\' + T[i];
      end;
    end
    else
      Result := Result + C;
    Inc(i);
  end;
end;

end.
