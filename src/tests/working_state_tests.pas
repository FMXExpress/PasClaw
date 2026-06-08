program working_state_tests;
(*
  Covers the working-state snapshot helpers in PasClaw.Session.Store:

    - UpdateWorkingStateAfterTurn  pulls edited paths from fs_write /
                                    fs_edit_hashline calls, the most
                                    recent shell command, and the
                                    most recent tool error.
    - FormatWorkingStateBlock      renders the snapshot as a
                                    system-prompt prefix the next
                                    turn can prepend, or '' when no
                                    field is populated.

  Round-trip through TSession.Save/Load is exercised so the new
  'working_state' JSON object survives a /quit-then-resume cycle.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Session.Store;

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

function MakeAssistantWithToolCall(const ToolName, ArgsJSON: string): TMessage;
begin
  Result := Default(TMessage);
  Result.Role := mrAssistant;
  SetLength(Result.ToolCalls, 1);
  Result.ToolCalls[0].Id := 'call-1';
  Result.ToolCalls[0].Func.Name := ToolName;
  Result.ToolCalls[0].Func.Arguments := ArgsJSON;
end;

function MakeToolResult(const ResultText: string): TMessage;
begin
  Result := Default(TMessage);
  Result.Role := mrTool;
  Result.Content := ResultText;
end;

procedure TestExtractsFsWritePaths;
{ The basic case: fs_write should populate EditedFiles. The TUI
  surfaces this on the next turn so the model knows what it just
  touched even after compaction has dropped the tool call. }
var
  Meta: TSessionMeta;
  Hist: array of TMessage;
begin
  Meta := Default(TSessionMeta);
  SetLength(Hist, 2);
  Hist[0] := MakeAssistantWithToolCall('fs_write', '{"path":"src/a.pas","content":"unit a;"}');
  Hist[1] := MakeAssistantWithToolCall('fs_write', '{"path":"src/b.pas","content":"unit b;"}');
  UpdateWorkingStateAfterTurn(Meta, Hist);
  AssertTrue(Length(Meta.WorkingState.EditedFiles) = 2,
             'fs_write paths captured (got ' +
             IntToStr(Length(Meta.WorkingState.EditedFiles)) + ')');
  { Newest-first invariant. }
  AssertEqStr(Meta.WorkingState.EditedFiles[0], 'src/b.pas',
              'most recent fs_write at index 0');
  AssertEqStr(Meta.WorkingState.EditedFiles[1], 'src/a.pas',
              'earlier fs_write at index 1');
end;

procedure TestExtractsFsEditPathsAndDedupes;
{ fs_edit_hashline is treated identically to fs_write. Re-editing
  the same file shouldn't grow EditedFiles -- the second hit moves
  the path to front (newest), not appends a duplicate. }
var
  Meta: TSessionMeta;
  Hist: array of TMessage;
begin
  Meta := Default(TSessionMeta);
  SetLength(Hist, 3);
  Hist[0] := MakeAssistantWithToolCall('fs_edit_hashline', '{"patch":"...","path":"src/a.pas"}');
  Hist[1] := MakeAssistantWithToolCall('fs_write',         '{"path":"src/b.pas","content":""}');
  Hist[2] := MakeAssistantWithToolCall('fs_edit_hashline', '{"path":"src/a.pas","patch":"..."}');
  UpdateWorkingStateAfterTurn(Meta, Hist);
  AssertTrue(Length(Meta.WorkingState.EditedFiles) = 2,
             'duplicate path deduped (got ' +
             IntToStr(Length(Meta.WorkingState.EditedFiles)) + ')');
  AssertEqStr(Meta.WorkingState.EditedFiles[0], 'src/a.pas',
              're-edited file moved to front');
  AssertEqStr(Meta.WorkingState.EditedFiles[1], 'src/b.pas',
              'other path stays in list');
end;

procedure TestCapturesShellAndError;
{ Shell + error are independent fields. A failing shell call
  populates BOTH (the command via the assistant tool_call, the
  error via the tool result). }
var
  Meta: TSessionMeta;
  Hist: array of TMessage;
begin
  Meta := Default(TSessionMeta);
  SetLength(Hist, 2);
  Hist[0] := MakeAssistantWithToolCall('shell_exec', '{"command":"make test"}');
  Hist[1] := MakeToolResult('ERROR: exit code 1');
  UpdateWorkingStateAfterTurn(Meta, Hist);
  AssertEqStr(Meta.WorkingState.LastShell, 'make test',
              'shell_exec command captured');
  AssertEqStr(Meta.WorkingState.LastError, 'exit code 1',
              'tool error captured (stripping ERROR: prefix)');
  AssertTrue(Meta.WorkingState.Updated > 0, 'Updated timestamp set');
end;

procedure TestFormatBlockSkipsEmpty;
{ Empty snapshot -> empty string, so callers can prepend
  unconditionally without polluting the prompt of fresh sessions. }
var
  Meta: TSessionMeta;
begin
  Meta := Default(TSessionMeta);
  AssertEqStr(FormatWorkingStateBlock(Meta), '',
              'empty snapshot formats to empty string');
end;

procedure TestFormatBlockRendersFields;
var
  Meta: TSessionMeta;
  S: string;
begin
  Meta := Default(TSessionMeta);
  SetLength(Meta.WorkingState.EditedFiles, 2);
  Meta.WorkingState.EditedFiles[0] := 'src/a.pas';
  Meta.WorkingState.EditedFiles[1] := 'src/b.pas';
  Meta.WorkingState.LastShell := 'make test';
  Meta.WorkingState.LastError := 'exit 1';
  S := FormatWorkingStateBlock(Meta);
  AssertTrue(Pos('Working state', S) > 0, 'header present');
  AssertTrue(Pos('src/a.pas', S) > 0,     'first edited file present');
  AssertTrue(Pos('src/b.pas', S) > 0,     'second edited file present');
  AssertTrue(Pos('make test', S) > 0,     'shell command present');
  AssertTrue(Pos('exit 1',    S) > 0,     'error present');
end;

procedure TestSaveLoadRoundTrip;
{ The 'working_state' JSON object should round-trip through
  TSession.Save/Load so a /quit-then-resume picks up where the
  prior session left off. Uses a synthetic session id under
  $PASCLAW_HOME so we don't collide with a real session. }
var
  Id: string;
  S1, S2: TSession;
begin
  Id := 'working-state-test-' + IntToStr(GetTickCount64);
  S1 := TSession.Create(Id);
  try
    SetLength(S1.Meta.WorkingState.EditedFiles, 2);
    S1.Meta.WorkingState.EditedFiles[0] := 'src/x.pas';
    S1.Meta.WorkingState.EditedFiles[1] := 'src/y.pas';
    S1.Meta.WorkingState.LastShell := 'make build';
    S1.Meta.WorkingState.LastError := 'undefined symbol';
    S1.Meta.WorkingState.Updated   := 1234567890;
    S1.Save;
  finally
    S1.Free;
  end;

  S2 := TSession.Create(Id);
  try
    AssertTrue(Length(S2.Meta.WorkingState.EditedFiles) = 2,
               'EditedFiles round-trips (got ' +
               IntToStr(Length(S2.Meta.WorkingState.EditedFiles)) + ')');
    AssertEqStr(S2.Meta.WorkingState.EditedFiles[0], 'src/x.pas',
                'first edited path round-trips');
    AssertEqStr(S2.Meta.WorkingState.EditedFiles[1], 'src/y.pas',
                'second edited path round-trips');
    AssertEqStr(S2.Meta.WorkingState.LastShell, 'make build',
                'shell round-trips');
    AssertEqStr(S2.Meta.WorkingState.LastError, 'undefined symbol',
                'error round-trips');
    AssertTrue(S2.Meta.WorkingState.Updated = 1234567890,
               'Updated round-trips');
  finally
    S2.Free;
    DeleteSession(Id);
  end;
end;

procedure TestEmptyWorkingStateNotEmitted;
{ A session that never produced any working-state signals
  shouldn't carry a 'working_state' JSON object -- pre-feature
  session files should round-trip byte-stable (minus the
  unrelated meta fields). We can't easily diff the JSON here, but
  loading after a save with empty state should still yield an
  empty struct. }
var
  Id: string;
  S1, S2: TSession;
begin
  Id := 'working-state-empty-' + IntToStr(GetTickCount64);
  S1 := TSession.Create(Id);
  try
    { No working-state assignments. }
    S1.Save;
  finally
    S1.Free;
  end;

  S2 := TSession.Create(Id);
  try
    AssertTrue(Length(S2.Meta.WorkingState.EditedFiles) = 0,
               'empty EditedFiles');
    AssertEqStr(S2.Meta.WorkingState.LastShell, '', 'empty LastShell');
    AssertEqStr(S2.Meta.WorkingState.LastError, '', 'empty LastError');
    AssertTrue(S2.Meta.WorkingState.Updated = 0, 'zero Updated');
  finally
    S2.Free;
    DeleteSession(Id);
  end;
end;

begin
  TestExtractsFsWritePaths;
  TestExtractsFsEditPathsAndDedupes;
  TestCapturesShellAndError;
  TestFormatBlockSkipsEmpty;
  TestFormatBlockRendersFields;
  TestSaveLoadRoundTrip;
  TestEmptyWorkingStateNotEmitted;
  WriteLn('working_state_tests: OK');
end.
