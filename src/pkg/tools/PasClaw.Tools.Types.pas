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
    { IsDeferred -- progressive-disclosure marker. When True the registry
      skips the tool from ToProviderDefs (the provider's `tools` array
      gets the schema STRIPPED), but RunTool / Find still dispatch
      normally. The model sees the name in a system-prompt "deferred
      tools" pointer and uses tool_search to load the schema, which
      flips the per-name flag in the registry's revealed set; the next
      ToProviderDefs call then includes the tool. Mirrors Claude Code's
      ToolSearch pattern. Default False -- all built-in / skill / non-
      MCP tools surface immediately. }
    IsDeferred:  Boolean;
    { Hidden -- a back-compat alias. When True the tool is a rename shim:
      Find / RunTool dispatch to it normally so old tool names keep working
      for existing configs and mid-session calls, but ToProviderDefs skips
      it so the model only ever sees the new canonical name in its tool
      list. Unlike IsDeferred, a Hidden tool is never surfaced by
      tool_search / DeferredNames -- it is permanently invisible to the
      model. Default False. }
    Hidden:      Boolean;
  end;

  TToolList = array of TTool;

implementation

end.
