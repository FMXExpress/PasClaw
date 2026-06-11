@echo off
setlocal EnableExtensions

rem PasClaw FPC build helper for Windows.
rem Mirrors the repository Makefile defaults. Override FPC, BUILDDIR,
rem INDY_DIR, ICONVENC_DIR, or BIN in the environment if needed.

set "ROOT=%~dp0"
cd /d "%ROOT%" || exit /b 1

if "%FPC%"=="" set "FPC=fpc.exe"
if "%BUILDDIR%"=="" set "BUILDDIR=build"
if "%BIN%"=="" set "BIN=%BUILDDIR%\pasclaw.exe"
if "%INDY_DIR%"=="" set "INDY_DIR=vendor\Indy"
if "%ICONVENC_DIR%"=="" set "ICONVENC_DIR="

if exist "%FPC%" (
  rem FPC points directly at an executable path.
) else (
  where "%FPC%" >nul 2>nul
  if errorlevel 1 (
    echo ERROR: %FPC% was not found on PATH.
    echo Install Free Pascal 3.2 or newer, or set FPC=C:\path\to\fpc.exe.
    exit /b 1
  )
)

where fpcres.exe >nul 2>nul
if errorlevel 1 (
  echo ERROR: fpcres.exe was not found on PATH.
  echo Ensure the Free Pascal bin directory is on PATH before building.
  exit /b 1
)

if not exist "%INDY_DIR%\Lib\Core" (
  echo ERROR: Indy was not found at "%INDY_DIR%".
  echo Run "make get-indy" where make is available, or clone IndySockets/Indy to "%INDY_DIR%".
  exit /b 1
)

if not exist "%BUILDDIR%" mkdir "%BUILDDIR%" || exit /b 1
if not exist "%BUILDDIR%\lib" mkdir "%BUILDDIR%\lib" || exit /b 1

echo Compiling embedded web UI resource...
pushd src\pkg\gateway || exit /b 1
fpcres.exe -of res -o webui.res webui.rc
if errorlevel 1 (
  popd
  echo ERROR: Failed to compile src\pkg\gateway\webui.rc to src\pkg\gateway\webui.res.
  exit /b 1
)
popd

set "FPCFLAGS=-MDelphi -Sh -O2 -Xs -XX"
set "FPCFLAGS=%FPCFLAGS% -Fusrc\pkg\cliui -Fusrc\pkg\utils -Fusrc\pkg\logger -Fusrc\pkg\config -Fusrc\pkg\json -Fusrc\pkg\providers -Fusrc\pkg\stream -Fusrc\pkg\tokenizer -Fusrc\pkg\tools -Fusrc\pkg\mcp -Fusrc\pkg\gateway -Fusrc\pkg\channels -Fusrc\pkg\crypto -Fusrc\pkg\net -Fusrc\pkg\search -Fusrc\pkg\cron -Fusrc\pkg\skills -Fusrc\pkg\checkpoints -Fusrc\pkg\condense -Fusrc\pkg\session -Fusrc\pkg\identity -Fusrc\pkg\agent -Fusrc\pkg\memory -Fusrc\pkg\memory\localvector -Fusrc\pkg\kb -Fusrc\pkg\updater -Fusrc\pkg\membench -Fusrc\pkg\tui -Fusrc\pkg\platform -Fusrc\pkg\hashline -Fusrc\pkg\component -Fusrc\pkg\markdown -Fusrc\cmd"
set "FPCFLAGS=%FPCFLAGS% -Fu%INDY_DIR%\Lib\Core -Fu%INDY_DIR%\Lib\Protocols -Fu%INDY_DIR%\Lib\System -Fi%INDY_DIR%\Lib\Core -Fi%INDY_DIR%\Lib\Protocols -Fi%INDY_DIR%\Lib\System"
if not "%ICONVENC_DIR%"=="" set "FPCFLAGS=%FPCFLAGS% -Fu%ICONVENC_DIR%"
set "FPCFLAGS=%FPCFLAGS% -FE%BUILDDIR% -FU%BUILDDIR%\lib"

echo Building src\pasclaw\PasClaw.dpr with %FPC%...
"%FPC%" %FPCFLAGS% src\pasclaw\PasClaw.dpr -o"%BIN%"
if errorlevel 1 (
  echo ERROR: FPC build failed.
  exit /b 1
)

echo Build complete: %BIN%
