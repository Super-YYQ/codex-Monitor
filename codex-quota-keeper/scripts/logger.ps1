# Codex Quota Keeper - logging.
# runtime/logs/*.jsonl  : full local log (doc 03 §11 schema), retention-managed.
# history/events-*.jsonl: sanitized event records, the only thing github-sync pushes.
# history/summary-*.json: per-day rolling summary.

$script:CqkLoggerDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkLoggerDir 'common.ps1')
}

function Get-LogFilePath {
    param([string]$Root, [DateTime]$When)
    return Join-Path (Get-LogsDir $Root) ("keeper-" + $When.ToString('yyyy-MM-dd') + ".jsonl")
}

function Write-KeeperLog {
    # EventRecord schema (audit plan §12): ts/level/event/machineId/machineLabel?/role/mode/
    # runId/windows/anchor/errorKind?/error/version. machineLabel is only written when
    # logging.includeMachineLabel=true (privacy default off).
    param(
        [string]$Root,
        [string]$Event,
        [string]$MachineId = '',
        [string]$MachineLabel = '',
        [string]$Role = '',
        [string]$Mode = '',
        [string]$RunId = '',
        $Windows = $null,
        $Anchor = $null,
        $Error = $null,
        [string]$ErrorKind = $null,
        [string]$Level = 'INFO',
        [hashtable]$LoggingConfig = $null,
        [DateTime]$When = (Get-Date)
    )
    $includeLabel = $false
    if ($LoggingConfig) { $includeLabel = [bool]$LoggingConfig.includeMachineLabel }
    $entry = @{
        ts         = $When.ToString('yyyy-MM-ddTHH:mm:sszzz')
        level      = $Level
        event      = $Event
        machineId  = $MachineId
        role       = $Role
        mode       = $Mode
        runId      = $RunId
        windows    = $Windows
        anchor     = $Anchor
        error      = $Error
        version    = $script:CQK_VERSION
    }
    if ($ErrorKind) { $entry.errorKind = $ErrorKind }
    if ($includeLabel -and $MachineLabel) { $entry.machineLabel = $MachineLabel }
    if ($entry.error -is [string]) { $entry.error = Hide-SensitiveText $entry.error }
    Write-JsonLine (Get-LogFilePath $Root $When) $entry
}

function Write-HistoryEvent {
    # Sanitized, allowlist-only record for the optional Git-synced history.
    # Records with no meaningful payload (plain polls) are rejected by callers:
    # doc 03 §12 - never sync every unchanged poll.
    # machineLabel is dropped unless -IncludeMachineLabel is passed (privacy).
    param(
        [string]$Root,
        [hashtable]$Record,
        [switch]$IncludeMachineLabel,
        [DateTime]$When = (Get-Date)
    )
    $record.ts = $When.ToString('yyyy-MM-ddTHH:mm:sszzz')
    $clean = Sanitize-Record $Record -IncludeMachineLabel:$IncludeMachineLabel
    $path = Join-Path (Get-HistoryDir $Root) ("events-" + $When.ToString('yyyy-MM-dd') + ".jsonl")
    Write-JsonLine $path $clean
    return $path
}

function Update-DailySummary {
    # Rolling per-day aggregate in history/; rewritten (not appended) on each call.
    param(
        [string]$Root,
        [string]$Date,
        [hashtable]$EventCounts,
        $Windows = $null,
        [int]$AnchorCount = 0,
        [int]$ErrorCount = 0,
        [string]$MachineId = ''
    )
    $path = Join-Path (Get-HistoryDir $Root) ("summary-" + $Date + ".json")
    $existing = Read-JsonFile $path
    if ($existing -isnot [hashtable]) {
        $existing = @{ type = 'daily-summary'; date = $Date; machineId = $MachineId; counts = @{} }
    }
    if ($existing.counts -isnot [hashtable]) { $existing.counts = @{} }
    foreach ($k in $EventCounts.Keys) {
        $prev = 0
        if ($existing.counts[$k] -is [int] -or $existing.counts[$k] -is [long]) { $prev = [int]$existing.counts[$k] }
        $existing.counts[$k] = $prev + [int]$EventCounts[$k]
    }
    if ($Windows) { $existing.windows = $Windows }
    if ($AnchorCount -gt 0) {
        if (-not $existing.anchors) { $existing.anchors = 0 }
        $existing.anchors = [int]$existing.anchors + $AnchorCount
    }
    if ($ErrorCount -gt 0) {
        if (-not $existing.errors) { $existing.errors = 0 }
        $existing.errors = [int]$existing.errors + $ErrorCount
    }
    $existing.updatedAt = Get-IsoTimestamp
    Write-JsonFileAtomic $path $existing
    return $path
}

function Invoke-LogRetention {
    # Deletes local log/history files older than retentionDays. Git history in the
    # remote repo is intentionally untouched.
    param([string]$Root, [int]$RetentionDays)
    $cutoff = (Get-Date).AddDays(-1 * $RetentionDays)
    $removed = 0
    foreach ($dir in @((Get-LogsDir $Root), (Get-HistoryDir $Root))) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.LastWriteTime -lt $cutoff) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                $removed++
            }
        }
    }
    return $removed
}

function Get-RecentErrors {
    # Latest ERROR-level entries across recent log files (used by status.ps1).
    param([string]$Root, [int]$MaxAgeDays = 2, [int]$Take = 1)
    $errors = @()
    if (-not (Test-Path -LiteralPath (Get-LogsDir $Root))) { return $errors }
    $cutoff = (Get-Date).AddDays(-1 * $MaxAgeDays)
    $files = Get-ChildItem -LiteralPath (Get-LogsDir $Root) -Filter 'keeper-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($file in $files) {
        if ($file.LastWriteTime -lt $cutoff) { break }
        $lines = [System.IO.File]::ReadAllLines($file.FullName)
        [array]::Reverse($lines)
        foreach ($line in $lines) {
            $entry = ConvertFrom-JsonSafe $line
            if ($null -eq $entry) { continue }
            if ([string]$entry.level -eq 'ERROR') { $errors += $entry }
            if ($errors.Count -ge $Take) { return $errors }
        }
    }
    return $errors
}
