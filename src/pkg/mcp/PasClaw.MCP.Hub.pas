(*
  PasClaw.MCP.Hub -- pasclaw.dev MCP registry client + the resolver
  that prefers hub entries over the built-in 5-entry catalog with a
  fast offline fallback.

  Endpoints (base: https://pasclaw.dev/api/public/v1):

    GET /mcp?q=<query>&limit=<n>
       {"results":[{"slug":"…","displayName":"…","summary":"…",
                    "category":"…","tags":[…],"transport":"http",
                    "endpointUrl":"…","repoUrl":"…",
                    "homepageUrl":"…"}]}

    GET /mcp/<slug>
       {"slug":"…", … full entry detail including transport,
        endpointUrl, command, args[], envSchema[], tools[], repoUrl,
        homepageUrl, installSnippet, viewCount, moderation}

  PasClaw's existing TMCPCatalogEntry shape is HTTP-only (URL +
  EnvVar + AuthFmt). For v1 we filter the hub response down to
  transport=="http" entries and map their fields onto that record;
  stdio-transport entries are skipped with a debug log. Adding
  stdio support means extending TMCPCatalogEntry to carry command
  + args -- separate change.

  Offline behaviour: ResolveMCPCatalog tries the hub with a 5s
  timeout; on ANY failure (DNS, TLS, 5xx, parse error) it returns
  the bundled KnownMCPServers list with Source = 'builtin' so the
  caller can print "(offline)" / "(hub)" attribution. Search has
  no fallback -- it's an explicit hub query.
*)
unit PasClaw.MCP.Hub;

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
  PasClaw.MCP.Catalog;

type
  TMCPHubResult = record
    Slug:        string;
    DisplayName: string;
    Summary:     string;
    Category:    string;
    Tags:        string;
    Transport:   string;
    EndpointURL: string;
    RepoURL:     string;
    HomepageURL: string;
  end;
  TMCPHubResultArray = array of TMCPHubResult;

{ Search the pasclaw.dev MCP registry. Hub-only -- no fallback, since
  search needs the live registry to be useful (the bundled 5-entry
  list is too small to be worth searching). }
function SearchMCPHub(const Query: string; Limit: Integer;
                     out Results: TMCPHubResultArray;
                     out ErrMsg: string): Boolean;

{ Resolve the MCP catalog: try the hub first, fall back to the
  bundled KnownMCPServers list on failure. Source = 'hub' when the
  hub returned results, 'builtin' when we fell back, 'empty' when
  the hub returned an empty result set (treated as builtin
  fallback). All hub entries with transport != 'http' are skipped
  in v1; the count surfaces in HubSkipped for the caller's log
  line. }
function ResolveMCPCatalog(out Entries: TMCPCatalogEntryArray;
                           out Source: string;
                           out HubSkipped: Integer;
                           out HubErr: string): Boolean;

{ Look up a single hub entry by slug and project it onto the
  catalog record shape. Used by `pasclaw mcp install <slug>` so any
  hub-registered server is installable, not just the bundled 5.
  Returns False with ErrMsg = 'not found' (404) when the slug
  isn't on the hub. Non-HTTP transports surface ErrMsg = 'transport
  <kind> not supported yet' so the user gets a useful message
  rather than a generic install failure. }
function GetMCPHubEntry(const Slug: string;
                        out Entry: TMCPCatalogEntry;
                        out ErrMsg: string): Boolean;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

const
  HubBaseURL        = 'https://pasclaw.dev/api/public/v1';
  ListEndpoint      = '/mcp';
  GetEndpoint       = '/mcp/';
  CatalogTimeoutSec = 5;    { short -- keep `mcp catalog` snappy }
  SearchTimeoutSec  = 15;
  GetTimeoutSec     = 15;

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
      Result := Result + Format('%%%2.2X', [Ord(C)]);
  end;
end;

function CommaJoinArray(Arr: TJsonArray): string;
var
  i: Integer;
  S: string;
begin
  Result := '';
  if Arr = nil then Exit;
  for i := 0 to Arr.Count - 1 do
  begin
    S := Arr.ItemStr(i, '');
    if S = '' then Continue;
    if Result <> '' then Result := Result + ', ';
    Result := Result + S;
  end;
end;

function DoGetJSON(const URL: string; TimeoutSec: Integer;
                   out Body, ErrMsg: string): Boolean;
