# SkillMap.Tests.ps1
# -------------------------------------------------------------------
# v0.8.0 skill-mapping regression guard. Pinned upstream skill references resolve against
# the recorded catalog snapshot (or a verified alias); retired names do not come back;
# renames are never guessed from similar folder names; keyword suggestions stay
# reference-only; and the generated organisation (identities, tools, hierarchy, write
# permissions, the PBIVIZ team) matches tests/fixtures/agent-baseline.json.
#
# The vendor catalogs are stood in by a fixture built from
# tests/fixtures/skill-catalog.snapshot.json (identifiers only, no upstream text). The
# live-catalog check runs only when FABRIC_AGENTIC_CATALOG_ROOT points at a workspace
# with real clones; otherwise it is reported as SKIPPED, never as passed.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $script:InstallerText = [IO.File]::ReadAllText($script:Installer)
    $script:Snapshot = Get-SkillCatalogSnapshot
    $script:Baseline = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\agent-baseline.json')) | ConvertFrom-Json
    $script:Prefix = @{ MS = 'skills-for-fabric/skills'; MC = 'skills-for-fabric/common'; KP = 'power-bi-agentic-development/plugins'; CS = '.github/skills'; AD = '.github/agent-docs' }
    $script:Retired = @('onelake-catalog-govern-cli', 'fabriciq-ontology-cli', 'standardize-naming-conventions')
    $script:Pins = @([regex]::Matches($script:InstallerText, 'ref = "\$(MS|MC|KP|CS|AD)/([^"]+)"') | ForEach-Object { "$($script:Prefix[$_.Groups[1].Value])/$($_.Groups[2].Value)" })
    $script:UpstreamPins = @($script:Pins | Where-Object { $_ -like 'skills-for-fabric/*' -or $_ -like 'power-bi-agentic-development/*' } | Sort-Object -Unique)
    $script:KnownPaths = @{}
    foreach ($s in @($script:Snapshot.skills)) { $script:KnownPaths[$s] = $true }
    foreach ($p in @($script:Snapshot.paths)) { $script:KnownPaths[$p.path] = $true }

    # Load the installer's resolver tables and functions without running the installer.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$null, [ref]$null)
    $assignments = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Parent -eq $ast }, $false)
    foreach ($name in 'MS', 'MC', 'KP', 'CS', 'AD', 'bt', 'skillAliases', 'agentSkillKeywords', 'autoSuggestExclusions') {
        $a = @($assignments | Where-Object { $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Left.VariablePath.UserPath -eq $name }) | Select-Object -First 1
        $a | Should -Not -BeNullOrEmpty -Because "the installer must define `$$name"
        Set-Variable -Scope Script -Name $name -Value (Invoke-Expression $a.Right.Extent.Text)
    }
    foreach ($fnName in 'Get-SkillContainerDirs', 'Get-UpstreamSkillIndex', 'Get-AutoDiscoveredSkills', 'Resolve-KnowledgeRef', 'Get-SkillReviewCandidates') {
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true) | Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty -Because "$fnName must exist in the installer"
        Invoke-Expression $fn.Extent.Text
    }

    $script:TempRoots = New-Object System.Collections.Generic.List[string]
    function New-TestRoot([string]$Tag) {
        $r = Join-Path ([IO.Path]::GetTempPath()) ("fabric_skillmap_${Tag}_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $r | Out-Null
        $script:TempRoots.Add($r)
        return $r
    }
    function Invoke-Emit([string]$Root) {
        $out = & cmd /c ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $Root) 2>&1
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Output = ($out | Out-String) }
    }
    function Get-AgentHashes([string]$Root) {
        $h = [ordered]@{}
        foreach ($sub in '.github\agents', '.github\skills', '.github\agent-docs') {
            Get-ChildItem -LiteralPath (Join-Path $Root $sub) -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.md', '.ps1' } | Sort-Object FullName | ForEach-Object {
                $h[$_.FullName.Substring($Root.Length)] = Get-Sha256Hex -LiteralPath $_.FullName
            }
        }
        return $h
    }
    function Get-Sha256Hex([string]$LiteralPath) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($LiteralPath)))).Replace('-', '') } finally { $sha.Dispose() }
    }

    # Generated workspace against the fixture catalog (shared by the generated-output tests).
    $script:EmitRoot = New-TestRoot 'emit'
    New-SkillCatalogFixture -Root $script:EmitRoot -Snapshot $script:Snapshot
    $script:Emit = Invoke-Emit $script:EmitRoot
    $script:AgentsDir = Join-Path $script:EmitRoot '.github\agents'
    $script:Records = @{}
    $script:Bodies = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $script:AgentsDir -Filter '*.agent.md' -ErrorAction SilentlyContinue)) {
        $script:Records[$f.Name] = Get-GeneratedAgentRecord -Path $f.FullName
        $script:Bodies[$f.Name] = [IO.File]::ReadAllText($f.FullName)
    }
    $script:FirstHashes = Get-AgentHashes $script:EmitRoot
}

