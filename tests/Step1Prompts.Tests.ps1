# Step1Prompts.Tests.ps1
# -------------------------------------------------------------------
# Drives the REAL installer through its Step 1 questions with scripted answers and
# asserts the folder it resolves. Reproduces the field bug where answering "y" at
# "Enter 1 or 2" fell into option 2 and a full path typed at the "name" prompt
# crashed Join-Path ("The given path's format is not supported").
#
# Safety by construction (v0.9.0): every run uses the installer's -StopAfterStep1
# prompt check, so the installer itself exits before the prerequisite step. No tool
# is detected, installed or updated, nothing is cloned or generated, and the test
# does not depend on killing a process to prevent any of that. The child gets its
# own USERPROFILE and a PATH that starts with tripwire shims (see Manifest.Helpers).

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("fabric_step1_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Root | Out-Null
    $script:UserPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
    $script:MachinePathBefore = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $script:ProfileBefore = @(Get-ChildItem -LiteralPath $env:USERPROFILE -Force -Name | Sort-Object)
    $script:Runs = New-Object 'System.Collections.Generic.List[object]'
    $script:StopMarker = '\[prompt check\] Step 1 complete\. Stopped before the prerequisite step'

    # Runs Step 1 with the given answer lines; returns the transcript. Any folder
    # created lands under $script:Root because USERPROFILE is replaced for the child.
    function Invoke-Step1 {
        param([string[]]$Answers = @(), [int]$TimeoutSec = 120)
        $r = Invoke-InstallerPromptCheck -Answers $Answers -ProfileRoot $script:Root -TimeoutSec $TimeoutSec
        $script:Runs.Add($r)
        return $r.Output
    }
}

