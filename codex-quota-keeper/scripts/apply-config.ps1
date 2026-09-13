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
    # Returns @{ ok; issues; warnings; taskName; intervalMinutes; taskCreated; forcedAnchor }
    param([string]$KeeperRoot = '', [string]$ConfigFile = '')
    if (-not $KeeperRoot) { $KeeperRoot = Get-KeeperRoot }
    if (-not $ConfigFile) { $ConfigFile = Get-ConfigPath $KeeperRoot }

    $loaded = Load-Config $ConfigFile
    if ($null -eq $loaded.config -or @($loaded.issues).Count -gt 0) {
        return @{ ok = $false; issues = $loaded.issues; warnings = @(); profile = $null; taskName = $null; intervalMinutes = $null; taskCreated = $false; forcedAnchor = $null }
    }
    $cfg = $loaded.config
    $taskName = [string]$cfg.task.name

    # Execution profile gate (doc v3.0 §7) BEFORE any task write. Apply never runs
    # preflight, so it resolves the Codex path the same way preflight does - the
    # same binary `codex exec` will use - and returns the issue instead of calling
    # Register-KeeperTask. Registering is a read-modify-write of the live task, so
    # "fail and roll back" is not an option here; the only safe ordering is gate
    # first, which is what keeps the doc's promise that a failed apply leaves the
    # existing scheduled task untouched.
    $codexPath = Resolve-CodexCommand $cfg
    $gate = Get-ExecutionProfileGate -Config $cfg -CodexPath $codexPath -KeeperRoot $KeeperRoot -Stage 'Apply'
    if (@($gate.issues).Count -gt 0) {
        return @{ ok = $false; issues = @($gate.issues); warnings = @($gate.warnings); profile = $gate; taskName = $taskName; intervalMinutes = (Get-PollConfig $cfg).intervalMinutes; taskCreated = $false; forcedAnchor = $null }
    }

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        # Re-register with the new trigger/settings (keeps it simple and consistent).
        # CQK-022: thread the resolved ConfigFile so the scheduled runner keeps
        # using this exact config (a custom path would otherwise be lost here).
        Register-KeeperTask -Config $cfg -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile | Out-Null
        $taskCreated = $false
    } else {
        Register-KeeperTask -Config $cfg -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile | Out-Null
        $taskCreated = $true
    }
    # codex.autoAnchor.anchorOnApply=true: the config was just applied, so honor
    # the "trigger the CLI right now" request (fire and forget).
    $forcedAnchor = Invoke-ForcedAnchorIfRequested -Config $cfg -KeeperRoot $KeeperRoot -ConfigFile $ConfigFile
    return @{ ok = $true; issues = @(); warnings = @($gate.warnings); profile = $gate; taskName = $taskName; intervalMinutes = (Get-PollConfig $cfg).intervalMinutes; taskCreated = $taskCreated; forcedAnchor = $forcedAnchor }
}

if ($MyInvocation.InvocationName -ne '.') {
    $r = Invoke-ApplyConfig -KeeperRoot $AcKeeperRoot -ConfigFile $AcConfigFile
    Write-Host 'Codex Quota Keeper - Apply Config'
    Write-Host '========================================'
    foreach ($i in $r.issues) { Write-Host "  [ISSUE] $i" -ForegroundColor Yellow }
    foreach ($w in $r.warnings) { Write-Host "  [WARN] $w" -ForegroundColor DarkYellow }
    if ($r.ok) {
        $verb = if ($r.taskCreated) { 'CREATED' } else { 'UPDATED' }
        Write-Host "  Task '$($r.taskName)': $verb, polling every $($r.intervalMinutes) min"
        Write-Host "  Execution profile: $(Get-ExecutionProfileGateSummary -Gate $r.profile)"
        $fa = $r.forcedAnchor
        if ($fa -and $fa.started) {
            Write-Host '  Forced anchor    : STARTED (codex.autoAnchor.anchorOnApply=true)'
        } elseif ($fa) {
            Write-Host "  Forced anchor    : no ($($fa.reason))"
        }
    } else {
        Write-Host '  Config NOT applied (fix the issues above).' -ForegroundColor Red
    }
    exit $(if ($r.ok) { 0 } else { 1 })
}
