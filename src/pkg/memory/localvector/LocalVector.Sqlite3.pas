{
  Vendored from FMXExpress/localvector (MIT licensed; LICENSE preserved
  alongside this file). Upstream commit: 0f00eece553da47e83169ddc8d72965c0dc40bcc.
  https://github.com/FMXExpress/localvector

  Modifications kept to a minimum -- PasClaw uses these units verbatim
  as the in-tree implementation of the hybrid FTS5+vector memory backend
  (PasClaw.Memory.Vector). Diff against upstream for change tracking.
}

unit LocalVector.Sqlite3;

{ Minimal, dynamically-loaded binding to the SQLite C API -- just the calls the
  portable vector store needs (open, prepare/step/finalize, bind/column,
  enable/load extension). The library is resolved at run time (libsqlite3.so on
  POSIX, sqlite3.dll on Windows), so there is no link-time dependency.

  This backs the FPC build; the Delphi build uses FireDAC instead. }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

// The sqlite-vec (vec0) loadable extension references libm (e.g. sqrtf); make
// sure libm is in the process so the runtime can resolve those symbols.
{$IFDEF FPC}{$IFDEF UNIX}{$LINKLIB m}{$ENDIF}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils
{$ELSE}
  System.SysUtils
{$ENDIF}
{$IFDEF MSWINDOWS}
  , {$IFDEF FPC}Windows{$ELSE}Winapi.Windows{$ENDIF}
{$ELSE}
  {$IFDEF FPC}
  , dynlibs
  {$ELSE}
  (* Delphi non-Windows (Linux64) -- the FPC `dynlibs` unit doesn't
     exist here, so we get dlopen / dlsym out of Posix.Dlfcn instead.
     Without this import the original non-FPC branch tried to call
     FPC's LoadLibrary(string) and GetProcedureAddress, which dcc64
     on Linux can't resolve. Paren-star delimiters so the IFDEF/ELSE
     tokens inside this comment don't trip Delphi's preprocessor. *)
  , Posix.Dlfcn
  {$ENDIF}
{$ENDIF}
  ;

const
  SQLITE_OK     = 0;
  SQLITE_ROW    = 100;
  SQLITE_DONE   = 101;
  SQLITE_OPEN_READWRITE = $0002;
  SQLITE_OPEN_CREATE    = $0004;

type
  PSQLite3 = Pointer;
  PSQLite3Stmt = Pointer;
  ESQLiteError = class(Exception);

{ Loads libsqlite3 / sqlite3.dll and resolves the entry points. Returns True on
  success. Safe to call repeatedly. }
function LoadSqlite3(const APath: string = ''): Boolean;
function Sqlite3Loaded: Boolean;

// Thin Pascal wrappers (raise ESQLiteError on failure where useful).
function sqlite_open(const AFileName: string): PSQLite3;
procedure sqlite_close(db: PSQLite3);
procedure sqlite_exec(db: PSQLite3; const ASql: string);
function sqlite_prepare(db: PSQLite3; const ASql: string): PSQLite3Stmt;
function sqlite_step(stmt: PSQLite3Stmt): Integer;
procedure sqlite_finalize(stmt: PSQLite3Stmt);
procedure sqlite_reset(stmt: PSQLite3Stmt);
procedure sqlite_bind_int64(stmt: PSQLite3Stmt; idx: Integer; v: Int64);
procedure sqlite_bind_double(stmt: PSQLite3Stmt; idx: Integer; v: Double);
procedure sqlite_bind_text(stmt: PSQLite3Stmt; idx: Integer; const v: string);
procedure sqlite_bind_blob(stmt: PSQLite3Stmt; idx: Integer; const v; n: Integer);
function sqlite_column_int64(stmt: PSQLite3Stmt; col: Integer): Int64;
function sqlite_column_double(stmt: PSQLite3Stmt; col: Integer): Double;
function sqlite_column_text(stmt: PSQLite3Stmt; col: Integer): string;
function sqlite_last_insert_rowid(db: PSQLite3): Int64;
procedure sqlite_load_extension(db: PSQLite3; const APath, AEntry: string);

implementation

