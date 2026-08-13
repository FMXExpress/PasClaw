program PasclawDesktop;

(*
  PasClaw Desktop -- the FireMonkey client.

  Requires a sibling checkout of Cross-Platform-Retro-OS-Styles (the retro
  window manager and the .style files). Nothing from it is vendored; see
  desktop/README.md for the expected layout and how to point the build
  somewhere else.
*)

uses
  System.StartUpCopy,
  FMX.Forms,
  uDesktopMain in 'uDesktopMain.pas' {FormMain},
  PasClaw.Client.Api in '..\src\pkg\component\PasClaw.Client.Api.pas',
  PasClaw.JSON in '..\src\pkg\json\PasClaw.JSON.pas',
  PasClaw.Utils in '..\src\pkg\utils\PasClaw.Utils.pas',
  FMX.RetroWindows in '..\..\Cross-Platform-Retro-OS-Styles\Source\FMX.RetroWindows.pas',
  FMX.RetroSkins in '..\..\Cross-Platform-Retro-OS-Styles\Source\FMX.RetroSkins.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
