(*
  PasClaw.Browser.Tools - the six tools the agent uses to read and change
  the page in the PasClaw Browser.

  All six are TPasClawTool subclasses over one IBrowserBridge, so they
  register with TPasClawAgent.RegisterTool like any other tool and run
  under FPC against a fake bridge for tests. Every script here returns
  JSON.stringify(...) so the bridge hands back a JSON document whatever
  the engine (see PasClaw.Browser.Bridge for the WebView2 quoting quirk).

    browser_page      read-only   URL, title, selection, and the page as
                                  text or as a structural outline
    browser_find      read-only   selector or text -> matching elements
    browser_navigate  mutating    go / back / forward / reload
    browser_click     mutating    click an element by handle
    browser_fill      mutating    set an input's value, firing events
    browser_eval      mutating    arbitrary JavaScript

  HANDLES. Anything that lists elements -- the outline, browser_find --
  stamps each one with data-pc-handle="hN" and reports the handle. Later
  tools target [data-pc-handle="hN"], so the model names an element in a
  few bytes instead of re-sending a selector or a chunk of DOM. Handles
  are per-document: a navigation discards them, which the tools say when
  a handle no longer resolves.

  THE CAP. browser_page truncates at BrowserResultCap and reports the
  offset for the rest. A long page must not ride in the transcript for the
  remainder of the session; the same reasoning as PasClaw's per-tool
  output cap, applied here where the text is produced.

  MUTATION. Four of the six change the page, and browser_eval can do
  anything the page's own scripts can, with the user's cookies. They are
  tcMutating so plan mode refuses them, and PasClaw.Browser.Hooks puts a
  confirmation in front of them by default.
*)
unit PasClaw.Browser.Tools;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  PasClaw.Tools.Obj,
  PasClaw.Tools.Types,
  PasClaw.Browser.Bridge;

const
  { Bytes of page text per browser_page call. Matches
    DefaultToolOutputCap in PasClaw.Config (24 KB ~ 6K tokens) without
    pulling the whole config unit into a tool. }
  BrowserResultCap = 24576;

  { A selection quoted into a page result. Enough to say what was
    selected; a user who selected a whole article wants browser_page. }
  SelectionCap = 2000;

type
  { Common base: holds the bridge, names the mutating/read-only split. }
  TBrowserTool = class(TPasClawTool)
  protected
    FBridge: IBrowserBridge;
  public
    constructor Create(ABridge: IBrowserBridge);
  end;

  TBrowserPageTool = class(TBrowserTool)
  public
    function Name: string; override;
    function Description: string; override;
    function Schema: string; override;
    function Category: TToolCategory; override;
    function Run(const ArgsJSON: string; out ErrMsg: string): string; override;
  end;

  TBrowserFindTool = class(TBrowserTool)
  public
    function Name: string; override;
    function Description: string; override;
    function Schema: string; override;
    function Category: TToolCategory; override;
    function Run(const ArgsJSON: string; out ErrMsg: string): string; override;
  end;

  TBrowserNavigateTool = class(TBrowserTool)
  public
    function Name: string; override;
    function Description: string; override;
    function Schema: string; override;
    function Category: TToolCategory; override;
    function Run(const ArgsJSON: string; out ErrMsg: string): string; override;
  end;

  TBrowserClickTool = class(TBrowserTool)
  public
    function Name: string; override;
    function Description: string; override;
    function Schema: string; override;
    function Category: TToolCategory; override;
    function Run(const ArgsJSON: string; out ErrMsg: string): string; override;
  end;

  TBrowserFillTool = class(TBrowserTool)
  public
    function Name: string; override;
    function Description: string; override;
    function Schema: string; override;
    function Category: TToolCategory; override;
    function Run(const ArgsJSON: string; out ErrMsg: string): string; override;
  end;

  TBrowserEvalTool = class(TBrowserTool)
  public
    function Name: string; override;
    function Description: string; override;
    function Schema: string; override;
    function Category: TToolCategory; override;
    function Run(const ArgsJSON: string; out ErrMsg: string): string; override;
  end;

