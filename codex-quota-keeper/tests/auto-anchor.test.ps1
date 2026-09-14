# End-to-end tests for the AutoAnchor module through runner.ps1 and the mock CLI.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'state-machine.ps1')
. (Join-Path $scriptDir 'auto-anchor.ps1')

$pwsh = (Get-Process -Id $PID).Path
$runnerPath = Join-Path $scriptDir 'runner.ps1'
$mockPath = Join-Path $testsDir 'fixtures\mock-appserver.ps1'

function New-AutoAnchorConfig {
    param($Expiry = @(), $Schedule = @(), [int]$MaxPerDay = 6, [bool]$Enabled = $true)
    return New-TestConfig @{
        mode = $(if ($Enabled) { 'AutoAnchor' } else { 'MonitorOnly' })
        codex = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = @{
            enabled = $Enabled; prompt = 'Reply exactly OK.'; maxPerDay = $MaxPerDay; minimumGapMinutes = 1
            anchorOnExpiry = @($Expiry); schedule = @($Schedule); anchorOnApply = $false
        } }
        github = @{ coordination = @{ enabled = $false; repoPath = ''; branch = 'cqk/coordination' }; historySync = @{ enabled = $false; push = $false; branch = 'cqk/history'; eventsOnly = $true } }
    }
}

function Invoke-RunnerSub {
    param([string]$KeeperRoot, [string]$ConfigFile, [switch]$ForceAnchor)
    $runnerArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath, '-KeeperRoot', $KeeperRoot, '-ConfigFile', $ConfigFile, '-NoSync')
    if ($ForceAnchor) { $runnerArgs += @('-ForceAnchor', '-WaitLockSeconds', '2') }
    $output = & $pwsh @runnerArgs 2>&1
    return @{ exitCode = $LASTEXITCODE; output = ($output | Out-String) }
}

function Get-Records {
    param([string]$Root, [string]$RelativePath, [string]$Filter)
    $records = @()
    Get-ChildItem -LiteralPath (Join-Path $Root $RelativePath) -Filter $Filter -File -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($line in [System.IO.File]::ReadAllLines($_.FullName)) {
            $record = ConvertFrom-JsonSafe $line
            if ($record) { $records += $record }
        }
    }
    return ,$records
}

function Get-ExecCount {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @([System.IO.File]::ReadAllLines($Path) | Where-Object { $_ }).Count
}

Start-TestGroup 'anchor: prompt whitelist'

Assert-True (Test-AnchorPromptAllowed 'Reply exactly OK.') 'default prompt allowed'
Assert-True (Test-AnchorPromptAllowed '回复 恰好 OK') 'unicode prompt allowed'
Assert-False (Test-AnchorPromptAllowed 'a"b') 'quotes rejected by the current cmd-safe launcher'
Assert-False (Test-AnchorPromptAllowed "line1`nline2") 'newline rejected'

