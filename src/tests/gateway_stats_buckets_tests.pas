program gateway_stats_buckets_tests;
(*
  Covers the per-endpoint stats buckets the gateway writes for
  stateless requests (/v1/chat, /v1/chat/completions, /v1/responses).

  We can't drive a real HTTP request from a unit test without
  standing up the Indy server, so the surface we pin is the
  on-disk shape:

    - Leading-underscore session ids ('_gateway_v1_chat' etc.)
      pass IsSafeSessionId.
    - The bucket session round-trips through Save / Load like any
      other session.
    - Repeated AccumulateTurnStats calls on the same bucket sum
      across calls (simulating two gateway requests hitting the
      same endpoint back-to-back), which is the key property the
      gateway helper relies on.
    - The Title we stamp on first create survives subsequent
      saves (operator-facing label in the web UI sidebar).

  The actual concurrency helper (TCriticalSection) and the http
  wiring belong to the gateway unit and are exercised in
  integration; this test pins the per-session contract.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Session.Store,
  PasClaw.Gateway.Server;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertEqInt(Got, Want: Int64; const Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')');
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertFalse(Cond: Boolean; const Msg: string);
begin
  if Cond then Fail_(Msg);
end;

procedure TestLeadingUnderscoreIdIsSafe;
{ The bucket ids start with '_' on purpose -- they sort to the
  top of the sidebar and visually distinguish from operator
  sessions. Pin that IsSafeSessionId tolerates the leading
  underscore; a future tightening of the validator would
  silently lose every gateway bucket. }
begin
  AssertTrue(IsSafeSessionId('_gateway_v1_chat'),
             '_gateway_v1_chat is a safe id');
  AssertTrue(IsSafeSessionId('_gateway_v1_chat_completions'),
             '_gateway_v1_chat_completions is a safe id');
  AssertTrue(IsSafeSessionId('_gateway_v1_responses'),
             '_gateway_v1_responses is a safe id');
end;

procedure TestBucketAccumulatesAcrossCalls;
{ Two gateway requests to the same endpoint should sum into the
  same on-disk bucket. We simulate by opening the bucket session
  twice (once per request), bumping counters each time, saving,
  and reading back the cumulative totals. If accumulation drops
  the prior turn on every save, the test fails. }
const
  Id = '_gateway_v1_chat_completions';
var
  S: TSession;
begin
  { Make sure we're starting clean. }
  if FileExists(SessionPath(Id)) then DeleteFile(SessionPath(Id));

  { First "request" -- bucket created on first save. }
  S := TSession.Create(Id);
  try
    S.Meta.Title    := '(gateway: /v1/chat/completions)';
    S.Meta.Provider := 'anthropic';
    S.Meta.Model    := 'claude-opus-4-8';
    AccumulateTurnStats(S.Meta, 100, 200, 0, 0, 1, 0);
    S.Save;
  finally
    S.Free;
  end;

  { Second "request" -- bucket re-opened, counters bumped, saved. }
  S := TSession.Create(Id);
  try
    AssertEqStr(S.Meta.Title, '(gateway: /v1/chat/completions)',
                'title survives the second open');
    AssertEqInt(S.Meta.Stats.InputTokens, 100,
                'first turn counters loaded back from disk');
    AccumulateTurnStats(S.Meta, 50, 75, 0, 0, 2, 0);
    S.Save;
  finally
    S.Free;
  end;

  { Final read: totals must be the SUM of the two requests, not
    the second alone. }
  S := TSession.Create(Id);
  try
    AssertEqInt(S.Meta.Stats.InputTokens,  150,
                'input tokens summed across both turns');
    AssertEqInt(S.Meta.Stats.OutputTokens, 275,
                'output tokens summed');
    AssertEqInt(S.Meta.Stats.Turns,        2,
                'turns count = number of accumulate calls');
    AssertEqInt(S.Meta.Stats.ToolCalls,    3,
                'tool calls summed');
  finally
    S.Free;
    DeleteFile(SessionPath(Id));
  end;
end;

procedure TestDistinctBucketsDontInterfere;
{ Different endpoints get different ids, must not collide.
  Bumping the chat-completions bucket leaves the responses
  bucket untouched. }
const
  IdA = '_gateway_v1_chat_completions';
  IdB = '_gateway_v1_responses';
var
  S: TSession;
begin
  if FileExists(SessionPath(IdA)) then DeleteFile(SessionPath(IdA));
  if FileExists(SessionPath(IdB)) then DeleteFile(SessionPath(IdB));

  S := TSession.Create(IdA);
  try
    AccumulateTurnStats(S.Meta, 999, 999, 0, 0, 5, 0);
    S.Save;
  finally
    S.Free;
  end;

  S := TSession.Create(IdB);
  try
    AssertEqInt(S.Meta.Stats.InputTokens, 0,
                'sibling bucket starts at zero');
    AssertEqInt(S.Meta.Stats.Turns,       0,
                'sibling bucket turns at zero');
  finally
    S.Free;
    DeleteFile(SessionPath(IdA));
    if FileExists(SessionPath(IdB)) then DeleteFile(SessionPath(IdB));
  end;
end;

procedure TestRawHelperAccumulatesPassthroughTraffic;
(* Codex P2 on PR #204. The /v1/responses HasFunctionTools branch
   (Codex CLI's dominant flow) doesn't run RunToolLoop -- it calls
   FProvider.Chat / ChatStream directly. The Loop-shape accumulator
   wouldn't fire on that path, so the responses bucket stayed at
   zero for client-tools traffic.

   Fix exposes AccumulateGatewayStatsRaw in the interface so the
   passthrough sites can hand it the provider's Usage + tool-call
   count without faking a TToolLoopResult. We pin here that the
   raw helper accumulates the same way the existing Loop-shape
   helper does -- two calls sum across, the bucket title sticks,
   the provider/model labels survive. *)
const
  Id = '_gateway_v1_responses';
var
  Cfg: TConfig;
  U: TUsageInfo;
  S: TSession;
begin
  if FileExists(SessionPath(Id)) then DeleteFile(SessionPath(Id));

  Cfg := TConfig.Create;
  try
    Cfg.StatsCollectionEnabled := True;
    SetLength(Cfg.Providers, 0);
    SetLength(Cfg.Fallbacks, 0);

    { First passthrough call: 500 in / 200 out, 3 tool calls
      the model emitted (client executes them, we don't). }
    U := Default(TUsageInfo);
    U.InputTokens  := 500;
    U.OutputTokens := 200;
    AccumulateGatewayStatsRaw(Cfg, Id, '(gateway: /v1/responses)',
                               'anthropic', 'claude-opus-4-8',
                               U, 3, 0);

    { Second passthrough call: another 700/300, 1 tool call. }
    U := Default(TUsageInfo);
    U.InputTokens  := 700;
    U.OutputTokens := 300;
    AccumulateGatewayStatsRaw(Cfg, Id, '(gateway: /v1/responses)',
                               'anthropic', 'claude-opus-4-8',
                               U, 1, 0);
  finally
    Cfg.Free;
  end;

  S := TSession.Create(Id);
  try
    AssertEqStr(S.Meta.Title, '(gateway: /v1/responses)',
                'title stamped on first save');
    AssertEqInt(S.Meta.Stats.InputTokens,  1200,
                'input tokens summed across two passthrough turns');
    AssertEqInt(S.Meta.Stats.OutputTokens, 500,
                'output tokens summed');
    AssertEqInt(S.Meta.Stats.Turns,        2,
                'turns count = number of passthrough calls');
    AssertEqInt(S.Meta.Stats.ToolCalls,    4,
                'tool calls summed across both turns');
  finally
    S.Free;
    DeleteFile(SessionPath(Id));
  end;
end;

procedure TestRawHelperRespectsStatsFlag;
{ Sanity: with stats collection off, the raw helper writes
  nothing (no bucket file appears). Pins the early-exit so the
  Codex review's fix doesn't accidentally always-on the
  accumulator. }
const
  Id = '_gateway_v1_responses';
var
  Cfg: TConfig;
  U: TUsageInfo;
begin
  if FileExists(SessionPath(Id)) then DeleteFile(SessionPath(Id));

  Cfg := TConfig.Create;
  try
    Cfg.StatsCollectionEnabled := False;
    U := Default(TUsageInfo);
    U.InputTokens  := 100;
    U.OutputTokens := 200;
    AccumulateGatewayStatsRaw(Cfg, Id, '(gateway: /v1/responses)',
                               'anthropic', 'claude-opus-4-8', U, 0, 0);
    AssertFalse(FileExists(SessionPath(Id)),
                'stats flag off -> no bucket file written');
  finally
    Cfg.Free;
    if FileExists(SessionPath(Id)) then DeleteFile(SessionPath(Id));
  end;
end;

procedure TestSessionFromUserField;
{ /v1/chat/completions derives a session from the OpenAI `user` field
  when no X-PasClaw-Session header is present (OpenClaw-compatible).
  Pin the contract: stable per value, distinct across values, hashed
  (raw user string never appears in the id), '' / blank -> stateless. }
var
  A, B: string;
  i: Integer;
begin
  AssertEqStr(SessionFromUserField(''), '', 'no user field -> stateless');
  AssertEqStr(SessionFromUserField('   '), '', 'blank user field -> stateless');

  A := SessionFromUserField('sweetconsole-tasker');
  B := SessionFromUserField('sweetconsole-tasker');
  AssertEqStr(A, B, 'same user value -> same session across calls');
  AssertTrue(A <> SessionFromUserField('sweetconsole-other'),
             'different user values -> different sessions');
  AssertEqStr(SessionFromUserField('  sweetconsole-tasker  '), A,
              'surrounding whitespace does not change the session');

  AssertEqStr(Copy(A, 1, 5), 'user-', 'derived id carries the user- prefix');
  AssertEqInt(Length(A), 5 + 16, 'user- prefix + 16 hex chars');
  for i := 6 to Length(A) do
    AssertTrue(CharInSet(A[i], ['0'..'9', 'a'..'f']),
               'hash part is lowercase hex');
  AssertTrue(Pos('sweetconsole', A) = 0,
             'raw user string never appears in the session id');
end;

begin
  TestLeadingUnderscoreIdIsSafe;
  TestBucketAccumulatesAcrossCalls;
  TestDistinctBucketsDontInterfere;
  TestRawHelperAccumulatesPassthroughTraffic;
  TestRawHelperRespectsStatsFlag;
  TestSessionFromUserField;
  WriteLn('gateway_stats_buckets_tests: OK');
end.
