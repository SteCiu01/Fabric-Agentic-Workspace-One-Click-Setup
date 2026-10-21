# PythonDetection.Tests.ps1
# -------------------------------------------------------------------
# Regression guard for the Step 2 field failure fixed in v0.7.3:
# "No real Python found" on a laptop that HAD Python (not on PATH),
# followed by an installer frozen at "Trying winget: Python.Python.3.12"
# (unbounded winget call). Exercises the detection logic with fake
# interpreters on a private PATH -- no real Python is required, no
# install is attempted, and the machine's PATH is restored afterwards.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $script:Raw = Get-Content -LiteralPath $script:Installer -Raw

    # Load the detection helpers and their script-level constants from the real source.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$null, [ref]$null)
    foreach ($name in 'Get-FabPythonRangeLabel', 'Get-PythonVersionOf', 'Find-RealPython') {
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty -Because "$name must exist in the installer"
        Invoke-Expression $fn.Extent.Text
    }
    foreach ($line in ($script:Raw -split "`r?`n" | Where-Object { $_ -match '^\$script:(FabPythonMin|FabPythonMaxExclusive|PythonProbeCache|LastPythonProbe)\s*=' })) {
        Invoke-Expression ($line -replace '\s+#.*$', '')
    }
    $script:FabPythonMin | Should -Not -BeNullOrEmpty

    $script:Fake = Join-Path ([System.IO.Path]::GetTempPath()) ("fabric_py_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Fake | Out-Null
    $script:Counter = Join-Path $script:Fake 'py-calls.txt'
    $script:SavedPath = $env:Path
    # Only the fake folder plus System32 (cmd.exe for .cmd shims). The Store alias
    # folder (%LOCALAPPDATA%\Microsoft\WindowsApps) and any real Python are excluded.
    $script:BasePath = "$($script:Fake);$env:SystemRoot\System32"

    $script:WriteShim = {
        param([string]$Name, [string]$Body)
        Set-Content -LiteralPath (Join-Path $script:Fake "$Name.cmd") -Value $Body -Encoding ascii
    }
    $script:ClearShims = {
        Get-ChildItem -LiteralPath $script:Fake -Filter '*.cmd' | Remove-Item -Force
        $script:PythonProbeCache = $null
        $script:LastPythonProbe = $null
    }
}

