(*
  PasClaw.Search.SearXNG - SearXNG (self-hosted meta-search) adapter.

  SearXNG is the privacy-focused fork of Searx -- every instance is
  user-deployed, so this adapter takes a base URL (no public
  default). Endpoint:
    GET <base>/search?q=<query>&format=json&pageno=1&safesearch=1
  Most instances run without auth; if yours requires it, pass the
  bearer token through PASCLAW_SEARXNG_API_KEY and we add it as
  Authorization: Bearer <key>.

  Response shape:
    {
      "query": "...",
      "number_of_results": N,
      "results": [
        { "title": "...", "url": "...", "content": "...",
          "engine": "google", "score": 1.5, ... },
        ...
      ]
    }
  We pick title / url / content. SearXNG dedupes across upstream
  engines and orders by score, so the first N already are the best.

  Docs: https://docs.searxng.org/
*)
unit PasClaw.Search.SearXNG;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Search.Types;

function NewSearXNGProvider(const BaseURL, OptionalAPIKey: string): ISearchProvider;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

type
  TSearXNGProvider = class(TInterfacedObject, ISearchProvider)
  private
    FBase: string;
    FAuth: string;
  public
    constructor Create(const BaseURL, OptionalAPIKey: string);
    function Name: string;
    function Search(const Query: string; Count: Integer;
                    out Hits: TSearchResultArray; out ErrMsg: string): Boolean;
  end;

function UrlEncode(const S: string): string;
var
  i: Integer;
  C: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    C := S[i];
    if ((C >= 'A') and (C <= 'Z')) or
       ((C >= 'a') and (C <= 'z')) or
       ((C >= '0') and (C <= '9')) or
       (C = '-') or (C = '_') or (C = '.') or (C = '~') then
      Result := Result + C
    else
      Result := Result + '%' + IntToHex(Byte(C), 2);
  end;
end;

function TrimTrailingSlash(const S: string): string;
begin
  Result := S;
  while (Length(Result) > 0) and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
end;

constructor TSearXNGProvider.Create(const BaseURL, OptionalAPIKey: string);
begin
  inherited Create;
  FBase := TrimTrailingSlash(BaseURL);
  FAuth := OptionalAPIKey;
end;

function TSearXNGProvider.Name: string;
begin
  Result := 'searxng';
end;

function TSearXNGProvider.Search(const Query: string; Count: Integer;
                                  out Hits: TSearchResultArray;
                                  out ErrMsg: string): Boolean;
var
  URL: string;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
  Root, Item: TJsonObject;
  Results: TJsonArray;
  i, Cap: Integer;
begin
  SetLength(Hits, 0);
  ErrMsg := '';
  Result := False;

  if FBase = '' then
  begin
    ErrMsg := 'searxng: base_url not configured (set web_search.base_url ' +
              'in config.json, e.g. https://searx.be)';
    Exit;
  end;

  URL := FBase + '/search?format=json&safesearch=1&pageno=1&q=' + UrlEncode(Query);

  if FAuth <> '' then
  begin
    SetLength(Headers, 1);
    Headers[0] := MakeHeader('Authorization', 'Bearer ' + FAuth);
  end
  else
    SetLength(Headers, 0);

  Resp := GetJSONURL(URL, Headers, 20);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    ErrMsg := Format('searxng: status=%d body=%s',
                     [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
    Exit;
  end;

  try
    Root := TJsonObject.Parse(Resp.Body);
  except
    on E: Exception do
    begin
      ErrMsg := 'searxng: bad JSON: ' + E.Message;
      Exit;
    end;
  end;
  if Root = nil then begin ErrMsg := 'searxng: empty JSON'; Exit; end;

  try
    Results := Root.ChildArray('results');
    if Results = nil then
    begin
      LogWarn('searxng: response has no "results" array (body=%s)',
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

function NewSearXNGProvider(const BaseURL, OptionalAPIKey: string): ISearchProvider;
begin
  Result := TSearXNGProvider.Create(BaseURL, OptionalAPIKey);
end;

end.
