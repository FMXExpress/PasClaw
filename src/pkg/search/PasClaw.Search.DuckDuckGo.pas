(*
  PasClaw.Search.DuckDuckGo - HTML-scrape adapter against
  https://html.duckduckgo.com/html/.

  DuckDuckGo doesn't ship a public API so picoclaw scrapes the no-JS
  "html" endpoint and pulls results out of the rendered HTML. Same
  approach here, with the substring/Pos parsing kept deliberately
  conservative -- we look for the well-known result block markers
  ("result__a" anchor class, "result__snippet" snippet div) and
  extract title / URL / snippet. Failed parsing returns whatever
  block did extract cleanly instead of erroring; partial results
  beat no results when the model is asking.

  Zero-config: this is what the web_search tool falls back to when
  no provider is configured, so DuckDuckGo's reliability is the
  floor of the whole feature.

  Some notes on the URL extraction: DuckDuckGo wraps each result URL
  in their own redirector
    href="//duckduckgo.com/l/?uddg=<percent-encoded-real-url>&..."
  We unwrap the uddg param and percent-decode it so the model gets
  the real URL it'd recognize. If the wrapper shape changes the
  unwrap is a best-effort -- we return whatever's in href as a
  fallback.
*)
unit PasClaw.Search.DuckDuckGo;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Search.Types;

function NewDuckDuckGoProvider: ISearchProvider;

implementation

uses
  StrUtils,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

type
  TDuckDuckGoProvider = class(TInterfacedObject, ISearchProvider)
  public
    function Name: string;
    function Search(const Query: string; Count: Integer;
                    out Hits: TSearchResultArray; out ErrMsg: string): Boolean;
  end;

function PercentDecode(const S: string): string;
var
  i: Integer;
  Hex: string;
  B: Byte;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    if (S[i] = '%') and (i + 2 <= Length(S)) then
    begin
      Hex := Copy(S, i + 1, 2);
      try
        B := StrToInt('$' + Hex);
        Result := Result + Chr(B);
        Inc(i, 3);
        Continue;
      except
        { fall through to verbatim copy }
      end;
    end;
    if S[i] = '+' then Result := Result + ' '
    else Result := Result + S[i];
    Inc(i);
  end;
end;

function UnwrapDuckDuckGoURL(const Href: string): string;
var
  Marker: string;
  Start, Stop: Integer;
