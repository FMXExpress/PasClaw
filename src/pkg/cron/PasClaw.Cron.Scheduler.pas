(*
  PasClaw.Cron.Scheduler - background thread that walks the configured
  cron entries, fires the next-due job, and sleeps until the next deadline.

  Job = invoke a registered skill (Phase 7's PasClaw.Skills) with the
  configured arguments, capture its output, write it to the memory store
  for the cron session, and optionally post to a channel.

  Lifecycle: Start spins up a TThread that loops; RequestStop sets a flag
  and pulses an event so the loop wakes immediately.
*)
unit PasClaw.Cron.Scheduler;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.Config,
  PasClaw.Tools.Registry;

type
  { Owned-by-the-scheduler-thread copy of the cron entries, so the model's
    cron tool can edit config.json and have new jobs picked up live without
    any cross-thread mutation of the shared TConfig (which the gateway's
    /v1/cron handler also reads). See ReloadCronsIfChanged. }
  TCronEntryArray = array of TCronEntry;

  TCronScheduler = class
  private
    FCfg:      TConfig;
    FRegistry: TToolRegistry;
    FThread:   TThread;
    FStopEvt:  TEvent;
    FStop:     Boolean;
    FState:    TObject;   { TCronState -- opaque to avoid uses-cycle at decl time }
    FCrons:      TCronEntryArray;  { private copy RunOnce iterates }
    FCronsPath:  string;           { config.json path we watch }
    FCronsMtime: TDateTime;        { last-seen config mtime; 0 = unknown }
    procedure ReloadCronsIfChanged;
    procedure RunOnce;
  public
    constructor Create(Cfg: TConfig; Registry: TToolRegistry);
    destructor  Destroy; override;
    procedure Start;
    procedure RequestStop;
    procedure WaitForStop;
  end;

implementation

uses
  DateUtils,
  PasClaw.Logger,
  PasClaw.Cron.Expr,
  PasClaw.Cron.State,
  PasClaw.Cron.Sinks,
  PasClaw.Skills.Loader;

type
  TCronThread = class(TThread)
  private
    FOwner: TCronScheduler;
  protected
    procedure Execute; override;
  public
    constructor Create(Owner: TCronScheduler);
  end;

constructor TCronThread.Create(Owner: TCronScheduler);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := Owner;
end;

procedure TCronThread.Execute;
begin
  while not Terminated do
  begin
    try
      FOwner.RunOnce;
    except
      on E: Exception do
        LogError('cron: scheduler loop error: %s', [E.Message]);
    end;
    { Sleep ~30s between ticks; 1-minute cron granularity tolerates this. }
    if FOwner.FStopEvt.WaitFor(30000) = wrSignaled then Break;
    if FOwner.FStop then Break;
  end;
end;

(* ---- TCronScheduler ---- *)

constructor TCronScheduler.Create(Cfg: TConfig; Registry: TToolRegistry);
var
  State: TCronState;
begin
  inherited Create;
  FCfg      := Cfg;
  FRegistry := Registry;
  FStopEvt  := TEvent.Create(nil, True, False, '');
  State := TCronState.Create(DefaultCronStatePath);
  State.Load;
  FState := State;
  { Seed our private entry list from the startup config, and remember the
    config file's mtime so ReloadCronsIfChanged can pick up later edits
    (the model's cron tool writes config.json). }
  FCrons      := Copy(Cfg.Crons);
  FCronsPath  := GetConfigPath;
  FCronsMtime := 0;
  FileAge(FCronsPath, FCronsMtime);
end;

procedure TCronScheduler.ReloadCronsIfChanged;
{ Cheap mtime poll: when config.json changed since we last loaded it,
  re-read and replace our private FCrons. Runs only on the scheduler
  thread, so FCrons is never touched concurrently -- no lock needed, and
  we never mutate the shared FCfg the gateway also reads. }
var
  Mtime: TDateTime;
  Fresh: TConfig;
begin
  if FCronsPath = '' then Exit;
  Mtime := 0;
  if not FileAge(FCronsPath, Mtime) then Exit;   { file gone -- keep current }
  if (FCronsMtime <> 0) and (Mtime <= FCronsMtime) then Exit;
  Fresh := LoadConfig;
  try
    FCrons := Copy(Fresh.Crons);
    FCronsMtime := Mtime;
    LogInfo('cron: reloaded %d entr(ies) after config change', [Length(FCrons)]);
  finally
    Fresh.Free;
  end;
end;

destructor TCronScheduler.Destroy;
begin
  RequestStop;
  WaitForStop;
  FStopEvt.Free;
  FState.Free;
  inherited Destroy;
end;

procedure TCronScheduler.Start;
begin
  if FThread <> nil then Exit;
  FThread := TCronThread.Create(Self);
  FThread.Start;
  LogInfo('cron: scheduler started (%d entries)', [Length(FCfg.Crons)]);
end;

procedure TCronScheduler.RequestStop;
begin
  FStop := True;
  FStopEvt.SetEvent;
end;

procedure TCronScheduler.WaitForStop;
begin
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
end;

procedure TCronScheduler.RunOnce;
var
  i: Integer;
  Expr: TCronExpr;
  Next, Now_, LookFrom: TDateTime;
  LastFired: Int64;
  ShouldFire, Dirty: Boolean;
  Output, Err: string;
  Entry: TCronEntry;
  State: TCronState;
begin
  Now_  := Now;
  State := TCronState(FState);
  Dirty := False;

  { Pick up any config.json edits (e.g. the model's cron tool) before the
    sweep, so new jobs go live within one tick instead of needing a restart. }
  ReloadCronsIfChanged;

  for i := 0 to High(FCrons) do
  begin
    Entry := FCrons[i];
    if not Entry.Enabled then Continue;
    if not ParseCronExpr(Entry.Spec, Expr) then
    begin
      LogWarn('cron[%s]: invalid expression %s', [Entry.Id, Entry.Spec]);
      Continue;
    end;

    { Compute the next fire time AFTER the last successful run. If
      this cron has never fired, anchor the search on (Now - 60s) so a
      newly-added entry doesn't backfire for every minute of history.
      If a fire was missed (downtime, restart, sleep), NextFireAfter
      returns the earliest missed slot -- we fire exactly once, then
      catch up on the next tick. }
    LastFired := State.GetLastFired(Entry.Id);
    if LastFired > 0 then
      LookFrom := UnixToDateTime(LastFired)
    else
      LookFrom := IncSecond(Now_, -60);

    Next := NextFireAfter(Expr, LookFrom);
    ShouldFire := (Next > 0) and (Next <= Now_);
    if not ShouldFire then Continue;

    LogInfo('cron[%s]: firing skill=%s args=%s',
            [Entry.Id, Entry.Skill, Entry.Args]);
    Output := RunSkill(FRegistry, Entry.Skill, Entry.Args, Err);

    if Err <> '' then
      LogWarn('cron[%s]: skill error: %s', [Entry.Id, Err])
    else
    begin
      if Output <> '' then
        LogInfo('cron[%s]: %s', [Entry.Id, Copy(Output, 1, 200)]);
      AppendCronToDaily(Entry.Id, Entry.Skill, Output);
      if Entry.ChannelKind <> '' then
        PostCronToChannel(Entry.ChannelKind, Entry.ChannelTarget,
          Format('cron[%s] (%s):'#10'%s', [Entry.Id, Entry.Skill, Output]));
    end;

    { Stamp the SLOT we just handled, not Now. Subsequent ticks then
      compute NextFireAfter(slot) which returns the NEXT missed slot
      (or future slot if caught up), so a long downtime catches up
      one slot per tick instead of skipping the rest. Stamp regardless
      of skill success -- a permanently-failing job would otherwise
      retry the same slot on every tick forever; fix the skill and the
      next due slot fires. }
    State.SetLastFired(Entry.Id, DateTimeToUnix(Next));
    Dirty := True;
  end;

  if Dirty then State.Save;
end;

end.
