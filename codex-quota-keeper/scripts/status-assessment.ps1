# Codex Quota Keeper - status assessment layer (design doc v2.0 §8/§9.2/§10/§16).
#
# Layer 2 of the three-layer Status design:
#   Get-KeeperStatus (facts) -> Get-StatusAssessment (verdict) -> renderers (text).
#
# Invariants (§9.2): this layer never writes state and never writes logs. It is a
# throwaway derivation computed while the panel is displayed, so running
# status.cmd can never change what the next run says. It also adds no keys to
# Get-KeeperStatus (§9.1) - the facts the collector does not carry (today's anchor
# count, an open rate limit, backoff) are read from the same runtime files here,
# read-only, so status-json.ps1's English schema stays untouched.
#
# Finding text contract, same reasoning as scripts/anchor-claim.ps1:
#   * `code` / `severity` stay English - machine-readable anchors that docs cite;
#   * `title` / `action` are the Chinese human text (§9.2); `titleEn` / `actionEn`
#     exist because the optional en-US renderer (§14) needs the same finding in
#     English without a second rule engine;
#   * `detail` may legitimately be absent; when it is, the key is REMOVED rather
#     than holding an empty string, so a renderer cannot mistake "" for "no detail";
#   * `detail` is English because it embeds raw values (exit codes, lease expiry,
#     the config validator's own messages) and §7 requires error text to stay
#     traceable to a log line or a config field. The human-facing answer to a
#     finding is title + action, and those are localized.

$script:CqkStatusAssessmentDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkStatusAssessmentDir 'common.ps1')
}
if (-not (Get-Command Load-KeeperState -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkStatusAssessmentDir 'state-machine.ps1')
}

# Fallback for configs that predate the leader section. Must stay equal to
# common.ps1's own leader.graceMinutes default, or the two layers disagree about
# what "grace" means while still looking consistent.
$script:CQK_STATUS_GRACE_FALLBACK_MINUTES = 5

# Win32 exit codes the Task Scheduler reports for states that are not failures:
# 267009 running, 267010 has not yet run, 267011 was disabled. Treating the first
# two as failures would flash a warning on every machine mid-poll or freshly
# installed, which is exactly the false alarm §10 asks this layer not to produce.
$script:CQK_TASK_NON_FAILURE_CODES = @(267009, 267010, 267011)

