@echo off
REM Double-click launcher. Windows PowerShell 5.1 ships with Windows, so there
REM is nothing to install; -STA is what WPF needs, and -ExecutionPolicy Bypass
REM keeps an unsigned script from being blocked without changing any machine
REM setting.
setlocal
powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -STA -File "%~dp0PtrUiSetup.ps1" %*

REM Compared against 0 rather than "if errorlevel 1". That form is a
REM greater-than-or-equal test, so it misses the negative codes a process gets
REM when it is killed or crashes outright - which is exactly the case where the
REM console must not vanish before anyone has read it.
if not "%ERRORLEVEL%"=="0" (
    echo.
    echo ---------------------------------------------------------------
    echo The tool exited with code %ERRORLEVEL%.
    echo.
    echo The message above says why. It is also saved to:
    echo   %TEMP%\ptrsetup-error.log
    echo.
    echo Send that file to whoever gave you this.
    echo ---------------------------------------------------------------
    echo.
    pause
)
endlocal
