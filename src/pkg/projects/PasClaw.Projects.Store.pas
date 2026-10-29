(*
  PasClaw.Projects.Store - Projects, Tasks and Jobs on disk.

  The desktop's unit of work is a Project: a thing being built, usually an app
  the agent is producing. Inside it are Tasks (units of intent) and inside
  those, Jobs (individual agent runs). The whole tree lives under the active
  workspace, one directory per node, one JSON manifest per node:

    <workspace>/projects/
      spam-filter/
        project.json          { name, title, description, created, updated }
        app/                  the app being built (see PasClaw.Apps)
        tasks/
          T0001/
            task.json         { id, title, status, notes, criteria, assignee,
                                submission, verdict, created, updated }
            jobs/
              J0001/
                job.json      { id, status, session_id, started, ended, summary }
                artifacts/
        activity.jsonl        who moved which task, and why -- append-only

  Files are the database, exactly as sessions and cron already are: greppable,
  syncable, no migration, and a user poking around $PASCLAW_HOME sees what the
  UI shows. Ids are zero-padded ordinals so a directory listing sorts
  chronologically without reading a single manifest.

  Names arrive from two untrusted places -- the model (via the project tools)
  and HTTP (via the gateway) -- so SanitizeName is the only way a caller gets
  a project directory, and every read/write path is built from it.
*)
unit PasClaw.Projects.Store;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Utils;   { TStringArray -- one spelling for both compilers }

type
  (* tsReview is APPENDED, not slotted in beside tsActive: the stored form
     is the string, but an ordinal anyone persisted or switched on must not
     move. A task in review has been submitted and waits for someone other
     than its builder to give the verdict (SubmitTask / VerdictTask). *)
  TTaskStatus = (tsTodo, tsActive, tsDone, tsBlocked, tsReview);
  TJobStatus  = (jsQueued, jsRunning, jsDone, jsFailed, jsCancelled);

const
  (* Who a store call is made AS.

     '' is the operator: the desktop, an HTTP route, the CLI -- a person,
     and the authority review exists for, so the review rules do not bind
     them and what they do is recorded as theirs. Any other value is an
     agent slug, or ActorModel for a model turn that is not a standing
     agent's (the desktop chat, a background subagent, a job run). That
     one is NOT the operator: "we could not tell who called" must never
     read as "a person called", or every unattributed turn would hold the
     operator's override. ActorModel has a character no slug can, so no
     agent can be named into it. *)
  ActorOperator = '';
  ActorModel    = '(model)';