# code -> @{ severity; title; action; titleEn; actionEn }
# A code with no entry falls back to WARNING + the code as its own title, so
# adding a rule cannot silently produce a finding with no text.
$script:CqkStatusFindingCatalog = @{
    # ---- ERROR: the keeper cannot be running correctly --------------------------
    CONFIG_INVALID              = @{ severity = 'ERROR';   title = '配置无效'; action = '修复 config.json 后执行 apply-config.cmd'; titleEn = 'invalid configuration'; actionEn = 'fix config.json, then run apply-config.cmd' }
    TASK_NOT_INSTALLED          = @{ severity = 'ERROR';   title = '计划任务未安装'; action = '执行 install.cmd'; titleEn = 'scheduled task not installed'; actionEn = 'run install.cmd' }
    TASK_DISABLED               = @{ severity = 'ERROR';   title = '计划任务已禁用'; action = '在任务计划程序中启用，或重新执行 install.cmd'; titleEn = 'scheduled task is disabled'; actionEn = 'enable it in Task Scheduler, or run install.cmd again' }
    CODEX_NOT_FOUND             = @{ severity = 'ERROR';   title = 'Codex CLI 未找到'; action = '设置 codex.command 或检查 Codex 安装与 PATH'; titleEn = 'Codex CLI not found'; actionEn = 'set codex.command or check the Codex install and PATH' }
    COORDINATION_UNREACHABLE    = @{ severity = 'ERROR';   title = '多机协调仓库不可达'; action = '检查网络、Git 凭证与 github.coordination.repoPath 后重试；协调不可达期间自动锚定会失败关闭'; titleEn = 'multi-machine coordination repository unreachable'; actionEn = 'check the network, Git credentials and github.coordination.repoPath; auto-anchoring fails closed while unreachable' }
    ANCHOR_CAP_REACHED          = @{ severity = 'WARNING'; title = '今日锚定已达上限'; action = '确认每日上限是否合理；如需更多可调整 codex.autoAnchor.maxPerDay'; titleEn = 'daily anchor cap reached'; actionEn = 'review the daily cap; raise codex.autoAnchor.maxPerDay if intended' }
    AUTOANCHOR_BLOCKED          = @{ severity = 'ERROR';   title = '当前自动锚定被安全阻止'; action = '按下述原因解除阻止；这是保护机制，不是锚定功能故障'; titleEn = 'auto-anchoring is currently safety-blocked'; actionEn = 'remove the blocking condition below; this is the fail-closed guard working, not an anchor bug' }

    # ---- WARNING: running, but something needs attention -----------------------
    TASK_LAST_RESULT            = @{ severity = 'WARNING'; title = '最近任务执行失败'; action = '查看最近错误与 -Live 检测结果；下个周期会自动重试'; titleEn = 'last task run failed'; actionEn = 'check the recent error and -Live output; the next cycle retries' }
    TASK_LAST_RESULT_PERSISTENT = @{ severity = 'ERROR';   title = '任务连续执行失败'; action = '用 status.ps1 -Live 定位原因（Codex 登录、代理、网络）'; titleEn = 'task keeps failing'; actionEn = 'run status.ps1 -Live to find the cause (Codex sign-in, proxy, network)' }
    TASK_INTERVAL_MISMATCH      = @{ severity = 'WARNING'; title = '计划任务周期与配置不一致'; action = '执行 apply-config.cmd 重新注册计划任务'; titleEn = 'task interval does not match config'; actionEn = 'run apply-config.cmd to re-register the scheduled task' }
    TASK_TIME_LIMIT_TIGHT       = @{ severity = 'WARNING'; title = '单次运行时间余量偏紧'; action = '提高 poll.intervalMinutes，或降低 codex.queryTimeoutSeconds / 关闭远程同步；否则上一次未跑完会被下个周期忽略'; titleEn = 'one run barely fits its poll slot'; actionEn = 'raise poll.intervalMinutes, or lower codex.queryTimeoutSeconds / disable remote sync; otherwise a still-running tick is ignored by the next trigger' }
    QUOTA_NEVER_READ            = @{ severity = 'WARNING'; title = '尚未读取过额度数据'; action = '等待计划任务至少完成一次轮询，或手动运行 runner.ps1'; titleEn = 'no quota data has ever been read'; actionEn = 'wait for one scheduled poll, or run runner.ps1 once' }
    QUOTA_STALE                 = @{ severity = 'WARNING'; title = '额度数据已过期'; action = '查看最近错误，或运行 status.ps1 -Live'; titleEn = 'quota data is stale'; actionEn = 'check the recent error, or run status.ps1 -Live' }
    QUOTA_TOO_OLD               = @{ severity = 'WARNING'; title = '额度数据长时间未更新'; action = '确认计划任务仍在运行；可用 status.ps1 -Live 立即复查'; titleEn = 'quota data is overdue for a refresh'; actionEn = 'confirm the task still runs; status.ps1 -Live re-checks immediately' }
    QUOTA_READ_FAILED           = @{ severity = 'WARNING'; title = '最近一次额度读取失败且未恢复'; action = '运行 status.ps1 -Live 定位认证或网络问题'; titleEn = 'last quota read failed and has not recovered'; actionEn = 'run status.ps1 -Live to isolate an auth or network problem' }
    AUTH_PROBE_FAILED           = @{ severity = 'WARNING'; title = '实时连接检测未通过'; action = '确认已登录 Codex；必要时运行 codex login 重新认证'; titleEn = 'live connection probe failed'; actionEn = 'confirm the Codex sign-in; run codex login to re-authenticate' }
    LEASE_TTL_TOO_SHORT         = @{ severity = 'WARNING'; title = 'Leader 租约短于轮询周期'; action = '将 leader.leaseTtlMinutes 提高到至少 max(2×轮询周期, 轮询周期+grace+抖动)'; titleEn = 'leader lease shorter than the poll interval'; actionEn = 'raise leader.leaseTtlMinutes to at least max(2*poll, poll+grace+jitter)' }
    LEASE_TTL_LOW_MARGIN        = @{ severity = 'WARNING'; title = 'Leader 租约余量偏低'; action = '建议将 leader.leaseTtlMinutes 设为轮询周期的 3 倍（默认 180 分钟）'; titleEn = 'leader lease margin is low'; actionEn = 'prefer leader.leaseTtlMinutes at 3x the poll interval (180 by default)' }
    BACKOFF_ACTIVE              = @{ severity = 'WARNING'; title = '处于退避中'; action = '退避期间不会访问 Codex，到期自动恢复；频繁退避请检查额度与网络'; titleEn = 'in backoff'; actionEn = 'no Codex access until it lifts; if it recurs often, check quota and network' }
    ROLE_UNKNOWN                = @{ severity = 'WARNING'; title = '本机角色未知'; action = '等待一次完整轮询；仍未知时执行 apply-config.cmd 重新注册任务'; titleEn = 'machine role unknown'; actionEn = 'wait for one full poll; if it persists, run apply-config.cmd' }
    LAST_ERROR_RECENT           = @{ severity = 'WARNING'; title = '最近曾出现错误'; action = '确认该错误是否仍在发生；可用 status.ps1 -Live 复查'; titleEn = 'a recent error was recorded'; actionEn = 'confirm whether it still happens; status.ps1 -Live re-checks now' }
    GIT_UNREACHABLE             = @{ severity = 'WARNING'; title = '日志仓库不可达'; action = '检查网络与 Git 凭证；本地日志仍会正常写入'; titleEn = 'log repository unreachable'; actionEn = 'check the network and Git credentials; local logs are still written' }

    # ---- INFO: how it is running, not whether it is broken ---------------------
    LOCAL_ONLY                  = @{ severity = 'INFO'; title = '单机模式'; action = '单台电脑使用正常；多台电脑同时运行需启用 Git 协调'; titleEn = 'single-machine mode (LOCAL_ONLY)'; actionEn = 'normal for one machine; enable Git coordination for several' }
    AUTOANCHOR_ENABLED          = @{ severity = 'INFO'; title = '自动锚定已开启（实验功能）'; action = '该功能会主动调用 Codex 模型并消耗额度'; titleEn = 'auto-anchoring is ON (experimental)'; actionEn = 'this calls the Codex model on its own and consumes quota' }
    PROFILE_INVALID            = @{ severity = 'ERROR'; title = '执行模型配置校验失败'; action = '修正模型或推理强度后运行 Status -Live'; titleEn = 'execution profile is invalid'; actionEn = 'correct model or reasoning effort, then run Status -Live' }
    PROFILE_UNAVAILABLE        = @{ severity = 'WARNING'; title = '执行模型暂时无法校验'; action = '检查 Codex 登录和网络，再运行 Status -Live'; titleEn = 'execution profile is unavailable'; actionEn = 'check Codex login and network, then run Status -Live' }
    PROFILE_STALE              = @{ severity = 'WARNING'; title = '执行模型校验结果已过期或尚不存在'; action = '运行 Status -Live 获取当前校验结果'; titleEn = 'execution profile is stale or missing'; actionEn = 'run Status -Live to validate the current profile' }
    AUTOANCHOR_OFF              = @{ severity = 'INFO'; title = '自动锚定未开启'; action = '当前只读取额度，不会自动调用模型'; titleEn = 'auto-anchoring is OFF'; actionEn = 'quota is read only; no model call is made' }
    ANCHOR_TRIGGERS_OFF         = @{ severity = 'INFO'; title = '自动锚定未配置触发器'; action = '当前仍只查询额度；配置 schedule 和/或 anchorOnExpiry 后才会自动调用模型'; titleEn = 'no auto-anchor trigger configured'; actionEn = 'quota remains read-only; configure schedule and/or anchorOnExpiry to call a model' }
    BACKOFF_ACTIVE_SINGLE       = @{ severity = 'INFO'; title = '本机退避中（单机模式）'; action = '不影响总体状态；到期自动恢复'; titleEn = 'local backoff active (single machine)'; actionEn = 'does not affect the overall verdict in single-machine mode' }
    ROLE_PASSIVE                = @{ severity = 'INFO'; title = '本机为待机节点'; action = '属正常分工：由负责人机器访问 Codex，本机不访问'; titleEn = 'this machine is a passive node'; actionEn = 'normal split: the leader polls Codex, this machine does not' }
    RUNNER_RUNNING              = @{ severity = 'INFO'; title = '轮询进程正在运行'; action = '无需干预'; titleEn = 'runner process is running now'; actionEn = 'no action needed' }
    LIVE_PROBE_OK               = @{ severity = 'INFO'; title = '实时连接检测通过'; action = '无需干预'; titleEn = 'live connection probe passed'; actionEn = 'no action needed' }
    NEXT_RUN_DELAYED            = @{ severity = 'INFO'; title = '下次运行时间晚于预期'; action = '若持续如此，检查电脑睡眠设置与任务计划程序'; titleEn = 'next run is later than expected'; actionEn = 'if it persists, check sleep settings and Task Scheduler' }
    ANCHOR_GAP_COOLDOWN         = @{ severity = 'INFO'; title = '自动锚定处于静默期'; action = '属正常节流；达到 expiry 最小间隔后可再次触发'; titleEn = 'auto-anchor quiet period'; actionEn = 'normal throttling; the next expiry trigger needs the minimum gap' }
}

