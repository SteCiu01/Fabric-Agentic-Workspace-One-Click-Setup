# Pipeline.Tests.ps1
# -------------------------------------------------------------------
# Fabric Data Factory pipelines (v0.9.0). Loads the shipped offline check from its single
# source (the $pipelineCheckScript here-string in the installer) and runs it in-process on
# synthetic definitions. Nothing here calls Fabric; every GUID is a placeholder.
#   - the corrected SQL analytics endpoint refresh contract, with the v0.8.0 template as the
#     negative control (PIPE-01);
#   - workspace portability: foreign and source workspace ids, the all-zero GUID (PIPE-02, PIPE-06);
#   - definition round-trip: trusted unchanged blocks, change plan, binding changes (PIPE-03);
#   - structure, dependencies and expressions that Fabric itself accepts at save time;
#   - the fabric-pipelines skill: evidence class on every row and template, one contract shared
#     with the check, system variables, portability, per-table refresh states (PIPE-04 to PIPE-08);
#   - the fourteen safeguards of agent 036 (PIPE-09).

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:InstallerText = [IO.File]::ReadAllText((Get-InstallerPath))
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('fabric_pd_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Base | Out-Null

    $m = [regex]::Match($script:InstallerText, "(?s)\`$pipelineCheckScript = @'\r?\n(.*?)\r?\n'@")
    $m.Success | Should -BeTrue -Because 'the check has one source: the $pipelineCheckScript here-string'
    $script:CheckSource = $m.Groups[1].Value
    $script:Check = Join-Path $script:Base 'Test-PipelineDefinition.ps1'
    [IO.File]::WriteAllText($script:Check, $script:CheckSource, $script:Utf8)

    $s = [regex]::Match($script:InstallerText, "(?s)\`$pipelineContent = @'\r?\n(.*?)\r?\n'@")
    $s.Success | Should -BeTrue
    $script:Skill = $s.Groups[1].Value -replace "`r`n", "`n"

    $script:Fx = Join-Path $PSScriptRoot 'fixtures\pipelines'
    $script:Valid = [IO.File]::ReadAllText((Join-Path $script:Fx 'valid-api.json'))
    $script:Inventory = Join-Path $script:Fx 'inventory.json'
    # Placeholder ids: one repeated hex digit each.
    $script:Target = ('1' * 8), ('1' * 4), ('1' * 4), ('1' * 4), ('1' * 12) -join '-'
    $script:OtherWs = ('2' * 8), ('2' * 4), ('2' * 4), ('2' * 4), ('2' * 12) -join '-'
    $script:Zero = ('0' * 8), ('0' * 4), ('0' * 4), ('0' * 4), ('0' * 12) -join '-'
    $script:Unknown = ('b' * 8), ('b' * 4), ('b' * 4), ('b' * 4), ('b' * 12) -join '-'

    function Save-PdFile([string]$Name, [string]$Json) {
        $p = Join-Path $script:Base $Name
        [IO.File]::WriteAllText($p, $Json, $script:Utf8)
        return $p
    }
    # A copy of the valid fixture after one change; the scriptblock receives the parsed definition as $def.
    function New-PdVariant([string]$Name, [scriptblock]$Change) {
        $def = $script:Valid | ConvertFrom-Json
        & $Change $def
        return (Save-PdFile $Name (ConvertTo-Json -InputObject $def -Depth 50))
    }
    function Invoke-PdCheck([hashtable]$Params) {
        $lines = @(& $script:Check @Params 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        $result = $null
        foreach ($l in $lines) { if ($l -match 'RESULT: (\w+)') { $result = $Matches[1] } }
        return [pscustomobject]@{ Lines = $lines; Text = ($lines -join "`n"); Exit = $code; Result = $result }
    }
    function Get-PdTargeted([string]$FilePath, [hashtable]$More = @{}) {
        $p = @{ Path = $FilePath; TargetWorkspaceId = $script:Target; InventoryPath = $script:Inventory }
        foreach ($k in $More.Keys) { $p[$k] = $More[$k] }
        return (Invoke-PdCheck $p)
    }
    function Get-PdFolderState([string]$Folder) {
        return @(Get-ChildItem -LiteralPath $Folder -Recurse -File | Sort-Object FullName | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })
    }
}

AfterAll {
    if ($script:Base -and (Test-Path -LiteralPath $script:Base)) { Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Pipeline check: a correct definition' {

    It 'passes with the target workspace and its inventory' {
        $r = Get-PdTargeted (Join-Path $script:Fx 'valid-api.json')
        $r.Result | Should -Be 'PASS' -Because $r.Text
        $r.Exit | Should -Be 0
    }

    It 'is UNCHECKED, not PASS, when the target or the inventory is missing' {
        $r = Invoke-PdCheck @{ Path = (Join-Path $script:Fx 'valid-api.json') }
        $r.Result | Should -Be 'UNCHECKED'
        $r.Exit | Should -Be 3
        $r.Text | Should -Match 'PD002' -Because 'workspace references could not be compared'
        $r.Text | Should -Match 'PD077' -Because 'item and connection references could not be checked'
    }

    It 'reads a saved getDefinition answer and a .DataPipeline folder' {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:Valid))
        $answer = '{"status_code":200,"text":{"definition":{"parts":[{"path":"pipeline-content.json","payload":"' + $b64 + '","payloadType":"InlineBase64"},{"path":".platform","payload":"e30=","payloadType":"InlineBase64"}]}}}'
        (Get-PdTargeted (Save-PdFile 'answer.json' $answer)).Result | Should -Be 'PASS'
        $folder = Join-Path $script:Base 'Sample.DataPipeline'
        New-Item -ItemType Directory -Path $folder | Out-Null
        [IO.File]::WriteAllText((Join-Path $folder 'pipeline-content.json'), $script:Valid, $script:Utf8)
        (Get-PdTargeted $folder).Result | Should -Be 'PASS'
    }

    It 'returns the full result as JSON with every GUID classified' {
        $j = (& $script:Check -Path (Join-Path $script:Fx 'valid-api.json') -TargetWorkspaceId $script:Target -InventoryPath $script:Inventory -AsJson | Out-String) | ConvertFrom-Json
        $j.result | Should -Be 'PASS'
        $j.activities | Should -Be 7
        @($j.bindings | Where-Object { $_.class -eq 'target-workspace' }).Count | Should -Be 1
        @($j.bindings | Where-Object { $_.class -eq 'connection-known' }).Count | Should -Be 1
        @($j.bindings | Where-Object { $_.class -eq 'item-known' }).Count | Should -Be 3
    }

    It 'reads files only: nothing in the fixture folder changes' {
        $before = Get-PdFolderState $script:Fx
        [void](Get-PdTargeted (Join-Path $script:Fx 'valid-api.json') @{ CurrentPath = (Join-Path $script:Fx 'valid-api.json') })
        [void](Get-PdTargeted (Join-Path $script:Fx 'refresh-v080.json'))
        (Get-PdFolderState $script:Fx) | Should -Be $before
    }

    It 'answers with exit code 2 when the input cannot be read' {
        (Invoke-PdCheck @{ Path = (Save-PdFile 'broken.json' '{ not json') }).Exit | Should -Be 2
        (Invoke-PdCheck @{ Path = (Join-Path $script:Base 'absent.json') }).Exit | Should -Be 2
        (Invoke-PdCheck @{ Path = (Save-PdFile 'other.json' '{"name":"not a pipeline"}') }).Exit | Should -Be 2
        (Invoke-PdCheck @{ Path = (Join-Path $script:Fx 'valid-api.json'); TargetWorkspaceId = 'not-a-guid' }).Exit | Should -Be 2
    }

    It 'blocks an activities list that is null (it would empty the deployed pipeline)' {
        $r = Get-PdTargeted (Save-PdFile 'null-activities.json' '{"properties":{"activities":null}}')
        $r.Result | Should -Be 'BLOCKED' -Because $r.Text
        $r.Text | Should -Match 'PD001'
    }

    It 'takes both inventory lists as one comma-separated value, as the documented -File command passes them' {
        $twoInOne = "$($script:Inventory),$($script:Inventory)"
        $r = Invoke-PdCheck @{ Path = (Join-Path $script:Fx 'valid-api.json'); TargetWorkspaceId = $script:Target; InventoryPath = $twoInOne }
        $r.Result | Should -Be 'PASS' -Because $r.Text
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $out = @(& $ps -NoProfile -ExecutionPolicy Bypass -File $script:Check -Path (Join-Path $script:Fx 'valid-api.json') -TargetWorkspaceId $script:Target -InventoryPath $twoInOne 2>&1 | ForEach-Object { "$_" })
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
        ($out -join "`n") | Should -Match 'RESULT: PASS'
    }

    It 'binds no argument by position: a stray value is an error, never a workspace id or a path' {
        { & $script:Check -Path (Join-Path $script:Fx 'valid-api.json') 'stray-value' } | Should -Throw '*positional parameter*'
    }

    It 'the skill and agent 036 show the inventory lists as one quoted value' {
        $script:Skill | Should -Match ([regex]::Escape('-InventoryPath "<items.json>,<connections.json>"'))
        $script:InstallerText | Should -Not -Match ([regex]::Escape('-InventoryPath "<items.json>","<connections.json>"'))
    }

    It 'blocks an id property that holds a placeholder or a name instead of a GUID or an expression: <Case>' -TestCases @(
        @{ Case = 'SQL endpoint id placeholder'; Change = { param($def) $def.properties.activities[2].typeProperties.sqlEndpointId = 'UNRESOLVED-sql-endpoint-id' } }
        @{ Case = 'connection placeholder';      Change = { param($def) $def.properties.activities[2].externalReferences.connection = '<connection-id>' } }
        @{ Case = 'notebook given by name';      Change = { param($def) $def.properties.activities[0].typeProperties.notebookId = 'Load orders notebook' } }
        @{ Case = 'empty workspace id';          Change = { param($def) $def.properties.activities[0].typeProperties.workspaceId = '' } }
    ) {
        param($Case, $Change)
        $r = Get-PdTargeted (New-PdVariant ('placeholder-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json') $Change)
        $r.Result | Should -Be 'BLOCKED' -Because $r.Text
        $r.Text | Should -Match 'PD079'
    }

    It 'NEGATIVE CONTROL: GUIDs and expressions in id properties are not PD079' {
        $r = Get-PdTargeted (Join-Path $script:Fx 'valid-api.json')
        $r.Text | Should -Not -Match 'PD079'
        $e = New-PdVariant 'expr-ids.json' { param($def) $def.properties.activities[2].typeProperties.sqlEndpointId = '@pipeline().libraryVariables.EndpointId' }
        (Get-PdTargeted $e).Text | Should -Not -Match 'PD079'
    }
}

