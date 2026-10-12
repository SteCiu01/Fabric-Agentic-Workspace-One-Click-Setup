# VendorClone.Tests.ps1
# -------------------------------------------------------------------
# Regression guard for the silent vendor-refresh bug fixed in v0.7.0:
# `Update-VendorClone` must genuinely bring a stale clone to origin/HEAD
# even though the installer runs with $ErrorActionPreference = 'Stop'
# and git writes its normal progress to stderr.
#
# Uses a throwaway local bare repository as "upstream" -- no network.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath

    # Load only the function under test from the real installer source.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-VendorClone' }, $true) | Select-Object -First 1
    $fn | Should -Not -BeNullOrEmpty -Because 'Update-VendorClone must exist in the installer'
    Invoke-Expression $fn.Extent.Text

    $script:Root     = Join-Path ([System.IO.Path]::GetTempPath()) ("fabric_vendor_" + [guid]::NewGuid().ToString('N'))
    $script:Upstream = Join-Path $script:Root 'upstream.git'
    $script:Work     = Join-Path $script:Root 'work'
    $script:Clone    = Join-Path $script:Root 'clone'
    New-Item -ItemType Directory -Path $script:Root | Out-Null

    $script:SavedGitEnv = @{}
    foreach ($n in 'GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL') { $script:SavedGitEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
    $env:GIT_AUTHOR_NAME = 'test'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 'test'; $env:GIT_COMMITTER_EMAIL = 't@t'
    & git init --bare -q $script:Upstream 2>$null
    & git clone -q $script:Upstream $script:Work 2>$null
    Set-Content (Join-Path $script:Work 'SKILL.md') 'v1'
    & git -C $script:Work add . 2>$null; & git -C $script:Work commit -q -m v1 2>$null
    & git -C $script:Work push -q origin HEAD 2>$null
    # The "installed" clone at v1; ensure origin/HEAD exists like a real clone.
    & git clone -q $script:Upstream $script:Clone 2>$null
    # Upstream moves on to v2 while the clone stays stale.
    Set-Content (Join-Path $script:Work 'SKILL.md') 'v2'
    & git -C $script:Work commit -q -am v2 2>$null
    & git -C $script:Work push -q origin HEAD 2>$null
    $script:UpstreamHead = (& git -C $script:Work rev-parse HEAD 2>$null)
}

AfterAll {
    foreach ($n in $script:SavedGitEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $script:SavedGitEnv[$n], 'Process') }
    if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Update-VendorClone (vendor skill repositories mirror upstream)' {

    It 'starts from a genuinely stale clone (test precondition)' {
        (& git -C $script:Clone rev-parse HEAD 2>$null) | Should -Not -Be $script:UpstreamHead
    }

    It 'brings a stale clone to origin/HEAD under $ErrorActionPreference = Stop' {
        $ErrorActionPreference = 'Stop'
        { Update-VendorClone $script:Clone 'test-clone' } | Should -Not -Throw
        (& git -C $script:Clone rev-parse HEAD 2>$null) | Should -Be $script:UpstreamHead
        (Get-Content (Join-Path $script:Clone 'SKILL.md')) | Should -Be 'v2'
    }

    It 'stashes local edits instead of losing them' {
        Set-Content (Join-Path $script:Clone 'SKILL.md') 'local-edit'
        Set-Content (Join-Path $script:Clone 'untracked.txt') 'mine'
        $ErrorActionPreference = 'Stop'
        Update-VendorClone $script:Clone 'test-clone'
        (Get-Content (Join-Path $script:Clone 'SKILL.md')) | Should -Be 'v2'
        Test-Path (Join-Path $script:Clone 'untracked.txt') | Should -BeFalse
        (& git -C $script:Clone stash list 2>$null) | Should -Match 'installer-autostash'
    }

    It 'is idempotent when already at upstream' {
        $before = (& git -C $script:Clone rev-parse HEAD 2>$null)
        Update-VendorClone $script:Clone 'test-clone'
        (& git -C $script:Clone rev-parse HEAD 2>$null) | Should -Be $before
    }

    It 'leaves the caller''s ErrorActionPreference untouched' {
        $ErrorActionPreference = 'Stop'
        Update-VendorClone $script:Clone 'test-clone'
        $ErrorActionPreference | Should -Be 'Stop'
    }

    It 'skips silently when the path does not exist' {
        { Update-VendorClone (Join-Path $script:Root 'missing') 'missing' } | Should -Not -Throw
    }
}

