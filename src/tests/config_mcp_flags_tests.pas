program config_mcp_flags_tests;
(*
  Covers the round-trip of the MCP behaviour flags through
  TConfig.ToJSON/FromJSON.

  Why this exists
  ===============

  Both flags default to True and are written ONLY when the operator turns
  them off. That is the right shape -- an on-keeper's config.json stays clean
  -- but it has a failure mode with teeth: if ToJSON forgets the key, the
  opt-out survives in memory and vanishes the next time any command calls
  SaveConfig (auth login, model set, PUT /v1/config). The next load restores
  the default and quietly re-enables the behaviour the operator switched off.

  That is not hypothetical. mcp_compact_results shipped with exactly this gap
  (Codex P2 on PR #509), and the Profile field two declarations above it
  carries a comment recording the same bug on an earlier PR. A load-side test
  cannot catch it, because loading works fine; only a SAVE-then-LOAD cycle
  does.

  Pins, for each flag:
    - the explicit OFF is serialised
    - the OFF survives save -> load
    - the default ON writes no key at all (a clean file for on-keepers)
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config;

var
  Failures: Integer = 0;

procedure Check(const Name: string; Cond: Boolean);
begin
  if Cond then
    WriteLn('  ok    ', Name)
  else
  begin
    WriteLn('  FAIL  ', Name);
    Inc(Failures);
  end;
end;

{ Save a config whose flags are set as asked, then load it back. }
procedure RoundTrip(Compact, Disclosure: Boolean;
  out JSON: string; out GotCompact, GotDisclosure: Boolean);
var
  C: TConfig;
begin
  C := TConfig.Create;
  try
    C.MCPCompactResults       := Compact;
    C.MCPProgressiveDisclosure := Disclosure;
    JSON := C.ToJSON;
  finally
    C.Free;
  end;

  C := TConfig.Create;
  try
    C.FromJSON(JSON);
    GotCompact    := C.MCPCompactResults;
    GotDisclosure := C.MCPProgressiveDisclosure;
  finally
    C.Free;
  end;
end;

procedure TestOptOutSurvives;
var
  JSON: string;
  GotCompact, GotDisclosure: Boolean;
begin
  WriteLn('operator turns both flags OFF');
  RoundTrip(False, False, JSON, GotCompact, GotDisclosure);
  Check('mcp_compact_results is written',
    Pos('"mcp_compact_results"', JSON) > 0);
  Check('mcp_progressive_disclosure is written',
    Pos('"mcp_progressive_disclosure"', JSON) > 0);
  Check('compact opt-out survives save -> load', not GotCompact);
  Check('disclosure opt-out survives save -> load', not GotDisclosure);
end;

procedure TestDefaultsStayOutOfTheFile;
var
  JSON: string;
  GotCompact, GotDisclosure: Boolean;
begin
  WriteLn('both flags left at their default ON');
  RoundTrip(True, True, JSON, GotCompact, GotDisclosure);
  Check('mcp_compact_results writes no key',
    Pos('"mcp_compact_results"', JSON) = 0);
  Check('mcp_progressive_disclosure writes no key',
    Pos('"mcp_progressive_disclosure"', JSON) = 0);
  Check('compact stays on', GotCompact);
  Check('disclosure stays on', GotDisclosure);
end;

procedure TestFlagsAreIndependent;
var
  JSON: string;
  GotCompact, GotDisclosure: Boolean;
begin
  WriteLn('one off, one on');
  RoundTrip(False, True, JSON, GotCompact, GotDisclosure);
  Check('compact off survives', not GotCompact);
  Check('disclosure unaffected', GotDisclosure);
  RoundTrip(True, False, JSON, GotCompact, GotDisclosure);
  Check('disclosure off survives', not GotDisclosure);
  Check('compact unaffected', GotCompact);
end;

begin
  WriteLn('MCP config flag round-trip');
  TestOptOutSurvives;
  TestDefaultsStayOutOfTheFile;
  TestFlagsAreIndependent;
  WriteLn;
  if Failures = 0 then
    WriteLn('all mcp config flag tests passed')
  else
  begin
    WriteLn(Failures, ' mcp config flag test(s) FAILED');
    Halt(1);
  end;
end.
