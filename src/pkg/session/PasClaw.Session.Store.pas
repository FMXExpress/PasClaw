(*
  PasClaw.Session.Store — durable conversation sessions.

  Today `pasclaw agent` keeps its message history in process memory; a
  Ctrl-C / `/quit` / crash drops the whole conversation. Openclaw's
  /new / /reset / resume commands and nanobot's durable sessions
  treat each conversation as a persistent object you can come back to.

  Storage layout: one JSON file per session under
  $PASCLAW_HOME/workspace/sessions/<id>.json. The JSON carries
  everything RunToolLoop needs to continue the conversation —
  message history (user / assistant / tool with their tool_call
  pairings preserved), the compacted SystemPrompt override that
  PasClaw.Agent.Compact emits, the last provider/model the
  conversation ran against, an embedder-visible title, and
  created/updated timestamps for listing.

  ID shape: timestamp-prefix + 8 random hex chars (e.g.
  "20260601T134215-a3f4c2e1"). Sorts chronologically; readable by
  humans; collision-safe enough for a personal-agent home directory.

  Usage from Cmd.Agent.RunInteractive:

      Session := TSession.Create(A.Session);   { '' → new id }
      if Session.MetaExists then
        Session.Load(Session.Meta.Id)
      else
        Session.Save;                          { commit metadata }
      ... feed Session.Messages to the loop ...
      Session.Messages := Loop.FinalMessages;
      Session.Meta.SystemPromptOverride := Loop.FinalSystemPrompt;
      Session.Touch;
      Session.Save;

  Other call sites (cmd session list / show / delete, the gateway's
  read-only /v1/sessions endpoint) use ListSessions / SessionPath /
  DeleteSession without instantiating the class.
*)
unit PasClaw.Session.Store;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.JSON;

