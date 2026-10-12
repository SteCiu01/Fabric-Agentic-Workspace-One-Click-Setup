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
        powerBiModelMcpServer = @{ found = $true; category = 'mcp-extension'; extensionInstalled = $true; mcpToolsCallable = 'unknown' }
        fabricMcpServer = @{ found = $false; category = 'mcp-extension'; extensionInstalled = $false; mcpToolsCallable = 'unknown' }
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $script:Root '.github\agent-docs\tool-status.json'), $toolStatus, (New-Object System.Text.UTF8Encoding($false)))

    # 4. Run from an unrelated CWD.
    Push-Location $env:TEMP
    try { $script:Output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script 2>&1 | Out-String }
    finally { Pop-Location }
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

    It 'persists the block to session-status.last.txt as a stdout fallback' {
        $p = Join-Path $script:Root '.github\agent-docs\session-status.last.txt'
        Test-Path $p | Should -BeTrue
        (Get-Content $p -Raw) | Should -Match '(?m)^MCP\s+'
    }

    It 'reports not-logged-in without probing when the recorded CLIs are unavailable (offline-safe)' {
        $script:Output | Should -Match '(?m)^IDENTITY not logged in'
    }

    It 'does not nag about detect-only tools (te CLI) in the missing list' {
        $script:Output | Should -Not -Match 'missing:[^\r\n]*teCli'
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
        try { $script:Output2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script 2>&1 | Out-String }
        finally { Remove-Item Env:\FABRIC_AGENTIC_WORKSPACE_STORAGE -ErrorAction SilentlyContinue }
    }

    It 'warns with the exact path of the saved workspace file that lacks the setting' {
        $script:Output2 | Should -Match 'LACK the nested-dispatch setting'
        $script:Output2 | Should -Match ([regex]::Escape($script:UserWs))
        $script:Output2 | Should -Not -Match 'Other\.code-workspace' -Because 'a workspace file that does not open this root is irrelevant'
    }

    It 'still reports settings.json as enabled (the two facts are independent)' {
        $script:Output2 | Should -Match 'Nested dispatch: enabled in \.vscode/settings\.json'
    }
}
