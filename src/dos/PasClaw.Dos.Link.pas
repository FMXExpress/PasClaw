(*
  PasClaw.Dos.Link -- the DOS client's end of the line to `pasclaw bridge`.

  On DOS (go32v2): a serial port, COM1..COM4, driven directly: a 8250 /
  16450 / 16550 UART polled through its I/O ports, 8N1, no interrupts and
  no flow control. Polling is enough: the client does nothing else while
  it waits for an answer, and a 16550's 16-byte FIFO covers the gaps at
  115200 baud. The port's address comes from the BIOS table, else the
  usual 3F8/2F8/3E8/2E8. While it waits, Esc cancels.

  On a host build (Linux, for tests and for a PC without DOS): "host:port"
  is a TCP connection -- to `pasclaw bridge --listen` directly -- and a
  /dev/... path is a serial device.
*)
unit PasClaw.Dos.Link;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Bridge.Wire;

type
  TDosLink = class(TWireReader)
  protected
    FAborted: Boolean;
  public
    function WriteBytes(const S: RawByteString): Boolean; virtual; abstract;
    function Describe: string; virtual; abstract;
    { Discard what is arriving until QuietMs pass with nothing. }
    procedure Drain(QuietMs: Integer);
    { Set when the user pressed Esc during a wait; cleared by the caller. }
    property Aborted: Boolean read FAborted write FAborted;
  end;

{ "COM1".."COM4" (DOS), "host:port" or "/dev/..." (host builds). }
function OpenLink(const Spec: string; Baud: Integer; out Link: TDosLink;
  out Err: string): Boolean;

function BaudSupported(Baud: Integer): Boolean;

implementation

{$IFDEF GO32V2}
uses
  go32;
{$ELSE}
{$IFDEF UNIX}
uses
  BaseUnix, Unix, Sockets,
  PasClaw.Bridge.Serial;
{$ENDIF}
{$ENDIF}

function BaudSupported(Baud: Integer): Boolean;
begin
  case Baud of
    300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200: Result := True;
  else
    Result := False;
  end;
end;

procedure TDosLink.Drain(QuietMs: Integer);
var
  B: Byte;
begin
  while ReadByte(B, QuietMs) do ;
  FAborted := False;
end;

{$IFDEF GO32V2}

type
  TUartLink = class(TDosLink)
  private
    FBase: Word;
    FName: string;
    FBurst: Integer;   { bytes per transmit-empty: 16 with a FIFO, else 1 }
  public
    function Init(const Name: string; Base: Word; Baud: Integer; out Err: string): Boolean;
    function ReadByte(out B: Byte; TimeoutMs: Integer): Boolean; override;
    function WriteBytes(const S: RawByteString): Boolean; override;
    function Describe: string; override;
  end;

const
  TICKS_PER_DAY = $1800B0;

{ BIOS timer ticks since midnight (18.2 a second). }
function BiosTicks: LongInt;
var
  T: LongInt;
begin
  dosmemget($40, $6C, T, 4);
  Result := T;
end;

function ElapsedMs(Start: LongInt): LongInt;
var
  Now_: LongInt;
begin
  Now_ := BiosTicks;
  if Now_ < Start then Inc(Now_, TICKS_PER_DAY);
  Result := (Now_ - Start) * 55;
end;

{ Esc waiting in the BIOS keyboard buffer? Takes the key. Other keys
  are left for the next prompt. }
function EscPressed: Boolean;
var
  R: TRealRegs;
begin
  Result := False;
  FillChar(R, SizeOf(R), 0);
  R.ax := $0100;
  realintr($16, R);
  if (R.flags and $40) <> 0 then Exit;   { ZF: no key }
  if (R.ax and $FF) <> $1B then Exit;
  R.ax := $0000;
  realintr($16, R);
  Result := True;
end;

function TUartLink.Init(const Name: string; Base: Word; Baud: Integer; out Err: string): Boolean;
var
  Divisor: Word;
