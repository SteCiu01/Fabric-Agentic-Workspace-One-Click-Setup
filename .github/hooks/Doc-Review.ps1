#requires -Version 5.1
<#
Documentation review for this repository: hook handler, reviewer attestation and release gate.
Maintainer tooling. The installer does not ship it and never reads it.

  -HookEvent <name>   called by .github/hooks/documentation-review.json; reads the event as JSON on stdin
  -Attest             the Communication Writer records its verdict for the current state of the files
  -NoImpact           records that the current change needs no documentation (advisory hook only)
  -Status             shows the current state and the latest recorded review
  -Gate               release gate: exit code 0 only when a confirmed review matches the current files

A review counts only when three things agree: the Writer attested, the session's SubagentStop
hook saw that Writer finish, and no watched file changed in between or since.
Running this script by hand never creates a review.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$HookEvent,
    [switch]$Attest,
    [ValidateSet('complete', 'incomplete')][string]$Verdict,
    [string]$Summary,
    [switch]$NoImpact,
    [string]$Reason,
    [switch]$Status,
    [switch]$Gate
)

$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Root = if ($env:DOC_REVIEW_ROOT) { $env:DOC_REVIEW_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$script:Root = [IO.Path]::GetFullPath($script:Root).TrimEnd('\')

# What a documentation review covers. Tests, workflows and this tooling are not part of it.
$script:SourceFolders = @('fabric-agentic-installer', 'schema')
$script:Documents = @('README.md', 'CHANGELOG.md', 'CLI-FUNCTIONALITIES.md', 'CONTRIBUTING.md', 'tests/README.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md')
$script:PolicyDocuments = @('SECURITY.md', 'CODE_OF_CONDUCT.md')
$script:LockedDocuments = @('LICENSE', 'THIRD_PARTY_NOTICES.md')
$script:WriterName = 'Communication Writer'
# Full path: the terminal of an agent is not always in the repository root (a window with several folders).
$script:SelfCommand = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
}

function Get-StateDir {
    if ($env:DOC_REVIEW_STATE) { return $env:DOC_REVIEW_STATE }
    $git = Join-Path $script:Root '.git'
    if (Test-Path -LiteralPath $git -PathType Container) { return (Join-Path $git 'doc-review') }
    # No .git folder here (a worktree or a plain copy): keep the state outside the tree.
    $id = Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($script:Root.ToLowerInvariant()))
    return (Join-Path ([IO.Path]::GetTempPath()) ('doc-review-' + $id.Substring(0, 16)))
}

