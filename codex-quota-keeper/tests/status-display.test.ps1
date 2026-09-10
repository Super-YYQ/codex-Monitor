# Tests for the Status display layer (design doc v2.0 §11~§15, §17.2) - CQK-026~030.
#
# Three things are pinned here, and each is the part of the panel that can break
# without anyone touching the code that displays it:
#   - derived fields (§15.2): remaining percent, work mode, today's anchor count,
#     the next slot, the never-empty model/effort text;
#   - the §13 colour contract: logical line objects carry text + colour, ANSI is
#     never spliced into a string, and the [正常]/[注意]/[异常] prefixes mean the
#     panel reads identically with colour off, in a redirect and in a golden file;
#   - the §17.2 golden snapshots, rebuilt here from the same fixtures
#     golden-update.ps1 wrote them from, on PS 5.1 and PS 7 alike.
#
# The fact layer is mocked like it is in status-assessment.test.ps1 - the display
# layer must not re-probe anything, so hand-built status/config are the correct
# input. What *is* real: Load-KeeperState, Load-Config, Get-StatusAssessment and
# the whole renderer.
#
# UTF-8 BOM required: this file has non-ASCII inside string literals, and PS 5.1
# decodes a BOM-less script as the legacy codepage.

$ErrorActionPreference = 'Stop'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
. (Join-Path $testsDir 'golden-fixtures.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
$goldenDir = Join-Path $testsDir 'golden'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'state-machine.ps1')
. (Join-Path $scriptDir 'status-assessment.ps1')
. (Join-Path $scriptDir 'status-display.ps1')

$Now = Get-GoldenNow
$Today = $Now.ToString('yyyy-MM-dd')
# Colours the panel uses to paint a verdict. "Unpainted" cannot be asserted as
# $null - see Capture-Console below - so it is asserted as "none of these".
$script:SevColors = @('Red', 'Yellow', 'Green', 'Cyan', 'DarkGray')

# ---- helpers ---------------------------------------------------------------

function Get-RowText {
    # The rendered rows of a panel as plain strings, colours already dropped.
    # `,$texts` and not `return @(...)`: a bare array return is unwrapped by
    # PowerShell, so a one-line panel comes back as a String and [0] hands the
    # caller a Char - which fails on .EndsWith() long before the assertion does.
    param($Lines)
    $texts = @(foreach ($l in [object[]]$Lines) { [string]$l.text })
    return ,$texts
}

function Get-RowLine {
    # The single panel line whose label matches, or '' when there is none. Labels
    # are padded to a display column, so matching on the label prefix (indent +
    # label + padding + colon) is how the row is identified unambiguously. When a
    # label repeats across sections (说明) the caller must assert the whole row.
    param($Lines, [string]$Label)
    foreach ($t in (Get-RowText $Lines)) {
        if ($t -match ('^\s*' + [regex]::Escape($Label) + '\s*:')) { return $t }
    }
    return ''
}

function Assert-RowValue {
    # Asserts that the row for $Label carries exactly $Value after its colon. The
    # padding itself is not re-derived here - the cell-18 sweep and the golden
    # snapshots own the layout bytes - so this stays about which value belongs to
    # which label even when a row's value contains spaces or colons.
    param($Lines, [string]$Label, [string]$Value, [string]$Message)
    $row = Get-RowLine $Lines $Label
    if ($row -eq '') { Assert-True $false "$Message (no row labelled [$Label])"; return }
    $idx = $row.IndexOf(': ')
    if ($idx -lt 0) { Assert-True $false "$Message (row [$row] has no ': ' separator)"; return }
    Assert-Equal $Value $row.Substring($idx + 2) $Message
}

function Test-RowAlignment {
    # §11.1: every structural row's colon sits at display cell 18, i.e. the padding
    # between the label and the colon is exactly max(1, 18 - indent - labelCells).
    # Read off the row text alone (the label is the trimmed prefix before the
    # colon), so this does not reuse the renderer's own padding formula.
    param($Texts)
    $count = 0
    foreach ($raw in @($Texts)) {
        $t = [string]$raw
        if ($t -notmatch '^( {2}| {4})\S') { continue }
        $idx = $t.IndexOf(': ')
        if ($idx -lt 0) { continue }
        $ind = 0
        while ($ind -lt $t.Length -and [string]$t[$ind] -eq ' ') { $ind++ }
        $prefix = $t.Substring(0, $idx)
        $labelCells = (Get-CqkDisplayWidth $prefix.TrimEnd()) - $ind
        $actualPad = (Get-CqkDisplayWidth $prefix) - $ind - $labelCells
        Assert-Equal ([Math]::Max(1, [int]$script:CqkStatusLabelCol - $ind - $labelCells)) $actualPad "padding of row [$($prefix.TrimEnd())]"
        $count++
    }
    return $count
}

function Capture-Console {
    # Write-Host writes to the information stream, which 6>&1 turns into
    # InformationRecord objects. The rendered text is on MessageData.Message - NOT
    # on $record.Text, which is empty for Write-Host records - and the colour the
    # caller asked for is MessageData.ForegroundColor. Verified identical on 5.1 and
    # 7; a bare Write-Host (no -ForegroundColor) reports Gray, the console default,
    # so "unpainted" is asserted as "not a severity colour", not as $null. That is
    # also why the panel's -NoColor pass and a plain row look the same to a probe:
    # the difference between them is observable, the baseline is not.
    param([scriptblock]$Block)
    $recs = @( & $Block 6>&1 )
    return ,$recs
}

function Get-CapturedColor {
    param($Record)
    $fg = $Record.MessageData.ForegroundColor
    if ($null -eq $fg) { return '' }
    return [string]$fg
}

function Get-CapturedText {
    param($Record)
    return [string]$Record.MessageData.Message
}

# A healthy status with sensible defaults for the field tests. Kept separate from
# the golden fixtures: snapshots must stay frozen, while these tests are about
# individual derivations and are allowed to vary per case.
function New-DisplayStatus {
    param([hashtable]$Over = @{})
    return (Merge-StatusOver (New-GoldenStatus @{} -LocalOnly) $Over)
}

# Neutral KeeperRoot with the runtime layout and no state/config files: the panel
# reads state itself (Load-KeeperState) and must cope with "not installed yet".
$wsBase = New-TestWorkspace
$rootBase = Join-Path $wsBase 'keeper'
New-Item -ItemType Directory -Force -Path (Join-Path $rootBase 'runtime\logs') | Out-Null

