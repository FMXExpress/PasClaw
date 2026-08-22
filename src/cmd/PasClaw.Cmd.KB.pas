(*
  PasClaw.Cmd.KB - manage the knowledgebase ("add documents to the
  agent's reference corpus and search them").

    pasclaw kb add <path> [...]   Register file(s)/director(ies) as
                                  sources, then sync. Documents are
                                  indexed in place, never copied.
    pasclaw kb remove <path>      Unregister a source and drop its rows.
    pasclaw kb list               Registered sources with counts.
    pasclaw kb sync               Re-walk all sources (mtime-incremental).
    pasclaw kb search <query>     Search from the CLI (same backend the
                                  agent's kb_search tool uses).
    pasclaw kb get <path> <cN>    Print a chunk plus neighbours.
    pasclaw kb status             DB path, backend, corpus counts.

  Index: SQLite FTS5 BM25 always; hybrid FTS+vector automatically when
  the localvector runtime is provisioned (`pasclaw memory provision`)
  and vector_search_enabled is on — the exact same artifacts and flag
  memory_search uses. PDFs go through a native FlateDecode + /ToUnicode
  parser (PasClaw.KB.PDF) so they can be added directly; image-only
  scans without an embedded text layer fall out with a "no extractable
  text" warning.
*)
unit PasClaw.Cmd.KB;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_KB_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes, DateUtils,
  PasClaw.CliUI,
  PasClaw.Utils,
  PasClaw.KB.Index;

procedure Help;
begin
  PrintLn('Usage: pasclaw kb <subcommand>');
  PrintLn;
  PrintLn('Knowledgebase: index reference documents (text / markdown / source');
  PrintLn('code) so the agent can retrieve them with kb_search + kb_get.');
  PrintLn;
  PrintLn('Subcommands:');
  PrintLn('  add <path> [...]    Register file(s) or director(ies), then sync');
  PrintLn('  remove <path>       Unregister a source and drop its documents');
  PrintLn('  list                Show registered sources with counts');
  PrintLn('  sync                Re-index changed/added/removed documents');
  PrintLn('  search <query> [k]  Search the knowledgebase (default k=5)');
  PrintLn('  get <path> <cN> [w] Print chunk N of a document (+w neighbours)');
  PrintLn('  status              Show DB location, backend, and corpus size');
  PrintLn;
  PrintLn('Notes:');
  PrintLn('  - Documents are indexed in place; edits need `pasclaw kb sync`.');
  PrintLn('  - PDFs are indexed via a built-in parser (FlateDecode +');
  PrintLn('    /ToUnicode CMap). Image-only scans are skipped with a');
  PrintLn('    "no extractable text" warning. Files up to 30 MB.');
  PrintLn('  - Vector (semantic) ranking activates automatically once');
  PrintLn('    `pasclaw memory provision` has installed the local embedding');
  PrintLn('    runtime; otherwise search is keyword (FTS5 BM25) only.');
end;

function OpenIndex(out Idx: IKBIndex): Boolean;
begin
  Idx := NewKBIndex;
  Result := Idx.Open(DefaultKBDbPath);
  if not Result then
  begin
    PrintErr('could not open ' + DefaultKBDbPath +
             ' (' + SqliteOpenFailureReason(Idx.LastError) + ')');
    Idx := nil;
  end;
end;

function RunAdd(const Argv: array of string): Integer;
var
  Idx: IKBIndex;
  Err: string;
  i, Files, Chunks, Added: Integer;
begin
  Result := 1;
  if Length(Argv) = 0 then
  begin
    PrintErr('usage: pasclaw kb add <file-or-directory> [...]');
    Exit;
  end;
  if not OpenIndex(Idx) then Exit;
  try
    Added := 0;
    for i := 0 to High(Argv) do
      if Idx.AddSource(Argv[i], Err) then
      begin
        PrintLn(Ansi.Green + '+ ' + Ansi.Reset + ExpandFileName(Argv[i]));
        Inc(Added);
      end
      else
        PrintErr('skip ' + Argv[i] + ': ' + Err);
    if Added = 0 then Exit;

    PrintLn('indexing...');
    Idx.Sync(Files, Chunks);
    PrintLn(Format('indexed %d file(s), %d chunk(s)', [Files, Chunks]));
    Result := 0;
  finally
    Idx := nil;
  end;
end;

function RunRemove(const Argv: array of string): Integer;
var
  Idx: IKBIndex;
  Err: string;
begin
  Result := 1;
  if Length(Argv) = 0 then
  begin
    PrintErr('usage: pasclaw kb remove <path>');
    Exit;
  end;
  if not OpenIndex(Idx) then Exit;
  try
    if Idx.RemoveSource(Argv[0], Err) then
    begin
      PrintLn(Ansi.Red + '- ' + Ansi.Reset + ExpandFileName(Argv[0]));
      Result := 0;
    end
    else
      PrintErr(Err);
  finally
    Idx := nil;
  end;
end;

function RunList: Integer;
var
  Idx: IKBIndex;
  Sources: TKBSourceArray;
  i: Integer;
begin
  Result := 1;
  if not OpenIndex(Idx) then Exit;
  try
    Sources := Idx.GetSources;
    if Length(Sources) = 0 then
    begin
      PrintLn('(no sources — `pasclaw kb add <path>` to register documents)');
      Exit(0);
    end;
    for i := 0 to High(Sources) do
      PrintLn(Format('%s'#10'    %d file(s), %d chunk(s), added %s',
        [Sources[i].Root, Sources[i].Files, Sources[i].Chunks,
         FormatDateTime('yyyy-mm-dd', UnixToDateTime(Sources[i].AddedAt, False))]));
    Result := 0;
  finally
    Idx := nil;
  end;
end;

function RunSync: Integer;
var
  Idx: IKBIndex;
  Files, Chunks: Integer;
begin
  Result := 1;
  if not OpenIndex(Idx) then Exit;
  try
    Idx.Sync(Files, Chunks);
    if Files = 0 then
      PrintLn('up to date')
    else
      PrintLn(Format('re-indexed %d file(s), %d chunk(s)', [Files, Chunks]));
    Result := 0;
  finally
    Idx := nil;
  end;
end;

function RunSearch(const Argv: array of string): Integer;
var
  Idx:  IKBIndex;
  Hits: TKBHitArray;
  K, i: Integer;
begin
  Result := 1;
  if Length(Argv) = 0 then
  begin
    PrintErr('usage: pasclaw kb search <query> [k]');
    Exit;
  end;
  K := 5;
  if Length(Argv) >= 2 then K := StrToIntDef(Argv[1], 5);
  if not OpenIndex(Idx) then Exit;
  try
    Hits := Idx.Search(Argv[0], K);
    if Length(Hits) = 0 then
    begin
      PrintLn('(no matches)');
      Exit(0);
    end;
    for i := 0 to High(Hits) do
    begin
      PrintLn(Format('%s#c%d  ' + Ansi.Dim + '(score=%.3f)' + Ansi.Reset,
                     [Hits[i].Path, Hits[i].ChunkNo, Hits[i].Score]));
      PrintLn('  ' + Hits[i].Snippet);
      if i < High(Hits) then PrintLn;
    end;
    Result := 0;
  finally
    Idx := nil;
  end;
end;

function RunGet(const Argv: array of string): Integer;
var
  Idx: IKBIndex;
  ChunkNo, Window: Integer;
  S, NumArg: string;
begin
  Result := 1;
  if Length(Argv) < 2 then
  begin
    PrintErr('usage: pasclaw kb get <path> <chunk> [window]');
    Exit;
  end;
  { Accept both bare numbers and the c-prefixed citation form kb_search
    prints (`12` or `c12`). }
  NumArg := Argv[1];
  if (NumArg <> '') and ((NumArg[1] = 'c') or (NumArg[1] = 'C')) then
    NumArg := Copy(NumArg, 2, MaxInt);
  ChunkNo := StrToIntDef(NumArg, -1);
  if ChunkNo < 0 then
  begin
    PrintErr('chunk must be a number (e.g. 12 or c12)');
    Exit;
  end;
  Window := 1;
  if Length(Argv) >= 3 then Window := StrToIntDef(Argv[2], 1);

  if not OpenIndex(Idx) then Exit;
  try
    S := Idx.GetChunks(ExpandFileName(Argv[0]), ChunkNo, Window);
    if S = '' then
      { Paths are stored absolute, but show mercy on exact-string input
        from a kb_search hit (already absolute). }
      S := Idx.GetChunks(Argv[0], ChunkNo, Window);
    if S = '' then
    begin
      PrintErr('no such chunk — use the exact path printed by kb search');
      Exit;
    end;
    PrintLn(S);
    Result := 0;
  finally
    Idx := nil;
  end;
end;

function RunStatus: Integer;
var
  Idx: IKBIndex;
  S:   TKBStats;
begin
  Result := 1;
  PrintLn('db:      ' + DefaultKBDbPath);
  if not FileExists(DefaultKBDbPath) then
  begin
    PrintLn('status:  not created yet — `pasclaw kb add <path>` to start');
    Exit(0);
  end;
  if not OpenIndex(Idx) then Exit;
  try
    S := Idx.Stats;
    PrintLn(Format('corpus:  %d source(s), %d file(s), %d chunk(s)',
                   [S.Sources, S.Files, S.Chunks]));
    if S.VectorReady then
      PrintLn('backend: hybrid FTS5 + vector (localvector runtime provisioned)')
    else
      PrintLn('backend: FTS5 keyword only ' + Ansi.Dim +
              '(run `pasclaw memory provision` to enable semantic ranking)' +
              Ansi.Reset);
    Result := 0;
  finally
    Idx := nil;
  end;
end;

function Tail(const Argv: array of string): TArray<string>;
var
  i: Integer;
begin
  SetLength(Result, 0);
  if Length(Argv) <= 1 then Exit;
  SetLength(Result, Length(Argv) - 1);
  for i := 1 to High(Argv) do Result[i - 1] := Argv[i];
end;

function Cmd_KB_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then
  begin
    Help;
    Exit(1);
  end;
  Sub := LowerCase(Argv[0]);
  if (Sub = '-h') or (Sub = '--help') or (Sub = 'help') then
  begin
    Help;
    Exit(0);
  end;
  if Sub = 'add'    then Exit(RunAdd(Tail(Argv)));
  if Sub = 'remove' then Exit(RunRemove(Tail(Argv)));
  if Sub = 'list'   then Exit(RunList);
  if Sub = 'sync'   then Exit(RunSync);
  if Sub = 'search' then Exit(RunSearch(Tail(Argv)));
  if Sub = 'get'    then Exit(RunGet(Tail(Argv)));
  if Sub = 'status' then Exit(RunStatus);
  PrintErr('unknown kb subcommand: ' + Sub + sLineBreak);
  Help;
  Result := 1;
end;

end.
