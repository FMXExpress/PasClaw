(*
  PasClaw.Bridge.Serial -- a serial port as a wire stream, for
  `pasclaw bridge --serial`: the modern end of a null-modem cable to a
  DOS PC (a USB-serial adapter is fine).

  8N1, no flow control, raw. Unix (FPC): /dev/ttyS0, /dev/ttyUSB0, ...
  through termios. Windows (FPC and Delphi): COM1, COM10, ... through
  the comm API. Elsewhere Open fails with a message saying so.

  ReadByte returns as soon as one byte is there and waits at most
  TimeoutMs for it; bytes are read in blocks into a buffer, so a reader
  pulling one byte at a time makes one system call per block, not per
  byte.
*)
unit PasClaw.Bridge.Serial;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  {$IFDEF MSWINDOWS}{$IFDEF FPC}Windows,{$ELSE}Winapi.Windows,{$ENDIF}{$ENDIF}
  {$IFDEF UNIX}{$IFDEF FPC}BaseUnix, Unix, TermIO,{$ENDIF}{$ENDIF}
  PasClaw.Bridge.Wire;

type
  TSerialPort = class(TWireReader)
  private
    {$IFDEF MSWINDOWS}
    FHandle: THandle;
    FLastTimeout: Integer;
    {$ELSE}
    FHandle: Integer;
    {$ENDIF}
    FOpen: Boolean;
    FBuf: array[0..4095] of Byte;
    FLen, FPos: Integer;
    function Fill(TimeoutMs: Integer): Boolean;
  public
    destructor Destroy; override;
    { Dev: "/dev/ttyUSB0" or "COM1". Baud: 300 .. 115200. }
    function Open(const Dev: string; Baud: Integer; out Err: string): Boolean;
    procedure Close;
    function ReadByte(out B: Byte; TimeoutMs: Integer): Boolean; override;
    function WriteBytes(const S: RawByteString): Boolean;
    { Discard whatever is waiting: what arrives within QuietMs of the
      last byte, then stop. }
    procedure Drain(QuietMs: Integer);
    property IsOpen: Boolean read FOpen;
  end;

{ The speeds both ends can be set to. }
function SerialBaudSupported(Baud: Integer): Boolean;

implementation

function SerialBaudSupported(Baud: Integer): Boolean;
begin
  case Baud of
    300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200: Result := True;
  else
    Result := False;
  end;
end;

destructor TSerialPort.Destroy;
begin
  Close;
  inherited Destroy;
end;

{$IFDEF MSWINDOWS}

function TSerialPort.Open(const Dev: string; Baud: Integer; out Err: string): Boolean;
var
  Name: string;
  Dcb: TDCB;
begin
  Result := False;
  Err := '';
  Close;
  if not SerialBaudSupported(Baud) then
  begin
    Err := 'unsupported speed ' + IntToStr(Baud);
    Exit;
  end;
  { COM10 and up need the device namespace; COM1..9 accept it too. }
  Name := Dev;
  if Copy(Name, 1, 4) <> '\\.\' then Name := '\\.\' + Name;
  FHandle := CreateFile(PChar(Name), GENERIC_READ or GENERIC_WRITE, 0, nil,
                        OPEN_EXISTING, 0, 0);
  if FHandle = INVALID_HANDLE_VALUE then
  begin
    Err := 'cannot open ' + Dev + ': ' + SysErrorMessage(GetLastError);
    Exit;
  end;
  FillChar(Dcb, SizeOf(Dcb), 0);
  Dcb.DCBlength := SizeOf(Dcb);
  if not GetCommState(FHandle, Dcb) then
  begin
    Err := 'cannot read the settings of ' + Dev + ': ' + SysErrorMessage(GetLastError);
    CloseHandle(FHandle);
    Exit;
  end;
  Dcb.BaudRate := Baud;
  Dcb.ByteSize := 8;
  Dcb.Parity := NOPARITY;
  Dcb.StopBits := ONESTOPBIT;
  { fBinary on; no parity check, no CTS/DSR flow, DTR and RTS held on,
    no XON/XOFF. Bit layout per the DCB documentation. }
  Dcb.Flags := $0001 or ($0001 shl 4) or ($0001 shl 12);
  if not SetCommState(FHandle, Dcb) then
  begin
    Err := 'cannot set ' + Dev + ' to ' + IntToStr(Baud) + ' 8N1: ' + SysErrorMessage(GetLastError);
    CloseHandle(FHandle);
    Exit;
  end;
  PurgeComm(FHandle, PURGE_RXCLEAR or PURGE_TXCLEAR);
  FLastTimeout := -1;
  FLen := 0;
  FPos := 0;
  FOpen := True;
  Result := True;
