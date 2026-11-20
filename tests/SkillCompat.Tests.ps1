# SkillCompat.Tests.ps1
# -------------------------------------------------------------------
# An upstream skill change never becomes a task for the user. A refreshed vendor catalog
# is accepted only while every skill path the agents pin still resolves; otherwise the
# WHOLE catalog goes back to the commit it was on, or to the commit this kit release was
# validated against. Covers the installer preflight (Invoke-SkillCatalogHold), the
# Maintenance refresh (Invoke-VendorRefreshWithHold) and the emitted Skill-Compat.ps1.
#
# Throwaway local bare repositories stand in for the vendor catalogs -- no network.
# Each rename/deletion/split case has a negative control: without the hold the same
# upstream change leaves an unresolved reference, so the tests can fail.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath

    # Load the real installer code under test without running the installer.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$null, [ref]$null)
    $assignments = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Parent -eq $ast }, $false)
    foreach ($name in 'bt', 'skillAliases') {
        $a = @($assignments | Where-Object { $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Left.VariablePath.UserPath -eq $name }) | Select-Object -First 1
        $a | Should -Not -BeNullOrEmpty -Because "the installer must define `$$name"
        Set-Variable -Scope Script -Name $name -Value (Invoke-Expression $a.Right.Extent.Text)
    }
    foreach ($fnName in 'Get-GitProbe', 'Format-GitProbe', 'Update-VendorClone', 'Test-VendorCloneIdentity', 'Get-VendorCloneHead', 'Restore-VendorClone', 'Get-MissingSkillPins', 'Set-SkillCatalogState',
                        'Invoke-VendorRefreshWithHold', 'Get-SkillContainerDirs', 'Get-UpstreamSkillIndex', 'Resolve-SkillPin', 'Resolve-KnowledgeRef', 'Get-UnresolvedSkillPins', 'Invoke-SkillCatalogHold') {
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true) | Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty -Because "$fnName must exist in the installer"
        Invoke-Expression $fn.Extent.Text
    }

    $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('fabric_skillcompat_' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    New-Item -ItemType Directory -Path $script:Base | Out-Null
    $script:SavedGitEnv = @{}
    foreach ($n in 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL') { $script:SavedGitEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
    $env:GIT_AUTHOR_NAME = 'test'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 'test'; $env:GIT_COMMITTER_EMAIL = 't@t'
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:Catalog = 'skills-for-fabric'

    # What the agents pin in these scenarios: a skill folder, a reference file inside
    # another skill (advisory) and a shared common file.
    $script:Refs = @("$script:Catalog/skills/alpha", "$script:Catalog/skills/beta/references/guide.md", "$script:Catalog/common/COMMON.md")
    $script:UnknownSha = 'f' * 40

    function Add-SkillFile([string]$Dir, [string]$Rel) {
        $p = Join-Path $Dir $Rel
        New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($p, "---`nname: $(Split-Path (Split-Path $p -Parent) -Leaf)`ndescription: test`n---`n", $script:Utf8)
    }
    # One "vendor" repository (bare upstream + a work tree to publish from) and a workspace
    # root holding the installed clone at the first commit.
    function New-CatalogScenario([string]$Tag) {
        $dir = Join-Path $script:Base ($Tag + '_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $up = Join-Path $dir 'upstream.git'; $work = Join-Path $dir 'work'; $root = Join-Path $dir 'root'
        New-Item -ItemType Directory -Path $dir, $root | Out-Null
        & git init --bare -q $up 2>$null
        & git clone -q $up $work 2>$null
        foreach ($f in 'skills\alpha\SKILL.md', 'skills\beta\SKILL.md', 'skills\beta\references\guide.md', 'common\COMMON.md') { Add-SkillFile $work $f }
        & git -C $work add -A 2>$null; & git -C $work commit -q -m v1 2>$null; & git -C $work push -q origin HEAD 2>$null
        $clone = Join-Path $root $script:Catalog
        & git clone -q $up $clone 2>$null
        return [pscustomobject]@{ Root = $root; Upstream = $up; Work = $work; Clone = $clone; V1 = [string](& git -C $work rev-parse HEAD 2>$null) }
    }
    function Publish-Upstream($S, [scriptblock]$Change, [string]$Message = 'upstream change') {
        & $Change $S.Work
        & git -C $S.Work add -A 2>$null; & git -C $S.Work commit -q -m $Message 2>$null; & git -C $S.Work push -q origin HEAD 2>$null
        return [string](& git -C $S.Work rev-parse HEAD 2>$null)
    }
    function Get-CloneHead($S) { return [string](& git -C $S.Clone rev-parse HEAD 2>$null) }
    function Set-ResolverScope($S) {
        $script:rootPath = $S.Root
        $script:upstreamSkillIndex = @(Get-UpstreamSkillIndex -RootPath $S.Root)
        $script:UnresolvedKnowledgeRefs = [ordered]@{}
        $script:AdvisoryKnowledgeRefs = [ordered]@{}
    }
    # The installer sequence: remember the commit, refresh to upstream, then the preflight.
    function Invoke-InstallerPreflight($S, [string]$Approved, [string[]]$Refs = $script:Refs, [switch]$Fresh) {
        $before = @{}
        if (-not $Fresh) { $before[$script:Catalog] = Get-VendorCloneHead $S.Clone $S.Upstream }
        Update-VendorClone $S.Clone $script:Catalog -ExpectedRemote $S.Upstream 6>$null
        Set-ResolverScope $S
        $catalogs = [ordered]@{ $script:Catalog = @{ remote = $S.Upstream; approved = $Approved } }
        return (Invoke-SkillCatalogHold -RootPath $S.Root -Refs $Refs -Before $before -Catalogs $catalogs)
    }
    # The state file the installer writes next to the generated agents.
    function Set-TestPinState($S, [object[]]$Pins = $null) {
        if (-not $Pins) {
            $Pins = @(
                [ordered]@{ path = "$script:Catalog/skills/alpha"; critical = $true }
                [ordered]@{ path = "$script:Catalog/skills/beta"; critical = $true }
                [ordered]@{ path = "$script:Catalog/skills/beta/references/guide.md"; critical = $false }
                [ordered]@{ path = "$script:Catalog/common/COMMON.md"; critical = $true }
            )
        }
        $dir = Join-Path $S.Root '.github\agent-docs'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $state = [ordered]@{ schemaVersion = 1; productVersion = 'test'; catalogs = [ordered]@{}; pins = @($Pins) }
        [IO.File]::WriteAllText((Join-Path $dir 'skill-catalog-state.json'), ($state | ConvertTo-Json -Depth 6), $script:Utf8)
    }
    function Get-TestState($S) { return ([IO.File]::ReadAllText((Join-Path $S.Root '.github\agent-docs\skill-catalog-state.json')) | ConvertFrom-Json) }
    function Invoke-MaintenanceRefresh($S, [string]$Approved) {
        $script:vendorCatalogs = [ordered]@{ $script:Catalog = @{ remote = $S.Upstream; approved = $Approved } }
        return (Invoke-VendorRefreshWithHold $S.Root $script:Catalog)
    }
}

AfterAll {
    foreach ($n in $script:SavedGitEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $script:SavedGitEnv[$n], 'Process') }
    if ($script:Base -and (Test-Path -LiteralPath $script:Base)) { Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Installer preflight accepts a compatible upstream (SK-02, SK-03)' {

    It 'takes upstream HEAD when a new skill was added' {
        $s = New-CatalogScenario 'newskill'
        $v2 = Publish-Upstream $s { param($w) Add-SkillFile $w 'skills\gamma\SKILL.md' }
        $r = Invoke-InstallerPreflight $s $s.V1
        $r[$script:Catalog].state | Should -Be 'upstream'
        $r[$script:Catalog].commit | Should -Be $v2
        Get-CloneHead $s | Should -Be $v2
        Test-Path -LiteralPath (Join-Path $s.Clone 'skills\gamma\SKILL.md') | Should -BeTrue -Because 'new upstream skills arrive without a hold'
    }

    It 'takes upstream HEAD when only a reference file inside a pinned skill moved, and points the agent at the skill' {
        $s = New-CatalogScenario 'refmoved'
        $v2 = Publish-Upstream $s { param($w) New-Item -ItemType Directory -Path (Join-Path $w 'skills\beta\docs') | Out-Null; Move-Item -LiteralPath (Join-Path $w 'skills\beta\references\guide.md') -Destination (Join-Path $w 'skills\beta\docs\guide.md') }
        $r = Invoke-InstallerPreflight $s $s.V1
        $r[$script:Catalog].state | Should -Be 'upstream' -Because 'a reference file is advisory'
        Get-CloneHead $s | Should -Be $v2
        Resolve-KnowledgeRef "$script:Catalog/skills/beta/references/guide.md" | Should -Match "^``$script:Catalog/skills/beta`` \*\(its reference file ``guide\.md`` is not at the pinned path"
        @($script:UnresolvedKnowledgeRefs.Keys).Count | Should -Be 0
    }

    It 'reports a catalog that is not cloned as absent and does nothing' {
        $s = New-CatalogScenario 'absent'
        Set-ResolverScope $s
        $r = Invoke-SkillCatalogHold -RootPath $s.Root -Refs @('power-bi-agentic-development/plugins/x/skills/y') -Before @{} -Catalogs ([ordered]@{ 'power-bi-agentic-development' = @{ remote = $s.Upstream; approved = $s.V1 } })
        $r['power-bi-agentic-development'].state | Should -Be 'absent'
        Test-Path -LiteralPath (Join-Path $s.Root 'power-bi-agentic-development') | Should -BeFalse
    }
}

Describe 'Installer preflight holds an incompatible upstream at the last compatible commit (SK-04, SK-05)' {

    It 'holds the catalog when upstream <Name>' -TestCases @(
        @{ Name = 'renames a pinned skill folder'; Change = { param($w) Rename-Item -LiteralPath (Join-Path $w 'skills\alpha') -NewName 'alpha-renamed' } }
        @{ Name = 'deletes a pinned skill folder'; Change = { param($w) Remove-Item -LiteralPath (Join-Path $w 'skills\alpha') -Recurse -Force } }
        @{ Name = 'splits a pinned skill into two new skills'; Change = { param($w) Remove-Item -LiteralPath (Join-Path $w 'skills\alpha') -Recurse -Force; Add-SkillFile $w 'skills\alpha-read\SKILL.md'; Add-SkillFile $w 'skills\alpha-write\SKILL.md' } }
        @{ Name = 'deletes the skill that holds a pinned reference file'; Change = { param($w) Remove-Item -LiteralPath (Join-Path $w 'skills\beta') -Recurse -Force } }
        @{ Name = 'deletes a pinned shared common file'; Change = { param($w) Remove-Item -LiteralPath (Join-Path $w 'common\COMMON.md') -Force } }
    ) {
        $s = New-CatalogScenario 'hold'
        $v2 = Publish-Upstream $s $Change
        $r = Invoke-InstallerPreflight $s $script:UnknownSha
        $e = $r[$script:Catalog]
        $e.state | Should -Be 'held'
        $e.commit | Should -Be $s.V1 -Because 'the commit the clone was on before this run is tried first'
        $e.upstreamCommit | Should -Be $v2 -Because 'the rejected upstream commit is recorded for the maintainer'
        $e.checkedBy | Should -Be 'installer'
        Get-CloneHead $s | Should -Be $s.V1
        @(& git -C $s.Clone status --porcelain 2>$null) | Should -BeNullOrEmpty -Because 'the clone is exactly one commit, not a mix'
        @(Get-UnresolvedSkillPins $script:Refs) | Should -BeNullOrEmpty
        foreach ($ref in $script:Refs) { Resolve-KnowledgeRef $ref | Should -BeExactly "``$ref``" -Because 'the agents get the same references as before, with no marker' }
    }

    It 'NEGATIVE CONTROL: without the hold, the same rename leaves an unresolved reference and no guessed substitute' {
        $s = New-CatalogScenario 'nohold'
        $null = Publish-Upstream $s { param($w) Rename-Item -LiteralPath (Join-Path $w 'skills\alpha') -NewName 'alpha-renamed' }
        Update-VendorClone $s.Clone $script:Catalog -ExpectedRemote $s.Upstream 6>$null
        Set-ResolverScope $s
        @(Get-UnresolvedSkillPins $script:Refs) | Should -Be @("$script:Catalog/skills/alpha")
        $r = Resolve-KnowledgeRef "$script:Catalog/skills/alpha"
        $r | Should -Match 'not present at install time - not resolved; never substitute'
        $r | Should -Not -Match 'alpha-renamed'
    }

    It 'holds the whole catalog: skills added by the rejected commit are not kept' {
        $s = New-CatalogScenario 'whole'
        $null = Publish-Upstream $s { param($w) Remove-Item -LiteralPath (Join-Path $w 'skills\alpha') -Recurse -Force; Add-SkillFile $w 'skills\gamma\SKILL.md' }
        $r = Invoke-InstallerPreflight $s $script:UnknownSha
        $r[$script:Catalog].state | Should -Be 'held'
        Test-Path -LiteralPath (Join-Path $s.Clone 'skills\gamma') | Should -BeFalse -Because 'versions are never mixed per skill'
        Test-Path -LiteralPath (Join-Path $s.Clone 'skills\alpha\SKILL.md') | Should -BeTrue
    }

    It 'falls back to the approved commit on a first install against an incompatible upstream' {
        $s = New-CatalogScenario 'fresh'
        $v2 = Publish-Upstream $s { param($w) Remove-Item -LiteralPath (Join-Path $w 'skills\alpha') -Recurse -Force }
        $r = Invoke-InstallerPreflight $s $s.V1 -Fresh
        $r[$script:Catalog].state | Should -Be 'held'
        $r[$script:Catalog].commit | Should -Be $s.V1
        $r[$script:Catalog].approvedCommit | Should -Be $s.V1
        $r[$script:Catalog].upstreamCommit | Should -Be $v2
        Get-CloneHead $s | Should -Be $s.V1
    }

    It 'uses the approved commit when the previous commit cannot satisfy the pins either' {
        $s = New-CatalogScenario 'approved'
        $refs = @($script:Refs + "$script:Catalog/skills/delta")
        $v2 = Publish-Upstream $s { param($w) Add-SkillFile $w 'skills\delta\SKILL.md' } 'v2 adds delta'
        $null = Publish-Upstream $s { param($w) Remove-Item -LiteralPath (Join-Path $w 'skills\alpha') -Recurse -Force } 'v3 drops alpha'
        # The clone starts on v1 (no delta), upstream is v3 (no alpha); only v2 has both.
        $r = Invoke-InstallerPreflight $s $v2 -Refs $refs
        $r[$script:Catalog].state | Should -Be 'held'
        $r[$script:Catalog].commit | Should -Be $v2
        Get-CloneHead $s | Should -Be $v2
        @(Get-UnresolvedSkillPins $refs) | Should -BeNullOrEmpty
    }

    It 'reports incompatible and stays on upstream when no known commit satisfies the pins' {
        $s = New-CatalogScenario 'incompat'
        $refs = @($script:Refs + "$script:Catalog/skills/never-existed")
        $v2 = Publish-Upstream $s { param($w) Add-SkillFile $w 'skills\gamma\SKILL.md' }
        $r = Invoke-InstallerPreflight $s $s.V1 -Refs $refs
        $r[$script:Catalog].state | Should -Be 'incompatible'
        $r[$script:Catalog].commit | Should -Be $v2
        Get-CloneHead $s | Should -Be $v2 -Because 'a failed search must not leave the clone on an arbitrary older commit'
        Resolve-KnowledgeRef "$script:Catalog/skills/never-existed" | Should -Match 'not resolved; never substitute' -Because 'the agent is told, and continues with its other skills'
        Resolve-KnowledgeRef "$script:Catalog/skills/alpha" | Should -BeExactly "``$script:Catalog/skills/alpha``"
    }

    It 'reports incompatible when the approved commit is not in the clone' {
        $s = New-CatalogScenario 'noapproved'
        $v2 = Publish-Upstream $s { param($w) Remove-Item -LiteralPath (Join-Path $w 'skills\alpha') -Recurse -Force }
        $r = Invoke-InstallerPreflight $s $script:UnknownSha -Fresh
        $r[$script:Catalog].state | Should -Be 'incompatible'
        Get-CloneHead $s | Should -Be $v2
    }
}

Describe 'The hold never acts on anything but the vendor clone' {

    It 'leaves a vendor-named folder inside the workspace repository alone (unmanaged)' {
        $s = New-CatalogScenario 'outer'
        $outer = Join-Path (Split-Path $s.Root -Parent) 'outer-root'
        New-Item -ItemType Directory -Path $outer | Out-Null
        & git -C $outer init -q 2>$null
        & git -C $outer remote add origin $s.Upstream 2>$null
        [IO.File]::WriteAllText((Join-Path $outer 'user-work.txt'), 'precious')
        & git -C $outer add -A 2>$null; & git -C $outer commit -q -m 'user commit' 2>$null
        $outerHead = [string](& git -C $outer rev-parse HEAD 2>$null)
        # A plain copy of the catalog (no .git) that lacks a pinned skill, plus uncommitted user work.
        Add-SkillFile $outer "$script:Catalog\skills\beta\SKILL.md"
        [IO.File]::WriteAllText((Join-Path $outer 'uncommitted.txt'), 'in progress')
        $script:rootPath = $outer
        $script:upstreamSkillIndex = @(Get-UpstreamSkillIndex -RootPath $outer)
        $r = Invoke-SkillCatalogHold -RootPath $outer -Refs $script:Refs -Before @{ $script:Catalog = $s.V1 } -Catalogs ([ordered]@{ $script:Catalog = @{ remote = $s.Upstream; approved = $s.V1 } })
        $r[$script:Catalog].state | Should -Be 'unmanaged'
        [string](& git -C $outer rev-parse HEAD 2>$null) | Should -Be $outerHead -Because 'the outer repository must never be reset'
        Test-Path -LiteralPath (Join-Path $outer 'uncommitted.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $outer "$script:Catalog\skills\beta\SKILL.md") | Should -BeTrue
        Restore-VendorClone (Join-Path $outer $script:Catalog) $s.V1 $s.Upstream | Should -BeFalse
    }

    It 'refuses a repository whose origin is not the expected vendor remote' {
        $s = New-CatalogScenario 'wrongremote'
        $v2 = Publish-Upstream $s { param($w) Add-SkillFile $w 'skills\gamma\SKILL.md' }
        Update-VendorClone $s.Clone $script:Catalog -ExpectedRemote $s.Upstream 6>$null
        Restore-VendorClone $s.Clone $s.V1 'https://github.com/microsoft/skills-for-fabric.git' | Should -BeFalse
        Get-VendorCloneHead $s.Clone 'https://github.com/microsoft/skills-for-fabric.git' | Should -BeNullOrEmpty
        Get-CloneHead $s | Should -Be $v2
    }

    It 'never moves a clone that has local edits' {
        $s = New-CatalogScenario 'dirty'
        $v2 = Publish-Upstream $s { param($w) Add-SkillFile $w 'skills\gamma\SKILL.md' }
        Update-VendorClone $s.Clone $script:Catalog -ExpectedRemote $s.Upstream 6>$null
        [IO.File]::WriteAllText((Join-Path $s.Clone 'skills\alpha\SKILL.md'), 'my local edit')
        Restore-VendorClone $s.Clone $s.V1 $s.Upstream | Should -BeFalse
        Get-CloneHead $s | Should -Be $v2
        [IO.File]::ReadAllText((Join-Path $s.Clone 'skills\alpha\SKILL.md')) | Should -Be 'my local edit'
    }

    It 'refuses an unknown commit and an empty commit' {
        $s = New-CatalogScenario 'badsha'
        Restore-VendorClone $s.Clone $script:UnknownSha $s.Upstream | Should -BeFalse
        Restore-VendorClone $s.Clone '' $s.Upstream | Should -BeFalse
        Get-CloneHead $s | Should -Be $s.V1
    }
}

Describe 'Maintenance refresh applies the same rule against the recorded paths (SK-06)' {

    It 'refreshes to upstream when every recorded critical path survives' {
        $s = New-CatalogScenario 'm-ok'; Set-TestPinState $s
        $v2 = Publish-Upstream $s { param($w) Add-SkillFile $w 'skills\gamma\SKILL.md' }
        $r = Invoke-MaintenanceRefresh $s $s.V1
        $r.status | Should -Be 'refreshed'
        $r.commit | Should -Be $v2
        Get-CloneHead $s | Should -Be $v2
        $st = Get-TestState $s
        $st.catalogs.$($script:Catalog).state | Should -Be 'upstream'
        $st.catalogs.$($script:Catalog).checkedBy | Should -Be 'maintenance'
        @($st.pins).Count | Should -Be 4 -Because 'the recorded pins are never rewritten by Maintenance'
    }

    It 'reports current when upstream did not move' {
        $s = New-CatalogScenario 'm-current'; Set-TestPinState $s
        $r = Invoke-MaintenanceRefresh $s $s.V1
        $r.status | Should -Be 'current'
        Get-CloneHead $s | Should -Be $s.V1
    }

    It 'holds when upstream <Name>, with nothing left for the user to do' -TestCases @(
        @{ Name = 'renamed a pinned skill'; Change = { param($w) Rename-Item -LiteralPath (Join-Path $w 'skills\alpha') -NewName 'alpha-renamed' } }
        @{ Name = 'deleted a pinned skill'; Change = { param($w) Remove-Item -LiteralPath (Join-Path $w 'skills\alpha') -Recurse -Force } }
        @{ Name = 'split a pinned skill'; Change = { param($w) Remove-Item -LiteralPath (Join-Path $w 'skills\alpha') -Recurse -Force; Add-SkillFile $w 'skills\alpha-read\SKILL.md'; Add-SkillFile $w 'skills\alpha-write\SKILL.md' } }
        @{ Name = 'deleted the skill behind an advisory reference file'; Change = { param($w) Remove-Item -LiteralPath (Join-Path $w 'skills\beta') -Recurse -Force } }
    ) {
        $s = New-CatalogScenario 'm-hold'; Set-TestPinState $s
        $v2 = Publish-Upstream $s $Change
        $r = Invoke-MaintenanceRefresh $s $script:UnknownSha
        $r.status | Should -Be 'held'
        $r.commit | Should -Be $s.V1
        $r.upstream | Should -Be $v2
        @($r.missing).Count | Should -BeGreaterThan 0
        Get-CloneHead $s | Should -Be $s.V1
        @(Get-MissingSkillPins $s.Root) | Should -BeNullOrEmpty -Because 'every path the generated agents carry is on disk again'
        $st = Get-TestState $s
        $st.catalogs.$($script:Catalog).state | Should -Be 'held'
        $st.catalogs.$($script:Catalog).commit | Should -Be $s.V1
        $st.catalogs.$($script:Catalog).upstreamCommit | Should -Be $v2
        @($st.pins).Count | Should -Be 4
    }

    It 'NEGATIVE CONTROL: the same rename without the recorded pins is a plain refresh (nothing to protect)' {
        $s = New-CatalogScenario 'm-nostate'
        $v2 = Publish-Upstream $s { param($w) Rename-Item -LiteralPath (Join-Path $w 'skills\alpha') -NewName 'alpha-renamed' }
        $r = Invoke-MaintenanceRefresh $s $s.V1
        $r.status | Should -Be 'refreshed'
        Get-CloneHead $s | Should -Be $v2
        Test-Path -LiteralPath (Join-Path $s.Clone 'skills\alpha') | Should -BeFalse
    }

    It 'stays held on the same commit while upstream is still incompatible, then releases the hold by itself' {
        $s = New-CatalogScenario 'm-release'; Set-TestPinState $s
        $null = Publish-Upstream $s { param($w) Rename-Item -LiteralPath (Join-Path $w 'skills\alpha') -NewName 'alpha-renamed' }
        (Invoke-MaintenanceRefresh $s $script:UnknownSha).status | Should -Be 'held'
        $again = Invoke-MaintenanceRefresh $s $script:UnknownSha
        $again.status | Should -Be 'held'
        $again.commit | Should -Be $s.V1
        Get-CloneHead $s | Should -Be $s.V1
        # Upstream brings the skill back (or the kit adds an alias and is re-installed): the next refresh goes through.
        $v3 = Publish-Upstream $s { param($w) Add-SkillFile $w 'skills\alpha\SKILL.md' } 'v3 restores alpha'
        $after = Invoke-MaintenanceRefresh $s $script:UnknownSha
        $after.status | Should -Be 'refreshed'
        Get-CloneHead $s | Should -Be $v3
        (Get-TestState $s).catalogs.$($script:Catalog).state | Should -Be 'upstream'
    }

    It 'does not hold for an advisory reference file that moved' {
        $s = New-CatalogScenario 'm-advisory'; Set-TestPinState $s
        $v2 = Publish-Upstream $s { param($w) Remove-Item -LiteralPath (Join-Path $w 'skills\beta\references\guide.md') -Force }
        $r = Invoke-MaintenanceRefresh $s $s.V1
        $r.status | Should -Be 'refreshed'
        Get-CloneHead $s | Should -Be $v2
    }

    It 'falls back to the approved commit when the pre-refresh commit lacks a recorded path too' {
        $s = New-CatalogScenario 'm-approved'
        $v2 = Publish-Upstream $s { param($w) Add-SkillFile $w 'skills\delta\SKILL.md' } 'v2 adds delta'
        $null = Publish-Upstream $s { param($w) Remove-Item -LiteralPath (Join-Path $w 'skills\alpha') -Recurse -Force } 'v3 drops alpha'
        Set-TestPinState $s @([ordered]@{ path = "$script:Catalog/skills/alpha"; critical = $true }, [ordered]@{ path = "$script:Catalog/skills/delta"; critical = $true })
        $r = Invoke-MaintenanceRefresh $s $v2
        $r.status | Should -Be 'held'
        $r.commit | Should -Be $v2
        Get-CloneHead $s | Should -Be $v2
    }

    It 'reports incompatible and stays on upstream when no known commit has every recorded path' {
        $s = New-CatalogScenario 'm-incompat'
        Set-TestPinState $s @([ordered]@{ path = "$script:Catalog/skills/alpha"; critical = $true }, [ordered]@{ path = "$script:Catalog/skills/never-existed"; critical = $true })
        $v2 = Publish-Upstream $s { param($w) Add-SkillFile $w 'skills\gamma\SKILL.md' }
        $r = Invoke-MaintenanceRefresh $s $script:UnknownSha
        $r.status | Should -Be 'incompatible'
        @($r.missing) | Should -Be @("$script:Catalog/skills/never-existed")
        Get-CloneHead $s | Should -Be $v2
        (Get-TestState $s).catalogs.$($script:Catalog).state | Should -Be 'incompatible'
    }

    It 'skips a folder that is not the vendor repository and writes no state' {
        $s = New-CatalogScenario 'm-skip'; Set-TestPinState $s
        $before = [IO.File]::ReadAllText((Join-Path $s.Root '.github\agent-docs\skill-catalog-state.json'))
        $script:vendorCatalogs = [ordered]@{ $script:Catalog = @{ remote = 'https://github.com/microsoft/skills-for-fabric.git'; approved = $s.V1 } }
        $r = Invoke-VendorRefreshWithHold $s.Root $script:Catalog
        $r.status | Should -Be 'skipped'
        $r.detail | Should -Match 'left untouched'
        Get-CloneHead $s | Should -Be $s.V1
        [IO.File]::ReadAllText((Join-Path $s.Root '.github\agent-docs\skill-catalog-state.json')) | Should -BeExactly $before
        (Invoke-VendorRefreshWithHold $s.Root 'not-a-catalog').status | Should -Be 'skipped'
    }

    It 'keeps local edits in a named stash and says so in the notes' {
        $s = New-CatalogScenario 'm-stash'; Set-TestPinState $s
        $null = Publish-Upstream $s { param($w) Add-SkillFile $w 'skills\gamma\SKILL.md' }
        [IO.File]::WriteAllText((Join-Path $s.Clone 'skills\alpha\SKILL.md'), 'my local edit')
        $r = Invoke-MaintenanceRefresh $s $s.V1
        $r.status | Should -Be 'refreshed'
        (@($r.notes) -join ' ') | Should -Match 'stashed before refresh'
        (& git -C $s.Clone stash list 2>$null) | Should -Match 'installer-autostash'
    }
}

Describe 'Emitted Skill-Compat.ps1 is the installer''s own code and runs on its own' {

    BeforeAll {
        # A generated workspace whose Microsoft catalog is a real (local) Git repository.
        $script:E2E = Join-Path $script:Base 'e2e-root'
        New-Item -ItemType Directory -Path $script:E2E | Out-Null
        New-SkillCatalogFixture -Root $script:E2E
        $script:E2EUp = Join-Path $script:Base 'e2e-upstream.git'
        $script:E2ECat = Join-Path $script:E2E $script:Catalog
        & git init --bare -q $script:E2EUp 2>$null
        & git -C $script:E2ECat init -q 2>$null
        & git -C $script:E2ECat add -A 2>$null; & git -C $script:E2ECat commit -q -m v1 2>$null
        & git -C $script:E2ECat remote add origin $script:E2EUp 2>$null
        & git -C $script:E2ECat push -q -u origin HEAD 2>$null
        $script:E2EV1 = [string](& git -C $script:E2ECat rev-parse HEAD 2>$null)

        $out = & cmd /c ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $script:E2E) 2>&1
        $script:E2EEmitExit = $LASTEXITCODE
        $script:E2EEmitOut = ($out | Out-String)
        $script:Helper = Join-Path $script:E2E '.github\agent-docs\Skill-Compat.ps1'
        $script:E2EStatePath = Join-Path $script:E2E '.github\agent-docs\skill-catalog-state.json'
        $script:E2EState = if (Test-Path -LiteralPath $script:E2EStatePath) { [IO.File]::ReadAllText($script:E2EStatePath) | ConvertFrom-Json } else { $null }

        # Driver: dot-source the emitted helper only, point it at the local "vendor" remote, refresh.
        $script:Driver = Join-Path $script:Base 'e2e-driver.ps1'
        [IO.File]::WriteAllText($script:Driver, @'
param([string]$Helper, [string]$Root, [string]$Remote, [string]$Approved)
. $Helper
$vendorCatalogs = [ordered]@{ 'skills-for-fabric' = @{ remote = $Remote; approved = $Approved } }
Invoke-VendorRefreshWithHold $Root 'skills-for-fabric' | ConvertTo-Json -Depth 4 -Compress
'@, $script:Utf8)
        function Invoke-E2ERefresh {
            $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Driver -Helper $script:Helper -Root $script:E2E -Remote $script:E2EUp -Approved ('f' * 40) 2>&1
            return ((@($raw | ForEach-Object { [string]$_ } | Where-Object { $_ -like '{*' }) | Select-Object -Last 1) | ConvertFrom-Json)
        }
    }

    It 'the installer emits the helper and records the pinned paths of the generated agents' {
        $script:E2EEmitExit | Should -Be 0 -Because $script:E2EEmitOut
        Test-Path -LiteralPath $script:Helper | Should -BeTrue
        $script:E2EState | Should -Not -BeNullOrEmpty
        $script:E2EState.schemaVersion | Should -Be 1
        $critical = @($script:E2EState.pins | Where-Object { $_.critical })
        $critical.Count | Should -BeGreaterThan 30
        @($script:E2EState.pins | Where-Object { -not $_.critical }).Count | Should -BeGreaterThan 0 -Because 'reference files inside a skill are recorded as advisory'
        foreach ($p in @($script:E2EState.pins | Where-Object { -not $_.critical })) {
            $p.path | Should -Match '/skills/[^/]+/.+' -Because 'only a file inside a skill folder is advisory'
            $holder = [regex]::Match([string]$p.path, '^(.+?/skills/[^/]+)/').Groups[1].Value
            (@($critical | ForEach-Object { $_.path }) -contains $holder) | Should -BeTrue -Because "the skill folder of $($p.path) must be critical"
        }
        foreach ($p in $critical) { Test-Path -LiteralPath (Join-Path $script:E2E (([string]$p.path) -replace '/', '\')) | Should -BeTrue -Because "$($p.path) is what the agents were generated against" }
    }

    It 'parses, defines every shared function with the installer''s exact body and has no side effect when dot-sourced' {
        $errs = $null
        $helperAst = [System.Management.Automation.Language.Parser]::ParseFile($script:Helper, [ref]$null, [ref]$errs)
        @($errs).Count | Should -Be 0
        $installerAst = [System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$null, [ref]$null)
        # Compare the statements, not the declaration style (the helper re-declares each function with a param block).
        $statementsOf = {
            param($tree, $name)
            $f = $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
            if (-not $f -or -not $f.Body.EndBlock) { return $null }
            return ((@($f.Body.EndBlock.Statements | ForEach-Object { $_.Extent.Text }) -join "`n") -replace '\s+', ' ').Trim()
        }
        foreach ($fnName in 'ConvertFrom-JsonLenient', 'Find-JsonObjectEnd', 'Find-LineCommentStart', 'Add-JsonMemberBeforeClose', 'Update-UserSettingsInPlace', 'Get-GitProbe', 'Format-GitProbe', 'Update-VendorClone',
                            'Test-VendorCloneIdentity', 'Get-VendorCloneHead', 'Restore-VendorClone', 'Get-MissingSkillPins', 'Set-SkillCatalogState', 'Invoke-VendorRefreshWithHold') {
            $mine = & $statementsOf $helperAst $fnName
            $mine | Should -Not -BeNullOrEmpty -Because "$fnName must be shipped in the helper"
            $mine | Should -BeExactly (& $statementsOf $installerAst $fnName) -Because "$fnName must be the installer's code, not a copy that can drift"
        }
        $probe = Join-Path $script:Base 'e2e-probe.ps1'
        [IO.File]::WriteAllText($probe, "`$root = 'keep-root'; `$ErrorActionPreference = 'Stop'`n. '$($script:Helper)'`n`"root=`$root eap=`$ErrorActionPreference catalogs=`$(@(`$vendorCatalogs.Keys) -join ',') fn=`$([bool](Get-Command Invoke-VendorRefreshWithHold -ErrorAction SilentlyContinue))`"`n", $script:Utf8)
        $line = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe 2>&1 | Out-String).Trim()
        $line | Should -Be 'root=keep-root eap=Stop catalogs=skills-for-fabric,power-bi-agentic-development fn=True'
    }

    It 'carries the approved commits and remotes of the installer' {
        $t = [IO.File]::ReadAllText($script:Helper)
        $snap = Get-SkillCatalogSnapshot
        foreach ($src in @($snap.sources)) { $t | Should -Match ("'" + [regex]::Escape([string]$src.path) + "' = @\{ remote = 'https://github\.com/[^']+\.git'; approved = '" + [regex]::Escape([string]$src.commit) + "' \}") }
    }

    It 'the documented command leaves a folder that is not the vendor repository untouched (offline, exit 0)' {
        Push-Location $script:E2E
        try { $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.github/agent-docs/Skill-Compat.ps1' -RefreshCatalogs 2>&1 | Out-String; $code = $LASTEXITCODE }
        finally { Pop-Location }
        $code | Should -Be 0
        $out | Should -Match '(?m)^SKILLS REFRESH\s*$'
        $out | Should -Match '(?m)^skills-for-fabric: skipped - folder is missing or is not the vendor repository - left untouched'
        $out | Should -Match '(?m)^power-bi-agentic-development: skipped - '
        [string](& git -C $script:E2ECat rev-parse HEAD 2>$null) | Should -Be $script:E2EV1
        [IO.File]::ReadAllText($script:E2EStatePath) | Should -Match '"catalogs":\s*\{\s*\}' -Because 'a skipped catalog records nothing'
    }

    It 'END TO END: upstream deletes a skill the generated agents pin; the emitted helper holds the catalog' {
        $victim = [string](@($script:E2EState.pins | Where-Object { $_.critical -and $_.path -match "^$script:Catalog/skills/[^/]+$" }) | Select-Object -First 1).path
        $victim | Should -Not -BeNullOrEmpty
        $victimRel = ($victim.Substring($script:Catalog.Length + 1)) -replace '/', '\'
        $agentsBefore = @(Get-ChildItem -LiteralPath (Join-Path $script:E2E '.github\agents') -Filter '*.agent.md' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $agentsBefore | Should -Match ([regex]::Escape($victim)) -Because 'a generated agent really references this skill'

        $work = Join-Path $script:Base 'e2e-work'
        & git clone -q $script:E2EUp $work 2>$null
        Remove-Item -LiteralPath (Join-Path $work $victimRel) -Recurse -Force
        & git -C $work add -A 2>$null; & git -C $work commit -q -m 'upstream removes a skill' 2>$null; & git -C $work push -q origin HEAD 2>$null
        $v2 = [string](& git -C $work rev-parse HEAD 2>$null)

        $r = Invoke-E2ERefresh
        $r.status | Should -Be 'held'
        $r.commit | Should -Be $script:E2EV1
        $r.upstream | Should -Be $v2
        @($r.missing) | Should -Be @($victim)
        [string](& git -C $script:E2ECat rev-parse HEAD 2>$null) | Should -Be $script:E2EV1
        Test-Path -LiteralPath (Join-Path $script:E2ECat "$victimRel\SKILL.md") | Should -BeTrue -Because 'the agents keep a working reference'
        $st = [IO.File]::ReadAllText($script:E2EStatePath) | ConvertFrom-Json
        $st.catalogs.'skills-for-fabric'.state | Should -Be 'held'
        @($st.pins).Count | Should -Be @($script:E2EState.pins).Count
        $agentsAfter = @(Get-ChildItem -LiteralPath (Join-Path $script:E2E '.github\agents') -Filter '*.agent.md' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $agentsAfter | Should -BeExactly $agentsBefore -Because 'Maintenance never rewrites agents and never needs to'

        # A second run is stable, and -VerifyRoot still passes: the state file is not a hashed managed file.
        (Invoke-E2ERefresh).status | Should -Be 'held'
        & cmd /c ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -VerifyRoot "{1}" < NUL' -f $script:Installer, $script:E2E) 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}
