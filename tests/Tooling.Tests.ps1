# Tooling.Tests.ps1
# -------------------------------------------------------------------
# CLI and MCP capability rules added in v0.9.0, read from the installer source and run
# in-process (nothing is installed, started or contacted):
#   * remote Microsoft-hosted MCP servers (Fabric IQ, Fabric Data Warehouse) are detected
#     by URL in a parsed mcp.json, never added by the installer, and granted to named
#     agents only;
#   * agents report the state they can prove: documented, configured, callable,
#     signed in, executed;
#   * SQL work is classified (S0-S4) before a route is chosen: a SQL tool is not permission;
#   * Tabular Editor 2, Tabular Editor 3 and the te CLI stay three separate products;
#   * detect-only tools are never installed; Project Osmos is never started by the kit.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $script:Raw = [IO.File]::ReadAllText($script:Installer)
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$null, [ref]$null)
    $script:Manifest = Get-AgentManifest
    . (Get-InstallerFunctionLoader 'Get-RemoteMcpServers')

    function Get-HereString([string]$Name) {
        $m = [regex]::Match($script:Raw, "(?s)\`$$Name = @'\r?\n(.*?)\r?\n'@")
        $m.Success | Should -BeTrue -Because "the installer must define `$$Name"
        return ($m.Groups[1].Value -replace "`r`n", "`n")
    }
    function Get-AgentBlock([string]$Id) {
        $m = [regex]::Match($script:Raw, "(?s)\r?\n    '$([regex]::Escape($Id))' = @\{\r?\n(.*?)\r?\n    \}")
        $m.Success | Should -BeTrue -Because "agent knowledge for $Id must exist"
        return $m.Groups[1].Value
    }
    function Get-IdList([string]$Variable) {
        $m = [regex]::Match($script:Raw, "(?m)^\`$$Variable = @\(([^)]*)\)")
        $m.Success | Should -BeTrue -Because "the installer must define `$$Variable"
        return @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    }
    function Get-Section([string]$Text, [string]$Heading) {
        $m = [regex]::Match($Text, "(?ms)^## $([regex]::Escape($Heading)).*?(?=^## |\z)")
        $m.Success | Should -BeTrue -Because "section '$Heading' must exist"
        return $m.Value
    }
    function New-McpConfig([System.Collections.IDictionary]$Servers) {
        $s = [ordered]@{}
        foreach ($k in $Servers.Keys) { $s[$k] = [pscustomobject]$Servers[$k] }
        return [pscustomobject]@{ servers = [pscustomobject]$s }
    }
    $script:Policy = Get-HereString 'cliPolicyContent'
    $script:Status = Get-HereString 'sessionStatusScript'
    $script:Remote = Get-Section $script:Policy 'Remote MCP servers - Fabric IQ and Fabric Data Warehouse'
    $script:Sql = Get-Section $script:Policy 'SQL work - permission class first, then the route'
    # Synthetic identifiers only (one repeated digit).
    $script:Ws = '11111111-1111-1111-1111-111111111111'
    $script:Item = '22222222-2222-2222-2222-222222222222'
    $script:IqUrl = 'https://fabriciq.svc.cloud.microsoft/v1/mcp/fabriciq'
    $script:DwGlobal = 'https://api.fabric.microsoft.com/v1/mcp/dataPlane/sqlEndpoint'
    $script:DwItem = "https://api.fabric.microsoft.com/v1/mcp/dataPlane/workspaces/$($script:Ws)/items/$($script:Item)/sqlEndpoint"
}

