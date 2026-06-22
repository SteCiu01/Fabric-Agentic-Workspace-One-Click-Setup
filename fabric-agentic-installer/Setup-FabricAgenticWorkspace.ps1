<#
.SYNOPSIS
    Fabric Agentic Workspace  -- One-click bootstrap
.DESCRIPTION
    Run this script to set up a guided Fabric agentic workspace
    with a Fabric Master Agent, specialist agents, Microsoft & data-goblin skills,
    custom TMDL and Pipeline skills, and copilot instructions.
    Once complete it opens the folder in VS Code  -- select Fabric Master Agent
    from the Copilot Chat dropdown and type anything to start.
.NOTES
    Requirements: git, VS Code 1.117.0+ with GitHub Copilot.
    Optional CLIs (workspace works without them): Fabric CLI `fab` (recommended,
    `pip install ms-fabric-cli`) and Azure CLI `az` (fallback for SQL/TDS and
    non-Fabric token audiences).
    This script is the source of truth for managed agents and skills.
    It will overwrite its own files but leave unmanaged files untouched.
#>

# Keep the window open on any error so the user can read it
$ErrorActionPreference = 'Stop'
trap {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    Read-Host "`nPress Enter to close"
    exit 1
}

# =====================================================================
# PACKAGE MANIFEST  -- files managed by this installer
# These will be created or overwritten. All other files are left alone.
# =====================================================================
$managedAgents = @(
    '1-fabric-workspace-master-agent.agent.md',
    '2-fabric-skills-maintainer.agent.md',
    '3-semantic-model-agent.agent.md',
    '4-fabric-data-engineer.agent.md',
    '5-fabric-admin.agent.md',
    '6-fabric-app-dev.agent.md',
    '7-fabric-reports-agent.agent.md',
    '8-fabric-pipelines-agent.agent.md'
)
$managedSkills = @(
    'fabric-tmdl',
    'fabric-pipelines',
    'fabric-cli-policy'
)
$managedConfigs = @(
    '.github\copilot-instructions.md',
    '.github\agent-docs\starting-flow.md',
    '.github\agent-docs\working-flow-reference.md',
    'AGENTS.md',
    '.gitignore',
    '.vscode\tasks.json',
    '.vscode\settings.json'
)

# -- Helper: step banner ------------------------------------------------
function Show-Step ([int]$Number, [int]$Total, [string]$Title) {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  STEP $Number of $Total - $Title" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
}

# -- Helper: safe file write (creates parent dirs) ----------------------
function Write-ManagedFile ([string]$Path, [string]$Content) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -Path $Path -Value $Content -Encoding UTF8
}

# -- Helper: locate a REAL, runnable Python interpreter -----------------
# On Windows, `python` / `python3` on PATH are often the Microsoft Store
# "App execution alias" stubs that only print "Python was not found" and exit
# non-zero. Get-Command still finds them, so we must actually RUN --version and
# confirm a real "Python 3.x" before trusting the interpreter for pip installs.
# Returns the usable launcher string (e.g. 'py' / 'python') or $null.
function Find-RealPython {
    foreach ($cand in @('py', 'python', 'python3')) {
        if (-not (Get-Command $cand -ErrorAction SilentlyContinue)) { continue }
        try {
            $v = (& $cand --version 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $v -match 'Python\s+3') { return $cand }
        } catch { }
    }
    return $null
}

# -- Helper: refresh the current-session PATH from Machine + User scopes -
# A freshly installed tool updates the persisted PATH but not the in-memory one,
# which is the usual reason a successful install still reports "not found".
function Update-InstallerPath {
    $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

# -- Helper: add a dir to the session PATH and persist it (User scope) ---
# Idempotent. Ensures a newly installed tool resolves both now and on the next
# VS Code/terminal launch without a manual restart.
function Add-DirToPath {
    param([string]$Dir)
    if (-not $Dir) { return }
    if ($env:Path -notlike "*$Dir*") { $env:Path = "$Dir;$env:Path" }
    try {
        $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -notlike "*$Dir*") {
            [System.Environment]::SetEnvironmentVariable(
                'Path', ((@($userPath, $Dir) | Where-Object { $_ }) -join ';'), 'User')
        }
    } catch { }
}

# -- Helper: make tools installed by THIS or a PREVIOUS run discoverable -
# The #1 reason a freshly-installed CLI still reports "not found" is that its
# folder is not on the in-memory PATH yet. This refreshes PATH from the registry
# (Machine + User) and proactively adds the Python user/script dirs where pip
# drops console scripts (fab.exe, az.exe). Idempotent; safe to call repeatedly.
# Calling it at the START of the prerequisite step is what lets run N recognise
# what run N-1 actually installed -- so the "not found" list shrinks each run.
function Sync-ToolPaths {
    # 1. Pull the persisted PATH (a previous run may have appended to User scope).
    $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'

    # 2. Ask a real Python where it drops scripts and add those dirs.
    $py = Find-RealPython
    if ($py) {
        try {
            $dirs = & $py -c "import site,sys,os; print(os.path.join(sys.prefix,'Scripts')); print(os.path.join(site.getuserbase(),'Scripts'))" 2>$null
            foreach ($d in @($dirs)) { if ($d -and (Test-Path $d)) { Add-DirToPath $d } }
        } catch { }
    }

    # 3. Sweep the common per-user Python Scripts locations -- covers the case
    #    where the interpreter that installed the package is no longer on PATH.
    foreach ($root in @("$env:APPDATA\Python", "$env:LOCALAPPDATA\Programs\Python")) {
        if (Test-Path $root) {
            Get-ChildItem $root -Recurse -Directory -Filter 'Scripts' -ErrorAction SilentlyContinue |
                ForEach-Object { Add-DirToPath $_.FullName }
        }
    }
}

# -- Helper: resilient "is this CLI on PATH yet?" check ---------------------
# A just-installed CLI often fails a single Get-Command because its Scripts
# folder is not on the in-memory PATH yet. This re-syncs PATH and retries a few
# times, and as a last resort probes the known Python Scripts dirs on disk for
# the executable directly -- so a tool installed by this OR a previous run is
# recognised in the SAME run, without forcing the user to re-launch the installer.
function Test-CliResilient {
    param([string]$Name, [int]$Retries = 4)
    for ($i = 0; $i -lt $Retries; $i++) {
        if (Get-Command $Name -ErrorAction SilentlyContinue) { return $true }
        Sync-ToolPaths
        if (Get-Command $Name -ErrorAction SilentlyContinue) { return $true }
        # Direct on-disk probe: pip drops <name>.exe/.cmd/.bat into a Scripts dir.
        foreach ($root in @("$env:APPDATA\Python", "$env:LOCALAPPDATA\Programs\Python")) {
            if (Test-Path $root) {
                $hit = Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue `
                         -Include "$Name.exe", "$Name.cmd", "$Name.bat" | Select-Object -First 1
                if ($hit) {
                    Add-DirToPath $hit.DirectoryName
                    if (Get-Command $Name -ErrorAction SilentlyContinue) { return $true }
                }
            }
        }
        if ($i -lt $Retries - 1) { Start-Sleep -Milliseconds 400 }
    }
    return $false
}

# -- Helper: read VS Code's installed-extension list, resiliently -----------
# `code --list-extensions` can return empty/partial on the first call right
# after an install or on a slow/locked-down machine. Retry until it returns
# something rather than trusting a single (possibly empty) result.
function Get-InstalledVsCodeExtensions {
    param([string]$VsCode, [int]$Retries = 4)
    if (-not $VsCode) { return @() }
    for ($i = 0; $i -lt $Retries; $i++) {
        $list = & $VsCode --list-extensions 2>$null
        if ($list) { return @($list) }
        if ($i -lt $Retries - 1) { Start-Sleep -Milliseconds 400 }
    }
    return @()
}

# -- Helper: is a given VS Code extension present? --------------------------
# Authoritative source is the CLI's --list-extensions output. When that list is
# NON-EMPTY we trust it completely: an id that is absent means the extension is
# genuinely not installed. We deliberately do NOT fall back to a folder scan in
# that case, because an extension uninstalled via the CLI leaves its folder in
# .vscode\extensions (flagged in .obsolete) until VS Code restarts -- scanning
# would then report a removed extension as still installed (a false positive).
# Only when the CLI returns NOTHING (a transient failure on a slow/locked-down
# PC) do we scan on disk, and even then we skip folders marked obsolete.
function Test-VsCodeExtension {
    param([string]$Id, $List)
    if ($List -and @($List).Count -gt 0) {
        return (@($List) -contains $Id)
    }
    $pattern = '^' + [regex]::Escape($Id) + '-\d'
    foreach ($extRoot in @("$env:USERPROFILE\.vscode\extensions", "$env:USERPROFILE\.vscode-insiders\extensions")) {
        if (-not (Test-Path $extRoot)) { continue }
        # Build the set of folders VS Code has marked for removal (.obsolete is a
        # JSON map like { "publisher.id-1.2.3": true }).
        $obsolete = @{}
        $obsoleteFile = Join-Path $extRoot '.obsolete'
        if (Test-Path $obsoleteFile) {
            try {
                (Get-Content $obsoleteFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).PSObject.Properties |
                    ForEach-Object { $obsolete[$_.Name] = $true }
            } catch { }
        }
        $dirs = Get-ChildItem $extRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match $pattern -and -not $obsolete[$_.Name] }
        if ($dirs) { return $true }
    }
    return $false
}

# -- Helper: export the Windows trusted-root store to a PEM bundle ----------
# Locked-down corporate networks run TLS inspection (Zscaler / Netskope / etc.)
# that re-signs HTTPS with an internal root CA. VS Code's CLI downloads
# extensions through Node, which uses its OWN bundled CA list and therefore
# rejects that root with "self signed certificate in certificate chain" -- so
# `code --install-extension` fails even though browsers and pip (which use
# different trust stores) work fine. Exporting the Windows trusted roots (which
# DO include the corporate CA) to a PEM file and pointing Node at it via
# NODE_EXTRA_CA_CERTS lets the download validate. Reading the cert store needs
# no admin. Cached for the run; returns the bundle path or $null.
$script:CaBundlePath = $null
function Get-WindowsCaBundle {
    if ($script:CaBundlePath -and (Test-Path $script:CaBundlePath)) { return $script:CaBundlePath }
    try {
        $certs = Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root -ErrorAction SilentlyContinue
        if (-not $certs) { return $null }
        $sb = New-Object System.Text.StringBuilder
        foreach ($c in $certs) {
            $b64 = [Convert]::ToBase64String($c.RawData, 'InsertLineBreaks')
            [void]$sb.AppendLine('-----BEGIN CERTIFICATE-----')
            [void]$sb.AppendLine($b64)
            [void]$sb.AppendLine('-----END CERTIFICATE-----')
        }
        $path = Join-Path $env:LOCALAPPDATA 'fabric-agentic-ca-bundle.pem'
        Set-Content -Path $path -Value $sb.ToString() -Encoding ascii
        $script:CaBundlePath = $path
        return $path
    } catch { return $null }
}

# -- Helper: force-install a VS Code extension, robustly --------------------
# Replaces a bare `code --install-extension --force` call, fixing the two ways
# it silently fails on a locked-down corporate PC:
#   1. Under $ErrorActionPreference='Stop', the native command's progress text on
#      stderr (merged via 2>&1) is turned into a TERMINATING error -- so even a
#      successful install lands in the catch block and is reported as failed.
#      We run with a function-scoped EAP='Continue' and judge success by the
#      exit code + a --list-extensions check instead.
#   2. A TLS-inspection proxy makes the marketplace download fail the Node cert
#      check; we set NODE_EXTRA_CA_CERTS to the Windows trusted roots up front
#      (harmless off such networks -- it only ADDS already-trusted roots).
# Retries a few times. Returns $true only on a confirmed install.
function Install-VsCodeExtension {
    param([string]$VsCode, [string]$Id, [int]$Retries = 3)
    $ErrorActionPreference = 'Continue'   # function-scoped; native stderr won't throw
    if (-not $VsCode -or -not $Id) { return $false }

    if (-not $env:NODE_EXTRA_CA_CERTS) {
        $bundle = Get-WindowsCaBundle
        if ($bundle) { $env:NODE_EXTRA_CA_CERTS = $bundle }
    }

    for ($i = 0; $i -lt $Retries; $i++) {
        & $VsCode --install-extension $Id --force 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and
            (Test-VsCodeExtension -Id $Id -List (Get-InstalledVsCodeExtensions -VsCode $VsCode))) {
            return $true
        }
        Start-Sleep -Milliseconds 600
    }
    return (Test-VsCodeExtension -Id $Id -List (Get-InstalledVsCodeExtensions -VsCode $VsCode))
}

# -- Helper: ensure a REAL Python is available, installing if missing ----
# The Fabric CLI (fab) is a Python package, so without Python it cannot install.
# This force-installs Python (mirroring the Power Platform twin's pac/.NET
# bootstrap) so the common "fab won't install because Python is missing" case
# resolves itself. Tries, in order:
#   1. An existing real Python (Find-RealPython)
#   2. winget  (Python.Python.3.12, per-user, no admin)
#   3. The official python.org silent installer (pinned), per-user, no admin
# Refreshes PATH after each attempt. Returns a usable launcher string
# ('py'/'python') or $null on total failure -- never throws, never aborts setup.
function Ensure-Python {
    $py = Find-RealPython
    if ($py) { return $py }

    Write-Host "         No real Python found -- attempting to install Python 3.12 (required by the Fabric CLI)..." -ForegroundColor Yellow

    # -- Attempt 1: winget (per-user, no admin) -------------------------
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "         Trying winget: Python.Python.3.12 ..." -ForegroundColor DarkGray
        try {
            & winget install -e --id Python.Python.3.12 --scope user --silent `
                --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        } catch { }
        Update-InstallerPath
        $py = Find-RealPython
        if ($py) { Write-Host "         Python installed (via winget)." -ForegroundColor Green; return $py }
    }

    # -- Attempt 2: official python.org silent installer ----------------
    try {
        $pyVer = '3.12.10'
        $arch  = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'win32' }
        $url   = "https://www.python.org/ftp/python/$pyVer/python-$pyVer-$arch.exe"
        $exe   = Join-Path $env:TEMP "python-$pyVer-$arch.exe"
        Write-Host "         Downloading Python $pyVer from python.org ..." -ForegroundColor DarkGray
        $oldProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
        $ProgressPreference = $oldProgress
        if (Test-Path $exe) {
            Write-Host "         Installing Python silently (per-user, no admin; this can take a minute)..." -ForegroundColor DarkGray
            $proc = Start-Process $exe -ArgumentList '/quiet InstallAllUsers=0 PrependPath=1 Include_pip=1' -Wait -PassThru
            if ($proc.ExitCode -ne 0) { Write-Host "         Python installer exit code: $($proc.ExitCode)." -ForegroundColor DarkGray }
            Remove-Item $exe -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "         Python download/install failed: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
    Update-InstallerPath
    $py = Find-RealPython
    if ($py) { Write-Host "         Python installed (via python.org)." -ForegroundColor Green; return $py }

    return $null
}

# -- Helper: attempt an optional tool install, never fatal --------------
# Prompts the user, then tries each strategy in $Attempts (ordered list of
# @{ Exe = '<exe>'; Args = @(...) }) until $CheckCmd is satisfied. Strategies
# whose Exe is missing are skipped, so a blocked winget or missing pip does not
# stop us trying another route. On total failure it reports the captured cause
# (exit code + output) so the user knows WHY, and always returns control to the
# caller -- a failed optional install never aborts the setup.
function Try-InstallOptionalTool {
    param(
        [string]$Name,        # friendly name, e.g. "Fabric CLI (fab)"
        [string]$CheckCmd,    # command to detect presence, e.g. "fab"
        [array]$Attempts,     # ordered list of @{ Exe=..; Args=@(..) } strategies
        [string]$ManualUrl    # fallback manual install URL
    )
    # Install automatically -- no opt-out prompt. The goal is to set up as much
    # as possible up front; a failed optional install is reported but never fatal.
    Write-Host "    Installing $Name automatically..." -ForegroundColor White

    $anyRan = $false
    foreach ($attempt in $Attempts) {
        $exe = $attempt.Exe
        $eArgs = $attempt.Args
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
        $anyRan = $true
        Write-Host "    Trying: $exe $($eArgs -join ' ') ..." -ForegroundColor White
        $output = ''
        try { $output = & $exe @eArgs 2>&1 | Out-String } catch { $output = $_.Exception.Message }
        $code = $LASTEXITCODE

        # Refresh PATH so a freshly-installed command is visible this session.
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('Path', 'User')
        # pip drops console scripts either in the interpreter's own Scripts dir
        # (sys.prefix\Scripts) or, with --user, in the per-user Scripts dir
        # (%APPDATA%\Python\PythonXY\Scripts). Neither is guaranteed to be on
        # PATH yet -- add both so the CheckCmd test can find the freshly installed tool.
        if ($exe -match '(^|\\)(py|python|python3)(\.exe)?$') {
            try {
                $scriptDirs = & $exe -c "import site, sys, os; print(os.path.join(sys.prefix, 'Scripts')); print(os.path.join(site.getuserbase(), 'Scripts'))" 2>$null
                foreach ($sd in @($scriptDirs)) {
                    if ($sd -and (Test-Path $sd)) { Add-DirToPath $sd }
                }
            } catch { }
        }

        if (Get-Command $CheckCmd -ErrorAction SilentlyContinue) {
            Write-Host "    $Name installed successfully (via $exe)." -ForegroundColor Green
            return $true
        }
        Write-Host "    That method did not succeed (exit code: $code)." -ForegroundColor Yellow
        $reason = ($output -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 3) -join "`n      "
        if ($reason) { Write-Host "      $reason" -ForegroundColor DarkGray }
        Write-Host "    Trying next method if available..." -ForegroundColor DarkGray
    }

    # Last-ditch recovery: the package may have installed but landed in a Scripts
    # dir we didn't compute (e.g. pip reported a different layout). Search the
    # common per-user Python Scripts locations for the tool and add it to PATH.
    foreach ($root in @("$env:APPDATA\Python", "$env:LOCALAPPDATA\Programs\Python")) {
        if (Test-Path $root) {
            $hit = Get-ChildItem $root -Recurse -Filter "$CheckCmd.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) {
                Add-DirToPath $hit.DirectoryName
                if (Get-Command $CheckCmd -ErrorAction SilentlyContinue) {
                    Write-Host "    $Name installed successfully (found in $($hit.DirectoryName))." -ForegroundColor Green
                    return $true
                }
            }
        }
    }

    # Nothing worked -- explain why and how to recover.
    if (-not $anyRan) {
        Write-Host "    Cannot install automatically: no working installer (real Python/pip or winget) is available." -ForegroundColor Yellow
    }
    Write-Host "    Likely causes: corporate security policy blocking installs, no real Python/pip or winget, or no network access." -ForegroundColor DarkGray
    Write-Host "    Install it later when convenient -- either manually ($ManualUrl)," -ForegroundColor DarkGray
    Write-Host "    or just open the workspace and ask the Fabric agent to walk you through it." -ForegroundColor DarkGray
    Write-Host "    Continuing without $Name (the workspace works fine without it)." -ForegroundColor DarkGray
    return $false
}

# -- Helper: install Azure CLI into a dedicated venv at a SHORT path --------
# azure-cli has a very deep package tree (e.g.
#   azure\mgmt\recoveryservicesbackup\activestamp\aio\operations\_..._operations.py)
# that overflows the Windows 260-char MAX_PATH limit when pip unpacks it into the
# Microsoft Store Python's long site-packages path -- the install dies with
# "OSError: [Errno 2] No such file or directory". The fix is a virtual env whose
# base path is short. Crucially the venv must live in the USER-PROFILE ROOT, not
# under %LOCALAPPDATA%: the Store Python virtualizes AppData\Local and silently
# redirects a venv created there back into its long sandbox path, re-triggering
# MAX_PATH. A profile-root folder (%USERPROFILE%\.fabric-az) is not virtualized,
# stays short, and installs cleanly. Idempotent: re-uses an existing venv. Puts
# the venv's Scripts dir on PATH (persisted) so `az` resolves now and later.
# Returns $true if `az` is available afterwards; never throws.
function Install-AzCliViaVenv {
    param([string]$Python)
    $ErrorActionPreference = 'Continue'   # function-scoped; native stderr won't throw
    if (-not $Python) { $Python = Find-RealPython }
    if (-not $Python) { return $false }

    $venv    = Join-Path $env:USERPROFILE '.fabric-az'
    $scripts = Join-Path $venv 'Scripts'
    $venvPy  = Join-Path $scripts 'python.exe'

    # Append the venv Scripts dir to PATH (NOT prepend): the venv carries its own
    # python/pip and an unrelated `fab` (pyinvoke), so prepending would shadow the
    # user's real Python / Fabric CLI. Appending exposes only `az`, which lives
    # nowhere else. Persists to User scope so it survives into VS Code / new shells.
    $addAzToPath = {
        if ($env:Path -notlike "*$scripts*") { $env:Path = "$env:Path;$scripts" }
        try {
            $up = [System.Environment]::GetEnvironmentVariable('Path', 'User')
            if ($up -notlike "*$scripts*") {
                [System.Environment]::SetEnvironmentVariable(
                    'Path', ((@($up, $scripts) | Where-Object { $_ }) -join ';'), 'User')
            }
        } catch { }
    }

    # Already installed by a previous run? Re-use it (fast + idempotent).
    $azExisting = Get-ChildItem $scripts -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^az\.(cmd|bat|exe)$' } | Select-Object -First 1
    if ($azExisting) { & $addAzToPath; return $true }

    Write-Host "    Installing Azure CLI into an isolated environment (sidesteps the Windows" -ForegroundColor White
    Write-Host "    260-char path limit that breaks a normal pip install)... this can take a few minutes." -ForegroundColor White

    if (-not (Test-Path $venvPy)) {
        try { & $Python -m venv $venv 2>&1 | Out-Null } catch { }
    }
    if (-not (Test-Path $venvPy)) {
        Write-Host "    Could not create the isolated environment for Azure CLI." -ForegroundColor Yellow
        return $false
    }

    try { & $venvPy -m pip install --upgrade pip --quiet 2>&1 | Out-Null } catch { }
    try { & $venvPy -m pip install --upgrade --retries 5 --timeout 120 azure-cli 2>&1 | Out-Null } catch { }

    $azWrapper = Get-ChildItem $scripts -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -match '^az\.(cmd|bat|exe)$' } | Select-Object -First 1
    if ($azWrapper) { & $addAzToPath; return $true }
    return $false
}