Describe 'SQL analytics endpoint refresh contract (PIPE-01)' {

    It 'NEGATIVE CONTROL: blocks the refresh template shipped with v0.8.0' {
        $r = Get-PdTargeted (Join-Path $script:Fx 'refresh-v080.json')
        $r.Result | Should -Be 'BLOCKED'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'PD021' -Because 'RefreshSQLEndpoint is the wrong identifier'
        $r.Text | Should -Match 'RefreshSqlEndpoint'
    }

    It 'blocks lakehouseId on the corrected activity type' {
        $p = New-PdVariant 'lh.json' { param($def) $def.properties.activities[2].typeProperties | Add-Member -NotePropertyName lakehouseId -NotePropertyValue (('5' * 8), ('5' * 4), ('5' * 4), ('5' * 4), ('5' * 12) -join '-') }
        (Get-PdTargeted $p).Text | Should -Match 'PD031'
    }

    It 'blocks a missing sqlEndpointId and a missing connection' {
        $p = New-PdVariant 'noep.json' { param($def) $def.properties.activities[2].typeProperties.PSObject.Properties.Remove('sqlEndpointId') }
        (Get-PdTargeted $p).Text | Should -Match "PD030.*sqlEndpointId"
        $q = New-PdVariant 'noconn.json' { param($def) $def.properties.activities[2].PSObject.Properties.Remove('externalReferences') }
        (Get-PdTargeted $q).Text | Should -Match 'PD033'
    }

    It 'treats recreateTables = true as destructive until the user approves it' {
        $p = New-PdVariant 'recreate.json' { param($def) $def.properties.activities[2].typeProperties.recreateTables = $true }
        $r = Get-PdTargeted $p
        $r.Result | Should -Be 'BLOCKED'
        $r.Text | Should -Match 'PD032'
        $ok = Get-PdTargeted $p @{ AllowRecreateTables = $true }
        $ok.Result | Should -Be 'PASS'
        $ok.Text | Should -Match '\[warn\] PD032'
    }

    It 'accepts the refresh without recreateTables (the property is optional)' {
        $p = New-PdVariant 'noflag.json' { param($def) $def.properties.activities[2].typeProperties.PSObject.Properties.Remove('recreateTables') }
        (Get-PdTargeted $p).Result | Should -Be 'PASS'
    }

    It 'warns when two refreshes target the same endpoint (lock contention)' {
        $p = New-PdVariant 'twice.json' { param($def)
            $copy = $def.properties.activities[2] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $copy.name = 'Refresh again'
            $copy.dependsOn = @([pscustomobject]@{ activity = 'Refresh SQL endpoint'; dependencyConditions = @('Succeeded') })
            $def.properties.activities += $copy
        }
        $r = Get-PdTargeted $p
        $r.Result | Should -Be 'PASS'
        $r.Text | Should -Match '\[warn\] PD034'
    }
}

Describe 'Workspace portability (PIPE-02, PIPE-06)' {

    It 'NEGATIVE CONTROL: blocks a second workspace''s GUID, and passes once it is the target again' {
        $p = New-PdVariant 'foreign.json' { param($def) $def.properties.activities[0].typeProperties.workspaceId = $script:OtherWs }
        $r = Get-PdTargeted $p
        $r.Result | Should -Be 'BLOCKED'
        $r.Text | Should -Match 'PD071'
        $fixed = New-PdVariant 'foreign-fixed.json' { param($def) $def.properties.activities[0].typeProperties.workspaceId = $script:Target }
        (Get-PdTargeted $fixed).Result | Should -Be 'PASS'
    }

    It 'an approved cross-workspace reference is UNCHECKED, never PASS' {
        $r = Get-PdTargeted (Join-Path $script:Base 'foreign.json') @{ AllowedWorkspaceId = @($script:OtherWs) }
        $r.Result | Should -Be 'UNCHECKED'
        $r.Text | Should -Match 'PD078'
    }

    It 'blocks the source workspace''s GUID wherever it appears, also inside a path' {
        $p = New-PdVariant 'path.json' { param($def) $def.properties.description = "abfss://$($script:OtherWs)@onelake.dfs.fabric.microsoft.com/data" }
        $r = Get-PdTargeted $p @{ SourceWorkspaceId = $script:OtherWs; CurrentPath = (Join-Path $script:Fx 'valid-api.json') }
        $r.Result | Should -Be 'BLOCKED'
        $r.Text | Should -Match 'PD071 properties:description'
    }

    It 'blocks the all-zero GUID in the API format and accepts it in the Git format' {
        $p = New-PdVariant 'zero.json' { param($def) $def.properties.activities[0].typeProperties.workspaceId = $script:Zero }
        $api = Get-PdTargeted $p
        $api.Result | Should -Be 'BLOCKED'
        $api.Text | Should -Match 'PD073'
        $git = Invoke-PdCheck @{ Path = $p; Format = 'Git' }
        $git.Result | Should -Be 'PASS'
        $git.Text | Should -Not -Match 'PD073'
    }

    It 'in the Git format a literal workspace id is a warning (it stays pinned)' {
        $r = Invoke-PdCheck @{ Path = (Join-Path $script:Fx 'valid-api.json'); Format = 'Git' }
        $r.Result | Should -Be 'PASS'
        $r.Text | Should -Match '\[warn\] PD074 Load orders'
    }

    It 'blocks an item id and a connection id that are not in the target inventory' {
        $p = New-PdVariant 'stale-item.json' { param($def) $def.properties.activities[0].typeProperties.notebookId = $script:Unknown }
        (Get-PdTargeted $p).Text | Should -Match 'PD075'
        $q = New-PdVariant 'stale-conn.json' { param($def) $def.properties.activities[2].externalReferences.connection = $script:Unknown }
        (Get-PdTargeted $q).Text | Should -Match 'PD076'
    }

    It 'blocks a second workspace''s GUID inside an Expression object or an expression, and passes the target there' {
        $obj = New-PdVariant 'foreign-exprobj.json' { param($def) $def.properties.activities[2].typeProperties.workspaceId = [pscustomobject]@{ value = $script:OtherWs; type = 'Expression' } }
        $r = Get-PdTargeted $obj
        $r.Result | Should -Be 'BLOCKED' -Because $r.Text
        $r.Text | Should -Match 'PD071 Refresh SQL endpoint:typeProperties\.workspaceId\.value'
        $expr = New-PdVariant 'foreign-concat.json' { param($def) $def.properties.activities[0].typeProperties.workspaceId = "@concat('', '$($script:OtherWs)')" }
        $e = Get-PdTargeted $expr
        $e.Result | Should -Be 'BLOCKED' -Because $e.Text
        $e.Text | Should -Match 'PD071 Load orders:typeProperties\.workspaceId'
        $own = New-PdVariant 'target-exprobj.json' { param($def) $def.properties.activities[2].typeProperties.workspaceId = [pscustomobject]@{ value = $script:Target; type = 'Expression' } }
        (Get-PdTargeted $own).Result | Should -Be 'PASS'
    }
}

