(*
  PasClaw.Tools.Memory - registers the memory_search tool.

  Workflow (openclaw-style):
    - The model writes durable NOTES by editing MEMORY.md or a daily
      file workspace/memory/YYYY-MM-DD.md with the existing fs_write
      tool. There is intentionally no memory_add tool for those -- files
      are the source of truth, the index follows.
    - memory_write is the exception, and it targets the other corpus: the
      fact store, which has no file behind it. Until now the ONLY way in
      was auto-distillation of PasClaw's own transcripts, so a fact could
      not be recorded deliberately, and an external MCP client could read
      the store (memory_search is tcReadOnly and the MCP server exposes
      it) but never contribute to it. memory_write is tcMutating, so plan
      mode refuses it and the MCP server exposes it only under
      --mcp-allow-write -- a foreign host writing the operator's memory is
      an explicit decision, not a default.
    - memory_search opens the lazy FTS5 index over workspace/memory/,
      syncs it against the current files (rebuilding rows for any file
      whose mtime moved), and runs an FTS5 MATCH against the user's
      query. Returns up to K hits as
        path | bm25 score | highlighted snippet
      one per line, smallest score first.

  The DB lives at <home>/workspace/memory/.index.db. A failed open
  degrades to "memory_search: index unavailable" -- the rest of the
  agent continues to function. The reported reason comes from the
  driver exception (via IMemoryIndex.LastError), not from a guess:
  the cause is a missing shared library only on the builds that link
  SQLite dynamically, and an unwritable path or corrupt file on the
  Delphi targets that link it statically.
*)
unit PasClaw.Tools.Memory;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

procedure RegisterMemoryTools(R: TToolRegistry);

implementation

