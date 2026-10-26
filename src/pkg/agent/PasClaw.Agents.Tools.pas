(*
  PasClaw.Agents.Tools - the model-callable `agent` tool.

  One tool, not four, because a tool list is prompt budget -- the same
  call the `project` and `task` tools make:

    agent action = list | create | get | delete | send | inbox

  `send` is the one that matters. It is how a lead tells a project lead
  what changed, how a project lead hands an IC its next piece, and how
  either reports back -- and it reaches an agent that is CURRENTLY
  WORKING, through the steering queue, rather than waiting for it to
  finish. See PasClaw.Agents for why that is one mechanism and not two.

  Deliberately NOT here: starting a turn on another agent's behalf.
  Delivery and execution are different questions -- an agent that could
  make another agent run would need a whole scheduling policy to stop
  two of them driving the same session at once, and the session turn
  lock only serialises turns, it does not decide who may start one.
  Phase 3 owns that; this tool stops at the mailbox.

  tcMutating: every action but list/get/inbox writes under the active
  workspace.
*)
unit PasClaw.Agents.Tools;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

interface

uses
  PasClaw.Tools.Registry;

procedure RegisterAgentTools(R: TToolRegistry);

(* Who is calling, for THIS thread.

   A `send` with no explicit "from" is attributed to whoever the runner
   says is running -- so an agent messaging a colleague is recorded as
   itself rather than as the operator. Set by the agent runner around a
   turn and cleared after.

   A THREADVAR, not a global: up to MaxConcurrentAgentRuns turns run at
   once, and a shared global would attribute one agent's message to
   whichever other agent happened to start last. Same reason the
   workspace pin is per-thread. *)
procedure SetCallingAgent(const Name: string);

(* The agent this thread is running a turn for; '' outside one.

   Read by the `task` tool, whose review rules turn on who is asking: a
   builder may not give the verdict on its own work. Mutating tools
   dispatch inline on the loop thread (PasClaw.Tools.ToolLoop gives each a
   batch of one), which is the thread the agent runner set this on.
   Anywhere else -- a parallel worker, a background subagent's own thread
   -- it reads '', and the task tool treats '' as "cannot tell", never as
   the operator. *)
function CallingAgent: string;

{ The handler, exposed for tests. }
function Tool_Agent(const ArgsJSON: string; out ErrMsg: string): string;

implementation

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.Tools.Types,
  PasClaw.JSON,
  PasClaw.Config,           { decisions.channel }
  PasClaw.Logger,
  PasClaw.Agents,
  PasClaw.Decisions,        { ask_operator }
  PasClaw.Projects.Store,   { the task a question blocks }
  PasClaw.Tools.SendMessage; { PostToChannel -- decisions off the desk }

const
  AgentSchema =
    '{"type":"object","properties":{' +
    '"action":{"type":"string","enum":["list","create","get","delete","send","inbox","ask_operator"]},' +
    '"question":{"type":"string","description":"what only a person can decide (ask_operator)"},' +
    '"choices":{"type":"array","items":{"type":"string"},"description":"the answers you can act on, e.g. [\"yes\",\"no\"] (ask_operator; optional)"},' +
    '"project":{"type":"string","description":"project the question is about (ask_operator; optional)"},' +
    '"task":{"type":"string","description":"task it holds up -- blocked until answered (ask_operator; optional)"},' +
    '"name":{"type":"string","description":"the agent to act on"},' +
    '"title":{"type":"string","description":"human label (create)"},' +
    '"role":{"type":"string","description":"what this agent is for (create)"},' +
    '"model":{"type":"string","description":"model override; empty inherits (create)"},' +
    '"parent":{"type":"string","description":"the agent it reports to (create)"},' +
    '"from":{"type":"string","description":"who is sending; defaults to the caller (send)"},' +
    '"text":{"type":"string","description":"the message (send)"},' +
    '"limit":{"type":"integer","description":"how many messages to read (inbox)"}' +
    '},"required":["action"]}';

{ The name of the agent whose loop is making this call, when the runner
  set one. Without it a `send` is attributed to 'operator', which is
  honest -- an unattributed message should not claim to be from an
  agent. }
threadvar
  GCallerAgent: string;

procedure SetCallingAgent(const Name: string);
begin
  GCallerAgent := Name;
end;

function IfThenStr(Cond: Boolean; const Yes, No: string): string;
begin
  if Cond then Result := Yes else Result := No;
end;