Describe 'References are checked for identity and item type' {

    BeforeAll {
        function New-PdId([string]$Digit) { return (($Digit * 8), ($Digit * 4), ($Digit * 4), ($Digit * 4), ($Digit * 12) -join '-') }
        $script:Id = @{
            Notebook = New-PdId '6'; SQLEndpoint = New-PdId '4'; Lakehouse = New-PdId '5'; VariableLibrary = New-PdId 'a'; Connection = New-PdId '3'
            DataPipeline = New-PdId '7'; Dataflow = New-PdId '8'; SemanticModel = New-PdId '9'; CopyJob = New-PdId 'c'; SparkJobDefinition = New-PdId 'd'
            Environment = New-PdId 'e'; UserDataFunction = New-PdId 'f'; Warehouse = New-PdId '2'
        }
        # An inventory as the two list calls answer: items carry "type", connections carry "connectivityType".
        function New-PdInventory([string]$Name, [string[]]$Without = @(), [string[]]$Untyped = @(), [hashtable]$Top = @{}) {
            $entries = @()
            foreach ($t in @($script:Id.Keys | Sort-Object)) {
                if ($Without -contains $t) { continue }
                if ($Untyped -contains $t) { $entries += [ordered]@{ id = $script:Id[$t]; displayName = "$t one" } }
                elseif ($t -eq 'Connection') { $entries += [ordered]@{ id = $script:Id[$t]; displayName = 'Refresh connection'; connectivityType = 'ShareableCloud'; connectionDetails = [ordered]@{ type = 'FabricSqlEndpointMetadata'; path = 'x' } } }
                else { $entries += [ordered]@{ id = $script:Id[$t]; type = $t; displayName = "$t one"; workspaceId = $script:Target } }
            }
            $doc = [ordered]@{ value = $entries }
            foreach ($k in $Top.Keys) { $doc[$k] = $Top[$k] }
            return (Save-PdFile $Name (ConvertTo-Json -InputObject $doc -Depth 6))
        }
        # One activity per kind of reference the check knows. -Set replaces one id: 'activity name|property path' = value.
        function New-PdReferences([string]$Name, [hashtable]$Set = @{}) {
            $ws = $script:Target; $id = $script:Id
            $policy = [ordered]@{ timeout = '0.01:00:00'; retry = 0; retryIntervalInSeconds = 30 }
            $acts = @(
                [ordered]@{ name = 'Notebook'; type = 'TridentNotebook'; dependsOn = @(); typeProperties = [ordered]@{ notebookId = $id.Notebook; workspaceId = $ws } }
                [ordered]@{ name = 'Refresh'; type = 'RefreshSqlEndpoint'; dependsOn = @(); typeProperties = [ordered]@{ workspaceId = $ws; sqlEndpointId = $id.SQLEndpoint; recreateTables = $false }; externalReferences = [ordered]@{ connection = $id.Connection } }
                [ordered]@{ name = 'Invoke'; type = 'InvokePipeline'; dependsOn = @(); typeProperties = [ordered]@{ workspaceId = $ws; pipelineId = $id.DataPipeline; waitOnCompletion = $true }; externalReferences = [ordered]@{ connection = $id.Connection } }
                [ordered]@{ name = 'Execute'; type = 'ExecutePipeline'; dependsOn = @(); typeProperties = [ordered]@{ pipeline = [ordered]@{ referenceName = $id.DataPipeline; type = 'PipelineReference' }; waitOnCompletion = $true } }
                [ordered]@{ name = 'Dataflow'; type = 'RefreshDataFlow'; dependsOn = @(); policy = $policy; typeProperties = [ordered]@{ dataflowId = $id.Dataflow; workspaceId = $ws } }
                [ordered]@{ name = 'Spark'; type = 'SparkJobDefinition'; dependsOn = @(); typeProperties = [ordered]@{ sparkJobDefinitionId = $id.SparkJobDefinition; workspaceId = $ws } }
                [ordered]@{ name = 'CopyJob'; type = 'InvokeCopyJob'; dependsOn = @(); typeProperties = [ordered]@{ copyJobId = $id.CopyJob; workspaceId = $ws } }
                [ordered]@{ name = 'Model'; type = 'PBISemanticModelRefresh'; dependsOn = @(); typeProperties = [ordered]@{ method = 'POST'; groupId = $ws; datasetId = $id.SemanticModel; type = 'Full'; operationType = 'RefreshDataset' }; externalReferences = [ordered]@{ connection = $id.Connection } }
                [ordered]@{ name = 'Lookup'; type = 'Lookup'; dependsOn = @(); typeProperties = [ordered]@{ source = [ordered]@{ type = 'LakehouseTableSource' }; firstRowOnly = $true
                        datasetSettings = [ordered]@{ type = 'LakehouseTable'; typeProperties = [ordered]@{ table = 'config' }; linkedService = [ordered]@{ name = 'lh'; properties = [ordered]@{ type = 'Lakehouse'; typeProperties = [ordered]@{ workspaceId = $ws; artifactId = $id.Lakehouse; rootFolder = 'Tables' } } } } } }
            )
            $def = [ordered]@{ properties = [ordered]@{ activities = $acts; libraryVariables = [ordered]@{ schema = [ordered]@{ libraryName = 'Config'; libraryId = $id.VariableLibrary; variableName = 'schema'; type = 'String' } } } }
            foreach ($k in $Set.Keys) {
                $actName, $path = $k -split '\|', 2
                $node = if ($actName -eq 'properties') { $def.properties } else { @($acts | Where-Object { $_.name -eq $actName })[0] }
                $parts = @($path -split '\.')
                for ($i = 0; $i -lt $parts.Count - 1; $i++) { $node = $node[$parts[$i]] }
                $node[$parts[-1]] = $Set[$k]
            }
            return (Save-PdFile $Name (ConvertTo-Json -InputObject $def -Depth 30))
        }
        function Invoke-PdRefs([string]$Definition, [string]$InventoryFile) { return (Invoke-PdCheck @{ Path = $Definition; TargetWorkspaceId = $script:Target; InventoryPath = $InventoryFile }) }
        $script:FullInventory = New-PdInventory 'inv-full.json'
    }

    It 'passes when every reference names an item of the expected type, and says what the inventory held' {
        $r = Invoke-PdRefs (New-PdReferences 'refs-ok.json') $script:FullInventory
        $r.Result | Should -Be 'PASS' -Because $r.Text
        $r.Text | Should -Match 'inventory: 12 item\(s\) with a type, 0 without, 1 connection\(s\)'
        $j = (& $script:Check -Path (Join-Path $script:Base 'refs-ok.json') -TargetWorkspaceId $script:Target -InventoryPath $script:FullInventory -AsJson | Out-String) | ConvertFrom-Json
        $endpoint = @($j.bindings | Where-Object { $_.where -eq 'Refresh:typeProperties.sqlEndpointId' })[0]
        $endpoint.class | Should -Be 'item-known'
        $endpoint.itemType | Should -Be 'SQLEndpoint'
        $endpoint.expectedType | Should -Be 'SQLEndpoint'
    }

    It 'NEGATIVE CONTROL: the lakehouse id as sqlEndpointId is blocked although it is an item of the workspace' {
        $r = Invoke-PdRefs (New-PdReferences 'refs-lh-as-endpoint.json' @{ 'Refresh|typeProperties.sqlEndpointId' = $script:Id.Lakehouse }) $script:FullInventory
        $r.Result | Should -Be 'BLOCKED' -Because $r.Text
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'PD084 Refresh:typeProperties\.sqlEndpointId'
        $r.Text | Should -Match 'is a Lakehouse, not a SQLEndpoint'
    }

    It 'blocks an existing item of the wrong type under <Where> (expected <Expected>)' -TestCases @(
        @{ Where = 'Notebook|typeProperties.notebookId'; Expected = 'Notebook' }
        @{ Where = 'Invoke|typeProperties.pipelineId'; Expected = 'DataPipeline' }
        @{ Where = 'Execute|typeProperties.pipeline.referenceName'; Expected = 'DataPipeline' }
        @{ Where = 'Dataflow|typeProperties.dataflowId'; Expected = 'Dataflow' }
        @{ Where = 'Spark|typeProperties.sparkJobDefinitionId'; Expected = 'SparkJobDefinition' }
        @{ Where = 'CopyJob|typeProperties.copyJobId'; Expected = 'CopyJob' }
        @{ Where = 'Model|typeProperties.datasetId'; Expected = 'SemanticModel' }
        @{ Where = 'Lookup|typeProperties.datasetSettings.linkedService.properties.typeProperties.artifactId'; Expected = 'Lakehouse' }
        @{ Where = 'properties|libraryVariables.schema.libraryId'; Expected = 'VariableLibrary' }
        @{ Where = 'Notebook|typeProperties.environmentId'; Expected = 'Environment' }
        @{ Where = 'Notebook|typeProperties.functionSetId'; Expected = 'UserDataFunction' }
        @{ Where = 'Notebook|typeProperties.lakehouseId'; Expected = 'Lakehouse' }
    ) {
        param($Where, $Expected)
        $r = Invoke-PdRefs (New-PdReferences 'refs-wrong.json' @{ $Where = $script:Id.Warehouse }) $script:FullInventory
        $r.Result | Should -Be 'BLOCKED' -Because $r.Text
        $r.Text | Should -Match "PD084 .*is a Warehouse, not a $Expected"
        @($r.Lines | Where-Object { $_ -match '\[block\]' }).Count | Should -Be 1 -Because 'only the changed reference is wrong'
    }

    It 'blocks an item where a connection belongs, and a connection where an item belongs' {
        $a = Invoke-PdRefs (New-PdReferences 'refs-item-as-conn.json' @{ 'Refresh|externalReferences.connection' = $script:Id.SQLEndpoint }) $script:FullInventory
        $a.Result | Should -Be 'BLOCKED' -Because $a.Text
        $a.Text | Should -Match 'PD084 Refresh:externalReferences\.connection .*is a SQLEndpoint item, not a connection'
        $b = Invoke-PdRefs (New-PdReferences 'refs-conn-as-item.json' @{ 'Refresh|typeProperties.sqlEndpointId' = $script:Id.Connection }) $script:FullInventory
        $b.Result | Should -Be 'BLOCKED' -Because $b.Text
        $b.Text | Should -Match 'PD084 Refresh:typeProperties\.sqlEndpointId .*is a connection, not a SQLEndpoint'
    }

    It 'is UNCHECKED when the inventory entry has no type: the type is never guessed from the id' {
        $inv = New-PdInventory 'inv-untyped-endpoint.json' -Untyped @('SQLEndpoint')
        $r = Invoke-PdRefs (Join-Path $script:Base 'refs-ok.json') $inv
        $r.Result | Should -Be 'UNCHECKED' -Because $r.Text
        $r.Exit | Should -Be 3
        $r.Text | Should -Match '\[unchecked\] PD085 Refresh:typeProperties\.sqlEndpointId'
        $r.Text | Should -Match 'inventory: 11 item\(s\) with a type, 1 without'
        # The same id shape with every type removed: nothing passes on the shape of a GUID.
        $none = New-PdInventory 'inv-untyped-all.json' -Untyped @($script:Id.Keys)
        $all = Invoke-PdRefs (Join-Path $script:Base 'refs-ok.json') $none
        $all.Result | Should -Be 'UNCHECKED'
        @($all.Lines | Where-Object { $_ -match 'PD085' }).Count | Should -Be 13 -Because 'ten item references and three connection references'
    }

    It 'blocks an id that is in no list (sqlEndpointId and connection)' {
        $r = Invoke-PdRefs (New-PdReferences 'refs-missing.json' @{ 'Refresh|typeProperties.sqlEndpointId' = $script:Unknown }) $script:FullInventory
        $r.Result | Should -Be 'BLOCKED'
        $r.Text | Should -Match 'PD075 Refresh:typeProperties\.sqlEndpointId'
        $c = Invoke-PdRefs (New-PdReferences 'refs-missing-conn.json' @{ 'Refresh|externalReferences.connection' = $script:Unknown }) $script:FullInventory
        $c.Text | Should -Match 'PD076 Refresh:externalReferences\.connection'
    }

    It 'a partial inventory is UNCHECKED, not a stale reference: <Case>' -TestCases @(
        @{ Case = 'the item list without the connection list'; Without = @('Connection'); Top = @{}; Rule = 'PD087'; Text = 'no connection list' }
        @{ Case = 'the connection list without the item list'; Without = @('Notebook', 'SQLEndpoint', 'Lakehouse', 'VariableLibrary', 'DataPipeline', 'Dataflow', 'SemanticModel', 'CopyJob', 'SparkJobDefinition', 'Environment', 'UserDataFunction', 'Warehouse'); Top = @{}; Rule = 'PD087'; Text = 'no item list' }
        @{ Case = 'one page of a longer item list'; Without = @('SQLEndpoint'); Top = @{ continuationToken = 'next-page' }; Rule = 'PD087'; Text = 'more pages' }
    ) {
        param($Case, $Without, $Top, $Rule, $Text)
        $inv = New-PdInventory 'inv-partial.json' -Without $Without -Top $Top
        $r = Invoke-PdRefs (Join-Path $script:Base 'refs-ok.json') $inv
        $r.Result | Should -Be 'UNCHECKED' -Because $r.Text
        $r.Exit | Should -Be 3
        $r.Text | Should -Match "\[unchecked\] $Rule .*$Text"
        $r.Text | Should -Not -Match 'PD075|PD076'
    }

    It 'an inventory that cannot be read is exit code 2, never a result' {
        $r = Invoke-PdRefs (Join-Path $script:Base 'refs-ok.json') (Join-Path $script:Base 'no-such-inventory.json')
        $r.Exit | Should -Be 2
        $r.Result | Should -BeNullOrEmpty
        $r.Text | Should -Match 'inventory file not found'
    }

    It 'is UNCHECKED for a reference whose expected type the contract does not define (artifactId under another linked service)' {
        $p = New-PdReferences 'refs-other-ls.json' @{ 'Lookup|typeProperties.datasetSettings.linkedService.properties.type' = 'SomeOtherStore'; 'Lookup|typeProperties.datasetSettings.linkedService.properties.typeProperties.artifactId' = $script:Id.Warehouse }
        $r = Invoke-PdRefs $p $script:FullInventory
        $r.Result | Should -Be 'UNCHECKED' -Because $r.Text
        $r.Text | Should -Match '\[unchecked\] PD086 Lookup:.*artifactId .*Warehouse'
    }

    It 'still passes a literal id written in upper case' {
        $r = Invoke-PdRefs (New-PdReferences 'refs-variant.json' @{ 'CopyJob|typeProperties.copyJobId' = $script:Id.CopyJob.ToUpperInvariant() }) $script:FullInventory
        $r.Result | Should -Be 'PASS' -Because $r.Text
    }

    It 'the three outcomes: verified literal PASS, wrong-type literal BLOCKED, dynamic @pipeline() reference UNCHECKED' {
        $pass = Invoke-PdRefs (Join-Path $script:Base 'refs-ok.json') $script:FullInventory
        $pass.Result | Should -Be 'PASS' -Because $pass.Text
        $pass.Exit | Should -Be 0
        $pass.Text | Should -Not -Match 'PD088'
        $blocked = Invoke-PdRefs (New-PdReferences 'refs-three-blocked.json' @{ 'Refresh|typeProperties.sqlEndpointId' = $script:Id.Lakehouse }) $script:FullInventory
        $blocked.Result | Should -Be 'BLOCKED' -Because $blocked.Text
        $blocked.Exit | Should -Be 1
        $blocked.Text | Should -Match '\[block\] PD084 Refresh:typeProperties\.sqlEndpointId'
        $dynamic = Invoke-PdRefs (New-PdReferences 'refs-three-dynamic.json' @{ 'Refresh|typeProperties.sqlEndpointId' = '@pipeline().parameters.EndpointId'; 'properties|parameters' = [ordered]@{ EndpointId = [ordered]@{ type = 'string' } } }) $script:FullInventory
        $dynamic.Result | Should -Be 'UNCHECKED' -Because $dynamic.Text
        $dynamic.Exit | Should -Be 3
        $dynamic.Text | Should -Match '\[unchecked\] PD088 Refresh:typeProperties\.sqlEndpointId .*SQLEndpoint'
        $dynamic.Text | Should -Not -Match '\[block\]'
    }

    It 'a dynamic reference is UNCHECKED, never PASS: <Case>' -TestCases @(
        @{ Case = 'an item id from a Variable Library value'; Where = 'Refresh:typeProperties\.sqlEndpointId'; Set = { @{ 'Refresh|typeProperties.sqlEndpointId' = '@pipeline().libraryVariables.schema' } } }
        @{ Case = 'an item id as an Expression object'; Where = 'Refresh:typeProperties\.sqlEndpointId\.value'; Set = { @{ 'Refresh|typeProperties.sqlEndpointId' = [ordered]@{ value = '@pipeline().parameters.EndpointId'; type = 'Expression' }; 'properties|parameters' = [ordered]@{ EndpointId = [ordered]@{ type = 'string' } } } } }
        @{ Case = 'an expression that holds a GUID of the right type'; Where = 'Notebook:typeProperties\.notebookId'; Set = { @{ 'Notebook|typeProperties.notebookId' = "@concat('', '$($script:Id.Notebook)')" } } }
        @{ Case = 'an interpolated string'; Where = 'CopyJob:typeProperties\.copyJobId'; Set = { @{ 'CopyJob|typeProperties.copyJobId' = '@{pipeline().libraryVariables.schema}' } } }
        @{ Case = 'a connection'; Where = 'Refresh:externalReferences\.connection'; Set = { @{ 'Refresh|externalReferences.connection' = '@pipeline().libraryVariables.schema' } } }
        @{ Case = 'the pipeline of ExecutePipeline'; Where = 'Execute:typeProperties\.pipeline\.referenceName'; Set = { @{ 'Execute|typeProperties.pipeline.referenceName' = '@pipeline().libraryVariables.schema' } } }
        @{ Case = 'a workspace other than the running one'; Where = 'Notebook:typeProperties\.workspaceId'; Set = { @{ 'Notebook|typeProperties.workspaceId' = '@pipeline().libraryVariables.schema' } } }
    ) {
        param($Case, $Where, $Set)
        $r = Invoke-PdRefs (New-PdReferences 'refs-dynamic.json' (& $Set)) $script:FullInventory
        $r.Result | Should -Be 'UNCHECKED' -Because $r.Text
        $r.Exit | Should -Be 3
        $r.Text | Should -Match "\[unchecked\] PD088 $Where "
        @($r.Lines | Where-Object { $_ -match 'PD088' }).Count | Should -Be 1 -Because 'one line per dynamic reference'
        $r.Text | Should -Not -Match '\[block\]'
    }

    It 'the same dynamic reference is UNCHECKED without an inventory and in the Git format too' {
        $p = Join-Path $script:Base 'refs-three-dynamic.json'
        $none = Invoke-PdCheck @{ Path = $p; TargetWorkspaceId = $script:Target }
        $none.Result | Should -Be 'UNCHECKED'
        $none.Text | Should -Match '\[unchecked\] PD088 Refresh:typeProperties\.sqlEndpointId'
        $git = Invoke-PdCheck @{ Path = $p; Format = 'Git' }
        $git.Result | Should -Be 'UNCHECKED' -Because $git.Text
        $git.Text | Should -Match '\[unchecked\] PD088 Refresh:typeProperties\.sqlEndpointId'
    }

    It 'a wrong-type literal beside a dynamic reference is BLOCKED, and both are listed' {
        $p = New-PdReferences 'refs-blocked-and-dynamic.json' @{ 'Refresh|typeProperties.sqlEndpointId' = $script:Id.Lakehouse; 'Notebook|typeProperties.notebookId' = '@pipeline().libraryVariables.schema' }
        $r = Invoke-PdRefs $p $script:FullInventory
        $r.Result | Should -Be 'BLOCKED' -Because $r.Text
        $r.Exit | Should -Be 1
        $r.Text | Should -Match '\[block\] PD084 Refresh:typeProperties\.sqlEndpointId'
        $r.Text | Should -Match '\[unchecked\] PD088 Notebook:typeProperties\.notebookId'
        $r.Text | Should -Match 'RESULT: BLOCKED \(1 blocking, 1 unchecked'
    }

    It 'NEGATIVE CONTROL: the running workspace (@pipeline().DataFactory) is not a dynamic reference to verify' {
        foreach ($form in '@pipeline().DataFactory', '@{pipeline().DataFactory}') {
            $r = Invoke-PdRefs (New-PdReferences 'refs-datafactory.json' @{ 'Notebook|typeProperties.workspaceId' = $form }) $script:FullInventory
            $r.Result | Should -Be 'PASS' -Because $r.Text
            $r.Text | Should -Not -Match 'PD088'
        }
        $obj = Invoke-PdRefs (New-PdReferences 'refs-datafactory-obj.json' @{ 'Notebook|typeProperties.workspaceId' = [ordered]@{ value = '@pipeline().DataFactory'; type = 'Expression' } }) $script:FullInventory
        $obj.Result | Should -Be 'PASS' -Because $obj.Text
    }

    It 'a dynamic reference in an unchanged activity of the current definition is not reported again' {
        $p = Join-Path $script:Base 'refs-three-dynamic.json'
        $r = Invoke-PdCheck @{ Path = $p; CurrentPath = $p; TargetWorkspaceId = $script:Target; InventoryPath = $script:FullInventory }
        $r.Text | Should -Not -Match 'PD088 Refresh'
    }

    It 'reads the type from a saved API answer and compares it without regard to letter case' {
        $entries = @(([IO.File]::ReadAllText($script:FullInventory) | ConvertFrom-Json).value)
        foreach ($e in $entries) { if ($e.PSObject.Properties['type']) { $e.type = $e.type.ToLowerInvariant() } }
        $wrapped = Save-PdFile 'inv-wrapped.json' (ConvertTo-Json -InputObject ([ordered]@{ status_code = 200; text = [ordered]@{ value = $entries } }) -Depth 8)
        (Invoke-PdRefs (Join-Path $script:Base 'refs-ok.json') $wrapped).Result | Should -Be 'PASS'
    }

    It 'an unchanged activity of the current definition is not re-checked (the change plan is the place for it)' {
        $bad = New-PdReferences 'refs-current-bad.json' @{ 'Refresh|typeProperties.sqlEndpointId' = $script:Id.Lakehouse }
        $r = Invoke-PdCheck @{ Path = $bad; CurrentPath = $bad; TargetWorkspaceId = $script:Target; InventoryPath = $script:FullInventory }
        $r.Text | Should -Not -Match 'PD084'
    }

    It 'checks a literal id inside an Expression object like the property it belongs to' {
        $p = New-PdReferences 'refs-exprobj-literal.json' @{ 'Refresh|typeProperties.sqlEndpointId' = [ordered]@{ value = $script:Id.Lakehouse; type = 'Expression' } }
        $r = Invoke-PdRefs $p $script:FullInventory
        $r.Result | Should -Be 'BLOCKED' -Because $r.Text
        $r.Text | Should -Match 'PD084 Refresh:typeProperties\.sqlEndpointId\.value .*is a Lakehouse, not a SQLEndpoint'
    }

    It 'lists every dynamic reference with its place, and the result line counts them' {
        $p = New-PdReferences 'refs-expr-count.json' @{ 'Refresh|typeProperties.sqlEndpointId' = '@pipeline().libraryVariables.schema'; 'Notebook|typeProperties.notebookId' = '@pipeline().libraryVariables.schema' }
        $r = Invoke-PdRefs $p $script:FullInventory
        $r.Result | Should -Be 'UNCHECKED' -Because $r.Text
        @($r.Lines | Where-Object { $_ -match '\[unchecked\] PD088' }).Count | Should -Be 2
        $r.Text | Should -Not -Match '\[info\] PD088'
        $r.Text | Should -Match 'RESULT: UNCHECKED \(0 blocking, 2 unchecked'
    }
}

