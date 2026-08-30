# Codex Quota Keeper - apply config changes (doc 02 §6).
# Validates config.json and updates the Scheduled Task repetition interval.
# Values below the 5-minute floor are rejected by config validation.

param(
    [string]$KeeperRoot = '',
    [string]$ConfigFile = ''
)

$script:CqkApplyConfigDir = Split-Path -Parent $PSCommandPath
# Capture before dot-sourcing install.ps1 (its param block would re-bind these).
$AcKeeperRoot = $KeeperRoot
$AcConfigFile = $ConfigFile
if (-not (Get-Command Get-KeeperRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkApplyConfigDir 'common.ps1')
}
if (-not (Get-Command Register-KeeperTask -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:CqkApplyConfigDir 'install.ps1')
}

function Invoke-ApplyConfig {
    # Returns @{ ok; issues; taskName; intervalMinutes; taskCreated }
    param([string]$KeeperRoot = '', [string]$ConfigFile = '')
    if (-not $KeeperRoot) { $KeeperRoot = Get-KeeperRoot }
    if (-not $ConfigFile) { $ConfigFile = Get-ConfigPath $KeeperRoot }

    $loaded = Load-Config $ConfigFile
    if ($null -eq $loaded.config -or @($loaded.issues).Count -gt 0) {
        return @{ ok = $false; issues = $loaded.issues; taskName = $null; intervalMinutes = $null; taskCreated = $false }
    }
    $cfg = $loaded.config
    $taskName = [string]$cfg.task.name

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        # Re-register with the new trigger/settings (keeps it simple and consistent).
        Register-KeeperTask -Config $cfg -KeeperRoot $KeeperRoot | Out-Null
        return @{ ok = $true; issues = @(); taskName = $taskName; intervalMinutes = [int]$cfg.pollIntervalMinutes; taskCreated = $false }
    }
    Register-KeeperTask -Config $cfg -KeeperRoot $KeeperRoot | Out-Null
    return @{ ok = $true; issues = @(); taskName = $taskName; intervalMinutes = [int]$cfg.pollIntervalMinutes; taskCreated = $true }
}

if ($MyInvocation.InvocationName -ne '.') {
    $r = Invoke-ApplyConfig -KeeperRoot $AcKeeperRoot -ConfigFile $AcConfigFile
    Write-Host 'Codex Quota Keeper - Apply Config'
    Write-Host '========================================'
    foreach ($i in $r.issues) { Write-Host "  [ISSUE] $i" -ForegroundColor Yellow }
    if ($r.ok) {
        $verb = if ($r.taskCreated) { 'CREATED' } else { 'UPDATED' }
        Write-Host "  Task '$($r.taskName)': $verb, polling every $($r.intervalMinutes) min"
    } else {
        Write-Host '  Config NOT applied (fix the issues above).' -ForegroundColor Red
    }
    exit $(if ($r.ok) { 0 } else { 1 })
}
