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

type
  (* Canonical dynamic string array. FPC's SysUtils already exports a
     TStringArray that every FPC unit shares, so the per-unit local defs were
     all Delphi-only -- the duplication (and dcc64's E2010/E2250 "distinct
     named type" collisions) only ever bit the Delphi build. Mirror that here:
     alias the RTL type on FPC (so PasClaw.Utils.TStringArray is literally
     SysUtils.TStringArray and adds no second type), and provide the ONE
     canonical definition on Delphi, which the former definers now alias.
     PasClaw.Utils depends only on the RTL, so it is safe to use anywhere
     without a cycle. *)
  {$IFDEF FPC}
  TStringArray = SysUtils.TStringArray;
  {$ELSE}
  TStringArray = array of string;
  {$ENDIF}

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
{ True when B is well-formed UTF-8 (used by ReadFileText to pick a Latin-1
  fallback for non-UTF-8 files; exposed for tests). }
function BytesAreValidUTF8(const B: TBytes): Boolean;
procedure WriteFileText(const Path, Content: string);
{ On Windows, convert '/' to '\' so RTL path parsing (ExtractFilePath,
  ForceDirectories) handles paths the model passes with forward slashes
  (it copies them from fs_read's "path" output). Without this,
  ExtractFilePath('a/b/c.pas') returns '' on Windows and ForceDirectories
  raises "Unable to create directory". On POSIX '\' is a legal filename
  char, so the path is returned untouched. }
function NormalizePathSep(const P: string): string;
function SplitToList(const S: string; Sep: Char): TStringList;
function NowIsoUtc: string;

{ Local wall-clock time with its UTC offset and the UTC equivalent, e.g.
  "Thu 2026-08-14 12:25:33 UTC+02:00 (2026-08-14T10:25:33Z)".

  Exists because a model with no stated time falls back to its training
  cutoff, which silently corrupts date arithmetic, "is this still the
  latest version" judgements, relative-time reasoning, and anything
  schedule-shaped. Day-of-week is included because "next Monday" is a
  question models actually get asked. }
function NowStampWithZone: string;

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

function NormalizePathSep(const P: string): string;
begin
  {$IFDEF MSWINDOWS}
  Result := StringReplace(P, '/', '\', [rfReplaceAll]);
  {$ELSE}
  Result := P;
  {$ENDIF}
end;

{ True when B holds a well-formed UTF-8 byte sequence (rejects overlong forms,
  stray continuation bytes, and > U+10FFFF leads). Used to decide whether a file
  needs the Latin-1 fallback below. }
function BytesAreValidUTF8(const B: TBytes): Boolean;
var
  i, n, Extra, j: Integer;
  c, Lo, Hi: Byte;
begin
  i := 0; n := Length(B);
  while i < n do
  begin
    c := B[i];
    Lo := $80; Hi := $BF;   { default range for a trailing continuation byte }
    if c < $80 then Extra := 0
    else if (c and $E0) = $C0 then
    begin if c < $C2 then Exit(False); Extra := 1; end   { $C0/$C1 -> overlong }
    else if (c and $F0) = $E0 then
    begin
      Extra := 2;
      { RFC 3629 boundary on the FIRST trailing byte: E0 rejects overlong
        (needs A0..BF), ED rejects the UTF-16 surrogate range U+D800..DFFF
        (needs 80..9F). }
      if c = $E0 then Lo := $A0
      else if c = $ED then Hi := $9F;
    end
    else if (c and $F8) = $F0 then
    begin
      if c > $F4 then Exit(False);                        { $F5..$F7 -> > U+10FFFF }
      Extra := 3;
      { F0 rejects overlong (needs 90..BF); F4 caps the last plane at
        U+10FFFF (needs 80..8F). }
      if c = $F0 then Lo := $90
      else if c = $F4 then Hi := $8F;
    end
    else Exit(False);                                     { stray continuation / invalid lead }
    for j := 1 to Extra do
    begin
      Inc(i);
      if (i >= n) or (B[i] < Lo) or (B[i] > Hi) then Exit(False);
      Lo := $80; Hi := $BF;   { only the first trailing byte is range-restricted }
    end;
    Inc(i);
  end;
  Result := True;
end;

{ Re-encode arbitrary bytes as UTF-8 by treating each input byte as a Latin-1
  codepoint (0..255). Total and lossless: every byte maps to a valid UTF-8
  sequence, so a non-UTF-8 file (e.g. a Windows-1252 PHP source) still reads back
  as valid, displayable text instead of raising an encoding error. }
function Latin1BytesToUTF8(const B: TBytes): TBytes;
var
  i, o, n: Integer;
  c: Byte;
begin
  n := Length(B);
  SetLength(Result, n * 2);   { worst case: 2 UTF-8 bytes per input byte }
  o := 0;
  for i := 0 to n - 1 do
  begin
    c := B[i];
    if c < $80 then begin Result[o] := c; Inc(o); end
    else
    begin
      Result[o] := $C0 or (c shr 6);   Inc(o);
      Result[o] := $80 or (c and $3F); Inc(o);
    end;
  end;
  SetLength(Result, o);
end;

{ Wrap already-UTF-8 bytes as pasclaw's `string` WITHOUT any system-codepage
  round-trip: on FPC keep the bytes verbatim and tag them CP_UTF8; on Delphi
  decode to the native UnicodeString. Never raises. }
function UTF8BytesToStr(const B: TBytes): string;
begin
{$IFDEF FPC}
  SetLength(Result, Length(B));
  if Length(B) > 0 then Move(B[0], Result[1], Length(B));
  { The bytes are UTF-8 but a raw AnsiString is tagged CP_0 (system default);
    retag so downstream TEncoding.UTF8.GetBytes on this string doesn't
    double-encode. }
  TagUTF8(Result);
{$ELSE}
  Result := TEncoding.UTF8.GetString(B);
{$ENDIF}
end;

function ReadFileText(const Path: string): string;
var
  Strm: TFileStream;
  Bytes: TBytes;
  NPath: string;
  N: Integer;
begin
  Result := '';
  NPath := NormalizePathSep(Path);
  if not FileExists(NPath) then Exit;
  Strm := TFileStream.Create(NPath, fmOpenRead or fmShareDenyWrite);
  try
    N := Strm.Size;
    SetLength(Bytes, N);
    if N > 0 then Strm.ReadBuffer(Bytes[0], N);
  finally
    Strm.Free;
  end;
  { Drop a leading UTF-8 BOM so it doesn't surface as a stray char on line 1
    (which would break edit_file's first-line matching). }
  if (Length(Bytes) >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and (Bytes[2] = $BF) then
    Bytes := Copy(Bytes, 3, Length(Bytes) - 3);
  { Decode defensively. The old path -- TEncoding.UTF8.GetString then an
    implicit re-encode of the UnicodeString result back through the system ANSI
    codepage -- raised EEncodingError ("No mapping for the Unicode character
    exists in the target multi-byte code page") on Windows for any file
    character with no mapping in the active codepage (common with legacy 8-bit
    sources). Instead: pass valid UTF-8 through untouched, and reinterpret a
    non-UTF-8 file as Latin-1 so it still reads as text and never raises. }
  if BytesAreValidUTF8(Bytes) then
    Result := UTF8BytesToStr(Bytes)
  else
    Result := UTF8BytesToStr(Latin1BytesToUTF8(Bytes));
end;

procedure WriteFileText(const Path, Content: string);
var
  Strm: TFileStream;
  Bytes: TBytes;
  Tagged, NPath, Dir: string;
begin
  NPath := NormalizePathSep(Path);
  { Only force-create the directory when there is one -- ExtractFilePath of
    a bare filename is '', and ForceDirectories('') raises EInOutError
    "Unable to create directory". }
  Dir := ExtractFilePath(NPath);
  if Dir <> '' then EnsureDir(Dir);
  Strm := TFileStream.Create(NPath, fmCreate);
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

function NowStampWithZone: string;
const
  { Fixed English names -- FormatDateTime's 'ddd' is locale-dependent, and
    a model reading "Do" or "jeu." learns less than it should. }
  DOW: array[1..7] of string =
    ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
var
  LocalDT, UtcDT: TDateTime;
  OffsetMin, H, M: Integer;
  Sign: string;
begin
  LocalDT := Now;
  {$IFDEF FPC}
  UtcDT := LocalTimeToUniversal(LocalDT);
  {$ELSE}
  UtcDT := TTimeZone.Local.ToUniversalTime(LocalDT);
  {$ENDIF}
  { The offset IS the timezone information the model can act on -- a bare
    local time is ambiguous and a bare UTC time makes it do arithmetic to
    answer "what time is it here". Give both. }
  OffsetMin := Round((LocalDT - UtcDT) * 24 * 60);
  if OffsetMin < 0 then
  begin
    Sign := '-';
    OffsetMin := -OffsetMin;
  end
  else
    Sign := '+';
  H := OffsetMin div 60;
  M := OffsetMin mod 60;
  Result := Format('%s %s UTC%s%.2d:%.2d (%s)',
    [DOW[DayOfWeek(LocalDT)],
     FormatDateTime('yyyy"-"mm"-"dd hh":"nn":"ss', LocalDT),
     Sign, H, M,
     FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', UtcDT)]);
end;

end.
