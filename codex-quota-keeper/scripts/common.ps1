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
$script:CQK_VERSION = '0.1.0'

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
        return ConvertTo-HashtableDeep (ConvertFrom-Json $Text)
    } catch {
        return $null
    }
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
    # v2: codex.autoAnchor = @{ enabled; prompt; maxPerDay; minimumGapMinutes }
    # v1: codex.autoAnchor = bool + codex.anchorPrompt / maxAnchorsPerDay / minimumAnchorGapMinutes
    param([hashtable]$Config)
    if ($null -eq $Config -or $null -eq $Config.codex) {
        return @{ enabled = $false; prompt = ''; maxPerDay = 0; minimumGapMinutes = 0 }
    }
    $aa = $Config.codex.autoAnchor
    if ($aa -is [hashtable]) {
        return @{
            enabled            = [bool]($aa.enabled -eq $true)
            prompt             = [string]$aa.prompt
            maxPerDay          = [int]$aa.maxPerDay
            minimumGapMinutes  = [int]$aa.minimumGapMinutes
        }
    }
    return @{
        enabled            = [bool]($Config.codex.autoAnchor -eq $true)
        prompt             = [string]$Config.codex.anchorPrompt
        maxPerDay          = [int]$Config.codex.maxAnchorsPerDay
        minimumGapMinutes  = [int]$Config.codex.minimumAnchorGapMinutes
    }
}

function Test-AutoAnchorEnabled {
    param([hashtable]$Config)
    return (Get-AutoAnchorConfig $Config).enabled
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
            intervalMinutes = 15
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
                enabled = $true
                repoPath = ''
                branch = 'cqk/coordination'
            }
            historySync = @{
                enabled = $true
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
                minimumGapMinutes = 60
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
        return @{ config = $null; issues = @("config file not found: $Path (copy config.example.json to config.json)"); path = $Path }
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
    $rootKey = Get-Sha256Hex ("lock:" + (Get-KeeperRoot $Root).ToLowerInvariant()).Substring(0, 12)
    $mutexName = "Global\CodexQuotaKeeper.$rootKey"

    # Layer 1: lock file with PID; stale locks from dead processes are breakable.
    if (Test-Path -LiteralPath $lockPath) {
        $existing = Read-JsonFile $lockPath
        if ($null -ne $existing -and $existing.pid) {
            $dead = $true
            try {
                $proc = Get-Process -Id ([int]$existing.pid) -ErrorAction Stop
                if ($proc) { $dead = $false }
            } catch { $dead = $true }
            if (-not $dead) { return @{ acquired = $false; lockPath = $lockPath; owner = $existing } }
        }
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }

    # Layer 2: named mutex; released by OS when the process dies.
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
            $mutex.Dispose()
            return @{ acquired = $false; lockPath = $lockPath; owner = $null }
        }
    }

    Write-JsonFileAtomic $lockPath @{ pid = $PID; startedAt = Get-IsoTimestamp; mutex = $mutexName }
    $script:CqkRunnerMutex = $mutex
    return @{ acquired = $true; lockPath = $lockPath; owner = $null }
}

function Exit-RunnerLock {
    param([string]$Root)
    if ($script:CqkRunnerMutex) {
        try { $script:CqkRunnerMutex.ReleaseMutex() } catch { }
        try { $script:CqkRunnerMutex.Dispose() } catch { }
        $script:CqkRunnerMutex = $null
    }
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
            #   cmd /d /s /c ""C:\path\x.cmd" "arg1" "arg2""
            # /s strips the outer quotes, leaving a correctly quoted command.
            $inner = '"' + $Executable + '"'
            foreach ($a in $ArgumentList) { $inner += ' "' + ("$a" -replace '"', '') + '"' }
            $raw = '/d /s /c ""' + $inner + '""'
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
