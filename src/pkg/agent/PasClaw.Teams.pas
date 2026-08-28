(*
  PasClaw.Teams -- ready-made agent teams.

  A team template is a catalogue entry (or a user file): a set of agents
  with roles and reporting lines, one kickoff message, and a wake
  schedule. `team up` seeds the agents the way SeedSuite seeds apps --
  idempotently, skipping and REPORTING anything the operator already
  owns -- then points the team at work (a goal, or an existing project's
  task board) and leaves a state file the gateway's tick loop reads to
  keep the team moving without a human poking it.

  Everything here is deliberately free of gateway types: seeding,
  validation, state and the wake DECISIONS are plain functions over the
  agents/projects stores, so teams_tests pins them without a server.
  Starting a run is the gateway's job (it owns the runner callback);
  this unit only ever answers "who should be woken, and why".

  See docs/agent-teams-plan.md for the design story.
*)
unit PasClaw.Teams;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

interface

uses
  PasClaw.Utils,
  PasClaw.Agents;

type
  TTeamAgent = record
    Name:   string;   { slug, validated by AgentSlug rules }
    Title:  string;
    Role:   string;   { the full role prompt }
    (* A model TIER, not a model id: '' inherits the runner's default,
       'fast' asks for the cheap tier. Never a literal model name --
       a template outlives any model id it could have pinned. *)
    Model:  string;
    Parent: string;   { must name another agent in the SAME template }
  end;
  TTeamAgentArray = array of TTeamAgent;

  TTeamTemplate = record
    Name:        string;
    Title:       string;
    Description: string;
    Agents:      TTeamAgentArray;
    (* Sent to each top-level agent when the team is pointed at work.
       '{{goal}}' and '{{project}}' are filled in at up-time. *)
    Kickoff:     string;
    (* Wake cadence in minutes; 0 = never wake on a clock (the team
       only moves when messaged or run by hand). *)
    WakeMinutes: Integer;
    (* Which agents the tick CONSIDERS. Empty = every agent in the
       template, which is the right default and was not the first
       one: with only the lead on this list, a worker holding an
       assigned task never ran, because the lead cannot start another
       agent's turn (deliberately -- see agents.md) and nothing else
       was looking. Being on the list costs nothing; each agent is
       still gated on having a reason to run. *)
    WakeWho:     TStringArray;
    Exists:      Boolean;
  end;
  TTeamTemplateArray = array of TTeamTemplate;

  (* One running (or parked) team in the active workspace. State lives
     at workspace/teams/state/<name>.json so a gateway restart forgets
     nothing -- the same reason agents keep run state on disk. *)
  TTeamState = record
    Name:        string;   { template name; one live team per template }
    Project:     string;   { the board this team works }
    Goal:        string;
    Enabled:     Boolean;  { False = parked: agents stay, nothing wakes }
    WakeMinutes: Integer;
    WakeWho:     TStringArray;
    LastTick:    string;   { ISO-8601 UTC }
    (* Consecutive ticks the board has been fully done. At 2 the tick
       loop parks the team by itself -- a finished team that keeps
       being woken is a bill, not a team. *)
    DoneTicks:   Integer;
    Created:     string;
    Updated:     string;
    Exists:      Boolean;
  end;
  TTeamStateArray = array of TTeamState;

  (* Why an agent is (or is not) being woken -- returned so the tick
     can log and tests can pin the reasoning, not just the outcome. *)
  TWakeReason = record
    Agent:   string;
    Wake:    Boolean;
    Why:     string;
  end;
  TWakeReasonArray = array of TWakeReason;

