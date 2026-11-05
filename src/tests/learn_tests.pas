program learn_tests;
(*
  Covers PasClaw.Learn's pattern-extraction primitives:
  NormalizeErrorSignature (the clustering key), LooksLikeFailure (the
  line-level pre-filter), the misuse notes, and which tool a result is
  attributed to.

  Pinned because the whole `pasclaw learn` value proposition rides
  on "same root cause -> same signature": if the normaliser drifts,
  every session looks unique and the report goes empty. If
  LooksLikeFailure drifts the other way, the report fills with
  noise the operator has to wade through.

  ScanSession runs on sessions built in memory; WriteScars on a temp
  file. The walk over saved sessions, and the nightly refresh of
  SCARS.md, are covered by maintain_tests.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}    { The TestReadExistingScars* fixtures embed `§`
                        in string literals; without this directive
                        FPC reinterprets the UTF-8 bytes through the
                        host codepage and the round-trip drifts. }
{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Session.Store,
  PasClaw.Tools.Registry,
  PasClaw.Tools.Sandbox,
  PasClaw.Tools.FS,
  PasClaw.Learn;

procedure Fail(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail(Msg);
end;

procedure AssertFalse(Cond: Boolean; const Msg: string);
begin
  if Cond then Fail(Msg);
end;

procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail(Msg + Format(' (got %d, want %d)', [Got, Want]));
end;

procedure AssertContains(const Hay, Needle, Msg: string);
begin
  if Pos(Needle, Hay) = 0 then Fail(Msg + ' -- missing "' + Needle + '"');
end;

{ ------------------------------------------------------- session fixtures }

function CallMsg(const ToolName, Id: string): TMessage;
begin
  Result := MakeMessage(mrAssistant, '');
  SetLength(Result.ToolCalls, 1);
  Result.ToolCalls[0].Id := Id;
  Result.ToolCalls[0].Func.Name := ToolName;
  Result.ToolCalls[0].Func.Arguments := '{}';
end;

function ResultMsg(const Id, Content: string): TMessage;
begin
  Result := MakeMessage(mrTool, Content);
  Result.ToolCallId := Id;
end;

function MkSession(const Id: string; const Msgs: array of TMessage): TSession;
var
  i: Integer;
begin
  Result := TSession.Create;   { no id: nothing is read from disk }
  Result.Meta.Id := Id;
  Result.Meta.UpdatedAt := 1000;
  SetLength(Result.Messages, Length(Msgs));
  for i := 0 to High(Msgs) do Result.Messages[i] := Msgs[i];
end;

procedure ScanInto(const Id: string; const Msgs: array of TMessage;
                   var Patterns: TErrorPatternArray);
var
  S: TSession;
begin
  S := MkSession(Id, Msgs);
  try
    ScanSession(S, Patterns);
  finally
    S.Free;
  end;
end;

function PatternWith(const Patterns: TErrorPatternArray; const Needle: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(Patterns) do
    if Pos(Needle, Patterns[i].Sample) > 0 then Exit(i);
  Result := -1;
end;

const
  RegexNote = '(no matches) -- note: grep_files matches a LITERAL substring, ' +
    'not a regex. Search one plain term (e.g. "to_csv"), or run it once per alternative.';

procedure TestNormalizeCollapsesDigitRuns;
{ Line numbers, byte counts, pids -- anything 2+ digits -- becomes
  '<n>' so "error at line 42" and "error at line 9001" cluster. }
begin
  AssertEqStr(NormalizeErrorSignature('error at line 42'),
              'error at line <n>',
              '2-digit line number collapses');
  AssertEqStr(NormalizeErrorSignature('killed pid 12345 by SIGTERM'),
              'killed pid <n> by SIGTERM',
              '5-digit pid collapses');
  AssertEqStr(NormalizeErrorSignature('cargo: error 1'),
              'cargo: error 1',
              'single digit stays literal (exit codes matter)');
end;

procedure TestNormalizeCollapsesHexHashes;
{ Session ids, commit shas, temp-dir UUIDs all become '<hash>'.
  Letter requirement keeps pure-decimal runs out of this bucket. }
begin
  AssertEqStr(NormalizeErrorSignature('checking commit a1b2c3d4e5f6'),
              'checking commit <hash>',
              'mixed hex collapses to <hash>');
  AssertEqStr(NormalizeErrorSignature('object sha 0123456789abcdef'),
              'object sha <hash>',
              '16-char hex collapses');
  AssertEqStr(NormalizeErrorSignature('count was 12345678'),
              'count was <n>',
              'pure-decimal stays <n>, not <hash>');
end;

procedure TestNormalizeCollapsesPaths;
{ Unix and Windows absolute paths collapse to '<path>' so
  per-session temp dirs don't fragment a cluster. Bare '/' in
  prose ('5 / 2') must NOT trigger. }
begin
  AssertEqStr(NormalizeErrorSignature('cannot read /tmp/foo/bar.txt'),
              'cannot read <path>',
              'unix path -> <path>');
  AssertEqStr(NormalizeErrorSignature('fs_write to C:\Users\bob\code\x.pas failed'),
              'fs_write to <path> failed',
              'windows path -> <path>');
  AssertEqStr(NormalizeErrorSignature('result was 5 / 2'),
              'result was 5 / 2',
              'bare slash in prose stays literal');
end;

procedure TestNormalizeCollapsesWhitespace;
begin
  AssertEqStr(NormalizeErrorSignature('error:    too   much    space'),
              'error: too much space',
              'runs of internal spaces collapse');
  AssertEqStr(NormalizeErrorSignature('   leading and trailing   '),
              'leading and trailing',
              'leading and trailing whitespace trims');
end;

procedure TestClusteringContract;
{ The end-state we care about: two superficially different lines
  that share a root cause normalise to the same key. }
var
  A, B, C: string;
begin
  A := NormalizeErrorSignature(
         'shell_exec failed: /tmp/sandbox-abc123/run.sh: line 42: foo: command not found');
  B := NormalizeErrorSignature(
         'shell_exec failed: /tmp/sandbox-xyz789/run.sh: line 17: foo: command not found');
  AssertEqStr(A, B,
              'two sessions hitting the same "foo: command not found" cluster');

  { Different root cause stays distinct. }
  C := NormalizeErrorSignature(
         'shell_exec failed: /tmp/sandbox-xyz789/run.sh: line 17: bar: command not found');
  AssertTrue(A <> C,
             'different command (foo vs bar) does NOT cluster');
end;

procedure TestLooksLikeFailurePositives;
begin
  AssertTrue(LooksLikeFailure('bash: foo: command not found'),
             'command not found');
  AssertTrue(LooksLikeFailure('open(/etc/shadow): permission denied'),
             'permission denied');
  AssertTrue(LooksLikeFailure('error: undefined symbol main'),
             '"error:" + content');
  AssertTrue(LooksLikeFailure('exit=1 oops'),
             'exit=1 leading');
  AssertTrue(LooksLikeFailure('cannot find module "fs"'),
             'cannot find ...');
  AssertTrue(LooksLikeFailure('connection refused'),
             'connection refused');
  AssertTrue(LooksLikeFailure('Traceback (most recent call last):'),
             'a Python traceback');
end;

procedure TestReadExistingScarsRecognisesRenamedAnchors;
{ Codex P2 on PR #197: the promise in MakeAnchorName's docstring
  ("operators can rename anchors freely; pasclaw learn matches
  patterns by signature, not by anchor name") is only kept if the
  emitter actually persists a signature alongside each anchor and
  the reader picks it up. Without this regression test the
  contract drifts silently -- the rename-and-rerun path is rare
  enough on any one operator's machine that the symptom (duplicate
  block) would only surface once someone curates SCARS for a
  while. Pin it now.

  Fixture mimics three on-disk states in one file: a stock
  emitter-produced block, an operator-renamed block (anchor
  changed, signature marker preserved), and an entirely
  hand-written block (no signature marker -- legacy / external).
  Each case feeds a different branch of the skip logic. }
const
  FixturePath = '/tmp/pasclaw-learn-scars-fixture.md';
var
  Sl, Anchors, Signatures: TStringList;
begin
  Sl := TStringList.Create;
  try
    Sl.Add('# SCARS');
    Sl.Add('');
    Sl.Add('## §STOCK-ANCHOR');
    Sl.Add('<!-- signature: stock signature stays put -->');
    Sl.Add('**Symptom:** stock');
    Sl.Add('');
    Sl.Add('## §OPERATOR-RENAMED-THIS');
    Sl.Add('<!-- signature: renamed entry keeps signature -->');
    Sl.Add('**Symptom:** renamed');
    Sl.Add('');
    Sl.Add('## §HAND-WRITTEN');
    Sl.Add('**Symptom:** no signature marker');
    Sl.Add('');
    Sl.SaveToFile(FixturePath);
  finally
    Sl.Free;
  end;

  Anchors := nil; Signatures := nil;
  try
    ReadExistingScars(FixturePath, Anchors, Signatures);

    AssertTrue(Anchors.IndexOf('STOCK-ANCHOR') >= 0,
               'reader picks up the stock anchor name');
    AssertTrue(Anchors.IndexOf('OPERATOR-RENAMED-THIS') >= 0,
               'reader picks up renamed anchor');
    AssertTrue(Anchors.IndexOf('HAND-WRITTEN') >= 0,
               'reader picks up signature-less anchor');

    AssertTrue(Signatures.IndexOf('stock signature stays put') >= 0,
               'reader extracts stock signature marker');
    AssertTrue(Signatures.IndexOf('renamed entry keeps signature') >= 0,
               'reader extracts signature even when anchor was renamed');
    AssertTrue(Signatures.IndexOf('no signature marker') < 0,
               'reader does NOT invent a signature where none was emitted');
  finally
    Anchors.Free;
    Signatures.Free;
    if FileExists(FixturePath) then DeleteFile(FixturePath);
  end;
end;

procedure TestReadExistingScarsMissingFile;
{ Missing file is not an error -- AppendToScarsMd leans on this to
  treat first-run as "no existing anchors, write the header". Both
  lists must come back empty rather than nil. }
var
  Anchors, Signatures: TStringList;
begin
  Anchors := nil; Signatures := nil;
  try
    ReadExistingScars('/tmp/pasclaw-does-not-exist-' + IntToStr(Random(MaxInt)),
                      Anchors, Signatures);
    AssertTrue(Anchors    <> nil, 'Anchors list returned even when file is missing');
    AssertTrue(Signatures <> nil, 'Signatures list returned even when file is missing');
    AssertTrue(Anchors.Count = 0,    'missing-file Anchors is empty');
    AssertTrue(Signatures.Count = 0, 'missing-file Signatures is empty');
  finally
    Anchors.Free;
    Signatures.Free;
  end;
end;

procedure TestMakeAnchorName;
{ The anchor is the SCARS join point ("fixes §FOO-BAR" in a commit
  message). Pin the derivation so a later refactor of MakeAnchorName
  doesn't silently rename every anchor in the operator's checked-in
  SCARS.md. }
begin
  AssertEqStr(
    MakeAnchorName('shell_exec failed: <path>: <n>: foo: command not found'),
    'SHELL-EXEC-FAILED-FOO-COMMAND',
    'placeholders drop, underscores split, first 5 tokens win');
  AssertEqStr(
    MakeAnchorName('permission denied <path>'),
    'PERMISSION-DENIED',
    'placeholders strip cleanly');
  AssertEqStr(
    MakeAnchorName('<n> <path> <hash>'),
    'PATTERN',
    'all-placeholder signature falls back to PATTERN');
  AssertEqStr(
    MakeAnchorName('the a an the to of from'),
    'PATTERN',
    'all-stopword signature falls back to PATTERN');
  AssertEqStr(
    MakeAnchorName('Cannot Find Module foo'),
    'CANNOT-FIND-MODULE-FOO',
    'casing normalises to upper, dashes between tokens');
end;

procedure TestAttributionWhenIdsRepeat;
{ Some servers number calls per turn (the relay provider, several local
  OpenAI-compatible servers), so "c1" comes back every turn. A result
  belongs to the latest call with its id; keeping the first sent the
  live security run's shell_exec refusal to the turn-one grep_files. }
var
  P: TErrorPatternArray;
  i: Integer;
begin
  P := nil;
  try
    ScanInto('s1',
      [MakeMessage(mrUser, 'sweep it'),
       CallMsg('grep_files', 'c1'),
       ResultMsg('c1', RegexNote),
       CallMsg('shell_exec', 'c1'),
       ResultMsg('c1', 'ERROR: refused: the command runs eval on its input'),
       MakeMessage(mrAssistant, 'done')], P);
    AssertEqInt(Length(P), 2, 'a misuse and a failure');
    i := PatternWith(P, 'refused');
    AssertTrue(i >= 0, 'the refusal is a pattern');
    AssertEqStr(P[i].Context, 'shell_exec', 'the refusal is the turn-two call''s');
    AssertTrue(P[i].Kind = pkFailure, 'a failure');
    i := PatternWith(P, 'LITERAL substring');
    AssertTrue(i >= 0, 'the misuse note is a pattern');
    AssertEqStr(P[i].Context, 'grep_files', 'the note is the turn-one call''s');
    AssertTrue(P[i].Kind = pkMisuse, 'a misuse');
  finally
    FreePatterns(P);
  end;

  { Calls of one turn split over two assistant messages, results after
    both: each id still finds its call. }
  P := nil;
  try
    ScanInto('s2',
      [CallMsg('read_file', 'c1'),
       CallMsg('shell_exec', 'c2'),
       ResultMsg('c1', 'ERROR: no such file: notes.txt'),
       ResultMsg('c2', 'bash: jq: command not found')], P);
    i := PatternWith(P, 'no such file');
    AssertTrue((i >= 0) and (P[i].Context = 'read_file'), 'c1 is read_file''s');
    i := PatternWith(P, 'command not found');
    AssertTrue((i >= 0) and (P[i].Context = 'shell_exec'), 'c2 is shell_exec''s');
  finally
    FreePatterns(P);
  end;

  { An id with '=' in it (base64 padding) still finds its call. }
  P := nil;
  try
    ScanInto('s3',
      [CallMsg('shell_exec', 'Y2FsbF8x=='),
       ResultMsg('Y2FsbF8x==', 'bash: jq: command not found')], P);
    AssertEqInt(Length(P), 1, 'one failure');
    AssertEqStr(P[0].Context, 'shell_exec', 'attributed through an id with =');
  finally
    FreePatterns(P);
  end;
end;

function SamplesOf(const P: TErrorPatternArray): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(P) do Result := Result + ' [' + P[i].Sample + ']';
end;

procedure TestQuotedTextIsNotMined;
{ What a tool only returns is quoted, not failed. Mining it is the loop
  the nightly pass would otherwise close: SCARS.md read back in two
  sessions came back as new patterns, and the next night wrote anchors
  for its own Symptom lines. }
var
  P: TErrorPatternArray;
begin
  P := nil;
  try
    ScanInto('s1',
      [CallMsg('read_file', 'c1'),
       ResultMsg('c1', '1:ab|error: the build broke'#10'2:cd|bash: x: command not found'),
       CallMsg('memory_search', 'c2'),
       ResultMsg('c2', 'SCARS.md (score 1.2)'#10'  **Symptom:** ERROR: refused: eval'#10 +
         '  **Symptom:** ' + RegexNote + #10 +
         'notes.md (score 0.8)'#10'  ERROR: the deploy failed on Tuesday'),
       CallMsg('grep_files', 'c3'),
       ResultMsg('c3', 'src/FS.pas:954:  Result := ''' + RegexNote + '''' + #10 +
         'src/b.pas:3:  raise Exception.Create(''error: bad input'');'),
       CallMsg('shell_exec', 'c4'),
       ResultMsg('c4', '**Symptom:** ERROR: refused: eval'#10 +
         '  - `bash: npm: command not found`'#10 +
         '- 2x across 2 sessions, `shell`: `ERROR: x` ' + SectionSign + 'ERROR-X')], P);
    AssertEqInt(Length(P), 0, 'nothing quoted is mined:' + SamplesOf(P));

    { A read's own status line, and a command's output, still count. }
    ScanInto('s2',
      [CallMsg('read_file', 'c1'),
       ResultMsg('c1', 'ERROR: no such file: notes.txt'),
       CallMsg('shell_exec', 'c2'),
       ResultMsg('c2', 'building'#10'bash: jq: command not found')], P);
    AssertEqInt(Length(P), 2, 'a read''s ERROR line and a shell failure:' + SamplesOf(P));
  finally
    FreePatterns(P);
  end;
end;

procedure TestRedactSecrets;
{ SCARS.md is written unattended and exported into committed rule files,
  so a credential in a failure line must not reach it. }
var
  P: TErrorPatternArray;
begin
  AssertEqStr(RedactSecrets('fatal: unable to access ''https://eli:hunter22@github.com/x.git/'': error'),
    'fatal: unable to access ''https://<redacted>@github.com/x.git/'': error', 'URL userinfo');
  AssertEqStr(RedactSecrets('remote: https://ghp_abcdefghijklmnop1234@github.com'),
    'remote: https://<redacted>@github.com', 'a token as userinfo');
  AssertEqStr(RedactSecrets('error: bad credentials ghp_AbCdEf0123456789xyz'),
    'error: bad credentials <redacted>', 'a GitHub token');
  AssertEqStr(RedactSecrets('error: key sk-ant-api03-abcdefghijklmnop rejected'),
    'error: key <redacted> rejected', 'an API key');
  AssertEqStr(RedactSecrets('error: AKIAIOSFODNN7EXAMPLE is not authorized'),
    'error: <redacted> is not authorized', 'an AWS key id');
  AssertEqStr(RedactSecrets('curl: (22) https://api.x.com/v1?api_key=s3cr3tvalue&q=1 failed'),
    'curl: (22) https://api.x.com/v1?api_key=<redacted>&q=1 failed', 'a key=value');
  AssertEqStr(RedactSecrets('error: password: Hunter2! rejected'),
    'error: password: <redacted> rejected', 'a key: value');
  AssertEqStr(RedactSecrets('error: Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc denied'),
    'error: Authorization: Bearer <redacted> denied', 'a bearer token');
  AssertEqStr(RedactSecrets('error: GITHUB_TOKEN=ghp_AbCdEf0123456789xyz'),
    'error: GITHUB_TOKEN=<redacted>', 'an env var');
  AssertEqStr(RedactSecrets('error: invalid key AbCdEfGhIjKlMnOpQrStUvWxYz0123456789'),
    'error: invalid key <redacted>', 'a long opaque key');
  { What is not a secret stays. }
  AssertEqStr(RedactSecrets('error: unexpected token: identifier at line 3'),
    'error: unexpected token: identifier at line 3', 'a parser''s token');
  AssertEqStr(RedactSecrets('ERROR: refused: command contains forbidden token "eval"'),
    'ERROR: refused: command contains forbidden token "eval"', 'the shell refusal');
  AssertEqStr(RedactSecrets('fatal: bad object 3f2a9c1e0b7d4a6f8e2c1b0a9d8e7f6a5b4c3d2e'),
    'fatal: bad object 3f2a9c1e0b7d4a6f8e2c1b0a9d8e7f6a5b4c3d2e', 'a commit hash');
  AssertEqStr(RedactSecrets('error: https://github.com/FMXExpress/PasClaw/pull/628 failed'),
    'error: https://github.com/FMXExpress/PasClaw/pull/628 failed', 'a plain URL');

  { Mined lines are masked in the sample and in the signature. }
  P := nil;
  try
    ScanInto('s1', [CallMsg('shell_exec', 'c1'), ResultMsg('c1',
      'fatal: unable to access ''https://eli:hunter22@github.com/x.git/'': error: 403')], P);
    AssertEqInt(Length(P), 1, 'one failure');
    AssertFalse(Pos('hunter22', P[0].Sample) > 0, 'no password in the sample');
    AssertFalse(Pos('hunter22', P[0].Signature) > 0, 'nor in the signature');
  finally
    FreePatterns(P);
  end;
end;

procedure TestSortIsStable;
{ Most occurrences first; equal counts keep the order they were found in. }
var
  P: TErrorPatternArray;
  i: Integer;
const
  Counts: array[0..4] of Integer = (1, 3, 2, 3, 1);
  Want: array[0..4] of string = ('b', 'd', 'c', 'a', 'e');
begin
  SetLength(P, 5);
  for i := 0 to 4 do
  begin
    P[i].Count := Counts[i];
    P[i].Signature := Chr(Ord('a') + i);
    P[i].Sessions := nil;
  end;
  SortPatternsByCount(P);
  for i := 0 to 4 do
    AssertEqStr(P[i].Signature, Want[i], 'sorted position ' + IntToStr(i));
end;

procedure TestScarsAnchors;
{ Anchors that collide, anchors the operator renamed, a hand-written block,
  a dry run, and a file that cannot be written. }
var
  P: TErrorPatternArray;
  Dir, Path, Text, Base, A0, A1: string;
  Fresh, Skipped: Integer;
  AnchorOf: TArray<string>;
begin
  P := nil;
  Dir := JoinPath(GetTempDir, 'pc-learn-anchors-' + IntToStr(GetProcessID));
  ForceDirectories(Dir);
  Path := JoinPath(Dir, 'SCARS.md');
  SysUtils.DeleteFile(Path);
  try
    { Two refusals of two commands derive one five-word anchor. }
    ScanInto('s1', [CallMsg('shell_exec', 'c1'),
      ResultMsg('c1', 'ERROR: refused: command contains forbidden token "eval"'),
      CallMsg('shell_exec', 'c2'),
      ResultMsg('c2', 'ERROR: refused: command contains forbidden token "rm"')], P);
    ScanInto('s2', [CallMsg('shell_exec', 'c1'),
      ResultMsg('c1', 'ERROR: refused: command contains forbidden token "eval"'),
      CallMsg('shell_exec', 'c2'),
      ResultMsg('c2', 'ERROR: refused: command contains forbidden token "rm"')], P);
    AssertEqInt(Length(P), 2, 'two patterns');
    Base := MakeAnchorName(P[0].Signature);
    AssertEqStr(MakeAnchorName(P[1].Signature), Base, 'that derive one anchor');

    AssertTrue(WriteScars(Path, P, 2, True, Fresh, Skipped, AnchorOf), 'dry run');
    AssertEqInt(Fresh, 2, 'a dry run says two would be added');
    AssertFalse(FileExists(Path), 'and writes nothing');
    AssertTrue((AnchorOf[0] = '') and (AnchorOf[1] = ''), 'so nothing is cited yet');

    AssertTrue(WriteScars(Path, P, 2, False, Fresh, Skipped, AnchorOf), 'written');
    AssertEqInt(Fresh, 2, 'both added, neither dropped as already there');
    AssertEqStr(AnchorOf[0], Base, 'the first under the anchor');
    AssertEqStr(AnchorOf[1], Base + '-2', 'the second with a suffix');
    A1 := AnchorOf[1];

    { The operator renames the first: the next run follows the rename. }
    Text := ReadFileText(Path);
    AssertContains(Text, '## ' + SectionSign + Base + #10, 'the heading as written');
    Text := StringReplace(Text, '## ' + SectionSign + Base + #10,
                          '## ' + SectionSign + 'EVAL-DENIED' + #10, []);
    WriteFileText(Path, Text);
    AssertTrue(WriteScars(Path, P, 2, False, Fresh, Skipped, AnchorOf), 'third run');
    AssertEqInt(Fresh, 0, 'nothing new');
    AssertEqInt(Skipped, 2, 'both known');
    AssertEqStr(AnchorOf[0], 'EVAL-DENIED', 'the renamed anchor is the one cited');
    AssertEqStr(AnchorOf[1], A1, 'the other is unchanged');

    { A hand-written block with no marker is its anchor's pattern -- once. }
    WriteFileText(Path, '## ' + SectionSign + Base + #10 + 'written by hand'#10);
    AssertTrue(WriteScars(Path, P, 2, False, Fresh, Skipped, AnchorOf), 'hand-written');
    AssertEqInt(Skipped, 1, 'the hand-written block is the first');
    AssertEqInt(Fresh, 1, 'the second is added');
    AssertEqStr(AnchorOf[0], Base, 'cited by its hand-written anchor');
    AssertEqStr(AnchorOf[1], Base + '-2', 'the second beside it');
    A0 := ReadFileText(Path);
    AssertContains(A0, 'written by hand', 'the operator''s text is kept');

    { A file that cannot be written reports nothing added. }
    ForceDirectories(JoinPath(Dir, 'adir'));
    AssertFalse(WriteScars(JoinPath(Dir, 'adir'), P, 2, False, Fresh, Skipped, AnchorOf),
                'a directory is not writable as SCARS.md');
    AssertEqInt(Fresh, 0, 'no anchors reported added');
    AssertEqInt(Skipped, 0, 'none reported known');
    AssertEqStr(AnchorOf[0], '', 'none cited');
    RemoveDir(JoinPath(Dir, 'adir'));
  finally
    FreePatterns(P);
    SysUtils.DeleteFile(Path);
    RemoveDir(Dir);
  end;
end;

procedure TestMisuseClusters;
{ The definition hint names the symbol searched for. Two sessions hunting
  two different names are one recurring misuse, not two one-offs. }
var
  P: TErrorPatternArray;
  Dir, Path, Text: string;
  Fresh, Skipped: Integer;
  AnchorOf: TArray<string>;
begin
  AssertTrue(MisuseSignature('(no matches)') = '', 'a plain miss is no misuse');
  AssertTrue(MisuseSignature('error: no such file') = '', 'a failure is no misuse');
  AssertTrue(MisuseSignature(RegexNote) <> '', 'the regex note is');
  P := nil;
  try
    ScanInto('s1', [CallMsg('grep_files', 'c1'), ResultMsg('c1',
      '(no matches) -- to find where a name is defined, whatever its keyword or owner: ' +
      'code_outline symbol="TFoo.Make".')], P);
    ScanInto('s2', [CallMsg('grep_files', 'c1'), ResultMsg('c1',
      '(no matches) -- to find where a name is defined, whatever its keyword or owner: ' +
      'code_outline symbol="ParseArgs".')], P);
    AssertEqInt(Length(P), 1, 'one pattern for both names');
    AssertEqInt(P[0].Sessions.Count, 2, 'seen in two sessions');
    AssertTrue(PassesThreshold(P[0], 2), 'so it recurs');
    AssertEqStr(MakeAnchorName(P[0].Signature), 'GREP-FILES-DEFINITION-HUNT-KEYWORD',
                'its anchor reads as what went wrong');

    Dir := JoinPath(GetTempDir, 'pc-learn-tests-' + IntToStr(GetProcessID));
    ForceDirectories(Dir);
    Path := JoinPath(Dir, 'SCARS.md');
    SysUtils.DeleteFile(Path);
    AssertTrue(WriteScars(Path, P, 2, False, Fresh, Skipped, AnchorOf), 'SCARS.md written');
    AssertEqInt(Fresh, 1, 'one new anchor');
    Text := ReadFileText(Path);
    AssertContains(Text, SectionSign + 'GREP-FILES-DEFINITION-HUNT-KEYWORD', 'the anchor');
    AssertContains(Text, '**Kind:** misuse', 'marked a misuse');
    AssertContains(Text, '**Where:** tool `grep_files`', 'and where');
    AssertTrue(WriteScars(Path, P, 2, False, Fresh, Skipped, AnchorOf), 'second write');
    AssertEqInt(Fresh, 0, 'nothing new the second time');
    AssertEqInt(Skipped, 1, 'the anchor is already there');
    SysUtils.DeleteFile(Path);
    RemoveDir(Dir);
  finally
    FreePatterns(P);
  end;
end;

procedure TestMisuseNotesMatchTheTool;
{ MisuseSignature matches the notes' wording, so run the tool that writes
  them: a reworded note fails here instead of going quietly uncounted. }
var
  Dir, Out_, Err: string;
  R: TToolRegistry;
  Pol: TSandboxPolicy;
begin
  Dir := JoinPath(GetTempDir, 'pc-learn-grep-' + IntToStr(GetProcessID));
  ForceDirectories(Dir);
  WriteFileText(JoinPath(Dir, 'a.txt'), 'nothing to see'#10);
  Pol := Default(TSandboxPolicy);
  ConfigureSandbox(Pol, Dir);
  R := TToolRegistry.Create;
  try
    RegisterFSTools(R);
    Out_ := R.RunTool('grep_files', '{"path":".","pattern":"foo|bar"}', Err);
    AssertContains(Out_, 'LITERAL', 'grep_files notes a regex');
    AssertTrue(LooksLikeMisuse(Out_), 'the regex note counts as a misuse: ' + Out_);
    Out_ := R.RunTool('grep_files', '{"path":".","pattern":"function TFoo.Make"}', Err);
    AssertContains(Out_, 'code_outline', 'grep_files notes a definition hunt');
    AssertTrue(LooksLikeMisuse(Out_), 'the definition note counts as a misuse: ' + Out_);
    AssertTrue(MisuseSignature(Out_) <> MisuseSignature(RegexNote), 'two different misuses');
    Out_ := R.RunTool('grep_files', '{"path":".","pattern":"absent"}', Err);
    AssertFalse(LooksLikeMisuse(Out_), 'an ordinary miss is not');
    { A file that quotes the note is found, not misused. }
    WriteFileText(JoinPath(Dir, 'b.txt'), 'x := ''' + RegexNote + ''';'#10);
    Out_ := R.RunTool('grep_files', '{"path":".","pattern":"LITERAL"}', Err);
    AssertContains(Out_, 'b.txt', 'the quoting file is found');
    AssertEqInt(Length(ProblemLines('grep_files', Out_)), 0, 'and no misuse is counted: ' + Out_);
  finally
    R.Free;
    SysUtils.DeleteFile(JoinPath(Dir, 'a.txt'));
    SysUtils.DeleteFile(JoinPath(Dir, 'b.txt'));
    RemoveDir(Dir);
  end;
end;

procedure TestLooksLikeFailureNegatives;
{ Precision matters: ordinary output lines must not match. The
  cost of a false positive is a noisy report the operator has to
  read past; the cost of a false negative is a missed pattern. }
begin
  AssertFalse(LooksLikeFailure('test passed in 0.2s'),
              'plain success line');
  AssertFalse(LooksLikeFailure('compiled 100 files'),
              'compile summary');
  AssertFalse(LooksLikeFailure(''),
              'empty string');
  AssertFalse(LooksLikeFailure('the cake is a lie'),
              'random prose');
end;

begin
  TestNormalizeCollapsesDigitRuns;
  TestNormalizeCollapsesHexHashes;
  TestNormalizeCollapsesPaths;
  TestNormalizeCollapsesWhitespace;
  TestClusteringContract;
  TestLooksLikeFailurePositives;
  TestLooksLikeFailureNegatives;
  TestMakeAnchorName;
  TestReadExistingScarsRecognisesRenamedAnchors;
  TestReadExistingScarsMissingFile;
  TestAttributionWhenIdsRepeat;
  TestMisuseClusters;
  TestMisuseNotesMatchTheTool;
  TestQuotedTextIsNotMined;
  TestRedactSecrets;
  TestScarsAnchors;
  TestSortIsStable;
  WriteLn('learn_tests: OK');
end.
