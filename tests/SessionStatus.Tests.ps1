# SessionStatus.Tests.ps1
# -------------------------------------------------------------------
# Behavioural test of the emitted Get-SessionStatus.ps1: builds a scratch
# workspace (emit-mode output + junctions to fake skill clones), runs the
# script from an UNRELATED working directory and asserts the block it
# prints, the self-heal of skill registrations, the honest MCP line and
# the persisted fallback snapshot. No network, no real tools required.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("fabric_status_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Root | Out-Null

    # 1. Emit the managed files (agents, docs, status script, settings) into the scratch root.
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $script:Root
    $null = & cmd /c $cmd 2>&1
    $script:Script = Join-Path $script:Root '.github\agent-docs\Get-SessionStatus.ps1'

    # 2. Fake upstream clones: one registered container, one NEW container the script must self-register.
    foreach ($rel in @('skills-for-fabric\skills\demo-skill', 'power-bi-agentic-development\plugins\newplugin\skills\brand-new-skill')) {
        $d = Join-Path $script:Root $rel
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content (Join-Path $d 'SKILL.md') "---`nname: x`ndescription: y`n---`n"
    }
    # Pretend the installer registered only the Microsoft container (as if newplugin appeared upstream later).
    $settingsPath = Join-Path $script:Root '.vscode\settings.json'
    $s = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $s.'chat.agentSkillsLocations' | Add-Member -NotePropertyName 'skills-for-fabric/skills' -NotePropertyValue $true -Force
    $s | Add-Member -NotePropertyName 'user.customKey' -NotePropertyValue 'keep-me' -Force
    [IO.File]::WriteAllText($settingsPath, ($s | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))

    # 3. A minimal tool-status.json with one CLI, one MCP extension. Both CLI commands are
    #    unresolvable so the identity probes (fab/az) never leave the machine: offline by design.
    $toolStatus = @{
        _meta = @{ schemaVersion = 1 }
        fab = @{ found = $true; command = 'definitely-not-a-real-command-xyz'; path = ''; category = 'core-cli'; reason = '' }
        az = @{ found = $true; command = 'definitely-not-a-real-command-abc'; path = ''; category = 'core-cli'; reason = '' }
        teCli = @{ found = $false; command = ''; path = ''; category = 'specialist-cli'; installMode = 'detect'; reason = '' }
        gitIdentity = @{ found = $true; command = ''; path = ''; category = 'pbiviz-info'; installMode = 'detect'; reason = '' }
        powerBiModelMcpServer = @{ found = $true; category = 'mcp-extension'; extensionInstalled = $true; mcpToolsCallable = 'unknown' }
        fabricMcpServer = @{ found = $false; category = 'mcp-extension'; extensionInstalled = $false; mcpToolsCallable = 'unknown' }
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $script:Root '.github\agent-docs\tool-status.json'), $toolStatus, (New-Object System.Text.UTF8Encoding($false)))

    # 3b. An enabled PBIVIZ mapping whose folder exists but is not a repository (no Git needed).
    New-Item -ItemType Directory -Path (Join-Path $script:Root 'Viz Dev'), (Join-Path $script:Root '.github\agent-docs\local') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:Root '.github\agent-docs\local\pbiviz-workspace.json'), '{ "schemaVersion": 1, "enabled": true, "relativePath": "Viz Dev", "git": { "initStatus": "skipped: synced path" } }', (New-Object System.Text.UTF8Encoding($false)))

    # 4. Run from an unrelated CWD, with a controlled (absent) USER settings file so the
    #    developer's real %APPDATA% settings cannot change the outcome.
    $script:NoUserSettings = Join-Path $script:Root 'no-user-settings.json'
    $env:FABRIC_AGENTIC_USER_SETTINGS = $script:NoUserSettings
    Push-Location $env:TEMP
    try { $script:Output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script 2>&1 | Out-String }
    finally { Pop-Location; Remove-Item Env:\FABRIC_AGENTIC_USER_SETTINGS -ErrorAction SilentlyContinue }
    $script:Settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
}

