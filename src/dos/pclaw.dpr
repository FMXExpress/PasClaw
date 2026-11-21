(*
  PCLAW -- the PasClaw client for DOS.

  An agent that runs on an MS-DOS PC (386+ with an FPU-free path, 4 MB,
  CWSDPMI.EXE beside it) and reaches the model through `pasclaw bridge`
  on a modern machine over a serial line. See docs/dos.md.

    PCLAW                       talk to it
    PCLAW /P:"what is in C:\"   one request, then exit
    PCLAW /F:TASK.TXT           one request read from a file
    PCLAW /PORT:COM2 /BAUD:38400 /MODEL:name /YES /STEPS:20 /TIMEOUT:300 /V

  Settings also come from PCLAW.CFG (KEY=VALUE lines: PORT, BAUD, MODEL,
  STEPS, TIMEOUT, HISTORY, YES) in the current directory or beside
  PCLAW.EXE; switches win. Built for go32v2 by `make dos`; a host build
  (`make dos-host`, Linux) talks TCP to the bridge for testing.

  Exit codes: 0 done, 1 the request failed, 2 no bridge / gateway, 3 usage.
*)
program pclaw;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils, Classes,
  PasClaw.Bridge.Wire,
  PasClaw.Dos.Text,
  PasClaw.Dos.Link,
  PasClaw.Dos.Tools,
  PasClaw.Dos.Agent;

type
  TArgs = record
    Port: string;
    Baud: Integer;
    Prompt: string;
    PromptFile: string;
    Opts: TDosAgentOptions;
  end;

procedure Usage;
begin
  Say('PCLAW -- PasClaw for DOS, over a serial line to `pasclaw bridge`');
  Say('');
  Say('  PCLAW [/PORT:COM1] [/BAUD:115200] [/MODEL:name] [/YES] [/V]');
  Say('        [/STEPS:20] [/TIMEOUT:300] [/HISTORY:24000] [/P:text | /F:file]');
  Say('');
  Say('  /PORT     COM1..COM4 (host builds: host:port of the bridge, or /dev/...)');
  Say('  /BAUD     300..115200; the bridge must use the same');
  Say('  /MODEL    a model the gateway knows (default: its own)');
  Say('  /YES      write, edit and run without asking');
  Say('  /P /F     one request (text, or a file holding it), then exit');
  Say('  /V        show each request''s size and time');
  Say('');
  Say('Settings can also go in PCLAW.CFG as KEY=VALUE lines.');
end;

{ "/KEY:VALUE", "/KEY=VALUE", "-KEY VALUE" / "--key value", "/FLAG". }
function SplitSwitch(const A: string; out Key, Value: string; out HasValue: Boolean): Boolean;
var
  S: string;
  P: Integer;
begin
  Result := False;
  Key := '';
  Value := '';
  HasValue := False;
  if (A = '') or not ((A[1] = '/') or (A[1] = '-')) then Exit;
  S := A;
  while (S <> '') and ((S[1] = '/') or (S[1] = '-')) do Delete(S, 1, 1);
  P := Pos(':', S);
  if (P = 0) or ((Pos('=', S) > 0) and (Pos('=', S) < P)) then P := Pos('=', S);
  if P > 0 then
  begin
    Key := UpperCase(Copy(S, 1, P - 1));
    Value := Copy(S, P + 1, MaxInt);
    HasValue := True;
  end
  else
    Key := UpperCase(S);
  Result := Key <> '';
end;

