# Tests for tools/build-release.ps1 (CQK-035).
#
# The packager's whole job is to refuse: refuse a dirty tree, refuse a credential,
# refuse an artifact that carries local state, refuse a checksum that does not
# match. Those refusals are the product, so they are driven here against a
# throwaway git repository rather than eyeballed once at a prompt.
#
# Nothing in this file may contain a string the secret scanner matches - it runs
# over the tests directory like everything else (CQK-033), so a "fake" credential
# planted here would fail CI rather than quietly pass. The synthetic token below is
# built by concatenation for exactly that reason.

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $testsDir 'test-helper.ps1')
# Both files are function libraries behind an InvocationName guard, so sourcing
# them defines the functions without building anything or calling exit.
. (Join-Path $testsDir 'secret-scan.ps1')
. (Join-Path (Split-Path -Parent $testsDir) 'tools\build-release.ps1')

$repoRoot = Split-Path -Parent (Split-Path -Parent $testsDir)
$prefix = 'codex-quota-keeper'

# git needs an identity to commit as and CI runners do not reliably have one
# configured; set it per-repo instead of assuming the developer's global config.
function Set-TestGitIdentity {
    param([string]$RepoPath)
    $null = Invoke-TestGit -RepoPath $RepoPath -ArgumentList @('config', 'user.name', 'CQK Test')
    $null = Invoke-TestGit -RepoPath $RepoPath -ArgumentList @('config', 'user.email', 'cqk-test@example.invalid')
    $null = Invoke-TestGit -RepoPath $RepoPath -ArgumentList @('config', 'commit.gpgsign', 'false')
}

