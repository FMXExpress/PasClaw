program loop_shaping_defaults_tests;
(*
  Verifies the loop-shaping config defaults AND that round-tripping
  through ToJSON/FromJSON honours explicit opt-outs (and opt-ins for the
  default-off knobs).

  Current defaults under test (PR #289 flipped vault/web ON; PR #314
  reverted them to OFF -- "stock = lean-edit, opt in via onboarding" --
  and the orient-CLI PR keeps orient OFF, CLI-only via --orient):
    VaultToolsEnabled     False   (off; onboarding/--? opt-in)
    WebFetchEnabled       True    (on; description documents strip + cap)
    CondenseReversible    False   (off since PR #289)
    PromptwareEnabled     True
    VectorSearchEnabled   True
    RenderMarkdown        True
    ToolOutputCap         0
    OrientTaskAware       False   (off; opt in per-run with --orient)
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.JSON,
  PasClaw.Config,
  PasClaw.Tools.OutputCache;    { CondenseReversibleEnabled / SetCondenseReversible }

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure TestFreshDefaults;
var C: TConfig;
begin
  C := TConfig.Create;
  try
    AssertTrue(not C.VaultToolsEnabled, 'VaultToolsEnabled defaults to False');
    AssertTrue(C.WebFetchEnabled,       'WebFetchEnabled defaults to True');
    AssertTrue(not C.CondenseReversible,'CondenseReversible defaults to False');
    AssertTrue(C.PromptwareEnabled,     'PromptwareEnabled stays True');
    AssertTrue(C.VectorSearchEnabled,   'VectorSearchEnabled stays True');
    AssertTrue(C.RenderMarkdown,        'RenderMarkdown stays True');
    AssertTrue(C.ToolOutputCap = 0,     'ToolOutputCap stays 0');
    AssertTrue(not C.OrientTaskAware,   'OrientTaskAware stays False');
    AssertTrue(not C.SelfImprovingSkills.SelfManage,
               'SelfImprovingSkills.SelfManage stays False');
  finally
    C.Free;
  end;
end;

procedure TestEmittedFieldsAreTidy;
var
  C: TConfig;
  S: string;
begin
  { A fresh config (every flag at its new default) should NOT emit the
    flipped keys. Same posture as render_markdown / vector_search:
    "default value, no need to spell it out". }
  C := TConfig.Create;
  try
    S := C.ToJSON;
    AssertTrue(Pos('vault_tools_enabled', S) = 0, 'fresh ToJSON omits vault_tools_enabled');
    AssertTrue(Pos('web_fetch_enabled',   S) = 0, 'fresh ToJSON omits web_fetch_enabled');
    AssertTrue(Pos('condense_reversible', S) = 0, 'fresh ToJSON omits condense_reversible');
    AssertTrue(Pos('promptware_enabled',  S) = 0, 'fresh ToJSON omits promptware_enabled');
    AssertTrue(Pos('vector_search_enabled', S) = 0, 'fresh ToJSON omits vector_search_enabled');
    AssertTrue(Pos('render_markdown',     S) = 0, 'fresh ToJSON omits render_markdown');
    AssertTrue(Pos('tool_output_cap',     S) = 0, 'fresh ToJSON omits tool_output_cap');
    AssertTrue(Pos('orient_task_aware',   S) = 0, 'fresh ToJSON omits orient_task_aware');
  finally
    C.Free;
  end;
end;

procedure TestExplicitOptOutRoundTrip;
var
  C, C2: TConfig;
  S: string;
begin
  { Operator-opted-out of every now-default-on flag, and opted IN to
    every now-default-off flag. Every field should serialise AND
    round-trip back as set. }
  C := TConfig.Create;
  try
    C.VaultToolsEnabled  := True;   { default False -> opt-in }
    C.WebFetchEnabled    := False;  { default True  -> opt-out }
    C.PromptwareEnabled  := False;
    C.VectorSearchEnabled := False;
    C.RenderMarkdown     := False;
    C.CondenseReversible := True;
    C.OrientTaskAware    := True;
    C.ToolOutputCap      := 8192;
    S := C.ToJSON;
    { Each non-default field must be present in the serialised form,
      otherwise LoadConfig would silently fall back to the default. }
    AssertTrue(Pos('"vault_tools_enabled"',   S) > 0, 'opt-in vault_tools_enabled emitted');
    AssertTrue(Pos('"web_fetch_enabled"',     S) > 0, 'opt-out web_fetch_enabled emitted');
    AssertTrue(Pos('"promptware_enabled"',    S) > 0, 'opt-out promptware_enabled emitted');
    AssertTrue(Pos('"vector_search_enabled"', S) > 0, 'opt-out vector_search_enabled emitted');
    AssertTrue(Pos('"render_markdown"',       S) > 0, 'opt-out render_markdown emitted');
    AssertTrue(Pos('"condense_reversible"',   S) > 0, 'opt-in condense_reversible emitted');
    AssertTrue(Pos('"orient_task_aware"',     S) > 0, 'opt-in orient_task_aware emitted');
    AssertTrue(Pos('"tool_output_cap"',       S) > 0, 'opt-in tool_output_cap emitted');
  finally
    C.Free;
  end;

  C2 := TConfig.Create;
  try
    C2.FromJSON(S);
    AssertTrue(C2.VaultToolsEnabled,        'VaultToolsEnabled round-trips True');
    AssertTrue(not C2.WebFetchEnabled,      'WebFetchEnabled round-trips False');
    AssertTrue(not C2.PromptwareEnabled,    'PromptwareEnabled round-trips False');
    AssertTrue(not C2.VectorSearchEnabled,  'VectorSearchEnabled round-trips False');
    AssertTrue(not C2.RenderMarkdown,       'RenderMarkdown round-trips False');
    AssertTrue(C2.CondenseReversible,       'CondenseReversible round-trips True');
    AssertTrue(C2.OrientTaskAware,          'OrientTaskAware round-trips True');
    AssertTrue(C2.ToolOutputCap = 8192,     'ToolOutputCap round-trips 8192');
  finally
    C2.Free;
  end;
end;

(* Codex PR #289 P1: when CondenseReversibleEnabled is False, BOTH the
   stash footer AND the upstream condensers (ApplyShellFilter in
   Tools.Shell, MaybeCondenseJSON in Tools.ToolLoop) must no-op. The
   propagation contract being tested here is that the module-level
   gate getter tracks SetCondenseReversible, which the LoadConfig
   path propagates from Cfg.CondenseReversible. The dispatch-site
   gating itself is exercised by test-condense-reversible. *)
procedure TestCondenseGatePropagation;
begin
  SetCondenseReversible(True);
  AssertTrue(CondenseReversibleEnabled, 'gate flips on');
  SetCondenseReversible(False);
  AssertTrue(not CondenseReversibleEnabled, 'gate flips off -- shell/json condensers must skip when this is False');
  { Restore so a later test in the same process isn't surprised. }
  SetCondenseReversible(False);
end;

begin
  TestFreshDefaults;
  TestEmittedFieldsAreTidy;
  TestExplicitOptOutRoundTrip;
  TestCondenseGatePropagation;
  WriteLn('ok - loop-shaping defaults tests passed');
end.
