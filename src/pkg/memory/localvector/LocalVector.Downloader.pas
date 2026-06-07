{
  Vendored from FMXExpress/localvector (MIT licensed; LICENSE preserved
  alongside this file). Upstream commit: 0f00eece553da47e83169ddc8d72965c0dc40bcc.
  https://github.com/FMXExpress/localvector

  Modifications kept to a minimum — PasClaw uses these units verbatim
  as the in-tree implementation of the hybrid FTS5+vector memory backend
  (PasClaw.Memory.Vector). Diff against upstream for change tracking.
}

unit LocalVector.Downloader;

{ First-run model acquisition. Downloads the two files a WordPiece model needs --
  the ONNX graph and vocab.txt -- from the Hugging Face repo named in the model
  spec, into a local models directory.

  HTTP is provided by the Delphi RTL (System.Net.HttpClient, TLS via SChannel)
  or, under Free Pascal, by fphttpclient + opensslsockets (needs the OpenSSL
  runtime libraries to be present). }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  LocalVector.Models;

const
  MODEL_FILE = 'model.onnx';
  VOCAB_FILE = 'vocab.txt';

type
  TModelDownloader = class
  private
    FSpec: TModelSpec;
    FModelDir: string;
    FModelPath: string;
    FVocabPath: string;
    FVerbose: Boolean;
    procedure DownloadTo(const AUrl, ADestPath: string);
  public
    constructor Create(const ASpec: TModelSpec; const AModelDir: string;
      AVerbose: Boolean = False);
    { Ensures both files exist locally, downloading whatever is missing. }
    procedure EnsureFiles;
    property ModelPath: string read FModelPath;
    property VocabPath: string read FVocabPath;
  end;

implementation

uses
  {$IFDEF FPC}
  fphttpclient, opensslsockets
  {$ELSE}
  System.Net.HttpClient, System.Net.URLClient
  {$ENDIF};

function JoinPath(const ADir, AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ADir) + AName;
end;

function FileSizeOf(const APath: string): Int64;
var
  FS: TFileStream;
begin
  Result := -1;
  if not FileExists(APath) then
    Exit;
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    Result := FS.Size;
  finally
    FS.Free;
  end;
end;

constructor TModelDownloader.Create(const ASpec: TModelSpec; const AModelDir: string;
  AVerbose: Boolean);
begin
  inherited Create;
  FSpec := ASpec;
  FModelDir := AModelDir;
  FVerbose := AVerbose;
  FModelPath := JoinPath(FModelDir, MODEL_FILE);
  FVocabPath := JoinPath(FModelDir, VOCAB_FILE);
end;

{$IFDEF FPC}
procedure TModelDownloader.DownloadTo(const AUrl, ADestPath: string);
var
  Client: TFPHTTPClient;
  FS: TFileStream;
begin
  WriteLn(ErrOutput, '[localvector] downloading ', ExtractFileName(ADestPath), ' ...');
  WriteLn(ErrOutput, '[localvector]   from ', AUrl);
  Client := TFPHTTPClient.Create(nil);
  try
    Client.AllowRedirect := True; // HF resolve/ URLs redirect to a CDN
    Client.AddHeader('User-Agent', 'localvector/1.0');
    FS := TFileStream.Create(ADestPath, fmCreate);
    try
      Client.Get(AUrl, FS);
    finally
      FS.Free;
    end;
  finally
    Client.Free;
  end;
  WriteLn(ErrOutput, '[localvector]   saved ', ADestPath, ' (',
          FileSizeOf(ADestPath), ' bytes)');
end;
{$ELSE}
procedure TModelDownloader.DownloadTo(const AUrl, ADestPath: string);
var
  Client: THTTPClient;
  Response: IHTTPResponse;
  FS: TFileStream;
begin
  WriteLn(ErrOutput, '[localvector] downloading ', ExtractFileName(ADestPath), ' ...');
  WriteLn(ErrOutput, '[localvector]   from ', AUrl);
  Client := THTTPClient.Create;
  try
    Client.ConnectionTimeout := 30000;
    Client.ResponseTimeout := 1800000; // up to 30 min for big models
    FS := TFileStream.Create(ADestPath, fmCreate);
    try
      Response := Client.Get(AUrl, FS);
      if Response.StatusCode <> 200 then
        raise Exception.CreateFmt('Download failed (%d %s) for %s',
          [Response.StatusCode, Response.StatusText, AUrl]);
    finally
      FS.Free;
    end;
  finally
    Client.Free;
  end;
  WriteLn(ErrOutput, '[localvector]   saved ', ADestPath, ' (',
          FileSizeOf(ADestPath), ' bytes)');
end;
{$ENDIF}

procedure TModelDownloader.EnsureFiles;
begin
  if not DirectoryExists(FModelDir) then
    ForceDirectories(FModelDir);

  if FVerbose then
    WriteLn(ErrOutput, '[localvector] model: ', FSpec.DisplayName,
            ' (', FSpec.SizeDesc, ')  dir: ', FModelDir);

  if not FileExists(FVocabPath) then
    DownloadTo(FSpec.BaseURL + FSpec.VocabRelURL, FVocabPath);

  // Treat a suspiciously tiny model file as a failed/partial download.
  if (not FileExists(FModelPath)) or (FileSizeOf(FModelPath) < 1024 * 1024) then
  begin
    if FileExists(FModelPath) then
      DeleteFile(FModelPath);
    DownloadTo(FSpec.BaseURL + FSpec.ModelRelURL, FModelPath);
  end;
end;

end.
