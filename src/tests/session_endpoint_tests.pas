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
  PasClaw.Providers.Types,
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

function HomeLooksIsolated: Boolean;
var
  Home: string;
begin
  Home := GetEnvironmentVariable('PASCLAW_HOME');
  Result := (Home <> '') and (Pos('.pasclaw', LowerCase(Home)) = 0);
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
  WriteLn('session_endpoint_tests: OK');
end.
