# AiReadiness.Tests.ps1
# -------------------------------------------------------------------
# The in-house Semantic Model AI Readiness skill (fabric-ai-readiness) and its routing.
# Everything is read from the installer source (the single source of truth for house
# skills and agent knowledge); nothing is generated, installed or contacted.
#
# What these tests protect:
#   * the skill exists, is installer-managed and is listed where agents and users look;
#   * agents may change model metadata, only DRAFT Prep data for AI content, and never
#     touch the settings that belong to a person;
#   * a check is never reported at a higher validation level than it was run
#     (offline means files only);
#   * only the semantic-model team is routed to the skill.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Raw = [IO.File]::ReadAllText((Get-InstallerPath))
    $m = [regex]::Match($script:Raw, "(?s)\`$aiReadinessContent = @'\r?\n(.*?)\r?\n'@")
    $m.Success | Should -BeTrue -Because 'the installer must define the fabric-ai-readiness skill'
    $script:Skill = $m.Groups[1].Value -replace "`r`n", "`n"

    # One markdown table row by its first cell, and one "## n. Title" section.
    function Get-SkillRow([string]$FirstCell) {
        $line = @($script:Skill -split "`n" | Where-Object { $_ -match ('^\|\s*\*\*' + [regex]::Escape($FirstCell)) }) | Select-Object -First 1
        return [string]$line
    }
    function Get-SkillSection([string]$Number) {
        $mm = [regex]::Match($script:Skill, "(?ms)^## $Number\. .*?(?=^## \d+\. |\z)")
        return $mm.Value
    }
    # The knowledge block of one agent in the installer ($agentKnowledge entry), as text.
    function Get-AgentBlock([string]$Id) {
        $mm = [regex]::Match($script:Raw, "(?s)\r?\n    '$([regex]::Escape($Id))' = @\{\r?\n(.*?)\r?\n    \}")
        $mm.Success | Should -BeTrue -Because "agent knowledge for $Id must exist"
        return $mm.Groups[1].Value
    }
    $script:Manifest = Get-AgentManifest
    $script:Ref = '"$CS/fabric-ai-readiness/SKILL.md"'
}

