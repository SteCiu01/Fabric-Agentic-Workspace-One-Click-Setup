# SetupHonesty.Tests.ps1
# -------------------------------------------------------------------
# The installer must report what really happened. A repository Git refuses to open is not
# "not a repository", a command on PATH that does not start is not an installed tool, a
# skipped refresh does not make a catalogue look fresh, and a run with skipped steps does
# not end with a clean "Setup complete!".
#
# Every case runs in-process: Git is replaced by a stand-in function (refusal, start-up
# failure, success), the PBIVIZ helper is pointed at a file that is not a program, and the
# installer's own functions are loaded from its source. No real Git, Python or network.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $script:Raw = [IO.File]::ReadAllText($script:Installer)
    . (Get-InstallerFunctionLoader 'Get-GitProbe', 'Format-GitProbe', 'Add-SetupWarning', 'Update-VendorClone', 'Test-VendorCloneIdentity',
        'Get-VendorCloneHead', 'Set-SkillCatalogState', 'Get-MissingSkillPins', 'Restore-VendorClone', 'Invoke-VendorRefreshWithHold',
        'Invoke-SkillCatalogHold', 'Try-InstallOptionalTool', 'Add-DirToPath', 'Get-CliVersionProbe', 'Get-PbivizMapGitBlock')
    $script:SetupWarnings = New-Object System.Collections.Generic.List[string]

    $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('fabric honesty ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Base | Out-Null
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:N = 0
    function New-HDir([string]$Prefix = 'd', [switch]$WithGit) {
        $script:N++
        $d = Join-Path $script:Base "$Prefix $($script:N)"
        New-Item -ItemType Directory -Path $d | Out-Null
        if ($WithGit) { New-Item -ItemType Directory -Path (Join-Path $d '.git') | Out-Null }
        return $d
    }

    # Git stand-in. Modes: refused (ownership check), nostart (Windows start-up status code, no
    # output), throws, notrepo, other, ok (answers with $script:GitTop and $script:GitOrigin).
    $script:GitMode = 'ok'; $script:GitTop = ''; $script:GitOrigin = ''
    $script:GitCalls = New-Object System.Collections.Generic.List[string]
    function git {
        $script:GitCalls.Add(($args -join ' '))
        switch ($script:GitMode) {
            'refused' { Write-Error "fatal: detected dubious ownership in repository at '$($args[1])'"; $global:LASTEXITCODE = 128 }
            'nostart' { $global:LASTEXITCODE = -1073741502 }
            'throws'  { throw 'The application was unable to start correctly' }
            'notrepo' { Write-Error 'fatal: not a git repository (or any of the parent directories): .git'; $global:LASTEXITCODE = 128 }
            'other'   { Write-Error 'error: unexpected failure'; $global:LASTEXITCODE = 1 }
            default {
                $global:LASTEXITCODE = 0
                if ($args -contains '--show-toplevel') { $script:GitTop }
                elseif ($args -contains 'remote.origin.url') { $script:GitOrigin }
            }
        }
    }

    # The PBIVIZ helper, from its single source.
    $m = [regex]::Match($script:Raw, "(?s)\`$pbivizAlmScript = @'\r?\n(.*?)\r?\n'@")
    $m.Success | Should -BeTrue
    $helperFile = Join-Path $script:Base 'Pbiviz-Alm.ps1'
    [IO.File]::WriteAllText($helperFile, $m.Groups[1].Value, $script:Utf8)
    . $helperFile
}

