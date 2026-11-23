#requires -Version 5.1
<#
Documentation review for this repository: hook handler, reviewer attestation, policy approvals and release gate.
Maintainer tooling. The installer does not ship it and never reads it.

  -HookEvent <name>   called by .github/hooks/documentation-review.json; reads the event as JSON on stdin
  -Attest -Run <id>   the Communication Writer records its verdict for its own run; the id is given to it
                      when the run starts, and a verdict without it is refused
  -NoImpact -Session <id> -Reason "..."   records that the change of that session needs no documentation
                      (quiets the end-of-task request of that session only; never a review)
  -ApprovePolicy -File <document> -ApprovedBy "<who>" -Reason "..."   records the owner's approval of the
                      CURRENT text of SECURITY.md, CODE_OF_CONDUCT.md, LICENSE or THIRD_PARTY_NOTICES.md
  -Status             shows the current state, the latest recorded review and the latest Writer run
  -Gate               release gate: exit code 0 only when a confirmed review matches the current files and
                      the policy and legal documents hold the text their owner approved

A review counts only when all of this agrees: a Communication Writer run was started in a session,
that run recorded a verdict under its own run id, the same session's SubagentStop hook saw that
Writer finish, the run changed nothing outside the Writer's allowlist, and no watched file changed
in between or since. A review belongs to the session that produced it: it ends that session's
end-of-task request, never another session's. The release gate looks at the files only.
Running this script by hand never creates a review.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$HookEvent,
    [switch]$Attest,
    [string]$Run,
    [ValidateSet('complete', 'incomplete')][string]$Verdict,
    [string]$Summary,
    [switch]$NoImpact,
    [string]$Session,
    [string]$Reason,
    [switch]$ApprovePolicy,
    [string]$File,
    [string]$ApprovedBy,
    [switch]$Status,
    [switch]$Gate
)

