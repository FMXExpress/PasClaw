unit ZpaqClasses;


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

//ZpaqClasses — high-level Pascal wrapper for libzpaq.
//TZpaqPacker   – appends files (from TStream) to a .zpaq archive.
//TZpaqUnpacker – enumerates and extracts files from a .zpaq archive.
//                Supports both streaming and journaling formats.


{ PasClaw: mode directive guarded so the unit also compiles under Delphi. }
{$IFDEF FPC}{$mode objfpc}{$H+}{$ENDIF}

interface

uses
  SysUtils, Classes, DateUtils, libzpaq;

{$IFNDEF FPC}
type
  DWord = LongWord;   { FPC built-in; not in scope on Delphi without Winapi }
{$ENDIF}

{ ------------------------------------------------------------------ }
{  Filter callback: return True to extract the file, False to skip.   }
{  Assign nil to ExtractAll to extract everything.                     }
{ ------------------------------------------------------------------ }
type
  TZpaqFilterEvent = function(const AName: String; ASize: Int64;
                              ADate: TDateTime): Boolean of object;

{ ================================================================== }
{  TZpaqPacker                                                         }
{                                                                      }
{  Appends one compressed segment per AddFile() call.                 }
{  The resulting archive is a valid streaming .zpaq file readable      }
{  by zpaq64 x archive -to outdir                                      }
{ ================================================================== }
  TZpaqPacker = class
  private
    FArchiveName : String;
    FMethod      : String;
  public
    { ArchiveName: path to .zpaq file (created or appended) }
    constructor Create(const ArchiveName: String);

    { Set compression level 0..5 (default 3).
        0 = store (no compression)
        1 = fast
        3 = balanced  (default)
        5 = best }
    procedure SetMethod(Level: Integer); overload;

    { Set a custom method string, e.g. 'x3,1,4,0,3' }
    procedure SetMethod(const Method: String); overload;

    { Compress the contents of S and store it in the archive.
      Path is the name recorded inside the archive (may include
      subdirectory separators, e.g. 'subdir/file.txt'). }
    procedure AddFile(S: TStream; const Path: String);
  end;

{ ================================================================== }
{  TZpaqUnpacker                                                       }
{                                                                      }
{  Usage:                                                              }
{    u := TZpaqUnpacker.Create('archive.zpaq');                        }
{    while u.NextEntry(Name, Size, Date) do begin                      }
{      if WantThisFile(Name) then                                      }
{        u.Extract(someStream);                                        }
{    end;                                                              }
{    u.Free;                                                           }
{ ================================================================== }
  TZpaqUnpacker = class
  private
    { ---- internal record types ---- }
    type
      THTRec = record
        sha1 : array[0..19] of Byte;
        usize: Integer;              { uncompressed size, -1 if unknown }
      end;
      TBlockRec = record
        offset: Int64;               { file offset of the 'd' block }
        start : Cardinal;            { first fragment index }
        count : Cardinal;            { number of fragments }
        bsize : Cardinal;            { compressed size of 'd' block }
      end;
      TFileRec = record
        Name : String;
        Size : Int64;                { -1 for streaming archives }
        Date : TDateTime;            {  0 for streaming archives }
        { journaling: fragment indices into Fht[] }
        Ptrs : array of Cardinal;
        { streaming: entire decompressed file data cached here }
        Data : TMemoryStream;
      end;

  private
    FArchiveName  : String;
    FIsJournaling : Boolean;
    FEntries      : array of TFileRec;
    FCount        : Integer;
    FCurrent      : Integer;          { index of last NextEntry result }

    { journaling tables }
    Fht           : array of THTRec;
    FhtCount      : Integer;
    Fblocks       : array of TBlockRec;
    FblockCount   : Integer;

    procedure ScanArchive;
    function  DoScanPass(reader    : TZPAQLStream;
                         memBuf    : TMemoryStream;
                         var dataOff: Int64): Boolean;

    function  ZpaqDateToDateTime(d: Int64): TDateTime;
    function  FindBlockForFrag(fragIdx: Cardinal): Integer;
    procedure DecompressJournalEntry(idx: Integer; Dest: TStream);

  public
    constructor Create(const ArchiveName: String);
    destructor  Destroy; override;

    { Restart iteration from the first entry. }
    procedure Reset;

    { Advance to the next entry.
      Returns False when there are no more entries.
      ASize = -1  and  ADate = 0  for streaming archives. }
    function NextEntry(out AName: String;
                       out ASize: Int64;
                       out ADate: TDateTime): Boolean;

    { Extract the current entry (from the last NextEntry call) to Dest.
      Safe to call multiple times on the same entry. }
    procedure Extract(Dest: TStream);

    { Extract all entries to OutDir.
      If OnFilter is assigned, only files for which it returns True
      are written to disk; others are skipped silently. }
    procedure ExtractAll(const OutDir  : String;
                         OnFilter: TZpaqFilterEvent = nil);
  end;

