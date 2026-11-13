program session_stats_tests;
(*
  Covers the per-session stats fields added in this PR:

    - TSessionMeta.Stats round-trips through TSession.Save / Load
      (every counter persisted; no silent field drops on serialise)
    - A flag-off session (every stats field at zero) serialises
      WITHOUT a "stats" block, so on-disk diff vs. the pre-feature
      schema is byte-clean and old sessions stay readable
    - AccumulateTurnStats sums correctly across multiple calls
    - TConfig.StatsCollectionEnabled round-trips through the
      config JSON (default off; "stats_collection_enabled": true
      survives a Save / Load cycle)
    - ResetSessionStats (the Stats tab's Reset button) empties the
      counters and nothing else: the transcript with its tool calls,
      the tool-detail blob, the title, updated_at and the transcript
      log stay; a session that never recorded where it works is not
      stamped with the caller's workspace; nothing is written when
      there is nothing to clear, for a missing session or for a file
      that does not parse
    - ...and a save that lands while the reset is under way is not
      overwritten: the reset starts over from the new contents, and
      gives up, leaving the file alone, when it keeps changing

  Doesn't touch /v1/stats -- that's a thin aggregator over the
  data exercised here, and the per-session round-trip is the
  contract worth pinning. The aggregator can be smoke-tested by
  running the gateway against a synthetic session set.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Providers.Types,
  PasClaw.Tools.Sandbox,
  PasClaw.Session.Store;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
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

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing)');
end;

procedure AssertNotContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then
    Fail_(Msg + ' (needle "' + Needle + '" should not appear)');
end;

procedure TestStatsRoundTrip;
{ Save a session with every Stats field populated, load it back,
  verify the counters survive. This is the smoke test for the
  serialise / deserialise contract -- if either side drops a
  field, the rollup totals at /v1/stats drift silently. }
var
  Id: string;
  S1, S2: TSession;
begin
  Id := 'stats-roundtrip-test-' + IntToStr(Random(MaxInt));
  S1 := TSession.Create(Id);
  try
    S1.Meta.Provider := 'anthropic-test';
    S1.Meta.Model    := 'claude-opus-4-8-test';
    S1.Meta.Stats.InputTokens          := 1000;
    S1.Meta.Stats.OutputTokens         := 2000;
    S1.Meta.Stats.CacheReadTokens      := 500;
    S1.Meta.Stats.CacheCreatedTokens   := 100;
    S1.Meta.Stats.Turns                := 7;
    S1.Meta.Stats.ToolCalls            := 42;
    S1.Meta.Stats.TruncationBytesSaved := 65536;
    S1.Save;
  finally
    S1.Free;
  end;

  S2 := TSession.Create(Id);
  try
    AssertTrue(S2.MetaExists, 'session reloaded');
    AssertEqInt(S2.Meta.Stats.InputTokens,          1000,  'input_tokens');
    AssertEqInt(S2.Meta.Stats.OutputTokens,         2000,  'output_tokens');
    AssertEqInt(S2.Meta.Stats.CacheReadTokens,      500,   'cache_read_tokens');
    AssertEqInt(S2.Meta.Stats.CacheCreatedTokens,   100,   'cache_created_tokens');
    AssertEqInt(S2.Meta.Stats.Turns,                7,     'turns');
    AssertEqInt(S2.Meta.Stats.ToolCalls,            42,    'tool_calls');
    AssertEqInt(S2.Meta.Stats.TruncationBytesSaved, 65536, 'truncation_bytes_saved');
    { Provider + Model survive too -- /v1/stats rolls up by these. }
    AssertTrue(S2.Meta.Provider = 'anthropic-test', 'Provider survives');
    AssertTrue(S2.Meta.Model    = 'claude-opus-4-8-test', 'Model survives');
  finally
    S2.Free;
    DeleteFile(SessionPath(Id));
  end;
end;

procedure TestEmptyStatsOmitted;
{ When every Stats counter is zero (flag-off path), the session
  JSON must NOT include a "stats" object. Two reasons:
    1) Old sessions stay byte-identical to their pre-feature
       serialisation.
    2) Flag-off operators don't carry an empty-stats block in
       every session file forever. }
