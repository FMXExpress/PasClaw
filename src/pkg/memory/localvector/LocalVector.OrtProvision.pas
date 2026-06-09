{
  Vendored from FMXExpress/localvector (MIT licensed; LICENSE preserved
  alongside this file). Upstream commit: 0f00eece553da47e83169ddc8d72965c0dc40bcc.
  https://github.com/FMXExpress/localvector

  Modifications kept to a minimum -- PasClaw uses these units verbatim
  as the in-tree implementation of the hybrid FTS5+vector memory backend
  (PasClaw.Memory.Vector). Diff against upstream for change tracking.
}

unit LocalVector.OrtProvision;

{ Makes sure an ONNX Runtime is loaded and its C API is initialized.

  Because the bindings now load onnxruntime dynamically, the program can start
  with no runtime present. Strategy:
    1. If a runtime is already loaded, just (re)init the API + defaults.
    2. Prefer a runtime next to the executable. On Windows, if it is missing and
       downloads are allowed, fetch a current build from the ONNX Runtime GitHub
       release and extract onnxruntime.dll there.
    3. Otherwise fall back to the system loader (LD_LIBRARY_PATH / in-box DLL).
  Then InitOrtApi + EnsureOrtDefaults. Raises on failure. }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes;
{$ELSE}
  System.SysUtils, System.Classes;
{$ENDIF}

const
  ORT_VERSION = '1.26.0';

{ Ensures the runtime is loaded + API ready. Returns True; raises on failure. }
function EnsureOnnxRuntime(const AExeDir: string; AAllowDownload, AVerbose: Boolean): Boolean;

{ True on platforms where we can auto-download a runtime (currently Windows x64). }
function CanAutoProvisionRuntime: Boolean;

implementation

uses
  onnxruntime_pas_api, onnxruntime, LocalVector.Runtime
{$IFDEF FPC}
  , fphttpclient, opensslsockets, zipper
{$ELSE}
  , System.Net.HttpClient, System.Net.URLClient, System.Zip
{$ENDIF};

function CanAutoProvisionRuntime: Boolean;
begin
{$IFDEF MSWINDOWS}
  {$IFDEF WIN64}
  Result := True;
  {$ELSE}
  Result := False;  // only the win-x64 release asset is wired up
  {$ENDIF}
{$ELSE}
  Result := False;
{$ENDIF}
end;

{$IFDEF FPC}
procedure DownloadFile(const AUrl, ADest: string);
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
procedure DownloadFile(const AUrl, ADest: string);
var
  C: THTTPClient;
  R: IHTTPResponse;
  FS: TFileStream;
begin
  C := THTTPClient.Create;
  try
    C.ConnectionTimeout := 30000;
    C.ResponseTimeout := 600000;
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

{$IFDEF FPC}
type
  TZipEntryWriter = class
    Target: string;
    Stream: TFileStream;
    procedure DoCreate(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
    procedure DoDone(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
  end;

procedure TZipEntryWriter.DoCreate(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
begin
  Stream := TFileStream.Create(Target, fmCreate);
  AStream := Stream;
end;

procedure TZipEntryWriter.DoDone(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
begin
  FreeAndNil(Stream);
  AStream := nil;
end;

procedure ExtractZipEntryToFile(const AZip, AEntry, ADest: string);
var
  UnZip: TUnZipper;
  List: TStringList;
  W: TZipEntryWriter;
begin
  UnZip := TUnZipper.Create;
  W := TZipEntryWriter.Create;
  List := TStringList.Create;
  try
    W.Target := ADest;
    UnZip.FileName := AZip;
    UnZip.OnCreateStream := W.DoCreate;
    UnZip.OnDoneStream := W.DoDone;
    List.Add(AEntry);
    UnZip.UnZipFiles(List);
  finally
    List.Free;
    W.Free;
    UnZip.Free;
  end;
end;
{$ELSE}
procedure ExtractZipEntryToFile(const AZip, AEntry, ADest: string);
var
  Zip: TZipFile;
  Bytes: TBytes;
  FS: TFileStream;
begin
  Zip := TZipFile.Create;
  try
    Zip.Open(AZip, zmRead);
    Zip.Read(AEntry, Bytes);
    FS := TFileStream.Create(ADest, fmCreate);
    try
      if Length(Bytes) > 0 then
        FS.WriteBuffer(Bytes[0], Length(Bytes));
    finally
      FS.Free;
    end;
  finally
    Zip.Free;
  end;
end;
{$ENDIF}

procedure ProvisionRuntime(const AExeDir: string; AVerbose: Boolean);
const
  RELEASE = 'https://github.com/microsoft/onnxruntime/releases/download/v' + ORT_VERSION + '/';
  ASSET   = 'onnxruntime-win-x64-' + ORT_VERSION + '.zip';
  ENTRY   = 'onnxruntime-win-x64-' + ORT_VERSION + '/lib/onnxruntime.dll';
var
  ZipPath, Dest: string;
begin
  Dest := IncludeTrailingPathDelimiter(AExeDir) + ORT_LIB;
  ZipPath := IncludeTrailingPathDelimiter(AExeDir) + ASSET;

  WriteLn(ErrOutput, '[localvector] onnxruntime not found - downloading ONNX Runtime ',
          ORT_VERSION, ' ...');
  WriteLn(ErrOutput, '[localvector]   from ', RELEASE + ASSET);
  DownloadFile(RELEASE + ASSET, ZipPath);
  try
    WriteLn(ErrOutput, '[localvector]   extracting ', ORT_LIB, ' -> ', Dest);
    ExtractZipEntryToFile(ZipPath, ENTRY, Dest);
  finally
    if FileExists(ZipPath) then
      DeleteFile(ZipPath);
  end;
  WriteLn(ErrOutput, '[localvector]   installed ', Dest);
end;

function EnsureOnnxRuntime(const AExeDir: string; AAllowDownload, AVerbose: Boolean): Boolean;
var
  Dll: string;
begin
  if not OrtRuntimeLoaded then
  begin
    Dll := IncludeTrailingPathDelimiter(AExeDir) + ORT_LIB;

    // Prefer a current runtime next to the exe; download one if it's missing.
    if (not FileExists(Dll)) and AAllowDownload and CanAutoProvisionRuntime then
    begin
      try
        ProvisionRuntime(AExeDir, AVerbose);
      except
        on E: Exception do
          WriteLn(ErrOutput, '[localvector] runtime download failed: ', E.Message);
      end;
    end;

    if FileExists(Dll) then
      LoadOnnxRuntime(Dll)
    else
      LoadOnnxRuntime('');   // system loader (LD_LIBRARY_PATH / Windows in-box)
  end;

  if not OrtRuntimeLoaded then
    raise Exception.Create(
      'Could not load onnxruntime. Put ' + ORT_LIB + ' next to the executable' +
      {$IFDEF MSWINDOWS}'.'{$ELSE}' or on the loader path.'{$ENDIF});

  if not InitOrtApi then
    raise Exception.CreateFmt(
      'Loaded onnxruntime but its C API (v%d) is unavailable - the library may be too old.',
      [ORT_API_VERSION]);

  EnsureOrtDefaults;
  Result := True;
end;

end.
