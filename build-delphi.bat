@echo off
setlocal EnableExtensions

rem PasClaw Delphi/RAD Studio build helper for Windows.
rem Prefer MSBuild and the checked-in .dproj so source paths stay centralized.
rem Override CONFIG and PLATFORM in the environment if needed.

set "ROOT=%~dp0"
cd /d "%ROOT%" || exit /b 1

if "%CONFIG%"=="" set "CONFIG=Release"
if "%PLATFORM%"=="" set "PLATFORM=Win64"
set "DPROJ=src\pasclaw\PasClaw.dproj"
set "DPR=src\pasclaw\PasClaw.dpr"

if not exist "%DPROJ%" (
  echo ERROR: Expected Delphi project "%DPROJ%" was not found.
  exit /b 1
)

call :compile_resource || exit /b 1

where msbuild.exe >nul 2>nul
if not errorlevel 1 (
  echo Building %DPROJ% with MSBuild ^(%CONFIG%^|%PLATFORM%^)...
  msbuild.exe "%DPROJ%" /t:Build /p:Config=%CONFIG% /p:Platform=%PLATFORM%
  if errorlevel 1 (
    echo ERROR: Delphi MSBuild build failed.
    exit /b 1
  )
  echo Build complete.
  exit /b 0
)

where dcc64.exe >nul 2>nul
if errorlevel 1 (
  echo ERROR: Neither msbuild.exe nor dcc64.exe was found on PATH.
  echo Open a RAD Studio command prompt, or run rsvars.bat before this script.
  exit /b 1
)

if not exist "build\delphi\%PLATFORM%\%CONFIG%" mkdir "build\delphi\%PLATFORM%\%CONFIG%" || exit /b 1
if not exist "build\delphi\%PLATFORM%\%CONFIG%\dcu" mkdir "build\delphi\%PLATFORM%\%CONFIG%\dcu" || exit /b 1

set "UNIT_PATH=src\cmd;src\pkg\cliui;src\pkg\utils;src\pkg\logger;src\pkg\config;src\pkg\json;src\pkg\providers;src\pkg\stream;src\pkg\tokenizer;src\pkg\tools;src\pkg\mcp;src\pkg\gateway;src\pkg\channels;src\pkg\crypto;src\pkg\net;src\pkg\search;src\pkg\cron;src\pkg\skills;src\pkg\checkpoints;src\pkg\session;src\pkg\identity;src\pkg\agent;src\pkg\memory;src\pkg\memory\localvector;src\pkg\kb;src\pkg\updater;src\pkg\membench;src\pkg\tui;src\pkg\platform;src\pkg\hashline;src\pkg\component;src\pkg\markdown;src\pkg\vendor\dmvcframework"

echo Building %DPR% with dcc64.exe...
rem -DPASCLAW_NETHTTP routes outbound HTTP through System.Net.HttpClient
rem so the Delphi build uses SChannel for TLS instead of needing the
rem OpenSSL DLLs shipped alongside pasclaw.exe. The .dproj path picks
rem this up via DCC_Define; the direct-dcc64 path needs it explicitly.
dcc64.exe -B -CC -E"build\delphi\%PLATFORM%\%CONFIG%" -N0"build\delphi\%PLATFORM%\%CONFIG%\dcu" -U"%UNIT_PATH%" -NSSystem;System.Net;System.Win;Xml;Data;Datasnap;Web;Soap;Winapi -DPASCLAW_NETHTTP "%DPR%"
if errorlevel 1 (
  echo ERROR: Delphi dcc64 build failed.
  exit /b 1
)

echo Build complete.
exit /b 0

:compile_resource
where brcc32.exe >nul 2>nul
if not errorlevel 1 (
  echo Compiling embedded web UI resource with brcc32...
  pushd src\pkg\gateway || exit /b 1
  brcc32.exe webui.rc
  if errorlevel 1 (
    popd
    echo ERROR: Failed to compile src\pkg\gateway\webui.rc with brcc32.exe.
    exit /b 1
  )
  popd
  exit /b 0
)

where rc.exe >nul 2>nul
if not errorlevel 1 (
  echo Compiling embedded web UI resource with rc...
  pushd src\pkg\gateway || exit /b 1
  rc.exe /fo webui.res webui.rc
  if errorlevel 1 (
    popd
    echo ERROR: Failed to compile src\pkg\gateway\webui.rc with rc.exe.
    exit /b 1
  )
  popd
  exit /b 0
)

echo ERROR: Neither brcc32.exe nor rc.exe was found on PATH.
echo Open a RAD Studio command prompt, or run rsvars.bat before this script.
exit /b 1
