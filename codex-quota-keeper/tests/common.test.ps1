# Unit tests for common.ps1: config load/validation, machine identity, backoff,
# sanitization, hashing, atomic JSON writes, local runner lock.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
. (Join-Path (Split-Path -Parent $testsDir) 'scripts\common.ps1')

Start-TestGroup 'config: defaults are conservative'

$defaults = Get-DefaultConfig
Assert-Equal 'MonitorOnly' $defaults.mode 'default mode is MonitorOnly'
Assert-Equal 2 $defaults.schemaVersion 'v2 config schema'
Assert-False ([bool]$defaults.codex.autoAnchor.enabled) 'autoAnchor default off'
Assert-Equal 60 $defaults.poll.intervalMinutes 'default poll 60 min'
Assert-Equal 5 $defaults.poll.minimumIntervalMinutes 'min poll floor 5 min'
Assert-False ([bool]$defaults.logging.includeMachineLabel) 'machineLabel privacy default off'
Assert-Equal 'cqk/coordination' $defaults.github.coordination.branch 'coordination branch name'
Assert-Equal 'cqk/history' $defaults.github.historySync.branch 'history branch name'

Start-TestGroup 'config: Load-Config merges defaults and validates'

$ws = New-TestWorkspace
try {
    $cfgFile = Join-Path $ws 'config.json'
    $cfg = New-TestConfig @{ github = @{ coordination = @{ enabled = $false }; historySync = @{ enabled = $false } } }
    [void](Write-TestConfigFile $cfgFile $cfg)
    $loaded = Load-Config $cfgFile
    Assert-Equal 0 @($loaded.issues).Count 'valid config has no issues'
    Assert-Equal 'MonitorOnly' $loaded.config.mode 'mode preserved'
    Assert-Equal 'Test PC' $loaded.config.leader.label 'test label preserved'

    Start-TestGroup 'config: poll interval below minimum is rejected'

    $bad = New-TestConfig @{ poll = @{ intervalMinutes = 1; minimumIntervalMinutes = 1 } }
    [void](Write-TestConfigFile $cfgFile $bad)
    $loaded2 = Load-Config $cfgFile
    Assert-True (@($loaded2.issues).Count -ge 1) 'poll below 5-min floor rejected'

    Start-TestGroup 'config: autoAnchor.enabled=true requires mode=AutoAnchor'

    $bad2 = New-TestConfig @{ codex = @{ autoAnchor = @{ enabled = $true } } }
    [void](Write-TestConfigFile $cfgFile $bad2)
    $loaded3 = Load-Config $cfgFile
    Assert-True (@($loaded3.issues).Count -ge 1) 'autoAnchor without AutoAnchor mode rejected'

    Start-TestGroup 'config: coordination enabled without repoPath rejected'

    $bad3 = New-TestConfig @{ github = @{ coordination = @{ enabled = $true; repoPath = '' } } }
    [void](Write-TestConfigFile $cfgFile $bad3)
    $loaded4 = Load-Config $cfgFile
    Assert-True (@($loaded4.issues).Count -ge 1) 'missing repoPath rejected'

    Start-TestGroup 'config: proxy URL validation'

    $noProxy = New-TestConfig @{
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ proxy = '' }
    }
    [void](Write-TestConfigFile $cfgFile $noProxy)
    $lNone = Load-Config $cfgFile
    Assert-Equal 0 @($lNone.issues).Count 'proxy-off config valid'
    Assert-Equal 0 @((Get-CodexProxyEnvironment $lNone.config).Keys).Count 'no proxy env when proxy is off'

    $goodProxy = New-TestConfig @{
        github = @{ coordination = @{ enabled = $false; repoPath = '' }; historySync = @{ enabled = $false } }
        codex  = @{ proxy = 'http://127.0.0.1:7890' }
    }
    [void](Write-TestConfigFile $cfgFile $goodProxy)
    $lp = Load-Config $cfgFile
    Assert-Equal 0 @($lp.issues).Count 'http proxy URL accepted'
    Assert-Equal 'http://127.0.0.1:7890' (Get-ProxyConfig $lp.config).url 'proxy url preserved'
    $pOn = Get-CodexProxyEnvironment $lp.config
    Assert-Equal 'http://127.0.0.1:7890' $pOn['HTTPS_PROXY'] 'HTTPS_PROXY set'
    Assert-Equal 'http://127.0.0.1:7890' $pOn['ALL_PROXY'] 'ALL_PROXY set'
    Assert-Equal 3 @($pOn.Keys).Count 'exactly three proxy env keys'

    $badProxy = New-TestConfig @{ codex = @{ proxy = 'not a url' } }
    [void](Write-TestConfigFile $cfgFile $badProxy)
    $lpb = Load-Config $cfgFile
    Assert-True (@($lpb.issues).Count -ge 1) 'malformed proxy URL rejected'

    $ftpProxy = New-TestConfig @{ codex = @{ proxy = 'ftp://example.com:21' } }
    [void](Write-TestConfigFile $cfgFile $ftpProxy)
    $lpf = Load-Config $cfgFile
    Assert-True (@($lpf.issues).Count -ge 1) 'non-http(s) proxy scheme rejected'

    Start-TestGroup 'config: legacy v1 keys map onto v2 schema'

    $legacyJson = @'
{
  "schemaVersion": 1,
  "mode": "MonitorOnly",
  "pollIntervalMinutes": 30,
  "minimumPollIntervalMinutes": 10,
  "leader": { "enabled": true, "leaseTtlMinutes": 45, "graceMinutes": 5, "label": "Legacy PC" },
  "codex": { "command": "auto", "queryTimeoutSeconds": 20, "autoAnchor": false, "anchorPrompt": "p", "maxAnchorsPerDay": 4, "minimumAnchorGapMinutes": 30 },
  "github": { "enabled": true, "repoPath": "D:/logrepo", "coordinationBranch": "coordination", "historyBranch": "history", "syncEventsOnly": true, "push": true },
  "logging": { "retentionDays": 30, "includeMachineLabel": true },
  "task": { "name": "LegacyTask", "startWithWindows": true, "runIfNetworkAvailable": true, "wakeToRun": false }
}
'@
    [System.IO.File]::WriteAllText($cfgFile, $legacyJson, (New-Object System.Text.UTF8Encoding($false)))
    $legacy = Load-Config $cfgFile
    Assert-Equal 0 @($legacy.issues).Count 'legacy config valid after mapping'
    Assert-Equal 30 $legacy.config.poll.intervalMinutes 'pollIntervalMinutes mapped'
    Assert-Equal 10 $legacy.config.poll.minimumIntervalMinutes 'minimumPollIntervalMinutes mapped'
    Assert-True ([bool]$legacy.config.github.coordination.enabled) 'github.enabled -> coordination.enabled'
    Assert-Equal 'D:/logrepo' $legacy.config.github.coordination.repoPath 'repoPath mapped'
    Assert-Equal 'coordination' $legacy.config.github.coordination.branch 'coordinationBranch mapped'
    Assert-Equal 'history' $legacy.config.github.historySync.branch 'historyBranch mapped'
    Assert-False ([bool]$legacy.config.codex.autoAnchor.enabled) 'legacy autoAnchor=false mapped'
    Assert-Equal 4 $legacy.config.codex.autoAnchor.maxPerDay 'maxAnchorsPerDay mapped'
    Assert-Equal 2 $legacy.config.schemaVersion 'schema upgraded to 2'

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

