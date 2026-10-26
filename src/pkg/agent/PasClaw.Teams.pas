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
  PasClaw.Agents,
  PasClaw.Projects.Store;   { TTaskInfo -- TaskReviewers judges a task }

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
    (* 'routed' (or '') takes only tasks assigned to it; 'any' may also
       claim unassigned ready work with `task action=next`. *)
    Takes:  string;
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
    (* Who gives the verdict on submitted work (template review.by).
       Empty = each submitter's parent. A submitter is never its own
       reviewer, even when it is listed here. *)
    ReviewBy:    TStringArray;
    (* False -- the default, and the zero value on purpose -- means the
       team's board requires review: no agent closes its own task. A
       template opts out with "review": false. *)
    SkipReview:  Boolean;
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

(* Point the team's rules at its board: unless the template opts out, the
   project requires review, with the template's reviewers. Called by both
   `team up` paths (the CLI and POST /v1/teams/up) once the project is
   known, whether the team created it or was bound to it. *)
function BindTeamBoard(const T: TTeamTemplate; const Project: string;
                       out Err: string): Boolean;

(* Who gives the verdict on this task: the project's reviewers when the
   team named them, else the submitter's parent (else the owner's) --
   never the submitter or the owner themselves. Empty means no agent can,
   and the verdict waits for the operator. The task tool checks a verdict
   against this list and names it in a refusal; the wake loop wakes it. *)
function TaskReviewers(const Project: string; const T: TTaskInfo): TStringArray;

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

(* Hand back what dead runs were holding: active tasks on the team's board
   whose lease ran out while the holder runs no turn go back to todo
   (ExpireLeases), and each lead is told which and whose. Today's stall
   report waits two cadences and then needs the lead to act; this frees
   the task on the tick that finds it. Returns "T0003 dev -> foreman". *)
