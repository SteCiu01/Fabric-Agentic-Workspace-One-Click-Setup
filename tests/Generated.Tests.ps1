# Generated.Tests.ps1
# -------------------------------------------------------------------
# End-to-end smoke test of the REAL generator. Unlike the other suites
# (which read the embedded manifest without running the installer),
# this one actually RUNS the installer in its dry-run "-EmitAgentsTo"
# mode into a throwaway temp folder and asserts on the agent files it
# produces on disk. This proves the code path that writes agents -- not
# just the manifest data -- is correct and stays in sync.
#
# Emit mode performs NO prerequisite checks, NO repo cloning, NO tool
# installs and NO VS Code launch, so it is safe to run in CI.
#
# Note on filenames: the manifest stores two-digit prefixes (e.g.
# "00-...") while the installer emits three-digit prefixes (e.g.
# "000-..."). We therefore pair a manifest entry to its generated file
# by "slug" -- the filename with its leading numeric prefix removed --
# which is stable regardless of the padding width.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"

    $script:Manifest    = Get-AgentManifest
    $script:Installer   = Get-InstallerPath
    $script:EmitDir     = Join-Path ([System.IO.Path]::GetTempPath()) ("fabric_emit_" + [guid]::NewGuid().ToString('N'))

    # Run the installer's dry-run generator. stdin is fed from NUL so any
    # "Press Enter to continue" prompts in the generation steps return
    # immediately (EOF) instead of blocking the test run.
    # Force Windows PowerShell 5.1 (powershell.exe) for the child so the emit path
    # behaves identically on a PS7 CI host and a local PS5.1 shell.
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $script:EmitDir
    $script:EmitOutput  = & cmd /c $cmd 2>&1
    $script:EmitExit    = $LASTEXITCODE
    $script:AgentsDir   = Join-Path $script:EmitDir '.github\agents'
    $script:AgentFiles  = @(Get-ChildItem -Path $script:AgentsDir -Filter '*.agent.md' -ErrorAction SilentlyContinue)

    function Get-FrontmatterTools {
        param([string]$Path)
        $head = Get-Content -LiteralPath $Path -TotalCount 15
        $line = $head | Where-Object { $_ -match '^\s*tools:\s*\[' } | Select-Object -First 1
        if (-not $line) { return @() }
        $inner = ($line -replace '^\s*tools:\s*\[', '') -replace '\].*$', ''
        return @($inner -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ })
    }

    # Base capability tokens. MCP entries (which contain "/") are additive
    # and excluded from the manifest-vs-generated comparison.
    $script:BaseTools = @('agent', 'read', 'search', 'execute', 'edit')

    # slug (filename without numeric prefix) -> generated file info
    $script:GenBySlug = @{}
    foreach ($f in $script:AgentFiles) {
        $slug = $f.Name -replace '^\d+-', ''
        $script:GenBySlug[$slug] = [pscustomobject]@{
            Name  = $f.Name
            Path  = $f.FullName
            Tools = @(Get-FrontmatterTools -Path $f.FullName)
        }
    }
}