var
  Id, RawJson: string;
  S: TSession;
  F: TextFile;
  Line: string;
begin
  Id := 'stats-empty-test-' + IntToStr(Random(MaxInt));
  S := TSession.Create(Id);
  try
    S.Meta.Provider := 'p';
    S.Meta.Model    := 'm';
    { Stats stays at zero. }
    S.Save;
  finally
    S.Free;
  end;

  RawJson := '';
  AssignFile(F, SessionPath(Id));
  try
    Reset(F);
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      RawJson := RawJson + Line + #10;
    end;
  finally
    CloseFile(F);
  end;

  AssertNotContains(RawJson, '"stats"',
                    'empty stats produces no on-disk block');
  DeleteFile(SessionPath(Id));
end;

procedure TestAccumulateTurnStatsAddsCorrectly;
{ The accumulator runs once per turn. Two calls with the same
  deltas should produce double counters; Turns increments by
  exactly 1 per call (not by InputTokens or anything else --
  this was easy to get wrong in earlier drafts). }
var
  M: TSessionMeta;
begin
  M := Default(TSessionMeta);
  AccumulateTurnStats(M, 100, 200, 50, 25, 3, 4096);
  AssertEqInt(M.Stats.InputTokens,          100,  'after one call: input');
  AssertEqInt(M.Stats.OutputTokens,         200,  'after one call: output');
  AssertEqInt(M.Stats.CacheReadTokens,      50,   'after one call: cache_r');
  AssertEqInt(M.Stats.CacheCreatedTokens,   25,   'after one call: cache_w');
  AssertEqInt(M.Stats.Turns,                1,    'after one call: turns is 1');
  AssertEqInt(M.Stats.ToolCalls,            3,    'after one call: tool_calls');
  AssertEqInt(M.Stats.TruncationBytesSaved, 4096, 'after one call: bytes');

  AccumulateTurnStats(M, 100, 200, 50, 25, 3, 4096);
  AssertEqInt(M.Stats.InputTokens,          200,   'after two calls: input doubled');
  AssertEqInt(M.Stats.OutputTokens,         400,   'after two calls: output doubled');
  AssertEqInt(M.Stats.Turns,                2,     'after two calls: turns is 2 (not 200)');
  AssertEqInt(M.Stats.ToolCalls,            6,     'after two calls: tool_calls doubled');
  AssertEqInt(M.Stats.TruncationBytesSaved, 8192,  'after two calls: bytes doubled');
end;

procedure TestAccumulateThenSavePersistsCounters;
(* Codex P2 on PR #202. The original wiring incremented Meta.Stats
   AFTER ApplyLoopResultTo had already saved the session, so the
   counters were never written to disk -- /v1/stats stayed at zero
   for TUI sessions even with the flag on. This pins the corrected
   ordering: bump first, save second, reload, read the counters
   back. If a future refactor reverses the order this test fails
   instead of silently losing data. *)
var
  Id: string;
  S1, S2: TSession;
begin
  Id := 'stats-order-test-' + IntToStr(Random(MaxInt));
  S1 := TSession.Create(Id);
  try
    AccumulateTurnStats(S1.Meta, 100, 200, 50, 25, 3, 4096);
    S1.Save;  { the order under test: accumulate THEN save }
  finally
    S1.Free;
  end;

  S2 := TSession.Create(Id);
  try
    AssertTrue(S2.MetaExists, 'session present after accumulate-then-save');
    AssertEqInt(S2.Meta.Stats.InputTokens,          100,  'on-disk input survives');
    AssertEqInt(S2.Meta.Stats.OutputTokens,         200,  'on-disk output survives');
    AssertEqInt(S2.Meta.Stats.Turns,                1,    'on-disk turns survives');
    AssertEqInt(S2.Meta.Stats.ToolCalls,            3,    'on-disk tool_calls survives');
    AssertEqInt(S2.Meta.Stats.TruncationBytesSaved, 4096, 'on-disk bytes survives');
  finally
    S2.Free;
    DeleteFile(SessionPath(Id));
  end;