Describe 'Remote MCP servers are detected by URL, not assumed (TOOL-01, TOOL-02)' {

    It 'reports both servers as not configured when there is no mcp.json or it has no servers' {
        foreach ($cfg in @($null, [pscustomobject]@{ }, [pscustomobject]@{ servers = $null }, (New-McpConfig @{ }))) {
            $r = @(Get-RemoteMcpServers $cfg)
            @($r | ForEach-Object { $_.Key }) | Should -Be @('fabricIqMcp', 'fabricDataWarehouseMcp')
            foreach ($x in $r) { $x.Configured | Should -BeFalse; $x.KeyMatchesGrant | Should -BeFalse; @($x.ServerKeys).Count | Should -Be 0 }
        }
    }

    It 'finds Fabric IQ under the documented key, on the public and the private-link endpoint' {
        foreach ($url in $script:IqUrl, 'https://api.fabric.microsoft.com/v1/mcp/fabriciq', "$($script:IqUrl)/") {
            $iq = @(Get-RemoteMcpServers (New-McpConfig @{ FabricIQ = @{ type = 'http'; url = $url } })) | Where-Object { $_.Key -eq 'fabricIqMcp' }
            $iq.Configured | Should -BeTrue -Because $url
            $iq.KeyMatchesGrant | Should -BeTrue
            $iq.Release | Should -Be 'generally available'
            $iq.Access | Should -Be 'read-only'
        }
    }

    It 'says so when a server is saved under a key the agents hold no grant for' {
        $iq = @(Get-RemoteMcpServers (New-McpConfig @{ 'my-fabric-iq' = @{ type = 'http'; url = $script:IqUrl } })) | Where-Object { $_.Key -eq 'fabricIqMcp' }
        $iq.Configured | Should -BeTrue
        $iq.KeyMatchesGrant | Should -BeFalse
        @($iq.ServerKeys) | Should -Be @('my-fabric-iq')
        # The grant is an exact server name: another letter case is another name.
        (@(Get-RemoteMcpServers (New-McpConfig @{ fabriciq = @{ type = 'http'; url = $script:IqUrl } })) | Where-Object { $_.Key -eq 'fabricIqMcp' }).KeyMatchesGrant | Should -BeFalse
    }

    It 'tells the global Fabric Data Warehouse endpoint from an item-scoped one' {
        $global = @(Get-RemoteMcpServers (New-McpConfig @{ 'fabric-dw-global' = @{ type = 'http'; url = $script:DwGlobal } })) | Where-Object { $_.Key -eq 'fabricDataWarehouseMcp' }
        $global.Configured | Should -BeTrue; $global.Scope | Should -Be 'global'; $global.KeyMatchesGrant | Should -BeTrue
        $item = @(Get-RemoteMcpServers (New-McpConfig @{ 'fabric-dw-item' = @{ type = 'http'; url = $script:DwItem } })) | Where-Object { $_.Key -eq 'fabricDataWarehouseMcp' }
        $item.Configured | Should -BeTrue; $item.Scope | Should -Be 'item'; $item.KeyMatchesGrant | Should -BeTrue
        $both = @(Get-RemoteMcpServers (New-McpConfig ([ordered]@{ 'fabric-dw-global' = @{ type = 'http'; url = $script:DwGlobal }; 'fabric-dw-item' = @{ type = 'http'; url = $script:DwItem } }))) | Where-Object { $_.Key -eq 'fabricDataWarehouseMcp' }
        $both.Scope | Should -Be 'global+item'
        # The order of the report follows the kit's own list, not the order of entries in the file.
        (@(Get-RemoteMcpServers (New-McpConfig ([ordered]@{ 'fabric-dw-item' = @{ type = 'http'; url = $script:DwItem }; 'fabric-dw-global' = @{ type = 'http'; url = $script:DwGlobal } }))) | Where-Object { $_.Key -eq 'fabricDataWarehouseMcp' }).Scope | Should -Be 'global+item'
        $both.Release | Should -Be 'preview'
        $both.Access | Should -Match 'statements that change data'
    }

    It 'NEGATIVE CONTROL: <Name> is not taken for a known server' -TestCases @(
        @{ Name = 'another host with the same path'; Url = 'https://example.invalid/v1/mcp/fabriciq' },
        @{ Name = 'plain http'; Url = 'http://fabriciq.svc.cloud.microsoft/v1/mcp/fabriciq' },
        @{ Name = 'a longer path'; Url = 'https://fabriciq.svc.cloud.microsoft/v1/mcp/fabriciq/extra' },
        @{ Name = 'a host that only ends like the real one'; Url = 'https://api.fabric.microsoft.com.example.invalid/v1/mcp/dataPlane/sqlEndpoint' },
        @{ Name = 'the Microsoft Learn server'; Url = 'https://learn.microsoft.com/api/mcp' },
        @{ Name = 'an item-scoped path with an extra segment'; Url = 'https://api.fabric.microsoft.com/v1/mcp/dataPlane/workspaces/a/b/items/c/sqlEndpoint' },
        @{ Name = 'an empty url'; Url = '' }
    ) {
        param($Name, $Url)
        foreach ($x in @(Get-RemoteMcpServers (New-McpConfig @{ FabricIQ = @{ type = 'http'; url = $Url }; 'fabric-dw-global' = @{ type = 'http'; url = $Url } }))) { $x.Configured | Should -BeFalse -Because $Name }
    }

    It 'ignores servers that have no url (local stdio servers)' {
        foreach ($x in @(Get-RemoteMcpServers (New-McpConfig @{ pbiviz = @{ type = 'stdio'; command = 'node' } }))) { $x.Configured | Should -BeFalse }
    }

    It 'the session status script carries the identical function' {
        $fn = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-RemoteMcpServers' }, $false) | Select-Object -First 1
        $statusAst = [System.Management.Automation.Language.Parser]::ParseInput($script:Status, [ref]$null, [ref]$null)
        $copy = $statusAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-RemoteMcpServers' }, $false) | Select-Object -First 1
        $copy | Should -Not -BeNullOrEmpty
        ($copy.Extent.Text -replace "`r`n", "`n") | Should -BeExactly ($fn.Extent.Text -replace "`r`n", "`n")
    }

    It 'the status script re-reads mcp.json each session, never lists a remote server as an available tool, and keeps the honest MCP line' {
        $script:Status | Should -Match ([regex]::Escape('$remoteMcp = @(Get-RemoteMcpServers $remoteMcpConfig)'))
        $script:Status | Should -Match ([regex]::Escape("if (`$t.category -eq 'mcp-remote') { continue }"))
        $script:Status | Should -Match "category = 'mcp-remote'; installMode = 'detect'"
        $script:Status | Should -Match "mcpToolsCallable = 'unknown'"
        $script:Status | Should -Match 'configured is not signed in or callable'
        $script:Status | Should -Match 'connected: none yet'
    }
}