function Unquote(const S: string): string;
begin
  Result := S;
  if (Length(Result) >= 2) and (Result[1] = '"') and (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

{ Apply one setting. False when the key is unknown or the value bad. }
function Apply(var A: TArgs; const Key, Value: string; out Err: string): Boolean;
var
  N: Integer;
begin
  Result := True;
  Err := '';
  N := StrToIntDef(Value, -1);
  if Key = 'PORT' then A.Port := Value
  else if Key = 'BAUD' then
  begin
    if not BaudSupported(N) then begin Err := 'BAUD must be 300..115200'; Exit(False); end;
    A.Baud := N;
  end
  else if Key = 'MODEL' then A.Opts.Model := FromLocal(Value)
  else if (Key = 'YES') or (Key = 'Y') then A.Opts.AutoYes := (Value = '') or (Value = '1') or SameText(Value, 'yes') or SameText(Value, 'on')
  else if (Key = 'V') or (Key = 'VERBOSE') then A.Opts.Verbose := True
  else if Key = 'STEPS' then
  begin
    if N < 1 then begin Err := 'STEPS must be a number'; Exit(False); end;
    A.Opts.MaxSteps := N;
  end
  else if Key = 'TIMEOUT' then
  begin
    if N < 5 then begin Err := 'TIMEOUT must be at least 5 (seconds)'; Exit(False); end;
    A.Opts.TimeoutSec := N;
  end
  else if Key = 'HISTORY' then
  begin
    if N < 2000 then begin Err := 'HISTORY must be at least 2000 (bytes)'; Exit(False); end;
    A.Opts.HistoryCap := N;
  end
  else if (Key = 'P') or (Key = 'PROMPT') then A.Prompt := FromLocal(Unquote(Value))
  else if (Key = 'F') or (Key = 'FILE') then A.PromptFile := FromLocal(Value)
  else
  begin
    Err := 'unknown setting ' + Key;
    Result := False;
  end;
end;

procedure LoadCfg(var A: TArgs);
var
  Path, Raw, Err, Line, Key, Value: string;
  L: TStringList;
  i, P: Integer;
begin
  Path := 'PCLAW.CFG';
  if not FileExists(Path) then
    Path := ExtractFilePath(ParamStr(0)) + 'PCLAW.CFG';
  if not FileExists(Path) then Exit;
  if not ReadFileBytes(Path, Raw, Err) then Exit;
  L := TStringList.Create;
  try
    L.Text := FileTextToUtf8(Raw);
    for i := 0 to L.Count - 1 do
    begin
      Line := Trim(L[i]);
      if (Line = '') or (Line[1] = ';') or (Line[1] = '#') then Continue;
      P := Pos('=', Line);
      if P = 0 then Continue;
      Key := UpperCase(Trim(Copy(Line, 1, P - 1)));
      Value := Trim(Copy(Line, P + 1, MaxInt));
      if (Key = 'P') or (Key = 'PROMPT') or (Key = 'F') or (Key = 'FILE') then Continue;
      if not Apply(A, Key, ToLocal(Value), Err) then
        Say('PCLAW.CFG: ' + Err);
    end;
  finally
    L.Free;
  end;
end;

function ParseArgs(var A: TArgs): Integer;
var
  i: Integer;
  Arg, Key, Value, Err: string;
  HasValue: Boolean;
begin
  Result := -1;
  i := 1;
  while i <= ParamCount do
  begin
    Arg := ParamStr(i);
    if not SplitSwitch(Arg, Key, Value, HasValue) then
    begin
      { Bare words: the prompt. }
      if A.Prompt = '' then A.Prompt := FromLocal(Arg)
      else A.Prompt := A.Prompt + ' ' + FromLocal(Arg);
      Inc(i);
      Continue;
    end;
    if (Key = '?') or (Key = 'H') or (Key = 'HELP') then
    begin
      Usage;
      Exit(0);
    end;
    if (not HasValue) and (i < ParamCount) and
       ((Key = 'PORT') or (Key = 'BAUD') or (Key = 'MODEL') or (Key = 'STEPS') or
        (Key = 'TIMEOUT') or (Key = 'HISTORY') or (Key = 'P') or (Key = 'PROMPT') or
        (Key = 'F') or (Key = 'FILE')) then
    begin
      Inc(i);
      Value := ParamStr(i);
    end;
    if not Apply(A, Key, Value, Err) then
    begin
      Say('PCLAW: ' + Err + ' (PCLAW /? lists the switches)');
      Exit(3);
    end;
    Inc(i);
  end;
end;

function Main: Integer;
var
  A: TArgs;
  Link: TDosLink;
  Agent: TDosAgent;
  Err, Info, Line, Raw: string;
  Code: Integer;
begin
  InitDosText;
  Randomize;
  {$IFDEF GO32V2}
  A.Port := 'COM1';
  {$ELSE}
  A.Port := '127.0.0.1:5150';
  {$ENDIF}
  A.Baud := 115200;
  A.Prompt := '';
  A.PromptFile := '';
  A.Opts := DefaultAgentOptions;
  LoadCfg(A);
  Code := ParseArgs(A);
  if Code >= 0 then Exit(Code);
  if A.PromptFile <> '' then
  begin
    if not ReadFileBytes(A.PromptFile, Raw, Err) then
    begin
      Say('PCLAW: cannot read ' + A.PromptFile + ': ' + Err);
      Exit(3);
    end;
    A.Prompt := Trim(FileTextToUtf8(Raw));
  end;

  if not OpenLink(A.Port, A.Baud, Link, Err) then
  begin
    Say('PCLAW: ' + Err);
    Exit(2);
  end;
  Agent := TDosAgent.Create(Link, A.Opts);
  try
    if not Agent.Health(Info) then
    begin
      Say('PCLAW: no answer from the bridge on ' + Link.Describe + ': ' + Info);
      Exit(2);
    end;
    if A.Prompt <> '' then
    begin
      if Agent.Turn(A.Prompt) then Exit(0) else Exit(1);
    end;

    Say(Format('PasClaw for DOS -- %s at %d -> %s', [Link.Describe, A.Baud, Info]));
    { One 80-column line: Say wraps at the screen edge. }
    Say('Type a request. /CLEAR forgets the chat, /QUIT leaves, Esc cancels a wait.');
    while True do
    begin
      Say('');
      SayRaw('pclaw> ');
      if not ReadPromptLine(Line) then Break;
      Line := Trim(Line);
      if Line = '' then Continue;
      if SameText(Line, '/QUIT') or SameText(Line, '/EXIT') or SameText(Line, 'exit') or
         SameText(Line, 'quit') then Break;
      if SameText(Line, '/CLEAR') then
      begin
        Agent.Clear;
        Say('(the conversation is forgotten)');
        Continue;
      end;
      if SameText(Line, '/HELP') or (Line = '/?') then
      begin
        Say('Ask for anything; the model can read, list, write and edit files here and run');
        Say('commands, and asks you before each write, edit or command (/YES skips that).');
        Continue;
      end;
      Agent.Turn(Line);
    end;
    Result := 0;
  finally
    Agent.Free;
    Link.Free;
  end;
end;

begin
  ExitCode := Main;
end.