type
  TOrdHandle = {$IFDEF MSWINDOWS}HMODULE{$ELSE}{$IFDEF FPC}TLibHandle{$ELSE}NativeUInt{$ENDIF}{$ENDIF};

  Tsqlite3_open = function(filename: PAnsiChar; var ppDb: PSQLite3): Integer; cdecl;
  Tsqlite3_close = function(db: PSQLite3): Integer; cdecl;
  Tsqlite3_exec = function(db: PSQLite3; sql: PAnsiChar; cb, arg, errmsg: Pointer): Integer; cdecl;
  Tsqlite3_prepare_v2 = function(db: PSQLite3; sql: PAnsiChar; n: Integer; var stmt: PSQLite3Stmt; tail: Pointer): Integer; cdecl;
  Tsqlite3_step = function(stmt: PSQLite3Stmt): Integer; cdecl;
  Tsqlite3_finalize = function(stmt: PSQLite3Stmt): Integer; cdecl;
  Tsqlite3_reset = function(stmt: PSQLite3Stmt): Integer; cdecl;
  Tsqlite3_bind_int64 = function(stmt: PSQLite3Stmt; idx: Integer; v: Int64): Integer; cdecl;
  Tsqlite3_bind_double = function(stmt: PSQLite3Stmt; idx: Integer; v: Double): Integer; cdecl;
  Tsqlite3_bind_text = function(stmt: PSQLite3Stmt; idx: Integer; v: PAnsiChar; n: Integer; destructor_: Pointer): Integer; cdecl;
  Tsqlite3_bind_blob = function(stmt: PSQLite3Stmt; idx: Integer; v: Pointer; n: Integer; destructor_: Pointer): Integer; cdecl;
  Tsqlite3_column_int64 = function(stmt: PSQLite3Stmt; col: Integer): Int64; cdecl;
  Tsqlite3_column_double = function(stmt: PSQLite3Stmt; col: Integer): Double; cdecl;
  Tsqlite3_column_text = function(stmt: PSQLite3Stmt; col: Integer): PAnsiChar; cdecl;
  Tsqlite3_last_insert_rowid = function(db: PSQLite3): Int64; cdecl;
  Tsqlite3_errmsg = function(db: PSQLite3): PAnsiChar; cdecl;
  Tsqlite3_enable_load_extension = function(db: PSQLite3; onoff: Integer): Integer; cdecl;
  Tsqlite3_load_extension = function(db: PSQLite3; afile, aproc: PAnsiChar; var errmsg: PAnsiChar): Integer; cdecl;

var
  _lib: TOrdHandle = 0;
  _open: Tsqlite3_open = nil;
  _close: Tsqlite3_close = nil;
  _exec: Tsqlite3_exec = nil;
  _prepare: Tsqlite3_prepare_v2 = nil;
  _step: Tsqlite3_step = nil;
  _finalize: Tsqlite3_finalize = nil;
  _reset: Tsqlite3_reset = nil;
  _bind_int64: Tsqlite3_bind_int64 = nil;
  _bind_double: Tsqlite3_bind_double = nil;
  _bind_text: Tsqlite3_bind_text = nil;
  _bind_blob: Tsqlite3_bind_blob = nil;
  _col_int64: Tsqlite3_column_int64 = nil;
  _col_double: Tsqlite3_column_double = nil;
  _col_text: Tsqlite3_column_text = nil;
  _last_rowid: Tsqlite3_last_insert_rowid = nil;
  _errmsg: Tsqlite3_errmsg = nil;
  _enable_load: Tsqlite3_enable_load_extension = nil;
  _load_ext: Tsqlite3_load_extension = nil;

function ldLib(const AName: string): TOrdHandle;
begin
{$IFDEF MSWINDOWS}
  Result := LoadLibrary(PChar(AName));
{$ELSE}
  {$IFDEF FPC}
  Result := LoadLibrary(AName);
  {$ELSE}
  { Delphi Linux: Posix.Dlfcn declares dlopen returning the handle
    as NativeUInt (the RTL wraps the POSIX void* as an ordinal, like
    HMODULE on Windows), which is exactly TOrdHandle here -- no cast.
    RTLD_NOW resolves every symbol up front so a missing entrypoint
    surfaces here, not on the first call -- mirrors what FPC's
    LoadLibrary does internally on POSIX. }
  Result := dlopen(PAnsiChar(AnsiString(AName)), RTLD_NOW);
  {$ENDIF}
{$ENDIF}
end;