Describe 'The installer records remote MCP servers and never adds them (TOOL-01, TOOL-02)' {

    It 'records both as detect-only entries whose tools are of unknown callability' {
        $script:Raw | Should -Match ([regex]::Escape("Set-ToolStatus -Key `$remoteMcp.Key -Found `$remoteMcp.Configured -Category 'mcp-remote' -InstallMode 'detect'"))
        $script:Raw | Should -Match "keyMatchesGrant = \`$remoteMcp\.KeyMatchesGrant; mcpToolsCallable = 'unknown'"
    }

    It 'writes only the Microsoft Learn server into mcp.json' {
        $fn = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Merge-McpJson' }, $false) | Select-Object -First 1
        $fn.Extent.Text | Should -Not -Match 'fabriciq|sqlEndpoint|dataPlane'
        $calls = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Merge-McpJson', 'Add-McpServerText') }, $true) |
            Where-Object { $p = $_.Parent; $inside = $false; while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inside = $true; break }; $p = $p.Parent }; -not $inside })
        $calls.Count | Should -Be 1
        $calls[0].Extent.Text | Should -BeExactly 'Merge-McpJson -Path "$rootPath\.vscode\mcp.json"'
    }

    It 'has no question that offers to add or sign in to a remote server' {
        $script:Raw | Should -Not -Match '(?i)Read-(ExplicitYes|DefaultYes|Host)[^\r\n]*(Fabric IQ|FabricIQ|Data Warehouse MCP|sqlEndpoint)'
    }

    It 'grants Fabric IQ (read-only) to 038 and 043 only' {
        Get-IdList 'fabricIqMcpAgents' | Should -Be @('fabric-intelligence-ontology-agent', 'monitoring-catalog-operations-agent')
    }

    It 'grants the write-capable Fabric Data Warehouse server to the Warehouse worker alone' {
        $ids = @(Get-IdList 'fabricDataWarehouseMcpAgents')
        $ids | Should -Be @('warehouse-sql-agent')
        $agent = $script:Manifest.agents | Where-Object { $_.id -eq $ids[0] }
        $agent.level | Should -Be 'worker'
        @($agent.tools) | Should -Contain 'execute'
        foreach ($never in 'sql-odbc-data-access-agent', 'monitoring-catalog-operations-agent', 'sql-database-agent', 'data-engineering-team-lead') { $ids | Should -Not -Contain $never }
        $script:Raw | Should -Match ([regex]::Escape("`$mcpServersById[`$mcpAgentId] += @('fabric-dw-global', 'fabric-dw-item')"))
    }

    It 'the grants use the server keys the detection expects' {
        $iq = @(Get-RemoteMcpServers $null) | Where-Object { $_.Key -eq 'fabricIqMcp' }
        $dw = @(Get-RemoteMcpServers $null) | Where-Object { $_.Key -eq 'fabricDataWarehouseMcp' }
        @($iq.GrantKeys) | Should -Be @('FabricIQ')
        @($dw.GrantKeys) | Should -Be @('fabric-dw-global', 'fabric-dw-item')
        $script:Raw | Should -Match ([regex]::Escape("`$mcpServersById[`$mcpAgentId] += 'FabricIQ'"))
    }
}

