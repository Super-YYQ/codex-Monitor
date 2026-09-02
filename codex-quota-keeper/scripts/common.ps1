# Codex Quota Keeper - shared facilities.
# Dot-source only; every function takes explicit -Root so tests can run in temp dirs.

# Captured while dot-sourcing: $PSCommandPath inside a function would resolve to the caller.
$script:CqkCommonDir = Split-Path -Parent $PSCommandPath

# Exit codes used by runner/install layer.
$script:CQK_EXIT_OK          = 0
$script:CQK_EXIT_FATAL       = 1   # config/preflight fatal
$script:CQK_EXIT_RUNTIME     = 2   # unexpected runtime failure

# Program floor: config may raise minimumPollIntervalMinutes above this, never lower it.
$script:CQK_MIN_POLL_FLOOR_MINUTES = 5
$script:CQK_VERSION = '0.9.0-beta'

function Get-KeeperScriptDir {
    return $script:CqkCommonDir
}

function Get-KeeperRoot {
    param([string]$Root)
    if ($Root) { return [System.IO.Path]::GetFullPath($Root) }
    # common.ps1 lives in <root>/scripts
    return (Split-Path -Parent $script:CqkCommonDir)
}

function Get-RuntimeDir   { param([string]$Root) Join-Path (Get-KeeperRoot $Root) 'runtime' }
function Get-LogsDir      { param([string]$Root) Join-Path (Get-RuntimeDir $Root) 'logs' }
function Get-LockDir      { param([string]$Root) Join-Path (Get-RuntimeDir $Root) 'lock' }
function Get-HistoryDir   { param([string]$Root) Join-Path (Get-KeeperRoot $Root) 'history' }
function Get-ConfigPath   { param([string]$Root) Join-Path (Get-KeeperRoot $Root) 'config.json' }
function Get-StatePath    { param([string]$Root) Join-Path (Get-RuntimeDir $Root) 'state.json' }
function Get-MachinePath  { param([string]$Root) Join-Path (Get-RuntimeDir $Root) 'machine.json' }
function Get-BackoffPath  { param([string]$Root) Join-Path (Get-RuntimeDir $Root) 'backoff.json' }

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    return $Path
}

# ---------------------------------------------------------------------------
# JSON helpers (work on PowerShell 5.1 and 7)

function ConvertTo-HashtableDeep {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($k in $Value.Keys) { $out[$k] = ConvertTo-HashtableDeep $Value[$k] }
        return $out
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $out = @{}
        foreach ($p in $Value.PSObject.Properties) {
            $out[$p.Name] = ConvertTo-HashtableDeep $p.Value
        }
        return $out
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [byte[]]) {
        $list = @()
        foreach ($item in $Value) { $list += ,(ConvertTo-HashtableDeep $item) }
        # Unary comma: without it PowerShell unrolls a single-element array into
        # the element itself and callers lose the "is this an array?" contract.
        return ,$list
    }
    return $Value
}

function ConvertFrom-JsonSafe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try {
        return ConvertTo-HashtableDeep (ConvertFrom-Json (Remove-JsonComments $Text))
    } catch {
        return $null
    }
}

function Remove-JsonComments {
    # JSONC support: strips // line comments and /* */ block comments that appear
    # OUTSIDE double-quoted strings (\" escapes respected), so config.example.jsonc
    # can carry Chinese annotations while still parsing as JSON. A // inside a
    # string value (e.g. "http://127.0.0.1:7890") is never treated as a comment.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $sb = [System.Text.StringBuilder]::new($Text.Length)
    $i = 0
    $n = $Text.Length
    $inString = $false
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($inString) {
            [void]$sb.Append($c)
            if ($c -eq '\' -and $i + 1 -lt $n) {
                [void]$sb.Append($Text[$i + 1]); $i += 2; continue
            }
            if ($c -eq '"') { $inString = $false }
            $i += 1; continue
        }
        if ($c -eq '"') {
            $inString = $true; [void]$sb.Append($c); $i += 1; continue
        }
        if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '/') {
            $i += 2
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i += 1 }
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '*') {
            $i += 2
            while ($i + 1 -lt $n -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i += 1 }
            $i += 2
            continue
        }
        [void]$sb.Append($c); $i += 1
    }
    return $sb.ToString()
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        return ConvertFrom-JsonSafe $text
    } catch {
        return $null
    }
}

