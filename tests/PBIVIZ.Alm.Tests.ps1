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
    # ok | fail (exit 1) | touch (rewrites a tracked file) | none (exit 0, no package) | hang (never ends).
    $script:FakePbivizJs = @'
const fs = require('fs'), path = require('path');
const here = path.join(__dirname, '..');
const modeFile = path.join(here, 'fake-mode.txt');
const mode = fs.existsSync(modeFile) ? fs.readFileSync(modeFile, 'utf8').trim() : 'ok';
if (process.argv[2] !== 'package') { console.error('fake pbiviz: only package'); process.exit(2); }
if (mode === 'hang') { setTimeout(() => process.exit(0), 600000); return; }
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
        param([string]$Dir, [string]$Visual = 'Bar', [string]$Mode = 'ok', [int]$Seed = 11, [string]$ToolsVersion = '7.2.2')
        $tools = "$Visual/node_modules/powerbi-visuals-tools"
        Write-TFile $Dir "$tools/package.json" "{ ""name"": ""powerbi-visuals-tools"", ""version"": ""$ToolsVersion"" }"
        Write-TFile $Dir "$tools/bin/pbiviz.js" $script:FakePbivizJs
        Write-TFile $Dir "$tools/fake-mode.txt" $Mode
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
