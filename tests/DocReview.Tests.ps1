# DocReview.Tests.ps1
# -------------------------------------------------------------------
# The maintainer documentation workflow in .github/: the product-communication skill, the
# Communication Writer agent, the completion hook and the release gate (Doc-Review.ps1).
# The script is run as a real child process against a throwaway repository under TEMP, with
# hook events on stdin as the editor sends them. These tests prove what the SCRIPT does:
#   - an unrelated change asks for nothing; a relevant one asks for a review, at most twice;
#   - a review exists only after a Writer attested AND its SubagentStop event was seen;
#   - the verdict is bound to one run id, one session and one agent: sessions cannot exchange or
#     overwrite review state, also when their hooks run at the same moment;
#   - policy and legal documents must hold the text their owner approved;
#   - a Writer run that changed anything outside its five documents is rejected;
#   - any later change of a watched file, the images or the review controls makes that review stale;
#   - a failed hook, a missing hook or a hand-run script never counts as a review.
# They do not prove that an editor session fires the events or that an agent delegates.

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:Script = Join-Path $script:Repo '.github\hooks\Doc-Review.ps1'
    $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('fabric docreview ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:Writer = 'Communication Writer'
    $script:Protected = @('SECURITY.md', 'CODE_OF_CONDUCT.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md')
    $script:Allowed = @('README.md', 'CHANGELOG.md', 'CLI-FUNCTIONALITIES.md', 'CONTRIBUTING.md', 'tests/README.md')

    function Set-RFile([string]$Rel, [string]$Text) {
        $p = Join-Path $script:Root $Rel
        New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($p, $Text, $script:Utf8)
    }
    # The hash the script records for a policy or legal document: UTF-8 text, no byte order mark, LF line ends.
    function Get-RPolicyHash([string]$Path) {
        $text = [IO.File]::ReadAllText($Path)
        $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
    }
    # A fresh repository with one source file, the documents, the owner approvals and the real hook files.
    function New-RRepo {
        $script:Root = Join-Path $script:Base ('repo ' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:State = Join-Path $script:Root '.state'
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host one'
        Set-RFile 'schema\a.json' '{}'
        Set-RFile 'assets\cover.png' 'image one'
        Set-RFile 'tests\Some.Tests.ps1' '# test'
        foreach ($d in 'README.md', 'CHANGELOG.md', 'CLI-FUNCTIONALITIES.md', 'CONTRIBUTING.md', 'tests\README.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md') { Set-RFile $d "text of $d" }
        foreach ($f in '.github\hooks\documentation-review.json', '.github\hooks\Doc-Review.ps1', '.github\agents\communication-writer.agent.md', '.github\skills\product-communication\SKILL.md') {
            Set-RFile $f ([IO.File]::ReadAllText((Join-Path $script:Repo $f)))
        }
        $documents = [ordered]@{}
        foreach ($d in $script:Protected) { $documents[$d] = [ordered]@{ sha256 = (Get-RPolicyHash (Join-Path $script:Root $d)); approvedBy = 'test owner'; reason = 'baseline'; approvedUtc = '2026-01-01T00:00:00Z' } }
        Set-RFile '.github\hooks\policy-approvals.json' ([ordered]@{ schemaVersion = 1; documents = $documents } | ConvertTo-Json -Depth 5)
    }
    function Start-DocReviewProcess([string]$Arguments, [string]$StdIn = $null) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:Script + '" ' + $Arguments
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['DOC_REVIEW_ROOT'] = $script:Root
        $psi.EnvironmentVariables['DOC_REVIEW_STATE'] = $script:State
        $p = [Diagnostics.Process]::Start($psi)
        if ($StdIn) { $p.StandardInput.Write($StdIn) }
        $p.StandardInput.Close()
        return [pscustomobject]@{ Process = $p; Err = $p.StandardError.ReadToEndAsync(); OutTask = $p.StandardOutput.ReadToEndAsync() }
    }
    function Wait-DocReviewProcess($Started) {
        $Started.Process.WaitForExit()
        $out = $Started.OutTask.Result
        $json = $null; try { if ($out.Trim()) { $json = $out | ConvertFrom-Json } } catch { }
        return [pscustomobject]@{ Exit = $Started.Process.ExitCode; Out = $out; Err = $Started.Err.Result; Json = $json }
    }
    function Invoke-DocReview([string]$Arguments, [string]$StdIn = $null) { return (Wait-DocReviewProcess (Start-DocReviewProcess $Arguments $StdIn)) }
    function Get-HookPayload([string]$Name, [hashtable]$Fields = @{}, [string]$Session = 'session-a') {
        $payload = @{ hook_event_name = $Name; session_id = $Session; timestamp = '2026-01-01T00:00:00Z' }
        foreach ($k in $Fields.Keys) { $payload[$k] = $Fields[$k] }
        return ($payload | ConvertTo-Json -Compress)
    }
    function Send-Hook([string]$Name, [hashtable]$Fields = @{}, [string]$Session = 'session-a') { return (Invoke-DocReview "-HookEvent $Name" (Get-HookPayload $Name $Fields $Session)) }
    function Get-RReviews { return @(Get-ChildItem -LiteralPath (Join-Path $script:State 'reviews') -Filter *.json -ErrorAction SilentlyContinue) }
    function Read-RReviews { return @(Get-RReviews | ForEach-Object { [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json }) }
    # The run id is given to the Writer in the note the SubagentStart hook returns, and nowhere else.
    function Get-RunId($StartResult) {
        $m = [regex]::Match([string]$StartResult.Json.hookSpecificOutput.additionalContext, '-Attest -Run ([0-9a-f]{32}) ')
        $m.Success | Should -BeTrue -Because 'the Writer needs its run id to record a verdict'
        return $m.Groups[1].Value
    }
    function Start-Writer([string]$Session = 'session-a', [string]$AgentId = 'agent-1') {
        $start = Send-Hook 'SubagentStart' @{ agent_id = $AgentId; agent_type = $script:Writer } $Session
        Send-Hook 'UserPromptSubmit' @{ prompt = 'review the documents' } $Session | Out-Null
        return (Get-RunId $start)
    }
    function Stop-Writer([string]$Session = 'session-a', [string]$AgentId = 'agent-1', [bool]$Active = $false) {
        return (Send-Hook 'SubagentStop' @{ agent_id = $AgentId; agent_type = $script:Writer; stop_hook_active = $Active } $Session)
    }
    function Send-Verdict([string]$RunId, [string]$Verdict = 'complete', [string]$Summary = 'checked the documents') { return (Invoke-DocReview "-Attest -Run $RunId -Verdict $Verdict -Summary `"$Summary`"") }
    # A complete Writer run as the editor reports it: start, the subagent's own prompt event, optional work, verdict, stop.
    function Invoke-WriterRun([scriptblock]$Work = { }, [string]$Verdict = 'complete', [string]$Session = 'session-a', [string]$AgentId = 'agent-1') {
        $runId = Start-Writer $Session $AgentId
        & $Work
        Send-Verdict $runId $Verdict | Out-Null
        return (Stop-Writer $Session $AgentId)
    }
}

AfterAll { if (Test-Path -LiteralPath $script:Base) { Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue } }

Describe 'Maintainer documentation files: valid, short, and not part of the product' {

    It 'the skill has valid frontmatter and stays short' {
        $text = [IO.File]::ReadAllText((Join-Path $script:Repo '.github\skills\product-communication\SKILL.md'))
        $m = [regex]::Match($text, '(?s)^---\r?\n(.*?)\r?\n---\r?\n(.*)$')
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Match '(?m)^name: product-communication\s*$'
        $description = [regex]::Match($m.Groups[1].Value, "(?m)^description: '(.*)'\s*$").Groups[1].Value
        $description.Length | Should -BeGreaterThan 80
        $description.Length | Should -BeLessOrEqual 1024
        $words = @($m.Groups[2].Value -split '\s+' | Where-Object { $_ -match '[A-Za-z]' }).Count
        $words | Should -BeGreaterOrEqual 400
        $words | Should -BeLessOrEqual 700
        @($text -split "`n").Count | Should -BeLessThan 120
        @(Get-ChildItem -LiteralPath (Join-Path $script:Repo '.github\skills\product-communication') -Recurse -File).Count | Should -Be 1 -Because 'the skill needs no supporting files'
    }

    It 'the Writer is a subagent that can edit documents and cannot dispatch agents' {
        $text = [IO.File]::ReadAllText((Join-Path $script:Repo '.github\agents\communication-writer.agent.md'))
        $front = [regex]::Match($text, '(?s)^---\r?\n(.*?)\r?\n---').Groups[1].Value
        $front | Should -Match '(?m)^name: Communication Writer\s*$'
        $front | Should -Match '(?m)^user-invocable: false\s*$' -Because 'selected as the main agent it could not be told apart from the agent it reviews'
        $front | Should -Match "(?m)^tools: \['read', 'search', 'edit', 'execute'\]\s*$"
        $front | Should -Match '(?m)^agents: \[\]\s*$'
        $text | Should -Match 'product-communication/SKILL\.md'
        $text | Should -Match '-Attest -Run <run id> -Verdict complete'
        $text | Should -Not -Match '-Attest -Verdict' -Because 'a verdict without a run id is refused'
        $text | Should -Match '\*\*You may change five files and nothing else\*\*: `README\.md`, `CHANGELOG\.md`, `CLI-FUNCTIONALITIES\.md`, `CONTRIBUTING\.md`, `tests/README\.md`'
        $text | Should -Match '`SECURITY\.md`, `CODE_OF_CONDUCT\.md`, `LICENSE` and `THIRD_PARTY_NOTICES\.md`: never edit, not even a typo or a link'
        $text | Should -Not -Match 'You may fix an obvious typo' -Because 'policy text is changed by its owner only'
    }

    It 'the hook configuration names the four events and one script' {
        $json = [IO.File]::ReadAllText((Join-Path $script:Repo '.github\hooks\documentation-review.json')) | ConvertFrom-Json
        @($json.hooks.PSObject.Properties.Name | Sort-Object) | Should -Be @('Stop', 'SubagentStart', 'SubagentStop', 'UserPromptSubmit')
        foreach ($e in $json.hooks.PSObject.Properties) {
            @($e.Value).Count | Should -Be 1
            $e.Value[0].powershell | Should -Be "powershell -NoProfile -ExecutionPolicy Bypass -File .github/hooks/Doc-Review.ps1 -HookEvent $($e.Name)"
            $e.Value[0].bash | Should -Be 'true' -Because 'the hook does nothing on a system without Windows PowerShell'
        }
        $json.hooks.PSObject.Properties.Name | Should -Not -Contain 'PostToolUse' -Because 'a process per tool call would slow every session'
    }

    It 'the script parses and holds ASCII only (Windows PowerShell 5.1 reads it without a byte order mark)' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        @([IO.File]::ReadAllBytes($script:Script) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'the installer ships none of it: no Writer among the product agents, no skill, no hook' {
        $installer = [IO.File]::ReadAllText((Join-Path $script:Repo 'fabric-agentic-installer\Setup-FabricAgenticWorkspace.ps1'))
        $installer | Should -Not -Match 'Communication Writer|communication-writer|product-communication|Doc-Review'
        [IO.File]::ReadAllText((Join-Path $script:Repo 'tests\fixtures\agent-baseline.json')) | Should -Not -Match 'Communication Writer'
    }
}

Describe 'End of a task: when the hook asks for a review' {

    BeforeEach { New-RRepo; Send-Hook 'UserPromptSubmit' | Out-Null }

    It 'asks for nothing when the task changed no watched file (a question, a test, tooling)' {
        Set-RFile 'tests\Some.Tests.ps1' '# changed test'
        Set-RFile '.github\workflows\x.yml' 'name: x'
        $r = Send-Hook 'Stop' @{ stop_hook_active = $false }
        $r.Exit | Should -Be 0
        $r.Out.Trim() | Should -Be '{}'
    }

    It 'asks once for a Writer review when a source file changed, in the form both runtimes read' {
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        $r = Send-Hook 'Stop' @{ stop_hook_active = $false }
        $r.Exit | Should -Be 0
        $r.Json.decision | Should -Be 'block'
        $r.Json.hookSpecificOutput.decision | Should -Be 'block'
        $r.Json.hookSpecificOutput.hookEventName | Should -Be 'Stop'
        $r.Json.reason | Should -Be $r.Json.hookSpecificOutput.reason
        $r.Json.reason | Should -Match "'Communication Writer' agent as a subagent"
        $r.Json.reason | Should -Match 'fabric-agentic-installer/Setup\.ps1'
        $r.Json.reason | Should -Match '-NoImpact -Session session-a -Reason'
    }

    It 'a changed document is a relevant change too' {
        Set-RFile 'README.md' 'edited by hand'
        (Send-Hook 'Stop' @{ stop_hook_active = $false }).Json.decision | Should -Be 'block'
    }

    It 'makes one recovery attempt, then lets the task end and says the review is incomplete' {
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        (Send-Hook 'Stop' @{ stop_hook_active = $false }).Json.decision | Should -Be 'block'
        $second = Send-Hook 'Stop' @{ stop_hook_active = $true }
        $second.Json.decision | Should -Be 'block'
        $second.Json.reason | Should -Match 'Try once more'
        $third = Send-Hook 'Stop' @{ stop_hook_active = $true }
        $third.Json.PSObject.Properties.Name | Should -Not -Contain 'decision'
        $third.Json.systemMessage | Should -Match 'Documentation review INCOMPLETE'
        $fourth = Send-Hook 'Stop' @{ stop_hook_active = $true }
        $fourth.Json.PSObject.Properties.Name | Should -Not -Contain 'decision' -Because 'the hook never forces more than two continuations in one task'
        @(Get-RReviews).Count | Should -Be 0
    }

    It 'counts a continuation it did not record itself (state lost) as the first request' {
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        (Send-Hook 'Stop' @{ stop_hook_active = $true }).Json.reason | Should -Match 'Try once more'
        (Send-Hook 'Stop' @{ stop_hook_active = $true }).Json.systemMessage | Should -Match 'INCOMPLETE'
    }

    It 'a review left incomplete is mentioned once at the end of the next task, and not again' {
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        foreach ($i in 1..3) { Send-Hook 'Stop' @{ stop_hook_active = ($i -gt 1) } | Out-Null }
        Send-Hook 'UserPromptSubmit' | Out-Null
        $next = Send-Hook 'Stop' @{ stop_hook_active = $false }
        $next.Json.PSObject.Properties.Name | Should -Not -Contain 'decision' -Because 'nothing changed in this task'
        $next.Json.systemMessage | Should -Match 'Documentation review still open'
        Send-Hook 'UserPromptSubmit' | Out-Null
        (Send-Hook 'Stop' @{ stop_hook_active = $false }).Out.Trim() | Should -Be '{}'
    }

    It 'a recorded "no documentation impact" quiets the reminder of that session only, and is not a review' {
        Send-Hook 'UserPromptSubmit' @{} 'session-b' | Out-Null
        Set-RFile 'fabric-agentic-installer\Setup.ps1' '# comment only'
        (Invoke-DocReview '-NoImpact -Session session-a').Exit | Should -Be 2 -Because 'a reason is required'
        (Invoke-DocReview '-NoImpact -Reason "comment only"').Exit | Should -Be 2 -Because 'it is recorded for one session'
        (Invoke-DocReview '-NoImpact -Session no-such-session -Reason "comment only"').Exit | Should -Be 2
        (Invoke-DocReview '-NoImpact -Session session-a -Reason "comment only"').Exit | Should -Be 0
        (Send-Hook 'Stop' @{ stop_hook_active = $false }).Out.Trim() | Should -Be '{}'
        (Send-Hook 'Stop' @{ stop_hook_active = $false } 'session-b').Json.decision | Should -Be 'block' -Because 'session-b recorded nothing'
        $gate = Invoke-DocReview '-Gate'
        $gate.Exit | Should -Be 1
        $gate.Out | Should -Match 'DOC GATE: FAIL'
    }

    It 'ignores a Stop that comes from inside a subagent' {
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        (Send-Hook 'Stop' @{ stop_hook_active = $false; agent_id = 'sub-1'; agent_type = 'default' }).Out.Trim() | Should -Be '{}'
    }

    It 'a session the hook first sees at its end has no baseline and is left alone' {
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        (Send-Hook 'Stop' @{ stop_hook_active = $false } 'session-late').Out.Trim() | Should -Be '{}'
    }

    It 'never reads or stores the prompt text' {
        Send-Hook 'UserPromptSubmit' @{ prompt = 'SECRET-PROMPT-TEXT' } 'session-p' | Out-Null
        $stored = (Get-ChildItem -LiteralPath $script:State -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $stored | Should -Not -Match 'SECRET-PROMPT-TEXT'
    }

    # The editor fires UserPromptSubmit for a subagent's prompt too, right after its SubagentStart.
    It 'the prompt event of a subagent does not start a new task: a delegation that fails is still noticed' {
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        (Send-Hook 'Stop' @{ stop_hook_active = $false }).Json.decision | Should -Be 'block'
        Send-Hook 'SubagentStart' @{ agent_id = 'sub-1'; agent_type = 'default' } | Out-Null
        (Send-Hook 'UserPromptSubmit' @{ prompt = 'subagent task' }).Out.Trim() | Should -Be '{}'
        Send-Hook 'SubagentStop' @{ agent_id = 'sub-1'; agent_type = 'default'; stop_hook_active = $false } | Out-Null
        $second = Send-Hook 'Stop' @{ stop_hook_active = $true }
        $second.Json.decision | Should -Be 'block' -Because 'no Writer review was recorded'
        $second.Json.reason | Should -Match 'Try once more'
    }

    It 'two subagents started together use two prompt events; the next prompt is the user''s and starts a new task' {
        Send-Hook 'SubagentStart' @{ agent_id = 'sub-1'; agent_type = 'default' } | Out-Null
        Send-Hook 'SubagentStart' @{ agent_id = 'sub-2'; agent_type = 'default' } | Out-Null
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        Send-Hook 'UserPromptSubmit' | Out-Null
        Send-Hook 'UserPromptSubmit' | Out-Null
        (Send-Hook 'Stop' @{ stop_hook_active = $false }).Json.decision | Should -Be 'block' -Because 'both prompt events belonged to subagents'
        Send-Hook 'UserPromptSubmit' | Out-Null
        $next = Send-Hook 'Stop' @{ stop_hook_active = $false }
        $next.Json.PSObject.Properties.Name | Should -Not -Contain 'decision' -Because 'the third prompt opened a new task, and nothing changed in it'
        $next.Json.systemMessage | Should -Match 'still open' -Because 'the review asked for in the task before was never done'
    }

    It 'a subagent start that is more than two minutes old does not swallow the user''s next prompt' {
        Send-Hook 'SubagentStart' @{ agent_id = 'sub-1'; agent_type = 'default' } | Out-Null
        $marker = @(Get-ChildItem -LiteralPath (Join-Path $script:State 'subprompt') -File)
        $marker.Count | Should -Be 1
        $marker[0].LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-5)
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        Send-Hook 'UserPromptSubmit' | Out-Null
        (Send-Hook 'Stop' @{ stop_hook_active = $false }).Out.Trim() | Should -Be '{}' -Because 'that prompt opened a new task after the change'
        @(Get-ChildItem -LiteralPath (Join-Path $script:State 'subprompt') -File).Count | Should -Be 0
    }

    It 'a subagent start in one session does not affect the prompt of another session' {
        Send-Hook 'SubagentStart' @{ agent_id = 'sub-1'; agent_type = 'default' } 'session-b' | Out-Null
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        Send-Hook 'UserPromptSubmit' | Out-Null
        (Send-Hook 'Stop' @{ stop_hook_active = $false }).Out.Trim() | Should -Be '{}'
    }
}

Describe 'A review is a Writer run the hook saw finish, for exactly these files' {

    BeforeEach { New-RRepo; Send-Hook 'UserPromptSubmit' | Out-Null; Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two' }

    It 'request, Writer run, record: the task then ends quietly and the gate passes' {
        (Send-Hook 'Stop' @{ stop_hook_active = $false }).Json.decision | Should -Be 'block'
        $start = Send-Hook 'SubagentStart' @{ agent_id = 'agent-1'; agent_type = $script:Writer }
        $start.Json.hookSpecificOutput.additionalContext | Should -Match '-Attest -Run [0-9a-f]{32} -Verdict complete'
        $start.Json.hookSpecificOutput.additionalContext | Should -Match 'You may change only these files: README\.md, CHANGELOG\.md, CLI-FUNCTIONALITIES\.md, CONTRIBUTING\.md, tests/README\.md'
        $start.Json.additionalContext | Should -Be $start.Json.hookSpecificOutput.additionalContext
        $runId = Get-RunId $start
        Set-RFile 'CHANGELOG.md' 'text of CHANGELOG.md plus one bullet'
        (Send-Verdict $runId 'complete' 'added one bullet').Exit | Should -Be 0
        @(Get-RReviews).Count | Should -Be 0 -Because 'the attestation alone is not a review'
        (Send-Hook 'SubagentStop' @{ agent_id = 'agent-1'; agent_type = $script:Writer; stop_hook_active = $false }).Out.Trim() | Should -Be '{}'
        $review = [IO.File]::ReadAllText((Get-RReviews)[0].FullName) | ConvertFrom-Json
        $review.confirmedBy | Should -Be 'SubagentStop hook'
        $review.sessionId | Should -Be 'session-a'
        $review.agentId | Should -Be 'agent-1'
        $review.agentType | Should -Be $script:Writer
        $review.runId | Should -Be $runId
        $review.summary | Should -Be 'added one bullet'
        @($review.documentsChanged) | Should -Be @('CHANGELOG.md')
        (Send-Hook 'Stop' @{ stop_hook_active = $true }).Out.Trim() | Should -Be '{}'
        $gate = Invoke-DocReview '-Gate'
        $gate.Exit | Should -Be 0
        $gate.Out | Should -Match 'DOC GATE: PASS'
        $gate.Out | Should -Match "Reviewed: yes - Communication Writer run $($runId.Substring(0, 8)) confirmed .* \(session session-\)"
    }

    It 'running the script by hand never creates a review: a verdict needs the id of a run the hook started' {
        $r = Invoke-DocReview '-Attest -Verdict complete -Summary "by hand"'
        $r.Exit | Should -Be 2
        $r.Err | Should -Match '-Attest needs -Run <id>'
        $unknown = Invoke-DocReview "-Attest -Run $('ab' * 16) -Verdict complete -Summary `"invented id`""
        $unknown.Exit | Should -Be 2
        $unknown.Err | Should -Match 'No Communication Writer run .* was started'
        (Invoke-DocReview '-Status').Out | Should -Match 'Reviewed: NO'
        (Invoke-DocReview '-Gate').Exit | Should -Be 1
        @(Get-RReviews).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $script:State 'attest') -Filter *.json -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'another agent gets no run id, and its finishing is not a review' {
        $start = Send-Hook 'SubagentStart' @{ agent_id = 'agent-9'; agent_type = 'default' }
        $start.Out.Trim() | Should -Be '{}' -Because 'only the Writer is given a run'
        @(Get-ChildItem -LiteralPath (Join-Path $script:State 'runs') -Filter *.json -ErrorAction SilentlyContinue).Count | Should -Be 0
        (Send-Hook 'SubagentStop' @{ agent_id = 'agent-9'; agent_type = 'default'; stop_hook_active = $false }).Out.Trim() | Should -Be '{}'
        @(Get-RReviews).Count | Should -Be 0
    }

    It 'a Writer that finishes without a verdict is asked once, with its run id, then no review is recorded' {
        $runId = Start-Writer
        $first = Stop-Writer
        $first.Json.hookSpecificOutput.decision | Should -Be 'block'
        $first.Json.reason | Should -Match 'record your verdict'
        $first.Json.reason | Should -Match "-Attest -Run $runId -Verdict complete"
        (Stop-Writer -Active $true).Out.Trim() | Should -Be '{}'
        @(Get-RReviews).Count | Should -Be 0
        (Invoke-DocReview '-Gate').Exit | Should -Be 1
        (Send-Verdict $runId).Exit | Should -Be 2 -Because 'the run is closed'
    }

    It 'a Writer whose start the hook did not see leaves no review' {
        Stop-Writer | Out-Null
        @(Get-RReviews).Count | Should -Be 0
    }

    It 'the verdict "incomplete" is recorded as no review' {
        (Invoke-WriterRun -Verdict 'incomplete').Json.systemMessage | Should -Match 'verdict-incomplete'
        @(Get-RReviews).Count | Should -Be 0
    }

    It 'a document changed after the verdict: the Writer is sent back once, and the second verdict of the same run counts' {
        $runId = Start-Writer
        Send-Verdict $runId 'complete' 'first' | Out-Null
        Set-RFile 'README.md' 'changed after the verdict'
        $stop = Stop-Writer
        $stop.Json.decision | Should -Be 'block'
        $stop.Json.reason | Should -Match 'README\.md'
        $stop.Json.reason | Should -Match "-Attest -Run $runId "
        Send-Verdict $runId 'complete' 'second' | Out-Null
        Stop-Writer -Active $true | Out-Null
        @(Get-RReviews).Count | Should -Be 1
        @(Read-RReviews)[0].summary | Should -Be 'second'
    }

    It 'a Writer run during which product source changed is not a review, and the file is named' {
        $stop = Invoke-WriterRun { Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host three' }
        $stop.Json.systemMessage | Should -Match 'files outside the Writer allowlist changed during the run'
        $stop.Json.systemMessage | Should -Match 'fabric-agentic-installer/Setup\.ps1'
        $stop.Json.systemMessage | Should -Match 'Nothing was reverted'
        @(Get-RReviews).Count | Should -Be 0
    }

    It 'a Writer run that changed <File> is not a review' -TestCases @(@{ File = 'LICENSE' }, @{ File = 'THIRD_PARTY_NOTICES.md' }, @{ File = 'SECURITY.md' }, @{ File = 'CODE_OF_CONDUCT.md' }) {
        param($File)
        $stop = Invoke-WriterRun { Set-RFile $File 'rewritten' }
        $stop.Json.systemMessage | Should -Match 'policy or legal document changed during the run'
        $stop.Json.systemMessage | Should -Match ([regex]::Escape($File))
        @(Get-RReviews).Count | Should -Be 0
        (Invoke-DocReview '-Gate').Exit | Should -Be 1
    }

    It 'a verdict serves one Writer run only: it cannot be recorded again or reused by the next run' {
        $first = Start-Writer
        Send-Verdict $first | Out-Null
        Stop-Writer | Out-Null
        @(Get-RReviews).Count | Should -Be 1
        $again = Send-Verdict $first
        $again.Exit | Should -Be 2
        $again.Err | Should -Match 'is closed \(recorded\)'
        Set-RFile 'README.md' 'a later edit'
        $second = Start-Writer -AgentId 'agent-2'
        $second | Should -Not -Be $first
        (Send-Verdict $first).Exit | Should -Be 2 -Because 'the old id stays closed'
        (Stop-Writer -AgentId 'agent-2' -Active $true).Out.Trim() | Should -Be '{}'
        @(Get-RReviews).Count | Should -Be 1 -Because 'the second run recorded no verdict of its own'
        (Invoke-DocReview '-Gate').Exit | Should -Be 1
    }

    It 'a change after a recorded review is a new request in the same task, with its own single recovery attempt' {
        (Send-Hook 'Stop' @{ stop_hook_active = $false }).Json.reason | Should -Match 'Documentation review needed'
        Invoke-WriterRun | Out-Null
        (Send-Hook 'Stop' @{ stop_hook_active = $true }).Out.Trim() | Should -Be '{}' -Because 'the files are reviewed'
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host three'
        $again = Send-Hook 'Stop' @{ stop_hook_active = $true }
        $again.Json.decision | Should -Be 'block'
        $again.Json.reason | Should -Match 'Documentation review needed' -Because 'the earlier request was answered by a review'
        (Send-Hook 'Stop' @{ stop_hook_active = $true }).Json.reason | Should -Match 'Try once more'
        (Send-Hook 'Stop' @{ stop_hook_active = $true }).Json.systemMessage | Should -Match 'INCOMPLETE'
        (Send-Hook 'Stop' @{ stop_hook_active = $true }).Json.PSObject.Properties.Name | Should -Not -Contain 'decision'
    }
}

Describe 'Stale evidence, the release gate and failures' {

    BeforeEach { New-RRepo; Send-Hook 'UserPromptSubmit' | Out-Null; Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'; Invoke-WriterRun | Out-Null }

    It 'the gate passes for the reviewed files and fails after a later change to <File>' -TestCases @(
        @{ File = 'fabric-agentic-installer\Setup.ps1' }, @{ File = 'schema\a.json' }, @{ File = 'README.md' }, @{ File = 'tests\README.md' }, @{ File = 'fabric-agentic-installer\New.ps1' }
        # The images and the review controls are part of what a review covers.
        @{ File = 'assets\cover.png' }, @{ File = 'assets\new-diagram.png' }
        @{ File = '.github\agents\communication-writer.agent.md' }, @{ File = '.github\skills\product-communication\SKILL.md' }
        @{ File = '.github\hooks\Doc-Review.ps1' }
    ) {
        param($File)
        (Invoke-DocReview '-Gate').Exit | Should -Be 0
        Set-RFile $File 'changed after the review'
        $gate = Invoke-DocReview '-Gate'
        $gate.Exit | Should -Be 1
        $gate.Out | Should -Match 'is stale\. Changed since: '
        $gate.Out | Should -Match ([regex]::Escape($File.Replace('\', '/')))
    }

    It 'a change to a file outside the review (a test, the tooling) leaves the gate passing' {
        Set-RFile 'tests\Some.Tests.ps1' '# another test'
        Set-RFile '.github\workflows\x.yml' 'name: x'
        (Invoke-DocReview '-Gate').Exit | Should -Be 0
    }

    It 'restoring the reviewed content restores the review (the evidence is the content, not the time)' {
        Set-RFile 'README.md' 'temporary'
        (Invoke-DocReview '-Gate').Exit | Should -Be 1
        Set-RFile 'README.md' 'text of README.md'
        (Invoke-DocReview '-Gate').Exit | Should -Be 0
    }

    It 'a change to the Writer, the skill or the hook asks for a new review at the end of the task' {
        Send-Hook 'UserPromptSubmit' | Out-Null
        Set-RFile '.github\agents\communication-writer.agent.md' 'other rules'
        $r = Send-Hook 'Stop' @{ stop_hook_active = $false }
        $r.Json.decision | Should -Be 'block'
        $r.Json.reason | Should -Match '\.github/agents/communication-writer\.agent\.md'
    }

    It 'in the next task a new relevant change is asked about again' {
        Send-Hook 'UserPromptSubmit' | Out-Null
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host three'
        (Send-Hook 'Stop' @{ stop_hook_active = $false }).Json.decision | Should -Be 'block'
    }

    It 'the gate fails when the hook is <Case>' -TestCases @(
        @{ Case = 'missing'; Break = { Remove-Item -LiteralPath (Join-Path $script:Root '.github\hooks\documentation-review.json') }; Text = 'hook configuration is missing' }
        @{ Case = 'disabled'; Break = { Set-RFile '.github\hooks\documentation-review.json' '{ "version": 1, "disableAllHooks": true, "hooks": {} }' }; Text = 'disabled \(disableAllHooks\)' }
        @{ Case = 'without its Stop entry'; Break = { $j = [IO.File]::ReadAllText((Join-Path $script:Root '.github\hooks\documentation-review.json')) | ConvertFrom-Json; $j.hooks.PSObject.Properties.Remove('Stop'); Set-RFile '.github\hooks\documentation-review.json' ($j | ConvertTo-Json -Depth 6) }; Text = 'no Stop entry' }
        @{ Case = 'without the Writer agent'; Break = { Remove-Item -LiteralPath (Join-Path $script:Root '.github\agents\communication-writer.agent.md') }; Text = 'missing: \.github/agents/communication-writer\.agent\.md' }
    ) {
        param($Case, $Break, $Text)
        (Invoke-DocReview '-Gate').Exit | Should -Be 0
        & $Break
        $gate = Invoke-DocReview '-Gate'
        $gate.Exit | Should -Be 1
        $gate.Out | Should -Match "Hook problem: .*$Text"
        $gate.Out | Should -Match 'DOC GATE: FAIL'
    }

    It 'a hook that fails says so, exits with an error and writes no review' {
        $before = @(Get-RReviews).Count
        $state = $script:State
        try {
            $script:State = Join-Path $script:Root 'README.md\not-a-folder'
            $r = Send-Hook 'Stop' @{ stop_hook_active = $false }
            $r.Exit | Should -Be 1
            $r.Out.Trim() | Should -BeNullOrEmpty
            $r.Err | Should -Match 'Doc-Review\.ps1 failed'
        } finally { $script:State = $state }
        @(Get-RReviews).Count | Should -Be $before
    }

    It 'an event it does not know, or input that is not JSON, changes nothing' {
        (Invoke-DocReview '-HookEvent PreCompact' '{"hook_event_name":"PreCompact"}').Out.Trim() | Should -Be '{}'
        (Invoke-DocReview '-HookEvent SubagentStop' 'not json').Out.Trim() | Should -Be '{}'
    }
}

Describe 'Several sessions at once' {

    BeforeEach { New-RRepo }

    It 'keeps one state file per session and asks only the session whose task saw the change' {
        Send-Hook 'UserPromptSubmit' @{} 'session-a' | Out-Null
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        Send-Hook 'UserPromptSubmit' @{} 'session-b' | Out-Null
        (Send-Hook 'Stop' @{ stop_hook_active = $false } 'session-b').Out.Trim() | Should -Be '{}' -Because 'the change happened before the task of session-b began'
        (Send-Hook 'Stop' @{ stop_hook_active = $false } 'session-a').Json.decision | Should -Be 'block'
        @(Get-ChildItem -LiteralPath (Join-Path $script:State 'sessions') -Filter *.json | ForEach-Object { $_.BaseName } | Sort-Object) | Should -Be @('session-a', 'session-b')
    }

    It 'a review recorded in one session does not end another session''s request; the gate looks at the files only' {
        Send-Hook 'UserPromptSubmit' @{} 'session-a' | Out-Null
        Send-Hook 'UserPromptSubmit' @{} 'session-b' | Out-Null
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        Invoke-WriterRun -Session 'session-b' -AgentId 'agent-b' | Out-Null
        (Send-Hook 'Stop' @{ stop_hook_active = $false } 'session-b').Out.Trim() | Should -Be '{}' -Because 'session-b produced that review'
        $a = Send-Hook 'Stop' @{ stop_hook_active = $false } 'session-a'
        $a.Json.decision | Should -Be 'block' -Because 'a review from one session must not satisfy another session'
        $a.Json.reason | Should -Match 'Another session has reviewed these files; that review belongs to that session and does not end this task'
        @(Get-ChildItem -LiteralPath (Join-Path $script:State 'runs') -Filter *.json).Name | Should -Match '^session-b\.agent-b\.[0-9a-f]{32}\.json$'
        (Invoke-DocReview '-Gate').Exit | Should -Be 0 -Because 'the release gate is about the files, whoever reviewed them'
        # session-a runs its own Writer: its own record, and its request ends.
        Invoke-WriterRun -Session 'session-a' -AgentId 'agent-a' | Out-Null
        (Send-Hook 'Stop' @{ stop_hook_active = $true } 'session-a').Out.Trim() | Should -Be '{}'
        @(Read-RReviews | ForEach-Object { $_.sessionId } | Sort-Object) | Should -Be @('session-a', 'session-b')
    }

    It 'six hook processes at the same moment all succeed and leave readable state' {
        $jobs = foreach ($i in 1..6) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:Script + '" -HookEvent UserPromptSubmit'
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
            $psi.EnvironmentVariables['DOC_REVIEW_ROOT'] = $script:Root; $psi.EnvironmentVariables['DOC_REVIEW_STATE'] = $script:State
            $p = [Diagnostics.Process]::Start($psi)
            $p.StandardInput.Write((@{ hook_event_name = 'UserPromptSubmit'; session_id = "par-$($i % 3)" } | ConvertTo-Json -Compress)); $p.StandardInput.Close()
            $p
        }
        foreach ($p in $jobs) { [void]$p.StandardOutput.ReadToEnd(); $p.WaitForExit(); $p.ExitCode | Should -Be 0 }
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:State 'sessions') -Filter *.json) { ([IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json).baselineFingerprint | Should -Match '^[0-9a-f]{64}$' }
        @(Get-ChildItem -LiteralPath (Join-Path $script:State 'sessions') -Filter *.tmp).Count | Should -Be 0
    }

    It 'a session id that is not a plain token is stored under a hash, never as a path' {
        Send-Hook 'UserPromptSubmit' @{} '..\..\evil id' | Out-Null
        $names = @(Get-ChildItem -LiteralPath (Join-Path $script:State 'sessions') -Filter *.json | ForEach-Object { $_.BaseName })
        $names.Count | Should -Be 1
        $names[0] | Should -Match '^[0-9a-f]{32}$'
    }
}

Describe 'A verdict is bound to its run, session and agent' {

    BeforeEach {
        New-RRepo
        Send-Hook 'UserPromptSubmit' @{} 'session-a' | Out-Null
        Send-Hook 'UserPromptSubmit' @{} 'session-b' | Out-Null
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
    }

    It 'REGRESSION: the verdict of session-b''s Writer does not confirm session-a''s Writer run' {
        $a = Start-Writer 'session-a' 'writer-a'
        $b = Start-Writer 'session-b' 'writer-b'
        $a | Should -Not -Be $b
        (Send-Verdict $b 'complete' 'verdict of the session-b Writer').Exit | Should -Be 0
        # session-a's Writer stops without a verdict of its own: asked once, then nothing is recorded.
        (Stop-Writer 'session-a' 'writer-a').Json.decision | Should -Be 'block'
        (Stop-Writer 'session-a' 'writer-a' $true).Out.Trim() | Should -Be '{}'
        @(Get-RReviews).Count | Should -Be 0 -Because 'the only verdict belongs to another run'
        (Stop-Writer 'session-b' 'writer-b').Out.Trim() | Should -Be '{}'
        $reviews = @(Read-RReviews)
        $reviews.Count | Should -Be 1
        $reviews[0].sessionId | Should -Be 'session-b'
        $reviews[0].agentId | Should -Be 'writer-b'
        $reviews[0].runId | Should -Be $b
        $reviews[0].summary | Should -Be 'verdict of the session-b Writer'
    }

    It 'a run id is honoured only by the session and agent that started the run' {
        $a = Start-Writer 'session-a' 'writer-a'
        Send-Verdict $a | Out-Null
        (Stop-Writer 'session-b' 'writer-a').Out.Trim() | Should -Be '{}' -Because 'session-b started no such run'
        (Stop-Writer 'session-a' 'writer-x').Out.Trim() | Should -Be '{}' -Because 'another agent of the same session did not start it either'
        @(Get-RReviews).Count | Should -Be 0
        (Stop-Writer 'session-a' 'writer-a').Out.Trim() | Should -Be '{}'
        @(Read-RReviews)[0].runId | Should -Be $a
    }

    It 'a verdict file edited to name another run, session or agent is not accepted' {
        $a = Start-Writer 'session-a' 'writer-a'
        $b = Start-Writer 'session-b' 'writer-b'
        Send-Verdict $b | Out-Null
        # Copy session-b's verdict over the place where session-a's would be.
        Copy-Item -LiteralPath (Join-Path $script:State "attest\$b.json") -Destination (Join-Path $script:State "attest\$a.json")
        (Stop-Writer 'session-a' 'writer-a' $true).Out.Trim() | Should -Be '{}'
        @(Get-RReviews).Count | Should -Be 0 -Because 'the copied verdict names run, session and agent of session-b'
    }

    It 'two Writers with the same agent id in two sessions keep their own runs (an editor that sends no agent id)' {
        $startA = Send-Hook 'SubagentStart' @{ agent_type = $script:Writer } 'session-a'
        $startB = Send-Hook 'SubagentStart' @{ agent_type = $script:Writer } 'session-b'
        $a = Get-RunId $startA; $b = Get-RunId $startB
        Send-Verdict $a 'complete' 'from a' | Out-Null
        (Send-Hook 'SubagentStop' @{ agent_type = $script:Writer; stop_hook_active = $true } 'session-b').Out.Trim() | Should -Be '{}'
        @(Get-RReviews).Count | Should -Be 0
        (Send-Hook 'SubagentStop' @{ agent_type = $script:Writer; stop_hook_active = $false } 'session-a').Out.Trim() | Should -Be '{}'
        $reviews = @(Read-RReviews)
        $reviews.Count | Should -Be 1
        $reviews[0].sessionId | Should -Be 'session-a'
        $reviews[0].summary | Should -Be 'from a'
    }

    It 'CONCURRENCY: two sessions run their Writers at the same moment and neither exchanges nor overwrites the other''s state' {
        foreach ($round in 1..2) {
            Set-RFile 'fabric-agentic-installer\Setup.ps1' "Write-Host round $round"
            $sessions = @('session-a', 'session-b')
            # Start both runs at once.
            $started = foreach ($s in $sessions) { Start-DocReviewProcess '-HookEvent SubagentStart' (Get-HookPayload 'SubagentStart' @{ agent_id = "writer-$s"; agent_type = $script:Writer } $s) }
            $ids = @{}; for ($i = 0; $i -lt 2; $i++) { $ids[$sessions[$i]] = Get-RunId (Wait-DocReviewProcess $started[$i]) }
            $ids['session-a'] | Should -Not -Be $ids['session-b']
            # Both record a verdict at once, each under its own id.
            $verdicts = foreach ($s in $sessions) { Start-DocReviewProcess "-Attest -Run $($ids[$s]) -Verdict complete -Summary `"round $round verdict of $s`"" }
            foreach ($v in $verdicts) { (Wait-DocReviewProcess $v).Exit | Should -Be 0 }
            # Both stop at once.
            $stops = foreach ($s in $sessions) { Start-DocReviewProcess '-HookEvent SubagentStop' (Get-HookPayload 'SubagentStop' @{ agent_id = "writer-$s"; agent_type = $script:Writer; stop_hook_active = $false } $s) }
            foreach ($st in $stops) { $r = Wait-DocReviewProcess $st; $r.Exit | Should -Be 0 -Because $r.Err; $r.Out.Trim() | Should -Be '{}' }
            $mine = @(Read-RReviews | Where-Object { $_.summary -like "round $round *" })
            $mine.Count | Should -Be 2 -Because 'each session recorded its own review'
            foreach ($s in $sessions) {
                $r = @($mine | Where-Object { $_.sessionId -eq $s })
                $r.Count | Should -Be 1
                $r[0].runId | Should -Be $ids[$s]
                $r[0].agentId | Should -Be "writer-$s"
                $r[0].summary | Should -Be "round $round verdict of $s"
            }
            # Each session's own Stop is satisfied by its own review.
            $ends = foreach ($s in $sessions) { Start-DocReviewProcess '-HookEvent Stop' (Get-HookPayload 'Stop' @{ stop_hook_active = $false } $s) }
            foreach ($e in $ends) { (Wait-DocReviewProcess $e).Out.Trim() | Should -Be '{}' }
        }
        @(Get-ChildItem -LiteralPath (Join-Path $script:State 'runs') -Filter *.json).Count | Should -Be 4
        @(Get-ChildItem -LiteralPath $script:State -Recurse -Filter *.tmp).Count | Should -Be 0
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:State 'runs') -Filter *.json) { ([IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json).state | Should -Be 'recorded' }
    }

    It 'CONCURRENCY: while session-a''s Writer runs, session-b changes product source: session-a''s run is not recorded' {
        $a = Start-Writer 'session-a' 'writer-a'
        Set-RFile 'schema\a.json' '{ "changed": "by session-b" }'
        Send-Verdict $a | Out-Null
        $stop = Stop-Writer 'session-a' 'writer-a'
        $stop.Json.systemMessage | Should -Match 'files outside the Writer allowlist changed during the run'
        $stop.Json.systemMessage | Should -Match 'schema/a\.json'
        @(Get-RReviews).Count | Should -Be 0
    }

    It 'after a relevant change the old review and the old run id are worth nothing: a new review is required' {
        (Send-Hook 'Stop' @{ stop_hook_active = $false } 'session-a').Json.decision | Should -Be 'block'
        $first = Start-Writer 'session-a' 'writer-a'
        Send-Verdict $first | Out-Null
        Stop-Writer 'session-a' 'writer-a' | Out-Null
        (Send-Hook 'Stop' @{ stop_hook_active = $true } 'session-a').Out.Trim() | Should -Be '{}'
        (Invoke-DocReview '-Gate').Exit | Should -Be 0
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host three'
        (Invoke-DocReview '-Gate').Exit | Should -Be 1
        $again = Send-Hook 'Stop' @{ stop_hook_active = $true } 'session-a'
        $again.Json.decision | Should -Be 'block'
        $again.Json.reason | Should -Match 'Documentation review needed'
        $reuse = Send-Verdict $first
        $reuse.Exit | Should -Be 2
        $reuse.Err | Should -Match 'cannot be used again'
        (Send-Hook 'Stop' @{ stop_hook_active = $true } 'session-a').Json.decision | Should -Be 'block' -Because 'the old verdict was refused'
        @(Get-RReviews).Count | Should -Be 1
        # A new run with its own id settles it.
        Invoke-WriterRun -Session 'session-a' -AgentId 'writer-a2' | Out-Null
        (Invoke-DocReview '-Gate').Exit | Should -Be 0
        @(Read-RReviews | ForEach-Object { $_.runId } | Sort-Object -Unique).Count | Should -Be 2
    }
}

Describe 'The Writer changes its five documents and nothing else' {

    BeforeEach { New-RRepo; Send-Hook 'UserPromptSubmit' | Out-Null; Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two' }

    It 'a run that edited every document of the allowlist is recorded, with the list of what it changed' {
        Invoke-WriterRun { foreach ($d in $script:Allowed) { Set-RFile $d "edited $d" } } | Out-Null
        $reviews = @(Read-RReviews)
        $reviews.Count | Should -Be 1
        @($reviews[0].documentsChanged | Sort-Object) | Should -Be @($script:Allowed | Sort-Object)
    }

    It 'a run that touched <Case> is rejected and the file is named' -TestCases @(
        @{ Case = 'the installer'; File = 'fabric-agentic-installer/Setup.ps1'; Change = { Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host hacked' } }
        @{ Case = 'a test'; File = 'tests/Some.Tests.ps1'; Change = { Set-RFile 'tests\Some.Tests.ps1' '# weakened' } }
        @{ Case = 'a schema'; File = 'schema/a.json'; Change = { Set-RFile 'schema\a.json' '{ "x": 1 }' } }
        @{ Case = 'an image'; File = 'assets/cover.png'; Change = { Set-RFile 'assets\cover.png' 'image two' } }
        @{ Case = 'its own agent file'; File = '.github/agents/communication-writer.agent.md'; Change = { Set-RFile '.github\agents\communication-writer.agent.md' 'I may edit anything' } }
        @{ Case = 'the communication skill'; File = '.github/skills/product-communication/SKILL.md'; Change = { Set-RFile '.github\skills\product-communication\SKILL.md' 'other rules' } }
        @{ Case = 'the hook script'; File = '.github/hooks/Doc-Review.ps1'; Change = { Set-RFile '.github\hooks\Doc-Review.ps1' '# gate removed' } }
        @{ Case = 'the hook configuration'; File = '.github/hooks/documentation-review.json'; Change = { Set-RFile '.github\hooks\documentation-review.json' '{ "hooks": {} }' } }
        @{ Case = 'a workflow (a release control)'; File = '.github/workflows/validate.yml'; Change = { Set-RFile '.github\workflows\validate.yml' 'name: none' } }
        @{ Case = 'a new document'; File = 'docs/NEW.md'; Change = { Set-RFile 'docs\NEW.md' 'a new page' } }
        @{ Case = 'a scratch file in the root'; File = 'notes.txt'; Change = { Set-RFile 'notes.txt' 'scratch' } }
        @{ Case = 'a removed file'; File = 'schema/a.json (removed)'; Change = { Remove-Item -LiteralPath (Join-Path $script:Root 'schema\a.json') } }
    ) {
        param($Case, $File, $Change)
        $stop = Invoke-WriterRun { Set-RFile 'README.md' 'a legitimate edit'; & $Change }
        $stop.Json.systemMessage | Should -Match 'Documentation review not recorded \(files outside the Writer allowlist changed during the run\)'
        $stop.Json.systemMessage | Should -Match ([regex]::Escape($File))
        ($stop.Json.systemMessage -split 'The Communication Writer may change only')[0] | Should -Not -Match 'README\.md' -Because 'an allowed edit is not reported as a violation'
        @(Get-RReviews).Count | Should -Be 0
        $status = (Invoke-DocReview '-Status').Out
        $status | Should -Match 'Latest Writer run [0-9a-f]{8} \(session session-\): NOT recorded - files outside the Writer allowlist changed during the run: '
        $status | Should -Match ([regex]::Escape($File))
        (Invoke-DocReview '-Gate').Exit | Should -Be 1
    }

    It 'the rejection reaches the developer agent: the next end-of-task request names the reason and the files' {
        (Send-Hook 'Stop' @{ stop_hook_active = $false }).Json.decision | Should -Be 'block'
        Invoke-WriterRun { Set-RFile 'tests\Some.Tests.ps1' '# weakened' } | Out-Null
        $second = Send-Hook 'Stop' @{ stop_hook_active = $true }
        $second.Json.decision | Should -Be 'block'
        $second.Json.reason | Should -Match 'The last Communication Writer run of this session was not recorded: files outside the Writer allowlist changed during the run \(tests/Some\.Tests\.ps1\)'
    }

    It 'a rejected run is closed: its verdict cannot be recorded afterwards, and nothing was reverted' {
        $runId = Start-Writer
        Set-RFile 'tests\Some.Tests.ps1' '# weakened'
        Send-Verdict $runId | Out-Null
        Stop-Writer | Out-Null
        (Send-Verdict $runId).Exit | Should -Be 2
        [IO.File]::ReadAllText((Join-Path $script:Root 'tests\Some.Tests.ps1')) | Should -Be '# weakened' -Because 'the hook reports; it does not undo work'
    }

    It 'files that are not part of the repository content are not compared (.git, virtual environments, temporary files)' {
        $stop = Invoke-WriterRun { Set-RFile '.venv\lib\x.py' 'x'; Set-RFile '.git\index' 'x'; Set-RFile 'tests\out.tmp' 'x'; Set-RFile '__pycache__\a.pyc' 'x' }
        $stop.Out.Trim() | Should -Be '{}'
        @(Get-RReviews).Count | Should -Be 1
    }
}

Describe 'Policy and legal documents hold the text their owner approved' {

    BeforeEach { New-RRepo; Send-Hook 'UserPromptSubmit' | Out-Null }

    It 'with every approval in place and a review recorded, the gate passes and says so' {
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        Invoke-WriterRun | Out-Null
        $gate = Invoke-DocReview '-Gate'
        $gate.Exit | Should -Be 0
        $gate.Out | Should -Match 'Policy and legal documents: 4 hold the text their owner approved'
    }

    It 'an unapproved edit of <File> fails the gate, also when a Writer reviewed the result' -TestCases @(@{ File = 'SECURITY.md' }, @{ File = 'CODE_OF_CONDUCT.md' }, @{ File = 'LICENSE' }, @{ File = 'THIRD_PARTY_NOTICES.md' }) {
        param($File)
        Set-RFile $File "text of $File with a changed commitment"
        Invoke-WriterRun | Out-Null
        @(Get-RReviews).Count | Should -Be 1 -Because 'the Writer reviewed the files and changed none of them'
        $gate = Invoke-DocReview '-Gate'
        $gate.Exit | Should -Be 1
        $gate.Out | Should -Match "Policy problem: $([regex]::Escape($File)) differs from the text its owner approved"
        $gate.Out | Should -Match 'DOC GATE: FAIL - a policy or legal document does not hold the text its owner approved'
        # The developer agent is told at the end of the task as well.
        Send-Hook 'UserPromptSubmit' @{} 'session-y' | Out-Null
        Set-RFile 'README.md' 'another edit'
        (Send-Hook 'Stop' @{ stop_hook_active = $false } 'session-y').Json.reason | Should -Match "Policy or legal text changed without a recorded owner approval: $([regex]::Escape($File))"
    }

    It 'an approval covers one exact text: the approved correction passes, the next edit fails again' {
        Set-RFile 'SECURITY.md' 'text of SECURITY.md with one corrected fact'
        $ok = Invoke-DocReview '-ApprovePolicy -File SECURITY.md -ApprovedBy "test owner" -Reason "corrected one fact"'
        $ok.Exit | Should -Be 0
        $ok.Out | Should -Match 'The approval covers this exact text only'
        $entry = ([IO.File]::ReadAllText((Join-Path $script:Root '.github\hooks\policy-approvals.json')) | ConvertFrom-Json).documents.'SECURITY.md'
        $entry.sha256 | Should -Be (Get-RPolicyHash (Join-Path $script:Root 'SECURITY.md'))
        $entry.approvedBy | Should -Be 'test owner'
        $entry.reason | Should -Be 'corrected one fact'
        Invoke-WriterRun | Out-Null
        (Invoke-DocReview '-Gate').Exit | Should -Be 0
        # Not a blanket authorization: a second, unapproved change to the same file.
        Set-RFile 'SECURITY.md' 'text of SECURITY.md with one corrected fact and one more change'
        Invoke-WriterRun -AgentId 'agent-2' | Out-Null
        $gate = Invoke-DocReview '-Gate'
        $gate.Exit | Should -Be 1
        $gate.Out | Should -Match 'Policy problem: SECURITY\.md differs'
        # Nor does it cover another document.
        Set-RFile 'SECURITY.md' 'text of SECURITY.md with one corrected fact'
        Set-RFile 'CODE_OF_CONDUCT.md' 'changed too'
        (Invoke-DocReview '-Gate').Out | Should -Match 'Policy problem: CODE_OF_CONDUCT\.md differs'
    }

    It 'an approval needs a document from the list, a name and a reason' {
        (Invoke-DocReview '-ApprovePolicy -File README.md -ApprovedBy "x" -Reason "y"').Exit | Should -Be 2
        (Invoke-DocReview '-ApprovePolicy -File SECURITY.md -Reason "y"').Exit | Should -Be 2
        (Invoke-DocReview '-ApprovePolicy -File SECURITY.md -ApprovedBy "x"').Exit | Should -Be 2
        (Invoke-DocReview '-ApprovePolicy -File ..\SECURITY.md -ApprovedBy "x" -Reason "y"').Exit | Should -Be 2
    }

    It 'the Writer cannot approve its own change: an approval recorded during its run voids the run' {
        $stop = Invoke-WriterRun { Set-RFile 'SECURITY.md' 'rewritten by the writer'; Invoke-DocReview '-ApprovePolicy -File SECURITY.md -ApprovedBy "the writer" -Reason "self-approved"' | Out-Null }
        $stop.Json.systemMessage | Should -Match 'policy or legal document changed during the run'
        $stop.Json.systemMessage | Should -Match '\.github/hooks/policy-approvals\.json'
        @(Get-RReviews).Count | Should -Be 0
    }

    It 'the gate fails when the approvals are missing, unreadable or lack a document' {
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        $approvals = Join-Path $script:Root '.github\hooks\policy-approvals.json'
        $good = [IO.File]::ReadAllText($approvals)
        Remove-Item -LiteralPath $approvals
        Invoke-WriterRun | Out-Null
        (Invoke-DocReview '-Gate').Out | Should -Match 'Policy problem: the owner approvals are missing or unreadable'
        Set-RFile '.github\hooks\policy-approvals.json' 'not json'
        (Invoke-DocReview '-Gate').Exit | Should -Be 1
        $j = $good | ConvertFrom-Json; $j.documents.PSObject.Properties.Remove('LICENSE')
        Set-RFile '.github\hooks\policy-approvals.json' ($j | ConvertTo-Json -Depth 5)
        Invoke-WriterRun -AgentId 'agent-2' | Out-Null
        $gate = Invoke-DocReview '-Gate'
        $gate.Exit | Should -Be 1
        $gate.Out | Should -Match 'Policy problem: LICENSE has no recorded owner approval'
    }

    It 'line ends do not change what was approved (a clone with CRLF and one with LF agree)' {
        Set-RFile 'LICENSE' "line one`nline two`n"
        (Invoke-DocReview '-ApprovePolicy -File LICENSE -ApprovedBy "test owner" -Reason "two lines"').Exit | Should -Be 0
        Set-RFile 'LICENSE' "line one`r`nline two`r`n"
        (Invoke-DocReview '-Status').Out | Should -Match 'Policy and legal documents: 4 hold the text their owner approved'
        Set-RFile 'LICENSE' "line one`r`nline 2`r`n"
        (Invoke-DocReview '-Status').Out | Should -Match 'Policy problem: LICENSE differs'
    }

    It 'THIS REPOSITORY: the four documents hold exactly the text recorded in .github/hooks/policy-approvals.json' {
        $path = Join-Path $script:Repo '.github\hooks\policy-approvals.json'
        Test-Path -LiteralPath $path | Should -BeTrue
        $approvals = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        @($approvals.documents.PSObject.Properties.Name) | Should -Be $script:Protected
        foreach ($d in $script:Protected) {
            $entry = $approvals.documents.$d
            $entry.sha256 | Should -Be (Get-RPolicyHash (Join-Path $script:Repo $d)) -Because "$d may change only with a recorded owner approval of the exact text (Doc-Review.ps1 -ApprovePolicy)"
            $entry.approvedBy | Should -Not -BeNullOrEmpty
            $entry.reason | Should -Not -BeNullOrEmpty
        }
    }
}