AfterAll {
    if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
        Get-ChildItem -LiteralPath $script:Root -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Step 1 folder prompts (field-reported crash)' {

    It 'treats "y" as option 1 and accepts a full path typed as the folder name' {
        # Exactly the reported sequence: "y" then a full path. Must not crash and
        # must use the typed path, not nest it under the profile.
        $target = Join-Path $script:Root 'Fabric_Workspaces'
        $out = Invoke-Step1 -Answers @('y', $target, 'y')
        $out | Should -Not -Match "The given path's format is not supported"
        $out | Should -Match ([regex]::Escape("Workspace target: $target"))
        Test-Path -LiteralPath $target | Should -BeTrue
    }

    It 'option 2 honours a full path typed at the name prompt' {
        $target = Join-Path $script:Root 'Elsewhere\My Fabric'
        $out = Invoke-Step1 -Answers @('2', $target)
        $out | Should -Not -Match "The given path's format is not supported"
        $out | Should -Match ([regex]::Escape("Workspace target: $target"))
        Test-Path -LiteralPath $target | Should -BeTrue
    }

    It 'option 2 sanitises an invalid folder name instead of crashing' {
        $out = Invoke-Step1 -Answers @('2', 'Sales:Reports?')
        $out | Should -Not -Match 'ERROR'
        $out | Should -Match 'Folder name adjusted to: Sales-Reports-'
        Test-Path -LiteralPath (Join-Path $script:Root 'Sales-Reports-') | Should -BeTrue
    }

    It 're-asks on an unrecognised choice instead of silently picking option 2' {
        $out = Invoke-Step1 -Answers @('maybe', '2', 'ReAsked')
        $out | Should -Match 'Please answer 1 \(existing folder\) or 2'
        Test-Path -LiteralPath (Join-Path $script:Root 'ReAsked') | Should -BeTrue
    }

    It 'rejects a relative or malformed path for option 1 and re-asks' {
        $out = Invoke-Step1 -Answers @('1', 'just-a-name', '1', (Join-Path $script:Root 'Valid'), 'y')
        $out | Should -Match 'not a valid full path'
        Test-Path -LiteralPath (Join-Path $script:Root 'Valid') | Should -BeTrue
    }

    It 'creates a missing option 1 folder only on an explicit Yes: <Name> does not create it' -TestCases @(
        @{ Name = 'N'; Answer = 'n' }, @{ Name = 'an empty line'; Answer = '' }, @{ Name = 'other text'; Answer = 'maybe' }, @{ Name = 'end of input'; Answer = $null }
    ) {
        param($Name, $Answer)
        $target = Join-Path $script:Root ('NotCreated_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $answers = @('1', $target)
        if ($null -ne $Answer) { $answers += $Answer }   # $null = the answers end here (end of input)
        $out = Invoke-Step1 -Answers $answers
        $out | Should -Match 'Aborted\.'
        Test-Path -LiteralPath $target | Should -BeFalse
    }
}

Describe 'Prompt check safety: Step 1 tests cannot install anything' {

    It 'a completed Step 1 stops by itself with exit code 0 and never starts Step 2' {
        $existing = Join-Path $script:Root 'Existing'
        New-Item -ItemType Directory -Path $existing -Force | Out-Null
        # Option 1, the folder, then the answers end: every later question gets end of input.
        $r = Invoke-InstallerPromptCheck -Answers @('1', $existing) -ProfileRoot $script:Root
        $script:Runs.Add($r)
        $r.TimedOut | Should -BeFalse
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match $script:StopMarker
        $r.Output | Should -Not -Match 'STEP 2 of 9'
        $r.Output | Should -Not -Match 'Checking Prerequisites'
        @(Get-ChildItem -LiteralPath $existing -Force).Count | Should -Be 0 -Because 'the prompt check generates nothing in the workspace'
    }

    It 'end of input inside Step 1 ends the run without reaching Step 2 (<Name>)' -TestCases @(
        @{ Name = 'no answers at all'; Answers = @() },
        @{ Name = 'answers end at the folder name'; Answers = @('2') },
        @{ Name = 'answers end at the path'; Answers = @('1') }
    ) {
        param($Name, $Answers)
        $r = Invoke-InstallerPromptCheck -Answers $Answers -ProfileRoot $script:Root
        $script:Runs.Add($r)
        $r.TimedOut | Should -BeFalse -Because 'a run with no input must end by itself'
        $r.ExitCode | Should -Not -BeNullOrEmpty
        $r.Output | Should -Not -Match 'STEP 2 of 9'
        $r.Output | Should -Not -Match 'Checking Prerequisites'
    }

    It 'a workspace name that keeps colliding at end of input is skipped instead of looping' {
        $existing = Join-Path $script:Root 'Collide'
        New-Item -ItemType Directory -Path (Join-Path $existing 'Workspace 1') -Force | Out-Null
        $r = Invoke-InstallerPromptCheck -Answers @('1', $existing, '1') -ProfileRoot $script:Root -TimeoutSec 60
        $script:Runs.Add($r)
        $r.TimedOut | Should -BeFalse
        $r.Output | Should -Match 'No further input - Workspace 1 is skipped'
        $r.Output | Should -Match $script:StopMarker
    }

    It 'no run timed out, left a process behind, or called a package manager or tool' {
        $script:Runs.Count | Should -BeGreaterThan 0
        foreach ($r in $script:Runs) {
            $r.TimedOut | Should -BeFalse
            @($r.Survivors).Count | Should -Be 0
            @($r.TripwireHits) | Should -BeNullOrEmpty -Because 'Step 1 must not start any external program'
            $r.Output | Should -Not -Match 'STEP 2 of 9'
        }
    }

    It 'every file and folder the runs created is inside the disposable test folder' {
        [Environment]::GetEnvironmentVariable('Path', 'User') | Should -BeExactly $script:UserPathBefore
        [Environment]::GetEnvironmentVariable('Path', 'Machine') | Should -BeExactly $script:MachinePathBefore
        $now = @(Get-ChildItem -LiteralPath $env:USERPROFILE -Force -Name | Sort-Object)
        @(Compare-Object $script:ProfileBefore $now | Where-Object { $_.SideIndicator -eq '=>' } | ForEach-Object { $_.InputObject }) |
            Where-Object { $_ -match '^(Fabric Workspaces|Sales-Reports-|ReAsked|Elsewhere|Valid|Fabric_Workspaces)$' } | Should -BeNullOrEmpty
    }
}

Describe 'Prompt check entry point (static)' {

    BeforeAll {
        $script:Source = [IO.File]::ReadAllText($script:Installer)
        $script:Analysis = Get-PromptCheckAnalysis -Text $script:Source
        # Returns the problems found in the installer source after one deliberate change. The changed
        # text is only parsed, never run.
        function Get-ProblemsAfter {
            param([string]$Find, [string]$Replace)
            ([regex]::Matches($script:Source, [regex]::Escape($Find))).Count | Should -Be 1 -Because "the text to change must exist exactly once: $Find"
            return @((Get-PromptCheckAnalysis -Text $script:Source.Replace($Find, $Replace)).Problems)
        }
    }

    It 'the installer passes the static check: it stops before Step 2 and can reach nothing but questions before that' {
        @($script:Analysis.Problems) | Should -BeNullOrEmpty
        @($script:Analysis.Commands) | Should -Contain 'Read-Host'
        @($script:Analysis.Commands) | Should -Contain 'Read-ExplicitYes'
        @($script:Analysis.Commands).Count | Should -BeGreaterThan 15 -Because 'the check must really have walked Step 1 and its functions'
    }

    It 'no install, update, PATH, download, clone or file-generation function is reachable before the stop' {
        foreach ($name in 'Try-InstallOptionalTool', 'Ensure-Python', 'Install-AzCliViaVenv', 'Install-VsCodeExtension', 'Install-ViaWingetDownload',
            'Install-PortableZipTool', 'Install-FromLocalZip', 'Install-StagedToolPayload', 'Invoke-OptionalToolPrompt', 'Invoke-ToolUpdateCheck',
            'Invoke-ToolUpdateOffer', 'Sync-ToolPaths', 'Add-DirToPath', 'Find-RealPython', 'Update-VendorClone', 'Invoke-VendorRefreshWithHold',
            'Write-ManagedFile', 'Merge-JsonSettings', 'Merge-CodeWorkspace', 'Merge-McpJson', 'Update-UserSettingsInPlace', 'Get-FileBestEffort',
            'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-Process', 'winget', 'pip', 'python', 'py', 'git', 'code', 'az', 'fab', 'npm', 'msiexec') {
            @($script:Analysis.Commands) | Should -Not -Contain $name
        }
    }

    It 'Step 1 also stops by itself and says so (the message the prompt tests wait for)' {
        $script:Source | Should -Match "(?s)if \(\`$StopAfterStep1\) \{\s+Write-Host ''\s+Write-Host '  \[prompt check\] Step 1 complete\. Stopped before the prerequisite step: nothing was detected, installed or generated\.' -ForegroundColor Cyan\s+exit 0\s+\}"
    }

    It 'NEGATIVE CONTROL: <Name> is reported' -TestCases @(
        @{ Name = 'a missing script-level stop'; Find = 'if ($StopAfterStep1) { exit 0 }'; Replace = ''; Expect = 'precedes Step 2' },
        @{ Name = 'a stop with an extra condition'; Find = 'if ($StopAfterStep1) { exit 0 }'; Replace = 'if ($StopAfterStep1 -and $env:FABRIC_AGENTIC_X) { exit 0 }'; Expect = 'precedes Step 2' },
        @{ Name = 'a stop that does not exit'; Find = 'if ($StopAfterStep1) { exit 0 }'; Replace = 'if ($StopAfterStep1) { Write-Host stop }'; Expect = 'precedes Step 2' },
        @{ Name = 'a stop placed after the Step 2 banner'; Find = "if (`$StopAfterStep1) { exit 0 }"; Replace = "Show-Step 2 9 'early'`r`nif (`$StopAfterStep1) { exit 0 }"; Expect = 'precedes Step 2' },
        @{ Name = 'a parameter that is not a switch'; Find = '[switch]$StopAfterStep1'; Replace = '[string]$StopAfterStep1'; Expect = 'not declared as a switch' },
        @{ Name = 'an installer function before the stop'; Find = '# Unconditional second stop for the prompt check'; Replace = "Sync-ToolPaths`r`n# x"; Expect = 'function (Sync-ToolPaths|Add-DirToPath|Find-RealPython)' },
        @{ Name = 'an optional-tool prompt before the stop'; Find = '# Unconditional second stop for the prompt check'; Replace = "Invoke-OptionalToolPrompt -Key 'x' -Name 'x' -Aliases @('x')`r`n# x"; Expect = 'function Invoke-OptionalToolPrompt' },
        @{ Name = 'a program started before the stop'; Find = '# Unconditional second stop for the prompt check'; Replace = "& winget install --id Some.Package`r`n# x"; Expect = "can run 'winget'" },
        @{ Name = 'a cmdlet that is not on the allow-list'; Find = '# Unconditional second stop for the prompt check'; Replace = "Invoke-WebRequest 'https://example.invalid/x' -OutFile 'x'`r`n# x"; Expect = "can run 'Invoke-WebRequest'" },
        @{ Name = 'a computed command'; Find = '# Unconditional second stop for the prompt check'; Replace = "& `$env:ComSpec /c echo x`r`n# x"; Expect = 'computed command' },
        @{ Name = 'a persisted environment change'; Find = '# Unconditional second stop for the prompt check'; Replace = "[Environment]::SetEnvironmentVariable('Path', 'x', 'User')`r`n# x"; Expect = '\.SetEnvironmentVariable' },
        @{ Name = 'an install hidden in a new function'; Find = '# Unconditional second stop for the prompt check'; Replace = "function Invoke-Sneaky { Start-Process 'setup.exe' }`r`nInvoke-Sneaky`r`n# x"; Expect = "function Invoke-Sneaky can run 'Start-Process'" }
    ) {
        param($Name, $Find, $Replace, $Expect)
        $problems = Get-ProblemsAfter -Find $Find -Replace $Replace
        $problems | Should -Not -BeNullOrEmpty
        ($problems -join "`n") | Should -Match $Expect
    }

    It 'the launcher refuses to start a script that is not proven to stop, and starts nothing' {
        # A harmless stand-in, not the installer: even if it were started it would only print a line.
        $standIn = Join-Path $script:Root 'stand-in-installer.ps1'
        [IO.File]::WriteAllText($standIn, "param([string]`$EmitAgentsTo, [string]`$VerifyRoot, [switch]`$StopAfterStep1)`r`nfunction Show-Step { }`r`n[IO.File]::AppendAllText('$($standIn).started', 'x')`r`nShow-Step 2 9 'x'`r`n")
        { Invoke-InstallerPromptCheck -Answers @('1') -ProfileRoot $script:Root -InstallerPath $standIn } | Should -Throw '*not safe to run as a prompt check*'
        Test-Path -LiteralPath "$standIn.started" | Should -BeFalse -Because 'the script must not have been started'
    }
}

Describe 'Emergency stop of the test harness' {

    It 'stops a child that outlives the timeout together with its descendant and reports no survivor' {
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # A stand-in that never ends by itself and starts a second process. It is not the installer.
        $cmd = "Start-Process -FilePath '$powershell' -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 90' -WindowStyle Hidden; Start-Sleep -Seconds 90"
        $r = Invoke-BoundedChild -FilePath $powershell -Arguments ('-NoProfile -Command "{0}"' -f $cmd) -TimeoutSec 8
        $r.TimedOut | Should -BeTrue
        @($r.Stopped).Count | Should -BeGreaterOrEqual 2 -Because 'the child and the process it started are both stopped'
        @($r.Survivors).Count | Should -Be 0
        foreach ($id in @($r.Stopped)) {
            $alive = $false
            try { $alive = -not ([System.Diagnostics.Process]::GetProcessById($id)).HasExited } catch { $alive = $false }
            $alive | Should -BeFalse -Because "process $id must not be left running"
        }
    }

    It 'returns the exit code and output of a child that ends by itself' {
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $r = Invoke-BoundedChild -FilePath $powershell -Arguments '-NoProfile -Command "$l = [Console]::In.ReadLine(); Write-Output \"got:$l\"; exit 7"' -StdinText "hello`r`n" -TimeoutSec 60
        $r.TimedOut | Should -BeFalse
        $r.ExitCode | Should -Be 7
        $r.Output | Should -Match 'got:hello'
        @($r.Survivors).Count | Should -Be 0
    }
}
