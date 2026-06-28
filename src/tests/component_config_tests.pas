program component_config_tests;
(*
  Covers the code-driven configuration surface on TPasClawAgent: an
  embedding app must be able to make every choice `pasclaw onboard` makes
  in code, with no ~/.pasclaw/config.json dependency.

  Contracts pinned:
    - Config is LIVE (non-nil) immediately after Create -- it used to be
      lazily nil until the first Chat, so Agent.Config.X := .. crashed.
    - LoadConfigFromDisk := False starts from clean TConfig defaults
      (no disk read), so the test is hermetic and proves the no-disk path.
    - Mutations to Config persist on the one live object.
    - SetProvider populates providers + default_provider in code.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF FPC}{$IFDEF UNIX}cthreads,{$ENDIF}{$ENDIF}
  SysUtils,
  PasClaw.Config,
  PasClaw.Tools.OutputCache,  { CondenseReversibleEnabled / SetCondenseReversible }
  PasClaw.Agent.Subagent,   { establish TSpawnTool's unit before PasClaw.Agent
                              -- they form a circular interface dep that only
                              resolves cleanly when this compiles first. }
  PasClaw.Agent;

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;

var
  A: TPasClawAgent;
  C: TConfig;
  Eff: TConfig;
begin
  A := TPasClawAgent.Create('claude-opus-4-7');
  try
    { No disk: start from clean defaults so this never touches the dev's
      real config and proves the code-only boot path. }
    A.LoadConfigFromDisk := False;

    { The fix: Config is usable right after Create (was nil pre-first-Chat). }
    C := A.Config;
    AssertTrue(C <> nil, 'Config is live immediately after Create');

    { Clean defaults: the opt-in features are off. }
    AssertTrue(not C.MemoryDistillEnabled, 'default MemoryDistillEnabled = False');
    AssertTrue(not C.OrientTaskAware,       'default OrientTaskAware = False');
    AssertTrue(not C.WebFetchEnabled,       'default WebFetchEnabled = False');

    { Express onboarding choices in code... }
    C.MemoryDistillEnabled := True;
    C.OrientTaskAware      := True;
    C.WebFetchEnabled      := True;

    { ...and confirm they stuck on the same live object Config returns. }
    AssertTrue(A.Config.MemoryDistillEnabled, 'mutation persists: MemoryDistillEnabled');
    AssertTrue(A.Config.OrientTaskAware,       'mutation persists: OrientTaskAware');
    AssertTrue(A.Config.WebFetchEnabled,       'mutation persists: WebFetchEnabled');

    { Provider configured in code (no config.json). }
    A.SetProvider('anthropic', 'sk-ant-test', 'claude-opus-4-7');
    AssertEqStr(A.Config.DefaultProvider, 'anthropic', 'SetProvider sets default_provider');
    AssertTrue(Length(A.Config.Providers) >= 1, 'SetProvider added a provider entry');

    { P1 review: in no-disk mode the OutputCache process-global mirror must
      not drift from Config. LoadConfig syncs it in its finally; the no-disk
      path skips LoadConfig, so ApplyConfigGlobals (run at the component's
      first Chat/Run) must do it. Simulate a stale global left enabled by a
      prior run, then confirm syncing against the default (False) Config
      turns it off -- otherwise tool output would be condensed while Config
      says it shouldn't. }
    SetCondenseReversible(True);
    AssertTrue(not A.Config.CondenseReversible, 'default CondenseReversible = False');
    ApplyConfigGlobals(A.Config);
    AssertTrue(not CondenseReversibleEnabled,
      'ApplyConfigGlobals syncs the condense-reversible global to Config');

    { Active-config override: tool handlers that call LoadEffectiveConfig must
      see the agent's in-memory Config (not disk) once it's published. Set a
      distinctive value, publish, and confirm a fresh effective config carries
      it -- as a COPY (different object the caller can free). }
    A.Config.WebSearch.Provider := 'brave';
    SetActiveConfig(A.Config);
    Eff := LoadEffectiveConfig;
    try
      AssertEqStr(Eff.WebSearch.Provider, 'brave',
        'LoadEffectiveConfig reflects the published in-memory Config');
      AssertTrue(Eff <> A.Config, 'LoadEffectiveConfig returns a copy, not the live object');
    finally
      Eff.Free;
    end;
    { Cleared -> falls back to disk/defaults (default WebSearch is not 'brave'). }
    SetActiveConfig(nil);
    Eff := LoadEffectiveConfig;
    try
      AssertTrue(Eff.WebSearch.Provider <> 'brave',
        'cleared override falls back to LoadConfig (disk/defaults)');
    finally
      Eff.Free;
    end;
  finally
    A.Free;
  end;

  WriteLn('  ok: component code-config (live Config, defaults, globals, active-config override)');
  WriteLn('PASS');
end.
