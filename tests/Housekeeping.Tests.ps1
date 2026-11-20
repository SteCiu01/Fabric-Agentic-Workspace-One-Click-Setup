# Housekeeping.Tests.ps1
# -------------------------------------------------------------------
# Agent working files and workspace housekeeping (v0.9.0). Loads the shipped helper from
# its single source (the $agentWorkspaceScript here-string in the installer) and runs it
# against throwaway workspaces under TEMP:
#   - task folders: unique, short, marked; closing removes only named files inside them;
#   - preview: every class (safe, ambiguous, secret-flagged, protected) on a prepared tree,
#     read-only except for its own report, possible secrets by pattern class and never by value;
#   - execute: token-gated, re-checks every file, moves (never deletes), idempotent, undoable;
#   - purge: second token, only files Execute recorded, one by one;
#   - Windows paths with spaces and longer than 260 characters;
#   - the installer side: tree created without touching existing content, ignore rules,
#     agent contracts and the Maintenance Preview/Execute split.
# Each safety rule has a negative control (a tampered plan, a wrong token, a changed file).

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $script:InstallerText = [IO.File]::ReadAllText($script:Installer)
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('fabric_hk_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Base | Out-Null

    $m = [regex]::Match($script:InstallerText, "(?s)\`$agentWorkspaceScript = @'\r?\n(.*?)\r?\n'@")
    $m.Success | Should -BeTrue -Because 'the helper has one source: the $agentWorkspaceScript here-string'
    $script:HelperSource = $m.Groups[1].Value
    $script:Helper = Join-Path $script:Base 'kit\.github\agent-docs\Agent-Workspace.ps1'
    New-Item -ItemType Directory -Path (Split-Path $script:Helper -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($script:Helper, $script:HelperSource, $script:Utf8)
    . $script:Helper
    $script:AwsName = Get-AwsFolderName

    $script:SavedGitEnv = @{}
    foreach ($n in 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL') { $script:SavedGitEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
    $env:GIT_AUTHOR_NAME = 'test'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 'test'; $env:GIT_COMMITTER_EMAIL = 't@t'

    # Fake secrets are assembled at run time so this file holds nothing that looks like one.
    $script:FakeJwtTail = 'c' * 24
    $script:FakeJwt = 'eyJ' + ('a' * 20) + '.eyJ' + ('b' * 20) + '.' + $script:FakeJwtTail
    $script:FakeBearer = 'Z' * 48

    function Set-HkFile([string]$FilePath, [string]$Text = 'x', [int]$AgeDays = 0, [switch]$Unicode) {
        New-Item -ItemType Directory -Path (Split-Path $FilePath -Parent) -Force | Out-Null
        if ($Unicode) { [IO.File]::WriteAllText($FilePath, $Text, [Text.Encoding]::Unicode) } else { [IO.File]::WriteAllText($FilePath, $Text, $script:Utf8) }
        if ($AgeDays -gt 0) { (Get-Item -LiteralPath $FilePath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-$AgeDays) }
    }
    function Set-HkMarker([string]$Task, [hashtable]$Set) {
        $p = Join-Path $Task '.task.json'
        $marker = [IO.File]::ReadAllText($p) | ConvertFrom-Json
        foreach ($k in $Set.Keys) { $marker | Add-Member -NotePropertyName $k -NotePropertyValue $Set[$k] -Force }
        [IO.File]::WriteAllText($p, ($marker | ConvertTo-Json -Depth 5), $script:Utf8)
    }
    function Get-HkOldTicks { return (Get-Date).ToUniversalTime().AddDays(-30).Ticks }
    # Every file under a folder with its size: the before/after evidence of "nothing changed".
    function Get-HkListing([string]$Folder) {
        return @(Get-ChildItem -LiteralPath $Folder -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\\.git\\' } | Sort-Object FullName | ForEach-Object { "$($_.FullName.Substring($Folder.Length))|$($_.Length)" })
    }
    # A workspace with one of everything. The root name has a space on purpose.
    function New-HkScenario([switch]$NoGit) {
        $root = Join-Path $script:Base ('ws ' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $root | Out-Null
        $aws = Join-Path $root $script:AwsName
        $legacy = Join-Path $root 'scripts'
        Set-HkFile (Join-Path $legacy 'tracked.ps1') 'a user script under version control' -AgeDays 40
        if (-not $NoGit) {
            & git -C $root init -q 2>$null
            & git -C $root add -- scripts/tracked.ps1 2>$null
            & git -C $root commit -q -m 'user commit' 2>$null
        }
        Set-HkFile (Join-Path $legacy 'agent013-probe-20250101-101010.ps1') 'old scratch' -AgeDays 40
        Set-HkFile (Join-Path $legacy 'agent013-probe-20250101-101010.out.txt') 'old capture' -AgeDays 40
        Set-HkFile (Join-Path $legacy ('agent014-check-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.ps1')) 'fresh scratch'
        Set-HkFile (Join-Path $legacy 'random.py') 'unknown origin' -AgeDays 40

        $outside = Join-Path $script:Base ('outside ' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        Set-HkFile (Join-Path $outside 'outside.txt') 'must never be listed or moved'

        $t1 = New-AgentTaskFolder -WorkspaceRoot $root -Project 'Sales Report' -Topic 'refresh check'
        Set-HkFile (Join-Path $t1 'a.ps1') 'probe'
        Set-HkFile (Join-Path $t1 'a.out.txt') 'capture'
        Set-HkFile (Join-Path $t1 'sub\b.txt') 'intermediate'
        Set-HkFile (Join-Path $t1 'model-backup\def.tmdl') 'recovery copy'
        Set-HkFile (Join-Path $t1 'token-dump.out.txt') ("header`n" + $script:FakeJwt + "`nfooter")
        Set-HkFile (Join-Path $t1 'capture.txt') ('Authorization: Bearer ' + $script:FakeBearer) -Unicode
        & cmd /c mklink /J (Join-Path $t1 'link') $outside 2>&1 | Out-Null
        Close-AgentTaskFolder -Path $t1 | Out-Null
        Set-HkMarker $t1 @{ closedUtcTicks = (Get-HkOldTicks) }

        $t2 = New-AgentTaskFolder -WorkspaceRoot $root -Project 'Sales Report' -Topic 'recent'
        Set-HkFile (Join-Path $t2 'r.txt') 'closed yesterday'
        Close-AgentTaskFolder -Path $t2 | Out-Null

        $t3 = New-AgentTaskFolder -WorkspaceRoot $root -Project 'Sales Report' -Topic 'running'
        Set-HkFile (Join-Path $t3 'o.txt') 'in use' -AgeDays 40

        Set-HkFile (Join-Path $aws 'Sales Report\tasks\manual-folder\m.txt') 'no marker' -AgeDays 40

        $t5 = New-AgentTaskFolder -WorkspaceRoot $root -Project 'Sales Report' -Topic 'throwaway'
        Set-HkFile (Join-Path $t5 'x.ps1') 'probe'
        Set-HkFile (Join-Path $t5 'deep\y.txt') 'intermediate'
        Close-AgentTaskFolder -Path $t5 | Out-Null
        Set-HkMarker $t5 @{ closedUtcTicks = (Get-HkOldTicks) }

        Set-HkFile (Join-Path $aws 'Sales Report\scripts\tool.ps1') 'reusable' -AgeDays 40
        Set-HkFile (Join-Path $aws 'Sales Report\_archive\old.txt') 'kept on purpose' -AgeDays 40
        Set-HkFile (Join-Path $aws '_shared-tools\shared.ps1') 'reusable' -AgeDays 40
        Set-HkFile (Join-Path $aws 'Sales Report\loose.txt') 'outside a task' -AgeDays 40
        Set-HkFile (Join-Path $aws 'stray.log') 'outside a project' -AgeDays 40
        return [pscustomobject]@{ Root = $root; Aws = $aws; Legacy = $legacy; Outside = $outside; T1 = $t1; T2 = $t2; T3 = $t3; T5 = $t5 }
    }
    function Get-HkClass($Plan, [string]$Suffix) { return [string](@($Plan.entries | Where-Object { $_.path -like "*$Suffix" }) | Select-Object -First 1).class }
    function Read-HkPlan([string]$Root, [string]$PlanId) { return ([IO.File]::ReadAllText((Join-Path $Root "$script:AwsName\_housekeeping\preview-$PlanId.json")) | ConvertFrom-Json) }
}

AfterAll {
    foreach ($n in $script:SavedGitEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $script:SavedGitEnv[$n], 'Process') }
    if ($script:Base -and (Test-Path -LiteralPath $script:Base)) {
        # Junctions first (rmdir removes the link, not its target), then the tree.
        Get-ChildItem -LiteralPath $script:Base -Recurse -Force -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | ForEach-Object { & cmd /c rmdir "$($_.FullName)" 2>&1 | Out-Null }
        & cmd /c rmdir /s /q "\\?\$($script:Base)" 2>&1 | Out-Null
    }
}

Describe 'Task folders (HK-01, HK-03, HK-06)' {

    BeforeAll {
        $script:TaskRoot = Join-Path $script:Base 'task root with spaces'
        New-Item -ItemType Directory -Path $script:TaskRoot | Out-Null
    }

    It 'creates the project tree and a uniquely named, open task folder' {
        $one = New-AgentTaskFolder -WorkspaceRoot $script:TaskRoot -Project 'Finance Model' -Topic 'Measure audit'
        $two = New-AgentTaskFolder -WorkspaceRoot $script:TaskRoot -Project 'Finance Model' -Topic 'Measure audit'
        $one | Should -Not -Be $two -Because 'two sessions on the same topic must never share a folder'
        foreach ($sub in 'scripts', 'tasks', '_archive') { Test-Path -LiteralPath (Join-Path $script:TaskRoot "$script:AwsName\Finance Model\$sub") -PathType Container | Should -BeTrue }
        (Split-Path $one -Leaf) | Should -Match ('^' + (Get-Date -Format 'yyyy-MM-dd') + '-measure-audit-[0-9a-f]{6}$')
        (Split-Path (Split-Path $one -Parent) -Leaf) | Should -Be 'tasks'
        $marker = [IO.File]::ReadAllText((Join-Path $one '.task.json')) | ConvertFrom-Json
        $marker.status | Should -Be 'open'
        $marker.project | Should -Be 'Finance Model'
        [long]$marker.createdUtcTicks | Should -BeGreaterThan 0
    }

    It 'keeps names short and plain, whatever it is given' {
        $task = New-AgentTaskFolder -WorkspaceRoot $script:TaskRoot -Project 'My Report: Sales/2026? <draft> and a very long tail that goes on and on' -Topic 'A topic that is far too long to be a folder name / with: bad chars'
        $rel = $task.Substring($script:TaskRoot.Length + 1)
        $rel | Should -Not -Match '[:*?"<>|]'
        ($rel -split '\\')[1].Length | Should -BeLessOrEqual 40
        (($rel -split '\\')[3] -replace '^\d{4}-\d{2}-\d{2}-', '' -replace '-[0-9a-f]{6}$', '').Length | Should -BeLessOrEqual 24
        $rel.Length | Should -BeLessOrEqual 120 -Because 'the folder must leave room under the Windows path limit'
    }

    It 'refuses a missing project name and reserved names' {
        { New-AgentTaskFolder -WorkspaceRoot $script:TaskRoot -Project '' -Topic 'x' } | Should -Throw
        { New-AgentTaskFolder -WorkspaceRoot $script:TaskRoot -Project '_housekeeping' -Topic 'x' } | Should -Throw
        { New-AgentTaskFolder -WorkspaceRoot $script:TaskRoot -Project '???' -Topic 'x' } | Should -Throw
    }

    It 'closing removes exactly the named files inside the task folder and nothing else' {
        $task = New-AgentTaskFolder -WorkspaceRoot $script:TaskRoot -Project 'Finance Model' -Topic 'close'
        foreach ($f in 'probe 1.ps1', 'probe 1.out.txt', 'probe 2.out.txt', 'evidence.md', 'sub\inner.txt', 'sub\keep.txt') { Set-HkFile (Join-Path $task $f) }
        $neighbour = Join-Path (Split-Path $task -Parent) 'neighbour.txt'
        Set-HkFile $neighbour 'belongs to nobody in particular'
        $r = Close-AgentTaskFolder -Path $task -Remove @('probe 1.ps1', '*.out.txt', 'sub/inner.txt', '..\neighbour.txt', $neighbour, '*\keep.txt', '.task.json', 'missing.txt', 'sub') -Kept 'evidence.md for the reviewer'
        $r.Status | Should -Be 'closed'
        (@($r.Removed) | Sort-Object) | Should -Be @('probe 1.out.txt', 'probe 1.ps1', 'probe 2.out.txt', 'sub\inner.txt')
        @($r.Refused).Count | Should -Be 6 -Because 'a parent path, an absolute path, a folder wildcard, the marker, a missing file and a folder are all refused'
        Test-Path -LiteralPath $neighbour | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $task 'evidence.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $task 'sub\keep.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $task 'sub') -PathType Container | Should -BeTrue -Because 'folders are never removed'
        $marker = [IO.File]::ReadAllText((Join-Path $task '.task.json')) | ConvertFrom-Json
        $marker.status | Should -Be 'closed'
        $marker.kept | Should -Be 'evidence.md for the reviewer'
        [long]$marker.closedUtcTicks | Should -BeGreaterThan 0
    }

    It 'a wildcard with a three-letter extension does not reach longer extensions (deliverables stay)' {
        $task = New-AgentTaskFolder -WorkspaceRoot $script:TaskRoot -Project 'Finance Model' -Topic 'extensions'
        foreach ($f in 'temp.xls', 'report.xlsx', 'run.ps1', 'helper.ps1xml', 'notes [draft].txt', 'notes d.txt') { Set-HkFile (Join-Path $task $f) }
        $r = Close-AgentTaskFolder -Path $task -Remove @('*.xls', '*.ps1', 'notes [draft].txt')
        (@($r.Removed) | Sort-Object) | Should -Be @('notes [draft].txt', 'run.ps1', 'temp.xls')
        Test-Path -LiteralPath (Join-Path $task 'report.xlsx') | Should -BeTrue -Because '.NET GetFiles("*.xls") also returns .xlsx files'
        Test-Path -LiteralPath (Join-Path $task 'helper.ps1xml') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $task 'notes d.txt') | Should -BeTrue -Because 'square brackets in a file name are literal, not a character range'
    }

    It 'refuses to close a folder that is not one of its task folders' {
        $plain = Join-Path $script:TaskRoot 'not a task'
        Set-HkFile (Join-Path $plain 'file.txt')
        { Close-AgentTaskFolder -Path $plain -Remove @('file.txt') } | Should -Throw
        Test-Path -LiteralPath (Join-Path $plain 'file.txt') | Should -BeTrue
        $noMarker = Join-Path $script:TaskRoot "$script:AwsName\Finance Model\tasks\hand-made"
        Set-HkFile (Join-Path $noMarker 'file.txt')
        { Close-AgentTaskFolder -Path $noMarker -Remove @('file.txt') } | Should -Throw
        Test-Path -LiteralPath (Join-Path $noMarker 'file.txt') | Should -BeTrue
    }

    It 'removes a file whose path is longer than 260 characters' {
        $task = New-AgentTaskFolder -WorkspaceRoot $script:TaskRoot -Project 'Finance Model' -Topic 'long'
        $relDir = (1..6 | ForEach-Object { 'a folder with spaces ' + $_ + ' ' + ('n' * 28) }) -join '\'
        $long = '\\?\' + $task + '\' + $relDir
        [void][IO.Directory]::CreateDirectory($long)
        [IO.File]::WriteAllText("$long\long capture.out.txt", 'x')
        ("$task\$relDir\long capture.out.txt").Length | Should -BeGreaterThan 300
        $r = Close-AgentTaskFolder -Path $task -Remove @("$relDir\long capture.out.txt")
        @($r.Removed).Count | Should -Be 1
        [IO.File]::Exists("$long\long capture.out.txt") | Should -BeFalse
    }
}

Describe 'Housekeeping preview classifies and changes nothing (Maintenance Preview)' {

    BeforeAll {
        $script:P = New-HkScenario
        $script:Before = Get-HkListing $script:P.Root
        $script:Preview = Get-AgentWorkspacePreview -WorkspaceRoot $script:P.Root -RetentionDays 14
        $script:Plan = $script:Preview.Plan
        $script:PlanText = [IO.File]::ReadAllText($script:Preview.PlanFile)
        $script:After = Get-HkListing $script:P.Root
    }

    It 'writes only its own report' {
        $new = @($script:After | Where-Object { $script:Before -notcontains $_ })
        $gone = @($script:Before | Where-Object { $script:After -notcontains $_ })
        $gone | Should -BeNullOrEmpty
        $new.Count | Should -Be 1
        $new[0] | Should -Match ([regex]::Escape("\$script:AwsName\_housekeeping\preview-$($script:Plan.planId).json"))
        $script:Plan.gitStateKnown | Should -BeTrue
    }

    It 'classifies <Suffix> as <Class>' -TestCases @(
        @{ Suffix = '-refresh-check-*/a.ps1'; Class = 'Safe' }
        @{ Suffix = '-refresh-check-*/a.out.txt'; Class = 'Safe' }
        @{ Suffix = '-refresh-check-*/sub/b.txt'; Class = 'Safe' }
        @{ Suffix = '-throwaway-*/x.ps1'; Class = 'Safe' }
        @{ Suffix = '-throwaway-*/deep/y.txt'; Class = 'Safe' }
        @{ Suffix = 'scripts/agent013-probe-20250101-101010.ps1'; Class = 'Safe' }
        @{ Suffix = 'scripts/agent013-probe-20250101-101010.out.txt'; Class = 'Safe' }
        @{ Suffix = 'scripts/random.py'; Class = 'Ambiguous' }
        @{ Suffix = 'Sales Report/loose.txt'; Class = 'Ambiguous' }
        @{ Suffix = '/stray.log'; Class = 'Ambiguous' }
        @{ Suffix = '/token-dump.out.txt'; Class = 'SecretFlagged' }
        @{ Suffix = '/capture.txt'; Class = 'SecretFlagged' }
    ) {
        Get-HkClass $script:Plan $Suffix | Should -Be $Class
    }

    It 'never lists a protected file as a candidate: <Suffix>' -TestCases @(
        @{ Suffix = 'scripts/tracked.ps1' }
        @{ Suffix = 'scripts/agent014-check-*.ps1' }
        @{ Suffix = '/model-backup/def.tmdl' }
        @{ Suffix = '-recent-*/r.txt' }
        @{ Suffix = '-running-*/o.txt' }
        @{ Suffix = '/manual-folder/m.txt' }
        @{ Suffix = 'Sales Report/scripts/tool.ps1' }
        @{ Suffix = '/_archive/old.txt' }
        @{ Suffix = '/_shared-tools/shared.ps1' }
        @{ Suffix = '/.task.json' }
        @{ Suffix = '/outside.txt' }
    ) {
        @($script:Plan.entries | Where-Object { $_.path -like "*$Suffix" }) | Should -BeNullOrEmpty
    }

    It 'totals the classes and explains what is protected' {
        $script:Plan.summary.safe.files | Should -Be 7
        $script:Plan.summary.ambiguous.files | Should -Be 3
        $script:Plan.summary.secretFlagged.files | Should -Be 2
        $script:Plan.summary.protected.files | Should -BeGreaterOrEqual 14
        $reasons = @($script:Plan.protectedByReason | ForEach-Object { $_.reason }) -join ' | '
        foreach ($r in 'Git-tracked file', 'backup', 'link or unreadable folder', 'active or unknown session \(open\)', 'active or unknown session \(unknown\)', 'closed task folder, newer than the retention period', 'reusable project utility', 'archive', 'shared tool', 'agent scratch file in scripts/, newer') {
            $reasons | Should -Match $r
        }
        ($script:Plan.summary.safe.bytes + $script:Plan.summary.ambiguous.bytes) | Should -BeGreaterThan 0
    }

    It 'does not follow a link out of the workspace' {
        $script:PlanText | Should -Not -Match 'outside\.txt'
        Test-Path -LiteralPath (Join-Path $script:P.Outside 'outside.txt') | Should -BeTrue
    }

    It 'reports possible secrets by pattern class and never by value, also in a UTF-16 capture' {
        $jwt = @($script:Plan.entries | Where-Object { $_.path -like '*/token-dump.out.txt' })[0]
        @($jwt.secret) | Should -Contain 'jwt'
        @($jwt.secret) | Should -Contain 'file-name'
        $bearer = @($script:Plan.entries | Where-Object { $_.path -like '*/capture.txt' })[0]
        @($bearer.secret) | Should -Be @('bearer-token')
        $script:PlanText | Should -Not -Match ([regex]::Escape($script:FakeJwtTail))
        $script:PlanText | Should -Not -Match ([regex]::Escape($script:FakeBearer))
    }

    It 'prints tokens that are bound to this plan, and one for ambiguous files that names count and size' {
        $id = $script:Plan.planId
        $id | Should -Match '^\d{8}-\d{6}-[0-9a-f]{6}$'
        $script:Plan.tokens.safe | Should -BeExactly "APPROVED:HOUSEKEEPING:$id"
        $script:Plan.tokens.ambiguous | Should -BeExactly "APPROVED:HOUSEKEEPING-AMBIGUOUS:${id}:3:$($script:Plan.summary.ambiguous.bytes)"
    }

    It 'classifies nothing as safe when the Git state cannot be read' {
        $s = New-HkScenario
        # A broken repository: Git cannot say what is tracked.
        [IO.File]::WriteAllText((Join-Path $s.Root '.git\HEAD'), 'not a ref')
        $plan = (Get-AgentWorkspacePreview -WorkspaceRoot $s.Root).Plan
        $plan.gitStateKnown | Should -BeFalse
        $plan.summary.safe.files | Should -Be 0
        Get-HkClass $plan 'scripts/agent013-probe-20250101-101010.ps1' | Should -Be 'Ambiguous'
    }

    It 'treats a workspace that is not a repository as having no tracked files' {
        $s = New-HkScenario -NoGit
        $plan = (Get-AgentWorkspacePreview -WorkspaceRoot $s.Root).Plan
        $plan.gitStateKnown | Should -BeTrue
        Get-HkClass $plan 'scripts/agent013-probe-20250101-101010.ps1' | Should -Be 'Safe'
        Get-HkClass $plan 'scripts/tracked.ps1' | Should -Be 'Ambiguous' -Because 'without Git it is a file of unknown origin, still never safe'
    }
}

Describe 'Housekeeping execute is token-gated, re-checks, moves and can be undone (Maintenance Execute)' {

    BeforeAll {
        $script:E = New-HkScenario
        $script:EPlan = (Get-AgentWorkspacePreview -WorkspaceRoot $script:E.Root).Plan
        $script:EId = $script:EPlan.planId
        $script:EQuarantine = Join-Path $script:E.Root "$script:AwsName\_housekeeping\quarantine\$($script:EId)"
        $script:EStart = Get-HkListing $script:E.Root
    }

    It 'does nothing without a token of this plan' -TestCases @(
        @{ Tokens = @() }
        @{ Tokens = @('APPROVED:HOUSEKEEPING') }
        @{ Tokens = @('APPROVED:HOUSEKEEPING:20200101-000000-abcdef') }
        @{ Tokens = @('approved:housekeeping:PLANID') }
        @{ Tokens = @('APPROVED:HOUSEKEEPING-PURGE:PLANID') }
        @{ Tokens = @('APPROVED:HOUSEKEEPING-AMBIGUOUS:PLANID:99:1') }
    ) {
        $given = @($Tokens | ForEach-Object { $_ -replace 'PLANID', $script:EId })
        $r = Invoke-AgentWorkspaceCleanup -WorkspaceRoot $script:E.Root -PlanId $script:EId -Approval $given
        $r.status | Should -Be 'NEEDS APPROVAL'
        @($r.moved).Count | Should -Be 0
        (Get-HkListing $script:E.Root) | Should -Be $script:EStart
    }

    It 'skips a file that changed and a task that was reopened after the preview' {
        Add-Content -LiteralPath (Join-Path $script:E.Legacy 'agent013-probe-20250101-101010.out.txt') -Value 'new output'
        Set-HkMarker $script:E.T5 @{ status = 'open' }
        $r = Invoke-AgentWorkspaceCleanup -WorkspaceRoot $script:E.Root -PlanId $script:EId -Approval @($script:EPlan.tokens.safe)
        $r.status | Should -Be 'DONE'
        $reasons = @($r.skipped | ForEach-Object { "$($_.path) => $($_.reason)" }) -join "`n"
        $reasons | Should -Match 'agent013-probe-20250101-101010\.out\.txt => changed since the preview'
        $reasons | Should -Match 'x\.ps1 => now classified Protected'
        Test-Path -LiteralPath (Join-Path $script:E.T5 'x.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:E.T5 'deep\y.txt') | Should -BeTrue
        # Safe files of the other closed task and the untouched scratch script were moved.
        @($r.moved | Where-Object { $_.class -eq 'Safe' }).Count | Should -Be 4
        foreach ($rel in 'a.ps1', 'a.out.txt', 'sub\b.txt') { Test-Path -LiteralPath (Join-Path $script:E.T1 $rel) | Should -BeFalse }
        Test-Path -LiteralPath (Join-Path $script:E.Legacy 'agent013-probe-20250101-101010.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:EQuarantine 'scripts\agent013-probe-20250101-101010.ps1') | Should -BeTrue -Because 'Execute moves, it never deletes'
    }

    It 'leaves ambiguous, secret-flagged and protected files where they are' {
        foreach ($p in (Join-Path $script:E.Legacy 'random.py'), (Join-Path $script:E.Legacy 'tracked.ps1'), (Join-Path $script:E.Aws 'Sales Report\loose.txt'), (Join-Path $script:E.Aws 'stray.log'),
                       (Join-Path $script:E.T1 'token-dump.out.txt'), (Join-Path $script:E.T1 'capture.txt'), (Join-Path $script:E.T1 'model-backup\def.tmdl'), (Join-Path $script:E.T1 '.task.json'),
                       (Join-Path $script:E.T2 'r.txt'), (Join-Path $script:E.T3 'o.txt'), (Join-Path $script:E.Aws 'Sales Report\scripts\tool.ps1'), (Join-Path $script:E.Outside 'outside.txt')) {
            Test-Path -LiteralPath $p | Should -BeTrue -Because "$p must not be moved by the safe token"
        }
        Test-Path -LiteralPath (Join-Path $script:E.T1 'sub') | Should -BeFalse -Because 'a folder the cleanup emptied is removed'
        Test-Path -LiteralPath $script:E.T1 -PathType Container | Should -BeTrue -Because 'the task folder still holds files that stay'
    }

    It 'changes nothing when it is run a second time' {
        $before = Get-HkListing $script:E.Root
        $r = Invoke-AgentWorkspaceCleanup -WorkspaceRoot $script:E.Root -PlanId $script:EId -Approval @($script:EPlan.tokens.safe)
        $r.status | Should -Be 'DONE'
        @($r.moved).Count | Should -Be 0
        $r.alreadyQuarantined | Should -Be 4
        (Get-HkListing $script:E.Root) | Should -Be $before
    }

    It 'moves ambiguous files only with the token that names their count and size' {
        $wrong = "APPROVED:HOUSEKEEPING-AMBIGUOUS:$($script:EId):2:$($script:EPlan.summary.ambiguous.bytes)"
        (Invoke-AgentWorkspaceCleanup -WorkspaceRoot $script:E.Root -PlanId $script:EId -Approval @($wrong)).status | Should -Be 'NEEDS APPROVAL'
        Test-Path -LiteralPath (Join-Path $script:E.Legacy 'random.py') | Should -BeTrue
        $r = Invoke-AgentWorkspaceCleanup -WorkspaceRoot $script:E.Root -PlanId $script:EId -Approval @($script:EPlan.tokens.ambiguous)
        @($r.moved | Where-Object { $_.class -eq 'Ambiguous' }).Count | Should -Be 3
        Test-Path -LiteralPath (Join-Path $script:E.Legacy 'random.py') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:E.Legacy 'tracked.ps1') | Should -BeTrue
    }

    It 'moves a secret-flagged file only when that file is named' {
        $entry = @($script:EPlan.entries | Where-Object { $_.path -like '*/token-dump.out.txt' })[0]
        $r = Invoke-AgentWorkspaceCleanup -WorkspaceRoot $script:E.Root -PlanId $script:EId -Approval @("APPROVED:HOUSEKEEPING-SECRET:$($script:EId):$($entry.id)")
        @($r.moved).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $script:E.T1 'token-dump.out.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:E.T1 'capture.txt') | Should -BeTrue -Because 'the other flagged file was not named'
    }

    It 'NEGATIVE CONTROL: a tampered plan cannot make it move a protected file or a path outside the area' {
        $s = New-HkScenario
        $plan = (Get-AgentWorkspacePreview -WorkspaceRoot $s.Root).Plan
        $file = Join-Path $s.Root "$script:AwsName\_housekeeping\preview-$($plan.planId).json"
        $json = [IO.File]::ReadAllText($file) | ConvertFrom-Json
        $forge = {
            param([string]$Rel, [string]$Full)
            $fi = Get-Item -LiteralPath $Full
            [pscustomobject]@{ id = 900 + @($json.entries).Count; path = $Rel; class = 'Safe'; reason = 'forged'; bytes = $fi.Length; modifiedUtcTicks = $fi.LastWriteTimeUtc.Ticks; secret = @() }
        }
        $outsideRel = '../' + (Split-Path $s.Outside -Leaf) + '/outside.txt'
        $t3Rel = ($s.T3.Substring($s.Root.Length + 1) -replace '\\', '/') + '/o.txt'
        $json.entries = @($json.entries) + @(
            (& $forge 'scripts/tracked.ps1' (Join-Path $s.Legacy 'tracked.ps1')),
            (& $forge $t3Rel (Join-Path $s.T3 'o.txt')),
            (& $forge "$script:AwsName/Sales Report/scripts/tool.ps1" (Join-Path $s.Aws 'Sales Report\scripts\tool.ps1')),
            (& $forge $outsideRel (Join-Path $s.Outside 'outside.txt')),
            (& $forge "$script:AwsName/_housekeeping/preview-$($plan.planId).json" $file)
        )
        [IO.File]::WriteAllText($file, ($json | ConvertTo-Json -Depth 8), $script:Utf8)
        $r = Invoke-AgentWorkspaceCleanup -WorkspaceRoot $s.Root -PlanId $plan.planId -Approval @($plan.tokens.safe)
        $r.status | Should -Be 'DONE'
        $why = @($r.skipped | Where-Object { $_.reason -match 'forged|now classified|outside the housekeeping area' -or $_.id -ge 900 } | ForEach-Object { $_.reason })
        @($r.skipped | Where-Object { $_.id -ge 900 }).Count | Should -Be 5
        @($why | Where-Object { $_ -match 'now classified Protected' }).Count | Should -Be 3
        @($why | Where-Object { $_ -match 'outside the housekeeping area' }).Count | Should -Be 2
        foreach ($p in (Join-Path $s.Legacy 'tracked.ps1'), (Join-Path $s.T3 'o.txt'), (Join-Path $s.Aws 'Sales Report\scripts\tool.ps1'), (Join-Path $s.Outside 'outside.txt'), $file) { Test-Path -LiteralPath $p | Should -BeTrue }
    }

    It 'refuses a preview older than seven days and an unknown plan id' {
        $s = New-HkScenario -NoGit
        $plan = (Get-AgentWorkspacePreview -WorkspaceRoot $s.Root).Plan
        $file = Join-Path $s.Root "$script:AwsName\_housekeeping\preview-$($plan.planId).json"
        $json = [IO.File]::ReadAllText($file) | ConvertFrom-Json
        $json.createdUtcTicks = (Get-Date).ToUniversalTime().AddDays(-8).Ticks
        [IO.File]::WriteAllText($file, ($json | ConvertTo-Json -Depth 8), $script:Utf8)
        $r = Invoke-AgentWorkspaceCleanup -WorkspaceRoot $s.Root -PlanId $plan.planId -Approval @($plan.tokens.safe)
        $r.status | Should -Be 'FAILED'
        $r.message | Should -Match 'older than 7 days'
        (Invoke-AgentWorkspaceCleanup -WorkspaceRoot $s.Root -PlanId '..\..\x' -Approval @('APPROVED:HOUSEKEEPING:..\..\x')).status | Should -Be 'FAILED'
        Test-Path -LiteralPath (Join-Path $s.Legacy 'agent013-probe-20250101-101010.ps1') | Should -BeTrue
    }
}

Describe 'Restore and purge (recovery is restore-from-quarantine)' {

    BeforeAll {
        $script:R = New-HkScenario
        $script:RStart = Get-HkListing $script:R.Root
        $script:RPlan = (Get-AgentWorkspacePreview -WorkspaceRoot $script:R.Root).Plan
        $script:RId = $script:RPlan.planId
        $script:RExec = Invoke-AgentWorkspaceCleanup -WorkspaceRoot $script:R.Root -PlanId $script:RId -Approval @($script:RPlan.tokens.safe)
        $script:RQuarantine = Join-Path $script:R.Root "$script:AwsName\_housekeeping\quarantine\$($script:RId)"
    }

    It 'a fully cleaned task folder leaves with its marker' {
        @($script:RExec.moved | Where-Object { $_.class -eq 'Safe' }).Count | Should -Be 7
        @($script:RExec.moved | Where-Object { $_.class -eq 'Marker' }).Count | Should -Be 1
        [long]@($script:RExec.moved | Where-Object { $_.class -eq 'Marker' })[0].bytes | Should -BeGreaterThan 0 -Because 'the execute log records the real size of the marker it moved (Canary finding)'
        Test-Path -LiteralPath $script:R.T5 | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:R.T1 '.task.json') | Should -BeTrue -Because 'a task folder that still holds files keeps its marker'
    }

    It 'restore puts every file back where it was' {
        $r = Restore-AgentWorkspaceQuarantine -WorkspaceRoot $script:R.Root -PlanId $script:RId
        $r.status | Should -Be 'DONE'
        @($r.restored).Count | Should -Be 8
        @($r.skipped) | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:RQuarantine | Should -BeFalse
        $now = @(Get-HkListing $script:R.Root | Where-Object { $_ -notmatch '\\_housekeeping\\' })
        $now | Should -Be @($script:RStart | Where-Object { $_ -notmatch '\\_housekeeping\\' })
        ([IO.File]::ReadAllText((Join-Path $script:R.T5 '.task.json')) | ConvertFrom-Json).status | Should -Be 'closed'
    }

    It 'restore never overwrites a file that reappeared' {
        $s = New-HkScenario -NoGit
        $plan = (Get-AgentWorkspacePreview -WorkspaceRoot $s.Root).Plan
        $null = Invoke-AgentWorkspaceCleanup -WorkspaceRoot $s.Root -PlanId $plan.planId -Approval @($plan.tokens.safe)
        Set-HkFile (Join-Path $s.Legacy 'agent013-probe-20250101-101010.ps1') 'written again meanwhile'
        $r = Restore-AgentWorkspaceQuarantine -WorkspaceRoot $s.Root -PlanId $plan.planId
        (@($r.skipped) -join ' ') | Should -Match 'agent013-probe-20250101-101010\.ps1: a file is already there'
        [IO.File]::ReadAllText((Join-Path $s.Legacy 'agent013-probe-20250101-101010.ps1')) | Should -Be 'written again meanwhile'
        Test-Path -LiteralPath (Join-Path $s.Root "$script:AwsName\_housekeeping\quarantine\$($plan.planId)\scripts\agent013-probe-20250101-101010.ps1") | Should -BeTrue
    }

    It 'purge needs its own token and deletes only what Execute recorded, one file at a time' {
        $s = New-HkScenario -NoGit
        $plan = (Get-AgentWorkspacePreview -WorkspaceRoot $s.Root).Plan
        $id = $plan.planId
        $null = Invoke-AgentWorkspaceCleanup -WorkspaceRoot $s.Root -PlanId $id -Approval @($plan.tokens.safe)
        $q = Join-Path $s.Root "$script:AwsName\_housekeeping\quarantine\$id"
        Set-HkFile (Join-Path $q 'placed by someone else\unknown.txt') 'not in the execute log'
        $count = @(Get-ChildItem -LiteralPath $q -Recurse -File -Force).Count
        foreach ($bad in @(), @($plan.tokens.safe), @("APPROVED:HOUSEKEEPING-PURGE:20200101-000000-abcdef")) {
            (Remove-AgentWorkspaceQuarantine -WorkspaceRoot $s.Root -PlanId $id -Approval $bad).status | Should -Be 'NEEDS APPROVAL'
            @(Get-ChildItem -LiteralPath $q -Recurse -File -Force).Count | Should -Be $count
        }
        $r = Remove-AgentWorkspaceQuarantine -WorkspaceRoot $s.Root -PlanId $id -Approval @("APPROVED:HOUSEKEEPING-PURGE:$id")
        $r.status | Should -Be 'DONE'
        $r.purged | Should -Be ($count - 1)
        (@($r.left) -join ' ') | Should -Match 'unknown\.txt: not recorded by Execute, left in place'
        @(Get-ChildItem -LiteralPath $q -Recurse -File -Force | ForEach-Object { $_.Name }) | Should -Be @('unknown.txt')
    }
}

Describe 'Windows paths: spaces and more than 260 characters (HK-08)' {

    It 'previews, quarantines and restores a file behind a very long path' {
        $root = Join-Path $script:Base 'long path workspace'
        New-Item -ItemType Directory -Path $root | Out-Null
        $task = New-AgentTaskFolder -WorkspaceRoot $root -Project 'A Project With Spaces' -Topic 'long paths'
        $relDir = (1..6 | ForEach-Object { 'export folder ' + $_ + ' ' + ('p' * 30) }) -join '\'
        $long = '\\?\' + $task + '\' + $relDir
        [void][IO.Directory]::CreateDirectory($long)
        [IO.File]::WriteAllText("$long\definition copy.json", '{ "k": 1 }')
        ("$task\$relDir\definition copy.json").Length | Should -BeGreaterThan 320
        Close-AgentTaskFolder -Path $task | Out-Null
        Set-HkMarker $task @{ closedUtcTicks = (Get-HkOldTicks) }

        $plan = (Get-AgentWorkspacePreview -WorkspaceRoot $root).Plan
        $entry = @($plan.entries | Where-Object { $_.path -like '*/definition copy.json' })
        $entry.Count | Should -Be 1
        $entry[0].class | Should -Be 'Safe'
        $r = Invoke-AgentWorkspaceCleanup -WorkspaceRoot $root -PlanId $plan.planId -Approval @($plan.tokens.safe)
        @($r.skipped) | Should -BeNullOrEmpty
        [IO.File]::Exists("$long\definition copy.json") | Should -BeFalse
        Test-Path -LiteralPath $task | Should -BeFalse -Because 'the emptied long folders and the task folder are removed one by one'
        $quarantined = '\\?\' + $root + "\$script:AwsName\_housekeeping\quarantine\$($plan.planId)\" + ($entry[0].path -replace '/', '\')
        $quarantined.Length | Should -BeGreaterThan 400
        [IO.File]::Exists($quarantined) | Should -BeTrue
        (Restore-AgentWorkspaceQuarantine -WorkspaceRoot $root -PlanId $plan.planId).status | Should -Be 'DONE'
        [IO.File]::ReadAllText("$long\definition copy.json") | Should -Be '{ "k": 1 }'
    }

    It 'previews, quarantines and restores files whose names are not ASCII or need quoting' {
        # Built from code points so this file stays plain ASCII: accented Latin, Greek, CJK, and
        # characters a shell would otherwise treat specially (space, apostrophe, brackets, ampersand, percent).
        $accented = 'Verkaufs' + [char]0x00FC + 'bersicht ' + [char]0x00E9 + 't' + [char]0x00E9
        $greek = [string][char]0x0394 + [char]0x03B5 + [char]0x03B4 + [char]0x03BF + [char]0x03BC + [char]0x03AD + [char]0x03BD + [char]0x03B1
        $cjk = [string][char]0x62A5 + [char]0x8868
        $quoting = "it's [draft] & 100% (v2)"
        $root = Join-Path $script:Base ("unicode ws $greek")
        New-Item -ItemType Directory -Path $root | Out-Null
        $task = New-AgentTaskFolder -WorkspaceRoot $root -Project $accented -Topic 'names'
        Test-Path -LiteralPath $task | Should -BeTrue
        $files = [ordered]@{
            "$accented.out.txt"       = 'accented'
            "$greek\$cjk.json"        = 'greek folder, cjk file'
            "$quoting.txt"            = 'quoting'
            "$quoting\$accented.csv"  = 'both'
        }
        # Created with .NET calls: square brackets in a name must not be read as a wildcard here.
        foreach ($rel in $files.Keys) {
            $full = Join-Path $task $rel
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
            [IO.File]::WriteAllText($full, $files[$rel], $script:Utf8)
        }
        Close-AgentTaskFolder -Path $task | Out-Null
        Set-HkMarker $task @{ closedUtcTicks = (Get-HkOldTicks) }

        $before = Get-HkListing $root
        $preview = Get-AgentWorkspacePreview -WorkspaceRoot $root
        $plan = $preview.Plan
        foreach ($rel in $files.Keys) {
            $leaf = Split-Path $rel -Leaf
            $entry = @($plan.entries | Where-Object { $_.path.EndsWith('/' + $leaf) })
            $entry.Count | Should -Be 1 -Because "$leaf is listed exactly once, with its real name"
            $entry[0].class | Should -Be 'Safe'
        }
        # The plan file is JSON on disk: the names must survive being written and read back.
        $reread = Read-HkPlan $root $plan.planId
        @($reread.entries | ForEach-Object { $_.path } | Sort-Object) | Should -Be @($plan.entries | ForEach-Object { $_.path } | Sort-Object)

        $r = Invoke-AgentWorkspaceCleanup -WorkspaceRoot $root -PlanId $plan.planId -Approval @($plan.tokens.safe)
        $r.status | Should -Be 'DONE'
        @($r.skipped) | Should -BeNullOrEmpty
        foreach ($rel in $files.Keys) { [IO.File]::Exists((Join-Path $task $rel)) | Should -BeFalse }
        Invoke-AgentWorkspaceCleanup -WorkspaceRoot $root -PlanId $plan.planId -Approval @($plan.tokens.safe) | Out-Null   # a second run finds nothing left to move

        (Restore-AgentWorkspaceQuarantine -WorkspaceRoot $root -PlanId $plan.planId).status | Should -Be 'DONE'
        foreach ($rel in $files.Keys) { [IO.File]::ReadAllText((Join-Path $task $rel)) | Should -BeExactly $files[$rel] -Because "$rel is back with its content" }
        @(Get-HkListing $root | Where-Object { $_ -notmatch '\\_housekeeping\\' }) | Should -Be @($before | Where-Object { $_ -notmatch '\\_housekeeping\\' })
    }

    It 'flags a possible secret in a file with a non-ASCII name and still never shows the value' {
        $name = 'Schl' + [char]0x00FC + 'ssel ' + [char]0x5BC6 + [char]0x94A5 + '.out.txt'
        $root = Join-Path $script:Base 'unicode secret ws'
        New-Item -ItemType Directory -Path $root | Out-Null
        $task = New-AgentTaskFolder -WorkspaceRoot $root -Project 'P' -Topic 'secret'
        Set-HkFile (Join-Path $task $name) ("x`n" + $script:FakeJwt + "`n")
        Close-AgentTaskFolder -Path $task | Out-Null
        Set-HkMarker $task @{ closedUtcTicks = (Get-HkOldTicks) }
        $plan = (Get-AgentWorkspacePreview -WorkspaceRoot $root).Plan
        $entry = @($plan.entries | Where-Object { $_.path.EndsWith('/' + $name) })
        $entry.Count | Should -Be 1
        $entry[0].class | Should -Be 'SecretFlagged'
        $planText = [IO.File]::ReadAllText((Join-Path $root "$script:AwsName\_housekeeping\preview-$($plan.planId).json"))
        $planText | Should -Not -Match ([regex]::Escape($script:FakeJwtTail))
        ($plan | ConvertTo-Json -Depth 10) | Should -Not -Match ([regex]::Escape($script:FakeJwtTail))
    }
}

Describe 'Ignore rules for Power BI project files (HK-02)' {

    BeforeAll {
        . (Get-InstallerFunctionLoader 'Add-GitIgnoreRules', 'Add-PowerBiProjectIgnoreRules')
        $m = [regex]::Match($script:InstallerText, "(?s)\`$gitignoreContent = @'\r?\n(.*?)\r?\n'@")
        $m.Success | Should -BeTrue
        $script:IgnoreTemplate = @($m.Groups[1].Value -split "\r?\n")
        $script:IgnoreDir = Join-Path $script:Base 'ignore rules'
        New-Item -ItemType Directory -Path $script:IgnoreDir | Out-Null
        function New-HkIgnoreFile([string]$Text) {
            $p = Join-Path $script:IgnoreDir ([guid]::NewGuid().ToString('N').Substring(0, 8) + '.gitignore')
            [IO.File]::WriteAllText($p, $Text, $script:Utf8)
            return $p
        }
        function Get-HkRules([string]$FilePath) { return @([IO.File]::ReadAllLines($FilePath) | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | ForEach-Object { $_.Trim() }) }
    }

    It 'a new workspace ignores exactly the two per-machine files Power BI Desktop ignores itself' {
        $rules = @($script:IgnoreTemplate | Where-Object { $_.Trim() -and -not $_.StartsWith('#') })
        $rules | Should -Contain '**/.pbi/localSettings.json'
        $rules | Should -Contain '**/.pbi/cache.abf'
        @($rules | Where-Object { $_ -match '\.pbi' }).Count | Should -Be 2 -Because 'the rest of a .pbi folder (editorSettings.json, unappliedChanges.json) is project content'
    }

    It 'a new workspace has no rule that hides a whole .pbi folder, and no rule for a file type that does not exist' {
        $rules = @($script:IgnoreTemplate | Where-Object { $_.Trim() -and -not $_.StartsWith('#') })
        $rules | Should -Not -Contain '.pbi/'
        @($rules | Where-Object { $_ -match 'pbicache' }) | Should -BeNullOrEmpty
        $script:InstallerText | Should -Not -Match "'\*\.pbicache'" -Because 'no code path writes that rule any more'
    }

    It 'every rule of the new-workspace template is anchored to something the kit creates or documents' {
        # A plain list on purpose: a new line in the template has to be added here with its reason.
        $expected = @(
            'skills-for-fabric/', 'power-bi-agentic-development/', 'source-control-repositories/',
            '.vscode/', 'Fabric-Agentic-Workspace.code-workspace', 'Thumbs.db', '.DS_Store',
            '**/.pbi/localSettings.json', '**/.pbi/cache.abf',
            '.github/agent-docs/tool-status.json', '.github/agent-docs/session-status.last.txt', '.github/agent-docs/session-status/',
            '.github/agent-docs/guardrail-status.json', '.github/agent-docs/installed-manifest.json',
            '.github/agent-docs/skill-catalog-state.json', '.github/agent-docs/local/',
            '.dataprojects/', "/$script:AwsName/"
        )
        $rules = @($script:IgnoreTemplate | Where-Object { $_.Trim() -and -not $_.StartsWith('#') })
        @($rules | Sort-Object) | Should -Be @($expected | Sort-Object)
        $rules | Should -Not -Contain '/scripts/' -Because 'a root scripts/ folder is ignored only after checking that nothing in it is tracked'
        $rules | Should -Not -Contain 'scripts/'
    }

    It 'an existing .gitignore without the rules gets the two files appended and keeps its own lines' {
        $p = New-HkIgnoreFile "# mine`r`nnode_modules/`r`n*.log`r`n"
        Add-PowerBiProjectIgnoreRules -Path $p
        $rules = Get-HkRules $p
        $rules[0] | Should -Be 'node_modules/'
        $rules[1] | Should -Be '*.log'
        $rules | Should -Contain '**/.pbi/localSettings.json'
        $rules | Should -Contain '**/.pbi/cache.abf'
        $rules.Count | Should -Be 4
        [IO.File]::ReadAllText($p).StartsWith("# mine`r`nnode_modules/`r`n*.log`r`n") | Should -BeTrue -Because 'existing content is never rewritten'
    }

    It 'a second run adds nothing' {
        $p = New-HkIgnoreFile "node_modules/`r`n"
        Add-PowerBiProjectIgnoreRules -Path $p
        $once = [IO.File]::ReadAllText($p)
        Add-PowerBiProjectIgnoreRules -Path $p
        [IO.File]::ReadAllText($p) | Should -BeExactly $once
    }

    It 'an existing broader rule (<Rule>) written by an earlier version is left exactly as it is' -TestCases @(
        @{ Rule = '.pbi/' }, @{ Rule = '.pbi' }, @{ Rule = '**/.pbi/' }, @{ Rule = '/.pbi/' }, @{ Rule = '  .pbi/  ' }
    ) {
        param($Rule)
        $text = "# Fabric local cache`r`n$Rule`r`n*.pbicache`r`n"
        $p = New-HkIgnoreFile $text
        Add-PowerBiProjectIgnoreRules -Path $p
        [IO.File]::ReadAllText($p) | Should -BeExactly $text -Because 'the broader rule already covers both files, and the installer never removes a line from a .gitignore'
    }

    It 'a rule for another folder that merely contains the text is not mistaken for the broader rule' {
        $p = New-HkIgnoreFile "my.pbi/`r`n.pbix`r`n# .pbi/`r`n"
        Add-PowerBiProjectIgnoreRules -Path $p
        Get-HkRules $p | Should -Contain '**/.pbi/cache.abf'
    }

    It 'only one of the two rules present: the missing one is added once' {
        $p = New-HkIgnoreFile "**/.pbi/cache.abf`r`n"
        Add-PowerBiProjectIgnoreRules -Path $p
        $rules = Get-HkRules $p
        @($rules | Where-Object { $_ -eq '**/.pbi/cache.abf' }).Count | Should -Be 1
        @($rules | Where-Object { $_ -eq '**/.pbi/localSettings.json' }).Count | Should -Be 1
    }

    It 'the update path calls this function and no longer lists the old rules' {
        $script:InstallerText | Should -Match '(?m)^\s+Add-PowerBiProjectIgnoreRules -Path \$gitignorePath\s*$'
        $script:InstallerText | Should -Not -Match "Fabric local cache"
    }
}

Describe 'Command line, as the agents run it (Windows PowerShell 5.1)' {

    BeforeAll {
        $script:C = New-HkScenario
        # The helper finds the workspace from its own location: install it like the kit does.
        $script:CHelper = Join-Path $script:C.Root '.github\agent-docs\Agent-Workspace.ps1'
        New-Item -ItemType Directory -Path (Split-Path $script:CHelper -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($script:CHelper, $script:HelperSource, $script:Utf8)
        function Invoke-HkCli { $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:CHelper @args 2>&1 | Out-String; return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = $out } }
    }

    It 'prints the new task folder path and nothing else' {
        $r = Invoke-HkCli -NewTask -Project 'Sales Report' -Topic 'cli check'
        $path = $r.Text.Trim()
        $path | Should -Match ([regex]::Escape((Join-Path $script:C.Aws 'Sales Report\tasks\')) + '\d{4}-\d{2}-\d{2}-cli-check-[0-9a-f]{6}$')
        Test-Path -LiteralPath (Join-Path $path '.task.json') | Should -BeTrue
        Set-HkFile (Join-Path $path 'one.out.txt'); Set-HkFile (Join-Path $path 'two.out.txt'); Set-HkFile (Join-Path $path 'keep.md')
        $c = Invoke-HkCli -CloseTask -Path $path -Remove 'one.out.txt,two.out.txt' -Kept 'keep.md'
        $c.Text | Should -Match 'TASK CLOSED'
        $c.Text | Should -Match 'Removed: 2 file\(s\)'
        @(Get-ChildItem -LiteralPath $path -File -Force | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('.task.json', 'keep.md')
    }

    It 'previews, then executes only with the token the preview printed' {
        $p = Invoke-HkCli -Preview
        $p.Text | Should -Match '(?m)^HOUSEKEEPING PREVIEW  plan (\d{8}-\d{6}-[0-9a-f]{6})'
        $id = [regex]::Match($p.Text, 'HOUSEKEEPING PREVIEW  plan (\S+)').Groups[1].Value
        $p.Text | Should -Match ([regex]::Escape("Safe            7 file(s)"))
        $p.Text | Should -Match ([regex]::Escape("-> APPROVED:HOUSEKEEPING:$id"))
        $p.Text | Should -Match "APPROVED:HOUSEKEEPING-AMBIGUOUS:${id}:3:\d+"
        $p.Text | Should -Match 'Possible secrets \(path and pattern class; values are never shown\)'
        $p.Text | Should -Match 'token-dump\.out\.txt\s+\(file-name, jwt\)'
        $p.Text | Should -Not -Match ([regex]::Escape($script:FakeJwtTail))
        $p.Text | Should -Not -Match ([regex]::Escape($script:FakeBearer))
        $p.Text | Should -Match 'Nothing has been changed'

        $none = Invoke-HkCli -Execute -PlanId $id
        $none.Text | Should -Match 'status NEEDS APPROVAL'
        Test-Path -LiteralPath (Join-Path $script:C.T1 'a.ps1') | Should -BeTrue

        $x = Invoke-HkCli -Execute -PlanId $id -Approval "APPROVED:HOUSEKEEPING:$id"
        $x.Text | Should -Match 'status DONE'
        $x.Text | Should -Match 'Moved to quarantine: 8 file\(s\)'
        $x.Text | Should -Match "-Restore -PlanId $id"
        Test-Path -LiteralPath (Join-Path $script:C.T1 'a.ps1') | Should -BeFalse

        (Invoke-HkCli -Purge -PlanId $id).Text | Should -Match 'status NEEDS APPROVAL'
        $back = Invoke-HkCli -Restore -PlanId $id
        $back.Text | Should -Match 'Restored: 8 file\(s\)'
        Test-Path -LiteralPath (Join-Path $script:C.T1 'a.ps1') | Should -BeTrue
    }

    It 'explains every protected file, and says that a flagged protected file stays (Canary finding)' {
        # A file with a tell-tale name inside an open task: reported for rotation, but never a candidate.
        Set-HkFile (Join-Path $script:C.T3 'api-token-notes.txt') 'no secret value here'
        $p = Invoke-HkCli -Preview
        $p.Text | Should -Match 'api-token-notes\.txt\s+\(file-name\)\s+- protected: stays where it is'
        $p.Text | Should -Match 'token-dump\.out\.txt\s+\(file-name, jwt\)\s*\r?\n' -Because 'a file a token can move carries no such note'
        $total = [int][regex]::Match($p.Text, '(?m)^\s+Protected\s+(\d+) file\(s\)').Groups[1].Value
        $byReason = 0
        foreach ($m in [regex]::Matches($p.Text, '(?m)^\s{6}(\d+) x ')) { $byReason += [int]$m.Groups[1].Value }
        $total | Should -BeGreaterThan 0
        $byReason | Should -Be $total -Because 'the reasons listed under Protected must add up to the Protected total'
    }

    It 'has no command that deletes recursively or by wildcard across folders' {
        $code = ($script:HelperSource -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $code | Should -Not -Match '(?i)Remove-Item|\brd\b|\brmdir\b|\bdel\b|-Recurse|Directory\]::Delete\([^)]*,\s*\$true'
        $code | Should -Not -Match '(?i)Invoke-Expression|\biex\b|Invoke-WebRequest|Start-Process'
        @([regex]::Matches($code, '\[IO\.File\]::Delete\(')).Count | Should -Be 2 -Because 'files are deleted in two places only: a named file of a closing task, and a purge of recorded files'
    }
}

Describe 'Installer side: tree, ignore rules, contracts and Maintenance roles' {

    BeforeAll {
        $script:I = Join-Path $script:Base 'install root'
        # Content that exists before the installer runs must survive untouched.
        Set-HkFile (Join-Path $script:I "$script:AwsName\Existing Project\tasks\old\mine.txt") 'user content'
        Set-HkFile (Join-Path $script:I "$script:AwsName\README.md") 'my own notes'
        Set-HkFile (Join-Path $script:I 'scripts\agent013-probe-20250101-101010.ps1') 'legacy scratch'
        $out = & cmd /c ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $script:I) 2>&1
        $script:IExit = $LASTEXITCODE
        $script:IOut = ($out | Out-String)
        $script:IAgents = @{}
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $script:I '.github\agents') -Filter '*.agent.md' -ErrorAction SilentlyContinue)) { $script:IAgents[$f.Name] = [IO.File]::ReadAllText($f.FullName) }
        $script:Manifest = Get-AgentManifest
    }

    It 'emits the helper byte for byte from its single source, as a managed file' {
        $script:IExit | Should -Be 0 -Because $script:IOut
        [IO.File]::ReadAllText((Join-Path $script:I '.github\agent-docs\Agent-Workspace.ps1')) | Should -BeExactly $script:HelperSource
        $manifest = [IO.File]::ReadAllText((Join-Path $script:I '.github\agent-docs\installed-manifest.json')) | ConvertFrom-Json
        (@($manifest.files | ForEach-Object { $_.path }) -contains '.github/agent-docs/Agent-Workspace.ps1') | Should -BeTrue
        (@($manifest.files | ForEach-Object { $_.path }) -contains '.github/skills/fabric-housekeeping/SKILL.md') | Should -BeTrue
    }

    It 'names the working folder identically in the installer, the helper, the ignore rule and the skill' {
        [regex]::Match($script:InstallerText, "(?m)^\`$agentFilesFolderName = '([^']+)'").Groups[1].Value | Should -BeExactly $script:AwsName
        [IO.File]::ReadAllText((Join-Path $script:I '.gitignore')) | Should -Match ('(?m)^/' + [regex]::Escape($script:AwsName) + '/\s*$')
        [IO.File]::ReadAllText((Join-Path $script:I '.github\skills\fabric-housekeeping\SKILL.md')) | Should -Match ('(?m)^' + [regex]::Escape($script:AwsName) + '/\s*$')
        $script:InstallerText | Should -Match '(?m)^\$pbivizReserved = @\([^\r\n]*\$agentFilesFolderName\)' -Because 'the housekept, git-ignored folder must never be chosen as the PBIVIZ repository folder'
    }

    It 'creates the working tree and never moves, overwrites or removes what is already there' {
        foreach ($d in '_shared-tools', '_housekeeping') { Test-Path -LiteralPath (Join-Path $script:I "$script:AwsName\$d") -PathType Container | Should -BeTrue }
        [IO.File]::ReadAllText((Join-Path $script:I "$script:AwsName\README.md")) | Should -Be 'my own notes'
        [IO.File]::ReadAllText((Join-Path $script:I "$script:AwsName\Existing Project\tasks\old\mine.txt")) | Should -Be 'user content'
        [IO.File]::ReadAllText((Join-Path $script:I 'scripts\agent013-probe-20250101-101010.ps1')) | Should -Be 'legacy scratch'
        $fresh = Join-Path $script:Base 'fresh install root'
        & cmd /c ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $fresh) 2>&1 | Out-Null
        [IO.File]::ReadAllText((Join-Path $fresh "$script:AwsName\README.md")) | Should -Match 'housekeeping preview'
        Test-Path -LiteralPath (Join-Path $fresh 'scripts') | Should -BeFalse -Because 'the legacy folder is never created'
        [IO.File]::ReadAllText((Join-Path $fresh '.gitignore')) | Should -Not -Match '(?m)^/scripts/' -Because 'a workspace without a legacy scratch folder gets no rule that could hide a future user folder'
    }

    It 'ignores a legacy root scripts/ folder only when nothing in it is tracked' {
        [IO.File]::ReadAllText((Join-Path $script:I '.gitignore')) | Should -Match '(?m)^/scripts/\s*$'
        $tracked = Join-Path $script:Base 'tracked scripts root'
        Set-HkFile (Join-Path $tracked 'scripts\deploy.ps1') 'a user script under version control'
        & git -C $tracked init -q 2>$null; & git -C $tracked add -- scripts/deploy.ps1 2>$null; & git -C $tracked commit -q -m 'user commit' 2>$null
        $out = & cmd /c ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $tracked) 2>&1 | Out-String
        [IO.File]::ReadAllText((Join-Path $tracked '.gitignore')) | Should -Not -Match '(?m)^/scripts/'
        $out | Should -Match 'scripts/ holds 1 tracked file\(s\): no ignore rule added'
        (& git -C $tracked ls-files -- scripts 2>$null) | Should -Be 'scripts/deploy.ps1'
    }

    It 'a second run adds no duplicate ignore rule' {
        & cmd /c ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $script:I) 2>&1 | Out-Null
        $t = [IO.File]::ReadAllText((Join-Path $script:I '.gitignore'))
        @([regex]::Matches($t, '(?m)^/' + [regex]::Escape($script:AwsName) + '/\s*$')).Count | Should -Be 1
        @([regex]::Matches($t, '(?m)^/scripts/\s*$')).Count | Should -Be 1
    }

    It 'every agent carries the working-files rule, worded for what it can do' {
        $script:IAgents.Count | Should -Be 54
        foreach ($agent in $script:Manifest.agents) {
            $body = @($script:IAgents.GetEnumerator() | Where-Object { $_.Key -replace '^\d+-', '' -eq ($agent.filename -replace '^\d+-', '') })[0].Value
            $body | Should -Match '(?m)^- \*\*Working files\.\*\*' -Because $agent.filename
            $tools = @($agent.tools)
            if ($tools -contains 'edit' -or $tools -contains 'execute') {
                $body | Should -Match 'fabric-housekeeping/SKILL\.md' -Because $agent.filename
                $body | Should -Match 'task folder named in your WORK ORDER' -Because $agent.filename
                $body | Should -Match 'Never write a token or password to a file or a log' -Because $agent.filename
                $body | Should -Match 'never clean up beyond your own task folder' -Because $agent.filename
            } else {
                $body | Should -Match 'Working files\.\*\* You create none' -Because "$($agent.filename) can neither edit nor run commands"
            }
            if ($tools -contains 'execute') { $body | Should -Match 'Agent-Workspace\.ps1 -NewTask' -Because $agent.filename }
            elseif ($tools -contains 'edit') { $body | Should -Match 'return `NEEDS INPUT` asking for it' -Because "$($agent.filename) cannot run the helper" }
            if ($tools -contains 'agent' -and $tools -contains 'execute') { $body | Should -Match 'Agent-Workspace\.ps1 -CloseTask' -Because "$($agent.filename) may be the agent the user selected" }
            if ($agent.id -ne 'fabric-workspace-master') { $body | Should -Match '(?m)^housekeeping: <temporary files removed' -Because "$($agent.filename) must report housekeeping in its WORK RESULT" }
        }
    }

    It 'no agent is told to use the root scripts/ folder any more' {
        $old = 'scripts/<agent>-<purpose>|under `scripts/`|under scripts/ and start|`scripts/` is scratch'
        # Negative control: the v0.8.0 wording is what this pattern catches.
        'goes into `scripts/<agent>-<purpose>-<yyyyMMdd-HHmmss>.ps1` (unique name, never reused)' | Should -Match $old
        foreach ($k in $script:IAgents.Keys) { $script:IAgents[$k] | Should -Not -Match $old -Because $k }
        [IO.File]::ReadAllText((Join-Path $script:I '.github\agent-docs\working-flow-reference.md')) | Should -Not -Match $old
        $script:InstallerText | Should -Not -Match 'scripts/<agent>-<purpose>'
    }

    It 'the shared protocol carries the task folder and the housekeeping line' {
        $flow = [IO.File]::ReadAllText((Join-Path $script:I '.github\agent-docs\working-flow-reference.md'))
        $flow | Should -Match '(?m)^task folder: <path created with Agent-Workspace\.ps1 -NewTask, or none>'
        $flow | Should -Match '(?m)^housekeeping: <temporary files removed'
        $flow | Should -Match '075 previews, 074\s+executes with the approval token the preview prints'
    }

    It 'Maintenance splits housekeeping: 075 previews, 074 executes with a token, 070 never composes one' {
        $a075 = $script:IAgents['075-installer-health-regression.agent.md']
        $a074 = $script:IAgents['074-environment-tooling.agent.md']
        $a070 = $script:IAgents['070-capability-maintenance-team-lead.agent.md']
        $a075 | Should -Match 'Agent-Workspace\.ps1 -Preview'
        $a075 | Should -Match 'You never execute a cleanup'
        $a075 | Should -Match 'Running `-Execute`, `-Restore` or `-Purge`'
        $a074 | Should -Match 'Agent-Workspace\.ps1 -Execute -PlanId <id> -Approval'
        $a074 | Should -Match 'It moves, it never deletes'
        $a074 | Should -Match 'APPROVED:HOUSEKEEPING-PURGE:<id>'
        $a074 | Should -Match 'Deleting or moving workspace files by hand'
        $a070 | Should -Match 'Housekeeping is two separate steps'
        $a070 | Should -Match 'Never compose or shorten a token yourself'
        $a070 | Should -Match '(?m)^3\. \*\*Housekeeping\*\*'
        # No tool was added for this: the grants are the ones of the previous release.
        (Get-GeneratedAgentRecord -Path (Join-Path $script:I '.github\agents\075-installer-health-regression.agent.md')).tools | Should -Not -Contain 'edit'
    }

    It 'ordinary agents only suggest a cleanup; none outside Maintenance is told to run one' {
        foreach ($k in @($script:IAgents.Keys | Where-Object { $_ -notmatch '^07[045]-' })) {
            $script:IAgents[$k] | Should -Not -Match 'Agent-Workspace\.ps1 -(Preview|Execute|Purge|Restore)' -Because "$k is not a housekeeping operator"
        }
    }

    It 'the skill and the helper agree on every approval token' {
        $skill = [IO.File]::ReadAllText((Join-Path $script:I '.github\skills\fabric-housekeeping\SKILL.md'))
        $skill | Should -Match '(?m)^name: fabric-housekeeping\s*$'
        foreach ($token in 'APPROVED:HOUSEKEEPING:<id>', 'APPROVED:HOUSEKEEPING-AMBIGUOUS:<id>:<files>:<bytes>', 'APPROVED:HOUSEKEEPING-SECRET:<id>:<entry id>', 'APPROVED:HOUSEKEEPING-PURGE:<id>') {
            $skill | Should -Match ([regex]::Escape($token))
            $script:HelperSource | Should -Match ([regex]::Escape(($token -replace ':<.*$', ':')))
        }
        $skill | Should -Match 'A git-ignored file is not a protected file'
        $skill | Should -Match 'an\s+agent never writes a token on the user''s behalf'
    }

    It 'Project Osmos keeps its auth files in one ignored place and its Python need is recorded' {
        $script:IAgents['030-data-engineering-team-lead.agent.md'] | Should -Match 'live only in `<workspace root>/\.dataprojects/`'
        $script:IAgents['030-data-engineering-team-lead.agent.md'] | Should -Match 'python\.projectOsmosReady'
        $script:InstallerText | Should -Match "Set-ToolStatus -Key 'python' -Found \`$true[^\r\n]*\r?\n[^\r\n]*-InstallMode 'detect' -Extra @\{ projectOsmosReady = "
        $script:InstallerText | Should -Not -Match "Invoke-OptionalToolPrompt -Key 'python'"
    }
}