end;

procedure TSerialPort.Close;
begin
  if FOpen then CloseHandle(FHandle);
  FOpen := False;
end;

function TSerialPort.Fill(TimeoutMs: Integer): Boolean;
var
  T: TCommTimeouts;
  Got: DWORD;
begin
  Result := False;
  if not FOpen then Exit;
  if TimeoutMs < 1 then TimeoutMs := 1;
  if TimeoutMs <> FLastTimeout then
  begin
    { MAXDWORD / MAXDWORD / N: return at once with what is buffered, else
      wait up to N ms for the first byte and return with it. }
    T.ReadIntervalTimeout := MAXDWORD;
    T.ReadTotalTimeoutMultiplier := MAXDWORD;
    T.ReadTotalTimeoutConstant := TimeoutMs;
    T.WriteTotalTimeoutMultiplier := 0;
    T.WriteTotalTimeoutConstant := 0;
    SetCommTimeouts(FHandle, T);
    FLastTimeout := TimeoutMs;
  end;
  Got := 0;
  if not ReadFile(FHandle, FBuf[0], SizeOf(FBuf), Got, nil) then Exit;
  FLen := Got;
  FPos := 0;
  Result := Got > 0;
end;

function TSerialPort.WriteBytes(const S: RawByteString): Boolean;
var
  N: DWORD;
  P: Integer;
begin
  Result := False;
  if not FOpen then Exit;
  P := 1;
  while P <= Length(S) do
  begin
    N := 0;
    if not WriteFile(FHandle, S[P], Length(S) - P + 1, N, nil) then Exit;
    if N = 0 then Exit;
    Inc(P, Integer(N));
  end;
  Result := True;
end;

{$ELSE}
{$IFDEF UNIX}{$IFDEF FPC}

function BaudConst(Baud: Integer): Cardinal;
begin
  case Baud of
    300: Result := B300;
    1200: Result := B1200;
    2400: Result := B2400;
    4800: Result := B4800;
    9600: Result := B9600;
    19200: Result := B19200;
    38400: Result := B38400;
    57600: Result := B57600;
  else
    Result := B115200;
  end;
end;

function TSerialPort.Open(const Dev: string; Baud: Integer; out Err: string): Boolean;
var
  T: termios;
begin
  Result := False;
  Err := '';
  Close;
  if not SerialBaudSupported(Baud) then
  begin
    Err := 'unsupported speed ' + IntToStr(Baud);
    Exit;
  end;
  FHandle := FpOpen(Dev, O_RDWR or O_NOCTTY or O_NONBLOCK);
  if FHandle < 0 then
  begin
    Err := 'cannot open ' + Dev + ': ' + SysErrorMessage(fpgeterrno);
    Exit;
  end;
  if TCGetAttr(FHandle, T) <> 0 then
  begin
    Err := Dev + ' is not a serial port (tcgetattr failed)';
    FpClose(FHandle);
    Exit;
  end;
  { Raw 8N1, receiver on, modem lines ignored, no flow control. }
  CFMakeRaw(T);
  T.c_cflag := (T.c_cflag and not (CSIZE or PARENB or CSTOPB or CRTSCTS)) or
               CS8 or CREAD or CLOCAL;
  T.c_iflag := T.c_iflag and not (IXON or IXOFF or IXANY);
  T.c_cc[VMIN] := 0;
  T.c_cc[VTIME] := 0;
  CFSetISpeed(T, BaudConst(Baud));
  CFSetOSpeed(T, BaudConst(Baud));
  if TCSetAttr(FHandle, TCSANOW, T) <> 0 then
  begin
    Err := 'cannot set ' + Dev + ' to ' + IntToStr(Baud) + ' 8N1';
    FpClose(FHandle);
    Exit;
  end;
  TCFlush(FHandle, TCIOFLUSH);
  FLen := 0;
  FPos := 0;
  FOpen := True;
  Result := True;
