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
        $r = Invoke-Git -RepoPath $RepoPath -ArgumentList @('read-tree', '--empty') -TimeoutSeconds 15 -Environment $envs
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

function Sync-HistoryToGitHub {
    # Pushes sanitized event/summary files from local history/ onto the history
    # branch. Failures NEVER propagate: local logs stay and the next run retries.
    param(
        [hashtable]$Config,
        [string]$KeeperRoot,
        [string[]]$FilePaths,
        [string]$CommitMessage,
        [string]$MachineId = ''
    )
    $resultTemplate = @{ ok = $false; reason = $null; detail = $null; pushed = 0 }
    if ($Config.github.enabled -ne $true) {
        $resultTemplate.reason = 'disabled'
        return $resultTemplate
    }
    if (-not (Test-GitAvailable)) { $resultTemplate.reason = 'git-unavailable'; return $resultTemplate }

    $repoPath = [System.IO.Path]::GetFullPath([string]$Config.github.repoPath)
    $issues = Test-LogRepoAllowed -RepoPath $repoPath -KeeperRoot $KeeperRoot
    if ($issues.Count -gt 0) {
        $resultTemplate.reason = 'repo-not-allowed'
        $resultTemplate.detail = ($issues -join '; ')
        return $resultTemplate
    }

    $branch = [string]$Config.github.historyBranch
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
