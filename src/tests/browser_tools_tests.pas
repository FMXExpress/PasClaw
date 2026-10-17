program browser_tools_tests;
(*
  Covers the FPC-compilable layer of the PasClaw Browser (browser-desktop/) -- the part that
  can be wrong in interesting ways and the part no CI compiler can reach
  once the FMX form is involved:

    PasClaw.Browser.Bridge    UnwrapJsString (the WebView2 quoting quirk)
    PasClaw.Browser.Tools     six tools against a fake bridge: argument
                              validation, the 24 KB cap and offset, handle
                              validation, what JS each tool emits, the
                              read-only / mutating split
    PasClaw.Browser.Hooks     page context stamped once and only once;
                              the confirm gate cancels with a synthetic
                              result, remembers "always for this host",
                              and refuses when no asker is wired
    PasClaw.Browser.Session   JSON round-trip through a real temp file

  The fake bridge answers by recognising the script it was handed, and
  records that script so a test can assert on what the tool actually
  asked the page to do -- the JS is the contract, not an implementation
  detail.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Providers.Types,
  PasClaw.Tools.Types,
  PasClaw.Browser.Bridge,
  PasClaw.Browser.Tools,
  PasClaw.Browser.Hooks,
  PasClaw.Browser.Session;

var
  GTmpDir: string;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;

procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected to contain "' + Needle + '" in: ' + Copy(Hay, 1, 160)); end;

{ ------------------------------------------------------------------ }
{ A bridge that recognises the script it is given.                    }

type
  TFakeBridge = class(TInterfacedObject, IBrowserBridge)
  public
    LastJS:      string;
    LastNavURL:  string;
    FailEval:    Boolean;      { simulate a timeout }
    PageText:    string;
    Selection:   string;
    URL, Title:  string;
    EvalCalls:   Integer;
    constructor Create;
    function Eval(const JS: string; TimeoutMs: Integer; out Value, Err: string): Boolean;
    function Navigate(const AURL: string; TimeoutMs: Integer; out Err: string): Boolean;
    function CurrentURL: string;
    function CurrentTitle: string;
  end;

constructor TFakeBridge.Create;
begin
  inherited Create;
  URL := 'https://example.com/docs/page?x=1';
  Title := 'Example Page';
  PageText := 'Hello world. This is the page.';
  Selection := '';
end;

function TFakeBridge.CurrentURL: string;   begin Result := URL; end;
function TFakeBridge.CurrentTitle: string; begin Result := Title; end;

function TFakeBridge.Navigate(const AURL: string; TimeoutMs: Integer; out Err: string): Boolean;
begin
  Err := '';
  LastNavURL := AURL;
  if AURL = 'https://unreachable.invalid' then
  begin
    Err := 'net::ERR_NAME_NOT_RESOLVED';
    Exit(False);
  end;
  if AURL = 'back:' then URL := 'https://example.com/'
  else if Pos(':', AURL) = Length(AURL) then { forward:/reload: keep URL }
  else URL := AURL;
  Result := True;
end;

function JStr(const S: string): string;
begin
  Result := JsStr(S);   { same escaping the tools use }
end;

function TFakeBridge.Eval(const JS: string; TimeoutMs: Integer; out Value, Err: string): Boolean;
begin
  Inc(EvalCalls);
  LastJS := JS;
  Err := '';
  Value := '';
  if FailEval then
  begin
    Err := 'timed out after ' + IntToStr(TimeoutMs) + ' ms';
    Exit(False);
  end;

  { Recognise each tool's script by a distinctive substring. }
  if Pos('return JSON.stringify(String(window.getSelection()))', JS) > 0 then
    Value := '"' + Selection + '"'                                { hook's selection read, still quoted }
  else if (Pos('innerText', JS) > 0) and (Pos('selection:s', JS) > 0) then
    Value := '{"url":' + JStr(URL) + ',"title":' + JStr(Title) +
             ',"selection":' + JStr(Selection) + ',"text":' + JStr(PageText) + '}'
  else if Pos('querySelectorAll("h1,h2', JS) > 0 then
    Value := '{"url":' + JStr(URL) + ',"title":' + JStr(Title) + ',"count":2,"items":[' +
             '{"handle":"h1","tag":"h1","text":"Welcome"},' +
             '{"handle":"h2","tag":"a","text":"Docs","href":"https://example.com/docs"}]}'
  else if Pos('bad selector', JS) > 0 then
  begin
    if Pos('"[[broken"', JS) > 0 then
      Value := '{"error":"bad selector: [[broken is not a valid selector"}'
    else
      Value := '{"count":1,"items":[{"handle":"h3","tag":"input","text":""}]}';
  end
  else if (Pos('.click();', JS) > 0) and (Pos('data-pc-handle', JS) > 0) then
  begin
    if Pos('"h99"', JS) > 0 then
      Value := '{"error":"no element with handle h99 -- the page may have navigated; call browser_find again"}'
    else
      Value := '{"ok":true,"tag":"button","text":"Submit"}';
  end
  else if Pos('dispatchEvent(new Event("input"', JS) > 0 then
    Value := '{"ok":true,"tag":"input","value":"typed"}'
  else if Pos('var r=eval(', JS) > 0 then
  begin
    if Pos('throw', JS) > 0 then
      Value := '{"error":"boom"}'
    else
      Value := '{"value":"forty-two"}';
  end
  else
    Value := '{}';
  Result := True;
end;

{ ------------------------------------------------------------------ }

procedure TestUnwrap;
const
  { Built by concatenation so the backslash is a real byte in the source.
    A first version wrote '"A"' inline and the file-writing layer
    decoded it to '"A"' before the compiler ever saw it -- so the escape
    branch was never tested and the assertion passed for the wrong reason.
    The same could happen to \" and \n; every escape here goes through BS. }
  BS = '\';
begin
  AssertEqStr(UnwrapJsString('"hello"'), 'hello', 'one layer of quoting removed');
  AssertEqStr(UnwrapJsString('"a' + BS + '"b"'), 'a"b', 'escaped quote decoded');
  AssertEqStr(UnwrapJsString('"line' + BS + 'nnext"'), 'line' + #10 + 'next', 'escaped newline decoded');
  AssertEqStr(UnwrapJsString('"tab' + BS + 'tx"'), 'tab' + #9 + 'x', 'escaped tab decoded');
  AssertEqStr(UnwrapJsString('"' + BS + BS + '"'), BS, 'escaped backslash decoded');
  AssertEqStr(UnwrapJsString('"' + BS + 'u0041' + BS + 'u00e9"'), 'A' + #$C3#$A9, 'unicode escapes decoded (BMP, incl. non-ASCII)');
  { U+1F600 as a surrogate pair: must become the 4-byte UTF-8 sequence, not two broken halves. }
  AssertEqStr(UnwrapJsString('"' + BS + 'ud83d' + BS + 'ude00"'), #$F0#$9F#$98#$80, 'a surrogate pair decodes to one code point');
  AssertEqStr(UnwrapJsString('{"a":1}'), '{"a":1}', 'a JSON object is left alone');
  AssertEqStr(UnwrapJsString('plain'), 'plain', 'unquoted text is left alone');
  AssertEqStr(UnwrapJsString('""'), '', 'an empty JSON string unwraps to empty');
  WriteLn('  ok: UnwrapJsString removes exactly one layer of JSON quoting');
end;

procedure TestHelpers;
begin
  AssertEqStr(JsStr('a"b\c'), '"a\"b\\c"', 'JsStr escapes quote and backslash');
  AssertEqStr(JsStr('x' + #10 + 'y'), '"x\ny"', 'JsStr escapes newline');
  AssertTrue(IsValidHandle('h1'),  'h1 valid');
  AssertTrue(IsValidHandle('h123'), 'h123 valid');
  AssertTrue(not IsValidHandle('1'), 'digits alone invalid');
  AssertTrue(not IsValidHandle('h'), 'bare h invalid');
  AssertTrue(not IsValidHandle('h1"]'), 'a selector-breaking handle is refused');
  AssertTrue(not IsValidHandle(''), 'empty invalid');
  AssertTrue(IsMutatingBrowserTool('browser_eval'), 'eval is mutating');
  AssertTrue(not IsMutatingBrowserTool('browser_page'), 'page is not');
  AssertEqStr(HostOf('https://Ex.com:8080/a/b?q=1#f'), 'ex.com', 'host extracted, lower, no port');
  AssertEqStr(HostOf('http://user@host.io/'), 'host.io', 'userinfo stripped');
  AssertEqStr(HostOf('not a url'), '', 'no scheme -> empty');
  WriteLn('  ok: JsStr, IsValidHandle, IsMutatingBrowserTool, HostOf');
end;

procedure TestPageTool;
var
  B: TFakeBridge;
  T: TBrowserPageTool;
  R, Err, Big: string;
  i: Integer;
begin
  B := TFakeBridge.Create;
  T := TBrowserPageTool.Create(B);
  try
    AssertTrue(T.Category = tcReadOnly, 'browser_page is read-only');

    R := T.Run('{}', Err);
    AssertEqStr(Err, '', 'default mode runs clean');
    AssertContains(R, 'url: https://example.com/docs/page?x=1', 'url reported');
    AssertContains(R, 'title: Example Page', 'title reported');
    AssertContains(R, 'Hello world.', 'text reported');
    AssertTrue(Pos('selection:', R) = 0, 'no selection line when nothing is selected');

    B.Selection := 'is the';
    R := T.Run('{"mode":"text"}', Err);
    AssertContains(R, 'selection: is the', 'selection reported when present');

    R := T.Run('{"mode":"outline"}', Err);
    AssertEqStr(Err, '', 'outline runs clean');
    AssertContains(R, '"handle":"h2"', 'outline carries handles');
    { The outline mints handles through the DOM property (dataset.pcHandle),
      which the browser maps to the data-pc-handle attribute; only the
      click/fill scripts spell the attribute out, in their selectors. }
    AssertContains(B.LastJS, 'dataset.pcHandle', 'outline script mints handles');

    R := T.Run('{"mode":"bogus"}', Err);
    AssertTrue(Err <> '', 'unknown mode is an error');

    { The cap: a page well over the limit is cut, with a breadcrumb that
      names the offset to continue from. }
    Big := '';
    for i := 1 to 3000 do Big := Big + 'word' + IntToStr(i) + ' ';
    B.PageText := Big;
    B.Selection := '';
    R := T.Run('{}', Err);
    AssertTrue(Length(R) < Length(Big), 'long text is truncated');
    AssertContains(R, '[truncated at ' + IntToStr(BrowserResultCap), 'breadcrumb names the cut');
    AssertContains(R, 'offset=' + IntToStr(BrowserResultCap), 'breadcrumb names the next offset');

    R := T.Run('{"offset":' + IntToStr(BrowserResultCap) + '}', Err);
    AssertContains(R, '(from offset ' + IntToStr(BrowserResultCap) + ')', 'offset honoured');
    AssertTrue(Pos('[truncated', R) = 0, 'the remainder fits without a second cut');

    R := T.Run('{"offset":999999}', Err);
    AssertContains(R, 'past the end', 'an offset past the end says so');

    B.FailEval := True;
    R := T.Run('{}', Err);
    AssertContains(Err, 'timed out', 'a bridge timeout surfaces as the tool error');
  finally
    T.Free;
  end;
  WriteLn('  ok: browser_page text / outline / cap / offset / timeout');
end;

procedure TestFindTool;
var
  B: TFakeBridge;
  T: TBrowserFindTool;
  R, Err: string;
begin
  B := TFakeBridge.Create;
  T := TBrowserFindTool.Create(B);
  try
    AssertTrue(T.Category = tcReadOnly, 'browser_find is read-only');
    R := T.Run('{}', Err);
    AssertTrue(Err <> '', 'needs a selector or text');

    R := T.Run('{"selector":"input[name=q]"}', Err);
    AssertEqStr(Err, '', 'selector search runs');
    AssertContains(R, '"handle":"h3"', 'returns handles');
    AssertContains(B.LastJS, '"input[name=q]"', 'selector reaches the page as a quoted literal');

    R := T.Run('{"selector":"[[broken"}', Err);
    AssertContains(Err, 'bad selector', 'a bad selector is a tool error, not a result');

    R := T.Run('{"text":"Sign in"}', Err);
    AssertContains(B.LastJS, '"Sign in"', 'text search passes the text');
  finally
    T.Free;
  end;
  WriteLn('  ok: browser_find selector / text / bad selector');
end;

procedure TestNavigateTool;
var
  B: TFakeBridge;
  T: TBrowserNavigateTool;
  R, Err: string;
begin
  B := TFakeBridge.Create;
  T := TBrowserNavigateTool.Create(B);
  try
    AssertTrue(T.Category = tcMutating, 'browser_navigate is mutating');
    R := T.Run('{}', Err);
    AssertTrue(Err <> '', 'url required');

    R := T.Run('{"url":"example.org/x"}', Err);
    AssertEqStr(B.LastNavURL, 'https://example.org/x', 'a bare host gets https://');
    AssertContains(R, 'now at: https://example.org/x', 'reports where it landed');

    R := T.Run('{"url":"back"}', Err);
    AssertEqStr(B.LastNavURL, 'back:', 'back is spelled for the bridge');

    R := T.Run('{"url":"https://unreachable.invalid"}', Err);
    AssertContains(Err, 'ERR_NAME_NOT_RESOLVED', 'bridge failure surfaces');
  finally
    T.Free;
  end;
  WriteLn('  ok: browser_navigate url / back / failure');
end;

procedure TestClickAndFill;
var
  B: TFakeBridge;
  C: TBrowserClickTool;
  F: TBrowserFillTool;
  R, Err: string;
begin
  B := TFakeBridge.Create;
  C := TBrowserClickTool.Create(B);
  F := TBrowserFillTool.Create(B);
  try
    AssertTrue(C.Category = tcMutating, 'click is mutating');
    AssertTrue(F.Category = tcMutating, 'fill is mutating');

    R := C.Run('{"handle":"nope"}', Err);
    AssertTrue(Err <> '', 'click refuses a malformed handle');
    R := C.Run('{"handle":"h1\"]"}', Err);
    AssertTrue(Err <> '', 'click refuses a selector-breaking handle before it reaches JS');

    R := C.Run('{"handle":"h3"}', Err);
    AssertEqStr(Err, '', 'click runs');
    AssertContains(B.LastJS, '[data-pc-handle="''+hd+''"]', 'click targets by handle attribute');
    AssertContains(B.LastJS, 'scrollIntoView', 'click scrolls into view first');

    R := C.Run('{"handle":"h99"}', Err);
    AssertContains(Err, 'no element with handle h99', 'a stale handle is a tool error');

    R := F.Run('{"handle":"h3","value":"typed"}', Err);
    AssertEqStr(Err, '', 'fill runs');
    AssertContains(B.LastJS, 'dispatchEvent(new Event("input"', 'fill fires input');
    AssertContains(B.LastJS, 'dispatchEvent(new Event("change"', 'fill fires change');
    AssertContains(B.LastJS, 'getOwnPropertyDescriptor(p,"value")', 'fill uses the prototype setter so React notices');
    AssertContains(B.LastJS, '"typed"', 'value reaches the page quoted');
  finally
    C.Free;
    F.Free;
  end;
  WriteLn('  ok: browser_click / browser_fill handles, events, stale handle');
end;

procedure TestEvalTool;
var
  B: TFakeBridge;
  T: TBrowserEvalTool;
  R, Err: string;
begin
  B := TFakeBridge.Create;
  T := TBrowserEvalTool.Create(B);
  try
    AssertTrue(T.Category = tcMutating, 'eval is mutating');
    R := T.Run('{}', Err);
    AssertTrue(Err <> '', 'js required');

    R := T.Run('{"js":"6*7"}', Err);
    AssertEqStr(Err, '', 'eval runs');
    AssertEqStr(R, 'forty-two', 'the {value} envelope is unwrapped');
    AssertContains(B.LastJS, 'eval("6*7")', 'source reaches eval as a quoted literal');

    R := T.Run('{"js":"throw new Error(1)"}', Err);
    AssertContains(Err, 'script threw', 'an exception is a tool error');
  finally
    T.Free;
  end;
  WriteLn('  ok: browser_eval passes source, unwraps value, surfaces throws');
end;

{ ------------------------------------------------------------------ }

procedure TestContextHook;
var
  B: TFakeBridge;
  H: TPageContextHook;
  Msgs: TMessageArray;
  Cont: Boolean;
  Before: Integer;
begin
  B := TFakeBridge.Create;
  H := TPageContextHook.Create(B, True);
  try
    SetLength(Msgs, 2);
    Msgs[0] := MakeMessage(mrUser, 'earlier question');
    Msgs[1] := MakeMessage(mrUser, 'what is this page?');
    Cont := True;
    H.BeforeTurn(Cont, Msgs);
    AssertTrue(Cont, 'hook never aborts the turn');
    AssertContains(Msgs[1].Content, '[page: Example Page -- https://example.com/docs/page?x=1]',
                   'the LAST user message gets the page line');
    AssertTrue(Pos('[page:', Msgs[0].Content) = 0, 'earlier messages are untouched');
    AssertTrue(Pos('[selection:', Msgs[1].Content) = 0, 'no selection line when nothing selected');

    { Idempotent: a turn with tool calls runs BeforeTurn several times. }
    Before := Length(Msgs[1].Content);
    H.BeforeTurn(Cont, Msgs);
    AssertEqInt(Length(Msgs[1].Content), Before, 'a second pass does not stamp again');

    B.Selection := 'the quick brown fox';
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'explain the selection');
    H.BeforeTurn(Cont, Msgs);
    AssertContains(Msgs[0].Content, '[selection: the quick brown fox]', 'selection is included');

    { A selection read that fails is silently "no selection", not an error. }
    B.FailEval := True;
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'again');
    H.BeforeTurn(Cont, Msgs);
    AssertContains(Msgs[0].Content, '[page:', 'page line still added when the selection read times out');
    AssertTrue(Pos('[selection:', Msgs[0].Content) = 0, 'and no selection line');
  finally
    H.Free;
  end;
  WriteLn('  ok: page context stamped once, on the last user message, selection optional');
end;

type
  TAsker = class
    Answer: TConfirmAnswer;
    Calls:  Integer;
    LastTool, LastHost: string;
    function Ask(const ToolName, ArgsJSON, Host: string): TConfirmAnswer;
  end;

function TAsker.Ask(const ToolName, ArgsJSON, Host: string): TConfirmAnswer;
begin
  Inc(Calls);
  LastTool := ToolName;
  LastHost := Host;
  Result := Answer;
end;

function MkCall(const Name, Args: string): TToolCall;
begin
  Result.Id := 'c1';
  Result.Kind := 'function';
  Result.Func.Name := Name;
  Result.Func.Arguments := Args;
end;

procedure TestConfirmHook;
var
  B: TFakeBridge;
  A: TAsker;
  H: TConfirmMutationHook;
  Cancel: Boolean;
  Synth: string;
begin
  B := TFakeBridge.Create;
  A := TAsker.Create;
  H := TConfirmMutationHook.Create(B, A.Ask);
  try
    { Read-only tools never ask. }
    Cancel := False; Synth := '';
    H.BeforeToolCall(MkCall('browser_page', '{}'), Cancel, Synth);
    AssertTrue(not Cancel, 'read-only tool passes');
    AssertEqInt(A.Calls, 0, 'and did not ask');

    { A denied mutation is cancelled with a synthetic result. }
    A.Answer := caDeny;
    H.BeforeToolCall(MkCall('browser_eval', '{"js":"1"}'), Cancel, Synth);
    AssertTrue(Cancel, 'denied mutation is cancelled');
    AssertContains(Synth, 'declined browser_eval', 'synthetic result names the tool');
    AssertEqStr(A.LastHost, 'example.com', 'asker sees the host');

    { Allow once: passes, asks again next time. }
    A.Answer := caAllowOnce; Cancel := False; Synth := '';
    H.BeforeToolCall(MkCall('browser_click', '{"handle":"h1"}'), Cancel, Synth);
    AssertTrue(not Cancel, 'allow-once passes');
    H.BeforeToolCall(MkCall('browser_click', '{"handle":"h1"}'), Cancel, Synth);
    AssertEqInt(A.Calls, 3, 'allow-once asks again');

    { Allow host: remembered for the session. }
    A.Answer := caAllowHost; Cancel := False;
    H.BeforeToolCall(MkCall('browser_fill', '{}'), Cancel, Synth);
    AssertTrue(H.IsHostAllowed('example.com'), 'host remembered');
    A.Answer := caDeny;   { would deny, but must not be asked }
    Cancel := False;
    H.BeforeToolCall(MkCall('browser_eval', '{}'), Cancel, Synth);
    AssertTrue(not Cancel, 'remembered host is not asked again');
    AssertEqInt(A.Calls, 4, 'no extra ask for a remembered host');

    { Another host is still gated. }
    B.URL := 'https://other.example.net/';
    H.BeforeToolCall(MkCall('browser_eval', '{}'), Cancel, Synth);
    AssertTrue(Cancel, 'a different host is asked, and here denied');

    H.ForgetHosts;
    AssertTrue(not H.IsHostAllowed('example.com'), 'forget clears');
  finally
    H.Free;
    A.Free;
  end;

  { No asker wired: the gate is closed, not open. }
  B := TFakeBridge.Create;
  H := TConfirmMutationHook.Create(B, nil);
  try
    Cancel := False; Synth := '';
    H.BeforeToolCall(MkCall('browser_navigate', '{"url":"x"}'), Cancel, Synth);
    AssertTrue(Cancel, 'with no confirmation handler, mutations are refused');
    AssertContains(Synth, 'no confirmation handler', 'and the reason is stated');
  finally
    H.Free;
  end;
  WriteLn('  ok: confirm gate denies / allows once / remembers host / closed without an asker');
end;

{ ------------------------------------------------------------------ }

procedure TestSession;
var
  S, S2: TBrowserSession;
  Path: string;
  Hist: TMessageArray;
begin
  S := TBrowserSession.Create('tab-test');
  try
    S.URL := 'https://example.com/';
    S.Title := 'Example';
    S.AppendUser('hello');
    S.AppendAssistant('hi there');
    S.AppendUser('caf' + #$C3#$A9 + ' ' + #$E6#$97#$A5);   { non-ASCII survives the round-trip }
    AssertEqInt(S.TurnCount, 3, 'three turns');

    Hist := S.HistoryCopy;
    AssertEqInt(Length(Hist), 3, 'copy has three');
    AssertTrue(Hist[1].Role = mrAssistant, 'roles preserved');
    SetLength(Hist, 0);
    AssertEqInt(S.TurnCount, 3, 'clearing the copy does not touch the session');

    Path := SessionFilePath(GTmpDir, S.Id);
    AssertContains(Path, 'workspace', 'session path is under workspace/browser');
    S.SaveToFile(Path);
    AssertTrue(FileExists(Path), 'file written');
  finally
    S.Free;
  end;

  S2 := TBrowserSession.Create('ignored');
  try
    AssertTrue(S2.LoadFromFile(Path), 'loads back');
    AssertEqStr(S2.Id, 'tab-test', 'id comes from the file');
    AssertEqStr(S2.URL, 'https://example.com/', 'url restored');
    AssertEqInt(S2.TurnCount, 3, 'turns restored');
    Hist := S2.HistoryCopy;
    AssertEqStr(Hist[0].Content, 'hello', 'first turn text');
    AssertTrue(Hist[1].Role = mrAssistant, 'assistant role restored');
    AssertEqStr(Hist[2].Content, 'caf' + #$C3#$A9 + ' ' + #$E6#$97#$A5, 'UTF-8 round-trips byte-exact');

    AssertTrue(not S2.LoadFromFile(JoinPath(GTmpDir, 'missing.json')), 'missing file is False, not an exception');
    AssertEqInt(S2.TurnCount, 0, 'a failed load leaves the session empty');
  finally
    S2.Free;
  end;

  AssertTrue(NewBrowserSessionId <> NewBrowserSessionId, 'ids are unique');
  WriteLn('  ok: session append / copy / JSON round-trip / UTF-8 / missing file');
end;

(* The one agent per process holds the tools for good; the switching
   bridge is how a turn gets pointed at the tab that owns it. This is
   the fix for "second tab raises EPasClawInstance", so it is tested
   where it can be: no current tab fails with a named error and no call
   reaches any real bridge; switching routes to the new tab and only
   that tab; Shutdown fails every call immediately, refuses to be
   re-pointed, and blanks the URL and title the hooks read. *)
procedure TestSwitchingBridge;
var
  Sw:    TSwitchingBridge;
  SwI:   IBrowserBridge;
  A, B:  TFakeBridge;
  AI, BI: IBrowserBridge;
  V, E:  string;
  Tool:  TBrowserPageTool;
  Hook:  TPageContextHook;
  Cont:  Boolean;
  Msgs:  TMessageArray;
begin
  A := TFakeBridge.Create; AI := A; A.URL := 'https://a.example/'; A.Title := 'Tab A';
  B := TFakeBridge.Create; BI := B; B.URL := 'https://b.example/'; B.Title := 'Tab B';
  Sw := TSwitchingBridge.Create;
  SwI := Sw;

  { No turn running: fail, name the reason, touch nobody. }
  AssertTrue(not SwI.Eval('1+1', 100, V, E), 'eval with no current tab fails');
  AssertEqStr(E, NoActiveTabError, 'no-tab error is the named one');
  AssertTrue(not SwI.Navigate('https://x.example/', 100, E), 'navigate with no current tab fails');
  AssertEqStr(SwI.CurrentURL, '', 'no-tab URL is blank');
  AssertEqInt(A.EvalCalls + B.EvalCalls, 0, 'no fake was reached without a current tab');

  { A tool built once against the switching bridge follows Current. }
  Tool := TBrowserPageTool.Create(SwI);
  try
    Sw.SetCurrent(AI);
    AssertTrue(SwI.Eval('x', 100, V, E), 'eval routes once a tab is current');
    AssertEqInt(A.EvalCalls, 1, 'tab A received the eval');
    AssertEqInt(B.EvalCalls, 0, 'tab B did not');
    AssertEqStr(SwI.CurrentTitle, 'Tab A', 'title comes from the current tab');

    Sw.SetCurrent(BI);
    V := Tool.Run('{}', E);
    AssertEqStr(E, '', 'page tool ran without error on tab B');
    AssertContains(V, 'https://b.example/', 'the page tool now reads tab B');
    AssertEqInt(A.EvalCalls, 1, 'tab A was not touched by tab B''s turn');
    AssertTrue(B.EvalCalls >= 1, 'tab B received the page read');
  finally
    Tool.Free;
  end;

  { The context hook, likewise built once, stamps the current tab's page. }
  Hook := TPageContextHook.Create(SwI, False);
  try
    Sw.SetCurrent(AI);
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'what is this?');
    Cont := True;
    Hook.BeforeTurn(Cont, Msgs);
    AssertContains(Msgs[0].Content, 'Tab A', 'hook stamped tab A while A is current');
    AssertTrue(Pos('Tab B', Msgs[0].Content) = 0, 'hook did not stamp tab B');
  finally
    Hook.Free;
  end;

  { Closing: every call fails at once, Current cannot be re-pointed, and
    the hooks' cheap reads go blank rather than reaching a dying control. }
  Sw.SetCurrent(AI);
  Sw.Shutdown;
  AssertTrue(Sw.IsClosing, 'IsClosing after Shutdown');
  AssertTrue(not SwI.Eval('x', 100, V, E), 'eval fails after shutdown');
  AssertEqStr(E, AppClosingError, 'shutdown error is the named one');
  AssertTrue(not SwI.Navigate('reload:', 100, E), 'navigate fails after shutdown');
  AssertEqStr(SwI.CurrentURL, '', 'URL blank after shutdown');
  AssertEqStr(SwI.CurrentTitle, '', 'title blank after shutdown');
  Sw.SetCurrent(BI);
  AssertTrue(not SwI.Eval('x', 100, V, E), 'calls still fail after a SetCurrent that follows Shutdown');
  AssertEqStr(E, AppClosingError, 'and still name closing, not "no tab"');
  AssertEqInt(A.EvalCalls, 1, 'no eval reached tab A after shutdown');
  AssertEqInt(B.EvalCalls, 1, 'no eval reached tab B after shutdown');

  SwI := nil;
  AI := nil; BI := nil;
  WriteLn('  ok: switching bridge: no-tab error / routes to current / shutdown fails fast');
end;

begin
  GTmpDir := JoinPath(GetTempDir, 'pasclaw-browser-test-' + IntToStr(Random(1 shl 30)));
  EnsureDir(GTmpDir);
  TestUnwrap;
  TestSwitchingBridge;
  TestHelpers;
  TestPageTool;
  TestFindTool;
  TestNavigateTool;
  TestClickAndFill;
  TestEvalTool;
  TestContextHook;
  TestConfirmHook;
  TestSession;
  WriteLn('PASS');
end.
