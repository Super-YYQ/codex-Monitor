# Shared fixtures for the four §17.2 golden Status panels (CQK-030).
#
# Dot-sourced by BOTH tests/golden-update.ps1 (which writes tests/golden/*.txt) and
# tests/status-display.test.ps1 (which compares the live renderer against them). That
# sharing is the point: if the two sides built their own copies of these facts, a
# snapshot failure would no longer prove anything about the renderer - it would just
# mean the two fixture sets drifted apart.
#
# The fixtures are hand-built status/config/state, not a real machine, and they are
# built to render identically on any host, shell version or timezone. Two rules make
# that work; breaking either makes CI (UTC) disagree with a dev box (+08:00):
#   - timestamps are wall-clock strings WITHOUT an offset. ConvertTo-StatusDateTime
#     parses via [DateTime]::TryParse, which treats them as local and prints them back
#     unchanged - an ISO string with +08:00 would instead be shifted to the host zone.
#   - resetsAt is a unix epoch derived from the *host's* local time, because
#     ConvertFrom-EpochSeconds renders it back in that same zone. A baked-in epoch
#     would print a different clock reading per host.

$script:GoldenNow = Get-Date '2026-09-09 12:00:00'

function Get-GoldenNow { return $script:GoldenNow }

function Format-GoldenStamp {
    # Wall-clock string in the shape the collector's ISO timestamps parse to.
    param([datetime]$Value)
    return $Value.ToString('yyyy-MM-dd HH:mm:ss')
}

function Get-GoldenEpoch {
    # Unix seconds such that ConvertFrom-EpochSeconds renders back exactly $Value.
    param([datetime]$Value)
    return ([DateTimeOffset]::new($Value)).ToUnixTimeSeconds()
}

function Merge-StatusOver {
    # One level of hashtable merge is enough: cases override whole sections.
    param([hashtable]$Base, [hashtable]$Over)
    $out = @{}
    foreach ($k in $Base.Keys) { $out[$k] = $Base[$k] }
    foreach ($k in $Over.Keys) { $out[$k] = $Over[$k] }
    return $out
}

function New-GoldenStatus {
    param([hashtable]$Over = @{}, [switch]$LocalOnly)
    $now = $script:GoldenNow
    $base = @{
        configOk            = $true
        mode                = 'MonitorOnly'
        autoAnchor          = $false
        pollIntervalMinutes = 60
        machineLabel        = 'Home PC'
        machineId           = '4f90abcd-1234'
        anchorKeepalive     = @{ intervalMinutes = 300; lastAnchorAt = $null }
        anchorSchedule      = @{ slots = @() }
        anchorExec          = @{ model = ''; reasoningEffort = '' }
        task                = @{
            installed             = $true; enabled = $true
            lastRunTime           = (Format-GoldenStamp $now); lastResult = 0
            nextRunTime           = (Format-GoldenStamp $now.AddMinutes(38)); intervalMinutes = 60
            intervalMatchesConfig = $true
        }
        codex               = @{ found = $true; path = 'C:\Users\x\codex.cmd'; liveOk = $null; liveError = $null }
        process             = @{ runnerRunningNow = $false; pid = $null }
        role                = @{
            role = 'LEADER'; leaderOwner = 'machine-a'; leaderLabel = $null
            leaseExpiresAt = (Format-GoldenStamp $now.AddMinutes(120)); localOnly = $false
        }
        quota               = @{ lastReadAt = (Format-GoldenStamp $now.AddMinutes(-5)); stale = $false; windows = @() }
        lastError           = $null
        git                 = @{ enabled = $true; repoPath = 'R:\repo'; reachable = $true }
    }
    if ($LocalOnly) {
        $base.role = @{ role = 'LEADER'; leaderOwner = 'machine-a'; leaderLabel = $null; leaseExpiresAt = $null; localOnly = $true }
        $base.git  = @{ enabled = $false; repoPath = ''; reachable = $true }
    }
    return (Merge-StatusOver $base $Over)
}

function New-GoldenConfig {
    param([bool]$Coordination = $true, [bool]$AutoAnchor = $false, [int]$Poll = 60,
        [int]$LeaseTtl = 180, [int]$Grace = 5, [string[]]$Schedule = @(), [int]$Keepalive = 300)
    $now = $script:GoldenNow
    return @{
        schemaVersion = 2
        mode          = $(if ($AutoAnchor) { 'AutoAnchor' } else { 'MonitorOnly' })
        poll          = @{ intervalMinutes = $Poll; minimumIntervalMinutes = 5 }
        leader        = @{ enabled = $true; leaseTtlMinutes = $LeaseTtl; graceMinutes = $Grace; takeoverOnExpiry = $true; label = 'Home PC' }
        github        = @{
            coordination = @{ enabled = $Coordination; repoPath = $(if ($Coordination) { 'R:\repo' } else { '' }); branch = 'cqk/coordination' }
            historySync  = @{ enabled = $false; push = $false; branch = 'cqk/history'; eventsOnly = $true }
        }
        codex         = @{
            command = 'auto'; queryTimeoutSeconds = 20; proxy = ''
            autoAnchor = @{
                enabled = $AutoAnchor; prompt = 'OK'; maxPerDay = 6; minimumGapMinutes = 300
                keepaliveIntervalMinutes = $Keepalive; schedule = $Schedule
            }
        }
        logging       = @{ retentionDays = 90; includeMachineLabel = $false }
        task          = @{ name = 'CodexQuotaKeeper.Check'; startWithWindows = $true; runIfNetworkAvailable = $true; wakeToRun = $false }
    }
}