Describe 'Update-VendorClone failure paths (never lose edits, never claim a reset that did not happen)' {

    BeforeEach {
        # Fresh clone at v1 (stale) for every failure scenario.
        $script:FailClone = Join-Path $script:Root ("fail_" + [guid]::NewGuid().ToString('N'))
        & git clone -q $script:Upstream $script:FailClone 2>$null
        # Git >= 2.48 re-creates origin/HEAD on fetch; pin it off so the reset-target scenarios are deterministic.
        & git -C $script:FailClone config remote.origin.followRemoteHEAD never 2>$null
        & git -C $script:FailClone reset -q --hard HEAD~1 2>$null
        $script:StaleHead = (& git -C $script:FailClone rev-parse HEAD 2>$null)
    }

    It 'does not hard-reset when the stash fails, and says so' {
        Set-Content (Join-Path $script:FailClone 'SKILL.md') 'my-local-edit'
        # A stale lock file for the stash ref makes `git stash push` fail at the ref update
        # ("Unable to create '.git/refs/stash.lock': File exists") while fetch still works,
        # because ref iteration ignores *.lock files.
        Set-Content (Join-Path $script:FailClone '.git\refs\stash.lock') 'x'
        $ErrorActionPreference = 'Stop'
        $out = Update-VendorClone $script:FailClone 'stash-fail' 6>&1 | Out-String
        $out | Should -Match 'could not be stashed'
        $out | Should -Not -Match 'refreshed|already at upstream'
        (Get-Content (Join-Path $script:FailClone 'SKILL.md')) | Should -Be 'my-local-edit' -Because 'the working tree must be preserved'
        (& git -C $script:FailClone rev-parse HEAD 2>$null) | Should -Be $script:StaleHead -Because 'no reset may run after a failed stash'
    }

    It 'reports failure (not "already at upstream") when both resets fail' {
        # Remove origin/HEAD and the branch upstream so both reset targets are unresolvable.
        & git -C $script:FailClone remote set-head origin -d 2>$null
        & git -C $script:FailClone branch --unset-upstream 2>$null
        $ErrorActionPreference = 'Stop'
        $out = Update-VendorClone $script:FailClone 'reset-fail' 6>&1 | Out-String
        $out | Should -Match 'could not reset'
        $out | Should -Not -Match 'already at upstream|refreshed:'
        (& git -C $script:FailClone rev-parse HEAD 2>$null) | Should -Be $script:StaleHead
    }

    It 'still succeeds through the @{upstream} fallback when only origin/HEAD is missing' {
        & git -C $script:FailClone remote set-head origin -d 2>$null
        $ErrorActionPreference = 'Stop'
        $out = Update-VendorClone $script:FailClone 'fallback' 6>&1 | Out-String
        $out | Should -Match 'refreshed:'
        (& git -C $script:FailClone rev-parse HEAD 2>$null) | Should -Be $script:UpstreamHead
    }
}

Describe 'Update-VendorClone identity guard (never touch a repository that is not the vendor clone)' {

    BeforeAll {
        # An OUTER repository with a vendor-named subfolder that is NOT its own repository:
        # git -C <subfolder> would discover the outer repo. Also give the outer repo a remote
        # named origin so fetch would otherwise succeed.
        $script:Outer = Join-Path $script:Root 'outer-workspace'
        New-Item -ItemType Directory -Path $script:Outer | Out-Null
        & git -C $script:Outer init -q 2>$null
        & git -C $script:Outer remote add origin $script:Upstream 2>$null
        Set-Content (Join-Path $script:Outer 'user-work.txt') 'precious'
        & git -C $script:Outer add . 2>$null; & git -C $script:Outer commit -q -m 'user commit' 2>$null
        $script:OuterHead = (& git -C $script:Outer rev-parse HEAD 2>$null)
        $script:FakeVendor = Join-Path $script:Outer 'skills-for-fabric'
        New-Item -ItemType Directory -Path $script:FakeVendor | Out-Null
        Set-Content (Join-Path $script:FakeVendor 'SKILL.md') 'orphan copy without .git'
        Set-Content (Join-Path $script:Outer 'uncommitted.txt') 'in progress'
    }

    It 'refuses a vendor-named folder that is not the root of its own repository' {
        $ErrorActionPreference = 'Stop'
        $out = Update-VendorClone $script:FakeVendor 'orphan' 6>&1 | Out-String
        $out | Should -Match 'not the root of its own Git repository'
        (& git -C $script:Outer rev-parse HEAD 2>$null) | Should -Be $script:OuterHead -Because 'the outer repository must not be reset'
        Test-Path (Join-Path $script:Outer 'uncommitted.txt') | Should -BeTrue -Because 'the outer working tree must not be stashed'
        (& git -C $script:Outer stash list 2>$null) | Should -BeNullOrEmpty
        (Get-Content (Join-Path $script:FakeVendor 'SKILL.md')) | Should -Be 'orphan copy without .git'
    }

    It 'refuses a real repository whose origin is not the expected vendor remote' {
        $other = Join-Path $script:Root 'other-repo'
        & git clone -q $script:Upstream $other 2>$null
        & git -C $other reset -q --hard HEAD~1 2>$null
        $before = (& git -C $other rev-parse HEAD 2>$null)
        $ErrorActionPreference = 'Stop'
        $out = Update-VendorClone $other 'wrong-remote' -ExpectedRemote 'https://github.com/microsoft/skills-for-fabric.git' 6>&1 | Out-String
        $out | Should -Match '(?s)origin is.*left untouched'
        (& git -C $other rev-parse HEAD 2>$null) | Should -Be $before
    }

    It 'accepts the expected remote with .git / trailing-slash / case differences' {
        $ok = Join-Path $script:Root 'ok-repo'
        & git clone -q $script:Upstream $ok 2>$null
        & git -C $ok reset -q --hard HEAD~1 2>$null
        $expected = ($script:Upstream.Replace('\', '/').ToUpperInvariant()) + '/'
        $ErrorActionPreference = 'Stop'
        $out = Update-VendorClone $ok 'ok' -ExpectedRemote $expected 6>&1 | Out-String
        $out | Should -Match 'refreshed:'
        (& git -C $ok rev-parse HEAD 2>$null) | Should -Be $script:UpstreamHead
    }
}
