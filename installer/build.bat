@echo off
REM Build the PasClaw Windows installer with Inno Setup.
REM Usage:  build.bat [version]
REM   e.g.  build.bat 0.2.0
REM Requires: Inno Setup 6 (iscc.exe on PATH) and a Release Win64 build at
REM           ..\build\delphi\Win64\Release\PasClaw.exe
setlocal
set VER=%1
if "%VER%"=="" set VER=0.1.0

set EXE=%~dp0..\build\delphi\Win64\Release\PasClaw.exe
if not exist "%EXE%" (
  echo [error] %EXE% not found.
  echo         Build the Release / Win64 target of src\pasclaw\PasClaw.dproj first.
  exit /b 1
)

iscc /DMyAppVersion=%VER% "%~dp0pasclaw.iss"