function New-MiniReleaseRepo {
    <#
    Builds <workspace>/origin.git + <workspace>/repo with the same prefix layout as
    the real repository, including a copy of the real secret scanner so the
    secret-gate linkage is exercised rather than stubbed.

    The scanner allowlists fixture files by exact repo-relative path, so a mini
    repo without them fails its own build on stale-allowlist findings. Recreating
    them from Get-FakeCredential* keeps the fixture honest without copying token
    text into this file.
    #>
    param([string]$Workspace, [string]$Version = '0.9.0-beta', [hashtable]$Files = @{})
    $repos = New-TestOriginAndClone -Workspace $Workspace
    $clone = $repos.clone
    Set-TestGitIdentity $clone
    $root = Join-Path $clone $prefix
    New-Item -ItemType Directory -Path (Join-Path $root 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'tests') -Force | Out-Null
    # The scanner's self-exemption is keyed on this exact path, so keeping the
    # layout identical is not cosmetic.
    Copy-Item -LiteralPath (Join-Path $testsDir 'secret-scan.ps1') -Destination (Join-Path $root 'tests\secret-scan.ps1') -Force
    $lits = @(Get-FakeCredentialLiteral)
    foreach ($fp in @(Get-FakeCredentialFixturePath)) {
        $full = Join-Path $root ($fp -replace [regex]::Escape("$prefix/"), '' -replace '/', '\')
        $mine = @($lits | Where-Object { $_.Length -gt 0 })
        # github-sync.test.ps1 holds three of the four literals, golden-fixtures.ps1
        # the fourth; which file holds which does not matter as long as each is used
        # by a file on the allowlist.
        [System.IO.File]::WriteAllText($full, ($mine -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    [System.IO.File]::WriteAllText((Join-Path $root 'scripts\common.ps1'), "`$script:CQK_VERSION = '$Version'`n", (New-Object System.Text.UTF8Encoding($false)))
    foreach ($rel in @('scripts\runner.ps1', 'install.cmd', 'config.example.jsonc', 'README.md')) {
        $full = Join-Path $root $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
        [System.IO.File]::WriteAllText($full, "placeholder for $rel`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $root ([string]$rel -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
        [System.IO.File]::WriteAllText($full, [string]$Files[$rel], (New-Object System.Text.UTF8Encoding($false)))
    }
    $null = Invoke-TestGit -RepoPath $clone -ArgumentList @('add', '-A')
    $null = Invoke-TestGit -RepoPath $clone -ArgumentList @('commit', '-q', '-m', 'mini release fixture')
    return @{ origin = $repos.origin; clone = $clone; root = $root }
}

# -----------------------------------------------------------------------------
Start-TestGroup 'forbidden-entry gate is a pure function and actually discriminates'

# Splitting the gate out of the build is deliberate: proving it against a synthetic
# entry list is honest, while committing a runtime/ directory to Git just to prove
# the packager drops it would put local-state paths in the repository.
$clean = @("$prefix/README.md", "$prefix/config.example.jsonc", "$prefix/scripts/runner.ps1",
           "$prefix/install.cmd", "$prefix/tests/secret-scan.ps1")
Assert-Equal 0 @(Get-ForbiddenArtifactEntry -Prefix $prefix -Entries $clean).Count 'a normal artifact has no forbidden entries'

$dirtyEntries = @(
    "$prefix/runtime/state.json",
    "$prefix/runtimes/mock/app-server.js",
    "$prefix/history/events-2026-08-30.jsonl",
    "$prefix/config.json",
    "$prefix/deploy/prod.env",
    "$prefix/certs/signing.pem",
    "$prefix/certs/signing.key",
    "$prefix/certs/ship.pfx",
    "$prefix/.git/config"
)
foreach ($e in $dirtyEntries) {
    Assert-Contains @(Get-ForbiddenArtifactEntry -Prefix $prefix -Entries $e) $e "forbidden: $e"
}
Assert-Equal $dirtyEntries.Count @(Get-ForbiddenArtifactEntry -Prefix $prefix -Entries $dirtyEntries).Count 'every local-state shape is caught in one pass'

# Anchoring cuts both ways: a same-named path OUTSIDE the packaged prefix is not
# this project's local state and must not fail the build. (runtime|runtimes|history
# and config.json are matched only DIRECTLY under the prefix, mirroring the
# .gitignore layout at the project root - a nested docs/runtime/ is out of scope.)
$outside = @('docs/runtime/notes.md', 'tools/history/readme.md', 'other/config.json', 'docs/env-notes.md')
Assert-Equal 0 @(Get-ForbiddenArtifactEntry -Prefix $prefix -Entries $outside).Count 'unprefixed look-alike paths are not forbidden'
# ...but the extension rule is deliberately NOT anchored, since key material can
# sit anywhere in a tree.
Assert-Equal 1 @(Get-ForbiddenArtifactEntry -Prefix $prefix -Entries 'elsewhere/server.pem').Count 'key material is caught at any path'
Assert-Equal 0 @(Get-ForbiddenArtifactEntry -Prefix $prefix -Entries "$prefix/runner.psf").Count 'a near-miss extension is not reported (.psf is not .pfx)'

# -----------------------------------------------------------------------------
Start-TestGroup 'required-entry gate names the paths users install from'

Assert-Equal 4 @(Get-MissingRequiredEntry -Prefix $prefix -Entries @()).Count 'an empty archive is missing all four'
Assert-Equal 0 @(Get-MissingRequiredEntry -Prefix $prefix -Entries $clean).Count 'the four required entries are all in $clean'
Assert-Equal "$prefix/install.cmd" (@(Get-MissingRequiredEntry -Prefix $prefix -Entries ($clean | Where-Object { $_ -ne "$prefix/install.cmd" }))[0]) 'a renamed install entry point is reported by name'

# The real repository must satisfy the same gate: a rename of any of these four
# would ship an artifact that cannot install, and the mini repo cannot catch that
# because this test writes its placeholders.
$tracked = @((Invoke-TestGit -RepoPath $repoRoot -ArgumentList @('ls-files', '--', $prefix)).stdout -split "`r?`n" |
    ForEach-Object { $_ -replace '\\', '/' } | Where-Object { $_ -ne '' })
Assert-Equal 0 @(Get-MissingRequiredEntry -Prefix $prefix -Entries $tracked).Count 'the four required paths are tracked in the real repository'
Assert-True ($tracked.Count -ge 40) "the real prefix has a plausible file count (got $($tracked.Count))"

# The artifact directory must never be committed: a checked-in ZIP is a binary
# nobody can diff, and its SHA256SUMS would describe a stale build.
$gitignoreText = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $testsDir) '.gitignore'))
Assert-True ($gitignoreText -match '(?m)^tools/dist/?$') 'tools/dist is listed in .gitignore'
Assert-True (Invoke-TestGit -RepoPath $repoRoot -ArgumentList @('check-ignore', '-q', "$prefix/tools/dist/x.zip")).ok 'git really ignores a path under tools/dist'

# -----------------------------------------------------------------------------
Start-TestGroup 'SHA256SUMS parsing accepts the shapes other tools write'

$ws = New-TestWorkspace
try {
    $sums = Join-Path $ws 'SHA256SUMS.txt'
    $hexA = ('a' * 64)
    # Text mode (two spaces), extra padding, binary mode (space-star), uppercase
    # hex, a comment line, an 8-hex line and a non-hex line: the format has to
    # survive all of it, because a checksum file written by sha256sum on Linux is
    # the normal way somebody will verify a release.
    [System.IO.File]::WriteAllText($sums, "$hexA  a.zip`r`n$('C' * 64) *b.zip`r`n${hexA}   spaced.zip`r`n# note`r`n$('B' * 63)C  upper.zip`r`ndeadbeef  junk line`r`nnot-a-hash  other.zip`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $map = Read-Sha256Sums $sums
    Assert-Equal 4 $map.Count 'only parsable lines become entries'
    Assert-Equal $hexA $map['a.zip'] 'text-mode line'
    Assert-Equal $hexA $map['spaced.zip'] 'extra padding between hash and name is tolerated'
    Assert-Equal ('c' * 64) $map['b.zip'] 'binary-mode star prefix, hex lower-cased'
    Assert-Equal ('b' * 63 + 'c') $map['upper.zip'] 'uppercase hex is normalised'
    Assert-False $map.ContainsKey('junk') 'a short hash is not silently treated as a name'
    Assert-False $map.ContainsKey('dist') 'no phantom entry from the unparsable lines'

    # Round-trip: what the packager writes must be what it reads back, or the
    # build-time self-check asserts against a format it cannot parse.
    [System.IO.File]::WriteAllText($sums, "$hexA  codex-quota-keeper-v0.9.0-beta.zip`n", (New-Object System.Text.UTF8Encoding($false)))
    $again = Read-Sha256Sums $sums
    Assert-Equal $hexA $again['codex-quota-keeper-v0.9.0-beta.zip'] 'the packager own format round-trips'
    Assert-Equal "$hexA  codex-quota-keeper-v0.9.0-beta.zip`n" ([System.IO.File]::ReadAllText($sums)) 'written with LF only, so sha256sum -c works under WSL'

    Start-TestGroup 'verify catches tampering, deletion and a missing checksum file'

    $good = Join-Path $ws 'payload.bin'
    [System.IO.File]::WriteAllBytes($good, [byte[]](1, 2, 3, 4, 5))
    $real = Get-FileSha256 $good
    Assert-True ($real -match '^[0-9a-f]{64}$') 'file hash is lowercase hex of the right length'
    $dist = Join-Path $ws 'dist'
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    Copy-Item -LiteralPath $good -Destination (Join-Path $dist 'payload.bin')
    [System.IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), "$real  payload.bin`n", (New-Object System.Text.UTF8Encoding($false)))
    $ok = Test-Sha256Sums -OutDir $dist
    Assert-True $ok.ok 'an untouched artifact verifies'
    Assert-Equal 1 @($ok.lines).Count 'one line per checksummed file'
    Assert-True (@($ok.lines)[0].StartsWith('OK')) 'the OK prefix is what a human greps for'

    # A single flipped byte - the realistic corruption, not a re-download.
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $dist 'payload.bin'))
    $bytes[2] = 9
    [System.IO.File]::WriteAllBytes((Join-Path $dist 'payload.bin'), $bytes)
    $tampered = Test-Sha256Sums -OutDir $dist
    $tamperText = [string]::Join("`n", $tampered.lines)
    Assert-False $tampered.ok 'a one-byte edit fails verification'
    Assert-True ($tamperText -match 'expected') 'the failure prints both hashes'
    Assert-True ($tamperText -match [regex]::Escape($real)) 'the expected hash is echoed for comparison'

    Remove-Item -LiteralPath (Join-Path $dist 'payload.bin') -Force
    $gone = Test-Sha256Sums -OutDir $dist
    Assert-False $gone.ok 'a missing file fails verification'
    Assert-True (@($gone.lines)[0] -match 'missing') 'and says so, rather than throwing'

    $empty = Join-Path $ws 'empty-dist'
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    Assert-False (Test-Sha256Sums -OutDir $empty).ok 'no checksums file is a failure, not a vacuous pass'
    [System.IO.File]::WriteAllText((Join-Path $empty 'SHA256SUMS.txt'), "whatever`n", (New-Object System.Text.UTF8Encoding($false)))
    Assert-False (Test-Sha256Sums -OutDir $empty).ok 'a checksums file with no parsable lines also fails'
} finally {
    Remove-TestWorkspace $ws
}

