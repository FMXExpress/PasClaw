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
  PasClaw.Config,          { TSandboxPolicy }
  PasClaw.Tools.Sandbox,   { ConfigureSandbox -- sets CurrentWorkspace }
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

{ Regression for Codex P2 on PR #298: ReadHead used to Move raw bytes
  into Result[1], which under Delphi (UTF-16 string) garbled the
  snippet and broke UTF-8 multibyte sequences entirely. The fix
  routes through TEncoding.UTF8.GetString. The test writes a README
  containing a multibyte UTF-8 sequence (`é`, C3 A9) and asserts the
  decoded codepoint survives the digest path. }
procedure TestDigestUtf8;
var
  Dir, ReadmePath, Digest: string;
const
  EAcute = #$C3#$A9;  { UTF-8 bytes for U+00E9 }
begin
  Dir := MakeTempDir;
  ReadmePath := JoinPath(Dir, 'README.md');
  WriteFile_(ReadmePath, '# Caf' + EAcute + sLineBreak +
                         'Multibyte UTF-8 must survive the snippet path.' + sLineBreak);
  try
    Digest := BuildProjectDigest(Dir);
    AssertContains(Digest, 'Caf' + EAcute,
                   'UTF-8 multibyte sequence preserved in digest');
    AssertContains(Digest, 'Multibyte UTF-8',
                   'rest of README still present');
  finally
    RemoveTree(Dir);
  end;
end;

{ RunInit returns a populated Outcome with no stdio. The arg-only
  failure paths (missing dir, existing AGENTS.md without --force) are
  safe to exercise without a real provider; the model-call path needs
  an integration setup we don't run here. Covers the structural
  contract the positioned TUI's /init handler relies on. }
procedure TestRunInitArgFailures;
var
  Argv: array of string;
  Outcome: TInitOutcome;
  Dir, ExistingTarget: string;
  Rc: Integer;
begin
  { Missing positional: Status=2, ErrorMsg mentions the bad dir. }
  SetLength(Argv, 1);
  Argv[0] := '/tmp/__pasclaw_no_such_dir_for_init__';
  Rc := RunInit(Argv, Outcome);
  AssertTrue(Rc = 2, 'RunInit returns 2 on missing dir');
  AssertTrue(Outcome.Status = 2, 'Outcome.Status = 2');
  AssertContains(Outcome.ErrorMsg, 'directory does not exist',
                 'errmsg explains the failure');

  { Existing AGENTS.md, no --force: Status=1. }
  Dir := MakeTempDir;
  ExistingTarget := JoinPath(Dir, 'AGENTS.md');
  WriteFile_(ExistingTarget, '# pre-existing' + sLineBreak);
  try
    SetLength(Argv, 1);
    Argv[0] := Dir;
    Rc := RunInit(Argv, Outcome);
    AssertTrue(Rc = 1, 'RunInit returns 1 without --force on existing file');
    AssertContains(Outcome.ErrorMsg, 'already exists',
                   'errmsg explains overwrite refusal');
    AssertContains(Outcome.ErrorMsg, '--force',
                   'errmsg points at the escape hatch');
  finally
    RemoveTree(Dir);
  end;
end;

procedure TestBuildSectionFromWorkspaceNotCwd;
{ The gateway/serve/docker case: AGENTS.md lives in the configured WORKSPACE
  while the process cwd is elsewhere. BuildProjectRulesSection must read the
  WORKSPACE copy -- it previously read only the launch cwd, so a workspace
  AGENTS.md was silently never injected. }
var
  WsDir, CwdDir, Saved, Section: string;
  Pol: TSandboxPolicy;
begin
  WsDir := MakeTempDir;
  CwdDir := MakeTempDir;   { a different dir, with NO AGENTS.md }
  WriteFile_(JoinPath(WsDir, 'AGENTS.md'),
    '# WS' + sLineBreak + 'Use the log() helper, never print().' + sLineBreak);
  Saved := GetCurrentDir;
  try
    SetCurrentDir(CwdDir);
    Pol := Default(TSandboxPolicy);
    ConfigureSandbox(Pol, WsDir);      { CurrentWorkspace := WsDir }
    Section := BuildProjectRulesSection;
    AssertContains(Section, 'Use the log() helper',
      'workspace AGENTS.md is read even when the process cwd is elsewhere');
  finally
    SetCurrentDir(Saved);
    ConfigureSandbox(Default(TSandboxPolicy), '');   { reset workspace }
    RemoveTree(WsDir);
    RemoveTree(CwdDir);
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
  TestDigestUtf8;
  TestRunInitArgFailures;
  { Runs LAST: it configures a real sandbox workspace (module-global
    CurrentWorkspace), which would otherwise leak into the cwd-reliant
    section tests above. }
  TestBuildSectionFromWorkspaceNotCwd;
  Writeln('ok - agents.md ingest + init digest tests passed');
end.
