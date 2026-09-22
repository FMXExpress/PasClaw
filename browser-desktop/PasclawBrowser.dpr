program PasclawBrowser;

(*
  PasClaw Browser (browser-desktop/) -- tabs of WebView2, each with a PasClaw chat beside it
  that can read the page and change it.

  The agent is embedded: TPasClawAgent runs in this process, one per tab,
  against the user's own PASCLAW_HOME. There is no gateway to start and no
  port to open. Everything under the form -- the bridge contract, the six
  page tools, the hooks, the per-tab session -- is FPC-compilable and
  tested by `make test-browser-tools`; this program and uBrowserMain are
  the Delphi/FMX glue.

  Requires Delphi 11 or later: the form uses the EvaluateJavaScript
  overload that returns the script's value through a callback.
*)

uses
  System.StartUpCopy,
  FMX.Forms,
  uBrowserMain in 'uBrowserMain.pas' {FormMain},
  PasClaw.Browser.Bridge in 'PasClaw.Browser.Bridge.pas',
  PasClaw.Browser.Tools in 'PasClaw.Browser.Tools.pas',
  PasClaw.Browser.Hooks in 'PasClaw.Browser.Hooks.pas',
  PasClaw.Browser.Session in 'PasClaw.Browser.Session.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
