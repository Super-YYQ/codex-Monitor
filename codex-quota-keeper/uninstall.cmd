@echo off
rem Codex Quota Keeper - 卸载入口
setlocal
set "ROOT=%~dp0"

where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\uninstall.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\uninstall.ps1"
)

echo.
echo Press any key to close...
pause >nul
endlocal