$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Root = if ($env:DOC_REVIEW_ROOT) { $env:DOC_REVIEW_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$script:Root = [IO.Path]::GetFullPath($script:Root).TrimEnd('\')

# What a documentation review covers: the product source, the images, the documents, and the review
# controls themselves (a review made under other rules is not a review of these). Tests and workflows are not part of it.
$script:SourceFolders = @('fabric-agentic-installer', 'schema', 'assets')
$script:Documents = @('README.md', 'CHANGELOG.md', 'CLI-FUNCTIONALITIES.md', 'CONTRIBUTING.md', 'tests/README.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md')
$script:ControlFiles = @('.github/agents/communication-writer.agent.md', '.github/skills/product-communication/SKILL.md', '.github/hooks/Doc-Review.ps1', '.github/hooks/documentation-review.json', '.github/hooks/policy-approvals.json')
# The only files a Communication Writer run may change. Everything else in the repository is compared before and after.
$script:WriterAllowlist = @('README.md', 'CHANGELOG.md', 'CLI-FUNCTIONALITIES.md', 'CONTRIBUTING.md', 'tests/README.md')
# Policy and legal text: changed only by its owner's decision, recorded for the exact text in policy-approvals.json.
$script:ProtectedDocuments = @('SECURITY.md', 'CODE_OF_CONDUCT.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md')
$script:ApprovalsFile = '.github/hooks/policy-approvals.json'
$script:GuardSkipFolders = @('.git', '.venv', 'venv', 'env', '__pycache__', 'node_modules', 'TestResults')
$script:GuardSkipFiles = '(?i)(\.tmp|\.bak|\.orig|\.pyc)$|(^|/)(testresults\.xml|Thumbs\.db|\.DS_Store)$'
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

# SHA-256 of a file, read as a stream: the hook runs at every task end, and the images are megabytes.
function Get-FileSha256([string]$Path) {
    for ($i = 0; ; $i++) {
        try {
            $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite, 1048576)
            try {
                $sha = New-Object Security.Cryptography.SHA256CryptoServiceProvider
                try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
            } finally { $stream.Dispose() }
        } catch [IO.IOException] { if ($i -ge 4) { throw }; Start-Sleep -Milliseconds 120 }
    }
}

# Every watched file with its SHA-256, plus one fingerprint for all of them and one for the files a Writer may not change.
function Get-Snapshot {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($folder in $script:SourceFolders) {
        $dir = Join-Path $script:Root $folder
        if (Test-Path -LiteralPath $dir -PathType Container) {
            foreach ($f in [IO.Directory]::GetFiles($dir, '*', [IO.SearchOption]::AllDirectories)) { $paths.Add($f.Substring($script:Root.Length + 1).Replace('\', '/')) }
        }
    }
    foreach ($doc in ($script:Documents + $script:ControlFiles)) { if (Test-Path -LiteralPath (Join-Path $script:Root $doc) -PathType Leaf) { $paths.Add($doc) } }
    $sorted = $paths.ToArray(); [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $files = [ordered]@{}
    $all = New-Object System.Text.StringBuilder
    $source = New-Object System.Text.StringBuilder
    foreach ($rel in $sorted) {
        $hash = Get-FileSha256 (Join-Path $script:Root $rel)
        $files[$rel] = $hash
        [void]$all.Append("$rel|$hash`n")
        if ($script:WriterAllowlist -cnotcontains $rel) { [void]$source.Append("$rel|$hash`n") }
    }
    return [pscustomobject]@{
        files             = $files
        fingerprint       = Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($all.ToString()))
        sourceFingerprint = Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($source.ToString()))
    }
}

# Every file of the repository with its SHA-256 (not only the watched ones): what a Writer run is compared against.
function Get-GuardSnapshot {
    $stateDir = [IO.Path]::GetFullPath((Get-StateDir)).TrimEnd('\')
    $paths = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($script:Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($d in [IO.Directory]::GetDirectories($dir)) {
            if ($script:GuardSkipFolders -contains [IO.Path]::GetFileName($d)) { continue }
            if ($d.TrimEnd('\') -ieq $stateDir) { continue }
            $stack.Push($d)
        }
        foreach ($f in [IO.Directory]::GetFiles($dir)) {
            $rel = $f.Substring($script:Root.Length + 1).Replace('\', '/')
            if ($rel -notmatch $script:GuardSkipFiles) { $paths.Add($rel) }
        }
    }
    $sorted = $paths.ToArray(); [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $files = [ordered]@{}
    foreach ($rel in $sorted) { $files[$rel] = Get-FileSha256 (Join-Path $script:Root $rel) }
    return $files
}

# The text of a policy or legal document without byte order mark and with LF line ends, so every clone agrees.
function Get-PolicyHash([string]$Rel) {
    $path = Join-Path $script:Root $Rel
    if (-not [IO.File]::Exists($path)) { return '' }
    $text = [Text.Encoding]::UTF8.GetString((Read-FileBytes $path))
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    return (Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($text)))
}

# One line per policy or legal document whose current text is not the text its owner approved.
function Get-PolicyProblems {
    $json = Read-JsonFile (Join-Path $script:Root $script:ApprovalsFile)
    if (-not $json -or -not $json.documents) { return , @("the owner approvals are missing or unreadable: $($script:ApprovalsFile)") }
    $problems = @()
    foreach ($d in $script:ProtectedDocuments) {
        $hash = Get-PolicyHash $d
        $entry = $json.documents.PSObject.Properties[$d]
        if (-not $hash) { $problems += "$d is missing" }
        elseif (-not $entry -or -not $entry.Value.sha256) { $problems += "$d has no recorded owner approval" }
        elseif ([string]$entry.Value.sha256 -ne $hash) { $problems += "$d differs from the text its owner approved ($($entry.Value.approvedUtc)): restore it, or have the owner approve the exact new text (-ApprovePolicy -File $d)" }
    }
    return , @($problems)
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

# A review record is valid only when the hook wrote it for a Writer run that finished with the verdict 'complete'.
function Get-Reviews {
    $list = @()
    foreach ($f in [IO.Directory]::GetFiles((Get-StatePath 'reviews'), '*.json')) {
        $r = Read-JsonFile $f
        if ($r -and $r.kind -eq 'writer-review' -and $r.verdict -eq 'complete' -and $r.confirmedBy -eq 'SubagentStop hook' -and $r.fingerprint -and $r.runId -and $r.sessionId) { $list += $r }
    }
    return @($list | Sort-Object { [long]$_.confirmedTicks } -Descending)
}

# With a session id: only a review that session produced. Without: any session (the release gate, which looks at the files).
function Find-Review([string]$Fingerprint, [string]$SessionId) {
    $found = @(Get-Reviews) | Where-Object { $_.fingerprint -eq $Fingerprint }
    if ($SessionId) { $found = $found | Where-Object { [string]$_.sessionId -ceq $SessionId } }
    return ($found | Select-Object -First 1)
}

function Test-NoImpact([string]$SessionId, [string]$Fingerprint) { return [IO.File]::Exists((Get-StatePath 'noimpact' "$SessionId.$Fingerprint.json")) }

# Writer runs, newest first. One file per run: <session>.<agent>.<run id>.json
function Get-Runs([string]$Pattern = '*.json') {
    $list = @()
    foreach ($f in [IO.Directory]::GetFiles((Get-StatePath 'runs'), $Pattern)) {
        $r = Read-JsonFile $f
        if ($r -and $r.runId) { $r | Add-Member -NotePropertyName path -NotePropertyValue $f -Force; $list += $r }
    }
    return @($list | Sort-Object { [long]$_.startedTicks } -Descending)
}

function Save-Run($RunRecord, [hashtable]$Changes) {
    foreach ($k in $Changes.Keys) { $RunRecord | Add-Member -NotePropertyName $k -NotePropertyValue $Changes[$k] -Force }
    $path = [string]$RunRecord.path
    Write-JsonFile $path ($RunRecord | Select-Object -Property * -ExcludeProperty path)
}

function Format-FileList([string[]]$Files, [int]$Max = 8) {
    if (-not $Files -or $Files.Count -eq 0) { return 'none' }
    $shown = @($Files | Select-Object -First $Max) -join ', '
    if ($Files.Count -gt $Max) { $shown += " and $($Files.Count - $Max) more" }
    return $shown
}

function Remove-OldState {
    $limit = [DateTime]::UtcNow.AddDays(-30)
    foreach ($folder in 'sessions', 'runs', 'log', 'attest', 'attest\used', 'subprompt', 'noimpact') {
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
    $pending = if ($previous -and $previous.pendingFingerprint -and -not (Find-Review ([string]$previous.pendingFingerprint) $Sid)) { [string]$previous.pendingFingerprint } else { '' }
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
    # Only a review this session produced ends this session's request.
    $reviewed = [bool](Find-Review $snap.fingerprint $Sid)
    $save = { param($Changes) foreach ($k in $Changes.Keys) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $Changes[$k] -Force }; Write-JsonFile $path $s }

    if ($snap.fingerprint -eq $s.baselineFingerprint) {
        # Nothing changed in this turn. Remind once if an earlier turn of this session left a review open.
        if (-not $reviewed -and $s.pendingFingerprint -eq $snap.fingerprint -and $s.warnedFingerprint -ne $snap.fingerprint -and -not (Test-NoImpact $Sid $snap.fingerprint)) {
            & $save @{ warnedFingerprint = $snap.fingerprint; pendingFingerprint = '' }
            Write-Log $Sid 'Stop decision=allow warning=review-still-open'
            Write-HookOutput @{ systemMessage = "Documentation review still open: files changed earlier in this session have not been reviewed by the $($script:WriterName)." }
            return
        }
        Write-Log $Sid 'Stop decision=allow reason=no-change-this-turn'
        Write-HookOutput @{}; return
    }
    if ($reviewed) { Write-Log $Sid 'Stop decision=allow reason=reviewed-by-this-session'; Write-HookOutput @{}; return }
    if (Test-NoImpact $Sid $snap.fingerprint) { Write-Log $Sid 'Stop decision=allow reason=no-impact-recorded'; Write-HookOutput @{}; return }

    $changed = Get-ChangedFiles $s.baselineFiles $snap.files
    $blocks = [int]$s.blocksThisTurn
    # A review this session recorded since the last request answered that request: what changed after it is a new one.
    $lastBlock = if ($s.PSObject.Properties['lastBlockTicks'] -and $s.lastBlockTicks) { [long]$s.lastBlockTicks } else { 0L }
    $newRequest = $blocks -gt 0 -and $lastBlock -gt 0 -and [bool](@(Get-Reviews) | Where-Object { [string]$_.sessionId -ceq $Sid -and [long]$_.confirmedTicks -gt $lastBlock } | Select-Object -First 1)
    if ($newRequest) { $blocks = 0 }
    $active = ((Get-Field $Data @('stop_hook_active', 'stopHookActive')) -eq 'True')
    if ($active -and $blocks -eq 0 -and -not $newRequest) { $blocks = 1 }
    # Said with the request, so the agent knows why an existing review or a finished Writer run did not count.
    $notes = ''
    if (Find-Review $snap.fingerprint '') { $notes += ' Another session has reviewed these files; that review belongs to that session and does not end this task.' }
    $lastRun = @(Get-Runs "$Sid.*.json") | Select-Object -First 1
    if ($lastRun -and $lastRun.state -eq 'rejected') { $notes += " The last $($script:WriterName) run of this session was not recorded: $($lastRun.reason)$(if (@($lastRun.rejectedFiles).Count) { ' (' + (Format-FileList @($lastRun.rejectedFiles)) + ')' })." }
    $policyProblems = Get-PolicyProblems
    $unapproved = @($policyProblems | Where-Object { $_ -match ' differs from the text ' } | ForEach-Object { ($_ -split ' ')[0] })
    if ($unapproved.Count) { $notes += " Policy or legal text changed without a recorded owner approval: $($unapproved -join ', '). The Writer cannot settle that; the release gate fails until the owner approves the exact text or it is restored." }
    if ($blocks -eq 0) {
        & $save @{ blocksThisTurn = 1; pendingFingerprint = $snap.fingerprint; lastBlockTicks = [DateTime]::UtcNow.Ticks }
        Write-Log $Sid "Stop decision=block request=1 changed=$($changed.Count)"
        Write-Block 'Stop' ("Documentation review needed before this task ends. Changed in this task: $(Format-FileList $changed). " +
            "Run the '$($script:WriterName)' agent as a subagent now: tell it what changed and what a user would notice, and let it update the documents. Do not write the review yourself. " +
            "If nothing a user or contributor can observe changed (refactoring, comments), record that instead: $($script:SelfCommand) -NoImpact -Session $Sid -Reason `"<one sentence>`"." + $notes)
        return
    }
    if ($blocks -eq 1) {
        & $save @{ blocksThisTurn = 2; pendingFingerprint = $snap.fingerprint; lastBlockTicks = [DateTime]::UtcNow.Ticks }
        Write-Log $Sid "Stop decision=block request=2 changed=$($changed.Count)"
        Write-Block 'Stop' ("The documentation review is still not recorded for the current files (no '$($script:WriterName)' run of this session finished with a completed verdict, or files changed after it). " +
            "Try once more: run the '$($script:WriterName)' agent as a subagent. If that is not possible in this session, tell the user plainly that the documentation review is incomplete." + $notes)
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
    # One id per Writer execution. The verdict is recorded under it and accepted only from this run.
    $runId = [guid]::NewGuid().ToString('N')
    $snap = Get-Snapshot
    $now = [DateTime]::UtcNow
    Write-JsonFile (Get-StatePath 'runs' "$Sid.$agentId.$runId.json") ([ordered]@{
            schemaVersion = 2; runId = $runId; sessionId = $Sid; agentId = $agentId; agentType = (Get-Field $Data @('agent_type', 'agentType', 'agent_name', 'agentName'))
            startedTicks = $now.Ticks; startedUtc = $now.ToString('s') + 'Z'; state = 'open'; stopBlocks = 0
            startFingerprint = $snap.fingerprint; sourceFingerprint = $snap.sourceFingerprint; guard = (Get-GuardSnapshot)
        })
    $last = @(Get-Reviews) | Select-Object -First 1
    $scope = if ($last) { "Changed since the last recorded review: $(Format-FileList (Get-ChangedFiles $last.files $snap.files) 12)." } else { 'No earlier review is recorded: check every document against the current source.' }
    $context = "Documentation review run $runId. $scope You may change only these files: $($script:WriterAllowlist -join ', '). " +
        "If anything else in the repository changes during this run, the review is not recorded; report such a change as a proposal instead. " +
        "Record your verdict as your last action, with this run id: $($script:SelfCommand) -Attest -Run $runId -Verdict complete -Summary `"<one sentence>`" (or -Verdict incomplete)."
    Write-Log $Sid "SubagentStart writer agent=$agentId run=$runId"
    Write-HookOutput @{ additionalContext = $context; hookSpecificOutput = @{ hookEventName = 'SubagentStart'; additionalContext = $context } }
}

function Invoke-SubagentStop([string]$Sid, $Data) {
    if (-not (Test-IsWriter $Data)) { Write-HookOutput @{}; return }
    $agentId = Get-SafeId (Get-Field $Data @('agent_id', 'agentId')) 'writer'
    # The run this session started for this agent. A run of another session is never looked at.
    $run = @(Get-Runs "$Sid.$agentId.*.json") | Where-Object { $_.state -eq 'open' -and [string]$_.sessionId -ceq $Sid -and [string]$_.agentId -ceq $agentId } | Select-Object -First 1
    if (-not $run) { Write-Log $Sid "SubagentStop writer agent=$agentId result=NO-REVIEW reason=start-not-seen"; Write-HookOutput @{}; return }
    $runId = [string]$run.runId
    $snap = Get-Snapshot
    $attestFile = Get-StatePath 'attest' "$runId.json"
    $close = {
        param([string]$State, [string]$Why, [string[]]$Files = @())
        Save-Run $run @{ state = $State; reason = $Why; rejectedFiles = @($Files); closedUtc = [DateTime]::UtcNow.ToString('s') + 'Z' }
        if ([IO.File]::Exists($attestFile)) {
            $used = Join-Path (Get-StatePath 'attest\used') "$runId.json"
            try { if ([IO.File]::Exists($used)) { [IO.File]::Delete($used) }; [IO.File]::Move($attestFile, $used) } catch { }
        }
    }

    # 1. What the run changed, in the whole repository, against what a Writer may change.
    $touched = Get-ChangedFiles $run.guard (Get-GuardSnapshot)
    $outside = @($touched | Where-Object { $script:WriterAllowlist -cnotcontains ($_ -replace ' \(removed\)$', '') })
    if ($outside.Count -gt 0) {
        $protected = @($outside | Where-Object { $script:ProtectedDocuments -contains ($_ -replace ' \(removed\)$', '') })
        $why = if ($protected.Count -gt 0) { 'policy or legal document changed during the run' } else { 'files outside the Writer allowlist changed during the run' }
        & $close 'rejected' $why $outside
        Write-Log $Sid "SubagentStop writer agent=$agentId run=$runId result=NO-REVIEW reason=outside-allowlist files=$($outside -join ';')"
        Write-HookOutput @{ systemMessage = "Documentation review not recorded ($why): $(Format-FileList $outside 20). The $($script:WriterName) may change only $($script:WriterAllowlist -join ', '). Nothing was reverted: decide what to do with those changes, then run the review again." }
        return
    }

    # 2. The verdict this run recorded under its own id, for the files as they are now.
    $canBlock = ([int]$run.stopBlocks -eq 0) -and ((Get-Field $Data @('stop_hook_active', 'stopHookActive')) -ne 'True')
    $blockOnce = {
        param([string]$Why, [string]$Text)
        Save-Run $run @{ stopBlocks = 1 }
        Write-Log $Sid "SubagentStop writer agent=$agentId run=$runId decision=block reason=$Why"
        Write-Block 'SubagentStop' $Text
    }
    $attestation = Read-JsonFile $attestFile
    if ($attestation -and ([string]$attestation.runId -cne $runId -or [string]$attestation.sessionId -cne $Sid -or [string]$attestation.agentId -cne $agentId)) { $attestation = $null }
    if (-not $attestation) {
        if ($canBlock) { & $blockOnce 'no-attestation' "Before you finish, record your verdict for this run: $($script:SelfCommand) -Attest -Run $runId -Verdict complete -Summary `"<one sentence>`" (use -Verdict incomplete if you could not finish the review)."; return }
        & $close 'rejected' 'the run recorded no verdict'
        Write-Log $Sid "SubagentStop writer agent=$agentId run=$runId result=NO-REVIEW reason=no-attestation"; Write-HookOutput @{}; return
    }
    if ($attestation.fingerprint -ne $snap.fingerprint) {
        if ($canBlock) { & $blockOnce 'changed-after-attestation' "Files changed after you recorded your verdict ($(Format-FileList (Get-ChangedFiles $attestation.files $snap.files))). Check them, then record the verdict again as your very last action: $($script:SelfCommand) -Attest -Run $runId -Verdict complete -Summary `"<one sentence>`"."; return }
        & $close 'rejected' 'files changed after the verdict'
        Write-Log $Sid "SubagentStop writer agent=$agentId run=$runId result=NO-REVIEW reason=changed-after-attestation"; Write-HookOutput @{}; return
    }
    if ($attestation.verdict -ne 'complete') {
        & $close 'rejected' 'the verdict was incomplete'
        Write-Log $Sid "SubagentStop writer agent=$agentId run=$runId result=NO-REVIEW reason=verdict-incomplete"
        Write-HookOutput @{ systemMessage = 'Documentation review not recorded (verdict-incomplete).' }
        return
    }
    $now = [DateTime]::UtcNow
    Write-JsonFile (Get-StatePath 'reviews' "$($snap.fingerprint).$runId.json") ([ordered]@{
            schemaVersion = 2; kind = 'writer-review'; verdict = 'complete'; summary = [string]$attestation.summary
            runId = $runId; sessionId = $Sid; agentId = $agentId; agentType = [string]$run.agentType
            fingerprint = $snap.fingerprint; sourceFingerprint = $snap.sourceFingerprint; files = $snap.files
            documentsChanged = @($touched); startedUtc = $run.startedUtc; attestedUtc = $attestation.attestedUtc
            confirmedUtc = $now.ToString('s') + 'Z'; confirmedTicks = $now.Ticks; confirmedBy = 'SubagentStop hook'
        })
    & $close 'recorded' ''
    Write-Log $Sid "SubagentStop writer agent=$agentId run=$runId result=REVIEW-RECORDED fingerprint=$($snap.fingerprint.Substring(0, 12)) documentsChanged=$($touched.Count)"
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
    $review = Find-Review $snap.fingerprint ''
    $last = @(Get-Reviews) | Select-Object -First 1
    $hookProblems = Get-HookProblems
    $policyProblems = Get-PolicyProblems
    $short = { param([string]$Text, [int]$Length = 8) $Text.Substring(0, [Math]::Min($Length, $Text.Length)) }
    "Files under review: $(@($snap.files.Keys).Count)   fingerprint: $($snap.fingerprint.Substring(0, 12))"
    if ($review) {
        "Reviewed: yes - $($script:WriterName) run $(& $short ([string]$review.runId)) confirmed $($review.confirmedUtc) (session $(& $short ([string]$review.sessionId)))"
        "Summary: $($review.summary)"
    } elseif ($last) {
        "Reviewed: NO - the latest review ($($last.confirmedUtc)) is stale. Changed since: $(Format-FileList (Get-ChangedFiles $last.files $snap.files) 20)"
    } else {
        'Reviewed: NO - no review has been recorded for this repository.'
    }
    $lastRun = @(Get-Runs) | Select-Object -First 1
    if ($lastRun -and $lastRun.state -eq 'rejected') { "Latest Writer run $(& $short ([string]$lastRun.runId)) (session $(& $short ([string]$lastRun.sessionId))): NOT recorded - $($lastRun.reason)$(if (@($lastRun.rejectedFiles).Count) { ': ' + (Format-FileList @($lastRun.rejectedFiles) 20) })" }
    if ($policyProblems.Count -eq 0) { "Policy and legal documents: $($script:ProtectedDocuments.Count) hold the text their owner approved" }
    foreach ($p in $policyProblems) { "Policy problem: $p" }
    foreach ($p in $hookProblems) { "Hook problem: $p" }
    if ($AsGate) {
        if ($review -and $hookProblems.Count -eq 0 -and $policyProblems.Count -eq 0) { 'DOC GATE: PASS'; return 0 }
        if ($policyProblems.Count -gt 0) { 'DOC GATE: FAIL - a policy or legal document does not hold the text its owner approved (see the "Policy problem" lines). A review cannot settle that.'; return 1 }
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
        if ($Run -notmatch '^[0-9a-f]{32}$') { [Console]::Error.WriteLine('-Attest needs -Run <id>: the run id in the note you received when your review run started. A verdict without it is not recorded.'); exit 2 }
        $mine = @(Get-Runs "*.$Run.json") | Where-Object { [string]$_.runId -ceq $Run } | Select-Object -First 1
        if (-not $mine) { [Console]::Error.WriteLine("No $($script:WriterName) run $Run was started in this repository. Nothing recorded."); exit 2 }
        if ($mine.state -ne 'open') { [Console]::Error.WriteLine("Run $Run is closed ($($mine.state)). A verdict belongs to one run and cannot be used again. Nothing recorded."); exit 2 }
        $snap = Get-Snapshot; $now = [DateTime]::UtcNow
        Write-JsonFile (Get-StatePath 'attest' "$Run.json") ([ordered]@{
                runId = $Run; sessionId = [string]$mine.sessionId; agentId = [string]$mine.agentId
                verdict = $Verdict; summary = [string]$Summary; fingerprint = $snap.fingerprint; sourceFingerprint = $snap.sourceFingerprint; files = $snap.files
                attestedTicks = $now.Ticks; attestedUtc = $now.ToString('s') + 'Z'
            })
        "Verdict '$Verdict' noted for run $($Run.Substring(0, 8)), fingerprint $($snap.fingerprint.Substring(0, 12)). It becomes a review only when the hook of the session that started this run confirms it as the $($script:WriterName) finishes. Change no file now."
        exit 0
    }
    if ($NoImpact) {
        if ([string]::IsNullOrWhiteSpace($Reason)) { [Console]::Error.WriteLine('-NoImpact needs -Reason "<one sentence>".'); exit 2 }
        if ($Session -notmatch '^[A-Za-z0-9_-]{1,80}$' -or -not [IO.File]::Exists((Get-StatePath 'sessions' "$Session.json"))) { [Console]::Error.WriteLine('-NoImpact needs -Session <id>: the session id shown in the request at the end of your task. It quiets that session only.'); exit 2 }
        $snap = Get-Snapshot
        Write-JsonFile (Get-StatePath 'noimpact' "$Session.$($snap.fingerprint).json") ([ordered]@{ sessionId = $Session; fingerprint = $snap.fingerprint; reason = $Reason; recordedUtc = [DateTime]::UtcNow.ToString('s') + 'Z' })
        'Noted: no documentation impact for the current files, for this session. This quiets its end-of-task reminder; the release gate still needs a review.'
        exit 0
    }
    if ($ApprovePolicy) {
        if ($script:ProtectedDocuments -cnotcontains $File) { [Console]::Error.WriteLine("-ApprovePolicy needs -File, one of: $($script:ProtectedDocuments -join ', ')."); exit 2 }
        if ([string]::IsNullOrWhiteSpace($ApprovedBy) -or [string]::IsNullOrWhiteSpace($Reason)) { [Console]::Error.WriteLine('-ApprovePolicy needs -ApprovedBy "<who decided>" and -Reason "<the decision, in one sentence>". It records a decision; it does not make one.'); exit 2 }
        $hash = Get-PolicyHash $File
        if (-not $hash) { [Console]::Error.WriteLine("$File does not exist."); exit 2 }
        $path = Join-Path $script:Root $script:ApprovalsFile
        $existing = Read-JsonFile $path
        $documents = [ordered]@{}
        foreach ($d in $script:ProtectedDocuments) {
            if ($d -ceq $File) { $documents[$d] = [ordered]@{ sha256 = $hash; approvedBy = $ApprovedBy; reason = $Reason; approvedUtc = [DateTime]::UtcNow.ToString('s') + 'Z' } }
            elseif ($existing -and $existing.documents -and $existing.documents.PSObject.Properties[$d]) { $documents[$d] = $existing.documents.$d }
        }
        $record = [ordered]@{
            schemaVersion = 1
            note          = 'Owner approvals for the policy and legal documents. Each entry approves one exact text (SHA-256 of the UTF-8 text with LF line ends). Any other text fails the documentation gate. Written by Doc-Review.ps1 -ApprovePolicy; see CONTRIBUTING.md.'
            documents     = $documents
        }
        if (-not (Test-Path -LiteralPath (Split-Path $path -Parent))) { [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent)) }
        Write-Atomic $path (($record | ConvertTo-Json -Depth 5) + "`r`n")
        "Recorded: $File, text $($hash.Substring(0, 12)), approved by '$ApprovedBy'. The approval covers this exact text only; any later edit needs its own."
        exit 0
    }
    if ($Gate) { $lines = @(Show-State -AsGate); $lines[0..($lines.Count - 2)]; exit [int]$lines[-1] }
    $lines = @(Show-State); $lines[0..($lines.Count - 2)]; exit 0
} catch {
    # A failed hook is a failed hook: it writes no review and says so.
    [Console]::Error.WriteLine("Doc-Review.ps1 failed: $($_.Exception.Message)")
    exit 1
}
