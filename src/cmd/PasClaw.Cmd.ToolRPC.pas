(*
  PasClaw.Cmd.ToolRPC -- the `pasclaw __tool` subcommand.

  Internal subcommand the spawned execute_code script uses to call
  back into the parent PasClaw process's tool registry. Reads the
  port + token from $PASCLAW_HOME/run/tool-rpc.json, opens a TCP
  connection to that port, sends one JSON-line request, prints
  the response on stdout, exits with the appropriate code.

  Usage from inside an execute_code script:

      pasclaw __tool memory_search '{"q":"sandbox enforcement"}'
      pasclaw __tool fs_read       '{"path":"src/main.go"}'

  The double-underscore prefix keeps this off the operator-facing
  help list -- it's a callback channel, not a UI surface. Operators
  CAN run it from a regular shell to debug the RPC server, but
  there's no reason to advertise it.

  Exit codes:
    0   tool ran cleanly; result printed to stdout
    1   tool returned a non-empty error; err message printed to stderr
    2   RPC discovery / connection / protocol failure; message on stderr
*)
unit PasClaw.Cmd.ToolRPC;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_ToolRPC_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes,
  IdTCPClient, IdGlobal,
  PasClaw.CliUI,
  PasClaw.JSON,
  PasClaw.Tools.RPC;

function PrintErr_(const S: string): Integer;
begin
  WriteLn(ErrOutput, S);
  Result := 2;
end;

function Cmd_ToolRPC_Run(const Argv: array of string): Integer;
var
  ToolName, ArgsJSON, Token, Err, Response, ResultText, RespErr: string;
  Port: Integer;
  Client: TIdTCPClient;
  Req, Resp, ArgsObj: TJsonObject;
begin
  if Length(Argv) < 1 then
    Exit(PrintErr_('Usage: pasclaw __tool <name> [args-json]'));

  ToolName := Argv[0];
  if Length(Argv) >= 2 then
    ArgsJSON := Argv[1]
  else
    ArgsJSON := '{}';
  if Trim(ArgsJSON) = '' then ArgsJSON := '{}';

  if not DiscoverRunningRPC(Port, Token, Err) then
    Exit(PrintErr_('__tool: ' + Err));

  Req := TJsonObject.Create;
  try
    Req.PutStr('token', Token);
    Req.PutStr('name',  ToolName);
    try
      ArgsObj := TJsonObject.Parse(ArgsJSON);
    except
      ArgsObj := nil;
    end;
    if ArgsObj = nil then
      Exit(PrintErr_('__tool: args is not valid JSON: ' + Copy(ArgsJSON, 1, 200)));
    Req.PutObject('args', ArgsObj);

    Client := TIdTCPClient.Create(nil);
    try
      Client.Host := '127.0.0.1';
      Client.Port := Port;
      Client.ConnectTimeout := 5000;
      try
        Client.Connect;
      except
        on E: Exception do
          Exit(PrintErr_('__tool: connect to 127.0.0.1:' + IntToStr(Port) +
                         ' failed: ' + E.Message));
      end;
      try
        Client.IOHandler.WriteLn(Req.ToJSON);
        Response := Client.IOHandler.ReadLn(LF, 60000);
      finally
        try Client.Disconnect; except end;
      end;
    finally
      Client.Free;
    end;

    if Trim(Response) = '' then
      Exit(PrintErr_('__tool: empty response from server'));
    try
      Resp := TJsonObject.Parse(Response);
    except
      Resp := nil;
    end;
    if Resp = nil then
      Exit(PrintErr_('__tool: response is not valid JSON: ' +
                     Copy(Response, 1, 200)));
    try
      ResultText := Resp.GetStr('result', '');
      RespErr    := Resp.GetStr('err',    '');
    finally
      Resp.Free;
    end;

    if RespErr <> '' then
    begin
      WriteLn(ErrOutput, RespErr);
      Exit(1);
    end;
    Write(ResultText);
    if (ResultText = '') or (ResultText[Length(ResultText)] <> #10) then
      WriteLn;
    Result := 0;
  finally
    Req.Free;
  end;
end;

end.