AfterAll {
    if ($script:EmitDir -and (Test-Path -LiteralPath $script:EmitDir)) {
        Remove-Item -LiteralPath $script:EmitDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Installer emit mode (real generator dry-run)' {

    It 'exits successfully (self-test gate passed)' {
        # On failure, surface the installer's emit output in the CI log so the
        # exact cause is visible instead of a bare non-zero exit code.
        $script:EmitExit | Should -Be 0 -Because "the emit dry-run must exit 0; installer output was:`n$(($script:EmitOutput | Out-String))"
    }

    It 'creates exactly one agent file per manifest entry' {
        $script:AgentFiles.Count | Should -Be $script:Manifest.agents.Count
    }

    It 'writes exactly one generated file per manifest slug (no missing, no extras)' {
        $generatedSlugs = $script:GenBySlug.Keys | Sort-Object
        $manifestSlugs  = $script:Manifest.agents.filename | ForEach-Object { $_ -replace '^\d+-', '' } | Sort-Object
        $generatedSlugs | Should -Be $manifestSlugs
    }

    It 'names every generated file with a three-digit ordered prefix' {
        foreach ($f in $script:AgentFiles) {
            $f.Name | Should -Match '^\d{3}-[a-z0-9-]+\.agent\.md$'
        }
    }
}

Describe 'Generated agent frontmatter' {

    It 'every agent file opens with a YAML frontmatter fence' {
        foreach ($f in $script:AgentFiles) {
            (Get-Content -LiteralPath $f.FullName -TotalCount 1) | Should -Be '---'
        }
    }

    It 'every generated file has a name and description in its frontmatter' {
        foreach ($f in $script:AgentFiles) {
            $head = (Get-Content -LiteralPath $f.FullName -TotalCount 15) -join "`n"
            $head | Should -Match '(?m)^name:\s*'
            $head | Should -Match '(?m)^description:\s*'
        }
    }

    It 'each generated file exposes exactly the capability tokens declared in the manifest' {
        foreach ($agent in $script:Manifest.agents) {
            $slug = $agent.filename -replace '^\d+-', ''
            $script:GenBySlug.ContainsKey($slug) | Should -BeTrue -Because "manifest lists $($agent.filename)"

            $generatedBase = @($script:GenBySlug[$slug].Tools | Where-Object { $script:BaseTools -contains $_ } | Sort-Object)
            $expectedBase  = @($agent.tools | Where-Object { $script:BaseTools -contains $_ } | Sort-Object)

            ($generatedBase -join ',') | Should -Be ($expectedBase -join ',') -Because "tools drift in $($agent.filename)"
        }
    }

    It 'no worker agent exposes the delegation (agent) token (only executives and team leads delegate)' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { $_.level -eq 'worker' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $script:GenBySlug[$slug].Tools | Should -Not -Contain 'agent' -Because "$($agent.filename) is a worker and must not delegate"
        }
    }

    It 'the Master lists only its declared children in agents: (no direct-to-worker fallback)' {
        $master = $script:Manifest.agents | Where-Object { $_.id -eq 'fabric-workspace-master' }
        $slug = $master.filename -replace '^\d+-', ''
        $head = (Get-Content -LiteralPath $script:GenBySlug[$slug].Path -TotalCount 20) -join "`n"
        $line = [regex]::Match($head, '(?m)^agents:\s*\[(.*)\]').Groups[1].Value
        $listed = @($line -split ',' | ForEach-Object { $_.Trim().Trim("'") } | Where-Object { $_ })
        $listed.Count | Should -Be @($master.allowedChildren).Count -Because 'the Master must not list workers in agents:'
        foreach ($w in ($script:Manifest.agents | Where-Object { $_.level -eq 'worker' })) {
            ($listed -join '|') | Should -Not -Match ([regex]::Escape($w.displayName)) -Because "worker $($w.displayName) must not be directly dispatchable by the Master"
        }
    }

    It 'the Master carries a capability-maintenance handoff' {
        $master = $script:Manifest.agents | Where-Object { $_.id -eq 'fabric-workspace-master' }
        $slug = $master.filename -replace '^\d+-', ''
        $head = (Get-Content -LiteralPath $script:GenBySlug[$slug].Path -TotalCount 25) -join "`n"
        $head | Should -Match '(?m)^handoffs:'
        $head | Should -Match 'Capability Maintenance Team Lead'
    }
}

