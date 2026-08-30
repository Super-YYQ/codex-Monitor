# Codex Quota Keeper - GitHub log/coordination repo access.
# All remote writes use git plumbing (hash-object/update-index/commit-tree/push)
# against a temporary index, so the user's checked-out working tree in the log
# repo is never touched. Concurrency control = push rejection (non-fast-forward).

$script:CqkGithubSyncDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkGithubSyncDir 'common.ps1')
}

function Test-GitAvailable {
    return ($null -ne (Get-Command git -ErrorAction SilentlyContinue))
}

function Get-GitExe {
    return (Get-Command git -ErrorAction SilentlyContinue).Source
}

function Get-OriginFingerprint {
    # Fingerprint of the log repo's origin URL with any userinfo stripped, so a
    # binding survives credential rotation but breaks if the remote changes.
    param([string]$RepoPath)
    $git = Get-GitExe
    if (-not $git) { return $null }
    $r = Invoke-External -FilePath $git -ArgumentList @('-C', $RepoPath, 'remote', 'get-url', 'origin') -TimeoutSeconds 15
    if (-not $r.ok) { return $null }
    $url = $r.stdout.Trim()
    $url = [regex]::Replace($url, '([a-z][a-z0-9+.\-]*://)[^/\s@]+@', '$1')
    return (Get-Sha256Hex $url.ToLowerInvariant())
}

# Dedicated log-repo binding (audit plan v1.0 §10 / CQK-011)

$script:CQK_MARKER_FILE = '.codex-quota-keeper-repository.json'
$script:CQK_FORBIDDEN_BRANCHES = @('main', 'master', 'develop', 'release', 'trunk', 'dev')

function Get-LogRepoBindingPath { param([string]$Root) Join-Path (Get-RuntimeDir $Root) 'log-repo.json' }

function Initialize-LogRepo {
    # One-time explicit setup: writes the marker into the log repo working tree
    # and records repoId + origin fingerprint in runtime. Every later push
    # verifies this binding; a misconfigured business repo is refused.
    param([string]$RepoPath, [string]$KeeperRoot)
    $issues = Test-LogRepoAllowed -RepoPath $RepoPath -KeeperRoot $KeeperRoot
    if ($issues.Count -gt 0) { return @{ ok = $false; issues = $issues } }
    if (Test-GitAvailable) {
        $bare = Invoke-Git -RepoPath $RepoPath -ArgumentList @('rev-parse', '--is-bare-repository') -TimeoutSeconds 10
        if ($bare.ok -and $bare.stdout.Trim() -eq 'true') {
            return @{ ok = $false; issues = @('log repo must be a working clone (not bare) so the marker file can be written') }
        }
    }

    # Idempotent: an existing marker keeps its repoId so multiple keeper
    # installations bound to the same log repo stay consistent.
    $markerPath = Join-Path $RepoPath $script:CQK_MARKER_FILE
    $existingMarker = Read-JsonFile $markerPath
    $repoId = [guid]::NewGuid().ToString()
    if ($existingMarker -is [hashtable] -and $existingMarker.repoId -and [string]$existingMarker.createdFor -eq 'codex-quota-keeper') {
        $repoId = [string]$existingMarker.repoId
    }
    $marker = @{
        schema          = 1
        repoId          = $repoId
        createdFor      = 'codex-quota-keeper'
        createdAt       = Get-IsoTimestamp
        allowedBranches = @('cqk/coordination', 'cqk/history')
    }
    Write-JsonFileAtomic $markerPath $marker

    $fingerprint = Get-OriginFingerprint -RepoPath $RepoPath
    if (-not $fingerprint) { return @{ ok = $false; issues = @('cannot read origin url of the log repo') } }

    Write-JsonFileAtomic (Get-LogRepoBindingPath $KeeperRoot) @{
        schema            = 1
        repoId            = $repoId
        repoPath          = [System.IO.Path]::GetFullPath($RepoPath)
        originFingerprint = $fingerprint
        initializedAt     = Get-IsoTimestamp
    }
    return @{ ok = $true; repoId = $repoId; markerPath = $markerPath; originFingerprint = $fingerprint }
}