function Get-GoldenFreshQuota {
    # 5h + weekly, both usable, both with a known reset - §20's "已使用/剩余/重置时间
    # together" case. The numbers are the design doc's own sample values.
    $now = $script:GoldenNow
    return @{
        lastReadAt = (Format-GoldenStamp $now.AddMinutes(-5)); stale = $false
        windows    = @(
            @{ bucketId = 'default'; minutes = 300;   usedPercent = 12; resetsAt = (Get-GoldenEpoch $now.AddHours(6));     usable = $true },
            @{ bucketId = 'default'; minutes = 10080; usedPercent = 37; resetsAt = (Get-GoldenEpoch $now.AddDays(4).Date.AddHours(12)); usable = $true }
        )
    }
}

function Get-GoldenCases {
    # §17.2's four scenarios, in snapshot-name order. Each is the whole input to one
    # panel: Status facts, Config, and optionally the runtime anchors state.
    $now = $script:GoldenNow
    $freshQuota = Get-GoldenFreshQuota
    return [ordered]@{
        # case 1 - single machine, everything fine, AutoAnchor off.
        'monitor-only-healthy' = @{
            Status = (New-GoldenStatus @{ quota = $freshQuota } -LocalOnly)
            Config = (New-GoldenConfig -Coordination $false)
        }
        # case 2 - judgment mode: trigger list, gap, keepalive, cap, CLI defaults.
        # The state fixture agrees with status.anchorKeepalive.lastAnchorAt (on a real
        # machine both come from that same file) - 2h < minimumGapMinutes 300, so this
        # is also the snapshot that pins ANCHOR_GAP_COOLDOWN: the 当前锚定 row rendered
        # as INFO, which unlike ERROR/WARNING carries no 建议 continuation.
        'aa-judgment' = @{
            Status  = (New-GoldenStatus @{
                autoAnchor      = $true; mode = 'AutoAnchor'
                anchorKeepalive = @{ intervalMinutes = 300; lastAnchorAt = (Format-GoldenStamp $now.AddHours(-2)) }
                quota           = $freshQuota
            } -LocalOnly)
            Config  = (New-GoldenConfig -Coordination $false -AutoAnchor $true)
            Anchors = @{ day = $now.ToString('yyyy-MM-dd'); count = 1; lastAnchorAt = (Format-GoldenStamp $now.AddHours(-2)) }
        }
        # case 3 - schedule mode: slots + next slot, periodic judgment explicitly
        # off, both exec overrides set, and a runtime state showing 2 anchors today.
        'aa-schedule' = @{
            Status  = (New-GoldenStatus @{
                autoAnchor     = $true; mode = 'AutoAnchor'
                anchorSchedule = @{ slots = @('09:30', '21:00') }
                anchorExec     = @{ model = 'gpt-5-codex'; reasoningEffort = 'low' }
                quota          = $freshQuota
            } -LocalOnly)
            Config  = (New-GoldenConfig -Coordination $false -AutoAnchor $true -Schedule @('09:30', '21:00'))
            Anchors = @{ day = $now.ToString('yyyy-MM-dd'); count = 2; lastAnchorAt = (Format-GoldenStamp $now.AddHours(-1)) }
        }
        # case 4 - multi-PC with an unreachable coordination repo: ERROR findings,
        # fail-closed anchor, stale quota, and a lastError holding a fake token so the
        # snapshot pins §18 sanitisation end to end.
        'multi-pc-error' = @{
            Status = (New-GoldenStatus @{
                autoAnchor = $true; mode = 'AutoAnchor'
                git        = @{ enabled = $true; repoPath = 'R:\repo'; reachable = $false }
                role       = @{ role = 'UNKNOWN'; leaderOwner = $null; leaderLabel = $null; leaseExpiresAt = $null; localOnly = $false }
                quota      = @{ lastReadAt = (Format-GoldenStamp $now.AddDays(-2)); stale = $true; windows = @() }
                lastError  = 'auth failed for user bob: token=sk-fake-0123456789abcdef'
            })
            Config = (New-GoldenConfig -AutoAnchor $true -LeaseTtl 30)
        }
    }
}

function Get-GoldenCaseText {
    # Renders one §17.2 case to panel text. Shared by golden-update.ps1 (writes the
    # snapshot) and status-display.test.ps1 (compares against it), so a snapshot can
    # only ever disagree with the renderer - never with a second copy of the setup.
    #
    # Callers must have dot-sourced test-helper.ps1 plus common/state-machine/
    # status-assessment/status-display first; this file deliberately loads nothing.
    #
    # The KeeperRoot is a fresh temp dir the caller owns: a real Load-KeeperState /
    # Get-BackoffState run against "no state yet" is part of what case 1 and 4 pin.
    param([hashtable]$Case, [string]$KeeperRoot, [datetime]$Now)
    $av = Get-StatusAssessment -Status $Case.Status -Config $Case.Config -KeeperRoot $KeeperRoot -Now $Now
    return Get-StatusPanelText -Status $Case.Status -Assessment $av -Config $Case.Config -KeeperRoot $KeeperRoot -Now $Now
}

function Install-GoldenCaseState {
    # Materialises a case's -Anchors fixture into <KeeperRoot>\runtime\state.json,
    # which is the only way the panel's 今日已执行 row can be non-zero.
    param([hashtable]$Case, [string]$KeeperRoot)
    if (-not $Case.ContainsKey('Anchors')) { return }
    $state = New-KeeperState
    $state.anchors = $Case.Anchors
    $state.lastReadAt = $Case.Status.quota.lastReadAt
    Write-JsonFileAtomic (Get-StatePath $KeeperRoot) $state
}
