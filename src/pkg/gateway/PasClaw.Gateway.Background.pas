(*
  PasClaw.Gateway.Background -- the /v1/background routes: the background
  jobs on this gateway (spawn_background subagents and shell_background
  commands, every chat's, running and finished), one job's transcript or
  output, stop, and a follow-up message to a finished subagent.

    GET  /v1/background                  the jobs, running first, then newest
    GET  /v1/background/<handle>         one job: transcript / output
    POST /v1/background/<handle>/cancel  stop it (spawn_cancel's path)
    POST /v1/background/<handle>/message {"text"}: continue a finished
                                         subagent's conversation as a new job

  Scheduled work is not here: GET /v1/cron already lists it.

  No Indy in this unit. HandleBackgroundRoute takes the verb, the path and
  the body and gives back a status and a JSON body, so the routes are
  tested without a server (src/tests/background_view_tests.pas).
  PasClaw.Gateway.Server calls it inside its bearer-token gate, like every
  other /v1 route. The jobs themselves live in PasClaw.Agent.SubagentBg.
*)
unit PasClaw.Gateway.Background;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

const
  BackgroundRoutePrefix = '/v1/background';
  { Previews in the list; the detail carries the whole text (bounded). }
  BgPromptPreviewChars = 200;
  BgResultPreviewChars = 300;

{ True when Doc is a /v1/background route, whatever the verb; Status and
  JSON are then the answer to send. Method is the HTTP verb, Body the
  request body (only POST .../message reads it). }
function HandleBackgroundRoute(const Method, Doc, Body: string;
                               out Status: Integer; out JSON: string): Boolean;

{ GET /v1/background's body. }
function BackgroundListJSON: string;

implementation

uses
  SysUtils, DateUtils,
  PasClaw.JSON,
  PasClaw.Utils,                 { Utf8SafeTruncate, Utf8SeqLen }
  PasClaw.Providers.Types,       { TMsgRole }
  PasClaw.Gateway.ToolView,      { the chat's own tool-call / result lines }
  PasClaw.Agent.SubagentBg;

function ScrubUtf8(const S: string): string;
(* Replace any byte that does not start a whole UTF-8 sequence with '?'.
   Tool lines are shortened by byte count (ToolView's Ellipsize) and a
   cut can land inside a character; a strict JSON reader refuses the whole
   answer for one such byte. One pass over the finished body. Delphi's
   strings are UTF-16 and need nothing. *)
{$IFDEF FPC}
var
  i, n, k: Integer;
  Ok: Boolean;
begin
  Result := S;
  i := 1;
  while i <= Length(Result) do
  begin
    if Byte(Result[i]) < $80 then begin Inc(i); Continue; end;
    n := Utf8SeqLen(Byte(Result[i]));
    Ok := (n > 1) and (i + n - 1 <= Length(Result));
    if Ok then
      for k := 1 to n - 1 do
        if (Byte(Result[i + k]) and $C0) <> $80 then begin Ok := False; Break; end;
    if Ok then Inc(i, n)
    else begin Result[i] := '?'; Inc(i); end;
  end;
end;
{$ELSE}
begin
  Result := S;
end;
{$ENDIF}

function Preview(const S: string; MaxLen: Integer): string;
begin
  if Length(S) <= MaxLen then Result := S
  else Result := Utf8SafeTruncate(S, MaxLen) + '...';
end;

procedure PutTime(O: TJsonObject; const Key: string; T: TDateTime);
begin
  if T = 0 then O.PutRaw(Key, 'null')
  else O.PutInt(Key, DateTimeToUnix(T, False));
end;

function RoleName(R: TMsgRole): string;
begin
  case R of
    mrSystem:    Result := 'system';
    mrUser:      Result := 'user';
    mrAssistant: Result := 'assistant';
    mrTool:      Result := 'tool';
  else           Result := 'unknown';
  end;
end;

function MessagesJSON(const Msgs: TMessageArray): TJsonArray;
(* The transcript, message by message, in the shape a chat client already
   knows (role, content, tool_calls, tool_call_id). Each tool call and tool
   result also carries `line`: the one-liner the chat stream shows for it
   (FormatToolCallLine / FormatToolResultLine), so the web UI draws a
   subagent's work with the chat's own tool cards. *)
var
  i, j: Integer;
  M, TC: TJsonObject;
  Calls: TJsonArray;
  CallNames: array of string;
  CallIds: array of string;
  Name: string;
  k: Integer;
begin
  Result := TJsonArray.Create;
  SetLength(CallNames, 0);
  SetLength(CallIds, 0);
  for i := 0 to High(Msgs) do
  begin
    M := TJsonObject.Create;
    M.PutStr('role', RoleName(Msgs[i].Role));
    M.PutStr('content', Msgs[i].Content);
    if Length(Msgs[i].ToolCalls) > 0 then
    begin
      Calls := TJsonArray.Create;
      for j := 0 to High(Msgs[i].ToolCalls) do
      begin
        TC := TJsonObject.Create;
        TC.PutStr('id', Msgs[i].ToolCalls[j].Id);
        TC.PutStr('name', Msgs[i].ToolCalls[j].Func.Name);
        TC.PutStr('arguments', Msgs[i].ToolCalls[j].Func.Arguments);
        TC.PutStr('line', FormatToolCallLine(Msgs[i].ToolCalls[j].Func.Name,
                                             Msgs[i].ToolCalls[j].Func.Arguments));
        Calls.AddObject(TC);
        { Remember the name by id: a tool result names only its call. }
        SetLength(CallIds, Length(CallIds) + 1);
        SetLength(CallNames, Length(CallNames) + 1);
        CallIds[High(CallIds)] := Msgs[i].ToolCalls[j].Id;
        CallNames[High(CallNames)] := Msgs[i].ToolCalls[j].Func.Name;
      end;
      M.PutArray('tool_calls', Calls);
    end;
    if Msgs[i].Role = mrTool then
    begin
      Name := Msgs[i].Name;
      if (Name = '') and (Msgs[i].ToolCallId <> '') then
        for k := High(CallIds) downto 0 do
          if CallIds[k] = Msgs[i].ToolCallId then begin Name := CallNames[k]; Break; end;
      if Msgs[i].ToolCallId <> '' then M.PutStr('tool_call_id', Msgs[i].ToolCallId);
      if Name <> '' then M.PutStr('name', Name);
      M.PutStr('line', FormatToolResultLine(Name, Msgs[i].Content, ''));
    end;
    Result.AddObject(M);
  end;
end;

function JobJSON(const I: TBgJobInfo; Detail: Boolean): TJsonObject;
var
  Finished: Boolean;
  Msgs: TJsonArray;
  ResultPreview: string;
begin
  Result := TJsonObject.Create;
  Finished := I.FinishedAt <> 0;
  Result.PutStr('handle', I.Handle);
  Result.PutStr('kind', I.Kind);
  Result.PutStr('agent', I.AgentName);
  if I.Kind = 'shell' then
  begin
    if Detail then Result.PutStr('command', I.Command)
    else Result.PutStr('command', Preview(I.Command, BgPromptPreviewChars));
  end
  else
  begin
    if Detail then Result.PutStr('prompt', I.Prompt)
    else Result.PutStr('prompt', Preview(I.Prompt, BgPromptPreviewChars));
  end;
  Result.PutStr('state', I.State);
  { Cancelled, but its thread is still finishing a model call. }
  Result.PutBool('stopping', I.Stopping);
  PutTime(Result, 'started_at', I.StartedAt);
  PutTime(Result, 'finished_at', I.FinishedAt);
  Result.PutInt('elapsed_sec', I.ElapsedSec);
  { The chat it belongs to: the session key of the turn that started it
    (the web UI's chat id). '' when that turn named no session. }
  Result.PutStr('session', I.Session);
  if I.State = 'failed' then ResultPreview := I.ErrMsg
  else ResultPreview := I.ResultText;
  Result.PutStr('result_preview', Preview(ResultPreview, BgResultPreviewChars));
  if I.ErrMsg <> '' then Result.PutStr('error', I.ErrMsg);
  if I.ExitCode >= 0 then Result.PutInt('exit_code', I.ExitCode);
  { Its result has reached the model of its chat (drained into a turn, or
    fetched with spawn_wait). }
  Result.PutBool('delivered', I.Collected);
  if I.Worktree <> '' then Result.PutStr('worktree', I.Worktree);
  if I.ContinuedFrom <> '' then Result.PutStr('continued_from', I.ContinuedFrom);
  if I.ContinuedBy <> '' then Result.PutStr('continued_by', I.ContinuedBy);
  Result.PutBool('can_cancel', I.State = 'running');
  Result.PutBool('can_message', (I.Kind = 'subagent') and Finished);
  if not Detail then Exit;
  if I.Kind = 'subagent' then
  begin
    Msgs := MessagesJSON(I.Messages);
    Result.PutArray('messages', Msgs);
    Result.PutBool('transcript_trimmed', I.Trimmed);
    if I.ResultText <> '' then
      Result.PutStr('result', Utf8SafeTruncate(I.ResultText, BgOutputViewChars));
  end
  else
  begin
    Result.PutStr('output', I.Output);
    Result.PutBool('output_truncated', I.OutputTruncated);
  end;
end;

function ErrorJSON(const Msg: string): string;
var
  O: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    O.PutStr('error', Msg);
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function BackgroundListJSON: string;
var
  Jobs: TBgJobInfoArray;
  Root, O: TJsonObject;
  Arr: TJsonArray;
  i, Running: Integer;
begin
  Jobs := ListBackgroundJobs;
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    Running := 0;
    for i := 0 to High(Jobs) do
    begin
      if Jobs[i].State = 'running' then Inc(Running);
      O := JobJSON(Jobs[i], False);
      Arr.AddObject(O);
    end;
    Root.PutArray('jobs', Arr);
    Root.PutInt('running', Running);
    Root.PutInt('history_max', BackgroundHistoryMax);
    { Scheduled work has its own route; this one does not repeat it. }
    Root.PutStr('cron', '/v1/cron');
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function DetailJSON(const Handle: string; out Status: Integer): string;
var
  Info: TBgJobInfo;
  O: TJsonObject;
begin
  if not GetBackgroundJob(Handle, Info) then
  begin
    Status := 404;
    Exit(ErrorJSON('no background job with handle ' + Handle));
  end;
  O := JobJSON(Info, True);
  try
    Status := 200;
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function CancelJSON(const Handle: string; out Status: Integer): string;
var
  Msg: string;
  Outcome: TBgCancelOutcome;
  Info: TBgJobInfo;
  O: TJsonObject;
begin
  Outcome := CancelBackgroundJob(Handle, Msg);
  if Outcome = bcoNotFound then
  begin
    Status := 404;
    Exit(ErrorJSON('no background job with handle ' + Handle));
  end;
  GetBackgroundJob(Handle, Info);
  O := TJsonObject.Create;
  try
    O.PutStr('handle', Handle);
    O.PutStr('state', Info.State);
    if Outcome = bcoAlreadyFinished then
    begin
      Status := 409;
      O.PutStr('error', Msg);
    end
    else
    begin
      Status := 200;
      O.PutBool('cancelled', True);
      { Killed: a local process was. Advisory: the job was marked and stops
        by itself -- a subagent at its next step, after any model call in
        flight; a shell job under another backend never killed from here.
        Either way its result is discarded. }
      O.PutBool('killed', Outcome = bcoKilled);
      O.PutBool('advisory', Outcome = bcoAdvisory);
      O.PutStr('message', Msg);
    end;
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function MessageJSON(const Handle, Body: string; out Status: Integer): string;
var
  Req, O: TJsonObject;
  Text, NewH, Msg: string;
  Outcome: TBgContinueOutcome;
  Info: TBgJobInfo;
begin
  Text := '';
  Req := nil;
  if Trim(Body) <> '' then
    try
      Req := TJsonObject.Parse(Body);
    except
      Req := nil;
    end;
  if Req = nil then
  begin
    Status := 400;
    Exit(ErrorJSON('the body must be JSON: {"text": "..."}'));
  end;
  try
    Text := Req.GetStr('text', '');
  finally
    Req.Free;
  end;
  Outcome := ContinueBackgroundJob(Handle, Text, NewH, Msg);
  case Outcome of
    bmoStarted:     Status := 202;
    bmoNotFound:    Status := 404;
    bmoEmptyText:   Status := 400;
    bmoNotSubagent: Status := 400;
    bmoRunning:     Status := 409;
    bmoNoSuchAgent: Status := 409;
    bmoAtCap:       Status := 429;
  else              Status := 500;
  end;
  if Outcome <> bmoStarted then Exit(ErrorJSON(Msg));
  GetBackgroundJob(NewH, Info);
  O := TJsonObject.Create;
  try
    O.PutStr('handle', NewH);
    O.PutStr('continued_from', Handle);
    O.PutStr('state', Info.State);
    O.PutStr('session', Info.Session);
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function HandleBackgroundRoute(const Method, Doc, Body: string;
                               out Status: Integer; out JSON: string): Boolean;
var
  Rest, Handle, Action: string;
  Slash: Integer;
begin
  Status := 404;
  JSON := '';
  Result := False;
  if Doc = BackgroundRoutePrefix then
  begin
    Result := True;
    if Method <> 'GET' then
    begin
      Status := 405;
      JSON := ErrorJSON('GET only');
      Exit;
    end;
    Status := 200;
    JSON := ScrubUtf8(BackgroundListJSON);
    Exit;
  end;
  if Copy(Doc, 1, Length(BackgroundRoutePrefix) + 1) <> BackgroundRoutePrefix + '/' then Exit;
  Result := True;
  Rest := Copy(Doc, Length(BackgroundRoutePrefix) + 2, MaxInt);
  Slash := Pos('/', Rest);
  if Slash > 0 then
  begin
    Handle := Copy(Rest, 1, Slash - 1);
    Action := Copy(Rest, Slash + 1, MaxInt);
  end
  else
  begin
    Handle := Rest;
    Action := '';
  end;
  if (Handle = '') or ((Action <> '') and (Action <> 'cancel') and (Action <> 'message')) then
  begin
    Status := 404;
    JSON := ErrorJSON('not found: ' + Doc);
    Exit;
  end;
  if Action = '' then
  begin
    if Method <> 'GET' then begin Status := 405; JSON := ErrorJSON('GET only'); Exit; end;
    JSON := ScrubUtf8(DetailJSON(Handle, Status));
  end
  else if Method <> 'POST' then
  begin
    Status := 405;
    JSON := ErrorJSON('POST only');
  end
  else if Action = 'cancel' then
    JSON := ScrubUtf8(CancelJSON(Handle, Status))
  else
    JSON := ScrubUtf8(MessageJSON(Handle, Body, Status));
end;

end.
