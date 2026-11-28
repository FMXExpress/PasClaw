(*
  PasClaw.HTTP.FreePascalOS - outbound HTTP and HTTPS on FreePascalOS.

  FreePascalOS has no Indy socket stack and no OpenSSL. It has its own
  HTTP client, libhttp (Http.Client.THttpClient: HTTP/1.1 and HTTP/2,
  TLS 1.3 and 1.2 through libtls with certificate checks against the
  system's CA list), and this unit is PasClaw's way to it. It is what
  PasClaw.Providers.HTTP calls on FreePascalOS, so every provider, the
  SSE stream, web_fetch and the downloads go through here with the same
  API they use elsewhere.

  The response body is written to the caller's stream piece by piece as
  it arrives (libhttp's body sink), which is what keeps streamed replies
  streaming: PasClaw.Providers.Stream's parser sees each SSE line as the
  model produces it.

  As with Indy, an answer that is not 2xx does not reach the caller's
  stream: its body is kept and returned (ErrorBody) -- it is the
  provider's explanation, and the stream may be an SSE parser.

  Redirects are followed here rather than inside libhttp, so a caller's
  guard (web_fetch's SSRF check) sees every hop before it is taken.

  Trusted certificates: the system's list, or the PEM file named by
  SSL_CERT_FILE (or PASCLAW_CA_FILE) when set -- for a private CA, or a
  test server. PASCLAW_TLS_INSECURE=1 turns the checks off.

  Only `make fpos` compiles this unit (src/fpos). It is PasClaw's code
  under the MIT license; the libhttp/libtls units it uses are
  FreePascalOS's and GPLv3 -- see docs/freepascalos.md.
*)
unit PasClaw.HTTP.FreePascalOS;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes;

type
  { The same shape as PasClaw.Providers.HTTP.THTTPRedirectGuard. }
  TFposRedirectGuard = procedure(var DestURL: string;
                                 var Allow: Boolean;
                                 var Reason: string) of object;

  TFposHttpExchange = record
    { What to send. }
    Method: string;
    URL: string;
    HeaderNames: array of string;
    HeaderValues: array of string;
    HasBody: Boolean;
    Body: RawByteString;           { sent as is (UTF-8 for text) }
    ContentType: string;           { of Body }
    UserAgent: string;             { '' = PasClaw's }
    Accept: string;                { '' = */* }
    TimeoutSeconds: Integer;       { 0 = libhttp's default (60 s) }
    OnRedirect: TFposRedirectGuard;
    { What came back. }
    StatusCode: Integer;           { 0 when no answer came }
    RespContentType: string;       { lower case }
    RespNames: array of string;
    RespValues: array of string;
    ErrorMsg: string;              { '' on a 2xx answer }
    ErrorBody: RawByteString;      { the body of an answer that is not 2xx }
  end;

{ Sends X; the body of a 2xx answer goes to Sink (nil: dropped). True
  when an answer came back, whatever its status (StatusCode says);
  False with ErrorMsg when none did. }
function FposHttpExecute(var X: TFposHttpExchange; Sink: TStream): Boolean;

{ Adds a header to send. }
procedure FposAddHeader(var X: TFposHttpExchange; const Name, Value: string);

{ A fresh exchange: GET, no headers. }
function FposNewExchange(const Method, URL: string; TimeoutSeconds: Integer): TFposHttpExchange;

const
  FposDefaultUserAgent = 'PasClaw/0.1 (FreePascalOS; +https://github.com/FMXExpress/PasClaw)';
  FposMaxRedirects = 10;

implementation

uses
  Http.BodySinks,
  Http.Client,
  Http.Messages,
  Http.Observers,
  Http.RequestBodies,
  Http.Results,
  Http.SocketConnector,
  Url.Parser,
  Url.Records;

type
  { Hands the body on to the caller's stream for a 2xx answer, keeps it
    for any other (and for a redirect, which is followed and dropped). }
  TFposSink = class(THttpBodySink)
  private
    FTarget: TStream;
    FPassOn: Boolean;
    FKept: RawByteString;
  public
    constructor Create(Target: TStream);
    function Write(Data: Pointer; Count: PtrUInt): Boolean; override;
    function OnHead(Response: THttpResponse): Boolean;
  end;

constructor TFposSink.Create(Target: TStream);
begin
  inherited Create;
  FTarget := Target;
end;

function TFposSink.OnHead(Response: THttpResponse): Boolean;
begin
  FPassOn := (Response.Status >= 200) and (Response.Status < 300);
  FKept := '';
  Result := True;
end;

function TFposSink.Write(Data: Pointer; Count: PtrUInt): Boolean;
var
  Old: Integer;
begin
  Result := True;
  if Count = 0 then Exit;
  Inc(FWritten, Count);
  if FPassOn then
  begin
    if FTarget <> nil then
      try
        FTarget.WriteBuffer(Data^, Count);
      except
        on E: Exception do
        begin
          FErrorText := E.Message;
          Result := False;
        end;
      end;
  end
  else if Length(FKept) < 1024 * 1024 then
  begin
    Old := Length(FKept);
    SetLength(FKept, Old + Integer(Count));
    Move(Data^, FKept[Old + 1], Count);
  end;
end;

procedure FposAddHeader(var X: TFposHttpExchange; const Name, Value: string);
var
  N: Integer;
begin
  N := Length(X.HeaderNames);
  SetLength(X.HeaderNames, N + 1);
  SetLength(X.HeaderValues, N + 1);
  X.HeaderNames[N] := Name;
  X.HeaderValues[N] := Value;
end;

function FposNewExchange(const Method, URL: string; TimeoutSeconds: Integer): TFposHttpExchange;
begin
  Result := Default(TFposHttpExchange);
  Result.Method := Method;
  Result.URL := URL;
  Result.TimeoutSeconds := TimeoutSeconds;
end;

function EnvFlag(const Name: string): Boolean;
var
  V: string;
begin
  V := LowerCase(Trim(GetEnvironmentVariable(Name)));
  Result := (V = '1') or (V = 'true') or (V = 'yes');
end;

function ClientSettings(const X: TFposHttpExchange): THttpClientSettings;
var
  CAFile: string;
begin
  Result := DefaultClientSettings;
  if X.UserAgent <> '' then
    Result.UserAgent := X.UserAgent
  else
    Result.UserAgent := FposDefaultUserAgent;
  if X.TimeoutSeconds > 0 then
    Result.TimeoutMilliseconds := Int64(X.TimeoutSeconds) * 1000;
  { One answer at a time; HTTP/3 would need libquic, which is not linked. }
  Result.AllowHttp3 := False;
  { Redirects are followed by FposHttpExecute, hop by hop. }
  Result.MaximumRedirects := 0;
  CAFile := GetEnvironmentVariable('PASCLAW_CA_FILE');
  if CAFile = '' then CAFile := GetEnvironmentVariable('SSL_CERT_FILE');
  if CAFile <> '' then
  begin
    Result.HasTrustFile := True;
    Result.TrustFile := CAFile;
  end;
  if EnvFlag('PASCLAW_TLS_INSECURE') then
    Result.VerifyCertificates := False;
end;

function ResultText(const R: THttpResult): string;
begin
  Result := R.Text;
  if Result = '' then
    case R.Code of
      HttpLookupFailed:      Result := 'host not found';
      HttpConnectFailed:     Result := 'could not connect';
      HttpTimedOut:          Result := 'timed out';
      HttpTlsFailed:         Result := 'TLS handshake failed';
      HttpCertificateFailed: Result := 'server certificate not trusted';
      HttpUnsupportedScheme: Result := 'unsupported URL scheme';
    else
      Result := 'HTTP request failed';
    end;
end;

function OriginOf(const U: TUrlRecord): string;
begin
  Result := LowerCase(U.Scheme) + '://' + LowerCase(SerializeHost(U.Host)) + ':' +
            IntToStr(UrlEffectivePort(U));
end;

{ Credentials a redirect to another origin must not carry along. }
function IsCredentialHeader(const Name: string): Boolean;
var
  N: string;
begin
  N := LowerCase(Name);
  Result := (N = 'authorization') or (N = 'proxy-authorization') or (N = 'cookie') or
            (N = 'x-api-key') or (N = 'api-key') or (N = 'x-goog-api-key');
end;

function IsRedirect(Status: Integer): Boolean;
begin
  Result := (Status = 301) or (Status = 302) or (Status = 303) or
            (Status = 307) or (Status = 308);
end;

function FposHttpExecute(var X: TFposHttpExchange; Sink: TStream): Boolean;
var
  Client: THttpClient;
  Request: THttpRequest;
  Response: THttpResponse;
  BodySink: TFposSink;
  R: THttpResult;
  CurrentURL, Method, Location, Reason: string;
  Base, Next: TUrlRecord;
  Hops, i: Integer;
  SendBody, Allow, DropCredentials: Boolean;
  FirstOrigin: string;
begin
  Result := False;
  X.StatusCode := 0;
  X.RespContentType := '';
  X.ErrorMsg := '';
  X.ErrorBody := '';
  SetLength(X.RespNames, 0);
  SetLength(X.RespValues, 0);
  CurrentURL := X.URL;
  Method := UpperCase(X.Method);
  if Method = '' then Method := 'GET';
  SendBody := X.HasBody;
  DropCredentials := False;
  FirstOrigin := '';
  Client := CreateSystemClient(ClientSettings(X));
  try
    Hops := 0;
    while True do
    begin
      if not THttpRequest.FromText(Method, CurrentURL, Request) then
      begin
        X.ErrorMsg := 'not a URL: ' + CurrentURL;
        Exit;
      end;
      Response := nil;
      BodySink := TFposSink.Create(Sink);
      try
        Request.RedirectMode := RedirectManual;
        Request.CacheMode := CacheModeNoStore;
        Request.CredentialsMode := CredentialsOmit;
        if FirstOrigin = '' then
          FirstOrigin := OriginOf(Request.Url)
        else
          DropCredentials := OriginOf(Request.Url) <> FirstOrigin;
        for i := 0 to High(X.HeaderNames) do
          if not (DropCredentials and IsCredentialHeader(X.HeaderNames[i])) then
            Request.Headers.Add(X.HeaderNames[i], X.HeaderValues[i]);
        if not Request.Headers.Has('accept') then
        begin
          if X.Accept <> '' then
            Request.Headers.Add('accept', X.Accept)
          else
            Request.Headers.Add('accept', '*/*');
        end;
        if SendBody then
        begin
          if (X.ContentType <> '') and not Request.Headers.Has('content-type') then
            Request.Headers.Add('content-type', X.ContentType);
          Request.SetBody(THttpBytesBody.Create(BytesOf(X.Body), X.ContentType));
        end;
        R := Client.Fetch(Request, BodySink, Response, BodySink.OnHead);
        if (Response = nil) or ((Response.Status = 0) and not HttpSucceeded(R)) then
        begin
          X.ErrorMsg := ResultText(R);
          Exit;
        end;
        X.StatusCode := Response.Status;
        X.RespContentType := LowerCase(Response.Headers.Value('content-type'));
        SetLength(X.RespNames, Response.Headers.Count);
        SetLength(X.RespValues, Response.Headers.Count);
        for i := 0 to Response.Headers.Count - 1 do
        begin
          X.RespNames[i] := Response.Headers[i].Name;
          X.RespValues[i] := Response.Headers[i].Value;
        end;
        Location := Response.Headers.Value('location');
        Base := Response.Url;
        if not HttpSucceeded(R) then
        begin
          { An answer came, its body did not arrive whole. }
          X.ErrorMsg := ResultText(R);
          X.ErrorBody := BodySink.FKept;
          Result := True;
          Exit;
        end;
        if IsRedirect(X.StatusCode) and (Location <> '') then
        begin
          Inc(Hops);
          if Hops > FposMaxRedirects then
          begin
            X.ErrorMsg := 'too many redirects';
            Exit;
          end;
          if not ParseUrl(Location, Base, Next) then
          begin
            X.ErrorMsg := 'bad redirect location: ' + Location;
            Exit;
          end;
          CurrentURL := SerializeUrl(Next);
          if Assigned(X.OnRedirect) then
          begin
            Allow := True;
            Reason := '';
            X.OnRedirect(CurrentURL, Allow, Reason);
            if not Allow then
            begin
              if Reason = '' then Reason := 'redirect refused';
              X.ErrorMsg := Reason;
              Exit;
            end;
          end;
          { 303, and 301/302 after a POST, become a GET without a body
            (as browsers and Indy do); 307 and 308 keep both. }
          if (X.StatusCode = 303) or
             (((X.StatusCode = 301) or (X.StatusCode = 302)) and (Method = 'POST')) then
          begin
            Method := 'GET';
            SendBody := False;
          end;
          Continue;
        end;
        if (X.StatusCode < 200) or (X.StatusCode >= 300) then
        begin
          X.ErrorBody := BodySink.FKept;
          X.ErrorMsg := Format('HTTP/1.1 %d %s', [X.StatusCode, Response.Reason]);
        end;
        Result := True;
        Exit;
      finally
        Response.Free;
        BodySink.Free;
        Request.Free;
      end;
    end;
  finally
    Client.Free;
  end;
end;

end.
