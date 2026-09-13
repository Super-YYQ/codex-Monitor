# Production-readiness regressions. All processes use a mock CLI, local-only;
# no Git remote, model request, or scheduled task registration is involved.
$testsDir = Split-Path -Parent $PSCommandPath
. (Join-Path $testsDir 'test-helper.ps1')
$scripts = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scripts 'auto-anchor.ps1')
$mock = Join-Path $testsDir 'fixtures/mock-appserver.ps1'
$hostExe = (Get-Process -Id $PID).Path
$ws = New-TestWorkspace
try {
    Start-TestGroup 'transport classifications are owned by the client'
    Assert-Equal 'NETWORK_ERROR' (Get-CodexAppServerErrorKind -Code '-32000' -Message 'failed to fetch codex rate limits: error sending request') 'network is not a usage limit'
    Assert-Equal 'RATE_LIMITED' (Get-CodexAppServerErrorKind -Code '429' -Message 'Too many requests') '429 is typed'
    Assert-Equal 'AUTH_ERROR' (Get-CodexAppServerErrorKind -Code '401' -Message 'Unauthorized') '401 is typed'

    Start-TestGroup 'outbox uses the same privacy boundary as local history'
    $poison = 'sk-' + 'synthetic-for-readiness-12345678'
    $record = @{ event = 'ANCHOR_ABORTED'; eventId = 'safe-event'; runId = 'run-test';
        machineLabel = 'private-label'; token = $poison; errorKind = 'TIMEOUT';
        anchor = @{ phase = 'ABORTED'; reason = $poison; effectiveModel = 'mock-model-alpha'; token = $poison } }
    $outbox = Write-OutboxEvent -Root $ws -Record $record -MachineId 'test-machine'
    $raw = [IO.File]::ReadAllText($outbox.path)
    Assert-False ($raw.Contains($poison)) 'outbox never writes nested or top-level secrets'
    Assert-False ($raw.Contains('private-label')) 'outbox respects machine label opt-out'
    $clean = Sanitize-Record $record
    Assert-Equal 'TIMEOUT' $clean.errorKind 'history preserves typed failure identity'
    Assert-Equal 'safe-event' $clean.eventId 'history preserves audit identity'

    Start-TestGroup 'legacy counts cannot invent successful executions'
    $root = Join-Path $ws 'legacy'
    Ensure-Directory $root | Out-Null
    $st = New-KeeperState
    $st.anchors = @{ day = (Get-Date).ToString('yyyy-MM-dd'); count = 3; lastAnchorAt = '2026-09-11T01:00:00Z' }
    Save-KeeperState $root $st
    $migrated = Load-KeeperState $root
    Assert-Equal 3 $migrated.anchors.attemptCount 'old count migrates to attempts'
    Assert-Equal 0 $migrated.anchors.successCount 'unknown success is never invented'
    Assert-Null $migrated.anchors.lastSuccessAt 'old last anchor is not a known success'

    Start-TestGroup 'a refused reset remains eligible on the next runner tick'
    $root = Join-Path $ws 'retry-reset'
    Ensure-Directory $root | Out-Null
    $cfg = New-TestConfig @{
        mode = 'AutoAnchor'
        codex = @{ command = $mock; queryTimeoutSeconds = 5; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 1; keepaliveIntervalMinutes = 0; model = 'invalid-model' } }
        github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } }
    }
    $configFile = Write-TestConfigFile (Join-Path $root 'config.json') $cfg
    $env:CQK_MOCK_EXEC_ARGS_FILE = Join-Path $ws 'exec.txt'
    $env:CQK_MOCK_EXEC = 'ok'
    $env:CQK_MOCK_MODE = 'multi-reset-baseline'
    & $hostExe -NoProfile -File (Join-Path $scripts 'runner.ps1') -KeeperRoot $root -ConfigFile $configFile
    Assert-Equal 0 $LASTEXITCODE 'baseline runner finishes'
    $env:CQK_MOCK_MODE = 'multi-reset'
    & $hostExe -NoProfile -File (Join-Path $scripts 'runner.ps1') -KeeperRoot $root -ConfigFile $configFile
    Assert-Equal 0 $LASTEXITCODE 'rejected-profile runner finishes'
    Assert-False (Test-Path $env:CQK_MOCK_EXEC_ARGS_FILE) 'invalid profile performs no exec'
    $claims = @(Get-ChildItem (Join-Path $root 'runtime/anchor-claims') -Filter '*.json' -ErrorAction SilentlyContinue)
    Assert-Equal 0 $claims.Count 'invalid profile consumes no claim'
    $afterReject = Load-KeeperState $root
    Assert-Equal 0 $afterReject.anchors.count 'invalid profile consumes no daily allowance'
    $cfg.codex.autoAnchor.model = 'mock-model-alpha'
    $cfg.codex.autoAnchor.reasoningEffort = 'low'
    $null = Write-TestConfigFile $configFile $cfg
    & $hostExe -NoProfile -File (Join-Path $scripts 'runner.ps1') -KeeperRoot $root -ConfigFile $configFile
    Assert-Equal 0 $LASTEXITCODE 'corrected-profile runner finishes'
    Assert-True (Test-Path $env:CQK_MOCK_EXEC_ARGS_FILE) 'same reset executes after profile correction'
    $after = Load-KeeperState $root
    Assert-Equal 1 $after.anchors.attemptCount 'one actual attempt'
    Assert-Equal 1 $after.anchors.successCount 'one verified success'
    Assert-Equal 0 $after.anchors.failedCount 'no failure'
    $records = @(Get-ChildItem (Join-Path $root 'history') -Filter '*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
        Get-Content $_.FullName | ForEach-Object { ConvertFrom-JsonSafe $_ }
    } | Where-Object { $_.event -eq 'ANCHOR_EXECUTED' })
    Assert-Equal 1 $records.Count 'one invocation audit'
    if ($records.Count) {
        Assert-Equal 'mock-model-alpha' $records[0].anchor.effectiveModel 'effective model audited'
        Assert-Equal 'VALID' $records[0].anchor.profileValidation 'validation audited'
        Assert-Equal 2 @($records[0].anchor.triggerEventIds).Count 'both reset triggers preserved'
    }

    Start-TestGroup 'all audit surfaces project the same anchor fields'
    . (Join-Path $scripts 'logger.ps1')
    $auditRoot = Join-Path $ws 'audit'
    Write-KeeperLog -Root $auditRoot -Event $record.event -Anchor $record.anchor
    $runtime = ConvertFrom-JsonSafe ([IO.File]::ReadAllText((Get-LogFilePath $auditRoot (Get-Date))).Trim())
    Assert-False ((ConvertTo-Json $runtime -Depth 12).Contains($poison)) 'runtime anchor is sanitized'
    Assert-Equal $clean.anchor.effectiveModel $runtime.anchor.effectiveModel 'runtime and history model match'
    Assert-Equal $clean.anchor.reason $runtime.anchor.reason 'runtime and history reason match'

    Start-TestGroup 'a confirmed launch failure is not an invocation'
    $savedExecCommand = ${function:Get-AnchorExecCommand}
    try {
        function Get-AnchorExecCommand { return @{ exe = (Join-Path $ws 'missing.exe'); args = @() } }
        $launchRoot = Join-Path $ws 'launch-failed'
        $launchState = New-KeeperState
        $launchState.stale = $false
        $launch = Invoke-AutoAnchorIfNeeded -Config $cfg -KeeperRoot $launchRoot -State $launchState -Events @() `
            -IsLeader $true -Machine @{ machineId = 'test-machine' } -Election @{ localOnly = $true } -CodexPath $mock -ForceAnchor $true
        Assert-Equal 0 $launchState.anchors.attemptCount 'confirmed no-start refunds reserved attempt'
        Assert-Equal 0 $launchState.anchors.failedCount 'no-start is not a failed model invocation'
        Assert-Equal 1 @($launch.events | Where-Object { $_.anchor.phase -eq 'EXEC_LAUNCH' }).Count 'launch error has its own phase'
        Assert-Equal 0 @($launch.events | Where-Object { $_.anchorInvocationId }).Count 'launch error has no invocation id'
    } finally { Set-Item Function:Get-AnchorExecCommand $savedExecCommand }

    Start-TestGroup 'known claims are terminal, not repeated pending work'
    $takeover = New-KeeperState
    $takeover.stale = $false
    $null = Invoke-AutoAnchorIfNeeded -Config $cfg -KeeperRoot $launchRoot -State $takeover -Events @() `
        -IsLeader $true -Machine @{ machineId = 'test-machine' } -Election @{ localOnly = $true } -CodexPath $mock -ForceAnchor $true
    Assert-Equal 1 @($takeover.processedEventIds).Count 'existing durable claim removes trigger from pending work'
    Assert-Equal 0 $takeover.anchors.attemptCount 'takeover does not count another invocation'

    Start-TestGroup 'failed invocation consumes one attempt and cannot repeat'
    $failedRoot = Join-Path $ws 'exec-failed'
    $failedState = New-KeeperState
    $failedState.stale = $false
    $env:CQK_MOCK_EXEC = 'fail'
    $failed = Invoke-AutoAnchorIfNeeded -Config $cfg -KeeperRoot $failedRoot -State $failedState -Events @() `
        -IsLeader $true -Machine @{ machineId = 'test-machine' } -Election @{ localOnly = $true } -CodexPath $mock -ForceAnchor $true
    Assert-Equal 1 $failedState.anchors.attemptCount 'failed exec consumes an attempt'
    Assert-Equal 1 $failedState.anchors.failedCount 'failed exec counted separately'
    Assert-Null $failedState.anchors.lastSuccessAt 'failure cannot invent a success time'
    $guard = Test-ShouldAnchor -Config $cfg -State $failedState -Events @() -IsLeader $true -Now (Get-Date).AddMinutes(5) -Force $true
    Assert-False $guard.should 'force cannot bypass the once-per-day allowance'
    $rolled = Get-AnchorStatistics $after.anchors ((Get-Date).AddDays(1).ToString('yyyy-MM-dd'))
    Assert-Equal 0 $rolled.attemptCount 'daily attempts reset on rollover'
    Assert-Equal $after.anchors.lastSuccessAt $rolled.lastSuccessAt 'rollover preserves known success time'
} finally {
    Remove-Item Env:\CQK_MOCK_MODE, Env:\CQK_MOCK_EXEC, Env:\CQK_MOCK_EXEC_ARGS_FILE -ErrorAction SilentlyContinue
    Remove-TestWorkspace $ws
}
$r = Get-TestResult
Write-Host "readiness: $($r.checks) checks, $($r.failures) failures"
exit ([int]($r.failures -gt 0))
