# Minimal assertion helpers + temp workspace management for the keeper test suite.
# No Pester dependency so the suite runs anywhere PowerShell runs.

$script:TestFailures = 0
$script:TestChecks = 0

function New-TestWorkspace {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("cqk-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Remove-TestWorkspace {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message = 'expected true')
    $script:TestChecks++
    if (-not $Condition) {
        $script:TestFailures++
        Write-Host "  FAIL: $Message" -ForegroundColor Red
    }
}

function Assert-False {
    param([bool]$Condition, [string]$Message = 'expected false')
    Assert-True (-not $Condition) $Message
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = 'values differ')
    $script:TestChecks++
    $e = "$Expected"; $a = "$Actual"
    if ($e -ne $a) {
        $script:TestFailures++
        Write-Host "  FAIL: $Message (expected [$e], got [$a])" -ForegroundColor Red
    }
}

function Assert-Null {
    param($Value, [string]$Message = 'expected null')
    Assert-True ($null -eq $Value) $Message
}

function Assert-NotNull {
    param($Value, [string]$Message = 'expected non-null')
    Assert-True ($null -ne $Value) $Message
}

function Assert-Contains {
    param($Collection, $Item, [string]$Message = 'collection does not contain item')
    $script:TestChecks++
    $found = $false
    foreach ($x in @($Collection)) { if ("$x" -eq "$Item") { $found = $true } }
    if (-not $found) {
        $script:TestFailures++
        Write-Host "  FAIL: $Message (missing [$Item])" -ForegroundColor Red
    }
}

function Start-TestGroup {
    param([string]$Name)
    Write-Host "- $Name" -ForegroundColor Cyan
}

function Get-TestResult {
    return @{ failures = $script:TestFailures; checks = $script:TestChecks }
}

# Default-merged valid config for tests.
function New-TestConfig {
    param([hashtable]$Override = @{})
    # v2 config schema (audit plan v1.0 §6.1)
    $base = @{
        schemaVersion = 2
        mode = 'MonitorOnly'
        poll = @{ intervalMinutes = 15; minimumIntervalMinutes = 5 }
        leader = @{ enabled = $true; leaseTtlMinutes = 45; graceMinutes = 5; takeoverOnExpiry = $true; label = 'Test PC' }
        codex = @{ command = 'auto'; queryTimeoutSeconds = 20; proxy = ''; autoAnchor = @{ enabled = $false; prompt = 'Reply exactly OK.'; maxPerDay = 6; minimumGapMinutes = 60 } }
        github = @{
            coordination = @{ enabled = $true; repoPath = ''; branch = 'cqk/coordination' }
            historySync = @{ enabled = $true; push = $true; branch = 'cqk/history'; eventsOnly = $true }
        }
        logging = @{ retentionDays = 90; includeMachineLabel = $false }
        task = @{ name = 'CodexQuotaKeeper.Check'; startWithWindows = $true; runIfNetworkAvailable = $true; wakeToRun = $false }
    }
    foreach ($k in $Override.Keys) {
        if ($base[$k] -is [hashtable] -and $Override[$k] -is [hashtable]) {
            foreach ($k2 in $Override[$k].Keys) { $base[$k][$k2] = $Override[$k][$k2] }
        } else {
            $base[$k] = $Override[$k]
        }
    }
    return $base
}

function Write-TestConfigFile {
    param([string]$Path, [hashtable]$Config)
    $json = ConvertTo-Json -InputObject $Config -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

# ---- git test repos (local bare origin + working clone) --------------------

function Invoke-TestGit {
    param([string]$RepoPath, [string[]]$ArgumentList)
    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    $args = @()
    if ($RepoPath) { $args += @('-C', $RepoPath) }
    $args += $ArgumentList
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $git
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if ($psi.PSObject.Properties['ArgumentList']) {
        foreach ($a in $args) { [void]$psi.ArgumentList.Add([string]$a) }
    } else {
        $psi.Arguments = ($args | ForEach-Object { '"' + ("$_" -replace '"', '\"') + '"' }) -join ' '
    }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch { }; return @{ ok = $false } }
    return @{ ok = ($p.ExitCode -eq 0); stdout = $p.StandardOutput.ReadToEnd(); stderr = $p.StandardError.ReadToEnd() }
}

function New-TestOriginAndClone {
    # Creates <workspace>/origin.git (bare) and <workspace>/repo (clone).
    param([string]$Workspace)
    $origin = Join-Path $Workspace 'origin.git'
    $clone = Join-Path $Workspace 'repo'
    $null = Invoke-TestGit -RepoPath $null -ArgumentList @('init', '--bare', '-q', $origin)
    $null = Invoke-TestGit -RepoPath $null -ArgumentList @('clone', '-q', $origin, $clone)
    return @{ origin = $origin; clone = $clone }
}
