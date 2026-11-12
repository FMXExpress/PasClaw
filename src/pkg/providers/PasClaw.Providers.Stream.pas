(*
  PasClaw.Providers.Stream - Server-Sent Events over a streaming POST,
  shared by the OpenAI-compatible and Anthropic streaming endpoints.

  SSE framing:
    data: <chunk>\n
    data: <chunk>\n
    \n               <- blank line ends an event
    event: <name>\n  <- optional, present in Anthropic stream
    ...

  The HTTP POST is delegated to PasClaw.Providers.HTTP.PostJSONToStream.
  Both of its backends (Indy, and System.Net on Delphi) write the response
  body into the stream they are given as it arrives off the socket -- a
  chunk at a time for a chunked response, a buffer at a time otherwise.
  TSSEParseStream is that stream: its Write splits lines and fires each
  event the moment its blank line lands, so a caller sees tokens as the
  model produces them, not after the whole reply. Every bit of parse
  state lives in the stream object, one per request, so concurrent
  streams (several sessions, several threads) never share any.
*)
unit PasClaw.Providers.Stream;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.HTTP;

type
  TSSECallback = procedure(const Event, Data: string) of object;

  (* A write-only stream that parses SSE as bytes are written to it.
     OnEvent fires for each complete event (its `event:` name, if any, and
     its `data:` lines joined with #10). Finish flushes a last event that
     had no closing blank line. Raw keeps the first RawCap bytes verbatim:
     an error response, or a server that ignored `stream: true` and sent
     one JSON body, is not SSE, and the caller reads it from there. *)
  TSSEParseStream = class(TStream)
  private
    FOnEvent: TSSECallback;
    FBuf: TBytes;          { bytes of a line not yet ended by #10 }
    FBufLen: Integer;
    FEventName, FData: string;
    FHasData: Boolean;
    FRaw: TBytes;
    FRawLen: Integer;
    FWritten: Int64;
    FEvents: Integer;
    procedure Line(const S: string);
    procedure Dispatch_;
  public
    RawCap: Integer;
    constructor Create(OnEvent: TSSECallback);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    procedure Finish;
    function Raw: string;
    property Events: Integer read FEvents;
  end;

(* POST JSON asking for text/event-stream and call OnEvent per event as it
   arrives. Raw is the start of the body as received (see TSSEParseStream)
   and ErrMsg the transport's or the server's error text. *)
function PostSSE(const URL, JSON: string;
                 const Headers: array of THeaderPair;
                 TimeoutSeconds: Integer;
                 OnEvent: TSSECallback;
                 out StatusCode: Integer;
                 out ErrMsg, Raw: string;
                 out Events: Integer): Boolean;

implementation

const
  DefaultRawCap = 64 * 1024;

function BytesToText(const B: TBytes; Start, Len: Integer): string;
begin
  if Len <= 0 then Exit('');
  {$IFDEF FPC}
  SetLength(Result, Len);
  Move(B[Start], Result[1], Len);
  {$ELSE}
  Result := TEncoding.UTF8.GetString(B, Start, Len);
  {$ENDIF}
end;

constructor TSSEParseStream.Create(OnEvent: TSSECallback);
begin
  inherited Create;
  FOnEvent := OnEvent;
  RawCap := DefaultRawCap;
end;

function TSSEParseStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;   { write-only }
end;

function TSSEParseStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  { Writers ask where they are (or rewind an empty stream); the answer is
    always "at the end of what was written". }
  Result := FWritten;
end;

procedure TSSEParseStream.Dispatch_;
begin
  if (FEventName <> '') or FHasData then
  begin
    Inc(FEvents);
    if Assigned(FOnEvent) then FOnEvent(FEventName, FData);
  end;
  FEventName := '';
  FData := '';
  FHasData := False;
end;

procedure TSSEParseStream.Line(const S: string);
var
  L: string;
begin
  L := S;
  if (L <> '') and (L[Length(L)] = #13) then SetLength(L, Length(L) - 1);
  if L = '' then
  begin
    Dispatch_;
    Exit;
  end;
  if Copy(L, 1, 6) = 'event:' then
    FEventName := Trim(Copy(L, 7, MaxInt))
  else if Copy(L, 1, 5) = 'data:' then
  begin
    if FHasData then FData := FData + #10;
    FData := FData + Trim(Copy(L, 6, MaxInt));
    FHasData := True;
  end;
  { Comments (':') and unknown fields are ignored, as SSE says. }
end;

function TSSEParseStream.Write(const Buffer; Count: Longint): Longint;
var
  P: PByte;
  i, Start, Keep: Integer;
begin
  Result := Count;
  if Count <= 0 then Exit;
  P := @Buffer;
  Inc(FWritten, Count);
  if FRawLen < RawCap then
  begin
    Keep := Count;
    if FRawLen + Keep > RawCap then Keep := RawCap - FRawLen;
    SetLength(FRaw, FRawLen + Keep);
    Move(P^, FRaw[FRawLen], Keep);
    Inc(FRawLen, Keep);
  end;
  { Append, then cut every complete line. #10 never occurs inside a UTF-8
    sequence, so a character split across writes stays whole in FBuf. }
  if FBufLen + Count > Length(FBuf) then
    SetLength(FBuf, (FBufLen + Count) * 2);
  Move(P^, FBuf[FBufLen], Count);
  Inc(FBufLen, Count);
  Start := 0;
  for i := 0 to FBufLen - 1 do
    if FBuf[i] = 10 then
    begin
      Line(BytesToText(FBuf, Start, i - Start));
      Start := i + 1;
    end;
  if Start > 0 then
  begin
    if Start < FBufLen then Move(FBuf[Start], FBuf[0], FBufLen - Start);
    Dec(FBufLen, Start);
  end;
end;

procedure TSSEParseStream.Finish;
begin
  if FBufLen > 0 then
  begin
    Line(BytesToText(FBuf, 0, FBufLen));
    FBufLen := 0;
  end;
  Dispatch_;
end;

function TSSEParseStream.Raw: string;
begin
  Result := BytesToText(FRaw, 0, FRawLen);
end;

function PostSSE(const URL, JSON: string;
                 const Headers: array of THeaderPair;
                 TimeoutSeconds: Integer;
                 OnEvent: TSSECallback;
                 out StatusCode: Integer;
                 out ErrMsg, Raw: string;
                 out Events: Integer): Boolean;
var
  S: TSSEParseStream;
begin
  S := TSSEParseStream.Create(OnEvent);
  try
    PostJSONToStream(URL, JSON, S, Headers, TimeoutSeconds,
                     'PasClaw/0.1', 'text/event-stream', StatusCode, ErrMsg);
    S.Finish;
    Raw := S.Raw;
    Events := S.Events;
    Result := (StatusCode >= 200) and (StatusCode < 300);
  finally
    S.Free;
  end;
end;

end.
