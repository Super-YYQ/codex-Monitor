# AutoAnchor tests (experimental feature): default-off guarantees, prompt whitelist,
# exec + verification flow, idempotency incl. the remote second-layer event lock,
# daily cap. All through the mock codex (exec + app-server); no real credentials.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'github-sync.ps1')
. (Join-Path $scriptDir 'quota-client.ps1')
. (Join-Path $scriptDir 'state-machine.ps1')
. (Join-Path $scriptDir 'auto-anchor.ps1')

$pwsh = (Get-Process -Id $PID).Path
$runnerPath = Join-Path $scriptDir 'runner.ps1'
$mockPath = Join-Path $testsDir 'fixtures\mock-appserver.ps1'
$now = Get-Date

function Reset-RemoteLease {
    # All test machines share one origin; expire the lease so the next machine
    # can take over (takeoverOnExpiry=true).
    param([string]$ClonePath)
    $blob = Get-RemoteBranchBlob -RepoPath $ClonePath -Branch 'cqk/coordination' -PathInRepo 'coordination/lease.json'
    $parent = $null
    if ($blob.commit) { $parent = $blob.commit }
    $stale = @{
        schema = 1; ownerId = 'GHOST-PC'; ownerLabel = 'ghost'
        acquiredAt = (Get-Date).AddMinutes(-120).ToString('yyyy-MM-ddTHH:mm:sszzz')
        renewedAt = (Get-Date).AddMinutes(-120).ToString('yyyy-MM-ddTHH:mm:sszzz')
        expiresAt = (Get-Date).AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:sszzz')
        mode = 'AutoAnchor'; version = '0.1.0'
    }
    $null = Push-RepoBlobs -RepoPath $ClonePath -Branch 'cqk/coordination' `
        -Blobs @{ 'coordination/lease.json' = (ConvertTo-Json -InputObject $stale -Depth 6) } `
        -ParentCommit $parent -CommitMessage 'lease: expire for test' -MachineId 'ghost'
}

