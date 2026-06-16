unit PasClaw.KB.PDF.Parser;

(*
  PasClaw.KB.PDF.Parser - port of the upstream pdftotext PDF parser
  (https://github.com/FMXExpress/pdftotext), brought in here at the
  author's explicit request to give the KB ingest pipeline native PDF
  support without an external dependency.

  Handles: PDF text streams (with /FlateDecode), per-font /ToUnicode
  CMaps for Type0/CID + simple fonts (beginbfchar / beginbfrange),
  resource font tables (BT/ET blocks), CP1252 byte fallback, PDF
  string escapes (octal, hex, UTF-16BE BOM), and metadata extraction
  (/Title, /Author, /Creator, /Producer, page count).
*)

{ Use delphiunicode under FPC so that `string` is UnicodeString and `Char` is
  WideChar, matching Delphi semantics (required for /ToUnicode decoding). }
{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

interface

uses
{$IFDEF FPC}
  Classes, SysUtils, StrUtils, Character,
  Generics.Collections, Generics.Defaults,
  PasClaw.KB.PDF.Compat;
{$ELSE}
  System.Classes, System.SysUtils, System.RegularExpressions,
  System.Generics.Collections, System.IOUtils, System.StrUtils, System.Character,
  PasClaw.KB.PDF.Compat;
{$ENDIF}

type
  TPDFMetadata = record
    Title: string;
    Author: string;
    Creator: string;
    Producer: string;
    PageCount: Integer;
    CharCount: Integer;
    WordCount: Integer;
  end;

  { Per-font /ToUnicode mapping. For Type0/CID fonts (Identity-H) character
    codes are two bytes wide; for simple fonts they are a single byte. The
    ToUni map translates a character code into the actual Unicode string. }
  TFontInfo = class
  public
    TwoByte: Boolean;
    ToUni: TDictionary<Integer, string>;
    constructor Create;
    destructor Destroy; override;
  end;

  TPDFParser = class
  private
    class function BytesToString(const Bytes: TBytes): string; static;
    class function DecompressFlate(const InputBytes: TBytes): TBytes; static;
    class function GetPrecedingDictionary(const S: string; StreamIdx: Integer): string; static;
    class function DecodeHexPDFString(const HexStr: string): string; static;
    class function ParseTextOperators(const BlockS: string;
      const ResFontMap: TDictionary<string, Integer>;
      const Fonts: TObjectDictionary<Integer, TFontInfo>): string; static;
    class function CollapseWhitespace(const Line: string): string; static;
    class function CleanText(const S: string): string; static;
    class function ExtractMetaValue(const S, Key: string): string; static;
    class function ExtractPageCount(const S: string): Integer; static;
    class function CountWords(const S: string): Integer; static;
    class function GetPageContentStreamIDs(const S: string; MaxPages: Integer; const PagesRange: string; out PageCounts: Integer): TList<Integer>; static;
    class function CP1252ByteToChar(B: Byte): Char; static;
    class function DecodePDFString(const S: string): string; static;
    class function HexToRawBytes(const HexStr: string): string; static;
    class function ParseToUnicodeCMap(const CMapStr: string): TDictionary<Integer, string>; static;
    class function BuildObjectIndex(const S: string): TDictionary<Integer, Integer>; static;
    class function GetObjectStreamData(const S: string; const Bytes: TBytes;
      const ObjIndex: TDictionary<Integer, Integer>; ObjID: Integer): TBytes; static;
    class procedure BuildFonts(const S: string; const Bytes: TBytes;
      const ObjIndex: TDictionary<Integer, Integer>;
      const Fonts: TObjectDictionary<Integer, TFontInfo>); static;
    class function BuildResourceFontMap(const S: string;
      const Fonts: TObjectDictionary<Integer, TFontInfo>): TDictionary<string, Integer>; static;
    class function DecodeStringBytes(const Raw: string; Font: TFontInfo): string; static;
  public
    class function IsPageInRange(const PageIdx: Integer; const RangeStr: string): Boolean; static;
    class function IsValidPDFHeader(const FilePath: string): Boolean; static;
    class function ExtractTextAndMetadata(const FilePath: string; out Text: string; out Meta: TPDFMetadata; const MaxPages: Integer = 0; const PagesRange: string = ''): Boolean;
  end;

implementation

{ TFontInfo }

constructor TFontInfo.Create;
begin
  inherited Create;
  TwoByte := False;
  ToUni := nil;
end;

destructor TFontInfo.Destroy;
begin
  if Assigned(ToUni) then
    ToUni.Free;
  inherited Destroy;
end;

{ Split a string on any of the given delimiter characters. Portable replacement
  for the Delphi-only TStringHelper.Split (not available under FPC). }
function SplitChars(const S: string; const Delims: array of Char): TArray<string>;
var
  I, Start: Integer;
  D: Char;
  IsDelim: Boolean;
begin
  SetLength(Result, 0);
  Start := 1;
  for I := 1 to Length(S) do
  begin
    IsDelim := False;
    for D in Delims do
      if S[I] = D then
      begin
        IsDelim := True;
        Break;
      end;
    if IsDelim then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(S, Start, I - Start);
      Start := I + 1;
    end;
  end;
  SetLength(Result, Length(Result) + 1);
  Result[High(Result)] := Copy(S, Start, Length(S) - Start + 1);
end;

{ Join lines with the platform line break. Uses a TList<string> (which stores
  real UnicodeStrings under both Delphi and FPC) rather than TStringList/
  TStringBuilder, whose FPC implementations are AnsiString-backed and would
  lose code points above U+00FF. }
function JoinLines(const Lines: TList<string>): string;
var
  I, Total, P, BreakLen: Integer;
  L, Brk: string;
begin
  Result := '';
  Brk := sLineBreak;
  BreakLen := Length(Brk);
  Total := 0;
  for I := 0 to Lines.Count - 1 do
    Inc(Total, Length(Lines[I]) + BreakLen);
  if Total = 0 then Exit;

  SetLength(Result, Total);
  P := 1;
  for I := 0 to Lines.Count - 1 do
  begin
    L := Lines[I];
    if Length(L) > 0 then
    begin
      Move(L[1], Result[P], Length(L) * SizeOf(Char));
      Inc(P, Length(L));
    end;
    if BreakLen > 0 then
    begin
      Move(Brk[1], Result[P], BreakLen * SizeOf(Char));
      Inc(P, BreakLen);
    end;
  end;
  { Drop the trailing line break. }
  SetLength(Result, (P - 1) - BreakLen);
end;

{ Convert a UTF-16BE hex destination (as found in /ToUnicode bf entries) into a
  Delphi/FPC UnicodeString. Every 4 hex digits become one UTF-16 code unit. }
function HexUTF16ToStr(const Hex: string): string;
var
  I, Len: Integer;
begin
  Result := '';
  Len := Length(Hex);
  I := 1;
  while I + 3 <= Len do
  begin
    Result := Result + Char(StrToIntDef('$' + Copy(Hex, I, 4), 0));
    Inc(I, 4);
  end;
  if I + 1 <= Len then
    Result := Result + Char(StrToIntDef('$' + Copy(Hex, I, 2), 0));
end;

class function TPDFParser.HexToRawBytes(const HexStr: string): string;
var
  H1: string;
  I, Len: Integer;
begin
  Result := '';
  H1 := HexStr;
  if (Length(H1) mod 2) <> 0 then
    H1 := H1 + '0';
  Len := Length(H1);
  I := 1;
  while I + 1 <= Len do
  begin
    Result := Result + Char(StrToIntDef('$' + Copy(H1, I, 2), 0));
    Inc(I, 2);
  end;
end;

class function TPDFParser.ParseToUnicodeCMap(const CMapStr: string): TDictionary<Integer, string>;
var
  Len: Integer;

  function IsWS(C: Char): Boolean;
  begin
    Result := CharInSet(C, [#9, #10, #12, #13, #32]);
  end;

  function NextHex(var P: Integer; Bound: Integer; out Hex: string): Boolean;
  begin
    Hex := '';
    Result := False;
    while (P <= Bound) and (CMapStr[P] <> '<') and (CMapStr[P] <> '[') and (CMapStr[P] <> ']') do
      Inc(P);
    if (P > Bound) or (CMapStr[P] <> '<') then Exit;
    Inc(P);
    while (P <= Bound) and (CMapStr[P] <> '>') do
    begin
      if not IsWS(CMapStr[P]) then
        Hex := Hex + CMapStr[P];
      Inc(P);
    end;
    Inc(P);
    Result := True;
  end;

var
  P, BlockStart, BlockEnd: Integer;
  SrcHex, DstHex, LoHex, HiHex: string;
  Code, Lo, Hi, BaseVal, C: Integer;
begin
  Result := TDictionary<Integer, string>.Create;
  Len := Length(CMapStr);

  P := 1;
  repeat
    BlockStart := Pos('beginbfchar', CMapStr, P);
    if BlockStart = 0 then Break;
    BlockStart := BlockStart + Length('beginbfchar');
    BlockEnd := Pos('endbfchar', CMapStr, BlockStart);
    if BlockEnd = 0 then BlockEnd := Len + 1;
    P := BlockStart;
    while P < BlockEnd do
    begin
      if not NextHex(P, BlockEnd, SrcHex) then Break;
      if not NextHex(P, BlockEnd, DstHex) then Break;
      Code := StrToIntDef('$' + SrcHex, -1);
      if Code >= 0 then
        Result.AddOrSetValue(Code, HexUTF16ToStr(DstHex));
    end;
    P := BlockEnd + Length('endbfchar');
  until False;

  P := 1;
  repeat
    BlockStart := Pos('beginbfrange', CMapStr, P);
    if BlockStart = 0 then Break;
    BlockStart := BlockStart + Length('beginbfrange');
    BlockEnd := Pos('endbfrange', CMapStr, BlockStart);
    if BlockEnd = 0 then BlockEnd := Len + 1;
    P := BlockStart;
    while P < BlockEnd do
    begin
      if not NextHex(P, BlockEnd, LoHex) then Break;
      if not NextHex(P, BlockEnd, HiHex) then Break;
      Lo := StrToIntDef('$' + LoHex, -1);
      Hi := StrToIntDef('$' + HiHex, -1);
      if (Lo < 0) or (Hi < 0) then Break;
      while (P <= BlockEnd) and IsWS(CMapStr[P]) do Inc(P);
      if (P <= BlockEnd) and (CMapStr[P] = '[') then
      begin
        Inc(P);
        C := Lo;
        while (P <= BlockEnd) and (CMapStr[P] <> ']') do
        begin
          while (P <= BlockEnd) and IsWS(CMapStr[P]) do Inc(P);
          if (P <= BlockEnd) and (CMapStr[P] = ']') then Break;
          if not NextHex(P, BlockEnd, DstHex) then Break;
          if C <= Hi then
            Result.AddOrSetValue(C, HexUTF16ToStr(DstHex));
          Inc(C);
        end;
        if (P <= BlockEnd) and (CMapStr[P] = ']') then Inc(P);
      end
      else
      begin
        if not NextHex(P, BlockEnd, DstHex) then Break;
        BaseVal := StrToIntDef('$' + DstHex, 0);
        for C := Lo to Hi do
        begin
          if Length(DstHex) <= 4 then
            Result.AddOrSetValue(C, Char(Word(BaseVal + (C - Lo))))
          else
            Result.AddOrSetValue(C, HexUTF16ToStr(DstHex));
        end;
      end;
    end;
    P := BlockEnd + Length('endbfrange');
  until False;
end;

class function TPDFParser.BuildObjectIndex(const S: string): TDictionary<Integer, Integer>;
var
  ObjPos, Q, IdEnd, GenEnd, ObjID, Len: Integer;

  function IsWS(C: Char): Boolean;
  begin
    Result := CharInSet(C, [#9, #10, #12, #13, #32]);
  end;

begin
  Result := TDictionary<Integer, Integer>.Create;
  Len := Length(S);
  ObjPos := 1;
  repeat
    ObjPos := Pos('obj', S, ObjPos);
    if ObjPos = 0 then Break;
    Q := ObjPos - 1;
    if (Q >= 1) and IsWS(S[Q]) then
    begin
      while (Q >= 1) and IsWS(S[Q]) do Dec(Q);
      GenEnd := Q;
      while (Q >= 1) and CharInSet(S[Q], ['0'..'9']) do Dec(Q);
      if Q < GenEnd then
      begin
        while (Q >= 1) and IsWS(S[Q]) do Dec(Q);
        IdEnd := Q;
        while (Q >= 1) and CharInSet(S[Q], ['0'..'9']) do Dec(Q);
        if Q < IdEnd then
        begin
          ObjID := StrToIntDef(Copy(S, Q + 1, IdEnd - Q), -1);
          if ObjID >= 0 then
            Result.AddOrSetValue(ObjID, Q + 1);
        end;
      end;
    end;
    ObjPos := ObjPos + 3;
  until False;
end;

class function TPDFParser.GetObjectStreamData(const S: string; const Bytes: TBytes;
  const ObjIndex: TDictionary<Integer, Integer>; ObjID: Integer): TBytes;
var
  StartPos, StreamIdx, EndStreamIdx, EndObjIdx, DataStart, DataLen: Integer;
  Dict: string;
  Raw: TBytes;
begin
  SetLength(Result, 0);
  if not ObjIndex.TryGetValue(ObjID, StartPos) then Exit;

  StreamIdx := Pos('stream', S, StartPos);
  if StreamIdx = 0 then Exit;
  EndObjIdx := Pos('endobj', S, StartPos);
  if (EndObjIdx > 0) and (StreamIdx > EndObjIdx) then Exit;

  EndStreamIdx := Pos('endstream', S, StreamIdx + 6);
  if EndStreamIdx = 0 then Exit;

  DataStart := StreamIdx + 6;
  while (DataStart < EndStreamIdx) and CharInSet(S[DataStart], [#10, #13]) do
    Inc(DataStart);

  DataLen := EndStreamIdx - DataStart;
  if DataLen <= 0 then Exit;

  SetLength(Raw, DataLen);
  Move(Bytes[DataStart - 1], Raw[0], DataLen);

  Dict := Copy(S, StartPos, StreamIdx - StartPos);
  if ContainsText(Dict, '/FlateDecode') or ContainsText(Dict, '/Fl') then
    Result := DecompressFlate(Raw)
  else
    Result := Raw;
end;

class procedure TPDFParser.BuildFonts(const S: string; const Bytes: TBytes;
  const ObjIndex: TDictionary<Integer, Integer>;
  const Fonts: TObjectDictionary<Integer, TFontInfo>);
var
  Pair: TPair<Integer, Integer>;
  Head: string;
  TUPos, P, Len: Integer;
  NumStr: string;
  TUId: Integer;
  CMapBytes: TBytes;
  FI: TFontInfo;
begin
  for Pair in ObjIndex do
  begin
    Head := Copy(S, Pair.Value, 800);
    TUPos := Pos('/ToUnicode', Head);
    if TUPos = 0 then Continue;

    P := TUPos + Length('/ToUnicode');
    Len := Length(Head);
    while (P <= Len) and CharInSet(Head[P], [#9, #10, #12, #13, #32]) do Inc(P);
    NumStr := '';
    while (P <= Len) and CharInSet(Head[P], ['0'..'9']) do
    begin
      NumStr := NumStr + Head[P];
      Inc(P);
    end;
    TUId := StrToIntDef(NumStr, -1);
    if TUId < 0 then Continue;

    CMapBytes := GetObjectStreamData(S, Bytes, ObjIndex, TUId);
    if Length(CMapBytes) = 0 then Continue;

    FI := TFontInfo.Create;
    FI.TwoByte := ContainsText(Head, '/Type0');
    FI.ToUni := ParseToUnicodeCMap(BytesToString(CMapBytes));
    Fonts.AddOrSetValue(Pair.Key, FI);
  end;
end;

{ Build a document-wide map of font resource name (e.g. "F30") -> font
  object id, restricted to fonts that actually carry a /ToUnicode CMap.

  Known limitation: PDF font resource names are scoped to a page's
  resource dictionary, not the document. Two pages can both define /F1
  pointing at different subset fonts (common in LaTeX output where each
  page gets its own subset). Because this map is document-wide and
  AddOrSetValue is last-write-wins, pages using the *other* /F1 will
  decode with the wrong /ToUnicode map and produce garbled glyphs for
  those runs. Fixing this requires per-page resource maps threaded
  through ParseTextOperators; deferred -- single-font and
  same-font-across-pages documents (the majority of technical PDFs)
  work correctly, and the CP1252 fallback in DecodeStringBytes still
  yields readable plain ASCII even when the /ToUnicode lookup misses. }
class function TPDFParser.BuildResourceFontMap(const S: string;
  const Fonts: TObjectDictionary<Integer, TFontInfo>): TDictionary<string, Integer>;
var
  M: TMatch;
  Name: string;
  ObjID: Integer;
begin
  Result := TDictionary<string, Integer>.Create;
  M := TRegEx.Match(S, '/([A-Za-z][A-Za-z0-9]*)\s+(\d+)\s+\d+\s+R\b');
  while M.Success do
  begin
    ObjID := StrToIntDef(M.Groups[2].Value, -1);
    if (ObjID >= 0) and Fonts.ContainsKey(ObjID) then
    begin
      Name := M.Groups[1].Value;
      Result.AddOrSetValue(Name, ObjID);
    end;
    M := M.NextMatch;
  end;
end;

class function TPDFParser.DecodeStringBytes(const Raw: string; Font: TFontInfo): string;
var
  K, Len, Code: Integer;
  U: string;
begin
  Result := '';
  Len := Length(Raw);
  if (Font <> nil) and Assigned(Font.ToUni) and Font.TwoByte then
  begin
    K := 1;
    while K + 1 <= Len do
    begin
      Code := (Ord(Raw[K]) shl 8) or Ord(Raw[K + 1]);
      if Font.ToUni.TryGetValue(Code, U) then
      begin
        if U <> #$FFFF then
          Result := Result + U;
      end;
      Inc(K, 2);
    end;
  end
  else if (Font <> nil) and Assigned(Font.ToUni) then
  begin
    for K := 1 to Len do
    begin
      Code := Ord(Raw[K]);
      if Font.ToUni.TryGetValue(Code, U) then
      begin
        if U <> #$FFFF then
          Result := Result + U;
      end
      else
        Result := Result + CP1252ByteToChar(Code);
    end;
  end
  else
  begin
    for K := 1 to Len do
      Result := Result + CP1252ByteToChar(Ord(Raw[K]));
  end;
end;

class function TPDFParser.CP1252ByteToChar(B: Byte): Char;
begin
  case B of
    $80: Result := #$20AC;
    $82: Result := #$201A;
    $83: Result := #$0192;
    $84: Result := #$201E;
    $85: Result := #$2026;
    $86: Result := #$2020;
    $87: Result := #$2021;
    $88: Result := #$02C6;
    $89: Result := #$2030;
    $8A: Result := #$0160;
    $8B: Result := #$2039;
    $8C: Result := #$0152;
    $8E: Result := #$017D;
    $91: Result := #$2018;
    $92: Result := #$2019;
    $93: Result := #$201C;
    $94: Result := #$201D;
    $95: Result := #$2022;
    $96: Result := #$2013;
    $97: Result := #$2014;
    $98: Result := #$02DC;
    $99: Result := #$2122;
    $9A: Result := #$0161;
    $9B: Result := #$203A;
    $9C: Result := #$0153;
    $9E: Result := #$017E;
    $9F: Result := #$0178;
  else
    Result := Char(B);
  end;
end;

class function TPDFParser.DecodePDFString(const S: string): string;
var
  I, Len: Integer;
  OctVal, OctCount: Integer;
begin
  Result := '';
  I := 1;
  Len := Length(S);
  while I <= Len do
  begin
    if (S[I] = '\') and (I < Len) then
    begin
      Inc(I);
      if CharInSet(S[I], ['0'..'7']) then
      begin
        OctVal := 0;
        OctCount := 0;
        while (I <= Len) and CharInSet(S[I], ['0'..'7']) and (OctCount < 3) do
        begin
          OctVal := OctVal * 8 + (Ord(S[I]) - Ord('0'));
          Inc(OctCount);
          Inc(I);
        end;
        Dec(I);
        Result := Result + CP1252ByteToChar(OctVal);
      end
      else
      begin
        case S[I] of
          'n': Result := Result + #10;
          'r': Result := Result + #13;
          't': Result := Result + #9;
          'b': Result := Result + #8;
          'f': Result := Result + #12;
          '(', ')', '\': Result := Result + S[I];
          #13:
            begin
              if (I < Len) and (S[I + 1] = #10) then
                Inc(I);
            end;
          #10: ;
        else
          Result := Result + S[I];
        end;
      end;
    end
    else
    begin
      Result := Result + S[I];
    end;
    Inc(I);
  end;
end;

class function TPDFParser.BytesToString(const Bytes: TBytes): string;
var
  I: Integer;
begin
  SetLength(Result, Length(Bytes));
  for I := 0 to Length(Bytes) - 1 do
    Result[I + 1] := Char(Bytes[I]);
end;

class function TPDFParser.DecompressFlate(const InputBytes: TBytes): TBytes;
begin
  { Raw zlib/FlateDecode inflate, provided portably by PasClaw.KB.PDF.Compat
    (System.ZLib under Delphi, paszlib/zstream under FPC). }
  Result := InflateBytes(InputBytes);
end;

class function TPDFParser.GetPrecedingDictionary(const S: string; StreamIdx: Integer): string;
var
  P: Integer;
  NestCount: Integer;
begin
  Result := '';
  P := StreamIdx - 1;
  while (P > 0) and (S[P] <= ' ') do
    Dec(P);

  if (P > 1) and (S[P] = '>') and (S[P - 1] = '>') then
  begin
    NestCount := 1;
    Dec(P, 2);
    while (P > 1) and (NestCount > 0) do
    begin
      if (S[P] = '>') and (S[P - 1] = '>') then
      begin
        Inc(NestCount);
        Dec(P, 2);
      end
      else if (S[P] = '<') and (S[P - 1] = '<') then
      begin
        Dec(NestCount);
        if NestCount = 0 then
        begin
          Result := Copy(S, P - 1, (StreamIdx - 1) - (P - 1) + 1);
          Exit;
        end;
        Dec(P, 2);
      end
      else
        Dec(P);
    end;
  end;
end;

class function TPDFParser.DecodeHexPDFString(const HexStr: string): string;
var
  Len: Integer;
  I: Integer;
  H1: string;
  C: Word;
  IsUnicode: Boolean;
begin
  Result := '';
  Len := Length(HexStr);
  if Len = 0 then Exit;

  H1 := HexStr;
  if (Len mod 2) <> 0 then
    H1 := H1 + '0';

  Len := Length(H1);

  IsUnicode := False;
  if (Len >= 4) and ((Len mod 4) = 0) then
  begin
    C := StrToIntDef('$' + Copy(H1, 1, 2), 0);
    if (C = $FE) or (C = $FF) or (C = $00) then
      IsUnicode := True;
  end;

  if IsUnicode then
  begin
    I := 1;
    if (Len >= 8) and (Copy(H1, 1, 4) = 'FEFF') then
      Inc(I, 4)
    else if (Len >= 8) and (Copy(H1, 1, 4) = 'feff') then
      Inc(I, 4);

    while I <= Len - 3 do
    begin
      C := StrToIntDef('$' + Copy(H1, I, 4), 0);
      if C <> 0 then
        Result := Result + Char(C);
      Inc(I, 4);
    end;
  end
  else
  begin
    I := 1;
    while I <= Len - 1 do
    begin
      C := StrToIntDef('$' + Copy(H1, I, 2), 0);
      if C <> 0 then
        Result := Result + Char(C);
      Inc(I, 2);
    end;
  end;
end;

class function TPDFParser.ParseTextOperators(const BlockS: string;
  const ResFontMap: TDictionary<string, Integer>;
  const Fonts: TObjectDictionary<Integer, TFontInfo>): string;
var
  I, J, Len: Integer;
  InParen: Boolean;
  ParenDepth: Integer;
  InHex: Boolean;
  InsideTJ: Boolean;
  CurrentStr: string;
  CurrentHex: string;
  NumStr: string;
  Val: Integer;
  OctVal, OctCount: Integer;
  CurFont: TFontInfo;
  LastName: string;
  FID: Integer;
  { Set when a positioning operator (Td/TD/Tm/T*/'/") follows an
    already-emitted string; the next text-show operator prepends a
    space before its decoded bytes. Without this, a BT block of the
    form `(Hello) Tj 50 0 Td (World) Tj` extracts as "HelloWorld"
    instead of "Hello World" -- TJ-array negative-number spacing
    already handled below covers only positioned glyphs inside a
    single TJ operand. }
  NeedSpaceBeforeNext: Boolean;

  procedure EmitWithSpacing(const Decoded: string);
  begin
    if NeedSpaceBeforeNext then
    begin
      if (Result <> '') and (Result[Length(Result)] <> ' ') then
        Result := Result + ' ';
      NeedSpaceBeforeNext := False;
    end;
    Result := Result + Decoded;
  end;

begin
  Result := '';
  I := 1;
  Len := Length(BlockS);
  InParen := False;
  ParenDepth := 0;
  InHex := False;
  CurrentStr := '';
  CurrentHex := '';
  InsideTJ := False;
  CurFont := nil;
  LastName := '';
  NeedSpaceBeforeNext := False;

  while I <= Len do
  begin
    if InParen then
    begin
      if (BlockS[I] = '\') and (I < Len) then
      begin
        Inc(I);
        if CharInSet(BlockS[I], ['0'..'7']) then
        begin
          OctVal := 0;
          OctCount := 0;
          while (I <= Len) and CharInSet(BlockS[I], ['0'..'7']) and (OctCount < 3) do
          begin
            OctVal := OctVal * 8 + (Ord(BlockS[I]) - Ord('0'));
            Inc(OctCount);
            Inc(I);
          end;
          Dec(I);
          CurrentStr := CurrentStr + Char(OctVal and $FF);
        end
        else
        begin
          case BlockS[I] of
            'n': CurrentStr := CurrentStr + #10;
            'r': CurrentStr := CurrentStr + #13;
            't': CurrentStr := CurrentStr + #9;
            'b': CurrentStr := CurrentStr + #8;
            'f': CurrentStr := CurrentStr + #12;
            '(', ')', '\': CurrentStr := CurrentStr + BlockS[I];
            #13:
              begin
                if (I < Len) and (BlockS[I + 1] = #10) then
                  Inc(I);
              end;
            #10: ;
          else
            CurrentStr := CurrentStr + BlockS[I];
          end;
        end;
      end
      else if BlockS[I] = '(' then
      begin
        Inc(ParenDepth);
        CurrentStr := CurrentStr + '(';
      end
      else if BlockS[I] = ')' then
      begin
        Dec(ParenDepth);
        if ParenDepth = 0 then
        begin
          InParen := False;
          EmitWithSpacing(DecodeStringBytes(CurrentStr, CurFont));
          CurrentStr := '';
        end
        else
          CurrentStr := CurrentStr + ')';
      end
      else
      begin
        CurrentStr := CurrentStr + BlockS[I];
      end;
    end
    else if InHex then
    begin
      if BlockS[I] = '>' then
      begin
        InHex := False;
        EmitWithSpacing(DecodeStringBytes(HexToRawBytes(CurrentHex), CurFont));
        CurrentHex := '';
      end
      else if CharInSet(BlockS[I], ['0'..'9', 'a'..'f', 'A'..'F']) then
      begin
        CurrentHex := CurrentHex + BlockS[I];
      end;
    end
    else
    begin
      if BlockS[I] = '(' then
      begin
        InParen := True;
        ParenDepth := 1;
        CurrentStr := '';
      end
      else if BlockS[I] = '<' then
      begin
        if (I < Len) and (BlockS[I + 1] = '<') then
        begin
          Inc(I);
        end
        else
        begin
          InHex := True;
          CurrentHex := '';
        end;
      end
      else if BlockS[I] = '/' then
      begin
        J := I + 1;
        LastName := '';
        while (J <= Len) and CharInSet(BlockS[J], ['A'..'Z', 'a'..'z', '0'..'9']) do
        begin
          LastName := LastName + BlockS[J];
          Inc(J);
        end;
        I := J - 1;
      end
      else if (BlockS[I] = 'T') and (I < Len) and (BlockS[I + 1] = 'f') then
      begin
        CurFont := nil;
        if (ResFontMap <> nil) and ResFontMap.TryGetValue(LastName, FID) then
          Fonts.TryGetValue(FID, CurFont);
        Inc(I);
      end
      else if (BlockS[I] = 'T') and (I < Len) and
              ((BlockS[I + 1] = 'd') or (BlockS[I + 1] = 'D') or
               (BlockS[I + 1] = 'm') or (BlockS[I + 1] = '*')) then
      begin
        { Td (translate), TD (translate + set leading), Tm (set matrix),
          T* (next line): all position operators between text shows.
          Mark that we need a space before the next emission so word-
          per-Tj layouts ("BT (Hello) Tj 50 0 Td (World) Tj ET") don't
          run together. }
        if Result <> '' then
          NeedSpaceBeforeNext := True;
        Inc(I);
      end
      else if (BlockS[I] = '''') or (BlockS[I] = '"') then
      begin
        { ' (move to next line + show string) and " (move + show + adjust
          spacings) are text-show ops preceded by an implicit line break,
          so always treat as a word boundary. }
        if Result <> '' then
          NeedSpaceBeforeNext := True;
      end
      else if BlockS[I] = '[' then
      begin
        InsideTJ := True;
      end
      else if BlockS[I] = ']' then
      begin
        InsideTJ := False;
      end
      else if (BlockS[I] = '-') and InsideTJ then
      begin
        NumStr := '';
        Inc(I);
        while (I <= Len) and CharInSet(BlockS[I], ['0'..'9']) do
        begin
          NumStr := NumStr + BlockS[I];
          Inc(I);
        end;
        Dec(I);
        if NumStr <> '' then
        begin
          Val := StrToIntDef(NumStr, 0);
          if Val > 120 then
            Result := Result + ' ';
        end;
      end;
    end;
    Inc(I);
  end;
end;

{ Collapse runs of whitespace to single spaces and drop blank lines.
  Implemented without regular expressions so it is safe on fully-decoded
  Unicode text (FPC's regexpr operates on a byte codepage and would mangle
  code points above U+00FF). }
class function TPDFParser.CollapseWhitespace(const Line: string): string;
var
  I, Len: Integer;
  PrevSpace: Boolean;
begin
  Result := '';
  Len := Length(Line);
  PrevSpace := False;
  for I := 1 to Len do
  begin
    if CharInSet(Line[I], [#9, #10, #11, #12, #13, #32]) then
    begin
      if not PrevSpace then
      begin
        Result := Result + ' ';
        PrevSpace := True;
      end;
    end
    else
    begin
      Result := Result + Line[I];
      PrevSpace := False;
    end;
  end;
  Result := Trim(Result);
end;

class function TPDFParser.CleanText(const S: string): string;
var
  Lines: TArray<string>;
  Line, CleanedLine: string;
  Cleaned: TList<string>;
begin
  Cleaned := TList<string>.Create;
  try
    Lines := SplitChars(S, [#13, #10]);
    for Line in Lines do
    begin
      CleanedLine := CollapseWhitespace(Line);
      if CleanedLine <> '' then
        Cleaned.Add(CleanedLine);
    end;
    Result := Trim(JoinLines(Cleaned));
  finally
    Cleaned.Free;
  end;
end;

class function TPDFParser.ExtractMetaValue(const S, Key: string): string;
var
  M: TMatch;
  Pattern: string;
begin
  Result := '';
  Pattern := Key + '\s*\(([^)]*)\)';
  M := TRegEx.Match(S, Pattern, [roIgnoreCase]);
  if M.Success then
  begin
    Result := Trim(DecodePDFString(M.Groups[1].Value));
    Exit;
  end;

  Pattern := Key + '\s*<([0-9a-fA-F]+)>';
  M := TRegEx.Match(S, Pattern, [roIgnoreCase]);
  if M.Success then
  begin
    Result := Trim(DecodeHexPDFString(M.Groups[1].Value));
    Exit;
  end;
end;

class function TPDFParser.ExtractPageCount(const S: string): Integer;
var
  M: TMatch;
begin
  Result := 0;
  M := TRegEx.Match(S, '/Type\s*/Page\b', [roIgnoreCase]);
  while M.Success do
  begin
    Inc(Result);
    M := M.NextMatch;
  end;

  if Result = 0 then
  begin
    M := TRegEx.Match(S, '/Count\s*(\d+)', [roIgnoreCase]);
    while M.Success do
    begin
      Result := StrToIntDef(M.Groups[1].Value, 0);
      if Result > 0 then
        Exit;
      M := M.NextMatch;
    end;
  end;
end;

class function TPDFParser.CountWords(const S: string): Integer;
var
  I, Len: Integer;
  InWord: Boolean;

  function IsWordChar(C: Char): Boolean;
  begin
    Result := CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '_']);
  end;

begin
  Result := 0;
  Len := Length(S);
  InWord := False;
  for I := 1 to Len do
  begin
    if IsWordChar(S[I]) then
    begin
      if not InWord then
      begin
        Inc(Result);
        InWord := True;
      end;
    end
    else
      InWord := False;
  end;
end;

class function TPDFParser.GetPageContentStreamIDs(const S: string; MaxPages: Integer; const PagesRange: string; out PageCounts: Integer): TList<Integer>;
var
  M: TMatch;
  P, DictStart, DictEnd: Integer;
  DictText, ContentsVal: string;
  MRef: TMatch;
begin
  Result := TList<Integer>.Create;
  PageCounts := 0;

  M := TRegEx.Match(S, '/Type\s*/Page\b', [roIgnoreCase]);
  while M.Success do
  begin
    Inc(PageCounts);
    if ((MaxPages <= 0) or (PageCounts <= MaxPages)) and IsPageInRange(PageCounts, PagesRange) then
    begin
      P := M.Index;
      DictStart := P;
      while (DictStart > 1) and not ((S[DictStart] = '<') and (S[DictStart - 1] = '<')) do
        Dec(DictStart);

      DictEnd := P;
      while (DictEnd < Length(S)) and not ((S[DictEnd] = '>') and (S[DictEnd + 1] = '>')) do
        Inc(DictEnd);

      if (DictStart > 1) and (DictEnd < Length(S)) then
      begin
        DictText := Copy(S, DictStart - 1, DictEnd - DictStart + 3);

        MRef := TRegEx.Match(DictText, '/Contents\s*([^/]+)', [roIgnoreCase]);
        if MRef.Success then
        begin
          ContentsVal := MRef.Groups[1].Value;
          MRef := TRegEx.Match(ContentsVal, '\b(\d+)\s+\d+\s+R\b', [roIgnoreCase]);
          while MRef.Success do
          begin
            Result.Add(StrToInt(MRef.Groups[1].Value));
            MRef := MRef.NextMatch;
          end;
        end;
      end;
    end;
    M := M.NextMatch;
  end;
end;

class function TPDFParser.IsPageInRange(const PageIdx: Integer; const RangeStr: string): Boolean;
var
  Tokens: TArray<string>;
  Token: string;
  TrimmedToken: string;
  DashPos: Integer;
  StartStr, EndStr: string;
  StartPage, EndPage, SpecificPage: Integer;
begin
  if Trim(RangeStr) = '' then
  begin
    Result := True;
    Exit;
  end;

  Result := False;
  Tokens := SplitChars(RangeStr, [',']);
  for Token in Tokens do
  begin
    TrimmedToken := Trim(Token);
    if TrimmedToken = '' then Continue;

    DashPos := Pos('-', TrimmedToken);
    if DashPos > 0 then
    begin
      StartStr := Trim(Copy(TrimmedToken, 1, DashPos - 1));
      EndStr := Trim(Copy(TrimmedToken, DashPos + 1, Length(TrimmedToken)));
      StartStr := Trim(Copy(Token, 1, DashPos - 1));
      EndStr := Trim(Copy(Token, DashPos + 1, Length(Token)));
      if TryStrToInt(StartStr, StartPage) and TryStrToInt(EndStr, EndPage) then
      begin
        if (PageIdx >= StartPage) and (PageIdx <= EndPage) then
        begin
          Result := True;
          Exit;
        end;
      end;
    end
    else
    begin
      if TryStrToInt(Token, SpecificPage) then
      begin
        if PageIdx = SpecificPage then
        begin
          Result := True;
          Exit;
        end;
      end;
    end;
  end;
end;

class function TPDFParser.IsValidPDFHeader(const FilePath: string): Boolean;
var
  FS: TFileStream;
  Buffer: array[0..3] of Byte;
begin
  Result := False;
  if not TFile.Exists(FilePath) then Exit;
  try
    FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
    try
      if FS.Size >= 4 then
      begin
        FS.ReadBuffer(Buffer[0], 4);
        Result := (Buffer[0] = $25) and (Buffer[1] = $50) and (Buffer[2] = $44) and (Buffer[3] = $46);
      end;
    finally
      FS.Free;
    end;
  except
  end;
end;

class function TPDFParser.ExtractTextAndMetadata(const FilePath: string; out Text: string; out Meta: TPDFMetadata; const MaxPages: Integer = 0; const PagesRange: string = ''): Boolean;
var
  Bytes, StreamBytes, Decompressed: TBytes;
  S, Dict, DecompressedStr, BlockText: string;
  StreamPos, StreamIdx, EndstreamIdx, DataStart, DataLen: Integer;
  TextBuilder: TList<string>;
  M: TMatch;
  ContentIDs: TList<Integer>;
  ObjID: Integer;
  ObjIdx, EndObjIdx: Integer;
  PagesProcessed: Integer;
  ParsedPageCount: Integer;
  ObjIndex: TDictionary<Integer, Integer>;
  Fonts: TObjectDictionary<Integer, TFontInfo>;
  ResFontMap: TDictionary<string, Integer>;
begin
  Result := False;
  Text := '';
  FillChar(Meta, SizeOf(Meta), 0);

  if not TFile.Exists(FilePath) then
    Exit;

  try
    Bytes := TFile.ReadAllBytes(FilePath);
    S := BytesToString(Bytes);

    Meta.Title := ExtractMetaValue(S, '/Title');
    Meta.Author := ExtractMetaValue(S, '/Author');
    Meta.Creator := ExtractMetaValue(S, '/Creator');
    Meta.Producer := ExtractMetaValue(S, '/Producer');
    Meta.PageCount := ExtractPageCount(S);

    ObjIndex := nil;
    Fonts := nil;
    ResFontMap := nil;
    TextBuilder := TList<string>.Create;
    ContentIDs := nil;
    try
      ObjIndex := BuildObjectIndex(S);
      Fonts := TObjectDictionary<Integer, TFontInfo>.Create([doOwnsValues]);
      BuildFonts(S, Bytes, ObjIndex, Fonts);
      ResFontMap := BuildResourceFontMap(S, Fonts);

      ContentIDs := GetPageContentStreamIDs(S, MaxPages, PagesRange, ParsedPageCount);

      if ContentIDs.Count > 0 then
      begin
        for ObjID in ContentIDs do
        begin
          { Use the precomputed object index so non-zero-generation
            content streams (e.g. "12 1 obj" after an incremental
            update) are still resolved. A regex hardcoded to "%d 0 obj"
            would miss them and the wrapper would mis-report a valid
            text PDF as "no extractable text". }
          if not ObjIndex.TryGetValue(ObjID, ObjIdx) then Continue;

          StreamIdx := Pos('stream', S, ObjIdx);
          if StreamIdx > 0 then
          begin
            { Confirm the stream belongs to this object: the next
              'endobj' must come after the stream, not before. Mirrors
              the bounds check in GetObjectStreamData. }
            EndObjIdx := Pos('endobj', S, ObjIdx);
            if (EndObjIdx = 0) or (StreamIdx < EndObjIdx) then
            begin
              EndstreamIdx := Pos('endstream', S, StreamIdx + 6);
              if EndstreamIdx > 0 then
              begin
                Dict := GetPrecedingDictionary(S, StreamIdx);

                DataStart := StreamIdx + 6;
                while (DataStart < EndstreamIdx) and CharInSet(S[DataStart], [#10, #13]) do
                  Inc(DataStart);

                DataLen := EndstreamIdx - DataStart;
                if DataLen > 0 then
                begin
                  SetLength(StreamBytes, DataLen);
                  Move(Bytes[DataStart - 1], StreamBytes[0], DataLen);

                  if ContainsText(Dict, '/FlateDecode') or ContainsText(Dict, '/Fl') then
                    Decompressed := DecompressFlate(StreamBytes)
                  else
                    Decompressed := StreamBytes;

                  if Length(Decompressed) > 0 then
                  begin
                    DecompressedStr := BytesToString(Decompressed);
                    M := TRegEx.Match(DecompressedStr, '\bBT\b([\s\S]*?)\bET\b', [roIgnoreCase]);
                    while M.Success do
                    begin
                      BlockText := ParseTextOperators(M.Groups[1].Value, ResFontMap, Fonts);
                      if BlockText <> '' then
                        TextBuilder.Add(BlockText);
                      M := M.NextMatch;
                    end;
                  end;
                end;
              end;
            end;
          end;
        end;
      end
      else
      begin
        { FALLBACK: sequential stream scanning. }
        StreamPos := 1;
        PagesProcessed := 0;
        while True do
        begin
          StreamIdx := Pos('stream', S, StreamPos);
          if StreamIdx = 0 then Break;

          EndstreamIdx := Pos('endstream', S, StreamIdx + 6);
          if EndstreamIdx = 0 then
          begin
            StreamPos := StreamIdx + 6;
            Continue;
          end;

          Dict := GetPrecedingDictionary(S, StreamIdx);

          if ContainsText(Dict, '/Type/Font') or ContainsText(Dict, '/Type /Font') or
             ContainsText(Dict, '/Subtype/Image') or ContainsText(Dict, '/Subtype /Image') or
             ContainsText(Dict, '/Type/XRef') or ContainsText(Dict, '/Type /XRef') or
             ContainsText(Dict, '/Type/ObjStm') or ContainsText(Dict, '/Type /ObjStm') then
          begin
            StreamPos := EndstreamIdx + 9;
            Continue;
          end;

          DataStart := StreamIdx + 6;
          while (DataStart < EndstreamIdx) and CharInSet(S[DataStart], [#10, #13]) do
            Inc(DataStart);

          DataLen := EndstreamIdx - DataStart;
          if DataLen > 0 then
          begin
            SetLength(StreamBytes, DataLen);
            Move(Bytes[DataStart - 1], StreamBytes[0], DataLen);

            if ContainsText(Dict, '/FlateDecode') or ContainsText(Dict, '/Fl') then
              Decompressed := DecompressFlate(StreamBytes)
            else
              Decompressed := StreamBytes;

            if Length(Decompressed) > 0 then
            begin
              DecompressedStr := BytesToString(Decompressed);
              M := TRegEx.Match(DecompressedStr, '\bBT\b([\s\S]*?)\bET\b', [roIgnoreCase]);
              if M.Success then
              begin
                Inc(PagesProcessed);
                if (MaxPages > 0) and (PagesProcessed > MaxPages) then
                begin
                  Break;
                end;

                if IsPageInRange(PagesProcessed, PagesRange) then
                begin
                  while M.Success do
                  begin
                    BlockText := ParseTextOperators(M.Groups[1].Value, ResFontMap, Fonts);
                    if BlockText <> '' then
                      TextBuilder.Add(BlockText);
                    M := M.NextMatch;
                  end;
                end;
              end;
            end;
          end;

          StreamPos := EndstreamIdx + 9;
        end;
      end;

      Text := CleanText(JoinLines(TextBuilder));
      Meta.CharCount := Length(Text);
      Meta.WordCount := CountWords(Text);

      if (Meta.PageCount = 0) and (Text <> '') then
        Meta.PageCount := 1;

      Result := True;
    finally
      TextBuilder.Free;
      if Assigned(ContentIDs) then
        ContentIDs.Free;
      ResFontMap.Free;
      Fonts.Free;
      ObjIndex.Free;
    end;
  except
    on E: Exception do
    begin
      Result := False;
    end;
  end;
end;

end.
