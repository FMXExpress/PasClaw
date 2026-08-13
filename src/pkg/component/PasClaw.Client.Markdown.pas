(*
  PasClaw.Client.Markdown - turn model-emitted markdown into HTML a GUI
  client can display.

  Why not PasClaw.Markdown.Render: that one emits ANSI escape codes for a
  terminal. A FireMonkey TMemo shows those as mojibake, and a TWebBrowser
  cannot use them at all. The subset and the intent are the same; only the
  output differs.

  Why here and not in the desktop unit: the desktop client has no compiler
  in CI, so anything with a rule in it belongs on this side of the line
  where FPC builds it and tests run against it. Studio can use it too.

  Deliberately small. Models emit a narrow band of markdown and the goal is
  a readable transcript, not a CommonMark implementation:

    # ## ###           headings
    **bold**           bold
    *italic* _italic_  italic
    `code`             inline code
    ```fenced```       code block, no inline transforms inside
    - * bullets        unordered list
    1. numbered        ordered list
    > quote            blockquote
    [text](url)        link
    ---                horizontal rule
    blank line         paragraph break

  Everything else passes through as text. Two rules are load-bearing:

  1. HTML in the SOURCE is escaped, always. Model output is untrusted text;
     a reply containing <script> must render as those characters, not run.
     This is the security boundary of the unit.
  2. Unrecognised markup degrades to its own literal characters rather than
     disappearing. An answer must never come out emptier than it went in.
*)
unit PasClaw.Client.Markdown;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

{ Markdown -> an HTML fragment (no <html>/<body> wrapper). }
function MarkdownToHTML(const S: string): string;

(* A whole transcript as a styled HTML document.

   Colors are passed in rather than baked: the desktop reskins at runtime
   across 27 styles, and a chat pane that stayed white inside a Windows 3.1
   desktop would be the one thing on screen that ignored the theme. *)
function ChatDocumentHTML(const BodyHTML, BgColor, FgColor, AccentColor,
  PanelColor: string): string;

{ Escape text for safe inclusion in HTML. Public because a caller
  assembling its own document (speaker labels, timestamps) needs the same
  rule, and two escapers would eventually disagree. }
function HtmlEscape(const S: string): string;

implementation

uses
  SysUtils, Classes, StrUtils;

