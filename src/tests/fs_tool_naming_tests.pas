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
  PasClaw.Providers.Types,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
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
begin
  Dir := JoinPath(GetTempDir, 'pcfsnaming');
  ForceDirectories(Dir);
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

    { --- 2c. read_file line ranges (C2). --- }
    Reg.RunTool('write_file', '{"path":"' + PathA + '","content":"r1\nr2\nr3\nr4\nr5"}', Err);
    R := Reg.RunTool('read_file', '{"path":"' + PathA + '","start_line":2,"end_line":3}', Err);
    AssertContains(R, '(lines 2-3 of 5)', 'range read reports the slice + total');
    AssertContains(R, 'r2', 'range includes start line');
    AssertContains(R, 'r3', 'range includes end line');
    AssertTrue(Pos('r4', R) = 0, 'range excludes lines past end_line');
    R := Reg.RunTool('read_file', '{"path":"' + PathA + '","start_line":4,"end_line":99}', Err);
    AssertContains(R, '(lines 4-5 of 5)', 'end_line clamps to the file end');
    WriteLn('  ok: read_file start_line/end_line slices and clamps');
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
