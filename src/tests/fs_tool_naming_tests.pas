program fs_tool_naming_tests;
(*
  Pins the verb_noun file-tool rename + the new append_file and the
  edit_file string-replacement mode:

    * ToProviderDefs advertises ONLY the new canonical names
      (read_file / write_file / append_file / list_dir / grep_files /
      edit_file) and never the old fs_* names.
    * The old fs_* names remain dispatchable as hidden aliases (Find /
      RunTool still route them) so existing configs / sessions keep
      working.
    * append_file concatenates onto an existing file (and creates it
      when absent).
    * edit_file does old_text->new_text replacement: unique match,
      replace_all, not-found error, ambiguous-match error, and delete
      (omitted new_text).

  Strategy: drive the tools through a real TToolRegistry via RunTool
  with hand-built JSON args against a temp dir. No model, no provider.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.Sandbox,
  PasClaw.Tools.FS;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertFalse(Cond: Boolean; const Msg: string);
begin if Cond then Fail_(Msg); end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' + Copy(Want, 1, 200) + '")');
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing from "' + Copy(Haystack, 1, 200) + '")');
end;

function JEsc(const S: string): string;
var i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    case S[i] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: ;
    else
      Result := Result + S[i];
    end;
end;

function DefsHasName(const Defs: TToolDefinitionArray; const Name: string): Boolean;
var i: Integer;
begin
  Result := False;
  for i := 0 to High(Defs) do
    if Defs[i].Name = Name then Exit(True);
end;

function NamesHas(const Names: TStringArray; const Name: string): Boolean;
var i: Integer;
begin
  Result := False;
  for i := 0 to High(Names) do
    if Names[i] = Name then Exit(True);
end;

{ Read a file back through read_file's plain mode so we don't need a
  separate disk-read helper. }
function ReadBack(Reg: TToolRegistry; const Path: string): string;
var Err: string;
begin
  Result := Reg.RunTool('read_file', '{"path":"' + Path + '","plain":true}', Err);
end;

var
  Reg: TToolRegistry;
  Defs: TToolDefinitionArray;
  Dir, PathA, PathB, PathC, PathN, Patch, R, Err: string;
  T: TTool;
  Pol: TSandboxPolicy;
