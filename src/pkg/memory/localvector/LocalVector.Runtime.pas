{
  Vendored from FMXExpress/localvector (MIT licensed; LICENSE preserved
  alongside this file). Upstream commit: 0f00eece553da47e83169ddc8d72965c0dc40bcc.
  https://github.com/FMXExpress/localvector

  Modifications kept to a minimum — PasClaw uses these units verbatim
  as the in-tree implementation of the hybrid FTS5+vector memory backend
  (PasClaw.Memory.Vector). Diff against upstream for change tracking.
}

unit LocalVector.Runtime;

{ ONNX Runtime diagnostics.

  The bindings load onnxruntime dynamically (LoadOnnxRuntime), so this unit
  reports the file that was actually loaded and the version it returns -- no
  guessing whether the app picked up a local DLL or the one inside Windows. }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  onnxruntime_pas_api;

type
  TOrtRuntimeInfo = record
    DllPath: string;        // full path of the loaded onnxruntime shared library (Windows)
    Version: string;        // version string reported by the DLL, e.g. "1.26.0"
    RequestedApi: Integer;  // ORT_API_VERSION the Pascal bindings ask GetApi() for
    ApiAvailable: Boolean;  // True if GetApi(RequestedApi) returned a usable pointer
    BaseAvailable: Boolean; // True if OrtGetApiBase() returned non-nil
  end;

{ Queries the loaded onnxruntime library. Never raises. }
function GetOrtRuntimeInfo: TOrtRuntimeInfo;

{ Heuristic: ORT older than ~1.17 cannot load ONNX models with IR version 10.
  Returns True when the parsed version looks too old for modern HF exports. }
function OrtVersionLooksTooOldForIR10(const AVersion: string): Boolean;

{ Writes the runtime info to ErrOutput (stderr). }
procedure PrintOrtRuntimeInfo(const APrefix: string = '[localvector] ');

const
  {$IFDEF MSWINDOWS}
  ORT_LIB = 'onnxruntime.dll';
  {$ELSE}
    {$IFDEF DARWIN}
  ORT_LIB = 'onnxruntime.dylib';
    {$ELSE}
  ORT_LIB = 'onnxruntime.so';
    {$ENDIF}
  {$ENDIF}

implementation

{$IFDEF MSWINDOWS}
uses
  {$IFDEF FPC}Windows{$ELSE}Winapi.Windows{$ENDIF};
{$ENDIF}

{$IFDEF MSWINDOWS}
function ModulePathForHandle(H: HMODULE): string;
var
  Buf: array[0..1023] of WideChar;
  N: DWORD;
  W: WideString;
begin
  Result := '';
  if H = 0 then
    Exit;
  N := GetModuleFileNameW(H, @Buf[0], Length(Buf));
  if N > 0 then
  begin
    W := PWideChar(@Buf[0]);
    Result := string(W);
  end;
end;
{$ENDIF}

function GetOrtRuntimeInfo: TOrtRuntimeInfo;
var
  Base: POrtApiBase;
  VerPtr: POrtChar;
begin
  Result.DllPath := '';
  Result.Version := '';
  Result.RequestedApi := ORT_API_VERSION;
  Result.ApiAvailable := False;
  Result.BaseAvailable := False;

  {$IFDEF MSWINDOWS}
  if OrtRuntimeLibHandle <> 0 then
    Result.DllPath := ModulePathForHandle(HMODULE(OrtRuntimeLibHandle))
  else
    Result.DllPath := ModulePathForHandle(GetModuleHandleW(PWideChar(WideString(ORT_LIB))));
  {$ENDIF}

  Base := nil;
  if Assigned(OrtGetApiBase) then
    try
      Base := OrtGetApiBase();
    except
      Base := nil;
    end;

  if Base <> nil then
  begin
    Result.BaseAvailable := True;
    if Assigned(Base^.GetVersionString) then
    begin
      VerPtr := Base^.GetVersionString();
      if VerPtr <> nil then
        Result.Version := string(AnsiString(PAnsiChar(VerPtr)));
    end;
    if Assigned(Base^.GetApi) then
      Result.ApiAvailable := Base^.GetApi(ORT_API_VERSION) <> nil;
  end;
end;

function OrtVersionLooksTooOldForIR10(const AVersion: string): Boolean;
var
  P: Integer;
  S, MajS, MinS: string;
  Major, Minor: Integer;
begin
  // Be conservative: only report "too old" when we can confidently parse a
  // major.minor that is below 1.17. Unknown/unparseable -> not flagged.
  Result := False;
  S := Trim(AVersion);
  if S = '' then Exit;

  P := Pos('.', S);
  if P <= 0 then Exit;
  MajS := Copy(S, 1, P - 1);
  S := Copy(S, P + 1, Length(S));
  P := Pos('.', S);
  if P > 0 then
    MinS := Copy(S, 1, P - 1)
  else
    MinS := S;

  if not TryStrToInt(Trim(MajS), Major) then Exit;
  if not TryStrToInt(Trim(MinS), Minor) then Exit;

  Result := (Major < 1) or ((Major = 1) and (Minor < 17));
end;

procedure PrintOrtRuntimeInfo(const APrefix: string);
var
  Info: TOrtRuntimeInfo;
begin
  Info := GetOrtRuntimeInfo;
  WriteLn(ErrOutput, APrefix, 'onnxruntime library:');
  if Info.DllPath <> '' then
    WriteLn(ErrOutput, APrefix, '  loaded from : ', Info.DllPath)
  else
    WriteLn(ErrOutput, APrefix, '  loaded from : (unknown on this platform)');
  if Info.Version <> '' then
    WriteLn(ErrOutput, APrefix, '  version     : ', Info.Version)
  else
    WriteLn(ErrOutput, APrefix, '  version     : (could not query)');
  WriteLn(ErrOutput, APrefix, '  bindings ask: ORT_API_VERSION ', Info.RequestedApi,
                              '  (GetApi ', BoolToStr(Info.ApiAvailable, True), ')');
  if (Info.Version <> '') and OrtVersionLooksTooOldForIR10(Info.Version) then
  begin
    WriteLn(ErrOutput, APrefix, '  NOTE: this runtime predates ONNX IR v10 support.');
    WriteLn(ErrOutput, APrefix, '        Modern Hugging Face models (IR v10) will fail to load.');
    WriteLn(ErrOutput, APrefix, '        Place a current onnxruntime.dll (>= 1.17) next to this exe.');
  end;
end;

end.
