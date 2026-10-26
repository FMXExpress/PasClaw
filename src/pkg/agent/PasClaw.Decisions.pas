(*
  PasClaw.Decisions -- one queue for the operator's calls.

  A team runs on its own until it reaches something only a person can
  decide: spend money, pick between two designs, hand over a key. Before
  this, "report it to the operator" was prose in the lead's transcript,
  and nothing collected the questions. A decision is a file:

    workspace/decisions/D0012.json
      { id, kind, asked_by, question, choices[], project, task,
        task_status_before, status (open|answered), answer, answered_by,
        created, answered_at, payload }

  Created by the `agent` tool's ask_operator (docs/team-board-plan.md,
  Phase 3) -- only by the top of a reporting chain: an agent with a parent
  is routed to the parent instead, by the tool, not by the role prompt.
  Answered from the desktop's Needs-you window, over HTTP, or from a chat
  ("D12 yes") by a sender the operator named. Whatever answers it, the
  listeners registered here deliver the answer: the asker's mailbox, the
  task the question blocked, and -- for a proposed rule (Phase 4) -- the
  project's scenarios.

  Deliberately free of agent and gateway types, like PasClaw.Teams: the
  store decides nothing about who is told; listeners do.
*)
unit PasClaw.Decisions;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

interface

uses
  PasClaw.Utils;

type
  TDecisionInfo = record
    Id:        string;   { 'D0012' }
    Kind:      string;   { 'question' | 'rule' }
    AskedBy:   string;   { agent slug }
    Question:  string;
    Choices:   TStringArray;   { empty = free text }
    Project:   string;
    Task:      string;
    { The task's status when the question blocked it, so the answer can
      put it back where it was rather than guessing. }
    TaskStatusBefore: string;
    Status:    string;   { 'open' | 'answered' }
    Answer:    string;
    AnsweredBy: string;
    Created:   string;
    AnsweredAt: string;
    Payload:   string;   { kind-specific JSON object, '' when none }
    Exists:    Boolean;
  end;
  TDecisionInfoArray = array of TDecisionInfo;

  TDecisionListener = procedure(const D: TDecisionInfo);

function DecisionsDir: string;

{ 'D12', 'd0012', '12' -> 'D0012'; '' when it is not a decision id. }
function NormalizeDecisionId(const S: string): string;

function CreateDecision(const Kind, AskedBy, Question: string;
  const Choices: TStringArray; const Project, TaskId, TaskStatusBefore,
  Payload: string; out Err: string): string;
function GetDecision(const Id: string; out D: TDecisionInfo): Boolean;
{ Oldest first. }
function ListDecisions(OpenOnly: Boolean): TDecisionInfoArray;

(* Answer an open decision. With choices, the answer must be one of them
   (case-insensitive; the stored answer is the choice as written), because
   "yes, but" to a yes/no question is not an answer the asker can act on.
   An answered decision is refused, not re-answered: the asker may already
   have acted. AnsweredBy is 'operator' or a channel identity. *)
function AnswerDecision(const Id, Answer, AnsweredBy: string;
  out Err: string): Boolean;

{ Told on every create / answer. Listeners must not raise. }
procedure AddDecisionCreatedListener(L: TDecisionListener);
procedure AddDecisionAnsweredListener(L: TDecisionListener);

(* A chat message that answers a decision: "D12 yes", "d12: ship it",
   "D0012 - no". True with the id and answer when it is one. Pure. *)
function ParseDecisionReply(const Text: string; out Id, Answer: string): Boolean;

(* What a chat bot does with an inbound message before handing it to the
   model. True when the message was a decision reply -- answered, or
   refused -- with Reply the text to send back; False to carry on as an
   ordinary message. Sender is the canonical identity ("telegram:12345");
   AnswerFrom is decisions.answer_from. An empty AnswerFrom refuses every
   channel answer: allow_senders is no help, since an empty one lets
   anyone talk to the bot. *)
function HandleDecisionReply(const Text, Sender: string;
  const AnswerFrom: array of string; out Reply: string): Boolean;

{ The one-paragraph form a decision is announced and listed in. }
function DecisionSummary(const D: TDecisionInfo): string;

