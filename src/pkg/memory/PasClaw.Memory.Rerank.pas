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
  LocalVector.Runtime, LocalVector.Tokenizer, LocalVector.Models;

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
    FTok: TBertTokenizer;
    FModelPath, FVocabPath: string;
    FDoLowerCase, FNeedsTokenTypeIds: Boolean;
    FMaxSeq: Integer;
    FLoaded: Boolean;
    procedure EnsureLoaded(AVerbose: Boolean);
  public
    { AMaxSeq caps the packed pair length -- long candidates are truncated so a
      cross-encoder that pools over one physical batch never rejects the input
      ("input is too large to process"; cf. LocalAI PR #10104). }
    constructor Create(const AModelPath, AVocabPath: string;
      ADoLowerCase, ANeedsTokenTypeIds: Boolean; AMaxSeq: Integer = 512);
    destructor Destroy; override;

    { Pack "[CLS] query [SEP] doc [SEP]" into input ids + token_type_ids,
      truncating doc first (then query) to fit AMaxSeq. Pure -- no ONNX. }
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
  else if (K = 'bge-reranker-base') or (K = 'bge-rerank') or (K = 'bge-reranker') then
    ASpec := MakeRSpec('bge-reranker-base', 'bge-reranker-base', 'bge-reranker-base',
      'https://huggingface.co/Xenova/bge-reranker-base/resolve/main/',
      'onnx/model.onnx', 'vocab.txt', True, True, '~1.1 GB')
  else
    Result := False;
end;

function RerankerKeys: string;
begin
  Result := 'ms-marco-minilm, bge-reranker-base';
end;

{ ----- TReranker ----- }

constructor TReranker.Create(const AModelPath, AVocabPath: string;
  ADoLowerCase, ANeedsTokenTypeIds: Boolean; AMaxSeq: Integer);
begin
  inherited Create;
  FModelPath := AModelPath;
  FVocabPath := AVocabPath;
  FDoLowerCase := ADoLowerCase;
  FNeedsTokenTypeIds := ANeedsTokenTypeIds;
  if AMaxSeq < 8 then AMaxSeq := 8;
  FMaxSeq := AMaxSeq;
  FLoaded := False;
  FTok := TBertTokenizer.Create(AVocabPath, ADoLowerCase);
end;

destructor TReranker.Destroy;
begin
  FTok.Free;
  { TORTSession is a managed record; it releases itself. }
  inherited;
end;

procedure TReranker.EnsureLoaded(AVerbose: Boolean);
begin
  if FLoaded then Exit;
  if not FileExists(FModelPath) then
    raise ERerankerError.CreateFmt('Reranker model not found: %s', [FModelPath]);
  { Same CPU-EP wiring the embedder needs on ONNX Runtime 1.22+ (no implicit
    CPU provider). See LocalVector.Embedder.Load. }
  if not Assigned(DefaultSessionOptions.p_) then
    ThrowOnError(GetApi().CreateSessionOptions(PPOrtSessionOptions(@DefaultSessionOptions.p_)));
  ThrowOnError(OrtSessionOptionsAppendExecutionProvider_CPU(DefaultSessionOptions.p_, 1));
  FSession := TORTSession.Create(FModelPath);
  FLoaded := True;
end;

procedure TReranker.EncodePair(const AQuery, ADoc: UnicodeString;
  out AIds, ATypeIds: TArray<Int64>);
begin
  { The packing lives in the tokenizer (it owns BasicTokenize/WordPiece); this
    is a thin pass-through carrying the reranker's MaxSeq budget. }
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