Describe 'House skill fabric-ai-readiness: present and managed' {

    It 'is one of the installer-managed skills and is written with the other house skills' {
        $list = [regex]::Match($script:Raw, '(?s)\$managedSkills = @\((.*?)\)').Groups[1].Value
        @([regex]::Matches($list, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) | Should -Contain 'fabric-ai-readiness'
        $script:Raw | Should -Match ([regex]::Escape('Write-ManagedFile "$rootPath\.github\skills\fabric-ai-readiness\SKILL.md" $aiReadinessContent'))
    }

    It 'has valid frontmatter: its own name and a "Use when" description with the trigger words' {
        $script:Skill | Should -Match '(?s)\A---\nname: fabric-ai-readiness\ndescription: "Use when: [^\n]+"\n---\n'
        $desc = [regex]::Match($script:Skill, '(?m)^description: "(.*)"$').Groups[1].Value
        foreach ($word in 'Copilot', 'data agents', 'AI instructions', 'AI data schema', 'verified answers', 'Approved for Copilot', 'validation ladder') { $desc | Should -Match ([regex]::Escape($word)) }
    }

    It 'says where its product facts come from, when they were read, and that the feature is in preview' {
        $evidence = [regex]::Match($script:Skill, '(?s)\*\*Evidence\.\*\*.*?\n\n').Value
        $evidence | Should -Match 'Microsoft Learn on \d{4}-\d{2}-\d{2}'
        foreach ($page in 'copilot-prepare-data-ai', 'semantic-model-best-practices', 'fabric-iq-mcp') { $evidence | Should -Match $page }
        $evidence | Should -Match '\*\*preview\*\*'
        $evidence | Should -Match '\[LEARN\]'
        $evidence | Should -Match '\[MS-SKILL\]'
    }

    It 'is listed in the generated copilot-instructions, AGENTS.md and working-flow reference' {
        $script:Raw | Should -Match '(?m)^- `\.github/skills/fabric-ai-readiness/SKILL\.md`  -- Preparing a semantic model for Copilot'
        $script:Raw | Should -Match 'Custom \(TMDL, Pipelines, CLI policy, Housekeeping, AI readiness, six PBIVIZ skills\)'
        $script:Raw | Should -Match '`fabric-housekeeping`,\r?\n  `fabric-ai-readiness`, and the PBIVIZ house skills'
    }

    It 'defers to the TMDL house style instead of restating it' {
        $script:Skill | Should -Match 'House style for TMDL and DAX stays in `fabric-tmdl`; this skill never overrides it'
    }
}

Describe 'Three classes of change: what agents edit, draft, and leave to a person' {

    It 'defines exactly the three classes' {
        @([regex]::Matches((Get-SkillSection 2), '(?m)^\| \*\*([A-Z][A-Z -]+)(?: \(draft only\))?\*\* \|') | ForEach-Object { $_.Groups[1].Value }) |
            Should -Be @('AGENT-EDITABLE', 'USER-CONFIGURED', 'HUMAN SETTING')
    }

    It 'model metadata is agent-editable, and the consequential changes need an approval token' {
        $row = Get-SkillRow 'AGENT-EDITABLE'
        foreach ($item in 'descriptions', 'hidden flag', 'data types', 'summarizeBy', 'format strings', 'explicit measures') { $row | Should -Match $item }
        $row | Should -Match 'Renames, hiding, deletions, `IsAvailableInMDX` and role changes need the approval token'
    }

    It 'Prep data for AI content <Item> is draft only: applied by the user, never written by agents' -TestCases @(
        @{ Item = 'AI instructions' }, @{ Item = 'AI data schema' }, @{ Item = 'verified answers' }
    ) {
        param($Item)
        $row = Get-SkillRow 'USER-CONFIGURED'
        $row | Should -Match ([regex]::Escape("**$Item**"))
        $row | Should -Match '015 drafts; the user reviews and applies it in Power BI Desktop or the Power BI service'
        $row | Should -Match 'Agents never write it'
        (Get-SkillRow 'AGENT-EDITABLE') | Should -Not -Match ([regex]::Escape($Item)) -Because "$Item must not appear among the things agents may edit"
    }

    It 'the setting <Item> belongs to a person: agents report it and never change or claim it' -TestCases @(
        @{ Item = 'Q&A enabled on the model' }, @{ Item = 'Approved for Copilot' }, @{ Item = 'tenant and workspace settings' },
        @{ Item = 'show only approved items' }, @{ Item = 'endorsement and sensitivity labels' }
    ) {
        param($Item)
        $row = Get-SkillRow 'HUMAN SETTING'
        $row | Should -Match ([regex]::Escape($Item))
        $row | Should -Match 'never change or claim it'
    }

    It 'does not let agents switch Q&A on by editing definition.pbism' {
        (Get-SkillSection 2) | Should -Match 'this\s+workspace does not edit `definition\.pbism`, so enabling it is the user''s action'
        # The TMDL worker's standing rule that the skill relies on.
        (Get-AgentBlock 'tmdl-agent') | Should -Match "'Editing definition\.pbism\.'"
    }

    It 'treats what already sits in the Copilot folder or the linguistic metadata as the user''s, not as agent-editable' {
        (Get-SkillRow 'USER-CONFIGURED') | Should -Match 'whatever already sits in the model''s `Copilot/` folder or in `linguisticMetadata`'
        (Get-SkillRow 'AGENT-EDITABLE') | Should -Not -Match 'linguisticMetadata|Copilot/'
    }

    It 'does not read a missing Q&A key as on or off, and shows what an approval token looks like' {
        $s = Get-SkillSection 2
        $s | Should -Match 'An absent key\s+establishes nothing: report the Q&A state as not established, never as on or off'
        $s | Should -Match ([regex]::Escape('`APPROVED:RENAME:Sales[CustNm]`'))
        $s | Should -Match ([regex]::Escape('`APPROVED:HIDE:Sales[SalesKey]`'))
    }

    It 'gives no verdict in either direction' {
        (Get-SkillSection 3) | Should -Match 'Give no verdict the other way either: list the findings instead of calling the model\s+"not ready"'
    }

    It 'never promises a round trip, a specific answer or an "AI ready" verdict' {
        $s = Get-SkillSection 3
        $s | Should -Match 'authored, deployed or round-tripped through TMDL, REST,\s+XMLA, Git or a deployment pipeline'
        $s | Should -Match 'cannot guarantee a\s+given output'
        $s | Should -Match 'That a model is "AI ready" or "approved"'
        $s | Should -Match 'for\s+DirectQuery and Direct Lake models only once a day'
    }

    It 'has the preservation rule for the Copilot folder and linguistic metadata' {
        $s = Get-SkillSection 3
        $s | Should -Match '\*\*Preservation rule\.\*\*'
        $s | Should -Match '`Copilot/` folder, `linguisticMetadata` in cultures'
        $s | Should -Match 'byte-identical'
        $s | Should -Match 'stop and return NEEDS INPUT'
    }

    It 'the review workflow changes nothing, and the apply workflow is limited to the WORK ORDER' {
        (Get-SkillSection 4) | Should -Match '(?m)^## 4\. Workflow A - readiness review \(changes nothing\)'
        (Get-SkillSection 4) | Should -Match 'No edits in this workflow'
        (Get-SkillSection 4) | Should -Match 'Never invent business meaning'
        (Get-SkillSection 5) | Should -Match 'Apply only AGENT-EDITABLE changes named in the WORK ORDER'
        (Get-SkillSection 5) | Should -Match 'comes back as NEEDS APPROVAL'
        (Get-SkillSection 5) | Should -Match 'record the state of the `Copilot/` folder and the culture files'
    }

    It 'the hand-over package tells the user what to apply, where, how to test, and what only they decide' {
        $s = Get-SkillSection 6
        foreach ($part in 'Draft AI instructions', 'Draft AI data schema', 'Verified answer candidates', 'How to apply it', 'How to test it', 'The decision that stays with the owner') { $s | Should -Match ([regex]::Escape("**$part**")) }
        $s | Should -Match 'marking the model \*Approved for Copilot\*'
        $s | Should -Match 'Hard rules belong in the\s+model, not in instructions'
    }
}

Describe 'Validation ladder: offline means files only' {

    BeforeAll {
        $script:Ladder = Get-SkillSection 7
        $script:Rows = @{}
        foreach ($level in 'L0 Offline', 'L1 Local tool', 'L2 Live model', 'L3 Power BI Desktop or service') { $script:Rows[$level] = Get-SkillRow $level }
    }

    It 'has the four levels in order' {
        @([regex]::Matches($script:Ladder, '(?m)^\| \*\*(L\d) ') | ForEach-Object { $_.Groups[1].Value }) | Should -Be @('L0', 'L1', 'L2', 'L3')
    }

    It 'L0 needs no network, no live model and no Desktop, and holds only file checks' {
        $script:Rows['L0 Offline'] | Should -Match 'Only the files; no network, no live model, no Desktop'
        # Nothing that needs a connection, a sign-in or a person may sit in the offline row.
        foreach ($liveOnly in 'compiles', 'evaluates', 'executeQueries', 'regression', 'role-scoped', 'Copilot answers', 'modeling MCP', 'Approved for Copilot', 'pbir desktop', 'deployment') {
            $script:Rows['L0 Offline'] | Should -Not -Match ([regex]::Escape($liveOnly)) -Because "'$liveOnly' is not an offline check"
        }
    }

    It 'L1 runs only a tool that tool-status reports as found, and is NOT RUN otherwise' {
        $script:Rows['L1 Local tool'] | Should -Match 'A tool that tool-status reports as found, run on the local files'
        $script:Rows['L1 Local tool'] | Should -Match 'Absent tool: NOT RUN'
    }

    It 'L2 needs the Master-opened modeling MCP connection or REST and holds the live checks' {
        $script:Rows['L2 Live model'] | Should -Match 'The modeling MCP connection the Master opened, or REST `executeQueries`'
        foreach ($check in 'DAX compiles and evaluates', 'regression', 'role-scoped query') { $script:Rows['L2 Live model'] | Should -Match $check }
    }

    It 'L3 needs a person, and agents report it as NOT RUN unless the user confirms' {
        $script:Rows['L3 Power BI Desktop or service'] | Should -Match 'A person, or `pbir desktop` for report checks only'
        $script:Rows['L3 Power BI Desktop or service'] | Should -Match 'Agents report these as NOT RUN unless the user confirms them'
    }

    It 'forbids reporting a check at a higher level than it was run' {
        $script:Ladder | Should -Match 'A check is never reported at a higher level than it was run'
        $script:Ladder | Should -Match 'a check that was not run is NOT RUN, never passed'
        $script:Ladder | Should -Match '"Offline" means L0 only\. A check that needs a connection, a sign-in or Desktop is L2 or L3'
    }

    It 'a review does not list a comparison it has no recorded state for as run' {
        $script:Ladder | Should -Match 'A review \(Workflow A\) writes nothing and records no state: say that nothing\s+was written, and do not list that comparison as run'
    }

    It '016 and the skill agree: a check that was not run is NOT RUN, not a failure and not a pass' {
        $block = Get-AgentBlock 'semantic-validation-performance-agent'
        $block | Should -Match 'A check you could not run is NOT RUN with the reason, never passed and never guessed'
        $block | Should -Match 'with any NOT RUN or FAIL line the overall result is not a pass'
        $block | Should -Not -Match 'FAIL any check you could not run' -Because 'the skill says NOT RUN; two words for one case made the agent choose'
    }

    It 'the validation agent (016) applies the ladder and never edits' {
        $block = Get-AgentBlock 'semantic-validation-performance-agent'
        $block | Should -Match ([regex]::Escape($script:Ref))
        $block | Should -Match 'L0 offline \(files only: no network, no live model, no Desktop\)'
        $block | Should -Match 'L1 local tool \(TE2 or `te` on the local files, only when tool-status says found\)'
        $block | Should -Match 'never call an L2 or L3 check offline'
        $block | Should -Match 'check -> level \(L0-L3\) -> result -> evidence'
        @(($script:Manifest.agents | Where-Object { $_.id -eq 'semantic-validation-performance-agent' }).tools) | Should -Not -Contain 'edit'
    }
}

Describe 'Security and consumers' {

    It 'treats names, descriptions, instructions and trigger phrases as visible metadata' {
        $s = Get-SkillSection 8
        $s | Should -Match 'Security filters data, not text'
        $s | Should -Match 'put nothing in them that the least-privileged reader of the model may not see'
        $s | Should -Match 'No secrets, personal data, customer names or confidential figures'
        $s | Should -Match 'Never describe or route to an object protected by object-level security'
        $s | Should -Match 'Record the identity every test ran under'
    }

    It 'asks for a role-scoped check instead of assuming security carries over' {
        (Get-SkillSection 8) | Should -Match 'confirm it for your model with a role-scoped query \(L2\)\s+instead of assuming it'
    }

    It 'role, RLS and OLS changes are never a side effect of an AI readiness pass' {
        (Get-SkillSection 8) | Should -Match 'Role, RLS and OLS changes are never part of an AI readiness pass unless the WORK ORDER carries\s+their approval token'
    }

    It 'names the consumers and keeps Fabric IQ read-only and with 038' {
        $s = Get-SkillSection 9
        foreach ($c in 'Copilot in Power BI', 'Fabric data agents', 'Fabric IQ MCP') { $s | Should -Match ([regex]::Escape("**$c**")) }
        $s | Should -Match 'ignores DAX instructions written at data-agent level'
        $s | Should -Match 'read-only and has no tool that answers in natural language'
        $s | Should -Match 'Use and limits: 038'
    }

    It 'ends with a report checklist that repeats the non-negotiable points' {
        $s = Get-SkillSection 10
        @([regex]::Matches($s, '(?m)^- \[ \] ')).Count | Should -BeGreaterOrEqual 6
        $s | Should -Match 'AGENT-EDITABLE, USER-CONFIGURED or HUMAN SETTING'
        $s | Should -Match 'Nothing in `Copilot/` or the linguistic metadata changed'
        $s | Should -Match 'anything not run says NOT RUN'
        $s | Should -Match 'No statement that the model is approved, AI ready'
    }
}

Describe 'Routing: the semantic-model team, and nobody else' {

    It 'exactly 010 (lead), 015 (drafts and security) and 016 (validation) pin the skill' {
        $pinning = @()
        foreach ($mm in [regex]::Matches($script:Raw, "(?s)\r?\n    '([a-z0-9-]+)' = @\{\r?\n(.*?)\r?\n    \}")) {
            if ($mm.Groups[2].Value.Contains($script:Ref)) { $pinning += $mm.Groups[1].Value }
        }
        @($pinning | Sort-Object) | Should -Be @('semantic-model-team-lead', 'semantic-security-ai-metadata-agent', 'semantic-validation-performance-agent')
        foreach ($id in $pinning) { ($script:Manifest.agents | Where-Object { $_.id -eq $id }).department | Should -Be 'semantic-model' }
    }

    It 'the lead routes the three workflows and never reports a model as AI ready' {
        $block = Get-AgentBlock 'semantic-model-team-lead'
        $block | Should -Match 'AI readiness follows the house skill fabric-ai-readiness'
        foreach ($w in 'Workflow A', 'Workflow B', 'Workflow C') { $block | Should -Match $w }
        $block | Should -Match 'Q&A, the Approved for Copilot mark and tenant settings are the user''''s'
        $block | Should -Match 'Never report a model as AI ready or approved'
        $block | Should -Match 'WINS on who does what'
    }

    It '015 still only drafts Prep data for AI content and labels every recommendation with its class' {
        $block = Get-AgentBlock 'semantic-security-ai-metadata-agent'
        $block | Should -Match 'Draft only, never written: AI instructions, AI data schema \(including its synonyms\), verified answers'
        $block | Should -Match "'Writing or regenerating AI instructions, AI data schema, verified answers or other ``Copilot/`` files\.'"
        $block | Should -Match 'AGENT-EDITABLE \(applied, with evidence\), USER-CONFIGURED \(draft\) or HUMAN SETTING \(reported only\)'
        # The Microsoft reference stays pinned next to the house skill; the house skill wins on who does what.
        $block | Should -Match 'semantic-model-ai-readiness\.md'
    }

    It 'the TMDL and DAX workers keep their own guardrails (the skill adds no permission)' {
        (Get-AgentBlock 'tmdl-agent') | Should -Match "'Writing Prep data for AI content \(AI instructions, AI data schema, verified answers\)\.'"
        (Get-AgentBlock 'tmdl-agent') | Should -Match 'Leave the model''''s `Copilot/` folder, `linguisticMetadata` in cultures and any unrecognised metadata untouched'
        (Get-AgentBlock 'dax-agent') | Should -Match 'apply it only with the approval token in your WORK ORDER'
    }

    It 'no agent gained a tool for this skill: the semantic team holds what the recorded baseline says' {
        $baseline = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\agent-baseline.json')) | ConvertFrom-Json
        $team = @($script:Manifest.agents | Where-Object { $_.department -eq 'semantic-model' })
        $team.Count | Should -Be 7
        foreach ($agent in $team) {
            $file = ([string]$agent.filename) -replace '^\d+', ('{0:D3}' -f [int]([regex]::Match([string]$agent.filename, '^\d+').Value))
            $recorded = @($baseline.agents.$file.tools)
            $recorded | Should -Not -BeNullOrEmpty -Because "$file is in the baseline"
            # Built-in capabilities come from the manifest; server grants are the entries with a slash.
            (@($agent.tools) -join '|') | Should -BeExactly (@($recorded | Where-Object { $_ -notmatch '/' }) -join '|') -Because $file
            foreach ($grant in @($recorded | Where-Object { $_ -match '/' })) { $grant | Should -BeIn @('powerbi-modeling-mcp/*', 'microsoftDocs/*') -Because "$file holds no remote MCP server" }
        }
    }
}