Describe 'Agents report the state they can prove (TOOL-01, TOOL-02)' {

    It 'the policy skill names the five states in order' {
        @([regex]::Matches($script:Remote, '(?m)^\d\. \*\*([A-Za-z ]+)\*\* - ') | ForEach-Object { $_.Groups[1].Value }) | Should -Be @('Documented', 'Configured', 'Callable', 'Signed in', 'Executed')
        $script:Remote | Should -Match 'Report the highest one you have evidence for, by its name'
        $script:Remote | Should -Match 'Never write "available" or "connected" for a server that is only documented or configured'
        $script:Remote | Should -Match 'A\s+skill that describes an endpoint is state 1'
    }

    It 'the kit does not add, register or sign in to these servers, and agents do not edit mcp.json' {
        $script:Remote | Should -Match 'This kit does not add, register or sign in to them'
        $script:Remote | Should -Match 'do not edit\s+`mcp\.json` yourself'
    }

    It 'states what each server is: release status, read or write, tools and who holds the grant' {
        $script:Remote | Should -Match '(?m)^\| Status \| generally available \| \*\*preview\*\* \|$'
        $script:Remote | Should -Match '(?m)^\| Writes \| no \(read-only\) \| \*\*yes\*\*, whatever the signed-in user may run, including DDL and DML \|$'
        $script:Remote | Should -Match '(?m)^\| Agents holding the grant \| 038 and 043 \| 033 only \|$'
        $script:Remote | Should -Match '(?m)^\| Server key the grants expect \| `FabricIQ` \| `fabric-dw-global`, `fabric-dw-item` \|$'
        foreach ($tool in 'DiscoverArtifacts', 'ResolveFabricItem', 'GetReportMetadata', 'GetSemanticModelSchema', 'ValueSearch', 'ExecuteQuery') { $script:Remote | Should -Match $tool }
        $row = @($script:Remote -split "`n" | Where-Object { $_ -match '^\| Tools \|' })[0]
        $row | Should -Match 'no fixed name: the tool that runs a T-SQL statement is taken from the server''s `tools/list` answer at the step that needs it'
        $script:Remote | Should -Match 'answer in natural language by itself'
        $script:Remote | Should -Match 'ontologies or data agents'
    }

    It 'does not claim a VS Code setup that Microsoft does not document for Fabric IQ' {
        $script:Remote | Should -Match '(?m)^\| Microsoft documents the VS Code setup \| no: the page shows GitHub Copilot CLI'
    }

    It 'every endpoint the skill prints is one the detection recognises' {
        $row = @($script:Remote -split "`n" | Where-Object { $_ -match '^\| Endpoint \|' })[0]
        $urls = @([regex]::Matches($row, '`(https://[^`]+)`') | ForEach-Object { $_.Groups[1].Value })
        $urls.Count | Should -Be 3
        foreach ($u in $urls) {
            @(Get-RemoteMcpServers (New-McpConfig @{ x = @{ type = 'http'; url = $u } }) | Where-Object { $_.Configured }).Count | Should -Be 1 -Because $u
        }
        # The item-scoped form is printed with placeholders; with identifiers filled in it is recognised too.
        $row | Should -Match 'workspaces/<workspace-id>/items/<item-id>/sqlEndpoint'
    }

    It '038 proves the state before relying on Fabric IQ and keeps it apart from Ontology work' {
        $b = Get-AgentBlock 'fabric-intelligence-ontology-agent'
        $b | Should -Match 'tool-status `fabricIqMcp\.configured` says only that an entry exists'
        $b | Should -Match 'callable means its tools are in your tool list in this session'
        $b | Should -Match 'The installer never configures or signs in to these endpoints, and an upstream skill describing one proves nothing about this machine'
        $b | Should -Match 'It has no tool that answers a question'
        $b | Should -Match 'not dashboards, paginated reports, apps, ontologies or data agents'
        $b | Should -Match 'never a substitute for Ontology work'
        $b | Should -Match 'Calling Fabric IQ available, connected or configured without the evidence for that state, or adding it to mcp\.json yourself'
    }

    It 'a fallback belongs to the agent that owns the work: 038 hands the question back instead of answering it another way' {
        $script:Remote | Should -Match 'the documented\s+fallback applies and belongs to the agent that owns that work'
        $script:Remote | Should -Match 'when the fallback is not yours, return NEEDS INPUT so the Master can route it'
        $b = Get-AgentBlock 'fabric-intelligence-ontology-agent'
        $b | Should -Match 'return NEEDS INPUT asking the Master to route the question to 010'
        $b | Should -Match 'you do not answer it from another source yourself'
        $b | Should -Match 'never from KQL or SQL you composed against the underlying source'
        $b | Should -Not -Match 'answer through 010' -Because 'a worker cannot dispatch another team'
    }

    It 'the copilot instructions carry the same rule for every agent' {
        $script:Raw | Should -Match 'Two remote Microsoft-hosted MCP servers are known to the kit but never added or signed\r?\nin to by it'
        $script:Raw | Should -Match 'Agents report the state they can prove - documented, configured, callable,\r?\nsigned in, executed'
    }
}