function Get-StatePath([string]$Folder, [string]$Name) {
    $dir = Join-Path (Get-StateDir) $Folder
    if (-not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    if ($Name) { return (Join-Path $dir $Name) }
    return $dir
}

function Read-FileBytes([string]$Path) {
    for ($i = 0; ; $i++) {
        try { return [IO.File]::ReadAllBytes($Path) } catch [IO.IOException] { if ($i -ge 4) { throw }; Start-Sleep -Milliseconds 120 }
    }
}

# Every watched file with its SHA-256, plus one fingerprint for all of them and one for the source files.
function Get-Snapshot {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($folder in $script:SourceFolders) {
        $dir = Join-Path $script:Root $folder
        if (Test-Path -LiteralPath $dir -PathType Container) {
            foreach ($f in [IO.Directory]::GetFiles($dir, '*', [IO.SearchOption]::AllDirectories)) { $paths.Add($f.Substring($script:Root.Length + 1).Replace('\', '/')) }
        }
    }
    foreach ($doc in $script:Documents) { if (Test-Path -LiteralPath (Join-Path $script:Root $doc) -PathType Leaf) { $paths.Add($doc) } }
    $sorted = $paths.ToArray(); [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $files = [ordered]@{}
    $all = New-Object System.Text.StringBuilder
    $source = New-Object System.Text.StringBuilder
    foreach ($rel in $sorted) {
        $hash = Get-Sha256Hex (Read-FileBytes (Join-Path $script:Root $rel))
        $files[$rel] = $hash
        [void]$all.Append("$rel|$hash`n")
        if ($script:Documents -notcontains $rel) { [void]$source.Append("$rel|$hash`n") }
    }
    return [pscustomobject]@{
        files             = $files
        fingerprint       = Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($all.ToString()))
        sourceFingerprint = Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($source.ToString()))
    }
}

function ConvertTo-Map($Object) {
    $map = @{}
    if ($null -eq $Object) { return $map }
    if ($Object -is [Collections.IDictionary]) { foreach ($k in $Object.Keys) { $map[[string]$k] = [string]$Object[$k] }; return $map }
    foreach ($p in $Object.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
    return $map
}

function Get-ChangedFiles($Before, $After) {
    $a = ConvertTo-Map $Before; $b = ConvertTo-Map $After
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($k in $b.Keys) { if (-not $a.ContainsKey($k) -or $a[$k] -ne $b[$k]) { $changed.Add($k) } }
    foreach ($k in $a.Keys) { if (-not $b.ContainsKey($k)) { $changed.Add("$k (removed)") } }
    $r = $changed.ToArray(); [Array]::Sort($r, [StringComparer]::Ordinal)
    return , $r
}

# Whole-file replace, so a reader never sees a half-written record.
function Write-Atomic([string]$Path, [string]$Text) {
    $tmp = "$Path.$PID.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    [IO.File]::WriteAllText($tmp, $Text, $script:Utf8)
    for ($i = 0; ; $i++) {
        try {
            if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
            return
        } catch [IO.IOException] {
            if ($i -ge 4) { try { [IO.File]::Delete($tmp) } catch { }; throw }
            Start-Sleep -Milliseconds 80
        }
    }
}

function Write-JsonFile([string]$Path, $Data) { Write-Atomic $Path ($Data | ConvertTo-Json -Depth 8) }

function Read-JsonFile([string]$Path) {
    try { if ([IO.File]::Exists($Path)) { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } } catch { }
    return $null
}

function Get-SafeId([string]$Value, [string]$Fallback) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Fallback }
    if ($Value -match '^[A-Za-z0-9_-]{1,80}$') { return $Value }
    return (Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($Value))).Substring(0, 32)
}

function Write-Log([string]$SessionId, [string]$Text) {
    $line = '{0}Z {1}{2}' -f [DateTime]::UtcNow.ToString('s'), $Text, "`r`n"
    $path = Get-StatePath 'log' "$SessionId.log"
    for ($i = 0; $i -lt 5; $i++) { try { [IO.File]::AppendAllText($path, $line, $script:Utf8); return } catch [IO.IOException] { Start-Sleep -Milliseconds 60 } }
}

# A review record is valid only when the hook wrote it for a Writer that finished with the verdict 'complete'.
function Get-Reviews {
    $list = @()
    foreach ($f in [IO.Directory]::GetFiles((Get-StatePath 'reviews'), '*.json')) {
        $r = Read-JsonFile $f
        if ($r -and $r.kind -eq 'writer-review' -and $r.verdict -eq 'complete' -and $r.confirmedBy -eq 'SubagentStop hook' -and $r.fingerprint) { $list += $r }
    }
    return @($list | Sort-Object { [long]$_.confirmedTicks } -Descending)
}

function Find-Review([string]$Fingerprint) { return (@(Get-Reviews) | Where-Object { $_.fingerprint -eq $Fingerprint } | Select-Object -First 1) }

function Test-NoImpact([string]$Fingerprint) { return [IO.File]::Exists((Get-StatePath 'noimpact' "$Fingerprint.json")) }

function Format-FileList([string[]]$Files, [int]$Max = 8) {
    if (-not $Files -or $Files.Count -eq 0) { return 'none' }
    $shown = @($Files | Select-Object -First $Max) -join ', '
    if ($Files.Count -gt $Max) { $shown += " and $($Files.Count - $Max) more" }
    return $shown
}

function Remove-OldState {
    $limit = [DateTime]::UtcNow.AddDays(-30)
    foreach ($folder in 'sessions', 'runs', 'log', 'attest', 'attest\used', 'subprompt') {
        try { foreach ($f in [IO.Directory]::GetFiles((Get-StatePath $folder))) { if ([IO.File]::GetLastWriteTimeUtc($f) -lt $limit) { [IO.File]::Delete($f) } } } catch { }
    }
}

# -- Hook events --------------------------------------------------------------------------------

function Write-HookOutput($Data) { [Console]::Out.Write(($Data | ConvertTo-Json -Depth 6 -Compress)) }

function Write-Block([string]$EventName, [string]$Text) {
    Write-HookOutput @{ decision = 'block'; reason = $Text; hookSpecificOutput = @{ hookEventName = $EventName; decision = 'block'; reason = $Text } }
}

function Get-Field($Data, [string[]]$Names) {
    foreach ($n in $Names) { $p = $Data.PSObject.Properties[$n]; if ($p -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)) { return [string]$p.Value } }
    return ''
}

