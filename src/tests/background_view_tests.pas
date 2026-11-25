program background_view_tests;
(*
  The background-work view: PasClaw.Agent.SubagentBg's listing, history
  and follow-ups, and PasClaw.Gateway.Background's /v1/background JSON.

    - the listing JSON: every field a viewer needs, running jobs first and
      then the newest, previews cut on a character boundary; a job's detail
      carries its transcript (with the answer) or its output; the routes'
      statuses for unknown handles and wrong verbs;
    - retention: a coordinator keeps BackgroundHistoryMax finished jobs,
      dropping first those whose result already reached the model, then
      the oldest -- before this the list grew for the life of a gateway;
    - follow-ups: a message to a finished subagent starts a linked job whose
      model is sent the earlier conversation and then the message, under the
      same system prompt; refused for a shell job, a running job, an empty
      message and an unknown handle;
    - BoundTranscript: the caps hold, the first message stays, no tool
      result is left leading without its call, big arguments stay JSON.

  A fake provider echoes the last user message, and blocks on a task that
  starts with BLOCK until the test lets it go. No network, no model.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, DateUtils,
  PasClaw.Config,
  PasClaw.JSON,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.ToolLoop,
  PasClaw.Agent.Subagent,
  PasClaw.Agent.SubagentBg,
  PasClaw.Gateway.Background;

var
  GSeenLock: TCriticalSection;
  GSeen: TMessageArray;            { the last request's messages }
  GSeenSystem: string;
  GRelease: TEvent;                { lets a BLOCK task answer }

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEq(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' + Copy(Want, 1, 200) + '")');
end;

procedure AssertContains(const Hay, Needle, Msg: string);
begin
  if Pos(Needle, Hay) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing from "' + Copy(Hay, 1, 300) + '")');
end;

type
  TFakeProvider = class(TInterfacedObject, ILLMProvider)
  public
    function Chat(const Messages: array of TMessage;
                  const Tools:    array of TToolDefinition;
                  const Model:    string;
                  const Options:  TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

function TFakeProvider.Chat(const Messages: array of TMessage;
                            const Tools:    array of TToolDefinition;
                            const Model:    string;
                            const Options:  TChatOptions): TLLMResponse;
var
  i: Integer;
  UserText, First: string;
begin
  Result := Default(TLLMResponse);
  UserText := '';
  First := '';
  GSeenLock.Enter;
  try
    SetLength(GSeen, Length(Messages));
    for i := 0 to High(Messages) do GSeen[i] := Messages[i];
    GSeenSystem := Options.SystemPrompt;
  finally
    GSeenLock.Leave;
  end;
  for i := High(Messages) downto 0 do
    if Messages[i].Role = mrUser then
    begin
      UserText := StripTurnClock(Messages[i].Content);
      Break;
    end;
  for i := 0 to High(Messages) do
    if Messages[i].Role = mrUser then
    begin
      First := Messages[i].Content;
      Break;
    end;
  if Copy(First, 1, 5) = 'BLOCK' then GRelease.WaitFor(30000);
  Result.Content      := 'ECHO[' + UserText + ']';
  Result.FinishReason := 'stop';
  Result.StatusCode   := 200;
end;

function TFakeProvider.ChatStream(const Messages: array of TMessage;
                                  const Tools:    array of TToolDefinition;
                                  const Model:    string;
                                  const Options:  TChatOptions;
                                  OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

function TFakeProvider.GetDefaultModel: string; begin Result := 'fake'; end;
function TFakeProvider.GetName: string;         begin Result := 'fake'; end;
function TFakeProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TFakeProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TFakeProvider.SupportsStreaming: Boolean;    begin Result := False; end;

function MakeSpecs: TSubagentSpecArray;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0].Name         := 'researcher';
  Result[0].Description  := 'pretend research';
  Result[0].SystemPrompt := 'you are research';
  SetLength(Result[0].Tools, 0);
  Result[0].Model        := '';
  Result[0].MaxIter      := 2;
end;

function MakeCtx(const Provider: ILLMProvider; Reg: TToolRegistry): TSubagentContext;
begin
  Result := Default(TSubagentContext);
  Result.Provider       := Provider;
  Result.ParentRegistry := Reg;
  Result.DefaultModel   := 'fake';
  Result.PromptCache    := Default(TPromptCacheConfig);
end;

function ExtractHandle(const Body: string): string;
var
  P, Q: Integer;
begin
  Result := '';
  P := Pos('handle=', Body);
  if P = 0 then Exit;
  P := P + Length('handle=');
  Q := P;
  while (Q <= Length(Body)) and (Body[Q] in ['0'..'9', 'a'..'z', '-']) do Inc(Q);
  Result := Copy(Body, P, Q - P);
end;

procedure WaitDone(Coord: TBackgroundSpawnCoordinator; const Handle: string);
var
  Deadline: TDateTime;
  Err, S: string;
begin
  Deadline := IncSecond(Now, 10);
  repeat
    S := Coord.HandleStatus('{"handle":"' + Handle + '"}', Err);
    if (Pos('state=done', S) > 0) or (Pos('state=failed', S) > 0) or
       (Pos('state=cancelled', S) > 0) then Exit;
    Sleep(20);
  until Now >= Deadline;
  Fail_('job ' + Handle + ' never finished: ' + S + Err);
end;

function Present(Coord: TBackgroundSpawnCoordinator; const Handle: string): Boolean;
var
  Info: TBgJobInfo;
begin
  Result := Coord.GetInfo(Handle, Info);
end;

function FindJobObj(Jobs: TJsonArray; const Handle: string): TJsonObject;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to Jobs.Count - 1 do
    if Jobs.ItemObject(i).GetStr('handle') = Handle then Exit(Jobs.ItemObject(i));
end;

function Route(const Method, Doc, Body: string; out Status: Integer): TJsonObject;
var
  J: string;
begin
  if not HandleBackgroundRoute(Method, Doc, Body, Status, J) then
    Fail_(Doc + ' is not taken as a background route');
  Result := TJsonObject.Parse(J);
  AssertTrue(Result <> nil, Doc + ' answers JSON: ' + Copy(J, 1, 200));
end;

{ ------------------------------------------------------------------ }

procedure TestListingJSON(Coord: TBackgroundSpawnCoordinator);
var
  Out_, Err, HSub, HLong, HShell, HSleep, J, LongPrompt, Pv: string;
  Root, O, D: TJsonObject;
  Jobs, Msgs: TJsonArray;
  St, i: Integer;
  Info: TBgJobInfo;
begin
  Out_ := Coord.HandleSpawnBackground('{"agent":"researcher","prompt":"summarise the frobnicator"}', Err);
  AssertEq(Err, '', 'subagent spawns');
  HSub := ExtractHandle(Out_);
  WaitDone(Coord, HSub);
  { 199 ASCII characters then a two-byte one: a byte cut at 200 would split it. }
  LongPrompt := StringOfChar('x', 199) + #$C3#$A9 + ' and more';
  Out_ := Coord.HandleSpawnBackground('{"agent":"researcher","prompt":"' + LongPrompt + '"}', Err);
  HLong := ExtractHandle(Out_);
  WaitDone(Coord, HLong);
  Out_ := Coord.HandleShellBackground('{"command":"echo listing-shell-out"}', Err);
  AssertEq(Err, '', 'shell spawns');
  HShell := ExtractHandle(Out_);
  WaitDone(Coord, HShell);
  Sleep(1100);   { a later start second than the finished ones }
  Out_ := Coord.HandleShellBackground('{"command":"sleep 20"}', Err);
  HSleep := ExtractHandle(Out_);

  Root := Route('GET', '/v1/background', '', St);
  try
    AssertTrue(St = 200, 'list is 200');
    Jobs := Root.ChildArray('jobs');
    AssertTrue((Jobs <> nil) and (Jobs.Count >= 4), 'four jobs listed');
    AssertEq(Jobs.ItemObject(0).GetStr('handle'), HSleep, 'the running job comes first');
    AssertTrue(Root.GetInt('running') >= 1, 'running count');
    AssertTrue(Root.GetInt('history_max') = BackgroundHistoryMax, 'history cap reported');
    AssertEq(Root.GetStr('cron'), '/v1/cron', 'scheduled work is pointed at, not repeated');
    { newest first among the finished: shell, then the long one, then the first }
    AssertTrue(Jobs.ItemObject(1).GetInt('started_at') >= Jobs.ItemObject(Jobs.Count - 1).GetInt('started_at'),
               'finished jobs newest first');

    O := FindJobObj(Jobs, HSub);
    AssertTrue(O <> nil, 'subagent job listed');
    AssertEq(O.GetStr('kind'), 'subagent', 'kind');
    AssertEq(O.GetStr('agent'), 'researcher', 'agent');
    AssertEq(O.GetStr('prompt'), 'summarise the frobnicator', 'prompt');
    AssertEq(O.GetStr('state'), 'done', 'state');
    AssertTrue(O.GetInt('started_at') > 1700000000, 'start time is unix seconds');
    AssertTrue(O.GetInt('finished_at') >= O.GetInt('started_at'), 'finish time');
    AssertTrue(O.Has('elapsed_sec'), 'elapsed');
    AssertTrue(O.Has('session'), 'session');
    AssertContains(O.GetStr('result_preview'), 'ECHO[summarise the frobnicator]', 'result preview');
    AssertTrue(O.GetBool('can_message') and not O.GetBool('can_cancel'), 'finished subagent flags');

    O := FindJobObj(Jobs, HLong);
    Pv := O.GetStr('prompt');
    AssertTrue(Length(Pv) <= 203, 'prompt preview capped: ' + IntToStr(Length(Pv)));
    AssertTrue(Copy(Pv, Length(Pv) - 2, 3) = '...', 'a cut preview says so');
    AssertTrue(Pos(#$C3'.', Pv) = 0, 'the cut does not split the two-byte character');

    O := FindJobObj(Jobs, HShell);
    AssertEq(O.GetStr('kind'), 'shell', 'shell kind');
    AssertEq(O.GetStr('command'), 'echo listing-shell-out', 'shell command');
    AssertTrue(O.GetInt('exit_code', -1) = 0, 'shell exit code');

    O := FindJobObj(Jobs, HSleep);
    AssertEq(O.GetStr('state'), 'running', 'sleep is running');
    AssertTrue(O.GetBool('can_cancel') and not O.GetBool('can_message'), 'running flags');
    J := StringReplace(O.ToJSON, ' ', '', [rfReplaceAll]);
    AssertContains(J, '"finished_at":null', 'a running job has no finish time');
  finally
    Root.Free;
  end;

  { the detail: transcript with the answer, and a shell job's output }
  D := Route('GET', '/v1/background/' + HSub, '', St);
  try
    AssertTrue(St = 200, 'detail is 200');
    Msgs := D.ChildArray('messages');
    AssertTrue((Msgs <> nil) and (Msgs.Count >= 2), 'detail has messages');
    AssertEq(Msgs.ItemObject(0).GetStr('role'), 'user', 'first is the task');
    AssertContains(Msgs.ItemObject(0).GetStr('content'), 'summarise the frobnicator', 'the task text');
    AssertEq(Msgs.ItemObject(Msgs.Count - 1).GetStr('role'), 'assistant', 'last is the answer');
    AssertEq(Msgs.ItemObject(Msgs.Count - 1).GetStr('content'), 'ECHO[summarise the frobnicator]',
             'the answer is in the transcript, not only in the result');
    AssertContains(D.GetStr('result'), 'ECHO[', 'full result in the detail');
  finally
    D.Free;
  end;
  D := Route('GET', '/v1/background/' + HShell, '', St);
  try
    AssertContains(D.GetStr('output'), 'listing-shell-out', 'shell output in the detail');
    AssertTrue(Pos('exit=', D.GetStr('output')) = 0, 'the exit line is the exit_code field, not output');
  finally
    D.Free;
  end;

  { routes: unknown handle, wrong verb, not ours }
  D := Route('GET', '/v1/background/bg-nope00', '', St);
  D.Free;
  AssertTrue(St = 404, 'unknown handle is 404');
  D := Route('POST', '/v1/background', '', St);
  D.Free;
  AssertTrue(St = 405, 'POST on the list is 405');
  D := Route('POST', '/v1/background/' + HSub, '', St);
  D.Free;
  AssertTrue(St = 405, 'POST on a detail is 405');
  D := Route('GET', '/v1/background/' + HSub + '/cancel', '', St);
  D.Free;
  AssertTrue(St = 405, 'GET on cancel is 405');
  AssertTrue(not HandleBackgroundRoute('GET', '/v1/backgroundx', '', St, J), 'a lookalike path is not ours');

  { cancel through the route: a shell job is killed }
  D := Route('POST', '/v1/background/' + HSleep + '/cancel', '', St);
  try
    AssertTrue(St = 200, 'cancel is 200');
    AssertTrue(D.GetBool('killed') and not D.GetBool('advisory'), 'a local shell job is killed');
  finally
    D.Free;
  end;
  WaitDone(Coord, HSleep);
  D := Route('POST', '/v1/background/' + HSleep + '/cancel', '', St);
  D.Free;
  AssertTrue(St = 409, 'cancelling it again is 409');
  for i := 1 to 50 do
  begin
    Coord.GetInfo(HSleep, Info);
    if Info.FinishedAt <> 0 then Break;
    Sleep(50);
  end;
  { the /tasks text: one line per job, the running one first }
  J := FormatBackgroundJobsText;
  AssertContains(J, HSub, '/tasks lists the subagent');
  AssertContains(J, 'researcher: summarise the frobnicator', '/tasks names agent and task');
  AssertContains(J, 'shell: echo listing-shell-out', '/tasks names the command');
  AssertContains(J, 'exit=0', '/tasks gives a shell job''s exit code');
  AssertContains(BackgroundJobsSummary, 'finished', 'the one-line summary counts');
  WriteLn('  ok: listing JSON, detail, routes, cancel and the /tasks text');
end;

procedure TestRetention;
var
  Provider: ILLMProvider;
  Reg: TToolRegistry;
  Coord: TBackgroundSpawnCoordinator;
  Out_, Err, HA, HB, HC1, HT: string;
  i, Done: Integer;
  Infos: TBgJobInfoArray;

  function Spawn(const Cmd: string): string;
  begin
    Result := ExtractHandle(Coord.HandleShellBackground('{"command":"' + Cmd + '"}', Err));
    AssertEq(Err, '', 'spawn ' + Cmd);
    WaitDone(Coord, Result);
  end;

begin
  Provider := TFakeProvider.Create;
  Reg := TToolRegistry.Create;
  Coord := TBackgroundSpawnCoordinator.Create(MakeCtx(Provider, Reg), MakeSpecs);
  try
    HA := Spawn('echo A');                       { oldest, never delivered }
    HB := Spawn('echo B');
    Out_ := Coord.HandleWait('{"handle":"' + HB + '"}', Err);   { delivered }
    AssertContains(Out_, 'B', 'wait returns B');
    HC1 := Spawn('echo C1');
    for i := 2 to BackgroundHistoryMax - 2 do Spawn('echo C' + IntToStr(i));
    { 50 finished: nothing is dropped yet. }
    Sleep(200);
    Spawn('echo D');
    AssertTrue(Present(Coord, HA) and Present(Coord, HB), 'at the cap nothing is dropped');
    Sleep(200);                                  { every thread above has ended }
    HT := Spawn('echo T1');                      { 51 finished -> one goes }
    AssertTrue(not Present(Coord, HB), 'the delivered job goes first, though not the oldest');
    AssertTrue(Present(Coord, HA), 'the undelivered oldest stays while a delivered one can go');
    Sleep(200);
    Spawn('echo T2');                            { again one over }
    AssertTrue(not Present(Coord, HA), 'then the oldest goes');
    AssertTrue(Present(Coord, HC1) and Present(Coord, HT), 'newer jobs stay');
    SetLength(Infos, 0);
    Coord.AppendInfos(Infos);
    Done := 0;
    for i := 0 to High(Infos) do
      if Infos[i].State <> 'running' then Inc(Done);
    AssertTrue(Done <= BackgroundHistoryMax + 1,
               Format('the finished jobs stay bounded (%d kept)', [Done]));
    AssertTrue(Length(Infos) <= BackgroundHistoryMax + 1,
               Format('the list stays bounded (%d jobs)', [Length(Infos)]));
  finally
    Coord.Free;
    Reg.Free;
  end;
  WriteLn('  ok: retention keeps ', BackgroundHistoryMax, ' finished jobs, delivered ones dropped first');
end;

procedure TestFollowUp;
var
  Provider: ILLMProvider;
  Reg: TToolRegistry;
  Coord: TBackgroundSpawnCoordinator;
  Out_, Err, H1, H2, HSh, HBl, NewH, Msg, Seen: string;
  Outcome: TBgContinueOutcome;
  Info: TBgJobInfo;
  i: Integer;
begin
  Provider := TFakeProvider.Create;
  Reg := TToolRegistry.Create;
  Coord := TBackgroundSpawnCoordinator.Create(MakeCtx(Provider, Reg), MakeSpecs);
  try
    Out_ := Coord.HandleSpawnBackground('{"agent":"researcher","prompt":"first question"}', Err);
    H1 := ExtractHandle(Out_);
    WaitDone(Coord, H1);

    Outcome := Coord.ContinueJob(H1, 'second question', NewH, Msg);
    AssertTrue(Outcome = bmoStarted, 'follow-up starts: ' + Msg);
    H2 := NewH;
    AssertTrue((H2 <> '') and (H2 <> H1), 'a new job');
    Out_ := Coord.HandleWait('{"handle":"' + H2 + '","timeout_sec":10}', Err);
    AssertEq(Out_, 'ECHO[second question]', 'the follow-up answers the new message');

    { what the model was sent: the old conversation, then the message }
    GSeenLock.Enter;
    try
      Seen := '';
      for i := 0 to High(GSeen) do
        Seen := Seen + '|' + IntToStr(Ord(GSeen[i].Role)) + ':' + StripTurnClock(GSeen[i].Content);
      AssertEq(Seen, '|1:first question|2:ECHO[first question]|1:second question',
               'the follow-up continues the conversation');
      AssertEq(GSeenSystem, 'you are research', 'under the same system prompt');
    finally
      GSeenLock.Leave;
    end;

    AssertTrue(Coord.GetInfo(H2, Info), 'new job visible');
    AssertEq(Info.ContinuedFrom, H1, 'linked back');
    AssertTrue(Length(Info.Messages) = 4, 'its transcript is the whole conversation');
    AssertTrue(Coord.GetInfo(H1, Info), 'old job still there');
    AssertEq(Info.ContinuedBy, H2, 'linked forward');

    { a follow-up to the follow-up chains }
    AssertTrue(Coord.ContinueJob(H2, 'third', NewH, Msg) = bmoStarted, 'chains: ' + Msg);
    Out_ := Coord.HandleWait('{"handle":"' + NewH + '","timeout_sec":10}', Err);
    AssertEq(Out_, 'ECHO[third]', 'third answer');

    { refusals }
    AssertTrue(Coord.ContinueJob(H1, '   ', NewH, Msg) = bmoEmptyText, 'empty message refused');
    AssertTrue(Coord.ContinueJob('bg-000000', 'x', NewH, Msg) = bmoNotFound, 'unknown handle');
    HSh := ExtractHandle(Coord.HandleShellBackground('{"command":"echo sh"}', Err));
    WaitDone(Coord, HSh);
    AssertTrue(Coord.ContinueJob(HSh, 'x', NewH, Msg) = bmoNotSubagent, 'a shell job has no conversation');
    AssertContains(Msg, 'shell', 'and says so');
    GRelease.ResetEvent;
    HBl := ExtractHandle(Coord.HandleSpawnBackground('{"agent":"researcher","prompt":"BLOCK me"}', Err));
    Sleep(100);
    AssertTrue(Coord.ContinueJob(HBl, 'x', NewH, Msg) = bmoRunning, 'a running job is refused');
    { cancelled but still in its model call: still refused }
    Coord.HandleCancel('{"handle":"' + HBl + '"}', Err);
    AssertTrue(Coord.ContinueJob(HBl, 'x', NewH, Msg) = bmoRunning,
               'a cancelled job still finishing its call is refused');
    GRelease.SetEvent;
    WaitDone(Coord, HBl);
    for i := 1 to 100 do
    begin
      Coord.GetInfo(HBl, Info);
      if Info.FinishedAt <> 0 then Break;
      Sleep(20);
    end;
    AssertTrue(Coord.ContinueJob(HBl, 'after all', NewH, Msg) = bmoStarted,
               'once it has ended a cancelled job can be messaged: ' + Msg);
    Coord.HandleWait('{"handle":"' + NewH + '","timeout_sec":10}', Err);
  finally
    GRelease.SetEvent;
    Coord.Free;
    Reg.Free;
  end;
  WriteLn('  ok: follow-ups continue the conversation as linked jobs; refusals');
end;

procedure TestBoundTranscript;
var
  Src, R: TMessageArray;
  i: Integer;
  T: Boolean;
  Big: string;
  O: TJsonObject;
begin
  { 1 task + 150 rounds of (assistant with a call, tool result) = 301 }
  SetLength(Src, 301);
  Src[0] := MakeMessage(mrUser, 'the task');
  for i := 0 to 149 do
  begin
    Src[1 + i * 2] := MakeMessage(mrAssistant, '');
    SetLength(Src[1 + i * 2].ToolCalls, 1);
    Src[1 + i * 2].ToolCalls[0].Id := 'c' + IntToStr(i);
    Src[1 + i * 2].ToolCalls[0].Func.Name := 'read_file';
    Src[1 + i * 2].ToolCalls[0].Func.Arguments := '{"path":"f' + IntToStr(i) + '"}';
    Src[2 + i * 2] := MakeMessage(mrTool, 'result ' + IntToStr(i));
    Src[2 + i * 2].ToolCallId := 'c' + IntToStr(i);
  end;
  R := BoundTranscript(Src, T);
  AssertTrue(T, 'trimmed is reported');
  AssertTrue(Length(R) <= BgTranscriptMaxMessages, 'message cap holds: ' + IntToStr(Length(R)));
  AssertEq(R[0].Content, 'the task', 'the task stays first');
  AssertTrue(R[1].Role <> mrTool, 'no tool result leads without its call');
  AssertEq(R[High(R)].Content, 'result 149', 'the newest stays');

  { one huge message is cut, with a marker; huge arguments stay JSON }
  SetLength(Src, 3);
  Big := StringOfChar('y', BgTranscriptMsgChars + 500);
  Src[0] := MakeMessage(mrUser, 'task');
  Src[1] := MakeMessage(mrAssistant, '');
  SetLength(Src[1].ToolCalls, 1);
  Src[1].ToolCalls[0].Func.Name := 'write_file';
  Src[1].ToolCalls[0].Func.Arguments := '{"path":"a.txt","content":"' + Big + '"}';
  Src[2] := MakeMessage(mrTool, Big);
  R := BoundTranscript(Src, T);
  AssertTrue(T, 'trimmed when cut');
  AssertTrue(Length(R[2].Content) < BgTranscriptMsgChars + 100, 'a big message is cut');
  AssertContains(R[2].Content, '[cut: 500 more characters]', 'and says how much');
  AssertTrue(Length(R[1].ToolCalls[0].Func.Arguments) < BgTranscriptArgChars, 'big arguments shrink');
  O := TJsonObject.Parse(R[1].ToolCalls[0].Func.Arguments);
  AssertTrue(O <> nil, 'and stay JSON');
  AssertEq(O.GetStr('path'), 'a.txt', 'small fields kept');
  O.Free;
  AssertEq(Src[2].Content, Big, 'the source is not changed');

  { the char cap drops from the front too }
  SetLength(Src, 40);
  Src[0] := MakeMessage(mrUser, 'task');
  for i := 1 to 39 do
    Src[i] := MakeMessage(mrAssistant, StringOfChar('z', BgTranscriptMsgChars - 10));
  R := BoundTranscript(Src, T);
  AssertTrue(Length(R) < 40, 'the character cap drops messages');
  AssertEq(R[0].Content, 'task', 'the task stays');
  WriteLn('  ok: BoundTranscript caps messages and characters, keeps the task and JSON');
end;

var
  Provider: ILLMProvider;
  Reg: TToolRegistry;
  Coord: TBackgroundSpawnCoordinator;
begin
  GSeenLock := TCriticalSection.Create;
  GRelease := TEvent.Create(nil, True, True, '');
  TestBoundTranscript;
  Provider := TFakeProvider.Create;
  Reg := TToolRegistry.Create;
  { Registered like the gateway's, so the process-wide listing finds it. }
  Coord := RegisterBackgroundSpawnTools(Reg, MakeCtx(Provider, Reg), MakeSpecs);
  TestListingJSON(Coord);
  TestRetention;
  TestFollowUp;
  WriteLn('background_view_tests: OK');
end.
