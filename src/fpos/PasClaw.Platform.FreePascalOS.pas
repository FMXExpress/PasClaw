(*
  PasClaw.Platform.FreePascalOS - the operating system calls PasClaw makes
  on FreePascalOS (https://github.com/xeons/FreePascalOS).

  Only `make fpos` compiles this unit: src/fpos is on no other build's
  unit path, and every unit that names it does so inside
  {$IFDEF FREEPASCALOS}. It is the one place PasClaw talks to the
  system's own libraries (libsystem's Sys.* units) for processes, the
  console and the environment -- the parts that are BaseUnix, termio or
  Windows on the other targets.

  This file is PasClaw's, under PasClaw's MIT license. The units it uses
  are FreePascalOS's and GPLv3; a pasclaw binary built for FreePascalOS
  links them, so docs/freepascalos.md applies to distributing one.
*)
unit PasClaw.Platform.FreePascalOS;

{$MODE DELPHI}
{$H+}

interface

uses
  SysUtils, Classes;

const
  { The exit code a program ended outright gets: 128 + SIGKILL, as a
    shell reports `kill -9`. }
  FposKilledExitCode = 128 + 9;

{ Ends Pid and every process started under it (its children, theirs,
  ...), the deepest first, so that nothing a command left running
  outlives it. A pid that has ended already is skipped. }
procedure FposTerminateProcessTree(Pid: Integer);

{ Ends one process outright; False when it could not be ended (it had
  ended, or it is not this user's). }
function FposTerminateProcess(Pid: Integer): Boolean;

{ True while process Pid runs. }
function FposProcessExists(Pid: Integer): Boolean;

{ The console's size in characters; False (and 80 x 24) when standard
  output is not a console. }
function FposConsoleSize(out Columns, Rows: Integer): Boolean;

{ True when standard input / output is the console (not a pipe or a
  file). }
function FposStdinIsConsole: Boolean;
function FposStdoutIsConsole: Boolean;

{ Sets (or with Value = '' removes) a variable of this program's
  environment, which the programs it starts inherit. }
procedure FposSetEnvironmentVariable(const Name, Value: string);

{ Turns the console's echo of what is typed off (Echo = False) or back
  on; False when standard input is not the console. For reading a
  secret. }
function FposSetConsoleEcho(Echo: Boolean): Boolean;

{ The first IPv4 address of Host as a dotted quad, through the system's
  resolver (/etc/hosts, then DNS). False with ErrMsg when it has none. }
function FposResolveIPv4(const Host: string; out IP, ErrMsg: string): Boolean;

implementation

uses
  Abi.SystemCalls,
  Sys.Console,
  Sys.Environment,
  Sys.HostLookup,
  Sys.HostNames,
  Sys.InternetAddresses,
  Sys.ProcessList,
  Sys.Processes;

function FposResolveIPv4(const Host: string; out IP, ErrMsg: string): Boolean;
var
  Addresses: TInternetAddressArray;
  Error: LongInt;
begin
  IP := '';
  ErrMsg := '';
  Error := ResolveHost(Host, HostFamilyIpv4, Addresses);
  if Error <> ErrorNone then
  begin
    ErrMsg := HostLookupErrorMessage(Error);
    Exit(False);
  end;
  if Length(Addresses) = 0 then
  begin
    ErrMsg := 'no IPv4 address';
    Exit(False);
  end;
  IP := Format('%d.%d.%d.%d', [Addresses[0].Bytes[0], Addresses[0].Bytes[1],
                               Addresses[0].Bytes[2], Addresses[0].Bytes[3]]);
  Result := True;
end;

function FposTerminateProcess(Pid: Integer): Boolean;
begin
  Result := (Pid > 1) and
            (TerminateProgram(QWord(Pid), FposKilledExitCode) = ErrorNone);
end;

function FposProcessExists(Pid: Integer): Boolean;
var
  Details: TProcessDetails;
begin
  Result := (Pid > 0) and GetProcessDetails(QWord(Pid), Details);
end;

procedure FposTerminateProcessTree(Pid: Integer);
var
  Snapshot: TProcessSnapshot;
  Tree: array of QWord;
  Count, Scan, i: Integer;
  Entry: PProcessDetails;
  Self_: QWord;
begin
  if Pid <= 1 then Exit;
  Self_ := QWord(CurrentProcessId);
  SetLength(Tree, 1);
  Tree[0] := QWord(Pid);
  Count := 1;
  InitializeProcessSnapshot(Snapshot);
  try
    if TakeProcessSnapshot(Snapshot) = ErrorNone then
    begin
      { Breadth first over one snapshot: everything whose parent is
        already in the tree joins it. Bounded by the snapshot, so a
        process table that changes meanwhile cannot make it loop. }
      Scan := 0;
      while Scan < Count do
      begin
        Entry := Snapshot.Entries;
        for i := 0 to Snapshot.Count - 1 do
        begin
          if (Entry^.ParentProcessId = Tree[Scan]) and
             (Entry^.ProcessId <> Self_) and (Entry^.ProcessId > 1) then
          begin
            if Count >= Length(Tree) then
              SetLength(Tree, Count * 2 + 4);
            Tree[Count] := Entry^.ProcessId;
            Inc(Count);
          end;
          Inc(Entry);
        end;
        Inc(Scan);
      end;
    end;
  finally
    FreeProcessSnapshot(Snapshot);
  end;
  for i := Count - 1 downto 0 do
    if Tree[i] <> Self_ then
      TerminateProgram(Tree[i], FposKilledExitCode);
end;

const
  StdinHandle  = 0;
  StdoutHandle = 1;

function FposConsoleSize(out Columns, Rows: Integer): Boolean;
var
  R, C: LongInt;
begin
  Columns := 80;
  Rows := 24;
  Result := False;
  if not IsConsole(StdoutHandle) then Exit;
  R := 0;
  C := 0;
  GetConsoleSize(StdoutHandle, R, C);
  if (R > 0) and (C > 0) then
  begin
    Columns := C;
    Rows := R;
    Result := True;
  end;
end;

function FposStdinIsConsole: Boolean;
begin
  Result := IsConsole(StdinHandle);
end;

function FposStdoutIsConsole: Boolean;
begin
  Result := IsConsole(StdoutHandle);
end;

procedure FposSetEnvironmentVariable(const Name, Value: string);
begin
  if Value = '' then
    RemoveVariable(Name)
  else
    SetVariable(Name, Value);
  { libsystem keeps the changed environment in a block of its own; the
    runtime's GetEnvironmentVariable reads System.envp. Point that at it
    so this program sees the change as well as the ones it starts. }
  envp := EnvironmentBlock;
end;

function FposSetConsoleEcho(Echo: Boolean): Boolean;
var
  Mode: Int64;
begin
  Result := False;
  if not IsConsole(StdinHandle) then Exit;
  Mode := GetConsoleMode(StdinHandle);
  if Mode < 0 then Exit;
  if Echo then
    Mode := Mode or ConsoleModeEcho
  else
    Mode := Mode and not Int64(ConsoleModeEcho);
  Result := SetConsoleMode(StdinHandle, LongWord(Mode)) = ErrorNone;
end;

end.
