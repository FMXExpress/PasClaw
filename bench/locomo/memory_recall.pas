program memory_recall;
(*
  bench/locomo/memory_recall -- thin CLI shim over PasClaw.Memory.Index
  for the LOCOMO retrieval bench. Not part of pasclaw proper; lives
  here so the harness can ask the same Search() the agent's
  memory_search tool would, without spawning the agent loop.

  Usage:
    memory_recall --home <path> --query "<question>" --k <N>

  Output: a single JSON object on stdout:
    { "hits": [
        { "path": "<file>", "snippet": "<txt>", "score": <float> },
        ...
      ]
    }

  Errors go to stderr; exit code is 0 on success / 1 on any failure
  so the Python harness can subprocess this cleanly.

  Resolution order for $PASCLAW_HOME:
    1. --home <path>          (the bench harness always sets this)
    2. PASCLAW_HOME env var   (so a manual run is easy too)
    3. default GetHome        (last resort)
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  SysUtils,
  PasClaw.Memory.Index,
  PasClaw.Memory.Vector,
  PasClaw.Config,
  PasClaw.Utils;

{$IFDEF UNIX}
function libc_setenv(const Name, Value: PAnsiChar; Overwrite: Integer): Integer;
  cdecl; external 'c' name 'setenv';
{$ENDIF}

procedure SetEnv(const Name, Value: string);
begin
  {$IFDEF UNIX}
  libc_setenv(PAnsiChar(AnsiString(Name)), PAnsiChar(AnsiString(Value)), 1);
  {$ENDIF}
end;

function JsonEscape(const S: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    case c of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      if Ord(c) < 32 then
        Result := Result + Format('\u%4.4x', [Ord(c)])
      else
        Result := Result + c;
    end;
  end;
end;

procedure Die(const Msg: string);
begin
  Writeln(StdErr, 'memory_recall: ', Msg);
  Halt(1);
end;

var
  i, K: Integer;
  Query, Home: string;
  Cfg: TConfig;
  Idx: IMemoryIndex;
  Hits: TMemoryHitArray;
  DbPath, MemDir: string;
  First: Boolean;
begin
  Home  := '';
  Query := '';
  K     := 10;
  i := 1;
  while i <= ParamCount do
  begin
    if ParamStr(i) = '--home' then
    begin
      if i = ParamCount then Die('--home needs a value');
      Inc(i); Home := ParamStr(i);
    end
    else if ParamStr(i) = '--query' then
    begin
      if i = ParamCount then Die('--query needs a value');
      Inc(i); Query := ParamStr(i);
    end
    else if ParamStr(i) = '--k' then
    begin
      if i = ParamCount then Die('--k needs a value');
      Inc(i); K := StrToIntDef(ParamStr(i), 10);
    end
    else
      Die('unknown arg: ' + ParamStr(i));
    Inc(i);
  end;

  if Query = '' then Die('--query is required');
  if Home <> '' then SetEnv('PASCLAW_HOME', Home);

  { Sync the memory store so any newly-written .md files we wrote
    in load_persona.py land in the FTS5 / vec indexes before we
    Search. The bench writes files then immediately queries; without
    a SyncDir, FTS5 sees zero rows.

    Index paths match PasClaw.Tools.Memory.IndexDbPath:
      FTS5     : $PASCLAW_HOME/workspace/memory/.index.db
      Vector   : $PASCLAW_HOME/workspace/memory/.index.db.vec  }
  Cfg := LoadConfig;
  try
    MemDir := JoinPath(GetHome, 'workspace/memory');
    ForceDirectories(MemDir);
    DbPath := JoinPath(MemDir, '.index.db');

    Idx := nil;
    if Cfg.VectorSearchEnabled then
    begin
      Idx := NewVectorMemoryIndex;
      if not Idx.Open(DbPath + '.vec') then
        Idx := nil;
    end;
    if Idx = nil then
    begin
      Idx := NewMemoryIndex;
      if not Idx.Open(DbPath) then
        Die('Open ' + DbPath + ' failed (libsqlite3 missing?)');
    end;
    try
      Idx.SyncDir(MemDir);
      Hits := Idx.Search(Query, K);
    finally
      Idx.Close;
    end;
  finally
    Cfg.Free;
  end;

  { Emit as JSON. Manual emission so we don't drag in a builder for
    one object -- the shape is fixed and small. }
  Write('{"hits":[');
  First := True;
  for i := 0 to High(Hits) do
  begin
    if not First then Write(',');
    First := False;
    Write(Format('{"path":"%s","score":%.6f,"snippet":"%s"}',
                 [JsonEscape(Hits[i].Path),
                  Hits[i].Score,
                  JsonEscape(Hits[i].Snippet)]));
  end;
  Writeln(']}');
end.
