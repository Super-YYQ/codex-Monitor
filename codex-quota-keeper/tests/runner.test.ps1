# End-to-end runner tests: mock app-server + local bare origin as the log repo.
# Each run executes scripts/runner.ps1 in a fresh subprocess (it calls exit).

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'github-sync.ps1')
. (Join-Path $scriptDir 'global-backoff.ps1')

$pwsh = (Get-Process -Id $PID).Path
$runnerPath = Join-Path $scriptDir 'runner.ps1'

function Invoke-Runner {
    param([string]$KeeperRoot, [string]$ConfigFile, [switch]$NoSync)
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath, '-KeeperRoot', $KeeperRoot, '-ConfigFile', $ConfigFile)
    if ($NoSync) { $args += '-NoSync' }
    $out = & $pwsh @args 2>&1
    return @{ exitCode = $LASTEXITCODE; output = ($out | Out-String) }
}

function Get-RunnerLogLines {
    param([string]$KeeperRoot)
    $logDir = Join-Path $KeeperRoot 'runtime\logs'
    $lines = @()
    Get-ChildItem -LiteralPath $logDir -Filter 'keeper-*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $lines += [System.IO.File]::ReadAllLines($_.FullName)
    }
    return $lines
}

function Clear-GlobalBackoff {
    # The 429/auth paths now push a cluster-level backoff; tests clear it by
    # pushing an already-expired record.
    param([string]$ClonePath)
    $blob = Get-RemoteBranchBlob -RepoPath $ClonePath -Branch 'cqk/coordination' -PathInRepo 'coordination/backoff.json'
    if ($blob.ok -and $blob.reason -eq 'ok') {
        $past = @{ schema = 1; until = '2000-01-01T00:00:00+00:00'; reason = 'cleared'; sourceOwnerId = 'test'; setAt = '2000-01-01T00:00:00+00:00' }
        $null = Push-RepoBlobs -RepoPath $ClonePath -Branch 'cqk/coordination' `
            -Blobs @{ 'coordination/backoff.json' = (ConvertTo-Json -InputObject $past -Depth 6) } `
            -ParentCommit $blob.commit -CommitMessage 'test: clear global backoff' -MachineId 'test'
    }
}

function Get-LogEventNames {
    param([string]$KeeperRoot)
    return @((Get-RunnerLogLines $KeeperRoot) | ForEach-Object { (ConvertFrom-JsonSafe $_).event })
}

