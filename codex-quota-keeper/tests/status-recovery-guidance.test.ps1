# Default status must explain a pause and the tool's own recovery, without
# requiring Detailed mode or sending the user to run repair commands.
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
$scriptDir = Join-Path (Split-Path -Parent $testsDir) 'scripts'
. (Join-Path $scriptDir 'status.ps1')
. (Join-Path $testsDir 'golden-fixtures.ps1')

$ws = New-TestWorkspace
try {
    $now = Get-GoldenNow
    $cfg = New-GoldenConfig -Coordination $false -AutoAnchor $true -Schedule @('05:55', '11:00', '16:05')
    $status = New-GoldenStatus @{
        autoAnchor = $true
        anchorSchedule = @{ slots = @('05:55', '11:00', '16:05') }
        quota = @{ lastReadAt = (ConvertTo-IsoString $now.AddMinutes(-10)); stale = $true; windows = @() }
        lastError = 'READ_FAILED: network error'
        lastErrorEvent = 'READ_FAILED'
        lastErrorAt = (ConvertTo-IsoString $now.AddMinutes(-10))
        lastErrorText = 'network error'
    } -LocalOnly
    $status.task.nextRunTime = $now.AddMinutes(38)
    $nextText = $status.task.nextRunTime.ToString('yyyy-MM-dd HH:mm:ss')

    Start-TestGroup 'quota failure: default finding contains cause and automatic recovery'
    $a = Get-StatusAssessment -Status $status -Config $cfg -KeeperRoot $ws -Now $now
    $block = Get-StatusFinding -Assessment $a -Code 'AUTOANCHOR_BLOCKED'
    Assert-NotNull $block 'the stale quota guard is still reported'
    Assert-Equal 'ERROR' $block.severity 'untrusted quota still prevents anchoring'
    Assert-True ($block.title -match '额度.*读取|读取.*额度') 'the title explains the quota-read cause'
    Assert-True ($block.action -match '自动恢复') 'the tool owns recovery'
    Assert-True ($block.action -match '无需手动') 'no manual unblock instruction'
    Assert-True ($block.action.Contains($nextText)) 'next regular check is visible in the finding'
    Assert-True ($block.titleEn -match 'quota') 'English metadata also identifies the cause'
    Assert-True ($block.actionEn -match 'automatic|automatically') 'English metadata explains recovery'
    $panel = Format-StatusText (Get-StatusDisplayLines -Status $status -Assessment $a -Config $cfg -KeeperRoot $ws -Now $now)
    Assert-True ($panel.Contains($block.title)) 'cause is visible in the normal panel'
    Assert-False ($panel.Contains('按下述原因')) 'no dangling reference to hidden details'
    Assert-False ($panel.Contains('不是锚定功能故障')) 'does not dismiss a possible tool failure'

    Start-TestGroup 'different prerequisites have different visible reasons'
    Assert-True ((Get-StatusAnchorBlock -SchemaUnknown $true).title -match '格式') 'unknown schema is explicitly named'
    Assert-True ((Get-StatusAnchorBlock -RateLimitReachedType primary).title -match '额度') 'exhausted quota is explicitly named'
    Assert-True ((Get-StatusAnchorBlock -LocalOnly $false -Role PASSIVE).title -match '负责人') 'missing leadership is explicitly named'
    Assert-Equal 'BACKOFF_ACTIVE' (Get-StatusAnchorBlock -QuotaStale $true -BackoffActive $true).code 'original guard order remains intact'

    Start-TestGroup 'disabled tasks do not promise a future scheduled recovery'
    $status.task.enabled = $false
    $disabled = Get-StatusAssessment -Status $status -Config $cfg -KeeperRoot $ws -Now $now
    Assert-False ((Get-StatusFinding $disabled AUTOANCHOR_BLOCKED).action.Contains($nextText)) 'disabled task time is not advertised as an upcoming check'
    $status.task.enabled = $true

    Start-TestGroup 'expired successful profile is routine automatic validation'
    $status.quota.stale = $false
    $status.executionProfile = @{ source = 'cache'; stale = $true; value = @{ validation = 'VALID'; validatedAt = (ConvertTo-IsoString $now.AddHours(-8)) } }
    $recovered = Get-StatusAssessment -Status $status -Config $cfg -KeeperRoot $ws -Now $now
    Assert-Null (Get-StatusFinding $recovered AUTOANCHOR_BLOCKED) 'successful background read clears the quota block'
    $profile = Get-StatusFinding $recovered PROFILE_STALE
    Assert-Equal 'INFO' $profile.severity 'routine expiry is informational'
    Assert-True ($profile.action -match '自动.*校验|自动.*复查') 'validation happens automatically before an anchor'
    Assert-False ($profile.action -match '运行.*status') 'manual probe is not presented as required repair'
    $history = Get-StatusFinding $recovered LAST_ERROR_RECENT
    Assert-Equal 'INFO' $history.severity 'recovered historical errors stay informational'
    Assert-True ($history.action -match '无需手动') 'history does not send the user to repair an already recovered fault'
    $panel = Format-StatusText (Get-StatusDisplayLines -Status $status -Assessment $recovered -Config $cfg -KeeperRoot $ws -Now $now)
    Assert-True ($panel -match '执行配置校验\s*:\s*\[信息\].*自动') 'profile row shows automatic revalidation as information'

    Start-TestGroup 'real profile failures are not hidden by cache expiry'
    $status.executionProfile.value.validation = 'INVALID'
    $invalid = Get-StatusAssessment -Status $status -Config $cfg -KeeperRoot $ws -Now $now
    Assert-Equal 'ERROR' (Get-StatusFinding $invalid PROFILE_INVALID).severity 'known invalid profile remains an error even when old'
    $status.executionProfile = @{ source = 'live'; stale = $false; value = @{ validation = 'UNAVAILABLE' } }
    $unavailable = Get-StatusAssessment -Status $status -Config $cfg -KeeperRoot $ws -Now $now
    Assert-Equal 'WARNING' (Get-StatusFinding $unavailable PROFILE_UNAVAILABLE).severity 'a real failed validation still needs attention'
} finally { Remove-TestWorkspace $ws }

$r = Get-TestResult
Write-Host "`n$($r.checks) checks, $($r.failures) failures."
exit $(if ($r.failures -eq 0) { 0 } else { 1 })
