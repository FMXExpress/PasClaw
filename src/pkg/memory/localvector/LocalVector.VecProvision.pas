{
  Vendored from FMXExpress/localvector (MIT licensed; LICENSE preserved
  alongside this file). Upstream commit: 0f00eece553da47e83169ddc8d72965c0dc40bcc.
  https://github.com/FMXExpress/localvector

  Modifications kept to a minimum -- PasClaw uses these units verbatim
  as the in-tree implementation of the hybrid FTS5+vector memory backend
  (PasClaw.Memory.Vector). Diff against upstream for change tracking.
}

unit LocalVector.VecProvision;

{ Ensures the sqlite-vec loadable extension (vec0.dll / vec0.so / vec0.dylib) is
  available next to the executable, downloading + extracting it from the
  sqlite-vec GitHub release on first use (same idea as the onnxruntime
  auto-provision). The release assets are single-file .tar.gz archives. }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes;
{$ELSE}
  System.SysUtils, System.Classes;
{$ENDIF}

const
  SQLITE_VEC_VERSION = '0.1.9';

  {$IFDEF MSWINDOWS}
  VEC0_LIB = 'vec0.dll';
  {$ELSE}
    {$IFDEF DARWIN}
  VEC0_LIB = 'vec0.dylib';
    {$ELSE}
  VEC0_LIB = 'vec0.so';
    {$ENDIF}
  {$ENDIF}

  // sqlite-vec's exported extension entry point (independent of the file name).
  VEC0_ENTRY = 'sqlite3_vec_init';

{ Returns the full path to the vec0 extension, downloading it if missing.
  Raises if it cannot be obtained. }
function EnsureVec0(const AExeDir: string; AAllowDownload, AVerbose: Boolean): string;

implementation

uses
  {$IFDEF FPC}
  fphttpclient, opensslsockets, zstream
  {$ELSE}
  System.Net.HttpClient, System.Net.URLClient, System.ZLib
  {$ENDIF};

function PlatformTag: string;
begin
{$IFDEF MSWINDOWS}
  Result := 'windows';
{$ELSE}
  {$IFDEF DARWIN}
  Result := 'macos';
  {$ELSE}
  Result := 'linux';
  {$ENDIF}
{$ENDIF}
end;

{$IFDEF CPUAARCH64}{$DEFINE LV_ARM64}{$ENDIF}
{$IFDEF CPUARM64}{$DEFINE LV_ARM64}{$ENDIF}

function ArchTag: string;
begin
{$IFDEF LV_ARM64}
  Result := 'aarch64';
{$ELSE}
  Result := 'x86_64';
{$ENDIF}
end;

procedure DownloadFile(const AUrl, ADest: string);
{$IFDEF FPC}
var
  C: TFPHTTPClient;
  FS: TFileStream;
begin
  C := TFPHTTPClient.Create(nil);
  try
    C.AllowRedirect := True;
    C.AddHeader('User-Agent', 'localvector/1.0');
    FS := TFileStream.Create(ADest, fmCreate);
    try
      C.Get(AUrl, FS);
    finally
      FS.Free;
    end;
  finally
    C.Free;
  end;
end;
{$ELSE}
var
  C: THTTPClient;
  R: IHTTPResponse;
  FS: TFileStream;
begin
  C := THTTPClient.Create;
  try
    C.ConnectionTimeout := 30000;
    C.ResponseTimeout := 300000;
    FS := TFileStream.Create(ADest, fmCreate);
    try
      R := C.Get(AUrl, FS);
      if R.StatusCode <> 200 then
        raise Exception.CreateFmt('HTTP %d %s for %s', [R.StatusCode, R.StatusText, AUrl]);
    finally
      FS.Free;
    end;
  finally
    C.Free;
  end;
end;
{$ENDIF}

{ Decompress a gzip file fully into memory. }
function GunzipFile(const AGzPath: string): TBytes;
const
  CHUNK = 65536;
