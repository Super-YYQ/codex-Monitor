# Tests for github-sync.ps1: repo whitelist, plumbing-based blob push with
# push-rejection CAS, remote blob read, history sync isolation from failures.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'github-sync.ps1')

Start-TestGroup 'git available in test environment'

Assert-True (Test-GitAvailable) 'git must be available for these tests'

Start-TestGroup 'whitelist: repoPath disjoint from keeper project'

$ws = New-TestWorkspace
try {
    $keeperRoot = Join-Path $ws 'keeper'
    New-Item -ItemType Directory -Path $keeperRoot -Force | Out-Null
    $repos = New-TestOriginAndClone -Workspace $ws

    $issues = Test-LogRepoAllowed -RepoPath $keeperRoot -KeeperRoot $keeperRoot
    Assert-True ($issues.Count -ge 1) 'keeper dir itself rejected'

    $inside = Join-Path $keeperRoot 'somewhere\logrepo'
    $issues = Test-LogRepoAllowed -RepoPath $inside -KeeperRoot $keeperRoot
    Assert-True ($issues.Count -ge 1) 'path inside keeper rejected'

    $issues = Test-LogRepoAllowed -RepoPath (Join-Path $ws 'not-exist') -KeeperRoot $keeperRoot
    Assert-True ($issues.Count -ge 1) 'missing path rejected'

    $plainDir = Join-Path $ws 'plain'
    New-Item -ItemType Directory -Path $plainDir -Force | Out-Null
    $issues = Test-LogRepoAllowed -RepoPath $plainDir -KeeperRoot $keeperRoot
    Assert-True ($issues.Count -ge 1) 'non-git dir rejected'

    $issues = Test-LogRepoAllowed -RepoPath $repos.clone -KeeperRoot $keeperRoot
    Assert-Equal 0 $issues.Count 'proper clone accepted'

    Start-TestGroup 'plumbing: push blob to new branch (root commit)'

    $push1 = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/history' `
        -Blobs @{ 'history/events-2026-08-30.jsonl' = "line1`nline2`n" } `
        -ParentCommit $null -CommitMessage 'quota: test' -MachineId 'M-TEST'
    Assert-True $push1.ok "first push ok ($($push1.reason) $($push1.stderr))"

    $blob = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/history' -PathInRepo 'history/events-2026-08-30.jsonl'
    Assert-True $blob.ok 'blob readable from remote'
    Assert-Equal 'ok' $blob.reason 'blob present'
    Assert-True ("$($blob.content)" -match 'line2') 'content matches'

    Start-TestGroup 'CAS: stale-parent push rejected, fresh-parent push accepted'

    $pushWin = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/history' `
        -Blobs @{ 'history/events-2026-08-30.jsonl' = "line1`nline2`nappended`n" } `
        -ParentCommit $push1.commit -CommitMessage 'quota: race winner'
    Assert-True $pushWin.ok "fresh parent push accepted ($($pushWin.reason))"

    $pushStale = Push-RepoBlobs -RepoPath $repos.clone -Branch 'cqk/history' `
        -Blobs @{ 'history/events-2026-08-30.jsonl' = "conflicting`n" } `
        -ParentCommit $push1.commit -CommitMessage 'quota: race loser'
    # parent C1 is now an ancestor (head moved to the winner commit) -> non-FF -> rejected
    Assert-False $pushStale.ok 'stale parent push rejected'
    Assert-Equal 'push-rejected' $pushStale.reason 'rejection reason'
    Assert-False ("$($pushStale.stderr)" -match 'ghp_|github_pat_') 'no tokens in git stderr'

    $blob2 = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/history' -PathInRepo 'history/events-2026-08-30.jsonl'
    Assert-True ("$($blob2.content)" -match 'appended') 'winner content visible'
    Assert-False ("$($blob2.content)" -match 'conflicting') 'loser content not visible'

    Start-TestGroup 'missing branch / file reported correctly'

    $missing = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/coordination' -PathInRepo 'coordination/lease.json'
    Assert-True $missing.ok 'remote reachable'
    Assert-Equal 'branch-missing' $missing.reason 'branch missing on fresh repo'

    $nofile = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/history' -PathInRepo 'history/nope.jsonl'
    Assert-Equal 'file-missing' $nofile.reason 'file missing on existing branch'

    Start-TestGroup 'history sync: end-to-end push + failure isolation'

    $histDir = Join-Path $ws 'keeper\history'
    New-Item -ItemType Directory -Path $histDir -Force | Out-Null
    $evFile = Join-Path $histDir 'events-2026-08-30.jsonl'
    [System.IO.File]::WriteAllText($evFile, '{"event":"WINDOW_RESET_OBSERVED"}' + "`n")

    $cfg = New-TestConfig @{ github = @{ coordination = @{ enabled = $true; repoPath = $repos.clone; branch = 'cqk/coordination' }; historySync = @{ enabled = $true; push = $true; branch = 'cqk/history'; eventsOnly = $true } } }
    $sync = Sync-HistoryToGitHub -Config $cfg -KeeperRoot $keeperRoot -FilePaths @($evFile) -CommitMessage 'quota: reset observed' -MachineId 'M-TEST'
    Assert-True $sync.ok "history sync ok ($($sync.reason) $($sync.detail))"
    Assert-Equal 1 $sync.pushed 'one file pushed'

    $remote = Get-RemoteBranchBlob -RepoPath $repos.clone -Branch 'cqk/history' -PathInRepo 'history/events-2026-08-30.jsonl'
    Assert-True ("$($remote.content)" -match 'WINDOW_RESET_OBSERVED') 'event content on remote'

    # Second sync re-fetches the parent (fresh head) and overwrites cleanly.
    # Push-rejection races are proven at the Push-RepoBlobs CAS test above.
    $sync2 = Sync-HistoryToGitHub -Config $cfg -KeeperRoot $keeperRoot -FilePaths @($evFile) -CommitMessage 'quota: daily summary'
    Assert-True $sync2.ok "second sync ok ($($sync2.reason) $($sync2.detail))"
    Assert-True (Test-Path $evFile) 'local history file untouched by sync'

    Start-TestGroup 'history sync: disabled/unreachable never throws'

    $cfgOff = New-TestConfig @{ github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } } }
    $syncOff = Sync-HistoryToGitHub -Config $cfgOff -KeeperRoot $keeperRoot -FilePaths @($evFile) -CommitMessage 'x'
    Assert-Equal 'disabled' $syncOff.reason 'disabled reason'

    $cfgBad = New-TestConfig @{ github = @{ coordination = @{ enabled = $true; repoPath = Join-Path $ws 'does-not-exist' } } }
    $syncBad = Sync-HistoryToGitHub -Config $cfgBad -KeeperRoot $keeperRoot -FilePaths @($evFile) -CommitMessage 'x'
    Assert-False $syncBad.ok 'unreachable/bad repo not ok'
    Assert-True ($syncBad.reason -in @('repo-not-allowed', 'unreachable')) "bad repo reason ($($syncBad.reason))"
} finally {
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "github-sync.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
