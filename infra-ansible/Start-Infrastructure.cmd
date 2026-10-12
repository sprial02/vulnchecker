@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Infrastructure.ps1" %*
pause
