(*
  `pasclaw heartbeat` -- foreground daemon for the proactive
  periodic wake-up loop. Reads workspace/heartbeat.md every
  Cfg.Heartbeat.IntervalMins minutes and runs the agent on it.

  Usage:
    pasclaw heartbeat              start daemon (interval from config)
    pasclaw heartbeat --once       run a single tick and exit
                                   (useful for cron-from-outside or
                                    smoke-testing the wiring)
    pasclaw heartbeat --interval N override config's interval
    pasclaw heartbeat --content P  override config's content path

  Opt-in: requires Cfg.Heartbeat.Enabled = True or --force, so an
  operator who's never been through `pasclaw onboard` doesn't get
  a quietly-running background model loop they don't know about.

  This is foreground (blocks until Ctrl-C). Embedders that want
  always-on can spin a THeartbeat instance directly. The gateway /
  serve daemons could host it in-process in a follow-up; v1 keeps
  it standalone so the failure modes are easy to reason about.
*)
unit PasClaw.Cmd.Heartbeat;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Heartbeat_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory,
  PasClaw.Tools.Registry,
  PasClaw.Tools.FS,
  PasClaw.Tools.Shell,
  PasClaw.Tools.Memory,
  PasClaw.Tools.SendMessage,
  PasClaw.Tools.OutputCache,
  PasClaw.Tools.Sandbox,    { ConfigureSandbox -- apply the operator's
                              policy before fs_*/shell tools can fire }
  PasClaw.Shell.Backend,         { TShellBackendKind -- needed for the
                                   KindSelected local var }
  PasClaw.Shell.Backend.Factory, { InstallShellBackend }
  PasClaw.Heartbeat;

procedure Help;
begin
  PrintLn('Usage: pasclaw heartbeat [options]');
  PrintLn('');
  PrintLn('  Reads workspace/heartbeat.md every N minutes, runs the agent on it,');
  PrintLn('  and (optionally) posts the result to a named channel.');
  PrintLn('');
  PrintLn('Options:');
  PrintLn('  --once                run a single tick and exit (testing)');
  PrintLn('  --interval N          override config''s interval (minutes)');
  PrintLn('  --content PATH        override config''s content file path');
  PrintLn('  --backend local|docker  override config''s shell_backend for this run');
  PrintLn('  --force               run even when heartbeat.enabled is false in config');
end;

function BuildRegistry: TToolRegistry;
var
  Cfg: TConfig;
begin
  Result := TToolRegistry.Create;
  { Minimal tool set -- the heartbeat prompt is operator-curated, not
    the model picking what to do, so it doesn't need the whole CLI
    surface. fs + shell + memory cover the "check X and report" use
    cases; send_message lets the model post directly. tool_output_get
    rides along so the OR-gate in Cfg honours the CCR default. }
  RegisterFSTools(Result, True);
  RegisterShellTool(Result);
  RegisterMemoryTools(Result);
  RegisterSendMessageTool(Result);
  Cfg := LoadConfig;
  try
    if (Cfg.ToolOutputCap > 0) or Cfg.CondenseReversible then
      RegisterOutputCacheTool(Result);
  finally
    Cfg.Free;
  end;
end;

function Cmd_Heartbeat_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Provider: ILLMProvider;
  Reg: TToolRegistry;
  HB: THeartbeat;
  Once, Force: Boolean;
  IntervalOverride: Integer;
  ContentOverride, Err, ProviderName, Model, BackendOverride: string;
  KindSelected: TShellBackendKind;
  BackendDesc: string;
  i: Integer;