function ldProc(h: TOrdHandle; const AName: string): Pointer;
begin
{$IFDEF MSWINDOWS}
  Result := GetProcAddress(h, PAnsiChar(AnsiString(AName)));
{$ELSE}
  {$IFDEF FPC}
  Result := GetProcedureAddress(h, AName);
  {$ELSE}
  { Delphi Linux equivalent of FPC's GetProcedureAddress -- dlsym
    against the handle dlopen handed back. No cast: Delphi's
    Posix.Dlfcn declares dlsym(Handle: NativeUInt; ...) -- the RTL
    wraps the POSIX void* handle as an ordinal, same as HMODULE on
    Windows -- and h is already that type. Every earlier attempt to
    hand it a Pointer (Pointer(h), Pointer(NativeUInt(h)),
    PPointer(@h)^) drew E2010 "UInt64 and Pointer" because the
    PARAMETER wants the ordinal, not because the cast itself was
    ill-formed. }
  Result := dlsym(h, PAnsiChar(AnsiString(AName)));
  {$ENDIF}
{$ENDIF}
end;

function Sqlite3Loaded: Boolean;
begin
  Result := (_lib <> 0) and Assigned(_open);
end;

function LoadSqlite3(const APath: string): Boolean;

  function P(const n: string): Pointer;
  begin
    Result := ldProc(_lib, n);
  end;

begin
  if Sqlite3Loaded then
    Exit(True);

  if APath <> '' then
    _lib := ldLib(APath);
  if _lib = 0 then
  {$IFDEF MSWINDOWS}
    _lib := ldLib('sqlite3.dll');
  {$ELSE}
    begin
      _lib := ldLib('libsqlite3.so.0');
      if _lib = 0 then _lib := ldLib('libsqlite3.so');
      if _lib = 0 then _lib := ldLib('libsqlite3.dylib');
    end;
  {$ENDIF}
  if _lib = 0 then
    Exit(False);

  _open := Tsqlite3_open(P('sqlite3_open'));
  _close := Tsqlite3_close(P('sqlite3_close'));
  _exec := Tsqlite3_exec(P('sqlite3_exec'));
  _prepare := Tsqlite3_prepare_v2(P('sqlite3_prepare_v2'));
  _step := Tsqlite3_step(P('sqlite3_step'));
  _finalize := Tsqlite3_finalize(P('sqlite3_finalize'));
  _reset := Tsqlite3_reset(P('sqlite3_reset'));
  _bind_int64 := Tsqlite3_bind_int64(P('sqlite3_bind_int64'));
  _bind_double := Tsqlite3_bind_double(P('sqlite3_bind_double'));
  _bind_text := Tsqlite3_bind_text(P('sqlite3_bind_text'));
  _bind_blob := Tsqlite3_bind_blob(P('sqlite3_bind_blob'));
  _col_int64 := Tsqlite3_column_int64(P('sqlite3_column_int64'));
  _col_double := Tsqlite3_column_double(P('sqlite3_column_double'));
  _col_text := Tsqlite3_column_text(P('sqlite3_column_text'));
  _last_rowid := Tsqlite3_last_insert_rowid(P('sqlite3_last_insert_rowid'));
  _errmsg := Tsqlite3_errmsg(P('sqlite3_errmsg'));
  _enable_load := Tsqlite3_enable_load_extension(P('sqlite3_enable_load_extension'));
  _load_ext := Tsqlite3_load_extension(P('sqlite3_load_extension'));

  Result := Assigned(_open) and Assigned(_prepare) and Assigned(_step);
end;

function ErrMsg(db: PSQLite3): string;
begin
  if Assigned(_errmsg) and (db <> nil) then
    Result := string(AnsiString(_errmsg(db)))
  else
    Result := '(unknown sqlite error)';
end;

function sqlite_open(const AFileName: string): PSQLite3;
var
  rc: Integer;
