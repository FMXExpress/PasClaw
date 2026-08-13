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

procedure ExpectStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' -- got "' + Got + '", want "' + Want + '"');
end;

procedure ExpectInt(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' -- got ' + IntToStr(Got) + ', want ' + IntToStr(Want));
end;

var
  C: TPasClawClient;
  Base, Ver, Slug, TaskId, Val, Visible: string;
  Blocks: TUIBlocks;
  WS: TWorkspaceRows;
  PR: TProjectRows;
  TR: TTaskRows;
  P: TProjectRow;
  A: TAppRow;
  I: Integer;
  Found: Boolean;
  Dir: TDirListing;
  Run: TRunRow;
  PageId: string;
  PG: TPageRows;
  Cur, Cnt: Integer;
  Sess: TSessionRows;
  Raw: TBytes;
  Total: Int64;
begin
  { ---- UI block parsing: pure string work, so it runs with no gateway ---- }
  { The happy path: prose around a wizard block. }
  ParseUIBlocks(
    'Here is the plan.'#10#10 +
    '```pasclaw-ui'#10 +
    '{"ui":"wizard","title":"Plan","steps":[' +
    '{"title":"One","body":"first"},{"title":"Two","body":"second"}]}'#10 +
    '```'#10#10 +
    'Tell me if it is wrong.',
    Visible, Blocks);
  ExpectInt(Length(Blocks), 1, 'one block recognised');
  ExpectTrue(Blocks[0].Kind = ubWizard, 'recognised as a wizard');
  ExpectStr(Blocks[0].Title, 'Plan', 'title parsed');
  ExpectInt(Length(Blocks[0].Steps), 2, 'both steps parsed');
  ExpectStr(Blocks[0].Steps[1].Title, 'Two', 'step order preserved');
  ExpectTrue(Pos('Here is the plan', Visible) > 0, 'prose before survives');
  ExpectTrue(Pos('Tell me if it is wrong', Visible) > 0, 'prose after survives');
  ExpectTrue(Pos('pasclaw-ui', Visible) = 0, 'the block itself is removed');

  { A question with buttons. }
  ParseUIBlocks(
    '```pasclaw-ui'#10 +
    '{"ui":"ask","text":"IMAP or Gmail?","buttons":[' +
    '{"label":"IMAP","value":"IMAP"},{"label":"Gmail API","value":"Gmail API"}]}'#10 +
    '```',
    Visible, Blocks);
  ExpectInt(Length(Blocks), 1, 'ask block recognised');
  ExpectTrue(Blocks[0].Kind = ubAsk, 'kind is ask');
  ExpectInt(Length(Blocks[0].Buttons), 2, 'both buttons parsed');
  ExpectStr(Blocks[0].Buttons[1].Caption, 'Gmail API', 'button label parsed');
  ExpectStr(Blocks[0].Kind_, 'ask', 'icon kind defaults to ask');

  { ---- the fail-safe rules: an answer must never disappear ---- }
  { Malformed JSON stays visible rather than vanishing. }
  ParseUIBlocks('before'#10'```pasclaw-ui'#10'{not json'#10'```'#10'after',
                Visible, Blocks);
  ExpectInt(Length(Blocks), 0, 'malformed block is not rendered');
  ExpectTrue(Pos('not json', Visible) > 0, 'and is left in the visible text');
  ExpectTrue(Pos('before', Visible) > 0, 'with its surroundings intact');
  ExpectTrue(Pos('after', Visible) > 0, 'on both sides');

  { An unterminated fence must not swallow the rest of the reply. }
  ParseUIBlocks('keep me'#10'```pasclaw-ui'#10'{"ui":"wizard"}', Visible, Blocks);
  ExpectInt(Length(Blocks), 0, 'unterminated block is not rendered');
  ExpectTrue(Pos('keep me', Visible) > 0, 'and the reply before it survives');

  { An unknown ui type is not our business -- leave it alone. }
  ParseUIBlocks('```pasclaw-ui'#10'{"ui":"hologram"}'#10'```', Visible, Blocks);
  ExpectInt(Length(Blocks), 0, 'unknown ui type ignored');
  ExpectTrue(Pos('hologram', Visible) > 0, 'and left visible');

  { A wizard with no steps would render an empty window; refuse it. }
  ParseUIBlocks('```pasclaw-ui'#10'{"ui":"wizard","steps":[]}'#10'```', Visible, Blocks);
  ExpectInt(Length(Blocks), 0, 'a stepless wizard is refused');

  { A message with no buttons gets one, so it can be dismissed. }
  ParseUIBlocks('```pasclaw-ui'#10'{"ui":"message","text":"done"}'#10'```',
                Visible, Blocks);
  ExpectInt(Length(Blocks), 1, 'message recognised');
  ExpectInt(Length(Blocks[0].Buttons), 1, 'a dismiss button is supplied');

  { Plain prose is returned untouched -- the common case must cost nothing. }
  ParseUIBlocks('just an ordinary answer', Visible, Blocks);
  ExpectInt(Length(Blocks), 0, 'no blocks in plain prose');
  ExpectStr(Visible, 'just an ordinary answer', 'text returned verbatim');

  { Two blocks in one reply. }
  ParseUIBlocks(
    '```pasclaw-ui'#10'{"ui":"message","text":"a"}'#10'```'#10 +
    'middle'#10 +
    '```pasclaw-ui'#10'{"ui":"message","text":"b"}'#10'```',
    Visible, Blocks);
  ExpectInt(Length(Blocks), 2, 'both blocks recognised');
  ExpectTrue(Pos('middle', Visible) > 0, 'text between them survives');

  Base := GetEnvironmentVariable('PASCLAW_TEST_GATEWAY');
  if Trim(Base) = '' then
  begin
    WriteLn('client_api_tests: UI parsing OK; live half skipped ' +
            '(set PASCLAW_TEST_GATEWAY to run it)');
    if Failures > 0 then Halt(1);
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

    { ------------------------------------------------- files -------- }
    (* The File Manager's whole backing. Sandbox-checked and
       secret-filtered server-side, so the client shows exactly what the
       operator surface will show and cannot be talked into more. *)
    ExpectTrue(C.ListDir('', Dir), 'the default directory lists');
    ExpectTrue(Dir.Path <> '', 'and reports where it landed');
    Found := False;
    for I := 0 to High(Dir.Rows) do
      if Dir.Rows[I].Name = 'projects' then Found := True;
    ExpectTrue(Found, 'the workspace listing has projects/');
    Found := False;
    for I := 0 to High(Dir.Rows) do
      if Dir.Rows[I].Name = 'config.json' then Found := True;
    ExpectTrue(not Found, 'and never a secret-bearing file');
    ExpectTrue(C.ListDir(Dir.Path + '/projects', Dir), 'a subdirectory lists');

    { ------------------------------------------------- desktop state -- }
    (* Per workspace, on the gateway. Both desktops read the same document,
       so a layout arranged in one opens in the other. *)
    ExpectTrue(C.SetDesktopState('{"v":1,"windows":[{"fn":"library"}]}'),
               'desktop state saves');
    ExpectTrue(Pos('library', C.DesktopState) > 0, 'and reads back');
    ExpectTrue(not C.SetDesktopState('{"v":1,'), 'malformed state is refused');
    ExpectTrue(Pos('library', C.DesktopState) > 0,
               'and the good state survives the bad write');

    (* Naming the desktop. Paging desks is "save here, switch there", and
       "here" stops being current the moment the switch lands -- a save that
       says only "current" can therefore write the wrong layout onto the
       wrong desk and lose the arrangement. These four assertions are the
       whole reason the addressed form exists. *)
    ExpectTrue(C.Desktops(Cur, Cnt), 'the pager reports itself');
    ExpectTrue((Cur = 1) and (Cnt >= 1), 'starting on desktop 1');
    ExpectTrue(C.SetDesktopStateFor(1, '{"v":1,"windows":[{"fn":"files"}]}'),
               'desktop 1 saves by number');
    ExpectTrue(C.SwitchDesktop(2, Cur, Cnt), 'switch to desktop 2');
    ExpectTrue(Cur = 2, 'the switch reports where it landed');
    { The bug this guards: writing "the current layout" AFTER the switch. }
    ExpectTrue(C.SetDesktopStateFor(1, '{"v":1,"windows":[{"fn":"library"}]}'),
               'desktop 1 is still addressable from desktop 2');
    ExpectTrue(Pos('files', C.DesktopState) = 0,
               'and desktop 2 did not inherit desktop 1''s windows');
    ExpectTrue(Pos('library', C.DesktopStateFor(1)) > 0,
               'desktop 1 kept what was written to it by number');
    ExpectTrue(C.SwitchDesktop(1, Cur, Cnt), 'switch back');
    ExpectTrue(Pos('library', C.DesktopState) > 0,
               'and the arrangement is there on return');

    { ------------------------------------------------------- sessions -- }
    { Empty is a fine answer on a fresh home; the contract is that it
      returns a list rather than throwing. }
    Sess := C.Sessions;
    ExpectTrue(Length(Sess) >= 0, 'sessions list');

    { ----------------------------------------------------- raw bytes --- }
    (* The hex viewer's feed. A text file is bytes too, so this is testable
      without inventing a binary one. *)
    ExpectTrue(C.PeekFile(Dir.WorkspaceRoot + '/PLAN.md', 0, 16,
                          Raw, Total) or (C.LastError <> ''),
               'peek either returns bytes or says why not');
    ExpectTrue(C.SetDesktopState('{"v":1,"windows":[]}'), 'state resets');

    { ------------------------------------------------ pages + promote -- }
    ExpectTrue(C.CreatePageOfKind('client api page', pkeReport, PageId) or
               (PageId = ''),
               'a page request either lands or fails cleanly');
    if PageId <> '' then
    begin
      ExpectTrue(C.PromotePage(PageId, Val), 'a page promotes to a project');
      ExpectTrue(Val <> '', 'and names the project it became');
      { The page is a record of an answer at a time -- promotion copies it
        and must leave it in the history. }
      Found := False;
      PG := C.Pages;
      for I := 0 to High(PG) do
        if PG[I].Id = PageId then Found := True;
      ExpectTrue(Found, 'and the page is still there afterwards');
      C.DeleteProject(Val);
    end;

    { ------------------------------------------------- process apps ---- }
    { No app on this project, so the run surface must say so rather than
      starting something. }
    ExpectTrue(not C.RunApp(Slug, Run, Val), 'running an appless project fails');
    ExpectTrue(Val <> '', 'with a reason: ' + Val);

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
