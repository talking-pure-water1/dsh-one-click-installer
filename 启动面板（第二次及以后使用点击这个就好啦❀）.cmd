@echo off
rem Graphical control panel entry: status, install/repair, start, update, rename/icon, uninstall.
rem Set DSH_NO_PAUSE=1 for unattended runs.
chcp 65001 >nul
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0panel.ps1" %*
if "%DSH_NO_PAUSE%"=="1" goto :end
echo.
pause
:end
endlocal
