@echo off
REM Build the PasClaw Windows installers (x64 and x86) with Inno Setup.
REM Usage:  build.bat [version]
REM   e.g.  build.bat 0.2.0
REM Requires: Inno Setup 6 (iscc.exe on PATH) and Release builds at
REM           ..\build\delphi\Win64\Release\PasClaw.exe   (x64)
REM           ..\build\delphi\Win32\Release\PasClaw.exe   (x86)
setlocal enabledelayedexpansion
set VER=%1
if "%VER%"=="" set VER=0.1.0
set ROOT=%~dp0..

set ANY=0
for %%A in (x64 x86) do (
  if "%%A"=="x64" (set PLAT=Win64) else (set PLAT=Win32)
  if exist "%ROOT%\build\delphi\!PLAT!\Release\PasClaw.exe" (
    echo === building %%A installer ===
    iscc /DArch=%%A /DMyAppVersion=%VER% "%~dp0pasclaw.iss" || exit /b 1
    set ANY=1
  ) else (
    echo [warn] %%A binary missing: build\delphi\!PLAT!\Release\PasClaw.exe -- skipping
  )
)
if "%ANY%"=="0" (
  echo [error] no binaries found. Build the Release/Win64 and/or Release/Win32
  echo         target of src\pasclaw\PasClaw.dproj first.
  exit /b 1
)
echo Done. Installers are in installer\Output\.