function Get-StatusFindingCatalog {
    param([string]$Code)
    if ($script:CqkStatusFindingCatalog.ContainsKey($Code)) { return $script:CqkStatusFindingCatalog[$Code] }
    # An unknown code must still render something. Fall back to WARNING, never blank.
    return @{ severity = 'WARNING'; title = "未识别的诊断项（$Code）"; action = '请反馈该诊断码';
              titleEn = 'unrecognized diagnostic code'; actionEn = 'please report this diagnostic code' }
}

function ConvertTo-StatusHashtable {
    # Get-KeeperStatus returns a hashtable; PS7's ConvertFrom-Json returns a
    # [pscustomobject], and so does a cached status.json. Both must be indexable
    # here or the panel would work in one shell and not the other.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [hashtable]) { return $Value }
    if ($Value -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $out = @{}
    foreach ($p in $Value.PSObject.Properties) { $out[[string]$p.Name] = $p.Value }
    return $out
}

function Get-StatusValue {
    # Dotted-path read that tolerates any missing link. Get-KeeperStatus is allowed
    # to return early (config load failure), so half of these paths genuinely do
    # not exist at runtime - throwing over one absent key would take the panel down.
    param($Map, [string]$Path)
    $cur = $Map
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -isnot [hashtable]) {
            $conv = ConvertTo-StatusHashtable $cur
            if ($null -eq $conv) { return $null }
            $cur = $conv
        }
        if (-not $cur.ContainsKey($part)) { return $null }
        $cur = $cur[$part]
    }
    return $cur
}

function New-StatusAssessment {
    # §9.2 shape. findings is always an array so renderers can foreach it without
    # an @() guard. No version/extra keys: the panel's payload is this exactly.
    return @{ overall = 'HEALTHY'; summary = ''; findings = @() }
}

function Add-StatusFinding {
    # Appends one catalog entry to an assessment. Returns nothing on purpose: a
    # finding must not be able to leak into the pipeline.
    [CmdletBinding()]
    param(
        [hashtable]$Assessment,
        [string]$Code,
        [string]$Detail = '',
        [ValidateSet('', 'ERROR', 'WARNING', 'INFO')] [string]$Severity = '',
        [string]$Title = '',
        [string]$Action = '',
        [datetime]$Now = (Get-Date)
    )
    $cat = Get-StatusFindingCatalog $Code
    $f = @{
        code       = $Code
        severity   = $(if ($Severity) { $Severity } else { [string]$cat.severity })
        title      = $(if ($Title)   { $Title }   else { [string]$cat.title })
        action     = $(if ($Action)  { $Action }  else { [string]$cat.action })
        titleEn    = [string]$cat.titleEn
        actionEn   = [string]$cat.actionEn
        observedAt = $Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
    }
    # Absent detail drops the key entirely (see the text contract above).
    if ($Detail) { $f.detail = Hide-SensitiveText ([string]$Detail) }
    $Assessment.findings = @($Assessment.findings) + @($f)
}

function Get-StatusOverall {
    # §10.1: any ERROR wins, else any WARNING, else HEALTHY. INFO never downgrades
    # (LOCAL_ONLY, AutoAnchor ON are running modes, not faults).
    param([hashtable]$Assessment)
    $worst = 'HEALTHY'
    foreach ($f in @($Assessment.findings)) {
        $sev = [string]$f.severity
        if ($sev -eq 'ERROR') { return 'ERROR' }
        if ($sev -eq 'WARNING' -and $worst -ne 'ERROR') { $worst = 'WARNING' }
    }
    return $worst
}

function Set-StatusSummary {
    # Derived from the verdict, so the two can disagree only if Get-StatusOverall
    # is wrong. Chinese only: §9.2 fixes the three literal strings, and the en-US
    # renderer reads verdict + findings directly instead of a translated summary.
    param([hashtable]$Assessment)
    $overall = Get-StatusOverall -Assessment $Assessment
    $Assessment.overall = $overall
    $Assessment.summary = switch ($overall) {
        'ERROR'   { '运行异常' }
        'WARNING' { '存在需要注意的配置' }
        default   { '运行正常' }
    }
    return $Assessment
}

function Get-StatusFinding {
    # The finding with this code, or $null. Renderers use it to answer "was this
    # specific fact reported", not just "how bad is it".
    param([hashtable]$Assessment, [string]$Code)
    foreach ($f in @($Assessment.findings)) { if ([string]$f.code -eq $Code) { return $f } }
    return $null
}

function Test-StatusOverallIs {
    param([hashtable]$Assessment, [ValidateSet('HEALTHY', 'WARNING', 'ERROR')] [string]$Level)
    $rank = @{ HEALTHY = 0; WARNING = 1; ERROR = 2 }
    return ([int]$rank[[string]$Assessment.overall] -ge [int]$rank[$Level])
}

# ---------------------------------------------------------------------------
# Timestamp parsing
#
# ConvertTo-IsoString normalizes what WE write, but state.json is hand-editable
# and PS7's ConvertFrom-Json turns ISO strings into [DateTime] while PS5.1 leaves
# them as strings. Both shapes must be accepted, and "unparseable" has to stay
# distinguishable from "real timestamp" - guessing would misreport how old the
# quota data is.

function ConvertTo-StatusDateTime {
    # $null when the value is absent or unparseable.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value }
    if ($Value -is [DateTimeOffset]) { return $Value.LocalDateTime }
    $s = ([string]$Value).Trim()
    if ($s.Length -eq 0) { return $null }
    $dt = [DateTime]::MinValue
    if ([DateTime]::TryParse($s, [ref]$dt)) { return $dt }
    $dto = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($s, [ref]$dto)) { return $dto.LocalDateTime }
    return $null
}

