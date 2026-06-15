program skills_install_tests;
(*
  Covers the network-free parts of PasClaw.Skills.Install used by the web
  UI's POST/DELETE /v1/skills: target classification (which hub / GitHub /
  bare-slug, with @version split) and the IsSafeSkillName guard that keeps
  a DELETE from escaping workspace/skills/. The actual fetch/unpack is
  exercised by the hub clients' own paths and needs the network, so it's
  not pinned here.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Skills.Install;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEqS(const Got, Want, Msg: string);
begin
  if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure Check(const Target: string; WantKind: TSkillTargetKind;
                const WantSlug, WantVer: string);
var
  K: TSkillTargetKind;
  Slug, Ver: string;
begin
  ClassifySkillTarget(Target, K, Slug, Ver);
  AssertTrue(K = WantKind, 'kind for "' + Target + '"');
  AssertEqS(Slug, WantSlug, 'slug for "' + Target + '"');
  AssertEqS(Ver, WantVer, 'version for "' + Target + '"');
end;

begin
  { Explicit hub prefixes win; @version splits off. }
  Check('hub:foo',            stPasClawHub, 'foo', '');
  Check('hub:foo@1.2',        stPasClawHub, 'foo', '1.2');
  Check('clawhub:bar',        stClawHub,    'bar', '');
  Check('clawhub:bar@3',      stClawHub,    'bar', '3');

  { owner/repo and github URLs route to GitHub, passed through verbatim. }
  Check('owner/repo',                       stGitHub, 'owner/repo', '');
  Check('https://github.com/owner/repo',    stGitHub, 'https://github.com/owner/repo', '');

  { Bare slug -> hub fallback chain; @version splits. }
  Check('baz',     stBareSlug, 'baz', '');
  Check('baz@2.0', stBareSlug, 'baz', '2.0');

  { Safe-name guard. }
  AssertTrue(IsSafeSkillName('my-skill'),  'plain name is safe');
  AssertTrue(IsSafeSkillName('a.b'),       'dot (not "..") is safe');
  AssertTrue(not IsSafeSkillName(''),      'empty rejected');
  AssertTrue(not IsSafeSkillName('..'),    'dot-dot rejected');
  AssertTrue(not IsSafeSkillName('a/b'),   'slash rejected');
  AssertTrue(not IsSafeSkillName('a\b'),   'backslash rejected');
  AssertTrue(not IsSafeSkillName('a:b'),   'colon rejected');
  AssertTrue(not IsSafeSkillName('../x'),  'traversal rejected');

  WriteLn('skills_install_tests: OK');
end.
