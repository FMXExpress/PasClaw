{ MCP — list/add/remove/edit/test/show MCP server entries in config. }
unit PasClaw.Cmd.MCP;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_MCP_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.Config, PasClaw.CliUI,
  PasClaw.MCP.Types,
  PasClaw.MCP.StdioClient,
  PasClaw.MCP.HttpClient,
  PasClaw.MCP.Catalog,
  PasClaw.MCP.Hub,
  PasClaw.MCP.OAuth;

procedure Help;
begin
  WriteLn('Usage: pasclaw mcp <list|add|remove|test|edit|show|catalog|search|install|auth> [args]');
  WriteLn('  add <name> <cmd> [args]   register a new MCP server');
  WriteLn('  remove <name>             delete an MCP server entry');
  WriteLn('  list                      list configured servers');
  WriteLn('  show <name>               show one server in detail');
  WriteLn('  test <name>               probe a server: initialize + tools/list');
  WriteLn('  edit                      open config in $EDITOR');
  WriteLn('  catalog                   list public MCP servers (pasclaw.dev hub,');
  WriteLn('                            falls back to built-in 5 when offline)');
  WriteLn('  search <query>            search pasclaw.dev MCP registry');
  WriteLn('  install <name>            add from hub or catalog (reads auth from env)');
  WriteLn('  auth <name>               run the OAuth 2.1 + PKCE flow for an OAuth-only');
  WriteLn('                            MCP server (opens browser, captures callback)');
end;

function DoList: Integer;
var
  Cfg: TConfig;
  i: Integer;
