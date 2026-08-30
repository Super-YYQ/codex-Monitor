# Unit tests for common.ps1: config load/validation, machine identity, backoff,
# sanitization, hashing, atomic JSON writes, local runner lock.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
. (Join-Path (Split-Path -Parent $testsDir) 'scripts\common.ps1')

Start-TestGroup 'config: defaults are conservative'

$defaults = Get-DefaultConfig
Assert-Equal 'MonitorOnly' $defaults.mode 'default mode is MonitorOnly'
Assert-False ([bool]$defaults.codex.autoAnchor) 'autoAnchor default off'
Assert-Equal 15 $defaults.pollIntervalMinutes 'default poll 15 min'
Assert-Equal 5 $defaults.minimumPollIntervalMinutes 'min poll floor 5 min'

Start-TestGroup 'config: Load-Config merges defaults and validates'

$ws = New-TestWorkspace
try {
    $cfgFile = Join-Path $ws 'config.json'
    $cfg = New-TestConfig @{ github = @{ enabled = $false } }
    [void](Write-TestConfigFile $cfgFile $cfg)
    $loaded = Load-Config $cfgFile
    Assert-Equal 0 @($loaded.issues).Count 'valid config has no issues'
    Assert-Equal 'MonitorOnly' $loaded.config.mode 'mode preserved'
    Assert-Equal 'Test PC' $loaded.config.leader.label 'test label preserved'

    Start-TestGroup 'config: poll interval below minimum is rejected'

    $bad = New-TestConfig @{ pollIntervalMinutes = 1; minimumPollIntervalMinutes = 1 }
    [void](Write-TestConfigFile $cfgFile $bad)
    $loaded2 = Load-Config $cfgFile
    Assert-True (@($loaded2.issues).Count -ge 1) 'poll below 5-min floor rejected'

    Start-TestGroup 'config: autoAnchor=true requires mode=AutoAnchor'

    $bad2 = New-TestConfig @{ codex = @{ autoAnchor = $true } }
    [void](Write-TestConfigFile $cfgFile $bad2)
    $loaded3 = Load-Config $cfgFile
    Assert-True (@($loaded3.issues).Count -ge 1) 'autoAnchor without AutoAnchor mode rejected'

    Start-TestGroup 'config: github enabled without repoPath rejected'

    $bad3 = New-TestConfig @{ github = @{ enabled = $true; repoPath = '' } }
    [void](Write-TestConfigFile $cfgFile $bad3)
    $loaded4 = Load-Config $cfgFile
    Assert-True (@($loaded4.issues).Count -ge 1) 'missing repoPath rejected'

    Start-TestGroup 'config: invalid JSON / missing file handled'

    [System.IO.File]::WriteAllText($cfgFile, '{ not json', (New-Object System.Text.UTF8Encoding($false)))
    $loaded5 = Load-Config $cfgFile
    Assert-True (@($loaded5.issues).Count -ge 1) 'invalid JSON reported'
    $loaded6 = Load-Config (Join-Path $ws 'nope.json')
    Assert-True (@($loaded6.issues).Count -ge 1) 'missing config reported'
} finally {
    Remove-TestWorkspace $ws
}

Start-TestGroup 'machine identity: stable random id, label update'

$ws = New-TestWorkspace
try {
    $m1 = Get-MachineIdentity -Root $ws -Label 'Home PC'
    $m2 = Get-MachineIdentity -Root $ws -Label 'Home PC'
    Assert-Equal $m1.machineId $m2.machineId 'machineId stable across calls'
    $parsed = [guid]::Empty
    Assert-True ([guid]::TryParse([string]$m1.machineId, [ref]$parsed)) 'machineId is a GUID'
    $m3 = Get-MachineIdentity -Root $ws -Label 'Office PC'
    Assert-Equal $m1.machineId $m3.machineId 'id survives label change'
    Assert-Equal 'Office PC' $m3.label 'label updated on request'
} finally {
    Remove-TestWorkspace $ws
}

Start-TestGroup 'backoff: set/expiry/clear'

$ws = New-TestWorkspace
try {
    Assert-False (Test-InBackoff $ws) 'no backoff initially'
    Set-Backoff -Root $ws -Minutes 60 -Reason '429'
    Assert-True (Test-InBackoff $ws) 'backoff active after set'
    $state = Get-BackoffState $ws
    Assert-Equal '429' $state.reason 'backoff reason recorded'
    Clear-Backoff $ws
    Assert-False (Test-InBackoff $ws) 'backoff cleared'
    Set-Backoff -Root $ws -Minutes (-1) -Reason 'past'
    Assert-False (Test-InBackoff $ws) 'expired backoff treated as inactive'
} finally {
    Remove-TestWorkspace $ws
}

