(*
  stats_bench - benchmark harness for the /v1/stats aggregation path.

  Not a pass/fail suite: it prints timings so the stats plan can cite
  measurements rather than assertions about what "feels" slow.

  What it measures, at increasing session counts:
    1. ListSessions(True)  -- the walk /v1/stats performs per uncached
       request. This is the whole cost of the endpoint; HandleStats
       does nothing else but sum the records it returns.
    2. The same walk with IncludeBuckets=False, which is what the TUI
       and `pasclaw session list` pay, for comparison.
    3. Per-session transcript size, so the "loads the whole file to
       read seven counters" cost can be attributed.

  Usage: PASCLAW_HOME must point at a scratch dir. The Makefile target
  supplies one. Session count comes from argv[1] (default 200) and the
  transcript size in turns from argv[2] (default 20).
*)
program stats_bench;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils, Classes, DateUtils,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Workspaces,
  PasClaw.Providers.Types,
  PasClaw.Session.Store;

function NowMs: Double;
begin
  Result := MilliSecondsBetween(Now, EncodeDate(2020, 1, 1)) * 1.0;
end;

{ Wall-clock helper: Now has ~10ms resolution on some platforms, so every
  measurement below repeats until it has accumulated a meaningful span
  rather than timing a single sub-tick call. }
type
  TBenchProc = procedure;

function TimeIt(Proc: TBenchProc; MinMs: Double; out Iters: Integer): Double;
var
  T0, T1: TDateTime;
begin
  Iters := 0;
  T0 := Now;
  repeat
    Proc;
    Inc(Iters);
    T1 := Now;
  until MilliSecondsBetween(T1, T0) >= MinMs;
  Result := MilliSecondsBetween(T1, T0) / Iters;
end;

var
  Home: string;

procedure MakeSessions(N, TurnsEach: Integer; BucketEvery: Integer);
var
  i, t: Integer;
  S: TSession;
  M: TMessage;
  Id: string;
begin
  for i := 1 to N do
  begin
    { Interleave gateway bucket sessions at the requested rate so the
      IncludeBuckets=True / False split is measured against a realistic
      mix rather than an all-or-nothing corpus. }
    if (BucketEvery > 0) and (i mod BucketEvery = 0) then
      Id := Format('_gateway_v1_chat_%.6d', [i])
    else
      Id := Format('20260101T%.6d-bench%.4d', [i, i]);

    S := TSession.Create(Id);
    try
      S.Meta.CreatedAt := 1767225600 + i;
      S.Meta.UpdatedAt := 1767225600 + i;
      S.Meta.Title     := 'bench session ' + IntToStr(i);
      S.Meta.Model     := 'claude-bench-' + IntToStr(i mod 5);
      S.Meta.Provider  := 'provider-' + IntToStr(i mod 3);
      S.Meta.Stats.InputTokens  := i * 100;
      S.Meta.Stats.OutputTokens := i * 50;
      S.Meta.Stats.Turns        := TurnsEach;
      S.Meta.Stats.ToolCalls    := TurnsEach * 2;

      SetLength(S.Messages, TurnsEach);
      for t := 1 to TurnsEach do
      begin
        M := Default(TMessage);
        if t mod 2 = 1 then M.Role := mrUser else M.Role := mrAssistant;
        { Realistic-ish turn body. Transcript bulk is the whole point:
          ListSessions pays for it on every stats request. }
        M.Content := StringOfChar('x', 800) + ' turn ' + IntToStr(t);
        S.Messages[t - 1] := M;
      end;
      S.Save;
    finally
      S.Free;
    end;
  end;
end;

var
  GCount: Integer;

procedure WalkWithBuckets;
var
  A: TSessionMetaArray;
begin
  A := ListSessions(True);
  GCount := Length(A);
end;

procedure WalkWithoutBuckets;
var
  A: TSessionMetaArray;
begin
  A := ListSessions(False);
  GCount := Length(A);
end;

function DirBytes(const Dir: string): Int64;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(JoinPath(Dir, '*.json'), faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) = 0 then Inc(Result, SR.Size);
    until FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;
end;

var
  N, TurnsEach, Iters: Integer;
  MsWith, MsWithout: Double;
  Bytes: Int64;
  SessDir: string;
begin
  Home := GetHome;
  if (GetEnvironmentVariable('PASCLAW_HOME') = '') or (Home = '') then
  begin
    WriteLn('refusing to run without $PASCLAW_HOME (use: make bench-stats)');
    Halt(1);
  end;

  N := 200;
  TurnsEach := 20;
  if ParamCount >= 1 then N := StrToIntDef(ParamStr(1), 200);
  if ParamCount >= 2 then TurnsEach := StrToIntDef(ParamStr(2), 20);

  SessDir := JoinPath(Home, ActiveWorkspaceName + '/sessions');
  ForceDirectories(SessDir);

  Write(Format('building %d sessions x %d turns... ', [N, TurnsEach]));
  Flush(Output);
  MakeSessions(N, TurnsEach, {BucketEvery=} 5);
  Bytes := DirBytes(SessDir);
  WriteLn(Format('%.1f MB on disk', [Bytes / (1024 * 1024)]));

  MsWith := TimeIt(WalkWithBuckets, 400, Iters);
  WriteLn(Format('  ListSessions(True)   [/v1/stats path] : %8.2f ms  (%d sessions, %d iters)',
                 [MsWith, GCount, Iters]));

  MsWithout := TimeIt(WalkWithoutBuckets, 400, Iters);
  WriteLn(Format('  ListSessions(False)  [TUI / CLI path] : %8.2f ms  (%d sessions, %d iters)',
                 [MsWithout, GCount, Iters]));

  WriteLn(Format('  bytes read per stats request          : %8.1f MB', [Bytes / (1024 * 1024)]));
  if N > 0 then
    WriteLn(Format('  per-session cost                      : %8.3f ms', [MsWith / N]));
end.