begin
  Result := False;
  FName := Name;
  FBase := Base;
  { A missing port reads back all ones. }
  if inportb(FBase + 5) = $FF then
  begin
    Err := Format('no serial port at %s (I/O %xh)', [Name, Base]);
    Exit;
  end;
  Divisor := 115200 div Baud;
  outportb(FBase + 1, $00);                 { no interrupts }
  outportb(FBase + 3, $80);                 { DLAB: divisor follows }
  outportb(FBase + 0, Lo(Divisor));
  outportb(FBase + 1, Hi(Divisor));
  outportb(FBase + 3, $03);                 { 8 data bits, no parity, 1 stop }
  outportb(FBase + 2, $C7);                 { FIFO on, both cleared, 14-byte trigger }
  outportb(FBase + 4, $03);                 { DTR + RTS }
  { IIR bits 6-7 both set: a 16550A with a working FIFO. }
  if (inportb(FBase + 2) and $C0) = $C0 then FBurst := 16 else FBurst := 1;
  while (inportb(FBase + 5) and 1) <> 0 do inportb(FBase);   { stale bytes }
  Result := True;
end;

function TUartLink.ReadByte(out B: Byte; TimeoutMs: Integer): Boolean;
var
  Start: LongInt;
  k: Integer;
begin
  B := 0;
  if (inportb(FBase + 5) and 1) <> 0 then
  begin
    B := inportb(FBase);
    Exit(True);
  end;
  Start := BiosTicks;
  repeat
    for k := 1 to 4000 do
      if (inportb(FBase + 5) and 1) <> 0 then
      begin
        B := inportb(FBase);
        Exit(True);
      end;
    if (TimeoutMs > 1000) and EscPressed then
    begin
      FAborted := True;
      Exit(False);
    end;
  until ElapsedMs(Start) >= TimeoutMs;
  Result := False;
end;

function TUartLink.WriteBytes(const S: RawByteString): Boolean;
var
  i, n: Integer;
  Start: LongInt;
begin
  i := 1;
  while i <= Length(S) do
  begin
    Start := BiosTicks;
    while (inportb(FBase + 5) and $20) = 0 do   { transmit holding register empty }
      if ElapsedMs(Start) > 2000 then Exit(False);
    n := 0;
    while (n < FBurst) and (i <= Length(S)) do
    begin
      outportb(FBase, Ord(S[i]));
      Inc(i);
      Inc(n);
    end;
  end;
  Result := True;
end;

function TUartLink.Describe: string;
begin
  if FBurst > 1 then Result := FName + ' (16550)' else Result := FName;
end;

function OpenLink(const Spec: string; Baud: Integer; out Link: TDosLink;
  out Err: string): Boolean;
const
  DefaultBase: array[1..4] of Word = ($3F8, $2F8, $3E8, $2E8);
var
  N: Integer;
  Base: Word;
  U: TUartLink;
begin
  Result := False;
  Link := nil;
  Err := '';
  if not BaudSupported(Baud) then
  begin
    Err := 'unsupported speed ' + IntToStr(Baud);
    Exit;
  end;
  if (Length(Spec) <> 4) or not SameText(Copy(Spec, 1, 3), 'COM') then
  begin
    Err := 'the port is COM1, COM2, COM3 or COM4, not "' + Spec + '"';
    Exit;
  end;
  N := Ord(Spec[4]) - Ord('0');
  if (N < 1) or (N > 4) then
  begin
    Err := 'the port is COM1, COM2, COM3 or COM4, not "' + Spec + '"';
    Exit;
  end;
  { The BIOS data area lists the ports it found at boot, from 0040:0000. }
  Base := 0;
  dosmemget($40, (N - 1) * 2, Base, 2);
  if Base = 0 then Base := DefaultBase[N];
  U := TUartLink.Create;
  if not U.Init(UpperCase(Spec), Base, Baud, Err) then
  begin
    U.Free;
    Exit;
  end;
  Link := U;
  Result := True;
end;

{$ELSE}
{$IFDEF UNIX}

type
  TTcpLink = class(TDosLink)
  private
    FSock: LongInt;
    FSpec: string;
    FBuf: array[0..4095] of Byte;
    FLen, FPos: Integer;
    FClosed: Boolean;
  public
    destructor Destroy; override;
    function Connect(const Host: string; Port: Integer; out Err: string): Boolean;
    function ReadByte(out B: Byte; TimeoutMs: Integer): Boolean; override;
    function IsClosed: Boolean; override;
    function WriteBytes(const S: RawByteString): Boolean; override;
    function Describe: string; override;
  end;

  TDevLink = class(TDosLink)
  private
    FPort: TSerialPort;
    FSpec: string;
  public
    destructor Destroy; override;
    function ReadByte(out B: Byte; TimeoutMs: Integer): Boolean; override;
    function WriteBytes(const S: RawByteString): Boolean; override;
    function Describe: string; override;
  end;

