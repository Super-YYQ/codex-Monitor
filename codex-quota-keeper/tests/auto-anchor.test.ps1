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
    param([string]$KeeperRoot, [string]$ConfigFile, [switch]$ForceAnchor)
    $subArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath, '-KeeperRoot', $KeeperRoot, '-ConfigFile', $ConfigFile)
    if ($ForceAnchor) { $subArgs += '-ForceAnchor' }
    $out = & $pwsh @subArgs 2>&1
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
Assert-True (Test-AnchorPromptAllowed -Prompt '回复 恰好 OK') 'unicode (Chinese) prompt allowed'
Assert-True (Test-AnchorPromptAllowed -Prompt ("x" * 200)) '200 chars allowed'
Assert-False (Test-AnchorPromptAllowed -Prompt 'a"b') 'double quote rejected'
Assert-False (Test-AnchorPromptAllowed -Prompt 'a>b') 'redirect character rejected'
Assert-False (Test-AnchorPromptAllowed -Prompt 'a&b') 'ampersand rejected'
Assert-False (Test-AnchorPromptAllowed -Prompt 'a%PATH%b') 'percent rejected'
Assert-False (Test-AnchorPromptAllowed -Prompt "line1`nline2") 'newline rejected'
Assert-False (Test-AnchorPromptAllowed -Prompt '') 'empty rejected'
Assert-False (Test-AnchorPromptAllowed -Prompt ('x' * 201)) 'overlong rejected'

