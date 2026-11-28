(*
  dynlibs for the FreePascalOS build of PasClaw.

  FPC's own dynlibs unit wants an include file for each operating system,
  and its source tree has none for FreePascalOS. There the System unit
  sets the dynamic library manager up by itself (the kernel loads
  libraries), so this unit only hands each call on to System -- the
  interface FPC's dynlibs has, for the units that use it (fcl-db's
  sqlite3dyn, LocalVector.Sqlite3, onnxruntime). Only `make fpos` puts
  src/fpos on the unit path.

  PasClaw's own code, MIT like the rest of it.
*)
unit dynlibs;

{$MODE OBJFPC}
{$H+}

interface

type
  TLibHandle = System.TLibHandle;
  HModule = TLibHandle;

const
  NilHandle = System.NilHandle;
  SharedSuffix = System.SharedSuffix;

function SafeLoadLibrary(const Name: RawByteString): TLibHandle; inline;
function LoadLibrary(const Name: RawByteString): TLibHandle; inline;
function SafeLoadLibrary(const Name: UnicodeString): TLibHandle; inline;
function LoadLibrary(const Name: UnicodeString): TLibHandle; inline;
function GetProcedureAddress(Lib: TLibHandle; const ProcName: AnsiString): Pointer; inline;
function GetProcedureAddress(Lib: TLibHandle; Ordinal: TOrdinalEntry): Pointer; inline;
function UnloadLibrary(Lib: TLibHandle): Boolean; inline;
function GetLoadErrorStr: string; inline;
function FreeLibrary(Lib: TLibHandle): Boolean; inline;
function GetProcAddress(Lib: TLibHandle; const ProcName: AnsiString): Pointer; inline;

implementation

function SafeLoadLibrary(const Name: RawByteString): TLibHandle;
begin
  Result := System.SafeLoadLibrary(Name);
end;

function LoadLibrary(const Name: RawByteString): TLibHandle;
begin
  Result := System.LoadLibrary(Name);
end;

function SafeLoadLibrary(const Name: UnicodeString): TLibHandle;
begin
  Result := System.SafeLoadLibrary(Name);
end;

function LoadLibrary(const Name: UnicodeString): TLibHandle;
begin
  Result := System.LoadLibrary(Name);
end;

function GetProcedureAddress(Lib: TLibHandle; const ProcName: AnsiString): Pointer;
begin
  Result := System.GetProcedureAddress(Lib, ProcName);
end;

function GetProcedureAddress(Lib: TLibHandle; Ordinal: TOrdinalEntry): Pointer;
begin
  Result := System.GetProcedureAddress(Lib, Ordinal);
end;

function UnloadLibrary(Lib: TLibHandle): Boolean;
begin
  Result := System.UnloadLibrary(Lib);
end;

function GetLoadErrorStr: string;
begin
  Result := System.GetLoadErrorStr;
end;

function FreeLibrary(Lib: TLibHandle): Boolean;
begin
  Result := System.FreeLibrary(Lib);
end;

function GetProcAddress(Lib: TLibHandle; const ProcName: AnsiString): Pointer;
begin
  Result := System.GetProcedureAddress(Lib, ProcName);
end;

end.