{ ================================================================== }
{  Internal bridge streams                                             }
{ ================================================================== }
type
  { Read-only bridge: TStream -> TZPAQLStream (with seek/tell) }
  TReadBridge = class(TZPAQLStream)
  private
    FStream: TStream;
    FOwned : Boolean;
  public
    constructor Create(AStream: TStream; AOwned: Boolean = False);
    destructor  Destroy; override;
    function  get(): Integer; override;
    function  bread(buf: PU8; n: Integer): Integer; override;
    function  tell(): Int64; override;
    function  seek(pos: Int64): Boolean; override;
  end;

  { Write-only bridge: TStream -> TZPAQLStream }
  TWriteBridge = class(TZPAQLStream)
  private
    FStream: TStream;
  public
    constructor Create(AStream: TStream);
    procedure put(c: Integer); override;
    procedure bwrite(buf: PU8; n: Integer); override;
  end;

implementation

type

  { Appends to a file (creates the file if it does not exist) }
  TFileAppendWriter = class(TZPAQLStream)
  private
    FStream: TFileStream;
  public
    constructor Create(const FileName: String);
    destructor  Destroy; override;
    procedure put(c: Integer); override;
    procedure bwrite(buf: PU8; n: Integer); override;
  end;

  { Accumulates decompressed output into a TMemoryStream }
  TMemOutBridge = class(TZPAQLStream)
  private
    FMem: TMemoryStream;
  public
    constructor Create(AMem: TMemoryStream);
    procedure put(c: Integer); override;
    procedure bwrite(buf: PU8; n: Integer); override;
    procedure reset();
  end;

{ ---- TReadBridge ---- }

constructor TReadBridge.Create(AStream: TStream; AOwned: Boolean);
begin
  inherited Create;
  FStream := AStream;
  FOwned  := AOwned;
end;

destructor TReadBridge.Destroy;
begin
  if FOwned then FStream.Free;
  inherited;
end;

function TReadBridge.get(): Integer;
var b: Byte;
begin
  if FStream.Read(b, 1) = 1 then Result := b else Result := -1;
end;

function TReadBridge.bread(buf: PU8; n: Integer): Integer;
begin
  Result := FStream.Read(buf^, n);
end;

function TReadBridge.tell(): Int64;
begin
  Result := FStream.Position;
end;

function TReadBridge.seek(pos: Int64): Boolean;
begin
  try
    FStream.Position := pos;
    Result := True;
  except
    Result := False;
  end;
end;

{ ---- TWriteBridge ---- }

constructor TWriteBridge.Create(AStream: TStream);
begin
  inherited Create;
  FStream := AStream;
end;

procedure TWriteBridge.put(c: Integer);
var b: Byte;
begin
  b := Byte(c and $FF);
  FStream.Write(b, 1);
end;

procedure TWriteBridge.bwrite(buf: PU8; n: Integer);
begin
  if n > 0 then FStream.Write(buf^, n);
end;

{ ---- TFileAppendWriter ---- }

constructor TFileAppendWriter.Create(const FileName: String);
begin
  inherited Create;
  if FileExists(FileName) then
    FStream := TFileStream.Create(FileName, fmOpenReadWrite or fmShareDenyWrite)
  else
    FStream := TFileStream.Create(FileName, fmCreate);
  FStream.Seek(0, soEnd);
