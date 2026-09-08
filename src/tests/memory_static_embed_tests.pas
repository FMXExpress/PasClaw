program memory_static_embed_tests;
(*
  Covers PasClaw.Memory.Embed.Static -- the dependency-free embedding tier
  that stands in when the ONNX model has not been provisioned -- and the
  embedder-identity contract in PasClaw.Memory.Facts that keeps two
  embedding spaces from being compared.

  The claims under test are deliberately modest, because the tier is
  lexical and not semantic. It must be:

    - deterministic and unit-length, since the vectors are persisted and
      re-read by later processes;
    - tolerant of typos and inflection, which is the thing it buys over
      the BM25 keyword tier;
    - honest about unrelated text, scoring it far below related text.

  There is NO test asserting that "car" is close to "automobile". It
  isn't, and a test claiming otherwise would be testing a fiction.

  The identity half asserts the failure this work exists to prevent: a
  vector written by one embedder must never be scored against a query
  embedded by another, and a backfill must repair rows left behind by a
  model switch.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.Memory.Distill,
  PasClaw.Memory.Facts,
  PasClaw.Memory.Embed.Static;

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

function MkFact(const Txt: string): TFact;
begin
  Result.Text          := Txt;
  Result.Kind          := 'static';
  Result.Scope         := 'project';
  Result.Confidence    := 0.9;
  Result.EventDate     := '';
  Result.Expires       := '';
  Result.SourceSession := 'test';
end;

function Sim(const A, B: string): Double;
begin
  Result := CosineSim(StaticEmbed(A), StaticEmbed(B));
end;

{ ------------------------------------------------------------------ }

procedure TestShape;
var
  V, W: TArray<Single>;
  i: Integer;
  Norm: Double;
begin
  V := StaticEmbed('the deploy script lives in bin');
  AssertEqInt(Length(V), StaticEmbedDim, 'vector has the declared dimension');

  Norm := 0;
  for i := 0 to High(V) do Norm := Norm + V[i] * V[i];
  AssertTrue(Abs(Norm - 1.0) < 1E-4, 'vector is unit length');

  { Determinism is not a nicety here: the vectors are written to disk and
    compared by a later process, so an embedder that varied run to run
    would silently rot the whole column. }
  W := StaticEmbed('the deploy script lives in bin');
  for i := 0 to High(V) do
    AssertTrue(V[i] = W[i], 'same text embeds identically every call');

  AssertTrue(Length(StaticEmbed('')) = 0, 'empty text yields no vector');
  AssertTrue(Length(StaticEmbed('   ...  !!! ')) = 0,
             'punctuation-only text yields no vector');

  AssertTrue(Pos('@', StaticEmbedderId) > 0,
             'embedder id carries a dimension suffix');
  WriteLn('  ok: shape, determinism, empty input, id format');
end;

procedure TestCrossTargetEncoding;
(* The vectors are persisted and shared between builds, so the SAME text
   must hash the same on FPC and on Delphi. It does not for free: FPC's
   `string` holds UTF-8 here, Delphi's holds UTF-16, so hashing character
   units would hash different data on the two targets -- and truncate each
   UTF-16 unit -- while both rows still claimed the same embedder id. That
   is precisely the corruption the id is supposed to prevent.

   StaticEmbed converts to UTF-8 bytes before hashing, so this fingerprint
   is a fixed function of the text. Pinning it turns a silent cross-target
   divergence into a failing test on whichever target regressed. Recompute
   it deliberately (and bump the embedder id) if the feature extraction
   ever changes -- never just paste in whatever the build prints. *)
const
  ExpectedFingerprint = LongWord($75A30107);
  (* A literal, not #$xx escapes: with the UTF-8 codepage directive in
     force, FPC reads #$C3 as the CODEPOINT U+00C3 and re-encodes it as two
     UTF-8 bytes, so escapes would spell different text than they appear
     to. A literal says "this text" correctly on both targets, which is
     exactly the claim under test. *)
  Sample = 'café déjà-vu 日本語のテキスト naïve';
var
  V: TArray<Single>;
  i: Integer;
  H: LongWord;
begin
  V := StaticEmbed(Sample);
  AssertEqInt(Length(V), StaticEmbedDim, 'non-ASCII text still embeds');
  H := 2166136261;
  for i := 0 to High(V) do
    H := (H xor LongWord(Round(V[i] * 100000))) * 16777619;
  AssertTrue(H = ExpectedFingerprint,
             Format('non-ASCII fingerprint is $%.8x, expected $%.8x -- the ' +
                    'UTF-8 encoding path changed, so vectors written by ' +
                    'another build are no longer comparable',
                    [H, ExpectedFingerprint]));
  WriteLn('  ok: non-ASCII hashes to a fixed, target-independent vector');
end;

procedure TestLexicalBehaviour;
var
  Related, Typo, Inflected, Unrelated: Double;
begin
  Related   := Sim('the deploy script lives in bin',
                   'deploy script is under bin');
  Unrelated := Sim('the deploy script lives in bin',
                   'the cat sat quietly on a warm mat');
  AssertTrue(Related > Unrelated + 0.2,
             Format('related text outscores unrelated (%.3f vs %.3f)',
                    [Related, Unrelated]));

  (* Character n-grams survive a typo -- but only in proportion to how much
     of the text is still spelled correctly, and that limit is the honest
     shape of this tier. Measured against the fact-store gate
     (RankFactsBySemantic drops anything below 0.30):

       one word of two misspelled, vs a full sentence : 0.42  -> retrieved
       BOTH words misspelled,      vs a full sentence : 0.18  -> DROPPED
       unrelated topic,            vs a full sentence : 0.10

     So a fully misspelled short query does NOT reach the fact it names,
     even though it scores well clear of noise. The earlier version of this
     test compared 'deployment configuration' with 'deploymnet
     configuration' and asserted > 0.7 -- true, but only because the second
     word matched exactly, so it measured the shared word rather than the
     typo tolerance it claimed to. Pin the real numbers instead. *)
  Typo := Sim('release chekclist',
              'The release checklist lives at docs/release.md, step 3 first.');
  AssertTrue(Typo > 0.30,
             Format('one misspelled word still clears the retrieval gate (%.3f)',
                    [Typo]));

  Typo := Sim('relaese chekclist',
              'The release checklist lives at docs/release.md, step 3 first.');
  AssertTrue((Typo > 0.12) and (Typo < 0.30),
             Format('a fully misspelled short query beats noise but does NOT ' +
                    'clear the 0.30 gate (%.3f) -- a documented limitation, ' +
                    'not an accident', [Typo]));

  Typo := Sim('relaese chekclist',
              'The database migration runs nightly at 0200 UTC on the replica.');
  AssertTrue(Typo < 0.12,
             Format('...and unrelated text stays below it (%.3f)', [Typo]));

  Inflected := Sim('deploy the release', 'deploying the releases');
  AssertTrue(Inflected > 0.5,
             Format('inflected forms stay close (%.3f)', [Inflected]));

  { Case and punctuation are normalised away. }
  AssertTrue(Sim('Deploy Script!', 'deploy script') > 0.99,
             'case and punctuation do not change the vector');

  { The honest negative: this tier knows nothing about meaning. If this
    assertion ever starts failing, the tier has changed into something
    else and its documentation is wrong. }
  AssertTrue(Sim('car', 'automobile') < 0.3,
             'synonyms are NOT close -- this tier is lexical, not semantic');

  WriteLn('  ok: typo / inflection tolerance, and no false semantics');
end;

{ ------------------------------------------------------------------ }
{ Identity: vectors from different embedders must never be compared.    }

{ Two fake embedders that share a dimension but not a space. This is the
  dangerous case -- CosineSim's length guard cannot catch it, so only the
  stored id can. }
function EmbedSpaceA(const Text: string): TArray<Single>;
begin
  SetLength(Result, 4);
  Result[0] := 1; Result[1] := 0; Result[2] := 0; Result[3] := 0;
  if Pos('beta', LowerCase(Text)) > 0 then begin Result[0] := 0; Result[1] := 1; end;
end;

function EmbedSpaceB(const Text: string): TArray<Single>;
begin
  SetLength(Result, 4);
  Result[0] := 0; Result[1] := 0; Result[2] := 1; Result[3] := 0;
  if Pos('beta', LowerCase(Text)) > 0 then begin Result[2] := 0; Result[3] := 1; end;
end;

procedure TestEmbedderIdentity;
var
  Store: IFactStore;
  Db, Today: string;
  Facts: TStoredFactArray;
  Hits: TStoredFactArray;
  Filled: Integer;
begin
  { The DEFAULT path for GTmpDir, not an arbitrary file: SearchActiveFacts
    below takes a home directory and resolves the store itself, so a store
    opened anywhere else would leave it searching an empty database and
    the assertion would pass for the wrong reason. }
  Db := DefaultFactsDbPath(GTmpDir);
  EnsureDir(ExtractFileDir(Db));
  Today := '2026-01-01';

  SetFactEmbedder(@EmbedSpaceA, 'spaceA@4');
  Store := NewFactStore;
  AssertTrue(Store.Open(Db), 'store opens');
  try
    Store.Add(MkFact('alpha release notes'), 1700000000);
    Store.Add(MkFact('beta release notes'), 1700000001);
    Facts := Store.ActiveFacts(Today);
    AssertEqInt(Length(Facts), 2, 'both facts stored');
    AssertTrue(Facts[0].EmbedModel = 'spaceA@4',
               'the writing embedder is recorded on the row');
    AssertTrue(Facts[0].EmbeddingHex <> '', 'a vector was stored');
  finally
    Store.Close;
  end;

  { Switch to a DIFFERENT embedder of the SAME dimension. The stored
    vectors are now meaningless in the new space; the id is the only
    thing standing between us and confidently wrong neighbours. }
  SetFactEmbedder(@EmbedSpaceB, 'spaceB@4');
  Store := NewFactStore;
  AssertTrue(Store.Open(Db), 'store reopens');
  try
    Facts := Store.ActiveFacts(Today);
    AssertTrue(Facts[0].EmbedModel <> FactEmbedderId,
               'stored rows are from the previous space');

    { Backfill must rewrite them rather than leave them stranded. }
    Filled := Store.BackfillEmbeddings(Today);
    AssertEqInt(Filled, 2, 'backfill re-embeds rows from another space');
    Facts := Store.ActiveFacts(Today);
    AssertTrue(Facts[0].EmbedModel = 'spaceB@4',
               'rows now carry the active embedder id');
    AssertTrue(Facts[1].EmbedModel = 'spaceB@4',
               'every row was migrated, not just the first');

    { A second backfill has nothing to do -- otherwise every startup would
      rewrite the whole table. }
    AssertEqInt(Store.BackfillEmbeddings(Today), 0,
                'backfill is idempotent once the space matches');
  finally
    Store.Close;
  end;

  Hits := SearchActiveFacts(GTmpDir, Today, 'beta', 5);
  AssertTrue(Length(Hits) >= 1, 'search still returns results after a switch');

  SetFactEmbedder(nil, '');
  AssertTrue(not FactEmbedderActive, 'embedder cleared');

  { An embedder that cannot be named cannot be attributed, so it is
    refused outright rather than allowed to write unlabelled rows. }
  SetFactEmbedder(@EmbedSpaceA, '   ');
  AssertTrue(not FactEmbedderActive,
             'an embedder with a blank id is refused');

  WriteLn('  ok: embedder identity recorded, enforced, and backfilled');
end;

{ ------------------------------------------------------------------ }
{ The dedup gate: a lexical tier ranks but must not merge.              }

procedure TestDedupGate;
var
  Store: IFactStore;
  Db: string;
  A, B: Int64;
begin
  Db := JoinPath(GTmpDir, 'dedupgate.db');

  { Registered WITHOUT dedup rights, as the static tier is. Two facts
    that a lexical score would call near-identical must stay distinct. }
  SetFactEmbedder(@StaticEmbed, StaticEmbedderId, {AllowSemanticDedup=} False);
  AssertTrue(FactEmbedderActive, 'embedder active');
  AssertTrue(not FactEmbedderDedups, 'this tier is not trusted to merge');

  Store := NewFactStore;
  AssertTrue(Store.Open(Db), 'store opens');
  try
    A := Store.Add(MkFact('The build runs on Linux and Windows.'), 1700000000);
    B := Store.Add(MkFact('The build runs on Windows and Linux.'), 1700000001);
    AssertTrue(A <> B,
               'a non-dedup embedder keeps near-identical facts distinct');
    AssertEqInt(Store.CountAll, 2, 'both rows survive');

    { It still writes vectors -- search wants them; only the destructive
      merge is withheld. }
    AssertTrue(Store.ActiveFacts('2026-01-01')[0].EmbeddingHex <> '',
               'vectors are stored even when dedup is off');
  finally
    Store.Close;
  end;

  SetFactEmbedder(nil, '');
  WriteLn('  ok: lexical tier ranks without being trusted to merge');
end;

{ ------------------------------------------------------------------ }

var
  GHookCalls: Integer = 0;

procedure FakeEnsureHook;
begin
  Inc(GHookCalls);
  SetFactEmbedder(@StaticEmbed, StaticEmbedderId, {AllowSemanticDedup=} False);
end;

procedure TestLazyEmbedderHook;
(* Registering the memory tools does not register an embedder. Several
   hosts -- PasClaw.Agent, Cmd.Heartbeat, the PasClaw.Tools bundle -- do
   exactly that, and every fact they wrote would carry no vector. The store
   therefore asks for one, once, at the point it needs it. *)
var
  Store: IFactStore;
  Db: string;
  Facts: TStoredFactArray;
begin
  Db := JoinPath(GTmpDir, 'lazy.db');
  SetFactEmbedder(nil, '');
  GHookCalls := 0;
  SetEnsureEmbedderHook(@FakeEnsureHook);
  AssertTrue(not FactEmbedderActive, 'no embedder before the first write');

  Store := NewFactStore;
  AssertTrue(Store.Open(Db), 'store opens');
  try
    Store.Add(MkFact('a host that never called EnableBestFactEmbedder'), 1700000000);
    AssertEqInt(GHookCalls, 1, 'the write asked for an embedder');
    AssertTrue(FactEmbedderActive, 'and one is now active');
    Facts := Store.ActiveFacts('2026-01-01');
    AssertTrue(Facts[0].EmbeddingHex <> '',
               'so the row was written WITH a vector, not without one');

    { Once per process, not once per write: a host with no embedder
      available must not re-probe the filesystem on every fact. }
    Store.Add(MkFact('a second fact from the same host'), 1700000001);
    AssertEqInt(GHookCalls, 1, 'the hook is not re-run once one is active');
  finally
    Store.Close;
  end;

  SetEnsureEmbedderHook(nil);
  SetFactEmbedder(nil, '');
  WriteLn('  ok: a host with no explicit enable call still gets vectors');
end;

procedure TestDateValidation;
(* Shape is not validity. Both of these are well-formed and name no date,
   and because expiry is compared as text an impossible one sorts above
   every real date -- so the fact would never expire, silently. *)
begin
  AssertTrue(IsValidISODateOrEmpty(''), 'empty means "no date"');
  AssertTrue(IsValidISODateOrEmpty('2026-06-27'), 'a real date passes');
  AssertTrue(IsValidISODateOrEmpty('2028-02-29'), 'a real leap day passes');
  AssertTrue(not IsValidISODateOrEmpty('2027-02-29'), 'a non-leap Feb 29 fails');
  AssertTrue(not IsValidISODateOrEmpty('2026-99-99'), 'month 99 fails');
  AssertTrue(not IsValidISODateOrEmpty('2026-02-31'), 'February 31 fails');
  AssertTrue(not IsValidISODateOrEmpty('2026-6-27'),  'unpadded fails');
  AssertTrue(not IsValidISODateOrEmpty('tomorrow'),   'prose fails');
  WriteLn('  ok: only dates that exist are accepted');
end;

begin
  GTmpDir := JoinPath(GetTempDir, 'pasclaw-static-embed-' + IntToStr(Random(1 shl 30)));
  EnsureDir(GTmpDir);
  TestShape;
  TestCrossTargetEncoding;
  TestLexicalBehaviour;
  TestEmbedderIdentity;
  TestDedupGate;
  TestLazyEmbedderHook;
  TestDateValidation;
  WriteLn('PASS');
end.
