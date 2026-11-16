# PBIVIZ.Install.Tests.ps1
# -------------------------------------------------------------------
# Installer side of the optional PBIVIZ (custom visual) development folder:
#   * Step 1 prompt flows, driven through the REAL installer with scripted
#     answers (the run is killed as soon as Step 2 starts, so nothing is
#     installed, cloned or created beyond the scratch workspace);
#   * folder-name validation, the Level 1 repository decision tree, the
#     outer .gitignore rule, the .vscode/mcp.json merge and the status line,
#     exercised as the installer's own functions (extracted by AST, never
#     re-implemented) against throwaway folders under TEMP.
# The developer's global/system Git configuration and OneDrive variables are
# hidden for the duration; every repository is local.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $raw = [IO.File]::ReadAllText($script:Installer)
    $m = [regex]::Match($raw, "(?s)\`$pbivizAlmScript = @'\r?\n(.*?)\r?\n'@")
    $m.Success | Should -BeTrue
    $script:InstallerRaw = $raw

    $script:Root = Join-Path ([IO.Path]::GetTempPath()) ('pbi' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Root | Out-Null
    $helperFile = Join-Path $script:Root 'Pbiviz-Alm.ps1'
    [IO.File]::WriteAllText($helperFile, $m.Groups[1].Value, (New-Object System.Text.UTF8Encoding($false)))
    . $helperFile

    # The installer's own functions, extracted from its AST (single source of truth).
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tokens, [ref]$errors)
    $wanted = @('Write-ManagedFile', 'ConvertFrom-JsonLenient', 'Add-GitIgnoreRules', 'Get-PbivizFolderNameProblem', 'Get-JsoncTokens', 'Add-McpServerText', 'Merge-McpJson')
    $defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $false))
    @($defs | ForEach-Object { $_.Name } | Sort-Object -Unique).Count | Should -Be $wanted.Count
    foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

    $script:SavedEnv = @{}
    $script:EnvNames = @('GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer')
    foreach ($n in $script:EnvNames) { $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
    $env:GIT_AUTHOR_NAME = 'test'; $env:GIT_AUTHOR_EMAIL = 't@example.invalid'
    $env:GIT_COMMITTER_NAME = 'test'; $env:GIT_COMMITTER_EMAIL = 't@example.invalid'
    $script:EmptyGitConfig = Join-Path $script:Root 'empty.gitconfig'
    [IO.File]::WriteAllText($script:EmptyGitConfig, '')
    $env:GIT_CONFIG_GLOBAL = $script:EmptyGitConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'
    foreach ($n in 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer') { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    $script:Counter = 0

    function New-TDir {
        param([string]$Prefix = 'd')
        $script:Counter++
        $d = Join-Path $script:Root ("$Prefix$($script:Counter)")
        New-Item -ItemType Directory -Path $d | Out-Null
        return $d
    }
    function TGit {
        param([string]$Dir, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
        $o = & git -C $Dir @Rest 2>$null
        if ($LASTEXITCODE -ne 0) { throw "git $($Rest -join ' ') failed in $Dir (exit $LASTEXITCODE)" }
        return ((@($o) | ForEach-Object { "$_" }) -join "`n").Trim()
    }
    function Get-TBytes { param([string]$Path) if (Test-Path -LiteralPath $Path) { return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) } return $null }

    # Runs the REAL installer through Step 1 against an existing scratch workspace:
    # option 1, the workspace path, zero Fabric workspaces, then $Pbiviz answers,
    # then "no business repositories". Killed as soon as Step 2 starts.
    function Invoke-Step1Pbiviz {
        param([string]$Workspace, [string[]]$Pbiviz, [int]$TimeoutSec = 120)
        $answers = @('1', $Workspace, '0') + $Pbiviz + @('n', '')
        $answersFile = Join-Path $script:Root ([guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($answersFile, (($answers -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        $outFile = "$answersFile.out"
        $cmd = 'set "USERPROFILE={2}"&& set FABRIC_AGENTIC_SKIP_VSCODE_LAUNCH=1&& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" < "{1}" > "{3}" 2>&1' -f $script:Installer, $answersFile, $script:Root, $outFile
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -PassThru -WindowStyle Hidden
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            $text = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
            if ($text -match 'STEP 2 of 9|Press Enter to close|^ERROR' -or $p.HasExited) { break }
        }
        if (-not $p.HasExited) { & taskkill.exe /PID $p.Id /T /F 2>$null | Out-Null }
        Start-Sleep -Milliseconds 300
        return [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
    }
    function Write-TMap {
        param([string]$Workspace, [string]$Json)
        $dir = Join-Path $Workspace '.github\agent-docs\local'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'pbiviz-workspace.json'
        [IO.File]::WriteAllText($path, $Json, (New-Object System.Text.UTF8Encoding($false)))
        return $path
    }
}

AfterAll {
    foreach ($n in $script:EnvNames) {
        if ($null -eq $script:SavedEnv[$n]) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue } else { Set-Item "Env:$n" $script:SavedEnv[$n] }
    }
    if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
        Get-ChildItem -LiteralPath $script:Root -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Step 1: PBIVIZ prompt (real installer, scripted answers)' {

    # Note: with redirected stdin, Read-Host prompt texts are not echoed to the transcript;
    # assertions use the installer's Write-Host lines and the static prompt text instead.
    It 'declining (or EOF) creates nothing and continues to Step 2' {
        $ws = New-TDir 'ws'
        $out = Invoke-Step1Pbiviz -Workspace $ws -Pbiviz @('n')
        $out | Should -Match 'PBIVIZ DEVELOPMENT \(OPTIONAL\)'
        $script:InstallerRaw | Should -Match ([regex]::Escape("'  Create a dedicated folder for Power BI custom visual development? (y/N)'"))
        $out | Should -Match 'No PBIVIZ folder'
        $out | Should -Match 'STEP 2 of 9'
        Test-Path -LiteralPath (Join-Path $ws '0 - PBIVIZ Developing Environment') | Should -BeFalse
    }

    It 'accepting with an empty name uses the default folder name (created later, in Step 3)' {
        $ws = New-TDir 'ws'
        $out = Invoke-Step1Pbiviz -Workspace $ws -Pbiviz @('y', '')
        $out | Should -Match ([regex]::Escape("Will create: $(Join-Path $ws '0 - PBIVIZ Developing Environment')"))
        $out | Should -Match 'STEP 2 of 9'
        Test-Path -LiteralPath (Join-Path $ws '0 - PBIVIZ Developing Environment') | Should -BeFalse -Because 'Step 1 only collects the decision'
    }

    It 'accepts a custom name and reports an existing folder as reused, contents untouched' {
        $ws = New-TDir 'ws'
        New-Item -ItemType Directory -Path (Join-Path $ws 'My Visuals') | Out-Null
        [IO.File]::WriteAllText((Join-Path $ws 'My Visuals\keep.txt'), 'x')
        $out = Invoke-Step1Pbiviz -Workspace $ws -Pbiviz @('y', 'My Visuals')
        $out | Should -Match 'Folder exists; it will be reused and its contents left unchanged'
        [IO.File]::ReadAllText((Join-Path $ws 'My Visuals\keep.txt')) | Should -Be 'x'
    }

    It 'rejects paths, traversal, reserved and device names, then accepts a valid one' {
        $ws = New-TDir 'ws'
        $out = Invoke-Step1Pbiviz -Workspace $ws -Pbiviz @('y', '..\escape', 'a/b', 'scripts', 'CON', 'Good Name')
        $out | Should -Match 'not a path'
        $out | Should -Match 'already used by the workspace'
        $out | Should -Match 'reserved Windows device name'
        $out | Should -Match ([regex]::Escape("Will create: $(Join-Path $ws 'Good Name')"))
    }

    It 'gives up after five invalid names without configuring anything' {
        $ws = New-TDir 'ws'
        $out = Invoke-Step1Pbiviz -Workspace $ws -Pbiviz @('y', '..', '..', '..', '..', '..')
        $out | Should -Match 'No valid folder name given'
        $out | Should -Match 'STEP 2 of 9'
    }

    It 're-asks when the mapping records enabled:false' {
        $ws = New-TDir 'ws'
        Write-TMap $ws '{ "schemaVersion": 1, "enabled": false, "relativePath": null }' | Out-Null
        $out = Invoke-Step1Pbiviz -Workspace $ws -Pbiviz @('n')
        $out | Should -Match ([regex]::Escape('PBIVIZ folder: not configured.'))
        $out | Should -Match 'No PBIVIZ folder'
    }

    It 'keeps an enabled folder that exists without asking' {
        $ws = New-TDir 'ws'
        New-Item -ItemType Directory -Path (Join-Path $ws 'Viz') | Out-Null
        Write-TMap $ws '{ "schemaVersion": 1, "enabled": true, "relativePath": "Viz" }' | Out-Null
        $out = Invoke-Step1Pbiviz -Workspace $ws -Pbiviz @()
        $out | Should -Match ([regex]::Escape('PBIVIZ folder: Viz (kept)'))
        $out | Should -Not -Match 'Create a dedicated folder'
    }

    It 'offers Recreate / Choose / Disable when the enabled folder is missing (default Recreate)' {
        $ws = New-TDir 'ws'
        Write-TMap $ws '{ "schemaVersion": 1, "enabled": true, "relativePath": "Gone" }' | Out-Null
        $out = Invoke-Step1Pbiviz -Workspace $ws -Pbiviz @('')
        $out | Should -Match ([regex]::Escape("PBIVIZ folder 'Gone' not found."))
        $script:InstallerRaw | Should -Match ([regex]::Escape("'  [R]ecreate / [C]hoose another name / [D]isable (default: R)'"))
        $out | Should -Match ([regex]::Escape("Will recreate: $(Join-Path $ws 'Gone')"))
        $ws2 = New-TDir 'ws'
        Write-TMap $ws2 '{ "schemaVersion": 1, "enabled": true, "relativePath": "Gone" }' | Out-Null
        $out2 = Invoke-Step1Pbiviz -Workspace $ws2 -Pbiviz @('D')
        $out2 | Should -Match 'PBIVIZ development disabled'
    }

    It 'preserves an unreadable mapping and skips PBIVIZ setup' {
        $ws = New-TDir 'ws'
        $map = Write-TMap $ws '{ this is not json'
        $before = Get-TBytes $map
        $out = Invoke-Step1Pbiviz -Workspace $ws -Pbiviz @()
        $out | Should -Match 'unreadable or invalid; it is preserved'
        Get-TBytes $map | Should -Be $before
    }
}

Describe 'Folder name validation' {

    It 'rejects <Name>' -TestCases @(
        @{ Name = '' }, @{ Name = '   ' }, @{ Name = '..' }, @{ Name = '..\x' }, @{ Name = 'a\b' }, @{ Name = 'a/b' }, @{ Name = 'C:\x' }, @{ Name = '\\srv\x' },
        @{ Name = '.github' }, @{ Name = '.GIT' }, @{ Name = 'skills-for-fabric' }, @{ Name = 'Source-Control-Repositories' }, @{ Name = 'scripts' },
        @{ Name = 'CON' }, @{ Name = 'nul.txt' }, @{ Name = 'LPT1' }, @{ Name = 'name.' }, @{ Name = '-dash' }, @{ Name = 'a*b' }, @{ Name = 'a:b' }, @{ Name = ('x' * 81) }
    ) {
        param($Name)
        Get-PbivizFolderNameProblem -Name $Name -Reserved @('.github', '.vscode', '.git', 'scripts', 'skills-for-fabric', 'power-bi-agentic-development', 'source-control-repositories') | Should -Not -BeNullOrEmpty
    }

    It 'accepts <Name>' -TestCases @(@{ Name = '0 - PBIVIZ Developing Environment' }, @{ Name = 'Visuals' }, @{ Name = 'Team (BI) visuals_v2.0' }, @{ Name = 'Visualisierung' }) {
        param($Name)
        Get-PbivizFolderNameProblem -Name $Name -Reserved @('.github') | Should -BeNullOrEmpty
    }

    It 'rejects a Fabric workspace name entered in the same run' {
        Get-PbivizFolderNameProblem -Name 'sales dev' -Reserved @('.github', 'Sales DEV') | Should -Match 'already used'
    }
}

Describe 'Level 1: repository initialisation decision tree' {

    It 'initialises an empty folder on main with a baseline commit (trailer) and core.longpaths' {
        $d = New-TDir 'p'
        $r = Initialize-PbivizRepository -Root $d -FolderWasEmpty
        $r.Status | Should -Be 'INITIALIZED'
        TGit $d symbolic-ref --short HEAD | Should -Be 'main'
        TGit $d rev-list --count HEAD | Should -Be '1'
        TGit $d log -1 --format=%B | Should -Match 'Fabric-Agentic-Installer: pbiviz-baseline'
        TGit $d config core.longpaths | Should -Be 'true'
        TGit $d ls-files | Should -Be ".gitattributes`n.gitignore"
        $r.BaselineCommit | Should -Be (TGit $d rev-parse HEAD)
    }

    It 'O1: a folder that already had files gets NO baseline commit and its files stay untracked' {
        $d = New-TDir 'p'
        [IO.File]::WriteAllText((Join-Path $d 'existing.txt'), 'mine')
        $r = Initialize-PbivizRepository -Root $d
        $r.Status | Should -Be 'INITIALIZED'
        $r.InitStatus | Should -Match 'no restore point yet'
        (& git -C $d rev-parse -q --verify HEAD 2>$null) | Should -BeNullOrEmpty
        TGit $d ls-files | Should -BeNullOrEmpty
        [IO.File]::ReadAllText((Join-Path $d 'existing.txt')) | Should -Be 'mine'
    }

    It 'O1: without a Git identity the repository is initialised but nothing is committed' {
        $d = New-TDir 'p'
        $saved = @{}; foreach ($n in 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL') { $saved[$n] = [Environment]::GetEnvironmentVariable($n); Remove-Item "Env:$n" }
        try { $r = Initialize-PbivizRepository -Root $d -FolderWasEmpty }
        finally { foreach ($n in $saved.Keys) { Set-Item "Env:$n" $saved[$n] } }
        $r.Status | Should -Be 'INITIALIZED'
        $r.InitStatus | Should -Match 'user.name/user.email not configured'
        (& git -C $d rev-parse -q --verify HEAD 2>$null) | Should -BeNullOrEmpty
    }

    It 'O1: a rerun reuses the repository and never commits again' {
        $d = New-TDir 'p'
        Initialize-PbivizRepository -Root $d -FolderWasEmpty | Out-Null
        $head = TGit $d rev-parse HEAD
        [IO.File]::WriteAllText((Join-Path $d 'work.txt'), 'wip')
        $r = Initialize-PbivizRepository -Root $d -FolderWasEmpty
        $r.Status | Should -Be 'REUSED'
        TGit $d rev-parse HEAD | Should -Be $head
        TGit $d rev-list --count HEAD | Should -Be '1'
    }

    It 'skips below the Git floor without touching the folder' {
        $d = New-TDir 'p'
        $r = Initialize-PbivizRepository -Root $d -FolderWasEmpty -GitVersionText 'git version 2.20.1.windows.1'
        $r.Status | Should -Be 'SKIPPED'
        $r.InitStatus | Should -Match '2\.20\.1'
        Test-Path -LiteralPath (Join-Path $d '.git') | Should -BeFalse
    }

    It 'reports a failure honestly instead of throwing (the installer continues)' {
        $r = Initialize-PbivizRepository -Root (Join-Path $script:Root 'does-not-exist') -FolderWasEmpty
        $r.Status | Should -Be 'FAILED'
        $r.InitStatus | Should -Match '^failed: '
        $script:InstallerRaw | Should -Match ([regex]::Escape("if (`$pbivizInit.Status -in @('STOPPED', 'FAILED'))"))
    }

    It 'stops on a nested repository, a .git file and an unusable .git folder' {
        $n1 = New-TDir 'p'; New-Item -ItemType Directory -Path (Join-Path $n1 'Visual') | Out-Null; TGit (Join-Path $n1 'Visual') init -q | Out-Null
        (Initialize-PbivizRepository -Root $n1 -FolderWasEmpty).InitStatus | Should -Match 'nested repositories'
        Test-Path -LiteralPath (Join-Path $n1 '.git') | Should -BeFalse
        $n2 = New-TDir 'p'; [IO.File]::WriteAllText((Join-Path $n2 '.git'), 'gitdir: C:/elsewhere/.git/worktrees/x')
        (Initialize-PbivizRepository -Root $n2 -FolderWasEmpty).Status | Should -Be 'STOPPED'
        [IO.File]::ReadAllText((Join-Path $n2 '.git')) | Should -Match 'gitdir'
        $n3 = New-TDir 'p'; New-Item -ItemType Directory -Path (Join-Path $n3 '.git') | Out-Null
        (Initialize-PbivizRepository -Root $n3 -FolderWasEmpty).Status | Should -Be 'STOPPED'
        @(Get-ChildItem -LiteralPath (Join-Path $n3 '.git') -Force).Count | Should -Be 0
    }

    It 'finds nested repositories at any depth and .git files, and skips node_modules' {
        $d = New-TDir 'p'
        $deep = Join-Path $d 'a\b\c\d\e\f\Visual'
        New-Item -ItemType Directory -Path $deep -Force | Out-Null
        TGit $deep init -q | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $d 'x\y\z') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'x\y\z\.git'), 'gitdir: C:/elsewhere/.git/worktrees/z')
        New-Item -ItemType Directory -Path (Join-Path $d 'Bar\node_modules\dep\.git') -Force | Out-Null
        $scan = Get-PbivizNestedRepos -Root $d
        $scan.Complete | Should -BeTrue -Because ($scan.Issues -join '; ')
        @($scan.Repos) | Should -Contain 'a\b\c\d\e\f\Visual\.git' -Because 'depth 7 is beyond the old limit of 3'
        @($scan.Repos) | Should -Contain 'x\y\z\.git' -Because 'a .git FILE (worktree or submodule pointer) is a nested repository too'
        @($scan.Repos | Where-Object { $_ -like '*node_modules*' }).Count | Should -Be 0
        $r = Initialize-PbivizRepository -Root $d -FolderWasEmpty
        $r.Status | Should -Be 'STOPPED'
        $r.InitStatus | Should -Match 'nested repositories found'
        Test-Path -LiteralPath (Join-Path $d '.git') | Should -BeFalse
    }

    It 'fails closed when the nested-repository scan is incomplete (<Case>)' -TestCases @(@{ Case = 'junction' }, @{ Case = 'unreadable folder' }) {
        $d = New-TDir 'p'
        $target = New-TDir 't'
        TGit $target init -q | Out-Null
        $link = Join-Path $d 'linked'
        $locked = Join-Path $d 'locked'
        $rule = $null
        if ($Case -eq 'junction') { & cmd.exe /c "mklink /J `"$link`" `"$target`"" | Out-Null; Test-Path -LiteralPath $link | Should -BeTrue }
        else {
            New-Item -ItemType Directory -Path (Join-Path $locked 'inner\.git') -Force | Out-Null
            $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, [System.Security.AccessControl.FileSystemRights]::ListDirectory, [System.Security.AccessControl.AccessControlType]::Deny)
            $acl = Get-Acl -LiteralPath $locked; $acl.AddAccessRule($rule); Set-Acl -LiteralPath $locked -AclObject $acl
        }
        try {
            $scan = Get-PbivizNestedRepos -Root $d
            $scan.Complete | Should -BeFalse
            @($scan.Repos).Count | Should -Be 0 -Because 'nothing behind the link or the locked folder was read'
            ($scan.Issues -join ' ') | Should -Match $(if ($Case -eq 'junction') { "not followed: 'linked'" } else { "cannot read 'locked'" })
            $r = Initialize-PbivizRepository -Root $d -FolderWasEmpty
            $r.Status | Should -Be 'STOPPED'
            $r.InitStatus | Should -Match 'nested-repository scan incomplete'
            Test-Path -LiteralPath (Join-Path $d '.git') | Should -BeFalse
        } finally {
            if ($Case -eq 'junction') { [IO.Directory]::Delete($link) }
            else { $acl = Get-Acl -LiteralPath $locked; [void]$acl.RemoveAccessRule($rule); Set-Acl -LiteralPath $locked -AclObject $acl }
        }
    }

    It 'stops when the outer workspace repository already tracks files in the folder' {
        $outer = New-TDir 'o'
        TGit $outer init -q -b main | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $outer 'Viz Folder') | Out-Null
        [IO.File]::WriteAllText((Join-Path $outer 'Viz Folder\a.txt'), 'a')
        TGit $outer add -A | Out-Null
        TGit $outer commit -q -m one | Out-Null
        $r = Initialize-PbivizRepository -Root (Join-Path $outer 'Viz Folder') -OuterRoot $outer
        $r.Status | Should -Be 'STOPPED'
        $r.InitStatus | Should -Match 'outer workspace repository tracks'
        Test-Path -LiteralPath (Join-Path $outer 'Viz Folder\.git') | Should -BeFalse
    }

    It 'O3: inside a OneDrive-synced path it is skipped unless explicitly allowed' {
        $base = New-TDir 'od'
        $d = Join-Path $base 'Visuals'; New-Item -ItemType Directory -Path $d | Out-Null
        $env:OneDriveCommercial = $base
        try {
            $r = Initialize-PbivizRepository -Root $d -FolderWasEmpty
            $r.Status | Should -Be 'SKIPPED'
            $r.InitStatus | Should -Match 'synced'
            Test-Path -LiteralPath (Join-Path $d '.git') | Should -BeFalse
            (Initialize-PbivizRepository -Root $d -FolderWasEmpty -AllowSyncedPath).Status | Should -Be 'INITIALIZED'
        } finally { Remove-Item Env:OneDriveCommercial -ErrorAction SilentlyContinue }
    }

    It 'the installer asks before initialising in a synced path, default No' {
        $script:InstallerRaw | Should -Match ([regex]::Escape("Read-Host '  Initialize Git here anyway? (y/N)'"))
        $script:InstallerRaw | Should -Match ([regex]::Escape("`$allowSynced = (`$syncAns -match '^\s*(y|yes)\s*$')"))
    }
}

Describe 'Outer repository, mapping and MCP configuration' {

    It 'adds the outer ignore rule once and Git ignores the PBIVIZ repository' {
        $outer = New-TDir 'o'
        TGit $outer init -q -b main | Out-Null
        $gi = Join-Path $outer '.gitignore'
        Add-GitIgnoreRules -Path $gi -Heading 'PBIVIZ repository' -Rules @('/0 - PBIVIZ Developing Environment/')
        Add-GitIgnoreRules -Path $gi -Heading 'PBIVIZ repository' -Rules @('/0 - PBIVIZ Developing Environment/')
        @([regex]::Matches([IO.File]::ReadAllText($gi), '(?m)^/0 - PBIVIZ Developing Environment/\s*$')).Count | Should -Be 1
        $p = Join-Path $outer '0 - PBIVIZ Developing Environment'
        New-Item -ItemType Directory -Path $p | Out-Null
        [IO.File]::WriteAllText((Join-Path $p 'x.txt'), 'x')
        & git -C $outer check-ignore -q -- '0 - PBIVIZ Developing Environment/x.txt'
        $LASTEXITCODE | Should -Be 0
    }

    It 'adds the outer ignore rule before Step 9 stages the outer repository' {
        $iRule = $script:InstallerRaw.IndexOf("Rules @(""/`$pbivizRelativePath/"")")
        $iStep9 = $script:InstallerRaw.IndexOf('Show-Step 9 $totalSteps')
        $iRule | Should -BeGreaterThan 0
        $iRule | Should -BeLessThan $iStep9
    }

    It 'writes the mapping with Write-ManagedFile (UTF-8, no BOM) and preserves unknown keys' {
        $f = Join-Path (New-TDir 'm') 'map.json'
        Write-ManagedFile -Path $f -Content '{ "a": 1 }'
        $b = [IO.File]::ReadAllBytes($f)
        ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeFalse
        $script:InstallerRaw | Should -Match ([regex]::Escape('foreach ($prop in $pbivizExistingMap.PSObject.Properties) { $pbivizMap[$prop.Name] = $prop.Value }'))
        $script:InstallerRaw | Should -Match ([regex]::Escape('Write-ManagedFile -Path $pbivizMapPath -Content ($pbivizMap | ConvertTo-Json -Depth 10)'))
    }

    It 'creates .vscode/mcp.json with the Microsoft Learn server and is idempotent' {
        $f = Join-Path (New-TDir 'mcp') '.vscode\mcp.json'
        $r1 = Merge-McpJson -Path $f
        $r1.Changed | Should -BeTrue
        $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json
        $j.servers.microsoftDocs.type | Should -Be 'http'
        $j.servers.microsoftDocs.url | Should -Be 'https://learn.microsoft.com/api/mcp'
        $bytes = Get-TBytes $f
        (Merge-McpJson -Path $f).Changed | Should -BeFalse
        Get-TBytes $f | Should -Be $bytes
    }

    It 'preserves existing servers and inputs when merging' {
        $f = Join-Path (New-TDir 'mcp') 'mcp.json'
        [IO.File]::WriteAllText($f, '{ "inputs": [ { "id": "tok", "type": "promptString" } ], "servers": { "mine": { "type": "stdio", "command": "node", "args": ["x.js"] } } }')
        (Merge-McpJson -Path $f).Changed | Should -BeTrue
        $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json
        $j.servers.mine.command | Should -Be 'node'
        @($j.servers.mine.args) | Should -Be @('x.js')
        @($j.inputs).Count | Should -Be 1
        $j.inputs[0].id | Should -Be 'tok'
        $j.servers.microsoftDocs.url | Should -Be 'https://learn.microsoft.com/api/mcp'
    }

    It 'recognises the Learn server under another key or URL spelling and changes nothing' {
        $f = Join-Path (New-TDir 'mcp') 'mcp.json'
        [IO.File]::WriteAllText($f, '{ "servers": { "microsoft.docs.mcp": { "type": "http", "url": "https://Learn.Microsoft.com/api/mcp/" } } }')
        $before = Get-TBytes $f
        $r = Merge-McpJson -Path $f
        $r.Changed | Should -BeFalse
        $r.Status | Should -Match 'already configured'
        Get-TBytes $f | Should -Be $before
    }

    It 'leaves a malformed file and a conflicting microsoftDocs key untouched' {
        $f = Join-Path (New-TDir 'mcp') 'mcp.json'
        [IO.File]::WriteAllText($f, '{ "servers": { broken')
        $before = Get-TBytes $f
        (Merge-McpJson -Path $f).Status | Should -Match 'malformed'
        Get-TBytes $f | Should -Be $before
        $g = Join-Path (New-TDir 'mcp') 'mcp.json'
        [IO.File]::WriteAllText($g, '{ "servers": { "microsoftDocs": { "type": "http", "url": "https://example.invalid/mcp" } } }')
        $before2 = Get-TBytes $g
        (Merge-McpJson -Path $g).Changed | Should -BeFalse
        Get-TBytes $g | Should -Be $before2
    }

    It 'merges a JSONC file by inserting text: comments, formatting and every other byte survive' {
        $f = Join-Path (New-TDir 'mcp') 'mcp.json'
        $orig = "{`n  // my servers`n  ""servers"": { ""mine"": { ""type"": ""stdio"", ""command"": ""x"" }, },`n  /* inputs follow */`n  ""inputs"": []`n}"
        [IO.File]::WriteAllText($f, $orig)
        $r = Merge-McpJson -Path $f
        $r.Changed | Should -BeTrue
        $r.Status | Should -Match 'comments and formatting preserved'
        $new = [IO.File]::ReadAllText($f)
        $new.Replace($r.Inserted, '') | Should -BeExactly $orig -Because 'the only change is the inserted entry'
        $j = ConvertFrom-JsonLenient $new
        $j.servers.mine.command | Should -Be 'x'
        $j.servers.microsoftDocs.url | Should -Be 'https://learn.microsoft.com/api/mcp'
        (Merge-McpJson -Path $f).Changed | Should -BeFalse -Because 'a second run finds the server and changes nothing'
    }

    It 'adds a servers block to a JSONC file that has none, keeping CRLF and the BOM' {
        $f = Join-Path (New-TDir 'mcp') 'mcp.json'
        $orig = "{`r`n  // inputs only`r`n  ""inputs"": [ { ""id"": ""tok"" } ]`r`n}`r`n"
        [IO.File]::WriteAllText($f, $orig, (New-Object System.Text.UTF8Encoding($true)))
        $r = Merge-McpJson -Path $f
        $r.Changed | Should -BeTrue -Because $r.Status
        $b = [IO.File]::ReadAllBytes($f)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeTrue
        $new = [IO.File]::ReadAllText($f)
        $new.Replace($r.Inserted, '') | Should -BeExactly $orig
        $new | Should -Not -Match "[^`r]`n" -Because 'CRLF line endings are kept'
        $j = ConvertFrom-JsonLenient $new
        $j.inputs[0].id | Should -Be 'tok'
        $j.servers.microsoftDocs.type | Should -Be 'http'
    }

    It 'leaves a layout it cannot patch verifiably untouched and says how to add the server manually' {
        $f = Join-Path (New-TDir 'mcp') 'mcp.json'
        [IO.File]::WriteAllText($f, '{ "serv\u0065rs": { "a": { "type": "stdio", "command": "x" } } }')
        $before = Get-TBytes $f
        $r = Merge-McpJson -Path $f
        $r.Changed | Should -BeFalse
        $r.Status | Should -Match 'add it manually'
        Get-TBytes $f | Should -Be $before
    }

    It 'never lists the user-owned .vscode/mcp.json as an installer-managed (purgeable) file' {
        $m = [regex]::Match($script:InstallerRaw, '(?s)\$managedConfigs = @\((.*?)\)')
        $m.Groups[1].Value | Should -Not -Match 'mcp\.json'
        $m.Groups[1].Value | Should -Match ([regex]::Escape("'.github\agent-docs\Pbiviz-Alm.ps1'"))
    }
}

Describe 'PBIVIZ status line' {

    It 'reports a missing folder, an uninitialised folder and a Level 1 repository honestly' {
        $base = New-TDir 's'
        Get-PbivizStatusLine -Root (Join-Path $base 'nope') -RelativePath 'nope' | Should -Match 'folder missing'
        $plain = Join-Path $base 'plain'; New-Item -ItemType Directory -Path $plain | Out-Null
        Get-PbivizStatusLine -Root $plain -RelativePath 'plain' -InitStatus 'skipped: synced path' | Should -Match 'local Git NOT initialized - PBIVIZ work is not versioned \(skipped: synced path\)'
        $repo = Join-Path $base 'repo'; New-Item -ItemType Directory -Path $repo | Out-Null
        Initialize-PbivizRepository -Root $repo -FolderWasEmpty | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo 'Bar') | Out-Null
        [IO.File]::WriteAllText((Join-Path $repo 'Bar\pbiviz.json'), '{}')
        $line = Get-PbivizStatusLine -Root $repo -RelativePath 'repo'
        $line | Should -Match '1 visual\(s\)'
        $line | Should -Match 'git: main, 1 commit\(s\), uncommitted changes'
        $line | Should -Match 'Level 1 \(local only - not an off-device backup\)'
        $fresh = Join-Path $base 'fresh'; New-Item -ItemType Directory -Path $fresh | Out-Null
        [IO.File]::WriteAllText((Join-Path $fresh 'f.txt'), 'f')
        Initialize-PbivizRepository -Root $fresh | Out-Null
        Get-PbivizStatusLine -Root $fresh -RelativePath 'fresh' | Should -Match 'no commits yet - make a first commit'
    }
}
