@echo off
rem Stub bcdedit: forwards to bcd.ps1 and propagates its exit code.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%OSSWITCH_STUB_DIR%\bcd.ps1" %*
exit /b %ERRORLEVEL%