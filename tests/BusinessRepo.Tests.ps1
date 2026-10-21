# BusinessRepo.Tests.ps1
# -------------------------------------------------------------------
# Regression guard for the Step 4 field failure fixed in v0.7.3:
# on a machine with Git's DEFAULT settings every branch of a business
# repository was reported "Could not create a worktree ... skipped",
# because Fabric item paths nested under source-control-repositories\
# <repo>\<branch>\ exceed Windows' 260-char limit and git's checkout
# dies with "Filename too long" (then deletes the half-made worktree).
# Also guards the phantom 'origin' branch (refs/remotes/origin/HEAD
# shortens to "origin" on Git >= 2.48) and the new failure diagnostics.
#
# Uses throwaway local repositories as "upstream" -- no network. The
# developer's global/system Git config is hidden for the duration so a
# personal core.longpaths=true cannot mask the regression.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Sync-BusinessRepositoryWorktrees' }, $true) | Select-Object -First 1
    $fn | Should -Not -BeNullOrEmpty -Because 'Sync-BusinessRepositoryWorktrees must exist in the installer'
    Invoke-Expression $fn.Extent.Text

    $script:Root      = Join-Path ([System.IO.Path]::GetTempPath()) ("fabric_biz_" + [guid]::NewGuid().ToString('N'))
    $script:Upstream  = Join-Path $script:Root 'upstream.git'
    $script:Work      = Join-Path $script:Root 'work'
    $script:Container = Join-Path $script:Root 'source-control-repositories\team-long'
    $script:GitDir    = Join-Path $script:Container '.bare'
    New-Item -ItemType Directory -Path $script:Root, $script:Container | Out-Null

    # Hide the developer's own Git configuration (a global core.longpaths=true
    # would make the fixture pass for the wrong reason) and pin an identity.
    $script:SavedGitEnv = @{}
    foreach ($n in 'GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL','GIT_CONFIG_GLOBAL','GIT_CONFIG_NOSYSTEM') {
        $script:SavedGitEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process')
    }
    $env:GIT_AUTHOR_NAME = 'test'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 'test'; $env:GIT_COMMITTER_EMAIL = 't@t'
    $script:EmptyGitConfig = Join-Path $script:Root 'empty.gitconfig'
    Set-Content -LiteralPath $script:EmptyGitConfig -Value '' -Encoding ascii
    $env:GIT_CONFIG_GLOBAL = $script:EmptyGitConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'

    # A tracked file whose RELATIVE path alone is ~200 chars (Fabric repos reach
    # 150-190). Built with plumbing so the fixture never touches a long path itself.
    $script:LongRel = ('a' * 70) + '/' + ('b' * 70) + '/' + ('c' * 55) + '.json'
    & git init -q --bare $script:Upstream 2>$null
    & git init -q $script:Work 2>$null
    & git -C $script:Work remote add origin $script:Upstream 2>$null
    $blob1 = ('v1' | & git -C $script:Work hash-object -w --stdin 2>$null)
    $env:GIT_INDEX_FILE = Join-Path $script:Root 'fixture.index'
    & git -C $script:Work update-index --add --cacheinfo "100644,$blob1,README.md" 2>$null
    & git -C $script:Work update-index --add --cacheinfo "100644,$blob1,$($script:LongRel)" 2>$null
    $tree1 = (& git -C $script:Work write-tree 2>$null)
    $script:Commit1 = ('v1' | & git -C $script:Work commit-tree $tree1 2>$null)
    # Upstream moves DI-Test one commit ahead later (for the -Pull test).
    $blob2 = ('v2' | & git -C $script:Work hash-object -w --stdin 2>$null)
    & git -C $script:Work update-index --add --cacheinfo "100644,$blob2,README.md" 2>$null
    $tree2 = (& git -C $script:Work write-tree 2>$null)
    $script:Commit2 = ('v2' | & git -C $script:Work commit-tree $tree2 -p $script:Commit1 2>$null)
    Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
    foreach ($ref in 'main', 'DI-Test', 'DI-prod', 'sub/leaf') { & git -C $script:Work update-ref "refs/heads/$ref" $script:Commit1 2>$null }
    & git -C $script:Work push -q origin 'refs/heads/*:refs/heads/*' 2>$null
    & git --git-dir $script:Upstream symbolic-ref HEAD refs/heads/main 2>$null

    # Mirror exactly as the installer's Step 4 does before calling the function.
    & git clone -q --bare -- $script:Upstream $script:GitDir 2>$null
    & git --git-dir $script:GitDir config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' 2>$null
    & git --git-dir $script:GitDir fetch -q --prune origin 2>$null
    # Make the Git >= 2.48 phantom deterministic on every Git version.
    & git --git-dir $script:GitDir symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>$null
    # A FILE where the 'sub/leaf' worktree's parent folder must go: forces one
    # deterministic worktree failure so the diagnostics path is exercised.
    Set-Content -LiteralPath (Join-Path $script:Container 'sub') -Value 'blocker' -Encoding ascii

    $script:WtDI = Join-Path $script:Container 'DI-Test'
    $script:LongAbs = Join-Path $script:WtDI ($script:LongRel -replace '/', '\')

    # Split a 6>&1 capture into host lines and real return values.
    $script:Capture = {
        param([scriptblock]$Call)
        $all = @(& $Call 6>&1)
        [pscustomobject]@{
            Host   = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData.Message })
            Result = @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ })
        }
    }
}

