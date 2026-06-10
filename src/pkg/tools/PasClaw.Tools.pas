(*
  PasClaw.Tools -- umbrella unit exposing the built-in tool capabilities
  as concrete TPasClawTool subclasses.

  Each class is a thin wrapper over the existing module-level
  Register*Tool / RegisterFSTools procedures in PasClaw.Tools.*. The
  class form means embedders can hand instances to
  Agent.RegisterTool(...) the same way they'd hand it a custom
  TPasClawTool subclass:

      uses PasClaw.Agent, PasClaw.Tools;

      Agent.RegisterTool(TWebSearchTool.Create);
      Agent.RegisterTool(TWebFetchTool.Create);
      Agent.RegisterTool(TFileSystemTool.Create(True));  { hashline on }
      Agent.RegisterTool(TShellTool.Create);
      Agent.RegisterTool(TMemoryTool.Create);

  TFileSystemTool is a bundle: one Create call installs fs_read,
  fs_write, fs_grep, fs_list, and (when UseHashline=True)
  fs_edit_hashline as five separate tools in the agent's registry.

  For custom tools, subclass PasClaw.Tools.Obj.TPasClawTool directly
  and override Name/Description/Schema/Run -- see that unit's header.
*)
unit PasClaw.Tools;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  PasClaw.Tools.Types,
  PasClaw.Tools.Obj,
  PasClaw.Tools.Registry;

type
  TWebSearchTool = class(TPasClawTool)
  public
    procedure Install(R: TToolRegistry); override;
    function Category: TToolCategory; override;
  end;

  TWebFetchTool = class(TPasClawTool)
  public
    procedure Install(R: TToolRegistry); override;
    function Category: TToolCategory; override;
  end;

  TShellTool = class(TPasClawTool)
  public
    procedure Install(R: TToolRegistry); override;
    { Category stays tcMutating from the base class -- shell spawns
      subprocesses, can't safely parallelize. }
  end;

  TMemoryTool = class(TPasClawTool)
  public
    procedure Install(R: TToolRegistry); override;
    function Category: TToolCategory; override;
  end;

  TFileSystemTool = class(TPasClawTool)
  private
    FUseHashline: Boolean;
  public
    constructor Create(UseHashline: Boolean = True); reintroduce;
    procedure Install(R: TToolRegistry); override;
    { Per-sub-tool categories are set by RegisterFSTools (fs_read /
      fs_grep / fs_list = tcReadOnly; fs_write / fs_edit = tcMutating).
      The bundle's own Category isn't used since Install delegates
      directly to RegisterFSTools rather than going through the
      default Install path. }
    property UseHashline: Boolean read FUseHashline write FUseHashline;
  end;

implementation

uses
  PasClaw.Tools.WebSearch,
  PasClaw.Tools.WebFetch,
  PasClaw.Tools.Shell,
  PasClaw.Tools.Memory,
  PasClaw.Tools.KB,
  PasClaw.Tools.FS;

procedure TWebSearchTool.Install(R: TToolRegistry);
begin
  RegisterWebSearchTool(R);
end;

function TWebSearchTool.Category: TToolCategory;
begin
  Result := tcReadOnly;
end;

procedure TWebFetchTool.Install(R: TToolRegistry);
begin
  RegisterWebFetchTool(R);
end;

function TWebFetchTool.Category: TToolCategory;
begin
  Result := tcReadOnly;
end;

procedure TShellTool.Install(R: TToolRegistry);
begin
  RegisterShellTool(R);
end;

procedure TMemoryTool.Install(R: TToolRegistry);
begin
  RegisterMemoryTools(R);
  RegisterKBTools(R);
end;

function TMemoryTool.Category: TToolCategory;
begin
  Result := tcReadOnly;
end;

constructor TFileSystemTool.Create(UseHashline: Boolean);
begin
  inherited Create;
  FUseHashline := UseHashline;
end;

procedure TFileSystemTool.Install(R: TToolRegistry);
begin
  RegisterFSTools(R, FUseHashline);
end;

end.
