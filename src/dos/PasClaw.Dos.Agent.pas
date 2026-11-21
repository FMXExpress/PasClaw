(*
  PasClaw.Dos.Agent -- the agent loop of the DOS client.

  The loop runs here, on the DOS PC; only the model call leaves it. Each
  step is one POST /v1/responses through the bridge, carrying the system
  prompt, the conversation so far and the tools (PasClaw.Dos.Tools). The
  gateway passes the tools through to the model and returns its tool
  calls unrun (Responses API "function" tools); they run here, and their
  outputs go back in the next step, until the model answers in text.

  Each request carries a sequence number the bridge echoes. A request
  whose answer is lost to line noise (CRC mismatch, a cut-off) is sent
  again, and an answer to an earlier try that arrives late is skipped by
  its number. The conversation is capped (HistoryCap bytes of JSON): the
  oldest turns go first, whole, so a tool call never loses its output.
*)
unit PasClaw.Dos.Agent;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.JSON,
  PasClaw.Bridge.Wire,
  PasClaw.Dos.Link;

type
  TDosAgentOptions = record
    Model: string;         { '' = the bridge's / gateway's default }
    MaxSteps: Integer;     { model calls per prompt }
    AutoYes: Boolean;      { run write/edit/run without asking }
    TimeoutSec: Integer;   { one model call, at most }
    HistoryCap: Integer;   { bytes of conversation JSON kept }
    Verbose: Boolean;      { show request sizes and timings }
  end;

  TDosAgent = class
  private
    FLink: TDosLink;
    FOpts: TDosAgentOptions;
    FSeq: Integer;
    FHistory: TStringList;   { one JSON input item per line }
    FAllowAll: Boolean;
    function SystemPrompt: string;
    function Ask(const Question: string): Boolean;
    function ItemIsUserMessage(const Json: string): Boolean;
  public
    procedure AddItem(const Json: string);
    { Keep the conversation under HistoryCap bytes: whole turns go first. }
    procedure TrimHistory;
    constructor Create(Link: TDosLink; const Opts: TDosAgentOptions);
    destructor Destroy; override;
    { One HTTP exchange with retries. False with Err when no answer came. }
    function Call(const Method, Path, Body: string; out Status: Integer;
      out Resp, Err: string): Boolean;
    { GET /v1/health: is the bridge there, and the gateway behind it. }
    function Health(out Info: string): Boolean;
    { One prompt, run to the model's final answer. False on an error. }
    function Turn(const UserText: string): Boolean;
    procedure Clear;
    property History: TStringList read FHistory;
  end;

function DefaultAgentOptions: TDosAgentOptions;

{ The error text of a gateway error body, or the body itself. }
function ErrorMessageOf(const Body: string): string;

{ JSON without the whitespace between tokens. }
function CompactJson(const S: string): string;

implementation

uses
  DateUtils,
  {$IFDEF GO32V2}Dos,{$ENDIF}
  PasClaw.Dos.Text,
  PasClaw.Dos.Tools;

function CompactJson(const S: string): string;
var
  i, N: Integer;
  InStr, Esc: Boolean;
  C: Char;
begin
  { The JSON writer pads ": " and ", "; on a serial line every byte is
    time. Drop whitespace outside strings. }
  SetLength(Result, Length(S));
  N := 0;
  InStr := False;
  Esc := False;
  for i := 1 to Length(S) do
  begin
    C := S[i];
    if InStr then
    begin
      if Esc then Esc := False
      else if C = '\' then Esc := True
      else if C = '"' then InStr := False;
    end
    else if C = '"' then InStr := True
    else if (C = ' ') or (C = #9) or (C = #10) or (C = #13) then Continue;
    Inc(N);
    Result[N] := C;
  end;
  SetLength(Result, N);
end;

{ The text of a "message" output item: its output_text parts. }
function MessageText(Item: TJsonObject): string;
var
  Content: TJsonArray;
  Part: TJsonObject;
  j: Integer;
begin
  Result := '';
  Content := Item.ChildArray('content');
  if Content = nil then Exit(Item.GetStr('content', ''));
  try
    for j := 0 to Content.Count - 1 do
    begin
      Part := Content.ItemObject(j);
      if Part = nil then Continue;
      try
        Result := Result + Part.GetStr('text', '');
      finally
        Part.Free;
      end;
    end;
  finally
    Content.Free;
  end;
end;

function AssistantItem(const Text: string): string;
var
  O: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    O.PutStr('type', 'message');
    O.PutStr('role', 'assistant');
    O.PutStr('content', Text);
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function DefaultAgentOptions: TDosAgentOptions;
begin
  Result.Model := '';
  Result.MaxSteps := 20;
  Result.AutoYes := False;
  Result.TimeoutSec := 300;
  Result.HistoryCap := 24000;
  Result.Verbose := False;
end;

function ErrorMessageOf(const Body: string): string;
var
  O, E: TJsonObject;
begin
  Result := Trim(Body);
  O := nil;
  try
    O := TJsonObject.Parse(Body);
  except
    O := nil;
  end;
  if O = nil then Exit;
  try
    E := O.ChildObject('error');
    if E <> nil then
    try
      Result := E.GetStr('message', Result);
    finally
      E.Free;
    end
    else if O.GetStr('error', '') <> '' then
      Result := O.GetStr('error', '');
  finally
    O.Free;
  end;
  if Length(Result) > 300 then Result := Copy(Result, 1, 300) + '...';
end;

constructor TDosAgent.Create(Link: TDosLink; const Opts: TDosAgentOptions);
begin
  inherited Create;
  FLink := Link;
  FOpts := Opts;
  FAllowAll := Opts.AutoYes;
  FHistory := TStringList.Create;
  { Not 1: an emulator keeps one connection across PCLAW runs, and an
    answer a cancelled run left on the line must not pass for this run's. }
  FSeq := Random(900000) + 1000;
end;

destructor TDosAgent.Destroy;
begin
  FHistory.Free;
  inherited Destroy;
end;

procedure TDosAgent.Clear;
begin
  FHistory.Clear;
end;

function TDosAgent.SystemPrompt: string;
var
  Where: string;
begin
  {$IFDEF GO32V2}
  Where := Format('an MS-DOS compatible PC (DOS %d.%d)', [Lo(DosVersion), Hi(DosVersion)]);
  {$ELSE}
  Where := 'a test machine standing in for a DOS PC (' + {$I %FPCTARGETOS%} + ')';
  {$ENDIF}
  Result :=
    'You are PasClaw, an assistant running on ' + Where + '. ' +
    'You reach the model over a serial line, and your tools act on this PC: ' +
    'read_file, list_dir, write_file, edit_file, run. ' +
    'The user confirms every write, edit and command. ' +
    {$IFDEF GO32V2}
    'Paths are DOS paths (C:\DIR\FILE.TXT): 8.3 names, case does not matter, backslashes. ' +
    'Commands run through COMMAND.COM: DOS built-ins (DIR, TYPE, COPY, DEL, MD, SET, VER, MEM) ' +
    'and programs on the PATH; there are no Unix tools, a command line holds 126 characters, ' +
    'and only standard output is captured. ' +
    {$ENDIF}
    'The current directory is ' + FromLocal(GetCurrentDir) + '. ' +
    'Today is ' + FormatDateTime('yyyy-mm-dd', Date) + '. ' +
    'The screen is 80 columns of plain text: answer briefly, no Markdown tables, ' +
    'no emoji; keep lines under 78 characters.';
end;

function TDosAgent.Ask(const Question: string): Boolean;
var
  Answer: string;
begin
  if FAllowAll then
  begin
    Say('  ' + Question + ' [yes: /YES]');
    Exit(True);
  end;
  SayRaw('  ' + Question + ' [y/N/a=all] ');
  if not ReadPromptLine(Answer) then Exit(False);
  Answer := LowerCase(Trim(Answer));
  if Answer = 'a' then
  begin
    FAllowAll := True;
    Exit(True);
  end;
  Result := (Answer = 'y') or (Answer = 'yes');
end;

function TDosAgent.Call(const Method, Path, Body: string; out Status: Integer;
  out Resp, Err: string): Boolean;
var
  Req, Ans: TWireMessage;
  Attempt, Skips: Integer;
  Wire: RawByteString;
  ReadErr: string;
  T0: TDateTime;
begin
  Result := False;
  Status := 0;
  Resp := '';
  Err := '';
  Inc(FSeq);
  Req.Method := Method;
  Req.Path := Path;
  Req.Status := 0;
  Req.Reason := '';
  SetLength(Req.Headers, 0);
  WireSetHeader(Req, 'Host', 'pasclaw-bridge');
  WireSetHeader(Req, 'User-Agent', 'PCLAW/1');
  WireSetHeader(Req, WIRE_SEQ_HEADER, IntToStr(FSeq));
  if Method = 'POST' then WireSetHeader(Req, 'Content-Type', 'application/json');
  Req.Body := StringToWireBody(Body);
  Wire := FormatWireRequest(Req);
  for Attempt := 1 to 3 do
  begin
    FLink.Drain(50);
    T0 := Now;
    if not FLink.WriteBytes(Wire) then
    begin
      Err := 'the line would not take the request (is the port right?)';
      Exit;
    end;
    Skips := 0;
    while True do
    begin
      if not ReadWireResponse(FLink, Ans, FOpts.TimeoutSec * 1000, 15000, ReadErr) then
      begin
        if FLink.Aborted then
        begin
          FLink.Aborted := False;
          Err := 'cancelled';
          Exit;
        end;
        if ReadErr = 'idle' then
        begin
          Err := Format('no answer within %d s -- is `pasclaw bridge` running, ' +
                        'on the same speed?', [FOpts.TimeoutSec]);
          Exit;
        end;
        Err := ReadErr;
        Break;   { a damaged answer: send again }
      end;
      if (WireHeader(Ans, WIRE_SEQ_HEADER) <> '') and
         (WireHeader(Ans, WIRE_SEQ_HEADER) <> IntToStr(FSeq)) then
      begin
        Inc(Skips);   { the answer to an earlier try }
        if Skips > 5 then
        begin
          Err := 'the line is out of step';
          Break;
        end;
        Continue;
      end;
      if (Ans.Status = 400) and (ErrorMessageOf(WireBodyToString(Ans.Body)) = 'crc') then
      begin
        Err := 'the request was damaged on the line';
        Break;   { the bridge asks for it again }
      end;
      Status := Ans.Status;
      Resp := WireBodyToString(Ans.Body);
      if FOpts.Verbose then
        Say(Format('  [%s %s: %d B up, %d B down, %d, %.1f s]',
          [Method, Path, Length(Wire), Length(Ans.Body), Status,
           MilliSecondsBetween(Now, T0) / 1000]));
      Exit(True);
    end;
    if Attempt < 3 then Say('  (' + Err + '; sending again)');
  end;
end;

function TDosAgent.Health(out Info: string): Boolean;
var
  Status: Integer;
  Resp, Err: string;
begin
  Info := '';
  Result := False;
  if not Call('GET', '/v1/health', '', Status, Resp, Err) then
  begin
    Info := Err;
    Exit;
  end;
  if Status <> 200 then
  begin
    Info := Format('%d %s', [Status, ErrorMessageOf(Resp)]);
    Exit;
  end;
  Info := 'gateway ' + JsonReadStr(Resp, 'version', '?');
  Result := True;
end;

procedure TDosAgent.AddItem(const Json: string);
begin
  FHistory.Add(CompactJson(Json));
end;

function TDosAgent.ItemIsUserMessage(const Json: string): Boolean;
var
  O: TJsonObject;
begin
  Result := False;
  O := TJsonObject.Parse(Json);
  if O = nil then Exit;
  try
    Result := (O.GetStr('type', 'message') = 'message') and (O.GetStr('role', '') = 'user');
  finally
    O.Free;
  end;
end;

procedure TDosAgent.TrimHistory;
var
  Total, i, Cut: Integer;
  O: TJsonObject;
begin
  Total := 0;
  for i := 0 to FHistory.Count - 1 do Inc(Total, Length(FHistory[i]) + 1);
  if Total <= FOpts.HistoryCap then Exit;
  { Drop whole turns from the front: up to the next user message. }
  Cut := 0;
  while (Total > FOpts.HistoryCap) and (Cut < FHistory.Count - 1) do
  begin
    i := Cut + 1;
    while (i < FHistory.Count) and not ItemIsUserMessage(FHistory[i]) do Inc(i);
    if i >= FHistory.Count then Break;   { the current turn: keep it }
    while Cut < i do
    begin
      Dec(Total, Length(FHistory[Cut]) + 1);
      Inc(Cut);
    end;
  end;
  for i := 1 to Cut do FHistory.Delete(0);
  { Still over: the current turn alone is too big. Shorten its older tool
    outputs, keeping the newest four whole. }
  if Total > FOpts.HistoryCap then
    for i := 0 to FHistory.Count - 5 do
    begin
      if Pos('"function_call_output"', FHistory[i]) = 0 then Continue;
      if Length(FHistory[i]) < 400 then Continue;
      O := TJsonObject.Parse(FHistory[i]);
      if O = nil then Continue;
      try
        O.PutStr('output', Copy(O.GetStr('output', ''), 1, 200) +
                           ' [... cut to keep the conversation small]');
        FHistory[i] := O.ToJSON;
      finally
        O.Free;
      end;
    end;
end;

function TDosAgent.Turn(const UserText: string): Boolean;
var
  Req, Item, OutItem: TJsonObject;
  Sys: TJsonObject;
  Status, Step, i, NCalls: Integer;
  Body, Resp, Err, Text, CallId, Name, Args, Output, ItemType, InputJson: string;
  OutArr: TJsonArray;
  IsErr: Boolean;
  Calls: TStringList;
begin
  Result := False;
  Item := TJsonObject.Create;
  try
    Item.PutStr('type', 'message');
    Item.PutStr('role', 'user');
    Item.PutStr('content', UserText);
    AddItem(Item.ToJSON);
  finally
    Item.Free;
  end;
  Calls := TStringList.Create;
  try
    for Step := 1 to FOpts.MaxSteps do
    begin
      TrimHistory;
      Sys := TJsonObject.Create;
      try
        Sys.PutStr('type', 'message');
        Sys.PutStr('role', 'system');
        Sys.PutStr('content', SystemPrompt);
        InputJson := '[' + CompactJson(Sys.ToJSON);
      finally
        Sys.Free;
      end;
      for i := 0 to FHistory.Count - 1 do InputJson := InputJson + ',' + FHistory[i];
      InputJson := InputJson + ']';
      Req := TJsonObject.Create;
      try
        if FOpts.Model <> '' then Req.PutStr('model', FOpts.Model);
        Req.PutBool('stream', False);
        Req.PutRaw('input', InputJson);
        Req.PutRaw('tools', DosToolsJSON);
        Body := CompactJson(Req.ToJSON);
      finally
        Req.Free;
      end;
      if ConsoleIsTTY then SayRaw('  ...' + #13);
      if not Call('POST', '/v1/responses', Body, Status, Resp, Err) then
      begin
        Say('! ' + Err);
        Exit;
      end;
      if ConsoleIsTTY then SayRaw('     ' + #13);
      if Status <> 200 then
      begin
        Say(Format('! the model call failed (%d): %s', [Status, ErrorMessageOf(Resp)]));
        Exit;
      end;
      Item := nil;
      try
        Item := TJsonObject.Parse(Resp);
      except
        Item := nil;
      end;
      if Item = nil then
      begin
        Say('! the answer is not JSON: ' + Copy(Resp, 1, 200));
        Exit;
      end;
      Calls.Clear;
      try
        OutArr := Item.ChildArray('output');
        if OutArr <> nil then
        try
          for i := 0 to OutArr.Count - 1 do
          begin
            OutItem := OutArr.ItemObject(i);
            if OutItem = nil then Continue;
            try
              ItemType := OutItem.GetStr('type', '');
              if ItemType = 'message' then
              begin
                Text := MessageText(OutItem);
                if Trim(Text) <> '' then
                begin
                  Say('');
                  Say(Trim(Text));
                  AddItem(AssistantItem(Text));
                end;
              end
              else if ItemType = 'function_call' then
              begin
                { Echo it back as it came, provider_signature and all: the
                  gateway needs it to replay the call to some providers. }
                OutItem.Remove('status');
                OutItem.Remove('id');
                AddItem(OutItem.ToJSON);
                Calls.Add(CompactJson(OutItem.ToJSON));
              end;
            finally
              OutItem.Free;
            end;
          end;
        finally
          OutArr.Free;
        end;
      finally
        Item.Free;
      end;

      NCalls := Calls.Count;
      if NCalls = 0 then Exit(True);
      for i := 0 to NCalls - 1 do
      begin
        Item := TJsonObject.Parse(Calls[i]);
        try
          CallId := Item.GetStr('call_id', '');
          Name := Item.GetStr('name', '');
          Args := Item.GetStr('arguments', '{}');
        finally
          Item.Free;
        end;
        Say('> ' + DescribeToolCall(Name, Args));
        Output := RunDosTool(Name, Args, Ask, IsErr);
        if IsErr then Say('  ! ' + Copy(StringReplace(Output, #10, ' ', [rfReplaceAll]), 1, 74))
        else Say(Format('  ok, %d bytes', [Length(Output)]));
        Item := TJsonObject.Create;
        try
          Item.PutStr('type', 'function_call_output');
          Item.PutStr('call_id', CallId);
          Item.PutStr('output', Output);
          AddItem(Item.ToJSON);
        finally
          Item.Free;
        end;
      end;
    end;
    Say(Format('! stopped after %d model calls; say "go on" to continue', [FOpts.MaxSteps]));
  finally
    Calls.Free;
  end;
end;

end.