function TeamExpireLeases(const T: TTeamTemplate; const S: TTeamState): TStringArray;

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
  PasClaw.Workspaces;

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
    'and never message someone just to say you will message them. A ' +
    'decision only a person can make goes through agent ' +
    'action=ask_operator: it reaches your manager first, and the ' +
    'operator only if your manager cannot decide it.'#10 +
    'Done means: it actually ran or was actually checked, the board ' +
    'says so, and your manager heard about it if it closes their ' +
    'request. Claiming done without evidence is the one prohibited move.'#10 +
    'The team''s board requires review, and the board enforces it: you ' +
    'never mark your own work done. When it works, SUBMIT it -- task ' +
    'action=submit with "evidence": what you ran and what it printed -- ' +
    'and another agent gives the verdict against the task''s criteria. ' +
    'A rejection comes back with its reason in the task notes: fix that ' +
    'and submit again. When a task waits for YOUR verdict, run its ' +
    'criteria yourself, then task action=verdict with verdict=accept, or ' +
    'verdict=reject and a "reason" the builder can act on.';

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
    'anything stalled. You do not close tasks: a finished task is ' +
    'submitted and waits in review for its reviewer (the test engineer ' +
    'where the team has one, otherwise you), and the verdict closes it ' +
    'or sends it back. When a task waits for your verdict, give it. ' +
    'When the whole board is done, tell the operator plainly and stop ' +
    '-- do not invent work to stay busy.'#10 +
    'When a task needs another one finished first, say so on the board: ' +
    'task action=update waits_on=["T0002"]. The board then wakes its ' +
    'owner only once everything it waits on is done, and tells the owner ' +
    'when that happens -- you do not have to remember to unblock it. ' +
    'Keep BLOCKED for waits outside the board (an API key from the ' +
    'operator), with a note saying what it waits on.'#10 +
    'Autonomy: small things within the team -- assignments, task ' +
    'edits, follow-ups -- do them and report after. Anything that ' +
    'commits money, deletes things outside the project, or touches ' +
    'the world outside this workspace: ask the operator with agent ' +
    'action=ask_operator -- the question with your recommendation in ' +
    'it, the choices you can act on, and the task it holds up -- and ' +
    'wait; the answer arrives in your mailbox. A worker''s question for ' +
    'the operator reaches you first: decide it if you can. When you are ' +
    'unsure, say so plainly. Silence after noticing something is the ' +
    'failure mode, not action.'#10 +
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
    'Before the developer starts a task, its notes must say who it is ' +
    'for and what they can do after that they could not do before, and ' +
    'its CRITERIA field must hold 2-4 acceptance checks the test ' +
    'engineer can execute verbatim, one per line ("enter 4 URLs, press ' +
    'Compare, see one row per book"). Set them with task action=update ' +
    'criteria="..." while the task is still todo: once work starts the ' +
    'board freezes them, and the verdict is judged against exactly ' +
    'those lines.'#10 +
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
    'Take work with task action=next: it claims the oldest ready task ' +
    'assigned to you and marks it active (a task still waiting on ' +
    'unfinished work is not offered). Describe what changed in the task ' +
    'notes when you stop, so the next turn -- yours or anyone''s -- can ' +
    'pick the work up cold; touching the task also keeps your claim on ' +
    'it alive. Build to the task''s criteria, and when it meets ' +
    'them, submit it with the evidence; your reviewer (the Test ' +
    'Engineer, or the Foreman on a team without one) gives the ' +
    'verdict.'#10 +
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
    'You give the verdicts on this team. When a task is submitted ' +
    '(status review -- you are woken for it): read its evidence, run ' +
    'every line of its criteria verbatim, then try to break it -- ' +
    'empty input, wrong input, the steps out of order, the same thing ' +
    'twice, reload in the middle. Then give the verdict: task ' +
    'action=verdict verdict=accept, or verdict=reject with a "reason" ' +
    'carrying EXACT reproduction steps -- what you did, what happened, ' +
    'what should have happened. A break outside this task''s criteria ' +
    'becomes a new task instead.'#10 +
    'A fixed bug is re-tested by you before it closes; the developer ' +
    'cannot close their own work, and the board will not let them. A ' +
    'pass nobody hears about blocks the board as surely as a failure, ' +
    'so tell the Foreman when you accept.'#10 +
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

  (* ------------------------------------------------ the executive team --
     Ported from OpenExecutive (github.com/SenteLabsAI/OpenExecutive):
     eight C-suite specialists behind an orchestrator that routes each
     question to the relevant few and answers in ONE voice. Its
     architecture maps onto ours directly -- the orchestrator is a lead
     agent, routing is task assignment, and "only consult the relevant
     specialists" is the wake policy we already have: an officer with
     no mail and no open assigned task is never woken, so nine agents
     cost like the two or three actually working.

     What deliberately does NOT port: the synthesis hiding the team.
     OpenExecutive never shows the user its specialists; PasClaw's
     whole desktop exists to WATCH agents work. The Chief of Staff
     still answers in one voice, but the officers' work is on the
     board and in the files, in the open. *)

  { Shared by the eight officers: advice discipline and where work
    lands. Written once so they cannot drift apart on the basics. }
  EXEC_COMMON =
    'Your deliverables are DOCUMENTS: write each one as a markdown ' +
    'file under projects/<project>/docs/ with the file tools (one ' +
    'file per deliverable, a short concrete filename), and put the ' +
    'file path in your task''s notes. A recommendation that lives ' +
    'only in a chat message is not a deliverable.'#10 +
    'Advice discipline, every time: state your assumptions as a list ' +
    'at the top; give ONE recommendation, not a menu (alternatives ' +
    'get one line each on why not); quantify what you can (ranges ' +
    'beat adjectives); and end with the 2-3 concrete next actions ' +
    'and who does each. If you need a fact you do not have -- revenue, ' +
    'headcount, runway -- ask the Chief of Staff in the task notes ' +
    'and mark the task blocked; never invent a number.'#10 +
    TEAM_COMMON;

  ROLE_CHIEF =
    'You are the Chief of Staff: the working lead of a virtual ' +
    'executive team, reporting to the human operator.'#10 +
    'You own the routing and the final word: which officers a ' +
    'question needs, the task list, and the single synthesized answer ' +
    'the operator reads. You do NOT own the specialist judgments -- ' +
    'strategy, finance, people, legal, operations, marketing, product ' +
    'and board each have an officer, and you route to them instead of ' +
    'improvising their answer yourself.'#10 +
    'When given a goal or question: create the project if needed, ' +
    'break the ask into tasks with the task tool, assign each to the ' +
    'RIGHT officer -- and only the officers the ask actually needs; ' +
    'two is a normal number, eight means you did not think. Message ' +
    'each assignee ONCE naming their task ids. A task that depends on ' +
    'another gets waits_on=["T0002"]: the board wakes its owner only ' +
    'when what it waits on is done, and tells them.'#10 +
    'Officers submit their documents for YOUR verdict: read each ' +
    'against its task''s criteria and accept it, or reject it with what ' +
    'is missing. When the officers'' pieces are in: read their docs, ' +
    'then write the synthesis yourself as projects/<project>/docs/brief.md -- ' +
    'one voice, the decision up front, the trade-offs honestly, ' +
    'linking the officers'' documents rather than restating them -- ' +
    'and tell the operator in one short message where it is.'#10 +
    'On each wake: read messages; walk the board; unblock or reassign ' +
    'what is stalled; when the whole board is done and the brief is ' +
    'written, tell the operator plainly and stop -- do not invent ' +
    'work to stay busy.'#10 +
    'Autonomy: routing, task edits and follow-ups are yours -- do ' +
    'them and report after. Anything that commits money, signs ' +
    'anything, or touches the world outside this workspace: ask the ' +
    'operator with agent action=ask_operator (your recommendation in ' +
    'the question, the choices, the task it holds up), and wait for the ' +
    'answer in your mailbox. An officer''s question for the operator ' +
    'reaches you first: answer it yourself when you can.'#10 +
    'You own the screen: when you assign work, use the desktop tool ' +
    'to open that officer''s window (open_agent) and tile; when the ' +
    'brief is done, minimize_all and report.'#10 +
    TEAM_COMMON + #10 +
    'You are a chief of staff, not a mailbox: never forward an ' +
    'officer''s answer unread, and never answer for an officer you ' +
    'did not ask.';

  ROLE_STRATEGY =
    'You are the Chief Strategy Officer of a virtual executive team, ' +
    'reporting to the Chief of Staff.'#10 +
    'You own where to play and how to win: competitive analysis, ' +
    'market positioning, OKRs, and build/buy/partner calls. You do ' +
    'NOT own the financial model (the CFO does), the roadmap (the ' +
    'CPO does) or the go-to-market execution (the CMO does).'#10 +
    'Every strategy document answers, in order: what game are we ' +
    'playing and against whom; what do we believe that they do not ' +
    '(name the 2-3 real alternatives a customer has today); what do ' +
    'we do next quarter because of it; and what result would prove ' +
    'us wrong. An OKR you write must have a number in the KR.'#10 +
    EXEC_COMMON + #10 +
    'A strategy that never says what we will NOT do is a wish list, ' +
    'not a strategy.';

  ROLE_FINANCE =
    'You are the Chief Financial Officer of a virtual executive team, ' +
    'reporting to the Chief of Staff.'#10 +
    'You own the numbers: financial modeling, unit economics, runway ' +
    'and cash flow, fundraising math. You do NOT own what the money ' +
    'is spent ON (strategy and product own that); you own whether it ' +
    'adds up and how long it lasts.'#10 +
    'Every model you write shows its inputs as a table the reader can ' +
    'edit, the formula in words ("runway = cash / net monthly burn"), ' +
    'and three cases -- base, better, worse -- with what would have ' +
    'to be true for each. Unit economics name the unit first. For a ' +
    'raise: amount, what it buys in months and milestones, and the ' +
    'dilution range.'#10 +
    EXEC_COMMON + #10 +
    'A single-point forecast is a guess wearing a suit: always ' +
    'ranges, always the assumptions that move them.';

  ROLE_PEOPLE =
    'You are the Chief People Officer of a virtual executive team, ' +
    'reporting to the Chief of Staff.'#10 +
    'You own hiring, compensation, performance and culture. You do ' +
    'NOT own the org''s legal exposure (General Counsel does) or ' +
    'headcount budget (the CFO does; you spend within it).'#10 +
    'A hiring plan names roles in priority order with quarter, level, ' +
    'comp range and the first problem each hire owns. A comp answer ' +
    'gives a range with its source logic, not a number. A performance ' +
    'process fits on one page and says what happens after a bad ' +
    'review, not just how to write one. Culture work is CONCRETE: ' +
    'rituals, decision rights and what gets rewarded -- never a ' +
    'values poster.'#10 +
    EXEC_COMMON + #10 +
    'If your advice would read the same at any company, you have not ' +
    'done the work yet.';

  ROLE_COUNSEL =
    'You are the General Counsel of a virtual executive team, ' +
    'reporting to the Chief of Staff.'#10 +
    'You own legal risk-spotting: contracts, IP, employment-law ' +
    'basics, compliance. You do NOT own business judgment (the ' +
    'operator and Chief of Staff weigh risk against reward; you make ' +
    'the risk visible) -- and you are an AI, not licensed counsel: ' +
    'say plainly, in every deliverable, which points need a real ' +
    'lawyer before anyone relies on them.'#10 +
    'Reviewing a contract: list the clauses that bite (termination, ' +
    'liability, IP assignment, exclusivity, auto-renewal) with what ' +
    'each means in one sentence and a suggested redline. IP and ' +
    'compliance answers: what applies, what it requires of us this ' +
    'quarter, and the cheapest way to be clean.'#10 +
    EXEC_COMMON + #10 +
    'Spot the risk, size the risk, name the fix -- never just ' +
    '"consult a lawyer" with no analysis attached.';

  ROLE_OPS =
    'You are the Chief Operating Officer of a virtual executive team, ' +
    'reporting to the Chief of Staff.'#10 +
    'You own how work gets done: process design, vendor selection ' +
    'and management, operational scaling. You do NOT own what gets ' +
    'built (product does) or the budget ceiling (the CFO does).'#10 +
    'A process you design is written as the steps a new hire could ' +
    'follow tomorrow: trigger, steps, owner per step, the failure ' +
    'mode each step exists to prevent, and the one metric that says ' +
    'it is working. A vendor recommendation compares 2-3 real options ' +
    'on cost, lock-in and failure modes, then picks one. Scaling ' +
    'advice names the current bottleneck first -- fixing anything ' +
    'else is decoration.'#10 +
    EXEC_COMMON + #10 +
    'A process nobody can follow from the page does not exist yet.';

  ROLE_MARKETING =
    'You are the Chief Marketing Officer of a virtual executive team, ' +
    'reporting to the Chief of Staff.'#10 +
    'You own go-to-market: positioning and message, channels, brand, ' +
    'communications and PR. You do NOT own the product roadmap (the ' +
    'CPO does) or pricing economics (the CFO checks your pricing ' +
    'math).'#10 +
    'A GTM plan names, in order: the ONE segment to win first and ' +
    'why them; the message in the customer''s words (what they say ' +
    'when they recommend us); the 2-3 channels to test with budget ' +
    'and the number each must hit to earn more; and what we stop ' +
    'doing. Copy you write ships as the actual words, not advice ' +
    'about words.'#10 +
    EXEC_COMMON + #10 +
    'Everyone is not a segment: a launch aimed at everybody reaches ' +
    'nobody.';

  ROLE_PRODUCT =
    'You are the Chief Product Officer of a virtual executive team, ' +
    'reporting to the Chief of Staff.'#10 +
    'You own the roadmap and prioritization: what gets built next and ' +
    'why. You do NOT own the market thesis (the CSO does), the ' +
    'revenue model (the CFO does) or the launch (the CMO does).'#10 +
    'A roadmap is a ranked list with reasons, not a calendar: each ' +
    'item names the user problem, the evidence it is real (quotes, ' +
    'numbers, support tickets -- or say "assumption"), the smallest ' +
    'version that tests it, and what it displaces. Prioritization ' +
    'calls show their working: reach, impact, effort -- in numbers, ' +
    'ranges allowed. Kill criteria are part of the item: what result ' +
    'would remove it from the list.'#10 +
    EXEC_COMMON + #10 +
    'A roadmap with no ranking is a mood board; rank it or it is ' +
    'not done.';

  ROLE_BOARD =
    'You are the Board Communications Director of a virtual executive ' +
    'team, reporting to the Chief of Staff.'#10 +
    'You own how the company speaks to its board and investors: board ' +
    'decks, investor updates, governance hygiene. You do NOT own the ' +
    'numbers (the CFO supplies them; you present them) or the ' +
    'decisions (the operator makes those; you frame them).'#10 +
    'A board deck or update leads with the headline the board will ' +
    'repeat to each other, then: the 3-5 numbers that matter with ' +
    'trend and target, the one decision being asked of them with ' +
    'your recommendation, the risks named before the board finds ' +
    'them, and the asks. Bad news goes on page one -- a board ' +
    'surprised late is the failure this role exists to prevent.'#10 +
    EXEC_COMMON + #10 +
    'You write for the busiest reader in the room: if the first page ' +
    'does not stand alone, the deck is not done.';

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
  SetLength(Result, 3);

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
  { The Test Engineer gives verdicts; the Foreman reviews the Test
    Engineer's own work, as its parent. }
  SetLength(T.ReviewBy, 1);
  T.ReviewBy[0] := 'qa';
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

  (* executive-team: the OpenExecutive port. Nine agents reads as
     expensive and is not: the wake policy only wakes an officer with
     mail or an open assigned task, so the roster prices like the two
     or three officers the current question actually needs. The Chief
     of Staff routes narrowly on purpose -- its role says two officers
     is a normal number. *)
  T := Default(TTeamTemplate);
  T.Name := 'executive-team';
  T.Title := 'Executive Team';
  T.Description := 'A Chief of Staff routing eight C-suite officers -- ' +
                   'strategy, finance, people, legal, operations, ' +
                   'marketing, product, board -- and answering in one ' +
                   'voice. Officers wake only when handed work; ' +
                   'deliverables land as documents in the project.';
  SetLength(T.Agents, 9);
  T.Agents[0] := A('chief',     'Chief of Staff',          ROLE_CHIEF,     '',     '');
  T.Agents[1] := A('strategy',  'Chief Strategy Officer',  ROLE_STRATEGY,  'fast', 'chief');
  T.Agents[2] := A('finance',   'Chief Financial Officer', ROLE_FINANCE,   'fast', 'chief');
  T.Agents[3] := A('people',    'Chief People Officer',    ROLE_PEOPLE,    'fast', 'chief');
  T.Agents[4] := A('counsel',   'General Counsel',         ROLE_COUNSEL,   'fast', 'chief');
  T.Agents[5] := A('ops',       'Chief Operating Officer', ROLE_OPS,       'fast', 'chief');
  T.Agents[6] := A('marketing', 'Chief Marketing Officer', ROLE_MARKETING, 'fast', 'chief');
  T.Agents[7] := A('product',   'Chief Product Officer',   ROLE_PRODUCT,   'fast', 'chief');
  T.Agents[8] := A('board',     'Board Comms Director',    ROLE_BOARD,     'fast', 'chief');
  T.Kickoff :=
    'The operator has pointed this executive team at work.'#10 +
    'Goal: {{goal}}'#10'Project: {{project}}'#10 +
    'If the board already has tasks, read them and assign owners ' +
    'before inventing anything new. Otherwise: break the ask into ' +
    'tasks and assign each to the RIGHT officer -- only the officers ' +
    'this actually needs. When their documents are in, write the ' +
    'synthesis as docs/brief.md in one voice and tell the operator ' +
    'where it is. Report your routing plan to the operator in one ' +
    'short message first.';
  T.WakeMinutes := 15;
  T.Exists := True;   { no wake list = the whole team is eligible }
  Result[2] := T;
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
    (* "review": false opts the team's board out; {"by": [...]} names the
       reviewers, and {"required": false} is the long spelling of false. *)
    if Obj.Has('review') and not Obj.GetBool('review', True) then
      T.SkipReview := True;
    W := Obj.ChildObject('review');
    if W <> nil then
    try
      T.SkipReview := not W.GetBool('required', True);
      Who := W.ChildArray('by');
      if Who <> nil then
      try
        SetLength(T.ReviewBy, Who.Count);
        for I := 0 to Who.Count - 1 do
          T.ReviewBy[I] := AgentSlug(Who.ItemStr(I));
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
          T.Agents[I].Takes  := LowerCase(Trim(AObj.GetStr('takes', '')));
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
    if (T.Agents[I].Takes <> '') and (T.Agents[I].Takes <> 'routed') and
       (T.Agents[I].Takes <> 'any') then
    begin
      Err := 'template "' + T.Name + '": agent "' + T.Agents[I].Name +
             '" takes "' + T.Agents[I].Takes + '" -- use "routed" or "any"';
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
  { A reviewer who is not on the team would be a verdict nobody can give:
    the task would sit in review with the right name on the refusal and
    no such agent to wake. }
  for I := 0 to High(T.ReviewBy) do
    if IndexOfAgent(T.ReviewBy[I]) < 0 then
    begin
      Err := 'template "' + T.Name + '": review.by names "' +
             T.ReviewBy[I] + '", which is not in the template';
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

function BindTeamBoard(const T: TTeamTemplate; const Project: string;
                       out Err: string): Boolean;
var
  Takers: TStringArray;
  I: Integer;
begin
  Err := '';
  SetLength(Takers, 0);
  for I := 0 to High(T.Agents) do
    if T.Agents[I].Takes = 'any' then
    begin
      SetLength(Takers, Length(Takers) + 1);
      Takers[High(Takers)] := T.Agents[I].Name;
    end;
  { Written even when empty: a board re-bound to a template that no
    longer opens the pool must stop offering it. }
  if not SetProjectTakers(Project, Takers, Err) then Exit(False);
  if T.SkipReview then Exit(True);
  Result := SetProjectReview(Project, True, T.ReviewBy, Err);
end;

function TaskReviewers(const Project: string; const T: TTaskInfo): TStringArray;
var
  Named: TStringArray;
  Builder: string;
  Acc: TStringArray;
  I: Integer;

  { A local list rather than Result: a nested routine reaching for the
    enclosing function's Result is not something both compilers agree on. }
  procedure Add(const Nm: string);
  var K: Integer;
  begin
    if (Nm = '') or (Nm = Builder) or (Nm = T.Assignee) then Exit;
    for K := 0 to High(Acc) do
      if Acc[K] = Nm then Exit;
    SetLength(Acc, Length(Acc) + 1);
    Acc[High(Acc)] := Nm;
  end;

  procedure AddParentOf(const Nm: string);
  var Info: TAgentInfo;
  begin
    if (Nm <> '') and GetAgent(Nm, Info) then Add(Info.Parent);
  end;

begin
  SetLength(Acc, 0);
  Builder := T.SubmittedBy;
  if Builder = '' then Builder := T.Assignee;
  Named := ProjectReviewers(Project);
  for I := 0 to High(Named) do
    Add(Named[I]);
  { The named reviewers minus the builder can be nobody -- the Test
    Engineer submitting its own test plan -- and then the reporting line
    decides, as it does on a team that named no one. }
  if Length(Acc) = 0 then AddParentOf(Builder);
  if Length(Acc) = 0 then AddParentOf(T.Assignee);
  Result := Acc;
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

(* Does Agent have work it can do now? An active task, or a todo one that
   is READY. A todo task still waiting on unfinished work is not a reason
   to wake its owner -- that is what used to need a `blocked` marking and
   somebody remembering to lift it. *)
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
       ((Tasks[I].Status = tsActive) or
        ((Tasks[I].Status = tsTodo) and TaskReady(Tasks[I], Tasks))) then
      Exit(True);
end;

{ Ready unassigned work, for an agent that takes from the pool. }
function ReadyPoolTasks(const Project, Agent: string): Integer;
var
  Tasks: TTaskInfoArray;
  Takers: TStringArray;
  I: Integer;
  IsTaker: Boolean;
begin
  Result := 0;
  if Project = '' then Exit;
  Takers := ProjectTakers(Project);
  IsTaker := False;
  for I := 0 to High(Takers) do
    if Takers[I] = Agent then IsTaker := True;
  if not IsTaker then Exit;
  Tasks := ListTasks(Project);
  for I := 0 to High(Tasks) do
    if (Tasks[I].Status = tsTodo) and (Tasks[I].Assignee = '') and
       TaskReady(Tasks[I], Tasks) then
      Inc(Result);
end;

(* How many tasks on the board wait for THIS agent's verdict. A task in
   review is not its owner's to touch -- AgentHasOpenAssignedTask leaves
   it out for that reason -- so without this nothing would wake the one
   agent that can move it. *)
function AgentReviewsWaiting(const Project, Agent: string): Integer;
var
  Tasks: TTaskInfoArray;
  Revs: TStringArray;
  I, K: Integer;
begin
  Result := 0;
  if Project = '' then Exit;
  Tasks := ListTasks(Project);
  for I := 0 to High(Tasks) do
  begin
    if Tasks[I].Status <> tsReview then Continue;
    Revs := TaskReviewers(Project, Tasks[I]);
    for K := 0 to High(Revs) do
      if Revs[K] = Agent then
      begin
        Inc(Result);
        Break;
      end;
  end;
end;

function TeamWakeDecisions(const S: TTeamState): TWakeReasonArray;
var
  I, N, Reviews: Integer;
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
    begin
      Reviews := AgentReviewsWaiting(S.Project, R.Agent);
      if Reviews > 0 then
      begin
        R.Wake := True;
        R.Why := Format('%d task(s) on %s waiting for its verdict',
                        [Reviews, S.Project]);
      end
      else if ReadyPoolTasks(S.Project, R.Agent) > 0 then
      begin
        R.Wake := True;
        R.Why := Format('%d ready unassigned task(s) on %s it can claim',
                        [ReadyPoolTasks(S.Project, R.Agent), S.Project]);
      end
      else
        R.Why := 'nothing to do -- left alone';
    end;
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

function TeamExpireLeases(const T: TTeamTemplate; const S: TTeamState): TStringArray;
var
  Expired, Leads: TStringArray;
  I, L, N, Sp: Integer;
  Id, Holder, Text, Delivered, Err: string;
begin
  SetLength(Result, 0);
  N := 0;
  if S.Project = '' then Exit;
  Expired := ExpireLeases(S.Project, AgentIsBusy);
  if Length(Expired) = 0 then Exit;
  Leads := TeamLeads(T);
  for I := 0 to High(Expired) do
  begin
    Sp := Pos(' ', Expired[I]);
    Id := Copy(Expired[I], 1, Sp - 1);
    Holder := Copy(Expired[I], Sp + 1, MaxInt);
    Text := Format('Task %s on %s was claimed by %s, whose claim ran out ' +
                   'while %s was not running -- the run holding it is gone. ' +
                   'It is back to todo. Reassign it, or let its owner claim ' +
                   'it again with task action="next".',
                   [Id, S.Project, Holder, Holder]);
    for L := 0 to High(Leads) do
      if AgentSend(Leads[L], 'team-tick', Text, Delivered, Err) then
      begin
        SetLength(Result, N + 1);
        Result[N] := Id + ' ' + Holder + ' -> ' + Leads[L];
        Inc(N);
      end;
  end;
end;

{ ------------------------------------------------------------- export -- }

{ Add Nm to Names unless it is already there. Retiring a team draws its
  roster from two places that overlap, and deleting the same agent twice
  would report it removed twice. }
procedure AddOnce(var Names: TStringArray; const Nm: string);
var
  I: Integer;
begin
  if Trim(Nm) = '' then Exit;
  for I := 0 to High(Names) do
    if Names[I] = Nm then Exit;
  SetLength(Names, Length(Names) + 1);
  Names[High(Names)] := Nm;
end;

function RemoveTeam(const Name: string; out Removed: TStringArray;
                    out Err: string): Boolean;
var
  S: TTeamState;
  T: TTeamTemplate;
  Names, Busy: TStringArray;
  I, N: Integer;
  HaveState, HaveTemplate: Boolean;
  Path, DelErr: string;
begin
  Result := False;
  Err := '';
  SetLength(Removed, 0);
  SetLength(Names, 0);
  SetLength(Busy, 0);
  N := 0;

  (* The roster is the TEMPLATE's agent list, not the wake list.

     Those are different things and only look the same on the built-in
     templates, where everyone is wakeable. A custom template can list
     a subset in wake.who on purpose -- a reviewer who should only run
     when something is handed to it, say -- and retiring the team off
     that list deleted the wakeable members, left the rest sitting in
     the roster, and reported the team retired. (Codex P2 on #591.)

     Both sources are read and merged rather than one chosen: the
     template can have been edited since the team was seeded, so an
     agent named only in the saved wake list is still this team's, and
     the state file is all there is for a team whose template is gone. *)
  HaveState    := LoadTeamState(Name, S);
  HaveTemplate := FindTeamTemplate(Name, T);
  if not (HaveState or HaveTemplate) then
  begin
    Err := 'no team called "' + AgentSlug(Name) + '"';
    Exit;
  end;
  if HaveTemplate then
    for I := 0 to High(T.Agents) do AddOnce(Names, AgentSlug(T.Agents[I].Name));
  if HaveState then
    for I := 0 to High(S.WakeWho) do AddOnce(Names, AgentSlug(S.WakeWho[I]));

  (* Refuse while anyone is mid-turn, and refuse before deleting
     ANYTHING -- a half-retired team is worse than one still standing.

     Retiring a single agent already refuses this way; doing it a team
     at a time skipped the check, so `team rm` during a run deleted a
     working agent's manifest and mailbox out from under its own turn.
     The turn keeps going, dispatching tools and then persisting a
     session for an agent that no longer exists. (Codex P1 on #591.) *)
  for I := 0 to High(Names) do
    if AgentIsBusy(Names[I]) then AddOnce(Busy, Names[I]);
  if Length(Busy) > 0 then
  begin
    Err := 'still working:';
    for I := 0 to High(Busy) do
      Err := Err + ' ' + Busy[I];
    Err := Err + ' -- pause first (`pasclaw team pause`, or Pause all ' +
           'on the desktop) and retire once the turn has stopped';
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
