@echo off
REM Double-click to run the whole test suite. Nothing to install, and it never
REM touches a real game folder - every test builds its own throwaway one.
setlocal
powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0tests\Invoke-Tests.ps1"
echo.
pause
endlocal
