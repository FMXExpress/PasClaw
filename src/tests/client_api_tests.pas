program client_api_tests;
(*
  Exercises PasClaw.Client.Api against a LIVE gateway -- the shared client the
  FireMonkey desktop (desktop/) and Studio drive the gateway through. Point it
  at a running server:

    PASCLAW_TEST_GATEWAY=http://127.0.0.1:8088 build/client_api_tests

  Skips (exit 0) when that variable is unset, so `make test` on a machine with
  no gateway running stays green. The FMX client itself needs Delphi and is
  not compiled here; this covers the half of it that isn't UI.
*)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  {$IFDEF FPC}{$IFDEF UNIX}
  cthreads,   { Indy uses TThread; FPC/Linux needs the pthreads driver first }
  {$ENDIF}{$ENDIF}
  SysUtils, PasClaw.Client.Api;

var Failures: Integer = 0;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Inc(Failures);
end;

procedure ExpectTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

var
  C: TPasClawClient;
  Base, Ver, Slug, TaskId, Val: string;
  WS: TWorkspaceRows;
  PR: TProjectRows;
  TR: TTaskRows;
  P: TProjectRow;
  A: TAppRow;
  I: Integer;
  Found: Boolean;
begin
  Base := GetEnvironmentVariable('PASCLAW_TEST_GATEWAY');
  if Trim(Base) = '' then
  begin
    WriteLn('client_api_tests: skipped (set PASCLAW_TEST_GATEWAY to run)');
    Halt(0);
  end;

  C := TPasClawClient.Create(Base);
  try
    ExpectTrue(C.Ping(Ver), 'gateway reachable at ' + Base);

    WS := C.Workspaces;
    ExpectTrue(Length(WS) >= 1, 'at least one workspace');
    Found := False;
    for I := 0 to High(WS) do
      if WS[I].Active then Found := True;
    ExpectTrue(Found, 'one workspace is active');

    Slug := C.CreateProject('Client Api Test');
    ExpectTrue(Slug = 'client-api-test', 'project created with the expected slug');

    PR := C.Projects;
    Found := False;
    for I := 0 to High(PR) do
      if PR[I].Name = Slug then Found := True;
    ExpectTrue(Found, 'project appears in the list');

    ExpectTrue(C.Project(Slug, P), 'project loads individually');
    ExpectTrue(P.Title = 'Client Api Test', 'title round-trips');

    TaskId := C.CreateTask(Slug, 'Do the thing');
    ExpectTrue(TaskId = 'T0001', 'task created');
    TR := C.Tasks(Slug);
    ExpectTrue((Length(TR) = 1) and (TR[0].Title = 'Do the thing'), 'task listed');
    ExpectTrue(C.UpdateTaskStatus(Slug, TaskId, 'active'), 'task status updated');
    TR := C.Tasks(Slug);
    ExpectTrue((Length(TR) = 1) and (TR[0].Status = 'active'), 'status persisted');

    ExpectTrue(C.App(Slug, A), 'app manifest reads');
    ExpectTrue(not A.Exists, 'a fresh project has no app');

    ExpectTrue(C.StateSet(Slug, 'k', 'hello'), 'state set');
    ExpectTrue(C.StateGet(Slug, 'k', Val) and (Val = 'hello'), 'state round-trips');
    ExpectTrue(not C.StateGet(Slug, 'nope', Val), 'unset key reports missing');

    ExpectTrue(C.AppURL(Slug) = Base + '/apps/' + Slug + '/', 'app URL composed');
    ExpectTrue(C.PageURL('P0001') = Base + '/pages/P0001/', 'page URL composed');

    ExpectTrue(C.DeleteProject(Slug), 'project deleted');
    ExpectTrue(not C.Project(Slug, P), 'deleted project is gone');
  finally
    C.Free;
  end;

  if Failures = 0 then
    WriteLn('client_api_tests: OK')
  else
  begin
    WriteLn('client_api_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
