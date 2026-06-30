program subagent_default_tests;
(*
  Covers the "subagents on by default" behavior:
    - ResolveSubagentSpecs returns a built-in general-purpose agent when none
      are configured (so `spawn` registers out of the box);
    - it is empty when SubagentsEnabled = False;
    - a configured "general-purpose" overrides the built-in (no duplicate);
    - BuildFilteredRegistry('*') inherits the parent's ACTIVE tools, excluding
      the spawn family, tool_search, and deferred (unrevealed) MCP tools;
    - subagents_enabled round-trips through Save/Load (default True).
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Agent.Subagent;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqI(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')'); end;

function NoopHandler(const ArgsJSON: string; out ErrMsg: string): string;
begin ErrMsg := ''; Result := ''; end;

procedure AddPlain(Reg: TToolRegistry; const Name: string);
var T: TTool;
begin
  FillChar(T, SizeOf(T), 0);
  T.Name := Name; T.Description := Name; T.Schema := '{}';
  T.Handler := NoopHandler; T.Category := tcReadOnly;
  Reg.Register(T);
end;

procedure AddDeferred(Reg: TToolRegistry; const Name: string);
var T: TTool;
begin
  FillChar(T, SizeOf(T), 0);
  T.Name := Name; T.Description := Name; T.Schema := '{}';
  T.Handler := NoopHandler; T.Category := tcReadOnly;
  Reg.RegisterDeferred(T, True);
end;

procedure TestDefaultPresentWhenNoneConfigured;
var Cfg: TConfig; Specs: TSubagentSpecArray;
begin
  Cfg := TConfig.Create;
  try
    AssertTrue(Cfg.SubagentsEnabled, 'SubagentsEnabled defaults True');
    Specs := ResolveSubagentSpecs(Cfg);
    AssertEqI(Length(Specs), 1, 'one built-in spec when none configured');
    AssertTrue(SameText(Specs[0].Name, 'general-purpose'), 'built-in is general-purpose');
    AssertTrue((Length(Specs[0].Tools) = 1) and (Specs[0].Tools[0] = '*'),
               'general-purpose inherits all tools via *');
  finally Cfg.Free; end;
  WriteLn('  ok: built-in general-purpose subagent present by default');
end;

procedure TestEmptyWhenDisabled;
var Cfg: TConfig; Specs: TSubagentSpecArray;
begin
  Cfg := TConfig.Create;
  try
    Cfg.SubagentsEnabled := False;
    Specs := ResolveSubagentSpecs(Cfg);
    AssertEqI(Length(Specs), 0, 'no specs when SubagentsEnabled is False');
  finally Cfg.Free; end;
  WriteLn('  ok: opt-out removes all subagent specs');
end;

procedure TestConfiguredPlusDefault;
var Cfg: TConfig; Specs: TSubagentSpecArray;
begin
  Cfg := TConfig.Create;
  try
    SetLength(Cfg.Subagents, 1);
    Cfg.Subagents[0].Name := 'researcher';
    Specs := ResolveSubagentSpecs(Cfg);
    AssertEqI(Length(Specs), 2, 'configured agent + built-in general-purpose');
    AssertTrue(SameText(Specs[1].Name, 'general-purpose'), 'general-purpose appended');
  finally Cfg.Free; end;
  WriteLn('  ok: configured subagents coexist with the built-in default');
end;

procedure TestOperatorOverridesGeneralPurpose;
var Cfg: TConfig; Specs: TSubagentSpecArray;
begin
  Cfg := TConfig.Create;
  try
    SetLength(Cfg.Subagents, 1);
    Cfg.Subagents[0].Name := 'general-purpose';   { operator's own }
    Specs := ResolveSubagentSpecs(Cfg);
    AssertEqI(Length(Specs), 1, 'operator general-purpose is not duplicated by the built-in');
  finally Cfg.Free; end;
  WriteLn('  ok: operator general-purpose overrides the built-in');
end;

procedure TestWildcardInheritsActiveTools;
var Src, Filtered: TToolRegistry; Names: array of string;
begin
  Src := TToolRegistry.Create;
  try
    AddPlain(Src, 'fs_read');
    AddPlain(Src, 'shell_exec');
    AddPlain(Src, 'spawn');             { spawn family -> excluded }
    AddPlain(Src, 'spawn_background');  { spawn family -> excluded }
    AddPlain(Src, 'tool_search');       { excluded }
    AddDeferred(Src, 'github__list');   { deferred MCP -> excluded }
    SetLength(Names, 1); Names[0] := '*';
    Filtered := BuildFilteredRegistry(Src, Names);
    try
      AssertEqI(Filtered.Count, 2, 'wildcard yields only fs_read + shell_exec');
    finally Filtered.Free; end;
  finally Src.Free; end;
  WriteLn('  ok: * inherits active parent tools, drops spawn*/tool_search/deferred');
end;

procedure TestExplicitListStillExcludesSpawn;
var Src, Filtered: TToolRegistry; Names: array of string;
begin
  Src := TToolRegistry.Create;
  try
    AddPlain(Src, 'fs_read');
    AddPlain(Src, 'spawn');
    SetLength(Names, 2); Names[0] := 'fs_read'; Names[1] := 'spawn';
    Filtered := BuildFilteredRegistry(Src, Names);
    try
      AssertEqI(Filtered.Count, 1, 'explicit list still drops spawn');
    finally Filtered.Free; end;
  finally Src.Free; end;
  WriteLn('  ok: explicit tool list never includes the spawn family');
end;

procedure TestConfigRoundTrip;
var Fresh, Loaded: TConfig; S: string;
begin
  Fresh := TConfig.Create;
  try
    AssertTrue(Pos('subagents_enabled', Fresh.ToJSON) = 0,
               'default-True not emitted (tidy)');
    Fresh.SubagentsEnabled := False;
    S := Fresh.ToJSON;
    AssertTrue(Pos('subagents_enabled', S) > 0, 'opt-out is emitted');
    Loaded := TConfig.Create;
    try
      Loaded.FromJSON(S);
      AssertTrue(not Loaded.SubagentsEnabled, 'opt-out round-trips to False');
    finally Loaded.Free; end;
  finally Fresh.Free; end;
  WriteLn('  ok: subagents_enabled defaults True, opt-out round-trips');
end;

begin
  TestDefaultPresentWhenNoneConfigured;
  TestEmptyWhenDisabled;
  TestConfiguredPlusDefault;
  TestOperatorOverridesGeneralPurpose;
  TestWildcardInheritsActiveTools;
  TestExplicitListStillExcludesSpawn;
  TestConfigRoundTrip;
  WriteLn('subagent_default_tests: OK');
end.
