(*
  PasClaw.Providers.HTTP - centralised outbound HTTP wrapper.

  Two interchangeable backends, picked by compile-time define:

    Indy (default everywhere)
      - TIdHTTP + TIdSSLIOHandlerSocketOpenSSL.
      - HTTPS needs OpenSSL DLLs: libssl-dev / libssl.so.3 on Linux;
        libeay32.dll + ssleay32.dll next to pasclaw.exe on Windows
        (or under $PASCLAW_OPENSSL_DIR). EnsureOpenSSL probes both.
      - Works on FPC and Delphi -- the only path FPC supports.

    TNetHTTPClient (Delphi-only, opt-in)
      - THTTPClient via System.Net.HttpClient.
      - Uses Windows SChannel / Apple TransportSecurity / NSURLSession,
        so no OpenSSL DLLs are needed at all.
      - Enable with -DPASCLAW_NETHTTP on the dcc32/dcc64 command line,
        or by adding the symbol to the project's conditional defines.
        Ignored under FPC since TNetHTTPClient doesn't exist there --
        FPC stays on Indy regardless.

  The public interface is library-neutral; callers see neither Indy
  nor TNetHTTPClient types. EnsureOpenSSL stays in the interface for
  both backends -- it's a no-op success under TNetHTTPClient so an
  onboarding precheck can call it uniformly.
*)
unit PasClaw.Providers.HTTP;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  THeaderPair = record
    Name, Value: string;
  end;
  THeaderPairs = array of THeaderPair;

  THTTPResult = record
    StatusCode:  Integer;
    Body:        string;
    { Lower-cased Content-Type returned by the server, with charset
      etc. preserved (e.g. "text/html; charset=utf-8"). Empty on error
      or for endpoints that do not set one. }
    ContentType: string;
    ErrorMsg:    string;
    { Full response header list, populated by both backends. Names
      are case-preserved from the server; callers comparing should
      use SameText. The MCP HTTP client reads "Mcp-Session-Id" off
      this for the Streamable HTTP transport's session tracking. }
    RespHeaders: THeaderPairs;
  end;

  { Redirect guard invoked before following each 3xx response. Set
    Allow := False to abort the request; the wrapper raises with
    Reason, which propagates back as ErrorMsg on the THTTPResult.
    DestURL is mutable for callers that want to rewrite redirects;
    leaving it untouched preserves the server's Location header. }
  THTTPRedirectGuard = procedure(var DestURL: string;
                                  var Allow: Boolean;
                                  var Reason: string) of object;

function PostJSON(const URL, JSON: string;
                  const Headers: array of THeaderPair;
                  TimeoutSeconds: Integer): THTTPResult;
function PutJSON(const URL, JSON: string;
                 const Headers: array of THeaderPair;
                 TimeoutSeconds: Integer): THTTPResult;
function GetJSONURL(const URL: string;
                    const Headers: array of THeaderPair;
                    TimeoutSeconds: Integer): THTTPResult;

{ GET with optional User-Agent / Accept overrides and a redirect
  guard. Pass '' for UserAgent/Accept to keep the wrapper's defaults
  ('PasClaw/0.1 ...' and '*/*'); nil for OnRedirect to follow
  redirects without inspection.

  Used by web_fetch (SSRF guard on each hop, browser-ish UA, HTML
  Accept) and by search providers that need a custom UA. }
function GetURL(const URL: string;
                const Headers: array of THeaderPair;
                TimeoutSeconds: Integer;
                const UserAgent: string;
                const Accept: string;
                OnRedirect: THTTPRedirectGuard): THTTPResult;

{ POST with caller-supplied content type and a UTF-8 encoded body.
  For form-encoded posts (application/x-www-form-urlencoded) and any
  other non-JSON payload. UserAgent/Accept follow the same '' = default
  convention as GetURL. }
function PostRaw(const URL, ContentType, Body: string;
                 const Headers: array of THeaderPair;
                 TimeoutSeconds: Integer;
                 const UserAgent: string;
                 const Accept: string): THTTPResult;

{ POST JSON and write the response body into RespStream instead of
  returning it as a string. The SSE provider uses this -- it asks for
  text/event-stream and parses the buffered response after the call
  completes. Returns False on transport error with ErrMsg populated;
  StatusCode is always set to what Indy saw (0 if the request never
  reached a status line). }
function PostJSONToStream(const URL, JSON: string;
                          RespStream: TStream;
                          const Headers: array of THeaderPair;
                          TimeoutSeconds: Integer;
                          const UserAgent: string;
                          const Accept: string;
                          out StatusCode: Integer;
                          out ErrMsg: string): Boolean;

{ Binary HTTP GET into a caller-owned stream. Use this for zip
  downloads, embedding fetches, etc. -- anything where TStringStream's
  UTF-8 decoding would corrupt the payload. Caller positions and
  sizes Stream however they need afterward.

  Returns a THTTPResult with StatusCode and ErrorMsg set; Body stays
  empty (the bytes went into Stream). HandleRedirects is on so a
  GitHub codeload 302 -> Amazon S3 URL works transparently. }
function GetURLToStream(const URL: string; Stream: TStream;
                        const Headers: array of THeaderPair;
                        TimeoutSeconds: Integer): THTTPResult;

{ GetURL's redirect-guard + UA/Accept overrides combined with
  GetURLToStream's raw-bytes output. For web_fetch's save_to path:
  callers want SSRF-checked downloads of arbitrary content (PDFs,
  images, tarballs) where the UTF-8 round-trip through THTTPResult.Body
  would mangle non-text bytes. ContentType/StatusCode/RespHeaders are
  populated as usual; Body stays empty. }
function GetURLToStreamGuarded(const URL: string;
                                RespStream: TStream;
                                const Headers: array of THeaderPair;
                                TimeoutSeconds: Integer;
                                const UserAgent: string;
                                const Accept: string;
                                OnRedirect: THTTPRedirectGuard): THTTPResult;

function MakeHeader(const Name, Value: string): THeaderPair;

{ Returns True if Indy can load OpenSSL; otherwise False and ErrMsg
  contains an actionable message naming the DLLs and the override env
  var. Safe to call multiple times -- probing happens once and caches. }
function EnsureOpenSSL(out ErrMsg: string): Boolean;

{ Lowercased host of a URL (scheme, userinfo, port and path stripped;
  bracketed IPv6 literals unwrapped). Exposed for testing the proxy path. }
function ExtractURLHost(const URL: string): string;

{ True when Host must bypass the proxy: loopback always, plus any match
  against the NoProxy list (comma-separated; '*' = all, exact or domain-
  suffix match, optional leading '.'). NoProxy is passed in (rather than
  read from the environment) so the matcher is pure and testable. }
function HostBypassesProxy(const Host, NoProxy: string): Boolean;

implementation

uses
  PasClaw.Utils,
{$IF Defined(PASCLAW_NETHTTP) and not Defined(FPC)}
  System.Net.URLClient, System.Net.HttpClient;
{$ELSE}
  IdHTTP, IdSSLOpenSSL, IdSSLOpenSSLHeaders,
  IdGlobal, IdExceptionCore, IdException;
{$IFEND}

function MakeHeader(const Name, Value: string): THeaderPair;
begin
  Result.Name  := Name;
  Result.Value := Value;
end;

function MakeHTTPS(URL: string): Boolean;
begin
  Result := (Length(URL) >= 8) and SameText(Copy(URL, 1, 8), 'https://');
end;

{$IF Defined(PASCLAW_NETHTTP) and not Defined(FPC)}
(* ============================================================
   TNetHTTPClient backend -- Delphi only, opt-in via -DPASCLAW_NETHTTP.
   TLS via the OS (SChannel on Windows, Secure Transport on macOS,
   OpenSSL via NSURLSession-equivalent on Linux), so no OpenSSL DLL
   shipping requirement. EnsureOpenSSL is a no-op success here for
   onboarding-precheck parity.
   ============================================================ *)

function EnsureOpenSSL(out ErrMsg: string): Boolean;
begin
  ErrMsg := '';
  Result := True;
end;

function MakeNetHeaders(const Headers: array of THeaderPair): TNetHeaders;
var
  i: Integer;
begin
  SetLength(Result, Length(Headers));
  for i := 0 to High(Headers) do
    Result[i] := TNetHeader.Create(Headers[i].Name, Headers[i].Value);
end;

function NewNetClient(TimeoutSeconds: Integer;
                      const UserAgent, Accept: string): THTTPClient;
begin
  Result := THTTPClient.Create;
  Result.ConnectionTimeout := TimeoutSeconds * 1000;
  Result.ResponseTimeout   := TimeoutSeconds * 1000;
  Result.HandleRedirects   := True;
  if UserAgent <> '' then
    Result.UserAgent := UserAgent
  else
    Result.UserAgent := 'PasClaw/0.1 (+https://github.com/FMXExpress/PasClaw)';
  if Accept <> '' then
    Result.Accept := Accept;
end;

type
  { Bridges THTTPRedirectGuard to THTTPClient.OnRedirect (typed as
    THTTPRedirectEvent). The event can't raise to abort -- it cancels
    the follow by setting AAllow := False -- so we record the refusal
    on this adapter and the caller promotes it to THTTPResult.ErrorMsg
    after the request returns. ARequest.URL is mutable through the
    interface even though ARequest itself is const, so the guard can
    rewrite the redirect destination. }
  TNetRedirectAdapter = class
  private
    FGuard: THTTPRedirectGuard;
  public
    Rejected:     Boolean;
    RejectReason: string;
    constructor Create(AGuard: THTTPRedirectGuard);
    procedure OnRedirect(const Sender: TObject;
                          const ARequest: IHTTPRequest;
                          const AResponse: IHTTPResponse;
                          ARedirections: Integer;
                          var AAllow: Boolean);
  end;

constructor TNetRedirectAdapter.Create(AGuard: THTTPRedirectGuard);
begin
  inherited Create;
  FGuard       := AGuard;
  Rejected     := False;
  RejectReason := '';
end;

procedure TNetRedirectAdapter.OnRedirect(const Sender: TObject;
                                          const ARequest: IHTTPRequest;
                                          const AResponse: IHTTPResponse;
                                          ARedirections: Integer;
                                          var AAllow: Boolean);
var
  Dest, LocalReason: string;
  Allow: Boolean;
begin
  if not Assigned(FGuard) then
  begin
    AAllow := True;
    Exit;
  end;
  Dest        := ARequest.URL.ToString;
  Allow       := True;
  LocalReason := '';
  FGuard(Dest, Allow, LocalReason);
  ARequest.URL := TURI.Create(Dest);
  AAllow       := Allow;
  if not Allow then
  begin
    Rejected     := True;
    RejectReason := LocalReason;
  end;
end;

function NetExecute(C: THTTPClient; const Method, URL: string;
                    Req: TStream;
                    Resp: TStream;
                    const Hdrs: TNetHeaders;
                    out StatusCode: Integer;
                    out ContentType: string;
                    out RespHeaders: THeaderPairs;
                    out ErrMsg: string): Boolean;
{ Dispatch through THTTPClient's verb-specific helpers. The inherited
  TURLClient.Execute(method, url, ...) overload returns IURLResponse,
  not IHTTPResponse, so its result can't be assigned to an IHTTPResponse
  local. Get/Post/Put each return IHTTPResponse natively. }
var
  R: IHTTPResponse;
  i: Integer;
begin
  Result := False;
  StatusCode  := 0;
  ContentType := '';
  ErrMsg      := '';
  SetLength(RespHeaders, 0);
  try
    if SameText(Method, 'GET') then
      R := C.Get(URL, Resp, Hdrs)
    else if SameText(Method, 'POST') then
      R := C.Post(URL, Req, Resp, Hdrs)
    else if SameText(Method, 'PUT') then
      R := C.Put(URL, Req, Resp, Hdrs)
    else
    begin
      ErrMsg := 'unsupported HTTP method: ' + Method;
      Exit;
    end;
    StatusCode  := R.StatusCode;
    ContentType := LowerCase(R.MimeType);
    SetLength(RespHeaders, Length(R.Headers));
    for i := 0 to High(R.Headers) do
    begin
      RespHeaders[i].Name  := R.Headers[i].Name;
      RespHeaders[i].Value := R.Headers[i].Value;
    end;
    Result := True;
  except
    on E: Exception do
      ErrMsg := E.Message;
  end;
end;

function PostJSON(const URL, JSON: string;
                  const Headers: array of THeaderPair;
                  TimeoutSeconds: Integer): THTTPResult;
var
  C: THTTPClient;
  Req, Resp: TStringStream;
  Hdrs: TNetHeaders;
begin
  Result.StatusCode  := 0;
  Result.Body        := '';
  Result.ContentType := '';
  Result.ErrorMsg    := '';
  C    := NewNetClient(TimeoutSeconds, '', 'application/json');
  Req  := TStringStream.Create(JSON, TEncoding.UTF8);
  Resp := TStringStream.Create('', TEncoding.UTF8);
  try
    Hdrs := MakeNetHeaders(Headers);
    Hdrs := Hdrs + [TNetHeader.Create('Content-Type', 'application/json; charset=utf-8')];
    NetExecute(C, 'POST', URL, Req, Resp, Hdrs,
               Result.StatusCode, Result.ContentType,
               Result.RespHeaders, Result.ErrorMsg);
    Result.Body := Resp.DataString;
    TagUTF8(Result.Body);
  finally
    Resp.Free;
    Req.Free;
    C.Free;
  end;
end;

function PutJSON(const URL, JSON: string;
                 const Headers: array of THeaderPair;
                 TimeoutSeconds: Integer): THTTPResult;
var
  C: THTTPClient;
  Req, Resp: TStringStream;
  Hdrs: TNetHeaders;
begin
  Result.StatusCode  := 0;
  Result.Body        := '';
  Result.ContentType := '';
  Result.ErrorMsg    := '';
  C    := NewNetClient(TimeoutSeconds, '', 'application/json');
  Req  := TStringStream.Create(JSON, TEncoding.UTF8);
  Resp := TStringStream.Create('', TEncoding.UTF8);
  try
    Hdrs := MakeNetHeaders(Headers);
    Hdrs := Hdrs + [TNetHeader.Create('Content-Type', 'application/json; charset=utf-8')];
    NetExecute(C, 'PUT', URL, Req, Resp, Hdrs,
               Result.StatusCode, Result.ContentType,
               Result.RespHeaders, Result.ErrorMsg);
    Result.Body := Resp.DataString;
    TagUTF8(Result.Body);
  finally
    Resp.Free;
    Req.Free;
    C.Free;
  end;
end;

function GetJSONURL(const URL: string;
                    const Headers: array of THeaderPair;
                    TimeoutSeconds: Integer): THTTPResult;
var
  C: THTTPClient;
  Resp: TStringStream;
  Hdrs: TNetHeaders;
begin
  Result.StatusCode  := 0;
  Result.Body        := '';
  Result.ContentType := '';
  Result.ErrorMsg    := '';
  C    := NewNetClient(TimeoutSeconds, '', 'application/json');
  Resp := TStringStream.Create('', TEncoding.UTF8);
  try
    Hdrs := MakeNetHeaders(Headers);
    NetExecute(C, 'GET', URL, nil, Resp, Hdrs,
               Result.StatusCode, Result.ContentType,
               Result.RespHeaders, Result.ErrorMsg);
    Result.Body := Resp.DataString;
    TagUTF8(Result.Body);
  finally
    Resp.Free;
    C.Free;
  end;
end;

function GetURL(const URL: string;
                const Headers: array of THeaderPair;
                TimeoutSeconds: Integer;
                const UserAgent: string;
                const Accept: string;
                OnRedirect: THTTPRedirectGuard): THTTPResult;
var
  C: THTTPClient;
  Resp: TStringStream;
  Hdrs: TNetHeaders;
  EffAccept: string;
  Adapter: TNetRedirectAdapter;
begin
  Result.StatusCode  := 0;
  Result.Body        := '';
  Result.ContentType := '';
  Result.ErrorMsg    := '';
  if Accept <> '' then EffAccept := Accept else EffAccept := '*/*';
  C       := NewNetClient(TimeoutSeconds, UserAgent, EffAccept);
  Resp    := TStringStream.Create('', TEncoding.UTF8);
  Adapter := nil;
  try
    if Assigned(OnRedirect) then
    begin
      Adapter := TNetRedirectAdapter.Create(OnRedirect);
      C.OnRedirect := Adapter.OnRedirect;
    end;
    Hdrs := MakeNetHeaders(Headers);
    NetExecute(C, 'GET', URL, nil, Resp, Hdrs,
               Result.StatusCode, Result.ContentType,
               Result.RespHeaders, Result.ErrorMsg);
    Result.Body := Resp.DataString;
    TagUTF8(Result.Body);
    if (Adapter <> nil) and Adapter.Rejected then
    begin
      Result.ErrorMsg    := Adapter.RejectReason;
      Result.StatusCode  := -1;
    end;
  finally
    Adapter.Free;
    Resp.Free;
    C.Free;
  end;
end;

function PostRaw(const URL, ContentType, Body: string;
                 const Headers: array of THeaderPair;
                 TimeoutSeconds: Integer;
                 const UserAgent: string;
                 const Accept: string): THTTPResult;
var
  C: THTTPClient;
  Req, Resp: TStringStream;
  Hdrs: TNetHeaders;
  EffAccept: string;
begin
  Result.StatusCode  := 0;
  Result.Body        := '';
  Result.ContentType := '';
  Result.ErrorMsg    := '';
  if Accept <> '' then EffAccept := Accept else EffAccept := '*/*';
  C    := NewNetClient(TimeoutSeconds, UserAgent, EffAccept);
  Req  := TStringStream.Create(Body, TEncoding.UTF8);
  Resp := TStringStream.Create('', TEncoding.UTF8);
  try
    Hdrs := MakeNetHeaders(Headers);
    Hdrs := Hdrs + [TNetHeader.Create('Content-Type', ContentType + '; charset=utf-8')];
    NetExecute(C, 'POST', URL, Req, Resp, Hdrs,
               Result.StatusCode, Result.ContentType,
               Result.RespHeaders, Result.ErrorMsg);
    Result.Body := Resp.DataString;
    TagUTF8(Result.Body);
  finally
    Resp.Free;
    Req.Free;
    C.Free;
  end;
end;

function PostJSONToStream(const URL, JSON: string;
                          RespStream: TStream;
                          const Headers: array of THeaderPair;
                          TimeoutSeconds: Integer;
                          const UserAgent: string;
                          const Accept: string;
                          out StatusCode: Integer;
                          out ErrMsg: string): Boolean;
var
  C: THTTPClient;
  Req: TStringStream;
  Hdrs: TNetHeaders;
  EffAccept, RespContentType: string;
  DiscardHeaders: THeaderPairs;
begin
  Result := False;
  if Accept <> '' then EffAccept := Accept else EffAccept := 'application/json';
  C   := NewNetClient(TimeoutSeconds, UserAgent, EffAccept);
  Req := TStringStream.Create(JSON, TEncoding.UTF8);
  try
    Hdrs := MakeNetHeaders(Headers);
    Hdrs := Hdrs + [TNetHeader.Create('Content-Type', 'application/json; charset=utf-8')];
    NetExecute(C, 'POST', URL, Req, RespStream, Hdrs,
               StatusCode, RespContentType, DiscardHeaders, ErrMsg);
    Result := (StatusCode >= 200) and (StatusCode < 300);
  finally
    Req.Free;
    C.Free;
  end;
end;

function GetURLToStream(const URL: string; Stream: TStream;
                        const Headers: array of THeaderPair;
                        TimeoutSeconds: Integer): THTTPResult;
var
  C: THTTPClient;
  Hdrs: TNetHeaders;
begin
  Result.StatusCode  := 0;
  Result.Body        := '';
  Result.ContentType := '';
  Result.ErrorMsg    := '';
  C := NewNetClient(TimeoutSeconds, '', '*/*');
  try
    Hdrs := MakeNetHeaders(Headers);
    NetExecute(C, 'GET', URL, nil, Stream, Hdrs,
               Result.StatusCode, Result.ContentType,
               Result.RespHeaders, Result.ErrorMsg);
  finally
    C.Free;
  end;
end;

function GetURLToStreamGuarded(const URL: string;
                                RespStream: TStream;
                                const Headers: array of THeaderPair;
                                TimeoutSeconds: Integer;
                                const UserAgent: string;
                                const Accept: string;
                                OnRedirect: THTTPRedirectGuard): THTTPResult;
var
  C: THTTPClient;
  Hdrs: TNetHeaders;
  EffAccept: string;
  Adapter: TNetRedirectAdapter;
begin
  Result.StatusCode  := 0;
  Result.Body        := '';
  Result.ContentType := '';
  Result.ErrorMsg    := '';
  if Accept <> '' then EffAccept := Accept else EffAccept := '*/*';
  C       := NewNetClient(TimeoutSeconds, UserAgent, EffAccept);
  Adapter := nil;
  try
    if Assigned(OnRedirect) then
    begin
      Adapter := TNetRedirectAdapter.Create(OnRedirect);
      C.OnRedirect := Adapter.OnRedirect;
    end;
    Hdrs := MakeNetHeaders(Headers);
    NetExecute(C, 'GET', URL, nil, RespStream, Hdrs,
               Result.StatusCode, Result.ContentType,
               Result.RespHeaders, Result.ErrorMsg);
    if (Adapter <> nil) and Adapter.Rejected then
    begin
      Result.ErrorMsg    := Adapter.RejectReason;
      Result.StatusCode  := -1;
    end;
  finally
    Adapter.Free;
    C.Free;
  end;
end;

{$ELSE}
(* ============================================================
   Indy backend -- default on both Delphi and FPC.
   ============================================================ *)

procedure ApplyHeaders(Http: TIdHTTP; const Headers: array of THeaderPair);
var
  i: Integer;
begin
  for i := 0 to High(Headers) do
    Http.Request.CustomHeaders.AddValue(Headers[i].Name, Headers[i].Value);
end;

procedure CaptureIndyHeaders(Http: TIdHTTP; var Out_: THeaderPairs);
{ Snapshot Http.Response.RawHeaders into the result record's
  RespHeaders field. Indy's RawHeaders is a TStringList where
  Strings[i] is "Name: Value" -- split on the first colon so values
  containing further colons (e.g. URLs in Location, timestamps)
  survive intact. }
var
  i, P: Integer;
  Line: string;
begin
  SetLength(Out_, Http.Response.RawHeaders.Count);
  for i := 0 to Http.Response.RawHeaders.Count - 1 do
  begin
    Line := Http.Response.RawHeaders[i];
    P := Pos(':', Line);
    if P > 0 then
    begin
      Out_[i].Name  := Trim(Copy(Line, 1, P - 1));
      Out_[i].Value := Trim(Copy(Line, P + 1, MaxInt));
    end
    else
      Out_[i].Name  := Trim(Line);
  end;
end;

function DoRequest(Http: TIdHTTP; const URL: string; const ReqBody: TStream;
                   IsPost: Boolean): THTTPResult;
var
  Resp: TStringStream;
begin
  Result.StatusCode := 0;
  Result.Body := '';
  Result.ContentType := '';
  Result.ErrorMsg := '';
  SetLength(Result.RespHeaders, 0);
  { Force UTF-8 on the response stream. Under Delphi modern, TStringStream
    defaults to TEncoding.Default (the system codepage), which mangles
    non-ASCII bytes in JSON responses. Under FPC the encoding arg is
    accepted and behaves the same. }
  Resp := TStringStream.Create('', TEncoding.UTF8);
  try
    try
      if IsPost then
        Http.Post(URL, ReqBody, Resp)
      else
        Http.Get(URL, Resp);
      Result.StatusCode := Http.ResponseCode;
      Result.Body := Resp.DataString;
      TagUTF8(Result.Body);
      Result.ContentType := LowerCase(Http.Response.ContentType);
      CaptureIndyHeaders(Http, Result.RespHeaders);
    except
      on E: EIdHTTPProtocolException do
      begin
        Result.StatusCode := E.ErrorCode;
        Result.Body       := E.ErrorMessage;
        TagUTF8(Result.Body);
        Result.ContentType := LowerCase(Http.Response.ContentType);
        Result.ErrorMsg   := E.Message;
        CaptureIndyHeaders(Http, Result.RespHeaders);
      end;
      on E: Exception do
      begin
        Result.StatusCode := Http.ResponseCode;
        Result.Body       := Resp.DataString;
        TagUTF8(Result.Body);
        Result.ContentType := LowerCase(Http.Response.ContentType);
        Result.ErrorMsg   := E.Message;
        CaptureIndyHeaders(Http, Result.RespHeaders);
      end;
    end;
  finally
    Resp.Free;
  end;
end;

var
  GSSLProbed: Boolean = False;
  GSSLAvailable: Boolean = False;

procedure ProbeOpenSSL;
{ Steer Indy's loader at known-good locations before its first SSL call.
  Side-effecting at unit init was tempting but ParamStr(0) and
  GetEnvironmentVariable are friendlier inside a regular procedure
  invoked lazily on the first HTTPS request. }
var
  CustomDir: string;
begin
  if GSSLProbed then Exit;
  GSSLProbed := True;

  CustomDir := GetEnvironmentVariable('PASCLAW_OPENSSL_DIR');
  if CustomDir = '' then
    CustomDir := ExtractFilePath(ParamStr(0));
  if (CustomDir <> '') and DirectoryExists(CustomDir) then
    IdOpenSSLSetLibPath(CustomDir);

  GSSLAvailable := LoadOpenSSLLibrary;
end;

function OpenSSLHelpMessage: string;
begin
  Result :=
    'TLS support requires OpenSSL but the libraries could not be loaded.' + sLineBreak +
    'Indy reports: ' + WhichFailedToLoad + sLineBreak +
    {$IFDEF MSWINDOWS}
    'On Windows, place libeay32.dll and ssleay32.dll next to pasclaw.exe,' + sLineBreak +
    'or set PASCLAW_OPENSSL_DIR to a directory containing them.';
    {$ELSE}
    'On Linux/macOS, install OpenSSL (libssl + libcrypto) via your package' + sLineBreak +
    'manager, or set PASCLAW_OPENSSL_DIR to a directory containing them.';
    {$ENDIF}
end;

function EnsureOpenSSL(out ErrMsg: string): Boolean;
begin
  ProbeOpenSSL;
  Result := GSSLAvailable;
  if Result then ErrMsg := '' else ErrMsg := OpenSSLHelpMessage;
end;

function ExtractURLHost(const URL: string): string;
{ Lowercased host of a URL, stripped of scheme, userinfo, port and path.
  Handles bracketed IPv6 literals ([::1]:8000 -> ::1). }
var
  S: string;
  P: Integer;
begin
  S := URL;
  P := Pos('://', S);
  if P > 0 then S := Copy(S, P + 3, MaxInt);
  P := Pos('@', S);               { strip userinfo }
  if P > 0 then S := Copy(S, P + 1, MaxInt);
  P := Pos('/', S);               { strip path }
  if P > 0 then S := Copy(S, 1, P - 1);
  if (S <> '') and (S[1] = '[') then
  begin
    P := Pos(']', S);             { IPv6 literal -- take what's inside brackets }
    if P > 0 then S := Copy(S, 2, P - 2);
  end
  else
  begin
    P := Pos(':', S);             { strip :port }
    if P > 0 then S := Copy(S, 1, P - 1);
  end;
  Result := LowerCase(Trim(S));
end;

function HostBypassesProxy(const Host, NoProxy: string): Boolean;
{ Loopback always bypasses so local providers (ollama / lmstudio / vllm) and
  127.0.0.1 callbacks never route through an external proxy. Then honour the
  NoProxy list, matching the semantics curl / wget / Go use: '*' bypasses
  everything; an entry matches Host exactly or as a domain suffix (a leading
  '.' is optional, so both "example.com" and ".example.com" match
  "api.example.com"). }
var
  Raw, Entry: string;
  Start, i, L: Integer;
begin
  Result := True;
  if (Host = 'localhost') or (Host = '127.0.0.1') or (Host = '::1')
     or (Copy(Host, 1, 4) = '127.') then Exit;

  if NoProxy <> '' then
  begin
    Raw := LowerCase(NoProxy);
    Start := 1;
    L := Length(Raw);
    for i := 1 to L + 1 do
      if (i > L) or (Raw[i] = ',') then
      begin
        Entry := Trim(Copy(Raw, Start, i - Start));
        Start := i + 1;
        if Entry = '' then Continue;
        if Entry = '*' then Exit;
        while (Entry <> '') and (Entry[1] = '.') do Delete(Entry, 1, 1);
        if Entry = '' then Continue;
        if (Host = Entry) or
           ((Length(Host) > Length(Entry)) and
            (Copy(Host, Length(Host) - Length(Entry), Length(Entry) + 1)
             = '.' + Entry)) then Exit;
      end;
  end;
  Result := False;
end;

function EnvNoProxy: string;
begin
  Result := GetEnvironmentVariable('NO_PROXY');
  if Result = '' then Result := GetEnvironmentVariable('no_proxy');
end;

procedure ApplyEnvProxy(Http: TIdHTTP; const URL: string);
(* Route the client through an HTTP(S)_PROXY from the environment, the way
   curl / wget / git / npm / wrangler all do. Indy's TIdHTTP does NOT read
   these env vars on its own -- without this it opens a direct socket, which
   fails wherever egress is only available through a proxy (corporate
   networks, the c2w in-browser guest, sandboxed CI). For an https:// target
   Indy issues a CONNECT tunnel through the proxy, so the TLS session is still
   end-to-end to the provider.

   HTTPS_PROXY governs https targets, HTTP_PROXY governs http; NO_PROXY (and
   loopback, always) opts a host out -- see HostBypassesProxy. The proxy URL
   itself is parsed down to host[:port] (default port 80).

   No CA wiring is needed for a TLS-terminating (MITM) proxy: Indy does not
   verify the server certificate by default, so the proxy's re-signed cert is
   accepted. This generalises the former c2w-only ApplyBrowserProxy. *)
var
  Raw, Host: string;
  P, Port: Integer;
begin
  if MakeHTTPS(URL) then
  begin
    Raw := GetEnvironmentVariable('HTTPS_PROXY');
    if Raw = '' then Raw := GetEnvironmentVariable('https_proxy');
  end
  else
  begin
    Raw := GetEnvironmentVariable('HTTP_PROXY');
    if Raw = '' then Raw := GetEnvironmentVariable('http_proxy');
  end;
  if Raw = '' then Exit;
  if HostBypassesProxy(ExtractURLHost(URL), EnvNoProxy) then Exit;

  { Strip scheme://, any userinfo@, and trailing /path so only host[:port]
    remains (proxy URLs are typically a plain http://host:port). }
  P := Pos('://', Raw);
  if P > 0 then Raw := Copy(Raw, P + 3, MaxInt);
  P := Pos('/', Raw);
  if P > 0 then Raw := Copy(Raw, 1, P - 1);
  P := Pos('@', Raw);
  if P > 0 then Raw := Copy(Raw, P + 1, MaxInt);

  P := Pos(':', Raw);
  if P > 0 then
  begin
    Host := Copy(Raw, 1, P - 1);
    Port := StrToIntDef(Copy(Raw, P + 1, MaxInt), 0);
  end
  else
  begin
    Host := Raw;
    Port := 80;
  end;
  if (Host = '') or (Port <= 0) then Exit;

  Http.ProxyParams.ProxyServer := Host;
  Http.ProxyParams.ProxyPort   := Port;
end;

function NewClient(TimeoutSeconds: Integer; const URL: string;
                   out ErrMsg: string): TIdHTTP;
var
  SSL: TIdSSLIOHandlerSocketOpenSSL;
begin
  ErrMsg := '';
  Result := TIdHTTP.Create(nil);
  Result.ConnectTimeout := TimeoutSeconds * 1000;
  Result.ReadTimeout    := TimeoutSeconds * 1000;
  Result.HandleRedirects := True;
  Result.Request.UserAgent := 'PasClaw/0.1 (+https://github.com/FMXExpress/PasClaw)';
  { Honour HTTP(S)_PROXY / NO_PROXY from the environment (all builds, not just
    c2w) so pasclaw reaches providers through a proxy like every other CLI. }
  ApplyEnvProxy(Result, URL);
  if MakeHTTPS(URL) then
  begin
    if not EnsureOpenSSL(ErrMsg) then Exit;
    SSL := TIdSSLIOHandlerSocketOpenSSL.Create(Result);
    SSL.SSLOptions.Method  := sslvTLSv1_2;
    SSL.SSLOptions.SSLVersions := [sslvTLSv1_2];
    Result.IOHandler := SSL;
  end;
end;

function PostJSON(const URL, JSON: string;
                  const Headers: array of THeaderPair;
                  TimeoutSeconds: Integer): THTTPResult;
var
  Http: TIdHTTP;
  Req: TStringStream;
  SSLErr: string;
begin
  Http := NewClient(TimeoutSeconds, URL, SSLErr);
  if SSLErr <> '' then
  begin
    Result.StatusCode := -1;
    Result.Body       := '';
    Result.ErrorMsg   := SSLErr;
    Http.Free;
    Exit;
  end;
  { UTF-8 encode the request body; default codepage would corrupt non-ASCII
    JSON values (user names, system prompts, content blocks). }
  Req  := TStringStream.Create(JSON, TEncoding.UTF8);
  try
    Http.Request.ContentType    := 'application/json; charset=utf-8';
    Http.Request.Accept         := 'application/json';
    ApplyHeaders(Http, Headers);
    Result := DoRequest(Http, URL, Req, True);
  finally
    Req.Free;
    Http.Free;
  end;
end;

function PutJSON(const URL, JSON: string;
                 const Headers: array of THeaderPair;
                 TimeoutSeconds: Integer): THTTPResult;
var
  Http: TIdHTTP;
  Req, Resp: TStringStream;
  SSLErr: string;
begin
  Http := NewClient(TimeoutSeconds, URL, SSLErr);
  if SSLErr <> '' then
  begin
    Result.StatusCode := -1;
    Result.Body       := '';
    Result.ErrorMsg   := SSLErr;
    Http.Free;
    Exit;
  end;
  Req  := TStringStream.Create(JSON, TEncoding.UTF8);
  Resp := TStringStream.Create('', TEncoding.UTF8);
  try
    Http.Request.ContentType    := 'application/json; charset=utf-8';
    Http.Request.Accept         := 'application/json';
    ApplyHeaders(Http, Headers);
    Result.StatusCode := 0;
    Result.Body       := '';
    Result.ErrorMsg   := '';
    try
      Http.Put(URL, Req, Resp);
      Result.StatusCode := Http.ResponseCode;
      Result.Body       := Resp.DataString;
      TagUTF8(Result.Body);
    except
      on E: EIdHTTPProtocolException do
      begin
        Result.StatusCode := E.ErrorCode;
        Result.Body       := E.ErrorMessage;
        TagUTF8(Result.Body);
        Result.ErrorMsg   := E.Message;
      end;
      on E: Exception do
      begin
        Result.StatusCode := Http.ResponseCode;
        Result.Body       := Resp.DataString;
        TagUTF8(Result.Body);
        Result.ErrorMsg   := E.Message;
      end;
    end;
  finally
    Req.Free;
    Resp.Free;
    Http.Free;
  end;
end;

function GetJSONURL(const URL: string;
                    const Headers: array of THeaderPair;
                    TimeoutSeconds: Integer): THTTPResult;
var
  Http: TIdHTTP;
  SSLErr: string;
begin
  Http := NewClient(TimeoutSeconds, URL, SSLErr);
  if SSLErr <> '' then
  begin
    Result.StatusCode := -1;
    Result.Body       := '';
    Result.ErrorMsg   := SSLErr;
    Http.Free;
    Exit;
  end;
  try
    Http.Request.Accept := 'application/json';
    ApplyHeaders(Http, Headers);
    Result := DoRequest(Http, URL, nil, False);
  finally
    Http.Free;
  end;
end;

type
  { Bridges the public THTTPRedirectGuard signature to Indy's
    TIdHTTP.OnRedirect. One-shot helper: created per request, freed
    in the same try/finally. }
  TRedirectAdapter = class
  private
    FGuard: THTTPRedirectGuard;
  public
    constructor Create(AGuard: THTTPRedirectGuard);
    procedure OnRedirect(Sender: TObject; var Dest: string;
                          var NumRedirect: Integer;
                          var Handled: Boolean;
                          var VMethod: TIdHTTPMethod);
  end;

constructor TRedirectAdapter.Create(AGuard: THTTPRedirectGuard);
begin
  inherited Create;
  FGuard := AGuard;
end;

procedure TRedirectAdapter.OnRedirect(Sender: TObject; var Dest: string;
                                       var NumRedirect: Integer;
                                       var Handled: Boolean;
                                       var VMethod: TIdHTTPMethod);
var
  Allow: Boolean;
  Reason: string;
begin
  if not Assigned(FGuard) then Exit;
  Allow := True;
  Reason := '';
  FGuard(Dest, Allow, Reason);
  if not Allow then
    raise Exception.Create(Reason);
end;

function GetURL(const URL: string;
                const Headers: array of THeaderPair;
                TimeoutSeconds: Integer;
                const UserAgent: string;
                const Accept: string;
                OnRedirect: THTTPRedirectGuard): THTTPResult;
var
  Http: TIdHTTP;
  SSLErr: string;
  Adapter: TRedirectAdapter;
begin
  Http := NewClient(TimeoutSeconds, URL, SSLErr);
  if SSLErr <> '' then
  begin
    Result.StatusCode  := -1;
    Result.Body        := '';
    Result.ContentType := '';
    Result.ErrorMsg    := SSLErr;
    Http.Free;
    Exit;
  end;
  Adapter := nil;
  try
    if UserAgent <> '' then Http.Request.UserAgent := UserAgent;
    if Accept    <> '' then Http.Request.Accept    := Accept
    else                    Http.Request.Accept    := '*/*';
    if Assigned(OnRedirect) then
    begin
      Adapter := TRedirectAdapter.Create(OnRedirect);
      Http.OnRedirect := Adapter.OnRedirect;
    end;
    ApplyHeaders(Http, Headers);
    Result := DoRequest(Http, URL, nil, False);
  finally
    Adapter.Free;
    Http.Free;
  end;
end;

function PostRaw(const URL, ContentType, Body: string;
                 const Headers: array of THeaderPair;
                 TimeoutSeconds: Integer;
                 const UserAgent: string;
                 const Accept: string): THTTPResult;
var
  Http: TIdHTTP;
  Req: TStringStream;
  SSLErr: string;
begin
  Http := NewClient(TimeoutSeconds, URL, SSLErr);
  if SSLErr <> '' then
  begin
    Result.StatusCode  := -1;
    Result.Body        := '';
    Result.ContentType := '';
    Result.ErrorMsg    := SSLErr;
    Http.Free;
    Exit;
  end;
  Req := TStringStream.Create(Body, TEncoding.UTF8);
  try
    if UserAgent <> '' then Http.Request.UserAgent := UserAgent;
    Http.Request.ContentType     := ContentType + '; charset=utf-8';
    if Accept <> '' then Http.Request.Accept := Accept
    else                 Http.Request.Accept := '*/*';
    ApplyHeaders(Http, Headers);
    Result := DoRequest(Http, URL, Req, True);
  finally
    Req.Free;
    Http.Free;
  end;
end;

function PostJSONToStream(const URL, JSON: string;
                          RespStream: TStream;
                          const Headers: array of THeaderPair;
                          TimeoutSeconds: Integer;
                          const UserAgent: string;
                          const Accept: string;
                          out StatusCode: Integer;
                          out ErrMsg: string): Boolean;
var
  Http: TIdHTTP;
  Req: TStringStream;
  SSLErr: string;
begin
  Result := False;
  StatusCode := 0;
  ErrMsg := '';
  Http := NewClient(TimeoutSeconds, URL, SSLErr);
  if SSLErr <> '' then
  begin
    StatusCode := -1;
    ErrMsg := SSLErr;
    Http.Free;
    Exit;
  end;
  Req := TStringStream.Create(JSON, TEncoding.UTF8);
  try
    if UserAgent <> '' then Http.Request.UserAgent := UserAgent;
    Http.Request.ContentType     := 'application/json; charset=utf-8';
    if Accept <> '' then Http.Request.Accept := Accept
    else                 Http.Request.Accept := 'application/json';
    ApplyHeaders(Http, Headers);
    try
      Http.Post(URL, Req, RespStream);
      StatusCode := Http.ResponseCode;
    except
      on E: EIdHTTPProtocolException do
      begin
        StatusCode := E.ErrorCode;
        ErrMsg     := E.Message;
        { fall through -- caller may still want to parse what we got }
      end;
      on E: Exception do
      begin
        StatusCode := Http.ResponseCode;
        ErrMsg     := E.Message;
      end;
    end;
    Result := (StatusCode >= 200) and (StatusCode < 300);
  finally
    Req.Free;
    Http.Free;
  end;
end;

function GetURLToStream(const URL: string; Stream: TStream;
                        const Headers: array of THeaderPair;
                        TimeoutSeconds: Integer): THTTPResult;
var
  Http: TIdHTTP;
  SSLErr: string;
begin
  Result.StatusCode  := 0;
  Result.Body        := '';
  Result.ContentType := '';
  Result.ErrorMsg    := '';
  Http := NewClient(TimeoutSeconds, URL, SSLErr);
  if SSLErr <> '' then
  begin
    Result.StatusCode := -1;
    Result.ErrorMsg   := SSLErr;
    Http.Free;
    Exit;
  end;
  try
    Http.Request.Accept := '*/*';
    ApplyHeaders(Http, Headers);
    try
      Http.Get(URL, Stream);
      Result.StatusCode := Http.ResponseCode;
    except
      on E: EIdHTTPProtocolException do
      begin
        Result.StatusCode := E.ErrorCode;
        Result.ErrorMsg   := E.Message;
      end;
      on E: Exception do
      begin
        Result.StatusCode := Http.ResponseCode;
        Result.ErrorMsg   := E.Message;
      end;
    end;
  finally
    Http.Free;
  end;
end;

function GetURLToStreamGuarded(const URL: string;
                                RespStream: TStream;
                                const Headers: array of THeaderPair;
                                TimeoutSeconds: Integer;
                                const UserAgent: string;
                                const Accept: string;
                                OnRedirect: THTTPRedirectGuard): THTTPResult;
var
  Http: TIdHTTP;
  SSLErr: string;
  Adapter: TRedirectAdapter;
begin
  Result.StatusCode  := 0;
  Result.Body        := '';
  Result.ContentType := '';
  Result.ErrorMsg    := '';
  Http := NewClient(TimeoutSeconds, URL, SSLErr);
  if SSLErr <> '' then
  begin
    Result.StatusCode := -1;
    Result.ErrorMsg   := SSLErr;
    Http.Free;
    Exit;
  end;
  Adapter := nil;
  try
    if UserAgent <> '' then Http.Request.UserAgent := UserAgent;
    if Accept    <> '' then Http.Request.Accept    := Accept
    else                    Http.Request.Accept    := '*/*';
    if Assigned(OnRedirect) then
    begin
      Adapter := TRedirectAdapter.Create(OnRedirect);
      Http.OnRedirect := Adapter.OnRedirect;
    end;
    ApplyHeaders(Http, Headers);
    try
      Http.Get(URL, RespStream);
      Result.StatusCode  := Http.ResponseCode;
      Result.ContentType := LowerCase(Http.Response.ContentType);
      CaptureIndyHeaders(Http, Result.RespHeaders);
    except
      on E: EIdHTTPProtocolException do
      begin
        Result.StatusCode  := E.ErrorCode;
        Result.ContentType := LowerCase(Http.Response.ContentType);
        Result.ErrorMsg    := E.Message;
        CaptureIndyHeaders(Http, Result.RespHeaders);
      end;
      on E: Exception do
      begin
        Result.StatusCode  := Http.ResponseCode;
        Result.ContentType := LowerCase(Http.Response.ContentType);
        Result.ErrorMsg    := E.Message;
        CaptureIndyHeaders(Http, Result.RespHeaders);
      end;
    end;
  finally
    Adapter.Free;
    Http.Free;
  end;
end;

{$IFEND}

end.