begin
  Marker := 'uddg=';
  Start := Pos(Marker, Href);
  if Start = 0 then
  begin
    { Already a real URL, or a shape we don't recognise. Return as-is. }
    if Pos('//', Href) = 1 then Result := 'https:' + Href
    else                         Result := Href;
    Exit;
  end;
  Inc(Start, Length(Marker));
  Stop := Start;
  while (Stop <= Length(Href)) and (Href[Stop] <> '&') do Inc(Stop);
  Result := PercentDecode(Copy(Href, Start, Stop - Start));
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
  { Compress runs of whitespace. }
  Result := Trim(StringReplace(StringReplace(StringReplace(
              Result, #10, ' ', [rfReplaceAll]),
              #13, ' ',         [rfReplaceAll]),
              #9,  ' ',          [rfReplaceAll]));
  while Pos('  ', Result) > 0 do
    Result := StringReplace(Result, '  ', ' ', [rfReplaceAll]);
end;

function DecodeEntities(const S: string): string;
begin
  Result := S;
  Result := StringReplace(Result, '&amp;',  '&', [rfReplaceAll]);
  Result := StringReplace(Result, '&lt;',   '<', [rfReplaceAll]);
  Result := StringReplace(Result, '&gt;',   '>', [rfReplaceAll]);
  Result := StringReplace(Result, '&quot;', '"', [rfReplaceAll]);
  Result := StringReplace(Result, '&#39;',  '''', [rfReplaceAll]);
  Result := StringReplace(Result, '&nbsp;', ' ', [rfReplaceAll]);
end;

function ExtractBetween(const Hay, StartMark, EndMark: string;
                        var Cursor: Integer): string;
var
  S, E: Integer;
begin
  Result := '';
  S := PosEx(StartMark, Hay, Cursor);
  if S = 0 then begin Cursor := MaxInt; Exit; end;
  Inc(S, Length(StartMark));
  E := PosEx(EndMark, Hay, S);
  if E = 0 then begin Cursor := MaxInt; Exit; end;
  Result := Copy(Hay, S, E - S);
  Cursor := E + Length(EndMark);
end;

function UrlEncode(const S: string): string;
var
  i: Integer;
  C: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    C := S[i];
    if ((C >= 'A') and (C <= 'Z')) or
       ((C >= 'a') and (C <= 'z')) or
       ((C >= '0') and (C <= '9')) or
       (C = '-') or (C = '_') or (C = '.') or (C = '~') then
      Result := Result + C
    else if C = ' ' then
      Result := Result + '+'
    else
      Result := Result + '%' + IntToHex(Byte(C), 2);
  end;
end;

function TDuckDuckGoProvider.Name: string;
begin
  Result := 'duckduckgo';
end;

function TDuckDuckGoProvider.Search(const Query: string; Count: Integer;
                                     out Hits: TSearchResultArray;
                                     out ErrMsg: string): Boolean;
const
  AnchorOpen  = '<a rel="nofollow" class="result__a"';
  HrefOpen    = 'href="';
  AnchorEnd   = '</a>';
  SnippetOpen = '<a class="result__snippet"';
  SnippetEnd  = '</a>';
var
  HTML, Body, Block, RawTitle, RawSnippet, Href: string;
  Resp: THTTPResult;
  Headers: array of THeaderPair;
  Cursor, HrefStart, HrefEnd, BlockStart, TitleClose: Integer;
  N: Integer;
begin
  SetLength(Hits, 0);
  ErrMsg := '';
  Result := False;
  SetLength(Headers, 0);

  Body := 'q=' + UrlEncode(Query) + '&kl=us-en';
  Resp := PostRaw('https://html.duckduckgo.com/html/',
                  'application/x-www-form-urlencoded', Body,
                  Headers, 15,
                  'Mozilla/5.0 (PasClaw web_search)',
                  'text/html');
  if Resp.ErrorMsg <> '' then
  begin
    ErrMsg := 'duckduckgo: HTTP error: ' + Resp.ErrorMsg;
    Exit;
  end;
  HTML := Resp.Body;

  if Trim(HTML) = '' then
  begin
    ErrMsg := 'duckduckgo: empty response';
    Exit;
  end;

  N := 0;
  Cursor := 1;
  while (N < Count) and (Cursor < Length(HTML)) do
  begin
    BlockStart := PosEx(AnchorOpen, HTML, Cursor);
    if BlockStart = 0 then Break;

    { Extract href first -- bound to the same anchor open tag. }
    HrefStart := PosEx(HrefOpen, HTML, BlockStart);
    if HrefStart = 0 then Break;
    Inc(HrefStart, Length(HrefOpen));
    HrefEnd := PosEx('"', HTML, HrefStart);
    if HrefEnd = 0 then Break;
    Href := Copy(HTML, HrefStart, HrefEnd - HrefStart);

    { Title: everything between the anchor's > and the matching </a>. }
    TitleClose := PosEx('>', HTML, HrefEnd);
    if TitleClose = 0 then Break;
    Cursor := TitleClose + 1;
    RawTitle := ExtractBetween(HTML, '', AnchorEnd, Cursor);
    if Cursor = MaxInt then Break;
    RawTitle := Copy(HTML, TitleClose + 1, Cursor - Length(AnchorEnd) - (TitleClose + 1));

    { Snippet: the next result__snippet block -- best-effort. If we
      can't find one, leave Snippet empty rather than skipping the
      whole result. }
    RawSnippet := ExtractBetween(HTML, SnippetOpen, SnippetEnd, Cursor);
    Block := RawSnippet;

    SetLength(Hits, N + 1);
    Hits[N].Title   := DecodeEntities(StripTags(RawTitle));
    Hits[N].URL     := UnwrapDuckDuckGoURL(Href);
    Hits[N].Snippet := DecodeEntities(StripTags(Block));
    Inc(N);
  end;

  if N = 0 then
    LogWarn('duckduckgo: parsed 0 hits from %d-byte response', [Length(HTML)]);
  Result := True;
end;

function NewDuckDuckGoProvider: ISearchProvider;
begin
  Result := TDuckDuckGoProvider.Create;
end;

end.
