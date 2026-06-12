(*
  PasClaw.Hashline - hashline diff format port for built-in fs tools.

  Hashline lets the model identify "which line to edit" by stable line-number
  anchors instead of perfect-text reproduction (which fails ~half the time
  with str_replace under spec compression). Pure-Pascal port of the format
  primitives from oh-my-pi (Apache-2.0).

  Read tool emits per file:
      ¶path/to/file#abcd
      1:first line
      2:second line
      ...

  The "abcd" is xxHash32(normalized_content, 0) & 0xffff, hex-padded to 4
  chars, so it's cheap, deterministic, and forwards-compatible with the
  upstream TS hash if anyone ever wants to share patches between tools.

  Edit tool accepts a patch shaped like:
      ¶path/to/file#abcd
      42:               <- anchor (a single line number or N-M range)
      |new replacement line(s)
      ↑a line inserted ABOVE the anchor
      ↓a line inserted BELOW the anchor

  The applier validates the header hash matches the file on disk so stale
  edits abort instead of corrupting unrelated text.

  Recovery heuristics (boundary-dup auto-absorb, structural-bracket fixups,
  comment line skipping) from upstream are deliberately omitted in this port;
  they only matter once production traffic surfaces the failure modes they
  were written to handle. The format and the basic apply path are
  faithful so we can add them incrementally.
*)
unit PasClaw.Hashline;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}            { Tag this unit's AnsiStrings as CP_UTF8
                                so concatenation results
                                (FormatHashlineHeader's `HL_FILE_PREFIX
                                + FilePath + ...`) carry CP_UTF8 instead
                                of defaulting to the system ANSI codepage.
                                Without this, on Windows the JSON
                                serialiser downstream treats the bytes
                                as CP1252 and re-encodes them to UTF-8 --
                                that's how the bytes for `¶` (0xC2 0xB6)
                                turned into `Â¶` (0xC3 0x82 0xC2 0xB6) in
                                fs_read tool results. The special-char
                                constants below sidestep the
                                directive's literal-promotion gotcha by
                                being spelled as raw byte sequences. }
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes;

const
  (* Use literal Unicode characters so each compiler stores them in its
     native string form: Delphi UnicodeString = one WideChar per
     codepoint, FPC mode-delphi UTF-8 AnsiString = multi-byte encoding.
     Length() and Copy() are unit-consistent per compiler (chars in
     Delphi, bytes in FPC), so the same parsing code works in both.

     FPC-side: byte literals (#$NN sequences) avoid any source
     codepage interpretation. The .pas file is saved as UTF-8 on
     disk, but FPC's default source codepage on Windows is CP1252
     (or other system ANSI), which would read the UTF-8 bytes of
     '¶' (0xC2 0xB6) as two separate Latin-1 chars and tag the
     AnsiString as CP1252. When that string later flowed through
     fs_read into the model's tool result, downstream UTF-8
     re-encoding turned `¶` into `Â¶`. Spelling the bytes explicitly
     bypasses the source-codepage step entirely and we additionally
     tag the resulting AnsiString as CP_UTF8 via SetCodePage at
     unit initialization, so the bytes round-trip through the JSON
     serialiser as proper UTF-8. *)
  {$IFDEF FPC}
  HL_FILE_HASH_SEP   = '#';
  HL_LINE_BODY_SEP   = ':';
  HL_OP_REPLACE      = ':';
  HL_PAYLOAD_REPLACE = '|';
  {$ELSE}
  HL_FILE_PREFIX     = '¶';
  HL_FILE_HASH_SEP   = '#';
  HL_LINE_BODY_SEP   = ':';
  HL_OP_REPLACE      = ':';
  HL_PAYLOAD_REPLACE = '|';
  HL_PAYLOAD_ABOVE   = '↑';
  HL_PAYLOAD_BELOW   = '↓';
  {$ENDIF}

  {$IFDEF FPC}
  { UTF-8 byte sequences spelled out to bypass source-codepage
    interpretation. ¶ U+00B6 = 0xC2 0xB6. ↑ U+2191 = 0xE2 0x86 0x91.
    ↓ U+2193 = 0xE2 0x86 0x93. Constants are AnsiString here; the
    initialization section below SetCodePages each to CP_UTF8 so
    downstream code (JSON serialisation, etc.) treats the bytes as
    UTF-8 instead of re-encoding via the system ANSI codepage. }
  HL_FILE_PREFIX:     AnsiString = #$C2#$B6;
  HL_PAYLOAD_ABOVE:   AnsiString = #$E2#$86#$91;
  HL_PAYLOAD_BELOW:   AnsiString = #$E2#$86#$93;
  {$ENDIF}
  HL_FILE_HASH_LEN   = 4;

type
  THLPayloadKind = (hpkReplace, hpkAbove, hpkBelow);

  THLEditKind = (hekInsert, hekDelete);

  THLAnchor = record
    LineNum: Integer;       { 1-indexed }
  end;

  THLEdit = record
    Kind:        THLEditKind;
    Anchor:      THLAnchor; { for Delete; for Insert when Cursor is before/after }
    Text:        string;    { for Insert }
    PayloadKind: THLPayloadKind;
    SourceLine:  Integer;   { line number in the patch text, for diagnostics }
  end;

  THLEditArray = array of THLEdit;

  THLSection = record
    Path:         string;
    HasFileHash:  Boolean;
    FileHash:     string;
    Edits:        THLEditArray;
  end;

  THLSectionArray = array of THLSection;

{ Low-level format helpers. }
function ComputeFileHash(const Content: string): string;
function FormatHashlineHeader(const FilePath, FileHash: string): string;
function FormatNumberedLine(LineNumber: Integer; const LineText: string): string;
function FormatNumberedLines(const Text: string; StartLine: Integer): string;
function FormatHashlineRead(const FilePath, Content: string): string;

{ Returns True if every non-empty content line in the input carries the
  `LINENO:` prefix; in that case the prefixes are stripped in place.
  Used by fs_write to defend against the model echoing read-output prefixes
  back into a file body. }
function StripHashlinePrefixes(var Lines: TStringList): Boolean;

{ Patch parser + applier. The high-level entry point reads the file,
  validates the header hash, applies the edits, and returns the new text.
  ErrMsg carries any structural complaint; the file is never partially
  written. }
function ParseHashlinePatch(const PatchText: string;
                            out Sections: THLSectionArray;
                            out ErrMsg: string): Boolean;
function ValidateHashlinePatchGrammar(const PatchText: string;
                                      out ErrMsg: string): Boolean;
function ApplyHashlineEdits(const Original: string;
                            const Edits: THLEditArray;
                            out NewText: string;
                            out ErrMsg: string): Boolean;

implementation

uses
  Math;

{ ============================ xxHash32 =========================== }
{ Lightweight 32-bit xxHash implementation matching upstream Bun.hash so
  hashes are interchangeable. Operates on a TBytes buffer to avoid the
  AnsiString/UnicodeString divergence between FPC and Delphi. }

const
  PRIME32_1 : Cardinal = 2654435761;
  PRIME32_2 : Cardinal = 2246822519;
  PRIME32_3 : Cardinal = 3266489917;
  PRIME32_4 : Cardinal =  668265263;
  PRIME32_5 : Cardinal =  374761393;

function RotL32(X: Cardinal; N: Byte): Cardinal; inline;
begin
  Result := (X shl N) or (X shr (32 - N));
end;

function ReadLE32(const Data: TBytes; Pos: Integer): Cardinal; inline;
begin
  Result := Cardinal(Data[Pos])
         or (Cardinal(Data[Pos + 1]) shl 8)
         or (Cardinal(Data[Pos + 2]) shl 16)
         or (Cardinal(Data[Pos + 3]) shl 24);
end;

function XXHash32(const Data: TBytes; Seed: Cardinal): Cardinal;
var
  v1, v2, v3, v4, h32: Cardinal;
  len, p, limit: Integer;
begin
  len := Length(Data);
  p := 0;
  if len >= 16 then
  begin
    v1 := Seed + PRIME32_1 + PRIME32_2;
    v2 := Seed + PRIME32_2;
    v3 := Seed;
    v4 := Seed - PRIME32_1;
    limit := len - 16;
    while p <= limit do
    begin
      v1 := v1 + ReadLE32(Data, p     ) * PRIME32_2; v1 := RotL32(v1, 13); v1 := v1 * PRIME32_1;
      v2 := v2 + ReadLE32(Data, p +  4) * PRIME32_2; v2 := RotL32(v2, 13); v2 := v2 * PRIME32_1;
      v3 := v3 + ReadLE32(Data, p +  8) * PRIME32_2; v3 := RotL32(v3, 13); v3 := v3 * PRIME32_1;
      v4 := v4 + ReadLE32(Data, p + 12) * PRIME32_2; v4 := RotL32(v4, 13); v4 := v4 * PRIME32_1;
      Inc(p, 16);
    end;
    h32 := RotL32(v1, 1) + RotL32(v2, 7) + RotL32(v3, 12) + RotL32(v4, 18);
  end
  else
    h32 := Seed + PRIME32_5;

  h32 := h32 + Cardinal(len);

  while p + 4 <= len do
  begin
    h32 := h32 + ReadLE32(Data, p) * PRIME32_3;
    h32 := RotL32(h32, 17) * PRIME32_4;
    Inc(p, 4);
  end;
  while p < len do
  begin
    h32 := h32 + Cardinal(Data[p]) * PRIME32_5;
    h32 := RotL32(h32, 11) * PRIME32_1;
    Inc(p);
  end;

  h32 := h32 xor (h32 shr 15);
  h32 := h32 * PRIME32_2;
  h32 := h32 xor (h32 shr 13);
  h32 := h32 * PRIME32_3;
  h32 := h32 xor (h32 shr 16);

  Result := h32;
end;

{ ====================== Normalization + hashing ====================== }

function NormalizeForHash(const Text: string): string;
{ Match upstream: strip CR, trim each line's trailing whitespace, rejoin
  with LF. Keeps anchors stable across CRLF/LF mixes and editors that
  trim on save. }
var
  Lines: TStringList;
  i: Integer;
  Tmp: string;
begin
  Tmp := StringReplace(Text, #13, '', [rfReplaceAll]);
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.StrictDelimiter := True;
    Lines.Text := Tmp;
    for i := 0 to Lines.Count - 1 do
      Lines[i] := TrimRight(Lines[i]);
    Result := Lines.Text;
    { TStringList.Text may append a trailing LF; trim it if Text didn't. }
    if (Length(Tmp) = 0) or ((Tmp[Length(Tmp)] <> #10)) then
      if (Length(Result) > 0) and (Result[Length(Result)] = #10) then
        SetLength(Result, Length(Result) - 1);
  finally
    Lines.Free;
  end;
end;

function ComputeFileHash(const Content: string): string;
var
  Norm: string;
  Bytes: TBytes;
  Hash: Cardinal;
  Low16: Cardinal;
begin
  Norm := NormalizeForHash(Content);
  Bytes := TEncoding.UTF8.GetBytes(Norm);
  Hash := XXHash32(Bytes, 0);
  Low16 := Hash and $FFFF;
  Result := LowerCase(IntToHex(Integer(Low16), HL_FILE_HASH_LEN));
end;

{ ========================== Format helpers ========================== }

function FormatHashlineHeader(const FilePath, FileHash: string): string;
begin
  Result := HL_FILE_PREFIX + FilePath + HL_FILE_HASH_SEP + FileHash;
  {$IFDEF FPC}
  { Concatenating an AnsiString(CP_UTF8) with strings tagged at the
    system's default codepage produces a Result tagged CP=0 ("use
    DefaultSystemCodepage") even though the bytes are valid UTF-8.
    On Windows that DefaultSystemCodepage is the system ANSI CP
    (CP1252 on English, etc.), so downstream JSON serialisation
    transcodes our UTF-8 bytes as if they were CP1252 chars --
    that's how `¶` (0xC2 0xB6) flips to `Â¶` (0xC3 0x82 0xC2 0xB6)
    in fs_read output. Stamp the result as CP_UTF8 so the
    downstream serialiser passes the bytes through verbatim. }
  SetCodePage(RawByteString(Result), CP_UTF8, False);
  {$ENDIF}
end;

function FormatNumberedLine(LineNumber: Integer; const LineText: string): string;
begin
  Result := IntToStr(LineNumber) + HL_LINE_BODY_SEP + LineText;
end;

function FormatNumberedLines(const Text: string; StartLine: Integer): string;
var
  Lines: TStringList;
  i: Integer;
  Sb: TStringBuilder;
begin
  Lines := TStringList.Create;
  Sb := TStringBuilder.Create;
  try
    Lines.LineBreak := #10;
    Lines.StrictDelimiter := True;
    Lines.Text := StringReplace(Text, #13, '', [rfReplaceAll]);
    for i := 0 to Lines.Count - 1 do
    begin
      if i > 0 then Sb.Append(#10);
      Sb.Append(FormatNumberedLine(StartLine + i, Lines[i]));
    end;
    Result := Sb.ToString;
  finally
    Sb.Free;
    Lines.Free;
  end;
end;

function FormatHashlineRead(const FilePath, Content: string): string;
begin
  Result := FormatHashlineHeader(FilePath, ComputeFileHash(Content)) + #10 +
            FormatNumberedLines(Content, 1);
end;

{ ====================== Prefix stripping (defensive) ====================== }

function LineLooksHashlinePrefixed(const Line: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if Line = '' then Exit;
  i := 1;
  while (i <= Length(Line)) and (Line[i] = ' ') do Inc(i);
  if (i > Length(Line)) or not ((Line[i] >= '0') and (Line[i] <= '9')) then Exit;
  while (i <= Length(Line)) and (Line[i] >= '0') and (Line[i] <= '9') do Inc(i);
  Result := (i <= Length(Line)) and (Line[i] = ':');
end;

function StripPrefixFromLine(const Line: string): string;
var
  i: Integer;
begin
  i := 1;
  while (i <= Length(Line)) and (Line[i] = ' ') do Inc(i);
  while (i <= Length(Line)) and (Line[i] >= '0') and (Line[i] <= '9') do Inc(i);
  if (i <= Length(Line)) and (Line[i] = ':') then Inc(i);
  Result := Copy(Line, i, MaxInt);
end;

function StripHashlinePrefixes(var Lines: TStringList): Boolean;
var
  i, NonEmpty, Prefixed: Integer;
begin
  Result := False;
  NonEmpty := 0;
  Prefixed := 0;
  for i := 0 to Lines.Count - 1 do
    if Trim(Lines[i]) <> '' then
    begin
      Inc(NonEmpty);
      if LineLooksHashlinePrefixed(Lines[i]) then Inc(Prefixed);
    end;
  if (NonEmpty = 0) or (Prefixed < NonEmpty) then Exit;
  for i := 0 to Lines.Count - 1 do
    if LineLooksHashlinePrefixed(Lines[i]) then
      Lines[i] := StripPrefixFromLine(Lines[i]);
  Result := True;
end;

{ ============================ Patch parser ============================ }

type
  TPendingBlock = record
    HasAnchor:   Boolean;
    RangeStart:  Integer;
    RangeEnd:    Integer;
    SourceLine:  Integer;
    Replaces:    array of string;
    AboveLines:  array of string;
    BelowLines:  array of string;
  end;

procedure ResetBlock(var B: TPendingBlock);
begin
  B.HasAnchor   := False;
  B.RangeStart  := 0;
  B.RangeEnd    := 0;
  B.SourceLine  := 0;
  SetLength(B.Replaces,   0);
  SetLength(B.AboveLines, 0);
  SetLength(B.BelowLines, 0);
end;

function StartsWith(const S, Prefix: string): Boolean; inline;
begin
  Result := (Length(S) >= Length(Prefix)) and
            (Copy(S, 1, Length(Prefix)) = Prefix);
end;

function TryParseAnchor(const Line: string; out RangeStart, RangeEnd: Integer): Boolean;
{ Anchor lines look like `42:` or `7-10:` (with optional decoration like
  `>` or `*` that we ignore). Returns False for anything else. }
var
  i, n: Integer;
  StartStr, EndStr: string;
begin
  Result := False;
  RangeStart := 0;
  RangeEnd := 0;
  n := Length(Line);
  i := 1;
  while (i <= n) and ((Line[i] = ' ') or (Line[i] = #9) or
                       (Line[i] = '>') or (Line[i] = '-') or (Line[i] = '*')) do Inc(i);
  if (i > n) or not ((Line[i] >= '1') and (Line[i] <= '9')) then Exit;
  StartStr := '';
  while (i <= n) and (Line[i] >= '0') and (Line[i] <= '9') do
  begin
    StartStr := StartStr + Line[i];
    Inc(i);
  end;
  if (i <= n) and (Line[i] = '-') then
  begin
    Inc(i);
    EndStr := '';
    while (i <= n) and (Line[i] >= '0') and (Line[i] <= '9') do
    begin
      EndStr := EndStr + Line[i];
      Inc(i);
    end;
  end
  else
    EndStr := StartStr;
  if (i > n) or (Line[i] <> ':') then Exit;
  { trailing chars (we tolerate trailing spaces only) }
  Inc(i);
  while (i <= n) and (Line[i] = ' ') do Inc(i);
  if i <= n then Exit;
  RangeStart := StrToIntDef(StartStr, 0);
  RangeEnd   := StrToIntDef(EndStr,   0);
  Result := (RangeStart > 0) and (RangeEnd >= RangeStart);
end;

function TryParsePayload(const Line: string; out Kind: THLPayloadKind;
                         out Body: string): Boolean;
begin
  Result := True;
  if StartsWith(Line, HL_PAYLOAD_ABOVE) then
  begin
    Kind := hpkAbove;
    Body := Copy(Line, Length(HL_PAYLOAD_ABOVE) + 1, MaxInt);
  end
  else if StartsWith(Line, HL_PAYLOAD_BELOW) then
  begin
    Kind := hpkBelow;
    Body := Copy(Line, Length(HL_PAYLOAD_BELOW) + 1, MaxInt);
  end
  else if (Line <> '') and (Line[1] = HL_PAYLOAD_REPLACE) then
  begin
    Kind := hpkReplace;
    Body := Copy(Line, 2, MaxInt);
  end
  else
    Result := False;
end;

function TryParseHeader(const Line: string; out Path, Hash: string;
                        out HasHash: Boolean): Boolean;
{ Header looks like `¶path/to/file` or `¶path/to/file#abcd`. }
var
  Body: string;
  Sep: Integer;
begin
  Result := False;
  Path := '';
  Hash := '';
  HasHash := False;
  if not StartsWith(Line, HL_FILE_PREFIX) then Exit;
  Body := TrimRight(Copy(Line, Length(HL_FILE_PREFIX) + 1, MaxInt));
  if Body = '' then Exit;
  Sep := -1;
  if Length(Body) > HL_FILE_HASH_LEN then
    if Body[Length(Body) - HL_FILE_HASH_LEN] = HL_FILE_HASH_SEP then
      Sep := Length(Body) - HL_FILE_HASH_LEN;
  if Sep > 0 then
  begin
    Path := Copy(Body, 1, Sep - 1);
    Hash := LowerCase(Copy(Body, Sep + 1, HL_FILE_HASH_LEN));
    HasHash := True;
  end
  else
    Path := Body;
  Result := Path <> '';
end;

procedure FlushBlock(var B: TPendingBlock; var Edits: THLEditArray);
var
  i, Idx: Integer;
begin
  if not B.HasAnchor then Exit;
  { Above-inserts go in front of the anchor. }
  for i := 0 to High(B.AboveLines) do
  begin
    Idx := Length(Edits);
    SetLength(Edits, Idx + 1);
    Edits[Idx].Kind        := hekInsert;
    Edits[Idx].Anchor.LineNum := B.RangeStart;
    Edits[Idx].PayloadKind := hpkAbove;
    Edits[Idx].Text        := B.AboveLines[i];
    Edits[Idx].SourceLine  := B.SourceLine;
  end;
  { Replace = delete the anchored range + insert payloads in its place. }
  if Length(B.Replaces) > 0 then
  begin
    for i := B.RangeStart to B.RangeEnd do
    begin
      Idx := Length(Edits);
      SetLength(Edits, Idx + 1);
      Edits[Idx].Kind        := hekDelete;
      Edits[Idx].Anchor.LineNum := i;
      Edits[Idx].PayloadKind := hpkReplace;
      Edits[Idx].SourceLine  := B.SourceLine;
    end;
    for i := 0 to High(B.Replaces) do
    begin
      Idx := Length(Edits);
      SetLength(Edits, Idx + 1);
      Edits[Idx].Kind        := hekInsert;
      Edits[Idx].Anchor.LineNum := B.RangeStart;
      Edits[Idx].PayloadKind := hpkReplace;
      Edits[Idx].Text        := B.Replaces[i];
      Edits[Idx].SourceLine  := B.SourceLine;
    end;
  end;
  { Below-inserts go after the last anchor line. }
  for i := 0 to High(B.BelowLines) do
  begin
    Idx := Length(Edits);
    SetLength(Edits, Idx + 1);
    Edits[Idx].Kind        := hekInsert;
    Edits[Idx].Anchor.LineNum := B.RangeEnd + 1;
    Edits[Idx].PayloadKind := hpkBelow;
    Edits[Idx].Text        := B.BelowLines[i];
    Edits[Idx].SourceLine  := B.SourceLine;
  end;
  ResetBlock(B);
end;

function ParseHashlinePatch(const PatchText: string;
                            out Sections: THLSectionArray;
                            out ErrMsg: string): Boolean;
var
  Lines: TStringList;
  i, SectionIdx: Integer;
  Block: TPendingBlock;
  CurEdits: THLEditArray;
  Path, Hash, Body: string;
  HasHash, Started: Boolean;
  Kind: THLPayloadKind;
  RangeStart, RangeEnd: Integer;
begin
  Result := False;
  ErrMsg := '';
  SetLength(Sections, 0);
  SectionIdx := -1;
  Started := False;
  ResetBlock(Block);
  SetLength(CurEdits, 0);
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.StrictDelimiter := True;
    Lines.Text := StringReplace(PatchText, #13, '', [rfReplaceAll]);
    for i := 0 to Lines.Count - 1 do
    begin
      if TryParseHeader(Lines[i], Path, Hash, HasHash) then
      begin
        if Started then
        begin
          FlushBlock(Block, CurEdits);
          Sections[SectionIdx].Edits := CurEdits;
          SetLength(CurEdits, 0);
        end;
        Inc(SectionIdx);
        SetLength(Sections, SectionIdx + 1);
        Sections[SectionIdx].Path        := Path;
        Sections[SectionIdx].FileHash    := Hash;
        Sections[SectionIdx].HasFileHash := HasHash;
        Started := True;
        Continue;
      end;
      if not Started then
      begin
        { Ignore leading whitespace/comment lines outside a section. }
        if Trim(Lines[i]) = '' then Continue;
        if (Lines[i] <> '') and (Lines[i][1] = '#') then Continue;
        ErrMsg := Format('line %d: content before any %sPATH header', [i + 1, HL_FILE_PREFIX]);
        Exit;
      end;
      if TryParseAnchor(Lines[i], RangeStart, RangeEnd) then
      begin
        FlushBlock(Block, CurEdits);
        Block.HasAnchor  := True;
        Block.RangeStart := RangeStart;
        Block.RangeEnd   := RangeEnd;
        Block.SourceLine := i + 1;
        Continue;
      end;
      if TryParsePayload(Lines[i], Kind, Body) then
      begin
        if not Block.HasAnchor then
        begin
          ErrMsg := Format('line %d: payload without an anchor', [i + 1]);
          Exit;
        end;
        case Kind of
          hpkReplace:
            begin
              SetLength(Block.Replaces, Length(Block.Replaces) + 1);
              Block.Replaces[High(Block.Replaces)] := Body;
            end;
          hpkAbove:
            begin
              SetLength(Block.AboveLines, Length(Block.AboveLines) + 1);
              Block.AboveLines[High(Block.AboveLines)] := Body;
            end;
          hpkBelow:
            begin
              SetLength(Block.BelowLines, Length(Block.BelowLines) + 1);
              Block.BelowLines[High(Block.BelowLines)] := Body;
            end;
        end;
        Continue;
      end;
      if Trim(Lines[i]) = '' then Continue;
      if (Lines[i] <> '') and (Lines[i][1] = '#') then Continue;
      ErrMsg := Format('line %d: unrecognized content %s', [i + 1, QuotedStr(Lines[i])]);
      Exit;
    end;
    if Started then
    begin
      FlushBlock(Block, CurEdits);
      Sections[SectionIdx].Edits := CurEdits;
    end;
    Result := True;
  finally
    Lines.Free;
  end;
end;

function ValidateHashlinePatchGrammar(const PatchText: string;
                                      out ErrMsg: string): Boolean;
{ HL_PAYLOAD_ABOVE / HL_PAYLOAD_BELOW are multi-byte UTF-8 sequences
  in FPC mode delphi (where Char = AnsiChar, single byte) and single
  WideChars in Delphi. `L[p+1] = HL_PAYLOAD_BELOW` compares one
  AnsiChar against a 3-byte string under FPC and never matches --
  the validator silently accepted "60:↓bad inline payload" instead
  of flagging it, and the canonical inline-payload check became
  Delphi-only. Use Copy(L, p+1, Length(MARKER)) so the comparison
  works in byte units on FPC and char units on Delphi without
  changing semantics on either side. Same reason the error-message
  Copy uses Length(Match) instead of a hard-coded 2 -- under FPC
  Copy(L, p, 2) only catches `:` plus the first byte of `↓`, so
  the reported snippet would be a truncated mojibake. }
var
  Lines: TStringList;
  i, p, j: Integer;
  L, Match: string;
begin
  Result := False;
  ErrMsg := '';
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.StrictDelimiter := True;
    Lines.Text := StringReplace(PatchText, #13, '', [rfReplaceAll]);
    for i := 0 to Lines.Count - 1 do
    begin
      L := Lines[i];
      p := Pos(':', L);
      if p <= 0 then Continue;
      if p >= Length(L) then Continue;
      Match := '';
      if Copy(L, p + 1, Length(HL_PAYLOAD_ABOVE)) = HL_PAYLOAD_ABOVE then
        Match := HL_PAYLOAD_ABOVE
      else if Copy(L, p + 1, Length(HL_PAYLOAD_BELOW)) = HL_PAYLOAD_BELOW then
        Match := HL_PAYLOAD_BELOW
      else if Copy(L, p + 1, Length(HL_PAYLOAD_REPLACE)) = HL_PAYLOAD_REPLACE then
        Match := HL_PAYLOAD_REPLACE;
      if Match = '' then Continue;
      j := p - 1;
      { CharInSet vs bare `in [...]` silences dcc64 W1050: on the
        modern Delphi compiler L[j] is WideChar and the byte-char
        set literal narrows implicitly. Same fix shape as PR #177
        applied to Channels.Email. }
      while (j >= 1) and CharInSet(L[j], ['0'..'9']) do Dec(j);
      if (j = 0) or ((j >= 1) and (L[j] = '-')) then
      begin
        ErrMsg := Format('line %d: unsupported inline payload token near "%s"; use canonical grammar with anchor on its own line and payload lines beginning with %s/%s/%s',
                         [i + 1, Copy(L, p, 1 + Length(Match)),
                          HL_PAYLOAD_REPLACE, HL_PAYLOAD_ABOVE, HL_PAYLOAD_BELOW]);
        Exit;
      end;
    end;
    Result := True;
  finally
    Lines.Free;
  end;
end;

{ ============================ Patch applier ============================ }

function ApplyHashlineEdits(const Original: string;
                            const Edits: THLEditArray;
                            out NewText: string;
                            out ErrMsg: string): Boolean;
{ Two-pass apply:
    1. Walk edits in source order; mark deletes and bucket inserts by
       (anchor-line, position-relative-to-anchor).
    2. Rebuild output line-by-line: for each kept original line, emit
       before-inserts -> the line itself -> after-inserts. Pure-insert
       blocks at line N stash their payload into the same buckets. }
var
  Src: TStringList;
  Deletes: array of Boolean;
  Before:  array of TStringList;
  After:   array of TStringList;
  Sb: TStringBuilder;
  Norm: string;
  i, j, N: Integer;
  E: THLEdit;
  Idx: Integer;
  HadTrailingNewline: Boolean;
begin
  Result := False;
  ErrMsg := '';
  Norm := StringReplace(Original, #13, '', [rfReplaceAll]);
  HadTrailingNewline := (Norm <> '') and (Norm[Length(Norm)] = #10);

  Src := TStringList.Create;
  Sb  := nil;
  try
    Src.LineBreak := #10;
    Src.StrictDelimiter := True;
    Src.Text := Norm;
    N := Src.Count;

    SetLength(Deletes, N);
    SetLength(Before,  N + 2);
    SetLength(After,   N + 2);
    for i := 0 to N - 1 do Deletes[i] := False;

    for i := 0 to High(Edits) do
    begin
      E := Edits[i];
      case E.Kind of
        hekDelete:
          begin
            Idx := E.Anchor.LineNum - 1;
            if (Idx < 0) or (Idx >= N) then
            begin
              ErrMsg := Format('patch line %d: delete anchor %d out of range (file has %d lines)',
                               [E.SourceLine, E.Anchor.LineNum, N]);
              Exit;
            end;
            Deletes[Idx] := True;
          end;
        hekInsert:
          begin
            Idx := E.Anchor.LineNum - 1;
            case E.PayloadKind of
              hpkAbove, hpkReplace:
                begin
                  if (Idx < 0) or (Idx >= N) then
                  begin
                    if Idx = N then { allow insert past end as "append" }
                    begin
                      if After[N] = nil then After[N] := TStringList.Create;
                      After[N].Add(E.Text);
                    end
                    else
                    begin
                      ErrMsg := Format('patch line %d: insert anchor %d out of range (file has %d lines)',
                                       [E.SourceLine, E.Anchor.LineNum, N]);
                      Exit;
                    end;
                  end
                  else
                  begin
                    if Before[Idx] = nil then Before[Idx] := TStringList.Create;
                    Before[Idx].Add(E.Text);
                  end;
                end;
              hpkBelow:
                begin
                  { Anchor.LineNum is RangeEnd+1; emit after the previous line. }
                  if (Idx - 1 < 0) or (Idx - 1 >= N) then
                  begin
                    if Idx - 1 = N - 1 then
                    begin
                      if After[N - 1] = nil then After[N - 1] := TStringList.Create;
                      After[N - 1].Add(E.Text);
                    end
                    else if Idx = N then
                    begin
                      if After[N - 1] = nil then After[N - 1] := TStringList.Create;
                      After[N - 1].Add(E.Text);
                    end
                    else
                    begin
                      ErrMsg := Format('patch line %d: below-insert anchor %d out of range',
                                       [E.SourceLine, E.Anchor.LineNum]);
                      Exit;
                    end;
                  end
                  else
                  begin
                    if After[Idx - 1] = nil then After[Idx - 1] := TStringList.Create;
                    After[Idx - 1].Add(E.Text);
                  end;
                end;
            end;
          end;
      end;
    end;

    Sb := TStringBuilder.Create;
    for i := 0 to N - 1 do
    begin
      if (Before[i] <> nil) then
        for j := 0 to Before[i].Count - 1 do
        begin
          if Sb.Length > 0 then Sb.Append(#10);
          Sb.Append(Before[i][j]);
        end;
      if not Deletes[i] then
      begin
        if Sb.Length > 0 then Sb.Append(#10);
        Sb.Append(Src[i]);
      end;
      if (After[i] <> nil) then
        for j := 0 to After[i].Count - 1 do
        begin
          if Sb.Length > 0 then Sb.Append(#10);
          Sb.Append(After[i][j]);
        end;
    end;
    { Trailing After[N] catches pure-append inserts. }
    if (After[N] <> nil) then
      for j := 0 to After[N].Count - 1 do
      begin
        if Sb.Length > 0 then Sb.Append(#10);
        Sb.Append(After[N][j]);
      end;
    NewText := Sb.ToString;
    if HadTrailingNewline and ((NewText = '') or (NewText[Length(NewText)] <> #10)) then
      NewText := NewText + #10;
    Result := True;
  finally
    for i := 0 to High(Before) do if Before[i] <> nil then Before[i].Free;
    for i := 0 to High(After)  do if After[i]  <> nil then After[i].Free;
    if Sb <> nil then Sb.Free;
    Src.Free;
  end;
end;

{$IFDEF FPC}
initialization
  { Tag the byte-literal AnsiString constants as CP_UTF8 so when
    they reach the JSON serialiser (via hashline headers in fs_read
    output, etc.) the bytes are treated as the UTF-8 sequences they
    are -- not re-encoded as if they were the system ANSI codepage,
    which is what produced "Â¶..." instead of "¶..." on Windows. }
  SetCodePage(RawByteString(HL_FILE_PREFIX),   CP_UTF8, False);
  SetCodePage(RawByteString(HL_PAYLOAD_ABOVE), CP_UTF8, False);
  SetCodePage(RawByteString(HL_PAYLOAD_BELOW), CP_UTF8, False);
{$ENDIF}

end.