function Test-IsWriter($Data) {
    $want = ($script:WriterName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    foreach ($n in 'agent_type', 'agentType', 'agent_name', 'agentName', 'agent_display_name', 'agentDisplayName') {
        $p = $Data.PSObject.Properties[$n]
        if ($p -and (([string]$p.Value) -replace '[^A-Za-z0-9]', '').ToLowerInvariant() -eq $want) { return $true }
    }
    return $false
}

# The editor fires UserPromptSubmit for a subagent's prompt too, right after its SubagentStart and
# with no agent field. SubagentStart leaves a marker; the prompt event that follows consumes it.
$script:SubagentPromptWindowSeconds = 120

function Add-SubagentPromptMarker([string]$Sid, [string]$AgentId) {
    $name = '{0}.{1}.{2}.{3}' -f $Sid, [DateTime]::UtcNow.Ticks, $AgentId, [guid]::NewGuid().ToString('N').Substring(0, 6)
    [IO.File]::WriteAllText((Get-StatePath 'subprompt' $name), '', $script:Utf8)
}

function Use-SubagentPromptMarker([string]$Sid) {
    $limit = [DateTime]::UtcNow.AddSeconds(-$script:SubagentPromptWindowSeconds)
    $markers = @([IO.Directory]::GetFiles((Get-StatePath 'subprompt'), "$Sid.*") | Where-Object { $_ -notlike '*.used' } | Sort-Object)
    foreach ($m in $markers) {
        $fresh = [IO.File]::GetLastWriteTimeUtc($m) -ge $limit
        # Move is the claim: of two prompt events racing for one marker, only one succeeds.
        try { [IO.File]::Move($m, "$m.used"); [IO.File]::Delete("$m.used") } catch { continue }
        if ($fresh) { return $true }
    }
    return $false
}

function Invoke-PromptEvent([string]$Sid) {
    if (Use-SubagentPromptMarker $Sid) {
        Write-Log $Sid 'UserPromptSubmit of a subagent: turn baseline kept'
        Write-HookOutput @{}; return
    }
    $snap = Get-Snapshot
    # A review an earlier task of this session left open stays open: the next task is reminded once.
    $previous = Read-JsonFile (Get-StatePath 'sessions' "$Sid.json")
    $pending = if ($previous -and $previous.pendingFingerprint -and -not (Find-Review ([string]$previous.pendingFingerprint))) { [string]$previous.pendingFingerprint } else { '' }
    Write-JsonFile (Get-StatePath 'sessions' "$Sid.json") ([ordered]@{
            sessionId = $Sid; turnStartedUtc = [DateTime]::UtcNow.ToString('s') + 'Z'; baselineFingerprint = $snap.fingerprint; baselineFiles = $snap.files
            blocksThisTurn = 0; pendingFingerprint = $pending; warnedFingerprint = ''
        })
    Write-Log $Sid "UserPromptSubmit baseline=$($snap.fingerprint.Substring(0, 12))"
    Remove-OldState
    Write-HookOutput @{}
}

function Invoke-StopEvent([string]$Sid, $Data) {
    if (Get-Field $Data @('agent_id', 'agentId')) { Write-Log $Sid 'Stop inside a subagent: ignored'; Write-HookOutput @{}; return }
    $snap = Get-Snapshot
    $path = Get-StatePath 'sessions' "$Sid.json"
    $s = Read-JsonFile $path
    if (-not $s -or -not $s.baselineFingerprint) {
        # First event of this session seen by the hook: nothing to compare with yet.
        Write-JsonFile $path ([ordered]@{ sessionId = $Sid; turnStartedUtc = [DateTime]::UtcNow.ToString('s') + 'Z'; baselineFingerprint = $snap.fingerprint; baselineFiles = $snap.files; blocksThisTurn = 0; pendingFingerprint = ''; warnedFingerprint = '' })
        Write-Log $Sid 'Stop decision=allow reason=no-baseline-for-this-turn'
        Write-HookOutput @{}; return
    }
    $reviewed = [bool](Find-Review $snap.fingerprint)
    $save = { param($Changes) foreach ($k in $Changes.Keys) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $Changes[$k] -Force }; Write-JsonFile $path $s }

    if ($snap.fingerprint -eq $s.baselineFingerprint) {
        # Nothing changed in this turn. Remind once if an earlier turn of this session left a review open.
        if (-not $reviewed -and $s.pendingFingerprint -eq $snap.fingerprint -and $s.warnedFingerprint -ne $snap.fingerprint -and -not (Test-NoImpact $snap.fingerprint)) {
            & $save @{ warnedFingerprint = $snap.fingerprint; pendingFingerprint = '' }
            Write-Log $Sid 'Stop decision=allow warning=review-still-open'
            Write-HookOutput @{ systemMessage = "Documentation review still open: files changed earlier in this session have not been reviewed by the $($script:WriterName)." }
            return
        }
        Write-Log $Sid 'Stop decision=allow reason=no-change-this-turn'
        Write-HookOutput @{}; return
    }
    if ($reviewed) { Write-Log $Sid 'Stop decision=allow reason=reviewed'; Write-HookOutput @{}; return }
    if (Test-NoImpact $snap.fingerprint) { Write-Log $Sid 'Stop decision=allow reason=no-impact-recorded'; Write-HookOutput @{}; return }

    $changed = Get-ChangedFiles $s.baselineFiles $snap.files
    $blocks = [int]$s.blocksThisTurn
    # A review recorded since the last request answered that request: what changed after it is a new one.
    $lastBlock = if ($s.PSObject.Properties['lastBlockTicks'] -and $s.lastBlockTicks) { [long]$s.lastBlockTicks } else { 0L }
    $newRequest = $blocks -gt 0 -and $lastBlock -gt 0 -and [bool](@(Get-Reviews) | Where-Object { [long]$_.confirmedTicks -gt $lastBlock } | Select-Object -First 1)
    if ($newRequest) { $blocks = 0 }
    $active = ((Get-Field $Data @('stop_hook_active', 'stopHookActive')) -eq 'True')
    if ($active -and $blocks -eq 0 -and -not $newRequest) { $blocks = 1 }
    if ($blocks -eq 0) {
        & $save @{ blocksThisTurn = 1; pendingFingerprint = $snap.fingerprint; lastBlockTicks = [DateTime]::UtcNow.Ticks }
        Write-Log $Sid "Stop decision=block request=1 changed=$($changed.Count)"
        Write-Block 'Stop' ("Documentation review needed before this task ends. Changed in this task: $(Format-FileList $changed). " +
            "Run the '$($script:WriterName)' agent as a subagent now: tell it what changed and what a user would notice, and let it update the documents. Do not write the review yourself. " +
            "If nothing a user or contributor can observe changed (refactoring, comments), record that instead: $($script:SelfCommand) -NoImpact -Reason `"<one sentence>`".")
        return
    }
    if ($blocks -eq 1) {
        & $save @{ blocksThisTurn = 2; pendingFingerprint = $snap.fingerprint; lastBlockTicks = [DateTime]::UtcNow.Ticks }
        Write-Log $Sid "Stop decision=block request=2 changed=$($changed.Count)"
        Write-Block 'Stop' ("The documentation review is still not recorded for the current files (no '$($script:WriterName)' run finished with a completed verdict, or files changed after it). " +
            "Try once more: run the '$($script:WriterName)' agent as a subagent. If that is not possible in this session, tell the user plainly that the documentation review is incomplete.")
        return
    }
    & $save @{ pendingFingerprint = $snap.fingerprint; warnedFingerprint = $snap.fingerprint }
    Write-Log $Sid "Stop decision=allow result=REVIEW-INCOMPLETE changed=$($changed.Count)"
    Write-HookOutput @{ systemMessage = "Documentation review INCOMPLETE: $(Format-FileList $changed) changed in this task and no $($script:WriterName) review was recorded. The release gate will not pass until one is." }
}

function Invoke-SubagentStart([string]$Sid, $Data) {
    $agentId = Get-SafeId (Get-Field $Data @('agent_id', 'agentId')) 'writer'
    Add-SubagentPromptMarker $Sid $agentId
    if (-not (Test-IsWriter $Data)) { Write-HookOutput @{}; return }
    $snap = Get-Snapshot
    $locked = @{}; foreach ($d in $script:LockedDocuments) { $locked[$d] = [string]$snap.files[$d] }
    $policy = @{}; foreach ($d in $script:PolicyDocuments) { $policy[$d] = [string]$snap.files[$d] }
    Write-JsonFile (Get-StatePath 'runs' "$Sid.$agentId.json") ([ordered]@{
            sessionId = $Sid; agentId = $agentId; startedTicks = [DateTime]::UtcNow.Ticks; startedUtc = [DateTime]::UtcNow.ToString('s') + 'Z'
            sourceFingerprint = $snap.sourceFingerprint; locked = $locked; policy = $policy; stopBlocks = 0
        })
    $last = @(Get-Reviews) | Select-Object -First 1
    $scope = if ($last) { "Changed since the last recorded review: $(Format-FileList (Get-ChangedFiles $last.files $snap.files) 12)." } else { 'No earlier review is recorded: check every document against the current source.' }
    $context = "Documentation review run. $scope Record your verdict as your last action: $($script:SelfCommand) -Attest -Verdict complete -Summary `"<one sentence>`" (or -Verdict incomplete)."
    Write-Log $Sid "SubagentStart writer agent=$agentId"
    Write-HookOutput @{ additionalContext = $context; hookSpecificOutput = @{ hookEventName = 'SubagentStart'; additionalContext = $context } }
}

function Invoke-SubagentStop([string]$Sid, $Data) {
    if (-not (Test-IsWriter $Data)) { Write-HookOutput @{}; return }
    $agentId = Get-SafeId (Get-Field $Data @('agent_id', 'agentId')) 'writer'
    $runPath = Get-StatePath 'runs' "$Sid.$agentId.json"
    $run = Read-JsonFile $runPath
    if (-not $run) { Write-Log $Sid "SubagentStop writer agent=$agentId result=NO-REVIEW reason=start-not-seen"; Write-HookOutput @{}; return }
    $snap = Get-Snapshot
    $canBlock = ([int]$run.stopBlocks -eq 0) -and ((Get-Field $Data @('stop_hook_active', 'stopHookActive')) -ne 'True')
    $blockOnce = {
        param([string]$Why, [string]$Text)
        $run.stopBlocks = 1; Write-JsonFile $runPath $run
        Write-Log $Sid "SubagentStop writer agent=$agentId decision=block reason=$Why"
        Write-Block 'SubagentStop' $Text
    }

    # The newest attestation written during this run.
    $attestation = $null; $attestFile = $null
    foreach ($f in @([IO.Directory]::GetFiles((Get-StatePath 'attest'), '*.json') | Sort-Object -Descending)) {
        $a = Read-JsonFile $f
        if ($a -and [long]$a.attestedTicks -ge [long]$run.startedTicks) { $attestation = $a; $attestFile = $f; break }
    }
    if (-not $attestation) {
        if ($canBlock) { & $blockOnce 'no-attestation' "Before you finish, record your verdict: $($script:SelfCommand) -Attest -Verdict complete -Summary `"<one sentence>`" (use -Verdict incomplete if you could not finish the review)."; return }
        Write-Log $Sid "SubagentStop writer agent=$agentId result=NO-REVIEW reason=no-attestation"; Write-HookOutput @{}; return
    }
    if ($attestation.fingerprint -ne $snap.fingerprint) {
        if ($canBlock) { & $blockOnce 'changed-after-attestation' "Files changed after you recorded your verdict ($(Format-FileList (Get-ChangedFiles $attestation.files $snap.files))). Check them, then record the verdict again as your very last action."; return }
        Write-Log $Sid "SubagentStop writer agent=$agentId result=NO-REVIEW reason=changed-after-attestation"; Write-HookOutput @{}; return
    }
    $problem = ''
    if ($snap.sourceFingerprint -ne $run.sourceFingerprint) { $problem = 'source-changed-during-review' }
    foreach ($d in $script:LockedDocuments) { if ([string]$snap.files[$d] -ne [string]$run.locked.$d) { $problem = "locked-document-changed:$d" } }
    $policyChanged = @($script:PolicyDocuments | Where-Object { [string]$snap.files[$_] -ne [string]$run.policy.$_ })
    $used = Join-Path (Get-StatePath 'attest\used') ([IO.Path]::GetFileName($attestFile))
    try { [IO.File]::Move($attestFile, $used) } catch { $problem = 'attestation-already-used' }
    if ($problem -or $attestation.verdict -ne 'complete') {
        $why = if ($problem) { $problem } else { 'verdict-incomplete' }
        Write-Log $Sid "SubagentStop writer agent=$agentId result=NO-REVIEW reason=$why"
        Write-HookOutput @{ systemMessage = "Documentation review not recorded ($why)." }
        return
    }
    $now = [DateTime]::UtcNow
    Write-JsonFile (Get-StatePath 'reviews' "$($snap.fingerprint).$($now.Ticks).json") ([ordered]@{
            schemaVersion = 1; kind = 'writer-review'; verdict = 'complete'; summary = [string]$attestation.summary
            fingerprint = $snap.fingerprint; sourceFingerprint = $snap.sourceFingerprint; files = $snap.files
            policyDocumentsChanged = $policyChanged
            sessionId = $Sid; agentId = $agentId; startedUtc = $run.startedUtc; attestedUtc = $attestation.attestedUtc
            confirmedUtc = $now.ToString('s') + 'Z'; confirmedTicks = $now.Ticks; confirmedBy = 'SubagentStop hook'
        })
    Write-Log $Sid "SubagentStop writer agent=$agentId result=REVIEW-RECORDED fingerprint=$($snap.fingerprint.Substring(0, 12)) policyChanged=$($policyChanged.Count)"
    Write-HookOutput @{}
}

function Invoke-Hook([string]$Name) {
    try { [Console]::OutputEncoding = $script:Utf8 } catch { }
    $stream = [Console]::OpenStandardInput(); $buffer = New-Object IO.MemoryStream; $stream.CopyTo($buffer)
    $text = [Text.Encoding]::UTF8.GetString($buffer.ToArray())
    $data = $null
    try { if ($text.Trim()) { $data = $text | ConvertFrom-Json } } catch { }
    if (-not $data) { $data = [pscustomobject]@{} }
    if (-not $Name) { $Name = Get-Field $data @('hook_event_name', 'hookEventName') }
    $sid = Get-SafeId (Get-Field $data @('session_id', 'sessionId')) 'no-session-id'
    # Field names only: prompts, arguments and results are never written anywhere.
    $agent = Get-Field $data @('agent_type', 'agentType', 'agent_name', 'agentName')
    Write-Log $sid ("event=$Name" + $(if ($agent) { " agent='$agent'" }) + " fields=$(@($data.PSObject.Properties.Name | Sort-Object) -join ',')")
    switch ($Name) {
        'UserPromptSubmit' { Invoke-PromptEvent $sid }
        'Stop' { Invoke-StopEvent $sid $data }
        'SubagentStart' { Invoke-SubagentStart $sid $data }
        'SubagentStop' { Invoke-SubagentStop $sid $data }
        default { Write-HookOutput @{} }
    }
}

# -- Command line -------------------------------------------------------------------------------

function Get-HookProblems {
    $problems = @()
    $config = Join-Path $script:Root '.github\hooks\documentation-review.json'
    $json = Read-JsonFile $config
    if (-not $json) { return , @("the hook configuration is missing or unreadable: .github/hooks/documentation-review.json") }
    if ($json.disableAllHooks -eq $true) { $problems += 'the hook configuration is disabled (disableAllHooks)' }
    foreach ($e in 'UserPromptSubmit', 'SubagentStart', 'SubagentStop', 'Stop') {
        $entries = @($json.hooks.$e)
        if (-not ($entries | Where-Object { ("$($_.powershell) $($_.command) $($_.windows)") -match 'Doc-Review\.ps1' })) { $problems += "the hook configuration has no $e entry for Doc-Review.ps1" }
    }
    foreach ($f in '.github\agents\communication-writer.agent.md', '.github\skills\product-communication\SKILL.md') {
        if (-not (Test-Path -LiteralPath (Join-Path $script:Root $f) -PathType Leaf)) { $problems += "missing: $($f.Replace('\', '/'))" }
    }
    return , @($problems)
}

function Show-State([switch]$AsGate) {
    $snap = Get-Snapshot
    $review = Find-Review $snap.fingerprint
    $last = @(Get-Reviews) | Select-Object -First 1
    $hookProblems = Get-HookProblems
    "Files under review: $(@($snap.files.Keys).Count)   fingerprint: $($snap.fingerprint.Substring(0, 12))"
    if ($review) {
        "Reviewed: yes - $($script:WriterName) run confirmed $($review.confirmedUtc) (session $(([string]$review.sessionId).Substring(0, [Math]::Min(8, ([string]$review.sessionId).Length))))"
        "Summary: $($review.summary)"
        if (@($review.policyDocumentsChanged).Count -gt 0) { "Policy documents changed in that review - the owner confirms them: $(@($review.policyDocumentsChanged) -join ', ')" }
    } elseif ($last) {
        "Reviewed: NO - the latest review ($($last.confirmedUtc)) is stale. Changed since: $(Format-FileList (Get-ChangedFiles $last.files $snap.files) 20)"
    } else {
        'Reviewed: NO - no review has been recorded for this repository.'
    }
    foreach ($p in $hookProblems) { "Hook problem: $p" }
    if ($AsGate) {
        if ($review -and $hookProblems.Count -eq 0) { 'DOC GATE: PASS'; return 0 }
        if ($review) { 'DOC GATE: FAIL - the files are reviewed, but the review workflow is not in place: restore what the "Hook problem" lines name, then run the gate again.'; return 1 }
        'DOC GATE: FAIL - run a Communication Writer review of the current files (ask your agent: "run a Communication Writer review"), then run the gate again.'
        return 1
    }
    return 0
}

try {
    if ($HookEvent) { Invoke-Hook $HookEvent; exit 0 }
    if ($Attest) {
        if (-not $Verdict) { [Console]::Error.WriteLine('-Attest needs -Verdict complete or -Verdict incomplete.'); exit 2 }
        $snap = Get-Snapshot; $now = [DateTime]::UtcNow
        Write-JsonFile (Get-StatePath 'attest' "$($now.Ticks).$([guid]::NewGuid().ToString('N').Substring(0, 8)).json") ([ordered]@{
                verdict = $Verdict; summary = [string]$Summary; fingerprint = $snap.fingerprint; files = $snap.files; attestedTicks = $now.Ticks; attestedUtc = $now.ToString('s') + 'Z'
            })
        "Verdict '$Verdict' noted for fingerprint $($snap.fingerprint.Substring(0, 12)). It becomes a review only when the session hook confirms it as the $($script:WriterName) finishes. Change no file now."
        exit 0
    }
    if ($NoImpact) {
        if ([string]::IsNullOrWhiteSpace($Reason)) { [Console]::Error.WriteLine('-NoImpact needs -Reason "<one sentence>".'); exit 2 }
        $snap = Get-Snapshot
        Write-JsonFile (Get-StatePath 'noimpact' "$($snap.fingerprint).json") ([ordered]@{ fingerprint = $snap.fingerprint; reason = $Reason; recordedUtc = [DateTime]::UtcNow.ToString('s') + 'Z' })
        'Noted: no documentation impact for the current files. This quiets the end-of-task reminder; the release gate still needs a review.'
        exit 0
    }
    if ($Gate) { $lines = @(Show-State -AsGate); $lines[0..($lines.Count - 2)]; exit [int]$lines[-1] }
    $lines = @(Show-State); $lines[0..($lines.Count - 2)]; exit 0
} catch {
    # A failed hook is a failed hook: it writes no review and says so.
    [Console]::Error.WriteLine("Doc-Review.ps1 failed: $($_.Exception.Message)")
    exit 1
}
