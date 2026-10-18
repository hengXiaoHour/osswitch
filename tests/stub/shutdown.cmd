@echo off
rem Stub shutdown.exe: records the request instead of rebooting this machine.
echo %*>> "%OSSWITCH_STUB_DIR%\shutdown.log"
exit /b 0