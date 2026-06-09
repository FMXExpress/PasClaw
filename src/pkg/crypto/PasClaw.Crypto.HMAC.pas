(*
  PasClaw.Crypto.HMAC - SHA-256 and HMAC-SHA-256 over arbitrary bytes,
  with Base64 and lowercase-hex encoders for the two main webhook
  signature shapes (LINE expects Base64 in X-Line-Signature; WhatsApp
  expects "sha256=" + lowercase hex in X-Hub-Signature-256).

  Pure Pascal implementation of FIPS 180-4 SHA-256 and RFC 2104 HMAC.
  No OpenSSL, no Indy hash dependency, no platform-specific units --
  same code path under FPC ({$MODE DELPHI}) and Delphi 12. The Indy
  HMAC classes are tied to OpenSSL's EVP function pointers and the
  OpenSSL 3 export changes are flaky to detect at load time; doing the
  primitive ourselves removes that whole class of failure mode.

  ConstantTimeEqual is a length-checked byte-by-byte XOR -- never
  compare signatures with `=`, the early-out timing leaks one byte at
  a time.
*)
unit PasClaw.Crypto.HMAC;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}{$Q-}{$R-}

interface

uses
  SysUtils, Classes;

function SHA256Bytes(const Data: TBytes): TBytes;
function HMACSHA256Bytes(const Key, Data: TBytes): TBytes;
function HMACSHA256Base64(const Key, Data: TBytes): string;
function HMACSHA256HexLower(const Key, Data: TBytes): string;
function StringToBytes(const S: string): TBytes;
function BytesToHexLower(const B: TBytes): string;
function ConstantTimeEqual(const A, B: string): Boolean;

implementation

const
  SHA256_BLOCK = 64;
  SHA256_HASH  = 32;

  K: array[0..63] of LongWord = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2
  );

function RotR(X: LongWord; N: Byte): LongWord; inline;
begin
  Result := (X shr N) or (X shl (32 - N));
end;

function Ch(x, y, z: LongWord): LongWord; inline;
begin
  Result := (x and y) xor ((not x) and z);
end;

function Maj(x, y, z: LongWord): LongWord; inline;
begin
  Result := (x and y) xor (x and z) xor (y and z);
end;

function BigSig0(x: LongWord): LongWord; inline;
begin
  Result := RotR(x, 2) xor RotR(x, 13) xor RotR(x, 22);
end;

function BigSig1(x: LongWord): LongWord; inline;
begin
  Result := RotR(x, 6) xor RotR(x, 11) xor RotR(x, 25);
end;

function LilSig0(x: LongWord): LongWord; inline;
begin
  Result := RotR(x, 7) xor RotR(x, 18) xor (x shr 3);
end;

function LilSig1(x: LongWord): LongWord; inline;
begin
  Result := RotR(x, 17) xor RotR(x, 19) xor (x shr 10);
end;

procedure ProcessBlock(var State: array of LongWord; const Block: array of Byte);
var
  W: array[0..63] of LongWord;
  i: Integer;
  va, vb, vc, vd, ve, vf, vg, vh, T1, T2: LongWord;
begin
  for i := 0 to 15 do
    W[i] := (LongWord(Block[i * 4    ]) shl 24) or
            (LongWord(Block[i * 4 + 1]) shl 16) or
            (LongWord(Block[i * 4 + 2]) shl  8) or
             LongWord(Block[i * 4 + 3]);
  for i := 16 to 63 do
    W[i] := LilSig1(W[i - 2]) + W[i - 7] + LilSig0(W[i - 15]) + W[i - 16];

  va := State[0]; vb := State[1]; vc := State[2]; vd := State[3];
  ve := State[4]; vf := State[5]; vg := State[6]; vh := State[7];

  for i := 0 to 63 do
  begin
    T1 := vh + BigSig1(ve) + Ch(ve, vf, vg) + K[i] + W[i];
    T2 := BigSig0(va) + Maj(va, vb, vc);
    vh := vg; vg := vf; vf := ve; ve := vd + T1;
    vd := vc; vc := vb; vb := va; va := T1 + T2;
  end;

  State[0] := State[0] + va; State[1] := State[1] + vb;
  State[2] := State[2] + vc; State[3] := State[3] + vd;
  State[4] := State[4] + ve; State[5] := State[5] + vf;
  State[6] := State[6] + vg; State[7] := State[7] + vh;
end;

function SHA256Bytes(const Data: TBytes): TBytes;
var
  State: array[0..7] of LongWord;
  PadLen, Total, i, Pos: Integer;
  Buf: array of Byte;
  BitLen: UInt64;
  Block: array[0..63] of Byte;
begin
  State[0] := $6a09e667; State[1] := $bb67ae85; State[2] := $3c6ef372; State[3] := $a54ff53a;
  State[4] := $510e527f; State[5] := $9b05688c; State[6] := $1f83d9ab; State[7] := $5be0cd19;

  { Pad: original || 0x80 || zero bytes || 8-byte big-endian bit length.
    Total padded length is a multiple of 64. }
  PadLen := SHA256_BLOCK - ((Length(Data) + 1 + 8) mod SHA256_BLOCK);
  if PadLen = SHA256_BLOCK then PadLen := 0;
  Total := Length(Data) + 1 + PadLen + 8;
  SetLength(Buf, Total);
  if Length(Data) > 0 then
    Move(Data[0], Buf[0], Length(Data));
  Buf[Length(Data)] := $80;
  for i := Length(Data) + 1 to Length(Data) + PadLen do
    Buf[i] := 0;

  BitLen := UInt64(Length(Data)) * 8;
  for i := 0 to 7 do
    Buf[Total - 8 + i] := Byte(BitLen shr (8 * (7 - i)));

  Pos := 0;
  while Pos < Total do
  begin
    Move(Buf[Pos], Block[0], SHA256_BLOCK);
    ProcessBlock(State, Block);
    Inc(Pos, SHA256_BLOCK);
  end;

  SetLength(Result, SHA256_HASH);
  for i := 0 to 7 do
  begin
    Result[i * 4    ] := Byte(State[i] shr 24);
    Result[i * 4 + 1] := Byte(State[i] shr 16);
    Result[i * 4 + 2] := Byte(State[i] shr  8);
    Result[i * 4 + 3] := Byte(State[i]);
  end;