implementation

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.JSON,
  PasClaw.Workspaces,
  PasClaw.Desktop.Events;

var
  GLock: TCriticalSection = nil;
  GCreated, GAnswered: array of TDecisionListener;

function JoinStrings(const A: TStringArray; const Sep: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do
  begin
    if I > 0 then Result := Result + Sep;
    Result := Result + A[I];
  end;
end;

function DecisionsDir: string;
begin
  Result := WorkspacePath('decisions');
end;

function NormalizeDecisionId(const S: string): string;
var
  T: string;
  I, N: Integer;
begin
  Result := '';
  T := UpperCase(Trim(S));
  if (T <> '') and (T[1] = 'D') then T := Copy(T, 2, MaxInt);
  if (T = '') or (Length(T) > 9) then Exit;
  for I := 1 to Length(T) do
    if not (T[I] in ['0'..'9']) then Exit;
  N := StrToIntDef(T, 0);
  if N <= 0 then Exit;
  Result := 'D' + Format('%.4d', [N]);
end;

function DecisionPath(const Id: string): string;
var
  N: string;
begin
  Result := '';
  N := NormalizeDecisionId(Id);
  if N = '' then Exit;
  Result := JoinPath(DecisionsDir, N + '.json');
end;

function ReadDecision(const Path: string; out D: TDecisionInfo): Boolean;
var
  Obj, P: TJsonObject;
  Arr: TJsonArray;
  I: Integer;
begin
  Result := False;
  D := Default(TDecisionInfo);
  if not FileExists(Path) then Exit;
  Obj := nil;
  try
    Obj := TJsonObject.Parse(ReadFileText(Path));
  except
    Obj := nil;
  end;
  if Obj = nil then Exit;
  try
    D.Id         := Obj.GetStr('id', '');
    D.Kind       := Obj.GetStr('kind', 'question');
    D.AskedBy    := Obj.GetStr('asked_by', '');
    D.Question   := Obj.GetStr('question', '');
    D.Project    := Obj.GetStr('project', '');
    D.Task       := Obj.GetStr('task', '');
    D.TaskStatusBefore := Obj.GetStr('task_status_before', '');
    D.Status     := Obj.GetStr('status', 'open');
    D.Answer     := Obj.GetStr('answer', '');
    D.AnsweredBy := Obj.GetStr('answered_by', '');
    D.Created    := Obj.GetStr('created', '');
    D.AnsweredAt := Obj.GetStr('answered_at', '');
    Arr := Obj.ChildArray('choices');
    if Arr <> nil then
    try
      SetLength(D.Choices, Arr.Count);
      for I := 0 to Arr.Count - 1 do D.Choices[I] := Arr.ItemStr(I);
    finally
      Arr.Free;
    end;
    P := Obj.ChildObject('payload');
    if P <> nil then
    try
      D.Payload := P.ToJSON;
    finally
      P.Free;
    end;
    D.Exists := D.Id <> '';
    Result := D.Exists;
  finally
    Obj.Free;
  end;
end;

procedure WriteDecision(const D: TDecisionInfo);
var
  Obj: TJsonObject;
  Arr: TJsonArray;
  I: Integer;
begin
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('id', D.Id);
    Obj.PutStr('kind', D.Kind);
    Obj.PutStr('asked_by', D.AskedBy);
    Obj.PutStr('question', D.Question);
    Arr := TJsonArray.Create;
    for I := 0 to High(D.Choices) do Arr.AddStr(D.Choices[I]);
    Obj.PutArray('choices', Arr);
    Obj.PutStr('project', D.Project);
    Obj.PutStr('task', D.Task);
    Obj.PutStr('task_status_before', D.TaskStatusBefore);
    Obj.PutStr('status', D.Status);
    Obj.PutStr('answer', D.Answer);
    Obj.PutStr('answered_by', D.AnsweredBy);
    Obj.PutStr('created', D.Created);
    Obj.PutStr('answered_at', D.AnsweredAt);
    if Trim(D.Payload) <> '' then Obj.PutRaw('payload', D.Payload);
    EnsureDir(DecisionsDir);
    WriteFileText(DecisionPath(D.Id), Obj.ToJSON);
  finally
    Obj.Free;
  end;
end;

function DecisionNames: TStringList;
var
  Rec: TSearchRec;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  if not DirectoryExists(DecisionsDir) then Exit;
  if FindFirst(JoinPath(DecisionsDir, 'D*.json'), faAnyFile, Rec) = 0 then
  try
    repeat
      if (Rec.Attr and faDirectory) = 0 then
        Result.Add(ChangeFileExt(Rec.Name, ''));
    until FindNext(Rec) <> 0;
  finally
    FindClose(Rec);
  end;
end;

procedure Notify(const Listeners: array of TDecisionListener; const D: TDecisionInfo);
var
  I: Integer;
begin
  for I := 0 to High(Listeners) do
    try
      Listeners[I](D);
    except
      { a listener that fails must not undo the decision it was told about }
    end;
end;

procedure PublishDecision(const D: TDecisionInfo);
begin
  PublishRaw('{"type":"decision","id":"' + JsonEscape(D.Id) +
             '","status":"' + JsonEscape(D.Status) + '"}');
end;

function CreateDecision(const Kind, AskedBy, Question: string;
  const Choices: TStringArray; const Project, TaskId, TaskStatusBefore,
  Payload: string; out Err: string): string;
var
  D: TDecisionInfo;
  Names: TStringList;
  I, Max_, N: Integer;
begin
  Err := '';
  Result := '';
  if Trim(Question) = '' then
  begin
    Err := 'a decision needs a "question"';
    Exit;
  end;
  D := Default(TDecisionInfo);
  if Trim(Kind) = '' then D.Kind := 'question' else D.Kind := LowerCase(Trim(Kind));
  D.AskedBy := AskedBy;
  D.Question := Trim(Question);
  SetLength(D.Choices, 0);
  for I := 0 to High(Choices) do
    if Trim(Choices[I]) <> '' then
    begin
      SetLength(D.Choices, Length(D.Choices) + 1);
      D.Choices[High(D.Choices)] := Trim(Choices[I]);
    end;
  D.Project := Project;
  D.Task := UpperCase(TaskId);
  D.TaskStatusBefore := TaskStatusBefore;
  D.Status := 'open';
  D.Created := NowIsoUtc;
  D.Payload := Payload;
  (* Allocate and write under one lock: two agents asking at once must
     not be handed the same number -- the same lesson the task board's
     id allocation learned. *)
  GLock.Enter;
  try
    Names := DecisionNames;
    try
      Max_ := 0;
      for I := 0 to Names.Count - 1 do
      begin
        N := StrToIntDef(Copy(Names[I], 2, MaxInt), 0);
        if N > Max_ then Max_ := N;
      end;
    finally
      Names.Free;
    end;
    D.Id := 'D' + Format('%.4d', [Max_ + 1]);
    D.Exists := True;
    WriteDecision(D);
  finally
    GLock.Leave;
  end;
  PublishDecision(D);
  Notify(GCreated, D);
  Result := D.Id;
end;

function GetDecision(const Id: string; out D: TDecisionInfo): Boolean;
var
  Path: string;
begin
  D := Default(TDecisionInfo);
  Path := DecisionPath(Id);
  Result := (Path <> '') and ReadDecision(Path, D);
end;

function ListDecisions(OpenOnly: Boolean): TDecisionInfoArray;
var
  Names: TStringList;
  I, N: Integer;
  D: TDecisionInfo;
begin
  SetLength(Result, 0);
  Names := DecisionNames;
  try
    SetLength(Result, Names.Count);
    N := 0;
    for I := 0 to Names.Count - 1 do
      if ReadDecision(JoinPath(DecisionsDir, Names[I] + '.json'), D) and
         ((not OpenOnly) or (D.Status = 'open')) then
      begin
        Result[N] := D;
        Inc(N);
      end;
    SetLength(Result, N);
  finally
    Names.Free;
  end;
end;

function AnswerDecision(const Id, Answer, AnsweredBy: string;
  out Err: string): Boolean;
var
  D: TDecisionInfo;
  A, Choice: string;
  I: Integer;
begin
  Err := '';
  Result := False;
  A := Trim(Answer);
  if A = '' then
  begin
    Err := 'an answer cannot be empty';
    Exit;
  end;
  GLock.Enter;
  try
    if not GetDecision(Id, D) then
    begin
      Err := 'no such decision: ' + Id;
      Exit;
    end;
    if D.Status <> 'open' then
    begin
      Err := D.Id + ' was already answered (' + D.Answer + ', by ' +
             D.AnsweredBy + ') -- the asker may have acted on it';
      Exit;
    end;
    if Length(D.Choices) > 0 then
    begin
      Choice := '';
      for I := 0 to High(D.Choices) do
        if SameText(D.Choices[I], A) then Choice := D.Choices[I];
      if Choice = '' then
      begin
        Err := D.Id + ' asks for one of: ' + JoinStrings(D.Choices, ', ');
        Exit;
      end;
      A := Choice;
    end;
    D.Status := 'answered';
    D.Answer := A;
    D.AnsweredBy := AnsweredBy;
    D.AnsweredAt := NowIsoUtc;
    WriteDecision(D);
  finally
    GLock.Leave;
  end;
  PublishDecision(D);
  Notify(GAnswered, D);
  Result := True;
end;

procedure AddDecisionCreatedListener(L: TDecisionListener);
begin
  SetLength(GCreated, Length(GCreated) + 1);
  GCreated[High(GCreated)] := L;
end;

procedure AddDecisionAnsweredListener(L: TDecisionListener);
begin
  SetLength(GAnswered, Length(GAnswered) + 1);
  GAnswered[High(GAnswered)] := L;
end;

function ParseDecisionReply(const Text: string; out Id, Answer: string): Boolean;
var
  S, Digits: string;
  I: Integer;
begin
  Result := False;
  Id := '';
  Answer := '';
  S := Trim(Text);
  if (Length(S) < 3) or not ((S[1] = 'D') or (S[1] = 'd')) then Exit;
  I := 2;
  Digits := '';
  while (I <= Length(S)) and (S[I] in ['0'..'9']) do
  begin
    Digits := Digits + S[I];
    Inc(I);
  end;
  if Digits = '' then Exit;
  { "D12yes" is not a reply; the id has to end. }
  if (I <= Length(S)) and not (S[I] in [' ', ':', ',', '-', #9]) then Exit;
  while (I <= Length(S)) and (S[I] in [' ', ':', ',', '-', #9]) do Inc(I);
  Answer := Trim(Copy(S, I, MaxInt));
  if Answer = '' then Exit;
  Id := NormalizeDecisionId(Digits);
  Result := Id <> '';
end;

function HandleDecisionReply(const Text, Sender: string;
  const AnswerFrom: array of string; out Reply: string): Boolean;
var
  Id, Answer, Err: string;
  I: Integer;
  Allowed: Boolean;
  D: TDecisionInfo;
begin
  Reply := '';
  Result := ParseDecisionReply(Text, Id, Answer);
  if not Result then Exit;
  { Not a decision we have: an ordinary message that happens to start
    "D12" goes on to the model like any other. }
  if not GetDecision(Id, D) then Exit(False);
  Allowed := False;
  for I := 0 to High(AnswerFrom) do
    if (Trim(AnswerFrom[I]) <> '') and SameText(Trim(AnswerFrom[I]), Sender) then
      Allowed := True;
  if not Allowed then
  begin
    Reply := Id + ' was not answered: ' + Sender + ' is not in ' +
             'decisions.answer_from, and only the senders named there can ' +
             'answer the operator''s decisions from a chat.';
    Exit;
  end;
  if AnswerDecision(Id, Answer, Sender, Err) then
    Reply := 'Recorded ' + Id + ': ' + Answer + '. ' + D.AskedBy +
             ' has been told.'
  else
    Reply := Id + ' was not answered: ' + Err;
end;

function DecisionSummary(const D: TDecisionInfo): string;
begin
  Result := D.Id + ' from ' + D.AskedBy + ': ' + D.Question;
  if Length(D.Choices) > 0 then
    Result := Result + ' [' + JoinStrings(D.Choices, ' / ') + ']';
  if D.Task <> '' then
    Result := Result + ' (task ' + D.Task + ' on ' + D.Project + ')';
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  FreeAndNil(GLock);

end.
