(*
  PasClaw.Bridge.Wire -- HTTP/1.1 on a plain byte stream, for the DOS
  client (src/dos) and `pasclaw bridge`.

  A DOS PC has no TLS and no TCP/IP here: it reaches the gateway over a
  serial line -- a null-modem cable to a modern machine, or an emulator
  that connects COM1 to a TCP port. Both ends speak ordinary HTTP/1.1 on
  that stream: one request, its response, the next request. Messages are
  framed by Content-Length alone, so opening or closing the stream means
  nothing and chunked encoding is never used.

  A serial line has no checksum. Every body carries X-PasClaw-CRC32 (the
  IEEE CRC-32 of the body bytes, 8 hex digits), and a reader refuses a
  body that does not match it. A request reader skips anything before a
  line that starts with a method, so it finds the next request again
  after line noise or a half-sent message.

  Portable: FPC (go32v2, Linux, Windows) and Delphi. Bodies are raw bytes
  (RawByteString; UTF-8 in practice). The head is ASCII.
*)
unit PasClaw.Bridge.Wire;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

const
  WIRE_CRC_HEADER = 'X-PasClaw-CRC32';
  { The client numbers its requests; the bridge echoes the number on the
    answer, so a client that resent a request after a timeout can tell the
    answer to the first try from the answer to the second. }
  WIRE_SEQ_HEADER = 'X-PasClaw-Seq';
  { A model request with a long history is tens of KB; a tool result is
    capped well below this. Bigger is a desync, not a message. }
  WIRE_MAX_BODY   = 4 * 1024 * 1024;
  WIRE_MAX_LINE   = 8192;

type
  TWireHeader = record
    Name, Value: string;
  end;
  TWireHeaders = array of TWireHeader;

  { One request (Method, Path) or one response (Status, Reason). }
  TWireMessage = record
    Method, Path: string;
    Status: Integer;
    Reason: string;
    Headers: TWireHeaders;
    Body: RawByteString;
  end;

  { A byte source with a timeout: False when no byte came within
    TimeoutMs, or the source is closed. }
  TWireReader = class
  public
    function ReadByte(out B: Byte; TimeoutMs: Integer): Boolean; virtual; abstract;
    { True once the source has ended for good (a socket the peer closed).
      A serial line never ends: silence on it is only silence. }
    function IsClosed: Boolean; virtual;
  end;

  { Bytes held in memory -- tests, and parsing a buffer. }
  TWireStringReader = class(TWireReader)
  private
    FData: RawByteString;
    FPos: Integer;
  public
    constructor Create(const Data: RawByteString);
    function ReadByte(out B: Byte; TimeoutMs: Integer): Boolean; override;
    function IsClosed: Boolean; override;
  end;

function Crc32(const S: RawByteString): Cardinal;
function Crc32Hex(const S: RawByteString): string;

function WireHeader(const M: TWireMessage; const Name: string): string;
procedure WireSetHeader(var M: TWireMessage; const Name, Value: string);

{ Serialise. Content-Length and the CRC header are set from the body,
  replacing any given. }
function FormatWireRequest(const M: TWireMessage): RawByteString;
function FormatWireResponse(const M: TWireMessage): RawByteString;

(* Read one message. FirstByteTimeoutMs: how long to wait for it to start
   (a model call can take minutes); ByteTimeoutMs: the longest gap once it
   has. False with Err:
     'idle'       nothing arrived within FirstByteTimeoutMs
     'crc: ...'   the body does not match its CRC header
     anything else: a timeout part-way, a malformed head, a body over
                  WIRE_MAX_BODY.
   A request is found by skipping anything before a line that starts with
   a method; a response must start with "HTTP/". A message without the
   CRC header is accepted (curl, socat): only a header that is present
   and wrong refuses it. *)
function ReadWireRequest(R: TWireReader; out M: TWireMessage;
  FirstByteTimeoutMs, ByteTimeoutMs: Integer; out Err: string): Boolean;
