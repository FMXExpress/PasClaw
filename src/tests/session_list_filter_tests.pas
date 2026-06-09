program session_list_filter_tests;
(*
  Covers the bucket-session filtering contract on ListSessions.

  Pre-PR the gateway's per-endpoint stats buckets (ids starting
  with `_gateway_`) showed up in the TUI session pane and the
  `pasclaw session list` output, polluting the operator's view
  with stats-only pseudo-sessions they never created. ListSessions
  now skips them by default; the /v1/stats aggregator opts back
  in via IncludeBuckets=True.

  We pin:
    - IsGatewayBucketSessionId recognises the bucket-id naming
      rule and rejects regular session ids (operator-named or
      timestamp-prefixed)
    - Default ListSessions() hides bucket sessions
    - ListSessions(True) returns them
    - Real sessions (no bucket prefix) always come back either way
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
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

procedure AssertFalse(Cond: Boolean; const Msg: string);
begin
  if Cond then Fail_(Msg);
end;

procedure TestPredicate;
begin
  AssertTrue(IsGatewayBucketSessionId('_gateway_v1_chat'),
             '_gateway_v1_chat matches');
  AssertTrue(IsGatewayBucketSessionId('_gateway_v1_chat_completions'),
             '_gateway_v1_chat_completions matches');
  AssertTrue(IsGatewayBucketSessionId('_gateway_v1_responses'),
             '_gateway_v1_responses matches');
  AssertFalse(IsGatewayBucketSessionId('gateway_v1_chat'),
              'no leading underscore -> not a bucket');
  AssertFalse(IsGatewayBucketSessionId('_gateway'),
              'bare _gateway -> not a bucket (too short, no body)');
  AssertFalse(IsGatewayBucketSessionId(''),
              'empty -> not a bucket');
  AssertFalse(IsGatewayBucketSessionId('20260609T101010-abc'),
              'timestamp session id -> not a bucket');
  AssertFalse(IsGatewayBucketSessionId('my-conversation'),
              'operator-named session -> not a bucket');
end;

procedure TestListSessionsFiltersBuckets;
{ Create one regular session + one bucket session and verify the
  default ListSessions returns only the regular one, while
  ListSessions(True) returns both. The PASCLAW_HOME the Makefile
  exports for this target is isolated so the fixture doesn't
  collide with the operator's real session store. }
const
  RegularId = 'list-filter-test-regular';
  BucketId  = '_gateway_v1_chat_completions';
var
  S: TSession;
  ListedDefault, ListedIncluding: TSessionMetaArray;
  HasRegular, HasBucket: Boolean;
  i: Integer;
begin
  { Wipe whatever might be left over from a prior run. }
  if FileExists(SessionPath(RegularId)) then DeleteFile(SessionPath(RegularId));
  if FileExists(SessionPath(BucketId))  then DeleteFile(SessionPath(BucketId));

  S := TSession.Create(RegularId);
  try
    S.Meta.Title := 'a regular operator session';
    S.Save;
  finally
    S.Free;
  end;

  S := TSession.Create(BucketId);
  try
    S.Meta.Title := '(gateway: /v1/chat/completions)';
    { Stamp a counter so the bucket has data the aggregator would
      want to see. }
    AccumulateTurnStats(S.Meta, 100, 200, 0, 0, 3, 0);
    S.Save;
  finally
    S.Free;
  end;

  { Default call: bucket hidden, regular present. }
  ListedDefault := ListSessions;
  HasRegular := False; HasBucket := False;
  for i := 0 to High(ListedDefault) do
  begin
    if ListedDefault[i].Id = RegularId then HasRegular := True;
    if ListedDefault[i].Id = BucketId  then HasBucket  := True;
  end;
  AssertTrue (HasRegular, 'default ListSessions returns regular session');
  AssertFalse(HasBucket,  'default ListSessions hides the bucket session');

  { Opt-in call: both visible. }
  ListedIncluding := ListSessions(True);
  HasRegular := False; HasBucket := False;
  for i := 0 to High(ListedIncluding) do
  begin
    if ListedIncluding[i].Id = RegularId then HasRegular := True;
    if ListedIncluding[i].Id = BucketId  then HasBucket  := True;
  end;
  AssertTrue(HasRegular, 'opt-in ListSessions includes regular session');
  AssertTrue(HasBucket,  'opt-in ListSessions includes bucket session');

  { Cleanup. }
  DeleteFile(SessionPath(RegularId));
  DeleteFile(SessionPath(BucketId));
end;

begin
  TestPredicate;
  TestListSessionsFiltersBuckets;
  WriteLn('session_list_filter_tests: OK');
end.
