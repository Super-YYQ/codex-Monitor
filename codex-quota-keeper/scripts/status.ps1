# Codex Quota Keeper - status (doc 02 §4 / doc 03 §13, design v2.0 §11/§14).
# READ-ONLY: never claims the lease, never starts the keeper, never pushes.
# Get-KeeperStatus collects the data; the display layer renders it. -Live adds a
# read-only auth probe. Default output is the Chinese panel (§11); -Language en-US
# gives the pre-v2.0 fact dump that status-json.ps1 adjacent tooling may expect.

param(
    [string]$KeeperRoot = '',
    [string]$ConfigFile = '',
    [switch]$Live,
    [ValidateSet('zh-CN', 'en-US')] [string]$Language = 'zh-CN',
    [switch]$NoColor,
    [switch]$Detailed
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
if (-not (Get-Command Get-StatusDisplayLines -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkStatusDir 'status-display.ps1')
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
        anchorKeepalive = @{ intervalMinutes = $null; lastAnchorAt = $null }
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
    $status.autoAnchor = Test-AutoAnchorEnabled $cfg
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
    $aaCfg = Get-AutoAnchorConfig $cfg
    $status.anchorKeepalive = @{ intervalMinutes = [int]$aaCfg.keepaliveIntervalMinutes; lastAnchorAt = [string]$state.anchors.lastAnchorAt }
    $status.anchorSchedule = @{ slots = @($aaCfg.schedule) }
    $status.anchorExec = @{ model = [string]$aaCfg.model; reasoningEffort = [string]$aaCfg.reasoningEffort }
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
    # Compatibility shim: the pre-v2.0 English fact dump, whose implementation now
    # lives in the display layer (Write-StatusTextEn) so the -Language en-US panel
    # and this function cannot drift. Tests and external callers still use this
    # name, and the [hashtable] signature stays as the documented contract.
    param([hashtable]$Status)
    return (Write-StatusTextEn -Status $Status)
}

if ($MyInvocation.InvocationName -ne '.') {
    # §14: status.cmd's default view is the Chinese panel. The collector and the
    # assessment are both built from $Status alone, so -Live stays the only thing
    # that touches the network beyond the read-only local queries.
    $s = Get-KeeperStatus -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile -Live:$Live
    $av = Get-StatusAssessment -Status $s -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile
    $panel = Get-StatusDisplayLines -Status $s -Assessment $av -Language $Language -Detailed:$Detailed `
        -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile
    Write-StatusConsole $panel -NoColor:$NoColor
    exit 0
}
