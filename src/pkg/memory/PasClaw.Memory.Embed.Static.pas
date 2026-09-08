(*
  PasClaw.Memory.Embed.Static - an always-available embedding tier.

  The ONNX embedder (PasClaw.Memory.Facts.Embed, LocalVector.Embedder) is
  the good one, but it costs a ~90 MB model download AND a native ONNX
  Runtime library. Until `pasclaw memory provision` has run, the fact
  store's semantic layer is simply absent: SetFactEmbedder is never called,
  dedup falls back to exact text, and search falls back to keyword ranking.
  On a machine that will never provision -- a CI box, a container, a user
  who does not want a 90 MB download -- that is a permanent downgrade.

  This unit fills that gap with an embedder that needs nothing: no model
  file, no runtime, no vocabulary. It is the hashing trick (feature hashing
  / random indexing) over word unigrams and character n-grams, which is a
  1990s idea that keeps working: hash each feature to a bucket, accumulate
  a signed count, squash, normalise.

  WHAT IT IS NOT
  --------------
  This is a LEXICAL embedding, not a semantic one. It scores "the deploy
  script lives in bin/" and "deployment script is under bin" as similar
  because they share words and letter sequences. It scores "car" and
  "automobile" as unrelated, because nothing here has ever read a corpus.
  Anything claiming otherwise is claiming a static hash learned meaning.

  So what is it FOR? Two things the keyword tier does badly:

    - morphology and typos. BM25 with a Porter stemmer matches
      "deploying"/"deploy" but not "deploymnet"; character 4-grams do.
    - a usable vector column from turn one, so the hybrid RRF path has two
      ranks to fuse instead of one, and so a database is never left with a
      mix of embedded and unembedded rows just because provisioning
      happened late.

  Deliberately NOT used for semantic dedup. Merging two facts is
  destructive and irreversible, and a lexical score of 0.85 between two
  genuinely different facts is far more likely than it is for a real
  encoder. The dedup path keys on the embedder id, so this tier simply
  never reaches that threshold check -- see EmbedderId below and the
  filtering in PasClaw.Memory.Facts.

  If a static SEMANTIC tier is wanted later, the model2vec / potion family
  is the right shape for it: a distilled token-vector table, ~8-30 MB of
  data with no native runtime, mean-pooled over the same tokenizer
  LocalVector.Tokenizer already implements. That is a data download, so it
  belongs beside the ONNX tier rather than here; this unit is specifically
  the tier that needs nothing at all.
*)
unit PasClaw.Memory.Embed.Static;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

const
  { Bucket count. 256 Singles = 1 KB per vector, ~2 KB as the hex the fact
    store persists. Large enough that collisions between the few hundred
    distinct features of a one-sentence fact stay rare; small enough that
    storing one on every row is not a burden. }
  StaticEmbedDim = 256;

  { Character n-gram width. 4 is the usual sweet spot for short English
    text: long enough to be more than a letter-bag, short enough to still
    overlap across a one-character typo. }
  StaticEmbedGram = 4;

{ Identity of this embedding space, in the '<name>@<dim>' form
  PasClaw.Memory.Facts stores on every vector. Bump the version segment on
  ANY change to the feature extraction or hashing below -- an old vector
  and a new one would otherwise be compared as if they came from the same
  space, which is the exact failure the id exists to prevent. }
function StaticEmbedderId: string;

{ Embed Text into a unit-length vector of StaticEmbedDim Singles.
  Returns [] for text with no usable features (empty, or punctuation
  only), matching the TFactEmbedFn contract. Pure and deterministic:
  the same text yields the same vector on every platform and run, which
  is what makes the persisted vectors reusable across processes. }
function StaticEmbed(const Text: string): TArray<Single>;

implementation

uses
  { Classes for TBytes on FPC; TEncoding lives in SysUtils there. The UTF-8
    conversion is the reason this unit is byte-based at all. }
  {$IFDEF FPC}Classes,{$ENDIF}
  SysUtils, Math;

(* FNV-1a over BYTES, 32-bit.

   Bytes, not characters, and the distinction is the whole point. FPC's
   `string` here holds UTF-8 (see {$CODEPAGE UTF8} above); Delphi's is
   UTF-16. Hashing `Byte(S[i])` would therefore hash different data on the
   two compilers for any non-ASCII text, and truncate each UTF-16 code unit
   into the bargain. Two fact databases carrying the same embedder id would
   then hold incompatible vectors -- defeating the very model-space guard
   this tier ships alongside. Everything below runs on the UTF-8 encoding,
   which is identical on both targets.

   The feature kind (word vs gram) is folded in as the hash SEED rather
   than a string prefix, so no character-typed concatenation happens on the
   hot path at all. *)
const
  FnvPrime = LongWord(16777619);
  { Distinct starting states keep the two feature families in separate hash
    streams, so a word and a gram spelling the same bytes cannot collide. }
  WordSeed = LongWord(2166136261);
  GramSeed = LongWord(2166136453);