Describe 'Generated agent content (specialist knowledge and team protocol)' {

    BeforeAll {
        $script:BodyBySlug = @{}
        foreach ($k in $script:GenBySlug.Keys) {
            $script:BodyBySlug[$k] = Get-Content -LiteralPath $script:GenBySlug[$k].Path -Raw
        }
    }

    It 'every agent has a Knowledge and skills section with at least one skill reference' {
        foreach ($agent in $script:Manifest.agents) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Match '(?m)^## Knowledge and skills' -Because "$($agent.filename) must not be an empty shell"
            $body | Should -Match '(?m)^- `[^`]+` ' -Because "$($agent.filename) must list at least one skill path"
        }
    }

    It 'every agent has a Playbook and a Validation section' {
        foreach ($agent in $script:Manifest.agents) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Match '(?m)^## Playbook' -Because $agent.filename
            $body | Should -Match '(?m)^## Validation you must run before reporting' -Because $agent.filename
        }
    }

    It 'every non-Master agent ends with the WORK RESULT return contract' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { $_.id -ne 'fabric-workspace-master' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Match 'WORK RESULT' -Because $agent.filename
            $body | Should -Match 'NEEDS APPROVAL' -Because $agent.filename
            $body | Should -Match 'final message must be the WORK RESULT block' -Because "$($agent.filename) must treat a block-less turn as a failure"
        }
    }

    It 'every agent that can execute carries the terminal-hygiene rule' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { @($_.tools) -contains 'execute' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $script:BodyBySlug[$slug] | Should -Match 'Terminal hygiene' -Because "$($agent.filename) runs commands"
        }
    }

    It 'every agent that can delegate handles agent-not-found retries and empty returns' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { @($_.tools) -contains 'agent' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Match 'not found' -Because "$($agent.filename) dispatches and must retry registry flakes"
            $body | Should -Match 'ended without a WORK RESULT' -Because "$($agent.filename) must re-dispatch on empty returns"
        }
    }

    It 'semantic-model agents reuse the Master-opened MCP connection instead of probing' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { $_.department -eq 'semantic-model' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Match 'mcp connection' -Because $agent.filename
            $body | Should -Not -Match 'first-use probe' -Because "$($agent.filename) must not probe with ListConnections"
        }
        $master = ($script:Manifest.agents | Where-Object { $_.id -eq 'fabric-workspace-master' }).filename -replace '^\d+-', ''
        $script:BodyBySlug[$master] | Should -Match 'ConnectFabric'
    }

    It 'every instruction to use a tool is backed by a grant in the same agent''s frontmatter' {
        # The bug class behind v0.7.1: a body telling the agent to call something its tools: list excludes.
        foreach ($k in $script:GenBySlug.Keys) {
            $tools = $script:GenBySlug[$k].Tools
            $body  = $script:BodyBySlug[$k]
            # Strip the frontmatter so `tools:` itself does not count as an instruction.
            $prose = ($body -split '(?m)^---\s*$', 3)[2]
            if ($prose -match 'ConnectFabric|connection_operations|dax_query|powerbi-modeling-mcp') {
                $tools | Should -Contain 'powerbi-modeling-mcp/*' -Because "$k tells itself to use the Power BI modeling MCP"
            }
            if ($prose -match 'Fabric MCP/\*') {
                $tools | Should -Contain 'Fabric MCP/*' -Because "$k tells itself to use the Fabric MCP wildcard"
            }
            if ($prose -match '\*\*Terminal hygiene\.\*\*') {
                $tools | Should -Contain 'execute' -Because "$k carries the execute hygiene rule"
            }
            if ($prose -match '(?m)^## Delegation|^## How you dispatch') {
                $tools | Should -Contain 'agent' -Because "$k has a delegation section"
            }
        }
    }

    It 'the MCP-connection bullet is emitted only to agents that hold the modeling MCP' {
        foreach ($k in $script:GenBySlug.Keys) {
            $tools = $script:GenBySlug[$k].Tools
            $prose = ($script:BodyBySlug[$k] -split '(?m)^---\s*$', 3)[2]
            $hasBullet = $prose -match 'Never (try to )?open a connection yourself'
            if ($tools -contains 'powerbi-modeling-mcp/*') { $hasBullet | Should -BeTrue -Because "$k holds the modeling MCP" }
            else { $hasBullet | Should -BeFalse -Because "$k does not hold the modeling MCP - lean contract must not carry the bullet" }
        }
    }

    It 'delegating agents carry the retry-after-write and parallel-dispatch rules' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { @($_.tools) -contains 'agent' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Match 'Retries must not repeat writes' -Because $agent.filename
            $body | Should -Match 'at most one of them needs the terminal' -Because $agent.filename
        }
    }

    It 'maintenance agents carry ONE vendor-refresh policy (stop conditions, no blanket never-reset)' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { $_.department -eq 'capability-maintenance' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Match 'Stop and report instead of resetting' -Because $agent.filename
            $body | Should -Match 'rev-parse --show-toplevel' -Because "$($agent.filename) must check the repository root before any reset"
            $body | Should -Not -Match 'never reset or overwrite it' -Because "$($agent.filename) must not contradict the refresh rule"
            $body | Should -Match 'source-control-repositories/[^\r\n]*never' -Because 'business repositories stay protected'
        }
    }

    It 'terminal hygiene matches what the agent can actually do (edit vs execute-only)' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { @($_.tools) -contains 'execute' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Not -Match 'Use your OWN terminal' -Because 'the shell is shared; a per-agent terminal cannot be guaranteed'
            if (@($agent.tools) -contains 'edit') {
                $body | Should -Match '\*\*Terminal hygiene\.\*\*' -Because $agent.filename
                $body | Should -Match 'scripts/<agent>-<purpose>' -Because "$($agent.filename) can write scripts"
            } else {
                $body | Should -Match 'Terminal hygiene \(execute without edit\)' -Because "$($agent.filename) cannot create files"
                $body | Should -Match 'hand it to an edit-capable worker' -Because "$($agent.filename) must escalate instead of improvising scripts"
            }
        }
    }

    It 'PLAN and VERDICT travel inside the WORK RESULT payload field' {
        $arch = ($script:Manifest.agents | Where-Object { $_.id -eq 'fabric-solution-architect' }).filename -replace '^\d+-', ''
        $qa   = ($script:Manifest.agents | Where-Object { $_.id -eq 'integration-qa-change-controller' }).filename -replace '^\d+-', ''
        $script:BodyBySlug[$arch] | Should -Match 'complete PLAN block verbatim in the ``?payload:``?'
        $script:BodyBySlug[$qa]   | Should -Match 'complete VERDICT block verbatim in the ``?payload:``?'
        foreach ($agent in ($script:Manifest.agents | Where-Object { $_.id -ne 'fabric-workspace-master' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $script:BodyBySlug[$slug] | Should -Match '(?m)^payload: ' -Because "$($agent.filename) return contract must define the field"
        }
    }

    It 'every worker carries the approval-token rule and the scope boundary' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { $_.level -eq 'worker' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Match 'APPROVED:DELETE' -Because "$($agent.filename) must know the token format"
            $body | Should -Match 'phrasing is NOT the token' -Because "$($agent.filename) must not treat user wording as approval"
            $body | Should -Match '(?m)^## Scope boundary' -Because $agent.filename
            $body | Should -Not -Match '(?m)^## Delegation' -Because "$($agent.filename) is a worker"
        }
    }

    It 'every team lead has a roster table and dispatch rules' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { $_.level -eq 'team-lead' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Match '(?m)^## Your team' -Because $agent.filename
            $body | Should -Match '(?m)^## How you dispatch' -Because $agent.filename
            $body | Should -Match '(?m)^## Delegation' -Because $agent.filename
        }
    }

    It 'the Architect returns a PLAN and QA returns a VERDICT' {
        $arch = ($script:Manifest.agents | Where-Object { $_.id -eq 'fabric-solution-architect' }).filename -replace '^\d+-', ''
        $qa   = ($script:Manifest.agents | Where-Object { $_.id -eq 'integration-qa-change-controller' }).filename -replace '^\d+-', ''
        $script:BodyBySlug[$arch] | Should -Match '(?m)^## Your output: a PLAN'
        $script:BodyBySlug[$qa]   | Should -Match '(?m)^## Your output: a VERDICT'
    }

    It 'the Master describes the three loops, the session ledger and the destructive-request confirmation' {
        $slug = ($script:Manifest.agents | Where-Object { $_.id -eq 'fabric-workspace-master' }).filename -replace '^\d+-', ''
        $body = $script:BodyBySlug[$slug]
        $body | Should -Match '(?m)^## The three loops you run'
        $body | Should -Match '(?m)^## Session ledger'
        $body | Should -Match 'Confirm destructive requests up front'
        $body | Should -Not -Match 'Degraded-mode' -Because 'the direct-to-worker fallback was removed'
    }

    It 'no agent references the non-existent skill name fabric-tool-policy' {
        foreach ($k in $script:BodyBySlug.Keys) {
            $script:BodyBySlug[$k] | Should -Not -Match 'fabric-tool-policy' -Because $k
        }
    }

    It 'custom skill references always resolve (no re-discover marker on .github paths)' {
        foreach ($k in $script:BodyBySlug.Keys) {
            $script:BodyBySlug[$k] | Should -Not -Match '`\.github/[^`]+` \*\(not present' -Because "$k references a managed file that the installer always writes"
        }
    }

    It 'every section heading is preceded by a blank line (markdown renders correctly)' {
        foreach ($k in $script:BodyBySlug.Keys) {
            $lines = $script:BodyBySlug[$k] -split "`r?`n"
            for ($i = 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -like '## *') { $lines[$i - 1].Trim() | Should -Be '' -Because "$k line $($i + 1)" }
            }
        }
    }
}

