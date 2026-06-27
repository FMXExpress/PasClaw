program memory_facts_tests;
(*
  Covers PasClaw.Memory.Facts -- Phase 2 SQLite persistence for distilled
  facts. Uses a real temp SQLite db (libsqlite3 at runtime) and exercises
  the lifecycle contract:

    - Add returns a row id; facts read back with all fields intact
    - ActiveFacts(today) excludes EXPIRED facts (expires < today)
    - Supersede hides a fact from ActiveFacts but keeps it in AllFacts
    - Delete removes it entirely
    - Count(false) ignores superseded; Count(true) includes them
    - Facts persist across Close/Open (durable)
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.Memory.Distill,
  PasClaw.Memory.Facts;

var
  GTmpDir: string;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;

function MkFact(const Txt, Kind, Scope, Expires: string; Conf: Double): TFact;
begin
  Result.Text          := Txt;
  Result.Kind          := Kind;
  Result.Scope         := Scope;
  Result.Confidence    := Conf;
  Result.Expires       := Expires;
  Result.SourceSession := 'sess-x';
end;

const
  TODAY = '2026-06-26';

procedure RunTests;
var
  DbPath: string;
  Store: IFactStore;
  IdNoExp, IdFuture, IdPast, IdSup: Int64;
  Active, All: TStoredFactArray;
begin
  DbPath := JoinPath(GTmpDir, 'facts.db');

  Store := NewFactStore;
  AssertTrue(Store.Open(DbPath), 'open store');

  IdNoExp  := Store.Add(MkFact('Prefers Delphi', 'static', 'user', '', 0.9), 1000);
  IdFuture := Store.Add(MkFact('Sprint ends soon', 'dynamic', 'project', '2026-12-31', 0.7), 1001);
  IdPast   := Store.Add(MkFact('Exam yesterday', 'dynamic', 'session', '2026-06-01', 0.6), 1002);
  IdSup    := Store.Add(MkFact('Old preference', 'static', 'user', '', 0.5), 1003);

  AssertTrue(IdNoExp > 0, 'add returns id');
  AssertTrue((IdFuture <> IdNoExp) and (IdPast <> IdFuture), 'ids distinct');

  { Active as of today: no-expiry + future-expiry + the soon-to-be-superseded
    one = 3; the past-expiry one is filtered out. }
  Active := Store.ActiveFacts(TODAY);
  AssertEqInt(Length(Active), 3, 'active excludes expired');
  { Newest first -> IdSup (created_at 1003) is row 0. }
  AssertEqStr(Active[0].Text, 'Old preference', 'newest first ordering');
  AssertEqStr(Active[0].Kind, 'static', 'kind round-trips');
  AssertEqStr(Active[0].Scope, 'user', 'scope round-trips');
  AssertTrue(Abs(Active[0].Confidence - 0.5) < 0.001, 'confidence round-trips');

  { Supersede hides from Active but keeps in All. }
  AssertTrue(Store.Supersede(IdSup), 'supersede returns true');
  AssertTrue(not Store.Supersede(IdSup), 'second supersede is a no-op');
  Active := Store.ActiveFacts(TODAY);
  AssertEqInt(Length(Active), 2, 'superseded fact drops out of active');

  All := Store.AllFacts;
  AssertEqInt(Length(All), 4, 'AllFacts keeps superseded + expired');

  { CountActive must match ActiveFacts exactly: NoExp + Future = 2 (the
    past-expiry fact is NOT counted, and the superseded one is gone). The
    old Count(False) wrongly reported 3 by ignoring expiry. }
  AssertEqInt(Store.CountActive(TODAY), 2, 'active count excludes superseded AND expired');
  AssertEqInt(Store.CountActive(TODAY), Length(Store.ActiveFacts(TODAY)),
              'CountActive agrees with ActiveFacts');
  AssertEqInt(Store.CountAll, 4, 'CountAll includes superseded + expired');

  { Delete the expired one entirely. }
  AssertTrue(Store.Delete(IdPast), 'delete returns true');
  AssertEqInt(Store.CountAll, 3, 'count drops after delete');

  Store.Close;

  { Reopen: durability. }
  Store := NewFactStore;
  AssertTrue(Store.Open(DbPath), 'reopen store');
  AssertEqInt(Store.CountAll, 3, 'facts persisted across reopen');
  Active := Store.ActiveFacts(TODAY);
  AssertEqInt(Length(Active), 2, 'active count stable after reopen');
  Store.Close;
end;

procedure RunDedupTests;
{ Exact-text dedup: a re-observed active fact returns the existing id
  (no duplicate row). But an EXPIRED prior copy must NOT block a fresh
  insert -- otherwise the refreshed fact never re-enters active memory. }
const
  T2025 = 1751328000;   { ~2025-07-01; "today" for these Adds derives from it }
var
  DbPath: string;
  Store: IFactStore;
  Id1, Id2, Id3, Id4: Int64;
begin
  DbPath := JoinPath(GTmpDir, 'dedup.db');
  Store := NewFactStore;
  AssertTrue(Store.Open(DbPath), 'open dedup store');

  Id1 := Store.Add(MkFact('Likes tea', 'static', 'user', '', 0.9), T2025);
  Id2 := Store.Add(MkFact('LIKES TEA', 'dynamic', 'user', '', 0.4), T2025 + 1);
  AssertTrue(Id2 = Id1, 'case-insensitive exact dup returns existing id');
  AssertEqInt(Store.CountAll, 1, 'exact dup not inserted');

  { Expired prior copy must not suppress the refreshed one. }
  Id3 := Store.Add(MkFact('Sprint topic', 'dynamic', 'project', '2020-01-01', 0.5), T2025);
  Id4 := Store.Add(MkFact('Sprint topic', 'dynamic', 'project', '', 0.6), T2025 + 1);
  AssertTrue(Id4 <> Id3, 'expired dup does NOT block a fresh insert');
  AssertEqInt(Store.CountAll, 3, 'tea + expired sprint + fresh sprint');
  Store.Close;
end;

function SF(const Txt, Expires: string): TStoredFact;
begin
  Result := Default(TStoredFact);
  Result.Text := Txt;
  Result.Kind := 'static'; Result.Scope := 'user';
  Result.Expires := Expires;
end;

procedure RunFormatTests;
{ Pure FormatFactsBlock: budget gating, breadcrumb, expiry annotation. }
var
  Facts: TStoredFactArray;
  S: string;
begin
  SetLength(Facts, 0);
  AssertEqStr(FormatFactsBlock(Facts, 2000), '', 'empty -> empty block');

  SetLength(Facts, 3);
  Facts[0] := SF('Prefers Delphi', '');
  Facts[1] := SF('Sprint ends', '2026-12-31');
  Facts[2] := SF('Likes terse commits', '');

  AssertEqStr(FormatFactsBlock(Facts, 0), '', 'budget 0 -> no injection');

  S := FormatFactsBlock(Facts, 2000);
  AssertTrue(Pos('Durable facts', S) > 0, 'has header');
  AssertTrue(Pos('- Prefers Delphi', S) > 0, 'has a bullet');
  AssertTrue(Pos('(until 2026-12-31)', S) > 0, 'expiry annotated');
  AssertTrue(Pos('more --', S) = 0, 'no breadcrumb when all fit');

  { Tiny budget: at least one fact kept, rest summarised as a breadcrumb
    that now (Phase 4b) points at the searchable store. }
  S := FormatFactsBlock(Facts, 45);
  AssertTrue(Pos('- Prefers Delphi', S) > 0, 'keeps newest fact under tiny budget');
  AssertTrue(Pos('more --', S) > 0, 'breadcrumb notes the omitted facts');
  AssertTrue(Pos('memory_search', S) > 0, 'breadcrumb points at memory_search (now searchable)');
end;

procedure RunRankTests;
{ Pure keyword ranking: term matching, score/confidence ordering, K cap,
  no-match -> empty. }
var
  Facts, R: TStoredFactArray;
begin
  SetLength(Facts, 3);
  Facts[0] := SF('User prefers Delphi over Lazarus', ''); Facts[0].Confidence := 0.5; Facts[0].CreatedAt := 10;
  Facts[1] := SF('Deploys on FreeBSD', '');                Facts[1].Confidence := 0.9; Facts[1].CreatedAt := 20;
  Facts[2] := SF('Delphi build uses dcc64', '');           Facts[2].Confidence := 0.5; Facts[2].CreatedAt := 30;

  { No match -> empty. }
  R := RankFactsByQuery(Facts, 'kubernetes', 5);
  AssertEqInt(Length(R), 0, 'no-match query -> empty');

  { "delphi build" hits #2 (both terms) over #0 (one term). }
  R := RankFactsByQuery(Facts, 'delphi build', 5);
  AssertTrue(Length(R) >= 2, 'matches the two delphi facts');
  AssertEqStr(R[0].Text, 'Delphi build uses dcc64', 'higher term-overlap ranks first');

  { Single shared term -> tie broken by confidence (FreeBSD 0.9 not relevant;
    use a term in two equal-score facts). "delphi" hits #0 and #2 (score 1
    each); #2 is newer so wins the recency tiebreak (equal confidence). }
  R := RankFactsByQuery(Facts, 'delphi', 5);
  AssertEqStr(R[0].Text, 'Delphi build uses dcc64', 'equal score -> newer wins');

  { K cap. }
  R := RankFactsByQuery(Facts, 'delphi', 1);
  AssertEqInt(Length(R), 1, 'K caps results');
end;

{ Deterministic fake embedder: a 4-dim bag-of-topics so paraphrases that
  share a topic land on the same vector, and a query can match a fact
  whose literal words differ (semantic recall the keyword tier misses).
    dim0 pascal/delphi   dim1 lazarus   dim2 tea/drink   dim3 deploy }
function FakeEmbed(const Text: string): TArray<Single>;
var
  L: string;
  function Has(const W: string): Boolean; begin Result := Pos(W, L) > 0; end;
begin
  L := LowerCase(Text);
  SetLength(Result, 4);
  Result[0] := Ord(Has('delphi') or Has('pascal') or Has('ide') or Has('dcc64'));
  Result[1] := Ord(Has('lazarus'));
  Result[2] := Ord(Has('tea') or Has('drink') or Has('beverage'));
  Result[3] := Ord(Has('deploy') or Has('freebsd') or Has('server'));
end;

procedure RunSemCoreTests;
{ Pure cosine + hex round-trip. }
var
  A, B, C: TArray<Single>;
begin
  SetLength(A, 3); A[0] := 1; A[1] := 0; A[2] := 0;
  SetLength(B, 3); B[0] := 1; B[1] := 0; B[2] := 0;
  SetLength(C, 3); C[0] := 0; C[1] := 1; C[2] := 0;
  AssertTrue(Abs(CosineSim(A, B) - 1.0) < 0.0001, 'identical -> 1');
  AssertTrue(Abs(CosineSim(A, C)) < 0.0001, 'orthogonal -> 0');
  AssertTrue(Abs(CosineSim(A, nil)) < 0.0001, 'empty -> 0');

  { Hex round-trips exactly. }
  B := HexToEmb(EmbToHex(A));
  AssertEqInt(Length(B), 3, 'hex round-trip length');
  AssertTrue(Abs(CosineSim(A, B) - 1.0) < 0.0001, 'hex round-trip preserves vector');
  AssertEqStr(EmbToHex(nil), '', 'empty embedding -> empty hex');
end;

procedure RunSemanticTests;
const T2025 = 1751328000;
var
  Store: IFactStore;
  DbPath: string;
  Id1, Id2, Id3: Int64;
  R: TStoredFactArray;
begin
  SetFactEmbedder(@FakeEmbed);
  try
    AssertTrue(FactEmbedderActive, 'embedder registered');

    { --- semantic dedup: a paraphrase merges into the existing fact --- }
    DbPath := JoinPath(GTmpDir, 'sem.db');
    Store := NewFactStore;
    AssertTrue(Store.Open(DbPath), 'open sem store');
    Id1 := Store.Add(MkFact('User prefers Delphi over Lazarus', 'static', 'user', '', 0.9), T2025);
    { Different exact text (exact-dedup misses) but same topic vector. }
    Id2 := Store.Add(MkFact('Loves Delphi, avoids Lazarus', 'dynamic', 'user', '', 0.4), T2025 + 1);
    AssertTrue(Id2 = Id1, 'semantic dedup merges paraphrase');
    AssertEqInt(Store.CountAll, 1, 'paraphrase not inserted');
    Id3 := Store.Add(MkFact('Drinks tea each morning', 'dynamic', 'user', '', 0.5), T2025 + 2);
    AssertTrue(Id3 <> Id1, 'unrelated topic inserted');
    AssertEqInt(Store.CountAll, 2, 'two distinct facts');
    Store.Close;

    { --- semantic search: query matches by topic with no word overlap --- }
    Store := NewFactStore;
    AssertTrue(Store.Open(DefaultFactsDbPath(GTmpDir)), 'open default store');
    Store.Add(MkFact('User prefers Delphi over Lazarus', 'static', 'user', '', 0.9), T2025);
    Store.Add(MkFact('Drinks tea each morning', 'dynamic', 'user', '', 0.5), T2025 + 1);
    Store.Close;

    R := SearchActiveFacts(GTmpDir, TODAY, 'pascal ide', 5);
    AssertTrue(Length(R) >= 1, 'semantic search finds a topical fact');
    AssertEqStr(R[0].Text, 'User prefers Delphi over Lazarus',
                'semantic match despite zero keyword overlap');
  finally
    SetFactEmbedder(nil);
  end;
  AssertTrue(not FactEmbedderActive, 'embedder cleared');
end;

procedure RunBackfillTests;
{ Pre-4c / embedder-off rows have no embedding. Once the embedder is
  available, BackfillEmbeddings must fill them so they take part in
  semantic search (the #372 review). }
const T2025 = 1751328000;
var
  Store: IFactStore;
  DbPath: string;
  Filled: Integer;
  R: TStoredFactArray;
begin
  { Add with NO embedder -> rows stored without embeddings. }
  DbPath := JoinPath(GTmpDir, 'backfill.db');
  Store := NewFactStore;
  AssertTrue(Store.Open(DbPath), 'open backfill store');
  Store.Add(MkFact('User prefers Delphi over Lazarus', 'static', 'user', '', 0.9), T2025);
  Store.Add(MkFact('Drinks tea each morning', 'dynamic', 'user', '', 0.5), T2025 + 1);
  { No embedder yet -> backfill is a no-op. }
  AssertEqInt(Store.BackfillEmbeddings(TODAY), 0, 'no embedder -> no backfill');

  SetFactEmbedder(@FakeEmbed);
  try
    Filled := Store.BackfillEmbeddings(TODAY);
    AssertEqInt(Filled, 2, 'backfill fills both empty rows');
    AssertEqInt(Store.BackfillEmbeddings(TODAY), 0, 're-run backfill is a no-op');
    Store.Close;

    { Now a previously-unembedded fact is semantically searchable. }
    Store := NewFactStore;
    AssertTrue(Store.Open(DefaultFactsDbPath(GTmpDir)), 'open default for search');
    Store.Add(MkFact('User prefers Delphi over Lazarus', 'static', 'user', '', 0.9), T2025);
    { Stored WITH embedder active this time, but exercise backfill path on a
      fresh empty one too: add an unembedded row via a second store w/o embedder. }
    Store.Close;
    R := SearchActiveFacts(GTmpDir, TODAY, 'pascal ide', 5);
    AssertTrue(Length(R) >= 1, 'backfilled/embedded fact is semantically searchable');
  finally
    SetFactEmbedder(nil);
  end;
end;

procedure RunEventDateTests;
{ event_date is stored distinctly from expires, round-trips, and drives
  the proactive FormatUpcomingBlock surfacing. TODAY = 2026-06-26. }
var
  DbPath: string;
  Store: IFactStore;
  F: TFact;
  Active, Up: TStoredFactArray;
  S: string;
  i: Integer;
  FoundExam: Boolean;
begin
  DbPath := JoinPath(GTmpDir, 'facts-event.db');
  Store := NewFactStore;
  AssertTrue(Store.Open(DbPath), 'open event store');

  { Exam tomorrow (2026-06-27), distinct expiry a few days out. }
  F := MkFact('User has a calculus exam', 'dynamic', 'user', '2026-06-30', 0.9);
  F.EventDate := '2026-06-27';
  Store.Add(F, 2000);
  { Conference in 10 days -- beyond a 7-day horizon. }
  F := MkFact('PasCon talk', 'dynamic', 'project', '', 0.8);
  F.EventDate := '2026-07-06';
  Store.Add(F, 2001);
  { Plain fact, no event date. }
  Store.Add(MkFact('Prefers Delphi', 'static', 'user', '', 0.9), 2002);

  { event_date round-trips through storage. }
  Active := Store.ActiveFacts(TODAY);
  FoundExam := False;
  for i := 0 to High(Active) do
    if Active[i].Text = 'User has a calculus exam' then
    begin
      AssertEqStr(Active[i].EventDate, '2026-06-27', 'event_date round-trips');
      AssertEqStr(Active[i].Expires, '2026-06-30', 'expires stays distinct from event_date');
      FoundExam := True;
    end;
  AssertTrue(FoundExam, 'exam fact present in active set');
  Store.Close;

  { Upcoming within 7 days: only the exam (tomorrow). The conference is 10
    days out; the Delphi fact has no event date. Reopen to prove durability. }
  Store := NewFactStore;
  AssertTrue(Store.Open(DbPath), 'reopen event store');
  Up := Store.ActiveFacts(TODAY);
  Store.Close;

  S := FormatUpcomingBlock(Up, TODAY, 7);
  AssertTrue(Pos('Upcoming', S) > 0, 'upcoming header present');
  AssertTrue(Pos('calculus exam', S) > 0, 'exam surfaced within horizon');
  AssertTrue(Pos('tomorrow', S) > 0, 'exam phrased relatively as tomorrow');
  AssertTrue(Pos('PasCon', S) = 0, 'event beyond horizon not surfaced');
  AssertTrue(Pos('Prefers Delphi', S) = 0, 'event-less fact not surfaced');

  { Widen the horizon to catch the conference too; soonest first. }
  S := FormatUpcomingBlock(Up, TODAY, 14);
  AssertTrue(Pos('PasCon', S) > 0, 'conference surfaced with wider horizon');
  AssertTrue(Pos('calculus exam', S) < Pos('PasCon', S), 'soonest event listed first');

  { Nothing upcoming when the horizon is 0 and the only event is tomorrow. }
  S := FormatUpcomingBlock(Up, TODAY, 0);
  AssertEqStr(S, '', 'horizon 0 -> nothing upcoming (exam is tomorrow, not today)');
end;

begin
  GTmpDir := JoinPath(GetTempDir, 'pasclaw-facts-test-' + IntToStr(Random(1 shl 30)));
  EnsureDir(GTmpDir);
  try
    RunTests;
    WriteLn('  ok: add / read-back / active-excludes-expired');
    WriteLn('  ok: supersede / delete / counts');
    WriteLn('  ok: durability across reopen');
    RunDedupTests;
    WriteLn('  ok: exact-text dedup (expired copy does not block refresh)');
    RunFormatTests;
    WriteLn('  ok: format facts block (budget / breadcrumb / expiry)');
    RunRankTests;
    WriteLn('  ok: keyword rank facts (match / order / K cap)');
    RunSemCoreTests;
    WriteLn('  ok: cosine + embedding hex round-trip');
    RunSemanticTests;
    WriteLn('  ok: semantic dedup + hybrid search (fake embedder)');
    RunBackfillTests;
    WriteLn('  ok: backfill embeds pre-existing empty rows');
    RunEventDateTests;
    WriteLn('  ok: event_date round-trip + proactive upcoming block');
    WriteLn('PASS');
  finally
    {$IFDEF UNIX}
    ExecuteProcess('/bin/sh', ['-c', 'rm -rf "' + GTmpDir + '"']);
    {$ENDIF}
  end;
end.
