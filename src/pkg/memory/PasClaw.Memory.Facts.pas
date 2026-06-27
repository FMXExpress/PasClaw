(*
  PasClaw.Memory.Facts - Phase 2 persistence for distilled memory.

  Stores the TFact records produced by PasClaw.Memory.Distill in a
  SQLite table (workspace/memory/facts.db). This is the relational
  store + lifecycle bookkeeping; the similarity/dedup side (sqlite-vec
  embeddings, contradiction resolution) is Phase 3 and slots in on top
  of this schema.

  Why SQLite rather than flat .md files: the fact store's core ops are
  metadata queries and in-place updates -- "active facts as of today"
  (WHERE not superseded AND not expired), supersede a contradicted
  fact, expire-sweep -- which SQL does cleanly and a markdown blob does
  not. Auditability (the thing pure-vector stores lose) comes back via
  a future Memory web tab + a markdown export, not by making files the
  source of truth.

  Cross-target split mirrors PasClaw.Memory.Index:
    - {$IFDEF FPC}: TSQLite3Connection + TSQLQuery (sqldb).
    - {$ELSE}:      FireDAC TFDConnection + TFDQuery.

  Schema:
    facts(id INTEGER PK, text, kind, scope, confidence REAL,
          event_date TEXT, expires TEXT, source_session TEXT,
          created_at INTEGER, superseded INTEGER)

    expires is '' (never) or 'YYYY-MM-DD'. A fact is ACTIVE when
    superseded = 0 and (expires = '' or expires >= today). "today" is
    passed in by the caller so reads stay deterministic/testable.

    event_date is '' or 'YYYY-MM-DD' and is DISTINCT from expires: it is
    when an event happens (so the agent can surface "your exam is
    tomorrow"), whereas expires is when the fact stops being worth
    keeping. See FormatUpcomingBlock for the proactive surfacing path.
*)
unit PasClaw.Memory.Facts;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Memory.Distill;   { TFact }

type
  TStoredFact = record
    Id:            Int64;
    Text:          string;
    Kind:          string;
    Scope:         string;
    Confidence:    Double;
    EventDate:     string;    { 'YYYY-MM-DD' or '' -- when the event happens }
    Expires:       string;
    SourceSession: string;
    CreatedAt:     Int64;     { unix seconds }
    Superseded:    Boolean;
    EmbeddingHex:  string;    { hex-packed Single[] (Phase 4c); '' if none }
  end;
  TStoredFactArray = array of TStoredFact;

  { Injectable text embedder. Returns a unit-ish vector; [] when embedding
    is unavailable (no ONNX model provisioned). Set via SetFactEmbedder so
    the dedup/search logic stays testable with a fake and the heavy ONNX
    dependency lives in a separate unit. }
  TFactEmbedFn = function(const Text: string): TArray<Single>;

  IFactStore = interface
    ['{4C2F9A11-7E3D-4B8A-9F21-2A6D0C5E1B77}']
    function  Open(const DbPath: string): Boolean;
    procedure Close;
    { Insert F; returns the new row id (0 on failure). CreatedAt is set
      to now; Superseded starts false. }
    function  Add(const F: TFact; CreatedAt: Int64): Int64;
    { Facts that are live as of Today ('YYYY-MM-DD'): not superseded and
      not past their expiry. Newest first. }
    function  ActiveFacts(const Today: string): TStoredFactArray;
    { Every fact, including superseded/expired (newest first). }
    function  AllFacts: TStoredFactArray;
    { Mark a fact superseded (kept for history). True if a row changed. }
    function  Supersede(Id: Int64): Boolean;
    { Hard-delete a fact. True if a row was removed. }
    function  Delete(Id: Int64): Boolean;
    { Total rows, including superseded/expired. }
    function  CountAll: Integer;
    { Count of facts ACTIVE as of Today -- identical predicate to
      ActiveFacts(Today), so the two never disagree. }
    function  CountActive(const Today: string): Integer;
    { Embed any ACTIVE rows that have no embedding yet (pre-4c databases,
      or facts saved while the embedder was unavailable) so they take part
      in semantic dedup + search. No-op without a wired embedder. Returns
      the number of rows filled. }
    function  BackfillEmbeddings(const Today: string): Integer;
  end;

function NewFactStore: IFactStore;

{ Default on-disk location: <home>/workspace/memory/facts.db }
function DefaultFactsDbPath(const HomeDir: string): string;

{ Render facts as a system-prompt block, newest first, until Budget bytes
  are used; a trailing "(+N more -- search with memory_search)" breadcrumb
  notes any omitted. Wholesale (NOT relevance-sliced). '' when Facts is
  empty or Budget <= 0. Pure -- exposed for testing. }
function FormatFactsBlock(const Facts: TStoredFactArray; Budget: Integer): string;

{ Convenience for the prompt builder: open the default store, read the
  facts active as of Today, and format them within Budget. '' when the
  store is absent/empty or Budget <= 0. }
function ActiveFactsBlock(const HomeDir, Today: string; Budget: Integer): string;

{ Render the PROACTIVE "upcoming events" block: facts whose event_date
  falls between Today and Today+WithinDays (inclusive), soonest first,
  each phrased relative to Today ("today" / "tomorrow" / "in N days").
  This is the "your exam is tomorrow" surfacing -- distinct from the
  wholesale facts block, which is keyed on expiry, not event date.

  Budget bounds the rendered size (bytes), same contract as
  FormatFactsBlock: lines are emitted soonest-first until the budget is
  used, at least one is kept, and a "(+N more ...)" breadcrumb notes any
  dropped. Pure; '' when nothing is upcoming, Facts is empty,
  WithinDays < 0, or Budget <= 0. }
function FormatUpcomingBlock(const Facts: TStoredFactArray;
                            const Today: string; WithinDays, Budget: Integer): string;

{ Convenience for the prompt builder: open the default store and format
  the upcoming-events block for facts active as of Today (so an expired
  fact never resurfaces), bounded by Budget bytes. '' when nothing is
  upcoming, the store is absent, or Budget <= 0. }
function UpcomingFactsBlock(const HomeDir, Today: string;
                           WithinDays, Budget: Integer): string;

{ Render facts as human-readable / git-friendly Markdown, grouped by scope
  (the auditability export -- shared by the CLI `memory export` and the web
  Memory tab's download). Pure. }
function FactsToMarkdown(const Facts: TStoredFactArray; const Today: string): string;

{ Keyword-rank Facts against Query: score each by how many distinct query
  terms appear (case-insensitive substring) in its text, drop zero-score,
  sort by score then confidence then recency, return the top K. Pure (the
  keyword half of hybrid retrieval) -- exposed for testing. }
function RankFactsByQuery(const Facts: TStoredFactArray;
                          const Query: string; K: Integer): TStoredFactArray;

{ Open the default store and return the top-K active (as of Today) facts
  matching Query. [] when the store is absent/empty. Used by memory_search
  so distilled facts are reachable alongside the .md notes. When a fact
  embedder is active, keyword and semantic (cosine) ranks are RRF-fused. }
function SearchActiveFacts(const HomeDir, Today, Query: string;
                          K: Integer): TStoredFactArray;

{ ----- Semantic layer (Phase 4c) -----

  Register the embedder used for semantic dedup + search. nil (the
  default) disables the semantic layer entirely -- everything falls back
  to the exact + keyword behaviour, so a build without ONNX is unaffected.
  The heavy ONNX embedder lives in PasClaw.Memory.Facts.Embed. }
procedure SetFactEmbedder(Fn: TFactEmbedFn);
function FactEmbedderActive: Boolean;

{ Open the default store and backfill embeddings for active rows missing
  them (see IFactStore.BackfillEmbeddings). Returns rows filled; 0 when no
  embedder is wired or the store is absent. Called when the embedder is
  enabled so pre-4c facts join the semantic layer. }
function BackfillFactEmbeddings(const HomeDir, Today: string): Integer;

{ Cosine similarity of two equal-length vectors (0 when either is empty or
  lengths differ). Pure -- exposed for testing. }
function CosineSim(const A, B: TArray<Single>): Double;

{ Hex (de)serialisation of an embedding for the TEXT column. Round-trip
  exact; locale-safe (no float formatting). Pure -- exposed for testing. }
function EmbToHex(const V: TArray<Single>): string;
function HexToEmb(const S: string): TArray<Single>;

implementation

uses
  {$IFDEF FPC}
  sqldb, sqlite3conn,
  {$ELSE}
  FireDAC.Comp.Client, FireDAC.Phys.SQLite, FireDAC.Stan.Def,
  FireDAC.Stan.Async, FireDAC.Stan.Param, FireDAC.DApt,
  {$ENDIF}
  DateUtils,
  PasClaw.Utils,
  PasClaw.Logger;

function DefaultFactsDbPath(const HomeDir: string): string;
begin
  Result := JoinPath(JoinPath(JoinPath(HomeDir, 'workspace'), 'memory'), 'facts.db');
end;

const
  { Cosine above which two facts are "the same" for semantic dedup.
    MiniLM normalised cosine: ~0.85 catches paraphrases without merging
    merely-related facts. Tunable; conservative on the high side so we
    never silently lose a distinct fact. }
  SemanticDedupThreshold = 0.85;
  RrfK = 60;   { Reciprocal Rank Fusion constant (same as the .md index). }

var
  GFactEmbed: TFactEmbedFn = nil;

procedure SetFactEmbedder(Fn: TFactEmbedFn);
begin
  GFactEmbed := Fn;
end;

function FactEmbedderActive: Boolean;
begin
  Result := Assigned(GFactEmbed);
end;

function CosineSim(const A, B: TArray<Single>): Double;
var
  i: Integer;
  dot, na, nb: Double;
begin
  Result := 0;
  if (Length(A) = 0) or (Length(A) <> Length(B)) then Exit;
  dot := 0; na := 0; nb := 0;
  for i := 0 to High(A) do
  begin
    dot := dot + (A[i] * B[i]);
    na  := na + (A[i] * A[i]);
    nb  := nb + (B[i] * B[i]);
  end;
  if (na = 0) or (nb = 0) then Exit;
  Result := dot / (Sqrt(na) * Sqrt(nb));
end;

function EmbToHex(const V: TArray<Single>): string;
const
  Hex: array[0..15] of Char = '0123456789abcdef';
var
  Bytes: TBytes;
  i: Integer;
begin
  Result := '';
  if Length(V) = 0 then Exit;
  SetLength(Bytes, Length(V) * SizeOf(Single));
  if Length(Bytes) > 0 then
    Move(V[0], Bytes[0], Length(Bytes));
  SetLength(Result, Length(Bytes) * 2);
  for i := 0 to High(Bytes) do
  begin
    Result[(i * 2) + 1] := Hex[(Bytes[i] shr 4) and $0F];
    Result[(i * 2) + 2] := Hex[Bytes[i] and $0F];
  end;
end;

function HexToEmb(const S: string): TArray<Single>;
var
  Bytes: TBytes;
  i, n: Integer;

  function Nib(C: Char): Integer;
  begin
    case C of
      '0'..'9': Result := Ord(C) - Ord('0');
      'a'..'f': Result := Ord(C) - Ord('a') + 10;
      'A'..'F': Result := Ord(C) - Ord('A') + 10;
    else Result := 0;
    end;
  end;

begin
  Result := nil;
  if (S = '') or (Length(S) mod 2 <> 0) then Exit;
  n := Length(S) div 2;
  if n mod SizeOf(Single) <> 0 then Exit;
  SetLength(Bytes, n);
  for i := 0 to n - 1 do
    Bytes[i] := (Nib(S[(i * 2) + 1]) shl 4) or Nib(S[(i * 2) + 2]);
  SetLength(Result, n div SizeOf(Single));
  if Length(Result) > 0 then
    Move(Bytes[0], Result[0], n);
end;

function TryParseISODate(const S: string; out DT: TDateTime): Boolean;
var
  Y, M, D: Integer;
begin
  Result := False;
  DT := 0;
  if (Length(S) <> 10) or (S[5] <> '-') or (S[8] <> '-') then Exit;
  if not TryStrToInt(Copy(S, 1, 4), Y) then Exit;
  if not TryStrToInt(Copy(S, 6, 2), M) then Exit;
  if not TryStrToInt(Copy(S, 9, 2), D) then Exit;
  Result := TryEncodeDate(Y, M, D, DT);
end;

function ISODaysBetween(const FromISO, ToISO: string; out Days: Integer): Boolean;
{ Whole days from FromISO to ToISO (positive => ToISO is later). False when
  either side is not a valid YYYY-MM-DD. }
var
  A, B: TDateTime;
begin
  Result := False;
  Days := 0;
  if not TryParseISODate(FromISO, A) then Exit;
  if not TryParseISODate(ToISO, B) then Exit;
  Days := Trunc(B) - Trunc(A);
  Result := True;
end;

function RelDayPhrase(Days: Integer): string;
begin
  if Days = 0 then Result := 'today'
  else if Days = 1 then Result := 'tomorrow'
  else Result := Format('in %d days', [Days]);
end;

function FormatFactsBlock(const Facts: TStoredFactArray; Budget: Integer): string;
const
  Header = 'Durable facts (auto-distilled memory):';
var
  i, Used, Omitted: Integer;
  Line, Body: string;
begin
  Result := '';
  if (Length(Facts) = 0) or (Budget <= 0) then Exit;
  Body := '';
  Used := Length(Header);
  Omitted := 0;
  for i := 0 to High(Facts) do
  begin
    if Trim(Facts[i].Text) = '' then Continue;
    Line := '- ' + Facts[i].Text;
    if Facts[i].EventDate <> '' then
      Line := Line + ' (event ' + Facts[i].EventDate + ')';
    if Facts[i].Expires <> '' then
      Line := Line + ' (until ' + Facts[i].Expires + ')';
    { +1 for the newline this line will cost. Always keep at least one. }
    if (Body <> '') and (Used + Length(Line) + 1 > Budget) then
    begin
      Omitted := Length(Facts) - i;
      Break;
    end;
    if Body <> '' then Body := Body + sLineBreak;
    Body := Body + Line;
    Used := Used + Length(Line) + 1;
  end;
  if Body = '' then Exit;
  Result := Header + sLineBreak + Body;
  if Omitted > 0 then
    { memory_search now also searches facts.db (Phase 4b), so this hint is
      actionable -- the model can recover omitted facts by querying. }
    Result := Result + sLineBreak +
      Format('(+%d more -- search with memory_search)', [Omitted]);
end;

function ActiveFactsBlock(const HomeDir, Today: string; Budget: Integer): string;
var
  Store: IFactStore;
begin
  Result := '';
  if Budget <= 0 then Exit;
  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(HomeDir)) then Exit;
  try
    Result := FormatFactsBlock(Store.ActiveFacts(Today), Budget);
  finally
    Store.Close;
  end;
end;

function FormatUpcomingBlock(const Facts: TStoredFactArray;
  const Today: string; WithinDays, Budget: Integer): string;
const
  Header = 'Upcoming (mention proactively if the user would want a heads-up):';
var
  i, j, n, Days, Used, Omitted: Integer;
  Idx, DayOf: array of Integer;
  ti, tj: Integer;
  Body, Line: string;
begin
  Result := '';
  if (Length(Facts) = 0) or (WithinDays < 0) or (Budget <= 0) then Exit;
  { Collect facts with an event_date in [Today, Today+WithinDays]. }
  n := 0;
  for i := 0 to High(Facts) do
  begin
    if Facts[i].EventDate = '' then Continue;
    if not ISODaysBetween(Today, Facts[i].EventDate, Days) then Continue;
    if (Days < 0) or (Days > WithinDays) then Continue;
    SetLength(Idx, n + 1); SetLength(DayOf, n + 1);
    Idx[n] := i; DayOf[n] := Days; Inc(n);
  end;
  if n = 0 then Exit;
  { Soonest first (selection sort, small n). }
  for i := 0 to n - 2 do
    for j := i + 1 to n - 1 do
      if DayOf[j] < DayOf[i] then
      begin
        ti := DayOf[i]; DayOf[i] := DayOf[j]; DayOf[j] := ti;
        tj := Idx[i];   Idx[i]   := Idx[j];   Idx[j]   := tj;
      end;
  { Emit soonest-first within Budget; keep at least one, breadcrumb the rest. }
  Body := '';
  Used := Length(Header);
  Omitted := 0;
  for i := 0 to n - 1 do
  begin
    Line := Format('- %s (%s, %s)',
      [Facts[Idx[i]].Text, RelDayPhrase(DayOf[i]), Facts[Idx[i]].EventDate]);
    { +1 for the newline this line will cost. }
    if (Body <> '') and (Used + Length(Line) + 1 > Budget) then
    begin
      Omitted := n - i;
      Break;
    end;
    if Body <> '' then Body := Body + sLineBreak;
    Body := Body + Line;
    Used := Used + Length(Line) + 1;
  end;
  if Body = '' then Exit;
  Result := Header + sLineBreak + Body;
  if Omitted > 0 then
    Result := Result + sLineBreak +
      Format('(+%d more upcoming -- search with memory_search)', [Omitted]);
end;

function UpcomingFactsBlock(const HomeDir, Today: string;
  WithinDays, Budget: Integer): string;
var
  Store: IFactStore;
begin
  Result := '';
  if Budget <= 0 then Exit;
  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(HomeDir)) then Exit;
  try
    Result := FormatUpcomingBlock(Store.ActiveFacts(Today), Today, WithinDays, Budget);
  finally
    Store.Close;
  end;
end;

function FactsToMarkdown(const Facts: TStoredFactArray; const Today: string): string;
var
  SL: TStringList;

  procedure EmitScope(const Scope: string);
  var j: Integer; Any: Boolean; Line: string;
  begin
    Any := False;
    for j := 0 to High(Facts) do
    begin
      if Facts[j].Scope <> Scope then Continue;
      if not Any then begin SL.Add('## ' + Scope); SL.Add(''); Any := True; end;
      Line := Format('- %s  _(%s, conf %.2f)_',
        [Facts[j].Text, Facts[j].Kind, Facts[j].Confidence]);
      if Facts[j].EventDate <> '' then Line := Line + ' _(event ' + Facts[j].EventDate + ')_';
      if Facts[j].Expires <> '' then Line := Line + ' _(until ' + Facts[j].Expires + ')_';
      if Facts[j].Superseded then Line := Line + ' _(superseded)_';
      SL.Add(Line);
    end;
    if Any then SL.Add('');
  end;

begin
  SL := TStringList.Create;
  try
    SL.Add('# PasClaw distilled memory');
    SL.Add('');
    SL.Add(Format('_%d fact(s), exported %s._', [Length(Facts), Today]));
    SL.Add('');
    EmitScope('user');
    EmitScope('project');
    EmitScope('session');
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function RankFactsByQuery(const Facts: TStoredFactArray;
  const Query: string; K: Integer): TStoredFactArray;
var
  Terms: array of string;
  Cur, LowText: string;
  i, j, NTerms, Score: Integer;
  { Parallel scored set: a fact + its match score, before top-K sort. }
  Scored: array of TStoredFact;
  ScoreOf: array of Integer;
  n, a, b: Integer;
  TmpF: TStoredFact;
  TmpI: Integer;

  procedure AddTerm(const T: string);
  var t2: string; x: Integer; dup: Boolean;
  begin
    t2 := LowerCase(Trim(T));
    if t2 = '' then Exit;
    dup := False;
    for x := 0 to High(Terms) do if Terms[x] = t2 then begin dup := True; Break; end;
    if not dup then begin SetLength(Terms, Length(Terms) + 1); Terms[High(Terms)] := t2; end;
  end;

begin
  Result := nil;
  if (Length(Facts) = 0) or (Trim(Query) = '') then Exit;
  if K <= 0 then K := 5;

  { Tokenise the query on non-alphanumeric (>= $80 kept so UTF-8 survives). }
  SetLength(Terms, 0);
  Cur := '';
  for i := 1 to Length(Query) do
    if (Query[i] in ['a'..'z','A'..'Z','0'..'9']) or (Ord(Query[i]) >= $80) then
      Cur := Cur + Query[i]
    else begin AddTerm(Cur); Cur := ''; end;
  AddTerm(Cur);
  NTerms := Length(Terms);
  if NTerms = 0 then Exit;

  { Score: distinct query terms present (substring) in the fact text. }
  n := 0;
  for i := 0 to High(Facts) do
  begin
    LowText := LowerCase(Facts[i].Text);
    Score := 0;
    for j := 0 to NTerms - 1 do
      if Pos(Terms[j], LowText) > 0 then Inc(Score);
    if Score = 0 then Continue;
    SetLength(Scored, n + 1);
    SetLength(ScoreOf, n + 1);
    Scored[n] := Facts[i];
    ScoreOf[n] := Score;
    Inc(n);
  end;
  if n = 0 then Exit;

  { Selection sort (small n): score desc, then confidence desc, then
    created_at desc. }
  for a := 0 to n - 2 do
    for b := a + 1 to n - 1 do
      if (ScoreOf[b] > ScoreOf[a]) or
         ((ScoreOf[b] = ScoreOf[a]) and (Scored[b].Confidence > Scored[a].Confidence)) or
         ((ScoreOf[b] = ScoreOf[a]) and (Scored[b].Confidence = Scored[a].Confidence)
            and (Scored[b].CreatedAt > Scored[a].CreatedAt)) then
      begin
        TmpF := Scored[a]; Scored[a] := Scored[b]; Scored[b] := TmpF;
        TmpI := ScoreOf[a]; ScoreOf[a] := ScoreOf[b]; ScoreOf[b] := TmpI;
      end;

  if n > K then n := K;
  SetLength(Result, n);
  for i := 0 to n - 1 do Result[i] := Scored[i];
end;

function RankFactsBySemantic(const Facts: TStoredFactArray;
  const QueryEmb: TArray<Single>; K: Integer): TStoredFactArray;
const
  MinCosine = 0.30;   { drop clearly-unrelated facts before fusion }
var
  Scored: array of TStoredFact;
  ScoreOf: array of Double;
  i, n, a, b: Integer;
  c: Double;
  TmpF: TStoredFact;
  TmpD: Double;
begin
  Result := nil;
  if (Length(Facts) = 0) or (Length(QueryEmb) = 0) then Exit;
  if K <= 0 then K := 5;
  n := 0;
  for i := 0 to High(Facts) do
  begin
    if Facts[i].EmbeddingHex = '' then Continue;
    c := CosineSim(QueryEmb, HexToEmb(Facts[i].EmbeddingHex));
    if c < MinCosine then Continue;
    SetLength(Scored, n + 1); SetLength(ScoreOf, n + 1);
    Scored[n] := Facts[i]; ScoreOf[n] := c; Inc(n);
  end;
  if n = 0 then Exit;
  for a := 0 to n - 2 do
    for b := a + 1 to n - 1 do
      if ScoreOf[b] > ScoreOf[a] then
      begin
        TmpF := Scored[a]; Scored[a] := Scored[b]; Scored[b] := TmpF;
        TmpD := ScoreOf[a]; ScoreOf[a] := ScoreOf[b]; ScoreOf[b] := TmpD;
      end;
  if n > K then n := K;
  SetLength(Result, n);
  for i := 0 to n - 1 do Result[i] := Scored[i];
end;

function FuseFactRanks(const A, B: TStoredFactArray; K: Integer): TStoredFactArray;
{ Reciprocal Rank Fusion over two ranked fact lists, keyed by fact id. }
var
  Uniq: TStoredFactArray;
  Score: array of Double;
  n, i, j, a2, b2: Integer;
  TmpF: TStoredFact;
  TmpD: Double;

  function FindUniq(Id: Int64): Integer;
  var x: Integer;
  begin
    Result := -1;
    for x := 0 to n - 1 do if Uniq[x].Id = Id then Exit(x);
  end;

  procedure Fold(const L: TStoredFactArray);
  var r, idx: Integer;
  begin
    for r := 0 to High(L) do
    begin
      idx := FindUniq(L[r].Id);
      if idx < 0 then
      begin
        SetLength(Uniq, n + 1); SetLength(Score, n + 1);
        Uniq[n] := L[r]; Score[n] := 0; idx := n; Inc(n);
      end;
      Score[idx] := Score[idx] + (1.0 / (RrfK + r + 1));
    end;
  end;

begin
  Result := nil;
  n := 0;
  Fold(A);
  Fold(B);
  if n = 0 then Exit;
  for a2 := 0 to n - 2 do
    for b2 := a2 + 1 to n - 1 do
      if Score[b2] > Score[a2] then
      begin
        TmpF := Uniq[a2]; Uniq[a2] := Uniq[b2]; Uniq[b2] := TmpF;
        TmpD := Score[a2]; Score[a2] := Score[b2]; Score[b2] := TmpD;
      end;
  if (K > 0) and (n > K) then n := K;
  SetLength(Result, n);
  for i := 0 to n - 1 do Result[i] := Uniq[i];
end;

function SearchActiveFacts(const HomeDir, Today, Query: string;
  K: Integer): TStoredFactArray;
var
  Store: IFactStore;
  Active, KwHits, SemHits: TStoredFactArray;
  QEmb: TArray<Single>;
begin
  Result := nil;
  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(HomeDir)) then Exit;
  try
    Active := Store.ActiveFacts(Today);
  finally
    Store.Close;
  end;
  if Length(Active) = 0 then Exit;

  KwHits := RankFactsByQuery(Active, Query, K);

  { Keyword-only unless an embedder is wired and can embed the query. }
  if not Assigned(GFactEmbed) then Exit(KwHits);
  QEmb := GFactEmbed(Query);
  if Length(QEmb) = 0 then Exit(KwHits);

  SemHits := RankFactsBySemantic(Active, QEmb, K);
  if Length(SemHits) = 0 then Exit(KwHits);

  { Hybrid: fuse the keyword and semantic ranks (the LoCoMo lever). }
  Result := FuseFactRanks(KwHits, SemHits, K);
