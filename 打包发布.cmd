@echo off
rem Packaging entry: builds a clean distribution zip (without local run artifacts).
rem Set DSH_NO_PAUSE=1 for unattended runs.
chcp 65001 >nul
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0pack-release.ps1" %*
if "%DSH_NO_PAUSE%"=="1" goto :end
echo.
pause
:end
endlocal