AfterAll {
    if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-SessionStatus.ps1 (emitted status script)' {

    It 'resolves the workspace root from its own location, not the CWD' {
        $script:Output | Should -Match ('(?m)^ROOT\s+' + [regex]::Escape($script:Root))
    }

    It 'prints every section of the status block' {
        foreach ($h in 'SKILLS', 'CONFIG', 'IDENTITY', 'TOOLS', 'MCP') {
            $script:Output | Should -Match "(?m)^$h\s+" -Because "$h line must be present"
        }
    }

    It 'reports MCP as installed but never as connected' {
        $script:Output | Should -Match '(?m)^MCP\s+installed: Power BI modeling MCP'
        $script:Output | Should -Match 'not installed: Fabric MCP'
        $script:Output | Should -Match 'connected: none'
        $script:Output | Should -Not -Match '(?m)^TOOLS\s+available:[^\r\n]*McpServer' -Because 'MCP must not be listed as an available CLI tool'
    }

    It 'self-registers a new upstream skill container and reports it' {
        $script:Settings.'chat.agentSkillsLocations'.'power-bi-agentic-development/plugins/newplugin/skills' | Should -BeTrue
        $script:Output | Should -Match 'Newly registered skill folders'
    }

    It 'preserves existing settings keys when it rewrites settings.json' {
        $script:Settings.'user.customKey' | Should -Be 'keep-me'
        $script:Settings.'chat.subagents.allowInvocationsFromSubagents' | Should -BeTrue
        $script:Settings.'chat.agentSkillsLocations'.'.github/skills' | Should -BeTrue
    }

    It 'flips a tool to missing when its command is not on this machine and refreshes tool-status.json' {
        $ts = Get-Content (Join-Path $script:Root '.github\agent-docs\tool-status.json') -Raw | ConvertFrom-Json
        $ts.fab.found | Should -BeFalse
        $ts._meta.lastSessionCheck | Should -Not -BeNullOrEmpty
        $script:Output | Should -Match 'changed since install:[^\r\n]*fab: True -> False'
    }

    It 'persists the block to session-status.last.txt as a stdout fallback, stamped with GENERATED' {
        $p = Join-Path $script:Root '.github\agent-docs\session-status.last.txt'
        Test-Path $p | Should -BeTrue
        $saved = Get-Content $p -Raw
        $saved | Should -Match '(?m)^MCP\s+'
        $saved | Should -Match '(?m)^GENERATED \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}'
        $script:Output | Should -Match '(?m)^GENERATED \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' -Because 'the timestamp is the first line of stdout too'
    }

    It 'reports not-logged-in without probing when the recorded CLIs are unavailable (offline-safe)' {
        $script:Output | Should -Match '(?m)^IDENTITY not logged in'
    }

    It 'does not nag about detect-only tools (te CLI) in the missing list' {
        $script:Output | Should -Not -Match 'missing:[^\r\n]*teCli'
    }

    It 'never re-checks informational PBIVIZ entries (Git identity has no executable)' {
        $ts = Get-Content (Join-Path $script:Root '.github\agent-docs\tool-status.json') -Raw | ConvertFrom-Json
        $ts.gitIdentity.found | Should -BeTrue
        $script:Output | Should -Not -Match 'gitIdentity'
    }

    It 'prints an honest PBIVIZ line from the mapping and the shipped helper' {
        $script:Output | Should -Match '(?m)^PBIVIZ\s+Viz Dev \| local Git NOT initialized - PBIVIZ work is not versioned \(skipped: synced path\)'
    }

    It 'does not warn about saved workspace files when none open this root' {
        $script:Output | Should -Not -Match 'LACK the nested-dispatch setting'
    }
}

