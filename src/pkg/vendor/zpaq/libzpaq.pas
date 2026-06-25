unit libzpaq;
{ PasClaw: directives guarded so the unit also parses under Delphi. The body is
  already portable -- AnsiChar/Byte throughout, no PChar, pointer math gated by
  POINTERMATH (which Delphi supports), advanced records native to Delphi. }
{$IFDEF FPC}
  {$mode objfpc}{$H+}{$inline on}
  {$MODESWITCH AdvancedRecords}
{$ELSE}
  { Delphi: the port works in AnsiString for byte data; silence the noisy
    UnicodeString<->AnsiString cast warnings (ASCII method/filename strings). }
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}
{$Q-}{$R-}{$POINTERMATH ON}

//Pascal port of LIBZPAQ Version 7.15 (Aug. 17, 2016)
//Port by www.xelitan.com
//License: MIT

//Credits:
//libdivsufsort (C) 2003-2008 Yuta Mori, license MIT
//Some of the code for AES is from libtomcrypt 1.17 by Tom St. Denis, License: public domain
//The Salsa20/8 code for Scrypt is by D. Bernstein, License: public domain
//LibZPaq code by Matt Mahoney, License: public domain
//LIBZPAQ is a library for compression and decompression
//http://mattmahoney.net/zpaq/

interface
uses SysUtils;

{$IFNDEF FPC}
type
  QWord = UInt64;   { FPC built-in; Delphi spells it UInt64 }
{$ENDIF}

type
  U8  = Byte;
  U16 = Word;
  U32 = LongWord;
  U64 = QWord;
  TU8Array  = array of U8;
  TU16Array = array of U16;
  TU32Array = array of U32;
  TI32Array = array of Integer;
  PU8       = ^U8;

  { Base stream }
  TZPAQLStream = class
  public
    function  get(): Integer; virtual;
    procedure put(c: Integer); virtual;
    function  bread(buf: PU8; n: Integer): Integer; virtual;
    procedure bwrite(buf: PU8; n: Integer); virtual;
    function  seek(pos: Int64): Boolean; virtual;
    function  tell(): Int64; virtual;
  end;

  { SHA1 }
  TSHA1 = class
  private
    Flen: U64;
    Fs: array[0..4] of U32;
    Fw: array[0..15] of U32;
    Fresult: array[0..19] of U8;
    procedure process();
  public
    constructor Create;
    procedure put(c: Integer); inline;
    procedure bwrite(buf: PU8; n: Integer);
    function  getResult(): PU8;
    function  usize(): U64; inline;
  end;

  { SHA256 }
  TSHA256 = class
  private
    Flen: U64;
    Fs: array[0..7] of U32;
    Fw: array[0..15] of U32;
    Fresult: array[0..31] of U8;
    procedure process256();
  public
    constructor Create;
    procedure put(c: Integer); inline;
    procedure bwrite(buf: PU8; n: Integer);
    function  getResult(): PU8;
    function  usize(): U64; inline;
  end;

  { StateTable }
  TStateTable = class
  public
    ns: array[0..1023] of U8;
    constructor Create;
    function next(state, y: Integer): Integer; inline;
    function cminit(state: Integer): U32; inline;
  end;

  { Component }
  TComponent = record
    limit: Integer;
    cxt:   U32;
    a, b, c: U32;
    cm:    TU32Array;
    ht:    TU8Array;
    a16:   TU16Array;
    procedure init();
  end;

  { Forward declarations }
  TZPAQL     = class;
  TPredictor = class;

  { TZPAQL - ZPAQL virtual machine }
  TZPAQL = class
  private
    Fr: array[0..255] of U32;  // R registers
    Foutbuf: TU8Array;
    Fbufptr: Integer;
    procedure err();
  public
    Fra, Frb, Frc, Frd: U32;
    Ff: Boolean;
    Fpc: Integer;
    Fm: TU8Array;
    Fh: TU32Array;
    output: TZPAQLStream;
    sha1:   TSHA1;
    header: TU8Array;
    cend:   Integer;
    hbegin: Integer;
    hend:   Integer;
    constructor Create;
    destructor  Destroy; override;
    procedure clear();
    procedure init(hbits, mbits: Integer);
    procedure inith();
    procedure initp();
    function  read(in2: TZPAQLStream): Integer;
    procedure bwrite(out2: TZPAQLStream; pp: Boolean);
    procedure run(input: U32);
    function  execute(): Integer;
    procedure outc(c: Integer); inline;
    procedure flush();
    function  H(i: Integer): U32; inline;
    function  memory(): Double;
  end;

  { TPredictor }
  TPredictor = class
  private
    Fc8:     Integer;
    Fhmap4:  Integer;
    Fcomp:   array[0..255] of TComponent;
    Fp:      array[0..255] of Integer;
    Fh:      array[0..255] of U32;
    Fdt2k:   array[0..255] of Integer;
    Fdt:     array[0..1023] of Integer;
    Fsquasht:  array[0..4095] of U16;
    Fstretcht: array[0..32767] of SmallInt;
    Fst:     TStateTable;
    Fz:      TZPAQL;
    FinitTables: Boolean;
    function  squash(d: Integer): Integer; inline;
    function  stretch(p: Integer): Integer; inline;
    function  clamp2k(x: Integer): Integer; inline;
    function  clamp512k(x: Integer): Integer; inline;
    procedure train(var cr: TComponent; y: Integer); inline;
    function  find(var ht: TU8Array; sizebits: Integer; cxt: U32): U32;
  public
    constructor Create(var zr: TZPAQL);
    destructor  Destroy; override;
    procedure init();
    function  predict(): Integer;
    procedure update(y: Integer);
    function  isModeled(): Boolean; inline;
    function  predict0(): Integer;
    procedure update0(y: Integer);
  end;

  { TDecoder }
  TDecoder = class
  private
    Fin:   TZPAQLStream;
    Flow:  U32;
    Fhigh: U32;
    Fcurr: U32;
    Frpos: Integer;
    Fwpos: Integer;
    Fbuf:  TU8Array;
    Fpr:   TPredictor;
    function  get(): Integer;
  public
    constructor Create(var z: TZPAQL);
    destructor  Destroy; override;
    procedure init();
    procedure setInput(s: TZPAQLStream); inline;
    function  decode(p: Integer): Integer;
    function  decompress(): Integer;
    function  skip(): Integer;
    function  buffered(): Integer; inline;
    function  getInput(): TZPAQLStream; inline;
  end;

  { TPostProcessor }
  TPostProcessor = class
  private
    Fstate: Integer;
    Fhsize: Integer;
    Fph:    Integer;
    Fpm:    Integer;
    Fz:     TZPAQL;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure init(h, m: Integer);
    function  bwrite(c: Integer): Integer;
    function  getState(): Integer; inline;
  end;

  { TDecompresser }
  TDecompresser = class
  private
    type TDState = (dsBlock, dsFilename, dsComment, dsData, dsSegEnd);
    type TDecState = (decFirstSeg, decSeg, decSkip);
  private
    Fstate:        TDState;
    Fdecode_state: TDecState;
    Fdec:          TDecoder;
    Fpp:           TPostProcessor;
    Fz:            TZPAQL;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure setInput(s: TZPAQLStream);
    procedure setOutput(s: TZPAQLStream);
    function  findBlock(memptr: PDouble): Boolean;
    function  findFilename(filename: TZPAQLStream): Boolean;
    procedure readComment(comment: TZPAQLStream);
    function  decompress(n: Integer): Boolean;
    procedure readSegmentEnd(sha1string: PAnsiChar);
    function  getPos(): Int64;
  end;

  { TStringBuffer - in-memory read/write stream }
  TStringBuffer = class(TZPAQLStream)
  private
    Fdata: TU8Array;
    Fsize: Integer;
    Frpos: Integer;
  public
    constructor Create(n: Integer = 0);
    function  get(): Integer; override;
    procedure put(c: Integer); override;
    function  bread(buf: PU8; n: Integer): Integer; override;
    procedure bwrite(buf: PU8; n: Integer); override;
    function  data(): PU8; inline;
    function  size(): Integer; inline;
    procedure resize(n: Integer);
    function  c_str(): PAnsiChar; inline;
  end;

  { TEncoder }
  TEncoder = class
  private
    Flow: U32;
    Fhigh: U32;
    Fbuf:  TU8Array;
    Fpr:   TPredictor;
  public
    Fout:  TZPAQLStream;
    constructor Create(var z: TZPAQL);
    destructor  Destroy; override;
    procedure init();
    procedure encode(y, p: Integer);
    procedure compress(c: Integer);
    procedure setOutput(s: TZPAQLStream); inline;
  end;

  { TCompressor states }
  TCompState = (csInit, csBlock1, csBlock2, csSeg1, csSeg2);

  { TCompressor }
  TCompressor = class
  private
    Fstate:  TCompState;
    Fenc:    TEncoder;
    Fz:      TZPAQL;
    Fpz:     TZPAQL;
    Fsha1:   TSHA1;
    Fsha1result: array[0..19] of AnsiChar;
    Fverify: Boolean;
    Fin:     TZPAQLStream;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure setOutput(s: TZPAQLStream);
    procedure setInput(s: TZPAQLStream); inline;
    procedure setVerify(v: Boolean); inline;
    procedure writeTag();
    procedure startBlock(level: Integer); overload;
    procedure startBlock(hcomp: PAnsiChar); overload;
    procedure startBlock(const config: AnsiString; args: PInteger; pcomp_cmd: TZPAQLStream); overload;
    procedure startSegment(const filename, comment: AnsiString);
    procedure postProcess(pcomp: PAnsiChar; len: Integer);
    function  compress(n: Integer): Boolean;
    procedure endSegment(sha1string: PAnsiChar);
    function  endSegmentChecksum(outsize: PInt64; dosha1: Boolean): PAnsiChar;
    procedure endBlock();
  end;

{ Helper: integer-to-string }
function itos(x: Int64; n: Integer = 1): AnsiString;

{ LZ77/BWT preprocessing }
procedure e8e9(buf: PU8; n: Integer);

{ Main compression/decompression API }
procedure zpaq_compress(input, output: TZPAQLStream; const method: AnsiString;
                        const filename: AnsiString = '';
                        const comment: AnsiString = '';
                        dosha1: Boolean = True);
procedure zpaq_decompress(input, output: TZPAQLStream);

procedure compressBlock(inbuf: TStringBuffer; out_: TZPAQLStream;
                        const method: AnsiString;
                        const filename: AnsiString;
                        const comment: AnsiString;
                        dosha1: Boolean);

implementation

{ ============================================================ }
{  Error handler (application must override or the default     }
{  raises an EZPAQError exception)                             }
{ ============================================================ }

procedure zpaq_error(const msg: AnsiString);
begin
  raise Exception.Create('ZPAQ error: ' + msg);
end;

{ ============================================================ }
{  Utility                                                      }
{ ============================================================ }

function itos(x: Int64; n: Integer): AnsiString;
var r: AnsiString;
begin
  r := '';
  repeat
    r := AnsiChar(Ord('0') + Integer(x mod 10)) + r;
    x := x div 10;
    Dec(n);
  until (x = 0) and (n <= 0);
  Result := r;
end;