type
  TSessionMeta = record
    Id:                   string;     { 20260601T134215-a3f4c2e1 }
    CreatedAt:            Int64;      { unix seconds, UTC }
    UpdatedAt:            Int64;
    Title:                string;     { auto-derived from first user turn if empty }
    Model:                string;     { last model used }
    Provider:             string;     { last provider name }
    SystemPromptOverride: string;     { compacted system prompt across turns }
  end;
  TSessionMetaArray = array of TSessionMeta;

  TSession = class
  private
    FExists: Boolean;
  public
    Meta:     TSessionMeta;
    Messages: TMessageArray;
    { Create a session handle. When AId is empty, generates a new id
      and leaves FExists False — caller decides whether to persist
      via Save. When AId is non-empty, attempts to load the file;
      MetaExists reflects whether the load found anything. }
    constructor Create(const AId: string = '');
    function MetaExists: Boolean;
    procedure Save;
    procedure Load(const AId: string);
    { Refresh UpdatedAt to now. Doesn't write — caller decides when. }
    procedure Touch;
    { Empty Messages, keep Meta (id/title/etc.). Caller decides whether
      to persist. Doesn't reset SystemPromptOverride — embedders that
      want a hard reset should set it to '' explicitly. }
    procedure ClearMessages;
    { Derive a title from the first mrUser message when Meta.Title is
      empty. Idempotent — does nothing when Title is already set or
      Messages has no user turn. }
    procedure AutoTitle;
  end;

function NewSessionId: string;
{ True when Id is a safe filename component for a session file — see
  IsSafeSessionId in the implementation for the exact rules. Exposed
  so CLI callers (cmd/session, cmd/agent) can surface a clear error
  before invoking Save/Load/Delete with a hostile id. }
function IsSafeSessionId(const Id: string): Boolean;
function SessionsDir: string;
{ Returns '' when Id fails IsSafeSessionId, otherwise the absolute
  path of the session file. Callers MUST handle the empty-string
  case (treat as "no session named X"). }
function SessionPath(const Id: string): string;
function ListSessions: TSessionMetaArray;
function DeleteSession(const Id: string): Boolean;

(* Exposed for tests: TToolCall <-> JSON conversion used by TSession.
   Round-trip preserves Id, Kind, Func.Name, Func.Arguments, and
   (when non-empty) Gemini 3+'s ProviderSignature. *)
function ToolCallToJSON(const TC: TToolCall): TJsonObject;
procedure ToolCallFromJSON(const Obj: TJsonObject; out TC: TToolCall);

implementation

uses
  DateUtils,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Logger;

function NowUnix: Int64;
begin
  Result := DateTimeToUnix(Now, False);
end;

function NewSessionId: string;
var
  Stamp: string;
  Rand: string;
  i: Integer;
begin
  Stamp := FormatDateTime('yyyymmdd"T"hhnnss', Now);
  Rand := '';
  for i := 1 to 8 do
    Rand := Rand + IntToHex(Random(16), 1);
  Result := Stamp + '-' + LowerCase(Rand);
end;

{ A session id becomes a filename under workspace/sessions/, so we
  refuse anything that could escape the directory (`..`, `/`, `\`,
  NULs, leading `.`) or surprise the FS (overlong names). Allowed
  charset is the superset of NewSessionId's output plus the things a
  human is likely to want for hand-picked ids (`-`, `_`, `.` mid-name)
  — Codex P1 on PR #117. Keep this strict; widening the charset
  later is easy, narrowing it after files exist on disk is not. }
function IsSafeSessionId(const Id: string): Boolean;
var
  i: Integer;
  C: Char;
begin
  Result := False;
  if Id = '' then Exit;
  if Length(Id) > 128 then Exit;
  if (Id = '.') or (Id = '..') then Exit;
  if Id[1] = '.' then Exit;
  for i := 1 to Length(Id) do
  begin
    C := Id[i];
    if not (((C >= 'a') and (C <= 'z'))
         or ((C >= 'A') and (C <= 'Z'))
         or ((C >= '0') and (C <= '9'))
         or (C = '-') or (C = '_') or (C = '.')) then
      Exit;
  end;
  Result := True;
end;

function SessionsDir: string;
begin
  Result := JoinPath(GetHome, 'workspace/sessions');
end;

function SessionPath(const Id: string): string;
begin
  if not IsSafeSessionId(Id) then Exit('');
  Result := JoinPath(SessionsDir, Id + '.json');
end;

procedure EnsureSessionsDir;
begin
  if not DirectoryExists(SessionsDir) then
    ForceDirectories(SessionsDir);
end;

function ToolCallToJSON(const TC: TToolCall): TJsonObject;
var
  Func: TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr('id',   TC.Id);
  Result.PutStr('type', TC.Kind);
  Func := TJsonObject.Create;
  Func.PutStr('name',      TC.Func.Name);
  Func.PutStr('arguments', TC.Func.Arguments);
  Result.PutObject('function', Func);
  { Persist Gemini 3+'s thoughtSignature so a session saved mid-loop
    survives /quit + resume. Without this the resumed assistant turn
    drops the signature and Gemini's next request 400s with
    "Function call is missing a thought_signature". Omitted from
    JSON when empty — that's the common case (other providers / older
    Gemini) and keeps stock session files tidy. Codex P2 on PR #154. }
  if TC.ProviderSignature <> '' then
    Result.PutStr('provider_signature', TC.ProviderSignature);
end;

procedure ToolCallFromJSON(const Obj: TJsonObject; out TC: TToolCall);
var
  Func: TJsonObject;
begin
  TC.Id   := Obj.GetStr('id',   '');
  TC.Kind := Obj.GetStr('type', 'function');
  TC.ProviderSignature := Obj.GetStr('provider_signature', '');
  TC.Func.Name      := '';
  TC.Func.Arguments := '';
  Func := Obj.ChildObject('function');
  if Func <> nil then
  try
    TC.Func.Name      := Func.GetStr('name',      '');
    TC.Func.Arguments := Func.GetStr('arguments', '');
  finally
    Func.Free;
  end;
end;

function MessageToJSON(const M: TMessage): TJsonObject;
var
  Arr: TJsonArray;
  TCO: TJsonObject;
  i: Integer;
begin
  Result := TJsonObject.Create;
  Result.PutStr('role',    MsgRoleToString(M.Role));
  Result.PutStr('content', M.Content);
  if M.Name <> ''       then Result.PutStr('name',         M.Name);
  if M.ToolCallId <> '' then Result.PutStr('tool_call_id', M.ToolCallId);
  if Length(M.ToolCalls) > 0 then
  begin
    Arr := TJsonArray.Create;
    for i := 0 to High(M.ToolCalls) do
    begin
      TCO := ToolCallToJSON(M.ToolCalls[i]);
      Arr.AddObject(TCO);
    end;
    Result.PutArray('tool_calls', Arr);
  end;
end;

procedure MessageFromJSON(const Obj: TJsonObject; out M: TMessage);
var
  Arr: TJsonArray;
  TCO: TJsonObject;
  i: Integer;
begin
  M.Role       := MsgRoleFromString(Obj.GetStr('role', 'user'));
  M.Content    := Obj.GetStr('content',      '');
  M.Name       := Obj.GetStr('name',         '');
  M.ToolCallId := Obj.GetStr('tool_call_id', '');
  SetLength(M.ToolCalls, 0);
  Arr := Obj.ChildArray('tool_calls');
  if Arr <> nil then
  try
    SetLength(M.ToolCalls, Arr.Count);
    for i := 0 to Arr.Count - 1 do
    begin
      TCO := Arr.ItemObject(i);
      if TCO = nil then Continue;
      try
        ToolCallFromJSON(TCO, M.ToolCalls[i]);
      finally
        TCO.Free;
      end;
    end;
  finally
    Arr.Free;
  end;
end;

constructor TSession.Create(const AId: string);
begin
  inherited Create;
  if AId = '' then
  begin
    Meta.Id        := NewSessionId;
    Meta.CreatedAt := NowUnix;
    Meta.UpdatedAt := Meta.CreatedAt;
    FExists := False;
    SetLength(Messages, 0);
  end
  else
    Load(AId);
end;

function TSession.MetaExists: Boolean;
begin
  Result := FExists;
end;

procedure TSession.Save;
var
  Root, MetaObj, MsgObj: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
  S: TStringList;
  Path, TmpPath: string;
begin
  Path := SessionPath(Meta.Id);
  if Path = '' then
    raise EArgumentException.CreateFmt('Session.Save: unsafe id %s', [Meta.Id]);
  EnsureSessionsDir;
  Root := TJsonObject.Create;
  try
    MetaObj := TJsonObject.Create;
    MetaObj.PutStr('id',                     Meta.Id);
    MetaObj.PutInt('created_at',             Meta.CreatedAt);
    MetaObj.PutInt('updated_at',             Meta.UpdatedAt);
    MetaObj.PutStr('title',                  Meta.Title);
    MetaObj.PutStr('model',                  Meta.Model);
    MetaObj.PutStr('provider',               Meta.Provider);
    MetaObj.PutStr('system_prompt_override', Meta.SystemPromptOverride);
    Root.PutObject('meta', MetaObj);

    Arr := TJsonArray.Create;
    for i := 0 to High(Messages) do
    begin
      MsgObj := MessageToJSON(Messages[i]);
      Arr.AddObject(MsgObj);   { takes ownership; sets MsgObj := nil }
    end;
    Root.PutArray('messages', Arr);

    { Atomic write: tmp file + rename. A crash partway through
      SaveToFile would otherwise leave a half-written JSON that Load
      can't parse, defeating the "your conversation survives Ctrl-C"
      promise. POSIX rename(2) is atomic and overwrites; Windows
      MoveFile requires the destination not exist — delete first.
      Codex P2 on PR #117. }
    TmpPath := Path + '.tmp';
    S := TStringList.Create;
    try
      S.Text := Root.ToJSON;
      S.SaveToFile(TmpPath);
    finally
      S.Free;
    end;
    {$IFDEF MSWINDOWS}
    if FileExists(Path) then SysUtils.DeleteFile(Path);
    {$ENDIF}
    if not RenameFile(TmpPath, Path) then
    begin
      SysUtils.DeleteFile(TmpPath);
      raise Exception.CreateFmt('Session.Save: rename %s -> %s failed', [TmpPath, Path]);
    end;
    FExists := True;
  finally
    Root.Free;
  end;
end;

procedure TSession.Load(const AId: string);
var
  Path: string;
  S: TStringList;
  Root, MetaObj, MsgObj: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  FExists := False;
  SetLength(Messages, 0);
  Meta := Default(TSessionMeta);
  Meta.Id := AId;
  Path := SessionPath(AId);
  if Path = '' then Exit;          { unsafe id — treat as not found }
  if not FileExists(Path) then Exit;

  S := TStringList.Create;
  try
    S.LoadFromFile(Path);
    Root := TJsonObject.Parse(S.Text);
    if Root = nil then Exit;
    try
      MetaObj := Root.ChildObject('meta');
      if MetaObj <> nil then
      try
        Meta.Id                   := MetaObj.GetStr('id',                     AId);
        Meta.CreatedAt            := MetaObj.GetInt('created_at',             0);
        Meta.UpdatedAt            := MetaObj.GetInt('updated_at',             0);
        Meta.Title                := MetaObj.GetStr('title',                  '');
        Meta.Model                := MetaObj.GetStr('model',                  '');
        Meta.Provider             := MetaObj.GetStr('provider',               '');
        Meta.SystemPromptOverride := MetaObj.GetStr('system_prompt_override', '');
      finally
        MetaObj.Free;
      end;
      Arr := Root.ChildArray('messages');
      if Arr <> nil then
      try
        SetLength(Messages, Arr.Count);
        for i := 0 to Arr.Count - 1 do
        begin
          MsgObj := Arr.ItemObject(i);
          if MsgObj = nil then Continue;
          try
            MessageFromJSON(MsgObj, Messages[i]);
          finally
            MsgObj.Free;
          end;
        end;
      finally
        Arr.Free;
      end;
      FExists := True;
    finally
      Root.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TSession.Touch;
begin
  Meta.UpdatedAt := NowUnix;
end;

procedure TSession.ClearMessages;
begin
  SetLength(Messages, 0);
end;

procedure TSession.AutoTitle;
var
  i: Integer;
  Line: string;
const
  MaxTitleLen = 72;
begin
  if Trim(Meta.Title) <> '' then Exit;
  for i := 0 to High(Messages) do
    if Messages[i].Role = mrUser then
    begin
      Line := Trim(Messages[i].Content);
      if Length(Line) > MaxTitleLen then
        Line := Copy(Line, 1, MaxTitleLen - 1) + '…';
      Meta.Title := Line;
      Exit;
    end;
end;

function ListSessions: TSessionMetaArray;
var
  SR: TSearchRec;
  Pattern, Id: string;
  TmpSess: TSession;
begin
  SetLength(Result, 0);
  Pattern := JoinPath(SessionsDir, '*.json');
  if FindFirst(Pattern, faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      Id := ChangeFileExt(SR.Name, '');
      { Skip stray files (.tmp leftovers from a crashed Save, or
        anything a human dropped in here) — only ids that round-trip
        through IsSafeSessionId are real sessions. }
      if not IsSafeSessionId(Id) then Continue;
      { Load only the meta; this is wasteful but the sessions tree is
        typically small (10s to low 100s) and ListSessions runs from
        an interactive command. If it grows: write a "headers only"
        Load. }
      TmpSess := TSession.Create(Id);
      try
        if TmpSess.MetaExists then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := TmpSess.Meta;
        end;
      finally
        TmpSess.Free;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function DeleteSession(const Id: string): Boolean;
var
  Path: string;
begin
  Result := False;
  Path := SessionPath(Id);
  if Path = '' then Exit;                 { unsafe id }
  if not FileExists(Path) then Exit;
  Result := DeleteFile(Path);
  if Result then
    LogInfo('session %s deleted', [Id]);
end;

initialization
  Randomize;

end.
