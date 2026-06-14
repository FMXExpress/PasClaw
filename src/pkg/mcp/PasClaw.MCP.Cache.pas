(*
  PasClaw.MCP.Cache - per-server tools-list cache on disk.

  Persists the result of an MCP server's tools/list call to
  <home>/mcp-cache/<server>.json so subsequent boots can register
  the tools immediately without paying the network round-trip cost.
  Replicate's MCP server hands back thousands of tools and takes a
  noticeable wall-clock chunk every cold connect -- the cache lets
  `pasclaw serve` / `pasclaw gateway` boot in under a second even
  with several big-catalog MCP servers configured.

  Lifecycle:
    1. ConnectMCPServers loads each enabled server's cache before
       spawning the background connect thread. Cache hits register
       tools immediately (handlers point at a still-nil client; see
       PasClaw.MCP.Bridge for the deferred-dispatch dance).
    2. After the live tools/list returns, the bridge calls
       SaveToolsList with the fresh array. Stale entries vanish on
       next boot.
    3. A failed connect leaves the existing cache in place -- the
       model keeps seeing whatever tools we last knew about, even
       though calls will surface the connect error until the server
       comes back up.

  Cache format (JSON):
    {
      "cached_at": <unix-seconds>,
      "server":    "<name>",
      "tools":     [ { "name", "description", "schema", "server" }, ... ]
    }
  Schema is the raw JSON inputSchema, embedded as a literal value so a
  round-trip survives without re-encoding.
*)
unit PasClaw.MCP.Cache;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.MCP.Types;

function LoadCachedTools(const ServerName: string;
                          out Tools: TMCPToolArray): Boolean;
procedure SaveCachedTools(const ServerName: string;
                          const Tools: TMCPToolArray);
function CachePath(const ServerName: string): string;
function HasCachedTools(const ServerName: string): Boolean;

{ Seconds since the cache for ServerName was written (its `cached_at`).
  -1 when there is no cache, it can't be read, or it predates the
  cached_at field. Clock skew (cached_at in the future) clamps to 0 so a
  fresh cache is never treated as stale. Used to gate the live tools/list
  refresh on a TTL. }
function CacheAgeSeconds(const ServerName: string): Int64;

implementation

uses
  Classes,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.JSON,
  PasClaw.Logger;

function CachePath(const ServerName: string): string;
begin
  Result := JoinPath(JoinPath(GetHome, 'mcp-cache'), ServerName + '.json');
end;

function HasCachedTools(const ServerName: string): Boolean;
begin
  Result := FileExists(CachePath(ServerName));
end;

function NowUnix: Int64;
const
  UnixDelta = 25569.0;
var
  T: TDateTime;
begin
  {$IFDEF FPC}
  T := Now;
  {$ELSE}
  T := Now;
  {$ENDIF}
  Result := Round((T - UnixDelta) * 86400);
end;

function CacheAgeSeconds(const ServerName: string): Int64;
var
  Path: string;
  L: TStringList;
  Root: TJsonObject;
  CachedAt: Int64;
begin
  Result := -1;
  Path := CachePath(ServerName);
  if not FileExists(Path) then Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
    except
      Exit;
    end;
    Root := TJsonObject.Parse(L.Text);
    if Root = nil then Exit;
    try
      CachedAt := Root.GetInt('cached_at', 0);
    finally
      Root.Free;
    end;
  finally
    L.Free;
  end;
  if CachedAt <= 0 then Exit;
  Result := NowUnix - CachedAt;
  if Result < 0 then Result := 0;   { clock skew -> treat as fresh }
end;

function LoadCachedTools(const ServerName: string;
                         out Tools: TMCPToolArray): Boolean;
var
  Path: string;
  L: TStringList;
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  Schema: TJsonObject;
  i: Integer;
