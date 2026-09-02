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
(* Keep the TAIL of S within MaxVis visible columns by dropping whole
   leading code points. For an input line, where the cursor end is what
   the operator is looking at. Never splits a multi-byte / multi-unit
   character or a wide one. *)
function TruncateVisibleTail(const S: string; MaxVis: Integer): string;

(* Terminal cell width of one code point: 2 for East Asian Wide /
   Fullwidth (CJK, Hangul, fullwidth forms, most emoji), 0 for combining
   marks and zero-width joiners / spaces, 1 otherwise. The width helpers
   above sum this, so a line of Chinese pads and wraps in cells rather
   than in characters -- the positioned TUI overflowed its rows and
   under-padded them before, because a 3-byte 你 counted as one column
   and rendered as two. Control characters count 1, matching what the
   byte-counting version did, so nothing that passed before changes. *)
function CodePointCellWidth(CP: Integer): Integer;

(* UTF-8 by the byte, for callers that receive a byte stream -- the
   Delphi TUI on POSIX gets one byte per GetKey and has to reassemble
   the character itself. Utf8SeqLen: bytes in the sequence this lead
   byte starts (1 for ASCII, 2..4, 0 for a continuation byte or an
   invalid lead such as $C0/$C1/$F5+). Utf8DecodeCodePoint: decode a
   complete sequence, rejecting a wrong length, bad continuation bytes,
   overlong forms and surrogates. Seq holds one byte per Char so the
   same code serves an AnsiString on FPC and a UnicodeString of byte
   values on Delphi. *)
function Utf8SeqLen(Lead: Byte): Integer;
function Utf8DecodeCodePoint(const Seq: string; out CP: Integer): Boolean;
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

(* Names the SQLite binding THIS build actually uses, for the
   "index unavailable" diagnostics in memory_search / kb_search /
   session_search and their gateway equivalents.

   Those messages used to say "libsqlite3 missing or unreadable" on
   every target. That is true of the FPC build (sqldb + sqlite3conn
   resolve the shared library at runtime) and of Delphi's Linux64
   target, but it is flatly wrong for the Delphi Windows / macOS /
   mobile build: PasClaw.dpr links FireDAC.Phys.SQLiteWrapper.Stat,
   which statically links SQLite into the exe, so there is no
   sqlite3.dll for the user to go find. Sending them off to install
   one wastes their time and hides the real cause, which on that
   target is always an unwritable path or a corrupt db file.

   The result is embedded inside a parenthetical and inside the
   gateway's hand-built JSON error bodies, so it must stay free of
   double quotes and backslashes. sqlite_hint_tests enforces that. *)
function SqliteBackendHint: string;

(* Renders the reason an index failed to open, for the user-facing
   "unavailable" message.

   Detail is whatever the index captured from the exception that
   actually killed the Open -- "unable to open database file",
   "file is not a database", "cannot load SQLite client library".
   That beats any guess we could make, so it wins when present.
   SqliteBackendHint is the fallback for the paths that can return
   False without raising. *)
function SqliteOpenFailureReason(const Detail: string): string;

implementation

function SqliteBackendHint: string;
begin
  {$IFDEF FPC}
    {$IFDEF MSWINDOWS}
    Result := 'sqlite3.dll not on PATH, or not loadable';
    {$ELSE}
    Result := 'libsqlite3 not installed, or not loadable';
    {$ENDIF}
  {$ELSE}
    {$IFDEF LINUX}
    { Delphi Linux64: RAD Studio ships no static SQLite wrapper for this
      target, so PasClaw.dpr excludes it and FireDAC falls back to the
      dynamic libsqlite3.so link. }
    Result := 'libsqlite3.so not installed, or not loadable';
    {$ELSE}
    Result := 'db path unwritable or file corrupt -- SQLite is linked ' +
              'statically here, so no sqlite3.dll is involved';
    {$ENDIF}
  {$ENDIF}
end;

function SqliteOpenFailureReason(const Detail: string): string;
var
  i: Integer;
