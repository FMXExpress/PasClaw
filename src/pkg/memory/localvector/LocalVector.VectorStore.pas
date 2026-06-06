{
  Vendored from FMXExpress/localvector (MIT licensed; LICENSE preserved
  alongside this file). Upstream commit: 0f00eece553da47e83169ddc8d72965c0dc40bcc.
  https://github.com/FMXExpress/localvector

  Modifications kept to a minimum — PasClaw uses these units verbatim
  as the in-tree implementation of the hybrid FTS5+vector memory backend
  (PasClaw.Memory.Vector). Diff against upstream for change tracking.
}

unit LocalVector.VectorStore;

{ Hybrid (FTS5 keyword + vec0 vector) store abstraction.

  IVectorStore is implemented by a portable sqlite3 backend (FPC) and a FireDAC
  backend (Delphi); CreateVectorStore returns the right one. Shared helpers here:
  chunking, FTS5 query building, and reciprocal-rank fusion. }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes, Generics.Collections;
{$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections;
{$ENDIF}

type
  TSearchMode = (smHybrid, smVector, smKeyword);

  TSearchHit = record
    Id: Int64;
    Source: string;
    ChunkIndex: Integer;
    Text: string;
    Score: Double;       // fused score (higher is better)
    VecDistance: Double; // L2 distance from the vector index, or -1
  end;
  TSearchHits = TArray<TSearchHit>;

  TIdScore = record
    Id: Int64;
    Score: Double;
  end;

  IVectorStore = interface
    ['{6F1B2C44-9A3D-4E77-B0C1-2D5E8F0A7B31}']
    procedure OpenStore(const ADbPath, AVecExtPath: string);
    { Creates the schema for a new DB, or validates model/dim against an existing
      one. }
    procedure InitSchema(ADim: Integer; const AModel: string);
    function MetaModel: string;
    function MetaDim: Integer;
    procedure BeginBatch;
    procedure CommitBatch;
    function AddChunk(const ASource: string; AChunkIndex: Integer;
      const AText: string; const AEmbedding: TArray<Single>): Int64;
    function Search(const AQueryText: string; const AQueryEmbedding: TArray<Single>;
      AMode: TSearchMode; AK: Integer): TSearchHits;
    procedure CloseStore;
  end;

function ParseSearchMode(const AStr: string; out AMode: TSearchMode): Boolean;
function SearchModeName(AMode: TSearchMode): string;

{ Splits text into chunks. AMode = 'paragraphs' (blank-line separated, default)
  or 'lines'. Trims, drops empties. }
function ChunkText(const AText: string; const AMode: string): TArray<string>;

{ Turns free text into a safe FTS5 MATCH expression: quoted terms OR-ed together.
  Returns '' when there are no usable terms. }
function BuildFtsQuery(const AText: string): string;

{ Reciprocal-rank fusion of two ranked id lists into top-AK (id, score) desc. }
function FuseRRF(const AVecIds, AFtsIds: TArray<Int64>; AK, ARrfK: Integer): TArray<TIdScore>;

{ Encodes a float32 vector as little-endian bytes (sqlite-vec compact format). }
function VectorToBytes(const AVec: TArray<Single>): TBytes;

function CreateVectorStore: IVectorStore;

implementation

uses
{$IFDEF FPC}
  LocalVector.VectorStore.Sqlite;
{$ELSE}
  {$IFDEF LV_PORTABLE_SQLITE}
  LocalVector.VectorStore.Sqlite;
  {$ELSE}
  LocalVector.VectorStore.FireDAC;
  {$ENDIF}
{$ENDIF}

function CreateVectorStore: IVectorStore;
begin
{$IFDEF FPC}
  Result := TSqliteVectorStore.Create;
{$ELSE}
  {$IFDEF LV_PORTABLE_SQLITE}
  Result := TSqliteVectorStore.Create;
  {$ELSE}
  Result := TFireDACVectorStore.Create;
  {$ENDIF}
{$ENDIF}
end;

function ParseSearchMode(const AStr: string; out AMode: TSearchMode): Boolean;
var
  S: string;
begin
  Result := True;
  S := LowerCase(Trim(AStr));
  if (S = 'hybrid') or (S = '') then AMode := smHybrid
  else if (S = 'vector') or (S = 'vec') or (S = 'semantic') then AMode := smVector
  else if (S = 'keyword') or (S = 'fts') or (S = 'bm25') or (S = 'text') then AMode := smKeyword
  else Result := False;
end;

function SearchModeName(AMode: TSearchMode): string;
begin
  case AMode of
    smHybrid:  Result := 'hybrid';
    smVector:  Result := 'vector';
    smKeyword: Result := 'keyword';
  else
    Result := '?';
  end;
end;

function ChunkText(const AText: string; const AMode: string): TArray<string>;
var
  Lines: TStringList;
  List: TList<string>;
  I: Integer;
  Cur, Ln, T: string;

  procedure Flush;
  var
    S: string;
  begin
    S := Trim(Cur);
    if S <> '' then
      List.Add(S);
    Cur := '';
  end;

begin
  List := TList<string>.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    Cur := '';
    if SameText(AMode, 'lines') then
    begin
      for I := 0 to Lines.Count - 1 do
      begin
        T := Trim(Lines[I]);
        if T <> '' then
          List.Add(T);
      end;
    end
    else // paragraphs (blank-line separated)
    begin
      for I := 0 to Lines.Count - 1 do
      begin
        Ln := Lines[I];
        if Trim(Ln) = '' then
          Flush
        else if Cur = '' then
          Cur := Ln
        else
          Cur := Cur + ' ' + Trim(Ln);
      end;
      Flush;
    end;
    Result := List.ToArray;
  finally
    Lines.Free;
    List.Free;
  end;
end;

function BuildFtsQuery(const AText: string): string;
var
  I: Integer;
  C: Char;
  Tok: string;
  SB: TStringBuilder;

  procedure Emit;
  begin
    if Tok <> '' then
    begin
      if SB.Length > 0 then
        SB.Append(' OR ');
      SB.Append('"').Append(Tok).Append('"');
      Tok := '';
    end;
  end;

begin
  SB := TStringBuilder.Create;
  try
    Tok := '';
    for I := 1 to Length(AText) do
    begin
      C := AText[I];
      if ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
         ((C >= '0') and (C <= '9')) then
        Tok := Tok + C
      else
        Emit;
    end;
    Emit;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function FuseRRF(const AVecIds, AFtsIds: TArray<Int64>; AK, ARrfK: Integer): TArray<TIdScore>;
var
  Scores: TDictionary<Int64, Double>;
  Order: TList<Int64>;
  I, J: Integer;
  Id: Int64;
  Cur: Double;
  Tmp: TIdScore;
  Arr: TArray<TIdScore>;
begin
  Scores := TDictionary<Int64, Double>.Create;
  Order := TList<Int64>.Create;
  try
    for I := 0 to High(AVecIds) do
    begin
      Id := AVecIds[I];
      if not Scores.ContainsKey(Id) then Order.Add(Id);
      if not Scores.TryGetValue(Id, Cur) then Cur := 0;
      Scores.AddOrSetValue(Id, Cur + 1.0 / (ARrfK + I + 1));
    end;
    for I := 0 to High(AFtsIds) do
    begin
      Id := AFtsIds[I];
      if not Scores.ContainsKey(Id) then Order.Add(Id);
      if not Scores.TryGetValue(Id, Cur) then Cur := 0;
      Scores.AddOrSetValue(Id, Cur + 1.0 / (ARrfK + I + 1));
    end;

    SetLength(Arr, Order.Count);
    for I := 0 to Order.Count - 1 do
    begin
      Arr[I].Id := Order[I];
      Arr[I].Score := Scores[Order[I]];
    end;

    // simple descending sort by score
    for I := 0 to High(Arr) - 1 do
      for J := 0 to High(Arr) - 1 - I do
        if Arr[J].Score < Arr[J + 1].Score then
        begin
          Tmp := Arr[J]; Arr[J] := Arr[J + 1]; Arr[J + 1] := Tmp;
        end;

    if (AK > 0) and (Length(Arr) > AK) then
      SetLength(Arr, AK);
    Result := Arr;
  finally
    Scores.Free;
    Order.Free;
  end;
end;

function VectorToBytes(const AVec: TArray<Single>): TBytes;
begin
  SetLength(Result, Length(AVec) * SizeOf(Single));
  if Length(AVec) > 0 then
    Move(AVec[0], Result[0], Length(Result));
end;

end.