end;

function BackfillFactEmbeddings(const HomeDir, Today: string): Integer;
var
  Store: IFactStore;
begin
  Result := 0;
  if not Assigned(GFactEmbed) then Exit;
  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(HomeDir)) then Exit;
  try
    Result := Store.BackfillEmbeddings(Today);
  finally
    Store.Close;
  end;
end;

type
{$IFDEF FPC}
  TQuery = TSQLQuery;
{$ELSE}
  TQuery = TFDQuery;
{$ENDIF}

  TFactStoreImpl = class(TInterfacedObject, IFactStore)
  private
    {$IFDEF FPC}
    FConn: TSQLite3Connection;
    FTx:   TSQLTransaction;
    {$ELSE}
    FConn: TFDConnection;
    {$ENDIF}
    FOpen: Boolean;
    function  NewQuery: TQuery;
    procedure PStr(Q: TQuery; const N, V: string);
    procedure PInt(Q: TQuery; const N: string; V: Int64);
    procedure PFloat(Q: TQuery; const N: string; V: Double);
    procedure Commit;
    procedure ExecSQL(const SQL: string);
    procedure EnsureSchema;
    function  ReadRows(Q: TQuery): TStoredFactArray;
    procedure RefreshFactDates(Id: Int64; const EventDate, Expires: string);
  public
    destructor Destroy; override;
    function  Open(const DbPath: string): Boolean;
    procedure Close;
    function  Add(const F: TFact; CreatedAt: Int64): Int64;
    function  ActiveFacts(const Today: string): TStoredFactArray;
    function  AllFacts: TStoredFactArray;
    function  Supersede(Id: Int64): Boolean;
    function  Delete(Id: Int64): Boolean;
    function  CountAll: Integer;
    function  CountActive(const Today: string): Integer;
    function  BackfillEmbeddings(const Today: string): Integer;
  end;

