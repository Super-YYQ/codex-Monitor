# Runs every *.test.ps1 in tests/, each in its own PowerShell process for scope
# isolation, and exits non-zero if any file fails.
# Usage: pwsh tests/run-all.ps1   (or: powershell -File tests/run-all.ps1)

$ErrorActionPreference = 'Stop'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$pwsh = (Get-Process -Id $PID).Path
if (-not $pwsh) { $pwsh = "$PSHOME\pwsh.exe" }

$testFiles = Get-ChildItem -LiteralPath $testsDir -Filter '*.test.ps1' | Sort-Object Name
if (-not $testFiles) {
    Write-Host 'No test files found.' -ForegroundColor Yellow
    exit 1
}

$passed = @()
$failed = @()

foreach ($file in $testFiles) {
    Write-Host ''
    Write-Host "== $($file.Name) ==" -ForegroundColor Yellow
    $out = & $pwsh -NoProfile -ExecutionPolicy Bypass -File $file.FullName 2>&1
    $out | ForEach-Object { Write-Host "$_" }
    if ($LASTEXITCODE -eq 0) {
        $passed += $file.Name
    } else {
        $failed += $file.Name
        Write-Host "  -> FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
    }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "RESULT: $($passed.Count) passed, $($failed.Count) failed. Failed: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: all $($passed.Count) test file(s) passed." -ForegroundColor Green
exit 0
