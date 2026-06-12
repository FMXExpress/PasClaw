program fs_grep_tier5_6_tests;
(*
  Pin the two ripgrep-inspired fs_grep optimisations as observable
  behaviour:

    Tier 5  Walk bytes, not lines. No TStringList, no
            StringReplace, no per-line LowerCase. Observable
            difference: none -- this is a refactor for speed.
            We pin the OUTPUT (line numbers, matched text, hashline
            header) so the rewrite can't silently drift.

    Tier 6  Boyer-Moore-Horspool substring search. Also output-
            equivalent to Pos(), but we exercise enough corner
            cases (overlapping patterns, repeated alphabets,
            single-char patterns, longer patterns at the start /
            middle / end of a line, case-insensitive) to catch
            classic BMH bugs like the "last char in shift table"
            infinite-loop trap or a 1-byte-off-by-one mismatch.

  Strategy: spin a unique-per-run temp dir, write fixtures, drive
  Tool_FSGrep via its public handler with hand-built JSON args,
  parse the hashline-formatted output and assert on its contents.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.FS;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing from "' +
          Copy(Haystack, 1, 400) + '")');
end;

procedure AssertNotContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then
    Fail_(Msg + ' (unwanted needle "' + Needle +
          '" found in "' + Copy(Haystack, 1, 400) + '")');
end;

procedure WriteText(const Path, Content: string);
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmCreate);
  try
    if Length(Content) > 0 then
      F.WriteBuffer(Content[1], Length(Content));
  finally
    F.Free;
  end;
end;

function MakeTempDir(const Tag: string): string;
begin
  Result := IncludeTrailingPathDelimiter(SysUtils.GetTempDir) +
            'pasclaw-fsgrep56-' + Tag + '-' +
            IntToStr(Random(MaxInt));
  ForceDirectories(Result);
end;

procedure DeleteTree(const Dir: string);
var
  SR: TSearchRec;
begin
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Attr and faDirectory) <> 0 then
          DeleteTree(JoinPath(Dir, SR.Name))
        else
          DeleteFile(JoinPath(Dir, SR.Name));
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
  RemoveDir(Dir);
end;

function CallGrep(const Path, Pattern: string;
                  IgnoreCase: Boolean = False): string;
