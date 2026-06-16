unit PasClaw.KB.PDF.Compat;

(*
  PasClaw.KB.PDF.Compat - cross-compiler shim for the PDF parser.

  The PDF parser (PasClaw.KB.PDF.Parser) is a near-verbatim port of the
  upstream pdftotext (https://github.com/FMXExpress/pdftotext) parser,
  which is written against the Delphi RTL (System.ZLib,
  System.RegularExpressions, System.IOUtils). This unit provides the
  small surface of those APIs the parser actually uses, routed to the
  equivalent Free Pascal units (paszlib/zstream, regexpr) when compiled
  under FPC, so the parser source compiles unchanged on both compilers:

    * InflateBytes    - raw zlib/FlateDecode inflate.
    * TRegEx / TMatch - the subset of System.RegularExpressions used.
    * TFile           - Exists / ReadAllBytes.

  Original code by Eli M (FMXExpress) - same author as PasClaw, brought
  in here at his explicit request to give the KB ingest pipeline native
  PDF support without an external dependency.
*)

{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

interface

uses
{$IFDEF FPC}
  Classes, SysUtils, RegExpr, zstream;
{$ELSE}
  System.Classes, System.SysUtils, System.ZLib;
{$ENDIF}

{$IFDEF FPC}
type
  TRegExOption = (roNone, roIgnoreCase, roMultiLine, roExplicitCapture,
                  roCompiled, roSingleLine, roIgnorePatternSpace, roNotEmpty);
  TRegExOptions = set of TRegExOption;

  TGroup = record
    Value: string;
    Index: Integer;
    Length: Integer;
    Success: Boolean;
  end;

  TGroupCollection = record
  private
    FItems: array of TGroup;
    function GetItem(AIndex: Integer): TGroup;
  public
    property Item[AIndex: Integer]: TGroup read GetItem; default;
  end;

  TMatchData = record
    Index: Integer;
    Value: string;
    Groups: array of TGroup;
  end;

  TMatch = record
  private
    FMatches: array of TMatchData;
    FIdx: Integer;
    function GetSuccess: Boolean;
    function GetIndex: Integer;
    function GetValue: string;
    function GetGroups: TGroupCollection;
  public
    function NextMatch: TMatch;
    property Success: Boolean read GetSuccess;
    property Index: Integer read GetIndex;
    property Value: string read GetValue;
    property Groups: TGroupCollection read GetGroups;
  end;

  TRegEx = record
  public
    class function Match(const Input, Pattern: string): TMatch; overload; static;
    class function Match(const Input, Pattern: string;
      Options: TRegExOptions): TMatch; overload; static;
    class function Replace(const Input, Pattern, Replacement: string): string; static;
  end;

  TFile = class
  public
    class function Exists(const Path: string): Boolean; static;
    class function ReadAllBytes(const Path: string): TBytes; static;
  end;
{$ENDIF}

function InflateBytes(const InputBytes: TBytes): TBytes;

implementation

{$IFDEF FPC}

{ TGroupCollection }

function TGroupCollection.GetItem(AIndex: Integer): TGroup;
begin
  if (AIndex >= 0) and (AIndex < Length(FItems)) then
    Result := FItems[AIndex]
  else
  begin
    Result.Value := '';
    Result.Index := 0;
    Result.Length := 0;
    Result.Success := False;
  end;
end;

{ TMatch }

function TMatch.GetSuccess: Boolean;
begin
  Result := (FIdx >= 0) and (FIdx < Length(FMatches));
end;

function TMatch.GetIndex: Integer;
begin
  if GetSuccess then
    Result := FMatches[FIdx].Index
  else
    Result := 0;
end;

function TMatch.GetValue: string;
begin
  if GetSuccess then
    Result := FMatches[FIdx].Value
  else
    Result := '';
end;

function TMatch.GetGroups: TGroupCollection;
begin
  if GetSuccess then
    Result.FItems := FMatches[FIdx].Groups
  else
    SetLength(Result.FItems, 0);
end;

function TMatch.NextMatch: TMatch;
begin
  Result.FMatches := FMatches;
  Result.FIdx := FIdx + 1;
end;

{ TRegEx }

{ FPC's regexpr operates on single-byte AnsiStrings. The parser only ever
  feeds it raw PDF bytes whose code units are all in 0..255, so we map
  UnicodeString <-> AnsiString as Latin-1 (1 byte per code unit). Independent
  of the system codepage, and keeps match positions 1:1 with the original. }
function ToLatin1(const W: string): AnsiString;
var
  I: Integer;
begin
  SetLength(Result, Length(W));
  for I := 1 to Length(W) do
    Result[I] := AnsiChar(Ord(W[I]) and $FF);
end;

function FromLatin1(const A: AnsiString): string;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 1 to Length(A) do
    Result[I] := Char(Ord(A[I]));
end;

class function TRegEx.Match(const Input, Pattern: string;
  Options: TRegExOptions): TMatch;
var
  RE: TRegExpr;
  MD: TMatchData;
  G, N: Integer;
  AInput: AnsiString;
begin
  SetLength(Result.FMatches, 0);
  Result.FIdx := 0;
  AInput := ToLatin1(Input);
  RE := TRegExpr.Create;
  try
    RE.Expression := ToLatin1(Pattern);
    RE.ModifierI := roIgnoreCase in Options;
    RE.ModifierS := True; { '.' matches newline; patterns here use [\s\S] regardless }
    if RE.Exec(AInput) then
      repeat
        MD.Index := RE.MatchPos[0];
        MD.Value := FromLatin1(RE.Match[0]);
        N := RE.SubExprMatchCount;
        SetLength(MD.Groups, N + 1);
        for G := 0 to N do
        begin
          MD.Groups[G].Value := FromLatin1(RE.Match[G]);
          MD.Groups[G].Index := RE.MatchPos[G];
          MD.Groups[G].Length := RE.MatchLen[G];
          MD.Groups[G].Success := RE.MatchPos[G] > 0;
        end;
        SetLength(Result.FMatches, Length(Result.FMatches) + 1);
        Result.FMatches[High(Result.FMatches)] := MD;
      until not RE.ExecNext;
  finally
    RE.Free;
  end;
end;

class function TRegEx.Match(const Input, Pattern: string): TMatch;
begin
  Result := Match(Input, Pattern, []);
end;

class function TRegEx.Replace(const Input, Pattern, Replacement: string): string;
var
  RE: TRegExpr;
begin
  RE := TRegExpr.Create;
  try
    RE.Expression := ToLatin1(Pattern);
    Result := FromLatin1(RE.Replace(ToLatin1(Input), ToLatin1(Replacement), False));
  finally
    RE.Free;
  end;
end;

{ TFile }

class function TFile.Exists(const Path: string): Boolean;
begin
  Result := FileExists(Path);
end;

class function TFile.ReadAllBytes(const Path: string): TBytes;
var
  FS: TFileStream;
begin
  SetLength(Result, 0);
  FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Result[0], FS.Size);
  finally
    FS.Free;
  end;
end;

{ InflateBytes - FPC (paszlib/zstream) }

function InflateBytes(const InputBytes: TBytes): TBytes;
var
  Input, Output: TMemoryStream;
  Decompressor: Tdecompressionstream;
  Buffer: array[0..4095] of Byte;
  BytesRead: Integer;
begin
  SetLength(Result, 0);
  if Length(InputBytes) = 0 then Exit;

  Input := TMemoryStream.Create;
  Output := TMemoryStream.Create;
  try
    Input.WriteBuffer(InputBytes[0], Length(InputBytes));
    Input.Position := 0;
    try
      Decompressor := Tdecompressionstream.Create(Input);
      try
        repeat
          BytesRead := Decompressor.Read(Buffer[0], Length(Buffer));
          if BytesRead > 0 then
            Output.WriteBuffer(Buffer[0], BytesRead);
        until BytesRead = 0;
      finally
        Decompressor.Free;
      end;
      SetLength(Result, Output.Size);
      if Output.Size > 0 then
        Move(Output.Memory^, Result[0], Output.Size);
    except
      SetLength(Result, 0);
    end;
  finally
    Input.Free;
    Output.Free;
  end;
end;

{$ELSE}

{ InflateBytes - Delphi (System.ZLib) }

function InflateBytes(const InputBytes: TBytes): TBytes;
var
  Input, Output: TMemoryStream;
  Decompressor: TZDecompressionStream;
  Buffer: array[0..4095] of Byte;
  BytesRead: Integer;
begin
  SetLength(Result, 0);
  if Length(InputBytes) = 0 then Exit;

  Input := TMemoryStream.Create;
  Output := TMemoryStream.Create;
  try
    Input.WriteBuffer(InputBytes[0], Length(InputBytes));
    Input.Position := 0;
    try
      Decompressor := TZDecompressionStream.Create(Input);
      try
        repeat
          BytesRead := Decompressor.Read(Buffer[0], Length(Buffer));
          if BytesRead > 0 then
            Output.WriteBuffer(Buffer[0], BytesRead);
        until BytesRead = 0;
      finally
        Decompressor.Free;
      end;
      SetLength(Result, Output.Size);
      if Output.Size > 0 then
        Move(Output.Memory^, Result[0], Output.Size);
    except
      SetLength(Result, 0);
    end;
  finally
    Input.Free;
    Output.Free;
  end;
end;

{$ENDIF}

end.