# -----------------------------------------------------------------------------
Start-TestGroup 'version is read from the commit being packaged, not the working tree'

$ws = New-TestWorkspace
try {
    $mini = New-MiniReleaseRepo -Workspace $ws -Version '1.2.3-rc.4'
    $clone = $mini.clone
    $commit = (Invoke-TestGit -RepoPath $clone -ArgumentList @('rev-parse', 'HEAD')).stdout.Trim()
    Assert-Equal '1.2.3-rc.4' (Get-ReleaseVersion -RepoRoot $clone -Commit $commit -Prefix $prefix) 'auto-detected from the committed common.ps1'

    # Change the file in the working tree only: detection must ignore it.
    [System.IO.File]::WriteAllText((Join-Path $clone "$prefix\scripts\common.ps1"), "`$script:CQK_VERSION = '9.9.9'`n", (New-Object System.Text.UTF8Encoding($false)))
    Assert-Equal '1.2.3-rc.4' (Get-ReleaseVersion -RepoRoot $clone -Commit $commit -Prefix $prefix) 'an uncommitted version bump is NOT picked up'
    Assert-True ((Invoke-TestGit -RepoPath $clone -ArgumentList @('status', '--porcelain', '--', $prefix)).stdout.Trim() -ne '') '(the fixture really is dirty, so the line above has teeth)'

    [System.IO.File]::WriteAllText((Join-Path $clone "$prefix\scripts\common.ps1"), "no version here at all`n", (New-Object System.Text.UTF8Encoding($false)))
    $null = Invoke-TestGit -RepoPath $clone -ArgumentList @('commit', '-q', '-am', 'drop version')
    $noVer = (Invoke-TestGit -RepoPath $clone -ArgumentList @('rev-parse', 'HEAD')).stdout.Trim()
    $threw = $false
    try { $null = Get-ReleaseVersion -RepoRoot $clone -Commit $noVer -Prefix $prefix } catch { $threw = $true }
    Assert-True $threw 'a commit with no version line throws rather than shipping an empty tag'
} finally {
    Remove-TestWorkspace $ws
}

