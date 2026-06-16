program agents_md_tests;
{ Coverage for the AGENTS.md project-rules ingest path:
    - FindProjectAgentsMd walks up from a given dir, stops at git root.
    - BuildProjectRulesSection injects the body when present, omits when
      absent, tail-truncates when oversized.
    - UnfenceMarkdown strips a leading ```...``` if the model added one.

  Pure helpers only -- no provider calls, no network. A temp-dir
  fixture is set up per test so they're hermetic on any host. }
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Agent.Prompt,
  PasClaw.Cmd.Init,
  PasClaw.Utils;

procedure Fail_(const Msg: string);
begin
  Writeln('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertEqS(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) = 0 then
    Fail_(Msg + ' (haystack="' + Copy(Haystack, 1, 80) +
          '...", needle="' + Needle + '")');
end;

procedure WriteFile_(const Path, Content: string);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(Path, fmCreate);
  try
    if Length(Content) > 0 then
      FS.WriteBuffer(Content[1], Length(Content));
  finally
    FS.Free;
  end;
end;

function MakeTempDir: string;
begin
  Result := JoinPath(GetTempDir(False),
                     'pasclaw_agents_md_test_' + IntToStr(Random(MaxInt)));
  ForceDirectories(Result);
end;

procedure RemoveTree(const Path: string);
var
  Sr: TSearchRec;
  Sub: string;
begin
  if not DirectoryExists(Path) then Exit;
  if FindFirst(JoinPath(Path, '*'), faAnyFile, Sr) = 0 then
  try
    repeat
      if (Sr.Name = '.') or (Sr.Name = '..') then Continue;
      Sub := JoinPath(Path, Sr.Name);
      if (Sr.Attr and faDirectory) <> 0 then
        RemoveTree(Sub)
      else
        DeleteFile(Sub);
    until FindNext(Sr) <> 0;
  finally
    FindClose(Sr);
  end;
  RemoveDir(Path);
end;

procedure TestFindMissing;
var
  Dir: string;
begin
  Dir := MakeTempDir;
  try
    AssertEqS(FindProjectAgentsMd(Dir), '', 'absent -> empty');
  finally
    RemoveTree(Dir);
  end;
end;

procedure TestFindInCwd;
var
  Dir, AgentsPath, Found: string;
begin
  Dir := MakeTempDir;
  AgentsPath := JoinPath(Dir, 'AGENTS.md');
  WriteFile_(AgentsPath, '# Local' + sLineBreak);
  try
    Found := FindProjectAgentsMd(Dir);
    AssertTrue(SameFileName(Found, AgentsPath),
               'found in cwd (got "' + Found + '")');
  finally
    RemoveTree(Dir);
  end;
end;

procedure TestFindWalksToGitRoot;
var
  Root, Nested, AgentsPath, Found: string;
begin
  { Layout:
      <root>/.git/         (marks the project root)
      <root>/AGENTS.md     (the file we should find)
      <root>/a/b/c/        (start dir 3 levels deep) }
  Root := MakeTempDir;
  AgentsPath := JoinPath(Root, 'AGENTS.md');
  ForceDirectories(JoinPath(Root, '.git'));
  WriteFile_(AgentsPath, '# Root rules' + sLineBreak);
  Nested := JoinPath(JoinPath(JoinPath(Root, 'a'), 'b'), 'c');
  ForceDirectories(Nested);
  try
    Found := FindProjectAgentsMd(Nested);
    AssertTrue(SameFileName(Found, AgentsPath),
               'walks up to git root (got "' + Found + '")');
  finally
    RemoveTree(Root);
  end;
end;

procedure TestFindStopsAtGitRoot;
var
  Outer, Root, OuterAgents, Found: string;
begin
  { An AGENTS.md sitting ABOVE the .git boundary must NOT be picked up
    -- once we cross the git root, we stop. Otherwise a nested project
    inside a monorepo would inherit the outer project's rules. }
  Outer := MakeTempDir;
  Root := JoinPath(Outer, 'inner');
  ForceDirectories(JoinPath(Root, '.git'));
  OuterAgents := JoinPath(Outer, 'AGENTS.md');
  WriteFile_(OuterAgents, '# Outer (should not be picked up)' + sLineBreak);
  try
    Found := FindProjectAgentsMd(Root);
    AssertEqS(Found, '', 'inner project does not inherit outer AGENTS.md');
  finally
    RemoveTree(Outer);
  end;
end;

procedure TestBuildSectionAbsent;
var
  Dir, Saved, Section: string;
begin
  { Run with cwd pointed at a known-empty temp dir so the lookup
    definitely misses; nothing else should change. }
  Dir := MakeTempDir;
  Saved := GetCurrentDir;
  try
    SetCurrentDir(Dir);
    Section := BuildProjectRulesSection;
    AssertEqS(Section, '', 'absent file -> empty section');
  finally
    SetCurrentDir(Saved);
    RemoveTree(Dir);
  end;
end;

procedure TestBuildSectionPresent;
var
  Dir, AgentsPath, Saved, Section: string;
begin
  Dir := MakeTempDir;
  AgentsPath := JoinPath(Dir, 'AGENTS.md');
  WriteFile_(AgentsPath,
    '# Demo' + sLineBreak +
    'Prefer X over Y.' + sLineBreak);
  Saved := GetCurrentDir;
  try
    SetCurrentDir(Dir);
    Section := BuildProjectRulesSection;
    AssertContains(Section, 'Project Rules (AGENTS.md)', 'section header present');
    AssertContains(Section, 'Prefer X over Y.', 'body included');
    AssertContains(Section, 'cross-tool convention',
                   'preamble names cross-tool convention');
  finally
    SetCurrentDir(Saved);
    RemoveTree(Dir);
  end;
end;

procedure TestBuildSectionTruncated;
var
  Dir, AgentsPath, Saved, Section, Big: string;
  i: Integer;
begin
  { 80 KB of 'a' -- well over the 64 KB cap. Tail must be replaced with
    an elision notice; the head must survive. }
  Dir := MakeTempDir;
  AgentsPath := JoinPath(Dir, 'AGENTS.md');
  Big := '# Big' + sLineBreak;
  for i := 1 to 80 * 1024 do
    Big := Big + 'a';
  WriteFile_(AgentsPath, Big);
  Saved := GetCurrentDir;
  try
    SetCurrentDir(Dir);
    Section := BuildProjectRulesSection;
    AssertContains(Section, '# Big', 'head preserved');
    AssertContains(Section, 'elided', 'truncation notice present');
    AssertTrue(Length(Section) < 70 * 1024,
               Format('section bounded under 70 KB (got %d)', [Length(Section)]));
  finally
    SetCurrentDir(Saved);
    RemoveTree(Dir);
  end;
end;

procedure TestUnfenceBare;
begin
  AssertEqS(UnfenceMarkdown('plain body, no fences'),
            'plain body, no fences',
            'bare text unchanged');
  AssertEqS(UnfenceMarkdown(''), '', 'empty unchanged');
end;

procedure TestUnfenceWrapped;
var
  Wrapped, Got: string;
begin
  Wrapped := '```markdown' + sLineBreak +
             '# Title' + sLineBreak +
             'Body' + sLineBreak +
             '```';
  Got := UnfenceMarkdown(Wrapped);
  AssertContains(Got, '# Title', 'title preserved');
  AssertContains(Got, 'Body',    'body preserved');
  AssertTrue(Pos('```', Got) = 0, 'opening fence stripped');
end;

procedure TestDigestShape;
var
  Dir, ReadmePath, Digest: string;
begin
  Dir := MakeTempDir;
  ReadmePath := JoinPath(Dir, 'README.md');
  WriteFile_(ReadmePath, '# DigestProj' + sLineBreak +
                         'A sample for the digest test.' + sLineBreak);
  ForceDirectories(JoinPath(Dir, 'src'));
  WriteFile_(JoinPath(JoinPath(Dir, 'src'), 'main.pas'), '// stub');
  try
    Digest := BuildProjectDigest(Dir);
    AssertContains(Digest, 'Project root',  'digest names root');
    AssertContains(Digest, 'File tree',     'digest has tree section');
    AssertContains(Digest, 'README.md',     'digest lists README');
    AssertContains(Digest, 'Key files',     'digest has key-files section');
    AssertContains(Digest, '# DigestProj',  'README contents quoted');
    AssertContains(Digest, 'src/',          'subdir listed');
  finally
    RemoveTree(Dir);
  end;
end;

begin
  Randomize;
  TestFindMissing;
  TestFindInCwd;
  TestFindWalksToGitRoot;
  TestFindStopsAtGitRoot;
  TestBuildSectionAbsent;
  TestBuildSectionPresent;
  TestBuildSectionTruncated;
  TestUnfenceBare;
  TestUnfenceWrapped;
  TestDigestShape;
  Writeln('ok - agents.md ingest + init digest tests passed');
end.
