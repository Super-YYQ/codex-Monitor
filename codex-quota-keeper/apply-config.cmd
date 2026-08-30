@echo off
rem Codex Quota Keeper - 修改 config.json 后应用（更新计划任务周期）
setlocal
set "ROOT=%~dp0"

where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\apply-config.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\apply-config.ps1"
)

echo.
echo Press any key to close...
pause >nul
endlocal