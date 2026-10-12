# Step1Prompts.Tests.ps1
# -------------------------------------------------------------------
# Drives the REAL installer through Step 1 only, with scripted answers, and
# asserts the folder it resolves. Reproduces the field bug where answering
# "y" at "Enter 1 or 2" fell into option 2 and a full path typed at the
# "name" prompt crashed Join-Path ("The given path's format is not supported").
# The run is aborted right after Step 1 by feeding EOF to the next prompt.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("fabric_step1_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Root | Out-Null

    # Run Step 1 with the given answer lines; returns the transcript. Any
    # folder created lands under $script:Root because USERPROFILE is redirected.
    # The process tree is killed as soon as Step 1 has printed its verdict so the
    # test never waits for Step 2's tool probes.
    function Invoke-Step1 {
        param([string[]]$Answers, [int]$TimeoutSec = 90)
        $answersFile = Join-Path $script:Root ([guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($answersFile, (($Answers -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        $outFile = "$answersFile.out"
        $cmd = 'set "USERPROFILE={2}"&& set FABRIC_AGENTIC_SKIP_VSCODE_LAUNCH=1&& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" < "{1}" > "{3}" 2>&1' -f $script:Installer, $answersFile, $script:Root, $outFile
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -PassThru -WindowStyle Hidden
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $text = ''
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            $text = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
            if ($text -match 'STEP 2 of 9|Press Enter to close|^ERROR' -or $p.HasExited) { break }
        }
        if (-not $p.HasExited) { & taskkill.exe /PID $p.Id /T /F 2>$null | Out-Null }
        Start-Sleep -Milliseconds 300
        return [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
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
}