Describe 'SQL work: the permission class comes before the route (TOOL-03)' {

    It 'defines the five classes S0 to S4 in order' {
        @([regex]::Matches($script:Sql, '(?m)^\| \*\*(S\d) ') | ForEach-Object { $_.Groups[1].Value }) | Should -Be @('S0', 'S1', 'S2', 'S3', 'S4')
    }

    It 'a tool is never permission, and an unclassifiable statement is treated as a change' {
        $script:Sql | Should -Match 'It is never permission to run it'
        $script:Sql | Should -Match 'A statement you cannot classify is S3\. A batch takes the class of its highest statement'
    }

    It 'changes to data or schema need a script the user saw and the approval token' {
        $row = @($script:Sql -split "`n" | Where-Object { $_ -match '^\| \*\*S3 ' })[0]
        foreach ($verb in 'INSERT', 'UPDATE', 'DELETE', 'MERGE', 'CREATE', 'ALTER', 'DROP', 'TRUNCATE') { $row | Should -Match "``$verb``" }
        $row | Should -Match '033 \(Warehouse\), 034 \(SQL database\)'
        $row | Should -Match 'the script shown to the user and the approval token in the WORK ORDER'
        $row | Should -Match 'Destructive statements need their own `APPROVED:<ACTION>:<object>`'
    }

    It 'shows the token for a change, says which statements are destructive, and how an approval names the MCP route' {
        $script:Sql | Should -Match ([regex]::Escape('`APPROVED:INSERT:dbo.Stage`'))
        $script:Sql | Should -Match '`DELETE`, `TRUNCATE`, `DROP` and an `UPDATE` or `MERGE` that\s+overwrites existing rows are destructive: one token per object, never covered by another\s+approval'
        $script:Sql | Should -Match 'To name the route, the approval request you return quotes the server and the tool name\s+exactly as listed'
    }

    It 'administration is not SQL work, and read-only roles stop at S2' {
        (@($script:Sql -split "`n" | Where-Object { $_ -match '^\| \*\*S4 ' })[0]) | Should -Match 'the 040 team \| its own approval; never a side effect of SQL work'
        $script:Sql | Should -Match 'Read-only roles \(043, 063 for analysis\) stop at S2 whatever tool is present'
    }

    It 'orders the routes: sqlcmd, then the Fabric Data Warehouse MCP, then alternates, then definition work' {
        $i1 = $script:Sql.IndexOf('1. **`sqlcmd -G`**'); $i2 = $script:Sql.IndexOf('2. **Fabric Data Warehouse MCP** when it is configured, callable in this session')
        $i3 = $script:Sql.IndexOf('3. **Alternates**'); $i4 = $script:Sql.IndexOf('4. **Otherwise S0**')
        $i1 | Should -BeGreaterThan 0
        $i2 | Should -BeGreaterThan $i1
        $i3 | Should -BeGreaterThan $i2
        $i4 | Should -BeGreaterThan $i3
        $script:Sql | Should -Match 'S3 always runs from a script file'
        $script:Sql | Should -Match 'so the class rules above apply unchanged'
        $script:Sql | Should -Match 'for S3 only when route 1 is impossible and the approval names this route'
        $script:Sql | Should -Match '`az` only supplies a token for a non-Fabric audience; it is not a SQL route by itself'
    }

    It '033 and 034 classify first and need the token for a change; 063 and 043 never change data' {
        foreach ($id in 'warehouse-sql-agent', 'sql-database-agent') {
            $b = Get-AgentBlock $id
            $b | Should -Match 'Classify every statement first \(fabric-cli-policy, SQL work\)'
            $b | Should -Match 'with the approval token in your WORK ORDER'
            $b | Should -Match 'Treating a SQL tool being present as permission to change data'
        }
        (Get-AgentBlock 'warehouse-sql-agent') | Should -Match 'tool-status `fabricDataWarehouseMcp\.configured` alone is not enough'
        (Get-AgentBlock 'warehouse-sql-agent') | Should -Match 'S3 goes through it only when sqlcmd is impossible and the approval names that route'
        (Get-AgentBlock 'sql-odbc-data-access-agent') | Should -Match 'Your SQL stops at class S2'
        (Get-AgentBlock 'sql-odbc-data-access-agent') | Should -Match 'Running a statement that changes data or schema'
        (Get-AgentBlock 'monitoring-catalog-operations-agent') | Should -Match 'SQL stays at class S1 for you'
        foreach ($id in 'sql-database-agent', 'sql-odbc-data-access-agent') { (Get-AgentBlock $id) | Should -Match 'You hold no grant for the Fabric Data Warehouse MCP' }
    }

    It 'the Warehouse MCP tool is discovered at the step that needs it: no tool name is written into the kit' {
        # Neither the published name nor the name the endpoints listed may be relied on anywhere in what the installer writes.
        $script:Raw | Should -Not -Match '(?i)executeSQL|execute_query' -Because 'a hardcoded tool name is the defect'
        $script:Sql | Should -Match '\*\*Discover the tool, never assume it\.\*\*'
        $script:Sql | Should -Match 'read the tools that server lists in\s+this session \(its `tools/list` answer; in VS Code, your tool list for that server\)'
        $script:Sql | Should -Match 'call\s+only a listed tool whose description and input schema say it runs a T-SQL statement'
        $script:Sql | Should -Match 'A name\s+from documentation, a skill or an earlier session is not evidence'
    }

    It 'a missing, renamed or ambiguous Warehouse MCP tool is reported, never guessed' {
        $script:Sql | Should -Match 'No such tool listed: the route is not callable\. Say so and take route 3'
        $script:Sql | Should -Match 'More than one candidate, or a tool whose purpose is unclear: return NEEDS INPUT with the\s+names and descriptions you saw\. Do not pick one, and do not try them in turn'
        $b = Get-AgentBlock 'warehouse-sql-agent'
        $b | Should -Match 'Its tool is discovered, never assumed: read what that server lists at this step and call only a listed tool whose description says it runs a T-SQL statement'
        $b | Should -Match 'none listed means the route is not callable, and more than one candidate or an unclear one is NEEDS INPUT with the names you saw'
        $b | Should -Match 'the tool name as the server listed it'
        $b | Should -Match 'Calling a Fabric Data Warehouse MCP tool by a name you remember or read somewhere instead of one the server listed in this session'
    }

    It 'discovery changes neither the grant nor the classes: 033 alone, by server, S3 still by approval' {
        @(Get-IdList 'fabricDataWarehouseMcpAgents') | Should -Be @('warehouse-sql-agent')
        # The grant names the server, so a renamed tool needs no new grant and no agent gains one.
        $script:Raw | Should -Match ([regex]::Escape("`$mcpServersById[`$mcpAgentId] += @('fabric-dw-global', 'fabric-dw-item')"))
        @((Get-RemoteMcpServers $null | Where-Object { $_.Key -eq 'fabricDataWarehouseMcp' }).GrantKeys) | Should -Be @('fabric-dw-global', 'fabric-dw-item')
        $script:Sql | Should -Match 'so the class rules above apply unchanged'
        $script:Sql | Should -Match 'for S3 only when route 1 is impossible and the approval names this route'
    }

    It 'the agents that may not edit files still cannot: 043 and 063 have no edit capability' {
        foreach ($id in 'monitoring-catalog-operations-agent', 'sql-odbc-data-access-agent') { @(($script:Manifest.agents | Where-Object { $_.id -eq $id }).tools) | Should -Not -Contain 'edit' }
    }
}