Start-TestGroup 'launcher: Resolve-ExecutableLaunchSpec (CQK-004)'

$testsDir2 = Split-Path -Parent $MyInvocation.MyCommand.Path
$spec = Resolve-ExecutableLaunchSpec -Executable 'C:\Tools\codex.exe' -ArgumentList @('app-server')
Assert-Equal 'C:\Tools\codex.exe' $spec.exe 'exe runs directly'
Assert-Equal 'app-server' $spec.args[0] 'exe args preserved'

$spec = Resolve-ExecutableLaunchSpec -Executable 'C:\Tools\mock.ps1' -ArgumentList @('app-server')
Assert-True ("$($spec.exe)" -match 'pwsh|powershell') 'ps1 runs through powershell'
Assert-True ($spec.args -contains '-NoProfile') 'ps1 launched with -NoProfile'
Assert-True ($spec.args -contains 'C:\Tools\mock.ps1') 'ps1 script path in args'

$spec = Resolve-ExecutableLaunchSpec -Executable 'C:\Tools\codex.cmd' -ArgumentList @('app-server')
Assert-True ("$($spec.exe)" -match 'cmd\.exe$') 'cmd wrapped in ComSpec'
Assert-Equal '/d /s /c ""C:\Tools\codex.cmd" "app-server"""' "$($spec.rawArgs)" 'cmd raw command line double-quoted for /s'

$spec = Resolve-ExecutableLaunchSpec -Executable 'pwsh' -ArgumentList @('-NoProfile')
Assert-NotNull $spec 'PATH-resolved executable'
Assert-True ("$($spec.exe)" -match 'pwsh') 'PATH resolution recursed to exe'

Assert-Null (Resolve-ExecutableLaunchSpec -Executable 'no-such-exe-xyz-abc') 'unknown command returns null'

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "common.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
