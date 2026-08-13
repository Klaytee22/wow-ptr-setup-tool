@echo off
REM Double-click this first. It builds a fake World of Warcraft folder on your
REM desktop and opens the window pointed at it, so you can try every button
REM without going near your real game folder.
REM
REM Same switches as Start-PtrUiSetup.cmd: -STA is what WPF needs, and
REM -ExecutionPolicy Bypass keeps an unsigned script from being blocked for this
REM one process without changing any machine setting.
setlocal
echo Building a fake World of Warcraft folder on your desktop...
echo (Rebuilt from scratch each time you run this. Delete PtrUiSetup-Mock when done.)
echo.
powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -STA -File "%~dp0tools\New-MockWowFolder.ps1" -Force -Launch
if errorlevel 1 (
    echo.
    echo That did not work. The message above says why.
    pause
    exit /b 1
)
endlocal