begin
  Cfg := LoadConfig;
  try
    if Length(Cfg.MCPServers) = 0 then
    begin
      WriteLn('(no MCP servers configured)');
      Exit(0);
    end;
    WriteLn(Ansi.Bold, 'name', Ansi.Reset, '            cmd');
    for i := 0 to High(Cfg.MCPServers) do
      WriteLn(Cfg.MCPServers[i].Name:14, '  ', Cfg.MCPServers[i].Cmd, ' ', Cfg.MCPServers[i].Args);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoAdd(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Args: string;
  i, n: Integer;
begin
  if Length(Argv) < 3 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    Args := '';
    for i := 3 to High(Argv) do
    begin
      if Args <> '' then Args := Args + ' ';
      Args := Args + Argv[i];
    end;
    n := Length(Cfg.MCPServers);
    SetLength(Cfg.MCPServers, n + 1);
    Cfg.MCPServers[n].Name    := Argv[1];
    Cfg.MCPServers[n].Cmd     := Argv[2];
    Cfg.MCPServers[n].Args    := Args;
    Cfg.MCPServers[n].Enabled := True;
    SaveConfig(Cfg);
    WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'added MCP server ', Argv[1]);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoRemove(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i, dst: Integer;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    dst := 0;
    for i := 0 to High(Cfg.MCPServers) do
      if not SameText(Cfg.MCPServers[i].Name, Argv[1]) then
      begin
        Cfg.MCPServers[dst] := Cfg.MCPServers[i];
        Inc(dst);
      end;
    SetLength(Cfg.MCPServers, dst);
    SaveConfig(Cfg);
    WriteLn('removed ', Argv[1]);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoShow(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i: Integer;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    for i := 0 to High(Cfg.MCPServers) do
      if SameText(Cfg.MCPServers[i].Name, Argv[1]) then
      begin
        WriteLn('name:    ', Cfg.MCPServers[i].Name);
        WriteLn('cmd:     ', Cfg.MCPServers[i].Cmd);
        WriteLn('args:    ', Cfg.MCPServers[i].Args);
        WriteLn('env:     ', Cfg.MCPServers[i].Env);
        WriteLn('enabled: ', Cfg.MCPServers[i].Enabled);
        Exit(0);
      end;
    WriteLn('no such MCP server: ', Argv[1]);
    Result := 1;
  finally
    Cfg.Free;
  end;
end;

function IsHttpUrl(const S: string): Boolean;
begin
  Result := (Length(S) >= 7) and
            ((LowerCase(Copy(S, 1, 7)) = 'http://') or
             ((Length(S) >= 8) and (LowerCase(Copy(S, 1, 8)) = 'https://')));
end;

function DoTest(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i, j: Integer;
  Client: TMCPBaseClient;
  Tools: TMCPToolArray;
  Err: string;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    for i := 0 to High(Cfg.MCPServers) do
      if SameText(Cfg.MCPServers[i].Name, Argv[1]) then
      begin
        if IsHttpUrl(Cfg.MCPServers[i].Cmd) then
        begin
          WriteLn('Connecting HTTP MCP at ', Cfg.MCPServers[i].Cmd, '...');
          Client := TMCPHttpClient.Create(Cfg.MCPServers[i].Name,
                                          Cfg.MCPServers[i].Cmd,
                                          Cfg.MCPServers[i].Args);
        end
        else
        begin
          WriteLn('Spawning ', Cfg.MCPServers[i].Cmd, ' ', Cfg.MCPServers[i].Args, '...');
          Client := TMCPStdioClient.Create(Cfg.MCPServers[i].Name,
                                           Cfg.MCPServers[i].Cmd,
                                           Cfg.MCPServers[i].Args);
        end;
        try
          if not Client.Connect(5000, Err) then
          begin
            WriteLn(Ansi.Red, '✗ ', Err, Ansi.Reset);
            Exit(1);
          end;
          WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'initialize OK');
          WriteLn('  server: ', Client.ServerInfo.Name, ' ', Client.ServerInfo.Version);
          if Client.ListTools(Tools, Err) then
          begin
            WriteLn('  tools (', Length(Tools), '):');
            for j := 0 to High(Tools) do
              WriteLn('    - ', Tools[j].Name, '  ', Tools[j].Description);
          end
          else
            WriteLn(Ansi.Yellow, '  tools/list failed: ', Err, Ansi.Reset);
        finally
          Client.Free;
        end;
        Exit(0);
      end;
    WriteLn('no such MCP server: ', Argv[1]);
    Result := 1;
  finally
    Cfg.Free;
  end;
end;

function DoEdit(const Argv: array of string): Integer;
begin
  WriteLn('open ', GetConfigPath, ' in your editor (no shell-out yet).');
  Result := 0;
end;

function DoCatalog: Integer;
var
  Entries: TMCPCatalogEntryArray;
  i, Skipped: Integer;
  Auth, Source, HubErr: string;
begin
  if not ResolveMCPCatalog(Entries, Source, Skipped, HubErr) then
  begin
    { ResolveMCPCatalog always returns True today — it falls back to
      KnownMCPServers on hub failure. Defensive branch for the
      future case where it might fail outright. }
    WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'catalog unavailable: ', HubErr);
    Exit(1);
  end;
  if Source = 'hub' then
    WriteLn(Ansi.Dim, '(showing ', Length(Entries),
            ' from pasclaw.dev hub)', Ansi.Reset)
  else if HubErr <> '' then
    WriteLn(Ansi.Yellow, '! ', Ansi.Reset,
            'hub unreachable (', HubErr,
            ') — showing built-in ', Length(Entries), ' entries')
  else
    WriteLn(Ansi.Dim, '(showing built-in ', Length(Entries), ' entries)', Ansi.Reset);
  if Skipped > 0 then
    WriteLn(Ansi.Dim, '  (', Skipped,
            ' hub entry/entries skipped — non-HTTP transports not supported yet)',
            Ansi.Reset);
  WriteLn;
  if Length(Entries) = 0 then
  begin
    WriteLn('(catalog empty)');
    Exit(0);
  end;
  WriteLn(Ansi.Bold, 'name', Ansi.Reset, '                       env var               status');
  for i := 0 to High(Entries) do
  begin
    if Entries[i].EnvVar = '' then Auth := '(no auth)'
    else if GetEnvironmentVariable(Entries[i].EnvVar) <> '' then Auth := Ansi.Green + 'set' + Ansi.Reset
    else Auth := Ansi.Yellow + 'unset' + Ansi.Reset;
    WriteLn(Entries[i].Name:24, '   ', Entries[i].EnvVar:18, '   ', Auth);
    if Entries[i].Desc <> '' then
      WriteLn('                            ', Ansi.Dim, Entries[i].Desc, Ansi.Reset);
  end;
  WriteLn;
  WriteLn(Ansi.Dim, 'Install one with: pasclaw mcp install <name>', Ansi.Reset);
  Result := 0;
end;

function DoSearch(const Argv: array of string): Integer;
var
  Results: TMCPHubResultArray;
  ErrMsg, Summary: string;
  i: Integer;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  WriteLn('Searching pasclaw.dev MCP registry: ', Argv[1], ' …');
  if not SearchMCPHub(Argv[1], 25, Results, ErrMsg) then
  begin
    WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'search failed: ', ErrMsg);
    Exit(1);
  end;
  if Length(Results) = 0 then
  begin
    WriteLn('(no matches)');
    Exit(0);
  end;
  WriteLn(Ansi.Bold, 'slug', Ansi.Reset,
          '                       transport  name');
  for i := 0 to High(Results) do
  begin
    WriteLn(Results[i].Slug:26, '  ', Results[i].Transport:9, '  ',
            Results[i].DisplayName);
    Summary := Trim(Results[i].Summary);
    if Summary <> '' then
      WriteLn('                            ', Ansi.Dim, Summary, Ansi.Reset);
  end;
  WriteLn;
  WriteLn(Ansi.Dim, 'Install with: ', Ansi.Reset,
          Ansi.Bold, 'pasclaw mcp install <slug>', Ansi.Reset);
  Result := 0;