Describe 'Get-SessionStatus.ps1 names a user-saved .code-workspace that lacks nested dispatch' {

    BeforeAll {
        # Fake VS Code workspaceStorage: one entry whose workspace.json points at a saved
        # .code-workspace that opens the scratch root via a RELATIVE path and has no setting
        # (the field case), one that opens an unrelated folder, one folder-mode entry.
        $script:Storage = Join-Path $script:Root 'fake-workspaceStorage'
        $script:WsDir = Join-Path $script:Root 'VS_Code_Sessions\Projects'
        New-Item -ItemType Directory -Path $script:Storage, $script:WsDir -Force | Out-Null
        $script:UserWs = Join-Path $script:WsDir 'My General.code-workspace'
        # WsDir is <Root>\VS_Code_Sessions\Projects, so three levels up + the root's leaf = Root.
        $rel = '../../../' + (Split-Path $script:Root -Leaf)
        [IO.File]::WriteAllText($script:UserWs, "{`n`t// my saved workspace`n`t`"folders`": [ { `"path`": `"$rel`" } ],`n`t`"settings`": { `"git.autoRepositoryDetection`": `"subFolders`" }`n}`n", (New-Object System.Text.UTF8Encoding($false)))
        $other = Join-Path $script:WsDir 'Other.code-workspace'
        [IO.File]::WriteAllText($other, (@{ folders = @(@{ path = 'C:/somewhere/else' }) } | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        foreach ($pair in @(@('aaaa', $script:UserWs), @('bbbb', $other))) {
            $d = Join-Path $script:Storage $pair[0]; New-Item -ItemType Directory -Path $d -Force | Out-Null
            $uri = 'file:///' + ([Uri]::EscapeUriString($pair[1].Replace('\', '/')) -replace ':', '%3A')
            [IO.File]::WriteAllText((Join-Path $d 'workspace.json'), (@{ workspace = $uri } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        }
        $d = Join-Path $script:Storage 'cccc'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'workspace.json'), (@{ folder = 'file:///c%3A/Users/x/folder' } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

        $env:FABRIC_AGENTIC_WORKSPACE_STORAGE = $script:Storage
        $env:FABRIC_AGENTIC_USER_SETTINGS = $script:NoUserSettings
        try { $script:Output2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script 2>&1 | Out-String }
        finally { Remove-Item Env:\FABRIC_AGENTIC_WORKSPACE_STORAGE, Env:\FABRIC_AGENTIC_USER_SETTINGS -ErrorAction SilentlyContinue }
    }

    It 'warns with the exact path of the saved workspace file that lacks the setting' {
        $script:Output2 | Should -Match 'LACK the nested-dispatch setting'
        $script:Output2 | Should -Match ([regex]::Escape($script:UserWs))
        $script:Output2 | Should -Not -Match 'Other\.code-workspace' -Because 'a workspace file that does not open this root is irrelevant'
    }

    It 'still reports settings.json as enabled (the two facts are independent) and says it is folder-only' {
        $script:Output2 | Should -Match 'Nested dispatch: enabled in \.vscode/settings\.json only'
    }

    It 'names the saved workspace file that does not list every skill folder, in neutral words' {
        $script:Output2 | Should -Match ('do not list every skill folder: ' + [regex]::Escape($script:UserWs))
        $script:Output2 | Should -Match 're-run the installer \(it adds only what is missing\) or enable the team in your user settings'
    }
}

Describe 'Get-SessionStatus.ps1 with the v0.7.2 USER-level setting in effect' {

    BeforeAll {
        $script:UserSettings = Join-Path $script:Root 'user-settings.json'
        # JSONC on purpose; one relative location that exists in the scratch root, one that does not.
        [IO.File]::WriteAllText($script:UserSettings, "{`n  // user prefs`n  `"chat.subagents.allowInvocationsFromSubagents`": true,`n  `"chat.agentSkillsLocations`": { `"skills-for-fabric/skills`": true, `"does/not/exist`": true, `"C:/abs/skills`": true },`n}`n", (New-Object System.Text.UTF8Encoding($false)))
        $env:FABRIC_AGENTIC_WORKSPACE_STORAGE = $script:Storage
        $env:FABRIC_AGENTIC_USER_SETTINGS = $script:UserSettings
        try { $script:Output3 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script 2>&1 | Out-String }
        finally { Remove-Item Env:\FABRIC_AGENTIC_WORKSPACE_STORAGE, Env:\FABRIC_AGENTIC_USER_SETTINGS -ErrorAction SilentlyContinue }
    }

    It 'reports nested dispatch as enabled at user level' {
        $script:Output3 | Should -Match 'Nested dispatch: enabled at user level \(every VS Code window\)'
    }

    It 'counts workspace-relative user locations under this root and adds the skill folder that was missing, in place' {
        $script:Output3 | Should -Match '2 workspace-relative in user settings'
        $script:Output3 | Should -Match 'Newly registered skill folders'
        $raw = [IO.File]::ReadAllText($script:UserSettings)
        $raw | Should -Match '// user prefs' -Because 'the user file is edited in place, comments survive'
        $raw | Should -Match '"power-bi-agentic-development/plugins/newplugin/skills": true'
        $raw | Should -Match '"does/not/exist": true'
        $raw | Should -Match '"C:/abs/skills": true'
        @([regex]::Matches($raw, 'allowInvocationsFromSubagents')).Count | Should -Be 1 -Because 'the dispatch flag is never touched by the status script'
    }

    It 'is idempotent: a second run adds nothing to the user file' {
        $before = [IO.File]::ReadAllText($script:UserSettings)
        $env:FABRIC_AGENTIC_WORKSPACE_STORAGE = $script:Storage
        $env:FABRIC_AGENTIC_USER_SETTINGS = $script:UserSettings
        try { $again = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script 2>&1 | Out-String }
        finally { Remove-Item Env:\FABRIC_AGENTIC_WORKSPACE_STORAGE, Env:\FABRIC_AGENTIC_USER_SETTINGS -ErrorAction SilentlyContinue }
        [IO.File]::ReadAllText($script:UserSettings) | Should -BeExactly $before
        $again | Should -Not -Match 'Newly registered skill folders'
    }

    It 'no longer warns about saved workspace files (the user-level setting covers them)' {
        $script:Output3 | Should -Not -Match 'LACK the nested-dispatch setting'
        $script:Output3 | Should -Match 'need no patch'
        $script:Output3 | Should -Not -Match 'do not list every skill folder' -Because 'user-level skill locations reach every window'
    }
}

Describe 'Get-SessionStatus.ps1 never writes to user settings without earlier consent' {

    It 'leaves the user file byte-identical when <Case>' -TestCases @(
        @{ Case = 'nested dispatch is on but no skill folder of this workspace is listed'; Text = "{`n  // other project`n  `"chat.subagents.allowInvocationsFromSubagents`": true,`n  `"chat.agentSkillsLocations`": { `"some/other/skills`": true }`n}`n" }
        @{ Case = 'this workspace is listed but nested dispatch is off'; Text = "{`n  `"chat.subagents.allowInvocationsFromSubagents`": false,`n  `"chat.agentSkillsLocations`": { `"skills-for-fabric/skills`": true }`n}`n" }
        @{ Case = 'the file has neither setting'; Text = "{`n  `"editor.fontSize`": 12`n}`n" }
    ) {
        $p = Join-Path $script:Root ('user-noconsent-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
        [IO.File]::WriteAllText($p, $Text, (New-Object System.Text.UTF8Encoding($false)))
        $env:FABRIC_AGENTIC_WORKSPACE_STORAGE = $script:Storage
        $env:FABRIC_AGENTIC_USER_SETTINGS = $p
        try { $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script 2>&1 | Out-String }
        finally { Remove-Item Env:\FABRIC_AGENTIC_WORKSPACE_STORAGE, Env:\FABRIC_AGENTIC_USER_SETTINGS -ErrorAction SilentlyContinue }
        [IO.File]::ReadAllText($p) | Should -BeExactly $Text
    }
}

Describe 'Get-SessionStatus.ps1 reports a held skills catalog and pinned paths missing on disk' {

    BeforeAll {
        $script:StatePath = Join-Path $script:Root '.github\agent-docs\skill-catalog-state.json'
        function Invoke-StatusRun {
            $env:FABRIC_AGENTIC_WORKSPACE_STORAGE = $script:Storage
            $env:FABRIC_AGENTIC_USER_SETTINGS = $script:NoUserSettings
            try { return (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script 2>&1 | Out-String) }
            finally { Remove-Item Env:\FABRIC_AGENTIC_WORKSPACE_STORAGE, Env:\FABRIC_AGENTIC_USER_SETTINGS -ErrorAction SilentlyContinue }
        }
        function Set-StatusCatalogState([string]$MicrosoftState, [object[]]$Pins) {
            $state = [ordered]@{
                schemaVersion = 1; productVersion = 'test'
                catalogs = [ordered]@{ 'skills-for-fabric' = [ordered]@{ state = $MicrosoftState; commit = '1111111'; upstreamCommit = '2222222' }; 'power-bi-agentic-development' = [ordered]@{ state = 'upstream' } }
                pins = @($Pins)
            }
            [IO.File]::WriteAllText($script:StatePath, ($state | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        }
        # The scratch catalogs are plain folders, so the script dates them by file time: make Microsoft's look 90 days old.
        $old = (Get-Date).AddDays(-90)
        Get-ChildItem -LiteralPath (Join-Path $script:Root 'skills-for-fabric') -Recurse -File | ForEach-Object { $_.LastWriteTime = $old }

        $present = [ordered]@{ path = 'skills-for-fabric/skills/demo-skill'; critical = $true }
        Set-StatusCatalogState 'upstream' @($present)
        $script:OutUpstream = Invoke-StatusRun
        Set-StatusCatalogState 'held' @($present, [ordered]@{ path = 'skills-for-fabric/skills/gone-skill'; critical = $true }, [ordered]@{ path = 'skills-for-fabric/skills/demo-skill/references/gone.md'; critical = $false })
        $script:OutHeld = Invoke-StatusRun
    }

    It 'NEGATIVE CONTROL: an old catalog that is not held gets the refresh hint and no hold line' {
        $script:OutUpstream | Should -Match 'Upstream older than 30 days: Microsoft \(\d+ d\)'
        $script:OutUpstream | Should -Not -Match 'Kept at the last compatible version'
        $script:OutUpstream | Should -Not -Match 'missing on disk'
    }

    It 'says a held catalog is kept at its last compatible version and does not nag to refresh it' {
        $script:OutHeld | Should -Match 'Kept at the last compatible version: skills-for-fabric \(upstream changed in a way this kit version does not support yet; nothing to do\)\.'
        $script:OutHeld | Should -Not -Match 'Upstream older than 30 days' -Because 'refreshing a held catalog changes nothing'
    }

    It 'counts only critical pinned paths that are missing and points at the installer, not at the user' {
        $script:OutHeld | Should -Match '(?m)^\s+1 skill path\(s\) the agents reference are missing on disk -> re-run the installer to regenerate the references\.'
        $lines = @($script:OutHeld -split "`r?`n" | Where-Object { $_ -match 'missing on disk|Kept at the last compatible' })
        $lines.Count | Should -Be 2
        ($lines -join ' ') | Should -Not -Match '(?i)\bmap\b|rename|choose' -Because 'an upstream skill change is never handed to the user as a mapping task'
    }
}

Describe 'Get-SessionStatus.ps1 registers a new skill folder without rewriting .vscode/settings.json' {

    BeforeAll {
        $script:SettingsPath = Join-Path $script:Root '.vscode\settings.json'
        $script:Jsonc = "{`r`n    // keep this comment`r`n    `"chat.subagents.allowInvocationsFromSubagents`": true,`r`n    `"chat.agentSkillsLocations`": {`r`n        `".github/skills`": true,`r`n        `"skills-for-fabric/skills`": true // trailing note`r`n    },`r`n    `"user.customKey`": `"keep-me`"`r`n}`r`n"
        [IO.File]::WriteAllText($script:SettingsPath, $script:Jsonc, (New-Object System.Text.UTF8Encoding($false)))
        $env:FABRIC_AGENTIC_WORKSPACE_STORAGE = $script:Storage
        $env:FABRIC_AGENTIC_USER_SETTINGS = $script:NoUserSettings
        try { $script:Output4 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script 2>&1 | Out-String }
        finally { Remove-Item Env:\FABRIC_AGENTIC_WORKSPACE_STORAGE, Env:\FABRIC_AGENTIC_USER_SETTINGS -ErrorAction SilentlyContinue }
        $script:SettingsAfter = [IO.File]::ReadAllText($script:SettingsPath)
    }

    It 'adds exactly the missing folder and reports it' {
        $script:SettingsAfter | Should -Match '"power-bi-agentic-development/plugins/newplugin/skills": true'
        $script:Output4 | Should -Match 'Newly registered skill folders \(reload window to load them\): power-bi-agentic-development/plugins/newplugin/skills'
        $script:Output4 | Should -Match 'Skill locations registered: 3 in \.vscode/settings\.json'
        $script:Output4 | Should -Match 'Nested dispatch: enabled in \.vscode/settings\.json only'
    }

    It 'keeps comments, order and every other line of the file' {
        $script:SettingsAfter | Should -Match '// keep this comment'
        $script:SettingsAfter | Should -Match '// trailing note'
        $before = @($script:Jsonc -split "`r`n")
        $after = @($script:SettingsAfter -split "`r`n")
        $after.Count | Should -Be ($before.Count + 1) -Because 'one line was added, nothing was reformatted'
        foreach ($line in @($before | Where-Object { $_ -and $_ -notmatch 'trailing note' })) { ($after -ccontains $line) | Should -BeTrue -Because "line '$line' must survive unchanged" }
        ($script:SettingsAfter.IndexOf('// keep this comment') -lt $script:SettingsAfter.IndexOf('user.customKey')) | Should -BeTrue
    }

    It 'leaves an unreadable settings file untouched and says how to repair it' {
        $broken = "{ `"chat.agentSkillsLocations`": { `".github/skills`": true `r`n"
        [IO.File]::WriteAllText($script:SettingsPath, $broken, (New-Object System.Text.UTF8Encoding($false)))
        $env:FABRIC_AGENTIC_WORKSPACE_STORAGE = $script:Storage
        $env:FABRIC_AGENTIC_USER_SETTINGS = $script:NoUserSettings
        try { $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script 2>&1 | Out-String }
        finally { Remove-Item Env:\FABRIC_AGENTIC_WORKSPACE_STORAGE, Env:\FABRIC_AGENTIC_USER_SETTINGS -ErrorAction SilentlyContinue }
        [IO.File]::ReadAllText($script:SettingsPath) | Should -BeExactly $broken
        $out | Should -Match 'Nested dispatch: unknown - \.vscode/settings\.json could not be read as JSON; re-run the installer to repair it'
        $out | Should -Not -Match 'Newly registered skill folders'
    }
}

Describe 'Get-SessionStatus.ps1 mentions agent working files only when they have piled up' {

    It 'NEGATIVE CONTROL: a tidy workspace gets no WORKFILES line' {
        $script:Output | Should -Not -Match '(?m)^WORKFILES'
    }

    It 'suggests a housekeeping preview when a legacy root scripts/ folder holds many agent scratch files' {
        $legacy = Join-Path $script:Root 'scripts'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        1..30 | ForEach-Object { Set-Content -LiteralPath (Join-Path $legacy ('agent013-probe-20250101-1010{0:d2}.ps1' -f $_)) -Value 'x' }
        Set-Content -LiteralPath (Join-Path $legacy 'my-own-tool.py') -Value 'x'
        $before = @(Get-ChildItem -LiteralPath $legacy -File).Count
        $env:FABRIC_AGENTIC_WORKSPACE_STORAGE = $script:Storage
        $env:FABRIC_AGENTIC_USER_SETTINGS = $script:NoUserSettings
        try { $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script 2>&1 | Out-String }
        finally { Remove-Item Env:\FABRIC_AGENTIC_WORKSPACE_STORAGE, Env:\FABRIC_AGENTIC_USER_SETTINGS -ErrorAction SilentlyContinue }
        $out | Should -Match '(?m)^WORKFILES agent working files: \d+ file\(s\), [^|]+\| legacy root scripts/: 31 file\(s\), 30 of them agent scratch \| quarantine: 0 file\(s\) -> suggest a housekeeping preview by Capability Maintenance'
        @(Get-ChildItem -LiteralPath $legacy -File).Count | Should -Be $before -Because 'the status script only counts'
        $out | Should -Match '(?m)^MCP\s+' -Because 'the helper is loaded in a child scope and must not disturb the rest of the block'
    }
}
