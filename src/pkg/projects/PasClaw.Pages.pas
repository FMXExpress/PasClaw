(*
  PasClaw.Pages - answers as pages.

  A search or a question about your own data ends as an HTML document on the
  desktop, not as a wall of chat text: sections, tables, comparison grids, and
  citations as real links, laid out to fit the answer. Pages live in the
  active workspace so the browsing history IS part of the workspace:

    <workspace>/pages/
      P0001/
        page.json     { id, title, query, kind, created, sources[] }
        index.html    the rendered document

  Two rules this unit enforces rather than asks for:

  1. THE SOURCES STRIP IS NOT OPTIONAL. RenderDocument wraps whatever the
     model produced in a shell that ends with a provenance footer listing
     every source and the generation time. The model cannot omit it, because
     the model never writes the outer document -- it writes the body, and
     this unit writes the frame. A rendered page reads as more authoritative
     than chat text, so it has to carry its receipts.

  2. NO SCRIPTS. A page is a document. The body is sanitised of <script>,
     event-handler attributes and javascript: URLs before it is framed, and
     the gateway serves it under a script-free CSP (PasClaw.Apps). Belt and
     braces, because the body is model-authored text derived from web pages
     that may themselves be hostile.

  Grounding is the caller's job -- BuildPagePrompt tells the agent to search,
  read, and cite -- but "no sources" is representable and renders as an
  explicit "could not ground this" page rather than a confident-looking one.
*)
unit PasClaw.Pages;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, StrUtils;

type
  TPageKind = (pkSearch, pkData, pkReport, pkResearch);

  TPageSource = record
    Title: string;
    URL:   string;    { http(s) for web citations, or a workspace path }
  end;
  TPageSourceArray = array of TPageSource;

  TPageInfo = record
    Id:      string;   { 'P0001' }
    Title:   string;
    Query:   string;
    Kind:    TPageKind;
    Created: string;
    Sources: TPageSourceArray;
    Path:    string;   { absolute path to index.html }
  end;
  TPageInfoArray = array of TPageInfo;

function PageKindToStr(K: TPageKind): string;
function StrToPageKind(const S: string): TPageKind;

function PagesRoot: string;
function PageDir(const Id: string): string;      { '' when Id is malformed }

{ Instructions handed to the agent for producing a page body. Kept here, next
  to the renderer that consumes the output, so the contract between them is
  visible in one file. }
function BuildPagePrompt(const Query: string; Kind: TPageKind): string;

{ Wrap a model-authored body in the page shell: styling that inherits the
  desktop's palette, a title header, and the mandatory sources footer.
  BodyHTML is sanitised here -- callers pass raw model output. }
function RenderDocument(const Title, Query: string; Kind: TPageKind;
  const BodyHTML: string; const Sources: TPageSourceArray): string;

{ Strip scripts, event handlers and javascript: URLs from model-authored
  HTML. Exposed for tests -- this is a security boundary, not a nicety. }
function SanitizeBodyHTML(const S: string): string;

{ Persist a page and return its id. Sources may be empty, which renders the
  ungrounded notice rather than silently looking authoritative. }
function SavePage(const Title, Query: string; Kind: TPageKind;
  const BodyHTML: string; const Sources: TPageSourceArray;
  out Err: string): string;

function ListPages: TPageInfoArray;
function GetPage(const Id: string; out Info: TPageInfo): Boolean;
function DeletePage(const Id: string; out Err: string): Boolean;

(* Parse a sources array out of the agent's JSON reply:
     [{"title":"...","url":"..."}, ...]
   Paren-star delimiters: the literal brace in the JSON example would close a
   curly-brace comment early. *)
function ParseSources(const JSONArray: string): TPageSourceArray;

(* Promote a page into an app.

   "Make this interactive" is the plan's pitch in miniature: the thing the
   agent just showed you stops being a document you read and becomes
   software you own. Mechanically it is a copy -- the rendered page becomes
   a new project's app/index.html with kind `html` -- and the copying is
   deliberate. A page is the record of an answer at a time; editing it in
   place would falsify the history. The app is the part that changes.

   Two things travel with it on purpose:

     - The sources footer. Provenance does not stop mattering because the
       document became editable.
     - A pasclaw.js tag. The page has no scripts (it was sanitised), so the
       app starts inert -- but the SDK is wired for the first "now make it
       sort by date".

   Returns the new project slug, or '' with Err set. *)
