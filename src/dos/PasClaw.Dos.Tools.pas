(*
  PasClaw.Dos.Tools -- what the model can do on the DOS PC.

    read_file   a text file, a window of lines at a time
    list_dir    a directory: names, sizes, <DIR>
    write_file  create or replace a text file         (asks first)
    edit_file   replace one exact piece of a file     (asks first)
    run         a command through COMMAND.COM        (asks first)

  Every result is capped: the answer travels back up a serial line and
  into the model's context. Text files are CP437 with CR LF on disk and
  UTF-8 with LF to the model (PasClaw.Dos.Text). A command's output is
  what it writes to standard output, captured by redirecting it to a
  file -- COMMAND.COM cannot redirect standard error, and a DOS command
  line holds 126 characters, so a longer command belongs in a .BAT file.

  On a host build `run` goes through /bin/sh and captures both streams.
*)
unit PasClaw.Dos.Tools;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

const
  READ_CAP  = 6000;   { bytes of file text per read_file }
  RUN_CAP   = 4000;   { bytes of command output }
  LIST_CAP  = 4000;
  READ_LINES_DEFAULT = 200;

type
  { The question goes to the person at the keyboard; True = go ahead. }
  TAskFn = function(const Question: string): Boolean of object;

{ The tools as the "tools" array of a /v1/responses request. }
function DosToolsJSON: string;