# -----------------------------------------------------------------------------
Start-TestGroup 'a real build: artifact, checksum and reproducibility'

$ws = New-TestWorkspace
try {
    $mini = New-MiniReleaseRepo -Workspace $ws -Version '0.9.0-beta'
    $clone = $mini.clone
    $dist = Join-Path $ws 'dist'

    $b1 = Invoke-BuildRelease -RepoRoot $clone -OutDir $dist -Prefix $prefix
    Assert-True (Test-Path -LiteralPath $b1.zip) 'the ZIP exists'
    Assert-Equal 'codex-quota-keeper-v0.9.0-beta.zip' $b1.zipName 'filename carries the version'
    Assert-Equal $b1.sha256 (Get-FileSha256 $b1.zip) 'reported hash matches the bytes on disk'
    Assert-True (Test-Sha256Sums -OutDir $dist).ok 'the artifact verifies immediately after building'
    Assert-True (@($b1.entries | Where-Object { $_ -notlike "$prefix/*" }).Count -eq 0) 'every entry lives under the packaged prefix'
    Assert-True ($b1.entries -contains "$prefix/tests/secret-scan.ps1") 'the scanner itself ships (it is a tracked file)'
    Assert-True ($b1.entries -contains "$prefix/install.cmd") 'the install entry point ships'

    # Rebuild the same commit: identical hash, because entry timestamps come from
    # the commit and blobs are archived with autocrlf disabled. This is the
    # property that lets a third party reproduce a release, so it cannot be
    # assumed - Compress-Archive over the same files would fail it.
    $b2 = Invoke-BuildRelease -RepoRoot $clone -OutDir $dist -Prefix $prefix
    Assert-Equal $b1.sha256 $b2.sha256 'same commit, same bytes - the build is reproducible'
    Assert-Equal $b1.commit $b2.commit 'and it pinned the same commit'

    # An explicit -Version overrides detection but must still be sane.
    $b3 = Invoke-BuildRelease -RepoRoot $clone -OutDir $dist -Version '2.0.0' -Prefix $prefix
    Assert-Equal 'codex-quota-keeper-v2.0.0.zip' $b3.zipName 'explicit version names the artifact'
    $badVer = ''
    try { $null = Invoke-BuildRelease -RepoRoot $clone -OutDir $dist -Version 'v1' -Prefix $prefix } catch { $badVer = $_.Exception.Message }
    Assert-True ($badVer -match 'semver') "a version that would make a nonsense tag is refused (got: $badVer)"

    # A ref that is not a commit must not archive anything at all.
    $badRef = ''
    try { $null = Invoke-BuildRelease -RepoRoot $clone -OutDir $dist -Ref 'no-such-branch-xyz' -Version '3.0.0' -Prefix $prefix } catch { $badRef = $_.Exception.Message }
    Assert-True ($badRef -ne '') 'an unresolvable ref fails the build (git exit code is checked)'
    Assert-False (Test-Path -LiteralPath (Join-Path $dist 'codex-quota-keeper-v3.0.0.zip')) 'and no artifact is left behind'

    Start-TestGroup 'dirty tree is refused by default, only under the packaged prefix'

    New-Item -ItemType Directory -Path (Join-Path $clone 'docs') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $clone 'docs\note.md'), "outside the prefix`n", (New-Object System.Text.UTF8Encoding($false)))
    $outOk = $null
    $outErr = ''
    try { $outOk = Invoke-BuildRelease -RepoRoot $clone -OutDir $dist -Version '4.0.0' -Prefix $prefix } catch { $outErr = $_.Exception.Message }
    Assert-True ($outErr -eq '') "an untracked file outside the prefix does not block a release (got: $outErr)"
    Assert-NotNull $outOk 'and the build succeeded'

    [System.IO.File]::WriteAllText((Join-Path $clone "$prefix\scripts\runner.ps1"), "# dirty`n", (New-Object System.Text.UTF8Encoding($false)))
    $dErr = ''
    try { $null = Invoke-BuildRelease -RepoRoot $clone -OutDir $dist -Prefix $prefix } catch { $dErr = $_.Exception.Message }
    Assert-True ($dErr -match 'not clean') "a dirty file inside the prefix is refused (got: $dErr)"
    # The gate scopes to the prefix, so the message carries what git reported: the
    # name must survive, because "not clean" alone sends the user hunting.
    Assert-True ($dErr -match 'scripts/runner\.ps1' -or $dErr -match 'runner\.ps1') 'and the message names the dirty path'
    $hatch = Invoke-BuildRelease -RepoRoot $clone -OutDir $dist -Version '5.0.0' -Prefix $prefix -DirtyOk
    Assert-NotNull $hatch '-DirtyOk is the documented escape hatch'
} finally {
    Remove-TestWorkspace $ws
}

