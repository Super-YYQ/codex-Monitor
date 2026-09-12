# Codex Quota Keeper - Status display layer (design v2.0 §11~§15.1).
#
# Third layer of the §15.1 split:
#   Get-KeeperStatus      (status.ps1)            -> facts, English values
#   Get-StatusAssessment  (status-assessment.ps1) -> overall + findings
#   this file                                   -> derived display fields + rendering
#
# Two rules shape everything below.
#
# 1. §13: never splice ANSI escape codes into strings. The renderers build logical
#    line objects (@{text;color}) and only Write-StatusConsole decides whether to
#    pass -ForegroundColor to Write-Host. That is what makes the redirected output
#    (`status.cmd > status.txt`) clean on PS 5.1 and on legacy consoles.
# 2. §7/§22: status-json.ps1 reads Get-KeeperStatus directly and keeps its English
#    schema. No Chinese text may be produced anywhere below that object, which is
#    why the whole panel lives here instead of in the collector.
#
# No top-level param() block: this file is dot-sourced by status.ps1 (and by the
# tests) into a scope that already has same-named caller variables, where a param
# block would rebind them.

$script:CqkStatusDisplayDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-StatusAssessment -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkStatusDisplayDir 'status-assessment.ps1')
}

# Label column and value column, both measured against the §11.1 sample: every row's
# colon sits at display cell 18 (so the value starts at 20), and continuation lines
# are indented to exactly that value column. Counted in display cells, not
# [string]::Length: '本机 ID' is 5 characters but 7 cells, '当前状态' is 4 characters
# but 8. Character count and cell count order the two labels in opposite directions,
# so Length-based padding would put their colons two cells apart.
$script:CqkStatusLabelCol = 18
$script:CqkStatusValueCol = 20

# ---------------------------------------------------------------------------
# Terminal-width and formatting primitives (§15.1 Format-* family)

function Get-CqkDisplayWidth {
    # Console cells a string occupies: CJK/fullwidth = 2, everything else = 1.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        $wide =
            ($c -ge 0x1100 -and $c -le 0x115F) -or   # Hangul Jamo init
            ($c -ge 0x2E80 -and $c -le 0x303E) -or   # CJK radicals, symbols
            ($c -ge 0x3041 -and $c -le 0x33FF) -or   # kana, Hangul compat, CJK punct
            ($c -ge 0x3400 -and $c -le 0x4DBF) -or   # CJK ext A
            ($c -ge 0x4E00 -and $c -le 0x9FFF) -or   # CJK unified
            ($c -ge 0xA000 -and $c -le 0xA4CF) -or   # Yi
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or   # Hangul syllables
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or   # CJK compat ideographs
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or   # CJK compat forms
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or   # fullwidth ASCII
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)       # fullwidth signs
        if ($wide) { $width += 2 } else { $width += 1 }
    }
    return $width
}

function Format-StatusDateTime {
    # '' when there is nothing to show, so callers can test for emptiness instead
    # of printing '0001-01-01 00:00:00' (Task Scheduler's "never ran" shape).
    #
    # $Pattern is second-precision by default. §11 asks for 'yyyy-MM-dd HH:mm' on
    # quota reset / last anchor: those are forward-looking or historical context,
    # where seconds are noise, while a task run must be second-exact to correlate
    # with the log.
    param($Value, [string]$Pattern = 'yyyy-MM-dd HH:mm:ss')
    $dt = ConvertTo-StatusDateTime $Value
    if ($null -eq $dt) { return '' }
    if ($dt.Year -le 1) { return '' }
    return $dt.ToString($Pattern)
}

function Format-BooleanZh {
    param($Value)
    return $(if ([bool]$Value) { '是' } else { '否' })
}

function Format-QuotaWindowNameZh {
    # §15.2: 300 => '5 小时', 10080 => '7 天', anything else => 'X 分钟窗口'.
    # Codex currently reports 5h and weekly windows; a future third duration must
    # still read sensibly rather than as '0 小时'.
    param($Minutes)
    $m = 0
    if ($null -ne $Minutes) { $m = [int]$Minutes }
    if ($m -eq 300) { return '5 小时' }
    if ($m -eq 10080) { return '7 天' }
    if ($m -gt 0 -and ($m % 60) -eq 0) { return "$($m / 60) 小时" }
    return "$m 分钟窗口"
}

function Format-QuotaWindowHeaderZh {
    # Panel heading for a window: '5 小时额度', '7 天额度', but '45 分钟窗口' rather
    # than '45 分钟窗口额度' (the name already says 窗口).
    param($Minutes)
    $name = Format-QuotaWindowNameZh $Minutes
    if ($name -match '窗口$') { return $name }
    return "$($name)额度"
}

function Format-RoleZh {
    # §12 terminology table. The English internal name stays in parentheses so the
    # panel can be reconciled against logs / status-json without a lookup table.
    param([string]$Role)
    $r = if ($Role) { $Role.Trim().ToUpperInvariant() } else { '' }
    $zh = switch ($r) {
        'LEADER'   { '负责人' }
        'PASSIVE'  { '待机节点' }
        'DEGRADED' { '降级运行' }
        'BACKOFF'  { '退避中' }
        default    { $null }
    }
    if ($null -eq $zh) { return '未知（UNKNOWN）' }
    return "$zh（$r）"
}

function Format-ModeZh {
    # §12: MonitorOnly => 仅监控, AutoAnchor => 自动锚定 (experimental).
    param([string]$Mode)
    $m = if ($Mode) { $Mode.Trim() } else { '' }
    if ($m -match '(?i)autoanchor') { return '自动锚定（AutoAnchor）' }
    if ($m -match '(?i)monitoronly') { return '仅监控（MonitorOnly）' }
    if ([string]::IsNullOrWhiteSpace($m)) { return '未知（UNKNOWN）' }
    return $m
}

