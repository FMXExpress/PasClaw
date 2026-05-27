{
  PasClaw.Utils - small helpers used across the codebase.
  Mirrors pieces of pkg/utils in picoclaw.
}
unit PasClaw.Utils;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, DateUtils;

function DupStr(const S: string; Count: Integer): string;
function VisibleLength(const S: string): Integer;
function HasPrefix(const S, Prefix: string): Boolean;
function HasSuffix(const S, Suffix: string): Boolean;
function TrimQuotes(const S: string): string;
function EnsureDir(const Path: string): Boolean;
function ExpandHome(const Path: string): string;
function HomeDir: string;
function JoinPath(const A, B: string): string;
function FileExistsCI(const Path: string): Boolean;
function ReadFileText(const Path: string): string;
procedure WriteFileText(const Path, Content: string);
function SplitToList(const S: string; Sep: Char): TStringList;
function NowIsoUtc: string;

implementation

function DupStr(const S: string; Count: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Count do Result := Result + S;
end;

function VisibleLength(const S: string): Integer;
{ Strip ANSI escapes and count display columns; treats UTF-8 multi-byte runs
  as one column each. This is approximate but adequate for box drawing. }
var
  i, n: Integer;
  c: Byte;
  inEsc: Boolean;
begin
  n := 0;
  inEsc := False;
  i := 1;
  while i <= Length(S) do
  begin
    c := Byte(S[i]);
    if inEsc then
    begin
      if c = Ord('m') then inEsc := False;
      Inc(i);
      Continue;
    end;
    if c = 27 then { ESC }
    begin
      inEsc := True;
      Inc(i);
      Continue;
    end;
    { Skip continuation bytes 10xxxxxx, count lead bytes only. }
    if (c and $C0) <> $80 then
      Inc(n);
    Inc(i);
  end;
  Result := n;
end;

function HasPrefix(const S, Prefix: string): Boolean;
begin
  Result := (Length(S) >= Length(Prefix)) and
            (Copy(S, 1, Length(Prefix)) = Prefix);
end;

function HasSuffix(const S, Suffix: string): Boolean;
begin
  Result := (Length(S) >= Length(Suffix)) and
            (Copy(S, Length(S) - Length(Suffix) + 1, Length(Suffix)) = Suffix);
end;

function TrimQuotes(const S: string): string;
begin
  Result := S;
  if (Length(Result) >= 2) and
     (((Result[1] = '"') and (Result[Length(Result)] = '"')) or
      ((Result[1] = '''') and (Result[Length(Result)] = ''''))) then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

function HomeDir: string;
begin
  Result := GetEnvironmentVariable('HOME');
  if Result = '' then
    Result := GetEnvironmentVariable('USERPROFILE');
  if Result = '' then
    Result := GetCurrentDir;
end;

function ExpandHome(const Path: string): string;
begin
  if (Path <> '') and (Path[1] = '~') then
    Result := HomeDir + Copy(Path, 2, MaxInt)
  else
    Result := Path;
end;

function JoinPath(const A, B: string): string;
begin
  if A = '' then Exit(B);
  if B = '' then Exit(A);
  if (A[Length(A)] = PathDelim) or (A[Length(A)] = '/') then
    Result := A + B
  else
    Result := A + PathDelim + B;
end;

function EnsureDir(const Path: string): Boolean;
begin
  if DirectoryExists(Path) then Exit(True);
  Result := ForceDirectories(Path);
end;

function FileExistsCI(const Path: string): Boolean;
begin
  Result := FileExists(Path);
end;

function ReadFileText(const Path: string): string;
var
  Strm: TFileStream;
  Bytes: TBytes;
begin
  Result := '';
  if not FileExists(Path) then Exit;
  Strm := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Bytes, Strm.Size);
    if Strm.Size > 0 then Strm.ReadBuffer(Bytes[0], Strm.Size);
    { TEncoding.UTF8.GetString round-trips correctly in both FPC and Delphi:
      under FPC the result is AnsiString-UTF8; under Delphi it's UnicodeString
      decoded from the UTF-8 bytes. }
    Result := TEncoding.UTF8.GetString(Bytes);
  finally
    Strm.Free;
  end;
end;

procedure WriteFileText(const Path, Content: string);
var
  Strm: TFileStream;
  Bytes: TBytes;
begin
  EnsureDir(ExtractFilePath(Path));
  Strm := TFileStream.Create(Path, fmCreate);
  try
    if Content <> '' then
    begin
      Bytes := TEncoding.UTF8.GetBytes(Content);
      Strm.WriteBuffer(Bytes[0], Length(Bytes));
    end;
  finally
    Strm.Free;
  end;
end;

function SplitToList(const S: string; Sep: Char): TStringList;
var
  i, last: Integer;
begin
  Result := TStringList.Create;
  last := 1;
  for i := 1 to Length(S) do
    if S[i] = Sep then
    begin
      Result.Add(Copy(S, last, i - last));
      last := i + 1;
    end;
  Result.Add(Copy(S, last, MaxInt));
end;

function NowIsoUtc: string;
var
  DT: TDateTime;
begin
  {$IFDEF FPC}
  DT := LocalTimeToUniversal(Now);
  {$ELSE}
  DT := TTimeZone.Local.ToUniversalTime(Now);
  {$ENDIF}
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', DT);
end;

end.