function Get-StatusMinutesSince {
    # A future timestamp means clock skew; clamped to 0 so an age rule can never
    # point the wrong way (fresh read as stale, or stale read as fresh).
    param($Value, [datetime]$Now = (Get-Date))
    $dt = ConvertTo-StatusDateTime $Value
    if ($null -eq $dt) { return $null }
    $minutes = ($Now - $dt).TotalMinutes
    if ($minutes -lt 0) { return 0 }
    return $minutes
}

function Get-StatusAnchorToday {
    # How many anchors happened today. Anchors are counted per calendar day in
    # state.json (anchors.day + anchors.count), so a day stamped yesterday means
    # today has none yet - reporting yesterday's count as today's would show
    # "6/6" on a machine that has not run yet. Shared with the display layer
    # (autoAnchor.today) so the verdict and the panel cannot disagree.
    param($State, [string]$Today)
    $st = ConvertTo-StatusHashtable $State
    if ([string](Get-StatusValue -Map $st -Path 'anchors.day') -ne $Today) { return 0 }
    return (Get-AnchorStatistics (Get-StatusValue -Map $st -Path 'anchors')).attemptCount
}

# ---------------------------------------------------------------------------
# §16 verdict freshness: is a recorded error still the situation we are in?
#
# There is no VERDICT_* event in the log stream; the runner's own terminal events
# are the verdict. RUNNER_OK is written on the success path, RUNNER_ERROR on the
# catch path, so the newest of the two is the latest verdict and any ERROR-level
# line after it is a failure the machine has not recovered from. A healthy poll
# clears yesterday's failure - the whole rule, needing no new log format and no
# write from this read-only layer.

function Read-StatusLogTail {
    # Newest-first log entries across the last -MaxAgeDays daily files. Same file
    # walk as Get-RecentErrors, minus its ERROR-level filter: the verdict scan has
    # to see the INFO-level RUNNER_OK too, and Get-RecentErrors stops at the first
    # ERROR without ever looking for a verdict.
    param([string]$Root, [int]$MaxAgeDays = 3, [int]$Take = 200)
    $out = New-Object System.Collections.ArrayList
    if (-not $Root) { return @() }
    $logsDir = Get-LogsDir $Root
    if (-not (Test-Path -LiteralPath $logsDir)) { return @() }
    $cutoff = (Get-Date).AddDays(-1 * $MaxAgeDays)
    $files = @(Get-ChildItem -LiteralPath $logsDir -Filter 'keeper-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)
    foreach ($file in $files) {
        if ($file.LastWriteTime -lt $cutoff) { break }
        $lines = @()
        try { $lines = [System.IO.File]::ReadAllLines($file.FullName) } catch { continue }
        [array]::Reverse($lines)
        foreach ($line in $lines) {
            $entry = ConvertFrom-JsonSafe $line
            if ($null -eq $entry) { continue }
            # error is carried for the finding detail only; Add-StatusFinding runs
            # every detail through Hide-SensitiveText, so this stays the one place
            # the mask is applied.
            $null = $out.Add(@{
                ts    = [string]$entry.ts
                level = [string]$entry.level
                event = [string]$entry.event
                error = [string]$entry.error
            })
            if ($out.Count -ge $Take) { return @($out.ToArray()) }
        }
    }
    return @($out.ToArray())
}

function Get-StatusVerdictFreshness {
    # @{ fresh; ageMinutes; thresholdMinutes; reason; event }
    # fresh=$false means "the last thing we know is an unrecovered failure".
    #
    # Fails OPEN on missing data. With no logs there is no ERROR finding to clear,
    # and §10 requires the verdict to be computed from facts: inventing a warning
    # because a machine rotated its logs is the opposite of that. The threshold
    # scales with the poll interval (two cycles + grace + jitter, floor one hour,
    # ceiling twelve) so a slow poller is not accused of staleness.
    #
    # The threshold bounds an *open* verdict, not just a healthy one: an ERROR from
    # yesterday that nothing followed is still an unrecovered failure, but §16.3's
    # tolerance applies to the verdict stream too, so past the horizon it is
    # reported as 'stale-verdict' (fresh) rather than escalated forever.
    [CmdletBinding()]
    param(
        [string]$Root,
        [int]$PollMinutes = 60,
        [datetime]$Now = (Get-Date),
        $Tail = $null
    )
    $poll = [Math]::Max(1, $PollMinutes)
    $threshold = [Math]::Max(60, [Math]::Min(720, 2 * $poll + $script:CQK_STATUS_GRACE_FALLBACK_MINUTES + $script:CQK_SCHEDULING_JITTER_MINUTES))
    $entries = @(if ($null -ne $Tail) { $Tail } elseif ($Root) { Read-StatusLogTail -Root $Root -MaxAgeDays 3 -Take 200 })
    if ($entries.Count -eq 0) {
        return @{ fresh = $true; ageMinutes = $null; thresholdMinutes = $threshold; reason = 'no-logs'; event = '' }
    }
    $verdictIndex = -1; $verdictEvent = ''; $verdictTs = $null; $verdictError = ''
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $ev = [string]$entries[$i].event
        if ($ev -eq 'RUNNER_OK' -or $ev -eq 'RUNNER_ERROR') {
            $verdictIndex = $i; $verdictEvent = $ev
            $verdictTs = ConvertTo-StatusDateTime $entries[$i].ts
            $verdictError = [string]$entries[$i].error
            break
        }
    }
    if ($verdictIndex -lt 0) {
        # Logs exist but hold no verdict yet. Nothing to escalate.
        return @{ fresh = $true; ageMinutes = $null; thresholdMinutes = $threshold; reason = 'no-verdict'; event = '' }
    }
    $age = if ($null -ne $verdictTs) { [Math]::Max(0, ($Now - $verdictTs).TotalMinutes) } else { $null }
    $openVerdict = @{ fresh = $false; ageMinutes = $age; thresholdMinutes = $threshold; reason = ''; event = $verdictEvent; error = $verdictError }
    if ($verdictEvent -eq 'RUNNER_ERROR') {
        $openVerdict.reason = 'last-verdict-error'
        # Unparseable stamp: age unknown, so keep the escalation (fail-closed).
        if ($null -ne $age -and $age -gt $threshold) { $openVerdict.fresh = $true; $openVerdict.reason = 'stale-verdict' }
        return $openVerdict
    }
    for ($i = $verdictIndex + 1; $i -lt $entries.Count; $i++) {
        if ([string]$entries[$i].level -ne 'ERROR') { continue }
        $later = ConvertTo-StatusDateTime $entries[$i].ts
        # An unparseable stamp cannot be ordered; treat it as "still open"
        # (fail-closed) rather than dropping a real failure.
        if ($null -ne $verdictTs -and $null -ne $later -and $later -lt $verdictTs) { continue }
        $openVerdict.reason = 'error-after-verdict'
        $openVerdict.event = [string]$entries[$i].event
        $openVerdict.error = [string]$entries[$i].error
        if ($null -ne $age -and $age -gt $threshold) { $openVerdict.fresh = $true; $openVerdict.reason = 'stale-verdict' }
        return $openVerdict
    }
    return @{ fresh = $true; ageMinutes = $age; thresholdMinutes = $threshold; reason = 'ok'; event = $verdictEvent; error = $verdictError }
}