# -- Helper: merge installer-owned keys into existing JSON settings -----
function Merge-JsonSettings ([string]$Path, [hashtable]$Required) {
    $existing = [ordered]@{}
    if (Test-Path $Path) {
        try {
            $parsed = Get-Content $Path -Raw | ConvertFrom-Json
            foreach ($prop in $parsed.PSObject.Properties) {
                $existing[$prop.Name] = $prop.Value
            }
        } catch {
            # Malformed JSON -- back up and start fresh
            Copy-Item $Path "$Path.bak" -Force
            Write-Host "  Backed up malformed settings.json to settings.json.bak" -ForegroundColor Yellow
        }
    }
    foreach ($key in $Required.Keys) {
        $val = $Required[$key]
        if ($val -is [hashtable] -and $existing.Contains($key) -and $existing[$key] -is [PSCustomObject]) {
            # Deep merge: add missing sub-keys, preserve user additions
            foreach ($sk in $val.Keys) {
                $existing[$key] | Add-Member -NotePropertyName $sk -NotePropertyValue $val[$sk] -Force
            }
        } else {
            $existing[$key] = $val
        }
    }
    $json = $existing | ConvertTo-Json -Depth 10
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

$totalSteps = 8

# =====================================================================
# STEP 1  -- Workspace folder configuration
# =====================================================================
Show-Step 1 $totalSteps "Workspace Folder"

Write-Host "  Welcome to the Fabric Agentic Workspace setup!" -ForegroundColor White
Write-Host ""
Write-Host "  This will configure your local folder with agents and skills" -ForegroundColor White
Write-Host "  for AI-assisted Fabric development in VS Code." -ForegroundColor White
Write-Host ""
Write-Host "  Do you already have a local folder where you work with Fabric?" -ForegroundColor Yellow
Write-Host "  (e.g. where you sync your Semantic Models, Notebooks, Pipelines)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [1] Yes  -- I have an existing folder (I will provide the path)" -ForegroundColor White
Write-Host "  [2] No   -- Create a new folder for me" -ForegroundColor White
Write-Host ""
$choice = Read-Host "  Enter 1 or 2"

if ($choice -eq '1') {
    $rootPath = Read-Host "`n  Enter the full path to your existing Fabric folder"
    $rootPath = $rootPath.Trim('"').Trim("'").TrimEnd('\')
    if (-not (Test-Path $rootPath)) {
        Write-Host "`n  That folder does not exist: $rootPath" -ForegroundColor Red
        $create = Read-Host "  Create it? (y/n)"
        if ($create -ne 'y') { Write-Host "  Aborted."; exit 0 }
        New-Item -ItemType Directory -Path $rootPath -Force | Out-Null
        Write-Host "  Created: $rootPath" -ForegroundColor Green
    } else {
        Write-Host "`n  Using existing folder: $rootPath" -ForegroundColor Green
    }
} else {
    $defaultParent = $env:USERPROFILE
    $defaultName = "Fabric Workspaces"
    Write-Host ""
    Write-Host "  New folder will be created at: $defaultParent\" -ForegroundColor DarkGray
    $folderName = Read-Host "  Enter a name (default: $defaultName)"
    if ([string]::IsNullOrWhiteSpace($folderName)) { $folderName = $defaultName }
    $rootPath = Join-Path $defaultParent $folderName
    if (-not (Test-Path $rootPath)) {
        New-Item -ItemType Directory -Path $rootPath -Force | Out-Null
        Write-Host "  Created: $rootPath" -ForegroundColor Green
    } else {
        Write-Host "  Folder already exists: $rootPath" -ForegroundColor Yellow
    }
}

Write-Host "`n  Workspace target: $rootPath" -ForegroundColor White

# -- Workflow explanation & workspace prompts ---------------------------
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "       HOW THIS WORKSPACE WORKS -- ONE LIFECYCLE, THREE WAYS" -ForegroundColor Cyan
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This local folder is your main working directory for Fabric." -ForegroundColor White
Write-Host "  All work shares ONE safe lifecycle, and you can edit on top of" -ForegroundColor White
Write-Host "  it in THREE ways. Pick whichever fits the task." -ForegroundColor White
Write-Host ""
Write-Host "  THE SHARED LIFECYCLE (common to all three ways):" -ForegroundColor White
Write-Host ""
Write-Host "     Fabric DEV Workspace        <- your changes land here" -ForegroundColor Yellow
Write-Host "            |  commit (Fabric Portal > Git Integration)" -ForegroundColor DarkGray
Write-Host "            v" -ForegroundColor DarkGray
Write-Host "     Azure DevOps (DEV branch)   <- safety net: revert anytime" -ForegroundColor Yellow
Write-Host "            |  Pull Request (DEV -> PROD)" -ForegroundColor DarkGray
Write-Host "            v" -ForegroundColor DarkGray
Write-Host "     Azure DevOps (PROD branch)" -ForegroundColor Yellow
Write-Host "            |  sync" -ForegroundColor DarkGray
Write-Host "            v" -ForegroundColor DarkGray
Write-Host "     Fabric PROD Workspace       <- stable production" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Whatever editing method you use, changes land in the same DEV" -ForegroundColor White
Write-Host "  workspace and are captured by the same DevOps commit -- so a" -ForegroundColor White
Write-Host "  revert always restores it. That is why all three ways are" -ForegroundColor White
Write-Host "  equally safe." -ForegroundColor White
Write-Host ""
Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  THE THREE WAYS OF WORKING" -ForegroundColor Cyan
Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "  A) FULL LOCAL  (file-first -- the default)" -ForegroundColor Green
Write-Host "       Fabric Portal --(extension: pull)--> local files" -ForegroundColor DarkGray
Write-Host "       --> edit with AI agents or by hand --(push)--> Fabric DEV." -ForegroundColor DarkGray
Write-Host "       * Pull items (Semantic Models, Notebooks, Pipelines, ...)" -ForegroundColor DarkGray
Write-Host "         into sub-folders here using the Fabric extension." -ForegroundColor DarkGray
Write-Host "       * Edit locally with Copilot agents & skills (TMDL, DAX," -ForegroundColor DarkGray
Write-Host "         pipeline JSON, notebooks); push back and test in portal." -ForegroundColor DarkGray
Write-Host "       Best for bulk/structured edits, diffs, offline work." -ForegroundColor DarkGray
Write-Host "       Needs only: Fabric extension + Git." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  B) FULL LIVE  (in-workspace -- no local round-trip)" -ForegroundColor Green
Write-Host "       Agents act directly on the live DEV workspace via Fabric" -ForegroundColor DarkGray
Write-Host "       REST (updateDefinition) + the two MCP servers." -ForegroundColor DarkGray
Write-Host "       * Run DAX (EVALUATE) on running models: compare TEST vs PROD." -ForegroundColor DarkGray
Write-Host "       * Read real deployed GUIDs / SQL endpoints; edit in place;" -ForegroundColor DarkGray
Write-Host "         create items." -ForegroundColor DarkGray
Write-Host "       Needs: Fabric MCP + Power BI model MCP servers, plus fab/az." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  C) HYBRID  (local + live)" -ForegroundColor Green
Write-Host "       Mix both in one session -- some items as files, others live." -ForegroundColor DarkGray
Write-Host "       GOLDEN RULE: keep local = live workspace. Each session pull" -ForegroundColor DarkGray
Write-Host "       only what you need, do your mixed work, then re-pull (or" -ForegroundColor DarkGray
Write-Host "       clean up local) before a new job so local = live workspace" -ForegroundColor DarkGray
Write-Host "       and you avoid drift." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Diagrams: assets\workflow-mode-local|live|hybrid.svg  (see README)." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Git versioning: this workspace is initialized with Git, so every" -ForegroundColor White
Write-Host "  local change is tracked with full history and can be reverted." -ForegroundColor White
Write-Host ""
Write-Host "  PRO TIP:" -ForegroundColor Magenta
Write-Host "    Connect your Fabric workspaces to Azure DevOps (or GitHub) for" -ForegroundColor DarkGray
Write-Host "    backup + gated DEV -> TEST -> PROD promotion. Set this up in" -ForegroundColor DarkGray
Write-Host "    Fabric Portal > Workspace Settings > Git Integration." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  PRO TIP:" -ForegroundColor Magenta
Write-Host "    Install the 'Fabric Data Engineer Remote' extension to run" -ForegroundColor DarkGray
Write-Host "    notebook cells against remote Spark from VS Code (agentic" -ForegroundColor DarkGray
Write-Host "    run/inspect loop without leaving the editor)." -ForegroundColor DarkGray
Write-Host "    Install: code --install-extension synapsevscode.vscode-synapse-remote" -ForegroundColor DarkGray
Write-Host ""

# -- Ask how many workspaces to scaffold ---------------------------------
Write-Host "  How many Fabric workspaces will you work with?" -ForegroundColor Yellow
Write-Host "  (The Fabric extension will clone items into separate folders)" -ForegroundColor DarkGray
Write-Host ""
$wsCountInput = Read-Host "  Number of workspaces (default: 1)"
if ([string]::IsNullOrWhiteSpace($wsCountInput)) { $wsCountInput = '1' }
$wsCount = 0
if (-not [int]::TryParse($wsCountInput, [ref]$wsCount) -or $wsCount -lt 0) {
    Write-Host "  Invalid number. Skipping workspace folder creation." -ForegroundColor Yellow
    $wsCount = 0
}

$workspaceNames = @()
if ($wsCount -gt 0) {
    Write-Host ""
    for ($i = 1; $i -le $wsCount; $i++) {
        while ($true) {
            $wsName = Read-Host "  Name for Workspace $i"
            if ([string]::IsNullOrWhiteSpace($wsName)) {
                $wsName = "Workspace $i"
            }
            $wsPath = Join-Path $rootPath $wsName
            if (Test-Path $wsPath) {
                Write-Host "  A folder named '$wsName' already exists in this workspace." -ForegroundColor Red
                Write-Host "  Workspace folders contain your Fabric items and will NOT be overwritten." -ForegroundColor Red
                Write-Host "  Please choose a different name.`n" -ForegroundColor Yellow
            } elseif ($workspaceNames -contains $wsName) {
                Write-Host "  You already used the name '$wsName' for another workspace." -ForegroundColor Red
                Write-Host "  Please choose a different name.`n" -ForegroundColor Yellow
            } else {
                $workspaceNames += $wsName
                break
            }
        }
    }
    Write-Host ""
    Write-Host "  Workspace folders to create:" -ForegroundColor White
    foreach ($name in $workspaceNames) {
        Write-Host "    -> $name (new)" -ForegroundColor Green
    }
}

Read-Host "`n  Press Enter to continue..."

# =====================================================================
# STEP 2  -- Prerequisites check
# ====================================================================="
Show-Step 2 $totalSteps "Checking Prerequisites"

$missing = @()
$warnings = @()

# Recognise anything a PREVIOUS run already installed (refresh PATH from the
# registry + re-add Python Scripts dirs) so we do not re-attempt tools that are
# in fact present. This is the fix for "installs but shows not found" on locked PCs.
Sync-ToolPaths

# Git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $missing += "git (https://git-scm.com)"
} else {
    Write-Host "  git: found" -ForegroundColor Green
}

# VS Code
$vscodeCmd = $null
$userVsCode         = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"
$userVsCodeInsiders = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd"

if (Test-Path $userVsCode) {
    $vscodeCmd = $userVsCode
} elseif (Test-Path $userVsCodeInsiders) {
    $vscodeCmd = $userVsCodeInsiders
} elseif (Get-Command code -ErrorAction SilentlyContinue) {
    $vscodeCmd = 'code'
} elseif (Get-Command code-insiders -ErrorAction SilentlyContinue) {
    $vscodeCmd = 'code-insiders'
} else {
    $missing += "VS Code 1.117.0+ (https://code.visualstudio.com)"
}

$minVsCodeVersion = [version]"1.117.0"
if ($vscodeCmd) {
    try {
        $vscodeVersionStr = (& $vscodeCmd --version 2>$null | Select-Object -First 1).Trim()
        $vscodeVersion = [version]$vscodeVersionStr
        if ($vscodeVersion -lt $minVsCodeVersion) {
            $missing += "VS Code $minVsCodeVersion+ (you have $vscodeVersionStr)"
        } else {
            Write-Host "  VS Code: $vscodeVersionStr" -ForegroundColor Green
        }
    } catch {
        $warnings += "Could not determine VS Code version"
    }
}

