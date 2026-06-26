(*
  PasClaw.Memory.Distill -- Phase 1 of the distilled-memory system.

  Turns a raw conversation transcript into a small set of durable,
  structured FACTS using one LLM pass -- the "write side" PasClaw was
  missing (today's NDJSON session logs are never distilled; notes must
  be hand-written). This is the extraction step ONLY:

      transcript (TMessageArray)  --LLM-->  TFact[]

  It is deliberately storage-agnostic. Persistence (a SQLite fact table
  + sqlite-vec sidecar), dedup/contradiction/expiry reconciliation, and
  retrieval/injection land in later phases. Keeping extraction pure
  makes it trivially testable with a scripted provider -- no model, no
  database, no I/O.

  A fact:

    { "text": "User prefers Delphi over Lazarus",
      "kind": "static" | "dynamic",          // stable trait vs current focus
      "scope": "user" | "project" | "session",
      "confidence": 0.0 .. 1.0,
      "expires": "YYYY-MM-DD" | "" }          // temporary facts self-expire

  The model is asked to return ONLY a JSON object {"facts":[...]}; we
  parse leniently (strip code fences, slice the outer object) and
  normalise every field so a sloppy model can't produce a malformed
  fact. Facts that are empty after trimming are dropped; duplicates
  within the batch (case-insensitive text) collapse to the first.
*)
unit PasClaw.Memory.Distill;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf;

type
  TFact = record
    Text:          string;
    Kind:          string;   { 'static' | 'dynamic' }
    Scope:         string;   { 'user' | 'project' | 'session' }
    Confidence:    Double;   { 0..1 }
    Expires:       string;   { 'YYYY-MM-DD' or '' }
    SourceSession: string;
  end;
  TFactArray = array of TFact;

  TMemoryDistiller = class
  private
    FProvider: ILLMProvider;
    FModel:    string;
    FMaxChars: Integer;   { transcript byte budget handed to the model }
    function BuildSystemPrompt(const Today: string): string;
    function RenderTranscript(const Transcript: array of TMessage): string;
    function ParseFacts(const Raw, SessionId: string): TFactArray;
  public
    constructor Create(AProvider: ILLMProvider; const AModel: string);
    { Extract facts from Transcript. Today ('YYYY-MM-DD') is injected so
      the model can resolve relative dates ("tomorrow") into Expires; pass
      it explicitly so the extraction is deterministic/testable. Returns
      False with ErrMsg on a provider/parse failure (Facts is then empty). }
    function Distill(const Transcript: array of TMessage;
                     const SessionId, Today: string;
                     out Facts: TFactArray; out ErrMsg: string): Boolean;
    property MaxTranscriptChars: Integer read FMaxChars write FMaxChars;
  end;

