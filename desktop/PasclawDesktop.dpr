program PasclawDesktop;

(*
  PasClaw Desktop -- the FireMonkey client.

  Everything this project compiles is inside the repository: the three
  PasClaw units it shares with the CLI, and the retro window manager
  vendored under retro\ (MIT, from Cross-Platform-Retro-OS-Styles --
  see retro\README.md). It used to reach for the styles repo through a
  ..\..\ sibling path, which meant the project only opened on a machine
  that happened to have that checkout.

  The .style files are a runtime asset, not a build dependency; the
  desktop runs without them and FindStyleDir picks them up when present.
*)

uses
  System.StartUpCopy,
  FMX.Forms,
  uDesktopMain in 'uDesktopMain.pas' {FormMain},
  PasClaw.Client.Api in '..\src\pkg\component\PasClaw.Client.Api.pas',
  PasClaw.JSON in '..\src\pkg\json\PasClaw.JSON.pas',
  PasClaw.Utils in '..\src\pkg\utils\PasClaw.Utils.pas',
  FMX.RetroWindows in 'retro\FMX.RetroWindows.pas',
  FMX.RetroSkins in 'retro\FMX.RetroSkins.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
