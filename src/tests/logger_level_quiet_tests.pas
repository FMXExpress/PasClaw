program logger_level_quiet_tests;
(*
  Pins the level-suppression contract PasClaw.dpr's IsQuietInvocation
  branch depends on: SetLogLevel(llError) must drop LogInfo / LogDebug
  / LogWarn while still letting LogError through. The dpr applies this
  whenever --quiet / -q is on argv so [info] / [debug] noise from
  Search.Factory, MCP.Bridge, etc. doesn't pollute the stdout pipeline
  scripts read.

  We assert on LogBufferSnapshot rather than on stderr -- the ring
  buffer mirrors the same level gate (Emit short-circuits BEFORE both
  the stderr WriteLn and the buffer Add), so observing the buffer is
  equivalent to observing what the user would have seen.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Logger;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

function BufferTailHas(const Marker: string;
                       Within: Integer = 8): Boolean;
{ Look for Marker in the last `Within` entries of the ring buffer.
  Each entry is "<tag>\t<message>", so a substring search is
  sufficient and avoids tag-coupling. }
var
  Snap: TStringList;
  i, Start: Integer;
begin
  Result := False;
  Snap := LogBufferSnapshot;
  try
    Start := Snap.Count - Within;
    if Start < 0 then Start := 0;
    for i := Start to Snap.Count - 1 do
      if Pos(Marker, Snap[i]) > 0 then Exit(True);
  finally
    Snap.Free;
  end;
end;

procedure TestLevelErrorSuppressesInfoAndDebug;
const
  MarkerDebug = 'qlt-DEBUG-MARKER-' + 'a4f9';
  MarkerInfo  = 'qlt-INFO-MARKER-'  + 'a4f9';
  MarkerWarn  = 'qlt-WARN-MARKER-'  + 'a4f9';
  MarkerError = 'qlt-ERROR-MARKER-' + 'a4f9';
begin
  SetLogLevel(llError);
  LogDebug(MarkerDebug);
  LogInfo (MarkerInfo);
  LogWarn (MarkerWarn);
  LogError(MarkerError);

  AssertTrue(not BufferTailHas(MarkerDebug),
             'llError suppresses LogDebug (would have been [info] noise)');
  AssertTrue(not BufferTailHas(MarkerInfo),
             'llError suppresses LogInfo  -- the actual case --quiet fixes');
  AssertTrue(not BufferTailHas(MarkerWarn),
             'llError suppresses LogWarn');
  AssertTrue(BufferTailHas(MarkerError),
             'llError keeps LogError so real failures still surface');
end;

procedure TestLevelInfoLetsInfoThrough;
const
  MarkerInfo  = 'qlt-INFO-DEFAULT-MARKER-' + 'a4f9';
  MarkerError = 'qlt-ERROR-DEFAULT-MARKER-' + 'a4f9';
begin
  SetLogLevel(llInfo);
  LogInfo (MarkerInfo);
  LogError(MarkerError);

  AssertTrue(BufferTailHas(MarkerInfo),
             'llInfo (the default) keeps LogInfo -- control for the suppression test');
  AssertTrue(BufferTailHas(MarkerError),
             'llInfo keeps LogError');
end;

procedure TestSetLogLevelFromStringErrorAlias;
const
  MarkerInfo  = 'qlt-FROMSTR-INFO-MARKER-' + 'a4f9';
  MarkerError = 'qlt-FROMSTR-ERROR-MARKER-' + 'a4f9';
begin
  { The dpr applies SetLogLevel(llError) directly, but operators who
    set PASCLAW_LOG=error via env (a separate mechanism) go through
    SetLogLevelFromString. Pin both aliases the string parser
    accepts so future renames can't silently strand --quiet's level
    choice. }
  SetLogLevelFromString('error');
  LogInfo (MarkerInfo);
  LogError(MarkerError);
  AssertTrue(not BufferTailHas(MarkerInfo),
             'SetLogLevelFromString("error") suppresses LogInfo');
  AssertTrue(BufferTailHas(MarkerError),
             'SetLogLevelFromString("error") keeps LogError');
end;

procedure TestCurrentLogLevelMatchesSet;
begin
  SetLogLevel(llError);
  AssertTrue(CurrentLogLevel = llError,
             'CurrentLogLevel reflects the most recent SetLogLevel');
  SetLogLevel(llInfo);
  AssertTrue(CurrentLogLevel = llInfo,
             'SetLogLevel reverts cleanly back to llInfo');
end;

begin
  TestLevelErrorSuppressesInfoAndDebug;
  WriteLn('  ok: SetLogLevel(llError) suppresses Debug/Info/Warn, keeps Error');
  TestLevelInfoLetsInfoThrough;
  WriteLn('  ok: default llInfo lets LogInfo / LogError through (control)');
  TestSetLogLevelFromStringErrorAlias;
  WriteLn('  ok: SetLogLevelFromString("error") matches SetLogLevel(llError)');
  TestCurrentLogLevelMatchesSet;
  WriteLn('  ok: CurrentLogLevel reflects the last SetLogLevel call');
  WriteLn('PASS');
end.
