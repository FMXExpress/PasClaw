program cancelprobe;
(*
  Proves the desktop event-stream cancel reaches the socket.

  This is the bug that made closing PasClaw Desktop nearly impossible.
  WatchEvents blocks in an HTTP GET with no read timeout; Terminate sets a
  flag the thread only checks between reconnects, and the callback's Stop
  flag is only consulted when a real `data:` event arrives -- a keepalive is
  a comment line and gets dropped before the callback sees it. So on an idle
  board, joining that thread waits for something to happen on the gateway,
  which may be never.

  Measured before the fix: still waiting 45 seconds after Terminate, against
  a gateway that was up and healthy the whole time. After: 101ms.

  NOT part of `make test`, and deliberately so: it needs a LIVE gateway on a
  real port, and the default suite runs in-process. Two commands:

    PASCLAW_HOME=build/probe-home build/pasclaw gateway --port 8231 &
    build/cancelprobe http://127.0.0.1:8231

  Build it the way the other tests are built -- same FPC flags, see the
  test-* targets in the Makefile.
*)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
uses
  {$IFDEF FPC}{$IFDEF UNIX}cthreads,{$ENDIF}{$ENDIF}
  SysUtils, Classes, DateUtils,
  PasClaw.Client.Api;

type
  TWatch = class(TThread)
  private
    FC: TPasClawClient;
  protected
    procedure Execute; override;
  public
    Returned: Boolean;
    constructor Create(AC: TPasClawClient);
    procedure OnEv(const Ev: TDesktopEvent; var Stop: Boolean);
  end;

constructor TWatch.Create(AC: TPasClawClient);
begin
  inherited Create(True);
  FC := AC;
  FreeOnTerminate := False;
  Returned := False;
end;

procedure TWatch.OnEv(const Ev: TDesktopEvent; var Stop: Boolean);
begin
  Stop := Terminated;
end;

procedure TWatch.Execute;
begin
  FC.WatchEvents(OnEv);
  Returned := True;
end;

var
  C: TPasClawClient;
  W: TWatch;
  T0: TDateTime;
  Ms: Integer;
  Ver: string;
begin
  C := TPasClawClient.Create(ParamStr(1));
  try
    if not C.Ping(Ver) then
    begin
      WriteLn('no gateway at ', ParamStr(1));
      Halt(2);
    end;
    W := TWatch.Create(C);
    try
      W.Start;
      { Let the stream establish and park. }
      Sleep(1500);
      if W.Returned then
      begin
        WriteLn('FAIL: the watcher returned before it was cancelled');
        Halt(1);
      end;
      T0 := Now;
      W.Terminate;
      C.CancelEvents;
      W.WaitFor;
      Ms := MilliSecondsBetween(Now, T0);
      WriteLn('joined in ', Ms, 'ms');
      if Ms > 2000 then
      begin
        WriteLn('FAIL: the join took ', Ms, 'ms -- cancel did not reach the socket');
        Halt(1);
      end;
      WriteLn('OK');
    finally
      W.Free;
    end;
  finally
    C.Free;
  end;
end.
