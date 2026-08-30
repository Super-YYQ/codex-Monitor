# Codex Quota Keeper - status (doc 02 §4 / doc 03 §13).
# READ-ONLY: never claims the lease, never starts the keeper, never pushes.
# Get-KeeperStatus collects the data; Write-StatusText renders the human view;
# status-json.ps1 renders the machine view. -Live adds a read-only auth probe.

param(
    [string]$KeeperRoot = '',
    [string]$ConfigFile = '',
    [switch]$Live
)

$script:CqkStatusDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkStatusDir 'common.ps1')
}
if (-not (Get-Command Get-RecentErrors -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkStatusDir 'logger.ps1')
}
if (-not (Get-Command Get-RemoteLease -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkStatusDir 'leader-lease.ps1')
}
if (-not (Get-Command Invoke-CodexRateLimitsRead -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkStatusDir 'quota-client.ps1')
}
if (-not (Get-Command Load-KeeperState -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkStatusDir 'state-machine.ps1')
}

function Get-TaskIntervalMinutes {
    # Accepts either a ScheduledTask or a single trigger object.
    param($Task)
    if (-not $Task) { return $null }
    # Where-Object filters a missing .Triggers (single-trigger mode): @($null) has Count 1.
    $triggers = @($Task.Triggers | Where-Object { $_ })
    if ($triggers.Count -eq 0 -and $Task.Repetition) { $triggers = @($Task) }
    foreach ($t in $triggers) {
        $rep = $t.Repetition
        if ($null -eq $rep) { continue }
        $interval = $rep.Interval
        if ($null -eq $interval) { continue }
        if ($interval -is [TimeSpan]) { return [int]$interval.TotalMinutes }
        # CIM string form like 'PT15M' / 'PT1H'
        if ("$interval" -match 'PT(?<v>\d+)(?<u>[MH])') {
            $v = [int]$Matches.v
            return $(if ($Matches.u -eq 'H') { $v * 60 } else { $v })
        }
    }
    return $null
}