end;

destructor TFileAppendWriter.Destroy;
begin
  FStream.Free;
  inherited;
end;

procedure TFileAppendWriter.put(c: Integer);
var b: Byte;
begin
  b := Byte(c and $FF);
  FStream.Write(b, 1);
end;

procedure TFileAppendWriter.bwrite(buf: PU8; n: Integer);
begin
  if n > 0 then FStream.Write(buf^, n);
end;

{ ---- TMemOutBridge ---- }

constructor TMemOutBridge.Create(AMem: TMemoryStream);
begin
  inherited Create;
  FMem := AMem;
end;

procedure TMemOutBridge.put(c: Integer);
var b: Byte;
begin
  b := Byte(c and $FF);
  FMem.Write(b, 1);
end;

procedure TMemOutBridge.bwrite(buf: PU8; n: Integer);
begin
  if n > 0 then FMem.Write(buf^, n);
end;

procedure TMemOutBridge.reset();
begin
  FMem.Size     := 0;
  FMem.Position := 0;
end;

{ ================================================================== }
{  Little-endian binary readers (ZPAQ journaling format)              }
{ ================================================================== }

function btoi(var p: PAnsiChar): Cardinal; inline;
begin
  Result := Byte(p[0]) or (Byte(p[1]) shl 8)
          or (Byte(p[2]) shl 16) or (Byte(p[3]) shl 24);
  Inc(p, 4);
end;

function btol(var p: PAnsiChar): Int64; inline;
var lo, hi: Cardinal;
begin
  lo := btoi(p);
  hi := btoi(p);
  Result := Int64(lo) or (Int64(hi) shl 32);
end;

{ ================================================================== }
{  TZpaqPacker                                                         }
{ ================================================================== }

constructor TZpaqPacker.Create(const ArchiveName: String);
begin
  inherited Create;
  FArchiveName := ArchiveName;
  FMethod      := '3';
end;

procedure TZpaqPacker.SetMethod(Level: Integer);
begin
  if Level < 0 then Level := 0;
  if Level > 5 then Level := 5;
  FMethod := IntToStr(Level);
end;

procedure TZpaqPacker.SetMethod(const Method: String);
begin
  if Method <> '' then FMethod := Method;
end;

procedure TZpaqPacker.AddFile(S: TStream; const Path: String);
var
  reader: TReadBridge;
  writer: TFileAppendWriter;
begin
  reader := TReadBridge.Create(S, {owned=}False);
  writer := TFileAppendWriter.Create(FArchiveName);
  try
    zpaq_compress(reader, writer, AnsiString(FMethod),
                  AnsiString(Path), '', True);
  finally
    writer.Free;
    reader.Free;
  end;
end;

{ ================================================================== }
{  TZpaqUnpacker – internals                                           }
{ ================================================================== }

function TZpaqUnpacker.ZpaqDateToDateTime(d: Int64): TDateTime;
var
  ss, mi, hh, dd, mo, yy: Integer;
begin
  if d = 0 then begin Result := 0; Exit; end;
  ss := d mod 100; d := d div 100;
  mi := d mod 100; d := d div 100;
  hh := d mod 100; d := d div 100;
  dd := d mod 100; d := d div 100;
  mo := d mod 100; d := d div 100;
  yy := Integer(d);
  try
    Result := EncodeDateTime(yy, mo, dd, hh, mi, ss, 0);
  except
    Result := 0;
  end;
end;

{ ------------------------------------------------------------------ }
{  One scan pass over the archive.                                     }
{  Returns True if a seek was performed (buffer invalidated) —        }
{  the caller must loop with a fresh decompressor.                    }
{ ------------------------------------------------------------------ }
function TZpaqUnpacker.DoScanPass(reader  : TZPAQLStream;
                                  memBuf  : TMemoryStream;
                                  var dataOff: Int64): Boolean;