$ws = New-TestWorkspace
try {
    $repos = New-TestOriginAndClone -Workspace $ws
    $keeperRoot = Join-Path $ws 'keeper'
    New-Item -ItemType Directory -Path $keeperRoot -Force | Out-Null
    $cfgFile = Join-Path $keeperRoot 'config.json'
    $cfg = New-TestConfig @{
        mode  = 'AutoAnchor'
        # keepalive=0 here: these scenarios exercise reset-triggered anchoring,
        # where the first run must be a passive baseline (no trigger may fire on
        # the first observation - idle detection also needs a second record).
        codex = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 1; keepaliveIntervalMinutes = 0 } }
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

    # History audit file: written only when a significant event fires. A missing
    # file means the anchor flow did not execute on this runner; dump everything
    # observable so the CI log shows exactly which sub-run diverged.
    $histDir = Join-Path $keeperRoot 'history'
    $histFileItem = Get-ChildItem -LiteralPath $histDir -Filter 'events-*.jsonl' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    Assert-True ($null -ne $histFileItem) 'anchor history event file written'
    if ($null -eq $histFileItem) {
        Write-Host 'DIAG: no history/events-*.jsonl under keeper root' -ForegroundColor Yellow
        if (Test-Path -LiteralPath $histDir) {
            Get-ChildItem -LiteralPath $histDir -Force -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "DIAG: history entry: $($_.Name)" -ForegroundColor Yellow }
        } else {
            Write-Host 'DIAG: history directory is missing entirely' -ForegroundColor Yellow
        }
        Write-Host "DIAG: r1 exit=$($r1.exitCode)" -ForegroundColor Yellow
        Write-Host "DIAG: r1 output:`n$($r1.output)" -ForegroundColor Yellow
        Write-Host "DIAG: r2 exit=$($r2.exitCode)" -ForegroundColor Yellow
        Write-Host "DIAG: r2 output:`n$($r2.output)" -ForegroundColor Yellow
        Write-Host ("DIAG: events seen: " + ($evts2 -join ', ')) -ForegroundColor Yellow
        $stateDump = Read-JsonFile (Join-Path $keeperRoot 'runtime\state.json')
        if ($stateDump) {
            Write-Host ('DIAG: state.anchors=' + (ConvertTo-Json -InputObject $stateDump.anchors -Compress -Depth 6)) -ForegroundColor Yellow
            Write-Host ('DIAG: state.processedEventIds=' + (ConvertTo-Json -InputObject $stateDump.processedEventIds -Compress -Depth 6)) -ForegroundColor Yellow
        } else {
            Write-Host 'DIAG: state.json unreadable or missing' -ForegroundColor Yellow
        }
    } else {
        $histText = [System.IO.File]::ReadAllText($histFileItem.FullName)
        Assert-True ("$histText" -match 'ANCHOR_EXECUTED') 'anchor record in history'
        Assert-False ("$histText" -match 'Reply exactly OK') 'prompt text never appears in history'
        Assert-True ("$histText" -match '"verified":true') 'before/after verification recorded'
    }

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
        codex = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 1; minimumGapMinutes = 1; keepaliveIntervalMinutes = 0 } }
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

    Start-TestGroup 'anchor: scenario-1 idle detection (never used Codex, fires on the second observation)'

    # Local-only machine (no coordination repo), keepalive=0: the only trigger
    # left is the idle detection. Run 1 is a baseline; run 2 sees a second
    # observation with zero usage and fires exactly one CLI call; run 3 (no
    # reset, keepalive=0) must stay quiet.
    $keeperRoot6 = Join-Path $ws 'keeper6'
    New-Item -ItemType Directory -Path $keeperRoot6 -Force | Out-Null
    $cfgFile6 = Join-Path $keeperRoot6 'config.json'
    $cfgLocal = New-TestConfig @{
        mode   = 'AutoAnchor'
        codex  = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 300; keepaliveIntervalMinutes = 0 } }
        github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } }
    }
    $null = Write-TestConfigFile $cfgFile6 $cfgLocal
    $env:CQK_MOCK_MODE = 'idle'
    $env:CQK_MOCK_EXEC = 'ok'
    # Run 1: one poll record is only a baseline - the keeper needs a SECOND
    # observation before concluding "nobody is using Codex".
    $rIdle1 = Invoke-RunnerSub -KeeperRoot $keeperRoot6 -ConfigFile $cfgFile6
    Assert-Equal 0 $rIdle1.exitCode "first idle run ok ($($rIdle1.output))"
    $stateL0 = Read-JsonFile (Join-Path $keeperRoot6 'runtime\state.json')
    Assert-Equal 0 $stateL0.anchors.count 'first observation records a baseline, no anchor'
    $evtsIdle1 = Get-LogEventNames $keeperRoot6
    Assert-False ($evtsIdle1 -contains 'ANCHOR_EXECUTED') 'no CLI call on the very first run'
    # Run 2: second observation, still zero usage -> idle detection fires the CLI.
    $rIdle2 = Invoke-RunnerSub -KeeperRoot $keeperRoot6 -ConfigFile $cfgFile6
    Assert-Equal 0 $rIdle2.exitCode "idle run 2 ok ($($rIdle2.output))"
    $evtsIdle2 = Get-LogEventNames $keeperRoot6
    Assert-Contains $evtsIdle2 'ANCHOR_LOCAL' 'local claim path used'
    Assert-Contains $evtsIdle2 'ANCHOR_EXECUTED' 'idle detection anchors a never-used Codex account'
    Assert-False ($evtsIdle2 -contains 'ANCHOR_ABORTED') 'no abort on the idle happy path'
    $stateL = Read-JsonFile (Join-Path $keeperRoot6 'runtime\state.json')
    Assert-Equal 1 $stateL.anchors.count 'idle anchor counted'
    Assert-NotNull $stateL.anchors.lastAnchorAt 'idle anchor timestamp recorded'
    Assert-Equal 1 @($stateL.processedEventIds).Count 'idle eventId marked processed'
    # Run 3: the 5h quiet must hold - keepalive=0, no reset, minGap=300.
    $rIdle3 = Invoke-RunnerSub -KeeperRoot $keeperRoot6 -ConfigFile $cfgFile6
    Assert-Equal 0 $rIdle3.exitCode "third idle run ok ($($rIdle3.output))"
    $stateL2 = Read-JsonFile (Join-Path $keeperRoot6 'runtime\state.json')
    Assert-Equal 1 $stateL2.anchors.count 'no re-trigger after the idle anchor'
    $env:CQK_MOCK_MODE = 'normal'

    Start-TestGroup 'anchor: anchorOnApply forces an immediate CLI call'

    # keepalive=0 + minGap=60 + no reset: nothing fires without the force.
    $keeperRoot7 = Join-Path $ws 'keeper7'
    New-Item -ItemType Directory -Path $keeperRoot7 -Force | Out-Null
    $cfgFile7 = Join-Path $keeperRoot7 'config.json'
    $cfgForce = New-TestConfig @{
        mode   = 'AutoAnchor'
        codex  = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60; keepaliveIntervalMinutes = 0 } }
        github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } }
    }
    $null = Write-TestConfigFile $cfgFile7 $cfgForce
    $r14 = Invoke-RunnerSub -KeeperRoot $keeperRoot7 -ConfigFile $cfgFile7
    Assert-Equal 0 $r14.exitCode "baseline run ok ($($r14.output))"
    $stF0 = Read-JsonFile (Join-Path $keeperRoot7 'runtime\state.json')
    Assert-Equal 0 $stF0.anchors.count 'no anchor without reset/keepalive/force'

    # runner -ForceAnchor (what install/apply-config fire on anchorOnApply=true):
    # the CLI runs immediately even though keepalive=0, minGap=60 and no reset.
    $r15 = Invoke-RunnerSub -KeeperRoot $keeperRoot7 -ConfigFile $cfgFile7 -ForceAnchor
    Assert-Equal 0 $r15.exitCode "forced anchor run ok ($($r15.output))"
    $evts15 = Get-LogEventNames $keeperRoot7
    Assert-Contains $evts15 'ANCHOR_EXECUTED' 'forced run executes the CLI'
    Assert-Contains $evts15 'ANCHOR_LOCAL' 'forced run used the local path'
    Assert-False ($evts15 -contains 'ANCHOR_ABORTED') 'no abort on the forced happy path'
    $stF1 = Read-JsonFile (Join-Path $keeperRoot7 'runtime\state.json')
    Assert-Equal 1 $stF1.anchors.count 'forced anchor counted'
    Assert-NotNull $stF1.anchors.lastAnchorAt 'forced anchor timestamp recorded'
    Assert-Equal 1 @($stF1.processedEventIds).Count 'force eventId marked processed (exact id unit-tested)'

    Start-TestGroup 'anchor: schedule timer mode - a due daily slot fires without any reset'

    # Pure timer mode (codex.autoAnchor.schedule): the first poll at/after a
    # configured HH:mm fires the CLI - no second observation, no reset, no
    # keepalive. The slot is computed as "one minute ago" so it is due on run 1;
    # run 2 (same day) must not re-fire. keepalive=0 and minGap=300 prove the
    # timer bypasses both. mock 'idle' keeps usage at zero so no other trigger
    # can be responsible.
    $keeperRoot8 = Join-Path $ws 'keeper8'
    New-Item -ItemType Directory -Path $keeperRoot8 -Force | Out-Null
    $cfgFile8 = Join-Path $keeperRoot8 'config.json'
    $slotBase = (Get-Date).AddMinutes(-1)
    $slotAt = if ($slotBase.Date -ne (Get-Date).Date) { (Get-Date).Date } else { $slotBase }
    $slotText = $slotAt.ToString('HH:mm')
    $cfgSch = New-TestConfig @{
        mode   = 'AutoAnchor'
        codex  = @{ command = $mockPath; queryTimeoutSeconds = 15; autoAnchor = @{ enabled = $true; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 300; keepaliveIntervalMinutes = 0; schedule = @($slotText) } }
        github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } }
    }
    $null = Write-TestConfigFile $cfgFile8 $cfgSch
    $env:CQK_MOCK_MODE = 'idle'
    $env:CQK_MOCK_EXEC = 'ok'
    # Run 1: the due slot triggers on the very first run, with no usage history.
    $rSch1 = Invoke-RunnerSub -KeeperRoot $keeperRoot8 -ConfigFile $cfgFile8
    Assert-Equal 0 $rSch1.exitCode "schedule run 1 ok ($($rSch1.output))"
    $evtsSch1 = Get-LogEventNames $keeperRoot8
    Assert-Contains $evtsSch1 'ANCHOR_LOCAL' 'local claim path used'
    Assert-Contains $evtsSch1 'ANCHOR_EXECUTED' 'due slot executes the CLI on the first run'
    Assert-False ($evtsSch1 -contains 'ANCHOR_ABORTED') 'no abort on the schedule happy path'
    $stSch = Read-JsonFile (Join-Path $keeperRoot8 'runtime\state.json')
    Assert-Equal 1 $stSch.anchors.count 'scheduled anchor counted'
    Assert-Equal 1 @($stSch.processedEventIds).Count 'schedule eventId marked processed'
    $histSchItem = Get-ChildItem -LiteralPath (Join-Path $keeperRoot8 'history') -Filter 'events-*.jsonl' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($histSchItem) {
        $histSchText = [System.IO.File]::ReadAllText($histSchItem.FullName)
        Assert-True ("$histSchText" -match '"trigger":"schedule"') 'history records trigger=schedule'
    } else {
        Assert-True $false 'schedule anchor history event file written'
    }
    # Run 2: same day - the slot is already processed, nothing re-fires.
    $rSch2 = Invoke-RunnerSub -KeeperRoot $keeperRoot8 -ConfigFile $cfgFile8
    Assert-Equal 0 $rSch2.exitCode "schedule run 2 ok ($($rSch2.output))"
    $stSch2 = Read-JsonFile (Join-Path $keeperRoot8 'runtime\state.json')
    Assert-Equal 1 $stSch2.anchors.count 'same-day slot does not re-fire'
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
