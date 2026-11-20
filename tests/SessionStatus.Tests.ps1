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

Describe 'Get-SessionStatus.ps1 keeps one status snapshot per session' {

    BeforeAll {
        $script:AgentDocs = Join-Path $script:Root '.github\agent-docs'
        $script:SnapDir = Join-Path $script:AgentDocs 'session-status'
        $script:LastFile = Join-Path $script:AgentDocs 'session-status.last.txt'
        $script:NoStorage = Join-Path $script:Root 'no-workspace-storage'
        New-Item -ItemType Directory -Path $script:NoStorage -Force | Out-Null
        function Start-StatusRun([string]$SessionId) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:Script + '"' + $(if ($SessionId) { ' -SessionId "' + $SessionId + '"' })
            $psi.WorkingDirectory = $env:TEMP
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardInput = $true
            $psi.EnvironmentVariables['FABRIC_AGENTIC_USER_SETTINGS'] = $script:NoUserSettings
            $psi.EnvironmentVariables['FABRIC_AGENTIC_WORKSPACE_STORAGE'] = $script:NoStorage
            $p = [Diagnostics.Process]::Start($psi)
            $p.StandardInput.Close()
            return [pscustomobject]@{ Process = $p; Out = $p.StandardOutput.ReadToEndAsync() }
        }
        function Wait-StatusRun($Run) { $Run.Process.WaitForExit(); return [pscustomobject]@{ Exit = $Run.Process.ExitCode; Text = [string]$Run.Out.Result } }
        function Invoke-StatusRun([string]$SessionId) { return (Wait-StatusRun (Start-StatusRun $SessionId)) }
        function Get-Block([string]$Text) { return (($Text -replace "`r`n", "`n").Trim()) }
    }

    It 'two sessions running at the same moment each keep their own complete block' {
        $a = Start-StatusRun 'session-alpha'; $b = Start-StatusRun 'session-beta'
        $ra = Wait-StatusRun $a; $rb = Wait-StatusRun $b
        $ra.Exit | Should -Be 0; $rb.Exit | Should -Be 0
        foreach ($pair in @(@('session-alpha', $ra), @('session-beta', $rb))) {
            $file = Join-Path $script:SnapDir "$($pair[0]).txt"
            Test-Path -LiteralPath $file | Should -BeTrue
            $saved = [IO.File]::ReadAllText($file)
            (Get-Block $saved) | Should -Be (Get-Block $pair[1].Text) -Because 'the snapshot is exactly the block this run printed'
            $saved | Should -Match "(?m)^SESSION\s+$($pair[0]) "
            $saved | Should -Match '(?m)^GENERATED \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}'
            $saved | Should -Match '(?m)^MCP\s+'
        }
        @(Get-ChildItem -LiteralPath $script:SnapDir -Filter *.tmp).Count | Should -Be 0
    }

    It 'a repeated run replaces the session''s own snapshot and leaves the other session''s file byte-identical' {
        $other = Join-Path $script:SnapDir 'session-beta.txt'
        $before = [IO.File]::ReadAllBytes($other)
        $first = [IO.File]::ReadAllText((Join-Path $script:SnapDir 'session-alpha.txt'))
        Start-Sleep -Milliseconds 1100
        $r = Invoke-StatusRun 'session-alpha'
        $now = [IO.File]::ReadAllText((Join-Path $script:SnapDir 'session-alpha.txt'))
        (Get-Block $now) | Should -Be (Get-Block $r.Text)
        $now | Should -Not -Be $first -Because 'the GENERATED stamp moved'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($other)) | Should -Be ([Convert]::ToBase64String($before))
        @(Get-ChildItem -LiteralPath $script:SnapDir -Filter 'session-alpha*').Count | Should -Be 1 -Because 'one file per session, not one per run'
    }

    It 'the shared file is only the latest run of any session, and says whose it is' {
        Invoke-StatusRun 'session-beta' | Out-Null
        $last = [IO.File]::ReadAllText($script:LastFile)
        $last | Should -Match '(?m)^SESSION\s+session-beta '
        (Get-Block $last) | Should -Be (Get-Block ([IO.File]::ReadAllText((Join-Path $script:SnapDir 'session-beta.txt'))))
        [IO.File]::ReadAllText((Join-Path $script:SnapDir 'session-alpha.txt')) | Should -Match '(?m)^SESSION\s+session-alpha ' -Because 'the other session''s own snapshot still holds its own block'
        $last | Should -Match 'session-status\.last\.txt is the latest run of any session'
    }

    It 'a caller that passes no id still gets the block, the shared file and an id of its own (earlier callers keep working)' {
        $r1 = Invoke-StatusRun ''; $r2 = Invoke-StatusRun ''
        $r1.Exit | Should -Be 0
        $r1.Text | Should -Match '(?m)^GENERATED \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}'
        $id1 = [regex]::Match($r1.Text, '(?m)^SESSION\s+(\S+) ').Groups[1].Value
        $id2 = [regex]::Match($r2.Text, '(?m)^SESSION\s+(\S+) ').Groups[1].Value
        $id1 | Should -Match '^[A-Za-z0-9_-]{12,64}$'
        $id2 | Should -Not -Be $id1 -Because 'generated ids do not collide'
        Test-Path -LiteralPath (Join-Path $script:SnapDir "$id1.txt") | Should -BeTrue
        (Get-Block ([IO.File]::ReadAllText($script:LastFile))) | Should -Be (Get-Block $r2.Text)
    }

    It 'an interrupted write never leaves a half-written snapshot: <Case>' -TestCases @(
        @{ Case = 'the snapshot is open in another program'; Kind = 'locked' }
        @{ Case = 'an earlier run died and left a temp file'; Kind = 'leftover' }
    ) {
        param($Case, $Kind)
        $file = Join-Path $script:SnapDir 'session-alpha.txt'
        $old = [IO.File]::ReadAllText($file)
        if ($Kind -eq 'locked') {
            $hold = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try { $r = Invoke-StatusRun 'session-alpha' } finally { $hold.Dispose() }
            $r.Exit | Should -Be 0 -Because 'the block on stdout does not depend on the file'
            $r.Text | Should -Match '(?m)^MCP\s+'
            $after = [IO.File]::ReadAllText($file)
            ($after -eq $old -or (Get-Block $after) -eq (Get-Block $r.Text)) | Should -BeTrue -Because 'the file is the old block or the new one, never a mixture'
        } else {
            $stale = Join-Path $script:SnapDir 'session-alpha.txt.4242.deadbeef.tmp'
            [IO.File]::WriteAllText($stale, 'GENERATED half a blo')
            (Get-Item -LiteralPath $stale).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
            $fresh = Join-Path $script:SnapDir 'session-gamma.txt.4243.cafe0001.tmp'
            [IO.File]::WriteAllText($fresh, 'another session is writing right now')
            $r = Invoke-StatusRun 'session-alpha'
            (Get-Block ([IO.File]::ReadAllText($file))) | Should -Be (Get-Block $r.Text)
            Test-Path -LiteralPath $stale | Should -BeFalse -Because 'a temp file older than a day belongs to a run that died'
            Test-Path -LiteralPath $fresh | Should -BeTrue -Because 'a recent temp file may be another session''s write in progress'
            Remove-Item -LiteralPath $fresh -Force
        }
    }

    It 'a missing snapshot folder is created again, and a session without a snapshot simply has no file' {
        Remove-Item -LiteralPath $script:SnapDir -Recurse -Force
        Test-Path -LiteralPath (Join-Path $script:SnapDir 'session-never-ran.txt') | Should -BeFalse
        $r = Invoke-StatusRun 'session-alpha'
        $r.Exit | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:SnapDir 'session-alpha.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:SnapDir 'session-never-ran.txt') | Should -BeFalse
    }

    It 'removes snapshots older than seven days and never a recent one of another session' {
        $old = Join-Path $script:SnapDir 'session-old.txt'; $recent = Join-Path $script:SnapDir 'session-recent.txt'
        [IO.File]::WriteAllText($old, 'old block'); [IO.File]::WriteAllText($recent, 'recent block of another session')
        (Get-Item -LiteralPath $old).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)
        (Get-Item -LiteralPath $recent).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2)
        $keep = Join-Path $script:SnapDir 'notes-of-the-user.md'
        [IO.File]::WriteAllText($keep, 'not a snapshot'); (Get-Item -LiteralPath $keep).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-30)
        Invoke-StatusRun 'session-alpha' | Out-Null
        Test-Path -LiteralPath $old | Should -BeFalse
        [IO.File]::ReadAllText($recent) | Should -Be 'recent block of another session'
        Test-Path -LiteralPath $keep | Should -BeTrue -Because 'only its own .txt snapshots are cleaned'
    }

    It 'a session id that is not a plain name never becomes a path' {
        $filesBefore = @(Get-ChildItem -LiteralPath $script:Root -Recurse -File | ForEach-Object { $_.FullName })
        $r = Invoke-StatusRun '..\..\outside\evil id'
        $r.Exit | Should -Be 0
        $id = [regex]::Match($r.Text, '(?m)^SESSION\s+(\S+) ').Groups[1].Value
        $id | Should -Match '^[A-Za-z0-9_-]{1,64}$'
        $new = @(Get-ChildItem -LiteralPath $script:Root -Recurse -File | ForEach-Object { $_.FullName } | Where-Object { $filesBefore -notcontains $_ })
        $new | Should -Be @((Join-Path $script:SnapDir "$id.txt"))
        Test-Path -LiteralPath (Join-Path (Split-Path $script:Root -Parent) 'outside') | Should -BeFalse
    }

    It 'the snapshot folder is ignored by Git, and the starting flow reads the session''s own file' {
        $installer = [IO.File]::ReadAllText($script:Installer)
        $installer | Should -Match '(?m)^\.github/agent-docs/session-status/\r?$' -Because 'the .gitignore template must list the snapshot folder'
        $flow = [IO.File]::ReadAllText((Join-Path $script:AgentDocs 'starting-flow.md'))
        $flow | Should -Match 'Get-SessionStatus\.ps1 -SessionId <id>'
        $flow | Should -Match '\.github/agent-docs/session-status/<id>\.txt'
        $flow | Should -Match 'session-status\.last\.txt[^\r\n]*latest run of any session'
    }
}