function lg(x: U32): Integer;
var r: Integer;
begin
  r := 0;
  if x >= 65536 then begin r := 16; x := x shr 16; end;
  if x >= 256   then begin Inc(r, 8); x := x shr 8; end;
  if x >= 16    then begin Inc(r, 4); x := x shr 4; end;
  Result := r + Integer(PByte(PAnsiChar(#0#1#2#2#3#3#3#3#4#4#4#4#4#4#4#4))[x]);
end;

function nbits(x: U32): Integer;
var r: Integer;
begin
  r := 0;
  while x <> 0 do begin
    Inc(r, Integer(x and 1));
    x := x shr 1;
  end;
  Result := r;
end;

function SarInt(x, n: Integer): Integer; inline;
begin
  if x >= 0 then Result := x shr n
  else Result := not(not(x) shr n);
end;

function toU16(p: PAnsiChar): Integer; inline;
begin
  Result := U8(p[0]) or (U8(p[1]) shl 8);
end;

{ ============================================================ }
{  TZPAQLStream                                                 }
{ ============================================================ }

function TZPAQLStream.get(): Integer;
begin
  Result := -1;
end;

procedure TZPAQLStream.put(c: Integer);
begin
end;

function TZPAQLStream.bread(buf: PU8; n: Integer): Integer;
var i, c: Integer;
begin
  for i := 0 to n - 1 do begin
    c := get();
    if c < 0 then begin Result := i; Exit; end;
    buf[i] := U8(c);
  end;
  Result := n;
end;

procedure TZPAQLStream.bwrite(buf: PU8; n: Integer);
var i: Integer;
begin
  for i := 0 to n - 1 do put(buf[i]);
end;

function TZPAQLStream.seek(pos: Int64): Boolean;
begin
  Result := False;
end;

function TZPAQLStream.tell(): Int64;
begin
  Result := -1;
end;

{ ============================================================ }
{  TSHA1                                                        }
{ ============================================================ }

constructor TSHA1.Create;
begin
  inherited Create;
  Flen := 0;
  Fs[0] := $67452301;
  Fs[1] := $EFCDAB89;
  Fs[2] := $98BADCFE;
  Fs[3] := $10325476;
  Fs[4] := $C3D2E1F0;
  FillChar(Fw, SizeOf(Fw), 0);
  FillChar(Fresult, SizeOf(Fresult), 0);
end;

procedure TSHA1.put(c: Integer);
begin
  Fw[U32(Flen) shr 5 and 15] :=
    (Fw[U32(Flen) shr 5 and 15] shl 8) or U32(c and 255);
  Inc(Flen, 8);
  if U32(Flen) and 511 = 0 then process();
end;

procedure TSHA1.bwrite(buf: PU8; n: Integer);
var i: Integer;
begin
  for i := 0 to n - 1 do put(buf[i]);
end;

procedure TSHA1.process();
var
  a, b, c, d, e, t, ww: U32;
  i: Integer;
begin
  a := Fs[0]; b := Fs[1]; c := Fs[2]; d := Fs[3]; e := Fs[4];
  for i := 0 to 79 do begin
    if i >= 16 then begin
      ww := Fw[i and 15] xor Fw[(i+2) and 15] xor Fw[(i+8) and 15] xor Fw[(i+13) and 15];
      Fw[i and 15] := (ww shl 1) or (ww shr 31);
    end;
    t := (a shl 5) or (a shr 27);
    if i < 20 then
      t := t + ((b and c) or ((not b) and d)) + $5A827999
    else if i < 40 then
      t := t + (b xor c xor d) + $6ED9EBA1
    else if i < 60 then
      t := t + ((b and c) or (b and d) or (c and d)) + $8F1BBCDC
    else
      t := t + (b xor c xor d) + $CA62C1D6;
    t := t + e + Fw[i and 15];
    e := d; d := c;
    c := (b shl 30) or (b shr 2);
    b := a; a := t;
  end;
  Inc(Fs[0], a); Inc(Fs[1], b); Inc(Fs[2], c); Inc(Fs[3], d); Inc(Fs[4], e);
end;

function TSHA1.getResult(): PU8;
var i: Integer; len: U64;
begin
  // save length, pad
  len := Flen;
  put($80);
  while U32(Flen) and 511 <> 448 do put(0);
  // length in bits big-endian 64-bit
  put(len shr 56); put(len shr 48); put(len shr 40); put(len shr 32);
  put(len shr 24); put(len shr 16); put(len shr 8);  put(len);
  // extract big-endian
  for i := 0 to 4 do begin
    Fresult[i*4+0] := U8(Fs[i] shr 24);
    Fresult[i*4+1] := U8(Fs[i] shr 16);
    Fresult[i*4+2] := U8(Fs[i] shr 8);
    Fresult[i*4+3] := U8(Fs[i]);
  end;
  Result := @Fresult[0];
end;

function TSHA1.usize(): U64;
begin
  Result := Flen shr 3;
end;

{ ============================================================ }
{  TSHA256                                                      }
{ ============================================================ }

const SHA256_K: array[0..63] of U32 = (
  $428a2f98,$71374491,$b5c0fbcf,$e9b5dba5,$3956c25b,$59f111f1,$923f82a4,$ab1c5ed5,
  $d807aa98,$12835b01,$243185be,$550c7dc3,$72be5d74,$80deb1fe,$9bdc06a7,$c19bf174,
  $e49b69c1,$efbe4786,$0fc19dc6,$240ca1cc,$2de92c6f,$4a7484aa,$5cb0a9dc,$76f988da,
  $983e5152,$a831c66d,$b00327c8,$bf597fc7,$c6e00bf3,$d5a79147,$06ca6351,$14292967,
  $27b70a85,$2e1b2138,$4d2c6dfc,$53380d13,$650a7354,$766a0abb,$81c2c92e,$92722c85,
  $a2bfe8a1,$a81a664b,$c24b8b70,$c76c51a3,$d192e819,$d6990624,$f40e3585,$106aa070,
  $19a4c116,$1e376c08,$2748774c,$34b0bcb5,$391c0cb3,$4ed8aa4a,$5b9cca4f,$682e6ff3,
  $748f82ee,$78a5636f,$84c87814,$8cc70208,$90befffa,$a4506ceb,$bef9a3f7,$c67178f2
);

constructor TSHA256.Create;
begin
  inherited Create;
  Flen := 0;
  Fs[0] := $6a09e667; Fs[1] := $bb67ae85; Fs[2] := $3c6ef372; Fs[3] := $a54ff53a;
  Fs[4] := $510e527f; Fs[5] := $9b05688c; Fs[6] := $1f83d9ab; Fs[7] := $5be0cd19;
  FillChar(Fw, SizeOf(Fw), 0);
  FillChar(Fresult, SizeOf(Fresult), 0);
end;

procedure TSHA256.put(c: Integer);
begin
  Fw[U32(Flen) shr 5 and 15] :=
    (Fw[U32(Flen) shr 5 and 15] shl 8) or U32(c and 255);
  Inc(Flen, 8);
  if U32(Flen) and 511 = 0 then process256();
end;

procedure TSHA256.bwrite(buf: PU8; n: Integer);
var i: Integer;
begin
  for i := 0 to n - 1 do put(buf[i]);
end;

procedure TSHA256.process256();
var
  a, b, c, d, e, f, g, h, t1, t2, ww: U32;
  W: array[0..63] of U32;
  i: Integer;
begin
  for i := 0 to 15 do W[i] := Fw[i];
  for i := 16 to 63 do begin
    ww := W[i-2]; ww := ((ww shr 17) or (ww shl 15)) xor ((ww shr 19) or (ww shl 13)) xor (ww shr 10);
    t1 := W[i-15]; t1 := ((t1 shr 7) or (t1 shl 25)) xor ((t1 shr 18) or (t1 shl 14)) xor (t1 shr 3);
    W[i] := ww + W[i-7] + t1 + W[i-16];
  end;
  a := Fs[0]; b := Fs[1]; c := Fs[2]; d := Fs[3];
  e := Fs[4]; f := Fs[5]; g := Fs[6]; h := Fs[7];
  for i := 0 to 63 do begin
    t1 := h + (((e shr 6)or(e shl 26)) xor ((e shr 11)or(e shl 21)) xor ((e shr 25)or(e shl 7)))
            + ((e and f) xor ((not e) and g)) + SHA256_K[i] + W[i];
    t2 := (((a shr 2)or(a shl 30)) xor ((a shr 13)or(a shl 19)) xor ((a shr 22)or(a shl 10)))
            + ((a and b) xor (a and c) xor (b and c));
    h := g; g := f; f := e; e := d + t1;
    d := c; c := b; b := a; a := t1 + t2;
  end;
  Inc(Fs[0], a); Inc(Fs[1], b); Inc(Fs[2], c); Inc(Fs[3], d);
  Inc(Fs[4], e); Inc(Fs[5], f); Inc(Fs[6], g); Inc(Fs[7], h);
end;

function TSHA256.getResult(): PU8;
var i: Integer; len: U64;
begin
  len := Flen;
  put($80);
  while U32(Flen) and 511 <> 448 do put(0);
  put(len shr 56); put(len shr 48); put(len shr 40); put(len shr 32);
  put(len shr 24); put(len shr 16); put(len shr 8);  put(len);
  for i := 0 to 7 do begin
    Fresult[i*4+0] := U8(Fs[i] shr 24);
    Fresult[i*4+1] := U8(Fs[i] shr 16);
    Fresult[i*4+2] := U8(Fs[i] shr 8);
    Fresult[i*4+3] := U8(Fs[i]);
  end;
  Result := @Fresult[0];
end;

function TSHA256.usize(): U64;
begin
  Result := Flen shr 3;
end;

{ ============================================================ }
{  TStateTable                                                  }
{ ============================================================ }

const SNS: array[0..1023] of U8 = (
  1, 2, 0, 0, 3, 5, 1, 0,
  4, 6, 0, 1, 7, 9, 2, 0,
  8, 11, 1, 1, 8, 11, 1, 1,
  10, 12, 0, 2, 13, 15, 3, 0,
  14, 17, 2, 1, 14, 17, 2, 1,
  16, 19, 1, 2, 16, 19, 1, 2,
  18, 20, 0, 3, 21, 23, 4, 0,
  22, 25, 3, 1, 22, 25, 3, 1,
  24, 27, 2, 2, 24, 27, 2, 2,
  26, 29, 1, 3, 26, 29, 1, 3,
  28, 30, 0, 4, 31, 33, 5, 0,
  32, 35, 4, 1, 32, 35, 4, 1,
  34, 37, 3, 2, 34, 37, 3, 2,
  36, 39, 2, 3, 36, 39, 2, 3,
  38, 41, 1, 4, 38, 41, 1, 4,
  40, 42, 0, 5, 43, 33, 6, 0,
  44, 47, 5, 1, 44, 47, 5, 1,
  46, 49, 4, 2, 46, 49, 4, 2,
  48, 51, 3, 3, 48, 51, 3, 3,
  50, 53, 2, 4, 50, 53, 2, 4,
  52, 55, 1, 5, 52, 55, 1, 5,
  40, 56, 0, 6, 57, 45, 7, 0,
  58, 47, 6, 1, 58, 47, 6, 1,
  60, 63, 5, 2, 60, 63, 5, 2,
  62, 65, 4, 3, 62, 65, 4, 3,
  64, 67, 3, 4, 64, 67, 3, 4,
  66, 69, 2, 5, 66, 69, 2, 5,
  52, 71, 1, 6, 52, 71, 1, 6,
  54, 72, 0, 7, 73, 59, 8, 0,
  74, 61, 7, 1, 74, 61, 7, 1,
  76, 63, 6, 2, 76, 63, 6, 2,
  78, 81, 5, 3, 78, 81, 5, 3,
  80, 83, 4, 4, 80, 83, 4, 4,
  82, 85, 3, 5, 82, 85, 3, 5,
  66, 87, 2, 6, 66, 87, 2, 6,
  68, 89, 1, 7, 68, 89, 1, 7,
  70, 90, 0, 8, 91, 59, 9, 0,
  92, 77, 8, 1, 92, 77, 8, 1,
  94, 79, 7, 2, 94, 79, 7, 2,
  96, 81, 6, 3, 96, 81, 6, 3,
  98, 101, 5, 4, 98, 101, 5, 4,
  100, 103, 4, 5, 100, 103, 4, 5,
  82, 105, 3, 6, 82, 105, 3, 6,
  84, 107, 2, 7, 84, 107, 2, 7,
  86, 109, 1, 8, 86, 109, 1, 8,
  70, 110, 0, 9, 111, 59, 10, 0,
  112, 77, 9, 1, 112, 77, 9, 1,
  114, 97, 8, 2, 114, 97, 8, 2,
  116, 99, 7, 3, 116, 99, 7, 3,
  62, 101, 6, 4, 62, 101, 6, 4,
  80, 83, 5, 5, 80, 83, 5, 5,
  100, 67, 4, 6, 100, 67, 4, 6,
  102, 119, 3, 7, 102, 119, 3, 7,
  104, 121, 2, 8, 104, 121, 2, 8,
  86, 123, 1, 9, 86, 123, 1, 9,
  70, 124, 0, 10, 125, 59, 11, 0,
  126, 77, 10, 1, 126, 77, 10, 1,
  128, 97, 9, 2, 128, 97, 9, 2,
  60, 63, 8, 3, 60, 63, 8, 3,
  66, 69, 3, 8, 66, 69, 3, 8,
  104, 131, 2, 9, 104, 131, 2, 9,
  86, 133, 1, 10, 86, 133, 1, 10,
  70, 134, 0, 11, 135, 59, 12, 0,
  136, 77, 11, 1, 136, 77, 11, 1,
  138, 97, 10, 2, 138, 97, 10, 2,
  104, 141, 2, 10, 104, 141, 2, 10,
  86, 143, 1, 11, 86, 143, 1, 11,
  70, 144, 0, 12, 145, 59, 13, 0,
  146, 77, 12, 1, 146, 77, 12, 1,
  148, 97, 11, 2, 148, 97, 11, 2,
  104, 151, 2, 11, 104, 151, 2, 11,
  86, 153, 1, 12, 86, 153, 1, 12,
  70, 154, 0, 13, 155, 59, 14, 0,
  156, 77, 13, 1, 156, 77, 13, 1,
  158, 97, 12, 2, 158, 97, 12, 2,
  104, 161, 2, 12, 104, 161, 2, 12,
  86, 163, 1, 13, 86, 163, 1, 13,
  70, 164, 0, 14, 165, 59, 15, 0,
  166, 77, 14, 1, 166, 77, 14, 1,
  168, 97, 13, 2, 168, 97, 13, 2,
  104, 171, 2, 13, 104, 171, 2, 13,
  86, 173, 1, 14, 86, 173, 1, 14,
  70, 174, 0, 15, 175, 59, 16, 0,
  176, 77, 15, 1, 176, 77, 15, 1,
  178, 97, 14, 2, 178, 97, 14, 2,
  104, 181, 2, 14, 104, 181, 2, 14,
  86, 183, 1, 15, 86, 183, 1, 15,
  70, 184, 0, 16, 185, 59, 17, 0,
  186, 77, 16, 1, 186, 77, 16, 1,
  74, 97, 15, 2, 74, 97, 15, 2,
  104, 89, 2, 15, 104, 89, 2, 15,
  86, 187, 1, 16, 86, 187, 1, 16,
  70, 188, 0, 17, 189, 59, 18, 0,
  190, 77, 17, 1, 86, 191, 1, 17,
  70, 192, 0, 18, 193, 59, 19, 0,
  194, 77, 18, 1, 86, 195, 1, 18,
  70, 196, 0, 19, 193, 59, 20, 0,
  197, 77, 19, 1, 86, 198, 1, 19,
  70, 196, 0, 20, 199, 77, 20, 1,
  86, 200, 1, 20, 201, 77, 21, 1,
  86, 202, 1, 21, 203, 77, 22, 1,
  86, 204, 1, 22, 205, 77, 23, 1,
  86, 206, 1, 23, 207, 77, 24, 1,
  86, 208, 1, 24, 209, 77, 25, 1,
  86, 210, 1, 25, 211, 77, 26, 1,
  86, 212, 1, 26, 213, 77, 27, 1,
  86, 214, 1, 27, 215, 77, 28, 1,
  86, 216, 1, 28, 217, 77, 29, 1,
  86, 218, 1, 29, 219, 77, 30, 1,
  86, 220, 1, 30, 221, 77, 31, 1,
  86, 222, 1, 31, 223, 77, 32, 1,
  86, 224, 1, 32, 225, 77, 33, 1,
  86, 226, 1, 33, 227, 77, 34, 1,
  86, 228, 1, 34, 229, 77, 35, 1,
  86, 230, 1, 35, 231, 77, 36, 1,
  86, 232, 1, 36, 233, 77, 37, 1,
  86, 234, 1, 37, 235, 77, 38, 1,
  86, 236, 1, 38, 237, 77, 39, 1,
  86, 238, 1, 39, 239, 77, 40, 1,
  86, 240, 1, 40, 241, 77, 41, 1,
  86, 242, 1, 41, 243, 77, 42, 1,
  86, 244, 1, 42, 245, 77, 43, 1,
  86, 246, 1, 43, 247, 77, 44, 1,
  86, 248, 1, 44, 249, 77, 45, 1,
  86, 250, 1, 45, 251, 77, 46, 1,
  86, 252, 1, 46, 253, 77, 47, 1,
  86, 254, 1, 47, 253, 77, 48, 1,
  86, 254, 1, 48, 0, 0, 0, 0
);

constructor TStateTable.Create;
begin
  inherited Create;
  Move(SNS[0], ns[0], 1024);
end;

function TStateTable.next(state, y: Integer): Integer;
begin
  Result := ns[state * 4 + y];
end;

function TStateTable.cminit(state: Integer): U32;
begin
  Result := ((U32(ns[state*4+3])*2+1) shl 22) div
            (U32(ns[state*4+2]) + U32(ns[state*4+3]) + 1);
end;

{ ============================================================ }
{  TComponent                                                   }
{ ============================================================ }

procedure TComponent.init();
begin
  limit := 0; cxt := 0; a := 0; b := 0; c := 0;
  SetLength(cm, 0); SetLength(ht, 0); SetLength(a16, 0);
end;

{ ============================================================ }
{  compsize                                                     }
{ ============================================================ }

const compsize: array[0..9] of Integer = (0,2,3,2,3,4,6,6,3,5);
const NONE = 0; CONS = 1; CM = 2; ICM = 3; MATCH = 4;
      AVG = 5; MIX2 = 6; MIX = 7; ISSE = 8; SSE = 9;
const BUFSIZE_DEC = 65536;

{ ============================================================ }
{  TZPAQL                                                       }
{ ============================================================ }

constructor TZPAQL.Create;
begin
  inherited Create;
  output := nil;
  sha1   := nil;
  SetLength(Foutbuf, 1 shl 14);
  Fbufptr := 0;
  clear();
end;

destructor TZPAQL.Destroy;
begin
  inherited Destroy;
end;

procedure TZPAQL.clear();
begin
  cend := 0; hbegin := 0; hend := 0;
  Fra := 0; Frb := 0; Frc := 0; Frd := 0;
  Ff := False; Fpc := 0;
  SetLength(header, 0);
  SetLength(Fh, 0);
  SetLength(Fm, 0);
  FillChar(Fr, SizeOf(Fr), 0);
end;

procedure TZPAQL.init(hbits, mbits: Integer);
var i: Integer;
begin
  if hbits > 32 then zpaq_error('H too big');
  if mbits > 32 then zpaq_error('M too big');
  // h: 2^hbits entries
  SetLength(Fh, 1 shl hbits);
  // m: 2^mbits entries
  SetLength(Fm, 1 shl mbits);
  FillChar(Fh[0], Length(Fh)*4, 0);
  FillChar(Fm[0], Length(Fm), 0);
  for i := 0 to 255 do Fr[i] := 0;
  Fra := 0; Frb := 0; Frc := 0; Frd := 0;
  Ff := False; Fpc := 0;
  Fbufptr := 0;
end;

procedure TZPAQL.inith();
begin
  init(header[2], header[3]);
end;

procedure TZPAQL.initp();
begin
  init(header[4], header[5]);
end;

procedure TZPAQL.flush();
begin
  if output <> nil then output.bwrite(@Foutbuf[0], Fbufptr);
  if sha1   <> nil then sha1.bwrite(@Foutbuf[0], Fbufptr);
  Fbufptr := 0;
end;

procedure TZPAQL.outc(c: Integer);
begin
  if Fbufptr >= Length(Foutbuf) then flush();
  Foutbuf[Fbufptr] := U8(c);
  Inc(Fbufptr);
end;

function TZPAQL.H(i: Integer): U32;
begin
  Result := Fh[i and (Length(Fh)-1)];
end;

function TZPAQL.read(in2: TZPAQLStream): Integer;
var hsize, n, i, op, tp: Integer;
begin
  hsize := in2.get();
  hsize := hsize + in2.get() * 256;
  SetLength(header, hsize + 300);
  cend := 0; hbegin := 0; hend := 0;
  header[cend] := hsize and 255; Inc(cend);
  header[cend] := hsize shr 8;   Inc(cend);
  while cend < 7 do begin header[cend] := in2.get(); Inc(cend); end;
  n := header[cend-1];
  for i := 0 to n-1 do begin
    tp := in2.get();
    if (tp < 0) or (tp > 255) then zpaq_error('unexpected end of file');
    header[cend] := tp; Inc(cend);
    if compsize[tp] < 1 then zpaq_error('Invalid component type');
    if cend + compsize[tp] > hsize then zpaq_error('COMP overflows header');
    for op := 1 to compsize[tp]-1 do begin
      header[cend] := in2.get(); Inc(cend);
    end;
  end;
  header[cend] := in2.get();
  if header[cend] <> 0 then zpaq_error('missing COMP END');
  Inc(cend);
  hbegin := cend + 128;
  hend := hbegin;
  if hend > hsize + 129 then zpaq_error('missing HCOMP');
  while hend < hsize + 129 do begin
    op := in2.get();
    if op = -1 then zpaq_error('unexpected end of file');
    header[hend] := op;
    Inc(hend);
  end;
  header[hend] := in2.get();
  if header[hend] <> 0 then zpaq_error('missing HCOMP END');
  Inc(hend);
  Result := cend + hend - hbegin;
end;

procedure TZPAQL.bwrite(out2: TZPAQLStream; pp: Boolean);
var i: Integer;
begin
  if Length(header) <= 6 then Exit;
  if not pp then begin
    for i := 0 to cend-1 do out2.put(header[i]);
  end else begin
    out2.put((hend - hbegin) and 255);
    out2.put((hend - hbegin) shr 8);
  end;
  for i := hbegin to hend-1 do out2.put(header[i]);
end;

function TZPAQL.memory(): Double;
var mem: Double; cp, i: Integer; sz: Double;
begin
  mem := 4*(1 shl header[2]) + (1 shl header[3])
       + 4*(1 shl header[4]) + (1 shl header[5])
       + Length(header);
  cp := 7;
  for i := 0 to header[6]-1 do begin
    sz := 1 shl header[cp+1];
    case header[cp] of
      CM:    mem := mem + 4*sz;
      ICM:   mem := mem + 64*sz + 1024;
      MATCH: mem := mem + 4*sz + (1 shl header[cp+2]);
      MIX2:  mem := mem + 2*sz;
      MIX:   mem := mem + 4*sz*header[cp+3];
      ISSE:  mem := mem + 64*sz + 2048;
      SSE:   mem := mem + 128*sz;
    end;
    cp := cp + compsize[header[cp]];
  end;
  Result := mem;
end;

procedure TZPAQL.err();
begin
  zpaq_error('ZPAQL execution error');
end;

procedure TZPAQL.run(input: U32);
begin
  Fpc := hbegin;
  Fra := input;
  while execute() <> 0 do ;
end;

{ Inline helpers for execute }

function TZPAQL.execute(): Integer;
var op: U8; tmp: U32; divisor: U32;
begin
  op := header[Fpc]; Inc(Fpc);

  // Macros (inlined):
  // mb(b) = Fm[Frb and (Length(Fm)-1)]
  // mc(c) = Fm[Frc and (Length(Fm)-1)]
  // hd   = Fh[Frd and (Length(Fh)-1)]

  case op of
    0:   begin err(); end;           // ERROR
    1:   Inc(Fra);                   // A++
    2:   Dec(Fra);                   // A--
    3:   Fra := not Fra;             // A!
    4:   Fra := 0;                   // A=0
    7:   begin Fra := Fr[header[Fpc]]; Inc(Fpc); end; // A=R N
    8:   begin tmp:=Fra; Fra:=Frb; Frb:=tmp; end; // B<>A
    9:   Inc(Frb);                   // B++
    10:  Dec(Frb);                   // B--
    11:  Frb := not Frb;             // B!
    12:  Frb := 0;                   // B=0
    15:  begin Frb := Fr[header[Fpc]]; Inc(Fpc); end; // B=R N
    16:  begin tmp:=Fra; Fra:=Frc; Frc:=tmp; end; // C<>A
    17:  Inc(Frc);                   // C++
    18:  Dec(Frc);                   // C--
    19:  Frc := not Frc;             // C!
    20:  Frc := 0;                   // C=0
    23:  begin Frc := Fr[header[Fpc]]; Inc(Fpc); end; // C=R N
    24:  begin tmp:=Fra; Fra:=Frd; Frd:=tmp; end; // D<>A
    25:  Inc(Frd);                   // D++
    26:  Dec(Frd);                   // D--
    27:  Frd := not Frd;             // D!
    28:  Frd := 0;                   // D=0
    31:  begin Frd := Fr[header[Fpc]]; Inc(Fpc); end; // D=R N
    32:  begin tmp:=Fra; Fra:=Fm[Frb and U32(Length(Fm)-1)]; Fm[Frb and U32(Length(Fm)-1)]:=tmp; end; // *B<>A
    33:  Inc(Fm[Frb and U32(Length(Fm)-1)]);   // *B++
    34:  Dec(Fm[Frb and U32(Length(Fm)-1)]);   // *B--
    35:  Fm[Frb and U32(Length(Fm)-1)] := not Fm[Frb and U32(Length(Fm)-1)]; // *B!
    36:  Fm[Frb and U32(Length(Fm)-1)] := 0;   // *B=0
    39:  begin // JT N
           if Ff then Fpc := Fpc + Integer(ShortInt(header[Fpc])) + 1
           else Inc(Fpc);
         end;
    40:  begin tmp:=Fra; Fra:=Fm[Frc and U32(Length(Fm)-1)]; Fm[Frc and U32(Length(Fm)-1)]:=tmp; end; // *C<>A
    41:  Inc(Fm[Frc and U32(Length(Fm)-1)]);   // *C++
    42:  Dec(Fm[Frc and U32(Length(Fm)-1)]);   // *C--
    43:  Fm[Frc and U32(Length(Fm)-1)] := not Fm[Frc and U32(Length(Fm)-1)]; // *C!
    44:  Fm[Frc and U32(Length(Fm)-1)] := 0;   // *C=0
    47:  begin // JF N
           if not Ff then Fpc := Fpc + Integer(ShortInt(header[Fpc])) + 1
           else Inc(Fpc);
         end;
    48:  begin tmp:=Fra; Fra:=Fh[Frd and U32(Length(Fh)-1)]; Fh[Frd and U32(Length(Fh)-1)]:=tmp; end; // *D<>A
    49:  Inc(Fh[Frd and U32(Length(Fh)-1)]);   // *D++
    50:  Dec(Fh[Frd and U32(Length(Fh)-1)]);   // *D--
    51:  Fh[Frd and U32(Length(Fh)-1)] := not Fh[Frd and U32(Length(Fh)-1)]; // *D!
    52:  Fh[Frd and U32(Length(Fh)-1)] := 0;   // *D=0
    55:  begin Fr[header[Fpc]] := Fra; Inc(Fpc); end; // R=A N
    56:  begin Result := 0; Exit; end; // HALT
    57:  outc(Fra and 255);           // OUT
    59:  Fra := (Fra + Fm[Frb and U32(Length(Fm)-1)] + 512) * 773; // HASH
    60:  Fh[Frd and U32(Length(Fh)-1)] := (Fh[Frd and U32(Length(Fh)-1)] + Fra + 512) * 773; // HASHD
    63:  Fpc := Fpc + Integer(ShortInt(header[Fpc])) + 1; // JMP N
    // Move instructions
    64:  ; // A=A
    65:  Fra := Frb;
    66:  Fra := Frc;
    67:  Fra := Frd;
    68:  Fra := Fm[Frb and U32(Length(Fm)-1)];
    69:  Fra := Fm[Frc and U32(Length(Fm)-1)];
    70:  Fra := Fh[Frd and U32(Length(Fh)-1)];
    71:  begin Fra := header[Fpc]; Inc(Fpc); end;
    72:  Frb := Fra;
    73:  ; // B=B
    74:  Frb := Frc;
    75:  Frb := Frd;
    76:  Frb := Fm[Frb and U32(Length(Fm)-1)];
    77:  Frb := Fm[Frc and U32(Length(Fm)-1)];
    78:  Frb := Fh[Frd and U32(Length(Fh)-1)];
    79:  begin Frb := header[Fpc]; Inc(Fpc); end;
    80:  Frc := Fra;
    81:  Frc := Frb;
    82:  ; // C=C
    83:  Frc := Frd;
    84:  Frc := Fm[Frb and U32(Length(Fm)-1)];
    85:  Frc := Fm[Frc and U32(Length(Fm)-1)];
    86:  Frc := Fh[Frd and U32(Length(Fh)-1)];
    87:  begin Frc := header[Fpc]; Inc(Fpc); end;
    88:  Frd := Fra;
    89:  Frd := Frb;
    90:  Frd := Frc;
    91:  ; // D=D
    92:  Frd := Fm[Frb and U32(Length(Fm)-1)];
    93:  Frd := Fm[Frc and U32(Length(Fm)-1)];
    94:  Frd := Fh[Frd and U32(Length(Fh)-1)];
    95:  begin Frd := header[Fpc]; Inc(Fpc); end;
    96:  Fm[Frb and U32(Length(Fm)-1)] := Fra;
    97:  Fm[Frb and U32(Length(Fm)-1)] := Frb;
    98:  Fm[Frb and U32(Length(Fm)-1)] := Frc;
    99:  Fm[Frb and U32(Length(Fm)-1)] := Frd;
    100: ; // *B=*B
    101: Fm[Frb and U32(Length(Fm)-1)] := Fm[Frc and U32(Length(Fm)-1)];
    102: Fm[Frb and U32(Length(Fm)-1)] := Fh[Frd and U32(Length(Fh)-1)];
    103: begin Fm[Frb and U32(Length(Fm)-1)] := header[Fpc]; Inc(Fpc); end;
    104: Fm[Frc and U32(Length(Fm)-1)] := Fra;
    105: Fm[Frc and U32(Length(Fm)-1)] := Frb;
    106: Fm[Frc and U32(Length(Fm)-1)] := Frc;
    107: Fm[Frc and U32(Length(Fm)-1)] := Frd;
    108: Fm[Frc and U32(Length(Fm)-1)] := Fm[Frb and U32(Length(Fm)-1)];
    109: ; // *C=*C
    110: Fm[Frc and U32(Length(Fm)-1)] := Fh[Frd and U32(Length(Fh)-1)];
    111: begin Fm[Frc and U32(Length(Fm)-1)] := header[Fpc]; Inc(Fpc); end;
    112: Fh[Frd and U32(Length(Fh)-1)] := Fra;
    113: Fh[Frd and U32(Length(Fh)-1)] := Frb;
    114: Fh[Frd and U32(Length(Fh)-1)] := Frc;
    115: Fh[Frd and U32(Length(Fh)-1)] := Frd;
    116: Fh[Frd and U32(Length(Fh)-1)] := Fm[Frb and U32(Length(Fm)-1)];
    117: Fh[Frd and U32(Length(Fh)-1)] := Fm[Frc and U32(Length(Fm)-1)];
    118: ; // *D=*D
    119: begin Fh[Frd and U32(Length(Fh)-1)] := header[Fpc]; Inc(Fpc); end;
    // Arithmetic
    128: Fra := Fra + Fra;
    129: Fra := Fra + Frb;
    130: Fra := Fra + Frc;
    131: Fra := Fra + Frd;
    132: Fra := Fra + Fm[Frb and U32(Length(Fm)-1)];
    133: Fra := Fra + Fm[Frc and U32(Length(Fm)-1)];
    134: Fra := Fra + Fh[Frd and U32(Length(Fh)-1)];
    135: begin Fra := Fra + header[Fpc]; Inc(Fpc); end;
    136: Fra := Fra - Fra;
    137: Fra := Fra - Frb;
    138: Fra := Fra - Frc;
    139: Fra := Fra - Frd;
    140: Fra := Fra - Fm[Frb and U32(Length(Fm)-1)];
    141: Fra := Fra - Fm[Frc and U32(Length(Fm)-1)];
    142: Fra := Fra - Fh[Frd and U32(Length(Fh)-1)];
    143: begin Fra := Fra - header[Fpc]; Inc(Fpc); end;
    144: Fra := Fra * Fra;
    145: Fra := Fra * Frb;
    146: Fra := Fra * Frc;
    147: Fra := Fra * Frd;
    148: Fra := Fra * Fm[Frb and U32(Length(Fm)-1)];
    149: Fra := Fra * Fm[Frc and U32(Length(Fm)-1)];
    150: Fra := Fra * Fh[Frd and U32(Length(Fh)-1)];
    151: begin Fra := Fra * header[Fpc]; Inc(Fpc); end;
    152: begin divisor := Fra;       if divisor <> 0 then Fra := Fra div divisor else Fra := 0; end;
    153: begin divisor := Frb;       if divisor <> 0 then Fra := Fra div divisor else Fra := 0; end;
    154: begin divisor := Frc;       if divisor <> 0 then Fra := Fra div divisor else Fra := 0; end;
    155: begin divisor := Frd;       if divisor <> 0 then Fra := Fra div divisor else Fra := 0; end;
    156: begin divisor := Fm[Frb and U32(Length(Fm)-1)]; if divisor <> 0 then Fra := Fra div divisor else Fra := 0; end;
    157: begin divisor := Fm[Frc and U32(Length(Fm)-1)]; if divisor <> 0 then Fra := Fra div divisor else Fra := 0; end;
    158: begin divisor := Fh[Frd and U32(Length(Fh)-1)]; if divisor <> 0 then Fra := Fra div divisor else Fra := 0; end;
    159: begin divisor := header[Fpc]; Inc(Fpc); if divisor <> 0 then Fra := Fra div divisor else Fra := 0; end;
    160: begin divisor := Fra;       if divisor <> 0 then Fra := Fra mod divisor else Fra := 0; end;
    161: begin divisor := Frb;       if divisor <> 0 then Fra := Fra mod divisor else Fra := 0; end;
    162: begin divisor := Frc;       if divisor <> 0 then Fra := Fra mod divisor else Fra := 0; end;
    163: begin divisor := Frd;       if divisor <> 0 then Fra := Fra mod divisor else Fra := 0; end;
    164: begin divisor := Fm[Frb and U32(Length(Fm)-1)]; if divisor <> 0 then Fra := Fra mod divisor else Fra := 0; end;
    165: begin divisor := Fm[Frc and U32(Length(Fm)-1)]; if divisor <> 0 then Fra := Fra mod divisor else Fra := 0; end;
    166: begin divisor := Fh[Frd and U32(Length(Fh)-1)]; if divisor <> 0 then Fra := Fra mod divisor else Fra := 0; end;
    167: begin divisor := header[Fpc]; Inc(Fpc); if divisor <> 0 then Fra := Fra mod divisor else Fra := 0; end;
    168: Fra := Fra and Fra;
    169: Fra := Fra and Frb;
    170: Fra := Fra and Frc;
    171: Fra := Fra and Frd;
    172: Fra := Fra and Fm[Frb and U32(Length(Fm)-1)];
    173: Fra := Fra and Fm[Frc and U32(Length(Fm)-1)];
    174: Fra := Fra and Fh[Frd and U32(Length(Fh)-1)];
    175: begin Fra := Fra and header[Fpc]; Inc(Fpc); end;
    176: Fra := Fra and (not Fra);
    177: Fra := Fra and (not Frb);
    178: Fra := Fra and (not Frc);
    179: Fra := Fra and (not Frd);
    180: Fra := Fra and (not Fm[Frb and U32(Length(Fm)-1)]);
    181: Fra := Fra and (not Fm[Frc and U32(Length(Fm)-1)]);
    182: Fra := Fra and (not Fh[Frd and U32(Length(Fh)-1)]);
    183: begin Fra := Fra and (not U32(header[Fpc])); Inc(Fpc); end;
    184: Fra := Fra or Fra;
    185: Fra := Fra or Frb;
    186: Fra := Fra or Frc;
    187: Fra := Fra or Frd;
    188: Fra := Fra or Fm[Frb and U32(Length(Fm)-1)];
    189: Fra := Fra or Fm[Frc and U32(Length(Fm)-1)];
    190: Fra := Fra or Fh[Frd and U32(Length(Fh)-1)];
    191: begin Fra := Fra or header[Fpc]; Inc(Fpc); end;
    192: Fra := Fra xor Fra;
    193: Fra := Fra xor Frb;
    194: Fra := Fra xor Frc;
    195: Fra := Fra xor Frd;
    196: Fra := Fra xor Fm[Frb and U32(Length(Fm)-1)];
    197: Fra := Fra xor Fm[Frc and U32(Length(Fm)-1)];
    198: Fra := Fra xor Fh[Frd and U32(Length(Fh)-1)];
    199: begin Fra := Fra xor header[Fpc]; Inc(Fpc); end;
    200: Fra := Fra shl (Fra and 31);
    201: Fra := Fra shl (Frb and 31);
    202: Fra := Fra shl (Frc and 31);
    203: Fra := Fra shl (Frd and 31);
    204: Fra := Fra shl (Fm[Frb and U32(Length(Fm)-1)] and 31);
    205: Fra := Fra shl (Fm[Frc and U32(Length(Fm)-1)] and 31);
    206: Fra := Fra shl (Fh[Frd and U32(Length(Fh)-1)] and 31);
    207: begin Fra := Fra shl (header[Fpc] and 31); Inc(Fpc); end;
    208: Fra := Fra shr (Fra and 31);
    209: Fra := Fra shr (Frb and 31);
    210: Fra := Fra shr (Frc and 31);
    211: Fra := Fra shr (Frd and 31);
    212: Fra := Fra shr (Fm[Frb and U32(Length(Fm)-1)] and 31);
    213: Fra := Fra shr (Fm[Frc and U32(Length(Fm)-1)] and 31);
    214: Fra := Fra shr (Fh[Frd and U32(Length(Fh)-1)] and 31);
    215: begin Fra := Fra shr (header[Fpc] and 31); Inc(Fpc); end;
    216: Ff := True;
    217: Ff := (Fra = Frb);
    218: Ff := (Fra = Frc);
    219: Ff := (Fra = Frd);
    220: Ff := (Fra = U32(Fm[Frb and U32(Length(Fm)-1)]));
    221: Ff := (Fra = U32(Fm[Frc and U32(Length(Fm)-1)]));
    222: Ff := (Fra = Fh[Frd and U32(Length(Fh)-1)]);
    223: begin Ff := (Fra = U32(header[Fpc])); Inc(Fpc); end;
    224: Ff := False;
    225: Ff := (Fra < Frb);
    226: Ff := (Fra < Frc);
    227: Ff := (Fra < Frd);
    228: Ff := (Fra < U32(Fm[Frb and U32(Length(Fm)-1)]));
    229: Ff := (Fra < U32(Fm[Frc and U32(Length(Fm)-1)]));
    230: Ff := (Fra < Fh[Frd and U32(Length(Fh)-1)]);
    231: begin Ff := (Fra < U32(header[Fpc])); Inc(Fpc); end;
    232: Ff := False;
    233: Ff := (Fra > Frb);
    234: Ff := (Fra > Frc);
    235: Ff := (Fra > Frd);
    236: Ff := (Fra > U32(Fm[Frb and U32(Length(Fm)-1)]));
    237: Ff := (Fra > U32(Fm[Frc and U32(Length(Fm)-1)]));
    238: Ff := (Fra > Fh[Frd and U32(Length(Fh)-1)]);
    239: begin Ff := (Fra > U32(header[Fpc])); Inc(Fpc); end;
    255: begin // LJ
           Fpc := hbegin + header[Fpc] + 256*Integer(header[Fpc+1]);
           if Fpc >= hend then err();
         end;
    else err();
  end;
  Result := 1;
end;


{ sdt lookup table }
const sdt_global: array[0..1023] of Integer = (
 87380,52428,37448,29126,23830,20164,17476,15420,13796,12482,11396,10484,9708,9038,8456,7942,
 7488,7084,6720,6392,6096,5824,5576,5348,5140,4946,4766,4598,4442,4296,4160,4032,
 3912,3798,3692,3590,3494,3404,3318,3236,3158,3084,3012,2944,2880,2818,2758,2702,
 2646,2594,2544,2496,2448,2404,2360,2318,2278,2240,2202,2166,2130,2096,2064,2032,
 2000,1970,1940,1912,1884,1858,1832,1806,1782,1758,1736,1712,1690,1668,1648,1628,
 1608,1588,1568,1550,1532,1514,1496,1480,1464,1448,1432,1416,1400,1386,1372,1358,
 1344,1330,1316,1304,1290,1278,1266,1254,1242,1230,1218,1208,1196,1186,1174,1164,
 1154,1144,1134,1124,1114,1106,1096,1086,1078,1068,1060,1052,1044,1036,1028,1020,
 1012,1004,996,988,980,974,966,960,952,946,938,932,926,918,912,906,
 900,894,888,882,876,870,864,858,852,848,842,836,832,826,820,816,
 810,806,800,796,790,786,782,776,772,768,764,758,754,750,746,742,
 738,734,730,726,722,718,714,710,706,702,698,694,690,688,684,680,
 676,672,670,666,662,660,656,652,650,646,644,640,636,634,630,628,
 624,622,618,616,612,610,608,604,602,598,596,594,590,588,586,582,
 580,578,576,572,570,568,566,562,560,558,556,554,550,548,546,544,
 542,540,538,536,532,530,528,526,524,522,520,518,516,514,512,510,
 508,506,504,502,500,498,496,494,492,490,488,488,486,484,482,480,
 478,476,474,474,472,470,468,466,464,462,462,460,458,456,454,454,
 452,450,448,448,446,444,442,442,440,438,436,436,434,432,430,430,
 428,426,426,424,422,422,420,418,418,416,414,414,412,410,410,408,
 406,406,404,402,402,400,400,398,396,396,394,394,392,390,390,388,
 388,386,386,384,382,382,380,380,378,378,376,376,374,372,372,370,
 370,368,368,366,366,364,364,362,362,360,360,358,358,356,356,354,
 354,352,352,350,350,348,348,348,346,346,344,344,342,342,340,340,
 340,338,338,336,336,334,334,332,332,332,330,330,328,328,328,326,
 326,324,324,324,322,322,320,320,320,318,318,316,316,316,314,314,
 312,312,312,310,310,310,308,308,308,306,306,304,304,304,302,302,
 302,300,300,300,298,298,298,296,296,296,294,294,294,292,292,292,
 290,290,290,288,288,288,286,286,286,284,284,284,284,282,282,282,
 280,280,280,278,278,278,276,276,276,276,274,274,274,272,272,272,
 272,270,270,270,268,268,268,268,266,266,266,266,264,264,264,262,
 262,262,262,260,260,260,260,258,258,258,258,256,256,256,256,254,
 254,254,254,252,252,252,252,250,250,250,250,248,248,248,248,248,
 246,246,246,246,244,244,244,244,242,242,242,242,242,240,240,240,
 240,238,238,238,238,238,236,236,236,236,234,234,234,234,234,232,
 232,232,232,232,230,230,230,230,230,228,228,228,228,228,226,226,
 226,226,226,224,224,224,224,224,222,222,222,222,222,220,220,220,
 220,220,220,218,218,218,218,218,216,216,216,216,216,216,214,214,
 214,214,214,212,212,212,212,212,212,210,210,210,210,210,210,208,
 208,208,208,208,208,206,206,206,206,206,206,204,204,204,204,204,
 204,204,202,202,202,202,202,202,200,200,200,200,200,200,198,198,
 198,198,198,198,198,196,196,196,196,196,196,196,194,194,194,194,
 194,194,194,192,192,192,192,192,192,192,190,190,190,190,190,190,
 190,188,188,188,188,188,188,188,186,186,186,186,186,186,186,186,
 184,184,184,184,184,184,184,182,182,182,182,182,182,182,182,180,
 180,180,180,180,180,180,180,178,178,178,178,178,178,178,178,176,
 176,176,176,176,176,176,176,176,174,174,174,174,174,174,174,174,
 172,172,172,172,172,172,172,172,172,170,170,170,170,170,170,170,
 170,170,168,168,168,168,168,168,168,168,168,166,166,166,166,166,
 166,166,166,166,166,164,164,164,164,164,164,164,164,164,162,162,
 162,162,162,162,162,162,162,162,160,160,160,160,160,160,160,160,
 160,160,158,158,158,158,158,158,158,158,158,158,158,156,156,156,
 156,156,156,156,156,156,156,154,154,154,154,154,154,154,154,154,
 154,154,152,152,152,152,152,152,152,152,152,152,152,150,150,150,
 150,150,150,150,150,150,150,150,150,148,148,148,148,148,148,148,
 148,148,148,148,148,146,146,146,146,146,146,146,146,146,146,146,
 146,144,144,144,144,144,144,144,144,144,144,144,144,142,142,142,
 142,142,142,142,142,142,142,142,142,142,140,140,140,140,140,140,
 140,140,140,140,140,140,140,138,138,138,138,138,138,138,138,138,
 138,138,138,138,138,136,136,136,136,136,136,136,136,136,136,136,
 136,136,136,134,134,134,134,134,134,134,134,134,134,134,134,134,
 134,132,132,132,132,132,132,132,132,132,132,132,132,132,132,132,
 130,130,130,130,130,130,130,130,130,130,130,130,130,130,130,128,
 128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,126
);



const sdt2k: array[0..255] of Integer = (
     0,  2048,  1024,   682,   512,   409,   341,   292,
   256,   227,   204,   186,   170,   157,   146,   136,
   128,   120,   113,   107,   102,    97,    93,    89,
    85,    81,    78,    75,    73,    70,    68,    66,
    64,    62,    60,    58,    56,    55,    53,    52,
    51,    49,    48,    47,    46,    45,    44,    43,
    42,    41,    40,    40,    39,    38,    37,    37,
    36,    35,    35,    34,    34,    33,    33,    32,
    32,    31,    31,    30,    30,    29,    29,    28,
    28,    28,    27,    27,    26,    26,    26,    25,
    25,    25,    24,    24,    24,    24,    23,    23,
    23,    23,    22,    22,    22,    22,    21,    21,
    21,    21,    20,    20,    20,    20,    20,    19,
    19,    19,    19,    19,    18,    18,    18,    18,
    18,    18,    17,    17,    17,    17,    17,    17,
    17,    16,    16,    16,    16,    16,    16,    16,
    16,    15,    15,    15,    15,    15,    15,    15,
    15,    14,    14,    14,    14,    14,    14,    14,
    14,    14,    14,    13,    13,    13,    13,    13,
    13,    13,    13,    13,    13,    13,    12,    12,
    12,    12,    12,    12,    12,    12,    12,    12,
    12,    12,    12,    11,    11,    11,    11,    11,
    11,    11,    11,    11,    11,    11,    11,    11,
    11,    11,    11,    10,    10,    10,    10,    10,
    10,    10,    10,    10,    10,    10,    10,    10,
    10,    10,    10,    10,    10,     9,     9,     9,
     9,     9,     9,     9,     9,     9,     9,     9,
     9,     9,     9,     9,     9,     9,     9,     9,
     9,     9,     9,     9,     8,     8,     8,     8,
     8,     8,     8,     8,     8,     8,     8,     8,
     8,     8,     8,     8,     8,     8,     8,     8,
     8,     8,     8,     8,     8,     8,     8,     8
);

const ssquasht: array[0..1343] of Word = (
  0, 0, 0, 0, 0, 0, 0, 1,
  1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 3, 3, 3,
  3, 3, 3, 3, 3, 3, 3, 3,
  3, 3, 3, 3, 3, 3, 3, 3,
  4, 4, 4, 4, 4, 4, 4, 4,
  4, 4, 4, 4, 4, 4, 5, 5,
  5, 5, 5, 5, 5, 5, 5, 5,
  5, 5, 6, 6, 6, 6, 6, 6,
  6, 6, 6, 6, 7, 7, 7, 7,
  7, 7, 7, 7, 8, 8, 8, 8,
  8, 8, 8, 8, 9, 9, 9, 9,
  9, 9, 10, 10, 10, 10, 10, 10,
  10, 11, 11, 11, 11, 11, 12, 12,
  12, 12, 12, 13, 13, 13, 13, 13,
  14, 14, 14, 14, 15, 15, 15, 15,
  15, 16, 16, 16, 17, 17, 17, 17,
  18, 18, 18, 18, 19, 19, 19, 20,
  20, 20, 21, 21, 21, 22, 22, 22,
  23, 23, 23, 24, 24, 25, 25, 25,
  26, 26, 27, 27, 28, 28, 28, 29,
  29, 30, 30, 31, 31, 32, 32, 33,
  33, 34, 34, 35, 36, 36, 37, 37,
  38, 38, 39, 40, 40, 41, 42, 42,
  43, 44, 44, 45, 46, 46, 47, 48,
  49, 49, 50, 51, 52, 53, 54, 54,
  55, 56, 57, 58, 59, 60, 61, 62,
  63, 64, 65, 66, 67, 68, 69, 70,
  71, 72, 73, 74, 76, 77, 78, 79,
  81, 82, 83, 84, 86, 87, 88, 90,
  91, 93, 94, 96, 97, 99, 100, 102,
  103, 105, 107, 108, 110, 112, 114, 115,
  117, 119, 121, 123, 125, 127, 129, 131,
  133, 135, 137, 139, 141, 144, 146, 148,
  151, 153, 155, 158, 160, 163, 165, 168,
  171, 173, 176, 179, 182, 184, 187, 190,
  193, 196, 199, 202, 206, 209, 212, 215,
  219, 222, 226, 229, 233, 237, 240, 244,
  248, 252, 256, 260, 264, 268, 272, 276,
  281, 285, 289, 294, 299, 303, 308, 313,
  318, 323, 328, 333, 338, 343, 349, 354,
  360, 365, 371, 377, 382, 388, 394, 401,
  407, 413, 420, 426, 433, 440, 446, 453,
  460, 467, 475, 482, 490, 497, 505, 513,
  521, 529, 537, 545, 554, 562, 571, 580,
  589, 598, 607, 617, 626, 636, 646, 656,
  666, 676, 686, 697, 708, 719, 730, 741,
  752, 764, 776, 788, 800, 812, 825, 837,
  850, 863, 876, 890, 903, 917, 931, 946,
  960, 975, 990, 1005, 1020, 1036, 1051, 1067,
  1084, 1100, 1117, 1134, 1151, 1169, 1186, 1204,
  1223, 1241, 1260, 1279, 1298, 1318, 1338, 1358,
  1379, 1399, 1421, 1442, 1464, 1486, 1508, 1531,
  1554, 1577, 1600, 1624, 1649, 1673, 1698, 1724,
  1749, 1775, 1802, 1829, 1856, 1883, 1911, 1940,
  1968, 1998, 2027, 2057, 2087, 2118, 2149, 2181,
  2213, 2245, 2278, 2312, 2345, 2380, 2414, 2450,
  2485, 2521, 2558, 2595, 2633, 2671, 2709, 2748,
  2788, 2828, 2869, 2910, 2952, 2994, 3037, 3080,
  3124, 3168, 3213, 3259, 3305, 3352, 3399, 3447,
  3496, 3545, 3594, 3645, 3696, 3747, 3799, 3852,
  3906, 3960, 4014, 4070, 4126, 4182, 4240, 4298,
  4356, 4416, 4476, 4537, 4598, 4660, 4723, 4786,
  4851, 4916, 4981, 5048, 5115, 5183, 5251, 5320,
  5390, 5461, 5533, 5605, 5678, 5752, 5826, 5901,
  5977, 6054, 6131, 6210, 6289, 6369, 6449, 6530,
  6613, 6695, 6779, 6863, 6949, 7035, 7121, 7209,
  7297, 7386, 7476, 7566, 7658, 7750, 7842, 7936,
  8030, 8126, 8221, 8318, 8415, 8513, 8612, 8712,
  8812, 8913, 9015, 9117, 9221, 9324, 9429, 9534,
  9640, 9747, 9854, 9962, 10071, 10180, 10290, 10401,
  10512, 10624, 10737, 10850, 10963, 11078, 11192, 11308,
  11424, 11540, 11658, 11775, 11893, 12012, 12131, 12251,
  12371, 12491, 12612, 12734, 12856, 12978, 13101, 13224,
  13347, 13471, 13595, 13719, 13844, 13969, 14095, 14220,
  14346, 14472, 14599, 14725, 14852, 14979, 15106, 15233,
  15361, 15488, 15616, 15744, 15872, 16000, 16128, 16256,
  16384, 16511, 16639, 16767, 16895, 17023, 17151, 17279,
  17406, 17534, 17661, 17788, 17915, 18042, 18168, 18295,
  18421, 18547, 18672, 18798, 18923, 19048, 19172, 19296,
  19420, 19543, 19666, 19789, 19911, 20033, 20155, 20276,
  20396, 20516, 20636, 20755, 20874, 20992, 21109, 21227,
  21343, 21459, 21575, 21689, 21804, 21917, 22030, 22143,
  22255, 22366, 22477, 22587, 22696, 22805, 22913, 23020,
  23127, 23233, 23338, 23443, 23546, 23650, 23752, 23854,
  23955, 24055, 24155, 24254, 24352, 24449, 24546, 24641,
  24737, 24831, 24925, 25017, 25109, 25201, 25291, 25381,
  25470, 25558, 25646, 25732, 25818, 25904, 25988, 26072,
  26154, 26237, 26318, 26398, 26478, 26557, 26636, 26713,
  26790, 26866, 26941, 27015, 27089, 27162, 27234, 27306,
  27377, 27447, 27516, 27584, 27652, 27719, 27786, 27851,
  27916, 27981, 28044, 28107, 28169, 28230, 28291, 28351,
  28411, 28469, 28527, 28585, 28641, 28697, 28753, 28807,
  28861, 28915, 28968, 29020, 29071, 29122, 29173, 29222,
  29271, 29320, 29368, 29415, 29462, 29508, 29554, 29599,
  29643, 29687, 29730, 29773, 29815, 29857, 29898, 29939,
  29979, 30019, 30058, 30096, 30134, 30172, 30209, 30246,
  30282, 30317, 30353, 30387, 30422, 30455, 30489, 30522,
  30554, 30586, 30618, 30649, 30680, 30710, 30740, 30769,
  30799, 30827, 30856, 30884, 30911, 30938, 30965, 30992,
  31018, 31043, 31069, 31094, 31118, 31143, 31167, 31190,
  31213, 31236, 31259, 31281, 31303, 31325, 31346, 31368,
  31388, 31409, 31429, 31449, 31469, 31488, 31507, 31526,
  31544, 31563, 31581, 31598, 31616, 31633, 31650, 31667,
  31683, 31700, 31716, 31731, 31747, 31762, 31777, 31792,
  31807, 31821, 31836, 31850, 31864, 31877, 31891, 31904,
  31917, 31930, 31942, 31955, 31967, 31979, 31991, 32003,
  32015, 32026, 32037, 32048, 32059, 32070, 32081, 32091,
  32101, 32111, 32121, 32131, 32141, 32150, 32160, 32169,
  32178, 32187, 32196, 32205, 32213, 32222, 32230, 32238,
  32246, 32254, 32262, 32270, 32277, 32285, 32292, 32300,
  32307, 32314, 32321, 32327, 32334, 32341, 32347, 32354,
  32360, 32366, 32373, 32379, 32385, 32390, 32396, 32402,
  32407, 32413, 32418, 32424, 32429, 32434, 32439, 32444,
  32449, 32454, 32459, 32464, 32468, 32473, 32478, 32482,
  32486, 32491, 32495, 32499, 32503, 32507, 32511, 32515,
  32519, 32523, 32527, 32530, 32534, 32538, 32541, 32545,
  32548, 32552, 32555, 32558, 32561, 32565, 32568, 32571,
  32574, 32577, 32580, 32583, 32585, 32588, 32591, 32594,
  32596, 32599, 32602, 32604, 32607, 32609, 32612, 32614,
  32616, 32619, 32621, 32623, 32626, 32628, 32630, 32632,
  32634, 32636, 32638, 32640, 32642, 32644, 32646, 32648,
  32650, 32652, 32653, 32655, 32657, 32659, 32660, 32662,
  32664, 32665, 32667, 32668, 32670, 32671, 32673, 32674,
  32676, 32677, 32679, 32680, 32681, 32683, 32684, 32685,
  32686, 32688, 32689, 32690, 32691, 32693, 32694, 32695,
  32696, 32697, 32698, 32699, 32700, 32701, 32702, 32703,
  32704, 32705, 32706, 32707, 32708, 32709, 32710, 32711,
  32712, 32713, 32713, 32714, 32715, 32716, 32717, 32718,
  32718, 32719, 32720, 32721, 32721, 32722, 32723, 32723,
  32724, 32725, 32725, 32726, 32727, 32727, 32728, 32729,
  32729, 32730, 32730, 32731, 32731, 32732, 32733, 32733,
  32734, 32734, 32735, 32735, 32736, 32736, 32737, 32737,
  32738, 32738, 32739, 32739, 32739, 32740, 32740, 32741,
  32741, 32742, 32742, 32742, 32743, 32743, 32744, 32744,
  32744, 32745, 32745, 32745, 32746, 32746, 32746, 32747,
  32747, 32747, 32748, 32748, 32748, 32749, 32749, 32749,
  32749, 32750, 32750, 32750, 32750, 32751, 32751, 32751,
  32752, 32752, 32752, 32752, 32752, 32753, 32753, 32753,
  32753, 32754, 32754, 32754, 32754, 32754, 32755, 32755,
  32755, 32755, 32755, 32756, 32756, 32756, 32756, 32756,
  32757, 32757, 32757, 32757, 32757, 32757, 32757, 32758,
  32758, 32758, 32758, 32758, 32758, 32759, 32759, 32759,
  32759, 32759, 32759, 32759, 32759, 32760, 32760, 32760,
  32760, 32760, 32760, 32760, 32760, 32761, 32761, 32761,
  32761, 32761, 32761, 32761, 32761, 32761, 32761, 32762,
  32762, 32762, 32762, 32762, 32762, 32762, 32762, 32762,
  32762, 32762, 32762, 32763, 32763, 32763, 32763, 32763,
  32763, 32763, 32763, 32763, 32763, 32763, 32763, 32763,
  32763, 32764, 32764, 32764, 32764, 32764, 32764, 32764,
  32764, 32764, 32764, 32764, 32764, 32764, 32764, 32764,
  32764, 32764, 32764, 32764, 32765, 32765, 32765, 32765,
  32765, 32765, 32765, 32765, 32765, 32765, 32765, 32765,
  32765, 32765, 32765, 32765, 32765, 32765, 32765, 32765,
  32765, 32765, 32765, 32765, 32765, 32765, 32766, 32766,
  32766, 32766, 32766, 32766, 32766, 32766, 32766, 32766,
  32766, 32766, 32766, 32766, 32766, 32766, 32766, 32766,
  32766, 32766, 32766, 32766, 32766, 32766, 32766, 32766,
  32766, 32766, 32766, 32766, 32766, 32766, 32766, 32766,
  32766, 32766, 32766, 32766, 32766, 32766, 32766, 32766,
  32766, 32766, 32767, 32767, 32767, 32767, 32767, 32767
);

const stdt: array[0..711] of Byte = (
  64, 128, 128, 128, 128, 128, 127, 128,
  127, 128, 127, 127, 127, 127, 126, 126,
  126, 126, 126, 125, 125, 124, 125, 124,
  123, 123, 123, 123, 122, 122, 121, 121,
  120, 120, 119, 119, 118, 118, 118, 116,
  117, 115, 116, 114, 114, 113, 113, 112,
  112, 111, 110, 110, 109, 108, 108, 107,
  106, 106, 105, 104, 104, 102, 103, 101,
  101, 100, 99, 98, 98, 97, 96, 96,
  94, 94, 94, 92, 92, 91, 90, 89,
  89, 88, 87, 86, 86, 84, 84, 84,
  82, 82, 81, 80, 79, 79, 78, 77,
  76, 76, 75, 74, 73, 73, 72, 71,
  70, 70, 69, 68, 67, 67, 66, 65,
  65, 64, 63, 62, 62, 61, 61, 59,
  59, 59, 57, 58, 56, 56, 55, 54,
  54, 53, 52, 52, 51, 51, 50, 49,
  49, 48, 48, 47, 47, 45, 46, 44,
  45, 43, 43, 43, 42, 41, 41, 40,
  40, 40, 39, 38, 38, 37, 37, 36,
  36, 36, 35, 34, 34, 34, 33, 32,
  33, 32, 31, 31, 30, 31, 29, 30,
  28, 29, 28, 28, 27, 27, 27, 26,
  26, 25, 26, 24, 25, 24, 24, 23,
  23, 23, 23, 22, 22, 21, 22, 21,
  20, 21, 20, 19, 20, 19, 19, 19,
  18, 18, 18, 18, 17, 17, 17, 17,
  16, 16, 16, 16, 15, 15, 15, 15,
  15, 14, 14, 14, 14, 13, 14, 13,
  13, 13, 12, 13, 12, 12, 12, 11,
  12, 11, 11, 11, 11, 11, 10, 11,
  10, 10, 10, 10, 9, 10, 9, 9,
  9, 9, 9, 8, 9, 8, 9, 8,
  8, 8, 7, 8, 8, 7, 7, 8,
  7, 7, 7, 6, 7, 7, 6, 6,
  7, 6, 6, 6, 6, 6, 6, 5,
  6, 5, 6, 5, 5, 5, 5, 5,
  5, 5, 5, 5, 4, 5, 4, 5,
  4, 4, 5, 4, 4, 4, 4, 4,
  4, 3, 4, 4, 3, 4, 4, 3,
  3, 4, 3, 3, 3, 4, 3, 3,
  3, 3, 3, 3, 2, 3, 3, 3,
  2, 3, 2, 3, 3, 2, 2, 3,
  2, 2, 3, 2, 2, 2, 2, 3,
  2, 2, 2, 2, 2, 2, 1, 2,
  2, 2, 2, 1, 2, 2, 2, 1,
  2, 1, 2, 2, 1, 2, 1, 2,
  1, 1, 2, 1, 1, 2, 1, 1,
  2, 1, 1, 1, 1, 2, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 0, 1, 1, 1, 1, 0,
  1, 1, 1, 0, 1, 1, 1, 0,
  1, 1, 0, 1, 1, 0, 1, 0,
  1, 1, 0, 1, 0, 1, 0, 1,
  0, 1, 0, 1, 0, 1, 0, 1,
  0, 1, 0, 1, 0, 1, 0, 0,
  1, 0, 1, 0, 0, 1, 0, 1,
  0, 0, 1, 0, 0, 1, 0, 0,
  1, 0, 0, 1, 0, 0, 0, 1,
  0, 0, 1, 0, 0, 0, 1, 0,
  0, 0, 1, 0, 0, 0, 1, 0,
  0, 0, 0, 1, 0, 0, 0, 0,
  1, 0, 0, 0, 0, 1, 0, 0,
  0, 0, 0, 1, 0, 0, 0, 0,
  0, 1, 0, 0, 0, 0, 0, 0,
  1, 0, 0, 0, 0, 0, 0, 0,
  1, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 1, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 1, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 1, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 1, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 1,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 1,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 1, 0
);

{ ============================================================ }
{  TPredictor                                                   }
{ ============================================================ }

constructor TPredictor.Create(var zr: TZPAQL);
begin
  inherited Create;
  Fz := zr;
  Fc8 := 1; Fhmap4 := 1; FinitTables := False;
  Fst := TStateTable.Create;
  FillChar(Fcomp, SizeOf(Fcomp), 0);
  FillChar(Fp, SizeOf(Fp), 0);
  FillChar(Fh, SizeOf(Fh), 0);
end;

destructor TPredictor.Destroy;
begin
  Fst.Free;
  inherited Destroy;
end;

function TPredictor.isModeled(): Boolean;
begin
  Result := (Length(Fz.header) > 6) and (Fz.header[6] <> 0);
end;

function TPredictor.squash(d: Integer): Integer;
begin Result := Fsquasht[d + 2048]; end;

function TPredictor.stretch(p: Integer): Integer;
begin Result := Fstretcht[p]; end;

function TPredictor.clamp2k(x: Integer): Integer;
begin
  if x < -2048 then Result := -2048
  else if x > 2047 then Result := 2047
  else Result := x;
end;

function TPredictor.clamp512k(x: Integer): Integer;
begin
  if x < -(1 shl 19) then Result := -(1 shl 19)
  else if x > (1 shl 19)-1 then Result := (1 shl 19)-1
  else Result := x;
end;

procedure TPredictor.train(var cr: TComponent; y: Integer);
var idx: U32; pn: U32; count, error: Integer;
begin
  idx := cr.cxt and U32(Length(cr.cm)-1);
  pn    := cr.cm[idx];
  count := Integer(pn and $3ff);
  error := y * 32767 - Integer(pn shr 17);
  cr.cm[idx] := pn + U32((Integer(error * Fdt[count]) and Integer(-1024)) + Integer(count < cr.limit));
end;

procedure TPredictor.init();
var i, j, k, n, cp, m_: Integer;
begin
  Fz.inith();
  if (not FinitTables) and isModeled() then begin
    FinitTables := True;
    Move(sdt2k[0], Fdt2k[0], 256*4);
    Move(sdt_global[0], Fdt[0], 1024*4);
    FillChar(Fsquasht[0], 1376 * SizeOf(Fsquasht[0]), 0);  { FillWord is FPC-only; value 0 -> FillChar is equivalent + cross-compiler }
    Move(ssquasht[0], Fsquasht[1376], 1344*2);
    for i := 2720 to 4095 do Fsquasht[i] := 32767;
    k := 16384;
    for i := 0 to 711 do
      for j := stdt[i] downto 1 do begin
        Fstretcht[k] := i; Inc(k);
      end;
    for i := 0 to 16383 do Fstretcht[i] := -Fstretcht[32767-i];
  end;
  for i := 0 to 255 do begin Fh[i] := 0; Fp[i] := 0; end;
  Fc8 := 1; Fhmap4 := 1;
  for i := 0 to 255 do Fcomp[i].init();
  if not isModeled() then Exit;
  n := Fz.header[6]; cp := 7;
  for i := 0 to n-1 do begin
    case Fz.header[cp] of
      CONS: Fp[i] := (Integer(Fz.header[cp+1]) - 128) * 4;
      CM: begin
        SetLength(Fcomp[i].cm, 1 shl Fz.header[cp+1]);
        Fcomp[i].limit := Integer(Fz.header[cp+2]) * 4;
        for j := 0 to Length(Fcomp[i].cm)-1 do Fcomp[i].cm[j] := $80000000;
      end;
      ICM: begin
        Fcomp[i].limit := 1023;
        SetLength(Fcomp[i].cm, 256);
        SetLength(Fcomp[i].ht, 64 shl Fz.header[cp+1]);
        for j := 0 to 255 do Fcomp[i].cm[j] := Fst.cminit(j);
      end;
      MATCH: begin
        SetLength(Fcomp[i].cm, 1 shl Fz.header[cp+1]);
        SetLength(Fcomp[i].ht, 1 shl Fz.header[cp+2]);
        Fcomp[i].ht[0] := 1;
      end;
      AVG: ;
      MIX2: begin
        Fcomp[i].c := U32(1) shl Fz.header[cp+1];
        SetLength(Fcomp[i].a16, 1 shl Fz.header[cp+1]);
        for j := 0 to Length(Fcomp[i].a16)-1 do Fcomp[i].a16[j] := 32768;
      end;
      MIX: begin
        m_ := Fz.header[cp+3];
        Fcomp[i].c := U32(1) shl Fz.header[cp+1];
        SetLength(Fcomp[i].cm, m_ * (1 shl Fz.header[cp+1]));
        for j := 0 to Length(Fcomp[i].cm)-1 do Fcomp[i].cm[j] := U32(65536 div m_);
      end;
      ISSE: begin
        SetLength(Fcomp[i].ht, 64 shl Fz.header[cp+1]);
        SetLength(Fcomp[i].cm, 512);
        for j := 0 to 255 do begin
          Fcomp[i].cm[j*2]   := 1 shl 15;
          Fcomp[i].cm[j*2+1] := U32(clamp512k(stretch(Integer(Fst.cminit(j) shr 8)) * 1024));
        end;
      end;
      SSE: begin
        SetLength(Fcomp[i].cm, 32 shl Fz.header[cp+1]);
        Fcomp[i].limit := Integer(Fz.header[cp+4]) * 4;
        for j := 0 to Length(Fcomp[i].cm)-1 do
          Fcomp[i].cm[j] := U32(squash((j and 31)*64 - 992)) shl 17 or Fz.header[cp+3];
      end;
    end;
    cp := cp + compsize[Fz.header[cp]];
  end;
end;

function TPredictor.find(var ht: TU8Array; sizebits: Integer; cxt: U32): U32;
var chk: U8; h0, h1, h2: U32;
begin
  chk := U8(cxt shr sizebits and 255);
  h0  := (cxt * 16) and U32(Length(ht) - 16);
  if ht[h0] = chk then begin Result := h0; Exit; end;
  h1 := h0 xor 16; if ht[h1] = chk then begin Result := h1; Exit; end;
  h2 := h0 xor 32; if ht[h2] = chk then begin Result := h2; Exit; end;
  if (ht[h0+1] <= ht[h1+1]) and (ht[h0+1] <= ht[h2+1]) then
    begin FillChar(ht[h0], 16, 0); ht[h0] := chk; Result := h0; end
  else if ht[h1+1] < ht[h2+1] then
    begin FillChar(ht[h1], 16, 0); ht[h1] := chk; Result := h1; end
  else
    begin FillChar(ht[h2], 16, 0); ht[h2] := chk; Result := h2; end;
end;

function TPredictor.predict(): Integer;
begin if isModeled() then Result := predict0() else Result := 0; end;

procedure TPredictor.update(y: Integer);
begin if isModeled() then update0(y); end;

function TPredictor.predict0(): Integer;
var n, cp, i, w, pq, wt, m_: Integer; pwt: PInteger;
begin
  n := Fz.header[6]; cp := 7;
  for i := 0 to n-1 do begin
    case Fz.header[cp] of
      CONS: ;
      CM: begin
        Fcomp[i].cxt := Fh[i] xor U32(Fhmap4);
        Fp[i] := stretch(Integer(Fcomp[i].cm[Fcomp[i].cxt and U32(Length(Fcomp[i].cm)-1)] shr 17));
      end;
      ICM: begin
        if (Fc8=1) or ((Fc8 and $f0)=16) then
          Fcomp[i].c := find(Fcomp[i].ht, Fz.header[cp+1]+2, Fh[i]+U32(16*Fc8));
        Fcomp[i].cxt := Fcomp[i].ht[Fcomp[i].c + U32(Fhmap4 and 15)];
        Fp[i] := stretch(Integer(Fcomp[i].cm[Fcomp[i].cxt and U32(Length(Fcomp[i].cm)-1)] shr 8));
      end;
      MATCH: begin
        if Fcomp[i].a = 0 then Fp[i] := 0
        else begin
          Fcomp[i].c := U32((Fcomp[i].ht[(U32(Integer(Fcomp[i].limit)-Integer(Fcomp[i].b))) and U32(Length(Fcomp[i].ht)-1)]
            shr (7-Integer(Fcomp[i].cxt))) and 1);
          Fp[i] := stretch(Fdt2k[Fcomp[i].a] * (Integer(Fcomp[i].c)*(-2)+1) and 32767);
        end;
      end;
      AVG: Fp[i] := (Fp[Fz.header[cp+1]]*Integer(Fz.header[cp+3]) +
                     Fp[Fz.header[cp+2]]*(256-Integer(Fz.header[cp+3]))) shr 8;
      MIX2: begin
        Fcomp[i].cxt := (Fh[i]+U32(Fc8 and Integer(Fz.header[cp+5]))) and (Fcomp[i].c-1);
        w := Fcomp[i].a16[Fcomp[i].cxt];
        Fp[i] := SarInt(w*Fp[Fz.header[cp+2]]+(65536-w)*Fp[Fz.header[cp+3]], 16);
      end;
      MIX: begin
        m_ := Fz.header[cp+3];
        Fcomp[i].cxt := Fh[i]+U32(Fc8 and Integer(Fz.header[cp+5]));
        Fcomp[i].cxt := (Fcomp[i].cxt and (Fcomp[i].c-1))*U32(m_);
        pwt := PInteger(@Fcomp[i].cm[Fcomp[i].cxt]);
        Fp[i] := 0;
        for w := 0 to m_-1 do Inc(Fp[i], SarInt(pwt[w],8)*Fp[Fz.header[cp+2]+w]);
        Fp[i] := clamp2k(SarInt(Fp[i],8));
      end;
      ISSE: begin
        if (Fc8=1) or ((Fc8 and $f0)=16) then
          Fcomp[i].c := find(Fcomp[i].ht, Fz.header[cp+1]+2, Fh[i]+U32(16*Fc8));
        Fcomp[i].cxt := Fcomp[i].ht[Fcomp[i].c+U32(Fhmap4 and 15)];
        pwt := PInteger(@Fcomp[i].cm[Integer(Fcomp[i].cxt)*2]);
        Fp[i] := clamp2k(SarInt(pwt[0]*Fp[Fz.header[cp+2]]+pwt[1]*64, 16));
      end;
      SSE: begin
        Fcomp[i].cxt := (Fh[i]+U32(Fc8))*32;
        pq := Fp[Fz.header[cp+2]]+992;
        if pq<0 then pq:=0; if pq>1983 then pq:=1983;
        wt := pq and 63; pq := pq shr 6;
        Inc(Fcomp[i].cxt, U32(pq));
        Fp[i] := stretch(
          (Integer(Fcomp[i].cm[Fcomp[i].cxt and U32(Length(Fcomp[i].cm)-1)] shr 10)*(64-wt)+
           Integer(Fcomp[i].cm[(Fcomp[i].cxt+1) and U32(Length(Fcomp[i].cm)-1)] shr 10)*wt) shr 13);
        Inc(Fcomp[i].cxt, U32(wt shr 5));
      end;
    end;
    cp := cp + compsize[Fz.header[cp]];
  end;
  Result := squash(Fp[n-1]);
end;

procedure TPredictor.update0(y: Integer);
var n, cp, i, err, w, m_: Integer; pwt: PInteger;
begin
  n := Fz.header[6]; cp := 7;
  for i := 0 to n-1 do begin
    case Fz.header[cp] of
      CONS: ;
      CM:   train(Fcomp[i], y);
      ICM: begin
        Fcomp[i].ht[Fcomp[i].c+U32(Fhmap4 and 15)] :=
          U8(Fst.next(Fcomp[i].ht[Fcomp[i].c+U32(Fhmap4 and 15)], y));
        Fcomp[i].cm[Fcomp[i].cxt and U32(Length(Fcomp[i].cm)-1)] :=
          Fcomp[i].cm[Fcomp[i].cxt and U32(Length(Fcomp[i].cm)-1)] +
          U32(SarInt(y*32767-Integer(Fcomp[i].cm[Fcomp[i].cxt and U32(Length(Fcomp[i].cm)-1)] shr 8),2));
      end;
      MATCH: begin
        if Integer(Fcomp[i].c)<>y then Fcomp[i].a := 0;
        Fcomp[i].ht[U32(Fcomp[i].limit) and U32(Length(Fcomp[i].ht)-1)] :=
          U8(Fcomp[i].ht[U32(Fcomp[i].limit) and U32(Length(Fcomp[i].ht)-1)]*2+U8(y));
        Inc(Fcomp[i].cxt);
        if Fcomp[i].cxt = 8 then begin
          Fcomp[i].cxt := 0;
          Inc(Fcomp[i].limit);
          Fcomp[i].limit := Fcomp[i].limit and ((1 shl Fz.header[cp+2])-1);
          if Fcomp[i].a = 0 then begin
            Fcomp[i].b := U32(Integer(Fcomp[i].limit)-Integer(Fcomp[i].cm[Fh[i] and U32(Length(Fcomp[i].cm)-1)]));
            if (Fcomp[i].b and U32(Length(Fcomp[i].ht)-1)) <> 0 then
              while (Fcomp[i].a < 255) and
                (Fcomp[i].ht[U32(Integer(Fcomp[i].limit)-Integer(Fcomp[i].a)-1) and U32(Length(Fcomp[i].ht)-1)] =
                 Fcomp[i].ht[U32(Integer(Fcomp[i].limit)-Integer(Fcomp[i].a)-Integer(Fcomp[i].b)-1) and U32(Length(Fcomp[i].ht)-1)])
              do Inc(Fcomp[i].a);
          end else if Fcomp[i].a < 255 then Inc(Fcomp[i].a);
          Fcomp[i].cm[Fh[i] and U32(Length(Fcomp[i].cm)-1)] := U32(Fcomp[i].limit);
        end;
      end;
      AVG: ;
      MIX2: begin
        err := SarInt((y*32767-squash(Fp[i]))*Integer(Fz.header[cp+4]), 5);
        w := Integer(Fcomp[i].a16[Fcomp[i].cxt]);
        w := w + SarInt(err*(Fp[Fz.header[cp+2]]-Fp[Fz.header[cp+3]])+(1 shl 12), 13);
        if w<0 then w:=0; if w>65535 then w:=65535;
        Fcomp[i].a16[Fcomp[i].cxt] := U16(w);
      end;
      MIX: begin
        m_ := Fz.header[cp+3];
        err := SarInt((y*32767-squash(Fp[i]))*Integer(Fz.header[cp+4]), 4);
        pwt := PInteger(@Fcomp[i].cm[Fcomp[i].cxt]);
        for w := 0 to m_-1 do
          pwt[w] := clamp512k(pwt[w]+SarInt(err*Fp[Fz.header[cp+2]+w]+(1 shl 12), 13));
      end;
      ISSE: begin
        err := y*32767-squash(Fp[i]);
        pwt := PInteger(@Fcomp[i].cm[Integer(Fcomp[i].cxt)*2]);
        pwt[0] := clamp512k(pwt[0]+SarInt(err*Fp[Fz.header[cp+2]]+(1 shl 12), 13));
        pwt[1] := clamp512k(pwt[1]+SarInt(err+16, 5));
        Fcomp[i].ht[Fcomp[i].c+U32(Fhmap4 and 15)] := U8(Fst.next(Integer(Fcomp[i].cxt),y));
      end;
      SSE: train(Fcomp[i], y);
    end;
    cp := cp + compsize[Fz.header[cp]];
  end;
  Fc8 := Fc8+Fc8+y;
  if Fc8 >= 256 then begin
    Fz.run(U32(Fc8-256)); Fhmap4 := 1; Fc8 := 1;
    for i := 0 to n-1 do Fh[i] := Fz.H(i);
  end else if (Fc8>=16) and (Fc8<32) then
    Fhmap4 := (Fhmap4 and $f) shl 5 or y shl 4 or 1
  else
    Fhmap4 := (Fhmap4 and $1f0) or (((Fhmap4 and $f)*2+y) and $f);
end;


{ ============================================================ }
{  TDecoder                                                     }
{ ============================================================ }

constructor TDecoder.Create(var z: TZPAQL);
begin
  inherited Create;
  Fin := nil; Flow := 1; Fhigh := $FFFFFFFF; Fcurr := 0;
  Frpos := 0; Fwpos := 0;
  SetLength(Fbuf, BUFSIZE_DEC);
  Fpr := TPredictor.Create(z);
end;

destructor TDecoder.Destroy;
begin Fpr.Free; inherited Destroy; end;

procedure TDecoder.setInput(s: TZPAQLStream);
begin Fin := s; end;

function TDecoder.get(): Integer;
begin
  if Frpos = Fwpos then begin
    Fwpos := Fin.bread(@Fbuf[0], BUFSIZE_DEC);
    Frpos := 0;
    if Fwpos <= 0 then begin Result := -1; Exit; end;
  end;
  Result := Fbuf[Frpos]; Inc(Frpos);
end;

procedure TDecoder.init();
begin
  Fpr.init();
  if Fpr.isModeled() then begin Flow := 1; Fhigh := $FFFFFFFF; Fcurr := 0; end
  else begin Flow := 0; Fhigh := 0; Fcurr := 0; end;
end;

function TDecoder.decode(p: Integer): Integer;
var mid: U32; c: Integer;
begin
  if (Fcurr < Flow) or (Fcurr > Fhigh) then zpaq_error('archive corrupted');
  mid := Flow + U32((U64(Fhigh-Flow)*U64(U32(p))) shr 16);
  if Fcurr <= mid then begin Result := 1; Fhigh := mid; end
  else begin Result := 0; Flow := mid+1; end;
  while (Fhigh xor Flow) < $1000000 do begin
    Fhigh := Fhigh shl 8 or 255;
    Flow  := Flow shl 8;
    if Flow = 0 then Inc(Flow);
    c := get();
    if c < 0 then zpaq_error('unexpected end of file');
    Fcurr := Fcurr shl 8 or U32(c);
  end;
end;

function TDecoder.decompress(): Integer;
var c, p: Integer;
begin
  if Fpr.isModeled() then begin
    if Fcurr = 0 then
      Fcurr := U32(get()) shl 24 or U32(get()) shl 16 or U32(get()) shl 8 or U32(get());
    if decode(0) <> 0 then begin
      if Fcurr <> 0 then zpaq_error('decoding end of stream');
      Result := -1; Exit;
    end else begin
      c := 1;
      while c < 256 do begin
        p := Fpr.predict()*2+1;
        c := c+c+decode(p);
        Fpr.update(c and 1);
      end;
      Result := c-256;
    end;
  end else begin
    if Fcurr = 0 then begin
      Fcurr := U32(get()) shl 24 or U32(get()) shl 16 or U32(get()) shl 8 or U32(get());
      if Fcurr = 0 then begin Result := -1; Exit; end;
    end;
    Dec(Fcurr);
    Result := get();
  end;
end;

function TDecoder.skip(): Integer;
var c: Integer;
begin
  c := -1;
  if Fpr.isModeled() then begin
    while Fcurr = 0 do Fcurr := U32(get());
    c := get();
    while Fcurr <> 0 do begin
      if c < 0 then Break;
      Fcurr := Fcurr shl 8 or U32(c);
      c := get();
    end;
    while c = 0 do c := get();
    Result := c;
  end else begin
    if Fcurr = 0 then begin
      c := get(); if c>=0 then Fcurr:=U32(c) shl 24;
      c := get(); if c>=0 then Fcurr:=Fcurr or U32(c) shl 16;
      c := get(); if c>=0 then Fcurr:=Fcurr or U32(c) shl 8;
      c := get(); if c>=0 then Fcurr:=Fcurr or U32(c);
    end;
    while Fcurr > 0 do begin
      while Fcurr > 0 do begin Dec(Fcurr); if get()<0 then begin Result:=-1; Exit; end; end;
      c := get(); if c>=0 then Fcurr:=U32(c) shl 24;
      c := get(); if c>=0 then Fcurr:=Fcurr or U32(c) shl 16;
      c := get(); if c>=0 then Fcurr:=Fcurr or U32(c) shl 8;
      c := get(); if c>=0 then Fcurr:=Fcurr or U32(c);
    end;
    if c >= 0 then c := get();
    Result := c;
  end;
end;

function TDecoder.buffered(): Integer;
begin
  Result := Fwpos - Frpos;
end;

function TDecoder.getInput(): TZPAQLStream;
begin
  Result := Fin;
end;

{ ============================================================ }
{  TPostProcessor                                               }
{ ============================================================ }

constructor TPostProcessor.Create;
begin
  inherited Create;
  Fz := TZPAQL.Create;
  Fstate := 0; Fhsize := 0; Fph := 0; Fpm := 0;
end;

destructor TPostProcessor.Destroy;
begin Fz.Free; inherited Destroy; end;

procedure TPostProcessor.init(h, m: Integer);
begin
  Fstate := 0; Fhsize := 0; Fph := h; Fpm := m;
  Fz.clear();
end;

function TPostProcessor.getState(): Integer;
begin Result := Fstate; end;

function TPostProcessor.bwrite(c: Integer): Integer;
begin
  case Fstate of
    0: begin
         if c < 0 then zpaq_error('Unexpected EOS');
         Fstate := c+1;
         if Fstate > 2 then zpaq_error('unknown post processing type');
         if Fstate = 1 then Fz.clear();
       end;
    1: begin
         if c >= 0 then Fz.outc(c)
         else Fz.flush();
       end;
    2: begin
         if c < 0 then zpaq_error('Unexpected EOS');
         Fhsize := c; Fstate := 3;
       end;
    3: begin
         if c < 0 then zpaq_error('Unexpected EOS');
         Inc(Fhsize, c*256);
         if Fhsize < 1 then zpaq_error('Empty PCOMP');
         SetLength(Fz.header, Fhsize+300);
         Fz.cend := 8; Fz.hbegin := Fz.cend+128; Fz.hend := Fz.hbegin;
         Fz.header[4] := Fph; Fz.header[5] := Fpm;
         Fstate := 4;
       end;
    4: begin
         if c < 0 then zpaq_error('Unexpected EOS');
         Fz.header[Fz.hend] := c; Inc(Fz.hend);
         if Fz.hend-Fz.hbegin = Fhsize then begin
           Fhsize := Fz.cend-2+Fz.hend-Fz.hbegin;
           Fz.header[0] := Fhsize and 255;
           Fz.header[1] := Fhsize shr 8;
           Fz.initp();
           Fstate := 5;
         end;
       end;
    5: begin
         Fz.run(U32(c));
         if c < 0 then Fz.flush();
       end;
  end;
  Result := Fstate;
end;

{ ============================================================ }
{  TDecoderStream adapter                                       }
{ ============================================================ }

type
  TDecoderStream = class(TZPAQLStream)
  private FDec: TDecoder;
  public
    constructor Create(d: TDecoder);
    function get(): Integer; override;
  end;

constructor TDecoderStream.Create(d: TDecoder);
begin inherited Create; FDec := d; end;

function TDecoderStream.get(): Integer;
begin Result := FDec.get(); end;

{ ============================================================ }
{  TDecompresser                                                }
{ ============================================================ }

constructor TDecompresser.Create;
begin
  inherited Create;
  Fz   := TZPAQL.Create;
  Fdec := TDecoder.Create(Fz);
  Fpp  := TPostProcessor.Create;
  Fstate := dsBlock;
  Fdecode_state := decFirstSeg;
end;

destructor TDecompresser.Destroy;
begin Fpp.Free; Fdec.Free; Fz.Free; inherited Destroy; end;

procedure TDecompresser.setInput(s: TZPAQLStream);
begin Fdec.setInput(s); end;

procedure TDecompresser.setOutput(s: TZPAQLStream);
begin
  Fz.output := s;
  Fpp.Fz.output := s;
end;

function TDecompresser.findBlock(memptr: PDouble): Boolean;
var h1,h2,h3,h4: U32; c: Integer; ds: TDecoderStream;
begin
  h1:=$3D49B113; h2:=$29EB7F93; h3:=$2614BE13; h4:=$3828EB13;
  c := Fdec.get();
  while c <> -1 do begin
    h1:=h1*12+U32(c); h2:=h2*20+U32(c);
    h3:=h3*28+U32(c); h4:=h4*44+U32(c);
    if (h1=$B16B88F1)and(h2=$FF5376F1)and(h3=$72AC5BF1)and(h4=$2F909AF1) then Break;
    c := Fdec.get();
  end;
  if c = -1 then begin Result := False; Exit; end;
  c := Fdec.get();
  if (c<>1) and (c<>2) then zpaq_error('unsupported ZPAQ level');
  if Fdec.get() <> 1 then zpaq_error('unsupported ZPAQL type');
  ds := TDecoderStream.Create(Fdec);
  try
    Fz.read(ds);
  finally
    ds.Free;
  end;
  if memptr <> nil then memptr^ := Fz.memory();
  Fstate := dsFilename;
  Fdecode_state := decFirstSeg;
  Result := True;
end;

function TDecompresser.findFilename(filename: TZPAQLStream): Boolean;
var c: Integer;
begin
  Result := False;
  c := Fdec.get();
  if c = 1 then begin
    repeat
      c := Fdec.get();
      if c = -1 then zpaq_error('unexpected EOF');
      if c = 0 then begin Fstate := dsComment; Result := True; Exit; end;
      if filename <> nil then filename.put(c);
    until False;
  end else if c = 255 then
    Fstate := dsBlock
  else
    zpaq_error('missing segment or end of block');
end;

procedure TDecompresser.readComment(comment: TZPAQLStream);
var c: Integer;
begin
  Fstate := dsData;
  repeat
    c := Fdec.get();
    if c = -1 then zpaq_error('unexpected EOF');
    if c = 0 then Break;
    if comment <> nil then comment.put(c);
  until False;
  if Fdec.get() <> 0 then zpaq_error('missing reserved byte');
end;

function TDecompresser.decompress(n: Integer): Boolean;
var c: Integer;
begin
  if Fdecode_state = decFirstSeg then begin
    Fdec.init();
    Fpp.init(Fz.header[4], Fz.header[5]);
    Fdecode_state := decSeg;
  end;
  while (Fpp.getState() and 3) <> 1 do
    Fpp.bwrite(Fdec.decompress());
  while n <> 0 do begin
    c := Fdec.decompress();
    Fpp.bwrite(c);
    if c = -1 then begin Fstate := dsSegEnd; Result := False; Exit; end;
    if n > 0 then Dec(n);
  end;
  Result := True;
end;

procedure TDecompresser.readSegmentEnd(sha1string: PAnsiChar);
var c, i: Integer;
begin
  c := 0;
  if Fstate = dsData then begin
    c := Fdec.skip(); Fdecode_state := decSkip;
  end else if Fstate = dsSegEnd then
    c := Fdec.get();
  Fstate := dsFilename;
  if c = 254 then begin
    if sha1string <> nil then sha1string[0] := #0;
  end else if c = 253 then begin
    if sha1string <> nil then sha1string[0] := #1;
    for i := 1 to 20 do begin
      c := Fdec.get();
      if sha1string <> nil then sha1string[i] := AnsiChar(c);
    end;
  end else
    zpaq_error('missing end of segment marker');
end;

function TDecompresser.getPos(): Int64;
begin
  Result := Fdec.getInput().tell() - Fdec.buffered();
end;

{ ============================================================ }
{  TStringBuffer                                                }
{ ============================================================ }

constructor TStringBuffer.Create(n: Integer);
begin
  inherited Create;
  Fsize := 0; Frpos := 0;
  if n > 0 then begin SetLength(Fdata, n); FillChar(Fdata[0], n, 0); Fsize := n; end;
end;

function TStringBuffer.get(): Integer;
begin
  if Frpos >= Fsize then Result := -1
  else begin Result := Fdata[Frpos]; Inc(Frpos); end;
end;

procedure TStringBuffer.put(c: Integer);
begin
  if Fsize >= Length(Fdata) then begin
    if Length(Fdata) = 0 then SetLength(Fdata, 64)
    else SetLength(Fdata, Length(Fdata)*2);
  end;
  Fdata[Fsize] := U8(c); Inc(Fsize);
end;

function TStringBuffer.bread(buf: PU8; n: Integer): Integer;
var nr: Integer;
begin
  nr := n;
  if nr > Fsize-Frpos then nr := Fsize-Frpos;
  if nr > 0 then Move(Fdata[Frpos], buf^, nr);
  Inc(Frpos, nr);
  Result := nr;
end;

procedure TStringBuffer.bwrite(buf: PU8; n: Integer);
var ns: Integer;
begin
  ns := Fsize+n;
  if ns > Length(Fdata) then begin
    if Length(Fdata) = 0 then SetLength(Fdata, ns+64)
    else while Length(Fdata) < ns do SetLength(Fdata, Length(Fdata)*2);
  end;
  Move(buf^, Fdata[Fsize], n); Inc(Fsize, n);
end;

function TStringBuffer.data(): PU8;
begin if Fsize = 0 then Result := nil else Result := @Fdata[0]; end;

function TStringBuffer.size(): Integer;
begin Result := Fsize; end;

procedure TStringBuffer.resize(n: Integer);
begin
  if n > Length(Fdata) then SetLength(Fdata, n);
  Fsize := n;
  if Frpos > Fsize then Frpos := Fsize;
end;

function TStringBuffer.c_str(): PAnsiChar;
begin if Fsize = 0 then Result := nil else Result := PAnsiChar(@Fdata[0]); end;

{ ============================================================ }
{  TEncoder                                                     }
{ ============================================================ }

constructor TEncoder.Create(var z: TZPAQL);
begin
  inherited Create;
  Flow := 1; Fhigh := $FFFFFFFF; Fout := nil;
  Fpr := TPredictor.Create(z);
end;

destructor TEncoder.Destroy;
begin Fpr.Free; inherited Destroy; end;

procedure TEncoder.setOutput(s: TZPAQLStream);
begin Fout := s; end;

procedure TEncoder.init();
begin
  Flow := 1; Fhigh := $FFFFFFFF;
  Fpr.init();
  if not Fpr.isModeled() then begin Flow := 0; SetLength(Fbuf, 1 shl 16); end;
end;

procedure TEncoder.encode(y, p: Integer);
var mid: U32;
begin
  mid := Flow + U32((U64(Fhigh-Flow)*U64(U32(p))) shr 16);
  if y <> 0 then Fhigh := mid else Flow := mid+1;
  while (Fhigh xor Flow) < $1000000 do begin
    Fout.put(Fhigh shr 24);
    Fhigh := Fhigh shl 8 or 255;
    Flow  := Flow shl 8;
    if Flow = 0 then Inc(Flow);
  end;
end;

procedure TEncoder.compress(c: Integer);
var i, p, y: Integer;
begin
  if Fpr.isModeled() then begin
    if c = -1 then encode(1, 0)
    else begin
      encode(0, 0);
      for i := 7 downto 0 do begin
        p := Fpr.predict()*2+1;
        y := (c shr i) and 1;
        encode(y, p);
        Fpr.update(y);
      end;
    end;
  end else begin
    if (Flow <> 0) and ((c < 0) or (Integer(Flow) = Length(Fbuf))) then begin
      Fout.put((Flow shr 24) and 255); Fout.put((Flow shr 16) and 255);
      Fout.put((Flow shr 8) and 255);  Fout.put(Flow and 255);
      Fout.bwrite(@Fbuf[0], Flow);
      Flow := 0;
    end;
    if c >= 0 then begin
      if Flow >= U32(Length(Fbuf)) then SetLength(Fbuf, Length(Fbuf)*2);
      Fbuf[Flow] := U8(c); Inc(Flow);
    end;
  end;
end;

{ ============================================================ }
{  TCompressor                                                  }
{ ============================================================ }

constructor TCompressor.Create;
begin
  inherited Create;
  Fz   := TZPAQL.Create;
  Fpz  := TZPAQL.Create;
  Fsha1 := TSHA1.Create;
  Fenc := TEncoder.Create(Fz);
  Fstate  := csInit;
  Fverify := False;
  Fin     := nil;
  FillChar(Fsha1result, SizeOf(Fsha1result), 0);
end;

destructor TCompressor.Destroy;
begin
  Fenc.Free; Fsha1.Free; Fpz.Free; Fz.Free;
  inherited Destroy;
end;

procedure TCompressor.setOutput(s: TZPAQLStream);
begin Fenc.setOutput(s); end;

procedure TCompressor.setInput(s: TZPAQLStream);
begin Fin := s; end;

procedure TCompressor.setVerify(v: Boolean);
begin Fverify := v; end;

procedure TCompressor.writeTag();
begin
  Fenc.Fout.put($37); Fenc.Fout.put($6b); Fenc.Fout.put($53); Fenc.Fout.put($74);
  Fenc.Fout.put($a0); Fenc.Fout.put($31); Fenc.Fout.put($83); Fenc.Fout.put($d3);
  Fenc.Fout.put($8c); Fenc.Fout.put($b2); Fenc.Fout.put($28); Fenc.Fout.put($b0);
  Fenc.Fout.put($d3);
end;

{ Models for startBlock(level) }
const MODELS_DATA: array[0..298] of Byte = (
  { Model 1 }
  26,0,1,2,0,0,2,3,16,8,19,0,0,96,4,28,
  59,10,59,112,25,10,59,10,59,112,56,0,
  { Model 2 }
  69,0,3,3,0,0,8,3,5,8,13,0,8,17,1,8,
  18,2,8,18,3,8,19,4,4,22,24,7,16,0,7,24,
  255,0,17,104,74,4,95,1,59,112,10,25,59,112,10,25,
  59,112,10,25,59,112,10,25,59,112,10,25,59,10,59,112,
  25,69,207,8,112,56,0,
  { Model 3 }
  196,0,5,9,0,0,22,1,160,3,5,8,13,1,8,16,
  2,8,18,3,8,19,4,8,19,5,8,20,6,4,22,24,
  3,17,8,19,9,3,13,3,13,3,13,3,14,7,16,0,
  15,24,255,7,8,0,16,10,255,6,0,15,16,24,0,9,
  8,17,32,255,6,8,17,18,16,255,9,16,19,32,255,6,
  0,19,20,16,0,0,17,104,74,4,95,2,59,112,10,25,
  59,112,10,25,59,112,10,25,59,112,10,25,59,112,10,25,
  59,10,59,112,10,25,59,112,10,25,69,183,32,239,64,47,
  14,231,91,47,10,25,60,26,48,134,151,20,112,63,9,70,
  223,0,39,3,25,112,26,52,25,25,74,10,4,59,112,25,
  10,4,59,112,25,10,4,59,112,25,65,143,212,72,4,59,
  112,8,143,216,8,68,175,60,60,25,69,207,9,112,25,25,
  25,25,25,112,56,0,
  { terminator }
  0,0
);

procedure TCompressor.startBlock(level: Integer);
var p: PAnsiChar; i: Integer; sz: Integer;
begin
  if level < 1 then zpaq_error('compression level must be at least 1');
  p := PAnsiChar(@MODELS_DATA[0]);
  for i := 1 to level-1 do begin
    sz := Integer(U8(p[0])) or (Integer(U8(p[1])) shl 8);
    if sz < 1 then zpaq_error('compression level too high');
    Inc(p, sz+2);
  end;
  sz := Integer(U8(p[0])) or (Integer(U8(p[1])) shl 8);
  if sz < 1 then zpaq_error('compression level too high');
  startBlock(p);
end;

procedure TCompressor.startBlock(hcomp: PAnsiChar);
var ms: TStringBuffer;
    sz, i: Integer;
begin
  ms := TStringBuffer.Create(0);
  try
    { Read exactly sz+2 bytes from binary model data (C++: StringBuffer(hcomp, 2+sz)) }
    sz := Integer(U8(hcomp[0])) or (Integer(U8(hcomp[1])) shl 8);
    for i := 0 to sz + 1 do ms.put(U8(hcomp[i]));
    ms.Frpos := 0;
    Fz.read(ms);
  finally
    ms.Free;
  end;
  Fpz.sha1 := Fsha1;
  Fenc.Fout.put(Ord('z')); Fenc.Fout.put(Ord('P')); Fenc.Fout.put(Ord('Q'));
  Fenc.Fout.put(1 + Integer(Fz.header[6] = 0));
  Fenc.Fout.put(1);
  Fz.bwrite(Fenc.Fout, False);
  Fstate := csBlock1;
end;

procedure CompileConfig(const cfg: AnsiString; args: PInteger; var hz, pz: TZPAQL; pcomp_cmd: TZPAQLStream); forward;

procedure TCompressor.startBlock(const config: AnsiString; args: PInteger; pcomp_cmd: TZPAQLStream);
begin
  // Compile the config string using TCompiler
  // For now do a simplified compile
  CompileConfig(config, args, Fz, Fpz, pcomp_cmd);
  Fpz.sha1 := Fsha1;
  Fenc.Fout.put(Ord('z')); Fenc.Fout.put(Ord('P')); Fenc.Fout.put(Ord('Q'));
  Fenc.Fout.put(1 + Integer(Fz.header[6] = 0));
  Fenc.Fout.put(1);
  Fz.bwrite(Fenc.Fout, False);
  Fstate := csBlock1;
end;

procedure TCompressor.startSegment(const filename, comment: AnsiString);
var i: Integer;
begin
  Fenc.Fout.put(1);
  for i := 1 to Length(filename) do Fenc.Fout.put(Ord(filename[i]));
  Fenc.Fout.put(0);
  for i := 1 to Length(comment) do Fenc.Fout.put(Ord(comment[i]));
  Fenc.Fout.put(0);
  Fenc.Fout.put(0);
  if Fstate = csBlock1 then Fstate := csSeg1;
  if Fstate = csBlock2 then Fstate := csSeg2;
end;

procedure TCompressor.postProcess(pcomp: PAnsiChar; len: Integer);
var i: Integer;
begin
  if Fstate = csSeg2 then Exit;
  Fenc.init();
  if pcomp = nil then begin
    len := Fpz.hend - Fpz.hbegin;
    if len > 0 then pcomp := PAnsiChar(@Fpz.header[Fpz.hbegin]);
  end else if len = 0 then begin
    len := Integer(U8(pcomp[0])) or (Integer(U8(pcomp[1])) shl 8);
    Inc(pcomp, 2);
  end;
  if len > 0 then begin
    Fenc.compress(1);
    Fenc.compress(len and 255);
    Fenc.compress((len shr 8) and 255);
    for i := 0 to len-1 do Fenc.compress(U8(pcomp[i]));
    if Fverify then Fpz.initp();
  end else
    Fenc.compress(0);
  Fstate := csSeg2;
end;

function TCompressor.compress(n: Integer): Boolean;
const CBUFSIZE = 1 shl 14;
var buf: array[0..CBUFSIZE-1] of AnsiChar;
    nbuf, nr, i: Integer; ch: Integer;
begin
  if Fstate = csSeg1 then postProcess(nil, 0);
  while n <> 0 do begin
    nbuf := CBUFSIZE;
    if (n >= 0) and (n < nbuf) then nbuf := n;
    nr := Fin.bread(PU8(@buf[0]), nbuf);
    if nr <= 0 then begin Result := False; Exit; end;
    if n >= 0 then Dec(n, nr);
    for i := 0 to nr-1 do begin
      ch := U8(buf[i]);
      Fenc.compress(ch);
      if Fverify then begin
        if Fpz.hend > 0 then Fpz.run(U32(ch))
        else Fsha1.put(ch);
      end;
    end;
  end;
  Result := True;
end;

procedure TCompressor.endSegment(sha1string: PAnsiChar);
var i: Integer;
begin
  if Fstate = csSeg1 then postProcess(nil, 0);
  Fenc.compress(-1);
  if Fverify and (Fpz.hend > 0) then begin
    Fpz.run(U32(-1)); Fpz.flush();
  end;
  Fenc.Fout.put(0); Fenc.Fout.put(0); Fenc.Fout.put(0); Fenc.Fout.put(0);
  if sha1string <> nil then begin
    Fenc.Fout.put(253);
    for i := 0 to 19 do Fenc.Fout.put(U8(sha1string[i]));
  end else
    Fenc.Fout.put(254);
  Fstate := csBlock2;
end;

function TCompressor.endSegmentChecksum(outsize: PInt64; dosha1: Boolean): PAnsiChar;
var i: Integer;
begin
  if Fstate = csSeg1 then postProcess(nil, 0);
  Fenc.compress(-1);
  if Fverify and (Fpz.hend > 0) then begin
    Fpz.run(U32(-1)); Fpz.flush();
  end;
  Fenc.Fout.put(0); Fenc.Fout.put(0); Fenc.Fout.put(0); Fenc.Fout.put(0);
  if Fverify then begin
    if outsize <> nil then outsize^ := Int64(Fsha1.usize());
    Move(Fsha1.getResult()^, Fsha1result[0], 20);
  end;
  if Fverify and dosha1 then begin
    Fenc.Fout.put(253);
    for i := 0 to 19 do Fenc.Fout.put(U8(Fsha1result[i]));
  end else
    Fenc.Fout.put(254);
  Fstate := csBlock2;
  if Fverify then Result := @Fsha1result[0] else Result := nil;
end;

procedure TCompressor.endBlock();
begin
  Fenc.Fout.put(255);
  Fstate := csInit;
end;


{ ============================================================ }
{  Compiler (ZPAQL config string -> bytecode)                  }
{ ============================================================ }

{ Opcode name lookup - returns numeric opcode or -1 }
function FindOpcode(const tok: AnsiString): Integer;
const NAMES: array[0..270] of AnsiString = (
  'error','a++','a--','a!','a=0','','','a=r',
  'b<>a','b++','b--','b!','b=0','','','b=r',
  'c<>a','c++','c--','c!','c=0','','','c=r',
  'd<>a','d++','d--','d!','d=0','','','d=r',
  '*b<>a','*b++','*b--','*b!','*b=0','','','jt',
  '*c<>a','*c++','*c--','*c!','*c=0','','','jf',
  '*d<>a','*d++','*d--','*d!','*d=0','','','r=a',
  'halt','out','','hash','hashd','','','jmp',
  'a=a','a=b','a=c','a=d','a=*b','a=*c','a=*d','a=',
  'b=a','b=b','b=c','b=d','b=*b','b=*c','b=*d','b=',
  'c=a','c=b','c=c','c=d','c=*b','c=*c','c=*d','c=',
  'd=a','d=b','d=c','d=d','d=*b','d=*c','d=*d','d=',
  '*b=a','*b=b','*b=c','*b=d','*b=*b','*b=*c','*b=*d','*b=',
  '*c=a','*c=b','*c=c','*c=d','*c=*b','*c=*c','*c=*d','*c=',
  '*d=a','*d=b','*d=c','*d=d','*d=*b','*d=*c','*d=*d','*d=',
  '','','','','','','','',
  'a+=a','a+=b','a+=c','a+=d','a+=*b','a+=*c','a+=*d','a+=',
  'a-=a','a-=b','a-=c','a-=d','a-=*b','a-=*c','a-=*d','a-=',
  'a*=a','a*=b','a*=c','a*=d','a*=*b','a*=*c','a*=*d','a*=',
  'a/=a','a/=b','a/=c','a/=d','a/=*b','a/=*c','a/=*d','a/=',
  'a%=a','a%=b','a%=c','a%=d','a%=*b','a%=*c','a%=*d','a%=',
  'a&=a','a&=b','a&=c','a&=d','a&=*b','a&=*c','a&=*d','a&=',
  'a&~a','a&~b','a&~c','a&~d','a&~*b','a&~*c','a&~*d','a&~',
  'a|=a','a|=b','a|=c','a|=d','a|=*b','a|=*c','a|=*d','a|=',
  'a^=a','a^=b','a^=c','a^=d','a^=*b','a^=*c','a^=*d','a^=',
  'a<<=a','a<<=b','a<<=c','a<<=d','a<<=*b','a<<=*c','a<<=*d','a<<=',
  'a>>=a','a>>=b','a>>=c','a>>=d','a>>=*b','a>>=*c','a>>=*d','a>>=',
  'a==a','a==b','a==c','a==d','a==*b','a==*c','a==*d','a==',
  'a<a','a<b','a<c','a<d','a<*b','a<*c','a<*d','a<',
  'a>a','a>b','a>c','a>d','a>*b','a>*c','a>*d','a>',
  '','','','','','','','',
  '','','','','','','','lj',
  'post','pcomp','end','if','ifnot','else','endif','do',
  'while','until','forever','ifl','ifnotl','elsel',';');
var i: Integer;
    low: AnsiString;
begin
  low := LowerCase(tok);
  for i := 0 to 270 do
    if NAMES[i] = low then begin Result := i; Exit; end;
  Result := -1;
end;

function FindCompname(const tok: AnsiString): Integer;
const CN: array[0..9] of AnsiString = (
  '','const','cm','icm','match','avg','mix2','mix','isse','sse');
var i: Integer; low: AnsiString;
begin
  low := LowerCase(tok);
  for i := 0 to 9 do
    if CN[i] = low then begin Result := i; Exit; end;
  Result := -1;
end;

{ Simple stack for compiler }
type
  TIntStack = record
    data: array[0..999] of Integer;
    top: Integer;
  end;

procedure StackPush(var s: TIntStack; v: Integer);
begin
  s.data[s.top] := v;
  Inc(s.top);
end;

function StackPop(var s: TIntStack): Integer;
begin
  Dec(s.top);
  Result := s.data[s.top];
end;

{ ============================================================ }
{  Compiler main function                                       }
{  Parses config string, fills hz (COMP+HCOMP) and pz (PCOMP) }
{ ============================================================ }

{ Skip whitespace and comments in Pascal string }
procedure SkipWS(const s: AnsiString; var pos: Integer);
var depth: Integer;
begin
  depth := 0;
  while pos <= Length(s) do begin
    if s[pos] = '(' then begin Inc(depth); Inc(pos); end
    else if (depth > 0) and (s[pos] = ')') then begin Dec(depth); Inc(pos); end
    else if depth > 0 then Inc(pos)
    else if s[pos] <= ' ' then Inc(pos)
    else Break;
  end;
end;

{ Read next token (space/paren delimited) }
function NextToken(const s: AnsiString; var pos: Integer): AnsiString;
var start: Integer;
begin
  SkipWS(s, pos);
  if pos > Length(s) then begin Result := ''; Exit; end;
  start := pos;
  while (pos <= Length(s)) and (s[pos] > ' ') and (s[pos] <> '(') do
    Inc(pos);
  Result := Copy(s, start, pos-start);
end;

function TokenToInt(const tok: AnsiString; args: PInteger; out val: Integer): Boolean;
var i: Integer;
begin
  Result := True;
  if (Length(tok) >= 2) and (tok[1] = '$') and (tok[2] >= '1') and (tok[2] <= '9') then begin
    val := 0;
    if (args <> nil) then val := args[Ord(tok[2])-Ord('1')];
    if (Length(tok) >= 4) and (tok[3] = '+') then
      val := val + StrToIntDef(Copy(tok,4,MaxInt), 0);
  end else begin
    val := StrToIntDef(tok, MaxInt);
    Result := (val <> MaxInt) or (tok = '-2147483648');
    if not Result then val := 0;
  end;
end;

{ Compile HCOMP or PCOMP bytecode into z.header[z.hend..] }
{ Returns opcode of terminal: POST=256, PCOMP=257, END=258 }
const OP_POST = 256; OP_PCOMP = 257; OP_END = 258;
const OP_IF=259; OP_IFNOT=260; OP_ELSE=261; OP_ENDIF=262;
      OP_DO=263; OP_WHILE=264; OP_UNTIL=265; OP_FOREVER=266;
      OP_IFL=267; OP_IFNOTL=268; OP_ELSEL=269; OP_SEMI=270;
      OP_LJ=255; OP_JT=39; OP_JF=47; OP_JMP=63;

function CompileComp(const s: AnsiString; var pos: Integer;
                     var z: TZPAQL; args: PInteger;
                     const comp_begin: Integer): Integer;
var
  tok: AnsiString;
  op, operand, operand2: Integer;
  if_stack, do_stack: TIntStack;
  a, j, jp: Integer;
begin
  if_stack.top := 0; do_stack.top := 0;
  Result := OP_END;
  while True do begin
    tok := NextToken(s, pos);
    if tok = '' then begin zpaq_error('unexpected end of config'); Exit; end;

    { Map high-level tokens to opcodes }
    if LowerCase(tok) = 'post'    then begin Result := OP_POST;  Exit; end;
    if LowerCase(tok) = 'pcomp'   then begin Result := OP_PCOMP; Exit; end;
    if LowerCase(tok) = 'end'     then begin Result := OP_END;   Exit; end;

    op := FindOpcode(tok);
    if op < 0 then begin zpaq_error('unknown opcode: ' + tok); Exit; end;

    operand  := -1;
    operand2 := -1;

    if op = 259 { IF } then begin
      op := OP_JF; operand := 0;
      StackPush(if_stack, z.hend+1);
    end else if op = 260 { IFNOT } then begin
      op := OP_JT; operand := 0;
      StackPush(if_stack, z.hend+1);
    end else if op = 267 { IFL } then begin
      z.header[z.hend] := OP_JT; Inc(z.hend);
      z.header[z.hend] := 3;     Inc(z.hend);
      op := OP_LJ; operand := 0; operand2 := 0;
      StackPush(if_stack, z.hend+1);
    end else if op = 268 { IFNOTL } then begin
      z.header[z.hend] := OP_JF; Inc(z.hend);
      z.header[z.hend] := 3;     Inc(z.hend);
      op := OP_LJ; operand := 0; operand2 := 0;
      StackPush(if_stack, z.hend+1);
    end else if (op = 261) or (op = 269) { ELSE, ELSEL } then begin
      if op = 261 then begin op := OP_JMP; operand := 0; end
      else begin op := OP_LJ; operand := 0; operand2 := 0; end;
      a := StackPop(if_stack);
      if z.header[a-1] <> OP_LJ then begin
        j := z.hend - a + 1 + Integer(op = OP_LJ);
        if j > 127 then zpaq_error('IF too big, try IFL, IFNOTL');
        z.header[a] := j and 255;
      end else begin
        j := z.hend - comp_begin + 2 + Integer(op = OP_LJ);
        z.header[a]   := j and 255;
        z.header[a+1] := (j shr 8) and 255;
      end;
      StackPush(if_stack, z.hend+1);
    end else if op = 262 { ENDIF } then begin
      a := StackPop(if_stack);
      j := z.hend - a - 1;
      if z.header[a-1] <> OP_LJ then begin
        if j > 127 then zpaq_error('IF too big, try IFL, IFNOTL, ELSEL');
        z.header[a] := j and 255;
      end else begin
        j := z.hend - comp_begin;
        z.header[a]   := j and 255;
        z.header[a+1] := (j shr 8) and 255;
      end;
      Continue; { no byte emitted }
    end else if op = 263 { DO } then begin
      StackPush(do_stack, z.hend);
      Continue;
    end else if (op >= 264) and (op <= 266) { WHILE, UNTIL, FOREVER } then begin
      a := StackPop(do_stack);
      j := a - z.hend - 2;
      if j >= -127 then begin
        if op = 264 then op := OP_JT
        else if op = 265 then op := OP_JF
        else op := OP_JMP;
        operand := j and 255;
      end else begin
        j := a - comp_begin;
        if op = 264 then begin
          z.header[z.hend] := OP_JF; Inc(z.hend);
          z.header[z.hend] := 3;     Inc(z.hend);
        end else if op = 265 then begin
          z.header[z.hend] := OP_JT; Inc(z.hend);
          z.header[z.hend] := 3;     Inc(z.hend);
        end;
        op := OP_LJ;
        operand  := j and 255;
        operand2 := (j shr 8) and 255;
      end;
    end else if (op and 7) = 7 then begin { 2-byte instruction }
      if op = OP_LJ then begin
        tok := NextToken(s, pos);
        if not TokenToInt(tok, args, jp) then zpaq_error('expected number');
        operand  := jp and 255;
        operand2 := (jp shr 8) and 255;
      end else if (op = OP_JT) or (op = OP_JF) or (op = OP_JMP) then begin
        tok := NextToken(s, pos);
        if not TokenToInt(tok, args, jp) then zpaq_error('expected number');
        operand := jp and 255;
      end else begin
        tok := NextToken(s, pos);
        if not TokenToInt(tok, args, jp) then zpaq_error('expected number');
        operand := jp and 255;
      end;
    end;

    if (op >= 0) and (op <= 255) then begin
      z.header[z.hend] := op; Inc(z.hend);
    end;
    if operand >= 0 then begin
      z.header[z.hend] := operand; Inc(z.hend);
    end;
    if operand2 >= 0 then begin
      z.header[z.hend] := operand2; Inc(z.hend);
    end;
  end;
end;

{ Main config compiler - fills hz and pz }
procedure CompileConfig(const cfg: AnsiString; args: PInteger;
                        var hz, pz: TZPAQL;
                        pcomp_cmd: TZPAQLStream);
var
  pos, n, i, tp, j, hsize, len, op: Integer;
  tok: AnsiString;
  comp_begin: Integer;
begin
  pos := 1;
  hz.clear(); pz.clear();
  SetLength(hz.header, 68000);

  tok := NextToken(cfg, pos);
  if LowerCase(tok) <> 'comp' then zpaq_error('expected comp');

  tok := NextToken(cfg, pos); if not TokenToInt(tok, args, i) then zpaq_error('expected hh'); hz.header[2] := i;
  tok := NextToken(cfg, pos); if not TokenToInt(tok, args, i) then zpaq_error('expected hm'); hz.header[3] := i;
  tok := NextToken(cfg, pos); if not TokenToInt(tok, args, i) then zpaq_error('expected ph'); hz.header[4] := i;
  tok := NextToken(cfg, pos); if not TokenToInt(tok, args, i) then zpaq_error('expected pm'); hz.header[5] := i;
  tok := NextToken(cfg, pos); if not TokenToInt(tok, args, n) then zpaq_error('expected n');
  hz.header[6] := n;
  hz.cend := 7;

  for i := 0 to n-1 do begin
    tok := NextToken(cfg, pos);
    if StrToIntDef(tok,-1) <> i then zpaq_error('expected component number '+IntToStr(i));
    tok := NextToken(cfg, pos);
    tp := FindCompname(tok);
    if tp < 0 then zpaq_error('unknown component: '+tok);
    hz.header[hz.cend] := tp; Inc(hz.cend);
    for j := 1 to compsize[tp]-1 do begin
      tok := NextToken(cfg, pos);
      if not TokenToInt(tok, args, hsize) then zpaq_error('expected number');
      hz.header[hz.cend] := hsize and 255; Inc(hz.cend);
    end;
  end;
  hz.header[hz.cend] := 0; Inc(hz.cend);
  hz.hbegin := hz.cend + 128;
  hz.hend   := hz.hbegin;

  tok := NextToken(cfg, pos);
  if LowerCase(tok) <> 'hcomp' then zpaq_error('expected hcomp');
  comp_begin := hz.hend;
  op := CompileComp(cfg, pos, hz, args, comp_begin);

  hz.header[hz.hend] := 0; Inc(hz.hend); { END marker - must come BEFORE hsize calc }
  hsize := hz.cend - 2 + hz.hend - hz.hbegin;
  hz.header[0] := hsize and 255;
  hz.header[1] := hsize shr 8;

  if op = OP_POST then begin
    tok := NextToken(cfg, pos);
    if tok <> '0' then zpaq_error('expected 0 after post');
    tok := NextToken(cfg, pos);
    if LowerCase(tok) <> 'end' then zpaq_error('expected end');
  end else if op = OP_PCOMP then begin
    SetLength(pz.header, 68000);
    pz.header[4] := hz.header[4];
    pz.header[5] := hz.header[5];
    pz.cend := 8;
    pz.hbegin := pz.cend + 128;
    pz.hend   := pz.hbegin;
    { read pcomp_cmd (up to ';') }
    while (pos <= Length(cfg)) and (cfg[pos] <> ';') do begin
      if pcomp_cmd <> nil then pcomp_cmd.put(Ord(cfg[pos]));
      Inc(pos);
    end;
    if (pos <= Length(cfg)) and (cfg[pos] = ';') then Inc(pos);
    comp_begin := pz.hend;
    op := CompileComp(cfg, pos, pz, args, comp_begin);
    pz.header[pz.hend] := 0; Inc(pz.hend); { END marker - before len calc }
    len := pz.cend - 2 + pz.hend - pz.hbegin;
    pz.header[0] := len and 255;
    pz.header[1] := len shr 8;
    if op <> OP_END then zpaq_error('expected END');
  end else if op <> OP_END then
    zpaq_error('expected END or POST 0 END or PCOMP cmd ; ... END');
end;

{ ============================================================ }
{  e8e9 transform                                               }
{ ============================================================ }

procedure e8e9(buf: PU8; n: Integer);
var i: Integer; a: U32;
begin
  for i := n-5 downto 0 do begin
    if ((buf[i] and 254) = $E8) and (((buf[i+4]+1) and 254) = 0) then begin
      a := U32(buf[i+1]) or (U32(buf[i+2]) shl 8) or (U32(buf[i+3]) shl 16) + U32(i);
      buf[i+1] := a and 255;
      buf[i+2] := (a shr 8) and 255;
      buf[i+3] := (a shr 16) and 255;
    end;
  end;
end;

{ ============================================================ }
{  Simple suffix sort for BWT (O(n^2) but correct)             }
{ ============================================================ }

procedure divsufsort(inp: PU8; sa: PInteger; n: Integer);
{ Build suffix array using simple insertion sort.
  For small n this is fine; for large n it's slow but correct. }
var
  i, j, k, tmp: Integer;
  cmp: Integer;
  pi, pj: PU8;
  p1, p2: PU8;
  maxlen, maxlen2: Integer;
begin
  for i := 0 to n-1 do sa[i] := i;
  { Shell sort suffixes }
  k := 1;
  while k < n do k := k*3+1;
  while k > 0 do begin
    k := k div 3;
    for i := k to n-1 do begin
      tmp := sa[i]; j := i;
      while j >= k do begin
        pi := inp + sa[j-k];
        pj := inp + tmp;
        { compare suffixes lexicographically }
        cmp := 0;
        begin
          p1 := pi; p2 := pj;
          maxlen := n - sa[j-k]; maxlen2 := n - tmp;
          if maxlen2 < maxlen then maxlen := maxlen2;
          while maxlen > 0 do begin
            if p1^ < p2^ then begin cmp := -1; Break; end;
            if p1^ > p2^ then begin cmp := 1; Break; end;
            Inc(p1); Inc(p2); Dec(maxlen);
          end;
          if cmp = 0 then begin
            if n - sa[j-k] > n - tmp then cmp := 1 else cmp := -1;
          end;
        end;
        if cmp <= 0 then Break;
        sa[j] := sa[j-k]; Dec(j, k);
      end;
      sa[j] := tmp;
    end;
  end;
end;

{ ============================================================ }
{  LZBuffer (simplified LZ77/BWT preprocessor)                 }
{ ============================================================ }

type
  TLZBuffer = class(TZPAQLStream)
  private
    Fin:        TU8Array;   { input data }
    Fn:         Integer;    { input length }
    Fi:         Integer;    { current position }
    Fbits:      U32;
    Fnbits:     Integer;
    Frpos:      Integer;
    Fwpos:      Integer;
    Flevel:     Integer;    { 1=var LZ77, 2=byte LZ77, 3=BWT }
    FminMatch:  Integer;
    Fht:        TU32Array;  { hash table or suffix array }
    Fhtsize:    Integer;
    Fbucket:    Integer;
    Fshift1:    Integer;
    Fcheckbits: Integer;
    Frb:        Integer;    { extra offset bits for level 1 }
    FminMatch2: Integer;
    Flookahead: Integer;
    Fh1, Fh2:  U32;
    Fidx:       Integer;    { BWT index }
    Fsa:        PInteger;   { suffix array (points into Fht) }
    Fisa:       PInteger;   { inverse SA }
    BUFSIZE:    Integer;
    Fbuf:       TU8Array;   { output buffer }
    procedure putb(x: U32; k: Integer);
    procedure putbyte(c: Integer);
    procedure flushbits();
    procedure fill();
    procedure write_literal(i: Integer; var lit: Integer);
    procedure write_match(len, off: Integer);
  public
    constructor Create(var inbuf: TStringBuffer; args: PInteger);
    destructor Destroy; override;
    function get(): Integer; override;
    function bread(buf: PU8; n: Integer): Integer; override;
  end;

constructor TLZBuffer.Create(var inbuf: TStringBuffer; args: PInteger);
var n2: Integer;
begin
  inherited Create;
  BUFSIZE := 1 shl 14;
  SetLength(Fbuf, BUFSIZE);
  Fn := inbuf.size();
  SetLength(Fin, Fn);
  if Fn > 0 then Move(inbuf.data()^, Fin[0], Fn);
  Fi := 0; Fbits := 0; Fnbits := 0; Frpos := 0; Fwpos := 0;
  Flevel    := args[1] and 3;
  FminMatch := args[2];
  FminMatch2:= args[3];
  Flookahead:= args[6];
  Fbucket   := (1 shl args[4]) - 1;
  Frb       := Integer(args[0] > 4) * (args[0] - 4);
  Fcheckbits:= 12 - args[0];
  Fh1 := 0; Fh2 := 0; Fidx := 0;
  Fshift1 := Integer(FminMatch > 0) * ((args[5]-1) div Integer(FminMatch>0) + 1);
  if Fshift1 = 0 then Fshift1 := 1;

  if (args[5] - args[0] >= 21) or (Flevel = 3) then begin
    { Use suffix array }
    SetLength(Fht, Fn + (1 shl 17 shl args[0]));
    if Fn > 0 then begin
      Fsa := PInteger(@Fht[0]);
      divsufsort(@Fin[0], Fsa, Fn);
      if Flevel < 3 then begin
        Fisa := Fsa + Fn;
        Fhtsize := 1 shl 17 shl args[0];
        Fcheckbits := 17 + args[0];
      end;
    end;
  end else begin
    Fhtsize := 1 shl args[5];
    SetLength(Fht, Fhtsize);
    FillChar(Fht[0], Fhtsize*4, 0);
    Fsa := nil; Fisa := nil;
    n2 := Fhtsize;
    Fhtsize := n2;
  end;

  { e8e9 if requested }
  if (args[1] > 4) and (Fn > 0) then e8e9(@Fin[0], Fn);
end;

destructor TLZBuffer.Destroy;
begin
  inherited Destroy;
end;

procedure TLZBuffer.putb(x: U32; k: Integer);
begin
  x := x and ((U32(1) shl k) - 1);
  Fbits := Fbits or (x shl Fnbits);
  Inc(Fnbits, k);
  while Fnbits > 7 do begin
    Fbuf[Fwpos] := Fbits and 255; Inc(Fwpos);
    Fbits := Fbits shr 8; Dec(Fnbits, 8);
  end;
end;

procedure TLZBuffer.putbyte(c: Integer);
begin
  Fbuf[Fwpos] := U8(c); Inc(Fwpos);
end;

procedure TLZBuffer.flushbits();
begin
  if Fnbits > 0 then begin Fbuf[Fwpos] := Fbits and 255; Inc(Fwpos); end;
  Fbits := 0; Fnbits := 0;
end;

procedure TLZBuffer.write_literal(i: Integer; var lit: Integer);
var j, k2: Integer;
begin
  if Flevel = 1 then begin
    if lit < 1 then Exit;
    { encode literal run: 00,n,L[n] }
    putb(0, 2);
    { encode lit count as interleaved Elias Gamma, MSB-first (C++ style)
      leading 1 is implicit; write remaining bits high-to-low,
      each preceded by flag=1, then terminate with flag=0 }
    j := lg(U32(lit)) - 2;  { first bit below MSB = lg(lit)-2 }
    while j >= 0 do begin
      putb(1, 1);
      putb((lit shr j) and 1, 1);
      Dec(j);
    end;
    putb(0, 1);
    { output literal bytes }
    for j := i-lit to i-1 do putb(Fin[j], 8);
    lit := 0;
  end else begin { level 2 }
    if lit < 1 then Exit;
    { 00xxxxxx = x+1 literals }
    while lit > 0 do begin
      j := lit; if j > 64 then j := 64;
      putbyte((j-1) and 63);
      for k2 := i-lit to i-lit+j-1 do putbyte(Fin[k2]);
      Dec(lit, j);
    end;
  end;
end;

procedure TLZBuffer.write_match(len, off: Integer);
var mm, nb, j: Integer;
begin
  if Flevel = 1 then begin
    { mm,mmm,n,ll,r,q encoding - off is 1-based (C++ uses off > 0) }
    { C++: off += (1<<rb)-1; lo = lg(off)-1-rb; then encodes off in lo bits }
    off := off + (1 shl Frb) - 1;
    nb := lg(U32(off)) - 1 - Frb;  { = lo in C++ notation }
    if nb < 0 then nb := 0;
    putb(U32(nb + 8) shr 3, 2); { mm = (lo+8)>>3 }
    putb(U32(nb) and 7, 3);     { mmm = lo&7 }
    { encode match length via interleaved Elias Gamma, MSB-first (C++ style)
      leading 1 implicit; write bits at positions (lg(len)-2) down to 2,
      each preceded by flag=1, terminated by 0; bottom 2 bits written as
      the separate 'll' field }
    j := lg(U32(len)) - 2;  { first bit below MSB }
    while j >= 2 do begin
      putb(1, 1);
      putb((len shr j) and 1, 1);
      Dec(j);
    end;
    putb(0, 1);
    { 2 bit fractional length }
    putb(len and 3, 2);
    { low rb bits of offset (r), then high lo=nb bits of offset>>rb (q) }
    putb(U32(off), Frb);            { r: low Frb bits }
    putb(U32(off) shr Frb, nb);     { q: lo=nb bits above rb }
  end else begin { level 2 }
    { yyxxxxxx yy+1 offset bytes, match len x+minMatch }
    Dec(off);
    nb := 1;
    if off >= 256 then Inc(nb);
    if off >= 65536 then Inc(nb);
    putbyte(((nb-1) shl 6) or ((len - FminMatch) and 63));
    case nb of
      1: putbyte(off and 255);
      2: begin putbyte((off shr 8) and 255); putbyte(off and 255); end;
      3: begin putbyte((off shr 16) and 255); putbyte((off shr 8) and 255); putbyte(off and 255); end;
    end;
  end;
end;

procedure TLZBuffer.fill();
var
  lit, blen, bp, blit, bscore: Integer;
  i, j, p, len, score: Integer;
  mask: U32;
  h: U32;
begin
  if Flevel = 3 then begin
    { BWT output }
    while (Fwpos < BUFSIZE) and (Fi < Fn+5) do begin
      if Fi = 0 then putbyte(Integer(Fin[Fn-1]))
      else if Fi > Fn then begin putbyte(Fidx and 255); Fidx := Fidx shr 8; end
      else if Fsa[Fi-1] = 0 then begin Fidx := Fi; putbyte(255); end
      else putbyte(Fin[Fsa[Fi-1]-1]);
      Inc(Fi);
    end;
    Exit;
  end;

  lit := 0;
  mask := (U32(1) shl Fcheckbits) - 1;
  while (Fi < Fn) and (Fwpos * 2 < BUFSIZE) do begin
    { Search for match }
    blen := FminMatch - 1;
    bp := 0; blit := 0; bscore := 0;

    if Fisa <> nil then begin
      { SA-based search (simplified: just hash search) }
    end;

    { Hash table search }
    if Fsa = nil then begin
      { update rolling hashes }
      Fh1 := Fh1 * U32(Fshift1) + Fin[Fi] + 1;
      if FminMatch2 > 0 then Fh2 := Fh2 * U32(Fshift1) + Fin[Fi] + 1;

      { look up in hash table }
      for j := 0 to Fbucket do begin
        p := Integer(Fht[(Fh1 + U32(j)) and U32(Fhtsize-1)]);
        if (p > 0) and (Integer(U32(p) and mask) = Integer(U32(Fin[Fi]) and mask)) then begin
          p := Integer(U32(p) shr Fcheckbits);
          if (p < Fi) and (p >= 0) then begin
            len := 0;
            while (Fi+len < Fn) and (len < 255) and (Fin[Fi+len] = Fin[p+len]) do Inc(len);
            if len > blen then begin blen := len; bp := p; end;
          end;
        end;
      end;

      { update hash }
      Fht[Fh1 and U32(Fhtsize-1)] := U32(Fi) shl Fcheckbits or (Fin[Fi] and mask);
    end;

    if blen >= FminMatch then begin
      write_literal(Fi, lit);
      write_match(blen, Fi - bp);
      Inc(Fi, blen);
    end else begin
      Inc(lit);
      Inc(Fi);
      if lit >= BUFSIZE div 4 then
        write_literal(Fi, lit);
    end;
  end;
  if Fi >= Fn then begin
    write_literal(Fi, lit);
    flushbits();
  end;
end;

function TLZBuffer.get(): Integer;
begin
  if Frpos = Fwpos then fill();
  if Frpos < Fwpos then begin
    Result := Fbuf[Frpos]; Inc(Frpos);
    if Frpos = Fwpos then begin Frpos := 0; Fwpos := 0; end;
  end else
    Result := -1;
end;

function TLZBuffer.bread(buf: PU8; n: Integer): Integer;
var nr: Integer;
begin
  if Frpos = Fwpos then fill();
  nr := n;
  if nr > Fwpos - Frpos then nr := Fwpos - Frpos;
  if nr > 0 then Move(Fbuf[Frpos], buf^, nr);
  Inc(Frpos, nr);
  if Frpos = Fwpos then begin Frpos := 0; Fwpos := 0; end;
  Result := nr;
end;


{ ============================================================ }
{  makeConfig                                                   }
{ ============================================================ }

function makeConfig(const method: AnsiString; args: PInteger): AnsiString;
var
  meth: AnsiString;
  mpos: Integer;
  mtype: AnsiChar;
  level, doe8: Integer;
  rb: Integer;
  hdr, pcomp, comp, hcomp, config: AnsiString;
  ncomp, membits, sb: Integer;
  v: array of Integer;
  vlen: Integer;
  i, j: Integer;
  period: Integer;
  score: Double;
  n1, t: Integer;

  { ---- read next char from meth at mpos ---- }
  { Not inlined: Delphi (E2449) refuses to inline a nested routine that touches
    the enclosing scope (meth / mpos); FPC's {$inline on} made these inline but
    the perf cost of dropping it on a method-string parser is nil. }
  function MC(): AnsiChar;
  begin if mpos <= Length(meth) then Result := meth[mpos] else Result := #0; end;
  function MCadv(): AnsiChar;
  begin Result := MC(); if mpos <= Length(meth) then Inc(mpos); end;

  function isDigit(c: AnsiChar): Boolean;
  begin Result := (c >= '0') and (c <= '9'); end;

begin
  meth := method;
  mpos := 1;
  if Length(meth) = 0 then begin Result := ''; Exit; end;
  mtype := meth[1];
  Inc(mpos);

  { initialise args[0..8] }
  for i := 0 to 8 do args[i] := 0;

  { parse N1,N2,...N9 }
  if isDigit(MC()) then begin { first digit resets args[0] } end;
  i := 0;
  while (i < 9) and ((isDigit(MC())) or (MC() = ',') or (MC() = '.')) do begin
    if isDigit(MC()) then
      args[i] := args[i] * 10 + Ord(MCadv()) - Ord('0')
    else begin
      Inc(i);
      if i < 9 then args[i] := 0;
      MCadv(); { skip comma/dot }
    end;
  end;

  { "0..." = no compression }
  if mtype = '0' then begin
    Result := 'comp 0 0 0 0 0 hcomp end' + #10;
    Exit;
  end;

  level  := args[1] and 3;
  if (args[1] >= 4) and (args[1] <= 7) then doe8 := 1 else doe8 := 0;

  { ---------- build postprocessor pcomp ---------- }
  pcomp := '';

  if level = 1 then begin
    rb := 0; if args[0] > 4 then rb := args[0] - 4;
    hdr := 'comp 9 16 0 $1+20 ';
    pcomp :=
      'pcomp lazy2 3 ;' + #10 +
      ' (r1 = state' + #10 +
      '  r2 = len - match or literal length' + #10 +
      '  r3 = m - number of offset bits expected' + #10 +
      '  r4 = ptr to buf' + #10 +
      '  r5 = r - low bits of offset' + #10 +
      '  c = bits - input buffer' + #10 +
      '  d = n - number of bits in c)' + #10 +
      '' + #10 +
      '  a> 255 if' + #10;
    if doe8 <> 0 then
      pcomp := pcomp +
        '    b=0 d=r 4 do (for b=0..d-1, d = end of buf)' + #10 +
        '      a=b a==d ifnot' + #10 +
        '        a+= 4 a<d if' + #10 +
        '          a=*b a&= 254 a== 232 if (e8 or e9?)' + #10 +
        '            c=b b++ b++ b++ b++ a=*b a++ a&= 254 a== 0 if (00 or ff)' + #10 +
        '              b-- a=*b' + #10 +
        '              b-- a<<= 8 a+=*b' + #10 +
        '              b-- a<<= 8 a+=*b' + #10 +
        '              a-=b a++' + #10 +
        '              *b=a a>>= 8 b++' + #10 +
        '              *b=a a>>= 8 b++' + #10 +
        '              *b=a b++' + #10 +
        '            endif' + #10 +
        '            b=c' + #10 +
        '          endif' + #10 +
        '        endif' + #10 +
        '        a=*b out b++' + #10 +
        '      forever' + #10 +
        '    endif' + #10 + #10;
    pcomp := pcomp +
      '    (reset state)' + #10 +
      '    a=0 b=0 c=0 d=0 r=a 1 r=a 2 r=a 3 r=a 4' + #10 +
      '    halt' + #10 +
      '  endif' + #10 + #10 +
      '  a<<=d a+=c c=a               (bits+=a<<n)' + #10 +
      '  a= 8 a+=d d=a                (n+=8)' + #10 + #10 +
      '  (if state==0 (expect new code))' + #10 +
      '  a=r 1 a== 0 if (match code mm,mmm)' + #10 +
      '    a= 1 r=a 2                 (len=1)' + #10 +
      '    a=c a&= 3 a> 0 if          (if (bits&3))' + #10 +
      '      a-- a<<= 3 r=a 3           (m=((bits&3)-1)*8)' + #10 +
      '      a=c a>>= 2 c=a             (bits>>=2)' + #10 +
      '      b=r 3 a&= 7 a+=b r=a 3     (m+=bits&7)' + #10 +
      '      a=c a>>= 3 c=a             (bits>>=3)' + #10 +
      '      a=d a-= 5 d=a              (n-=5)' + #10 +
      '      a= 1 r=a 1                 (state=1)' + #10 +
      '    else (literal, discard 00)' + #10 +
      '      a=c a>>= 2 c=a             (bits>>=2)' + #10 +
      '      d-- d--                    (n-=2)' + #10 +
      '      a= 3 r=a 1                 (state=3)' + #10 +
      '    endif' + #10 +
      '  endif' + #10 + #10 +
      '  (while state==1 && n>=3 (expect match length n*4+ll -> r2))' + #10 +
      '  do a=r 1 a== 1 if a=d a> 2 if' + #10 +
      '    a=c a&= 1 a== 1 if         (if bits&1)' + #10 +
      '      a=c a>>= 1 c=a             (bits>>=1)' + #10 +
      '      b=r 2 a=c a&= 1 a+=b a+=b r=a 2 (len+=len+(bits&1))' + #10 +
      '      a=c a>>= 1 c=a             (bits>>=1)' + #10 +
      '      d-- d--                    (n-=2)' + #10 +
      '    else' + #10 +
      '      a=c a>>= 1 c=a             (bits>>=1)' + #10 +
      '      a=r 2 a<<= 2 b=a           (len<<=2)' + #10 +
      '      a=c a&= 3 a+=b r=a 2       (len+=bits&3)' + #10 +
      '      a=c a>>= 2 c=a             (bits>>=2)' + #10 +
      '      d-- d-- d--                (n-=3)' + #10;
    if rb <> 0 then
      pcomp := pcomp + '      a= 5 r=a 1                 (state=5)' + #10
    else
      pcomp := pcomp + '      a= 2 r=a 1                 (state=2)' + #10;
    pcomp := pcomp +
      '    endif' + #10 +
      '  forever endif endif' + #10 + #10;
    if rb <> 0 then
      pcomp := pcomp +
        '  (if state==5 && n>=' + itos(rb) + ') (expect low bits of offset to put in r5)' + #10 +
        '  a=r 1 a== 5 if a=d a> ' + itos(rb-1) + ' if' + #10 +
        '    a=c a&= ' + itos((1 shl rb)-1) + ' r=a 5            (save r in r5)' + #10 +
        '    a=c a>>= ' + itos(rb) + ' c=a' + #10 +
        '    a=d a-= ' + itos(rb) + ' d=a' + #10 +
        '    a= 2 r=a 1                   (go to state 2)' + #10 +
        '  endif endif' + #10 + #10;
    pcomp := pcomp +
      '  (if state==2 && n>=m) (expect m offset bits)' + #10 +
      '  a=r 1 a== 2 if a=r 3 a>d ifnot' + #10 +
      '    a=c r=a 6 a=d r=a 7          (save c=bits, d=n in r6,r7)' + #10 +
      '    b=r 3 a= 1 a<<=b d=a         (d=1<<m)' + #10 +
      '    a-- a&=c a+=d                (d=offset=bits&((1<<m)-1)|(1<<m))' + #10;
    if rb <> 0 then
      pcomp := pcomp +
        '    a<<= ' + itos(rb) + ' d=r 5 a+=d a-= ' + itos((1 shl rb)-1) + #10;
    pcomp := pcomp +
      '    d=a b=r 4 a=b a-=d c=a       (c=p=(b=ptr)-offset)' + #10 + #10 +
      '    (while len-- (copy and output match d bytes from *c to *b))' + #10 +
      '    d=r 2 do a=d a> 0 if d--' + #10 +
      '      a=*c *b=a c++ b++          (buf[ptr++]-buf[p++])' + #10;
    if doe8 = 0 then pcomp := pcomp + ' out' + #10;
    pcomp := pcomp +
      '    forever endif' + #10 +
      '    a=b r=a 4' + #10 + #10 +
      '    a=r 6 b=r 3 a>>=b c=a        (bits>>=m)' + #10 +
      '    a=r 7 a-=b d=a               (n-=m)' + #10 +
      '    a=0 r=a 1                    (state=0)' + #10 +
      '  endif endif' + #10 + #10 +
      '  (while state==3 && n>=2 (expect literal length))' + #10 +
      '  do a=r 1 a== 3 if a=d a> 1 if' + #10 +
      '    a=c a&= 1 a== 1 if         (if bits&1)' + #10 +
      '      a=c a>>= 1 c=a              (bits>>=1)' + #10 +
      '      b=r 2 a&= 1 a+=b a+=b r=a 2 (len+=len+(bits&1))' + #10 +
      '      a=c a>>= 1 c=a              (bits>>=1)' + #10 +
      '      d-- d--                     (n-=2)' + #10 +
      '    else' + #10 +
      '      a=c a>>= 1 c=a              (bits>>=1)' + #10 +
      '      d--                         (--n)' + #10 +
      '      a= 4 r=a 1                  (state=4)' + #10 +
      '    endif' + #10 +
      '  forever endif endif' + #10 + #10 +
      '  (if state==4 && n>=8 (expect len literals))' + #10 +
      '  a=r 1 a== 4 if a=d a> 7 if' + #10 +
      '    b=r 4 a=c *b=a' + #10;
    if doe8 = 0 then pcomp := pcomp + ' out' + #10;
    pcomp := pcomp +
      '    b++ a=b r=a 4                 (buf[ptr++]=bits)' + #10 +
      '    a=c a>>= 8 c=a                (bits>>=8)' + #10 +
      '    a=d a-= 8 d=a                 (n-=8)' + #10 +
      '    a=r 2 a-- r=a 2 a== 0 if      (if --len<1)' + #10 +
      '      a=0 r=a 1                     (state=0)' + #10 +
      '    endif' + #10 +
      '  endif endif' + #10 +
      '  halt' + #10 +
      'end' + #10;
  end  { level=1 }

  else if level = 2 then begin
    hdr := 'comp 9 16 0 $1+20 ';
    pcomp :=
      'pcomp lzpre c ;' + #10 +
      '  (Decode LZ77: d=state, M=output buffer, b=size)' + #10 +
      '  a> 255 if (at EOF decode e8e9 and output)' + #10;
    if doe8 <> 0 then
      pcomp := pcomp +
        '    d=b b=0 do (for b=0..d-1, d = end of buf)' + #10 +
        '      a=b a==d ifnot' + #10 +
        '        a+= 4 a<d if' + #10 +
        '          a=*b a&= 254 a== 232 if (e8 or e9?)' + #10 +
        '            c=b b++ b++ b++ b++ a=*b a++ a&= 254 a== 0 if (00 or ff)' + #10 +
        '              b-- a=*b' + #10 +
        '              b-- a<<= 8 a+=*b' + #10 +
        '              b-- a<<= 8 a+=*b' + #10 +
        '              a-=b a++' + #10 +
        '              *b=a a>>= 8 b++' + #10 +
        '              *b=a a>>= 8 b++' + #10 +
        '              *b=a b++' + #10 +
        '            endif' + #10 +
        '            b=c' + #10 +
        '          endif' + #10 +
        '        endif' + #10 +
        '        a=*b out b++' + #10 +
        '      forever' + #10 +
        '    endif' + #10;
    pcomp := pcomp +
      '    b=0 c=0 d=0 a=0 r=a 1 r=a 2 (reset state)' + #10 +
      '  halt' + #10 +
      '  endif' + #10 + #10 +
      '  (in state d==0, expect a new code)' + #10 +
      '  (put length in r1 and inital part of offset in r2)' + #10 +
      '  c=a a=d a== 0 if' + #10 +
      '    a=c a>>= 6 a++ d=a' + #10 +
      '    a== 1 if (literal?)' + #10 +
      '      a+=c r=a 1 a=0 r=a 2' + #10 +
      '    else (3 to 5 byte match)' + #10 +
      '      d++ a=c a&= 63 a+= $3 r=a 1 a=0 r=a 2' + #10 +
      '    endif' + #10 +
      '  else' + #10 +
      '    a== 1 if (writing literal)' + #10 +
      '      a=c *b=a b++' + #10;
    if doe8 = 0 then pcomp := pcomp + ' out' + #10;
    pcomp := pcomp +
      '      a=r 1 a-- a== 0 if d=0 endif r=a 1 (if (--len==0) state=0)' + #10 +
      '    else' + #10 +
      '      a> 2 if (reading offset)' + #10 +
      '        a=r 2 a<<= 8 a|=c r=a 2 d-- (off=off<<8|c, --state)' + #10 +
      '      else (state==2, write match)' + #10 +
      '        a=r 2 a<<= 8 a|=c c=a a=b a-=c a-- c=a (c=i-off-1)' + #10 +
      '        d=r 1 (d=len)' + #10 +
      '        do (copy and output d=len bytes)' + #10 +
      '          a=*c *b=a c++ b++' + #10;
    if doe8 = 0 then pcomp := pcomp + ' out' + #10;
    pcomp := pcomp +
      '        d-- a=d a> 0 while' + #10 +
      '        (d=state=0. off, len don''t matter)' + #10 +
      '      endif' + #10 +
      '    endif' + #10 +
      '  endif' + #10 +
      '  halt' + #10 +
      'end' + #10;
  end  { level=2 }

  else if level = 3 then begin
    hdr := 'comp 9 16 $1+20 $1+20 ';
    pcomp :=
      'pcomp bwtrle c ;' + #10 + #10 +
      '  (read BWT, index into M, size in b)' + #10 +
      '  a> 255 ifnot' + #10 +
      '    *b=a b++' + #10 + #10 +
      '  (inverse BWT)' + #10 +
      '  elsel' + #10 + #10 +
      '    (index in last 4 bytes, put in c and R1)' + #10 +
      '    b-- a=*b' + #10 +
      '    b-- a<<= 8 a+=*b' + #10 +
      '    b-- a<<= 8 a+=*b' + #10 +
      '    b-- a<<= 8 a+=*b c=a r=a 1' + #10 + #10 +
      '    (save size in R2)' + #10 +
      '    a=b r=a 2' + #10 + #10 +
      '    (count bytes in H[~1..~255, ~0])' + #10 +
      '    do' + #10 +
      '      a=b a> 0 if' + #10 +
      '        b-- a=*b a++ a&= 255 d=a d! *d++' + #10 +
      '      forever' + #10 +
      '    endif' + #10 + #10 +
      '    (cumulative counts: H[~i=0..255] = count of bytes before i)' + #10 +
      '    d=0 d! *d= 1 a=0' + #10 +
      '    do' + #10 +
      '      a+=*d *d=a d--' + #10 +
      '    d<>a a! a> 255 a! d<>a until' + #10 + #10 +
      '    (build first part of linked list in H[0..idx-1])' + #10 +
      '    b=0 do' + #10 +
      '      a=c a>b if' + #10 +
      '        d=*b d! *d++ d=*d d-- *d=b' + #10 +
      '      b++ forever' + #10 +
      '    endif' + #10 + #10 +
      '    (rest of list in H[idx+1..n-1])' + #10 +
      '    b=c b++ c=r 2 do' + #10 +
      '      a=c a>b if' + #10 +
      '        d=*b d! *d++ d=*d d-- *d=b' + #10 +
      '      b++ forever' + #10 +
      '    endif' + #10 + #10;
    if args[0] <= 4 then begin
      pcomp := pcomp +
        '    (copy M to low 8 bits of H to reduce cache misses in next loop)' + #10 +
        '    b=0 do' + #10 +
        '      a=c a>b if' + #10 +
        '        d=b a=*d a<<= 8 a+=*b *d=a' + #10 +
        '      b++ forever' + #10 +
        '    endif' + #10 + #10 +
        '    (traverse list and output or copy to M)' + #10 +
        '    d=r 1 b=0 do' + #10 +
        '      a=d a== 0 ifnot' + #10 +
        '        a=*d a>>= 8 d=a' + #10;
      if doe8 <> 0 then pcomp := pcomp + ' *b=*d b++' + #10
      else              pcomp := pcomp + ' a=*d out' + #10;
      pcomp := pcomp +
        '      forever' + #10 +
        '    endif' + #10 + #10;
      if doe8 <> 0 then
        pcomp := pcomp +
          '    (e8e9 transform to out)' + #10 +
          '    d=b b=0 do (for b=0..d-1, d = end of buf)' + #10 +
          '      a=b a==d ifnot' + #10 +
          '        a+= 4 a<d if' + #10 +
          '          a=*b a&= 254 a== 232 if' + #10 +
          '            c=b b++ b++ b++ b++ a=*b a++ a&= 254 a== 0 if' + #10 +
          '              b-- a=*b' + #10 +
          '              b-- a<<= 8 a+=*b' + #10 +
          '              b-- a<<= 8 a+=*b' + #10 +
          '              a-=b a++' + #10 +
          '              *b=a a>>= 8 b++' + #10 +
          '              *b=a a>>= 8 b++' + #10 +
          '              *b=a b++' + #10 +
          '            endif' + #10 +
          '            b=c' + #10 +
          '          endif' + #10 +
          '        endif' + #10 +
          '        a=*b out b++' + #10 +
          '      forever' + #10 +
          '    endif' + #10;
      pcomp := pcomp +
        '  endif' + #10 +
        '  halt' + #10 +
        'end' + #10;
    end  { args[0]<=4 }
    else begin
      { slower IBWT for large blocks }
      if doe8 <> 0 then
        pcomp := pcomp +
          '    (R2 = output size without EOS)' + #10 +
          '    a=r 2 a-- r=a 2' + #10 + #10 +
          '    (traverse list (d = IBWT pointer) and output inverse e8e9)' + #10 +
          '    (C = offset = 0..R2-1)' + #10 +
          '    (R4 = last 4 bytes shifted in from MSB end)' + #10 +
          '    (R5 = temp pending output byte)' + #10 +
          '    c=0 d=r 1 do' + #10 +
          '      a=d a== 0 ifnot' + #10 +
          '        d=*d' + #10 + #10 +
          '        (store byte in R4 and shift out to R5)' + #10 +
          '        b=d a=*b a<<= 24 b=a' + #10 +
          '        a=r 4 r=a 5 a>>= 8 a|=b r=a 4' + #10 + #10 +
          '        (if E8|E9 xx xx xx 00|FF in R4:R5 then subtract c from x)' + #10 +
          '        a=c a> 3 if' + #10 +
          '          a=r 5 a&= 254 a== 232 if' + #10 +
          '            a=r 4 a>>= 24 b=a a++ a&= 254 a< 2 if' + #10 +
          '              a=r 4 a-=c a+= 4 a<<= 8 a>>= 8 ' + #10 +
          '              b<>a a<<= 24 a+=b r=a 4' + #10 +
          '            endif' + #10 +
          '          endif' + #10 +
          '        endif' + #10 + #10 +
          '        (output buffered byte)' + #10 +
          '        a=c a> 3 if a=r 5 out endif c++' + #10 + #10 +
          '      forever' + #10 +
          '    endif' + #10 + #10 +
          '    (output up to 4 pending bytes in R4)' + #10 +
          '    b=r 4' + #10 +
          '    a=c a> 3 a=b if out endif a>>= 8 b=a' + #10 +
          '    a=c a> 2 a=b if out endif a>>= 8 b=a' + #10 +
          '    a=c a> 1 a=b if out endif a>>= 8 b=a' + #10 +
          '    a=c a> 0 a=b if out endif' + #10 + #10 +
          '  endif' + #10 +
          '  halt' + #10 +
          'end' + #10
      else
        pcomp := pcomp +
          '    (traverse list and output)' + #10 +
          '    d=r 1 do' + #10 +
          '      a=d a== 0 ifnot' + #10 +
          '        d=*d' + #10 +
          '        b=d a=*b out' + #10 +
          '      forever' + #10 +
          '    endif' + #10 +
          '  endif' + #10 +
          '  halt' + #10 +
          'end' + #10;
    end;
  end  { level=3 }

  else begin  { level=0: E8E9 or none }
    hdr := 'comp 9 16 0 0 ';
    if doe8 <> 0 then
      pcomp :=
        'pcomp e8e9 d ;' + #10 +
        '  a> 255 if' + #10 +
        '    a=c a> 4 if' + #10 +
        '      c= 4' + #10 +
        '    else' + #10 +
        '      a! a+= 5 a<<= 3 d=a a=b a>>=d b=a' + #10 +
        '    endif' + #10 +
        '    do a=c a> 0 if' + #10 +
        '      a=b out a>>= 8 b=a c--' + #10 +
        '    forever endif' + #10 +
        '  else' + #10 +
        '    *b=b a<<= 24 d=a a=b a>>= 8 a+=d b=a c++' + #10 +
        '    a=c a> 4 if' + #10 +
        '      a=*b out' + #10 +
        '      a&= 254 a== 232 if' + #10 +
        '        a=b a>>= 24 a++ a&= 254 a== 0 if' + #10 +
        '          a=b a>>= 24 a<<= 24 d=a' + #10 +
        '          a=b a-=c a+= 5' + #10 +
        '          a<<= 8 a>>= 8 a|=d b=a' + #10 +
        '        endif' + #10 +
        '      endif' + #10 +
        '    endif' + #10 +
        '  endif' + #10 +
        '  halt' + #10 +
        'end' + #10
    else
      pcomp := 'end' + #10;
  end;

  { ---------- build context model ---------- }
  ncomp := 0;
  membits := args[0] + 20;
  sb := 5;
  comp := '';
  hcomp := 'hcomp' + #10 + 'c-- *c=a a+= 255 d=a *d=c' + #10;

  if level = 2 then begin
    hcomp := hcomp +
      '  (decode lz77 into M. Codes:' + #10 +
      '  00xxxxxx = literal length xxxxxx+1' + #10 +
      '  xx......, xx > 0 = match with xx offset bytes to follow)' + #10 + #10 +
      '  a=r 1 a== 0 if (init)' + #10 +
      '    a= ' + itos(111 + 57*doe8) + ' (skip post code)' + #10 +
      '  else a== 1 if  (new code?)' + #10 +
      '    a=*c r=a 2  (save code in R2)' + #10 +
      '    a> 63 if a>>= 6 a++ a++  (match)' + #10 +
      '    else a++ a++ endif  (literal)' + #10 +
      '  else (read rest of code)' + #10 +
      '    a--' + #10 +
      '  endif endif' + #10 +
      '  r=a 1  (R1 = 1+expected bytes to next code)' + #10;
  end;

  { parse remaining method characters }
  while (mpos <= Length(meth)) and (ncomp < 254) do begin
    { parse command C[N1[,N2]...] into v }
    SetLength(v, 1);
    v[0] := Ord(MCadv());
    vlen := 1;
    if isDigit(MC()) then begin
      SetLength(v, vlen+1);
      v[vlen] := Ord(MCadv()) - Ord('0');
      Inc(vlen);
      while isDigit(MC()) or (MC() = ',') or (MC() = '.') do begin
        if isDigit(MC()) then
          v[vlen-1] := v[vlen-1]*10 + Ord(MCadv()) - Ord('0')
        else begin
          SetLength(v, vlen+1);
          v[vlen] := 0;
          Inc(vlen);
          MCadv();
        end;
      end;
    end;

    { command 'c': context model }
    if v[0] = Ord('c') then begin
      while vlen < 3 do begin SetLength(v, vlen+1); v[vlen] := 0; Inc(vlen); end;
      comp := comp + itos(ncomp) + ' ';
      sb := 11;
      if v[2] < 256 then sb := sb + lg(v[2]) else sb := sb + 6;
      for i := 3 to vlen-1 do
        if v[i] < 512 then sb := sb + nbits(v[i])*3 div 4;
      if sb > membits then sb := membits;
      if v[1] mod 1000 = 0 then
        comp := comp + 'icm ' + itos(sb - 6 - v[1] div 1000) + #10
      else
        comp := comp + 'cm ' + itos(sb - 2 - v[1] div 1000) + ' ' + itos(v[1] mod 1000 - 1) + #10;

      hcomp := hcomp + 'd= ' + itos(ncomp) + ' *d=0' + #10;
      if (v[2] > 1) and (v[2] <= 255) then begin
        if lg(v[2]) <> lg(v[2]-1) then
          hcomp := hcomp + 'a=c a&= ' + itos(v[2]-1) + ' hashd' + #10
        else
          hcomp := hcomp + 'a=c a%= ' + itos(v[2]) + ' hashd' + #10;
      end
      else if (v[2] >= 1000) and (v[2] <= 1255) then
        hcomp := hcomp + 'a= 255 a+= ' + itos(v[2]-1000) +
                 ' d=a a=*d a-=c a> 255 if a= 255 endif d= ' +
                 itos(ncomp) + ' hashd' + #10;

      for i := 3 to vlen-1 do begin
        if i = 3 then hcomp := hcomp + 'b=c ';
        if v[i] = 255 then
          hcomp := hcomp + 'a=*b hashd' + #10
        else if (v[i] > 0) and (v[i] < 255) then
          hcomp := hcomp + 'a=*b a&= ' + itos(v[i]) + ' hashd' + #10
        else if (v[i] >= 256) and (v[i] < 512) then begin
          hcomp := hcomp +
            'a=r 1 a> 1 if' + #10 +
            '  a=r 2 a< 64 if' + #10 +
            '    a=*b ';
          if v[i] < 511 then hcomp := hcomp + 'a&= ' + itos(v[i]-256);
          hcomp := hcomp + ' hashd' + #10 +
            '  else' + #10 +
            '    a>>= 6 hashd a=r 1 hashd' + #10 +
            '  endif' + #10 +
            'else' + #10 +
            '  a= 255 hashd a=r 2 hashd' + #10 +
            'endif' + #10;
        end
        else if v[i] >= 1256 then
          hcomp := hcomp + 'a= ' + itos(((v[i]-1000) shr 8) and 255) +
                   ' a<<= 8 a+= ' + itos((v[i]-1000) and 255) + ' a+=b b=a' + #10
        else if v[i] > 1000 then
          hcomp := hcomp + 'a= ' + itos(v[i]-1000) + ' a+=b b=a' + #10;
        if (v[i] < 512) and (i < vlen-1) then
          hcomp := hcomp + 'b++ ';
      end;
      Inc(ncomp);
    end;

    { commands 'm', 't', 's' }
    if (v[0] = Ord('m')) or (v[0] = Ord('t')) or (v[0] = Ord('s')) then begin
      if (ncomp > 0) or (v[0] <> Ord('t')) then begin
        if vlen <= 1 then begin SetLength(v, vlen+1); v[vlen] := 8;   Inc(vlen); end;
        if vlen <= 2 then begin
          SetLength(v, vlen+1);
          if v[0] = Ord('s') then v[vlen] := 32 else v[vlen] := 24;
          Inc(vlen);
        end;
        if (v[0] = Ord('s')) and (vlen <= 3) then begin
          SetLength(v, vlen+1); v[vlen] := 255; Inc(vlen);
        end;
        comp := comp + itos(ncomp);
        sb := 5 + v[1]*3 div 4;
        if v[0] = Ord('m') then
          comp := comp + ' mix ' + itos(v[1]) + ' 0 ' + itos(ncomp) + ' ' + itos(v[2]) + ' 255' + #10
        else if v[0] = Ord('t') then
          comp := comp + ' mix2 ' + itos(v[1]) + ' ' + itos(ncomp-1) + ' ' + itos(ncomp-2) +
                  ' ' + itos(v[2]) + ' 255' + #10
        else
          comp := comp + ' sse ' + itos(v[1]) + ' ' + itos(ncomp-1) + ' ' + itos(v[2]) + ' ' +
                  itos(v[3]) + #10;
        if v[1] > 8 then begin
          hcomp := hcomp + 'd= ' + itos(ncomp) + ' *d=0 b=c a=0' + #10;
          j := v[1];
          while j >= 16 do begin
            hcomp := hcomp + 'a<<= 8 a+=*b';
            if j > 16 then hcomp := hcomp + ' b++';
            hcomp := hcomp + #10;
            Dec(j, 8);
          end;
          if j > 8 then
            hcomp := hcomp + 'a<<= 8 a+=*b a>>= ' + itos(16-j) + #10;
          hcomp := hcomp + 'a<<= 8 *d=a' + #10;
        end;
        Inc(ncomp);
      end;
    end;

    { command 'i': ISSE chain }
    if (v[0] = Ord('i')) and (ncomp > 0) then begin
      hcomp := hcomp + 'd= ' + itos(ncomp-1) + ' b=c a=*d d++' + #10;
      for i := 1 to vlen-1 do begin
        if ncomp >= 254 then Break;
        for j := 0 to (v[i] mod 10) - 1 do begin
          hcomp := hcomp + 'hash ';
          if (i < vlen-1) or (j < (v[i] mod 10) - 1) then
            hcomp := hcomp + 'b++ ';
          Inc(sb, 6);
        end;
        hcomp := hcomp + '*d=a';
        if i < vlen-1 then hcomp := hcomp + ' d++';
        hcomp := hcomp + #10;
        if sb > membits then sb := membits;
        comp := comp + itos(ncomp) + ' isse ' + itos(sb-6-v[i] div 10) + ' ' + itos(ncomp-1) + #10;
        Inc(ncomp);
      end;
    end;

    { command 'a': MATCH }
    if v[0] = Ord('a') then begin
      if vlen <= 1 then begin SetLength(v, vlen+1); v[vlen] := 24; Inc(vlen); end;
      while vlen < 4 do begin SetLength(v, vlen+1); v[vlen] := 0; Inc(vlen); end;
      comp := comp + itos(ncomp) + ' match ' + itos(membits-v[3]-2) + ' ' + itos(membits-v[2]) + #10;
      hcomp := hcomp + 'd= ' + itos(ncomp) + ' a=*d a*= ' + itos(v[1]) + ' a+=*c a++ *d=a' + #10;
      sb := 5 + (membits - v[2])*3 div 4;
      Inc(ncomp);
    end;

    { command 'w': ICM-ISSE chain with word contexts }
    if v[0] = Ord('w') then begin
      if vlen <= 1 then begin SetLength(v, vlen+1); v[vlen] := 1;   Inc(vlen); end;
      if vlen <= 2 then begin SetLength(v, vlen+1); v[vlen] := 65;  Inc(vlen); end;
      if vlen <= 3 then begin SetLength(v, vlen+1); v[vlen] := 26;  Inc(vlen); end;
      if vlen <= 4 then begin SetLength(v, vlen+1); v[vlen] := 223; Inc(vlen); end;
      if vlen <= 5 then begin SetLength(v, vlen+1); v[vlen] := 20;  Inc(vlen); end;
      if vlen <= 6 then begin SetLength(v, vlen+1); v[vlen] := 0;   Inc(vlen); end;
      comp := comp + itos(ncomp) + ' icm ' + itos(membits - 6 - v[6]) + #10;
      for i := 1 to v[1]-1 do
        comp := comp + itos(ncomp+i) + ' isse ' + itos(membits - 6 - v[6]) + ' ' + itos(ncomp+i-1) + #10;
      hcomp := hcomp + 'a=*c a&= ' + itos(v[4]) + ' a-= ' + itos(v[2]) + ' a&= 255 a< ' + itos(v[3]) + ' if' + #10;
      for i := 0 to v[1]-1 do begin
        if i = 0 then hcomp := hcomp + '  d= ' + itos(ncomp)
        else           hcomp := hcomp + '  d++';
        hcomp := hcomp + ' a=*d a*= ' + itos(v[5]) + ' a+=*c a++ *d=a' + #10;
      end;
      hcomp := hcomp + 'else' + #10;
      for i := v[1]-1 downto 1 do
        hcomp := hcomp + '  d= ' + itos(ncomp+i-1) + ' a=*d d++ *d=a' + #10;
      hcomp := hcomp + '  d= ' + itos(ncomp) + ' *d=0' + #10 + 'endif' + #10;
      ncomp := ncomp + v[1] - 1;
      sb := membits - v[6];
      Inc(ncomp);
    end;

  end; { while mpos }

  config := hdr + itos(ncomp) + #10 + comp + hcomp + 'halt' + #10 + pcomp;
  Result := config;
end;

{ ============================================================ }
{  compressBlock                                                }
{ ============================================================ }

procedure compressBlock(inbuf: TStringBuffer; out_: TZPAQLStream;
                        const method: AnsiString;
                        const filename: AnsiString;
                        const comment: AnsiString;
                        dosha1: Boolean);
var
  methodStr: AnsiString;   { Delphi forbids local-var initializers; AnsiString auto-inits to '' }
  n: U32;
  arg0: Integer;
  mtype: AnsiChar;
  commas, level_: Integer;
  arg: array[0..3] of Integer;
  typ_: U32;
  doe8: Integer;
  i: Integer;
  sha1: TSHA1;
  sha1ptr: PU8;
  htsz, sasz: AnsiString;
  config: AnsiString;
  args: array[0..8] of Integer;
  co: TCompressor;
  pcomp_cmd: TStringBuffer;
  cs: AnsiString;
  lz: TLZBuffer;
  NR: Integer;
  pt: array[0..255] of Integer;
  r: array[0..4095] of Integer;
  p: PU8;
  k, r1, r2: Integer;
  period: Integer;
  score, s: Double;
  n1, t: Integer;
begin
  n := inbuf.size();
  arg0 := 0;
  if n + 4095 > 0 then begin
    { arg0 = max(lg(n+4095)-20, 0) }
    arg0 := lg(n + 4095) - 20;
    if arg0 < 0 then arg0 := 0;
  end;

  methodStr := method;
  typ_ := 0;
  if (Length(methodStr) > 0) and (methodStr[1] >= '0') and (methodStr[1] <= '9') then begin
    commas := 0;
    FillChar(arg, SizeOf(arg), 0);
    for i := 2 to Length(methodStr) do begin
      if (methodStr[i] = ',') or (methodStr[i] = '.') then
        Inc(commas)
      else if (methodStr[i] >= '0') and (methodStr[i] <= '9') then
        arg[commas] := arg[commas]*10 + Ord(methodStr[i]) - Ord('0');
    end;
    if commas = 0 then typ_ := 512
    else typ_ := U32(arg[1]*4 + arg[2]);
  end;

  { SHA1 of input }
  sha1ptr := nil;
  if dosha1 then begin
    sha1 := TSHA1.Create;
    try
      if n > 0 then sha1.bwrite(inbuf.data(), n);
      sha1ptr := sha1.getResult();
    except
      sha1.Free; raise;
    end;
    { sha1 freed later -- actually we need result ptr before freeing }
    { we store result in a local buffer }
  end;

  { expand default numeric methods }
  if (Length(methodStr) > 0) and (methodStr[1] >= '0') and (methodStr[1] <= '9') then begin
    level_ := Ord(methodStr[1]) - Ord('0');
    doe8 := (Integer(typ_) and 2) * 2;  { 0 or 4 }
    methodStr := 'x' + itos(arg0);
    htsz := ',' + itos(19 + arg0 + Integer(arg0 <= 6));
    sasz := ',' + itos(21 + arg0);

    if level_ = 0 then
      methodStr := '0' + itos(arg0) + ',0'
    else if level_ = 1 then begin
      if typ_ < 40 then methodStr := methodStr + ',0'
      else begin
        methodStr := methodStr + ',' + itos(1+doe8) + ',';
        if      typ_ < 80  then methodStr := methodStr + '4,0,1,15'
        else if typ_ < 128 then methodStr := methodStr + '4,0,2,16'
        else if typ_ < 256 then methodStr := methodStr + '4,0,2' + htsz
        else if typ_ < 960 then methodStr := methodStr + '5,0,3' + htsz
        else                     methodStr := methodStr + '6,0,3' + htsz;
      end;
    end
    else if level_ = 2 then begin
      if typ_ < 32 then methodStr := methodStr + ',0'
      else begin
        methodStr := methodStr + ',' + itos(1+doe8) + ',';
        if typ_ < 64 then methodStr := methodStr + '4,0,3' + htsz
        else              methodStr := methodStr + '4,0,7' + sasz + ',1';
      end;
    end
    else if level_ = 3 then begin
      if      typ_ < 20  then methodStr := methodStr + ',0'
      else if typ_ < 48  then methodStr := methodStr + ',' + itos(1+doe8) + ',4,0,3' + htsz
      else if (typ_ >= 640) or (Integer(typ_) and 1 <> 0) then
        methodStr := methodStr + ',' + itos(3+doe8) + 'ci1'
      else
        methodStr := methodStr + ',' + itos(2+doe8) + ',12,0,7' + sasz + ',1c0,0,511i2';
    end
    else if level_ = 4 then begin
      if      typ_ < 12  then methodStr := methodStr + ',0'
      else if typ_ < 24  then methodStr := methodStr + ',' + itos(1+doe8) + ',4,0,3' + htsz
      else if typ_ < 48  then methodStr := methodStr + ',' + itos(2+doe8) + ',5,0,7' + sasz + '1c0,0,511'
      else if typ_ < 900 then begin
        methodStr := methodStr + ',' + itos(doe8) + 'ci1,1,1,1,2a';
        if Integer(typ_) and 1 <> 0 then methodStr := methodStr + 'w';
        methodStr := methodStr + 'm';
      end
      else
        methodStr := methodStr + ',' + itos(3+doe8) + 'ci1';
    end
    else begin  { level 5..9 }
      methodStr := methodStr + ',' + itos(doe8);
      if Integer(typ_) and 1 <> 0 then methodStr := methodStr + 'w2c0,1010,255i1'
      else                              methodStr := methodStr + 'w1i1';
      methodStr := methodStr + 'c256ci1,1,1,1,1,1,2a';

      { analyze data for periodic models }
      NR := 1 shl 12;
      FillChar(pt, SizeOf(pt), 0);
      FillChar(r,  SizeOf(r),  0);
      p := inbuf.data();
      for i := 0 to Integer(n)-1 do begin
        k := i - pt[p[i]];
        if (k > 0) and (k < NR) then Inc(r[k]);
        pt[p[i]] := i;
      end;

      n1 := Integer(n) - r[1] - r[2] - r[3];
      for r1 := 0 to 1 do begin
        period := 0; score := 0; t := 0;
        for r2 := 5 to NR-1 do begin
          if t >= n1 then Break;
          s := r[r2] / (256.0 + n1 - t);
          if s > score then begin score := s; period := r2; end;
          Inc(t, r[r2]);
        end;
        if (period > 4) and (score > 0.1) then begin
          methodStr := methodStr + 'c0,0,' + itos(999+period) + ',255i1';
          if period <= 255 then
            methodStr := methodStr + 'c0,' + itos(period) + 'i1';
          Dec(n1, r[period]);
          r[period] := 0;
        end
        else Break;
      end;
      methodStr := methodStr + 'c0,2,0,255i1c0,3,0,0,255i1c0,4,0,0,0,255i1mm16ts19t0';
    end;
  end;  { end expand numeric methodStr }

  { compile config }
  FillChar(args, SizeOf(args), 0);
  config := makeConfig(methodStr, PInteger(@args[0]));

  { compress }
  co := TCompressor.Create;
  pcomp_cmd := TStringBuffer.Create;
  try
    co.setOutput(out_);
    co.writeTag();
    co.startBlock(config, PInteger(@args[0]), pcomp_cmd);
    cs := itos(Int64(n));
    if comment <> '' then cs := cs + ' ' + comment;
    co.startSegment(filename, cs);

    if (args[1] >= 1) and (args[1] <= 7) and (args[1] <> 4) then begin
      { LZ77 or BWT preprocessing }
      lz := TLZBuffer.Create(inbuf, @args);
      try
        co.setInput(lz);
        while co.compress(-1) do ;
      finally
        lz.Free;
      end;
    end
    else begin
      { e8e9 or none }
      if (args[1] >= 4) and (args[1] <= 7) then
        e8e9(inbuf.data(), inbuf.size());
      co.setInput(inbuf);
      while co.compress(-1) do ;
    end;

    co.endSegment(PAnsiChar(sha1ptr));
    co.endBlock();
  finally
    pcomp_cmd.Free;
    co.Free;
    if dosha1 and Assigned(sha1) then sha1.Free;
  end;
end;

{ ============================================================ }
{  Public API: zpaq_compress / zpaq_decompress                  }
{ ============================================================ }

procedure zpaq_compress(input, output: TZPAQLStream;
                        const method: AnsiString;
                        const filename: AnsiString;
                        const comment: AnsiString;
                        dosha1: Boolean);
var
  buf: TStringBuffer;
  c: Integer;
begin
  { read all input into memory buffer }
  buf := TStringBuffer.Create;
  try
    repeat
      c := input.get();
      if c >= 0 then buf.put(c);
    until c < 0;
    compressBlock(buf, output, method, filename, comment, dosha1);
  finally
    buf.Free;
  end;
end;

procedure zpaq_decompress(input: TZPAQLStream; output: TZPAQLStream);
var
  dec: TDecompresser;
begin
  dec := TDecompresser.Create;
  try
    dec.setInput(input);
    dec.setOutput(output);
    while dec.findBlock(nil) do begin
      while dec.findFilename(nil) do begin
        dec.readComment(nil);
        while dec.decompress(-1) do ;
        dec.readSegmentEnd(nil);
      end;
    end;
  finally
    dec.Free;
  end;
end;

end.
