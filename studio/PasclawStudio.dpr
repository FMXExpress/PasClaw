program PasclawStudio;

uses
  System.StartUpCopy,
  FMX.Forms,
  FMX.Skia,
  MasterDetail in 'MasterDetail.pas' {MasterDetailForm},
  PasclawAccessibility in 'PasclawAccessibility.pas',
  PasclawAccessibilityMac in 'PasclawAccessibilityMac.pas',
  PasclawAccessibilityLinux in 'PasclawAccessibilityLinux.pas';

{$R *.res}

begin
  GlobalUseSkia := True;
  Application.Initialize;
  Application.CreateForm(TMasterDetailForm, MasterDetailForm);
  { After CreateForm, not in the constructor: the MSAA hook subclasses the
    native window, and the handle does not exist until the form is built. }
  InstallAccessibility(MasterDetailForm);
  InstallMacAccessibility(MasterDetailForm);
  InstallLinuxAccessibility(MasterDetailForm);
  Application.Run;
end.
