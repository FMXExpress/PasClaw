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
  SysUtils, Math;

{ FNV-1a, 32-bit. Chosen for being short, dependency-free and identical on
  every platform -- the vectors are persisted, so a hash that varied by
  compiler or word size would silently invalidate stored rows. }
function Fnv1a(const S: string): LongWord;
const
  Offset = LongWord(2166136261);
  Prime  = LongWord(16777619);
var
  i: Integer;
begin
  Result := Offset;
  for i := 1 to Length(S) do
  begin
    Result := Result xor LongWord(Byte(S[i]));
    Result := Result * Prime;
  end;
end;

{ ASCII lowercase + everything non-alphanumeric collapsed to a space.
  Bytes >= 128 are kept as-is: for UTF-8 input that keeps a multi-byte
  character's bytes adjacent, so its n-grams still work as a unit, without
  this unit needing a Unicode table. }
function Normalise(const Text: string): string;
var
  i: Integer;
  C: Char;
begin
  SetLength(Result, Length(Text));
  for i := 1 to Length(Text) do
  begin
    C := Text[i];
    if (C >= 'A') and (C <= 'Z') then
      Result[i] := Chr(Ord(C) + 32)
    else if ((C >= 'a') and (C <= 'z')) or ((C >= '0') and (C <= '9'))
            or (Byte(C) >= 128) then
      Result[i] := C
    else
      Result[i] := ' ';
  end;
end;

{ Add one feature to the accumulator: hash it, take the low bits for the
  bucket and one high bit for the sign. The signed accumulation is what
  makes hash collisions cancel rather than compound -- two unrelated
  features landing in the same bucket are as likely to subtract as to add,
  so the expected distortion is zero instead of a systematic inflation. }
procedure AddFeature(var Acc: array of Double; const Feature: string;
                     Weight: Double);
var
  H: LongWord;
  Bucket: Integer;
begin
  if Feature = '' then Exit;
  H := Fnv1a(Feature);
  Bucket := Integer(H mod LongWord(StaticEmbedDim));
  if (H and $80000000) <> 0 then
    Acc[Bucket] := Acc[Bucket] - Weight
  else
    Acc[Bucket] := Acc[Bucket] + Weight;
end;

function StaticEmbedderId: string;
begin
  Result := Format('hash-ngram-v1@%d', [StaticEmbedDim]);
end;

function StaticEmbed(const Text: string): TArray<Single>;
const
  { A whole word is a stronger signal than any one slice of it, and a long
    word contributes many n-grams, so the grams are damped to stop long
    words drowning out short ones. }
  WordWeight = 1.0;
  GramWeight = 0.5;
var
  Norm, Word, Padded: string;
  Acc: array[0 .. StaticEmbedDim - 1] of Double;
  i, j, Start, Features: Integer;
  Norm2, V: Double;
begin
  Result := nil;
  for i := 0 to StaticEmbedDim - 1 do Acc[i] := 0;

  Norm := Normalise(Text);
  Features := 0;
  i := 1;
  while i <= Length(Norm) do
  begin
    if Norm[i] = ' ' then begin Inc(i); Continue; end;
    Start := i;
    while (i <= Length(Norm)) and (Norm[i] <> ' ') do Inc(i);
    Word := Copy(Norm, Start, i - Start);

    AddFeature(Acc, 'w:' + Word, WordWeight);
    Inc(Features);

    { Boundary padding so a short word still yields grams, and so the
      start and end of a word are distinguishable features from the same
      letters appearing mid-word. }
    Padded := '^' + Word + '$';
    for j := 1 to Length(Padded) - StaticEmbedGram + 1 do
    begin
      AddFeature(Acc, 'g:' + Copy(Padded, j, StaticEmbedGram), GramWeight);
      Inc(Features);
    end;
  end;

  if Features = 0 then Exit;

  { Sublinear damping, the tf half of tf-idf: a word repeated ten times
    is more relevant than one used once, but not ten times more. Applied
    to the signed accumulator, so the sign is preserved. }
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