# -----------------------------------------------------------------------------
Start-TestGroup 'the gates refuse a build that would actually ship local state'

# Tracked-by-force is exactly how the .gitignore defence would fail, so this is the
# regression this group exists for: git archive CAN see it, and only the gate stops
# it. Everything else in the build succeeds, so a passing test here means the gate
# fired and nothing else could have.
$ws = New-TestWorkspace
try {
    $poison = New-MiniReleaseRepo -Workspace $ws -Version '0.9.1' -Files @{
        'runtime/state.json' = "{""machineId"":""M-1""}`n"
        'config.json'        = "{""codex"":{}}`n"
    }
    $pclone = $poison.clone
    $pdist = Join-Path $ws 'dist'
    # Confirm the poison really is in the commit - otherwise this whole group is a
    # test of a build that had nothing wrong with it.
    $pcommit = (Invoke-TestGit -RepoPath $pclone -ArgumentList @('rev-parse', 'HEAD')).stdout.Trim()
    $tree = (Invoke-TestGit -RepoPath $pclone -ArgumentList @('ls-tree', '-r', '--name-only', $pcommit)).stdout
    Assert-True ($tree -match 'runtime/state\.json') 'the fixture committed runtime/state.json'
    Assert-True ($tree -match '[Cc]onfig\.json') 'and config.json'

    $err = ''
    try { $null = Invoke-BuildRelease -RepoRoot $pclone -OutDir $pdist -Prefix $prefix } catch { $err = $_.Exception.Message }
    Assert-True ($err -match 'local state|key material') "a committed runtime/ is refused (got: $err)"
    Assert-False (Test-Path -LiteralPath (Join-Path $pdist 'codex-quota-keeper-v0.9.1.zip')) 'and the rejected ZIP is deleted, not left for someone to attach'
    Assert-False (Test-Path -LiteralPath (Join-Path $pdist 'SHA256SUMS.txt')) 'no checksum file was written for a rejected artifact'

    $ws2 = New-TestWorkspace
    try {
        $keyed = New-MiniReleaseRepo -Workspace $ws2 -Version '0.9.2' -Files @{ 'deploy/signing.pem' = "not a real key`n" }
        $kerr = ''
        try { $null = Invoke-BuildRelease -RepoRoot $keyed.clone -OutDir (Join-Path $ws2 'dist') -Prefix $prefix } catch { $kerr = $_.Exception.Message }
        Assert-True ($kerr -match 'local state|key material') "a committed .pem is refused (got: $kerr)"
    } finally { Remove-TestWorkspace $ws2 }

    # The mirror image: a prefix filter that silently matched nothing would archive
    # an empty tree and still exit 0. Deleting a required path from the commit (not
    # from the working tree) is how that shows up in practice, and only the
    # required-entry gate can catch it - git archive reports success.
    $ws3 = New-TestWorkspace
    try {
        $stripped = New-MiniReleaseRepo -Workspace $ws3 -Version '0.9.4'
        $null = Invoke-TestGit -RepoPath $stripped.clone -ArgumentList @('rm', '-q', "$prefix/install.cmd", "$prefix/README.md")
        $null = Invoke-TestGit -RepoPath $stripped.clone -ArgumentList @('commit', '-q', '-m', 'remove entry points')
        $werr = ''
        try { $null = Invoke-BuildRelease -RepoRoot $stripped.clone -OutDir (Join-Path $ws3 'dist') -Prefix $prefix } catch { $werr = $_.Exception.Message }
        Assert-True ($werr -match 'missing required') "an artifact without its entry points is refused (got: $werr)"
        Assert-True ($werr -match 'install\.cmd') 'and it names the missing path'
        # Join-Path takes exactly two path arguments on PS 5.1 (no -AdditionalChildPath
        # until 6.0), so the three-argument form works on 7 but dies on 5.1.
        Assert-False (Test-Path -LiteralPath (Join-Path (Join-Path $ws3 'dist') 'codex-quota-keeper-v0.9.4.zip')) 'the incomplete ZIP was deleted too'
    } finally { Remove-TestWorkspace $ws3 }
} finally {
    Remove-TestWorkspace $ws
}

