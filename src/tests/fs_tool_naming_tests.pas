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

function DefsHasName(const Defs: TToolDefinitionArray; const Name: string): Boolean;
var i: Integer;
begin
  Result := False;
  for i := 0 to High(Defs) do
    if Defs[i].Name = Name then Exit(True);
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
  Dir, PathA, PathB, R, Err: string;
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
    WriteLn('  ok: old fs_* names still dispatch as hidden aliases');

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

    { delete (omit new_text) }
    Reg.RunTool('write_file', '{"path":"' + PathA + '","content":"keepDROPkeep"}', Err);
    Reg.RunTool('edit_file', '{"path":"' + PathA + '","old_text":"DROP"}', Err);
    AssertEqStr(ReadBack(Reg, PathA), 'keepkeep', 'edit_file deletes when new_text omitted');
    WriteLn('  ok: edit_file str-replace (unique / not-found / ambiguous / replace_all / delete)');

  finally
    Reg.Free;
    if FileExists(PathA) then DeleteFile(PathA);
    if FileExists(PathB) then DeleteFile(PathB);
    RemoveDir(Dir);
  end;

  WriteLn('PASS');
end.
