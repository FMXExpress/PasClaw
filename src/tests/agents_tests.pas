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

procedure TestRunStateAndSupervision;
var
  Err: string;
  Info: TAgentInfo;
  V: TAgentVerdictArray;
  I: Integer;
  FoundDead, FoundOk: Boolean;
begin
  WriteLn('-- run state, and what a supervisor can actually know');
  SaveAgent(MakeAgent('worker', 'Worker', 'Does the work',
                      'payments-tech-lead'), Err);
  GetAgent('worker', Info);
  AssertEqStr(Info.RunState, 'idle', 'a fresh agent is idle');
  AssertEqInt(AgentIdleMinutes('worker'), -1,
              'and has no idle age until it has run');

  MarkAgentRunStarted('worker');
  GetAgent('worker', Info);
  AssertEqStr(Info.RunState, 'running', 'starting a run is recorded');
  AssertTrue(Info.RunStart <> '', 'with when it started');
  AssertEqStr(Info.RunEnd, '', 'and no end yet');

  { An ordinary edit must not reset a run in progress -- the runner owns
    run state, and a role reworded mid-run is not a reason to forget the
    agent is working. }
  SaveAgent(MakeAgent('worker', 'Worker', 'Does the work, carefully',
                      'payments-tech-lead'), Err);
  GetAgent('worker', Info);
  AssertEqStr(Info.RunState, 'running',
              'an unrelated edit carries run state through');
  AssertEqStr(Info.Role, 'Does the work, carefully', 'while taking the edit');

  (* The verdict that matters: the manifest says `running`, but nothing
     holds the session's turn lock. In a test process nothing ever does,
     which is exactly the state a crashed run leaves behind. *)
  V := SuperviseAgents(0, 0);
  FoundDead := False; FoundOk := False;
  for I := 0 to High(V) do
  begin
    if (V[I].Name = 'worker') and (V[I].Action = 'restart') then
    begin
      FoundDead := True;
      AssertTrue(Pos('no turn in flight', V[I].Why) > 0,
                 'and says why: the process that owned it is gone');
    end;
    if (V[I].Name = 'payments-tech-lead') and (V[I].Action = 'ok') then
      FoundOk := True;
  end;
  AssertTrue(FoundDead, 'a run left behind by a dead process is spotted');
  AssertTrue(FoundOk, 'an agent that never ran is left alone');

  MarkAgentRunFinished('worker', 'failed', 'provider refused');
  GetAgent('worker', Info);
  AssertEqStr(Info.RunState, 'failed', 'a failure is recorded');
  AssertEqStr(Info.RunNote, 'provider refused', 'with the reason');
  AssertTrue(AgentIdleMinutes('worker') >= 0,
             'and the clock starts from when it ended');

  V := SuperviseAgents(0, 0);
  FoundDead := False;
  for I := 0 to High(V) do
    if (V[I].Name = 'worker') and (V[I].Action = 'restart') then FoundDead := True;
  AssertTrue(FoundDead, 'a failed run is a restart too');

  MarkAgentRunFinished('worker', 'done', 'all good');
  V := SuperviseAgents(0, 0);
  FoundOk := False;
  for I := 0 to High(V) do
    if (V[I].Name = 'worker') and (V[I].Action = 'ok') then FoundOk := True;
  AssertTrue(FoundOk, 'a healthy agent is left alone');

  { IdleMinutes=1 with a just-finished run must NOT fire: the run ended
    seconds ago. This is the guard against a supervisor that churns a
    working organisation every sweep. }
  V := SuperviseAgents(0, 1);
  FoundOk := False;
  for I := 0 to High(V) do
    if (V[I].Name = 'worker') and (V[I].Action = 'ok') then FoundOk := True;
  AssertTrue(FoundOk, 'an agent that just ran is not nudged for idleness');
end;

procedure TestNotifyParent;
var
  Msgs: TAgentMessageArray;
begin
  WriteLn('-- telling the parent');
  AssertTrue(NotifyParent('worker', 'I fell over'),
             'a report with a parent notifies it');
  Msgs := AgentMessages('payments-tech-lead', 0);
  AssertTrue((Length(Msgs) > 0) and (Msgs[High(Msgs)].From = 'worker'),
             'the parent hears from the agent by name');
  AssertTrue(not NotifyParent('payments-tech-lead', 'anything'),
             'a top-level agent has nobody to tell, and says so rather ' +
             'than inventing a recipient');
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
  TestRunStateAndSupervision;
  TestNotifyParent;
  TestDelete;
  if Failures > 0 then
  begin
    WriteLn(Format('agents_tests: %d failure(s)', [Failures]));
    Halt(1);
  end;
  WriteLn('agents_tests: OK');
end.
