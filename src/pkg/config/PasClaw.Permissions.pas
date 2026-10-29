(*
  PasClaw.Permissions - one ordered rule list for what a tool may do.

  PasClaw had four unrelated gates: plan-mode refusal of mutating tools,
  the sandbox's shell denylist and path rules, the family switches
  (web_fetch_enabled, cron_tool_enabled, ...), and the component's
  BeforeToolCall hook. None of them let an operator say the ordinary
  thing: "ask me before shell_exec, but git status and git diff are fine,
  and git push is never fine". This unit does, in the shape OpenCode 2.0
  settled on:

    "permissions": [
      {"tool": "shell_exec",  "effect": "ask"},
      {"tool": "shell_exec",  "resource": "git status*", "effect": "allow"},
      {"tool": "shell_exec",  "resource": "git diff*",   "effect": "allow"},
      {"tool": "shell_exec",  "resource": "git push*",   "effect": "deny"},
      {"tool": "github__*",   "effect": "ask"}
    ]

  A rule matches when its tool glob matches the tool name and its
  resource glob (empty = any) matches the call's primary resource -- the
  command for the shell tools, the path for the file tools, the URL for
  the fetch tools (ResourceOf). The LAST matching rule wins. No matching
  rule means "no opinion": the call proceeds through the gates that
  already existed, so an empty list changes nothing.

  Effects:
    allow  proceed
    deny   the call is refused with a result the model can read
    ask    the loop's asker (TUI footer, CLI prompt, gateway event +
           POST /v1/permissions/<id>, the component's OnAsk event) is
           asked; allow once, allow for this session, or deny. With no
           asker wired the answer is deny -- a rule that says "ask" must
           never silently become "allow" because nobody was there.

  Policies are the same rules from a separate file, <home>/policies.json,
  that the gateway's PUT /v1/config cannot write and that is re-read when
  its mtime changes. They are evaluated FIRST and a policy deny is final;
  the team case is a gateway that owns the file, the single-user case
  never has one.

  Everything that decides is pure and tested; the process-global state
  (the two rule lists, the session allow-list) lives here behind a lock
  because tool dispatch happens on loop threads and parallel workers.
*)
unit PasClaw.Permissions;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes, SyncObjs;

type
  TPermEffect = (peNone, peAllow, peDeny, peAsk);

  TPermRule = record
    Tool:     string;   { glob over the tool name; '' or '*' = every tool }
    Resource: string;   { glob over the primary resource; '' = any }
    Effect:   TPermEffect;
    Source:   string;   { 'config' | 'policy' -- for messages and `permissions list` }
  end;
  TPermRuleArray = array of TPermRule;

  TAskAnswer = (aaDeny, aaAllowOnce, aaAllowSession);

  { The asker a loop config carries. Called on the dispatching thread
    (loop thread, or a parallel worker) and expected to block until a
    human answers or a timeout passes. Reason is one line for the UI:
    which rule asked, from which file. }
  TPermAskFn = function(const ToolName, ArgsJSON, Resource, Reason: string): TAskAnswer of object;

  TPermDecision = record
    Effect:     TPermEffect;   { peNone when no rule matched }
    Index:      Integer;       { index into the list that decided, -1 when none }
    FromPolicy: Boolean;
    Rule:       TPermRule;
  end;

const
  PolicyFileName = 'policies.json';

{ ---- pure ---- }

{ Case-insensitive glob: * matches any run (including empty), ? one char.
  An empty pattern matches only an empty string. }
function GlobMatch(const Pattern, S: string): Boolean;

function ParseEffect(const S: string; out E: TPermEffect): Boolean;
function EffectName(E: TPermEffect): string;
function AskAnswerName(A: TAskAnswer): string;   { deny | allow | session }

{ The call's primary resource: what a resource glob is matched against.
  shell_exec / shell_background: command; execute_code: code; web_fetch /
  memory_fetch: url. Every other tool -- the whole file family and its
  fs_* aliases, grep_files, find_files, kb_get, an MCP tool nobody here
  has heard of -- yields its "path", else "url", else "command"
  argument, so a resource rule reaches a tool without this unit being
  taught its name. '' when it has none of them. Pure. }
function ResourceOf(const ToolName, ArgsJSON: string): string;

{ Last matching rule wins. Index is into Rules. }
function EvaluateRules(const Rules: TPermRuleArray; const Tool, Resource: string): TPermDecision;

