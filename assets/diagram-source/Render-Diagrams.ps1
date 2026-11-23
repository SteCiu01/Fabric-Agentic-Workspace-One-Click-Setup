<#
.SYNOPSIS
    Regenerates the README diagrams (assets/*.png) from the HTML files in this folder with a locally installed
    Microsoft Edge or Google Chrome in headless mode. Nothing is installed or downloaded.
.PARAMETER Name
    One or more diagram names (the HTML file name without extension). Default: every *.html in this folder.
.PARAMETER OutDir
    Folder for the PNG files. Defaults to the parent folder (assets), where the README reads them.
.PARAMETER Browser
    Path to msedge.exe or chrome.exe. Defaults to the first one found in the standard install folders.
.PARAMETER CopilotIcon
    Path to the GitHub Copilot icon (PNG). Defaults to the copy that ships inside the local VS Code installation.
    When none is found, a neutral placeholder is drawn and a warning is printed.
#>
param(
    [string[]]$Name,
    [string]$OutDir = (Join-Path $PSScriptRoot '..'),
    [string]$Browser,
    [string]$CopilotIcon
)
$ErrorActionPreference = 'Stop'
$Width = 1000   # CSS width of every page; the PNG is rendered at 2x.

function Quote([string]$s) { '"' + $s + '"' }

if (-not $Name) { $Name = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.html | Sort-Object Name | ForEach-Object { $_.BaseName }) }
foreach ($n in $Name) { if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "$n.html"))) { throw "No diagram named '$n' in $PSScriptRoot." } }

if (-not $Browser) {
    $Browser = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
if (-not $Browser -or -not (Test-Path -LiteralPath $Browser)) { throw 'Microsoft Edge or Google Chrome was not found; pass -Browser <path to msedge.exe or chrome.exe>.' }

if (-not $CopilotIcon) {
    $roots = @("$env:LOCALAPPDATA\Programs\Microsoft VS Code", "$env:ProgramFiles\Microsoft VS Code")
    $code = Get-Command code -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($code) { $roots += Split-Path (Split-Path $code.Source) }
    $rel = 'resources\app\extensions\copilot\assets\copilot.png'
    $CopilotIcon = $roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object {
        Resolve-Path -Path (Join-Path $_ $rel), (Join-Path $_ "*\$rel") -ErrorAction SilentlyContinue
    } | Select-Object -First 1 -ExpandProperty ProviderPath
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('readme-diagrams-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    Copy-Item -Path (Join-Path $PSScriptRoot '*.html'), (Join-Path $PSScriptRoot '*.css') -Destination $work
    if ($CopilotIcon -and (Test-Path -LiteralPath $CopilotIcon)) {
        Copy-Item -LiteralPath $CopilotIcon -Destination (Join-Path $work 'copilot-icon.png')
        Write-Host "Copilot icon: $CopilotIcon"
    } else {
        Write-Warning 'GitHub Copilot icon not found (pass -CopilotIcon). A neutral placeholder is drawn instead, so the result differs from the published images.'
    }
    $common = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check', '--disable-extensions',
                '--disable-background-networking', '--disable-component-update', '--disable-sync')
    $i = 0
    foreach ($n in $Name) {
        $i++
        $url = ([Uri](Join-Path $work "$n.html")).AbsoluteUri

        # Pass 1: let the page report its own height (data-h on <html>).
        $dom = Join-Path $work "$n.dom.html"
        $a = $common + @("--user-data-dir=$(Quote (Join-Path $work "profile-measure-$i"))", "--window-size=$Width,200", '--dump-dom', $url)
        $p = Start-Process -FilePath $Browser -ArgumentList $a -RedirectStandardOutput $dom -RedirectStandardError (Join-Path $work "$n.dom.err") -PassThru -WindowStyle Hidden
        if (-not $p.WaitForExit(60000)) { $p.Kill(); throw "The browser did not finish measuring '$n' within 60 seconds." }
        # Browser helper processes can keep the redirected output open after the main process exits.
        $fs = [IO.File]::Open($dom, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs); $html = $sr.ReadToEnd(); $sr.Dispose()
        $m = [regex]::Match($html, 'data-h="(\d+)"')
        if (-not $m.Success) { throw "Could not read the page height of '$n' from the rendered page." }
        $height = [int]$m.Groups[1].Value

        # Pass 2: screenshot at exactly the page size, 2x device scale.
        $png = Join-Path $work "$n.png"
        $a = $common + @("--user-data-dir=$(Quote (Join-Path $work "profile-shot-$i"))", '--force-device-scale-factor=2', "--window-size=$Width,$height", "--screenshot=$(Quote $png)", $url)
        $p = Start-Process -FilePath $Browser -ArgumentList $a -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $work "$n.shot.err")
        if (-not $p.WaitForExit(60000)) { $p.Kill(); throw "The browser did not finish the screenshot of '$n' within 60 seconds." }
        if (-not (Test-Path -LiteralPath $png)) { throw "The browser did not write a screenshot of '$n'." }

        $target = Join-Path ([IO.Path]::GetFullPath($OutDir)) "$n.png"
        Copy-Item -LiteralPath $png -Destination $target -Force
        $b = [IO.File]::ReadAllBytes($target)
        $w = [int]$b[16] * 16777216 + [int]$b[17] * 65536 + [int]$b[18] * 256 + [int]$b[19]
        $h = [int]$b[20] * 16777216 + [int]$b[21] * 65536 + [int]$b[22] * 256 + [int]$b[23]
        Write-Host "Wrote $target ($w x $h px, $($b.Length) bytes)"
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
