# Tests for logger.ps1: JSONL schema, sanitization of history records, daily summary
# aggregation, retention cleanup, recent-error lookup.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'common.ps1')
. (Join-Path $scriptDir 'logger.ps1')

$when = [DateTime]::Parse('2026-08-30 10:45:06')

Start-TestGroup 'log: runtime JSONL follows doc schema'

$ws = New-TestWorkspace
try {
    Write-KeeperLog -Root $ws -Event 'QUOTA_SNAPSHOT_CHANGED' -MachineId 'M-1' -Role 'LEADER' -Mode 'MonitorOnly' `
        -Windows @(@{ minutes = 300; usedPercent = 18; resetsAt = 1788087660 }) -When $when

    $file = Join-Path (Get-LogsDir $ws) 'keeper-2026-08-30.jsonl'
    Assert-True (Test-Path $file) 'log file named keeper-YYYY-MM-DD.jsonl'
    $rawLine = [System.IO.File]::ReadAllLines($file)[0]
    $entry = ConvertFrom-JsonSafe $rawLine
    # null-valued schema fields must still be PRESENT (key existence, not value)
    foreach ($field in @('ts', 'level', 'event', 'machineId', 'role', 'mode', 'windows', 'anchor', 'error')) {
        Assert-True ($entry.ContainsKey($field)) "field '$field' present in schema"
    }
    Assert-Equal 'QUOTA_SNAPSHOT_CHANGED' $entry.event 'event name'
    Assert-Equal 'LEADER' $entry.role 'role'
    # ConvertFrom-Json parses ISO strings into DateTime, so assert the raw line.
    Assert-True ($rawLine -match '"ts":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}') 'ts iso format with offset'

    Start-TestGroup 'log: error text sanitized before writing'

    Write-KeeperLog -Root $ws -Event 'AUTH_ERROR' -Level 'ERROR' -Error 'token=supersecret123 relogin' -When $when
    $lines = [System.IO.File]::ReadAllLines($file)
    $errEntry = ConvertFrom-JsonSafe $lines[1]
    Assert-Equal 'ERROR' $errEntry.level 'error level recorded'
    Assert-False ("$($errEntry.error)" -match 'supersecret123') 'secret scrubbed from error text'

    Start-TestGroup 'history: only allowlisted sanitized fields'

    $null = Write-HistoryEvent -Root $ws -Record @{
        event = 'WINDOW_RESET_OBSERVED'; machineId = 'M-1'; machineLabel = 'Home PC'; role = 'LEADER'
        mode = 'MonitorOnly'; windows = @(@{ minutes = 300; usedPercent = 3; resetsAt = 1788087660 })
        anchor = $null; error = 'token=leaky-123'
        promptText = 'MUST NOT APPEAR'; sessionId = 'MUST NOT APPEAR'
    } -When $when

    $hfile = Join-Path (Get-HistoryDir $ws) 'events-2026-08-30.jsonl'
    Assert-True (Test-Path $hfile) 'history file created'
    $h = ConvertFrom-JsonSafe ([System.IO.File]::ReadAllLines($hfile)[0])
    Assert-Null $h.promptText 'prompt text never reaches history'
    Assert-Null $h.sessionId 'session data never reaches history'
    Assert-Equal 'Home PC' $h.machineLabel 'label kept (user-provided, non-sensitive)'
    Assert-False ("$($h.error)" -match 'leaky-123') 'history error sanitized'
    Assert-Equal 3 $h.windows[0].usedPercent 'quota data (non-sensitive) preserved'

    Start-TestGroup 'summary: rolling aggregation per day'

    $null = Update-DailySummary -Root $ws -Date '2026-08-30' -EventCounts @{ WINDOW_RESET_OBSERVED = 1 } -MachineId 'M-1'
    $null = Update-DailySummary -Root $ws -Date '2026-08-30' -EventCounts @{ WINDOW_RESET_OBSERVED = 1; QUOTA_SNAPSHOT_CHANGED = 5 } -AnchorCount 1 -Windows @(@{ minutes = 300 })
    $summary = Read-JsonFile (Join-Path (Get-HistoryDir $ws) 'summary-2026-08-30.json')
    Assert-Equal 2 $summary.counts.WINDOW_RESET_OBSERVED 'counts accumulate across calls'
    Assert-Equal 5 $summary.counts.QUOTA_SNAPSHOT_CHANGED 'other events counted'
    Assert-Equal 1 $summary.anchors 'anchor count aggregated'
    Assert-Equal 300 $summary.windows[0].minutes 'last snapshot stored'
    Assert-Equal 'daily-summary' $summary.type 'summary type'

    Start-TestGroup 'retention: old log/history files removed, new kept'

    $old = (Get-Date).AddDays(-120)
    $oldLog = Join-Path (Get-LogsDir $ws) 'keeper-2026-04-01.jsonl'
    [System.IO.File]::WriteAllText($oldLog, '{}')
    (Get-Item $oldLog).LastWriteTime = $old
    $oldHist = Join-Path (Get-HistoryDir $ws) 'events-2026-04-01.jsonl'
    [System.IO.File]::WriteAllText($oldHist, '{}')
    (Get-Item $oldHist).LastWriteTime = $old

    $removed = Invoke-LogRetention -Root $ws -RetentionDays 90
    Assert-True ($removed -ge 2) "two stale files removed (got $removed)"
    Assert-False (Test-Path $oldLog) 'stale runtime log deleted'
    Assert-False (Test-Path $oldHist) 'stale history file deleted'
    Assert-True (Test-Path (Join-Path (Get-LogsDir $ws) 'keeper-2026-08-30.jsonl')) 'recent log kept'

    Start-TestGroup 'recent errors: newest first, level=ERROR only'

    $logFile = Join-Path (Get-LogsDir $ws) 'keeper-2026-08-30.jsonl'
    Write-KeeperLog -Root $ws -Event 'READ_FAILED' -Level 'INFO' -When ([DateTime]::Parse('2026-08-30 11:00:00'))
    Write-KeeperLog -Root $ws -Event 'TIMEOUT' -Level 'ERROR' -Error 'app-server timeout' -When ([DateTime]::Parse('2026-08-30 11:05:00'))
    Write-KeeperLog -Root $ws -Event 'AUTH_ERROR' -Level 'ERROR' -Error 'relogin' -When ([DateTime]::Parse('2026-08-30 11:10:00'))

    $recent = Get-RecentErrors -Root $ws -Take 2
    Assert-Equal 2 @($recent).Count 'two most recent errors'
    Assert-Equal 'AUTH_ERROR' $recent[0].event 'newest error first'
    Assert-Equal 'TIMEOUT' $recent[1].event 'second newest after'
} finally {
    Remove-TestWorkspace $ws
}

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "logger.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