end;

function DoInstall(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Entry: TMCPCatalogEntry;
  HeaderVal, HubErr: string;
  EnvSet, AuthOk, HubFound: Boolean;
  i, n: Integer;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  { Try the pasclaw.dev hub first so any registered server is
    installable, not just the bundled 5. Fall back to the built-in
    catalog when the hub returns not-found OR is unreachable —
    network errors don't deny a built-in install that would
    otherwise work. }
  HubFound := GetMCPHubEntry(Argv[1], Entry, HubErr);
  if not HubFound then
  begin
    if not FindCatalogEntry(Argv[1], Entry) then
    begin
      WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'no entry named "', Argv[1], '"');
      if HubErr <> '' then
        WriteLn(Ansi.Dim, '  pasclaw.dev hub: ', HubErr, Ansi.Reset);
      WriteLn(Ansi.Dim, '  try: ', Ansi.Reset,
              Ansi.Bold, 'pasclaw mcp catalog', Ansi.Reset,
              Ansi.Dim, ' or ', Ansi.Reset,
              Ansi.Bold, 'pasclaw mcp search <query>', Ansi.Reset);
      Exit(1);
    end;
  end
  else
    WriteLn(Ansi.Dim, '  resolved from pasclaw.dev hub', Ansi.Reset);

  { OAuth-only servers (Replicate today) install with no header — the
    HTTP client reads the on-disk token store at request time. Prompt
    the user to run `mcp auth` so the next test/serve has a token. }
  if Entry.RequiresOAuth then
  begin
    HeaderVal := '';
    if HasStoredTokens(Entry.Name) then
      WriteLn(Ansi.Dim, '  using existing OAuth tokens at ',
              OAuthTokenPath(Entry.Name), Ansi.Reset)
    else
      WriteLn(Ansi.Yellow, '! ', Ansi.Reset,
              'OAuth required — run `pasclaw mcp auth ', Entry.Name,
              '` to authorize.');
  end
  else
  begin
    AuthOk := ResolveAuthHeader(Entry, HeaderVal, EnvSet);
    if (Entry.EnvVar <> '') and (not EnvSet) then
    begin
      WriteLn(Ansi.Yellow, '! ', Ansi.Reset, 'env var ', Entry.EnvVar,
              ' is not set. Installing anyway with an empty Authorization');
      WriteLn('  header — set ', Entry.EnvVar,
              ' and re-run `pasclaw mcp install ', Entry.Name, '` to refresh it,');
      WriteLn('  or run `pasclaw mcp edit` to drop in the token by hand.');
      HeaderVal := '';
    end
    else if AuthOk and (HeaderVal <> '') then
      WriteLn(Ansi.Dim, '  using ', Entry.EnvVar, ' from environment', Ansi.Reset);
  end;

  Cfg := LoadConfig;
  try
    { Replace any prior install of this catalog entry rather than
      creating a duplicate (idempotent refresh after the user sets
      the env var). }
    for i := 0 to High(Cfg.MCPServers) do
      if SameText(Cfg.MCPServers[i].Name, Entry.Name) then
      begin
        Cfg.MCPServers[i].Cmd     := Entry.URL;
        Cfg.MCPServers[i].Args    := HeaderVal;
        Cfg.MCPServers[i].Enabled := True;
        SaveConfig(Cfg);
        WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'updated MCP server ', Entry.Name);
        Exit(0);
      end;

    n := Length(Cfg.MCPServers);
    SetLength(Cfg.MCPServers, n + 1);
    Cfg.MCPServers[n].Name    := Entry.Name;
    Cfg.MCPServers[n].Cmd     := Entry.URL;
    Cfg.MCPServers[n].Args    := HeaderVal;
    Cfg.MCPServers[n].Enabled := True;
    SaveConfig(Cfg);
    WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'installed MCP server ', Entry.Name);
    WriteLn('  ', Ansi.Dim, Entry.Desc, Ansi.Reset);
    WriteLn('  Test with: ', Ansi.Bold, 'pasclaw mcp test ', Entry.Name, Ansi.Reset);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoAuth(const Argv: array of string): Integer;
{ pasclaw mcp auth <name>  — run OAuth 2.1 + PKCE against the
  authorization server the configured MCP server advertises. The
  resulting tokens land in <home>/oauth/<name>.json; the HTTP MCP
  client picks them up automatically on the next request. }