function NewFactStore: IFactStore;
begin
  Result := TFactStoreImpl.Create;
end;

destructor TFactStoreImpl.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TFactStoreImpl.NewQuery: TQuery;
begin
  Result := TQuery.Create(nil);
  {$IFDEF FPC}
  Result.Database := FConn;
  {$ELSE}
  Result.Connection := FConn;
  {$ENDIF}
end;

procedure TFactStoreImpl.PStr(Q: TQuery; const N, V: string);
begin
  {$IFDEF FPC}
  Q.Params.ParamByName(N).AsString := V;
  {$ELSE}
  Q.ParamByName(N).AsString := V;
  {$ENDIF}
end;

procedure TFactStoreImpl.PInt(Q: TQuery; const N: string; V: Int64);
begin
  {$IFDEF FPC}
  Q.Params.ParamByName(N).AsLargeInt := V;
  {$ELSE}
  Q.ParamByName(N).AsLargeInt := V;
  {$ENDIF}
end;

procedure TFactStoreImpl.PFloat(Q: TQuery; const N: string; V: Double);
begin
  {$IFDEF FPC}
  Q.Params.ParamByName(N).AsFloat := V;
  {$ELSE}
  Q.ParamByName(N).AsFloat := V;
  {$ENDIF}
end;

procedure TFactStoreImpl.Commit;
begin
  {$IFDEF FPC}
  if (FTx <> nil) and FTx.Active then FTx.CommitRetaining;
  {$ENDIF}
  { FireDAC autocommits each statement by default -- no-op on Delphi. }