function Get-KeeperStatus {
    param(
        [string]$KeeperRoot = '',
        [string]$ConfigFile = '',
        [switch]$Live
    )
    if (-not $KeeperRoot) { $KeeperRoot = Get-KeeperRoot }
    if (-not $ConfigFile) { $ConfigFile = Get-ConfigPath $KeeperRoot }

    $status = @{
        timestamp = (Get-IsoTimestamp)
        configOk  = $false
        mode      = $null
        autoAnchor = $false
        pollIntervalMinutes = $null
        machineId = $null
        machineLabel = $null
        task      = @{ installed = $false; enabled = $false; lastRunTime = $null; lastResult = $null; nextRunTime = $null; intervalMinutes = $null; intervalMatchesConfig = $null }
        codex     = @{ found = $false; path = $null; liveOk = $null; liveError = $null }
        process   = @{ runnerRunningNow = $false; pid = $null }
        role      = @{ role = 'UNKNOWN'; leaderOwner = $null; leaderLabel = $null; leaseExpiresAt = $null; localOnly = $false }
        quota     = @{ lastReadAt = $null; stale = $false; windows = @() }
        lastError = $null
        git       = @{ enabled = $false; repoPath = $null; reachable = $null }
    }

    $loaded = Load-Config $ConfigFile
    if ($null -eq $loaded.config) {
        $status.lastError = ($loaded.issues -join '; ')
        return $status
    }
    $cfg = $loaded.config
    $status.configOk = (@($loaded.issues).Count -eq 0)
    $status.mode = [string]$cfg.mode
    $status.autoAnchor = [bool]($cfg.codex.autoAnchor -eq $true)
    $status.pollIntervalMinutes = (Get-PollConfig $cfg).intervalMinutes

    $machine = Get-MachineIdentity -Root $KeeperRoot -Label ([string]$cfg.leader.label)
    $status.machineId = [string]$machine.machineId
    $status.machineLabel = [string]$machine.label

    # ---- Scheduled Task (read-only) ------------------------------------------
    $taskName = [string]$cfg.task.name
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        $status.task.installed = $true
        $status.task.enabled = ($task.State -ne 'Disabled')
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        if ($info) {
            $status.task.lastRunTime = $info.LastRunTime
            $status.task.lastResult = $info.LastTaskResult
            $status.task.nextRunTime = $info.NextRunTime
        }
        $status.task.intervalMinutes = Get-TaskIntervalMinutes $task
        if ($null -ne $status.task.intervalMinutes) {
            $status.task.intervalMatchesConfig = ($status.task.intervalMinutes -eq $status.pollIntervalMinutes)
        }
    }

    # ---- codex availability ---------------------------------------------------
    $codexPath = Resolve-CodexCommand $cfg
    if ($codexPath) { $status.codex.found = $true; $status.codex.path = $codexPath }
    if ($Live -and $codexPath) {
        $probe = Invoke-CodexRateLimitsRead -Config $cfg -CodexPath $codexPath
        $status.codex.liveOk = [bool]$probe.ok
        if (-not $probe.ok) { $status.codex.liveError = $probe.message }
    }

    # ---- local runner process (right now) --------------------------------------
    $lockPath = Join-Path (Get-LockDir $KeeperRoot) 'runner.lock'
    if (Test-Path -LiteralPath $lockPath) {
        $lock = Read-JsonFile $lockPath
        if ($lock -and $lock.pid) {
            try {
                $null = Get-Process -Id ([int]$lock.pid) -ErrorAction Stop
                $status.process.runnerRunningNow = $true
                $status.process.pid = [int]$lock.pid
            } catch { }
        }
    }

    # ---- role + lease ----------------------------------------------------------
    $state = Load-KeeperState $KeeperRoot
    $coord = Get-CoordinationConfig $cfg
    if ($coord.enabled -ne $true) {
        $status.role.role = $(if ($state.role) { $state.role } else { 'LEADER' })
        $status.role.localOnly = $true
    } else {
        $lease = Get-RemoteLease -Config $cfg -KeeperRoot $KeeperRoot
        if ($lease.reachable -and $lease.lease -and (Test-LeaseActive -Lease $lease.lease -Now (Get-Date) -GraceMinutes ([int]$cfg.leader.graceMinutes))) {
            $status.role.leaderOwner = [string]$lease.lease.ownerId
            $status.role.leaderLabel = [string]$lease.lease.ownerLabel
            $status.role.leaseExpiresAt = ConvertTo-IsoString $lease.lease.expiresAt
            if ([string]$lease.lease.ownerId -eq $status.machineId) {
                $status.role.role = 'LEADER'
            } else {
                $status.role.role = 'PASSIVE'
            }
        } else {
            $status.role.role = $(if ($state.role) { $state.role } else { 'UNKNOWN' })
        }
        $hist = Get-HistorySyncConfig $cfg
        $status.git.enabled = ($coord.enabled -or $hist.enabled)
        $status.git.repoPath = $coord.repoPath
        $reach = Test-RemoteReachable -RepoPath ([System.IO.Path]::GetFullPath($coord.repoPath))
        $status.git.reachable = [bool]$reach.ok
    }

    # ---- last quota + last error ------------------------------------------------
    $status.quota.lastReadAt = $state.lastReadAt
    $status.quota.stale = [bool]$state.stale
    # flatten buckets for display; only usable windows with a known reset time
    $flat = Get-FlattenedQuotaWindows (ConvertTo-StateBuckets $state)
    $status.quota.windows = @($flat | Where-Object { $_.usable -and $null -ne $_.resetsAt })
    $recent = Get-RecentErrors -Root $KeeperRoot -Take 1
    if ($recent.Count -gt 0) {
        $status.lastError = "$($recent[0].event): $($recent[0].error)"
    }
    return $status
}
function Write-StatusText {
    param([hashtable]$Status)
    $y = 'YES'; $n = 'NO'
    $lines = @()
    $lines += 'Codex Quota Keeper Status'
    $lines += '============================================================'
    $lines += ('Local machine       : {0} [{1}]' -f $Status.machineLabel, $Status.machineId)
    $lines += ('Task installed      : {0}' -f $(if ($Status.task.installed) { $y } else { $n }))
    if ($Status.task.installed) {
        $lines += ('Task enabled        : {0}' -f $(if ($Status.task.enabled) { $y } else { $n }))
        if ($Status.task.lastRunTime) {
            $ok = ($Status.task.lastResult -eq 0)
            $lines += ('Last task run       : {0}  ({1})' -f ([DateTime]$Status.task.lastRunTime).ToString('yyyy-MM-dd HH:mm:ss'), $(if ($ok) { 'Success' } else { "Code $($Status.task.lastResult)" }))
        }
        if ($Status.task.nextRunTime) {
            $lines += ('Next task run       : {0}' -f ([DateTime]$Status.task.nextRunTime).ToString('yyyy-MM-dd HH:mm:ss'))
        }
        $matchText = 'n/a'
        if ($null -ne $Status.task.intervalMatchesConfig) {
            $matchText = $(if ($Status.task.intervalMatchesConfig) { 'matches config' } else { 'MISMATCH - run apply-config' })
        }
        $lines += ('Polling interval    : {0} min ({1})' -f $Status.pollIntervalMinutes, $matchText)
    }
    $lines += ('Codex CLI/app-server: {0}' -f $(if ($Status.codex.found) { 'READY' } else { 'NOT FOUND - set codex.command' }))
    if ($null -ne $Status.codex.liveOk) {
        $lines += ('Auth (live probe)   : {0}' -f $(if ($Status.codex.liveOk) { 'OK (read-only)' } else { "FAILED - $($Status.codex.liveError)" }))
    }
    $lines += ('Mode                : {0}' -f $Status.mode)
    if ($Status.autoAnchor) {
        $lines += 'AutoAnchor          : *** ON - EXPERIMENTAL, consumes quota ***'
    } else {
        $lines += 'AutoAnchor          : OFF (experimental feature)'
    }
    $lines += ''
    if ($Status.role.localOnly) {
        $lines += 'Distributed leader  : none - LOCAL-ONLY MODE (MULTI-PC UNSAFE)'
    } else {
        $leader = $(if ($Status.role.leaderOwner) { '{0} [{1}]' -f $Status.role.leaderLabel, $Status.role.leaderOwner } else { 'unknown' })
        $lines += ('Distributed leader  : {0}' -f $leader)
        if ($Status.role.leaseExpiresAt) { $lines += ('Lease expires       : {0}' -f $Status.role.leaseExpiresAt) }
    }
    $lines += ('This machine role   : {0}' -f $Status.role.role)
    if ($Status.process.runnerRunningNow) {
        $lines += ('Runner process      : RUNNING NOW (pid {0})' -f $Status.process.pid)
    }
    $lines += ''
    if ($Status.quota.lastReadAt) {
        $staleMark = $(if ($Status.quota.stale) { ' (STALE)' } else { '' })
        $lines += ('Last quota read     : {0}{1}' -f $Status.quota.lastReadAt, $staleMark)
        foreach ($w in $Status.quota.windows) {
            $reset = ConvertFrom-EpochSeconds ([long]$w.resetsAt)
            $bucketTag = if ($w.bucketId -and $w.bucketId -ne 'default') { " [$($w.bucketId)]" } else { '' }
            $lines += ('{0,2}h window{1}     : {2}% used, reset {3}' -f ([int]($w.minutes / 60)), $bucketTag, [int]$w.usedPercent, $reset.ToString('yyyy-MM-dd HH:mm'))
        }
    } else {
        $lines += 'Last quota read     : never (runner has not completed a poll yet)'
    }
    $lines += ('Last error          : {0}' -f $(if ($Status.lastError) { $Status.lastError } else { 'none' }))
    if ($Status.git.enabled) {
        $lines += ('Log repo reachable  : {0}' -f $(if ($Status.git.reachable) { 'YES' } elseif ($null -eq $Status.git.reachable) { 'UNKNOWN' } else { 'NO' }))
    }
    $lines += '============================================================'
    return ($lines -join [Environment]::NewLine)
}

if ($MyInvocation.InvocationName -ne '.') {
    $s = Get-KeeperStatus -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile -Live:$Live
    Write-Host (Write-StatusText $s)
    exit 0
}
