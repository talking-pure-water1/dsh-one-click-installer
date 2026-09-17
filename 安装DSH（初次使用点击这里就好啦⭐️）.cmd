@echo off
rem ============================================================
rem  DSH one-click installer entry
rem  All Chinese UI text lives in install.ps1 (UTF-8 with BOM);
rem  this wrapper stays ASCII-only and bypasses the execution
rem  policy, which is Restricted on many fresh Windows machines.
rem  Set DSH_NO_PAUSE=1 for unattended/testing runs.
rem ============================================================
chcp 65001 >nul
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
if "%DSH_NO_PAUSE%"=="1" goto :end
echo.
pause
:end
endlocal
