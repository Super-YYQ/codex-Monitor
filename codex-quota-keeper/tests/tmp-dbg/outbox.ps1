$ErrorActionPreference = 'Stop'
$testsDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'github-sync.ps1')
. (Join-Path $scriptDir 'logger.ps1')
$ws = New-TestWorkspace
$repos = New-TestOriginAndClone -Workspace $ws
$keeperRoot = Join-Path $ws 'keeper'
New-Item -ItemType Directory -Path $keeperRoot -Force | Out-Null
$cfg = New-TestConfig @{ github = @{ coordination = @{ enabled = $true; repoPath = $repos.clone; branch = 'cqk/coordination' }; historySync = @{ enabled = $true; push = $true; branch = 'cqk/history'; eventsOnly = $true } } }
$machine = @{ machineId = 'M-TEST'; label = 'T' }
$null = Write-OutboxEvent -Root $keeperRoot -Record @{ eventId = 'deadbeef'; event = 'WINDOW_RESET_OBSERVED'; recordedAt = '2026-08-30T10:00:00+08:00' } -MachineId 'M-TEST' -When (Get-Date)
$pending = @(Get-ChildItem (Get-OutboxDir $keeperRoot) -Filter '*.json' -File)
Write-Host "pending before: $(@($pending).Count)"
$summary = Update-DailySummary -Root $keeperRoot -Date '2026-08-30' -EventCounts @{ WINDOW_RESET_OBSERVED = 1 } -MachineId 'M-TEST'
$r = Sync-OutboxToGitHub -Config $cfg -KeeperRoot $keeperRoot -Machine $machine -CommitMessage 'quota: reset observed' -SummaryFiles @($summary)
Write-Host "sync: ok=$($r.ok) reason=$($r.reason) pushed=$($r.pushed) detail=$($r.detail)"
$pending2 = @(Get-ChildItem (Get-OutboxDir $keeperRoot) -Filter '*.json' -File)
Write-Host "pending after: $(@($pending2).Count) syncState=$(Test-Path (Get-SyncStatePath $keeperRoot))"
$paths = Invoke-TestGit -RepoPath $repos.clone -ArgumentList @('ls-tree','-r','--name-only','origin/cqk/history')
Write-Host "remote: $($paths.stdout.Trim() -replace "`n", ' | ')"
Remove-TestWorkspace $ws