AfterAll {
    $env:Path = $script:SavedPath
    if ($script:Fake -and (Test-Path -LiteralPath $script:Fake)) { Remove-Item -LiteralPath $script:Fake -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Python detection helpers' {
    AfterEach { $env:Path = $script:SavedPath }

    It 'the supported range label is derived from the constants (currently 3.10-3.14)' {
        $expected = "$($script:FabPythonMin.Major).$($script:FabPythonMin.Minor)-$($script:FabPythonMaxExclusive.Major).$($script:FabPythonMaxExclusive.Minor - 1)"
        Get-FabPythonRangeLabel | Should -Be $expected
        Get-FabPythonRangeLabel | Should -Match '^3\.10-3\.1[4-9]$'
    }

    It 'Get-PythonVersionOf returns $null for a missing command without throwing under Stop' {
        $ErrorActionPreference = 'Stop'
        { Get-PythonVersionOf 'definitely-not-a-command-xyz' } | Should -Not -Throw
        Get-PythonVersionOf 'definitely-not-a-command-xyz' | Should -BeNullOrEmpty
    }

    It 'Get-PythonVersionOf rejects the Microsoft Store alias stub (stderr + non-zero exit)' {
        & $script:ClearShims
        & $script:WriteShim 'python' "@echo Python was not found; run without arguments to install from the Microsoft Store 1>&2`r`n@exit /b 9009"
        $env:Path = $script:BasePath
        $ErrorActionPreference = 'Stop'
        Get-PythonVersionOf 'python' | Should -BeNullOrEmpty
    }

    It 'Get-PythonVersionOf parses a real interpreter banner into a [version]' {
        & $script:ClearShims
        & $script:WriteShim 'python' "@echo Python 3.12.4`r`n@exit /b 0"
        $env:Path = $script:BasePath
        $v = Get-PythonVersionOf 'python'
        $v | Should -BeOfType [version]
        $v | Should -Be ([version]'3.12.4')
    }
}

Describe 'Find-RealPython (ranking, cache, fallbacks)' {
    AfterEach { $env:Path = $script:SavedPath }

    It 'prefers a supported interpreter over an unsupported one found earlier on PATH' {
        & $script:ClearShims
        & $script:WriteShim 'py'     "@echo.>>`"$($script:Counter)`"`r`n@echo Python 3.12.4`r`n@exit /b 0"
        & $script:WriteShim 'python' "@echo Python 3.9.1`r`n@exit /b 0"
        $env:Path = $script:BasePath
        $ErrorActionPreference = 'Stop'
        $py = Find-RealPython -Refresh
        $py | Should -Be 'py'
        $script:LastPythonProbe.Supported | Should -BeTrue
        $script:LastPythonProbe.Version | Should -Be ([version]'3.12.4')
        $script:LastPythonProbe.Source | Should -Be 'PATH'
    }

    It 'caches the probe for the run and re-probes only with -Refresh' {
        Remove-Item -LiteralPath $script:Counter -Force -ErrorAction SilentlyContinue
        & $script:ClearShims
        & $script:WriteShim 'py' "@echo.>>`"$($script:Counter)`"`r`n@echo Python 3.12.4`r`n@exit /b 0"
        $env:Path = $script:BasePath
        Find-RealPython -Refresh | Should -Be 'py'
        @(Get-Content -LiteralPath $script:Counter).Count | Should -Be 1
        Find-RealPython | Should -Be 'py'
        @(Get-Content -LiteralPath $script:Counter).Count | Should -Be 1 -Because 'a cached probe must not run the interpreter again'
        $script:LastPythonProbe.Version | Should -Be ([version]'3.12.4')
        Find-RealPython -Refresh | Should -Be 'py'
        @(Get-Content -LiteralPath $script:Counter).Count | Should -Be 2
    }

    It 'never returns the Store stub; looks beyond PATH when PATH has no real Python' {
        & $script:ClearShims
        & $script:WriteShim 'python' "@echo Python was not found 1>&2`r`n@exit /b 9009"
        $env:Path = $script:BasePath
        $ErrorActionPreference = 'Stop'
        $py = $null
        { $script:__py = Find-RealPython -Refresh } | Should -Not -Throw
        $py = $script:__py
        $py | Should -Not -Be 'python'
        if ($py) {
            # A real interpreter registered on this machine (PEP 514 / known folder).
            $script:LastPythonProbe.Source | Should -Be 'disk'
            $py | Should -Match '\\python\.exe$'
            Test-Path -LiteralPath $py | Should -BeTrue
            (Split-Path $py -Parent) | Should -BeIn @($env:Path -split ';') -Because 'a disk hit is put on the session PATH'
        } else {
            $script:LastPythonProbe | Should -BeNullOrEmpty
        }
    }

    It 'when PATH has only an unsupported Python, either a supported one is found elsewhere or the PATH one is kept (never null)' {
        & $script:ClearShims
        & $script:WriteShim 'python' "@echo Python 3.9.1`r`n@exit /b 0"
        $env:Path = $script:BasePath
        $py = Find-RealPython -Refresh
        $py | Should -Not -BeNullOrEmpty
        if ($script:LastPythonProbe.Source -eq 'PATH') {
            $py | Should -Be 'python'
            $script:LastPythonProbe.Supported | Should -BeFalse
            $script:LastPythonProbe.Version | Should -Be ([version]'3.9.1')
        } else {
            $script:LastPythonProbe.Supported | Should -BeTrue
            $script:LastPythonProbe.Version | Should -BeGreaterOrEqual $script:FabPythonMin
        }
    }

    It 'restores the session dirs of a cached disk hit after Sync-ToolPaths-style PATH rebuilds' {
        & $script:ClearShims
        $script:PythonProbeCache = @{ Invoke = 'C:\fake\python.exe'; Probe = @{ Invoke = 'C:\fake\python.exe'; Version = [version]'3.12.0'; Supported = $true; Source = 'disk' }; SessionDirs = @($script:Fake) }
        $env:Path = "$env:SystemRoot\System32"
        Find-RealPython | Should -Be 'C:\fake\python.exe'
        @($env:Path -split ';') | Should -Contain $script:Fake
    }
}

Describe 'Ensure-Python and Step 2 wiring (static)' {

    It 'the winget attempt is bounded by Start-Process + Wait-Process -Timeout (no bare & winget)' {
        $m = [regex]::Match($script:Raw, '(?s)function Ensure-Python \{.*?\n\}\r?\n')
        $m.Success | Should -BeTrue
        $body = $m.Value
        $body | Should -Not -Match '&\s+winget\s+install'
        $body | Should -Match 'Start-Process -FilePath \$wg\.Source -ArgumentList @\('
        $body | Should -Match 'Wait-Process -Timeout \$wingetTimeoutSec'
        $body | Should -Match "'--disable-interactivity'"
        $body | Should -Match 'Stop-Process -Force'
    }

    It 'Ensure-Python only accepts an interpreter the Fabric CLI supports and re-probes after installs' {
        $m = [regex]::Match($script:Raw, '(?s)function Ensure-Python \{.*?\n\}\r?\n')
        $body = $m.Value
        ([regex]::Matches($body, 'Find-RealPython -Refresh')).Count | Should -BeGreaterOrEqual 2
        $body | Should -Match '\$script:LastPythonProbe\.Supported'
        $body | Should -Match 'but the Fabric CLI needs \$range'
    }

    It 'Step 2 tells the user the real supported range instead of a hard-coded one' {
        $script:Raw | Should -Match 'Needs Python \$\(Get-FabPythonRangeLabel\)'
        $script:Raw | Should -Not -Match 'Needs Python 3\.10-3\.13'
    }

    It 'Find-RealPython probes the PEP 514 registry and the usual install folders' {
        $script:Raw | Should -Match 'HKCU:\\Software\\Python'
        $script:Raw | Should -Match 'HKLM:\\Software\\Python'
        $script:Raw | Should -Match 'Programs\\Python'
        $script:Raw | Should -Match 'miniconda3'
    }
}
