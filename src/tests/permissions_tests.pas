program permissions_tests;
(*
  PasClaw.Permissions, the ordered rule list, and its dispatch gate.

    - GlobMatch: *, ?, case, empty pattern
    - ResourceOf: command / code / path / url / ''
    - EvaluateRules: last match wins, tool-only rule, resource glob, no match
    - Parse / ToJSON round-trip, bad effects skipped
    - Decide: policies first, policy deny beats config allow, policy ask
      outranks config allow, config deny stands; policy file picked up
      and re-read on change (mtime)
    - session allow memory: remembered per session key, forgotten
    - the dispatch gate (MakeLoopDispatcher): deny -> refusal result, no
      handler run; ask with no asker -> refusal; ask + asker allow once
      -> runs, asked again next time; ask + asker allow session -> runs,
      not asked the second time; ask + asker deny -> refusal; no rule ->
      runs; a mode refusal still comes first
    - config round-trip of the permissions array; ApplyConfigGlobals
      installs the rules
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Agent.Mode,
  PasClaw.Tools.ToolLoop,
  PasClaw.Permissions;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;
procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' + Want + '")'); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '" in: ' + Copy(Hay, 1, 240)); end;

function R(const Tool, Res: string; E: TPermEffect): TPermRule;
begin
  Result.Tool := Tool; Result.Resource := Res; Result.Effect := E; Result.Source := 'config';
end;

procedure TestPure;
var
  Rules: TPermRuleArray;
  D: TPermDecision;
  J: string;
begin
  AssertTrue(GlobMatch('*', 'anything'), '* matches');
  AssertTrue(GlobMatch('git status*', 'git status --short'), 'prefix glob');
  AssertTrue(not GlobMatch('git status*', 'git push origin'), 'prefix glob rejects');
  AssertTrue(GlobMatch('github__*', 'GitHub__list_issues'), 'case-insensitive');
  AssertTrue(GlobMatch('fs_?rite', 'fs_write'), '? matches one');
  AssertTrue(not GlobMatch('fs_?rite', 'fs_rite'), '? needs a char');
  AssertTrue(GlobMatch('', ''), 'empty matches empty');
  AssertTrue(not GlobMatch('', 'x'), 'empty does not match text');
  AssertTrue(GlobMatch('*/secrets/*', '/home/u/secrets/key.pem'), 'infix glob');

  AssertEqStr(ResourceOf('shell_exec', '{"command":"ls -la"}'), 'ls -la', 'shell command');
  AssertEqStr(ResourceOf('shell_background', '{"command":"make"}'), 'make', 'background command');
  AssertEqStr(ResourceOf('execute_code', '{"code":"echo 1"}'), 'echo 1', 'script body');
  AssertEqStr(ResourceOf('fs_write', '{"path":"/tmp/x"}'), '/tmp/x', 'fs path');
  AssertEqStr(ResourceOf('write_file', '{"path":"a.txt"}'), 'a.txt', 'legacy path');
  AssertEqStr(ResourceOf('web_fetch', '{"url":"https://x"}'), 'https://x', 'url');
  AssertEqStr(ResourceOf('memory_search', '{"q":"x"}'), '', 'no primary resource');
  AssertEqStr(ResourceOf('shell_exec', 'not json'), '', 'bad json -> empty');

  SetLength(Rules, 4);
  Rules[0] := R('shell_exec', '', peAsk);
  Rules[1] := R('shell_exec', 'git status*', peAllow);
  Rules[2] := R('shell_exec', 'git push*', peDeny);
  Rules[3] := R('*', '*/secrets/*', peDeny);
  D := EvaluateRules(Rules, 'shell_exec', 'git status');
  AssertTrue((D.Effect = peAllow) and (D.Index = 1), 'resource rule wins over tool-only rule');
  D := EvaluateRules(Rules, 'shell_exec', 'git push origin main');
  AssertTrue((D.Effect = peDeny) and (D.Index = 2), 'deny rule');
  D := EvaluateRules(Rules, 'shell_exec', 'make test');
  AssertTrue((D.Effect = peAsk) and (D.Index = 0), 'falls back to the tool-only ask');
  D := EvaluateRules(Rules, 'fs_read', '/home/u/secrets/k');
  AssertTrue((D.Effect = peDeny) and (D.Index = 3), 'wildcard tool rule applies to fs_read');
  D := EvaluateRules(Rules, 'fs_read', '/home/u/notes');
  AssertTrue((D.Effect = peNone) and (D.Index = -1), 'no match -> none');
  { Later rule overrides earlier even when both match. }
  SetLength(Rules, 2);
  Rules[0] := R('fs_*', '', peDeny);
  Rules[1] := R('fs_read', '', peAllow);
  AssertTrue(EvaluateRules(Rules, 'fs_read', 'x').Effect = peAllow, 'last match wins');
  AssertTrue(EvaluateRules(Rules, 'fs_write', 'x').Effect = peDeny, 'earlier rule still covers the rest');

  Rules := ParsePermissionRules('[{"tool":"shell_exec","effect":"ask"},' +
                                 '{"tool":"x","effect":"bogus"},' +
                                 '{"tool":"fs_*","resource":"/etc/*","effect":"DENY"}]', 'config');
  AssertEqInt(Length(Rules), 2, 'bad effect skipped');
  AssertTrue(Rules[1].Effect = peDeny, 'effect case-insensitive');
  AssertEqStr(Rules[1].Resource, '/etc/*', 'resource kept');
  J := PermissionRulesToJSON(Rules);
  AssertEqInt(Length(ParsePermissionRules(J, 'config')), 2, 'round-trips');
  AssertContains(J, '"effect"', 'json has effect');
  AssertContains(PermissionRefusal('shell_exec', 'git push', EvaluateRules(Rules, 'shell_exec', 'git push')),
                 'refused: tool "shell_exec" on "git push"', 'refusal text');
  WriteLn('  ok: glob, resource, evaluate, parse/json, refusal');
end;

procedure TestDecideAndPolicies;
var
  Home, PPath: string;
  Rules: TPermRuleArray;
  D: TPermDecision;
begin
  Home := JoinPath(GetTempDir, 'pasclaw-perm-test-' + IntToStr(GetProcessID));
  EnsureDir(Home);
  PPath := PolicyFilePath(Home);
  if FileExists(PPath) then DeleteFile(PPath);
  LoadPolicyFile(Home);
  AssertEqInt(Length(PolicyRules), 0, 'no policy file -> no policy rules');

  SetLength(Rules, 2);
  Rules[0] := R('shell_exec', '', peAllow);
  Rules[1] := R('web_fetch', '', peAsk);
  SetPermissionRules(Rules);
  D := Decide('shell_exec', 'rm x');
  AssertTrue((D.Effect = peAllow) and (not D.FromPolicy), 'config allow');
  AssertTrue(Decide('fs_read', 'x').Effect = peNone, 'unmatched -> none');

  { A policy appears: deny beats config allow; ask outranks config allow. }
  WriteFileText(PPath, '{"permissions":[{"tool":"shell_exec","resource":"rm *","effect":"deny"},' +
                       '{"tool":"fs_write","effect":"ask"}]}');
  Sleep(1100);   { mtime granularity }
  D := Decide('shell_exec', 'rm x');
  AssertTrue((D.Effect = peDeny) and D.FromPolicy, 'policy deny beats config allow');
  D := Decide('shell_exec', 'ls');
  AssertTrue((D.Effect = peAllow) and (not D.FromPolicy), 'policy with no match falls through to config');
  SetLength(Rules, 3);
  Rules[2] := R('fs_write', '', peAllow);
  SetPermissionRules(Rules);
  D := Decide('fs_write', 'a');
  AssertTrue((D.Effect = peAsk) and D.FromPolicy, 'policy ask outranks config allow');
  Rules[2] := R('fs_write', '', peDeny);
  SetPermissionRules(Rules);
  AssertTrue(Decide('fs_write', 'a').Effect = peDeny, 'config deny stands under a policy ask');

  { Re-read on change; bare-array form. }
  Sleep(1100);
  WriteFileText(PPath, '[{"tool":"web_fetch","effect":"deny"}]');
  D := Decide('web_fetch', 'https://x');
  AssertTrue((D.Effect = peDeny) and D.FromPolicy, 'policy file re-read on mtime change (bare array)');
  AssertTrue(Decide('shell_exec', 'rm x').Effect = peAllow, 'old policy rule gone');
  Sleep(1100);
  DeleteFile(PPath);
  AssertTrue(Decide('web_fetch', 'https://x').Effect = peAsk, 'deleted policy file -> config rules only');

  { Session allows. }
  AssertTrue(not SessionAllowed('s1', 'web_fetch', 'https://x'), 'not allowed yet');
  RememberSessionAllow('s1', 'web_fetch', 'https://x');
  AssertTrue(SessionAllowed('s1', 'web_fetch', 'https://x'), 'remembered');
  AssertTrue(SessionAllowed('s1', 'WEB_FETCH', 'https://x'), 'tool case-insensitive');
  AssertTrue(not SessionAllowed('s2', 'web_fetch', 'https://x'), 'per session');
  AssertTrue(not SessionAllowed('s1', 'web_fetch', 'https://y'), 'per resource');
  ForgetSessionAllows('s1');
  AssertTrue(not SessionAllowed('s1', 'web_fetch', 'https://x'), 'forgotten');
  SetLength(Rules, 0);
  SetPermissionRules(Rules);
  WriteLn('  ok: Decide with policies (precedence, mtime reload), session allows');
end;

{ ---- the gate ---- }

var
  GRan: Integer = 0;
  GAsked: Integer = 0;

function Danger(const ArgsJSON: string; out ErrMsg: string): string;
begin ErrMsg := ''; Inc(GRan); Result := 'ran'; end;

type
  TFakeAsker = class
  public
    Answer: TAskAnswer;
    LastTool, LastResource: string;
    function Ask(const ToolName, ArgsJSON, Resource, Reason: string): TAskAnswer;
  end;

function TFakeAsker.Ask(const ToolName, ArgsJSON, Resource, Reason: string): TAskAnswer;
begin
  Inc(GAsked);
  LastTool := ToolName; LastResource := Resource;
  Result := Answer;
end;

procedure TestGate;
var
  Reg: TToolRegistry;
  T: TTool;
  Cfg: TToolLoopConfig;
  Rules: TPermRuleArray;
  Asker: TFakeAsker;
  Disp: IToolDispatcher;
  Err, Res: string;
begin
  Reg := TToolRegistry.Create;
  Asker := TFakeAsker.Create;
  try
    FillChar(T, SizeOf(T), 0);
    T.Name := 'shell_exec'; T.Description := 'd'; T.Schema := '{"type":"object"}';
    T.Handler := @Danger; T.IsCore := True; T.Category := tcMutating;
    Reg.Register(T);
    Cfg := Default(TToolLoopConfig);
    Cfg.Registry := Reg; Cfg.Mode := pmBuild; Cfg.Model := 'fake'; Cfg.MaxIterations := 1;
    Cfg.SteeringKey := 'sess-perm';

    { No rules: runs. }
    SetLength(Rules, 0); SetPermissionRules(Rules);
    GRan := 0;
    Disp := MakeLoopDispatcher(Cfg);
    Res := Disp.Dispatch('shell_exec', '{"command":"ls"}', Err);
    AssertEqStr(Res, 'ran', 'no rule -> runs');

    { Deny. }
    SetLength(Rules, 1); Rules[0] := R('shell_exec', 'rm *', peDeny); SetPermissionRules(Rules);
    GRan := 0;
    Res := Disp.Dispatch('shell_exec', '{"command":"rm -rf x"}', Err);
    AssertEqStr(Err, '', 'deny is a result, not an error');
    AssertContains(Res, 'refused: tool "shell_exec" on "rm -rf x"', 'deny refusal text');
    AssertEqInt(GRan, 0, 'denied call never ran');
    Res := Disp.Dispatch('shell_exec', '{"command":"ls"}', Err);
    AssertEqStr(Res, 'ran', 'unmatched resource runs');

    { Ask with nobody to ask: deny. }
    Rules[0] := R('shell_exec', '', peAsk); SetPermissionRules(Rules);
    GRan := 0;
    Res := Disp.Dispatch('shell_exec', '{"command":"ls"}', Err);
    AssertContains(Res, 'refused', 'ask without an asker refuses');
    AssertContains(Res, 'no one', 'and says why');
    AssertEqInt(GRan, 0, 'did not run');

    { Ask with an asker. }
    Cfg.OnAsk := Asker.Ask;
    Disp := MakeLoopDispatcher(Cfg);
    Asker.Answer := aaDeny; GRan := 0; GAsked := 0;
    Res := Disp.Dispatch('shell_exec', '{"command":"ls"}', Err);
    AssertEqInt(GAsked, 1, 'asker consulted');
    AssertEqStr(Asker.LastResource, 'ls', 'asker saw the resource');
    AssertContains(Res, 'refused', 'asker deny refuses');
    AssertEqInt(GRan, 0, 'did not run');

    Asker.Answer := aaAllowOnce; GRan := 0; GAsked := 0;
    Res := Disp.Dispatch('shell_exec', '{"command":"ls"}', Err);
    AssertEqStr(Res, 'ran', 'allow once runs');
    Res := Disp.Dispatch('shell_exec', '{"command":"ls"}', Err);
    AssertEqInt(GAsked, 2, 'allow once asks again next time');

    Asker.Answer := aaAllowSession; GRan := 0; GAsked := 0;
    Res := Disp.Dispatch('shell_exec', '{"command":"make"}', Err);
    AssertEqStr(Res, 'ran', 'allow session runs');
    Res := Disp.Dispatch('shell_exec', '{"command":"make"}', Err);
    AssertEqStr(Res, 'ran', 'second call runs');
    AssertEqInt(GAsked, 1, 'allow session is not asked again for the same resource');
    Res := Disp.Dispatch('shell_exec', '{"command":"make clean"}', Err);
    AssertEqInt(GAsked, 2, 'a different resource is asked');
    ForgetSessionAllows('sess-perm');

    { Mode refusal comes first. }
    Cfg.Mode := pmPlan;
    Disp := MakeLoopDispatcher(Cfg);
    GAsked := 0;
    Res := Disp.Dispatch('shell_exec', '{"command":"ls"}', Err);
    AssertEqStr(Res, PlanModeRefusal('shell_exec'), 'plan mode refuses before permissions');
    AssertEqInt(GAsked, 0, 'no ask in plan mode');
    SetLength(Rules, 0); SetPermissionRules(Rules);
  finally
    Asker.Free;
    Reg.Free;
  end;
  WriteLn('  ok: dispatch gate: deny / ask without asker / ask answers / session allow / mode first');
end;

procedure TestConfig;
var
  A, B: TConfig;
  Rules: TPermRuleArray;
begin
  A := TConfig.Create;
  B := TConfig.Create;
  try
    AssertEqInt(Length(A.Permissions), 0, 'no rules by default');
    AssertTrue(Pos('"permissions"', A.ToJSON) = 0, 'empty list not emitted');
    A.FromJSON('{"permissions":[{"tool":"shell_exec","effect":"ask"},{"tool":"shell_exec","resource":"git status*","effect":"allow"}]}');
    AssertEqInt(Length(A.Permissions), 2, 'parsed two rules');
    AssertTrue(A.Permissions[1].Effect = peAllow, 'second rule allow');
    B.FromJSON(A.ToJSON);
    AssertEqInt(Length(B.Permissions), 2, 'round-trips');
    AssertEqStr(B.Permissions[1].Resource, 'git status*', 'resource round-trips');
    ApplyConfigGlobals(B);
    Rules := PermissionRules;
    AssertEqInt(Length(Rules), 2, 'ApplyConfigGlobals installs the rules');
    SetLength(Rules, 0); SetPermissionRules(Rules);
  finally
    A.Free;
    B.Free;
  end;
  WriteLn('  ok: config round-trip and globals');
end;

begin
  TestPure;
  TestDecideAndPolicies;
  TestGate;
  TestConfig;
  WriteLn('PASS');
end.
