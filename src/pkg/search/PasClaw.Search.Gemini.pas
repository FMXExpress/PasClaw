(*
  PasClaw.Search.Gemini - Google Gemini "Google Search" grounding
  as a web_search provider.

  Gemini isn't a search engine. It's an LLM with a `google_search`
  tool the model can invoke during generation, with the response
  returning both the synthesised answer AND the source URLs it
  consulted. The adapter calls generateContent with the
  google_search tool enabled and maps the result into the same
  ISearchProvider shape Tavily / Perplexity use:

    Hits[0]   = the synthesised answer (title="Gemini summary",
                URL=first grounding URL if any, snippet=text)
    Hits[1..] = each remaining grounding chunk as a real
                {title, url} pair Gemini already supplies

  Caps total hits at `Count`. The synthesised summary plus a few
  source URLs is usually more useful than 10 raw search hits.

  Endpoint: POST https://generativelanguage.googleapis.com/v1beta/
                 models/<model>:generateContent?key=<api-key>
  Body:     { "contents": [
                { "parts": [ { "text": "<query>" } ] } ],
              "tools": [ { "google_search": {} } ] }
  Response: { "candidates": [ {
                "content": { "parts": [ { "text": "<answer>" } ] },
                "groundingMetadata": {
                  "groundingChunks": [
                    { "web": { "uri": "...", "title": "..." } }, ...
                  ],
                  "webSearchQueries": [ "..." ],
                  ...
                }
              } ] }

  Model: hardcoded to gemini-1.5-flash -- free-tier-friendly, supports
  google_search grounding, fast. Users wanting 1.5-pro or 2.0-flash
  can patch this constant; we don't add another config field for one
  provider.

  Docs:
    Grounding   https://ai.google.dev/gemini-api/docs/grounding
    REST shape  https://ai.google.dev/api/rest/v1beta/models/generateContent
*)
unit PasClaw.Search.Gemini;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Search.Types;

function NewGeminiProvider(const APIKey: string): ISearchProvider;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

const
  GEMINI_MODEL       = 'gemini-1.5-flash';
  ANSWER_SNIPPET_MAX = 1200;

type
  TGeminiProvider = class(TInterfacedObject, ISearchProvider)
  private
    FAPIKey: string;
  public
    constructor Create(const APIKey: string);
    function Name: string;
    function Search(const Query: string; Count: Integer;
                    out Hits: TSearchResultArray; out ErrMsg: string): Boolean;
  end;

constructor TGeminiProvider.Create(const APIKey: string);
begin
  inherited Create;
  FAPIKey := APIKey;
end;

function TGeminiProvider.Name: string;
begin
  Result := 'gemini';
end;

function BuildRequestBody(const Query: string): string;
var
  Root, Content, Part, Tool, GS: TJsonObject;
  ContentsArr, PartsArr, ToolsArr: TJsonArray;
begin
  Root := TJsonObject.Create;
  try
    ContentsArr := TJsonArray.Create;
    Content     := TJsonObject.Create;
    PartsArr    := TJsonArray.Create;
    Part        := TJsonObject.Create;
    Part.PutStr('text', Query);
    PartsArr.AddObject(Part);
    Content.PutArray('parts', PartsArr);
    ContentsArr.AddObject(Content);
    Root.PutArray('contents', ContentsArr);

    ToolsArr := TJsonArray.Create;
    Tool     := TJsonObject.Create;
    GS       := TJsonObject.Create;   { empty object -- the tool config }
    Tool.PutObject('google_search', GS);
    ToolsArr.AddObject(Tool);
    Root.PutArray('tools', ToolsArr);

    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function ExtractAnswer(Root: TJsonObject): string;
var
  Candidates: TJsonArray;
  Candidate, Content: TJsonObject;
  Parts: TJsonArray;
  Part: TJsonObject;
  i: Integer;
