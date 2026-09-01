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
    # EAP=Stop turns the child's first stderr line into a terminating error and
    # swallows its stdout, hiding every assertion result. Capture with EAP=Continue
    # so the child's full output (and stderr) always reaches the CI log.
    $hostEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $pwsh -NoProfile -ExecutionPolicy Bypass -File $file.FullName 2>&1
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $hostEap
    $out | ForEach-Object { Write-Host "$_" }
    if ($rc -eq 0) {
        $passed += $file.Name
    } else {
        $failed += $file.Name
        Write-Host "  -> FAILED (exit $rc)" -ForegroundColor Red
    }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "RESULT: $($passed.Count) passed, $($failed.Count) failed. Failed: $($failed -join ', ')" -ForegroundColor Red
    Write-Host "Mock trace files kept for forensics: $env:TEMP\cqk-mock-trace" -ForegroundColor Yellow
    exit 1
}
# Mock trace files (tests only) - scrub them once everything passed.
try { Remove-Item -LiteralPath (Join-Path $env:TEMP 'cqk-mock-trace') -Recurse -Force -ErrorAction SilentlyContinue } catch { }
Write-Host "RESULT: all $($passed.Count) test file(s) passed." -ForegroundColor Green
exit 0
