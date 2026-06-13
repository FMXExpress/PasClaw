program config_env_subst_tests;
(*
  Pins PasClaw.Config.ExpandEnvVarsInJSON contract:

    - Pattern matches openclaw's ${[A-Z_][A-Z0-9_]*} exactly.
    - Set env var: spliced in, JSON-escaping any "/\\/control bytes
      so the result stays valid JSON regardless of value contents.
    - Unset (or set-but-empty) env: literal ${VAR_NAME} left in
      place so an operator reading config back can SEE which marker
      didn't resolve.
    - Lowercase names DON'T match (case-sensitive per openclaw).
    - First char must be A-Z or _; subsequent allow 0-9 too.
    - Malformed markers (missing }, empty name, dollar without {)
      preserved verbatim -- a regex pattern in some config value
      that happens to contain `$` doesn't get eaten.
    - Substitution is positional (raw text), so anywhere the marker
      appears it expands; inside string values is the canonical
      use case but the function doesn't enforce that itself.

  Some assertions require the env var to actually be set in the
  parent process (FPC's RTL snapshots envp at startup). The
  Makefile invokes this binary in two passes: clean env for the
  in-process control assertions, and a second pass with a fixture
  env var for the actual expansion path -- same shape otel_tests
  and gateway_token_tests use.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Config;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEq(const A, B, Msg: string);
begin
  if A <> B then
    Fail_(Msg + ' (expected "' + B + '" got "' + A + '")');
end;

procedure TestUnsetEnvLeavesLiteral;
const
  Name = 'PASCLAW_TEST_DEFINITELY_UNSET_VAR_a4f9';
begin
  AssertEq(GetEnvironmentVariable(Name), '',
           'precondition: this env var is genuinely unset');
  AssertEq(ExpandEnvVarsInJSON('{"k":"${' + Name + '}"}'),
           '{"k":"${' + Name + '}"}',
           'unset env: literal ${VAR_NAME} preserved so operator can diagnose');
end;

procedure TestNoMarkersIsIdentity;
begin
  AssertEq(ExpandEnvVarsInJSON(''), '',
           'empty input -> empty output');
  AssertEq(ExpandEnvVarsInJSON('{"key":"plain string"}'),
           '{"key":"plain string"}',
           'no markers -> identity');
  AssertEq(ExpandEnvVarsInJSON('{"k":"contains $ literal"}'),
           '{"k":"contains $ literal"}',
           'lone $ not followed by { -> identity');
  AssertEq(ExpandEnvVarsInJSON('{"k":"${ }"}'),
           '{"k":"${ }"}',
           'malformed marker (space inside) -> preserved');
  AssertEq(ExpandEnvVarsInJSON('{"k":"${UNCLOSED_VAR"}'),
           '{"k":"${UNCLOSED_VAR"}',
           'missing closing brace -> preserved');
end;

procedure TestCaseSensitiveAndCharsetRules;
const
  Lower = 'pasclaw_lower_should_not_match_a4f9';
  Mixed = 'PasClaw_Mixed_Case_Should_Not_Match_a4f9';
begin
  AssertEq(ExpandEnvVarsInJSON('{"k":"${' + Lower + '}"}'),
           '{"k":"${' + Lower + '}"}',
           'lowercase name does NOT match (uppercase-only per openclaw)');
  AssertEq(ExpandEnvVarsInJSON('{"k":"${' + Mixed + '}"}'),
           '{"k":"${' + Mixed + '}"}',
           'mixed-case name does NOT match (first char lowercase fails the rule)');
  AssertEq(ExpandEnvVarsInJSON('{"k":"${1STARTS_WITH_DIGIT}"}'),
           '{"k":"${1STARTS_WITH_DIGIT}"}',
           'name starting with digit does NOT match (first char must be A-Z or _)');
  AssertEq(ExpandEnvVarsInJSON('{"k":"${WITH-DASH}"}'),
           '{"k":"${WITH-DASH}"}',
           'name containing - does NOT match (- not in [A-Z0-9_])');
end;

procedure TestEnvModeSubstitution;
(* --env-mode pass. Makefile sets PASCLAW_CONFIG_TEST_VAR_A4F9 to a
   known value before launch so we can observe the actual splicing
   behaviour through GetEnvironmentVariable (which sees envp the
   process started with). *)
const
  Name     = 'PASCLAW_CONFIG_TEST_VAR_A4F9';
  Expected = 'hello-from-env-aaaaaaaa';
begin
  AssertEq(GetEnvironmentVariable(Name), Expected,
           'precondition: Makefile set the fixture env var to the expected value');
  AssertEq(ExpandEnvVarsInJSON('{"k":"${' + Name + '}"}'),
           '{"k":"hello-from-env-aaaaaaaa"}',
           'simple substitution: ${VAR} -> value');
  AssertEq(ExpandEnvVarsInJSON('{"k":"prefix-${' + Name + '}-suffix"}'),
           '{"k":"prefix-hello-from-env-aaaaaaaa-suffix"}',
           'mid-string substitution: prefix-${VAR}-suffix');
  AssertEq(ExpandEnvVarsInJSON('{"a":"${' + Name + '}","b":"${' + Name + '}"}'),
           '{"a":"hello-from-env-aaaaaaaa","b":"hello-from-env-aaaaaaaa"}',
           'multiple occurrences in same body each expand');
  AssertEq(ExpandEnvVarsInJSON('{"deep":{"nested":{"k":"${' + Name + '}"}}}'),
           '{"deep":{"nested":{"k":"hello-from-env-aaaaaaaa"}}}',
           'works inside nested objects (raw-text substitution doesn''t care about depth)');
end;

procedure TestEnvModeJsonEscaping;
(* --env-mode pass continued. Makefile sets
   PASCLAW_CONFIG_TRICKY_VAR_A4F9 to `hello"world\backslash` (single-
   quoted in the shell so the " and \ stay literal). After splicing
   we expect the JSON body to be `{"k":"hello\"world\\backslash"}`
   -- the `"` escapes to `\"` and the `\` escapes to `\\`. *)
const
  Name = 'PASCLAW_CONFIG_TRICKY_VAR_A4F9';
  { Pascal string literals do NOT interpret backslash sequences, so
    every \ below is a literal backslash byte and every " inside
    the single-quoted string is a literal quote. }
  ExpectedEscaped = 'hello\"world\\backslash';
var
  Got: string;
begin
  AssertTrue(GetEnvironmentVariable(Name) <> '',
             'precondition: tricky env var inherited from Makefile');
  Got := ExpandEnvVarsInJSON('{"k":"${' + Name + '}"}');
  AssertEq(Got, '{"k":"' + ExpectedEscaped + '"}',
           'JSON-special bytes in env value get escaped (\" and \\)');
end;

procedure TestRoundTripWithEmptyConfig;
(* TConfig.FromJSON(ExpandEnvVarsInJSON(empty-with-markers)) must
   not crash. An unset marker leaves the literal ${VAR} in the
   string field, which FromJSON treats as a normal string. *)
var
  Cfg: TConfig;
begin
  Cfg := TConfig.Create;
  try
    Cfg.FromJSON(ExpandEnvVarsInJSON(
      '{"providers":[{"name":"anthropic","api_key":"${UNRELATED_UNSET_VAR_a4f9}"}]}'));
    AssertTrue(Length(Cfg.Providers) = 1,
               'unresolved marker still parses as a string field; providers[0] exists');
    AssertEq(Cfg.Providers[0].APIKey,
             '${UNRELATED_UNSET_VAR_a4f9}',
             'unresolved marker stays in the string verbatim');
  finally
    Cfg.Free;
  end;
end;

begin
  if (ParamCount >= 1) and (ParamStr(1) = '--env-mode') then
  begin
    TestEnvModeSubstitution;
    WriteLn('  ok: env-mode -- ${VAR} expands inside string values (simple, mid-string, multiple, nested)');
    TestEnvModeJsonEscaping;
    WriteLn('  ok: env-mode -- JSON-special bytes in env values get escaped so the body stays valid JSON');
    WriteLn('PASS');
    Exit;
  end;

  TestUnsetEnvLeavesLiteral;
  WriteLn('  ok: unset env: literal ${VAR_NAME} preserved (operator can diagnose by reading config back)');
  TestNoMarkersIsIdentity;
  WriteLn('  ok: no markers / malformed markers: input passes through verbatim');
  TestCaseSensitiveAndCharsetRules;
  WriteLn('  ok: pattern is ${[A-Z_][A-Z0-9_]*} (case-sensitive, no -, no digit-first)');
  TestRoundTripWithEmptyConfig;
  WriteLn('  ok: TConfig.FromJSON tolerates unresolved markers as plain string values');
  WriteLn('PASS');
end.