end;

procedure TSerialPort.Close;
begin
  if FOpen then FpClose(FHandle);
  FOpen := False;
end;

function TSerialPort.Fill(TimeoutMs: Integer): Boolean;
var
  Fds: TFDSet;
  N: TSsize;
begin
  Result := False;
  if not FOpen then Exit;
  fpFD_ZERO(Fds);
  fpFD_SET(FHandle, Fds);
  if fpSelect(FHandle + 1, @Fds, nil, nil, TimeoutMs) <= 0 then Exit;
  N := FpRead(FHandle, FBuf[0], SizeOf(FBuf));
  if N <= 0 then Exit;
  FLen := N;
  FPos := 0;
  Result := True;
end;

function TSerialPort.WriteBytes(const S: RawByteString): Boolean;
var
  P: Integer;
  N: TSsize;
  Fds: TFDSet;
begin
  Result := False;
  if not FOpen then Exit;
  P := 1;
  while P <= Length(S) do
  begin
    N := FpWrite(FHandle, S[P], Length(S) - P + 1);
    if N > 0 then
    begin
      Inc(P, N);
      Continue;
    end;
    if fpgeterrno <> ESysEAGAIN then Exit;
    { The output queue is full: wait until it drains a little. }
    fpFD_ZERO(Fds);
    fpFD_SET(FHandle, Fds);
    if fpSelect(FHandle + 1, nil, @Fds, nil, 5000) <= 0 then Exit;
  end;
  Result := True;
end;

{$ELSE}

function TSerialPort.Open(const Dev: string; Baud: Integer; out Err: string): Boolean;
begin
  Err := 'serial ports are not supported in this build; use --listen and ' +
         'a serial-to-TCP tool (socat, ser2net)';
  Result := False;
end;

procedure TSerialPort.Close;
begin
  FOpen := False;
end;

function TSerialPort.Fill(TimeoutMs: Integer): Boolean;
begin
  Result := False;
end;

function TSerialPort.WriteBytes(const S: RawByteString): Boolean;
begin
  Result := False;
end;

{$ENDIF}{$ELSE}

function TSerialPort.Open(const Dev: string; Baud: Integer; out Err: string): Boolean;
begin
  Err := 'serial ports are not supported on this platform; use --listen';
  Result := False;
end;

procedure TSerialPort.Close;
begin
  FOpen := False;
end;

function TSerialPort.Fill(TimeoutMs: Integer): Boolean;
begin
  Result := False;
end;

function TSerialPort.WriteBytes(const S: RawByteString): Boolean;
begin
  Result := False;
end;

{$ENDIF}
{$ENDIF}

function TSerialPort.ReadByte(out B: Byte; TimeoutMs: Integer): Boolean;
begin
  B := 0;
  if (FPos >= FLen) and not Fill(TimeoutMs) then Exit(False);
  B := FBuf[FPos];
  Inc(FPos);
  Result := True;
end;

procedure TSerialPort.Drain(QuietMs: Integer);
var
  B: Byte;
begin
  FPos := FLen;
  while ReadByte(B, QuietMs) do
    FPos := FLen;
end;

end.