$ws = New-TestWorkspace
try {
    $repos = New-TestOriginAndClone -Workspace $ws
    $keeperRoot = Join-Path $ws 'keeper'
    New-Item -ItemType Directory -Path $keeperRoot -Force | Out-Null
    $cfgFile = Join-Path $keeperRoot 'config.json'
    $mockPath = Join-Path $testsDir 'fixtures\mock-appserver.ps1'

    $cfg = New-TestConfig @{
        github = @{ coordination = @{ enabled = $true; repoPath = $repos.clone; branch = 'cqk/coordination' }; historySync = @{ enabled = $true; push = $true; branch = 'cqk/history'; eventsOnly = $true } }
        codex  = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = $false }
    }
    $null = Write-TestConfigFile $cfgFile $cfg

    Start-TestGroup 'runner: first MonitorOnly run acquires lease, snapshots baseline'

    $env:CQK_MOCK_MODE = 'normal'
    $r1 = Invoke-Runner -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 0 $r1.exitCode "first run exits 0 ($($r1.output))"
    $state = Read-JsonFile (Join-Path $keeperRoot 'runtime\state.json')
    Assert-NotNull $state 'state persisted'
    Assert-Equal 'LEADER' $state.role 'role leader'
    Assert-Equal 1 @($state.buckets).Count 'one bucket captured'
    Assert-Equal 'codex-default' $state.buckets[0].bucketId 'bucketId stored'
    Assert-Equal 2 @($state.buckets[0].windows).Count 'two windows captured'
    $pri = @($state.buckets[0].windows | Where-Object { $_.windowType -eq 'primary' })[0]
    Assert-Equal 300 $pri.windowDurationMins 'primary minutes stored'
    Assert-False ([bool]$state.stale) 'not stale'

    $evts = Get-LogEventNames $keeperRoot
    Assert-Contains $evts 'RUNNER_OK' 'runner ok logged'

    Start-TestGroup 'runner: unchanged poll writes no new events'

    $beforeCount = @(Get-RunnerLogLines $keeperRoot).Count
    $r2 = Invoke-Runner -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 0 $r2.exitCode 'second run exits 0'
    $evts2 = Get-LogEventNames $keeperRoot
    $newEvents = @($evts2 | Select-Object -Skip $beforeCount)
    Assert-False ($newEvents -contains 'QUOTA_SNAPSHOT_CHANGED') 'no snapshot event on identical poll'
    Assert-Contains $newEvents 'RUNNER_OK' 'runner ok still logged'

    Start-TestGroup 'runner: window reset detected, history synced to remote'

    $env:CQK_MOCK_MODE = 'reset'
    $r3 = Invoke-Runner -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 0 $r3.exitCode "reset run exits 0 ($($r3.output))"
    $evts3 = Get-LogEventNames $keeperRoot
    Assert-Contains $evts3 'WINDOW_RESET_OBSERVED' 'reset observed'

    $state3 = Read-JsonFile (Join-Path $keeperRoot 'runtime\state.json')
    $expectedId = Get-Sha256Hex 'codex-default|primary|300|1788062400|reset'
    Assert-Contains $state3.processedEventIds $expectedId 'reset eventId marked processed'

    $histFile = Join-Path $keeperRoot 'history\events-2026-08-30.jsonl'
    Assert-True (Test-Path $histFile) 'history event file written'
    Assert-True ("$([System.IO.File]::ReadAllText($histFile))" -match 'WINDOW_RESET_OBSERVED') 'reset in history'

    $remote = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/history' -PathInRepo 'history/events-2026-08-30.jsonl'
    Assert-True $remote.ok 'remote history readable'
    Assert-True ("$($remote.content)" -match 'WINDOW_RESET_OBSERVED') 'reset synced to remote history branch'
    $env:CQK_MOCK_MODE = 'normal'

    Start-TestGroup 'runner: passive machine does not query Codex'

    $keeperRoot2 = Join-Path $ws 'keeper2'
    New-Item -ItemType Directory -Path $keeperRoot2 -Force | Out-Null
    $cfgFile2 = Join-Path $keeperRoot2 'config.json'
    $null = Write-TestConfigFile $cfgFile2 $cfg
    # Seed machine identity so machine2 is NOT the current lease owner.
    Write-JsonFileAtomic (Join-Path $keeperRoot2 'runtime\machine.json') @{
        machineId = 'PASSIVE-MACHINE-0002'; label = 'PC-2'; createdAt = '2026-08-30T00:00:00+08:00'
    }
    $r4 = Invoke-Runner -KeeperRoot $keeperRoot2 -ConfigFile $cfgFile2
    Assert-Equal 0 $r4.exitCode 'passive run exits 0'
    $state4 = Read-JsonFile (Join-Path $keeperRoot2 'runtime\state.json')
    Assert-Equal 'PASSIVE' $state4.role 'role passive'
    Assert-Null $state4.lastReadAt 'no quota read performed'
    Assert-Equal 0 @($state4.buckets).Count 'no buckets stored on passive'

    Start-TestGroup 'runner: 429 error sets backoff, next run skipped'

    $env:CQK_MOCK_MODE = 'rate-limit'
    $r5 = Invoke-Runner -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 0 $r5.exitCode '429 run still exits 0'
    $backoff = Read-JsonFile (Join-Path $keeperRoot 'runtime\backoff.json')
    Assert-NotNull $backoff 'backoff recorded'
    Assert-Equal '429' $backoff.reason '429 reason'
    $evts5 = Get-LogEventNames $keeperRoot
    Assert-Contains $evts5 'READ_FAILED' 'read failure logged'

    $stateBefore = Read-JsonFile (Join-Path $keeperRoot 'runtime\state.json')
    $env:CQK_MOCK_MODE = 'normal'
    Clear-Backoff $keeperRoot   # local backoff cleared; cluster backoff must still block
    $r6 = Invoke-Runner -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 0 $r6.exitCode 'backoff run exits 0'
    $evts6 = Get-LogEventNames $keeperRoot
    Assert-Contains $evts6 'GLOBAL_BACKOFF_SKIP' 'global backoff skip logged (cluster-level)'
    $stateAfter = Read-JsonFile (Join-Path $keeperRoot 'runtime\state.json')
    Assert-Equal "$($stateBefore.lastReadAt)" "$($stateAfter.lastReadAt)" 'no new quota read during backoff'
    Clear-GlobalBackoff -ClonePath $repos.clone

    Start-TestGroup 'runner: auth error backs off 120 minutes'

    $env:CQK_MOCK_MODE = 'auth-error'
    $r7 = Invoke-Runner -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 0 $r7.exitCode 'auth run exits 0'
    $backoff7 = Read-JsonFile (Join-Path $keeperRoot 'runtime\backoff.json')
    Assert-NotNull $backoff7 'auth backoff recorded'
    Assert-Equal 'auth error' $backoff7.reason 'auth reason'
    Clear-Backoff $keeperRoot
    Clear-GlobalBackoff -ClonePath $repos.clone
    $env:CQK_MOCK_MODE = 'normal'

    Start-TestGroup 'runner: read failure keeps previous windows marked stale'

    $env:CQK_MOCK_MODE = 'start-failure'
    $r8 = Invoke-Runner -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 0 $r8.exitCode 'read-failure run exits 0'
    $state8 = Read-JsonFile (Join-Path $keeperRoot 'runtime\state.json')
    Assert-True ([bool]$state8.stale) 'stale flag set'
    Assert-Equal 2 @($state8.buckets[0].windows).Count 'previous buckets preserved'
    Assert-NotNull $state8.lastError 'error recorded'
    $env:CQK_MOCK_MODE = 'normal'

    Start-TestGroup 'runner: invalid config exits 1 with error log'

    $badCfg = Join-Path $ws 'bad.json'
    [System.IO.File]::WriteAllText($badCfg, '{ not json', (New-Object System.Text.UTF8Encoding($false)))
    $r9 = Invoke-Runner -KeeperRoot $keeperRoot -ConfigFile $badCfg
    Assert-Equal 1 $r9.exitCode 'invalid config exits 1'
    $evts9 = Get-LogEventNames $keeperRoot
    Assert-Contains $evts9 'CONFIG_INVALID' 'config error logged'

    Start-TestGroup 'runner: local lock prevents concurrent run'

    Enter-RunnerLock $keeperRoot | Out-Null
    try {
        $r10 = Invoke-Runner -KeeperRoot $keeperRoot -ConfigFile $cfgFile
        Assert-Equal 0 $r10.exitCode 'locked run exits 0 (skip, not fail)'
        $evts10 = Get-LogEventNames $keeperRoot
        Assert-Contains $evts10 'RUNNER_SKIPPED' 'skip logged'
    } finally {
        Exit-RunnerLock $keeperRoot
    }

    Start-TestGroup 'runner: github disabled -> local-only leader, no remote touched'

    $keeperRoot3 = Join-Path $ws 'keeper3'
    New-Item -ItemType Directory -Path $keeperRoot3 -Force | Out-Null
    $cfgFile3 = Join-Path $keeperRoot3 'config.json'
    $cfgLocal = New-TestConfig @{
        github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } }
        codex  = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = $false }
    }
    $null = Write-TestConfigFile $cfgFile3 $cfgLocal
    $remoteBefore = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/coordination' -PathInRepo 'coordination/lease.json'
    $r11 = Invoke-Runner -KeeperRoot $keeperRoot3 -ConfigFile $cfgFile3
    Assert-Equal 0 $r11.exitCode 'local-only run exits 0'
    $state11 = Read-JsonFile (Join-Path $keeperRoot3 'runtime\state.json')
    Assert-Equal 'LEADER' $state11.role 'local-only leader'
    $remoteAfter = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/coordination' -PathInRepo 'coordination/lease.json'
    Assert-Equal "$($remoteBefore.commit)" "$($remoteAfter.commit)" 'coordination branch untouched by local-only machine'

    Start-TestGroup 'runner: config semantics (audit plan section 6.2)'

    # includeMachineLabel=false (default): no label anywhere in local history
    $histText = ''
    Get-ChildItem -LiteralPath (Join-Path $keeperRoot 'history') -File -ErrorAction SilentlyContinue | ForEach-Object {
        $histText += [System.IO.File]::ReadAllText($_.FullName)
    }
    Assert-False ("$histText" -match 'machineLabel') 'machineLabel absent from local history (CQK-006)'

    # historySync.push=false: no history push may happen, coordination still works
    $freshOrigin = Join-Path $ws 'origin-push-false.git'
    $freshClone = Join-Path $ws 'repo-push-false'
    $null = Invoke-TestGit -RepoPath $null -ArgumentList @('init', '--bare', '-q', $freshOrigin)
    $null = Invoke-TestGit -RepoPath $null -ArgumentList @('clone', '-q', $freshOrigin, $freshClone)
    $keeperRoot4 = Join-Path $ws 'keeper-pushfalse'
    New-Item -ItemType Directory -Path $keeperRoot4 -Force | Out-Null
    $cfgFile4 = Join-Path $keeperRoot4 'config.json'
    $cfgPushFalse = New-TestConfig @{
        github = @{
            coordination = @{ enabled = $true; repoPath = $freshClone; branch = 'cqk/coordination' }
            historySync = @{ enabled = $true; push = $false; branch = 'cqk/history'; eventsOnly = $true }
        }
        codex = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = $false }
    }
    $null = Write-TestConfigFile $cfgFile4 $cfgPushFalse
    $env:CQK_MOCK_MODE = 'normal'
    $rp1 = Invoke-Runner -KeeperRoot $keeperRoot4 -ConfigFile $cfgFile4
    Assert-Equal 0 $rp1.exitCode 'push=false baseline run ok'
    Clear-Backoff $keeperRoot4
    $env:CQK_MOCK_MODE = 'reset'
    $rp2 = Invoke-Runner -KeeperRoot $keeperRoot4 -ConfigFile $cfgFile4
    Assert-Equal 0 $rp2.exitCode 'push=false reset run ok'
    $coordBranch = Get-RemoteBranchBlob -RepoPath $freshClone -Branch 'cqk/coordination' -PathInRepo 'coordination/lease.json'
    Assert-True ($coordBranch.ok -and $coordBranch.reason -eq 'ok') 'coordination push still happens (independent of historySync.push)'
    $histBranch = Get-RemoteBranchBlob -RepoPath $freshClone -Branch 'cqk/history' -PathInRepo 'history/.x'
    Assert-False ($histBranch.ok -and $histBranch.reason -eq 'ok') 'no history push when historySync.push=false (CQK-005)'
    Assert-True (Test-Path (Join-Path $keeperRoot4 'history')) 'local history files still written for later retry'

    # retentionDays: runner cleans stale local files at completion (CQK-007)
    $old = (Get-Date).AddDays(-200)
    $oldLog = Join-Path (Get-LogsDir $keeperRoot) 'keeper-2026-01-01.jsonl'
    [System.IO.File]::WriteAllText($oldLog, '{}')
    (Get-Item $oldLog).LastWriteTime = $old
    $oldHist = Join-Path (Get-HistoryDir $keeperRoot) 'events-2026-01-01.jsonl'
    [System.IO.File]::WriteAllText($oldHist, '{}')
    (Get-Item $oldHist).LastWriteTime = $old
    $env:CQK_MOCK_MODE = 'normal'
    $rp3 = Invoke-Runner -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 0 $rp3.exitCode 'retention run ok'
    Assert-False (Test-Path $oldLog) 'stale runtime log removed by runner (CQK-007)'
    Assert-False (Test-Path $oldHist) 'stale history file removed by runner'
    $env:CQK_MOCK_MODE = 'normal'
} finally {
    Remove-Item Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "runner.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
