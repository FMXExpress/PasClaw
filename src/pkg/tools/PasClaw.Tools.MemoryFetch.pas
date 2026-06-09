(*
  PasClaw.Tools.MemoryFetch - registers the memory_fetch tool.

  The model can already do this manually:
    1. web_fetch(url)            -- body lands in the conversation
    2. fs_write(path, content)   -- save to workspace/memory/
    3. memory_search(query)      -- retrieve the relevant slice later

  Step 1 dumps the entire body into the context window for what is
  often a reference doc the model will only need to consult by
  search. memory_fetch collapses 1+2 into a single tool call AND
  leaves the body OUT of the context: only a one-line confirmation
  returns to the model. The next memory_search call indexes the
  newly-written file via the existing FTS5 SyncDir and lets the
  model retrieve the slice it actually needs.

  Schema:
    {
      "url":  "<string, required>",
      "name": "<string, optional>"    -- override filename
    }

  Filenames live at workspace/memory/fetched-<sanitized>.md. The
  'fetched-' prefix keeps these out of conflict with daily notes
  (workspace/memory/YYYY-MM-DD.md). The body is preceded by a
  small YAML-style header (source, fetched_at, content-type) so
  the operator (and the model later) can tell where a memory entry
  came from.

  Reuse:
    - PasClaw.Providers.HTTP.GetURL for the round-trip
    - PasClaw.Tools.WebFetch's redirect-guard pattern (same SSRF
      semantics as web_fetch -- a public URL that 30Xs into the
      private network gets refused)
    - PasClaw.Search.HTMLText.HTMLToText for HTML pages
    - The existing memory directory layout. SyncDir is flat, so
      'fetched-*.md' files are picked up by memory_search
      automatically on the next call.
*)
unit PasClaw.Tools.MemoryFetch;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

procedure RegisterMemoryFetchTool(R: TToolRegistry);

implementation

uses
  Classes, StrUtils, DateUtils,
  PasClaw.JSON,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.Providers.HTTP,
  PasClaw.Search.HTMLText,
  PasClaw.Net.SSRF,
  PasClaw.Tools.Sandbox;       { NetworkBlockingActive -- same SSRF
                                 gate web_fetch uses }

