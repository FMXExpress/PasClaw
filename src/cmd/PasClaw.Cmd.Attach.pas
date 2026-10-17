(*
  PasClaw.Cmd.Attach -- the terminal as a client of a running gateway.

  `pasclaw agent` and `pasclaw tui` run their own tool loop against the
  session files. When a gateway is already up -- serving the web UI, the
  desktop, a channel -- a second loop in another process means two
  writers on one session store with no lock between them, and a terminal
  that cannot see the turn the browser started. OpenCode's answer is one
  service and clients; this is PasClaw's version of it, without a
  rewrite: when asked (--attach, or cli.attach in config) and a live
  gateway is found through <home>/run/gateway.json, the terminal sends
  each line as one turn through /v1/chat/completions with
  X-PasClaw-Session and session_context, so the gateway holds the
  transcript and the turn lock, and renders the stream and the tool
  frames as they arrive. Session list, new, resume and delete go through
  /v1/sessions. Nothing runs locally: no provider, no registry, no shell
  backend.

  v1 shows a turn's text as it streams and the tool calls as one-line
  traces. Watching a turn another surface started is a later step (an
  SSE feed per session); until then the gateway's reply for that turn is
  simply not in this terminal.
*)
unit PasClaw.Cmd.Attach;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  PasClaw.Config;

{ Should this run attach? Explicit = --attach was given. Mode comes from
  Cfg.Cli.Attach. True => URL is the gateway to use (Warn may carry a
  one-line caution, e.g. the token hash differs). False with Fail=True =>
  attaching was required and no gateway is running (Reason says so, the
  caller should exit non-zero). False with Fail=False => run locally. }
function ResolveAttach(const Cfg: TConfig; Explicit: Boolean;
                       out URL, Reason, Warn: string; out Fail: Boolean): Boolean;

{ The attached REPL (or one attached turn when Message is non-empty).
  SessionId '' creates a session on the gateway. Returns the exit code. }
function RunAttached(const Cfg: TConfig; const URL, SessionId, Message: string;
                     Quiet: Boolean): Integer;

implementation

uses
  SysUtils, Classes, DateUtils,
  PasClaw.CliUI,
  PasClaw.JSON,
  PasClaw.Gateway.RunFile,
  PasClaw.Client.Api;

function ResolveAttach(const Cfg: TConfig; Explicit: Boolean;
                       out URL, Reason, Warn: string; out Fail: Boolean): Boolean;
var
  Mode: string;
  Info: TGatewayRunInfo;
  Want: Boolean;
begin
  Result := False;
  URL := '';
  Reason := '';
  Warn := '';
  Fail := False;
  Mode := LowerCase(Trim(Cfg.Cli.Attach));
  Want := Explicit or (Mode = 'on') or (Mode = 'auto');
  if not Want then Exit;
  if ReadGatewayRunFile(GetHome, Info) then
  begin
    URL := GatewayBaseURL(Info);
    if (Info.TokenHash <> '') and (Info.TokenHash <> TokenHashHex(Cfg.Gateway.Token)) then
      Warn := 'the running gateway was started with a different gateway.token than this ' +
              'config has; requests will be refused with 401 unless the tokens match'
    else if (Info.TokenHash = '') and (Cfg.Gateway.Token <> '') then
      Warn := 'the running gateway has no token; this config''s gateway.token is unused';
    Exit(True);
  end;
  Fail := Explicit or (Mode = 'on');
  Reason := 'no running gateway found (' + GatewayRunFilePath(GetHome) +
            ' is missing or names a dead process) -- start `pasclaw gateway` first';
end;

type
  TPrinter = class
  public
    Quiet: Boolean;
    Printed: Boolean;
    procedure Chunk(const Chunk: string; var Abort: Boolean);
    procedure ToolTrace(const Kind, Name, Detail: string; IsErr: Boolean);
  end;

procedure TPrinter.Chunk(const Chunk: string; var Abort: Boolean);
begin
  Abort := False;
  if Chunk = '' then Exit;
  Print(Chunk);
  Printed := True;
end;

procedure TPrinter.ToolTrace(const Kind, Name, Detail: string; IsErr: Boolean);
var
  D: string;