begin
  Result := nil;
  rc := _open(PAnsiChar(UTF8Encode(AFileName)), Result);
  if rc <> SQLITE_OK then
    raise ESQLiteError.CreateFmt('sqlite open failed (%d): %s', [rc, ErrMsg(Result)]);
end;

procedure sqlite_close(db: PSQLite3);
begin
  if (db <> nil) and Assigned(_close) then
    _close(db);
end;

procedure sqlite_exec(db: PSQLite3; const ASql: string);
var
  rc: Integer;
begin
  rc := _exec(db, PAnsiChar(UTF8Encode(ASql)), nil, nil, nil);
  if rc <> SQLITE_OK then
    raise ESQLiteError.CreateFmt('sqlite exec failed (%d): %s'#10'SQL: %s',
      [rc, ErrMsg(db), ASql]);
end;

function sqlite_prepare(db: PSQLite3; const ASql: string): PSQLite3Stmt;
var
  rc: Integer;
  U: RawByteString;
begin
  Result := nil;
  U := UTF8Encode(ASql);
  rc := _prepare(db, PAnsiChar(U), Length(U), Result, nil);
  if rc <> SQLITE_OK then
    raise ESQLiteError.CreateFmt('sqlite prepare failed (%d): %s'#10'SQL: %s',
      [rc, ErrMsg(db), ASql]);
end;

function sqlite_step(stmt: PSQLite3Stmt): Integer;
begin
  Result := _step(stmt);
end;

procedure sqlite_finalize(stmt: PSQLite3Stmt);
begin
  if (stmt <> nil) and Assigned(_finalize) then
    _finalize(stmt);
end;

procedure sqlite_reset(stmt: PSQLite3Stmt);
begin
  _reset(stmt);
end;

procedure sqlite_bind_int64(stmt: PSQLite3Stmt; idx: Integer; v: Int64);
begin
  _bind_int64(stmt, idx, v);
end;

procedure sqlite_bind_double(stmt: PSQLite3Stmt; idx: Integer; v: Double);
begin
  _bind_double(stmt, idx, v);
end;

procedure sqlite_bind_text(stmt: PSQLite3Stmt; idx: Integer; const v: string);
var
  U: RawByteString;
begin
  U := UTF8Encode(v);
  // -1 length = NUL-terminated; SQLITE_TRANSIENT (-1) = sqlite copies the bytes.
  _bind_text(stmt, idx, PAnsiChar(U), Length(U), Pointer(-1));
end;

procedure sqlite_bind_blob(stmt: PSQLite3Stmt; idx: Integer; const v; n: Integer);
begin
  _bind_blob(stmt, idx, @v, n, Pointer(-1)); // SQLITE_TRANSIENT
end;

function sqlite_column_int64(stmt: PSQLite3Stmt; col: Integer): Int64;
begin
  Result := _col_int64(stmt, col);
end;

function sqlite_column_double(stmt: PSQLite3Stmt; col: Integer): Double;
begin
  Result := _col_double(stmt, col);
end;

function sqlite_column_text(stmt: PSQLite3Stmt; col: Integer): string;
var
  P: PAnsiChar;
begin
  P := _col_text(stmt, col);
  if P = nil then
    Result := ''
  else
    Result := string(UTF8ToString(P));
end;

function sqlite_last_insert_rowid(db: PSQLite3): Int64;
begin
  Result := _last_rowid(db);
end;

procedure sqlite_load_extension(db: PSQLite3; const APath, AEntry: string);
var
  rc: Integer;
  err: PAnsiChar;
  ep: PAnsiChar;
  eU: RawByteString;
begin
  if Assigned(_enable_load) then
    _enable_load(db, 1);
  err := nil;
  if AEntry <> '' then
  begin
    eU := UTF8Encode(AEntry);
    ep := PAnsiChar(eU);
  end
  else
    ep := nil;
  rc := _load_ext(db, PAnsiChar(UTF8Encode(APath)), ep, err);
  if Assigned(_enable_load) then
    _enable_load(db, 0);
  if rc <> SQLITE_OK then
    raise ESQLiteError.CreateFmt('load_extension(%s) failed (%d): %s',
      [APath, rc, string(AnsiString(err))]);
end;

end.
