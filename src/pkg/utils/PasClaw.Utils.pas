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
(* Right-pad S with spaces until its visible length reaches W. Same
   shape as PasClaw.CliUI.PadRight, but exposed from Utils so the
   positioned TUI's chat pane can use it without dragging in the
   CliUI dependency. ANSI escape sequences in S contribute zero to
   the visible length, so a styled line still pads correctly. *)
function PadVisibleRight(const S: string; W: Integer): string;
(* Carve a visible-width-bounded prefix off S. Returns the prefix
   whose visible length is <= MaxVis, with all ANSI escape
   sequences encountered in that span emitted intact (escapes
   contribute zero visible width). Remainder is whatever bytes
   remain in S beyond the prefix; the caller iterates by feeding
   Remainder back in until it's empty. A trailing ANSI reset is
   appended to the prefix when any escape was emitted, so the
   prefix is self-contained -- subsequent output doesn't inherit
   leftover styling from a mid-line wrap. *)
function TruncateVisible(const S: string; MaxVis: Integer;
                         out Remainder: string): string;
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

(* Tag S as carrying CP_UTF8 bytes without rewriting them. No-op on
   Delphi (string = UnicodeString, codepages don't apply) and on any
   platform where the string is empty.

   Why this exists. Under FPC {$MODE DELPHI}, `string` is still
   `AnsiString` (1-byte elements) -- it carries a codepage tag.
   Strings produced by `TStringStream(... TEncoding.UTF8).DataString`,
   by `Indy` response reads, and by `fpjson`'s `.Get('field', '')`
   path come out tagged **CP_NONE / 0 (system default)**, even though
   their bytes are valid UTF-8. Downstream code that does
   codepage-aware conversion -- `TEncoding.UTF8.GetBytes(s)`,
   string-concat across mismatched codepages, AnsiString-aware
   I/O -- sees the system tag, interprets the UTF-8 bytes as the
   system codepage (CP1252 on Windows), and re-encodes to UTF-8.
   Result: classic mojibake on the wire and in the terminal --
   `é` (UTF-8 `C3 A9`) becomes `Ã©` (`C3 83 C2 A9`).

   Calling TagUTF8 at every boundary where bytes enter the program
   (HTTP response read, file read, env var, JSON parse output) keeps
   the tag honest. The bytes themselves are untouched -- only the
   `StringCodePage(s)` metadata flips from 0 → 65001. *)
procedure TagUTF8(var S: string); inline;

implementation

procedure TagUTF8(var S: string);
begin
  if S = '' then Exit;
  {$IFDEF FPC}
  { SetCodePage with Convert=False retags the AnsiString in place
    without touching the underlying bytes -- exactly the boundary
    behaviour we want. Convert=True would re-encode through the
    current tag's codepage and corrupt anything already-UTF-8 that
    was mis-tagged as CP_0; we do NOT want that. }
  SetCodePage(RawByteString(S), CP_UTF8, False);
  {$ENDIF}
  { Delphi modern: string = UnicodeString, no codepage tag --
    nothing to do, the inline compiler will collapse the call. }
end;

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

function PadVisibleRight(const S: string; W: Integer): string;
var
  Vis: Integer;
begin
  Vis := VisibleLength(S);
  if Vis >= W then Result := S
  else             Result := S + StringOfChar(' ', W - Vis);
end;

function TruncateVisible(const S: string; MaxVis: Integer;
                         out Remainder: string): string;
var
  i, n: Integer;
  c: Byte;
  inEsc, anyEsc: Boolean;
begin
  Result    := '';
  Remainder := '';
  n         := 0;
  inEsc     := False;
  anyEsc    := False;
  i         := 1;
  while i <= Length(S) do
  begin
    c := Byte(S[i]);
    if inEsc then
    begin
      Result := Result + S[i];
      if c = Ord('m') then inEsc := False;
      Inc(i);
      Continue;
    end;
    if c = 27 then
    begin
      Result := Result + S[i];
      inEsc  := True;
      anyEsc := True;
      Inc(i);
      Continue;
    end;
    { Count lead bytes (visible chars); continuation bytes
      (10xxxxxx) ride along with their lead. }
    if (c and $C0) <> $80 then
    begin
      if n >= MaxVis then Break;
      Inc(n);
    end;
    Result := Result + S[i];
    Inc(i);
  end;
  { Emit a final ANSI reset on the prefix when we opened any
    escapes -- otherwise a wrap mid-styled-run would carry the
    color into the padding / next pane row. Cheap and idempotent. }
  if anyEsc then Result := Result + #27 + '[0m';
  if i <= Length(S) then
    Remainder := Copy(S, i, MaxInt);
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
    Result := TEncoding.UTF8.GetString(Bytes);
    { Under FPC, TEncoding.UTF8.GetString returns AnsiString carrying
      CP_0 (system default) -- the bytes are UTF-8 but the tag isn't.
      Retag at the boundary so downstream code that calls
      TEncoding.UTF8.GetBytes on this string doesn't double-encode. }
    TagUTF8(Result);
  finally
    Strm.Free;
  end;
end;

procedure WriteFileText(const Path, Content: string);
var
  Strm: TFileStream;
  Bytes: TBytes;
  Tagged: string;
begin
  EnsureDir(ExtractFilePath(Path));
  Strm := TFileStream.Create(Path, fmCreate);
  try
    if Content <> '' then
    begin
      { Retag before GetBytes -- see PasClaw.Utils.TagUTF8 doc.
        Without this, FPC interprets a CP_0 Content as the system
        codepage and double-encodes any non-ASCII to UTF-8 on disk. }
      Tagged := Content;
      TagUTF8(Tagged);
      Bytes := TEncoding.UTF8.GetBytes(Tagged);
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