begin
  Result := False;
  SetLength(Tools, 0);
  Path := CachePath(ServerName);
  if not FileExists(Path) then Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
    except
      on E: Exception do
      begin
        LogWarn('mcp-cache[%s] read failed: %s', [ServerName, E.Message]);
        Exit;
      end;
    end;
    Root := TJsonObject.Parse(L.Text);
    if Root = nil then
    begin
      LogWarn('mcp-cache[%s] parse failed (file at %s is not JSON)',
              [ServerName, Path]);
      Exit;
    end;
    try
      Arr := Root.ChildArray('tools');
      if Arr = nil then Exit;
      try
        SetLength(Tools, Arr.Count);
        for i := 0 to Arr.Count - 1 do
        begin
          Item := Arr.ItemObject(i);
          if Item = nil then Continue;
          try
            Tools[i].Name        := Item.GetStr('name', '');
            Tools[i].Description := Item.GetStr('description', '');
            { Schema can be either a JSON string (legacy) or a nested
              object (current). Both round-trip back to the raw JSON
              the MCP transport originally returned. }
            Schema := Item.ChildObject('schema');
            if Schema <> nil then
            try
              Tools[i].Schema := Schema.ToJSON;
            finally
              Schema.Free;
            end
            else
              Tools[i].Schema := Item.GetStr('schema', '{"type":"object"}');
            Tools[i].Server := Item.GetStr('server', ServerName);
          finally
            Item.Free;
          end;
        end;
      finally
        Arr.Free;
      end;
    finally
      Root.Free;
    end;
    Result := True;
  finally
    L.Free;
  end;
end;

procedure SaveCachedTools(const ServerName: string;
                          const Tools: TMCPToolArray);
var
  Path, Dir: string;
  Root: TJsonObject;
  Arr: TJsonArray;
  Item, Schema: TJsonObject;
  L: TStringList;
  i: Integer;
begin
  Path := CachePath(ServerName);
  Dir  := ExtractFilePath(Path);
  if Dir <> '' then ForceDirectories(Dir);
  Root := TJsonObject.Create;
  try
    Root.PutInt('cached_at', NowUnix);
    Root.PutStr('server',    ServerName);

    { Build the array + each item to completion FIRST. PutArray and
      AddObject both consume their `var` argument -- they take ownership
      of the backing and nil the local. Using the nilled local
      afterwards crashes (Codex P1 on PR #141). Hence: build Item,
      then add to Arr; build Arr fully, then PutArray onto Root. }
    Arr := TJsonArray.Create;
    try
      for i := 0 to High(Tools) do
      begin
        Item := TJsonObject.Create;
        try
          Item.PutStr('name',        Tools[i].Name);
          Item.PutStr('description', Tools[i].Description);
          { Round-trip the schema as a nested JSON object when it
            parses cleanly; otherwise fall back to a literal string so
            a malformed schema doesn't drop the whole entry.
            TJsonObject.Parse RAISES on bad JSON rather than returning
            nil, so the fallback has to live in an except branch. }
          Schema := nil;
          try
            Schema := TJsonObject.Parse(Tools[i].Schema);
          except
            on E: Exception do
            begin
              if Schema <> nil then Schema.Free;
              Schema := nil;
            end;
          end;
          if Schema <> nil then
            Item.PutObject('schema', Schema)  { consumes Schema }
          else
            Item.PutStr('schema', Tools[i].Schema);
          Item.PutStr('server', Tools[i].Server);
        except
          on E: Exception do
          begin
            Item.Free;
            raise;
          end;
        end;
        Arr.AddObject(Item);  { consumes Item -- nils it }
      end;
    except
      on E: Exception do
      begin
        Arr.Free;
        raise;
      end;
    end;
    Root.PutArray('tools', Arr);  { consumes Arr -- nils it }

    L := TStringList.Create;
    try
      L.Text := Root.ToJSON;
      try
        L.SaveToFile(Path);
      except
        on E: Exception do
          LogWarn('mcp-cache[%s] write failed: %s', [ServerName, E.Message]);
      end;
    finally
      L.Free;
    end;
  finally
    Root.Free;
  end;
end;

end.