{ Lenient extractor: returns the outermost brace-delimited JSON object
  found in S (after stripping ``` fences), or '' if none. For testing. }
function SliceJsonObject(const S: string): string;

{ Normalise a single raw fact's fields in place (kind/scope/confidence/
  expires). Exposed for testing. }
procedure NormaliseFact(var F: TFact);

implementation

uses
  PasClaw.JSON;

const
  KindStatic  = 'static';
  KindDynamic = 'dynamic';
  DefaultMaxTranscriptChars = 16000;

constructor TMemoryDistiller.Create(AProvider: ILLMProvider; const AModel: string);
begin
  inherited Create;
  FProvider := AProvider;
  FModel    := AModel;
  FMaxChars := DefaultMaxTranscriptChars;
end;

function TMemoryDistiller.BuildSystemPrompt(const Today: string): string;
begin
  Result :=
    'You distil durable MEMORY from a conversation. Read the transcript and '   + sLineBreak +
    'extract a SMALL set of facts worth remembering across future sessions: '   + sLineBreak +
    'stable user/project traits, decisions, preferences, and current focus. '   + sLineBreak +
    'Ignore one-off chatter, tool noise, and anything already obvious.'         + sLineBreak +
    sLineBreak +
    'Today is ' + Today + '. Resolve relative dates against it.'                + sLineBreak +
    sLineBreak +
    'For each fact set:'                                                        + sLineBreak +
    '  text       a single concise sentence, self-contained.'                  + sLineBreak +
    '  kind       "static" for stable traits, "dynamic" for current focus.'    + sLineBreak +
    '  scope      "user", "project", or "session".'                            + sLineBreak +
    '  confidence 0.0-1.0, how sure you are.'                                   + sLineBreak +
    '  expires    "YYYY-MM-DD" for temporary facts ("exam tomorrow"), else "".'+ sLineBreak +
    sLineBreak +
    'Return ONLY a JSON object, no prose, no code fence:'                       + sLineBreak +
    '{"facts":[{"text":"...","kind":"static","scope":"user",'                   +
    '"confidence":0.9,"expires":""}]}'                                          + sLineBreak +
    'If nothing is worth remembering, return {"facts":[]}.';
end;

function TMemoryDistiller.RenderTranscript(const Transcript: array of TMessage): string;
var
  i: Integer;
  Line, Acc: string;
  Budget: Integer;
begin
  { Build from the TAIL backwards so that when we hit the byte budget we
    keep the most recent exchanges (most relevant for "current focus"). }
  Acc    := '';
  Budget := FMaxChars;
  for i := High(Transcript) downto 0 do
  begin
    if Trim(Transcript[i].Content) = '' then Continue;
    Line := MsgRoleToString(Transcript[i].Role) + ': ' +
            Transcript[i].Content + sLineBreak;
    if Length(Line) > Budget then
    begin
      { This entry overflows the remaining budget. If we've added nothing
        yet -- the newest message alone is bigger than the whole budget,
        common for a large tool result saved last -- keep a truncated head
        so the model still gets recent context instead of an empty string
        (which would make Distill silently return zero facts). }
      if (Acc = '') and (Budget > 0) then
        Acc := Copy(Line, 1, Budget);
      Break;
    end;
    Acc    := Line + Acc;
    Budget := Budget - Length(Line);
  end;
  Result := Acc;
end;

function SliceJsonObject(const S: string): string;
var
  T: string;
  i, j: Integer;
begin
  Result := '';
  T := Trim(S);
  { Strip a leading ```json / ``` fence and a trailing ``` if present. }
  if Copy(T, 1, 3) = '```' then
  begin
    i := Pos(#10, T);
    if i > 0 then T := Copy(T, i + 1, MaxInt);
    j := Pos('```', T);
    if j > 0 then T := Copy(T, 1, j - 1);
    T := Trim(T);
  end;
  i := Pos('{', T);
  if i <= 0 then Exit;
  for j := Length(T) downto i do
    if T[j] = '}' then
    begin
      Result := Copy(T, i, j - i + 1);
      Exit;
    end;
end;

procedure NormaliseFact(var F: TFact);
var
  K, Sc: string;
begin
  F.Text := Trim(F.Text);

  K := LowerCase(Trim(F.Kind));
  if (K <> KindStatic) and (K <> KindDynamic) then K := KindDynamic;
  F.Kind := K;

  Sc := LowerCase(Trim(F.Scope));
  if (Sc <> 'user') and (Sc <> 'project') and (Sc <> 'session') then Sc := 'user';
  F.Scope := Sc;

  if F.Confidence < 0 then F.Confidence := 0
  else if F.Confidence > 1 then F.Confidence := 1;

  F.Expires := Trim(F.Expires);
  { Accept only a plausible YYYY-MM-DD; anything else means "no expiry". }
  if (Length(F.Expires) <> 10) or (F.Expires[5] <> '-') or (F.Expires[8] <> '-') then
    F.Expires := '';
end;

function TMemoryDistiller.ParseFacts(const Raw, SessionId: string): TFactArray;
var
  Json, Body: string;
  Root: TJsonObject;
  Arr: TJsonArray;
  Obj: TJsonObject;
  i: Integer;
  F: TFact;
  Seen: TStringList;
begin
  Result := nil;
  Json := SliceJsonObject(Raw);
  if Json = '' then Exit;
  { Lenient parse: the model can emit brace characters that don't form
    valid JSON (stray braces in prose). TJsonObject.Parse RAISES on
    those, so swallow it and treat the reply as "no facts" rather than
    letting the exception escape Distill (which only wraps the provider
    call) and abort the caller. }
  Root := nil;
  try
    Root := TJsonObject.Parse(Json);
  except
    Root := nil;
  end;
  if Root = nil then Exit;
  Seen := TStringList.Create;
  try
    Seen.CaseSensitive := False;
    Arr := Root.ChildArray('facts');
    if Arr = nil then Exit;
    for i := 0 to Arr.Count - 1 do
    begin
      Obj := Arr.ItemObject(i);
      if Obj = nil then Continue;
      F.Text          := Obj.GetStr('text', '');
      F.Kind          := Obj.GetStr('kind', '');
      F.Scope         := Obj.GetStr('scope', '');
      F.Confidence    := Obj.GetFloat('confidence', 0.5);
      F.Expires       := Obj.GetStr('expires', '');
      F.SourceSession := SessionId;
      NormaliseFact(F);
      if F.Text = '' then Continue;
      Body := LowerCase(F.Text);
      if Seen.IndexOf(Body) >= 0 then Continue;   { dedup within the batch }
      Seen.Add(Body);
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := F;
    end;
  finally
    Seen.Free;
    Root.Free;
  end;
end;

function TMemoryDistiller.Distill(const Transcript: array of TMessage;
  const SessionId, Today: string;
  out Facts: TFactArray; out ErrMsg: string): Boolean;
var
  Msgs: array of TMessage;
  NoTools: array of TToolDefinition;
  Opts: TChatOptions;
  Resp: TLLMResponse;
  Rendered: string;
begin
  SetLength(Facts, 0);
  ErrMsg := '';
  if FProvider = nil then
  begin
    ErrMsg := 'distill: no provider';
    Exit(False);
  end;

  Rendered := RenderTranscript(Transcript);
  if Trim(Rendered) = '' then
  begin
    { Empty transcript -> no facts, not an error. }
    Exit(True);
  end;

  Opts := DefaultChatOptions;
  Opts.Temperature  := 0;          { deterministic extraction }
  Opts.SystemPrompt := BuildSystemPrompt(Today);
  Opts.Stream       := False;

  SetLength(NoTools, 0);
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser,
    'Transcript to distil:' + sLineBreak + sLineBreak + Rendered);

  Resp := Default(TLLMResponse);
  try
    Resp := FProvider.Chat(Msgs, NoTools, FModel, Opts);
  except
    on E: Exception do
    begin
      ErrMsg := 'distill: provider error: ' + E.Message;
      Exit(False);
    end;
  end;

  Facts := ParseFacts(Resp.Content, SessionId);
  Result := True;
end;

end.
