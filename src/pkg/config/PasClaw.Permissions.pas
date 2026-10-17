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
  shell_exec / shell_background: command; execute_code: code; fs_* and the
  legacy read_file/write_file/edit_file family: path; web_fetch /
  memory_fetch: url; everything else: ''. Pure. }
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

{ Policies first; a policy deny is final. Then the config rules. }
function Decide(const Tool, Resource: string): TPermDecision;

{ "Allow for this session" memory, keyed by the loop's session key. }
procedure RememberSessionAllow(const SessionKey, Tool, Resource: string);
function  SessionAllowed(const SessionKey, Tool, Resource: string): Boolean;
procedure ForgetSessionAllows(const SessionKey: string);

implementation

uses
  PasClaw.Utils,   { ReadFileText }
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
var
  N: string;
begin
  N := LowerCase(ToolName);
  if (N = 'shell_exec') or (N = 'shell_background') then Result := ArgStr(ArgsJSON, 'command')
  else if N = 'execute_code' then Result := ArgStr(ArgsJSON, 'code')
  else if (N = 'web_fetch') or (N = 'memory_fetch') then Result := ArgStr(ArgsJSON, 'url')
  else if (Copy(N, 1, 3) = 'fs_') or (N = 'read_file') or (N = 'write_file') or
          (N = 'append_file') or (N = 'edit_file') or (N = 'list_dir') then
    Result := ArgStr(ArgsJSON, 'path')
  else
    Result := '';
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
              '(an "ask" rule matched) and no one is here to ask -- this session has ' +
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
  GAllows:      TStringList;   { "<session>|<tool>|<resource>" }

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

procedure ReadPoliciesLocked(const Path: string);
var
  Text, Inner: string;
  Obj: TJsonObject;
  Arr: TJsonArray;
begin
  SetLength(GPolicies, 0);
  if not FileExists(Path) then Exit;
  Text := Trim(ReadWholeFile(Path));
  if Text = '' then Exit;
  if Text[1] = '[' then
    GPolicies := ParsePermissionRules(Text, 'policy')
  else
  begin
    try
      Obj := TJsonObject.Parse(Text);
    except
      Obj := nil;
    end;
    if Obj = nil then Exit;
    try
      Arr := Obj.ChildArray('permissions');
      if Arr <> nil then
      try
        Inner := Arr.ToJSON;
      finally
        Arr.Free;
      end;
    finally
      Obj.Free;
    end;
    GPolicies := ParsePermissionRules(Inner, 'policy');
  end;
end;

procedure LoadPolicyFile(const Home: string);
var
  Mt: TDateTime;
begin
  GLock.Enter;
  try
    GPolicyPath := PolicyFilePath(Home);
    GPolicyMtime := 0;
    if FileAge(GPolicyPath, Mt) then GPolicyMtime := Mt;
    ReadPoliciesLocked(GPolicyPath);
  finally
    GLock.Leave;
  end;
end;

procedure RefreshPolicies;
var
  Mt: TDateTime;
begin
  GLock.Enter;
  try
    if GPolicyPath = '' then Exit;
    Mt := 0;
    if not FileAge(GPolicyPath, Mt) then Mt := 0;
    if Mt = GPolicyMtime then Exit;
    GPolicyMtime := Mt;
    ReadPoliciesLocked(GPolicyPath);
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
  GAllows := TStringList.Create;
  GAllows.Sorted := True;
  GAllows.Duplicates := dupIgnore;
  SetLength(GRules, 0);
  SetLength(GPolicies, 0);
  GPolicyPath := '';
  GPolicyMtime := 0;

finalization
  GAllows.Free;
  GLock.Free;

end.
