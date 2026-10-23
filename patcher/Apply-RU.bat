@echo off
chcp 65001 >nul
setlocal
powershell.exe -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply.ps1"
echo.
pause
