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
  PasClaw.JSON,
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

procedure TestSortNewestFirst;
{ The sort underpins the TUI session pane and `pasclaw session list`
  -- both surfaces want the freshest session at index 0. Pin the
  primary key (UpdatedAt desc) and the tiebreakers (CreatedAt
  desc, then Id desc) so a regression here doesn't silently
  reshuffle the lists. }
var
  Arr: TSessionMetaArray;
begin
  SetLength(Arr, 4);
  Arr[0].Id := 'a'; Arr[0].CreatedAt := 100; Arr[0].UpdatedAt := 500;
  Arr[1].Id := 'b'; Arr[1].CreatedAt := 200; Arr[1].UpdatedAt := 700;
  Arr[2].Id := 'c'; Arr[2].CreatedAt := 300; Arr[2].UpdatedAt := 700;  { tie with b on Updated; newer CreatedAt }
  Arr[3].Id := 'd'; Arr[3].CreatedAt := 150; Arr[3].UpdatedAt := 600;

  SortSessionsNewestFirst(Arr);

  AssertEqStr(Arr[0].Id, 'c', 'newest UpdatedAt+CreatedAt at index 0');
  AssertEqStr(Arr[1].Id, 'b', 'tie on UpdatedAt broken by CreatedAt');
  AssertEqStr(Arr[2].Id, 'd', 'next-newest UpdatedAt at index 2');
  AssertEqStr(Arr[3].Id, 'a', 'oldest at index 3');
end;

procedure TestExtractsApplyPatchAndHashlinePaths;
{ apply_patch writes carry no `path` arg -- their targets live in the
  `patch` envelope. A hashline edit_file patch likewise starts with a
  |path#hash header. Both must land in EditedFiles or patch-written files
  silently vanish from the working state (the bug the webui dropdown had). }
var
  Meta: TSessionMeta;
  Hist: array of TMessage;
  Found: array[0..2] of Boolean;
  i, j: Integer;
  Want: array[0..2] of string;