end;

procedure TFactStoreImpl.ExecSQL(const SQL: string);
{$IFDEF FPC}
begin
  FConn.ExecuteDirect(SQL);
  FTx.CommitRetaining;
end;
{$ELSE}
begin
  FConn.ExecSQL(SQL);
end;
{$ENDIF}

procedure TFactStoreImpl.EnsureSchema;
begin
  ExecSQL(
    'CREATE TABLE IF NOT EXISTS facts (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  text TEXT NOT NULL,' +
    '  kind TEXT NOT NULL,' +
    '  scope TEXT NOT NULL,' +
    '  confidence REAL NOT NULL,' +
    '  event_date TEXT NOT NULL DEFAULT '''',' +
    '  expires TEXT NOT NULL DEFAULT '''',' +
    '  source_session TEXT NOT NULL DEFAULT '''',' +
    '  created_at INTEGER NOT NULL,' +
    '  superseded INTEGER NOT NULL DEFAULT 0,' +
    '  embedding TEXT NOT NULL DEFAULT '''')');
  { Indexes that match the two hot read paths (active listing + expiry sweep). }
  ExecSQL('CREATE INDEX IF NOT EXISTS idx_facts_active ON facts(superseded, expires)');
  { SQLite has no ADD COLUMN IF NOT EXISTS, so add columns that landed after
    the original schema by trying and ignoring the "duplicate column name"
    error on already-migrated databases. }
  { Phase 4c: embedding. }
  try
    ExecSQL('ALTER TABLE facts ADD COLUMN embedding TEXT NOT NULL DEFAULT ''''');
  except
    on E: Exception do ; { column already present -- fine }
  end;
  { Event-date: distinct from expires, for proactive surfacing. }
  try
    ExecSQL('ALTER TABLE facts ADD COLUMN event_date TEXT NOT NULL DEFAULT ''''');
  except
    on E: Exception do ; { column already present -- fine }
  end;
