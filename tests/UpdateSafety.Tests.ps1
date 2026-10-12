# UpdateSafety.Tests.ps1
# -------------------------------------------------------------------
# Regression guards for the v0.7.1 update-mode hardening: an installer
# re-run must preserve what the user owns (workspace roots/settings,
# JSONC settings, user-authored agents) and only ever purge what it
# shipped itself. Helpers are AST-extracted from the real installer so
# the tests exercise shipped code, not a copy.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$null, [ref]$null)
    foreach ($name in 'ConvertFrom-JsonLenient', 'Merge-JsonSettings', 'Merge-CodeWorkspace', 'Write-ManagedFile', 'ConvertTo-SkillLocationKey', 'Get-UserWorkspaceFilesForRoot', 'Update-UserWorkspaceFile') {
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty -Because "$name must exist in the installer"
        Invoke-Expression $fn.Extent.Text
    }
    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("fabric_update_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Root | Out-Null
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
}

AfterAll {
    if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'ConvertFrom-JsonLenient (VS Code JSONC is not "malformed")' {

    It 'parses comments and trailing commas the way VS Code does' {
        $jsonc = @"
{
  // user comment
  "editor.fontSize": 14, /* block */
  "url": "https://example.com/not/a/comment",
  "list": [1, 2, 3,],
}
"@
        $o = ConvertFrom-JsonLenient $jsonc
        $o.'editor.fontSize' | Should -Be 14
        $o.url | Should -Be 'https://example.com/not/a/comment' -Because '// inside a string literal is not a comment'
        @($o.list).Count | Should -Be 3
    }

    It 'returns null for genuinely broken JSON' {
        ConvertFrom-JsonLenient '{ "a": ' | Should -BeNullOrEmpty
    }
}

Describe 'Merge-JsonSettings (settings.json survives the installer)' {

    It 'keeps user keys from a JSONC settings file instead of backing it up as malformed' {
        $p = Join-Path $script:Root '.vscode\settings.json'
        New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
        [IO.File]::WriteAllText($p, "{`n  // mine`n  `"editor.fontSize`": 15,`n}`n", $script:Utf8)
        Merge-JsonSettings $p @{ 'chat.subagents.allowInvocationsFromSubagents' = $true }
        $s = Get-Content $p -Raw | ConvertFrom-Json
        $s.'editor.fontSize' | Should -Be 15
        $s.'chat.subagents.allowInvocationsFromSubagents' | Should -BeTrue
        Test-Path "$p.bak" | Should -BeFalse -Because 'JSONC is valid input, not a malformed file'
    }
}

Describe 'Merge-CodeWorkspace (session workspace is merged, not rebuilt)' {

    It 'preserves user-added roots and settings from an existing session file' {
        $ws = Join-Path $script:Root 'session.code-workspace'
        $existing = @{
            folders  = @(@{ name = 'Old primary'; path = 'C:/somewhere/primary' }, @{ name = 'My extra root'; path = 'D:/extra' })
            settings = @{ 'editor.rulers' = @(100); 'chat.subagents.allowInvocationsFromSubagents' = $false }
        } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($ws, $existing, $script:Utf8)
        Merge-CodeWorkspace -Path $ws -WorkspaceName 'primary' -PrimaryRootPath 'C:\somewhere\primary'
        Test-Path $ws | Should -BeTrue -Because 'the merge must write back to the file it was given (no $Path shadowing)'
        $w = Get-Content $ws -Raw | ConvertFrom-Json
        @($w.folders).Count | Should -Be 2
        ($w.folders | Where-Object { $_.path -eq 'D:/extra' }).name | Should -Be 'My extra root'
        ($w.folders | Where-Object { $_.path -eq 'C:/somewhere/primary' }).name | Should -Be 'primary' -Because 'the managed primary root is renamed, not duplicated'
        @($w.settings.'editor.rulers')[0] | Should -Be 100
        $w.settings.'chat.subagents.allowInvocationsFromSubagents' | Should -BeTrue -Because 'nested dispatch is forced on'
    }

    It 'drops a stale relative "." root when the primary root is absolute' {
        $ws = Join-Path $script:Root 'legacy.code-workspace'
        [IO.File]::WriteAllText($ws, (@{ folders = @(@{ path = '.' }) } | ConvertTo-Json -Depth 5), $script:Utf8)
        Merge-CodeWorkspace -Path $ws -WorkspaceName 'p' -PrimaryRootPath 'C:\p'
        $w = Get-Content $ws -Raw | ConvertFrom-Json
        @($w.folders).Count | Should -Be 1
        $w.folders[0].path | Should -Be 'C:/p'
    }
}

Describe 'User-saved .code-workspace files (window-scoped settings)' {

    BeforeAll {
        # Layout: <Root>\ws is the installed workspace; a saved file in <Root>\sessions\sub
        # opens it via a relative path; fake workspaceStorage points at that file.
        $script:WsRoot = Join-Path $script:Root 'ws'
        $script:Sess = Join-Path $script:Root 'sessions\sub'
        $script:Storage = Join-Path $script:Root 'storage'
        New-Item -ItemType Directory -Path $script:WsRoot, $script:Sess, (Join-Path $script:Storage 'a') -Force | Out-Null
        $script:Saved = Join-Path $script:Sess 'Mine.code-workspace'
        [IO.File]::WriteAllText($script:Saved, "{`n`t// kept by the user`n`t`"folders`": [ { `"path`": `"../../ws`" } ],`n`t`"settings`": { `"chat.agentSkillsLocations`": { `"skills-for-fabric/skills`": true, `"C:/my/own/skills`": true } }`n}`n", $script:Utf8)
        $uri = 'file:///' + ([Uri]::EscapeUriString($script:Saved.Replace('\', '/')) -replace ':', '%3A')
        [IO.File]::WriteAllText((Join-Path $script:Storage 'a\workspace.json'), (@{ workspace = $uri } | ConvertTo-Json), $script:Utf8)
        $script:Required = @(
            (Join-Path $script:WsRoot '.github\skills'),
            (Join-Path $script:WsRoot 'skills-for-fabric\skills'),
            (Join-Path $script:WsRoot 'power-bi-agentic-development\plugins\pbip\skills')
        )
    }

    It 'reports the dispatch setting and only the skill locations the file does not already have' {
        $r = @(Get-UserWorkspaceFilesForRoot -RootPath $script:WsRoot -StorageRoot $script:Storage -RequiredSkillLocations $script:Required)
        $r.Count | Should -Be 1
        $r[0].Path | Should -Be $script:Saved
        $r[0].NestedDispatch | Should -BeFalse
        # relative 'skills-for-fabric/skills' in the file equals the absolute required one
        @($r[0].MissingSkillLocations).Count | Should -Be 2
        @($r[0].MissingSkillLocations) | Should -Not -Contain (Join-Path $script:WsRoot 'skills-for-fabric\skills')
    }

    It 'patch adds only what is missing, keeps user entries, writes no .bak, and reports dropped comments' {
        $r = @(Get-UserWorkspaceFilesForRoot -RootPath $script:WsRoot -StorageRoot $script:Storage -RequiredSkillLocations $script:Required)
        $hadComments = Update-UserWorkspaceFile -Path $script:Saved -SkillLocations $r[0].MissingSkillLocations
        $hadComments | Should -BeTrue
        Test-Path -LiteralPath "$($script:Saved).bak" | Should -BeFalse
        $w = Get-Content -LiteralPath $script:Saved -Raw | ConvertFrom-Json
        $w.settings.'chat.subagents.allowInvocationsFromSubagents' | Should -BeTrue
        $w.settings.'chat.agentSkillsLocations'.'C:/my/own/skills' | Should -BeTrue -Because 'user entries are preserved'
        $w.settings.'chat.agentSkillsLocations'.'skills-for-fabric/skills' | Should -BeTrue -Because 'an equivalent relative entry is not duplicated'
        $w.settings.'chat.agentSkillsLocations'.(Join-Path $script:WsRoot '.github\skills') | Should -BeTrue
        $w.folders[0].path | Should -Be '../../ws'
        (Get-Content -LiteralPath $script:Saved -Raw)[0] | Should -Be '{' -Because 'no BOM'
    }

    It 'is idempotent: after the patch a re-run finds nothing to update' {
        $r = @(Get-UserWorkspaceFilesForRoot -RootPath $script:WsRoot -StorageRoot $script:Storage -RequiredSkillLocations $script:Required |
            Where-Object { -not $_.NestedDispatch -or $_.MissingSkillLocations.Count -gt 0 })
        $r.Count | Should -Be 0
    }
}

Describe 'Installer source: manifest ownership and purge containment (static)' {

    BeforeAll { $script:Src = Get-Content -LiteralPath $script:Installer -Raw }

    It 'hashes only DECLARED agents into installed-manifest.json (user agents are never adopted)' {
        $script:Src | Should -Match '\$integrityTargets \+= @\(\$managedAgents \| ForEach-Object \{ Join-Path \$agentsDirPath \$_ \}\)'
        $script:Src | Should -Not -Match '\$integrityTargets \+= @\(\$writtenAgentFiles'
    }

    It 'rejects parent-directory and absolute paths from a previous manifest before purging' {
        $script:Src | Should -Match ([regex]::Escape('$rel -match ''(^|[\\/])\.\.([\\/]|$)'''))
        $script:Src | Should -Match ([regex]::Escape('$abs.StartsWith($rootCanonical, [StringComparison]::OrdinalIgnoreCase)'))
    }

    It 'counts a purge only after verifying the file is gone' {
        $script:Src | Should -Match ([regex]::Escape("if (Test-Path -LiteralPath `$abs) { throw 'still present after Remove-Item' }"))
    }

    It 'stages deletions of retired managed files in update commits' {
        $script:Src | Should -Match ([regex]::Escape('if (-not $exists -and -not $tracked) { continue }'))
        $script:Src | Should -Match ([regex]::Escape('@($purgedPaths)'))
    }

    It 'never deletes the session workspace file before merging it' {
        $block = [regex]::Match($script:Src, '(?s)if \(\$repositoryMapReadable\) \{.*?Merge-CodeWorkspace -Path \$sessionWorkspaceFilePath').Value
        $block | Should -Not -BeNullOrEmpty
        $block | Should -Not -Match 'Remove-Item -LiteralPath \$sessionWorkspaceFilePath'
    }

    It 'keys the session workspace file to the root path (two workspaces never share roots)' {
        $script:Src | Should -Match '\$sessionWorkspaceFilePath = Join-Path \(\[IO\.Path\]::GetTempPath\(\)\) \("\$\(Split-Path \$rootPath -Leaf\)-\$rootKey\.code-workspace"\)'
        $script:Src | Should -Not -Match '\$sessionWorkspaceFilePath = Join-Path \(\[IO\.Path\]::GetTempPath\(\)\) \$workspaceFileName'
    }

    It 'guards vendor refresh with a repository-root and expected-remote check' {
        $script:Src | Should -Match 'rev-parse --show-toplevel'
        $script:Src | Should -Match "Update-VendorClone \`"\`$rootPath\\skills-for-fabric\`" 'skills-for-fabric' -ExpectedRemote 'https://github.com/microsoft/skills-for-fabric.git'"
        $script:Src | Should -Match "Update-VendorClone \`"\`$rootPath\\power-bi-agentic-development\`" 'power-bi-agentic-development' -ExpectedRemote 'https://github.com/data-goblin/power-bi-agentic-development.git'"
    }

    It 'only accepts a winget payload after a normal zero exit' {
        $script:Src | Should -Match ([regex]::Escape('$completedOk = ($exited -and $proc.HasExited -and $proc.ExitCode -eq 0)'))
        $script:Src | Should -Match '(?s)if \(\$completedOk\) \{\s*\$fetched = Get-ChildItem'
    }

    It 'cleans up the previous tool copy only AFTER activation is committed' {
        $m = [regex]::Match($script:Src, '(?s)\$activated = \$true.*?\} catch \{.*?throw\s*\}\s*(.*?)return \$true')
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Match 'Remove-Item -LiteralPath \$backup' -Because 'backup removal must sit outside the rollback try/catch'
    }
}
