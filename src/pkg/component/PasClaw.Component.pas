(*
  PasClaw.Component -- legacy unit name retained for back-compat.

  The implementation moved to PasClaw.Agent (src/pkg/agent/) so the
  unit name matches the type it exposes. This shim re-exports every
  type, exception, event signature, and the Register procedure so
  any existing code that says `uses PasClaw.Component;` keeps
  compiling unchanged.

  New code should use PasClaw.Agent directly.
*)
unit PasClaw.Component;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  Classes,
  PasClaw.Agent;

type
  EPasClawInstance        = PasClaw.Agent.EPasClawInstance;
  EPasClawRun             = PasClaw.Agent.EPasClawRun;
  TPasClawTextEvent       = PasClaw.Agent.TPasClawTextEvent;
  TPasClawToolEvent       = PasClaw.Agent.TPasClawToolEvent;
  TPasClawToolResultEvent = PasClaw.Agent.TPasClawToolResultEvent;
  TPasClawErrorEvent      = PasClaw.Agent.TPasClawErrorEvent;
  TPasClawAgent           = PasClaw.Agent.TPasClawAgent;
  TPasClawServer          = PasClaw.Agent.TPasClawServer;

procedure Register;

implementation

procedure Register;
begin
  PasClaw.Agent.Register;
end;

end.
