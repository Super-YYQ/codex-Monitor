# Codex Quota Keeper - uninstaller.
# Removes the Scheduled Task. Local history is kept unless -DeleteHistory is given
# (doc 04 §9: whether local history survives is the user's choice).

param(
    [string]$KeeperRoot = '',
    [string]$ConfigFile = '',
    [switch]$DeleteHistory
)

$script:CqkUninstallDir = Split-Path -Parent $PSCommandPath
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkUninstallDir 'common.ps1')
}

function Invoke-KeeperUninstall {
    param([string]$KeeperRoot = '', [string]$ConfigFile = '', [switch]$DeleteHistory)
    if (-not $KeeperRoot) { $KeeperRoot = Get-KeeperRoot }
    if (-not $ConfigFile) { $ConfigFile = Get-ConfigPath $KeeperRoot }

    $taskName = $null
    $loaded = Load-Config $ConfigFile
    if ($loaded.config) { $taskName = [string]$loaded.config.task.name }

    $removedTask = $false
    if ($taskName) {
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            $removedTask = $true
        }
    }

    Clear-Backoff $KeeperRoot
    Exit-RunnerLock $KeeperRoot

    $historyRemoved = $false
    if ($DeleteHistory) {
        foreach ($dir in @((Get-HistoryDir $KeeperRoot), (Get-RuntimeDir $KeeperRoot))) {
            if (Test-Path -LiteralPath $dir) {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $historyRemoved = $true
    }

    return @{ taskName = $taskName; removedTask = $removedTask; historyRemoved = $historyRemoved }
}

if ($MyInvocation.InvocationName -ne '.') {
    $r = Invoke-KeeperUninstall -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile -DeleteHistory:$DeleteHistory
    Write-Host 'Codex Quota Keeper - Uninstall'
    Write-Host '========================================'
    if ($r.removedTask) {
        Write-Host "  Scheduled task   : REMOVED ('$($r.taskName)')"
    } else {
        Write-Host "  Scheduled task   : not found (nothing to remove)"
    }
    if ($r.historyRemoved) {
        Write-Host '  Local history    : DELETED (-DeleteHistory)'
    } else {
        Write-Host '  Local history    : KEPT (use -DeleteHistory to remove)'
    }
    exit 0
}
