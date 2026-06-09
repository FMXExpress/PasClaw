{
  PasClaw.Tools.Types - shared types for the tools registry.
  Mirrors the Tool interface in pkg/tools/registry.go.
}
unit PasClaw.Tools.Types;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  { Handler signature: receives a raw JSON argument blob and returns a string
    that becomes the tool_result content. The handler may set Err to a non-empty
    string to signal a recoverable error to the model. }
  TToolHandler = function(const ArgsJSON: string; out ErrMsg: string): string;

  { Method-pointer variant for class-based tools (TPasClawTool descendants).
    The registry prefers HandlerObj over Handler when both are set, so a
    class instance can dispatch through its own Self.Run without going via
    a top-level function pointer. }
  TToolHandlerObj = function(const ArgsJSON: string; out ErrMsg: string): string of object;

  { Tool category -- drives parallel dispatch in PasClaw.Tools.ToolLoop.

    tcMutating: the tool can mutate shared state (filesystem writes,
                shell subprocesses, MCP-stdio handshakes that share a
                single stdin pipe, memory writes). MUST run serially --
                a batch containing one mutating call has size 1, never
                gets parallelized with siblings.

    tcReadOnly: the tool only reads. Filesystem reads, HTTP GETs,
                grep / search / list. Multiple read-only calls from a
                single model turn can fan out concurrently.

    tcMutating is the first (= zero-init) value on purpose: a freshly-
    allocated TTool record on the stack with the Category field left
    untouched defaults to "treat as mutating", which is the safe choice
    when a tool author forgets to set it. Built-in tools and TPasClawTool
    subclasses explicitly opt into tcReadOnly. }
  TToolCategory = (tcMutating, tcReadOnly);

  TTool = record
    Name:        string;
    Description: string;
    Schema:      string;   { JSON schema (parameters) }
    Handler:     TToolHandler;
    HandlerObj:  TToolHandlerObj;
    IsCore:      Boolean;
    Category:    TToolCategory;
  end;

  TToolList = array of TTool;

implementation

end.