Describe 'Definition round-trip (PIPE-03)' {

    It 'a definition read from another workspace is blocked without the target''s current definition' {
        $r = Get-PdTargeted (Join-Path $script:Fx 'valid-api.json') @{ SourceWorkspaceId = $script:OtherWs }
        $r.Result | Should -Be 'BLOCKED'
        $r.Text | Should -Match 'PD082'
    }

    It 'prints a change plan: activities added, changed and every binding that moves' {
        $p = New-PdVariant 'changed.json' { param($def)
            $def.properties.activities[2].typeProperties.sqlEndpointId = (('7' * 8), ('7' * 4), ('7' * 4), ('7' * 4), ('7' * 12) -join '-')
            $def.properties.activities += [pscustomobject]@{ name = 'Pause'; type = 'Wait'; dependsOn = @(); typeProperties = [pscustomobject]@{ waitTimeInSeconds = 5 } }
        }
        $r = Get-PdTargeted $p @{ CurrentPath = (Join-Path $script:Fx 'valid-api.json') }
        $r.Result | Should -Be 'PASS' -Because $r.Text
        $r.Text | Should -Match 'change plan: 1 added, 0 removed, 1 changed, 6 unchanged; 1 binding change'
        $r.Text | Should -Match '\+ Pause'
        $r.Text | Should -Match '~ Refresh SQL endpoint'
        $r.Text | Should -Match 'binding Refresh SQL endpoint:typeProperties\.sqlEndpointId: 4{8}-\S+ -> 7{8}-'
    }

    It 'reports an activity that disappears from the current definition' {
        $p = New-PdVariant 'removed.json' { param($def)
            $def.properties.activities = @($def.properties.activities | Where-Object { $_.name -ne 'Any table processed' })
        }
        $r = Get-PdTargeted $p @{ CurrentPath = (Join-Path $script:Fx 'valid-api.json') }
        $r.Text | Should -Match 'PD083.*Any table processed'
        $r.Text | Should -Match '- Any table processed'
    }

    It 'trusts a block that is identical to the target''s current definition, and only that' {
        $existing = New-PdVariant 'existing.json' { param($def) $def.properties.activities[0].type = 'LakehouseMaintenance' }
        (Get-PdTargeted $existing).Text | Should -Match 'PD023' -Because 'as a new block the type is unverified'
        (Get-PdTargeted $existing @{ CurrentPath = $existing }).Result | Should -Be 'PASS' -Because 'unchanged from the target it is existing state'
        $touched = New-PdVariant 'touched.json' { param($def) $def.properties.activities[0].type = 'LakehouseMaintenance'; $def.properties.activities[0].typeProperties.notebookId = $script:Unknown }
        (Get-PdTargeted $touched @{ CurrentPath = $existing }).Result | Should -Be 'BLOCKED' -Because 'a changed block is checked again'
    }
}

