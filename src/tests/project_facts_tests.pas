program project_facts_tests;
(*
  Covers PasClaw.Agent.ProjectFacts -- the deterministic "## Project"
  system-prompt section (stack / build / test commands / git branch from
  pure file reads). Pins:
    * Makefile detection: target names surface, `make` as build, a test
      target promotes `make test` as THE verify command.
    * package.json scripts surface (npm run build / npm test).
    * Cargo.toml / go.mod fill build/test only when nothing better claimed
      them (Makefile wins).
    * Git branch parsed from .git/HEAD; detached HEAD reported as such.
    * An empty / unrecognisable directory yields NO section.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Agent.ProjectFacts;

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertHas(const Hay, Needle, Msg: string);
begin
  if Pos(Needle, Hay) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing from "' + Copy(Hay, 1, 300) + '")');
end;

procedure AssertNot(const Hay, Needle, Msg: string);
begin
  if Pos(Needle, Hay) > 0 then
    Fail_(Msg + ' (unexpected "' + Needle + '")');
end;

procedure WriteText(const Path, Body: string);
var
  S: TStringList;
begin
  S := TStringList.Create;
  try
    S.Text := Body;
    S.SaveToFile(Path);
  finally
    S.Free;
  end;
end;

procedure Nuke(const Dir: string);
var
  SR: TSearchRec;
begin
  if FindFirst(Dir + '/*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
      begin
        if (SR.Attr and faDirectory) <> 0 then Nuke(Dir + '/' + SR.Name)
        else DeleteFile(Dir + '/' + SR.Name);
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

var
  Dir, S: string;
begin
  Dir := IncludeTrailingPathDelimiter(GetTempDir) + 'pcfacts';
  if DirectoryExists(Dir) then Nuke(Dir);
  ForceDirectories(Dir);

  { Empty dir -> no section. }
  AssertTrue(BuildProjectFactsSection(Dir) = '', 'empty dir yields no section');
  AssertTrue(BuildProjectFactsSection('') = '', 'blank dir yields no section');

  { Makefile with test target + git branch. }
  WriteText(Dir + '/Makefile',
    'CC := gcc'#10 +
    'all: build'#10#9'echo hi'#10 +
    'build:'#10#9'echo build'#10 +
    'test: build'#10#9'echo test'#10 +
    '.PHONY: all'#10 +
    '%.o: %.c'#10#9'cc'#10);
  ForceDirectories(Dir + '/.git');
  WriteText(Dir + '/.git/HEAD', 'ref: refs/heads/feature/x'#10);
  S := BuildProjectFactsSection(Dir);
  AssertHas(S, '## Project', 'section header');
  AssertHas(S, 'Makefile', 'stack names Makefile');
  AssertHas(S, 'Build: make', 'build command is make');
  AssertHas(S, 'Test:  make test', 'test target promotes make test');
  AssertHas(S, 'verify after code edits', 'test line carries the verify nudge');
  AssertHas(S, 'all, build, test', 'target names listed');
  AssertNot(S, '%', 'pattern rules are not listed as targets');
  AssertNot(S, 'CC', 'variable lines are not targets');
  AssertHas(S, 'Git branch: feature/x', 'branch parsed from .git/HEAD');
  AssertHas(S, 'git status', 'points the model at git status for tree state');
  WriteLn('  ok: Makefile + git facts');

  { package.json scripts; Makefile still owns Build/Test. }
  WriteText(Dir + '/package.json',
    '{"name":"x","scripts":{"build":"vite build","test":"vitest run","dev":"vite"}}');
  S := BuildProjectFactsSection(Dir);
  AssertHas(S, 'Node (package.json)', 'stack names Node');
  AssertHas(S, 'npm run build', 'npm build script listed');
  AssertHas(S, 'npm test', 'npm test script listed');
  AssertHas(S, 'Build: make', 'Makefile still owns the build command');
  WriteLn('  ok: package.json scripts');

  { Cargo-only dir: cargo fills build/test. }
  Nuke(Dir); ForceDirectories(Dir);
  WriteText(Dir + '/Cargo.toml', '[package]'#10'name = "x"'#10);
  S := BuildProjectFactsSection(Dir);
  AssertHas(S, 'Rust (Cargo.toml)', 'stack names Rust');
  AssertHas(S, 'Build: cargo build', 'cargo build');
  AssertHas(S, 'Test:  cargo test', 'cargo test');
  WriteLn('  ok: Cargo fallback');

  { Detached HEAD. }
  ForceDirectories(Dir + '/.git');
  WriteText(Dir + '/.git/HEAD', 'deadbeefcafe1234'#10);
  S := BuildProjectFactsSection(Dir);
  AssertHas(S, '(detached: deadbeefcafe', 'detached HEAD reported');
  WriteLn('  ok: detached HEAD');

  Nuke(Dir);
  WriteLn('PASS');
end.