var
  Cfg: TConfig;
  i: Integer;
  URL, ErrMsg: string;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    URL := '';
    for i := 0 to High(Cfg.MCPServers) do
      if SameText(Cfg.MCPServers[i].Name, Argv[1]) then
      begin
        URL := Cfg.MCPServers[i].Cmd;
        Break;
      end;
    if URL = '' then
    begin
      WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'no such MCP server: ', Argv[1]);
      WriteLn(Ansi.Dim, '  install it first with: ', Ansi.Reset,
              Ansi.Bold, 'pasclaw mcp install ', Argv[1], Ansi.Reset);
      Exit(1);
    end;
    if not IsHttpUrl(URL) then
    begin
      WriteLn(Ansi.Red, '✗ ', Ansi.Reset,
              'OAuth flow only applies to HTTP MCP servers; ', Argv[1],
              ' is ', URL);
      Exit(1);
    end;
  finally
    Cfg.Free;
  end;

  if RunOAuthFlow(Argv[1], URL, ErrMsg) then
  begin
    WriteLn(Ansi.Green, '✓ ', Ansi.Reset, 'authorized ', Argv[1],
            ' — tokens written to ', OAuthTokenPath(Argv[1]));
    { Clear any pre-existing Args header on the server entry. Pre-OAuth
      installs of the same catalog name (e.g. an old `mcp install
      replicate` that wrote "Bearer r8_…" from REPLICATE_API_TOKEN)
      would otherwise short-circuit the HTTP client's auth resolver and
      send the stale token instead of the fresh OAuth one — the exact
      symptom the user reported after a successful `mcp auth`. A
      successful auth run is the canonical "use OAuth for this server"
      signal, so the Args slot belongs to the OAuth token store now. }
    Cfg := LoadConfig;
    try
      for i := 0 to High(Cfg.MCPServers) do
        if SameText(Cfg.MCPServers[i].Name, Argv[1]) and
           (Cfg.MCPServers[i].Args <> '') then
        begin
          Cfg.MCPServers[i].Args := '';
          SaveConfig(Cfg);
          WriteLn(Ansi.Dim,
                  '  cleared stale Authorization header on the server entry',
                  Ansi.Reset);
          Break;
        end;
    finally
      Cfg.Free;
    end;
    WriteLn('  Try it: ', Ansi.Bold, 'pasclaw mcp test ', Argv[1], Ansi.Reset);
    Result := 0;
  end
  else
  begin
    WriteLn(Ansi.Red, '✗ ', Ansi.Reset, 'OAuth flow failed: ', ErrMsg);
    Result := 1;
  end;
end;

function Cmd_MCP_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then begin Help; Exit(1); end;
  Sub := Argv[0];
  if      Sub = 'list'    then Result := DoList
  else if Sub = 'add'     then Result := DoAdd(Argv)
  else if Sub = 'remove'  then Result := DoRemove(Argv)
  else if Sub = 'show'    then Result := DoShow(Argv)
  else if Sub = 'test'    then Result := DoTest(Argv)
  else if Sub = 'edit'    then Result := DoEdit(Argv)
  else if Sub = 'catalog' then Result := DoCatalog
  else if Sub = 'search'  then Result := DoSearch(Argv)
  else if Sub = 'install' then Result := DoInstall(Argv)
  else if Sub = 'auth'    then Result := DoAuth(Argv)
  else begin Help; Result := 1; end;
end;

end.