begin
  Once := False;
  BackendOverride := '';
  Force := False;
  IntervalOverride := -1;
  ContentOverride := '';

  i := 0;
  while i <= High(Argv) do
  begin
    if Argv[i] = '--once' then begin Once := True; Inc(i); Continue; end;
    if Argv[i] = '--force' then begin Force := True; Inc(i); Continue; end;
    if (Argv[i] = '--interval') and (i < High(Argv)) then
    begin
      IntervalOverride := StrToIntDef(Argv[i + 1], -1);
      Inc(i, 2); Continue;
    end;
    if (Argv[i] = '--content') and (i < High(Argv)) then
    begin
      ContentOverride := Argv[i + 1];
      Inc(i, 2); Continue;
    end;
    if (Argv[i] = '--backend') and (i < High(Argv)) then
    begin
      BackendOverride := Argv[i + 1];
      Inc(i, 2); Continue;
    end;
    if (Argv[i] = '-h') or (Argv[i] = '--help') then
    begin
      Help;
      Exit(0);
    end;
    Inc(i);
  end;

  Cfg := LoadConfig;
  try
    { Apply the operator's sandbox policy BEFORE any tool can run --
      same call every other entry point (Agent / TUI / Serve /
      Gateway / embedder) makes at startup. PasClaw.Tools.Sandbox
      defaults RestrictToWorkspace to False until configured, so
      skipping this would let a heartbeat prompt fs_write / shell
      outside the workspace regardless of sandbox settings.
      Codex P1 on PR #232. }
    ConfigureSandbox(Cfg.Sandbox, '');
    { Install the shell backend. Each tick starts its own session
      so the docker container is short-lived (matches the
      "ephemeral" tick semantics). --backend override on the
      command line lets the operator pick local for a one-off
      tick without editing config. }
    try
      InstallShellBackend(Cfg, BackendOverride, KindSelected, BackendDesc);
    except
      on E: Exception do
      begin
        PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + E.Message);
        Exit(1);
      end;
    end;
    if not Cfg.Heartbeat.Enabled then
    begin
      if not Force then
      begin
        PrintLn(Ansi.Yellow + '!' + Ansi.Reset +
                ' heartbeat is disabled (Cfg.Heartbeat.Enabled = False).');
        PrintLn('  Enable via ' + Ansi.Bold + 'pasclaw onboard' + Ansi.Reset +
                ' or set heartbeat.enabled = true in config.json,');
        PrintLn('  or pass ' + Ansi.Bold + '--force' + Ansi.Reset +
                ' to run once without persisting the flag.');
        Exit(1);
      end;
      LogWarn('heartbeat: running with --force (heartbeat.enabled is false)');
    end;
    if IntervalOverride > 0 then
      Cfg.Heartbeat.IntervalMins := IntervalOverride;
    if ContentOverride <> '' then
      Cfg.Heartbeat.ContentPath := ContentOverride;

    ProviderName := Cfg.DefaultProvider;
    if ProviderName = '' then
    begin
      PrintLn(Ansi.Red + '✗ ' + Ansi.Reset +
              'no default_provider in config.json -- run `pasclaw onboard` first');
      Exit(1);
    end;
    if not NewProviderFromConfig(Cfg, ProviderName, Provider, Err) then
    begin
      PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + Err);
      Exit(1);
    end;
    Model := Cfg.DefaultModel;

    Reg := BuildRegistry;
    HB  := THeartbeat.Create(Cfg, Provider, Reg, Model);
    try
      if Once then
      begin
        PrintLn(Ansi.Dim + '— heartbeat: one-shot tick —' + Ansi.Reset);
        if HB.TickOnce then
          PrintLn(Ansi.Green + '✓' + Ansi.Reset + ' tick complete')
        else
          PrintLn(Ansi.Yellow + '!' + Ansi.Reset + ' tick skipped or failed (see log)');
        Result := 0;
      end
      else
      begin
        PrintLn(Ansi.Dim + '— heartbeat: daemon mode (Ctrl-C to stop) —' +
                Ansi.Reset);
        HB.Start;
        { Block until the user kills the process. ReadLn returns on
          stdin close (Ctrl-D) too, which is enough for v1 -- the
          deconstructor handles RequestStop + WaitForStop. }
        while not EOF do
        begin
          Sleep(60 * 1000);
        end;
        Result := 0;
      end;
    finally
      HB.Free;
      Reg.Free;
    end;
  finally
    Cfg.Free;
  end;
end;

end.
