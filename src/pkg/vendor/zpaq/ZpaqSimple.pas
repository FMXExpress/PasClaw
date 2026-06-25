unit ZpaqSimple;

{$IFDEF FPC}{$mode delphi}{$ENDIF}

//Pascal port of LIBZPAQ Version 7.15 (Aug. 17, 2016)
//Port by www.xelitan.com
//License: MIT

interface

uses Classes, SysUtils, libzpaq, ZpaqClasses;

function ZpaqCompressStreams(Infile, Outfile: TStream): Integer;
function ZpaqDecompressStreams(Infile, Outfile: TStream): Integer;

function ZpaqCompressFile(const Infilename, Outfilename: String): Integer;
function ZpaqDecompressFile(const Infilename, Outfilename: String): Integer;

function Zpaq(const Uncompressed: AnsiString): AnsiString;
function UnZpaq(const Compressed: AnsiString): AnsiString;

implementation

function ZpaqCompressStreams(Infile, Outfile: TStream): Integer;
var
  InBridge  : TReadBridge;
  OutBridge : TWriteBridge;
begin
  Result := 0;

  if (Infile = nil) or (Outfile = nil) then
  begin
    Result := -1;
    Exit;
  end;

  try
    Infile.Position := 0;
  except
    Result := -1;
    Exit;
  end;

  try
    Outfile.Position := 0;
    if Outfile is TMemoryStream then
      TMemoryStream(Outfile).Size := 0
    else if Outfile is TFileStream then
      TFileStream(Outfile).Size := 0;
  except
  end;

  InBridge := TReadBridge.Create(Infile);
  OutBridge := TWriteBridge.Create(Outfile);
  try
    try
      zpaq_compress(InBridge, OutBridge, '1', 'data', '', True);
      Outfile.Position := 0;
    except
      Result := -3;
    end;
  finally
    OutBridge.Free;
    InBridge.Free;
  end;
end;

function ZpaqDecompressStreams(Infile, Outfile: TStream): Integer;
var
  InBridge  : TReadBridge;
  OutBridge : TWriteBridge;
  Dec       : TDecompresser;
begin
  Result := 0;

  if (Infile = nil) or (Outfile = nil) then
  begin
    Result := -1;
    Exit;
  end;

  try
    Infile.Position := 0;
  except
    Result := -1;
    Exit;
  end;

  try
    Outfile.Position := 0;
    if Outfile is TMemoryStream then
      TMemoryStream(Outfile).Size := 0
    else if Outfile is TFileStream then
      TFileStream(Outfile).Size := 0;
  except
  end;

  InBridge := TReadBridge.Create(Infile);
  OutBridge := TWriteBridge.Create(Outfile);
  Dec := TDecompresser.Create;
  try
    try
      Dec.setInput(InBridge);
      Dec.setOutput(OutBridge);

      //find 1st block
      if not Dec.findBlock(nil) then
      begin
        Result := -3;
        Exit;
      end;

      //find 1st file/segment
      if not Dec.findFilename(nil) then
      begin
        Result := -3;
        Exit;
      end;

      Dec.readComment(nil);

      //unpack just the 1st segment
      while Dec.decompress(-1) do ;
      Dec.readSegmentEnd(nil);

      Outfile.Position := 0;
    except
      Result := -3;
    end;
  finally
    Dec.Free;
    OutBridge.Free;
    InBridge.Free;
  end;
end;

function ZpaqCompressFile(const Infilename, Outfilename: String): Integer;
var
  InFile: TFileStream;
  OutFile: TFileStream;
begin
  Result := 0;
  InFile := nil;
  OutFile := nil;

  try
    try
      InFile := TFileStream.Create(Infilename, fmOpenRead or fmShareDenyWrite);
    except
      Result := -1;
      Exit;
    end;

    try
      try
        OutFile := TFileStream.Create(Outfilename, fmCreate);
      except
        Result := -3;
        Exit;
      end;

      Result := ZpaqCompressStreams(InFile, OutFile);
    finally
      OutFile.Free;
    end;
  finally
    InFile.Free;
  end;
end;

function ZpaqDecompressFile(const Infilename, Outfilename: String): Integer;
var
  InFile: TFileStream;
  OutFile: TFileStream;
begin
  Result := 0;
  InFile := nil;
  OutFile := nil;

  try
    try
      InFile := TFileStream.Create(Infilename, fmOpenRead or fmShareDenyWrite);
    except
      Result := -1;
      Exit;
    end;

    try
      try
        OutFile := TFileStream.Create(Outfilename, fmCreate);
      except
        Result := -3;
        Exit;
      end;

      Result := ZpaqDecompressStreams(InFile, OutFile);
    finally
      OutFile.Free;
    end;
  finally
    InFile.Free;
  end;
end;

function Zpaq(const Uncompressed: AnsiString): AnsiString;
var
  InStream, OutStream: TMemoryStream;
begin
  Result := '';
  InStream := TMemoryStream.Create;
  OutStream := TMemoryStream.Create;
  try
    // put data in a stream
    if Length(Uncompressed) > 0 then
      InStream.WriteBuffer(Pointer(Uncompressed)^, Length(Uncompressed));
    InStream.Position := 0;

    // pack
    if ZpaqCompressStreams(InStream, OutStream) <> 0 then
      Exit;

    // stream to string
    SetLength(Result, OutStream.Size);
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(Pointer(Result)^, OutStream.Size);
    end;
  finally
    OutStream.Free;
    InStream.Free;
  end;
end;

function UnZpaq(const Compressed: AnsiString): AnsiString;
var
  InStream, OutStream: TMemoryStream;
begin
  Result := '';
  InStream := TMemoryStream.Create;
  OutStream := TMemoryStream.Create;
  try
    // string to stream
    if Length(Compressed) > 0 then
      InStream.WriteBuffer(Pointer(Compressed)^, Length(Compressed));
    InStream.Position := 0;

    // unpack
    if ZpaqDecompressStreams(InStream, OutStream) <> 0 then
      Exit;

    // stream to string
    SetLength(Result, OutStream.Size);
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(Pointer(Result)^, OutStream.Size);
    end;
  finally
    OutStream.Free;
    InStream.Free;
  end;
end;

end.
