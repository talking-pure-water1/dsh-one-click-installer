@echo off
rem One-click update: updates the globally installed @deepseek-ai/dsh to the latest version.
rem Set DSH_NO_PAUSE=1 for unattended runs.
chcp 65001 >nul
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-dsh.ps1" %*
if "%DSH_NO_PAUSE%"=="1" goto :end
echo.
pause
:end
endlocal