end;

function HMACSHA256Bytes(const Key, Data: TBytes): TBytes;
var
  K0: array[0..SHA256_BLOCK - 1] of Byte;
  IPadded, OPadded, Inner: TBytes;
  i: Integer;
  ShortKey: TBytes;
begin
  FillChar(K0, SizeOf(K0), 0);
  if Length(Key) > SHA256_BLOCK then
  begin
    ShortKey := SHA256Bytes(Key);
    Move(ShortKey[0], K0[0], Length(ShortKey));
  end
  else if Length(Key) > 0 then
    Move(Key[0], K0[0], Length(Key));

  SetLength(IPadded, SHA256_BLOCK + Length(Data));
  for i := 0 to SHA256_BLOCK - 1 do IPadded[i] := K0[i] xor $36;
  if Length(Data) > 0 then
    Move(Data[0], IPadded[SHA256_BLOCK], Length(Data));
  Inner := SHA256Bytes(IPadded);

  SetLength(OPadded, SHA256_BLOCK + SHA256_HASH);
  for i := 0 to SHA256_BLOCK - 1 do OPadded[i] := K0[i] xor $5c;
  Move(Inner[0], OPadded[SHA256_BLOCK], SHA256_HASH);
  Result := SHA256Bytes(OPadded);
end;

function StringToBytes(const S: string): TBytes;
{$IFDEF FPC}
var
  Raw: RawByteString;
{$ENDIF}
begin
  if S = '' then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  {$IFDEF FPC}
  Raw := UTF8Encode(S);
  SetLength(Result, Length(Raw));
  if Length(Raw) > 0 then
    Move(Raw[1], Result[0], Length(Raw));
  {$ELSE}
  Result := TEncoding.UTF8.GetBytes(S);
  {$ENDIF}
end;

function BytesToHexLower(const B: TBytes): string;
const
  Hex: array[0..15] of Char =
    ('0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f');
var
  i: Integer;
  Bt: Byte;
begin
  SetLength(Result, Length(B) * 2);
  for i := 0 to High(B) do
  begin
    Bt := B[i];
    Result[1 + i * 2]     := Hex[Bt shr 4];
    Result[1 + i * 2 + 1] := Hex[Bt and $F];
  end;
end;

function HMACSHA256HexLower(const Key, Data: TBytes): string;
begin
  Result := BytesToHexLower(HMACSHA256Bytes(Key, Data));
end;

function BytesToBase64(const B: TBytes): string;
const
  Alphabet: array[0..63] of Char =
    ('A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P',
     'Q','R','S','T','U','V','W','X','Y','Z','a','b','c','d','e','f',
     'g','h','i','j','k','l','m','n','o','p','q','r','s','t','u','v',
     'w','x','y','z','0','1','2','3','4','5','6','7','8','9','+','/');
var
  i, Triplets, Rem, OutLen, OPos: Integer;
  B1, B2, B3: Byte;
  N: LongWord;
begin
  Triplets := Length(B) div 3;
  Rem      := Length(B) mod 3;
  OutLen   := ((Length(B) + 2) div 3) * 4;
  SetLength(Result, OutLen);
  OPos := 1;
  for i := 0 to Triplets - 1 do
  begin
    B1 := B[i * 3];
    B2 := B[i * 3 + 1];
    B3 := B[i * 3 + 2];
    N := (LongWord(B1) shl 16) or (LongWord(B2) shl 8) or LongWord(B3);
    Result[OPos]     := Alphabet[(N shr 18) and $3F];
    Result[OPos + 1] := Alphabet[(N shr 12) and $3F];
    Result[OPos + 2] := Alphabet[(N shr  6) and $3F];
    Result[OPos + 3] := Alphabet[N          and $3F];
    Inc(OPos, 4);
  end;
  if Rem = 1 then
  begin
    B1 := B[Triplets * 3];
    Result[OPos]     := Alphabet[(B1 shr 2) and $3F];
    Result[OPos + 1] := Alphabet[(B1 shl 4) and $3F];
    Result[OPos + 2] := '=';
    Result[OPos + 3] := '=';
  end
  else if Rem = 2 then
  begin
    B1 := B[Triplets * 3];
    B2 := B[Triplets * 3 + 1];
    Result[OPos]     := Alphabet[(B1 shr 2) and $3F];
    Result[OPos + 1] := Alphabet[((B1 shl 4) or (B2 shr 4)) and $3F];
    Result[OPos + 2] := Alphabet[(B2 shl 2) and $3F];
    Result[OPos + 3] := '=';
  end;
end;

function HMACSHA256Base64(const Key, Data: TBytes): string;
begin
  Result := BytesToBase64(HMACSHA256Bytes(Key, Data));
end;

function ConstantTimeEqual(const A, B: string): Boolean;
var
  Diff: Byte;
  Len, i: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  Len := Length(A);
  Diff := 0;
  for i := 1 to Len do
    Diff := Diff or (Byte(A[i]) xor Byte(B[i]));
  Result := Diff = 0;
end;

end.