type
  TProjectInfo = record
    Name:        string;   { directory name / slug -- the identity }
    Title:       string;   { display name }
    Description: string;
    Created:     string;   { ISO-8601 UTC }
    Updated:     string;
    Icon:        string;   { desktop icon hint, e.g. 'Mail' }
    Suite:       Boolean;  { part of the seeded system suite (§2c) }
    HasApp:      Boolean;  { app/app.json present }
    (* Filed away: still on disk, still openable, out of the dock's
       default list.

       Projects only ever accumulated. A board whose tasks are all done
       looked exactly like one being worked on, and the only way to get
       it off the list was DELETE -- which destroys the tasks, the job
       history and the app the team built. "Finished" and "unwanted"
       are different things, and a stop button that only offers
       destruction is not a stop button. *)
    Archived:    Boolean;
    TaskCount:   Integer;
    (* Tasks that still need someone: todo + active. NOT blocked --
       blocked work is waiting on something, and counting it as open
       would put it in the "get on with it" badge where nobody can act
       on it. *)
    OpenTasks:   Integer;
    (* ...which is exactly why the other two are counted separately.
       "No open tasks" is not the same as "everything is done": a board
       of nothing but blocked tasks has an open count of zero and is
       the furthest thing from finished. Anything asking whether a
       project is DONE has to ask about DoneTasks, and anything drawing
       a board's state needs BlockedTasks or it will show a project
       with stuck work as having nothing going on at all. *)
    DoneTasks:    Integer;
    BlockedTasks: Integer;
    (* Submitted and waiting for a verdict. Also counted in OpenTasks --
       someone (the reviewer) still has to act -- and never in DoneTasks:
       work its builder calls finished is exactly what this state exists
       to keep apart from work that is. *)
    ReviewTasks:  Integer;
    (* The board requires a second agent's verdict: an agent cannot set
       its own task done, a finished job submits instead of closing, and
       the operator can still close anything. `team up` sets it; a
       project made by hand does not, so one person building one app
       sees no change. *)
    Review:       Boolean;
    (* Who gives verdicts here, when the team named them (template
       review.by). Empty = the submitter's parent. Either way a submitter
       never reviews its own work. *)
    Reviewers:    TStringArray;
    (* Agents that may claim UNASSIGNED ready work with `task action=next`
       (template `takes: "any"`). Everyone else takes only what was routed
       to them. *)
    Takers:       TStringArray;
  end;
  TProjectInfoArray = array of TProjectInfo;

  TTaskInfo = record
    Id:      string;   { 'T0001' }
    Project: string;
    Title:   string;
    Status:  TTaskStatus;
    Notes:   string;
    (* Which agent owns this task; '' = unassigned. An agent slug, set
       by a lead through the task tool. Recorded on the board rather
       than only said in a message, because a message is invisible to
       the wake loop and to the other workers -- two agents grabbing
       the same task is exactly what an unrecorded assignment allows. *)
    Assignee: string;
    (* The acceptance checks, one per line, kept apart from Notes so they
       can be held still: written while the task waits, frozen once work
       starts (see UpdateTask), and what a verdict is judged against. *)
    Criteria: string;
    { When work first started; '' until then, and cleared by a reopen
      (status todo). This, not the status, is what freezes Criteria:
      a task blocked after it started has still been started. }
    Started:  string;
    { The last submission (SubmitTask). }
    SubmittedBy:  string;
    SubmittedAt:  string;
    Evidence:     string;   { what was run and what it printed }
    SubmittedJob: string;
    { The copy of the project taken at that submission
      (PasClaw.Projects.Snapshots); '' when none could be taken. }
    SubmittedSnapshot: string;
    { The verdict on that submission (VerdictTask); cleared by the next
      submit, so a task back in review never shows the old verdict. }
    Verdict:      string;   { 'accept' | 'reject' | '' }
    { A reject's cause: a short slug the reviewer picks
      ("untested-empty-input"), the same across tasks, so a cause that
      keeps rejecting work can be noticed and turned into a rule. }
    VerdictCause: string;
    VerdictBy:    string;
    VerdictAt:    string;
    VerdictNote:  string;
    (* Tasks this one needs first ('T0002'). It is READY when every one of
       them is done -- computed (TaskReady), never stored, so it cannot go
       stale. `blocked` stays for waits outside the board. *)
    WaitsOn:      TStringArray;
    (* The claim on active work: who holds it and until when (a stamp of
       IsoUtcInMinutes's shape). Written when an agent starts or claims
       the task, renewed whenever its owner touches it, cleared when it
       leaves active. A lease that runs out while its holder runs no turn
       is a claim held by a run that died (ExpireLeases). *)
    LeaseBy:      string;
    LeaseUntil:   string;
    { 'pool' when `next` took it unassigned -- an expired lease hands such
      a task back to the pool rather than to whoever had it. }
    ClaimedFrom:  string;
    Created: string;
    Updated: string;
    JobCount: Integer;
  end;
  TTaskInfoArray = array of TTaskInfo;

  TJobInfo = record
    Id:        string;   { 'J0001' }
    Project:   string;
    Task:      string;
    Status:    TJobStatus;
    SessionId: string;
    Started:   string;
    Ended:     string;
    Summary:   string;
  end;
  TJobInfoArray = array of TJobInfo;

{ ---- names ---- }

{ Fold an arbitrary string into a safe directory slug: lowercase, [a-z0-9-],
  runs collapsed, trimmed. Returns '' when nothing usable survives, which
  every caller must treat as a rejection. This is the ONLY way to turn
  caller-supplied text into a path segment. }
(* A goal sentence turned into a short project TITLE.

   "A book comparison app: enter up to 4 book titles and compare them
   side by side" is a fine goal and a terrible folder name -- it became
   a 63-character slug that then appeared in every path, every task
   listing and every message the team sent. The desktop's Ask path has
   derived a short title from a brief for a long time
   (deriveProjectTitle in desktop.html); this is the same rule where
   the server can reach it, so `team up --goal` and the CLI name things
   the way the desktop does.

   Drops the request framing ("build me a", "I want a"), keeps the
   first clause, and trims to a few words on a word boundary -- never
   mid-word, and never leaving a dangling preposition. Falls back to
   the original text when trimming would leave nothing.

   Deliberately NOT a slug: it returns a human title, and
   CreateProject slugifies it as it does any other title. *)
function GoalToTitle(const Goal: string): string;

function SanitizeName(const S: string): string;

{ True when S is already a safe slug (what SanitizeName would return). }
function IsSafeName(const S: string): Boolean;

{ ---- paths ---- }

function ProjectsRoot: string;                         { <workspace>/projects }
function ProjectDir(const Project: string): string;    { '' when unsafe }
function ProjectAppDir(const Project: string): string;
function TaskDir(const Project, TaskId: string): string;
function JobDir(const Project, TaskId, JobId: string): string;

{ ---- projects ---- }

function ProjectExists(const Project: string): Boolean;
function ListProjects: TProjectInfoArray;
function GetProject(const Project: string; out Info: TProjectInfo): Boolean;

{ Create a project. ATitle is free text; the directory name is derived from it
  unless AName is given. Returns the created slug, or '' with Err set. An
  existing project of the same name is returned as-is (idempotent), so the
  agent re-running a create step doesn't fail the job. }
function CreateProject(const ATitle, AName, ADescription: string;
  out Err: string): string;

function UpdateProject(const Project, ATitle, ADescription, AIcon: string;
  out Err: string): Boolean;

(* File a project away, or bring it back. Nothing is moved and nothing
   is deleted -- one flag in project.json -- so an archived project's
   tasks, jobs, app and chat are all exactly where they were and
   un-archiving is instant.

   Deliberately NOT automatic on "all tasks done". A board that empties
   is a board that is very often about to get its next task, and a list
   that hides work the moment it goes green would have people chasing
   projects that vanished under them. Finishing is the machine's
   observation; filing away is the operator's decision. *)
function SetProjectArchived(const Project: string; Archived: Boolean;
  out Err: string): Boolean;

(* Require (or stop requiring) a second agent's verdict on this board, and
   name who gives it. Reviewers are agent slugs; an empty list means the
   submitter's parent. Like archiving, `updated` does not move: a rule
   about the board is not work on it. *)
function SetProjectReview(const Project: string; Review: Boolean;
  const Reviewers: TStringArray; out Err: string): Boolean;
function ProjectRequiresReview(const Project: string): Boolean;
{ The reviewers alone, from the manifest -- without loading the board,
  which GetProject does to count it. The wake loop asks this per task. }
function ProjectReviewers(const Project: string): TStringArray;

type
  (* A team agent's lane on a board: path globs, relative to the workspace
     ("projects/shop/app/**"), it may write inside -- and only there. *)
  TLane = record
    Agent: string;
    Globs: TStringArray;
  end;
  TLaneArray = array of TLane;

function SetProjectLanes(const Project: string; const Lanes: TLaneArray;
  out Err: string): Boolean;
function ProjectLanes(const Project: string): TLaneArray;
(* Every lane on every board in the workspace, from the manifests alone --
   the write check asks this per call, so it must not load the boards. *)
function AllLanes: TLaneArray;

{ Who may claim unassigned work here (see TProjectInfo.Takers). }
function SetProjectTakers(const Project: string; const Takers: TStringArray;
  out Err: string): Boolean;
function ProjectTakers(const Project: string): TStringArray;

(* Where the operator keeps this project's held-out checks:
   $PASCLAW_HOME/scenarios/<workspace>/<project>/ -- OUTSIDE the
   workspace, for the reason PasClaw.Agent.Verify gives: a check the
   builder can open in projects/<p>/ is a check it can "fix". '' for an
   unsafe name. *)
function ProjectScenariosDir(const Project: string): string;

{ Remove a project and everything under it. Refuses unsafe names. }
function DeleteProject(const Project: string; out Err: string): Boolean;

{ ---- tasks ---- }

function TaskStatusToStr(S: TTaskStatus): string;
function StrToTaskStatus(const S: string; Default: TTaskStatus = tsTodo): TTaskStatus;

function ListTasks(const Project: string): TTaskInfoArray;
function GetTask(const Project, TaskId: string; out Info: TTaskInfo): Boolean;
function CreateTask(const Project, ATitle, ANotes: string; out Err: string;
  const ACriteria: string = ''; const Actor: string = ActorOperator): string;
(* AAssignee and ACriteria follow the same two-sentinel contract as notes:
   '-' means leave it alone; '' explicitly clears it.

   Actor is who is asking (ActorOperator, an agent slug, ActorModel). For
   anyone but the operator:
     - status "done" on a board that requires review is refused, naming
       the submit it should have been;
     - a task in review does not change status -- only a verdict moves it;
     - criteria are frozen once work has started, and the builder never
       writes its own.
   "review" is never a status you set: SubmitTask is how a task gets
   there, because the submission (evidence, who, which job) is the point. *)
function UpdateTask(const Project, TaskId, ATitle, ANotes: string;
  const AStatus: string; out Err: string;
  const AAssignee: string = '-'; const ACriteria: string = '-';
  const Actor: string = ActorOperator): Boolean;

(* The builder hands work over for a verdict: todo/active -> review.
   Evidence is required -- what was run and what it printed -- because a
   submission is a claim, and a claim with nothing behind it is the move
   review exists to stop. Runs OnSubmitGate first (outside every lock)
   and refuses a red result with its report. *)
function SubmitTask(const Project, TaskId, Actor, Evidence, JobId: string;
  out Err: string): Boolean;

(* A verdict on a task in review. Accept closes it; reject needs a reason,
   puts it back to active with the same owner, and appends the reason to
   its notes where the builder reads them.

   Refused, for anyone but the operator, when the caller is the
   submitter or the task's owner, when the caller is unknown (ActorModel:
   a verdict that cannot tell who is giving it must refuse, never default
   to allow), and -- when Reviewers is non-empty -- when the caller is not
   one of them. Reviewers is the CALLER's answer to "who reviews this"
   (PasClaw.Teams.TaskReviewers); the store does not know the org chart.
   Cause is a reject's cause key (slugged); '' for none. *)
function VerdictTask(const Project, TaskId, Actor: string; Accept: Boolean;
  const Note: string; const Reviewers: TStringArray;
  out Err: string; const Cause: string = ''): Boolean;

type
  { Told after a reject that named a cause, however it was given. }
  TTaskRejectedHook = procedure(const Project, TaskId, Cause: string);

var
  (* PasClaw.Projects.Tools installs one that counts the cause across the
     board and, the second time it rejects work, tells the lead -- the
     first step from a repeated mistake to a proven rule (Phase 4). *)
  OnTaskRejected: TTaskRejectedHook = nil;

(* A project's lists of causes: 'rule_causes' (a proven rule exists for
   it) and 'declined_causes' (the operator said no to a rule for it, so it
   does not nag again). Slugged. *)
function ProjectCauses(const Project, Key: string): TStringArray;
function AddProjectCause(const Project, Key, Cause: string; out Err: string): Boolean;

(* The receipts: projects/<p>/activity.jsonl, one JSON object per line
   ({"at","task","event","by",...}), oldest first. Every create, assign,
   start, submit, accept, reject, reopen, status and criteria change made
   through this unit is recorded HERE rather than by a caller, so the HTTP
   route and the desktop leave the same trail the task tool does.
   TaskId '' = the whole board; Limit > 0 keeps the newest Limit lines. *)
function ReadActivity(const Project, TaskId: string;
  Limit: Integer = 0): TStringArray;
(* A receipt from outside the store -- a rule approved or declined is the
   board's history too. Pairs is key, value, key, value. *)
procedure RecordActivity(const Project, TaskId, Event, Actor: string;
  const Pairs: array of string);

(* What this task waits on. Every id must name another task on the same
   board, and an edge that would close a cycle is refused -- a cycle is a
   board where nothing can ever become ready, and the moment it is set is
   the only moment the fix is obvious. An empty list clears it. *)
function SetTaskWaitsOn(const Project, TaskId: string;
  const WaitsOn: TStringArray; const Actor: string; out Err: string): Boolean;

{ Every task this one waits on is done. Board is the project's tasks
  (ListTasks), passed in so a caller walking the board reads it once. }
function TaskReady(const T: TTaskInfo; const Board: TTaskInfoArray): Boolean;
{ The ids it still waits on -- not done, or not on the board at all. }
function TaskWaitingOn(const T: TTaskInfo; const Board: TTaskInfoArray): TStringArray;

(* `task action=next`: give Agent its next piece of work, atomically.

   The oldest ready todo task assigned to Agent; else, when AllowPool
   (Agent is one of the project's takers), the oldest ready UNASSIGNED
   one. Scanned and claimed under one lock, so two agents asking at once
   get two different tasks or one hears "nothing ready" -- never the
   same task twice. The claim sets the owner, `active`, and a lease.
   False with Err '' means nothing was ready (Err says why otherwise). *)
function ClaimNextTask(const Project, Agent: string; AllowPool: Boolean;
  out TaskId, Err: string): Boolean;

{ How long a claim lasts without its owner touching the task. Set from
  teams.claim_lease_minutes at startup; 120 by default. }
procedure SetClaimLeaseMinutes(Minutes: Integer);
function ClaimLeaseMinutes: Integer;

type
  TBusyProbe = function(const Agent: string): Boolean;

(* Hand back active tasks whose lease ran out while their holder runs no
   turn -- the same turn-lock test supervision uses to find a dead run, so
   a long legitimate turn is never cut. Each goes back to `todo` with an
   `expire` receipt; a task claimed from the pool goes back unassigned.
   Returns "T0003 dev" per task handed back, for the caller to report. *)
function ExpireLeases(const Project: string; Busy: TBusyProbe): TStringArray;

type
  { Called after a task reaches done, however it got there. }
  TTaskClosedHook = procedure(const Project, TaskId: string);

var
  (* PasClaw.Projects.Tools installs one that tells the owners of tasks
     that were waiting on this one -- and are now ready -- that they can
     start. A message is what makes their team due now rather than at
     the next cadence. *)
  OnTaskClosed: TTaskClosedHook = nil;

type
  { Called after a task changes hands -- to Assignee, by Actor. }
  TTaskAssignedHook = procedure(const Project, TaskId, Assignee, Actor: string);

var
  (* PasClaw.Projects.Tools installs one that tells the new owner, when
     the task is theirs to start. Without it a handoff waited out the
     team's cadence -- fifteen minutes by default -- for the wake loop
     to notice an open assigned task. Not called when an agent takes a
     task itself: nobody needs telling. *)
  OnTaskAssigned: TTaskAssignedHook = nil;

type
  (* Run before a submission is accepted. True = green (or nothing to
     run); False refuses the submit with Report. A hook rather than a
     call because what counts as green is the agent layer's business --
     the scenario runner pulls in the shell backend, and the store is
     linked into binaries that should not. PasClaw.Projects.Tools installs
     the held-out scenario gate. *)
  TSubmitGate = function(const Project, TaskId: string;
    out Report: string): Boolean;

var
  OnSubmitGate: TSubmitGate = nil;

{ The display name for an actor: 'operator' for '', else as given. }
function ActorLabel(const Actor: string): string;

{ ---- jobs ---- }

function JobStatusToStr(S: TJobStatus): string;
function StrToJobStatus(const S: string; Default: TJobStatus = jsQueued): TJobStatus;

function ListJobs(const Project, TaskId: string): TJobInfoArray;
function GetJob(const Project, TaskId, JobId: string; out Info: TJobInfo): Boolean;

{ Open a job under a task. The runtime calls this when an agent turn or a
  background subagent starts working the task, so transcripts and status wire
  up without the model having to remember to. }
function CreateJob(const Project, TaskId, ASessionId: string; out Err: string): string;
function UpdateJob(const Project, TaskId, JobId, AStatus, ASummary,
  ASessionId: string; out Err: string;
  const Actor: string = ActorOperator): Boolean;

(* UpdateJob, and what finishing the job did to its task. On a board that
   requires review a job that finishes done SUBMITS the task rather than
   closing it; SubmitErr is why that submit was refused ('' when it was
   not refused or not attempted). The task tool reports it to the model;
   UpdateJob, whose callers have nobody to tell, writes it to the job log. *)
function FinishJob(const Project, TaskId, JobId, AStatus, ASummary: string;
  const Actor: string; out Err, SubmitErr: string): Boolean;

{ Append a line to a job's log (jobs/<id>/job.log). The desktop tails this. }
procedure AppendJobLog(const Project, TaskId, JobId, Line: string);
function ReadJobLog(const Project, TaskId, JobId: string): string;

implementation

uses
  SyncObjs,
  PasClaw.JSON,
  PasClaw.Config,       { GetHome -- the held-out scenarios live beside, not in, the workspace }
  PasClaw.Projects.Snapshots,  { the project as submitted }
  PasClaw.Workspaces,
  PasClaw.Desktop.Events;

var
  (* Guards id allocation. NextId picks max+1 by SCANNING the directory,
     which is a read-then-write with a window in the middle: two gateway
     worker threads creating tasks at the same moment both scanned, both
     saw T0004 as the highest, and both took T0005 -- the second write
     landing on the first one's manifest and erasing it.

     Not theoretical. Eight simultaneous creates against a live gateway
     produced seven tasks: two callers were handed the same id and one
     item vanished, silently, with a 200 for both. It went unnoticed
     while every writer was sequential; the desktop's checklist mirror
     now reconciles concurrently, which is what made it reachable.

     One process-wide lock is the right grain here: allocation is a
     directory scan measured in microseconds, and the alternative --
     a lock per project -- buys nothing until projects are being written
     to in parallel at a rate this never approaches. *)
  GIdLock: TCriticalSection = nil;

  (* Guards a task's read-check-write. The review rules are decisions
     about the task's CURRENT state ("is it in review", "who submitted
     it"), and a check made on a copy read before another thread wrote is
     a check on a task that no longer exists: two reviewers answering at
     once would both see "review" and the second verdict would land on a
     task the first had already closed. One lock, for the reason GIdLock
     gives: the work inside is a manifest read and write. Never held
     while the submit gate runs -- that runs scenarios. *)
  GTaskLock: TCriticalSection = nil;
  { Appends to activity.jsonl from concurrent threads must not interleave. }
  GActivityLock: TCriticalSection = nil;
  { teams.claim_lease_minutes; written once at startup. }
  GLeaseMinutes: Integer = 120;

{ ------------------------------------------------------------------ names -- }


const
  { Words a title should never END on -- a trailing preposition or
    article reads as a sentence that was cut off, because it was. }
  TitleTailWords =
    ' a an the my our your its their this that these those and or but ' +
    'with for to of in on at from by into using is are be as some any ';
  { Where a title may be cut when it is too long: at a joining word,
    which is usually where the qualification starts. }
  TitleCutWords =
    ' with for to of in on at from by into using and or but so plus ';
  { Comfortably inside the 64-character slug cap, leaving room for the
    collision suffix a free-name search appends. }
  TitleMaxChars = 48;

function GoalToTitle(const Goal: string): string;
var
  S, Low, W: string;
  Words: TStringList;
  I, P: Integer;
  Cut: Boolean;

  function StripLead(const Text, Prefix: string): string;
  begin
    Result := Text;
    if (Length(Text) > Length(Prefix)) and
       SameText(Copy(Text, 1, Length(Prefix)), Prefix) then
      Result := TrimLeft(Copy(Text, Length(Prefix) + 1, MaxInt));
  end;

  function IsIn(const List, Word_: string): Boolean;
  var
    Bare: string;
    K: Integer;
  begin
    Bare := '';
    for K := 1 to Length(Word_) do
      if ((Word_[K] >= 'a') and (Word_[K] <= 'z')) or
         ((Word_[K] >= 'A') and (Word_[K] <= 'Z')) then
        Bare := Bare + LowerCase(Word_[K]);
    Result := (Bare <> '') and (Pos(' ' + Bare + ' ', List) > 0);
  end;

begin
  S := Trim(Goal);
  if S = '' then Exit('');

  { The request framing, in the order people write it. Spelled out
    rather than looped over a literal array: the lengths differ, and
    one wrong prefix silently eats the first letters of the thing
    being named -- "create an invoice tracker" became "e an invoice
    tracker" the first time round. }
  S := StripLead(S, 'please ');
  S := StripLead(S, 'can you ');
  Low := S;
  S := StripLead(S, 'make ');
  if S = Low then S := StripLead(S, 'build ');
  if S = Low then S := StripLead(S, 'create ');
  if S = Low then S := StripLead(S, 'write ');
  if S = Low then S := StripLead(S, 'design ');
  if S = Low then S := StripLead(S, 'generate ');
  if S = Low then S := StripLead(S, 'give ');
  S := StripLead(S, 'me ');
  Low := S;
  S := StripLead(S, 'i want ');
  if S = Low then S := StripLead(S, 'i need ');
  if S = Low then S := StripLead(S, 'i would like ');
  S := StripLead(S, 'a ');
  { The leading article: "Stopwatch" beats "A Stopwatch" as a name.
    Longest first, so "an" is not read as "a" plus a stray "n". }
  Low := S;
  S := StripLead(S, 'the ');
  if S = Low then S := StripLead(S, 'an ');
  if S = Low then S := StripLead(S, 'a ');

  (* First clause only. A sentence end is punctuation followed by a
     space or the end -- not every '.' in the text, or "a Node.js
     dashboard" loses the word that said what it was. A colon ends the
     preamble the same way: "Book compare: enter four URLs" is titled
     by its first half. *)
  for I := 1 to Length(S) do
    if (S[I] = #10) or (S[I] = #13) or (S[I] = ':') or
       (((S[I] = '.') or (S[I] = '!') or (S[I] = '?')) and
        ((I = Length(S)) or (S[I + 1] = ' '))) then
    begin
      S := Trim(Copy(S, 1, I - 1));
      Break;
    end;

  Words := TStringList.Create;
  try
    Words.Delimiter := ' ';
    Words.StrictDelimiter := False;
    Words.DelimitedText := S;
    for I := Words.Count - 1 downto 0 do
      if Trim(Words[I]) = '' then Words.Delete(I);
    if Words.Count = 0 then Exit(Trim(Goal));

    Cut := Words.Count > 6;
    while Words.Count > 6 do Words.Delete(Words.Count - 1);

    { Character budget, on a word boundary. }
    while (Words.Count > 2) and
          (Length(StringReplace(Words.DelimitedText, ',', ' ', [rfReplaceAll]))
             > TitleMaxChars) do
    begin
      Words.Delete(Words.Count - 1);
      Cut := True;
    end;

    { Never end on a preposition or article. }
    while (Words.Count > 2) and IsIn(TitleTailWords, Words[Words.Count - 1]) do
    begin
      Words.Delete(Words.Count - 1);
      Cut := True;
    end;

    { When something was dropped, prefer cutting at a joining word --
      that is usually where the qualification began. }
    if Cut then
      for I := Words.Count - 1 downto 2 do
        if IsIn(TitleCutWords, Words[I]) then
        begin
          while Words.Count > I do Words.Delete(Words.Count - 1);
          Break;
        end;

    Result := '';
    for I := 0 to Words.Count - 1 do
      if Result = '' then Result := Words[I]
                     else Result := Result + ' ' + Words[I];
  finally
    Words.Free;
  end;

  { Trailing punctuation from the clause split. }
  while (Result <> '') and
        ((Result[Length(Result)] = ',') or (Result[Length(Result)] = ';') or
         (Result[Length(Result)] = ':')) do
    Delete(Result, Length(Result), 1);
  Result := Trim(Result);

  { Hard bound whatever the word count -- one enormous token sails past
    the loop above, and past the slug cap a collision suffix falls off
    the end so every retry sanitizes to the same existing name. }
  if Length(Result) > TitleMaxChars then
  begin
    Result := Copy(Result, 1, TitleMaxChars);
    P := LastDelimiter(' ', Result);
    if P > TitleMaxChars div 2 then Result := Trim(Copy(Result, 1, P - 1));
  end;

  if Result = '' then Result := Trim(Goal);
end;

function SanitizeName(const S: string): string;
var
  I: Integer;
  C: Char;
  Prev: Char;
begin
  Result := '';
  Prev := #0;
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      'A'..'Z': C := Chr(Ord(C) + 32);
      'a'..'z', '0'..'9': ;
      else
        C := '-';
    end;
    { Collapse separator runs so "My  App!!" doesn't become "my--app--". }
    if (C = '-') and (Prev = '-') then
      Continue;
    { ...and never lead with one, which would also read as a CLI flag. }
    if (C = '-') and (Result = '') then
      Continue;
    Result := Result + C;
    Prev := C;
  end;
  while (Result <> '') and (Result[Length(Result)] = '-') do
    SetLength(Result, Length(Result) - 1);
  { Length cap: these become directory names on every supported filesystem. }
  if Length(Result) > 64 then
  begin
    SetLength(Result, 64);
    while (Result <> '') and (Result[Length(Result)] = '-') do
      SetLength(Result, Length(Result) - 1);
  end;
end;

function IsSafeName(const S: string): Boolean;
begin
  Result := (S <> '') and (S = SanitizeName(S));
end;

{ ------------------------------------------------------------------ paths -- }

function ProjectsRoot: string;
begin
  Result := WorkspacePath('projects');
end;

function ProjectDir(const Project: string): string;
begin
  if not IsSafeName(Project) then
    Exit('');
  Result := JoinPath(ProjectsRoot, Project);
end;

function ProjectAppDir(const Project: string): string;
var
  Dir: string;
begin
  Dir := ProjectDir(Project);
  if Dir = '' then Exit('');
  Result := JoinPath(Dir, 'app');
end;

function IsTaskId(const Id: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(Id) < 2 then Exit;
  if (Id[1] <> 'T') and (Id[1] <> 't') then Exit;
  for I := 2 to Length(Id) do
    if not (Id[I] in ['0'..'9']) then Exit;
  Result := True;
end;

function IsJobId(const Id: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(Id) < 2 then Exit;
  if (Id[1] <> 'J') and (Id[1] <> 'j') then Exit;
  for I := 2 to Length(Id) do
    if not (Id[I] in ['0'..'9']) then Exit;
  Result := True;
end;

function TaskDir(const Project, TaskId: string): string;
var
  Dir: string;
begin
  Result := '';
  Dir := ProjectDir(Project);
  if (Dir = '') or not IsTaskId(TaskId) then Exit;
  Result := JoinPath(JoinPath(Dir, 'tasks'), UpperCase(TaskId));
end;

function JobDir(const Project, TaskId, JobId: string): string;
var
  Dir: string;
begin
  Result := '';
  Dir := TaskDir(Project, TaskId);
  if (Dir = '') or not IsJobId(JobId) then Exit;
  Result := JoinPath(JoinPath(Dir, 'jobs'), UpperCase(JobId));
end;

{ ------------------------------------------------------------- shared I/O -- }

function ReadManifest(const Path: string): TJsonObject;
begin
  Result := nil;
  if not FileExists(Path) then Exit;
  try
    Result := TJsonObject.Parse(ReadFileText(Path));
  except
    Result := nil;   { a corrupt manifest must not take down a listing }
  end;
end;

procedure WriteManifest(const Path: string; Obj: TJsonObject);
begin
  EnsureDir(ExtractFileDir(Path));
  WriteFileText(Path, Obj.ToJSON);
end;

{ Directory names under Dir, sorted. Used for tasks/ and jobs/ where the
  zero-padded ids make lexical order chronological. }
function SubdirNames(const Dir: string): TStringList;
var
  Rec: TSearchRec;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, Rec) = 0 then
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then Continue;
        if (Rec.Attr and faDirectory) <> 0 then
          Result.Add(Rec.Name);
      until FindNext(Rec) <> 0;
    finally
      FindClose(Rec);
    end;
end;

{ Next free zero-padded id under Dir, e.g. NextId('.../tasks', 'T') -> 'T0003'.
  Reads the directory rather than a counter file so a manually created or
  deleted directory can't desync a stored high-water mark. }
function NextId(const Dir, Prefix: string): string;
var
  Names: TStringList;
  I, N, Max_: Integer;
begin
  Max_ := 0;
  Names := SubdirNames(Dir);
  try
    for I := 0 to Names.Count - 1 do
      if (Length(Names[I]) > 1) and (UpperCase(Names[I][1]) = Prefix) then
      begin
        N := StrToIntDef(Copy(Names[I], 2, MaxInt), 0);
        if N > Max_ then Max_ := N;
      end;
  finally
    Names.Free;
  end;
  Result := Prefix + Format('%.4d', [Max_ + 1]);
end;

function ReserveId(const Dir, Prefix: string): string;
{ Allocate the next id and STAKE it, under one lock.

  Creating the directory is what makes the reservation visible: NextId
  decides by scanning subdirectories, so a caller that has taken an id
  but not yet made its directory is invisible to the next scanner. Doing
  both inside the lock closes that window; the manifest write afterwards
  does not need to be held, because the id is already spoken for. }
begin
  GIdLock.Enter;
  try
    Result := NextId(Dir, Prefix);
    EnsureDir(JoinPath(Dir, Result));
  finally
    GIdLock.Leave;
  end;
end;

{ --------------------------------------------------------------- projects -- }

function ProjectExists(const Project: string): Boolean;
var
  Dir: string;
begin
  Dir := ProjectDir(Project);
  Result := (Dir <> '') and DirectoryExists(Dir);
end;

{ A names array of a manifest ("reviewers", "takers", "waits_on"),
  canonicalised by Canon; empty when absent. }
function ManifestNames(Obj: TJsonObject; const Key: string;
  TaskIds: Boolean = False): TStringArray;
var
  Arr: TJsonArray;
  I, N: Integer;
  S: string;
begin
  SetLength(Result, 0);
  if Obj = nil then Exit;
  Arr := Obj.ChildArray(Key);
  if Arr = nil then Exit;
  try
    SetLength(Result, Arr.Count);
    N := 0;
    for I := 0 to Arr.Count - 1 do
    begin
      if TaskIds then S := UpperCase(Trim(Arr.ItemStr(I)))
                 else S := SanitizeName(Arr.ItemStr(I));
      if S = '' then Continue;
      Result[N] := S;
      Inc(N);
    end;
    SetLength(Result, N);
  finally
    Arr.Free;
  end;
end;

function LoadProject(const Project: string; out Info: TProjectInfo): Boolean;
var
  Obj: TJsonObject;
  Dir: string;
  Tasks: TTaskInfoArray;
  I: Integer;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Name := ''; Info.Title := ''; Info.Description := '';
  Info.Created := ''; Info.Updated := ''; Info.Icon := '';
  Dir := ProjectDir(Project);
  if (Dir = '') or not DirectoryExists(Dir) then Exit;

  Info.Name := Project;
  Info.Title := Project;
  Obj := ReadManifest(JoinPath(Dir, 'project.json'));
  if Obj <> nil then
    try
      Info.Title       := Obj.GetStr('title', Project);
      Info.Description := Obj.GetStr('description', '');
      Info.Created     := Obj.GetStr('created', '');
      Info.Updated     := Obj.GetStr('updated', '');
      Info.Icon        := Obj.GetStr('icon', '');
      Info.Suite       := Obj.GetBool('suite', False);
      Info.Archived    := Obj.GetBool('archived', False);
      Info.Review      := Obj.GetBool('review', False);
      Info.Reviewers   := ManifestNames(Obj, 'reviewers');
      Info.Takers      := ManifestNames(Obj, 'takers');
    finally
      Obj.Free;
    end;
  Info.HasApp := FileExists(JoinPath(JoinPath(Dir, 'app'), 'app.json'));

  Tasks := ListTasks(Project);
  Info.TaskCount    := Length(Tasks);
  Info.OpenTasks    := 0;
  Info.DoneTasks    := 0;
  Info.BlockedTasks := 0;
  Info.ReviewTasks  := 0;
  for I := 0 to High(Tasks) do
    case Tasks[I].Status of
      tsTodo, tsActive: Inc(Info.OpenTasks);
      tsDone:           Inc(Info.DoneTasks);
      tsBlocked:        Inc(Info.BlockedTasks);
      tsReview:
        begin
          Inc(Info.OpenTasks);
          Inc(Info.ReviewTasks);
        end;
    end;
  Result := True;
end;

function GetProject(const Project: string; out Info: TProjectInfo): Boolean;
begin
  Result := LoadProject(Project, Info);
end;

function ListProjects: TProjectInfoArray;
var
  Names: TStringList;
  I, N: Integer;
  Info: TProjectInfo;
begin
  SetLength(Result, 0);
  Names := SubdirNames(ProjectsRoot);
  try
    SetLength(Result, Names.Count);
    N := 0;
    for I := 0 to Names.Count - 1 do
      if LoadProject(Names[I], Info) then
      begin
        Result[N] := Info;
        Inc(N);
      end;
    SetLength(Result, N);
  finally
    Names.Free;
  end;
end;

function CreateProject(const ATitle, AName, ADescription: string;
  out Err: string): string;
var
  Slug, Dir, Now_: string;
  Obj: TJsonObject;
begin
  Err := '';
  Result := '';
  if Trim(AName) <> '' then
    Slug := SanitizeName(AName)
  else
    Slug := SanitizeName(ATitle);
  if Slug = '' then
  begin
    Err := 'a project needs a name with at least one letter or digit';
    Exit;
  end;

  Dir := JoinPath(ProjectsRoot, Slug);
  { Idempotent: the agent re-running its own create step should not fail the
    job, it should carry on with the project that is already there. }
  if DirectoryExists(Dir) then
    Exit(Slug);

  Now_ := NowIsoUtc;
  EnsureDir(Dir);
  EnsureDir(JoinPath(Dir, 'tasks'));
  EnsureDir(JoinPath(Dir, 'app'));

  Obj := TJsonObject.Create;
  try
    Obj.PutStr('name', Slug);
    if Trim(ATitle) <> '' then
      Obj.PutStr('title', Trim(ATitle))
    else
      Obj.PutStr('title', Slug);
    Obj.PutStr('description', ADescription);
    Obj.PutStr('created', Now_);
    Obj.PutStr('updated', Now_);
    WriteManifest(JoinPath(Dir, 'project.json'), Obj);
  finally
    Obj.Free;
  end;
  PublishProjects;
  Result := Slug;
end;

function UpdateProject(const Project, ATitle, ADescription, AIcon: string;
  out Err: string): Boolean;
var
  Dir, Path: string;
  Obj: TJsonObject;
begin
  Err := '';
  Result := False;
  Dir := ProjectDir(Project);
  if (Dir = '') or not DirectoryExists(Dir) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;
  Path := JoinPath(Dir, 'project.json');
  Obj := ReadManifest(Path);
  if Obj = nil then
  begin
    Obj := TJsonObject.Create;
    Obj.PutStr('name', Project);
    Obj.PutStr('created', NowIsoUtc);
  end;
  try
    if Trim(ATitle) <> '' then Obj.PutStr('title', Trim(ATitle));
    { Description and icon are settable to empty on purpose -- clearing a
      description is a legitimate edit, so only nil-equivalent (unchanged)
      callers pass the sentinel '-'. }
    if ADescription <> '-' then Obj.PutStr('description', ADescription);
    if AIcon <> '-' then Obj.PutStr('icon', AIcon);
    Obj.PutStr('updated', NowIsoUtc);
    WriteManifest(Path, Obj);
  finally
    Obj.Free;
  end;
  PublishProjects;
  Result := True;
end;

function SetProjectArchived(const Project: string; Archived: Boolean;
  out Err: string): Boolean;
var
  Dir, Path: string;
  Obj: TJsonObject;
begin
  Err := '';
  Result := False;
  Dir := ProjectDir(Project);
  if (Dir = '') or not DirectoryExists(Dir) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;
  Path := JoinPath(Dir, 'project.json');
  Obj := ReadManifest(Path);
  if Obj = nil then
  begin
    Obj := TJsonObject.Create;
    Obj.PutStr('name', Project);
    Obj.PutStr('created', NowIsoUtc);
  end;
  try
    Obj.PutBool('archived', Archived);
    { `updated` deliberately NOT touched. Filing something away is not
      work on it, and bumping the timestamp would push a finished
      project to the top of anything sorted by recency -- the exact
      opposite of what was asked for. }
    WriteManifest(Path, Obj);
  finally
    Obj.Free;
  end;
  PublishProjects;
  Result := True;
end;

function SetProjectReview(const Project: string; Review: Boolean;
  const Reviewers: TStringArray; out Err: string): Boolean;
var
  Dir, Path, S: string;
  Obj: TJsonObject;
  Arr: TJsonArray;
  I: Integer;
begin
  Err := '';
  Result := False;
  Dir := ProjectDir(Project);
  if (Dir = '') or not DirectoryExists(Dir) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;
  Path := JoinPath(Dir, 'project.json');
  Obj := ReadManifest(Path);
  if Obj = nil then
  begin
    Obj := TJsonObject.Create;
    Obj.PutStr('name', Project);
    Obj.PutStr('created', NowIsoUtc);
  end;
  try
    Obj.PutBool('review', Review);
    Arr := TJsonArray.Create;
    for I := 0 to High(Reviewers) do
    begin
      S := SanitizeName(Reviewers[I]);
      if S <> '' then Arr.AddStr(S);
    end;
    Obj.PutArray('reviewers', Arr);
    WriteManifest(Path, Obj);
  finally
    Obj.Free;
  end;
  PublishProjects;
  Result := True;
end;

function ProjectRequiresReview(const Project: string): Boolean;
var
  Dir: string;
  Obj: TJsonObject;
begin
  Result := False;
  Dir := ProjectDir(Project);
  if Dir = '' then Exit;
  Obj := ReadManifest(JoinPath(Dir, 'project.json'));
  if Obj = nil then Exit;
  try
    Result := Obj.GetBool('review', False);
  finally
    Obj.Free;
  end;
end;

function ProjectReviewers(const Project: string): TStringArray;
var
  Dir: string;
  Obj: TJsonObject;
begin
  SetLength(Result, 0);
  Dir := ProjectDir(Project);
  if Dir = '' then Exit;
  Obj := ReadManifest(JoinPath(Dir, 'project.json'));
  if Obj = nil then Exit;
  try
    Result := ManifestNames(Obj, 'reviewers');
  finally
    Obj.Free;
  end;
end;

function ParseLanes(Obj: TJsonObject): TLaneArray;
var
  L: TJsonObject;
  Keys: TStringList;
  Arr: TJsonArray;
  I, J, N: Integer;
begin
  SetLength(Result, 0);
  if Obj = nil then Exit;
  L := Obj.ChildObject('lanes');
  if L = nil then Exit;
  try
    Keys := L.Keys;
    try
      for I := 0 to Keys.Count - 1 do
      begin
        Arr := L.ChildArray(Keys[I]);
        if Arr = nil then Continue;
        try
          N := Length(Result);
          SetLength(Result, N + 1);
          Result[N].Agent := SanitizeName(Keys[I]);
          SetLength(Result[N].Globs, Arr.Count);
          for J := 0 to Arr.Count - 1 do
            Result[N].Globs[J] := Trim(Arr.ItemStr(J));
        finally
          Arr.Free;
        end;
      end;
    finally
      Keys.Free;
    end;
  finally
    L.Free;
  end;
end;

function SetProjectLanes(const Project: string; const Lanes: TLaneArray;
  out Err: string): Boolean;
var
  Dir, Path: string;
  Obj, L: TJsonObject;
  Arr: TJsonArray;
  I, J: Integer;
begin
  Err := '';
  Result := False;
  Dir := ProjectDir(Project);
  if (Dir = '') or not DirectoryExists(Dir) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;
  Path := JoinPath(Dir, 'project.json');
  Obj := ReadManifest(Path);
  if Obj = nil then
  begin
    Obj := TJsonObject.Create;
    Obj.PutStr('name', Project);
    Obj.PutStr('created', NowIsoUtc);
  end;
  try
    L := TJsonObject.Create;
    for I := 0 to High(Lanes) do
    begin
      if SanitizeName(Lanes[I].Agent) = '' then Continue;
      Arr := TJsonArray.Create;
      for J := 0 to High(Lanes[I].Globs) do
        if Trim(Lanes[I].Globs[J]) <> '' then Arr.AddStr(Trim(Lanes[I].Globs[J]));
      L.PutArray(SanitizeName(Lanes[I].Agent), Arr);
    end;
    Obj.PutObject('lanes', L);
    WriteManifest(Path, Obj);
  finally
    Obj.Free;
  end;
  Result := True;
end;

function ProjectLanes(const Project: string): TLaneArray;
var
  Dir: string;
  Obj: TJsonObject;
begin
  SetLength(Result, 0);
  Dir := ProjectDir(Project);
  if Dir = '' then Exit;
  Obj := ReadManifest(JoinPath(Dir, 'project.json'));
  if Obj = nil then Exit;
  try
    Result := ParseLanes(Obj);
  finally
    Obj.Free;
  end;
end;

function AllLanes: TLaneArray;
var
  Names: TStringList;
  One: TLaneArray;
  I, J, N: Integer;
begin
  SetLength(Result, 0);
  Names := SubdirNames(ProjectsRoot);
  try
    for I := 0 to Names.Count - 1 do
    begin
      if not IsSafeName(Names[I]) then Continue;
      One := ProjectLanes(Names[I]);
      for J := 0 to High(One) do
      begin
        N := Length(Result);
        SetLength(Result, N + 1);
        Result[N] := One[J];
      end;
    end;
  finally
    Names.Free;
  end;
end;

function SetProjectTakers(const Project: string; const Takers: TStringArray;
  out Err: string): Boolean;
var
  Dir, Path, S: string;
  Obj: TJsonObject;
  Arr: TJsonArray;
  I: Integer;
begin
  Err := '';
  Result := False;
  Dir := ProjectDir(Project);
  if (Dir = '') or not DirectoryExists(Dir) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;
  Path := JoinPath(Dir, 'project.json');
  Obj := ReadManifest(Path);
  if Obj = nil then
  begin
    Obj := TJsonObject.Create;
    Obj.PutStr('name', Project);
    Obj.PutStr('created', NowIsoUtc);
  end;
  try
    Arr := TJsonArray.Create;
    for I := 0 to High(Takers) do
    begin
      S := SanitizeName(Takers[I]);
      if S <> '' then Arr.AddStr(S);
    end;
    Obj.PutArray('takers', Arr);
    WriteManifest(Path, Obj);
  finally
    Obj.Free;
  end;
  Result := True;
end;

function ProjectTakers(const Project: string): TStringArray;
var
  Dir: string;
  Obj: TJsonObject;
begin
  SetLength(Result, 0);
  Dir := ProjectDir(Project);
  if Dir = '' then Exit;
  Obj := ReadManifest(JoinPath(Dir, 'project.json'));
  if Obj = nil then Exit;
  try
    Result := ManifestNames(Obj, 'takers');
  finally
    Obj.Free;
  end;
end;

function ProjectScenariosDir(const Project: string): string;
begin
  Result := '';
  if not IsSafeName(Project) then Exit;
  Result := JoinPath(JoinPath(JoinPath(GetHome, 'scenarios'),
                              ActiveWorkspaceName), Project);
end;

function RemoveTree(const Dir: string): Boolean;
var
  Rec: TSearchRec;
  Full: string;
begin
  Result := True;
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, Rec) = 0 then
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then Continue;
        Full := JoinPath(Dir, Rec.Name);
        if (Rec.Attr and faDirectory) <> 0 then
          Result := RemoveTree(Full) and Result
        else
          Result := DeleteFile(Full) and Result;
      until FindNext(Rec) <> 0;
    finally
      FindClose(Rec);
    end;
  Result := RemoveDir(Dir) and Result;
end;

function DeleteProject(const Project: string; out Err: string): Boolean;
var
  Dir: string;
begin
  Err := '';
  Dir := ProjectDir(Project);
  if Dir = '' then
  begin
    Err := 'not a project name: ' + Project;
    Exit(False);
  end;
  if not DirectoryExists(Dir) then
  begin
    Err := 'no such project: ' + Project;
    Exit(False);
  end;
  Result := RemoveTree(Dir);
  if not Result then
    Err := 'could not remove ' + Dir
  else
  begin
    { Its snapshots go with it: they are copies of a board that is gone. }
    RemoveSnapshots(Project);
    PublishProjects;
  end;
end;

{ ------------------------------------------------------------------ tasks -- }

function TaskStatusToStr(S: TTaskStatus): string;
begin
  case S of
    tsActive:  Result := 'active';
    tsDone:    Result := 'done';
    tsBlocked: Result := 'blocked';
    tsReview:  Result := 'review';
    else       Result := 'todo';
  end;
end;

function StrToTaskStatus(const S: string; Default: TTaskStatus): TTaskStatus;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  if      L = 'todo'    then Result := tsTodo
  else if L = 'active'  then Result := tsActive
  else if L = 'done'    then Result := tsDone
  else if L = 'blocked' then Result := tsBlocked
  else if L = 'review'  then Result := tsReview
  else Result := Default;
end;

function ActorLabel(const Actor: string): string;
begin
  if Actor = ActorOperator then Result := 'operator' else Result := Actor;
end;

{ An agent slug -- someone the review rules can name and hold to. }
function IsAgentActor(const Actor: string): Boolean;
begin
  Result := (Actor <> ActorOperator) and (Actor <> ActorModel);
end;

{ --------------------------------------------------------------- activity -- }

function ActivityPath(const Project: string): string;
var
  Dir: string;
begin
  Result := '';
  Dir := ProjectDir(Project);
  if Dir = '' then Exit;
  Result := JoinPath(Dir, 'activity.jsonl');
end;

(* One receipt. Pairs is key, value, key, value...; an empty value is left
   out rather than written as "", so a line says only what happened. Best
   effort by design: a full disk must not turn a recorded status change
   into a failed one -- the manifest is the state, this is the trail. *)
procedure AppendActivity(const Project, TaskId, Event, Actor: string;
  const Pairs: array of string);
var
  Path, Line: string;
  Obj: TJsonObject;
  I: Integer;
  F: TextFile;
begin
  Path := ActivityPath(Project);
  if (Path = '') or not DirectoryExists(ExtractFileDir(Path)) then Exit;
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('at', NowIsoUtc);
    Obj.PutStr('task', UpperCase(TaskId));
    Obj.PutStr('event', Event);
    Obj.PutStr('by', ActorLabel(Actor));
    I := 0;
    while I + 1 <= High(Pairs) do
    begin
      if Pairs[I + 1] <> '' then Obj.PutStr(Pairs[I], Pairs[I + 1]);
      Inc(I, 2);
    end;
    Line := Obj.ToJSON;
  finally
    Obj.Free;
  end;
  { One object per line: ToJSON escapes newlines inside strings, so a
    multi-line reason cannot split a receipt in two. }
  GActivityLock.Enter;
  try
    try
      AssignFile(F, Path);
      if FileExists(Path) then Append(F) else Rewrite(F);
      try
        WriteLn(F, Line);
      finally
        CloseFile(F);
      end;
    except
      { see above: the trail is never worth failing the change it records }
    end;
  finally
    GActivityLock.Leave;
  end;
end;

procedure RecordActivity(const Project, TaskId, Event, Actor: string;
  const Pairs: array of string);
begin
  AppendActivity(Project, TaskId, Event, Actor, Pairs);
end;

function ReadActivity(const Project, TaskId: string;
  Limit: Integer): TStringArray;
var
  Path, Want: string;
  Lines: TStringList;
  Obj: TJsonObject;
  I, N, First: Integer;
  Keep: Boolean;
begin
  SetLength(Result, 0);
  Path := ActivityPath(Project);
  if (Path = '') or not FileExists(Path) then Exit;
  Want := UpperCase(Trim(TaskId));
  Lines := TStringList.Create;
  try
    GActivityLock.Enter;
    try
      Lines.Text := ReadFileText(Path);
    finally
      GActivityLock.Leave;
    end;
    SetLength(Result, Lines.Count);
    N := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      if Trim(Lines[I]) = '' then Continue;
      { A line that does not parse is dropped, not passed on: callers
        splice these into a JSON array verbatim. }
      Obj := nil;
      try
        Obj := TJsonObject.Parse(Lines[I]);
      except
        Obj := nil;
      end;
      if Obj = nil then Continue;
      try
        Keep := (Want = '') or (UpperCase(Obj.GetStr('task', '')) = Want);
      finally
        Obj.Free;
      end;
      if not Keep then Continue;
      Result[N] := Trim(Lines[I]);
      Inc(N);
    end;
    SetLength(Result, N);
  finally
    Lines.Free;
  end;
  if (Limit > 0) and (Length(Result) > Limit) then
  begin
    First := Length(Result) - Limit;
    for I := 0 to Limit - 1 do
      Result[I] := Result[First + I];
    SetLength(Result, Limit);
  end;
end;

function LoadTask(const Project, TaskId: string; out Info: TTaskInfo): Boolean;
var
  Dir: string;
  Obj: TJsonObject;
  Jobs: TStringList;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Id := ''; Info.Project := ''; Info.Title := '';
  Info.Notes := ''; Info.Created := ''; Info.Updated := '';
  Dir := TaskDir(Project, TaskId);
  if (Dir = '') or not DirectoryExists(Dir) then Exit;

  Info.Id      := UpperCase(TaskId);
  Info.Project := Project;
  Info.Title   := Info.Id;
  Info.Status  := tsTodo;
  Obj := ReadManifest(JoinPath(Dir, 'task.json'));
  if Obj <> nil then
    try
      Info.Title   := Obj.GetStr('title', Info.Id);
      Info.Status  := StrToTaskStatus(Obj.GetStr('status', 'todo'));
      Info.Notes   := Obj.GetStr('notes', '');
      Info.Assignee := Trim(Obj.GetStr('assignee', ''));
      Info.Criteria := Obj.GetStr('criteria', '');
      Info.Started  := Obj.GetStr('started', '');
      Info.SubmittedBy  := Obj.GetStr('submitted_by', '');
      Info.SubmittedAt  := Obj.GetStr('submitted_at', '');
      Info.Evidence     := Obj.GetStr('evidence', '');
      Info.SubmittedJob := Obj.GetStr('submitted_job', '');
      Info.Verdict      := Obj.GetStr('verdict', '');
      Info.VerdictBy    := Obj.GetStr('verdict_by', '');
      Info.VerdictAt    := Obj.GetStr('verdict_at', '');
      Info.VerdictNote  := Obj.GetStr('verdict_note', '');
      Info.VerdictCause := Obj.GetStr('verdict_cause', '');
      Info.SubmittedSnapshot := Obj.GetStr('submitted_snapshot', '');
      Info.WaitsOn      := ManifestNames(Obj, 'waits_on', True);
      Info.LeaseBy      := Obj.GetStr('lease_by', '');
      Info.LeaseUntil   := Obj.GetStr('lease_until', '');
      Info.ClaimedFrom  := Obj.GetStr('claimed_from', '');
      Info.Created := Obj.GetStr('created', '');
      Info.Updated := Obj.GetStr('updated', '');
    finally
      Obj.Free;
    end;
  Jobs := SubdirNames(JoinPath(Dir, 'jobs'));
  try
    Info.JobCount := Jobs.Count;
  finally
    Jobs.Free;
  end;
  Result := True;
end;

function GetTask(const Project, TaskId: string; out Info: TTaskInfo): Boolean;
begin
  Result := LoadTask(Project, TaskId, Info);
end;

function ListTasks(const Project: string): TTaskInfoArray;
var
  Dir: string;
  Names: TStringList;
  I, N: Integer;
  Info: TTaskInfo;
begin
  SetLength(Result, 0);
  Dir := ProjectDir(Project);
  if Dir = '' then Exit;
  Names := SubdirNames(JoinPath(Dir, 'tasks'));
  try
    SetLength(Result, Names.Count);
    N := 0;
    for I := 0 to Names.Count - 1 do
      if LoadTask(Project, Names[I], Info) then
      begin
        Result[N] := Info;
        Inc(N);
      end;
    SetLength(Result, N);
  finally
    Names.Free;
  end;
end;

function CreateTask(const Project, ATitle, ANotes: string; out Err: string;
  const ACriteria: string; const Actor: string): string;
var
  PDir, Id, Dir, Now_: string;
  Obj: TJsonObject;
begin
  Err := '';
  Result := '';
  PDir := ProjectDir(Project);
  if (PDir = '') or not DirectoryExists(PDir) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;
  if Trim(ATitle) = '' then
  begin
    Err := 'a task needs a title';
    Exit;
  end;

  EnsureDir(JoinPath(PDir, 'tasks'));
  Id  := ReserveId(JoinPath(PDir, 'tasks'), 'T');
  Dir := JoinPath(JoinPath(PDir, 'tasks'), Id);
  EnsureDir(JoinPath(Dir, 'jobs'));

  Now_ := NowIsoUtc;
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('id', Id);
    Obj.PutStr('title', Trim(ATitle));
    Obj.PutStr('status', 'todo');
    Obj.PutStr('notes', ANotes);
    if ACriteria <> '' then Obj.PutStr('criteria', ACriteria);
    Obj.PutStr('created', Now_);
    Obj.PutStr('updated', Now_);
    WriteManifest(JoinPath(Dir, 'task.json'), Obj);
  finally
    Obj.Free;
  end;
  AppendActivity(Project, Id, 'create', Actor, ['title', Trim(ATitle)]);
  PublishTask(Project, Id, 'todo');
  Result := Id;
end;

{ The call a refusal should have been -- refusals in this unit end with
  the next step, because the model's next move is a retry. }
function SubmitHint(const Project, TaskId: string): string;
begin
  Result := 'task action="submit" project="' + Project + '" id="' +
            UpperCase(TaskId) + '" evidence="what you ran and what it printed"';
end;

function UpdateTask(const Project, TaskId, ATitle, ANotes: string;
  const AStatus: string; out Err: string;
  const AAssignee: string; const ACriteria: string;
  const Actor: string): Boolean;
var
  Dir, Path, Id, St, OldSt, OldAssignee, NewAssignee, Ev: string;
  Obj: TJsonObject;
  StatusChange, AssigneeChange, CriteriaChange, Frozen: Boolean;
begin
  Err := '';
  Result := False;
  Id := UpperCase(TaskId);
  Dir := TaskDir(Project, TaskId);
  if (Dir = '') or not DirectoryExists(Dir) then
  begin
    Err := 'no such task: ' + Project + '/' + TaskId;
    Exit;
  end;
  St := LowerCase(Trim(AStatus));
  if St = '-' then St := '';
  if St = 'review' then
  begin
    Err := Id + ': "review" is not a status you set. A task enters review ' +
           'by being submitted, which records the evidence a reviewer ' +
           'checks: ' + SubmitHint(Project, Id);
    Exit;
  end;
  if (St <> '') and (St <> 'todo') and (St <> 'active') and
     (St <> 'done') and (St <> 'blocked') then
  begin
    Err := 'status must be todo, active, done or blocked (got "' + AStatus + '")';
    Exit;
  end;

  Path := JoinPath(Dir, 'task.json');
  GTaskLock.Enter;
  try
    Obj := ReadManifest(Path);
    if Obj = nil then
    begin
      Obj := TJsonObject.Create;
      Obj.PutStr('id', Id);
      Obj.PutStr('created', NowIsoUtc);
    end;
    try
      OldSt       := LowerCase(Trim(Obj.GetStr('status', 'todo')));
      OldAssignee := Trim(Obj.GetStr('assignee', ''));
      (* Canonicalised with the project slug rule, which is the same rule
         agent names use. Storing "Dev Name" or "@dev" as typed left a task
         that LOOKED assigned on the board while the wake loop -- which
         compares against agent slugs -- never matched it, so the owner was
         never woken and the task simply sat there. *)
      NewAssignee := OldAssignee;
      if AAssignee <> '-' then NewAssignee := SanitizeName(AAssignee);
      StatusChange   := (St <> '') and (St <> OldSt);
      AssigneeChange := NewAssignee <> OldAssignee;
      CriteriaChange := (ACriteria <> '-') and
                        (ACriteria <> Obj.GetStr('criteria', ''));

      (* The review rules. They bind everyone but the operator -- an agent,
         or a model turn we cannot attribute -- and they are checked here,
         in the store, so no route to the board skips them. *)
      if Actor <> ActorOperator then
      begin
        if StatusChange and (OldSt = 'review') then
        begin
          Err := Id + ' is waiting for a verdict. Only a verdict moves it ' +
                 'out of review (task action="verdict"), and never from ' +
                 'whoever submitted it.';
          Exit;
        end;
        if StatusChange and (St = 'done') and ProjectRequiresReview(Project) then
        begin
          Err := Id + ' is on a board that requires review: an agent does ' +
                 'not mark work done, another agent gives the verdict. ' +
                 'Submit it instead: ' + SubmitHint(Project, Id);
          Exit;
        end;
        if CriteriaChange then
        begin
          (* "Started", not "active": a task blocked after work began has
             still begun, and a builder could otherwise block, edit and
             unblock its way past the freeze. The status test covers
             tasks written before `started` existed. *)
          Frozen := (Obj.GetStr('started', '') <> '') or (OldSt = 'active') or
                    (OldSt = 'review') or (OldSt = 'done');
          if Frozen then
          begin
            Err := Id + ' has started, so its criteria are frozen: the bar ' +
                   'does not move while someone is working to it. Reopen ' +
                   'it (status todo) to change them.';
            Exit;
          end;
          if IsAgentActor(Actor) and
             ((Actor = OldAssignee) or (Actor = NewAssignee)) then
          begin
            Err := Id + ' is ' + Actor + '''s to build, and a builder does ' +
                   'not write its own acceptance criteria. Ask whoever owns ' +
                   'the requirements, or the operator, to set them.';
            Exit;
          end;
        end;
      end;

      { Two "leave this alone" spellings, because two callers grew them
        independently: '' (nothing supplied) and '-' (the route layer's
        explicit sentinel, since an absent JSON key must not clear text the
        user wrote). Accept both for every field. Titling a task '-' is not a
        thing anyone wants; silently wiping a title because a caller used the
        other unit's sentinel is a thing that already happened once. }
      if (Trim(ATitle) <> '') and (Trim(ATitle) <> '-') then
        Obj.PutStr('title', Trim(ATitle));
      if St <> '' then
      begin
        Obj.PutStr('status', St);
        if (St = 'active') and (Obj.GetStr('started', '') = '') then
          Obj.PutStr('started', NowIsoUtc);
        { A reopen hands the work out again, which is the one moment the
          bar may move. }
        if St = 'todo' then Obj.PutStr('started', '');
      end;
      if ANotes <> '-' then Obj.PutStr('notes', ANotes);
      if AAssignee <> '-' then Obj.PutStr('assignee', NewAssignee);
      if ACriteria <> '-' then Obj.PutStr('criteria', ACriteria);
      (* The lease. An AGENT starting work takes one (for the owner, or for
         itself when the task has none); the owner touching an active task
         renews it; leaving active drops it. The operator and the job
         runner never take one -- a lease answers "is the agent that
         claimed this still alive", and they are not agents. *)
      if (St <> '') and (St <> 'active') then
      begin
        Obj.PutStr('lease_by', '');
        Obj.PutStr('lease_until', '');
        Obj.PutStr('claimed_from', '');
      end
      else if IsAgentActor(Actor) and
              ((St = 'active') or (OldSt = 'active')) and
              (StatusChange or (Actor = NewAssignee)) then
      begin
        if NewAssignee <> '' then Obj.PutStr('lease_by', NewAssignee)
                             else Obj.PutStr('lease_by', Actor);
        Obj.PutStr('lease_until', IsoUtcInMinutes(GLeaseMinutes));
      end;
      Obj.PutStr('updated', NowIsoUtc);
      WriteManifest(Path, Obj);
    finally
      Obj.Free;
    end;
  finally
    GTaskLock.Leave;
  end;

  if AssigneeChange then
    AppendActivity(Project, Id, 'assign', Actor,
                   ['from', OldAssignee, 'to', NewAssignee]);
  if StatusChange then
  begin
    if (St = 'active') and ((OldSt = 'todo') or (OldSt = 'blocked')) then
      Ev := 'start'
    else if St = 'todo' then
      Ev := 'reopen'
    else
      Ev := 'status';
    AppendActivity(Project, Id, Ev, Actor, ['from', OldSt, 'to', St]);
  end;
  if CriteriaChange then
    AppendActivity(Project, Id, 'criteria', Actor, ['criteria', ACriteria]);
  PublishTask(Project, Id, St);
  if StatusChange and (St = 'done') and Assigned(OnTaskClosed) then
    OnTaskClosed(Project, Id);
  if AssigneeChange and (NewAssignee <> '') and (NewAssignee <> Actor) and
     Assigned(OnTaskAssigned) then
    OnTaskAssigned(Project, Id, NewAssignee, Actor);
  Result := True;
end;

{ ', '-joined, for refusals that name people. }
function JoinNames(const Names: TStringArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Names) do
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + Names[I];
  end;
end;

function InNames(const Name: string; const Names: TStringArray): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(Names) do
    if Names[I] = Name then Exit(True);
end;

function SubmitTask(const Project, TaskId, Actor, Evidence, JobId: string;
  out Err: string): Boolean;
var
  Path, Id, St, By, Report, Owner, Snap, SnapErr: string;
  Obj: TJsonObject;
  T: TTaskInfo;

  { Which states a submission may leave from. Checked twice -- before the
    gate, so a doomed submit does not run scenarios, and again under the
    lock, because the gate takes time and the task may have moved. }
  function Submittable(const S: string): Boolean;
  begin
    Result := False;
    if S = 'review' then
      Err := Id + ' is already waiting for a verdict.'
    else if S = 'done' then
      Err := Id + ' is already done. Reopen it (status todo) if there is ' +
             'more to do.'
    else if S = 'blocked' then
      Err := Id + ' is blocked. Unblock it (status active) before ' +
             'submitting it.'
    else
      Result := True;
  end;

begin
  Err := '';
  Result := False;
  Id := UpperCase(TaskId);
  if not GetTask(Project, TaskId, T) then
  begin
    Err := 'no such task: ' + Project + '/' + TaskId;
    Exit;
  end;
  if Trim(Evidence) = '' then
  begin
    Err := 'submitting ' + Id + ' needs "evidence": what you ran and what ' +
           'it printed. A submission is a claim, and the reviewer checks ' +
           'it against the criteria.';
    Exit;
  end;
  if not Submittable(TaskStatusToStr(T.Status)) then Exit;

  if Assigned(OnSubmitGate) and not OnSubmitGate(Project, Id, Report) then
  begin
    Err := Id + ' was not submitted: the operator''s held-out checks for ' +
           'this project fail, so it would not reach a reviewer. Fix the ' +
           'cause (not the check), then submit again.'#10 + Report;
    AppendActivity(Project, Id, 'submit-refused', Actor,
                   ['reason', Copy(Report, 1, 500)]);
    Exit;
  end;

  (* The project as submitted, kept outside the workspace: what a reviewer
     judged, and what a rule for a repeated cause is proven against
     (PasClaw.Projects.Snapshots). A project too big to copy still
     submits -- the snapshot is evidence, not a gate. *)
  if not TakeSnapshot(Project, Id, Snap, SnapErr) then Snap := '';

  (* Whose work this is. The caller when it is a named agent; otherwise
     the task's owner -- a job finishing, or an unattributed model turn,
     is still the owner's work, and recording it as anyone else's would
     let the owner give the verdict on it. *)
  if IsAgentActor(Actor) then By := Actor
  else if T.Assignee <> '' then By := T.Assignee
  else By := ActorLabel(Actor);

  Path := JoinPath(TaskDir(Project, TaskId), 'task.json');
  GTaskLock.Enter;
  try
    Obj := ReadManifest(Path);
    if Obj = nil then
    begin
      Err := 'no such task: ' + Project + '/' + TaskId;
      Exit;
    end;
    try
      St := LowerCase(Trim(Obj.GetStr('status', 'todo')));
      if not Submittable(St) then Exit;
      Owner := Trim(Obj.GetStr('assignee', ''));
      Obj.PutStr('status', 'review');
      if Obj.GetStr('started', '') = '' then Obj.PutStr('started', NowIsoUtc);
      Obj.PutStr('submitted_by', By);
      Obj.PutStr('submitted_at', NowIsoUtc);
      Obj.PutStr('evidence', Evidence);
      Obj.PutStr('submitted_job', UpperCase(Trim(JobId)));
      Obj.PutStr('submitted_snapshot', Snap);
      Obj.PutStr('verdict', '');
      Obj.PutStr('verdict_by', '');
      Obj.PutStr('verdict_at', '');
      Obj.PutStr('verdict_note', '');
      { Out of active, so out of the lease: a task waiting on a reviewer
        is not a claim a dead run could be holding. }
      Obj.PutStr('lease_by', '');
      Obj.PutStr('lease_until', '');
      Obj.PutStr('updated', NowIsoUtc);
      WriteManifest(Path, Obj);
    finally
      Obj.Free;
    end;
  finally
    GTaskLock.Leave;
  end;
  AppendActivity(Project, Id, 'submit', Actor,
                 ['submitted_by', By, 'owner', Owner,
                  'job', UpperCase(Trim(JobId)),
                  'snapshot', Snap, 'snapshot_error', SnapErr,
                  'evidence', Copy(Evidence, 1, 500)]);
  PublishTask(Project, Id, 'review');
  Result := True;
end;

function VerdictTask(const Project, TaskId, Actor: string; Accept: Boolean;
  const Note: string; const Reviewers: TStringArray;
  out Err: string; const Cause: string): Boolean;
var
  Path, Id, St, Who, Notes, Stamp, CauseKey: string;
  Obj: TJsonObject;
  T: TTaskInfo;
begin
  Err := '';
  Result := False;
  Id := UpperCase(TaskId);
  if not GetTask(Project, TaskId, T) then
  begin
    Err := 'no such task: ' + Project + '/' + TaskId;
    Exit;
  end;
  CauseKey := SanitizeName(Cause);
  if T.Status <> tsReview then
  begin
    Err := Id + ' is not waiting for a verdict (it is ' +
           TaskStatusToStr(T.Status) + '). A task reaches review when its ' +
           'builder submits it.';
    Exit;
  end;
  if (not Accept) and (Trim(Note) = '') then
  begin
    Err := 'rejecting ' + Id + ' needs a "reason" its builder can act on: ' +
           'what you ran, what happened, and what should have happened.';
    Exit;
  end;

  if Length(Reviewers) > 0 then
    Who := ' -- ' + JoinNames(Reviewers) + ' review(s) this work, or the ' +
           'operator can.'
  else
    Who := ' -- any other agent on the team can, or the operator.';
  if Actor <> ActorOperator then
  begin
    if not IsAgentActor(Actor) then
    begin
      Err := 'a verdict on ' + Id + ' has to come from a named agent or the ' +
             'operator, and this call is neither: it is not running as a ' +
             'standing agent''s turn, so who is giving the verdict cannot be ' +
             'checked' + Who;
      Exit;
    end;
    if (Actor = T.SubmittedBy) or (Actor = T.Assignee) then
    begin
      Err := Id + ' was submitted by ' + ActorLabel(T.SubmittedBy) +
             '; another agent must give the verdict' + Who;
      Exit;
    end;
    if (Length(Reviewers) > 0) and not InNames(Actor, Reviewers) then
    begin
      Err := Actor + ' does not review ' + Id + Who;
      Exit;
    end;
  end;

  Path := JoinPath(TaskDir(Project, TaskId), 'task.json');
  Stamp := NowIsoUtc;
  GTaskLock.Enter;
  try
    Obj := ReadManifest(Path);
    if Obj = nil then
    begin
      Err := 'no such task: ' + Project + '/' + TaskId;
      Exit;
    end;
    try
      { Re-checked under the lock: two reviewers answering together must
        not both land, and the second must hear why. }
      St := LowerCase(Trim(Obj.GetStr('status', '')));
      if St <> 'review' then
      begin
        Err := Id + ' is no longer waiting for a verdict (it is ' + St +
               ' -- another verdict landed first).';
        Exit;
      end;
      if Accept then
      begin
        Obj.PutStr('status', 'done');
        Obj.PutStr('verdict', 'accept');
        Obj.PutStr('claimed_from', '');
      end
      else
      begin
        { Same owner, back to work, and the reason where the builder
          reads first: the notes. Active again, so leased again -- to
          the owner, who is the one expected to pick it up. }
        Obj.PutStr('status', 'active');
        Obj.PutStr('verdict', 'reject');
        if Trim(Obj.GetStr('assignee', '')) <> '' then
        begin
          Obj.PutStr('lease_by', Trim(Obj.GetStr('assignee', '')));
          Obj.PutStr('lease_until', IsoUtcInMinutes(GLeaseMinutes));
        end;
        Notes := TrimRight(Obj.GetStr('notes', ''));
        if Notes <> '' then Notes := Notes + #10;
        Obj.PutStr('notes', Notes + '[rejected by ' + ActorLabel(Actor) +
                   ', ' + Stamp + '] ' + Trim(Note));
      end;
      Obj.PutStr('verdict_by', ActorLabel(Actor));
      Obj.PutStr('verdict_at', Stamp);
      Obj.PutStr('verdict_note', Trim(Note));
      Obj.PutStr('verdict_cause', CauseKey);
      Obj.PutStr('updated', Stamp);
      WriteManifest(Path, Obj);
    finally
      Obj.Free;
    end;
  finally
    GTaskLock.Leave;
  end;
  (* The snapshot rides on the verdict's receipt: a rule for a repeated
     cause is proven against the submission a reject was given on and the
     one accepted after it, and this line is how they are found. *)
  if Accept then
    AppendActivity(Project, Id, 'accept', Actor,
                   ['submitted_by', T.SubmittedBy, 'job', T.SubmittedJob,
                    'snapshot', T.SubmittedSnapshot, 'note', Trim(Note)])
  else
    AppendActivity(Project, Id, 'reject', Actor,
                   ['submitted_by', T.SubmittedBy, 'job', T.SubmittedJob,
                    'snapshot', T.SubmittedSnapshot, 'cause', CauseKey,
                    'reason', Trim(Note)]);
  if Accept then PublishTask(Project, Id, 'done')
            else PublishTask(Project, Id, 'active');
  if Accept and Assigned(OnTaskClosed) then OnTaskClosed(Project, Id);
  if (not Accept) and (CauseKey <> '') and Assigned(OnTaskRejected) then
    OnTaskRejected(Project, Id, CauseKey);
  Result := True;
end;

function ProjectCauses(const Project, Key: string): TStringArray;
var
  Dir: string;
  Obj: TJsonObject;
begin
  SetLength(Result, 0);
  Dir := ProjectDir(Project);
  if Dir = '' then Exit;
  Obj := ReadManifest(JoinPath(Dir, 'project.json'));
  if Obj = nil then Exit;
  try
    Result := ManifestNames(Obj, Key);
  finally
    Obj.Free;
  end;
end;

function AddProjectCause(const Project, Key, Cause: string; out Err: string): Boolean;
var
  Dir, Path, C: string;
  Obj: TJsonObject;
  Have: TStringArray;
  Arr: TJsonArray;
  I: Integer;
begin
  Err := '';
  Result := False;
  C := SanitizeName(Cause);
  Dir := ProjectDir(Project);
  if (Dir = '') or not DirectoryExists(Dir) or (C = '') then
  begin
    Err := 'no such project, or no cause: ' + Project + ' / ' + Cause;
    Exit;
  end;
  Path := JoinPath(Dir, 'project.json');
  GTaskLock.Enter;
  try
    Obj := ReadManifest(Path);
    if Obj = nil then
    begin
      Obj := TJsonObject.Create;
      Obj.PutStr('name', Project);
    end;
    try
      Have := ManifestNames(Obj, Key);
      Arr := TJsonArray.Create;
      for I := 0 to High(Have) do
        if Have[I] <> C then Arr.AddStr(Have[I]);
      Arr.AddStr(C);
      Obj.PutArray(Key, Arr);
      WriteManifest(Path, Obj);
    finally
      Obj.Free;
    end;
  finally
    GTaskLock.Leave;
  end;
  Result := True;
end;

{ ------------------------------------------------------- waits_on, next -- }

function FindOnBoard(const Board: TTaskInfoArray; const Id: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(Board) do
    if Board[I].Id = UpperCase(Id) then Exit(I);
end;

function TaskWaitingOn(const T: TTaskInfo; const Board: TTaskInfoArray): TStringArray;
var
  I, K, N: Integer;
begin
  SetLength(Result, Length(T.WaitsOn));
  N := 0;
  for I := 0 to High(T.WaitsOn) do
  begin
    K := FindOnBoard(Board, T.WaitsOn[I]);
    if (K < 0) or (Board[K].Status <> tsDone) then
    begin
      Result[N] := T.WaitsOn[I];
      Inc(N);
    end;
  end;
  SetLength(Result, N);
end;

function TaskReady(const T: TTaskInfo; const Board: TTaskInfoArray): Boolean;
begin
  Result := Length(TaskWaitingOn(T, Board)) = 0;
end;

function SetTaskWaitsOn(const Project, TaskId: string;
  const WaitsOn: TStringArray; const Actor: string; out Err: string): Boolean;
var
  Board: TTaskInfoArray;
  Ids: TStringArray;
  Id, Path, Joined: string;
  Obj: TJsonObject;
  Arr: TJsonArray;
  I, K: Integer;

  (* Is From reachable from Start by following waits_on, given the new
     edges for Id? A depth-first walk with a visited set -- the board is
     tens of tasks, not thousands. *)
  function Reaches(const Start, Target: string): Boolean;
  var
    Stack, Seen: TStringList;
    Cur: string;
    J, P: Integer;
    Next: TStringArray;
  begin
    Result := False;
    Stack := TStringList.Create;
    Seen := TStringList.Create;
    try
      Stack.Add(Start);
      while Stack.Count > 0 do
      begin
        Cur := Stack[Stack.Count - 1];
        Stack.Delete(Stack.Count - 1);
        if Cur = Target then Exit(True);
        if Seen.IndexOf(Cur) >= 0 then Continue;
        Seen.Add(Cur);
        if Cur = Id then Next := Ids
        else
        begin
          P := FindOnBoard(Board, Cur);
          if P < 0 then Continue;
          Next := Board[P].WaitsOn;
        end;
        for J := 0 to High(Next) do Stack.Add(Next[J]);
      end;
    finally
      Seen.Free;
      Stack.Free;
    end;
  end;

begin
  Err := '';
  Result := False;
  Id := UpperCase(TaskId);
  Board := ListTasks(Project);
  if FindOnBoard(Board, Id) < 0 then
  begin
    Err := 'no such task: ' + Project + '/' + TaskId;
    Exit;
  end;
  SetLength(Ids, 0);
  for I := 0 to High(WaitsOn) do
  begin
    if Trim(WaitsOn[I]) = '' then Continue;
    if UpperCase(Trim(WaitsOn[I])) = Id then
    begin
      Err := Id + ' cannot wait on itself.';
      Exit;
    end;
    if FindOnBoard(Board, Trim(WaitsOn[I])) < 0 then
    begin
      Err := Id + ' cannot wait on ' + UpperCase(Trim(WaitsOn[I])) +
             ': there is no such task on ' + Project + '.';
      Exit;
    end;
    K := 0;
    while (K <= High(Ids)) and (Ids[K] <> UpperCase(Trim(WaitsOn[I]))) do Inc(K);
    if K > High(Ids) then
    begin
      SetLength(Ids, Length(Ids) + 1);
      Ids[High(Ids)] := UpperCase(Trim(WaitsOn[I]));
    end;
  end;
  { A cycle: one of the new prerequisites already (transitively) waits on
    this task. }
  for I := 0 to High(Ids) do
    if Reaches(Ids[I], Id) then
    begin
      Err := Id + ' cannot wait on ' + Ids[I] + ': ' + Ids[I] +
             ' already waits on ' + Id + ' (directly or through other ' +
             'tasks), and a cycle is a board where neither can ever start.';
      Exit;
    end;

  Path := JoinPath(TaskDir(Project, TaskId), 'task.json');
  Joined := '';
  GTaskLock.Enter;
  try
    Obj := ReadManifest(Path);
    if Obj = nil then
    begin
      Err := 'no such task: ' + Project + '/' + TaskId;
      Exit;
    end;
    try
      Arr := TJsonArray.Create;
      for I := 0 to High(Ids) do
      begin
        Arr.AddStr(Ids[I]);
        if Joined <> '' then Joined := Joined + ',';
        Joined := Joined + Ids[I];
      end;
      Obj.PutArray('waits_on', Arr);
      Obj.PutStr('updated', NowIsoUtc);
      WriteManifest(Path, Obj);
    finally
      Obj.Free;
    end;
  finally
    GTaskLock.Leave;
  end;
  AppendActivity(Project, Id, 'waits', Actor, ['on', Joined]);
  PublishTask(Project, Id, '');
  Result := True;
end;

procedure SetClaimLeaseMinutes(Minutes: Integer);
begin
  if Minutes < 1 then Minutes := 1;
  GLeaseMinutes := Minutes;
end;

function ClaimLeaseMinutes: Integer;
begin
  Result := GLeaseMinutes;
end;

function ClaimNextTask(const Project, Agent: string; AllowPool: Boolean;
  out TaskId, Err: string): Boolean;
var
  Board: TTaskInfoArray;
  I, Pick: Integer;
  FromPool: Boolean;
  Path, Who: string;
  Obj: TJsonObject;
begin
  TaskId := '';
  Err := '';
  Result := False;
  Who := SanitizeName(Agent);
  if Who = '' then
  begin
    Err := 'next claims work for a named agent';
    Exit;
  end;
  if not ProjectExists(Project) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;
  FromPool := False;
  GTaskLock.Enter;
  try
    { Scanned under the lock that every task write takes: nothing can be
      claimed or moved between the choice and the claim. }
    Board := ListTasks(Project);
    Pick := -1;
    for I := 0 to High(Board) do
      if (Board[I].Status = tsTodo) and (Board[I].Assignee = Who) and
         TaskReady(Board[I], Board) then
      begin
        Pick := I;
        Break;
      end;
    if (Pick < 0) and AllowPool then
      for I := 0 to High(Board) do
        if (Board[I].Status = tsTodo) and (Board[I].Assignee = '') and
           TaskReady(Board[I], Board) then
        begin
          Pick := I;
          FromPool := True;
          Break;
        end;
    if Pick < 0 then Exit;   { nothing ready: Err stays '' }

    Path := JoinPath(TaskDir(Project, Board[Pick].Id), 'task.json');
    Obj := ReadManifest(Path);
    if Obj = nil then
    begin
      Err := 'could not read ' + Board[Pick].Id;
      Exit;
    end;
    try
      Obj.PutStr('status', 'active');
      Obj.PutStr('assignee', Who);
      if Obj.GetStr('started', '') = '' then Obj.PutStr('started', NowIsoUtc);
      Obj.PutStr('lease_by', Who);
      Obj.PutStr('lease_until', IsoUtcInMinutes(GLeaseMinutes));
      if FromPool then Obj.PutStr('claimed_from', 'pool')
                  else Obj.PutStr('claimed_from', '');
      Obj.PutStr('updated', NowIsoUtc);
      WriteManifest(Path, Obj);
    finally
      Obj.Free;
    end;
    TaskId := Board[Pick].Id;
  finally
    GTaskLock.Leave;
  end;
  if FromPool then
    AppendActivity(Project, TaskId, 'claim', Who, ['from', 'pool'])
  else
    AppendActivity(Project, TaskId, 'claim', Who, []);
  PublishTask(Project, TaskId, 'active');
  Result := True;
end;

function ExpireLeases(const Project: string; Busy: TBusyProbe): TStringArray;
var
  Board: TTaskInfoArray;
  I, N: Integer;
  Now_, Path, Holder: string;
  Obj: TJsonObject;
  Pool: Boolean;
begin
  SetLength(Result, 0);
  N := 0;
  Now_ := NowIsoUtc;
  Board := ListTasks(Project);
  for I := 0 to High(Board) do
  begin
    if Board[I].Status <> tsActive then Continue;
    if (Board[I].LeaseUntil = '') or (Board[I].LeaseUntil >= Now_) then Continue;
    Holder := Board[I].LeaseBy;
    { A turn in progress is working, whatever the clock says. }
    if Assigned(Busy) and (Holder <> '') and Busy(Holder) then Continue;

    Path := JoinPath(TaskDir(Project, Board[I].Id), 'task.json');
    Pool := False;
    GTaskLock.Enter;
    try
      Obj := ReadManifest(Path);
      if Obj = nil then Continue;
      try
        { Re-checked: renewed or moved since the scan means not expired. }
        if (LowerCase(Obj.GetStr('status', '')) <> 'active') or
           (Obj.GetStr('lease_until', '') = '') or
           (Obj.GetStr('lease_until', '') >= Now_) then Continue;
        Pool := Obj.GetStr('claimed_from', '') = 'pool';
        Obj.PutStr('status', 'todo');
        Obj.PutStr('started', '');
        Obj.PutStr('lease_by', '');
        Obj.PutStr('lease_until', '');
        Obj.PutStr('claimed_from', '');
        if Pool then Obj.PutStr('assignee', '');
        Obj.PutStr('updated', Now_);
        WriteManifest(Path, Obj);
      finally
        Obj.Free;
      end;
    finally
      GTaskLock.Leave;
    end;
    if Pool then
      AppendActivity(Project, Board[I].Id, 'expire', ActorOperator,
                     ['holder', Holder, 'to', 'pool'])
    else
      AppendActivity(Project, Board[I].Id, 'expire', ActorOperator,
                     ['holder', Holder]);
    PublishTask(Project, Board[I].Id, 'todo');
    SetLength(Result, N + 1);
    Result[N] := Board[I].Id + ' ' + Holder;
    Inc(N);
  end;
end;

{ ------------------------------------------------------------------- jobs -- }

function JobStatusToStr(S: TJobStatus): string;
begin
  case S of
    jsRunning:   Result := 'running';
    jsDone:      Result := 'done';
    jsFailed:    Result := 'failed';
    jsCancelled: Result := 'cancelled';
    else         Result := 'queued';
  end;
end;

function StrToJobStatus(const S: string; Default: TJobStatus): TJobStatus;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  if      L = 'queued'    then Result := jsQueued
  else if L = 'running'   then Result := jsRunning
  else if L = 'done'      then Result := jsDone
  else if L = 'failed'    then Result := jsFailed
  else if L = 'cancelled' then Result := jsCancelled
  else Result := Default;
end;

function LoadJob(const Project, TaskId, JobId: string; out Info: TJobInfo): Boolean;
var
  Dir: string;
  Obj: TJsonObject;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Id := ''; Info.Project := ''; Info.Task := '';
  Info.SessionId := ''; Info.Started := ''; Info.Ended := ''; Info.Summary := '';
  Dir := JobDir(Project, TaskId, JobId);
  if (Dir = '') or not DirectoryExists(Dir) then Exit;

  Info.Id      := UpperCase(JobId);
  Info.Project := Project;
  Info.Task    := UpperCase(TaskId);
  Info.Status  := jsQueued;
  Obj := ReadManifest(JoinPath(Dir, 'job.json'));
  if Obj <> nil then
    try
      Info.Status    := StrToJobStatus(Obj.GetStr('status', 'queued'));
      Info.SessionId := Obj.GetStr('session_id', '');
      Info.Started   := Obj.GetStr('started', '');
      Info.Ended     := Obj.GetStr('ended', '');
      Info.Summary   := Obj.GetStr('summary', '');
    finally
      Obj.Free;
    end;
  Result := True;
end;

function GetJob(const Project, TaskId, JobId: string; out Info: TJobInfo): Boolean;
begin
  Result := LoadJob(Project, TaskId, JobId, Info);
end;

function ListJobs(const Project, TaskId: string): TJobInfoArray;
var
  Dir: string;
  Names: TStringList;
  I, N: Integer;
  Info: TJobInfo;
begin
  SetLength(Result, 0);
  Dir := TaskDir(Project, TaskId);
  if Dir = '' then Exit;
  Names := SubdirNames(JoinPath(Dir, 'jobs'));
  try
    SetLength(Result, Names.Count);
    N := 0;
    for I := 0 to Names.Count - 1 do
      if LoadJob(Project, TaskId, Names[I], Info) then
      begin
        Result[N] := Info;
        Inc(N);
      end;
    SetLength(Result, N);
  finally
    Names.Free;
  end;
end;

function CreateJob(const Project, TaskId, ASessionId: string; out Err: string): string;
var
  TDir, Id, Dir: string;
  Obj: TJsonObject;
  T: TTaskInfo;
begin
  Err := '';
  Result := '';
  TDir := TaskDir(Project, TaskId);
  if (TDir = '') or not DirectoryExists(TDir) then
  begin
    Err := 'no such task: ' + Project + '/' + TaskId;
    Exit;
  end;

  EnsureDir(JoinPath(TDir, 'jobs'));
  { Same reservation as tasks: two turns starting on one task at the same
    moment would otherwise be handed the same job id, and the second
    would overwrite the first one's transcript. }
  Id  := ReserveId(JoinPath(TDir, 'jobs'), 'J');
  Dir := JoinPath(JoinPath(TDir, 'jobs'), Id);
  EnsureDir(JoinPath(Dir, 'artifacts'));

  Obj := TJsonObject.Create;
  try
    Obj.PutStr('id', Id);
    Obj.PutStr('status', 'running');
    Obj.PutStr('session_id', ASessionId);
    Obj.PutStr('started', NowIsoUtc);
    Obj.PutStr('ended', '');
    Obj.PutStr('summary', '');
    WriteManifest(JoinPath(Dir, 'job.json'), Obj);
  finally
    Obj.Free;
  end;

  { A job starting is what makes a task active -- the desktop shows the task
    lighting up without the model having to set the status itself.

    Except a task in review: it is waiting on someone else's verdict, and
    a run starting on it (the operator pressing Run, say) must not quietly
    take it out of review -- that is the one move review exists to stop. }
  if not (GetTask(Project, TaskId, T) and (T.Status = tsReview)) then
    UpdateTask(Project, TaskId, '', '-', 'active', Err);
  Err := '';
  PublishJob(Project, UpperCase(TaskId), Id, 'running');
  Result := Id;
end;

function DoUpdateJob(const Project, TaskId, JobId, AStatus, ASummary,
  ASessionId, Actor: string; out Err, SubmitErr: string): Boolean;
var
  Dir, Path, St, Ignored, Evidence: string;
  Obj: TJsonObject;
  Others: TJobInfoArray;
  T: TTaskInfo;
  J: TJobInfo;
  I: Integer;
  Busy: Boolean;
begin
  Err := '';
  SubmitErr := '';
  Result := False;
  Dir := JobDir(Project, TaskId, JobId);
  if (Dir = '') or not DirectoryExists(Dir) then
  begin
    Err := 'no such job: ' + Project + '/' + TaskId + '/' + JobId;
    Exit;
  end;
  St := LowerCase(Trim(AStatus));
  if (St <> '') and (St <> 'queued') and (St <> 'running') and (St <> 'done')
     and (St <> 'failed') and (St <> 'cancelled') then
  begin
    Err := 'status must be queued, running, done, failed or cancelled (got "'
           + AStatus + '")';
    Exit;
  end;

  Path := JoinPath(Dir, 'job.json');
  Obj := ReadManifest(Path);
  if Obj = nil then
  begin
    Obj := TJsonObject.Create;
    Obj.PutStr('id', UpperCase(JobId));
    Obj.PutStr('started', NowIsoUtc);
  end;
  try
    if St <> '' then
    begin
      Obj.PutStr('status', St);
      { A terminal status stamps the end time once; re-reporting 'done'
        shouldn't keep moving it. }
      if (St = 'done') or (St = 'failed') or (St = 'cancelled') then
      begin
        if Obj.GetStr('ended', '') = '' then
          Obj.PutStr('ended', NowIsoUtc);
      end
      else
        Obj.PutStr('ended', '');
    end;
    if ASummary   <> '-' then Obj.PutStr('summary', ASummary);
    if ASessionId <> '-' then Obj.PutStr('session_id', ASessionId);
    WriteManifest(Path, Obj);
  finally
    Obj.Free;
  end;
  if St <> '' then
    PublishJob(Project, UpperCase(TaskId), UpperCase(JobId), St);

  (* A task is done when its last job is. Opening a job makes the task
     active (CreateJob), so the symmetric rule belongs here rather than in
     any one caller -- the `task` tool, an HTTP PATCH and the gateway's job
     runner all finish jobs, and before this only the tool closed the task.

     Two guards: a task with another job still in flight stays active, and a
     task the user marked BLOCKED is not quietly reopened as done -- only an
     active task closes itself. *)
  if (St = 'done') or (St = 'failed') or (St = 'cancelled') then
  begin
    Others := ListJobs(Project, TaskId);
    Busy := False;
    for I := 0 to High(Others) do
      if Others[I].Status in [jsQueued, jsRunning] then
      begin
        Busy := True;
        Break;
      end;
    if not Busy and GetTask(Project, TaskId, T) and (T.Status = tsActive) then
    begin
      if (St = 'done') and ProjectRequiresReview(Project) then
      begin
        (* A board that requires review: finishing is SUBMITTING. The job's
           summary is the evidence -- it is what the run said it did -- and
           a run that said nothing still names itself, so the reviewer
           knows where to look. *)
        Evidence := '';
        if GetJob(Project, TaskId, JobId, J) then Evidence := Trim(J.Summary);
        if Evidence = '' then
          Evidence := 'job ' + UpperCase(JobId) + ' finished (no summary given)';
        SubmitTask(Project, TaskId, Actor, Evidence, JobId, SubmitErr);
      end
      else if St = 'done' then
        UpdateTask(Project, TaskId, '', '-', 'done', Ignored)
      else
        { A failed run leaves work to do -- back to todo, not done. }
        UpdateTask(Project, TaskId, '', '-', 'todo', Ignored);
    end;
  end;
  Result := True;
end;

function UpdateJob(const Project, TaskId, JobId, AStatus, ASummary,
  ASessionId: string; out Err: string; const Actor: string): Boolean;
var
  SubmitErr: string;
begin
  Result := DoUpdateJob(Project, TaskId, JobId, AStatus, ASummary, ASessionId,
                        Actor, Err, SubmitErr);
  { Nobody is waiting on this call to hear it -- the job runner, an HTTP
    PATCH -- so the refusal goes where the operator looks at a run. }
  if SubmitErr <> '' then
    AppendJobLog(Project, TaskId, JobId, 'not submitted for review: ' + SubmitErr);
end;

function FinishJob(const Project, TaskId, JobId, AStatus, ASummary: string;
  const Actor: string; out Err, SubmitErr: string): Boolean;
begin
  Result := DoUpdateJob(Project, TaskId, JobId, AStatus, ASummary, '-',
                        Actor, Err, SubmitErr);
end;

procedure AppendJobLog(const Project, TaskId, JobId, Line: string);
var
  Dir, Path: string;
  F: TextFile;
begin
  Dir := JobDir(Project, TaskId, JobId);
  if (Dir = '') or not DirectoryExists(Dir) then Exit;
  Path := JoinPath(Dir, 'job.log');
  AssignFile(F, Path);
  try
    if FileExists(Path) then
      Append(F)
    else
      Rewrite(F);
    WriteLn(F, Line);
  finally
    CloseFile(F);
  end;
  PublishJobLog(Project, UpperCase(TaskId), UpperCase(JobId), Line);
end;

function ReadJobLog(const Project, TaskId, JobId: string): string;
var
  Dir, Path: string;
begin
  Result := '';
  Dir := JobDir(Project, TaskId, JobId);
  if Dir = '' then Exit;
  Path := JoinPath(Dir, 'job.log');
  if FileExists(Path) then
    Result := ReadFileText(Path);
end;

initialization
  GIdLock := TCriticalSection.Create;
  GTaskLock := TCriticalSection.Create;
  GActivityLock := TCriticalSection.Create;

finalization
  FreeAndNil(GActivityLock);
  FreeAndNil(GTaskLock);
  FreeAndNil(GIdLock);

end.