uses
  PasClaw.Workspaces,
  Classes,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Logger,
  PasClaw.Memory.Index,
  PasClaw.Memory.Vector,
  PasClaw.Memory.Facts,   { distilled-fact search (Phase 4b) + memory_write }
  PasClaw.Memory.Distill, { TFact -- the record memory_write builds }
  DateUtils,              { DateTimeToUnix for the fact's created_at }
  PasClaw.Promptware;     { injection scan on recalled snippets -- chokepoint 2 }

function ParseStringArg(const ArgsJSON, Field: string; out V: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  V := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      V := Obj.GetStr(Field, '');
      Result := V <> '';
    finally
      Obj.Free;
    end;
  except
    Result := False;
  end;
end;

function ParseIntArg(const ArgsJSON, Field: string; Default: Integer): Integer;
var
  Obj: TJsonObject;
begin
  Result := Default;
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      if Obj.Has(Field) then Result := Obj.GetInt(Field, Default);
    finally
      Obj.Free;
    end;
  except
    Result := Default;
  end;
end;

function MemoryDir: string;
begin
  Result := JoinPath(GetHome, ActiveWorkspaceName + '/memory');
end;

function IndexDbPath: string;
begin
  Result := JoinPath(MemoryDir, '.index.db');
end;

function Tool_MemorySearch(const ArgsJSON: string; out ErrMsg: string): string;
const
  DefaultK = 5;
  MaxK     = 25;
var
  Query: string;
  K, i:  Integer;
  Idx:   IMemoryIndex;
  Hits:  TMemoryHitArray;
  Lines: TStringList;
  Dir:   string;
  Cfg:   TConfig;
  UseVector, DistillOn, IndexFailed: Boolean;
  MdText, FactText, OpenErr: string;
  FactHits: TStoredFactArray;
begin
  ErrMsg := '';
  Result := '';

  if not ParseStringArg(ArgsJSON, 'query', Query) then
  begin
    ErrMsg := 'missing required argument: query';
    Exit;
  end;
  K := ParseIntArg(ArgsJSON, 'k', DefaultK);
  if K < 1   then K := 1;
  if K > MaxK then K := MaxK;

  Dir := MemoryDir;
  if not DirectoryExists(Dir) then
    Exit('(no memory directory yet -- write to ' + JoinPath(Dir, 'MEMORY.md') +
         ' first)');

  { Backend selection -- try the hybrid FTS+vector backend first when
    the operator opted in via `pasclaw onboard` / `vector_search_enabled`
    (default True). On any "not provisioned yet" failure (missing
    sqlite-vec, missing ONNX Runtime, missing embedding model) Open()
    returns False quietly and we fall through to NewMemoryIndex, which
    is the FTS5-only path PasClaw has shipped since memory_search
    landed. Operators on stock builds without the runtime artifacts
    on disk get the same behaviour they did before: keyword search.

    Separate DB filenames (.index.db vs .index.db.vec) so flipping
    vector_search_enabled on/off doesn't cross-talk between the two
    schemas in one file. Both backends live alongside each other on
    disk; only one is opened per call. The vector DB file is created
    on first SyncDir after provisioning lands; until then it doesn't
    exist and isn't touched. }
  Cfg := LoadEffectiveConfig;
  try
    UseVector := Cfg.VectorSearchEnabled;
    DistillOn := Cfg.MemoryDistillEnabled;
  finally
    Cfg.Free;
  end;

  if UseVector then
  begin
    Idx := NewVectorMemoryIndex;
    if not Idx.Open(IndexDbPath + '.vec') then
      Idx := nil;  { releases the interface; falls through to FTS }
  end;

  IndexFailed := False;
  if Idx = nil then
  begin
    Idx := NewMemoryIndex;
    if not Idx.Open(IndexDbPath) then
    begin
      { Read the reason BEFORE dropping the reference -- releasing the
        interface destroys the object that holds it. }
      OpenErr := Idx.LastError;
      Idx := nil;
      { Index unavailable. If distilled facts are on, remember the failure
        and fall through so the fact store can still answer; otherwise this
        is a hard error (unchanged behaviour). The failure is NOT silently
        dropped -- it's reported below if facts don't produce results, and
        flagged as a partial search if they do. }
      if not DistillOn then
      begin
        ErrMsg := 'memory index unavailable (' +
                  SqliteOpenFailureReason(OpenErr) + ')';
        Exit;
      end;
      IndexFailed := True;
    end;
  end;

  if Idx <> nil then
  try
    Idx.SyncDir(Dir);
    Hits := Idx.Search(Query, K);
  finally
    Idx := nil;  { IInterface release closes the DB }
  end;

  { ----- .md note hits ----- }
  MdText := '';
  if Length(Hits) > 0 then
  begin
    Lines := TStringList.Create;
    try
      Lines.Add(Format('%d match(es) for %s:', [Length(Hits), Query]));
      Lines.Add('');
      for i := 0 to High(Hits) do
      begin
        Lines.Add(Format('%s  (bm25=%.3f)', [Hits[i].Path, Hits[i].Score]));
        Lines.Add('  ' + Hits[i].Snippet);
        if i < High(Hits) then Lines.Add('');
      end;
      MdText := Lines.Text;
    finally
      Lines.Free;
    end;
  end;

  { ----- distilled-fact hits (Phase 4b) ----- }
  FactText := '';
  if DistillOn then
  begin
    FactHits := SearchActiveFacts(GetHome,
                  FormatDateTime('yyyy"-"mm"-"dd', Now), Query, K);
    if Length(FactHits) > 0 then
    begin
      Lines := TStringList.Create;
      try
        Lines.Add(Format('%d distilled fact(s) for %s:', [Length(FactHits), Query]));
        for i := 0 to High(FactHits) do
        begin
          if FactHits[i].Expires <> '' then
            Lines.Add(Format('- %s (until %s)', [FactHits[i].Text, FactHits[i].Expires]))
          else
            Lines.Add('- ' + FactHits[i].Text);
        end;
        FactText := Lines.Text;
      finally
        Lines.Free;
      end;
    end;
  end;

  if (MdText = '') and (FactText = '') then
  begin
    { Nothing to return. If the markdown index never opened, that's the
      real reason -- report it as unavailable rather than a misleading
      "no matches" (the notes were never searched). }
    if IndexFailed then
      ErrMsg := 'memory index unavailable (' +
                SqliteOpenFailureReason(OpenErr) + '); ' +
                'no matching distilled facts either'
    else
      Result := Format('(no matches for %s in %s)', [Query, Dir]);
    Exit;
  end;

  Result := MdText;
  if FactText <> '' then
  begin
    if Result <> '' then Result := Result + sLineBreak;
    Result := Result + FactText;
  end;
  { Facts answered but the markdown index was down -- tell the model this
    was a partial search so it doesn't assume the notes were checked. }
  if IndexFailed then
    Result := '(note: markdown memory index unavailable -- searched ' +
              'distilled facts only)' + sLineBreak + Result;

  { Promptware chokepoint 2 of 3: recalled memory. Snippets were
    written on earlier turns -- possibly copied from attacker-supplied
    content the model summarised into a daily note -- so they re-enter
    the context as if they were the agent's own trusted notes. Label
    the scan source explicitly (the generic tool-output scan in the
    tool loop would catch this too, but "recalled memory" tells the
    model WHICH trust boundary the content crossed; the banner-mark
    idempotence guard stops the loop from double-wrapping). }
  Result := MaybeFlagPromptware(Result, 'recalled memory (memory_search)');

  LogDebug('memory_search query=%s k=%d hits=%d', [Query, K, Length(Hits)]);
end;

(* Accept 'YYYY-MM-DD' or ''. Rejecting a malformed date at the tool
   boundary matters more than usual here: expires drives whether a fact is
   ever shown again, so a date the store cannot compare would either hide
   the fact forever or never expire it, with no error either way. *)
function ValidDateArg(const S: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if S = '' then Exit(True);
  if Length(S) <> 10 then Exit;
  if (S[5] <> '-') or (S[8] <> '-') then Exit;
  for i := 1 to 10 do
    if (i <> 5) and (i <> 8) and ((S[i] < '0') or (S[i] > '9')) then Exit;
  Result := True;
end;

function Tool_MemoryWrite(const ArgsJSON: string; out ErrMsg: string): string;
const
  MaxTextLen = 2000;   { a fact is a sentence; a document belongs in a note }
var
  F: TFact;
  Cfg: TConfig;
  Store: IFactStore;
  Origin: string;
  Id: Int64;
  DistillOn: Boolean;
begin
  ErrMsg := '';
  Result := '';

  if not ParseStringArg(ArgsJSON, 'text', F.Text) then
  begin
    ErrMsg := 'missing required argument: text';
    Exit;
  end;
  F.Text := Trim(F.Text);
  if F.Text = '' then
  begin
    ErrMsg := 'text must not be empty';
    Exit;
  end;
  if Length(F.Text) > MaxTextLen then
  begin
    ErrMsg := Format('text is %d chars; the fact store holds sentences, ' +
                     'not documents (max %d). Write long-form content to ' +
                     'a note under workspace/memory/ instead.',
                     [Length(F.Text), MaxTextLen]);
    Exit;
  end;

  (* The fields below are validated strictly rather than passed through
     PasClaw.Memory.Distill.NormaliseFact. That helper silently coerces --
     an unparseable expires becomes "never expires", a bad kind becomes
     "dynamic" -- which is right for a distiller salvaging a model's JSON,
     where one bad field must not lose the whole pass. It is wrong for a
     tool: a caller that asks for expires="tomorrow" and is told the write
     succeeded has no way to learn its fact will never expire. *)
  if not ParseStringArg(ArgsJSON, 'kind', F.Kind) then F.Kind := '';
  if F.Kind = '' then F.Kind := 'static';
  if (F.Kind <> 'static') and (F.Kind <> 'dynamic') then
  begin
    ErrMsg := 'kind must be "static" or "dynamic"';
    Exit;
  end;

  if not ParseStringArg(ArgsJSON, 'scope', F.Scope) then F.Scope := '';
  if F.Scope = '' then F.Scope := 'project';
  if (F.Scope <> 'user') and (F.Scope <> 'project') and (F.Scope <> 'session') then
  begin
    ErrMsg := 'scope must be "user", "project" or "session"';
    Exit;
  end;

  if not ParseStringArg(ArgsJSON, 'expires', F.Expires) then F.Expires := '';
  if not ParseStringArg(ArgsJSON, 'event_date', F.EventDate) then F.EventDate := '';
  if not ValidDateArg(F.Expires) then
  begin
    ErrMsg := 'expires must be YYYY-MM-DD (or omitted)';
    Exit;
  end;
  if not ValidDateArg(F.EventDate) then
  begin
    ErrMsg := 'event_date must be YYYY-MM-DD (or omitted)';
    Exit;
  end;

  (* Confidence is fixed rather than caller-supplied. It ranks facts
     against each other, and a caller that can set its own rank can float
     to the top of every recall by asserting 1.0 -- which matters because
     the writer may be a different agent entirely. An explicitly written
     fact outranks a distilled guess, and that is the whole ordering this
     tool needs. *)
  F.Confidence := 0.95;

  (* Provenance. source_session already records WHERE a distilled fact came
     from; an explicit write records WHO asked for it, which is the
     question that matters once more than one agent can write here. The
     prefix is not a security boundary -- a caller can claim any origin --
     it is an audit trail for a human reading `pasclaw memory export`. *)
  if not ParseStringArg(ArgsJSON, 'source', Origin) then Origin := '';
  Origin := Trim(Origin);
  if Origin = '' then Origin := 'agent';
  F.SourceSession := 'written:' + Origin;

  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(GetHome)) then
  begin
    { The driver's own reason, via SqliteOpenFailureReason -- which falls
      back to the platform hint itself when the driver said nothing useful.
      Reaching straight for that fallback is the mistake the test-sqlite-hint
      structural guard exists to catch, and it caught this call site;
      IFactStore.LastError was added so the honest answer is available. }
    ErrMsg := 'cannot open the fact store at ' + DefaultFactsDbPath(GetHome) +
              ' (' + SqliteOpenFailureReason(Store.LastError) + ')';
    Exit;
  end;
  try
    { (Now, False) -- False means "this DateTime is local", which is what
      Now returns. Every other fact writer passes it; the default treats
      local time as UTC and skews created_at by the host's offset. }
    Id := Store.Add(F, DateTimeToUnix(Now, False));
  finally
    Store.Close;
  end;
  if Id = 0 then
  begin
    ErrMsg := 'fact store rejected the write';
    Exit;
  end;

  Result := Format('stored fact #%d (kind=%s scope=%s)', [Id, F.Kind, F.Scope]);
  if F.Expires <> '' then Result := Result + ' expires=' + F.Expires;
  if F.EventDate <> '' then Result := Result + ' event=' + F.EventDate;

  (* Both the prompt block and memory_search's fact half are gated on
     MemoryDistillEnabled. With it off the row is written and durable but
     nothing will ever surface it, so say so -- reporting a bare success
     would be a lie of omission the caller cannot detect. *)
  Cfg := LoadEffectiveConfig;   { profile-layered, and owned by us }
  try
    DistillOn := Cfg.MemoryDistillEnabled;
  finally
    Cfg.Free;
  end;
  if not DistillOn then
    Result := Result + sLineBreak +
      '(note: memory_distill_enabled is false in config.json, so stored ' +
      'facts are not injected into the prompt and memory_search will not ' +
      'return them. The row is saved and will surface once it is enabled.)';

  LogDebug('memory_write id=%d kind=%s scope=%s origin=%s',
           [Id, F.Kind, F.Scope, Origin]);
end;

procedure RegisterMemoryTools(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;
  T.Name        := 'memory_search';
  T.Description :=
    'Search workspace memory: the markdown notes (MEMORY.md + ' +
    'workspace/memory/*.md, SQLite FTS5 BM25) AND, when distilled memory ' +
    'is enabled, the auto-distilled fact store. Use this before answering ' +
    'questions about prior conversations, the user''s preferences, or ' +
    'project facts from an earlier turn. Returns up to k note matches ' +
    '(path + snippet + score) plus matching distilled facts.';
  T.Schema      :=
    '{"type":"object",' +
    '"properties":{' +
    '"query":{"type":"string","description":"FTS5 query string. Supports plain words, AND/OR/NOT, ' +
                '\"phrase\" quoting, and prefix^ matching."},' +
    '"k":{"type":"integer","minimum":1,"maximum":25,"description":"Max results (default 5)."}' +
    '},"required":["query"]}';
  T.Handler     := Tool_MemorySearch;
  T.IsCore      := True;
  { tcReadOnly from the CALLER's point of view -- it answers a question and
    changes nothing the user owns -- which is what the plan-mode gate and
    the read-only MCP server care about. }
  T.Category    := tcReadOnly;
  { ...but not from the DISK's: SyncDir reindexes and deletes rows in
    .index.db, so this must never share a parallel batch. That is declared
    once in ToolIsSerialOnly (PasClaw.Tools.Types) and applied by the
    registry -- setting it here would be an uninitialised-field hazard in
    reverse, since most registration sites never assign the field at all. }
  R.Register(T);

  T := Default(TTool);
  T.Name        := 'memory_write';
  T.Description :=
    'Record one durable fact in the distilled-memory store: a decision, a ' +
    'preference, a project constraint -- something that should still be ' +
    'true next session. One sentence per call; state it so it reads ' +
    'correctly with no surrounding context. Near-identical facts are ' +
    'folded into the existing row rather than duplicated. For long-form ' +
    'content write a note under workspace/memory/ with write_file ' +
    'instead -- files are the source of truth for notes, this store is ' +
    'for single facts. Set expires for anything that stops being true on ' +
    'a known date.';
  T.Schema      :=
    '{"type":"object",' +
    '"properties":{' +
    '"text":{"type":"string","description":"The fact, as one self-contained sentence."},' +
    '"kind":{"type":"string","enum":["static","dynamic"],' +
      '"description":"static = unlikely to change; dynamic = expected to change. Default static."},' +
    '"scope":{"type":"string","enum":["user","project","session"],' +
      '"description":"Who the fact is about. Default project."},' +
    '"expires":{"type":"string","description":"YYYY-MM-DD after which the fact stops being shown."},' +
    '"event_date":{"type":"string","description":"YYYY-MM-DD the fact is ABOUT, for proactive surfacing."},' +
    '"source":{"type":"string","description":"Who is recording this (e.g. the client name). Recorded for audit."}' +
    '},"required":["text"]}';
  T.Handler     := Tool_MemoryWrite;
  T.IsCore      := True;
  { Mutating: it changes durable state the user owns. That is what makes
    plan mode refuse it and keeps it off the MCP surface unless the
    operator passed --mcp-allow-write. }
  T.Category    := tcMutating;
  R.Register(T);
end;

end.
