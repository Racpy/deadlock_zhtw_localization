@echo off
rem Restore the game files to what they were before the first update
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0deadlock_zhtw_localization.ps1" -Restore
echo.
pause