AfterAll {
    foreach ($r in $script:TempRoots) {
        if (Test-Path -LiteralPath $r) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Pinned upstream skill references (V8-01 to V8-03)' {

    It 'every pinned upstream reference exists in the recorded catalog snapshot or follows a verified alias' {
        $script:UpstreamPins.Count | Should -BeGreaterThan 40
        $missing = @($script:UpstreamPins | Where-Object {
            -not $script:KnownPaths.ContainsKey($_) -and -not ($script:skillAliases.Contains($_) -and $script:KnownPaths.ContainsKey([string]$script:skillAliases[$_].to))
        })
        $missing | Should -BeNullOrEmpty -Because 'a pin must resolve to a real upstream skill (refresh the snapshot from a real catalog when pins change)'
    }

    It 'no pin uses a retired upstream skill name' {
        foreach ($old in $script:Retired) {
            @($script:Pins | Where-Object { $_ -like "*/$old" -or $_ -like "*/$old/*" }) | Should -BeNullOrEmpty -Because "$old was removed upstream"
        }
    }

    It 'the six retired-name occurrences are gone; only the verified alias keys still name them' {
        ([regex]::Matches($script:InstallerText, 'onelake-catalog-govern-cli')).Count | Should -Be 1 -Because 'only the $skillAliases key may keep the old name'
        ([regex]::Matches($script:InstallerText, 'fabriciq-ontology-cli')).Count | Should -Be 1 -Because 'only the $skillAliases key may keep the old name'
        ([regex]::Matches($script:InstallerText, 'standardize-naming-conventions')).Count | Should -Be 0 -Because 'the retired Kurt skill has no equivalent and no alias'
    }

    It 'every verified alias points at a skill in the snapshot, and never at fabriciq' {
        $script:skillAliases.Count | Should -BeGreaterThan 0
        foreach ($k in @($script:skillAliases.Keys)) {
            $to = [string]$script:skillAliases[$k].to
            $script:KnownPaths.ContainsKey($to) | Should -BeTrue -Because "alias target $to must exist"
            $to | Should -Not -Match '/fabriciq$'
            [string]$script:skillAliases[$k].source | Should -Not -BeNullOrEmpty -Because 'an alias records the evidence it was verified from'
        }
        $script:skillAliases['skills-for-fabric/skills/fabriciq-ontology-cli'].to | Should -Be 'skills-for-fabric/skills/ontology-cli'
        $script:skillAliases['skills-for-fabric/skills/onelake-catalog-govern-cli'].to | Should -Be 'skills-for-fabric/skills/onelake-catalog-cli'
    }

    It 'every pin resolves in the live vendor catalog (FABRIC_AGENTIC_CATALOG_ROOT)' {
        $live = $env:FABRIC_AGENTIC_CATALOG_ROOT
        if (-not $live -or -not (Test-Path -LiteralPath (Join-Path $live 'skills-for-fabric'))) {
            Set-ItResult -Skipped -Because 'FABRIC_AGENTIC_CATALOG_ROOT does not point at a workspace with cloned vendor catalogs'
            return
        }
        $missing = @($script:UpstreamPins | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $live ($_ -replace '/', '\'))) -and -not ($script:skillAliases.Contains($_) -and (Test-Path -LiteralPath (Join-Path $live (([string]$script:skillAliases[$_].to) -replace '/', '\'))))
        })
        $missing | Should -BeNullOrEmpty -Because "every pin must exist in $live"
    }
}

Describe 'Resolve-KnowledgeRef never guesses a rename (V8-04)' {

    BeforeAll {
        $script:ResolverRoot = New-TestRoot 'resolver'
        foreach ($rel in 'skills-for-fabric\skills\fabriciq', 'skills-for-fabric\skills\ontology-cli', 'skills-for-fabric\skills\spark-cli', 'skills-for-fabric\skills\spark-tools',
                         'skills-for-fabric\skills\widget', 'power-bi-agentic-development\plugins\a\skills\moved-skill', 'power-bi-agentic-development\plugins\b\skills\other',
                         'skills-for-fabric\skills\ms-only-name', 'power-bi-agentic-development\plugins\c\skills\shared-name',
                         'power-bi-agentic-development\plugins\c\skills\fabriciq-ontology-cli',
                         'skills-for-fabric\skills\dual-name', 'power-bi-agentic-development\plugins\a\skills\dual-name',
                         'power-bi-agentic-development\plugins\a\skills\twice', 'power-bi-agentic-development\plugins\b\skills\twice') {
            New-Item -ItemType Directory -Path (Join-Path $script:ResolverRoot $rel) -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $script:ResolverRoot "$rel\SKILL.md"), "---`nname: $(Split-Path $rel -Leaf)`ndescription: test`n---`n")
        }
        $script:rootPath = $script:ResolverRoot
        $script:upstreamSkillIndex = @(Get-UpstreamSkillIndex -RootPath $script:ResolverRoot)
        $script:UnresolvedKnowledgeRefs = [ordered]@{}
    }

    It 'resolves an existing reference unchanged' {
        Resolve-KnowledgeRef 'skills-for-fabric/skills/spark-cli' | Should -BeExactly '`skills-for-fabric/skills/spark-cli`'
    }

    It 'follows a verified alias to the renamed skill' {
        $r = Resolve-KnowledgeRef 'skills-for-fabric/skills/fabriciq-ontology-cli'
        $r | Should -Match '^`skills-for-fabric/skills/ontology-cli` \*\(verified upstream rename'
    }

    It 'never resolves the obsolete Ontology name to fabriciq, even without the alias target' {
        $target = Join-Path $script:ResolverRoot 'skills-for-fabric\skills\ontology-cli'
        Rename-Item -LiteralPath $target -NewName 'ontology-cli.hidden'
        try {
            $script:upstreamSkillIndex = @(Get-UpstreamSkillIndex -RootPath $script:ResolverRoot)
            $r = Resolve-KnowledgeRef 'skills-for-fabric/skills/fabriciq-ontology-cli'
            $r | Should -Not -Match 'skills/fabriciq`'
            $r | Should -Match 'not resolved; never substitute'
        } finally {
            Rename-Item -LiteralPath "$target.hidden" -NewName 'ontology-cli'
            $script:upstreamSkillIndex = @(Get-UpstreamSkillIndex -RootPath $script:ResolverRoot)
        }
    }

    It 'does not substitute a unique sibling that only shares the first name token' {
        $r = Resolve-KnowledgeRef 'skills-for-fabric/skills/widget-maker-cli'
        $r | Should -Not -Match '/widget`'
        $r | Should -Match 'not resolved'
    }

    It 'does not substitute when several siblings share the name stem' {
        $r = Resolve-KnowledgeRef 'skills-for-fabric/skills/spark-authoring-cli'
        $r | Should -Not -Match '/spark-(cli|tools)`'
        $r | Should -Match 'not resolved'
    }

    It 'follows the same skill name into another container (a moved folder, not a rename)' {
        $r = Resolve-KnowledgeRef 'power-bi-agentic-development/plugins/old/skills/moved-skill'
        $r | Should -Match '^`power-bi-agentic-development/plugins/a/skills/moved-skill` \*\(same skill name, moved upstream'
    }

    It 'never relocates a missing Microsoft skill to a same-named Kurt skill' {
        $r = Resolve-KnowledgeRef 'skills-for-fabric/skills/shared-name'
        $r | Should -Not -Match 'power-bi-agentic-development/'
        $r | Should -Match '^`skills-for-fabric/skills/shared-name` \*\(not present at install time - not resolved; never substitute'
    }

    It 'never relocates a missing Kurt skill to a same-named Microsoft skill' {
        $r = Resolve-KnowledgeRef 'power-bi-agentic-development/plugins/old/skills/ms-only-name'
        $r | Should -Not -Match 'skills-for-fabric/'
        $r | Should -Match '^`power-bi-agentic-development/plugins/old/skills/ms-only-name` \*\(not present at install time - not resolved; never substitute'
    }

    It 'relocates within the same provider even when the other provider has the same skill name' {
        $r = Resolve-KnowledgeRef 'power-bi-agentic-development/plugins/old/skills/dual-name'
        $r | Should -Match '^`power-bi-agentic-development/plugins/a/skills/dual-name` \*\(same skill name, moved upstream'
    }

    It 'leaves an ambiguous same-provider relocation unresolved' {
        $r = Resolve-KnowledgeRef 'power-bi-agentic-development/plugins/old/skills/twice'
        $r | Should -Match '^`power-bi-agentic-development/plugins/old/skills/twice` \*\(not present at install time - not resolved'
    }

    It 'a verified alias still wins over a same-named folder of the other provider' {
        $r = Resolve-KnowledgeRef 'skills-for-fabric/skills/fabriciq-ontology-cli'
        $r | Should -Match '^`skills-for-fabric/skills/ontology-cli` \*\(verified upstream rename'
    }

    It 'lists unresolved pins with name-similar review candidates for the maintainer only' {
        $script:UnresolvedKnowledgeRefs.Contains('skills-for-fabric/skills/widget-maker-cli') | Should -BeTrue
        (@(Get-SkillReviewCandidates -Rel 'skills-for-fabric/skills/widget-maker-cli') -contains 'widget') | Should -BeTrue
        (@(Get-SkillReviewCandidates -Rel 'skills-for-fabric/skills/spark-authoring-cli') -contains 'spark-cli') | Should -BeTrue
    }
}