var
  Buf: TBytes;
  Got: Integer;
  Outp: TMemoryStream;
{$IFDEF FPC}
  GZ: TGZFileStream;
{$ELSE}
  Src: TFileStream;
  Dec: TZDecompressionStream;
{$ENDIF}
begin
  Outp := TMemoryStream.Create;
  try
    SetLength(Buf, CHUNK);
  {$IFDEF FPC}
    GZ := TGZFileStream.Create(AGzPath, gzOpenRead);
    try
      repeat
        Got := GZ.Read(Buf[0], CHUNK);
        if Got > 0 then
          Outp.WriteBuffer(Buf[0], Got);
      until Got <= 0;
    finally
      GZ.Free;
    end;
  {$ELSE}
    Src := TFileStream.Create(AGzPath, fmOpenRead or fmShareDenyWrite);
    try
      Dec := TZDecompressionStream.Create(Src, 31); // 31 = gzip
      try
        repeat
          Got := Dec.Read(Buf[0], CHUNK);
          if Got > 0 then
            Outp.WriteBuffer(Buf[0], Got);
        until Got <= 0;
      finally
        Dec.Free;
      end;
    finally
      Src.Free;
    end;
  {$ENDIF}
    SetLength(Result, Outp.Size);
    if Outp.Size > 0 then
      Move(Outp.Memory^, Result[0], Outp.Size);
  finally
    Outp.Free;
  end;
end;

{ Find a member of an (uncompressed) tar archive whose name contains ANeedle and
  copy its bytes to ADest. tar = 512-byte header blocks; size is octal ASCII at
  offset 124. }
function TarExtractTo(const ATar: TBytes; const ANeedle, ADest: string): Boolean;
var
  Ofs, I, Size: Integer;
  Name, OctS: string;
  FS: TFileStream;
begin
  Result := False;
  Ofs := 0;
  while Ofs + 512 <= Length(ATar) do
  begin
    if ATar[Ofs] = 0 then // empty block -> end of archive
      Break;
    // name: bytes [0..99], NUL-terminated
    Name := '';
    I := 0;
    while (I < 100) and (ATar[Ofs + I] <> 0) do
    begin
      Name := Name + Char(ATar[Ofs + I]);
      Inc(I);
    end;
    // size: octal ascii at [124..135]
    OctS := '';
    for I := 124 to 135 do
    begin
      if (ATar[Ofs + I] = 0) or (ATar[Ofs + I] = Ord(' ')) then
        Break;
      OctS := OctS + Char(ATar[Ofs + I]);
    end;
    Size := 0;
    for I := 1 to Length(OctS) do
      if (OctS[I] >= '0') and (OctS[I] <= '7') then
        Size := Size * 8 + (Ord(OctS[I]) - Ord('0'));

    if (Pos(LowerCase(ANeedle), LowerCase(Name)) > 0) and (Size > 0) then
    begin
      FS := TFileStream.Create(ADest, fmCreate);
      try
        FS.WriteBuffer(ATar[Ofs + 512], Size);
      finally
        FS.Free;
      end;
      Exit(True);
    end;

    // advance: header + data rounded up to 512
    Inc(Ofs, 512 + ((Size + 511) div 512) * 512);
  end;
end;

function EnsureVec0(const AExeDir: string; AAllowDownload, AVerbose: Boolean): string;
var
  Dest, Asset, Url, TgzPath: string;
  Tar: TBytes;
begin
  Dest := IncludeTrailingPathDelimiter(AExeDir) + VEC0_LIB;
  if FileExists(Dest) then
    Exit(Dest);

  if not AAllowDownload then
    raise Exception.CreateFmt('sqlite-vec extension not found: %s', [Dest]);

  Asset := Format('sqlite-vec-%s-loadable-%s-%s.tar.gz',
    [SQLITE_VEC_VERSION, PlatformTag, ArchTag]);
  Url := 'https://github.com/asg017/sqlite-vec/releases/download/v' +
    SQLITE_VEC_VERSION + '/' + Asset;
  TgzPath := IncludeTrailingPathDelimiter(AExeDir) + Asset;

  WriteLn(ErrOutput, '[localvector] sqlite-vec not found - downloading v',
    SQLITE_VEC_VERSION, ' ...');
  WriteLn(ErrOutput, '[localvector]   from ', Url);
  DownloadFile(Url, TgzPath);
  try
    Tar := GunzipFile(TgzPath);
    if not TarExtractTo(Tar, 'vec0', Dest) then
      raise Exception.Create('vec0 binary not found inside the downloaded archive.');
  finally
    if FileExists(TgzPath) then
      DeleteFile(TgzPath);
  end;
  WriteLn(ErrOutput, '[localvector]   installed ', Dest);
  Result := Dest;
end;

end.
