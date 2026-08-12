program workspace_isolation_tests;
(*
  Proves the wall. "Business A in workspace 1, business B in workspace 2,
  and they must not know each other" -- this file is what makes that a
  property instead of a hope.

  Two halves:

  1. NO-OP. With a single workspace, every resolved path must equal the
     string the pre-refactor code produced. ~70 call sites were rerouted
     through ActiveWorkspaceName; this is what let that land without
     changing anything for anyone who never makes a second workspace.

  2. LEAK. Write a fact, a note and a session in workspace 1; switch; prove
     workspace 2 sees none of them; switch back; prove nothing was lost.
     Then the one that matters most: the sandbox. Moving the stores while
     the sandbox stays put makes the wall decorative -- the agent would
     just fs_read the other workspace's memory directory. So the last
     assertions are refusals, not lookups.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Config.Profile,
  PasClaw.Workspaces,
  PasClaw.Session.Store,
  PasClaw.Memory.Facts,
  PasClaw.Memory.Distill,
  PasClaw.Suite.Notes,
  PasClaw.KB.Index,
  PasClaw.Skills.Loader,
  PasClaw.Tools.Sandbox,
  DateUtils;

var
  Failures: Integer = 0;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Inc(Failures);
end;

procedure ExpectTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure ExpectStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' -- got "' + Got + '", want "' + Want + '"');
end;

function AddFact(const Text_: string): Boolean;
var
  Store: IFactStore;
  F: TFact;
begin
  Result := False;
  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(GetHome)) then Exit;
  try
    F.Text := Text_;
    F.Kind := 'static';
    F.Scope := 'user';
    F.Confidence := 1.0;
    F.EventDate := '';
    F.Expires := '';
    F.SourceSession := 'test';
    Result := Store.Add(F, DateTimeToUnix(Now, False)) > 0;
  finally
    Store.Close;
  end;
end;

function CountFacts: Integer;
var
  Store: IFactStore;
begin
  Result := 0;
  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(GetHome)) then Exit;
  try
    Result := Store.CountAll;
  finally
    Store.Close;
  end;
end;

var
  Home, Err, Slug, Reason: string;
  Notes: TNoteInfoArray;
  Policy: TSandboxPolicy;
  Ws1Memory: string;
