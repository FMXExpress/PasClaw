program session_endpoint_tests;
(*
  Covers the data-layer contract behind the gateway's durable
  /v1/sessions endpoints (PR: web UI Phase 2). The HTTP handlers
  themselves can't be exercised in CI without binding a listening
  socket, so the parse + persist logic they depend on is factored into
  PasClaw.Session.Store.ChatBodyToMessages and pinned here:

    - ChatBodyToMessages turns a chat-style request body
      ({"messages":[{role,content}], title?, model?}) into a
      TMessageArray + title/model overrides, mapping roles through
      MsgRoleFromString.
    - Absent/empty "messages" yields an empty array (not an error);
      invalid JSON raises EArgumentException (-> the handler's 400).
    - The full POST/PUT round-trip the handler performs: build messages
      from a body, persist via TSession.Save, reload by id, and get the
      same transcript back (roles + content), with MsgRoleToString
      round-tripping user/assistant.
    - ListSessions surfaces the saved session and DeleteSession removes
      it (the GET-list / DELETE handlers).

  PASCLAW_HOME must point at a scratch dir; the Makefile target does
  this so the fixtures never touch the operator's real session store.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.JSON,
  PasClaw.Providers.Types,
  PasClaw.Gateway.Server,   { TranscriptMessageJSON -- the reload contract }
  PasClaw.Session.Store;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEqI(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then Fail_(Msg + Format(' (got %d, want %d)', [Got, Want]));
end;

procedure AssertEqS(const Got, Want, Msg: string);
begin
  if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure TestParseBody;
var
  Msgs: TMessageArray;
  Title, Model: string;
begin
  Msgs := ChatBodyToMessages(
    '{"title":"my chat","model":"claude-x",' +
    '"messages":[{"role":"user","content":"hi"},' +
    '{"role":"assistant","content":"hello back"}]}', Title, Model);
  AssertEqI(Length(Msgs), 2, 'two messages parsed');
  AssertTrue(Msgs[0].Role = mrUser,      'first role is user');
  AssertTrue(Msgs[1].Role = mrAssistant, 'second role is assistant');
  AssertEqS(Msgs[0].Content, 'hi',         'first content');
  AssertEqS(Msgs[1].Content, 'hello back', 'second content');
  AssertEqS(Title, 'my chat',   'title override returned');
  AssertEqS(Model, 'claude-x',  'model override returned');
end;

procedure TestParseEdgeCases;
var
  Msgs: TMessageArray;
  Title, Model: string;
  Raised: Boolean;
begin
  { Absent messages -> empty array, no error (lets POST mint an empty
    session, and PUT clear one). }
  Msgs := ChatBodyToMessages('{"x":1}', Title, Model);
  AssertEqI(Length(Msgs), 0, 'no messages -> empty array');
  AssertEqS(Title, '', 'no title -> empty');

  { An empty body is coerced to an empty object and yields no messages. }
  Msgs := ChatBodyToMessages('', Title, Model);
  AssertEqI(Length(Msgs), 0, 'empty body -> empty array');

  { Invalid JSON raises EArgumentException (handler maps to 400). }
  Raised := False;
  try
    Msgs := ChatBodyToMessages('{not json', Title, Model);
  except
    on E: EArgumentException do Raised := True;
  end;
  AssertTrue(Raised, 'invalid JSON raises EArgumentException');
end;

procedure TestRoundTrip;
{ Mirror exactly what HandleSessionCreate/HandleSessionItem(PUT) do at
  the data layer, then what HandleSessionItem(GET) reads back. }
const
  Id = 'endpoint-test-roundtrip';
var
  S: TSession;
  Msgs: TMessageArray;
  Title, Model: string;
begin
  if FileExists(SessionPath(Id)) then DeleteFile(SessionPath(Id));

  { POST: parse body -> messages -> save. }
  Msgs := ChatBodyToMessages(
    '{"messages":[{"role":"user","content":"first turn"},' +
    '{"role":"assistant","content":"reply one"}]}', Title, Model);
  S := TSession.Create(Id);
  try
    S.Messages := Msgs;
    S.AutoTitle;              { title derives from first user turn }
    S.Touch;
    S.Save;
  finally
    S.Free;
  end;

  { GET: reload and verify the transcript came back intact. }
  S := TSession.Create(Id);
  try
    AssertTrue(S.MetaExists, 'saved session reloads');
    AssertEqI(Length(S.Messages), 2, 'round-trip message count');
    AssertEqS(MsgRoleToString(S.Messages[0].Role), 'user',      'role 0 round-trips');
    AssertEqS(MsgRoleToString(S.Messages[1].Role), 'assistant', 'role 1 round-trips');
    AssertEqS(S.Messages[0].Content, 'first turn', 'content 0 round-trips');
    AssertEqS(S.Messages[1].Content, 'reply one',  'content 1 round-trips');
    AssertEqS(S.Meta.Title, 'first turn', 'AutoTitle from first user turn');
  finally
    S.Free;
  end;

  { PUT: replace with a longer transcript. }
  Msgs := ChatBodyToMessages(
    '{"messages":[{"role":"user","content":"first turn"},' +
    '{"role":"assistant","content":"reply one"},' +
    '{"role":"user","content":"second turn"}]}', Title, Model);
  S := TSession.Create(Id);
  try
    S.Messages := Msgs;
    S.Touch;
    S.Save;
  finally
    S.Free;
  end;
  S := TSession.Create(Id);
  try
    AssertEqI(Length(S.Messages), 3, 'PUT replaced the transcript');
    AssertEqS(S.Messages[2].Content, 'second turn', 'appended turn persisted');
  finally
    S.Free;
  end;

  { DELETE removes it. }
  AssertTrue(DeleteSession(Id), 'DeleteSession returns true');
  S := TSession.Create(Id);
  try
    AssertTrue(not S.MetaExists, 'deleted session no longer loads');
  finally
    S.Free;
  end;
  AssertTrue(not DeleteSession(Id), 'second delete returns false (already gone)');
end;

procedure TestListSurfacesSession;
const
  Id = 'endpoint-test-listed';
var
  S: TSession;
  Listed: TSessionMetaArray;
  i: Integer;
  Found: Boolean;
begin
  if FileExists(SessionPath(Id)) then DeleteFile(SessionPath(Id));
  S := TSession.Create(Id);
  try
    S.Meta.Title := 'listed session';
    S.Save;
  finally
    S.Free;
  end;
  Listed := ListSessions;     { the GET /v1/sessions view (buckets excluded) }
  Found := False;
  for i := 0 to High(Listed) do
    if Listed[i].Id = Id then Found := True;
  AssertTrue(Found, 'ListSessions surfaces the saved session');
  DeleteFile(SessionPath(Id));
end;

procedure TestRichTurnDetection;
{ SessionHasRichTurns decides whether a /v1/sessions PUT overwrites or
  merges. A session carrying tool/system turns or assistant tool_calls is
  the agent's, not the web UI's: the PUT keeps the transcript on disk and
  takes only the tool-detail blob out of the body.

  It used to answer 409 instead, which prevented loss but forced the web UI
  to fork -- and once the gateway persists its own transcripts, a browser
  sharing that session would fork on every turn. The predicate is unchanged;
  what changed is the branch it selects. Pin it either way, because both
  behaviours key off exactly this. }
var
  Msgs: TMessageArray;
begin
  { Plain user/assistant -- web-ownable, NOT rich. }
  SetLength(Msgs, 2);
  Msgs[0] := MakeMessage(mrUser, 'hi');
  Msgs[1] := MakeMessage(mrAssistant, 'hello');
  AssertTrue(not SessionHasRichTurns(Msgs), 'plain user/assistant is not rich');

  { A tool turn makes it rich. }
  SetLength(Msgs, 3);
  Msgs[2] := MakeMessage(mrTool, 'ERROR: boom');
  AssertTrue(SessionHasRichTurns(Msgs), 'a tool turn marks the session rich');

  { A system turn makes it rich. }
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrSystem, 'you are an agent');
  AssertTrue(SessionHasRichTurns(Msgs), 'a system turn marks the session rich');

  { An assistant turn carrying tool_calls makes it rich. }
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrAssistant, '');
  SetLength(Msgs[0].ToolCalls, 1);
  Msgs[0].ToolCalls[0].Id := 'call_1';
  Msgs[0].ToolCalls[0].Func.Name := 'shell_exec';
  AssertTrue(SessionHasRichTurns(Msgs), 'assistant tool_calls mark the session rich');

  { Empty transcript is not rich. }
  SetLength(Msgs, 0);
  AssertTrue(not SessionHasRichTurns(Msgs), 'empty transcript is not rich');
end;

procedure TestToolDetailReplaceKeepsTranscript;
{ The merge branch rewrites ToolDetail and leaves Messages alone. That is
  only safe if the store treats the two independently, so pin it: a rich
  transcript survives a ToolDetail swap of the same length.

  Same-length deliberately -- Save drops a blob with MORE entries than the
  transcript (see TestToolDetailStalenessGuard), and the web UI's flattened
  view is never longer than the agent's, so the realistic merge is
  shorter-or-equal. }
var
  Id: string;
  S1, S2: TSession;
begin
  Id := 'merge-keeps-transcript-' + IntToStr(Random(MaxInt));
  S1 := TSession.Create(Id);
  try
    SetLength(S1.Messages, 3);
    S1.Messages[0] := MakeMessage(mrUser, 'build it');
    S1.Messages[1] := MakeMessage(mrAssistant, 'running a tool');
    S1.Messages[2] := MakeMessage(mrTool, 'exit=0');
    S1.ToolDetail := '[null,null,{"old":true}]';
    S1.Save;
  finally
    S1.Free;
  end;

  S2 := TSession.Create(Id);
  try
    AssertTrue(SessionHasRichTurns(S2.Messages),
               'the reloaded transcript is rich');
    { What the merge branch does: blob in, transcript untouched. }
    S2.ToolDetail := '[null,null,{"new":true}]';
    S2.Save;
  finally
    S2.Free;
  end;

  S2 := TSession.Create(Id);
  try
    AssertTrue(Length(S2.Messages) = 3, 'all three turns survived the merge');
    AssertTrue(S2.Messages[2].Role = mrTool, 'the tool turn is still a tool turn');
    AssertTrue(Pos('"new"', S2.ToolDetail) > 0, 'the new blob landed');
    AssertTrue(Pos('"old"', S2.ToolDetail) = 0, 'the old blob is gone');
  finally
    S2.Free;
  end;
  DeleteFile(SessionPath(Id));
end;

procedure TestFinalAnswerIsPersisted;
{ RunToolLoop returns FinalMessages as the history it FED the provider and
  exits as soon as a tool-less response arrives -- so the assistant turn
  carrying that response lives in Loop.Content, not the array. A gateway
  session that copies the array verbatim stops one turn short and loses the
  only thing the caller actually received.

  Pinned at the store level: an assistant turn appended after a tool turn
  round-trips, and the transcript still reads user / assistant / tool /
  assistant. }
var
  Id: string;
  S1, S2: TSession;
begin
  Id := 'final-answer-test-' + IntToStr(Random(MaxInt));
  S1 := TSession.Create(Id);
  try
    SetLength(S1.Messages, 4);
    S1.Messages[0] := MakeMessage(mrUser,      'do the thing');
    S1.Messages[1] := MakeMessage(mrAssistant, 'calling a tool');
    S1.Messages[2] := MakeMessage(mrTool,      'exit=0');
    S1.Messages[3] := MakeMessage(mrAssistant, 'done, here is the answer');
    S1.Save;
  finally
    S1.Free;
  end;
  S2 := TSession.Create(Id);
  try
    AssertTrue(Length(S2.Messages) = 4, 'all four turns persisted');
    AssertTrue(S2.Messages[3].Role = mrAssistant, 'the last turn is the answer');
    AssertTrue(Pos('here is the answer', S2.Messages[3].Content) > 0,
               'the answer text survived');
  finally
    S2.Free;
  end;
  DeleteFile(SessionPath(Id));
end;

procedure TestToolDetailIndicesFollowTheTranscript;
{ The web UI's tool_details array is indexed against what it DISPLAYS -- a
  flat list of user/assistant turns. The retained transcript interleaves
  tool turns, so entry N is the Nth displayed turn, not S.Messages[N].
  Storing it unchanged passes the count guard and still puts every card on
  the wrong message.

  This pins the mapping rule the merge implements: the flattened view is
  the subsequence of user/assistant turns, so the Nth blob entry belongs to
  the Nth such turn and every other slot is null. }
var
  Msgs: TMessageArray;
  i, Flat: Integer;
  Slot: array of Integer;
begin
  SetLength(Msgs, 5);
  Msgs[0] := MakeMessage(mrUser,      'ask');
  Msgs[1] := MakeMessage(mrAssistant, 'tool time');
  Msgs[2] := MakeMessage(mrTool,      'exit=0');
  Msgs[3] := MakeMessage(mrSystem,    'note');
  Msgs[4] := MakeMessage(mrAssistant, 'answer');

  { Slot[i] = which flattened index message i draws its cards from, or -1. }
  SetLength(Slot, Length(Msgs));
  Flat := 0;
  for i := 0 to High(Msgs) do
    if Msgs[i].Role in [mrUser, mrAssistant] then
    begin
      Slot[i] := Flat;
      Inc(Flat);
    end
    else
      Slot[i] := -1;

  AssertTrue(Slot[0] = 0, 'user turn takes flattened entry 0');
  AssertTrue(Slot[1] = 1, 'first assistant takes entry 1');
  AssertTrue(Slot[2] = -1, 'a tool turn takes no card');
  AssertTrue(Slot[3] = -1, 'a system turn takes no card');
  AssertTrue(Slot[4] = 2, 'the second assistant takes entry 2, not entry 4');
  AssertTrue(Flat = 3, 'three displayed turns out of five stored');
end;

procedure TestToolDetailStalenessGuard;
{ ToolDetail (the web UI's tool-card blob) is index-aligned to Messages.
  Paths outside the web UI's own PUT mutate Messages directly (TUI /clear,
  resume persisting a compacted history), so the store must not persist a
  blob that can no longer align: ClearMessages drops it, and Save drops a
  blob with MORE entries than the transcript. The append-only case (blob
  shorter/equal) survives -- earlier indexes still point at the same turns. }
const
  Id = 'endpoint-test-tooldetail';
var
  S: TSession;
begin
  if FileExists(SessionPath(Id)) then DeleteFile(SessionPath(Id));

  { Aligned blob (2 entries, 2 messages) round-trips. }
  S := TSession.Create(Id);
  try
    SetLength(S.Messages, 2);
    S.Messages[0] := MakeMessage(mrUser, 'build it');
    S.Messages[1] := MakeMessage(mrAssistant, 'built.');
    S.ToolDetail := '[null,[{"name":"write_file","args":"{}","result":"ok"}]]';
    S.Save;
  finally
    S.Free;
  end;
  S := TSession.Create(Id);
  try
    AssertTrue(Pos('write_file', S.ToolDetail) > 0, 'aligned tool detail round-trips');

    { ClearMessages invalidates the blob (TUI /clear shape). }
    S.ClearMessages;
    AssertTrue(S.ToolDetail = '', 'ClearMessages drops the tool detail');
    S.Save;
  finally
    S.Free;
  end;
  S := TSession.Create(Id);
  try
    AssertTrue(S.ToolDetail = '', 'cleared session persists without tool detail');

    { Transcript rebuilt SHORTER than the blob (compaction / replace shape):
      Save must drop the stale blob rather than persist a misaligned one. }
    SetLength(S.Messages, 1);
    S.Messages[0] := MakeMessage(mrUser, 'fresh start');
    S.ToolDetail := '[null,null,[{"name":"shell_exec","args":"{}","result":"stale"}]]';
    S.Save;
  finally
    S.Free;
  end;
  S := TSession.Create(Id);
  try
    AssertTrue(S.ToolDetail = '', 'over-long (stale) tool detail is dropped on save');
  finally
    S.Free;
    if FileExists(SessionPath(Id)) then DeleteFile(SessionPath(Id));
  end;
end;

function HomeLooksIsolated: Boolean;
var
  Home: string;
begin
  Home := GetEnvironmentVariable('PASCLAW_HOME');
  Result := (Home <> '') and (Pos('.pasclaw', LowerCase(Home)) = 0);
end;

(* The reload contract behind the desktop's tool cards.

   Both session readers used to serialise role + content and nothing
   else, so a reopened chat had no way to rebuild what a turn DID: the
   calls (name + args) live on the assistant turn and the results on
   tool turns joined by tool_call_id, all on disk and all dropped at
   the route. TranscriptMessageJSON is that route's per-message shape;
   this pins the fields the desktop pairs cards from -- and that the
   Gemini plumbing field stays private. *)
procedure TestTranscriptMessageCarriesToolWork;
var
  M: TMessage;
  Obj, C: TJsonObject;
  Calls: TJsonArray;
begin
  { An assistant turn that called one tool. }
  M := Default(TMessage);
  M.Role := mrAssistant;
  M.Content := 'checking';
  SetLength(M.ToolCalls, 1);
  M.ToolCalls[0].Id := 'c1';
  M.ToolCalls[0].Kind := 'function';
  M.ToolCalls[0].Func.Name := 'list_dir';
  M.ToolCalls[0].Func.Arguments := '{"path":"."}';
  M.ToolCalls[0].ProviderSignature := 'SECRET-SIG';
  Obj := TranscriptMessageJSON(M);
  try
    AssertEqS(Obj.GetStr('role', ''), 'assistant', 'role survives');
    AssertEqS(Obj.GetStr('content', ''), 'checking', 'content survives');
    Calls := Obj.ChildArray('tool_calls');
    AssertTrue(Calls <> nil, 'the calls are THERE -- this is the point');
    AssertEqI(Calls.Count, 1, 'one call');
    C := Calls.ItemObject(0);
    try
      AssertEqS(C.GetStr('id', ''),   'c1',           'paired by id');
      AssertEqS(C.GetStr('name', ''), 'list_dir',     'named');
      AssertEqS(C.GetStr('args', ''), '{"path":"."}', 'with its arguments');
      AssertTrue(Pos('SECRET-SIG', Obj.ToJSON) = 0,
        'provider_signature stays private -- it is plumbing between us ' +
        'and Gemini, not part of the conversation');
    finally
      C.Free;   { non-owning wrapper }
    end;
  finally
    Obj.Free;
  end;

  { The tool result turn that answers it. }
  M := Default(TMessage);
  M.Role := mrTool;
  M.Content := 'd desktop';
  M.Name := 'list_dir';
  M.ToolCallId := 'c1';
  Obj := TranscriptMessageJSON(M);
  try
    AssertEqS(Obj.GetStr('role', ''),         'tool',      'a tool turn');
    AssertEqS(Obj.GetStr('tool_call_id', ''), 'c1',        'joined to its call');
    AssertEqS(Obj.GetStr('name', ''),         'list_dir',  'and named');
    AssertEqS(Obj.GetStr('content', ''),      'd desktop', 'carrying the result');
  finally
    Obj.Free;
  end;

  { A plain turn stays plain -- no empty tool_calls array bloating
    every message of every session ever listed. }
  M := Default(TMessage);
  M.Role := mrUser;
  M.Content := 'hi';
  Obj := TranscriptMessageJSON(M);
  try
    AssertTrue(Pos('tool_calls', Obj.ToJSON) = 0, 'no tool work, no field');
    AssertTrue(Pos('tool_call_id', Obj.ToJSON) = 0, 'and no dangling ids');
  finally
    Obj.Free;
  end;
end;

begin
  if not HomeLooksIsolated then
  begin
    WriteLn('session_endpoint_tests: SKIP -- set PASCLAW_HOME to an');
    WriteLn('  isolated scratch directory before running this binary directly');
    WriteLn('  (the Makefile target ''make test-session-endpoints'' does this).');
    Halt(0);
  end;
  TestParseBody;
  TestParseEdgeCases;
  TestRoundTrip;
  TestListSurfacesSession;
  TestRichTurnDetection;
  TestToolDetailReplaceKeepsTranscript;
  TestFinalAnswerIsPersisted;
  TestToolDetailIndicesFollowTheTranscript;
  TestToolDetailStalenessGuard;
  TestTranscriptMessageCarriesToolWork;
  WriteLn('session_endpoint_tests: OK');
end.
