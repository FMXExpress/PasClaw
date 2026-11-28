{
  This file is part of the Indy (Internet Direct) project, and is offered
  under the dual-licensing agreement described on the Indy website.
  (http://www.indyproject.org/)

  Copyright:
   (c) 1993-2005, Chad Z. Hower and the Indy Pit Crew. All rights reserved.
}
{
  IdStackFreePascalOS - Indy's socket stack for FreePascalOS
  (https://github.com/xeons/FreePascalOS), written for PasClaw after
  IdStackUnix.pas (IndySockets/Indy 65007abe) and laid out like it.

  FreePascalOS defines FREEPASCALOS and neither UNIX nor WINDOWS, so none
  of Indy's stacks fits it. This one is a TIdStackBSDBase over the
  system's own BSD-style sockets (libsystem's Sys.Sockets: a socket is an
  Int64 handle, calls return ErrorNone or minus an error code) and its
  name lookup (Sys.HostNames). The differences from a Unix stack:

  - errors come back from each call, not through errno: the last one is
    kept per thread for WSGetLastError. FreePascalOS's error codes are
    Linux's errno numbers, as are the Id_WSAE* constants of the
    FreePascalOS branch of IdStackConsts;
  - options are FreePascalOS's own (SocketOption*), translated from the
    (level, name) pairs Indy passes;
  - readiness: one socket waits with WaitForSocket; several with
    WaitForHandles (a socket is signaled when readable), and the ones
    that are ready are then found by asking each without waiting;
  - addresses are TAbiSocketAddress records, ports in host byte order.

  It registers itself with SetStackClass() and GSocketListClass when it
  is initialized; IdStack's FreePascalOS branch names it so that it is
  linked into every program that uses Indy.

  Part of PasClaw's FreePascalOS port: only `make fpos` compiles it
  (src/fpos/indy is on no other build's unit path).
}
unit IdStackFreePascalOS;

interface

{$I IdCompilerDefines.inc}

{$IFNDEF FREEPASCALOS}
  {$Message Fatal 'IdStackFreePascalOS is only for FreePascalOS.'}
{$ENDIF}

uses
  Classes,
  IdStack,
  IdStackConsts,
  IdGlobal,
  IdStackBSDBase;

type
  TIdFposSocketHandles = array of TIdStackSocketHandle;

  TIdSocketListFreePascalOS = class(TIdSocketList)
  protected
    FHandles: TIdFposSocketHandles;
    FCount: Integer;
    function GetItem(AIndex: Integer): TIdStackSocketHandle; override;
    function Snapshot: TIdFposSocketHandles;
    procedure SetHandles(const AHandles: TIdFposSocketHandles);
  public
    procedure Add(AHandle: TIdStackSocketHandle); override;
    procedure Remove(AHandle: TIdStackSocketHandle); override;
    function Count: Integer; override;
    procedure Clear; override;
    function Clone: TIdSocketList; override;
    function ContainsSocket(AHandle: TIdStackSocketHandle): Boolean; override;
    class function Select(AReadList: TIdSocketList; AWriteList: TIdSocketList;
      AExceptList: TIdSocketList; const ATimeout: Integer = IdTimeoutInfinite): Boolean; override;
    function SelectRead(const ATimeout: Integer = IdTimeoutInfinite): Boolean; override;
    function SelectReadList(var VSocketList: TIdSocketList;
      const ATimeout: Integer = IdTimeoutInfinite): Boolean; override;
  end;

  TIdStackFreePascalOS = class(TIdStackBSDBase)
  protected
    function HostByName(const AHostName: string;
      const AIPVersion: TIdIPVersion = ID_DEFAULT_IP_VERSION): string; override;
    function ReadHostName: string; override;
    function WSCloseSocket(ASocket: TIdStackSocketHandle): Integer; override;
    function WSRecv(ASocket: TIdStackSocketHandle; var ABuffer;
      const ABufferLength, AFlags: Integer): Integer; override;
    function WSSend(ASocket: TIdStackSocketHandle; const ABuffer;
      const ABufferLength, AFlags: Integer): Integer; override;
    function WSShutdown(ASocket: TIdStackSocketHandle; AHow: Integer): Integer; override;
    procedure WSGetSocketOption(ASocket: TIdStackSocketHandle; ALevel: TIdSocketOptionLevel;
      AOptName: TIdSocketOption; var AOptVal; var AOptLen: Integer); override;
    procedure WSSetSocketOption(ASocket: TIdStackSocketHandle; ALevel: TIdSocketOptionLevel;
      AOptName: TIdSocketOption; const AOptVal; const AOptLen: Integer); override;
  public
    procedure SetBlocking(ASocket: TIdStackSocketHandle; const ABlocking: Boolean); override;
    function WouldBlock(const AResult: Integer): Boolean; override;
    function Accept(ASocket: TIdStackSocketHandle; var VIP: string; var VPort: TIdPort;
      var VIPVersion: TIdIPVersion): TIdStackSocketHandle; override;
    procedure Bind(ASocket: TIdStackSocketHandle; const AIP: string;
      const APort: TIdPort; const AIPVersion: TIdIPVersion = ID_DEFAULT_IP_VERSION); override;
    procedure Connect(const ASocket: TIdStackSocketHandle; const AIP: string;
      const APort: TIdPort; const AIPVersion: TIdIPVersion = ID_DEFAULT_IP_VERSION); override;
    function HostByAddress(const AAddress: string;
      const AIPVersion: TIdIPVersion = ID_DEFAULT_IP_VERSION): string; override;
    function WSGetLastError: Integer; override;
    procedure WSSetLastError(const AErr: Integer); override;
    function WSGetServByName(const AServiceName: string): TIdPort; override;
    procedure AddServByPortToList(const APortNumber: TIdPort; AAddresses: TStrings); override;
    procedure GetPeerName(ASocket: TIdStackSocketHandle; var VIP: string;
      var VPort: TIdPort; var VIPVersion: TIdIPVersion); override;
    procedure GetSocketName(ASocket: TIdStackSocketHandle; var VIP: string;
      var VPort: TIdPort; var VIPVersion: TIdIPVersion); override;
    procedure Listen(ASocket: TIdStackSocketHandle; ABackLog: Integer); override;
    function HostToNetwork(AValue: UInt16): UInt16; override;
    function NetworkToHost(AValue: UInt16): UInt16; override;
    function HostToNetwork(AValue: UInt32): UInt32; override;
    function NetworkToHost(AValue: UInt32): UInt32; override;
    function HostToNetwork(AValue: TIdUInt64): TIdUInt64; override;
    function NetworkToHost(AValue: TIdUInt64): TIdUInt64; override;
    function RecvFrom(const ASocket: TIdStackSocketHandle; var VBuffer;
      const ALength, AFlags: Integer; var VIP: string; var VPort: TIdPort;
      var VIPVersion: TIdIPVersion): Integer; override;
    function ReceiveMsg(ASocket: TIdStackSocketHandle;
      var VBuffer: TIdBytes; APkt: TIdPacketInfo): UInt32; override;
    procedure WSSendTo(ASocket: TIdStackSocketHandle; const ABuffer;
      const ABufferLength, AFlags: Integer; const AIP: string; const APort: TIdPort;
      AIPVersion: TIdIPVersion = ID_DEFAULT_IP_VERSION); override;
    function WSSocket(AFamily, AStruct, AProtocol: Integer;
      const ANonBlocking: Boolean = False): TIdStackSocketHandle; override;
    procedure Disconnect(ASocket: TIdStackSocketHandle); override;
    procedure SetKeepAliveValues(ASocket: TIdStackSocketHandle;
      const AEnabled: Boolean; const ATimeMS, AInterval: Integer); override;
    function SupportsIPv4: Boolean; override;
    function SupportsIPv6: Boolean; override;
    function CheckIPVersionSupport(const AIPVersion: TIdIPVersion): Boolean; override;
    procedure WriteChecksum(s: TIdStackSocketHandle; var VBuffer: TIdBytes;
      const AOffset: Integer; const AIP: String; const APort: TIdPort;
      const AIPVersion: TIdIPVersion = ID_DEFAULT_IP_VERSION); override;
    function IOControl(const s: TIdStackSocketHandle; const cmd: UInt32;
      var arg: UInt32): Integer; override;
    procedure GetLocalAddressList(AAddresses: TIdStackLocalAddressList); override;
  end;

  EIdResolveError = class(EIdSocketError);
  EIdReverseResolveError = class(EIdSocketError);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Sockets,
  Sys.Objects,
  Sys.InternetAddresses,
  Sys.HostNames,
  Sys.Information,
  Sys.NetworkInterfaces,
  IdException,
  IdResourceStrings;

const
  { The flag of recv() Indy could pass (Linux's MSG_PEEK). }
  BSD_MSG_PEEK = $02;
  { IPV6_V6ONLY, which Indy has no constant for. }
  BSD_IPV6_V6ONLY = 26;

threadvar
  { The error of the last call that failed in this thread: what errno is
    on Unix. }
  GLastError: Integer;

{ A system call result: when negative (minus an error code) the error is
  kept for WSGetLastError and Id_SOCKET_ERROR is returned, else the
  result itself. }
function Checked(const AResult: Int64): Integer;
begin
  if AResult < 0 then begin
    GLastError := Integer(-AResult);
    Result := Id_SOCKET_ERROR;
  end else begin
    Result := Integer(AResult);
  end;
end;

{ An error code (ErrorNone or a positive code) as a BSD result: 0, or
  Id_SOCKET_ERROR with the error kept. }
function CheckedCode(const ACode: LongInt): Integer;
begin
  if ACode <> ErrorNone then begin
    GLastError := ACode;
    Result := Id_SOCKET_ERROR;
  end else begin
    Result := 0;
  end;
end;

{ Indy's timeouts (IdTimeoutInfinite, IdTimeoutDefault, milliseconds) as
  the system's (InfiniteWait or milliseconds). }
function WaitTime(const ATimeout: Integer): Int64;
begin
  if ATimeout < 0 then begin
    Result := InfiniteWait;
  end else begin
    Result := ATimeout;
  end;
end;

function FamilyOf(const AIPVersion: TIdIPVersion): Word;
begin
  if AIPVersion = Id_IPv6 then begin
    Result := AddressFamilyIPv6;
  end else begin
    Result := AddressFamilyIPv4;
  end;
end;

{ ---------------------------------------------------------------------- }
{ TIdStackFreePascalOS                                                    }
{ ---------------------------------------------------------------------- }

{ The socket address of AIP (empty: any address) and APort. False (and
  the error kept) when AIP is not an address of AIPVersion. }
function MakeAddress(const AIP: string; const APort: TIdPort;
  const AIPVersion: TIdIPVersion; out VAddr: TAbiSocketAddress): Boolean;
var
  LHost: TInternetAddress;
begin
  if AIP = '' then begin
    if AIPVersion = Id_IPv6 then begin
      LHost := AnyIpv6Address;
    end else begin
      LHost := AnyIpv4Address;
    end;
  end else if not TextToAddress(AIP, LHost) then begin
    GLastError := Id_WSAEINVAL;
    Result := False;
    Exit;
  end;
  if LHost.Family <> FamilyOf(AIPVersion) then begin
    GLastError := Id_WSAEAFNOSUPPORT;
    Result := False;
    Exit;
  end;
  VAddr := MakeSocketAddress(LHost, APort);
  Result := True;
end;

{ The IP, port and IP version of a socket address; False for a family
  Indy does not know. }
function ReadAddress(const AAddr: TAbiSocketAddress; var VIP: string;
  var VPort: TIdPort; var VIPVersion: TIdIPVersion): Boolean;
begin
  Result := True;
  case AAddr.Family of
    AddressFamilyIPv4: VIPVersion := Id_IPv4;
    AddressFamilyIPv6: VIPVersion := Id_IPv6;
  else
    Result := False;
    Exit;
  end;
  VIP := AddressToText(SocketAddressHost(AAddr));
  VPort := AAddr.Port;
end;

function TIdStackFreePascalOS.WSGetLastError: Integer;
begin
  Result := GLastError;
  // as IdStackUnix does for EPIPE: writing to a connection the peer closed
  if Result = ErrorBrokenPipe then begin
    Result := Id_WSAECONNRESET;
  end;
end;

procedure TIdStackFreePascalOS.WSSetLastError(const AErr: Integer);
begin
  GLastError := AErr;
end;

function TIdStackFreePascalOS.WSSocket(AFamily, AStruct, AProtocol: Integer;
  const ANonBlocking: Boolean = False): TIdStackSocketHandle;
var
  LFamily, LKind: LongWord;
  LHandle: Int64;
begin
  Result := Id_INVALID_SOCKET;
  case AFamily of
    Id_PF_INET4: LFamily := AddressFamilyIPv4;
    Id_PF_INET6: LFamily := AddressFamilyIPv6;
  else
    GLastError := Id_WSAEAFNOSUPPORT;
    Exit;
  end;
  case AStruct of
    SOCK_STREAM: LKind := SocketKindStream;
    SOCK_DGRAM: LKind := SocketKindDatagram;
    SOCK_RAW: LKind := SocketKindRaw;
  else
    GLastError := Id_WSAESOCKTNOSUPPORT;
    Exit;
  end;
  if ANonBlocking then begin
    LKind := LKind or SocketKindNonBlocking;
  end;
  // the protocol numbers are the IANA ones on both sides (0: the kind's usual)
  LHandle := CreateSocket(LFamily, LKind, LongWord(AProtocol));
  if LHandle < 0 then begin
    GLastError := Integer(-LHandle);
  end else begin
    Result := LHandle;
  end;
end;

function TIdStackFreePascalOS.WSCloseSocket(ASocket: TIdStackSocketHandle): Integer;
begin
  Result := CheckedCode(Sys.Sockets.CloseSocket(ASocket));
end;

procedure TIdStackFreePascalOS.Bind(ASocket: TIdStackSocketHandle; const AIP: string;
  const APort: TIdPort; const AIPVersion: TIdIPVersion = ID_DEFAULT_IP_VERSION);
var
  LAddr: TAbiSocketAddress;
begin
  if not (AIPVersion in [Id_IPv4, Id_IPv6]) then begin
    IPVersionUnsupported;
  end;
  if not MakeAddress(AIP, APort, AIPVersion, LAddr) then begin
    RaiseLastSocketError;
  end;
  CheckForSocketError(CheckedCode(BindSocket(ASocket, LAddr)));
end;

procedure TIdStackFreePascalOS.Listen(ASocket: TIdStackSocketHandle; ABackLog: Integer);
begin
  // FreePascalOS takes 1 to MaximumListenBacklog (Indy's default is 15)
  if ABackLog < 1 then begin
    ABackLog := 1;
  end else if ABackLog > MaximumListenBacklog then begin
    ABackLog := MaximumListenBacklog;
  end;
  CheckForSocketError(CheckedCode(ListenOnSocket(ASocket, LongWord(ABackLog))));
end;

function TIdStackFreePascalOS.Accept(ASocket: TIdStackSocketHandle;
  var VIP: string; var VPort: TIdPort; var VIPVersion: TIdIPVersion): TIdStackSocketHandle;
var
  LPeer: TAbiSocketAddress;
  LHandle: Int64;
begin
  LHandle := AcceptOnSocket(ASocket, LPeer);
  if LHandle < 0 then begin
    GLastError := Integer(-LHandle);
    // as IdStackUnix: a listener closed under us reads as an interrupted call
    if GLastError = ErrorBadHandle then begin
      GLastError := Id_WSAEINTR;
    end;
    Result := Id_INVALID_SOCKET;
    Exit;
  end;
  Result := LHandle;
  if not ReadAddress(LPeer, VIP, VPort, VIPVersion) then begin
    Sys.Sockets.CloseSocket(Result);
    Result := Id_INVALID_SOCKET;
    IPVersionUnsupported;
  end;
end;

procedure TIdStackFreePascalOS.Connect(const ASocket: TIdStackSocketHandle;
  const AIP: string; const APort: TIdPort;
  const AIPVersion: TIdIPVersion = ID_DEFAULT_IP_VERSION);
var
  LAddr: TAbiSocketAddress;
begin
  if not (AIPVersion in [Id_IPv4, Id_IPv6]) then begin
    IPVersionUnsupported;
  end;
  if (AIP = '') or not MakeAddress(AIP, APort, AIPVersion, LAddr) then begin
    GLastError := Id_WSAEINVAL;
    RaiseLastSocketError;
  end;
  CheckForSocketError(CheckedCode(ConnectSocket(ASocket, LAddr)));
end;

function TIdStackFreePascalOS.WSRecv(ASocket: TIdStackSocketHandle; var ABuffer;
  const ABufferLength, AFlags: Integer): Integer;
var
  LFlags: LongWord;
begin
  LFlags := 0;
  if (AFlags and BSD_MSG_PEEK) <> 0 then begin
    LFlags := SocketFlagPeek;
  end;
  Result := Checked(ReceiveOnSocket(ASocket, @ABuffer, QWord(ABufferLength), LFlags));
end;

function TIdStackFreePascalOS.WSSend(ASocket: TIdStackSocketHandle;
  const ABuffer; const ABufferLength, AFlags: Integer): Integer;
begin
  Result := CheckForSocketError(Checked(SendOnSocket(ASocket, @ABuffer, QWord(ABufferLength), 0)));
end;

function TIdStackFreePascalOS.RecvFrom(const ASocket: TIdStackSocketHandle;
  var VBuffer; const ALength, AFlags: Integer; var VIP: string;
  var VPort: TIdPort; var VIPVersion: TIdIPVersion): Integer;
var
  LFrom: TAbiSocketAddress;
  LFlags: LongWord;
begin
  LFlags := 0;
  if (AFlags and BSD_MSG_PEEK) <> 0 then begin
    LFlags := SocketFlagPeek;
  end;
  Result := Checked(ReceiveSocketFrom(ASocket, @VBuffer, QWord(ALength), LFlags, LFrom));
  if Result >= 0 then begin
    ReadAddress(LFrom, VIP, VPort, VIPVersion);
  end;
end;

function TIdStackFreePascalOS.ReceiveMsg(ASocket: TIdStackSocketHandle;
  var VBuffer: TIdBytes; APkt: TIdPacketInfo): UInt32;
var
  LIP: string;
  LPort: TIdPort;
  LIPVersion: TIdIPVersion;
  LDestIP: string;
  LDestPort: TIdPort;
  LDestIPVersion: TIdIPVersion;
  LTTL: Int64;
begin
  // FreePascalOS has no recvmsg(): the sender comes from recvfrom(), where
  // it arrived from the socket's own address, the time to live from
  // SocketOptionReceivedTimeToLive
  APkt.Reset;
  LIP := '';
  LPort := 0;
  LIPVersion := Id_IPv4;
  Result := UInt32(CheckForSocketError(RecvFrom(ASocket, VBuffer[0], Length(VBuffer), 0,
    LIP, LPort, LIPVersion)));
  APkt.SourceIP := LIP;
  APkt.SourcePort := LPort;
  APkt.SourceIPVersion := LIPVersion;
  try
    GetSocketName(ASocket, LDestIP, LDestPort, LDestIPVersion);
    APkt.DestIP := LDestIP;
    APkt.DestPort := LDestPort;
    APkt.DestIPVersion := LDestIPVersion;
  except
    // not known
  end;
  if Sys.Sockets.GetSocketOption(ASocket, SocketOptionReceivedTimeToLive, LTTL) = ErrorNone then begin
    APkt.TTL := Byte(LTTL);
  end;
end;

procedure TIdStackFreePascalOS.WSSendTo(ASocket: TIdStackSocketHandle;
  const ABuffer; const ABufferLength, AFlags: Integer; const AIP: string;
  const APort: TIdPort; AIPVersion: TIdIPVersion = ID_DEFAULT_IP_VERSION);
var
  LAddr: TAbiSocketAddress;
  LBytesOut: Integer;
begin
  if not (AIPVersion in [Id_IPv4, Id_IPv6]) then begin
    IPVersionUnsupported;
  end;
  if not MakeAddress(AIP, APort, AIPVersion, LAddr) then begin
    RaiseLastSocketError;
  end;
  LBytesOut := Checked(SendSocketTo(ASocket, @ABuffer, QWord(ABufferLength), 0, LAddr));
  if LBytesOut = Id_SOCKET_ERROR then begin
    if WSGetLastError() = Id_WSAEMSGSIZE then begin
      raise EIdPackageSizeTooBig.Create(RSPackageSizeTooBig);
    end else begin
      RaiseLastSocketError;
    end;
  end else if LBytesOut <> ABufferLength then begin
    raise EIdNotAllBytesSent.Create(RSNotAllBytesSent);
  end;
end;

function TIdStackFreePascalOS.WSShutdown(ASocket: TIdStackSocketHandle; AHow: Integer): Integer;
var
  LHow: LongWord;
begin
  case AHow of
    Id_SD_Recv: LHow := SocketShutdownReceive;
    Id_SD_Send: LHow := SocketShutdownSend;
  else
    LHow := SocketShutdownBoth;
  end;
  Result := CheckedCode(ShutdownSocket(ASocket, LHow));
end;

procedure TIdStackFreePascalOS.Disconnect(ASocket: TIdStackSocketHandle);
begin
  // as on Unix: shut both directions, then close (the kernel ends the TCP
  // connection gracefully once the last handle is closed)
  WSShutdown(ASocket, Id_SD_Both);
  WSCloseSocket(ASocket);
end;

{ The FreePascalOS option for Indy's (level, name), or -1 when it has
  none. }
function SystemOption(const ALevel: TIdSocketOptionLevel; const AOptName: TIdSocketOption): Integer;
begin
  Result := -1;
  case ALevel of
    Id_SOL_SOCKET:
      case AOptName of
        Id_SO_REUSEADDR: Result := SocketOptionReuseAddress;
        Id_SO_KEEPALIVE: Result := SocketOptionKeepAlive;
        Id_SO_BROADCAST: Result := SocketOptionBroadcast;
        Id_SO_RCVBUF:    Result := SocketOptionReceiveBuffer;
        Id_SO_SNDBUF:    Result := SocketOptionSendBuffer;
        Id_SO_ERROR:     Result := SocketOptionError;
        Id_SO_TYPE:      Result := SocketOptionKind;
        Id_SO_RCVTIMEO:  Result := SocketOptionReceiveTimeout;
        Id_SO_SNDTIMEO:  Result := SocketOptionSendTimeout;
      end;
    Id_SOL_TCP:
      case AOptName of
        Id_TCP_NODELAY: Result := SocketOptionNoDelay;
        TCP_KEEPIDLE:   Result := SocketOptionKeepIdle;
        TCP_KEEPINTVL:  Result := SocketOptionKeepInterval;
      end;
    Id_SOL_IP:
      case AOptName of
        Id_SO_IP_TTL:         Result := SocketOptionTimeToLive;
        Id_IP_MULTICAST_TTL:  Result := SocketOptionMulticastHops;
        Id_IP_MULTICAST_LOOP: Result := SocketOptionMulticastLoop;
      end;
    Id_SOL_IPv6:
      case AOptName of
        Id_IPV6_UNICAST_HOPS:   Result := SocketOptionTimeToLive;
        Id_IPV6_MULTICAST_HOPS: Result := SocketOptionMulticastHops;
        Id_IPV6_MULTICAST_LOOP: Result := SocketOptionMulticastLoop;
        BSD_IPV6_V6ONLY:        Result := SocketOptionIpv6Only;
      end;
  end;
end;

procedure TIdStackFreePascalOS.WSGetSocketOption(ASocket: TIdStackSocketHandle;
  ALevel: TIdSocketOptionLevel; AOptName: TIdSocketOption; var AOptVal;
  var AOptLen: Integer);
var
  LOption: Integer;
  LValue: Int64;
begin
  LOption := SystemOption(ALevel, AOptName);
  if (LOption < 0) or (AOptLen < SizeOf(Integer)) then begin
    GLastError := iif(LOption < 0, Id_WSAENOPROTOOPT, Id_WSAEINVAL);
    RaiseLastSocketError;
  end;
  CheckForSocketError(CheckedCode(Sys.Sockets.GetSocketOption(ASocket, LongWord(LOption), LValue)));
  if LOption = SocketOptionKind then begin
    // SO_TYPE: the kind, without the non-blocking flag
    LValue := LValue and not Int64(SocketKindNonBlocking);
  end;
  Integer(AOptVal) := Integer(LValue);
  AOptLen := SizeOf(Integer);
end;

procedure TIdStackFreePascalOS.WSSetSocketOption(ASocket: TIdStackSocketHandle;
  ALevel: TIdSocketOptionLevel; AOptName: TIdSocketOption; const AOptVal;
  const AOptLen: Integer);
var
  LOption: Integer;
  LJoin: Boolean;
begin
  // multicast groups: Indy passes an ip_mreq / ipv6_mreq
  if ((ALevel = Id_SOL_IP) and ((AOptName = Id_IP_ADD_MEMBERSHIP) or (AOptName = Id_IP_DROP_MEMBERSHIP))) then begin
    LJoin := AOptName = Id_IP_ADD_MEMBERSHIP;
    CheckForSocketError(CheckedCode(ChangeMulticastMembership(ASocket, LJoin, AddressFamilyIPv4,
      @TIdIPMreq(AOptVal).IMRMultiAddr.S_un_b.s_b1, 0)));
    Exit;
  end;
  if ((ALevel = Id_SOL_IPv6) and ((AOptName = Id_IPV6_ADD_MEMBERSHIP) or (AOptName = Id_IPV6_DROP_MEMBERSHIP))) then begin
    LJoin := AOptName = Id_IPV6_ADD_MEMBERSHIP;
    CheckForSocketError(CheckedCode(ChangeMulticastMembership(ASocket, LJoin, AddressFamilyIPv6,
      @TIdIPv6Mreq(AOptVal).ipv6mr_multiaddr.s6_addr[0], TIdIPv6Mreq(AOptVal).ipv6mr_interface)));
    Exit;
  end;
  // SO_LINGER: FreePascalOS always closes gracefully; nothing to set
  if (ALevel = Id_SOL_SOCKET) and (AOptName = Id_SO_LINGER) then begin
    Exit;
  end;
  LOption := SystemOption(ALevel, AOptName);
  if (LOption < 0) or (AOptLen < SizeOf(Integer)) or (LOption = SocketOptionError) or
    (LOption = SocketOptionKind) then begin
    GLastError := iif(AOptLen < SizeOf(Integer), Id_WSAEINVAL, Id_WSAENOPROTOOPT);
    RaiseLastSocketError;
  end;
  CheckForSocketError(CheckedCode(Sys.Sockets.SetSocketOption(ASocket, LongWord(LOption),
    Int64(Integer(AOptVal)))));
end;

procedure TIdStackFreePascalOS.SetKeepAliveValues(ASocket: TIdStackSocketHandle;
  const AEnabled: Boolean; const ATimeMS, AInterval: Integer);
begin
  inherited; // SO_KEEPALIVE on or off
  if AEnabled then begin
    // seconds, at least one
    if ATimeMS > 0 then begin
      SetSocketOption(ASocket, Id_SOL_TCP, TCP_KEEPIDLE, IndyMax(1, ATimeMS div MSecsPerSec));
    end;
    if AInterval > 0 then begin
      SetSocketOption(ASocket, Id_SOL_TCP, TCP_KEEPINTVL, IndyMax(1, AInterval div MSecsPerSec));
    end;
  end;
end;

procedure TIdStackFreePascalOS.SetBlocking(ASocket: TIdStackSocketHandle;
  const ABlocking: Boolean);
begin
  CheckForSocketError(CheckedCode(Sys.Sockets.SetSocketOption(ASocket,
    SocketOptionNonBlocking, Ord(not ABlocking))));
end;

function TIdStackFreePascalOS.WouldBlock(const AResult: Integer): Boolean;
begin
  Result := (AResult = Id_WSAEWOULDBLOCK) or (AResult = Id_WSAEINPROGRESS);
end;

procedure TIdStackFreePascalOS.GetPeerName(ASocket: TIdStackSocketHandle;
  var VIP: string; var VPort: TIdPort; var VIPVersion: TIdIPVersion);
var
  LAddr: TAbiSocketAddress;
begin
  CheckForSocketError(CheckedCode(GetPeerSocketAddress(ASocket, LAddr)));
  if not ReadAddress(LAddr, VIP, VPort, VIPVersion) then begin
    IPVersionUnsupported;
  end;
end;

procedure TIdStackFreePascalOS.GetSocketName(ASocket: TIdStackSocketHandle;
  var VIP: string; var VPort: TIdPort; var VIPVersion: TIdIPVersion);
var
  LAddr: TAbiSocketAddress;
begin
  CheckForSocketError(CheckedCode(GetLocalSocketAddress(ASocket, LAddr)));
  if not ReadAddress(LAddr, VIP, VPort, VIPVersion) then begin
    IPVersionUnsupported;
  end;
end;

function TIdStackFreePascalOS.HostByName(const AHostName: string;
  const AIPVersion: TIdIPVersion = ID_DEFAULT_IP_VERSION): string;
var
  LFound: THostAddresses;
  LError: LongInt;
  LFamilies: LongWord;
  i: Integer;
begin
  if AIPVersion = Id_IPv6 then begin
    LFamilies := HostFamilyIpv6;
  end else begin
    LFamilies := HostFamilyIpv4;
  end;
  LError := LookUpHostAddresses(AHostName, LFamilies, LFound);
  if LError = ErrorNone then begin
    for i := 0 to High(LFound.Addresses) do begin
      if LFound.Addresses[i].Family = FamilyOf(AIPVersion) then begin
        Result := AddressToText(LFound.Addresses[i]);
        Exit;
      end;
    end;
    LError := ErrorNotFound;
  end;
  raise EIdResolveError.CreateError(LError, IndyFormat('Error resolving host %s: %s (%d)', {do not localize}
    [AHostName, HostLookupErrorMessage(LError), LError]));
end;

function TIdStackFreePascalOS.HostByAddress(const AAddress: string;
  const AIPVersion: TIdIPVersion = ID_DEFAULT_IP_VERSION): string;
var
  LHost: TInternetAddress;
  LError: LongInt;
begin
  if not TextToAddress(AAddress, LHost) then begin
    LError := ErrorInvalidArgument;
  end else begin
    LError := LookUpAddressName(LHost, Result);
    if LError = ErrorNone then begin
      Exit;
    end;
  end;
  raise EIdReverseResolveError.CreateError(LError, IndyFormat('Error resolving Address %s: %s (%d)', {do not localize}
    [AAddress, HostLookupErrorMessage(LError), LError]));
end;

function TIdStackFreePascalOS.ReadHostName: string;
begin
  if (ReadNodeName(Result) <> ErrorNone) or (Result = '') then begin
    Result := 'localhost'; {do not localize}
  end;
end;

type
  TIdServiceName = record
    Name: string;
    Port: TIdPort;
  end;

const
  // FreePascalOS has no /etc/services: the few names Indy's users give
  ServiceNames: array[0..11] of TIdServiceName = (
    (Name: 'echo'; Port: 7), (Name: 'ftp'; Port: 21), (Name: 'ssh'; Port: 22), {do not localize}
    (Name: 'telnet'; Port: 23), (Name: 'smtp'; Port: 25), (Name: 'domain'; Port: 53), {do not localize}
    (Name: 'http'; Port: 80), (Name: 'pop3'; Port: 110), (Name: 'imap'; Port: 143), {do not localize}
    (Name: 'https'; Port: 443), (Name: 'submission'; Port: 587), (Name: 'imaps'; Port: 993)); {do not localize}

function TIdStackFreePascalOS.WSGetServByName(const AServiceName: string): TIdPort;
var
  i: Integer;
begin
  for i := Low(ServiceNames) to High(ServiceNames) do begin
    if TextIsSame(ServiceNames[i].Name, AServiceName) then begin
      Result := ServiceNames[i].Port;
      Exit;
    end;
  end;
  raise EIdInvalidServiceName.CreateFmt(RSInvalidServiceName, [AServiceName]);
end;

procedure TIdStackFreePascalOS.AddServByPortToList(const APortNumber: TIdPort;
  AAddresses: TStrings);
var
  i: Integer;
begin
  for i := Low(ServiceNames) to High(ServiceNames) do begin
    if ServiceNames[i].Port = APortNumber then begin
      AAddresses.Add(ServiceNames[i].Name);
    end;
  end;
end;

function TIdStackFreePascalOS.HostToNetwork(AValue: UInt16): UInt16;
begin
  Result := NtoBE(AValue);
end;

function TIdStackFreePascalOS.NetworkToHost(AValue: UInt16): UInt16;
begin
  Result := BEtoN(AValue);
end;

function TIdStackFreePascalOS.HostToNetwork(AValue: UInt32): UInt32;
begin
  Result := NtoBE(AValue);
end;

function TIdStackFreePascalOS.NetworkToHost(AValue: UInt32): UInt32;
begin
  Result := BEtoN(AValue);
end;

function TIdStackFreePascalOS.HostToNetwork(AValue: TIdUInt64): TIdUInt64;
begin
  Result := NtoBE(AValue);
end;

function TIdStackFreePascalOS.NetworkToHost(AValue: TIdUInt64): TIdUInt64;
begin
  Result := BEtoN(AValue);
end;

function TIdStackFreePascalOS.SupportsIPv4: Boolean;
begin
  Result := CheckIPVersionSupport(Id_IPv4);
end;

function TIdStackFreePascalOS.SupportsIPv6: Boolean;
begin
  Result := CheckIPVersionSupport(Id_IPv6);
end;

function TIdStackFreePascalOS.CheckIPVersionSupport(const AIPVersion: TIdIPVersion): Boolean;
var
  LTmpSocket: TIdStackSocketHandle;
begin
  LTmpSocket := WSSocket(IdIPFamily[AIPVersion], Integer(Id_SOCK_STREAM), Id_IPPROTO_IP);
  Result := LTmpSocket <> Id_INVALID_SOCKET;
  if Result then begin
    WSCloseSocket(LTmpSocket);
  end;
end;

procedure TIdStackFreePascalOS.WriteChecksum(s: TIdStackSocketHandle;
  var VBuffer: TIdBytes; const AOffset: Integer; const AIP: String;
  const APort: TIdPort; const AIPVersion: TIdIPVersion);
begin
  // ICMPv6's checksum covers a pseudo-header with the addresses, which
  // FreePascalOS's ICMPv6 sockets fill in themselves
  case AIPVersion of
    Id_IPv4: CopyTIdUInt16(HostToLittleEndian(CalcCheckSum(VBuffer)), VBuffer, AOffset);
    Id_IPv6: ;
  else
    IPVersionUnsupported;
  end;
end;

function TIdStackFreePascalOS.IOControl(const s: TIdStackSocketHandle;
  const cmd: UInt32; var arg: UInt32): Integer;
begin
  // no ioctl() on sockets: SetBlocking() is an option there
  GLastError := Id_WSAEOPNOTSUPP;
  Result := Id_SOCKET_ERROR;
end;

type
  TIdStackLocalAddressAccess = class(TIdStackLocalAddress)
  end;

procedure TIdStackFreePascalOS.GetLocalAddressList(AAddresses: TIdStackLocalAddressList);
var
  LInterfaces: TNetworkInterfaceList;
  LHost: TInternetAddress;
  LAddress: TIdStackLocalAddress;
  i, j: Integer;
begin
  if ListNetworkInterfaces(LInterfaces) <> ErrorNone then begin
    Exit;
  end;
  AAddresses.BeginUpdate;
  try
    for i := 0 to High(LInterfaces) do begin
      for j := 0 to Integer(LInterfaces[i].AddressCount) - 1 do begin
        FillChar(LHost, SizeOf(LHost), 0);
        LHost.Family := LInterfaces[i].Addresses[j].Family;
        Move(LInterfaces[i].Addresses[j].Address[0], LHost.Bytes[0], SizeOf(LHost.Bytes));
        case LHost.Family of
          AddressFamilyIPv4:
            LAddress := TIdStackLocalAddressIPv4.Create(AAddresses, AddressToText(LHost),
              NetmaskToText(LInterfaces[i].Addresses[j].PrefixLength));
          AddressFamilyIPv6:
            LAddress := TIdStackLocalAddressIPv6.Create(AAddresses, AddressToText(LHost));
        else
          Continue;
        end;
        TIdStackLocalAddressAccess(LAddress).FInterfaceName := string(PChar(@LInterfaces[i].Name[0]));
        TIdStackLocalAddressAccess(LAddress).FInterfaceIndex := LInterfaces[i].Index;
      end;
    end;
  finally
    AAddresses.EndUpdate;
  end;
end;

{ ---------------------------------------------------------------------- }
{ TIdSocketListFreePascalOS                                               }
{ ---------------------------------------------------------------------- }

procedure TIdSocketListFreePascalOS.Add(AHandle: TIdStackSocketHandle);
begin
  Lock;
  try
    if not ContainsSocket(AHandle) then begin
      if FCount = Length(FHandles) then begin
        SetLength(FHandles, FCount * 2 + 4);
      end;
      FHandles[FCount] := AHandle;
      Inc(FCount);
    end;
  finally
    Unlock;
  end;
end;

procedure TIdSocketListFreePascalOS.Remove(AHandle: TIdStackSocketHandle);
var
  i: Integer;
begin
  Lock;
  try
    for i := 0 to FCount - 1 do begin
      if FHandles[i] = AHandle then begin
        FHandles[i] := FHandles[FCount - 1];
        Dec(FCount);
        Break;
      end;
    end;
  finally
    Unlock;
  end;
end;

function TIdSocketListFreePascalOS.Count: Integer;
begin
  Lock;
  try
    Result := FCount;
  finally
    Unlock;
  end;
end;

procedure TIdSocketListFreePascalOS.Clear;
begin
  Lock;
  try
    FCount := 0;
  finally
    Unlock;
  end;
end;

function TIdSocketListFreePascalOS.ContainsSocket(AHandle: TIdStackSocketHandle): Boolean;
var
  i: Integer;
begin
  Result := False;
  Lock;
  try
    for i := 0 to FCount - 1 do begin
      if FHandles[i] = AHandle then begin
        Result := True;
        Break;
      end;
    end;
  finally
    Unlock;
  end;
end;

function TIdSocketListFreePascalOS.GetItem(AIndex: Integer): TIdStackSocketHandle;
begin
  Lock;
  try
    if (AIndex >= 0) and (AIndex < FCount) then begin
      Result := FHandles[AIndex];
    end else begin
      Result := Id_INVALID_SOCKET;
    end;
  finally
    Unlock;
  end;
end;

function TIdSocketListFreePascalOS.Snapshot: TIdFposSocketHandles;
begin
  Lock;
  try
    Result := Copy(FHandles, 0, FCount);
  finally
    Unlock;
  end;
end;

procedure TIdSocketListFreePascalOS.SetHandles(const AHandles: TIdFposSocketHandles);
begin
  Lock;
  try
    FHandles := Copy(AHandles);
    FCount := Length(AHandles);
  finally
    Unlock;
  end;
end;

function TIdSocketListFreePascalOS.Clone: TIdSocketList;
begin
  Result := TIdSocketListFreePascalOS.Create;
  try
    TIdSocketListFreePascalOS(Result).SetHandles(Snapshot);
  except
    FreeAndNil(Result);
    raise;
  end;
end;

{ Those of AHandles for which Conditions (SocketReadable, SocketWritable)
  hold now, without waiting. }
function ReadyNow(const AHandles: TIdFposSocketHandles;
  const AConditions: LongWord): TIdFposSocketHandles;
var
  i, n: Integer;
begin
  SetLength(Result, Length(AHandles));
  n := 0;
  for i := 0 to High(AHandles) do begin
    if WaitForSocket(AHandles[i], AConditions, 0) > 0 then begin
      Result[n] := AHandles[i];
      Inc(n);
    end;
  end;
  SetLength(Result, n);
end;

{ Waits up to ATimeout (system milliseconds or InfiniteWait) until one of
  AHandles is readable; True if one is. Up to MaximumWaitHandles are
  waited on together, as a select() would; more are asked in turns. }
function WaitReadable(const AHandles: TIdFposSocketHandles; const ATimeout: Int64): Boolean;
var
  LStart: TIdTicks;
  LSlice: Int64;
begin
  case Length(AHandles) of
    0: begin
      // select() with nothing to watch: a sleep (for ever: a second at a
      // time, so that a caller looping on it does not spin)
      if ATimeout <> InfiniteWait then begin
        IndySleep(ATimeout);
      end else begin
        IndySleep(1000);
      end;
      Result := False;
    end;
    1..MaximumWaitHandles: begin
      if Length(AHandles) = 1 then begin
        Result := WaitForSocket(AHandles[0], SocketReadable, ATimeout) > 0;
      end else begin
        Result := WaitForHandles(AHandles, ATimeout) >= 0;
      end;
    end;
  else
    LStart := Ticks64;
    repeat
      Result := Length(ReadyNow(AHandles, SocketReadable)) > 0;
      if Result then begin
        Exit;
      end;
      LSlice := 10;
      if ATimeout <> InfiniteWait then begin
        if Int64(GetElapsedTicks64(LStart)) >= ATimeout then begin
          Exit;
        end;
        LSlice := IndyMin(LSlice, ATimeout - Int64(GetElapsedTicks64(LStart)));
      end;
      IndySleep(LSlice);
    until False;
  end;
end;

function TIdSocketListFreePascalOS.SelectRead(const ATimeout: Integer): Boolean;
begin
  Result := WaitReadable(Snapshot, WaitTime(ATimeout));
end;

function TIdSocketListFreePascalOS.SelectReadList(var VSocketList: TIdSocketList;
  const ATimeout: Integer): Boolean;
var
  LHandles, LReady: TIdFposSocketHandles;
begin
  LHandles := Snapshot;
  Result := WaitReadable(LHandles, WaitTime(ATimeout));
  if Result then begin
    LReady := ReadyNow(LHandles, SocketReadable);
    Result := Length(LReady) > 0;
    if Result then begin
      if VSocketList = nil then begin
        VSocketList := TIdSocketList.CreateSocketList;
      end;
      TIdSocketListFreePascalOS(VSocketList).SetHandles(LReady);
    end;
  end;
end;

class function TIdSocketListFreePascalOS.Select(AReadList: TIdSocketList;
  AWriteList: TIdSocketList; AExceptList: TIdSocketList;
  const ATimeout: Integer): Boolean;
var
  LRead, LWrite, LReadReady, LWriteReady: TIdFposSocketHandles;
  LStart: TIdTicks;
  LTimeout, LLeft: Int64;

  function Handles(AList: TIdSocketList): TIdFposSocketHandles;
  begin
    if AList <> nil then begin
      Result := TIdSocketListFreePascalOS(AList).Snapshot;
    end else begin
      Result := nil;
    end;
  end;

begin
  LRead := Handles(AReadList);
  LWrite := Handles(AWriteList);
  LTimeout := WaitTime(ATimeout);
  LStart := Ticks64;
  repeat
    LReadReady := ReadyNow(LRead, SocketReadable);
    LWriteReady := ReadyNow(LWrite, SocketWritable);
    Result := (Length(LReadReady) > 0) or (Length(LWriteReady) > 0);
    if Result then begin
      Break;
    end;
    if LTimeout = InfiniteWait then begin
      LLeft := InfiniteWait;
    end else begin
      LLeft := LTimeout - Int64(GetElapsedTicks64(LStart));
      if LLeft <= 0 then begin
        Break;
      end;
    end;
    if (Length(LWrite) = 0) and (Length(LRead) <= MaximumWaitHandles) then begin
      // only readability asked: wait for it
      WaitReadable(LRead, LLeft);
    end else if (Length(LRead) + Length(LWrite) = 1) then begin
      WaitForSocket(LWrite[0], SocketWritable, LLeft);
    end else begin
      if LLeft = InfiniteWait then begin
        LLeft := 10;
      end;
      IndySleep(IndyMin(LLeft, 10));
    end;
  until False;
  // as select() leaves them: only the ones that are ready (none has an
  // exceptional condition FreePascalOS reports)
  if AReadList <> nil then begin
    TIdSocketListFreePascalOS(AReadList).SetHandles(LReadReady);
  end;
  if AWriteList <> nil then begin
    TIdSocketListFreePascalOS(AWriteList).SetHandles(LWriteReady);
  end;
  if AExceptList <> nil then begin
    AExceptList.Clear;
  end;
end;

initialization
  SetStackClass(TIdStackFreePascalOS);
  GSocketListClass := TIdSocketListFreePascalOS;

end.