try {
    # -----------------------------------------------------------------------
    Start-TestGroup 'Get-CqkDisplayWidth: CJK counts as two cells'
    Assert-Equal 0 (Get-CqkDisplayWidth '') 'empty string is zero cells'
    Assert-Equal 3 (Get-CqkDisplayWidth 'abc') 'ascii'
    Assert-Equal 7 (Get-CqkDisplayWidth '本机 ID') '2 CJK + space + 2 ascii'
    Assert-Equal 8 (Get-CqkDisplayWidth '当前状态') '4 CJK'
    # '本机 ID' is 5 characters and 7 cells; '当前状态' is 4 characters and 8 cells.
    # Character count and cell count order the two labels in opposite directions,
    # which is exactly why padding is measured in cells: Length-based padding puts
    # their colons two cells apart.
    Assert-True ((('本机 ID').Length -gt ('当前状态').Length) -and ((Get-CqkDisplayWidth '本机 ID') -lt (Get-CqkDisplayWidth '当前状态'))) 'char count and cell count disagree'
    Assert-Equal 6 (Get-CqkDisplayWidth '［全］') 'fullwidth brackets count as 2 each'
    Assert-Equal 5 (Get-CqkDisplayWidth 'a中文') 'mixed ascii + CJK'
    Assert-Equal 9 (Get-CqkDisplayWidth 'Keepalive') 'the longest ascii label in the panel'

    # -----------------------------------------------------------------------
    Start-TestGroup '§12 terminology mapping'
    Assert-Equal '仅监控（MonitorOnly）' (Format-ModeZh 'MonitorOnly') 'mode MonitorOnly'
    Assert-Equal '自动锚定（AutoAnchor）' (Format-ModeZh 'AutoAnchor') 'mode AutoAnchor'
    Assert-Equal '自动锚定（AutoAnchor）' (Format-ModeZh 'autoanchor') 'mode match is case-insensitive'
    Assert-Equal '未知（UNKNOWN）' (Format-ModeZh '') 'empty mode is unknown, not blank'
    Assert-Equal '负责人（LEADER）' (Format-RoleZh 'LEADER') 'role LEADER'
    Assert-Equal '待机节点（PASSIVE）' (Format-RoleZh 'PASSIVE') 'role PASSIVE'
    Assert-Equal '降级运行（DEGRADED）' (Format-RoleZh 'DEGRADED') 'role DEGRADED'
    Assert-Equal '退避中（BACKOFF）' (Format-RoleZh 'BACKOFF') 'role BACKOFF'
    Assert-Equal '未知（UNKNOWN）' (Format-RoleZh '') 'empty role'
    Assert-Equal '未知（UNKNOWN）' (Format-RoleZh 'NONSENSE') 'unmapped role degrades to 未知'
    Assert-Equal '负责人（LEADER）' (Format-RoleZh ' leader ') 'role is trimmed and case-folded'
    Assert-Equal '负责人（LEADER）' (Format-RoleZh 'leader') 'lower-case role maps, and names itself upper-case'
    Assert-Equal '5 小时' (Format-QuotaWindowNameZh 300) '300 minutes'
    Assert-Equal '7 天' (Format-QuotaWindowNameZh 10080) 'weekly'
    Assert-Equal '2 小时' (Format-QuotaWindowNameZh 120) 'other whole hours'
    Assert-Equal '45 分钟窗口' (Format-QuotaWindowNameZh 45) 'sub-hour window reads sensibly'
    Assert-Equal '0 分钟窗口' (Format-QuotaWindowNameZh $null) 'null minutes is not a crash'
    Assert-Equal '5 小时额度' (Format-QuotaWindowHeaderZh 300) 'header adds 额度'
    Assert-Equal '7 天额度' (Format-QuotaWindowHeaderZh 10080) 'weekly header'
    Assert-Equal '45 分钟窗口' (Format-QuotaWindowHeaderZh 45) 'a name already ending in 窗口 is not doubled'
    Assert-Equal '周期判断' (Format-WorkModeZh 'JUDGMENT') 'judgment'
    Assert-Equal '每日定时（Schedule）' (Format-WorkModeZh 'SCHEDULE') 'schedule'
    Assert-Equal '是' (Format-BooleanZh $true) 'true'
    Assert-Equal '否' (Format-BooleanZh $null) 'null is 否, not blank'

    # -----------------------------------------------------------------------
    Start-TestGroup '§13 severity tags and colours'
    Assert-Equal '[异常]' (Get-StatusSeverityTag 'ERROR') 'ERROR'
    Assert-Equal '[注意]' (Get-StatusSeverityTag 'WARNING') 'WARNING'
    Assert-Equal '[正常]' (Get-StatusSeverityTag 'HEALTHY') 'HEALTHY'
    Assert-Equal '[关闭]' (Get-StatusSeverityTag 'OFF') 'OFF'
    Assert-Equal '[信息]' (Get-StatusSeverityTag 'INFO') 'INFO'
    Assert-Equal '[信息]' (Get-StatusSeverityTag 'GARBAGE') 'unknown severity degrades to 信息'
    Assert-Equal 'Red' (Get-StatusSeverityColor 'ERROR') 'ERROR colour'
    Assert-Equal 'Yellow' (Get-StatusSeverityColor 'WARNING') 'WARNING colour'
    Assert-Equal 'Green' (Get-StatusSeverityColor 'HEALTHY') 'HEALTHY colour'
    Assert-Equal 'DarkGray' (Get-StatusSeverityColor 'OFF') 'OFF colour'
    Assert-Equal 'Cyan' (Get-StatusSeverityColor 'INFO') 'INFO colour'
    Assert-Equal '' (Get-StatusSeverityColor 'GARBAGE') 'unknown severity paints nothing'

    $o1 = Get-CqkTaskRunOutcomeZh 0 $Now
    Assert-Equal 'HEALTHY' $o1.severity 'exit code 0 is healthy'
    Assert-Equal '成功' $o1.text 'success text'
    Assert-Equal 'ERROR' (Get-CqkTaskRunOutcomeZh 1 $Now).severity 'any other code is a failure'
    Assert-Equal '退出码 1' (Get-CqkTaskRunOutcomeZh 1 $Now).text 'the code is shown, not hidden'
    Assert-Equal 'INFO' (Get-CqkTaskRunOutcomeZh 267009 $Now).severity '267009 (running) is not a failure'
    Assert-Equal 'INFO' (Get-CqkTaskRunOutcomeZh 267010 $Now).severity '267010 (ready) is not a failure'
    Assert-Equal 'INFO' (Get-CqkTaskRunOutcomeZh 267011 $Now).severity '267011 (never ran) is not a failure'
    $oNone = Get-CqkTaskRunOutcomeZh $Null $Null
    Assert-Equal '尚未运行' $oNone.text 'no result and no run time'
    Assert-Equal '状态未知' (Get-CqkTaskRunOutcomeZh $Null $Now).text 'a run time with no result is unknown, not success'

    # -----------------------------------------------------------------------
    Start-TestGroup 'Format-StatusDateTime: never show a default DateTime'
    Assert-Equal '' (Format-StatusDateTime $null) 'null'
    Assert-Equal '' (Format-StatusDateTime '') 'empty string'
    Assert-Equal '' (Format-StatusDateTime 'not a date') 'unparseable'
    Assert-Equal '' (Format-StatusDateTime ([datetime]'0001-01-01')) 'DateTime.MinValue is "never"'
    Assert-Equal '2026-09-09 12:00:00' (Format-StatusDateTime $Now) 'default pattern has seconds'
    Assert-Equal '2026-09-09 12:00' (Format-StatusDateTime $Now 'yyyy-MM-dd HH:mm') 'minute pattern for quota/anchor rows'

    # -----------------------------------------------------------------------
    Start-TestGroup 'Get-NextScheduleSlotZh'
    Assert-Equal '21:00' (Get-NextScheduleSlotZh -Slots @('09:30', '21:00') -Now $Now) 'first slot ahead of now'
    Assert-Equal '明日 09:30' (Get-NextScheduleSlotZh -Slots @('09:30', '21:00') -Now (Get-Date '2026-09-09 22:00:00')) 'after the last slot rolls to tomorrow'
    Assert-Equal '明日 09:30' (Get-NextScheduleSlotZh -Slots @('21:00', '09:30') -Now (Get-Date '2026-09-09 22:00:00')) 'unsorted input is sorted before picking tomorrow'
    Assert-Equal '09:30' (Get-NextScheduleSlotZh -Slots @('21:00', '09:30') -Now (Get-Date '2026-09-09 08:00:00')) 'unsorted input is sorted before picking today'
    Assert-Equal '' (Get-NextScheduleSlotZh -Slots @() -Now $Now) 'no slots, no next slot'
    Assert-Equal '21:00' (Get-NextScheduleSlotZh -Slots @('not-a-time', '21:00') -Now $Now) 'a malformed slot is skipped, not sorted first'
    Assert-Equal '' (Get-NextScheduleSlotZh -Slots @('25:99') -Now $Now) 'an out-of-range slot is not a candidate'
    Assert-Equal '09:30' (Get-NextScheduleSlotZh -Slots @('9:30') -Now (Get-Date '2026-09-09 08:00:00')) 'single-digit hour is normalised'
    # Boundary: a slot exactly at the clock reading is already past, so it rolls to
    # tomorrow. Pinned because ">=" here would silently mean the panel claims a slot
    # the runner has already consumed.
    Assert-Equal '明日 12:00' (Get-NextScheduleSlotZh -Slots @('12:00') -Now $Now) 'a slot equal to now is not "next"'

    # -----------------------------------------------------------------------
    Start-TestGroup '§15.2 derived fields on Get-StatusDisplayModel'
    $wsM = New-TestWorkspace
    try {
        $rootM = Join-Path $wsM 'keeper'
        New-Item -ItemType Directory -Force -Path (Join-Path $rootM 'runtime\logs') | Out-Null
        $state = New-KeeperState
        $state.anchors = @{ day = $Today; count = 3; lastAnchorAt = (Format-GoldenStamp $Now.AddMinutes(-20)) }
        Write-JsonFileAtomic (Get-StatePath $rootM) $state

        $cfgM = New-GoldenConfig -Coordination $false -AutoAnchor $true
        $stM = New-DisplayStatus @{
            autoAnchor      = $true; mode = 'AutoAnchor'
            quota           = Get-GoldenFreshQuota
            anchorKeepalive = @{ intervalMinutes = 300; lastAnchorAt = (Format-GoldenStamp $Now.AddMinutes(-20)) }
        }
        $avM = Get-StatusAssessment -Status $stM -Config $cfgM -KeeperRoot $rootM -Now $Now
        $m = Get-StatusDisplayModel -Status $stM -Assessment $avM -Config $cfgM -KeeperRoot $rootM -Now $Now

        Assert-Equal 'HEALTHY' $m.overall 'healthy status is HEALTHY'
        Assert-Equal '运行正常' $m.summary 'summary comes from the assessment, not a local guess'
        Assert-Equal '自动锚定（AutoAnchor）' $m.modeText 'mode text comes from the status mode'
        Assert-Equal 60 $m.pollMinutes 'poll minutes passed through'

        # today: state.anchors for today's date, not yesterday's count.
        Assert-Equal 3 $m.autoAnchor.today 'today count read from state.json'
        Assert-Equal 300 $m.autoAnchor.keepalive 'keepalive minutes passed through'
        Assert-Equal 300 $m.autoAnchor.minGap 'minimumGapMinutes threaded from the config'
        Assert-Equal 6 $m.autoAnchor.maxPerDay 'maxPerDay threaded from the config'

        # The day-stamp rule, then the same rule seen through the whole panel: a
        # state file whose anchors.day is yesterday must produce both today=0 in the
        # model and no cap finding in the verdict, because both read one helper.
        $stateY = New-KeeperState
        $stateY.anchors = @{ day = $Now.AddDays(-1).ToString('yyyy-MM-dd'); count = 6 }
        Assert-Equal 0 (Get-StatusAnchorToday -State $stateY -Today $Today) "yesterday's 6 is today's 0"
        Assert-Equal 6 (Get-StatusAnchorToday -State $stateY -Today $Now.AddDays(-1).ToString('yyyy-MM-dd')) 'and is the count for its own day'
        Assert-Equal 0 (Get-StatusAnchorToday -State (New-KeeperState) -Today $Today) 'fresh state has no anchors'
        Assert-Equal 0 (Get-StatusAnchorToday -State $null -Today $Today) 'null state is 0, not a crash'
        $rootY = Join-Path $wsM 'keeper-yesterday'
        New-Item -ItemType Directory -Force -Path (Join-Path $rootY 'runtime\logs') | Out-Null
        Write-JsonFileAtomic (Get-StatePath $rootY) $stateY
        $avY = Get-StatusAssessment -Status $stM -Config $cfgM -KeeperRoot $rootY -Now $Now
        $mY = Get-StatusDisplayModel -Status $stM -Assessment $avY -Config $cfgM -KeeperRoot $rootY -Now $Now
        Assert-Equal 0 $mY.autoAnchor.today 'yesterday-at-cap renders as 0 today'
        Assert-Null (Get-StatusFinding -Assessment $avY -Code 'ANCHOR_CAP_REACHED') 'yesterday-at-cap raises no cap finding'
        Assert-NotNull (Get-StatusFinding -Assessment $avM -Code 'ANCHOR_GAP_COOLDOWN') '20 min after an anchor with a 300 min gap is a cooldown'
        Assert-Equal 'INFO' (Get-StatusFinding -Assessment $avM -Code 'ANCHOR_GAP_COOLDOWN').severity 'a cooldown is information, not a fault'

        # workMode is derived from the slots the collector reported, not from a flag.
        Assert-Equal 'JUDGMENT' $m.autoAnchor.workMode 'no slots means judgment mode'
        Assert-Equal '' $m.autoAnchor.nextSlot 'judgment mode has no next slot'
        $stSched = New-DisplayStatus @{
            autoAnchor     = $true; mode = 'AutoAnchor'
            anchorSchedule = @{ slots = @('09:30', '21:00') }
            quota          = Get-GoldenFreshQuota
        }
        $mS = Get-StatusDisplayModel -Status $stSched -Assessment $avM -Config $cfgM -KeeperRoot $rootM -Now $Now
        Assert-Equal 'SCHEDULE' $mS.autoAnchor.workMode 'slots present means schedule mode'
        Assert-Equal '21:00' $mS.autoAnchor.nextSlot 'next slot derived'
        Assert-Equal '09:30|21:00' ($mS.autoAnchor.slots -join '|') 'slots preserved in collector order'
        $stBlankSlot = New-DisplayStatus @{ autoAnchor = $true; mode = 'AutoAnchor'; anchorSchedule = @{ slots = @('09:30', '', '  ') } }
        $mBlank = Get-StatusDisplayModel -Status $stBlankSlot -Config $cfgM -KeeperRoot $rootM -Now $Now
        Assert-Equal '09:30' ($mBlank.autoAnchor.slots -join '|') 'blank slots are dropped, not rendered as empty columns'
        Assert-Equal 'SCHEDULE' $mBlank.autoAnchor.workMode 'a single real slot is still schedule mode'

        # §15.2 remainingPct = max(0, 100 - usedPercent)
        $mWindows = [object[]]$m.quota.windows
        Assert-Equal 2 $mWindows.Count 'both windows carried through'
        Assert-Equal '5 小时额度' $mWindows[0].header 'window header'
        Assert-Equal 12 $mWindows[0].usedPercent 'used percent passed through'
        Assert-Equal 88 $mWindows[0].remainingPct 'remaining = 100 - used'
        Assert-Equal '2026-09-09 18:00' $mWindows[0].resetText 'reset rendered at minute precision from a host-local epoch'
        Assert-Equal '7 天额度' $mWindows[1].header 'weekly header'
        Assert-Equal 63 $mWindows[1].remainingPct 'weekly remaining'
        $stOver = New-DisplayStatus @{ quota = @{
            lastReadAt = (Format-GoldenStamp $Now); stale = $false
            windows    = @(
                @{ bucketId = 'default'; minutes = 300; usedPercent = 120; resetsAt = 0; usable = $false },
                @{ bucketId = 'pro';     minutes = 45;  usedPercent = 0;   resetsAt = 0; usable = $true }
            )
        } }
        $mOver = Get-StatusDisplayModel -Status $stOver -Config $cfgM -KeeperRoot $rootM -Now $Now
        $overWindows = [object[]]$mOver.quota.windows
        Assert-Equal 0 $overWindows[0].remainingPct 'a >100% report clamps to 0, never negative'
        Assert-Equal '45 分钟窗口' $overWindows[1].header 'a non-standard window still gets a name'
        Assert-Equal 'pro' $overWindows[1].bucketId 'a non-default bucket id survives for the renderer to show'

        # §16.5: an empty model must never render as an empty value.
        Assert-Equal '沿用 CLI 默认' $m.autoAnchor.modelText 'empty model'
        Assert-Equal '沿用 CLI 默认' $m.autoAnchor.effortText 'empty effort'
        $stExec = New-DisplayStatus @{ anchorExec = @{ model = 'gpt-5-codex'; reasoningEffort = 'low' } }
        $mExec = Get-StatusDisplayModel -Status $stExec -Assessment $avM -Config $cfgM -KeeperRoot $rootM -Now $Now
        Assert-Equal 'gpt-5-codex' $mExec.autoAnchor.modelText 'configured model shown'
        Assert-Equal 'low' $mExec.autoAnchor.effortText 'configured effort shown'

        # 数据状态 reads the verdict stream, so it cannot drift from the finding.
        Assert-Equal '最新' $m.quota.statusText 'fresh data'
        Assert-Equal 'HEALTHY' $m.quota.severity 'fresh data is not a warning'
        $stNever = New-DisplayStatus @{ quota = @{ lastReadAt = ''; stale = $false; windows = @() } }
        $avNever = Get-StatusAssessment -Status $stNever -Config $cfgM -KeeperRoot $rootM -Now $Now
        $mNever = Get-StatusDisplayModel -Status $stNever -Assessment $avNever -Config $cfgM -KeeperRoot $rootM -Now $Now
        Assert-NotNull (Get-StatusFinding -Assessment $avNever -Code 'QUOTA_NEVER_READ') 'the verdict reports a never-read quota'
        Assert-Equal '尚无数据' $mNever.quota.statusText 'never read'
        Assert-Equal 'WARNING' $mNever.quota.severity 'never read warns'
        Assert-Equal '' $mNever.quota.lastReadAt 'a never-read quota has no last-read text'
        $stStale = New-DisplayStatus @{ quota = @{ lastReadAt = (Format-GoldenStamp $Now.AddDays(-2)); stale = $true; windows = @() } }
        $mStale = Get-StatusDisplayModel -Status $stStale -Config $cfgM -KeeperRoot $rootM -Now $Now
        Assert-Equal '已过期' $mStale.quota.statusText 'stale data wins the label over merely-too-old'
        Assert-Equal '2026-09-07 12:00:00' $mStale.quota.lastReadAt 'stale timestamp still rendered'
        # And the raw form is preserved only for -Detailed.
        Assert-Equal (Format-GoldenStamp $Now.AddDays(-2)) $mStale.quota.rawReadAt 'raw read time kept for the debug section'

        # role / coordination derivation
        Assert-Equal $true $m.coord.localOnly 'localOnly passed through'
        Assert-Equal '负责人（LEADER）' $m.coord.roleDisplay 'role mapped to Chinese'
        Assert-Equal '' $m.coord.leaseExpiresAt 'a LOCAL_ONLY status has no lease to show'
        $stMulti = New-GoldenStatus @{ role = @{ role = 'PASSIVE'; leaderOwner = 'machine-b'; leaderLabel = 'Office PC'; leaseExpiresAt = (Format-GoldenStamp $Now.AddMinutes(30)); localOnly = $false } }
        $mMulti = Get-StatusDisplayModel -Status $stMulti -Config (New-GoldenConfig) -KeeperRoot $rootM -Now $Now
        Assert-Equal $false $mMulti.coord.localOnly 'multi-machine mode'
        Assert-Equal '待机节点（PASSIVE）' $mMulti.coord.roleDisplay 'non-leader role mapped'
        Assert-Equal '2026-09-09 12:30:00' $mMulti.coord.leaseExpiresAt 'lease expiry rendered'
        Assert-Equal 'machine-b' $mMulti.coord.leaderOwner 'leader identity survives for the renderer'

        # Config may be omitted: the model loads it from disk itself rather than
        # printing zeros, which is how status.ps1 gets 最小间隔 right.
        $wsCfg = Join-Path $wsM 'keeper-cfg'
        New-Item -ItemType Directory -Force -Path (Join-Path $wsCfg 'runtime\logs') | Out-Null
        # Write-TestConfigFile echoes the path it wrote, so silence it: a stray
        # string in the test output reads as a failure line.
        $null = Write-TestConfigFile -Path (Get-ConfigPath $wsCfg) -Config $cfgM
        $mNoCfg = Get-StatusDisplayModel -Status $stM -Assessment $avM -KeeperRoot $wsCfg -Now $Now
        Assert-Equal 300 $mNoCfg.autoAnchor.minGap 'minimumGapMinutes falls back to Load-Config'
        Assert-Equal 6 $mNoCfg.autoAnchor.maxPerDay 'maxPerDay falls back to Load-Config'
        # And with no config file at all the model must not invent a limit.
        $mNoFile = Get-StatusDisplayModel -Status $stM -Assessment $avM -KeeperRoot $rootBase -Now $Now
        Assert-Equal 0 $mNoFile.autoAnchor.minGap 'no config file on disk means no claimed gap'
    } finally { Remove-TestWorkspace $wsM }

    # -----------------------------------------------------------------------
    Start-TestGroup '§11 panel shape: sections, labels, alignment'
    $texts = Get-RowText (Get-StatusDisplayLines -Status (New-GoldenStatus @{ quota = Get-GoldenFreshQuota } -LocalOnly) `
        -Config (New-GoldenConfig -Coordination $false -AutoAnchor $true -Schedule @('09:30', '21:00')) `
        -KeeperRoot $rootBase -Now $Now)
    Assert-Equal 'Codex Quota Keeper 状态' $texts[0] 'title is the first line'
    Assert-Equal ('=' * 60) $texts[1] 'title rule'
    foreach ($sec in @('【总体状态】', '【计划任务】', '【Codex】', '【AutoAnchor 自动锚定】', '【多机协调】', '【Codex 额度】', '【异常与建议】')) {
        Assert-Contains $texts $sec "section $sec present"
    }
    Assert-Equal ('=' * 60) $texts[($texts.Count - 1)] 'closing rule'
    $checked = Test-RowAlignment $texts
    Assert-True ($checked -ge 12) "alignment sweep examined real rows (got $checked)"

    # A label longer than the column must degrade to one space, not to a negative
    # pad (' ' * -1 throws) and not to a mashed-together row.
    $longLines = New-Object 'System.Collections.Generic.List[object]'
    Write-StatusRow $longLines -Label '这是一个远超列宽的超长标签名称' -Value 'v'
    $longText = (Get-RowText $longLines)[0]
    Assert-True $longText.EndsWith(': v') 'long label row still ends with its value'
    Assert-Equal 1 (Test-RowAlignment @($longText)) 'the degraded single space is what the sweep expects'
    # An empty value must not leave a trailing space (snapshots compare whole lines).
    $emptyLines = New-Object 'System.Collections.Generic.List[object]'
    Write-StatusRow $emptyLines -Label '功能状态' -Value '' -Color 'DarkGray'
    $emptyText = [string](Get-RowText $emptyLines)[0]
    Assert-False $emptyText.EndsWith(' ') 'empty value is trimmed, no trailing space'
    Assert-Equal '  功能状态        :' $emptyText 'and the row keeps its label and colon'

    # The §11.1 wording the panel must show verbatim for the two modes.
    $panelOff = Get-StatusDisplayLines -Status (New-GoldenStatus @{ quota = Get-GoldenFreshQuota } -LocalOnly) `
        -Config (New-GoldenConfig -Coordination $false) -KeeperRoot $rootBase -Now $Now
    $offTexts = Get-RowText $panelOff
    Assert-Equal '  功能状态        : [关闭]' (Get-RowLine $panelOff '功能状态') 'AutoAnchor off shows the tag as the value, unprefixed'
    Assert-Contains $offTexts '  说明            : 当前只读取额度，不会自动调用模型' 'DoD: 明确显示不会调用模型'
    Assert-Equal '  当前状态        : [正常] 运行正常' (Get-RowLine $panelOff '当前状态') 'a healthy monitor-only box reads as normal, not as degraded'
    Assert-Equal '  本机名称        : Home PC' (Get-RowLine $panelOff '本机名称') 'machine label'
    Assert-Equal '  本机 ID         : 4f90abcd-1234' (Get-RowLine $panelOff '本机 ID') 'machine id label keeps its ascii spacing'
    Assert-Equal '  当前模式        : 单机模式（LOCAL_ONLY）' (Get-RowLine $panelOff '当前模式') 'DoD: LOCAL_ONLY reads as a mode, not an alarm'
    Assert-Equal '未执行' ([string](Get-RowLine $panelOff '实时连接检测').Split(':')[-1]).Trim() 'live probe not run is stated plainly'
    # 功能状态 [关闭] is painted DarkGray without a second text tag (§11.1's value IS the tag).
    $offPainted = Capture-Console { Write-StatusConsole $panelOff }
    $offByIndex = @{}
    for ($i = 0; $i -lt $offTexts.Count; $i++) { $offByIndex[$offTexts[$i]] = (Get-CapturedColor $offPainted[$i]) }
    Assert-Equal 'DarkGray' $offByIndex['  功能状态        : [关闭]'] 'the OFF row is DarkGray'
    Assert-Equal 'Green' $offByIndex['  当前状态        : [正常] 运行正常'] 'the healthy row is Green'

    $panelOn = Get-StatusDisplayLines -Status (New-GoldenStatus @{
        autoAnchor      = $true; mode = 'AutoAnchor'
        anchorKeepalive = @{ intervalMinutes = 300; lastAnchorAt = $null }
        quota           = Get-GoldenFreshQuota
    } -LocalOnly) -Config (New-GoldenConfig -Coordination $false -AutoAnchor $true) -KeeperRoot $rootBase -Now $Now
    $onTexts = Get-RowText $panelOn
    Assert-Contains $onTexts '  功能状态        : [注意] 已开启（Experimental）' 'AutoAnchor on warns: it consumes quota'
    Assert-Contains $onTexts '  说明            : 该功能会主动调用 Codex 模型并消耗额度' 'the cost warning is in the section the user is reading'
    Assert-Contains $onTexts '  触发方式        : 窗口重置 / 首次空闲检测 / Keepalive' 'judgment mode lists its triggers'
    Assert-Contains $onTexts '  最小间隔        : 300 分钟' 'the configured gap is shown'
    Assert-Contains $onTexts '  Keepalive       : 300 分钟' 'the configured keepalive is shown'
    Assert-Contains $onTexts '  每日上限        : 6 次' 'the configured cap is shown'
    Assert-Contains $onTexts '  执行模型        : 沿用 CLI 默认' 'empty model never renders as an empty value'
    Assert-Contains $onTexts '  思考等级        : 沿用 CLI 默认' 'empty effort likewise'
    Assert-RowValue $panelOn '工作模式' '周期判断' 'judgment mode named'
    Assert-RowValue $panelOn '今日已执行' '0 / 6' 'an empty day reads 0 of the cap'
    Assert-RowValue $panelOn '数据状态' '[正常] 最新' 'fresh quota'
    Assert-False (@($onTexts | Where-Object { $_.Contains('下一个槽位') }).Count -gt 0) 'judgment mode has no next-slot row'
    Assert-False (@($onTexts | Where-Object { $_.Contains('上次执行') }).Count -gt 0) 'no anchor yet means no 上次执行 row'
    $checkedOn = Test-RowAlignment $onTexts
    Assert-True ($checkedOn -ge 14) "AutoAnchor rows examined by the sweep (got $checkedOn)"

    # Schedule mode replaces the trigger list and states plainly that judgment is off.
    $panelSched = Get-StatusDisplayLines -Status (New-GoldenStatus @{
        autoAnchor     = $true; mode = 'AutoAnchor'
        anchorSchedule = @{ slots = @('09:30', '21:00') }
        quota          = Get-GoldenFreshQuota
    } -LocalOnly) -Config (New-GoldenConfig -Coordination $false -AutoAnchor $true -Schedule @('09:30', '21:00')) -KeeperRoot $rootBase -Now $Now
    $stTexts = Get-RowText $panelSched
    Assert-Contains $stTexts '  工作模式        : 每日定时（Schedule）' 'schedule mode named'
    Assert-Contains $stTexts '  定时时间        : 09:30、21:00' 'slots are 、-separated'
    Assert-Contains $stTexts '  周期判断        : 已停用（reset / idle / keepalive 不触发）' 'judgment explicitly off, not implied'
    Assert-Contains $stTexts '  下一个槽位      : 21:00' 'next slot shown'
    Assert-False (@($stTexts | Where-Object { $_.Contains('触发方式') }).Count -gt 0) 'schedule mode does not show the judgment trigger list'
    Assert-False (@($stTexts | Where-Object { $_.Contains('最小间隔') }).Count -gt 0) 'schedule mode does not quote the judgment-only gap'
    # §11.3 sample rows carry no severity tags in this block - an [信息] on every
    # line makes the row that matters read as noise.
    $taggedSchedule = @($stTexts | Where-Object { $_ -match '^\s+(定时时间|周期判断|工作模式|下一个槽位)' -and $_ -match '\[' }).Count
    Assert-Equal 0 $taggedSchedule 'schedule block rows stay untagged'

    # The verdict the panel prints is the assessment's verdict, not its own opinion.
    $cases = Get-GoldenCases
    $c4 = $cases['multi-pc-error']
    $panelBad = Get-StatusDisplayLines -Status $c4.Status -Config $c4.Config -KeeperRoot $rootBase -Now $Now
    $badTexts = Get-RowText $panelBad
    Assert-Contains $badTexts '  当前状态        : [异常] 运行异常' 'overall follows the assessment'
    Assert-Contains $badTexts '  当前锚定        : [异常] 当前自动锚定被安全阻止' '§16.5 block is stated in the AutoAnchor section, not only at the bottom'
    Assert-Contains $badTexts '                    建议：按下述原因解除阻止；这是保护机制，不是锚定功能故障' 'advice sits under the row it applies to, at the value column'
    Assert-Contains $badTexts '  数据状态        : [注意] 已过期' 'stale quota label follows the finding'
    # At the cap the count itself is the news (§16.5), so that one row is tagged.
    $wsCap = New-TestWorkspace
    try {
        $rootCap = Join-Path $wsCap 'keeper'
        New-Item -ItemType Directory -Force -Path (Join-Path $rootCap 'runtime\logs') | Out-Null
        $capState = New-KeeperState
        $capState.anchors = @{ day = $Today; count = 6; lastAnchorAt = (Format-GoldenStamp $Now.AddHours(-3)) }
        Write-JsonFileAtomic (Get-StatePath $rootCap) $capState
        $stCap = New-DisplayStatus @{
            autoAnchor      = $true; mode = 'AutoAnchor'
            quota           = Get-GoldenFreshQuota
            anchorKeepalive = @{ intervalMinutes = 300; lastAnchorAt = (Format-GoldenStamp $Now.AddHours(-3)) }
        }
        $capTexts = Get-RowText (Get-StatusDisplayLines -Status $stCap -Config (New-GoldenConfig -Coordination $false -AutoAnchor $true) -KeeperRoot $rootCap -Now $Now)
        Assert-Contains $capTexts '  今日已执行      : [注意] 6 / 6' 'a capped day is tagged'
        Assert-Contains $capTexts '  当前锚定        : [注意] 今日锚定已达上限' 'and the guard reason is shown in the same section'
        Assert-False (@($capTexts | Where-Object { $_.Contains('[异常] 当前自动锚定被安全阻止') }).Count -gt 0) 'a configured cap is not reported as a block'
    } finally { Remove-TestWorkspace $wsCap }

    # -----------------------------------------------------------------------
    Start-TestGroup 'Write-StatusRow: -Severity and -Color are mutually exclusive'
    $guardLines = New-Object 'System.Collections.Generic.List[object]'
    $threw = $false
    try { Write-StatusRow $guardLines -Label 'x' -Value 'y' -Severity 'ERROR' -Color 'Red' } catch { $threw = $true }
    Assert-True $threw 'passing both throws rather than silently dropping one'
    # -Color alone is the legitimate mid-value-tag case, and must NOT throw even
    # when the caller passes the empty string explicitly (what the renderer does).
    $ok = $true
    try { Write-StatusRow $guardLines -Label 'x' -Value 'y' -Color '' } catch { $ok = $false }
    Assert-True $ok 'explicit empty -Color is not a conflict'
    $okSev = $true
    try { Write-StatusRow $guardLines -Label 'x' -Value 'y' -Severity 'ERROR' } catch { $okSev = $false }
    Assert-True $okSev '-Severity alone is fine'
    # The row that threw must not have been appended either, or a mistake would
    # leave half a row on the console.
    $guardTexts = Get-RowText $guardLines
    Assert-Equal 2 $guardTexts.Count 'only the accepted rows exist'
    # pad = 18 - 2 - 1 = 15 cells after the label, and -Severity adds '[异常] '.
    # The -Severity call was the second one, so it is the last row - both calls
    # used label 'x', and Get-RowLine would return the first.
    Assert-Equal '  x               : y' $guardTexts[0] 'explicit -Color paints without tagging'
    Assert-Equal '  x               : [异常] y' $guardTexts[1] '-Severity tags and paints in one step'

    # -----------------------------------------------------------------------
    Start-TestGroup '§13 colour contract on the console and under -NoColor'
    $cLines = New-Object 'System.Collections.Generic.List[object]'
    Add-StatusLine $cLines 'plain-row' ''
    Add-StatusLine $cLines 'red-row' 'Red'
    Add-StatusLine $cLines 'cyan-row' 'Cyan'
    $painted = Capture-Console { Write-StatusConsole $cLines }
    Assert-Equal 3 $painted.Count 'one record per line'
    Assert-Equal 'plain-row' (Get-CapturedText $painted[0]) 'text preserved exactly'
    Assert-True ($script:SevColors -notcontains (Get-CapturedColor $painted[0])) 'a row with no colour is not painted a severity colour'
    Assert-Equal 'Red' (Get-CapturedColor $painted[1]) 'Red row painted Red'
    Assert-Equal 'Cyan' (Get-CapturedColor $painted[2]) 'Cyan row painted Cyan'
    $silent = Capture-Console { Write-StatusConsole $cLines -NoColor }
    Assert-Equal 3 $silent.Count 'NoColor still writes every line'
    for ($i = 0; $i -lt 3; $i++) {
        Assert-Equal (Get-CapturedText $painted[$i]) (Get-CapturedText $silent[$i]) 'the same lines reach the console'
        Assert-True ($script:SevColors -notcontains (Get-CapturedColor $silent[$i])) "NoColor leaves row $i unpainted"
    }

    # Whole-panel version of the same check: with colour off nothing is painted with
    # a severity colour, and the text is byte-identical to the painted pass.
    $paintedPanel = Capture-Console { Write-StatusConsole $panelOn }
    $silentPanel = Capture-Console { Write-StatusConsole $panelOn -NoColor }
    Assert-Equal $paintedPanel.Count $silentPanel.Count 'same number of records'
    $diffText = 0
    $coloredWhenQuiet = 0
    for ($i = 0; $i -lt $paintedPanel.Count; $i++) {
        if ((Get-CapturedText $paintedPanel[$i]) -ne (Get-CapturedText $silentPanel[$i])) { $diffText++ }
        if ($script:SevColors -contains (Get-CapturedColor $silentPanel[$i])) { $coloredWhenQuiet++ }
    }
    Assert-Equal 0 $diffText 'NoColor changes paint, never content'
    Assert-Equal 0 $coloredWhenQuiet 'NoColor leaves no severity colour behind'
    # And the panel does paint something when colour is on - otherwise the loop
    # above would pass on a renderer that dropped all colour.
    $coloredWhenOn = @($paintedPanel | Where-Object { $script:SevColors -contains (Get-CapturedColor $_) }).Count
    Assert-True ($coloredWhenOn -gt 0) "colour-on pass actually paints ($coloredWhenOn rows)"
    # The [tag] prefixes are what makes colour optional: every painted row says the
    # same thing in its text, so a colour-blind or legacy-codepage console loses
    # nothing. 异常与建议 rows are the panel's whole colour contract in one place.
    $badPainted = Capture-Console { Write-StatusConsole $panelBad }
    $redWithoutTag = @()
    for ($i = 0; $i -lt $badPainted.Count; $i++) {
        if ((Get-CapturedColor $badPainted[$i]) -eq 'Red' -and -not (Get-CapturedText $badPainted[$i]).Contains('[异常]')) {
            $redWithoutTag += (Get-CapturedText $badPainted[$i])
        }
    }
    Assert-Equal 0 $redWithoutTag.Count 'every red row also says [异常] in text'

    # -----------------------------------------------------------------------
    Start-TestGroup '§13 no ANSI bytes anywhere in the text views'
    $panelText = Format-StatusText $panelOn
    # ESC is the only way an ANSI sequence can start; a literal in the source would
    # show up here, and so would one arriving through a pipeline or a file.
    $esc = [char]27
    Assert-False $panelText.Contains($esc) 'Format-StatusText contains no escape byte'
    foreach ($t in (Get-RowText $panelOn)) { Assert-False ([string]$t).Contains($esc) 'no line carries an escape byte' }
    Assert-Equal $panelOn.Count (@($panelText -split "`r?`n")).Count 'the text view has exactly one line per row object'
    # Redirected output keeps the meaning: every severity row still has its prefix.
    Assert-True $panelText.Contains('[注意] 已开启（Experimental）') 'tag survives the text view'
    Assert-True $panelText.Contains([Environment]::NewLine) 'joined with the platform newline, not a hardcoded one'
    Assert-Equal 'Codex Quota Keeper 状态' (@($panelText -split "`r?`n"))[0] 'the text view starts at the title'
    Assert-Equal ('=' * 60) (@($panelText -split "`r?`n"))[-1] 'and ends at the closing rule'

    # -----------------------------------------------------------------------
    Start-TestGroup 'List[object] coercion: the crash that @() caused'
    # Get-StatusDisplayLines hands back its List[object], which PowerShell unrolls on
    # output; foreach ($x in @($list)) throws "Argument types do not match" on BOTH
    # runtimes, so Write-StatusConsole casts instead - this is the regression guard
    # for that fix, on the shapes the renderer actually passes.
    $rawList = New-Object 'System.Collections.Generic.List[object]'
    [void]$rawList.Add((New-StatusLine 'a' 'Red'))
    [void]$rawList.Add((New-StatusLine 'b' ''))
    $listOk = $true
    try { $null = Capture-Console { Write-StatusConsole $rawList } } catch { $listOk = $false }
    Assert-True $listOk 'a raw List[object] renders without throwing'
    Assert-Equal 2 ([object[]]$rawList).Count 'the cast the fix relies on enumerates the List'
    Assert-Equal 0 ([object[]]$null).Count 'and $null coerces to an empty array'
    $one = New-StatusLine 'single' 'Green'
    Assert-Equal 1 ([object[]]$one).Count 'a lone line hashtable still coerces'
    $singleOk = $true
    try { $single = Capture-Console { Write-StatusConsole $one } } catch { $singleOk = $false }
    Assert-True $singleOk 'a lone hashtable renders'
    $singleRecords = [object[]]$single
    Assert-Equal 1 $singleRecords.Count 'exactly one record'
    Assert-Equal 'single' (Get-CapturedText $singleRecords[0]) 'and renders its text'
    Assert-Equal 'Green' (Get-CapturedColor $singleRecords[0]) 'and its colour'
    $nullOk = $true
    try { $nullOut = Capture-Console { Write-StatusConsole $null } } catch { $nullOk = $false }
    Assert-True $nullOk 'null renders nothing rather than throwing'
    Assert-Equal 0 @($nullOut | Where-Object { $null -ne $_ }).Count 'null produces no console records'
    Assert-Equal 2 (Get-RowText $rawList).Count 'Get-RowText survives the same List shape'
    Assert-Equal 1 (Get-RowText $one).Count 'and a lone hashtable'

    # -----------------------------------------------------------------------
    Start-TestGroup '§14 -Language en-US stays the pre-v2.0 fact dump'
    $enTexts = Get-RowText (Get-StatusDisplayLines -Status (New-GoldenStatus @{ quota = Get-GoldenFreshQuota } -LocalOnly) -Language 'en-US')
    Assert-Equal 'Codex Quota Keeper Status' $enTexts[0] 'English title unchanged'
    Assert-Contains $enTexts 'Distributed leader  : none - LOCAL-ONLY MODE (MULTI-PC UNSAFE)' 'English leader line unchanged'
    Assert-Contains $enTexts 'AutoAnchor          : OFF (experimental feature)' 'English AutoAnchor line unchanged'
    Assert-Contains $enTexts 'Last quota read     : 2026-09-09 11:55:00' 'English quota read time unchanged'
    Assert-Contains $enTexts ' 5h window     : 12% used, reset 2026-09-09 18:00' 'English window line unchanged'
    # The English view must carry no Chinese at all: it is what status-json adjacent
    # tooling and CI logs read.
    $cjk = [regex]'[一-鿿]'
    Assert-False $cjk.IsMatch(($enTexts -join '|')) 'English view has no CJK'
    # And the language switch is not a colour switch: the English view is unpainted.
    $enPainted = Capture-Console { Write-StatusConsole (Get-StatusDisplayLines -Status (New-GoldenStatus @{ quota = Get-GoldenFreshQuota } -LocalOnly) -Language 'en-US') }
    $enColored = @($enPainted | Where-Object { $script:SevColors -contains (Get-CapturedColor $_) }).Count
    Assert-Equal 0 $enColored 'the maintainer view is never painted'

    # -----------------------------------------------------------------------
    Start-TestGroup '-Detailed adds the debug section without touching the normal rows'
    $plainStatus = New-GoldenStatus @{ quota = Get-GoldenFreshQuota } -LocalOnly
    $plainCfg = New-GoldenConfig -Coordination $false
    $plain = Get-RowText (Get-StatusDisplayLines -Status $plainStatus -Config $plainCfg -KeeperRoot $rootBase -Now $Now)
    $verb = Get-RowText (Get-StatusDisplayLines -Status $plainStatus -Config $plainCfg -KeeperRoot $rootBase -Now $Now -Detailed)
    Assert-Contains $verb '【调试详情】' 'debug section appears'
    Assert-False (@($plain | Where-Object { $_ -eq '【调试详情】' }).Count -gt 0) 'and only with -Detailed'
    Assert-Contains $verb '  原始总体判定    : HEALTHY' 'raw verdict exposed'
    Assert-Contains $verb '  配置有效        : 是' 'configOk exposed'
    Assert-Contains $verb '  协调启用        : 否' 'coordination exposed'
    Assert-Contains $verb '  额度原始时间    : 2026-09-09 11:55:00' 'the unformatted read time is reachable, not only the panel text'
    # Everything above the debug section is identical, so the flag cannot reorder it.
    $cutIndex = @($verb).Count
    for ($i = 0; $i -lt @($verb).Count; $i++) { if ($verb[$i] -eq '【调试详情】') { $cutIndex = $i; break } }
    Assert-Equal (($plain | Select-Object -First $cutIndex) -join '|') (($verb | Select-Object -First $cutIndex) -join '|') 'normal rows are untouched by -Detailed'
    Assert-True (@($verb).Count -gt @($plain).Count) 'the extra rows are only ever appended'
    # INFO findings are hidden from the normal panel (§11.1) but not from -Detailed;
    # this is the only view where the raw English detail string may appear.
    $verbBad = Get-RowText (Get-StatusDisplayLines -Status $c4.Status -Config $c4.Config -KeeperRoot $rootBase -Now $Now -Detailed)
    Assert-True (@($verbBad | Where-Object { $_ -match '详情：.*\[(ERROR|WARNING)/' }).Count -gt 0) 'detail lines carry the raw evidence with its code'
    Assert-False (@($badTexts | Where-Object { $_.StartsWith('                    详情：') }).Count -gt 0) 'and the normal panel shows none'

    # -----------------------------------------------------------------------
    Start-TestGroup '§18 sanitisation reaches the panel, not just the verdict'
    $wsE = New-TestWorkspace
    try {
        $rootE = Join-Path $wsE 'keeper'
        New-Item -ItemType Directory -Force -Path (Join-Path $rootE 'runtime\logs') | Out-Null
        $secret = 'ghp_' + ('Z' * 30)
        $stE = New-GoldenStatus @{ lastError = "auth failed token=$secret" } -LocalOnly
        $flatE = (Get-RowText (Get-StatusDisplayLines -Status $stE -Config (New-GoldenConfig -Coordination $false) -KeeperRoot $rootE -Now $Now)) -join "`n"
        Assert-False $flatE.Contains($secret) 'a token in lastError never reaches the console'
        Assert-True $flatE.Contains('[REDACTED]') 'and the masking is visible'
        # A live-probe error is masked the same way, in its continuation line.
        $stL = New-GoldenStatus @{ codex = @{ found = $true; path = 'codex.cmd'; liveOk = $false; liveError = 'bad password=hunter2' } } -LocalOnly
        $flatL = (Get-RowText (Get-StatusDisplayLines -Status $stL -Config (New-GoldenConfig -Coordination $false) -KeeperRoot $rootE -Now $Now)) -join "`n"
        Assert-False $flatL.Contains('hunter2') 'live error masked in its continuation line'
        Assert-True $flatL.Contains('连接失败') 'while the failure itself is still reported'
        # The text view and the console view are the same objects, so one fix covers
        # `status.cmd > status.txt` too - the file a user would attach to a report.
        Assert-False (Format-StatusText (Get-StatusDisplayLines -Status $stE -Config (New-GoldenConfig -Coordination $false) -KeeperRoot $rootE -Now $Now)).Contains($secret) 'the redirected text view is masked too'
    } finally { Remove-TestWorkspace $wsE }

    # -----------------------------------------------------------------------
    Start-TestGroup '§17.2 golden snapshots'
    # Rebuilt from the shared fixtures and compared line by line, so a change in
    # padding, in a term, or in the newline convention has to be committed on
    # purpose via tests/golden-update.ps1.
    foreach ($name in $cases.Keys) {
        $path = Join-Path $goldenDir ($name + '.txt')
        Assert-True (Test-Path -LiteralPath $path) "snapshot $name exists (run tests/golden-update.ps1)"
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $expectedRaw = [System.IO.File]::ReadAllText($path)
        Assert-False $expectedRaw.Contains([char]0xFEFF) 'snapshot has no BOM'
        Assert-False $expectedRaw.Contains("`r") 'snapshot uses LF, not CRLF'
        $wsG = New-TestWorkspace
        try {
            $rootG = Join-Path $wsG 'keeper'
            New-Item -ItemType Directory -Force -Path (Join-Path $rootG 'runtime\logs') | Out-Null
            Install-GoldenCaseState -Case $cases[$name] -KeeperRoot $rootG
            $actualRaw = ((Get-GoldenCaseText -Case $cases[$name] -KeeperRoot $rootG -Now $Now) -replace "`r`n", "`n") + "`n"
            $exp = @($expectedRaw -split "`n")
            $act = @($actualRaw -split "`n")
            if (($exp -join '|') -ne ($act -join '|')) {
                $script:TestFailures++
                Write-Host "  FAIL: snapshot $name differs" -ForegroundColor Red
                $max = [Math]::Max($exp.Count, $act.Count)
                $shown = 0
                for ($i = 0; $i -lt $max; $i++) {
                    $e = if ($i -lt $exp.Count) { $exp[$i] } else { '<missing>' }
                    $a = if ($i -lt $act.Count) { $act[$i] } else { '<missing>' }
                    if ($e -ne $a) {
                        Write-Host ("    line {0}: expected [{1}] got [{2}]" -f ($i + 1), $e, $a) -ForegroundColor DarkRed
                        $shown++
                        if ($shown -ge 8) { Write-Host '    ... (further diffs suppressed)' -ForegroundColor DarkGray; break }
                    }
                }
            } else {
                $script:TestChecks++
            }
        } finally { Remove-TestWorkspace $wsG }
    }
    # Each snapshot must pin a distinct behaviour, or the set has a hole in it.
    $byName = @{}
    foreach ($name in $cases.Keys) {
        $p = Join-Path $goldenDir ($name + '.txt')
        if (Test-Path -LiteralPath $p) { $byName[$name] = [System.IO.File]::ReadAllText($p) }
    }
    Assert-Equal 4 $byName.Count 'all four §17.2 scenarios are snapshotted'
    if ($byName.Count -eq 4) {
        Assert-True $byName['monitor-only-healthy'].Contains('功能状态        : [关闭]') 'case 1 pins the OFF state'
        Assert-True $byName['monitor-only-healthy'].Contains('单机模式（LOCAL_ONLY）') 'case 1 pins LOCAL_ONLY as a mode, not an alarm'
        Assert-True $byName['monitor-only-healthy'].Contains('实时连接检测') 'case 1 pins the not-run live probe row'
        Assert-False $byName['monitor-only-healthy'].Contains('[异常]') 'case 1, the healthy baseline, contains no error row'
        Assert-True $byName['aa-judgment'].Contains('[信息] 自动锚定处于静默期') 'case 2 pins the INFO cooldown row'
        Assert-False $byName['aa-judgment'].Contains('建议：') 'an INFO cooldown row carries no advice line'
        Assert-True $byName['aa-judgment'].Contains('今日已执行      : 1 / 6') 'case 2 pins today count from state.json'
        Assert-True $byName['aa-judgment'].Contains('上次执行        : 2026-09-09 10:00') 'case 2 pins the minute-precision anchor time'
        Assert-True $byName['aa-schedule'].Contains('下一个槽位      : 21:00') 'case 3 pins the next slot'
        Assert-True $byName['aa-schedule'].Contains('执行模型        : gpt-5-codex') 'case 3 pins an explicit model override'
        Assert-True $byName['aa-schedule'].Contains('今日已执行      : 2 / 6') 'case 3 pins a second day count'
        Assert-True $byName['aa-judgment'].Contains('执行模型        : 沿用 CLI 默认') 'case 2 pins the CLI-default wording'
        Assert-True $byName['multi-pc-error'].Contains('[异常] 多机协调仓库不可达') 'case 4 pins the unreachable-repo ERROR'
        Assert-True $byName['multi-pc-error'].Contains('token=[REDACTED]') 'case 4 pins end-to-end sanitisation'
        Assert-False $byName['multi-pc-error'].Contains('sk-fake-') 'and the fake secret itself is gone'
        Assert-True $byName['multi-pc-error'].Contains('[异常] 当前自动锚定被安全阻止') 'case 4 pins fail-closed anchoring'
        Assert-True $byName['multi-pc-error'].Contains('本机角色        : [注意] 未知（UNKNOWN）') 'case 4 pins an unmapped role'
        # ERROR rows must be listed before WARNING rows: the panel is read top-down
        # and a red line under a yellow one reads as "already handled".
        $err4 = $byName['multi-pc-error']
        Assert-True ($err4.IndexOf('[异常] 多机协调仓库不可达') -lt $err4.IndexOf('[注意] 额度数据已过期')) 'ERROR findings precede WARNING findings'
        Assert-True ($err4.IndexOf('【异常与建议】') -lt $err4.IndexOf('最近错误')) 'the last error stays inside its section'
        # Quota windows are the §20 DoD: used, remaining and reset in one block.
        $ok1 = $byName['monitor-only-healthy']
        Assert-True ($ok1.IndexOf('已使用') -lt $ok1.IndexOf('剩余')) 'used precedes remaining'
        Assert-True ($ok1.IndexOf('剩余') -lt $ok1.IndexOf('重置时间')) 'and the reset time closes the block'
        # Alignment is part of the contract, so pin it in the snapshots too: every
        # row's colon sits at display cell 18, all four panels together.
        $swept = 0
        foreach ($name in @($byName.Keys)) { $swept += (Test-RowAlignment (@($byName[$name] -split "`n"))) }
        Assert-True ($swept -ge 40) "the snapshots collectively pin $swept aligned rows"
    }
} catch {
    Write-Host "status-display.test.ps1 EXCEPTION: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
} finally {
    Remove-TestWorkspace $wsBase
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "status-display.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "status-display.test.ps1: $($result.checks) checks passed" -ForegroundColor Green
exit 0