end;

function TFactStoreImpl.Open(const DbPath: string): Boolean;
begin
  Result := False;
  if FOpen then Exit(True);
  try
    EnsureDir(ExtractFilePath(DbPath));
    {$IFDEF FPC}
    FConn := TSQLite3Connection.Create(nil);
    FTx   := TSQLTransaction.Create(nil);
    FConn.DatabaseName := DbPath;
    FConn.Transaction  := FTx;
    FTx.Database       := FConn;
    FConn.Open;
    FTx.StartTransaction;
    {$ELSE}
    FConn := TFDConnection.Create(nil);
    FConn.DriverName := 'SQLite';
    FConn.Params.Values['Database'] := DbPath;
    FConn.LoginPrompt := False;
    FConn.Connected := True;
    {$ENDIF}
    EnsureSchema;
    FOpen := True;
    Result := True;
    LogDebug('memory.facts: opened %s', [DbPath]);
  except
    on E: Exception do
    begin
      LogWarn('memory.facts: failed to open %s (%s) -- fact store disabled',
              [DbPath, E.Message]);
      {$IFDEF FPC}
      FreeAndNil(FTx);
      {$ENDIF}
      FreeAndNil(FConn);
      FOpen := False;
    end;
  end;
end;

procedure TFactStoreImpl.Close;
begin
  if not FOpen then Exit;
  try
    {$IFDEF FPC}
    if (FTx <> nil) and FTx.Active then FTx.Commit;
    if (FConn <> nil) and FConn.Connected then FConn.Close;
    FreeAndNil(FTx);
    {$ELSE}
    if (FConn <> nil) and FConn.Connected then FConn.Connected := False;
    {$ENDIF}
    FreeAndNil(FConn);
  except
    on E: Exception do
      LogWarn('memory.facts: close error: %s', [E.Message]);
  end;
  FOpen := False;
