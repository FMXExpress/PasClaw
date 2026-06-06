{
  Vendored from FMXExpress/localvector (MIT licensed; LICENSE preserved
  alongside this file). Upstream commit: 0f00eece553da47e83169ddc8d72965c0dc40bcc.
  https://github.com/FMXExpress/localvector

  Modifications kept to a minimum — PasClaw uses these units verbatim
  as the in-tree implementation of the hybrid FTS5+vector memory backend
  (PasClaw.Memory.Vector). Diff against upstream for change tracking.
}

unit LocalVector.Tokenizer;

{ A self-contained BERT (WordPiece) tokenizer that reads a plain vocab.txt
  (one token per line; line index = token id). This is all that all-MiniLM-L6-v2
  needs, and avoids any dependency on regex / JSON units so the unit compiles
  cleanly under both Delphi and Free Pascal.

  The pipeline mirrors Hugging Face's BertTokenizer:
    BasicTokenizer  -> clean text, (lowercase), split on whitespace & punctuation,
                       isolate CJK characters.
    WordpieceTokenizer -> greedy longest-match-first using "##" continuations,
                       falling back to [UNK] for an unmatchable word.
  The result is wrapped with [CLS] ... [SEP] and truncated to the model limit. }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes, Generics.Collections;
{$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections;
{$ENDIF}

type
  ETokenizerError = class(Exception);

  TBertTokenizer = class
  private
    FVocab: TDictionary<UnicodeString, Integer>;
    FDoLowerCase: Boolean;
    FMaxCharsPerWord: Integer;
    FClsId, FSepId, FUnkId, FPadId: Integer;
    procedure LoadVocab(const AVocabPath: string);
    function LookupSpecial(const AToken: UnicodeString): Integer;
    function BasicTokenize(const AText: UnicodeString): TArray<UnicodeString>;
    procedure WordPiece(const AWord: UnicodeString; AOut: TList<Int64>);
  public
    constructor Create(const AVocabPath: string; ADoLowerCase: Boolean = True);
    destructor Destroy; override;
    { Encode text into BERT input ids, including [CLS]/[SEP], truncated so the
      whole sequence is at most AMaxLen tokens. }
    function Encode(const AText: UnicodeString; AMaxLen: Integer = 256): TArray<Int64>;
    property ClsId: Integer read FClsId;
    property SepId: Integer read FSepId;
    property UnkId: Integer read FUnkId;
    property PadId: Integer read FPadId;
  end;

implementation

const
  UNI_HASH: UnicodeString = '##';

{ ---- character classification (operate on a single UTF-16 code unit) ---- }

function IsWhitespaceCp(C: WideChar): Boolean;
var V: Word;
begin
  V := Ord(C);
  case V of
    $09, $0A, $0D, $20, $A0, $1680,
    $2000..$200A, $2028, $2029, $202F, $205F, $3000:
      Result := True;
  else
    Result := False;
  end;
end;

function IsControlCp(C: WideChar): Boolean;
var V: Word;
begin
  V := Ord(C);
  // Tab/newline/CR are handled as whitespace, never as control.
  if (V = $09) or (V = $0A) or (V = $0D) then
    Exit(False);
  Result := (V < $20) or ((V >= $7F) and (V <= $9F));
end;

function IsPunctuationCp(C: WideChar): Boolean;
var V: Word;
begin
  V := Ord(C);
  // BERT treats all ASCII non-alphanumeric/non-space as punctuation, plus the
  // common Unicode punctuation blocks.
  Result :=
    ((V >= 33) and (V <= 47))  or ((V >= 58) and (V <= 64))  or
    ((V >= 91) and (V <= 96))  or ((V >= 123) and (V <= 126)) or
    ((V >= $2000) and (V <= $206F)) or  // General Punctuation
    ((V >= $3000) and (V <= $303F)) or  // CJK Symbols and Punctuation
    ((V >= $FF00) and (V <= $FF0F)) or
    ((V >= $FF1A) and (V <= $FF20)) or
    ((V >= $FF3B) and (V <= $FF40)) or
    ((V >= $FF5B) and (V <= $FF65));
end;

function IsCJKCp(C: WideChar): Boolean;
var V: Word;
begin
  V := Ord(C);
  Result :=
    ((V >= $3400) and (V <= $4DBF)) or
    ((V >= $4E00) and (V <= $9FFF)) or
    ((V >= $F900) and (V <= $FAFF));
end;

function ToLowerCp(C: WideChar): WideChar;
var V: Word;
begin
  V := Ord(C);
  if (V >= Ord('A')) and (V <= Ord('Z')) then
    Result := WideChar(V + 32)
  else if (V >= $C0) and (V <= $DE) and (V <> $D7) then
    // Latin-1 Supplement uppercase -> lowercase (covers common accented forms).
    Result := WideChar(V + 32)
  else
    Result := C;
end;

{ ---- file helpers ---- }

function ReadAllBytesLV(const APath: string): TBytes;
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Result[0], FS.Size);
  finally
    FS.Free;
  end;
