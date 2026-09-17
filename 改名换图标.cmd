@echo off
rem Rename / re-icon the desktop shortcut. Interactive: asks for a name and lets you pick an icon.
rem Set DSH_NO_PAUSE=1 for unattended runs.
chcp 65001 >nul
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0shortcut.ps1" %*
if "%DSH_NO_PAUSE%"=="1" goto :end
echo.
pause
:end
endlocal