function Format-WorkModeZh {
    # §11.2 / §11.3 / §15.2 autoAnchor.workMode.
    param([string]$WorkMode)
    if ([string]$WorkMode -eq 'SCHEDULE') { return '每日定时（Schedule）' }
    return '周期判断'
}

function Get-StatusSeverityTag {
    # §13 text prefix. The prefix carries the meaning, the colour only repeats it,
    # so -NoColor and non-Write-Host consumers lose nothing.
    param([string]$Severity)
    switch ($Severity) {
        'ERROR'   { return '[异常]' }
        'WARNING' { return '[注意]' }
        'HEALTHY' { return '[正常]' }
        'OFF'     { return '[关闭]' }
        'INFO'    { return '[信息]' }
        default   { return '[信息]' }
    }
}

function Get-StatusSeverityColor {
    # §13 recommended colours. Returns the Write-Host colour name; '' = leave default.
    param([string]$Severity)
    switch ($Severity) {
        'ERROR'   { return 'Red' }
        'WARNING' { return 'Yellow' }
        'HEALTHY' { return 'Green' }
        'OFF'     { return 'DarkGray' }
        'INFO'    { return 'Cyan' }
        default   { return '' }
    }
}

function Get-CqkTaskRunOutcomeZh {
    # Task Scheduler result -> (§13 severity, text). The three 2670xx codes are not
    # failures - they mean the task is running / ready / has never run - and the
    # assessment layer keeps the same list in $script:CQK_TASK_NON_FAILURE_CODES.
    param($Result, $LastRun)
    if ($null -eq $Result) {
        if (Format-StatusDateTime $LastRun) { return @{ severity = 'INFO'; text = '状态未知' } }
        return @{ severity = 'INFO'; text = '尚未运行' }
    }
    $code = [int]$Result
    switch ($code) {
        0       { return @{ severity = 'HEALTHY'; text = '成功' } }
        267009  { return @{ severity = 'INFO'; text = '正在运行' } }
        267010  { return @{ severity = 'INFO'; text = '就绪' } }
        267011  { return @{ severity = 'INFO'; text = '尚未运行' } }
        default { return @{ severity = 'ERROR'; text = "退出码 $code" } }
    }
}

# ---------------------------------------------------------------------------
# Line objects (§13: build first, colour at write time)

function New-StatusLine {
    param([string]$Text = '', [string]$Color = '')
    return @{ text = $Text; color = $Color }
}

function Add-StatusLine {
    # $Lines is a List[object] handed by reference, which is why these helpers return
    # nothing: a renderer that returned the growing array would let one missed
    # assignment silently drop every earlier section.
    param($Lines, [string]$Text = '', [string]$Color = '')
    [void]$Lines.Add((New-StatusLine -Text $Text -Color $Color))
}

function Write-StatusSection {
    # Blank line, then 【区块】 at column 0. Uncoloured on purpose: emphasis here is
    # structural, and a rainbow panel hides which row actually needs attention.
    param($Lines, [string]$Title)
    Add-StatusLine $Lines ''
    Add-StatusLine $Lines "【$Title】"
}

function Write-StatusRow {
    #   <indent><label><padding>: [tag] <value>
    # plus optional continuation lines at the value column (§11.1's 提示 line).
    # $Colon defaults to ASCII ': ' - every structural row in §11 uses it; the
    # full-width ：appears only inside Chinese prose (提示：/建议：), so it is not
    # the row separator. Padding is in display cells (see $script:CqkStatusLabelCol).
    #
    # -Color paints without adding a text tag. §11 has rows whose verdict lives in
    # the *middle* of the value (最近运行's timestamp then [正常] 成功, 轮询周期's
    # "60 分钟  [正常] 与配置一致"): passing -Severity there would double-tag, but
    # -Color keeps the row painted. Callers must not be able to pass both, hence the
    # explicit guard rather than a precedence rule that would hide the mistake.
    param(
        $Lines,
        [string]$Label,
        [string]$Value = '',
        [string]$Severity = '',
        [string]$Color = '',
        [int]$Indent = 2,
        [string]$Colon = ': ',
        [string[]]$Continuation = @()
    )
    if ($Severity -and $PSBoundParameters.ContainsKey('Color')) {
        throw 'Write-StatusRow: use either -Severity (tag + colour) or -Color (colour only), not both.'
    }
    $prefix = ''
    if ($Severity) {
        $prefix = "$(Get-StatusSeverityTag $Severity) "
        $Color = Get-StatusSeverityColor $Severity
    }
    $pad = [int]$script:CqkStatusLabelCol - $Indent - (Get-CqkDisplayWidth $Label)
    if ($pad -lt 1) { $pad = 1 }
    # TrimEnd: an empty value (e.g. 功能状态 : [关闭]) must not leave a trailing
    # space - the golden snapshots compare whole lines.
    $row = ((' ' * $Indent) + $Label + (' ' * $pad) + $Colon + $prefix + $Value).TrimEnd()
    Add-StatusLine $Lines $row $Color
    foreach ($note in @($Continuation)) {
        if ([string]::IsNullOrWhiteSpace($note)) { continue }
        Add-StatusLine $Lines ((' ' * [int]$script:CqkStatusValueCol) + $note)
    }
}