end;

function TFactStoreImpl.Add(const F: TFact; CreatedAt: Int64): Int64;
var
  Q: TQuery;
  TodayStr, EmbHex: string;
  Emb: TArray<Single>;
  Active: TStoredFactArray;
  i: Integer;
  Best: Double;
begin
  Result := 0;
  if not FOpen then Exit;
  { Exact-text dedup: per-turn auto-distill keeps re-surfacing the same
    wording, so if an ACTIVE fact already has this exact text (case-
    insensitive) return its id instead of inserting a duplicate. Cheap;
    paraphrase/semantic dedup is a later phase.

    Must use the SAME active predicate as ActiveFacts -- skip EXPIRED
    rows too. Otherwise a re-observed fact whose old copy has expired
    would match the stale row and never re-enter active memory. "today"
    is the date this fact is being created (CreatedAt). }
  TodayStr := FormatDateTime('yyyy"-"mm"-"dd', UnixToDateTime(CreatedAt, False));
  Q := NewQuery;
  try
    Q.SQL.Text :=
      'SELECT id FROM facts WHERE superseded = 0 ' +
      'AND (expires = '''' OR expires >= :today) ' +
      'AND lower(text) = lower(:t) LIMIT 1';
    PStr(Q, 'today', TodayStr);
    PStr(Q, 't', F.Text);
    Q.Open;
    if not Q.EOF then
    begin
      Result := Q.Fields[0].AsLargeInt;
      Q.Close;
      { Re-observed fact: fold in any newly supplied dates so a later
        `add ... --event` (or a distil pass that learns the date) onto an
        existing/undated row isn't silently dropped. }
      RefreshFactDates(Result, F.EventDate, F.Expires);
      Exit;
    end;
    Q.Close;
  finally
    Q.Free;
  end;

  { Semantic dedup (Phase 4c): embed the new fact and, if it's near-
    identical in meaning to an existing ACTIVE fact (cosine >= threshold),
    treat it as the same and return that id -- this catches paraphrases
    the exact-text check misses. No-op when no embedder is wired. }
  EmbHex := '';
  if Assigned(GFactEmbed) then
  begin
    Emb := GFactEmbed(F.Text);
    if Length(Emb) > 0 then
    begin
      EmbHex := EmbToHex(Emb);
      Active := ActiveFacts(TodayStr);
      for i := 0 to High(Active) do
      begin
        if Active[i].EmbeddingHex = '' then Continue;
        Best := CosineSim(Emb, HexToEmb(Active[i].EmbeddingHex));
        if Best >= SemanticDedupThreshold then
        begin
          Result := Active[i].Id;   { paraphrase of an existing fact }
          RefreshFactDates(Result, F.EventDate, F.Expires);
          Exit;
        end;
      end;
    end;
  end;

  Q := NewQuery;
  try
    Q.SQL.Text :=
      'INSERT INTO facts (text, kind, scope, confidence, event_date, expires, ' +
      'source_session, created_at, superseded, embedding) ' +
      'VALUES (:t, :k, :sc, :cf, :ev, :ex, :ss, :ca, 0, :emb)';
    PStr  (Q, 't',  F.Text);
    PStr  (Q, 'k',  F.Kind);
    PStr  (Q, 'sc', F.Scope);
    PFloat(Q, 'cf', F.Confidence);
    PStr  (Q, 'ev', F.EventDate);
    PStr  (Q, 'ex', F.Expires);
    PStr  (Q, 'ss', F.SourceSession);
    PInt  (Q, 'ca', CreatedAt);
    PStr  (Q, 'emb', EmbHex);
    Q.ExecSQL;
    Commit;
    Q.SQL.Text := 'SELECT last_insert_rowid()';
    Q.Open;
    if not Q.EOF then Result := Q.Fields[0].AsLargeInt;
    Q.Close;
  finally
    Q.Free;
  end;
end;

procedure TFactStoreImpl.RefreshFactDates(Id: Int64;
  const EventDate, Expires: string);
{ Fold newly-supplied dates into a row a re-observed fact deduped onto.
  Only NON-empty incoming values overwrite -- we never blank an existing
  date with an empty one, so a later dateless re-observation can't wipe a
  date the row already carries. No-op when neither date is supplied. }
var
  Q: TQuery;
  SetClause: string;
begin
  if not FOpen then Exit;
  SetClause := '';
  if EventDate <> '' then SetClause := 'event_date = :ev';
  if Expires <> '' then
  begin
    if SetClause <> '' then SetClause := SetClause + ', ';
    SetClause := SetClause + 'expires = :ex';
  end;
  if SetClause = '' then Exit;
  Q := NewQuery;
  try
    Q.SQL.Text := 'UPDATE facts SET ' + SetClause + ' WHERE id = :id';
    if EventDate <> '' then PStr(Q, 'ev', EventDate);
    if Expires <> '' then PStr(Q, 'ex', Expires);
    PInt(Q, 'id', Id);
    Q.ExecSQL;
    Commit;
  finally
    Q.Free;
  end;
end;

function TFactStoreImpl.ReadRows(Q: TQuery): TStoredFactArray;
var
  F: TStoredFact;
begin
  Result := nil;
  Q.Open;
  while not Q.EOF do
  begin
    F.Id            := Q.FieldByName('id').AsLargeInt;
    F.Text          := Q.FieldByName('text').AsString;
    F.Kind          := Q.FieldByName('kind').AsString;
    F.Scope         := Q.FieldByName('scope').AsString;
    F.Confidence    := Q.FieldByName('confidence').AsFloat;
    F.EventDate     := Q.FieldByName('event_date').AsString;
    F.Expires       := Q.FieldByName('expires').AsString;
    F.SourceSession := Q.FieldByName('source_session').AsString;
    F.CreatedAt     := Q.FieldByName('created_at').AsLargeInt;
    F.Superseded    := Q.FieldByName('superseded').AsLargeInt <> 0;
    F.EmbeddingHex  := Q.FieldByName('embedding').AsString;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := F;
    Q.Next;
  end;
  Q.Close;
end;

function TFactStoreImpl.ActiveFacts(const Today: string): TStoredFactArray;
var
  Q: TQuery;
begin
  Result := nil;
  if not FOpen then Exit;
  Q := NewQuery;
  try
    Q.SQL.Text :=
      'SELECT * FROM facts WHERE superseded = 0 ' +
      'AND (expires = '''' OR expires >= :today) ' +
      'ORDER BY created_at DESC, id DESC';
    PStr(Q, 'today', Today);
    Result := ReadRows(Q);
  finally
    Q.Free;
  end;