end;

procedure TestAccumulateRoutesToOriginatingSession;
(* Codex P2 on PR #202: in the TUI, the worker thread can complete
   while the operator has already switched to a different session.
   AccumulateTurnStats must apply to the ORIGINATING session
   (looked up by id), not whatever's currently selected. We
   simulate the race by creating two sessions, accumulating into
   the FIRST one's Meta, switching the "current" reference to the
   second one, saving the first, and asserting the second is
   untouched. *)
var
  IdA, IdB: string;
  SA, SB, Reload: TSession;
begin
  IdA := 'stats-orig-A-' + IntToStr(Random(MaxInt));
  IdB := 'stats-orig-B-' + IntToStr(Random(MaxInt));
  SA := TSession.Create(IdA);
  SB := TSession.Create(IdB);
  try
    { Both sessions exist; both start with zero stats. }
    SA.Save;
    SB.Save;
    { Simulate "loop originated on SA". }
    AccumulateTurnStats(SA.Meta, 500, 1000, 0, 0, 7, 0);
    SA.Save;
    { SB is the "currently selected" session per the race scenario.
      It must NOT pick up SA's counters. }
  finally
    SA.Free;
    SB.Free;
  end;

  Reload := TSession.Create(IdA);
  try
    AssertEqInt(Reload.Meta.Stats.InputTokens, 500,
                'originating session got the counters');
  finally
    Reload.Free;
    DeleteFile(SessionPath(IdA));
  end;

  Reload := TSession.Create(IdB);
  try
    AssertEqInt(Reload.Meta.Stats.InputTokens, 0,
                'sibling session stayed clean (no cross-session leak)');
    AssertEqInt(Reload.Meta.Stats.Turns, 0,
                'sibling session turns stayed zero');
  finally
    Reload.Free;
    DeleteFile(SessionPath(IdB));
  end;
end;

procedure TestStatsCollectionEnabledRoundTrip;
{ Default TRUE since the six-free-toggles PR (#314); an explicit
  False (opt-out) survives a JSON Save / Load. We pin both halves
  because the persistence helper emits ONLY the non-default value --
  the default-on case round-trips via "field missing, fall back to
  the default", the opt-out via an explicit "false". }
var
  Cfg1, Cfg2, Cfg3: TConfig;
  Body: string;
begin
  Cfg1 := TConfig.Create;
  try
    AssertTrue(Cfg1.StatsCollectionEnabled,
               'default is True');
    Body := Cfg1.ToJSON;
  finally
    Cfg1.Free;
  end;
  AssertNotContains(Body, '"stats_collection_enabled"',
                    'default-on case writes no flag (fresh config stays clean)');

  Cfg2 := TConfig.Create;
  try
    Cfg2.StatsCollectionEnabled := False;
    Body := Cfg2.ToJSON;
  finally
    Cfg2.Free;
  end;
  AssertContains(Body, '"stats_collection_enabled"',
                 'explicit-off case writes the flag');

  Cfg3 := TConfig.Create;
  try
    Cfg3.FromJSON(Body);
    AssertTrue(not Cfg3.StatsCollectionEnabled,
               'opt-out survives round trip');
  finally
    Cfg3.Free;
  end;
end;

procedure TestProfileRoundTrip;
{ TSessionMeta.Profile persists and PeekSessionProfile reads it back
  WITHOUT loading the transcript -- the resume path calls Peek before
  LoadConfig, so a regression here silently drops a session back to the
  ambient profile instead of the one it was created under. }
var
  Id: string;
  S1, S2: TSession;
  M: TMessage;
begin
  Id := 'profile-roundtrip-test-' + IntToStr(Random(MaxInt));
  S1 := TSession.Create(Id);
  try
    S1.Meta.Profile := 'security';
    { A message body proves Peek is not just reading a one-line file. }
    FillChar(M, SizeOf(M), 0);
    M.Role    := mrUser;
    M.Content := 'hello';
    SetLength(S1.Messages, 1);
    S1.Messages[0] := M;
    S1.Save;
  finally
    S1.Free;
  end;

  S2 := TSession.Create(Id);
  try
    AssertTrue(S2.MetaExists, 'session reloaded');
    AssertTrue(S2.Meta.Profile = 'security', 'profile survives round trip');
  finally
    S2.Free;
  end;

  AssertTrue(PeekSessionProfile(Id) = 'security',
             'PeekSessionProfile reads the stored profile');
  AssertTrue(PeekSessionProfile('no-such-session-id-here') = '',
             'PeekSessionProfile is empty for a missing session');
  AssertTrue(PeekSessionProfile('../escape') = '',
             'PeekSessionProfile refuses an unsafe id');

  try DeleteFile(SessionPath(Id)); except end;
end;

procedure TestProfileAbsentByDefault;
{ A session created without a profile reports '' rather than inventing
  one -- that empty string is what makes LoadConfig fall through to its
  own precedence chain. }
var
  Id: string;
  S: TSession;
begin
  Id := 'profile-absent-test-' + IntToStr(Random(MaxInt));
  S := TSession.Create(Id);
  try
    S.Save;
  finally
    S.Free;
  end;
  AssertTrue(PeekSessionProfile(Id) = '', 'no profile stamped => empty');
  try DeleteFile(SessionPath(Id)); except end;
end;

{ ------------------------------------------------- ResetSessionStats -- }

const
  { Non-ASCII as UTF-8 bytes, the way the store holds text: a literal
    would be compared through whatever code page the test runs in. }
  SEED_TITLE = 'B' + #$C3#$BC + 'cher';                               { U+00FC }
  SEED_ASK   = 'h' + #$C3#$A9 + 'llo, read notes.txt ' + #$E6#$97#$A5; { U+00E9, U+65E5 }

function SeedSession(const Id: string): string;
{ A conversation with everything a reset must leave alone, and counters.
  Returns the file's text. }
var
  S: TSession;
  TC: TToolCall;
begin
  S := TSession.Create(Id);
  try
    S.Meta.Title     := SEED_TITLE;
    S.Meta.Provider  := 'anthropic-test';
    S.Meta.Model     := 'model-test';
    S.Meta.UpdatedAt := 1700000000;
    S.Meta.WorkingState.LastShell := 'make test';
    SetLength(S.Messages, 3);
    S.Messages[0] := MakeMessage(mrUser, SEED_ASK);
    S.Messages[1] := MakeMessage(mrAssistant, 'reading');
    TC := Default(TToolCall);
    TC.Id := 'call_1'; TC.Kind := 'function';
    TC.Func.Name := 'read_file'; TC.Func.Arguments := '{"path":"notes.txt"}';
    SetLength(S.Messages[1].ToolCalls, 1);
    S.Messages[1].ToolCalls[0] := TC;
    S.Messages[2] := MakeMessage(mrTool, 'the number is 4127');
    S.Messages[2].ToolCallId := 'call_1';
    S.ToolDetail := '[{"i":1,"args":"{}"},{"i":2,"result":"4127"}]';
    S.Meta.Stats.InputTokens          := -3690150476;   { the kind of total a reset is for }
    S.Meta.Stats.OutputTokens         := 163871;
    S.Meta.Stats.CacheReadTokens      := -1373772880;
    S.Meta.Stats.CacheCreatedTokens   := 163790;
    S.Meta.Stats.Turns                := 4;
    S.Meta.Stats.ToolCalls            := 1;
    S.Meta.Stats.TruncationBytesSaved := 2048;
    S.Save;
  finally
    S.Free;
  end;
  Result := ReadFileText(SessionPath(Id));
end;

procedure AssertConversationKept(const Id, Where: string);
var
  S: TSession;
begin
  S := TSession.Create(Id);
  try
    AssertTrue(S.MetaExists, Where + ': the session still loads');
    AssertTrue(S.Meta.Title = SEED_TITLE, Where + ': title');
    AssertTrue(S.Meta.Provider = 'anthropic-test', Where + ': provider');
    AssertTrue(S.Meta.Model = 'model-test', Where + ': model');
    AssertEqInt(S.Meta.UpdatedAt, 1700000000, Where + ': updated_at');
    AssertTrue(S.Meta.WorkingState.LastShell = 'make test', Where + ': working state');
    AssertTrue(Length(S.Messages) >= 3, Where + ': the first three messages are there');
    AssertTrue(S.Messages[0].Content = SEED_ASK, Where + ': user message');
    AssertEqInt(Length(S.Messages[1].ToolCalls), 1, Where + ': the tool call');
    AssertTrue(S.Messages[1].ToolCalls[0].Func.Arguments = '{"path":"notes.txt"}',
               Where + ': the tool call arguments');
    AssertTrue(S.Messages[2].ToolCallId = 'call_1', Where + ': the tool result pairing');
    AssertContains(S.ToolDetail, '"result"', Where + ': the tool-detail blob');
  finally
    S.Free;
  end;
end;

procedure RemoveSession(const Id: string);
begin
  try DeleteSession(Id); except end;
  try DeleteFile(SessionPath(Id) + '.tmp'); except end;
  try DeleteFile(SessionPath(Id) + '.reset.tmp'); except end;
end;

procedure TestResetClearsCountersOnly;
var
  Id, Before, After, LogBefore, Again: string;
  S: TSession;
  Msgs: TMessageArray;
  Policy: TSandboxPolicy;
begin
  Id := 'stats-reset-test-' + IntToStr(Random(MaxInt));
  { Saved before any workspace is set, so it has no location -- as a
    session from before locations were recorded has none. }
  Before := SeedSession(Id);
  AssertNotContains(Before, '"location"', 'premise: the seeded session has no location');
  AssertContains(Before, '"stats"', 'premise: the seeded session has counters');
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, SEED_ASK);
  AssertTrue(AppendSessionLog(Id, Msgs) > 0, 'premise: a transcript log was written');
  LogBefore := ReadFileText(SessionLogPath(Id));

  { From here the process works somewhere: a Save would now stamp it. }
  Policy := Default(TSandboxPolicy);
  ConfigureSandbox(Policy, GetCurrentDir);
  AssertTrue(CurrentWorkspace <> '', 'premise: a workspace is set');

  AssertTrue(ResetSessionStats(Id), 'reset reports the counters cleared');
  After := ReadFileText(SessionPath(Id));
  S := TSession.Create(Id);
  try
    AssertTrue(SessionStatsEmpty(S.Meta.Stats), 'every counter is zero after a reset');
    AssertTrue(S.Meta.Location = '', 'reset did not stamp a location: "' + S.Meta.Location + '"');
    AssertEqInt(Length(S.Messages), 3, 'reset kept exactly the messages');
  finally
    S.Free;
  end;
  AssertNotContains(After, '"stats"', 'no stats block is left');
  AssertNotContains(After, '"location"', 'no location was written');
  AssertConversationKept(Id, 'after reset');
  AssertTrue(ReadFileText(SessionLogPath(Id)) = LogBefore, 'the transcript log is untouched');
  AssertTrue(not FileExists(SessionPath(Id) + '.reset.tmp'), 'no temporary file is left');

  { Nothing to clear: not rewritten. }
  AssertTrue(not ResetSessionStats(Id), 'a second reset has nothing to clear');
  Again := ReadFileText(SessionPath(Id));
  AssertTrue(Again = After, 'a reset with nothing to clear leaves the file as it was');

  { What Save does in the same place, so the check above means something. }
  S := TSession.Create(Id);
  try
    S.Save;
    AssertTrue(S.Meta.Location <> '', 'premise: an ordinary Save stamps the location here');
  finally
    S.Free;
  end;

  AssertTrue(not ResetSessionStats('stats-reset-no-such-' + IntToStr(Random(MaxInt))),
             'a missing session is not reset');
  AssertTrue(not ResetSessionStats('../escape'), 'an unsafe id is not reset');
  RemoveSession(Id);

  { A file that is not a session is left exactly as it is. }
  Id := 'stats-reset-junk-' + IntToStr(Random(MaxInt));
  WriteFileText(SessionPath(Id), '{"meta": {"stats": {"turns": 3');
  AssertTrue(not ResetSessionStats(Id), 'a file that does not parse is not reset');
  AssertTrue(ReadFileText(SessionPath(Id)) = '{"meta": {"stats": {"turns": 3',
             'a file that does not parse is not rewritten');
  RemoveSession(Id);
end;

var
  GProbeId: string;
  GProbeCalls: Integer;
  GProbeEvery: Boolean;

{ Another process finishing a turn on the session, at the worst moment:
  the reset has read the file and written its replacement beside it. }
procedure SaveATurnMeanwhile;
var
  S: TSession;
begin
  Inc(GProbeCalls);
  if (GProbeCalls > 1) and not GProbeEvery then Exit;
  S := TSession.Create(GProbeId);
  try
    SetLength(S.Messages, Length(S.Messages) + 1);
    S.Messages[High(S.Messages)] :=
      MakeMessage(mrAssistant, 'written meanwhile ' + IntToStr(GProbeCalls));
    Inc(S.Meta.Stats.Turns);
    S.Save;
  finally
    S.Free;
  end;
end;

procedure TestResetDoesNotOverwriteASave;
var
  Id: string;
  S: TSession;
begin
  { One save lands mid-reset: the reset starts over and keeps it. }
  Id := 'stats-reset-race-' + IntToStr(Random(MaxInt));
  SeedSession(Id);
  GProbeId := Id; GProbeCalls := 0; GProbeEvery := False;
  AssertTrue(ResetSessionStats(Id, SaveATurnMeanwhile), 'reset succeeds after starting over');
  AssertEqInt(GProbeCalls, 2, 'the reset started over once');
  S := TSession.Create(Id);
  try
    AssertEqInt(Length(S.Messages), 4, 'the message saved meanwhile is still there');
    AssertTrue(S.Messages[3].Content = 'written meanwhile 1', 'the message saved meanwhile');
    AssertTrue(SessionStatsEmpty(S.Meta.Stats), 'and the counters are zero');
  finally
    S.Free;
  end;
  AssertConversationKept(Id, 'after a save mid-reset');
  AssertTrue(not FileExists(SessionPath(Id) + '.reset.tmp'), 'no temporary file is left');
  RemoveSession(Id);

  { The file changes every time: the reset gives up and leaves it alone. }
  Id := 'stats-reset-busy-' + IntToStr(Random(MaxInt));
  SeedSession(Id);
  GProbeId := Id; GProbeCalls := 0; GProbeEvery := True;
  AssertTrue(not ResetSessionStats(Id, SaveATurnMeanwhile),
             'a file that keeps changing is not reset');
  AssertTrue(GProbeCalls > 1, 'the reset tried more than once');
  S := TSession.Create(Id);
  try
    AssertEqInt(Length(S.Messages), 3 + GProbeCalls, 'every save made meanwhile is there');
    AssertEqInt(S.Meta.Stats.Turns, 4 + GProbeCalls, 'the counters are as the last save left them');
  finally
    S.Free;
  end;
  AssertTrue(not FileExists(SessionPath(Id) + '.reset.tmp'), 'no temporary file is left');
  RemoveSession(Id);
end;

begin
  Randomize;
  TestProfileRoundTrip;
  TestProfileAbsentByDefault;
  TestStatsRoundTrip;
  TestEmptyStatsOmitted;
  TestAccumulateTurnStatsAddsCorrectly;
  TestAccumulateThenSavePersistsCounters;
  TestAccumulateRoutesToOriginatingSession;
  TestStatsCollectionEnabledRoundTrip;
  { Last: it sets a workspace, which earlier tests assume is unset. }
  TestResetDoesNotOverwriteASave;
  TestResetClearsCountersOnly;
  WriteLn('session_stats_tests: OK');
end.
