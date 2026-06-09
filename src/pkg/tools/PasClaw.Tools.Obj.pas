(*
  PasClaw.Tools.Obj -- abstract base class for OOP tool authoring.

  This is the friendly side of the record-based registry. The legacy
  TTool record + plain function pointer in PasClaw.Tools.Types still
  works (the CLI's built-in tools, MCP bridge, and skills all use it);
  TPasClawTool is an opt-in object wrapper for code-driven embedders
  who want a normal class hierarchy and don't want to learn about
  function-pointer records.

  Usage from an embedding host:

    type
      TMyTool = class(TPasClawTool)
      public
        function Name:        string; override;
        function Description: string; override;
        function Schema:      string; override;
        function Run(const ArgsJSON: string;
                     out ErrMsg: string): string; override;
      end;

    Agent.RegisterTool(TMyTool.Create);

  TPasClawAgent owns every TPasClawTool handed to it and frees them
  in its destructor.

  Tool bundles (e.g. TFileSystemTool, which registers five fs_* tools
  at once) override Install instead of the four single-tool methods.
  The default Install registers Self via Name/Description/Schema with
  a method pointer back to Self.Run, so single-tool subclasses only
  ever need to touch the four virtuals above.
*)
unit PasClaw.Tools.Obj;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

type
  TPasClawTool = class
  public
    { Default Install registers this instance as a single tool using
      Name/Description/Schema, dispatching tool_call payloads to
      Self.Run via a method pointer. Tool-bundle subclasses override
      Install to register multiple sub-tools instead. }
    procedure Install(R: TToolRegistry); virtual;

    { Single-tool overrides. Default implementations return empty
      strings / "not implemented"; bundle subclasses that override
      Install can ignore these. }
    function Name:        string; virtual;
    function Description: string; virtual;
    function Schema:      string; virtual;
    function Run(const ArgsJSON: string; out ErrMsg: string): string; virtual;

    { Override to tcReadOnly if your Run does no shared-state mutation
      -- that lets the agent loop fan out concurrent calls to your tool
      alongside other read-only tools in the same model turn. Default is
      tcMutating for safety: a custom tool author who forgets to set
      Category gets serial dispatch, never an accidental race. }
    function Category: TToolCategory; virtual;
  end;

implementation

procedure TPasClawTool.Install(R: TToolRegistry);
var
  T: TTool;
begin
  T.Name        := Name;
  T.Description := Description;
  T.Schema      := Schema;
  T.Handler     := nil;
  T.HandlerObj  := Self.Run;
  T.IsCore      := False;
  T.Category    := Category;
  R.Register(T);
end;

function TPasClawTool.Name:        string; begin Result := ''; end;
function TPasClawTool.Description: string; begin Result := ''; end;
function TPasClawTool.Schema:      string; begin Result := '{"type":"object"}'; end;
function TPasClawTool.Category:    TToolCategory; begin Result := tcMutating; end;

function TPasClawTool.Run(const ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := 'TPasClawTool.Run not overridden';
  Result := '';
end;

end.
