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

Describe 'Documentation matches what the installer ships and asks' {

    BeforeAll {
        $root = Join-Path $PSScriptRoot '..'
        $script:Readme = Get-Content (Join-Path $root 'README.md') -Raw
        $script:CliDoc = Get-Content (Join-Path $root 'CLI-FUNCTIONALITIES.md') -Raw
        $script:TestsReadme = Get-Content (Join-Path $PSScriptRoot 'README.md') -Raw
        $m = [regex]::Match($script:Raw, '(?s)\$managedSkills = @\((.*?)\)')
        $m.Success | Should -BeTrue -Because 'the list of house skills has one source: $managedSkills'
        $script:ManagedSkills = @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        $script:Words = @('zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty')
    }

    It 'the README states the real number of house skills, and how they split' {
        $total = $script:ManagedSkills.Count
        $fabric = @($script:ManagedSkills | Where-Object { $_ -like 'fabric-*' }).Count
        $pbiviz = @($script:ManagedSkills | Where-Object { $_ -like 'pbiviz-*' }).Count
        ($fabric + $pbiviz) | Should -Be $total -Because 'every house skill is a fabric-* or a pbiviz-* skill; a new family needs a new sentence in the README'
        $script:Readme | Should -Match ([regex]::Escape("$($script:Words[$total]) embedded skills ($($script:Words[$fabric]) for Fabric, $($script:Words[$pbiviz]) for Power BI custom visual development)"))
        $script:Readme | Should -Match ([regex]::Escape("$total custom skills"))
        $script:Readme | Should -Match ([regex]::Escape("Writes the $($script:Words[$total]) maintainer-authored skills"))
        # No other count of house skills may linger anywhere in the README.
        $counted = 0
        foreach ($hit in [regex]::Matches($script:Readme, '(?i)\b(\w+) (embedded|custom|maintainer-authored) skills\b')) {
            $said = $hit.Groups[1].Value.ToLowerInvariant()
            if (($script:Words -notcontains $said) -and ($said -notmatch '^\d+$')) { continue }   # not a count (for example a heading)
            $counted++
            $said | Should -BeIn @($script:Words[$total], "$total") -Because "'$($hit.Value)' must state the real count"
        }
        $counted | Should -BeGreaterThan 2 -Because 'the scan must have found the counts it checks'
    }

    It 'the README names every house skill where Step 6 lists them, and no skill that is not shipped' {
        $line = [regex]::Match($script:Readme, '(?m)^No prompts\. Writes the .*$').Value
        $line | Should -Not -BeNullOrEmpty
        $named = @([regex]::Matches($line, '`((?:fabric|pbiviz)-[a-z0-9-]+)`') | ForEach-Object { $_.Groups[1].Value })
        @($named | Sort-Object) | Should -Be @($script:ManagedSkills | Sort-Object)
    }

    It 'the generated workspace guide names every Fabric house skill and counts the PBIVIZ ones correctly' {
        $guide = [regex]::Match($script:Raw, "(?s)\`$copilotInstructions = @'\r?\n(.*?)\r?\n'@")
        $guide.Success | Should -BeTrue
        foreach ($name in @($script:ManagedSkills | Where-Object { $_ -like 'fabric-*' })) {
            $guide.Groups[1].Value.Contains("``.github/skills/$name/SKILL.md``") | Should -BeTrue -Because "$name is described to the agents by its path"
        }
        $pbiviz = @($script:ManagedSkills | Where-Object { $_ -like 'pbiviz-*' }).Count
        $guide.Groups[1].Value | Should -Match ([regex]::Escape("$($script:Words[$pbiviz]) PBIVIZ house skills"))
    }

    It 'no document says a tool is installed without being asked' {
        foreach ($doc in @(@{ n = 'README.md'; t = $script:Readme }, @{ n = 'CLI-FUNCTIONALITIES.md'; t = $script:CliDoc }, @{ n = 'tests/README.md'; t = $script:TestsReadme })) {
            $doc.t | Should -Not -Match '(?i)auto-?install(s|ed)?\b|installed automatically|installs? (it|them) for you|Declined = remembered' -Because "$($doc.n) must describe consent as it is: every optional install asks"
            $doc.t.Contains([string][char]::ConvertFromUtf32(0x1F916)) | Should -BeFalse -Because "$($doc.n) no longer has an 'auto' category of tools"
        }
        $script:Readme | Should -Match 'only a typed `Y` or `YES` installs'
        $script:Readme | Should -Match '(?s)What counts as Yes\..*no answer at all.*all mean \*\*No\*\*'
        $script:Readme | Should -Match 'A \*\*No\*\* is not remembered'
    }

    It 'the README offers each recommended tool with the question the installer really asks' {
        foreach ($q in 'Install Fabric CLI (fab) now? (Y/N)', 'Install Python 3.12 for the current user now? (Y/N)', 'Install Azure CLI (az) now? (Y/N)') {
            $script:Readme.Contains($q) | Should -BeTrue -Because "the README quotes '$q'"
            $script:Raw.Contains($q) | Should -BeTrue -Because "the installer asks '$q'"
        }
        $script:Raw | Should -Match ([regex]::Escape('Install the VS Code extension $($mcp.Id) now? (Y/N)'))
        $script:Readme | Should -Match ([regex]::Escape('Install the VS Code extension <id> now? (Y/N)'))
    }

    It 'the documented switches exist in the installer' {
        $paramBlock = [regex]::Match($script:Raw, '(?ms)^param\((.*?)^\)').Groups[1].Value
        $paramBlock | Should -Not -BeNullOrEmpty
        foreach ($switch in 'EmitAgentsTo', 'VerifyRoot', 'StopAfterStep1') {
            $script:Readme | Should -Match ([regex]::Escape("-$switch"))
            $paramBlock | Should -Match ('\$' + $switch + '\b')
        }
    }

    It 'every test file is described in tests/README.md' {
        foreach ($f in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1')) {
            $script:TestsReadme.Contains('`' + $f.Name + '`') | Should -BeTrue -Because "$($f.Name) needs a row saying what it guards"
        }
    }
}