function Write-JsonFileAtomic {
    # Temp file + move so readers never observe a half-written state file.
    param([string]$Path, $Value)
    $dir = Split-Path -Parent $Path
    if ($dir) { Ensure-Directory $dir | Out-Null }
    $json = ConvertTo-Json -InputObject $Value -Depth 12
    $tmp = "$Path.tmp-$PID"
    [System.IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-JsonLine {
    param([string]$Path, $Value)
    Ensure-Directory (Split-Path -Parent $Path) | Out-Null
    $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    [System.IO.File]::AppendAllText($Path, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Time helpers

function Get-IsoTimestamp {
    return (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function ConvertFrom-EpochSeconds {
    param([long]$Seconds)
    return [DateTimeOffset]::FromUnixTimeSeconds($Seconds).LocalDateTime
}

function ConvertTo-EpochSeconds {
    param([DateTime]$Value)
    return [DateTimeOffset]::new($Value.ToLocalTime()).ToUnixTimeSeconds()
}

function Get-DatePartUtc {
    param([DateTime]$Value)
    return $Value.ToUniversalTime().ToString('yyyy-MM-dd')
}

function ConvertTo-IsoString {
    # PS7's ConvertFrom-Json parses ISO strings into [DateTime]; re-stringifying
    # those with [string] produces a locale format. Always normalize to ISO.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToString('yyyy-MM-ddTHH:mm:sszzz') }
    if ($Value -is [DateTimeOffset]) { return $Value.ToString('yyyy-MM-ddTHH:mm:sszzz') }
    return [string]$Value
}

# ---------------------------------------------------------------------------
# Hashing (event id per doc: SHA-256("300|1788062400|reset"))

function Get-Sha256Hex {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Sanitization: never let credential-looking material into logs/history.

function Hide-SensitiveText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $result = $Text
    $result = [regex]::Replace($result, 'sk-[A-Za-z0-9_\-]{6,}', '[REDACTED]')
    # GitHub token families (audit plan v1.0 §11 / CQK-012)
    $result = [regex]::Replace($result, '(?i)ghp_[A-Za-z0-9]{16,}', '[REDACTED]')
    $result = [regex]::Replace($result, '(?i)gh[ousr]_[A-Za-z0-9]{16,}', '[REDACTED]')
    $result = [regex]::Replace($result, '(?i)github_pat_[A-Za-z0-9_]{20,}', '[REDACTED]')
    # URL userinfo: scheme://user:pass@host/ -> scheme://[REDACTED]@host/
    $result = [regex]::Replace($result, '([a-z][a-z0-9+.\-]*://)[^/\s@]+@', '$1[REDACTED]@')
    $result = [regex]::Replace($result, '(?i)bearer\s+[^\s"'',;}]+', 'Bearer [REDACTED]')
    $result = [regex]::Replace(
        $result,
        '(?i)(openai[-_ ]?api[-_ ]?key|access[_-]?token|refresh[_-]?token|authorization|cookie|session[_-]?id|api[_-]?key|password|secret|token)(\s*[=:]\s*)"?[^"\s,;}]*"?',
        '$1$2[REDACTED]')
    return $result
}

# Allowlist for records that reach history/ or remote sync.
$script:CQK_HISTORY_ALLOWED_KEYS = @(
    'ts', 'event', 'machineId', 'machineLabel', 'role', 'mode',
    'windows', 'anchor', 'error', 'summary', 'version'
)

function Sanitize-Record {
    # machineLabel is only kept when explicitly allowed (logging.includeMachineLabel).
    param([hashtable]$Record, [switch]$IncludeMachineLabel)
    $out = @{}
    foreach ($key in $script:CQK_HISTORY_ALLOWED_KEYS) {
        if (-not $IncludeMachineLabel -and $key -eq 'machineLabel') { continue }
        if ($Record.ContainsKey($key) -and $null -ne $Record[$key]) {
            $out[$key] = $Record[$key]
        }
    }
    foreach ($key in @('error')) {
        if ($out.ContainsKey($key) -and $out[$key] -is [string]) {
            $out[$key] = Hide-SensitiveText $out[$key]
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# Config accessors (shape-agnostic: v2 nested schema and v1 flat schema both work)

function Get-AutoAnchorConfig {
    # v2: codex.autoAnchor = @{ enabled; prompt; maxPerDay; minimumGapMinutes; keepaliveIntervalMinutes; anchorOnApply }
    # v1: codex.autoAnchor = bool + codex.anchorPrompt / maxAnchorsPerDay / minimumAnchorGapMinutes /
    #                        anchorKeepaliveMinutes / anchorOnApply
    param([hashtable]$Config)
    if ($null -eq $Config -or $null -eq $Config.codex) {
        return @{ enabled = $false; prompt = ''; maxPerDay = 0; minimumGapMinutes = 0; keepaliveIntervalMinutes = 0; anchorOnApply = $false }
    }
    $aa = $Config.codex.autoAnchor
    if ($aa -is [hashtable]) {
        return @{
            enabled            = [bool]($aa.enabled -eq $true)
            prompt             = [string]$aa.prompt
            maxPerDay          = [int]$aa.maxPerDay
            minimumGapMinutes  = [int]$aa.minimumGapMinutes
            keepaliveIntervalMinutes = [int]$aa.keepaliveIntervalMinutes
            anchorOnApply      = [bool]($aa.anchorOnApply -eq $true)
            schedule           = @(@($aa.schedule) | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ } | Select-Object -Unique)
        }
    }
    return @{
        enabled            = [bool]($Config.codex.autoAnchor -eq $true)
        prompt             = [string]$Config.codex.anchorPrompt
        maxPerDay          = [int]$Config.codex.maxAnchorsPerDay
        minimumGapMinutes  = [int]$Config.codex.minimumAnchorGapMinutes
        keepaliveIntervalMinutes = [int]$Config.codex.anchorKeepaliveMinutes
        anchorOnApply      = [bool]($Config.codex.anchorOnApply -eq $true)
        schedule           = @()
    }
}

function Test-AutoAnchorEnabled {
    param([hashtable]$Config)
    return (Get-AutoAnchorConfig $Config).enabled
}

function Get-ProxyConfig {
    # codex.proxy = '' (off) or an http/https/socks5 proxy URL handed to the codex
    # child process as HTTP_PROXY/HTTPS_PROXY/ALL_PROXY (CQK-020 proxy support).
    # Whether the codex binary honors a socks5 scheme is up to its own HTTP stack;
    # a failed proxy attempt still falls back to one direct retry.
    param([hashtable]$Config)
    if ($null -eq $Config -or $null -eq $Config.codex) { return @{ enabled = $false; url = '' } }
    $url = [string]$Config.codex.proxy
    if ([string]::IsNullOrWhiteSpace($url)) { return @{ enabled = $false; url = '' } }
    return @{ enabled = $true; url = $url }
}

function Get-CodexProxyEnvironment {
    # Env vars the codex child inherits when a proxy is configured. Windows
    # environment variables are case-insensitive (one process env entry), so the
    # upper-case forms are the canonical keys and cover case-variant readers.
    param([hashtable]$Config)
    $p = Get-ProxyConfig $Config
    if (-not $p.enabled) { return @{} }
    return @{
        'HTTP_PROXY'  = $p.url
        'HTTPS_PROXY' = $p.url
        'ALL_PROXY'   = $p.url
    }
}

function Get-CoordinationConfig {
    # v2: github.coordination = @{ enabled; repoPath; branch }
    # v1: github = @{ enabled; repoPath; coordinationBranch }
    param([hashtable]$Config)
    $g = $Config.github
    if ($g -is [hashtable] -and $g.ContainsKey('coordination') -and $g.coordination -is [hashtable]) {
        return @{
            enabled  = [bool]($g.coordination.enabled -eq $true)
            repoPath = [string]$g.coordination.repoPath
            branch   = [string]$g.coordination.branch
        }
    }
    return @{
        enabled  = [bool]($g.enabled -eq $true)
        repoPath = [string]$g.repoPath
        branch   = [string]$g.coordinationBranch
    }
}

function Test-CoordinationEnabled {
    param([hashtable]$Config)
    return (Get-CoordinationConfig $Config).enabled
}

function Get-HistorySyncConfig {
    # v2: github.historySync = @{ enabled; push; branch; eventsOnly }
    # v1: github = @{ enabled; push; historyBranch; syncEventsOnly }
    param([hashtable]$Config)
    $g = $Config.github
    if ($g -is [hashtable] -and $g.ContainsKey('historySync') -and $g.historySync -is [hashtable]) {
        $h = $g.historySync
        return @{
            enabled    = [bool]($h.enabled -eq $true)
            push       = [bool]($h.push -ne $false)
            branch     = [string]$h.branch
            eventsOnly = [bool]($h.eventsOnly -ne $false)
        }
    }
    return @{
        enabled    = [bool]($g.enabled -eq $true)
        push       = [bool]($g.push -ne $false)
        branch     = [string]$g.historyBranch
        eventsOnly = [bool]($g.syncEventsOnly -ne $false)
    }
}

function Get-PollConfig {
    # v2: poll = @{ intervalMinutes; minimumIntervalMinutes }; v1: flat keys.
    param([hashtable]$Config)
    $p = $Config.poll
    if ($p -is [hashtable]) {
        return @{
            intervalMinutes        = [int]$p.intervalMinutes
            minimumIntervalMinutes = [int]$p.minimumIntervalMinutes
        }
    }
    return @{
        intervalMinutes        = [int]$Config.pollIntervalMinutes
        minimumIntervalMinutes = [int]$Config.minimumPollIntervalMinutes
    }
}

function Get-LoggingConfig {
    # v2/v1 identical shape today; accessor keeps call sites future-proof.
    param([hashtable]$Config)
    $l = $Config.logging
    if ($l -is [hashtable]) {
        return @{
            retentionDays       = [int]$l.retentionDays
            includeMachineLabel = [bool]($l.includeMachineLabel -eq $true)
        }
    }
    return @{ retentionDays = 90; includeMachineLabel = $false }
}

# ---------------------------------------------------------------------------
# Config

function Get-DefaultConfig {
    # v2 config schema (audit plan v1.0 §6.1)
    return @{
        schemaVersion = 2
        mode = 'MonitorOnly'
        poll = @{
            intervalMinutes = 60
            minimumIntervalMinutes = $script:CQK_MIN_POLL_FLOOR_MINUTES
        }
        leader = @{
            enabled = $true
            leaseTtlMinutes = 45
            graceMinutes = 5
            takeoverOnExpiry = $true
            label = 'Home PC'
        }
        github = @{
            coordination = @{
                enabled = $false
                repoPath = ''
                branch = 'cqk/coordination'
            }
            historySync = @{
                enabled = $false
                push = $true
                branch = 'cqk/history'
                eventsOnly = $true
            }
        }
        logging = @{
            retentionDays = 90
            includeMachineLabel = $false   # privacy default: labels stay local unless opted in
        }
        codex = @{
            command = 'auto'
            queryTimeoutSeconds = 20
            autoAnchor = @{
                enabled = $false
                prompt = 'Reply exactly OK.'
                maxPerDay = 6
                minimumGapMinutes = 300           # 5h quiet: 一次调用后 5 小时窗口内不再触发（force 除外）
                keepaliveIntervalMinutes = 300    # 0 = off; >0 = idle backstop: 距上次锚定超过该值仍未观测到滚动则自触发（默认 = 一个 5 小时窗口）
                anchorOnApply = $false   # true = install.cmd/apply-config.cmd fire one forced anchor right away
                schedule = @()           # 每日定时触发（"HH:mm" 本地时间数组）：到点后第一次轮询触发一次；空 = 关闭
            }
        }
        task = @{
            name = 'CodexQuotaKeeper.Check'
            startWithWindows = $true
            runIfNetworkAvailable = $true
            wakeToRun = $false
        }
    }
}

function Convert-LegacyConfig {
    # Maps v1 flat keys onto the v2 schema so pre-0.9 config.json files keep
    # working. v2 keys always win when both are present.
    param([hashtable]$Config)
    if ($Config.poll -isnot [hashtable]) {
        $Config.poll = @{}
        if ($Config.ContainsKey('pollIntervalMinutes')) { $Config.poll.intervalMinutes = $Config.pollIntervalMinutes }
        if ($Config.ContainsKey('minimumPollIntervalMinutes')) { $Config.poll.minimumIntervalMinutes = $Config.minimumPollIntervalMinutes }
    }
    if ($Config.github -is [hashtable]) {
        $g = $Config.github
        if ($g.coordination -isnot [hashtable]) {
            $c = @{}
            if ($g.ContainsKey('enabled')) { $c.enabled = $g.enabled }
            if ($g.ContainsKey('repoPath')) { $c.repoPath = $g.repoPath }
            if ($g.ContainsKey('coordinationBranch')) { $c.branch = $g.coordinationBranch }
            $g.coordination = $c
        }
        if ($g.historySync -isnot [hashtable]) {
            $h = @{}
            if ($g.ContainsKey('enabled')) { $h.enabled = $g.enabled }
            if ($g.ContainsKey('push')) { $h.push = $g.push }
            if ($g.ContainsKey('historyBranch')) { $h.branch = $g.historyBranch }
            if ($g.ContainsKey('syncEventsOnly')) { $h.eventsOnly = $g.syncEventsOnly }
            $g.historySync = $h
        }
    }
    if ($Config.codex -is [hashtable] -and $Config.codex.autoAnchor -isnot [hashtable]) {
        $c = $Config.codex
        $aa = @{}
        if ($c.ContainsKey('autoAnchor')) { $aa.enabled = ($c.autoAnchor -eq $true) }
        if ($c.ContainsKey('anchorPrompt')) { $aa.prompt = $c.anchorPrompt }
        if ($c.ContainsKey('maxAnchorsPerDay')) { $aa.maxPerDay = $c.maxAnchorsPerDay }
        if ($c.ContainsKey('minimumAnchorGapMinutes')) { $aa.minimumGapMinutes = $c.minimumAnchorGapMinutes }
        if ($c.ContainsKey('anchorKeepaliveMinutes')) { $aa.keepaliveIntervalMinutes = $c.anchorKeepaliveMinutes }
        if ($c.ContainsKey('anchorOnApply')) { $aa.anchorOnApply = ($c.anchorOnApply -eq $true) }
        $Config.codex.autoAnchor = $aa
    }
    $Config.schemaVersion = 2
    return $Config
}

function Merge-ConfigDefaults {
    param([hashtable]$Defaults, [hashtable]$Override)
    $out = @{}
    foreach ($k in $Defaults.Keys) {
        $dv = $Defaults[$k]
        if ($dv -is [hashtable]) {
            $ov = if ($Override -and $Override.ContainsKey($k) -and $Override[$k] -is [hashtable]) { $Override[$k] } else { @{} }
            $out[$k] = Merge-ConfigDefaults $dv $ov
        } elseif ($Override -and $Override.ContainsKey($k) -and $null -ne $Override[$k]) {
            $out[$k] = $Override[$k]
        } else {
            $out[$k] = $dv
        }
    }
    # keep keys unknown to defaults so validation can flag or tolerate them
    if ($Override) {
        foreach ($k in $Override.Keys) {
            if (-not $out.ContainsKey($k)) { $out[$k] = $Override[$k] }
        }
    }
    return $out
}

function Test-ConfigShape {
    # Returns a list of issue strings; empty list means valid. v2 schema.
    param([hashtable]$Config)
    $issues = @()
    $mode = [string]$Config.mode
    if ($mode -notin @('MonitorOnly', 'AutoAnchor')) {
        $issues += "mode must be MonitorOnly or AutoAnchor (got '$mode')"
    }
    $poll = Get-PollConfig $Config
    if ($poll.minimumIntervalMinutes -lt $script:CQK_MIN_POLL_FLOOR_MINUTES) {
        $issues += "poll.minimumIntervalMinutes must be >= $($script:CQK_MIN_POLL_FLOOR_MINUTES)"
    }
    if ($poll.intervalMinutes -lt $poll.minimumIntervalMinutes) {
        $issues += "poll.intervalMinutes ($($poll.intervalMinutes)) must be >= poll.minimumIntervalMinutes ($($poll.minimumIntervalMinutes))"
    }
    if ([int]$Config.leader.leaseTtlMinutes -lt 5) {
        $issues += 'leader.leaseTtlMinutes must be >= 5'
    }
    if ([int]$Config.leader.graceMinutes -lt 0) {
        $issues += 'leader.graceMinutes must be >= 0'
    }
    if ([int]$Config.codex.queryTimeoutSeconds -lt 5) {
        $issues += 'codex.queryTimeoutSeconds must be >= 5'
    }
    $proxy = Get-ProxyConfig $Config
    if ($proxy.enabled) {
        $uri = $null
        if (-not [System.Uri]::TryCreate($proxy.url, [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https', 'socks5', 'socks5h')) {
            $issues += "codex.proxy must be an http(s)/socks5(s) URL (got '$($proxy.url)')"
        }
    }
    $aa = Get-AutoAnchorConfig $Config
    if ($aa.enabled -and $mode -ne 'AutoAnchor') {
        $issues += "codex.autoAnchor.enabled=true requires mode='AutoAnchor'"
    }
    if ($aa.enabled) {
        if ([string]::IsNullOrWhiteSpace([string]$aa.prompt)) {
            $issues += 'codex.autoAnchor.prompt must not be empty when enabled'
        }
        if ([int]$aa.maxPerDay -lt 1) {
            $issues += 'codex.autoAnchor.maxPerDay must be >= 1'
        }
        if ([int]$aa.minimumGapMinutes -lt 1) {
            $issues += 'codex.autoAnchor.minimumGapMinutes must be >= 1'
        }
        if ([int]$aa.keepaliveIntervalMinutes -lt 0) {
            $issues += 'codex.autoAnchor.keepaliveIntervalMinutes must be >= 0 (0 = off)'
        }
        if ([int]$aa.keepaliveIntervalMinutes -gt 0 -and [int]$aa.keepaliveIntervalMinutes -lt [int]$aa.minimumGapMinutes) {
            $issues += ("codex.autoAnchor.keepaliveIntervalMinutes ({0}) must be >= minimumGapMinutes ({1}) when enabled" -f [int]$aa.keepaliveIntervalMinutes, [int]$aa.minimumGapMinutes)
        }
        foreach ($slot in @($aa.schedule)) {
            if ([string]$slot -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
                $issues += ("codex.autoAnchor.schedule entries must be zero-padded 24h 'HH:mm'; got '$slot'")
            }
        }
        if (@($aa.schedule).Count -gt [int]$aa.maxPerDay) {
            $issues += ("codex.autoAnchor.schedule has {0} slot(s) but maxPerDay is {1}; the daily cap would block later slots" -f @($aa.schedule).Count, [int]$aa.maxPerDay)
        }
    }
    if ([int]$Config.logging.retentionDays -lt 1) {
        $issues += 'logging.retentionDays must be >= 1'
    }
    $coord = Get-CoordinationConfig $Config
    if ($coord.enabled -and [string]::IsNullOrWhiteSpace($coord.repoPath)) {
        $issues += 'github.coordination.repoPath is required when github.coordination.enabled=true'
    }
    return $issues
}

function Load-Config {
    # Returns @{ config = <hashtable with defaults merged>; issues = @(); path = ... }
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ config = $null; issues = @("config file not found: $Path (copy config.example.jsonc to config.json)"); path = $Path }
    }
    $raw = Read-JsonFile $Path
    if ($null -eq $raw) {
        return @{ config = $null; issues = @("config file is not valid JSON: $Path"); path = $Path }
    }
    if ($raw -isnot [hashtable]) {
        return @{ config = $null; issues = @('config root must be a JSON object'); path = $Path }
    }
    try {
        $raw = Convert-LegacyConfig $raw
        $merged = Merge-ConfigDefaults (Get-DefaultConfig) $raw
        $issues = Test-ConfigShape $merged
    } catch {
        return @{ config = $null; issues = @("config validation error: $($_.Exception.Message)"); path = $Path }
    }
    return @{ config = $merged; issues = $issues; path = $Path }
}

# ---------------------------------------------------------------------------
# Machine identity: stable random id, no MAC / serial number / username.

function Get-MachineIdentity {
    param([string]$Root, [string]$Label)
    $path = Get-MachinePath $Root
    $existing = Read-JsonFile $path
    $changed = $false
    if ($null -eq $existing -or [string]::IsNullOrWhiteSpace([string]$existing.machineId)) {
        $existing = @{
            machineId = [guid]::NewGuid().ToString()
            label = $Label
            createdAt = Get-IsoTimestamp
        }
        $changed = $true
    }
    if ($Label -and $existing.label -ne $Label) {
        $existing.label = $Label
        $changed = $true
    }
    if ($changed) { Write-JsonFileAtomic $path $existing }
    return $existing
}

# ---------------------------------------------------------------------------
# Backoff window (429 -> 60 min, auth error -> 120 min per doc)

function Get-BackoffState {
    param([string]$Root)
    $state = Read-JsonFile (Get-BackoffPath $Root)
    if ($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.until)) { return $null }
    $untilOffset = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$state.until, [ref]$untilOffset)) {
        return $null
    }
    if ($untilOffset -le [DateTimeOffset]::Now) { return $null }
    return @{ until = $untilOffset; reason = [string]$state.reason }
}

function Set-Backoff {
    param([string]$Root, [int]$Minutes, [string]$Reason)
    Write-JsonFileAtomic (Get-BackoffPath $Root) @{
        until = (Get-Date).AddMinutes($Minutes).ToString('yyyy-MM-ddTHH:mm:sszzz')
        reason = $Reason
        setAt = Get-IsoTimestamp
    }
}

function Clear-Backoff {
    param([string]$Root)
    $path = Get-BackoffPath $Root
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Test-InBackoff {
    param([string]$Root)
    return ($null -ne (Get-BackoffState $Root))
}

# ---------------------------------------------------------------------------
# Local mutual exclusion: named mutex + lock file (two layers per doc).

function Enter-RunnerLock {
    param([string]$Root)
    Ensure-Directory (Get-LockDir $Root) | Out-Null
    $lockPath = Join-Path (Get-LockDir $Root) 'runner.lock'
    $rootKey = (Get-Sha256Hex ("lock:" + (Get-KeeperRoot $Root).ToLowerInvariant())).Substring(0, 12)
    $mutexName = "Global\CodexQuotaKeeper.$rootKey"

    # Same-process re-entry: the mutex is recursive, so only the record can tell
    # us this caller already holds the lock. A record carrying our pid while we
    # never acquired is a stale record from a recycled pid; the mutex below is
    # authoritative in that case.
    if (Test-Path -LiteralPath $lockPath) {
        $existing = Read-JsonFile $lockPath
        if ($null -ne $existing -and $existing.pid -and "$($existing.pid)" -eq "$PID" -and $script:CqkRunnerLockAcquired) {
            return @{ acquired = $false; lockPath = $lockPath; owner = $existing; layer = 'reentry';
                      detail = "process pid=$PID already holds the lock (startedAt=$($existing.startedAt))" }
        }
    }

    # Layer 2 (authoritative): named mutex, released by the OS when the owning
    # process dies. A stale lock file whose pid was recycled to some unrelated
    # live process can never block acquisition while this mutex is free, which
    # makes the old file-order check safe against fast pid reuse on busy boxes.
    $mutex = $null
    $createdNew = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$createdNew)
    } catch {
        $mutex = $null
    }
    if ($mutex) {
        $got = $false
        try { $got = $mutex.WaitOne(0) } catch { $got = $false }
        if (-not $got) {
            $fileDiag = 'no lock file present'
            if (Test-Path -LiteralPath $lockPath) {
                $l = Read-JsonFile $lockPath
                if ($l) { $fileDiag = "lock file pid=$($l.pid) startedAt=$($l.startedAt)" }
            }
            $mutex.Dispose()
            return @{ acquired = $false; lockPath = $lockPath; owner = $null; layer = 'mutex';
                      detail = "named mutex held ($mutexName); $fileDiag" }
        }
    } elseif (Test-Path -LiteralPath $lockPath) {
        # Layer 1 fallback, used only when the mutex API is unavailable: break a
        # stale record from a dead pid; a live owner pid still blocks.
        $existing = Read-JsonFile $lockPath
        if ($null -ne $existing -and $existing.pid) {
            $dead = $true
            $ownerInfo = ''
            try {
                $proc = Get-Process -Id ([int]$existing.pid) -ErrorAction Stop
                if ($proc) { $dead = $false; $ownerInfo = "$($proc.ProcessName) (started $($proc.StartTime.ToString('HH:mm:ss')))" }
            } catch { $dead = $true }
            if (-not $dead) {
                return @{ acquired = $false; lockPath = $lockPath; owner = $existing; layer = 'file';
                          detail = "lock file pid=$($existing.pid) startedAt=$($existing.startedAt) owner=$ownerInfo" }
            }
        }
    }

    # The mutex (or its absence) says we may proceed: drop any stale record and
    # write our own.
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    Write-JsonFileAtomic $lockPath @{ pid = $PID; startedAt = Get-IsoTimestamp; mutex = $mutexName }
    $script:CqkRunnerMutex = $mutex
    $script:CqkRunnerLockAcquired = $true
    return @{ acquired = $true; lockPath = $lockPath; owner = $null }
}

function Exit-RunnerLock {
    param([string]$Root)
    if ($script:CqkRunnerMutex) {
        try { $script:CqkRunnerMutex.ReleaseMutex() } catch { }
        try { $script:CqkRunnerMutex.Dispose() } catch { }
        $script:CqkRunnerMutex = $null
    }
    # Remove only the record this process wrote; a runner that never acquired
    # the lock must not delete the lock file of the real holder (that also
    # destroyed the evidence of who held the lock).
    if (-not $script:CqkRunnerLockAcquired) { return }
    $script:CqkRunnerLockAcquired = $false
    $lockPath = Join-Path (Get-LockDir $Root) 'runner.lock'
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# External command execution: argument arrays only, no shell string interpolation.

function Invoke-External {
    # Returns @{ ok; exitCode; stdout; stderr; timedOut }
    param(
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$RawArguments = '',
        [int]$TimeoutSeconds = 30,
        [string]$WorkingDirectory = $null,
        [string]$StdinText = $null,
        [hashtable]$Environment = $null
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = ($null -ne $StdinText)
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($Environment) {
        foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$Environment[$k] }
    }
    # RawArguments (cmd/bat launches) wins: .NET ArgumentList escaping corrupts
    # cmd.exe quote semantics, so those launches set the command line verbatim.
    if ($RawArguments) {
        $psi.Arguments = $RawArguments
    }
    # ArgumentList exists on PS7 (.NET Core); PS 5.1 must fall back to a quoted command line.
    elseif ($psi.PSObject.Properties['ArgumentList']) {
        foreach ($a in $ArgumentList) { [void]$psi.ArgumentList.Add([string]$a) }
    } else {
        $psi.Arguments = ($ArgumentList | ForEach-Object { '"' + ("$_" -replace '"', '\"') + '"' }) -join ' '
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        if ($null -ne $StdinText) {
            $proc.StandardInput.Write($StdinText)
            $proc.StandardInput.Close()
        }
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
            return @{ ok = $false; exitCode = -1; stdout = ''; stderr = 'process timed out'; timedOut = $true }
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return @{ ok = ($proc.ExitCode -eq 0); exitCode = $proc.ExitCode; stdout = $stdout; stderr = $stderr; timedOut = $false }
    } finally {
        $proc.Dispose()
    }
}

function Resolve-ExecutableLaunchSpec {
    # Unified external command launcher (audit plan v1.0 §9 / CQK-004).
    # npm on Windows exposes codex as codex.cmd, which fails when handed straight
    # to ProcessStartInfo(UseShellExecute=$false). Every external command goes
    # through here:
    #   .exe        -> run directly
    #   .ps1        -> pwsh/powershell -NoProfile -ExecutionPolicy Bypass -File <script> ...
    #   .cmd / .bat -> %ComSpec% /d /s /c "<cmd> <args>"
    #   other       -> Get-Command resolve, then recurse on the extension
    param([string]$Executable, [string[]]$ArgumentList = @())
    if ([string]::IsNullOrWhiteSpace($Executable)) { return $null }

    if (-not (Test-Path -LiteralPath $Executable)) {
        # Absolute/rooted paths are trusted and dispatched by extension (errors
        # surface at exec time); bare command names resolve through PATH.
        if (-not [System.IO.Path]::IsPathRooted($Executable)) {
            $found = Get-Command $Executable -ErrorAction SilentlyContinue
            if ($found -and $found.Source) { return (Resolve-ExecutableLaunchSpec -Executable $found.Source -ArgumentList $ArgumentList) }
            return $null
        }
    }

    $ext = [System.IO.Path]::GetExtension($Executable).ToLowerInvariant()
    switch ($ext) {
        '.exe' {
            return @{ exe = $Executable; args = $ArgumentList }
        }
        '.ps1' {
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if (-not $pwsh) { $pwsh = Get-Command powershell -ErrorAction SilentlyContinue }
            if (-not $pwsh) { return $null }
            return @{ exe = $pwsh.Source; args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Executable) + $ArgumentList }
        }
        { $_ -in '.cmd', '.bat' } {
            $comspec = $env:ComSpec
            if (-not $comspec) { $comspec = "$env:SystemRoot\System32\cmd.exe" }
            # cmd.exe quote rules + .NET argument escaping do not compose through
            # ArgumentList, so the launcher emits a raw command line instead:
            #   cmd /d /s /c ""E:\path\x.cmd" "arg1" "arg2""
            # With /s, cmd strips the first and last quote of the string after /c,
            # leaving a correctly quoted command. Empirically verified: one leading
            # quote (or three) breaks the launch.
            $raw = '/d /s /c ""' + $Executable + '"'
            foreach ($a in $ArgumentList) { $raw += ' "' + ("$a" -replace '"', '') + '"' }
            $raw += '""'
            return @{ exe = $comspec; args = @(); rawArgs = $raw }
        }
        default {
            $found = Get-Command $Executable -ErrorAction SilentlyContinue
            if ($found -and $found.Source -and $found.Source -ne $Executable) {
                return (Resolve-ExecutableLaunchSpec -Executable $found.Source -ArgumentList $ArgumentList)
            }
            return @{ exe = $Executable; args = $ArgumentList }
        }
    }
}

function Resolve-CodexCommand {
    # codex.command = 'auto' or an explicit path; returns exe path or $null.
    param([hashtable]$Config)
    $cmd = [string]$Config.codex.command
    if ($cmd -and $cmd -ne 'auto') {
        if (Test-Path -LiteralPath $cmd) { return $cmd }
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) { return $found.Source }
        return $null
    }
    $found = Get-Command 'codex' -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    $local = Join-Path $env:APPDATA 'npm\codex.cmd'
    if (Test-Path -LiteralPath $local) { return $local }
    return $null
}
