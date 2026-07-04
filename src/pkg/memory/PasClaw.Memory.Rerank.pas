unit PasClaw.Memory.Rerank;

{ Local ONNX cross-encoder reranker -- the second stage of two-stage retrieval.

  Stage 1 (embeddings + FTS5, fused by RRF) returns a candidate pool cheaply.
  This reranker RE-SCORES each (query, candidate) PAIR with a cross-encoder and
  reorders by relevance -- much more precise than the bi-encoder cosine, because
  the model sees the query and the document TOGETHER.

  Reuses the same ONNX Runtime + BERT/WordPiece tokenizer as the embedder
  (LocalVector.Embedder / LocalVector.Tokenizer). The only differences from the
  bi-encoder path:
    * input is the PAIR "[CLS] query [SEP] doc [SEP]" with token_type_ids
      segmenting query (0) from doc (1);
    * the model emits `logits [1, 1]` (a single relevance score), read directly
      -- no pooling.

  Default model: cross-encoder/ms-marco-MiniLM-L-6-v2 (~90 MB, same BERT
  WordPiece tokenizer as the MiniLM embedder). bge-reranker-base is a stronger
  drop-in; bge-reranker-v2-m3 is multilingual.

  NOTE: ONNX inference (Score/Rerank) needs a loadable ONNX Runtime shared
  library (auto-provisioned on win-x64; installed by the operator elsewhere),
  exactly like the embedder. The pure tokenization / pair-encoding logic
  (EncodePair) has no such dependency and is unit-tested on its own. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Math, Classes, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Math, System.Classes, System.Generics.Collections,
{$ENDIF}
  onnxruntime_pas_api, onnxruntime,
  LocalVector.Runtime, LocalVector.Tokenizer, LocalVector.SentencePiece,
  LocalVector.Models;

type
  ERerankerError = class(Exception);

  { One reranked candidate: its original index in the input list + score. }
  TRerankHit = record
    Index: Integer;
    Score: Single;
  end;
  TRerankHits = array of TRerankHit;

  TReranker = class
  private
    FSession: TORTSession;
    FOptions: TORTSessionOptions;
    FTok: TBertTokenizer;        { WordPiece (BERT / ms-marco) path }
    FSP:  TSPUnigram;            { SentencePiece (XLM-R / bge) path }
    FSentencePiece: Boolean;
    FModelPath, FVocabPath: string;
    FDoLowerCase, FNeedsTokenTypeIds: Boolean;
    FMaxSeq: Integer;
    FLoaded: Boolean;
    procedure EnsureLoaded(AVerbose: Boolean);
  public
    { AMaxSeq caps the packed pair length -- long candidates are truncated so a
      cross-encoder that pools over one physical batch never rejects the input
      ("input is too large to process"; cf. LocalAI PR #10104).
      ASentencePiece selects the tokenizer: False = BERT WordPiece + [CLS] q
      [SEP] d [SEP] (ms-marco); True = XLM-R SentencePiece Unigram + <s> q
      </s></s> d </s> (bge-reranker). AVocabPath is vocab.txt for WordPiece, or
      a HuggingFace tokenizer.json for SentencePiece. }
    constructor Create(const AModelPath, AVocabPath: string;
      ADoLowerCase, ANeedsTokenTypeIds: Boolean; AMaxSeq: Integer = 512;
      ASentencePiece: Boolean = False);
    destructor Destroy; override;

    { Pack the cross-encoder pair into input ids + token_type_ids, truncating
      doc first (then query) to fit AMaxSeq. WordPiece: [CLS] q [SEP] d [SEP].
      SentencePiece: <s> q </s></s> d </s>. Pure -- no ONNX. }
    procedure EncodePair(const AQuery, ADoc: UnicodeString;
      out AIds, ATypeIds: TArray<Int64>);

    { Relevance score for one pair (sigmoid of the cross-encoder logit -> 0..1).
      Loads the model on first use. Requires a working ONNX Runtime. }
    function Score(const AQuery, ADoc: string): Single;

    { Score every candidate against the query and return them ordered by score
      descending (index = position in ADocs). Requires a working ONNX Runtime. }
    function Rerank(const AQuery: string; const ADocs: array of string): TRerankHits;

    property ModelPath: string read FModelPath;
  end;

const
  DEFAULT_RERANKER = 'ms-marco-minilm';

{ Registry of the built-in reranker (cross-encoder) models. Mirrors
  LocalVector.Models.FindModelSpec but for rerankers -- reuses TModelSpec so the
  existing TModelDownloader can fetch model.onnx + vocab.txt. Pooling/Dim are
  unused for a cross-encoder. }
function FindRerankerSpec(const AKey: string; out ASpec: TModelSpec): Boolean;
function RerankerKeys: string;
{ True when AKey names an XLM-RoBERTa reranker (bge-*) whose tokenizer is
  SentencePiece + tokenizer.json, not BERT WordPiece + vocab.txt. }
function RerankerIsSentencePiece(const AKey: string): Boolean;

implementation

{ ----- model registry ----- }

function MakeRSpec(const AKey, ADisplay, ASubDir, ABaseURL, AModelRel, AVocabRel: string;
  ANeedsTT, ALower: Boolean; const ASize: string): TModelSpec;
begin
  Result.Key := AKey;
  Result.DisplayName := ADisplay;
  Result.SubDir := ASubDir;
  Result.BaseURL := ABaseURL;
  Result.ModelRelURL := AModelRel;
  Result.VocabRelURL := AVocabRel;
  Result.Pooling := poCLS;            { unused for a cross-encoder }
  Result.NeedsTokenTypeIds := ANeedsTT;
  Result.DoLowerCase := ALower;
  Result.Dim := 1;                    { single logit }
  Result.SizeDesc := ASize;
end;

function RerankerIsSentencePiece(const AKey: string): Boolean;
var K: string;
begin
  K := LowerCase(Trim(AKey));
  Result := (Pos('bge-reranker', K) = 1) or (K = 'bge-rerank') or (K = 'bge-m3')
         or (Pos('jina-reranker', K) = 1) or (K = 'jina-rerank');
end;

function FindRerankerSpec(const AKey: string; out ASpec: TModelSpec): Boolean;
var
  K: string;
begin
  Result := True;
  K := LowerCase(Trim(AKey));
  if (K = 'ms-marco-minilm') or (K = 'ms-marco') or (K = 'minilm-rerank')
     or (K = 'ms-marco-minilm-l-6-v2') then
    ASpec := MakeRSpec('ms-marco-minilm', 'ms-marco-MiniLM-L-6-v2', 'ms-marco-MiniLM-L-6-v2',
      'https://huggingface.co/Xenova/ms-marco-MiniLM-L-6-v2/resolve/main/',
      'onnx/model.onnx', 'vocab.txt', True, True, '~90 MB')
  else if (K = 'ms-marco-minilm-l12') or (K = 'ms-marco-l12')
     or (K = 'ms-marco-minilm-l-12-v2') then
    ASpec := MakeRSpec('ms-marco-minilm-l12', 'ms-marco-MiniLM-L-12-v2', 'ms-marco-MiniLM-L-12-v2',
      'https://huggingface.co/Xenova/ms-marco-MiniLM-L-12-v2/resolve/main/',
      'onnx/model.onnx', 'vocab.txt', True, True, '~130 MB')
  { XLM-RoBERTa cross-encoders (SentencePiece tokenizer, no token_type_ids).
    VocabRelURL points at tokenizer.json (the downloader saves it as the
    model's vocab file; TSPUnigram loads it as JSON). int8-quantised ONNX so it
    is CPU-practical; NeedsTT=False because RoBERTa has no segment embeddings. }
  else if (K = 'bge-reranker-base') or (K = 'bge-rerank') or (K = 'bge-reranker') then
    ASpec := MakeRSpec('bge-reranker-base', 'bge-reranker-base (int8)', 'bge-reranker-base',
      'https://huggingface.co/Xenova/bge-reranker-base/resolve/main/',
      'onnx/model_int8.onnx', 'tokenizer.json', False, False, '~280 MB')
  else if (K = 'bge-reranker-v2-m3') or (K = 'bge-m3') then
    ASpec := MakeRSpec('bge-reranker-v2-m3', 'bge-reranker-v2-m3 (int8)', 'bge-reranker-v2-m3',
      'https://huggingface.co/onnx-community/bge-reranker-v2-m3/resolve/main/',
      'onnx/model_int8.onnx', 'tokenizer.json', False, False, '~570 MB')
  else if (K = 'jina-reranker-v2') or (K = 'jina-rerank')
     or (K = 'jina-reranker-v2-base-multilingual') then
    ASpec := MakeRSpec('jina-reranker-v2', 'jina-reranker-v2-base-multilingual (int8)',
      'jina-reranker-v2-base-multilingual',
      'https://huggingface.co/jinaai/jina-reranker-v2-base-multilingual/resolve/main/',
      'onnx/model_int8.onnx', 'tokenizer.json', False, False, '~270 MB')
  else
    Result := False;
end;

function RerankerKeys: string;
begin
  Result := 'ms-marco-minilm, ms-marco-minilm-l12, bge-reranker-base, ' +
            'bge-reranker-v2-m3, jina-reranker-v2';
end;

{ ----- TReranker ----- }

constructor TReranker.Create(const AModelPath, AVocabPath: string;
  ADoLowerCase, ANeedsTokenTypeIds: Boolean; AMaxSeq: Integer;
  ASentencePiece: Boolean);
begin
  inherited Create;
  FModelPath := AModelPath;
  FVocabPath := AVocabPath;
  FDoLowerCase := ADoLowerCase;
  FNeedsTokenTypeIds := ANeedsTokenTypeIds;
  FSentencePiece := ASentencePiece;
  if AMaxSeq < 8 then AMaxSeq := 8;
  FMaxSeq := AMaxSeq;
  FLoaded := False;
  if FSentencePiece then
    FSP := TSPUnigram.Create(AVocabPath)          { AVocabPath is tokenizer.json }
  else
    FTok := TBertTokenizer.Create(AVocabPath, ADoLowerCase);
end;

destructor TReranker.Destroy;
begin
  FTok.Free;
  FSP.Free;
  { TORTSession is a managed record; it releases itself. }
  inherited;
end;

procedure TReranker.EnsureLoaded(AVerbose: Boolean);
{$IFDEF MSWINDOWS}
var Path: widestring;
{$ELSE}
var Path: ansistring;
{$ENDIF}
begin
  if FLoaded then Exit;
  if not FileExists(FModelPath) then
    raise ERerankerError.CreateFmt('Reranker model not found: %s', [FModelPath]);

  { CPU-EP wiring for ONNX Runtime 1.22+ (no implicit CPU provider). Unlike the
    embedder, the reranker uses its OWN session-options object rather than the
    shared DefaultSessionOptions: both the embedder and the reranker load in the
    same process (memory_search embeds THEN reranks; a gateway serves both
    /v1/embeddings and /v1/rerank), and appending the CPU EP to the shared
    options a second time makes ORT 1.22+ fail with "Provider
    CPUExecutionProvider has already been registered." A dedicated options
    object keeps the two independent regardless of load order. }
  EnsureOrtDefaults;   { make sure DefaultEnv exists once the runtime is loaded }
  if not Assigned(FOptions.p_) then
    ThrowOnError(GetApi().CreateSessionOptions(PPOrtSessionOptions(@FOptions.p_)));
  ThrowOnError(OrtSessionOptionsAppendExecutionProvider_CPU(FOptions.p_, 1));
  {$IFDEF MSWINDOWS}
  Path := FModelPath;                          { ORTCHAR_T is wchar_t on Windows }
  FSession := TORTSession.Create(DefaultEnv, PORTCHAR_T(Path), FOptions);
  {$ELSE}
  Path := ansistring(FModelPath);              { ORTCHAR_T is char (UTF-8) on POSIX }
  FSession := TORTSession.Create(DefaultEnv, PORTCHAR_T(PAnsiChar(Path)), FOptions);
  {$ENDIF}
  FLoaded := True;
end;

procedure TReranker.EncodePair(const AQuery, ADoc: UnicodeString;
  out AIds, ATypeIds: TArray<Int64>);
begin
  { The packing lives in the tokenizer. WordPiece -> [CLS] q [SEP] d [SEP];
    SentencePiece -> <s> q </s></s> d </s>. Both carry the reranker's MaxSeq. }
  if FSentencePiece then
    FSP.EncodePair(AQuery, ADoc, FMaxSeq, AIds, ATypeIds)
  else
    FTok.EncodePair(AQuery, ADoc, FMaxSeq, AIds, ATypeIds);
end;

function TReranker.Score(const AQuery, ADoc: string): Single;
var
  Ids, TypeIds: TArray<Int64>;
  InputIds, AttnMask, SegIds: TORTTensor<Int64>;
  OutVal: TORTValue;
  OutTensor: TORTTensor<Single>;
  Inputs, Outputs: TORTNameValueList;
  I, N: Integer;
begin
  EnsureLoaded(False);
  EncodePair(UnicodeString(AQuery), UnicodeString(ADoc), Ids, TypeIds);
  N := Length(Ids);
  if N = 0 then Exit(0);

  { TORTTensor.ToValue reverses the declared shape -> declare [N,1] to hand ONNX
    a [1,N] tensor (matches the embedder). }
  InputIds := TORTTensor<Int64>.Create([N, 1]);
  AttnMask := TORTTensor<Int64>.Create([N, 1]);
  for I := 0 to N - 1 do
  begin
    InputIds.Index1[I] := Ids[I];
    AttnMask.Index1[I] := 1;
  end;
  Inputs.Add('input_ids',      InputIds.ToValue);
  Inputs.Add('attention_mask', AttnMask.ToValue);
  if FNeedsTokenTypeIds then
  begin
    SegIds := TORTTensor<Int64>.Create([N, 1]);
    for I := 0 to N - 1 do SegIds.Index1[I] := TypeIds[I];
    Inputs.Add('token_type_ids', SegIds.ToValue);
  end;

  Outputs := FSession.Run(Inputs);
  if Outputs.Count = 0 then
    raise ERerankerError.Create('Reranker returned no outputs.');
  OutVal := Outputs.Values[0];
  OutTensor := TORTTensor<Single>.FromValue(OutVal);
  { logits shape is [1,1] (or [1]) -> the relevance score is element 0. Squash
    to 0..1 so scores are comparable / interpretable. }
  Result := 1 / (1 + Exp(-OutTensor.Index1[0]));
end;

function TReranker.Rerank(const AQuery: string; const ADocs: array of string): TRerankHits;
var
  I, J: Integer;
  Tmp: TRerankHit;
begin
  SetLength(Result, Length(ADocs));
  for I := 0 to High(ADocs) do
  begin
    Result[I].Index := I;
    Result[I].Score := Score(AQuery, ADocs[I]);
  end;
  { descending by score -- insertion sort (candidate pools are small, <= a few
    dozen). }
  for I := 1 to High(Result) do
  begin
    Tmp := Result[I];
    J := I - 1;
    while (J >= 0) and (Result[J].Score < Tmp.Score) do
    begin
      Result[J + 1] := Result[J];
      Dec(J);
    end;
    Result[J + 1] := Tmp;
  end;
end;

end.
