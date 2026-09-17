@echo off
rem Repair entry: re-checks everything and only fills in what is missing.
rem Set DSH_NO_PAUSE=1 for unattended/testing runs.
chcp 65001 >nul
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Repair %*
if "%DSH_NO_PAUSE%"=="1" goto :end
echo.
pause
:end
endlocal
