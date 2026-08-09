(*
  PasClaw.Session.Port -- import foreign chat exports as PasClaw sessions,
  and export sessions in portable shapes.

  There is no formal interchange standard for chat transcripts; the de-facto
  one is the OpenAI-style messages array -- which is exactly what
  PasClaw.Session.Store already persists. So "export" is largely our native
  file, and "import" is normalizing other vendors' shapes into it. Same
  approach as LibreChat / Open WebUI: accept the source's own export file,
  auto-detect, convert.

  Supported imports (DetectImportFormat):

    ifChatGPT      ChatGPT "Export data" -> conversations.json. A JSON ARRAY
                   of conversations; each carries a "mapping" tree of nodes
                   (id -> node with message/parent/children) plus
                   "current_node". The visible transcript is the parent-chain
                   walk from current_node back to the root, reversed. Only
                   user/assistant text turns are imported: ChatGPT tool/system
                   nodes are internal plumbing, and importing bare tool turns
                   would produce transcripts invalid to resume against
                   providers (tool msgs need their assistant tool_call pair).
                   One conversation -> one PasClaw session.

    ifClaudeJSONL  Claude Code session transcript (.jsonl, one JSON object
                   per line: type user/assistant with a nested "message"
                   whose content is either a string or an array of typed
                   blocks). Text blocks are imported; tool_use / tool_result
                   blocks are skipped for the same resume-validity reason.
                   A leading summary line becomes the title.
                   One file -> one PasClaw session.

    ifNative       A PasClaw session export (object with a "messages" array,
                   as produced by `pasclaw session export` / the gateway).
                   Re-imported under a fresh id via TSession.LoadFromText,
                   which preserves meta (title/model) AND rich turns --
                   assistant tool_calls with their tool_call_id pairings --
                   so the copy stays valid to resume against providers.

  Exports:

    - native JSON: the session file itself (Session.Store's shape) -- read it
      with SessionPath/ReadFileText; nothing to convert.
    - ExportSessionMarkdown: a human-readable transcript (title header +
      role-labelled turns), for sharing outside PasClaw.

  Imported sessions land in the normal store, so session_search / session_read
  see them immediately.
*)
unit PasClaw.Session.Port;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

type
  TImportFormat = (ifUnknown, ifChatGPT, ifClaudeJSONL, ifNative);
  TImportedIds  = array of string;

{ Sniff which known export shape Text is. }
function DetectImportFormat(const Text: string): TImportFormat;

{ Human name for a format ("chatgpt", "claude-code", "pasclaw", "unknown"). }
function ImportFormatName(F: TImportFormat): string;

{ Import every conversation found in Text into the session store. Returns the
  number of sessions created (their new ids in Ids). 0 with Err set on a
  malformed / unrecognized file; 0 with Err='' when the file was valid but
  held no importable conversations. }
function ImportSessions(const Text: string; out Ids: TImportedIds;
                        out Err: string): Integer;

{ Render a saved session as a Markdown transcript. }
function ExportSessionMarkdown(const Id: string; out MD: string;
                               out Err: string): Boolean;

implementation

uses
  SysUtils, Classes,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Session.Store;

function ImportFormatName(F: TImportFormat): string;
begin
  case F of
    ifChatGPT:     Result := 'chatgpt';
    ifClaudeJSONL: Result := 'claude-code';
    ifNative:      Result := 'pasclaw';
  else             Result := 'unknown';
  end;
end;

{ First non-blank line of Text (for JSONL sniffing). }
function FirstLine(const Text: string): string;
var
  i, a: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(Text) do
  begin
    a := i;
    while (i <= Length(Text)) and (Text[i] <> #10) and (Text[i] <> #13) do Inc(i);
    Result := Trim(Copy(Text, a, i - a));
    if Result <> '' then Exit;
    while (i <= Length(Text)) and ((Text[i] = #10) or (Text[i] = #13)) do Inc(i);
  end;
end;

function DetectImportFormat(const Text: string): TImportFormat;
var
  T, FL: string;
  Arr: TJsonArray;
  Obj, First: TJsonObject;
begin
  Result := ifUnknown;
  T := Trim(Text);
  if T = '' then Exit;

  { ChatGPT: a JSON array whose first object has a "mapping" key (the same
    heuristic Open WebUI uses). }
  if T[1] = '[' then
  begin
    try Arr := TJsonArray.Parse(T); except Arr := nil; end;
    if Arr <> nil then
    try
      if Arr.Count > 0 then
      begin
        First := Arr.ItemObject(0);
        if First <> nil then
        try
          if First.Has('mapping') then Exit(ifChatGPT);
        finally
          First.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
    Exit;
  end;

  { Object root: PasClaw native export has a top-level "messages" array. }
  if T[1] = '{' then
  begin
    { A Claude Code transcript is JSONL, so the FIRST LINE alone must parse;
      a native session file is one pretty-printed object (first line '{'). }
    FL := FirstLine(T);
    try Obj := TJsonObject.Parse(FL); except Obj := nil; end;
    if Obj <> nil then
    try
      if Obj.Has('type') and (Obj.Has('message') or Obj.Has('summary')
         or Obj.Has('uuid')) then
        Exit(ifClaudeJSONL);
    finally
      Obj.Free;
    end;

    try Obj := TJsonObject.Parse(T); except Obj := nil; end;
    if Obj <> nil then
    try
      { Has() only -- ChildArray would allocate a wrapper we'd have to free. }
      if Obj.Has('messages') then Exit(ifNative);
    finally
      Obj.Free;
    end;
  end;
end;

{ Append M to Msgs. }
procedure PushMsg(var Msgs: TMessageArray; Role: TMsgRole; const Content: string);
begin
  SetLength(Msgs, Length(Msgs) + 1);
  Msgs[High(Msgs)] := MakeMessage(Role, Content);
end;

{ Persist Title+Msgs as a fresh session; returns the new id. CreatedAt is
  stamped from SrcCreated (unix seconds) when > 0. }
function SaveImported(const Title: string; const Msgs: TMessageArray;
                      SrcCreated: Int64; const SourceName: string): string;
var
  S: TSession;
begin
  S := TSession.Create('');   { generates a fresh id }
  try
    S.Meta.Title    := Title;
    S.Meta.Provider := 'import:' + SourceName;
    S.Messages      := Msgs;
    if SrcCreated > 0 then S.Meta.CreatedAt := SrcCreated;
    S.AutoTitle;              { derive from first user turn when Title = '' }
    S.Touch;
    S.Save;
    Result := S.Meta.Id;
  finally
    S.Free;
  end;
end;

{ ---- ChatGPT conversations.json ---- }

function ImportOneChatGPT(Conv: TJsonObject; out Id: string): Boolean;
{ NOTE on wrappers: ChildObject/ChildArray allocate a NEW wrapper object on
  every call (the wrapper does not own the backing JSON, which lives until the
  root document is freed) -- so every wrapper taken in these loops must be
  freed, or a large archive import leaks several objects per message in the
  long-running gateway. }
var
  Mapping, Node, Msg, Author, Content: TJsonObject;
  Parts: TJsonArray;
  Chain: TStringList;
  Msgs: TMessageArray;
  Cur, Role, Text, PartStr: string;
  i, p: Integer;
  Created: Int64;
begin
  Result := False;
  Id := '';
  Mapping := Conv.ChildObject('mapping');
  if Mapping = nil then Exit;
  try
    Cur := Conv.GetStr('current_node', '');
    if Cur = '' then Exit;

    { Parent-chain walk from the current node to the root = the transcript the
      user last saw (edited branches fall away). Guard against cycles with a
      hard depth cap. }
    Chain := TStringList.Create;
    try
      i := 0;
      while (Cur <> '') and (i < 100000) do
      begin
        Node := Mapping.ChildObject(Cur);
        if Node = nil then Break;
        try
          Chain.Add(Cur);
          Cur := Node.GetStr('parent', '');
        finally
          Node.Free;
        end;
        Inc(i);
      end;

      SetLength(Msgs, 0);
      for i := Chain.Count - 1 downto 0 do   { root first }
      begin
        Node := Mapping.ChildObject(Chain[i]);
        if Node = nil then Continue;
        try
          Msg := Node.ChildObject('message');
        finally
          Node.Free;
        end;
        if Msg = nil then Continue;
        try
          Author := Msg.ChildObject('author');
          if Author = nil then Continue;
          try
            Role := LowerCase(Author.GetStr('role', ''));
          finally
            Author.Free;
          end;
          if (Role <> 'user') and (Role <> 'assistant') then Continue;
          Content := Msg.ChildObject('content');
          if Content = nil then Continue;
          try
            { parts: strings for text turns; objects for multimodal (skipped --
              ItemStr yields '' for non-strings). }
            Text := '';
            Parts := Content.ChildArray('parts');
            if Parts <> nil then
            try
              for p := 0 to Parts.Count - 1 do
              begin
                PartStr := Parts.ItemStr(p, '');
                if PartStr = '' then Continue;
                if Text <> '' then Text := Text + sLineBreak;
                Text := Text + PartStr;
              end;
            finally
              Parts.Free;
            end;
          finally
            Content.Free;
          end;
          if Trim(Text) = '' then Continue;
          if Role = 'user' then PushMsg(Msgs, mrUser, Text)
          else                  PushMsg(Msgs, mrAssistant, Text);
        finally
          Msg.Free;
        end;
      end;
    finally
      Chain.Free;
    end;

    if Length(Msgs) = 0 then Exit;
    Created := Trunc(Conv.GetFloat('create_time', 0));
    Id := SaveImported(Conv.GetStr('title', ''), Msgs, Created, 'chatgpt');
    Result := True;
  finally
    Mapping.Free;
  end;
end;

function ImportChatGPT(const Text: string; out Ids: TImportedIds;
                       out Err: string): Integer;
var
  Arr: TJsonArray;
  Conv: TJsonObject;
  i: Integer;
  NewId: string;
begin
  Result := 0;
  SetLength(Ids, 0);
  Err := '';
  try Arr := TJsonArray.Parse(Trim(Text)); except Arr := nil; end;
  if Arr = nil then begin Err := 'not a JSON array (expected conversations.json)'; Exit; end;
  try
    for i := 0 to Arr.Count - 1 do
    begin
      Conv := Arr.ItemObject(i);
      if Conv = nil then Continue;
      try
        if ImportOneChatGPT(Conv, NewId) then
        begin
          SetLength(Ids, Length(Ids) + 1);
          Ids[High(Ids)] := NewId;
          Inc(Result);
        end;
      finally
        Conv.Free;
      end;
    end;
  finally
    Arr.Free;
  end;
end;

{ ---- Claude Code .jsonl ---- }

function ImportClaudeJSONL(const Text: string; out Ids: TImportedIds;
                           out Err: string): Integer;
var
  Lines: TStringList;
  Obj, Msg, Block: TJsonObject;
  Blocks: TJsonArray;
  Msgs: TMessageArray;
  Kind, Role, Body, Title, BlockText: string;
  i, b: Integer;
begin
  Result := 0;
  SetLength(Ids, 0);
  Err := '';
  Title := '';
  SetLength(Msgs, 0);

  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for i := 0 to Lines.Count - 1 do
    begin
      if Trim(Lines[i]) = '' then Continue;
      try Obj := TJsonObject.Parse(Lines[i]); except Obj := nil; end;
      if Obj = nil then Continue;   { tolerate stray/garbled lines }
      try
        Kind := Obj.GetStr('type', '');
        if (Kind = 'summary') and (Title = '') then
        begin
          Title := Obj.GetStr('summary', '');
          Continue;
        end;
        if (Kind <> 'user') and (Kind <> 'assistant') then Continue;
        Msg := Obj.ChildObject('message');
        if Msg = nil then Continue;
        try
          Role := LowerCase(Msg.GetStr('role', Kind));

          { content: plain string, or an array of typed blocks -- keep the text
            blocks, skip tool_use / tool_result (no valid tool_call pairing
            survives an import). }
          Body := Msg.GetStr('content', '');
          if Body = '' then
          begin
            Blocks := Msg.ChildArray('content');
            if Blocks <> nil then
            try
              for b := 0 to Blocks.Count - 1 do
              begin
                Block := Blocks.ItemObject(b);
                if Block = nil then Continue;
                try
                  if Block.GetStr('type', '') = 'text' then
                  begin
                    BlockText := Block.GetStr('text', '');
                    if BlockText = '' then Continue;
                    if Body <> '' then Body := Body + sLineBreak;
                    Body := Body + BlockText;
                  end;
                finally
                  Block.Free;
                end;
              end;
            finally
              Blocks.Free;
            end;
          end;
        finally
          Msg.Free;
        end;
        if Trim(Body) = '' then Continue;
        if Role = 'user' then PushMsg(Msgs, mrUser, Body)
        else                  PushMsg(Msgs, mrAssistant, Body);
      finally
        Obj.Free;
      end;
    end;
  finally
    Lines.Free;
  end;

  if Length(Msgs) = 0 then
  begin
    Err := 'no user/assistant text turns found in the transcript';
    Exit;
  end;
  SetLength(Ids, 1);
  Ids[0] := SaveImported(Title, Msgs, 0, 'claude-code');
  Result := 1;
end;

{ ---- PasClaw native export ---- }

function ImportNative(const Text: string; out Ids: TImportedIds;
                      out Err: string): Integer;
var
  S: TSession;
  NewId: string;
begin
  Result := 0;
  SetLength(Ids, 0);
  Err := '';
  { The session-file deserializer, NOT ChatBodyToMessages: a native export
    carries meta (title/model/...) under "meta" and rich turns -- assistant
    tool_calls with their tool_call_id pairings -- that the flattened
    gateway-body parser would strip, leaving orphaned tool turns that make
    provider resume requests invalid. LoadFromText keeps all of it. }
  S := TSession.Create('');          { generates the fresh id up front }
  try
    NewId := S.Meta.Id;
    if not S.LoadFromText(Text) then
    begin
      Err := 'not a valid PasClaw session file';
      Exit;
    end;
    if Length(S.Messages) = 0 then
    begin
      Err := 'no messages in the session file';
      Exit;
    end;
    { NEVER keep the source id -- an import must create a copy, not
      overwrite the original session. }
    S.Meta.Id       := NewId;
    S.Meta.Provider := 'import:pasclaw';
    S.AutoTitle;
    S.Touch;
    S.Save;
    SetLength(Ids, 1);
    Ids[0] := NewId;
    Result := 1;
  finally
    S.Free;
  end;
end;

function ImportSessions(const Text: string; out Ids: TImportedIds;
                        out Err: string): Integer;
var
  F: TImportFormat;
begin
  SetLength(Ids, 0);
  Err := '';
  F := DetectImportFormat(Text);
  case F of
    ifChatGPT:     Result := ImportChatGPT(Text, Ids, Err);
    ifClaudeJSONL: Result := ImportClaudeJSONL(Text, Ids, Err);
    ifNative:      Result := ImportNative(Text, Ids, Err);
  else
    begin
      Result := 0;
      Err := 'unrecognized format -- expected ChatGPT conversations.json, a ' +
             'Claude Code .jsonl transcript, or a PasClaw session export';
    end;
  end;
  if Result > 0 then
    LogInfo('session import: %d session(s) from %s export',
            [Result, ImportFormatName(F)]);
end;

function ExportSessionMarkdown(const Id: string; out MD: string;
                               out Err: string): Boolean;
var
  S: TSession;
  Lines: TStringList;
  i: Integer;
  RoleStr, Body: string;
begin
  Result := False;
  MD := '';
  Err := '';
  if not IsSafeSessionId(Id) then
  begin Err := 'invalid session id: ' + Id; Exit; end;
  S := TSession.Create(Id);
  try
    if not S.MetaExists then
    begin Err := 'no such session: ' + Id; Exit; end;
    Lines := TStringList.Create;
    try
      if S.Meta.Title <> '' then Lines.Add('# ' + S.Meta.Title)
      else                       Lines.Add('# Session ' + S.Meta.Id);
      Lines.Add('');
      Lines.Add(Format('_session %s · model %s_', [S.Meta.Id, S.Meta.Model]));
      Lines.Add('');
      for i := 0 to High(S.Messages) do
      begin
        if S.Messages[i].Role = mrSystem then Continue;
        RoleStr := MsgRoleToString(S.Messages[i].Role);
        Body := S.Messages[i].Content;
        if (Body = '') and (Length(S.Messages[i].ToolCalls) > 0) then
          Body := '_(tool call: ' + S.Messages[i].ToolCalls[0].Func.Name + ')_';
        if Trim(Body) = '' then Continue;
        Lines.Add('## ' + RoleStr);
        Lines.Add('');
        Lines.Add(Body);
        Lines.Add('');
      end;
      MD := Lines.Text;
    finally
      Lines.Free;
    end;
    Result := True;
  finally
    S.Free;
  end;
end;

end.