Describe 'Activity types, structure and dependencies' {

    It 'blocks an unverified type until the user confirms it' {
        $p = New-PdVariant 'unverified.json' { param($def) $def.properties.activities[0].type = 'LakehouseMaintenance' }
        (Get-PdTargeted $p).Text | Should -Match 'PD023'
        $ok = Get-PdTargeted $p @{ AllowActivityType = @('LakehouseMaintenance') }
        $ok.Result | Should -Be 'PASS'
        $ok.Text | Should -Match 'PD024'
    }

    It 'blocks a type that differs from the contract only by letter case' {
        $p = New-PdVariant 'case.json' { param($def) $def.properties.activities[0].type = 'tridentnotebook' }
        (Get-PdTargeted $p).Text | Should -Match "PD022.*TridentNotebook"
    }

    It 'blocks every identifier of the removed templates and names the replacement' -ForEach @(
        @{ Old = 'RefreshSQLEndpoint'; New = 'RefreshSqlEndpoint' }, @{ Old = 'DataflowGen2'; New = 'RefreshDataFlow' }
        @{ Old = 'KQL'; New = 'KustoQueryLanguage' }, @{ Old = 'Webhook'; New = 'WebHook' }
        @{ Old = 'StoredProcedure'; New = 'SqlServerStoredProcedure' }, @{ Old = 'SQLScript'; New = 'Script' }
        @{ Old = 'HDInsightActivity'; New = 'AzureHDInsight' }, @{ Old = 'FunctionsActivity'; New = 'AzureFunction' }
        @{ Old = 'CopyJob'; New = 'InvokeCopyJob' }, @{ Old = 'AzureBatch'; New = 'Custom' }
        @{ Old = 'AzureDatabricks'; New = 'DatabricksNotebook' }, @{ Old = 'Deactivate'; New = 'onInactiveMarkAs' }
    ) {
        $p = New-PdVariant "old-$Old.json" { param($def) $def.properties.activities[0].type = $Old }
        $r = Get-PdTargeted $p
        $r.Result | Should -Be 'BLOCKED'
        $r.Text | Should -Match ('PD021.*' + [regex]::Escape($New))
    }

    It 'blocks a missing required property' {
        $p = New-PdVariant 'required.json' { param($def) $def.properties.activities[0].typeProperties.PSObject.Properties.Remove('notebookId') }
        (Get-PdTargeted $p).Text | Should -Match 'PD030.*notebookId'
    }

    It 'blocks a dependsOn that names a missing activity (Fabric saves it)' {
        $p = New-PdVariant 'dep.json' { param($def) $def.properties.activities[1].dependsOn[0].activity = 'Nowhere' }
        (Get-PdTargeted $p).Text | Should -Match 'PD042'
    }

    It 'blocks a dependsOn across lists' {
        $p = New-PdVariant 'scope.json' { param($def) $def.properties.activities[1].typeProperties.activities[0].dependsOn = @([pscustomobject]@{ activity = 'Load orders'; dependencyConditions = @('Succeeded') }) }
        (Get-PdTargeted $p).Text | Should -Match 'PD042 For each table/activities/Collect table'
    }

    It 'blocks a dependency cycle and an unknown condition' {
        $p = New-PdVariant 'cycle.json' { param($def) $def.properties.activities[0].dependsOn = @([pscustomobject]@{ activity = 'Any table processed'; dependencyConditions = @('Succeeded') }) }
        (Get-PdTargeted $p).Text | Should -Match 'PD044'
        $q = New-PdVariant 'cond.json' { param($def) $def.properties.activities[1].dependsOn[0].dependencyConditions = @('Done') }
        (Get-PdTargeted $q).Text | Should -Match 'PD043'
    }

    It 'blocks a name used twice in one list' {
        $p = New-PdVariant 'twice-name.json' { param($def) $def.properties.activities[1].name = 'Load orders'; $def.properties.activities[2].dependsOn[0].activity = 'Load orders' }
        (Get-PdTargeted $p).Text | Should -Match '\[block\] PD011'
    }

    It 'accepts a deactivated activity and rejects an unknown state' {
        $p = New-PdVariant 'inactive.json' { param($def) $def.properties.activities[0] | Add-Member -NotePropertyName state -NotePropertyValue 'Inactive'; $def.properties.activities[0] | Add-Member -NotePropertyName onInactiveMarkAs -NotePropertyValue 'Succeeded' }
        (Get-PdTargeted $p).Result | Should -Be 'PASS'
        $q = New-PdVariant 'state.json' { param($def) $def.properties.activities[0] | Add-Member -NotePropertyName state -NotePropertyValue 'Off' }
        (Get-PdTargeted $q).Text | Should -Match 'PD012'
    }
}