# Fabric VS Code Extension check
$installedExts = Get-InstalledVsCodeExtensions -VsCode $vscodeCmd
$fabricExtFound = Test-VsCodeExtension -Id 'fabric.vscode-fabric' -List $installedExts
if ($fabricExtFound) {
    Write-Host "  Fabric Extension: found" -ForegroundColor Green
}
if (-not $fabricExtFound) {
    Write-Host "" 
    Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host "  !!                                                        !!" -ForegroundColor Red
    Write-Host "  !!   FABRIC VS CODE EXTENSION NOT DETECTED                !!" -ForegroundColor Red
    Write-Host "  !!                                                        !!" -ForegroundColor Red
    Write-Host "  !!   The Microsoft Fabric extension for VS Code is        !!" -ForegroundColor Red
    Write-Host "  !!   REQUIRED for the pull/push workflow with Fabric.     !!" -ForegroundColor Red
    Write-Host "  !!                                                        !!" -ForegroundColor Red
    Write-Host "  !!   Install it from the VS Code Extensions Marketplace:  !!" -ForegroundColor Red
    Write-Host "  !!   Search 'Microsoft Fabric' or install via:            !!" -ForegroundColor Red
    Write-Host "  !!   code --install-extension fabric.vscode-fabric        !!" -ForegroundColor Red
    Write-Host "  !!                                                        !!" -ForegroundColor Red
    Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host ""
    $warnings += "Fabric VS Code extension not found -- install it before using the workspace"
}

# TMDL extension (optional -- provides syntax highlighting & validation for .tmdl files)
$tmdlExtFound = Test-VsCodeExtension -Id 'analysis-services.tmdl' -List $installedExts
if ($tmdlExtFound) {
    Write-Host "  TMDL Extension: found" -ForegroundColor Green
} else {
    Write-Host "  TMDL Extension: not found (recommended)" -ForegroundColor Yellow
    Write-Host "         Provides syntax highlighting and validation for .tmdl files." -ForegroundColor DarkGray
    Write-Host "         This workspace works heavily with Semantic Model TMDL definitions." -ForegroundColor DarkGray
    Write-Host "         Install via: code --install-extension analysis-services.tmdl" -ForegroundColor DarkGray
}

# Fabric CLI (fab) -- RECOMMENDED (optional). Primary CLI for Fabric control-plane:
# item lifecycle, jobs, export/import, OneLake file ops, table ops. Not required --
# the core workflow (Fabric extension + agents editing local files) needs no CLI.
if (-not (Test-CliResilient -Name 'fab')) {
    Write-Host "  Fabric CLI (fab): not found (recommended)" -ForegroundColor Yellow
    Write-Host "         Primary CLI for Fabric API, jobs, export/import, OneLake and table ops." -ForegroundColor DarkGray
    Write-Host "         Needs Python 3.10-3.13. Reference: https://github.com/microsoft/fabric-cli" -ForegroundColor DarkGray
    # Ensure a REAL Python exists (install it if missing), then install fab via pip.
    $realPy = Ensure-Python
    if ($realPy) {
        # Two shots, each resilient to transient network failures (--retries/--timeout):
        #   1. plain install -> lands in the interpreter's own Scripts dir, which is
        #      already on PATH for a winget/python.org per-user Python (the common case)
        #   2. --user fallback -> for system Pythons where the prefix isn't writable
        # Listing both also gives a free retry if the first attempt dies mid-download.
        Try-InstallOptionalTool -Name "Fabric CLI (fab)" -CheckCmd "fab" -Attempts @(
            @{ Exe = $realPy; Args = @("-m", "pip", "install", "--upgrade", "--retries", "5", "--timeout", "60", "ms-fabric-cli") }
            @{ Exe = $realPy; Args = @("-m", "pip", "install", "--user", "--upgrade", "--retries", "5", "--timeout", "60", "ms-fabric-cli") }
        ) -ManualUrl "https://github.com/microsoft/fabric-cli (pip install ms-fabric-cli)" | Out-Null
    } else {
        Write-Host "         Could not install Python automatically (corporate policy, no winget, or no network)." -ForegroundColor DarkGray
        Write-Host "         No problem -- the workspace works fine without it. Open the workspace and ask the" -ForegroundColor DarkGray
        Write-Host "         Fabric agent to walk you through installing Python + the Fabric CLI when convenient." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  Fabric CLI (fab): found" -ForegroundColor Green
}

# az CLI -- OPTIONAL (fallback). Only needed for SQL/TDS (sqlcmd -G) and non-Fabric
# token audiences (Storage, database.windows.net). fab covers the rest.
if (-not (Test-CliResilient -Name 'az')) {
    Write-Host "  az CLI: not found (optional, fallback)" -ForegroundColor Yellow
    Write-Host "         Only needed for SQL/TDS (sqlcmd) and non-Fabric token audiences; fab covers the rest." -ForegroundColor DarkGray
    Write-Host "    Installing az CLI automatically..." -ForegroundColor White

    # 1) winget (per-machine MSI). Silent, no admin where allowed; commonly
    #    blocked with exit 1603 on locked-down PCs, in which case we fall through.
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "    Trying winget: Microsoft.AzureCLI ..." -ForegroundColor White
        try { & winget install --silent --accept-package-agreements --accept-source-agreements -e --id Microsoft.AzureCLI 2>$null | Out-Null } catch { }
        Sync-ToolPaths
    }

    # 2) Isolated-venv pip install -- the reliable no-admin route. A plain
    #    `pip install azure-cli` overflows the Windows 260-char MAX_PATH limit on
    #    the Microsoft Store Python (azure-cli has a very deep package tree); a
    #    venv at a short profile-root path sidesteps it (see Install-AzCliViaVenv).
    if (Test-CliResilient -Name 'az' -Retries 1) {
        Write-Host "  az CLI: installed (via winget)." -ForegroundColor Green
    } elseif (Install-AzCliViaVenv) {
        Write-Host "  az CLI: installed (isolated environment)." -ForegroundColor Green
    } else {
        Write-Host "  az CLI: could not be installed automatically (optional -- the workspace works without it)." -ForegroundColor Yellow
        Write-Host "         Install it later if you need SQL/TDS or non-Fabric tokens: https://aka.ms/installazurecli" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  az CLI: found" -ForegroundColor Green
}

# -- MCP server extensions for full-live / hybrid modes (auto-installed) ------
# These two VS Code extensions provide the MCP servers the agents use for the
# full-live and hybrid ways of working. They are optional for full-LOCAL mode.
Write-Host ""
Write-Host "  Checking MCP server extensions (for full-live / hybrid modes)..." -ForegroundColor Cyan
$mcpExtensions = @(
    @{ Id = 'fabric.vscode-fabric-mcp-server';        Name = 'Fabric MCP server';                  Desc = 'items, OneLake, tables, definitions' },
    @{ Id = 'analysis-services.powerbi-modeling-mcp';  Name = 'Power BI semantic-model MCP server';  Desc = 'live XMLA DAX + model edits' }
)
if (-not $vscodeCmd) {
    Write-Host "  MCP: skipped (VS Code CLI not found)." -ForegroundColor Yellow
    $warnings += "MCP server extensions not checked (VS Code CLI not found) -- needed for full-live/hybrid modes"
} else {
    $installedExts = Get-InstalledVsCodeExtensions -VsCode $vscodeCmd
    foreach ($mcp in $mcpExtensions) {
        $mcpFound = Test-VsCodeExtension -Id $mcp.Id -List $installedExts
        if ($mcpFound) {
            Write-Host "  $($mcp.Name): found" -ForegroundColor Green
        } else {
            Write-Host "  $($mcp.Name): not found -- installing ($($mcp.Desc))..." -ForegroundColor Yellow
            if (Install-VsCodeExtension -VsCode $vscodeCmd -Id $mcp.Id) {
                Write-Host "  $($mcp.Name): installed" -ForegroundColor Green
                $installedExts = Get-InstalledVsCodeExtensions -VsCode $vscodeCmd
            } else {
                Write-Host "  $($mcp.Name): auto-install failed -- install manually:" -ForegroundColor Yellow
                Write-Host "         code --install-extension $($mcp.Id)" -ForegroundColor DarkGray
                Write-Host "         (On a corporate network this is usually a TLS/proxy certificate" -ForegroundColor DarkGray
                Write-Host "          issue -- installing from the VS Code Extensions view works.)" -ForegroundColor DarkGray
                $warnings += "$($mcp.Name) ($($mcp.Id)) auto-install failed -- run: code --install-extension $($mcp.Id)"
            }
        }
    }
    Write-Host "  (MCP servers power full-live / hybrid modes; full-local mode does not need them.)" -ForegroundColor DarkGray
}

if ($missing.Count -gt 0) {
    Write-Host "`n  Missing prerequisites:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host "`n  Install the above and re-run this script."
    exit 1
}
if ($warnings.Count -gt 0) {
    Write-Host ""
    $warnings | ForEach-Object { Write-Host "  WARNING: $_" -ForegroundColor Yellow }
}

Write-Host "`n  All prerequisites OK." -ForegroundColor Green
Read-Host "`n  Press Enter to continue..."

# =====================================================================
# STEP 3  -- Create folder structure
# =====================================================================
Show-Step 3 $totalSteps "Creating Folder Structure"

$dirs = @(
    "$rootPath\.github\agents"
    "$rootPath\.github\agent-docs"
    "$rootPath\.github\skills\fabric-tmdl"
    "$rootPath\.github\skills\fabric-pipelines"
    "$rootPath\.github\skills\fabric-cli-policy"
    "$rootPath\.vscode"
)
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Host "  Created: $($d.Replace($rootPath, '.'))"
    }
}

# Create workspace placeholder folders
if ($workspaceNames.Count -gt 0) {
    Write-Host ""
    foreach ($name in $workspaceNames) {
        $wsPath = Join-Path $rootPath $name
        if (-not (Test-Path $wsPath)) {
            New-Item -ItemType Directory -Path $wsPath -Force | Out-Null
            Write-Host "  Created workspace: $name" -ForegroundColor Green
        } else {
            Write-Host "  Workspace exists:  $name" -ForegroundColor Yellow
        }
    }
}

Write-Host "`n  Folder structure ready." -ForegroundColor Green

# =====================================================================
# STEP 4  -- Clone skill repositories
# =====================================================================
Show-Step 4 $totalSteps "Cloning Skill Repositories"

# NOTE: We deliberately do NOT clone microsoft/fabric-cli (https://github.com/microsoft/fabric-cli).
# The data-goblin plugin (power-bi-agentic-development/plugins/fabric-cli/) already provides
# rich `fab` references and scripts, and the `fab` tool itself is installed via pip
# (ms-fabric-cli) in Step 2. Cloning the CLI source repo would add no agent-usable skills.