function ReadWireResponse(R: TWireReader; out M: TWireMessage;
  FirstByteTimeoutMs, ByteTimeoutMs: Integer; out Err: string): Boolean;

{ Body bytes <-> string. FPC strings are already UTF-8 bytes; Delphi's
  are UTF-16 and are converted. }
function WireBodyToString(const B: RawByteString): string;
function StringToWireBody(const S: string): RawByteString;

implementation

var
  CrcTable: array[0..255] of Cardinal;

procedure InitCrcTable;
var
  i, k: Integer;
  C: Cardinal;
begin
  for i := 0 to 255 do
  begin
    C := Cardinal(i);
    for k := 0 to 7 do
      if (C and 1) <> 0 then C := $EDB88320 xor (C shr 1)
      else C := C shr 1;
    CrcTable[i] := C;
  end;
end;

function Crc32(const S: RawByteString): Cardinal;
var
  i: Integer;
begin
  Result := $FFFFFFFF;
  for i := 1 to Length(S) do
    Result := CrcTable[(Result xor Ord(S[i])) and $FF] xor (Result shr 8);
  Result := Result xor $FFFFFFFF;
end;

function Crc32Hex(const S: RawByteString): string;
begin
  Result := LowerCase(IntToHex(Crc32(S), 8));
end;

function TWireReader.IsClosed: Boolean;
begin
  Result := False;
end;

function TWireStringReader.IsClosed: Boolean;
begin
  Result := FPos >= Length(FData);
end;

constructor TWireStringReader.Create(const Data: RawByteString);
begin
  inherited Create;
  FData := Data;
  FPos := 0;
end;

function TWireStringReader.ReadByte(out B: Byte; TimeoutMs: Integer): Boolean;
begin
  Result := FPos < Length(FData);
  if Result then
  begin
    Inc(FPos);
    B := Ord(FData[FPos]);
  end
  else
    B := 0;
end;