end;

function TFactStoreImpl.AllFacts: TStoredFactArray;
var
  Q: TQuery;
begin
  Result := nil;
  if not FOpen then Exit;
  Q := NewQuery;
  try
    Q.SQL.Text := 'SELECT * FROM facts ORDER BY created_at DESC, id DESC';
    Result := ReadRows(Q);
  finally
    Q.Free;
  end;
end;

function TFactStoreImpl.Supersede(Id: Int64): Boolean;
var
  Q: TQuery;
begin
  Result := False;
  if not FOpen then Exit;
  Q := NewQuery;
  try
    Q.SQL.Text := 'UPDATE facts SET superseded = 1 WHERE id = :id AND superseded = 0';
    PInt(Q, 'id', Id);
    Q.ExecSQL;
    Result := Q.RowsAffected > 0;
    Commit;
  finally
    Q.Free;
  end;
end;

function TFactStoreImpl.Delete(Id: Int64): Boolean;
var
  Q: TQuery;
begin
  Result := False;
  if not FOpen then Exit;
  Q := NewQuery;
  try
    Q.SQL.Text := 'DELETE FROM facts WHERE id = :id';
    PInt(Q, 'id', Id);
    Q.ExecSQL;
    Result := Q.RowsAffected > 0;
    Commit;
  finally
    Q.Free;
  end;