Push-Location $rootPath
try {
    # -- microsoft/skills-for-fabric ----------------------------------
    if (-not (Test-Path "$rootPath\skills-for-fabric")) {
        Write-Host "  Cloning microsoft/skills-for-fabric..." -ForegroundColor White
        try {
            & git clone https://github.com/microsoft/skills-for-fabric.git skills-for-fabric 2>&1 | Out-Null
        } catch { }
        if (Test-Path "$rootPath\skills-for-fabric\skills") {
            Write-Host "  skills-for-fabric cloned." -ForegroundColor Green
        } else {
            Write-Host "  Warning: could not clone skills-for-fabric. Clone manually later." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  skills-for-fabric/ already exists  -- pulling latest..." -ForegroundColor Green
        try { & git -C "$rootPath\skills-for-fabric" pull --ff-only 2>&1 | Out-Null } catch { }
    }
    # Touch files so LastWriteTime reflects sync time, not upstream commit time
    if (Test-Path "$rootPath\skills-for-fabric\skills") {
        Get-ChildItem "$rootPath\skills-for-fabric\skills" -Recurse -File | ForEach-Object { $_.LastWriteTime = Get-Date }
    }

    # -- data-goblin/power-bi-agentic-development ---------------------
    if (-not (Test-Path "$rootPath\power-bi-agentic-development")) {
        Write-Host "  Cloning data-goblin/power-bi-agentic-development..." -ForegroundColor White
        try {
            & git clone https://github.com/data-goblin/power-bi-agentic-development.git power-bi-agentic-development 2>&1 | Out-Null
        } catch { }
        if (Test-Path "$rootPath\power-bi-agentic-development\plugins") {
            Write-Host "  power-bi-agentic-development cloned." -ForegroundColor Green
        } else {
            Write-Host "  Warning: could not clone power-bi-agentic-development. Clone manually later." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  power-bi-agentic-development/ already exists  -- pulling latest..." -ForegroundColor Green
        try { & git -C "$rootPath\power-bi-agentic-development" pull --ff-only 2>&1 | Out-Null } catch { }
    }
    # Touch files so LastWriteTime reflects sync time, not upstream commit time
    if (Test-Path "$rootPath\power-bi-agentic-development\plugins") {
        Get-ChildItem "$rootPath\power-bi-agentic-development\plugins" -Recurse -File | ForEach-Object { $_.LastWriteTime = Get-Date }
    }
} finally {
    Pop-Location
}

Read-Host "`n  Press Enter to continue..."

# =====================================================================
# STEP 5  -- Embed custom skills
# =====================================================================
Show-Step 5 $totalSteps "Writing Custom Skills"

# ----- fabric-tmdl/SKILL.md ------------------------------------------
$tmdlSkillPath = "$rootPath\.github\skills\fabric-tmdl\SKILL.md"
Write-Host "  Writing fabric-tmdl skill..."
$tmdlContent = @'
---
name: fabric-tmdl
description: "Use when: editing or creating TMDL files, DAX measures, columns, relationships, partitions, or parameters in Microsoft Fabric Semantic Models, Power BI datasets, or Direct Lake models. Covers TMDL syntax, indentation, lineageTag rules, and Tabular Object Model (TOM) structure."
---

# Fabric TMDL Skill

## Provenance and maintenance

- **Authored from**: real production Power BI / Fabric semantic models (the author's
  own reports). This is a HOUSE-STYLE skill - conventions, property ordering, and
  layout - not a TMDL/DAX language reference.
- **Independent of data-goblin**: this content was written from first-hand production
  work, NOT copied or AI-rewritten from `power-bi-agentic-development` (GPL-3.0).
  For TMDL/DAX language depth and validation, the semantic-model agent reads the
  cloned data-goblin skills separately; this skill layers house style on top.
- **Updating**: edit the PS1 installer (source of truth) and re-run it, or edit this
  file directly. The Skills Maintainer does NOT auto-modify it (it is house style,
  not an external API surface).
- **Freshness**: the date shown in the startup table is this file's real on-disk
  modification time (when this workspace last installed/updated it).

---

## When to use
- User asks to add, edit, or review measures, tables, columns, relationships, or partitions in `.tmdl` files
- User asks about TMDL syntax or Fabric Semantic Model structure
- User mentions DAX measures, calculated tables, parameters, or Direct Lake partitions

---

## Folder structure

Every Semantic Model in Git integration follows this exact layout:

```
<Name>.SemanticModel/
    definition/
        database.tmdl          <- compatibilityLevel only (always 1604)
        model.tmdl             <- culture, collation, annotations, ref table list
        expressions.tmdl       <- M/Power Query data source expressions
        relationships.tmdl     <- ALL relationships (never inside table files)
        tables/
            <TableName>.tmdl   <- one file per table
        cultures/
            en-US.tmdl         <- linguistic metadata
    definition.pbism           <- connection metadata (don't edit)
```

### database.tmdl
```tmdl
database
	compatibilityLevel: 1604
```
Always `1604`. Nothing else in this file.

### model.tmdl
```tmdl
model Model
	culture: en-US
	collation: Latin1_General_100_BIN2_UTF8
	defaultPowerBIDataSourceVersion: powerBI_V3
	sourceQueryCulture: en-US
	dataAccessOptions
		legacyRedirects
		returnErrorValuesAsNull

annotation __PBI_TimeIntelligenceEnabled = 0

annotation PBI_QueryOrder = ["DatabaseQuery"]

annotation PBI_ProTooling = ["WebModelingEdit","DaxQueryView_Desktop","TMDLView_Desktop","RemoteModeling","TMDL-Extension"]

ref table 'Table Name Here'

ref cultureInfo en-US
```
- Every table in the model MUST have a `ref table` entry here
- **WARNING**: When adding a new table, you MUST also add a `ref table 'New Table Name'` line to `model.tmdl`

### expressions.tmdl (Fabric Warehouse/Lakehouse connection)
```tmdl
expression DatabaseQuery =
		let
		    database = Sql.Database("<endpoint>", "<database-id>")
		in
		    database
	lineageTag: <guid>

	annotation PBI_IncludeFutureArtifacts = False
```

### cultures/en-US.tmdl
```tmdl
cultureInfo en-US

	linguisticMetadata =
			{
			  "Version": "1.0.0",
			  "Language": "en-US"
			}
		contentType: json
```

---

## Indentation rules -- CRITICAL

- **Always use TABS, never spaces** for indentation
- TMDL is indentation-based (like Python) -- no semicolons, no braces
- Nesting level defines hierarchy:
  - Level 0: `table`, `relationship`, `expression`, `model`, `database`, `cultureInfo`
  - Level 1 (1 tab): properties of the above (`column`, `measure`, `partition`, `lineageTag`, etc.)
  - Level 2 (2 tabs): properties of columns/measures/partitions
  - Level 3 (3 tabs): nested content inside partitions, DAX inside triple-backticks

---

## Measures

### Multi-line DAX (most common pattern)
Multi-line DAX is enclosed in **triple backticks** after `=`:

```tmdl
	measure 'My Measure Name' = ```
			VAR x = SUM('FactTable'[Amount])

			RETURN
			IF(x > 0, x, BLANK())
			
			```
		formatString: \$#,0;(\$#,0);\$#,0
		displayFolder: Category Name
		lineageTag: <guid>

		changedProperty = DisplayFolder

		changedProperty = FormatString

		annotation PBI_FormatHint = {"currencyCulture":"en-US"}
```

**Rules for triple-backtick DAX:**
- Opening ` ``` ` goes on the SAME line as `=`, with a space before it
- DAX body is indented with **3 tabs**
- Closing ` ``` ` is on its own line at 3 tabs
- After closing backticks, properties are at **2 tabs**

### Simple one-line DAX
```tmdl
	measure Space = ""
		displayFolder: 1. Formatting
		lineageTag: <guid>

		changedProperty = Name

		changedProperty = DisplayFolder
```

### Hidden measures
```tmdl
	measure 'Internal Measure' = ```
			COUNTROWS('SomeTable')
			
			```
		isHidden
		displayFolder: Hidden
		lineageTag: <guid>

		changedProperty = IsHidden
```

### Measure property order
1. `formatString` (if applicable)
2. `isHidden` (if applicable)
3. `displayFolder` (if applicable)
4. `lineageTag`
5. `changedProperty` entries (blank line before first)
6. `annotation` entries

### Common formatString patterns
- Currency: `\$#,0;(\$#,0);\$#,0`
- Integer: `0`
- Date: `General Date`
- Percentage: `0.00%`
- Custom date: `yyyy-mm-dd`

---

## Columns

### Source column (Direct Lake)
```tmdl
	column 'Customer Name'
		dataType: string
		sourceProviderType: varchar(8000)
		lineageTag: <guid>
		sourceLineageTag: Customer Name
		summarizeBy: none
		sourceColumn: Customer Name

		annotation SummarizationSetBy = Automatic
```

### Calculated column
```tmdl
	column Slicer =
			
			IF(
			    [Parameter Order] IN {0, 1}, "CID", "ICA"
			)
		lineageTag: <guid>
		summarizeBy: none

		annotation SummarizationSetBy = Automatic
```

### Column property order
1. `dataType`
2. `formatString` (if applicable)
3. `isHidden` (if applicable)
4. `sourceProviderType` (source columns)
5. `lineageTag`
6. `sourceLineageTag` (source columns)
7. `summarizeBy`
8. `sourceColumn` (source columns)
9. `sortByColumn` (if applicable)
10. `changedProperty` entries
11. `annotation` entries

---

## Partitions

### Direct Lake partition (most common)
```tmdl
	partition 'TableName' = entity
		mode: directLake
		source
			entityName: TableName
			schemaName: dbo
			expressionSource: DatabaseQuery
```

### Calculated table partition
```tmdl
	partition 'ParameterTable' = calculated
		mode: import
		source =
				
				{
				    ("Label", NAMEOF('DimTable'[Column]), 0),
				    ("Label2", NAMEOF('DimTable'[Column2]), 1)
				}
```

---

## Direct Lake: re-pointing a table to a different source -- `sourceLineageTag` MUST follow `entityName`

A Direct Lake model table has **two independent identities**:

1. **Model/display name** -- e.g. `'Table One'`. What DAX, relationships, and report
   visuals reference. Pure label; safe to rename without touching the source.
2. **Source binding** -- the partition's `source.entityName`, e.g. `TABLE_ONE`. The
   physical Lakehouse/Warehouse object the table actually reads.

There is also a **lineage anchor** at table level: `sourceLineageTag: [dbo].[Table One]`.
This is what the web **"Edit tables" / "Manage tables"** dialog uses to reconcile
"is this physical object already in my model?" -- it matches by lineage, **NOT** by the
model name and **NOT** by `entityName`.

### The trap

You have `Table One` in the Lakehouse and `'Table One'` in the model. You then re-point
the model table to a NEW physical object `TABLE_ONE` (rename in LH, or swap to a new
table/view) by editing only the partition:

```tmdl
	partition 'Table One' = entity
		mode: directLake
		source
			entityName: TABLE_ONE        <- changed
			schemaName: dbo
			expressionSource: DatabaseQuery
```

...but you leave the table header stale:

```tmdl
table 'Table One'
	sourceLineageTag: [dbo].[Table One]   <- STILL the OLD physical name -> MISMATCH
```

Now `entityName` (`TABLE_ONE`) and `sourceLineageTag` (`[dbo].[Table One]`) disagree.
The model still queries fine, **but the Edit tables dialog breaks**: it reconciles your
table to the old `[dbo].[Table One]` anchor and lists the real `TABLE_ONE` as a
separate, **unchecked "not added"** entry -- a phantom duplicate. If you then
**uncheck your real table** there you **DELETE it** (its curated/renamed columns AND
every relationship that points at it); **checking the phantom `TABLE_ONE`** adds a bare
table with raw source column names -> every measure/relationship referencing
`'Table One'` (or its friendly column names) **breaks**.

### The fix -- change BOTH, not just the connection source

When you rebind a Direct Lake table to a different physical object, update **all** of:

1. Partition `source.entityName` (and `schemaName`) -> the new physical object.
2. Table-level `sourceLineageTag` -> `[<schema>].[<NEW_PHYSICAL_NAME>]`.
3. Any renamed columns' `sourceColumn` + `sourceLineageTag` -> the new physical
   column names (the friendly `column 'Name'` stays as-is; only the source pointers move).

```tmdl
table 'Table One'
	sourceLineageTag: [dbo].[TABLE_ONE]   <- aligned to entityName
	...
	partition 'Table One' = entity
		mode: directLake
		source
			entityName: TABLE_ONE
			schemaName: dbo
			expressionSource: DatabaseQuery
```

After alignment the dialog recognises `TABLE_ONE` as already-checked and the phantom
duplicate disappears -- while the model keeps the friendly name `'Table One'`.

> **WARNING -- alignment can trigger a silent rename.** Once `sourceLineageTag`
> matches the physical name, the Edit tables dialog reconciles by that anchor and, on
> the next **apply/confirm**, will **rename the model table's display name to the raw
> physical name** (`'Table One'` -> `TABLE_ONE`). The curated columns survive, but every
> measure/relationship that references the **friendly** name now reports
> **`Missing_References`** (e.g. *"(Table One) SomeColumn ... Missing_References"*).
> This is a *rename*, not a delete -- diagnose it with
> `EVALUATE INFO.TABLES()` (look for raw names where friendly ones should be).
> **Fix:** rename the table back to the friendly name in TMDL or via XMLA
> (`table_operations Rename`, `currentName: TABLE_ONE` -> `newName: Table One`);
> `entityName` and `sourceLineageTag` stay on the physical object. After the rename all
> references resolve again. Then **stop using the Edit tables dialog** on these tables.

### Rules of thumb

- **Manage renamed/rebound Direct Lake tables via TMDL, not the Edit tables dialog.**
  That dialog is a blunt add/remove tool; with a friendly-named table whose source was
  swapped it will always offer the raw physical object as "new".
- If you must add a genuinely new LH table, add it via the dialog FIRST, then rename it
  in TMDL afterwards -- never uncheck an existing renamed one.
- `sourceLineageTag` is metadata only (lineage/refresh mapping); editing it does NOT
  change data or DAX, so re-aligning it is a safe, reversible fix.
- A leftover SQL view literally named `[dbo].[Table One]` can still appear unchecked in
  the dialog after alignment -- harmless; just don't tick it.

---

## Relationships (relationships.tmdl)

### Standard (many-to-one)
```tmdl
relationship eb7f42c7-7937-3a70-c2ae-81e7803461d0
	fromColumn: 'FactTable'.KeyColumn
	toColumn: 'DimTable'.KeyColumn
```

### Inactive
```tmdl
relationship e0828589-8818-68a1-c67a-b12fcd64d3ab
	isActive: false
	fromColumn: 'FactTable'.DateColumn
	toColumn: 'DateTable'.Date
```

### Relationship property order
1. `isActive: false` (only if inactive)
2. `toCardinality: many` (only if many-to-many)
3. `crossFilteringBehavior: bothDirections` (only if bidirectional)
4. `fromColumn`
5. `toColumn`

---

## lineageTag rules

- Format: lowercase GUID with dashes
- **Editing existing objects**: NEVER change or remove an existing lineageTag
- **Creating new objects**: **omit the lineageTag entirely** -- Fabric auto-generates it
- Never reuse a lineageTag from another element

---

## changedProperty rules

- Track UI modifications -- each on its own line at 2 tabs
- **Editing existing**: preserve all existing entries
- **Creating new**: do NOT add changedProperty entries

---

## Naming conventions

### Table naming
- `0.x -` prefix: System/dimension/lookup tables
- `1.x -` prefix: First domain area
- `2.x -` / `3.x -` / `4.x -`: Additional domain areas
- Measures-only: `X - Measures - Description`
- Facts: `X.X - Facts_Name`
- Dimensions: `X.X - Dim_Name`

---

## House modelling decisions

These are the author's standing modelling choices - apply them unless the user
asks otherwise. They are DECISIONS, not syntax (for syntax/DAX depth, the agent
also reads the cloned data-goblin skills).

- **Storage mode**: prefer Direct Lake for fact tables sourced from the Lakehouse/
  Warehouse; use Import only for small calculated/parameter tables that cannot be
  Direct Lake (e.g. field-parameter and disconnected slicer tables).
- **Measure home**: keep measures in dedicated measure-only tables (`X - Measures -`),
  not on fact tables, so the field list stays clean.
- **Folder taxonomy**: organise tables with the numeric-prefix convention (`0.x -`
  system/dimension, `1.x -`..`4.x -` domain areas); group measures with `displayFolder`.
- **Naming**: dimensions `X.X - Dim_Name`, facts `X.X - Facts_Name`; single-quote any
  name containing spaces.
- **Formatting**: set an explicit `formatString` on every numeric measure; never rely
  on the implicit default.
- **Hygiene**: hide key/technical columns (`isHidden`) and surface only business-
  friendly fields; set `summarizeBy: none` on non-additive columns.

For HOW to design star schemas, RLS, calc groups, incremental refresh, time
intelligence, or to tune DAX, defer to the cloned data-goblin skills + Microsoft
docs - this skill intentionally does not duplicate that depth.

---

## Common mistakes to AVOID

1. Never use semicolons -- TMDL is indentation-based
2. Never use spaces for indentation -- always tabs
3. Never put relationships inside table files
4. Never put multiple tables in one file
5. Never forget `ref table` in model.tmdl
6. Never wrap DAX in string quotes
7. Never omit the partition block
8. Single-quote names with spaces: `'My Table'`
9. Never change a Direct Lake table's partition `entityName` without also updating its table-level `sourceLineageTag` (see "Direct Lake: re-pointing a table to a different source")

---

## What NOT to edit

| File | Reason |
|------|--------|
| `definition.pbism` | Connection metadata -- editing breaks deployment |
| `.platform` | Fabric platform metadata -- auto-managed |
| `database.tmdl` | Always just `compatibilityLevel: 1604` |
| `cultures/en-US.tmdl` | Linguistic metadata -- rarely needs changes |

---

## Annotations guidance

- **Editing existing**: preserve all existing annotations
- **Creating new**: only add structurally required annotations:
  - `annotation SummarizationSetBy = Automatic` -- on every column
  - `annotation PBI_FormatHint = {"currencyCulture":"en-US"}` -- with currency formatString
  - `annotation PBI_FormatHint = {"isCustom":true}` -- with custom formatStrings
  - `annotation UnderlyingDateTimeDataType = Date` -- on date columns
  - `annotation PBI_ResultType = Table` -- at table level for source tables
  - `annotation PBI_Id = <hex>` -- on Field Parameter tables

---

## Post-edit validation checklist

- [ ] **Tabs only** -- no spaces in indentation
- [ ] **lineageTags unchanged** -- existing tags not modified
- [ ] **New table?** -> `ref table` added to `model.tmdl`
- [ ] **New relationship?** -> in `relationships.tmdl` only
- [ ] **Rebound a Direct Lake source?** -> table `sourceLineageTag` aligned to the new `entityName` (`[schema].[PHYSICAL_NAME]`)
- [ ] **Annotations preserved**
- [ ] **changedProperty preserved**
- [ ] **File not in do-not-edit list**
'@
Write-ManagedFile $tmdlSkillPath $tmdlContent
# The on-disk LastWriteTime is left untouched on purpose: it honestly reflects
# when this workspace installed/updated the skill. The freshness display reads
# this real mtime for custom skills (and git commit dates for cloned repos).
Write-Host "  Written: .github/skills/fabric-tmdl/SKILL.md" -ForegroundColor Green

# ----- fabric-pipelines/SKILL.md -------------------------------------
$pipelineSkillPath = "$rootPath\.github\skills\fabric-pipelines\SKILL.md"
Write-Host "  Writing fabric-pipelines skill..."
$pipelineContent = @'
---
name: fabric-pipelines
description: "Use when: editing or creating Data Factory pipeline JSON files (pipeline-content.json) in Fabric PBIP projects. Covers pipeline activity types, typeProperties, dependency chaining, ForEach/IfCondition nesting, variables, and Variable Library integration."
---

# Fabric Data Pipeline Authoring Skill

## Origin and maintenance

- **Created from**: microsoft/skills-for-fabric `ITEM-DEFINITIONS-CORE.md` (DataPipeline section)
  and Microsoft Learn docs for Data Factory in Fabric (both Microsoft, MIT-licensed)
- **Independent of data-goblin**: this skill is derived from Microsoft sources and
  Fabric docs only - NOT from `power-bi-agentic-development` (GPL-3.0). That repo is
  used solely as a locally cloned reference and is never copied into this skill.
- **Pipeline JSON schemas** are NOT published at `microsoft/json-schemas` (as of April 2026)
- **Last reviewed against Microsoft docs**: 2026-06-15 (against
  https://learn.microsoft.com/en-us/fabric/data-factory/activity-overview, updated 2026-06-07).
  Added `RefreshMaterializedLakeView` and `Approval` activities at that review.
- **In-house operational addendum**: 2026-06-17 - added "Operational practices
  (battle-tested)" section (RefreshSQLEndpoint placement, Direct Lake freshness,
  Variable Library endpoint/item-id discipline, Wait-buffer smell, pipeline auditing).
  Generalized from production work with all environment-specific identifiers removed;
  no proprietary data - redistributable.
- **To update this skill**: check `skills-for-fabric/common/ITEM-DEFINITIONS-CORE.md` for new
  activity types, and review https://learn.microsoft.com/en-us/fabric/data-factory/
  for updated typeProperties. Then re-run the installer or edit this file directly.
- **Note**: when `skills-for-fabric` or `power-bi-agentic-development` eventually publish
  a pipeline skill, the Fabric Master Agent starting flow will pull it in automatically.

---

## When to use
- User asks to create, edit, or review Data Factory pipeline definitions
- User mentions pipeline activities, orchestration, ForEach, IfCondition, Copy activity
- User asks about `pipeline-content.json` structure
- User wants to trigger notebook runs, semantic model refreshes, or copy data via pipelines

---

## File structure

In a Fabric PBIP project, a Data Pipeline is defined by:

```
<PipelineName>.DataPipeline/
    pipeline-content.json      <- all activities and pipeline config
    .platform                  <- Fabric metadata (don't edit)
```

## pipeline-content.json structure

```json
{
  "properties": {
    "description": "Pipeline description",
    "activities": [
      {
        "name": "ActivityName",
        "type": "ActivityType",
        "dependsOn": [],
        "policy": {
          "timeout": "0.12:00:00",
          "retry": 0,
          "retryIntervalInSeconds": 30
        },
        "typeProperties": { }
      }
    ],
    "variables": {
      "MyVar": { "type": "String", "defaultValue": "" }
    },
    "annotations": []
  }
}
```

### Top-level properties
- `properties.description` -- pipeline description string
- `properties.activities` -- array of activity objects (the core of the pipeline)
- `properties.variables` -- pipeline-scoped variables (String, Boolean, Array)
- `properties.annotations` -- metadata tags (array of strings)

---

## Activity common properties

Every activity has these properties:

| Property | Type | Description |
|----------|------|-------------|
| `name` | string | Unique name within the pipeline |
| `type` | string | Activity type (see list below) |
| `dependsOn` | array | Dependencies on other activities |
| `policy` | object | Timeout, retry, retryInterval |
| `typeProperties` | object | Activity-type-specific configuration |

### dependsOn structure
```json
"dependsOn": [
  {
    "activity": "PreviousActivityName",
    "dependencyConditions": ["Succeeded"]
  }
]
```
Valid conditions: `Succeeded`, `Failed`, `Skipped`, `Completed`

### policy structure
```json
"policy": {
  "timeout": "0.12:00:00",
  "retry": 0,
  "retryIntervalInSeconds": 30
}
```

---

## Activity types and typeProperties

### TridentNotebook (run a Fabric notebook)
```json
{
  "name": "Run ETL Notebook",
  "type": "TridentNotebook",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "notebookId": "<notebook-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```
- `notebookId` and `workspaceId` are GUIDs referencing Fabric items
- Can include `parameters` object for notebook parameters

### Copy (copy data between sources)
```json
{
  "name": "Copy Sales Data",
  "type": "Copy",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "source": {
      "type": "LakehouseTableSource"
    },
    "sink": {
      "type": "LakehouseTableSink",
      "tableActionOption": "Overwrite"
    },
    "enableStaging": false
  }
}
```

### ForEach (iterate over a collection)
```json
{
  "name": "Process Each Table",
  "type": "ForEach",
  "dependsOn": [],
  "typeProperties": {
    "isSequential": false,
    "batchCount": 20,
    "items": {
      "value": "@pipeline().parameters.TableList",
      "type": "Expression"
    },
    "activities": [
      {
        "name": "Inner Activity",
        "type": "TridentNotebook",
        "typeProperties": {
          "notebookId": "<guid>",
          "workspaceId": "<guid>"
        }
      }
    ]
  }
}
```
- `items` is an expression that evaluates to an array
- `activities` is a nested array of activities (same structure as top-level)
- `isSequential: false` enables parallel execution (up to `batchCount`)

### IfCondition (branching logic)
```json
{
  "name": "Check Row Count",
  "type": "IfCondition",
  "dependsOn": [
    { "activity": "Get Metadata", "dependencyConditions": ["Succeeded"] }
  ],
  "typeProperties": {
    "expression": {
      "value": "@greater(activity('Get Metadata').output.count, 0)",
      "type": "Expression"
    },
    "ifTrueActivities": [ ],
    "ifFalseActivities": [ ]
  }
}
```

### Switch (multi-branch)
```json
{
  "name": "Route by Type",
  "type": "Switch",
  "typeProperties": {
    "on": {
      "value": "@pipeline().parameters.ProcessType",
      "type": "Expression"
    },
    "cases": [
      {
        "value": "Full",
        "activities": [ ]
      },
      {
        "value": "Incremental",
        "activities": [ ]
      }
    ],
    "defaultActivities": [ ]
  }
}
```

### SetVariable
```json
{
  "name": "Set Status",
  "type": "SetVariable",
  "typeProperties": {
    "variableName": "ProcessStatus",
    "value": {
      "value": "@string('Complete')",
      "type": "Expression"
    }
  }
}
```

### ExecutePipeline (call another pipeline)
```json
{
  "name": "Run Child Pipeline",
  "type": "ExecutePipeline",
  "typeProperties": {
    "pipeline": {
      "referenceName": "<pipeline-guid>",
      "type": "PipelineReference"
    },
    "waitOnCompletion": true,
    "parameters": { }
  }
}
```

### PBISemanticModelRefresh (refresh a semantic model)
```json
{
  "name": "Refresh Sales Model",
  "type": "PBISemanticModelRefresh",
  "dependsOn": [
    { "activity": "Run ETL", "dependencyConditions": ["Succeeded"] }
  ],
  "policy": { "timeout": "0.12:00:00", "retry": 1, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "datasetId": "<semantic-model-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```

### Lookup (retrieve data for use in expressions)
```json
{
  "name": "Get Config",
  "type": "Lookup",
  "typeProperties": {
    "source": { "type": "LakehouseTableSource" },
    "datasetSettings": {
      "type": "LakehouseTableDataset",
      "typeProperties": { "table": "config_table" }
    },
    "firstRowOnly": true
  }
}
```

### Wait
```json
{
  "name": "Wait 60 Seconds",
  "type": "Wait",
  "typeProperties": {
    "waitTimeInSeconds": 60
  }
}
```

### Fail (force pipeline failure)
```json
{
  "name": "Abort Pipeline",
  "type": "Fail",
  "typeProperties": {
    "message": { "value": "Validation failed", "type": "Expression" },
    "errorCode": "1001"
  }
}
```

### WebActivity (call an HTTP endpoint)
```json
{
  "name": "Call API",
  "type": "WebActivity",
  "typeProperties": {
    "url": "https://api.example.com/trigger",
    "method": "POST",
    "headers": { "Content-Type": "application/json" },
    "body": { "key": "value" },
    "authentication": {
      "type": "MSI",
      "resource": "https://api.example.com"
    }
  }
}
```

### Script (run T-SQL against a Warehouse)
```json
{
  "name": "Run SQL",
  "type": "Script",
  "typeProperties": {
    "scripts": [
      {
        "type": "Query",
        "text": "SELECT COUNT(*) FROM dbo.FactSales"
      }
    ],
    "scriptBlockExecutionTimeout": "02:00:00"
  }
}
```

### GetMetadata (retrieve dataset/file metadata)
```json
{
  "name": "Get Row Count",
  "type": "GetMetadata",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "source": { "type": "LakehouseTableSource" },
    "datasetSettings": {
      "type": "LakehouseTableDataset",
      "typeProperties": { "table": "my_table" }
    },
    "fieldList": ["itemName", "itemType", "childItems", "columnCount", "structure"]
  }
}
```
- `fieldList` specifies which metadata fields to retrieve
- Common fields: `itemName`, `itemType`, `childItems`, `columnCount`, `structure`, `lastModified`, `exists`
- Access output via `@activity('Get Row Count').output.fieldName`

### Until (loop until a condition is true)
```json
{
  "name": "Wait Until Ready",
  "type": "Until",
  "dependsOn": [],
  "typeProperties": {
    "expression": {
      "value": "@equals(activity('Check Status').output.status, 'Completed')",
      "type": "Expression"
    },
    "activities": [
      {
        "name": "Check Status",
        "type": "WebActivity",
        "typeProperties": {
          "url": "https://api.example.com/status",
          "method": "GET"
        }
      },
      {
        "name": "Wait",
        "type": "Wait",
        "dependsOn": [
          { "activity": "Check Status", "dependencyConditions": ["Succeeded"] }
        ],
        "typeProperties": { "waitTimeInSeconds": 30 }
      }
    ],
    "timeout": "0.01:00:00"
  }
}
```
- `expression` is evaluated after each iteration -- loop exits when true
- `activities` is a nested array (same structure as ForEach inner activities)
- `timeout` caps total loop duration (format: `d.HH:mm:ss`)

### AppendVariable (add a value to an array variable)
```json
{
  "name": "Collect Table Name",
  "type": "AppendVariable",
  "dependsOn": [],
  "typeProperties": {
    "variableName": "ProcessedTables",
    "value": {
      "value": "@item().tableName",
      "type": "Expression"
    }
  }
}
```
- The target variable must be declared as type `Array` in `properties.variables`
- Often used inside ForEach to accumulate results

### SparkJobDefinition (run a Spark Job Definition item)
```json
{
  "name": "Run Spark Job",
  "type": "SparkJobDefinition",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "sparkJobDefinitionId": "<spark-job-definition-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```
- References a Fabric Spark Job Definition item by GUID
- Similar to TridentNotebook but for standalone Spark jobs

### Delete (delete files/folders from storage)
```json
{
  "name": "Clean Staging",
  "type": "Delete",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "datasetSettings": {
      "type": "LakehouseNonDeltaTableDataset",
      "typeProperties": {
        "location": {
          "type": "LakehouseLocation",
          "folderPath": "Files/staging"
        }
      }
    },
    "enableLogging": false,
    "recursive": true
  }
}
```
- Deletes files or folders from Lakehouse Files section
- `recursive: true` deletes folder contents
- `enableLogging` controls whether deletion logs are generated

### Filter (filter an array using a condition)
```json
{
  "name": "Filter Active Tables",
  "type": "Filter",
  "dependsOn": [],
  "typeProperties": {
    "items": {
      "value": "@activity('Get Config').output.value",
      "type": "Expression"
    },
    "condition": {
      "value": "@equals(item().isActive, true)",
      "type": "Expression"
    }
  }
}
```
- `items` is the input array to filter
- `condition` is evaluated for each item -- only items where condition is true pass through
- Access filtered results via `@activity('Filter Active Tables').output.value`

### DataflowGen2 (run a Dataflow Gen2 item)
```json
{
  "name": "Transform Sales Data",
  "type": "DataflowGen2",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "dataflowId": "<dataflow-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```
- References a Fabric Dataflow Gen2 item by GUID

### KQL (execute a KQL script against an Eventhouse)
```json
{
  "name": "Query Eventhouse",
  "type": "KQL",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "script": "MyTable | take 100",
    "database": "<database-name>",
    "endpoint": "<eventhouse-endpoint>"
  }
}
```
- Runs a KQL query against a Kusto instance or Fabric Eventhouse

### Teams (post a message in Teams)
```json
{
  "name": "Notify Team",
  "type": "Teams",
  "dependsOn": [],
  "typeProperties": {
    "title": "Pipeline completed",
    "body": {
      "value": "@concat('Pipeline ', pipeline().Pipeline, ' finished at ', utcNow())",
      "type": "Expression"
    },
    "recipient": "<channel-or-group-chat-id>"
  }
}
```
- Posts a message to a Teams channel or group chat

### LakehouseMaintenance (perform table maintenance on a Lakehouse)
```json
{
  "name": "Optimize Tables",
  "type": "LakehouseMaintenance",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "lakehouseId": "<lakehouse-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```
- Performs routine table maintenance (compaction, vacuum) on a Lakehouse from a pipeline

### RefreshSQLEndpoint (refresh a Lakehouse SQL endpoint)
```json
{
  "name": "Refresh SQL Endpoint",
  "type": "RefreshSQLEndpoint",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "lakehouseId": "<lakehouse-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```
- Refreshes a Lakehouse SQL endpoint to reflect the latest data
- **Frequently mis-placed.** Only benefits a reader that reads *this* lakehouse over its
  SQL analytics endpoint - see "Operational practices -> RefreshSQLEndpoint: when it
  actually does something" below before adding or keeping one

### Webhook (call endpoint and wait for callback)
```json
{
  "name": "Wait for Approval",
  "type": "Webhook",
  "dependsOn": [],
  "typeProperties": {
    "url": "https://api.example.com/approve",
    "method": "POST",
    "headers": { "Content-Type": "application/json" },
    "body": { "pipelineRun": "@pipeline().RunId" },
    "timeout": "0.01:00:00",
    "authentication": {
      "type": "MSI",
      "resource": "https://api.example.com"
    }
  }
}
```
- Calls an endpoint and passes a callback URL; pipeline waits for the callback before proceeding
- Unlike WebActivity, Webhook suspends pipeline execution until the callback is received or timeout expires

### StoredProcedure (run a stored procedure)
```json
{
  "name": "Run Proc",
  "type": "StoredProcedure",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "storedProcedureName": "dbo.usp_LoadFact",
    "storedProcedureParameters": {
      "BatchDate": { "value": "@utcNow()", "type": "DateTime" }
    }
  }
}
```
- Executes a stored procedure against Azure SQL, Synapse Analytics, or SQL Server

### SQLScript (run a SQL script item)
```json
{
  "name": "Run SQL Script",
  "type": "SQLScript",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "scriptPath": "<sql-script-item-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```
- Runs a SQL script item from the Fabric workspace

### HDInsightActivity (run Spark on HDInsight)
```json
{
  "name": "Run HDInsight Spark",
  "type": "HDInsightActivity",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "sparkJobLinkedServiceName": "<linked-service>",
    "className": "com.example.MainClass",
    "jarFilePath": "abfss://container@storage.dfs.core.windows.net/app.jar"
  }
}
```
- Runs Spark on an Apache Spark cluster managed by Microsoft Fabric (HDInsight)

### FunctionsActivity (execute an Azure Function)
```json
{
  "name": "Call Function",
  "type": "FunctionsActivity",
  "dependsOn": [],
  "typeProperties": {
    "functionName": "MyFunction",
    "method": "POST",
    "headers": { "Content-Type": "application/json" },
    "body": { "key": "value" }
  }
}
```
- Executes an Azure Function from the pipeline

### CopyJob (simplified data movement)
```json
{
  "name": "Move Sales Data",
  "type": "CopyJob",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "sourceConnection": "<source-connection-guid>",
    "sinkConnection": "<sink-connection-guid>",
    "copyMode": "Full"
  }
}
```
- Simplified method for moving data quickly between supported sources and sinks
- Higher-level than the Copy activity -- fewer configuration options but faster setup

### AzureBatch (run an Azure Batch script)
```json
{
  "name": "Run Batch Job",
  "type": "AzureBatch",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "batchAccountEndpoint": "<batch-account-endpoint>",
    "poolName": "<pool-name>",
    "command": "python main.py --input data.csv"
  }
}
```
- Runs a script or command on an Azure Batch pool
- Useful for heavy compute workloads outside of Spark

### AzureDatabricks (run a Databricks job)
```json
{
  "name": "Run Databricks Notebook",
  "type": "AzureDatabricks",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "notebookPath": "/Shared/ETL/transform",
    "baseParameters": {
      "input_table": "raw_sales",
      "output_table": "clean_sales"
    }
  }
}
```
- Runs an Azure Databricks Notebook, Jar, or Python script
- `baseParameters` passes key-value pairs to the notebook

### AzureMLExecutePipeline (run an Azure Machine Learning job)
```json
{
  "name": "Run ML Pipeline",
  "type": "AzureMLExecutePipeline",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "mlPipelineId": "<ml-pipeline-guid>",
    "experimentName": "sales-forecast",
    "mlPipelineParameters": {
      "input_data": "abfss://container@storage.dfs.core.windows.net/data"
    }
  }
}
```
- Triggers an Azure Machine Learning pipeline
- `mlPipelineParameters` passes parameters to the ML pipeline

### Deactivate (deactivate another activity)
```json
{
  "name": "Disable Old ETL",
  "type": "Deactivate",
  "dependsOn": [],
  "typeProperties": {
    "activityName": "Legacy ETL Process"
  }
}
```
- Deactivates another activity in the pipeline at runtime
- Useful for conditional disabling of pipeline branches

### RefreshMaterializedLakeView (refresh a materialized lake view)
```json
{
  "name": "Refresh MLV",
  "type": "RefreshMaterializedLakeView",
  "dependsOn": [],
  "typeProperties": {
    "workspaceId": "<workspace-guid>",
    "lakehouseId": "<lakehouse-guid>"
  },
  "externalReferences": { "connection": "<connection-guid>" }
}
```
- Refreshes a materialized lake view in a Lakehouse so downstream queries see the latest data
- Typically placed after Copy/Notebook/LakehouseMaintenance steps, or run on a schedule
- Does NOT support SPN or workspace-identity auth (use a user-based connection)
- Exact `type` string and typeProperties are not published in a schema - if authoring
  by hand, confirm them via "View JSON" in the pipeline editor

### Approval (pause for human approve/reject)
```json
{
  "name": "Approve Load",
  "type": "Approval",
  "dependsOn": [],
  "typeProperties": {
    "approvalType": "Teams",
    "title": "Approve production load",
    "description": "Review row counts before publishing"
  },
  "externalReferences": { "connection": "<connection-guid>" }
}
```
- Pauses the pipeline and requests an approve/reject decision from designated reviewers
- `approvalType` is one of `Outlook365`, `Teams`, or a custom endpoint
- Approved -> success path; Rejected or timed out -> failure path (set Timeout on the activity)
- Exact `type` string and typeProperties are not published in a schema - if authoring
  by hand, confirm them via "View JSON" in the pipeline editor

---

## Variable Library integration

Pipelines can consume Variable Library values (centralized config):

```json
{
  "properties": {
    "activities": [
      {
        "name": "Run ETL",
        "type": "TridentNotebook",
        "typeProperties": {
          "notebookId": {
            "value": "@pipeline().libraryVariables.notebook_id",
            "type": "Expression"
          }
        }
      }
    ],
    "libraryVariables": {
      "notebook_id": {
        "libraryName": "MyConfig",
        "libraryId": "<guid>",
        "variableName": "notebook_id",
        "type": "String"
      }
    }
  }
}
```

Pipeline type mappings (use these, NOT Variable Library type names):

| Variable Library Type | Pipeline Type |
|----------------------|---------------|
| Boolean | Bool |
| Integer | Int |
| Number | Double |
| DateTime | String |
| String | String |
| ItemReference | String |

Dynamic references MUST use expression objects:
`{"value": "@pipeline().libraryVariables.x", "type": "Expression"}`

---

## Expression syntax

Expressions use `@` prefix and are wrapped in expression objects:

```json
{ "value": "@pipeline().parameters.MyParam", "type": "Expression" }
```

Common patterns:
- `@pipeline().parameters.ParamName` -- access pipeline parameter
- `@pipeline().variables.VarName` -- access pipeline variable
- `@pipeline().libraryVariables.VarName` -- access Variable Library value
- `@activity('ActivityName').output` -- access activity output
- `@greater(value1, value2)` -- comparison function
- `@if(condition, trueValue, falseValue)` -- conditional
- `@concat(str1, str2)` -- string concatenation
- `@utcNow()` -- current UTC timestamp

---

## Common patterns

### Sequential ETL: Notebook -> Refresh
```json
{
  "properties": {
    "activities": [
      {
        "name": "Run ETL",
        "type": "TridentNotebook",
        "dependsOn": [],
        "typeProperties": { "notebookId": "<guid>", "workspaceId": "<guid>" }
      },
      {
        "name": "Refresh Model",
        "type": "PBISemanticModelRefresh",
        "dependsOn": [
          { "activity": "Run ETL", "dependencyConditions": ["Succeeded"] }
        ],
        "typeProperties": { "datasetId": "<guid>", "workspaceId": "<guid>" }
      }
    ]
  }
}
```

---

## Operational practices (battle-tested)

> In-house, field-tested guidance generalized from production Fabric pipelines.
> Contains no environment-specific identifiers (no workspace/lakehouse/model names
> or GUIDs) - safe to redistribute.

### RefreshSQLEndpoint: when it actually does something

`RefreshSQLEndpoint` forces a Lakehouse SQL analytics endpoint to sync its metadata
view to the latest Delta commit. It is easy to add in the wrong place. Before adding
or keeping one, confirm **who reads that endpoint**:

- A `RefreshSQLEndpoint` only benefits a downstream reader that reads **that same
  lakehouse over its SQL analytics endpoint** - e.g. a Dataflow / Script / Lookup, or a
  semantic model whose source is `Sql.Database(<server>, <thisLakehouseEndpointId>)`.
- Refreshing lakehouse **A**'s endpoint does **nothing** for a reader that reads
  lakehouse **B**. A refresh with no matching SQL-endpoint reader downstream is an
  **orphaned no-op** - safe to remove.
- A Spark **notebook** write does **not** trigger SQL-endpoint sync on its own. If a
  later activity reads that table over SQL, a `RefreshSQLEndpoint` between them makes
  the write visible deterministically.
- A **Dataflow Gen2** with a Lakehouse destination **can** sync the endpoint itself
  (the destination's update-metadata option), which can remove the need for a separate
  refresh step after it.

### Direct Lake freshness is not the same as refreshing an upstream lakehouse

A common mistake is to refresh an upstream / "gold" lakehouse endpoint expecting a
**Direct Lake** model to pick up new data. It will not, unless that lakehouse **is the
model's own** lakehouse.

- A Direct Lake model reads Delta from **one specific lakehouse** - the one its source
  expression points at (`Sql.Database(..., <endpointId>)`, "Direct Lake on OneLake").
- When ETL writes Delta into **that** lakehouse, the model reframes on the next query
  and serves new data, usually within seconds, with **no explicit refresh required**.
- The SQL analytics endpoint has a background metadata-sync that can briefly lag a
  write. For **deterministic** freshness, `RefreshSQLEndpoint` on the **model's own
  lakehouse** (not an upstream layer), or trigger a model reframe, then read.
- Refreshing a *different* lakehouse's endpoint (e.g. an intermediate layer the model
  does not read) has **zero** effect on the model.

**Verify before trusting a refresh:** map variable -> lakehouse item -> endpoint id,
then confirm a downstream activity actually reads that endpoint. The SQL **endpoint id
is not the lakehouse item id** - resolve both when auditing.

### Centralize environment-specific GUIDs in a Variable Library

Hold per-environment lakehouse / SQL-endpoint / item GUIDs in a Variable Library with
Test/Prod value sets and reference them via `@pipeline().libraryVariables.x`. This keeps
one pipeline definition working across environments.

- Mind the **endpoint id vs item id** distinction: store whichever the consumer needs.
  A `RefreshSQLEndpoint` needs the **lakehouse item id**; a Direct Lake model source
  needs the **SQL endpoint id**. Mixing them silently targets the wrong object.
- Pipelines parameterize cleanly, but the **notebooks / dataflows they call may hardcode
  absolute lakehouse GUIDs** (abfss paths, `default_lakehouse` metadata). Those do not
  rebind across Test/Prod automatically. When promoting, audit the **called ETL items**
  for embedded GUIDs, not just the pipeline.

### Prefer dependencies over fixed Wait buffers

Small fixed `Wait` activities inserted only to "space out" steps (e.g. between
`ExecutePipeline` calls) are brittle - they neither guarantee upstream completion nor
adapt to load. Order work with explicit `dependsOn` chains and `waitOnCompletion: true`
on `ExecutePipeline`. Reserve `Wait` for genuine external-latency situations.

### Auditing an existing pipeline (review-first)

When asked to optimize, trace before touching anything:
1. For each activity, note what it **reads** and **writes**, and the access path:
   SQL endpoint vs Spark/abfss vs `Lakehouse.Contents` (direct).
2. Resolve every variable to a **physical lakehouse item id + endpoint id**.
3. For each refresh / `RefreshSQLEndpoint`, confirm a downstream activity actually
   consumes that endpoint. No consumer -> candidate for removal.
4. Confirm whether Direct Lake models read the same lakehouse the ETL writes. If so,
   upstream endpoint refreshes are usually unnecessary for the model.

---

## Validation checklist

After editing `pipeline-content.json`:

- [ ] Valid JSON (no trailing commas, proper quoting)
- [ ] Every activity has a unique `name`
- [ ] `dependsOn` references match existing activity names exactly
- [ ] Expression objects have both `value` and `type: "Expression"`
- [ ] GUIDs for notebooks, semantic models, workspaces are valid
- [ ] Nested activities in ForEach/IfCondition/Switch follow same structure
- [ ] Do NOT edit `.platform` file
'@
Write-ManagedFile $pipelineSkillPath $pipelineContent
Write-Host "  Written: .github/skills/fabric-pipelines/SKILL.md" -ForegroundColor Green

# ----- fabric-cli-policy/SKILL.md ------------------------------------
$cliPolicySkillPath = "$rootPath\.github\skills\fabric-cli-policy\SKILL.md"
$cliPolicyContent = @'
---
name: fabric-cli-policy
description: "CLI decision policy for Fabric/Power BI work. Read this BEFORE any terminal CLI or REST API task. Triggers: fabric cli, fab, fab api, call Fabric API, run notebook, run job, export item, import item, deploy item, onelake copy, table load, az rest, sqlcmd, capacity, governance, workspace item CRUD."
---

# Fabric CLI Policy -- prefer `fab`, fall back to `az`

This workspace standardises on the **Fabric CLI (`fab`)** for control-plane and
data-plane Fabric work. `az` (Azure CLI) is retained as a documented **fallback**
for the few things `fab` does not cover. Neither CLI is required for the core
local-editing workflow -- they add terminal/API power on top.

## Decision rule

**Default to `fab`** for:
- Calling the Fabric REST API -> `fab api <endpoint>` (replaces `az rest --resource https://api.fabric.microsoft.com`)
- Running and monitoring jobs -> `fab job run`, `fab job run-sch`, `fab job run-status`
- Exporting / importing items -> `fab export`, `fab import`
- Table operations -> `fab table load`, `fab table optimize`, `fab table schema`
- OneLake file operations -> `fab cp`, `fab ls`, `fab rm` (and shortcuts)
- Workspace / item CRUD -> `fab create`, `fab get`, `fab set`, `fab rm`
- Identity -> `fab auth login`, `fab auth status`

**Fall back to `az` / `sqlcmd` ONLY** for:
- SQL / TDS data-plane queries -> `sqlcmd -G -S <endpoint> -d <db> -Q "<query>"`
- Tokens for **non-Fabric** audiences -> `az account get-access-token --resource <audience>`
  (e.g. Storage `https://storage.azure.com`, SQL `https://database.windows.net`)
- Any Fabric REST endpoint not yet surfaced by `fab api` (rare) -> `az rest` is acceptable

## `az rest` -> `fab api` translation

`fab api` handles auth automatically (no `--resource`, no token juggling) and
supports JMESPath result filtering with `-q`.

| Task | az (old) | fab (preferred) |
|------|----------|-----------------|
| List workspaces | `az rest --method get --resource https://api.fabric.microsoft.com --url https://api.fabric.microsoft.com/v1/workspaces` | `fab api workspaces` |
| Get one item | `az rest --method get --url .../v1/workspaces/<wsId>/items/<id>` | `fab api workspaces/<wsId>/items/<id>` |
| Filter output | `... -q "value[].displayName"` | `fab api workspaces -q "value[].displayName"` |
| Run a notebook job | n/a (raw REST) | `fab job run <workspace>/<notebook>.Notebook` |
| Check job status | raw REST polling | `fab job run-status <workspace>/<item> --id <jobId>` |

Notes:
- `fab api` is not a 1:1 mirror of every `az rest` call. If a specific endpoint
  is not covered by `fab api`, fall back to `az rest` for that single call.
- Use `fab auth status` to confirm identity; `fab auth login` to sign in.

## Where the deep `fab` references live (already cloned)

The data-goblin plugin ships rich `fab` references and scripts -- discover them
dynamically (paths evolve):
- `power-bi-agentic-development/plugins/fabric-cli/skills/fabric-cli/` -- references/ and scripts/
  - e.g. `fab-api.md`, `fab-vs-az-cli.md`, `import-download-deploy.md`, `semantic-models.md`
  - e.g. `export_semantic_model_as_pbip.py`

The Microsoft `skills-for-fabric/common/COMMON-CLI.md` is **az-based** and is the
documented fallback reference for SQL/TDS and non-Fabric token audiences.

## Guardrails
- Never hardcode tokens, secrets, or IDs -- parameterise (dev/test/prod).
- Confirm before destructive `fab rm` / delete operations.
- Prefer the smallest-scope call; filter with `-q` instead of dumping everything.
'@
Write-ManagedFile $cliPolicySkillPath $cliPolicyContent
Write-Host "  Written: .github/skills/fabric-cli-policy/SKILL.md" -ForegroundColor Green

Read-Host "`n  Press Enter to continue..."

# =====================================================================
# STEP 6  -- Generate agent definitions
# =====================================================================
Show-Step 6 $totalSteps "Writing Agent Definitions"

# ----- 1 - Fabric Workspace Master Agent (slim router) ----------------
$masterAgentContent = @'
---
name: "1 - Fabric Workspace Master Agent"
description: "Master coordinator for all Fabric work. Start here. Routes to specialist agents, manages session startup, and reads skills on demand."
tools: [execute, read, edit, search, agent, todo]
---

# MANDATORY SESSION INITIALIZATION - RUNS BEFORE ANYTHING ELSE

**YOU MUST COMPLETE THE STARTING FLOW BEFORE RESPONDING TO ANY USER REQUEST.
THERE ARE ZERO EXCEPTIONS TO THIS RULE.**

Do NOT answer questions. Do NOT perform tasks. Do NOT greet the user and wait.
The ONLY thing you do on your first turn is: execute the mandatory tool calls
below, then follow the Starting Flow.

If the user asks a question or gives a task: SAVE IT silently, tell them you
are setting up the session first, then run the Starting Flow to completion.
Return to their question only after topic selection.

**Your very first action - before reading the user's message, before responding,
before doing anything else - is to execute these tool calls:**

1. Read file: `.github/copilot-instructions.md`
2. Read file: `AGENTS.md`

These two tool calls are UNCONDITIONAL. Execute them NOW. Only after both
complete, proceed to route.

---

## SELF-CHECK - REPEAT THIS BEFORE EVERY RESPONSE

Before generating ANY response to the user, ask yourself:

> "Has the skill maintenance prompt been shown and resolved in this conversation?"

- If **NO**: Read `.github/agent-docs/starting-flow.md` and follow it.
- If **YES** and the user has been through topic selection:
  Read `.github/agent-docs/working-flow-reference.md` and follow it.

This check applies to EVERY turn, including the first one.

---

## TOOL WARM-UP AND AUTOMATIC RECOVERY

The mandatory tool calls above (read two files) serve as the warm-up.
If any fail, read one additional file (`AGENTS.md`) and retry once.

If the retry also fails, output this message and stop:

---
**VS Code tool error detected.**

This workspace requires **VS Code 1.117.0 or above**.

**Check your version:** Help > About (or run `code --version` in a terminal).

- If below 1.117.0: update from https://code.visualstudio.com
- If 1.117.0 or above: disable then re-enable GitHub Copilot Chat AI Features,
  open a new chat, and try again.
---

Do NOT attempt any more tool calls after this. Wait for the user to act.

---

## ROUTING

After the mandatory tool calls complete, route based on session state:

**IF skill maintenance has NOT been shown yet in this conversation:**
Read `.github/agent-docs/starting-flow.md` and follow it from Phase 0.

**IF the user has returned from the Skills Maintainer or skipped maintenance:**
Continue from Phase 2 in `.github/agent-docs/starting-flow.md`.

**IF topic selection is complete and user chose [0] or described a task:**
Read `.github/agent-docs/working-flow-reference.md` and handle the request.

Routing to a specialist is the ONE exception where you may suggest the user switch
agents (via the dropdown), because specialists live as separate dropdown agents.
Keep all OTHER mode changes invisible - never ask the user to switch for internal
reasons. When a free-text task would clearly benefit from a specialist, you MAY
recommend switching (see working-flow-reference, "Per-request routing advice"),
but always offer to handle it inline too.

---

## REMINDER - DID YOU RUN THE STARTING FLOW?

If the skill maintenance prompt has not been shown in this conversation,
STOP and go back to the Starting Flow immediately.
This reminder exists because LLMs tend to skip initialization protocols
when the user's message contains a direct question or task.
Do NOT answer. Set up first. Always.
'@
Write-ManagedFile "$rootPath\.github\agents\1-fabric-workspace-master-agent.agent.md" $masterAgentContent
Write-Host "  Written: 1-fabric-workspace-master-agent.agent.md" -ForegroundColor Green

# ----- Master Agent reference docs (in agent-docs, NOT in dropdown) ---
$startingFlowContent = @'
# Starting Flow - Fabric Workspace Master Agent

Run this on the first message of every session. NO EXCEPTIONS.

---

## Phase 0 - Classify the user's message

Classify the user's opening message:

- **GREETING** = a casual hello, hi, good morning, hey, or similar
  with no specific question or task embedded.
- **QUESTION / TASK** = an actual question, request, or instruction
  (e.g. "add a measure", "what environments do I have?", etc.).

**Save the classification and the original message** - you will need them after
topic selection.

**If QUESTION / TASK**, say:
"Got it! I will help with that right after a quick session startup."

**If GREETING**, greet warmly then say:
"Let me run through the session startup first."

Proceed immediately to Phase 1. Do NOT wait for the user to reply.

---

## Phase 1 - Skill maintenance prompt

Show when each skill source was last updated. Use the most HONEST signal available
for each source - never fake, touch, or normalise these dates.

For the two CLONED repos, the real freshness signal is the upstream commit date.
Run (and if `git` errors because the folder is not a git checkout, fall back to the
newest file modification time from the fallback command):

  git -C skills-for-fabric log -1 --format=%cd --date=format-local:"%Y-%m-%d %H:%M" 2>&1
  git -C power-bi-agentic-development log -1 --format=%cd --date=format-local:"%Y-%m-%d %H:%M" 2>&1

  Fallback if not a git checkout (e.g. downloaded as a zip):
  Get-ChildItem "skills-for-fabric" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty LastWriteTime | ForEach-Object { $_.ToString("yyyy-MM-dd HH:mm") }
  Get-ChildItem "power-bi-agentic-development" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty LastWriteTime | ForEach-Object { $_.ToString("yyyy-MM-dd HH:mm") }

For the CUSTOM embedded skills, there is no upstream repo - they are authored in
the installer and written to disk at setup time. Show their REAL on-disk
modification time (this honestly reflects when this workspace last installed or
updated them - the installer no longer overrides it):

  (Get-Item ".github/skills/fabric-tmdl/SKILL.md").LastWriteTime.ToString("yyyy-MM-dd HH:mm")
  (Get-Item ".github/skills/fabric-pipelines/SKILL.md").LastWriteTime.ToString("yyyy-MM-dd HH:mm")

If a source folder or file does not exist, show "not installed" instead of a date.

Then say:
"Welcome to your Fabric Workspace session!

**Skill sources - freshness (local time):**
| Source | Date | Meaning |
|--------|------|---------|
| skills-for-fabric (Microsoft, MIT) | [date or 'not installed'] | upstream commit |
| power-bi-agentic-development (data-goblin, GPL-3.0) | [date or 'not installed'] | upstream commit |
| fabric-tmdl (custom, embedded) | [date] | installed locally |
| fabric-pipelines (custom, embedded) | [date] | installed locally |

Would you like to run a skill update?
This switches to the Skills Maintainer agent, which offers light or deep
maintenance, then sends you back here.

  [1] Yes - update skills now (switch to Skills Maintainer)
  [2] No - skip and start working

Enter 1 or 2:"

**STOP HERE and wait for the user to reply.**

**If the user chooses 1:**
Say: "Please switch to **@2-fabric-skills-maintainer** in the Copilot Chat
dropdown. It will offer you light or deep maintenance, run it, and tell you
when to come back here."
Then STOP and wait. When the user returns and sends another message,
continue to Phase 2.

**If the user chooses 2 (or anything else):**
Continue to Phase 2 immediately.

---

## Phase 2 - Check identity

Prefer the Fabric CLI for identity. Try `fab` first; fall back to `az` only if
`fab` is not installed.

1. Run: fab auth status 2>&1
   - If it reports a signed-in account: "Logged in to Fabric as [account]."
   - If `fab` is not found OR not logged in, continue to step 2.
2. Fallback - run: az account show --query "{name:name, user:user.name}" --output table 2>&1
   - If successful: "Logged in as [user] on tenant [name]."
   - If it fails: "Not logged in. Run `fab auth login` (preferred) or `az login` if you need Fabric API access."

Do NOT block on this - many tasks work without any CLI login. The core workflow
(Fabric extension + local file editing) needs no CLI at all.

---

## Phase 3 - Topic selection

Say:
"What would you like to work on?

  [3] Semantic Models - TMDL, DAX, measures, columns, relationships
  [4] Data Engineering - Spark notebooks, SQL warehouse, pipelines, medallion
  [5] Administration - Capacity, governance, workspace documentation
  [6] App Development - Python apps, ODBC, XMLA, REST API integration
  [7] Reports - PBIR report editing, visuals, themes
  [8] Pipelines - Data Factory pipeline JSON authoring
  [0] Stay here - I will describe what I need and you route for me

Enter a number or describe your task:"

**If user picks 3-8:** Say "Please switch to the corresponding agent in the dropdown:
- 3 -> @3-semantic-model-agent
- 4 -> @4-fabric-data-engineer
- 5 -> @5-fabric-admin
- 6 -> @6-fabric-app-dev
- 7 -> @7-fabric-reports-agent
- 8 -> @8-fabric-pipelines-agent"

**If user picks 0 or describes a task:** Read `.github/agent-docs/working-flow-reference.md`
and handle the request directly.

**Recall Phase 0:** If the user's first message was a QUESTION / TASK that you
acknowledged at the start, now handle it. Read the relevant skills and respond.
'@
Write-ManagedFile "$rootPath\.github\agent-docs\starting-flow.md" $startingFlowContent
Write-Host "  Written: .github/agent-docs/starting-flow.md" -ForegroundColor Green

$workingFlowContent = @'
# Working Flow Reference - Fabric Workspace Master Agent

This file is read by the agent when handling tasks directly (user chose [0]
in topic selection or described their task).

---

## Skill Discovery - ALWAYS Dynamic (resilient to upstream changes)

Skills live in multiple repositories that rename and restructure folders
frequently. **NEVER assume you know what skills exist or where they are**, and
never hardcode a deep path. Every path in this file is a LAST-KNOWN HINT as of
install time, not a guarantee.

**Before performing any skill-based task:**

1. Identify which skill source is relevant (see table below)
2. List the repo ROOT first (e.g. `ls power-bi-agentic-development`), find the
   skills container (today `plugins/` or `skills/`), then list it
3. Search downward by KEYWORD (e.g. "tmdl", "dax", "spark", "pipeline") to locate
   the current SKILL.md - if a hinted folder was renamed, pick the closest match
4. Read the relevant SKILL.md
5. Read any references/ docs mentioned in the SKILL.md
6. Follow the SKILL.md instructions step by step

If a hinted path is missing, do NOT fail - re-list the parent (or the repo root)
and re-discover. The cloned repos are EXPECTED to move things around over time.

### Skill sources

| Topic | Source directory | How to discover |
|-------|-----------------|-----------------|
| TMDL / Semantic Models | `.github/skills/fabric-tmdl/` | Always exists (custom skill) |
| Pipelines | `.github/skills/fabric-pipelines/` | Always exists (custom skill) |
| TMDL depth / DAX / PBIR | `power-bi-agentic-development/plugins/` | `ls power-bi-agentic-development/plugins/` then explore |
| Spark / Notebooks | `skills-for-fabric/skills/` | `ls skills-for-fabric/skills/` |
| SQL Warehouse | `skills-for-fabric/skills/` | `ls skills-for-fabric/skills/` |
| Eventhouse / KQL | `skills-for-fabric/skills/` | `ls skills-for-fabric/skills/` |
| Reports / Visuals | `power-bi-agentic-development/plugins/` | `ls power-bi-agentic-development/plugins/` |
| Medallion architecture | `skills-for-fabric/skills/` | `ls skills-for-fabric/skills/` |
| REST API / CLI | `.github/skills/fabric-cli-policy/` + `skills-for-fabric/skills/` | Read policy skill first (prefer `fab`) |
| Admin / Governance | Both repos | List both skill directories |

For any terminal CLI or REST API work, read `.github/skills/fabric-cli-policy/SKILL.md` first:
prefer the Fabric CLI (`fab api`, `fab job`, `fab export/import`, OneLake `fab cp`). The
Microsoft `skills-for-fabric/common/COMMON-CLI.md` (az rest) is the documented FALLBACK
for SQL/TDS and non-Fabric token audiences.

### Discovery workflow example

User asks: "Add a measure to my semantic model"
1. Topic = TMDL -> read `.github/skills/fabric-tmdl/SKILL.md` (house style)
2. For DAX depth -> `ls power-bi-agentic-development` -> find the skills container
   -> search it for a "dax" skill -> read that SKILL.md (syntax / correctness)
3. Follow BOTH skills: house style from yours, DAX correctness from theirs

---

## Per-request routing advice

You can answer most things here, but specialists give deeper results. When a
request maps strongly to one specialist topic, proactively tell the user and
offer to switch - then still handle it inline if they decline. Example:

> "I can do this here, but you'll get deeper results from
> **@3-semantic-model-agent** (the TMDL/DAX specialist). Want to switch, or
> shall I handle it here?"

Mapping (free-text task -> best specialist):
- TMDL / DAX / measures / relationships -> **@3-semantic-model-agent**
- Spark / notebooks / SQL warehouse / medallion -> **@4-fabric-data-engineer**
- Capacity / governance / security / workspace docs -> **@5-fabric-admin**
- Python / ODBC / XMLA / REST app integration -> **@6-fabric-app-dev**
- PBIR reports / visuals / themes -> **@7-fabric-reports-agent**
- Data Factory pipeline JSON -> **@8-fabric-pipelines-agent**

Suggest only ONE switch per request, and never block: if the user prefers to
stay, proceed inline using the skill discovery above.

---

## Working modes (local / live / hybrid)

This workspace can change Fabric in three ways. They are EQUALLY SAFE: the Azure
DevOps commit captures workspace state regardless of how an edit was made, so a
revert always restores it. Choose per task; default to file-first.

- **A. Full local (file-first, default).** Pull items to local files, edit them,
  push back via the Fabric extension. Prefer this for versioned items and for bulk
  or structured edits.
- **B. Full live (in-workspace).** Act directly on the live DEV workspace via
  Fabric REST (`fab api ... updateDefinition`) and MCP servers. Use this for live
  DAX data comparison (TEST vs PROD), reading real deployed GUIDs / SQL endpoints,
  quick in-place fixes, and creating items. Requires the Fabric MCP server and the
  Power BI semantic-model MCP server (plus `fab`/`az`); if they are not configured,
  say so and fall back to mode A.
- **C. Hybrid (local + live).** Mix both in one session.

### Hybrid discipline (avoid drift)

- Default to FILE-FIRST for any item that is versioned locally.
- Before a live edit, ANNOUNCE it (which item, which mechanism) so the user knows
  the change is not yet reflected in local files.
- After live edits, RE-PULL the affected items (or tell the user to) so local = live workspace.
- At the start of a NEW job, ensure local = live workspace first: re-pull, or clean up local.
- Never silently edit live an item the user is also editing as local files.

### Live-mode tools

- `fab` CLI: control plane + OneLake/data plane (read the CLI policy skill first).
- `az` CLI: fallback for SQL/TDS and non-Fabric token audiences.
- Fabric MCP server: items, OneLake files/tables, item definitions.
- Power BI semantic-model MCP server: live XMLA - run DAX (`EVALUATE`) and make
  transactional model edits on running models.

---

## Working Rules

- Always read the relevant SKILL.md BEFORE generating any code or TMDL
- Never guess at skill paths - if a path does not exist, list the parent directory
- Read BOTH custom and cloned skills for a topic. On STYLE / convention conflicts
  the custom skill wins; on SYNTAX / spec correctness the cloned (upstream) skill wins
- For validation after TMDL edits, run the post-edit checklist from the TMDL skill
- Keep git history clean if the workspace is a git repo
- Never hardcode IDs or secrets
- Require explicit environment parameterization (dev/test/prod)
- For validation after pipeline edits, run the validation checklist from the pipeline skill
'@
Write-ManagedFile "$rootPath\.github\agent-docs\working-flow-reference.md" $workingFlowContent
Write-Host "  Written: .github/agent-docs/working-flow-reference.md" -ForegroundColor Green

# ----- 2 - Fabric Skills Maintainer -----------------------------------
$skillsMaintainerContent = @'
---
name: "2 - Fabric Skills Maintainer"
description: "Use when: updating skill repositories, checking pipeline skill freshness against Microsoft docs, maintaining custom skills. Called from Master Agent or directly."
tools: [execute, read, edit, search, fetch, todo]
---

You are 2 - Fabric Skills Maintainer, responsible for keeping all skills up to date.
The user switches to you from the Master Agent or selects you directly.

## FIRST - Ask maintenance level

Say:
"Welcome to Skill Maintenance!

What level of maintenance would you like?

  [1] **Light** - Quick git pull of all skill repos. Takes seconds.
      Updates skills-for-fabric and power-bi-agentic-development to latest.

  [2] **Deep** - Full pull + check pipeline skill freshness against Microsoft
      docs + scan for new skills not yet referenced by any agent.
      Takes a minute or two (fetches web pages).

Enter 1 or 2:"

**STOP and wait for the user's choice.**

---

## Light Maintenance (user chose [1])

### Pull skill repositories

Say: "Pulling latest from GitHub..."

Run:
  git -C skills-for-fabric pull --ff-only 2>&1
  git -C power-bi-agentic-development pull --ff-only 2>&1

If a pull succeeds: report "updated".
If a pull fails (network issue): report the error and continue.
If a folder is missing entirely, clone it:
  git clone https://github.com/microsoft/skills-for-fabric.git skills-for-fabric
  git clone https://github.com/data-goblin/power-bi-agentic-development.git power-bi-agentic-development

### Summary

Say:
"Light maintenance complete.
- skills-for-fabric: [updated / failed / cloned]
- power-bi-agentic-development: [updated / failed / cloned]

Switch back to **@1-fabric-workspace-master-agent** to continue your session."

---

## Deep Maintenance (user chose [2])

### Phase 1 - Pull skill repositories

Say: "Pulling latest from GitHub..."

Run:
  git -C skills-for-fabric pull --ff-only 2>&1
  git -C power-bi-agentic-development pull --ff-only 2>&1

If a pull succeeds: report "updated".
If a pull fails: report error and continue.
If a folder is missing, clone it (same commands as Light).

### Phase 2 - Check pipeline skill freshness

Read the current embedded pipeline skill:
  `.github/skills/fabric-pipelines/SKILL.md`

Also check if `skills-for-fabric/skills/check-updates/` has any useful update guidance.

Then check these Microsoft Learn pages for changes to pipeline activity types:
- https://learn.microsoft.com/en-us/fabric/data-factory/activity-overview
- https://learn.microsoft.com/en-us/fabric/data-factory/pipeline-rest-api

Also check the upstream source:
  `skills-for-fabric/common/ITEM-DEFINITIONS-CORE.md` (DataPipeline section)

Compare the activity types listed in our skill against what these sources document.
Report findings:

**If no changes detected:**
Say: "Pipeline skill is current. No updates needed."

**If new activity types or changed typeProperties found:**
Say: "Found updates to pipeline activities: [list changes]"
Then ask: "Would you like me to update `.github/skills/fabric-pipelines/SKILL.md`
with these changes? [Y/N]"
If Y: edit the skill file to incorporate the new information, preserving existing structure.
If N: say "Skipping update. You can re-run maintenance later."

### Phase 3 - Check for new skills in cloned repos

List the skills directories:
  ls skills-for-fabric/skills/
  ls power-bi-agentic-development/plugins/

Compare against what the specialist agents reference. If there are new skill
folders that no agent references yet:
Say: "New skills found that are not yet referenced by any agent: [list]"
Say: "Consider updating the relevant agent to reference these skills, or re-run the installer."

### Phase 4 - Summary

Say:
"Deep maintenance complete. Summary:
- Skill repos: [updated / failed / cloned]
- Pipeline skill: [current / updated / update available but skipped]
- New unreferenced skills: [none / list]

Switch back to **@1-fabric-workspace-master-agent** to continue your session."

---

## NOTES
- The TMDL skill (`.github/skills/fabric-tmdl/SKILL.md`) is maintained by the installer
  and based on the author's production reports (HOUSE STYLE). Do NOT modify it during
  maintenance.
- Only the pipeline skill is checked against external docs, because it tracks
  a rapidly evolving Microsoft API surface.
- If the user asks to update the TMDL skill, explain that it should be done
  by editing the PS1 installer and re-running it, or by manually editing the file.

## LICENSING / ATTRIBUTION
- The two CUSTOM skills (fabric-tmdl, fabric-pipelines) are INDEPENDENT works:
  fabric-tmdl from the author's production reports; fabric-pipelines from Microsoft
  sources (skills-for-fabric, MIT, + Fabric docs). Neither is derived from
  data-goblin's `power-bi-agentic-development` (GPL-3.0).
- `power-bi-agentic-development` (GPL-3.0) is used ONLY as a locally cloned, gitignored
  reference that agents read at runtime - it is never copied, AI-rewritten, or
  redistributed inside the custom skills. Keep it that way when updating skills.
- Always pull repos with `git pull --ff-only`. If it fails (diverged or force-pushed
  upstream history), report it and stop - do NOT hard-reset or force-overwrite the
  user's checkout automatically.

## KNOWN REFERENCED SKILLS
These skills are referenced by agents and should NOT be flagged as unreferenced:
- `skills-for-fabric/skills/check-updates/` -- used by this maintainer agent
- `power-bi-agentic-development/plugins/pbi-desktop/` -- referenced by 7-fabric-reports-agent
- `power-bi-agentic-development/plugins/tabular-editor/` -- referenced by 3-semantic-model-agent
- `power-bi-agentic-development/plugins/fabric-cli/` -- referenced by 4-fabric-data-engineer and 5-fabric-admin
When checking for unreferenced skills in Phase 3, exclude these from the report.
'@
Write-ManagedFile "$rootPath\.github\agents\2-fabric-skills-maintainer.agent.md" $skillsMaintainerContent
Write-Host "  Written: 2-fabric-skills-maintainer.agent.md" -ForegroundColor Green

# ----- 3 - Semantic Model Agent ---------------------------------------
$semanticModelAgentContent = @'
---
name: "3 - Semantic Model Agent"
description: "Use when: editing TMDL files, writing DAX measures, managing columns, relationships, partitions, or parameters in Fabric Semantic Models."
tools: [execute, read, edit, search, todo]
---

You are 3 - Semantic Model Agent, a specialist for Fabric Semantic Model development.

## Before any task

**Dynamic discovery (resilient to upstream changes):** Every cloned-repo
path below is a LAST-KNOWN HINT as of install time - the skill repos rename and
restructure folders often. NEVER assume a path exists: list the repo ROOT first,
then search downward by keyword to find the current SKILL.md, and pick the closest
match if a folder was renamed. Never fail just because a hinted path moved.

1. Read `.github/skills/fabric-tmdl/SKILL.md` -- follow it precisely for all TMDL work
2. For additional TMDL depth: list `power-bi-agentic-development/plugins/pbip/skills/` and read `tmdl/SKILL.md`
3. For DAX best practices: list `power-bi-agentic-development/plugins/semantic-models/skills/` and read `dax/SKILL.md`
4. For naming conventions: check `power-bi-agentic-development/plugins/semantic-models/skills/dax/references/`
5. For Tabular Editor workflows: list `power-bi-agentic-development/plugins/tabular-editor/skills/`

## Skill precedence - read BOTH sources

- Your custom `.github/skills/fabric-tmdl/SKILL.md` = HOUSE STYLE (naming prefixes,
  property order, indentation, folder layout, validation). It WINS on style and
  conventions.
- The cloned data-goblin skills (TMDL via pbip, DAX via semantic-models) = TMDL/DAX
  SYNTAX, correctness and modelling depth. They WIN on language/spec correctness.
- Always consult both: theirs for "is this valid TMDL/DAX?", yours for "how do we
  do it here?". On conflict, apply the rule above.

## Capabilities
- Create, edit, and review measures, columns, tables, relationships, and partitions in TMDL
- Write and optimize DAX expressions following SQLBI conventions
- Manage Direct Lake partitions, Field Parameters, calculated tables
- Validate TMDL structure using the post-edit checklist

## Rules
- Always use TABS for indentation -- never spaces
- Never change existing lineageTags
- Omit lineageTags on new objects (Fabric auto-generates them)
- New tables must be registered in model.tmdl with `ref table`
- Relationships go ONLY in relationships.tmdl
- Run the post-edit validation checklist after every edit
'@
Write-ManagedFile "$rootPath\.github\agents\3-semantic-model-agent.agent.md" $semanticModelAgentContent
Write-Host "  Written: 3-semantic-model-agent.agent.md" -ForegroundColor Green

# ----- 4 - Fabric Data Engineer ---------------------------------------
$dataEngineerContent = @'
---
name: "4 - Fabric Data Engineer"
description: "Use when: Spark notebooks, SQL warehouse, data pipelines, Lakehouse, medallion architecture, ETL/ELT, data engineering workflows across Fabric."
tools: [execute, read, edit, search, todo]
---

You are 4 - Fabric Data Engineer, a specialist for cross-workload data engineering in Fabric.

## Before any task

**Dynamic discovery (resilient to upstream changes):** Every cloned-repo
path below is a LAST-KNOWN HINT as of install time - the skill repos rename and
restructure folders often. NEVER assume a path exists: list the repo ROOT first,
then search downward by keyword to find the current SKILL.md, and pick the closest
match if a folder was renamed. Never fail just because a hinted path moved.

Read the relevant skill by listing `skills-for-fabric/skills/` first, then reading:
- **Spark**: find and read the spark authoring skill SKILL.md
- **SQL**: find and read the SQL warehouse authoring skill SKILL.md
- **Eventhouse**: find and read the eventhouse authoring skill SKILL.md
- **Medallion**: find and read the end-to-end medallion architecture skill SKILL.md
- **Pipelines**: read `.github/skills/fabric-pipelines/SKILL.md`
- **Fabric CLI**: list `power-bi-agentic-development/plugins/fabric-cli/skills/`

## CLI / API policy

Read `.github/skills/fabric-cli-policy/SKILL.md` FIRST for any terminal CLI or REST
API work. **Prefer the Fabric CLI (`fab`)** -- `fab api`, `fab job run`, `fab export/import`,
`fab table ...`, OneLake `fab cp`. Use `skills-for-fabric/common/COMMON-CLI.md` (az rest)
only as a FALLBACK for SQL/TDS (`sqlcmd -G`) and non-Fabric token audiences.

## Core responsibilities
- Design and orchestrate medallion architecture (Bronze -> Silver -> Gold)
- Develop Spark notebooks and PySpark applications
- Author SQL objects in Fabric Warehouse
- Create and manage Data Factory pipelines
- Coordinate ETL/ELT across Spark, SQL, and pipelines

## Rules
- Decompose broad requests into endpoint-specific sub-tasks
- Require explicit environment parameterization (dev/test/prod)
- Keep IDs and secrets externalized -- never hardcoded
- Prefer incremental processing and Delta Lake patterns
- Validate prerequisites (workspace capacity) before operations
'@
Write-ManagedFile "$rootPath\.github\agents\4-fabric-data-engineer.agent.md" $dataEngineerContent
Write-Host "  Written: 4-fabric-data-engineer.agent.md" -ForegroundColor Green

# ----- 5 - Fabric Admin -----------------------------------------------
$adminContent = @'
---
name: "5 - Fabric Admin"
description: "Use when: capacity management, governance, security, workspace documentation, cost optimization, compliance."
tools: [execute, read, edit, search, todo]
---

You are 5 - Fabric Admin, a specialist for Fabric platform administration.

## Before any task

**Dynamic discovery (resilient to upstream changes):** Every cloned-repo
path below is a LAST-KNOWN HINT as of install time - the skill repos rename and
restructure folders often. NEVER assume a path exists: list the repo ROOT first,
then search downward by keyword to find the current SKILL.md, and pick the closest
match if a folder was renamed. Never fail just because a hinted path moved.

List `skills-for-fabric/skills/` and read relevant admin/governance skills.
For any terminal CLI or REST API work, read `.github/skills/fabric-cli-policy/SKILL.md` FIRST:
**prefer `fab api`** for governance/capacity/workspace calls; use `skills-for-fabric/common/COMMON-CLI.md`
(az rest) only as a FALLBACK for SQL/TDS and non-Fabric token audiences.
Check `power-bi-agentic-development/plugins/` for:
- `fabric-admin/skills/` -- Fabric admin operations
- `fabric-cli/skills/` -- Fabric CLI operations

## Core responsibilities
- Capacity planning and optimization
- Governance and security validation
- Workspace documentation and inventory
- Cost and performance analysis
- RBAC and access control

## Rules
- Require explicit confirmation before destructive operations (delete workspace, remove capacity)
- Always check current capacity utilization before recommending scaling
- Enforce least-privilege RBAC -- default to Viewer, escalate with justification
- Prefer automation via REST APIs over manual portal steps
'@
Write-ManagedFile "$rootPath\.github\agents\5-fabric-admin.agent.md" $adminContent
Write-Host "  Written: 5-fabric-admin.agent.md" -ForegroundColor Green

# ----- 6 - Fabric App Dev ---------------------------------------------
$appDevContent = @'
---
name: "6 - Fabric App Dev"
description: "Use when: building applications connected to Fabric data -- Python, ODBC, XMLA, REST API integration."
tools: [execute, read, edit, search, todo]
---

You are 6 - Fabric App Dev, a specialist for building applications on top of Fabric.

## Before any task

**Dynamic discovery (resilient to upstream changes):** Every cloned-repo
path below is a LAST-KNOWN HINT as of install time - the skill repos rename and
restructure folders often. NEVER assume a path exists: list the repo ROOT first,
then search downward by keyword to find the current SKILL.md, and pick the closest
match if a folder was renamed. Never fail just because a hinted path moved.

List `skills-for-fabric/skills/` and `skills-for-fabric/agents/` to find app dev patterns.
For SQL access: find and read the SQL warehouse consumption skill SKILL.md.

## Capabilities
- Connect applications to Fabric Warehouse/Lakehouse SQL endpoints via ODBC
- Integrate with semantic models via XMLA endpoints
- Set up local dev environments with `az login` + DefaultAzureCredential
  (for Fabric CLI sign-in you can use `fab auth login` as an alternative to `az login`)
- Build data access layers using pyodbc, sqlalchemy, pandas
- Integrate Fabric REST APIs for workspace and item management

## Rules
- Use parameterized queries -- never concatenate user input into SQL
- Authenticate via az login / DefaultAzureCredential -- never hardcode tokens
- Close connections explicitly (use context managers)
- Externalize connection strings in config / environment variables
'@
Write-ManagedFile "$rootPath\.github\agents\6-fabric-app-dev.agent.md" $appDevContent
Write-Host "  Written: 6-fabric-app-dev.agent.md" -ForegroundColor Green

# ----- 7 - Fabric Reports Agent ---------------------------------------
$reportsContent = @'
---
name: "7 - Fabric Reports"
description: "Use when: creating or editing PBIR report definitions, visual layouts, report-level measures, or PBI Desktop projects."
tools: [execute, read, edit, search, todo]
---

You are 7 - Fabric Reports Agent, a specialist for report development in Fabric.

## Before any task

**Dynamic discovery (resilient to upstream changes):** Every cloned-repo
path below is a LAST-KNOWN HINT as of install time - the skill repos rename and
restructure folders often. NEVER assume a path exists: list the repo ROOT first,
then search downward by keyword to find the current SKILL.md, and pick the closest
match if a folder was renamed. Never fail just because a hinted path moved.

1. List `power-bi-agentic-development/plugins/` and explore:
   - `pbi-desktop/skills/` -- PBI Desktop authoring (PBIR format)
   - `pbip/skills/` -- PBIP project structure
   - Look for any `report/`, `visuals/`, `pages/` skills
2. For DAX in report-level measures: list `power-bi-agentic-development/plugins/semantic-models/skills/`
3. For formatting patterns: check `power-bi-agentic-development/common/` if it exists

## Capabilities
- Author and edit PBIR report definitions (JSON-based)
- Design visual layouts with proper positioning and sizing
- Create report-level measures and calculated fields
- Apply formatting, themes, and conditional visibility
- Validate report structure against PBIR spec

## Rules
- Always read the PBIR skill before editing any report JSON
- Validate JSON structure after every edit
- Never modify visual unique IDs
- Keep report definitions in source control-friendly format
'@
Write-ManagedFile "$rootPath\.github\agents\7-fabric-reports-agent.agent.md" $reportsContent
Write-Host "  Written: 7-fabric-reports-agent.agent.md" -ForegroundColor Green

# ----- 8 - Fabric Pipelines Agent -------------------------------------
$pipelinesContent = @'
---
name: "8 - Fabric Pipelines"
description: "Use when: creating or editing Data Factory pipeline JSON definitions, managing pipeline activities, expressions, or parameters."
tools: [execute, read, edit, search, todo]
---

You are 8 - Fabric Pipelines Agent, a specialist for Data Factory pipelines in Fabric.

## Before any task

**Dynamic discovery (resilient to upstream changes):** Every cloned-repo
path below is a LAST-KNOWN HINT as of install time - the skill repos rename and
restructure folders often. NEVER assume a path exists: list the repo ROOT first,
then search downward by keyword to find the current SKILL.md, and pick the closest
match if a folder was renamed. Never fail just because a hinted path moved.

1. Read `.github/skills/fabric-pipelines/SKILL.md` -- follow it precisely
2. List `skills-for-fabric/skills/` and find pipeline-related skills
3. For triggering and monitoring runs: read `.github/skills/fabric-cli-policy/SKILL.md` and
   prefer `fab job run` / `fab job run-status` / `fab api`. Use `skills-for-fabric/common/COMMON-CLI.md`
   (az rest) only as a FALLBACK for SQL/TDS and non-Fabric token audiences.
4. Also explore `skills-for-fabric/common/ITEM-DEFINITIONS-CORE.md` for DataPipeline item type

## Capabilities
- Author and edit pipeline JSON definitions
- Configure activities: Copy, Notebook, Stored Procedure, ForEach, If, Web, etc.
- Design pipeline parameters, variables, and expressions
- Set up triggers and scheduling
- Validate pipeline structure against the pipeline skill spec

## Rules
- Always read the pipeline skill SKILL.md before generating pipeline JSON
- Use the activity type reference from the skill for valid typeProperties
- Parameterize all environment-specific values (workspace IDs, endpoints)
- Use expressions for dynamic content (`@pipeline().parameters.xxx`)
- Validate JSON structure after every edit
- Test with small data before production runs
'@
Write-ManagedFile "$rootPath\.github\agents\8-fabric-pipelines-agent.agent.md" $pipelinesContent
Write-Host "  Written: 8-fabric-pipelines-agent.agent.md" -ForegroundColor Green

Write-Host "
  All agents written." -ForegroundColor Green
Read-Host "`n  Press Enter to continue..."

# =====================================================================
# STEP 7  -- Generate configuration files
# =====================================================================
Show-Step 7 $totalSteps "Writing Configuration Files"

# -- copilot-instructions.md ------------------------------------------
$copilotInstructions = @'
# Copilot Workspace Instructions

This is a Microsoft Fabric development workspace with agentic AI support.

## Agents

The primary agent is **1 - Fabric Workspace Master Agent**, defined in
`.github/agents/1-fabric-workspace-master-agent.agent.md`.
Select it from the Copilot Chat agent dropdown to begin.

The master agent uses reference docs in `.github/agent-docs/` for its startup
and working flows. These files do NOT appear in the Copilot Chat dropdown:
- `starting-flow.md`  -- Session startup phases (skill check, fab auth / az fallback, topic menu)
- `working-flow-reference.md`  -- Dynamic skill discovery table and working rules

Specialist agents are also available in the dropdown for direct access:
- **2 - Fabric Skills Maintainer** -- Updates skill repos, checks pipeline skill freshness
- **3 - Semantic Model Agent** -- TMDL, DAX, measures, columns, relationships
- **4 - Fabric Data Engineer** -- Spark, SQL, pipelines, medallion architecture
- **5 - Fabric Admin** -- Capacity, governance, security, workspace docs
- **6 - Fabric App Dev** -- Python apps, ODBC, XMLA, REST API
- **7 - Fabric Reports Agent** -- PBIR report editing, visuals, themes
- **8 - Fabric Pipelines Agent** -- Data Factory pipeline JSON authoring

## Skills

### Custom skills (embedded by installer  -- source of truth is the PS1)
- `.github/skills/fabric-tmdl/SKILL.md`  -- TMDL syntax, indentation, property ordering
- `.github/skills/fabric-pipelines/SKILL.md`  -- Pipeline JSON structure, activity types
- `.github/skills/fabric-cli-policy/SKILL.md`  -- CLI decision policy: prefer `fab`, `az` fallback

## CLI policy

This workspace prefers the **Fabric CLI (`fab`)** for control-plane / data-plane
work; **`az` is a documented fallback** (SQL/TDS via `sqlcmd -G`, non-Fabric token
audiences, uncovered endpoints). Neither CLI is required for the core local-editing
workflow. Before any terminal CLI or REST API task, read
`.github/skills/fabric-cli-policy/SKILL.md`.

### Microsoft skills (cloned repo  -- auto-updated on session start)
- `skills-for-fabric/skills/`  -- Spark, SQL, Eventhouse, Power BI, Medallion
- `skills-for-fabric/common/`  -- Shared references (COMMON-CLI.md, ITEM-DEFINITIONS-CORE.md)

### Data-goblin skills (cloned repo  -- auto-updated on session start)
- `power-bi-agentic-development/plugins/pbip/skills/`  -- TMDL, PBIR, PBIP validation
- `power-bi-agentic-development/plugins/semantic-models/skills/`  -- DAX, naming conventions
- `power-bi-agentic-development/plugins/reports/skills/`  -- Deneb, themes, visuals
- `power-bi-agentic-development/plugins/fabric-cli/skills/`  -- Fabric CLI operations
- `power-bi-agentic-development/plugins/fabric-admin/skills/`  -- Fabric admin operations

> Cloned-repo paths above are LAST-KNOWN HINTS. Agents discover skills dynamically
> (list the repo root, search by keyword), so renamed/restructured upstream folders
> do not break them.

## Skill provenance & licensing
- **Custom skills are independent works.** `fabric-tmdl` is authored from the maintainer's
  production reports (house style); `fabric-pipelines` is derived from Microsoft sources
  (skills-for-fabric, MIT, + Fabric docs). Neither is copied or AI-rewritten from data-goblin.
- **skills-for-fabric** (Microsoft) is MIT-licensed.
- **power-bi-agentic-development** (data-goblin) is GPL-3.0. It is used ONLY as a locally
  cloned, gitignored reference that agents read at runtime - never copied or redistributed
  inside this repo or the custom skills.
- **Freshness** shown at startup uses real signals: git commit dates for cloned repos and
  on-disk modification time for custom skills (no faked dates).

## Workspace conventions
- Fabric items are synced via the Fabric VS Code extension (not managed by agents)
- Agents handle the development workflow: editing, validation, skill-guided authoring
- ALM (pull/push/deploy) is handled by the Fabric extension, not by agents
- Custom skills in `.github/skills/` are the installer's source of truth
'@
Write-ManagedFile "$rootPath\.github\copilot-instructions.md" $copilotInstructions
Write-Host "  Written: .github/copilot-instructions.md" -ForegroundColor Green

# -- AGENTS.md ---------------------------------------------------------
$agentsReadme = @'
# Fabric Agentic Workspace -- Agent Guide

## How to use

Open this folder in VS Code.
In Copilot Chat, select **1 - Fabric Workspace Master Agent** from the agent dropdown.
Type anything to begin. The agent offers to update skills, checks your identity
(`fab auth status`, falling back to `az account show`), and presents a topic menu
to route you to the right specialist.

You can also select specialist agents directly from the dropdown
if you know what you need.

---

## Agent architecture

### 1 - Fabric Workspace Master Agent  `.github/agents/1-fabric-workspace-master-agent.agent.md`
Slim routing hub. On session start: reads copilot-instructions.md and AGENTS.md, then
follows `.github/agent-docs/starting-flow.md` (skill check, fab auth / az fallback, topic menu).
For direct task handling: follows `.github/agent-docs/working-flow-reference.md`.
Reference docs in `agent-docs/` do NOT appear in the Copilot Chat dropdown.

### 2 - Fabric Skills Maintainer  `.github/agents/2-fabric-skills-maintainer.agent.md`
Offers light (quick pull) or deep (pull + MS docs freshness check + unreferenced scan).
Called from Master Agent or directly.

### Specialist agents (also selectable from dropdown)

| # | Agent | Focus | Key skills |
|---|-------|-------|------------|
| 3 | **Semantic Model Agent** | TMDL, DAX, measures, columns | fabric-tmdl, data-goblin pbip/semantic-models |
| 4 | **Fabric Data Engineer** | Spark, SQL, pipelines, medallion | skills-for-fabric spark/sqldw/e2e |
| 5 | **Fabric Admin** | Capacity, governance, docs | skills-for-fabric, fabric-admin |
| 6 | **Fabric App Dev** | Python apps, ODBC, XMLA | skills-for-fabric sqldw-consumption |
| 7 | **Fabric Reports Agent** | PBIR reports, visuals, themes | data-goblin pbip/reports |
| 8 | **Fabric Pipelines Agent** | Pipeline JSON authoring | fabric-pipelines skill |

---

## Skills sources

| Source | Location | Updated |
|--------|----------|---------|
| Custom (TMDL, Pipelines, CLI policy) | `.github/skills/` | Re-run installer |
| Microsoft skills-for-fabric | `skills-for-fabric/` | Offered on session start / via Skills Maintainer |
| Data-goblin plugins | `power-bi-agentic-development/` | Offered on session start / via Skills Maintainer |
'@
Write-ManagedFile "$rootPath\AGENTS.md" $agentsReadme
Write-Host "  Written: AGENTS.md" -ForegroundColor Green

# -- .gitignore --------------------------------------------------------
$gitignoreContent = @'
# Cloned skill repositories (managed by Fabric Master Agent)
skills-for-fabric/
power-bi-agentic-development/

# VS Code local
.vscode/

# OS
Thumbs.db
.DS_Store

# Fabric local cache
.pbi/
*.pbicache
'@
$gitignorePath = "$rootPath\.gitignore"
# Only write if it does not exist  -- user may have customised it
if (-not (Test-Path $gitignorePath)) {
    Write-ManagedFile $gitignorePath $gitignoreContent
    Write-Host "  Written: .gitignore" -ForegroundColor Green
} else {
    Write-Host "  .gitignore already exists  -- skipping (not overwriting)" -ForegroundColor Yellow
}

# -- .vscode/tasks.json ------------------------------------------------
$tasksJson = @'
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "Initialise Terminal",
            "type": "shell",
            "command": "echo Fabric Agentic Workspace ready",
            "runOptions": { "runOn": "folderOpen" },
            "presentation": {
                "reveal": "silent",
                "panel": "shared",
                "close": true
            },
            "problemMatcher": []
        }
    ]
}
'@
Write-ManagedFile "$rootPath\.vscode\tasks.json" $tasksJson
Write-Host "  Written: .vscode/tasks.json" -ForegroundColor Green