function Clear-AnchorEvents {
    # The reset eventId is deterministic, so scenarios that must reach the exec
    # stage need the remote claim files removed first.
    param([string]$ClonePath)
    $listing = Invoke-TestGit -RepoPath $ClonePath -ArgumentList @('ls-tree', '-r', '--name-only', 'origin/cqk/coordination')
    if (-not $listing.ok) { return }
    $eventFiles = @(($listing.stdout -split "`n") | Where-Object { $_ -match '^coordination/events/' })
    if (@($eventFiles).Count -eq 0) { return }
    $blob = Get-RemoteBranchBlob -RepoPath $ClonePath -Branch 'cqk/coordination' -PathInRepo 'coordination/lease.json'
    $parent = $null
    if ($blob.commit) { $parent = $blob.commit }
    $null = Push-RepoBlobs -RepoPath $ClonePath -Branch 'cqk/coordination' -Blobs @{} `
        -RemovePaths $eventFiles -ParentCommit $parent -CommitMessage 'anchor: clear claims for test' -MachineId 'ghost'
}

function Invoke-RunnerSub {
    param([string]$KeeperRoot, [string]$ConfigFile)
    $out = & $pwsh -NoProfile -ExecutionPolicy Bypass -File $runnerPath -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile 2>&1
    return @{ exitCode = $LASTEXITCODE; output = ($out | Out-String) }
}

function Get-LogEventNames {
    param([string]$KeeperRoot)
    $names = @()
    Get-ChildItem -LiteralPath (Join-Path $KeeperRoot 'runtime\logs') -Filter 'keeper-*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $names += @(([System.IO.File]::ReadAllLines($_.FullName)) | ForEach-Object { (ConvertFrom-JsonSafe $_).event })
    }
    return $names
}

Start-TestGroup 'anchor: prompt whitelist'

Assert-True (Test-AnchorPromptAllowed -Prompt 'Reply exactly OK.') 'default prompt allowed'
Assert-False (Test-AnchorPromptAllowed -Prompt 'rm -rf /') 'shell metachars rejected'
Assert-False (Test-AnchorPromptAllowed -Prompt '') 'empty rejected'
Assert-False (Test-AnchorPromptAllowed -Prompt ('x' * 121)) 'overlong rejected'

$ws = New-TestWorkspace
try {
    $repos = New-TestOriginAndClone -Workspace $ws
    $keeperRoot = Join-Path $ws 'keeper'
    New-Item -ItemType Directory -Path $keeperRoot -Force | Out-Null
    $cfgFile = Join-Path $keeperRoot 'config.json'
    $cfg = New-TestConfig @{
        mode  = 'AutoAnchor'
        codex = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 1 } }
        github = @{ coordination = @{ enabled = $true; repoPath = $repos.clone; branch = 'cqk/coordination' }; historySync = @{ enabled = $true; push = $true; branch = 'cqk/history'; eventsOnly = $true } }
    }
    $null = Write-TestConfigFile $cfgFile $cfg
    $null = Initialize-LogRepo -RepoPath $repos.clone -KeeperRoot $keeperRoot

    Start-TestGroup 'anchor: runner with autoAnchor OFF never anchors (default)'

    $cfgOff = New-TestConfig @{
        mode  = 'MonitorOnly'
        codex = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = $false }
        github = @{ coordination = @{ enabled = $true; repoPath = $repos.clone; branch = 'cqk/coordination' }; historySync = @{ enabled = $true; push = $true; branch = 'cqk/history'; eventsOnly = $true } }
    }
    $null = Write-TestConfigFile (Join-Path $ws 'cfg-off.json') $cfgOff
    $env:CQK_MOCK_MODE = 'reset'
    $env:CQK_MOCK_EXEC = 'ok'
    $r0 = Invoke-RunnerSub -KeeperRoot $keeperRoot -ConfigFile (Join-Path $ws 'cfg-off.json')
    Assert-Equal 0 $r0.exitCode 'MonitorOnly run ok'
    $evts = Get-LogEventNames $keeperRoot
    Assert-False ($evts -contains 'ANCHOR_EXECUTED') 'MonitorOnly never anchors'
    Clear-Backoff $keeperRoot

    Start-TestGroup 'anchor: full flow - reset observed -> exec -> verify -> anchored'

    # Baseline read must see the OLD window first so the reset is detected.
    $env:CQK_MOCK_MODE = 'normal'
    $r1 = Invoke-RunnerSub -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 0 $r1.exitCode "baseline run ok ($($r1.output))"
    Clear-Backoff $keeperRoot

    $env:CQK_MOCK_MODE = 'reset'
    $r2 = Invoke-RunnerSub -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 0 $r2.exitCode "anchor run ok ($($r2.output))"
    $evts2 = Get-LogEventNames $keeperRoot
    Assert-Contains $evts2 'ANCHOR_EXECUTED' 'anchor executed'
    Assert-False ($evts2 -contains 'ANCHOR_ABORTED') 'no abort on the happy path'

    $state = Read-JsonFile (Join-Path $keeperRoot 'runtime\state.json')
    Assert-Equal 1 $state.anchors.count 'anchor counted'
    Assert-NotNull $state.anchors.lastAnchorAt 'lastAnchorAt recorded'
    $expectedId = Get-Sha256Hex 'codex-default|primary|300|1788062400|reset'
    Assert-Contains $state.processedEventIds $expectedId 'eventId marked processed'

    $histFileItem = Get-ChildItem -LiteralPath (Join-Path $keeperRoot 'history') -Filter 'events-*.jsonl' -File | Select-Object -First 1
    Assert-True ($null -ne $histFileItem) 'anchor history event file written'
    $histText = [System.IO.File]::ReadAllText($histFileItem.FullName)
    Assert-True ("$histText" -match 'ANCHOR_EXECUTED') 'anchor record in history'
    Assert-False ("$histText" -match 'Reply exactly OK') 'prompt text never appears in history'
    Assert-True ("$histText" -match '"verified":true') 'before/after verification recorded'

    $claimFile = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/coordination' -PathInRepo ('coordination/events/' + $expectedId + '.json')
    Assert-True ($claimFile.ok -and $claimFile.reason -eq 'ok') 'remote claim event file exists'
    Assert-True ("$($claimFile.content)" -match 'COMPLETED') 'claim state COMPLETED'

    Start-TestGroup 'anchor: idempotency - same reset never re-anchored'

    $r3 = Invoke-RunnerSub -KeeperRoot $keeperRoot -ConfigFile $cfgFile
    Assert-Equal 0 $r3.exitCode 'repeat run ok'
    $evts3 = Get-LogEventNames $keeperRoot
    $anchorCount = @($evts3 | Where-Object { $_ -eq 'ANCHOR_EXECUTED' }).Count
    Assert-Equal 1 $anchorCount 'anchor executed exactly once total'
    $state3 = Read-JsonFile (Join-Path $keeperRoot 'runtime\state.json')
    Assert-Equal 1 $state3.anchors.count 'counter not incremented again'

    Start-TestGroup 'anchor: remote duplicate lock blocks a second machine'

    # Fresh machine + fresh state, same remote: baseline first, then the reset;
    # the remote marker must stop the anchor.
    $keeperRoot2 = Join-Path $ws 'keeper2'
    New-Item -ItemType Directory -Path $keeperRoot2 -Force | Out-Null
    $cfgFile2 = Join-Path $keeperRoot2 'config.json'
    $null = Write-TestConfigFile $cfgFile2 $cfg
    $null = Initialize-LogRepo -RepoPath $repos.clone -KeeperRoot $keeperRoot2
    Write-JsonFileAtomic (Join-Path $keeperRoot2 'runtime\machine.json') @{
        machineId = 'SECOND-MACHINE-002'; label = 'PC-2'; createdAt = '2026-08-30T00:00:00+08:00'
    }
    Reset-RemoteLease -ClonePath $repos.clone
    $env:CQK_MOCK_MODE = 'normal'
    $r4a = Invoke-RunnerSub -KeeperRoot $keeperRoot2 -ConfigFile $cfgFile2
    Assert-Equal 0 $r4a.exitCode "second machine baseline ok ($($r4a.output))"
    Clear-Backoff $keeperRoot2
    $env:CQK_MOCK_MODE = 'reset'
    $r4 = Invoke-RunnerSub -KeeperRoot $keeperRoot2 -ConfigFile $cfgFile2
    Assert-Equal 0 $r4.exitCode 'second machine run ok'
    $evts4 = Get-LogEventNames $keeperRoot2
    Assert-False ($evts4 -contains 'ANCHOR_EXECUTED') 'second machine did not anchor'
    Assert-Contains $evts4 'ANCHOR_ABORTED' 'abort recorded'
    $state4 = Read-JsonFile (Join-Path $keeperRoot2 'runtime\state.json')
    Assert-Equal 0 $state4.anchors.count 'second machine executed no model call'

    Start-TestGroup 'anchor: exec failure -> ABORTED, no verification retry'

    $keeperRoot3 = Join-Path $ws 'keeper3'
    New-Item -ItemType Directory -Path $keeperRoot3 -Force | Out-Null
    $cfgFile3 = Join-Path $keeperRoot3 'config.json'
    $null = Write-TestConfigFile $cfgFile3 $cfg
    $null = Initialize-LogRepo -RepoPath $repos.clone -KeeperRoot $keeperRoot3
    Reset-RemoteLease -ClonePath $repos.clone
    $env:CQK_MOCK_MODE = 'normal'
    $r5 = Invoke-RunnerSub -KeeperRoot $keeperRoot3 -ConfigFile $cfgFile3
    Clear-Backoff $keeperRoot3
    Clear-AnchorEvents -ClonePath $repos.clone
    $env:CQK_MOCK_MODE = 'reset'
    $env:CQK_MOCK_EXEC = 'fail'
    $r6 = Invoke-RunnerSub -KeeperRoot $keeperRoot3 -ConfigFile $cfgFile3
    Assert-Equal 0 $r6.exitCode 'exec-failure run still exits 0'
    $evts6 = Get-LogEventNames $keeperRoot3
    Assert-Contains $evts6 'ANCHOR_ABORTED' 'abort recorded'
    $state6 = Read-JsonFile (Join-Path $keeperRoot3 'runtime\state.json')
    Assert-Equal 1 $state6.anchors.count 'attempt counted (quota consumed)'
    $env:CQK_MOCK_EXEC = 'ok'

    Start-TestGroup 'anchor: verification failure -> ABORTED without retry'

    $keeperRoot4 = Join-Path $ws 'keeper4'
    New-Item -ItemType Directory -Path $keeperRoot4 -Force | Out-Null
    $cfgFile4 = Join-Path $keeperRoot4 'config.json'
    $null = Write-TestConfigFile $cfgFile4 $cfg
    $null = Initialize-LogRepo -RepoPath $repos.clone -KeeperRoot $keeperRoot4
    Reset-RemoteLease -ClonePath $repos.clone
    $env:CQK_MOCK_MODE = 'normal'
    $r7 = Invoke-RunnerSub -KeeperRoot $keeperRoot4 -ConfigFile $cfgFile4
    Clear-Backoff $keeperRoot4
    Clear-AnchorEvents -ClonePath $repos.clone
    $countdownFile = Join-Path $ws 'countdown4.txt'
    Set-Content -Path $countdownFile -Value '1'
    $env:CQK_MOCK_READ_COUNTDOWN_FILE = $countdownFile
    $env:CQK_MOCK_MODE = 'reset'
    $r8 = Invoke-RunnerSub -KeeperRoot $keeperRoot4 -ConfigFile $cfgFile4
    Assert-Equal 0 $r8.exitCode 'verify-failure run still exits 0'
    $evts8 = Get-LogEventNames $keeperRoot4
    Assert-Contains $evts8 'ANCHOR_ABORTED' 'verification failure aborts'
    Assert-False ($evts8 -contains 'ANCHOR_EXECUTED') 'not marked anchored'
    Remove-Item Env:\CQK_MOCK_READ_COUNTDOWN_FILE -ErrorAction SilentlyContinue

    Start-TestGroup 'anchor: daily cap enforced end-to-end'

    $keeperRoot5 = Join-Path $ws 'keeper5'
    New-Item -ItemType Directory -Path $keeperRoot5 -Force | Out-Null
    $cfgFile5 = Join-Path $keeperRoot5 'config.json'
    $cfgCap = New-TestConfig @{
        mode  = 'AutoAnchor'
        codex = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 1; minimumGapMinutes = 1 } }
        github = @{ coordination = @{ enabled = $true; repoPath = $repos.clone; branch = 'cqk/coordination' }; historySync = @{ enabled = $true; push = $true; branch = 'cqk/history'; eventsOnly = $true } }
    }
    $null = Write-TestConfigFile $cfgFile5 $cfgCap
    $null = Initialize-LogRepo -RepoPath $repos.clone -KeeperRoot $keeperRoot5
    Reset-RemoteLease -ClonePath $repos.clone
    Clear-AnchorEvents -ClonePath $repos.clone
    $env:CQK_MOCK_MODE = 'normal'
    $r9 = Invoke-RunnerSub -KeeperRoot $keeperRoot5 -ConfigFile $cfgFile5
    Clear-Backoff $keeperRoot5
    $env:CQK_MOCK_MODE = 'reset'
    $r10 = Invoke-RunnerSub -KeeperRoot $keeperRoot5 -ConfigFile $cfgFile5
    Assert-Equal 0 $r10.exitCode 'cap run 1 ok'
    $state5 = Read-JsonFile (Join-Path $keeperRoot5 'runtime\state.json')
    Assert-Equal 1 $state5.anchors.count 'first anchor executed under cap 1'
    # Make the same event look fresh again while the cap is already reached.
    $state5.processedEventIds = @()
    $state5.anchors = @{ day = (Get-Date).ToString('yyyy-MM-dd'); count = 1; lastAnchorAt = $null }
    Save-KeeperState -Root $keeperRoot5 -State $state5
    Clear-AnchorEvents -ClonePath $repos.clone
    $r11 = Invoke-RunnerSub -KeeperRoot $keeperRoot5 -ConfigFile $cfgFile5
    Assert-Equal 0 $r11.exitCode 'cap run 2 ok'
    $state5b = Read-JsonFile (Join-Path $keeperRoot5 'runtime\state.json')
    Assert-Equal 1 $state5b.anchors.count 'daily cap blocks the second anchor'
    $evts11 = Get-LogEventNames $keeperRoot5
    Assert-False ($evts11 -contains 'ANCHOR_EXECUTED_2') 'no duplicate executed event'
    $env:CQK_MOCK_MODE = 'normal'
} finally {
    Remove-Item Env:\CQK_MOCK_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:\CQK_MOCK_EXEC -ErrorAction SilentlyContinue
    Remove-Item Env:\CQK_MOCK_READ_COUNTDOWN_FILE -ErrorAction SilentlyContinue
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "auto-anchor.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
