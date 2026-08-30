# Codex Quota Keeper - preflight checks before any keeper work happens.
# Fast local checks only; the quota probe is a separate read-only call the
# installer and status --live use explicitly.

$script:CqkPreflightDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkPreflightDir 'common.ps1')
}
if (-not (Get-Command Test-LogRepoAllowed -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkPreflightDir 'github-sync.ps1')
}
if (-not (Get-Command Invoke-CodexRateLimitsRead -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkPreflightDir 'quota-client.ps1')
}

function Invoke-Preflight {
    # Returns @{ ok; issues; codexPath; gitOk; logRepoIssues; machine }
    param(
        [hashtable]$Config,
        [string]$ConfigPath = $null,
        [string]$KeeperRoot = $null,
        [bool]$ProbeCodex = $false
    )
    $issues = @()
    if (-not $KeeperRoot) { $KeeperRoot = Get-KeeperRoot }

    if ($null -eq $Config) {
        if (-not $ConfigPath) { $ConfigPath = Get-ConfigPath $KeeperRoot }
        $loaded = Load-Config $ConfigPath
        if ($null -eq $loaded.config) {
            return @{ ok = $false; issues = $loaded.issues; codexPath = $null; gitOk = $false; logRepoIssues = @(); machine = $null }
        }
        $Config = $loaded.config
        $issues += $loaded.issues
    }

    $codexPath = Resolve-CodexCommand $Config
    if (-not $codexPath) {
        $issues += 'codex executable not found; install Codex CLI/Desktop or set codex.command'
    }

    $gitOk = $false
    $logRepoIssues = @()
    $coord = Get-CoordinationConfig $Config
    $hist = Get-HistorySyncConfig $Config
    if ($coord.enabled -eq $true -or $hist.enabled -eq $true) {
        $gitOk = Test-GitAvailable
        if (-not $gitOk) { $issues += 'git is required for GitHub coordination but was not found' }
        else {
            if ($coord.enabled -eq $true) {
                $logRepoIssues = Test-LogRepoAllowed -RepoPath $coord.repoPath -KeeperRoot $KeeperRoot
                $issues += $logRepoIssues
            }
        }
    }

    # Runtime must be creatable (locked-down dirs should fail loudly here).
    try {
        Ensure-Directory (Get-RuntimeDir $KeeperRoot) | Out-Null
        Ensure-Directory (Get-LogsDir $KeeperRoot) | Out-Null
        Ensure-Directory (Get-LockDir $KeeperRoot) | Out-Null
    } catch {
        $issues += "runtime directory not writable: $($_.Exception.Message)"
    }

    $machine = $null
    try {
        $machine = Get-MachineIdentity -Root $KeeperRoot -Label ([string]$Config.leader.label)
    } catch {
        $issues += "machine identity not available: $($_.Exception.Message)"
    }

    $probe = $null
    if ($ProbeCodex -and $codexPath) {
        # Read-only connectivity check; never calls the model.
        $probe = Invoke-CodexRateLimitsRead -Config $Config -CodexPath $codexPath
        if (-not $probe.ok) {
            $issues += "quota probe failed ($($probe.errorKind)): $($probe.message)"
        }
    }

    return @{
        ok            = ($issues.Count -eq 0)
        issues        = $issues
        codexPath     = $codexPath
        gitOk         = $gitOk
        logRepoIssues = $logRepoIssues
        machine       = $machine
        probe         = $probe
    }
}
