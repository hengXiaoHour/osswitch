@echo off
rem ---------------------------------------------------------------------------
rem Desktop shortcut entry point for osswitch.
rem
rem This wrapper exists so that a double-click leaves a BREADCRUMB on disk
rem before PowerShell is even started. If the log stays empty we know the click
rem never reached PowerShell, which is a completely different fault from the
rem script failing once it starts.
rem
rem   %1 = windows | manjaro
rem ---------------------------------------------------------------------------
setlocal
set "LOG=%LOCALAPPDATA%\osswitch\launcher.log"
if not exist "%LOG%" mkdir "%LOCALAPPDATA%\osswitch" 2>nul
>>"%LOG%" echo [%DATE% %TIME%] SHORTCUT STARTED  target=%~1

where powershell.exe >>"%LOG%" 2>&1
if errorlevel 1 >>"%LOG%" echo [%DATE% %TIME%] ERROR powershell.exe not on PATH

rem manjaro is already the first boot choice, so that icon is a plain restart and
rem needs no administrator rights. The windows icon genuinely has to change the
rem boot order, so it keeps the full launcher.
set "SCRIPT=%~dp0osswitch-launch.ps1"
set "SARGS=-Target %~1"
if /i "%~1"=="manjaro" set "SCRIPT=%~dp0boot-manjaro.ps1"
if /i "%~1"=="manjaro" set "SARGS="

if not exist "%SCRIPT%" (
    >>"%LOG%" echo [%DATE% %TIME%] ERROR script missing: %SCRIPT%
    type "%LOG%"
    timeout /t 15 /nobreak >nul
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %SARGS%
set "RC=%ERRORLEVEL%"
>>"%LOG%" echo [%DATE% %TIME%] SHORTCUT FINISHED  rc=%RC%
exit /b %RC%