function Get-StatusAnchorBlock {
    # §16.5: is the AutoAnchor guard currently refusing to fire? Returns
    # @{ code; severity; detail } for the first blocking condition, else $null.
    #
    # The conditions mirror Test-ShouldAnchor's fail-closed list AND its order
    # (scripts/state-machine.ps1), so the panel cannot drift from the guard: a
    # machine that would refuse to anchor must say so, and one that would anchor
    # must not claim otherwise. §16.5: the AutoAnchor banner alone never makes the
    # system ERROR - so a routine refusal (gap) is INFO, a protective one is
    # ERROR, and backoff is WARNING.
    #
    # Backoff and the lease are hoisted above the in-guard list because they are
    # gates *outside* Test-ShouldAnchor: the runner never asks the guard whether
    # the snapshot is trustworthy while it is parked in backoff or does not hold
    # the lease. The panel has to reproduce that whole chain, not just the guard.
    [CmdletBinding()]
    param(
        [bool]$QuotaStale = $false,
        [string]$RateLimitReachedType = '',
        [bool]$SchemaUnknown = $false,
        [bool]$LocalOnly = $true,
        [string]$Role = 'LEADER',
        [bool]$BackoffActive = $false,
        [string]$BackoffUntilText = '',
        [string]$BackoffReason = '',
        [int]$AnchorTodayCount = 0,
        [int]$MaxPerDay = 0,
        [int]$MinimumGapMinutes = 0,
        [bool]$ScheduleMode = $false,
        $LastAnchorAt = $null,
        [datetime]$Now = (Get-Date)
    )
    if ($BackoffActive) {
        # Upstream of the guard: the runner parks on role=BACKOFF and never asks
        # Test-ShouldAnchor whether this cycle's snapshot is trustworthy.
        $reason = if ($BackoffReason) { " ($BackoffReason)" } else { '' }
        return @{ code = 'BACKOFF_ACTIVE'; severity = 'WARNING'; detail = "in backoff until $BackoffUntilText$reason" }
    }
    if (-not $LocalOnly -and $Role -ne 'LEADER') {
        # Guard step "machine does not hold the leader lease" - also ahead of every
        # snapshot-quality check, since a non-leader has no snapshot of its own.
        # PASSIVE / UNKNOWN / BACKOFF / DEGRADED all mean "this machine may not anchor".
        return @{ code = 'AUTOANCHOR_BLOCKED'; severity = 'ERROR'; detail = "machine does not hold the leader lease (role=$Role)" }
    }
    if ($RateLimitReachedType) {
        return @{ code = 'AUTOANCHOR_BLOCKED'; severity = 'ERROR'; detail = "usage limit reached ($RateLimitReachedType) is still open" }
    }
    if ($SchemaUnknown) {
        return @{ code = 'AUTOANCHOR_BLOCKED'; severity = 'ERROR'; detail = 'unknown rate-limit schema in the last read' }
    }
    if ($MaxPerDay -gt 0 -and $AnchorTodayCount -ge $MaxPerDay) {
        # WARNING, not ERROR: a capped day is the guard doing what the user
        # configured. §16.5 says AutoAnchor's own limits must not read as a fault.
        # Ordered with the quota check because both are true at once on a real
        # capped-and-stale cycle, and "你今天的次数用完了" is the only one the user
        # can act on; the stale read already has its own QUOTA_STALE finding.
        return @{ code = 'ANCHOR_CAP_REACHED'; severity = 'WARNING'; detail = "daily anchor cap reached ($AnchorTodayCount/$MaxPerDay)" }
    }
    if ($QuotaStale) {
        return @{ code = 'AUTOANCHOR_BLOCKED'; severity = 'ERROR'; detail = 'quota read failed last cycle; the guard fails closed on a snapshot it cannot trust' }
    }
    # In schedule mode the minimum gap does not apply (Test-ShouldAnchor checks it
    # only for judgment triggers), so quoting it there would be a false alarm.
    if (-not $ScheduleMode -and $MinimumGapMinutes -gt 0) {
        $since = Get-StatusMinutesSince -Value $LastAnchorAt -Now $Now
        if ($null -ne $since -and $since -lt $MinimumGapMinutes) {
            return @{ code = 'ANCHOR_GAP_COOLDOWN'; severity = 'INFO'; detail = "minimum anchor gap not elapsed ($([int]$since) < $MinimumGapMinutes min)" }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# The assessment

function Get-StatusAssessment {
    # Inputs:
    #   Status     - a Get-KeeperStatus object (the fact layer, unmodified), or the
    #                same data as a pscustomobject / ConvertFrom-Json result.
    #   Config     - optional merged config or Load-Config result; avoids a second
    #                config.json read.
    #   KeeperRoot - where runtime/ lives; defaults to the install directory.
    #   ConfigFile - defaults to <KeeperRoot>\config.json.
    #   Now        - clock injection for deterministic tests.
    # Output: @{ overall; summary; findings } (§9.2).
    [CmdletBinding()]
    param(
        $Status,
        $Config = $null,
        [string]$KeeperRoot = '',
        [string]$ConfigFile = '',
        [datetime]$Now = (Get-Date)
    )
    $a = New-StatusAssessment
    $s = ConvertTo-StatusHashtable $Status
    if ($null -eq $s -or $s.Count -eq 0) {
        Add-StatusFinding -Assessment $a -Code 'CONFIG_INVALID' -Detail 'no status object was supplied to the assessment layer' -Now $Now
        return (Set-StatusSummary -Assessment $a)
    }
    # Single-argument form of the dotted reads below.
    $gv = { param([string]$p) Get-StatusValue -Map $s -Path $p }

    # ---- §10 row 1: configuration -------------------------------------------
    # configOk=false means the validator reported issues. Get-KeeperStatus may also
    # have returned before collecting anything; either way every other field is a
    # default, so the panel stops here instead of inventing twelve findings for one
    # broken config file.
    if (-not [bool](& $gv 'configOk')) {
        Add-StatusFinding -Assessment $a -Code 'CONFIG_INVALID' -Detail ([string](& $gv 'lastError')) -Now $Now
        return (Set-StatusSummary -Assessment $a)
    }

    if (-not $KeeperRoot) { $KeeperRoot = Get-KeeperRoot }
    if (-not $ConfigFile) { $ConfigFile = Get-ConfigPath $KeeperRoot }
    $poll = [int](& $gv 'pollIntervalMinutes')
    if ($poll -le 0) { $poll = 60 }

    # Load-Config also strips JSONC comments, which ConvertFrom-Json alone cannot.
    $cfg = ConvertTo-StatusHashtable $Config
    if ($null -eq $cfg) {
        $loaded = Load-Config $ConfigFile
        # An invalid config was already reported through configOk, so a null config
        # here means the file went away between the two reads: nothing to derive.
        if ($null -eq $loaded.config) {
            Add-StatusFinding -Assessment $a -Code 'CONFIG_INVALID' -Detail ((@($loaded.issues) | Where-Object { $_ }) -join '; ') -Now $Now
            return (Set-StatusSummary -Assessment $a)
        }
        $cfg = $loaded.config
    }

    # Facts Get-KeeperStatus does not carry. Read-only, from the same files the
    # runner writes; §9.1 keeps them out of the stable status object.
    $state = ConvertTo-StatusHashtable (Load-KeeperState $KeeperRoot)
    $backoff = Get-BackoffState $KeeperRoot
    $anchorCfg = ConvertTo-StatusHashtable (Get-AutoAnchorConfig $cfg)
    $coordCfg = ConvertTo-StatusHashtable (Get-CoordinationConfig $cfg)
    $today = $Now.ToString('yyyy-MM-dd')
    # Anchors are counted per calendar day; a stale day means today has none yet.
    # One call to the shared helper rather than a second copy of the rule, so the
    # verdict's cap check and the panel's 今日已执行 cannot drift apart.
    $anchorToday = Get-StatusAnchorToday -State $state -Today $today

    # ---- scheduled task ----------------------------------------------------
    $taskInstalled = [bool](& $gv 'task.installed')
    $taskEnabled = [bool](& $gv 'task.enabled')
    if (-not $taskInstalled) {
        Add-StatusFinding -Assessment $a -Code 'TASK_NOT_INSTALLED' -Now $Now
    } else {
        if (-not $taskEnabled) {
            Add-StatusFinding -Assessment $a -Code 'TASK_DISABLED' -Now $Now
        }
        $lastResult = & $gv 'task.lastResult'
        if ($null -ne $lastResult -and [int]$lastResult -ne 0) {
            $code = [int]$lastResult
            if ($script:CQK_TASK_NON_FAILURE_CODES -notcontains $code) {
                $detail = "task last exited with code $code"
                $failures = [int](Get-StatusValue -Map $state -Path 'consecutiveReadFailures')
                if ($failures -ge 3) {
                    # §10 row 4: "连续失败可升级 ERROR".
                    Add-StatusFinding -Assessment $a -Code 'TASK_LAST_RESULT_PERSISTENT' `
                        -Detail "$detail (consecutive read failures: $failures)" -Now $Now
                } else {
                    Add-StatusFinding -Assessment $a -Code 'TASK_LAST_RESULT' -Detail $detail -Now $Now
                }
            }
        }
        # §16.2: the finding has to name the fix, not just the mismatch.
        $taskInterval = & $gv 'task.intervalMinutes'
        if ($null -ne $taskInterval -and [int]$taskInterval -ne $poll) {
            Add-StatusFinding -Assessment $a -Code 'TASK_INTERVAL_MISMATCH' `
                -Detail "task repeats every $([int]$taskInterval) min, config says $poll min" -Now $Now
        }
        # CQK-031: the derived ExecutionTimeLimit is clamped to poll - 2 min so a
        # hung runner cannot swallow the next trigger. When that clamp is what
        # decided the limit, the worst-case run time sits inside 2 minutes of the
        # poll interval: legal (the validator hard-fails past that) but tight
        # enough that a slow proxy round-trip shows up as a dropped poll instead.
        # Every number here comes from the config, because that is what the
        # installer derived the limit from; the status-side poll would only add a
        # second, drifting figure (and its own TASK_INTERVAL_MISMATCH row).
        $limit = Get-KeeperTaskExecutionTimeLimit $cfg
        if ($limit.cappedByPoll) {
            $cfgPoll = [int](Get-PollConfig $cfg).intervalMinutes
            Add-StatusFinding -Assessment $a -Code 'TASK_TIME_LIMIT_TIGHT' `
                -Detail "worst-case run $([int]$limit.budgetSeconds) s vs a $cfgPoll min poll; task limit clamped to $([int]$limit.minutes) min" -Now $Now
        }
        $nextRun = ConvertTo-StatusDateTime (& $gv 'task.nextRunTime')
        if ($null -ne $nextRun -and ($nextRun - $Now).TotalMinutes -gt (2.5 * $poll)) {
            Add-StatusFinding -Assessment $a -Code 'NEXT_RUN_DELAYED' -Severity 'INFO' `
                -Detail "next run in $([int](($nextRun - $Now).TotalMinutes)) min, expected within $([int](2.5 * $poll))" -Now $Now
        }
    }

    # ---- §10 row 5: Codex CLI ---------------------------------------------
    # -Live stays the collector's concern: this layer only reacts to whether the
    # collector reported a probe result (non-null liveOk), never to a flag.
    $liveOk = & $gv 'codex.liveOk'
    if (-not [bool](& $gv 'codex.found')) {
        Add-StatusFinding -Assessment $a -Code 'CODEX_NOT_FOUND' -Now $Now
    } elseif ($null -ne $liveOk) {
        if ([bool]$liveOk) {
            Add-StatusFinding -Assessment $a -Code 'LIVE_PROBE_OK' -Detail ('probe at ' + $Now.ToString('yyyy-MM-dd HH:mm:ss')) -Now $Now
        } else {
            Add-StatusFinding -Assessment $a -Code 'AUTH_PROBE_FAILED' -Detail ([string](& $gv 'codex.liveError')) -Now $Now
        }
    }

    # ---- §16.3 quota freshness --------------------------------------------
    $lastReadAt = [string](& $gv 'quota.lastReadAt')
    $ageMinutes = Get-StatusMinutesSince -Value $lastReadAt -Now $Now
    if ([string]::IsNullOrWhiteSpace($lastReadAt)) {
        if ($taskInstalled -and $taskEnabled) {
            Add-StatusFinding -Assessment $a -Code 'QUOTA_NEVER_READ' -Now $Now
        } else {
            # A missing/disabled task already explains it: one cause, one finding.
            Add-StatusFinding -Assessment $a -Code 'QUOTA_NEVER_READ' -Severity 'INFO' -Now $Now
        }
    } else {
        if ([bool](& $gv 'quota.stale')) {
            Add-StatusFinding -Assessment $a -Code 'QUOTA_STALE' `
                -Detail $(if ($null -ne $ageMinutes) { "last read $([int]$ageMinutes) min ago and that read failed" } else { 'the last read failed' }) -Now $Now
        }
        $grace = [int](Get-StatusValue -Map $cfg -Path 'leader.graceMinutes')
        if ($grace -le 0) { $grace = $script:CQK_STATUS_GRACE_FALLBACK_MINUTES }
        $tolerance = $grace + $script:CQK_SCHEDULING_JITTER_MINUTES
        $tooOld = 2 * $poll + $tolerance
        if ($null -ne $ageMinutes -and $ageMinutes -gt $tooOld) {
            Add-StatusFinding -Assessment $a -Code 'QUOTA_TOO_OLD' `
                -Detail "last read $([int]$ageMinutes) min ago, threshold $tooOld min (2 x $poll + $tolerance)" -Now $Now
        }
    }

    # ---- §16.4 multi-machine coordination ---------------------------------
    $localOnly = [bool](& $gv 'role.localOnly')
    $role = [string](& $gv 'role.role'); if (-not $role) { $role = 'UNKNOWN' }
    $gitReachable = & $gv 'git.reachable'

    if ($localOnly) {
        # §7/§16.4: LOCAL_ONLY is a running mode, not a fault. Always INFO, so the
        # default single-machine panel never reads as a "MULTI-PC UNSAFE" warning.
        $hint = ''
        if ([bool](Get-StatusValue -Map $cfg -Path 'leader.enabled') -and -not [bool]$coordCfg.enabled) {
            $hint = 'leader.enabled is true but github.coordination.enabled is false'
        }
        Add-StatusFinding -Assessment $a -Code 'LOCAL_ONLY' -Detail $hint -Now $Now
        # BACKOFF_ACTIVE_SINGLE keys off runtime/backoff.json, not off role.role:
        # the file is what the runner actually honours, and status.ps1 only reports
        # role=BACKOFF when the coordination layer set it - which never happens in
        # single-machine mode, so gating on the role would hide the fact entirely.
        # Set-Backoff/Get-BackoffState stamp and compare against the real wall
        # clock, so this is the one finding the injected $Now cannot drive.
        if ($null -ne $backoff) {
            $bkUntil = $backoff.until.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
            $bkReason = if ($backoff.reason) { "; reason $($backoff.reason)" } else { '' }
            Add-StatusFinding -Assessment $a -Code 'BACKOFF_ACTIVE_SINGLE' `
                -Detail "backoff until $bkUntil$bkReason" -Now $Now
        } elseif ($role -eq 'BACKOFF') {
            Add-StatusFinding -Assessment $a -Code 'BACKOFF_ACTIVE_SINGLE' -Now $Now
        } elseif ($role -eq 'UNKNOWN') {
            Add-StatusFinding -Assessment $a -Code 'ROLE_UNKNOWN' -Severity 'INFO' -Now $Now
        }
    } else {
        # Coordination is on: reachability is the fact that decides (§16.4).
        if ($null -eq $gitReachable) {
            Add-StatusFinding -Assessment $a -Code 'GIT_UNREACHABLE' -Detail 'reachability could not be determined' -Now $Now
        } elseif (-not [bool]$gitReachable) {
            Add-StatusFinding -Assessment $a -Code 'COORDINATION_UNREACHABLE' -Detail "repoPath=$(& $gv 'git.repoPath')" -Now $Now
        }
        # §16.1 lease vs poll, only when coordination is genuinely enabled: a
        # single machine never lets the lease expire between two polls, so warning
        # there would be noise on every default install.
        if ([bool]$coordCfg.enabled) {
            $ttl = [int](Get-StatusValue -Map $cfg -Path 'leader.leaseTtlMinutes')
            $graceN = [int](Get-StatusValue -Map $cfg -Path 'leader.graceMinutes')
            if ($graceN -le 0) { $graceN = $script:CQK_STATUS_GRACE_FALLBACK_MINUTES }
            $effective = $ttl + $graceN
            if ($effective -le $poll) {
                Add-StatusFinding -Assessment $a -Code 'LEASE_TTL_TOO_SHORT' `
                    -Detail "lease $ttl min + grace $graceN min = $effective min, poll $poll min" -Now $Now
            } elseif ($ttl -lt 2 * $poll) {
                Add-StatusFinding -Assessment $a -Code 'LEASE_TTL_LOW_MARGIN' `
                    -Detail "lease $ttl min is under 2 x poll ($poll min)" -Now $Now
            }
        }
        if ($role -eq 'UNKNOWN') {
            Add-StatusFinding -Assessment $a -Code 'ROLE_UNKNOWN' -Now $Now
        } elseif ($role -eq 'BACKOFF') {
            Add-StatusFinding -Assessment $a -Code 'BACKOFF_ACTIVE' -Now $Now
        } elseif ($role -eq 'PASSIVE') {
            # Name the machine that is ahead of this one, so "待机节点" is an
            # explainable fact rather than a mystery. Add-StatusFinding masks the
            # detail, so an owner label coming from the shared repo is safe here.
            $holder = [string](& $gv 'role.leaderOwner')
            $lease = [string](& $gv 'role.leaseExpiresAt')
            $pd = @()
            if ($holder) { $pd += "leader=$holder" }
            if ($lease) { $pd += "lease until $lease" }
            Add-StatusFinding -Assessment $a -Code 'ROLE_PASSIVE' -Detail ($pd -join '; ') -Now $Now
        }
    }

    # ---- §16.5 AutoAnchor --------------------------------------------------
    $slots = @(& $gv 'anchorSchedule.slots')
    if ([bool](& $gv 'autoAnchor')) {
        # The banner itself never changes overall: severity pinned at INFO (§16.5).
        Add-StatusFinding -Assessment $a -Code 'AUTOANCHOR_ENABLED' -Severity 'INFO' `
            -Detail "daily cap $([int]$anchorCfg.maxPerDay); today $anchorToday" -Now $Now
        $ep = & $gv 'executionProfile'
        if ($null -ne $ep) {
            $validation = [string](Get-StatusValue -Map $ep -Path 'value.validation')
            $profileCode = ''
            if ([bool]$ep.stale) { $profileCode = 'PROFILE_STALE' }
            elseif ($validation -in @('INVALID', 'UNAVAILABLE')) { $profileCode = "PROFILE_$validation" }
            # A failed runtime probe does not overwrite the usable profile cache.
            # A later RUNNER_OK only proves quota polling, not profile recovery.
            if ($ep.source -ne 'live') {
                $cacheAt = ConvertTo-StatusDateTime (Get-StatusValue -Map $ep -Path 'value.validatedAt')
                foreach ($entry in @(Read-StatusLogTail -Root $KeeperRoot -Take 200)) {
                    if ($entry.event -eq 'ANCHOR_EXECUTED') { break }
                    if ($entry.event -notin @('ANCHOR_PROFILE_INVALID', 'ANCHOR_PROFILE_UNAVAILABLE')) { continue }
                    $failureAt = ConvertTo-StatusDateTime $entry.ts
                    if ($null -ne $failureAt -and ($Now - $failureAt).TotalMinutes -le (2 * $poll) -and
                        ($null -eq $cacheAt -or $failureAt -ge $cacheAt)) {
                        $profileCode = $entry.event -replace '^ANCHOR_', ''
                    }
                    break
                }
            }
            if ($profileCode) { Add-StatusFinding -Assessment $a -Code $profileCode -Detail ([string]$ep.reason) -Now $Now }
        }
        $nonEmptySlots = @($slots | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $expiryWindows = @(& $gv 'anchorExpiry.windows') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        if ($nonEmptySlots.Count -eq 0 -and @($expiryWindows).Count -eq 0) {
            Add-StatusFinding -Assessment $a -Code 'ANCHOR_TRIGGERS_OFF' -Now $Now
        }
        $block = Get-StatusAnchorBlock -QuotaStale ([bool](& $gv 'quota.stale')) `
            -RateLimitReachedType ([string](Get-StatusValue -Map $state -Path 'rateLimitReachedType')) `
            -SchemaUnknown ([bool](Get-StatusValue -Map $state -Path 'schemaUnknown')) `
            -LocalOnly $localOnly -Role $role `
            -BackoffActive ($null -ne $backoff) `
            -BackoffUntilText $(if ($null -ne $backoff) { $backoff.until.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }) `
            -BackoffReason $(if ($null -ne $backoff) { [string]$backoff.reason } else { '' }) `
            -AnchorTodayCount $anchorToday -MaxPerDay ([int]$anchorCfg.maxPerDay) `
            -MinimumGapMinutes ([int]$anchorCfg.minimumGapMinutes) `
            -ScheduleMode ($nonEmptySlots.Count -gt 0) `
            -LastAnchorAt (Get-StatusValue -Map $state -Path 'anchors.lastAnchorAt') -Now $Now
        if ($block) {
            Add-StatusFinding -Assessment $a -Code $block.code -Severity $block.severity -Detail $block.detail -Now $Now
        }
    } else {
        # §11 gives the AutoAnchor section an entry either way: "off" is a fact the
        # user should see (it is the default), and the cap/today pair says the
        # guard is armed even while nothing fires. INFO - a closed experiment is
        # not a fault (§16.5).
        Add-StatusFinding -Assessment $a -Code 'AUTOANCHOR_OFF' -Severity 'INFO' `
            -Detail "daily cap $([int]$anchorCfg.maxPerDay); today $anchorToday" -Now $Now
    }

    # ---- runner process ----------------------------------------------------
    if ([bool](& $gv 'process.runnerRunningNow')) {
        Add-StatusFinding -Assessment $a -Code 'RUNNER_RUNNING' -Detail "pid $(& $gv 'process.pid')" -Now $Now
    }

    # ---- §10 lastError, gated on the verdict so it cannot stay red forever --
    $lastError = & $gv 'lastError'
    if ($lastError) {
        $detail = "last error: $lastError"
        $verdict = Get-StatusVerdictFreshness -Root $KeeperRoot -PollMinutes $poll -Now $Now
        if ($verdict.fresh) {
            # "曾出现错误，但当前运行正常" (§10): informational, not a red panel.
            Add-StatusFinding -Assessment $a -Code 'LAST_ERROR_RECENT' -Severity 'INFO' -Detail $detail -Now $Now
        } else {
            Add-StatusFinding -Assessment $a -Code 'LAST_ERROR_RECENT' -Detail $detail -Now $Now
            if ([string]$verdict.reason -eq 'last-verdict-error') {
                # Point at the log line that is still open, not at the flattened
                # lastError (which could be an older, already-recovered error).
                $vd = "last verdict $($verdict.event)"
                if ($verdict.error) { $vd += ": $($verdict.error)" }
                Add-StatusFinding -Assessment $a -Code 'QUOTA_READ_FAILED' -Detail $vd -Now $Now
            }
        }
    }

    return (Set-StatusSummary -Assessment $a)
}

if ($MyInvocation.InvocationName -ne '.') {
    # Self-run: prints the verdict for this machine - the quickest way to see what
    # the panel will claim without building the renderer.
    #
    # status.ps1 is dot-sourced here, and its param block re-binds $KeeperRoot /
    # $ConfigFile / $Live in this scope with empty defaults (same trap as
    # status-json.ps1). This block only runs when this file is *executed*, where
    # the script-level param defaults already hold - but capture first anyway, so
    # the ordering never becomes load-bearing.
    $AvKeeperRoot = if ($KeeperRoot) { $KeeperRoot } else { Get-KeeperRoot }
    $AvConfigFile = if ($ConfigFile) { $ConfigFile } else { Get-ConfigPath $AvKeeperRoot }
    $AvLive = [bool]$Live
    . (Join-Path $script:CqkStatusAssessmentDir 'status.ps1')
    $sv = Get-KeeperStatus -KeeperRoot $AvKeeperRoot -ConfigFile $AvConfigFile -Live:$AvLive
    $av = Get-StatusAssessment -Status $sv -KeeperRoot $AvKeeperRoot -ConfigFile $AvConfigFile
    Write-Host "overall : $($av.overall)"
    Write-Host "summary : $($av.summary)"
    foreach ($f in @($av.findings)) {
        Write-Host ("[{0}] {1}  {2}" -f $f.severity, $f.code, $f.title)
        if ($f.detail) { Write-Host ("         detail : {0}" -f $f.detail) }
        Write-Host ("         action : {0}" -f $f.action)
    }
    exit 0
}
