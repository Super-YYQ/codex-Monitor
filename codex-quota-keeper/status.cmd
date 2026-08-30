@echo off
rem Codex Quota Keeper - 双击查看状态（唯一日常入口，只读，不争抢 Leader）
setlocal
set "ROOT=%~dp0"

rem 优先 PowerShell 7，缺失则回退 Windows PowerShell
where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\status.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\status.ps1"
)

rem 暂停便于阅读（若传入 --no-pause 则不暂停）
if /i "%~1"=="--no-pause" goto :eof
echo.
echo Press any key to close...
pause >nul
endlocal