@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-WSL.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%~1"=="" pause
exit /b %EXIT_CODE%
