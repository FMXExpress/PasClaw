(*
  PasClaw.Cmd.Session -- list / show / delete / export persistent
  conversation sessions stored under
  $PASCLAW_HOME/workspace/sessions/.

  See PasClaw.Session.Store for the on-disk format. The top-level
  `pasclaw resume <id>` shortcut is wired in Cmd.Root and rewrites
  Argv to `agent --session <id>` so the resume path goes through
  the same RunInteractive loop as a fresh chat.
*)
unit PasClaw.Cmd.Session;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Session_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes, DateUtils,
  PasClaw.CliUI,
  PasClaw.Utils,
  PasClaw.Providers.Types,   { TMsgRole = (mrSystem, mrUser, mrAssistant, mrTool) }
  PasClaw.Session.Store,
  PasClaw.Session.Port,
  PasClaw.Agent.Steering;

procedure PrintHelp;
begin
  PrintLn('Usage: pasclaw session <list|show|delete|export|import> [args]');
  PrintLn('  list                list every saved session (id, title, msgs, last used)');
  PrintLn('  show <id>           show one session: metadata + last N messages');
  PrintLn('  delete <id>         remove the session file from disk');
  PrintLn('  export <id> [--md]  print the session to stdout (raw JSON, or Markdown with --md)');
  PrintLn('  export <id> --full  the pre-prune original when pruning removed turns');
  PrintLn('  import <path>       import chats: ChatGPT conversations.json, a Claude Code /');
  PrintLn('                      Pi / OpenClaw .jsonl transcript, a PasClaw session export');
  PrintLn('                      (auto-detected), or an OpenCode data DIRECTORY');
end;

function FormatAge(Now_, Then_: Int64): string;
var
  Delta: Int64;
begin
  Delta := Now_ - Then_;
  if Delta < 60 then Result := IntToStr(Delta) + 's ago'
  else if Delta < 3600 then Result := IntToStr(Delta div 60) + 'm ago'
  else if Delta < 86400 then Result := IntToStr(Delta div 3600) + 'h ago'
  else Result := IntToStr(Delta div 86400) + 'd ago';
end;

function DoList: Integer;
var
  Sessions: TSessionMetaArray;
  i: Integer;
  Now_: Int64;
  Title: string;
begin
  Sessions := ListSessions;
  if Length(Sessions) = 0 then
  begin
    PrintLn(Ansi.Dim + '(no saved sessions)' + Ansi.Reset);
    Exit(0);
  end;
  Now_ := DateTimeToUnix(Now, False);
  PrintLn(Ansi.Bold + Format('%28s', ['session id']) + '  ' + Format('%12s', ['updated']) + '  ' + Format('%5s', ['msgs']) + '  title' + Ansi.Reset);
  for i := 0 to High(Sessions) do
  begin
    Title := Sessions[i].Title;
    if Title = '' then Title := Ansi.Dim + '(untitled)' + Ansi.Reset;
    PrintLn(Format('%28s', [Sessions[i].Id]) + '  ' +
            Format('%12s', [FormatAge(Now_, Sessions[i].UpdatedAt)]) + '  ' +
            Format('%5s', ['']) +
            '  ' + Title);
  end;
  Result := 0;
end;

function DoShow(const Id: string): Integer;
const
  TailCount = 8;   { last N messages, head trimmed for brevity }
var
  Sess: TSession;
  i, Start: Integer;
  Role, Preview: string;
begin
  Sess := TSession.Create(Id);
  try
    if not Sess.MetaExists then
    begin
      PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'no session named ' + Id);
      Exit(1);
    end;
    PrintLn(Ansi.Bold + 'id:        ' + Ansi.Reset + Sess.Meta.Id);
    PrintLn(Ansi.Bold + 'title:     ' + Ansi.Reset + Sess.Meta.Title);
    PrintLn(Ansi.Bold + 'model:     ' + Ansi.Reset + Sess.Meta.Model);
    PrintLn(Ansi.Bold + 'provider:  ' + Ansi.Reset + Sess.Meta.Provider);
    if Sess.Meta.Profile <> '' then
      PrintLn(Ansi.Bold + 'profile:   ' + Ansi.Reset + Sess.Meta.Profile);
    PrintLn(Ansi.Bold + 'messages:  ' + Ansi.Reset + IntToStr(Length(Sess.Messages)));
    if Sess.Meta.SystemPromptOverride <> '' then
      PrintLn(Ansi.Bold + 'compacted: ' + Ansi.Reset + Ansi.Dim + 'yes' + Ansi.Reset);
    PrintLn;
    Start := Length(Sess.Messages) - TailCount;
    if Start < 0 then Start := 0
    else if Start > 0 then
      PrintLn(Ansi.Dim + '... (' + IntToStr(Start) + ' earlier messages elided; use `export` for full JSON)' + Ansi.Reset);
    for i := Start to High(Sess.Messages) do
    begin
      case Sess.Messages[i].Role of
        mrSystem:    Role := Ansi.Yellow  + 'system'    + Ansi.Reset;
        mrUser:      Role := Ansi.Bold    + 'user'      + Ansi.Reset;
        mrAssistant: Role := Ansi.Cyan    + 'assistant' + Ansi.Reset;
        mrTool:      Role := Ansi.Magenta + 'tool'      + Ansi.Reset;
      else
        Role := '?';
      end;
      Preview := Sess.Messages[i].Content;
      if Length(Preview) > 200 then Preview := Copy(Preview, 1, 200) + '…';
      PrintLn(Role + ': ' + Preview);
    end;
    Result := 0;
  finally
    Sess.Free;
  end;