function Test-LogRepoBinding {
    # Push gate: marker + repoId + origin fingerprint + allowed branch. Any
    # mismatch fails closed with a reason string.
    param([string]$RepoPath, [string]$KeeperRoot, [string]$Branch)
    $binding = Read-JsonFile (Get-LogRepoBindingPath $KeeperRoot)
    if ($null -eq $binding) { return 'not-initialized (run scripts/setup-log-repo.ps1)' }

    if ([System.IO.Path]::GetFullPath($RepoPath) -ne [string]$binding.repoPath) {
        return 'repoPath does not match the initialized binding'
    }
    $marker = Read-JsonFile (Join-Path $RepoPath $script:CQK_MARKER_FILE)
    if ($null -eq $marker) { return 'marker file missing in log repo' }
    if ([string]$marker.repoId -ne [string]$binding.repoId) { return 'marker repoId mismatch' }
    if ([string]$marker.createdFor -ne 'codex-quota-keeper') { return 'marker was not created for codex-quota-keeper' }

    $fingerprint = Get-OriginFingerprint -RepoPath $RepoPath
    if (-not $fingerprint -or $fingerprint -ne [string]$binding.originFingerprint) {
        return 'origin fingerprint mismatch (remote changed since initialization)'
    }

    # Business-branch guard first: main/master/... are forbidden even if someone
    # lists them in the marker.
    foreach ($b in $script:CQK_FORBIDDEN_BRANCHES) {
        if ($Branch -match "(^|/)$b$") { return "branch '$Branch' looks like a business branch and is forbidden" }
    }
    $allowed = @($marker.allowedBranches | ForEach-Object { [string]$_ })
    if ($allowed.Count -gt 0 -and $allowed -cnotcontains $Branch) {
        return "branch '$Branch' is not in the marker allowedBranches"
    }
    return $null
}

