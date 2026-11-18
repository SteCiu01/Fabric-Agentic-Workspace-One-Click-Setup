# Neutrality.Tests.ps1
# -------------------------------------------------------------------
# The kit is distributed publicly. Its text files must not carry identifiers of the
# machines, tenants or organisations it was developed or tested on. This is a static
# scan of every text file in the repository (the installer is not run):
#   - every GUID is a placeholder or a documented Windows constant;
#   - no portal folder number, user-profile path, synced-drive path or staff-style id;
#   - no word on the private deny-list (kept as SHA-256, so the list reveals nothing);
#   - shipped skills and instructions describe their origin in neutral words.
# A new real-looking identifier fails here until it is replaced by a placeholder or, for a
# public platform constant, added to the allow-list below with what it is.

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $textExt = @('.ps1', '.bat', '.md', '.json', '.html', '.txt', '.yml', '.yaml', '.gitignore', '.gitattributes', '')
    $script:Texts = [ordered]@{}
    Get-ChildItem -LiteralPath $script:Repo -Recurse -File -Force | Where-Object {
        $_.FullName.Substring($script:Repo.Length + 1) -notmatch '^(\.git|\.venv)\\' -and ($textExt -contains $_.Extension.ToLowerInvariant())
    } | ForEach-Object { $script:Texts[$_.FullName.Substring($script:Repo.Length + 1)] = [IO.File]::ReadAllText($_.FullName) }

    function Get-Hits([string]$Pattern, [scriptblock]$Keep = { $true }) {
        $hits = @()
        foreach ($rel in $script:Texts.Keys) {
            foreach ($m in [regex]::Matches($script:Texts[$rel], $Pattern)) { if (& $Keep $m) { $hits += "${rel}: $($m.Value)" } }
        }
        return @($hits | Sort-Object -Unique)
    }
    function Get-Sha256([string]$Text) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    }
}