end;

function DoDelete(const Id: string): Integer;
begin
  if DeleteSession(Id) then
  begin
    { Stray steering messages for the just-deleted session would
      otherwise sit on disk forever -- clear them too. }
    ClearSteering(Id);
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'deleted session ' + Id);
    Result := 0;
  end
  else
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'no session named ' + Id);
    Result := 1;
  end;
end;

(* Export the session as JSON.

   Full prefers the PRE-PRUNE archive when there is one. Pruning
   deletes from the live file, which is correct for resuming and wrong
   for asking later what the agent actually saw -- so a pruned session
   keeps its original beside it and --full is how you read it. Without
   an archive the two are the same file, and --full is a no-op rather
   than an error: "give me everything" is satisfied by everything
   there is. *)
function DoExport(const Id: string; Full: Boolean = False): Integer;
var
  Path, Body, Err: string;
  S: TStringList;
begin
  Path := '';
  if Full and HasSessionArchive(Id) then
  begin
    Path := SessionArchivePath(Id);
    PrintErr('(pre-prune archive: ' + Path + ')' + sLineBreak);
  end;
  if Path <> '' then
  begin
    { --full asked for the pre-prune archive specifically: verbatim. }
    if not FileExists(Path) then
    begin
      PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'no session named ' + Id);
      Exit(1);
    end;
    S := TStringList.Create;
    try
      S.Text := ReadFileText(Path);
      Print(S.Text);
      Exit(0);
    finally
      S.Free;
    end;
  end;
  { The ordinary export: the session document with the full RECORD as
    its messages when one exists -- a compacted session's live file is
    a summary plus the tail, and exporting that silently dropped every
    turn compaction removed. Same shape either way. }
  if not ExportSessionJSON(Id, Body, Err) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + Err);
    Exit(1);
  end;
  Print(Body);   { raw JSON to stdout; pipe through jq for pretty-print }
  Result := 0;
end;

function DoExportMarkdown(const Id: string): Integer;
var
  MD, Err: string;
begin
  if ExportSessionMarkdown(Id, MD, Err) then
  begin
    Print(MD);
    Result := 0;
  end
  else
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + Err);
    Result := 1;
  end;
end;

function DoImport(const Path: string): Integer;
var
  Text, Err: string;
  Ids: TImportedIds;
  N, i: Integer;
begin
  { A directory is an OpenCode data dir (sessions fragmented across per-message
    files); a file is a ChatGPT / Claude Code / Pi / OpenClaw / PasClaw export. }
  if DirectoryExists(Path) then
    N := ImportOpenCodeDir(Path, Ids, Err)
  else if FileExists(Path) then
  begin
    Text := ReadFileText(Path);
    N := ImportSessions(Text, Ids, Err);
  end
  else
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'no such file or directory: ' + Path);
    Exit(1);
  end;
  if N = 0 then
  begin
    if Err <> '' then PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + Err)
    else PrintLn('nothing importable found in ' + Path);
    Exit(1);
  end;
  PrintLn(Format('%s✓%s imported %d session(s):', [Ansi.Green, Ansi.Reset, N]));
  for i := 0 to High(Ids) do
    PrintLn('  ' + Ids[i] + '   (resume with: pasclaw resume ' + Ids[i] + ')');
  Result := 0;
end;

function Cmd_Session_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then begin PrintHelp; Exit(1); end;
  Sub := Argv[0];
  if      Sub = 'list'   then Result := DoList
  else if Sub = 'show'   then begin if Length(Argv) < 2 then begin PrintHelp; Exit(1); end; Result := DoShow  (Argv[1]); end
  else if Sub = 'delete' then begin if Length(Argv) < 2 then begin PrintHelp; Exit(1); end; Result := DoDelete(Argv[1]); end
  else if Sub = 'export' then
  begin
    if Length(Argv) < 2 then begin PrintHelp; Exit(1); end;
    if (Length(Argv) >= 3) and ((Argv[2] = '--md') or (Argv[2] = '--markdown')) then
      Result := DoExportMarkdown(Argv[1])
    else
      Result := DoExport(Argv[1],
                         (Length(Argv) >= 3) and (Argv[2] = '--full'));
  end
  else if Sub = 'import' then begin if Length(Argv) < 2 then begin PrintHelp; Exit(1); end; Result := DoImport(Argv[1]); end
  else                        begin PrintHelp; Result := 1; end;
end;

end.
