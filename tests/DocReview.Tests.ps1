# DocReview.Tests.ps1
# -------------------------------------------------------------------
# The maintainer documentation workflow in .github/: the product-communication skill, the
# Communication Writer agent, the completion hook and the release gate (Doc-Review.ps1).
# The script is run as a real child process against a throwaway repository under TEMP, with
# hook events on stdin as the editor sends them. These tests prove what the SCRIPT does:
#   - an unrelated change asks for nothing; a relevant one asks for a review, at most twice;
#   - a review exists only after a Writer attested AND its SubagentStop event was seen;
#   - any later change of a watched file makes that review stale;
#   - a failed hook, a missing hook or a hand-run script never counts as a review.
# They do not prove that an editor session fires the events or that an agent delegates.

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:Script = Join-Path $script:Repo '.github\hooks\Doc-Review.ps1'
    $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('fabric docreview ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:Writer = 'Communication Writer'

    function Set-RFile([string]$Rel, [string]$Text) {
        $p = Join-Path $script:Root $Rel
        New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($p, $Text, $script:Utf8)
    }
    # A fresh repository with one source file, the documents, and the real hook files.
    function New-RRepo {
        $script:Root = Join-Path $script:Base ('repo ' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:State = Join-Path $script:Root '.state'
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host one'
        Set-RFile 'schema\a.json' '{}'
        Set-RFile 'tests\Some.Tests.ps1' '# test'
        foreach ($d in 'README.md', 'CHANGELOG.md', 'CLI-FUNCTIONALITIES.md', 'CONTRIBUTING.md', 'tests\README.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md') { Set-RFile $d "text of $d" }
        foreach ($f in '.github\hooks\documentation-review.json', '.github\agents\communication-writer.agent.md', '.github\skills\product-communication\SKILL.md') {
            Set-RFile $f ([IO.File]::ReadAllText((Join-Path $script:Repo $f)))
        }
    }
    function Invoke-DocReview([string]$Arguments, [string]$StdIn = $null) {
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
        $err = $p.StandardError.ReadToEndAsync()
        $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
        $json = $null; try { if ($out.Trim()) { $json = $out | ConvertFrom-Json } } catch { }
        return [pscustomobject]@{ Exit = $p.ExitCode; Out = $out; Err = $err.Result; Json = $json }
    }
    function Send-Hook([string]$Name, [hashtable]$Fields = @{}, [string]$Session = 'session-a') {
        $payload = @{ hook_event_name = $Name; session_id = $Session; timestamp = '2026-01-01T00:00:00Z' }
        foreach ($k in $Fields.Keys) { $payload[$k] = $Fields[$k] }
        return (Invoke-DocReview "-HookEvent $Name" ($payload | ConvertTo-Json -Compress))
    }
    function Get-RReviews { return @(Get-ChildItem -LiteralPath (Join-Path $script:State 'reviews') -Filter *.json -ErrorAction SilentlyContinue) }
    # A complete Writer run as the editor reports it: start, the subagent's own prompt event, optional work, attestation, stop.
    function Invoke-WriterRun([scriptblock]$Work = { }, [string]$Verdict = 'complete', [string]$Session = 'session-a', [string]$AgentId = 'agent-1') {
        Send-Hook 'SubagentStart' @{ agent_id = $AgentId; agent_type = $script:Writer } $Session | Out-Null
        Send-Hook 'UserPromptSubmit' @{ prompt = 'review the documents' } $Session | Out-Null
        & $Work
        Invoke-DocReview "-Attest -Verdict $Verdict -Summary `"checked the documents`"" | Out-Null
        return (Send-Hook 'SubagentStop' @{ agent_id = $AgentId; agent_type = $script:Writer; stop_hook_active = $false } $Session)
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
        $text | Should -Match '-Attest -Verdict complete'
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
        $r.Json.reason | Should -Match '-NoImpact -Reason'
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

    It 'a recorded "no documentation impact" quiets the reminder but is not a review' {
        Set-RFile 'fabric-agentic-installer\Setup.ps1' '# comment only'
        (Invoke-DocReview '-NoImpact').Exit | Should -Be 2 -Because 'a reason is required'
        (Invoke-DocReview '-NoImpact -Reason "comment only"').Exit | Should -Be 0
        (Send-Hook 'Stop' @{ stop_hook_active = $false }).Out.Trim() | Should -Be '{}'
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
        $start.Json.hookSpecificOutput.additionalContext | Should -Match '-Attest -Verdict complete'
        $start.Json.additionalContext | Should -Be $start.Json.hookSpecificOutput.additionalContext
        Set-RFile 'CHANGELOG.md' 'text of CHANGELOG.md plus one bullet'
        (Invoke-DocReview '-Attest -Verdict complete -Summary "added one bullet"').Exit | Should -Be 0
        @(Get-RReviews).Count | Should -Be 0 -Because 'the attestation alone is not a review'
        (Send-Hook 'SubagentStop' @{ agent_id = 'agent-1'; agent_type = $script:Writer; stop_hook_active = $false }).Out.Trim() | Should -Be '{}'
        $review = [IO.File]::ReadAllText((Get-RReviews)[0].FullName) | ConvertFrom-Json
        $review.confirmedBy | Should -Be 'SubagentStop hook'
        $review.sessionId | Should -Be 'session-a'
        $review.summary | Should -Be 'added one bullet'
        (Send-Hook 'Stop' @{ stop_hook_active = $true }).Out.Trim() | Should -Be '{}'
        $gate = Invoke-DocReview '-Gate'
        $gate.Exit | Should -Be 0
        $gate.Out | Should -Match 'DOC GATE: PASS'
    }

    It 'running the script by hand never creates a review' {
        (Invoke-DocReview '-Attest -Verdict complete -Summary "by hand"').Exit | Should -Be 0
        (Invoke-DocReview '-Status').Out | Should -Match 'Reviewed: NO'
        (Invoke-DocReview '-Gate').Exit | Should -Be 1
        @(Get-RReviews).Count | Should -Be 0
    }

    It 'another agent finishing is not a review, even after an attestation' {
        Send-Hook 'SubagentStart' @{ agent_id = 'agent-9'; agent_type = 'default' } | Out-Null
        Invoke-DocReview '-Attest -Verdict complete -Summary "not the writer"' | Out-Null
        (Send-Hook 'SubagentStop' @{ agent_id = 'agent-9'; agent_type = 'default'; stop_hook_active = $false }).Out.Trim() | Should -Be '{}'
        @(Get-RReviews).Count | Should -Be 0
    }

    It 'a Writer that finishes without a verdict is asked once, then no review is recorded' {
        Send-Hook 'SubagentStart' @{ agent_id = 'agent-1'; agent_type = $script:Writer } | Out-Null
        $first = Send-Hook 'SubagentStop' @{ agent_id = 'agent-1'; agent_type = $script:Writer; stop_hook_active = $false }
        $first.Json.hookSpecificOutput.decision | Should -Be 'block'
        $first.Json.reason | Should -Match 'record your verdict'
        (Send-Hook 'SubagentStop' @{ agent_id = 'agent-1'; agent_type = $script:Writer; stop_hook_active = $true }).Out.Trim() | Should -Be '{}'
        @(Get-RReviews).Count | Should -Be 0
        (Invoke-DocReview '-Gate').Exit | Should -Be 1
    }

    It 'a Writer whose start the hook did not see leaves no review' {
        Invoke-DocReview '-Attest -Verdict complete -Summary "x"' | Out-Null
        Send-Hook 'SubagentStop' @{ agent_id = 'agent-1'; agent_type = $script:Writer; stop_hook_active = $false } | Out-Null
        @(Get-RReviews).Count | Should -Be 0
    }

    It 'the verdict "incomplete" is recorded as no review' {
        (Invoke-WriterRun -Verdict 'incomplete').Json.systemMessage | Should -Match 'verdict-incomplete'
        @(Get-RReviews).Count | Should -Be 0
    }

    It 'a file changed after the verdict: the Writer is sent back once, and the second verdict counts' {
        Send-Hook 'SubagentStart' @{ agent_id = 'agent-1'; agent_type = $script:Writer } | Out-Null
        Invoke-DocReview '-Attest -Verdict complete -Summary "first"' | Out-Null
        Set-RFile 'README.md' 'changed after the verdict'
        $stop = Send-Hook 'SubagentStop' @{ agent_id = 'agent-1'; agent_type = $script:Writer; stop_hook_active = $false }
        $stop.Json.decision | Should -Be 'block'
        $stop.Json.reason | Should -Match 'README\.md'
        Invoke-DocReview '-Attest -Verdict complete -Summary "second"' | Out-Null
        Send-Hook 'SubagentStop' @{ agent_id = 'agent-1'; agent_type = $script:Writer; stop_hook_active = $true } | Out-Null
        @(Get-RReviews).Count | Should -Be 1
        ([IO.File]::ReadAllText((Get-RReviews)[0].FullName) | ConvertFrom-Json).summary | Should -Be 'second'
    }

    It 'a Writer run during which product source changed is not a review' {
        $stop = Invoke-WriterRun { Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host three' }
        $stop.Json.systemMessage | Should -Match 'source-changed-during-review'
        @(Get-RReviews).Count | Should -Be 0
    }

    It 'a Writer run that changed <File> is not a review' -TestCases @(@{ File = 'LICENSE' }, @{ File = 'THIRD_PARTY_NOTICES.md' }) {
        param($File)
        $stop = Invoke-WriterRun { Set-RFile $File 'rewritten' }
        $stop.Json.systemMessage | Should -Match "locked-document-changed:$([regex]::Escape($File))"
        @(Get-RReviews).Count | Should -Be 0
    }

    It 'a policy document changed in a review is recorded for the owner and shown by the gate' {
        Invoke-WriterRun { Set-RFile 'SECURITY.md' 'fixed a link' } | Out-Null
        ([IO.File]::ReadAllText((Get-RReviews)[0].FullName) | ConvertFrom-Json).policyDocumentsChanged | Should -Be @('SECURITY.md')
        $gate = Invoke-DocReview '-Gate'
        $gate.Exit | Should -Be 0
        $gate.Out | Should -Match 'Policy documents changed in that review - the owner confirms them: SECURITY\.md'
    }

    It 'one attestation serves one Writer run only' {
        Invoke-WriterRun | Out-Null
        @(Get-RReviews).Count | Should -Be 1
        Send-Hook 'SubagentStart' @{ agent_id = 'agent-2'; agent_type = $script:Writer } | Out-Null
        $stop = Send-Hook 'SubagentStop' @{ agent_id = 'agent-2'; agent_type = $script:Writer; stop_hook_active = $true }
        $stop.Out.Trim() | Should -Be '{}'
        @(Get-RReviews).Count | Should -Be 1
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

    It 'a review recorded in one session serves every session, and each Writer run has its own record' {
        Send-Hook 'UserPromptSubmit' @{} 'session-a' | Out-Null
        Send-Hook 'UserPromptSubmit' @{} 'session-b' | Out-Null
        Set-RFile 'fabric-agentic-installer\Setup.ps1' 'Write-Host two'
        Invoke-WriterRun -Session 'session-b' -AgentId 'agent-b' | Out-Null
        (Send-Hook 'Stop' @{ stop_hook_active = $false } 'session-a').Out.Trim() | Should -Be '{}'
        @(Get-ChildItem -LiteralPath (Join-Path $script:State 'runs') -Filter *.json).Name | Should -Be @('session-b.agent-b.json')
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
