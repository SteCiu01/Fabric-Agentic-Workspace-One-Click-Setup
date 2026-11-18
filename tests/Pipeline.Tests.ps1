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
}

Describe 'Definition round-trip (PIPE-03)' {

    It 'a definition read from another workspace is blocked without the target''s current definition' {
        $r = Get-PdTargeted (Join-Path $script:Fx 'valid-api.json') @{ SourceWorkspaceId = $script:OtherWs }
        $r.Result | Should -Be 'BLOCKED'
        $r.Text | Should -Match 'PD082'
    }

    It 'prints a change plan: activities added, changed and every binding that moves' {
        $p = New-PdVariant 'changed.json' { param($def)
            $def.properties.activities[2].typeProperties.sqlEndpointId = (('5' * 8), ('5' * 4), ('5' * 4), ('5' * 4), ('5' * 12) -join '-')
            $def.properties.activities += [pscustomobject]@{ name = 'Pause'; type = 'Wait'; dependsOn = @(); typeProperties = [pscustomobject]@{ waitTimeInSeconds = 5 } }
        }
        $r = Get-PdTargeted $p @{ CurrentPath = (Join-Path $script:Fx 'valid-api.json') }
        $r.Result | Should -Be 'PASS' -Because $r.Text
        $r.Text | Should -Match 'change plan: 1 added, 0 removed, 1 changed, 6 unchanged; 1 binding change'
        $r.Text | Should -Match '\+ Pause'
        $r.Text | Should -Match '~ Refresh SQL endpoint'
        $r.Text | Should -Match 'binding Refresh SQL endpoint:typeProperties\.sqlEndpointId: 4{8}-\S+ -> 5{8}-'
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

    It 'lists what does not move between environments and the manual work that remains (PIPE-06)' {
        foreach ($s in 'Semantic model \| does not rebind', 'Spark job definition \| does not rebind', 'Connection \| never rebinds', 'sign in again') { $script:Skill | Should -Match $s }
        $script:Skill | Should -Match 'never by the HTTP status'
        $script:Skill | Should -Match 'Number \| not supported in pipelines'
        $script:Skill | Should -Not -Match 'Number \| Double'
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