const
  { Cap on the body we'll persist. Same shape as web_fetch's
    DEFAULT_MAX_CHARS but a touch larger here -- the body never
    enters context so we can afford to keep more on disk for the
    operator's later memory_search runs. }
  MEMORY_FETCH_MAX_CHARS = 100000;

type
  TMemoryFetchRedirectGuard = class
    procedure OnRedirect(var Dest: string;
                          var Allow: Boolean;
                          var Reason: string);
  end;

function IsAbsoluteHttpURL(const S: string): Boolean;
begin
  Result := (Length(S) >= 7) and
            (SameText(Copy(S, 1, 7),  'http://')  or
             (Length(S) >= 8) and SameText(Copy(S, 1, 8), 'https://'));
end;

procedure TMemoryFetchRedirectGuard.OnRedirect(var Dest: string;
                                                 var Allow: Boolean;
                                                 var Reason: string);
{ Same SSRF posture as PasClaw.Tools.WebFetch: refuse a redirect
  that flips a public URL into a private-network host. Path- and
  protocol-relative redirects keep the previously-checked origin
  so they pass through. }
var
  Why: string;
begin
  Allow := True;
  if not NetworkBlockingActive then Exit;

  if not IsAbsoluteHttpURL(Dest) then
  begin
    if (Length(Dest) >= 2) and (Dest[1] = '/') and (Dest[2] = '/') then
    begin
      if URLIsLocal('http:' + Dest, Why) then
      begin
        Allow := False;
        Reason := 'SSRF: protocol-relative redirect to ' + Dest + ' refused (' + Why + ')';
      end;
      Exit;
    end;
    Exit;
  end;

  if URLIsLocal(Dest, Why) then
  begin
    Allow := False;
    Reason := 'SSRF: redirect to ' + Dest + ' refused (' + Why + ')';
  end;
end;

function SanitizeFilename(const Raw: string): string;
{ Take whatever the model handed us (URL last segment or an
  explicit `name`) and produce a kebab-case .md filename that's
  safe on every supported OS. Drops scheme/host punctuation,
  collapses runs of dashes, caps length so we don't trip POSIX
  PATH_MAX or NTFS 255-char limits. Empty result signals the
  caller to fall back to a hash. }
const
  MAX_LEN = 60;
var
  i: Integer;
  C: Char;
  Out_: string;
  LastDash: Boolean;
begin
  Out_ := '';
  LastDash := False;
  for i := 1 to Length(Raw) do
  begin
    C := Raw[i];
    if ((C >= 'a') and (C <= 'z')) or
       ((C >= 'A') and (C <= 'Z')) or
       ((C >= '0') and (C <= '9')) or
       (C = '_') then
    begin
      Out_ := Out_ + LowerCase(C);
      LastDash := False;
    end
    else if (C = '-') or (C = '.') then
    begin
      if (not LastDash) and (Out_ <> '') then
      begin
        Out_ := Out_ + '-';
        LastDash := True;
      end;
    end
    else
    begin
      if (not LastDash) and (Out_ <> '') then
      begin
        Out_ := Out_ + '-';
        LastDash := True;
      end;
    end;
    if Length(Out_) >= MAX_LEN then Break;
  end;
  while (Length(Out_) > 0) and (Out_[Length(Out_)] = '-') do
    SetLength(Out_, Length(Out_) - 1);
  Result := Out_;
end;

function FallbackHashName(const URL: string): string;
{ Last resort when sanitisation collapses to empty (e.g.
  'https://%E4%B8%AD/' is all non-ASCII). Cheap: lowercased URL
  hashed via Pascal's built-in numeric hash, rendered as hex. }
var
  H: Cardinal;
  i: Integer;
begin
  H := $811C9DC5;       { 32-bit FNV-1a offset; algorithm follows. }
  for i := 1 to Length(URL) do
  begin
    H := H xor Byte(URL[i]);
    H := H * $01000193;
  end;
  Result := 'url-' + LowerCase(IntToHex(H, 8));
end;

function ExtractUrlNameHint(const URL: string): string;
{ Heuristic name from the URL: last non-empty path segment with
  the query/fragment chopped off. Returns '' when the URL is just
  a bare host. }
var
  P, S, E: Integer;
  PathOnly, Last: string;
begin
  Result := '';
  P := Pos('://', URL);
  if P <= 0 then Exit;
  S := PosEx('/', URL, P + 3);
  if S <= 0 then Exit;
  PathOnly := Copy(URL, S + 1, MaxInt);

  E := Pos('?', PathOnly);
  if E > 0 then PathOnly := Copy(PathOnly, 1, E - 1);
  E := Pos('#', PathOnly);
  if E > 0 then PathOnly := Copy(PathOnly, 1, E - 1);

  while (Length(PathOnly) > 0) and (PathOnly[Length(PathOnly)] = '/') do
    SetLength(PathOnly, Length(PathOnly) - 1);

  E := LastDelimiter('/', PathOnly);
  if E > 0 then Last := Copy(PathOnly, E + 1, MaxInt)
  else          Last := PathOnly;

  Result := Last;
end;

function MemoryDir: string;
begin
  Result := JoinPath(GetHome, 'workspace/memory');
end;

function LooksTextual(const ContentType: string): Boolean;
begin
  Result := (Pos('text/', ContentType) = 1) or
            (Pos('application/json',       ContentType) > 0) or
            (Pos('application/xml',        ContentType) > 0) or
            (Pos('application/javascript', ContentType) > 0) or
            (Pos('application/xhtml',      ContentType) > 0) or
            (Pos('application/x-markdown', ContentType) > 0) or
            (Pos('application/markdown',   ContentType) > 0);
end;

const
  { Skip the HTTP and return the cached path when an existing
    fetched-<name>.md was written within this window. 24h covers
    the typical "fetch this RFC / API doc once per work session"
    case; operators wanting a refresh can rm the file or wait the
    window out. Borrowed from chopratejas/headroom's "cross-agent
    memory with auto-dedup" idea -- same URL fetched twice
    doesn't get re-stored. }
  MEMORY_FETCH_DEDUP_HOURS = 24;

function ReadCachedHeader(const Path: string;
                          out CachedURL: string;
                          out CachedAt: TDateTime): Boolean;
{ Parse the YAML-ish provenance header BuildBodyWithHeader writes:
    <!-- pasclaw memory_fetch -->
    source: <url>
    fetched_at: <iso-utc with Z suffix>
    content-type: ...
  Returns False on any parse failure -- caller treats that as
  "stale, refetch". The header lines are always near the top so
  we scan the first ~10 lines and bail; doesn't read the body. }
var
  Sl: TStringList;
  i: Integer;
  Line, Tail: string;
const
  HEADER_PROBE_LINES = 10;
begin
  Result    := False;
  CachedURL := '';
  CachedAt  := 0;
  Sl := TStringList.Create;
  try
    try
      Sl.LoadFromFile(Path);
    except
      Exit;
    end;
    for i := 0 to Sl.Count - 1 do
    begin
      if i >= HEADER_PROBE_LINES then Break;
      Line := Sl[i];
      if Pos('source:', Line) = 1 then
        CachedURL := Trim(Copy(Line, Length('source:') + 1, MaxInt))
      else if Pos('fetched_at:', Line) = 1 then
      begin
        Tail := Trim(Copy(Line, Length('fetched_at:') + 1, MaxInt));
        try
          CachedAt := ISO8601ToDate(Tail);
        except
          Exit;
        end;
      end;
      if (CachedURL <> '') and (CachedAt <> 0) then
      begin
        Result := True;
        Exit;
      end;
    end;
  finally
    Sl.Free;
  end;
end;

function FormatAgeHours(Hours: Double): string;
{ Short human-readable age for the cache-hit confirmation. Matches
  the shape of PasClaw.Providers.Models.HumanAge so operator
  output looks consistent across the codebase. }
begin
  if Hours < 1 then
    Result := IntToStr(Round(Hours * 60)) + 'm'
  else if Hours < 24 then
    Result := IntToStr(Round(Hours)) + 'h'
  else
    Result := IntToStr(Round(Hours / 24)) + 'd';
end;

function CanonicalizeURLForDedup(const URL: string): string;
{ Lowercase ONLY the scheme + host portion (everything up to but
  not including the first '/' after '://') and leave path/query
  case-sensitive. Per RFC 3986, scheme and host are case-
  insensitive but path and query commonly aren't -- /API and /api
  are routinely distinct resources. The previous SameText
  comparison over the full URL collided those two together and
  would have served stale content. Codex P2 on PR #192.

  Returns URL unchanged when the structure isn't recognisable so
  a malformed URL never gets a false cache hit. }
var
  SchemeMark, PathStart: Integer;
begin
  SchemeMark := Pos('://', URL);
  if SchemeMark <= 0 then Exit(URL);
  PathStart := PosEx('/', URL, SchemeMark + 3);
  if PathStart <= 0 then
    { No path -- whole URL is scheme+host. }
    Exit(LowerCase(URL));
  Result := LowerCase(Copy(URL, 1, PathStart - 1)) +
            Copy(URL, PathStart, MaxInt);
end;

function BuildBodyWithHeader(const URL, ContentType, Body: string): string;
begin
  Result :=
    '<!-- pasclaw memory_fetch -->' + sLineBreak +
    'source: ' + URL + sLineBreak +
    'fetched_at: ' + NowIsoUtc + sLineBreak +
    'content-type: ' + ContentType + sLineBreak +
    sLineBreak +
    Body;
end;

function Tool_MemoryFetch(const ArgsJSON: string; out ErrMsg: string): string;
var
  Obj: TJsonObject;
  URL, NameHint, FilenameBase, Filename, FullPath: string;
  RedirectGuard: TMemoryFetchRedirectGuard;
  Resp: THTTPResult;
  Headers: array of THeaderPair;
  TextBody, ContentType, FinalBody, SsrfWhy: string;
  CachedURL: string;
  CachedAt, NowUtc: TDateTime;
  AgeHours: Double;
  Sl: TStringList;
begin
  ErrMsg := '';
  Result := '';
  SetLength(Headers, 0);

  Obj := nil;
  try
    try
      Obj := TJsonObject.Parse(ArgsJSON);
    except
      on E: Exception do
      begin
        ErrMsg := 'memory_fetch: bad JSON: ' + E.Message;
        Exit;
      end;
    end;
    if Obj = nil then
    begin
      ErrMsg := 'memory_fetch: missing required argument: url';
      Exit;
    end;
    URL      := Trim(Obj.GetStr('url',  ''));
    NameHint := Trim(Obj.GetStr('name', ''));
  finally
    Obj.Free;
  end;

  if URL = '' then
  begin
    ErrMsg := 'memory_fetch: missing required argument: url';
    Exit;
  end;
  if not IsAbsoluteHttpURL(URL) then
  begin
    ErrMsg := 'memory_fetch: url must be http:// or https://';
    Exit;
  end;
  { Gate on NetworkBlockingActive so operators who flip
    sandbox.block_private_networks=false get the same escape
    hatch web_fetch already exposes (and the redirect guard
    here already honours). Codex P2 on PR #180 -- without this
    gate, memory_fetch refused localhost/RFC1918 URLs even when
    web_fetch was happily reaching them in the same session. }
  if NetworkBlockingActive and URLIsLocal(URL, SsrfWhy) then
  begin
    ErrMsg := 'memory_fetch: SSRF block: ' + SsrfWhy;
    Exit;
  end;

  if NameHint = '' then NameHint := ExtractUrlNameHint(URL);
  FilenameBase := SanitizeFilename(NameHint);
  if FilenameBase = '' then FilenameBase := FallbackHashName(URL);
  Filename := 'fetched-' + FilenameBase + '.md';
  FullPath := JoinPath(MemoryDir, Filename);

  { Auto-dedup: if the destination file exists, was written for
    THIS URL (not just a name-collision from a different URL), and
    falls inside the freshness window, skip the HTTP and return
    the cached path. Cuts a round trip + the body's token cost on
    repeat fetches of stable references (RFCs, API docs). When the
    cached URL doesn't match the requested one we fall through to
    re-fetch -- the operator passed `name=` for a different URL,
    which is a legitimate overwrite. }
  if FileExists(FullPath) and
     ReadCachedHeader(FullPath, CachedURL, CachedAt) and
     (CanonicalizeURLForDedup(CachedURL) =
      CanonicalizeURLForDedup(URL)) then
  begin
    {$IFDEF FPC}
    NowUtc := LocalTimeToUniversal(Now);
    {$ELSE}
    NowUtc := TTimeZone.Local.ToUniversalTime(Now);
    {$ENDIF}
    AgeHours := (NowUtc - CachedAt) * 24.0;
    if (AgeHours >= 0) and (AgeHours < MEMORY_FETCH_DEDUP_HOURS) then
    begin
      LogInfo('memory_fetch: cache hit on %s (age=%.1fh) -> %s',
              [URL, AgeHours, Filename]);
      Result := Format(
        'memory_fetch: already indexed (cached %s ago) as %s. ' +
        'Run memory_search to query.',
        [FormatAgeHours(AgeHours), Filename]);
      Exit;
    end;
  end;

  if not DirectoryExists(MemoryDir) then
    if not ForceDirectories(MemoryDir) then
    begin
      ErrMsg := 'memory_fetch: cannot create ' + MemoryDir;
      Exit;
    end;

  RedirectGuard := TMemoryFetchRedirectGuard.Create;
  try
    Resp := GetURL(URL, Headers, 30,
                   'Mozilla/5.0 (PasClaw memory_fetch)',
                   'text/html,application/xhtml+xml,text/plain,text/markdown;q=0.9,*/*;q=0.5',
                   RedirectGuard.OnRedirect);
  finally
    RedirectGuard.Free;
  end;

  if Resp.ErrorMsg <> '' then
  begin
    ErrMsg := 'memory_fetch: HTTP error: ' + Resp.ErrorMsg;
    Exit;
  end;
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    ErrMsg := Format('memory_fetch: HTTP %d for %s', [Resp.StatusCode, URL]);
    Exit;
  end;

  ContentType := Resp.ContentType;

  { HTML pages flow through HTMLToText so the body indexes as
    searchable prose, not a wall of markup. Plain text + markdown
    + JSON pass through; we still cap at MEMORY_FETCH_MAX_CHARS
    so a runaway page doesn't drop a megabyte into the index. }
  if (Pos('text/html',             ContentType) > 0) or
     (Pos('application/xhtml+xml', ContentType) > 0) or
     (ContentType = '') then
    TextBody := HTMLToText(Resp.Body, MEMORY_FETCH_MAX_CHARS)
  else if LooksTextual(ContentType) then
  begin
    TextBody := Resp.Body;
    if Length(TextBody) > MEMORY_FETCH_MAX_CHARS then
      TextBody := Copy(TextBody, 1, MEMORY_FETCH_MAX_CHARS) +
                  sLineBreak + '...(truncated)';
  end
  else
  begin
    ErrMsg := 'memory_fetch: non-textual content-type ' + ContentType +
              ' -- use web_fetch with save_to= for binary downloads';
    Exit;
  end;

  FinalBody := BuildBodyWithHeader(URL, ContentType, TextBody);

  Sl := TStringList.Create;
  try
    Sl.Text := FinalBody;
    try
      Sl.SaveToFile(FullPath);
    except
      on E: Exception do
      begin
        ErrMsg := 'memory_fetch: write failed: ' + E.Message;
        Exit;
      end;
    end;
  finally
    Sl.Free;
  end;

  LogInfo('memory_fetch: %s -> %s (%d chars, %s)',
          [URL, Filename, Length(TextBody), ContentType]);
  Result := Format('memory_fetch: %d chars from %s indexed as %s. ' +
                   'Run memory_search to query.',
                   [Length(TextBody), URL, Filename]);
end;

procedure RegisterMemoryFetchTool(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;
  T := Default(TTool);
  T.Name        := 'memory_fetch';
  T.Description := 'Fetch a URL and write its body to workspace/memory/ so it can be retrieved by memory_search. ' +
                   'Unlike web_fetch, the body does NOT enter the conversation -- only a one-line confirmation. ' +
                   'Use this for reference docs you may want to query later (manuals, RFCs, API docs).';
  T.Schema      := '{"type":"object","properties":{' +
                   '"url":{"type":"string","description":"http:// or https:// URL to fetch."},' +
                   '"name":{"type":"string","description":"Optional filename hint. Sanitised; .md suffix added; ''fetched-'' prefix applied. Defaults to last URL path segment."}' +
                   '},"required":["url"]}';
  T.Handler     := Tool_MemoryFetch;
  T.IsCore      := False;
  T.Category    := tcMutating;   { writes to workspace/memory/ }
  R.Register(T);
end;

end.
