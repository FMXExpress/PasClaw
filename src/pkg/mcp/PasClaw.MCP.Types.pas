{
  PasClaw.MCP.Types - Model Context Protocol types.
  MCP uses JSON-RPC 2.0 over stdio or Streamable HTTP.

  Spec: https://modelcontextprotocol.io/specification
}
unit PasClaw.MCP.Types;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

const
  { The stateless revision: no handshake, every request carries its
    version, capabilities and client identity in params._meta. Tried
    first, through server/discover. }
  MCPProtocolModern = '2026-07-28';
  { The newest handshake-era revision the client speaks in full, offered
    in `initialize` when a server turns out to be legacy. What the server
    answers is accepted and recorded, older or not. }
  MCPProtocolLegacy = '2025-11-25';
  JSONRPCVersion    = '2.0';

  { Extension identifier of the tasks extension (tasks/get, tasks/update). }
  MCPTasksExtension = 'io.modelcontextprotocol/tasks';

  { A server may answer a request with input_required again after it got
    its answers; past this many rounds the call gives up rather than loop. }
  MCPMaxInputRounds = 8;

type
  TMCPTool = record
    Name:        string;
    Description: string;
    Schema:      string;   { JSON-encoded inputSchema }
    Server:      string;   { display name of the host server, for routing }
  end;

  TMCPToolArray = array of TMCPTool;

  TMCPCapabilities = record
    Tools:     Boolean;
    Resources: Boolean;
    Prompts:   Boolean;
    Tasks:     Boolean;   { server advertised io.modelcontextprotocol/tasks }
  end;

  TMCPServerInfo = record
    Name:    string;
    Version: string;
    Caps:    TMCPCapabilities;
    { The protocol revision in use with this server: 2026-07-28 when the
      server/discover probe succeeded, otherwise what the server answered
      to `initialize`. '' until Connect succeeds. }
    ProtocolVersion: string;
    Modern:          Boolean;   { stateless era (per-request _meta, no session) }
    { How the version was settled, for `mcp test` and the status views:
      "server/discover", or "initialize (probe: <why it fell back>)". }
    Negotiation:     string;
  end;

  (* Common base for stdio and HTTP MCP clients. The bridge keeps a list
     of these and dispatches tool calls polymorphically. *)
  TMCPBaseClient = class
  protected
    FInfo: TMCPServerInfo;
  public
    function Connect(TimeoutMs: Integer; out ErrMsg: string): Boolean; virtual; abstract;
    function ListTools(out Tools: TMCPToolArray; out ErrMsg: string): Boolean; virtual; abstract;
    function CallTool(const ToolName, ArgsJSON: string;
                      out ResultText, ErrMsg: string): Boolean; virtual; abstract;
    { Structured variant: also returns the raw `result` object as JSON so
      callers (e.g. the workflow engine) can read structuredContent / output
      URLs the text flattening drops. Base default calls CallTool and leaves
      ResultJSON empty; the concrete clients override it to capture the JSON. }
    function CallToolStructured(const ToolName, ArgsJSON: string;
                      out ResultText, ResultJSON, ErrMsg: string): Boolean; virtual;
    { Tool descriptors the caller already holds (the bridge's tools/list
      cache), for a client that needs the schemas to build a request: the
      HTTP client mirrors x-mcp-header parameters into headers. No-op by
      default. }
    procedure SetKnownTools(const Tools: TMCPToolArray); virtual;
    property ServerInfo: TMCPServerInfo read FInfo;
  end;

implementation

function TMCPBaseClient.CallToolStructured(const ToolName, ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
begin
  ResultJSON := '';
  Result := CallTool(ToolName, ArgsJSON, ResultText, ErrMsg);
end;

procedure TMCPBaseClient.SetKnownTools(const Tools: TMCPToolArray);
begin
  if Length(Tools) = 0 then ;  { nothing to learn by default }
end;

end.