Describe 'Tabular Editor 2, Tabular Editor 3 and the te CLI are three products (TOOL-09)' {

    BeforeAll {
        $script:ToolCalls = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Invoke-OptionalToolPrompt', 'Resolve-ToolCommand', 'Set-ToolStatus', 'Install-ViaWingetDownload') }, $true))
    }

    It 'Tabular Editor 2 is the only one offered for install, and only by its own executable names' {
        $prompt = @($script:ToolCalls | Where-Object { $_.GetCommandName() -eq 'Invoke-OptionalToolPrompt' -and $_.Extent.Text -match "-Key 'tabularEditor'" })
        $prompt.Count | Should -Be 1
        $prompt[0].Extent.Text | Should -Match ([regex]::Escape("-Aliases @('TabularEditor.exe','TabularEditor2.exe')"))
        $prompt[0].Extent.Text | Should -Not -Match 'TabularEditor3'
        $prompt[0].Extent.Text | Should -Match '-ProbeVersion \$false' -Because 'a GUI application is never started to read its version'
    }

    It 'never downloads or installs Tabular Editor 3 (paid) or the te CLI (preview)' {
        @($script:ToolCalls | Where-Object { $_.GetCommandName() -eq 'Install-ViaWingetDownload' -and $_.Extent.Text -match 'TabularEditor\.TabularEditor\.3' }).Count | Should -Be 0
        @($script:ToolCalls | Where-Object { $_.GetCommandName() -eq 'Invoke-OptionalToolPrompt' -and $_.Extent.Text -match "-Key '(teCli|tabularEditor3)'" }).Count | Should -Be 0
        $script:Raw | Should -Not -Match 'cdn\.tabulareditor\.com'
    }

    It 'Tabular Editor 3 is detected by its own executable and never inferred from Tabular Editor 2' {
        $te3 = @($script:ToolCalls | Where-Object { $_.GetCommandName() -eq 'Resolve-ToolCommand' -and $_.Extent.Text -match 'TabularEditor3' })
        $te3.Count | Should -Be 1
        $te3[0].Extent.Text | Should -Match ([regex]::Escape("-Aliases @('TabularEditor3.exe')"))
        $te3[0].Extent.Text | Should -Not -Match "'TabularEditor\.exe'|'TabularEditor2\.exe'"
        foreach ($root in [regex]::Matches($te3[0].Extent.Text, '"([^"]+)"')) { $root.Groups[1].Value | Should -Match 'Tabular Editor 3$' -Because 'only folders named for Tabular Editor 3 are searched' }
        foreach ($s in @($script:ToolCalls | Where-Object { $_.GetCommandName() -eq 'Set-ToolStatus' -and $_.Extent.Text -match "-Key 'tabularEditor3'" })) {
            $s.Extent.Text | Should -Match "-InstallMode 'detect'"
            $s.Extent.Text | Should -Not -Match '\$hit\b|\$teHit\b' -Because 'its state never comes from another product''s detection'
        }
    }

    It 'the te CLI has its own key, alias and detect-only entries' {
        $te = @($script:ToolCalls | Where-Object { $_.GetCommandName() -eq 'Resolve-ToolCommand' -and $_.Extent.Text -match "-Aliases @\('te'\)" })
        $te.Count | Should -Be 1
        $sets = @($script:ToolCalls | Where-Object { $_.GetCommandName() -eq 'Set-ToolStatus' -and $_.Extent.Text -match "-Key 'teCli'" })
        $sets.Count | Should -Be 2
        foreach ($s in $sets) { $s.Extent.Text | Should -Match "-InstallMode 'detect'" }
    }

    It 'the update review only ever updates Tabular Editor 2 with a Tabular Editor 2 package' {
        $fn = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ToolUpdateCheck' }, $false) | Select-Object -First 1
        $fn.Extent.Text | Should -Match ([regex]::Escape("-WingetId 'TabularEditor.TabularEditor.2'"))
        $fn.Extent.Text | Should -Not -Match 'TabularEditor\.TabularEditor\.3|teCli|tabularEditor3'
    }

    It 'the validation worker uses each tool only when tool-status reports it' {
        (Get-AgentBlock 'semantic-validation-performance-agent') | Should -Match 'If Tabular Editor 2 is found in tool-status, run BPA against the model; otherwise apply the top BPA rules manually'
        (Get-AgentBlock 'semantic-model-team-lead') | Should -Match 'without them \(tool-status\) the passes are TMDL edits by the owning worker'
    }
}