destructor TTcpLink.Destroy;
begin
  if FSock >= 0 then CloseSocket(FSock);
  inherited Destroy;
end;

function TTcpLink.Connect(const Host: string; Port: Integer; out Err: string): Boolean;
var
  Addr: TInetSockAddr;
  H: string;
begin
  Result := False;
  FSpec := Host + ':' + IntToStr(Port);
  H := Host;
  if SameText(H, 'localhost') then H := '127.0.0.1';
  FSock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FSock < 0 then
  begin
    Err := 'socket() failed';
    Exit;
  end;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(Port);
  Addr.sin_addr := StrToNetAddr(H);
  if Addr.sin_addr.s_addr = 0 then
  begin
    Err := 'not an IPv4 address: ' + Host;
    Exit;
  end;
  if fpConnect(FSock, @Addr, SizeOf(Addr)) <> 0 then
  begin
    Err := 'cannot connect to ' + FSpec + ' (is `pasclaw bridge` running?)';
    Exit;
  end;
  Result := True;
end;

function TTcpLink.ReadByte(out B: Byte; TimeoutMs: Integer): Boolean;
var
  Fds: TFDSet;
  N: LongInt;
begin
  B := 0;
  Result := False;
  if FPos >= FLen then
  begin
    if FClosed then Exit;
    fpFD_ZERO(Fds);
    fpFD_SET(FSock, Fds);
    if fpSelect(FSock + 1, @Fds, nil, nil, TimeoutMs) <= 0 then Exit;
    N := fpRecv(FSock, @FBuf[0], SizeOf(FBuf), 0);
    if N <= 0 then
    begin
      FClosed := True;
      Exit;
    end;
    FLen := N;
    FPos := 0;
  end;
  B := FBuf[FPos];
  Inc(FPos);
  Result := True;
end;

function TTcpLink.IsClosed: Boolean;
begin
  Result := FClosed and (FPos >= FLen);
end;

function TTcpLink.WriteBytes(const S: RawByteString): Boolean;
var
  P, N: LongInt;
begin
  Result := False;
  P := 1;
  while P <= Length(S) do
  begin
    N := fpSend(FSock, @S[P], Length(S) - P + 1, 0);
    if N <= 0 then Exit;
    Inc(P, N);
  end;
  Result := True;
end;

function TTcpLink.Describe: string;
begin
  Result := FSpec;
end;

destructor TDevLink.Destroy;
begin
  FPort.Free;
  inherited Destroy;
end;

function TDevLink.ReadByte(out B: Byte; TimeoutMs: Integer): Boolean;
begin
  Result := FPort.ReadByte(B, TimeoutMs);
end;

function TDevLink.WriteBytes(const S: RawByteString): Boolean;
begin
  Result := FPort.WriteBytes(S);
end;

function TDevLink.Describe: string;
begin
  Result := FSpec;
end;

function OpenLink(const Spec: string; Baud: Integer; out Link: TDosLink;
  out Err: string): Boolean;
var
  P, Port: Integer;
  T: TTcpLink;
  D: TDevLink;
begin
  Result := False;
  Link := nil;
  Err := '';
  if Copy(Spec, 1, 5) = '/dev/' then
  begin
    D := TDevLink.Create;
    D.FSpec := Spec;
    D.FPort := TSerialPort.Create;
    if not D.FPort.Open(Spec, Baud, Err) then
    begin
      D.Free;
      Exit;
    end;
    Link := D;
    Exit(True);
  end;
  P := LastDelimiter(':', Spec);
  Port := StrToIntDef(Copy(Spec, P + 1, MaxInt), -1);
  if (P < 2) or (Port < 1) or (Port > 65535) then
  begin
    Err := 'on this build the port is host:port (a `pasclaw bridge --listen`) or a /dev/ ' +
           'serial device, not "' + Spec + '"';
    Exit;
  end;
  T := TTcpLink.Create;
  T.FSock := -1;
  if not T.Connect(Copy(Spec, 1, P - 1), Port, Err) then
  begin
    T.Free;
    Exit;
  end;
  Link := T;
  Result := True;
end;

{$ELSE}

function OpenLink(const Spec: string; Baud: Integer; out Link: TDosLink;
  out Err: string): Boolean;
begin
  Link := nil;
  Err := 'no link support on this platform';
  Result := False;
end;

{$ENDIF}
{$ENDIF}

end.