end;

function TFactStoreImpl.CountAll: Integer;
var
  Q: TQuery;
begin
  Result := 0;
  if not FOpen then Exit;
  Q := NewQuery;
  try
    Q.SQL.Text := 'SELECT COUNT(*) FROM facts';
    Q.Open;
    if not Q.EOF then Result := Q.Fields[0].AsInteger;
    Q.Close;
  finally
    Q.Free;
  end;
end;

function TFactStoreImpl.CountActive(const Today: string): Integer;
{ Same predicate as ActiveFacts(Today): not superseded AND not expired.
  Kept in lockstep so Count and the listing can't disagree (the earlier
  Count(False) only filtered superseded and over-counted expired rows). }
var
  Q: TQuery;
begin
  Result := 0;
  if not FOpen then Exit;
  Q := NewQuery;
  try
    Q.SQL.Text :=
      'SELECT COUNT(*) FROM facts WHERE superseded = 0 ' +
      'AND (expires = '''' OR expires >= :today)';
    PStr(Q, 'today', Today);
    Q.Open;
    if not Q.EOF then Result := Q.Fields[0].AsInteger;
    Q.Close;
  finally
    Q.Free;
  end;
end;

function TFactStoreImpl.BackfillEmbeddings(const Today: string): Integer;
var
  Active: TStoredFactArray;
  Emb: TArray<Single>;
  EmbHex: string;
  i: Integer;
  Q: TQuery;
begin
  Result := 0;
  if (not FOpen) or (not Assigned(GFactEmbed)) then Exit;
  Active := ActiveFacts(Today);
  for i := 0 to High(Active) do
  begin
    if Active[i].EmbeddingHex <> '' then Continue;
    Emb := GFactEmbed(Active[i].Text);
    if Length(Emb) = 0 then Continue;
    EmbHex := EmbToHex(Emb);
    Q := NewQuery;
    try
      Q.SQL.Text := 'UPDATE facts SET embedding = :e WHERE id = :id';
      PStr(Q, 'e', EmbHex);
      PInt(Q, 'id', Active[i].Id);
      Q.ExecSQL;
    finally
      Q.Free;
    end;
    Inc(Result);
  end;
  if Result > 0 then Commit;
end;

end.
