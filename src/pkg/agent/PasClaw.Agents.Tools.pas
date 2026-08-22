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

{ The handler, exposed for tests. }
function Tool_Agent(const ArgsJSON: string; out ErrMsg: string): string;

implementation

uses
  SysUtils,
  PasClaw.Tools.Types,
  PasClaw.JSON,
  PasClaw.Agents;

const
  AgentSchema =
    '{"type":"object","properties":{' +
    '"action":{"type":"string","enum":["list","create","get","delete","send","inbox"]},' +
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
var
  GCallerAgent: string = '';

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

    ErrMsg := 'agent: unknown action "' + Action +
              '" (list | create | get | delete | send | inbox)';
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
    'list | create | get | delete | send | inbox. ' +
    'An agent is a name, a role and a durable session -- it survives ' +
    'restarts, unlike a spawned subagent. `send` reaches an agent that ' +
    'is working right now (it sees the message between tool calls) as ' +
    'well as one that is idle (it sees it next turn).';
  T.Schema      := AgentSchema;
  T.Handler     := Tool_Agent;
  T.Category    := tcMutating;
  R.Register(T);
end;

end.