Describe 'Distributed files carry no private identifiers' {

    It 'scans the installer, the documentation and the tests' {
        $script:Texts.Count | Should -BeGreaterThan 25
        foreach ($must in 'fabric-agentic-installer\Setup-FabricAgenticWorkspace.ps1', 'README.md', 'CHANGELOG.md', 'CLI-FUNCTIONALITIES.md', 'tests\Neutrality.Tests.ps1', 'tests\fixtures\skill-catalog.snapshot.json') {
            $script:Texts.Contains($must) | Should -BeTrue -Because "$must must be part of the scan"
        }
    }

    It 'every GUID is a placeholder or a documented Windows constant' {
        $windowsConstants = @(
            '400e2d4a-1431-4c1a-a748-39ca472cfdb1'   # Delivery Optimization: IDOManager interface id
            'fbbd7fc0-c147-4727-a38d-827ef071ee77'   # Delivery Optimization: IDODownload interface id (fallback)
            'fbbd7fa9-8b12-4e28-a38d-3b4a5b9c8e5a'   # Delivery Optimization: IDODownload interface id (fallback)
            '5b99fa76-721c-423c-adac-56d03c8a8007'   # Delivery Optimization: COM class id
            '374de290-123f-4565-9164-39c4925e467b'   # Windows known folder: Downloads
        )
        $real = Get-Hits '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b' {
            param($m)
            $g = $m.Value.ToLowerInvariant()
            # A placeholder repeats one hex digit (00000000-..., 11111111-...).
            ($g -notmatch '^([0-9a-f])\1{7}-\1{4}-\1{4}-\1{4}-\1{12}$') -and ($windowsConstants -notcontains $g)
        }
        $real | Should -BeNullOrEmpty -Because 'a workspace, item, tenant or connection id must never be shipped; use a placeholder such as 00000000-0000-0000-0000-000000000000'
    }

    It 'NEGATIVE CONTROL: the GUID rule flags a real-looking id and accepts placeholders' {
        $rule = { param($g) ($g -notmatch '^([0-9a-f])\1{7}-\1{4}-\1{4}-\1{4}-\1{12}$') }
        # Assembled at run time so this file does not itself contain a real-looking id.
        (& $rule (@('3f2b8c1d', '4e5a', '4b6c', '9d7e', '8f9a0b1c2d3e') -join '-')) | Should -BeTrue
        (& $rule (@(('0' * 8), ('0' * 4), ('0' * 4), ('0' * 4), ('0' * 12)) -join '-')) | Should -BeFalse
        (& $rule (@(('1' * 8), ('1' * 4), ('1' * 4), ('1' * 4), ('1' * 12)) -join '-')) | Should -BeFalse
    }

    It 'no portal folder number is shipped (only a placeholder)' {
        Get-Hits '(?i)subfolderId=\d+' | Should -BeNullOrEmpty
    }

    It 'no user-profile path names a real account' {
        # Placeholders used in comments, examples and test data.
        $placeholder = '^(\.\.\.|[a-z]{1,2}|you|user|username|name|public|default|ABCDEF~1)$'
        $real = Get-Hits '(?i)[a-z](?::|%3A)[\\/]+Users[\\/]+([^\\/\s"''`<>|)]+)' {
            param($m)
            $name = $m.Groups[1].Value
            ($name -notmatch $placeholder) -and ($name -notmatch '^[<$%{]')
        }
        $real | Should -BeNullOrEmpty -Because 'paths must use %USERPROFILE%, $env:USERPROFILE or a placeholder'
    }

    It 'no synced-drive path names an organisation' {
        Get-Hits '(?i)OneDrive - \w+' | Should -BeNullOrEmpty
    }

    It 'no staff-style account id is shipped' {
        # One letter followed by six digits as a whole word; commit hashes and hex strings are longer tokens.
        Get-Hits '(?<![0-9A-Za-z_])[A-Za-z]\d{6}(?![0-9A-Za-z_])' | Should -BeNullOrEmpty
    }

    It 'no word on the private deny-list appears' {
        # SHA-256 of lower-cased words and numbers that identify where the kit was developed and tested.
        $deny = @(
            '07863e7a6a2154ba864a71b0818c5ed32f78999430254b2e272d461fcd0d34eb'
            '21181856ba8071eb94905487e90d61751e5168a6a1f85f4492ec5a7bfc706734'
            '44db2e578169fbf0d62c89ad7740ffcb966d2faa5ceffb7d1d311c621cc4243a'
        )
        $filesByWord = @{}
        foreach ($rel in $script:Texts.Keys) {
            foreach ($m in [regex]::Matches($script:Texts[$rel], '(?<![A-Za-z0-9])[A-Za-z0-9]{6,12}(?![A-Za-z0-9])')) {
                $w = $m.Value.ToLowerInvariant()
                if (-not $filesByWord.ContainsKey($w)) { $filesByWord[$w] = $rel }
            }
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hits = @($filesByWord.Keys | Where-Object { $deny -contains ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($_)))).Replace('-', '').ToLowerInvariant() } | ForEach-Object { $filesByWord[$_] })
        } finally { $sha.Dispose() }
        $filesByWord.Count | Should -BeGreaterThan 1000 -Because 'the scan must really have read the files'
        $hits | Should -BeNullOrEmpty -Because 'these files name a private organisation, account or location'
    }

    It 'NEGATIVE CONTROL: the deny-list check can match (the hash routine is the one the list was built with)' {
        Get-Sha256 'abc' | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }
}

Describe 'Shipped skills and instructions describe themselves neutrally' {

    It 'the installer text has no private-origin wording' {
        $t = $script:Texts['fabric-agentic-installer\Setup-FabricAgenticWorkspace.ps1']
        foreach ($phrase in 'in-house', 'battle-tested', 'field-tested', 'production work', 'production reports', 'production Fabric pipelines', 'maintainer''s production', 'field experience') {
            $t | Should -Not -Match ('(?i)' + [regex]::Escape($phrase)) -Because "'$phrase' ties shipped guidance to a private project"
        }
    }

    It 'the house PBIVIZ skills name chart types, not private project folders' {
        $t = $script:Texts['fabric-agentic-installer\Setup-FabricAgenticWorkspace.ps1']
        $t | Should -Not -Match 'ibcsBarChart|ibcsColumnChart|ibcsVarianceColumnChart|varianceLineChart'
        $t | Should -Match 'bar, column, variance column\s+and variance line'
    }
}
