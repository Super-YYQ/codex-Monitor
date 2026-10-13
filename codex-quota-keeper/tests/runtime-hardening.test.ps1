# Runtime-log regressions through the real runner and a local mock CLI.
# No model/network/Git calls or Task Scheduler writes.
$ErrorActionPreference = 'Stop'
$testsDir = Split-Path -Parent $PSCommandPath
. (Join-Path $testsDir 'test-helper.ps1')
$scripts = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scripts 'state-machine.ps1')
. (Join-Path $scripts 'status-assessment.ps1')
$hostExe = (Get-Process -Id $PID).Path
$ws = New-TestWorkspace
$saved = @{}
foreach ($key in @('CQK_MOCK_MODE','CQK_MOCK_POST_EXEC_MODE','CQK_MOCK_EXEC','CQK_MOCK_EXEC_ARGS_FILE')) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
function Invoke-HardeningRunner {
    param($Root, $Config, [switch]$Force, [switch]$Retry)
    Ensure-Directory $Root | Out-Null
    $file = Write-TestConfigFile (Join-Path $Root 'config.json') $Config
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $scripts 'runner.ps1'),'-KeeperRoot',$Root,'-ConfigFile',$file,'-NoSync','-NoTaskChanges')
    if ($Force) { $args += '-ForceAnchor' }
    if ($Retry) { $args += '-ReadOnlyRetry' }
    $output = & $hostExe @args 2>&1
    Assert-Equal 0 $LASTEXITCODE "runner completes ($output)"
    return @(Get-ChildItem -LiteralPath (Join-Path $Root 'runtime/logs') -Filter '*.jsonl' | ForEach-Object {
        Get-Content -LiteralPath $_.FullName | ForEach-Object { ConvertFrom-JsonSafe $_ }
    })
}
try {
    $cfg = New-TestConfig @{
        mode = 'AutoAnchor'
        github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } }
        codex = @{ command = (Join-Path $testsDir 'fixtures/mock-appserver.ps1'); queryTimeoutSeconds = 5; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 300; model = 'mock-model-alpha'; schedule = @(); anchorOnExpiry = @() } }
    }
    foreach ($case in @(@{mode='rate-limit';reason='429';kind='RATE_LIMITED'}, @{mode='auth-error';reason='auth error';kind='AUTH_ERROR'}, @{mode='network-error';reason='network';kind='NETWORK_ERROR'})) {
        Start-TestGroup "post-exec verification: $($case.kind) reaches state, backoff and one failure record"
        $root = Join-Path $ws $case.mode
        $env:CQK_MOCK_MODE = 'normal'; $env:CQK_MOCK_EXEC = 'ok'
        $env:CQK_MOCK_POST_EXEC_MODE = $case.mode
        $env:CQK_MOCK_EXEC_ARGS_FILE = Join-Path $ws ($case.mode + '-exec.txt')
        $summaryPath = Join-Path $root ('history/summary-' + (Get-Date).ToString('yyyy-MM-dd') + '.json')
        Write-JsonFileAtomic $summaryPath @{ counts = @{}; windows = @(@{ resetsAt = 1 }) }
        $logs = Invoke-HardeningRunner $root $cfg -Force
        $state = Load-KeeperState $root
        Assert-True $state.stale 'failed verification marks snapshot stale'
        Assert-Equal 1 $state.consecutiveReadFailures 'one failed read is counted'
        Assert-Equal $case.reason (Read-JsonFile (Join-Path $root 'runtime/backoff.json')).reason 'typed failure chooses backoff'
        Assert-Equal 1 @($logs | Where-Object {$_.event -eq 'READ_FAILED'}).Count 'failed read logged once'
        Assert-Equal 0 @($logs | Where-Object {$_.event -eq 'RUNNER_OK'}).Count 'failed read does not emit success'
        Assert-Equal 1 @($logs | Where-Object {$_.event -eq 'RUNNER_READ_FAILED'}).Count 'terminal read outcome is explicit'
        $abort = @($logs | Where-Object {$_.event -eq 'ANCHOR_ABORTED'})[0]
        Assert-Equal $case.kind $abort.errorKind 'anchor abort preserves verification error type'
        Assert-Equal 1 $state.anchors.attemptCount 'verification failure never retries the model call'
        Assert-False (Test-Path (Join-Path $root 'runtime/outbox')) 'disabled history does not accumulate new outbox files'
        Assert-Equal 1 @($logs | Where-Object {$_.event -eq 'READ_FAILED' -and $_.attempts[0].route -eq 'direct'}).Count 'read route is audited'
        $done = @($logs | Where-Object {$_.event -eq 'RUNNER_READ_FAILED'})[0]
        Assert-Equal $state.buckets[0].windows[0].resetsAt $done.windows[0].resetsAt 'failed verification preserves last successful snapshot in terminal log'
        Assert-Equal $done.windows[0].resetsAt (Read-JsonFile $summaryPath).windows[0].resetsAt 'failed verification replaces older summary with latest successful snapshot'
        Assert-True (Read-JsonFile $summaryPath).stale 'failed verification marks summary stale'
        Assert-Equal 'initial' $done.attempts[0].phase 'initial read diagnostics survive verification'
        Assert-Equal 'verification' $done.attempts[1].phase 'verification diagnostics have a distinct phase'
        Assert-True (@($logs | Where-Object {$_.event -eq 'QUOTA_SNAPSHOT_CHANGED'})[0].eventDetails.changes.Count -gt 0) 'snapshot change reasons reach the runtime log'
        Remove-Item -LiteralPath (Join-Path $root 'runtime/backoff.json')
        $env:CQK_MOCK_POST_EXEC_MODE = ''
        $null = Invoke-HardeningRunner $root $cfg
        Assert-False (Read-JsonFile $summaryPath).stale 'same snapshot successful read clears stale summary without a domain event'
        Assert-False (Load-KeeperState $root).stale 'same snapshot successful read clears stale state'
    }
    Start-TestGroup 'successful verification is the final snapshot and preserves before/after'
    $env:CQK_MOCK_MODE = 'normal'; $env:CQK_MOCK_POST_EXEC_MODE = 'reset'
    $env:CQK_MOCK_EXEC_ARGS_FILE = Join-Path $ws 'success-exec.txt'
    $root = Join-Path $ws 'success'
    $logs = Invoke-HardeningRunner $root $cfg -Force
    $state = Load-KeeperState $root
    $done = @($logs | Where-Object {$_.event -eq 'RUNNER_OK'})[0]
    $anchor = @($logs | Where-Object {$_.event -eq 'ANCHOR_EXECUTED'})[0]
    Assert-Equal 1900000000 $done.windows[0].resetsAt 'terminal snapshot uses verification boundary'
    $summaryFile = Get-ChildItem (Join-Path $root 'history') -Filter 'summary-*.json' | Select-Object -First 1
    Assert-Equal $done.windows[0].resetsAt (Read-JsonFile $summaryFile.FullName).windows[0].resetsAt 'daily summary matches terminal snapshot'
    Assert-Equal $done.windows[0].resetsAt $state.buckets[0].windows[0].resetsAt 'persisted state agrees'
    Assert-True ($anchor.anchor.beforeWindows[0].resetsAt -ne $anchor.anchor.afterWindows[0].resetsAt) 'audit preserves both sides of the transition'
    Assert-True ([string]$done.context.buildId -match '^[a-f0-9]{64}$') 'script build fingerprint is recorded'

    Start-TestGroup 'limit window type and existing disabled-sync queue are preserved'
    $env:CQK_MOCK_MODE = 'limit-reached'; $env:CQK_MOCK_POST_EXEC_MODE = ''
    $root = Join-Path $ws 'limited'
    $queued = Join-Path $root 'runtime/outbox/existing.jsonl'
    Write-JsonFileAtomic $queued @{ fixture = 'old queue' }
    $logs = Invoke-HardeningRunner $root $cfg
    Assert-Equal 'primary' @($logs | Where-Object {$_.event -eq 'LIMIT_REACHED'})[0].eventDetails.rateLimitReachedType 'limit event identifies the window'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath (Join-Path $root 'runtime/outbox') -File).Count 'disabled sync preserves old queue without creating new entries'
    Assert-Equal 'old queue' (Read-JsonFile $queued).fixture 'old queue content remains intact'

    Start-TestGroup 'read-only retry cannot execute even with explicit force'
    $env:CQK_MOCK_MODE = 'normal'
    $env:CQK_MOCK_POST_EXEC_MODE = ''; $env:CQK_MOCK_EXEC_ARGS_FILE = Join-Path $ws 'retry-exec.txt'
    $null = Invoke-HardeningRunner (Join-Path $ws 'retry') $cfg -Force -Retry
    Assert-False (Test-Path $env:CQK_MOCK_EXEC_ARGS_FILE) 'retry does not call model'

    Start-TestGroup 'legacy failed run is not cleared by its own terminal OK'
    $now = Get-Date
    foreach ($gap in @(0,1)) {
        $tail = @(@{event='RUNNER_OK';level='INFO';ts=$now.ToString('o');runId='failed'}, @{event='READ_FAILED';level='ERROR';ts=$now.AddSeconds(-$gap).ToString('o');runId='failed'})
        Assert-False (Get-StatusVerdictFreshness -Tail $tail -Now $now).fresh 'same failed run cannot recover across a second boundary'
    }
    $tail[0].runId = 'recovered'
    Assert-True (Get-StatusVerdictFreshness -Tail $tail -Now $now).fresh 'later successful run clears old error'
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    Remove-TestWorkspace $ws
}
$result = Get-TestResult
Write-Host "runtime-hardening: $($result.checks) checks, $($result.failures) failures"
if ($result.failures) { exit 1 }
exit 0
