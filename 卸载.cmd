@echo off
rem Uninstall entry: removes the shortcut / launcher, keeps your chat data by default.
rem Set DSH_NO_PAUSE=1 for unattended/testing runs.
chcp 65001 >nul
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
if "%DSH_NO_PAUSE%"=="1" goto :end
echo.
pause
:end
endlocal
