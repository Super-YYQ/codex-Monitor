# Regenerates tests/golden/*.txt - the four §17.2 Status panel snapshots (CQK-030).
#
#   powershell tests/golden-update.ps1
#   pwsh       tests/golden-update.ps1
#
# status-display.test.ps1 compares the live renderer against these files line for
# line, so this script is the only sanctioned way to change a snapshot. Review such a
# diff like any other output contract: §17.2 wants exactly this - "新增字段不会不小心
# 破坏排版" only holds if a layout change has to be committed on purpose.
#
# The scenario fixtures live in golden-fixtures.ps1, shared with the test that checks
# them. That file carries the two determinism rules (offset-less wall clock, host-local
# epochs) that keep a CI run in UTC byte-identical to a dev box in +08:00.

$ErrorActionPreference = 'Stop'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
. (Join-Path $testsDir 'golden-fixtures.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
$goldenDir = Join-Path $testsDir 'golden'

. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'state-machine.ps1')
. (Join-Path $scriptDir 'status-assessment.ps1')
. (Join-Path $scriptDir 'status-display.ps1')

$Now = Get-GoldenNow
$cases = Get-GoldenCases

if (-not (Test-Path -LiteralPath $goldenDir)) {
    New-Item -ItemType Directory -Path $goldenDir -Force | Out-Null
}
foreach ($name in $cases.Keys) {
    $c = $cases[$name]
    # A fresh runtime dir per case: Load-KeeperState / Get-BackoffState must take
    # their real "no state yet" path, and one case's anchors must not leak into the
    # next.
    $ws = New-TestWorkspace
    try {
        $root = Join-Path $ws 'keeper'
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'runtime\logs') | Out-Null
        Install-GoldenCaseState -Case $c -KeeperRoot $root
        $text = Get-GoldenCaseText -Case $c -KeeperRoot $root -Now $Now
        $path = Join-Path $goldenDir ($name + '.txt')
        # LF + trailing newline, written byte-explicit: PS 5.1's Set-Content
        # -Encoding UTF8 prepends a BOM, and the comparison in the test is a raw read.
        [System.IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "wrote $path" -ForegroundColor Green
    } finally {
        Remove-TestWorkspace $ws
    }
}