begin
  Result := '';
  Candidates := Root.ChildArray('candidates');
  if Candidates = nil then Exit;
  try
    if Candidates.Count = 0 then Exit;
    Candidate := Candidates.ItemObject(0);
    if Candidate = nil then Exit;
    try
      Content := Candidate.ChildObject('content');
      if Content = nil then Exit;
      try
        Parts := Content.ChildArray('parts');
        if Parts = nil then Exit;
        try
          for i := 0 to Parts.Count - 1 do
          begin
            Part := Parts.ItemObject(i);
            if Part = nil then Continue;
            try
              { Parts may carry text, function_call, etc. We only
                want the model's prose answer. }
              if Result <> '' then Result := Result + #10;
              Result := Result + Part.GetStr('text', '');
            finally
              Part.Free;
            end;
          end;
        finally
          Parts.Free;
        end;
      finally
        Content.Free;
      end;
    finally
      Candidate.Free;
    end;
  finally
    Candidates.Free;
  end;
end;

procedure ExtractGroundingURLs(Root: TJsonObject;
                                var Titles, URLs: array of string;
                                var ChunkCount: Integer);
(* Walks candidates[0].groundingMetadata.groundingChunks[].web and
   appends each title/uri pair into the parallel Titles/URLs arrays
   up to their declared length. ChunkCount returns how many were
   populated. *)
var
  Candidates: TJsonArray;
  Candidate, GM, Web: TJsonObject;
  Chunks: TJsonArray;
  Chunk: TJsonObject;
  i, Cap: Integer;
begin
  ChunkCount := 0;
  Cap := Length(Titles);   { same as Length(URLs) by contract }
  if Cap = 0 then Exit;
  Candidates := Root.ChildArray('candidates');
  if Candidates = nil then Exit;
  try
    if Candidates.Count = 0 then Exit;
    Candidate := Candidates.ItemObject(0);
    if Candidate = nil then Exit;
    try
      GM := Candidate.ChildObject('groundingMetadata');
      if GM = nil then Exit;
      try
        Chunks := GM.ChildArray('groundingChunks');
        if Chunks = nil then Exit;
        try
          for i := 0 to Chunks.Count - 1 do
          begin
            if ChunkCount >= Cap then Break;
            Chunk := Chunks.ItemObject(i);
            if Chunk = nil then Continue;
            try
              Web := Chunk.ChildObject('web');
              if Web = nil then Continue;
              try
                URLs[ChunkCount]   := Web.GetStr('uri',   '');
                Titles[ChunkCount] := Web.GetStr('title', '');
                if URLs[ChunkCount] <> '' then Inc(ChunkCount);
              finally
                Web.Free;
              end;
            finally
              Chunk.Free;
            end;
          end;
        finally
          Chunks.Free;
        end;
      finally
        GM.Free;
      end;
    finally
      Candidate.Free;
    end;
  finally
    Candidates.Free;
  end;
end;

function TGeminiProvider.Search(const Query: string; Count: Integer;
                                 out Hits: TSearchResultArray;
                                 out ErrMsg: string): Boolean;
var
  URL, Body, Answer: string;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
  Root: TJsonObject;
  Titles, URLs: array of string;
  ChunkCount, N, FirstCite, i: Integer;
begin
  SetLength(Hits, 0);
  ErrMsg := '';
  Result := False;

  if FAPIKey = '' then
  begin
    ErrMsg := 'gemini: missing API key (set $PASCLAW_GEMINI_API_KEY)';
    Exit;
  end;

  URL := 'https://generativelanguage.googleapis.com/v1beta/models/' +
         GEMINI_MODEL + ':generateContent?key=' + FAPIKey;
  Body := BuildRequestBody(Query);
  SetLength(Headers, 0);
  Resp := PostJSON(URL, Body, Headers, 45);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    ErrMsg := Format('gemini: status=%d body=%s',
                     [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
    Exit;
  end;

  try
    Root := TJsonObject.Parse(Resp.Body);
  except
    on E: Exception do
    begin
      ErrMsg := 'gemini: bad JSON: ' + E.Message;
      Exit;
    end;
  end;
  if Root = nil then begin ErrMsg := 'gemini: empty JSON'; Exit; end;

  try
    Answer := ExtractAnswer(Root);

    { Reserve room for up to Count grounding chunks. Pull them in
      one pass, then fold the answer in as Hits[0]. }
    SetLength(Titles, Count);
    SetLength(URLs,   Count);
    ChunkCount := 0;
    ExtractGroundingURLs(Root, Titles, URLs, ChunkCount);

    N := 0;
    FirstCite := 0;
    if Answer <> '' then
    begin
      SetLength(Hits, 1);
      Hits[0].Title := 'Gemini summary';
      if ChunkCount > 0 then
      begin
        Hits[0].URL := URLs[0];
        FirstCite := 1;   { first grounding URL already in Hits[0] }
      end
      else
        Hits[0].URL := '';
      if Length(Answer) > ANSWER_SNIPPET_MAX then
        Hits[0].Snippet := Copy(Answer, 1, ANSWER_SNIPPET_MAX) + ' …(truncated)'
      else
        Hits[0].Snippet := Answer;
      N := 1;
    end;

    for i := FirstCite to ChunkCount - 1 do
    begin
      if N >= Count then Break;
      SetLength(Hits, N + 1);
      Hits[N].Title   := Titles[i];
      if Hits[N].Title = '' then Hits[N].Title := '(grounding chunk)';
      Hits[N].URL     := URLs[i];
      Hits[N].Snippet := '';
      Inc(N);
    end;

    if (Answer = '') and (ChunkCount = 0) then
      LogWarn('gemini: response had neither candidates nor grounding (body=%s)',
              [Copy(Resp.Body, 1, 200)]);
  finally
    Root.Free;
  end;

  Result := True;
end;

function NewGeminiProvider(const APIKey: string): ISearchProvider;
begin
  Result := TGeminiProvider.Create(APIKey);
end;

end.
