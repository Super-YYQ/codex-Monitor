# Runs every *.test.ps1 in tests/ and exits non-zero on any failure.
# Usage: pwsh tests/run-all.ps1   (or: powershell -File tests/run-all.ps1)

$ErrorActionPreference = 'Stop'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $testsDir 'test-helper.ps1')

$testFiles = Get-ChildItem -LiteralPath $testsDir -Filter '*.test.ps1' | Sort-Object Name
if (-not $testFiles) {
    Write-Host 'No test files found.' -ForegroundColor Yellow
    exit 1
}

$totalFailures = 0
$totalChecks = 0
$failedFiles = @()

foreach ($file in $testFiles) {
    Write-Host ''
    Write-Host "== $($file.Name) ==" -ForegroundColor Yellow
    $before = Get-TestResult
    try {
        & $file.FullName
    } catch {
        Write-Host "  FAIL: test script threw: $($_.Exception.Message)" -ForegroundColor Red
        $script:TestFailures++
    }
    $after = Get-TestResult
    $fileFails = $after.failures - $before.failures
    $fileChecks = $after.checks - $before.checks
    $totalFailures += $fileFails
    $totalChecks += $fileChecks
    if ($fileFails -gt 0) { $failedFiles += $file.Name }
}

Write-Host ''
if ($totalFailures -gt 0) {
    Write-Host "RESULT: $totalFailures failure(s) out of $totalChecks checks. Failed: $($failedFiles -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: all $totalChecks checks passed." -ForegroundColor Green
exit 0
