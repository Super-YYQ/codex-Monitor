# Tests for tests/secret-scan.ps1 (CQK-033).
#
# The point of these assertions is that the scan cannot quietly stop scanning.
# The previous CI rule dropped every path under \tests\ on a one-line edit with
# nothing failing, so both directions are pinned here: a credential that shows up
# must be reported, and an allowlist entry or a scanned file that disappears must
# be reported too.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
. (Join-Path $testsDir 'secret-scan.ps1')

$repoRoot = Split-Path -Parent $testsDir
# The scanner walks the whole repository, one level above codex-quota-keeper.
$gitRoot = Split-Path -Parent $repoRoot

# Every synthetic token below is built by concatenation so that this file does
# not itself carry a string matching the patterns it tests - the real-repository
# scan further down covers this file like any other.
$FAKE_GHP = 'ghp_' + ('A' * 24)
$FAKE_GHO = 'gho_' + ('B' * 24)
$FAKE_PAT = 'github_pat_' + ('C' * 20) + '_1234'
$FAKE_SK = 'sk-' + ('d' * 24)
$FAKE_KEY = ('-----' + 'BEGIN ' + 'OPENSSH PRIVATE KEY-----')

# Pattern handles looked up by their distinguishing prefix rather than by index,
# so a reorder cannot silently retarget an assertion. Each assertion below then
# builds the *whole* expected issue string from these values - the exact-match
# form is the point, since "$file matches $pattern" is what CI actually prints.
$patterns = Get-SecretScanPattern
$P_SK = @($patterns | Where-Object { $_.StartsWith('sk-') })[0]
$P_GHP = @($patterns | Where-Object { $_.StartsWith('ghp_') })[0]
$P_GHOUSR = @($patterns | Where-Object { $_.StartsWith('gh[') })[0]
$P_PAT = @($patterns | Where-Object { $_.StartsWith('github_pat_') })[0]
$P_KEY = @($patterns | Where-Object { $_.StartsWith('-----BEGIN') })[0]
$P_GENERIC = @($patterns | Where-Object { $_.StartsWith('(?i)') })[0]

Start-TestGroup 'scan patterns and fixture allowlist are single-sourced'

Assert-Equal 6 @($patterns).Count 'pattern count (additions must be deliberate)'
foreach ($p in @($P_SK, $P_GHP, $P_GHOUSR, $P_PAT, $P_KEY, $P_GENERIC)) {
    Assert-True ($null -ne $p) "every pattern is reachable by its prefix: $p"
}
Assert-Equal 6 @($P_SK, $P_GHP, $P_GHOUSR, $P_PAT, $P_KEY, $P_GENERIC).Count 'prefixes are unambiguous'