function Fnv1aBytes(const B: TBytes; Start, Len: Integer; Seed: LongWord): LongWord;
var
  i: Integer;
begin
  Result := Seed;
  for i := Start to Start + Len - 1 do
  begin
    Result := Result xor LongWord(B[i]);
    Result := Result * FnvPrime;
  end;
end;

{ ASCII lowercase, every non-alphanumeric byte collapsed to a space, bytes
  >= 128 passed through. Because this runs on UTF-8, a multi-byte
  character's bytes stay adjacent and behave as one opaque run, so n-grams
  keep working across scripts without this unit needing a Unicode table. }
function NormaliseBytes(const Text: string): TBytes;
var
  i: Integer;
  B: Byte;
begin
  Result := TEncoding.UTF8.GetBytes(Text);
  for i := 0 to High(Result) do
  begin
    B := Result[i];
    if (B >= Ord('A')) and (B <= Ord('Z')) then
      Result[i] := B + 32
    else if not (((B >= Ord('a')) and (B <= Ord('z')))
              or ((B >= Ord('0')) and (B <= Ord('9')))
              or (B >= 128)) then
      Result[i] := Ord(' ');
  end;
end;

{ Add one hashed feature: low bits pick the bucket, one high bit picks the
  sign. Signed accumulation makes collisions cancel rather than compound --
  two unrelated features in the same bucket are as likely to subtract as to
  add, so expected distortion is zero instead of systematic inflation. }
procedure AddHashed(var Acc: array of Double; H: LongWord; Weight: Double);
var
  Bucket: Integer;
begin
  Bucket := Integer(H mod LongWord(StaticEmbedDim));
  if (H and $80000000) <> 0 then
    Acc[Bucket] := Acc[Bucket] - Weight
  else
    Acc[Bucket] := Acc[Bucket] + Weight;
end;

function StaticEmbedderId: string;
begin
  { v2: the feature extraction moved from character-typed strings to UTF-8
    bytes, which changes the space. Vectors written by v1 must not be
    compared against these, and the id is what enforces that. }
  Result := Format('hash-ngram-v2@%d', [StaticEmbedDim]);
end;

function StaticEmbed(const Text: string): TArray<Single>;
const
  { A whole word is a stronger signal than any one slice of it, and a long
    word contributes many n-grams, so grams are damped to stop long words
    drowning out short ones. }
  WordWeight = 1.0;
  GramWeight = 0.5;
  { Word-boundary markers, so the start and end of a word are distinct
    features from the same letters mid-word. Safe as sentinels because
    NormaliseBytes has already turned every non-alphanumeric byte into a
    space. }
  MarkStart = Byte(Ord('^'));
  MarkEnd   = Byte(Ord('$'));
var
  Norm, Padded: TBytes;
  Acc: array[0 .. StaticEmbedDim - 1] of Double;
  i, j, WStart, WLen, Features: Integer;
  Norm2, V: Double;
begin
  Result := nil;
  for i := 0 to StaticEmbedDim - 1 do Acc[i] := 0;

  Norm := NormaliseBytes(Text);
  Features := 0;
  i := 0;
  while i <= High(Norm) do
  begin
    if Norm[i] = Ord(' ') then begin Inc(i); Continue; end;
    WStart := i;
    while (i <= High(Norm)) and (Norm[i] <> Ord(' ')) do Inc(i);
    WLen := i - WStart;

    AddHashed(Acc, Fnv1aBytes(Norm, WStart, WLen, WordSeed), WordWeight);
    Inc(Features);

    SetLength(Padded, WLen + 2);
    Padded[0] := MarkStart;
    Move(Norm[WStart], Padded[1], WLen);
    Padded[WLen + 1] := MarkEnd;

    for j := 0 to Length(Padded) - StaticEmbedGram do
    begin
      AddHashed(Acc, Fnv1aBytes(Padded, j, StaticEmbedGram, GramSeed), GramWeight);
      Inc(Features);
    end;
  end;

  if Features = 0 then Exit;

  { Sublinear damping, the tf half of tf-idf: a word used ten times is more
    relevant than one used once, but not ten times more. Applied to the
    signed accumulator, so the sign survives. }
  Norm2 := 0;
  for i := 0 to StaticEmbedDim - 1 do
  begin
    V := Acc[i];
    if V > 0 then V := Ln(1 + V)
    else if V < 0 then V := -Ln(1 - V);
    Acc[i] := V;
    Norm2 := Norm2 + V * V;
  end;

  { An all-zero accumulator is possible in principle -- every feature
    cancelling exactly -- and normalising it would divide by zero. }
  if Norm2 <= 0 then Exit;
  Norm2 := Sqrt(Norm2);

  SetLength(Result, StaticEmbedDim);
  for i := 0 to StaticEmbedDim - 1 do
    Result[i] := Acc[i] / Norm2;
end;

end.