var
  Headers: array of THeaderPair;
  Resp: THTTPResult;
begin
  Result := False;
  ErrMsg := '';
  SetLength(Headers, 0);
  Resp := GetJSONURL(URL, Headers, TimeoutSec);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    if Resp.StatusCode = 404 then ErrMsg := 'not found'
    else if Resp.ErrorMsg <> '' then ErrMsg := Format('http %d: %s', [Resp.StatusCode, Resp.ErrorMsg])
    else ErrMsg := Format('http %d', [Resp.StatusCode]);
    Exit;
  end;
  Body := Resp.Body;
  Result := True;
end;

function SearchMCPHub(const Query: string; Limit: Integer;
                     out Results: TMCPHubResultArray;
                     out ErrMsg: string): Boolean;
var
  URL, Body, S: string;
  Root: TJsonObject;
  Arr, TagsArr: TJsonArray;
  Item: TJsonObject;
  i: Integer;
  Res: TMCPHubResult;
begin
  Result := False;
  ErrMsg := '';
  SetLength(Results, 0);
  if Limit <= 0 then Limit := 25;
  if Limit > 100 then Limit := 100;

  URL := HubBaseURL + ListEndpoint + '?limit=' + IntToStr(Limit);
  if Trim(Query) <> '' then
    URL := URL + '&q=' + UrlEncode(Query);
  LogDebug('mcp-hub: GET %s', [URL]);
  if not DoGetJSON(URL, SearchTimeoutSec, Body, ErrMsg) then Exit;

  Root := nil;
  try
    try
      Root := TJsonObject.Parse(Body);
    except
      on E: Exception do
      begin
        ErrMsg := 'malformed JSON response: ' + E.Message;
        Exit;
      end;
    end;
    if Root = nil then
    begin
      ErrMsg := 'malformed JSON response';
      Exit;
    end;
    Arr := Root.ChildArray('results');
    if Arr = nil then Exit(True);
    try
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          S := Item.GetStr('slug', '');
          if S = '' then Continue;
          Res.Slug        := S;
          Res.DisplayName := Item.GetStr('displayName', S);
          Res.Summary     := Item.GetStr('summary', '');
          Res.Category    := Item.GetStr('category', '');
          Res.Transport   := Item.GetStr('transport', '');
          Res.EndpointURL := Item.GetStr('endpointUrl', '');
          Res.RepoURL     := Item.GetStr('repoUrl', '');
          Res.HomepageURL := Item.GetStr('homepageUrl', '');
          TagsArr := Item.ChildArray('tags');
          if TagsArr <> nil then
          try
            Res.Tags := CommaJoinArray(TagsArr);
          finally
            TagsArr.Free;
          end
          else
            Res.Tags := '';
          SetLength(Results, Length(Results) + 1);
          Results[High(Results)] := Res;
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
    Result := True;
  finally
    Root.Free;
  end;
end;

function FindFirstEnvVar(EnvSchema: TJsonArray): string;
{ Pull the first required env-var name out of envSchema. The
  registry entry shape isn't fully nailed in the OpenAPI summary,
  so we tolerate either an object with name + required keys, or
  just name (required defaulting to True). Used to populate the
  TMCPCatalogEntry.EnvVar field. }
var
  i: Integer;
  Item: TJsonObject;
  Name: string;
  Required: Boolean;
begin
  Result := '';
  if EnvSchema = nil then Exit;
  for i := 0 to EnvSchema.Count - 1 do
  begin
    Item := EnvSchema.ItemObject(i);
    if Item = nil then Continue;
    try
      Name := Item.GetStr('name', '');
      Required := Item.GetBool('required', True);
      if Required and (Name <> '') then
      begin
        Result := Name;
        Exit;
      end;
    finally
      Item.Free;
    end;
  end;
end;

function ProjectHubEntryToCatalog(Root: TJsonObject;
                                   out Entry: TMCPCatalogEntry;
                                   out ErrMsg: string): Boolean;
var
  Transport, Slug, URL: string;
  EnvArr: TJsonArray;
