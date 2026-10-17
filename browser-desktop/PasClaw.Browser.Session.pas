(*
  PasClaw.Browser.Session - one tab's conversation.

  TPasClawAgent keeps nothing between calls: ChatHistory takes the whole
  transcript in and returns one reply. So the browser owns a history per
  tab and passes it in every turn. That is also what makes "each tab its
  own session" true rather than nominal -- the agent for a tab only ever
  sees that tab's history, and the page context stamped onto each user
  message is that tab's page.

  A session is user and assistant turns only. Tool calls and results happen
  INSIDE one ChatHistory call and do not need replaying; what the model
  needs next turn is what was asked and what was answered.

  Persisted as JSON under <home>/workspace/browser/<id>.json so a tab's
  conversation survives a restart. Written through WriteFileText and read
  through ReadFileText so the bytes are UTF-8 on both compilers -- the
  Delphi TStrings default is the system ANSI page, which is the bug the
  utf8-file-io lint exists to stop recurring.
*)
unit PasClaw.Browser.Session;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  PasClaw.Providers.Types;

type
  TBrowserSession = class
  private
    FId:      string;
    FURL:     string;
    FTitle:   string;
    FHistory: TMessageArray;
  public
    constructor Create(const AId: string);

    procedure AppendUser(const Text: string);
    procedure AppendAssistant(const Text: string);
    procedure Clear;

    { The transcript as the agent wants it. A copy, so a turn in flight
      is not disturbed by the UI appending to the live array. }
    function  HistoryCopy: TMessageArray;
    function  TurnCount: Integer;

    { JSON round-trip. LoadFromFile returns False and leaves the session
      empty when the file is missing or unreadable -- a fresh tab, not an
      error. SaveToFile creates the directory. }
    function  ToJSON: string;
    function  FromJSON(const S: string): Boolean;
    procedure SaveToFile(const Path: string);
    function  LoadFromFile(const Path: string): Boolean;

    property Id:    string read FId;
    property URL:   string read FURL   write FURL;
    property Title: string read FTitle write FTitle;
  end;

{ Where a session lives: <Home>/workspace/browser/<Id>.json. }
function SessionFilePath(const Home, Id: string): string;

{ A fresh id: 'tab-' + a timestamp + a counter, filesystem-safe. }
function NewBrowserSessionId: string;

implementation

uses
  SysUtils,
  PasClaw.JSON,
  PasClaw.Utils;

var
  GSeq: Integer = 0;

function NewBrowserSessionId: string;
begin
  Inc(GSeq);
  Result := 'tab-' + FormatDateTime('yyyymmdd"-"hhnnss', Now) + '-' + IntToStr(GSeq);
end;

function SessionFilePath(const Home, Id: string): string;
begin
  Result := JoinPath(JoinPath(JoinPath(Home, 'workspace'), 'browser'), Id + '.json');
end;

function RoleName(R: TMsgRole): string;
begin
  case R of
    mrSystem:    Result := 'system';
    mrUser:      Result := 'user';
    mrAssistant: Result := 'assistant';
  else           Result := 'tool';
  end;
end;

function RoleOf(const S: string): TMsgRole;
begin
  if S = 'assistant' then Result := mrAssistant
  else if S = 'system' then Result := mrSystem
  else if S = 'tool' then Result := mrTool
  else Result := mrUser;
end;

constructor TBrowserSession.Create(const AId: string);
begin
  inherited Create;
  FId := AId;
end;

procedure TBrowserSession.AppendUser(const Text: string);
var
  n: Integer;
begin
  n := Length(FHistory);
  SetLength(FHistory, n + 1);
  FHistory[n] := MakeMessage(mrUser, Text);
end;

procedure TBrowserSession.AppendAssistant(const Text: string);
var
  n: Integer;
begin
  n := Length(FHistory);
  SetLength(FHistory, n + 1);
  FHistory[n] := MakeMessage(mrAssistant, Text);
end;

procedure TBrowserSession.Clear;
begin
  SetLength(FHistory, 0);
end;

function TBrowserSession.HistoryCopy: TMessageArray;
var
  i: Integer;
begin
  Result := nil;
  SetLength(Result, Length(FHistory));
  for i := 0 to High(FHistory) do
    Result[i] := FHistory[i];
end;

function TBrowserSession.TurnCount: Integer;
begin
  Result := Length(FHistory);
end;

function TBrowserSession.ToJSON: string;
var
  Root, M: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('id', FId);
    Root.PutStr('url', FURL);
    Root.PutStr('title', FTitle);
    Arr := TJsonArray.Create;
    for i := 0 to High(FHistory) do
    begin
      M := TJsonObject.Create;
      M.PutStr('role', RoleName(FHistory[i].Role));
      M.PutStr('content', FHistory[i].Content);
      Arr.AddObject(M);
    end;
    Root.PutArray('messages', Arr);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function TBrowserSession.FromJSON(const S: string): Boolean;
var
  Root, M: TJsonObject;
  Arr: TJsonArray;
  i, n: Integer;
begin
  Result := False;
  Clear;
  Root := TJsonObject.Parse(S);
  if Root = nil then Exit;
  try
    if Root.GetStr('id', '') <> '' then FId := Root.GetStr('id', FId);
    FURL   := Root.GetStr('url', '');
    FTitle := Root.GetStr('title', '');
    Arr := Root.ChildArray('messages');
    if Arr <> nil then
    begin
      n := 0;
      SetLength(FHistory, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        M := Arr.ItemObject(i);
        if M = nil then Continue;
        FHistory[n] := MakeMessage(RoleOf(M.GetStr('role', 'user')),
                                   M.GetStr('content', ''));
        Inc(n);
      end;
      SetLength(FHistory, n);
    end;
    Result := True;
  finally
    Root.Free;
  end;
end;

procedure TBrowserSession.SaveToFile(const Path: string);
begin
  EnsureDir(ExtractFileDir(Path));
  WriteFileText(Path, ToJSON);
end;

function TBrowserSession.LoadFromFile(const Path: string): Boolean;
begin
  Result := False;
  { Clear FIRST. The contract is "False and empty" for a missing file, and
    a caller that reuses one session object across tabs must not inherit
    the previous tab's turns because the next tab had no file yet. }
  Clear;
  if not FileExists(Path) then Exit;
  try
    Result := FromJSON(ReadFileText(Path));
  except
    Result := False;
  end;
end;

end.
