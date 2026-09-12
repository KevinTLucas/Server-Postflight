@echo off
setlocal
title Server Postflight

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ServerPostflight.ps1"
set "RESULT=%ERRORLEVEL%"

echo.
if "%RESULT%"=="0" (
    echo Server Postflight finished: no failed targets.
) else (
    echo Server Postflight finished with failed checks or an error.
    echo Review the message above, then open the newest file in Reports.
)
echo Reports: %~dp0Reports
echo.
pause
exit /b %RESULT%
