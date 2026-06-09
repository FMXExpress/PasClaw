(*
  PasClaw.Search.Tavily - Tavily Search API adapter.

  Tavily is purpose-built for LLM augmentation -- the response is
  pre-summarised and short. Lower-friction than Brave for "drop
  this into the model" use cases.

  Endpoint: POST https://api.tavily.com/search
  Body:     { "api_key": "<key>", "query": "<q>",
              "max_results": <n>, "search_depth": "basic" }
  Response: { "results": [
              { "title": "...", "url": "...",
                "content": "...", "score": ... }, ... ] }

  Docs: https://docs.tavily.com/docs/rest-api/api-reference
*)
unit PasClaw.Search.Tavily;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Search.Types;

function NewTavilyProvider(const APIKey: string): ISearchProvider;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

type
  TTavilyProvider = class(TInterfacedObject, ISearchProvider)
  private
    FAPIKey: string;
  public
    constructor Create(const APIKey: string);
    function Name: string;
    function Search(const Query: string; Count: Integer;
                    out Hits: TSearchResultArray; out ErrMsg: string): Boolean;
  end;

constructor TTavilyProvider.Create(const APIKey: string);
begin
  inherited Create;
  FAPIKey := APIKey;
end;

function TTavilyProvider.Name: string;
begin
  Result := 'tavily';
end;

function TTavilyProvider.Search(const Query: string; Count: Integer;
                                 out Hits: TSearchResultArray;
                                 out ErrMsg: string): Boolean;
var
  Req: TJsonObject;
  Body: string;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
  Root, Item: TJsonObject;
  Results: TJsonArray;
  i, Cap: Integer;
begin
  SetLength(Hits, 0);
  ErrMsg := '';
  Result := False;

  if FAPIKey = '' then
  begin
    ErrMsg := 'tavily: missing API key (set $PASCLAW_TAVILY_API_KEY)';
    Exit;
  end;

  Req := TJsonObject.Create;
  try
    Req.PutStr('api_key',      FAPIKey);
    Req.PutStr('query',        Query);
    Req.PutInt('max_results',  Count);
    Req.PutStr('search_depth', 'basic');
    Body := Req.ToJSON;
  finally
    Req.Free;
  end;

  SetLength(Headers, 0);
  Resp := PostJSON('https://api.tavily.com/search', Body, Headers, 30);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    ErrMsg := Format('tavily: status=%d body=%s',
                     [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
    Exit;
  end;

  try
    Root := TJsonObject.Parse(Resp.Body);
  except
    on E: Exception do
    begin
      ErrMsg := 'tavily: bad JSON: ' + E.Message;
      Exit;
    end;
  end;
  if Root = nil then begin ErrMsg := 'tavily: empty JSON'; Exit; end;

  try
    Results := Root.ChildArray('results');
    if Results = nil then
    begin
      LogWarn('tavily: response has no "results" array (body=%s)',
              [Copy(Resp.Body, 1, 200)]);
      Result := True;
      Exit;
    end;
    try
      Cap := Results.Count;
      if Cap > Count then Cap := Count;
      SetLength(Hits, Cap);
      for i := 0 to Cap - 1 do
      begin
        Item := Results.ItemObject(i);
        if Item = nil then Continue;
        try
          Hits[i].Title   := Item.GetStr('title',   '');
          Hits[i].URL     := Item.GetStr('url',     '');
          Hits[i].Snippet := Item.GetStr('content', '');
        finally
          Item.Free;
        end;
      end;
    finally
      Results.Free;
    end;
  finally
    Root.Free;
  end;

  Result := True;
end;

function NewTavilyProvider(const APIKey: string): ISearchProvider;
begin
  Result := TTavilyProvider.Create(APIKey);
end;

end.
