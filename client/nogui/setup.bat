@echo off
rem First-time setup: detect game, update once, show the Steam launch option
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0deadlock_zhtw_localization.ps1" -Setup
echo.
pause