Start-TestGroup 'sanitization: credentials never reach output'

$leaky = 'token=abc12345 refresh_token: "xyz-98765432" Authorization: Bearer sk-proj-abcdef123456 cookie=sessionid=zzz; keep-this'
$clean = Hide-SensitiveText $leaky
Assert-False ($clean -match 'abc12345') 'token value removed'
Assert-False ($clean -match 'xyz-98765432') 'refresh token removed'
Assert-False ($clean -match 'sk-proj-abcdef') 'openai key removed'
Assert-True ($clean -match 'keep-this') 'benign content preserved'

$rec = Sanitize-Record @{
    ts = 't'; event = 'E'; machineId = 'm'; windows = @(); error = 'token=abc12345';
    prompt = 'MUST NOT LEAK'; authJson = 'MUST NOT LEAK'; session = 'MUST NOT LEAK'
}
Assert-Null $rec.prompt 'non-allowlisted key dropped'
Assert-Null $rec.authJson 'authJson dropped from history records'
Assert-False ("$($rec.error)" -match 'abc12345') 'error text sanitized'

Start-TestGroup 'sha256: deterministic hex digest'

$h1 = Get-Sha256Hex '300|1788062400|reset'
$h2 = Get-Sha256Hex '300|1788062400|reset'
$h3 = Get-Sha256Hex '300|1788062401|reset'
Assert-Equal $h1 $h2 'same input same hash'
Assert-True ($h1 -match '^[0-9a-f]{64}$') 'sha256 hex format'
Assert-True ($h1 -ne $h3) 'different input different hash'

Start-TestGroup 'json: atomic write + roundtrip + jsonl'

$ws = New-TestWorkspace
try {
    $obj = @{ a = 1; nested = @{ list = @(1, 2, 3) } }
    $p = Join-Path $ws 'sub\state.json'
    Write-JsonFileAtomic $p $obj
    $back = Read-JsonFile $p
    Assert-Equal 1 $back.a 'atomic write roundtrip'
    Assert-Equal 3 @($back.nested.list).Count 'nested structure preserved'

    $jl = Join-Path $ws 'logs\runner.jsonl'
    Write-JsonLine $jl @{ event = 'A' }
    Write-JsonLine $jl @{ event = 'B' }
    $lines = [System.IO.File]::ReadAllLines($jl)
    Assert-Equal 2 @($lines).Count 'two jsonl lines'
    Assert-Equal 'B' (ConvertFrom-JsonSafe $lines[1]).event 'jsonl line parses'

    $noTmpLeft = Get-ChildItem -LiteralPath $ws -Filter '*.tmp-*' -Recurse -Force
    Assert-Equal 0 @($noTmpLeft).Count 'no temp files left behind'
} finally {
    Remove-TestWorkspace $ws
}

Start-TestGroup 'runner lock: second acquisition blocked, released on exit'

$ws = New-TestWorkspace
try {
    $lock1 = Enter-RunnerLock $ws
    Assert-True $lock1.acquired 'first lock acquired'
    $lock2 = Enter-RunnerLock $ws
    Assert-False $lock2.acquired 'second lock denied while held'
    Exit-RunnerLock $ws
    $lock3 = Enter-RunnerLock $ws
    Assert-True $lock3.acquired 'lock re-acquired after release'
    Exit-RunnerLock $ws

    Start-TestGroup 'runner lock: stale lock file from dead pid is broken'

    $lockPath = Join-Path (Get-LockDir $ws) 'runner.lock'
    Write-JsonFileAtomic $lockPath @{ pid = 99999999; startedAt = '2000-01-01T00:00:00+00:00' }
    $lock4 = Enter-RunnerLock $ws
    Assert-True $lock4.acquired 'stale lock file broken and replaced'
    Exit-RunnerLock $ws
} finally {
    Remove-TestWorkspace $ws
}

Start-TestGroup 'time: iso timestamps and epoch roundtrip'

$now = Get-Date
$iso = Get-IsoTimestamp
Assert-True ($iso -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$') 'iso format with offset'
$epoch = ConvertTo-EpochSeconds $now
$round = ConvertFrom-EpochSeconds $epoch
Assert-True ([Math]::Abs(($round - $now).TotalSeconds) -lt 2) 'epoch roundtrip within 2s'

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "common.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
