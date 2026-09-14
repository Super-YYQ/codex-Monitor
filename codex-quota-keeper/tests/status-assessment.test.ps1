# Tests for the Status assessment layer (design doc v2.0 §9.2/§10/§16) - CQK-025.
#
# The fact layer (Get-KeeperStatus) is mocked, not executed: the assessment is
# defined purely by the status object + config + runtime/ state, so driving it
# with hand-built facts is what actually tests §10's rule table. Everything that
# *is* real here matters: Load-KeeperState, Get-BackoffState, Load-Config,
# Hide-SensitiveText and the dotted-path reads all run for real.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'state-machine.ps1')
. (Join-Path $scriptDir 'status-assessment.ps1')

# Fixed clock: every age/threshold rule must be deterministic.
$Now = Get-Date '2026-09-09 12:00:00'
$Today = '2026-09-09'

# ---- fixture builders ------------------------------------------------------
# Deep merge, unlike New-TestConfig's two levels: test cases read as small
# diffs against the healthy baseline instead of restating whole sections.
function Merge-Deep {
    param([hashtable]$Base, [hashtable]$Over)
    $out = @{}
    foreach ($k in $Base.Keys) { $out[$k] = $Base[$k] }
    foreach ($k in $Over.Keys) {
        if ($out[$k] -is [hashtable] -and $Over[$k] -is [hashtable]) { $out[$k] = (Merge-Deep $out[$k] $Over[$k]) }
        else { $out[$k] = $Over[$k] }
    }
    return $out
}

# Healthy multi-machine baseline. -LocalOnly flips the single-machine variant.
function New-StubStatus {
    param([hashtable]$Over = @{}, [switch]$LocalOnly)
    $base = @{
        configOk            = $true
        mode                = 'MonitorOnly'
        autoAnchor          = $false
        pollIntervalMinutes = 60
        anchorExpiry        = @{ windows = @(); installed = $false; nextRunTime = $null; lastAnchorAt = $null }
        anchorSchedule      = @{ slots = @() }
        task                = @{
            installed           = $true; enabled = $true
            lastRunTime         = $Now; lastResult = 0
            nextRunTime         = $Now.AddMinutes(38); intervalMinutes = 60
            intervalMatchesConfig = $true
        }
        codex               = @{ found = $true; path = 'codex'; liveOk = $null; liveError = $null }
        process             = @{ runnerRunningNow = $false; pid = $null }
        role                = @{
            role = 'LEADER'; leaderOwner = 'machine-a'; leaderLabel = $null
            leaseExpiresAt = (ConvertTo-IsoString $Now.AddMinutes(120)); localOnly = $false
        }
        quota               = @{ lastReadAt = (ConvertTo-IsoString $Now.AddMinutes(-22)); stale = $false; windows = @() }
        lastError           = $null
        git                 = @{ enabled = $true; repoPath = 'R:\repo'; reachable = $true }
    }
    if ($LocalOnly) {
        $base.role = @{ role = 'LEADER'; leaderOwner = 'machine-a'; leaderLabel = $null; leaseExpiresAt = $null; localOnly = $true }
        $base.git = @{ enabled = $false; repoPath = ''; reachable = $true }
    }
    return (Merge-Deep $base $Over)
}

function New-StubConfig {
    param([bool]$Coordination = $true, [bool]$AutoAnchor = $false, [int]$Poll = 60,
        [int]$LeaseTtl = 180, [int]$Grace = 5, [string[]]$Schedule = @(), [string[]]$AnchorOnExpiry = @())
    return New-TestConfig @{
        mode   = $(if ($AutoAnchor) { 'AutoAnchor' } else { 'MonitorOnly' })
        poll   = @{ intervalMinutes = $Poll }
        leader = @{ enabled = $true; leaseTtlMinutes = $LeaseTtl; graceMinutes = $Grace }
        github = @{
            coordination = @{ enabled = $Coordination; repoPath = $(if ($Coordination) { 'R:\repo' } else { '' }) }
            historySync  = @{ enabled = $false }
        }
        codex  = @{ autoAnchor = @{
            enabled = $AutoAnchor; maxPerDay = 6; minimumGapMinutes = 300
            anchorOnExpiry = $AnchorOnExpiry; schedule = $Schedule
        } }
    }
}

# Codes are the stable contract (§9.2 keeps them English), so nearly every
# assertion is on codes - titles are checked separately for language + shape.
function Get-CodeSet {
    param($Assessment)
    return @(@($Assessment.findings) | ForEach-Object { [string]$_.code })
}
function Test-HasCode { param($Assessment, [string]$Code) return (Get-CodeSet $Assessment) -contains $Code }
function Get-CodeSeverity {
    param($Assessment, [string]$Code)
    foreach ($f in @($Assessment.findings)) { if ([string]$f.code -eq $Code) { return [string]$f.severity } }
    return $null
}
function Get-CodeFinding {
    param($Assessment, [string]$Code)
    foreach ($f in @($Assessment.findings)) { if ([string]$f.code -eq $Code) { return $f } }
    return $null
}
function Write-VerdictLog {
    # One-line JSONL the way logger.ps1 writes it, so Read-StatusLogTail's
    # day-file discovery and newest-first scan are both exercised for real.
    # ConvertTo-IsoString carries the *machine's* offset (not a baked-in +08:00),
    # so the relative ages below hold on any timezone.
    param([string]$Root, [datetime]$Ts, [string]$Level, [string]$Event, [string]$MachineId = 'machine-a', [string]$ErrorText = $null)
    $line = '{"ts":"' + (ConvertTo-IsoString $Ts) + '","level":"' + $Level + '","event":"' + $Event + '","machineId":"' + $MachineId + '"'
    if ($null -ne $ErrorText) { $line += ',"error":"' + $ErrorText + '"' }
    $line += '}'
    $path = Join-Path (Get-LogsDir $Root) ('keeper-' + $Ts.ToString('yyyy-MM-dd') + '.jsonl')
    Add-Content -LiteralPath $path -Value $line -Encoding UTF8
}

# Empty runtime dir: the load-state / load-backoff default paths are part of
# every assertion, not something a fixture file can hide.
$emptyWs = New-TestWorkspace
$emptyRoot = Join-Path $emptyWs 'keeper'
New-Item -ItemType Directory -Force -Path (Join-Path $emptyRoot 'runtime\logs') | Out-Null

