program orient_preamble_tests;
(*
  Covers BuildOrientPreambleSection -- the opt-in "announce a short plan
  before using tools" instruction that the orient feature adds to the
  system prompt so the agent doesn't silently dive into work.

  Contracts pinned:
    - Off by default (orient off) and for a nil config -> ''
    - On (Cfg.OrientTaskAware) + build mode + tools -> the instruction
    - Suppressed in plan mode (the planner already produces a plan)
    - Suppressed without tools (nothing to preface)
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Agent.Mode,
  PasClaw.Agent.Prompt;

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

function Has(const Hay, Needle: string): Boolean;
begin Result := Pos(Needle, Hay) > 0; end;

var
  Cfg: TConfig;
  S: string;
begin
  { nil config -> empty (no crash). }
  AssertTrue(BuildOrientPreambleSection(nil, True, pmBuild) = '',
    'nil config -> empty');

  Cfg := TConfig.Create;
  try
    { Orient off (the default) -> empty regardless of mode/tools. }
    Cfg.OrientTaskAware := False;
    AssertTrue(BuildOrientPreambleSection(Cfg, True, pmBuild) = '',
      'orient off -> empty');

    { Orient on, build mode, tools -> the instruction is emitted. }
    Cfg.OrientTaskAware := True;
    S := BuildOrientPreambleSection(Cfg, True, pmBuild);
    AssertTrue(S <> '', 'orient on + build + tools -> non-empty');
    AssertTrue(Has(S, 'Before you start'), 'has the heading');
    AssertTrue(Has(S, 'plan'), 'mentions a plan');
    AssertTrue(Has(S, 'before calling any tools') or Has(S, 'BEFORE calling any tools'),
      'tells the model to plan before tools');

    { Plan mode already produces a plan -> suppressed. }
    AssertTrue(BuildOrientPreambleSection(Cfg, True, pmPlan) = '',
      'plan mode -> empty (planner already plans)');

    { No tools -> nothing to preface. }
    AssertTrue(BuildOrientPreambleSection(Cfg, False, pmBuild) = '',
      'no tools -> empty');
  finally
    Cfg.Free;
  end;

  WriteLn('  ok: orient preamble (off/on, plan-mode + no-tools suppression)');
  WriteLn('PASS');
end.