begin
  Home := GetHome;

  { ------------------------------------------------------------ no-op -- }
  (* Byte-for-byte: these are the strings the hardcoded call sites produced
     before the refactor. If any of these fail, single-workspace users are
     affected, and that is a stop-ship. *)
  ExpectStr(SessionsDir, JoinPath(Home, 'workspace/sessions'),
            'no-op: the session store path is unchanged');
  ExpectStr(DefaultFactsDbPath(Home),
            JoinPath(JoinPath(JoinPath(Home, 'workspace'), 'memory'), 'facts.db'),
            'no-op: the facts db path is unchanged');
  ExpectStr(DefaultKBDbPath, JoinPath(JoinPath(Home, 'workspace'), 'kb.db'),
            'no-op: the kb path is unchanged');
  ExpectStr(NotesDir, JoinPath(JoinPath(Home, 'workspace'), 'memory/notes'),
            'no-op: the notes path is unchanged');

  { ------------------------------------------------- write in workspace 1 -- }
  ExpectTrue(AddFact('Business A ships on Fridays'), 'a fact lands in ws1');
  ExpectTrue(SaveNote('', 'A pricing', 'Client A pays net 30.', Err) <> '',
             'a note lands in ws1: ' + Err);
  EnsureDir(SessionsDir);
  WriteFileText(JoinPath(SessionsDir, 'ws1-session.json'),
                '{"id":"ws1-session","title":"Business A call"}');
  Ws1Memory := JoinPath(Home, 'workspace/memory');

  { ------------------------------------------------------------ switch -- }
  Slug := CreateWorkspace('Business B');
  ExpectStr(Slug, 'workspace2', 'a second workspace exists');
  ExpectTrue(SetActiveWorkspace('workspace2', Err), 'switch: ' + Err);

  (* THE WALL. Everything written a moment ago must be invisible. Each of
     these is a store that used to hardcode workspace/ -- a regression in
     any one of them silently reconnects the two businesses. *)
  ExpectTrue(CountFacts = 0, 'ws2 does not know Business A''s facts');
  Notes := ListNotes;
  ExpectTrue(Length(Notes) = 0, 'ws2 does not see Business A''s notes');
  ExpectTrue(not FileExists(JoinPath(SessionsDir, 'ws1-session.json')),
             'ws2 does not see Business A''s sessions');
  ExpectStr(SessionsDir, JoinPath(Home, 'workspace2/sessions'),
            'the session store followed the switch');
  ExpectStr(DefaultKBDbPath, JoinPath(JoinPath(Home, 'workspace2'), 'kb.db'),
            'the knowledgebase followed the switch');
  { Skills: no skill exists in either world here, so assert the ROOT the
    loader scans rather than indexing an empty array. A skill dropped into
    ws1's directory must not be loadable from ws2. }
  WriteFileText(JoinPath(Home, 'workspace/skills/probe.json'),
                '{"name":"probe","description":"ws1 skill","kind":"prompt","prompt":"x"}');
  ExpectTrue(Length(LoadSkillManifests(Home)) = 0,
             'a skill installed in ws1 is not loadable from ws2');

  { The two worlds must also WRITE apart: a fact added in ws2 must not
    reach ws1. }
  ExpectTrue(AddFact('Business B pays net 60'), 'a fact lands in ws2');
  ExpectTrue(CountFacts = 1, 'and only that fact is here');

  (* THE SANDBOX. The assertions above prove the stores moved; this proves
     the agent cannot simply walk back in. With restrict_to_workspace on and
     the workspace pointed at ws2, reading ws1's memory directory must be
     REFUSED -- if it is not, everything above is decoration. *)
  FillChar(Policy, SizeOf(Policy), 0);
  Policy.RestrictToWorkspace := True;
  ConfigureSandbox(Policy, JoinPath(Home, 'workspace2'));
  ExpectTrue(not CanReadPath(JoinPath(Ws1Memory, 'facts.db'), Reason),
             'LEAK: the sandbox must refuse ws1''s facts db from ws2');
  ExpectTrue(not CanReadPathHTTP(Ws1Memory, Reason),
             'LEAK: the operator browse must not reach ws1''s memory either');
  ExpectTrue(CanReadPath(JoinPath(Home, 'workspace2/memory'), Reason),
             'and ws2 can still read its own memory: ' + Reason);

  { ------------------------------------------------------- switch back -- }
  ExpectTrue(SetActiveWorkspace('workspace', Err), 'switch back: ' + Err);
  ExpectTrue(CountFacts = 1, 'Business A''s fact survived untouched');
  Notes := ListNotes;
  ExpectTrue((Length(Notes) = 1) and (Pos('net 30', Notes[0].Body) > 0),
             'Business A''s note survived untouched');
  ExpectTrue(FileExists(JoinPath(SessionsDir, 'ws1-session.json')),
             'Business A''s session survived untouched');

  { -------------------------------------------- workspace -> profile -- }
  (* Phase 7: a workspace names the profile it works under. Below the
     explicit selectors (CLI/env must win), above the global field. *)
  ExpectStr(ExtractWorkspaceProfile(
    '{"active_workspace":"workspace2",' +
    '"workspace_profiles":{"workspace2":"security"}}'), 'security',
    'the active workspace''s binding is found');
  ExpectStr(ExtractWorkspaceProfile(
    '{"workspace_profiles":{"workspace2":"security"}}'), '',
    'no binding for the default workspace, no profile');
  ExpectStr(ExtractWorkspaceProfile('{"active_workspace":"../etc"}'), '',
    'a malformed name never reaches the map');

  { ------------------------------------------------- cron thread pin -- }
  (* Phase 8: the scheduler pins its thread to a tagged entry's workspace
     for the duration of a firing. The pin outranks env and config, and
     clearing it restores whatever they said. *)
  SetThreadWorkspace('workspace2');
  ExpectStr(ActiveWorkspaceName, 'workspace2', 'the pin wins');
  ExpectStr(SessionsDir, JoinPath(Home, 'workspace2/sessions'),
            'and every store follows it');
  SetThreadWorkspace('../etc');
  ExpectStr(ActiveWorkspaceName, 'workspace2',
            'a malformed pin is refused, not applied');
  SetThreadWorkspace('');
  ExpectStr(ActiveWorkspaceName, 'workspace',
            'clearing the pin restores the configured workspace');

  if Failures = 0 then
    WriteLn('workspace_isolation_tests: OK')
  else
  begin
    WriteLn('workspace_isolation_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
