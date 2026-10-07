@echo off
setlocal
cd /d "%~dp0"
start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0VulnChecker.ps1" -Action Gui