begin
  if Quiet then Exit;
  D := StringReplace(Trim(Detail), sLineBreak, ' ', [rfReplaceAll]);
  D := StringReplace(D, #10, ' ', [rfReplaceAll]);
  if Length(D) > 110 then D := Copy(D, 1, 107) + '...';
  if IsErr then
    PrintLn(Ansi.Red + '  [' + Kind + '] ' + Name + Ansi.Reset + ' ' + Ansi.Dim + D + Ansi.Reset)
  else
    PrintLn(Ansi.Dim + '  [' + Kind + '] ' + Name + ' ' + D + Ansi.Reset);
end;

function IfThenStr(Cond: Boolean; const S: string): string;
begin
  if Cond then Result := S else Result := '';
end;

function Age(Unix: Int64): string;
var
  S: Int64;
begin
  if Unix <= 0 then Exit('');
  S := DateTimeToUnix(Now, False) - Unix;
  if S < 90 then Result := IntToStr(S) + 's'
  else if S < 5400 then Result := IntToStr(S div 60) + 'm'
  else if S < 172800 then Result := IntToStr(S div 3600) + 'h'
  else Result := IntToStr(S div 86400) + 'd';
end;

function RunAttached(const Cfg: TConfig; const URL, SessionId, Message: string;
                     Quiet: Boolean): Integer;
var
  Client: TPasClawClient;
  Printer: TPrinter;
  Ver, Sid, Line, Arg: string;
  Rows: TSessionRows;
  i: Integer;

  procedure Turn(const Text: string);
  var
    Hist: TJsonArray;
    M: TJsonObject;
    Reply: string;
  begin
    Hist := TJsonArray.Create;
    try
      M := TJsonObject.Create;
      M.PutStr('role', 'user');
      M.PutStr('content', Text);
      Hist.AddObject(M);
      Printer.Printed := False;
      if not Quiet then Print(Ansi.BoldBlue + 'pasclaw' + Ansi.Reset + '  > ');
      Reply := Client.Chat(Hist.ToJSON, '', Printer.Chunk, Printer.ToolTrace);
      { Chunks already went to the terminal; a reply that never streamed
        (a non-streaming gateway, or one that answered in one piece) is
        printed whole. }
      if (not Printer.Printed) and (Reply <> '') then Print(Reply);
      PrintLn('');
      if Client.LastError <> '' then
        PrintLn(Ansi.Red + 'error: ' + Ansi.Reset + Client.LastError);
    finally
      Hist.Free;
    end;
  end;

  function NewSession: Boolean;
  begin
    Sid := Client.CreateSession('');
    Result := Sid <> '';
    if Result then
    begin
      Client.SessionId := Sid;
      if not Quiet then
        PrintLn(Ansi.Dim + '(new session ' + Sid + ' on the gateway)' + Ansi.Reset);
    end
    else
      PrintLn(Ansi.Red + 'error: ' + Ansi.Reset + 'the gateway did not create a session: ' + Client.LastError);
  end;

begin
  Result := 0;
  Client := TPasClawClient.Create(URL);
  Printer := TPrinter.Create;
  try
    Printer.Quiet := Quiet;
    Client.Token := Cfg.Gateway.Token;
    Client.SessionContext := True;   { the gateway merges its stored transcript }
    if not Client.Ping(Ver) then
    begin
      PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'no gateway answering at ' + URL);
      Exit(1);
    end;
    Sid := Trim(SessionId);
    if Sid = '' then
    begin
      if not NewSession then Exit(1);
    end
    else
      Client.SessionId := Sid;
    if not Quiet then
      PrintLn(Ansi.Dim + '(attached to ' + URL + ', pasclaw ' + Ver + ', session ' + Sid +
              ' -- the gateway holds the transcript; /sessions /new /resume <id> /delete <id> /quit)' +
              Ansi.Reset);

    if Message <> '' then
    begin
      Turn(Message);
      if Client.LastError <> '' then Result := 1;
      Exit;
    end;

    while True do
    begin
      Print(Ansi.Bold + '> ' + Ansi.Reset);
      if EOF then Break;
      ReadLn(Line);
      Line := Trim(Line);
      if Line = '' then Continue;
      if (Line = '/quit') or (Line = '/exit') or (Line = '/q') then Break;
      if Line = '/new' then
      begin
        NewSession;
        Continue;
      end;
      if Line = '/sessions' then
      begin
        try
          Rows := Client.Sessions;
        except
          on E: Exception do
          begin
            PrintLn(Ansi.Red + 'error: ' + Ansi.Reset + E.Message);
            Continue;
          end;
        end;
        if Length(Rows) = 0 then PrintLn(Ansi.Dim + '(no sessions on the gateway)' + Ansi.Reset);
        for i := 0 to High(Rows) do
          PrintLn(Format('  %-28s %5s  %s%s', [Rows[i].Id, Age(Rows[i].Updated), Rows[i].Title,
                  IfThenStr(Rows[i].Id = Sid, '  ' + Ansi.Dim + '(current)' + Ansi.Reset)]));
        Continue;
      end;
      if Copy(Line, 1, 8) = '/resume ' then
      begin
        Arg := Trim(Copy(Line, 9, MaxInt));
        if Arg = '' then begin PrintLn('usage: /resume <session-id>'); Continue; end;
        Sid := Arg;
        Client.SessionId := Sid;
        if not Quiet then PrintLn(Ansi.Dim + '(now on session ' + Sid + ')' + Ansi.Reset);
        Continue;
      end;
      if Copy(Line, 1, 8) = '/delete ' then
      begin
        Arg := Trim(Copy(Line, 9, MaxInt));
        if Arg = '' then begin PrintLn('usage: /delete <session-id>'); Continue; end;
        if Client.DeleteSession(Arg) then
        begin
          PrintLn(Ansi.Dim + '(deleted ' + Arg + ')' + Ansi.Reset);
          if Arg = Sid then NewSession;
        end
        else
          PrintLn(Ansi.Red + 'error: ' + Ansi.Reset + 'delete failed: ' + Client.LastError);
        Continue;
      end;
      if Line[1] = '/' then
      begin
        PrintLn(Ansi.Dim + 'attached mode knows /sessions /new /resume <id> /delete <id> /quit; ' +
                'other slash commands run on the gateway side' + Ansi.Reset);
        Continue;
      end;
      Turn(Line);
    end;
  finally
    Printer.Free;
    Client.Free;
  end;
end;

end.
