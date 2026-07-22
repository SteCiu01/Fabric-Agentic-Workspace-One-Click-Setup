BeforeAll {
    . (Join-Path $PSScriptRoot 'Manifest.Helpers.ps1')
    $script:json     = Get-RawManifestJson
    $script:manifest = $script:json | ConvertFrom-Json
    $script:agents   = $script:manifest.agents
}

Describe 'Manifest - structure' {
    It 'embedded JSON is valid and parses' {
        { $script:json | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'declares a schemaVersion and semantic productVersion' {
        $script:manifest.schemaVersion | Should -BeGreaterThan 0
        $script:manifest.productVersion | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'defines exactly 47 agents' {
        $script:agents.Count | Should -Be 47
    }

    It 'has the expected tier counts (3 executive, 7 team-lead, 37 worker)' {
        ($script:agents | Where-Object level -eq 'executive').Count | Should -Be 3
        ($script:agents | Where-Object level -eq 'team-lead').Count  | Should -Be 7
        ($script:agents | Where-Object level -eq 'worker').Count     | Should -Be 37
    }
}

Describe 'Manifest - identity uniqueness' {
    It 'has unique agent ids' {
        $ids = $script:agents.id
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }

    It 'has unique display names' {
        $names = $script:agents.displayName
        ($names | Sort-Object -Unique).Count | Should -Be $names.Count
    }

    It 'has unique filenames' {
        $files = $script:agents.filename
        ($files | Sort-Object -Unique).Count | Should -Be $files.Count
    }

    It 'has unique two-digit filename prefixes' {
        $prefixes = $script:agents | ForEach-Object { ([regex]::Match($_.filename, '^\d+')).Value }
        ($prefixes | Sort-Object -Unique).Count | Should -Be $prefixes.Count
    }

    It 'ids match a lowercase-kebab pattern' {
        foreach ($a in $script:agents) {
            $a.id | Should -Match '^[a-z0-9-]+$' -Because "id '$($a.id)' must be lowercase-kebab"
        }
    }
}

Describe 'Manifest - schema (when Test-Json -Schema is available)' {
    It 'validates against agent-manifest.schema.json' {
        $supportsSchema = (Get-Command Test-Json -ErrorAction SilentlyContinue) -and
                          ($PSVersionTable.PSVersion.Major -ge 6)
        if (-not $supportsSchema) {
            Set-ItResult -Skipped -Because 'Test-Json -Schema requires PowerShell 6+ (runs in CI)'
            return
        }
        $schema = Get-Content -LiteralPath (Get-SchemaPath) -Raw
        { $script:json | Test-Json -Schema $schema -ErrorAction Stop } | Should -Not -Throw
    }
}
