#requires -Version 5.1
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:InstallerPath = Get-InstallerPath
    $script:Raw = Get-Content $script:InstallerPath -Raw
    $script:Manifest = Get-AgentManifest
}

Describe 'Version single source of truth' {

    It 'installer $productVersion is a semantic version' {
        $m = [regex]::Match($script:Raw, "(?m)^\`$productVersion\s*=\s*'(?<v>[^']+)'")
        $m.Success | Should -BeTrue
        $m.Groups['v'].Value | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'installer $productVersion matches the embedded manifest productVersion' {
        $m = [regex]::Match($script:Raw, "(?m)^\`$productVersion\s*=\s*'(?<v>[^']+)'")
        $installerVersion = $m.Groups['v'].Value
        $installerVersion | Should -Be $script:Manifest.productVersion -Because 'the two version stamps must not drift'
    }

    It 'manifest declares an integer schemaVersion' {
        # ConvertFrom-Json yields Int32 on Windows PowerShell 5.1 but Int64 on
        # PowerShell 7 (the CI runner), so accept either integral type.
        ($script:Manifest.schemaVersion -is [int] -or $script:Manifest.schemaVersion -is [long]) | Should -BeTrue
    }

    It 'README version line names the installer version (no doc drift)' {
        $readmePath = Join-Path $PSScriptRoot '..\README.md'
        (Test-Path $readmePath) | Should -BeTrue
        $readme = Get-Content $readmePath -Raw
        $ver = $script:Manifest.productVersion
        @([regex]::Matches($readme, '(?m)^\*\*Version:\*\*')).Count | Should -Be 1 -Because 'the README states its version in exactly one line'
        $readme | Should -Match ("(?m)^\*\*Version:\*\* v" + [regex]::Escape($ver) + '\s*$') -Because 'the README version line must track the installer version'
    }

    It 'CHANGELOG newest entry is the installer version (no doc drift)' {
        $changelogPath = Join-Path $PSScriptRoot '..\CHANGELOG.md'
        (Test-Path $changelogPath) | Should -BeTrue
        $changelog = Get-Content $changelogPath -Raw
        $ver = $script:Manifest.productVersion
        $first = [regex]::Match($changelog, '(?m)^## \[.*$').Value.TrimEnd()
        $first | Should -Match ("^## \[v" + [regex]::Escape($ver) + '\]( - \d{4}-\d{2}-\d{2})?$') -Because 'the newest CHANGELOG entry documents the installer version, either neutral or with its real release date'
    }

    It 'CHANGELOG versions are unique and descending, and every earlier entry carries its release date' {
        $changelog = Get-Content (Join-Path $PSScriptRoot '..\CHANGELOG.md') -Raw
        $heads = @([regex]::Matches($changelog, '(?m)^## \[v(?<v>\d+\.\d+\.\d+)(?<suffix>[-0-9A-Za-z.]*)\](?<rest>.*)$'))
        @([regex]::Matches($changelog, '(?m)^## \[')).Count | Should -Be $heads.Count -Because 'every release heading uses the ## [vX.Y.Z...] form'
        $versions = @($heads | ForEach-Object { [version]$_.Groups['v'].Value })
        for ($i = 1; $i -lt $versions.Count; $i++) { $versions[$i] | Should -BeLessThan $versions[$i - 1] -Because "entry $($i + 1) must be older than entry $i" }
        foreach ($h in @($heads | Select-Object -Skip 1)) { $h.Groups['rest'].Value.TrimEnd() | Should -Match '^ - \d{4}-\d{2}-\d{2}$' -Because "$($h.Value.Trim()) is a published release with a date" }
    }

    It '.bat launcher banner and window title match the installer version' {
        $batPath = Join-Path (Split-Path $script:InstallerPath -Parent) 'Setup-FabricAgenticWorkspace.bat'
        (Test-Path $batPath) | Should -BeTrue
        $bat = Get-Content $batPath -Raw
        $ver = $script:Manifest.productVersion
        $bat | Should -Match ([regex]::Escape("One-click Setup v$ver")) -Because 'the banner the user sees first must show the current version'
        $bat | Should -Match ([regex]::Escape("Setup v$ver")) -Because 'the console window title must show the current version'
        # No other version string may linger in the launcher.
        ([regex]::Matches($bat, 'v\d+\.\d+\.\d+') | ForEach-Object { $_.Value } | Sort-Object -Unique) | Should -Be @("v$ver")
    }

    It 'release documentation makes no contradictory version claims' {
        $ver = $script:Manifest.productVersion
        $docs = [ordered]@{}
        foreach ($n in 'README.md', 'CHANGELOG.md', 'SECURITY.md') { $docs[$n] = Get-Content (Join-Path $PSScriptRoot "..\$n") -Raw }
        @([regex]::Matches($docs['README.md'], '\bv\d+\.\d+\.\d+\b') | ForEach-Object { $_.Value } | Sort-Object -Unique) | Should -Be @("v$ver") -Because 'the README documents one version only'
        @([regex]::Matches($docs['SECURITY.md'], '\bv\d+\.\d+\.\d+\b')).Count | Should -Be 0 -Because 'the support policy is evergreen and names no specific version'
        $docs['SECURITY.md'] | Should -Match ([regex]::Escape('https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/releases')) -Because 'the current supported release is identified by the release listing'
        foreach ($n in $docs.Keys) {
            $docs[$n] | Should -Not -Match '(?i)\bunreleased\b|not yet published|development candidate|latest published (pre)?release is v' -Because "$n must not carry release-status claims that the release record owns"
        }
    }
}
