@echo off
REM Double-click launcher. Windows PowerShell 5.1 ships with Windows, so there
REM is nothing to install; -STA is what WPF needs, and -ExecutionPolicy Bypass
REM keeps an unsigned script from being blocked without changing any machine
REM setting.
setlocal
powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -STA -File "%~dp0PtrUiSetup.ps1" %*
if errorlevel 1 (
    echo.
    echo The tool exited with an error. The message above says why.
    pause
)
endlocal
