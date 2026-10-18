@echo off
rem ============================================================
rem  Steam launch option (set once):
rem    "<this folder>\launch.bat" %command%
rem  Updates the zh-TW files first, then starts the game.
rem  If the update fails for any reason, the game still starts.
rem ============================================================
chcp 65001 >nul

if exist "%~dp0deadlock_zhtw_localization.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0deadlock_zhtw_localization.ps1" -Quiet
)

rem Start the game (Steam passes the full game command as arguments)
%*
