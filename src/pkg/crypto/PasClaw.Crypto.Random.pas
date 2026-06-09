(*
  PasClaw.Crypto.Random - cryptographic random bytes.

  Wraps the OS CSPRNG:
    POSIX (Linux/macOS) -> read /dev/urandom
    Windows             -> CryptGenRandom via advapi32

  OAuth PKCE and state-nonce generation need unpredictable bytes; the
  built-in System.Random / Randomize feeds off a low-entropy time seed
  and isn't suitable. The /dev/urandom and CryptGenRandom calls are
  the conventional choices on every modern OS, both available without
  any extra dependency. Raises EOSRandomFailure on hard failure (e.g.
  /dev/urandom missing from a minimal chroot) -- let the caller decide
  whether to abort the OAuth flow or fall back to a downgraded mode.
*)
unit PasClaw.Crypto.Random;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  EOSRandomFailure = class(Exception);

function GetRandomBytes(N: Integer): TBytes;

implementation

{$IFDEF MSWINDOWS}
uses
  {$IFDEF FPC}Windows{$ELSE}Winapi.Windows{$ENDIF};

const
  PROV_RSA_FULL          = 1;
  CRYPT_VERIFYCONTEXT    = $F0000000;
  advapi32 = 'advapi32.dll';

function CryptAcquireContextW(out hProv: ULONG_PTR; pszContainer, pszProvider: PWideChar;
                              dwProvType: DWORD; dwFlags: DWORD): BOOL; stdcall;
                              external advapi32 name 'CryptAcquireContextW';
function CryptReleaseContext(hProv: ULONG_PTR; dwFlags: DWORD): BOOL; stdcall;
                              external advapi32 name 'CryptReleaseContext';
function CryptGenRandom(hProv: ULONG_PTR; dwLen: DWORD; pbBuffer: PByte): BOOL; stdcall;
                              external advapi32 name 'CryptGenRandom';

function GetRandomBytes(N: Integer): TBytes;
var
  hProv: ULONG_PTR;
begin
  if N <= 0 then begin SetLength(Result, 0); Exit; end;
  SetLength(Result, N);
  if not CryptAcquireContextW(hProv, nil, nil, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT) then
    raise EOSRandomFailure.CreateFmt('CryptAcquireContext failed (gle=%d)', [GetLastError]);
  try
    if not CryptGenRandom(hProv, N, @Result[0]) then
      raise EOSRandomFailure.CreateFmt('CryptGenRandom failed (gle=%d)', [GetLastError]);
  finally
    CryptReleaseContext(hProv, 0);
  end;
end;

{$ELSE}

function GetRandomBytes(N: Integer): TBytes;
var
  F: TFileStream;
  Read: Integer;
begin
  if N <= 0 then begin SetLength(Result, 0); Exit; end;
  SetLength(Result, N);
  try
    F := TFileStream.Create('/dev/urandom', fmOpenRead);
  except
    on E: Exception do
      raise EOSRandomFailure.CreateFmt('open /dev/urandom failed: %s', [E.Message]);
  end;
  try
    Read := F.Read(Result[0], N);
    if Read <> N then
      raise EOSRandomFailure.CreateFmt('/dev/urandom returned %d of %d bytes', [Read, N]);
  finally
    F.Free;
  end;
end;

{$ENDIF}

end.