function Write-StatusFinding {
    # One finding as label-less rows in 【异常与建议】: the claim, then the fix, then
    # (detail mode) the raw evidence the assessment kept in English.
    param($Lines, $Finding, [switch]$Detailed)
    if ($null -eq $Finding) { return }
    $sev = [string]$Finding.severity
    $title = [string]$Finding.title
    $action = [string]$Finding.action
    Add-StatusLine $Lines ((' ' * 2) + "$(Get-StatusSeverityTag $sev) $title") (Get-StatusSeverityColor $sev)
    if ($action) { Add-StatusLine $Lines ((' ' * [int]$script:CqkStatusValueCol) + "建议：$action") }
    if ($Detailed -and $Finding.detail) {
        Add-StatusLine $Lines ((' ' * [int]$script:CqkStatusValueCol) + "详情：$([string]$Finding.detail) [$sev/$([string]$Finding.code)]")
    }
}

function Format-StatusText {
    # Plain-text form of a line list: no colours, no ANSI, platform newline.
    param($Lines)
    $texts = @($Lines | ForEach-Object { [string]$_.text })
    return ($texts -join [Environment]::NewLine)
}

function Write-StatusConsole {
    param($Lines, [switch]$NoColor)
    # [object[]] and not @($Lines): PowerShell cannot enumerate a
    # List[object] through @() on either runtime ("Argument types do not
    # match"), while the cast handles the List, an Object[] (what
    # Get-StatusDisplayLines actually returns, since PS unrolls the List on
    # output), a lone line hashtable and $null alike.
    foreach ($line in [object[]]$Lines) {
        $color = [string]$line.color
        if (-not $NoColor -and $color) {
            Write-Host ([string]$line.text) -ForegroundColor $color
        } else {
            Write-Host ([string]$line.text)
        }
    }
}

# ---------------------------------------------------------------------------
# §15.1 / §15.2 - derived fields the panel needs but the fact layer must not carry

function Get-NextScheduleSlotZh {
    # §15.2 autoAnchor.nextSlot: the first local slot still ahead of us today,
    # otherwise tomorrow's first slot marked 明日. Deliberately time-of-day only -
    # "already handled today" would need the claim store, and the guard, not the
    # panel, is the authority on that.
    #
    # Slots are compared as minutes-of-day strings, not [datetime] parsed via
    # TryParseExact: a malformed slot must simply not be a candidate, while a
    # DateTime-default failure would sort first and win as "next".
    param([string[]]$Slots, [datetime]$Now)
    $parsed = @()
    foreach ($raw in @($Slots)) {
        $t = ('{0}' -f $raw).Trim()
        if ($t -notmatch '^(\d{1,2}):(\d{2})$') { continue }
        $mins = [int]$Matches[1] * 60 + [int]$Matches[2]
        if ($mins -ge 1440) { continue }
        $parsed += @{ text = ('{0:D2}:{1:D2}' -f [int]$Matches[1], [int]$Matches[2]); minutes = $mins }
    }
    if (@($parsed).Count -eq 0) { return '' }
    $sorted = @($parsed | Sort-Object { [int]$_.minutes })
    $nowMins = $Now.Hour * 60 + $Now.Minute
    foreach ($p in $sorted) {
        if ([int]$p.minutes -gt $nowMins) { return [string]$p.text }
    }
    return "明日 $([string]$sorted[0].text)"
}