AfterAll {
    $script:PbivizGitExe = $null
    if ($script:Base -and (Test-Path -LiteralPath $script:Base)) { Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-GitProbe: Git''s answer is classified, never guessed' {

    BeforeEach { $script:GitCalls.Clear() }

    It 'a missing folder and a folder without .git are reported without asking Git' {
        (Get-GitProbe (Join-Path $script:Base 'does not exist')).State | Should -Be 'missing'
        $plain = New-HDir 'plain'
        $script:GitMode = 'ok'
        (Get-GitProbe $plain).State | Should -Be 'no-repository'
        $script:GitCalls.Count | Should -Be 0
    }

    It '<Mode> is reported as <State>' -TestCases @(
        @{ Mode = 'refused'; State = 'refused';       Detail = 'dubious ownership' }
        @{ Mode = 'nostart'; State = 'cannot-start';  Detail = 'git exit code -1073741502' }
        @{ Mode = 'throws';  State = 'cannot-start';  Detail = 'unable to start' }
        @{ Mode = 'notrepo'; State = 'no-repository'; Detail = 'not a git repository' }
        @{ Mode = 'other';   State = 'error';         Detail = 'unexpected failure' }
    ) {
        param($Mode, $State, $Detail)
        $d = New-HDir 'probe' -WithGit
        $script:GitMode = $Mode
        $p = Get-GitProbe $d
        $p.State | Should -Be $State
        $p.Detail | Should -Match ([regex]::Escape($Detail))
    }

    It 'Git answering with the folder itself is ok; another top level is enclosed' {
        $d = New-HDir 'own' -WithGit
        $script:GitMode = 'ok'; $script:GitTop = $d.Replace('\', '/')
        (Get-GitProbe $d).State | Should -Be 'ok'
        $script:GitTop = $script:Base.Replace('\', '/')
        $p = Get-GitProbe $d
        $p.State | Should -Be 'enclosed'
        $p.TopLevel | Should -Be $script:GitTop
    }

    It 'the plain sentence never calls a refusal a missing repository' {
        $d = New-HDir 'sentence' -WithGit
        $script:GitMode = 'refused'
        $text = Format-GitProbe (Get-GitProbe $d)
        $text | Should -Match '^Git refused to open the repository \(fatal: detected dubious ownership'
        $text | Should -Not -Match 'not a Git repository|not the root'
        $script:GitMode = 'nostart'
        Format-GitProbe (Get-GitProbe $d) | Should -Match '^Git is installed but could not be started \(git exit code -1073741502\)'
    }
}

Describe 'Vendor refresh: a clone Git refuses is kept, not called a stray folder' {

    BeforeEach { $script:GitCalls.Clear() }

    It 'Update-VendorClone reports the refusal, gives no move-aside advice and runs nothing else' {
        $repo = New-HDir 'skills-for-fabric' -WithGit
        $script:GitMode = 'refused'
        $out = (@(Update-VendorClone $repo 'skills-for-fabric' -ExpectedRemote 'https://example.invalid/vendor.git' 6>&1) | ForEach-Object { [string]$_ }) -join "`n"
        $out | Should -Match 'skills-for-fabric: not refreshed -- Git refused to open the repository \(fatal: detected dubious ownership'
        $out | Should -Match 'do not move or re-clone it'
        $out | Should -Not -Match 'not the root of its own Git repository|move it aside'
        $script:VendorRefreshStatus | Should -Be 'blocked'
        @($script:GitCalls | Where-Object { $_ -notmatch 'rev-parse --show-toplevel' }) | Should -BeNullOrEmpty -Because 'no fetch, stash or reset may follow a refusal'
    }

    It 'Update-VendorClone still sends a folder without its own .git to the move-aside path' {
        $repo = New-HDir 'orphan'
        $script:GitMode = 'ok'
        $out = (@(Update-VendorClone $repo 'orphan' 6>&1) | ForEach-Object { [string]$_ }) -join "`n"
        $out | Should -Match 'not the root of its own Git repository -- left untouched \(move it aside'
        $script:VendorRefreshStatus | Should -Be 'not-a-clone'
        $script:GitCalls.Count | Should -Be 0
    }

    It 'Update-VendorClone records a start-up failure as blocked' {
        $repo = New-HDir 'nostart' -WithGit
        $script:GitMode = 'nostart'
        $out = (@(Update-VendorClone $repo 'nostart' 6>&1) | ForEach-Object { [string]$_ }) -join "`n"
        $out | Should -Match 'Git is installed but could not be started'
        $script:VendorRefreshStatus | Should -Be 'blocked'
    }

    It 'maintenance refresh: blocked, previous commits kept, reason recorded' {
        $root = New-HDir 'root'
        $repo = Join-Path $root 'skills-for-fabric'
        New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force | Out-Null
        $statePath = Join-Path $root '.github\agent-docs\skill-catalog-state.json'
        New-Item -ItemType Directory -Path (Split-Path $statePath -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($statePath, '{ "schemaVersion": 1, "catalogs": { "skills-for-fabric": { "state": "upstream", "commit": "' + ('a' * 40) + '", "upstreamCommit": "' + ('b' * 40) + '" } }, "pins": [] }', $script:Utf8)
        $script:vendorCatalogs = [ordered]@{ 'skills-for-fabric' = @{ remote = 'https://example.invalid/vendor.git'; approved = ('c' * 40) } }
        $script:GitMode = 'refused'
        $r = Invoke-VendorRefreshWithHold $root 'skills-for-fabric'
        $r.status | Should -Be 'blocked'
        $r.detail | Should -Match 'Git refused to open the repository'
        $r.commit | Should -Be ('a' * 40)
        $entry = ([IO.File]::ReadAllText($statePath) | ConvertFrom-Json).catalogs.'skills-for-fabric'
        $entry.state | Should -Be 'blocked'
        $entry.commit | Should -Be ('a' * 40)
        $entry.upstreamCommit | Should -Be ('b' * 40)
        $entry.lastConfirmedState | Should -Be 'upstream'
        $entry.reason | Should -Match 'dubious ownership'
        # A second blocked refresh keeps the last confirmed state, not 'blocked'.
        [void](Invoke-VendorRefreshWithHold $root 'skills-for-fabric')
        ([IO.File]::ReadAllText($statePath) | ConvertFrom-Json).catalogs.'skills-for-fabric'.lastConfirmedState | Should -Be 'upstream'
    }

    It 'maintenance refresh: a repository with another origin is still skipped and writes no state' {
        $root = New-HDir 'root'
        $repo = Join-Path $root 'skills-for-fabric'
        New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force | Out-Null
        $script:vendorCatalogs = [ordered]@{ 'skills-for-fabric' = @{ remote = 'https://example.invalid/vendor.git'; approved = ('c' * 40) } }
        $script:GitMode = 'ok'; $script:GitTop = $repo.Replace('\', '/'); $script:GitOrigin = 'https://example.invalid/other.git'
        $r = Invoke-VendorRefreshWithHold $root 'skills-for-fabric'
        $r.status | Should -Be 'skipped'
        $r.detail | Should -Match 'left untouched'
        Test-Path -LiteralPath (Join-Path $root '.github\agent-docs\skill-catalog-state.json') | Should -BeFalse
    }

    It 'install-time hold: blocked with the previous commits for a refused clone, unmanaged for a plain folder' {
        $root = New-HDir 'root'
        New-Item -ItemType Directory -Path (Join-Path $root 'skills-for-fabric\.git') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'power-bi-agentic-development') -Force | Out-Null
        $catalogs = [ordered]@{
            'skills-for-fabric'            = @{ remote = 'https://example.invalid/a.git'; approved = ('c' * 40) }
            'power-bi-agentic-development' = @{ remote = 'https://example.invalid/b.git'; approved = ('d' * 40) }
        }
        $previous = [pscustomobject]@{ 'skills-for-fabric' = [pscustomobject]@{ state = 'held'; commit = ('e' * 40); upstreamCommit = ('f' * 40) } }
        $script:GitMode = 'refused'
        $r = Invoke-SkillCatalogHold -RootPath $root -Refs @() -Before @{} -Catalogs $catalogs -Previous $previous
        $r['skills-for-fabric'].state | Should -Be 'blocked'
        $r['skills-for-fabric'].reason | Should -Match '^Git refused to open the repository'
        $r['skills-for-fabric'].commit | Should -Be ('e' * 40)
        $r['skills-for-fabric'].upstreamCommit | Should -Be ('f' * 40)
        $r['skills-for-fabric'].lastConfirmedState | Should -Be 'held'
        $r['power-bi-agentic-development'].state | Should -Be 'unmanaged' -Because 'a folder without .git is not a refused clone'
        (Invoke-SkillCatalogHold -RootPath $root -Refs @() -Before @{} -Catalogs $catalogs)['skills-for-fabric'].commit | Should -BeNullOrEmpty -Because 'without a previous record nothing is invented'
        $unconfirmed = [pscustomobject]@{ 'skills-for-fabric' = [pscustomobject]@{ state = 'unmanaged'; commit = $null; upstreamCommit = $null } }
        $u = (Invoke-SkillCatalogHold -RootPath $root -Refs @() -Before @{} -Catalogs $catalogs -Previous $unconfirmed)['skills-for-fabric']
        $u.state | Should -Be 'blocked'
        $u.Contains('lastConfirmedState') | Should -BeFalse -Because 'a state no Git read confirmed is not carried forward'
        $again = (Invoke-SkillCatalogHold -RootPath $root -Refs @() -Before @{} -Catalogs $catalogs -Previous ([pscustomobject]@{ 'skills-for-fabric' = [pscustomobject]$r['skills-for-fabric'] }))['skills-for-fabric']
        $again.commit | Should -Be ('e' * 40)
        $again.lastConfirmedState | Should -Be 'held' -Because 'a second blocked run keeps the last confirmed state, not blocked'
    }

    It 'the installer only moves a catalogue''s freshness date after a clone or refresh that happened' {
        $step5 = [regex]::Match($script:Raw, '(?s)Show-Step 5 \$totalSteps.*?Show-Step 6 \$totalSteps').Value
        $step5 | Should -Not -BeNullOrEmpty
        foreach ($name in 'skills-for-fabric', 'power-bi-agentic-development') {
            $step5 | Should -Match ("if \(\`$script:VendorRefreshStatus -in @\('refreshed', 'current'\)\) \{ \`$vendorSynced\['$name'\] = \`$true \}")
            $step5 | Should -Match ("if \(\`$vendorSynced\['$name'\] -and \(Test-Path ")
        }
        @([regex]::Matches($step5, 'LastWriteTime = Get-Date')).Count | Should -Be 2
    }

    It 'the session status and the maintenance command name a blocked catalogue' {
        $script:Raw | Should -Match ([regex]::Escape("elseif (`$c.Value.state -eq 'blocked') { `$blockedCatalogs += "))
        $script:Raw | Should -Match ([regex]::Escape('Not refreshed, Git could not open the clone:'))
        $script:Raw | Should -Match ([regex]::Escape("'blocked'      { `"`${catalog}: not refreshed - "))
        $script:Raw | Should -Match "'Get-GitProbe', 'Format-GitProbe',"
    }

    It 'the agent that runs the refresh is told about the "not refreshed" line (Canary finding)' {
        # Every outcome word the maintenance command can print must be in the playbook of the agent that reports it.
        $playbook = [regex]::Match($script:Raw, "(?m)^\s+playbook = @\('Refresh the two vendor catalogs.*$").Value
        $playbook | Should -Not -BeNullOrEmpty
        foreach ($word in 'refreshed', 'current', 'held', 'incompatible', 'not refreshed', 'skipped') { $playbook | Should -Match ('`' + $word + '`') -Because "the helper can print '$word'" }
        $playbook | Should -Match 'do not move or re-clone the folder'
    }
}

Describe 'Optional installs: success means the tool works' {

    BeforeAll {
        $script:SavedPath = $env:Path
        $script:NoSuchTool = 'zz-honesty-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        function Invoke-StandInInstaller {
            $global:LASTEXITCODE = $script:StandInExit
            $script:StandInOutput
        }
        function Invoke-Try([scriptblock]$Verify, [string]$CheckCmd = $script:NoSuchTool) {
            $all = @(Try-InstallOptionalTool -Name 'Stand-in tool' -CheckCmd $CheckCmd -Attempts @(@{ Exe = 'Invoke-StandInInstaller'; Args = @() }) -ManualUrl 'https://example.invalid' -Verify $Verify 6>&1)
            $env:Path = $script:SavedPath
            return [pscustomobject]@{ Result = @($all | Where-Object { $_ -is [bool] })[-1]; Text = (@($all | Where-Object { $_ -isnot [bool] } | ForEach-Object { [string]$_ }) -join "`n") }
        }
    }

    AfterAll { $env:Path = $script:SavedPath }

    It 'exit code 0 and a working tool: installed and verified' {
        $script:StandInExit = 0; $script:StandInOutput = 'Successfully installed stand-in-1.0'
        $r = Invoke-Try -Verify { $true }
        $r.Result | Should -BeTrue
        $r.Text | Should -Match 'Stand-in tool installed and verified'
    }

    It 'an already satisfied requirement is reported as already installed, not as a new install' {
        $script:StandInExit = 0; $script:StandInOutput = 'Requirement already satisfied: stand-in in c:\somewhere'
        $r = Invoke-Try -Verify { $true }
        $r.Result | Should -BeTrue
        $r.Text | Should -Match 'was already installed; nothing changed'
        $r.Text | Should -Not -Match 'installed and verified'
    }

    It 'exit code 0 but the tool does not work: not a success, and it says so' {
        $script:StandInExit = 0; $script:StandInOutput = 'Requirement already satisfied: stand-in'
        $r = Invoke-Try -Verify { $false }
        $r.Result | Should -BeFalse
        $r.Text | Should -Match 'finished \(exit code 0\), but Stand-in tool does not work yet'
        $r.Text | Should -Not -Match 'installed successfully|installed and verified'
    }

    It 'a failing install command is not a success even when the command is on PATH' {
        $script:StandInExit = 1; $script:StandInOutput = 'ERROR: could not install'
        $r = Invoke-Try -Verify { $true } -CheckCmd 'Get-Date'
        $r.Result | Should -BeFalse
        $r.Text | Should -Match 'did not succeed \(exit code: 1\)'
        $r = Invoke-Try -Verify $null -CheckCmd 'Get-Date'
        $r.Result | Should -BeFalse -Because 'presence on PATH alone used to count as an install'
    }

    It 'without a check, exit code 0 and the command present is still a success' {
        $script:StandInExit = 0; $script:StandInOutput = 'done'
        (Invoke-Try -Verify $null -CheckCmd 'Get-Date').Result | Should -BeTrue
    }

    It 'the Fabric CLI install is verified by running it, and a failure is listed at the end' {
        $script:Raw | Should -Match ([regex]::Escape("-Verify { Test-CliResilient -Name 'fab' -Retries 2 -VersionPattern '(?im)^\s*fab version' }"))
        $script:Raw | Should -Match ([regex]::Escape("if (-not `$fabInstalled) { Add-SetupWarning 'Fabric CLI (fab)"))
    }
}

Describe 'Tool inventory: a broken fab is not called a different product' {

    It 'Get-CliVersionProbe keeps stderr and the exit code' {
        function Invoke-BrokenCli { Write-Error 'ModuleNotFoundError: No module named ''fabric_cli'''; $global:LASTEXITCODE = 1 }
        $p = Get-CliVersionProbe -Exe 'Invoke-BrokenCli'
        $p.ExitCode | Should -Be 1
        $p.Problem | Should -Match "ModuleNotFoundError: No module named 'fabric_cli'"
        function Invoke-NoStart { throw 'The application was unable to start correctly' }
        $q = Get-CliVersionProbe -Exe 'Invoke-NoStart'
        $q.ExitCode | Should -Be -1
        $q.Problem | Should -Match 'unable to start'
        function Invoke-GoodCli { $global:LASTEXITCODE = 0; 'fab version 1.7.0' }
        (Get-CliVersionProbe -Exe 'Invoke-GoodCli').Lines | Should -Contain 'fab version 1.7.0'
    }

    It 'the inventory separates a working fab, a different product and a broken fab' {
        $block = [regex]::Match($script:Raw, "(?s)\`$fabHit = Resolve-ToolCommand -Aliases @\('fab'\).*?-Reason 'not installed'").Value
        $block | Should -Not -BeNullOrEmpty
        $block | Should -Match ([regex]::Escape("(Fabric|Paramiko|Invoke)\s+\d"))
        $block | Should -Match ([regex]::Escape("a different 'fab' command is on PATH"))
        $block | Should -Match ([regex]::Escape("but 'fab --version' did not work (exit code `$(`$fabProbe.ExitCode)): `$(`$fabProbe.Problem)"))
    }

    It 'Step 2 starts git once instead of trusting PATH, and checks the workspace repository' {
        $step2 = [regex]::Match($script:Raw, '(?s)Show-Step 2 \$totalSteps.*?# VS Code').Value
        $step2 | Should -Match ([regex]::Escape("`$gitStartProbe = Get-CliVersionProbe -Exe 'git'"))
        $step2 | Should -Match ([regex]::Escape("git: found, but 'git --version' did not run"))
        $step2 | Should -Match ([regex]::Escape('$rootGitProbe = Get-GitProbe $rootPath'))
    }
}

Describe 'PBIVIZ: a Git that cannot start or read is not an uninitialised folder' {

    BeforeAll {
        # A file that is not a program: Process.Start fails exactly like a Git that cannot start.
        $script:FakeGit = Join-Path (New-HDir 'fake git') 'git.exe'
        [IO.File]::WriteAllText($script:FakeGit, 'not a program', $script:Utf8)
    }
    AfterEach { $script:PbivizGitExe = $null }

    It 'initialisation says Git could not be started, not that it was not found' {
        $script:PbivizGitExe = $script:FakeGit
        $d = New-HDir 'viz'
        $r = Initialize-PbivizRepository -Root $d -FolderWasEmpty
        $r.Status | Should -Be 'SKIPPED'
        $r.InitStatus | Should -Match '^skipped: git could not be started \('
        $r.InitStatus | Should -Not -Match 'not found'
        ($r.Messages -join ' ') | Should -Match 'nothing in it was changed'
        @(Get-ChildItem -LiteralPath $d -Force).Count | Should -Be 0
    }

    It 'the status line keeps "NOT initialized" for a folder without .git and says Git could not read an existing .git' {
        $script:PbivizGitExe = $script:FakeGit
        $plain = New-HDir 'viz plain'
        Get-PbivizStatusLine -Root $plain -RelativePath 'plain' -InitStatus 'skipped: synced path' | Should -Match 'local Git NOT initialized - PBIVIZ work is not versioned \(skipped: synced path\)'
        $repo = New-HDir 'viz repo' -WithGit
        $line = Get-PbivizStatusLine -Root $repo -RelativePath 'repo' -InitStatus 'skipped: git could not be started (x)'
        $line | Should -Match '^repo \| a \.git is present but Git could not read it \('
        $line | Should -Match 'its history was not changed'
        $line | Should -Not -Match 'NOT initialized'
    }

    It 'the mapping keeps the last recorded git block when Git could not read the repository' {
        $existing = [pscustomobject]@{ initStatus = 'reused existing repository'; branch = 'PBVIZ_Team_Dev'; commits = 12; baselineCommit = ('1' * 40); checkedAt = '2026-01-01T00:00:00Z'; lastCheck = 'stale' }
        $head = [pscustomobject]@{ isRepoRoot = $false; gitIsDir = $true; gitIsFile = $false; branch = $null; commitCount = 0; gitProblem = 'fatal: detected dubious ownership in repository' }
        $b = Get-PbivizMapGitBlock -Existing $existing -HeadState $head -InitStatus 'stopped: .git folder is not a usable repository root' -BaselineCommit $null -CheckedAt '2026-02-02T00:00:00Z'
        $b['branch'] | Should -Be 'PBVIZ_Team_Dev'
        $b['commits'] | Should -Be 12
        $b['initStatus'] | Should -Be 'reused existing repository'
        $b['baselineCommit'] | Should -Be ('1' * 40)
        $b['checkedAt'] | Should -Be '2026-01-01T00:00:00Z' -Because 'the recorded values keep their own date'
        $b['lastCheck'].checkedAt | Should -Be '2026-02-02T00:00:00Z'
        $b['lastCheck'].reason | Should -Match 'dubious ownership'
        $b['lastCheck'].result | Should -Match '^not confirmed'
    }

    It 'without a previous record, unknown values are null, never 0' {
        $head = [pscustomobject]@{ isRepoRoot = $false; gitIsDir = $false; gitIsFile = $false; branch = $null; commitCount = 0; gitProblem = $null }
        $b = Get-PbivizMapGitBlock -Existing $null -HeadState $head -InitStatus 'skipped: git could not be started (git exit code -1)' -BaselineCommit $null -CheckedAt 'now'
        $b.Contains('commits') | Should -BeTrue
        $b['commits'] | Should -BeNullOrEmpty
        $b['lastCheck'].reason | Should -Match 'could not be started'
    }

    It 'a readable repository and a folder without .git are written as before' {
        $ok = [pscustomobject]@{ isRepoRoot = $true; gitIsDir = $true; gitIsFile = $false; branch = 'main'; commitCount = 3; gitProblem = $null }
        $b = Get-PbivizMapGitBlock -Existing ([pscustomobject]@{ baselineCommit = ('2' * 40) }) -HeadState $ok -InitStatus 'reused existing repository' -BaselineCommit $null -CheckedAt 'now'
        $b['branch'] | Should -Be 'main'; $b['commits'] | Should -Be 3; $b['baselineCommit'] | Should -Be ('2' * 40)
        $b.Contains('lastCheck') | Should -BeFalse
        $none = [pscustomobject]@{ isRepoRoot = $false; gitIsDir = $false; gitIsFile = $false; branch = $null; commitCount = 0; gitProblem = $null }
        $c = Get-PbivizMapGitBlock -Existing $null -HeadState $none -InitStatus 'skipped: synced path' -BaselineCommit $null -CheckedAt 'now'
        $c['commits'] | Should -Be 0
        $c.Contains('lastCheck') | Should -BeFalse
    }

    It 'the installer writes the mapping through that function and the existing-map merge is unchanged' {
        $script:Raw | Should -Match ([regex]::Escape("`$pbivizMap['git'] = Get-PbivizMapGitBlock -Existing"))
        $script:Raw | Should -Match ([regex]::Escape('foreach ($prop in $pbivizExistingMap.PSObject.Properties) { $pbivizMap[$prop.Name] = $prop.Value }'))
    }
}

Describe 'The end of the run says what was not done' {

    BeforeAll {
        $script:Step9 = [regex]::Match($script:Raw, '(?s)Show-Step 9 \$totalSteps "Finishing Up".*?Press Enter to open VS Code').Value
    }

    It 'Add-SetupWarning collects each distinct warning once' {
        $script:SetupWarnings.Clear()
        Add-SetupWarning 'a'; Add-SetupWarning 'a'; Add-SetupWarning ''; Add-SetupWarning 'b'
        @($script:SetupWarnings) | Should -Be @('a', 'b')
    }

    It '"Setup complete!" is printed only when nothing was skipped' {
        $script:Step9 | Should -Match '(?s)if \(\$setupWarningCount -eq 0\) \{\s*Write-Host "  Setup complete! v\$productVersion" -ForegroundColor Green\s*\} else \{\s*Write-Host "  Setup finished with \$setupWarningCount warning\(s\)\. v\$productVersion"'
        @([regex]::Matches($script:Raw, 'Setup complete!')).Count | Should -Be 1
        $script:Step9 | Should -Match ([regex]::Escape('foreach ($setupWarning in $script:SetupWarnings) { Write-Host "    - $setupWarning"'))
    }

    It 'a refused workspace repository gives Git''s reason and is listed' {
        $script:Step9 | Should -Match ([regex]::Escape('$rootGitProbe = Get-GitProbe $rootPath'))
        $script:Step9 | Should -Match ([regex]::Escape("if (`$rootGitProbe.State -eq 'ok') { 'Git opened the repository but did not confirm a working tree' } else { Format-GitProbe `$rootGitProbe }"))
        $script:Step9 | Should -Match ([regex]::Escape('Add-SetupWarning "No setup commit was made: $rootGitReason."'))
        $script:Step9 | Should -Match ([regex]::Escape("Add-SetupWarning 'No setup commit was made: git user.name / user.email are not configured.'"))
    }

    It 'Step 2 says "All prerequisites OK." only without warnings' {
        $script:Raw | Should -Match '(?s)if \(\$warnings\.Count -gt 0\) \{.*?Required prerequisites are present; \$\(\$warnings\.Count\) warning\(s\) above\..*?\} else \{\s*Write-Host "`n  All prerequisites OK\." -ForegroundColor Green\s*\}'
    }

    It 'a blocked catalogue, a failed optional install and a PBIVIZ repository Git could not read are listed' {
        $script:Raw | Should -Match ([regex]::Escape('Add-SetupWarning "${catalogName}: skills catalog not checked or refreshed ($($catalogEntry.reason)).'))
        $script:Raw | Should -Match ([regex]::Escape('Add-SetupWarning "${Name}: you agreed to install it, but the install did not complete."'))
        $script:Raw | Should -Match ([regex]::Escape('Add-SetupWarning "PBIVIZ repository ${pbivizRelativePath}: not checked - '))
    }
}