Describe 'Expressions, variables and credentials' {

    It 'blocks an undeclared parameter, variable and library variable' {
        $p = New-PdVariant 'param.json' { param($def) $def.properties.parameters.PSObject.Properties.Remove('RunDate') }
        (Get-PdTargeted $p).Text | Should -Match "PD053.*RunDate"
        $q = New-PdVariant 'var.json' { param($def) $def.properties.variables.PSObject.Properties.Remove('Processed') }
        (Get-PdTargeted $q).Text | Should -Match "PD054.*Processed"
        $l = New-PdVariant 'lib.json' { param($def) $def.properties.PSObject.Properties.Remove('libraryVariables') }
        (Get-PdTargeted $l).Text | Should -Match "PD055.*target_schema"
    }

    It 'blocks a Variable Library type a pipeline cannot use (Number)' {
        $p = New-PdVariant 'number.json' { param($def) $def.properties.libraryVariables.target_schema.type = 'Double' }
        (Get-PdTargeted $p).Text | Should -Match 'PD060.*Number is not supported'
    }

    It 'blocks activity() for a missing activity, pipeline().variables and globalParameters' {
        $p = New-PdVariant 'act.json' { param($def) $def.properties.activities[3].typeProperties.expression.value = "@equals(activity('Gone').output.x, 1)" }
        (Get-PdTargeted $p).Text | Should -Match "PD056.*Gone"
        $q = New-PdVariant 'pv.json' { param($def) $def.properties.activities[3].typeProperties.expression.value = '@pipeline().variables.Status' }
        (Get-PdTargeted $q).Text | Should -Match 'PD051'
        $g = New-PdVariant 'gp.json' { param($def) $def.properties.activities[3].typeProperties.expression.value = '@pipeline().globalParameters.x' }
        (Get-PdTargeted $g).Text | Should -Match 'PD052'
    }

    It 'blocks an expression object without a value' {
        $p = New-PdVariant 'expr.json' { param($def) $def.properties.activities[3].typeProperties.expression.PSObject.Properties.Remove('value') }
        (Get-PdTargeted $p).Text | Should -Match 'PD050'
    }

    It 'points out that pipeline().Pipeline is an id, without blocking' {
        $p = New-PdVariant 'pipeline-id.json' { param($def) $def.properties.activities[3].typeProperties.ifTrueActivities[0].typeProperties.value.value = '@pipeline().Pipeline' }
        $r = Get-PdTargeted $p
        $r.Result | Should -Be 'PASS'
        $r.Text | Should -Match '\[warn\] PD057'
    }

    It 'blocks a credential-like value and never prints it' {
        $secret = 'S3' + 'cr3t-' + ('x' * 12)   # assembled at run time
        $p = New-PdVariant 'secret.json' { param($def) $def.properties.activities[0].typeProperties | Add-Member -NotePropertyName password -NotePropertyValue $secret }
        $r = Get-PdTargeted $p
        $r.Result | Should -Be 'BLOCKED'
        $r.Text | Should -Match 'PD090'
        $r.Text | Should -Not -Match ([regex]::Escape($secret))
        $j = (& $script:Check -Path $p -TargetWorkspaceId $script:Target -InventoryPath $script:Inventory -AsJson | Out-String)
        $j | Should -Not -Match ([regex]::Escape($secret)) -Because 'the JSON result must not carry the value either'
    }
}