{ Rules from a JSON array text of tool / resource / effect objects. Entries
  without a valid effect are skipped. Source is stamped on each. }
function ParsePermissionRules(const JSONArrayText, Source: string): TPermRuleArray;

{ Rules back to a JSON array text (config round-trip). }
function PermissionRulesToJSON(const Rules: TPermRuleArray): string;

{ The result text the model sees for a deny, phrased like the mode refusals. }
function PermissionRefusal(const Tool, Resource: string; const D: TPermDecision): string;
{ The result text when an ask was answered deny (or nobody was there to ask). }
function PermissionAskRefusal(const Tool, Resource: string; NobodyAsked: Boolean): string;
{ One line for the asker UI: which rule, from which file. }
function PermissionAskReason(const D: TPermDecision): string;

{ ---- process-global state ---- }

procedure SetPermissionRules(const Rules: TPermRuleArray);
function  PermissionRules: TPermRuleArray;

function  PolicyFilePath(const Home: string): string;
{ Read <Home>/policies.json (an object with a "permissions" array, or a bare array). A
  missing file clears the policy rules. Remembers the mtime; Decide calls
  RefreshPolicies, which re-reads only when the mtime moved. }
procedure LoadPolicyFile(const Home: string);
procedure RefreshPolicies;
function  PolicyRules: TPermRuleArray;
{ How many reads of the policy file were unusable and left the previous
  rules standing. Non-zero means what is in force is not what is on
  disk; `permissions list` says so. }
function  PolicyLoadFailures: Integer;

{ Policies first; a policy deny is final. Then the config rules. }
function Decide(const Tool, Resource: string): TPermDecision;

(* Turn-taking for an asker that has ONE place to ask.

   The TUI footer and the CLI prompt are a single line of screen and a
   single stdin; the loop dispatches tool calls in parallel, so two
   ask-gated calls in one batch reach the asker on two threads at once.
   Unserialised, the TUI overwrote the pending request with the second
   one and woke both waiters on one keypress -- one keystroke approving
   a call the operator never saw -- and the CLI had two threads reading
   the same stdin, so an answer meant for the prompt on screen could be
   consumed by the other thread's ReadLn. (Codex P1 on #611, twice.)

   A surface whose prompt is a shared console wraps its asker body in
   these. The gateway deliberately does NOT: its requests carry ids,
   each has its own event, and the web UI can show several at once.

   The cost is honest -- the second call waits for the first to be
   answered, up to permissions_ask_timeout_sec -- and the batch could
   not have finished before all its answers were in anyway. *)
procedure BeginInteractiveAsk;
procedure EndInteractiveAsk;