function Get-StatusDisplayModel {
    # §15.2 derived fields. Pure computation over facts + assessment + config + state;
    # it adds no new probes and changes no verdict. Config/State are optional: like
    # Get-StatusAssessment, the model reads the same runtime files itself when the
    # caller does not thread them through (Load-Config / Load-KeeperState read-only).
    param(
        $Status,
        $Assessment = $null,
        $Config = $null,
        $State = $null,
        [string]$KeeperRoot = '',
        [string]$ConfigFile = '',
        [datetime]$Now = (Get-Date)
    )
    $s = ConvertTo-StatusHashtable $Status
    if ($null -eq $s) { $s = @{} }
    if (-not $KeeperRoot) { $KeeperRoot = Get-KeeperRoot }
    if (-not $ConfigFile) { $ConfigFile = Get-ConfigPath $KeeperRoot }

    if ($null -eq $Assessment) {
        # Allowed but unusual: the panel normally threads its own assessment through
        # so that the verdict it prints is the one it was handed.
        $Assessment = Get-StatusAssessment -Status $s -Config $Config -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile -Now $Now
    }
    $a = ConvertTo-StatusHashtable $Assessment
    if ($null -eq $a) { $a = @{ overall = 'HEALTHY'; summary = ''; findings = @() } }
    $findings = @($a.findings)

    $cfg = ConvertTo-StatusHashtable $Config
    if ($null -eq $cfg -or $cfg.Count -eq 0) {
        # Load-Config also strips JSONC comments; a plain ConvertFrom-Json would not.
        $loaded = Load-Config $ConfigFile
        $cfg = ConvertTo-StatusHashtable $loaded.config
    }
    if ($null -eq $cfg) { $cfg = @{} }
    $aa = ConvertTo-StatusHashtable (Get-AutoAnchorConfig $cfg)
    if ($null -eq $aa) { $aa = @{} }
    $st = ConvertTo-StatusHashtable $State
    if ($null -eq $st) { $st = ConvertTo-StatusHashtable (Load-KeeperState $KeeperRoot) }
    if ($null -eq $st) { $st = @{} }

    $slots = @()
    foreach ($slot in @(Get-StatusValue -Map $s -Path 'anchorSchedule.slots')) {
        $txt = ('{0}' -f $slot).Trim()
        if ($txt) { $slots += $txt }
    }
    $maxPerDay = 0
    if ($null -ne $aa.maxPerDay) { $maxPerDay = [int]$aa.maxPerDay }
    $workMode = $(if ($slots.Count -gt 0) { 'SCHEDULE' } else { 'JUDGMENT' })
    $overall = [string](Get-StatusValue -Map $a -Path 'overall')
    if (-not $overall) { $overall = 'HEALTHY' }

    # Windows: keep the collector's order, add remaining percent + a Chinese name.
    $windows = @()
    foreach ($w in @(Get-StatusValue -Map $s -Path 'quota.windows')) {
        $wh = ConvertTo-StatusHashtable $w
        if ($null -eq $wh) { continue }
        $used = 0
        if ($null -ne $wh.usedPercent) { $used = [int]$wh.usedPercent }
        $remaining = 100 - $used
        if ($remaining -lt 0) { $remaining = 0 }   # §15.2 max(0, 100-usedPercent)
        $windows += @{
            name         = Format-QuotaWindowNameZh $wh.minutes
            header       = Format-QuotaWindowHeaderZh $wh.minutes
            bucketId     = [string]$wh.bucketId
            usedPercent  = $used
            remainingPct = $remaining
            resetText    = Format-StatusDateTime (ConvertFrom-EpochSeconds ([long]$wh.resetsAt)) 'yyyy-MM-dd HH:mm'
            minutes      = $(if ($null -ne $wh.minutes) { [int]$wh.minutes } else { 0 })
        }
    }

    # 数据状态 reads the verdict stream rather than recomputing ages: §16.3 owns the
    # thresholds (never / stale / 2*poll+tolerance), and a second copy of them here
    # would be free to drift from the finding the user is shown below it. The last
    # two branches cover the case where the assessment layer never ran against this
    # status object (direct model calls, e.g. from tests).
    $lastReadAt = [string](Get-StatusValue -Map $s -Path 'quota.lastReadAt')
    $dataSeverity = 'HEALTHY'
    $dataText = '最新'
    $neverF  = Get-StatusFinding -Assessment $a -Code 'QUOTA_NEVER_READ'
    $staleF  = Get-StatusFinding -Assessment $a -Code 'QUOTA_STALE'
    $oldF    = Get-StatusFinding -Assessment $a -Code 'QUOTA_TOO_OLD'
    $failF   = Get-StatusFinding -Assessment $a -Code 'QUOTA_READ_FAILED'
    if ($neverF) { $dataSeverity = 'WARNING'; $dataText = '尚无数据' }
    elseif ($staleF) { $dataSeverity = 'WARNING'; $dataText = '已过期' }
    elseif ($oldF) { $dataSeverity = 'WARNING'; $dataText = '长时间未更新' }
    elseif ($failF) { $dataSeverity = 'WARNING'; $dataText = '最近读取失败' }
    elseif ([string]::IsNullOrWhiteSpace($lastReadAt)) { $dataSeverity = 'INFO'; $dataText = '尚无数据' }
    elseif ([bool](Get-StatusValue -Map $s -Path 'quota.stale')) { $dataSeverity = 'WARNING'; $dataText = '已过期' }

    $model = [string](Get-StatusValue -Map $s -Path 'anchorExec.model')
    $effort = [string](Get-StatusValue -Map $s -Path 'anchorExec.reasoningEffort')

    return @{
        overall      = $overall
        summary      = [string](Get-StatusValue -Map $a -Path 'summary')
        findings     = $findings
        modeText     = Format-ModeZh ([string](Get-StatusValue -Map $s -Path 'mode'))
        machineLabel = [string](Get-StatusValue -Map $s -Path 'machineLabel')
        machineId    = [string](Get-StatusValue -Map $s -Path 'machineId')
        pollMinutes  = [int](Get-StatusValue -Map $s -Path 'pollIntervalMinutes')
        task         = @{
            installed = [bool](Get-StatusValue -Map $s -Path 'task.installed')
            enabled   = [bool](Get-StatusValue -Map $s -Path 'task.enabled')
            lastRun   = Format-StatusDateTime (Get-StatusValue -Map $s -Path 'task.lastRunTime')
            outcome   = Get-CqkTaskRunOutcomeZh (Get-StatusValue -Map $s -Path 'task.lastResult') (Get-StatusValue -Map $s -Path 'task.lastRunTime')
            nextRun   = Format-StatusDateTime (Get-StatusValue -Map $s -Path 'task.nextRunTime')
            interval  = Get-StatusValue -Map $s -Path 'task.intervalMinutes'
            matches   = Get-StatusValue -Map $s -Path 'task.intervalMatchesConfig'
        }
        codex        = @{
            found     = [bool](Get-StatusValue -Map $s -Path 'codex.found')
            path      = [string](Get-StatusValue -Map $s -Path 'codex.path')
            liveOk    = Get-StatusValue -Map $s -Path 'codex.liveOk'
            liveError = [string](Get-StatusValue -Map $s -Path 'codex.liveError')
        }
        autoAnchor   = @{
            profile    = Get-StatusValue -Map $s -Path 'executionProfile'
            stats      = Get-AnchorStatistics -Anchors (Get-StatusValue -Map $st -Path 'anchors') -Today $Now.ToString('yyyy-MM-dd')
            enabled    = [bool](Get-StatusValue -Map $s -Path 'autoAnchor')
            workMode   = $workMode
            slots      = $slots
            nextSlot   = Get-NextScheduleSlotZh -Slots $slots -Now $Now
            minGap     = $(if ($null -ne $aa.minimumGapMinutes) { [int]$aa.minimumGapMinutes } else { 0 })
            keepalive  = [int](Get-StatusValue -Map $s -Path 'anchorKeepalive.intervalMinutes')
            maxPerDay  = $maxPerDay
            today      = Get-StatusAnchorToday -State $st -Today $Now.ToString('yyyy-MM-dd')
            # §11.2 shows '2026-09-08 10:03' - minute precision, like the reset times.
            lastAt     = Format-StatusDateTime (Get-StatusValue -Map $s -Path 'anchorKeepalive.lastAnchorAt') 'yyyy-MM-dd HH:mm'
            model      = $model
            effort     = $effort
            # §16.5: an empty model/effort must never render as an empty value.
            modelText  = $(if ($model) { $model } else { '沿用 CLI 默认' })
            effortText = $(if ($effort) { $effort } else { '沿用 CLI 默认' })
        }
        coord        = @{
            localOnly      = [bool](Get-StatusValue -Map $s -Path 'role.localOnly')
            role           = [string](Get-StatusValue -Map $s -Path 'role.role')
            roleDisplay    = Format-RoleZh ([string](Get-StatusValue -Map $s -Path 'role.role'))
            leaderOwner    = [string](Get-StatusValue -Map $s -Path 'role.leaderOwner')
            leaderLabel    = [string](Get-StatusValue -Map $s -Path 'role.leaderLabel')
            leaseExpiresAt = Format-StatusDateTime (Get-StatusValue -Map $s -Path 'role.leaseExpiresAt')
            gitEnabled     = [bool](Get-StatusValue -Map $s -Path 'git.enabled')
            gitReachable   = Get-StatusValue -Map $s -Path 'git.reachable'
            repoPath       = [string](Get-StatusValue -Map $s -Path 'git.repoPath')
        }
        quota        = @{
            lastReadAt = Format-StatusDateTime $lastReadAt
            rawReadAt  = $lastReadAt
            stale      = [bool](Get-StatusValue -Map $s -Path 'quota.stale')
            severity   = $dataSeverity
            statusText = $dataText
            windows    = $windows
        }
        runner       = @{
            running = [bool](Get-StatusValue -Map $s -Path 'process.runnerRunningNow')
            pid     = Get-StatusValue -Map $s -Path 'process.pid'
        }
        lastError    = [string](Get-StatusValue -Map $s -Path 'lastError')
        configOk     = [bool](Get-StatusValue -Map $s -Path 'configOk')
    }
}