Describe 'fabric-pipelines skill: evidence and contract (PIPE-04 to PIPE-08)' {

    BeforeAll {
        # Matrix rows: | Activity | `type` | required | connection | rebinds | save check | evidence |
        $script:MatrixRows = @([regex]::Matches($script:Skill, '(?m)^\| ([^|\n]+) \| ([^|\n]+) \| ([^|\n]+) \| ([^|\n]+) \| ([^|\n]+) \| ([^|\n]+) \| (RUN|DOC|PARTIAL|UNVERIFIED) \|$') | ForEach-Object {
                [pscustomobject]@{ Activity = $_.Groups[1].Value.Trim(); Types = @([regex]::Matches($_.Groups[2].Value, '`([A-Za-z0-9]+)`') | ForEach-Object { $_.Groups[1].Value }); SaveCheck = $_.Groups[6].Value.Trim(); Evidence = $_.Groups[7].Value }
            })
        $script:ContractTypes = @([regex]::Matches($script:CheckSource, "(?m)^\s+'([A-Za-z0-9]+)\|[^']*\|(none|optional|required)'\s*$") | ForEach-Object { $_.Groups[1].Value })
    }

    It 'states its review date, its sources and the five evidence classes' {
        $script:Skill | Should -Match 'Last reviewed against Microsoft Learn\*\*: \d{4}-\d{2}-\d{2}'
        foreach ($class in 'RUN', 'DOC', 'PARTIAL', 'UNVERIFIED', 'REMOVED') { $script:Skill | Should -Match ("(?m)^\| $class \| ") }
        $script:Skill | Should -Match 'No template is verified against JSON produced by the Fabric editor'
    }

    It 'gives every matrix row an evidence class' {
        $script:MatrixRows.Count | Should -BeGreaterThan 35
        $all = @([regex]::Matches(([regex]::Match($script:Skill, '(?s)## Activity contract matrix.*?### Earlier templates')).Value, '(?m)^\| [^-|\n][^\n]*\|$'))
        ($all.Count - 1) | Should -Be $script:MatrixRows.Count -Because 'every row after the header must end in a known class'
    }

    It 'shares one contract with the check: the same activity types, no more and no fewer' {
        $skillTypes = @($script:MatrixRows | Where-Object { $_.Evidence -ne 'UNVERIFIED' } | ForEach-Object { $_.Types } | Sort-Object -Unique)
        $script:ContractTypes.Count | Should -BeGreaterThan 30
        (Compare-Object $skillTypes ($script:ContractTypes | Sort-Object -Unique)) | Should -BeNullOrEmpty
    }

    It 'gives no type identifier to an UNVERIFIED activity' {
        foreach ($row in @($script:MatrixRows | Where-Object { $_.Evidence -eq 'UNVERIFIED' })) { $row.Types | Should -BeNullOrEmpty -Because "$($row.Activity) has no published JSON" }
        @($script:MatrixRows | Where-Object { $_.Evidence -eq 'UNVERIFIED' }).Count | Should -Be 5
    }

    It 'records what the save check said and warns that "accepted" proves nothing' {
        ($script:MatrixRows | Where-Object { $_.Activity -eq 'Refresh SQL analytics endpoint' }).SaveCheck | Should -Be '`SqlEndpointId`'
        ($script:MatrixRows | Where-Object { $_.Activity -eq 'HDInsight' }).SaveCheck | Should -Be '`ExternalReferences`'
        $script:Skill | Should -Match 'so `accepted` proves nothing'
        # The check requires what Fabric itself named as required.
        $script:CheckSource | Should -Match "'AzureHDInsight\|hdiActivityType\|required'"
        $script:CheckSource | Should -Match "'PBISemanticModelRefresh\|datasetId\|required'"
    }

    It 'covers the activities named in the review (PIPE-04)' {
        foreach ($t in 'InvokePipeline', 'ExecutePipeline', 'RefreshDataFlow', 'Office365Email', 'RefreshSqlEndpoint') { $script:ContractTypes | Should -Contain $t }
        foreach ($a in 'Business action \(preview\)', 'Fabric actions \(preview\)') { $script:Skill | Should -Match "(?m)^\| $a \| not published " }
    }

    It 'carries a class on every template heading' {
        $templates = [regex]::Match($script:Skill, '(?s)## Templates: DOC and PARTIAL.*?\n---').Value
        $heads = @([regex]::Matches($templates, '(?m)^### (.+)$') | ForEach-Object { $_.Groups[1].Value })
        $heads.Count | Should -BeGreaterThan 8
        foreach ($h in $heads) { $h | Should -Match '\((DOC|PARTIAL)(, (DOC|PARTIAL))*\)$' }
        $script:Skill | Should -Match '(?m)^## Templates: RUN$'
    }

    It 'every JSON block is valid JSON and uses only contract types' {
        $blocks = @([regex]::Matches($script:Skill, '(?s)```json\n(.*?)\n```') | ForEach-Object { $_.Groups[1].Value })
        $blocks.Count | Should -BeGreaterThan 20
        foreach ($b in $blocks) {
            $o = $null
            { $script:o = $b | ConvertFrom-Json } | Should -Not -Throw -Because $b
            foreach ($t in @([regex]::Matches($b, '"name":\s*"[^"]+",\s*"type":\s*"([A-Za-z0-9]+)"') | ForEach-Object { $_.Groups[1].Value })) {
                $script:ContractTypes | Should -Contain $t -Because 'a template must not use a type the check would block'
            }
        }
    }

    It 'the refresh template uses the endpoint id, a connection and no lakehouse id (PIPE-01)' {
        $t = [regex]::Match($script:Skill, '(?s)### Refresh SQL analytics endpoint: RefreshSqlEndpoint\n```json\n(.*?)\n```').Groups[1].Value | ConvertFrom-Json
        $t.type | Should -BeExactly 'RefreshSqlEndpoint'
        $t.typeProperties.sqlEndpointId | Should -Not -BeNullOrEmpty
        $t.typeProperties.workspaceId.value | Should -Be '@pipeline().DataFactory'
        $t.typeProperties.recreateTables | Should -BeFalse
        $t.externalReferences.connection | Should -Not -BeNullOrEmpty
        $t.typeProperties.PSObject.Properties['lakehouseId'] | Should -BeNullOrEmpty
        $script:Skill | Should -Match 'not of the lakehouse'
    }

    It 'documents the workaround as interim and the Git behaviour as unverified (PIPE-02)' {
        $script:Skill | Should -Match 'It is an \*\*interim\*\* choice'
        $script:Skill | Should -Match '(?m)^\| all-zero GUID in a Git-connected folder \|.*\| UNVERIFIED \|$'
        $script:Skill | Should -Match 'error 4301'
    }

    It 'explains per-table states and sequencing (PIPE-07)' {
        foreach ($s in '`Success`', '`NotRun`', '`Failure`') { $script:Skill | Should -Match ([regex]::Escape($s)) }
        $script:Skill | Should -Match 'These are not the activity status'
        $script:Skill | Should -Match '(?i)one\*\* refresh at the end'
        $script:Skill | Should -Match 'LockConflict'
    }

    It 'lists the system variables with what they return (PIPE-05)' {
        foreach ($v in 'DataFactory', 'Pipeline', 'PipelineName', 'RunId', 'GroupId', 'TriggerTime') { $script:Skill | Should -Match ('(?m)^\| `@pipeline\(\)\.' + $v + '`') }
        $script:Skill | Should -Match '(?m)^\| `@pipeline\(\)\.DataFactory` \| the \*\*id of the workspace\*\*'
        $script:Skill | Should -Match '`GroupId` is \*\*not\*\* the workspace id'
    }

    It 'gives <Variable> exactly this meaning: <Meaning> (PIPE-05)' -TestCases @(
        @{ Variable = 'DataFactory'; Meaning = 'the **id of the workspace** the run is in'; Evidence = 'the workspace GUID' },
        @{ Variable = 'Pipeline'; Meaning = 'the **id of the pipeline**'; Evidence = 'the pipeline item GUID' },
        @{ Variable = 'PipelineName'; Meaning = 'the name of the pipeline'; Evidence = 'the display name' },
        @{ Variable = 'RunId'; Meaning = 'the id of this run'; Evidence = 'the job instance GUID' },
        @{ Variable = 'GroupId'; Meaning = 'the id of the group the run belongs to'; Evidence = 'equal to `RunId`' },
        @{ Variable = 'TriggerTime'; Meaning = 'when the trigger fired, UTC, ISO 8601'; Evidence = '`2000-01-01T00:00:00.0000000Z` form' }
    ) {
        param($Variable, $Meaning, $Evidence)
        $row = @($script:Skill -split "`n" | Where-Object { $_.StartsWith('| `@pipeline().' + $Variable + '` |') })
        $row.Count | Should -Be 1 -Because "$Variable has exactly one row"
        $cells = @($row[0].Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        $cells[1] | Should -BeExactly $Meaning
        $cells[2] | Should -BeExactly $Evidence
    }

    It 'never lets the pipeline id pass for its name (PIPE-05)' {
        $script:Skill | Should -Match '`Pipeline` is an id, not a name\. For a message use `PipelineName`\.'
        # The row of the id must not describe a name, and the row of the name must not describe an id.
        (@($script:Skill -split "`n" | Where-Object { $_.StartsWith('| `@pipeline().Pipeline` |') })[0]) | Should -Not -Match '(?i)\bname\b'
        (@($script:Skill -split "`n" | Where-Object { $_.StartsWith('| `@pipeline().PipelineName` |') })[0]) | Should -Not -Match '(?i)\bid\b|GUID'
        $script:Skill | Should -Match 'do not build on it' -Because 'an undocumented variable that happened to work is not offered as a contract'
    }

    It 'lists what does not move between environments and the manual work that remains (PIPE-06)' {
        foreach ($s in 'Semantic model \| does not rebind', 'Spark job definition \| does not rebind', 'Connection \| never rebinds', 'sign in again') { $script:Skill | Should -Match $s }
        $script:Skill | Should -Match 'never by the HTTP status'
        $script:Skill | Should -Match 'Number \| not supported in pipelines'
        $script:Skill | Should -Not -Match 'Number \| Double'
    }

    It 'names every binding that stays open after a promotion: <Binding> (PIPE-06)' -TestCases @(
        @{ Binding = 'Outlook and Teams sign-in' }, @{ Binding = 'connection' }, @{ Binding = 'dataflow references' },
        @{ Binding = 'semantic model, Spark job definition and warehouse endpoint' }, @{ Binding = 'every cross-workspace reference' },
        @{ Binding = 'the active value set of the Variable Library' }
    ) {
        param($Binding)
        $line = [regex]::Match($script:Skill, '(?s)- \*\*Manual work that remains after every promotion\*\*:.*?(?=\n- \*\*)').Value
        $line | Should -Not -BeNullOrEmpty
        ($line -replace '\s+', ' ') | Should -Match ([regex]::Escape($Binding))
    }

    It 'treats a dataflow reference as not portable and a foreign-workspace item as never rebinding (PIPE-06)' {
        $script:Skill | Should -Match '(?m)^\| Dataflow Gen2 \| documented both ways \| treat as not portable; verify after deployment \|$'
        $script:Skill | Should -Match '(?m)^\| Any item of \*\*another\*\* workspace \| never rebinds \|'
        $script:Skill | Should -Match '`libraryId` is the id of the Variable Library \*\*item of that workspace\*\*'
        $script:Skill | Should -Match 'The value used at run time is the one of the active value set of the workspace'
    }

    It 'states that no dedicated upstream binding skill exists and substitutes none (PIPE-10)' {
        $p = ([regex]::Match($script:Skill, '(?s)- \*\*Upstream skills \(catalog checked \d{4}-\d{2}-\d{2}\)\.\*\*.*?(?=\n\n|\n---)').Value) -replace '\s+', ' '
        $p | Should -Not -BeNullOrEmpty
        $p | Should -Match 'has no skill dedicated to rebinding a pipeline''s item references across workspaces'
        foreach ($related in 'variable-library-cli', 'deployment-pipelines-authoring-cli', 'git-integration-operations-cli', 'pipeline-migration') { $p | Should -Match ([regex]::Escape("``$related``")) }
        $p | Should -Match 'none is used in place of a binding skill'
        $p | Should -Match 'Capability Maintenance maps it through the normal skill compatibility process'
        # The related skills really are in the recorded upstream catalog; a binding skill is not.
        $snapshot = @((Get-SkillCatalogSnapshot).skills | ForEach-Object { ($_ -split '/')[-1] })
        foreach ($related in 'variable-library-cli', 'deployment-pipelines-authoring-cli', 'git-integration-operations-cli', 'pipeline-migration') { $snapshot | Should -Contain $related }
        @($snapshot | Where-Object { $_ -match '(?i)bind|rebind' }) | Should -BeNullOrEmpty -Because 'when such a skill appears upstream this statement and the mapping must be revisited'
    }

    It 'no longer teaches the removed templates as templates' {
        $outsideAudit = $script:Skill -replace '(?s)### Earlier templates of this skill \(audit\).*?\n---', ''
        foreach ($old in 'DataflowGen2', 'HDInsightActivity', 'FunctionsActivity', 'AzureDatabricks', 'SQLScript', 'LakehouseMaintenance') { $outsideAudit | Should -Not -Match ('"type":\s*"' + $old + '"') }
        $outsideAudit | Should -Not -Match '"lakehouseId"'
    }
}

Describe 'Agent 036 deployment safeguards (PIPE-09)' {

    BeforeAll {
        $script:Agent036 = [regex]::Match($script:InstallerText, "(?s)'pipeline-orchestration-agent' = @\{.*?\n    \}").Value
    }

    It 'lists the fourteen safeguards in order, then the fail-closed rule' {
        $labels = @([regex]::Matches($script:Agent036, "(?m)^\s+'\*\*([^*]+)\.\*\*") | ForEach-Object { $_.Groups[1].Value })
        $labels | Should -Be @('Target', 'Inspect first', 'Compare environments', 'Foreign workspace ids', 'Stale references', 'Schema and dependencies', 'No round-trip', 'Change plan and recovery', 'Approval', 'Scope', 'Read back', 'Validate bindings', 'Run', 'Evidence', 'Fail closed')
        $script:Agent036 | Should -Match "'\*\*Local authoring\*\* \(no workspace is touched\)"
    }

    It 'names the check, the approval token and the limits of an HTTP success' {
        $script:Agent036 | Should -Match 'Test-PipelineDefinition\.ps1'
        $script:Agent036 | Should -Match 'APPROVED:DEPLOY:<pipeline name>'
        $script:Agent036 | Should -Match 'NEEDS INPUT or NEEDS APPROVAL'
        $script:Agent036 | Should -Match 'NOT EXECUTED'
        $script:Agent036 | Should -Match 'A successful save is never reported as a working pipeline'
    }

    It 'never saves a BLOCKED result, and an UNCHECKED or unrun check only with the user''s decision on each point' {
        $script:Agent036 | Should -Match '`RESULT: PASS` with the token allows the save\. BLOCKED -> fix or ask; it is never saved'
        $script:Agent036 | Should -Not -Match 'Only `RESULT: PASS` allows the save' -Because 'an UNCHECKED result may be saved after the user decided on each unchecked point'
        $script:Agent036 | Should -Match 'UNCHECKED -> never saved on your own decision: say what could not be checked and return NEEDS INPUT'
        $script:Agent036 | Should -Match 'A check that could not be run at all counts as UNCHECKED for every point; without its change plan you return NEEDS INPUT, not NEEDS APPROVAL'
        $script:Agent036 | Should -Match 'a BLOCKED result was never saved, and an UNCHECKED result \(or a check that could not be run\) was not saved unless the WORK ORDER carried the user''''s decision on each unchecked point'
        # The skill states the same rule, so the two texts cannot be read against each other.
        $script:Skill | Should -Match '`RESULT: PASS` allows a save without a question to the user\. `BLOCKED` is never saved\.\s+`UNCHECKED`, or a check that could not be run, is saved only after the user decided on\s+each point that could not be checked'
    }

    It 'keeps the agent''s ownership and tools unchanged' {
        $a = @((Get-AgentManifest).agents | Where-Object { $_.id -eq 'pipeline-orchestration-agent' })
        $a.Count | Should -Be 1
        $a[0].tools | Should -Be @('read', 'search', 'execute', 'edit')
        $a[0].allowedChildren | Should -BeNullOrEmpty
    }
}

Describe 'Installer wiring of the pipeline check' {

    It 'emits the check as a managed file next to the other helpers' {
        $script:InstallerText | Should -Match "(?m)^\s+'\.github\\agent-docs\\Test-PipelineDefinition\.ps1',\s*$"
        $script:InstallerText | Should -Match 'Write-ManagedFile "\$rootPath\\\.github\\agent-docs\\Test-PipelineDefinition\.ps1" \$pipelineCheckScript'
    }

    It 'the check parses and declares no network or write operation' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:CheckSource, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        foreach ($forbidden in 'Invoke-RestMethod', 'Invoke-WebRequest', 'Net.WebClient', 'WriteAllText', 'WriteAllLines', 'Set-Content', 'Add-Content', 'Out-File', 'Remove-Item', 'New-Item', 'Start-Process') {
            $script:CheckSource | Should -Not -Match ([regex]::Escape($forbidden)) -Because 'the check reads files only'
        }
    }
}
