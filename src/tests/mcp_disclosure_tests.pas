program mcp_disclosure_tests;
(*
  Tests for PasClaw.MCP.Disclosure (progressive disclosure / tool_search,
  Claude Code-style ToolSearch parity).

  Coverage:
    - TToolRegistry.ToProviderDefs strips IsDeferred=True tools by default.
    - Plain Register defensively zeroes IsDeferred (legacy stack-garbage
      safety -- the reviewer's P1 concern on PR #315).
    - TToolRegistry.Reveal flips a deferred name into the visible set.
    - TToolRegistry.DeferredNames / DeferredFind only see deferred entries.
    - tool_search "select:Name" returns a <function> block for the matched
      name AND reveals it (next ToProviderDefs sees it).
    - tool_search keyword query ranks by name+description hit count and
      caps at max_results.
    - tool_search "+required keyword" rejects tools whose name lacks the
      required substring.
    - tool_search on an empty / unknown query returns a clean text result
      rather than crashing or wedging.
    - Cfg.MCPProgressiveDisclosure round-trips through SaveConfig /
      LoadConfig.

  These tests construct a TToolRegistry directly and register synthetic
  TTool records -- no actual MCP server is started, so the test stays
  hermetic (no sockets, no subprocesses, runs offline).
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.MCP.Disclosure,
  PasClaw.JSON,
  PasClaw.Utils;

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertEqI(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')'); end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin if Pos(Needle, Haystack) = 0 then
  Fail_(Msg + ' (no "' + Needle + '" in "' + Haystack + '")'); end;

{ A no-op handler for the synthetic tools. The disclosure path never
  actually calls it; we just need a valid TTool record to register. }
function NoopHandler(const ArgsJSON: string; out ErrMsg: string): string;
begin ErrMsg := ''; Result := ''; end;

{ Register a synthetic deferred tool. Routes through the registry's
  RegisterDeferred to mirror how the MCP bridge actually registers --
  plain Register defensively clears IsDeferred, so a test that sets
  T.IsDeferred := True then called Register would silently get False
  and the registry-filtering tests would all pass on a no-op. }
procedure RegisterDeferredTool(Reg: TToolRegistry; const Name, Desc: string);
var T: TTool;
begin
  FillChar(T, SizeOf(T), 0);
  T.Name := Name;
  T.Description := Desc;
  T.Schema := '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}';
  T.Handler := NoopHandler;
  T.Category := tcReadOnly;
  Reg.RegisterDeferred(T, True);
end;

procedure RegisterVisible(Reg: TToolRegistry; const Name: string);
var T: TTool;
begin
  FillChar(T, SizeOf(T), 0);
  T.Name := Name;
  T.Description := 'visible';
  T.Schema := '{}';
  T.Handler := NoopHandler;
  T.Category := tcReadOnly;
  Reg.Register(T);
end;

function CountResults(Reg: TToolRegistry): Integer;
begin Result := Length(Reg.ToProviderDefs); end;

procedure TestRegistryFiltersDeferred;
var
  Reg: TToolRegistry;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterVisible (Reg, 'fs_read');
    RegisterDeferredTool(Reg, 'github__list_issues',  'List issues');
    RegisterDeferredTool(Reg, 'github__create_issue', 'Create issue');
    RegisterVisible (Reg, 'fs_write');
    AssertEqI(CountResults(Reg), 2, 'ToProviderDefs strips IsDeferred entries');
    AssertEqI(Length(Reg.DeferredNames), 2, 'DeferredNames lists the deferred pair');
  finally
    Reg.Free;
  end;
  WriteLn('  ok: registry filters deferred');
end;

procedure TestLegacyRegisterClearsIsDeferred;
{ Reviewer concern on PR #315: legacy callers (RegisterFSTools,
  RegisterShellTool, every TPasClawTool subclass) build T: TTool on
  the stack without ever touching the new IsDeferred field. Stack
  garbage there could cause ToProviderDefs to silently drop core
  tools even when MCP progressive disclosure is off. The defensive
  clear in plain Register protects against that; this test
  simulates the risk by setting IsDeferred := True before calling
  plain Register and asserts the tool nevertheless shows up in
  ToProviderDefs (because Register zeroes the field). The MCP path
  -- the only legitimate IsDeferred=True source -- uses
  RegisterDeferred instead, which is exercised by the other tests. }
var
  Reg: TToolRegistry;
  T: TTool;
begin
  Reg := TToolRegistry.Create;
  try
    FillChar(T, SizeOf(T), 0);
    T.Name := 'fs_read';
    T.Description := 'core tool with garbage IsDeferred';
    T.Schema := '{}';
    T.Handler := NoopHandler;
    T.Category := tcReadOnly;
    T.IsDeferred := True;   { simulates stack garbage in a non-MCP path }
    Reg.Register(T);
    AssertEqI(CountResults(Reg), 1,
              'plain Register defensively clears IsDeferred even when caller sets True');
    AssertEqI(Length(Reg.DeferredNames), 0,
              'plain Register: tool does not leak into DeferredNames');
  finally
    Reg.Free;
  end;
  WriteLn('  ok: plain Register clears IsDeferred (legacy stack-garbage safety)');
end;

procedure TestRevealAddsToProviderDefs;
var
  Reg: TToolRegistry;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterVisible (Reg, 'fs_read');
    RegisterDeferredTool(Reg, 'github__list_issues', 'List issues');
    Reg.Reveal('github__list_issues');
    AssertEqI(CountResults(Reg), 2, 'Reveal moves a deferred tool into ToProviderDefs');
    AssertEqI(Length(Reg.DeferredNames), 0,
              'Reveal removes from DeferredNames');
  finally
    Reg.Free;
  end;
  WriteLn('  ok: reveal surfaces the deferred tool');
end;

procedure TestRevealUnknownIsNoop;
var
  Reg: TToolRegistry;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterDeferredTool(Reg, 'github__list_issues', 'List issues');
    { Stale model that calls tool_search with a stale name from a
      previous session must not wedge the registry. }
    Reg.Reveal('does_not_exist');
    Reg.Reveal('');
    AssertEqI(CountResults(Reg), 0, 'Reveal of unknown name is a no-op');
    AssertEqI(Length(Reg.DeferredNames), 1,
              'Reveal of unknown name does not consume the deferred entry');
  finally
    Reg.Free;
  end;
  WriteLn('  ok: reveal of unknown name is a no-op');
end;

procedure TestToolSearchSelectQuery;
var
  Reg: TToolRegistry;
  Cfg: TConfig;
  T: TTool;
  Result_, ErrMsg: string;
begin
  Reg := TToolRegistry.Create;
  Cfg := TConfig.Create;
  try
    Cfg.MCPProgressiveDisclosure := True;
    RegisterDeferredTool(Reg, 'github__list_issues',  'List issues on a repo');
    RegisterDeferredTool(Reg, 'github__create_issue', 'Open a new issue');
    RegisterMCPDisclosureTools(Reg, Cfg);
    AssertTrue(Reg.Find('tool_search', T),
               'tool_search registered when MCPProgressiveDisclosure=True');
    Result_ := Reg.RunTool('tool_search',
                            '{"query":"select:github__list_issues"}', ErrMsg);
    AssertTrue(ErrMsg = '', 'select query: no error');
    AssertContains(Result_, '<function>',
                   'select query: returns a <function> block');
    AssertContains(Result_, 'github__list_issues',
                   'select query: includes the requested tool name');
    AssertEqI(CountResults(Reg), 2,
              { tool_search itself + the revealed tool }
              'select query: reveals the matched tool into ToProviderDefs');
  finally
    Cfg.Free;
    Reg.Free;
  end;
  WriteLn('  ok: tool_search select: loads + reveals');
end;

procedure TestToolSearchKeywordQueryRanksAndCaps;
var
  Reg: TToolRegistry;
  Cfg: TConfig;
  Result_, ErrMsg: string;
begin
  Reg := TToolRegistry.Create;
  Cfg := TConfig.Create;
  try
    Cfg.MCPProgressiveDisclosure := True;
    RegisterDeferredTool(Reg, 'github__list_issues',  'List issues on a repo');
    RegisterDeferredTool(Reg, 'github__create_issue', 'Open a new issue with title and body');
    RegisterDeferredTool(Reg, 'github__list_prs',     'List pull requests');
    RegisterDeferredTool(Reg, 'slack__post_message',  'Post a Slack message');
    RegisterMCPDisclosureTools(Reg, Cfg);

    { "issue" should hit the two github__ issue tools (name + desc) and
      miss the prs / slack ones. max_results=1 caps the result. }
    Result_ := Reg.RunTool('tool_search',
                            '{"query":"issue","max_results":1}', ErrMsg);
    AssertTrue(ErrMsg = '', 'keyword query: no error');
    AssertContains(Result_, 'Loaded 1 tool(s)',
                   'keyword query: respects max_results cap');
    { Either of the two issue tools is acceptable; check that some
      issue tool came back rather than the prs / slack ones. }
    AssertTrue((Pos('github__list_issues',  Result_) > 0) or
               (Pos('github__create_issue', Result_) > 0),
               'keyword query: returns an issue tool');
    AssertTrue(Pos('slack__post_message', Result_) = 0,
               'keyword query: does not return a non-matching tool');
  finally
    Cfg.Free;
    Reg.Free;
  end;
  WriteLn('  ok: tool_search keyword ranks + caps');
end;

procedure TestToolSearchRequiredTerm;
var
  Reg: TToolRegistry;
  Cfg: TConfig;
  Result_, ErrMsg: string;
begin
  Reg := TToolRegistry.Create;
  Cfg := TConfig.Create;
  try
    Cfg.MCPProgressiveDisclosure := True;
    RegisterDeferredTool(Reg, 'github__list_issues', 'List issues');
    RegisterDeferredTool(Reg, 'slack__list_channels','List Slack channels');
    RegisterMCPDisclosureTools(Reg, Cfg);
    { "+slack list" must require "slack" in the name -- the github
      tool also matches "list" but its name lacks "slack". }
    Result_ := Reg.RunTool('tool_search',
                            '{"query":"+slack list"}', ErrMsg);
    AssertTrue(ErrMsg = '', 'required-term query: no error');
    AssertContains(Result_, 'slack__list_channels',
                   'required-term query: returns the slack-prefixed tool');
    AssertTrue(Pos('github__list_issues', Result_) = 0,
               'required-term query: rejects tool lacking the required substring');
  finally
    Cfg.Free;
    Reg.Free;
  end;
  WriteLn('  ok: tool_search +required filters by name');
end;

procedure TestToolSearchEmptyDeferred;
var
  Reg: TToolRegistry;
  Cfg: TConfig;
  Result_, ErrMsg: string;
begin
  Reg := TToolRegistry.Create;
  Cfg := TConfig.Create;
  try
    Cfg.MCPProgressiveDisclosure := True;
    RegisterMCPDisclosureTools(Reg, Cfg);
    Result_ := Reg.RunTool('tool_search', '{"query":"anything"}', ErrMsg);
    AssertTrue(ErrMsg = '', 'empty-deferred: no error');
    { No MCP servers configured at all -> explain that, not a bare dead end. }
    AssertContains(Result_, 'No MCP tools are configured',
                   'empty-deferred (none configured): explains nothing is configured');
  finally
    Cfg.Free;
    Reg.Free;
  end;
  WriteLn('  ok: tool_search with no MCP configured returns an explanatory message');
end;

procedure TestToolSearchEmptyDeferredDisabledServer;
{ The case that produced the 25-call flail: an MCP server is configured but
  disabled, so no tools register. tool_search must NAME it as disabled with the
  fix, instead of "No deferred tools to search" (which reads as "no such
  capability"). }
var
  Reg: TToolRegistry;
  Cfg: TConfig;
  Result_, ErrMsg: string;
begin
  Reg := TToolRegistry.Create;
  Cfg := TConfig.Create;
  try
    Cfg.MCPProgressiveDisclosure := True;
    SetLength(Cfg.MCPServers, 1);
    Cfg.MCPServers[0].Name    := 'replicate';
    Cfg.MCPServers[0].Enabled := False;
    RegisterMCPDisclosureTools(Reg, Cfg);
    Result_ := Reg.RunTool('tool_search', '{"query":"flux image"}', ErrMsg);
    AssertTrue(ErrMsg = '', 'disabled-server: no error');
    AssertContains(Result_, 'DISABLED', 'disabled-server: flags a disabled server');
    AssertContains(Result_, 'replicate', 'disabled-server: names the disabled server');
  finally
    Cfg.Free;
    Reg.Free;
  end;
  WriteLn('  ok: tool_search names a configured-but-disabled MCP server');
end;

procedure TestToolSearchEmptyDeferredEnabledButUnloaded;
{ Enabled server but no tools registered yet (cold cache / still connecting /
  failed). tool_search should say so and suggest a retry, not a dead end. }
var
  Reg: TToolRegistry;
  Cfg: TConfig;
  Result_, ErrMsg: string;
begin
  Reg := TToolRegistry.Create;
  Cfg := TConfig.Create;
  try
    Cfg.MCPProgressiveDisclosure := True;
    SetLength(Cfg.MCPServers, 1);
    Cfg.MCPServers[0].Name    := 'replicate';
    Cfg.MCPServers[0].Enabled := True;
    RegisterMCPDisclosureTools(Reg, Cfg);
    Result_ := Reg.RunTool('tool_search', '{"query":"flux image"}', ErrMsg);
    AssertTrue(ErrMsg = '', 'enabled-unloaded: no error');
    AssertContains(Result_, 'no tools loaded yet',
                   'enabled-unloaded: explains the server has not loaded tools');
    AssertContains(Result_, 'replicate', 'enabled-unloaded: names the server');
  finally
    Cfg.Free;
    Reg.Free;
  end;
  WriteLn('  ok: tool_search explains an enabled-but-unloaded MCP server');
end;

procedure TestToolSearchSkipsRegistrationWhenDisabled;
var
  Reg: TToolRegistry;
  Cfg: TConfig;
  T: TTool;
begin
  Reg := TToolRegistry.Create;
  Cfg := TConfig.Create;
  try
    Cfg.MCPProgressiveDisclosure := False;  { explicit off }
    RegisterMCPDisclosureTools(Reg, Cfg);
    AssertTrue(not Reg.Find('tool_search', T),
               'tool_search not registered when MCPProgressiveDisclosure=False');
  finally
    Cfg.Free;
    Reg.Free;
  end;
  WriteLn('  ok: tool_search skipped when disclosure off');
end;

procedure TestConfigRoundTrip;
var
  Fresh, Saved, Loaded: TConfig;
begin
  { Fresh-install default is True (PR moved the floor in response to
    operators running fat-catalog MCP servers like Replicate). Verify
    the default first so a future regression that flips it back surfaces
    here rather than as a behaviour change in production. }
  Fresh := LoadConfig('');
  try
    AssertTrue(Fresh.MCPProgressiveDisclosure,
               'fresh install: MCPProgressiveDisclosure defaults True');
  finally
    Fresh.Free;
  end;

  { Round-trip the opt-OUT direction since True is the default. Setting
    True would write nothing (SaveConfig skips equal-to-default fields)
    and the load would just re-read the default -- not exercising the
    round-trip at all. }
  Saved := LoadConfig('');
  try
    Saved.MCPProgressiveDisclosure := False;
    SaveConfig(Saved);
  finally
    Saved.Free;
  end;
  Loaded := LoadConfig('');
  try
    AssertTrue(not Loaded.MCPProgressiveDisclosure,
               'mcp_progressive_disclosure opt-out round-trips through save/load');
  finally
    Loaded.Free;
  end;
  WriteLn('  ok: config defaults True, opt-out round-trips');
end;

begin
  TestRegistryFiltersDeferred;
  TestLegacyRegisterClearsIsDeferred;
  TestRevealAddsToProviderDefs;
  TestRevealUnknownIsNoop;
  TestToolSearchSelectQuery;
  TestToolSearchKeywordQueryRanksAndCaps;
  TestToolSearchRequiredTerm;
  TestToolSearchEmptyDeferred;
  TestToolSearchEmptyDeferredDisabledServer;
  TestToolSearchEmptyDeferredEnabledButUnloaded;
  TestToolSearchSkipsRegistrationWhenDisabled;
  TestConfigRoundTrip;
  WriteLn('ok - mcp disclosure tests passed');
end.