{ Quote S as a JavaScript string literal (JSON escaping, which JS accepts).
  Pure; exposed for tests. }
function JsStr(const S: string): string;

{ True for the handle shape the page scripts mint: 'h' + digits. Anything
  else is refused before it can reach a selector string. Pure. }
function IsValidHandle(const H: string): Boolean;

{ Names of the tools that change the page, for hooks that gate mutation
  without depending on the class hierarchy. }
function IsMutatingBrowserTool(const ToolName: string): Boolean;

implementation

uses
  SysUtils,
  PasClaw.JSON;

{ ---------------------------------------------------------------- helpers }

function JsStr(const S: string): string;
var
  i: Integer;
  C: Char;
begin
  Result := '"';
  for i := 1 to Length(S) do
  begin
    C := S[i];
    case C of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      if Ord(C) < 32 then
        Result := Result + '\u' + IntToHex(Ord(C), 4)
      else
        Result := Result + C;
    end;
  end;
  Result := Result + '"';
end;

function IsValidHandle(const H: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if (Length(H) < 2) or (H[1] <> 'h') then Exit;
  for i := 2 to Length(H) do
    if (H[i] < '0') or (H[i] > '9') then Exit;
  Result := True;
end;

function IsMutatingBrowserTool(const ToolName: string): Boolean;
begin
  Result := (ToolName = 'browser_navigate') or (ToolName = 'browser_click')
         or (ToolName = 'browser_fill')     or (ToolName = 'browser_eval');
end;

{ Every page script minting handles shares this prologue. Handles persist
  on the element as a data attribute, so repeated calls return the same
  handle for the same element and the model's references stay valid until
  the document changes. }
const
  JsHandlePrologue =
    'window.__pcSeq=window.__pcSeq||0;' +
    'function h(e){if(!e.dataset.pcHandle){window.__pcSeq++;e.dataset.pcHandle="h"+window.__pcSeq;}return e.dataset.pcHandle;}' +
    'function t(s){s=(s||"").replace(/\s+/g," ").trim();return s.length>120?s.slice(0,117)+"...":s;}';

  JsPageText =
    '(function(){var b=document.body;var s="";try{s=String(window.getSelection());}catch(e){}' +
    'return JSON.stringify({url:location.href,title:document.title,selection:s,' +
    'text:b?b.innerText:""});})()';

  JsPageOutline =
    '(function(){' + JsHandlePrologue +
    'var out=[],els=document.querySelectorAll("h1,h2,h3,h4,h5,h6,a[href],button,input,textarea,select,[role=button]");' +
    'for(var i=0;i<els.length&&out.length<400;i++){var e=els[i];var r=e.getBoundingClientRect();' +
    'if(r.width===0&&r.height===0)continue;' +
    'var it={handle:h(e),tag:e.tagName.toLowerCase(),text:t(e.innerText||e.value||e.placeholder||e.getAttribute("aria-label")||"")};' +
    'if(e.href)it.href=e.href;if(e.type)it.type=e.type;if(e.name)it.name=e.name;out.push(it);}' +
    'return JSON.stringify({url:location.href,title:document.title,count:out.length,items:out});})()';

{ Pull a JSON error the script reported, so the tool can surface it as a
  tool error rather than as a "result" the model has to notice. }
function ScriptError(const ValueJSON: string; out Err: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  Err := '';
  Obj := TJsonObject.Parse(ValueJSON);
  if Obj = nil then Exit;
  try
    Err := Obj.GetStr('error', '');
    Result := Err <> '';
  finally
    Obj.Free;
  end;
end;

{ ---------------------------------------------------------------- base }

constructor TBrowserTool.Create(ABridge: IBrowserBridge);
begin
  inherited Create;
  FBridge := ABridge;
end;

{ ---------------------------------------------------------------- page }

function TBrowserPageTool.Name: string;
begin Result := 'browser_page'; end;

function TBrowserPageTool.Description: string;
begin
  Result :=
    'Read the page currently open in the browser. mode "text" (default) ' +
    'returns the URL, title, the user''s current selection, and the ' +
    'visible text; "outline" returns headings, links, buttons and form ' +
    'fields, each with a handle you can pass to browser_click or ' +
    'browser_fill. Long text is capped; pass offset to read the rest. ' +
    'Only the top-level document is visible -- content inside cross-' +
    'origin iframes is not.';
end;

function TBrowserPageTool.Schema: string;
begin
  Result :=
    '{"type":"object","properties":{' +
    '"mode":{"type":"string","enum":["text","outline"],"description":"text (default) or outline."},' +
    '"offset":{"type":"integer","minimum":0,"description":"Byte offset into the text, for pages longer than one result."}' +
    '}}';
end;

function TBrowserPageTool.Category: TToolCategory;
begin Result := tcReadOnly; end;

function TBrowserPageTool.Run(const ArgsJSON: string; out ErrMsg: string): string;
var
  Args, Obj: TJsonObject;
  Mode, Value, Err, Text, Sel: string;
  Offset, Total: Integer;
begin
  ErrMsg := '';
  Result := '';
  Args := TJsonObject.Parse(ArgsJSON);
  try
    Mode := 'text';
    Offset := 0;
    if Args <> nil then
    begin
      Mode := LowerCase(Trim(Args.GetStr('mode', 'text')));
      Offset := Integer(Args.GetInt('offset', 0));
    end;
  finally
    Args.Free;
  end;
  if Mode = '' then Mode := 'text';
  if (Mode <> 'text') and (Mode <> 'outline') then
  begin
    ErrMsg := 'mode must be "text" or "outline"';
    Exit;
  end;
  if Offset < 0 then Offset := 0;

  if Mode = 'outline' then
  begin
    if not FBridge.Eval(JsPageOutline, DefaultEvalTimeoutMs, Value, Err) then
    begin
      ErrMsg := 'could not read the page: ' + Err;
      Exit;
    end;
    { The outline is already compact JSON; the 400-item cap in the script
      keeps it well under the byte cap. Hand it back as-is. }
    Result := Value;
    Exit;
  end;

  if not FBridge.Eval(JsPageText, DefaultEvalTimeoutMs, Value, Err) then
  begin
    ErrMsg := 'could not read the page: ' + Err;
    Exit;
  end;
  Obj := TJsonObject.Parse(Value);
  if Obj = nil then
  begin
    ErrMsg := 'page script returned something that is not JSON';
    Exit;
  end;
  try
    Text := Obj.GetStr('text', '');
    Sel  := Obj.GetStr('selection', '');
    Total := Length(Text);
    if Length(Sel) > SelectionCap then
      Sel := Copy(Sel, 1, SelectionCap) + '...';

    Result := 'url: ' + Obj.GetStr('url', '') + sLineBreak +
              'title: ' + Obj.GetStr('title', '') + sLineBreak;
    if Sel <> '' then
      Result := Result + 'selection: ' + Sel + sLineBreak;
    Result := Result + Format('text: %d chars', [Total]);
    if Offset > 0 then
      Result := Result + Format(' (from offset %d)', [Offset]);
    Result := Result + sLineBreak + sLineBreak;

    if Offset >= Total then
    begin
      if Total = 0 then
        Result := Result + '(the page has no visible text)'
      else
        Result := Result + Format('(offset %d is past the end; the text is %d chars)', [Offset, Total]);
      Exit;
    end;

    Result := Result + Copy(Text, Offset + 1, BrowserResultCap);
    if Offset + BrowserResultCap < Total then
      Result := Result + sLineBreak + sLineBreak +
        Format('[truncated at %d of %d chars -- call browser_page with offset=%d for the rest]',
               [Offset + BrowserResultCap, Total, Offset + BrowserResultCap]);
  finally
    Obj.Free;
  end;
end;

{ ---------------------------------------------------------------- find }

function TBrowserFindTool.Name: string;
begin Result := 'browser_find'; end;

function TBrowserFindTool.Description: string;
begin
  Result :=
    'Find elements on the current page by CSS selector or by visible ' +
    'text, and get a handle for each. Use the handles with browser_click ' +
    'and browser_fill. Handles last until the page navigates.';
end;

function TBrowserFindTool.Schema: string;
begin
  Result :=
    '{"type":"object","properties":{' +
    '"selector":{"type":"string","description":"A CSS selector, e.g. \"form input[name=q]\"."},' +
    '"text":{"type":"string","description":"Visible text to search for (case-insensitive) when no selector is given."}' +
    '}}';
end;

function TBrowserFindTool.Category: TToolCategory;
begin Result := tcReadOnly; end;

function TBrowserFindTool.Run(const ArgsJSON: string; out ErrMsg: string): string;
var
  Args: TJsonObject;
  Sel, Txt, JS, Value, Err: string;
begin
  ErrMsg := '';
  Result := '';
  Sel := ''; Txt := '';
  Args := TJsonObject.Parse(ArgsJSON);
  try
    if Args <> nil then
    begin
      Sel := Trim(Args.GetStr('selector', ''));
      Txt := Trim(Args.GetStr('text', ''));
    end;
  finally
    Args.Free;
  end;
  if (Sel = '') and (Txt = '') then
  begin
    ErrMsg := 'give a selector or text to search for';
    Exit;
  end;

  JS :=
    '(function(sel,txt){' + JsHandlePrologue +
    'var els=[];' +
    'if(sel){try{els=Array.prototype.slice.call(document.querySelectorAll(sel));}' +
    'catch(e){return JSON.stringify({error:"bad selector: "+e.message});}}' +
    'else{var all=document.querySelectorAll("body *"),q=txt.toLowerCase();' +
    'for(var i=0;i<all.length;i++){var e=all[i];' +
    'if(e.children.length===0&&(e.innerText||e.value||"").toLowerCase().indexOf(q)>=0)els.push(e);}}' +
    'var out=[];for(var i=0;i<els.length&&i<100;i++){var e=els[i];' +
    'out.push({handle:h(e),tag:e.tagName.toLowerCase(),text:t(e.innerText||e.value||e.placeholder||"")});}' +
    'return JSON.stringify({count:els.length,items:out});' +
    '})(' + JsStr(Sel) + ',' + JsStr(Txt) + ')';

  if not FBridge.Eval(JS, DefaultEvalTimeoutMs, Value, Err) then
  begin
    ErrMsg := 'could not search the page: ' + Err;
    Exit;
  end;
  if ScriptError(Value, Err) then
  begin
    ErrMsg := Err;
    Exit;
  end;
  Result := Value;
end;

{ ---------------------------------------------------------------- navigate }

function TBrowserNavigateTool.Name: string;
begin Result := 'browser_navigate'; end;

function TBrowserNavigateTool.Description: string;
begin
  Result :=
    'Navigate the browser: open a URL, or go "back", "forward", or ' +
    '"reload". Waits for the page to finish loading. Handles from ' +
    'browser_find are discarded by a navigation.';
end;

function TBrowserNavigateTool.Schema: string;
begin
  Result :=
    '{"type":"object","properties":{' +
    '"url":{"type":"string","description":"A URL, or one of: back, forward, reload."}' +
    '},"required":["url"]}';
end;

function TBrowserNavigateTool.Category: TToolCategory;
begin Result := tcMutating; end;

function TBrowserNavigateTool.Run(const ArgsJSON: string; out ErrMsg: string): string;
var
  Args: TJsonObject;
  URL, Err, L: string;
begin
  ErrMsg := '';
  Result := '';
  URL := '';
  Args := TJsonObject.Parse(ArgsJSON);
  try
    if Args <> nil then URL := Trim(Args.GetStr('url', ''));
  finally
    Args.Free;
  end;
  if URL = '' then
  begin
    ErrMsg := 'missing required argument: url';
    Exit;
  end;
  L := LowerCase(URL);
  if (L = 'back') or (L = 'forward') or (L = 'reload') then
    URL := L + ':'
  else if (Pos('://', URL) = 0) then
    { A bare host is what people type; the bridge wants a scheme. }
    URL := 'https://' + URL;

  if not FBridge.Navigate(URL, DefaultNavigateTimeoutMs, Err) then
  begin
    ErrMsg := 'navigation failed: ' + Err;
    Exit;
  end;
  Result := 'now at: ' + FBridge.CurrentURL + sLineBreak +
            'title: ' + FBridge.CurrentTitle;
end;

{ ---------------------------------------------------------------- click }

function TBrowserClickTool.Name: string;
begin Result := 'browser_click'; end;

function TBrowserClickTool.Description: string;
begin
  Result :=
    'Click an element on the page, by the handle browser_find or ' +
    'browser_page(outline) gave it. Scrolls it into view first.';
end;

function TBrowserClickTool.Schema: string;
begin
  Result :=
    '{"type":"object","properties":{' +
    '"handle":{"type":"string","description":"An element handle such as h3."}' +
    '},"required":["handle"]}';
end;

function TBrowserClickTool.Category: TToolCategory;
begin Result := tcMutating; end;

function TBrowserClickTool.Run(const ArgsJSON: string; out ErrMsg: string): string;
var
  Args: TJsonObject;
  H, JS, Value, Err: string;
begin
  ErrMsg := '';
  Result := '';
  H := '';
  Args := TJsonObject.Parse(ArgsJSON);
  try
    if Args <> nil then H := Trim(Args.GetStr('handle', ''));
  finally
    Args.Free;
  end;
  if not IsValidHandle(H) then
  begin
    ErrMsg := 'handle must look like h12 -- get one from browser_find';
    Exit;
  end;

  JS :=
    '(function(hd){var e=document.querySelector(''[data-pc-handle="''+hd+''"]'');' +
    'if(!e)return JSON.stringify({error:"no element with handle "+hd+" -- the page may have navigated; call browser_find again"});' +
    'try{e.scrollIntoView({block:"center"});}catch(x){}e.click();' +
    'return JSON.stringify({ok:true,tag:e.tagName.toLowerCase(),text:(e.innerText||e.value||"").slice(0,80)});' +
    '})(' + JsStr(H) + ')';

  if not FBridge.Eval(JS, DefaultEvalTimeoutMs, Value, Err) then
  begin
    ErrMsg := 'click failed: ' + Err;
    Exit;
  end;
  if ScriptError(Value, Err) then
  begin
    ErrMsg := Err;
    Exit;
  end;
  Result := Value;
end;

{ ---------------------------------------------------------------- fill }

function TBrowserFillTool.Name: string;
begin Result := 'browser_fill'; end;

function TBrowserFillTool.Description: string;
begin
  Result :=
    'Set the value of an input, textarea or select on the page, by ' +
    'handle, and fire the input and change events so the page''s own ' +
    'scripts (React, Vue, plain listeners) notice. Does not submit; ' +
    'browser_click the submit button for that.';
end;

function TBrowserFillTool.Schema: string;
begin
  Result :=
    '{"type":"object","properties":{' +
    '"handle":{"type":"string","description":"An element handle from browser_find."},' +
    '"value":{"type":"string","description":"The value to set."}' +
    '},"required":["handle","value"]}';
end;

function TBrowserFillTool.Category: TToolCategory;
begin Result := tcMutating; end;

function TBrowserFillTool.Run(const ArgsJSON: string; out ErrMsg: string): string;
var
  Args: TJsonObject;
  H, V, JS, Value, Err: string;
begin
  ErrMsg := '';
  Result := '';
  H := ''; V := '';
  Args := TJsonObject.Parse(ArgsJSON);
  try
    if Args <> nil then
    begin
      H := Trim(Args.GetStr('handle', ''));
      V := Args.GetStr('value', '');
    end;
  finally
    Args.Free;
  end;
  if not IsValidHandle(H) then
  begin
    ErrMsg := 'handle must look like h12 -- get one from browser_find';
    Exit;
  end;

  { Setting .value directly is invisible to React, which tracks the value
    through the prototype's setter; call that setter, then dispatch the
    events every framework listens for. }
  JS :=
    '(function(hd,v){var e=document.querySelector(''[data-pc-handle="''+hd+''"]'');' +
    'if(!e)return JSON.stringify({error:"no element with handle "+hd+" -- the page may have navigated; call browser_find again"});' +
    'var p=Object.getPrototypeOf(e),d=p&&Object.getOwnPropertyDescriptor(p,"value");' +
    'if(d&&d.set){d.set.call(e,v);}else{e.value=v;}' +
    'e.dispatchEvent(new Event("input",{bubbles:true}));e.dispatchEvent(new Event("change",{bubbles:true}));' +
    'return JSON.stringify({ok:true,tag:e.tagName.toLowerCase(),value:String(e.value).slice(0,200)});' +
    '})(' + JsStr(H) + ',' + JsStr(V) + ')';

  if not FBridge.Eval(JS, DefaultEvalTimeoutMs, Value, Err) then
  begin
    ErrMsg := 'fill failed: ' + Err;
    Exit;
  end;
  if ScriptError(Value, Err) then
  begin
    ErrMsg := Err;
    Exit;
  end;
  Result := Value;
end;

{ ---------------------------------------------------------------- eval }

function TBrowserEvalTool.Name: string;
begin Result := 'browser_eval'; end;

function TBrowserEvalTool.Description: string;
begin
  Result :=
    'Run JavaScript in the current page and return the result. The ' +
    'escape hatch when browser_click / browser_fill are not enough: ' +
    'change text, inject CSS, read data the outline does not show. ' +
    'Return plain values (strings, numbers, arrays, objects) -- DOM ' +
    'nodes cannot be returned. Runs with the user''s cookies on whatever ' +
    'site is open, so prefer the specific tools when they will do.';
end;

function TBrowserEvalTool.Schema: string;
begin
  Result :=
    '{"type":"object","properties":{' +
    '"js":{"type":"string","description":"JavaScript source. The value of the last expression is returned."}' +
    '},"required":["js"]}';
end;

function TBrowserEvalTool.Category: TToolCategory;
begin Result := tcMutating; end;

function TBrowserEvalTool.Run(const ArgsJSON: string; out ErrMsg: string): string;
var
  Args, Obj: TJsonObject;
  Src, JS, Value, Err: string;
begin
  ErrMsg := '';
  Result := '';
  Src := '';
  Args := TJsonObject.Parse(ArgsJSON);
  try
    if Args <> nil then Src := Args.GetStr('js', '');
  finally
    Args.Free;
  end;
  if Trim(Src) = '' then
  begin
    ErrMsg := 'missing required argument: js';
    Exit;
  end;

  { eval() rather than a function body: it takes statements or an
    expression and yields the last value either way, so the model does not
    have to know which it wrote. Exceptions -- including JSON.stringify
    choking on a DOM node -- come back as a tool error, not a result. }
  JS :=
    '(function(){try{var r=eval(' + JsStr(Src) + ');' +
    'return JSON.stringify({value:(r===undefined?null:r)});}' +
    'catch(e){return JSON.stringify({error:String(e&&e.message?e.message:e)});}})()';

  if not FBridge.Eval(JS, DefaultEvalTimeoutMs, Value, Err) then
  begin
    ErrMsg := 'eval failed: ' + Err;
    Exit;
  end;
  if ScriptError(Value, Err) then
  begin
    ErrMsg := 'script threw: ' + Err;
    Exit;
  end;
  Obj := TJsonObject.Parse(Value);
  if Obj = nil then
  begin
    Result := Value;
    Exit;
  end;
  try
    (* Unwrap the {value: ...} envelope so the model sees the value.
       Star-comment rather than braces here: the brace inside the JSON
       shape above would close a brace comment early. *)
    Result := Obj.GetStr('value', '');
    if Result = '' then Result := Value;
    if Length(Result) > BrowserResultCap then
      Result := Copy(Result, 1, BrowserResultCap) +
        Format(sLineBreak + '[truncated at %d chars]', [BrowserResultCap]);
  finally
    Obj.Free;
  end;
end;

end.