(* A new decision goes off the desk too: to decisions.channel, when the
   operator named one, so the question reaches a phone and not only an
   open desktop. Best effort -- the decision exists either way. *)
procedure NotifyDecisionChannel(const D: TDecisionInfo);
var
  Cfg: TConfig;
  Channel, Err: string;
begin
  Cfg := LoadEffectiveConfig;
  try
    Channel := Cfg.DecisionsChannel;
  finally
    Cfg.Free;
  end;
  if Channel = '' then Exit;
  if not PostToChannel(Channel,
           'PasClaw needs you -- ' + DecisionSummary(D) + #10 +
           'Reply "' + D.Id + ' <answer>" in a chat with the bot, or answer ' +
           'it on the desktop (Needs you).', Err) then
    LogWarn('decisions: could not post %s to channel %s: %s', [D.Id, Channel, Err]);
end;

(* The answer goes where the asker reads first -- its mailbox, which also
   wakes it -- and the task the question blocked goes back to what it was
   doing. A rule's approval is Phase 4's listener; this one still tells
   whoever proposed it. *)
procedure DeliverDecisionAnswer(const D: TDecisionInfo);
var
  T: TTaskInfo;
  Delivered, Err, Back: string;
begin
  if D.AskedBy <> '' then
    AgentSend(D.AskedBy, 'operator',
              'Operator decided ' + D.Id + ' ("' + D.Question + '"): ' +
              D.Answer, Delivered, Err);
  if (D.Task = '') or (D.Project = '') then Exit;
  if not GetTask(D.Project, D.Task, T) or (T.Status <> tsBlocked) then Exit;
  if (D.TaskStatusBefore = 'active') or (D.TaskStatusBefore = 'todo') then
    Back := D.TaskStatusBefore
  else
    Back := 'todo';
  UpdateTask(D.Project, D.Task, '', '-', Back, Err);
end;

function CallingAgent: string;
begin
  Result := GCallerAgent;
end;

function AgentJSON(const Info: TAgentInfo): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr('name',    Info.Name);
  Result.PutStr('title',   Info.Title);
  Result.PutStr('role',    Info.Role);
  if Info.Model  <> '' then Result.PutStr('model',  Info.Model);
  if Info.Parent <> '' then Result.PutStr('parent', Info.Parent);
  Result.PutStr('session', AgentSessionId(Info.Name));
  Result.PutStr('created', Info.Created);
  Result.PutStr('updated', Info.Updated);
  { Live facts, not stored ones: whether it is working right now and how
    much is waiting for it. A roster without these is a list of names. }
  Result.PutBool('busy',    AgentIsBusy(Info.Name));
  Result.PutInt ('pending', AgentPending(Info.Name));
  { Run state: what the runner last wrote, plus how long ago -- the two
    numbers a roster (and a supervisor) actually reads. }
  Result.PutStr('run_state', Info.RunState);
  if Info.RunStart <> '' then Result.PutStr('run_start', Info.RunStart);
  if Info.RunEnd   <> '' then Result.PutStr('run_end',   Info.RunEnd);
  if Info.RunNote  <> '' then Result.PutStr('run_note',  Info.RunNote);
  Result.PutInt ('idle_minutes', AgentIdleMinutes(Info.Name));
end;

(* ask_operator: a question only a person can answer.

   Only the top of a reporting chain asks. An agent with a parent has its
   question delivered to the parent's mailbox, marked as an escalation:
   the parent decides, or escalates in turn. Held here, by the tool,
   rather than asked of the role prompt -- which is how "only your
   decisions reach you" stays true when twelve agents are working.

   A question about a task blocks the task until the answer comes, and
   the decision remembers what status to put it back to. *)
function AskOperator(Args: TJsonObject; out ErrMsg: string): string;
var
  Info: TAgentInfo;
  Caller, Question, Project, TaskId, Before, Id, Text, Delivered, Err, Notes: string;
  Choices: TStringArray;
  Arr: TJsonArray;
  T: TTaskInfo;
  Root: TJsonObject;
  I: Integer;