var
  dec      : TDecompresser;
  memOut   : TMemOutBridge;
  fnBuf    : TStringBuffer;
  cmBuf    : TStringBuffer;
  fnStr    : AnsiString;
  cmStr    : AnsiString;
  cmLen    : Integer;
  blockType: AnsiChar;
  didSeek  : Boolean;
  { journaling 'c' }
  jmp      : Int64;
  s        : PAnsiChar;
  { journaling 'h' }
  n, bsize : Cardinal;
  num      : Int64;
  i, j     : Integer;
  ch       : AnsiChar;
  { journaling 'i' }
  p, pEnd  : PAnsiChar;
  date     : Int64;
  na, ni   : Cardinal;
  ptrArr   : array of Cardinal;
  fsize    : Int64;
  fi       : Integer;
  { streaming }
  streamMS : TMemoryStream;
begin
  didSeek := False;
  memOut  := TMemOutBridge.Create(memBuf);
  dec     := TDecompresser.Create;
  fnBuf   := TStringBuffer.Create;
  cmBuf   := TStringBuffer.Create;
  try
    dec.setInput(reader);
    dec.setOutput(memOut);

    while (not didSeek) and dec.findBlock(nil) do begin
      while (not didSeek) and dec.findFilename(fnBuf) do begin

        { read filename }
        fnStr := '';
        if fnBuf.size() > 0 then
          SetString(fnStr, fnBuf.c_str(), fnBuf.size());
        fnBuf.resize(0);

        { read comment }
        cmBuf.resize(0);
        dec.readComment(cmBuf);
        cmStr := '';
        if cmBuf.size() > 0 then
          SetString(cmStr, cmBuf.c_str(), cmBuf.size());

        { ---- detect JIDAC journaling block ----
          filename: exactly 28 chars, starts "jDC"
          comment:  last 4 bytes = 'j','D','C',#1              }
        cmLen := Length(cmStr);
        if (cmLen >= 4) and
           (Length(fnStr) = 28) and
           (fnStr[1] = 'j') and (fnStr[2] = 'D') and (fnStr[3] = 'C') and
           (cmStr[cmLen-3] = 'j') and   { 4th byte from end }
           (cmStr[cmLen-2] = 'D') and   { 3rd byte from end }
           (cmStr[cmLen-1] = 'C') and   { 2nd byte from end }
           (Ord(cmStr[cmLen]) = 1) then { last byte = chr(1) }
        begin
          { --- extract fragment start number from filename[19..28] --- }
          num := 0;
          for i := 19 to 28 do begin
            ch := fnStr[i];
            if (ch >= '0') and (ch <= '9') then
              num := num * 10 + (Ord(ch) - Ord('0'));
          end;
          blockType := fnStr[18];   { 'c', 'd', 'h', or 'i' }

          FIsJournaling := True;

          if blockType in ['c','h','i'] then begin
            { decompress index/control block into memBuf }
            memOut.reset();
            dec.decompress(-1);
            dec.readSegmentEnd(nil);

            { -- 'c': transaction header -- }
            if blockType = 'c' then begin
              if memBuf.Size >= 8 then begin
                s   := PAnsiChar(memBuf.Memory);
                jmp := btol(s);
                if jmp >= 0 then begin
                  dataOff := dec.getPos();
                  if jmp > 0 then begin
                    reader.seek(dataOff + jmp);
                    didSeek := True;
                  end;
                end else
                  { negative jmp = incomplete transaction, skip 'h' and 'i' }
                  //Log('ZpaqUnpacker: incomplete transaction ignored');
              end;
            end

            { -- 'h': fragment hash index -- }
            else if blockType = 'h' then begin
              if (memBuf.Size >= 4) and ((memBuf.Size - 4) mod 24 = 0) then begin
                n := Cardinal((memBuf.Size - 4) div 24);
                s := PAnsiChar(memBuf.Memory);
                bsize := btoi(s);

                { grow Fht[] to fit fragments num .. num+n-1 }
                while FhtCount <= Integer(num + n) - 1 do begin
                  if FhtCount >= Length(Fht) then
                    SetLength(Fht, Length(Fht) * 2 + 64);
                  FillChar(Fht[FhtCount], SizeOf(THTRec), 0);
                  Fht[FhtCount].usize := -1;
                  Inc(FhtCount);
                end;

                { record block position }
                if FblockCount >= Length(Fblocks) then
                  SetLength(Fblocks, Length(Fblocks) * 2 + 16);
                Fblocks[FblockCount].offset := dataOff;
                Fblocks[FblockCount].start  := Cardinal(num);
                Fblocks[FblockCount].count  := n;
                Fblocks[FblockCount].bsize  := bsize;
                Inc(FblockCount);

                { read per-fragment sha1 + usize }
                for i := 0 to Integer(n) - 1 do begin
                  if Integer(num) + i >= Length(Fht) then
                    SetLength(Fht, Integer(num) + i + 64);
                  Move(s^, Fht[num + i].sha1[0], 20);
                  Inc(s, 20);
                  Fht[num + i].usize := Integer(btoi(s));
                  if Integer(num) + i + 1 > FhtCount then
                    FhtCount := Integer(num) + i + 1;
                end;

                dataOff := dataOff + bsize;
              end;
            end

            { -- 'i': file index -- }
            else begin  { blockType = 'i' }
              p    := PAnsiChar(memBuf.Memory);
              pEnd := p + memBuf.Size;
              while p + 9 <= pEnd do begin
                date := btol(p);
                { read null-terminated filename }
                i := 0;
                while (p + i < pEnd) and (p[i] <> #0) do Inc(i);
                fnStr := '';
                if i > 0 then SetString(fnStr, p, i);
                Inc(p, i + 1);
                if p > pEnd then Break;

                if date <> 0 then begin
                  { na: attribute byte count }
                  if p + 4 > pEnd then Break;
                  na := btoi(p);
                  if p + na > pEnd then Break;
                  Inc(p, na);
                  { ni: fragment pointer count }
                  if p + 4 > pEnd then Break;
                  ni := btoi(p);
                  if p + Int64(ni) * 4 > pEnd then Break;
                  SetLength(ptrArr, ni);
                  for j := 0 to Integer(ni) - 1 do
                    ptrArr[j] := btoi(p);
                  { compute file size from fragment usizes }
                  fsize := 0;
                  for j := 0 to Integer(ni) - 1 do begin
                    fi := Integer(ptrArr[j]);
                    if (fi > 0) and (fi < FhtCount) and (Fht[fi].usize > 0) then
                      Inc(fsize, Fht[fi].usize);
                  end;
                  { add entry }
                  if FCount >= Length(FEntries) then
                    SetLength(FEntries, Length(FEntries) * 2 + 16);
                  FEntries[FCount].Name := String(fnStr);
                  FEntries[FCount].Size := fsize;
                  FEntries[FCount].Date := ZpaqDateToDateTime(date);
                  FEntries[FCount].Ptrs := Copy(ptrArr, 0, ni);
                  FEntries[FCount].Data := nil;
                  Inc(FCount);
                end;
              end; { while p+9 <= pEnd }
            end; { 'i' }

          end else begin
            { 'd' or unknown during scan — skip segment }
            dec.readSegmentEnd(nil);
          end;

        end else begin
          { ---- streaming segment ---- }
          FIsJournaling := False;
          { decompress and cache the entire segment data }
          streamMS := TMemoryStream.Create;
          memOut.FMem := streamMS;   { redirect output into fresh stream }
          dec.decompress(-1);
          dec.readSegmentEnd(nil);
          memOut.FMem := memBuf;     { restore }

          if FCount >= Length(FEntries) then
            SetLength(FEntries, Length(FEntries) * 2 + 16);
          FEntries[FCount].Name := String(fnStr);
          FEntries[FCount].Size := streamMS.Size;
          FEntries[FCount].Date := 0;
          SetLength(FEntries[FCount].Ptrs, 0);
          FEntries[FCount].Data := streamMS;  { caller frees via Destroy }
          Inc(FCount);
        end;

      end; { while findFilename }
    end; { while findBlock }

    Result := didSeek;
  finally
    cmBuf.Free;
    fnBuf.Free;
    dec.Free;
    memOut.Free;
  end;
end;

{ ------------------------------------------------------------------ }
procedure TZpaqUnpacker.ScanArchive;
var
  fs      : TFileStream;
  reader  : TReadBridge;
  memBuf  : TMemoryStream;
  dataOff : Int64;
begin
  FCount        := 0;
  FhtCount      := 1;   { index 0 is unused sentinel }
  FblockCount   := 0;
  FIsJournaling := False;
  SetLength(FEntries, 16);
  SetLength(Fht,      64);
  SetLength(Fblocks,  16);
  dataOff := 0;

  fs := TFileStream.Create(FArchiveName, fmOpenRead or fmShareDenyWrite);
  reader := TReadBridge.Create(fs, {owned=}True);  { fs freed with reader }
  memBuf := TMemoryStream.Create;
  try
    { Loop: each iteration is one scan pass with a fresh TDecompresser.
      When DoScanPass returns True a seek occurred and the decompressor's
      64 KB read-ahead is stale; we restart from the new file position. }
    while DoScanPass(reader, memBuf, dataOff) do
      { nothing — fresh decompressor created at the top of DoScanPass };
  finally
    memBuf.Free;
    reader.Free;   { also frees fs }
  end;
end;

{ ================================================================== }
{  TZpaqUnpacker – extraction helpers                                  }
{ ================================================================== }

function TZpaqUnpacker.FindBlockForFrag(fragIdx: Cardinal): Integer;
var i: Integer;
begin
  for i := 0 to FblockCount - 1 do
    if (fragIdx >= Fblocks[i].start) and
       (fragIdx <  Fblocks[i].start + Fblocks[i].count) then
      begin Result := i; Exit; end;
  Result := -1;
end;

procedure TZpaqUnpacker.DecompressJournalEntry(idx: Integer; Dest: TStream);
var
  ptrs       : array of Cardinal;
  lastBlk    : Integer;
  fs         : TFileStream;
  reader     : TReadBridge;
  dec        : TDecompresser;
  blockMS    : TMemoryStream;
  outBridge  : TWriteBridge;
  blockBuf   : TMemOutBridge;
  pi, bi, k  : Integer;
  ptr        : Cardinal;
  fragOff    : Int64;
  fragSize   : Integer;
  bytesNeeded: Int64;
begin
  ptrs    := FEntries[idx].Ptrs;
  lastBlk := -1;
  fs      := nil;
  reader  := nil;
  dec     := nil;
  blockMS := nil;
  blockBuf:= nil;
  outBridge := TWriteBridge.Create(Dest);
  try
    for pi := 0 to Length(ptrs) - 1 do begin
      ptr := ptrs[pi];
      if (ptr = 0) or (Integer(ptr) >= FhtCount) then Continue;

      bi := FindBlockForFrag(ptr);
      if bi < 0 then begin
        //Log('ZpaqUnpacker: fragment ', ptr, ' not found in any block (skipped)');
        Continue;
      end;

      { Decompress the block only when it changes }
      if bi <> lastBlk then begin
        if dec     <> nil then FreeAndNil(dec);
        if blockBuf<> nil then FreeAndNil(blockBuf);
        if blockMS <> nil then FreeAndNil(blockMS);
        if reader  <> nil then FreeAndNil(reader);   { also frees fs }
        fs := nil;

        { sum up bytes needed for this block }
        bytesNeeded := 0;
        for k := 0 to Integer(Fblocks[bi].count) - 1 do begin
          if Integer(Fblocks[bi].start) + k < FhtCount then begin
            fragSize := Fht[Fblocks[bi].start + k].usize;
            if fragSize > 0 then Inc(bytesNeeded, fragSize);
          end;
        end;

        fs      := TFileStream.Create(FArchiveName, fmOpenRead or fmShareDenyWrite);
        reader  := TReadBridge.Create(fs, {owned=}True);
        blockMS := TMemoryStream.Create;
        blockBuf:= TMemOutBridge.Create(blockMS);
        dec     := TDecompresser.Create;
        reader.seek(Fblocks[bi].offset);
        dec.setInput(reader);
        dec.setOutput(blockBuf);

        if dec.findBlock(nil) then begin
          while dec.findFilename(nil) do begin
            dec.readComment(nil);
            while (blockMS.Size < bytesNeeded) and dec.decompress(1 shl 14) do;
            if blockMS.Size >= bytesNeeded then Break;
            dec.readSegmentEnd(nil);
          end;
        end;

        lastBlk := bi;
      end;

      { write this fragment's slice to Dest }
      fragOff  := 0;
      for k := 0 to Integer(ptr - Fblocks[bi].start) - 1 do begin
        fragSize := Fht[Fblocks[bi].start + k].usize;
        if fragSize > 0 then Inc(fragOff, fragSize);
      end;
      fragSize := Fht[ptr].usize;
      if (fragSize > 0) and (blockMS <> nil) and
         (fragOff + fragSize <= blockMS.Size) then
      begin
        blockMS.Position := fragOff;
        outBridge.bwrite(PU8(PAnsiChar(blockMS.Memory) + fragOff), fragSize);
      end;
    end; { for pi }
  finally
    dec.Free;
    blockBuf.Free;
    blockMS.Free;
    if reader <> nil then reader.Free else fs.Free;  { reader owns fs }
    outBridge.Free;
  end;
end;

{ ================================================================== }
{  TZpaqUnpacker – public interface                                    }
{ ================================================================== }

constructor TZpaqUnpacker.Create(const ArchiveName: String);
begin
  inherited Create;
  if not FileExists(ArchiveName) then
    raise EFileNotFoundException.CreateFmt(
      'ZpaqUnpacker: archive not found: %s', [ArchiveName]);
  FArchiveName := ArchiveName;
  FCurrent     := -1;
  ScanArchive;
end;

destructor TZpaqUnpacker.Destroy;
var i: Integer;
begin
  { free cached streaming data }
  for i := 0 to FCount - 1 do
    if FEntries[i].Data <> nil then
      FEntries[i].Data.Free;
  inherited;
end;

procedure TZpaqUnpacker.Reset;
begin
  FCurrent := -1;
end;

function TZpaqUnpacker.NextEntry(out AName: String;
                                  out ASize: Int64;
                                  out ADate: TDateTime): Boolean;
begin
  Inc(FCurrent);
  Result := FCurrent < FCount;
  if Result then begin
    AName := FEntries[FCurrent].Name;
    ASize := FEntries[FCurrent].Size;
    ADate := FEntries[FCurrent].Date;
  end else begin
    AName := '';
    ASize := -1;
    ADate := 0;
  end;
end;

procedure TZpaqUnpacker.Extract(Dest: TStream);
begin
  if (FCurrent < 0) or (FCurrent >= FCount) then
    raise ERangeError.Create('ZpaqUnpacker.Extract: no current entry');

  if FEntries[FCurrent].Data <> nil then begin
    { streaming: copy cached data }
    FEntries[FCurrent].Data.Position := 0;
    Dest.CopyFrom(FEntries[FCurrent].Data, FEntries[FCurrent].Data.Size);
  end else begin
    { journaling: decompress on demand }
    DecompressJournalEntry(FCurrent, Dest);
  end;
end;

procedure TZpaqUnpacker.ExtractAll(const OutDir  : String;
                                    OnFilter: TZpaqFilterEvent);
var
  name    : String;
  size    : Int64;
  date    : TDateTime;
  outPath : String;
  baseDir : String;
  dir     : String;
  fs      : TFileStream;
begin
  if OutDir <> '' then
    baseDir := IncludeTrailingPathDelimiter(OutDir)
  else
    baseDir := '';

  Reset;
  while NextEntry(name, size, date) do begin
    if Assigned(OnFilter) and (not OnFilter(name, size, date)) then
      Continue;

    { build output path: strip drive/leading slashes from stored name
      but keep subdirectory structure }
    outPath := baseDir + ExtractRelativePath('', name);
    { fall back to bare filename if ExtractRelativePath returns something odd }
    if (outPath = baseDir) or (outPath = '') then
      outPath := baseDir + ExtractFileName(name);

    dir := ExtractFileDir(outPath);
    if (dir <> '') and not DirectoryExists(dir) then
      ForceDirectories(dir);

    fs := TFileStream.Create(outPath, fmCreate);
    try
      Extract(fs);
    finally
      fs.Free;
    end;
  end;
end;

end.
