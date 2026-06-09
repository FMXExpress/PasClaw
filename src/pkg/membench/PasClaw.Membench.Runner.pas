(*
  PasClaw.Membench.Runner - simple memory log benchmark.

  Picoclaw's membench evaluates retrieval quality on a recall dataset
  (LoCoMo). That's a substantial port; the Pascal version here focuses on
  the raw I/O fundamentals -- write throughput and load throughput of the
  NDJSON memory log -- because those are the bits the rest of the agent
  builds on.

  Usage:
    pasclaw membench --records 10000 --content 256
*)
unit PasClaw.Membench.Runner;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

type
  TMembenchOpts = record
    Records:     Integer;
    ContentSize: Integer;
    KeepFile:    Boolean;
    OutDir:      string;
  end;

  TMembenchResult = record
    WriteSeconds:    Double;
    LoadSeconds:     Double;
    BytesOnDisk:     Int64;
    RecordsWritten:  Integer;
    RecordsLoaded:   Integer;
    Path:            string;
  end;

function DefaultMembenchOpts: TMembenchOpts;
function RunMembench(const Opts: TMembenchOpts): TMembenchResult;

implementation

uses
  Classes, DateUtils,
  {$IFNDEF FPC}IOUtils,{$ENDIF}
  PasClaw.Memory,
  PasClaw.Providers.Types,
  PasClaw.Utils;

function SystemTempDir: string;
begin
  {$IFDEF FPC}
  Result := GetTempDir;
  {$ELSE}
  Result := TPath.GetTempPath;
  {$ENDIF}
end;

function DefaultMembenchOpts: TMembenchOpts;
begin
  Result.Records     := 1000;
  Result.ContentSize := 128;
  Result.KeepFile    := False;
  Result.OutDir      := '';
end;

function MakePayload(Size: Integer): string;
var
  i: Integer;
  C: Char;
begin
  SetLength(Result, Size);
  for i := 1 to Size do
  begin
    C := Char(32 + ((i * 7) mod 90));
    if C = '"' then C := '_';
    if C = '\' then C := '/';
    Result[i] := C;
  end;
end;

function FileBytes(const Path: string): Int64;
var
  F: TFileStream;
begin
  Result := 0;
  if not FileExists(Path) then Exit;
  try
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Result := F.Size;
    finally
      F.Free;
    end;
  except
    Result := 0;
  end;
end;

function RunMembench(const Opts: TMembenchOpts): TMembenchResult;
var
  Home, SessionId, Path: string;
  Log: TMemoryLog;
  Start: TDateTime;
  i: Integer;
  Payload: string;
  Hist: TMessageArray;
begin
  Result.RecordsWritten := 0;
  Result.RecordsLoaded  := 0;
  Result.BytesOnDisk    := 0;
  Result.WriteSeconds   := 0;
  Result.LoadSeconds    := 0;

  if Opts.OutDir <> '' then Home := Opts.OutDir
  else                      Home := SystemTempDir;

  SessionId := 'membench-' + FormatDateTime('yyyymmdd-hhnnsszzz', Now);
  Log := NewMemoryLog(Home, SessionId);
  { Match the path NewMemoryLog actually wrote -- native separators throughout. }
  Path := JoinPath(JoinPath(JoinPath(Home, 'workspace'), 'memory'), SessionId + '.ndjson');
  Result.Path := Path;

  Payload := MakePayload(Opts.ContentSize);

  { Write pass }
  Start := Now;
  for i := 1 to Opts.Records do
  begin
    if (i mod 2) = 0 then
      Log.Append(mrAssistant, Payload, '')
    else
      Log.Append(mrUser, Payload, '');
  end;
  Log.Free;
  Result.WriteSeconds := SecondSpan(Now, Start);
  Result.RecordsWritten := Opts.Records;
  Result.BytesOnDisk := FileBytes(Path);

  { Load pass }
  Log := TMemoryLog.Create(Path, SessionId);
  try
    Start := Now;
    Hist := Log.LoadHistory;
    Result.LoadSeconds := SecondSpan(Now, Start);
    Result.RecordsLoaded := Length(Hist);
  finally
    Log.Free;
  end;

  if not Opts.KeepFile then
    DeleteFile(Path);
end;

end.
