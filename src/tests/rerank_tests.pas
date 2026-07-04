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
  PasClaw.Memory.Rerank,
  PasClaw.Memory.Rerank.Serve;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure IsTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure EqI(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Msg + Format(' (got %d want %d)', [Got, Want])); end;

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
  IsTrue(FindRerankerSpec('bge-reranker', Spec), 'bge-reranker alias resolves');
  IsTrue(not FindRerankerSpec('nope', Spec), 'unknown key -> false');
  WriteLn('  ok: reranker registry (ms-marco default + bge alias, unknown rejected)');

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

  WriteLn('rerank_tests: OK');
end.