$ws = New-TestWorkspace
try {
    $env:CQK_MOCK_EXEC = 'ok'

    Start-TestGroup 'anchor: default-off runner never calls a model'

    $offRoot = Join-Path $ws 'off'
    New-Item -ItemType Directory -Path $offRoot -Force | Out-Null
    $offCfg = Join-Path $offRoot 'config.json'
    Write-TestConfigFile $offCfg (New-AutoAnchorConfig -Enabled $false) | Out-Null
    $env:CQK_MOCK_MODE = 'expiry-primary'
    $off = Invoke-RunnerSub -KeeperRoot $offRoot -ConfigFile $offCfg
    Assert-Equal 0 $off.exitCode "MonitorOnly runner succeeds ($($off.output))"
    Assert-Equal 0 (Load-KeeperState $offRoot).anchors.attemptCount 'no anchor attempt while disabled'

    Start-TestGroup 'anchorOnExpiry: one expired window -> one exec, verify, and durable dedup'

    $root = Join-Path $ws 'expiry'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $cfgPath = Join-Path $root 'config.json'
    Write-TestConfigFile $cfgPath (New-AutoAnchorConfig -Expiry @('primary')) | Out-Null
    $execFile = Join-Path $root 'exec.txt'
    $env:CQK_MOCK_EXEC_ARGS_FILE = $execFile
    $env:CQK_MOCK_MODE = 'expiry-primary'
    $first = Invoke-RunnerSub -KeeperRoot $root -ConfigFile $cfgPath
    Assert-Equal 0 $first.exitCode "expiry runner succeeds ($($first.output))"
    $state = Load-KeeperState $root
    $expiryId = Get-ExpiryAnchorEventId 'codex-default' 'primary' 1000000000
    Assert-Equal 1 $state.anchors.attemptCount 'one attempt reserved'
    Assert-Equal 1 $state.anchors.successCount 'successful verification counted'
    Assert-Contains $state.processedEventIds $expiryId 'expiry event processed'
    Assert-Equal 1 (Get-ExecCount $execFile) 'one physical model call'
    $logs = Get-Records $root 'runtime\logs' 'keeper-*.jsonl'
    Assert-Equal 1 @($logs | Where-Object { $_.event -eq 'ANCHOR_EXECUTED' }).Count 'one runtime invocation audit'
    $history = Get-Records $root 'history' 'events-*.jsonl'
    Assert-Equal 1 @($history | Where-Object { $_.event -eq 'ANCHOR_EXECUTED' }).Count 'one local history invocation audit'

    $second = Invoke-RunnerSub -KeeperRoot $root -ConfigFile $cfgPath
    Assert-Equal 0 $second.exitCode 'repeat poll succeeds'
    Assert-Equal 1 (Get-ExecCount $execFile) 'same expiry never executes twice'
    Assert-Equal 1 (Load-KeeperState $root).anchors.attemptCount 'dedup keeps the daily count stable'

    Start-TestGroup 'anchor: failed exec is charged once and never retried'

    $failRoot = Join-Path $ws 'fail'
    New-Item -ItemType Directory -Path $failRoot -Force | Out-Null
    $failCfg = Join-Path $failRoot 'config.json'
    Write-TestConfigFile $failCfg (New-AutoAnchorConfig -Expiry @('secondary')) | Out-Null
    $env:CQK_MOCK_MODE = 'expiry-secondary'
    $env:CQK_MOCK_EXEC = 'fail'
    $failedRun = Invoke-RunnerSub -KeeperRoot $failRoot -ConfigFile $failCfg
    Assert-Equal 0 $failedRun.exitCode 'business abort does not crash runner'
    $failedState = Load-KeeperState $failRoot
    Assert-Equal 1 $failedState.anchors.attemptCount 'failed launched exec consumes allowance'
    Assert-Equal 1 $failedState.anchors.failedCount 'failure counted'
    Assert-Equal 1 @((Get-Records $failRoot 'runtime\logs' 'keeper-*.jsonl') | Where-Object { $_.event -eq 'ANCHOR_ABORTED' }).Count 'abort audited once'
    $env:CQK_MOCK_EXEC = 'ok'

    Start-TestGroup 'anchorOnApply: explicit force works with all automatic triggers off'

    $forceRoot = Join-Path $ws 'force'
    New-Item -ItemType Directory -Path $forceRoot -Force | Out-Null
    $forceCfg = Join-Path $forceRoot 'config.json'
    Write-TestConfigFile $forceCfg (New-AutoAnchorConfig) | Out-Null
    $env:CQK_MOCK_MODE = 'expiry-active'
    $forced = Invoke-RunnerSub -KeeperRoot $forceRoot -ConfigFile $forceCfg -ForceAnchor
    Assert-Equal 0 $forced.exitCode "forced runner succeeds ($($forced.output))"
    Assert-Equal 1 (Load-KeeperState $forceRoot).anchors.attemptCount 'forced attempt counted'

    Start-TestGroup 'schedule: due slot calls once only when primary is not running'

    $scheduleRoot = Join-Path $ws 'schedule'
    New-Item -ItemType Directory -Path $scheduleRoot -Force | Out-Null
    $scheduleCfg = Join-Path $scheduleRoot 'config.json'
    $slot = (Get-Date).AddMinutes(-1).ToString('HH:mm')
    Write-TestConfigFile $scheduleCfg (New-AutoAnchorConfig -Schedule @($slot)) | Out-Null
    $env:CQK_MOCK_MODE = 'expiry-primary'
    Assert-Equal 0 (Invoke-RunnerSub -KeeperRoot $scheduleRoot -ConfigFile $scheduleCfg).exitCode 'scheduled runner succeeds'
    Assert-Equal 1 (Load-KeeperState $scheduleRoot).anchors.attemptCount 'due schedule executes once'
    Assert-Equal 0 (Invoke-RunnerSub -KeeperRoot $scheduleRoot -ConfigFile $scheduleCfg).exitCode 'same slot repeat succeeds'
    Assert-Equal 1 (Load-KeeperState $scheduleRoot).anchors.attemptCount 'same schedule slot deduplicated'

    Start-TestGroup 'merged expiry: two buckets claim twice but execute and audit once'

    $mergeRoot = Join-Path $ws 'merge'
    New-Item -ItemType Directory -Path $mergeRoot -Force | Out-Null
    $mergeCfg = Join-Path $mergeRoot 'config.json'
    Write-TestConfigFile $mergeCfg (New-AutoAnchorConfig -Expiry @('primary')) | Out-Null
    $mergeExec = Join-Path $mergeRoot 'exec.txt'
    $env:CQK_MOCK_EXEC_ARGS_FILE = $mergeExec
    $env:CQK_MOCK_MODE = 'multi-expired'
    Assert-Equal 0 (Invoke-RunnerSub -KeeperRoot $mergeRoot -ConfigFile $mergeCfg).exitCode 'merged expiry runner succeeds'
    Assert-Equal 1 (Get-ExecCount $mergeExec) 'two triggers share one physical exec'
    $mergeClaims = @(Get-ChildItem -LiteralPath (Get-AnchorClaimsDir $mergeRoot) -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-Equal 2 $mergeClaims.Count 'one durable claim per expiry trigger'
    $mergeAudits = @((Get-Records $mergeRoot 'runtime\logs' 'keeper-*.jsonl') | Where-Object { $_.event -eq 'ANCHOR_EXECUTED' })
    Assert-Equal 1 $mergeAudits.Count 'one invocation audit for the physical exec'
    Assert-Equal 2 @($mergeAudits[0].anchor.triggerEventIds).Count 'audit keeps the full trigger set'

    Start-TestGroup 'daily cap blocks a later explicit force'

    $capRoot = Join-Path $ws 'cap'
    New-Item -ItemType Directory -Path $capRoot -Force | Out-Null
    $capCfg = Join-Path $capRoot 'config.json'
    Write-TestConfigFile $capCfg (New-AutoAnchorConfig -Expiry @('primary') -MaxPerDay 1) | Out-Null
    $capExec = Join-Path $capRoot 'exec.txt'
    $env:CQK_MOCK_EXEC_ARGS_FILE = $capExec
    $env:CQK_MOCK_MODE = 'expiry-primary'
    $null = Invoke-RunnerSub -KeeperRoot $capRoot -ConfigFile $capCfg
    $env:CQK_MOCK_MODE = 'expiry-active'
    $null = Invoke-RunnerSub -KeeperRoot $capRoot -ConfigFile $capCfg -ForceAnchor
    Assert-Equal 1 (Get-ExecCount $capExec) 'daily cap blocks the forced second call'
} finally {
    foreach ($name in @('CQK_MOCK_MODE', 'CQK_MOCK_EXEC', 'CQK_MOCK_EXEC_ARGS_FILE')) {
        Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
    }
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "auto-anchor.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
