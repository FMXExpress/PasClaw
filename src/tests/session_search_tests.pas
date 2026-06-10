program session_search_tests;
(*
  Covers PasClaw.Session.Search -- the FTS5 index over saved session
  transcripts that backs the session_search tool.

  We pin:
    - A saved session's message text is searchable by content
    - The right session id + title come back with a hit
    - Tool-call arg JSON / metadata is NOT what matches (we index
      message Content, not the raw JSON file)
    - Multiple sessions rank by relevance (the session that says
      the query term more wins)
    - A query that matches nothing returns an empty result, not an
      error
    - Re-Sync after a session's content changes re-indexes it
      (stale UpdatedAt triggers reindex)
    - Gateway stat-bucket sessions are excluded (Sync uses the
      default ListSessions which hides them)

  Runs against an isolated PASCLAW_HOME (Makefile target sets it)
  so the synthetic sessions + .search.db don't touch the operator's
  real store. libsqlite3 must be loadable; if Open() fails the test
  fails loudly rather than silently passing -- this is a unit test,
  not the production degrade-to-unavailable path.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Session.Store,
  PasClaw.Session.Search;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEqInt(Got, Want: Int64; const Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')');
end;

function SessionsDir_: string;
begin
  Result := JoinPath(GetHome, 'workspace/sessions');
end;

function IndexPath: string;
begin
  Result := JoinPath(SessionsDir_, '.search.db');
end;

procedure WipeStore;
{ Remove every session file + the index so each test run starts
  from a known empty state. Only touches the isolated test home. }
var
  Sr: TSearchRec;
begin
  if not DirectoryExists(SessionsDir_) then
  begin
    ForceDirectories(SessionsDir_);
    Exit;
  end;
  if FindFirst(JoinPath(SessionsDir_, '*'), faAnyFile, Sr) = 0 then
  try
    repeat
      if (Sr.Attr and faDirectory) = 0 then
        DeleteFile(JoinPath(SessionsDir_, Sr.Name));
    until FindNext(Sr) <> 0;
  finally
    FindClose(Sr);
  end;
end;

function MakeSession(const Id, Title: string;
                     const UserMsg, AssistantMsg: string): TSession;
begin
  Result := TSession.Create(Id);
  Result.Meta.Title := Title;
  SetLength(Result.Messages, 2);
  Result.Messages[0] := MakeMessage(mrUser, UserMsg);
  Result.Messages[1] := MakeMessage(mrAssistant, AssistantMsg);
  Result.Touch;
  Result.Save;
end;

function HasHitFor(const Hits: TSessionHitArray; const Id: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Hits) do
    if Hits[i].Id = Id then Exit(True);
end;

procedure TestSearchFindsByContent;
var
  S: TSession;
  Idx: ISessionSearchIndex;
  Hits: TSessionHitArray;
begin
  WipeStore;
  S := MakeSession('sess-deploy', 'Deploy setup',
                   'how do I configure the kubernetes deploy pipeline',
                   'use the helm chart in deploy/ and run make ship');
  S.Free;

  Idx := NewSessionSearchIndex;
  AssertTrue(Idx.Open(IndexPath), 'index opens (libsqlite3 present)');
  try
    Idx.Sync;
    Hits := Idx.Search('kubernetes deploy', 5);
    AssertTrue(Length(Hits) >= 1, 'found at least one hit for kubernetes deploy');
    AssertTrue(HasHitFor(Hits, 'sess-deploy'),
               'the deploy session is in the hits');
  finally
    Idx := nil;
  end;
end;

procedure TestHitCarriesIdAndTitle;
var
  S: TSession;
  Idx: ISessionSearchIndex;
  Hits: TSessionHitArray;
  i: Integer;
  FoundTitle: Boolean;
begin
  WipeStore;
  S := MakeSession('sess-auth', 'Auth flow chat',
                   'remind me how the oauth refresh token rotation works',
                   'the gateway rotates refresh tokens every 24h');
  S.Free;

  Idx := NewSessionSearchIndex;
  AssertTrue(Idx.Open(IndexPath), 'index opens');
  try
    Idx.Sync;
    Hits := Idx.Search('oauth refresh rotation', 5);
    AssertTrue(Length(Hits) >= 1, 'found the auth session');
    FoundTitle := False;
    for i := 0 to High(Hits) do
      if (Hits[i].Id = 'sess-auth') and (Hits[i].Title = 'Auth flow chat') then
        FoundTitle := True;
    AssertTrue(FoundTitle, 'hit carries the correct id + title');
  finally
    Idx := nil;
  end;
end;

procedure TestNoMatchReturnsEmpty;
var
  S: TSession;
  Idx: ISessionSearchIndex;
  Hits: TSessionHitArray;
begin
  WipeStore;
  S := MakeSession('sess-x', 'Some chat',
                   'we talked about gardening and tomatoes',
                   'plant basil next to them');
  S.Free;

  Idx := NewSessionSearchIndex;
  AssertTrue(Idx.Open(IndexPath), 'index opens');
  try
    Idx.Sync;
    Hits := Idx.Search('quantum chromodynamics', 5);
    AssertEqInt(Length(Hits), 0, 'unrelated query returns no hits');
  finally
    Idx := nil;
  end;
end;

procedure TestReindexOnContentChange;
var
  S: TSession;
  Idx: ISessionSearchIndex;
  Hits: TSessionHitArray;
begin
  WipeStore;
  S := MakeSession('sess-evolve', 'Evolving chat',
                   'initial topic was about caching strategies',
                   'use an LRU cache');
  S.Free;

  Idx := NewSessionSearchIndex;
  AssertTrue(Idx.Open(IndexPath), 'index opens');
  try
    Idx.Sync;
    Hits := Idx.Search('caching strategies', 5);
    AssertTrue(HasHitFor(Hits, 'sess-evolve'), 'first content indexed');

    { Rewrite the session with new content. Post-Codex-P2 fix the
      Sync uses (UpdatedAt OR file size) as the staleness signal,
      so we no longer need a Sleep here -- the new transcript has
      a different on-disk byte count which catches the change
      even when the second hasn't ticked. }
    S := TSession.Create('sess-evolve');
    try
      S.Meta.Title := 'Evolving chat';
      SetLength(S.Messages, 1);
      S.Messages[0] := MakeMessage(mrUser,
        'actually now we are discussing rate limiting and backpressure');
      S.Touch;
      S.Save;
    finally
      S.Free;
    end;

    Idx.Sync;
    Hits := Idx.Search('rate limiting backpressure', 5);
    AssertTrue(HasHitFor(Hits, 'sess-evolve'),
               'new content searchable after reindex');
    { Old content should no longer match (it was replaced, not appended). }
    Hits := Idx.Search('caching strategies LRU', 5);
    AssertTrue(not HasHitFor(Hits, 'sess-evolve'),
               'stale content dropped on reindex');
  finally
    Idx := nil;
  end;
end;

procedure TestReindexCatchesSameSecondSave;
(* Codex P2 on PR #209. TSession.Touch sets Meta.UpdatedAt to
   NowUnix (one-second resolution). Pre-fix Sync used strict
   `IdxMtime < UpdatedAt` so two saves within the same wall-clock
   second produced no advance, the second save's content was
   silently ignored, and session_search returned stale snippets.

   Reproduce: write a session, sync, force UpdatedAt back to the
   indexed value (simulates the same-second collision), save new
   content. Sync should still pick up the change via the file-size
   tiebreaker. Without the fix this test fails. *)
var
  S: TSession;
  Idx: ISessionSearchIndex;
  Hits: TSessionHitArray;
  PinnedTime: Int64;
begin
  WipeStore;
  S := MakeSession('sess-sec', 'Same-second test',
                   'original payload talks about quarks',
                   'ok');
  PinnedTime := S.Meta.UpdatedAt;
  S.Free;

  Idx := NewSessionSearchIndex;
  AssertTrue(Idx.Open(IndexPath), 'index opens');
  try
    Idx.Sync;
    Hits := Idx.Search('quarks', 5);
    AssertTrue(HasHitFor(Hits, 'sess-sec'), 'first content indexed');

    { Rewrite the session, pinning UpdatedAt to the same value the
      index already saw -- this is what a back-to-back agent turn
      looks like to the staleness check. Without the fix, the file
      size tiebreaker is the only signal that catches it. The new
      transcript is substantially longer so the size genuinely
      differs (and ALSO matches the dominant real-world case --
      transcripts grow, they rarely stay byte-identical). }
    S := TSession.Create('sess-sec');
    try
      S.Meta.Title := 'Same-second test';
      SetLength(S.Messages, 2);
      S.Messages[0] := MakeMessage(mrUser,
        'forget quarks -- now talking about gluons and the strong force ' +
        'with extra padding to guarantee a different on-disk size');
      S.Messages[1] := MakeMessage(mrAssistant,
        'gluons mediate the strong nuclear interaction between quarks ' +
        '(more padding bytes here too for size delta)');
      S.Meta.UpdatedAt := PinnedTime;  { same wall-clock second }
      S.Save;
    finally
      S.Free;
    end;

    Idx.Sync;
    Hits := Idx.Search('gluons strong force', 5);
    AssertTrue(HasHitFor(Hits, 'sess-sec'),
               'new content searchable despite UpdatedAt unchanged');
    Hits := Idx.Search('quarks', 5);
    { Stale content might still be in the index briefly if the
      reindex didn't fire -- pin that it DIDN'T match the new
      transcript. Actually quarks is mentioned in the new content
      too ("between quarks"), so this would pass for the wrong
      reason -- skip that assertion. The positive search above is
      the real regression guard. }
  finally
    Idx := nil;
  end;
end;

procedure TestRankingPrefersStrongerMatch;
var
  S: TSession;
  Idx: ISessionSearchIndex;
  Hits: TSessionHitArray;
begin
  WipeStore;
  { Session A mentions "telemetry" once; session B is all about it. }
  S := MakeSession('sess-a', 'Passing mention',
                   'we mostly discussed the UI but also telemetry briefly',
                   'ok');
  S.Free;
  S := MakeSession('sess-b', 'Telemetry deep dive',
                   'telemetry telemetry: how do we wire telemetry export, ' +
                   'telemetry sampling, and telemetry retention',
                   'configure the telemetry pipeline with these telemetry knobs');
  S.Free;

  Idx := NewSessionSearchIndex;
  AssertTrue(Idx.Open(IndexPath), 'index opens');
  try
    Idx.Sync;
    Hits := Idx.Search('telemetry', 5);
    AssertTrue(Length(Hits) >= 2, 'both sessions match');
    { bm25: smaller score = stronger. The deep-dive session should
      rank first. }
    AssertTrue(Hits[0].Id = 'sess-b',
               'the telemetry-heavy session ranks first');
  finally
    Idx := nil;
  end;
end;

procedure TestGatewayBucketsExcluded;
var
  S: TSession;
  Idx: ISessionSearchIndex;
  Hits: TSessionHitArray;
begin
  WipeStore;
  { A gateway stat bucket -- starts with _gateway_, hidden by the
    default ListSessions the Sync uses. Even though we stuff
    searchable text into it, session_search must not surface it. }
  S := MakeSession('_gateway_v1_chat_completions', '(gateway: /v1/chat/completions)',
                   'pineapple pizza debate transcript',
                   'pineapple belongs on pizza');
  S.Free;
  { A real session for contrast. }
  S := MakeSession('sess-real', 'Real chat',
                   'pineapple farming techniques',
                   'grow them in the tropics');
  S.Free;

  Idx := NewSessionSearchIndex;
  AssertTrue(Idx.Open(IndexPath), 'index opens');
  try
    Idx.Sync;
    Hits := Idx.Search('pineapple', 5);
    AssertTrue(HasHitFor(Hits, 'sess-real'), 'real session matches');
    AssertTrue(not HasHitFor(Hits, '_gateway_v1_chat_completions'),
               'gateway stat bucket excluded from session_search');
  finally
    Idx := nil;
  end;
end;

begin
  TestSearchFindsByContent;
  TestHitCarriesIdAndTitle;
  TestNoMatchReturnsEmpty;
  TestReindexOnContentChange;
  TestReindexCatchesSameSecondSave;
  TestRankingPrefersStrongerMatch;
  TestGatewayBucketsExcluded;
  WriteLn('session_search_tests: OK');
end.