function HtmlEscape(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

{ Replace paired delimiters with a tag. Unpaired ones are left alone, which
  is how `2 * 3 * 4` survives being read as italics. }
function WrapPairs(const S, Delim, Tag: string): string;
var
  P, Q, DL: Integer;
  Rest: string;
begin
  Result := '';
  Rest := S;
  DL := Length(Delim);
  repeat
    P := Pos(Delim, Rest);
    if P = 0 then Break;
    Q := PosEx(Delim, Rest, P + DL);
    if Q = 0 then Break;            { unpaired -- leave the rest verbatim }
    Result := Result + Copy(Rest, 1, P - 1) +
              '<' + Tag + '>' +
              Copy(Rest, P + DL, Q - P - DL) +
              '</' + Tag + '>';
    Rest := Copy(Rest, Q + DL, MaxInt);
  until False;
  Result := Result + Rest;
end;

{ [text](url) -> an anchor. Only http/https/mailto: a javascript: URL in a
  model reply is either a mistake or an attack, and neither should be
  clickable. }
function LinkUp(const S: string): string;
var
  P, Close_, Open_, End_: Integer;
  Text_, URL, Low_: string;
begin
  Result := S;
  P := 1;
  repeat
    P := PosEx('[', Result, P);
    if P = 0 then Break;
    Close_ := PosEx(']', Result, P);
    if Close_ = 0 then Break;
    Open_ := Close_ + 1;
    if (Open_ > Length(Result)) or (Result[Open_] <> '(') then
    begin
      P := Close_ + 1;
      Continue;
    end;
    End_ := PosEx(')', Result, Open_);
    if End_ = 0 then Break;
    Text_ := Copy(Result, P + 1, Close_ - P - 1);
    URL   := Trim(Copy(Result, Open_ + 1, End_ - Open_ - 1));
    Low_  := LowerCase(URL);
    if (Pos('http://', Low_) = 1) or (Pos('https://', Low_) = 1) or
       (Pos('mailto:', Low_) = 1) then
    begin
      Result := Copy(Result, 1, P - 1) +
                '<a href="' + URL + '">' + Text_ + '</a>' +
                Copy(Result, End_ + 1, MaxInt);
      P := P + Length(Text_) + Length(URL) + 15;
    end
    else
      P := Close_ + 1;      { not a URL we will make clickable }
  until False;
end;

{ Inline markup within one already-escaped line. Code first: text inside
  backticks must not then be read as bold or italic. }
function RenderInlineHTML(const S: string): string;
begin
  Result := WrapPairs(S, '`', 'code');
  Result := WrapPairs(Result, '**', 'strong');
  Result := WrapPairs(Result, '__', 'strong');
  Result := WrapPairs(Result, '*', 'em');
  Result := WrapPairs(Result, '_', 'em');
  Result := WrapPairs(Result, '~~', 'del');
  Result := LinkUp(Result);
end;

function IsBullet(const L: string; out Body: string): Boolean;
var
  T: string;
begin
  Result := False;
  T := TrimLeft(L);
  if (Pos('- ', T) = 1) or (Pos('* ', T) = 1) then
  begin
    Body := Copy(T, 3, MaxInt);
    Result := True;
  end;
end;

function IsNumbered(const L: string; out Body: string): Boolean;
var
  T: string;
  I: Integer;
begin
  Result := False;
  T := TrimLeft(L);
  I := 1;
  while (I <= Length(T)) and (T[I] >= '0') and (T[I] <= '9') do Inc(I);
  if (I = 1) or (I + 1 > Length(T)) then Exit;
  if (T[I] <> '.') or (T[I + 1] <> ' ') then Exit;
  Body := Copy(T, I + 2, MaxInt);
  Result := True;
end;

function HeadingLevel(const L: string; out Body: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  I := 1;
  while (I <= Length(L)) and (L[I] = '#') do Inc(I);
  if (I = 1) or (I > 4) then Exit;
  if (I > Length(L)) or (L[I] <> ' ') then Exit;
  Result := I - 1;
  Body := Copy(L, I + 1, MaxInt);
end;

function MarkdownToHTML(const S: string): string;
var
  Lines: TStringList;
  Out_: TStringList;
  I, HL: Integer;
  Line, Body, T: string;
  InCode, InUL, InOL: Boolean;

  procedure CloseLists;
  begin
    if InUL then begin Out_.Add('</ul>'); InUL := False; end;
    if InOL then begin Out_.Add('</ol>'); InOL := False; end;
  end;

begin
  Result := '';
  if Trim(S) = '' then Exit;
  Lines := TStringList.Create;
  Out_  := TStringList.Create;
  try
    Lines.Text := S;
    InCode := False; InUL := False; InOL := False;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      T := Trim(Line);

      { Fenced code. Everything between fences is verbatim -- no inline
        transforms, which is the whole point of showing code. }
      if Pos('```', T) = 1 then
      begin
        if InCode then
        begin
          Out_.Add('</code></pre>');
          InCode := False;
        end
        else
        begin
          CloseLists;
          Out_.Add('<pre><code>');
          InCode := True;
        end;
        Continue;
      end;
      if InCode then
      begin
        Out_.Add(HtmlEscape(Line));
        Continue;
      end;

      if T = '' then
      begin
        CloseLists;
        Continue;
      end;

      if (T = '---') or (T = '***') or (T = '___') then
      begin
        CloseLists;
        Out_.Add('<hr>');
        Continue;
      end;

      HL := HeadingLevel(T, Body);
      if HL > 0 then
      begin
        CloseLists;
        Out_.Add(Format('<h%d>%s</h%d>',
          [HL, RenderInlineHTML(HtmlEscape(Body)), HL]));
        Continue;
      end;

      if Pos('> ', T) = 1 then
      begin
        CloseLists;
        Out_.Add('<blockquote>' +
          RenderInlineHTML(HtmlEscape(Copy(T, 3, MaxInt))) + '</blockquote>');
        Continue;
      end;

      if IsBullet(Line, Body) then
      begin
        if InOL then begin Out_.Add('</ol>'); InOL := False; end;
        if not InUL then begin Out_.Add('<ul>'); InUL := True; end;
        Out_.Add('<li>' + RenderInlineHTML(HtmlEscape(Body)) + '</li>');
        Continue;
      end;

      if IsNumbered(Line, Body) then
      begin
        if InUL then begin Out_.Add('</ul>'); InUL := False; end;
        if not InOL then begin Out_.Add('<ol>'); InOL := True; end;
        Out_.Add('<li>' + RenderInlineHTML(HtmlEscape(Body)) + '</li>');
        Continue;
      end;

      CloseLists;
      Out_.Add('<p>' + RenderInlineHTML(HtmlEscape(T)) + '</p>');
    end;
    { An unterminated fence still closes: the transcript must not end
      mid-element and swallow whatever the caller appends next. }
    if InCode then Out_.Add('</code></pre>');
    CloseLists;
    Result := Out_.Text;
  finally
    Out_.Free;
    Lines.Free;
  end;
end;

function ChatDocumentHTML(const BodyHTML, BgColor, FgColor, AccentColor,
  PanelColor: string): string;
begin
  Result :=
    '<!doctype html><html><head><meta charset="utf-8">' +
    '<style>' +
    'html,body{margin:0;padding:8px;background:' + BgColor +
      ';color:' + FgColor + ';' +
      'font-family:Tahoma,Geneva,sans-serif;font-size:13px;' +
      'line-height:1.45;word-wrap:break-word}' +
    'p{margin:.35em 0}' +
    'h1,h2,h3,h4{margin:.6em 0 .3em 0;font-size:1.15em;color:' +
      AccentColor + '}' +
    'code{background:' + PanelColor + ';padding:0 3px;' +
      'font-family:Consolas,monospace;font-size:12px}' +
    'pre{background:' + PanelColor + ';padding:6px;overflow-x:auto;' +
      'margin:.4em 0}' +
    'pre code{background:none;padding:0}' +
    'ul,ol{margin:.3em 0 .3em 1.4em;padding:0}' +
    'li{margin:.15em 0}' +
    'blockquote{margin:.4em 0;padding-left:.7em;' +
      'border-left:3px solid ' + AccentColor + ';opacity:.85}' +
    'hr{border:0;border-top:1px solid ' + AccentColor + ';opacity:.4}' +
    'a{color:' + AccentColor + '}' +
    '.turn{margin:0 0 10px 0}' +
    '.who{font-weight:bold;color:' + AccentColor + '}' +
    '.tool{font-family:Consolas,monospace;font-size:11px;opacity:.75;' +
      'margin:1px 0 1px 12px}' +
    '.err{color:#c00}' +
    '</style></head><body>' + BodyHTML +
    '<div id="end"></div>' +
    '<script>window.scrollTo(0,document.body.scrollHeight);</script>' +
    '</body></html>';
end;

end.