{ Run one call. IsError when the call failed or was refused; the text
  says why either way, and goes back to the model as the call's output. }
function RunDosTool(const Name, ArgsJSON: string; Ask: TAskFn;
  out IsError: Boolean): string;

{ One line for the screen: what is about to happen. }
function DescribeToolCall(const Name, ArgsJSON: string): string;

(* A file in Dir that did not exist and now does, empty, with an 8.3
   name: where `run` sends a command's output. Made (not just named)
   here, so nothing else takes the name before the command runs, and
   `run` deletes it -- and only it -- afterwards. '' when no name is free. *)
function NewRunOutputPath(const Dir: string): string;

implementation

uses
  {$IFDEF GO32V2}Dos,{$ENDIF}
  StrUtils,
  PasClaw.JSON,
  PasClaw.Dos.Text;

function DosToolsJSON: string;
begin
  Result :=
    '[' +
    '{"type":"function","name":"read_file","description":"Read a text file. Returns up to ' +
      IntToStr(READ_LINES_DEFAULT) + ' lines from start_line; read on with a larger start_line.",' +
      '"parameters":{"type":"object","properties":{' +
        '"path":{"type":"string","description":"File path, e.g. C:\\AUTOEXEC.BAT"},' +
        '"start_line":{"type":"integer","description":"First line, from 1"},' +
        '"max_lines":{"type":"integer"}},"required":["path"]}},' +
    '{"type":"function","name":"list_dir","description":"List a directory: files with sizes, subdirectories marked <DIR>.",' +
      '"parameters":{"type":"object","properties":{' +
        '"path":{"type":"string","description":"Directory; default the current one"},' +
        '"pattern":{"type":"string","description":"Wildcard, default *.*"}}}},' +
    '{"type":"function","name":"write_file","description":"Create or replace a text file with content. The user confirms first.",' +
      '"parameters":{"type":"object","properties":{' +
        '"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}},' +
    '{"type":"function","name":"edit_file","description":"Replace old_text with new_text in a file. old_text must occur exactly once. The user confirms first.",' +
      '"parameters":{"type":"object","properties":{' +
        '"path":{"type":"string"},"old_text":{"type":"string"},"new_text":{"type":"string"}},' +
        '"required":["path","old_text","new_text"]}},' +
    '{"type":"function","name":"run","description":"Run a command with the system shell and return what it prints (first ' +
      IntToStr(RUN_CAP) + ' bytes). The user confirms first.",' +
      '"parameters":{"type":"object","properties":{' +
        '"command":{"type":"string"}},"required":["command"]}}' +
    ']';
end;

function Cap(const S: string; Limit: Integer; const What: string): string;
begin
  if Length(S) <= Limit then Exit(S);
  Result := Copy(S, 1, Limit);
  { Do not end inside a UTF-8 sequence. }
  while (Length(Result) > 0) and ((Ord(Result[Length(Result)]) and $C0) = $80) do
    SetLength(Result, Length(Result) - 1);
  if (Length(Result) > 0) and (Ord(Result[Length(Result)]) >= $C0) then
    SetLength(Result, Length(Result) - 1);
  Result := Result + #10 + '[' + What + ' cut at ' + IntToStr(Limit) + ' of ' +
            IntToStr(Length(S)) + ' bytes]';
end;

function ParseArgs(const ArgsJSON: string): TJsonObject;
begin
  Result := nil;
  try
    if Trim(ArgsJSON) = '' then Result := TJsonObject.Create
    else Result := TJsonObject.Parse(ArgsJSON);
  except
    Result := nil;
  end;
end;

function HasNul(const S: string): Boolean;
begin
  Result := Pos(#0, S) > 0;
end;

function ToolReadFile(A: TJsonObject; out IsError: Boolean): string;
var
  Path, Raw, Err: string;
  L: TStringList;
  Start, MaxL, i, Last: Integer;
  SB: TStringBuilder;
begin
  IsError := True;
  Path := A.GetStr('path', '');
  if Path = '' then Exit('read_file needs a path');
  if not ReadFileBytes(Path, Raw, Err) then Exit('cannot read ' + Path + ': ' + Err);
  if HasNul(Raw) then
    Exit(Format('%s is a binary file (%d bytes); not shown', [Path, Length(Raw)]));
  IsError := False;
  Start := A.GetInt('start_line', 1);
  if Start < 1 then Start := 1;
  MaxL := A.GetInt('max_lines', READ_LINES_DEFAULT);
  if MaxL < 1 then MaxL := READ_LINES_DEFAULT;
  L := TStringList.Create;
  SB := TStringBuilder.Create;
  try
    L.Text := FileTextToUtf8(Raw);
    if L.Count = 0 then Exit('(empty file)');
    if Start > L.Count then Exit(Format('(the file has %d lines)', [L.Count]));
    Last := Start + MaxL - 1;
    if Last > L.Count then Last := L.Count;
    for i := Start - 1 to Last - 1 do
    begin
      if SB.Length + Length(L[i]) + 1 > READ_CAP then
      begin
        if SB.Length = 0 then
        begin
          { The first line alone is over the cap (minified JSON, say):
            its start, marked as cut, and the window moves past it --
            otherwise "read on with start_line" would name this same
            line again, forever. }
          SB.Append(Cap(L[i], READ_CAP, Format('line %d', [i + 1])));
          SB.Append(#10);
          Last := i + 1;
        end
        else
          Last := i;
        Break;
      end;
      SB.Append(L[i]);
      SB.Append(#10);
    end;
    Result := SB.ToString;
    if (Start > 1) or (Last < L.Count) then
      Result := Result + Format('[lines %d-%d of %d', [Start, Last, L.Count]) +
        IfThen(Last < L.Count, Format('; read on with start_line=%d]', [Last + 1]), ']');
  finally
    SB.Free;
    L.Free;
  end;
end;

function ToolListDir(A: TJsonObject; out IsError: Boolean): string;
var
  Dir, Pattern, Line: string;
  SR: TSearchRec;
  SB: TStringBuilder;
  Count: Integer;
begin
  IsError := False;
  Dir := A.GetStr('path', '');
  if Dir = '' then Dir := '.';
  Pattern := A.GetStr('pattern', '');
  if Pattern = '' then
    {$IFDEF GO32V2}Pattern := '*.*'{$ELSE}Pattern := '*'{$ENDIF};
  SB := TStringBuilder.Create;
  try
    Count := 0;
    if SysUtils.FindFirst(ToLocal(IncludeTrailingPathDelimiter(Dir) + Pattern), faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') or (SR.Name = '') then Continue;
        if (SR.Attr and $08) <> 0 then Continue;   { the volume label, on DOS }
        if (SR.Attr and faDirectory) <> 0 then
          Line := Format('%-14s <DIR>', [FromLocal(SR.Name)])
        else
          Line := Format('%-14s %9d', [FromLocal(SR.Name), SR.Size]);
        SB.Append(Line);
        SB.Append(#10);
        Inc(Count);
      until SysUtils.FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
    if Count = 0 then
    begin
      if not DirectoryExists(ToLocal(Dir)) then
      begin
        IsError := True;
        Exit('no such directory: ' + Dir);
      end;
      Exit('(nothing matches ' + Pattern + ' in ' + Dir + ')');
    end;
    Result := Cap(SB.ToString, LIST_CAP, 'listing');
  finally
    SB.Free;
  end;
end;

function ToolWriteFile(A: TJsonObject; Ask: TAskFn; out IsError: Boolean): string;
var
  Path, Content, Err, Dir: string;
  Exists: Boolean;
begin
  IsError := True;
  Path := A.GetStr('path', '');
  if Path = '' then Exit('write_file needs a path');
  if not A.Has('content') then Exit('write_file needs content');
  Content := A.GetStr('content', '');
  Exists := FileExists(ToLocal(Path));
  if not Ask(Format('%s %s (%d bytes)?', [IfThen(Exists, 'Replace', 'Create'), Path,
                                          Length(Content)])) then
    Exit('the user said no; ' + Path + ' was not written');
  Dir := ExtractFileDir(Path);
  if (Dir <> '') and not DirectoryExists(ToLocal(Dir)) then
    ForceDirectories(ToLocal(Dir));
  if not WriteFileBytes(Path, Utf8ToFileText(Content), Err) then
    Exit('cannot write ' + Path + ': ' + Err);
  IsError := False;
  Result := Format('wrote %s (%d bytes)', [Path, Length(Content)]);
end;

function CountOccurrences(const Needle, Hay: string; out FirstAt: Integer): Integer;
var
  P, From: Integer;
begin
  Result := 0;
  FirstAt := 0;
  From := 1;
  while True do
  begin
    P := Pos(Needle, Copy(Hay, From, MaxInt));
    if P = 0 then Break;
    if Result = 0 then FirstAt := From + P - 1;
    Inc(Result);
    From := From + P - 1 + Length(Needle);
  end;
end;

function Preview(const S: string): string;
begin
  Result := StringReplace(S, #10, ' / ', [rfReplaceAll]);
  if Length(Result) > 60 then Result := Copy(Result, 1, 57) + '...';
end;

function ToolEditFile(A: TJsonObject; Ask: TAskFn; out IsError: Boolean): string;
var
  Path, OldT, NewT, Raw, Text, Err: string;
  N, At: Integer;
begin
  IsError := True;
  Path := A.GetStr('path', '');
  OldT := A.GetStr('old_text', '');
  NewT := A.GetStr('new_text', '');
  if Path = '' then Exit('edit_file needs a path');
  if OldT = '' then Exit('edit_file needs old_text (use write_file for a new file)');
  if not ReadFileBytes(Path, Raw, Err) then Exit('cannot read ' + Path + ': ' + Err);
  Text := FileTextToUtf8(Raw);
  N := CountOccurrences(OldT, Text, At);
  if N = 0 then Exit('old_text is not in ' + Path + ' (it must match exactly; read_file shows the text)');
  if N > 1 then Exit(Format('old_text occurs %d times in %s; give more of the surrounding text so it occurs once', [N, Path]));
  if not Ask(Format('Edit %s: "%s" -> "%s"?', [Path, Preview(OldT), Preview(NewT)])) then
    Exit('the user said no; ' + Path + ' was not changed');
  Text := Copy(Text, 1, At - 1) + NewT + Copy(Text, At + Length(OldT), MaxInt);
  if not WriteFileBytes(Path, Utf8ToFileText(Text), Err) then
    Exit('cannot write ' + Path + ': ' + Err);
  IsError := False;
  Result := 'edited ' + Path;
end;

function NewRunOutputPath(const Dir: string): string;
var
  i: Integer;
  H: THandle;
begin
  Result := '';
  for i := 1 to 1000 do
  begin
    { 8.3, for DOS. }
    Result := IncludeTrailingPathDelimiter(Dir) + Format('PC%.6d.TMP', [Random(1000000)]);
    if FileExists(ToLocal(Result)) then Continue;
    H := FileCreate(ToLocal(Result));
    if H = THandle(-1) then Continue;
    FileClose(H);
    Exit;
  end;
  Result := '';
end;

function TempOutDir: string;
begin
  {$IFDEF GO32V2}
  Result := GetEnvironmentVariable('TEMP');
  if Result = '' then Result := GetEnvironmentVariable('TMP');
  if (Result = '') or not DirectoryExists(Result) then Result := GetCurrentDir;
  {$ELSE}
  Result := GetTempDir;
  {$ENDIF}
end;

function ToolRun(A: TJsonObject; Ask: TAskFn; out IsError: Boolean): string;
var
  Cmd, Tmp, Raw, Err, Shell, Line: string;
  Code: Integer;
begin
  IsError := True;
  Cmd := A.GetStr('command', '');
  if Trim(Cmd) = '' then Exit('run needs a command');
  if not Ask('Run: ' + Cmd) then Exit('the user said no; the command did not run');
  Tmp := NewRunOutputPath(TempOutDir);
  if Tmp = '' then Exit('no free name for a temporary file in ' + TempOutDir);
  try
  {$IFDEF GO32V2}
  Shell := GetEnvironmentVariable('COMSPEC');
  if Shell = '' then Shell := 'C:\COMMAND.COM';
  Line := '/C ' + ToLocal(Cmd) + ' > ' + Tmp;
  if Length(Line) > 126 then
    Exit(Format('the command is %d characters; a DOS command line holds about %d. ' +
                'Write it to a .BAT file with write_file and run that.',
                [Length(Cmd), 126 - Length(Line) + Length(Cmd)]));
  SwapVectors;
  Dos.Exec(Shell, Line);
  SwapVectors;
  if DosError <> 0 then
    Exit(Format('cannot start %s (DOS error %d)', [Shell, DosError]));
  Code := DosExitCode;
  {$ELSE}
  Shell := '/bin/sh';
  Line := Cmd;
  try
    Code := ExecuteProcess(Shell, ['-c', '( ' + Cmd + ' ) > ''' + Tmp + ''' 2>&1']);
  except
    on E: Exception do Exit('cannot start ' + Shell + ': ' + E.Message);
  end;
  {$ENDIF}
  IsError := False;
  if ReadFileBytes(Tmp, Raw, Err) then
    Result := Cap(FileTextToUtf8(Raw), RUN_CAP, 'output')
  else
    Result := '';
  if Result = '' then Result := '(no output)';
  if Code <> 0 then Result := Result + #10 + '[exit code ' + IntToStr(Code) + ']';
  finally
    { Only the file this call made. }
    DeleteFile(ToLocal(Tmp));
  end;
end;

function RunDosTool(const Name, ArgsJSON: string; Ask: TAskFn;
  out IsError: Boolean): string;
var
  A: TJsonObject;
begin
  IsError := True;
  A := ParseArgs(ArgsJSON);
  if A = nil then Exit('the arguments are not a JSON object: ' + Copy(ArgsJSON, 1, 200));
  try
    try
      if Name = 'read_file' then Result := ToolReadFile(A, IsError)
      else if Name = 'list_dir' then Result := ToolListDir(A, IsError)
      else if Name = 'write_file' then Result := ToolWriteFile(A, Ask, IsError)
      else if Name = 'edit_file' then Result := ToolEditFile(A, Ask, IsError)
      else if Name = 'run' then Result := ToolRun(A, Ask, IsError)
      else Result := 'no tool named ' + Name + ' here; the tools are read_file, list_dir, ' +
                     'write_file, edit_file and run';
    except
      on E: Exception do
      begin
        IsError := True;
        Result := Name + ' failed: ' + E.Message;
      end;
    end;
  finally
    A.Free;
  end;
end;

function DescribeToolCall(const Name, ArgsJSON: string): string;
var
  A: TJsonObject;
begin
  Result := Name;
  A := ParseArgs(ArgsJSON);
  if A = nil then Exit;
  try
    if Name = 'run' then Result := 'run ' + A.GetStr('command', '')
    else if Name = 'list_dir' then
      Result := Trim('list_dir ' + A.GetStr('path', '.') + ' ' + A.GetStr('pattern', ''))
    else if Name = 'write_file' then
      Result := Format('write_file %s (%d bytes)', [A.GetStr('path', ''), Length(A.GetStr('content', ''))])
    else if A.Has('path') then Result := Name + ' ' + A.GetStr('path', '');
  finally
    A.Free;
  end;
  if Length(Result) > 76 then Result := Copy(Result, 1, 73) + '...';
end;

end.