begin
  ErrMsg := '';
  Result := '';
  Caller := GCallerAgent;
  if Caller = '' then
  begin
    ErrMsg := 'ask_operator is for standing agents, and this turn is not ' +
              'one -- you are already talking with the operator, so ask ' +
              'them in your reply.';
    Exit;
  end;
  Question := Trim(Args.GetStr('question', Args.GetStr('text', '')));
  if Question = '' then
  begin
    ErrMsg := 'ask_operator needs a "question"';
    Exit;
  end;
  SetLength(Choices, 0);
  Arr := Args.ChildArray('choices');
  if Arr <> nil then
  try
    for I := 0 to Arr.Count - 1 do
      if Trim(Arr.ItemStr(I)) <> '' then
      begin
        SetLength(Choices, Length(Choices) + 1);
        Choices[High(Choices)] := Trim(Arr.ItemStr(I));
      end;
  finally
    Arr.Free;
  end;
  Project := Trim(Args.GetStr('project', ''));
  TaskId  := UpperCase(Trim(Args.GetStr('task', '')));

  if GetAgent(Caller, Info) and (Info.Parent <> '') then
  begin
    Text := '[escalation] ' + Caller + ' needs a decision: ' + Question;
    if Length(Choices) > 0 then
    begin
      Text := Text + ' (choices:';
      for I := 0 to High(Choices) do Text := Text + ' ' + Choices[I];
      Text := Text + ')';
    end;
    if TaskId <> '' then Text := Text + ' [task ' + TaskId + ' on ' + Project + ']';
    Text := Text + #10'Decide it and message ' + Caller + ' back (agent ' +
            'action=send), or -- if it is the operator''s call -- ask them ' +
            'yourself with agent action=ask_operator.';
    if not AgentSend(Info.Parent, Caller, Text, Delivered, Err) then
    begin
      ErrMsg := 'ask_operator: could not reach ' + Info.Parent + ': ' + Err;
      Exit;
    end;
    Root := TJsonObject.Create;
    try
      Root.PutStr('escalated_to', Info.Parent);
      Root.PutStr('note', 'You report to ' + Info.Parent + ', so the question ' +
                  'went to them, not to the operator. Their answer arrives ' +
                  'in your mailbox.');
      Result := Root.ToJSON;
    finally
      Root.Free;
    end;
    Exit;
  end;

  Before := '';
  if TaskId <> '' then
  begin
    if not GetTask(Project, TaskId, T) then
    begin
      ErrMsg := 'ask_operator: no such task ' + Project + '/' + TaskId;
      Exit;
    end;
    Before := TaskStatusToStr(T.Status);
  end;
  Id := CreateDecision('question', Caller, Question, Choices, Project, TaskId,
                       Before, '', Err);
  if Id = '' then
  begin
    ErrMsg := 'ask_operator: ' + Err;
    Exit;
  end;
  { Only work that is waiting to be done is blocked; a task in review or
    done is left alone -- the question is about it, not holding it up. }
  if (TaskId <> '') and (T.Status in [tsTodo, tsActive]) then
  begin
    Notes := TrimRight(T.Notes);
    if Notes <> '' then Notes := Notes + #10;
    UpdateTask(Project, TaskId, '', Notes + '[waiting on the operator: ' + Id +
               ' -- ' + Question + ']', 'blocked', Err, '-', '-', Caller);
  end;
  Root := TJsonObject.Create;
  try
    Root.PutStr('decision', Id);
    Root.PutStr('note', 'The operator has it (Needs you on the desktop, and ' +
                'the decisions channel when one is set). The answer arrives in ' +
                'your mailbox' + IfThenStr(TaskId <> '', '; ' + TaskId +
                ' is blocked until then.', '.'));
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function Tool_Agent(const ArgsJSON: string; out ErrMsg: string): string;
var
  Args, Root, Item: TJsonObject;
  Arr: TJsonArray;
  Action, Name, Delivered, Err: string;
  Info: TAgentInfo;
  Rows: TAgentInfoArray;
  Msgs: TAgentMessageArray;
  I, Limit: Integer;
