(*
  PasClaw.Compare.FreePascalOS - exact string comparisons on FreePascalOS
  (https://github.com/xeons/FreePascalOS).

  FreePascalOS's SysUtils installs fpwidestring's string manager, which
  compares text by the Unicode collation algorithm with the root
  collation. That collation gives punctuation and spaces no weight, so
  there AnsiCompareText('X-Foo', 'XFoo') and AnsiCompareStr('a b', 'ab')
  are 0 -- and every TStringList lookup, sort and duplicate check goes
  through those two (UseLocale is on by default): IndexOf('my-db')
  finds 'mydb', and Indy read `GET /x HTTP/1.1` as the path
  `/x HTTP/1`.

  PasClaw compares names, keys, paths and protocol text, not prose for a
  person to read in sorted order. So this unit swaps the comparisons of
  the string manager for exact ones, as PasClaw gets on its other
  targets: case-sensitive ones compare the bytes of the UTF-8 (code point
  order), case-insensitive ones the same after Unicode upper-casing.
  Upper- and lower-casing stay fpwidestring's.

  It is the first unit of the program (src/pasclaw/PasClaw.dpr), inside
  {$IFDEF FREEPASCALOS}, so that the manager is swapped before any other
  unit's initialization fills a sorted list. Only `make fpos` compiles
  it: src/fpos is on no other build's unit path.

  This file is PasClaw's, under PasClaw's MIT license.
*)
unit PasClaw.Compare.FreePascalOS;

{$MODE DELPHI}
{$H+}

interface

{ Exposed for what checks the swap; the string manager calls them. }
function FposCompareStr(const S1, S2: AnsiString): PtrInt;
function FposCompareText(const S1, S2: AnsiString): PtrInt;

implementation

uses
  SysUtils;   { initialized first: it installs fpwidestring's manager }

var
  { fpwidestring's manager, for its Unicode case mapping. }
  Collating: TUnicodeStringManager;

function CompareBytes(P1, P2: PAnsiChar; L1, L2: PtrInt): PtrInt;
var
  I, N: PtrInt;
begin
  N := L1;
  if L2 < N then N := L2;
  for I := 0 to N - 1 do
    if P1[I] <> P2[I] then
      Exit(PtrInt(Byte(P1[I])) - PtrInt(Byte(P2[I])));
  Result := L1 - L2;
end;

function FposCompareStr(const S1, S2: AnsiString): PtrInt;
begin
  Result := CompareBytes(PAnsiChar(S1), PAnsiChar(S2), Length(S1), Length(S2));
end;

function UpperAscii(C: AnsiChar): AnsiChar; inline;
begin
  if (C >= 'a') and (C <= 'z') then
    Result := AnsiChar(Ord(C) - 32)
  else
    Result := C;
end;

{ ASCII is folded here, byte by byte. From the first byte past ASCII in
  either string, the rest of both is compared upper-cased by
  fpwidestring: the part before is the same either way, and upper-casing
  can turn a letter past ASCII into an ASCII one (dotless i into I). }
function FposCompareText(const S1, S2: AnsiString): PtrInt;
var
  I, N: PtrInt;
  C1, C2: AnsiChar;
begin
  N := Length(S1);
  if Length(S2) < N then N := Length(S2);
  for I := 1 to N do
  begin
    C1 := S1[I];
    C2 := S2[I];
    if (Ord(C1) >= $80) or (Ord(C2) >= $80) then
      Exit(FposCompareStr(Collating.UpperAnsiStringProc(Copy(S1, I, MaxInt)),
                          Collating.UpperAnsiStringProc(Copy(S2, I, MaxInt))));
    C1 := UpperAscii(C1);
    C2 := UpperAscii(C2);
    if C1 <> C2 then
      Exit(PtrInt(Ord(C1)) - PtrInt(Ord(C2)));
  end;
  Result := Length(S1) - Length(S2);
end;

{ The length of P up to its #0, at most MaxLen; 0 for nil. }
function BoundedLength(P: PAnsiChar; MaxLen: PtrUInt): PtrInt;
begin
  Result := 0;
  if P = nil then Exit;
  while (PtrUInt(Result) < MaxLen) and (P[Result] <> #0) do
    Inc(Result);
end;

function AsString(P: PAnsiChar; Len: PtrInt): AnsiString;
begin
  SetString(Result, P, Len);
end;

function StrCompExact(S1, S2: PAnsiChar): PtrInt;
begin
  Result := CompareBytes(S1, S2, BoundedLength(S1, High(PtrUInt)), BoundedLength(S2, High(PtrUInt)));
end;

function StrICompExact(S1, S2: PAnsiChar): PtrInt;
begin
  Result := FposCompareText(AsString(S1, BoundedLength(S1, High(PtrUInt))),
                            AsString(S2, BoundedLength(S2, High(PtrUInt))));
end;

function StrLCompExact(S1, S2: PAnsiChar; MaxLen: PtrUInt): PtrInt;
begin
  Result := CompareBytes(S1, S2, BoundedLength(S1, MaxLen), BoundedLength(S2, MaxLen));
end;

function StrLICompExact(S1, S2: PAnsiChar; MaxLen: PtrUInt): PtrInt;
begin
  Result := FposCompareText(AsString(S1, BoundedLength(S1, MaxLen)),
                            AsString(S2, BoundedLength(S2, MaxLen)));
end;

function CompareUnits(P1, P2: PWideChar; L1, L2: PtrInt): PtrInt;
var
  I, N: PtrInt;
begin
  N := L1;
  if L2 < N then N := L2;
  for I := 0 to N - 1 do
    if P1[I] <> P2[I] then
      Exit(PtrInt(Ord(P1[I])) - PtrInt(Ord(P2[I])));
  Result := L1 - L2;
end;

{ fpwidestring heeds only the case options too; the others are ignored
  here as there. }
function CompareUnicodeExact(const S1, S2: UnicodeString; Options: TCompareOptions): PtrInt;
var
  A, B: UnicodeString;
begin
  if coIgnoreCase in Options then
  begin
    A := Collating.UpperUnicodeStringProc(S1);
    B := Collating.UpperUnicodeStringProc(S2);
  end
  else
  begin
    A := S1;
    B := S2;
  end;
  Result := CompareUnits(PWideChar(A), PWideChar(B), Length(A), Length(B));
end;

function CompareWideExact(const S1, S2: WideString; Options: TCompareOptions): PtrInt;
var
  A, B: WideString;
begin
  if coIgnoreCase in Options then
  begin
    A := Collating.UpperWideStringProc(S1);
    B := Collating.UpperWideStringProc(S2);
  end
  else
  begin
    A := S1;
    B := S2;
  end;
  Result := CompareUnits(PWideChar(A), PWideChar(B), Length(A), Length(B));
end;

procedure SwapComparisons;
var
  M: TUnicodeStringManager;
begin
  GetUnicodeStringManager(Collating);
  M := Collating;
  M.CompareStrAnsiStringProc := @FposCompareStr;
  M.CompareTextAnsiStringProc := @FposCompareText;
  M.StrCompAnsiStringProc := @StrCompExact;
  M.StrICompAnsiStringProc := @StrICompExact;
  M.StrLCompAnsiStringProc := @StrLCompExact;
  M.StrLICompAnsiStringProc := @StrLICompExact;
  M.CompareUnicodeStringProc := @CompareUnicodeExact;
  M.CompareWideStringProc := @CompareWideExact;
  SetUnicodeStringManager(M);
end;

initialization
  SwapComparisons;
end.
