@echo off
rem Codex Quota Keeper - 双击查看状态（唯一日常入口，只读，不争抢 Leader）
setlocal
set "ROOT=%~dp0"
set "STATUS_FLAGS="
set "NO_PAUSE="

:parse_args
if "%~1"=="" goto :run_status
if /i "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
) else if /i "%~1"=="-Live" (
    set "STATUS_FLAGS=%STATUS_FLAGS% -Live"
) else if /i "%~1"=="-Detailed" (
    set "STATUS_FLAGS=%STATUS_FLAGS% -Detailed"
) else if /i "%~1"=="-NoColor" (
    set "STATUS_FLAGS=%STATUS_FLAGS% -NoColor"
) else (
    echo Usage: status.cmd [-Live] [-Detailed] [-NoColor] [--no-pause]
    exit /b 2
)
shift
goto :parse_args

:run_status

rem 优先 PowerShell 7，缺失则回退 Windows PowerShell
where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\status.ps1" %STATUS_FLAGS%
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\status.ps1" %STATUS_FLAGS%
)
set "STATUS_EXIT=%errorlevel%"

rem 暂停便于阅读（若传入 --no-pause 则不暂停）
if defined NO_PAUSE exit /b %STATUS_EXIT%
echo.
echo Press any key to close...
pause >nul
exit /b %STATUS_EXIT%
