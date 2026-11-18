# Consent.Tests.ps1
# -------------------------------------------------------------------
# Optional installs and updates need an explicit, current-run Yes (v0.9.0).
#
# Field defect this guards: with standard input at its end, Read-Host returns no
# value, and the old condition `$ans -notmatch '^(y|yes)$'` was then false, so the
# "skip" branch was not taken and optional tools were installed without any answer.
#
# Nothing here installs, downloads or updates anything:
#   * the installer's own functions are loaded from its source (never re-implemented,
#     the installer is never executed) and called with a dummy callback that only counts;
#   * Read-Host is mocked, or a tiny child PowerShell runs ONLY the consent helper with
#     a scripted standard input to observe the real end-of-input behaviour;
#   * Step 2 itself is checked on its syntax tree, not by running it.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $script:Raw = [IO.File]::ReadAllText($script:Installer)
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$null, [ref]$null)

    . (Get-InstallerFunctionLoader 'Test-ExplicitYes', 'Read-ExplicitYes', 'Read-DefaultYes', 'Set-ToolStatus', 'Invoke-OptionalToolPrompt',
        'Get-VersionToken', 'Test-UpdateAvailable', 'Invoke-ToolUpdateOffer', 'Get-FabPythonRangeLabel', 'Ensure-Python', 'Add-DirToPath')

    # Stand-ins for everything around the consent decision. None of them touches the machine.
    function Sync-ToolPaths { }
    function Update-InstallerPath { }
    function Get-ToolVersion { param([string]$Exe, [string[]]$VersionArgs) return $null }
    function Resolve-ToolCommand { param([string[]]$Aliases, [string[]]$SearchRoots) return $script:ToolHit }
    function Find-RealPython { param([switch]$Refresh) return $script:FakePython }
    function Get-FileBestEffort { param([string]$Url, [string]$OutFile) $script:DownloadCalls++; return $false }
    function Test-PublisherDownload { return $false }
    function Test-StagedExecutable { return $false }
    $script:FabPythonMin = [version]'3.10'
    $script:FabPythonMaxExclusive = [version]'3.15'

    # What the mocked Read-Host does for one test case.
    $script:Reply = {
        switch ($script:AnswerKind) {
            'value'   { return $script:AnswerValue }
            'null'    { return $null }
            'nothing' { return }
            'throw'   { throw 'input could not be read' }
        }
    }
    $script:Ask = @{ Key = 'demoTool'; Name = 'demo tool'; Purpose = 'test'; Provider = 'test'; Aliases = @('definitely-not-installed-demo-tool') }

    # Runs ONLY the consent helpers in a child PowerShell with the given standard input.
    $script:ChildDir = Join-Path ([IO.Path]::GetTempPath()) ('fabric_consent_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:ChildDir | Out-Null
    $helpers = (@('Test-ExplicitYes', 'Read-ExplicitYes', 'Read-DefaultYes') | ForEach-Object {
        $n = $_
        ($script:Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $false) | Select-Object -First 1).Extent.Text
    }) -join "`r`n"
    $script:ChildNew = Join-Path $script:ChildDir 'consent-new.ps1'
    [IO.File]::WriteAllText($script:ChildNew, $helpers + "`r`n" + 'if ($args[0] -eq ''default'') { "RESULT=" + (Read-DefaultYes ''q'') } else { "RESULT=" + (Read-ExplicitYes ''q'') }' + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    # The condition shipped up to v0.8.0, kept here only as a negative control.
    $script:ChildOld = Join-Path $script:ChildDir 'consent-old.ps1'
    [IO.File]::WriteAllText($script:ChildOld, '$ans = Read-Host ''q''' + "`r`n" + 'if ($ans -notmatch ''^(y|yes)$'') { ''RESULT=SKIP'' } else { ''RESULT=INSTALL'' }' + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

    $script:Hosts = @(@{ Label = 'Windows PowerShell 5.1'; Exe = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') })
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { $script:Hosts += @{ Label = 'PowerShell 7'; Exe = $pwsh.Source } }

    function Invoke-ConsentChild {
        param([string]$Exe, [string]$Script, [string]$Stdin = '', [string]$Mode = 'explicit', [switch]$NonInteractive)
        $flags = '-NoProfile -ExecutionPolicy Bypass'
        if ($NonInteractive) { $flags += ' -NonInteractive' }
        $remove = @(); if ($PSVersionTable.PSEdition -eq 'Core' -and $Exe -match 'WindowsPowerShell') { $remove = @('PSModulePath') }
        $r = Invoke-BoundedChild -FilePath $Exe -Arguments ('{0} -File "{1}" {2}' -f $flags, $Script, $Mode) -StdinText $Stdin -RemoveEnvironment $remove -TimeoutSec 90
        $r.TimedOut | Should -BeFalse
        return ([regex]::Match($r.Output, 'RESULT=(\w+)').Groups[1].Value)
    }
}

AfterAll {
    if ($script:ChildDir -and (Test-Path -LiteralPath $script:ChildDir)) { Remove-Item -LiteralPath $script:ChildDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Test-ExplicitYes: only Y or YES is a Yes' {

    It 'accepts <Text> (case and surrounding white space ignored)' -TestCases @(
        @{ Text = 'y' }, @{ Text = 'Y' }, @{ Text = 'yes' }, @{ Text = 'YES' }, @{ Text = 'Yes' }, @{ Text = 'yEs' },
        @{ Text = ' y' }, @{ Text = 'y ' }, @{ Text = '   yes   ' }, @{ Text = "`tY`t" }, @{ Text = "yes`r`n" }
    ) {
        param($Text)
        Test-ExplicitYes $Text | Should -BeTrue
    }

    It 'rejects the text <Text>' -TestCases @(
        @{ Text = '' }, @{ Text = ' ' }, @{ Text = "`t" }, @{ Text = "`r`n" },
        @{ Text = 'n' }, @{ Text = 'N' }, @{ Text = 'no' }, @{ Text = 'NO' },
        @{ Text = 'ye' }, @{ Text = 'yess' }, @{ Text = 'yes!' }, @{ Text = 'y y' }, @{ Text = 'y/n' }, @{ Text = '(y)' },
        @{ Text = 'ok' }, @{ Text = 'sure' }, @{ Text = 'true' }, @{ Text = '1' }, @{ Text = 'maybe' }, @{ Text = 'install' },
        @{ Text = "y`nn" }, @{ Text = "n`ny" }
    ) {
        param($Text)
        Test-ExplicitYes $Text | Should -BeFalse
    }

    It 'rejects no value, $null and anything that is not one string' {
        Test-ExplicitYes | Should -BeFalse
        Test-ExplicitYes $null | Should -BeFalse
        Test-ExplicitYes ([System.Management.Automation.Internal.AutomationNull]::Value) | Should -BeFalse
        Test-ExplicitYes @('y') | Should -BeFalse
        Test-ExplicitYes @('y', 'yes') | Should -BeFalse
        Test-ExplicitYes $true | Should -BeFalse
        Test-ExplicitYes 1 | Should -BeFalse
        Test-ExplicitYes ([char]'y') | Should -BeFalse
    }

    It 'always returns exactly one Boolean' {
        foreach ($v in @('y', 'n', '', $null)) {
            $r = @(Test-ExplicitYes $v)
            $r.Count | Should -Be 1
            $r[0] | Should -BeOfType [bool]
        }
    }
}

Describe 'Read-ExplicitYes and Read-DefaultYes (mocked input)' {

    It 'Read-ExplicitYes is true for the typed answer <Value>' -TestCases @(@{ Value = 'y' }, @{ Value = 'YES' }, @{ Value = '  Yes ' }) {
        param($Value)
        $script:AnswerKind = 'value'; $script:AnswerValue = $Value
        Mock Read-Host { & $script:Reply }
        Read-ExplicitYes 'q' | Should -BeTrue
        Should -Invoke Read-Host -Times 1 -Exactly
    }

    It 'Read-ExplicitYes is false for <Name>' -TestCases @(
        @{ Name = 'no value at all (end of input)'; Kind = 'nothing'; Value = $null },
        @{ Name = 'a null answer'; Kind = 'null'; Value = $null },
        @{ Name = 'an empty line'; Kind = 'value'; Value = '' },
        @{ Name = 'white space only'; Kind = 'value'; Value = '   ' },
        @{ Name = 'N'; Kind = 'value'; Value = 'N' },
        @{ Name = 'NO'; Kind = 'value'; Value = 'NO' },
        @{ Name = 'unexpected text'; Kind = 'value'; Value = 'install it' },
        @{ Name = 'a prompt that fails'; Kind = 'throw'; Value = $null }
    ) {
        param($Name, $Kind, $Value)
        $script:AnswerKind = $Kind; $script:AnswerValue = $Value
        Mock Read-Host { & $script:Reply }
        { $script:__r = Read-ExplicitYes 'q' } | Should -Not -Throw
        $script:__r | Should -BeFalse
        $script:__r | Should -BeOfType [bool]
    }

    It 'Read-DefaultYes accepts Enter and an explicit Yes only (<Name>)' -TestCases @(
        @{ Name = 'Enter'; Kind = 'value'; Value = ''; Expected = $true },
        @{ Name = 'y'; Kind = 'value'; Value = 'y'; Expected = $true },
        @{ Name = 'YES'; Kind = 'value'; Value = 'YES'; Expected = $true },
        @{ Name = 'n'; Kind = 'value'; Value = 'n'; Expected = $false },
        @{ Name = 'No'; Kind = 'value'; Value = 'No'; Expected = $false },
        @{ Name = 'unexpected text'; Kind = 'value'; Value = 'later'; Expected = $false },
        @{ Name = 'no value at all (end of input)'; Kind = 'nothing'; Value = $null; Expected = $false },
        @{ Name = 'a null answer'; Kind = 'null'; Value = $null; Expected = $false },
        @{ Name = 'a prompt that fails'; Kind = 'throw'; Value = $null; Expected = $false }
    ) {
        param($Name, $Kind, $Value, $Expected)
        $script:AnswerKind = $Kind; $script:AnswerValue = $Value
        Mock Read-Host { & $script:Reply }
        Read-DefaultYes 'q' | Should -Be $Expected
    }
}

Describe 'Real end of input in a child PowerShell (no mock)' {

    It '<Label>: Read-ExplicitYes on standard input "<Shown>" gives <Expected>' -TestCases @(
        @{ Shown = '(closed, nothing to read)'; Stdin = ''; Expected = 'False' },
        @{ Shown = 'y'; Stdin = "y`r`n"; Expected = 'True' },
        @{ Shown = '  YES  '; Stdin = "  YES  `r`n"; Expected = 'True' },
        @{ Shown = '(empty line)'; Stdin = "`r`n"; Expected = 'False' },
        @{ Shown = '(spaces)'; Stdin = "   `r`n"; Expected = 'False' },
        @{ Shown = 'n'; Stdin = "n`r`n"; Expected = 'False' },
        @{ Shown = 'no'; Stdin = "no`r`n"; Expected = 'False' },
        @{ Shown = 'whatever'; Stdin = "whatever`r`n"; Expected = 'False' }
    ) {
        param($Shown, $Stdin, $Expected)
        foreach ($h in $script:Hosts) {
            Invoke-ConsentChild -Exe $h.Exe -Script $script:ChildNew -Stdin $Stdin | Should -Be $Expected -Because "host: $($h.Label)"
        }
    }

    It 'a non-interactive host (Read-Host not available) is a No' {
        foreach ($h in $script:Hosts) {
            Invoke-ConsentChild -Exe $h.Exe -Script $script:ChildNew -Stdin "y`r`n" -NonInteractive | Should -Be 'False' -Because "host: $($h.Label)"
        }
    }

    It 'Read-DefaultYes: end of input is a No, Enter is a Yes' {
        foreach ($h in $script:Hosts) {
            Invoke-ConsentChild -Exe $h.Exe -Script $script:ChildNew -Stdin '' -Mode default | Should -Be 'False' -Because "host: $($h.Label)"
            Invoke-ConsentChild -Exe $h.Exe -Script $script:ChildNew -Stdin "`r`n" -Mode default | Should -Be 'True' -Because "host: $($h.Label)"
        }
    }

    It 'NEGATIVE CONTROL: the condition shipped up to v0.8.0 lets end of input through on Windows PowerShell 5.1' {
        # This is the defect: no answer at all took the install branch. If this ever reports SKIP the
        # control no longer reproduces the defect and the end-of-input cases above need another look.
        Invoke-ConsentChild -Exe $script:Hosts[0].Exe -Script $script:ChildOld -Stdin '' | Should -Be 'INSTALL'
        Invoke-ConsentChild -Exe $script:Hosts[0].Exe -Script $script:ChildOld -Stdin "n`r`n" | Should -Be 'SKIP'
    }

    It 'covers PowerShell 7 whenever pwsh is installed' -Skip:(-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        @($script:Hosts | Where-Object { $_.Label -eq 'PowerShell 7' }).Count | Should -Be 1
    }
}

Describe 'Optional tool prompt: the install callback runs only on an explicit Yes' {

    BeforeEach {
        $script:ToolStatus = [ordered]@{}
        $script:ToolHit = $null     # the tool is not on this machine
        $script:Ran = @{ n = 0 }
        $script:Callback = { $script:Ran.n++ }
    }

    It 'runs the callback exactly once for <Value>' -TestCases @(@{ Value = 'Y' }, @{ Value = 'y' }, @{ Value = 'YES' }, @{ Value = 'yes' }, @{ Value = ' Yes ' }) {
        param($Value)
        $script:AnswerKind = 'value'; $script:AnswerValue = $Value
        Mock Read-Host { & $script:Reply }
        Mock Write-Host { }
        Invoke-OptionalToolPrompt @script:Ask -Install $script:Callback
        $script:Ran.n | Should -Be 1
        $script:ToolStatus['demoTool'].reason | Should -Be 'install attempted; not detected'
    }

    It 'never runs the callback for <Name>' -TestCases @(
        @{ Name = 'no value at all (end of input)'; Kind = 'nothing'; Value = $null },
        @{ Name = 'a null answer'; Kind = 'null'; Value = $null },
        @{ Name = 'an empty line'; Kind = 'value'; Value = '' },
        @{ Name = 'white space only'; Kind = 'value'; Value = "  `t " },
        @{ Name = 'N'; Kind = 'value'; Value = 'N' },
        @{ Name = 'NO'; Kind = 'value'; Value = 'NO' },
        @{ Name = 'n'; Kind = 'value'; Value = 'n' },
        @{ Name = 'unexpected text'; Kind = 'value'; Value = 'yes please' },
        @{ Name = 'a failed or interrupted prompt'; Kind = 'throw'; Value = $null }
    ) {
        param($Name, $Kind, $Value)
        $script:AnswerKind = $Kind; $script:AnswerValue = $Value
        Mock Read-Host { & $script:Reply }
        Mock Write-Host { }
        { Invoke-OptionalToolPrompt @script:Ask -Install $script:Callback } | Should -Not -Throw
        $script:Ran.n | Should -Be 0
        $script:ToolStatus['demoTool'].found | Should -BeFalse
        $script:ToolStatus['demoTool'].reason | Should -Be 'not found; user declined'
    }

    It 'a No is not remembered: the next run asks again and a Yes then installs' {
        Mock Write-Host { }
        $script:AnswerKind = 'value'; $script:AnswerValue = 'n'
        Mock Read-Host { & $script:Reply }
        Invoke-OptionalToolPrompt @script:Ask -Install $script:Callback
        Invoke-OptionalToolPrompt @script:Ask -Install $script:Callback     # next run, the decline is still in the status table
        $script:Ran.n | Should -Be 0
        $script:AnswerValue = 'y'
        Invoke-OptionalToolPrompt @script:Ask -Install $script:Callback
        Should -Invoke Read-Host -Times 3 -Exactly
        $script:Ran.n | Should -Be 1
    }

    It 'a tool that is already present is recorded and neither asked about nor reinstalled' {
        $script:ToolHit = @{ command = 'demo'; path = 'C:\tools\demo.exe' }
        Mock Read-Host { throw 'must not ask' }
        Mock Write-Host { }
        Invoke-OptionalToolPrompt @script:Ask -Install $script:Callback
        Should -Invoke Read-Host -Times 0 -Exactly
        $script:Ran.n | Should -Be 0
        $script:ToolStatus['demoTool'].found | Should -BeTrue
        $script:ToolStatus['demoTool'].path | Should -Be 'C:\tools\demo.exe'
    }

    It 'asks before it can reach the install scriptblock (source order)' {
        $fn = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-OptionalToolPrompt' }, $false) | Select-Object -First 1
        $body = $fn.Extent.Text
        $ask = $body.IndexOf('if (-not (Read-ExplicitYes ')
        $run = $body.IndexOf('& $Install')
        $ask | Should -BeGreaterThan 0
        $run | Should -BeGreaterThan $ask
        ([regex]::Matches($body, [regex]::Escape('& $Install'))).Count | Should -Be 1
        $body | Should -Not -Match 'Read-Host'
    }
}

Describe 'Optional updates: the update callback runs only on an explicit Yes' {

    BeforeEach {
        $script:ToolStatus = [ordered]@{ demoTool = [ordered]@{ found = $true; version = '1.0.0' } }
        $script:UpdUnverified = 0; $script:UpdChecked = 0; $script:UpdOutdated = $false
        $script:Ran = @{ n = 0 }
        $script:Callback = { $script:Ran.n++ }
        $script:Redetect = { '1.0.0' }
    }

    It 'updates exactly once for <Value>' -TestCases @(@{ Value = 'Y' }, @{ Value = 'YES' }, @{ Value = ' yes ' }) {
        param($Value)
        $script:AnswerKind = 'value'; $script:AnswerValue = $Value
        Mock Read-Host { & $script:Reply }
        Mock Write-Host { }
        Invoke-ToolUpdateOffer 'demoTool' 'demo tool' '1.0.0' '2.0.0' $script:Callback $script:Redetect
        $script:Ran.n | Should -Be 1
    }

    It 'never updates for <Name>' -TestCases @(
        @{ Name = 'no value at all (end of input)'; Kind = 'nothing'; Value = $null },
        @{ Name = 'a null answer'; Kind = 'null'; Value = $null },
        @{ Name = 'an empty line'; Kind = 'value'; Value = '' },
        @{ Name = 'white space only'; Kind = 'value'; Value = '   ' },
        @{ Name = 'N'; Kind = 'value'; Value = 'N' },
        @{ Name = 'NO'; Kind = 'value'; Value = 'NO' },
        @{ Name = 'unexpected text'; Kind = 'value'; Value = 'update' },
        @{ Name = 'a failed or interrupted prompt'; Kind = 'throw'; Value = $null }
    ) {
        param($Name, $Kind, $Value)
        $script:AnswerKind = $Kind; $script:AnswerValue = $Value
        Mock Read-Host { & $script:Reply }
        Mock Write-Host { }
        { Invoke-ToolUpdateOffer 'demoTool' 'demo tool' '1.0.0' '2.0.0' $script:Callback $script:Redetect } | Should -Not -Throw
        $script:Ran.n | Should -Be 0
        $script:ToolStatus['demoTool'].version | Should -Be '1.0.0'
    }

    It 'does not even ask when no newer version is confirmed' {
        Mock Read-Host { throw 'must not ask' }
        Mock Write-Host { }
        Invoke-ToolUpdateOffer 'demoTool' 'demo tool' '2.0.0' '2.0.0' $script:Callback $script:Redetect
        Invoke-ToolUpdateOffer 'demoTool' 'demo tool' '2.0.0' $null $script:Callback $script:Redetect
        Invoke-ToolUpdateOffer 'demoTool' 'demo tool' $null '2.0.0' $script:Callback $script:Redetect
        Should -Invoke Read-Host -Times 0 -Exactly
        $script:Ran.n | Should -Be 0
    }

    It 'the update review uses this offer for every tool and the whole review is itself opt-in' {
        $fn = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ToolUpdateCheck' }, $false) | Select-Object -First 1
        $fn.Extent.Text | Should -Match ([regex]::Escape('$checkOne = ${function:Invoke-ToolUpdateOffer}'))
        $fn.Extent.Text | Should -Not -Match 'Read-Host'
        ([regex]::Matches($fn.Extent.Text, '& \$checkOne ')).Count | Should -BeGreaterOrEqual 8
        $script:Raw | Should -Match ([regex]::Escape('if (Read-ExplicitYes "  Check installed tools for updates now? (y/N)") {'))
    }
}

Describe 'Python for the Fabric CLI is installed only on an explicit Yes' {

    BeforeEach {
        $script:FakePython = $null; $script:LastPythonProbe = $null; $script:DownloadCalls = 0
        Mock Write-Host { }
        Mock Start-Process { throw 'no process may be started by this test' }
        Mock Remove-Item { }
        Mock Get-Command { $null } -ParameterFilter { "$Name" -eq 'winget' }
    }

    It 'reuses a supported Python without asking' {
        $script:FakePython = 'py'; $script:LastPythonProbe = @{ Invoke = 'py'; Version = [version]'3.12.4'; Supported = $true; Source = 'PATH' }
        Mock Read-Host { throw 'must not ask' }
        Ensure-Python | Should -Be 'py'
        Should -Invoke Read-Host -Times 0 -Exactly
        $script:DownloadCalls | Should -Be 0
    }

    It 'does not start any install route for <Name>' -TestCases @(
        @{ Name = 'no value at all (end of input)'; Kind = 'nothing'; Value = $null },
        @{ Name = 'an empty line'; Kind = 'value'; Value = '' },
        @{ Name = 'N'; Kind = 'value'; Value = 'N' },
        @{ Name = 'unexpected text'; Kind = 'value'; Value = 'python' },
        @{ Name = 'a failed prompt'; Kind = 'throw'; Value = $null }
    ) {
        param($Name, $Kind, $Value)
        $script:AnswerKind = $Kind; $script:AnswerValue = $Value
        Mock Read-Host { & $script:Reply }
        Ensure-Python | Should -BeNullOrEmpty
        $script:DownloadCalls | Should -Be 0
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Get-Command -Times 0 -Exactly -ParameterFilter { "$Name" -eq 'winget' }
    }

    It 'an unsupported Python is left alone and the same question is asked' {
        $script:FakePython = 'python'; $script:LastPythonProbe = @{ Invoke = 'python'; Version = [version]'3.9.1'; Supported = $false; Source = 'PATH' }
        $script:AnswerKind = 'value'; $script:AnswerValue = 'n'
        Mock Read-Host { & $script:Reply }
        Ensure-Python | Should -BeNullOrEmpty
        Should -Invoke Read-Host -Times 1 -Exactly
        $script:DownloadCalls | Should -Be 0
    }

    It 'reaches the install route only after Yes (the route itself is a stand-in here)' {
        $script:AnswerKind = 'value'; $script:AnswerValue = 'y'
        Mock Read-Host { & $script:Reply }
        Ensure-Python | Should -BeNullOrEmpty
        $script:DownloadCalls | Should -Be 1
        Should -Invoke Start-Process -Times 0 -Exactly
    }
}

Describe 'Step 2: every install route sits behind an explicit Yes (syntax tree)' {

    BeforeAll {
        # A call "can install" by name, or because it invokes a program with an install command line.
        # Printed instructions (Write-Host "... code --install-extension ...") are text, not calls, and
        # the asking wrapper Invoke-OptionalToolPrompt is not itself an install: the calls inside its
        # -Install script block are judged one by one.
        $script:InstallNames = @('Try-InstallOptionalTool', 'Ensure-Python', 'Install-AzCliViaVenv', 'Install-VsCodeExtension', 'Install-ViaWingetDownload',
            'Install-PortableZipTool', 'Install-FromLocalZip', 'Install-StagedToolPayload', 'Invoke-ToolUpdateCheck', 'Invoke-ToolUpdateOffer')
        $script:NativeNames = @('winget', 'winget.exe', 'pip', 'pip3', 'python', 'python3', 'py', 'az', 'code', 'code-insiders', 'msiexec', 'msiexec.exe', 'npm', 'npx', 'choco', 'dotnet')
        $script:InstallText = '(?i)\bwinget(\.exe)?\s+(install|upgrade)\b|-m\s+pip\s+install|\bpip3?\s+install\b|-m\s+venv\b|\baz\s+extension\s+(add|update)\b|--install-extension\b|\bmsiexec\b|\bnpm\s+(install|i)\b|\bchoco\s+install\b|\bdotnet\s+tool\s+install\b'
        $script:IsInstallCall = {
            param($cmd)
            $name = $cmd.GetCommandName()
            if ($script:InstallNames -contains $name) { return $true }
            $invokes = ($cmd.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand) -or ($script:NativeNames -contains $name)
            return ($invokes -and ($cmd.Extent.Text -match $script:InstallText))
        }
        $inFunction = {
            param($node)
            $n = $node.Parent
            while ($n) { if ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $true }; $n = $n.Parent }
            return $false
        }
        $all = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        $script:TopInstallCalls = @($all | Where-Object { -not (& $inFunction $_) -and (& $script:IsInstallCall $_) })
        # 'consent' = inside the body of `if (Read-ExplicitYes ...)`; 'prompt' = inside the -Install
        # script block handed to Invoke-OptionalToolPrompt (which asks first); 'none' = unguarded.
        $script:GuardOf = {
            param($cmd)
            $child = $cmd; $n = $cmd.Parent
            while ($n) {
                if ($n -is [System.Management.Automation.Language.IfStatementAst]) {
                    foreach ($clause in $n.Clauses) {
                        $inBody = ($child.Extent.StartOffset -ge $clause.Item2.Extent.StartOffset -and $child.Extent.EndOffset -le $clause.Item2.Extent.EndOffset)
                        if ($inBody -and $clause.Item1.Extent.Text -match '^Read-ExplicitYes\s') { return 'consent' }
                    }
                }
                if ($n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and $n.Parent -is [System.Management.Automation.Language.CommandAst] -and
                    $n.Parent.GetCommandName() -eq 'Invoke-OptionalToolPrompt') { return 'prompt' }
                $child = $n; $n = $n.Parent
            }
            return 'none'
        }
    }

    It 'finds the install routes of Step 2 (the check is not vacuous)' {
        $script:TopInstallCalls.Count | Should -BeGreaterOrEqual 12
        $names = @($script:TopInstallCalls | ForEach-Object { $_.GetCommandName() })
        foreach ($expected in 'Try-InstallOptionalTool', 'Ensure-Python', 'Install-AzCliViaVenv', 'Install-VsCodeExtension', 'Invoke-ToolUpdateCheck', 'winget') {
            $names | Should -Contain $expected
        }
    }

    It 'no install route can run without consent' {
        $unguarded = @($script:TopInstallCalls | Where-Object { (& $script:GuardOf $_) -eq 'none' } | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text.Split("`n")[0])" })
        $unguarded | Should -BeNullOrEmpty
    }

    It 'the recommended tools (Fabric CLI, Python, Azure CLI, MCP extensions, azure-devops, update review) are asked for directly' {
        foreach ($name in 'Try-InstallOptionalTool', 'Ensure-Python', 'Install-AzCliViaVenv', 'Install-VsCodeExtension', 'Invoke-ToolUpdateCheck') {
            foreach ($c in @($script:TopInstallCalls | Where-Object { $_.GetCommandName() -eq $name })) { (& $script:GuardOf $c) | Should -Be 'consent' -Because "$name at line $($c.Extent.StartLineNumber)" }
        }
        foreach ($c in @($script:TopInstallCalls | Where-Object { $_.Extent.Text -match '(?i)\bwinget\s+install\b.*Microsoft\.AzureCLI|\baz\s+extension\s+add\b' })) { (& $script:GuardOf $c) | Should -Be 'consent' }
        foreach ($q in 'Install Fabric CLI (fab) now? (Y/N)', 'Install Azure CLI (az) now? (Y/N)', 'Install the VS Code extension $($mcp.Id) now? (Y/N)',
            'Install the azure-devops az extension now? (Y/N)', 'Install Python 3.12 for the current user now? (Y/N)') {
            $script:Raw | Should -Match ([regex]::Escape($q))
        }
    }

    It 'NEGATIVE CONTROL: the guard check reports an install that is not behind consent' {
        $sample = [System.Management.Automation.Language.Parser]::ParseInput(@'
if (-not (Test-Something)) {
    Try-InstallOptionalTool -Name 'x'
}
if (Read-ExplicitYes 'q') { Write-Host 'yes' } else { Install-AzCliViaVenv }
if (Read-ExplicitYes 'q') { Ensure-Python }
& winget install --silent -e --id Some.Package
& $py -m pip install --upgrade some-package
Write-Host "Install it later: code --install-extension some.extension"
if ($answer -notmatch '^(y|yes)$') { Write-Host 'skipped' } else { & az extension add --name demo }
'@, [ref]$null, [ref]$null)
        $cmds = @($sample.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Where-Object { & $script:IsInstallCall $_ })
        @($cmds | ForEach-Object { $_.Extent.Text.Split(' ')[0] + ' ' + $_.Extent.Text.Split(' ')[1] }) | Should -Be @('Try-InstallOptionalTool -Name', 'Install-AzCliViaVenv ', 'Ensure-Python ', '& winget', '& $py', '& az') -Because 'printed instructions are not calls; every real install call is seen'
        (& $script:GuardOf $cmds[0]) | Should -Be 'none'
        (& $script:GuardOf $cmds[1]) | Should -Be 'none' -Because 'the else branch of a consent question is not consent'
        (& $script:GuardOf $cmds[2]) | Should -Be 'consent'
        (& $script:GuardOf $cmds[3]) | Should -Be 'none'
        (& $script:GuardOf $cmds[4]) | Should -Be 'none'
        (& $script:GuardOf $cmds[5]) | Should -Be 'none' -Because 'the condition shipped up to v0.8.0 is not the consent helper'
    }

    It 'nothing is recorded as automatically installed any more' {
        $script:Raw | Should -Not -Match "-InstallMode 'auto'"
        $script:Raw | Should -Not -Match 'Installing \$Name automatically'
        $script:Raw | Should -Not -Match 'Installing az CLI automatically'
        $script:Raw | Should -Not -Match 'not found -- installing \('
    }

    It 'detect-only tools are never prompted for or installed: <Key>' -TestCases @(
        @{ Key = 'teCli' }, @{ Key = 'tabularEditor3' }, @{ Key = 'powerbiReportAuthor' }, @{ Key = 'python' },
        @{ Key = 'node' }, @{ Key = 'npm' }, @{ Key = 'pbivizCli' }, @{ Key = 'gitIdentity' }, @{ Key = 'pbivizMcp' }
    ) {
        param($Key)
        $script:Raw | Should -Not -Match ("Invoke-OptionalToolPrompt -Key '{0}'" -f $Key)
        # Set-ToolStatus calls can span lines: check each whole call, not each line.
        $sets = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-ToolStatus' -and $n.Extent.Text -match ("-Key '{0}'" -f $Key) }, $true))
        $sets.Count | Should -BeGreaterThan 0
        foreach ($s in $sets) { $s.Extent.Text | Should -Match "-InstallMode 'detect'" }
    }

    It 'required prerequisites (Git, VS Code) are only detected, never installed' {
        $script:Raw | Should -Not -Match '(?i)--id\s+Git\.Git|--id\s+Microsoft\.VisualStudioCode|Git\.Git\b'
        $script:Raw | Should -Match ([regex]::Escape('$missing += "git (https://git-scm.com)"'))
    }
}

Describe 'Detection does not change the persisted PATH' {

    It 'Sync-ToolPaths and the CLI probe only ever add folders to the current session' {
        foreach ($name in 'Sync-ToolPaths', 'Test-CliResilient') {
            $fn = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false) | Select-Object -First 1
            $adds = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-DirToPath' }, $true))
            $adds.Count | Should -BeGreaterThan 0
            foreach ($a in $adds) { $a.Extent.Text | Should -Match '-SessionOnly' -Because "$name runs during detection" }
            $fn.Extent.Text | Should -Not -Match 'SetEnvironmentVariable'
        }
    }

    It 'Add-DirToPath -SessionOnly changes this process only' {
        $userBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
        $sessionBefore = $env:Path
        $dir = Join-Path $script:ChildDir 'session-only-tool'
        try {
            Add-DirToPath $dir -SessionOnly
            ($env:Path -split ';')[0] | Should -Be $dir
            [Environment]::GetEnvironmentVariable('Path', 'User') | Should -BeExactly $userBefore
        } finally { $env:Path = $sessionBefore }
    }
}