function WireHeader(const M: TWireMessage; const Name: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(M.Headers) do
    if SameText(M.Headers[i].Name, Name) then Exit(M.Headers[i].Value);
end;

procedure WireSetHeader(var M: TWireMessage; const Name, Value: string);
var
  i: Integer;
begin
  for i := 0 to High(M.Headers) do
    if SameText(M.Headers[i].Name, Name) then
    begin
      M.Headers[i].Value := Value;
      Exit;
    end;
  SetLength(M.Headers, Length(M.Headers) + 1);
  M.Headers[High(M.Headers)].Name := Name;
  M.Headers[High(M.Headers)].Value := Value;
end;

{ ASCII text -> bytes, one per character. The head is ASCII; anything
  else is replaced, never widened, so a header cannot change the framing. }
function AsciiBytes(const S: string): RawByteString;
var
  i, C: Integer;
begin
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do
  begin
    C := Ord(S[i]);
    if C > 126 then C := Ord('?');
    Result[i] := AnsiChar(C);
  end;
end;

function BytesToAscii(const B: RawByteString): string;
var
  i: Integer;
begin
  SetLength(Result, Length(B));
  for i := 1 to Length(B) do
    Result[i] := Char(Ord(B[i]));
end;

function Concat2(const A, B: RawByteString): RawByteString;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then Move(A[1], Result[1], Length(A));
  if Length(B) > 0 then Move(B[1], Result[Length(A) + 1], Length(B));
end;

function FormatHead(const FirstLine: string; const M: TWireMessage): string;
var
  i: Integer;
begin
  Result := FirstLine + #13#10;
  for i := 0 to High(M.Headers) do
  begin
    if SameText(M.Headers[i].Name, 'Content-Length') or
       SameText(M.Headers[i].Name, WIRE_CRC_HEADER) or
       SameText(M.Headers[i].Name, 'Transfer-Encoding') then Continue;
    Result := Result + M.Headers[i].Name + ': ' + M.Headers[i].Value + #13#10;
  end;
  Result := Result + 'Content-Length: ' + IntToStr(Length(M.Body)) + #13#10 +
            WIRE_CRC_HEADER + ': ' + Crc32Hex(M.Body) + #13#10 + #13#10;
end;

function FormatWireRequest(const M: TWireMessage): RawByteString;
begin
  Result := Concat2(AsciiBytes(FormatHead(M.Method + ' ' + M.Path + ' HTTP/1.1', M)), M.Body);
end;

function FormatWireResponse(const M: TWireMessage): RawByteString;
var
  Reason: string;
begin
  Reason := M.Reason;
  if Reason = '' then
    case M.Status of
      200: Reason := 'OK';
      400: Reason := 'Bad Request';
      403: Reason := 'Forbidden';
      502: Reason := 'Bad Gateway';
    else
      Reason := 'Status';
    end;
  Result := Concat2(AsciiBytes(FormatHead('HTTP/1.1 ' + IntToStr(M.Status) + ' ' + Reason, M)), M.Body);
end;

{ One line, without its CR LF. False on a timeout or an over-long line;
  Started says whether any byte arrived (so a caller can tell idle from
  cut off). }
function ReadLine(R: TWireReader; out Line: string; TimeoutMs: Integer;
  out Started: Boolean): Boolean;
var
  B: Byte;
  Buf: RawByteString;
  N: Integer;
begin
  Line := '';
  Started := False;
  SetLength(Buf, 128);
  N := 0;
  while True do
  begin
    if not R.ReadByte(B, TimeoutMs) then Exit(False);
    Started := True;
    if B = 10 then Break;
    if B = 13 then Continue;
    if N >= WIRE_MAX_LINE then Exit(False);
    if N = Length(Buf) then SetLength(Buf, N * 2);
    Inc(N);
    Buf[N] := AnsiChar(B);
  end;
  SetLength(Buf, N);
  Line := BytesToAscii(Buf);
  Result := True;
end;

function IsMethod(const S: string): Boolean;
begin
  Result := (S = 'GET') or (S = 'POST') or (S = 'PUT') or (S = 'DELETE') or
            (S = 'HEAD') or (S = 'OPTIONS') or (S = 'PATCH');
end;

{ Headers up to the blank line, then the body by Content-Length, then
  the CRC check. }
function ReadRest(R: TWireReader; var M: TWireMessage; ByteTimeoutMs: Integer;
  out Err: string): Boolean;
var
  Line, Name, Value, Want: string;
  P, Len, i: Integer;
  Started: Boolean;
  B: Byte;
begin
  Result := False;
  while True do
  begin
    if not ReadLine(R, Line, ByteTimeoutMs, Started) then
    begin
      Err := 'the header was cut off';
      Exit;
    end;
    if Line = '' then Break;
    P := Pos(':', Line);
    if P < 2 then Continue;
    Name := Trim(Copy(Line, 1, P - 1));
    Value := Trim(Copy(Line, P + 1, MaxInt));
    SetLength(M.Headers, Length(M.Headers) + 1);
    M.Headers[High(M.Headers)].Name := Name;
    M.Headers[High(M.Headers)].Value := Value;
  end;
  if SameText(WireHeader(M, 'Transfer-Encoding'), 'chunked') then
  begin
    Err := 'chunked bodies are not used on this link; send Content-Length';
    Exit;
  end;
  Len := StrToIntDef(WireHeader(M, 'Content-Length'), 0);
  if (Len < 0) or (Len > WIRE_MAX_BODY) then
  begin
    Err := 'Content-Length ' + IntToStr(Len) + ' is out of range';
    Exit;
  end;
  SetLength(M.Body, Len);
  for i := 1 to Len do
  begin
    if not R.ReadByte(B, ByteTimeoutMs) then
    begin
      Err := 'the body was cut off at ' + IntToStr(i - 1) + ' of ' + IntToStr(Len) + ' bytes';
      Exit;
    end;
    M.Body[i] := AnsiChar(B);
  end;
  Want := WireHeader(M, WIRE_CRC_HEADER);
  if (Want <> '') and not SameText(Want, Crc32Hex(M.Body)) then
  begin
    Err := 'crc: the body does not match its ' + WIRE_CRC_HEADER + ' (line noise?)';
    Exit;
  end;
  Result := True;
end;

procedure ClearMessage(out M: TWireMessage);
begin
  M.Method := '';
  M.Path := '';
  M.Status := 0;
  M.Reason := '';
  SetLength(M.Headers, 0);
  M.Body := '';
end;

function ReadWireRequest(R: TWireReader; out M: TWireMessage;
  FirstByteTimeoutMs, ByteTimeoutMs: Integer; out Err: string): Boolean;
var
  Line, Meth, Rest: string;
  Started, Any: Boolean;
  P, Skipped: Integer;
begin
  ClearMessage(M);
  Err := '';
  Result := False;
  Any := False;
  Skipped := 0;
  { Skip to a request line: blank lines between messages, and noise. }
  while True do
  begin
    if Any then
    begin
      if not ReadLine(R, Line, ByteTimeoutMs, Started) then
      begin
        Err := 'the request line was cut off';
        Exit;
      end;
    end
    else if not ReadLine(R, Line, FirstByteTimeoutMs, Started) then
    begin
      if Started then Err := 'the request line was cut off' else Err := 'idle';
      Exit;
    end;
    Any := True;
    P := Pos(' ', Line);
    if P > 0 then
    begin
      Meth := Copy(Line, 1, P - 1);
      if IsMethod(Meth) then Break;
    end;
    Inc(Skipped, Length(Line) + 1);
    if Skipped > WIRE_MAX_BODY then
    begin
      Err := 'no request line found';
      Exit;
    end;
  end;
  Rest := Copy(Line, P + 1, MaxInt);
  P := Pos(' ', Rest);
  if P > 0 then Rest := Copy(Rest, 1, P - 1);
  M.Method := Meth;
  M.Path := Rest;
  Result := ReadRest(R, M, ByteTimeoutMs, Err);
end;

function ReadWireResponse(R: TWireReader; out M: TWireMessage;
  FirstByteTimeoutMs, ByteTimeoutMs: Integer; out Err: string): Boolean;
var
  Line, Rest: string;
  Started: Boolean;
  P: Integer;
begin
  ClearMessage(M);
  Err := '';
  Result := False;
  repeat
    if not ReadLine(R, Line, FirstByteTimeoutMs, Started) then
    begin
      if Started then Err := 'the status line was cut off' else Err := 'idle';
      Exit;
    end;
  until Line <> '';
  if Copy(Line, 1, 5) <> 'HTTP/' then
  begin
    Err := 'not an HTTP response: ' + Copy(Line, 1, 60);
    Exit;
  end;
  P := Pos(' ', Line);
  Rest := Copy(Line, P + 1, MaxInt);
  M.Status := StrToIntDef(Copy(Rest, 1, 3), 0);
  M.Reason := Trim(Copy(Rest, 4, MaxInt));
  Result := ReadRest(R, M, ByteTimeoutMs, Err);
end;

function WireBodyToString(const B: RawByteString): string;
begin
  {$IFDEF FPC}
  SetLength(Result, Length(B));
  if Length(B) > 0 then Move(B[1], Result[1], Length(B));
  {$ELSE}
  Result := UTF8ToString(B);
  {$ENDIF}
end;

function StringToWireBody(const S: string): RawByteString;
begin
  {$IFDEF FPC}
  SetLength(Result, Length(S));
  if Length(S) > 0 then Move(S[1], Result[1], Length(S));
  {$ELSE}
  Result := UTF8Encode(S);
  {$ENDIF}
end;

initialization
  InitCrcTable;

end.
