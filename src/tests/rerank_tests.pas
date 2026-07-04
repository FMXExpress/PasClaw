program rerank_tests;
(*
  Unit tests for the ONNX-INDEPENDENT parts of PasClaw.Memory.Rerank:
    * the reranker model registry (FindRerankerSpec);
    * EncodePair -- the "[CLS] query [SEP] doc [SEP]" packing + token_type_ids
      segmentation + truncation-to-fit.

  Live cross-encoder scoring (Score/Rerank) needs a loadable ONNX Runtime and a
  real model, so it is NOT exercised here -- it is validated on an ORT-equipped
  machine. EncodePair is the tricky pure logic and is fully covered.

  Uses a tiny hand-built vocab so no model download / ONNX runtime is required.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  LocalVector.Models,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types,
  PasClaw.Memory.Rerank,
  PasClaw.Memory.Rerank.Serve,
  PasClaw.Memory.Rerank.LLM;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure IsTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure EqI(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Msg + Format(' (got %d want %d)', [Got, Want])); end;

type
  { Canned-response provider so LLMRerank can be exercised without a network
    call: it echoes a fixed Content + StatusCode, the way a real provider
    returns a ranking (or an error string) from Chat. }
  TFakeProvider = class(TInterfacedObject, ILLMProvider)
  private
    FContent: string;
    FStatus:  Integer;
  public
    constructor Create(const AContent: string; AStatus: Integer);
    function Chat(const Messages: array of TMessage; const Tools: array of TToolDefinition;
      const Model: string; const Options: TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage; const Tools: array of TToolDefinition;
      const Model: string; const Options: TChatOptions; OnChunk: TStreamCallback): TLLMResponse;
  end;

constructor TFakeProvider.Create(const AContent: string; AStatus: Integer);
begin inherited Create; FContent := AContent; FStatus := AStatus; end;

function TFakeProvider.Chat(const Messages: array of TMessage; const Tools: array of TToolDefinition;
  const Model: string; const Options: TChatOptions): TLLMResponse;
begin
  Result := Default(TLLMResponse);
  Result.Content := FContent;
  Result.StatusCode := FStatus;
end;

function TFakeProvider.GetDefaultModel: string; begin Result := 'fake-model'; end;
function TFakeProvider.GetName: string; begin Result := 'fake'; end;
function TFakeProvider.SupportsThinking: Boolean; begin Result := False; end;
function TFakeProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TFakeProvider.SupportsStreaming: Boolean; begin Result := False; end;
function TFakeProvider.ChatStream(const Messages: array of TMessage; const Tools: array of TToolDefinition;
  const Model: string; const Options: TChatOptions; OnChunk: TStreamCallback): TLLMResponse;
begin Result := Chat(Messages, Tools, Model, Options); end;

function Fake(const C: string; St: Integer): ILLMProvider;
begin Result := TFakeProvider.Create(C, St); end;

procedure TestLLMRerank;
var
  Order: TArray<Integer>;
  Scores: TArray<Single>;
  Docs: array of string;
begin
  SetLength(Docs, 3);
  Docs[0] := 'doc zero'; Docs[1] := 'doc one'; Docs[2] := 'doc two';

  { clean array }
  IsTrue(LLMRerank(Fake('[2, 0, 1]', 200), '', 'q', Docs, 0, 0, Order, Scores),
    'clean array parses');
  EqI(Length(Order), 3, 'clean: full permutation');
  EqI(Order[0], 2, 'clean: best is 2'); EqI(Order[1], 0, 'clean: then 0'); EqI(Order[2], 1, 'clean: then 1');
  IsTrue((Scores[0] > Scores[1]) and (Scores[1] > Scores[2]), 'clean: scores strictly descending');

  { thinking/prose with a stray early bracket -- pick the group with the MOST
    indices, not the first one (this is the [1,0,2] bug from the live run). }
  IsTrue(LLMRerank(Fake('Passage [1] looks off-topic. Final ranking: [2, 0, 1]', 200),
    '', 'q', Docs, 0, 0, Order, Scores), 'messy prose parses');
  EqI(Order[0], 2, 'messy: real array wins over stray [1]');
  EqI(Order[1], 0, 'messy: second is 0');

  { model omits a doc -> it is appended so Order stays a full permutation }
  IsTrue(LLMRerank(Fake('[2, 0]', 200), '', 'q', Docs, 0, 0, Order, Scores), 'partial parses');
  EqI(Length(Order), 3, 'partial: omitted doc appended');
  EqI(Order[2], 1, 'partial: the missing index (1) lands last');

  { top_n truncates }
  IsTrue(LLMRerank(Fake('[2, 0, 1]', 200), '', 'q', Docs, 2, 0, Order, Scores), 'topN parses');
  EqI(Length(Order), 2, 'topN=2 keeps two');

  { provider transport error (status=-1, error text in Content) must NOT be
    parsed as a ranking -- the exact live failure (garbage "1" from status=-1) }
  IsTrue(not LLMRerank(Fake('gemini error: status=-1 msg=TLS could not load', -1),
    '', 'q', Docs, 0, 0, Order, Scores), 'transport error -> False, not a bogus order');
  IsTrue(Length(Order) = 0, 'transport error yields no order');

  { HTTP error status likewise rejected }
  IsTrue(not LLMRerank(Fake('{"error":"rate limited"}', 429), '', 'q', Docs, 0, 0, Order, Scores),
    'HTTP 429 -> False');

  { success status but no parseable indices -> False (caller keeps RRF order) }
  IsTrue(not LLMRerank(Fake('I cannot help with that.', 200), '', 'q', Docs, 0, 0, Order, Scores),
    'no integers -> False');

  { no provider -> False }
  IsTrue(not LLMRerank(nil, '', 'q', Docs, 0, 0, Order, Scores), 'nil provider -> False');

  WriteLn('  ok: LLM reranker parses rankings, completes permutations, and rejects error responses');
end;

function WriteVocab: string;
var S: TStringList;
begin
  { id = line index (0-based): [PAD]=0 [UNK]=1 [CLS]=2 [SEP]=3 ... }
  Result := IncludeTrailingPathDelimiter(GetTempDir) + 'rerank_vocab_' + IntToStr(GetProcessID) + '.txt';
  S := TStringList.Create;
  try
    S.Add('[PAD]'); S.Add('[UNK]'); S.Add('[CLS]'); S.Add('[SEP]');
    S.Add('cancel'); S.Add('subscription'); S.Add('the'); S.Add('cat');
    S.Add('a'); S.Add('b'); S.Add('c'); S.Add('d'); S.Add('e');
    S.WriteBOM := False;
    S.SaveToFile(Result);
  finally S.Free; end;
end;

var
  Spec: TModelSpec;
  Rk: TReranker;
  Vocab: string;
  Ids, Types: TArray<Int64>;
  i: Integer;
  QsegLen, DsegLen: Integer;
begin
  { --- registry --- }
  IsTrue(FindRerankerSpec('ms-marco-minilm', Spec), 'default reranker resolves');
  IsTrue(Spec.NeedsTokenTypeIds, 'ms-marco cross-encoder needs token_type_ids');
  IsTrue(Pos('ms-marco', LowerCase(Spec.DisplayName)) > 0, 'display name');
  IsTrue(FindRerankerSpec('ms-marco-l12', Spec), 'ms-marco L-12 alias resolves');
  IsTrue(Pos('L-12', Spec.DisplayName) > 0, 'L-12 alias maps to the L-12 model');
  IsTrue(not FindRerankerSpec('bge-reranker', Spec), 'bge (SentencePiece) is NOT registered');
  IsTrue(not FindRerankerSpec('nope', Spec), 'unknown key -> false');
  WriteLn('  ok: reranker registry (ms-marco L-6 default + L-12, SentencePiece models rejected)');

  Vocab := WriteVocab;
  { model path unused until Score(); EncodePair only needs the tokenizer/vocab. }
  Rk := TReranker.Create('/nonexistent/model.onnx', Vocab, True, True, 512);
  try
    { --- pair packing: "[CLS] cancel subscription [SEP] the cat [SEP]" --- }
    Rk.EncodePair('cancel subscription', 'the cat', Ids, Types);
    EqI(Length(Ids), 7, 'pair length = CLS + 2 query + SEP + 2 doc + SEP');
    EqI(Integer(Ids[0]), 2, 'starts with [CLS]');
    EqI(Integer(Ids[1]), 4, 'query token 1 = cancel');
    EqI(Integer(Ids[2]), 5, 'query token 2 = subscription');
    EqI(Integer(Ids[3]), 3, 'first [SEP] after query');
    EqI(Integer(Ids[4]), 6, 'doc token 1 = the');
    EqI(Integer(Ids[5]), 7, 'doc token 2 = cat');
    EqI(Integer(Ids[6]), 3, 'closing [SEP]');
    { token_type_ids: 0 for [CLS]+query+first[SEP], 1 for doc+closing[SEP] }
    for i := 0 to 3 do EqI(Integer(Types[i]), 0, 'segment A id = 0 at ' + IntToStr(i));
    for i := 4 to 6 do EqI(Integer(Types[i]), 1, 'segment B id = 1 at ' + IntToStr(i));
    WriteLn('  ok: EncodePair packs [CLS] q [SEP] d [SEP] with correct segment ids');

    { --- truncation: a long doc is truncated to fit MaxSeq (=12 here) --- }
    Rk.Free;
    Rk := TReranker.Create('/nonexistent/model.onnx', Vocab, True, True, 12);
    Rk.EncodePair('a b', 'c d e a b c d e', Ids, Types);
    EqI(Length(Ids), 12, 'packed pair is capped at MaxSeq');
    EqI(Integer(Ids[0]), 2, 'still starts with [CLS] after truncation');
    EqI(Integer(Ids[High(Ids)]), 3, 'still ends with [SEP] after truncation');
    { last token type must be segment B (doc side) }
    EqI(Integer(Types[High(Types)]), 1, 'closing [SEP] stays in segment B');
    { count segment lengths are sane (query capped at budget/2) }
    QsegLen := 0; DsegLen := 0;
    for i := 0 to High(Types) do
      if Types[i] = 0 then Inc(QsegLen) else Inc(DsegLen);
    IsTrue((QsegLen >= 1) and (DsegLen >= 1), 'both segments non-empty after truncation');
    WriteLn('  ok: EncodePair truncates the doc to fit MaxSeq, keeps CLS/SEP structure');
  finally
    Rk.Free;
    DeleteFile(Vocab);
  end;

  { --- retrieval gate composition (ONNX-free): the config toggle AND
        provisioning must both hold before retrieval reranks. In this test
        env no reranker model is on disk, so "available" is always false --
        which is exactly the graceful-no-op property we want to guarantee. --- }
  SetRerankSearchEnabled(False);
  IsTrue(not RetrievalRerankActive(GetTempDir),
    'gate off -> retrieval does not rerank (fast path, no fs probe)');
  SetRerankSearchEnabled(True);
  IsTrue(not RetrievalRerankActive(GetTempDir),
    'gate on but model unprovisioned -> still no rerank (graceful no-op)');
  IsTrue(not LocalRerankAvailable(GetTempDir),
    'reranker reports unavailable when the model is not on disk');
  SetRerankSearchEnabled(False);   { restore }
  WriteLn('  ok: retrieval rerank gate needs BOTH the toggle and a provisioned model');

  TestLLMRerank;

  WriteLn('rerank_tests: OK');
end.