begin
  Result := Trim(Detail);
  if Result = '' then
  begin
    Result := SqliteBackendHint;
    Exit;
  end;
  { Three gateway call sites concatenate this into a hand-built JSON
    body, and driver messages are not under our control -- neutralise
    the two bytes that would break out of the string literal. Newlines
    go too: these land in one-line tool errors. }
  for i := 1 to Length(Result) do
    if (Result[i] = '"') or (Result[i] = '\') or
       (Result[i] = #10) or (Result[i] = #13) then
      Result[i] := ' ';
end;

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

function Utf8SeqLen(Lead: Byte): Integer;
begin
  if Lead < $80 then Result := 1
  else if (Lead >= $C2) and (Lead <= $DF) then Result := 2
  else if (Lead >= $E0) and (Lead <= $EF) then Result := 3
  else if (Lead >= $F0) and (Lead <= $F4) then Result := 4
  else Result := 0;
end;

function Utf8DecodeCodePoint(const Seq: string; out CP: Integer): Boolean;
var
  L, i, B: Integer;
begin
  Result := False;
  CP := 0;
  if Seq = '' then Exit;
  L := Utf8SeqLen(Ord(Seq[1]) and $FF);
  if (L = 0) or (Length(Seq) <> L) then Exit;
  B := Ord(Seq[1]) and $FF;
  case L of
    1: CP := B;
    2: CP := B and $1F;
    3: CP := B and $0F;
    4: CP := B and $07;
  end;
  for i := 2 to L do
  begin
    B := Ord(Seq[i]) and $FF;
    if (B and $C0) <> $80 then Exit;
    CP := (CP shl 6) or (B and $3F);
  end;
  { Overlong forms and UTF-16 surrogates are not valid scalar values. }
  case L of
    2: if CP < $80 then Exit;
    3: if (CP < $800) or ((CP >= $D800) and (CP <= $DFFF)) then Exit;
    4: if (CP < $10000) or (CP > $10FFFF) then Exit;
  end;
  Result := True;
end;

function CodePointCellWidth(CP: Integer): Integer;
begin
  { Zero-width: combining marks, ZW space/joiners, variation selectors. }
  if ((CP >= $0300) and (CP <= $036F)) or
     ((CP >= $200B) and (CP <= $200F)) or
     (CP = $2060) or (CP = $FEFF) or
     ((CP >= $FE00) and (CP <= $FE0F)) or
     ((CP >= $FE20) and (CP <= $FE2F)) then
    Exit(0);
  { Wide / fullwidth (East Asian Width W and F) plus the emoji blocks
    terminals draw two cells wide. }
  if ((CP >= $1100)  and (CP <= $115F))  or
     ((CP >= $2E80)  and (CP <= $A4CF) and (CP <> $303F)) or
     ((CP >= $AC00)  and (CP <= $D7A3))  or
     ((CP >= $F900)  and (CP <= $FAFF))  or
     ((CP >= $FE30)  and (CP <= $FE4F))  or
     ((CP >= $FF00)  and (CP <= $FF60))  or
     ((CP >= $FFE0)  and (CP <= $FFE6))  or
     ((CP >= $1F300) and (CP <= $1F64F)) or
     ((CP >= $1F680) and (CP <= $1F6FF)) or
     ((CP >= $1F900) and (CP <= $1FAFF)) or
     ((CP >= $20000) and (CP <= $3FFFD)) then
    Exit(2);
  Result := 1;
end;

(* Step one code point through S starting at index i (1-based), leaving
   i just past it. FPC: S is UTF-8 bytes; a stray continuation byte or a
   truncated / malformed sequence yields U+FFFD and advances one byte,
   so bad input costs one column rather than an exception. Delphi: S is
   UTF-16; a surrogate pair is combined, a lone surrogate passes through
   as itself. *)
function NextCodePoint(const S: string; var i: Integer; out CP: Integer): Boolean;
{$IFDEF FPC}
var
  L: Integer;
begin
  Result := False;
  CP := 0;
  if i > Length(S) then Exit;
  L := Utf8SeqLen(Byte(S[i]));
  if (L = 0) or (i + L - 1 > Length(S)) or
     (not Utf8DecodeCodePoint(Copy(S, i, L), CP)) then
  begin
    CP := $FFFD;
    Inc(i);
    Exit(True);
  end;
  Inc(i, L);
  Result := True;
end;
{$ELSE}
var
  W1, W2: Integer;
begin
  Result := False;
  CP := 0;
  if i > Length(S) then Exit;
  W1 := Ord(S[i]);
  Inc(i);
  if (W1 >= $D800) and (W1 <= $DBFF) and (i <= Length(S)) then
  begin
    W2 := Ord(S[i]);
    if (W2 >= $DC00) and (W2 <= $DFFF) then
    begin
      CP := $10000 + ((W1 - $D800) shl 10) + (W2 - $DC00);
      Inc(i);
      Exit(True);
    end;
  end;
  CP := W1;
  Result := True;
end;
{$ENDIF}

function VisibleLength(const S: string): Integer;
{ Strip ANSI escapes and count terminal cells. Iterates code points so a
  wide character counts two cells and a combining mark none -- see
  CodePointCellWidth for why the byte-per-column version was wrong. }
var
  i, CP: Integer;
  inEsc: Boolean;
begin
  Result := 0;
  inEsc := False;
  i := 1;
  while NextCodePoint(S, i, CP) do
  begin
    if inEsc then
    begin
      if CP = Ord('m') then inEsc := False;
      Continue;
    end;
    if CP = 27 then { ESC }
    begin
      inEsc := True;
      Continue;
    end;
    Inc(Result, CodePointCellWidth(CP));
  end;
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
  i, Start, CP, n, w: Integer;
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
    Start := i;
    if not NextCodePoint(S, i, CP) then Break;
    if inEsc then
    begin
      Result := Result + Copy(S, Start, i - Start);
      if CP = Ord('m') then inEsc := False;
      Continue;
    end;
    if CP = 27 then
    begin
      Result := Result + Copy(S, Start, i - Start);
      inEsc  := True;
      anyEsc := True;
      Continue;
    end;
    { A wide character that would straddle the boundary stays whole
      and moves to the remainder -- never half a 你 on each row. }
    w := CodePointCellWidth(CP);
    if n + w > MaxVis then
    begin
      i := Start;
      Break;
    end;
    Inc(n, w);
    Result := Result + Copy(S, Start, i - Start);
  end;
  { Emit a final ANSI reset on the prefix when we opened any
    escapes -- otherwise a wrap mid-styled-run would carry the
    color into the padding / next pane row. Cheap and idempotent. }
  if anyEsc then Result := Result + #27 + '[0m';
  if i <= Length(S) then
    Remainder := Copy(S, i, MaxInt);
end;

function TruncateVisibleTail(const S: string; MaxVis: Integer): string;
var
  i, CP: Integer;
begin
  Result := S;
  while (Result <> '') and (VisibleLength(Result) > MaxVis) do
  begin
    i := 1;
    if not NextCodePoint(Result, i, CP) then Break;
    Result := Copy(Result, i, MaxInt);
  end;
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
