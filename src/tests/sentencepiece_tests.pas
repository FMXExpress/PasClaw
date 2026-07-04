program sentencepiece_tests;
(*
  Unit tests for LocalVector.SentencePiece (XLM-R SentencePiece Unigram
  tokenizer) using a TINY hand-built tokenizer.json -- no 90 MB model / 250k
  vocab needed, so this runs in CI. Covers:
    * JSON string unescape (\uXXXX + the escape set);
    * metaspace + Viterbi max-score segmentation over a small unigram model;
    * RoBERTa pair packing <s> A </s></s> B </s> with token_type_ids all 0.

  The FULL correctness proof -- byte-identical output vs HuggingFace tokenizers
  on the real bge-reranker vocab (ASCII, accented Latin, code) -- is done
  out-of-band with the provisioned tokenizer.json (see the branch's scratch
  validator); it can't run in CI because the vocab file is 8 MB.
*)
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  LocalVector.SentencePiece;

procedure Fail_(const M: string); begin WriteLn('FAIL: ' + M); Halt(1); end;
procedure IsTrue(C: Boolean; const M: string); begin if not C then Fail_(M); end;
procedure EqI(G, W: Integer; const M: string);
begin if G <> W then Fail_(M + Format(' (got %d want %d)', [G, W])); end;

function WriteTinyTokenizer: string;
{ ids: <s>=0 <pad>=1 </s>=2 <unk>=3 then pieces. Scores chosen so the
  intended segmentation wins the Viterbi. U+2581 written as ▁. }
var S: TStringList;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) + 'sp_tiny_' + IntToStr(GetProcessID) + '.json';
  S := TStringList.Create;
  try
    S.Text :=
      '{"model":{"type":"Unigram","unk_id":3,"vocab":[' +
      '["<s>",0.0],["<pad>",0.0],["</s>",0.0],["<unk>",0.0],' +
      '["▁",-3.0],' +               { id 4: lone marker }
      '["▁hello",-2.0],' +          { id 5 }
      '["hello",-5.0],' +                { id 6 }
      '["▁world",-2.0],' +          { id 7 }
      '["▁wor",-6.0],' +            { id 8 }
      '["ld",-6.0],' +                   { id 9 }
      '["▁a",-4.0]' +               { id 10 }
      ']}}';
    S.WriteBOM := False;
    S.SaveToFile(Result);
  finally S.Free; end;
end;

var
  Tok: TSPUnigram;
  Path: string;
  ids: TArray<Integer>;
  pids, ptt: TArray<Int64>;
  u: UnicodeString;
begin
  { --- JsonUnescape --- }
  u := JsonUnescape('a▁b');
  IsTrue((Length(u) = 3) and (u[1] = 'a') and (Ord(u[2]) = $2581) and (u[3] = 'b'),
    'JsonUnescape decodes \\u2581 to U+2581');
  u := JsonUnescape('tab\tquote\"slash\\done');
  IsTrue(Pos(UnicodeString(#9), u) > 0, 'JsonUnescape handles \\t');
  WriteLn('  ok: JsonUnescape');

  Path := WriteTinyTokenizer;
  Tok := TSPUnigram.Create(Path);
  try
    EqI(Tok.Count, 11, 'tiny vocab loaded');
    EqI(Tok.BosId, 0, 'bos=0'); EqI(Tok.EosId, 2, 'eos=2'); EqI(Tok.UnkId, 3, 'unk=3');

    { "hello world" -> "▁hello▁world": [_hello](-2)+[_world](-2) = -4
      beats [_](-3)+[hello](-5)=-8 and [_wor..](-6)... so ids [5,7]. }
    ids := Tok.Encode('hello world');
    EqI(Length(ids), 2, 'hello world -> 2 pieces');
    EqI(ids[0], 5, 'first piece = _hello (id 5)');
    EqI(ids[1], 7, 'second piece = _world (id 7)');
    WriteLn('  ok: Viterbi picks the max-score segmentation');

    { an unknown char (no piece, no single-char match) -> <unk> }
    ids := Tok.Encode('z');
    IsTrue((Length(ids) >= 1) and (ids[High(ids)] = 3), 'unknown char -> <unk>');
    WriteLn('  ok: unknown codepoint falls back to <unk>');

    { pair packing: <s> hello </s></s> world </s> = [0,5,2,2,7,2], type_ids 0 }
    Tok.EncodePair('hello', 'world', 512, pids, ptt);
    EqI(Length(pids), 6, 'pair length = <s> q </s></s> d </s>');
    EqI(Integer(pids[0]), 0, 'starts <s>');
    EqI(Integer(pids[1]), 5, 'query piece');
    EqI(Integer(pids[2]), 2, 'first </s>');
    EqI(Integer(pids[3]), 2, 'second </s> (RoBERTa double-sep)');
    EqI(Integer(pids[4]), 7, 'doc piece');
    EqI(Integer(pids[5]), 2, 'closing </s>');
    IsTrue((ptt[0] = 0) and (ptt[5] = 0), 'XLM-R token_type_ids are all 0');
    WriteLn('  ok: EncodePair packs <s> q </s></s> d </s> (type_ids all 0)');
  finally
    Tok.Free;
    DeleteFile(Path);
  end;

  WriteLn('sentencepiece_tests: OK');
end.
