(*
  PasClaw.Memory.Rerank.LLM - rerank candidates by asking the configured chat
  model to order them, the universal fallback when no local ONNX cross-encoder
  is provisioned (or when the operator prefers an LLM's judgement).

  A frontier chat model is a far stronger reranker than a small local
  cross-encoder -- it reads the query and every candidate together and reasons
  about relevance -- at the cost of one provider round-trip per rerank. So this
  is the natural fallback for the /v1/rerank endpoint: no model download, no
  tokenizer, works the moment a provider is configured.

  The model is asked for a bare JSON array of candidate indices, most relevant
  first. The parser is deliberately forgiving: it takes the first bracketed
  group of integers, dedups, drops out-of-range values, and appends any omitted
  candidates (in their original order) so the returned Order is always a full
  permutation -- a sloppy reply degrades gracefully instead of dropping docs.
*)
unit PasClaw.Memory.Rerank.LLM;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  {$IFDEF FPC}SysUtils,{$ELSE}System.SysUtils,{$ENDIF}
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types;

{ True when an LLM rerank is possible -- i.e. a real provider is available. }
function LLMRerankAvailable(const AProvider: ILLMProvider): Boolean;

{ Rank ADocs against AQuery via AProvider. AModel empty -> the provider's
  default model. Returns Order (doc indices, most relevant first) and matching
  descending pseudo-scores in (0,1]. ATopN<=0 returns all; ADocCharCap<=0 uses
  a sane default. False only when the provider errors or returns nothing
  parseable (caller then keeps the first-stage order). }
function LLMRerank(const AProvider: ILLMProvider; const AModel, AQuery: string;
  const ADocs: array of string; ATopN, ADocCharCap: Integer;
  out Order: TArray<Integer>; out Scores: TArray<Single>): Boolean;

implementation

const
  DEFAULT_DOC_CHAR_CAP = 600;   { trim each candidate in the prompt to bound tokens }

function LLMRerankAvailable(const AProvider: ILLMProvider): Boolean;
begin
  Result := Assigned(AProvider);
end;

function BuildPrompt(const AQuery: string; const ADocs: array of string;
  ADocCharCap: Integer): string;
var
  I: Integer;
  Doc: string;
begin
  Result := 'Query: ' + AQuery + sLineBreak + sLineBreak +
            'Candidate passages:' + sLineBreak;
  for I := 0 to High(ADocs) do
  begin
    Doc := ADocs[I];
    if (ADocCharCap > 0) and (Length(Doc) > ADocCharCap) then
      Doc := Copy(Doc, 1, ADocCharCap) + ' ...';
    { collapse newlines so each candidate is one line the model can't confuse
      with the numbering. }
    Doc := StringReplace(Doc, sLineBreak, ' ', [rfReplaceAll]);
    Doc := StringReplace(Doc, #10, ' ', [rfReplaceAll]);
    Doc := StringReplace(Doc, #13, ' ', [rfReplaceAll]);
    Result := Result + '[' + IntToStr(I) + '] ' + Doc + sLineBreak;
  end;
end;

{ Extract unique in-range indices from ASlice, in order of appearance. }
function IndicesFrom(const ASlice: string; ACount: Integer): TArray<Integer>;
var
  I, V: Integer;
  Cur: string;
  Seen: array of Boolean;

  procedure Flush;
  begin
    if Cur = '' then Exit;
    if TryStrToInt(Cur, V) and (V >= 0) and (V < ACount) and (not Seen[V]) then
    begin
      Seen[V] := True;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := V;
    end;
    Cur := '';
  end;

begin
  SetLength(Result, 0);
  SetLength(Seen, ACount);
  for I := 0 to ACount - 1 do Seen[I] := False;
  Cur := '';
  for I := 1 to Length(ASlice) do
    if (ASlice[I] >= '0') and (ASlice[I] <= '9') then
      Cur := Cur + ASlice[I]
    else
      Flush;
  Flush;
end;

{ Recover the ranking array from a possibly-messy model reply. Thinking models
  (and models that ignore "JSON only") interleave prose and stray brackets like
  "passage [1] is ..." before the real answer -- so DON'T just take the first
  bracket. Scan every [ ... ] group, and pick the one yielding the MOST valid
  unique indices (the real ranking lists them all); on a tie prefer the LAST
  such group, since the final answer tends to come last. Fall back to a
  whole-text integer scan when there are no brackets at all. }
function ParseIndexArray(const AText: string; ACount: Integer): TArray<Integer>;
var
  I, GStart: Integer;
  Cand: TArray<Integer>;
  Best: TArray<Integer>;
begin
  SetLength(Result, 0);
  if ACount <= 0 then Exit;

  SetLength(Best, 0);
  GStart := 0;
  for I := 1 to Length(AText) do
  begin
    if AText[I] = '[' then
      GStart := I
    else if (AText[I] = ']') and (GStart > 0) then
    begin
      Cand := IndicesFrom(Copy(AText, GStart + 1, I - GStart - 1), ACount);
      { >= so a later group of equal size wins the tie (answer comes last). }
      if Length(Cand) >= Length(Best) then Best := Cand;
      GStart := 0;
    end;
  end;

  if Length(Best) > 0 then
    Result := Best
  else
    Result := IndicesFrom(AText, ACount);   { no brackets -> scan everything }
end;

function LLMRerank(const AProvider: ILLMProvider; const AModel, AQuery: string;
  const ADocs: array of string; ATopN, ADocCharCap: Integer;
  out Order: TArray<Integer>; out Scores: TArray<Single>): Boolean;
var
  Opts: TChatOptions;
  Msgs: TMessageArray;
  NoTools: array of TToolDefinition;
  Resp: TLLMResponse;
  Model: string;
  Ranked: TArray<Integer>;
  InRanked: array of Boolean;
  I, N, Keep: Integer;
begin
  Order  := nil;
  Scores := nil;
  Result := False;
  N := Length(ADocs);
  if N = 0 then Exit;
  if not Assigned(AProvider) then Exit;
  if ADocCharCap <= 0 then ADocCharCap := DEFAULT_DOC_CHAR_CAP;

  Opts := DefaultChatOptions;
  Opts.Temperature := 0;      { deterministic ordering }
  Opts.Stream      := False;
  { Never let provider grounding/web-search fire for a rerank: we are ordering
    the passages we were handed, not searching. With Gemini google_search on,
    the model returns empty text + groundingMetadata for this prompt. }
  Opts.DisableServerTools := True;
  { Thinking models (e.g. gemini-2.5-flash) spend output budget reasoning
    BEFORE emitting the answer; with a small cap the whole budget goes to
    thinking and the text part comes back empty. The answer here is only a
    short index array, but give generous headroom so thinking never starves
    it. Harmless for non-thinking models -- the array is tiny. }
  Opts.MaxTokens   := 4096;
  Opts.SystemPrompt :=
    'You are a search result reranker. You are given a query and a numbered ' +
    'list of candidate passages. Order the passages from MOST to LEAST ' +
    'relevant to the query. Reply with ONLY a JSON array of the passage ' +
    'numbers in that order, e.g. [3,0,1,2]. Include every number exactly ' +
    'once and output no other text.';

  SetLength(NoTools, 0);
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, BuildPrompt(AQuery, ADocs, ADocCharCap));

  Model := AModel;
  if Model = '' then Model := AProvider.GetDefaultModel;

  Resp := Default(TLLMResponse);
  try
    Resp := AProvider.Chat(Msgs, NoTools, Model, Opts);
  except
    on E: Exception do
      Exit;   { provider raised -> caller keeps the first-stage order }
  end;

  { Providers report transport/HTTP failures via StatusCode and stuff the error
    text into Content rather than raising (e.g. "gemini error: status=-1 msg=TLS
    ..."). Never parse that as a ranking -- it yields a garbage order. -1 =
    DNS/TLS/socket, >=400 = HTTP error; 0 = older provider that doesn't set it. }
  if (Resp.StatusCode = -1) or (Resp.StatusCode >= 400) then Exit;

  Ranked := ParseIndexArray(Resp.Content, N);
  if Length(Ranked) = 0 then Exit;   { nothing usable }

  { Append any candidates the model omitted, in original order, so Order is a
    full permutation and no doc is silently dropped. }
  SetLength(InRanked, N);
  for I := 0 to N - 1 do InRanked[I] := False;
  for I := 0 to High(Ranked) do InRanked[Ranked[I]] := True;
  Order := Copy(Ranked);
  for I := 0 to N - 1 do
    if not InRanked[I] then
    begin
      SetLength(Order, Length(Order) + 1);
      Order[High(Order)] := I;
    end;

  { Descending pseudo-scores in (0,1]: rank 0 -> 1.0, last -> 1/N. }
  SetLength(Scores, Length(Order));
  for I := 0 to High(Order) do
    Scores[I] := (Length(Order) - I) / Length(Order);

  if ATopN > 0 then
  begin
    Keep := ATopN;
    if Keep < Length(Order) then
    begin
      SetLength(Order,  Keep);
      SetLength(Scores, Keep);
    end;
  end;

  Result := True;
end;

end.
