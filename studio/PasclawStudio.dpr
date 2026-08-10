program PasclawStudio;

uses
  System.StartUpCopy,
  FMX.Forms,
  FMX.Skia,
  MasterDetail in 'MasterDetail.pas' {MasterDetailForm};

{$R *.res}

begin
  GlobalUseSkia := True;
  Application.Initialize;
  Application.CreateForm(TMasterDetailForm, MasterDetailForm);
  Application.Run;
end.