AfterAll {
    foreach ($n in $script:SavedGitEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $script:SavedGitEnv[$n], 'Process') }
    if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
        # Worktrees now hold >260-char paths that Windows PowerShell 5.1 cannot delete.
        & "$env:SystemRoot\System32\cmd.exe" /c rmdir /s /q "\\?\$($script:Root)" 2>$null | Out-Null
        if (Test-Path -LiteralPath $script:Root) { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Sync-BusinessRepositoryWorktrees (business repository branch mirroring)' {

    It 'fixture: the absolute path of the long file exceeds the classic Windows limit' {
        $script:LongAbs.Length | Should -BeGreaterThan 259
    }

    It 'fixture: refs/remotes/origin/HEAD shortens to the phantom branch name "origin"' {
        @(& git --git-dir $script:GitDir for-each-ref --format='%(refname:short)' refs/remotes/origin 2>$null) | Should -Contain 'origin'
    }

    It 'fixture: with default Git settings the plain worktree add fails the way the field did' {
        $probe = Join-Path $script:Container 'probe-default'
        $ErrorActionPreference = 'Continue'
        $out = @(& git --git-dir $script:GitDir worktree add --detach -- $probe DI-prod 2>&1 | ForEach-Object { "$_" })
        $exit = $LASTEXITCODE
        if ($exit -eq 0) {
            & git --git-dir $script:GitDir worktree remove --force $probe 2>$null | Out-Null
            Set-ItResult -Skipped -Because 'this Git build/OS checks out >260-char paths without core.longpaths; the fix is still exercised below'
        }
        $exit | Should -Not -Be 0
        ($out -join "`n") | Should -Match 'too long'
        Test-Path -LiteralPath $probe | Should -BeFalse -Because 'git removes the half-created worktree'
    }

    It 'creates a worktree per non-main branch, enabling long paths on the mirror only' {
        $ErrorActionPreference = 'Stop'
        $r = & $script:Capture { Sync-BusinessRepositoryWorktrees -GitDir $script:GitDir -Container $script:Container }
        @($r.Result | Sort-Object) | Should -Be @('DI-Test', 'DI-prod' | Sort-Object)
        (& git --git-dir $script:GitDir config --get core.longpaths 2>$null) | Should -Be 'true'
        # Hidden global config stays empty: the user's Git settings are never touched.
        (Get-Content -LiteralPath $script:EmptyGitConfig -Raw).Trim() | Should -Be ''
        Test-Path -LiteralPath $script:WtDI | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Container 'DI-prod') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Container 'main') | Should -BeFalse
        # The >260-char file really exists (checked through git; PS 5.1 cannot see it).
        @(& git -C $script:WtDI ls-files 2>$null) | Should -Contain $script:LongRel
        @(& git -C $script:WtDI status --porcelain 2>$null).Count | Should -Be 0
        (& git -C $script:WtDI rev-parse --abbrev-ref HEAD 2>$null) | Should -Be 'DI-Test'
        (& git -C $script:WtDI rev-parse --abbrev-ref '@{upstream}' 2>$null) | Should -Be 'origin/DI-Test'
        ($r.Host -join "`n") | Should -Match 'Live branches mirrored: .*DI-Test'
        ($r.Host -join "`n") | Should -Match 'Live branches mirrored: .*DI-prod'
        ($r.Host -join "`n") | Should -Match 'longer than 260 characters'
    }

    It 'never treats refs/remotes/origin/HEAD as a branch' {
        $r = & $script:Capture { Sync-BusinessRepositoryWorktrees -GitDir $script:GitDir -Container $script:Container }
        ($r.Host -join "`n") | Should -Not -Match "worktree for 'origin'"
        Test-Path -LiteralPath (Join-Path $script:Container 'origin') | Should -BeFalse
        $r.Result | Should -Not -Contain 'origin'
    }

    It 'prints git''s own error under a skipped branch instead of a bare "skipped"' {
        $r = & $script:Capture { Sync-BusinessRepositoryWorktrees -GitDir $script:GitDir -Container $script:Container }
        $text = $r.Host -join "`n"
        $text | Should -Match "Could not create a worktree for 'sub/leaf'; skipped\."
        $text | Should -Match '(?m)^\s+git: (fatal|error):'
        $r.Result | Should -Not -Contain 'sub/leaf'
    }

    It 'is idempotent: a re-run reuses existing worktrees and reports the same set' {
        $r = & $script:Capture { Sync-BusinessRepositoryWorktrees -GitDir $script:GitDir -Container $script:Container }
        @($r.Result | Sort-Object) | Should -Be @('DI-Test', 'DI-prod' | Sort-Object)
        ($r.Host -join "`n") | Should -Not -Match 'Branch worktree ready'
    }

    It 'with -Pull fast-forwards a clean worktree that is strictly behind' {
        & git -C $script:Work update-ref refs/heads/DI-Test $script:Commit2 2>$null
        & git -C $script:Work push -q origin refs/heads/DI-Test:refs/heads/DI-Test 2>$null
        & git --git-dir $script:GitDir fetch -q --prune origin 2>$null
        (& git -C $script:WtDI rev-parse HEAD 2>$null) | Should -Be $script:Commit1
        $r = & $script:Capture { Sync-BusinessRepositoryWorktrees -GitDir $script:GitDir -Container $script:Container -Pull }
        (& git -C $script:WtDI rev-parse HEAD 2>$null) | Should -Be $script:Commit2
        ($r.Host -join "`n") | Should -Match 'DI-Test fast-forwarded to match online'
        ($r.Host -join "`n") | Should -Match 'DI-prod already up to date'
    }

    It 'with -Pull leaves a worktree with local changes untouched' {
        Set-Content -LiteralPath (Join-Path $script:WtDI 'README.md') -Value 'local edit' -Encoding ascii
        & git -C $script:Work update-ref refs/heads/DI-Test $script:Commit1 2>$null   # upstream differs again
        & git -C $script:Work push -q --force origin refs/heads/DI-Test:refs/heads/DI-Test 2>$null
        & git --git-dir $script:GitDir fetch -q --prune origin 2>$null
        $r = & $script:Capture { Sync-BusinessRepositoryWorktrees -GitDir $script:GitDir -Container $script:Container -Pull }
        (& git -C $script:WtDI rev-parse HEAD 2>$null) | Should -Be $script:Commit2
        (Get-Content -LiteralPath (Join-Path $script:WtDI 'README.md')) | Should -Be 'local edit'
        ($r.Host -join "`n") | Should -Match 'DI-Test has local changes'
    }

    It 'leaves the caller''s ErrorActionPreference untouched' {
        $ErrorActionPreference = 'Stop'
        Sync-BusinessRepositoryWorktrees -GitDir $script:GitDir -Container $script:Container | Out-Null
        $ErrorActionPreference | Should -Be 'Stop'
    }

    It 'returns nothing and does not throw for a missing mirror' {
        $ErrorActionPreference = 'Stop'
        { Sync-BusinessRepositoryWorktrees -GitDir (Join-Path $script:Root 'nope\.bare') -Container $script:Root } | Should -Not -Throw
        @(Sync-BusinessRepositoryWorktrees -GitDir (Join-Path $script:Root 'nope\.bare') -Container $script:Root).Count | Should -Be 0
    }
}

Describe 'Step 4 wiring (static)' {
    BeforeAll { $script:Raw = Get-Content -LiteralPath $script:Installer -Raw }

    It 'Step 4 delegates branch mirroring to the function (single implementation)' {
        $script:Raw | Should -Match 'Sync-BusinessRepositoryWorktrees -GitDir \$gitDir -Container \$container -Pull:\$doPull'
        ([regex]::Matches($script:Raw, 'worktree add --track -B')).Count | Should -Be 1
    }

    It 'the function enables long paths on the mirror and enumerates full ref names' {
        $script:Raw | Should -Match "--git-dir \`$GitDir config core\.longpaths true"
        $script:Raw | Should -Match "for-each-ref --format='%\(refname\)' refs/remotes/origin"
        $script:Raw | Should -Not -Match "for-each-ref --format='%\(refname:short\)' refs/remotes/origin"
    }
}
