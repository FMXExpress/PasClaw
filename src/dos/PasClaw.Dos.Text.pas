(*
  PasClaw.Dos.Text -- text at the edges of the DOS client: the console,
  file contents, file names and command lines.

  Inside, every string is UTF-8: that is what the model reads and writes
  and what the JSON carries. A DOS PC is code page 437: the screen, the
  keyboard, the bytes in its text files and its file names. So text is
  turned into CP437 on its way out (screen, files, commands) and back into
  UTF-8 on its way in, here and nowhere else. Characters CP437 has no
  glyph for become their nearest ASCII ("--" for an em dash, quotes for
  curly quotes) or "?".

  Text files on DOS end lines with CR LF; the model writes LF. Files are
  read with CR LF turned into LF and written with LF turned into CR LF.

  On a host build (Linux, for testing) none of this applies: the console
  and the files are UTF-8 already, and these functions pass text through.

  InitDosText must run first: it makes the RTL treat every string as
  UTF-8 bytes and never convert one on its own (go32v2 has no code page
  conversion of its own worth trusting -- it would read CP437 as Latin-1).
*)
unit PasClaw.Dos.Text;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

const
  {$IFDEF GO32V2}
  DOS_TEXT = True;
  {$ELSE}
  DOS_TEXT = False;
  {$ENDIF}
  SCREEN_COLS = 80;

procedure InitDosText;

{ UTF-8 <-> CP437, always (tests call these on any host). }
function Utf8ToCp437(const S: string): string;
function Cp437ToUtf8(const S: string): string;

{ The same, only on DOS. }
function ToLocal(const Utf8: string): string;
function FromLocal(const S: string): string;

{ File contents: CP437 + CR LF on DOS, unchanged elsewhere. }
function FileTextToUtf8(const Raw: string): string;
function Utf8ToFileText(const S: string): string;

{ Whole files as bytes. }
function ReadFileBytes(const Path: string; out Data: string; out Err: string): Boolean;
function WriteFileBytes(const Path, Data: string; out Err: string): Boolean;

{ Console. Say wraps at the screen width and breaks on LF. }
procedure Say(const Utf8: string);
procedure SayRaw(const Utf8: string);   { no newline, no wrapping }
function ReadPromptLine(out Utf8: string): Boolean;   { False at end of input }

{ Is standard output the screen (not a file or a pipe)? }
function ConsoleIsTTY: Boolean;

{ Word-wrap to Width columns; lines split on LF. }
function WrapText(const S: string; Width: Integer): TStringList;

implementation

{$IFDEF GO32V2}
uses
  go32;
{$ELSE}
{$IFDEF UNIX}
uses
  termio;
{$ENDIF}
{$ENDIF}

var
  GTTYKnown: Boolean = False;
  GTTY: Boolean = False;