Describe 'Launchers report a run that failed or never started' {

    BeforeAll {
        $script:SetupBatPath = Join-Path (Split-Path $script:InstallerPath -Parent) 'Setup-FabricAgenticWorkspace.bat'
        $script:SetupBat = Get-Content -LiteralPath $script:SetupBatPath -Raw
        $script:TestsBat = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Run-Tests.bat') -Raw
        # The space in the folder name is deliberate: launchers must work from paths with spaces.
        $script:LauncherDir = Join-Path ([IO.Path]::GetTempPath()) ('fabric launcher ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:LauncherDir | Out-Null
        Copy-Item -LiteralPath $script:SetupBatPath -Destination $script:LauncherDir
        # Runs the copied launcher next to a stand-in script; the real installer is not involved.
        function Invoke-LauncherWithStandIn([string]$ScriptText) {
            [IO.File]::WriteAllText((Join-Path $script:LauncherDir 'Setup-FabricAgenticWorkspace.ps1'), $ScriptText)
            $bat = Join-Path $script:LauncherDir 'Setup-FabricAgenticWorkspace.bat'
            $out = (& cmd /c "`"$bat`" < NUL" 2>&1 | Out-String)
            return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = $out }
        }
    }

    AfterAll {
        if ($script:LauncherDir -and (Test-Path -LiteralPath $script:LauncherDir)) { Remove-Item -LiteralPath $script:LauncherDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the setup launcher keeps its documented PowerShell line and reads the exit code straight after it' {
        $script:SetupBat | Should -Match '(?m)^powershell\.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-FabricAgenticWorkspace\.ps1"\r?\nset "SETUP_EXIT=%ERRORLEVEL%"\r?$'
        @([regex]::Matches($script:SetupBat, '(?im)^\s*powershell')).Count | Should -Be 1 -Because 'the launcher starts PowerShell once, with the documented line only'
    }

    It 'the setup launcher says when setup did not complete and returns the exit code' {
        $script:SetupBat | Should -Match '(?m)^if not "%SETUP_EXIT%"=="0" echo  Setup did NOT complete: exit code %SETUP_EXIT%\.'
        $script:SetupBat | Should -Match 'Windows PowerShell could not be started from this window'
        $script:SetupBat.TrimEnd() | Should -Match 'exit /b %SETUP_EXIT%$'
    }

    It 'the test launcher exits 0 only when every test passed, and says which it was' {
        $script:TestsBat | Should -Match ([regex]::Escape('-PassThru; if ($r -and $r.Result -eq ''Passed'' -and $r.FailedCount -eq 0) { exit 0 } else { exit 1 }'))
        $script:TestsBat | Should -Match '(?m)^set "TESTS_EXIT=%ERRORLEVEL%"\r?$'
        $script:TestsBat | Should -Match '(?m)^if "%TESTS_EXIT%"=="0" echo RESULT: PASSED - no test failed\. Skipped and not-run tests are counted in the summary above\.\r?$'
        $script:TestsBat | Should -Not -Match 'ALL TESTS PASSED' -Because 'a run with skipped tests did not pass all tests'
        $script:TestsBat | Should -Match '(?m)^if not "%TESTS_EXIT%"=="0" echo RESULT: FAILED'
        $script:TestsBat | Should -Not -Match '(?im)^echo Done' -Because 'an unconditional "Done" reads as success'
        $script:TestsBat.TrimEnd() | Should -Match 'exit /b %TESTS_EXIT%$'
    }

    It 'a setup script that ends with an error is reported, with its exit code (stand-in script)' {
        $r = Invoke-LauncherWithStandIn 'Write-Host "stand-in setup"; exit 3'
        $r.Exit | Should -Be 3 -Because $r.Text
        $r.Text | Should -Match 'Setup did NOT complete: exit code 3\.'
    }

    It 'a setup script that ends normally is not reported as failed (stand-in script)' {
        $r = Invoke-LauncherWithStandIn 'Write-Host "stand-in setup"'
        $r.Exit | Should -Be 0 -Because $r.Text
        $r.Text | Should -Match 'stand-in setup'
        $r.Text | Should -Not -Match 'did NOT complete'
    }

    It 'the test launcher returns 0 for passed and skipped tests and 1 once a test fails (stand-in tests)' {
        $dir = Join-Path $script:LauncherDir 'tests stand-in'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Run-Tests.bat') -Destination $dir
        $bat = Join-Path $dir 'Run-Tests.bat'
        [IO.File]::WriteAllText((Join-Path $dir 'A.Tests.ps1'), "Describe 'stand-in' { It 'passes' { 1 | Should -Be 1 }; It 'is skipped' -Skip { 1 | Should -Be 2 } }")
        $passText = (& cmd /c "`"$bat`" < NUL" 2>&1 | Out-String)
        $passExit = $LASTEXITCODE
        $passExit | Should -Be 0 -Because $passText
        $passText | Should -Match 'RESULT: PASSED - no test failed'
        $passText | Should -Match 'Skipped:\s*1' -Because 'the skipped test stays visible in the summary'
        [IO.File]::WriteAllText((Join-Path $dir 'B.Tests.ps1'), "Describe 'stand-in failure' { It 'fails' { 1 | Should -Be 2 } }")
        $failText = (& cmd /c "`"$bat`" < NUL" 2>&1 | Out-String)
        $failExit = $LASTEXITCODE
        $failExit | Should -Be 1 -Because $failText
        $failText | Should -Match 'RESULT: FAILED'
        $failText | Should -Not -Match 'RESULT: PASSED'
    }
}

Describe 'Installer text survives Windows PowerShell 5.1 (Canary finding)' {

    # Windows PowerShell 5.1 reads a script without a byte order mark in the ANSI code page, so any
    # character outside ASCII reaches the generated agent files as two or three garbled characters.
    It 'the installer and its launcher hold ASCII characters only' {
        $dir = Split-Path $script:InstallerPath -Parent
        foreach ($name in 'Setup-FabricAgenticWorkspace.ps1', 'Setup-FabricAgenticWorkspace.bat') {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $dir $name))
            $found = @()
            $line = 1
            foreach ($b in $bytes) {
                if ($b -eq 10) { $line++ }
                elseif ($b -gt 127 -and $found -notcontains $line) { $found += $line }
            }
            ($found -join ', ') | Should -BeNullOrEmpty -Because "$name has non-ASCII bytes on these lines"
        }
    }
}