$literals = Get-FakeCredentialLiteral
$fixtures = Get-FakeCredentialFixturePath
Assert-Equal 4 @($literals).Count 'no new fake literals without a fixture'
foreach ($f in $fixtures) {
    Assert-True (Test-Path -LiteralPath (Join-Path $gitRoot ($f -replace '/', '\'))) "allowlisted fixture exists: $f"
    Assert-True ($f.StartsWith('codex-quota-keeper/tests/')) 'fixture allowlist stays inside the test tree'
}

Start-TestGroup 'real repository scan is clean and actually covers the tree'

$real = Invoke-SecretScan -Root $gitRoot -MustScan @('codex-quota-keeper/scripts/common.ps1', 'codex-quota-keeper/tests/github-sync.test.ps1')
Assert-Equal 0 @($real.issues).Count "repository is clean ($($real.issues -join '; '))"
# git ls-files counts 77, five of them .docx; a fall to (say) 3 would mean the
# walk is silently losing a subtree again.
Assert-True ($real.files -ge 70) "scanned a sane number of files (got $($real.files))"

$walked = @(Get-ScannedFile -Root $gitRoot).path
# The exact regression: the blanket \tests\ filter hid all of these.
Assert-Contains $walked 'codex-quota-keeper/tests/github-sync.test.ps1' 'test files are in scope now'
Assert-Contains $walked 'codex-quota-keeper/tests/golden-fixtures.ps1' 'golden fixture generator is in scope'
Assert-Contains $walked 'codex-quota-keeper/tests/secret-scan.test.ps1' 'this test file is in scope'
Assert-True (@($walked | Where-Object { $_ -like 'codex-quota-keeper/tests/golden/*' }).Count -ge 1) 'golden snapshots are in scope'
Assert-Contains $walked 'codex-quota-keeper/.gitignore' 'dotfiles are read (-Force), not skipped'
Assert-Contains $walked '.github/workflows/security.yml' 'the CI definitions are themselves scanned'
Assert-Equal 0 @($walked | Where-Object { $_ -match '(^|/)\.git/' }).Count 'the .git object store is not walked'

Start-TestGroup 'planted credentials are reported whatever their directory'

$ws = New-TestWorkspace
try {
    function New-MiniFile {
        param([string]$Ws, [string]$Rel, [string]$Text)
        [System.IO.File]::WriteAllText((Join-Path $Ws ($Rel -replace '/', '\')), $Text)
    }
    function New-MiniRepo {
        # Mirrors the real layout one level down so the same relative paths apply.
        # The sanctioned fakes are written in up front: a pristine tree must
        # pass, and the staleness rule would otherwise fire on every literal.
        param([string]$Ws)
        foreach ($d in @('codex-quota-keeper\scripts', 'codex-quota-keeper\tests', 'codex-quota-keeper\tests\golden', '.git\objects')) {
            New-Item -ItemType Directory -Path (Join-Path $Ws $d) -Force | Out-Null
        }
        New-MiniFile $Ws 'codex-quota-keeper/scripts/common.ps1' "# clean`n"
        New-MiniFile $Ws 'codex-quota-keeper/tests/github-sync.test.ps1' ("dirty = 'token $FAKE_GHP and $FAKE_GHO failed'`n")
        New-MiniFile $Ws 'codex-quota-keeper/tests/golden-fixtures.ps1' ("lastError = 'auth failed: token=$FAKE_PAT'`n")
        New-MiniFile $Ws 'codex-quota-keeper/tests/golden/case.txt' 'ok'
        New-MiniFile $Ws '.git/objects/pack.bin' ("$FAKE_GHP`n")
        return @{
            patterns = Get-SecretScanPattern
            # Three of the four real literals; sk-fake belongs to a fixture file
            # this mini repo does not have, so listing it would be a true positive
            # for the staleness rule and noise for every other assertion.
            literals = @($FAKE_GHP, $FAKE_GHO, $FAKE_PAT)
            fixtures = @('codex-quota-keeper/tests/github-sync.test.ps1', 'codex-quota-keeper/tests/golden-fixtures.ps1')
        }
    }
    function Invoke-Mini {
        param([string]$Ws, $M)
        return Invoke-SecretScan -Root $Ws -MustScan @('codex-quota-keeper/scripts/common.ps1') `
            -Patterns $M.patterns -FakeLiterals $M.literals -FixturePaths $M.fixtures
    }

    $m = New-MiniRepo $ws
    $clean = Invoke-Mini $ws $m
    Assert-Equal 0 @($clean.issues).Count "pristine mini repo passes ($($clean.issues -join '; '))"
    Assert-True (@(Get-ScannedFile -Root $ws).path -notcontains '.git/objects/pack.bin') 'a credential inside .git is not walked (objects are compressed anyway)'

    Start-TestGroup 'regression that motivated CQK-033: a credential inside tests/'

    # A token that is not one of the sanctioned fakes, so it has to fall through
    # to the pattern match and be reported on its own merits.
    $strayGhp = 'ghp_' + ('F' * 22)
    New-MiniFile $ws 'codex-quota-keeper/tests/runner.test.ps1' ("t = '$strayGhp'`n")
    $inTests = Invoke-Mini $ws $m
    Assert-True (@($inTests.issues) -contains "codex-quota-keeper/tests/runner.test.ps1 matches $P_GHP") 'a token inside tests/ is reported with a repo-relative path (the old \\tests\\ filter hid it)'
    Remove-Item -LiteralPath (Join-Path $ws 'codex-quota-keeper\tests\runner.test.ps1') -Force
    Assert-Equal 0 @(Invoke-Mini $ws $m).issues.Count 'clean again once the file is gone'

    Start-TestGroup 'generic secret wording and private keys'

    New-MiniFile $ws 'codex-quota-keeper/scripts/leaky.ps1' ("api_key = ""$FAKE_SK""`n")
    $generic = Invoke-Mini $ws $m
    Assert-True (@($generic.issues) -contains "codex-quota-keeper/scripts/leaky.ps1 matches $P_GENERIC") 'an api_key assignment with a quoted value is reported'
    Remove-Item -LiteralPath (Join-Path $ws 'codex-quota-keeper\scripts\leaky.ps1') -Force

    New-MiniFile $ws 'codex-quota-keeper/scripts/key.pem.txt' ("`n$FAKE_KEY`n")
    Assert-True (@((Invoke-Mini $ws $m).issues) -contains "codex-quota-keeper/scripts/key.pem.txt matches $P_KEY") 'a private key block is reported'
    Remove-Item -LiteralPath (Join-Path $ws 'codex-quota-keeper\scripts\key.pem.txt') -Force
    Assert-Equal 0 @(Invoke-Mini $ws $m).issues.Count 'mini repo clean again'

    Start-TestGroup 'the fixture exemption is per literal, not per file'

    # A real-shaped credential pasted next to the sanctioned fakes in the very
    # file that owns the exemption must still be caught.
    $unknown = 'gho_' + ('E' * 22)
    New-MiniFile $ws 'codex-quota-keeper/tests/github-sync.test.ps1' ("dirty = 'token $FAKE_GHP and $FAKE_GHO failed'`nreal = '$unknown'`n")
    $mixed = Invoke-Mini $ws $m
    Assert-True (@($mixed.issues) -contains "codex-quota-keeper/tests/github-sync.test.ps1 matches $P_GHOUSR") 'a non-allowlisted token inside an allowlisted file is still reported'
    Assert-True (@($mixed.issues | Where-Object { $_ -match 'not an allowlisted fixture' }).Count -eq 0) 'the file itself is still a known fixture'
    New-MiniFile $ws 'codex-quota-keeper/tests/github-sync.test.ps1' ("dirty = 'token $FAKE_GHP and $FAKE_GHO failed'`n")

    # Copying a sanctioned fake into production code is a finding, not a pass.
    New-MiniFile $ws 'codex-quota-keeper/scripts/runner.ps1' ("token = '$FAKE_GHP'`n")
    $copied = Invoke-Mini $ws $m
    Assert-True (@($copied.issues | Where-Object { $_ -match 'not an allowlisted fixture' }).Count -ge 1) 'a fixture literal outside its fixture is reported'
    Assert-True (@($copied.issues | Where-Object { $_ -match 'stale' }).Count -eq 0) 'a literal that is in use is not also called stale'
    Remove-Item -LiteralPath (Join-Path $ws 'codex-quota-keeper\scripts\runner.ps1') -Force

    Start-TestGroup 'the allowlist cannot rot into a blind spot'

    # Remove the fake from its fixture (the file stays, only the literal goes) and
    # the entry has to fail rather than sit there enforcing nothing.
    New-MiniFile $ws 'codex-quota-keeper/tests/golden-fixtures.ps1' "lastError = 'redacted'`n"
    $stale = Invoke-Mini $ws $m
    Assert-True (@($stale.issues | Where-Object { $_ -match 'stale fixture allowlist entry' }).Count -ge 1) 'an unused literal is reported as stale'
    Assert-True (@($stale.issues | Where-Object { $_ -match 'github_pat_' }).Count -ge 1) 'and it names the dead entry'
    New-MiniFile $ws 'codex-quota-keeper/tests/golden-fixtures.ps1' ("lastError = 'auth failed: token=$FAKE_PAT'`n")
    Assert-Equal 0 @(Invoke-Mini $ws $m).issues.Count 'restoring the fixture clears it'

    # Rename or delete a fixture file: the exemption must fail loudly, not shrink.
    Remove-Item -LiteralPath (Join-Path $ws 'codex-quota-keeper\tests\github-sync.test.ps1') -Force
    $gone = Invoke-Mini $ws $m
    Assert-True (@($gone.issues | Where-Object { $_ -match 'allowlisted fixture file is not present' }).Count -ge 1) 'a missing fixture file is reported'
    Assert-True (@($gone.issues | Where-Object { $_ -match 'stale' }).Count -ge 1) 'and its literals go stale with it'

    Start-TestGroup 'a walk that finds nothing fails instead of passing'

    $empty = New-TestWorkspace
    try {
        $blind = Invoke-SecretScan -Root $empty -MustScan @('codex-quota-keeper/scripts/common.ps1') -Patterns (Get-SecretScanPattern) -FakeLiterals @() -FixturePaths @()
        Assert-True (@($blind.issues | Where-Object { $_ -match 'scan is blind' }).Count -ge 1) 'a missing must-scan file is a hard issue'
        Assert-Equal 0 $blind.files 'and the walk really found nothing'
        $noMust = Invoke-SecretScan -Root $empty -Patterns (Get-SecretScanPattern) -FakeLiterals @() -FixturePaths @()
        Assert-Equal 0 @($noMust.issues).Count 'with no expectations set, an empty tree is legitimately clean'
    } finally { Remove-TestWorkspace $empty }
} finally {
    Remove-TestWorkspace $ws
}

Start-TestGroup 'CI wiring'

$workflowRaw = [System.IO.File]::ReadAllText((Join-Path $gitRoot '.github\workflows\security.yml'))
# Comments have to come out before the negative assertion below: the step carries
# a comment that *describes* the old `'\\tests\\'` filter, so matching against the
# raw file would pass on the line break alone rather than on the filter being gone.
$workflow = @($workflowRaw -split "`r?`n" | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
Assert-True ($workflow -match 'secret-scan\.ps1') 'security.yml runs the shared scanner, not a drifted inline copy'
Assert-False ($workflow -match "-notmatch '\\\\tests\\\\'") 'the blanket tests/ exclusion is gone for good'
Assert-False ($workflow -match 'Where-Object.*FullName') 'no inline path filtering survives in the scan step'
$runnerYml = [System.IO.File]::ReadAllText((Join-Path $gitRoot '.github\workflows\test-windows.yml'))
Assert-True ($runnerYml -match 'run-all\.ps1') 'run-all still drives the suite, so this test file runs in CI'

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "secret-scan.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
