unit LocalVector.SentencePiece;

{ SentencePiece **Unigram** tokenizer for XLM-RoBERTa-family cross-encoders
  (bge-reranker-base / -large / -v2-m3). This is a different algorithm from the
  BERT WordPiece path in LocalVector.Tokenizer:

    * vocabulary is a list of (piece, log-prob score); tokenization is the
      max-score segmentation found by Viterbi over that unigram language model
      (not greedy longest-match subword);
    * whitespace is turned into the meta symbol U+2581 ("lower one eighth
      block", the SentencePiece space marker) and a leading U+2581 is prepended
      (HuggingFace Metaspace, prepend_scheme = "always");
    * the cross-encoder pair input is RoBERTa-style
      `<s> query </s></s> passage </s>` with token_type_ids all 0 (XLM-R has
      no segment embeddings), NOT BERT's `[CLS] q [SEP] d [SEP]` with
      token_type_ids 0/1.

  The vocabulary + specials are loaded from the model's HuggingFace
  `tokenizer.json` (the `model.vocab` array). A targeted scanner reads just that
  array rather than building a full 250k-node JSON DOM.

  LIMITATION: XLM-R's `Precompiled` normalizer (an NFKC-ish compiled charmap) is
  NOT reproduced -- only the trivial "collapse runs of spaces" step is applied.
  For ASCII / common Latin text (the retrieval / code case) this matches the
  reference tokenizer exactly; text needing NFKC folding (some CJK width
  variants, exotic compatibility characters) may tokenize slightly differently.
  Validated against HuggingFace `tokenizers` on ASCII + accented Latin. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes, Math, Generics.Collections;
{$ELSE}
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections;
{$ENDIF}

type
  ESentencePieceError = class(Exception);

  TSPUnigram = class
  private
    FPieceToId: TDictionary<UnicodeString, Integer>;
    FScores:    array of Single;      { score by id }
    FMinScore:  Single;
    FMaxLen:    Integer;              { longest piece, in UTF-16 code units }
    FBosId, FEosId, FPadId, FUnkId: Integer;
    procedure LoadFromTokenizerJson(const AJsonText: string);
    function EncodePieceIds(const ANorm: UnicodeString): TArray<Integer>;
  public
    { Load the unigram model from a HuggingFace tokenizer.json (or a file whose
      bytes are that JSON, whatever it is named on disk). }
    constructor Create(const ATokenizerJsonPath: string);
    destructor Destroy; override;

    { Normalise + metaspace + Viterbi-encode a single string to piece ids
      (NO special tokens). Public for testing. }
    function Encode(const AText: UnicodeString): TArray<Integer>;

    { Cross-encoder pair packing: <s> A </s></s> B </s>, truncated to AMaxLen
      (query capped at half, passage truncated first), with token_type_ids all
      0. Mirrors TBertTokenizer.EncodePair's budget logic. }
    procedure EncodePair(const AQuery, ADoc: UnicodeString; AMaxLen: Integer;
      out AIds, ATypeIds: TArray<Int64>);

    property BosId: Integer read FBosId;
    property EosId: Integer read FEosId;
    property UnkId: Integer read FUnkId;
    property VocabSize: Integer read FMaxLen;   { not size; see Count below }
    function Count: Integer;
  end;

{ JSON-unescape a raw tokenizer.json string token body (already decoded to
  UTF-16, between the quotes): processes \uXXXX (surrogate halves emitted
  verbatim so a pair reforms), \n \t \r \" \\ \/ \b \f; literal characters
  (incl. multi-byte UTF-8 that was decoded to real code points) pass through
  untouched. Exposed for testing. }
function JsonUnescape(const ARaw: UnicodeString): UnicodeString;

implementation

{ ----- JSON string unescape ----- }

function HexVal(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
  else Result := 0;
  end;
end;

function JsonUnescape(const ARaw: UnicodeString): UnicodeString;
var
  i, n: Integer;
  cp: Integer;
begin
  Result := '';
  i := 1; n := Length(ARaw);
  while i <= n do
  begin
    if (ARaw[i] = '\') and (i < n) then
    begin
      case ARaw[i + 1] of
        'n': begin Result := Result + #10; Inc(i, 2); end;
        't': begin Result := Result + #9;  Inc(i, 2); end;
        'r': begin Result := Result + #13; Inc(i, 2); end;
        'b': begin Result := Result + #8;  Inc(i, 2); end;
        'f': begin Result := Result + #12; Inc(i, 2); end;
        '"': begin Result := Result + '"'; Inc(i, 2); end;
        '\': begin Result := Result + '\'; Inc(i, 2); end;
        '/': begin Result := Result + '/'; Inc(i, 2); end;
        'u':
          begin
            if i + 5 <= n then
            begin
              cp := (HexVal(Char(ARaw[i+2])) shl 12) or (HexVal(Char(ARaw[i+3])) shl 8)
                 or (HexVal(Char(ARaw[i+4])) shl 4) or HexVal(Char(ARaw[i+5]));
              Result := Result + WideChar(cp);   { surrogate halves pass through as-is }
              Inc(i, 6);
            end
            else Inc(i, 2);
          end;
      else
        begin Result := Result + ARaw[i + 1]; Inc(i, 2); end;
      end;
    end
    else
    begin
      Result := Result + ARaw[i];   { literal (already-decoded) code unit }
      Inc(i);
    end;
  end;
end;

{ ----- TSPUnigram ----- }

constructor TSPUnigram.Create(const ATokenizerJsonPath: string);
var
  SL: TStringList;
  Txt: string;
begin
  inherited Create;
  FPieceToId := TDictionary<UnicodeString, Integer>.Create;
  FBosId := 0; FPadId := 1; FEosId := 2; FUnkId := 3;   { XLM-R defaults }
  FMaxLen := 1; FMinScore := 0;
  if not FileExists(ATokenizerJsonPath) then
    raise ESentencePieceError.CreateFmt('tokenizer.json not found: %s', [ATokenizerJsonPath]);
  SL := TStringList.Create;
  try
    { PasClaw modification: read as UTF-8 explicitly. Without an encoding,
      Delphi's LoadFromFile decodes a BOM-less tokenizer.json as the ANSI
      codepage, which corrupts every non-ASCII vocab entry -- the CJK
      pieces in particular, for the users most likely to need them. FPC
      passed the bytes through untouched, so this only ever bit the
      Delphi build. RTL overload rather than PasClaw.Utils so the vendored
      unit stays free of app dependencies. }
    SL.LoadFromFile(ATokenizerJsonPath, TEncoding.UTF8);
    Txt := SL.Text;
  finally
    SL.Free;
  end;
  LoadFromTokenizerJson(Txt);
  if FPieceToId.Count = 0 then
    raise ESentencePieceError.Create('tokenizer.json has no unigram vocab');
end;

destructor TSPUnigram.Destroy;
begin
  FPieceToId.Free;
  inherited;
end;

function TSPUnigram.Count: Integer;
begin
  Result := FPieceToId.Count;
end;

procedure TSPUnigram.LoadFromTokenizerJson(const AJsonText: string);
{ Scan for "vocab":[ ... ] inside the model object and read each ["piece",score]
  entry. Bytes in AJsonText are UTF-8 (raw file); JsonUnescape turns the escaped
  token body into UTF-16, and non-escaped multi-byte UTF-8 is decoded up front. }
var
  Uni: UnicodeString;
  s: string;
  p, vstart, n, id: Integer;
  ch: WideChar;
  piece: UnicodeString;
  scoreStr: string;
  sc: Single;
  fs: TFormatSettings;

  function FindVocabArray(const U: UnicodeString): Integer;
  var q: Integer;
  begin
    { locate the '[' that opens "vocab": [ ... }
    q := Pos(UnicodeString('"vocab"'), U);
    Result := 0;
    if q = 0 then Exit;
    Inc(q, Length('"vocab"'));
    while (q <= Length(U)) and (U[q] <> '[') do Inc(q);
    Result := q;   { position of '[' }
  end;

begin
  { Decode the whole file (UTF-8) to UTF-16 once so codepoint handling is
    uniform. FPC: assigning AnsiString(UTF8) -> UnicodeString decodes via the
    active code page (UTF8 in this unit). }
  {$IFDEF FPC}
  Uni := UTF8Decode(AJsonText);
  {$ELSE}
  Uni := UnicodeString(AJsonText);
  {$ENDIF}
  s := '';   { silence hint }
  if s = '' then ;

  fs := {$IFDEF FPC}DefaultFormatSettings{$ELSE}TFormatSettings.Invariant{$ENDIF};
  fs.DecimalSeparator := '.';

  p := FindVocabArray(Uni);
  if p = 0 then Exit;
  n := Length(Uni);
  id := 0;
  Inc(p);   { step past '[' }

  while p <= n do
  begin
    { skip whitespace / commas }
    while (p <= n) and ((Uni[p] = ' ') or (Uni[p] = #10) or (Uni[p] = #13)
          or (Uni[p] = #9) or (Uni[p] = ',')) do Inc(p);
    if (p > n) or (Uni[p] = ']') then Break;
    if Uni[p] <> '[' then Break;      { not an entry -> stop }
    Inc(p);                            { past entry '[' }
    { expect a quoted string: "piece" }
    while (p <= n) and (Uni[p] <> '"') do Inc(p);
    if p > n then Break;
    Inc(p);                            { past opening quote }
    vstart := p;
    while (p <= n) do
    begin
      ch := Uni[p];
      if ch = '\' then Inc(p, 2)       { skip escaped pair }
      else if ch = '"' then Break
      else Inc(p);
    end;
    piece := JsonUnescape(Copy(Uni, vstart, p - vstart));
    Inc(p);                            { past closing quote }
    { comma then score number }
    while (p <= n) and (Uni[p] <> ',') do Inc(p);
    Inc(p);
    while (p <= n) and ((Uni[p] = ' ') or (Uni[p] = #9)) do Inc(p);
    scoreStr := '';
    while (p <= n) and (Uni[p] <> ']') do
    begin
      scoreStr := scoreStr + Char(Uni[p]);
      Inc(p);
    end;
    Inc(p);                            { past entry ']' }

    sc := StrToFloatDef(Trim(scoreStr), 0, fs);
    if not FPieceToId.ContainsKey(piece) then
      FPieceToId.AddOrSetValue(piece, id);
    if Length(FScores) <= id then SetLength(FScores, id + 1024);
    FScores[id] := sc;
    if sc < FMinScore then FMinScore := sc;
    if Length(piece) > FMaxLen then FMaxLen := Length(piece);
    Inc(id);
  end;
  SetLength(FScores, id);
end;

function TSPUnigram.EncodePieceIds(const ANorm: UnicodeString): TArray<Integer>;
{ Viterbi max-score segmentation of ANorm over the unigram vocab. Positions with
  no vocab piece fall back to a single-codepoint <unk> edge scored just below the
  worst real piece, so unk is only taken when nothing else fits. }
var
  N, i, L, clen: Integer;
  best: array of Single;
  backLen: array of Integer;   { length (code units) of the edge landing at i }
  backId:  array of Integer;   { piece id of that edge }
  sub: UnicodeString;
  pid: Integer;
  cand, unkPenalty: Single;
  segLen: array of Integer;
  segId:  array of Integer;
  cnt, pos: Integer;
begin
  Result := nil;
  N := Length(ANorm);
  if N = 0 then Exit;
  SetLength(best, N + 1);
  SetLength(backLen, N + 1);
  SetLength(backId, N + 1);
  for i := 0 to N do begin best[i] := -1e30; backLen[i] := 0; backId[i] := -1; end;
  best[0] := 0;
  unkPenalty := FMinScore - 10.0;

  for i := 1 to N do
  begin
    { real pieces ending at i, length 1..FMaxLen }
    for L := 1 to Min(FMaxLen, i) do
    begin
      if best[i - L] <= -1e29 then Continue;
      sub := Copy(ANorm, i - L + 1, L);
      if FPieceToId.TryGetValue(sub, pid) then
      begin
        cand := best[i - L] + FScores[pid];
        if cand > best[i] then
        begin best[i] := cand; backLen[i] := L; backId[i] := pid; end;
      end;
    end;
    { unk fallback for one codepoint (2 code units if a surrogate pair) }
    clen := 1;
    if (i >= 2) and (Ord(ANorm[i]) >= $DC00) and (Ord(ANorm[i]) <= $DFFF)
       and (Ord(ANorm[i-1]) >= $D800) and (Ord(ANorm[i-1]) <= $DBFF) then clen := 2;
    if best[i - clen] > -1e29 then
    begin
      cand := best[i - clen] + unkPenalty;
      if cand > best[i] then
      begin best[i] := cand; backLen[i] := clen; backId[i] := FUnkId; end;
    end;
  end;

  { backtrack }
  SetLength(segLen, N); SetLength(segId, N); cnt := 0; pos := N;
  while pos > 0 do
  begin
    if backLen[pos] = 0 then begin backLen[pos] := 1; backId[pos] := FUnkId; end;
    segLen[cnt] := backLen[pos]; segId[cnt] := backId[pos];
    pos := pos - backLen[pos]; Inc(cnt);
  end;
  SetLength(Result, cnt);
  for i := 0 to cnt - 1 do Result[i] := segId[cnt - 1 - i];   { reverse }
end;

function TSPUnigram.Encode(const AText: UnicodeString): TArray<Integer>;
const
  MARK = WideChar($2581);   { U+2581 lower one eighth block (SentencePiece space) }
var
  s: UnicodeString;
  i: Integer;
  mspaced: UnicodeString;
begin
  { normalise: collapse runs of 2+ ASCII spaces to one (XLM-R's space-run Replace) }
  s := '';
  i := 1;
  while i <= Length(AText) do
  begin
    if AText[i] = ' ' then
    begin
      s := s + ' ';
      while (i <= Length(AText)) and (AText[i] = ' ') do Inc(i);
    end
    else begin s := s + AText[i]; Inc(i); end;
  end;
  { metaspace: prepend U+2581, replace spaces with U+2581 (prepend_scheme=always) }
  mspaced := MARK;
  for i := 1 to Length(s) do
    if s[i] = ' ' then mspaced := mspaced + MARK else mspaced := mspaced + s[i];
  Result := EncodePieceIds(mspaced);
end;

procedure TSPUnigram.EncodePair(const AQuery, ADoc: UnicodeString; AMaxLen: Integer;
  out AIds, ATypeIds: TArray<Int64>);
var
  q, d: TArray<Integer>;
  budget, qcap, i, k: Integer;
begin
  q := Encode(AQuery);
  d := Encode(ADoc);
  { specials used: <s> ... </s></s> ... </s>  == 4 special slots }
  if AMaxLen < 5 then AMaxLen := 5;
  budget := AMaxLen - 4;
  if budget < 2 then budget := 2;
  qcap := budget div 2;
  if Length(q) > qcap then SetLength(q, qcap);
  if Length(d) > (budget - Length(q)) then SetLength(d, budget - Length(q));

  SetLength(AIds, 0); SetLength(ATypeIds, 0);
  k := 2 + Length(q) + Length(d) + 2;   { <s> q </s> </s> d </s> }
  SetLength(AIds, k); SetLength(ATypeIds, k);
  i := 0;
  AIds[i] := FBosId; Inc(i);
  for k := 0 to High(q) do begin AIds[i] := q[k]; Inc(i); end;
  AIds[i] := FEosId; Inc(i);
  AIds[i] := FEosId; Inc(i);
  for k := 0 to High(d) do begin AIds[i] := d[k]; Inc(i); end;
  AIds[i] := FEosId; Inc(i);
  { XLM-R: token_type_ids are all 0 }
  for k := 0 to High(ATypeIds) do ATypeIds[k] := 0;
end;

end.
