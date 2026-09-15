# Exercise the real runner and all local audit surfaces with a mock app-server.
# This suite uses no Git remote, real account, model call, or scheduled task.
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'state-machine.ps1')
. (Join-Path $scriptDir 'logger.ps1')
. (Join-Path $scriptDir 'github-sync.ps1')
$pwsh = (Get-Process -Id $PID).Path
$ws = New-TestWorkspace
$savedMode = $env:CQK_MOCK_MODE
try {
    $config = New-TestConfig @{
        mode = 'MonitorOnly'
        github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } }
        codex = @{ command = (Join-Path $testsDir 'fixtures\mock-appserver.cmd') }
    }
    $configFile = Write-TestConfigFile (Join-Path $ws 'config.json') $config
    # The mock reset mode returns primary=2 at 1900000000 and secondary=18.
    # Seed the old primary boundary in the future with 90% used.
    $state = New-KeeperState
    $state.buckets = @(@{ bucketId = 'codex-default'; windows = @(
        @{ windowType = 'primary'; windowDurationMins = 300; usedPercent = 90; resetsAt = 1899990000; usable = $true },
        @{ windowType = 'secondary'; windowDurationMins = 10080; usedPercent = 18; resetsAt = 1788667200; usable = $true }
    ) })
    Save-KeeperState -Root $ws -State $state
    $env:CQK_MOCK_MODE = 'reset'
    Start-TestGroup 'runner: early recovery reaches runtime, history, outbox and summary'
    $output = & $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'runner.ps1') -KeeperRoot $ws -ConfigFile $configFile -NoSync 2>&1
    Assert-Equal 0 $LASTEXITCODE "runner exits successfully ($output)"
    $runtime = @(Get-ChildItem -LiteralPath (Get-LogsDir $ws) -Filter '*.jsonl' | ForEach-Object {
        Get-Content -LiteralPath $_.FullName | ForEach-Object { ConvertFrom-JsonSafe $_ }
    } | Where-Object { $_.event -eq 'QUOTA_RECOVERED_EARLY' })
    $history = @(Get-ChildItem -LiteralPath (Get-HistoryDir $ws) -Filter 'events-*.jsonl' | ForEach-Object {
        Get-Content -LiteralPath $_.FullName | ForEach-Object { ConvertFrom-JsonSafe $_ }
    } | Where-Object { $_.event -eq 'QUOTA_RECOVERED_EARLY' })
    $outbox = @(Get-ChildItem -LiteralPath (Join-Path $ws 'runtime\outbox') -Recurse -Filter '*.json' | ForEach-Object {
        Read-JsonFile $_.FullName
    } | Where-Object { $_.event -eq 'QUOTA_RECOVERED_EARLY' })
    foreach ($surface in @(@{name='runtime'; records=$runtime}, @{name='history'; records=$history}, @{name='outbox'; records=$outbox})) {
        Assert-Equal 1 @($surface.records).Count "$($surface.name) contains exactly one recovery"
        if (@($surface.records).Count -eq 1) {
            $change = $surface.records[0].quotaChange
            Assert-Equal 90 $change.previousUsedPercent "$($surface.name) preserves previous usage"
            Assert-Equal 2 $change.usedPercent "$($surface.name) preserves current usage"
            Assert-Equal 'unknown' $change.reason "$($surface.name) does not claim a manual redemption"
        }
    }
    if ($history.Count -eq 1 -and $outbox.Count -eq 1) { Assert-Equal $history[0].eventId $outbox[0].eventId 'durable audit IDs agree' }
    $summaryFile = Get-ChildItem -LiteralPath (Get-HistoryDir $ws) -Filter 'summary-*.json' | Select-Object -First 1
    Assert-Equal 1 (Read-JsonFile $summaryFile.FullName).counts.QUOTA_RECOVERED_EARLY 'daily summary counts recovery'

    $output = & $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'runner.ps1') -KeeperRoot $ws -ConfigFile $configFile -NoSync 2>&1
    Assert-Equal 0 $LASTEXITCODE "unchanged second runner succeeds ($output)"
    $historyAgain = @(Get-ChildItem -LiteralPath (Get-HistoryDir $ws) -Filter 'events-*.jsonl' | ForEach-Object {
        Get-Content -LiteralPath $_.FullName | ForEach-Object { ConvertFrom-JsonSafe $_ }
    } | Where-Object { $_.event -eq 'QUOTA_RECOVERED_EARLY' })
    Assert-Equal 1 $historyAgain.Count 'next identical poll does not duplicate recovery'

    Start-TestGroup 'quota-change audit: nested fields use an allowlist and text redaction'
    $unsafe = @{ windowType = 'secondary'; previousUsedPercent = 90; usedPercent = 10; reason = 'token=fixture-secret'; prompt = 'must be removed'; resetsAt = @{ secret = 'must be removed' } }
    $clean = Sanitize-Record @{ event = 'QUOTA_RECOVERED_EARLY'; quotaChange = $unsafe }
    Assert-False $clean.quotaChange.ContainsKey('prompt') 'arbitrary nested keys removed'
    Assert-False $clean.quotaChange.ContainsKey('resetsAt') 'nested object cannot enter numeric field'
    Assert-False ($clean.quotaChange.reason -match 'fixture-secret') 'allowed text is redacted'
} finally {
    $env:CQK_MOCK_MODE = $savedMode
    Remove-TestWorkspace $ws
}
$result = Get-TestResult
Write-Host "recovery-logging: $($result.checks) checks, $($result.failures) failures"
if ($result.failures -gt 0) { exit 1 }
exit 0