# ---------------------------------------------------------------------------
# The zh-CN panel (§11)

function Get-StatusDisplayLines {
    # Status + assessment -> ordered line objects. Everything the console and the
    # text/redirect/golden-snapshot views share, so the three cannot drift.
    param(
        $Status,
        $Assessment = $null,
        $Model = $null,
        [ValidateSet('zh-CN', 'en-US')] [string]$Language = 'zh-CN',
        [switch]$Detailed,
        $Config = $null,
        [string]$KeeperRoot = '',
        [string]$ConfigFile = '',
        [datetime]$Now = (Get-Date)
    )
    $lines = New-Object 'System.Collections.Generic.List[object]'
    if ($Language -eq 'en-US') {
        # Maintainer/compat view (§14): the pre-v2.0 English text, unpainted.
        foreach ($row in ((Write-StatusTextEn -Status $Status) -split "`r?`n")) { Add-StatusLine $lines $row }
        return $lines
    }
    if ($null -eq $Model) {
        $Model = Get-StatusDisplayModel -Status $Status -Assessment $Assessment -Config $Config -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile -Now $Now
    }
    $findings = @($Model.findings)
    Add-StatusLine $lines 'Codex Quota Keeper 状态'
    Add-StatusLine $lines ('=' * 60)

    # ---- 总体状态 -----------------------------------------------------------
    Write-StatusSection $lines '总体状态'
    $summary = [string]$Model.summary
    if (-not $summary) {
        $summary = switch ($Model.overall) { 'ERROR' { '运行异常' } 'WARNING' { '存在需要注意的配置' } default { '运行正常' } }
    }
    Write-StatusRow $lines -Label '当前状态' -Value $summary -Severity $Model.overall
    Write-StatusRow $lines -Label '运行模式' -Value $Model.modeText
    Write-StatusRow $lines -Label '本机名称' -Value $(if ($Model.machineLabel) { $Model.machineLabel } else { '未设置' })
    Write-StatusRow $lines -Label '本机 ID' -Value $Model.machineId

    # ---- 计划任务 -----------------------------------------------------------
    Write-StatusSection $lines '计划任务'
    $t = $Model.task
    if (-not $t.installed) {
        Write-StatusRow $lines -Label '安装状态' -Value '未安装' -Severity 'ERROR'
        Write-StatusRow $lines -Label '说明' -Value '双击 install.cmd 完成安装后，本区块会显示运行记录'
    } else {
        Write-StatusRow $lines -Label '安装状态' -Value '已安装' -Severity 'HEALTHY'
        Write-StatusRow $lines -Label '启用状态' -Value $(if ($t.enabled) { '已启用' } else { '已禁用' }) -Severity $(if ($t.enabled) { 'HEALTHY' } else { 'ERROR' })
        $out = $t.outcome
        if ($t.lastRun) {
            # The tag belongs to the outcome, not to the timestamp, so it is spliced
            # into the value and the row is only painted (-Color).
            Write-StatusRow $lines -Label '最近运行' -Value "$($t.lastRun)  $(Get-StatusSeverityTag $out.severity) $($out.text)" -Color (Get-StatusSeverityColor $out.severity)
        } else {
            Write-StatusRow $lines -Label '最近运行' -Value $out.text -Severity $out.severity
        }
        if ($t.nextRun) { Write-StatusRow $lines -Label '下次运行' -Value $t.nextRun }
        $matchSev = 'INFO'; $matchText = '未知'
        if ($null -ne $t.matches) {
            if ([bool]$t.matches) { $matchSev = 'HEALTHY'; $matchText = '与配置一致' }
            else { $matchSev = 'WARNING'; $matchText = "不一致（任务为 $([int]$t.interval) 分钟）" }
        }
        Write-StatusRow $lines -Label '轮询周期' -Value "$($Model.pollMinutes) 分钟  $(Get-StatusSeverityTag $matchSev) $matchText" -Color (Get-StatusSeverityColor $matchSev)
        if ($Model.runner.running) {
            Write-StatusRow $lines -Label '本机进程' -Value "runner 正在运行（PID $($Model.runner.pid)）"
        }
    }

    # ---- Codex --------------------------------------------------------------
    Write-StatusSection $lines 'Codex'
    $c = $Model.codex
    if ($c.found) {
        Write-StatusRow $lines -Label 'CLI 状态' -Value '已找到' -Severity 'HEALTHY'
        if ($c.path) { Write-StatusRow $lines -Label 'CLI 路径' -Value $c.path }
    } else {
        Write-StatusRow $lines -Label 'CLI 状态' -Value '未找到' -Severity 'ERROR'
        Write-StatusRow $lines -Label '说明' -Value '请设置 codex.command，或确认 codex 已在 PATH 中'
    }
    if ($null -eq $c.liveOk) {
        Write-StatusRow $lines -Label '实时连接检测' -Value '未执行' `
            -Continuation @('提示：使用 status.ps1 -Live 进行只读连接检测')
    } elseif ([bool]$c.liveOk) {
        Write-StatusRow $lines -Label '实时连接检测' -Value '只读连接成功' -Severity 'HEALTHY'
    } else {
        Write-StatusRow $lines -Label '实时连接检测' -Value '连接失败' -Severity 'ERROR' `
            -Continuation @($(if ($c.liveError) { "错误：$(Hide-SensitiveText $c.liveError)" } else { '' }))
    }

    # ---- AutoAnchor ---------------------------------------------------------
    Write-StatusSection $lines 'AutoAnchor 自动锚定'
    $aa = $Model.autoAnchor
    if (-not $aa.enabled) {
        # §11.1: the OFF state says plainly that no model is called (DoD: MonitorOnly
        # 明确显示"不会调用模型"). Here the doc's value IS the tag (功能状态 : [关闭]),
        # so -Severity would double it; -Color paints without adding a prefix.
        Write-StatusRow $lines -Label '功能状态' -Value '[关闭]' -Color 'DarkGray'
        Write-StatusRow $lines -Label '说明' -Value '当前只读取额度，不会自动调用模型'
    } else {
        Write-StatusRow $lines -Label '功能状态' -Value '已开启（Experimental）' -Severity 'WARNING'
        Write-StatusRow $lines -Label '工作模式' -Value (Format-WorkModeZh $aa.workMode)
        if ($aa.workMode -eq 'SCHEDULE') {
            # §11.3: slots are 、-separated; judgment is explicitly NOT live. No
            # severity tags in this block - §11.3's sample rows are all plain, and an
            # [信息] on every line makes the one row that matters read as noise.
            Write-StatusRow $lines -Label '定时时间' -Value ($aa.slots -join '、')
            Write-StatusRow $lines -Label '周期判断' -Value '已停用（reset / idle / keepalive 不触发）'
        } else {
            Write-StatusRow $lines -Label '触发方式' -Value '窗口重置 / 首次空闲检测 / Keepalive'
            if ($aa.minGap -gt 0) { Write-StatusRow $lines -Label '最小间隔' -Value "$($aa.minGap) 分钟" }
            if ($aa.keepalive -gt 0) { Write-StatusRow $lines -Label 'Keepalive' -Value "$($aa.keepalive) 分钟" }
            else { Write-StatusRow $lines -Label 'Keepalive' -Value '已关闭（仅重置/空闲触发）' }
        }
        if ($aa.maxPerDay -gt 0) { Write-StatusRow $lines -Label '每日上限' -Value "$($aa.maxPerDay) 次" }
        $capText = "$($aa.today) / $(if ($aa.maxPerDay -gt 0) { $aa.maxPerDay } else { '不限' })"
        if ($aa.maxPerDay -gt 0 -and $aa.today -ge $aa.maxPerDay) {
            # At the cap the count itself is the news (§16.5), so tag only here.
            Write-StatusRow $lines -Label '今日已执行' -Value $capText -Severity 'WARNING'
        } else {
            Write-StatusRow $lines -Label '今日已执行' -Value $capText
        }
        if ($aa.workMode -eq 'SCHEDULE' -and $aa.nextSlot) { Write-StatusRow $lines -Label '下一个槽位' -Value $aa.nextSlot }
        if ($aa.lastAt) { Write-StatusRow $lines -Label '上次执行' -Value $aa.lastAt }
        # §16.5: an empty model must never render as an empty value.
        Write-StatusRow $lines -Label '执行模型' -Value $aa.modelText
        Write-StatusRow $lines -Label '思考等级' -Value $aa.effortText
        Write-StatusRow $lines -Label '成功 / 失败' -Value "$($aa.stats.successCount) / $($aa.stats.failedCount)（仅已确认结果）"
        if ($aa.stats.lastSuccessAt) { Write-StatusRow $lines -Label '上次成功' -Value (Format-StatusDateTime $aa.stats.lastSuccessAt) }
        $ep = $aa.profile
        if (-not $ep -or -not $ep.value) {
            Write-StatusRow $lines -Label '执行配置校验' -Value '尚无记录；运行 status.cmd -Live 校验' -Severity 'INFO'
        } else {
            $pv = $ep.value
            $origin = if ($ep.source -eq 'live') { '本次实时校验' } else { '缓存；仅代表上次校验' }
            if ($ep.stale) { $origin += '，已过期或配置已修改' }
            $verdict = switch ($pv.validation) { 'VALID' { '通过' }; 'INVALID' { '不支持此配置' }; default { '暂时无法校验' } }
            $sev = if ($pv.validation -eq 'VALID' -and -not $ep.stale) { 'HEALTHY' } elseif ($pv.validation -eq 'INVALID') { 'ERROR' } else { 'WARNING' }
            Write-StatusRow $lines -Label '执行配置校验' -Value "$verdict（$origin）" -Severity $sev
            Write-StatusRow $lines -Label '有效模型' -Value $(if ($pv.effectiveModel) { $pv.effectiveModel } else { '未知' })
            Write-StatusRow $lines -Label '有效思考等级' -Value $(if ($pv.effectiveReasoningEffort) { $pv.effectiveReasoningEffort } else { '沿用 CLI 默认' })
            Write-StatusRow $lines -Label '配置来源' -Value "$($pv.modelSource) / $($pv.reasoningEffortSource)"
            Write-StatusRow $lines -Label '模型提供方' -Value $(if ($pv.modelProvider) { $pv.modelProvider } else { 'CLI 默认' })
            Write-StatusRow $lines -Label '校验时间' -Value (Format-StatusDateTime $pv.validatedAt)
            if ($ep.source -eq 'live' -and $pv.supportedReasoningEfforts) {
                Write-StatusRow $lines -Label '支持思考等级' -Value ($pv.supportedReasoningEfforts -join ' / ')
            }
            if ($ep.reason) { Write-StatusRow $lines -Label '校验原因' -Value (Hide-SensitiveText $ep.reason) }
        }
        Write-StatusRow $lines -Label '说明' -Value '该功能会主动调用 Codex 模型并消耗额度'
        $block = $null
        foreach ($code in @('AUTOANCHOR_BLOCKED', 'ANCHOR_CAP_REACHED', 'ANCHOR_GAP_COOLDOWN')) {
            $block = Get-StatusFinding -Assessment @{ findings = $findings } -Code $code
            if ($block) { break }
        }
        if ($block) {
            # §16.5 "当前自动锚定被安全阻止": say it in the section the user is reading,
            # not only in the finding list at the bottom.
            Write-StatusRow $lines -Label '当前锚定' -Value ([string]$block.title) -Severity ([string]$block.severity) `
                -Continuation @($(if ([string]$block.severity -ne 'INFO') { "建议：$([string]$block.action)" } else { '' }))
        }
    }

    # ---- 多机协调 -----------------------------------------------------------
    Write-StatusSection $lines '多机协调'
    $co = $Model.coord
    if ($co.localOnly) {
        # §16.4 / DoD: LOCAL_ONLY is a running mode, not an UNSAFE alarm.
        Write-StatusRow $lines -Label '当前模式' -Value '单机模式（LOCAL_ONLY）'
        Write-StatusRow $lines -Label '本机角色' -Value $co.roleDisplay
        Write-StatusRow $lines -Label 'Git 协调' -Value '未启用'
        Write-StatusRow $lines -Label '说明' -Value '单台电脑使用正常；多台电脑同时运行时需启用 Git 协调'
    } else {
        Write-StatusRow $lines -Label '当前模式' -Value '多机协调（Git 租约）'
        Write-StatusRow $lines -Label '本机角色' -Value $co.roleDisplay `
            -Severity $(if ($co.role -eq 'LEADER') { 'HEALTHY' } elseif ($co.role -eq 'UNKNOWN') { 'WARNING' } else { 'INFO' })
        if ($co.leaderOwner) {
            $holder = if ($co.leaderLabel) { "$($co.leaderLabel) [$($co.leaderOwner)]" } else { $co.leaderOwner }
            Write-StatusRow $lines -Label '负责人' -Value $holder
        }
        if ($co.leaseExpiresAt) { Write-StatusRow $lines -Label '租约到期' -Value $co.leaseExpiresAt }
        $gitSev = 'WARNING'; $gitText = '未知'
        if ($null -ne $co.gitReachable) {
            if ([bool]$co.gitReachable) { $gitSev = 'HEALTHY'; $gitText = '可达' }
            else { $gitSev = 'ERROR'; $gitText = '不可达' }
        }
        Write-StatusRow $lines -Label 'Git 协调' -Value $gitText -Severity $gitSev
        if ($gitSev -eq 'ERROR') {
            Write-StatusRow $lines -Label '说明' -Value '协调仓库不可达，自动锚定已失败关闭（不访问 Codex）' -Severity 'ERROR' `
                -Continuation @($(if ($co.repoPath) { "仓库路径：$($co.repoPath)" } else { '' }))
        }
    }

    # ---- Codex 额度 ---------------------------------------------------------
    Write-StatusSection $lines 'Codex 额度'
    $q = $Model.quota
    if ($q.lastReadAt) { Write-StatusRow $lines -Label '最近读取' -Value $q.lastReadAt }
    else { Write-StatusRow $lines -Label '最近读取' -Value '尚未读取' -Severity 'INFO' }
    Write-StatusRow $lines -Label '数据状态' -Value $q.statusText -Severity $q.severity
    foreach ($w in @($q.windows)) {
        $head = $w.header
        if ($w.bucketId -and $w.bucketId -ne 'default') { $head = "$head（$($w.bucketId)）" }
        Add-StatusLine $lines ''
        Add-StatusLine $lines ((' ' * 2) + $head)
        # §20 DoD: 已使用、剩余、重置时间 together - remaining is the number users
        # actually act on, usedPercent alone is not.
        Write-StatusRow $lines -Label '已使用' -Value "$($w.usedPercent)%" -Indent 4
        Write-StatusRow $lines -Label '剩余' -Value "$($w.remainingPct)%" -Indent 4
        if ($w.resetText) { Write-StatusRow $lines -Label '重置时间' -Value $w.resetText -Indent 4 }
    }

    # ---- 异常与建议 ---------------------------------------------------------
    Write-StatusSection $lines '异常与建议'
    $shown = @($findings | Where-Object { @('ERROR', 'WARNING') -contains [string]$_.severity })
    # §11.1's clean sample has no "no problems" row here: 当前状态 already says
    # [正常] 运行正常 at the top, and INFO findings (LOCAL_ONLY, AUTOANCHOR_OFF) are
    # narrated in their own sections rather than listed as advice.
    if ($shown.Count -gt 0) {
        # Worst first: the panel is read top-down and a red row under a yellow one
        # reads as "already handled".
        foreach ($f in @($shown | Where-Object { [string]$_.severity -eq 'ERROR' })) { Write-StatusFinding $lines $f -Detailed:$Detailed }
        foreach ($f in @($shown | Where-Object { [string]$_.severity -eq 'WARNING' })) { Write-StatusFinding $lines $f -Detailed:$Detailed }
    }
    $le = [string]$Model.lastError
    if ($le) {
        Write-StatusRow $lines -Label '最近错误' -Value (Hide-SensitiveText $le) `
            -Severity $(if (Get-StatusFinding -Assessment @{ findings = $findings } -Code 'LAST_ERROR_RECENT') {
                if (Test-StatusOverallIs -Assessment @{ overall = $Model.overall } -Level 'ERROR') { 'ERROR' } else { 'INFO' }
            } else { 'INFO' })
    } else {
        Write-StatusRow $lines -Label '最近错误' -Value '无'
    }

    # ---- 调试详情（可选）----------------------------------------------------
    if ($Detailed) {
        Write-StatusSection $lines '调试详情'
        Write-StatusRow $lines -Label '配置有效' -Value (Format-BooleanZh $Model.configOk)
        Write-StatusRow $lines -Label '原始总体判定' -Value $Model.overall
        Write-StatusRow $lines -Label '额度原始时间' -Value $(if ($q.rawReadAt) { $q.rawReadAt } else { '-' })
        Write-StatusRow $lines -Label 'Git 仓库路径' -Value $(if ($co.repoPath) { $co.repoPath } else { '-' })
        Write-StatusRow $lines -Label '协调启用' -Value (Format-BooleanZh (-not $co.localOnly))
        $rank = @{ ERROR = 0; WARNING = 1; INFO = 2 }
        foreach ($f in @($findings | Sort-Object { [int]$rank[[string]$_.severity] })) {
            Add-StatusLine $lines (' ' * 2)
            Write-StatusFinding $lines $f -Detailed
        }
        if (@($findings).Count -eq 0) { Add-StatusLine $lines ((' ' * 2) + '（无 finding）') }
    }

    Add-StatusLine $lines ''
    Add-StatusLine $lines ('=' * 60)
    return $lines
}

function Get-StatusPanelText {
    # One-call text view for both languages (§14): assessment included, colours
    # already stripped by Format-StatusText. Used by tests, golden snapshots, and
    # any caller that wants the panel as a string instead of on the console.
    param(
        $Status,
        $Assessment = $null,
        [ValidateSet('zh-CN', 'en-US')] [string]$Language = 'zh-CN',
        [switch]$Detailed,
        $Config = $null,
        [string]$KeeperRoot = '',
        [string]$ConfigFile = '',
        [datetime]$Now = (Get-Date)
    )
    if ($null -eq $Assessment) {
        $Assessment = Get-StatusAssessment -Status $Status -Config $Config -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile -Now $Now
    }
    $lines = Get-StatusDisplayLines -Status $Status -Assessment $Assessment -Language $Language -Detailed:$Detailed `
        -Config $Config -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile -Now $Now
    return (Format-StatusText $lines)
}

function Write-StatusTextEn {
    # The pre-v2.0 English view, kept verbatim for -Language en-US (§14) and for the
    # assertions that pin it. No health verdict: the English view is the fact dump.
    param($Status)
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
        $ka = [int]$Status.anchorKeepalive.intervalMinutes
        $kaText = if ($ka -le 0) { 'off (reset/idle triggers only)' } else { "every $ka min" }
        $lastAnchor = [string]$Status.anchorKeepalive.lastAnchorAt
        $lastText = if ($lastAnchor) { $lastAnchor } else { 'never' }
        $lines += ('Anchor backstop     : {0} (last anchor: {1})' -f $kaText, $lastText)
        if ($Status.anchorSchedule) {
            $slots = @($Status.anchorSchedule.slots)
            $slotText = if ($slots.Count -gt 0) { $slots -join ', ' } else { 'none' }
            $lines += ('Scheduled anchor    : {0}' -f $slotText)
        }
        if ($Status.anchorExec) {
            $m = [string]$Status.anchorExec.model
            $e = [string]$Status.anchorExec.reasoningEffort
            if ($m -or $e) {
                $mText = if ($m) { $m } else { 'CLI default' }
                $eText = if ($e) { $e } else { 'CLI default' }
                $lines += ('Anchor exec         : model {0}, effort {1}' -f $mText, $eText)
            }
        }
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
