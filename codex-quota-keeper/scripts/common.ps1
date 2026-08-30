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
    param([hashtable]$Record)
    $out = @{}
    foreach ($key in $script:CQK_HISTORY_ALLOWED_KEYS) {
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
# Config

function Get-DefaultConfig {
    return @{
        schemaVersion = 1
        mode = 'MonitorOnly'
        pollIntervalMinutes = 15
        minimumPollIntervalMinutes = $script:CQK_MIN_POLL_FLOOR_MINUTES
        leader = @{
            enabled = $true
            leaseTtlMinutes = 45
            graceMinutes = 5
            takeoverOnExpiry = $true
            label = 'Home PC'
        }
        codex = @{
            command = 'auto'
            queryTimeoutSeconds = 20
            autoAnchor = $false
            anchorPrompt = 'Reply exactly OK.'
            maxAnchorsPerDay = 6
            minimumAnchorGapMinutes = 60
        }
        github = @{
            enabled = $true
            repoPath = ''
            coordinationBranch = 'coordination'
            historyBranch = 'history'
            syncEventsOnly = $true
            push = $true
        }
        logging = @{
            retentionDays = 90
            includeMachineLabel = $true
        }
        task = @{
            name = 'CodexQuotaKeeper.Check'
            startWithWindows = $true
            runIfNetworkAvailable = $true
            wakeToRun = $false
        }
    }
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
    # Returns a list of issue strings; empty list means valid.
    param([hashtable]$Config)
    $issues = @()
    $mode = [string]$Config.mode
    if ($mode -notin @('MonitorOnly', 'AutoAnchor')) {
        $issues += "mode must be MonitorOnly or AutoAnchor (got '$mode')"
    }
    $minPoll = [int]$Config.minimumPollIntervalMinutes
    if ($minPoll -lt $script:CQK_MIN_POLL_FLOOR_MINUTES) {
        $issues += "minimumPollIntervalMinutes must be >= $($script:CQK_MIN_POLL_FLOOR_MINUTES)"
    }
    $poll = [int]$Config.pollIntervalMinutes
    if ($poll -lt $minPoll) {
        $issues += "pollIntervalMinutes ($poll) must be >= minimumPollIntervalMinutes ($minPoll)"
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
    if ($Config.codex.autoAnchor -eq $true -and $mode -ne 'AutoAnchor') {
        $issues += "codex.autoAnchor=true requires mode='AutoAnchor'"
    }
    if ($Config.codex.autoAnchor -eq $true) {
        if ([string]::IsNullOrWhiteSpace([string]$Config.codex.anchorPrompt)) {
            $issues += 'codex.anchorPrompt must not be empty when autoAnchor is on'
        }
        if ([int]$Config.codex.maxAnchorsPerDay -lt 1) {
            $issues += 'codex.maxAnchorsPerDay must be >= 1'
        }
        if ([int]$Config.codex.minimumAnchorGapMinutes -lt 1) {
            $issues += 'codex.minimumAnchorGapMinutes must be >= 1'
        }
    }
    if ([int]$Config.logging.retentionDays -lt 1) {
        $issues += 'logging.retentionDays must be >= 1'
    }
    if ($Config.github.enabled -eq $true) {
        $repo = [string]$Config.github.repoPath
        if ([string]::IsNullOrWhiteSpace($repo)) {
            $issues += 'github.repoPath is required when github.enabled=true'
        }
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
        [int]$TimeoutSeconds = 30,
        [string]$WorkingDirectory = $null,
        [string]$StdinText = $null
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
    # ArgumentList exists on PS7 (.NET Core); PS 5.1 must fall back to a quoted command line.
    if ($psi.PSObject.Properties['ArgumentList']) {
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