# -----------------------------------------------------------------------------
Start-TestGroup 'the secret gate is wired into the packager, not just into CI'

$ws = New-TestWorkspace
try {
    # A credential-shaped string planted in a NON-fixture file has to stop the
    # build. Built by concatenation so this test file stays clean.
    $leaked = 'github_pat_' + ('Q' * 20) + '_9876'
    $bad = New-MiniReleaseRepo -Workspace $ws -Version '0.9.3' -Files @{ 'scripts/leaky.ps1' = "`$token = '$leaked'`n" }
    $err = ''
    try { $null = Invoke-BuildRelease -RepoRoot $bad.clone -OutDir (Join-Path $ws 'dist') -Prefix $prefix } catch { $err = $_.Exception.Message }
    Assert-True ($err -match 'secret scan failed') "a credential in the tree stops the build (got: $err)"
    # Nested: three-argument Join-Path (-AdditionalChildPath) is PS 6.0+, dies on 5.1.
    Assert-False (Test-Path -LiteralPath (Join-Path (Join-Path $ws 'dist') 'codex-quota-keeper-v0.9.3.zip')) 'nothing was archived'

    # And the gate cannot be skipped by absence: no scanner file, no build. An empty
    # repo has no commits, so the missing-scanner check has to fire before the ref
    # resolution - the message is pinned so the order cannot silently invert.
    $noScanner = New-TestOriginAndClone -Workspace (Join-Path $ws 'nosec')
    Set-TestGitIdentity $noScanner.clone
    $nsErr = ''
    try { $null = Invoke-BuildRelease -RepoRoot $noScanner.clone -OutDir (Join-Path $ws 'dist2') -Prefix $prefix } catch { $nsErr = $_.Exception.Message }
    Assert-True ($nsErr -match 'secret gate|secret-scan') "a missing scanner refuses to build (got: $nsErr)"
    Assert-False ($nsErr -match 'rev-parse') 'and it is the scanner check that fired, not a later git error'
} finally {
    Remove-TestWorkspace $ws
}

# -----------------------------------------------------------------------------
Start-TestGroup 'CI and docs reference the packager'

$testYml = [System.IO.File]::ReadAllText((Join-Path $repoRoot '.github\workflows\test-windows.yml'))
# run-all globs tests/*.test.ps1, so this file is in CI as long as it lives there -
# the assertion is on the mechanism, not on this file's own name.
Assert-True ($testYml -match 'run-all\.ps1') 'run-all drives the suite, so this test file runs in CI'
Assert-True (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $testsDir) 'tools\build-release.ps1')) 'the packager is at the documented path'
Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot 'docs\release-engineering.md')) 'release-engineering.md documents the runbook'

$result = Get-TestResult
if ($result.failures -gt 0) { Write-Host "build-release.test.ps1: $($result.failures) failure(s)" -ForegroundColor Red; exit 1 }
exit 0