function PromotePage(const PageId, PreferredName: string;
  out Err: string): string;

implementation

uses
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Workspaces,
  PasClaw.Projects.Store,
  PasClaw.Apps;

function PageKindToStr(K: TPageKind): string;
begin
  case K of
    pkData:     Result := 'data';
    pkReport:   Result := 'report';
    pkResearch: Result := 'research';
    else        Result := 'search';
  end;
end;

function StrToPageKind(const S: string): TPageKind;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  if      L = 'data'     then Result := pkData
  else if L = 'report'   then Result := pkReport
  else if L = 'research' then Result := pkResearch
  else Result := pkSearch;
end;

function PagesRoot: string;
begin
  Result := WorkspacePath('pages');
end;

function IsPageId(const Id: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(Id) < 2 then Exit;
  if (Id[1] <> 'P') and (Id[1] <> 'p') then Exit;
  for I := 2 to Length(Id) do
    if not (Id[I] in ['0'..'9']) then Exit;
  Result := True;
end;

function PageDir(const Id: string): string;
begin
  if not IsPageId(Id) then Exit('');
  Result := JoinPath(PagesRoot, UpperCase(Id));
end;

{ ----------------------------------------------------------------- prompt -- }

function BuildPagePrompt(const Query: string; Kind: TPageKind): string;
var
  S: string;
begin
  S := 'Produce an HTML DOCUMENT BODY that answers the request below. ' +
       'The user reads this as a page on their desktop, not as chat text.'#10#10 +
       'REQUEST: ' + Query + #10#10;

  case Kind of
    pkSearch:
      S := S +
        'Ground it: use web_search to find sources, web_fetch to read the ' +
        'promising ones, and answer from what you actually read. Cite ' +
        'inline with <a href="...">, using the real URLs you fetched.'#10;
    pkData:
      S := S +
        'Answer from the user''s own workspace: read the relevant files, ' +
        'memory notes, project manifests and session data with the tools ' +
        'you have. Link to what you used with <a href="...">.'#10;
    pkReport:
      S := S +
        'Compose a report from what you have already gathered this turn. ' +
        'Attribute each section to its source.'#10;
    (* Deep research. The difference from pkSearch is not "try harder" --
       it is a named three-phase shape the model is told to follow, because
       one search-and-summarise pass is what pkSearch already does and
       asking for more of it produces a longer version of the same answer.

       PLAN forces the question to be decomposed before anything is read,
       so the reading is directed rather than opportunistic. READ demands
       breadth AND disagreement, because a report assembled from sources
       that all agree is usually a report assembled from one source and its
       copies. SYNTHESISE separates what was found from what it means, so
       the reader can tell which is which. *)
    pkResearch:
      S := S +
        'This is a DEEP RESEARCH request. Work in three phases and do not ' +
        'skip ahead.'#10#10 +
        '1. PLAN. Before searching, break the request into the specific ' +
        'sub-questions that would have to be answered for the whole thing ' +
        'to be answered. State them.'#10 +
        '2. READ. Search for each sub-question separately, and web_fetch ' +
        'the promising results -- a snippet is not a source. Aim for ' +
        'several INDEPENDENT sources, not several pages repeating one. ' +
        'Where they disagree, read enough to say why.'#10 +
        '3. SYNTHESISE. Structure the page by sub-question, not by source. ' +
        'Keep what you found separate from what you conclude from it, and ' +
        'mark disagreement between sources where you found it.'#10#10 +
        'Cite inline with <a href="...">, using the real URLs you fetched. ' +
        'Where the evidence is thin, say so in the section it belongs to ' +
        'rather than at the end -- a caveat readers meet after the claim ' +
        'has done its work is a caveat that arrived too late.'#10;
  end;

  Result := S + #10 +
    'RULES'#10 +
    '- Output ONLY the body markup: headings, paragraphs, tables, lists. ' +
      'No <html>, <head>, <body> or <style> wrapper -- the desktop supplies ' +
      'those and will discard yours.'#10 +
    '- NO <script>, no inline event handlers, no javascript: URLs. They are ' +
      'stripped before the page is saved, so anything relying on them breaks.'#10 +
    '- Choose the layout that fits the answer. A comparison wants a <table>; ' +
      'a procedure wants an <ol>; a survey wants sections with <h2>. This ' +
      'freedom is the whole reason the answer is a page and not a paragraph.'#10 +
    '- Say what you do not know. An unanswerable part of the request gets a ' +
      'sentence saying so, never a plausible-sounding filler.'#10 +
    '- Do not invent sources, quotes, figures or URLs. Every factual claim ' +
      'must trace to something you actually read this turn.'#10#10 +
    'Then, on a final line by itself, emit the sources you used as JSON:'#10 +
    'SOURCES: [{"title":"...","url":"..."}]'#10 +
    'Emit SOURCES: [] if you genuinely could not ground the answer -- the ' +
    'page will be labelled as ungrounded, which is the honest outcome.';
end;

{ ------------------------------------------------------------- sanitising -- }

{ Case-insensitive search from a start index. }
function PosFrom(const Needle, Haystack: string; Start: Integer): Integer;
var
  Tail: string;
  P: Integer;
begin
  Result := 0;
  if Start > Length(Haystack) then Exit;
  Tail := Copy(Haystack, Start, MaxInt);
  P := Pos(LowerCase(Needle), LowerCase(Tail));
  if P > 0 then
    Result := P + Start - 1;
end;

{ Drop <tag>...</tag> and everything between, wherever it appears. }
function StripElement(const S, Tag: string): string;
var
  Res: string;
  I, Open_, Close_, AfterOpen: Integer;
begin
  Res := S;
  I := 1;
  repeat
    Open_ := PosFrom('<' + Tag, Res, I);
    if Open_ = 0 then Break;
    { Make sure this is the tag and not a prefix of a longer name. }
    AfterOpen := Open_ + Length(Tag) + 1;
    if (AfterOpen <= Length(Res)) and
       not (Res[AfterOpen] in [' ', '>', '/', #9, #10, #13]) then
    begin
      I := Open_ + 1;
      Continue;
    end;
    Close_ := PosFrom('</' + Tag, Res, Open_);
    if Close_ = 0 then
    begin
      { Unclosed: drop the remainder rather than leave a live tag. }
      Res := Copy(Res, 1, Open_ - 1);
      Break;
    end;
    Close_ := PosFrom('>', Res, Close_);
    if Close_ = 0 then
    begin
      Res := Copy(Res, 1, Open_ - 1);
      Break;
    end;
    Delete(Res, Open_, Close_ - Open_ + 1);
    I := Open_;
  until False;
  Result := Res;
end;

{ Remove on*="..." attributes. Scans for ' on' followed by letters and '='. }
function StripEventHandlers(const S: string): string;
var
  Res: string;
  I, J, Start_: Integer;
  Quote: Char;
begin
  Res := S;
  I := 1;
  while I < Length(Res) - 3 do
  begin
    if (Res[I] in [' ', #9, #10, #13]) and
       ((Res[I + 1] = 'o') or (Res[I + 1] = 'O')) and
       ((Res[I + 2] = 'n') or (Res[I + 2] = 'N')) then
    begin
      J := I + 3;
      while (J <= Length(Res)) and (Res[J] in ['a'..'z', 'A'..'Z']) do Inc(J);
      { Allow whitespace before '='. }
      Start_ := J;
      while (J <= Length(Res)) and (Res[J] in [' ', #9]) do Inc(J);
      if (J <= Length(Res)) and (Res[J] = '=') and (Start_ > I + 3) then
      begin
        Inc(J);
        while (J <= Length(Res)) and (Res[J] in [' ', #9]) do Inc(J);
        if (J <= Length(Res)) and (Res[J] in ['"', '''']) then
        begin
          Quote := Res[J];
          Inc(J);
          while (J <= Length(Res)) and (Res[J] <> Quote) do Inc(J);
          if J <= Length(Res) then Inc(J);
        end
        else
          while (J <= Length(Res)) and not (Res[J] in [' ', '>', #9, #10, #13]) do Inc(J);
        Delete(Res, I, J - I);
        Continue;   { re-test at the same index -- handlers can be adjacent }
      end;
    end;
    Inc(I);
  end;
  Result := Res;
end;

{ Neutralise javascript:/vbscript:/data:text/html URLs in href/src. }
function StripScriptURLs(const S: string): string;
var
  Res: string;
  P: Integer;
begin
  Res := S;
  repeat
    P := Pos('javascript:', LowerCase(Res));
    if P = 0 then Break;
    Delete(Res, P, Length('javascript:'));
    Insert('about:blank#', Res, P);
  until False;
  repeat
    P := Pos('vbscript:', LowerCase(Res));
    if P = 0 then Break;
    Delete(Res, P, Length('vbscript:'));
    Insert('about:blank#', Res, P);
  until False;
  repeat
    P := Pos('data:text/html', LowerCase(Res));
    if P = 0 then Break;
    Delete(Res, P, Length('data:text/html'));
    Insert('about:blank#', Res, P);
  until False;
  Result := Res;
end;

function SanitizeBodyHTML(const S: string): string;
begin
  Result := S;
  Result := StripElement(Result, 'script');
  Result := StripElement(Result, 'iframe');
  Result := StripElement(Result, 'object');
  Result := StripElement(Result, 'embed');
  Result := StripElement(Result, 'form');
  { <style> is dropped because the shell owns the look -- a model-authored
    stylesheet would fight the desktop palette and could hide the sources
    footer, which is the one thing that must always be visible. }
  Result := StripElement(Result, 'style');
  Result := StripElement(Result, 'link');
  Result := StripElement(Result, 'meta');
  Result := StripElement(Result, 'base');
  Result := StripEventHandlers(Result);
  Result := StripScriptURLs(Result);
end;

{ --------------------------------------------------------------- renderer -- }

function HtmlEscape(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      '''': Result := Result + '&#39;';
      else Result := Result + S[I];
    end;
end;

const
  { The page shell. Colours are CSS variables with retro-neutral defaults so
    the same document reads correctly whether it is opened inside the desktop
    (which overrides them per style) or on its own. }
  PageCSS =
    ':root{--pg-bg:#fff;--pg-fg:#111;--pg-muted:#555;--pg-rule:#c8c8c8;' +
    '--pg-accent:#000080;--pg-face:#f2f2f2;}' +
    'html{background:var(--pg-face);}' +
    'body{margin:0;padding:0;background:var(--pg-face);color:var(--pg-fg);' +
    'font:13px/1.55 "MS Sans Serif",Tahoma,Geneva,Verdana,sans-serif;}' +
    '.pg-doc{max-width:44rem;margin:0 auto;background:var(--pg-bg);' +
    'padding:1.25rem 1.5rem 0;min-height:100vh;box-sizing:border-box;}' +
    '.pg-head{border-bottom:2px solid var(--pg-rule);padding-bottom:.5rem;' +
    'margin-bottom:1rem;}' +
    '.pg-head h1{font-size:1.35rem;margin:0 0 .15rem;}' +
    '.pg-q{color:var(--pg-muted);font-size:.8rem;}' +
    '.pg-body h2{font-size:1.05rem;margin:1.4rem 0 .4rem;' +
    'border-bottom:1px solid var(--pg-rule);padding-bottom:.15rem;}' +
    '.pg-body h3{font-size:.95rem;margin:1rem 0 .3rem;}' +
    '.pg-body a{color:var(--pg-accent);}' +
    '.pg-body table{border-collapse:collapse;width:100%;margin:.7rem 0;' +
    'font-size:.85rem;display:block;overflow-x:auto;}' +
    '.pg-body th,.pg-body td{border:1px solid var(--pg-rule);padding:.3rem .5rem;' +
    'text-align:left;vertical-align:top;}' +
    '.pg-body th{background:var(--pg-face);}' +
    '.pg-body pre{background:var(--pg-face);border:1px solid var(--pg-rule);' +
    'padding:.5rem;overflow-x:auto;font-size:.8rem;}' +
    '.pg-body img{max-width:100%;height:auto;}' +
    '.pg-body blockquote{margin:.7rem 0;padding-left:.75rem;' +
    'border-left:3px solid var(--pg-rule);color:var(--pg-muted);}' +
    '.pg-src{margin-top:2rem;border-top:2px solid var(--pg-rule);' +
    'padding:.6rem 0 1.25rem;font-size:.78rem;color:var(--pg-muted);}' +
    '.pg-src b{color:var(--pg-fg);letter-spacing:.04em;}' +
    '.pg-src ol{margin:.4rem 0 0;padding-left:1.4rem;}' +
    '.pg-src li{margin:.15rem 0;}' +
    '.pg-src a{color:var(--pg-accent);word-break:break-all;}' +
    '.pg-ungrounded{border:1px solid #a00;background:#fff4f4;color:#7a0000;' +
    'padding:.5rem .7rem;margin:.6rem 0 0;}';

function RenderDocument(const Title, Query: string; Kind: TPageKind;
  const BodyHTML: string; const Sources: TPageSourceArray): string;
var
  S, Href, Label_: string;
  I: Integer;
begin
  S := '<!DOCTYPE html>'#10 +
       '<html lang="en"><head><meta charset="utf-8">' +
       '<meta name="viewport" content="width=device-width,initial-scale=1">' +
       '<title>' + HtmlEscape(Title) + '</title>' +
       '<style>' + PageCSS + '</style></head><body><div class="pg-doc">'#10;

  S := S + '<div class="pg-head"><h1>' + HtmlEscape(Title) + '</h1>';
  if Trim(Query) <> '' then
    S := S + '<div class="pg-q">' + HtmlEscape(Query) + '</div>';
  S := S + '</div>'#10;

  S := S + '<div class="pg-body">'#10 + SanitizeBodyHTML(BodyHTML) + #10'</div>'#10;

  { The footer is written here, always, from the stored source list -- it is
    not part of anything the model emitted and cannot be suppressed by it. }
  S := S + '<div class="pg-src"><b>SOURCES</b>';
  if Length(Sources) = 0 then
    S := S + '<div class="pg-ungrounded">This page could not be grounded in ' +
             'any source. Treat it as unverified.</div>'
  else
  begin
    S := S + ' &mdash; ' + IntToStr(Length(Sources));
    if Length(Sources) = 1 then S := S + ' source' else S := S + ' sources';
    S := S + '<ol>';
    for I := 0 to High(Sources) do
    begin
      Href   := Trim(Sources[I].URL);
      Label_ := Trim(Sources[I].Title);
      if Label_ = '' then Label_ := Href;
      { Only http(s) become links. A workspace path is shown as plain text --
        turning it into a file:// link from inside the desktop's origin is
        neither useful nor safe. }
      if HasPrefix(LowerCase(Href), 'http://') or
         HasPrefix(LowerCase(Href), 'https://') then
        S := S + '<li><a href="' + HtmlEscape(Href) +
             '" rel="noopener noreferrer nofollow" target="_blank">' +
             HtmlEscape(Label_) + '</a></li>'
      else if Href <> '' then
        S := S + '<li>' + HtmlEscape(Label_) + ' <span>(' + HtmlEscape(Href) +
             ')</span></li>'
      else
        S := S + '<li>' + HtmlEscape(Label_) + '</li>';
    end;
    S := S + '</ol>';
  end;
  S := S + '<div>' + HtmlEscape(PageKindToStr(Kind)) + ' page generated ' +
       HtmlEscape(NowIsoUtc) + ' by PasClaw</div>';
  S := S + '</div>'#10;

  Result := S + '</div></body></html>'#10;
end;

{ ------------------------------------------------------------------ store -- }

function NextPageId: string;
var
  Rec: TSearchRec;
  Max_, N: Integer;
begin
  Max_ := 0;
  if FindFirst(JoinPath(PagesRoot, 'P*'), faAnyFile, Rec) = 0 then
    try
      repeat
        if (Rec.Attr and faDirectory) = 0 then Continue;
        if not IsPageId(Rec.Name) then Continue;
        N := StrToIntDef(Copy(Rec.Name, 2, MaxInt), 0);
        if N > Max_ then Max_ := N;
      until FindNext(Rec) <> 0;
    finally
      FindClose(Rec);
    end;
  Result := 'P' + Format('%.4d', [Max_ + 1]);
end;

function ParseSources(const JSONArray: string): TPageSourceArray;
var
  Arr: TJsonArray;
  Obj: TJsonObject;
  I, N: Integer;
begin
  SetLength(Result, 0);
  if Trim(JSONArray) = '' then Exit;
  try
    Arr := TJsonArray.Parse(JSONArray);
  except
    Exit;   { an unparseable source list means ungrounded, not a crash }
  end;
  try
    SetLength(Result, Arr.Count);
    N := 0;
    for I := 0 to Arr.Count - 1 do
    begin
      Obj := Arr.ItemObject(I);
      if Obj = nil then Continue;
      Result[N].Title := Obj.GetStr('title', '');
      Result[N].URL   := Obj.GetStr('url', '');
      if (Result[N].Title = '') and (Result[N].URL = '') then Continue;
      Inc(N);
    end;
    SetLength(Result, N);
  finally
    Arr.Free;
  end;
end;

function SavePage(const Title, Query: string; Kind: TPageKind;
  const BodyHTML: string; const Sources: TPageSourceArray;
  out Err: string): string;
var
  Id, Dir, T: string;
  Obj, Item: TJsonObject;
  Arr: TJsonArray;
  I: Integer;
begin
  Err := '';
  Result := '';
  EnsureDir(PagesRoot);
  Id  := NextPageId;
  Dir := JoinPath(PagesRoot, Id);
  if not EnsureDir(Dir) then
  begin
    Err := 'could not create ' + Dir;
    Exit;
  end;

  T := Trim(Title);
  if T = '' then T := Trim(Query);
  if T = '' then T := 'Untitled page';

  WriteFileText(JoinPath(Dir, 'index.html'),
    RenderDocument(T, Query, Kind, BodyHTML, Sources));

  Obj := TJsonObject.Create;
  try
    Obj.PutStr('id', Id);
    Obj.PutStr('title', T);
    Obj.PutStr('query', Query);
    Obj.PutStr('kind', PageKindToStr(Kind));
    Obj.PutStr('created', NowIsoUtc);
    Arr := TJsonArray.Create;
    for I := 0 to High(Sources) do
    begin
      Item := TJsonObject.Create;
      Item.PutStr('title', Sources[I].Title);
      Item.PutStr('url', Sources[I].URL);
      Arr.AddObject(Item);
    end;
    Obj.PutArray('sources', Arr);
    WriteFileText(JoinPath(Dir, 'page.json'), Obj.ToJSON);
  finally
    Obj.Free;
  end;
  Result := Id;
end;

function LoadPage(const Id: string; out Info: TPageInfo): Boolean;
var
  Dir: string;
  Obj, Item: TJsonObject;
  Arr: TJsonArray;
  I: Integer;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Id := ''; Info.Title := ''; Info.Query := ''; Info.Created := '';
  Info.Path := '';
  SetLength(Info.Sources, 0);

  Dir := PageDir(Id);
  if (Dir = '') or not DirectoryExists(Dir) then Exit;
  Info.Id   := UpperCase(Id);
  Info.Path := JoinPath(Dir, 'index.html');
  Info.Title := Info.Id;
  Info.Kind := pkSearch;

  if FileExists(JoinPath(Dir, 'page.json')) then
    try
      Obj := TJsonObject.Parse(ReadFileText(JoinPath(Dir, 'page.json')));
      try
        Info.Title   := Obj.GetStr('title', Info.Id);
        Info.Query   := Obj.GetStr('query', '');
        Info.Kind    := StrToPageKind(Obj.GetStr('kind', 'search'));
        Info.Created := Obj.GetStr('created', '');
        Arr := Obj.ChildArray('sources');
        if Arr <> nil then
        begin
          SetLength(Info.Sources, Arr.Count);
          for I := 0 to Arr.Count - 1 do
          begin
            Item := Arr.ItemObject(I);
            if Item = nil then Continue;
            Info.Sources[I].Title := Item.GetStr('title', '');
            Info.Sources[I].URL   := Item.GetStr('url', '');
          end;
        end;
      finally
        Obj.Free;
      end;
    except
      { keep the defaults }
    end;
  Result := True;
end;

function GetPage(const Id: string; out Info: TPageInfo): Boolean;
begin
  Result := LoadPage(Id, Info);
end;

function ListPages: TPageInfoArray;
var
  Rec: TSearchRec;
  Names: TStringList;
  I, N: Integer;
  Info: TPageInfo;
begin
  SetLength(Result, 0);
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    if FindFirst(JoinPath(PagesRoot, 'P*'), faAnyFile, Rec) = 0 then
      try
        repeat
          if (Rec.Attr and faDirectory) = 0 then Continue;
          if IsPageId(Rec.Name) then Names.Add(Rec.Name);
        until FindNext(Rec) <> 0;
      finally
        FindClose(Rec);
      end;
    SetLength(Result, Names.Count);
    N := 0;
    { Newest first -- this is a history list. }
    for I := Names.Count - 1 downto 0 do
      if LoadPage(Names[I], Info) then
      begin
        Result[N] := Info;
        Inc(N);
      end;
    SetLength(Result, N);
  finally
    Names.Free;
  end;
end;

function DeletePage(const Id: string; out Err: string): Boolean;
var
  Dir: string;
begin
  Err := '';
  Dir := PageDir(Id);
  if (Dir = '') or not DirectoryExists(Dir) then
  begin
    Err := 'no such page: ' + Id;
    Exit(False);
  end;
  DeleteFile(JoinPath(Dir, 'index.html'));
  DeleteFile(JoinPath(Dir, 'page.json'));
  Result := RemoveDir(Dir);
  if not Result then
    Err := 'could not remove ' + Dir;
end;


(* Insert the SDK tag before </body>, once.

   Anchored to the LAST closing tag, case-insensitively: a document that
   quotes "</body>" in its own prose -- a page about HTML, which this
   feature will produce sooner or later -- must not get a script spliced
   into the middle of it. *)
function WithSDKTag(const Doc: string): string;
const
  Tag = '<script src="pasclaw.js"></scr' + 'ipt>';
var
  P, At: Integer;
  Low_: string;
begin
  Result := Doc;
  if Pos('pasclaw.js', LowerCase(Doc)) > 0 then Exit;
  Low_ := LowerCase(Doc);
  P := 0;
  At := 1;
  repeat
    At := PosEx('</body>', Low_, At);
    if At = 0 then Break;
    P := At;
    Inc(At, 7);
  until False;
  if P <= 0 then
  begin
    { No closing tag to anchor to -- append rather than drop the tag. }
    Result := Doc + sLineBreak + Tag;
    Exit;
  end;
  Result := Copy(Doc, 1, P - 1) + Tag + sLineBreak + Copy(Doc, P, MaxInt);
end;

function PromotePage(const PageId, PreferredName: string;
  out Err: string): string;
var
  Info: TPageInfo;
  Doc, Slug, Title: string;
  App: TAppInfo;
begin
  Result := '';
  Err := '';
  if not GetPage(PageId, Info) then
  begin
    Err := 'no such page: ' + PageId;
    Exit;
  end;
  if not FileExists(Info.Path) then
  begin
    Err := 'that page has no rendered document';
    Exit;
  end;
  Doc := ReadFileText(Info.Path);
  if Trim(Doc) = '' then
  begin
    Err := 'that page is empty';
    Exit;
  end;

  Title := Trim(Info.Title);
  if Title = '' then Title := Trim(Info.Query);
  if Title = '' then Title := 'Page ' + PageId;

  Slug := CreateProject(Title, PreferredName, Info.Query, Err);
  if Slug = '' then Exit;

  try
    WriteFileText(JoinPath(ProjectAppDir(Slug), 'index.html'), WithSDKTag(Doc));
  except
    on E: Exception do
    begin
      Err := 'could not write the app: ' + E.Message;
      Exit;
    end;
  end;

  App.Project := Slug;
  App.Name    := Title;
  App.Kind    := akHtml;
  App.Entry   := 'index.html';
  App.Run     := '';
  App.Build   := '';
  App.Width   := 720;
  App.Height  := 560;
  App.Icon    := 'Document';
  App.Network := '';
  App.EnvKeys := '';
  if not WriteApp(Slug, App, Err) then Exit;

  Result := Slug;
end;

end.
