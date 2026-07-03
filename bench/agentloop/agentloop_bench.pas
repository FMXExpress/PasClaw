program agentloop_bench;
(*
  bench/agentloop -- deterministic agent-loop harness benchmark, pure FPC.

  Measures and pins HARNESS quality (not model quality -- that's bench/swe):
  the scripted "model" below is played by this process through the relay
  provider, so every run is fully reproducible, costs zero API tokens, and
  every request envelope the loop builds is inspectable.

  How it works:
    1. Spawns `build/pasclaw gateway` (TProcess) against a throwaway
       PASCLAW_HOME whose config.json uses the relay provider.
    2. Connects as a relay worker -- a background thread holds the SSE GET
       on /v1/relay/poll (same TIdHTTP + custom-TStream frame parser shape
       as PasClaw.Cmd.Relay) and answers each inference request from a
       per-scenario script, POSTing to /v1/relay/respond/<id>.
    3. Fires /v1/chat/completions tasks and asserts on what the LOOP did:
       the system prompts it built, what landed on disk, how big the
       request bodies grew.

  Scenarios:
    build-site          write_file + todo_write on turn 1 -> the progress
                        ledger must fold into iteration 2's system prompt
                        (goal + file + checklist), iteration 1 must stay
                        pristine (prefix-cache), deliverable on disk.
    malformed-recovery  a Gemini-shaped MALFORMED_FUNCTION_CALL empty turn
                        must be retried with the corrective nudge naming a
                        REGISTERED tool, and the turn must still deliver.
    resume-after-cap    run the loop into the 25-iteration cap; the reply
                        must carry the max-iter notice WITH the resume
                        ledger; a follow-up "continue" turn must anchor its
                        ledger goal to the original task. Also reports max
                        request-body bytes across the 25 iterations.

  Run:  make bench-agentloop     (compiles this program, needs build/pasclaw)
  Exit: 0 all scenarios pass; 1 otherwise. Metrics print either way.
  FPC-only (TProcess); the shipping binary itself is what gets exercised.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Process, SyncObjs,
  IdHTTP,
  PasClaw.JSON,
  PasClaw.Providers.HTTP;

const
  PORT = 8140;
  BASE = 'http://127.0.0.1:8140';

{ ---- assertion + metric plumbing ---------------------------------------- }
var
  GFailures: array of string;
  GMetrics:  array of string;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then
    WriteLn('  ok: ' + Msg)
  else
  begin
    WriteLn('  FAIL: ' + Msg);
    SetLength(GFailures, Length(GFailures) + 1);
    GFailures[High(GFailures)] := Msg;
  end;
end;

procedure Metric(const Name: string; Value: Int64);
begin
  SetLength(GMetrics, Length(GMetrics) + 1);
  GMetrics[High(GMetrics)] := Format('%s = %d', [Name, Value]);
  WriteLn('  metric: ' + GMetrics[High(GMetrics)]);
end;

function Has(const Hay, Needle: string): Boolean;
begin
  Result := Pos(Needle, Hay) > 0;
end;

{ ---- the scripted model: relay worker ------------------------------------ }
type
  { Per-scenario script: called with the 1-based call number within the
    scenario and the raw envelope JSON; returns the response JSON to POST
    back to /v1/relay/respond/<id>. }
  THandler = function(N: Integer; const EnvJSON: string): string;

var
  GLock:     TCriticalSection;
  GHandler:  THandler;
  GEnvs:     array of string;   { raw envelopes, reset per scenario }
  GMaxBody:  Integer;           { max envelope bytes, reset per scenario }
  GTotalBody: Int64;            { sum of envelope bytes, reset per scenario }
  GStep:     Integer;           { policy-model state for ScenarioRealTask }

procedure ResetScenario(H: THandler);
begin
  GLock.Acquire;
  try
    GHandler := H;
    SetLength(GEnvs, 0);
    GMaxBody := 0;
    GTotalBody := 0;
    GStep := 0;
  finally
    GLock.Release;
  end;
end;

function EnvCount: Integer;
begin
  GLock.Acquire;
  try Result := Length(GEnvs); finally GLock.Release; end;
end;

function EnvAt(I: Integer): string;
begin
  GLock.Acquire;
  try
    if (I >= 0) and (I <= High(GEnvs)) then Result := GEnvs[I] else Result := '';
  finally
    GLock.Release;
  end;
end;

function EnvSystemPrompt(const EnvJSON: string): string;
var
  Env, Opts: TJsonObject;
begin
  Result := '';
  Env := TJsonObject.Parse(EnvJSON);
  if Env = nil then Exit;
  try
    Opts := Env.ChildObject('options');
    if Opts <> nil then
    try
      Result := Opts.GetStr('system_prompt', '');
    finally
      Opts.Free;
    end;
  finally
    Env.Free;
  end;
end;

function EnvLastMessage(const EnvJSON: string): string;
var
  Env, MsgObj: TJsonObject;
  Arr: TJsonArray;
begin
  Result := '';
  Env := TJsonObject.Parse(EnvJSON);
  if Env = nil then Exit;
  try
    Arr := Env.ChildArray('messages');
    if Arr <> nil then
    try
      if Arr.Count > 0 then
      begin
        MsgObj := Arr.ItemObject(Arr.Count - 1);
        if MsgObj <> nil then
        try
          Result := MsgObj.GetStr('content', '');
        finally
          MsgObj.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
  finally
    Env.Free;
  end;
end;

{ Dispatch one relay envelope: record it, ask the scenario script for the
  response, POST it back. Runs synchronously inside the SSE stream's Write
  (same back-pressure shape as PasClaw.Cmd.Relay). }
procedure DispatchEnvelope(const Data: string);
var
  Env: TJsonObject;
  Id, RespJSON: string;
  N: Integer;
  H: THandler;
begin
  Env := TJsonObject.Parse(Data);
  if Env = nil then Exit;
  try
    Id := Env.GetStr('id', '');
  finally
    Env.Free;
  end;
  if Id = '' then Exit;

  GLock.Acquire;
  try
    SetLength(GEnvs, Length(GEnvs) + 1);
    GEnvs[High(GEnvs)] := Data;
    N := Length(GEnvs);
    if Length(Data) > GMaxBody then GMaxBody := Length(Data);
    Inc(GTotalBody, Length(Data));
    H := GHandler;
  finally
    GLock.Release;
  end;

  if Assigned(H) then RespJSON := H(N, Data)
  else RespJSON := '{"content":"no handler","finish_reason":"stop"}';
  PostJSON(BASE + '/v1/relay/respond/' + Id, RespJSON, [], 30);
end;

type
  { SSE frame parser fed by TIdHTTP.Get -- accumulate, split on blank
    lines, dispatch each data: payload. Same shape as Cmd.Relay's
    TSSEStream. }
  TBenchSSE = class(TStream)
  private
    FBuf: string;
  public
    function Write(const Buffer; Count: Longint): Longint; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(Offset: Longint; Origin: Word): Longint; override;
  end;

function TBenchSSE.Read(var Buffer; Count: Longint): Longint;
begin Result := 0; end;

function TBenchSSE.Seek(Offset: Longint; Origin: Word): Longint;
begin Result := 0; end;

function TBenchSSE.Write(const Buffer; Count: Longint): Longint;
var
  Chunk: AnsiString;
  P: Integer;
  Frame, Line, DataAcc: string;
  Lines: TStringList;
  i: Integer;
begin
  Result := Count;
  if Count <= 0 then Exit;
  SetLength(Chunk, Count);
  Move(Buffer, Chunk[1], Count);
  FBuf := StringReplace(FBuf + string(Chunk), #13#10, #10, [rfReplaceAll]);
  repeat
    P := Pos(#10#10, FBuf);
    if P = 0 then Break;
    Frame := Copy(FBuf, 1, P - 1);
    Delete(FBuf, 1, P + 1);
    DataAcc := '';
    Lines := TStringList.Create;
    try
      Lines.Text := Frame;
      for i := 0 to Lines.Count - 1 do
      begin
        Line := Lines[i];
        if Copy(Line, 1, 5) = 'data:' then
        begin
          if DataAcc <> '' then DataAcc := DataAcc + #10;
          DataAcc := DataAcc + Trim(Copy(Line, 6, MaxInt));
        end;
      end;
    finally
      Lines.Free;
    end;
    if DataAcc <> '' then DispatchEnvelope(DataAcc);
  until False;
end;

type
  TWorkerThread = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TWorkerThread.Execute;
var
  Http: TIdHTTP;
  Stream: TBenchSSE;
begin
  { One long-lived SSE GET; when the bench kills the gateway the socket
    drops, Get raises, and the thread ends. Reconnect once on an early
    drop so a slow gateway start can't strand the worker. }
  while not Terminated do
  begin
    Http := TIdHTTP.Create(nil);
    Stream := TBenchSSE.Create;
    try
      Http.ConnectTimeout := 5000;
      Http.ReadTimeout := 0;   { SSE: idle gaps are unbounded }
      Http.Request.Accept := 'text/event-stream';
      Http.Request.CustomHeaders.AddValue('X-Relay-Worker-Id', 'agentbench');
      try
        Http.Get(BASE + '/v1/relay/poll?worker_id=agentbench&caps=', Stream);
      except
        { disconnect -- fall through }
      end;
    finally
      Stream.Free;
      Http.Free;
    end;
    if not Terminated then Sleep(300);
  end;
end;

{ ---- response builders ---------------------------------------------------- }
function ArgsObj1(const K1, V1: string): string;
var O: TJsonObject;
begin
  O := TJsonObject.Create;
  try O.PutStr(K1, V1); Result := O.ToJSON; finally O.Free; end;
end;

function ArgsPathContent(const P, C: string): string;
var O: TJsonObject;
begin
  O := TJsonObject.Create;
  try O.PutStr('path', P); O.PutStr('content', C); Result := O.ToJSON;
  finally O.Free; end;
end;

function ArgsPathPlain(const P: string): string;
var O: TJsonObject;
begin
  O := TJsonObject.Create;
  try O.PutStr('path', P); O.PutBool('plain', True); Result := O.ToJSON;
  finally O.Free; end;
end;

function OneCall(const Name, Args: string): string;
var O, F: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    O.PutStr('id', 'c_' + Name);
    O.PutStr('type', 'function');
    F := TJsonObject.Create;
    F.PutStr('name', Name);
    F.PutStr('arguments', Args);
    O.PutObject('function', F);
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function RoundOf(const Calls: array of string): string;
var
  O: TJsonObject;
  Arr: string;
  i: Integer;
begin
  Arr := '';
  for i := 0 to High(Calls) do
  begin
    if Arr <> '' then Arr := Arr + ',';
    Arr := Arr + Calls[i];
  end;
  O := TJsonObject.Create;
  try
    O.PutStr('content', 'working');
    O.PutStr('finish_reason', 'tool_calls');
    O.PutRaw('tool_calls', '[' + Arr + ']');
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function StopOf(const Text: string): string;
var O: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    O.PutStr('content', Text);
    O.PutStr('finish_reason', 'stop');
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function TruncatedOf(const Text, Finish: string): string;
{ A no-tool-call turn that failed recoverably: prose content, no tool call,
  finish_reason = 'length' (output ceiling; Gemini/OpenAI) or
  'MALFORMED_FUNCTION_CALL' (Gemini emitted an unparseable / oversized call
  alongside narration). Both are the observed real-world Gemini 3.5 Flash
  failure -- narrating code as prose until it runs out or malforms. }
var O: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    O.PutStr('content', Text);
    O.PutStr('finish_reason', Finish);
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

{ ---- chat driver ---------------------------------------------------------- }
function MsgObjJSON(const Role, Content: string): string;
var O: TJsonObject;
begin
  O := TJsonObject.Create;
  try O.PutStr('role', Role); O.PutStr('content', Content); Result := O.ToJSON;
  finally O.Free; end;
end;

function Chat(const MsgsJSONArr: string; const Session: string): string;
var
  Body: TJsonObject;
  R: THTTPResult;
  Root, Choice, Msg: TJsonObject;
  Choices: TJsonArray;
begin
  Result := '';
  Body := TJsonObject.Create;
  try
    Body.PutStr('model', 'sim');
    Body.PutBool('stream', False);
    Body.PutRaw('messages', MsgsJSONArr);
    R := PostJSON(BASE + '/v1/chat/completions', Body.ToJSON,
                  [MakeHeader('X-PasClaw-Session', Session)], 120);
  finally
    Body.Free;
  end;
  if (R.StatusCode < 200) or (R.StatusCode >= 300) then
    Exit(Format('(http %d: %s)', [R.StatusCode, Copy(R.Body, 1, 200)]));
  Root := TJsonObject.Parse(R.Body);
  if Root = nil then Exit('(unparseable response)');
  try
    Choices := Root.ChildArray('choices');
    if Choices <> nil then
    try
      if Choices.Count > 0 then
      begin
        Choice := Choices.ItemObject(0);
        if Choice <> nil then
        try
          Msg := Choice.ChildObject('message');
          if Msg <> nil then
          try
            Result := Msg.GetStr('content', '');
          finally
            Msg.Free;
          end;
        finally
          Choice.Free;
        end;
      end;
    finally
      Choices.Free;
    end;
  finally
    Root.Free;
  end;
end;

{ ---- scenarios ------------------------------------------------------------ }
var
  GHomeDir: string;

function H_BuildSite(N: Integer; const EnvJSON: string): string;
begin
  case N of
    1: Result := RoundOf([
         OneCall('write_file', ArgsPathContent('bench-demo.html', '<h1>bench</h1>')),
         OneCall('todo_write', ArgsObj1('checklist', '- [x] write page'#10'- [ ] verify page'))]);
    2: Result := RoundOf([OneCall('edit_file',
         '{"path":"bench-demo.html","old_text":"<h1>bench</h1>","new_text":"<h1>bench v2</h1>"}')]);
  else if N = 3 then
    Result := RoundOf([OneCall('find_files', '{"pattern":"bench-*.html"}')])
  else
    Result := StopOf('page written and verified.');
  end;
end;

procedure ScenarioBuildSite;
var
  Answer, SP1, SP2: string;
begin
  WriteLn;
  WriteLn('== scenario: build-site (goal anchor + ledger fold + deliverable) ==');
  ResetScenario(H_BuildSite);
  Answer := Chat('[' + MsgObjJSON('user',
    'build a small landing page named bench-demo.html for the demo project') + ']',
    'bench-build');

  Check(EnvCount = 4, Format('loop finished in 4 provider calls (got %d)', [EnvCount]));
  SP1 := EnvSystemPrompt(EnvAt(0));
  Check(not Has(SP1, '[progress ledger'),
    'iteration 1 system prompt is pristine (prefix-cache preserved)');
  SP2 := EnvSystemPrompt(EnvAt(1));
  Check(Has(SP2, '[progress ledger'), 'iteration 2 carries the progress ledger');
  Check(Has(SP2, 'bench-demo.html'), 'ledger lists the written file');
  Check(Has(SP2, '- [ ] verify page'), 'ledger folds the todo_write checklist');
  Check(Has(SP2, 'Goal:') and Has(SP2, 'landing page'), 'ledger anchors the goal');
  Check(FileExists(GHomeDir + '/workspace/bench-demo.html'),
    'deliverable exists in the workspace');
  Check(Has(Answer, 'page written'), 'final answer surfaced');
  { B2: the edit's tool result carries the mini-diff snippet, so the model
    verifies placement without a full-file re-read. }
  Check(Has(EnvLastMessage(EnvAt(2)), 'now reads (lines'),
    'edit_file result carries the mini-diff context snippet');
  Check(Has(EnvLastMessage(EnvAt(2)), 'bench v2'),
    'snippet shows the changed content');
  { D1: one find_files call locates the deliverable by name -- no
    list_dir ladder. }
  Check(Has(EnvLastMessage(EnvAt(3)), 'bench-demo.html'),
    'find_files locates the file by glob in one call');
  Metric('build-site.provider_calls', EnvCount);
  { C4 baseline: the fixed per-request overhead every call pays -- system
    prompt + full tool schemas + one user message. Schema fat shows here. }
  Metric('build-site.first_request_bytes', Length(EnvAt(0)));
end;

function H_Malformed(N: Integer; const EnvJSON: string): string;
begin
  case N of
    1: Result := '{"content":"","finish_reason":"MALFORMED_FUNCTION_CALL"}';
    2: Result := RoundOf([OneCall('write_file', ArgsPathContent('recovered.txt', 'ok'))]);
  else
    Result := StopOf('recovered and wrote the file.');
  end;
end;

procedure ScenarioMalformedRecovery;
var
  Answer, LastMsg: string;
begin
  WriteLn;
  WriteLn('== scenario: malformed-recovery (Gemini MALFORMED_FUNCTION_CALL) ==');
  ResetScenario(H_Malformed);
  Answer := Chat('[' + MsgObjJSON('user',
    'write a big file for me in the workspace right now') + ']',
    'bench-malformed');

  Check(EnvCount >= 3, Format('malformed turn was retried (%d calls)', [EnvCount]));
  LastMsg := EnvLastMessage(EnvAt(1));
  Check(Has(LastMsg, 'not a valid tool call'), 'retry carries the corrective nudge');
  Check(Has(LastMsg, 'write_file') or Has(LastMsg, 'edit_file') or Has(LastMsg, 'append_file'),
    'nudge names a REGISTERED tool');
  Check(Has(Answer, 'recovered'), 'turn still delivered after recovery');
end;

function H_FatRead(N: Integer; const EnvJSON: string): string;
begin
  if N = 1 then
    Result := RoundOf([OneCall('read_file', ArgsPathPlain('big.txt'))])
  else if N = 2 then
    Result := RoundOf([OneCall('list_dir', ArgsObj1('path', '.'))])
  else
    Result := StopOf('inspected the big file.');
end;

procedure ScenarioFatRead;
{ C1: one oversized tool result must not ride verbatim in history for the
  rest of the turn. With the default ToolOutputCap the 100 KB read is
  diverted to the output cache (head + tail + tool_output_get handle) and
  every subsequent request stays flat; without it (tool_output_cap: 0 /
  pre-C1 builds) request 2 carries the full 100 KB. }
var
  S: TStringList;
  Big: string;
  i: Integer;
begin
  WriteLn;
  WriteLn('== scenario: fat-read (tool-output cap keeps request bodies flat) ==');
  Big := '';
  for i := 1 to 1800 do
    Big := Big + Format('line %4d: the quick brown fox jumps over the lazy dog again', [i]) + #10;
  S := TStringList.Create;
  try
    S.Text := Big;
    S.SaveToFile(GHomeDir + '/workspace/big.txt');
  finally
    S.Free;
  end;

  ResetScenario(H_FatRead);
  Chat('[' + MsgObjJSON('user',
    'inspect the big data file big.txt and summarise what it contains') + ']',
    'bench-fatread');
  Check(Has(EnvAt(1), 'tool_output_get'),
    'oversized read was capped with a tool_output_get retrieval handle');
  Check(GMaxBody < 60000,
    Format('request bodies stay under 60 KB with the cap (max %d)', [GMaxBody]));
  Metric('fatread.max_request_body_bytes', GMaxBody);
end;

function H_CapTurn1(N: Integer; const EnvJSON: string): string;
begin
  if N = 1 then
    Result := RoundOf([OneCall('write_file', ArgsPathContent('partial.txt', 'part 1'))])
  else
    { keep exploring forever -> the loop must hit its 25-iteration cap }
    Result := RoundOf([OneCall('read_file', ArgsPathPlain('partial.txt'))]);
end;

function H_CapTurn2(N: Integer; const EnvJSON: string): string;
begin
  if N = 1 then
    Result := RoundOf([OneCall('read_file', ArgsPathPlain('partial.txt'))])
  else
    Result := StopOf('resumed and finished.');
end;

procedure ScenarioResumeAfterCap;
const
  Task = 'produce the full multi-part report file for the quarterly numbers';
var
  Turn1, Turn2, SP2: string;
begin
  WriteLn;
  WriteLn('== scenario: resume-after-cap (25-iter notice + resume ledger) ==');
  ResetScenario(H_CapTurn1);
  Turn1 := Chat('[' + MsgObjJSON('user', Task) + ']', 'bench-cap');

  Check(Has(Turn1, 'hit the tool-call limit'), 'reply carries the max-iter notice');
  Check(Has(Turn1, 'do NOT redo'), 'notice carries the resume ledger instruction');
  Check(Has(Turn1, 'partial.txt'), 'resume ledger names the written file');
  Check(Has(Turn1, 'read '), 'resume ledger counts the reads');
  Metric('resume.max_request_body_bytes', GMaxBody);

  { Turn 2: "continue" -- the new turn's ledger must anchor to the TASK. }
  ResetScenario(H_CapTurn2);
  Turn2 := Chat('[' + MsgObjJSON('user', Task) + ',' +
                      MsgObjJSON('assistant', Turn1) + ',' +
                      MsgObjJSON('user', 'continue') + ']', 'bench-cap');
  SP2 := EnvSystemPrompt(EnvAt(1));
  Check(Has(SP2, 'quarterly numbers'),
    'turn 2 ledger anchors to the original task, not to "continue"');
  Check(Has(Turn2, 'finished'), 'turn 2 delivered');
end;

function H_RepeatRead(N: Integer; const EnvJSON: string): string;
begin
  if N <= 3 then
    Result := RoundOf([OneCall('read_file', ArgsPathPlain('notes.txt'))])
  else
    Result := StopOf('reviewed the notes.');
end;

procedure ScenarioRepeatRead;
{ C3: re-reading an unchanged file must not re-inject the full body --
  the second and third reads dedup to a one-line stub, so history growth
  across the repeat reads is stub-sized, not file-sized. The 8 KB fixture
  sits below the C1 cap on purpose: what keeps the bodies flat here is
  the dedup, not the byte cap. }
var
  S: TStringList;
  Body: string;
  i, Grow: Integer;
begin
  WriteLn;
  WriteLn('== scenario: repeat-read (per-turn dedup keeps history flat) ==');
  Body := '';
  for i := 1 to 130 do
    Body := Body + Format('note %3d: remember the thing about the thing', [i]) + #10;
  S := TStringList.Create;
  try
    S.Text := Body;
    S.SaveToFile(GHomeDir + '/workspace/notes.txt');
  finally
    S.Free;
  end;

  ResetScenario(H_RepeatRead);
  Chat('[' + MsgObjJSON('user',
    'review notes.txt very carefully, twice if you must') + ']', 'bench-repeat');
  Check(EnvCount = 4, Format('four provider calls (got %d)', [EnvCount]));
  Check(Has(EnvAt(2), 'unchanged since the earlier read'),
    'second read deduped to a stub in history');
  Grow := Length(EnvAt(3)) - Length(EnvAt(1));
  Check(Grow < 2500,
    Format('history growth across 2 repeat reads is stub-sized (%d bytes; the file is ~7 KB)', [Grow]));
  Metric('repeatread.growth_bytes_over_2_rereads', Grow);
end;

function H_RealTask(N: Integer; const EnvJSON: string): string;
{ A deterministic POLICY, not a fixed script: the same code runs against
  both binaries and adapts to what the harness offers -- exactly how a
  real model reads its tool schemas. Where the after-binary provides
  find_files / start_line / the mini-diff, the policy uses them; where
  the before-binary doesn't, it falls back to the list_dir ladder and
  full-file verify re-reads the original failing transcript showed. The
  60 KB "site dump" is generated locally (shell printf loop) instead of
  a live fetch so the run is byte-deterministic -- it mirrors the real
  transcript's fetch -> save -> parse loop. }
var
  LastMsg: string;
begin
  LastMsg := EnvLastMessage(EnvJSON);
  case GStep of
    0: begin GStep := 1;
         Result := RoundOf([OneCall('list_dir', ArgsObj1('path', '.'))]); end;
    1: begin GStep := 2;   { "fetch the reference site" -> save a ~68 KB dump.
         yes|head, not a shell loop: $((...)) trips the deny-substring
         guard for command substitution. }
         Result := RoundOf([OneCall('shell_exec', ArgsObj1('command',
           'yes "pasclaw dev site: tool-calling agent in object pascal, gateway, mcp, skills, sessions, memory pad" | head -800 > site-dump.html; wc -c site-dump.html'))]); end;
    2: begin GStep := 3;
         Result := RoundOf([OneCall('read_file', ArgsPathPlain('site-dump.html'))]); end;
    3: begin GStep := 4;   { "grab the README for feature listings" }
         Result := RoundOf([OneCall('shell_exec', ArgsObj1('command',
           'yes "README feature line: agent loop, tools, sessions, gateway" | head -100 > readme-ref.md; wc -c readme-ref.md'))]); end;
    4: begin GStep := 5;
         Result := RoundOf([OneCall('read_file', ArgsPathPlain('readme-ref.md'))]); end;
    5: begin GStep := 6;   { "double-check the dump" -- the classic re-read }
         Result := RoundOf([OneCall('read_file', ArgsPathPlain('site-dump.html'))]); end;
    6: begin GStep := 7;
         Result := RoundOf([OneCall('write_file', ArgsPathContent('index.html',
           '<!DOCTYPE html>'#10'<html><head><title>PasClaw</title></head>'#10 +
           '<body>'#10'<h1>PasClaw</h1>'#10'<p>AI agent in Object Pascal.</p>'#10 +
           '</body></html>'))]); end;
    7: begin           { locate the deliverable: glob if the harness has it }
         if Pos('find_files', EnvJSON) > 0 then
         begin
           GStep := 9;
           Result := RoundOf([OneCall('find_files', '{"pattern":"index.*"}')]);
         end
         else
         begin
           GStep := 8;
           Result := RoundOf([OneCall('list_dir', ArgsObj1('path', '.'))]);
         end;
       end;
    8: begin GStep := 9;   { ladder's second rung (no glob tool) }
         Result := RoundOf([OneCall('list_dir', ArgsObj1('path', '.'))]); end;
    9: begin GStep := 10;  { verify the write: surgical if ranges exist }
         if Pos('start_line', EnvJSON) > 0 then
           Result := RoundOf([OneCall('read_file',
             '{"path":"index.html","start_line":1,"end_line":6}')])
         else
           Result := RoundOf([OneCall('read_file', ArgsPathPlain('index.html'))]);
       end;
    10: begin GStep := 11;
         Result := RoundOf([OneCall('edit_file',
           '{"path":"index.html","old_text":"<title>PasClaw</title>","new_text":"<title>PasClaw v2 -- better than before</title>"}')]); end;
    11: begin            { trust the mini-diff; re-read blind edits }
         if Pos('now reads', LastMsg) > 0 then
         begin
           GStep := 13;
           Result := StopOf('done: index.html built in the workspace with the v2 title.');
         end
         else
         begin
           GStep := 12;
           Result := RoundOf([OneCall('read_file', ArgsPathPlain('index.html'))]);
         end;
       end;
  else
    Result := StopOf('done: index.html built in the workspace with the v2 title.');
  end;
end;

procedure ScenarioRealTask;
{ The original failing prompt, end to end, under a policy model. }
var
  Answer, Deliv: string;
  S: TStringList;
begin
  WriteLn;
  WriteLn('== scenario: real-task (the pasclaw.dev build prompt, end to end) ==');
  ResetScenario(H_RealTask);
  Answer := Chat('[' + MsgObjJSON('user',
    'build a better version of https://pasclaw.dev/ -- ' +
    'https://github.com/fmxexpress/pasclaw/ if you need more feature ' +
    'listings. you can build it using HTML and HTMX if you need to or just ' +
    'vanilla javascript. it could be a single inline file or multiple ' +
    'files. make sure you use the workspace dir to do your work') + ']',
    'bench-realtask');

  Deliv := '';
  if FileExists(GHomeDir + '/workspace/index.html') then
  begin
    S := TStringList.Create;
    try
      S.LoadFromFile(GHomeDir + '/workspace/index.html');
      Deliv := S.Text;
    finally
      S.Free;
    end;
  end;
  { Guard against silently measuring the wrong task: the dump must have
    been written and its body must have reached the model. }
  Check(FileExists(GHomeDir + '/workspace/site-dump.html'),
    'the reference dump was written by the shell step');
  Check(Has(EnvAt(3), 'pasclaw dev site:'),
    'the dump body reached the model in the read result');
  Check(Deliv <> '', 'deliverable index.html exists in the workspace');
  Check(Has(Deliv, 'v2 -- better than before'), 'edit landed (v2 title)');
  Check(Has(Answer, 'done:'), 'turn finished with a final answer');
  Metric('realtask.provider_calls', EnvCount);
  Metric('realtask.total_request_bytes', GTotalBody);
  Metric('realtask.max_request_body_bytes', GMaxBody);
end;

function H_ErrorGuidance(N: Integer; const EnvJSON: string): string;
begin
  case N of
    1: Result := RoundOf([OneCall('read_files', '{"path":"whatever.txt"}')]);   { typo'd tool }
    2: Result := RoundOf([OneCall('read_file', ArgsPathPlain('sub-dir-page.html'))]); { wrong dir }
  else
    Result := StopOf('guidance received.');
  end;
end;

procedure ScenarioErrorGuidance;
{ B3: the errors a model actually loops on must carry the next move --
  through the real gateway dispatch, not just unit-level. }
var
  S: TStringList;
begin
  WriteLn;
  WriteLn('== scenario: error-guidance (errors state the next move) ==');
  ForceDirectories(GHomeDir + '/workspace/pages');
  S := TStringList.Create;
  try
    S.Text := '<p>hi</p>';
    S.SaveToFile(GHomeDir + '/workspace/pages/sub-dir-page.html');
  finally
    S.Free;
  end;
  ResetScenario(H_ErrorGuidance);
  Chat('[' + MsgObjJSON('user', 'open that page file') + ']', 'bench-errs');
  Check(Has(EnvLastMessage(EnvAt(1)), 'did you mean'),
    'unknown tool error suggests similar names');
  Check(Has(EnvLastMessage(EnvAt(1)), 'read_file'),
    'suggestion includes the real tool name');
  Check(Has(EnvLastMessage(EnvAt(2)), 'Did you mean') and
        Has(EnvLastMessage(EnvAt(2)), 'pages/sub-dir-page.html'),
    'no-such-file error names the actual location');
end;

function H_TruncationRecovery(N: Integer; const EnvJSON: string): string;
begin
  case N of
    { Turn 1: narrate the game as prose and emit a malformed function call --
      finish=MALFORMED_FUNCTION_CALL, no usable tool call. This is the exact
      live Gemini 3.5 Flash failure. On main the loop returns this narration
      as the finished answer and no file lands; the fix must retry instead. }
    1: Result := TruncatedOf(
         'Let me build this. ### Player drawing:'#10 +
         'We draw the ship with rotation. ### Bullets:'#10 +
         'procedure DrawBullet(X, Y: Integer);'#10 + 'begin'#10 + '  GotoXY(X, Y);',
         'MALFORMED_FUNCTION_CALL');
    { Turn 2: after the corrective nudge, actually call write_file. }
    2: Result := RoundOf([OneCall('write_file',
         ArgsPathContent('game.pas',
           'program game;'#10 + 'begin'#10 + '  writeln(''ok'');'#10 + 'end.'#10))]);
  else
    Result := StopOf('done: wrote game.pas.');
  end;
end;

procedure ScenarioTruncationRecovery;
{ The live Gemini-3.5-Flash failure: a turn that hits the output-token
  ceiling with no tool call must NOT be treated as a finished answer.
  On main this scenario fails (loop ends at call 1, no file); with the
  recovery it nudges toward tool use, retries, and the file lands. }
var
  Answer, SP1, SP2: string;
begin
  WriteLn;
  WriteLn('== scenario: recovery (finish=MALFORMED_FUNCTION_CALL + no tool call must not end the turn) ==');
  if FileExists(GHomeDir + '/workspace/game.pas') then
    DeleteFile(GHomeDir + '/workspace/game.pas');
  ResetScenario(H_TruncationRecovery);
  Answer := Chat('[' + MsgObjJSON('user',
    'build a small terminal game named game.pas') + ']', 'bench-trunc');

  { Did not terminate on the malformed turn: it retried and delivered. }
  Check(EnvCount = 3, Format('loop recovered across 3 provider calls (got %d)', [EnvCount]));
  { Turn 1 is pristine -- no nudge before the failure happens. }
  SP1 := EnvSystemPrompt(EnvAt(0));
  Check(not Has(SP1, 'no usable tool call'),
    'iteration 1 system prompt carries no recovery nudge yet');
  { Turn 2 (the retry) carries the corrective nudge steering toward tools. }
  SP2 := EnvSystemPrompt(EnvAt(1));
  Check(Has(SP2, 'no usable tool call'),
    'retry system prompt carries the recovery nudge');
  Check(Has(SP2, 'write_file') and Has(SP2, 'append_file'),
    'nudge names the tools to use instead of prose');
  { The truncated prose blob is dropped, not replayed into the retry. }
  Check(not Has(SP2, 'DrawBullet'),
    'the truncated prose is not re-injected into history on retry');
  { The deliverable actually lands, and the final answer is the stop text,
    not the half-written ramble. }
  Check(FileExists(GHomeDir + '/workspace/game.pas'),
    'deliverable written after recovery');
  Check(Has(Answer, 'done:') and not Has(Answer, 'DrawBullet'),
    'final answer is the real result, not the truncated prose');
  Metric('truncrecovery.provider_calls', EnvCount);
end;

function H_HistElide(N: Integer; const EnvJSON: string): string;
begin
  case N of
    { Turn 1: write a big (40 KB) file. Without elision this whole blob is
      replayed in turn 2's history and every turn after. }
    1: Result := RoundOf([OneCall('write_file',
         ArgsPathContent('big.html', StringOfChar('X', 40000)))]);
    { Turn 2: a trivial call so a second request is built (which replays the
      turn-1 write in history). }
    2: Result := RoundOf([OneCall('find_files', '{"pattern":"big.html"}')]);
  else
    Result := StopOf('done: wrote big.html.');
  end;
end;

procedure ScenarioHistoryElision;
{ A model's own large write_file content must NOT be re-shipped verbatim on
  every later turn: the assistant tool-call args are elided to a stub in the
  replayed history, while the FULL content still lands on disk. }
var
  Answer: string;
  S: TStringList;
begin
  WriteLn;
  WriteLn('== scenario: history-elision (large write args not replayed verbatim) ==');
  if FileExists(GHomeDir + '/workspace/big.html') then
    DeleteFile(GHomeDir + '/workspace/big.html');
  ResetScenario(H_HistElide);
  Answer := Chat('[' + MsgObjJSON('user',
    'write a big html file named big.html') + ']', 'bench-elide');

  Check(EnvCount = 3, Format('loop finished in 3 provider calls (got %d)', [EnvCount]));
  { Turn 2's request (EnvAt(1)) replays turn 1's write in history. The 40 KB
    of filler must be gone, replaced by the stub. }
  Check(not Has(EnvAt(1), StringOfChar('X', 5000)),
    'the 40 KB write content is NOT replayed verbatim in turn 2');
  Check(Has(EnvAt(1), 'elided'),
    'the replayed write arg is stubbed with an <elided ...> marker');
  Check(Length(EnvAt(1)) < 20000,
    Format('turn 2 request stays small despite the 40 KB write (%d bytes)',
           [Length(EnvAt(1))]));
  { The real file still got the full content -- dispatch used the real args. }
  Check(FileExists(GHomeDir + '/workspace/big.html'), 'big.html exists on disk');
  S := TStringList.Create;
  try
    S.LoadFromFile(GHomeDir + '/workspace/big.html');
    Check(Length(S.Text) >= 39000,
      Format('the FULL 40 KB landed on disk (%d bytes) -- dispatch unaffected',
             [Length(S.Text)]));
  finally
    S.Free;
  end;
  Metric('histelide.turn2_request_bytes', Length(EnvAt(1)));
end;

{ ---- gateway lifecycle ---------------------------------------------------- }
var
  GW: TProcess;
  Drainer: TThread;

type
  TDrainThread = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TDrainThread.Execute;
{ Keep the gateway's stdout/stderr pipe drained so a chatty log can't fill
  the pipe buffer and block the child. Output is discarded -- the bench's
  own assertions are the signal. }
var
  Buf: array[0..4095] of Byte;
begin
  while (not Terminated) and (GW <> nil) and GW.Running do
  begin
    if GW.Output.NumBytesAvailable > 0 then
      GW.Output.Read(Buf, SizeOf(Buf))
    else
      Sleep(50);
  end;
end;

function WaitHealthy: Boolean;
var
  i: Integer;
  R: THTTPResult;
begin
  Result := False;
  for i := 1 to 40 do
  begin
    Sleep(250);
    R := GetJSONURL(BASE + '/v1/health', [], 2);
    if R.StatusCode = 200 then Exit(True);
  end;
end;

var
  BinPath, CfgJSON, EnvLine: string;
  S: TStringList;
  Worker: TWorkerThread;
  i: Integer;
begin
  BinPath := ExpandFileName('build/pasclaw');
  if GetEnvironmentVariable('BENCH_BIN') <> '' then
    BinPath := GetEnvironmentVariable('BENCH_BIN');
  if not FileExists(BinPath) then
  begin
    WriteLn('build/pasclaw not found -- run `make` first (looked at ', BinPath, ')');
    Halt(2);
  end;

  GHomeDir := IncludeTrailingPathDelimiter(GetTempDir) +
              'agentbench-' + IntToStr(GetProcessID);
  ForceDirectories(GHomeDir + '/workspace');
  CfgJSON :=
    '{"default_provider":"relay","default_model":"sim",' +
    '"providers":[{"name":"relay","kind":"relay","model":"sim"}],' +
    '"gateway":{"bind_addr":"127.0.0.1","port":' + IntToStr(PORT) + '},' +
    '"relay_wait_timeout_ms":3600000,"auto_router":{"enabled":false}}';
  S := TStringList.Create;
  try
    S.Text := CfgJSON;
    S.SaveToFile(GHomeDir + '/config.json');
  finally
    S.Free;
  end;

  GLock := TCriticalSection.Create;
  GW := TProcess.Create(nil);
  Worker := nil;
  Drainer := nil;
  try
    GW.Executable := BinPath;
    GW.Parameters.Add('gateway');
    { #414 review: appending PASCLAW_HOME after copying the caller's env
      produces DUPLICATE entries when the caller has it exported, and
      typical getenv resolution takes the FIRST -- the spawned gateway
      would then run against the user's LIVE PasClaw home instead of the
      throwaway bench home. Skip the caller's PASCLAW_HOME / PASCLAW_CONFIG
      / NO_COLOR while copying so the bench's values are the only ones. }
    for i := 1 to GetEnvironmentVariableCount do
    begin
      EnvLine := GetEnvironmentString(i);
      if (Pos('PASCLAW_HOME=', EnvLine) = 1) or
         (Pos('PASCLAW_CONFIG=', EnvLine) = 1) or
         (Pos('NO_COLOR=', EnvLine) = 1) then Continue;
      GW.Environment.Add(EnvLine);
    end;
    GW.Environment.Add('PASCLAW_HOME=' + GHomeDir);
    GW.Environment.Add('NO_COLOR=1');
    GW.Options := [poUsePipes, poStderrToOutPut];
    GW.Execute;
    Drainer := TDrainThread.Create(False);

    if not WaitHealthy then
    begin
      WriteLn('gateway did not come up on ', BASE);
      Halt(2);
    end;
    Worker := TWorkerThread.Create(False);
    Sleep(500);

    ScenarioBuildSite;
    ScenarioMalformedRecovery;
    ScenarioResumeAfterCap;
    ScenarioFatRead;
    ScenarioRepeatRead;
    ScenarioRealTask;
    ScenarioErrorGuidance;
    ScenarioTruncationRecovery;
    ScenarioHistoryElision;

    WriteLn;
    WriteLn('== metrics ==');
    for i := 0 to High(GMetrics) do WriteLn('  ' + GMetrics[i]);
    if Length(GFailures) > 0 then
    begin
      WriteLn;
      WriteLn(Format('FAIL (%d):', [Length(GFailures)]));
      for i := 0 to High(GFailures) do WriteLn('  - ' + GFailures[i]);
      ExitCode := 1;
    end
    else
    begin
      WriteLn;
      WriteLn('PASS: all agent-loop scenarios green');
      ExitCode := 0;
    end;
  finally
    if Worker <> nil then Worker.Terminate;
    if Drainer <> nil then Drainer.Terminate;
    if GW.Running then GW.Terminate(0);
    GW.Free;
    { Worker/Drainer block in socket reads/sleeps; the process exit reaps
      them -- same teardown posture as the TUI's bounded-wait threads. }
  end;
end.