Describe 'Keyword suggestions stay reference-only (V8-04)' {

    BeforeAll {
        $script:rootPath = $script:EmitRoot
        $script:upstreamSkillIndex = @(Get-UpstreamSkillIndex -RootPath $script:EmitRoot)
    }

    It 'the fixture still reproduces the old mismatch when a retired keyword is used (the test can fail)' {
        $saved = $script:agentSkillKeywords
        try {
            $script:agentSkillKeywords = @{ 'probe' = @('onelake', 'operations-cli') }
            $hits = @(Get-AutoDiscoveredSkills -AgentId 'probe' -AlreadyPinned @() | ForEach-Object { $_.skill.rel -replace '^.*/', '' })
            ($hits -contains 'onelake-catalog-cli') | Should -BeTrue
            ($hits -contains 'git-integration-operations-cli') | Should -BeTrue
        } finally { $script:agentSkillKeywords = $saved }
    }

    It 'excluded skills are never suggested to any agent' {
        foreach ($id in @($script:agentSkillKeywords.Keys)) {
            $hits = @(Get-AutoDiscoveredSkills -AgentId $id -AlreadyPinned @() | ForEach-Object { $_.skill.rel -replace '^.*/', '' })
            foreach ($x in $script:autoSuggestExclusions) { ($hits -contains $x) | Should -BeFalse -Because "$id must not be offered $x by keyword" }
        }
    }

    It 'the reported off-target suggestion <Skill> is gone from <File>' -TestCases @(
        @{ File = '032-lakehouse-delta-mlv.agent.md'; Skill = 'hdinsight-migration' }
        @{ File = '032-lakehouse-delta-mlv.agent.md'; Skill = 'onelake-catalog-cli' }
        @{ File = '032-lakehouse-delta-mlv.agent.md'; Skill = 'project-osmos' }
        @{ File = '043-monitoring-catalog-operations.agent.md'; Skill = 'git-integration-operations-cli' }
        @{ File = '030-data-engineering-team-lead.agent.md'; Skill = 'deployment-pipelines-authoring-cli' }
        @{ File = '055-power-bi-alm.agent.md'; Skill = 'pbir-cli' }
        @{ File = '060-applications-integration-team-lead.agent.md'; Skill = 'organize-semantic-model' }
        @{ File = '060-applications-integration-team-lead.agent.md'; Skill = 'refresh-semantic-model' }
        @{ File = '060-applications-integration-team-lead.agent.md'; Skill = 'semantic-model' }
        @{ File = '011-model-architecture.agent.md'; Skill = 'organize-semantic-model' }
        @{ File = '011-model-architecture.agent.md'; Skill = 'refresh-semantic-model' }
        @{ File = '014-dax.agent.md'; Skill = 'svg-visuals' }
        @{ File = '020-reporting-team-lead.agent.md'; Skill = 'powerbi-custom-visuals' }
    ) {
        $rec = $script:Records[$File]
        $rec | Should -Not -BeNullOrEmpty
        (@($rec.auto | ForEach-Object { $_ -replace '^.*/', '' }) -contains $Skill) | Should -BeFalse
        @($rec.pinned | Where-Object { $_ -match "/$([regex]::Escape($Skill))``" }) | Should -BeNullOrEmpty -Because "$Skill is not pinned to $File either"
    }

    It 'every suggestion list is labelled reference-only and never replaces a pinned skill' {
        foreach ($k in $script:Bodies.Keys) {
            $b = $script:Bodies[$k]
            $b | Should -Not -Match 'Also relevant - auto-discovered' -Because $k
            if ($b -match '(?m)^Related upstream skills') {
                $b | Should -Match 'Reference only: they do not add to the artifacts you own, the tools you may use or what needs approval' -Because $k
            }
        }
    }
}