end;

{ ---- TBertTokenizer ---- }

constructor TBertTokenizer.Create(const AVocabPath: string; ADoLowerCase: Boolean);
begin
  inherited Create;
  if not FileExists(AVocabPath) then
    raise ETokenizerError.CreateFmt('vocab.txt not found: %s', [AVocabPath]);

  FVocab := TDictionary<UnicodeString, Integer>.Create;
  FDoLowerCase := ADoLowerCase;
  FMaxCharsPerWord := 100;

  LoadVocab(AVocabPath);

  FClsId := LookupSpecial('[CLS]');
  FSepId := LookupSpecial('[SEP]');
  FUnkId := LookupSpecial('[UNK]');
  FPadId := LookupSpecial('[PAD]');

  if (FClsId < 0) or (FSepId < 0) or (FUnkId < 0) then
    raise ETokenizerError.Create(
      'vocab.txt is missing required special tokens ([CLS]/[SEP]/[UNK]).');
end;

destructor TBertTokenizer.Destroy;
begin
  FVocab.Free;
  inherited;
end;

function TBertTokenizer.LookupSpecial(const AToken: UnicodeString): Integer;
begin
  if not FVocab.TryGetValue(AToken, Result) then
    Result := -1;
end;

procedure TBertTokenizer.LoadVocab(const AVocabPath: string);
var
  Bytes: TBytes;
  Content: UnicodeString;
  I, LineStart, Id: Integer;
  Token: UnicodeString;

  procedure CommitLine(const ARawLine: UnicodeString);
  var
    T: UnicodeString;
    L: Integer;
  begin
    T := ARawLine;
    // strip a trailing CR (vocab.txt may be CRLF)
    L := Length(T);
    if (L > 0) and (T[L] = #13) then
      Delete(T, L, 1);
    // The very last "line" may be empty due to a trailing newline -> skip it,
    // but still consume the id slot only for real tokens.
    if T <> '' then
      FVocab.AddOrSetValue(T, Id);
    Inc(Id);
  end;

begin
  Bytes := ReadAllBytesLV(AVocabPath);
  Content := TEncoding.UTF8.GetString(Bytes);

  Id := 0;
  LineStart := 1;
  for I := 1 to Length(Content) do
  begin
    if Content[I] = #10 then
    begin
      Token := Copy(Content, LineStart, I - LineStart);
      CommitLine(Token);
      LineStart := I + 1;
    end;
  end;
  if LineStart <= Length(Content) then
    CommitLine(Copy(Content, LineStart, Length(Content) - LineStart + 1));

  if FVocab.Count = 0 then
    raise ETokenizerError.CreateFmt('vocab.txt appears empty: %s', [AVocabPath]);
end;

function TBertTokenizer.BasicTokenize(const AText: UnicodeString): TArray<UnicodeString>;
var
  Seg: UnicodeString;
  I: Integer;
  C: WideChar;
  Words: TList<UnicodeString>;
  W, Cur, PunctStr: UnicodeString;
  J, RStart: Integer;
begin
  // Pass 1: clean + segment. Drop control chars, collapse whitespace to a
  // single space, and surround CJK characters with spaces so each becomes its
  // own token.
  Seg := '';
  for I := 1 to Length(AText) do
  begin
    C := AText[I];
    if (Ord(C) = 0) or (Ord(C) = $FFFD) or IsControlCp(C) then
      Continue
    else if IsWhitespaceCp(C) then
      Seg := Seg + ' '
    else if IsCJKCp(C) then
      Seg := Seg + ' ' + C + ' '
    else
      Seg := Seg + C;
  end;

  Words := TList<UnicodeString>.Create;
  try
    // Pass 2: split on spaces; for each whitespace word, lowercase then split
    // punctuation into standalone tokens.
    RStart := 1;
    for J := 1 to Length(Seg) + 1 do
    begin
      if (J > Length(Seg)) or (Seg[J] = ' ') then
      begin
        if J > RStart then
        begin
          W := Copy(Seg, RStart, J - RStart);

          Cur := '';
          for I := 1 to Length(W) do
          begin
            C := W[I];
            if FDoLowerCase then
              C := ToLowerCp(C);
            if IsPunctuationCp(C) then
            begin
              if Cur <> '' then
              begin
                Words.Add(Cur);
                Cur := '';
              end;
              PunctStr := C; // WideChar -> 1-char UnicodeString
              Words.Add(PunctStr);
            end
            else
              Cur := Cur + C;
          end;
          if Cur <> '' then
            Words.Add(Cur);
        end;
        RStart := J + 1;
      end;
    end;

    Result := Words.ToArray;
  finally
    Words.Free;
  end;
end;

procedure TBertTokenizer.WordPiece(const AWord: UnicodeString; AOut: TList<Int64>);
var
  N, StartI, EndI, Id: Integer;
  Found, BadWord: Boolean;
  Sub, Key: UnicodeString;
  SubIds: TList<Int64>;
  K: Integer;
begin
  N := Length(AWord);
  if N = 0 then
    Exit;
  if N > FMaxCharsPerWord then
  begin
    AOut.Add(FUnkId);
    Exit;
  end;

  SubIds := TList<Int64>.Create;
  try
    StartI := 1;
    BadWord := False;
    while StartI <= N do
    begin
      EndI := N;
      Found := False;
      Id := -1;
      while StartI <= EndI do
      begin
        Sub := Copy(AWord, StartI, EndI - StartI + 1);
        if StartI > 1 then
          Key := UNI_HASH + Sub
        else
          Key := Sub;
        if FVocab.TryGetValue(Key, Id) then
        begin
          Found := True;
          Break;
        end;
        Dec(EndI);
      end;
      if not Found then
      begin
        BadWord := True;
        Break;
      end;
      SubIds.Add(Id);
      StartI := EndI + 1;
    end;

    if BadWord then
      AOut.Add(FUnkId)
    else
      for K := 0 to SubIds.Count - 1 do
        AOut.Add(SubIds[K]);
  finally
    SubIds.Free;
  end;
end;

function TBertTokenizer.Encode(const AText: UnicodeString; AMaxLen: Integer): TArray<Int64>;
var
  Words: TArray<UnicodeString>;
  Ids: TList<Int64>;
  I, ContentMax: Integer;
begin
  Ids := TList<Int64>.Create;
  try
    Words := BasicTokenize(AText);
    for I := 0 to High(Words) do
      WordPiece(Words[I], Ids);

    // Leave room for [CLS] and [SEP].
    ContentMax := AMaxLen - 2;
    if ContentMax < 0 then
      ContentMax := 0;
    while Ids.Count > ContentMax do
      Ids.Delete(Ids.Count - 1);

    Ids.Insert(0, FClsId);
    Ids.Add(FSepId);

    Result := Ids.ToArray;
  finally
    Ids.Free;
  end;
end;

end.
