(*
  PasClaw.Tools.WebFetch - registers the web_fetch tool.

  Fetches an arbitrary HTTP/HTTPS URL with TIdHTTP, follows redirects
  (capped at 5), and converts the response body to plain text via
  PasClaw.Search.HTMLText. Default text cap is 50 KB to keep one
  page from blowing the model's context; an explicit `max_chars`
  argument can raise or lower it.

  Schema:
    {
      "url":       "<string, required>",
      "max_chars": <integer, optional, default 50000>
    }

  Safety: refuses non-http/https schemes (no file://, ftp://,
  data://) so a misbehaving model can't read local files via this
  path -- it would have to go through fs_read which is sandbox-
  governed.

  Out of scope for Wave 1 (deferred to a later PR):
    - SSRF protection (block requests to RFC1918 / loopback /
      link-local) -- picoclaw does this; PasClaw will when somebody
      actually deploys a public-facing agent.
    - Markdown conversion. The current strip-tags output is enough
      for the model to read.
    - User-Agent overrides per-request.
*)
unit PasClaw.Tools.WebFetch;

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

procedure RegisterWebFetchTool(R: TToolRegistry);

implementation

uses
  Classes,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP,
  PasClaw.Search.HTMLText,
  PasClaw.Net.SSRF,
  PasClaw.Tools.Sandbox;

type
  (* Redirect guard hooked into PasClaw.Providers.HTTP. Runs URLIsLocal
     on every 3xx target so a public→private redirect can't smuggle a
     request past the pre-check. Setting Allow := False aborts the
     redirect chain -- the wrapper raises with Reason, and the outer
     try/except in Tool_WebFetch surfaces it as the same "SSRF
     blocked" string a direct hit would produce. *)
  TWebFetchRedirectGuard = class
    procedure OnRedirect(var Dest: string;
                          var Allow: Boolean;
                          var Reason: string);
  end;

function IsAbsoluteHttpURL(const S: string): Boolean;
{ True iff S has an http:// or https:// scheme. Anything else is
  either path-relative ("/login", "next.html") or protocol-relative
  ("//cdn.example.com/a"). The wrapper hands OnRedirect whatever the
  server's Location header said -- which is frequently a bare path,
  NOT a full URL. Codex PR #85 P2 caught that we were rejecting
  "/login" as malformed. }
begin
  Result := (Length(S) >= 7) and
            (SameText(Copy(S, 1, 7),  'http://')  or
             (Length(S) >= 8) and SameText(Copy(S, 1, 8), 'https://'));
end;

procedure TWebFetchRedirectGuard.OnRedirect(var Dest: string;
                                              var Allow: Boolean;
                                              var Reason: string);
var
  Why: string;
begin
  Allow := True;
  if not NetworkBlockingActive then Exit;

  { Same-origin redirects retain the host that already passed the
    pre-check. Two flavours:
      "/path/next"     -- path-relative; same scheme, host, port.
      "next.html"      -- path-relative without leading slash; same.
    A protocol-relative URL ("//cdn.example.com/a") DOES change
    host so we still pass it through URLIsLocal -- ExtractHost
    handles those since "//" parses as an authority without a
    scheme, and a bare authority is enough to read the host. }
  if not IsAbsoluteHttpURL(Dest) then
  begin
    if (Length(Dest) >= 2) and (Dest[1] = '/') and (Dest[2] = '/') then
    begin
      { Protocol-relative. Synthesise an http:// prefix purely for
        the parse -- the underlying client will re-prefix with the
        current URL's scheme before connecting. }
      if URLIsLocal('http:' + Dest, Why) then
      begin
        Allow := False;
        Reason := Format(
          'SSRF: protocol-relative redirect to %s refused (%s; ' +
          'flip sandbox.block_private_networks=false in config.json to allow)',
          [Dest, Why]);
      end;
      Exit;
    end;
    { Path-relative -- same host as the request that just passed
      the check. Let the request proceed. }
    Exit;
  end;

  if URLIsLocal(Dest, Why) then
  begin
    Allow := False;
    Reason := Format('SSRF: redirect to %s refused (%s; ' +
      'flip sandbox.block_private_networks=false in config.json to allow)',
      [Dest, Why]);
  end;
end;

const
  DEFAULT_MAX_CHARS = 50000;
  HARD_MAX_CHARS    = 200000;

function ParseStringArg(const ArgsJSON, Field: string; out V: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  V := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      V := Obj.GetStr(Field, '');
      Result := V <> '';
    finally
      Obj.Free;
    end;
  except
    Result := False;
  end;
end;

function ParseIntArg(const ArgsJSON, Field: string; Default: Integer): Integer;
var
  Obj: TJsonObject;
begin
  Result := Default;
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      if Obj.Has(Field) then Result := Obj.GetInt(Field, Default);
    finally
      Obj.Free;
    end;
  except
    Result := Default;
  end;
end;

function LowerStartsWith(const S, Prefix: string): Boolean;
begin
  Result := (Length(S) >= Length(Prefix)) and
            SameText(Copy(S, 1, Length(Prefix)), Prefix);
end;

function EnsureParentDir(const Path: string; out ErrMsg: string): Boolean;
var
  Dir: string;
begin
  Result := True;
  ErrMsg := '';
  Dir := ExtractFilePath(Path);
  if (Dir <> '') and not DirectoryExists(Dir) then
    if not ForceDirectories(Dir) then
    begin
      ErrMsg := 'web_fetch: cannot create parent directory: ' + Dir;
      Result := False;
    end;
end;

function ReadPreviewBytes(const Path: string; MaxBytes: Integer): TBytes;
{ Read up to MaxBytes from Path for the receipt preview. Used after a
  binary-safe stream download where Resp.Body is empty. }
var
  FS: TFileStream;
  N: Int64;
begin
  SetLength(Result, 0);
  if not FileExists(Path) then Exit;
  try
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
    try
      N := FS.Size;
      if N > MaxBytes then N := MaxBytes;
      SetLength(Result, N);
      if N > 0 then FS.ReadBuffer(Result[0], N);
    finally
      FS.Free;
    end;
  except
    SetLength(Result, 0);
  end;
end;

function LooksTextual(const ContentType: string): Boolean;
begin
  Result := (Pos('text/', ContentType) = 1) or
            (Pos('application/json',       ContentType) > 0) or
            (Pos('application/xml',        ContentType) > 0) or
            (Pos('application/javascript', ContentType) > 0) or
            (Pos('application/xhtml',      ContentType) > 0);
end;

function Tool_WebFetch(const ArgsJSON: string; out ErrMsg: string): string;
var
  URL, SaveTo, SandboxReason, Preview: string;
  MaxChars: Integer;
  RedirectGuard: TWebFetchRedirectGuard;
  Resp: THTTPResult;
  Headers: array of THeaderPair;
  FS: TFileStream;
  Bytes: TBytes;
  WrittenBytes: Int64;
begin
  ErrMsg := '';
  Result := '';
  SetLength(Headers, 0);

  if not ParseStringArg(ArgsJSON, 'url', URL) then
  begin
    ErrMsg := 'missing required argument: url';
    Exit;
  end;
  if not (LowerStartsWith(URL, 'http://') or LowerStartsWith(URL, 'https://')) then
  begin
    ErrMsg := 'web_fetch only supports http:// and https:// URLs';
    Exit;
  end;

  MaxChars := ParseIntArg(ArgsJSON, 'max_chars', DEFAULT_MAX_CHARS);
  if MaxChars < 100           then MaxChars := 100;
  if MaxChars > HARD_MAX_CHARS then MaxChars := HARD_MAX_CHARS;

  { Optional curl -o: when save_to is set, the full response body is
    written to disk and the tool result becomes a small receipt
    instead of the inlined content. The model then uses fs_read /
    fs_grep on the saved file. This skips the max_chars cap entirely
    so the model can pull down arbitrarily large pages / API dumps
    without blowing the context window. }
  ParseStringArg(ArgsJSON, 'save_to', SaveTo);
  if SaveTo <> '' then
  begin
    if not CanWritePath(SaveTo, SandboxReason) then
    begin
      ErrMsg := 'web_fetch: save_to refused: ' + SandboxReason;
      Exit;
    end;
  end;

  { SSRF pre-check on the initial URL. The redirect guard covers
    subsequent hops; both layers must pass for the request to land. }
  if NetworkBlockingActive then
  begin
    if URLIsLocal(URL, ErrMsg) then
    begin
      ErrMsg := 'web_fetch: SSRF: ' + URL + ' refused (' + ErrMsg +
        '; flip sandbox.block_private_networks=false in config.json to allow)';
      Exit;
    end;
    ErrMsg := '';
  end;

  { save_to: stream bytes straight to disk via the binary-safe wrapper.
    GetURL returns a UTF-8-decoded string, which mangles non-text
    payloads (PDFs, images, archives) on the round trip back through
    TEncoding.UTF8.GetBytes -- losing precisely the use case save_to
    advertises. The receipt + preview are reconstructed from the file
    so the model still gets a sniffable hint. }
  if SaveTo <> '' then
  begin
    if not EnsureParentDir(SaveTo, ErrMsg) then Exit;
    RedirectGuard := TWebFetchRedirectGuard.Create;
    try
      { TFileStream.Create lives OUTSIDE the inner try-finally so its
        FS.Free only runs when Create actually succeeded. The previous
        shape pre-init'd FS := nil + WrittenBytes := 0 to protect a
        single outer try-finally that wrapped both branches -- dcc64
        flagged both inits as H2077 because the assignments after
        TFileStream.Create dominate every flow path it traces. The
        restructure makes the lifetimes match the control flow and
        silences the hint without weakening the safety. }
      try
        FS := TFileStream.Create(SaveTo, fmCreate);
      except
        on E: Exception do
        begin
          ErrMsg := 'web_fetch: write failed: ' + E.Message;
          Exit;
        end;
      end;
      try
        Resp := GetURLToStreamGuarded(URL, FS, Headers, 30,
                                       'Mozilla/5.0 (PasClaw web_fetch)',
                                       '*/*',
                                       RedirectGuard.OnRedirect);
        WrittenBytes := FS.Size;
      finally
        FS.Free;
      end;
    finally
      RedirectGuard.Free;
    end;

    if Resp.ErrorMsg <> '' then
    begin
      ErrMsg := 'web_fetch: HTTP error: ' + Resp.ErrorMsg;
      Exit;
    end;

    Bytes := ReadPreviewBytes(SaveTo, 200);
    if (Length(Bytes) > 0) and LooksTextual(Resp.ContentType) then
      Preview := TEncoding.UTF8.GetString(Bytes)
    else
      Preview := '';

    Result := Format('web_fetch: saved %d bytes to %s (status %d, content-type %s)',
                     [WrittenBytes, SaveTo, Resp.StatusCode, Resp.ContentType]);
    if Trim(Preview) <> '' then
      Result := Result + sLineBreak + 'preview: ' + Preview
    else if not LooksTextual(Resp.ContentType) then
      Result := Result + sLineBreak + 'preview: (binary content)';
    LogDebug('web_fetch url=%s bytes_in=%d saved_to=%s',
             [URL, WrittenBytes, SaveTo]);
    Exit;
  end;

  RedirectGuard := TWebFetchRedirectGuard.Create;
  try
    Resp := GetURL(URL, Headers, 30,
                   'Mozilla/5.0 (PasClaw web_fetch)',
                   'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5',
                   RedirectGuard.OnRedirect);
  finally
    RedirectGuard.Free;
  end;

  if Resp.ErrorMsg <> '' then
  begin
    ErrMsg := 'web_fetch: HTTP error: ' + Resp.ErrorMsg;
    Exit;
  end;

  if (Pos('text/html',             Resp.ContentType) > 0) or
     (Pos('application/xhtml+xml', Resp.ContentType) > 0) or
     (Resp.ContentType = '') then
    Result := HTMLToText(Resp.Body, MaxChars)
  else if Pos('text/', Resp.ContentType) = 1 then
  begin
    Result := Resp.Body;
    if Length(Result) > MaxChars then
      Result := Copy(Result, 1, MaxChars) + #10 + '…(truncated)';
  end
  else
  begin
    ErrMsg := Format('web_fetch: unsupported content-type %s (try save_to to download as-is)',
                     [Resp.ContentType]);
    Exit;
  end;

  LogDebug('web_fetch url=%s bytes_in=%d chars_out=%d',
           [URL, Length(Resp.Body), Length(Result)]);
end;

procedure RegisterWebFetchTool(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;
  T.Name        := 'web_fetch';
  T.Description :=
    'Fetch an HTTP/HTTPS URL and return its READABLE PLAIN TEXT: HTML tags ' +
    'are stripped and entities decoded, capped at max_chars (default 50000 ' +
    'characters -- raise it, or use save_to, for more). It does NOT run ' +
    'JavaScript, so a JS-rendered single-page app returns little; for those ' +
    'fetch a raw/API/README URL instead. Pass save_to to write the FULL body ' +
    '(no char cap) to a workspace file -- for large pages or binary ' +
    'downloads -- then read_file / grep_files it; the tool result is just a ' +
    'receipt + short preview when save_to is set.';
  T.Schema      :=
    '{"type":"object",' +
    '"properties":{' +
    '"url":{"type":"string","description":"http:// or https:// URL."},' +
    '"max_chars":{"type":"integer","minimum":100,"maximum":200000,"description":"Inline output char cap (default 50000). Ignored when save_to is set."},' +
    '"save_to":{"type":"string","description":"Optional workspace-relative path. When set, the full response body is written there and the tool returns a receipt only."}' +
    '},"required":["url"]}';
  T.Handler     := Tool_WebFetch;
  T.IsCore      := True;
  { Mutating because save_to writes to the workspace. Without this the
    agent scheduler can run a follow-up fs_read in parallel with the
    in-flight download and observe a half-written file. The plain
    inlined-text path doesn't touch shared state, but tagging at the
    tool level (not per-call) is the only signal the registry exposes. }
  T.Category    := tcMutating;
  R.Register(T);
end;

end.