try {
    # =====================================================================
    Start-TestGroup 'catalog contract (code / severity / language / placeholders)'

    $allCodes = @(
        'CONFIG_INVALID', 'TASK_NOT_INSTALLED', 'TASK_DISABLED', 'CODEX_NOT_FOUND',
        'COORDINATION_UNREACHABLE', 'ANCHOR_CAP_REACHED', 'AUTOANCHOR_BLOCKED',
        'TASK_LAST_RESULT', 'TASK_LAST_RESULT_PERSISTENT', 'TASK_INTERVAL_MISMATCH',
        'QUOTA_NEVER_READ', 'QUOTA_STALE', 'QUOTA_TOO_OLD', 'QUOTA_READ_FAILED',
        'AUTH_PROBE_FAILED', 'LEASE_TTL_TOO_SHORT', 'LEASE_TTL_LOW_MARGIN', 'BACKOFF_ACTIVE',
        'ROLE_UNKNOWN', 'LAST_ERROR_RECENT', 'GIT_UNREACHABLE',
        'LOCAL_ONLY', 'AUTOANCHOR_ENABLED', 'AUTOANCHOR_OFF', 'ANCHOR_TRIGGERS_OFF',
        'BACKOFF_ACTIVE_SINGLE', 'ROLE_PASSIVE', 'RUNNER_RUNNING',
        'LIVE_PROBE_OK', 'NEXT_RUN_DELAYED', 'ANCHOR_GAP_COOLDOWN', 'TASK_TIME_LIMIT_TIGHT'
    )
    foreach ($code in $allCodes) {
        $cat = Get-StatusFindingCatalog $code
        Assert-True ($null -ne $cat) "catalog entry exists: $code"
        $sev = "$($cat.severity)"
        Assert-True (@('ERROR', 'WARNING', 'INFO') -contains $sev) "severity valid for ${code}: $sev"
        Assert-True ("$($cat.title)" -match '[一-鿿]') "title is Chinese: $code"
        Assert-True ("$($cat.titleEn)" -notmatch '[一-鿿]') "titleEn is English: $code"
        Assert-True ("$($cat.action)" -match '[一-鿿]') "action is Chinese: $code"
        Assert-True ("$($cat.actionEn)" -notmatch '[一-鿿]') "actionEn is English: $code"
        foreach ($field in @('title', 'titleEn', 'action', 'actionEn')) {
            # A single placeholder is allowed (the {0}-style rows); two is a
            # formatter that can never be filled correctly.
            Assert-True (([regex]::Matches("$($cat.$field)", '\{0\}')).Count -le 1) "at most one {0} in ${code}.${field}"
        }
    }
    # The unknown-code fallback must never throw or silently drop a diagnostic.
    $unkAssess = New-StatusAssessment
    Add-StatusFinding -Assessment $unkAssess -Code 'NO_SUCH_CODE' -Now $Now
    $unk = @($unkAssess.findings)[0]
    Assert-Equal 'WARNING' "$($unk.severity)" 'unknown code defaults to WARNING'
    Assert-True ("$($unk.title)" -match 'NO_SUCH_CODE') 'unknown code is named in the title'

    # =====================================================================
    Start-TestGroup '§10.1 overall computation and summary wording'

    foreach ($case in @(
            @{ e = @('INFO', 'INFO'); o = 'HEALTHY'; s = '运行正常' },
            @{ e = @(); o = 'HEALTHY'; s = '运行正常' },
            @{ e = @('INFO', 'WARNING', 'INFO'); o = 'WARNING'; s = '存在需要注意的配置' },
            @{ e = @('WARNING', 'ERROR'); o = 'ERROR'; s = '运行异常' },
            @{ e = @('ERROR'); o = 'ERROR'; s = '运行异常' })) {
        $a = New-StatusAssessment
        $a.findings = @($case.e | ForEach-Object { @{ severity = $_ } })
        # Get-StatusOverall is a pure computation; Set-StatusSummary is the only
        # thing that writes the verdict into the assessment (§10.1).
        $o = Set-StatusSummary -Assessment $a
        Assert-Equal $case.o "$($a.overall)" "overall from [$($case.e -join ',')] -> assessment updated"
        Assert-Equal $case.o "$($o.overall)" "overall from [$($case.e -join ',')] -> returned object"
        Assert-Equal $case.s "$($a.summary)" "summary wording for [$($case.e -join ',')]"
        Assert-True (Test-StatusOverallIs -Assessment $a -Level $case.o) "Test-StatusOverallIs matches $case.o"
    }

    # =====================================================================
    Start-TestGroup '§17.1 row 1: healthy MonitorOnly (single machine)'

    # This is the default install. A healthy machine may still show INFO notes
    # (LOCAL_ONLY, AutoAnchor closed, runner busy) - those are how it is running,
    # not faults - but it must show no WARNING/ERROR line, because those are what
    # the user reads as "something is wrong".
    $hh = Get-StatusAssessment -Status (New-StubStatus -LocalOnly) -Config (New-StubConfig -Coordination $false) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'HEALTHY' $hh.overall 'healthy MonitorOnly is HEALTHY'
    Assert-Equal '运行正常' $hh.summary 'healthy summary'
    $hhBad = @(@($hh.findings) | Where-Object { $_.severity -ne 'INFO' })
    Assert-Equal 0 $hhBad.Count 'healthy single-machine panel has no WARNING/ERROR findings'

    # §16.4 / §20: LOCAL_ONLY is a mode note, never a WARNING, and it must not
    # appear as "MULTI-PC UNSAFE" in the default Chinese view.
    $hm = Get-StatusAssessment -Status (New-StubStatus @{ process = @{ runnerRunningNow = $true; pid = 4321 } } -LocalOnly) `
        -Config (New-StubConfig -Coordination $false) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'HEALTHY' $hm.overall 'LOCAL_ONLY does not downgrade overall'
    Assert-True (Test-HasCode $hm 'LOCAL_ONLY') 'LOCAL_ONLY is reported'
    Assert-Equal 'INFO' (Get-CodeSeverity $hm 'LOCAL_ONLY') 'LOCAL_ONLY is INFO'
    Assert-False ((Get-CodeSet $hm) -contains 'COORDINATION_UNREACHABLE') 'no coordination error in single-machine mode'
    Assert-False ((Get-CodeSet $hm) -contains 'LEASE_TTL_TOO_SHORT') 'lease rules are skipped when coordination is off'
    Assert-True (Test-HasCode $hm 'RUNNER_RUNNING') 'a running runner process is reported'
    Assert-Equal 'INFO' (Get-CodeSeverity $hm 'RUNNER_RUNNING') 'runner state is INFO'
    Assert-True ("$((Get-CodeFinding $hm 'RUNNER_RUNNING').detail)" -match '4321') 'runner detail quotes the pid'

    # §10 row 10 / §17.1 row 1: AutoAnchor shows as closed.
    Assert-True (Test-HasCode $hm 'AUTOANCHOR_OFF') 'AutoAnchor closed is reported'
    Assert-Equal 'INFO' (Get-CodeSeverity $hm 'AUTOANCHOR_OFF') 'AutoAnchor closed is INFO'
    Assert-True ((Get-CodeFinding $hm 'AUTOANCHOR_OFF').title -match '未开启') 'AutoAnchor closed wording'
    $aaOff = (Get-CodeFinding $hm 'AUTOANCHOR_OFF').detail
    Assert-True ($aaOff -like 'daily cap 6*' -and $aaOff -like '*today 0*') "AutoAnchor closed detail carries cap + today: $aaOff"

    # =====================================================================
    Start-TestGroup '§10 row 2 / §17.1 row 2: task not installed'

    $ti = Get-StatusAssessment -Status (New-StubStatus @{ task = @{ installed = $false }; quota = @{ lastReadAt = ''; stale = $false } } -LocalOnly) `
        -Config (New-StubConfig -Coordination $false) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'ERROR' $ti.overall 'missing task is ERROR'
    Assert-True (Test-HasCode $ti 'TASK_NOT_INSTALLED') 'TASK_NOT_INSTALLED'
    $tiFind = Get-CodeFinding $ti 'TASK_NOT_INSTALLED'
    Assert-True ("$($tiFind.action)" -match 'install\.cmd') '§17.1: action names install.cmd'
    Assert-True ("$($tiFind.titleEn)" -match 'not installed') 'English title available for -Language en-US'
    # One cause, one finding: a machine that never ran also has no quota data,
    # but repeating the diagnosis would suggest two problems.
    Assert-Equal 'INFO' (Get-CodeSeverity $ti 'QUOTA_NEVER_READ') 'never-read demoted when the task explains it'

    $td = Get-StatusAssessment -Status (New-StubStatus @{ task = @{ enabled = $false } }) `
        -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'ERROR' $td.overall 'disabled task is ERROR'
    Assert-True (Test-HasCode $td 'TASK_DISABLED') 'TASK_DISABLED'

    $tn = Get-StatusAssessment -Status (New-StubStatus @{ quota = @{ lastReadAt = ''; stale = $false } } -LocalOnly) `
        -Config (New-StubConfig -Coordination $false) -KeeperRoot $emptyRoot -Now $Now
    Assert-True (Test-HasCode $tn 'QUOTA_NEVER_READ') 'fresh install reports no quota data'
    Assert-Equal 'WARNING' (Get-CodeSeverity $tn 'QUOTA_NEVER_READ') 'never-read is WARNING once the task should have run'
    Assert-True ((Get-CodeFinding $tn 'QUOTA_NEVER_READ').title -match '额度') '§10 wording: 尚无额度数据'

    # =====================================================================
    Start-TestGroup '§16.2 / §17.1 row 3: task interval mismatch'

    $tm = Get-StatusAssessment -Status (New-StubStatus @{ pollIntervalMinutes = 30; task = @{ intervalMinutes = 60 } }) `
        -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'WARNING' $tm.overall 'drift is WARNING'
    Assert-True (Test-HasCode $tm 'TASK_INTERVAL_MISMATCH') 'TASK_INTERVAL_MISMATCH'
    $tmFind = Get-CodeFinding $tm 'TASK_INTERVAL_MISMATCH'
    Assert-True ("$($tmFind.action)" -match 'apply-config\.cmd') '§16.2: action names apply-config.cmd'
    Assert-True ("$($tmFind.detail)" -match '30') 'detail quotes the config interval'
    Assert-True ("$($tmFind.detail)" -match '60') 'detail quotes the task interval'

    $tb = Get-StatusAssessment -Status (New-StubStatus @{ task = @{ lastResult = 1 } }) `
        -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'WARNING' $tb.overall 'one failed run is WARNING'
    Assert-True (Test-HasCode $tb 'TASK_LAST_RESULT') 'TASK_LAST_RESULT'
    Assert-True ((Get-CodeFinding $tb 'TASK_LAST_RESULT').title -match '失败') '§10 wording: 最近任务执行失败'
    # §10 row 4: the exit code is part of the diagnosis.
    Assert-True ("$((Get-CodeFinding $tb 'TASK_LAST_RESULT').detail)" -match 'code 1') 'detail shows the exit code'

    foreach ($winCode in @(267009, 267010, 267011)) {
        $tr = Get-StatusAssessment -Status (New-StubStatus @{ task = @{ lastResult = $winCode } }) `
            -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
        Assert-False ((Get-CodeSet $tr) -contains 'TASK_LAST_RESULT') "Win32 task code $winCode is not a keeper failure"
    }

    # The comparison is against the *configured* poll, not against a hard-coded 60:
    # a 30-minute task on a 30-minute config is in sync even though it is not 60.
    $tg = Get-StatusAssessment -Status (New-StubStatus @{ pollIntervalMinutes = 30; task = @{ intervalMinutes = 30 } }) `
        -Config (New-StubConfig -Poll 30) -KeeperRoot $emptyRoot -Now $Now
    Assert-False ((Get-CodeSet $tg) -contains 'TASK_INTERVAL_MISMATCH') 'task interval vs config poll is compared, not vs an assumption'

    # =====================================================================
    Start-TestGroup 'CQK-031: task time limit vs poll (warning, never a throw)'

    # q=180 behind a proxy means 180 s x 2 waits x 2 attempts = 720 s worst case,
    # inside a 13-minute poll. That config is legal (the validator hard-fails only
    # when the budget overruns the poll) but the installer clamp (poll - 2 min) is
    # what decides ExecutionTimeLimit, so the margin is gone and the panel has to
    # say so - the read-only status panel is exactly the tool reached for when the
    # scheduling is suspect, so it must warn rather than refuse to render.
    $cfgTightCqk = New-StubConfig -Coordination $false -Poll 13
    $cfgTightCqk.codex.queryTimeoutSeconds = 180
    $cfgTightCqk.codex.proxy = 'http://proxy.invalid:7890'
    $tl = Get-StatusAssessment -Status (New-StubStatus @{ pollIntervalMinutes = 13; task = @{ intervalMinutes = 13; nextRunTime = $Now.AddMinutes(5) } }) `
        -Config $cfgTightCqk -KeeperRoot $emptyRoot -Now $Now
    Assert-True (Test-HasCode $tl 'TASK_TIME_LIMIT_TIGHT') 'cappedByPoll surfaces as TASK_TIME_LIMIT_TIGHT'
    Assert-Equal 'WARNING' (Get-CodeSeverity $tl 'TASK_TIME_LIMIT_TIGHT') 'a tight limit is WARNING, not ERROR'
    $tlFind = Get-CodeFinding $tl 'TASK_TIME_LIMIT_TIGHT'
    Assert-True ("$($tlFind.detail)" -match '720') 'detail quotes the worst-case run seconds'
    Assert-True ("$($tlFind.detail)" -match '13 min poll') 'detail quotes the poll it must fit inside'
    Assert-True ("$($tlFind.detail)" -match 'clamped to 11 min') 'detail quotes the installed limit'
    Assert-True ("$($tlFind.action)" -match 'queryTimeoutSeconds') 'action names the knob to turn'
    Assert-False ((Get-CodeSet $tl) -contains 'CONFIG_INVALID') 'a tight-but-legal config is not reported invalid'

    # The same budget on a roomy poll: the clamp is not what decided the limit.
    $cfgRoomy = New-StubConfig -Coordination $false -Poll 60
    $cfgRoomy.codex.queryTimeoutSeconds = 180
    $cfgRoomy.codex.proxy = 'http://proxy.invalid:7890'
    $tlOk = Get-StatusAssessment -Status (New-StubStatus -LocalOnly) -Config $cfgRoomy -KeeperRoot $emptyRoot -Now $Now
    Assert-False ((Get-CodeSet $tlOk) -contains 'TASK_TIME_LIMIT_TIGHT') 'uncapped limit stays silent'
    Assert-Equal 'HEALTHY' $tlOk.overall 'a 12-minute budget inside a 60-minute poll is healthy'

    # And a default config never trips it either: the 10-minute floor decides.
    $tlDef = Get-StatusAssessment -Status (New-StubStatus -LocalOnly) -Config (New-StubConfig -Coordination $false) -KeeperRoot $emptyRoot -Now $Now
    Assert-False ((Get-CodeSet $tlDef) -contains 'TASK_TIME_LIMIT_TIGHT') 'default config has no time-limit warning'

    # =====================================================================
    Start-TestGroup '§10 row 5 / §17.1 row 4: Codex not found'

    $cn = Get-StatusAssessment -Status (New-StubStatus @{ codex = @{ found = $false } } -LocalOnly) `
        -Config (New-StubConfig -Coordination $false) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'ERROR' $cn.overall 'missing CLI is ERROR'
    Assert-True (Test-HasCode $cn 'CODEX_NOT_FOUND') 'CODEX_NOT_FOUND'
    $cnFind = Get-CodeFinding $cn 'CODEX_NOT_FOUND'
    Assert-True ("$($cnFind.action)" -match 'codex\.command') '§17.1: action names codex.command'
    Assert-True ("$($cnFind.action)" -match 'PATH' -or "$($cnFind.actionEn)" -match 'PATH') '§17.1: PATH is mentioned'

    $ok = Get-StatusAssessment -Status (New-StubStatus @{ codex = @{ liveOk = $true } } -LocalOnly) `
        -Config (New-StubConfig -Coordination $false) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'HEALTHY' $ok.overall 'a successful -Live probe stays HEALTHY'
    Assert-Equal 'INFO' (Get-CodeSeverity $ok 'LIVE_PROBE_OK') 'probe success is INFO'

    $ap = Get-StatusAssessment -Status (New-StubStatus @{ codex = @{ found = $true; liveOk = $false; liveError = 'not signed in' } }) `
        -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'WARNING' $ap.overall 'a failed auth probe is WARNING'
    Assert-True (Test-HasCode $ap 'AUTH_PROBE_FAILED') 'AUTH_PROBE_FAILED'
    Assert-Equal 'not signed in' "$((Get-CodeFinding $ap 'AUTH_PROBE_FAILED').detail)" 'probe error text preserved'
    # The probe finding only exists when -Live actually ran: the default panel
    # must not invent an auth verdict (§14).
    $noProbe = Get-StatusAssessment -Status (New-StubStatus) -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-False ((Get-CodeSet $noProbe) -contains 'AUTH_PROBE_FAILED') 'no live finding without a probe result'

    # =====================================================================
    Start-TestGroup '§16.3 / §17.1 row 6: quota data freshness'

    $qs = Get-StatusAssessment -Status (New-StubStatus @{ quota = @{ stale = $true; lastReadAt = (ConvertTo-IsoString $Now.AddMinutes(-22)) } }) `
        -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'WARNING' $qs.overall 'stale quota is WARNING'
    Assert-True (Test-HasCode $qs 'QUOTA_STALE') 'QUOTA_STALE'
    $qsFind = Get-CodeFinding $qs 'QUOTA_STALE'
    Assert-True ("$($qsFind.detail)" -match '22 min') '§17.1: shows the last read time/age'
    Assert-True ("$($qsFind.action)" -match 'Live') '§10 row 6: action mentions -Live'

    $qo = Get-StatusAssessment -Status (New-StubStatus @{ quota = @{ stale = $false; lastReadAt = (ConvertTo-IsoString $Now.AddMinutes(-400)) } }) `
        -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-True (Test-HasCode $qo 'QUOTA_TOO_OLD') 'QUOTA_TOO_OLD'
    Assert-False ((Get-CodeSet $qo) -contains 'QUOTA_STALE') 'too-old is not stale (the read itself succeeded)'
    Assert-Equal 'WARNING' (Get-CodeSeverity $qo 'QUOTA_TOO_OLD') 'too-old is WARNING'

    # 2*poll + tolerance(grace 5 + jitter 5) = 130 min: 120 is inside the horizon,
    # so no QUOTA_* finding at all (the baseline's 22 min already is; this pins the
    # boundary from the safe side without sitting right on it).
    $qb = Get-StatusAssessment -Status (New-StubStatus @{ quota = @{ stale = $false; lastReadAt = (ConvertTo-IsoString $Now.AddMinutes(-120)) } }) `
        -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-False (@(Get-CodeSet $qb | Where-Object { $_ -like 'QUOTA_*' }).Count -gt 0) 'within 2*poll + tolerance is silent'
    Assert-Equal 'HEALTHY' $qb.overall 'fresh-enough quota data stays HEALTHY'

    # =====================================================================
    Start-TestGroup '§16.4 / §17.1 row 5: multi-machine coordination'

    $cu = Get-StatusAssessment -Status (New-StubStatus @{ git = @{ reachable = $false } }) `
        -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'ERROR' $cu.overall '§17.1: unreachable coordination is ERROR'
    Assert-True (Test-HasCode $cu 'COORDINATION_UNREACHABLE') 'COORDINATION_UNREACHABLE'
    $cuFind = Get-CodeFinding $cu 'COORDINATION_UNREACHABLE'
    Assert-True ("$($cuFind.action)" -match '网络') '§10 row 8 wording: check network'
    Assert-True ("$($cuFind.detail)" -match 'R:\\repo') 'detail names the repoPath'
    # §17.1: with AutoAnchor on, the same cycle must say anchoring is blocked.
    $cua = Get-StatusAssessment -Status (New-StubStatus @{ autoAnchor = $true; git = @{ reachable = $false }; role = @{ role = 'BACKOFF' } }) `
        -Config (New-StubConfig -AutoAnchor $true) -KeeperRoot $emptyRoot -Now $Now
    Assert-True (Test-HasCode $cua 'AUTOANCHOR_BLOCKED') '§17.1: AutoAnchor hints fail-closed when coordination is down'
    Assert-True ("$((Get-CodeFinding $cua 'AUTOANCHOR_BLOCKED').detail)" -match 'role=BACKOFF') 'block detail quotes the role'

    $gu = Get-StatusAssessment -Status (New-StubStatus @{ git = @{ reachable = $null } }) `
        -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-True (Test-HasCode $gu 'GIT_UNREACHABLE') 'unknown reachability is still reported'
    Assert-Equal 'WARNING' (Get-CodeSeverity $gu 'GIT_UNREACHABLE') 'undetermined reachability does not jump to ERROR'

    $ps = Get-StatusAssessment -Status (New-StubStatus @{ role = @{ role = 'PASSIVE'; leaseExpiresAt = (ConvertTo-IsoString $Now.AddMinutes(64)) } }) `
        -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'HEALTHY' $ps.overall 'a healthy follower is HEALTHY'
    Assert-True (Test-HasCode $ps 'ROLE_PASSIVE') 'ROLE_PASSIVE'
    Assert-Equal 'INFO' (Get-CodeSeverity $ps 'ROLE_PASSIVE') 'follower role is a mode note'
    Assert-True ("$((Get-CodeFinding $ps 'ROLE_PASSIVE').detail)" -match 'lease') 'detail points at the holder'

    $ru = Get-StatusAssessment -Status (New-StubStatus @{ role = @{ role = 'UNKNOWN' } }) `
        -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-True (Test-HasCode $ru 'ROLE_UNKNOWN') 'ROLE_UNKNOWN'
    Assert-Equal 'WARNING' (Get-CodeSeverity $ru 'ROLE_UNKNOWN') 'unknown role needs attention'
    Assert-True ((Get-CodeFinding $ru 'ROLE_UNKNOWN').title -match '未知') '§12: UNKNOWN -> 未知'

    # =====================================================================
    Start-TestGroup '§16.1 lease / poll relationship'

    $ls = Get-StatusAssessment -Status (New-StubStatus) `
        -Config (New-StubConfig -LeaseTtl 50 -Grace 5) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'WARNING' $ls.overall 'effective lease below poll is WARNING'
    Assert-True (Test-HasCode $ls 'LEASE_TTL_TOO_SHORT') 'LEASE_TTL_TOO_SHORT'
    $lsFind = Get-CodeFinding $ls 'LEASE_TTL_TOO_SHORT'
    Assert-True ((Get-CodeSet $ls) -notcontains 'LEASE_TTL_LOW_MARGIN') 'the two lease rules are exclusive'
    Assert-True ("$($lsFind.detail)" -match '50') 'detail quotes the TTL'
    Assert-True ("$($lsFind.detail)" -match '60') 'detail quotes the poll interval'

    $lm = Get-StatusAssessment -Status (New-StubStatus) `
        -Config (New-StubConfig -LeaseTtl 110 -Grace 5) -KeeperRoot $emptyRoot -Now $Now
    Assert-True (Test-HasCode $lm 'LEASE_TTL_LOW_MARGIN') 'LEASE_TTL_LOW_MARGIN under 2x poll'
    Assert-False ((Get-CodeSet $lm) -contains 'LEASE_TTL_TOO_SHORT') 'not too short when effective lease exceeds poll'

    $lh = Get-StatusAssessment -Status (New-StubStatus) `
        -Config (New-StubConfig -LeaseTtl 180 -Grace 5) -KeeperRoot $emptyRoot -Now $Now
    Assert-False (@(Get-CodeSet $lh | Where-Object { $_ -like 'LEASE_*' }).Count -gt 0) 'healthy 3x margin produces no lease finding'

    $lo = Get-StatusAssessment -Status (New-StubStatus -LocalOnly) `
        -Config (New-StubConfig -Coordination $false -LeaseTtl 20) -KeeperRoot $emptyRoot -Now $Now
    Assert-False (@(Get-CodeSet $lo | Where-Object { $_ -like 'LEASE_*' }).Count -gt 0) '§16.1 is scoped to coordination enabled'

    # =====================================================================
    Start-TestGroup '§16.5 / §17.1 rows 8-10: AutoAnchor display'

    $aj = Get-StatusAssessment -Status (New-StubStatus @{ autoAnchor = $true }) `
        -Config (New-StubConfig -AutoAnchor $true) -KeeperRoot $emptyRoot -Now $Now
    Assert-True (Test-HasCode $aj 'AUTOANCHOR_ENABLED') 'enabled banner'
    $ajFind = Get-CodeFinding $aj 'AUTOANCHOR_ENABLED'
    Assert-Equal 'INFO' "$($ajFind.severity)" '§16.5: the banner itself never degrades overall'
    Assert-True ((Get-CodeFinding $aj 'AUTOANCHOR_ENABLED').title -match '实验') '§12: EXPERIMENTAL -> 实验功能'
    Assert-True ("$($ajFind.detail)" -like 'daily cap 6*') '§10 row 10: detail shows the daily cap'
    Assert-True ("$($ajFind.detail)" -like '*today 0*') 'today count shown'
    Assert-True ((Get-CodeSet $aj) -contains 'ANCHOR_TRIGGERS_OFF') 'armed config with no schedule/expiry trigger is explicitly read-only'
    Assert-Equal 'HEALTHY' $aj.overall 'AutoAnchor alone is not a fault (§16.5)'

    $as = Get-StatusAssessment -Status (New-StubStatus @{ autoAnchor = $true; anchorSchedule = @{ slots = @('09:30', '21:00') } }) `
        -Config (New-StubConfig -AutoAnchor $true -Schedule @('09:30', '21:00')) -KeeperRoot $emptyRoot -Now $Now
    Assert-False (Test-HasCode $as 'ANCHOR_TRIGGERS_OFF') 'schedule is an independent configured trigger'
    Assert-Equal 'HEALTHY' $as.overall 'timer mode is a configuration, not a fault'

    $ak = Get-StatusAssessment -Status (New-StubStatus @{ autoAnchor = $true }) `
        -Config (New-StubConfig -AutoAnchor $true) -KeeperRoot $emptyRoot -Now $Now
    Assert-True (Test-HasCode $ak 'ANCHOR_TRIGGERS_OFF') 'no schedule/expiry trigger is reported'

    # ---- Get-StatusAnchorBlock mirrors Test-ShouldAnchor (§16.5) ----------
    Assert-Equal 'ANCHOR_GAP_COOLDOWN' (Get-StatusAnchorBlock -MinimumGapMinutes 300 -LastAnchorAt (ConvertTo-IsoString $Now.AddMinutes(-42)) -Now $Now).code 'gap cooldown reported'
    Assert-Equal 'INFO' (Get-StatusAnchorBlock -MinimumGapMinutes 300 -LastAnchorAt (ConvertTo-IsoString $Now.AddMinutes(-42)) -Now $Now).severity 'a cooldown is not a fault'
    Assert-True ((Get-StatusAnchorBlock -MinimumGapMinutes 300 -LastAnchorAt (ConvertTo-IsoString $Now.AddMinutes(-42)) -Now $Now).detail -match '42 < 300') 'cooldown detail matches the guard wording'
    Assert-Null (Get-StatusAnchorBlock -MinimumGapMinutes 300 -LastAnchorAt (ConvertTo-IsoString $Now.AddMinutes(-42)) -ScheduleMode $true -Now $Now) 'schedule mode bypasses the gap'
    Assert-Null (Get-StatusAnchorBlock -MinimumGapMinutes 300 -LastAnchorAt (ConvertTo-IsoString $Now.AddMinutes(-400)) -Now $Now) 'gap elapsed -> allowed'
    Assert-Equal 'ANCHOR_CAP_REACHED' (Get-StatusAnchorBlock -AnchorTodayCount 6 -MaxPerDay 6 -Now $Now).code 'daily cap blocks'
    Assert-Equal 'WARNING' (Get-StatusAnchorBlock -AnchorTodayCount 6 -MaxPerDay 6 -Now $Now).severity 'hitting the cap is expected operation, not a fault'
    Assert-True ((Get-StatusAnchorBlock -AnchorTodayCount 6 -MaxPerDay 6 -Now $Now).detail -match '6/6') 'cap detail matches guard wording'
    Assert-Null (Get-StatusAnchorBlock -AnchorTodayCount 6 -MaxPerDay 0 -Now $Now) 'maxPerDay 0 is validated away, never a divide-by-zero'
    Assert-Equal 'AUTOANCHOR_BLOCKED' (Get-StatusAnchorBlock -LocalOnly $false -Role 'PASSIVE' -Now $Now).code 'non-leader cannot anchor'
    Assert-Equal 'ERROR' (Get-StatusAnchorBlock -LocalOnly $false -Role 'PASSIVE' -Now $Now).severity 'fail-closed'
    Assert-Null (Get-StatusAnchorBlock -LocalOnly $true -Role 'PASSIVE' -Now $Now) 'LOCAL_ONLY always runs as its own leader'
    Assert-Equal 'BACKOFF_ACTIVE' (Get-StatusAnchorBlock -QuotaStale $true -BackoffActive $true -Now $Now).code 'backoff outranks the stale-snapshot check (guard order)'
    Assert-Equal 'AUTOANCHOR_BLOCKED' (Get-StatusAnchorBlock -QuotaStale $true -Now $Now).code 'stale quota fails closed'
    Assert-Equal 'AUTOANCHOR_BLOCKED' (Get-StatusAnchorBlock -RateLimitReachedType 'primary' -Now $Now).code 'open usage limit blocks'
    Assert-Equal 'AUTOANCHOR_BLOCKED' (Get-StatusAnchorBlock -SchemaUnknown $true -Now $Now).code 'unknown schema blocks'
    Assert-Equal 'BACKOFF_ACTIVE' (Get-StatusAnchorBlock -BackoffActive $true -BackoffUntilText '2026-09-09 12:30:00' -BackoffReason '429' -Now $Now).code 'backoff blocks anchoring'

    # =====================================================================
    Start-TestGroup 'derived state: daily anchors, backoff, day rollover'

    $bw = New-TestWorkspace
    try {
        $bRoot = Join-Path $bw 'keeper'
        New-Item -ItemType Directory -Force -Path (Join-Path $bRoot 'runtime\logs') | Out-Null
        Set-Backoff -Root $bRoot -Minutes 30 -Reason '429' | Out-Null
        $ba = Get-StatusAssessment -Status (New-StubStatus -LocalOnly) -Config (New-StubConfig -Coordination $false) -KeeperRoot $bRoot -Now $Now
        Assert-True (Test-HasCode $ba 'BACKOFF_ACTIVE_SINGLE') 'active local backoff is shown'
        Assert-Equal 'INFO' (Get-CodeSeverity $ba 'BACKOFF_ACTIVE_SINGLE') '§10: backoff is a control action, not a failure'
        Assert-True (Test-HasCode $ba 'LOCAL_ONLY') 'single-machine mode still reported alongside'
        Assert-Equal 'HEALTHY' $ba.overall 'backoff keeps the panel HEALTHY'

        # A backoff window that already passed must not be shown (Get-BackoffState
        # expiry filter reaching the panel through the assessment).
        $b2Root = Join-Path $bw 'keeper2'
        New-Item -ItemType Directory -Force -Path (Join-Path $b2Root 'runtime\logs') | Out-Null
        Set-Backoff -Root $b2Root -Minutes -5 -Reason '429' | Out-Null
        $b2 = Get-StatusAssessment -Status (New-StubStatus -LocalOnly) -Config (New-StubConfig -Coordination $false) -KeeperRoot $b2Root -Now $Now
        Assert-False ((Get-CodeSet $b2) -contains 'BACKOFF_ACTIVE_SINGLE') 'expired backoff disappears'

        # Set-Backoff stamps the *real* wall clock (not the injected $Now), so the
        # 30-minute window above is still open as far as Get-BackoffState is
        # concerned. Clear it: backoff outranks the daily cap in the guard chain,
        # and the anchor-count cases below must not inherit this machine's park.
        Clear-Backoff -Root $bRoot

        # Anchors are counted per calendar day (state.anchors.day).
        $st = New-KeeperState
        $st.anchors = @{ day = $Today; count = 2; lastAnchorAt = (ConvertTo-IsoString $Now.AddMinutes(-400)) }
        Save-KeeperState -Root $bRoot -State $st
        $ac = Get-StatusAssessment -Status (New-StubStatus @{ autoAnchor = $true } -LocalOnly) -Config (New-StubConfig -AutoAnchor $true -Coordination $false) -KeeperRoot $bRoot -Now $Now
        Assert-True ("$((Get-CodeFinding $ac 'AUTOANCHOR_ENABLED').detail)" -like '*today 2*') 'today anchor count read from state'

        # Yesterday's count must not be read as today's.
        $stY = New-KeeperState
        $stY.anchors = @{ day = '2026-09-08'; count = 6; lastAnchorAt = (ConvertTo-IsoString $Now.AddDays(-1)) }
        Save-KeeperState -Root $bRoot -State $stY
        $ay = Get-StatusAssessment -Status (New-StubStatus @{ autoAnchor = $true } -LocalOnly) -Config (New-StubConfig -AutoAnchor $true -Coordination $false) -KeeperRoot $bRoot -Now $Now
        Assert-True ("$((Get-CodeFinding $ay 'AUTOANCHOR_ENABLED').detail)" -like '*today 0*') 'yesterday count is not today count'
        Assert-False ((Get-CodeSet $ay) -contains 'ANCHOR_CAP_REACHED') 'yesterday cap does not block today'

        # Today at the cap -> blocking finding, and the gap note stays behind it
        # (guard order: cap before gap).
        $stC = New-KeeperState
        $stC.anchors = @{ day = $Today; count = 6; lastAnchorAt = (ConvertTo-IsoString $Now.AddMinutes(-30)) }
        Save-KeeperState -Root $bRoot -State $stC
        $acap = Get-StatusAssessment -Status (New-StubStatus @{ autoAnchor = $true } -LocalOnly) -Config (New-StubConfig -AutoAnchor $true -Coordination $false) -KeeperRoot $bRoot -Now $Now
        Assert-True (Test-HasCode $acap 'ANCHOR_CAP_REACHED') 'cap reached is reported'
        Assert-False ((Get-CodeSet $acap) -contains 'ANCHOR_GAP_COOLDOWN') 'first blocking reason wins'
        Assert-Equal 'WARNING' $acap.overall 'a capped day is a note, not an outage'

        # Schema-unknown / limit-open come from state, not from the status object.
        $stS = New-KeeperState; $stS.schemaUnknown = $true
        Save-KeeperState -Root $bRoot -State $stS
        $as2 = Get-StatusAssessment -Status (New-StubStatus @{ autoAnchor = $true } -LocalOnly) -Config (New-StubConfig -AutoAnchor $true -Coordination $false) -KeeperRoot $bRoot -Now $Now
        Assert-True (Test-HasCode $as2 'AUTOANCHOR_BLOCKED') 'unknown schema blocks anchoring'
    } finally { Remove-TestWorkspace $bw }

    # =====================================================================
    Start-TestGroup '§10 row 13 / §16.3: lastError vs the verdict stream'

    $lw = New-TestWorkspace
    try {
        $lRoot = Join-Path $lw 'keeper'
        New-Item -ItemType Directory -Force -Path (Join-Path $lRoot 'runtime\logs') | Out-Null

        # No logs at all: fail OPEN to INFO, because status may legitimately be
        # read where logs were rotated or the runner never ran.
        $nl = Get-StatusAssessment -Status (New-StubStatus @{ lastError = 'boom' } -LocalOnly) `
            -Config (New-StubConfig -Coordination $false) -KeeperRoot $lRoot -Now $Now
        Assert-Equal 'HEALTHY' $nl.overall 'unverifiable history must not fabricate an error'
        Assert-True (Test-HasCode $nl 'LAST_ERROR_RECENT') 'the error is still shown'
        Assert-Equal 'INFO' (Get-CodeSeverity $nl 'LAST_ERROR_RECENT') 'INFO when recovery cannot be confirmed either way'
        Assert-True ("$((Get-CodeFinding $nl 'LAST_ERROR_RECENT').detail)" -match 'boom') 'the error text survives'

        Write-VerdictLog -Root $lRoot -Ts $Now.AddMinutes(-360) -Level 'ERROR' -Event 'RUNNER_ERROR'
        Write-VerdictLog -Root $lRoot -Ts $Now.AddMinutes(-2) -Level 'INFO' -Event 'RUNNER_OK'
        $rec = Get-StatusAssessment -Status (New-StubStatus @{ lastError = 'boom' } -LocalOnly) `
            -Config (New-StubConfig -Coordination $false) -KeeperRoot $lRoot -Now $Now
        Assert-Equal 'HEALTHY' $rec.overall '§10 row 13: recovered run is not ERROR'
        Assert-False ((Get-CodeSet $rec) -contains 'QUOTA_READ_FAILED') 'no failure finding after RUNNER_OK'

        Write-VerdictLog -Root $lRoot -Ts $Now.AddMinutes(-1) -Level 'ERROR' -Event 'RUNNER_ERROR'
        $act = Get-StatusAssessment -Status (New-StubStatus @{ lastError = 'boom' } -LocalOnly) `
            -Config (New-StubConfig -Coordination $false) -KeeperRoot $lRoot -Now $Now
        Assert-Equal 'WARNING' $act.overall 'an ERROR after the last OK is still open'
        Assert-True (Test-HasCode $act 'QUOTA_READ_FAILED') 'QUOTA_READ_FAILED names the failed verdict'
        Assert-True (Test-HasCode $act 'LAST_ERROR_RECENT') 'and the error line is shown too'

        # Everything outside the freshness horizon is history (§16.3 tolerance).
        $old = Get-StatusAssessment -Status (New-StubStatus @{ lastError = 'boom' } -LocalOnly) `
            -Config (New-StubConfig -Coordination $false) -KeeperRoot $lRoot -Now $Now.AddMinutes(700)
        Assert-False ((Get-CodeSet $old) -contains 'QUOTA_READ_FAILED') 'stale log tail is not treated as current'

        # A machine whose runner never completed a cycle has no verdict at all.
        $lRoot2 = Join-Path $lw 'keeper2'
        New-Item -ItemType Directory -Force -Path (Join-Path $lRoot2 'runtime\logs') | Out-Null
        Write-VerdictLog -Root $lRoot2 -Ts $Now.AddMinutes(-5) -Level 'ERROR' -Event 'CONFIG_INVALID'
        $nv = Get-StatusVerdictFreshness -Root $lRoot2 -PollMinutes 60 -Now $Now
        Assert-Equal 'no-verdict' $nv.reason 'no RUNNER_OK/RUNNER_ERROR line yet'
        # Fail-open on purpose: a machine whose runner never finished a cycle has
        # no verdict to judge, which is not evidence of a failure.
        Assert-True $nv.fresh 'no verdict is not an open failure'
        $nv2 = Get-StatusVerdictFreshness -Root (Join-Path $lw 'missing') -PollMinutes 60 -Now $Now
        Assert-Equal 'no-logs' $nv2.reason 'absent log dir does not throw'

        # A future timestamp must not be read as "recovered 0 minutes ago" in the
        # other direction - negative ages clamp to 0.
        Write-VerdictLog -Root $lRoot2 -Ts $Now.AddMinutes(-1) -Level 'INFO' -Event 'RUNNER_OK'
        $clamped = Get-StatusAssessment -Status (New-StubStatus @{ lastError = 'boom' } -LocalOnly) `
            -Config (New-StubConfig -Coordination $false) -KeeperRoot $lRoot2 -Now $Now.AddMinutes(-60)
        Assert-False ((Get-CodeSet $clamped) -contains 'QUOTA_READ_FAILED') 'clock skew does not invent a failure'
    } finally { Remove-TestWorkspace $lw }

    # =====================================================================
    Start-TestGroup '§9.2 contract: no writes, no silence, no leaks'

    $cw = New-TestWorkspace
    try {
        $cRoot = Join-Path $cw 'keeper'
        New-Item -ItemType Directory -Force -Path (Join-Path $cRoot 'runtime\logs') | Out-Null
        $st0 = New-KeeperState
        $st0.anchors = @{ day = $Today; count = 1; lastAnchorAt = $null }
        Save-KeeperState -Root $cRoot -State $st0
        $statePath = Get-StatePath $cRoot
        $before = [System.IO.File]::ReadAllText($statePath)
        $beforeSet = @(Get-ChildItem -LiteralPath (Get-RuntimeDir $cRoot) -Recurse -File | ForEach-Object { $_.FullName })

        $a = Get-StatusAssessment -Status (New-StubStatus @{ lastError = 'token=abc123def456' }) -Config (New-StubConfig) -KeeperRoot $cRoot -Now $Now

        Assert-Equal $before ([System.IO.File]::ReadAllText($statePath)) '§9.2: state.json untouched'
        $afterSet = @(Get-ChildItem -LiteralPath (Get-RuntimeDir $cRoot) -Recurse -File | ForEach-Object { $_.FullName })
        Assert-Equal ($beforeSet -join '|') ($afterSet -join '|') 'no runtime/ files created'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Get-LogsDir $cRoot) -Recurse -File).Count '§9.2: assessment writes no log lines'

        # Findings are self-describing: a renderer must never have to look a code up.
        foreach ($f in @($a.findings)) {
            Assert-True ($f.ContainsKey('code') -and "$($f.code)" -match '^[A-Z][A-Z0-9_]*$') "code is UPPER_SNAKE: $($f.code)"
            Assert-True (@('ERROR', 'WARNING', 'INFO') -contains "$($f.severity)") "severity is one of three: $($f.code)=$($f.severity)"
            Assert-True ("$($f.title)".Length -gt 0 -and "$($f.action)".Length -gt 0) "title+action populated: $($f.code)"
            Assert-True ($f.ContainsKey('titleEn') -and ($f.titleEn -ne '')) "titleEn populated: $($f.code)"
            Assert-True ($f.ContainsKey('observedAt') -and "$($f.observedAt)" -match '^\d{4}-\d{2}-\d{2}T') "observedAt is ISO: $($f.code)"
            # Empty detail drops the key rather than carrying '' (renderer can test
            # ContainsKey instead of checking for a falsy string).
            if ($f.ContainsKey('detail')) { Assert-True ("$($f.detail)".Length -gt 0) "detail non-empty when present: $($f.code)" }
        }
    } finally { Remove-TestWorkspace $cw }

    # =====================================================================
    Start-TestGroup 'shape tolerance and fail-fast'

    # -Live changes the facts, not the rules: the assessment must not carry a
    # switch that re-interprets them.
    $swLive = @(Get-Command Get-StatusAssessment).Parameters.Keys
    Assert-False ($swLive -contains 'IncludeLiveVerdict') 'no -IncludeLiveVerdict: rules never key off a CLI flag'

    $null1 = Get-StatusAssessment -Status $null -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'ERROR' $null1.overall 'null status is ERROR'
    Assert-True (Test-HasCode $null1 'CONFIG_INVALID') 'CONFIG_INVALID'
    Assert-True ((Get-CodeFinding $null1 'CONFIG_INVALID').title -match '配置无效') '§10 row 1 wording'
    Assert-True ("$((Get-CodeFinding $null1 'CONFIG_INVALID').action)" -match 'apply-config\.cmd') '§10 row 1 action'
    Assert-Equal 1 @($null1.findings).Count 'one broken config, one finding (§10 stop-here rule)'

    $empty = Get-StatusAssessment -Status @{} -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'ERROR' $empty.overall 'empty status is ERROR'
    Assert-Equal 1 @($empty.findings).Count 'no cascade of phantom findings'

    $cfgFalse = Get-StatusAssessment -Status (New-StubStatus @{ configOk = $false; lastError = 'poll.intervalMinutes must be >= 5' }) `
        -Config (New-StubConfig) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'ERROR' $cfgFalse.overall 'configOk=false is ERROR'
    Assert-Equal 1 @($cfgFalse.findings).Count 'assessment stops at the config error'
    Assert-True ("$((Get-CodeFinding $cfgFalse 'CONFIG_INVALID').detail)" -match 'intervalMinutes') 'validator message is carried through'

    # Missing keys must not throw (no Set-StrictMode in this project, and the
    # collector returns early on config failure).
    $sparse = Get-StatusAssessment -Status @{ configOk = $true } -Config (New-StubConfig -Coordination $false) -KeeperRoot $emptyRoot -Now $Now
    Assert-NotNull $sparse 'sparse status does not throw'
    # Absent facts are read as absent, not as fine: no task installed is ERROR by
    # design (§10 row 2), so a status object missing everything must not look
    # merely "notable". The point of this case is that it yields a *verdict*, not
    # that the verdict is soft.
    Assert-Equal 'ERROR' $sparse.overall 'sparse status still yields a usable verdict'
    Assert-True (Test-HasCode $sparse 'TASK_NOT_INSTALLED') 'absent task facts read as not installed'

    # PSCustomObject is what status-json.ps1 round-trips: same rules, same result.
    $obj = (New-StubStatus -LocalOnly) | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $fromObj = Get-StatusAssessment -Status $obj -Config (New-StubConfig -Coordination $false) -KeeperRoot $emptyRoot -Now $Now
    Assert-Equal 'HEALTHY' $fromObj.overall 'JSON round-tripped status is HEALTHY'
    Assert-True (Test-HasCode $fromObj 'LOCAL_ONLY') 'nested hashtable reads work on PSCustomObject too'

    # Config loaded from disk (not injected): JSONC comments must survive, since
    # config.example.jsonc is the shipped template.
    $dw = New-TestWorkspace
    try {
        $dRoot = Join-Path $dw 'keeper'
        New-Item -ItemType Directory -Force -Path (Join-Path $dRoot 'runtime\logs') | Out-Null
        $dCfg = Join-Path $dRoot 'config.json'
        $json = ConvertTo-Json -InputObject (New-StubConfig -Coordination $false) -Depth 12
        [System.IO.File]::WriteAllText($dCfg, "// JSONC comment that the naive parser would choke on`n$json", (New-Object System.Text.UTF8Encoding($false)))
        $dc = Get-StatusAssessment -Status (New-StubStatus -LocalOnly) -ConfigFile $dCfg -KeeperRoot $dRoot -Now $Now
        Assert-Equal 'HEALTHY' $dc.overall 'config read from disk'
        Assert-True (Test-HasCode $dc 'LOCAL_ONLY') 'coordination=false read from disk'

        [System.IO.File]::WriteAllText($dCfg, '{ this is not json', (New-Object System.Text.UTF8Encoding($false)))
        $dbad = Get-StatusAssessment -Status (New-StubStatus -LocalOnly) -ConfigFile $dCfg -KeeperRoot $dRoot -Now $Now
        Assert-Equal 'ERROR' $dbad.overall 'unparseable config is ERROR'
        Assert-True (Test-HasCode $dbad 'CONFIG_INVALID') 'CONFIG_INVALID from the loader'
    } finally { Remove-TestWorkspace $dw }

    # =====================================================================
    Start-TestGroup 'helper primitives'

    $iso = ConvertTo-StatusDateTime (ConvertTo-IsoString $Now)
    Assert-Equal $Now.ToString('yyyy-MM-dd HH:mm:ss') $iso.ToString('yyyy-MM-dd HH:mm:ss') 'ISO -> local datetime'
    $utc = ConvertTo-StatusDateTime '2026-09-09T04:00:00Z'
    Assert-NotNull $utc 'UTC form parses'
    Assert-Null (ConvertTo-StatusDateTime 'not a date') 'unparseable -> $null'
    Assert-Null (ConvertTo-StatusDateTime '') 'empty -> $null'
    Assert-Null (ConvertTo-StatusDateTime $null) 'null -> $null'

    Assert-Equal 22 (Get-StatusMinutesSince -Value (ConvertTo-IsoString $Now.AddMinutes(-22)) -Now $Now) 'age in minutes'
    Assert-Equal 0 (Get-StatusMinutesSince -Value (ConvertTo-IsoString $Now.AddMinutes(50)) -Now $Now) 'future clamps to 0'
    Assert-Null (Get-StatusMinutesSince -Value '' -Now $Now) 'no value -> $null'
    Assert-Null (Get-StatusMinutesSince -Value $null -Now $Now) 'null -> $null'

    $dp = @{ a = @{ b = @{ c = 7 } } }
    Assert-Equal 7 (Get-StatusValue -Map $dp -Path 'a.b.c') 'dotted path read'
    Assert-Null (Get-StatusValue -Map $dp -Path 'a.b.missing') 'missing leaf -> $null'
    Assert-Null (Get-StatusValue -Map $dp -Path 'x.y.z') 'missing branch -> $null'
    Assert-Null (Get-StatusValue -Map $null -Path 'a') 'null map -> $null'
    Assert-Null (Get-StatusValue -Map 'string' -Path 'a') 'scalar map -> $null'

    # Add-StatusFinding appends in place and returns nothing.
    $av = New-StatusAssessment
    $ret = Add-StatusFinding -Assessment $av -Code 'LOCAL_ONLY' -Now $Now
    Assert-Null $ret 'Add-StatusFinding leaks nothing into the pipeline'
    Assert-Equal 1 @($av.findings).Count 'finding appended in place'
    $null = Add-StatusFinding -Assessment $av -Code 'TASK_DISABLED' -Now $Now
    Assert-Equal 2 @($av.findings).Count 'second finding appended'
    Assert-Equal 'LOCAL_ONLY' "$(@($av.findings)[0].code)" 'order preserved'
    # Severity override (the INFO demotions) must stick.
    $ao = New-StatusAssessment
    Add-StatusFinding -Assessment $ao -Code 'QUOTA_NEVER_READ' -Severity 'INFO' -Now $Now
    Assert-Equal 'INFO' "$(@($ao.findings)[0].severity)" 'explicit severity wins over the catalog'

    Start-TestGroup 'execution profile contributes to overall health'
    $profileWs = New-TestWorkspace
    try {
        Ensure-Directory (Get-LogsDir $profileWs) | Out-Null
        $pc = New-StubConfig -Coordination $false -AutoAnchor $true
        $ps = New-StubStatus @{ autoAnchor = $true; executionProfile = @{ source = 'live'; stale = $false; value = @{ validation = 'INVALID' } } } -LocalOnly
        $pa = Get-StatusAssessment -Status $ps -Config $pc -KeeperRoot $profileWs -Now $Now
        Assert-True (Test-HasCode $pa 'PROFILE_INVALID') 'invalid live profile has structured finding'
        Assert-Equal 'ERROR' $pa.overall 'invalid profile cannot be healthy'
        $ps.executionProfile = @{ source = 'cache'; stale = $false; value = @{ validation = 'VALID'; validatedAt = (ConvertTo-IsoString $Now.AddMinutes(-5)) } }
        Write-VerdictLog -Root $profileWs -Ts $Now.AddMinutes(-1) -Level 'ERROR' -Event 'ANCHOR_PROFILE_UNAVAILABLE'
        Write-VerdictLog -Root $profileWs -Ts $Now -Level 'INFO' -Event 'RUNNER_OK'
        $pa = Get-StatusAssessment -Status $ps -Config $pc -KeeperRoot $profileWs -Now $Now
        Assert-True (Test-HasCode $pa 'PROFILE_UNAVAILABLE') 'runner OK does not erase newer profile failure'
        Assert-Equal 'WARNING' $pa.overall 'unavailable profile cannot be healthy'
        $ps.executionProfile.source = 'live'
        $pa = Get-StatusAssessment -Status $ps -Config $pc -KeeperRoot $profileWs -Now $Now
        Assert-False (Test-HasCode $pa 'PROFILE_UNAVAILABLE') 'live validation supersedes historical profile error'
        $ps.executionProfile.stale = $true
        $pa = Get-StatusAssessment -Status $ps -Config $pc -KeeperRoot $profileWs -Now $Now
        Assert-True (Test-HasCode $pa 'PROFILE_STALE') 'stale profile is explicitly reported'
        Assert-Equal 'WARNING' $pa.overall 'stale profile cannot be healthy'
    } finally { Remove-TestWorkspace $profileWs }

    # ---- sensitive text never reaches the panel ---------------------------
    $sw2 = New-TestWorkspace
    try {
        $sRoot = Join-Path $sw2 'keeper'
        New-Item -ItemType Directory -Force -Path (Join-Path $sRoot 'runtime\logs') | Out-Null
        $secret = 'ghp_' + ('Z' * 30)
        $sv = Get-StatusAssessment -Status (New-StubStatus @{ lastError = "auth failed for $secret" } -LocalOnly) `
            -Config (New-StubConfig -Coordination $false) -KeeperRoot $sRoot -Now $Now
        $flat = (ConvertTo-Json -InputObject $sv -Depth 8)
        Assert-False ($flat.Contains($secret)) 'token in lastError is masked'
        Assert-True ($flat.Contains('[REDACTED]')) 'masked marker present'

        $lePath = Get-LogsDir $sRoot
        # Written through Write-VerdictLog so the stamp carries the *host's* offset:
        # baking +08:00 here made the verdict 8h old on a UTC runner, which flips
        # §10's escalation to 'stale-verdict' (fresh) and drops the finding.
        Write-VerdictLog -Root $sRoot -Ts $Now -Level 'ERROR' -Event 'RUNNER_ERROR' -MachineId 'm' -ErrorText 'password=hunter2 failed'
        $sv2 = Get-StatusAssessment -Status (New-StubStatus @{ lastError = 'older' } -LocalOnly) `
            -Config (New-StubConfig -Coordination $false) -KeeperRoot $sRoot -Now $Now
        $flat2 = (ConvertTo-Json -InputObject $sv2 -Depth 8)
        Assert-False ($flat2.Contains('hunter2')) 'password in the verdict detail is masked'
        Assert-True ($flat2.Contains('last verdict RUNNER_ERROR')) 'the failure is still reported'
    } finally { Remove-TestWorkspace $sw2 }
} catch {
    Write-Host "status-assessment.test.ps1 EXCEPTION: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
} finally {
    Remove-TestWorkspace $emptyWs
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "status-assessment.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
