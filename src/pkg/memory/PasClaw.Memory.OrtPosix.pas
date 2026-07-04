(*
  PasClaw.Memory.OrtPosix - download + install the ONNX Runtime shared library
  on Linux / macOS, where the vendored LocalVector.OrtProvision auto-download is
  win-x64 only (CanAutoProvisionRuntime = False off Windows).

  Fetches the platform's ONNX Runtime release tarball from GitHub, extracts the
  real (non-symlink) shared lib, and drops it in the cache as onnxruntime.so /
  onnxruntime.dylib -- exactly where EnsureOnnxRuntime looks. Console-free so
  BOTH the CLI (`pasclaw memory provision`) and the gateway's background web
  provisioning job can call the same code path.
*)
unit PasClaw.Memory.OrtPosix;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

{ Compiler-neutral macOS symbol. }
{$IFDEF DARWIN}{$DEFINE PCLAW_MACOS}{$ENDIF}
{$IFDEF MACOS}{$DEFINE PCLAW_MACOS}{$ENDIF}
{$IFDEF OSX}{$DEFINE PCLAW_MACOS}{$ENDIF}

interface

{ Ensure onnxruntime.so/.dylib exists in ACacheDir on POSIX. Returns True when
  the library is present afterwards (already there, or freshly installed).
  Always False on Windows (that path uses the vendored win-x64 auto-download).
  AMsg carries a short human status/error for the caller to surface. }
function EnsurePosixOrt(const ACacheDir: string; out AMsg: string): Boolean;

implementation

uses
  {$IFDEF FPC}
  SysUtils, fphttpclient, opensslsockets;
  {$ELSE}
  System.SysUtils, System.Net.HttpClient, System.Net.URLClient;
  {$ENDIF}

const
  { Pinned to match LocalVector's onnxruntime bindings' expected API version. }
  ORT_POSIX_VERSION = '1.20.1';

function JoinP(const ADir, AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ADir) + AName;
end;

function InstalledLibPath(const ACacheDir: string): string;
begin
  {$IFDEF PCLAW_MACOS}
  Result := JoinP(ACacheDir, 'onnxruntime.dylib');
  {$ELSE}
  Result := JoinP(ACacheDir, 'onnxruntime.so');
  {$ENDIF}
end;

{$IFNDEF MSWINDOWS}
function PosixOrtAsset(out Asset, LibGlob: string): Boolean;
begin
  Result := True;
  {$IFDEF PCLAW_MACOS}
  Asset   := 'onnxruntime-osx-universal2-' + ORT_POSIX_VERSION + '.tgz';
  LibGlob := 'libonnxruntime*.dylib';
  {$ELSE}
    {$IFDEF CPUAARCH64}
    Asset := 'onnxruntime-linux-aarch64-' + ORT_POSIX_VERSION + '.tgz';
    {$ELSE}
    Asset := 'onnxruntime-linux-x64-' + ORT_POSIX_VERSION + '.tgz';
    {$ENDIF}
  LibGlob := 'libonnxruntime.so.*';
  {$ENDIF}
end;

function HttpDownload(const Url, Dest: string): Boolean;
{$IFDEF FPC}
var C: TFPHTTPClient;
begin
  Result := False;
  C := TFPHTTPClient.Create(nil);
  try
    C.AllowRedirect := True;
    C.AddHeader('User-Agent', 'pasclaw');
    C.Get(Url, Dest);
    Result := FileExists(Dest);
  finally
    C.Free;
  end;
end;
{$ELSE}
var C: THTTPClient; FS: TFileStream;
begin
  Result := False;
  C := THTTPClient.Create;
  FS := TFileStream.Create(Dest, fmCreate);
  try
    C.Get(Url, FS);
    Result := FS.Size > 0;
  finally
    FS.Free;
    C.Free;
  end;
end;
{$ENDIF}
{$ENDIF}

function EnsurePosixOrt(const ACacheDir: string; out AMsg: string): Boolean;
{$IFDEF MSWINDOWS}
begin
  AMsg := 'windows uses the vendored auto-download';
  Result := False;
end;
{$ELSE}
var
  Asset, LibGlob, Url, Tgz, Tmp, Dest: string;
begin
  AMsg := '';
  Dest := InstalledLibPath(ACacheDir);
  if FileExists(Dest) then
  begin
    AMsg := 'already installed';
    Exit(True);
  end;
  if not PosixOrtAsset(Asset, LibGlob) then
  begin
    AMsg := 'no ONNX Runtime asset for this platform';
    Exit(False);
  end;
  ForceDirectories(ACacheDir);
  Url := 'https://github.com/microsoft/onnxruntime/releases/download/v' +
         ORT_POSIX_VERSION + '/' + Asset;
  Tgz := JoinP(ACacheDir, Asset);
  Tmp := JoinP(ACacheDir, 'ort-extract');

  Result := False;
  try
    if not HttpDownload(Url, Tgz) then
    begin
      AMsg := 'download failed: ' + Url;
      Exit(False);
    end;
    { Extract + copy the real (non-symlink) shared lib via system tar. }
    ExecuteProcess('/bin/sh', ['-c', 'rm -rf "' + Tmp + '" && mkdir -p "' + Tmp +
      '" && tar -xzf "' + Tgz + '" -C "' + Tmp + '" && cp "$(find "' + Tmp +
      '" -name ''' + LibGlob + ''' -type f | head -1)" "' + Dest + '"']);
    Result := FileExists(Dest);
    if Result then AMsg := 'installed at ' + Dest
    else AMsg := 'extract failed (no ' + LibGlob + ' in archive)';
  except
    on E: Exception do AMsg := E.Message;
  end;
  try
    if FileExists(Tgz) then DeleteFile(Tgz);
    ExecuteProcess('/bin/sh', ['-c', 'rm -rf "' + Tmp + '"']);
  except
    on E: Exception do ;
  end;
end;
{$ENDIF}

end.