{ The built-in catalogue plus user templates from workspace/teams/*.json
  (a user template overrides a built-in with the same name). }
function TeamTemplates: TTeamTemplateArray;
function FindTeamTemplate(const Name: string; out T: TTeamTemplate): Boolean;

{ Referential integrity, checked in code rather than trusted: unique
  valid slugs, every parent names an agent in the template, no
  parent cycles, wake list names template agents. }
function ValidateTeamTemplate(const T: TTeamTemplate; out Err: string): Boolean;

{ Create the template's agents. Idempotent on slug: an existing agent is
  SKIPPED (keeping its conversation and any edited role) and reported,
  the same contract SeedSuiteReporting has. Parents are created before
  their reports so a reporting line never dangles. }
function SeedTeam(const T: TTeamTemplate;
                  out Created, Skipped: TStringArray;
                  out Err: string): Boolean;

(* The kickoff text with {{goal}} / {{project}} filled in. *)
function TeamKickoffText(const T: TTeamTemplate;
                         const Goal, Project: string): string;

{ Top-level agents of a template (parent = '') -- who gets the kickoff. }
function TeamLeads(const T: TTeamTemplate): TStringArray;

(* Who the tick considers waking: the template's list, or every agent
   in it when that list is empty. Separate from TeamLeads because the
   two questions are different -- the lead receives the kickoff, the
   whole team is eligible to be woken. *)
function TeamWakeList(const T: TTeamTemplate): TStringArray;

{ ------------------------------------------------------------- state -- }

function TeamStateDir: string;
function LoadTeamState(const Name: string; out S: TTeamState): Boolean;
function SaveTeamState(var S: TTeamState; out Err: string): Boolean;
function ListTeamStates: TTeamStateArray;

{ --------------------------------------------------------- the tick -- }

(* Is this team due a tick? Compares LastTick + WakeMinutes against now;
   a team with WakeMinutes = 0 or Enabled = False is never due.

   NOT the whole story: see TeamHasWaitingMail. A team where someone
   has just been sent a message is due immediately regardless of the
   clock. *)
function TeamTickDue(const S: TTeamState): Boolean;

(* Does anyone on this team have an undelivered message?

   The cadence exists to stop an idle agent being re-woken every tick
   about the same unfinished task -- nothing new has happened, so
   waking it again just buys another provider call. A MESSAGE is the
   opposite: it is new information, sent by a colleague who is now
   waiting on the answer. Making it wait out the cadence meant a lead
   delegated and the whole team sat still for fifteen minutes; the
   handoff, which is the point of having a team, was the slowest thing
   in the system. *)
function TeamHasWaitingMail(const S: TTeamState): Boolean;

(* Who to wake, and why -- the whole wake policy in one testable place.
   An agent is woken only when it is idle AND has a reason to run:
   pending mailbox messages, or open tasks assigned to it on the team's
   board. An idle agent with nothing to do is left alone; waking it
   would burn a provider call to be told "no news". *)
function TeamWakeDecisions(const S: TTeamState): TWakeReasonArray;

(* Tasks that look stuck: active, assigned, their owner idle, and not
   touched for two wake periods. The tick MESSAGES THE LEAD about these
   rather than re-waking the owner -- waking a stuck worker repeats the
   stall; telling its manager is what unsticks it. Returns the message
   texts it sent (for the tick's log) and sends them via AgentSend. *)
function TeamStallMessages(const T: TTeamTemplate; const S: TTeamState): TStringArray;

(* True when every task on the team's board is done (and there is at
   least one task -- an empty board is "not started", not "finished"). *)
function TeamBoardDone(const Project: string): Boolean;

(* Is this agent one of the team's? *)
function AgentInTeam(const S: TTeamState; const Name: string): Boolean;

(* Supervision verdicts for THIS TEAM only.

   SuperviseAgents sweeps the whole workspace roster, which is right for
   the operator's supervise button and wrong for a team's tick: a team
   existing at all would otherwise restart an unrelated personal agent
   that had failed, and go on restarting it on every cadence. A team
   supervises its own members; everyone else's agents are not its
   business. *)
function TeamSupervise(const S: TTeamState): TAgentVerdictArray;

(* Retire a whole team: delete its agents and its state file.

   Sessions and the PROJECT are left alone, the same contract
   DeleteAgent already keeps -- a conversation is not garbage because
   the role that held it was retired, and the work the team did is the
   operator's, not the team's. Returns the agents actually removed;
   one that was already gone is not an error. *)
function RemoveTeam(const Name: string; out Removed: TStringArray;
                    out Err: string): Boolean;

{ ----------------------------------------------------------- export -- }

(* The live roster as a template JSON -- how a hand-built (or hand-
   tuned) team becomes a shareable file. Wake defaults are the caller's
   to fill in; agents' current roles/parents/models are captured as
   they stand. *)
function ExportRosterJSON(const Name, Title: string): string;

(* Parse one template file's JSON. Public because the export test
   proves round-tripping through it, and a future generator will too. *)
function ParseTemplateJSON(const Body: string; out T: TTeamTemplate): Boolean;

implementation

uses
  SysUtils, Classes, DateUtils,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Workspaces,
  PasClaw.Projects.Store;

(* ====================================================================
   The built-in catalogue.

   Role prompts follow one six-section skeleton -- who you are, what
   you own, what you do NOT own (naming the owner), how you work, who
   you talk to, what done means -- with concrete checklists instead of
   adjectives and one closing anti-pattern line each. The skeleton is
   what makes six agents a team instead of six chatbots; the details
   are in docs/agent-teams-plan.md.
   ==================================================================== *)

const
  { Shared by every role: the loop and the comms discipline. Written
    once so the six roles cannot drift apart on the basics. }
  TEAM_COMMON =
    'How you work, every turn: read your messages first; then look at ' +
    'the task board for the team''s project; then do ONE concrete ' +
    'increment of your own work; then update the board (task status, ' +
    'a note on what changed); then, only if something changed that ' +
    'your manager must know -- done, blocked, a decision needed -- ' +
    'send them a message.'#10 +
    'Work goes through the TASK BOARD (the task tool): create tasks, ' +
    'update status and notes, set assignee when handing work over. ' +
    'Messages (the agent tool, action=send) are for exceptions only: ' +
    'blocked, done, need a decision. Never idle-chat another agent, ' +
    'and never message someone just to say you will message them.'#10 +
    'Done means: it actually ran or was actually checked, the board ' +
    'says so, and your manager heard about it if it closes their ' +
    'request. Claiming done without evidence is the one prohibited move.';

  ROLE_FOREMAN =
    'You are the Foreman: the working lead of a small software team, ' +
    'reporting to the human operator.'#10 +
    'You own the plan: the project, its task list, and who is doing ' +
    'what. You do NOT own the code (the developer does), the ' +
    'requirements detail (the product manager does), or the verdict on ' +
    'quality (the test engineer does) -- you own that all of it happens.'#10 +
    'When given a goal: create the project if it does not exist, break ' +
    'the goal into small concrete tasks with the task tool, set each ' +
    'task''s assignee to the team member who owns it, and message each ' +
    'assignee ONCE naming their task ids. When given an existing ' +
    'board: read it first; assign and unblock what is there before ' +
    'inventing anything new.'#10 +
    'On each wake: read messages; walk the board; unblock or reassign ' +
    'anything stalled; if a worker reported done, have the test ' +
    'engineer verify before you close it; when the whole board is ' +
    'done, tell the operator plainly and stop -- do not invent work ' +
    'to stay busy.'#10 +
    'Mark a task BLOCKED when it waits on another task, and say in its ' +
    'notes what it waits on. This is not bookkeeping: only todo and ' +
    'active tasks wake their owner, so a review task left as todo ' +
    'before there is anything to review wakes the reviewer to look at ' +
    'an empty project. Unblock it the moment the thing it waited for ' +
    'closes, and tell its owner.'#10 +
    'Autonomy: small things within the team -- assignments, task ' +
    'edits, follow-ups -- do them and report after. Anything that ' +
    'commits money, deletes things outside the project, or touches ' +
    'the world outside this workspace: propose it to the operator ' +
    'with your recommendation, and wait. When you are unsure, say so ' +
    'plainly. Silence after noticing something is the failure mode, ' +
    'not action.'#10 +
    'You own the screen: when you assign work, use the desktop tool ' +
    'to open that worker''s window (open_agent) and tile; when the ' +
    'board is done, minimize_all and report. The operator watches the ' +
    'team through the windows you arrange.'#10 +
    TEAM_COMMON + #10 +
    'You are a working lead, not a status-report generator: every ' +
    'wake should move the board, not summarise it.';

  ROLE_PM =
    'You are the Product Manager of a small software team, reporting ' +
    'to the Foreman.'#10 +
    'You own what "it" is: user stories and acceptance criteria. You ' +
    'do NOT own the schedule (the Foreman does) or the implementation ' +
    '(the developer does).'#10 +
    'Before the developer starts a task, its notes must say: who it ' +
    'is for, what they can do after that they could not do before, ' +
    'and 2-4 acceptance checks the test engineer can execute ' +
    'verbatim ("enter 4 URLs, press Compare, see one row per book"). ' +
    'Write those into the task notes with the task tool.'#10 +
    'Answer the developer''s "what should happen when..." questions ' +
    'the same day they are asked; an unanswered question is a stalled ' +
    'task with your name on it. Cut scope rather than letting a task ' +
    'balloon: a smaller thing that ships beats a bigger thing that ' +
    'does not.'#10 +
    TEAM_COMMON + #10 +
    'You are not a spec factory: if a criterion cannot be checked in ' +
    'under a minute by the test engineer, rewrite it until it can.';

  ROLE_DEV =
    'You are the 10x Developer of a small software team, reporting to ' +
    'the Foreman.'#10 +
    'You own the code: the app under projects/<project>/app/. You do ' +
    'NOT own the requirements (ask the Product Manager instead of ' +
    'guessing), the environment (the Foreman unblocks that), or the ' +
    'verdict on your own work (the Test Engineer closes bugs, not you).'#10 +
    'Building an app: it is FILES, not a wish. Create ' +
    'projects/<project>/app/index.html and app.json ({"name":..., ' +
    '"kind":"html","entry":"index.html","window":{"width":...,' +
    '"height":...}}) with the file tools. Use pasclaw.js when the app ' +
    'needs saved state. kind can also be python or fpc for process ' +
    'apps with a main file. Never use the desktop tool to build -- it ' +
    'asks a browser to do it and there may be no browser watching.'#10 +
    'Ship the smallest increment that works, and RUN or open what you ' +
    'made before claiming anything. Report failure as plainly as ' +
    'success: "it does not work yet because X" is a good report and ' +
    '"done" that was never run is the one prohibited move.'#10 +
    'Take only tasks assigned to you; mark them active when you ' +
    'start, and describe what changed in the task notes when you ' +
    'stop, so the next turn -- yours or anyone''s -- can pick the ' +
    'work up cold.'#10 +
    TEAM_COMMON + #10 +
    'The 10x is never having to be asked twice and never claiming ' +
    'done untested -- not volume.';

  ROLE_UI =
    'You are the UI Psychologist of a small software team, reporting ' +
    'to the Foreman.'#10 +
    'You own the user''s first five minutes. You do NOT own fixing ' +
    'what you find (the developer does) or deciding priority (the ' +
    'Foreman does).'#10 +
    'When the developer reports something built, open the app and go ' +
    'through it as a first-time human. Your checklist, every pass: ' +
    'what is the very FIRST thing a user sees and does it say what ' +
    'this app is; what do the labels assume the user already knows; ' +
    'where does an error leave you stranded with no way forward; what ' +
    'takes three clicks that should take one; what has no feedback ' +
    'after you do it.'#10 +
    'File each finding as a TASK with a concrete rewrite -- ' +
    '"rename ''Execute query'' to ''Search''", "empty state should ' +
    'say ''Paste 4 Amazon links above''" -- assigned to nobody (the ' +
    'Foreman routes it). One finding per task. Never an essay.'#10 +
    TEAM_COMMON + #10 +
    'Cognitive load, defaults and error wording are your beat; pixel ' +
    'taste is not -- if the objection is "I would have used a nicer ' +
    'blue", drop it.';

  ROLE_QA =
    'You are the Test Engineer of a small software team, reporting to ' +
    'the Foreman.'#10 +
    'You own "does it actually work". You do NOT own fixing it (the ' +
    'developer does) or the acceptance criteria themselves (the ' +
    'Product Manager writes those; you execute them).'#10 +
    'When a task reaches you: run every acceptance check in its notes ' +
    'verbatim, then try to break it -- empty input, wrong input, the ' +
    'steps out of order, the same thing twice, reload in the middle. ' +
    'Every break becomes a task with EXACT reproduction steps: what ' +
    'you did, what happened, what should have happened.'#10 +
    'A fixed bug is re-tested by you before it closes; the developer ' +
    'does not close their own bug. When everything passes, say so on ' +
    'the task and tell the Foreman -- a pass nobody hears about ' +
    'blocks the board as surely as a failure.'#10 +
    TEAM_COMMON + #10 +
    'You are not a rubber stamp: a pass you did not personally ' +
    'reproduce is not a pass.';

  ROLE_REVIEWER =
    'You are the Code Reviewer of a small software team, reporting to ' +
    'the Foreman.'#10 +
    'You own maintainability. You do NOT own runtime correctness (the ' +
    'Test Engineer catches that) or rewriting the code yourself (the ' +
    'developer does; you file findings).'#10 +
    'Read the app source for what a runtime test misses: state that ' +
    'cannot survive a reload, error paths that swallow silently, ' +
    'duplication that will drift, names that lie. File each as a task ' +
    'prefixed [review] so the Foreman can defer them below feature ' +
    'work.'#10 +
    TEAM_COMMON + #10 +
    'You review the code that exists, not the architecture you would ' +
    'have chosen.';

function BuiltinTemplates: TTeamTemplateArray;

  function A(const Name, Title, Role, Model, Parent: string): TTeamAgent;
  begin
    Result.Name := Name; Result.Title := Title; Result.Role := Role;
    Result.Model := Model; Result.Parent := Parent;
  end;

var
  T: TTeamTemplate;
  N: Integer;
begin
  SetLength(Result, 2);

  { duo: the cheapest thing that demonstrates the loop. }
  T := Default(TTeamTemplate);
  T.Name := 'duo';
  T.Title := 'Duo';
  T.Description := 'A Foreman and a 10x Developer -- the smallest team ' +
                   'that plans, builds and reports.';
  SetLength(T.Agents, 2);
  T.Agents[0] := A('foreman', 'Foreman', ROLE_FOREMAN, '', '');
  T.Agents[1] := A('dev', '10x Developer', ROLE_DEV, '', 'foreman');
  T.Kickoff :=
    'The operator has pointed this team at work.'#10 +
    'Goal: {{goal}}'#10'Project: {{project}}'#10 +
    'If the board already has tasks, read and assign them; otherwise ' +
    'break the goal into tasks, assign them, and get the developer ' +
    'building. Report your plan to the operator in one short message.';
  T.WakeMinutes := 15;
  T.Exists := True;   { no wake list = the whole team is eligible }
  Result[0] := T;

  { software-team: the six roles. }
  T := Default(TTeamTemplate);
  T.Name := 'software-team';
  T.Title := 'Software Team';
  T.Description := 'Foreman, Product Manager, 10x Developer, UI ' +
                   'Psychologist and Test Engineer: takes a goal or a ' +
                   'task board and ships an app. (A Code Reviewer role ' +
                   'exists but is off by default to save turns.)';
  N := 5;
  SetLength(T.Agents, N);
  T.Agents[0] := A('foreman', 'Foreman',         ROLE_FOREMAN, '',     '');
  T.Agents[1] := A('pm',      'Product Manager', ROLE_PM,      'fast', 'foreman');
  T.Agents[2] := A('dev',     '10x Developer',   ROLE_DEV,     '',     'foreman');
  T.Agents[3] := A('ui',      'UI Psychologist', ROLE_UI,      'fast', 'foreman');
  T.Agents[4] := A('qa',      'Test Engineer',   ROLE_QA,      'fast', 'foreman');
  T.Kickoff :=
    'The operator has pointed this team at work.'#10 +
    'Goal: {{goal}}'#10'Project: {{project}}'#10 +
    'If the board already has tasks, read them and assign owners ' +
    'before inventing anything new. Otherwise: have the Product ' +
    'Manager turn the goal into tasks with acceptance checks, assign ' +
    'the build to the developer, and line up the UI Psychologist and ' +
    'Test Engineer behind it. Report your plan to the operator in one ' +
    'short message.';
  T.WakeMinutes := 15;
  T.Exists := True;   { no wake list = the whole team is eligible }
  Result[1] := T;
end;

(* The optional reviewer, published so a user template (or a future
   variant) can include it without re-authoring the role. *)
function ReviewerRole: string;
begin
  Result := ROLE_REVIEWER;
end;

{ ------------------------------------------------- user template files -- }

function TeamsDir: string;
begin
  Result := WorkspaceSubdir('teams');
end;

function TeamStateDir: string;
begin
  Result := JoinPath(TeamsDir, 'state');
end;

function ParseTemplateJSON(const Body: string; out T: TTeamTemplate): Boolean;
var
  Obj, AObj, W: TJsonObject;
  Arr, Who: TJsonArray;
  I: Integer;
begin
  Result := False;
  T := Default(TTeamTemplate);
  Obj := nil;
  try
    Obj := TJsonObject.Parse(Body);
  except
    Obj := nil;
  end;
  if Obj = nil then Exit;
  try
    T.Name        := AgentSlug(Obj.GetStr('name', ''));
    T.Title       := Trim(Obj.GetStr('title', T.Name));
    T.Description := Trim(Obj.GetStr('description', ''));
    T.Kickoff     := Obj.GetStr('kickoff', '');
    W := Obj.ChildObject('wake');
    if W <> nil then
    try
      T.WakeMinutes := W.GetInt('minutes', 0);
      Who := W.ChildArray('who');
      if Who <> nil then
      try
        SetLength(T.WakeWho, Who.Count);
        for I := 0 to Who.Count - 1 do
          T.WakeWho[I] := AgentSlug(Who.ItemStr(I));
      finally
        Who.Free;
      end;
    finally
      W.Free;
    end;
    Arr := Obj.ChildArray('agents');
    if Arr <> nil then
    try
      SetLength(T.Agents, Arr.Count);
      for I := 0 to Arr.Count - 1 do
      begin
        T.Agents[I] := Default(TTeamAgent);
        AObj := Arr.ItemObject(I);
        if AObj = nil then Continue;
        try
          T.Agents[I].Name   := AgentSlug(AObj.GetStr('name', ''));
          T.Agents[I].Title  := Trim(AObj.GetStr('title', T.Agents[I].Name));
          T.Agents[I].Role   := AObj.GetStr('role', '');
          T.Agents[I].Model  := LowerCase(Trim(AObj.GetStr('model', '')));
          T.Agents[I].Parent := AgentSlug(AObj.GetStr('parent', ''));
        finally
          AObj.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
    T.Exists := T.Name <> '';
    Result := T.Exists;
  finally
    Obj.Free;
  end;
end;

function UserTemplates: TTeamTemplateArray;
var
  Rec: TSearchRec;
  Dir: string;
  T: TTeamTemplate;
  N: Integer;
begin
  SetLength(Result, 0);
  N := 0;
  Dir := TeamsDir;
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(JoinPath(Dir, '*.json'), faAnyFile, Rec) = 0 then
  try
    repeat
      if (Rec.Attr and faDirectory) <> 0 then Continue;
      if ParseTemplateJSON(ReadFileText(JoinPath(Dir, Rec.Name)), T) then
      begin
        SetLength(Result, N + 1);
        Result[N] := T;
        Inc(N);
      end
      else
        LogDebug('teams: %s is not a readable team template -- skipped',
                 [Rec.Name]);
    until FindNext(Rec) <> 0;
  finally
    FindClose(Rec);
  end;
end;

function TeamTemplates: TTeamTemplateArray;
var
  B, U: TTeamTemplateArray;
  I, J, N: Integer;
  Shadowed: Boolean;
begin
  B := BuiltinTemplates;
  U := UserTemplates;
  { A user template overrides a built-in of the same name: the operator
    who wrote a file called software-team.json meant THEIR software
    team. Built-ins that are not shadowed keep their place. }
  SetLength(Result, 0);
  N := 0;
  for I := 0 to High(B) do
  begin
    Shadowed := False;
    for J := 0 to High(U) do
      if U[J].Name = B[I].Name then Shadowed := True;
    if not Shadowed then
    begin
      SetLength(Result, N + 1);
      Result[N] := B[I];
      Inc(N);
    end;
  end;
  for J := 0 to High(U) do
  begin
    SetLength(Result, N + 1);
    Result[N] := U[J];
    Inc(N);
  end;
end;

function FindTeamTemplate(const Name: string; out T: TTeamTemplate): Boolean;
var
  All: TTeamTemplateArray;
  I: Integer;
  Slug: string;
begin
  Result := False;
  T := Default(TTeamTemplate);
  Slug := AgentSlug(Name);
  All := TeamTemplates;
  for I := 0 to High(All) do
    if All[I].Name = Slug then
    begin
      T := All[I];
      Exit(True);
    end;
end;

{ --------------------------------------------------------- validation -- }

function ValidateTeamTemplate(const T: TTeamTemplate; out Err: string): Boolean;
var
  I, J, Hops: Integer;
  Cur: string;

  function IndexOfAgent(const Name: string): Integer;
  var K: Integer;
  begin
    Result := -1;
    for K := 0 to High(T.Agents) do
      if T.Agents[K].Name = Name then Exit(K);
  end;

begin
  Result := False;
  Err := '';
  if T.Name = '' then begin Err := 'a template needs a name'; Exit; end;
  if Length(T.Agents) = 0 then
  begin
    Err := 'template "' + T.Name + '" has no agents';
    Exit;
  end;
  for I := 0 to High(T.Agents) do
  begin
    if T.Agents[I].Name = '' then
    begin
      Err := 'template "' + T.Name + '": agent ' + IntToStr(I + 1) +
             ' has no usable name';
      Exit;
    end;
    if Trim(T.Agents[I].Role) = '' then
    begin
      Err := 'template "' + T.Name + '": agent "' + T.Agents[I].Name +
             '" has no role text';
      Exit;
    end;
    if (T.Agents[I].Model <> '') and (T.Agents[I].Model <> 'fast') and
       (T.Agents[I].Model <> 'primary') then
    begin
      Err := 'template "' + T.Name + '": agent "' + T.Agents[I].Name +
             '" names model tier "' + T.Agents[I].Model +
             '" -- use "", "primary" or "fast" (never a model id)';
      Exit;
    end;
    for J := 0 to I - 1 do
      if T.Agents[J].Name = T.Agents[I].Name then
      begin
        Err := 'template "' + T.Name + '": duplicate agent "' +
               T.Agents[I].Name + '"';
        Exit;
      end;
    if (T.Agents[I].Parent <> '') and
       (IndexOfAgent(T.Agents[I].Parent) < 0) then
    begin
      Err := 'template "' + T.Name + '": agent "' + T.Agents[I].Name +
             '" reports to "' + T.Agents[I].Parent +
             '", which is not in the template';
      Exit;
    end;
  end;
  { A parent cycle costs a confusing org chart at delivery time, but at
    seeding time it would loop the parents-first ordering forever --
    refuse it here where the fix is obvious. }
  for I := 0 to High(T.Agents) do
  begin
    Cur := T.Agents[I].Parent;
    Hops := 0;
    while (Cur <> '') and (Hops <= Length(T.Agents)) do
    begin
      if Cur = T.Agents[I].Name then
      begin
        Err := 'template "' + T.Name + '": reporting line through "' +
               T.Agents[I].Name + '" loops back on itself';
        Exit;
      end;
      J := IndexOfAgent(Cur);
      if J < 0 then Break;
      Cur := T.Agents[J].Parent;
      Inc(Hops);
    end;
    if Hops > Length(T.Agents) then
    begin
      Err := 'template "' + T.Name + '": reporting lines form a cycle';
      Exit;
    end;
  end;
  for I := 0 to High(T.WakeWho) do
    if IndexOfAgent(T.WakeWho[I]) < 0 then
    begin
      Err := 'template "' + T.Name + '": wake list names "' +
             T.WakeWho[I] + '", which is not in the template';
      Exit;
    end;
  Result := True;
end;

{ ------------------------------------------------------------ seeding -- }

function SeedTeam(const T: TTeamTemplate;
                  out Created, Skipped: TStringArray;
                  out Err: string): Boolean;
var
  Done: array of Boolean;
  Existing: TAgentInfo;
  Info: TAgentInfo;
  Progress: Boolean;
  I, Pass: Integer;

  function ParentSeeded(const Parent: string): Boolean;
  var K: Integer;
  begin
    if Parent = '' then Exit(True);
    for K := 0 to High(T.Agents) do
      if T.Agents[K].Name = Parent then Exit(Done[K]);
    Result := True;  { validated earlier; unreachable }
  end;

begin
  Result := False;
  SetLength(Created, 0);
  SetLength(Skipped, 0);
  if not ValidateTeamTemplate(T, Err) then Exit;

  SetLength(Done, Length(T.Agents));
  for I := 0 to High(Done) do Done[I] := False;

  (* Parents before reports. Validation ruled out cycles, so repeated
     passes always make progress; the bound is belt-and-braces. *)
  for Pass := 1 to Length(T.Agents) do
  begin
    Progress := False;
    for I := 0 to High(T.Agents) do
    begin
      if Done[I] then Continue;
      if not ParentSeeded(T.Agents[I].Parent) then Continue;

      if GetAgent(T.Agents[I].Name, Existing) then
      begin
        { The operator's agent, kept: conversation, edited role, all of
          it. Reported rather than silent -- "why does my dev still act
          like a poet" is answered by "it was already here". }
        SetLength(Skipped, Length(Skipped) + 1);
        Skipped[High(Skipped)] := T.Agents[I].Name;
      end
      else
      begin
        Info := Default(TAgentInfo);
        Info.Name   := T.Agents[I].Name;
        Info.Title  := T.Agents[I].Title;
        Info.Role   := T.Agents[I].Role;
        Info.Model  := T.Agents[I].Model;   { tier word; runner resolves }
        Info.Parent := T.Agents[I].Parent;
        if SaveAgent(Info, Err) = '' then Exit;
        SetLength(Created, Length(Created) + 1);
        Created[High(Created)] := T.Agents[I].Name;
      end;
      Done[I] := True;
      Progress := True;
    end;
    if not Progress then Break;
  end;

  for I := 0 to High(Done) do
    if not Done[I] then
    begin
      Err := 'could not order agent "' + T.Agents[I].Name +
             '" after its parent';
      Exit;
    end;
  Result := True;
end;

function TeamKickoffText(const T: TTeamTemplate;
                         const Goal, Project: string): string;
begin
  Result := T.Kickoff;
  if Result = '' then
    Result := 'The operator has pointed this team at work.'#10 +
              'Goal: {{goal}}'#10'Project: {{project}}';
  Result := StringReplace(Result, '{{goal}}', Goal, [rfReplaceAll]);
  Result := StringReplace(Result, '{{project}}', Project, [rfReplaceAll]);
end;

function TeamLeads(const T: TTeamTemplate): TStringArray;
var
  I, N: Integer;
begin
  SetLength(Result, 0);
  N := 0;
  for I := 0 to High(T.Agents) do
    if T.Agents[I].Parent = '' then
    begin
      SetLength(Result, N + 1);
      Result[N] := T.Agents[I].Name;
      Inc(N);
    end;
end;

function TeamWakeList(const T: TTeamTemplate): TStringArray;
var
  I: Integer;
begin
  if Length(T.WakeWho) > 0 then Exit(T.WakeWho);
  SetLength(Result, Length(T.Agents));
  for I := 0 to High(T.Agents) do
    Result[I] := T.Agents[I].Name;
end;

{ -------------------------------------------------------------- state -- }

function StatePath(const Name: string): string;
begin
  Result := '';
  if AgentSlug(Name) = '' then Exit;
  Result := JoinPath(TeamStateDir, AgentSlug(Name) + '.json');
end;

function LoadTeamState(const Name: string; out S: TTeamState): Boolean;
var
  Obj: TJsonObject;
  Who: TJsonArray;
  Path: string;
  I: Integer;
begin
  Result := False;
  S := Default(TTeamState);
  Path := StatePath(Name);
  if (Path = '') or not FileExists(Path) then Exit;
  Obj := nil;
  try
    Obj := TJsonObject.Parse(ReadFileText(Path));
  except
    Obj := nil;
  end;
  if Obj = nil then Exit;
  try
    S.Name        := AgentSlug(Obj.GetStr('name', Name));
    S.Project     := Trim(Obj.GetStr('project', ''));
    S.Goal        := Obj.GetStr('goal', '');
    S.Enabled     := Obj.GetBool('enabled', False);
    S.WakeMinutes := Obj.GetInt('wake_minutes', 0);
    S.LastTick    := Obj.GetStr('last_tick', '');
    S.DoneTicks   := Obj.GetInt('done_ticks', 0);
    S.Created     := Obj.GetStr('created', '');
    S.Updated     := Obj.GetStr('updated', '');
    Who := Obj.ChildArray('wake_who');
    if Who <> nil then
    try
      SetLength(S.WakeWho, Who.Count);
      for I := 0 to Who.Count - 1 do
        S.WakeWho[I] := AgentSlug(Who.ItemStr(I));
    finally
      Who.Free;
    end;
    S.Exists := True;
    Result := True;
  finally
    Obj.Free;
  end;
end;

function SaveTeamState(var S: TTeamState; out Err: string): Boolean;
var
  Obj: TJsonObject;
  Who: TJsonArray;
  I: Integer;
  Path: string;
begin
  Result := False;
  Err := '';
  S.Name := AgentSlug(S.Name);
  Path := StatePath(S.Name);
  if Path = '' then
  begin
    Err := 'a team state needs a usable name';
    Exit;
  end;
  if not EnsureDir(TeamStateDir) then
  begin
    Err := 'could not create ' + TeamStateDir;
    Exit;
  end;
  if S.Created = '' then S.Created := NowIsoUtc;
  S.Updated := NowIsoUtc;
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('name', S.Name);
    Obj.PutStr('project', S.Project);
    Obj.PutStr('goal', S.Goal);
    Obj.PutBool('enabled', S.Enabled);
    Obj.PutInt('wake_minutes', S.WakeMinutes);
    Who := TJsonArray.Create;
    for I := 0 to High(S.WakeWho) do Who.AddStr(S.WakeWho[I]);
    Obj.PutArray('wake_who', Who);
    Obj.PutStr('last_tick', S.LastTick);
    Obj.PutInt('done_ticks', S.DoneTicks);
    Obj.PutStr('created', S.Created);
    Obj.PutStr('updated', S.Updated);
    WriteFileText(Path, Obj.ToJSON);
  finally
    Obj.Free;
  end;
  S.Exists := True;
  Result := True;
end;

function ListTeamStates: TTeamStateArray;
var
  Rec: TSearchRec;
  S: TTeamState;
  N: Integer;
begin
  SetLength(Result, 0);
  N := 0;
  if not DirectoryExists(TeamStateDir) then Exit;
  if FindFirst(JoinPath(TeamStateDir, '*.json'), faAnyFile, Rec) = 0 then
  try
    repeat
      if (Rec.Attr and faDirectory) <> 0 then Continue;
      if LoadTeamState(ChangeFileExt(Rec.Name, ''), S) then
      begin
        SetLength(Result, N + 1);
        Result[N] := S;
        Inc(N);
      end;
    until FindNext(Rec) <> 0;
  finally
    FindClose(Rec);
  end;
end;

{ ----------------------------------------------------------- the tick -- }

function IsoToLocal(const Iso: string): TDateTime;
begin
  Result := 0;
  if Iso = '' then Exit;
  try
    Result := ISO8601ToDate(Iso, {ReturnUTC=}False);
  except
    Result := 0;
  end;
end;

function TeamTickDue(const S: TTeamState): Boolean;
var
  Last: TDateTime;
begin
  Result := False;
  { The operator's brake outranks every schedule. }
  if AgentsPaused then Exit;
  if (not S.Enabled) or (S.WakeMinutes <= 0) then Exit;
  if S.LastTick = '' then Exit(True);
  Last := IsoToLocal(S.LastTick);
  if Last = 0 then Exit(True);
  Result := MinutesBetween(Now, Last) >= S.WakeMinutes;
end;

function TeamHasWaitingMail(const S: TTeamState): Boolean;
var
  I: Integer;
begin
  Result := False;
  if AgentsPaused then Exit;
  if not S.Enabled then Exit;
  for I := 0 to High(S.WakeWho) do
    if (AgentPending(S.WakeWho[I]) > 0) and (not AgentIsBusy(S.WakeWho[I])) then
      Exit(True);
end;

function AgentHasOpenAssignedTask(const Project, Agent: string): Boolean;
var
  Tasks: TTaskInfoArray;
  I: Integer;
begin
  Result := False;
  if Project = '' then Exit;
  Tasks := ListTasks(Project);
  for I := 0 to High(Tasks) do
    if (Tasks[I].Assignee = Agent) and
       (Tasks[I].Status in [tsTodo, tsActive]) then
      Exit(True);
end;

function TeamWakeDecisions(const S: TTeamState): TWakeReasonArray;
var
  I, N: Integer;
  R: TWakeReason;
  Info: TAgentInfo;
begin
  SetLength(Result, Length(S.WakeWho));
  N := 0;
  for I := 0 to High(S.WakeWho) do
  begin
    R := Default(TWakeReason);
    R.Agent := S.WakeWho[I];
    R.Wake := False;
    if not GetAgent(R.Agent, Info) then
      R.Why := 'no such agent'
    else if AgentIsBusy(R.Agent) then
      R.Why := 'already working'
    else if AgentPending(R.Agent) > 0 then
    begin
      R.Wake := True;
      R.Why := Format('%d message(s) waiting', [AgentPending(R.Agent)]);
    end
    else if AgentHasOpenAssignedTask(S.Project, R.Agent) then
    begin
      R.Wake := True;
      R.Why := 'open assigned task(s) on ' + S.Project;
    end
    else
      R.Why := 'nothing to do -- left alone';
    Result[N] := R;
    Inc(N);
  end;
end;

function TeamBoardDone(const Project: string): Boolean;
var
  Tasks: TTaskInfoArray;
  I: Integer;
begin
  Result := False;
  if Project = '' then Exit;
  Tasks := ListTasks(Project);
  if Length(Tasks) = 0 then Exit;   { empty is "not started", not done }
  for I := 0 to High(Tasks) do
    if Tasks[I].Status <> tsDone then Exit;
  Result := True;
end;

function AgentInTeam(const S: TTeamState; const Name: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(S.WakeWho) do
    if S.WakeWho[I] = Name then Exit(True);
end;

function TeamSupervise(const S: TTeamState): TAgentVerdictArray;
var
  All: TAgentVerdictArray;
  I, N: Integer;
begin
  SetLength(Result, 0);
  N := 0;
  All := SuperviseAgents(0, 0);
  for I := 0 to High(All) do
    if AgentInTeam(S, All[I].Name) then
    begin
      SetLength(Result, N + 1);
      Result[N] := All[I];
      Inc(N);
    end;
end;

function TeamStallMessages(const T: TTeamTemplate; const S: TTeamState): TStringArray;
var
  Tasks: TTaskInfoArray;
  Leads: TStringArray;
  I, L, N: Integer;
  Updated: TDateTime;
  Text, Delivered, Err: string;
begin
  SetLength(Result, 0);
  N := 0;
  if (S.Project = '') or (S.WakeMinutes <= 0) then Exit;
  Leads := TeamLeads(T);
  if Length(Leads) = 0 then Exit;
  Tasks := ListTasks(S.Project);
  for I := 0 to High(Tasks) do
  begin
    if Tasks[I].Status <> tsActive then Continue;
    if Tasks[I].Assignee = '' then Continue;
    { A busy owner is working, whatever the clock says. }
    if AgentIsBusy(Tasks[I].Assignee) then Continue;
    Updated := IsoToLocal(Tasks[I].Updated);
    if Updated = 0 then Continue;
    if MinutesBetween(Now, Updated) < 2 * S.WakeMinutes then Continue;

    Text := Format('Task %s ("%s") on %s is assigned to %s, marked ' +
                   'active, and has not moved for %d minutes while its ' +
                   'owner sits idle. Unblock it, reassign it, or close it.',
                   [Tasks[I].Id, Tasks[I].Title, S.Project,
                    Tasks[I].Assignee, MinutesBetween(Now, Updated)]);
    for L := 0 to High(Leads) do
      { The lead's own stall is still reported -- to itself: its next
        wake reads the message and acts, which beats a silent stall. }
      if AgentSend(Leads[L], 'team-tick', Text, Delivered, Err) then
      begin
        SetLength(Result, N + 1);
        Result[N] := Tasks[I].Id + ' -> ' + Leads[L];
        Inc(N);
      end;
  end;
end;

{ ------------------------------------------------------------- export -- }

function RemoveTeam(const Name: string; out Removed: TStringArray;
                    out Err: string): Boolean;
var
  S: TTeamState;
  T: TTeamTemplate;
  Names: TStringArray;
  I, N: Integer;
  Path, DelErr: string;
begin
  Result := False;
  Err := '';
  SetLength(Removed, 0);
  N := 0;

  { The state's own wake list is the roster of record; the template is
    the fallback for a team whose state file has already gone. }
  if LoadTeamState(Name, S) then Names := S.WakeWho
  else if FindTeamTemplate(Name, T) then Names := TeamWakeList(T)
  else
  begin
    Err := 'no team called "' + AgentSlug(Name) + '"';
    Exit;
  end;

  for I := 0 to High(Names) do
    if DeleteAgent(Names[I], DelErr) then
    begin
      SetLength(Removed, N + 1);
      Removed[N] := Names[I];
      Inc(N);
    end;

  Path := StatePath(Name);
  if (Path <> '') and FileExists(Path) then DeleteFile(Path);
  Result := True;
end;

function ExportRosterJSON(const Name, Title: string): string;
var
  Obj, AObj: TJsonObject;
  Arr: TJsonArray;
  W: TJsonObject;
  Rows: TAgentInfoArray;
  I: Integer;
begin
  Rows := ListAgents;
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('name', AgentSlug(Name));
    if Title <> '' then Obj.PutStr('title', Title)
                   else Obj.PutStr('title', Name);
    Obj.PutStr('description', 'Exported from a live roster on ' + NowIsoUtc);
    Arr := TJsonArray.Create;
    for I := 0 to High(Rows) do
    begin
      AObj := TJsonObject.Create;
      AObj.PutStr('name', Rows[I].Name);
      AObj.PutStr('title', Rows[I].Title);
      AObj.PutStr('role', Rows[I].Role);
      AObj.PutStr('model', Rows[I].Model);
      AObj.PutStr('parent', Rows[I].Parent);
      Arr.AddObject(AObj);
    end;
    Obj.PutArray('agents', Arr);
    W := TJsonObject.Create;
    W.PutInt('minutes', 15);
    Obj.PutObject('wake', W);
    Result := Obj.ToJSON;
  finally
    Obj.Free;
  end;
end;

end.
