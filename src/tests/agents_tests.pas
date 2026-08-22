program agents_tests;
(*
  Covers PasClaw.Agents -- the durable agent roster and the mailbox
  agents reach each other through.

  What is actually being asserted, in the order it matters:

    - an agent SURVIVES: the manifest is on disk and reads back after
      the store has forgotten everything in memory (this is the whole
      difference between an agent and a spawned subagent).
    - created is preserved across an update, updated is not.
    - a message is RECORDED before it is queued, and the record
      outlives the queue being drained -- "who told whom what" is the
      accountability half and it must not vanish when the message is
      consumed.
    - delivery lands in the target's steering queue under its OWN
      session id, which is what makes an idle agent see it next turn
      and a working one see it mid-turn.
    - the record survives a drain; the queue does not.
    - names are slugged and traversal-proof, and an agent cannot be
      made to report to itself.

  Runs against a temp PASCLAW_HOME; no network, no gateway.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.Workspaces,
  PasClaw.Agent.Steering,
  PasClaw.Agents;

var
  Failures: Integer = 0;

procedure Fail(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Inc(Failures);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok: ' + Msg) else Fail(Msg);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got = Want then WriteLn('  ok: ' + Msg)
  else Fail(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin
  if Got = Want then WriteLn('  ok: ' + Msg)
  else Fail(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')');
end;

function MakeAgent(const Name, Title, Role, Parent: string): TAgentInfo;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Name   := Name;
  Result.Title  := Title;
  Result.Role   := Role;
  Result.Model  := '';
  Result.Parent := Parent;
end;

procedure TestCreateAndSurvive;
var
  Info: TAgentInfo;
  Slug, Err, Created: string;
begin
  WriteLn('-- an agent is a file, not a thread');
  Slug := SaveAgent(MakeAgent('Payments Tech Lead', 'Payments tech lead',
                              'Owns the payments service', ''), Err);
  AssertEqStr(Slug, 'payments-tech-lead', 'the name is slugged');
  AssertEqStr(Err, '', 'no error creating');

  { Read it back through a fresh call -- nothing is cached in memory,
    so this is the on-disk manifest answering. }
  AssertTrue(GetAgent('payments-tech-lead', Info), 'it reads back');
  AssertEqStr(Info.Title, 'Payments tech lead', 'the title round-trips');
  AssertEqStr(Info.Role, 'Owns the payments service', 'the role round-trips');
  AssertEqStr(AgentSessionId('payments-tech-lead'), 'agent-payments-tech-lead',
              'its session id is derived, and is an ordinary session id');
  Created := Info.Created;
  AssertTrue(Created <> '', 'it records when it was created');

  { An update must not reset the agent's age. }
  Sleep(1100);   { NowIsoUtc has second resolution }
  Slug := SaveAgent(MakeAgent('payments-tech-lead', 'Payments lead',
                              'Owns payments and billing', ''), Err);
  AssertEqStr(Slug, 'payments-tech-lead', 'updating keeps the slug');
  GetAgent('payments-tech-lead', Info);
  AssertEqStr(Info.Created, Created, 'created is preserved across an update');
  AssertTrue(Info.Updated <> Created, 'updated moved');
  AssertEqStr(Info.Title, 'Payments lead', 'the update took');
end;

procedure TestRoster;
var
  Rows: TAgentInfoArray;
  Err: string;
  I: Integer;
  FoundLead, FoundIC: Boolean;
begin
  WriteLn('-- the roster');
  SaveAgent(MakeAgent('IC One', 'IC one', 'Writes the code',
                      'payments-tech-lead'), Err);
  Rows := ListAgents;
  FoundLead := False; FoundIC := False;
  for I := 0 to High(Rows) do
  begin
    if Rows[I].Name = 'payments-tech-lead' then FoundLead := True;
    if Rows[I].Name = 'ic-one' then
    begin
      FoundIC := True;
      AssertEqStr(Rows[I].Parent, 'payments-tech-lead',
                  'an IC records who it reports to');
    end;
  end;
  AssertTrue(FoundLead and FoundIC, 'both agents are listed');
end;

procedure TestSendRecordsThenQueues;
var
  Delivered, Err: string;
  Msgs: TAgentMessageArray;
  Sid: string;
begin
  WriteLn('-- a message is recorded, then queued');
  Sid := AgentSessionId('ic-one');
  AssertEqInt(PendingSteeringCount(Sid), 0, 'the queue starts empty');

  AssertTrue(AgentSend('ic-one', 'payments-tech-lead',
                       'Pick up the refund bug next', Delivered, Err),
             'the send succeeds');
  AssertEqStr(Err, '', 'no error');
  { Nothing is running in a test process, so the honest answer is
    "queued" -- and the wording is part of the contract: it tells the
    sender the target will see this next turn, not this second. }
  AssertEqStr(Delivered, 'queued', 'an idle agent is told the truth: queued');
  AssertEqInt(AgentPending('ic-one'), 1, 'one message is waiting');

  Msgs := AgentMessages('ic-one', 0);
  AssertEqInt(Length(Msgs), 1, 'the record has one line');
  AssertEqStr(Msgs[0].From, 'payments-tech-lead', 'the record names the sender');
  AssertEqStr(Msgs[0].Text, 'Pick up the refund bug next', 'and what was said');
  AssertEqStr(Msgs[0].Delivered, 'queued', 'and how it went');
end;

procedure TestDeliveryLandsInTheRightQueue;
var
  Steers: TSteeringMessageArray;
  Delivered, Err: string;
  Msgs: TAgentMessageArray;
begin
  WriteLn('-- the queue drains into the agent, and the record stays');
  { This is the delivery path the tool loop takes: it drains the
    steering key equal to the session id it is running. Draining here
    proves an agent's next turn would receive the message. }
  Steers := DrainSteering(AgentSessionId('ic-one'), 8);
  AssertEqInt(Length(Steers), 1, 'the agent-s session queue holds the message');
  AssertTrue(Pos('Pick up the refund bug next', Steers[0].Text) > 0,
             'the text arrives intact');
  AssertTrue(Pos('payments-tech-lead', Steers[0].Text) > 0,
             'the envelope names the sender, so an instruction arriving ' +
             'mid-turn is attributed rather than anonymous');

  AssertEqInt(AgentPending('ic-one'), 0, 'the queue is consumed by the drain');
  Msgs := AgentMessages('ic-one', 0);
  AssertEqInt(Length(Msgs), 1,
              'but the RECORD survives the drain -- accountability outlives ' +
              'delivery');

  { A second message after a drain appends rather than replaces. }
  AgentSend('ic-one', 'operator', 'And update the runbook', Delivered, Err);
  Msgs := AgentMessages('ic-one', 0);
  AssertEqInt(Length(Msgs), 2, 'the record appends');
  AssertEqStr(Msgs[1].From, 'operator',
              'a sender that is not an agent is recorded as itself');
end;

procedure TestLimitAndUnknown;
var
  Msgs: TAgentMessageArray;
  Delivered, Err: string;
begin
  WriteLn('-- reading and refusing');
  Msgs := AgentMessages('ic-one', 1);
  AssertEqInt(Length(Msgs), 1, 'a limit returns the newest N');
  AssertEqStr(Msgs[0].Text, 'And update the runbook', 'newest last');

  AssertTrue(not AgentSend('no-such-agent', 'operator', 'hello',
                           Delivered, Err),
             'sending to an unknown agent fails');
  AssertTrue(Pos('no such agent', Err) > 0, 'and says so');

  AssertTrue(not AgentSend('ic-one', 'operator', '   ', Delivered, Err),
             'an empty message is refused');
end;

procedure TestNameSafety;
var
  Err: string;
  Info: TAgentInfo;
begin
  WriteLn('-- names cannot escape the agents directory');
  AssertEqStr(AgentSlug('../../etc/passwd'), 'etc-passwd',
              'traversal is slugged away');
  AssertEqStr(AgentSlug('  '), '', 'nothing usable gives nothing');
  AssertEqStr(SaveAgent(MakeAgent('   ', '', '', ''), Err), '',
              'an unusable name is refused');
  AssertTrue(Err <> '', 'and says why');

  AssertEqStr(SaveAgent(MakeAgent('loopy', 'Loopy', '', 'loopy'), Err), '',
              'an agent cannot report to itself');
  AssertTrue(not GetAgent('loopy', Info), 'and was not created');
end;

procedure TestDelete;
var
  Err, Delivered: string;
  Info: TAgentInfo;
begin
  WriteLn('-- retiring an agent');
  AgentSend('ic-one', 'operator', 'one last thing', Delivered, Err);
  AssertTrue(AgentPending('ic-one') > 0, 'something is queued');
  AssertTrue(DeleteAgent('ic-one', Err), 'delete succeeds');
  AssertTrue(not GetAgent('ic-one', Info), 'the agent is gone');
  AssertEqInt(AgentPending('ic-one'), 0,
              'and anything still queued went with it, rather than waiting ' +
              'to be folded into whatever reuses the name');
  AssertTrue(not DeleteAgent('ic-one', Err), 'deleting twice reports honestly');
end;

begin
  WriteLn('agents_tests');
  SetThreadWorkspace('workspace');
  TestCreateAndSurvive;
  TestRoster;
  TestSendRecordsThenQueues;
  TestDeliveryLandsInTheRightQueue;
  TestLimitAndUnknown;
  TestNameSafety;
  TestDelete;
  if Failures > 0 then
  begin
    WriteLn(Format('agents_tests: %d failure(s)', [Failures]));
    Halt(1);
  end;
  WriteLn('agents_tests: OK');
end.