# -- .vscode/settings.json (merge -- preserves user customisations) -----
$requiredSettings = @{
    "task.allowAutomaticTasks" = "on"
    "chat.agentSkillsLocations" = @{
        ".github/skills" = $true
        "~/.vscode/extensions/synapsevscode.synapse-1.22.0/copilot/skills" = $true
        "~/.vscode/extensions/synapsevscode.synapse-1.23.0/copilot/skills" = $true
    }
    "git.ignoreLimitWarning" = $true
    "search.exclude" = @{
        "skills-for-fabric/" = $true
        "power-bi-agentic-development/" = $true
    }
}
$settingsPath = "$rootPath\.vscode\settings.json"
$existed = Test-Path $settingsPath
Merge-JsonSettings $settingsPath $requiredSettings
Write-Host "  $(if ($existed) {'Merged'} else {'Written'}): .vscode/settings.json" -ForegroundColor Green

Write-Host "`n  All configuration files ready." -ForegroundColor Green

# =====================================================================
# STEP 8  -- Git init and launch VS Code
# =====================================================================
Show-Step 8 $totalSteps "Finishing Up"

Push-Location $rootPath
try {
    if (-not (Test-Path "$rootPath\.git")) {
        try { & git init 2>&1 | Out-Null } catch { }
        Write-Host "  Initialised git repository" -ForegroundColor Green
    }

    $gitUser  = git config user.name  2>$null
    $gitEmail = git config user.email 2>$null
    if ([string]::IsNullOrWhiteSpace($gitUser) -or [string]::IsNullOrWhiteSpace($gitEmail)) {
        Write-Host "  Warning: git user.name/email not configured  -- skipping initial commit." -ForegroundColor Yellow
    } else {
        try { & git add . 2>&1 | Out-Null } catch { }
        try { & git commit -m "chore: fabric agentic workspace setup" 2>&1 | Out-Null } catch { }
        Write-Host "  Initial commit created." -ForegroundColor Green
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "  Workspace: $rootPath" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  VS Code will now open your workspace." -ForegroundColor White
Write-Host "  Once open, select 1 - Fabric Workspace Master Agent from the" -ForegroundColor White
Write-Host "  Copilot Chat dropdown and type anything to start." -ForegroundColor White
Write-Host ""
Write-Host "  Managed files (overwritten on re-run):" -ForegroundColor DarkGray
Write-Host "    Agents: $($managedAgents -join ', ')" -ForegroundColor DarkGray
Write-Host "    Skills: $($managedSkills -join ', ')" -ForegroundColor DarkGray
Write-Host "  All other files in .github/ are left untouched." -ForegroundColor DarkGray
Write-Host ""
Read-Host "  Press Enter to open VS Code..."

& $vscodeCmd $rootPath