begin
  Meta := Default(TSessionMeta);
  SetLength(Hist, 2);
  Hist[0] := MakeAssistantWithToolCall('apply_patch',
    '{"patch":"*** Begin Patch\n*** Update File: src/game.pas\n*** Add File: src/new.pas\n*** Delete File: src/old.pas\n*** End Patch\n"}');
  { edit_file in hashline mode: the header is <U+00B6>path#hash. }
  Hist[1] := MakeAssistantWithToolCall('edit_file',
    '{"patch":"' + #$C2#$B6 + 'src/hash.pas#a1b2\n@@ -1,1 +1,1 @@\n-a\n+b\n"}');
  UpdateWorkingStateAfterTurn(Meta, Hist);

  Want[0] := 'src/game.pas';   { Update target }
  Want[1] := 'src/new.pas';    { Add target }
  Want[2] := 'src/hash.pas';   { hashline header }
  for j := 0 to 2 do Found[j] := False;
  for i := 0 to High(Meta.WorkingState.EditedFiles) do
  begin
    { deletes must NOT be tracked }
    AssertTrue(Meta.WorkingState.EditedFiles[i] <> 'src/old.pas',
      'deleted file must not appear in the working state');
    for j := 0 to 2 do
      if Meta.WorkingState.EditedFiles[i] = Want[j] then Found[j] := True;
  end;
  for j := 0 to 2 do
    AssertTrue(Found[j], 'patch-written path captured: ' + Want[j]);
end;

(* ---- MergeSessionContext: what a session-context turn runs against ----

   The desktop no longer holds its own transcript. It sends the message
   the person just typed and the gateway supplies everything before it,
   so this merge IS the conversation the model sees. Three things have
   to hold, and the third is the one that bit: the merged array must
   grow by exactly the new messages, because appending the stored ones
   to a client that ALSO sent them doubled every turn. *)

function Msg(R: TMsgRole; const C: string): TMessage;
begin
  Result := Default(TMessage);
  Result.Role := R;
  Result.Content := C;
end;

(* ---- the transcript log: compaction stops costing the record ----

   The bug these pin: a compaction rebuilds the live transcript around
   a summary, every surface writes that back as the session, and the
   turns it summarised are gone. The log is what keeps them. *)

{ These tests drive LogSessionTurn without ever saving a session, so
  DeleteSession has no session file to work from -- remove the record
  directly. }
procedure CleanLog(const Id: string);
var
  P: string;
begin
  P := SessionLogPath(Id);
  if (P <> '') and FileExists(P) then SysUtils.DeleteFile(P);
end;

function LogMsg(R: TMsgRole; const C: string): TMessage;
begin
  Result := Default(TMessage);
  Result.Role := R;
  Result.Content := C;
end;

procedure TestMergePutsStoredFirst;
var
  Stored, Fresh, Merged: TMessageArray;
begin
  SetLength(Stored, 4);
  Stored[0] := Msg(mrUser, 'one');
  Stored[1] := Msg(mrAssistant, 'reply one');
  Stored[2] := Msg(mrUser, 'two');
  Stored[3] := Msg(mrAssistant, 'reply two');
  SetLength(Fresh, 1);
  Fresh[0] := Msg(mrUser, 'three');

  Merged := MergeSessionContext(Stored, Fresh);
  AssertTrue(Length(Merged) = 5, 'merged length is stored + fresh');
  AssertEqStr(Merged[0].Content, 'one', 'oldest stored turn leads');
  AssertEqStr(Merged[3].Content, 'reply two', 'stored order preserved');
  AssertEqStr(Merged[4].Content, 'three', 'the new turn goes last');
end;

procedure TestMergeDropsStoredSystemTurns;
var
  Stored, Fresh, Merged: TMessageArray;
  i: Integer;
begin
  SetLength(Stored, 3);
  Stored[0] := Msg(mrSystem, 'a system prompt from an older turn');
  Stored[1] := Msg(mrUser, 'one');
  Stored[2] := Msg(mrAssistant, 'reply one');
  SetLength(Fresh, 1);
  Fresh[0] := Msg(mrUser, 'two');

  Merged := MergeSessionContext(Stored, Fresh);
  AssertTrue(Length(Merged) = 3, 'the stored system turn is dropped');
  for i := 0 to High(Merged) do
    AssertTrue(Merged[i].Role <> mrSystem,
      'no stored system turn survives the merge');
  AssertEqStr(Merged[0].Content, 'one', 'the conversation still starts at one');
  AssertEqStr(Merged[2].Content, 'two', 'the new turn is still last');
end;

procedure TestMergeKeepsToolTurns;
var
  Stored, Fresh, Merged: TMessageArray;
begin
  { A model that called a tool has to see its own result, or the next
    turn reads as an answer that came from nowhere. }
  SetLength(Stored, 3);
  Stored[0] := Msg(mrUser, 'write the file');
  Stored[1] := MakeAssistantWithToolCall('fs_write', '{"path":"a.txt"}');
  Stored[2] := Msg(mrTool, 'ok');
  SetLength(Fresh, 1);
  Fresh[0] := Msg(mrUser, 'now read it back');

  Merged := MergeSessionContext(Stored, Fresh);
  AssertTrue(Length(Merged) = 4, 'tool call and tool result both survive');
  AssertTrue(Merged[1].Role = mrAssistant, 'the tool call survives');
  AssertTrue(Length(Merged[1].ToolCalls) = 1, 'with its tool call intact');
  AssertTrue(Merged[2].Role = mrTool, 'the tool result survives');
end;

procedure TestMergeOnAnEmptySession;
var
  Stored, Fresh, Merged: TMessageArray;
begin
  { The first turn of a conversation: nothing stored yet, and the
    request must go through unchanged rather than being treated as a
    special case somewhere upstream. }
  SetLength(Stored, 0);
  SetLength(Fresh, 1);
  Fresh[0] := Msg(mrUser, 'hello');
  Merged := MergeSessionContext(Stored, Fresh);
  AssertTrue(Length(Merged) = 1, 'an empty session contributes nothing');
  AssertEqStr(Merged[0].Content, 'hello', 'the new turn is the whole array');
end;

(* both sides of the merge keep their tests: the merge rule and the
   transcript log are separate contracts that happen to share a file *)

procedure TestLogRecordsEachTurnOnce;
var
  Meta: TSessionMeta;
  Msgs, Back: TMessageArray;
  Total: Integer;
begin
  Meta := Default(TSessionMeta);
  Meta.Id := 'logtest-once';
  CleanLog(Meta.Id);   { a stale record from a previous run is not this test }
  SetLength(Msgs, 2);
  Msgs[0] := LogMsg(mrUser, 'one');
  Msgs[1] := LogMsg(mrAssistant, 'reply one');
  LogSessionTurn(Meta, Msgs);
  AssertTrue(Meta.LoggedCount = 2, 'the count follows the live length');

  { Saving again with the SAME transcript must not duplicate it --
    every surface calls this on every save, including saves that added
    no messages. }
  LogSessionTurn(Meta, Msgs);
  Back := ReadSessionLog(Meta.Id, 0, 0, Total);
  AssertTrue(Total = 2, 'an unchanged transcript logs nothing twice');

  SetLength(Msgs, 4);
  Msgs[2] := LogMsg(mrUser, 'two');
  Msgs[3] := LogMsg(mrAssistant, 'reply two');
  LogSessionTurn(Meta, Msgs);
  Back := ReadSessionLog(Meta.Id, 0, 0, Total);
  AssertTrue(Total = 4, 'the next turn appends only what is new');
  AssertEqStr(Back[0].Content, 'one',       'oldest first');
  AssertEqStr(Back[3].Content, 'reply two', 'newest last');
  DeleteSession(Meta.Id);
end;

procedure TestCompactionDoesNotCostTheRecord;
var
  Meta: TSessionMeta;
  Live, Back: TMessageArray;
  Total, i: Integer;
begin
  Meta := Default(TSessionMeta);
  Meta.Id := 'logtest-compact';
  CleanLog(Meta.Id);   { a stale record from a previous run is not this test }
  SetLength(Live, 20);
  for i := 0 to 19 do
    if i mod 2 = 0 then Live[i] := LogMsg(mrUser, 'q' + IntToStr(i))
    else                Live[i] := LogMsg(mrAssistant, 'a' + IntToStr(i));
  LogSessionTurn(Meta, Live);

  { What the compaction hook does: flush the pre-drop history, then
    mark the count stale because the live array is about to shrink. }
  LogSessionTurn(Meta, Live);
  Meta.LogPending := True;

  { ...and the drop. The live transcript is now a summary plus the
    tail -- shorter, and renumbered. }
  SetLength(Live, 3);
  Live[0] := LogMsg(mrUser, 'SUMMARY of the earlier conversation');
  Live[1] := LogMsg(mrUser, 'q18');
  Live[2] := LogMsg(mrAssistant, 'a19');
  LogSessionTurn(Meta, Live);
  AssertTrue(Meta.LoggedCount = 3, 'the count re-anchors to the new live length');
  AssertTrue(not Meta.LogPending,  'and the flag clears');

  Back := ReadSessionLog(Meta.Id, 0, 0, Total);
  AssertTrue(Total = 20, 'the record still holds every pre-compaction turn');
  AssertEqStr(Back[0].Content, 'q0',
    'including the opening of the conversation the live file dropped');

  { The turn AFTER a compaction still appends, and appends only itself. }
  SetLength(Live, 5);
  Live[3] := LogMsg(mrUser, 'q20');
  Live[4] := LogMsg(mrAssistant, 'a21');
  LogSessionTurn(Meta, Live);
  Back := ReadSessionLog(Meta.Id, 0, 0, Total);
  AssertTrue(Total = 22, 'post-compaction turns append once');
  AssertEqStr(Back[21].Content, 'a21', 'and land at the end');
  DeleteSession(Meta.Id);
end;

procedure TestReplyAfterCompactionIsRecorded;
var
  Meta: TSessionMeta;
  Live, Back, Reply: TMessageArray;
  Total, i: Integer;
begin
  (* The sequence the gateway runs on a COMPACTING turn, in order:
     the flush hook fires mid-loop with the pre-drop history (reply not
     yet in existence), the loop drops the older half, and the persist
     at end of turn re-anchors -- then appends the reply separately.
     The one-step version swallowed the reply: the re-anchor treats
     everything alive as already-logged, which was true at flush time
     and false once the reply landed. Found live before fixing. *)
  Meta := Default(TSessionMeta);
  Meta.Id := 'logtest-reply';
  CleanLog(Meta.Id);
  SetLength(Live, 10);
  for i := 0 to 9 do
    if i mod 2 = 0 then Live[i] := LogMsg(mrUser, 'q' + IntToStr(i))
    else                Live[i] := LogMsg(mrAssistant, 'a' + IntToStr(i));

  { the flush, with the pre-drop history -- the reply does not exist }
  LogSessionTurn(Meta, Live);
  Meta.LogPending := True;

  { the drop, then the persist's first step: re-anchor on the rebuilt
    array, still without the reply }
  SetLength(Live, 2);
  Live[0] := LogMsg(mrUser, 'SUMMARY');
  Live[1] := LogMsg(mrUser, 'q8');
  LogSessionTurn(Meta, Live);

  { the persist's second step: the reply, appended on its own }
  SetLength(Reply, 1);
  Reply[0] := LogMsg(mrAssistant, 'THE-REPLY');
  if AppendSessionLog(Meta.Id, Reply) > 0 then
    Meta.LoggedCount := Meta.LoggedCount + 1;

  Back := ReadSessionLog(Meta.Id, 0, 0, Total);
  AssertTrue(Total = 11, 'pre-drop history plus the reply');
  AssertEqStr(Back[10].Content, 'THE-REPLY',
    'the compacting turn''s ANSWER is in the record');

  { and the next ordinary turn still diffs from the right place }
  SetLength(Live, 4);
  Live[2] := LogMsg(mrAssistant, 'THE-REPLY');
  Live[3] := LogMsg(mrUser, 'next question');
  { live is [SUMMARY, q8, THE-REPLY, next question]; LoggedCount = 3 }
  LogSessionTurn(Meta, Live);
  Back := ReadSessionLog(Meta.Id, 0, 0, Total);
  AssertTrue(Total = 12, 'the next turn appends once, not twice');
  AssertEqStr(Back[11].Content, 'next question', 'and lands at the end');
  CleanLog(Meta.Id);
end;

procedure TestLogWindows;
var
  Meta: TSessionMeta;
  Live, Back: TMessageArray;
  Total, i: Integer;
begin
  Meta := Default(TSessionMeta);
  Meta.Id := 'logtest-window';
  CleanLog(Meta.Id);   { a stale record from a previous run is not this test }
  SetLength(Live, 50);
  for i := 0 to 49 do Live[i] := LogMsg(mrUser, 'm' + IntToStr(i));
  LogSessionTurn(Meta, Live);

  Back := ReadSessionLog(Meta.Id, 10, 5, Total);
  AssertTrue(Total = 50, 'total is the whole log, not the window');
  AssertTrue(Length(Back) = 5, 'the window is the size asked for');
  AssertEqStr(Back[0].Content, 'm10', 'offset counts from the start');
  AssertEqStr(Back[4].Content, 'm14', 'and runs forward');

  { Clamped rather than erroring: a client paging backwards will walk
    off both ends eventually. }
  Back := ReadSessionLog(Meta.Id, 47, 20, Total);
  AssertTrue(Length(Back) = 3, 'a window past the end is clamped');
  Back := ReadSessionLog(Meta.Id, 999, 10, Total);
  AssertTrue(Length(Back) = 0, 'an offset past the end returns nothing');
  AssertTrue(Total = 50, 'and still reports the total');
  AssertTrue(SessionLogCount(Meta.Id) = 50, 'the count helper agrees');
  DeleteSession(Meta.Id);
end;

procedure TestExportsCarryTheRecord;
var
  S: TSession;
  Meta: TSessionMeta;
  Live: TMessageArray;
  i: Integer;
  Body, Err: string;
  Obj: TJsonObject;
  Arr: TJsonArray;
begin
  (* A compacted session's live file is a summary plus the tail; its
     record is the whole conversation. An export exists to answer "what
     happened", so it must be built from the record -- before this, every
     export path silently omitted the turns compaction removed. *)
  DeleteSession('logtest-export');
  S := TSession.Create('logtest-export');
  try
    SetLength(S.Messages, 2);
    S.Messages[0] := LogMsg(mrUser, 'SUMMARY of earlier work');
    S.Messages[1] := LogMsg(mrAssistant, 'the tail answer');
    S.Save;
  finally
    S.Free;
  end;
  { The record holds the FULL conversation the live file no longer does. }
  Meta := Default(TSessionMeta);
  Meta.Id := 'logtest-export';
  CleanLog(Meta.Id);
  SetLength(Live, 6);
  for i := 0 to 5 do
    if i mod 2 = 0 then Live[i] := LogMsg(mrUser, 'q' + IntToStr(i))
    else                Live[i] := LogMsg(mrAssistant, 'a' + IntToStr(i));
  LogSessionTurn(Meta, Live);

  AssertTrue(Length(SessionExportMessages('logtest-export')) = 6,
    'the export messages are the record, not the live pair');

  AssertTrue(ExportSessionJSON('logtest-export', Body, Err),
    'the JSON export succeeds: ' + Err);
  Obj := TJsonObject.Parse(Body);
  try
    Arr := Obj.ChildArray('messages');
    try
      AssertTrue((Arr <> nil) and (Arr.Count = 6),
        'the JSON export carries all six recorded messages');
    finally
      Arr.Free;
    end;
  finally
    Obj.Free;
  end;
  AssertTrue(Pos('q0', Body) > 0,
    'including the opening the live file dropped');

  { No record: the live file is the whole story and still serves. }
  CleanLog('logtest-export');
  AssertTrue(Length(SessionExportMessages('logtest-export')) = 2,
    'a session with no record exports its live messages');
  DeleteSession('logtest-export');
end;

procedure TestLogIsNotASession;
begin
  { SessionPath refuses it, so `pasclaw resume <id>.log` cannot open the
    record and write turns into it. }
  AssertTrue(IsSessionArchiveId('anything.log'), 'a .log id is not a session id');
  AssertEqStr(SessionPath('anything.log'), '', 'and has no session path');
  AssertTrue(SessionLogPath('anything.log') = '',
    'nor a log path of its own');
end;

begin
  TestMergePutsStoredFirst;
  TestMergeDropsStoredSystemTurns;
  TestMergeKeepsToolTurns;
  TestMergeOnAnEmptySession;
  TestLogRecordsEachTurnOnce;
  TestCompactionDoesNotCostTheRecord;
  TestReplyAfterCompactionIsRecorded;
  TestLogWindows;
  TestExportsCarryTheRecord;
  TestLogIsNotASession;
  TestExtractsFsWritePaths;
  TestExtractsFsEditPathsAndDedupes;
  TestCapturesShellAndError;
  TestExtractsApplyPatchAndHashlinePaths;
  TestFormatBlockSkipsEmpty;
  TestFormatBlockRendersFields;
  TestSaveLoadRoundTrip;
  TestEmptyWorkingStateNotEmitted;
  TestSortNewestFirst;
  WriteLn('working_state_tests: OK');
end.