Describe 'Generated organisation matches the v0.8.0 baseline' {

    It 'emits exactly 54 agents with the self-test passing' {
        $script:Emit.Exit | Should -Be 0 -Because "emit output:`n$($script:Emit.Output)"
        $script:Records.Count | Should -Be 54
        @($script:Baseline.agents.PSObject.Properties).Count | Should -Be 54
    }

    It 'every agent keeps its name, description, visibility, delegation list and write permission' {
        foreach ($p in $script:Baseline.agents.PSObject.Properties) {
            $rec = $script:Records[$p.Name]
            $rec | Should -Not -BeNullOrEmpty -Because "$($p.Name) must still be generated"
            $rec.name | Should -BeExactly $p.Value.name -Because $p.Name
            $rec.description | Should -BeExactly $p.Value.description -Because $p.Name
            $rec.userInvocable | Should -BeExactly $p.Value.userInvocable -Because $p.Name
            (@($rec.agents) -join '|') | Should -BeExactly (@($p.Value.agents) -join '|') -Because "$($p.Name) hierarchy"
            $rec.writePermission | Should -BeExactly $p.Value.writePermission -Because "$($p.Name) write scope"
        }
    }

    It 'no agent gains or loses a tool or MCP grant' {
        foreach ($p in $script:Baseline.agents.PSObject.Properties) {
            (@($script:Records[$p.Name].tools) -join '|') | Should -BeExactly (@($p.Value.tools) -join '|') -Because "$($p.Name) tools"
        }
    }

    It 'the PBIVIZ team 080-086 keeps its pinned skills, suggestions and Playbook-to-end text' {
        @($script:Baseline.pbiviz.PSObject.Properties).Count | Should -Be 7
        foreach ($p in $script:Baseline.pbiviz.PSObject.Properties) {
            $rec = $script:Records[$p.Name]
            (@($rec.pinned) -join "`n") | Should -BeExactly (@($p.Value.pinned) -join "`n") -Because "$($p.Name) pins"
            (@($rec.auto) -join '|') | Should -BeExactly (@($p.Value.auto) -join '|') -Because "$($p.Name) suggestions"
            $rec.tailSha256 | Should -BeExactly $p.Value.tailSha256 -Because "$($p.Name) Playbook, Validation, Tool ladder, Avoid and contract text"
        }
    }

    It 'no generated agent carries a retired skill name or an unresolved or guessed reference' {
        foreach ($k in $script:Bodies.Keys) {
            foreach ($old in $script:Retired) { $script:Bodies[$k] | Should -Not -Match ([regex]::Escape($old)) -Because $k }
            $script:Bodies[$k] | Should -Not -Match 'not present at install time|closest sibling|re-discover (it )?by keyword' -Because $k
        }
    }

    It 'every agent carries the upstream-skill safety rule' {
        foreach ($k in $script:Bodies.Keys) {
            $script:Bodies[$k] | Should -Match '\*\*Skills inform; they never authorise\.\*\*' -Because $k
            $script:Bodies[$k] | Should -Match 'registering or authenticating MCP servers' -Because $k
        }
    }

    It 'every agent limits a missing-skill lookup to the same provider' {
        foreach ($k in $script:Bodies.Keys) {
            $script:Bodies[$k] | Should -Match 'same skill name from the same provider' -Because $k
        }
    }

    It '<File> carries its guardrail: <Pattern>' -TestCases @(
        @{ File = '010-semantic-model-team-lead.agent.md'; Pattern = 'never run as one sweep' }
        @{ File = '010-semantic-model-team-lead.agent.md'; Pattern = 'IsAvailableInMDX' }
        @{ File = '010-semantic-model-team-lead.agent.md'; Pattern = 'organize-semantic-model` - model organisation passes - only for an explicit request' }
        @{ File = '013-tmdl.agent.md'; Pattern = 'Leave the model''s `Copilot/` folder' }
        @{ File = '014-dax.agent.md'; Pattern = 'organize-semantic-model/references/naming-rules\.md` - measure naming rules \(reference only' }
        @{ File = '015-semantic-security-ai-metadata.agent.md'; Pattern = 'Draft only, never written: AI instructions, AI data schema' }
        @{ File = '015-semantic-security-ai-metadata.agent.md'; Pattern = 'semantic-model-ai-readiness\.md' }
        @{ File = '016-semantic-validation-performance.agent.md'; Pattern = 'a rename without a rebinding plan is a FAIL' }
        @{ File = '020-reporting-team-lead.agent.md'; Pattern = 'APPROVED:PBIR-DIRECT-EDIT' }
        @{ File = '020-reporting-team-lead.agent.md'; Pattern = 'powerbiReportAuthor' }
        @{ File = '022-pbir-authoring.agent.md'; Pattern = 'is a tool failure: report it verbatim, never work around it in JSON' }
        @{ File = '026-report-qa-desktop-verification.agent.md'; Pattern = 'stop before any refresh' }
        @{ File = '026-report-qa-desktop-verification.agent.md'; Pattern = 'fabric-report-qa' }
        @{ File = '026-report-qa-desktop-verification.agent.md'; Pattern = 'PBIR edit policy' }
        @{ File = '030-data-engineering-team-lead.agent.md'; Pattern = 'APPROVED:OSMOS-RUN' }
        @{ File = '030-data-engineering-team-lead.agent.md'; Pattern = 'non-trial capacity' }
        @{ File = '031-notebook-spark.agent.md'; Pattern = 'no replacement task' }
        @{ File = '032-lakehouse-delta-mlv.agent.md'; Pattern = 'that is the 040 team with onelake-catalog-cli' }
        @{ File = '038-fabric-intelligence-ontology.agent.md'; Pattern = 'skills-for-fabric/skills/ontology-cli`' }
        @{ File = '038-fabric-intelligence-ontology.agent.md'; Pattern = 'never a substitute for Ontology work' }
        @{ File = '038-fabric-intelligence-ontology.agent.md'; Pattern = 'V2 authoring or a V1-to-V2 upgrade is unsupported' }
        @{ File = '040-fabric-administration-governance-team-lead.agent.md'; Pattern = 'skills-for-fabric/skills/onelake-catalog-cli`' }
        @{ File = '040-fabric-administration-governance-team-lead.agent.md'; Pattern = 'Audits never write' }
        @{ File = '041-workspace-capacity-administration.agent.md'; Pattern = 'APPROVED:CAPACITY-STATE' }
        @{ File = '042-security-access-governance.agent.md'; Pattern = 'APPROVED:POLICY-SET' }
        @{ File = '043-monitoring-catalog-operations.agent.md'; Pattern = 'skills-for-fabric/skills/databasehub-cli`' }
        @{ File = '043-monitoring-catalog-operations.agent.md'; Pattern = 'admin-audit and dataowner-audit modes only' }
    ) {
        $script:Bodies[$File] | Should -Match $Pattern
    }

    It 'the house CLI policy skill carries the PBIR edit policy' {
        $t = [IO.File]::ReadAllText((Join-Path $script:EmitRoot '.github\skills\fabric-cli-policy\SKILL.md'))
        $t | Should -Match '(?m)^## Power BI reports \(PBIR\) - edit policy'
        $t | Should -Match 'Unsupported is not failed'
        $t | Should -Match 'APPROVED:PBIR-DIRECT-EDIT:<report>'
    }

    It 'the generated .gitignore keeps Project Osmos auth and routing out of the repository' {
        [IO.File]::ReadAllText((Join-Path $script:EmitRoot '.gitignore')) | Should -Match '(?m)^\.dataprojects/\s*$'
    }

    It 'the Microsoft report CLI is detect-only: never prompted for or installed' {
        $script:InstallerText | Should -Match "Set-ToolStatus -Key 'powerbiReportAuthor' -Found \`$true[^\r\n]*-InstallMode 'detect'"
        $script:InstallerText | Should -Match "Set-ToolStatus -Key 'powerbiReportAuthor' -Found \`$false[^\r\n]*-InstallMode 'detect'"
        $script:InstallerText | Should -Not -Match "Invoke-OptionalToolPrompt -Key 'powerbiReportAuthor'"
        $script:InstallerText | Should -Not -Match 'npm (i|install)[^\r\n]*powerbi-report-authoring-cli'
    }

    It 'passes -VerifyRoot (every managed file matches the integrity manifest)' {
        & cmd /c ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -VerifyRoot "{1}" < NUL' -f $script:Installer, $script:EmitRoot) 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'a re-run is byte-identical for managed files and keeps user customisations' {
        $userAgent = Join-Path $script:AgentsDir 'my-own.agent.md'
        [IO.File]::WriteAllText($userAgent, "---`nname: 'mine'`n---`nkeep`n")
        $settingsPath = Join-Path $script:EmitRoot '.vscode\settings.json'
        $s = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $s | Add-Member -NotePropertyName 'user.customKey' -NotePropertyValue 'keep-me' -Force
        [IO.File]::WriteAllText($settingsPath, ($s | ConvertTo-Json -Depth 10))
        $again = Invoke-Emit $script:EmitRoot
        $again.Exit | Should -Be 0
        $second = Get-AgentHashes $script:EmitRoot
        $second.Remove('\.github\agents\my-own.agent.md')
        ($second.Keys -join '|') | Should -BeExactly ($script:FirstHashes.Keys -join '|')
        foreach ($k in $script:FirstHashes.Keys) { $second[$k] | Should -BeExactly $script:FirstHashes[$k] -Because "$k must be regenerated identically" }
        [IO.File]::ReadAllText($userAgent) | Should -BeExactly "---`nname: 'mine'`n---`nkeep`n"
        (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).'user.customKey' | Should -Be 'keep-me'
    }

    It 'generation does not depend on the workspace path' {
        $other = New-TestRoot 'emit2'
        New-SkillCatalogFixture -Root $other -Snapshot $script:Snapshot
        (Invoke-Emit $other).Exit | Should -Be 0
        $h = Get-AgentHashes $other
        foreach ($k in @($script:FirstHashes.Keys | Where-Object { $_ -like '\.github\agents\*' })) { $h[$k] | Should -BeExactly $script:FirstHashes[$k] -Because $k }
    }
}