{ "Allow for this session" memory, keyed by the loop's session key. }
procedure RememberSessionAllow(const SessionKey, Tool, Resource: string);
function  SessionAllowed(const SessionKey, Tool, Resource: string): Boolean;
procedure ForgetSessionAllows(const SessionKey: string);

implementation

uses
  PasClaw.Utils,   { ReadFileText }
  PasClaw.Logger,  { LogWarn -- a policy file we could not use must say so }
  PasClaw.JSON;

{ ------------------------------------------------------------- glob }

function GlobMatch(const Pattern, S: string): Boolean;
var
  P, T: string;
  function M(pi, si: Integer): Boolean;
  begin
    while pi <= Length(P) do
    begin
      case P[pi] of
        '*':
          begin
            { Collapse runs of *; then try every split. }
            while (pi <= Length(P)) and (P[pi] = '*') do Inc(pi);
            if pi > Length(P) then Exit(True);
            while si <= Length(T) + 1 do
            begin
              if M(pi, si) then Exit(True);
              Inc(si);
            end;
            Exit(False);
          end;
        '?':
          begin
            if si > Length(T) then Exit(False);
            Inc(pi); Inc(si);
          end;
      else
        if (si > Length(T)) or (P[pi] <> T[si]) then Exit(False);
        Inc(pi); Inc(si);
      end;
    end;
    Result := si > Length(T);
  end;
begin
  P := LowerCase(Pattern);
  T := LowerCase(S);
  Result := M(1, 1);
end;

function ParseEffect(const S: string; out E: TPermEffect): Boolean;
var
  L: string;
begin
  Result := True;
  L := LowerCase(Trim(S));
  if L = 'allow' then E := peAllow
  else if L = 'deny' then E := peDeny
  else if L = 'ask' then E := peAsk
  else
  begin
    E := peNone;
    Result := False;
  end;
end;

function EffectName(E: TPermEffect): string;
begin
  case E of
    peAllow: Result := 'allow';
    peDeny:  Result := 'deny';
    peAsk:   Result := 'ask';
  else       Result := 'none';
  end;
end;

function AskAnswerName(A: TAskAnswer): string;
begin
  case A of
    aaAllowOnce:    Result := 'allow';
    aaAllowSession: Result := 'session';
  else              Result := 'deny';
  end;
end;

{ --------------------------------------------------------- resource }

function ArgStr(const ArgsJSON, Field: string): string;
var
  Obj: TJsonObject;
begin
  Result := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
  except
    Obj := nil;
  end;
  if Obj = nil then Exit;
  try
    Result := Obj.GetStr(Field, '');
  finally
    Obj.Free;
  end;
end;

function ResourceOf(const ToolName, ArgsJSON: string): string;
(* The two shell tools and the two fetch tools are named because the
   field their resource lives in is particular to them. Everything else
   falls through to the three fields an operator actually writes a
   resource glob against, in the order a tool that has more than one
   would mean them.

   That fall-through replaced a list of file-tool names, which had gone
   stale the moment the Glob/Grep pair landed: grep_files and find_files
   both take a path, neither was named, so a policy denying `/etc*` for
   every tool did not match grep_files({"path":"/etc"}) and the search
   went ahead. A list of names has to be revisited by whoever adds a
   tool -- including an MCP server, whose tools nobody here will ever
   name -- and nothing makes them. Reading the argument does not.
   (Codex P1 on #611.)

   apply_patch is the one real gap left, and no field would close it: its
   paths are inside the patch body, several of them, and a glob over
   that text would match by accident as often as on purpose. Scope it by
   tool (`{"tool":"apply_patch","effect":"ask"}`); the sandbox's path
   rules still bound where it can write. *)
var
  N: string;
begin
  N := LowerCase(ToolName);
  if (N = 'shell_exec') or (N = 'shell_background') then Exit(ArgStr(ArgsJSON, 'command'));
  if N = 'execute_code' then Exit(ArgStr(ArgsJSON, 'code'));
  if (N = 'web_fetch') or (N = 'memory_fetch') then Exit(ArgStr(ArgsJSON, 'url'));
  { A worktree is named by its branch; no generic field below would find
    it. worktree_remove takes a `path` and needs no case of its own. }
  if N = 'worktree_create' then Exit(ArgStr(ArgsJSON, 'branch'));
  Result := ArgStr(ArgsJSON, 'path');
  if Result <> '' then Exit;
  Result := ArgStr(ArgsJSON, 'url');
  if Result <> '' then Exit;
  Result := ArgStr(ArgsJSON, 'command');
end;

{ --------------------------------------------------------- evaluate }

function EvaluateRules(const Rules: TPermRuleArray; const Tool, Resource: string): TPermDecision;
var
  i: Integer;
  ToolPat: string;
begin
  Result.Effect := peNone;
  Result.Index := -1;
  Result.FromPolicy := False;
  Result.Rule := Default(TPermRule);
  for i := 0 to High(Rules) do
  begin
    ToolPat := Rules[i].Tool;
    if ToolPat = '' then ToolPat := '*';
    if not GlobMatch(ToolPat, Tool) then Continue;
    if (Rules[i].Resource <> '') and (not GlobMatch(Rules[i].Resource, Resource)) then Continue;
    { last match wins: keep overwriting }
    Result.Effect := Rules[i].Effect;
    Result.Index := i;
    Result.Rule := Rules[i];
  end;
end;

function ParsePermissionRules(const JSONArrayText, Source: string): TPermRuleArray;
var
  Arr: TJsonArray;
  Obj: TJsonObject;
  i, n: Integer;
  E: TPermEffect;
begin
  SetLength(Result, 0);
  if Trim(JSONArrayText) = '' then Exit;
  try
    Arr := TJsonArray.Parse(JSONArrayText);
  except
    Arr := nil;
  end;
  if Arr = nil then Exit;
  try
    SetLength(Result, Arr.Count);
    n := 0;
    for i := 0 to Arr.Count - 1 do
    begin
      Obj := Arr.ItemObject(i);
      if Obj = nil then Continue;
      try
        if not ParseEffect(Obj.GetStr('effect', ''), E) then Continue;
        Result[n].Tool := Trim(Obj.GetStr('tool', ''));
        Result[n].Resource := Obj.GetStr('resource', '');
        Result[n].Effect := E;
        Result[n].Source := Source;
        Inc(n);
      finally
        Obj.Free;
      end;
    end;
    SetLength(Result, n);
  finally
    Arr.Free;
  end;
end;

function PermissionRulesToJSON(const Rules: TPermRuleArray): string;
var
  Arr: TJsonArray;
  Obj: TJsonObject;
  i: Integer;
begin
  Arr := TJsonArray.Create;
  try
    for i := 0 to High(Rules) do
    begin
      Obj := TJsonObject.Create;
      Obj.PutStr('tool', Rules[i].Tool);
      if Rules[i].Resource <> '' then Obj.PutStr('resource', Rules[i].Resource);
      Obj.PutStr('effect', EffectName(Rules[i].Effect));
      Arr.AddObject(Obj);
    end;
    Result := Arr.ToJSON;
  finally
    Arr.Free;
  end;
end;

function PermissionRefusal(const Tool, Resource: string; const D: TPermDecision): string;
var
  Where, Res: string;
begin
  if D.FromPolicy then Where := 'a policy (policies.json)' else Where := 'the permissions rules (config.json)';
  Res := Resource;
  if Length(Res) > 120 then Res := Copy(Res, 1, 117) + '...';
  if Res <> '' then Res := ' on "' + Res + '"';
  Result := 'refused: tool "' + Tool + '"' + Res + ' is denied by ' + Where;
  if D.Rule.Tool <> '' then
    Result := Result + ' (rule: tool=' + D.Rule.Tool;
  if D.Rule.Resource <> '' then
    Result := Result + ' resource=' + D.Rule.Resource;
  if D.Rule.Tool <> '' then
    Result := Result + ')';
  Result := Result + '. Do not retry the same call; tell the user what you needed ' +
            'and why, or find another way.';
end;

function PermissionAskRefusal(const Tool, Resource: string; NobodyAsked: Boolean): string;
var
  Res: string;
begin
  Res := Resource;
  if Length(Res) > 120 then Res := Copy(Res, 1, 117) + '...';
  if Res <> '' then Res := ' on "' + Res + '"';
  if NobodyAsked then
    Result := 'refused: tool "' + Tool + '"' + Res + ' needs the user''s permission ' +
              'and no one is here to ask -- this session has ' +
              'no interactive operator. Do not retry the same call; tell the user ' +
              'what you needed and why, or find another way.'
  else
    Result := 'refused: the user declined to allow tool "' + Tool + '"' + Res +
              '. Do not retry the same call; ask the user what they would prefer, ' +
              'or find another way.';
end;

function PermissionAskReason(const D: TPermDecision): string;
begin
  if D.FromPolicy then Result := 'policies.json' else Result := 'config.json permissions';
  Result := Result + ' rule: tool=' + D.Rule.Tool;
  if D.Rule.Resource <> '' then Result := Result + ' resource=' + D.Rule.Resource;
end;

{ ------------------------------------------------------------ state }

var
  GLock:        TCriticalSection;
  GRules:       TPermRuleArray;
  GPolicies:    TPermRuleArray;
  GPolicyPath:  string;
  GPolicyMtime: TDateTime;
  GPolicySize:  Int64;
  GPolicyFails: Integer;   { reads kept the previous rules; `permissions list` shows it }
  GAllows:      TStringList;   { "<session>|<tool>|<resource>" }
  { Held for the whole of one interactive ask -- see BeginInteractiveAsk.
    Separate from GLock, which is only ever held for a field read. }
  GAskTurn:     TCriticalSection;

procedure SetPermissionRules(const Rules: TPermRuleArray);
var
  i: Integer;
begin
  GLock.Enter;
  try
    SetLength(GRules, Length(Rules));
    for i := 0 to High(Rules) do GRules[i] := Rules[i];
  finally
    GLock.Leave;
  end;
end;

function PermissionRules: TPermRuleArray;
var
  i: Integer;
begin
  GLock.Enter;
  try
    SetLength(Result, Length(GRules));
    for i := 0 to High(GRules) do Result[i] := GRules[i];
  finally
    GLock.Leave;
  end;
end;

function PolicyFilePath(const Home: string): string;
begin
  Result := IncludeTrailingPathDelimiter(Home) + PolicyFileName;
end;

function ReadWholeFile(const Path: string): string;
begin
  try
    Result := ReadFileText(Path);   { UTF-8, BOM-tolerant -- PasClaw.Utils }
  except
    Result := '';
  end;
end;

procedure PolicyLoadFailedLocked(const What: string);
{ Caller holds GLock. Says it out loud once per failed stamp -- silence
  here would read as "no policies", which is the thing being avoided. }
begin
  Inc(GPolicyFails);
  LogWarn('permissions: could not %s %s -- keeping the %d policy rule(s) ' +
          'already in force', [What, GPolicyPath, Length(GPolicies)]);
end;

function JSONArrayParses(const S: string): Boolean;
var
  A: TJsonArray;
begin
  try
    A := TJsonArray.Parse(S);
  except
    A := nil;
  end;
  Result := A <> nil;
  if A <> nil then A.Free;
end;

(* Read the policy file into GPolicies.

   The active rules are replaced only on a SUCCESSFUL read, and only a
   file that is gone clears them. The first cut cleared GPolicies up
   front and then returned early on every failure -- unreadable,
   truncated, not JSON, no "permissions" array -- so a policies.json
   being rewritten non-atomically left the process with NO policy denies
   for the length of that window, and RefreshPolicies had already
   consumed the mtime, so if the final write landed in the same
   filesystem timestamp the empty state was permanent. A file a team
   gateway owns is exactly the file that gets rewritten under a running
   agent. (Codex P1 on #611.)

   Returns False when the content could not be used, so the caller can
   leave the change stamp alone and try again. *)
function ReadPoliciesLocked(const Path: string): Boolean;
var
  Text, Inner: string;
  Obj: TJsonObject;
  Arr: TJsonArray;
begin
  { A missing file is a decision, not a failure: it clears the rules. }
  if not FileExists(Path) then
  begin
    SetLength(GPolicies, 0);
    Exit(True);
  end;
  Text := Trim(ReadWholeFile(Path));
  { Empty is indistinguishable from the moment between truncate and
    write, so it is a failure, not "no rules". Delete the file to clear. }
  if Text = '' then Exit(False);
  Inner := '';
  if Text[1] = '[' then
    Inner := Text
  else
  begin
    try
      Obj := TJsonObject.Parse(Text);
    except
      Obj := nil;
    end;
    if Obj = nil then Exit(False);
    try
      Arr := Obj.ChildArray('permissions');
      if Arr = nil then Exit(False);
      try
        Inner := Arr.ToJSON;
      finally
        Arr.Free;
      end;
    finally
      Obj.Free;
    end;
  end;
  { ParsePermissionRules returns an empty array both for `[]` -- a valid
    file that says "no rules" -- and for a truncated one it could not
    parse at all. Those must not be treated alike, so check the array
    parses before trusting the (possibly empty) result. }
  if not JSONArrayParses(Inner) then Exit(False);
  GPolicies := ParsePermissionRules(Inner, 'policy');
  Result := True;
end;

(* The change stamp: modification time AND size.

   Size is in it because mtime alone cannot see the recovery. A
   non-atomic rewrite can leave a truncated file and then a good one
   inside the same filesystem timestamp (one-second granularity is still
   common, and some filesystems coarser); with mtime alone the good
   write looks identical to the bad one we already read, and the process
   keeps the stale rules for good. Sizes differ in practice. *)
procedure PolicyStamp(const Path: string; out Mt: TDateTime; out Size: Int64);
var
  SR: SysUtils.TSearchRec;
begin
  Mt := 0;
  Size := -1;
  if SysUtils.FindFirst(Path, faAnyFile, SR) = 0 then
  begin
    Size := SR.Size;
    {$IFDEF FPC}
    Mt := FileDateToDateTime(SR.Time);
    {$ELSE}
    Mt := SR.TimeStamp;
    {$ENDIF}
    SysUtils.FindClose(SR);
  end;
end;

procedure LoadPolicyFile(const Home: string);
begin
  GLock.Enter;
  try
    GPolicyPath := PolicyFilePath(Home);
    PolicyStamp(GPolicyPath, GPolicyMtime, GPolicySize);
    if not ReadPoliciesLocked(GPolicyPath) then
      PolicyLoadFailedLocked('load');
  finally
    GLock.Leave;
  end;
end;

procedure RefreshPolicies;
var
  Mt: TDateTime;
  Size: Int64;
begin
  GLock.Enter;
  try
    if GPolicyPath = '' then Exit;
    PolicyStamp(GPolicyPath, Mt, Size);
    if (Mt = GPolicyMtime) and (Size = GPolicySize) then Exit;
    { Adopt the stamp either way: a file we could not use is re-read when
      it changes again, not on every tool call. What we do NOT do is drop
      the rules we already have. }
    GPolicyMtime := Mt;
    GPolicySize  := Size;
    if not ReadPoliciesLocked(GPolicyPath) then
      PolicyLoadFailedLocked('reload');
  finally
    GLock.Leave;
  end;
end;

function PolicyLoadFailures: Integer;
begin
  GLock.Enter;
  try
    Result := GPolicyFails;
  finally
    GLock.Leave;
  end;
end;

function PolicyRules: TPermRuleArray;
var
  i: Integer;
begin
  RefreshPolicies;
  GLock.Enter;
  try
    SetLength(Result, Length(GPolicies));
    for i := 0 to High(GPolicies) do Result[i] := GPolicies[i];
  finally
    GLock.Leave;
  end;
end;

function Decide(const Tool, Resource: string): TPermDecision;
var
  P: TPermDecision;
begin
  RefreshPolicies;
  GLock.Enter;
  try
    P := EvaluateRules(GPolicies, Tool, Resource);
    if P.Effect = peDeny then
    begin
      P.FromPolicy := True;
      Exit(P);
    end;
    Result := EvaluateRules(GRules, Tool, Resource);
    { A policy ask outranks a config allow; a policy allow is just an
      opinion the config may still tighten. }
    if (P.Effect = peAsk) and (Result.Effect <> peDeny) then
    begin
      P.FromPolicy := True;
      Exit(P);
    end;
  finally
    GLock.Leave;
  end;
end;

function AllowKey(const SessionKey, Tool, Resource: string): string;
var
  SK: string;
begin
  SK := SessionKey;
  if SK = '' then SK := 'default';
  Result := SK + '|' + LowerCase(Tool) + '|' + Resource;
end;

procedure BeginInteractiveAsk;
begin
  if GAskTurn <> nil then GAskTurn.Enter;
end;

procedure EndInteractiveAsk;
begin
  if GAskTurn <> nil then GAskTurn.Leave;
end;

procedure RememberSessionAllow(const SessionKey, Tool, Resource: string);
begin
  GLock.Enter;
  try
    GAllows.Add(AllowKey(SessionKey, Tool, Resource));
  finally
    GLock.Leave;
  end;
end;

function SessionAllowed(const SessionKey, Tool, Resource: string): Boolean;
begin
  GLock.Enter;
  try
    Result := GAllows.IndexOf(AllowKey(SessionKey, Tool, Resource)) >= 0;
  finally
    GLock.Leave;
  end;
end;

procedure ForgetSessionAllows(const SessionKey: string);
var
  i: Integer;
  Prefix: string;
begin
  Prefix := SessionKey;
  if Prefix = '' then Prefix := 'default';
  Prefix := Prefix + '|';
  GLock.Enter;
  try
    for i := GAllows.Count - 1 downto 0 do
      if Copy(GAllows[i], 1, Length(Prefix)) = Prefix then GAllows.Delete(i);
  finally
    GLock.Leave;
  end;
end;

initialization
  GLock := TCriticalSection.Create;
  GAskTurn := TCriticalSection.Create;
  GAllows := TStringList.Create;
  GAllows.Sorted := True;
  GAllows.Duplicates := dupIgnore;
  SetLength(GRules, 0);
  SetLength(GPolicies, 0);
  GPolicyPath := '';
  GPolicyMtime := 0;
  GPolicySize := -1;
  GPolicyFails := 0;

finalization
  GAllows.Free;
  GLock.Free;
  { Nilled, not freed. A loop thread the TUI handed to FreeOnTerminate
    can still be on its way into BeginInteractiveAsk; Begin/End check for
    nil and do nothing, which is the right answer once the process is
    tearing down. }
  GAskTurn := nil;

end.