Describe 'Generated configuration (settings, docs, status script)' {

    It 'emits Get-SessionStatus.ps1 and it parses' {
        $p = Join-Path $script:EmitDir '.github\agent-docs\Get-SessionStatus.ps1'
        Test-Path -LiteralPath $p | Should -BeTrue
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It 'status script reports MCP separately from CLI tools and persists a fallback snapshot' {
        $p = Join-Path $script:EmitDir '.github\agent-docs\Get-SessionStatus.ps1'
        $text = Get-Content -LiteralPath $p -Raw
        $text | Should -Match '"MCP\s+' -Because 'MCP installed-vs-connected must be its own line'
        $text | Should -Match 'connected: none' -Because 'installed must never be reported as connected'
        $text | Should -Match 'session-status\.last\.txt' -Because 'the block must survive a wedged shell'
    }

    It 'the starting flow makes the Master open the MCP connection, not list it' {
        $p = Join-Path $script:EmitDir '.github\agent-docs\starting-flow.md'
        $text = Get-Content -LiteralPath $p -Raw
        $text | Should -Match 'ConnectFabric'
        $text | Should -Not -Match 'Power BI modeling MCP: list connections'
    }

    It 'emits the lean starting flow (no blocking menus, one status call)' {
        $p = Join-Path $script:EmitDir '.github\agent-docs\starting-flow.md'
        $text = Get-Content -LiteralPath $p -Raw
        $text | Should -Match 'Get-SessionStatus\.ps1'
        $text | Should -Not -Match 'Enter 1 or 2'
        $text | Should -Not -Match 'Please switch to the corresponding agent'
    }

    It 'emits the working-flow reference with the team protocol' {
        $p = Join-Path $script:EmitDir '.github\agent-docs\working-flow-reference.md'
        $text = Get-Content -LiteralPath $p -Raw
        $text | Should -Match '(?m)^## Team protocol'
        $text | Should -Match '(?m)^### WORK ORDER'
        $text | Should -Match '(?m)^### WORK RESULT'
        $text | Should -Match '(?m)^payload: ' -Because 'the PLAN/VERDICT wrapper must be in the shared protocol'
        $text | Should -Not -Match 'handle it inline if they decline'
        $text | Should -Not -Match 'One terminal PER AGENT' -Because 'the shared-shell rule replaced the per-agent terminal assumption'
        $text | Should -Not -Match 'INFO\.VIEW\.MEASURES\(\)[^\r\n]*instead' -Because 'REST executeQueries does not support INFO functions; no workaround may be promised'
    }

    It 'enables nested subagent dispatch and registers skill locations in .vscode/settings.json' {
        $p = Join-Path $script:EmitDir '.vscode\settings.json'
        Test-Path -LiteralPath $p | Should -BeTrue
        $s = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $s.'chat.subagents.allowInvocationsFromSubagents' | Should -BeTrue
        $s.'chat.agentSkillsLocations'.'.github/skills' | Should -BeTrue
        # Extension skill dirs are discovered on disk, never pinned: every ~/ entry must exist.
        foreach ($loc in $s.'chat.agentSkillsLocations'.PSObject.Properties.Name | Where-Object { $_ -like '~/*' }) {
            $full = Join-Path $env:USERPROFILE ($loc.Substring(2) -replace '/', '\')
            Test-Path -LiteralPath $full | Should -BeTrue -Because "registered skill location $loc must exist on this machine"
        }
    }
}
