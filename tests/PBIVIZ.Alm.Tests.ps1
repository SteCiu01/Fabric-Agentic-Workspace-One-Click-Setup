# PBIVIZ.Alm.Tests.ps1
# -------------------------------------------------------------------
# Executable regression tests for the deterministic PBIVIZ repository helper
# (.github/agent-docs/Pbiviz-Alm.ps1), loaded from its single source: the
# $pbivizAlmScript heredoc inside the installer. Every scenario runs against
# throwaway local repositories and `git init --bare` remotes under TEMP:
# no network, no real remote, no user repository. The developer's global and
# system Git configuration is hidden for the duration.
#
# Covers plan v0.8.0 rev 3: defects 1-3 (remote adoption, release archive,
# post-merge provenance), safeguards S1-S4, input validation (G0) and the
# release archive rules (append-only pairs, legacy archive, monotonic versions).

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $raw = [IO.File]::ReadAllText((Get-InstallerPath))
    $m = [regex]::Match($raw, "(?s)\`$pbivizAlmScript = @'\r?\n(.*?)\r?\n'@")
    $m.Success | Should -BeTrue -Because 'the installer must carry the helper as a single-source heredoc'
    $script:HelperText = $m.Groups[1].Value

    $script:Root = Join-Path ([IO.Path]::GetTempPath()) ('pbz' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Root | Out-Null
    $script:HelperFile = Join-Path $script:Root 'Pbiviz-Alm.ps1'
    [IO.File]::WriteAllText($script:HelperFile, $script:HelperText, (New-Object System.Text.UTF8Encoding($false)))
    . $script:HelperFile

    $script:SavedEnv = @{}
    foreach ($n in 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM',
                   'GIT_LITERAL_PATHSPECS', 'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS', 'GIT_ICASE_PATHSPECS', 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer') {
        $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process')
    }
    $env:GIT_AUTHOR_NAME = 'test'; $env:GIT_AUTHOR_EMAIL = 't@example.invalid'
    $env:GIT_COMMITTER_NAME = 'test'; $env:GIT_COMMITTER_EMAIL = 't@example.invalid'
    $script:EmptyGitConfig = Join-Path $script:Root 'empty.gitconfig'
    [IO.File]::WriteAllText($script:EmptyGitConfig, '')
    $env:GIT_CONFIG_GLOBAL = $script:EmptyGitConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'
    foreach ($n in 'GIT_LITERAL_PATHSPECS', 'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS', 'GIT_ICASE_PATHSPECS', 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer') { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:Counter = 0
    $script:TempBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'pbiviz-release-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

    function TGit {
        param([string]$Dir, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
        $o = & git -C $Dir @Rest 2>$null
        if ($LASTEXITCODE -ne 0) { throw "git $($Rest -join ' ') failed in $Dir (exit $LASTEXITCODE)" }
        return ((@($o) | ForEach-Object { "$_" }) -join "`n").Trim()
    }
    function TGitExit {
        param([string]$Dir, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
        & git -C $Dir @Rest 2>$null | Out-Null
        return $LASTEXITCODE
    }
    function New-TDir {
        param([string]$Prefix = 'r')
        $script:Counter++
        $d = Join-Path $script:Root ("$Prefix$($script:Counter)")
        New-Item -ItemType Directory -Path $d | Out-Null
        return $d
    }
    function Write-TFile {
        param([string]$Repo, [string]$Rel, [string]$Text)
        $full = Join-Path $Repo ($Rel -replace '/', '\')
        $dir = Split-Path $full -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($full, $Text, $script:Utf8)
    }
    function Write-TBytes {
        param([string]$Path, [int]$Seed = 1, [int]$Size = 4096)
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $b = New-Object byte[] $Size
        (New-Object System.Random $Seed).NextBytes($b)
        $b[0] = 0x50; $b[1] = 0x4B; $b[2] = 0; $b[3] = 0
        [IO.File]::WriteAllBytes($Path, $b)
    }
    # A real .pbiviz layout (powerbi-visuals-webpack-plugin): package.json + resources/<guid>.pbiviz.json.
    # -ResourceGuid/-ResourceVersion make the two files disagree; -NoPackageJson drops package.json.
    function Write-TPackage {
        param([string]$Path, [string]$Guid, [string]$Version, [int]$Seed = 1, [string]$ResourceGuid = $null, [string]$ResourceVersion = $null, [switch]$NoPackageJson)
        if (-not ('System.IO.Compression.ZipArchive' -as [type])) { Add-Type -AssemblyName System.IO.Compression }
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $rg = if ($ResourceGuid) { $ResourceGuid } else { $Guid }
        $rv = if ($ResourceVersion) { $ResourceVersion } else { $Version }
        $rnd = New-Object byte[] 256
        (New-Object System.Random $Seed).NextBytes($rnd)
        $js = [BitConverter]::ToString($rnd).Replace('-', '')
        $items = [ordered]@{}
        if (-not $NoPackageJson) {
            $items['package.json'] = "{`n`t""version"": ""$Version"",`n`t""author"": { ""name"": ""t"", ""email"": ""t@example.invalid"" },`n`t""resources"": [ { ""resourceId"": ""rId0"", ""sourceType"": 5, ""file"": ""resources/$Guid.pbiviz.json"" } ],`n`t""visual"": { ""name"": ""v"", ""guid"": ""$Guid"", ""version"": ""$Version"" },`n`t""metadata"": { ""pbivizjson"": { ""resourceId"": ""rId0"" } }`n}"
        }
        $items["resources/$Guid.pbiviz.json"] = '{"visual":{"name":"v","guid":"' + $rg + '","version":"' + $rv + '"},"apiVersion":"5.11.0","content":{"js":"' + $js + '","css":""}}'
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Create)
        try {
            $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($k in $items.Keys) {
                    $s = $zip.CreateEntry($k).Open()
                    try { $bytes = $script:Utf8.GetBytes($items[$k]); $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
                }
            } finally { $zip.Dispose() }
        } finally { $fs.Dispose() }
    }
    # Deny folder listing to the current user (an "inaccessible directory"); undone by Clear-TDeny.
    function Set-TDenyList {
        param([string]$Path)
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, [System.Security.AccessControl.FileSystemRights]::ListDirectory, [System.Security.AccessControl.AccessControlType]::Deny)
        $acl = Get-Acl -LiteralPath $Path
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
        return $rule
    }
    function Clear-TDeny {
        param([string]$Path, $Rule)
        $acl = Get-Acl -LiteralPath $Path
        [void]$acl.RemoveAccessRule($Rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    function New-TVisual {
        param([string]$Repo, [string]$Name, [string]$Guid, [string]$Version, [string]$Code = 'export class Visual {}')
        Write-TFile $Repo "$Name/pbiviz.json" ("{`n  ""visual"": { ""name"": ""$Name"", ""guid"": ""$Guid"", ""version"": ""$Version"" },`n  ""apiVersion"": ""5.11.0""`n}`n")
        Write-TFile $Repo "$Name/capabilities.json" "{ ""dataRoles"": [] }`n"
        Write-TFile $Repo "$Name/src/visual.ts" "$Code`n"
    }
    function Set-TVersion {
        param([string]$Repo, [string]$Name, [string]$Guid, [string]$Version)
        Write-TFile $Repo "$Name/pbiviz.json" ("{`n  ""visual"": { ""name"": ""$Name"", ""guid"": ""$Guid"", ""version"": ""$Version"" },`n  ""apiVersion"": ""5.11.0""`n}`n")
    }
    function Save-TAll {
        param([string]$Repo, [string]$Message)
        TGit $Repo add -A | Out-Null
        TGit $Repo commit -q -m $Message | Out-Null
        return (TGit $Repo rev-parse HEAD)
    }
    function New-TRepo {
        $d = New-TDir 'r'
        TGit $d init -q -b main | Out-Null
        [IO.File]::WriteAllText((Join-Path $d '.gitignore'), (($script:PbivizGitignoreLines -join "`n") + "`n"), $script:Utf8)
        [IO.File]::WriteAllText((Join-Path $d '.gitattributes'), (($script:PbivizGitattributesLines -join "`n") + "`n"), $script:Utf8)
        return $d
    }
    function New-TReleasePair {
        param([string]$Repo, [string]$Visual, [string]$Guid, [string]$Version, [string]$Origin = 'release', [int]$Seed = 7, [string]$Sub = '', [switch]$Validated)
        $dir = if ($Sub) { "$Visual/releases/$Sub" } else { "$Visual/releases" }
        $pkg = Join-Path $Repo (($dir -replace '/', '\') + "\$Guid.$Version.pbiviz")
        Write-TPackage -Path $pkg -Guid $Guid -Version $Version -Seed $Seed
        $bytes = [IO.File]::ReadAllBytes($pkg)
        $pk = Get-PbivizPackageIdentity -Bytes $bytes
        $sha = Get-PbivizSha256Hex $bytes
        # Evidence-consistent fixture: without -Validated there is no test, review, build or toolchain
        # evidence, so validated:false; with it, every claim matches the bytes and the source commit.
        $man = [ordered]@{ schemaVersion = 1; visual = $Visual; guid = $Guid; version = $Version; origin = $Origin; validated = $false }
        if ($Origin -eq 'release') {
            $src = TGit $Repo rev-parse HEAD
            $fp = Get-PbivizSourceFingerprint -Root $Repo -TreeIsh $src -Visual $Visual
            $tests = [ordered]@{ lint = 'NOT RUN'; unit = 'NOT RUN'; host = 'NOT RUN'; certification = 'NOT RUN' }
            $review = $null; $build = $null; $tv = $null; $nv = $null
            if ($Validated) {
                $tests.lint = 'PASS'; $tests.unit = 'PASS'; $tv = '7.2.2'; $nv = 'v24.2.0'
                $review = [ordered]@{ reviewer = '084 PBIVIZ Reviewer'; verdict = 'APPROVE'; sourceSha = $src; reviewedAt = ''; reference = 'fixture' }
                $build = [ordered]@{ evidence = 'helper build record'; visual = $Visual; sourceSha = $src; sourceFingerprint = $fp; location = 'checkout'; command = $script:PbivizBuildCommand
                    toolsVersion = $tv; nodeVersion = $nv; exitCode = 0; startedAt = ''; finishedAt = ''; logSha256 = ('0' * 64)
                    package = [ordered]@{ file = "$Guid.$Version.pbiviz"; sha256 = $sha; bytes = $bytes.Length; guid = $pk.Guid; version = $pk.Version; resource = $pk.Resource; entries = $pk.Entries } }
            }
            $v = Get-PbivizValidationVerdict -Tests $tests -Review $review -SourceSha $src -ToolsVersion $tv -NodeVersion $nv -PackageVerified $true -BuildVerified ([bool]$Validated)
            $man.validated = $v.Validated; $man.validationGaps = @($v.Gaps); $man.quality = $v.Quality
            $man.sourceSha = $src; $man.sourceFingerprint = $fp; $man.sharedFiles = @()
            $man.packageSource = 'build output'; $man.externalApproval = $null; $man.build = $build; $man.toolsVersion = $tv; $man.nodeVersion = $nv
            $man.tests = $tests; $man.review = $review; $man.level = 'local'
        } else { $man.sourceSha = $null; $man.sourceFingerprint = $null }
        $man.packageFile = "$Guid.$Version.pbiviz"; $man.sha256 = $sha; $man.bytes = $bytes.Length
        $man.package = [ordered]@{ identity = 'VERIFIED'; guid = $pk.Guid; version = $pk.Version; resource = $pk.Resource; entries = $pk.Entries }
        Write-TFile $Repo "$dir/$Guid.$Version.release.json" (ConvertTo-PbivizJson $man)
    }
    # A stand-in for the visual's project-local powerbi-visuals-tools: `pbiviz.js package` copies a
    # prepared .pbiviz (identity from the current pbiviz.json) to dist/. fake-mode.txt selects
    # ok | fail (exit 1) | touch (rewrites a tracked file) | none (exit 0, no package) | hang (never ends)
    # | spawn-hang / spawn-exit (starts a DETACHED node child that inherits stdout/stderr and writes the
    # package plus late-write.txt after 6 s; the CLI then hangs or exits 0 at once; child.pid names it)
    # | probe / sdk-cert (writes probe.json: what the SDK would see - home, PATH, PATHEXT, npm settings,
    # the placeholder certificate per config.json; sdk-cert also prints the SDK's verification error when
    # the placeholder is missing) | pwsh (runs `pwsh -Command ...` through cmd.exe like the SDK's
    # certificate generation) | spawn-pwsh (shell-less spawn of pwsh, result in spawn.txt) | install-api
    # (prints the SDK's "Installing API" line). Every probe mode then packages like ok.
    $script:FakePbivizJs = @'
const fs = require('fs'), path = require('path'), os = require('os'), cp = require('child_process');
const here = path.join(__dirname, '..');
const modeFile = path.join(here, 'fake-mode.txt');
const mode = fs.existsSync(modeFile) ? fs.readFileSync(modeFile, 'utf8').trim() : 'ok';
if (process.argv[2] !== 'package') { console.error('fake pbiviz: only package'); process.exit(2); }
if (mode === 'hang') { setTimeout(() => process.exit(0), 600000); return; }
if (mode === 'spawn-hang' || mode === 'spawn-exit') {
  const cfg0 = JSON.parse(fs.readFileSync('pbiviz.json', 'utf8'));
  const late = path.resolve('dist', cfg0.visual.guid + '.' + cfg0.visual.version + '.pbiviz');
  const code = "const fs = require('fs'), path = require('path'); setTimeout(() => { fs.mkdirSync(path.dirname(process.argv[1]), { recursive: true }); fs.copyFileSync(process.argv[2], process.argv[1]); fs.writeFileSync(process.argv[3], 'late'); console.log('late write'); }, 6000);";
  const child = require('child_process').spawn(process.execPath, ['-e', code, late, path.join(here, 'fixture.pbiviz'), path.join(here, 'late-write.txt')], { detached: true, stdio: 'inherit' });
  fs.writeFileSync(path.join(here, 'child.pid'), String(child.pid));
  console.log('fake pbiviz: detached child ' + child.pid + ' inherits stdout/stderr');
  if (mode === 'spawn-exit') { process.exit(0); }
  setTimeout(() => process.exit(0), 600000); return;
}
if (mode === 'probe' || mode === 'sdk-cert') {
  let sc = {}; try { sc = JSON.parse(fs.readFileSync(path.join(here, 'config.json'), 'utf8')).server || {}; } catch (e) { }
  const folder = path.join(os.homedir(), sc.certificateFolder || 'pbiviz-certs');
  const first = (process.env.PATH || '').split(';')[0];
  const g = path.join(first, 'pwsh.cmd');
  const probe = { homedir: os.homedir(), USERPROFILE: process.env.USERPROFILE, HOME: process.env.HOME, TEMP: process.env.TEMP, TMP: process.env.TMP,
    PATHEXT: process.env.PATHEXT, NoDefault: process.env.NoDefaultCurrentDirectoryInExePath, pathFirst: first, path: process.env.PATH,
    guard: fs.existsSync(g) ? fs.readFileSync(g, 'utf8') : null, npmCache: process.env.npm_config_cache, npmOffline: process.env.npm_config_offline,
    npmNotifier: process.env.npm_config_update_notifier, npmUserconfig: process.env.npm_config_userconfig,
    pfxExists: fs.existsSync(path.join(folder, sc.pfx || 'PowerBICustomVisualTest_public.pfx')),
    passExists: fs.existsSync(path.join(folder, sc.passphrase || 'PowerBICustomVisualTestPass.txt')) };
  fs.writeFileSync(path.join(here, 'probe.json'), JSON.stringify(probe));
  if (mode === 'sdk-cert' && !(probe.pfxExists && probe.passExists)) { console.log('Certificate verification error: Error: PFX or passphrase file not found'); }
}
if (mode === 'pwsh') { try { cp.execSync('pwsh -Command "New-SelfSignedCertificate"', { stdio: 'pipe' }); console.log('pwsh ran'); } catch (e) { console.log('pwsh failed ' + e.status); } }
if (mode === 'spawn-pwsh') { const r = cp.spawnSync('pwsh', ['-NoProfile'], { encoding: 'utf8', timeout: 20000 }); fs.writeFileSync(path.join(here, 'spawn.txt'), r.error ? r.error.code : ('ran ' + r.status + ' ' + (r.stdout || '').trim())); }
if (mode === 'install-api') { console.log('Installing API: ~5.11.0...'); }
if (mode === 'fail') { console.error('error: fake build failure'); process.exit(1); }
const cfg = JSON.parse(fs.readFileSync('pbiviz.json', 'utf8'));
if (mode === 'touch') { fs.writeFileSync(path.join('src', 'visual.ts'), 'rewritten by the build\n'); }
if (mode !== 'none') {
  fs.mkdirSync('dist', { recursive: true });
  fs.copyFileSync(path.join(here, 'fixture.pbiviz'), path.join('dist', cfg.visual.guid + '.' + cfg.visual.version + '.pbiviz'));
}
console.log('fake pbiviz package done');
'@
    function Install-TFakeTools {
        param([string]$Dir, [string]$Visual = 'Bar', [string]$Mode = 'ok', [int]$Seed = 11, [string]$ToolsVersion = '7.2.2', [string]$ApiVersion = '5.11.0', [hashtable]$CertConfig = $null)
        $tools = "$Visual/node_modules/powerbi-visuals-tools"
        Write-TFile $Dir "$tools/package.json" "{ ""name"": ""powerbi-visuals-tools"", ""version"": ""$ToolsVersion"" }"
        Write-TFile $Dir "$tools/bin/pbiviz.js" $script:FakePbivizJs
        Write-TFile $Dir "$tools/fake-mode.txt" $Mode
        # The API package the SDK checks before every package (absent with -ApiVersion '').
        if ($ApiVersion) { Write-TFile $Dir "$Visual/node_modules/powerbi-visuals-api/package.json" "{ ""name"": ""powerbi-visuals-api"", ""version"": ""$ApiVersion"" }" }
        if ($CertConfig) { Write-TFile $Dir "$tools/config.json" (ConvertTo-Json @{ server = $CertConfig } -Compress) }
        $pj = [IO.File]::ReadAllText((Join-Path $Dir "$Visual\pbiviz.json")) | ConvertFrom-Json
        Write-TPackage -Path (Join-Path $Dir (($tools -replace '/', '\') + '\fixture.pbiviz')) -Guid $pj.visual.guid -Version $pj.visual.version -Seed $Seed
    }
    function Invoke-TBuild {
        param([string]$Dir, [string]$Visual = 'Bar', [switch]$Worktree, [string]$Mode = 'ok', [int]$Seed = 11)
        Install-TFakeTools -Dir $Dir -Visual $Visual -Mode $Mode -Seed $Seed
        if ($Worktree) { return (Invoke-PbivizBuild -Worktree $Dir -Visual $Visual) }
        return (Invoke-PbivizBuild -Root $Dir -Visual $Visual)
    }
    # Complete release evidence for a source commit: 083's lint/unit results and 084's approving review.
    function Get-TEvidence {
        param([string]$Sha, [string]$Visual = 'Bar', [string]$Unit = 'PASS', [switch]$NoReview)
        $ev = @{ Tests = @{ lint = 'PASS'; unit = $Unit } }
        if (-not $NoReview) { $ev.Review = @{ reviewer = '084 PBIVIZ Reviewer'; verdict = 'APPROVE'; sourceSha = $Sha; visual = $Visual; reference = 'REVIEW VERDICT' } }
        return $ev
    }
    # Level 3 fixture: Bar and Column on main; Prod and Dev branch from it; checkout on Dev.
    function New-TL3 {
        param([scriptblock]$OnProd = $null)
        $r = New-TRepo
        New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
        New-TVisual $r 'Column' 'colGuid0001' '2.0.0.1'
        Save-TAll $r 'base' | Out-Null
        TGit $r branch PBVIZ_Team_Prod | Out-Null
        if ($OnProd) {
            TGit $r switch -q PBVIZ_Team_Prod | Out-Null
            & $OnProd $r
            Save-TAll $r 'prod-only change' | Out-Null
            TGit $r switch -q main | Out-Null
        }
        TGit $r switch -q -c PBVIZ_Team_Dev | Out-Null
        return $r
    }
    # Level 3 release with complete evidence: the build runs inside the candidate worktree with the
    # (fake) project-local CLI, then the pair is staged with 083's results and 084's review.
    function Invoke-TPromotion {
        param([string]$Repo, [string]$Visual = 'Bar', [string[]]$Allowlist = @(), [switch]$SkipRelease, [int]$Seed = 11)
        $cand = New-PbivizPromotionCandidate -Root $Repo -Visual $Visual -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod -Allowlist $Allowlist
        $out = [pscustomobject]@{ Candidate = $cand; Build = $null; Release = $null; Gates = $null }
        if ($cand.Status -ne 'PASS') { return $out }
        $out.Build = Invoke-TBuild -Dir $cand.Worktree -Visual $Visual -Worktree -Seed $Seed
        if (-not $SkipRelease) { $ev = Get-TEvidence -Sha $cand.Source -Visual $Visual; $out.Release = Add-PbivizRelease -Worktree $cand.Worktree -Visual $Visual -SourceSha $cand.Source @ev }
        $out.Gates = Test-PbivizPromotionGates -Worktree $cand.Worktree -Visual $Visual -TargetRef PBVIZ_Team_Prod -Allowlist $Allowlist
        return $out
    }
    function Get-TGate { param($Gates, [string]$Id) return @($Gates.Gates | Where-Object { $_.Gate -eq $Id })[0] }
    function Get-TRefs { param([string]$Repo) return (Get-PbivizRefSnapshot -Root $Repo) }
    function Get-TState { param([string]$Repo) return (Get-PbivizWorkingStateDigest -Root $Repo) }
    function Get-TReleaseDirs { return @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'pbiviz-release-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
    function New-TBare {
        $d = New-TDir 'b'
        TGit $d init -q --bare -b main | Out-Null
        return $d
    }
    # Writes NUL-separated records to `git mktree -z` stdin (names may contain tab/newline).
    function New-TTreeRaw {
        param([string]$Repo, [string[]]$Records)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $psi.Arguments = 'mktree -z'
        $psi.WorkingDirectory = $Repo
        $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $bytes = $script:Utf8.GetBytes((($Records | ForEach-Object { $_ + [char]0 }) -join ''))
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
        return $out.Trim()
    }
}

AfterAll {
    # Requirement 18: no test touched a real remote. Every configured remote URL is a temp path.
    foreach ($cfg in @(Get-ChildItem -LiteralPath $script:Root -Recurse -Force -Filter 'config' -File -ErrorAction SilentlyContinue)) {
        $text = [IO.File]::ReadAllText($cfg.FullName)
        foreach ($mm in [regex]::Matches($text, '(?m)^\s*url\s*=\s*(.+)$')) {
            # git config escapes backslashes (C:\\Users\\...) and may quote the value.
            $u = $mm.Groups[1].Value.Trim().Trim('"').Replace('\\', '\')
            if (-not ($u.Replace('/', '\').StartsWith($script:Root, [StringComparison]::OrdinalIgnoreCase) -or $u -like "file://*$((Split-Path $script:Root -Leaf))*")) {
                throw "isolation guard: a test configured a non-temp remote: $u"
            }
        }
    }
    foreach ($d in @(Get-TReleaseDirs | Where-Object { $script:TempBefore -notcontains $_ })) {
        $full = Join-Path ([IO.Path]::GetTempPath()) $d
        & cmd.exe /c "rmdir /s /q `"\\?\$full`"" 2>$null | Out-Null
    }
    foreach ($k in $script:SavedEnv.Keys) {
        if ($null -eq $script:SavedEnv[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } else { Set-Item "Env:$k" $script:SavedEnv[$k] }
    }
    if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
        & cmd.exe /c "rmdir /s /q `"\\?\$($script:Root)`"" 2>$null | Out-Null
    }
}

Describe 'Binary-safe git invocation (S2)' {

    It 'passes arguments with spaces, quotes and trailing backslashes to git unchanged' {
        $r = New-TRepo
        $argsIn = @('plain', 'with space', 'quote"inside', 'trail\', 'C:\Users\a b\x.lst', '')
        $res = Invoke-PbivizGit -WorkingDirectory $r -Arguments (@('rev-parse', '--sq-quote') + $argsIn)
        $res.ExitCode | Should -Be 0
        $res.Out.Trim() | Should -Be ("'plain' 'with space' 'quote`"inside' 'trail\' 'C:\Users\a b\x.lst' ''")
    }

    It 'forces literal pathspecs in the child even when the parent sets GIT_GLOB_PATHSPECS' {
        $r = New-TRepo
        Write-TFile $r 'a.txt' 'a'
        Save-TAll $r 'a' | Out-Null
        $env:GIT_GLOB_PATHSPECS = '1'
        try {
            $hit = Invoke-PbivizGit -WorkingDirectory $r -Arguments @('ls-files', '-z', '--', '*.txt')
        } finally { Remove-Item Env:GIT_GLOB_PATHSPECS -ErrorAction SilentlyContinue }
        $hit.ExitCode | Should -Be 0
        $hit.Out | Should -BeNullOrEmpty -Because 'a wildcard must never match under the helper'
    }

    It 'writes pathspec files as UTF-8 without BOM, NUL-terminated, and they round-trip' {
        $names = @('with space.ts', ('caf' + [char]0xE9 + '.ts'), ([string][char]0x65E5 + [char]0x672C + '.ts'), ('emoji-' + [char]::ConvertFromUtf32(0x1F600) + '.ts'))
        $f = Write-PbivizPathspecFile -Paths $names -Directory $script:Root
        $bytes = [IO.File]::ReadAllBytes($f)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        $bytes[$bytes.Length - 1] | Should -Be 0
        $back = @(Split-PbivizNul ($script:Utf8.GetString($bytes)))
        ($back -join '|') | Should -Be ($names -join '|')
    }

    It 'returns Unicode paths byte-exact through the .NET process' {
        $r = New-TRepo
        TGit $r config core.quotePath true | Out-Null
        $names = @('with space.ts', ('u' + [char]0xFC + 'n' + [char]0xEF + 'c' + [char]0xF8 + 'de.ts'), ([string][char]0x65E5 + [char]0x672C + [char]0x8A9E + '.ts'), ('emoji-' + [char]::ConvertFromUtf32(0x1F600) + '.ts'), ('caf' + [char]0xE9 + '.ts'), ('cafe' + [char]0x301 + '.ts'))
        foreach ($n in $names) { Write-TFile $r "V/$n" $n }
        Save-TAll $r 'unicode' | Out-Null
        $paths = @(Get-PbivizTreePaths -Root $r -TreeIsh HEAD)
        foreach ($n in $names) { $paths | Should -Contain "V/$n" }
        @($paths | Where-Object { $_.StartsWith('V/') }).Count | Should -Be $names.Count -Because 'NFC and NFD names stay distinct'
    }

    It 'fails closed on a malformed or unexpected staged diff' {
        Mock Invoke-PbivizGit { [pscustomobject]@{ ExitCode = 0; Out = "X`0a.txt`0"; Err = ''; Bytes = $null; TimedOut = $false } } -ParameterFilter { $Arguments[0] -eq 'diff-index' }
        $a = Get-PbivizStagedChanges -Directory $script:Root -Base 'deadbeef'
        $a.Ok | Should -BeFalse
        $a.Reason | Should -Match 'unexpected diff status'
        Mock Invoke-PbivizGit { [pscustomobject]@{ ExitCode = 0; Out = "A`0"; Err = ''; Bytes = $null; TimedOut = $false } } -ParameterFilter { $Arguments[0] -eq 'diff-index' }
        (Get-PbivizStagedChanges -Directory $script:Root -Base 'deadbeef').Reason | Should -Match 'odd field count'
        Mock Invoke-PbivizGit { [pscustomobject]@{ ExitCode = 128; Out = ''; Err = 'fatal: bad object'; Bytes = $null; TimedOut = $false } } -ParameterFilter { $Arguments[0] -eq 'diff-index' }
        (Get-PbivizStagedChanges -Directory $script:Root -Base 'deadbeef').Ok | Should -BeFalse
    }
}

Describe 'Repository state and levels (#9, #12)' {

    It 'derives Level 1 for a local repository and Level 3 once the PBVIZ_Team branches exist, without moving any ref' {
        $r = New-TRepo
        New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
        Save-TAll $r 'base' | Out-Null
        $s1 = Get-PbivizRepoState -Root $r
        $s1.isRepoRoot | Should -BeTrue
        $s1.derivedLevel | Should -Be 1
        $s1.remotes.Count | Should -Be 0 -Because 'Level 1 needs no remote'
        $before = Get-TRefs $r
        TGit $r branch PBVIZ_Team_Dev | Out-Null
        TGit $r branch PBVIZ_Team_Prod | Out-Null
        (Assert-PbivizNoCommitLoss -Root $r -Before $before -After (Get-TRefs $r)).Status | Should -Be 'PASS'
        (Get-PbivizRepoState -Root $r).derivedLevel | Should -Be 3
    }

    It 'never treats a folder inside another repository as a repository root' {
        $outer = New-TRepo
        New-Item -ItemType Directory -Path (Join-Path $outer 'inner') | Out-Null
        Test-PbivizIsRepoRoot (Join-Path $outer 'inner') | Should -BeFalse
        (Get-PbivizRepoState -Root (Join-Path $outer 'inner')).isRepoRoot | Should -BeFalse
    }
}

Describe 'Unsafe inputs are rejected before Git runs (G0)' {

    BeforeAll {
        $script:G0Repo = New-TL3
        New-TVisual $script:G0Repo 'ibcsColumnChart' 'icolGuid01' '1.0.0.0'
        Save-TAll $script:G0Repo 'more' | Out-Null
    }

    It 'rejects <Name> and leaves HEAD, index, refs, worktrees and the filesystem unchanged' -TestCases @(
        @{ Name = '..' }, @{ Name = 'a/b' }, @{ Name = 'C:\x' }, @{ Name = '\\srv\x' }, @{ Name = ':(glob)*' },
        @{ Name = '*' }, @{ Name = '-rf' }, @{ Name = 'CON' }, @{ Name = 'con.txt' }, @{ Name = 'name.' },
        @{ Name = '.git' }, @{ Name = 'releases' }, @{ Name = 'bar' }, @{ Name = 'Missing' }, @{ Name = '' }
    ) {
        $r = $script:G0Repo
        $refs = Get-TRefs $r; $state = Get-TState $r; $dirs = Get-TReleaseDirs
        (Test-PbivizVisualInput -Root $r -Name $Name -Ref PBVIZ_Team_Dev).Status | Should -Be 'BLOCKED'
        $c = New-PbivizPromotionCandidate -Root $r -Visual $Name -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod
        $c.Status | Should -Be 'BLOCKED'
        $c.Reason | Should -Match 'invalid input'
        $c.Worktree | Should -BeNullOrEmpty
        (Compare-PbivizRefSnapshot -Before $refs -After (Get-TRefs $r)).Created.Count | Should -Be 0
        @(Compare-PbivizWorkingState -Before $state -After (Get-TState $r)).Count | Should -Be 0
        @(Get-TReleaseDirs).Count | Should -Be @($dirs).Count -Because 'no pbiviz-release-* folder may be created'
    }

    It 'rejects a case-only mismatch with an explicit rename hint' {
        $res = Test-PbivizVisualInput -Root $script:G0Repo -Name 'bar' -Ref PBVIZ_Team_Dev
        $res.Reason | Should -Match 'differs only by case'
    }

    It 'rejects a ref that starts with a dash or does not resolve' {
        Resolve-PbivizCommit -Root $script:G0Repo -Ref '--all' | Should -BeNullOrEmpty
        Resolve-PbivizCommit -Root $script:G0Repo -Ref '-n1' | Should -BeNullOrEmpty
        $c = New-PbivizPromotionCandidate -Root $script:G0Repo -Visual 'Bar' -SourceRef '--output=x' -TargetRef PBVIZ_Team_Prod
        $c.Status | Should -Be 'BLOCKED'
        Test-Path -LiteralPath (Join-Path $script:G0Repo 'x') | Should -BeFalse
    }

    It 'rejects allowlist entries that are absolute, traverse, use magic or sit inside a visual or an archive' -TestCases @(
        @{ P = '../x.ts' }, @{ P = '/etc/x' }, @{ P = 'C:/x.ts' }, @{ P = ':(glob)*.ts' }, @{ P = 'shared/*.ts' },
        @{ P = 'ibcsColumnChart/src/visual.ts' }, @{ P = 'shared/releases/x.json' }, @{ P = '-x' }, @{ P = 'a/./b.ts' }
    ) {
        (Test-PbivizRelativePath -Root $script:G0Repo -Path $P -VisualNames @('Bar', 'Column', 'ibcsColumnChart')).Status | Should -Be 'BLOCKED'
        $c = New-PbivizPromotionCandidate -Root $script:G0Repo -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod -Allowlist @($P)
        $c.Status | Should -Be 'BLOCKED'
        $c.Worktree | Should -BeNullOrEmpty
    }

    It 'rejects a junction that escapes the PBIVIZ root' {
        $r = New-TRepo
        $outside = New-TDir 'o'
        New-TVisual $outside 'Evil' 'evilGuid01' '1.0.0.0'
        & cmd.exe /c "mklink /J `"$(Join-Path $r 'Evil')`" `"$(Join-Path $outside 'Evil')`"" 2>$null | Out-Null
        Test-Path -LiteralPath (Join-Path $r 'Evil\pbiviz.json') | Should -BeTrue
        $res = Test-PbivizVisualInput -Root $r -Name 'Evil' -RequireOnDisk
        $res.Status | Should -Be 'BLOCKED'
        $res.Reason | Should -Match 'junction'
    }

    It 'refuses worktree folders outside the temp prefix' {
        Test-PbivizWorktreeDir -Dir (Join-Path $script:Root 'pbiviz-release-x') | Should -Match 'temp folder'
        Test-PbivizWorktreeDir -Dir (Join-Path ([IO.Path]::GetTempPath()) 'other-x') | Should -Match 'must start with'
        $c = New-PbivizPromotionCandidate -Root $script:G0Repo -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod -WorktreeDir (Join-Path $script:Root 'pbiviz-release-y')
        $c.Status | Should -Be 'BLOCKED'
        Test-Path -LiteralPath (Join-Path $script:Root 'pbiviz-release-y') | Should -BeFalse
    }
}

Describe 'Remote adoption preserves both histories (defect 1)' {

    It '(a) baseline commit + independent README remote: both roots kept, all files present, push is a fast-forward' {
        $r = New-TDir 'L'
        $init = Initialize-PbivizRepository -Root $r -FolderWasEmpty
        $init.Status | Should -Be 'INITIALIZED'
        $baseline = $init.BaselineCommit
        $baseline | Should -Not -BeNullOrEmpty
        $bare = New-TBare
        $seed = New-TDir 's'
        TGit $seed init -q -b main | Out-Null
        Write-TFile $seed 'README.md' "# remote`n"
        $remoteTip = Save-TAll $seed 'remote root'
        TGit $seed push -q $bare main | Out-Null
        TGit $r remote add origin $bare | Out-Null
        $res = Connect-PbivizRemoteHistory -Root $r -Remote origin -Branch main -Fetch
        $res.Status | Should -Be 'PASS' -Because $res.Reason
        $res.Case | Should -Be 'unrelated-merge'
        (TGitExit $r merge-base --is-ancestor $baseline main) | Should -Be 0
        (TGitExit $r merge-base --is-ancestor $remoteTip main) | Should -Be 0
        $tree = @(Get-PbivizTreePaths -Root $r -TreeIsh HEAD)
        foreach ($f in '.gitignore', '.gitattributes', 'README.md') {
            $tree | Should -Contain $f
            Test-Path -LiteralPath (Join-Path $r $f) | Should -BeTrue
        }
        $res.BackupRef | Should -Match '^refs/pbiviz-backup/connect-'
        (TGit $r rev-parse $res.BackupRef) | Should -Be $baseline
        (TGitExit $r push --dry-run --porcelain $bare main) | Should -Be 0 -Because 'the remote tip is an ancestor, so the push is a fast-forward without force'
    }

    It '(b) conflicting add/add of .gitignore: merge aborted, repository exactly as before, conflict reported' {
        $r = New-TDir 'L'
        (Initialize-PbivizRepository -Root $r -FolderWasEmpty).Status | Should -Be 'INITIALIZED'
        $bare = New-TBare
        $seed = New-TDir 's'
        TGit $seed init -q -b main | Out-Null
        Write-TFile $seed '.gitignore' "remote-only/`n"
        Save-TAll $seed 'remote ignore' | Out-Null
        TGit $seed push -q $bare main | Out-Null
        TGit $r remote add origin $bare | Out-Null
        Write-TFile $r 'notes.txt' 'untracked note'
        $refs = Get-TRefs $r; $state = Get-TState $r
        $res = Connect-PbivizRemoteHistory -Root $r -Remote origin -Branch main -Fetch
        $res.Status | Should -Be 'CONFLICT' -Because $res.Reason
        $res.ConflictPaths | Should -Contain '.gitignore'
        @(Compare-PbivizWorkingState -Before $state -After (Get-TState $r)).Count | Should -Be 0
        $d = Compare-PbivizRefSnapshot -Before $refs -After (Get-TRefs $r)
        @($d.Updated).Count | Should -Be 0
        @($d.Deleted).Count | Should -Be 0
        @($d.Created | Sort-Object) | Should -Be @(@('refs/remotes/origin/main', $res.BackupRef) | Sort-Object)
    }

    It '(c) unborn branch with files: NEEDS CHECKPOINT, nothing changed' {
        $r = New-TDir 'L'
        Write-TFile $r 'Bar/pbiviz.json' '{}'
        TGit $r init -q -b main | Out-Null
        $bare = New-TBare; $seed = New-TDir 's'
        TGit $seed init -q -b main | Out-Null; Write-TFile $seed 'README.md' 'x'; Save-TAll $seed 'r' | Out-Null; TGit $seed push -q $bare main | Out-Null
        TGit $r remote add origin $bare | Out-Null
        $state = Get-TState $r
        $res = Connect-PbivizRemoteHistory -Root $r -Remote origin -Branch main -Fetch
        $res.Status | Should -Be 'NEEDS CHECKPOINT'
        (TGitExit $r rev-parse -q --verify refs/heads/main) | Should -Not -Be 0
        @(Compare-PbivizWorkingState -Before $state -After (Get-TState $r)).Count | Should -Be 0
    }

    It '(d) unborn and empty: tracking checkout of the remote branch' {
        $r = New-TDir 'L'
        TGit $r init -q -b main | Out-Null
        $bare = New-TBare; $seed = New-TDir 's'
        TGit $seed init -q -b main | Out-Null; Write-TFile $seed 'README.md' 'x'; $tip = Save-TAll $seed 'r'; TGit $seed push -q $bare main | Out-Null
        TGit $r remote add origin $bare | Out-Null
        $res = Connect-PbivizRemoteHistory -Root $r -Remote origin -Branch main -Fetch
        $res.Status | Should -Be 'PASS' -Because $res.Reason
        $res.Case | Should -Be 'tracking-checkout'
        (TGit $r rev-parse main) | Should -Be $tip
        (TGit $r rev-parse --abbrev-ref '@{upstream}') | Should -Be 'origin/main'
    }

    It '(e) related history: fast-forward only' {
        $bare = New-TBare; $seed = New-TDir 's'
        TGit $seed init -q -b main | Out-Null; Write-TFile $seed 'README.md' 'v1'; $c1 = Save-TAll $seed 'v1'; TGit $seed push -q $bare main | Out-Null
        $r = New-TDir 'L'
        TGit $script:Root clone -q $bare $r | Out-Null
        Write-TFile $seed 'README.md' 'v2'; $c2 = Save-TAll $seed 'v2'; TGit $seed push -q $bare main | Out-Null
        $res = Connect-PbivizRemoteHistory -Root $r -Remote origin -Branch main -Fetch
        $res.Status | Should -Be 'PASS' -Because $res.Reason
        $res.Case | Should -Be 'fast-forward'
        (TGit $r rev-parse main) | Should -Be $c2
        (TGitExit $r merge-base --is-ancestor $c1 main) | Should -Be 0
    }

    It '(f) remote default branch is not main: asks which branch to track' {
        $bare = New-TDir 'b'
        TGit $bare init -q --bare -b master | Out-Null
        $seed = New-TDir 's'
        TGit $seed init -q -b master | Out-Null; Write-TFile $seed 'README.md' 'x'; Save-TAll $seed 'r' | Out-Null; TGit $seed push -q $bare master | Out-Null
        $r = New-TDir 'L'
        (Initialize-PbivizRepository -Root $r -FolderWasEmpty).Status | Should -Be 'INITIALIZED'
        TGit $r remote add origin $bare | Out-Null
        $before = Get-TRefs $r
        $res = Connect-PbivizRemoteHistory -Root $r -Remote origin -Branch main -Fetch
        $res.Status | Should -Be 'NEEDS INPUT'
        $res.RemoteDefault | Should -Be 'master'
        (Compare-PbivizRefSnapshot -Before $before -After (Get-TRefs $r)).Created.Count | Should -Be 0
    }

    It 'empty remote: nothing changes locally' {
        $r = New-TDir 'L'
        (Initialize-PbivizRepository -Root $r -FolderWasEmpty).Status | Should -Be 'INITIALIZED'
        $bare = New-TBare
        TGit $r remote add origin $bare | Out-Null
        $before = Get-TRefs $r
        $res = Connect-PbivizRemoteHistory -Root $r -Remote origin -Branch main -Fetch
        $res.Case | Should -Be 'empty-remote'
        (Compare-PbivizRefSnapshot -Before $before -After (Get-TRefs $r)).Created.Count | Should -Be 0
    }
}

Describe 'Adoption postconditions are strict (S4)' {

    BeforeAll {
        function New-TAdoptPair {
            param([scriptblock]$Remote)
            $r = New-TDir 'L'
            (Initialize-PbivizRepository -Root $r -FolderWasEmpty).Status | Should -Be 'INITIALIZED'
            $bare = New-TBare; $seed = New-TDir 's'
            TGit $seed init -q -b main | Out-Null
            & $Remote $seed
            Save-TAll $seed 'remote' | Out-Null
            TGit $seed push -q $bare main | Out-Null
            TGit $r remote add origin $bare | Out-Null
            return @($r, $seed, $bare)
        }
    }

    It 'a remote tag is never fetched' {
        $p = New-TAdoptPair { param($s) Write-TFile $s 'README.md' 'x' }
        TGit $p[1] tag v-remote | Out-Null
        TGit $p[1] push -q $p[2] v-remote | Out-Null
        $res = Connect-PbivizRemoteHistory -Root $p[0] -Remote origin -Branch main -Fetch
        $res.Status | Should -Be 'PASS'
        @((Get-TRefs $p[0]).Keys | Where-Object { $_ -like 'refs/tags/*' }).Count | Should -Be 0
    }

    It 'blocks before merging when the remote tracks a path that is an IGNORED local file (overwrite-then-delete regression)' {
        $p = New-TAdoptPair { param($s) Write-TFile $s 'node_modules/keep.txt' 'REMOTE'; Write-TFile $s 'README.md' 'x' }
        Write-TFile $p[0] 'node_modules/keep.txt' 'LOCAL'
        $state = Get-TState $p[0]
        $res = Connect-PbivizRemoteHistory -Root $p[0] -Remote origin -Branch main -Fetch
        $res.Status | Should -Be 'BLOCKED'
        $res.Collisions | Should -Contain 'node_modules/keep.txt'
        [IO.File]::ReadAllText((Join-Path $p[0] 'node_modules\keep.txt')) | Should -Be 'LOCAL'
        @(Compare-PbivizWorkingState -Before $state -After (Get-TState $p[0])).Count | Should -Be 0
        (TGitExit $p[0] rev-parse -q --verify MERGE_HEAD) | Should -Not -Be 0
    }

    It 'blocks before merging on an untracked collision' {
        $p = New-TAdoptPair { param($s) Write-TFile $s 'README.md' 'REMOTE' }
        Write-TFile $p[0] 'README.md' 'LOCAL UNTRACKED'
        $res = Connect-PbivizRemoteHistory -Root $p[0] -Remote origin -Branch main -Fetch
        $res.Status | Should -Be 'BLOCKED'
        [IO.File]::ReadAllText((Join-Path $p[0] 'README.md')) | Should -Be 'LOCAL UNTRACKED'
    }

    It 'dirty tracked files: NEEDS CHECKPOINT' {
        $p = New-TAdoptPair { param($s) Write-TFile $s 'README.md' 'x' }
        Add-Content -LiteralPath (Join-Path $p[0] '.gitignore') -Value 'extra/'
        (Connect-PbivizRemoteHistory -Root $p[0] -Remote origin -Branch main -Fetch).Status | Should -Be 'NEEDS CHECKPOINT'
    }

    It 'a successful adoption has exactly [old local tip, remote tip] as parents' {
        $p = New-TAdoptPair { param($s) Write-TFile $s 'README.md' 'x' }
        $old = TGit $p[0] rev-parse main
        $res = Connect-PbivizRemoteHistory -Root $p[0] -Remote origin -Branch main -Fetch
        $res.Status | Should -Be 'PASS'
        $parents = (TGit $p[0] rev-list --parents -n 1 main).Split(' ')
        $parents[1] | Should -Be $old
        $parents[2] | Should -Be $res.RemoteTip
    }

    It 'meta: a backup ref holding the old tip never satisfies the history check when main moves backwards' {
        $r = New-TRepo
        $c1 = Save-TAll $r 'one'
        Write-TFile $r 'b.txt' 'b'
        $c2 = Save-TAll $r 'two'
        $before = Get-TRefs $r
        $backup = New-PbivizBackupRef -Root $r -Operation 'meta' -Sha $c2
        TGit $r update-ref refs/heads/main $c1 | Out-Null
        $res = Assert-PbivizNoCommitLoss -Root $r -Before $before -After (Get-TRefs $r)
        $res.Status | Should -Be 'FAILED'
        $res.Reason | Should -Match 'refs/heads/main'
        (TGit $r rev-parse $backup) | Should -Be $c2 -Because 'the backup still holds the commit, yet the check fails'
    }

    It 'meta: deleting a branch or creating a tag fails the ref accounting' {
        $r = New-TRepo
        Save-TAll $r 'one' | Out-Null
        TGit $r branch side | Out-Null
        $before = Get-TRefs $r
        TGit $r branch '-D' side | Out-Null
        (Assert-PbivizNoCommitLoss -Root $r -Before $before -After (Get-TRefs $r)).Reason | Should -Match 'deleted'
        $before2 = Get-TRefs $r
        TGit $r tag stray | Out-Null
        (Assert-PbivizNoCommitLoss -Root $r -Before $before2 -After (Get-TRefs $r)).Reason | Should -Match 'created'
    }
}

Describe 'Promotion never touches the release archive (defect 2)' {

    It 'keeps a Prod-only archived package (blob ids unchanged) and G6 passes' {
        $r = New-TL3 -OnProd { param($x) New-TReleasePair $x 'Bar' 'barGuid0001' '1.0.0.1' }
        $prodBlobs = @(Get-PbivizTreeEntries -Root $r -TreeIsh PBVIZ_Team_Prod | Where-Object { Test-PbivizArchivePath $_.Path })
        $prodBlobs.Count | Should -Be 2
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Write-TFile $r 'Bar/src/visual.ts' 'export class Visual { v2 = true }'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Candidate.Status | Should -Be 'PASS' -Because $p.Candidate.Reason
        $p.Release.Status | Should -Be 'PASS' -Because $p.Release.Reason
        $p.Gates.Status | Should -Be 'PASS' -Because $p.Gates.Reason
        $idx = @(Get-PbivizTreeEntries -Root $p.Candidate.Worktree -TreeIsh (TGit $p.Candidate.Worktree write-tree))
        foreach ($pb in $prodBlobs) { (@($idx | Where-Object { $_.Path -ceq $pb.Path })[0]).Object | Should -Be $pb.Object }
    }

    It 'BLOCKS a forced staged <Kind> of an archived file (G6)' -TestCases @(@{ Kind = 'deletion' }, @{ Kind = 'modification' }, @{ Kind = 'rename' }) {
        $r = New-TL3 -OnProd { param($x) New-TReleasePair $x 'Bar' 'barGuid0001' '1.0.0.1' }
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'PASS'
        $wt = $p.Candidate.Worktree
        $old = 'Bar/releases/barGuid0001.1.0.0.1.pbiviz'
        switch ($Kind) {
            'deletion'     { TGit $wt rm -q --cached -- $old | Out-Null }
            'modification' { Write-TBytes -Path (Join-Path $wt ($old -replace '/', '\')) -Seed 99; TGit $wt add -- $old | Out-Null }
            'rename'       { TGit $wt mv -- $old 'Bar/releases/renamed.pbiviz' | Out-Null }
        }
        $g = Test-PbivizPromotionGates -Worktree $wt -Visual 'Bar' -TargetRef PBVIZ_Team_Prod
        $g.Status | Should -Be 'BLOCKED'
        (Get-TGate $g 'G6').Pass | Should -BeFalse
        (Get-TGate $g 'G6').Detail | Should -Match 'append-only'
    }

    It 'never promotes DEV-only archive files' {
        $r = New-TL3
        New-TReleasePair $r 'Bar' 'barGuid0001' '0.9.0.0'
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'dev release + v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'PASS' -Because $p.Gates.Reason
        @(Get-PbivizTreePaths -Root $p.Candidate.Worktree -TreeIsh (TGit $p.Candidate.Worktree write-tree)) | Should -Not -Contain 'Bar/releases/barGuid0001.0.9.0.0.pbiviz'
    }

    It 'leaves another visual archive untouched (G3)' {
        $r = New-TL3 -OnProd { param($x) New-TReleasePair $x 'Column' 'colGuid0001' '2.0.0.1' }
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'PASS'
        (Get-TGate $p.Gates 'G3').Pass | Should -BeTrue
        (TGit $p.Candidate.Worktree rev-parse "$(TGit $p.Candidate.Worktree write-tree):Column") | Should -Be (TGit $r rev-parse 'PBVIZ_Team_Prod:Column')
    }

    It 'legacy archive versions enforce monotonicity' {
        $r = New-TL3 -OnProd { param($x) New-TReleasePair $x 'Bar' 'barGuid0001' '5.0.0.0' -Origin 'legacy-archive' -Sub 'legacy' }
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $c = New-PbivizPromotionCandidate -Root $r -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod
        $c.Status | Should -Be 'BLOCKED'
        $c.Reason | Should -Match 'does not exceed'
    }

    It 'archive-only promotion adds earlier validated releases to an empty-history Prod and nothing else' {
        $r = New-TL3
        New-TReleasePair $r 'Bar' 'barGuid0001' '1.0.0.1' -Validated
        Save-TAll $r 'release on dev' | Out-Null
        $c = New-PbivizPromotionCandidate -Root $r -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod -ArchiveOnly
        $c.Status | Should -Be 'PASS' -Because $c.Reason
        $g = Test-PbivizPromotionGates -Worktree $c.Worktree -Visual 'Bar' -TargetRef PBVIZ_Team_Prod -ArchiveOnly
        $g.Status | Should -Be 'PASS' -Because $g.Reason
        @($g.Changes | Where-Object { $_.Status -ne 'A' -or -not (Test-PbivizArchivePath $_.Path) }).Count | Should -Be 0
    }
}

Describe 'Selective single-visual promotion (#13, #14)' {

    It 'promotes Bar only while Column also changed on DEV (separate and mixed commits)' -TestCases @(@{ Mixed = $false }, @{ Mixed = $true }) {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        if (-not $Mixed) { Save-TAll $r 'bar' | Out-Null }
        Write-TFile $r 'Column/src/visual.ts' 'export class Visual { dev = 1 }'
        Save-TAll $r 'column (+bar if mixed)' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'PASS' -Because $p.Gates.Reason
        @($p.Gates.Changes | Where-Object { $_.Path -like 'Column/*' }).Count | Should -Be 0
        [IO.File]::ReadAllText((Join-Path $p.Candidate.Worktree 'Column\src\visual.ts')) | Should -Not -Match 'dev = 1'
    }

    It 'stages deletions and renames inside the source scope' {
        $r = New-TL3
        Write-TFile $r 'Bar/src/old.ts' 'old'
        Write-TFile $r 'Bar/src/a.ts' 'a'
        Save-TAll $r 'extra files' | Out-Null
        TGit $r branch -f PBVIZ_Team_Prod HEAD | Out-Null
        TGit $r rm -q -- 'Bar/src/old.ts' | Out-Null
        TGit $r mv -- 'Bar/src/a.ts' 'Bar/src/b.ts' | Out-Null
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'delete + rename' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'PASS' -Because $p.Gates.Reason
        $ch = @($p.Gates.Changes | ForEach-Object { "$($_.Status) $($_.Path)" })
        $ch | Should -Contain 'D Bar/src/old.ts'
        $ch | Should -Contain 'D Bar/src/a.ts'
        $ch | Should -Contain 'A Bar/src/b.ts'
        Test-Path -LiteralPath (Join-Path $p.Candidate.Worktree 'Bar\src\old.ts') | Should -BeFalse
    }

    It 'BLOCKS an undeclared shared dependency and passes once it is allowlisted' {
        $r = New-TL3
        Write-TFile $r 'shared/fmt.ts' 'export const f = 1;'
        Save-TAll $r 'shared' | Out-Null
        TGit $r branch -f PBVIZ_Team_Prod HEAD | Out-Null
        Write-TFile $r 'shared/fmt.ts' 'export const f = 2;'
        Write-TFile $r 'Bar/src/visual.ts' "import { f } from '../../shared/fmt';`nexport class Visual {}"
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar uses shared' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'BLOCKED'
        (Get-TGate $p.Gates 'G4').Pass | Should -BeFalse
        $discard = Remove-PbivizPromotionWorktree -Root $r -WorktreeDir $p.Candidate.Worktree
        $discard.Status | Should -Be 'BLOCKED' -Because 'an uncommitted candidate is never discarded without explicit approval'
        $discard.Reason | Should -Match 'incomplete candidate'
        (Remove-PbivizPromotionWorktree -Root $r -WorktreeDir $p.Candidate.Worktree -DiscardApproval 'APPROVED:DISCARD-CANDIDATE:release/pbiviz/Bar/1.0.0.2').Status | Should -Be 'PASS'
        TGit $r branch '-D' 'release/pbiviz/Bar/1.0.0.2' | Out-Null
        $q = Invoke-TPromotion -Repo $r -Allowlist @('shared/fmt.ts')
        $q.Gates.Status | Should -Be 'PASS' -Because $q.Gates.Reason
        (Get-TGate $q.Gates 'G3').Pass | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $q.Candidate.Worktree 'shared\fmt.ts')) | Should -Match 'f = 2'
        $man = [IO.File]::ReadAllText($q.Release.ManifestPath) | ConvertFrom-Json
        @($man.sharedFiles).Count | Should -Be 1 -Because 'allowlisted files sit outside the fingerprint, so the manifest records them'
        $man.sharedFiles[0].path | Should -Be 'shared/fmt.ts'
        $man.sharedFiles[0].blob | Should -Be (TGit $r rev-parse 'PBVIZ_Team_Dev:shared/fmt.ts')
    }

    It 'leaves a dirty user checkout untouched' {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar' | Out-Null
        Write-TFile $r 'Column/src/visual.ts' 'work in progress'
        Write-TFile $r 'scratch.txt' 'untracked'
        $state = Get-TState $r
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'PASS'
        TGit $p.Candidate.Worktree commit -q -m 'release Bar 1.0.0.2' | Out-Null
        (Remove-PbivizPromotionWorktree -Root $r -WorktreeDir $p.Candidate.Worktree).Status | Should -Be 'PASS'
        $after = Get-TState $r
        @(Compare-PbivizWorkingState -Before $state -After $after | Where-Object { $_ -ne 'Worktrees changed' }).Count | Should -Be 0
        $after.Worktrees | Should -Be $state.Worktrees
    }

    It 'never moves an existing release branch' {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar' | Out-Null
        TGit $r branch 'release/pbiviz/Bar/1.0.0.2' PBVIZ_Team_Prod | Out-Null
        $before = TGit $r rev-parse 'release/pbiviz/Bar/1.0.0.2'
        $c = New-PbivizPromotionCandidate -Root $r -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod
        $c.Status | Should -Be 'BLOCKED'
        (TGit $r rev-parse 'release/pbiviz/Bar/1.0.0.2') | Should -Be $before
    }
}

Describe 'G6 is independent of pathspec mode (S1)' {

    It 'BLOCKS deletion of an existing Prod release with identical verdicts when the test process sets <Mode>' -TestCases @(
        @{ Mode = 'GIT_LITERAL_PATHSPECS'; Value = '1' }, @{ Mode = 'none'; Value = $null }, @{ Mode = 'GIT_GLOB_PATHSPECS'; Value = '1' }
    ) {
        $r = New-TL3 -OnProd { param($x) New-TReleasePair $x 'Bar' 'barGuid0001' '1.0.0.1' }
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        TGit $p.Candidate.Worktree rm -q --cached -- 'Bar/releases/barGuid0001.1.0.0.1.pbiviz' | Out-Null
        if ($Mode -ne 'none') { Set-Item "Env:$Mode" $Value }
        try { $g = Test-PbivizPromotionGates -Worktree $p.Candidate.Worktree -Visual 'Bar' -TargetRef PBVIZ_Team_Prod }
        finally { if ($Mode -ne 'none') { Remove-Item "Env:$Mode" -ErrorAction SilentlyContinue } }
        $g.Status | Should -Be 'BLOCKED'
        (Get-TGate $g 'G6').Pass | Should -BeFalse
        (Get-TGate $g 'G6').Detail | Should -Match 'D Bar/releases/barGuid0001\.1\.0\.0\.1\.pbiviz'
        (@($g.Gates | ForEach-Object { "$($_.Gate)=$($_.Pass)" }) -join ',') | Should -Be 'G0=False,G1=False,G2=False,G3=True,G4=True,G5=True,G6=False'
    }

    It 'BLOCKS a releases/ -> Releases/ case rename' {
        $r = New-TL3 -OnProd { param($x) New-TReleasePair $x 'Bar' 'barGuid0001' '1.0.0.1' }
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $wt = $p.Candidate.Worktree
        $blob = TGit $wt rev-parse ':Bar/releases/barGuid0001.1.0.0.1.pbiviz'
        TGit $wt rm -q --cached -- 'Bar/releases/barGuid0001.1.0.0.1.pbiviz' | Out-Null
        TGit $wt update-index --add --cacheinfo "100644,$blob,Bar/Releases/barGuid0001.1.0.0.1.pbiviz" | Out-Null
        $g = Test-PbivizPromotionGates -Worktree $wt -Visual 'Bar' -TargetRef PBVIZ_Team_Prod
        $g.Status | Should -Be 'BLOCKED'
        (Get-TGate $g 'G6').Pass | Should -BeFalse
    }

    It 'never passes vacuously: a release promotion with zero archive additions is BLOCKED' {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r -SkipRelease
        $p.Gates.Status | Should -Be 'BLOCKED'
        (Get-TGate $p.Gates 'G6').Detail | Should -Match 'found 0'
    }
}

Describe 'File lists are binary-safe (S2)' {

    It 'promotes Unicode, NFC/NFD, bracket, dash and long names byte-exact with core.quotePath=true' {
        $r = New-TL3
        TGit $r config core.quotePath true | Out-Null
        $names = @('with space.ts', ('u' + [char]0xFC + 'n' + [char]0xEF + 'c' + [char]0xF8 + 'de.ts'), ([string][char]0x65E5 + [char]0x672C + [char]0x8A9E + '.ts'),
                   ('emoji-' + [char]::ConvertFromUtf32(0x1F600) + '.ts'), ('caf' + [char]0xE9 + '.ts'), ('cafe' + [char]0x301 + '.ts'), '[brackets].ts', '-leading-dash.ts', "apostrophe's & percent%20.ts")
        foreach ($n in $names) { Write-TFile $r "Bar/src/$n" $n }
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        TGit $r add -A -- Bar | Out-Null
        $long = 'Bar/' + (('d' * 60 + '/') * 3) + ('f' * 40) + '.ts'
        TGit $r config core.longpaths true | Out-Null
        $blob = ('long' | & git -C $r hash-object -w --stdin)
        TGit $r update-index --add --cacheinfo "100644,$blob,$long" | Out-Null
        TGit $r commit -q -m 'unicode' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'PASS' -Because $p.Gates.Reason
        $added = @($p.Gates.Changes | Where-Object { $_.Status -eq 'A' } | ForEach-Object { $_.Path })
        foreach ($n in $names) { ($added -ccontains "Bar/src/$n") | Should -BeTrue -Because "'$n' must be staged exactly once" }
        ($added -ccontains $long) | Should -BeTrue
        @($added | Where-Object { $_ -like 'Bar/src/*' }).Count | Should -Be $names.Count -Because 'the long-path file sits outside src/ and is asserted above'
        (Get-PbivizSourceFingerprint -Root $r -TreeIsh PBVIZ_Team_Dev -Visual 'Bar') | Should -Be (Get-PbivizSourceFingerprint -Root $r -TreeIsh (TGit $p.Candidate.Worktree write-tree) -Visual 'Bar')
    }

    It 'BLOCKS tree entries Windows cannot represent (<Label>) before writing anything' -TestCases @(
        @{ Label = 'tab'; Bad = "a`tb.ts" }, @{ Label = 'newline'; Bad = "a`nb.ts" }, @{ Label = 'quote'; Bad = 'a"b.ts' }, @{ Label = 'backslash'; Bad = 'a\b.ts' }
    ) {
        $r = New-TL3
        $blob = ('x' | & git -C $r hash-object -w --stdin)
        $src = New-TTreeRaw $r @("100644 blob $blob`tvisual.ts", "100644 blob $blob`t$Bad")
        $pj = TGit $r rev-parse 'HEAD:Bar/pbiviz.json'
        $bar = New-TTreeRaw $r @("100644 blob $pj`tpbiviz.json", "040000 tree $src`tsrc")
        $top = @(Get-PbivizTopEntries -Root $r -TreeIsh HEAD)
        $recs = @(); foreach ($k in $top[0].Keys) { if ($k -ne 'Bar') { $e = $top[0][$k]; $recs += "$($e.Mode) $($e.Type) $($e.Object)`t$k" } }
        $recs += "040000 tree $bar`tBar"
        $root = New-TTreeRaw $r $recs
        $commit = ('crafted' | & git -C $r commit-tree $root -p HEAD)
        TGit $r update-ref refs/heads/PBVIZ_Team_Dev $commit | Out-Null
        $listed = @(Get-PbivizTreePaths -Root $r -TreeIsh $commit)
        $listed | Should -Contain "Bar/src/$Bad" -Because 'the name is listed byte-exact, never dropped'
        $dirs = Get-TReleaseDirs; $wtl = @(Get-PbivizWorktreeList -Directory $r)
        $c = New-PbivizPromotionCandidate -Root $r -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod
        $c.Status | Should -Be 'BLOCKED'
        $c.Reason | Should -Match 'not representable'
        @(Get-TReleaseDirs).Count | Should -Be @($dirs).Count
        @(Get-PbivizWorktreeList -Directory $r).Count | Should -Be $wtl.Count
    }
}

Describe 'Candidate worktree state contract (S3)' {

    BeforeAll {
        function New-TCandidate {
            $r = New-TL3
            Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
            Save-TAll $r 'bar v2' | Out-Null
            $c = New-PbivizPromotionCandidate -Root $r -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod
            $c.Status | Should -Be 'PASS' -Because $c.Reason
            $b = Invoke-TBuild -Dir $c.Worktree -Worktree -Seed 3
            $b.Status | Should -Be 'PASS' -Because $b.Reason
            return @($r, $c)
        }
    }

    It 'accepts the authorised staged snapshot (no false dirty error) and ignored build outputs' {
        $x = New-TCandidate
        Write-TFile $x[1].Worktree 'Bar/node_modules/pkg/index.js' 'x'
        Write-TFile $x[1].Worktree 'Bar/.tmp/cache.txt' 'x'
        (Test-PbivizCandidateState -Worktree $x[1].Worktree).Status | Should -Be 'PASS'
        $ev = Get-TEvidence -Sha $x[1].Source
        $res = Add-PbivizRelease -Worktree $x[1].Worktree -Visual 'Bar' -SourceSha $x[1].Source @ev
        $res.Status | Should -Be 'PASS' -Because $res.Reason
    }

    It 'BLOCKS <Case>' -TestCases @(
        @{ Case = 'an extra staged change to another visual' }, @{ Case = 'an unstaged edit after the snapshot' },
        @{ Case = 'an untracked non-ignored file' }, @{ Case = 'a build that rewrites a tracked file' },
        @{ Case = 'an extra commit on the candidate branch' }, @{ Case = 'a missing candidate record' }, @{ Case = 'a mismatched candidate record' }
    ) {
        $x = New-TCandidate
        $wt = $x[1].Worktree
        switch ($Case) {
            'an extra staged change to another visual' { Write-TFile $wt 'Column/src/visual.ts' 'sneaky'; TGit $wt add -- 'Column/src/visual.ts' | Out-Null }
            'an unstaged edit after the snapshot' { Write-TFile $wt 'Bar/src/visual.ts' 'edited later' }
            'an untracked non-ignored file' { Write-TFile $wt 'Bar/notes.txt' 'x' }
            'a build that rewrites a tracked file' { Write-TFile $wt 'Bar/capabilities.json' '{ "rewritten": true }' }
            'an extra commit on the candidate branch' { TGit $wt commit -q -m 'early' | Out-Null }
            'a missing candidate record' { Remove-Item -LiteralPath (Get-PbivizCandidateRecordPath -Worktree $wt) -Force }
            'a mismatched candidate record' { $rp = Get-PbivizCandidateRecordPath -Worktree $wt; $j = [IO.File]::ReadAllText($rp) | ConvertFrom-Json; $j.candidateTree = '0' * 40; [IO.File]::WriteAllText($rp, ($j | ConvertTo-Json)) }
        }
        (Test-PbivizCandidateState -Worktree $wt).Status | Should -Be 'BLOCKED'
        $ev = Get-TEvidence -Sha $x[1].Source
        (Add-PbivizRelease -Worktree $wt -Visual 'Bar' -SourceSha $x[1].Source @ev).Status | Should -Be 'BLOCKED'
    }

    It 'BLOCKS a worktree the helper did not create' {
        $r = New-TL3
        $manual = Join-Path ([IO.Path]::GetTempPath()) ('pbiviz-release-manual-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        TGit $r worktree add -q -b manual-test $manual PBVIZ_Team_Prod | Out-Null
        try {
            $s = Test-PbivizCandidateState -Worktree $manual
            $s.Status | Should -Be 'BLOCKED'
            $s.Reason | Should -Match 'not created by the helper'
        } finally { TGit $r worktree remove --force $manual | Out-Null }
    }

    It 'L1/L2 release refuses a dirty tree or untracked files in the visual' {
        $r = New-TRepo
        New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
        $head = Save-TAll $r 'base'
        Write-TPackage -Path (Join-Path $r 'Bar\dist\barGuid0001.1.0.0.1.pbiviz') -Guid 'barGuid0001' -Version '1.0.0.1'
        Write-TFile $r 'Bar/untracked.ts' 'x'
        (Add-PbivizRelease -Root $r -Visual 'Bar' -SourceSha $head).Reason | Should -Match 'untracked'
        Remove-Item -LiteralPath (Join-Path $r 'Bar\untracked.ts')
        Write-TFile $r 'Bar/src/visual.ts' 'dirty'
        (Add-PbivizRelease -Root $r -Visual 'Bar' -SourceSha $head).Reason | Should -Match 'uncommitted'
    }
}

Describe 'Provenance is derived; Prod is never written after merge (defect 3)' {

    It 'derives the Prod commit after a <Strategy> merge and verifies integrity' -TestCases @(@{ Strategy = 'merge-commit' }, @{ Strategy = 'squash' }, @{ Strategy = 'rebase' }) {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'PASS'
        $wt = $p.Candidate.Worktree
        TGit $wt commit -q -m 'release Bar 1.0.0.2' -m 'Pbiviz-Release: Bar@1.0.0.2' | Out-Null
        $releaseCommit = TGit $wt rev-parse HEAD
        $manifest = [IO.File]::ReadAllText((Join-Path $wt 'Bar\releases\barGuid0001.1.0.0.2.release.json')) | ConvertFrom-Json
        @($manifest.PSObject.Properties.Name) | Should -Not -Contain 'prodSha'
        @($manifest.PSObject.Properties.Name) | Should -Not -Contain 'pr'
        @($manifest.PSObject.Properties.Name) | Should -Not -Contain 'tag'
        (Remove-PbivizPromotionWorktree -Root $r -WorktreeDir $wt).Status | Should -Be 'PASS'
        TGit $r switch -q PBVIZ_Team_Prod | Out-Null
        switch ($Strategy) {
            'merge-commit' { TGit $r merge -q --no-ff -m 'Merge PR' $releaseCommit | Out-Null }
            'squash'       { TGit $r merge -q --squash $releaseCommit | Out-Null; TGit $r commit -q -m 'Squashed PR' | Out-Null }
            'rebase'       { TGit $r cherry-pick $releaseCommit | Out-Null }
        }
        $prodTip = TGit $r rev-parse PBVIZ_Team_Prod
        TGit $r switch -q PBVIZ_Team_Dev | Out-Null
        $prov = Get-PbivizReleaseProvenance -Root $r -Visual 'Bar' -Version '1.0.0.2' -ProdRef PBVIZ_Team_Prod
        $prov.Status | Should -Be 'DERIVED' -Because $prov.Reason
        $prov.ProdCommit | Should -Be $prodTip
        $i = Test-PbivizReleaseIntegrity -Root $r -Visual 'Bar' -Version '1.0.0.2' -Commit $prov.ProdCommit
        $i.Status | Should -Be 'PASS' -Because $i.Reason
        $i.Verification | Should -Be 'COMPLETE'
        $i.ReleaseClass | Should -Be 'OFFICIAL RELEASE'
        (TGit $r rev-parse PBVIZ_Team_Prod) | Should -Be $prodTip -Because 'the helper writes nothing to Prod after the merge'
    }

    It 'reports NOT DERIVABLE in a shallow clone' {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        TGit $p.Candidate.Worktree commit -q -m 'release' | Out-Null
        $rc = TGit $p.Candidate.Worktree rev-parse HEAD
        TGit $r branch -f PBVIZ_Team_Prod $rc | Out-Null
        $shallow = New-TDir 'sh'
        Remove-Item -LiteralPath $shallow
        TGit $script:Root clone -q --depth 1 --branch PBVIZ_Team_Prod ('file:///' + ($r -replace '\\', '/')) $shallow | Out-Null
        $prov = Get-PbivizReleaseProvenance -Root $shallow -Visual 'Bar' -Version '1.0.0.2' -ProdRef HEAD
        $prov.Status | Should -Be 'NOT DERIVABLE'
        $prov.Reason | Should -Match 'shallow'
    }

    It 'the helper exposes no function that pushes, merges, tags or commits to a target branch' {
        $names = @(Get-Command -CommandType Function | Where-Object { $_.ScriptBlock.File -eq $script:HelperFile } | ForEach-Object { $_.Name })
        $names.Count | Should -BeGreaterThan 20
        $names | Where-Object { $_ -cmatch '^(Push|Merge|Publish|Send)-|PullRequest|Tags?$|Distribute' } | Should -BeNullOrEmpty
    }
}

Describe 'Release archive pairs and legacy archive (#15, O2)' {

    It 'adds a release pair on a clean tree with hash, fingerprint and no Prod fields' {
        $r = New-TRepo
        New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
        $head = Save-TAll $r 'base'
        Write-TPackage -Path (Join-Path $r 'Bar\dist\barGuid0001.1.0.0.1.pbiviz') -Guid 'barGuid0001' -Version '1.0.0.1' -Seed 5
        $res = Add-PbivizRelease -Root $r -Visual 'Bar' -SourceSha $head
        $res.Status | Should -Be 'PASS' -Because $res.Reason
        $res.Sha256 | Should -Be (Get-PbivizFileSha256 (Join-Path $r 'Bar\dist\barGuid0001.1.0.0.1.pbiviz'))
        $staged = TGit $r diff --cached --name-only
        $staged | Should -Match 'Bar/releases/barGuid0001.1.0.0.1.pbiviz'
        $m = [IO.File]::ReadAllText($res.ManifestPath) | ConvertFrom-Json
        $m.origin | Should -Be 'release'
        $m.sourceSha | Should -Be $head
        $m.sourceFingerprint | Should -Be (Get-PbivizSourceFingerprint -Root $r -TreeIsh $head -Visual 'Bar')
        @($m.PSObject.Properties.Name) | Should -Not -Contain 'prodSha'
    }

    It 'never overwrites an existing pair and enforces monotonic versions and a stable GUID' {
        $r = New-TRepo
        New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
        $head = Save-TAll $r 'base'
        Write-TPackage -Path (Join-Path $r 'Bar\dist\barGuid0001.1.0.0.1.pbiviz') -Guid 'barGuid0001' -Version '1.0.0.1' -Seed 5
        (Add-PbivizRelease -Root $r -Visual 'Bar' -SourceSha $head).Status | Should -Be 'PASS'
        $head2 = Save-TAll $r 'release 1.0.0.1'
        $bytes = [IO.File]::ReadAllBytes((Join-Path $r 'Bar\releases\barGuid0001.1.0.0.1.pbiviz'))
        (Add-PbivizRelease -Root $r -Visual 'Bar' -SourceSha $head2).Reason | Should -Match 'does not exceed|already exists'
        [IO.File]::ReadAllBytes((Join-Path $r 'Bar\releases\barGuid0001.1.0.0.1.pbiviz')).Length | Should -Be $bytes.Length
        Set-TVersion $r 'Bar' 'otherGuid99' '1.0.0.2'
        $head3 = Save-TAll $r 'guid rotated'
        Write-TPackage -Path (Join-Path $r 'Bar\dist\otherGuid99.1.0.0.2.pbiviz') -Guid 'otherGuid99' -Version '1.0.0.2' -Seed 6
        (Add-PbivizRelease -Root $r -Visual 'Bar' -SourceSha $head3).Reason | Should -Match 'GUID'
    }

    It 'archives legacy dist packages as validated:false and counts them for monotonicity' {
        $r = New-TRepo
        New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
        $head = Save-TAll $r 'base'
        Write-TPackage -Path (Join-Path $r 'Bar\dist\barGuid0001.3.0.0.0.pbiviz') -Guid 'barGuid0001' -Version '3.0.0.0' -Seed 8
        Write-TBytes -Path (Join-Path $r 'Bar\dist\not-a-release.pbiviz') -Seed 9
        Write-TPackage -Path (Join-Path $r 'Bar\dist\barGuid0001.4.0.0.0.pbiviz') -Guid 'barGuid0001' -Version '4.0.0.1' -Seed 10
        Write-TBytes -Path (Join-Path $r 'Bar\dist\barGuid0001.5.0.0.0.pbiviz') -Seed 11
        $a = Add-PbivizLegacyArchive -Root $r -Visual 'Bar'
        $a.Status | Should -Be 'PASS' -Because $a.Reason
        @($a.Archived).Count | Should -Be 2
        @($a.Skipped).Count | Should -Be 3
        ($a.Skipped -join ' | ') | Should -Match 'barGuid0001\.4\.0\.0\.0\.pbiviz \(content is barGuid0001 4\.0\.0\.1; the file name does not match\)' -Because 'the identity comes from the content, never from the file name'
        ($a.Skipped -join ' | ') | Should -Match 'barGuid0001\.5\.0\.0\.0\.pbiviz \(not a \.pbiviz package'
        Test-Path -LiteralPath (Join-Path $r 'Bar\releases\legacy\barGuid0001.4.0.0.0.pbiviz') | Should -BeFalse
        $m = [IO.File]::ReadAllText((Join-Path $r 'Bar\releases\legacy\barGuid0001.3.0.0.0.release.json')) | ConvertFrom-Json
        $m.validated | Should -BeFalse
        $m.origin | Should -Be 'legacy-archive'
        $head2 = Save-TAll $r 'legacy archive'
        (Add-PbivizLegacyArchive -Root $r -Visual 'Bar').Archived.Count | Should -Be 0 -Because 're-running skips archived files'
        Write-TPackage -Path (Join-Path $r 'Bar\dist\barGuid0001.1.0.0.1.pbiviz') -Guid 'barGuid0001' -Version '1.0.0.1' -Seed 5
        (Add-PbivizRelease -Root $r -Visual 'Bar' -SourceSha $head2).Reason | Should -Match 'does not exceed'
    }
}

Describe 'Candidate cleanup checks identity and state before removing anything (review finding 1)' {

    BeforeAll {
        function New-TPromoted {
            param([switch]$Commit)
            $r = New-TL3
            Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
            Save-TAll $r 'bar v2' | Out-Null
            $p = Invoke-TPromotion -Repo $r
            $p.Gates.Status | Should -Be 'PASS' -Because $p.Gates.Reason
            if ($Commit) { TGit $p.Candidate.Worktree commit -q -m 'release Bar 1.0.0.2' | Out-Null }
            return [pscustomobject]@{ Repo = $r; Wt = $p.Candidate.Worktree; Branch = $p.Candidate.Branch }
        }
    }

    It 'removes a completed candidate WITHOUT force; ignored build output goes, the release branch stays' {
        $x = New-TPromoted -Commit
        Write-TFile $x.Wt 'Bar/node_modules/dep/index.js' 'ignored build input'
        $tip = TGit $x.Repo rev-parse $x.Branch
        $res = Remove-PbivizPromotionWorktree -Root $x.Repo -WorktreeDir $x.Wt
        $res.Status | Should -Be 'PASS' -Because $res.Reason
        ($res.Evidence -join ' ') | Should -Match 'without force'
        Test-Path -LiteralPath $x.Wt | Should -BeFalse
        (TGit $x.Repo rev-parse $x.Branch) | Should -Be $tip
    }

    It 'keeps an uncommitted candidate unless the exact discard approval is given' {
        $x = New-TPromoted
        $idx = TGit $x.Wt write-tree
        foreach ($tok in @($null, 'APPROVED:DISCARD-CANDIDATE', 'APPROVED:DISCARD-CANDIDATE:release/pbiviz/Column/9.9.9.9', 'approved:discard-candidate:release/pbiviz/Bar/1.0.0.2', 'yes')) {
            $res = Remove-PbivizPromotionWorktree -Root $x.Repo -WorktreeDir $x.Wt -DiscardApproval $tok
            $res.Status | Should -Be 'BLOCKED' -Because "token '$tok'"
            $res.Reason | Should -Match 'incomplete candidate'
        }
        Test-Path -LiteralPath $x.Wt | Should -BeTrue
        (TGit $x.Wt write-tree) | Should -Be $idx -Because 'a refused removal changes nothing'
        $ok = Remove-PbivizPromotionWorktree -Root $x.Repo -WorktreeDir $x.Wt -DiscardApproval "APPROVED:DISCARD-CANDIDATE:$($x.Branch)"
        $ok.Status | Should -Be 'PASS' -Because $ok.Reason
        Test-Path -LiteralPath $x.Wt | Should -BeFalse
        (TGitExit $x.Repo rev-parse -q --verify "refs/heads/$($x.Branch)") | Should -Be 0
    }

    It 'refuses <Case>, even with the discard approval, and changes nothing' -TestCases @(
        @{ Case = 'an unstaged edit to a tracked file' }, @{ Case = 'an untracked file' }, @{ Case = 'an extra staged change' },
        @{ Case = 'a merge in progress' }, @{ Case = 'a missing candidate record' }, @{ Case = 'a record written for another folder' },
        @{ Case = 'a switched branch' }
    ) {
        $x = New-TPromoted -Commit
        $wt = $x.Wt
        switch ($Case) {
            'an unstaged edit to a tracked file' { Write-TFile $wt 'Bar/src/visual.ts' 'unsaved work' }
            'an untracked file' { Write-TFile $wt 'Bar/notes.txt' 'my notes' }
            'an extra staged change' { Write-TFile $wt 'Column/src/visual.ts' 'staged'; TGit $wt add -- 'Column/src/visual.ts' | Out-Null }
            'a merge in progress' { [IO.File]::WriteAllText((Join-Path (TGit $wt rev-parse --absolute-git-dir) 'MERGE_HEAD'), (TGit $wt rev-parse HEAD) + "`n") }
            'a missing candidate record' { Remove-Item -LiteralPath (Get-PbivizCandidateRecordPath -Worktree $wt) -Force }
            'a record written for another folder' { $rp = Get-PbivizCandidateRecordPath -Worktree $wt; $j = [IO.File]::ReadAllText($rp) | ConvertFrom-Json; $j.worktree = Join-Path ([IO.Path]::GetTempPath()) 'pbiviz-release-other-000000'; [IO.File]::WriteAllText($rp, ($j | ConvertTo-Json)) }
            'a switched branch' { TGit $wt switch -q -c 'release/pbiviz/Bar/other' | Out-Null }
        }
        $state = Get-TState $wt
        $res = Remove-PbivizPromotionWorktree -Root $x.Repo -WorktreeDir $wt -DiscardApproval "APPROVED:DISCARD-CANDIDATE:$($x.Branch)"
        $res.Status | Should -Be 'BLOCKED'
        $res.Reason | Should -Match '^refused'
        Test-Path -LiteralPath $wt | Should -BeTrue
        @(Compare-PbivizWorkingState -Before $state -After (Get-TState $wt)).Count | Should -Be 0
    }

    It 'refuses an unrelated worktree that only shares the prefix, and a worktree of another repository' {
        $r = New-TL3
        $manual = Join-Path ([IO.Path]::GetTempPath()) ('pbiviz-release-manual-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        TGit $r worktree add -q -b 'release/pbiviz/Bar/manual' $manual PBVIZ_Team_Prod | Out-Null
        try {
            $res = Remove-PbivizPromotionWorktree -Root $r -WorktreeDir $manual -DiscardApproval 'APPROVED:DISCARD-CANDIDATE:release/pbiviz/Bar/manual'
            $res.Status | Should -Be 'BLOCKED'
            $res.Reason | Should -Match 'no candidate record'
            $other = New-TL3
            $res2 = Remove-PbivizPromotionWorktree -Root $other -WorktreeDir $manual
            $res2.Status | Should -Be 'BLOCKED'
            $res2.Reason | Should -Match 'not a registered worktree of this repository'
            Test-Path -LiteralPath $manual | Should -BeTrue
        } finally { TGit $r worktree remove --force $manual | Out-Null }
    }
}

Describe 'Release validation is evidence-based and reads the package content (review finding 2)' {

    BeforeAll {
        function New-TL1 {
            $r = New-TRepo
            New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
            $head = Save-TAll $r 'base'
            return [pscustomobject]@{ Repo = $r; Head = $head; Pkg = (Join-Path $r 'Bar\dist\barGuid0001.1.0.0.1.pbiviz') }
        }
    }

    It 'rejects <Label> and writes nothing' -TestCases @(
        @{ Label = 'random bytes behind a zip signature'; Kind = 'bytes'; Match = 'not a readable zip' },
        @{ Label = 'a zip without package.json'; Kind = 'no-package-json'; Match = 'package\.json is missing' },
        @{ Label = 'content for another GUID under the expected file name'; Kind = 'guid'; Match = 'package content is otherGuid99 1\.0\.0\.1' },
        @{ Label = 'content for another version under the expected file name'; Kind = 'version'; Match = 'package content is barGuid0001 1\.0\.0\.9' },
        @{ Label = 'a resource that disagrees with package.json'; Kind = 'resource'; Match = 'disagree on the visual identity' }
    ) {
        $x = New-TL1
        switch ($Kind) {
            'bytes'           { Write-TBytes -Path $x.Pkg -Seed 3 }
            'no-package-json' { Write-TPackage -Path $x.Pkg -Guid 'barGuid0001' -Version '1.0.0.1' -NoPackageJson }
            'guid'            { Write-TPackage -Path $x.Pkg -Guid 'otherGuid99' -Version '1.0.0.1' }
            'version'         { Write-TPackage -Path $x.Pkg -Guid 'barGuid0001' -Version '1.0.0.9' }
            'resource'        { Write-TPackage -Path $x.Pkg -Guid 'barGuid0001' -Version '1.0.0.1' -ResourceVersion '1.0.0.7' }
        }
        $before = Get-TState $x.Repo
        $res = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head
        $res.Status | Should -Be 'BLOCKED'
        $res.Reason | Should -Match $Match
        Test-Path -LiteralPath (Join-Path $x.Repo 'Bar\releases') | Should -BeFalse
        @(Compare-PbivizWorkingState -Before $before -After (Get-TState $x.Repo)).Count | Should -Be 0
    }

    It 'records validated:false with explicit gaps when no evidence is supplied - never an invented PASS' {
        $x = New-TL1
        Write-TPackage -Path $x.Pkg -Guid 'barGuid0001' -Version '1.0.0.1'
        $res = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head
        $res.Status | Should -Be 'PASS' -Because $res.Reason
        $res.Validated | Should -BeFalse
        $res.ReleaseClass | Should -Be 'DEVELOPMENT/TEST CANDIDATE'
        $res.BuildEvidence | Should -Be 'NONE'
        $m = [IO.File]::ReadAllText($res.ManifestPath) | ConvertFrom-Json
        $m.validated | Should -BeFalse
        foreach ($g in 'no build evidence for these package bytes at the source revision', 'lint NOT RUN', 'unit NOT RUN', 'powerbi-visuals-tools version not recorded', 'Node.js version not recorded', 'no approving review recorded for this source revision') { @($m.validationGaps) | Should -Contain $g }
        @($m.tests.PSObject.Properties.Name) | Should -Not -Contain 'package' -Because 'the package result is never asserted by a caller'
        $m.tests.host | Should -Be 'NOT RUN'
        $m.package.identity | Should -Be 'VERIFIED'
        $m.package.resource | Should -Be 'resources/barGuid0001.pbiviz.json'
        $m.packageSource | Should -Be 'build output'
        $m.build | Should -BeNullOrEmpty
        @($m.PSObject.Properties.Name) | Should -Not -Contain 'buildCommand' -Because 'a build command is recorded only as build evidence'
        @($m.PSObject.Properties.Name) | Should -Not -Contain 'builtAt'
        $m.quality.codeReviewed | Should -Be 'NO EVIDENCE'
        $m.quality.built | Should -Be 'NO EVIDENCE' -Because 'a verified package identity (ZIP metadata) is not evidence of a build'
        $m.quality.hostTested | Should -Be 'NOT RUN'
        $m.quality.certificationReady | Should -Be 'NOT ASSESSED'
        $m.quality.microsoftCertified | Should -Be 'NOT CLAIMED'
    }

    It 'keeps validated:false while a required gate is incomplete (<Missing>)' -TestCases @(
        @{ Missing = 'unit tests'; Build = $true; Unit = 'NOT RUN'; Reviewed = $true; Tools = $null; Gap = 'unit NOT RUN' },
        @{ Missing = 'review'; Build = $true; Unit = 'PASS'; Reviewed = $false; Tools = $null; Gap = 'no approving review recorded' },
        @{ Missing = 'build evidence'; Build = $false; Unit = 'PASS'; Reviewed = $true; Tools = '7.2.2'; Gap = 'no build evidence for these package bytes' },
        @{ Missing = 'toolchain'; Build = $false; Unit = 'PASS'; Reviewed = $true; Tools = $null; Gap = 'powerbi-visuals-tools version not recorded' }
    ) {
        $x = New-TL1
        if ($Build) { (Invoke-TBuild -Dir $x.Repo).Status | Should -Be 'PASS' } else { Write-TPackage -Path $x.Pkg -Guid 'barGuid0001' -Version '1.0.0.1' }
        $review = if ($Reviewed) { @{ reviewer = '084 PBIVIZ Reviewer'; verdict = 'APPROVE'; sourceSha = $x.Head; reference = 'REVIEW VERDICT 1' } } else { $null }
        $node = if ($Build) { $null } else { 'v24.2.0' }
        $res = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head -Tests @{ lint = 'PASS'; unit = $Unit } -ToolsVersion $Tools -NodeVersion $node -Review $review
        $res.Status | Should -Be 'PASS' -Because $res.Reason
        $res.Validated | Should -BeFalse
        ($res.ValidationGaps -join ' | ') | Should -Match ([regex]::Escape($Gap))
        if ($Build) { @($res.ValidationGaps).Count | Should -Be 1 -Because 'only the listed item is missing' }
    }

    It 'marks validated:true only with complete source-bound evidence; host, certification and Microsoft labels stay separate' {
        $x = New-TL1
        $b = Invoke-TBuild -Dir $x.Repo
        $b.Status | Should -Be 'PASS' -Because $b.Reason
        $review = @{ reviewer = '084 PBIVIZ Reviewer'; verdict = 'APPROVE WITH NONBLOCKING NOTES'; sourceSha = $x.Head; visual = 'Bar'; reviewedAt = '2026-11-12T10:00:00Z'; reference = 'REVIEW VERDICT 2' }
        $res = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head -Tests @{ lint = 'PASS'; unit = 'PASS' } -Review $review
        $res.Status | Should -Be 'PASS' -Because $res.Reason
        $res.Validated | Should -BeTrue -Because ($res.ValidationGaps -join '; ')
        $res.ReleaseClass | Should -Be 'OFFICIAL RELEASE'
        $res.BuildEvidence | Should -Be 'VERIFIED'
        $m = [IO.File]::ReadAllText($res.ManifestPath) | ConvertFrom-Json
        $m.toolsVersion | Should -Be '7.2.2' -Because 'the toolchain comes from the build evidence'
        $m.nodeVersion | Should -Be $b.NodeVersion
        $m.build.sourceSha | Should -Be $x.Head
        $m.build.package.sha256 | Should -Be $res.Sha256
        $m.review.sourceSha | Should -Be $x.Head
        $m.quality.codeReviewed | Should -Be 'YES'
        $m.quality.built | Should -Be 'YES'
        $m.quality.hostTested | Should -Be 'NOT RUN'
        $m.quality.certificationReady | Should -Be 'NOT ASSESSED'
        $m.quality.microsoftCertified | Should -Be 'NOT CLAIMED'
        @(Get-PbivizReleasePairProblems -Manifest $m -ManifestPath 'Bar/releases/barGuid0001.1.0.0.1.release.json' -PackageBytes ([IO.File]::ReadAllBytes($res.PackagePath))).Count | Should -Be 0
    }

    It 'BLOCKS <Label> before writing anything' -TestCases @(
        @{ Label = 'a FAIL result'; Tests = @{ unit = 'FAIL' }; Match = "test 'unit' FAILED" },
        @{ Label = 'a caller-asserted package result'; Tests = @{ package = 'PASS' }; Match = 'established from the package content' },
        @{ Label = 'a result outside PASS / FAIL / NOT RUN'; Tests = @{ lint = 'GREEN' }; Match = 'not PASS, FAIL or NOT RUN' },
        @{ Label = 'an unknown test'; Tests = @{ smoke = 'PASS' }; Match = 'unknown test' },
        @{ Label = 'a review of another source revision'; ReviewSha = ('0' * 40); Match = 'review covers' },
        @{ Label = 'a BLOCK review'; Verdict = 'BLOCK'; Match = 'verdict is BLOCK' },
        @{ Label = 'a review verdict outside the vocabulary'; Verdict = 'LGTM'; Match = 'is not APPROVE' },
        @{ Label = 'a toolsVersion contradicting the project-local CLI'; Tools = '6.0.0'; LocalTools = $true; Match = 'contradicts' }
    ) {
        $x = New-TL1
        Write-TPackage -Path $x.Pkg -Guid 'barGuid0001' -Version '1.0.0.1'
        if ($LocalTools) { Write-TFile $x.Repo 'Bar/node_modules/powerbi-visuals-tools/package.json' '{ "version": "7.2.2" }' }
        $review = $null
        if ($ReviewSha -or $Verdict) { $review = @{ reviewer = '084'; verdict = $(if ($Verdict) { $Verdict } else { 'APPROVE' }); sourceSha = $(if ($ReviewSha) { $ReviewSha } else { $x.Head }) } }
        $before = Get-TState $x.Repo
        $res = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head -Tests $Tests -ToolsVersion $Tools -Review $review
        $res.Status | Should -Be 'BLOCKED'
        $res.Reason | Should -Match $Match
        Test-Path -LiteralPath (Join-Path $x.Repo 'Bar\releases') | Should -BeFalse
        @(Compare-PbivizWorkingState -Before $before -After (Get-TState $x.Repo)).Count | Should -Be 0
    }
}

Describe 'Archived pairs are verified against their content, the candidate and the commit (review finding 3)' {

    BeforeAll {
        # Bar imports an allowlisted shared file that changed on Dev; the pair is staged, optionally committed.
        function New-TShared {
            param([switch]$Commit)
            $r = New-TL3
            Write-TFile $r 'shared/fmt.ts' 'export const f = 1;'
            Save-TAll $r 'shared' | Out-Null
            TGit $r branch -f PBVIZ_Team_Prod HEAD | Out-Null
            Write-TFile $r 'shared/fmt.ts' 'export const f = 2;'
            Write-TFile $r 'Bar/src/visual.ts' "import { f } from '../../shared/fmt';`nexport class Visual {}"
            Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
            Save-TAll $r 'bar uses shared' | Out-Null
            $p = Invoke-TPromotion -Repo $r -Allowlist @('shared/fmt.ts')
            $p.Gates.Status | Should -Be 'PASS' -Because $p.Gates.Reason
            if ($Commit) { TGit $p.Candidate.Worktree commit -q -m 'release Bar 1.0.0.2' | Out-Null }
            return [pscustomobject]@{ Repo = $r; Wt = $p.Candidate.Worktree; Branch = $p.Candidate.Branch; Manifest = 'Bar/releases/barGuid0001.1.0.0.2.release.json'; Package = 'Bar/releases/barGuid0001.1.0.0.2.pbiviz' }
        }
        function Set-TManifest {
            param($X, [scriptblock]$Edit)
            $p = Join-Path $X.Wt ($X.Manifest -replace '/', '\')
            $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
            & $Edit $j $X
            [IO.File]::WriteAllText($p, ($j | ConvertTo-Json -Depth 8))
            TGit $X.Wt add -- $X.Manifest | Out-Null
        }
        function Set-TSwappedPackage {
            param($X, [string]$Version, [int]$Seed)
            $pk = Join-Path $X.Wt ($X.Package -replace '/', '\')
            Write-TPackage -Path $pk -Guid 'barGuid0001' -Version $Version -Seed $Seed
            $b = [IO.File]::ReadAllBytes($pk)
            $mp = Join-Path $X.Wt ($X.Manifest -replace '/', '\')
            $j = [IO.File]::ReadAllText($mp) | ConvertFrom-Json
            $j.sha256 = Get-PbivizSha256Hex $b; $j.bytes = $b.Length
            [IO.File]::WriteAllText($mp, ($j | ConvertTo-Json -Depth 8))
            TGit $X.Wt add -- $X.Manifest $X.Package | Out-Null
        }
    }

    It 'keeps commit evidence and source-revision evidence apart, and both verify' {
        $x = New-TShared -Commit
        $i = Test-PbivizReleaseIntegrity -Root $x.Repo -Visual 'Bar' -Version '1.0.0.2' -Commit (TGit $x.Wt rev-parse HEAD)
        $i.Status | Should -Be 'PASS' -Because $i.Reason
        $i.CommitEvidence | Should -Be 'VERIFIED'
        $i.SourceRevision | Should -Be 'VERIFIED'
    }

    It 'reports a source revision missing from the clone as PARTIAL / COMMIT ONLY, never as PASS' {
        $x = New-TShared -Commit
        $clone = New-TDir 'cl'
        Remove-Item -LiteralPath $clone
        TGit $script:Root clone -q --no-tags --single-branch --branch $x.Branch ('file:///' + ($x.Repo -replace '\\', '/')) $clone | Out-Null
        $i = Test-PbivizReleaseIntegrity -Root $clone -Visual 'Bar' -Version '1.0.0.2' -Commit HEAD
        $i.Status | Should -Be 'PARTIAL' -Because 'commit evidence alone is not a fully verified release'
        $i.Verification | Should -Be 'COMMIT ONLY'
        $i.CommitEvidence | Should -Be 'VERIFIED'
        $i.SourceRevision | Should -Be 'NOT AVAILABLE'
        $i.Reason | Should -Match 'NOT fully verified'
    }

    It 'FAILS integrity for a manipulated committed manifest (<Field>)' -TestCases @(
        @{ Field = 'guid'; Edit = { param($j) $j.guid = 'otherGuid99' }; Match = 'do not match its file name' },
        @{ Field = 'packageFile'; Edit = { param($j) $j.packageFile = 'renamed.pbiviz' }; Match = 'is not the paired package' },
        @{ Field = 'sha256'; Edit = { param($j) $j.sha256 = ('0' * 64) }; Match = 'SHA-256 differs' },
        @{ Field = 'sourceFingerprint'; Edit = { param($j) $j.sourceFingerprint = ('a' * 64) }; Match = 'differs from the manifest fingerprint' },
        @{ Field = 'sharedFiles blob'; Edit = { param($j) $j.sharedFiles[0].blob = ('1' * 40) }; Match = "shared file 'shared/fmt.ts'" },
        @{ Field = 'sourceSha'; Edit = { param($j, $x) $s = (TGit $x.Repo rev-parse PBVIZ_Team_Prod); $j.sourceSha = $s; $j.review.sourceSha = $s; $j.build.sourceSha = $s }; Match = 'does not yield the manifest fingerprint' },
        @{ Field = 'validated'; Edit = { param($j) $j.validated = $false }; Match = 'not supported by the recorded evidence' },
        @{ Field = 'quality.hostTested'; Edit = { param($j) $j.quality.hostTested = 'YES' }; Match = 'quality\.hostTested' },
        @{ Field = 'package.version'; Edit = { param($j) $j.package.version = '9.9.9.9' }; Match = 'package\.guid/version \(barGuid0001 9\.9\.9\.9\) differ from the package content' },
        @{ Field = 'package.resource'; Edit = { param($j) $j.package.resource = 'resources/other.pbiviz.json' }; Match = 'package\.resource' },
        @{ Field = 'package.entries'; Edit = { param($j) $j.package.entries = 99 }; Match = 'package\.entries 99' },
        @{ Field = 'build.package.sha256'; Edit = { param($j) $j.build.package.sha256 = ('b' * 64) }; Match = 'build evidence describes other package bytes' },
        @{ Field = 'build.sourceSha'; Edit = { param($j, $x) $j.build.sourceSha = (TGit $x.Repo rev-parse PBVIZ_Team_Prod) }; Match = 'build evidence built from [0-9a-f]{40}, not the release source' },
        @{ Field = 'toolsVersion'; Edit = { param($j) $j.toolsVersion = '1.0.0' }; Match = 'toolchain differs' },
        @{ Field = 'quality.built without build evidence'; Edit = { param($j) $j.build = $null }; Match = 'quality\.built=YES is not supported' },
        @{ Field = 'packageSource'; Edit = { param($j) $j.packageSource = 'external (approved)' }; Match = 'no approval for these exact bytes' },
        @{ Field = 'validationGaps'; Edit = { param($j) $j.validationGaps = @('host NOT RUN') }; Match = 'validationGaps differ from the gaps re-derived' },
        @{ Field = 'validated type'; Edit = { param($j) $j.validated = 'true' }; Match = "validated 'true' is not a JSON boolean" },
        @{ Field = 'tests vocabulary'; Edit = { param($j) $j.tests.host = 'GREEN' }; Match = "tests\.host='GREEN' is outside the evidence vocabulary" }
    ) {
        $x = New-TShared -Commit
        Set-TManifest $x $Edit
        TGit $x.Wt commit -q -m "tamper $Field" | Out-Null
        $i = Test-PbivizReleaseIntegrity -Root $x.Repo -Visual 'Bar' -Version '1.0.0.2' -Commit (TGit $x.Wt rev-parse HEAD)
        $i.Status | Should -Be 'FAILED'
        $i.Reason | Should -Match $Match
    }

    It 'FAILS integrity for <Label>' -TestCases @(
        @{ Label = 'a package swapped for another identity with matching hash and size'; Kind = 'swap'; Match = 'package content identifies barGuid0001 1\.0\.0\.1' },
        @{ Label = 'altered package content'; Kind = 'alter'; Match = 'SHA-256 differs' },
        @{ Label = 'a shared file that differs from the recorded blob at the commit'; Kind = 'shared'; Match = "shared file 'shared/fmt\.ts' at [0-9a-f]{12} is" }
    ) {
        $x = New-TShared -Commit
        switch ($Kind) {
            'swap'   { Set-TSwappedPackage $x '1.0.0.1' 77 }
            'alter'  { Write-TPackage -Path (Join-Path $x.Wt ($x.Package -replace '/', '\')) -Guid 'barGuid0001' -Version '1.0.0.2' -Seed 78; TGit $x.Wt add -- $x.Package | Out-Null }
            'shared' { Write-TFile $x.Wt 'shared/fmt.ts' 'export const f = 3;'; TGit $x.Wt add -- 'shared/fmt.ts' | Out-Null }
        }
        TGit $x.Wt commit -q -m "tamper $Kind" | Out-Null
        $i = Test-PbivizReleaseIntegrity -Root $x.Repo -Visual 'Bar' -Version '1.0.0.2' -Commit (TGit $x.Wt rev-parse HEAD)
        $i.Status | Should -Be 'FAILED'
        $i.Reason | Should -Match $Match
    }

    It 'G6 BLOCKS a staged pair that does not describe the candidate (<Field>)' -TestCases @(
        @{ Field = 'sourceSha'; Edit = { param($j, $x) $j.sourceSha = (TGit $x.Repo rev-parse PBVIZ_Team_Prod) }; Match = 'is not the candidate source' },
        @{ Field = 'sharedFiles blob'; Edit = { param($j) $j.sharedFiles[0].blob = ('1' * 40) }; Match = "sharedFiles 'shared/fmt.ts' blob" },
        @{ Field = 'sharedFiles list'; Edit = { param($j) $j.sharedFiles = @() }; Match = 'sharedFiles paths differ' },
        @{ Field = 'validated claim'; Edit = { param($j) $j.validated = $false }; Match = 'not supported by the recorded evidence' },
        @{ Field = 'swapped package'; Edit = $null; Match = 'package content identifies barGuid0001 1\.0\.0\.1' },
        @{ Field = 'build log digest'; Edit = { param($j) $j.build.logSha256 = ('c' * 64) }; Match = 'build\.logSha256 differs from the local build record' },
        @{ Field = 'level'; Edit = { param($j) $j.level = 'local' }; Match = "level 'local' is not promotion" }
    ) {
        $x = New-TShared
        if ($Edit) { Set-TManifest $x $Edit } else { Set-TSwappedPackage $x '1.0.0.1' 79 }
        $g = Test-PbivizPromotionGates -Worktree $x.Wt -Visual 'Bar' -TargetRef PBVIZ_Team_Prod -Allowlist @('shared/fmt.ts')
        $g.Status | Should -Be 'BLOCKED'
        (Get-TGate $g 'G6').Pass | Should -BeFalse
        (Get-TGate $g 'G6').Detail | Should -Match $Match
    }

    It 'G0 BLOCKS gates run with an allowlist other than the recorded one' {
        $x = New-TShared
        $g = Test-PbivizPromotionGates -Worktree $x.Wt -Visual 'Bar' -TargetRef PBVIZ_Team_Prod
        (Get-TGate $g 'G0').Pass | Should -BeFalse
        (Get-TGate $g 'G0').Detail | Should -Match 'allowlist differs'
    }
}

Describe 'G4 dependency scan prunes while walking and fails closed (review finding 5)' {

    It 'never enumerates dependency, cache or generated trees (performance regression)' {
        $w = New-TDir 'g4'
        Write-TFile $w 'Bar/pbiviz.json' '{ "visual": {} }'
        Write-TFile $w 'Bar/src/visual.ts' "import { x } from './util';`nexport class Visual {}"
        Write-TFile $w 'Bar/src/util.ts' 'export const x = 1;'
        $escape = "import { y } from '" + ('../' * 12) + "outside/y';"
        foreach ($tree in 'node_modules', 'src/node_modules', 'dist', '.tmp', 'coverage', '.cache', 'src/.cache') {
            for ($i = 0; $i -lt 150; $i++) {
                $nest = ((1..6) | ForEach-Object { "d$($i % 5)" }) -join '/'
                Write-TFile $w "Bar/$tree/$nest/f$i.ts" $escape
            }
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $s = Get-PbivizDependencyEscapes -Worktree $w -Visual 'Bar'
        $sw.Stop()
        $s.Complete | Should -BeTrue -Because ($s.Uncertain -join '; ')
        @($s.Escapes).Count | Should -Be 0 -Because 'files inside pruned trees are never read'
        $s.FilesScanned | Should -Be 3
        $s.DirectoriesVisited | Should -Be 2 -Because 'only Bar and Bar/src are listed; 1,050 files in pruned trees are never enumerated'
        foreach ($p in 'node_modules', 'src/node_modules', 'dist', '.tmp', 'coverage', '.cache', 'src/.cache') { @($s.Pruned) | Should -Contain $p }
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
        Write-TFile $w 'Bar/src/bad.ts' $escape
        @((Get-PbivizDependencyEscapes -Worktree $w -Visual 'Bar').Escapes) | Should -Be @("src/bad.ts -> $(('../' * 12))outside/y") -Because 'pruning never hides the source itself'
    }

    It 'never follows a junction or reads an unreadable folder, and reports the analysis as incomplete (<Case>)' -TestCases @(@{ Case = 'junction' }, @{ Case = 'unreadable folder' }) {
        $w = New-TDir 'g4'
        Write-TFile $w 'Bar/src/visual.ts' 'export class Visual {}'
        Write-TFile $w 'outside/secret.ts' "import { z } from '../../../../escape';"
        $link = Join-Path $w 'Bar\src\linked'
        $rule = $null
        if ($Case -eq 'junction') { & cmd.exe /c "mklink /J `"$link`" `"$(Join-Path $w 'outside')`"" | Out-Null; Test-Path -LiteralPath $link | Should -BeTrue }
        else { Write-TFile $w 'Bar/src/locked/inner.ts' "import { z } from '../../../../escape';"; $rule = Set-TDenyList (Join-Path $w 'Bar\src\locked') }
        try {
            $s = Get-PbivizDependencyEscapes -Worktree $w -Visual 'Bar'
            $s.Complete | Should -BeFalse
            ($s.Uncertain -join ' ') | Should -Match $(if ($Case -eq 'junction') { "not followed: 'src/linked'" } else { "cannot read folder 'src/locked'" })
            @($s.Escapes).Count | Should -Be 0 -Because 'nothing behind the link or the locked folder was read'
        } finally {
            if ($Case -eq 'junction') { [IO.Directory]::Delete($link) } else { Clear-TDeny (Join-Path $w 'Bar\src\locked') $rule }
        }
    }

    It 'G4 fails closed on an incomplete analysis inside a candidate' {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'PASS' -Because $p.Gates.Reason
        $outside = New-TDir 'out'
        $link = Join-Path $p.Candidate.Worktree 'Bar\src\linked'
        & cmd.exe /c "mklink /J `"$link`" `"$outside`"" | Out-Null
        try {
            $g = Test-PbivizPromotionGates -Worktree $p.Candidate.Worktree -Visual 'Bar' -TargetRef PBVIZ_Team_Prod
            $g.Status | Should -Be 'BLOCKED'
            (Get-TGate $g 'G4').Pass | Should -BeFalse
            (Get-TGate $g 'G4').Detail | Should -Match 'analysis incomplete \(fail closed\)'
        } finally { [IO.Directory]::Delete($link) }
    }
}

Describe 'Level 3 promotes only validated releases; unvalidated packages stay development/test candidates (final review 1)' {

    It 'Add-PbivizRelease -Worktree BLOCKS an unvalidated release (missing <Missing>) and writes nothing' -TestCases @(
        @{ Missing = 'build evidence'; Build = $false; Unit = 'PASS'; NoReview = $false; Gap = 'no build evidence for these package bytes' },
        @{ Missing = 'unit tests'; Build = $true; Unit = 'NOT RUN'; NoReview = $false; Gap = 'unit NOT RUN' },
        @{ Missing = 'review'; Build = $true; Unit = 'PASS'; NoReview = $true; Gap = 'no approving review recorded' }
    ) {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $c = New-PbivizPromotionCandidate -Root $r -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod
        $c.Status | Should -Be 'PASS' -Because $c.Reason
        if ($Build) { (Invoke-TBuild -Dir $c.Worktree -Worktree).Status | Should -Be 'PASS' }
        else { Write-TPackage -Path (Join-Path $c.Worktree "Bar\dist\$($c.Guid).$($c.Version).pbiviz") -Guid $c.Guid -Version $c.Version -Seed 4 }
        $ev = Get-TEvidence -Sha $c.Source -Unit $Unit -NoReview:$NoReview
        $res = Add-PbivizRelease -Worktree $c.Worktree -Visual 'Bar' -SourceSha $c.Source @ev
        $res.Status | Should -Be 'BLOCKED'
        $res.Reason | Should -Match 'Level 3 promotes only validated releases'
        $res.Reason | Should -Match ([regex]::Escape($Gap))
        $res.ReleaseClass | Should -Be 'DEVELOPMENT/TEST CANDIDATE'
        Test-Path -LiteralPath (Join-Path $c.Worktree 'Bar\releases') | Should -BeFalse
        (Test-PbivizCandidateState -Worktree $c.Worktree).Status | Should -Be 'PASS' -Because 'the candidate is unchanged'
    }

    It 'G6 BLOCKS an internally consistent unvalidated pair that bypassed Add-PbivizRelease' {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'PASS' -Because $p.Gates.Reason
        $wt = $p.Candidate.Worktree
        $rel = 'Bar/releases/barGuid0001.1.0.0.2.release.json'
        $mp = Join-Path $wt ($rel -replace '/', '\')
        $j = [IO.File]::ReadAllText($mp) | ConvertFrom-Json
        $j.review = $null
        $v = Get-PbivizValidationVerdict -Tests $j.tests -Review $null -SourceSha $j.sourceSha -ToolsVersion $j.toolsVersion -NodeVersion $j.nodeVersion -PackageVerified $true -BuildVerified $true
        $j.validated = $v.Validated; $j.validationGaps = @($v.Gaps); $j.quality = $v.Quality
        [IO.File]::WriteAllText($mp, ($j | ConvertTo-Json -Depth 8))
        TGit $wt add -- $rel | Out-Null
        $pkg = [IO.File]::ReadAllBytes((Join-Path $wt 'Bar\releases\barGuid0001.1.0.0.2.pbiviz'))
        @(Get-PbivizReleasePairProblems -Manifest ([IO.File]::ReadAllText($mp) | ConvertFrom-Json) -ManifestPath $rel -PackageBytes $pkg).Count | Should -Be 0 -Because 'the forged pair is internally consistent'
        $g = Test-PbivizPromotionGates -Worktree $wt -Visual 'Bar' -TargetRef PBVIZ_Team_Prod
        $g.Status | Should -Be 'BLOCKED'
        (Get-TGate $g 'G6').Pass | Should -BeFalse
        (Get-TGate $g 'G6').Detail | Should -Match 'validated is false - Level 3 promotes only validated releases'
    }

    It 'archive-only promotion BLOCKS an unvalidated Dev release; labelled legacy history is admitted' {
        $r = New-TL3
        New-TReleasePair $r 'Bar' 'barGuid0001' '1.0.0.1'
        New-TReleasePair $r 'Bar' 'barGuid0001' '0.5.0.0' -Origin 'legacy-archive' -Sub 'legacy' -Seed 9
        Save-TAll $r 'dev archive' | Out-Null
        $c = New-PbivizPromotionCandidate -Root $r -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod -ArchiveOnly
        $c.Status | Should -Be 'PASS' -Because $c.Reason
        $g = Test-PbivizPromotionGates -Worktree $c.Worktree -Visual 'Bar' -TargetRef PBVIZ_Team_Prod -ArchiveOnly
        $g.Status | Should -Be 'BLOCKED'
        $d = (Get-TGate $g 'G6').Detail
        $d | Should -Match 'barGuid0001\.1\.0\.0\.1\.release\.json: validated is false - a DEVELOPMENT/TEST CANDIDATE never enters Prod'
        $d | Should -Not -Match 'legacy/barGuid0001\.0\.5\.0\.0\.release\.json'
        $r2 = New-TL3
        New-TReleasePair $r2 'Bar' 'barGuid0001' '0.5.0.0' -Origin 'legacy-archive' -Sub 'legacy' -Seed 9
        Save-TAll $r2 'legacy only' | Out-Null
        $c2 = New-PbivizPromotionCandidate -Root $r2 -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod -ArchiveOnly
        $g2 = Test-PbivizPromotionGates -Worktree $c2.Worktree -Visual 'Bar' -TargetRef PBVIZ_Team_Prod -ArchiveOnly
        $g2.Status | Should -Be 'PASS' -Because $g2.Reason
    }

    It 'Level 1 keeps an unvalidated release as a DEVELOPMENT/TEST CANDIDATE and integrity reports the class' {
        $r = New-TRepo
        New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
        $head = Save-TAll $r 'base'
        Write-TPackage -Path (Join-Path $r 'Bar\dist\barGuid0001.1.0.0.1.pbiviz') -Guid 'barGuid0001' -Version '1.0.0.1'
        $res = Add-PbivizRelease -Root $r -Visual 'Bar' -SourceSha $head
        $res.Status | Should -Be 'PASS' -Because $res.Reason
        $res.ReleaseClass | Should -Be 'DEVELOPMENT/TEST CANDIDATE'
        ($res.Evidence -join ' ') | Should -Match 'never presented or distributed as an official release'
        TGit $r commit -q -m 'release candidate 1.0.0.1' | Out-Null
        $i = Test-PbivizReleaseIntegrity -Root $r -Visual 'Bar' -Version '1.0.0.1' -Commit HEAD
        $i.Status | Should -Be 'PASS' -Because $i.Reason
        $i.Verification | Should -Be 'COMPLETE'
        $i.Validated | Should -BeFalse
        $i.ReleaseClass | Should -Be 'DEVELOPMENT/TEST CANDIDATE'
        ($i.Evidence -join ' ') | Should -Match 'never presented or distributed as an official production release'
    }
}

Describe 'Integrity separates complete verification from commit-only evidence (final review 2)' {

    It 'reports PASS only for COMPLETE verification of an official release; a failure carries no class' {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'PASS' -Because $p.Gates.Reason
        $wt = $p.Candidate.Worktree
        TGit $wt commit -q -m 'release Bar 1.0.0.2' | Out-Null
        $i = Test-PbivizReleaseIntegrity -Root $r -Visual 'Bar' -Version '1.0.0.2' -Commit (TGit $wt rev-parse HEAD)
        $i.Status | Should -Be 'PASS' -Because $i.Reason
        $i.Verification | Should -Be 'COMPLETE'
        $i.SourceRevision | Should -Be 'VERIFIED'
        $i.Validated | Should -BeTrue
        $i.ReleaseClass | Should -Be 'OFFICIAL RELEASE'
        $mp = Join-Path $wt 'Bar\releases\barGuid0001.1.0.0.2.release.json'
        $j = [IO.File]::ReadAllText($mp) | ConvertFrom-Json
        $j.bytes = 1
        [IO.File]::WriteAllText($mp, ($j | ConvertTo-Json -Depth 8))
        TGit $wt add -- 'Bar/releases/barGuid0001.1.0.0.2.release.json' | Out-Null
        TGit $wt commit -q -m 'tamper size' | Out-Null
        $f = Test-PbivizReleaseIntegrity -Root $r -Visual 'Bar' -Version '1.0.0.2' -Commit (TGit $wt rev-parse HEAD)
        $f.Status | Should -Be 'FAILED'
        $f.Verification | Should -Be 'NONE'
        $f.ReleaseClass | Should -BeNullOrEmpty
    }
}

Describe 'Release packages carry build evidence bound to the source revision (final review 3)' {

    BeforeAll {
        function New-TB1 {
            $r = New-TRepo
            New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
            $head = Save-TAll $r 'base'
            return [pscustomobject]@{ Repo = $r; Head = $head; Pkg = (Join-Path $r 'Bar\dist\barGuid0001.1.0.0.1.pbiviz'); Records = (Join-Path $r '.git\pbiviz-builds') }
        }
    }

    It 'Invoke-PbivizBuild runs the project-local CLI on a clean checkout and records the evidence' {
        $x = New-TB1
        $b = Invoke-TBuild -Dir $x.Repo
        $b.Status | Should -Be 'PASS' -Because $b.Reason
        $b.SourceSha | Should -Be $x.Head
        $b.PackagePath | Should -Be $x.Pkg
        $b.Sha256 | Should -Be (Get-PbivizFileSha256 $x.Pkg)
        $b.RecordPath | Should -Be (Join-Path $x.Records "$($b.Sha256).json")
        $text = [IO.File]::ReadAllText($b.RecordPath)
        $rec = $text | ConvertFrom-Json
        $rec.sourceSha | Should -Be $x.Head
        $rec.sourceFingerprint | Should -Be (Get-PbivizSourceFingerprint -Root $x.Repo -TreeIsh $x.Head -Visual 'Bar')
        $rec.toolsVersion | Should -Be '7.2.2'
        $rec.nodeVersion | Should -Be ((& node --version) | Out-String).Trim()
        $rec.exitCode | Should -Be 0
        $rec.command | Should -BeExactly 'node node_modules/powerbi-visuals-tools/bin/pbiviz.js package'
        $rec.package.sha256 | Should -Be $b.Sha256
        $rec.package.guid | Should -Be 'barGuid0001'
        $text | Should -Not -Match ([regex]::Escape($x.Repo.Replace('\', '\\'))) -Because 'no local absolute path is recorded (the evidence is archived and pushed)'
        Test-Path -LiteralPath (Join-Path $x.Records "$($b.Sha256).log") | Should -BeTrue
    }

    It 'refuses to build <Case>; nothing is run or recorded' -TestCases @(
        @{ Case = 'without the project-local CLI (never downloads)'; Match = 'not installed in Bar/node_modules - the helper never downloads.*APPROVED:INSTALL:Bar' },
        @{ Case = 'with an uncommitted tracked change'; Match = 'clean checkout.*uncommitted' },
        @{ Case = 'with an untracked file in the visual'; Match = 'clean checkout.*untracked' },
        @{ Case = 'with an ignored source file in the visual'; Match = 'ignored files inside the visual.*Bar/src/secret\.ts' },
        @{ Case = 'with an assume-unchanged entry'; Match = 'assume-unchanged or skip-worktree.*Bar/src/visual\.ts' },
        @{ Case = 'over an existing dist package (never overwritten)'; Match = 'already exists - a package is never overwritten' }
    ) {
        $x = New-TB1
        if ($Case -notmatch 'project-local') { Install-TFakeTools -Dir $x.Repo }
        switch -Wildcard ($Case) {
            '*uncommitted*'      { Write-TFile $x.Repo 'Bar/capabilities.json' '{ "edited": true }' }
            '*untracked*'        { Write-TFile $x.Repo 'Bar/notes.ts' 'x' }
            '*ignored source*'   { [IO.File]::AppendAllText((Join-Path $x.Repo '.git\info\exclude'), "Bar/src/secret.ts`n"); Write-TFile $x.Repo 'Bar/src/secret.ts' 'export const s = 1;' }
            '*assume-unchanged*' { TGit $x.Repo update-index --assume-unchanged -- 'Bar/src/visual.ts' | Out-Null; Write-TFile $x.Repo 'Bar/src/visual.ts' 'hidden edit' }
            '*existing dist*'    { Write-TPackage -Path $x.Pkg -Guid 'barGuid0001' -Version '1.0.0.1' -Seed 2 }
        }
        $before = if (Test-Path -LiteralPath $x.Pkg) { Get-PbivizFileSha256 $x.Pkg } else { 'absent' }
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
        $b.Status | Should -Be 'BLOCKED'
        $b.Reason | Should -Match $Match
        Test-Path -LiteralPath $x.Records | Should -BeFalse
        $(if (Test-Path -LiteralPath $x.Pkg) { Get-PbivizFileSha256 $x.Pkg } else { 'absent' }) | Should -Be $before
    }

    It 'records no evidence when the build <Case>' -TestCases @(
        @{ Case = 'fails'; Mode = 'fail'; Match = 'pbiviz package failed \(exit 1\): error: fake build failure' },
        @{ Case = 'rewrites a tracked source file'; Mode = 'touch'; Match = 'the build changed the repository state' },
        @{ Case = 'produces no package'; Mode = 'none'; Match = 'did not produce dist/barGuid0001\.1\.0\.0\.1\.pbiviz' }
    ) {
        $x = New-TB1
        $b = Invoke-TBuild -Dir $x.Repo -Mode $Mode
        $b.Status | Should -Be 'FAILED'
        $b.Reason | Should -Match $Match
        Test-Path -LiteralPath $x.Records | Should -BeFalse
    }

    It 'stops a build that exceeds the timeout and records no evidence' {
        $x = New-TB1
        Install-TFakeTools -Dir $x.Repo -Mode 'hang'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar' -TimeoutSeconds 3
        $sw.Stop()
        $b.Status | Should -Be 'FAILED'
        $b.Reason | Should -Match 'pbiviz package timed out after 3 s - no build evidence recorded'
        $b.ExitCode | Should -Be -2
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 120 -Because 'the hung CLI is stopped at the timeout, not awaited'
        Test-Path -LiteralPath $x.Records | Should -BeFalse
        Test-Path -LiteralPath $x.Pkg | Should -BeFalse
    }

    It 'stops the whole process tree when the CLI <Case>: no orphan, no late package write, no evidence (final hardening 3)' -TestCases @(
        @{ Case = 'hangs past the timeout while a detached child holds its output handles'; Mode = 'spawn-hang'; Match = 'pbiviz package timed out after 3 s - no build evidence recorded; its whole process tree was stopped \(including 1 descendant process'; Limit = 25 },
        @{ Case = 'exits at once but leaves a detached child running on its output handles'; Mode = 'spawn-exit'; Match = 'pbiviz package exited but left 1 process\(es\) of its tree running; they were stopped .* no build evidence recorded'; Limit = 20 }
    ) {
        $x = New-TB1
        Install-TFakeTools -Dir $x.Repo -Mode $Mode
        $tools = Join-Path $x.Repo 'Bar\node_modules\powerbi-visuals-tools'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar' -TimeoutSeconds 3
        $returned = $sw.Elapsed.TotalSeconds
        $b.Status | Should -Be 'FAILED'
        $b.Reason | Should -Match $Match
        $returned | Should -BeLessThan $Limit -Because 'inherited output handles never hold the call past its timeout'
        $childPid = [int]([IO.File]::ReadAllText((Join-Path $tools 'child.pid')).Trim())
        $childPid | Should -BeGreaterThan 0
        Get-Process -Id $childPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the detached descendant was terminated with the tree'
        # The child would have written the package 6 s after it started; wait well past that.
        $wait = 10 - $sw.Elapsed.TotalSeconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }
        Test-Path -LiteralPath (Join-Path $tools 'late-write.txt') | Should -BeFalse -Because 'no process of the build survived to write late'
        Test-Path -LiteralPath $x.Pkg | Should -BeFalse
        Test-Path -LiteralPath $x.Records | Should -BeFalse
    }

    It 'builds inside a release candidate only in its authorised state' {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $c = New-PbivizPromotionCandidate -Root $r -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod
        $c.Status | Should -Be 'PASS' -Because $c.Reason
        Write-TFile $c.Worktree 'Bar/src/visual.ts' 'edited after the snapshot'
        $b = Invoke-TBuild -Dir $c.Worktree -Worktree
        $b.Status | Should -Be 'BLOCKED'
        $b.Reason | Should -Match 'candidate state'
        Test-Path -LiteralPath (Join-Path $c.Worktree "Bar\dist\$($c.Guid).$($c.Version).pbiviz") | Should -BeFalse
    }

    It 'accepts a package outside the visual dist folder only with approval for its exact bytes' {
        $x = New-TB1
        (Invoke-TBuild -Dir $x.Repo).Status | Should -Be 'PASS'
        $ext = Join-Path (New-TDir 'ext') 'barGuid0001.1.0.0.1.pbiviz'
        Copy-Item -LiteralPath $x.Pkg -Destination $ext
        $sha = Get-PbivizFileSha256 $ext
        $before = Get-TState $x.Repo
        $no = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head -PackagePath $ext
        $no.Status | Should -Be 'BLOCKED'
        $no.Reason | Should -Match ('external package: .* -ExternalPackageApproval ''APPROVED:EXTERNAL-PACKAGE:Bar:' + $sha + '''')
        $wrong = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head -PackagePath $ext -ExternalPackageApproval ('APPROVED:EXTERNAL-PACKAGE:Bar:' + ('0' * 64))
        $wrong.Status | Should -Be 'BLOCKED'
        Test-Path -LiteralPath (Join-Path $x.Repo 'Bar\releases') | Should -BeFalse
        @(Compare-PbivizWorkingState -Before $before -After (Get-TState $x.Repo)).Count | Should -Be 0
        $ev = Get-TEvidence -Sha $x.Head
        $ok = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head -PackagePath $ext -ExternalPackageApproval "APPROVED:EXTERNAL-PACKAGE:Bar:$sha" @ev
        $ok.Status | Should -Be 'PASS' -Because $ok.Reason
        $ok.PackageSource | Should -Be 'external (approved)'
        $ok.BuildEvidence | Should -Be 'VERIFIED' -Because 'the build evidence follows the exact bytes, wherever the file sits'
        $m = [IO.File]::ReadAllText($ok.ManifestPath) | ConvertFrom-Json
        $m.packageSource | Should -Be 'external (approved)'
        $m.externalApproval | Should -Be "APPROVED:EXTERNAL-PACKAGE:Bar:$sha"
        @(Get-PbivizReleasePairProblems -Manifest $m -ManifestPath 'Bar/releases/barGuid0001.1.0.0.1.release.json' -PackageBytes ([IO.File]::ReadAllBytes($ok.PackagePath))).Count | Should -Be 0
    }

    It 'treats <Case> as an external package' -TestCases @(@{ Case = 'another file name in dist' }, @{ Case = 'a dist folder that is a junction' }) {
        $x = New-TB1
        (Invoke-TBuild -Dir $x.Repo).Status | Should -Be 'PASS'
        $link = $null
        if ($Case -like 'another*') { $path = Join-Path $x.Repo 'Bar\dist\copy.pbiviz'; Copy-Item -LiteralPath $x.Pkg -Destination $path }
        else {
            $real = New-TDir 'realdist'
            Copy-Item -LiteralPath $x.Pkg -Destination (Join-Path $real 'barGuid0001.1.0.0.1.pbiviz')
            Remove-Item -LiteralPath (Join-Path $x.Repo 'Bar\dist') -Recurse -Force
            $link = Join-Path $x.Repo 'Bar\dist'
            & cmd.exe /c "mklink /J `"$link`" `"$real`"" | Out-Null
            $path = $x.Pkg
        }
        try {
            $res = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head -PackagePath $path
            $res.Status | Should -Be 'BLOCKED'
            $res.Reason | Should -Match 'external package'
        } finally { if ($link) { [IO.Directory]::Delete($link) } }
    }

    It 'BLOCKS <Label>' -TestCases @(
        @{ Label = 'a package whose build evidence names another source revision'; Kind = 'other-source'; Match = 'built from source revision [0-9a-f]{40}, not the release source' },
        @{ Label = 'a build record edited to name the release source'; Kind = 'edited-record'; Match = 'fingerprint differs from the release source' },
        @{ Label = 'a toolchain claim that contradicts the build evidence'; Kind = 'tools-claim'; Match = 'contradicts the build evidence' }
    ) {
        $x = New-TB1
        $b = Invoke-TBuild -Dir $x.Repo
        $b.Status | Should -Be 'PASS' -Because $b.Reason
        $src = $x.Head; $tools = $null
        if ($Kind -ne 'tools-claim') {
            Write-TFile $x.Repo 'Bar/src/visual.ts' 'export class Visual { changed = true }'
            $src = Save-TAll $x.Repo 'source changed, same version'
        } else { $tools = '6.0.0' }
        if ($Kind -eq 'edited-record') {
            $rec = [IO.File]::ReadAllText($b.RecordPath) | ConvertFrom-Json
            $rec.sourceSha = $src
            [IO.File]::WriteAllText($b.RecordPath, ($rec | ConvertTo-Json -Depth 8))
        }
        $before = Get-TState $x.Repo
        $res = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $src -ToolsVersion $tools
        $res.Status | Should -Be 'BLOCKED'
        $res.Reason | Should -Match $Match
        Test-Path -LiteralPath (Join-Path $x.Repo 'Bar\releases') | Should -BeFalse
        @(Compare-PbivizWorkingState -Before $before -After (Get-TState $x.Repo)).Count | Should -Be 0
    }

    It 'G6 BLOCKS a staged pair whose build evidence has no local build record' {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'PASS' -Because $p.Gates.Reason
        Remove-Item -LiteralPath (Join-Path (Get-PbivizBuildRecordDir -Directory $r) "$($p.Release.Sha256).json")
        $g = Test-PbivizPromotionGates -Worktree $p.Candidate.Worktree -Visual 'Bar' -TargetRef PBVIZ_Team_Prod
        $g.Status | Should -Be 'BLOCKED'
        (Get-TGate $g 'G6').Detail | Should -Match 'no local build record for these package bytes'
    }
}

Describe 'G4 classifies every dependency form the PBIVIZ toolchain resolves and fails closed (final hardening 2)' {

    BeforeAll {
        # A visual folder Bar inside a scratch worktree root, plus the given files (repository-relative).
        function New-TG4 {
            param([hashtable]$Files)
            $w = New-TDir 'g4f'
            Write-TFile $w 'Bar/pbiviz.json' '{ "visual": { "name": "Bar", "guid": "barGuid0001", "version": "1.0.0.1" }, "style": "style/visual.less", "capabilities": "capabilities.json" }'
            Write-TFile $w 'Bar/src/visual.ts' 'export class Visual {}'
            foreach ($k in $Files.Keys) { Write-TFile $w $k $Files[$k] }
            return $w
        }
    }

    It 'an unapproved dependency outside the visual never passes silently: <Case>' -TestCases @(
        @{ Case = 'side-effect import'; File = 'Bar/src/a.ts'; Text = "import '../../shared/side';"; Escape = 'src/a.ts -> ../../shared/side' },
        @{ Case = 'template-literal dynamic import'; File = 'Bar/src/a.ts'; Text = 'export const load = (n: string) => import(`../../shared/${n}.js`);'; Escape = 'src/a.ts -> ../../shared/<computed> (a folder' },
        @{ Case = 'string-concatenated require'; File = 'Bar/src/a.ts'; Text = "const m = require('../../shared/' + n);"; Escape = 'src/a.ts -> ../../shared/<computed> (a folder' },
        @{ Case = 'require.context'; File = 'Bar/src/a.ts'; Text = "const c = require.context('../../shared', true, /\.ts$/);"; Escape = 'src/a.ts -> ../../shared (a folder' },
        @{ Case = 'import.meta.webpackContext'; File = 'Bar/src/a.ts'; Text = "const c = import.meta.webpackContext('../../shared');"; Escape = 'src/a.ts -> ../../shared (a folder' },
        @{ Case = 'new URL asset'; File = 'Bar/src/a.ts'; Text = "const u = new URL('../../shared/worker.js', import.meta.url);"; Escape = 'src/a.ts -> ../../shared/worker.js' },
        @{ Case = 'require.resolve'; File = 'Bar/src/a.js'; Text = "const p = require.resolve('../../shared/x');"; Escape = 'src/a.js -> ../../shared/x' },
        @{ Case = 'absolute path import'; File = 'Bar/src/a.ts'; Text = "import x from 'C:/shared/x';"; Escape = 'src/a.ts -> C:/shared/x' },
        @{ Case = 'triple-slash reference'; File = 'Bar/src/a.ts'; Text = '/// <reference path="../../shared/types.d.ts" />'; Escape = 'src/a.ts -> ../../shared/types.d.ts' },
        @{ Case = 'import written in a comment (raw safety net)'; File = 'Bar/src/a.ts'; Text = "// import x from '../../shared/x';"; Escape = 'src/a.ts -> ../../shared/x' },
        @{ Case = 'LESS @import with options'; File = 'Bar/style/b.less'; Text = "@import (reference) '../../shared/x.less';"; Escape = 'style/b.less -> ../../shared/x.less' },
        @{ Case = 'CSS url()'; File = 'Bar/style/b.css'; Text = '.a { background: url(../../shared/i.png); }'; Escape = 'style/b.css -> ../../shared/i.png' },
        @{ Case = 'tsconfig extends'; File = 'Bar/tsconfig.json'; Text = '{ "extends": "../tsconfig.base.json" }'; Escape = 'tsconfig.json -> ../tsconfig.base.json' },
        @{ Case = 'tsconfig baseUrl above the visual'; File = 'Bar/tsconfig.json'; Text = '{ "compilerOptions": { "baseUrl": ".." } }'; Escape = 'tsconfig.json -> ..' },
        @{ Case = 'tsconfig paths alias'; File = 'Bar/tsconfig.json'; Text = '{ "compilerOptions": { "paths": { "@shared/*": ["../shared/*"] } } }'; Escape = 'tsconfig.json -> ../shared/*' },
        @{ Case = 'package.json file: dependency'; File = 'Bar/package.json'; Text = '{ "dependencies": { "s": "file:../shared" } }'; Escape = 'package.json -> ../shared' },
        @{ Case = 'absolute path in pbiviz.json'; File = 'Bar/pbiviz.json'; Text = '{ "visual": {}, "assets": { "icon": "/icons/x.png" } }'; Escape = 'pbiviz.json -> /icons/x.png' },
        @{ Case = 'npm workspaces at the repository root'; File = 'package.json'; Text = '{ "workspaces": ["*"] }'; Escape = 'package.json -> npm workspaces at the repository root' }
    ) {
        $w = New-TG4 @{ $File = $Text }
        $s = Get-PbivizDependencyEscapes -Worktree $w -Visual 'Bar'
        (@($s.Escapes) -join ' || ') | Should -Match ([regex]::Escape($Escape))
    }

    It 'reports a request it cannot classify as incomplete, so G4 fails closed: <Case>' -TestCases @(
        @{ Case = 'computed dynamic import'; File = 'Bar/src/a.ts'; Text = 'const m = import(base + n);'; Match = 'src/a\.ts:1: import\(\) with a computed request' },
        @{ Case = 'require of a variable'; File = 'Bar/src/a.js'; Text = "const n = 'x';`nconst m = require(n);"; Match = 'src/a\.js:2: require\(\) with a computed request' },
        @{ Case = 'require.ensure'; File = 'Bar/src/a.js'; Text = 'require.ensure([], () => {});'; Match = 'require\.ensure\(\) with a computed request' },
        @{ Case = 'package not declared by the visual'; File = 'Bar/src/a.ts'; Text = "import x from 'lodash';"; Match = "package 'lodash' is neither declared in its package\.json nor locked in its package-lock\.json" },
        @{ Case = 'inline loader syntax'; File = 'Bar/src/a.ts'; Text = "import x from 'raw-loader!./x.txt';"; Match = 'inline loader syntax' },
        @{ Case = 'package.json subpath import'; File = 'Bar/src/a.ts'; Text = "import x from '#shared';"; Match = "subpath import '#shared'" },
        @{ Case = 'package request climbing out of its folder'; File = 'Bar/src/a.ts'; Text = "import x from 'd3/../../shared/x';"; Match = 'climbs out of a package folder' },
        @{ Case = 'LESS ~package not declared'; File = 'Bar/style/b.less'; Text = "@import '~somepkg/x.less';"; Match = "package 'somepkg'" },
        @{ Case = 'LESS interpolated import'; File = 'Bar/style/b.less'; Text = "@import '@{root}/x.less';"; Match = '@import with a computed request' },
        @{ Case = 'executable pbiviz.mjs'; File = 'Bar/pbiviz.mjs'; Text = 'export default {}'; Match = 'pbiviz\.mjs: powerbi-visuals-tools runs it as JavaScript' },
        @{ Case = 'node_modules at the repository root'; File = 'node_modules/x/index.js'; Text = 'x'; Match = 'node_modules/ exists at the repository root' }
    ) {
        $w = New-TG4 @{ $File = $Text }
        $s = Get-PbivizDependencyEscapes -Worktree $w -Visual 'Bar'
        $s.Complete | Should -BeFalse
        (@($s.Uncertain) -join ' || ') | Should -Match $Match
    }

    It 'passes a template-style visual: declared and lockfile-transitive packages, an internal context, strings and regex literals that only look like requests' {
        $w = New-TG4 @{
            'Bar/package.json'        = '{ "dependencies": { "d3": "7.9.0", "powerbi-visuals-utils-formattingmodel": "6.1.1" }, "devDependencies": { "powerbi-visuals-tools": "7.0.3", "eslint-plugin-powerbi-visuals": "1.1.0" } }'
            'Bar/package-lock.json'   = '{ "lockfileVersion": 3, "packages": { "": { "name": "bar" }, "node_modules/d3": { "version": "7.9.0" }, "node_modules/d3-array": { "version": "3.2.4" }, "node_modules/@types/d3": { "version": "7.4.3" } } }'
            'Bar/tsconfig.json'       = '{ "compilerOptions": { "target": "es2022", "outDir": "./.tmp/build/", "lib": ["es2022", "dom"] }, "files": ["./src/visual.ts"] }'
            'Bar/eslint.config.mjs'   = "import powerbiVisualsConfigs from `"eslint-plugin-powerbi-visuals`";`nexport default [powerbiVisualsConfigs.configs.recommended];"
            'Bar/src/visual.ts'       = @'
"use strict";
import "./../style/visual.less";
import powerbi from "powerbi-visuals-api";
import { formattingSettings, FormattingSettingsService } from "powerbi-visuals-utils-formattingmodel";
import * as d3 from "d3";
import { max } from "d3-array";
import * as fs from "node:fs";
import FormattingSettingsCard = formattingSettings.SimpleCard;
import { VisualFormattingSettingsModel } from "./settings";
/// <reference types="d3" />
const looksLikeCode = 'require(name) and import(base + n)';
const re = /import\(x\)|require\(y\)/g;
const half = (a: number) => a / 2 / 1;
export async function locale(l: string) { return import(`./locales/${l}.json`); }
export class Visual {}
'@
            'Bar/src/settings.ts'     = 'export class VisualFormattingSettingsModel {}'
            'Bar/src/locales/en.json' = '{ "hello": "Hello" }'
            'Bar/style/visual.less'   = "@import (reference) `"./vars`";`n// @import '../../shared/commented.less';`n.a { color: @c; background: url(`"data:image/png;base64,AAAA`"); }"
            'Bar/style/vars.less'     = '@c: red;'
            'Bar/capabilities.json'   = '{ "dataRoles": [] }'
        }
        $s = Get-PbivizDependencyEscapes -Worktree $w -Visual 'Bar'
        $s.Complete | Should -BeTrue -Because ($s.Uncertain -join '; ')
        @($s.Escapes).Count | Should -Be 0 -Because ($s.Escapes -join '; ')
        $s.References | Should -BeGreaterThan 9
    }

    It 'allowlists only files a static request resolves to - never a folder request' {
        $w = New-TG4 @{ 'shared/a.js' = 'x'; 'Bar/src/a.ts' = "import x from '../../shared/a';" }
        @((Get-PbivizDependencyEscapes -Worktree $w -Visual 'Bar' -Allowlist @('shared/a.js')).Escapes).Count | Should -Be 0 -Because 'the request resolves to the allowlisted file'
        @((Get-PbivizDependencyEscapes -Worktree $w -Visual 'Bar' -Allowlist @('shared/b.js')).Escapes) | Should -Be @('src/a.ts -> ../../shared/a')
        $w2 = New-TG4 @{ 'shared/a.js' = 'x'; 'Bar/src/a.ts' = "const c = require.context('../../shared');" }
        @((Get-PbivizDependencyEscapes -Worktree $w2 -Visual 'Bar' -Allowlist @('shared/a.js')).Escapes) | Should -Be @('src/a.ts -> ../../shared (a folder: every file below it can be bundled, so it can never be allowlisted)')
    }

    It 'G4 BLOCKS a Level 3 candidate that loads shared code through a template-literal import, even with a shared file allowlisted' {
        $r = New-TL3
        Write-TFile $r 'shared/fmt.ts' 'export const f = 1;'
        Save-TAll $r 'shared' | Out-Null
        TGit $r branch -f PBVIZ_Team_Prod HEAD | Out-Null
        Write-TFile $r 'shared/fmt.ts' 'export const f = 2;'
        Write-TFile $r 'Bar/src/visual.ts' ('export const load = (n: string) => import(`../../shared/${n}`);' + "`nexport class Visual {}")
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar loads shared code dynamically' | Out-Null
        $p = Invoke-TPromotion -Repo $r -Allowlist @('shared/fmt.ts')
        $p.Gates.Status | Should -Be 'BLOCKED'
        $g4 = Get-TGate $p.Gates 'G4'
        $g4.Pass | Should -BeFalse
        $g4.Detail | Should -Match 'dependencies resolve outside the visual folder and are not allowlisted: src/visual\.ts -> \.\./\.\./shared/<computed>'
    }
}

Describe 'Archiving is transactional: a failed release leaves nothing half-created (final hardening 4)' {

    BeforeAll {
        # Level 1: a clean checkout with a verified build of HEAD; -Existing adds a committed user file
        # to Bar/releases so the folder pre-exists.
        function New-TR1 {
            param([switch]$Existing)
            $r = New-TRepo
            New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
            if ($Existing) { Write-TFile $r 'Bar/releases/README.md' 'release notes written by the user' }
            $head = Save-TAll $r 'base'
            $b = Invoke-TBuild -Dir $r
            $b.Status | Should -Be 'PASS' -Because $b.Reason
            return [pscustomobject]@{ Repo = $r; Head = $head; Releases = (Join-Path $r 'Bar\releases'); Pkg = (Join-Path $r 'Bar\releases\barGuid0001.1.0.0.1.pbiviz'); Man = (Join-Path $r 'Bar\releases\barGuid0001.1.0.0.1.release.json') }
        }
        function Get-TTempWrites { param([string]$Dir) return @(Get-ChildItem -LiteralPath $Dir -Force -Filter '.pbiviz-write-*' -ErrorAction SilentlyContinue) }
    }
    AfterEach { $script:PbivizFaults.Clear() }

    It 'rolls back a Level 1 release that fails <Case>, keeping what existed before; a retry then succeeds' -TestCases @(
        @{ Case = 'after the package was written (new releases folder)'; Fault = 'release:package-written'; Existing = $false },
        @{ Case = 'after the manifest was written (existing releases folder)'; Fault = 'release:manifest-written'; Existing = $true },
        @{ Case = 'after the pair was staged'; Fault = 'release:staged'; Existing = $true },
        @{ Case = 'after the post-staging checks'; Fault = 'release:verified'; Existing = $false }
    ) {
        $x = New-TR1 -Existing:$Existing
        $before = Get-TState $x.Repo
        $ev = Get-TEvidence -Sha $x.Head
        $script:PbivizFaults[$Fault] = $true
        $res = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head @ev
        $script:PbivizFaults.Clear()
        $res.Status | Should -Be 'BLOCKED' -Because $res.Reason
        $res.Reason | Should -Match "injected fault at $Fault - rolled back: nothing this call wrote or staged was left behind"
        $res.PackagePath | Should -BeNullOrEmpty
        @($res.Staged).Count | Should -Be 0
        Test-Path -LiteralPath $x.Pkg | Should -BeFalse
        Test-Path -LiteralPath $x.Man | Should -BeFalse
        Test-Path -LiteralPath $x.Releases | Should -Be ([bool]$Existing) -Because 'a folder the call created is removed; an existing one stays'
        if ($Existing) { [IO.File]::ReadAllText((Join-Path $x.Releases 'README.md')) | Should -Be 'release notes written by the user'; @(Get-TTempWrites $x.Releases).Count | Should -Be 0 }
        @(Compare-PbivizWorkingState -Before $before -After (Get-TState $x.Repo)).Count | Should -Be 0 -Because 'index and working tree are exactly as before'
        $ok = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head @ev
        $ok.Status | Should -Be 'PASS' -Because $ok.Reason
        @($ok.Staged) | Should -Be @('Bar/releases/barGuid0001.1.0.0.1.pbiviz', 'Bar/releases/barGuid0001.1.0.0.1.release.json')
    }

    It 'rolls back when Git cannot stage the pair (index locked), then succeeds once the lock is gone' {
        $x = New-TR1
        $before = Get-TState $x.Repo
        $ev = Get-TEvidence -Sha $x.Head
        $lock = Join-Path $x.Repo '.git\index.lock'
        [IO.File]::WriteAllText($lock, '')
        try { $res = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head @ev }
        finally { Remove-Item -LiteralPath $lock -Force }
        $res.Status | Should -Be 'BLOCKED' -Because $res.Reason
        $res.Reason | Should -Match 'staging the release pair failed: .*index\.lock.* - rolled back: nothing this call wrote or staged was left behind'
        Test-Path -LiteralPath $x.Releases | Should -BeFalse
        @(Compare-PbivizWorkingState -Before $before -After (Get-TState $x.Repo)).Count | Should -Be 0
        (Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head @ev).Status | Should -Be 'PASS'
    }

    It 'rolls back a Level 3 release that fails after staging; the candidate keeps its authorised state and the release can be retried' {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r -SkipRelease
        $p.Build.Status | Should -Be 'PASS' -Because $p.Build.Reason
        $wt = $p.Candidate.Worktree
        $ev = Get-TEvidence -Sha $p.Candidate.Source
        $script:PbivizFaults['release:staged'] = $true
        $res = Add-PbivizRelease -Worktree $wt -Visual 'Bar' -SourceSha $p.Candidate.Source @ev
        $script:PbivizFaults.Clear()
        $res.Status | Should -Be 'BLOCKED' -Because $res.Reason
        $res.Reason | Should -Match 'injected fault at release:staged - rolled back: nothing this call wrote or staged was left behind'
        (Test-PbivizCandidateState -Worktree $wt).Status | Should -Be 'PASS' -Because 'the index is the authorised candidate snapshot again'
        Test-Path -LiteralPath (Join-Path $wt 'Bar\releases') | Should -BeFalse
        $ok = Add-PbivizRelease -Worktree $wt -Visual 'Bar' -SourceSha $p.Candidate.Source @ev
        $ok.Status | Should -Be 'PASS' -Because $ok.Reason
        (Test-PbivizPromotionGates -Worktree $wt -Visual 'Bar' -TargetRef PBVIZ_Team_Prod).Status | Should -Be 'PASS'
    }

    It 'never deletes a file it wrote once that file changed; the run FAILS with ROLLBACK INCOMPLETE naming it' {
        $x = New-TR1
        $ev = Get-TEvidence -Sha $x.Head
        $script:PbivizFaults['release:manifest-written'] = { param($path) [IO.File]::AppendAllText($path, 'edited meanwhile') }
        $res = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head @ev
        $script:PbivizFaults.Clear()
        $res.Status | Should -Be 'FAILED'
        $res.Reason | Should -Match 'ROLLBACK INCOMPLETE, review by hand before archiving again: .*barGuid0001\.1\.0\.0\.1\.release\.json changed after this call wrote it - left in place'
        [IO.File]::ReadAllText($x.Man) | Should -Match 'edited meanwhile$'
        Test-Path -LiteralPath $x.Pkg | Should -BeFalse -Because 'the unchanged package the call wrote is still removed'
    }

    It 'explains an untracked (ignored) leftover release file and never deletes it' {
        $x = New-TR1
        [IO.File]::AppendAllText((Join-Path $x.Repo '.git\info\exclude'), "Bar/releases/`n")
        Write-TPackage -Path $x.Pkg -Guid 'barGuid0001' -Version '1.0.0.1' -Seed 99
        $sha = Get-PbivizFileSha256 $x.Pkg
        $res = Add-PbivizRelease -Root $x.Repo -Visual 'Bar' -SourceSha $x.Head
        $res.Status | Should -Be 'BLOCKED'
        $res.Reason | Should -Match 'already exists - releases are never overwritten\. barGuid0001\.1\.0\.0\.1\.pbiviz is not tracked by Git: possibly left by an interrupted run .* The helper never deletes it'
        Get-PbivizFileSha256 $x.Pkg | Should -Be $sha
        Test-Path -LiteralPath $x.Man | Should -BeFalse
    }

    It 'rolls back a legacy archive that fails after writing, leaving dist untouched' {
        $r = New-TRepo
        New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.3'
        Save-TAll $r 'base' | Out-Null
        $dist = Join-Path $r 'Bar\dist\barGuid0001.1.0.0.1.pbiviz'
        Write-TPackage -Path $dist -Guid 'barGuid0001' -Version '1.0.0.1' -Seed 5
        $sha = Get-PbivizFileSha256 $dist
        $before = Get-TState $r
        $script:PbivizFaults['legacy:written'] = $true
        $res = Add-PbivizLegacyArchive -Root $r -Visual 'Bar'
        $script:PbivizFaults.Clear()
        $res.Status | Should -Be 'BLOCKED' -Because $res.Reason
        $res.Reason | Should -Match 'injected fault at legacy:written - rolled back'
        @($res.Archived).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $r 'Bar\releases') | Should -BeFalse
        Get-PbivizFileSha256 $dist | Should -Be $sha
        @(Compare-PbivizWorkingState -Before $before -After (Get-TState $r)).Count | Should -Be 0
        $ok = Add-PbivizLegacyArchive -Root $r -Visual 'Bar'
        $ok.Status | Should -Be 'PASS' -Because $ok.Reason
        @($ok.Archived).Count | Should -Be 2
    }
}

Describe 'G4 decodes request strings by their language rules before classifying them (focused correction)' {

    BeforeAll {
        function New-TG5 {
            param([hashtable]$Files)
            $w = New-TDir 'g4e'
            Write-TFile $w 'Bar/pbiviz.json' '{ "visual": { "name": "Bar", "guid": "barGuid0001", "version": "1.0.0.1" } }'
            Write-TFile $w 'Bar/src/visual.ts' 'export class Visual {}'
            Write-TFile $w 'Bar/src/util.ts' 'export const x = 1;'
            foreach ($k in $Files.Keys) { Write-TFile $w $k $Files[$k] }
            return $w
        }
        # The G4 verdict exactly as Test-PbivizPromotionGates derives it from the scan.
        function Get-TG4Verdict { param($Scan) return [bool]($Scan.Complete -and @($Scan.Escapes).Count -eq 0) }
    }

    It 'BLOCKS an escaped request that resolves outside the visual: <Case>' -TestCases @(
        @{ Case = 'static import with \u escapes'; File = 'Bar/src/a.ts'; Text = "import { label } from '\u002e\u002e/\u002e\u002e/shared/probe.mjs';"; Escape = 'src/a.ts -> ../../shared/probe.mjs' },
        @{ Case = 'export from with \x escapes'; File = 'Bar/src/a.ts'; Text = 'export { x } from "\x2e\x2e/\x2e\x2e/shared/x";'; Escape = 'src/a.ts -> ../../shared/x' },
        @{ Case = 'side-effect import with mixed-case hex digits'; File = 'Bar/src/a.ts'; Text = "import '\x2E\u002E/\u002e./shared/side';"; Escape = 'src/a.ts -> ../../shared/side' },
        @{ Case = 'require() with \u{...} escapes'; File = 'Bar/src/a.js'; Text = 'const m = require("\u{2e}\u{2E}/\u{002e}\u{2e}/shared/m");'; Escape = 'src/a.js -> ../../shared/m' },
        @{ Case = 'dynamic import()'; File = 'Bar/src/a.ts'; Text = "const d = import('\u002E./\u002e\u002e/shared/d.js');"; Escape = 'src/a.ts -> ../../shared/d.js' },
        @{ Case = 'template-literal import with an escaped static prefix'; File = 'Bar/src/a.ts'; Text = 'export const t = (n: string) => import(`\u002e\u002e/\u002e\u002e/shared/${n}`);'; Escape = 'src/a.ts -> ../../shared/<computed> (a folder' },
        @{ Case = 'identity escapes'; File = 'Bar/src/a.ts'; Text = "import x from '.\./.\./shared/x';"; Escape = 'src/a.ts -> ../../shared/x' },
        @{ Case = 'line continuation (LF)'; File = 'Bar/src/a.ts'; Text = "import x from '../\`n../shared/lf';"; Escape = 'src/a.ts -> ../../shared/lf' },
        @{ Case = 'line continuation (CRLF)'; File = 'Bar/src/a.ts'; Text = "import x from '../\`r\`n../shared/crlf';"; Escape = 'src/a.ts -> ../../shared/crlf' },
        @{ Case = 'escaped Windows separators'; File = 'Bar/src/a.js'; Text = "const w = require('..\\..\\shared\\w');"; Escape = 'src/a.js -> ..\..\shared\w' },
        @{ Case = 'require written with an escaped identifier'; File = 'Bar/src/a.js'; Text = "const r = \u0072equire('../../shared/r');"; Escape = 'src/a.js -> ../../shared/r' },
        @{ Case = 'new URL asset with escapes'; File = 'Bar/src/a.ts'; Text = "const u = new URL('\u002e\u002e/\u002e\u002e/shared/w.js', import.meta.url);"; Escape = 'src/a.ts -> ../../shared/w.js' },
        @{ Case = 'require.context with escapes'; File = 'Bar/src/a.js'; Text = "const c = require.context('\x2e\x2e/\x2e\x2e/shared');"; Escape = 'src/a.js -> ../../shared (a folder' },
        @{ Case = 'JSON tsconfig extends'; File = 'Bar/tsconfig.json'; Text = '{ "extends": "\u002e\u002e/tsconfig.base.json" }'; Escape = 'tsconfig.json -> ../tsconfig.base.json' },
        @{ Case = 'JSON tsconfig baseUrl'; File = 'Bar/tsconfig.json'; Text = '{ "compilerOptions": { "baseUrl": "\u002e\u002e" } }'; Escape = 'tsconfig.json -> ..' },
        @{ Case = 'JSON tsconfig paths'; File = 'Bar/tsconfig.json'; Text = '{ "compilerOptions": { "paths": { "@shared/*": ["\u002e\u002e\/shared/*"] } } }'; Escape = 'tsconfig.json -> ../shared/*' },
        @{ Case = 'JSON file: dependency'; File = 'Bar/package.json'; Text = '{ "dependencies": { "s": "file:\u002e\u002e/shared" } }'; Escape = 'package.json -> ../shared' },
        @{ Case = 'JSON absolute path in pbiviz.json'; File = 'Bar/pbiviz.json'; Text = '{ "visual": {}, "assets": { "icon": "\u002ficons/x.png" } }'; Escape = 'pbiviz.json -> /icons/x.png' }
    ) {
        $w = New-TG5 @{ $File = $Text }
        $s = Get-PbivizDependencyEscapes -Worktree $w -Visual 'Bar'
        (Get-TG4Verdict $s) | Should -BeFalse
        (@($s.Escapes) -join ' || ') | Should -Match ([regex]::Escape($Escape)) -Because "uncertain: $($s.Uncertain -join '; ')"
    }

    It 'fails closed on an unsupported, malformed or ambiguous escape: <Case>' -TestCases @(
        @{ Case = 'malformed \x escape'; File = 'Bar/src/a.ts'; Text = "import x from '\x2e\x2/shared/x';"; Match = 'src/a\.ts:1: import/export from request with an unsupported or malformed escape sequence \(malformed hexadecimal escape' },
        @{ Case = 'malformed \u escape'; File = 'Bar/src/a.js'; Text = "const m = require('\u002e\u002/x');"; Match = 'require\(\) request with an unsupported or malformed escape sequence \(malformed or out-of-range Unicode escape' },
        @{ Case = 'out-of-range \u{...} escape'; File = 'Bar/src/a.ts'; Text = "const d = import('\u{110000}/x');"; Match = 'malformed or out-of-range Unicode escape' },
        @{ Case = 'legacy octal escape (mode-dependent)'; File = 'Bar/src/a.js'; Text = "const m = require('\56\56/\56\56/shared/x');"; Match = 'legacy octal or decimal escape' },
        @{ Case = 'non-octal decimal escape \8'; File = 'Bar/src/a.ts'; Text = "import x from '\8/x';"; Match = 'legacy octal or decimal escape' },
        @{ Case = 'unpaired surrogate'; File = 'Bar/src/a.ts'; Text = "import x from '\uD800/x';"; Match = 'unpaired surrogate' },
        @{ Case = 'unterminated request string'; File = 'Bar/src/a.ts'; Text = "import x from '../../shared/x`nexport class V {}"; Match = 'unterminated string literal' },
        @{ Case = 'escape an untagged template rejects'; File = 'Bar/src/a.ts'; Text = 'export const t = (n: string) => import(`\01/${n}`);'; Match = 'legacy octal or decimal escape' },
        @{ Case = 'JSON escape outside RFC 8259'; File = 'Bar/tsconfig.json'; Text = '{ "extends": "\x2e\x2e/base.json" }'; Match = 'tsconfig\.json:1: JSON string .* is not valid in JSON' },
        @{ Case = 'malformed JSON \u escape'; File = 'Bar/tsconfig.json'; Text = '{ "compilerOptions": { "baseUrl": "\u002" } }'; Match = 'malformed Unicode escape' },
        @{ Case = 'unpaired surrogate in JSON'; File = 'Bar/tsconfig.json'; Text = '{ "compilerOptions": { "paths": { "a": ["\uDC00/x"] } } }'; Match = 'unpaired surrogate' },
        @{ Case = 'escape in a CSS url()'; File = 'Bar/style/b.css'; Text = ".a { background: url('\2e\2e/\2e\2e/shared/i.png'); }"; Match = 'escape sequences in style requests are not decoded' },
        @{ Case = 'backslash in a triple-slash reference'; File = 'Bar/src/a.ts'; Text = '/// <reference path="\u002e\u002e/x.d.ts" />'; Match = 'a backslash in a triple-slash reference is not interpreted' },
        @{ Case = 'control character in a request'; File = 'Bar/src/a.ts'; Text = "import x from './\u0000x';"; Match = 'request contains control characters' }
    ) {
        $w = New-TG5 @{ $File = $Text }
        $s = Get-PbivizDependencyEscapes -Worktree $w -Visual 'Bar'
        $s.Complete | Should -BeFalse -Because "escapes: $($s.Escapes -join '; ')"
        (Get-TG4Verdict $s) | Should -BeFalse
        (@($s.Uncertain) -join ' || ') | Should -Match $Match
    }

    It 'keeps passing legitimate internal requests written with escapes, valid JSON escapes, and mode-dependent escapes outside requests' {
        $w = New-TG5 @{
            'Bar/src/visual.ts'       = @'
import { x } from '\u002e/util';
import { y } from "\x2e/\x75til";
export { x as z } from '.\/util';
import '\u{2e}/\u{2e}\u{2e}/style/visual.less';
const t = (l: string) => import(`\u002e/locales/${l}.json`);
const c = (l: string) => import('\u002e/locales/' + l + '.json');
const r = \u0072equire('./util');
const s = 'text \n with \t valid \u00e9 escapes \x41 and \0';
export class Visual {}
'@
            'Bar/src/legacy.js'       = "var msg = '\101\102'; // legacy octal outside any request (sloppy-mode script)`nmodule.exports = msg;"
            'Bar/src/globals.d.ts'    = 'declare const G: number;'
            'Bar/src/refs.ts'         = '/// <reference path="globals.d.ts" />' + "`nexport const g = 1;"
            'Bar/src/locales/en.json' = '{ "hello": "H\u00e9llo \"quoted\" \\ back\/slash \n" }'
            'Bar/style/visual.less'   = '.a { color: red; }'
            'Bar/tsconfig.json'       = '{ "compilerOptions": { "outDir": "\u002e/.tmp/build/" }, "files": ["\u002e/src/visual.ts"] }'
        }
        $s = Get-PbivizDependencyEscapes -Worktree $w -Visual 'Bar'
        $s.Complete | Should -BeTrue -Because ($s.Uncertain -join '; ')
        @($s.Escapes).Count | Should -Be 0 -Because ($s.Escapes -join '; ')
        (Get-TG4Verdict $s) | Should -BeTrue
        $s.References | Should -BeGreaterThan 9
    }

    It 'G4 BLOCKS a Level 3 candidate whose escaped import reaches an unapproved shared file, and passes once that file is allowlisted' {
        $r = New-TL3
        Write-TFile $r 'shared/probe.mjs' 'export const label = 1;'
        Save-TAll $r 'shared' | Out-Null
        TGit $r branch -f PBVIZ_Team_Prod HEAD | Out-Null
        Write-TFile $r 'shared/probe.mjs' 'export const label = 2;'
        Write-TFile $r 'Bar/src/visual.ts' ("import { label } from '\u002e\u002e/\u002e\u002e/shared/probe.mjs';" + "`nexport class Visual {}")
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar imports shared code through an escaped path' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $p.Gates.Status | Should -Be 'BLOCKED'
        $g4 = Get-TGate $p.Gates 'G4'
        $g4.Pass | Should -BeFalse
        $g4.Detail | Should -Match 'not allowlisted: src/visual\.ts -> \.\./\.\./shared/probe\.mjs'
        (Remove-PbivizPromotionWorktree -Root $r -WorktreeDir $p.Candidate.Worktree -DiscardApproval 'APPROVED:DISCARD-CANDIDATE:release/pbiviz/Bar/1.0.0.2').Status | Should -Be 'PASS'
        TGit $r branch '-D' 'release/pbiviz/Bar/1.0.0.2' | Out-Null
        $q = Invoke-TPromotion -Repo $r -Allowlist @('shared/probe.mjs')
        $q.Gates.Status | Should -Be 'PASS' -Because $q.Gates.Reason
        (Get-TGate $q.Gates 'G4').Pass | Should -BeTrue
    }
}

Describe 'Build isolation contains the SDK''s known side effects (Canary D2, final hardening)' {

    BeforeAll {
        function New-TIso {
            $r = New-TRepo
            New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
            $head = Save-TAll $r 'base'
            return [pscustomobject]@{ Repo = $r; Head = $head; Tools = (Join-Path $r 'Bar\node_modules\powerbi-visuals-tools'); HomeRoot = (Join-Path $r '.git\pbiviz-build-home'); Records = (Join-Path $r '.git\pbiviz-builds') }
        }
        function Read-TProbe { param($X) return ([IO.File]::ReadAllText((Join-Path $X.Tools 'probe.json')) | ConvertFrom-Json) }
        $script:IsoEnvNames = @('USERPROFILE', 'HOME', 'PATH', 'PATHEXT', 'NoDefaultCurrentDirectoryInExePath', 'PBIVIZ_PWSH_GUARD_MARKER', 'TEMP', 'TMP', 'npm_config_userconfig', 'npm_config_cache', 'npm_config_offline', 'npm_config_update_notifier', 'npm_config_audit', 'npm_config_fund')
        function Get-TEnvSnap { $h = @{}; foreach ($n in $script:IsoEnvNames) { $h[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }; return $h }
        function Assert-TEnvRestored {
            param($Before)
            foreach ($n in $script:IsoEnvNames) { [Environment]::GetEnvironmentVariable($n, 'Process') | Should -Be $Before[$n] -Because "$n is restored after the build" }
        }
    }

    It 'runs the CLI with a disposable profile, the guard first on PATH, no current-directory search and offline npm, then removes it all' {
        $x = New-TIso
        $before = Get-TEnvSnap
        Install-TFakeTools -Dir $x.Repo -Mode 'probe'
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
        $b.Status | Should -Be 'PASS' -Because $b.Reason
        $p = Read-TProbe $x
        $p.homedir | Should -BeLike "$($x.HomeRoot)\home-*\profile" -Because 'os.homedir() is the disposable profile'
        $p.USERPROFILE | Should -Be $p.homedir
        $p.HOME | Should -Be $p.homedir
        $p.homedir | Should -Not -Be $before.USERPROFILE
        $p.TEMP | Should -BeLike "$($x.HomeRoot)\home-*\tmp"
        $p.pathFirst | Should -BeLike "$($x.HomeRoot)\home-*\guard"
        $p.guard | Should -Match 'PBIVIZ_PWSH_GUARD_MARKER'
        $p.NoDefault | Should -Be '1'
        @($p.PATHEXT -split ';') | Should -Contain '.CMD'
        $p.npmCache | Should -BeLike "$($x.HomeRoot)\home-*\npm-cache"
        $p.npmOffline | Should -Be 'true'
        $p.npmNotifier | Should -Be 'false'
        $p.pfxExists | Should -BeTrue -Because 'the placeholder sits where the SDK looks for it'
        $p.passExists | Should -BeTrue
        Test-Path -LiteralPath $x.HomeRoot | Should -BeFalse -Because 'the disposable home and its empty root are removed'
        ($b.Evidence -join ' ') | Should -Match 'isolation: disposable profile'
        Assert-TEnvRestored $before
    }

    It 'the guard still stops pwsh when the visual folder holds a same-named <Name> (current-directory search is off)' -TestCases @(
        @{ Name = 'pwsh.cmd' }, @{ Name = 'pwsh.exe' }
    ) {
        $x = New-TIso
        $hijack = Join-Path $x.Repo 'hijack-ran.txt'
        if ($Name -eq 'pwsh.cmd') { Write-TFile $x.Repo 'Bar/pwsh.cmd' "@echo hijack>> `"$hijack`"`r`n@exit /b 0`r`n" }
        else { Copy-Item -LiteralPath "$env:SystemRoot\System32\whoami.exe" -Destination (Join-Path $x.Repo 'Bar\pwsh.exe') }
        Save-TAll $x.Repo "visual ships $Name" | Out-Null
        $before = Get-TEnvSnap
        Install-TFakeTools -Dir $x.Repo -Mode 'pwsh'
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
        $b.Status | Should -Be 'FAILED'
        $b.Reason | Should -Match 'the SDK tried to start pwsh to generate a certificate \(the guard stopped it\) - no build evidence recorded'
        Test-Path -LiteralPath $hijack | Should -BeFalse -Because 'the same-named file in the visual folder never ran'
        Test-Path -LiteralPath $x.Records | Should -BeFalse
        Test-Path -LiteralPath $x.HomeRoot | Should -BeFalse
        Assert-TEnvRestored $before
    }

    It 'the guard still stops pwsh when the caller''s PATHEXT omits .CMD' {
        $x = New-TIso
        $saved = $env:PATHEXT
        try {
            $env:PATHEXT = '.COM;.EXE'
            Install-TFakeTools -Dir $x.Repo -Mode 'pwsh'
            $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
            $b.Status | Should -Be 'FAILED'
            $b.Reason | Should -Match 'the guard stopped it'
            $env:PATHEXT | Should -Be '.COM;.EXE' -Because "the caller's PATHEXT is restored"
        } finally { $env:PATHEXT = $saved }
        Test-Path -LiteralPath $x.Records | Should -BeFalse
    }

    It 'leaves folders that hold a PowerShell 7 executable out of the child PATH (a shell-less spawn finds no pwsh)' {
        $x = New-TIso
        $ps7 = New-TDir 'ps7'
        Copy-Item -LiteralPath "$env:SystemRoot\System32\whoami.exe" -Destination (Join-Path $ps7 'pwsh.exe')
        $saved = $env:PATH
        try {
            $env:PATH = "$ps7;$saved"
            Install-TFakeTools -Dir $x.Repo -Mode 'spawn-pwsh'
            $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
            $env:PATH | Should -Be "$ps7;$saved" -Because "the caller's PATH is restored"
        } finally { $env:PATH = $saved }
        $b.Status | Should -Be 'PASS' -Because $b.Reason
        [IO.File]::ReadAllText((Join-Path $x.Tools 'spawn.txt')) | Should -Be 'ENOENT'
        ($b.Evidence -join ' ') | Should -Match '[1-9]\d* PowerShell 7 folder\(s\) left out'
    }

    It 'SDK certificate settings that name isolation files stay inside the disposable certificate folder' {
        $x = New-TIso
        Install-TFakeTools -Dir $x.Repo -Mode 'probe' -CertConfig @{ certificateFolder = 'guard'; pfx = 'pwsh.cmd'; passphrase = 'guard-called.txt'; certificate = 'owner.lock'; privateKey = 'tmp' }
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
        $b.Status | Should -Be 'PASS' -Because $b.Reason
        $p = Read-TProbe $x
        $p.guard | Should -Match 'PBIVIZ_PWSH_GUARD_MARKER' -Because 'a PFX named pwsh.cmd in a certificate folder named guard did not overwrite the guard'
        $p.pfxExists | Should -BeTrue
    }

    It 'BLOCKS SDK certificate settings that <Case>; the CLI never runs' -TestCases @(
        @{ Case = 'climb out of the certificate folder (certificate)'; Config = @{ certificate = '..\guard\pwsh.cmd' }; Match = "certificate '\.\.\\guard\\pwsh\.cmd' is not a single safe file name" },
        @{ Case = 'climb out of the certificate folder (privateKey)'; Config = @{ privateKey = '../../owner.lock' }; Match = "privateKey '\.\./\.\./owner\.lock' is not a single safe file name" },
        @{ Case = 'name a nested folder'; Config = @{ certificateFolder = 'a\b' }; Match = "certificateFolder 'a\\b' is not a single safe file name" },
        @{ Case = 'name a device'; Config = @{ certificateFolder = 'NUL' }; Match = "certificateFolder 'NUL' is not a single safe file name" },
        @{ Case = 'name the same file twice'; Config = @{ pfx = 'cert.PFX'; passphrase = 'CERT.pfx' }; Match = 'name the same file twice' }
    ) {
        $x = New-TIso
        Install-TFakeTools -Dir $x.Repo -Mode 'probe' -CertConfig $Config
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
        $b.Status | Should -Be 'BLOCKED'
        $b.Reason | Should -Match $Match
        Test-Path -LiteralPath (Join-Path $x.Tools 'probe.json') | Should -BeFalse
        Test-Path -LiteralPath $x.HomeRoot | Should -BeFalse
        Test-Path -LiteralPath $x.Records | Should -BeFalse
    }

    It 'keeps the caller''s own certificate material untouched' {
        $x = New-TIso
        $fakeProfile = New-TDir 'profile'
        Write-TFile $fakeProfile 'pbiviz-certs/PowerBICustomVisualTestPass.txt' 'sentinel passphrase'
        Write-TBytes -Path (Join-Path $fakeProfile 'pbiviz-certs\PowerBICustomVisualTest_public.pfx') -Seed 5
        $hashes = @(Get-ChildItem -LiteralPath (Join-Path $fakeProfile 'pbiviz-certs') -File | ForEach-Object { "$($_.Name)=$(Get-PbivizFileSha256 $_.FullName)" })
        $saved = $env:USERPROFILE
        try {
            $env:USERPROFILE = $fakeProfile
            Install-TFakeTools -Dir $x.Repo -Mode 'sdk-cert'
            $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
            $env:USERPROFILE | Should -Be $fakeProfile
        } finally { $env:USERPROFILE = $saved }
        $b.Status | Should -Be 'PASS' -Because $b.Reason
        (Read-TProbe $x).homedir | Should -Not -Be $fakeProfile
        @(Get-ChildItem -LiteralPath (Join-Path $fakeProfile 'pbiviz-certs') -File | ForEach-Object { "$($_.Name)=$(Get-PbivizFileSha256 $_.FullName)" }) | Should -Be $hashes
        @(Get-ChildItem -LiteralPath $fakeProfile -Recurse -Force).Count | Should -Be 3 -Because 'nothing was added to the profile'
    }

    It 'FAILS without build evidence when a new certificate appears in Cert:\CurrentUser\My (the store is only read)' {
        $x = New-TIso
        $calls = @{ n = 0 }
        function Get-PbivizUserCertThumbprints { $calls.n++; if ($calls.n -eq 1) { return @('AAAA') } else { return @('AAAA', 'BBBB') } }
        Install-TFakeTools -Dir $x.Repo
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
        $b.Status | Should -Be 'FAILED'
        $b.Reason | Should -Match 'a new certificate appeared in Cert:\\CurrentUser\\My during the build \(BBBB\) - it was NOT removed'
        $calls.n | Should -Be 2
        Test-Path -LiteralPath $x.Records | Should -BeFalse
    }

    It 'BLOCKS before the CLI starts when Cert:\CurrentUser\My cannot be read; nothing is run or recorded' {
        $x = New-TIso
        function Get-PbivizUserCertThumbprints { return $null }
        Install-TFakeTools -Dir $x.Repo -Mode 'probe'
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
        $b.Status | Should -Be 'BLOCKED'
        $b.Reason | Should -Match 'Cert:\\CurrentUser\\My cannot be read, so a certificate the SDK might create during the build could not be detected - refusing to run pbiviz package'
        Test-Path -LiteralPath (Join-Path $x.Tools 'probe.json') | Should -BeFalse -Because 'the CLI never started'
        Test-Path -LiteralPath $x.HomeRoot | Should -BeFalse
        Test-Path -LiteralPath $x.Records | Should -BeFalse
    }

    It 'FAILS without build evidence when Cert:\CurrentUser\My cannot be read after the build' {
        $x = New-TIso
        $calls = @{ n = 0 }
        function Get-PbivizUserCertThumbprints { $calls.n++; if ($calls.n -eq 1) { return , [string[]]@('AAAA') } else { return $null } }
        Install-TFakeTools -Dir $x.Repo
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
        $b.Status | Should -Be 'FAILED'
        $b.Reason | Should -Match 'Cert:\\CurrentUser\\My could not be read after the build, so a certificate the SDK might have created could not be ruled out - no build evidence recorded'
        Test-Path -LiteralPath $x.Records | Should -BeFalse
        Test-Path -LiteralPath $x.HomeRoot | Should -BeFalse
    }

    It 'compares an empty but readable store like any other: <Case>' -TestCases @(
        @{ Case = 'still empty after the build'; After = @(); Status = 'PASS'; Match = 'Cert:\\CurrentUser\\My unchanged' },
        @{ Case = 'a certificate added during the build'; After = @('BBBB'); Status = 'FAILED'; Match = 'a new certificate appeared in Cert:\\CurrentUser\\My during the build \(BBBB\)' }
    ) {
        $x = New-TIso
        $calls = @{ n = 0; after = [string[]]$After }
        function Get-PbivizUserCertThumbprints { $calls.n++; if ($calls.n -eq 1) { return , [string[]]@() } else { return , $calls.after } }
        Install-TFakeTools -Dir $x.Repo
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
        $b.Status | Should -Be $Status -Because $b.Reason
        "$($b.Reason) $($b.Evidence -join ' ')" | Should -Match $Match
        Test-Path -LiteralPath $x.Records | Should -Be ($Status -eq 'PASS')
    }

    It 'reads the store as a string array: empty for an empty store, $null only when it cannot be opened (read-only)' {
        $real = Get-PbivizUserCertThumbprints
        $null -eq $real | Should -BeFalse -Because 'the current user''s store is readable here'
        $real -is [string[]] | Should -BeTrue
        Mock New-Object -ParameterFilter { $TypeName -like '*X509Store' } -MockWith {
            $o = [pscustomobject]@{ Certificates = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new() }
            $o | Add-Member -MemberType ScriptMethod -Name Open -Value { param($Flags) if ($Flags -ne [System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly) { throw 'opened for writing' } }
            $o | Add-Member -MemberType ScriptMethod -Name Close -Value { }
            return $o
        }
        $empty = Get-PbivizUserCertThumbprints
        $null -eq $empty | Should -BeFalse -Because 'an empty store was read successfully'
        $empty -is [string[]] | Should -BeTrue
        $empty.Count | Should -Be 0
        Mock New-Object -ParameterFilter { $TypeName -like '*X509Store' } -MockWith {
            $o = [pscustomobject]@{ Certificates = $null }
            $o | Add-Member -MemberType ScriptMethod -Name Open -Value { param($Flags) throw 'Access is denied.' }
            $o | Add-Member -MemberType ScriptMethod -Name Close -Value { }
            return $o
        }
        Get-PbivizUserCertThumbprints | Should -BeNullOrEmpty
        $null -eq (Get-PbivizUserCertThumbprints) | Should -BeTrue
    }

    It 'FAILS without build evidence when the SDK tries to install the API package' {
        $x = New-TIso
        Install-TFakeTools -Dir $x.Repo -Mode 'install-api'
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
        $b.Status | Should -Be 'FAILED'
        $b.Reason | Should -Match 'the SDK tried to install powerbi-visuals-api'
        Test-Path -LiteralPath $x.Records | Should -BeFalse
    }

    It 'removes the disposable home after <Case> and keeps evidence only for success' -TestCases @(
        @{ Case = 'success'; Mode = 'ok'; Status = 'PASS'; Timeout = 900 },
        @{ Case = 'a failed build'; Mode = 'fail'; Status = 'FAILED'; Timeout = 900 },
        @{ Case = 'a timeout'; Mode = 'hang'; Status = 'FAILED'; Timeout = 3 },
        @{ Case = 'a guard stop'; Mode = 'pwsh'; Status = 'FAILED'; Timeout = 900 }
    ) {
        $x = New-TIso
        $before = Get-TEnvSnap
        Install-TFakeTools -Dir $x.Repo -Mode $Mode
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar' -TimeoutSeconds $Timeout
        $b.Status | Should -Be $Status -Because $b.Reason
        Test-Path -LiteralPath $x.HomeRoot | Should -BeFalse
        Test-Path -LiteralPath $x.Records | Should -Be ($Status -eq 'PASS')
        Assert-TEnvRestored $before
    }
}

Describe 'The toolchain preflight blocks every dependency download pbiviz package would start (final hardening P2)' {

    BeforeAll {
        function New-TPre {
            param([string]$PbivizJson = $null, [hashtable]$Lock = $null)
            $r = New-TRepo
            New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
            if ($PbivizJson) { Write-TFile $r 'Bar/pbiviz.json' $PbivizJson }
            if ($Lock) {
                # A $null declaration leaves the package out of that side; ApiSection moves the API to "dependencies" on both sides.
                $decl = { param($api) $s = @(); if ($api -and $Lock.ApiSection) { $s += """$($Lock.ApiSection)"": { ""powerbi-visuals-api"": ""$api"" }" }
                    $dev = @("""powerbi-visuals-tools"": ""$($Lock.ToolsDeclared)"""); if ($api -and -not $Lock.ApiSection) { $dev = @("""powerbi-visuals-api"": ""$api""") + $dev }
                    $s += """devDependencies"": { $($dev -join ', ') }"; $s -join ', ' }
                $declared = & $decl $Lock.ApiDeclared
                $lockDeclared = & $decl $Lock.LockApiDeclared
                $rootEntry = if ($Lock.NoRoot) { '' } else { """"": { ""name"": ""bar"", ""version"": ""1.0.0"", $lockDeclared }, " }
                Write-TFile $r 'Bar/package.json' "{ ""name"": ""bar"", ""version"": ""1.0.0"", $declared }"
                Write-TFile $r 'Bar/package-lock.json' "{ ""name"": ""bar"", ""version"": ""1.0.0"", ""lockfileVersion"": 3, ""requires"": true, ""packages"": { $rootEntry""node_modules/powerbi-visuals-api"": { ""version"": ""$($Lock.ApiLocked)"", ""dev"": true }, ""node_modules/powerbi-visuals-tools"": { ""version"": ""$($Lock.ToolsLocked)"", ""dev"": true } } }"
            }
            $head = Save-TAll $r 'base'
            return [pscustomobject]@{ Repo = $r; Head = $head; Tools = (Join-Path $r 'Bar\node_modules\powerbi-visuals-tools'); HomeRoot = (Join-Path $r '.git\pbiviz-build-home'); Records = (Join-Path $r '.git\pbiviz-builds') }
        }
        $script:GoodLock = @{ ApiDeclared = '~5.11.0'; LockApiDeclared = '~5.11.0'; ToolsDeclared = '^7.2.2'; ApiLocked = '5.11.0'; ToolsLocked = '7.2.2' }
    }

    It 'BLOCKS <Case> before the CLI starts; nothing is run, installed or recorded' -TestCases @(
        @{ Case = 'a missing powerbi-visuals-api'; Api = ''; Lock = $null; Pbiviz = $null; Match = 'powerbi-visuals-api is not installed in Bar/node_modules: pbiviz package would run npm install --save powerbi-visuals-api@~5\.11\.0 .*APPROVED:INSTALL:Bar' },
        @{ Case = 'an installed API with another major.minor'; Api = '5.3.0'; Lock = $null; Pbiviz = $null; Match = 'the installed powerbi-visuals-api 5\.3\.0 does not match pbiviz\.json apiVersion 5\.11\.0 \(major\.minor\): pbiviz package would run npm install --save powerbi-visuals-api@~5\.11\.0' },
        @{ Case = 'a pbiviz.json without apiVersion'; Api = '5.11.0'; Lock = $null; Pbiviz = "{`n  ""visual"": { ""name"": ""Bar"", ""guid"": ""barGuid0001"", ""version"": ""1.0.0.1"" }`n}`n"; Match = 'pbiviz\.json has no apiVersion: pbiviz package would run npm install --save powerbi-visuals-api@latest' },
        @{ Case = 'an installed API other than the locked one'; Api = '5.11.1'; Lock = 'api-drift'; Pbiviz = $null; Match = 'node_modules holds powerbi-visuals-api 5\.11\.1 but package-lock\.json locks 5\.11\.0' },
        @{ Case = 'installed tools other than the locked ones'; Api = '5.11.0'; Lock = 'tools-drift'; Pbiviz = $null; Match = 'node_modules holds powerbi-visuals-tools 7\.2\.2 but package-lock\.json locks 7\.2\.1' },
        @{ Case = 'a package.json that disagrees with package-lock.json'; Api = '5.11.0'; Lock = 'manifest-drift'; Pbiviz = $null; Match = "package\.json and package-lock\.json disagree on powerbi-visuals-api \('~5\.12\.0' vs '~5\.11\.0'\)" },
        @{ Case = 'a lockfile root entry missing the declared API'; Api = '5.11.0'; Lock = 'root-without-api'; Pbiviz = $null; Match = "package\.json declares powerbi-visuals-api '~5\.11\.0' but the root entry of package-lock\.json does not: the lockfile was not regenerated" },
        @{ Case = 'a lockfile without a root entry'; Api = '5.11.0'; Lock = 'no-root'; Pbiviz = $null; Match = "package-lock\.json has no root package entry although package\.json declares powerbi-visuals-tools '\^7\.2\.2'" },
        @{ Case = 'a lockfile root entry declaring an API package.json does not'; Api = '5.11.0'; Lock = 'manifest-without-api'; Pbiviz = $null; Match = "the root entry of package-lock\.json declares powerbi-visuals-api '~5\.11\.0' but package\.json does not" }
    ) {
        $lockSpec = $null
        if ($Lock) {
            $lockSpec = $script:GoodLock.Clone()
            if ($Lock -eq 'tools-drift') { $lockSpec.ToolsLocked = '7.2.1' }
            if ($Lock -eq 'manifest-drift') { $lockSpec.ApiDeclared = '~5.12.0' }
            if ($Lock -eq 'root-without-api') { $lockSpec.LockApiDeclared = $null }
            if ($Lock -eq 'no-root') { $lockSpec.NoRoot = $true }
            if ($Lock -eq 'manifest-without-api') { $lockSpec.ApiDeclared = $null }
        }
        $x = New-TPre -PbivizJson $Pbiviz -Lock $lockSpec
        Install-TFakeTools -Dir $x.Repo -Mode 'probe' -ApiVersion $Api
        $before = Get-TState $x.Repo
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
        $b.Status | Should -Be 'BLOCKED'
        $b.Reason | Should -Match $Match
        Test-Path -LiteralPath (Join-Path $x.Tools 'probe.json') | Should -BeFalse -Because 'the CLI never started'
        Test-Path -LiteralPath $x.HomeRoot | Should -BeFalse
        Test-Path -LiteralPath $x.Records | Should -BeFalse
        @(Compare-PbivizWorkingState -Before $before -After (Get-TState $x.Repo)).Count | Should -Be 0
    }

    It 'builds with a compatible installed toolchain: <Case>' -TestCases @(
        @{ Case = 'another patch of the same API major.minor, no lockfile'; Api = '5.11.4'; Lock = $false; Match = 'no package-lock\.json' },
        @{ Case = 'the versions package-lock.json locks'; Api = '5.11.0'; Lock = 'good'; Match = 'are the versions package-lock\.json locks' },
        @{ Case = 'the API in dependencies and the tools in devDependencies'; Api = '5.11.0'; Lock = 'split'; Match = 'are the versions package-lock\.json locks' }
    ) {
        $lockSpec = $null
        if ($Lock) { $lockSpec = $script:GoodLock.Clone(); if ($Lock -eq 'split') { $lockSpec.ApiSection = 'dependencies' } }
        $x = New-TPre -Lock $lockSpec
        Install-TFakeTools -Dir $x.Repo -ApiVersion $Api
        $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
        $b.Status | Should -Be 'PASS' -Because $b.Reason
        ($b.Evidence -join ' ') | Should -Match 'toolchain preflight: powerbi-visuals-api'
        ($b.Evidence -join ' ') | Should -Match $Match
    }
}

Describe 'Stale build homes are swept only when their build has ended (final hardening P3)' {

    BeforeAll {
        function New-TSweep {
            $r = New-TRepo
            New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
            New-TVisual $r 'Column' 'colGuid0001' '2.0.0.1'
            Save-TAll $r 'base' | Out-Null
            Install-TFakeTools -Dir $r -Visual 'Bar'
            $root = Join-Path $r '.git\pbiviz-build-home'
            [void][IO.Directory]::CreateDirectory($root)
            return [pscustomobject]@{ Repo = $r; HomeRoot = $root }
        }
        function New-THome {
            param($X, [string]$Name, [switch]$Lock, [int]$AgeHours = 0)
            $h = Join-Path $X.HomeRoot $Name
            [void][IO.Directory]::CreateDirectory((Join-Path $h 'profile'))
            if ($Lock) { [IO.File]::WriteAllText((Join-Path $h 'owner.lock'), '') }
            if ($AgeHours) { $t = [DateTime]::UtcNow.AddHours(-$AgeHours); (Get-Item -LiteralPath $h).CreationTimeUtc = $t; (Get-Item -LiteralPath $h).LastWriteTimeUtc = $t }
            return $h
        }
    }

    It 'keeps a live home whose build holds its lock, however old it is and however short this build''s timeout' {
        $x = New-TSweep
        $live = New-THome $x 'home-live00000001' -Lock -AgeHours 72
        $held = [IO.File]::Open((Join-Path $live 'owner.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar' -TimeoutSeconds 5
            $b.Status | Should -Be 'PASS' -Because $b.Reason
            Test-Path -LiteralPath $live | Should -BeTrue -Because 'a concurrent build keeps its home'
            ($b.Evidence -join ' ') | Should -Not -Match 'home-live00000001'
        } finally { $held.Dispose() }
        Remove-Item -LiteralPath (Join-Path $x.Repo 'Bar\dist') -Recurse -Force
        $b2 = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar' -TimeoutSeconds 5
        $b2.Status | Should -Be 'PASS' -Because $b2.Reason
        Test-Path -LiteralPath $live | Should -BeFalse -Because 'once its build ended the lock is free and the home is swept'
        ($b2.Evidence -join ' ') | Should -Match 'removed a disposable build home left by an ended run: home-live00000001'
    }

    It 'removes a home whose lock is free (an interrupted build), keeps a lockless home for 24 hours and never follows a link' {
        $x = New-TSweep
        $dead = New-THome $x 'home-dead00000001' -Lock
        $fresh = New-THome $x 'home-fresh0000001'
        $old = New-THome $x 'home-old000000001' -AgeHours 30
        $target = New-TDir 'linktarget'
        Write-TFile $target 'must-survive.txt' 'x'
        $link = Join-Path $x.HomeRoot 'home-link00000001'
        & cmd.exe /c "mklink /J `"$link`" `"$target`"" | Out-Null
        try {
            $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Bar'
            $b.Status | Should -Be 'PASS' -Because $b.Reason
            Test-Path -LiteralPath $dead | Should -BeFalse
            Test-Path -LiteralPath $old | Should -BeFalse
            Test-Path -LiteralPath $fresh | Should -BeTrue
            Test-Path -LiteralPath $link | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $target 'must-survive.txt') | Should -BeTrue
            $ev = $b.Evidence -join ' '
            $ev | Should -Match 'home-dead00000001'
            $ev | Should -Match 'home-old000000001'
            $ev | Should -Match 'a link in the build-home folder was left alone: home-link00000001'
        } finally { if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) } }
    }

    It 'a build running in parallel in the same repository keeps its home while another build sweeps' {
        $x = New-TSweep
        Install-TFakeTools -Dir $x.Repo -Visual 'Bar' -Mode 'hang'
        Install-TFakeTools -Dir $x.Repo -Visual 'Column'
        $job = Start-Job -ScriptBlock {
            param($Helper, $Repo, $GitConfig)
            $env:GIT_CONFIG_GLOBAL = $GitConfig; $env:GIT_CONFIG_NOSYSTEM = '1'
            . $Helper
            $r = Invoke-PbivizBuild -Root $Repo -Visual 'Bar' -TimeoutSeconds 40
            [pscustomobject]@{ Status = $r.Status; Reason = $r.Reason }
        } -ArgumentList $script:HelperFile, $x.Repo, $script:EmptyGitConfig
        try {
            $other = $null
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not $other -and $sw.Elapsed.TotalSeconds -lt 60) {
                foreach ($h in @(Get-ChildItem -LiteralPath $x.HomeRoot -Directory -Filter 'home-*' -ErrorAction SilentlyContinue)) {
                    $l = Join-Path $h.FullName 'owner.lock'
                    if (-not (Test-Path -LiteralPath $l)) { continue }
                    try { ([IO.File]::Open($l, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)).Dispose() } catch { $other = $h.FullName }
                }
                if (-not $other) { Start-Sleep -Milliseconds 250 }
            }
            $other | Should -Not -BeNullOrEmpty -Because 'the parallel build created and holds its home'
            $b = Invoke-PbivizBuild -Root $x.Repo -Visual 'Column' -TimeoutSeconds 60
            $b.Status | Should -Be 'PASS' -Because $b.Reason
            Test-Path -LiteralPath $other | Should -BeTrue -Because 'the sweep never removes the home of a live build'
            $r = Wait-Job $job -Timeout 90 | Receive-Job
            $r.Status | Should -Be 'FAILED'
            $r.Reason | Should -Match 'timed out after 40 s'
            Test-Path -LiteralPath $other | Should -BeFalse -Because 'the parallel build removed its own home when it ended'
        } finally { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Archive-only promotions verify completely at the source revision (Canary D3)' {

    BeforeAll {
        # Prod starts without Bar; a validated Level 1 release of Bar on Dev reaches Prod through an
        # archive-only promotion, so the Prod commit carries the pair but no Bar source.
        function New-TArchiveOnly {
            $r = New-TRepo
            Write-TFile $r 'README.md' 'base'
            Save-TAll $r 'base' | Out-Null
            TGit $r branch PBVIZ_Team_Prod | Out-Null
            TGit $r switch -q -c PBVIZ_Team_Dev | Out-Null
            New-TVisual $r 'Bar' 'barGuid0001' '1.0.0.1'
            $src = Save-TAll $r 'bar'
            (Invoke-TBuild -Dir $r).Status | Should -Be 'PASS'
            $ev = Get-TEvidence -Sha $src
            $rel = Add-PbivizRelease -Root $r -Visual 'Bar' -SourceSha $src @ev
            $rel.Status | Should -Be 'PASS' -Because $rel.Reason
            $rel.Validated | Should -BeTrue
            TGit $r commit -q -m 'release Bar 1.0.0.1' | Out-Null
            $c = New-PbivizPromotionCandidate -Root $r -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod -ArchiveOnly
            $c.Status | Should -Be 'PASS' -Because $c.Reason
            $g = Test-PbivizPromotionGates -Worktree $c.Worktree -Visual 'Bar' -TargetRef PBVIZ_Team_Prod -ArchiveOnly
            $g.Status | Should -Be 'PASS' -Because $g.Reason
            TGit $c.Worktree commit -q -m 'archive-only: Bar 1.0.0.1' | Out-Null
            @(TGit $c.Worktree ls-tree '-r' --name-only HEAD -- 'Bar/src') | Where-Object { $_ } | Should -BeNullOrEmpty -Because 'the Prod commit carries no Bar source'
            return [pscustomobject]@{ Repo = $r; Wt = $c.Worktree; Branch = $c.Branch; Src = $src; Manifest = 'Bar/releases/barGuid0001.1.0.0.1.release.json'; Package = 'Bar/releases/barGuid0001.1.0.0.1.pbiviz' }
        }
    }

    It 'verifies a validated archive-only release COMPLETELY: commit evidence at Prod, source binding at the source revision' {
        $x = New-TArchiveOnly
        $i = Test-PbivizReleaseIntegrity -Root $x.Repo -Visual 'Bar' -Version '1.0.0.1' -Commit (TGit $x.Wt rev-parse HEAD)
        $i.Status | Should -Be 'PASS' -Because $i.Reason
        $i.Verification | Should -Be 'COMPLETE'
        $i.CommitEvidence | Should -Be 'VERIFIED'
        $i.SourceRevision | Should -Be 'VERIFIED'
        $i.ReleaseClass | Should -Be 'OFFICIAL RELEASE'
        ($i.Evidence -join ' ') | Should -Match 'archive-only\): shared files and the archived pair .* the source fingerprint is NOT compared at this commit - only at the source revision'
    }

    It 'reports PARTIAL / COMMIT ONLY when the source revision is not in the clone' {
        $x = New-TArchiveOnly
        $clone = New-TDir 'cl'
        Remove-Item -LiteralPath $clone
        TGit $script:Root clone -q --no-tags --single-branch --branch $x.Branch ('file:///' + ($x.Repo -replace '\\', '/')) $clone | Out-Null
        $i = Test-PbivizReleaseIntegrity -Root $clone -Visual 'Bar' -Version '1.0.0.1' -Commit HEAD
        $i.Status | Should -Be 'PARTIAL'
        $i.Verification | Should -Be 'COMMIT ONLY'
        $i.SourceRevision | Should -Be 'NOT AVAILABLE'
    }

    It 'FAILS an archive-only release whose <Case>' -TestCases @(
        @{ Case = 'package bytes were altered'; Kind = 'package'; Match = 'SHA-256 differs' },
        @{ Case = 'manifest size was edited'; Kind = 'bytes'; Match = 'package size differs from the manifest' },
        @{ Case = 'manifest fingerprint no longer matches the source revision'; Kind = 'fingerprint'; Match = 'does not yield the manifest fingerprint' },
        @{ Case = 'manifest claims a shared file the commit does not hold'; Kind = 'shared'; Match = "shared file 'shared/fmt\.ts' at [0-9a-f]{12} is ''" }
    ) {
        $x = New-TArchiveOnly
        $mp = Join-Path $x.Wt ($x.Manifest -replace '/', '\')
        switch ($Kind) {
            'package' { Write-TPackage -Path (Join-Path $x.Wt ($x.Package -replace '/', '\')) -Guid 'barGuid0001' -Version '1.0.0.1' -Seed 91; TGit $x.Wt add -- $x.Package | Out-Null }
            default {
                $j = [IO.File]::ReadAllText($mp) | ConvertFrom-Json
                switch ($Kind) {
                    'bytes' { $j.bytes = 1 }
                    'fingerprint' { $j.sourceFingerprint = ('a' * 64); $j.build.sourceFingerprint = ('a' * 64) }
                    'shared' { $j.sharedFiles = @([pscustomobject]@{ path = 'shared/fmt.ts'; blob = ('1' * 40) }) }
                }
                [IO.File]::WriteAllText($mp, ($j | ConvertTo-Json -Depth 8))
                TGit $x.Wt add -- $x.Manifest | Out-Null
            }
        }
        TGit $x.Wt commit -q -m "tamper $Kind" | Out-Null
        $i = Test-PbivizReleaseIntegrity -Root $x.Repo -Visual 'Bar' -Version '1.0.0.1' -Commit (TGit $x.Wt rev-parse HEAD)
        $i.Status | Should -Be 'FAILED'
        $i.Reason | Should -Match $Match
        $i.ReleaseClass | Should -BeNullOrEmpty
    }
}

Describe 'Test-stage reconciliation keeps rejected content out of Prod (Canary D4)' {

    It 'reconciles only the selected visual on Test through test-sync, keeps the rejected pair as history and promotes the unchanged release branch' {
        $r = New-TL3
        TGit $r branch PBVIZ_Team_Test PBVIZ_Team_Prod | Out-Null
        # Test also carries a tested change of another visual that reconciliation must not touch.
        TGit $r switch -q PBVIZ_Team_Test | Out-Null
        Write-TFile $r 'Column/src/visual.ts' 'export class Visual { testOnly = true }'
        Save-TAll $r 'Column change on Test' | Out-Null
        $columnOnTest = TGit $r rev-parse 'PBVIZ_Team_Test:Column'
        $columnOnProd = TGit $r rev-parse 'PBVIZ_Team_Prod:Column'
        TGit $r switch -q PBVIZ_Team_Dev | Out-Null
        # V1 1.0.0.2: released to Test, then rejected there.
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Write-TFile $r 'Bar/src/visual.ts' 'export class Visual { v = 2 }'
        Write-TFile $r 'Bar/src/rejected-only.ts' 'export const rejected = true;'
        Save-TAll $r 'Bar 1.0.0.2 (rejected in Test later)' | Out-Null
        $p1 = Invoke-TPromotion -Repo $r
        $p1.Gates.Status | Should -Be 'PASS' -Because $p1.Gates.Reason
        TGit $p1.Candidate.Worktree commit -q -m 'release Bar 1.0.0.2' | Out-Null
        TGit $r switch -q PBVIZ_Team_Test | Out-Null
        TGit $r merge -q --no-ff -m 'PR1 Bar 1.0.0.2 into Test' $p1.Candidate.Branch | Out-Null
        (Test-PbivizReleaseIntegrity -Root $r -Visual 'Bar' -Version '1.0.0.2' -Commit PBVIZ_Team_Test).Status | Should -Be 'PASS'
        TGit $r switch -q PBVIZ_Team_Dev | Out-Null
        # V2 1.0.0.3: the fix is a new Dev commit and a new version, cut from the Prod tip again.
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.3'
        Write-TFile $r 'Bar/src/visual.ts' 'export class Visual { v = 3 }'
        TGit $r rm -q -- 'Bar/src/rejected-only.ts' | Out-Null
        Save-TAll $r 'Bar 1.0.0.3 fix' | Out-Null
        $p2 = Invoke-TPromotion -Repo $r -Seed 12
        $p2.Gates.Status | Should -Be 'PASS' -Because $p2.Gates.Reason
        TGit $p2.Candidate.Worktree commit -q -m 'release Bar 1.0.0.3' | Out-Null
        $rel = $p2.Candidate.Branch
        $relTip = TGit $r rev-parse $rel
        # One candidate per release: a second one for the same version is refused.
        (New-PbivizPromotionCandidate -Root $r -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod).Status | Should -Be 'BLOCKED'
        # A naive pull request 1 (resolving only the conflicting paths) leaves rejected source on Test.
        TGit $r switch -q -c naive PBVIZ_Team_Test | Out-Null
        TGitExit $r merge --no-ff --no-commit $rel | Should -Not -Be 0 -Because 'Test still holds the rejected Bar source'
        foreach ($p in @((TGit $r diff --name-only --diff-filter=U) -split "`n" | Where-Object { $_ })) { TGit $r checkout --theirs -- $p | Out-Null; TGit $r add -- $p | Out-Null }
        TGit $r commit -q -m 'naive resolution' | Out-Null
        $naive = Test-PbivizReleaseIntegrity -Root $r -Visual 'Bar' -Version '1.0.0.3' -Commit HEAD
        $naive.Status | Should -Be 'FAILED' -Because 'the rejected rejected-only.ts is still in the Bar source scope on Test'
        # The documented mechanism: test-sync/<visual>/<version> from the Test tip.
        TGit $r switch -q -c 'test-sync/Bar/1.0.0.3' PBVIZ_Team_Test | Out-Null
        TGitExit $r merge --no-ff --no-commit $rel | Out-Null
        TGit $r checkout $rel -- Bar | Out-Null
        $relFiles = @((TGit $r ls-tree '-r' --name-only $rel -- Bar) -split "`n" | Where-Object { $_ })
        $extra = @((TGit $r ls-files -- Bar) -split "`n" | Where-Object { $_ -and $_ -notlike 'Bar/releases/*' -and $relFiles -notcontains $_ })
        ($extra -join '|') | Should -Be 'Bar/src/rejected-only.ts'
        foreach ($p in $extra) { TGit $r rm -q -- $p | Out-Null }
        @((TGit $r diff --name-only --diff-filter=U) -split "`n" | Where-Object { $_ }).Count | Should -Be 0
        @((TGit $r diff --cached --name-only PBVIZ_Team_Test) -split "`n" | Where-Object { $_ -and -not $_.StartsWith('Bar/') }).Count | Should -Be 0 -Because 'only the selected visual is reconciled'
        TGit $r commit -q -m 'Merge release Bar 1.0.0.3 into Test via test-sync' | Out-Null
        TGit $r switch -q PBVIZ_Team_Test | Out-Null
        TGit $r merge -q --no-ff -m 'PR1 test-sync/Bar/1.0.0.3 into Test' 'test-sync/Bar/1.0.0.3' | Out-Null
        $onTest = Test-PbivizReleaseIntegrity -Root $r -Visual 'Bar' -Version '1.0.0.3' -Commit PBVIZ_Team_Test
        $onTest.Status | Should -Be 'PASS' -Because $onTest.Reason
        $onTest.Verification | Should -Be 'COMPLETE'
        TGit $r ls-tree --name-only PBVIZ_Team_Test -- 'Bar/releases/barGuid0001.1.0.0.2.pbiviz' | Should -Be 'Bar/releases/barGuid0001.1.0.0.2.pbiviz' -Because 'the rejected pair stays in the Test archive as history'
        TGit $r rev-parse 'PBVIZ_Team_Test:Column' | Should -Be $columnOnTest -Because 'the other visual on Test is untouched'
        TGit $r rev-parse $rel | Should -Be $relTip -Because 'the release branch itself is never changed on the way to Test'
        # Pull request 2: the SAME release branch to Prod.
        TGit $r switch -q PBVIZ_Team_Prod | Out-Null
        TGit $r merge -q --no-ff -m 'PR2 Bar 1.0.0.3 into Prod' $rel | Out-Null
        $onProd = Test-PbivizReleaseIntegrity -Root $r -Visual 'Bar' -Version '1.0.0.3' -Commit PBVIZ_Team_Prod
        $onProd.Status | Should -Be 'PASS' -Because $onProd.Reason
        $onProd.ReleaseClass | Should -Be 'OFFICIAL RELEASE'
        TGit $r ls-tree '-r' --name-only PBVIZ_Team_Prod -- 'Bar' | Should -Not -Match 'rejected-only|1\.0\.0\.2' -Because 'rejected content never reaches Prod'
        TGit $r rev-parse 'PBVIZ_Team_Prod:Column' | Should -Be $columnOnProd -Because 'the Test-only change of another visual did not reach Prod'
    }
}

Describe 'Gate results stay readable in Windows PowerShell 5.1 (Canary D11)' {

    It 'returns all seven gates as a plain array for PASS and BLOCKED results' {
        $r = New-TL3
        Set-TVersion $r 'Bar' 'barGuid0001' '1.0.0.2'
        Save-TAll $r 'bar v2' | Out-Null
        $p = Invoke-TPromotion -Repo $r
        $g = $p.Gates
        $g.Status | Should -Be 'PASS' -Because $g.Reason
        $g.Gates.GetType().FullName | Should -Be 'System.Object[]'
        { @($g.Gates) } | Should -Not -Throw
        @($g.Gates).Count | Should -Be 7
        (@($g.Gates | ForEach-Object { $_.Gate }) -join ',') | Should -Be 'G0,G1,G2,G3,G4,G5,G6'
        @($g.Gates | Where-Object { -not $_.Pass }).Count | Should -Be 0
        Write-TFile $p.Candidate.Worktree 'Column/src/visual.ts' 'export class Visual { sneaked = true }'
        TGit $p.Candidate.Worktree add -- 'Column/src/visual.ts' | Out-Null
        $b = Test-PbivizPromotionGates -Worktree $p.Candidate.Worktree -Visual 'Bar' -TargetRef PBVIZ_Team_Prod
        $b.Status | Should -Be 'BLOCKED'
        $b.Gates.GetType().FullName | Should -Be 'System.Object[]'
        @($b.Gates).Count | Should -Be 7
        @($b.Gates | Where-Object { -not $_.Pass } | ForEach-Object { $_.Gate }) | Should -Contain 'G3'
        (Get-TGate $b 'G3').Detail | Should -Match 'other visuals changed: Column'
    }
}