function Test-LogRepoAllowed {
    # Whitelist/normalization for github.repoPath: the log repo must be a real git
    # repository and must be disjoint from the keeper project itself, so automation
    # can never push into a user code repository (doc 03 §15).
    param([string]$RepoPath, [string]$KeeperRoot)
    $issues = @()
    if ([string]::IsNullOrWhiteSpace($RepoPath)) { return @('repoPath is empty') }
    if (-not (Test-GitAvailable)) { return @('git is not available') }

    $full = [System.IO.Path]::GetFullPath($RepoPath)
    $root = [System.IO.Path]::GetFullPath($KeeperRoot)
    if ($full -eq $root) { $issues += 'repoPath must not be the keeper project directory' }
    if ($full.StartsWith($root.TrimEnd('\') + '\', 'OrdinalIgnoreCase')) {
        $issues += 'repoPath must not live inside the keeper project'
    }
    if ($root.StartsWith($full.TrimEnd('\') + '\', 'OrdinalIgnoreCase')) {
        $issues += 'keeper project must not live inside the log repo'
    }
    if (-not (Test-Path -LiteralPath $full)) { $issues += "log repo not found: $full"; return $issues }

    $git = Invoke-Git -RepoPath $full -ArgumentList @('rev-parse', '--git-dir') -TimeoutSeconds 10
    if (-not $git.ok) { $issues += "not a git repository: $full" }
    return $issues
}

function Invoke-Git {
    # Argument-array git execution; stderr is sanitized (remote URLs can embed tokens).
    param(
        [string]$RepoPath,
        [string[]]$ArgumentList,
        [int]$TimeoutSeconds = 60,
        [hashtable]$Environment = $null
    )
    $args = @()
    if ($RepoPath) { $args += @('-C', $RepoPath) }
    $args += $ArgumentList
    $r = Invoke-External -FilePath (Get-GitExe) -ArgumentList $args -TimeoutSeconds $TimeoutSeconds -Environment $Environment
    return @{
        ok       = $r.ok
        exitCode = $r.exitCode
        stdout   = $r.stdout
        stderr   = (Hide-SensitiveText $r.stderr)
        timedOut = $r.timedOut
    }
}

function Test-RemoteReachable {
    param([string]$RepoPath)
    $r = Invoke-Git -RepoPath $RepoPath -ArgumentList @('ls-remote', 'origin', 'HEAD') -TimeoutSeconds 20
    return @{ ok = $r.ok; stderr = $r.stderr }
}

function Get-RemoteBranchBlob {
    # Returns the file content on origin/<branch> without any checkout, or $null.
    param([string]$RepoPath, [string]$Branch, [string]$PathInRepo)
    $fetch = Invoke-Git -RepoPath $RepoPath -ArgumentList @('fetch', 'origin', $Branch) -TimeoutSeconds 60
    if (-not $fetch.ok) {
        $ls = Invoke-Git -RepoPath $RepoPath -ArgumentList @('ls-remote', 'origin', $Branch) -TimeoutSeconds 20
        if (-not $ls.ok) {
            return @{ ok = $false; reason = 'unreachable'; detail = $fetch.stderr; content = $null; commit = $null }
        }
        return @{ ok = $true; reason = 'branch-missing'; detail = $null; content = $null; commit = $null }
    }
    $rev = Invoke-Git -RepoPath $RepoPath -ArgumentList @('rev-parse', "origin/$Branch") -TimeoutSeconds 15
    if (-not $rev.ok) {
        return @{ ok = $true; reason = 'branch-missing'; detail = $null; content = $null; commit = $null }
    }
    $commit = $rev.stdout.Trim()
    $show = Invoke-Git -RepoPath $RepoPath -ArgumentList @('show', "${commit}:${PathInRepo}") -TimeoutSeconds 15
    if (-not $show.ok) {
        return @{ ok = $true; reason = 'file-missing'; detail = $null; content = $null; commit = $commit }
    }
    return @{ ok = $true; reason = 'ok'; detail = $null; content = $show.stdout; commit = $commit }
}

function Push-RepoBlobs {
    # Builds a commit (via a temp index) whose tree contains exactly $Blobs
    # (path -> text content) and pushes it to refs/heads/<Branch> with parent
    # $ParentCommit ($null = root commit). Push rejection means another machine
    # won the race -> caller must retry as PASSIVE. No worktree is touched.
    param(
        [string]$RepoPath,
        [string]$Branch,
        [hashtable]$Blobs,
        [string]$ParentCommit,
        [string]$CommitMessage,
        [string]$MachineId = ''
    )
    if ($Blobs.Count -eq 0) { return @{ ok = $false; reason = 'nothing-to-commit'; stderr = $null } }

    # Carry the repository marker on every branch so remote state is self-describing.
    $markerPath = Join-Path $RepoPath $script:CQK_MARKER_FILE
    if (Test-Path -LiteralPath $markerPath) {
        if (-not $Blobs.ContainsKey($script:CQK_MARKER_FILE)) {
            $Blobs[$script:CQK_MARKER_FILE] = [System.IO.File]::ReadAllText($markerPath)
        }
    }

    $indexFile = Join-Path ([System.IO.Path]::GetTempPath()) ("cqk-index-" + [guid]::NewGuid().ToString('N'))
    $authorName = 'codex-quota-keeper'
    $authorEmail = if ($MachineId) { "keeper-$MachineId@local" } else { 'keeper@local' }
    $envs = @{
        GIT_INDEX_FILE     = $indexFile
        GIT_AUTHOR_NAME    = $authorName
        GIT_AUTHOR_EMAIL   = $authorEmail
        GIT_COMMITTER_NAME = $authorName
        GIT_COMMITTER_EMAIL = $authorEmail
    }

    try {
        # Seed the temp index from the parent tree so unrelated files already on
        # the branch survive this commit (only $Blobs paths are replaced).
        if ($ParentCommit) {
            $r = Invoke-Git -RepoPath $RepoPath -ArgumentList @('read-tree', $ParentCommit) -TimeoutSeconds 15 -Environment $envs
        } else {
            $r = Invoke-Git -RepoPath $RepoPath -ArgumentList @('read-tree', '--empty') -TimeoutSeconds 15 -Environment $envs
        }
        if (-not $r.ok) { return @{ ok = $false; reason = 'index-failed'; stderr = $r.stderr } }

        foreach ($path in $Blobs.Keys) {
            $tmpBlob = Join-Path ([System.IO.Path]::GetTempPath()) ("cqk-blob-" + [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllText($tmpBlob, [string]$Blobs[$path], (New-Object System.Text.UTF8Encoding($false)))
            try {
                $hash = Invoke-Git -RepoPath $RepoPath -ArgumentList @('hash-object', '-w', $tmpBlob) -TimeoutSeconds 15 -Environment $envs
            } finally {
                Remove-Item -LiteralPath $tmpBlob -Force -ErrorAction SilentlyContinue
            }
            if (-not $hash.ok) { return @{ ok = $false; reason = 'hash-failed'; stderr = $hash.stderr } }
            $blobSha = $hash.stdout.Trim()
            $add = Invoke-Git -RepoPath $RepoPath -ArgumentList @('update-index', '--add', '--cacheinfo', "100644,$blobSha,$path") -TimeoutSeconds 15 -Environment $envs
            if (-not $add.ok) { return @{ ok = $false; reason = 'index-add-failed'; stderr = $add.stderr } }
        }

        $tree = Invoke-Git -RepoPath $RepoPath -ArgumentList @('write-tree') -TimeoutSeconds 15 -Environment $envs
        if (-not $tree.ok) { return @{ ok = $false; reason = 'tree-failed'; stderr = $tree.stderr } }
        $treeSha = $tree.stdout.Trim()

        $commitArgs = @('commit-tree', $treeSha, '-m', $CommitMessage)
        if ($ParentCommit) { $commitArgs += @('-p', $ParentCommit) }
        $commit = Invoke-Git -RepoPath $RepoPath -ArgumentList $commitArgs -TimeoutSeconds 15 -Environment $envs
        if (-not $commit.ok) { return @{ ok = $false; reason = 'commit-failed'; stderr = $commit.stderr } }
        $commitSha = $commit.stdout.Trim()

        $push = Invoke-Git -RepoPath $RepoPath -ArgumentList @('push', 'origin', "${commitSha}:refs/heads/$Branch") -TimeoutSeconds 90
        if (-not $push.ok) {
            return @{ ok = $false; reason = 'push-rejected'; stderr = $push.stderr }
        }
        return @{ ok = $true; reason = 'pushed'; commit = $commitSha; stderr = $null }
    } finally {
        Remove-Item -LiteralPath $indexFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-OutboxDir { param([string]$Root) Join-Path (Get-RuntimeDir $Root) 'outbox' }
function Get-SyncStatePath { param([string]$Root) Join-Path (Get-RuntimeDir $Root) 'sync-state.json' }

function Write-OutboxEvent {
    # Durable outbox (audit plan v1.0 §8.2 / CQK-010): a significant event is
    # written to runtime/outbox/<id>.json BEFORE any push is attempted. The file
    # only leaves the outbox after a successful push, so CAS conflicts, network
    # failures and credential errors can never lose a pending event.
    # Reset events reuse their deterministic eventId; other events get a
    # timestamp+runId id. Remote paths are unique per machine, so concurrent
    # machines never overwrite each other's history.
    param(
        [string]$Root,
        [hashtable]$Record,
        [string]$MachineId,
        [string]$RunId = '',
        [switch]$IncludeMachineLabel,
        [DateTime]$When = (Get-Date)
    )
    $record.event = [string]$Record.event
    $record.schema = 1
    $record.recordedAt = $When.ToString('yyyy-MM-ddTHH:mm:sszzz')
    $record.machineId = [string]$MachineId
    $record.runId = $RunId
    $record.version = $script:CQK_VERSION

    $id = [string]$Record.eventId
    if ([string]::IsNullOrEmpty($id)) {
        $id = $When.ToLocalTime().ToString('yyyyMMddTHHmmss') + '_' + $RunId + '_' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    }
    $path = Join-Path (Get-OutboxDir $Root) ($id + '.json')
    Write-JsonFileAtomic $path $record
    return @{ id = $id; path = $path; when = $When }
}

function Sync-OutboxToGitHub {
    # Drains the durable outbox onto the immutable remote history layout:
    #   history/<date>/<machineId>/<stamp>_<EVENT>_<id>.json
    #   summary/<date>/<machineId>.json
    # Every remote path is unique, so a leader switch can never overwrite
    # another machine's audit data (CQK-009). Push failure keeps everything
    # pending for the next run (CQK-010).
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [hashtable]$Machine,
        [string]$RunId = '',
        [string]$CommitMessage = 'quota: daily summary',
        [string[]]$SummaryFiles = @()
    )
    $result = @{ ok = $false; reason = $null; detail = $null; pushed = 0; pending = 0 }
    $hist = Get-HistorySyncConfig $Config
    $coord = Get-CoordinationConfig $Config
    if ($hist.enabled -ne $true) { $result.reason = 'disabled'; return $result }
    if ($hist.push -ne $true) { $result.reason = 'push-disabled'; return $result }
    if (-not (Test-GitAvailable)) { $result.reason = 'git-unavailable'; return $result }

    $repoPath = [System.IO.Path]::GetFullPath($coord.repoPath)
    $binding = Test-LogRepoBinding -RepoPath $repoPath -KeeperRoot $KeeperRoot -Branch $hist.branch
    if ($binding) {
        $result.reason = 'repo-binding-failed'; $result.detail = $binding; return $result
    }

    $pending = @(Get-ChildItem -LiteralPath (Get-OutboxDir $KeeperRoot) -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $result.pending = @($pending).Count
    if ($pending.Count -eq 0) { $result.reason = 'nothing-to-sync'; return $result }

    $machineId = [string]$Machine.machineId
    $blobs = @{}
    foreach ($file in $pending) {
        $rec = ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText($file.FullName))
        if ($rec -isnot [hashtable]) { continue }
        $when = [DateTime]::Now
        if ($rec.recordedAt) {
            $parsed = [DateTime]::MinValue
            if ([DateTime]::TryParse([string]$rec.recordedAt, [ref]$parsed)) { $when = $parsed }
        }
        $stamp = $when.ToLocalTime().ToString('yyyyMMddTHHmmss')
        $date = $when.ToLocalTime().ToString('yyyy-MM-dd')
        $remotePath = 'history/' + $date + '/' + $machineId + '/' + $stamp + '_' + $rec.event + '_' + $file.BaseName + '.json'
        $blobs[$remotePath] = [System.IO.File]::ReadAllText($file.FullName)
    }
    foreach ($summaryFile in $SummaryFiles) {
        if (-not (Test-Path -LiteralPath $summaryFile)) { continue }
        $name = [System.IO.Path]::GetFileName($summaryFile)   # summary-YYYY-MM-DD.json
        $date = $name -replace '^summary-', ''
        $date = $date -replace '\.json$', ''
        $blobs['summary/' + $date + '/' + $machineId + '.json'] = [System.IO.File]::ReadAllText($summaryFile)
    }
    if ($blobs.Count -eq 0) { $result.reason = 'nothing-to-sync'; return $result }

    $branch = $hist.branch
    $remote = Get-RemoteBranchBlob -RepoPath $repoPath -Branch $branch -PathInRepo 'history/.keeper'
    if (-not $remote.ok) { $result.reason = 'unreachable'; $result.detail = $remote.detail; return $result }
    $parent = $null
    if ($remote.commit) { $parent = $remote.commit }

    $push = Push-RepoBlobs -RepoPath $repoPath -Branch $branch -Blobs $blobs -ParentCommit $parent `
        -CommitMessage $CommitMessage -MachineId $machineId
    if (-not $push.ok) {
        $result.reason = $push.reason; $result.detail = $push.stderr
        return $result
    }

    # Push succeeded: mark sent and drain the outbox.
    $state = Read-JsonFile (Get-SyncStatePath $KeeperRoot)
    if ($state -isnot [hashtable]) { $state = @{ schema = 1; sent = @(); sentCount = 0 } }
    $state.lastSyncAt = Get-IsoTimestamp
    $state.sentCount = [int]$state.sentCount + $blobs.Count
    $recent = @($state.sent)
    foreach ($file in $pending) {
        $recent += ,@{ id = $file.BaseName; sentAt = $state.lastSyncAt; path = 'outbox/' + $file.Name }
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
    if ($recent.Count -gt 100) { $recent = @($recent | Select-Object -Last 100) }
    $state.sent = $recent
    Write-JsonFileAtomic (Get-SyncStatePath $KeeperRoot) $state

    $result.ok = $true; $result.reason = 'pushed'; $result.pushed = $blobs.Count
    return $result
}

function Sync-HistoryToGitHub {
    # Pushes sanitized event/summary files from local history/ onto the history
    # branch. Failures NEVER propagate: local logs stay and the next run retries.
    # historySync.push=false blocks every history push; coordination.enabled
    # governs the lease branch independently (audit plan §6.2).
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string[]]$FilePaths,
        [string]$CommitMessage,
        [string]$MachineId = ''
    )
    $resultTemplate = @{ ok = $false; reason = $null; detail = $null; pushed = 0 }
    $hist = Get-HistorySyncConfig $Config
    $coord = Get-CoordinationConfig $Config
    if ($hist.enabled -ne $true) {
        $resultTemplate.reason = 'disabled'
        return $resultTemplate
    }
    if ($hist.push -ne $true) {
        $resultTemplate.reason = 'push-disabled'
        return $resultTemplate
    }
    if (-not (Test-GitAvailable)) { $resultTemplate.reason = 'git-unavailable'; return $resultTemplate }

    $repoPath = [System.IO.Path]::GetFullPath($coord.repoPath)
    $issues = Test-LogRepoAllowed -RepoPath $repoPath -KeeperRoot $KeeperRoot
    if ($issues.Count -gt 0) {
        $resultTemplate.reason = 'repo-not-allowed'
        $resultTemplate.detail = ($issues -join '; ')
        return $resultTemplate
    }

    $branch = $hist.branch
    $remote = Get-RemoteBranchBlob -RepoPath $repoPath -Branch $branch -PathInRepo 'history/.keeper'
    if (-not $remote.ok) {
        $resultTemplate.reason = 'unreachable'
        $resultTemplate.detail = $remote.detail
        return $resultTemplate
    }
    if ($remote.reason -eq 'unreachable') {
        $resultTemplate.reason = 'unreachable'
        return $resultTemplate
    }

    $blobs = @{}
    foreach ($file in $FilePaths) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $name = [System.IO.Path]::GetFileName($file)
        $blobs["history/$name"] = [System.IO.File]::ReadAllText($file)
    }
    if ($blobs.Count -eq 0) {
        $resultTemplate.reason = 'nothing-to-sync'
        return $resultTemplate
    }

    $parent = $null
    if ($remote.commit) { $parent = $remote.commit }
    $push = Push-RepoBlobs -RepoPath $repoPath -Branch $branch -Blobs $blobs -ParentCommit $parent -CommitMessage $CommitMessage -MachineId $MachineId
    if ($push.ok) {
        $resultTemplate.ok = $true
        $resultTemplate.reason = 'pushed'
        $resultTemplate.pushed = $blobs.Count
    } else {
        $resultTemplate.reason = $push.reason
        $resultTemplate.detail = $push.stderr
    }
    return $resultTemplate
}
