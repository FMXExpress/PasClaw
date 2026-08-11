(*
  PasClaw.Gateway.WebUI - serves the embedded single-page chat UI.

  The HTML/CSS/JS lives in webui.html as a real editable file. webui.rc
  declares it as a Windows-style RCDATA resource named PASCLAW_WEBUI_HTML;
  the Makefile compiles that to webui.res via fpcres, and {$R webui.res}
  links it into the binary. At runtime we open a TResourceStream over the
  raw bytes and hand it directly to Indy.

  Same pattern works under Delphi:
      brcc32 webui.rc -> webui.res
      {$R webui.res}
      TResourceStream.Create(HInstance, 'PASCLAW_WEBUI_HTML', RT_RCDATA);

  No string encoding ever happens, so the body Indy ships is byte-identical
  to what's on disk regardless of host string type.
*)
unit PasClaw.Gateway.WebUI;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

{$R webui.res}

interface

uses
  SysUtils, Classes, Types;

function WebUIStream: TStream;   { caller owns and frees }
{ The desktop client page, served at /desktop. Same resource pattern. }
function DesktopUIStream: TStream;   { caller owns and frees }

implementation

{ Both pages load the same way; only the resource name differs. }
function ResourceStream(const ResName: string;
  const Fallback: AnsiString): TStream;
var
  Src: TResourceStream;
  Mem: TMemoryStream;
begin
  Mem := TMemoryStream.Create;
  try
    Src := TResourceStream.Create(HInstance, PChar(ResName), PChar(RT_RCDATA));
    try
      if Src.Size > 0 then Mem.CopyFrom(Src, 0);
    finally
      Src.Free;
    end;
  except
    { Resource missing - fall back to a stub so the gateway still serves. }
    Mem.WriteBuffer(Fallback[1], Length(Fallback));
  end;
  Mem.Position := 0;
  Result := Mem;
end;

function DesktopUIStream: TStream;
begin
  Result := ResourceStream('PASCLAW_DESKTOP_HTML',
    '<!doctype html><html><body><h1>PasClaw Desktop</h1>' +
    '<p>Desktop resource missing - recompile with `make webui-res && make`.</p>' +
    '</body></html>');
end;

function WebUIStream: TStream;
const
  Fallback: AnsiString =
    '<!doctype html><html><body><h1>PasClaw</h1>' +
    '<p>UI resource missing - recompile with `make webui.res && make`.</p>' +
    '</body></html>';
begin
  Result := ResourceStream('PASCLAW_WEBUI_HTML', Fallback);
end;

end.