function ConsoleIsTTY: Boolean;
{$IFDEF GO32V2}
var
  R: TRealRegs;
{$ENDIF}
begin
  if not GTTYKnown then
  begin
    {$IFDEF GO32V2}
    { IOCTL "get device information" on handle 1: bit 7 = a device,
      bit 1 = the console's output. }
    FillChar(R, SizeOf(R), 0);
    R.ax := $4400;
    R.bx := 1;
    realintr($21, R);
    GTTY := ((R.flags and 1) = 0) and ((R.dx and $82) = $82);
    {$ELSE}
    {$IFDEF UNIX}
    GTTY := IsATTY(1) = 1;
    {$ELSE}
    GTTY := True;
    {$ENDIF}
    {$ENDIF}
    GTTYKnown := True;
  end;
  Result := GTTY;
end;

const
  { CP437 $80..$FF as Unicode code points. }
  CP437_HIGH: array[$80..$FF] of Word = (
    $00C7, $00FC, $00E9, $00E2, $00E4, $00E0, $00E5, $00E7,
    $00EA, $00EB, $00E8, $00EF, $00EE, $00EC, $00C4, $00C5,
    $00C9, $00E6, $00C6, $00F4, $00F6, $00F2, $00FB, $00F9,
    $00FF, $00D6, $00DC, $00A2, $00A3, $00A5, $20A7, $0192,
    $00E1, $00ED, $00F3, $00FA, $00F1, $00D1, $00AA, $00BA,
    $00BF, $2310, $00AC, $00BD, $00BC, $00A1, $00AB, $00BB,
    $2591, $2592, $2593, $2502, $2524, $2561, $2562, $2556,
    $2555, $2563, $2551, $2557, $255D, $255C, $255B, $2510,
    $2514, $2534, $252C, $251C, $2500, $253C, $255E, $255F,
    $255A, $2554, $2569, $2566, $2560, $2550, $256C, $2567,
    $2568, $2564, $2565, $2559, $2558, $2552, $2553, $256B,
    $256A, $2518, $250C, $2588, $2584, $258C, $2590, $2580,
    $03B1, $00DF, $0393, $03C0, $03A3, $03C3, $00B5, $03C4,
    $03A6, $0398, $03A9, $03B4, $221E, $03C6, $03B5, $2229,
    $2261, $00B1, $2265, $2264, $2320, $2321, $00F7, $2248,
    $00B0, $2219, $00B7, $221A, $207F, $00B2, $25A0, $00A0);

procedure InitDosText;
begin
  {$IFDEF FPC}
  DefaultSystemCodePage := CP_UTF8;
  DefaultFileSystemCodePage := CP_UTF8;
  DefaultRTLFileSystemCodePage := CP_UTF8;
  SetTextCodePage(Output, CP_UTF8);
  SetTextCodePage(Input, CP_UTF8);
  SetTextCodePage(ErrOutput, CP_UTF8);
  {$ENDIF}
end;

procedure AddByte(var R: string; var N: Integer; B: Byte);
begin
  if N = Length(R) then SetLength(R, N * 2 + 16);
  Inc(N);
  R[N] := AnsiChar(B);
end;

procedure AddStr(var R: string; var N: Integer; const S: string);
var
  i: Integer;
begin
  for i := 1 to Length(S) do AddByte(R, N, Ord(S[i]));
end;

{ Nearest ASCII for what CP437 cannot show; '' when there is none. }
function AsciiFallback(CP: Cardinal): string;
begin
  case CP of
    $2018, $2019, $201A, $2032: Result := '''';
    $201C, $201D, $201E, $2033: Result := '"';
    $2010, $2011, $2012, $2013, $2212: Result := '-';
    $2014, $2015: Result := '--';
    $2026: Result := '...';
    $2022, $25CF, $25E6: Result := '*';   { #7 would be the glyph, but DOS rings the bell }
    $2192, $27F6: Result := '->';
    $2190, $27F5: Result := '<-';
    $21D2: Result := '=>';
    $2194: Result := '<->';
    $2713, $2714, $2705: Result := #$FB;   { square root, the usual check }
    $2717, $2718, $274C: Result := 'x';
    $00D7: Result := 'x';
    $2260: Result := '!=';
    $00A9: Result := '(c)';
    $00AE: Result := '(R)';
    $2122: Result := '(TM)';
    $20AC: Result := 'EUR';
    $00A0, $2002, $2003, $2009, $200A, $202F: Result := ' ';
    $200B, $200C, $200D, $FEFF, $FE0F: Result := '';   { invisible }
    $00C0, $00C1, $00C2, $00C3: Result := 'A';
    $00C8, $00CA, $00CB: Result := 'E';
    $00CC, $00CD, $00CE, $00CF: Result := 'I';
    $00D2, $00D3, $00D4, $00D5, $00D8: Result := 'O';
    $00D9, $00DA, $00DB: Result := 'U';
    $00E3: Result := 'a';
    $00F5, $00F8: Result := 'o';
    $00FD: Result := 'y';
  else
    Result := '?';
  end;
end;

function Utf8ToCp437(const S: string): string;
var
  i, N, k, Extra: Integer;
  B: Byte;
  CP: Cardinal;
  Found: Boolean;
begin
  SetLength(Result, Length(S));
  N := 0;
  i := 1;
  while i <= Length(S) do
  begin
    B := Ord(S[i]);
    if B < $80 then
    begin
      AddByte(Result, N, B);
      Inc(i);
      Continue;
    end;
    if (B and $E0) = $C0 then begin CP := B and $1F; Extra := 1; end
    else if (B and $F0) = $E0 then begin CP := B and $0F; Extra := 2; end
    else if (B and $F8) = $F0 then begin CP := B and $07; Extra := 3; end
    else
    begin
      { Not UTF-8 lead byte: one '?' and move on. }
      AddByte(Result, N, Ord('?'));
      Inc(i);
      Continue;
    end;
    if i + Extra > Length(S) then
    begin
      AddByte(Result, N, Ord('?'));
      Break;
    end;
    for k := 1 to Extra do
      CP := (CP shl 6) or (Ord(S[i + k]) and $3F);
    Inc(i, Extra + 1);
    Found := False;
    for k := $80 to $FF do
      if CP437_HIGH[k] = CP then
      begin
        AddByte(Result, N, k);
        Found := True;
        Break;
      end;
    if not Found then AddStr(Result, N, AsciiFallback(CP));
  end;
  SetLength(Result, N);
end;

function Cp437ToUtf8(const S: string): string;
var
  i, N: Integer;
  B: Byte;
  CP: Word;
begin
  SetLength(Result, Length(S));
  N := 0;
  for i := 1 to Length(S) do
  begin
    B := Ord(S[i]);
    if B < $80 then
    begin
      AddByte(Result, N, B);
      Continue;
    end;
    CP := CP437_HIGH[B];
    if CP < $800 then
    begin
      AddByte(Result, N, $C0 or (CP shr 6));
      AddByte(Result, N, $80 or (CP and $3F));
    end
    else
    begin
      AddByte(Result, N, $E0 or (CP shr 12));
      AddByte(Result, N, $80 or ((CP shr 6) and $3F));
      AddByte(Result, N, $80 or (CP and $3F));
    end;
  end;
  SetLength(Result, N);
end;

function ToLocal(const Utf8: string): string;
begin
  {$IFDEF GO32V2}Result := Utf8ToCp437(Utf8);{$ELSE}Result := Utf8;{$ENDIF}
end;

function FromLocal(const S: string): string;
begin
  {$IFDEF GO32V2}Result := Cp437ToUtf8(S);{$ELSE}Result := S;{$ENDIF}
end;

function FileTextToUtf8(const Raw: string): string;
begin
  {$IFDEF GO32V2}
  Result := StringReplace(Cp437ToUtf8(Raw), #13#10, #10, [rfReplaceAll]);
  {$ELSE}
  Result := Raw;
  {$ENDIF}
end;

function Utf8ToFileText(const S: string): string;
begin
  {$IFDEF GO32V2}
  Result := StringReplace(StringReplace(S, #13#10, #10, [rfReplaceAll]),
                          #10, #13#10, [rfReplaceAll]);
  Result := Utf8ToCp437(Result);
  {$ELSE}
  Result := S;
  {$ENDIF}
end;

function ReadFileBytes(const Path: string; out Data: string; out Err: string): Boolean;
var
  F: TFileStream;
begin
  Result := False;
  Data := '';
  Err := '';
  try
    F := TFileStream.Create(ToLocal(Path), fmOpenRead or fmShareDenyNone);
    try
      SetLength(Data, F.Size);
      if Length(Data) > 0 then F.ReadBuffer(Data[1], Length(Data));
    finally
      F.Free;
    end;
    Result := True;
  except
    on E: Exception do Err := E.Message;
  end;
end;

function WriteFileBytes(const Path, Data: string; out Err: string): Boolean;
var
  F: TFileStream;
begin
  Result := False;
  Err := '';
  try
    F := TFileStream.Create(ToLocal(Path), fmCreate);
    try
      if Length(Data) > 0 then F.WriteBuffer(Data[1], Length(Data));
    finally
      F.Free;
    end;
    Result := True;
  except
    on E: Exception do Err := E.Message;
  end;
end;

{ Display width of a UTF-8 string: one column per code point. }
function Utf8Len(const S: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to Length(S) do
    if (Ord(S[i]) and $C0) <> $80 then Inc(Result);
end;

{ Byte index after the first Cols code points. }
function Utf8Cut(const S: string; Cols: Integer): Integer;
var
  i, C: Integer;
begin
  C := 0;
  i := 1;
  while i <= Length(S) do
  begin
    if (Ord(S[i]) and $C0) <> $80 then
    begin
      if C = Cols then Exit(i - 1);
      Inc(C);
    end;
    Inc(i);
  end;
  Result := Length(S);
end;

function WrapText(const S: string; Width: Integer): TStringList;
var
  Lines: TStringList;
  i, Cut, SpaceAt, k: Integer;
  L: string;
begin
  Result := TStringList.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := StringReplace(S, #13#10, #10, [rfReplaceAll]);
    for i := 0 to Lines.Count - 1 do
    begin
      L := TrimRight(Lines[i]);
      while Utf8Len(L) > Width do
      begin
        Cut := Utf8Cut(L, Width);
        SpaceAt := 0;
        for k := Cut + 1 downto 2 do
          if (k <= Length(L)) and (L[k] = ' ') then
          begin
            SpaceAt := k;
            Break;
          end;
        if SpaceAt > 0 then
        begin
          Result.Add(TrimRight(Copy(L, 1, SpaceAt - 1)));
          L := TrimLeft(Copy(L, SpaceAt + 1, MaxInt));
        end
        else
        begin
          Result.Add(Copy(L, 1, Cut));
          L := Copy(L, Cut + 1, MaxInt);
        end;
      end;
      Result.Add(L);
    end;
  finally
    Lines.Free;
  end;
end;

procedure SayRaw(const Utf8: string);
begin
  Write(Output, ToLocal(Utf8));
end;

procedure Say(const Utf8: string);
var
  L: TStringList;
  i: Integer;
begin
  { A line exactly SCREEN_COLS wide makes the DOS cursor wrap by itself,
    and the WriteLn then leaves a blank line: wrap one column short. }
  L := WrapText(Utf8, SCREEN_COLS - 1);
  try
    if L.Count = 0 then WriteLn(Output);
    for i := 0 to L.Count - 1 do
      WriteLn(Output, ToLocal(L[i]));
  finally
    L.Free;
  end;
end;

function ReadPromptLine(out Utf8: string): Boolean;
var
  S: string;
begin
  Utf8 := '';
  if EOF(Input) then Exit(False);
  ReadLn(Input, S);
  Utf8 := FromLocal(S);
  Result := True;
end;

end.