begin
  Dir := JoinPath(GetTempDir, 'pcfsnaming');
  ForceDirectories(Dir);
  { Pin the workspace to the fixture dir so the B3 nearest-match walk is
    deterministic (it searches from the working directory). }
  Pol := Default(TSandboxPolicy);
  ConfigureSandbox(Pol, Dir);
  PathA := JoinPath(Dir, 'a.txt');
  PathB := JoinPath(Dir, 'b.txt');
  if FileExists(PathA) then DeleteFile(PathA);
  if FileExists(PathB) then DeleteFile(PathB);

  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);

    { --- 1. Provider defs advertise ONLY the new names. --- }
    Defs := Reg.ToProviderDefs;
    AssertTrue(DefsHasName(Defs, 'read_file'),  'read_file advertised');
    AssertTrue(DefsHasName(Defs, 'write_file'), 'write_file advertised');
    AssertTrue(DefsHasName(Defs, 'append_file'),'append_file advertised');
    AssertTrue(DefsHasName(Defs, 'list_dir'),   'list_dir advertised');
    AssertTrue(DefsHasName(Defs, 'grep_files'), 'grep_files advertised');
    AssertTrue(DefsHasName(Defs, 'edit_file'),  'edit_file advertised');
    AssertFalse(DefsHasName(Defs, 'fs_read'),   'fs_read hidden from provider defs');
    AssertFalse(DefsHasName(Defs, 'fs_write'),  'fs_write hidden from provider defs');
    AssertFalse(DefsHasName(Defs, 'fs_list'),   'fs_list hidden from provider defs');
    AssertFalse(DefsHasName(Defs, 'fs_grep'),   'fs_grep hidden from provider defs');
    AssertFalse(DefsHasName(Defs, 'fs_edit_hashline'), 'fs_edit_hashline hidden from provider defs');
    WriteLn('  ok: provider defs advertise new names, hide old aliases');

    { --- 2. Old names still dispatch (hidden aliases). --- }
    AssertTrue(Reg.Find('fs_write', T), 'fs_write alias findable');
    AssertTrue(Reg.Find('edit_file', T), 'edit_file findable');
    R := Reg.RunTool('fs_write', '{"path":"' + PathA + '","content":"hello"}', Err);
    AssertEqStr(Err, '', 'fs_write alias runs without error');
    AssertEqStr(ReadBack(Reg, PathA), 'hello', 'fs_write alias actually wrote the file');
    { Registry.Names (feeds subagent '*' expansion + MCP tools/list) must also
      exclude the hidden aliases, not just ToProviderDefs. }
    AssertTrue(NamesHas(Reg.Names, 'write_file'), 'Names includes canonical write_file');
    AssertFalse(NamesHas(Reg.Names, 'fs_write'),  'Names excludes hidden fs_write alias');
    AssertFalse(NamesHas(Reg.Names, 'fs_edit_hashline'), 'Names excludes hidden fs_edit_hashline alias');
    WriteLn('  ok: old fs_* names still dispatch as hidden aliases, hidden from Names');

    { --- 2b. read_file defaults to plain; hashline is opt-in. --- }
    R := Reg.RunTool('read_file', '{"path":"' + PathA + '"}', Err);
    AssertEqStr(R, 'hello', 'read_file defaults to plain content (no hashline header)');
    R := Reg.RunTool('read_file', '{"path":"' + PathA + '","hashline":true}', Err);
    AssertContains(R, '#', 'read_file hashline:true emits the #hash header');
    AssertContains(R, '1:hello', 'read_file hashline:true emits LINENO:line');
    WriteLn('  ok: read_file plain by default, hashline:true opts in');

    { --- 2c. read_file line ranges (C2), numbered output (F3). --- }
    Reg.RunTool('write_file', '{"path":"' + PathA + '","content":"r1\nr2\nr3\nr4\nr5"}', Err);
    R := Reg.RunTool('read_file', '{"path":"' + PathA + '","start_line":2,"end_line":3}', Err);
    AssertContains(R, '(lines 2-3 of 5', 'range read reports the slice + total');
    AssertContains(R, '2:r2', 'range lines carry their line number (grep cross-ref, N: format)');
    AssertContains(R, '3:r3', 'numbering matches the actual line, not the slice index');
    AssertTrue(Pos('r4', R) = 0, 'range excludes lines past end_line');
    R := Reg.RunTool('read_file', '{"path":"' + PathA + '","start_line":4,"end_line":99}', Err);
    AssertContains(R, '(lines 4-5 of 5', 'end_line clamps to the file end');
    AssertContains(R, '5:r5', 'clamped tail keeps true line numbers');
    { Round-trip guard (P2 on #419): ranged output uses the SAME N: format
      write_file's StripHashlinePrefixes consumes, so a copied indented body
      keeps its exact indentation. A "N: " separator would leave a stray
      leading space after stripping. }
    Reg.RunTool('write_file', '{"path":"' + PathA + '","content":"a\n  indented\nb"}', Err);
    R := Reg.RunTool('read_file', '{"path":"' + PathA + '","start_line":1,"end_line":3}', Err);
    AssertContains(R, '2:  indented', 'numbered slice preserves the two-space indent verbatim');
    { Feed the numbered slice (minus the header) straight back into write_file;
      the two-space indent must survive the auto-strip untouched. Assert on the
      indentation specifically -- the strip path appends a trailing newline via
      TStringList.Text (long-standing), which exact-equality would trip over. }
    Reg.RunTool('write_file', '{"path":"' + PathB + '","content":"1:a\n2:  indented\n3:b"}', Err);
    R := ReadBack(Reg, PathB);
    AssertContains(R, #10 + '  indented' + #10, 'copied numbered body keeps the exact two-space indent');
    AssertTrue(Pos(#10 + '   indented', R) = 0, 'no stray leading space introduced by the stripper');
    AssertTrue(Pos('1:a', R) = 0, 'the N: prefixes were stripped, not written literally');
    if FileExists(PathB) then DeleteFile(PathB);  { the append section below expects PathB absent }
    { empty file + range: must not range-check into Lines[-1] }
    Reg.RunTool('write_file', '{"path":"' + PathA + '","content":""}', Err);
    R := Reg.RunTool('read_file', '{"path":"' + PathA + '","start_line":1,"end_line":5}', Err);
    AssertEqStr(Err, '', 'range read of an empty file is not an error');
    AssertContains(R, '(empty file', 'empty file reports itself instead of crashing');
    WriteLn('  ok: read_file start_line/end_line slices, clamps, round-trips through write_file');
    { restore the fixture the append section below builds on }
    Reg.RunTool('write_file', '{"path":"' + PathA + '","content":"hello"}', Err);

    { --- 3. append_file concatenates. --- }
    R := Reg.RunTool('append_file', '{"path":"' + PathA + '","content":" world"}', Err);
    AssertEqStr(Err, '', 'append_file no error');
    AssertContains(R, 'appended 6 bytes', 'append_file reports byte count');
    AssertEqStr(ReadBack(Reg, PathA), 'hello world', 'append_file concatenated');
    { creates when absent }
    R := Reg.RunTool('append_file', '{"path":"' + PathB + '","content":"fresh"}', Err);
    AssertEqStr(Err, '', 'append_file creates missing file');
    AssertEqStr(ReadBack(Reg, PathB), 'fresh', 'append_file created + wrote');
    WriteLn('  ok: append_file concatenates and creates');

    { --- 4. edit_file string replacement. --- }
    Reg.RunTool('write_file', '{"path":"' + PathA + '","content":"alpha beta gamma"}', Err);
    R := Reg.RunTool('edit_file', '{"path":"' + PathA + '","old_text":"beta","new_text":"BETA"}', Err);
    AssertEqStr(Err, '', 'edit_file unique replace no error');
    AssertEqStr(ReadBack(Reg, PathA), 'alpha BETA gamma', 'edit_file replaced unique match');

    { not found }
    Reg.RunTool('edit_file', '{"path":"' + PathA + '","old_text":"zzz","new_text":"x"}', Err);
    AssertContains(Err, 'not found', 'edit_file not-found error');

    { ambiguous -> refuse without replace_all }
    Reg.RunTool('write_file', '{"path":"' + PathA + '","content":"x x x"}', Err);
    Reg.RunTool('edit_file', '{"path":"' + PathA + '","old_text":"x","new_text":"y"}', Err);
    AssertContains(Err, 'matches 3 times', 'edit_file ambiguous error');

    { replace_all }
    R := Reg.RunTool('edit_file', '{"path":"' + PathA + '","old_text":"x","new_text":"y","replace_all":true}', Err);
    AssertEqStr(Err, '', 'edit_file replace_all no error');
    AssertEqStr(ReadBack(Reg, PathA), 'y y y', 'edit_file replaced all occurrences');

    { mini-diff feedback: the result shows the changed region with line
      numbers and +-3 context so the model needn't re-read the file. }
    Reg.RunTool('write_file', '{"path":"' + PathA + '","content":"l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8"}', Err);
    R := Reg.RunTool('edit_file', '{"path":"' + PathA + '","old_text":"l5","new_text":"L5-CHANGED"}', Err);
    AssertContains(R, 'now reads (lines 2-8):', 'snippet header with clamped range');
    AssertContains(R, '5: L5-CHANGED', 'snippet shows the changed line with its number');
    AssertContains(R, '2: l2', 'snippet includes leading context');
    AssertContains(R, '8: l8', 'snippet includes trailing context');
    AssertTrue(Pos('1: l1', R) = 0, 'context is bounded (line 1 outside +-3)');

    { delete (omit new_text) }
    Reg.RunTool('write_file', '{"path":"' + PathA + '","content":"keepDROPkeep"}', Err);
    Reg.RunTool('edit_file', '{"path":"' + PathA + '","old_text":"DROP"}', Err);
    AssertEqStr(ReadBack(Reg, PathA), 'keepkeep', 'edit_file deletes when new_text omitted');
    WriteLn('  ok: edit_file str-replace (unique / not-found / ambiguous / replace_all / delete)');

    { --- 4b. find_files: glob by NAME (D1). --- }
    AssertTrue(DefsHasName(Reg.ToProviderDefs, 'find_files'), 'find_files advertised');
    ForceDirectories(Dir + PathDelim + 'sub');
    ForceDirectories(Dir + PathDelim + 'node_modules');
    Reg.RunTool('write_file', '{"path":"' + JEsc(Dir + PathDelim + 'sub' + PathDelim + 'deep.pas') + '","content":"x"}', Err);
    Reg.RunTool('write_file', '{"path":"' + JEsc(Dir + PathDelim + 'top.pas') + '","content":"x"}', Err);
    Reg.RunTool('write_file', '{"path":"' + JEsc(Dir + PathDelim + 'node_modules' + PathDelim + 'skip.pas') + '","content":"x"}', Err);
    R := Reg.RunTool('find_files', '{"pattern":"*.pas","path":"' + JEsc(Dir) + '"}', Err);
    AssertEqStr(Err, '', 'find_files no error');
    AssertContains(R, '2 file(s) matching', 'finds both .pas files');
    AssertContains(R, 'top.pas', 'top-level match listed');
    AssertContains(R, 'deep.pas', 'recursive match listed (relative path)');
    AssertTrue(Pos('skip.pas', R) = 0, 'node_modules is skipped');
    R := Reg.RunTool('find_files', '{"pattern":"nosuch.*","path":"' + JEsc(Dir) + '"}', Err);
    AssertContains(R, 'no files matching', 'empty result explains itself');
    AssertContains(R, 'grep_files', 'empty result points at the contents-search sibling');
    WriteLn('  ok: find_files globs by name, skips deps dirs');

    { --- 4c. B3: errors state the next move. --- }
    { Wrong directory, right name: nearest-match suggestion (deep.pas lives
      in sub/ from 4b, requested at the root). }
    Reg.RunTool('read_file', '{"path":"' + JEsc(Dir + PathDelim + 'deep.pas') + '"}', Err);
    AssertContains(Err, 'Did you mean', 'no-such-file suggests nearby names');
    AssertContains(Err, 'deep.pas', 'suggestion names the actual location');
    { Nothing similar: point at find_files instead. }
    Reg.RunTool('read_file', '{"path":"' + JEsc(Dir + PathDelim + 'zzqq-none.pas') + '"}', Err);
    AssertContains(Err, 'find_files', 'no-match error points at find_files');
    { Unknown tool: suggest similar registered names. }
    Reg.RunTool('read_files', '{}', Err);
    AssertContains(Err, 'unknown tool', 'unknown tool still errors');
    AssertContains(Err, 'did you mean', 'unknown tool suggests');
    AssertContains(Err, 'read_file', 'suggestion includes the real name');
    { Shell denial carries a remediation. }
    Pol.ShellDenyEnabled := True;
    ConfigureSandbox(Pol, Dir);
    AssertTrue(not ShellAllowed('sudo ls', R), 'denylist still refuses');
    AssertContains(R, 'dedicated tools', 'denial suggests the tool alternatives');
    { A delete/move token points at apply_patch (the only in-box way to
      remove a file) -- the old message named tools that can't delete. }
    AssertTrue(not ShellAllowed('rm -rf build', R), 'rm still refused');
    AssertContains(R, 'apply_patch', 'rm remediation names apply_patch for deletion');
    AssertContains(R, 'Delete File', 'rm remediation shows the Delete File section');
    { Command substitution is labelled correctly (not conflated with the
      dollar-brace pattern). }
    AssertTrue(not ShellAllowed('echo $(whoami)', R), 'command substitution refused');
    AssertContains(R, 'command substitution', 'the $( refusal names command substitution');
    { Parameter expansion stays refused, with an accurate label: the shell
      expands it before the scanner runs, so it can reassemble a blocked
      token. Both a plain use and the reassembly-bypass forms are caught. }
    AssertTrue(not ShellAllowed('echo ${PIPESTATUS[0]}', R), 'parameter expansion refused');
    AssertContains(R, 'parameter expansion', 'the ${ refusal names parameter expansion');
    AssertTrue(not ShellAllowed('r${X}m -rf build', R),
      'expansion-reassembly of a forbidden token (rm) is refused');
    AssertTrue(not ShellAllowed('curl x | b${X}ash', R),
      'expansion-reassembly of a pipe-to-shell is refused');
    Pol.ShellDenyEnabled := False;
    ConfigureSandbox(Pol, Dir);
    WriteLn('  ok: errors carry the next move (nearest file / similar tool / shell alternative / apply_patch delete)');

    { --- 4d. F2: grep_files context_lines (grep -C). Matches keep the
      LINENO: anchor shape; context lines are LINENO- so the two can't be
      confused; non-contiguous groups get grep's -- fence. --- }
    Reg.RunTool('write_file', '{"path":"' + JEsc(JoinPath(Dir, 'ctx.txt')) +
      '","content":"a1\na2\nHIT here\na4\na5\na6\nHIT again\na8"}', Err);
    R := Reg.RunTool('grep_files', '{"path":"' + JEsc(JoinPath(Dir, 'ctx.txt')) +
      '","pattern":"HIT","context_lines":1}', Err);
    AssertEqStr(Err, '', 'grep_files context_lines no error');
    AssertContains(R, '3:HIT here', 'match keeps the LINENO: anchor prefix');
    AssertContains(R, '2-a2', 'before-context line carries LINENO-');
    AssertContains(R, '4-a4', 'after-context line emitted');
    AssertContains(R, '6-a6', 'second group has its own before-context');
    AssertContains(R, '--'#10, 'non-contiguous groups separated by a -- fence');
    AssertTrue(Pos('a5', R) = 0, 'lines outside every context window stay out');
    R := Reg.RunTool('grep_files', '{"path":"' + JEsc(JoinPath(Dir, 'ctx.txt')) +
      '","pattern":"HIT"}', Err);
    AssertTrue(Pos('a2', R) = 0, 'without context_lines the output is matches-only (unchanged)');
    { A 0-match regex-shaped pattern (alternation) gets a next-move hint that
      grep_files is literal-substring, not regex. A plain 0-match does not. }
    R := Reg.RunTool('grep_files', '{"path":"' + JEsc(JoinPath(Dir, 'ctx.txt')) +
      '","pattern":"HIT|MISS"}', Err);
    AssertContains(R, 'no matches', 'alternation pattern finds nothing (literal match)');
    AssertContains(R, 'LITERAL substring', 'regex-shaped 0-match hints that grep is literal');
    R := Reg.RunTool('grep_files', '{"path":"' + JEsc(JoinPath(Dir, 'ctx.txt')) +
      '","pattern":"NOPEPLAIN"}', Err);
    AssertContains(R, 'no matches', 'plain miss reports no matches');
    AssertTrue(Pos('LITERAL substring', R) = 0, 'a plain 0-match gets NO regex hint');
    WriteLn('  ok: grep_files context_lines + regex-shaped 0-match hint');

    { --- 5. apply_patch: multi-file (update + add + delete) in one call. --- }
    AssertTrue(DefsHasName(Reg.ToProviderDefs, 'apply_patch'), 'apply_patch advertised');
    PathC := JoinPath(Dir, 'c.txt');
    PathN := JoinPath(Dir, 'new.txt');
    Reg.RunTool('write_file', '{"path":"' + PathA + '","content":"line1\nline2\nline3"}', Err);
    Reg.RunTool('write_file', '{"path":"' + PathC + '","content":"doomed"}', Err);
    if FileExists(PathN) then DeleteFile(PathN);
    Patch :=
      '*** Begin Patch'#10 +
      '*** Update File: ' + PathA + #10 +
      ' line1'#10 +
      '-line2'#10 +
      '+LINE2'#10 +
      ' line3'#10 +
      '*** Add File: ' + PathN + #10 +
      '+brand new'#10 +
      '*** Delete File: ' + PathC + #10 +
      '*** End Patch'#10;
    R := Reg.RunTool('apply_patch', '{"patch":"' + JEsc(Patch) + '"}', Err);
    AssertEqStr(Err, '', 'apply_patch no error');
    AssertContains(R, '1 added', 'apply_patch reports 1 added');
    AssertContains(R, '1 updated', 'apply_patch reports 1 updated');
    AssertContains(R, '1 deleted', 'apply_patch reports 1 deleted');
    { F4: B2 parity -- the update carries the edit_file-style mini-diff
      of its first changed region, so the model verifies placement from
      the tool result instead of re-reading the file it just patched. }
    AssertContains(R, 'now reads (lines', 'apply_patch result carries the mini-diff snippet');
    AssertContains(R, '2: LINE2', 'snippet shows the replacement on its real line');
    AssertEqStr(ReadBack(Reg, PathA), 'line1' + #10 + 'LINE2' + #10 + 'line3',
      'apply_patch applied the context hunk');
    AssertContains(ReadBack(Reg, PathN), 'brand new', 'apply_patch added the new file');
    AssertFalse(FileExists(PathC), 'apply_patch deleted the file');

    { A patch whose context does not match writes nothing (atomic). }
    Reg.RunTool('write_file', '{"path":"' + PathA + '","content":"unchanged"}', Err);
    Reg.RunTool('apply_patch',
      '{"patch":"' + JEsc('*** Begin Patch'#10'*** Update File: ' + PathA + #10'-nope'#10'+yep'#10'*** End Patch'#10) + '"}',
      Err);
    AssertContains(Err, 'context not found', 'apply_patch reports a missing-context failure');
    AssertContains(Err, 'start_line', 'context failure tells the model to re-read the region');
    AssertEqStr(ReadBack(Reg, PathA), 'unchanged', 'apply_patch wrote nothing on failure');

    { Add File onto an existing path must refuse (not silently clobber). PathN
      already exists ("brand new") from the successful patch above. }
    R := Reg.RunTool('apply_patch',
      '{"patch":"' + JEsc('*** Begin Patch'#10'*** Add File: ' + PathN + #10'+overwrite'#10'*** End Patch'#10) + '"}',
      Err);
    AssertContains(Err, 'already exists', 'apply_patch refuses Add File onto an existing path');
    AssertContains(ReadBack(Reg, PathN), 'brand new', 'apply_patch did NOT clobber the existing file');
    WriteLn('  ok: apply_patch (update+add+delete, atomic on failure, no-clobber Add)');

  finally
    Reg.Free;
    if FileExists(PathA) then DeleteFile(PathA);
    if FileExists(PathB) then DeleteFile(PathB);
    if FileExists(PathC) then DeleteFile(PathC);
    if FileExists(PathN) then DeleteFile(PathN);
    RemoveDir(Dir);
  end;

  WriteLn('PASS');
end.