begin
  Result := False;
  FillChar(Entry, SizeOf(Entry), 0);
  Slug := Root.GetStr('slug', '');
  if Slug = '' then
  begin
    ErrMsg := 'hub entry missing slug';
    Exit;
  end;
  Transport := LowerCase(Root.GetStr('transport', 'http'));
  if Transport <> 'http' then
  begin
    ErrMsg := Format('transport %s not supported yet (v1 is HTTP-only)', [Transport]);
    Exit;
  end;
  URL := Root.GetStr('endpointUrl', '');
  if URL = '' then
  begin
    ErrMsg := 'hub entry missing endpointUrl';
    Exit;
  end;

  Entry.Name := Slug;
  Entry.URL  := URL;
  Entry.Desc := Root.GetStr('summary', '');
  Entry.Docs := Root.GetStr('homepageUrl', '');
  if Entry.Docs = '' then Entry.Docs := Root.GetStr('repoUrl', '');

  EnvArr := Root.ChildArray('envSchema');
  if EnvArr <> nil then
  try
    Entry.EnvVar := FindFirstEnvVar(EnvArr);
  finally
    EnvArr.Free;
  end;
  if Entry.EnvVar <> '' then
    Entry.AuthFmt := 'Bearer %s';   { sane default; hub may carry an explicit format later }

  Result := True;
end;

function GetMCPHubEntry(const Slug: string;
                        out Entry: TMCPCatalogEntry;
                        out ErrMsg: string): Boolean;
var
  URL, Body: string;
  Root: TJsonObject;
begin
  Result := False;
  ErrMsg := '';
  FillChar(Entry, SizeOf(Entry), 0);

  URL := HubBaseURL + GetEndpoint + UrlEncode(Slug);
  LogDebug('mcp-hub: GET %s', [URL]);
  if not DoGetJSON(URL, GetTimeoutSec, Body, ErrMsg) then Exit;

  Root := nil;
  try
    try
      Root := TJsonObject.Parse(Body);
    except
      on E: Exception do
      begin
        ErrMsg := 'malformed JSON response: ' + E.Message;
        Exit;
      end;
    end;
    if Root = nil then
    begin
      ErrMsg := 'malformed JSON response';
      Exit;
    end;
    Result := ProjectHubEntryToCatalog(Root, Entry, ErrMsg);
  finally
    Root.Free;
  end;
end;

function ResolveMCPCatalog(out Entries: TMCPCatalogEntryArray;
                           out Source: string;
                           out HubSkipped: Integer;
                           out HubErr: string): Boolean;
var
  URL, Body: string;
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  i: Integer;
  Entry: TMCPCatalogEntry;
  ProjectErr: string;
begin
  { Result := False removed -- dead write per dcc64 H2077. The two
    success exits (hub fetch produced entries; builtin fallback) both
    explicitly set Result := True before returning. No code path
    leaves the function without one of those assignments. }
  Source := '';
  HubSkipped := 0;
  HubErr := '';
  SetLength(Entries, 0);

  URL := HubBaseURL + ListEndpoint + '?limit=100';
  LogDebug('mcp-hub: GET %s', [URL]);

  if DoGetJSON(URL, CatalogTimeoutSec, Body, HubErr) then
  begin
    Root := nil;
    try
      try
        Root := TJsonObject.Parse(Body);
      except
        on E: Exception do
        begin
          HubErr := 'malformed JSON response: ' + E.Message;
          Root := nil;
        end;
      end;
      if Root <> nil then
      begin
        Arr := Root.ChildArray('results');
        if Arr <> nil then
        try
          for i := 0 to Arr.Count - 1 do
          begin
            Item := Arr.ItemObject(i);
            if Item = nil then Continue;
            try
              if ProjectHubEntryToCatalog(Item, Entry, ProjectErr) then
              begin
                SetLength(Entries, Length(Entries) + 1);
                Entries[High(Entries)] := Entry;
              end
              else
              begin
                Inc(HubSkipped);
                LogDebug('mcp-hub: skipped %s -- %s',
                         [Item.GetStr('slug', '?'), ProjectErr]);
              end;
            finally
              Item.Free;
            end;
          end;
        finally
          Arr.Free;
        end;
      end;
    finally
      Root.Free;
    end;

    if Length(Entries) > 0 then
    begin
      Source := 'hub';
      Result := True;
      Exit;
    end;
    { Hub responded but returned nothing usable -- fall through to
      builtin so the user still gets the 5 bundled entries. Keep
      HubErr empty since this isn't really an error. }
  end;

  Entries := KnownMCPServers;
  Source := 'builtin';
  Result := True;
end;

end.