begin
  ErrMsg := '';
  Result := '';
  try
    Args := TJsonObject.Parse(ArgsJSON);
  except
    ErrMsg := 'agent: arguments are not valid JSON';
    Exit;
  end;
  try
    Action := LowerCase(Trim(Args.GetStr('action', '')));
    Name   := Trim(Args.GetStr('name', ''));

    if Action = 'list' then
    begin
      Rows := ListAgents;
      Root := TJsonObject.Create;
      try
        Arr := TJsonArray.Create;
        for I := 0 to High(Rows) do
        begin
          Item := AgentJSON(Rows[I]);
          Arr.AddObject(Item);
        end;
        Root.PutArray('agents', Arr);
        Result := Root.ToJSON;
      finally
        Root.Free;
      end;
      Exit;
    end;

    if Action = 'create' then
    begin
      if Name = '' then
      begin
        ErrMsg := 'agent create: needs a name';
        Exit;
      end;
      Info.Name   := Name;
      Info.Title  := Args.GetStr('title', Name);
      Info.Role   := Args.GetStr('role', '');
      Info.Model  := Args.GetStr('model', '');
      Info.Parent := Args.GetStr('parent', '');
      Name := SaveAgent(Info, Err);
      if Name = '' then
      begin
        ErrMsg := 'agent create: ' + Err;
        Exit;
      end;
      if not GetAgent(Name, Info) then
      begin
        ErrMsg := 'agent create: wrote ' + Name + ' but cannot read it back';
        Exit;
      end;
      Root := AgentJSON(Info);
      try
        Result := Root.ToJSON;
      finally
        Root.Free;
      end;
      Exit;
    end;

    if (Action = 'get') or (Action = 'inbox') then
    begin
      if not GetAgent(Name, Info) then
      begin
        ErrMsg := 'no such agent: ' + Name;
        Exit;
      end;
      Root := AgentJSON(Info);
      try
        if Action = 'inbox' then
        begin
          Limit := Integer(Args.GetInt('limit', 20));
          if Limit < 0 then Limit := 0;
          Msgs := AgentMessages(Info.Name, Limit);
          Arr := TJsonArray.Create;
          for I := 0 to High(Msgs) do
          begin
            Item := TJsonObject.Create;
            Item.PutStr('at',        Msgs[I].At);
            Item.PutStr('from',      Msgs[I].From);
            Item.PutStr('text',      Msgs[I].Text);
            Item.PutStr('delivered', Msgs[I].Delivered);
            Arr.AddObject(Item);
          end;
          Root.PutArray('messages', Arr);
        end;
        Result := Root.ToJSON;
      finally
        Root.Free;
      end;
      Exit;
    end;

    if Action = 'delete' then
    begin
      if not DeleteAgent(Name, Err) then
      begin
        ErrMsg := 'agent delete: ' + Err;
        Exit;
      end;
      Root := TJsonObject.Create;
      try
        Root.PutBool('deleted', True);
        Root.PutStr('name', Name);
        Result := Root.ToJSON;
      finally
        Root.Free;
      end;
      Exit;
    end;

    if Action = 'send' then
    begin
      if not AgentSend(Name, Args.GetStr('from', GCallerAgent),
                       Args.GetStr('text', ''), Delivered, Err) then
      begin
        ErrMsg := 'agent send: ' + Err;
        Exit;
      end;
      Root := TJsonObject.Create;
      try
        Root.PutStr('to', Name);
        Root.PutStr('delivered', Delivered);
        { Say what the wording MEANS. "queued" reads like a failure to a
          model that expected an answer, and it is not one -- it is the
          normal case for an agent that is not currently working. }
        if Delivered = 'mid-turn' then
          Root.PutStr('note', 'the agent is working; it will see this ' +
                              'between tool calls')
        else
          Root.PutStr('note', 'the agent is idle; it will see this at the ' +
                              'start of its next turn');
        Result := Root.ToJSON;
      finally
        Root.Free;
      end;
      Exit;
    end;

    if Action = 'ask_operator' then
    begin
      Result := AskOperator(Args, ErrMsg);
      Exit;
    end;

    ErrMsg := 'agent: unknown action "' + Action +
              '" (list | create | get | delete | send | inbox | ask_operator)';
  finally
    Args.Free;
  end;
end;

procedure RegisterAgentTools(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;
  FillChar(T, SizeOf(T), 0);
  T.Name        := 'agent';
  T.Description :=
    'Standing agents and the messages between them. ' +
    'list | create | get | delete | send | inbox | ask_operator. ' +
    'An agent is a name, a role and a durable session -- it survives ' +
    'restarts, unlike a spawned subagent. `send` reaches an agent that ' +
    'is working right now (it sees the message between tool calls) as ' +
    'well as one that is idle (it sees it next turn). `ask_operator` ' +
    'raises a question only a person can decide; if you report to ' +
    'someone it goes to them first.';
  T.Schema      := AgentSchema;
  T.Handler     := Tool_Agent;
  T.Category    := tcMutating;
  R.Register(T);
end;

initialization
  AddDecisionCreatedListener(NotifyDecisionChannel);
  AddDecisionAnsweredListener(DeliverDecisionAnswer);

end.