Describe 'Report tools: pbir stays the house tool; the Microsoft CLI is a detected companion (TOOL-04, TOOL-05)' {

    It 'pbir is offered (never installed unasked) and the Microsoft CLI is only detected' {
        $script:Raw | Should -Match "Invoke-OptionalToolPrompt -Key 'pbir' -Name 'pbir CLI'"
        $script:Raw | Should -Not -Match "Invoke-OptionalToolPrompt -Key 'powerbiReportAuthor'"
        $script:Raw | Should -Not -Match 'npm (i|install)[^\r\n]*powerbi-report-authoring-cli'
    }

    It 'the PBIR edit policy keeps its order and its approval token' {
        $pbir = Get-Section $script:Policy 'Power BI reports (PBIR) - edit policy'
        $pbir | Should -Match '1\. \*\*pbir first\.\*\*'
        $pbir | Should -Match 'Unsupported is not failed'
        $pbir | Should -Match 'APPROVED:PBIR-DIRECT-EDIT:<report>'
        $pbir | Should -Match 'is a companion, not an editor'
        $pbir | Should -Match 'It is never a fallback way to change a report'
    }
}

Describe 'Project Osmos stays behind an explicit request (TOOL-06)' {

    It 'the kit never starts an Osmos task or command by itself' {
        $commands = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match '(?i)osmos' })
        $commands | Should -BeNullOrEmpty
    }

    It 'a run needs the user''s token and Python is only detected for it' {
        (Get-AgentBlock 'data-engineering-team-lead') | Should -Match 'APPROVED:OSMOS-RUN'
        $script:Raw | Should -Match "Set-ToolStatus -Key 'python' -Found \`$true[^\r\n]*\r?\n[^\r\n]*-InstallMode 'detect' -Extra @\{ projectOsmosReady = "
        $script:Raw | Should -Not -Match "Invoke-OptionalToolPrompt -Key 'python'"
    }

    It 'its local sign-in and routing state is ignored by Git and kept out of vendor stashes' {
        (Get-HereString 'gitignoreContent') | Should -Match '(?m)^\.dataprojects/$'
        $script:Raw | Should -Match ([regex]::Escape("-Rules @('.dataprojects/')"))
        $fn = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-VendorClone' }, $false) | Select-Object -First 1
        $text = $fn.Extent.Text
        $exclude = $text.IndexOf("'.git\info\exclude'")
        $stash = $text.IndexOf('stash push')
        $exclude | Should -BeGreaterThan 0
        $stash | Should -BeGreaterThan 0
        $exclude | Should -BeLessThan $stash -Because 'the exclusion is written before anything is stashed'
        $text | Should -Match ([regex]::Escape('".dataprojects/`n"'))
    }
}
