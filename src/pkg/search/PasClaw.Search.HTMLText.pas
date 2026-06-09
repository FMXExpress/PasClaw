(*
  PasClaw.Search.HTMLText - "good enough for the model" HTML to plain
  text conversion for web_fetch.

  Strip <script> and <style> bodies entirely, drop every other tag,
  decode the common entities, collapse whitespace runs to single
  spaces, normalise line breaks. The output isn't pretty-printed
  Markdown -- picoclaw bothers with that for human display, the
  model doesn't need it -- but it preserves the readable text from
  most modern HTML pages without dragging in a real HTML parser.

  Limited intentionally:
    - no <li> bullet preservation
    - no anchor href extraction (URLs go to the model via web_search)
    - no <table> alignment
  Fancier conversion is out of scope; the model can re-fetch with a
  tighter selector via shell + curl + html2text if that ever matters.
*)
unit PasClaw.Search.HTMLText;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, StrUtils;

function HTMLToText(const HTML: string; MaxChars: Integer): string;

implementation

function StripBlock(const S, OpenLower, CloseLower: string): string;
var
  i, Hit, EndPos: Integer;
  Lower: string;
begin
  Lower := LowerCase(S);
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    Hit := PosEx(OpenLower, Lower, i);
    if Hit = 0 then
    begin
      Result := Result + Copy(S, i, MaxInt);
      Break;
    end;
    Result := Result + Copy(S, i, Hit - i);
    EndPos := PosEx(CloseLower, Lower, Hit + Length(OpenLower));
    if EndPos = 0 then Break;
    i := EndPos + Length(CloseLower);
  end;
end;

function StripTags(const S: string): string;
var
  i: Integer;
  InTag: Boolean;
begin
  Result := '';
  InTag := False;
  for i := 1 to Length(S) do
  begin
    if S[i] = '<' then InTag := True
    else if S[i] = '>' then InTag := False
    else if not InTag then Result := Result + S[i];
  end;
end;

function DecodeEntities(const S: string): string;
begin
  Result := S;
  Result := StringReplace(Result, '&amp;',  '&', [rfReplaceAll]);
  Result := StringReplace(Result, '&lt;',   '<', [rfReplaceAll]);
  Result := StringReplace(Result, '&gt;',   '>', [rfReplaceAll]);
  Result := StringReplace(Result, '&quot;', '"', [rfReplaceAll]);
  Result := StringReplace(Result, '&#39;',  '''', [rfReplaceAll]);
  Result := StringReplace(Result, '&apos;', '''', [rfReplaceAll]);
  Result := StringReplace(Result, '&nbsp;', ' ', [rfReplaceAll]);
  Result := StringReplace(Result, '&mdash;', '-', [rfReplaceAll]);
  Result := StringReplace(Result, '&ndash;', '-', [rfReplaceAll]);
  Result := StringReplace(Result, '&hellip;', '...', [rfReplaceAll]);
end;

function CollapseWhitespace(const S: string): string;
var
  i: Integer;
  PrevSpace: Boolean;
  C: Char;
begin
  Result := '';
  PrevSpace := True;   { suppress leading whitespace }
  for i := 1 to Length(S) do
  begin
    C := S[i];
    if (C = #13) or (C = #10) then
    begin
      { Preserve paragraph breaks: keep a single \n, swallow runs. }
      if (Length(Result) > 0) and (Result[Length(Result)] <> #10) then
        Result := Result + #10;
      PrevSpace := True;
    end
    else if (C = ' ') or (C = #9) then
    begin
      if not PrevSpace then
      begin
        Result := Result + ' ';
        PrevSpace := True;
      end;
    end
    else
    begin
      Result := Result + C;
      PrevSpace := False;
    end;
  end;
  Result := Trim(Result);
end;

function HTMLToText(const HTML: string; MaxChars: Integer): string;
var
  S: string;
begin
  if Trim(HTML) = '' then Exit('');
  S := StripBlock(HTML, '<script', '</script>');
  S := StripBlock(S,    '<style',  '</style>');
  S := StripBlock(S,    '<!--',    '-->');
  S := StripTags(S);
  S := DecodeEntities(S);
  S := CollapseWhitespace(S);
  if (MaxChars > 0) and (Length(S) > MaxChars) then
    S := Copy(S, 1, MaxChars) + #10 + '…(truncated)';
  Result := S;
end;

end.