var
  Reg: TToolRegistry;
  Tool: TTool;
  Args, ErrMsg: string;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);
    if not Reg.Find('fs_grep', Tool) then
      Fail_('fs_grep not registered');
    if IgnoreCase then
      Args := Format('{"path":"%s","pattern":"%s","ignore_case":true}',
                     [StringReplace(Path, '\', '\\', [rfReplaceAll]), Pattern])
    else
      Args := Format('{"path":"%s","pattern":"%s"}',
                     [StringReplace(Path, '\', '\\', [rfReplaceAll]), Pattern]);
    Result := Tool.Handler(Args, ErrMsg);
    if ErrMsg <> '' then
      Fail_('fs_grep returned error: ' + ErrMsg);
  finally
    Reg.Free;
  end;
end;

procedure TestLineNumbersExact;
{ Tier 5 regression bait: the byte walker has to produce the same
  line numbers as the old TStringList split. Seed a file with
  matches on specific line numbers and assert each one. }
var
  Root, Got: string;
begin
  Root := MakeTempDir('linenums');
  try
    WriteText(JoinPath(Root, 'a.txt'),
      'first line'#10 +
      'second NEEDLE here'#10 +
      'third line'#10 +
      'NEEDLE at line 4'#10 +
      'fifth line'#10);
    Got := CallGrep(Root, 'NEEDLE');
    AssertContains(Got, '2:second NEEDLE here',
                   'line 2 match has correct line number');
    AssertContains(Got, '4:NEEDLE at line 4',
                   'line 4 match has correct line number');
    AssertNotContains(Got, '3:', 'no spurious match on line 3');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestCRLFLineEndings;
{ Tier 5 regression bait: CRLF files. The old code did
  StringReplace(Body, #13, '', [rfReplaceAll]) up front; the byte
  walker has to trim trailing #13 inline. Without that, the BMH
  pattern would search "line\r" and miss a pattern that's anchored
  to end-of-line; OR the matched line in the output would carry
  the CR and corrupt the terminal display. }
var
  Root, Got: string;
begin
  Root := MakeTempDir('crlf');
  try
    WriteText(JoinPath(Root, 'win.txt'),
      'alpha'#13#10 + 'BRAVO'#13#10 + 'charlie'#13#10);
    Got := CallGrep(Root, 'BRAVO');
    AssertContains(Got, '2:BRAVO',
                   'CRLF line found on correct line number');
    AssertNotContains(Got, #13,
                     'output line does not carry stray CR (display would break)');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestNoTrailingNewline;
{ Tier 5 regression bait: file that does NOT end in #10. The byte
  walker's "i = BodyLen" branch has to close the final line, or
  the last line's match goes missing. }
var
  Root, Got: string;
begin
  Root := MakeTempDir('notail');
  try
    WriteText(JoinPath(Root, 'a.txt'), 'line one'#10'last NEEDLE no newline');
    Got := CallGrep(Root, 'NEEDLE');
    AssertContains(Got, '2:last NEEDLE no newline',
                   'final-line-without-trailing-newline match surfaces');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestMultipleMatchesPerFile;
{ Each matching line gets its own LINE:text entry; the file header
  is emitted exactly once at the first match. }
var
  Root, Got: string;
  HeaderCount: Integer;
  k: Integer;
begin
  Root := MakeTempDir('multi');
  try
    WriteText(JoinPath(Root, 'a.txt'),
      'NEEDLE 1'#10'no'#10'NEEDLE 2'#10'no'#10'NEEDLE 3'#10);
    Got := CallGrep(Root, 'NEEDLE');
    AssertContains(Got, '1:NEEDLE 1', 'first match');
    AssertContains(Got, '3:NEEDLE 2', 'second match');
    AssertContains(Got, '5:NEEDLE 3', 'third match');
    { Pilcrow (¶) starts the hashline header for the file. There
      should be exactly one of them -- one section per matched file,
      not one per match. }
    HeaderCount := 0;
    for k := 1 to Length(Got) - 1 do
      if (Got[k] = #$C2) and (Got[k + 1] = #$B6) then
        Inc(HeaderCount);
    AssertTrue(HeaderCount = 1,
               'exactly one hashline header for the matched file (got ' +
               IntToStr(HeaderCount) + ')');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestCaseInsensitiveMatch;
{ Tier 6 path: ignore_case=true lowers the pattern once at startup
  and folds every text byte through the lower table. Confirm the
  match still fires when only the case differs. }
var
  Root, Got: string;
begin
  Root := MakeTempDir('case');
  try
    WriteText(JoinPath(Root, 'a.txt'),
      'no match'#10'has NEEDLE in it'#10'no match'#10);
    { Pattern is lowercase, line has uppercase. Must hit. }
    Got := CallGrep(Root, 'needle', True);
    AssertContains(Got, '2:has NEEDLE in it',
                   'case-insensitive search matches mixed case');
    { Case-sensitive negative control: same pattern at default
      ignore_case=false must NOT find it. }
    Got := CallGrep(Root, 'needle');
    AssertContains(Got, 'no matches',
                   'case-sensitive search does NOT match uppercase');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestOverlappingPatternBytes;
{ Tier 6 regression bait. Classic BMH bugs:
    - The shift table entry for the LAST pattern byte must be the
      default m, NOT m-i. If it's m-i, a pattern like "AAAA" against
      "AAAB" would loop forever after the partial match resets.
    - Patterns containing repeated alphabets test the inner-while
      mismatch tracking.
  Seed a body that exercises both. }
var
  Root, Got: string;
begin
  Root := MakeTempDir('overlap');
  try
    WriteText(JoinPath(Root, 'a.txt'),
      'AAAB'#10                 +  { line 1: prefix of pattern, no match  }
      'AAAA'#10                 +  { line 2: exact match                  }
      'XAAAAY'#10               +  { line 3: pattern embedded             }
      'AAAAA'#10                +  { line 4: pattern + tail               }
      'AABAA'#10                +  { line 5: prefix + suffix, no match    }
      'plain text'#10);
    Got := CallGrep(Root, 'AAAA');
    AssertContains(Got, '2:AAAA', 'exact match on line 2');
    AssertContains(Got, '3:XAAAAY', 'embedded match on line 3');
    AssertContains(Got, '4:AAAAA', 'overlapping match on line 4');
    AssertNotContains(Got, '1:AAAB', 'AAAB must NOT match AAAA');
    AssertNotContains(Got, '5:AABAA', 'AABAA must NOT match AAAA');
    AssertNotContains(Got, '6:plain text', 'unrelated line must NOT match');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestSingleCharPattern;
{ Tier 6 corner: m=1 degenerates the BMH inner loop. shift table
  entries are all m=1, and the inner while-loop runs exactly once
  per text byte. Easy off-by-one trap if i + j - 1 arithmetic
  doesn't simplify correctly when j=1. }
var
  Root, Got: string;
begin
  Root := MakeTempDir('mone');
  try
    WriteText(JoinPath(Root, 'a.txt'), 'find X here'#10'nothing'#10'and X again'#10);
    Got := CallGrep(Root, 'X');
    AssertContains(Got, '1:find X here', 'm=1 match on line 1');
    AssertContains(Got, '3:and X again', 'm=1 match on line 3');
    AssertNotContains(Got, '2:nothing', 'm=1 no false positive on bare line');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestPatternLongerThanLine;
{ Tier 6 corner: m > n triggers the early exit in BMHFindInBuf.
  Seed a file with short lines where pattern length exceeds any
  single line, and confirm no match. (The pattern would match if
  we accidentally scanned across the line boundary.) }
var
  Root, Got: string;
begin
  Root := MakeTempDir('pattoolong');
  try
    WriteText(JoinPath(Root, 'a.txt'),
      'abc'#10'def'#10'ghi'#10);
    Got := CallGrep(Root, 'abcdefghi');
    AssertContains(Got, 'no matches',
                   'pattern longer than any line returns no matches');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestEmptyAndAllNewlinesFile;
{ Tier 5 edge: empty body and all-newline body must not crash and
  must produce zero matches. The byte walker dereferences pBody
  only when BodyLen > 0; an early-return guards this. }
var
  Root, Got: string;
begin
  Root := MakeTempDir('empty');
  try
    WriteText(JoinPath(Root, 'empty.txt'), '');
    WriteText(JoinPath(Root, 'newlines.txt'), #10#10#10);
    Got := CallGrep(Root, 'anything');
    AssertContains(Got, 'no matches',
                   'empty + newline-only files do not crash and produce no matches');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestHashlineHeaderStillCorrect;
{ Output-equivalence pin: rewrite must keep emitting the
  hashline header (¶path#hash) so fs_edit_hashline downstream
  can still parse it. }
var
  Root, Got: string;
begin
  Root := MakeTempDir('header');
  try
    WriteText(JoinPath(Root, 'src.pas'),
              'line one'#10 + 'line with NEEDLE'#10 + 'line three');
    Got := CallGrep(Root, 'NEEDLE');
    AssertContains(Got, #$C2#$B6, 'hashline pilcrow prefix present');
    AssertContains(Got, 'src.pas#', 'path + # separator present');
    AssertContains(Got, '2:line with NEEDLE',
                   'matching line has correct line number');
  finally
    DeleteTree(Root);
  end;
end;

begin
  Randomize;
  TestLineNumbersExact;
  WriteLn('  ok: tier 5 -- line numbers exact across byte walker');
  TestCRLFLineEndings;
  WriteLn('  ok: tier 5 -- CRLF trimmed inline, no stray CR in output');
  TestNoTrailingNewline;
  WriteLn('  ok: tier 5 -- final line without trailing newline still matched');
  TestMultipleMatchesPerFile;
  WriteLn('  ok: tier 5 -- multiple matches per file, single header');
  TestCaseInsensitiveMatch;
  WriteLn('  ok: tier 6 -- ignore_case via byte-fold table');
  TestOverlappingPatternBytes;
  WriteLn('  ok: tier 6 -- BMH overlapping / partial / embedded patterns');
  TestSingleCharPattern;
  WriteLn('  ok: tier 6 -- m=1 degenerate case');
  TestPatternLongerThanLine;
  WriteLn('  ok: tier 6 -- m > n early-exit (no cross-line scan)');
  TestEmptyAndAllNewlinesFile;
  WriteLn('  ok: tier 5 -- empty / newline-only bodies do not crash');
  TestHashlineHeaderStillCorrect;
  WriteLn('  ok: tier 5+6 -- hashline ¶path#hash header still emitted');
  WriteLn('PASS');
end.
