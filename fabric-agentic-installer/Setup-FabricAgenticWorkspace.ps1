<#
.SYNOPSIS
    Fabric Agentic Workspace  -- One-click bootstrap
.DESCRIPTION
    Run this script to set up a fully configured Fabric agentic workspace
    with a Fabric Master Agent, specialist agents, Microsoft & data-goblin skills,
    custom TMDL and Pipeline skills, and copilot instructions.
    Once complete it opens the folder in VS Code  -- select Fabric Master Agent
    from the Copilot Chat dropdown and type anything to start.
.NOTES
    Requirements: git, VS Code 1.117.0+ with GitHub Copilot, az CLI (recommended)
    This script is the source of truth for managed agents and skills.
    It will overwrite its own files but leave unmanaged files untouched.
#>

# Keep the window open on any error so the user can read it
$ErrorActionPreference = 'Stop'
trap {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    Read-Host "`nPress Enter to close"
    exit 1
}

# =====================================================================
# PACKAGE MANIFEST  -- files managed by this installer
# These will be created or overwritten. All other files are left alone.
# =====================================================================
$managedAgents = @(
    '1-fabric-workspace-master-agent.agent.md',
    '2-fabric-skills-maintainer.agent.md',
    '3-semantic-model-agent.agent.md',
    '4-fabric-data-engineer.agent.md',
    '5-fabric-admin.agent.md',
    '6-fabric-app-dev.agent.md',
    '7-fabric-reports-agent.agent.md',
    '8-fabric-pipelines-agent.agent.md'
)
$managedSkills = @(
    'fabric-tmdl',
    'fabric-pipelines'
)
$managedConfigs = @(
    '.github\copilot-instructions.md',
    'AGENTS.md',
    '.gitignore',
    '.vscode\tasks.json',
    '.vscode\settings.json'
)

# -- Helper: step banner ------------------------------------------------
function Show-Step ([int]$Number, [int]$Total, [string]$Title) {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  STEP $Number of $Total - $Title" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
}

# -- Helper: safe file write (creates parent dirs) ----------------------
function Write-ManagedFile ([string]$Path, [string]$Content) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -Path $Path -Value $Content -Encoding UTF8
}

$totalSteps = 8

# =====================================================================
# STEP 1  -- Workspace folder configuration
# =====================================================================
Show-Step 1 $totalSteps "Workspace Folder"

Write-Host "  Welcome to the Fabric Agentic Workspace setup!" -ForegroundColor White
Write-Host ""
Write-Host "  This will configure your local folder with agents and skills" -ForegroundColor White
Write-Host "  for AI-assisted Fabric development in VS Code." -ForegroundColor White
Write-Host ""
Write-Host "  Do you already have a local folder where you work with Fabric?" -ForegroundColor Yellow
Write-Host "  (e.g. where you sync your Semantic Models, Notebooks, Pipelines)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [1] Yes  -- I have an existing folder (I will provide the path)" -ForegroundColor White
Write-Host "  [2] No   -- Create a new folder for me" -ForegroundColor White
Write-Host ""
$choice = Read-Host "  Enter 1 or 2"

if ($choice -eq '1') {
    $rootPath = Read-Host "`n  Enter the full path to your existing Fabric folder"
    $rootPath = $rootPath.Trim('"').Trim("'").TrimEnd('\')
    if (-not (Test-Path $rootPath)) {
        Write-Host "`n  That folder does not exist: $rootPath" -ForegroundColor Red
        $create = Read-Host "  Create it? (y/n)"
        if ($create -ne 'y') { Write-Host "  Aborted."; exit 0 }
        New-Item -ItemType Directory -Path $rootPath -Force | Out-Null
        Write-Host "  Created: $rootPath" -ForegroundColor Green
    } else {
        Write-Host "`n  Using existing folder: $rootPath" -ForegroundColor Green
    }
} else {
    $defaultParent = $env:USERPROFILE
    $defaultName = "Fabric Workspaces"
    Write-Host ""
    Write-Host "  New folder will be created at: $defaultParent\" -ForegroundColor DarkGray
    $folderName = Read-Host "  Enter a name (default: $defaultName)"
    if ([string]::IsNullOrWhiteSpace($folderName)) { $folderName = $defaultName }
    $rootPath = Join-Path $defaultParent $folderName
    if (-not (Test-Path $rootPath)) {
        New-Item -ItemType Directory -Path $rootPath -Force | Out-Null
        Write-Host "  Created: $rootPath" -ForegroundColor Green
    } else {
        Write-Host "  Folder already exists: $rootPath" -ForegroundColor Yellow
    }
}

Write-Host "`n  Workspace target: $rootPath" -ForegroundColor White

# =====================================================================
# STEP 2  -- Prerequisites check
# =====================================================================
Show-Step 2 $totalSteps "Checking Prerequisites"

$missing = @()
$warnings = @()

# Git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $missing += "git (https://git-scm.com)"
} else {
    Write-Host "  git: found" -ForegroundColor Green
}

# VS Code
$vscodeCmd = $null
$userVsCode         = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"
$userVsCodeInsiders = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd"

if (Test-Path $userVsCode) {
    $vscodeCmd = $userVsCode
} elseif (Test-Path $userVsCodeInsiders) {
    $vscodeCmd = $userVsCodeInsiders
} elseif (Get-Command code -ErrorAction SilentlyContinue) {
    $vscodeCmd = 'code'
} elseif (Get-Command code-insiders -ErrorAction SilentlyContinue) {
    $vscodeCmd = 'code-insiders'
} else {
    $missing += "VS Code 1.117.0+ (https://code.visualstudio.com)"
}

$minVsCodeVersion = [version]"1.117.0"
if ($vscodeCmd) {
    try {
        $vscodeVersionStr = (& $vscodeCmd --version 2>$null | Select-Object -First 1).Trim()
        $vscodeVersion = [version]$vscodeVersionStr
        if ($vscodeVersion -lt $minVsCodeVersion) {
            $missing += "VS Code $minVsCodeVersion+ (you have $vscodeVersionStr)"
        } else {
            Write-Host "  VS Code: $vscodeVersionStr" -ForegroundColor Green
        }
    } catch {
        $warnings += "Could not determine VS Code version"
    }
}

# az CLI (soft check -- offer to install if missing)
# az CLI (optional -- useful for Fabric REST API calls but not required)
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "  az CLI: not found (optional)" -ForegroundColor Yellow
    Write-Host "         Some agents can use az rest for Fabric API calls." -ForegroundColor DarkGray
    Write-Host "         Install later if needed: https://aka.ms/installazurecli" -ForegroundColor DarkGray
} else {
    Write-Host "  az CLI: found" -ForegroundColor Green
}

if ($missing.Count -gt 0) {
    Write-Host "`n  Missing prerequisites:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host "`n  Install the above and re-run this script."
    exit 1
}
if ($warnings.Count -gt 0) {
    Write-Host ""
    $warnings | ForEach-Object { Write-Host "  WARNING: $_" -ForegroundColor Yellow }
}

Write-Host "`n  All prerequisites OK." -ForegroundColor Green
Read-Host "`n  Press Enter to continue..."

# =====================================================================
# STEP 3  -- Create folder structure
# =====================================================================
Show-Step 3 $totalSteps "Creating Folder Structure"

$dirs = @(
    "$rootPath\.github\agents"
    "$rootPath\.github\skills\fabric-tmdl"
    "$rootPath\.github\skills\fabric-pipelines"
    "$rootPath\.vscode"
)
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Host "  Created: $($d.Replace($rootPath, '.'))"
    }
}

Write-Host "`n  Folder structure ready." -ForegroundColor Green

# =====================================================================
# STEP 4  -- Clone skill repositories
# =====================================================================
Show-Step 4 $totalSteps "Cloning Skill Repositories"

Push-Location $rootPath
try {
    # -- microsoft/skills-for-fabric ----------------------------------
    if (-not (Test-Path "$rootPath\skills-for-fabric")) {
        Write-Host "  Cloning microsoft/skills-for-fabric..." -ForegroundColor White
        try {
            & git clone https://github.com/microsoft/skills-for-fabric.git skills-for-fabric 2>&1 | Out-Null
        } catch { }
        if (Test-Path "$rootPath\skills-for-fabric\skills") {
            Write-Host "  skills-for-fabric cloned." -ForegroundColor Green
        } else {
            Write-Host "  Warning: could not clone skills-for-fabric. Clone manually later." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  skills-for-fabric/ already exists  -- pulling latest..." -ForegroundColor Green
        try { & git -C "$rootPath\skills-for-fabric" pull --ff-only 2>&1 | Out-Null } catch { }
    }

    # -- data-goblin/power-bi-agentic-development ---------------------
    if (-not (Test-Path "$rootPath\power-bi-agentic-development")) {
        Write-Host "  Cloning data-goblin/power-bi-agentic-development..." -ForegroundColor White
        try {
            & git clone https://github.com/data-goblin/power-bi-agentic-development.git power-bi-agentic-development 2>&1 | Out-Null
        } catch { }
        if (Test-Path "$rootPath\power-bi-agentic-development\plugins") {
            Write-Host "  power-bi-agentic-development cloned." -ForegroundColor Green
        } else {
            Write-Host "  Warning: could not clone power-bi-agentic-development. Clone manually later." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  power-bi-agentic-development/ already exists  -- pulling latest..." -ForegroundColor Green
        try { & git -C "$rootPath\power-bi-agentic-development" pull --ff-only 2>&1 | Out-Null } catch { }
    }
} finally {
    Pop-Location
}

Read-Host "`n  Press Enter to continue..."

# =====================================================================
# STEP 5  -- Embed custom skills
# =====================================================================
Show-Step 5 $totalSteps "Writing Custom Skills"

# ----- fabric-tmdl/SKILL.md ------------------------------------------
$tmdlSkillPath = "$rootPath\.github\skills\fabric-tmdl\SKILL.md"
Write-Host "  Writing fabric-tmdl skill..."
$tmdlContent = @'
---
name: fabric-tmdl
description: "Use when: editing or creating TMDL files, DAX measures, columns, relationships, partitions, or parameters in Microsoft Fabric Semantic Models, Power BI datasets, or Direct Lake models. Covers TMDL syntax, indentation, lineageTag rules, and Tabular Object Model (TOM) structure."
---

# Fabric TMDL Skill

## When to use
- User asks to add, edit, or review measures, tables, columns, relationships, or partitions in `.tmdl` files
- User asks about TMDL syntax or Fabric Semantic Model structure
- User mentions DAX measures, calculated tables, parameters, or Direct Lake partitions

---

## Folder structure

Every Semantic Model in Git integration follows this exact layout:

```
<Name>.SemanticModel/
    definition/
        database.tmdl          <- compatibilityLevel only (always 1604)
        model.tmdl             <- culture, collation, annotations, ref table list
        expressions.tmdl       <- M/Power Query data source expressions
        relationships.tmdl     <- ALL relationships (never inside table files)
        tables/
            <TableName>.tmdl   <- one file per table
        cultures/
            en-US.tmdl         <- linguistic metadata
    definition.pbism           <- connection metadata (don't edit)
```

### database.tmdl
```tmdl
database
	compatibilityLevel: 1604
```
Always `1604`. Nothing else in this file.

### model.tmdl
```tmdl
model Model
	culture: en-US
	collation: Latin1_General_100_BIN2_UTF8
	defaultPowerBIDataSourceVersion: powerBI_V3
	sourceQueryCulture: en-US
	dataAccessOptions
		legacyRedirects
		returnErrorValuesAsNull

annotation __PBI_TimeIntelligenceEnabled = 0

annotation PBI_QueryOrder = ["DatabaseQuery"]

annotation PBI_ProTooling = ["WebModelingEdit","DaxQueryView_Desktop","TMDLView_Desktop","RemoteModeling","TMDL-Extension"]

ref table 'Table Name Here'

ref cultureInfo en-US
```
- Every table in the model MUST have a `ref table` entry here
- **WARNING**: When adding a new table, you MUST also add a `ref table 'New Table Name'` line to `model.tmdl`

### expressions.tmdl (Fabric Warehouse/Lakehouse connection)
```tmdl
expression DatabaseQuery =
		let
		    database = Sql.Database("<endpoint>", "<database-id>")
		in
		    database
	lineageTag: <guid>

	annotation PBI_IncludeFutureArtifacts = False
```

### cultures/en-US.tmdl
```tmdl
cultureInfo en-US

	linguisticMetadata =
			{
			  "Version": "1.0.0",
			  "Language": "en-US"
			}
		contentType: json
```

---

## Indentation rules -- CRITICAL

- **Always use TABS, never spaces** for indentation
- TMDL is indentation-based (like Python) -- no semicolons, no braces
- Nesting level defines hierarchy:
  - Level 0: `table`, `relationship`, `expression`, `model`, `database`, `cultureInfo`
  - Level 1 (1 tab): properties of the above (`column`, `measure`, `partition`, `lineageTag`, etc.)
  - Level 2 (2 tabs): properties of columns/measures/partitions
  - Level 3 (3 tabs): nested content inside partitions, DAX inside triple-backticks

---

## Measures

### Multi-line DAX (most common pattern)
Multi-line DAX is enclosed in **triple backticks** after `=`:

```tmdl
	measure 'My Measure Name' = ```
			VAR x = SUM('FactTable'[Amount])

			RETURN
			IF(x > 0, x, BLANK())
			
			```
		formatString: \$#,0;(\$#,0);\$#,0
		displayFolder: Category Name
		lineageTag: <guid>

		changedProperty = DisplayFolder

		changedProperty = FormatString

		annotation PBI_FormatHint = {"currencyCulture":"en-US"}
```

**Rules for triple-backtick DAX:**
- Opening ` ``` ` goes on the SAME line as `=`, with a space before it
- DAX body is indented with **3 tabs**
- Closing ` ``` ` is on its own line at 3 tabs
- After closing backticks, properties are at **2 tabs**

### Simple one-line DAX
```tmdl
	measure Space = ""
		displayFolder: 1. Formatting
		lineageTag: <guid>

		changedProperty = Name

		changedProperty = DisplayFolder
```

### Hidden measures
```tmdl
	measure 'Internal Measure' = ```
			COUNTROWS('SomeTable')
			
			```
		isHidden
		displayFolder: Hidden
		lineageTag: <guid>

		changedProperty = IsHidden
```

### Measure property order
1. `formatString` (if applicable)
2. `isHidden` (if applicable)
3. `displayFolder` (if applicable)
4. `lineageTag`
5. `changedProperty` entries (blank line before first)
6. `annotation` entries

### Common formatString patterns
- Currency: `\$#,0;(\$#,0);\$#,0`
- Integer: `0`
- Date: `General Date`
- Percentage: `0.00%`
- Custom date: `yyyy-mm-dd`

---

## Columns

### Source column (Direct Lake)
```tmdl
	column 'Customer Name'
		dataType: string
		sourceProviderType: varchar(8000)
		lineageTag: <guid>
		sourceLineageTag: Customer Name
		summarizeBy: none
		sourceColumn: Customer Name

		annotation SummarizationSetBy = Automatic
```

### Calculated column
```tmdl
	column Slicer =
			
			IF(
			    [Parameter Order] IN {0, 1}, "CID", "ICA"
			)
		lineageTag: <guid>
		summarizeBy: none

		annotation SummarizationSetBy = Automatic
```

### Column property order
1. `dataType`
2. `formatString` (if applicable)
3. `isHidden` (if applicable)
4. `sourceProviderType` (source columns)
5. `lineageTag`
6. `sourceLineageTag` (source columns)
7. `summarizeBy`
8. `sourceColumn` (source columns)
9. `sortByColumn` (if applicable)
10. `changedProperty` entries
11. `annotation` entries

---

## Partitions

### Direct Lake partition (most common)
```tmdl
	partition 'TableName' = entity
		mode: directLake
		source
			entityName: TableName
			schemaName: dbo
			expressionSource: DatabaseQuery
```

### Calculated table partition
```tmdl
	partition 'ParameterTable' = calculated
		mode: import
		source =
				
				{
				    ("Label", NAMEOF('DimTable'[Column]), 0),
				    ("Label2", NAMEOF('DimTable'[Column2]), 1)
				}
```

---

## Relationships (relationships.tmdl)

### Standard (many-to-one)
```tmdl
relationship eb7f42c7-7937-3a70-c2ae-81e7803461d0
	fromColumn: 'FactTable'.KeyColumn
	toColumn: 'DimTable'.KeyColumn
```

### Inactive
```tmdl
relationship e0828589-8818-68a1-c67a-b12fcd64d3ab
	isActive: false
	fromColumn: 'FactTable'.DateColumn
	toColumn: 'DateTable'.Date
```

### Relationship property order
1. `isActive: false` (only if inactive)
2. `toCardinality: many` (only if many-to-many)
3. `crossFilteringBehavior: bothDirections` (only if bidirectional)
4. `fromColumn`
5. `toColumn`

---

## lineageTag rules

- Format: lowercase GUID with dashes
- **Editing existing objects**: NEVER change or remove an existing lineageTag
- **Creating new objects**: **omit the lineageTag entirely** -- Fabric auto-generates it
- Never reuse a lineageTag from another element

---

## changedProperty rules

- Track UI modifications -- each on its own line at 2 tabs
- **Editing existing**: preserve all existing entries
- **Creating new**: do NOT add changedProperty entries

---

## Naming conventions

### Table naming
- `0.x -` prefix: System/dimension/lookup tables
- `1.x -` prefix: First domain area
- `2.x -` / `3.x -` / `4.x -`: Additional domain areas
- Measures-only: `X - Measures - Description`
- Facts: `X.X - Facts_Name`
- Dimensions: `X.X - Dim_Name`

---

## Common mistakes to AVOID

1. Never use semicolons -- TMDL is indentation-based
2. Never use spaces for indentation -- always tabs
3. Never put relationships inside table files
4. Never put multiple tables in one file
5. Never forget `ref table` in model.tmdl
6. Never wrap DAX in string quotes
7. Never omit the partition block
8. Single-quote names with spaces: `'My Table'`

---

## What NOT to edit

| File | Reason |
|------|--------|
| `definition.pbism` | Connection metadata -- editing breaks deployment |
| `.platform` | Fabric platform metadata -- auto-managed |
| `database.tmdl` | Always just `compatibilityLevel: 1604` |
| `cultures/en-US.tmdl` | Linguistic metadata -- rarely needs changes |

---

## Annotations guidance

- **Editing existing**: preserve all existing annotations
- **Creating new**: only add structurally required annotations:
  - `annotation SummarizationSetBy = Automatic` -- on every column
  - `annotation PBI_FormatHint = {"currencyCulture":"en-US"}` -- with currency formatString
  - `annotation PBI_FormatHint = {"isCustom":true}` -- with custom formatStrings
  - `annotation UnderlyingDateTimeDataType = Date` -- on date columns
  - `annotation PBI_ResultType = Table` -- at table level for source tables
  - `annotation PBI_Id = <hex>` -- on Field Parameter tables

---

## Post-edit validation checklist

- [ ] **Tabs only** -- no spaces in indentation
- [ ] **lineageTags unchanged** -- existing tags not modified
- [ ] **New table?** -> `ref table` added to `model.tmdl`
- [ ] **New relationship?** -> in `relationships.tmdl` only
- [ ] **Annotations preserved**
- [ ] **changedProperty preserved**
- [ ] **File not in do-not-edit list**
'@
Write-ManagedFile $tmdlSkillPath $tmdlContent
# Set the custom skill file date to the PS1 installer's own modification date
# so on first install the date reflects when the skill content was last authored,
# not when the installer happened to run. After maintainer updates, the file's
# own LastWriteTime will reflect the actual update date.
$ps1LastModified = (Get-Item $MyInvocation.MyCommand.Path).LastWriteTime
(Get-Item $tmdlSkillPath).LastWriteTime = $ps1LastModified
Write-Host "  Written: .github/skills/fabric-tmdl/SKILL.md" -ForegroundColor Green

# ----- fabric-pipelines/SKILL.md -------------------------------------
$pipelineSkillPath = "$rootPath\.github\skills\fabric-pipelines\SKILL.md"
Write-Host "  Writing fabric-pipelines skill..."
$pipelineContent = @'
---
name: fabric-pipelines
description: "Use when: editing or creating Data Factory pipeline JSON files (pipeline-content.json) in Fabric PBIP projects. Covers pipeline activity types, typeProperties, dependency chaining, ForEach/IfCondition nesting, variables, and Variable Library integration."
---

# Fabric Data Pipeline Authoring Skill

## Origin and maintenance

- **Created from**: microsoft/skills-for-fabric `ITEM-DEFINITIONS-CORE.md` (DataPipeline section)
  and Microsoft Learn docs for Data Factory in Fabric
- **Pipeline JSON schemas** are NOT published at `microsoft/json-schemas` (as of April 2026)
- **To update this skill**: check `skills-for-fabric/common/ITEM-DEFINITIONS-CORE.md` for new
  activity types, and review https://learn.microsoft.com/en-us/fabric/data-factory/
  for updated typeProperties. Then re-run the installer or edit this file directly.
- **Note**: when `skills-for-fabric` or `power-bi-agentic-development` eventually publish
  a pipeline skill, the Fabric Master Agent starting flow will pull it in automatically.

---

## When to use
- User asks to create, edit, or review Data Factory pipeline definitions
- User mentions pipeline activities, orchestration, ForEach, IfCondition, Copy activity
- User asks about `pipeline-content.json` structure
- User wants to trigger notebook runs, semantic model refreshes, or copy data via pipelines

---

## File structure

In a Fabric PBIP project, a Data Pipeline is defined by:

```
<PipelineName>.DataPipeline/
    pipeline-content.json      <- all activities and pipeline config
    .platform                  <- Fabric metadata (don't edit)
```

## pipeline-content.json structure

```json
{
  "properties": {
    "description": "Pipeline description",
    "activities": [
      {
        "name": "ActivityName",
        "type": "ActivityType",
        "dependsOn": [],
        "policy": {
          "timeout": "0.12:00:00",
          "retry": 0,
          "retryIntervalInSeconds": 30
        },
        "typeProperties": { }
      }
    ],
    "variables": {
      "MyVar": { "type": "String", "defaultValue": "" }
    },
    "annotations": []
  }
}
```

### Top-level properties
- `properties.description` -- pipeline description string
- `properties.activities` -- array of activity objects (the core of the pipeline)
- `properties.variables` -- pipeline-scoped variables (String, Boolean, Array)
- `properties.annotations` -- metadata tags (array of strings)

---

## Activity common properties

Every activity has these properties:

| Property | Type | Description |
|----------|------|-------------|
| `name` | string | Unique name within the pipeline |
| `type` | string | Activity type (see list below) |
| `dependsOn` | array | Dependencies on other activities |
| `policy` | object | Timeout, retry, retryInterval |
| `typeProperties` | object | Activity-type-specific configuration |

### dependsOn structure
```json
"dependsOn": [
  {
    "activity": "PreviousActivityName",
    "dependencyConditions": ["Succeeded"]
  }
]
```
Valid conditions: `Succeeded`, `Failed`, `Skipped`, `Completed`

### policy structure
```json
"policy": {
  "timeout": "0.12:00:00",
  "retry": 0,
  "retryIntervalInSeconds": 30
}
```

---

## Activity types and typeProperties

### TridentNotebook (run a Fabric notebook)
```json
{
  "name": "Run ETL Notebook",
  "type": "TridentNotebook",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "notebookId": "<notebook-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```
- `notebookId` and `workspaceId` are GUIDs referencing Fabric items
- Can include `parameters` object for notebook parameters

### Copy (copy data between sources)
```json
{
  "name": "Copy Sales Data",
  "type": "Copy",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "source": {
      "type": "LakehouseTableSource"
    },
    "sink": {
      "type": "LakehouseTableSink",
      "tableActionOption": "Overwrite"
    },
    "enableStaging": false
  }
}
```

### ForEach (iterate over a collection)
```json
{
  "name": "Process Each Table",
  "type": "ForEach",
  "dependsOn": [],
  "typeProperties": {
    "isSequential": false,
    "batchCount": 20,
    "items": {
      "value": "@pipeline().parameters.TableList",
      "type": "Expression"
    },
    "activities": [
      {
        "name": "Inner Activity",
        "type": "TridentNotebook",
        "typeProperties": {
          "notebookId": "<guid>",
          "workspaceId": "<guid>"
        }
      }
    ]
  }
}
```
- `items` is an expression that evaluates to an array
- `activities` is a nested array of activities (same structure as top-level)
- `isSequential: false` enables parallel execution (up to `batchCount`)

### IfCondition (branching logic)
```json
{
  "name": "Check Row Count",
  "type": "IfCondition",
  "dependsOn": [
    { "activity": "Get Metadata", "dependencyConditions": ["Succeeded"] }
  ],
  "typeProperties": {
    "expression": {
      "value": "@greater(activity('Get Metadata').output.count, 0)",
      "type": "Expression"
    },
    "ifTrueActivities": [ ],
    "ifFalseActivities": [ ]
  }
}
```

### Switch (multi-branch)
```json
{
  "name": "Route by Type",
  "type": "Switch",
  "typeProperties": {
    "on": {
      "value": "@pipeline().parameters.ProcessType",
      "type": "Expression"
    },
    "cases": [
      {
        "value": "Full",
        "activities": [ ]
      },
      {
        "value": "Incremental",
        "activities": [ ]
      }
    ],
    "defaultActivities": [ ]
  }
}
```

### SetVariable
```json
{
  "name": "Set Status",
  "type": "SetVariable",
  "typeProperties": {
    "variableName": "ProcessStatus",
    "value": {
      "value": "@string('Complete')",
      "type": "Expression"
    }
  }
}
```

### ExecutePipeline (call another pipeline)
```json
{
  "name": "Run Child Pipeline",
  "type": "ExecutePipeline",
  "typeProperties": {
    "pipeline": {
      "referenceName": "<pipeline-guid>",
      "type": "PipelineReference"
    },
    "waitOnCompletion": true,
    "parameters": { }
  }
}
```

### PBISemanticModelRefresh (refresh a semantic model)
```json
{
  "name": "Refresh Sales Model",
  "type": "PBISemanticModelRefresh",
  "dependsOn": [
    { "activity": "Run ETL", "dependencyConditions": ["Succeeded"] }
  ],
  "policy": { "timeout": "0.12:00:00", "retry": 1, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "datasetId": "<semantic-model-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```

### Lookup (retrieve data for use in expressions)
```json
{
  "name": "Get Config",
  "type": "Lookup",
  "typeProperties": {
    "source": { "type": "LakehouseTableSource" },
    "datasetSettings": {
      "type": "LakehouseTableDataset",
      "typeProperties": { "table": "config_table" }
    },
    "firstRowOnly": true
  }
}
```

### Wait
```json
{
  "name": "Wait 60 Seconds",
  "type": "Wait",
  "typeProperties": {
    "waitTimeInSeconds": 60
  }
}
```

### Fail (force pipeline failure)
```json
{
  "name": "Abort Pipeline",
  "type": "Fail",
  "typeProperties": {
    "message": { "value": "Validation failed", "type": "Expression" },
    "errorCode": "1001"
  }
}
```

### WebActivity (call an HTTP endpoint)
```json
{
  "name": "Call API",
  "type": "WebActivity",
  "typeProperties": {
    "url": "https://api.example.com/trigger",
    "method": "POST",
    "headers": { "Content-Type": "application/json" },
    "body": { "key": "value" },
    "authentication": {
      "type": "MSI",
      "resource": "https://api.example.com"
    }
  }
}
```

### Script (run T-SQL against a Warehouse)
```json
{
  "name": "Run SQL",
  "type": "Script",
  "typeProperties": {
    "scripts": [
      {
        "type": "Query",
        "text": "SELECT COUNT(*) FROM dbo.FactSales"
      }
    ],
    "scriptBlockExecutionTimeout": "02:00:00"
  }
}
```

### GetMetadata (retrieve dataset/file metadata)
```json
{
  "name": "Get Row Count",
  "type": "GetMetadata",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "source": { "type": "LakehouseTableSource" },
    "datasetSettings": {
      "type": "LakehouseTableDataset",
      "typeProperties": { "table": "my_table" }
    },
    "fieldList": ["itemName", "itemType", "childItems", "columnCount", "structure"]
  }
}
```
- `fieldList` specifies which metadata fields to retrieve
- Common fields: `itemName`, `itemType`, `childItems`, `columnCount`, `structure`, `lastModified`, `exists`
- Access output via `@activity('Get Row Count').output.fieldName`

### Until (loop until a condition is true)
```json
{
  "name": "Wait Until Ready",
  "type": "Until",
  "dependsOn": [],
  "typeProperties": {
    "expression": {
      "value": "@equals(activity('Check Status').output.status, 'Completed')",
      "type": "Expression"
    },
    "activities": [
      {
        "name": "Check Status",
        "type": "WebActivity",
        "typeProperties": {
          "url": "https://api.example.com/status",
          "method": "GET"
        }
      },
      {
        "name": "Wait",
        "type": "Wait",
        "dependsOn": [
          { "activity": "Check Status", "dependencyConditions": ["Succeeded"] }
        ],
        "typeProperties": { "waitTimeInSeconds": 30 }
      }
    ],
    "timeout": "0.01:00:00"
  }
}
```
- `expression` is evaluated after each iteration -- loop exits when true
- `activities` is a nested array (same structure as ForEach inner activities)
- `timeout` caps total loop duration (format: `d.HH:mm:ss`)

### AppendVariable (add a value to an array variable)
```json
{
  "name": "Collect Table Name",
  "type": "AppendVariable",
  "dependsOn": [],
  "typeProperties": {
    "variableName": "ProcessedTables",
    "value": {
      "value": "@item().tableName",
      "type": "Expression"
    }
  }
}
```
- The target variable must be declared as type `Array` in `properties.variables`
- Often used inside ForEach to accumulate results

### SparkJobDefinition (run a Spark Job Definition item)
```json
{
  "name": "Run Spark Job",
  "type": "SparkJobDefinition",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "sparkJobDefinitionId": "<spark-job-definition-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```
- References a Fabric Spark Job Definition item by GUID
- Similar to TridentNotebook but for standalone Spark jobs

### Delete (delete files/folders from storage)
```json
{
  "name": "Clean Staging",
  "type": "Delete",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "datasetSettings": {
      "type": "LakehouseNonDeltaTableDataset",
      "typeProperties": {
        "location": {
          "type": "LakehouseLocation",
          "folderPath": "Files/staging"
        }
      }
    },
    "enableLogging": false,
    "recursive": true
  }
}
```
- Deletes files or folders from Lakehouse Files section
- `recursive: true` deletes folder contents
- `enableLogging` controls whether deletion logs are generated

### Filter (filter an array using a condition)
```json
{
  "name": "Filter Active Tables",
  "type": "Filter",
  "dependsOn": [],
  "typeProperties": {
    "items": {
      "value": "@activity('Get Config').output.value",
      "type": "Expression"
    },
    "condition": {
      "value": "@equals(item().isActive, true)",
      "type": "Expression"
    }
  }
}
```
- `items` is the input array to filter
- `condition` is evaluated for each item -- only items where condition is true pass through
- Access filtered results via `@activity('Filter Active Tables').output.value`

### DataflowGen2 (run a Dataflow Gen2 item)
```json
{
  "name": "Transform Sales Data",
  "type": "DataflowGen2",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "dataflowId": "<dataflow-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```
- References a Fabric Dataflow Gen2 item by GUID

### KQL (execute a KQL script against an Eventhouse)
```json
{
  "name": "Query Eventhouse",
  "type": "KQL",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "script": "MyTable | take 100",
    "database": "<database-name>",
    "endpoint": "<eventhouse-endpoint>"
  }
}
```
- Runs a KQL query against a Kusto instance or Fabric Eventhouse

### Teams (post a message in Teams)
```json
{
  "name": "Notify Team",
  "type": "Teams",
  "dependsOn": [],
  "typeProperties": {
    "title": "Pipeline completed",
    "body": {
      "value": "@concat('Pipeline ', pipeline().Pipeline, ' finished at ', utcNow())",
      "type": "Expression"
    },
    "recipient": "<channel-or-group-chat-id>"
  }
}
```
- Posts a message to a Teams channel or group chat

### LakehouseMaintenance (perform table maintenance on a Lakehouse)
```json
{
  "name": "Optimize Tables",
  "type": "LakehouseMaintenance",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "lakehouseId": "<lakehouse-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```
- Performs routine table maintenance (compaction, vacuum) on a Lakehouse from a pipeline

### RefreshSQLEndpoint (refresh a Lakehouse SQL endpoint)
```json
{
  "name": "Refresh SQL Endpoint",
  "type": "RefreshSQLEndpoint",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "lakehouseId": "<lakehouse-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```
- Refreshes a Lakehouse SQL endpoint to reflect the latest data

### Webhook (call endpoint and wait for callback)
```json
{
  "name": "Wait for Approval",
  "type": "Webhook",
  "dependsOn": [],
  "typeProperties": {
    "url": "https://api.example.com/approve",
    "method": "POST",
    "headers": { "Content-Type": "application/json" },
    "body": { "pipelineRun": "@pipeline().RunId" },
    "timeout": "0.01:00:00",
    "authentication": {
      "type": "MSI",
      "resource": "https://api.example.com"
    }
  }
}
```
- Calls an endpoint and passes a callback URL; pipeline waits for the callback before proceeding
- Unlike WebActivity, Webhook suspends pipeline execution until the callback is received or timeout expires

### StoredProcedure (run a stored procedure)
```json
{
  "name": "Run Proc",
  "type": "StoredProcedure",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "storedProcedureName": "dbo.usp_LoadFact",
    "storedProcedureParameters": {
      "BatchDate": { "value": "@utcNow()", "type": "DateTime" }
    }
  }
}
```
- Executes a stored procedure against Azure SQL, Synapse Analytics, or SQL Server

### SQLScript (run a SQL script item)
```json
{
  "name": "Run SQL Script",
  "type": "SQLScript",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "scriptPath": "<sql-script-item-guid>",
    "workspaceId": "<workspace-guid>"
  }
}
```
- Runs a SQL script item from the Fabric workspace

### HDInsightActivity (run Spark on HDInsight)
```json
{
  "name": "Run HDInsight Spark",
  "type": "HDInsightActivity",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "sparkJobLinkedServiceName": "<linked-service>",
    "className": "com.example.MainClass",
    "jarFilePath": "abfss://container@storage.dfs.core.windows.net/app.jar"
  }
}
```
- Runs Spark on an Apache Spark cluster managed by Microsoft Fabric (HDInsight)

### FunctionsActivity (execute an Azure Function)
```json
{
  "name": "Call Function",
  "type": "FunctionsActivity",
  "dependsOn": [],
  "typeProperties": {
    "functionName": "MyFunction",
    "method": "POST",
    "headers": { "Content-Type": "application/json" },
    "body": { "key": "value" }
  }
}
```
- Executes an Azure Function from the pipeline

### CopyJob (simplified data movement)
```json
{
  "name": "Move Sales Data",
  "type": "CopyJob",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "sourceConnection": "<source-connection-guid>",
    "sinkConnection": "<sink-connection-guid>",
    "copyMode": "Full"
  }
}
```
- Simplified method for moving data quickly between supported sources and sinks
- Higher-level than the Copy activity -- fewer configuration options but faster setup

### AzureBatch (run an Azure Batch script)
```json
{
  "name": "Run Batch Job",
  "type": "AzureBatch",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "batchAccountEndpoint": "<batch-account-endpoint>",
    "poolName": "<pool-name>",
    "command": "python main.py --input data.csv"
  }
}
```
- Runs a script or command on an Azure Batch pool
- Useful for heavy compute workloads outside of Spark

### AzureDatabricks (run a Databricks job)
```json
{
  "name": "Run Databricks Notebook",
  "type": "AzureDatabricks",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "notebookPath": "/Shared/ETL/transform",
    "baseParameters": {
      "input_table": "raw_sales",
      "output_table": "clean_sales"
    }
  }
}
```
- Runs an Azure Databricks Notebook, Jar, or Python script
- `baseParameters` passes key-value pairs to the notebook

### AzureMLExecutePipeline (run an Azure Machine Learning job)
```json
{
  "name": "Run ML Pipeline",
  "type": "AzureMLExecutePipeline",
  "dependsOn": [],
  "policy": { "timeout": "0.12:00:00", "retry": 0, "retryIntervalInSeconds": 30 },
  "typeProperties": {
    "mlPipelineId": "<ml-pipeline-guid>",
    "experimentName": "sales-forecast",
    "mlPipelineParameters": {
      "input_data": "abfss://container@storage.dfs.core.windows.net/data"
    }
  }
}
```
- Triggers an Azure Machine Learning pipeline
- `mlPipelineParameters` passes parameters to the ML pipeline

### Deactivate (deactivate another activity)
```json
{
  "name": "Disable Old ETL",
  "type": "Deactivate",
  "dependsOn": [],
  "typeProperties": {
    "activityName": "Legacy ETL Process"
  }
}
```
- Deactivates another activity in the pipeline at runtime
- Useful for conditional disabling of pipeline branches

---

## Variable Library integration

Pipelines can consume Variable Library values (centralized config):

```json
{
  "properties": {
    "activities": [
      {
        "name": "Run ETL",
        "type": "TridentNotebook",
        "typeProperties": {
          "notebookId": {
            "value": "@pipeline().libraryVariables.notebook_id",
            "type": "Expression"
          }
        }
      }
    ],
    "libraryVariables": {
      "notebook_id": {
        "libraryName": "MyConfig",
        "libraryId": "<guid>",
        "variableName": "notebook_id",
        "type": "String"
      }
    }
  }
}
```

Pipeline type mappings (use these, NOT Variable Library type names):

| Variable Library Type | Pipeline Type |
|----------------------|---------------|
| Boolean | Bool |
| Integer | Int |
| Number | Double |
| DateTime | String |
| String | String |
| ItemReference | String |

Dynamic references MUST use expression objects:
`{"value": "@pipeline().libraryVariables.x", "type": "Expression"}`

---

## Expression syntax

Expressions use `@` prefix and are wrapped in expression objects:

```json
{ "value": "@pipeline().parameters.MyParam", "type": "Expression" }
```

Common patterns:
- `@pipeline().parameters.ParamName` -- access pipeline parameter
- `@pipeline().variables.VarName` -- access pipeline variable
- `@pipeline().libraryVariables.VarName` -- access Variable Library value
- `@activity('ActivityName').output` -- access activity output
- `@greater(value1, value2)` -- comparison function
- `@if(condition, trueValue, falseValue)` -- conditional
- `@concat(str1, str2)` -- string concatenation
- `@utcNow()` -- current UTC timestamp

---

## Common patterns

### Sequential ETL: Notebook -> Refresh
```json
{
  "properties": {
    "activities": [
      {
        "name": "Run ETL",
        "type": "TridentNotebook",
        "dependsOn": [],
        "typeProperties": { "notebookId": "<guid>", "workspaceId": "<guid>" }
      },
      {
        "name": "Refresh Model",
        "type": "PBISemanticModelRefresh",
        "dependsOn": [
          { "activity": "Run ETL", "dependencyConditions": ["Succeeded"] }
        ],
        "typeProperties": { "datasetId": "<guid>", "workspaceId": "<guid>" }
      }
    ]
  }
}
```

---

## Validation checklist

After editing `pipeline-content.json`:

- [ ] Valid JSON (no trailing commas, proper quoting)
- [ ] Every activity has a unique `name`
- [ ] `dependsOn` references match existing activity names exactly
- [ ] Expression objects have both `value` and `type: "Expression"`
- [ ] GUIDs for notebooks, semantic models, workspaces are valid
- [ ] Nested activities in ForEach/IfCondition/Switch follow same structure
- [ ] Do NOT edit `.platform` file
'@
Write-ManagedFile $pipelineSkillPath $pipelineContent
(Get-Item $pipelineSkillPath).LastWriteTime = $ps1LastModified
Write-Host "  Written: .github/skills/fabric-pipelines/SKILL.md" -ForegroundColor Green

Read-Host "`n  Press Enter to continue..."

# =====================================================================
# STEP 6  -- Generate agent definitions
# =====================================================================
Show-Step 6 $totalSteps "Writing Agent Definitions"

# ----- 1 - Fabric Workspace Master Agent ------------------------------
$masterAgentContent = @'
---
name: "1 - Fabric Workspace Master Agent"
description: "Master coordinator for all Fabric work. Start here. Routes to specialist agents, manages session startup, and reads skills on demand."
tools: [execute, read, edit, search, agent, todo]
---

You are 1 - Fabric Workspace Master Agent, the single entry point for all Microsoft Fabric work.
The user selects you from the Copilot Chat dropdown and sends any message to begin.

## TOOL WARM-UP

Before running ANY terminal command, read these files first:
1. Read `.github/copilot-instructions.md`
2. Read `AGENTS.md`
Only after both reads succeed, proceed to terminal commands.

## STARTING FLOW
(Run this on the first message of every new session)

### Phase 1 -- Skill maintenance prompt

First, check when each skill source was last modified locally and display it.
Use file modification times (LastWriteTime) for ALL sources. This date reflects:
- For a freshly installed workspace: the date the installer created the skills
- For updated skills: the date of the last git pull or maintainer update
All times are shown in the user's local timezone.

Run these commands and collect the dates (format: yyyy-MM-dd HH:mm local time):

For cloned repos, check the most recently modified skill file:
  Get-ChildItem "skills-for-fabric/skills" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty LastWriteTime | ForEach-Object { $_.ToString("yyyy-MM-dd HH:mm") }
  Get-ChildItem "power-bi-agentic-development/plugins" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty LastWriteTime | ForEach-Object { $_.ToString("yyyy-MM-dd HH:mm") }

For custom embedded skills:
  (Get-Item ".github/skills/fabric-tmdl/SKILL.md").LastWriteTime.ToString("yyyy-MM-dd HH:mm")
  (Get-Item ".github/skills/fabric-pipelines/SKILL.md").LastWriteTime.ToString("yyyy-MM-dd HH:mm")

If a source folder or file does not exist, show "not installed" instead of a date.

Then say:
"Welcome to your Fabric Workspace session!

**Skill sources -- last updated (local time):**
| Source | Last updated |
|--------|-------------|
| skills-for-fabric (Microsoft) | [date HH:mm or 'not installed'] |
| power-bi-agentic-development (data-goblin) | [date HH:mm or 'not installed'] |
| fabric-tmdl (custom, embedded) | [date HH:mm] |
| fabric-pipelines (custom, embedded) | [date HH:mm] |

Would you like to run a full skill update?
This pulls the latest from GitHub and checks skill freshness against MS docs.

  [1] Yes -- update skills now (switches to Skills Maintainer, then returns here)
  [2] No  -- skip and start working

Enter 1 or 2:"

**If the user chooses 1:**
Say: "Please switch to **@2-fabric-skills-maintainer** in the Copilot Chat dropdown. It will run the full maintenance flow and tell you when to come back here."
Then STOP and wait. When the user returns and sends another message, continue to Phase 2.

**If the user chooses 2 (or anything else):**
Run a quick background pull (no deep check):
  git -C skills-for-fabric pull --ff-only 2>&1 || true
  git -C power-bi-agentic-development pull --ff-only 2>&1 || true
Say: "Quick pull done. Skipping deep skill check."
Continue to Phase 2.

### Phase 2 -- Check Azure identity

Run: az account show --query "{name:name, user:user.name}" --output table 2>&1
If successful: "Logged in as [user] on tenant [name]."
If it fails: "Not logged in to Azure. Run `az login` if you need Fabric API access."
Do NOT block on this -- many tasks work without az login.

### Phase 3 -- Topic selection

Say:
"What would you like to work on?

  [3] Semantic Models  -- TMDL, DAX, measures, columns, relationships
  [4] Data Engineering -- Spark notebooks, SQL warehouse, pipelines, medallion
  [5] Administration   -- Capacity, governance, workspace documentation
  [6] App Development  -- Python apps, ODBC, XMLA, REST API integration
  [7] Reports          -- PBIR report editing, visuals, themes
  [8] Pipelines        -- Data Factory pipeline JSON authoring
  [0] Stay here        -- I will describe what I need and you route for me

Enter a number or describe your task:"

**If user picks 3-8:** Say "Please switch to the corresponding agent in the dropdown:
- 3 -> @3-semantic-model-agent
- 4 -> @4-fabric-data-engineer
- 5 -> @5-fabric-admin
- 6 -> @6-fabric-app-dev
- 7 -> @7-fabric-reports-agent
- 8 -> @8-fabric-pipelines-agent"

**If user picks 0 or describes a task:** Continue in this agent. Read the relevant skills yourself (see WORKING FLOW below) and handle the request directly.

## WORKING FLOW

When handling tasks directly, read the relevant skill files before generating any code:

### TMDL / Semantic Model work
Read `.github/skills/fabric-tmdl/SKILL.md` first, then follow it precisely.
For additional TMDL depth: `power-bi-agentic-development/plugins/pbip/skills/tmdl/SKILL.md`
For DAX best practices: `power-bi-agentic-development/plugins/semantic-models/skills/dax/SKILL.md`

### Spark / Notebook / Lakehouse work
Read `skills-for-fabric/skills/spark-authoring-cli/SKILL.md` first.
For consumption (queries): `skills-for-fabric/skills/spark-consumption-cli/SKILL.md`

### SQL Warehouse work
Read `skills-for-fabric/skills/sqldw-authoring-cli/SKILL.md` first.
For consumption: `skills-for-fabric/skills/sqldw-consumption-cli/SKILL.md`

### Eventhouse / KQL work
Read `skills-for-fabric/skills/eventhouse-authoring-cli/SKILL.md` first.
For consumption: `skills-for-fabric/skills/eventhouse-consumption-cli/SKILL.md`

### Pipeline work
Read `.github/skills/fabric-pipelines/SKILL.md` first.

### Semantic model deployment / refresh / permissions (via REST API)
Read `skills-for-fabric/skills/powerbi-authoring-cli/SKILL.md` first.
For DAX queries against deployed models: `skills-for-fabric/skills/powerbi-consumption-cli/SKILL.md`

### Report editing (PBIR)
Read `power-bi-agentic-development/plugins/pbip/skills/pbir-format/SKILL.md` first.
For themes and visuals: `power-bi-agentic-development/plugins/reports/skills/`

### Capacity / Admin / Governance
Read `skills-for-fabric/skills/` -- use the FabricAdmin patterns.
Also: `power-bi-agentic-development/plugins/fabric-admin/skills/`

### Medallion architecture (end-to-end)
Read `skills-for-fabric/skills/e2e-medallion-architecture/SKILL.md`

### Working rules
- Always read the relevant SKILL.md BEFORE generating any code or TMDL
- Never guess -- if a skill file does not exist, tell the user
- For validation after TMDL edits, run the post-edit checklist from the TMDL skill
- Keep git history clean if the workspace is a git repo
'@
Write-ManagedFile "$rootPath\.github\agents\1-fabric-workspace-master-agent.agent.md" $masterAgentContent
Write-Host "  Written: 1-fabric-workspace-master-agent.agent.md" -ForegroundColor Green

# ----- 2 - Fabric Skills Maintainer -----------------------------------
$skillsMaintainerContent = @'
---
name: "2 - Fabric Skills Maintainer"
description: "Use when: updating skill repositories, checking pipeline skill freshness against Microsoft docs, maintaining custom skills. Called from Master Agent or directly."
tools: [execute, read, edit, search, fetch, todo]
---

You are 2 - Fabric Skills Maintainer, responsible for keeping all skills up to date.
The user switches to you from the Master Agent or selects you directly from the dropdown.

## MAINTENANCE FLOW

Run all phases in order, then tell the user to switch back to the Master Agent.

### Phase 1 -- Pull skill repositories

Say: "Updating skill repositories from GitHub..."

Run:
  git -C skills-for-fabric pull --ff-only 2>&1
  git -C power-bi-agentic-development pull --ff-only 2>&1

If a pull succeeds: report "skills-for-fabric: updated" / "power-bi-agentic-development: updated"
If a pull fails (network issue): report the error and continue.
If a folder is missing entirely, clone it:
  git clone https://github.com/microsoft/skills-for-fabric.git skills-for-fabric
  git clone https://github.com/data-goblin/power-bi-agentic-development.git power-bi-agentic-development

### Phase 2 -- Check pipeline skill freshness

Read the current embedded pipeline skill:
  `.github/skills/fabric-pipelines/SKILL.md`

Also check if `skills-for-fabric/skills/check-updates/` has any useful update guidance.

Then check these Microsoft Learn pages for any changes to pipeline activity types or structure:
- https://learn.microsoft.com/en-us/fabric/data-factory/activity-overview
- https://learn.microsoft.com/en-us/fabric/data-factory/pipeline-rest-api

Also check the upstream source the skill was built from:
  `skills-for-fabric/common/ITEM-DEFINITIONS-CORE.md` (DataPipeline section)

Compare the activity types listed in our skill against what these sources document.
Report findings:

**If no changes detected:**
Say: "Pipeline skill is current. No updates needed."

**If new activity types or changed typeProperties found:**
Say: "Found updates to pipeline activities: [list changes]"
Then ask: "Would you like me to update `.github/skills/fabric-pipelines/SKILL.md` with these changes? [Y/N]"
If Y: edit the skill file to incorporate the new information, preserving the existing structure.
If N: say "Skipping update. You can re-run maintenance later."

### Phase 3 -- Check for new skills in cloned repos

List the skills directories:
  ls skills-for-fabric/skills/
  ls power-bi-agentic-development/plugins/

Compare against what the Master Agent references in its WORKING FLOW section.
If there are new skill folders that no agent references yet:
Say: "New skills found that are not yet referenced by any agent: [list]"
Say: "Consider updating the relevant agent to reference these skills, or re-run the installer."

### Phase 4 -- Summary and handoff

Say:
"Maintenance complete. Summary:
- Skill repos: [updated / failed / cloned]
- Pipeline skill: [current / updated / update available but skipped]
- New unreferenced skills: [none / list]

Switch back to **@1-fabric-workspace-master-agent** to continue your session."

## NOTES
- The TMDL skill (`.github/skills/fabric-tmdl/SKILL.md`) is maintained by the installer
  and based on codebase-specific knowledge. Do NOT modify it during maintenance.
- Only the pipeline skill is checked against external docs, because it tracks
  a rapidly evolving Microsoft API surface.
- If the user asks to update the TMDL skill, explain that it should be done
  by editing the PS1 installer and re-running it, or by manually editing the file.

## KNOWN REFERENCED SKILLS
These skills are referenced by agents and should NOT be flagged as unreferenced:
- `skills-for-fabric/skills/check-updates/` -- used by this maintainer agent for update checks
- `power-bi-agentic-development/plugins/pbi-desktop/` -- referenced by 7-fabric-reports-agent
- `power-bi-agentic-development/plugins/tabular-editor/` -- referenced by 3-semantic-model-agent
- `power-bi-agentic-development/plugins/fabric-cli/` -- referenced by 4-fabric-data-engineer and 5-fabric-admin
When checking for unreferenced skills in Phase 3, exclude these from the report.
'@
Write-ManagedFile "$rootPath\.github\agents\2-fabric-skills-maintainer.agent.md" $skillsMaintainerContent
Write-Host "  Written: 2-fabric-skills-maintainer.agent.md" -ForegroundColor Green

# ----- 3 - Semantic Model Agent ---------------------------------------
$semanticModelAgentContent = @'
---
name: "3 - Semantic Model Agent"
description: "Use when: editing TMDL files, writing DAX measures, managing columns, relationships, partitions, or parameters in Fabric Semantic Models."
tools: [execute, read, edit, search, todo]
---

You are 3 - Semantic Model Agent, a specialist for Fabric Semantic Model development.

## Before any task

1. Read `.github/skills/fabric-tmdl/SKILL.md`  -- follow it precisely for all TMDL work
2. For additional TMDL depth: read `power-bi-agentic-development/plugins/pbip/skills/tmdl/SKILL.md`
3. For DAX best practices: read `power-bi-agentic-development/plugins/semantic-models/skills/dax/SKILL.md`
4. For naming conventions: read `power-bi-agentic-development/plugins/semantic-models/skills/dax/references/naming-conventions.md`
5. For Tabular Editor workflows: read `power-bi-agentic-development/plugins/tabular-editor/skills/` (if available)

## Capabilities
- Create, edit, and review measures, columns, tables, relationships, and partitions in TMDL
- Write and optimize DAX expressions following SQLBI conventions
- Manage Direct Lake partitions, Field Parameters, calculated tables
- Validate TMDL structure using the post-edit checklist

## Rules
- Always use TABS for indentation  -- never spaces
- Never change existing lineageTags
- Omit lineageTags on new objects (Fabric auto-generates them)
- New tables must be registered in model.tmdl with `ref table`
- Relationships go ONLY in relationships.tmdl
- Run the post-edit validation checklist after every edit
'@
Write-ManagedFile "$rootPath\.github\agents\3-semantic-model-agent.agent.md" $semanticModelAgentContent
Write-Host "  Written: 3-semantic-model-agent.agent.md" -ForegroundColor Green

# ----- 4 - Fabric Data Engineer ---------------------------------------
$dataEngineerContent = @'
---
name: "4 - Fabric Data Engineer"
description: "Use when: Spark notebooks, SQL warehouse, data pipelines, Lakehouse, medallion architecture, ETL/ELT, data engineering workflows across Fabric."
tools: [execute, read, edit, search, todo]
---

You are 4 - Fabric Data Engineer, a specialist for cross-workload data engineering in Fabric.

## Before any task

Read the relevant skill from `skills-for-fabric/skills/`:
- **Spark**: `spark-authoring-cli/SKILL.md` (notebooks, Lakehouse, PySpark)
- **SQL**: `sqldw-authoring-cli/SKILL.md` (Warehouse DDL/DML, T-SQL)
- **Eventhouse**: `eventhouse-authoring-cli/SKILL.md` (KQL tables, ingestion)
- **Medallion**: `e2e-medallion-architecture/SKILL.md` (Bronze/Silver/Gold)
- **Pipelines**: `.github/skills/fabric-pipelines/SKILL.md`
- **Fabric CLI**: `power-bi-agentic-development/plugins/fabric-cli/skills/` (Fabric CLI operations)

Also read `skills-for-fabric/common/COMMON-CLI.md` for az rest patterns and authentication.

## Core responsibilities
- Design and orchestrate medallion architecture (Bronze -> Silver -> Gold)
- Develop Spark notebooks and PySpark applications
- Author SQL objects in Fabric Warehouse
- Create and manage Data Factory pipelines
- Coordinate ETL/ELT across Spark, SQL, and pipelines

## Rules
- Decompose broad requests into endpoint-specific sub-tasks
- Require explicit environment parameterization (dev/test/prod)
- Keep IDs and secrets externalized  -- never hardcoded
- Prefer incremental processing and Delta Lake patterns
- Validate prerequisites (workspace capacity) before operations
'@
Write-ManagedFile "$rootPath\.github\agents\4-fabric-data-engineer.agent.md" $dataEngineerContent
Write-Host "  Written: 4-fabric-data-engineer.agent.md" -ForegroundColor Green

# ----- 5 - Fabric Admin -----------------------------------------------
$adminContent = @'
---
name: "5 - Fabric Admin"
description: "Use when: capacity management, governance, security, workspace documentation, cost optimization, compliance."
tools: [execute, read, edit, search, todo]
---

You are 5 - Fabric Admin, a specialist for Fabric platform administration.

## Before any task

Read skills from `skills-for-fabric/skills/` and `skills-for-fabric/common/COMMON-CLI.md`.
Also check:
- `power-bi-agentic-development/plugins/fabric-admin/skills/`
- `power-bi-agentic-development/plugins/fabric-cli/skills/` (Fabric CLI operations)

## Core responsibilities
- Capacity planning and optimization
- Governance and security validation
- Workspace documentation and inventory
- Cost and performance analysis
- RBAC and access control

## Rules
- Require explicit confirmation before destructive operations (delete workspace, remove capacity)
- Always check current capacity utilization before recommending scaling
- Enforce least-privilege RBAC  -- default to Viewer, escalate with justification
- Prefer automation via REST APIs over manual portal steps
'@
Write-ManagedFile "$rootPath\.github\agents\5-fabric-admin.agent.md" $adminContent
Write-Host "  Written: 5-fabric-admin.agent.md" -ForegroundColor Green

# ----- 6 - Fabric App Dev ---------------------------------------------
$appDevContent = @'
---
name: "6 - Fabric App Dev"
description: "Use when: building applications connected to Fabric data -- Python, ODBC, XMLA, REST API integration."
tools: [execute, read, edit, search, todo]
---

You are 6 - Fabric App Dev, a specialist for building applications on top of Fabric.

## Before any task

Read `skills-for-fabric/agents/FabricAppDev.agent.md` for full patterns.
Also: `skills-for-fabric/skills/sqldw-consumption-cli/SKILL.md` for SQL access patterns.

## Capabilities
- Connect applications to Fabric Warehouse/Lakehouse SQL endpoints via ODBC
- Integrate with semantic models via XMLA endpoints
- Set up local dev environments with `az login` + DefaultAzureCredential
- Build data access layers using pyodbc, sqlalchemy, pandas
- Integrate Fabric REST APIs for workspace and item management

## Rules
- Use parameterized queries  -- never concatenate user input into SQL
- Authenticate via az login / DefaultAzureCredential  -- never hardcode tokens
- Close connections explicitly (use context managers)
- Externalize connection strings in config / environment variables
'@
Write-ManagedFile "$rootPath\.github\agents\6-fabric-app-dev.agent.md" $appDevContent
Write-Host "  Written: 6-fabric-app-dev.agent.md" -ForegroundColor Green

# ----- 7 - Fabric Reports Agent ---------------------------------------
$reportsContent = @'
---
name: "7 - Fabric Reports Agent"
description: "Use when: editing PBIR report files, managing pages, visuals, themes, filters in Power BI report definitions."
tools: [execute, read, edit, search, todo]
---

You are 7 - Fabric Reports Agent, a specialist for editing Power BI report definitions (PBIR format).

## Before any task

Read these skills from `power-bi-agentic-development/plugins/`:
1. `pbip/skills/pbir-format/SKILL.md`  -- PBIR file structure and editing
2. `reports/skills/`  -- for Deneb, themes, R/Python visuals, report design
3. `pbi-desktop/skills/`  -- for Power BI Desktop authoring patterns (if available)

## PBIR structure
```
<ReportName>.Report/
    definition/
        report.json                              <- report-level settings
        version.json                             <- format version
        pages/
            pages.json                           <- page listing
            <pageId>/
                page.json                        <- per-page layout
                visuals/
                    <visualId>/visual.json       <- per-visual config
    definition.pbir                              <- semantic model reference
    StaticResources/                             <- themes, custom visuals, images
```

## Rules
- Always read the relevant SKILL.md before editing any PBIR file
- Validate JSON structure after every edit
- Do NOT edit `.platform` or `definition.pbir` unless explicitly asked
- Make a backup recommendation before large report restructuring
'@
Write-ManagedFile "$rootPath\.github\agents\7-fabric-reports-agent.agent.md" $reportsContent
Write-Host "  Written: 7-fabric-reports-agent.agent.md" -ForegroundColor Green

# ----- 8 - Fabric Pipelines Agent -------------------------------------
$pipelinesContent = @'
---
name: "8 - Fabric Pipelines Agent"
description: "Use when: creating or editing Data Factory pipeline JSON files, managing pipeline activities, orchestration, scheduling."
tools: [execute, read, edit, search, todo]
---

You are 8 - Fabric Pipelines Agent, a specialist for Data Factory pipeline authoring in Fabric.

## Before any task

1. Read `.github/skills/fabric-pipelines/SKILL.md`  -- follow it precisely
2. For deployment via REST API: read `skills-for-fabric/skills/powerbi-authoring-cli/SKILL.md`
3. For Variable Library integration: read `skills-for-fabric/common/ITEM-DEFINITIONS-CORE.md`

## Capabilities
- Create and edit pipeline-content.json files
- Design activity chains with proper dependency conditions
- Build ForEach, IfCondition, Switch branching logic
- Configure TridentNotebook, Copy, PBISemanticModelRefresh activities
- Integrate Variable Library for parameterized pipelines

## Rules
- Always validate JSON after edits (no trailing commas, proper quoting)
- Every activity must have a unique name
- dependsOn references must match existing activity names exactly
- Expression objects always need both `value` and `type: "Expression"`
- Do NOT edit `.platform` files
'@
Write-ManagedFile "$rootPath\.github\agents\8-fabric-pipelines-agent.agent.md" $pipelinesContent
Write-Host "  Written: 8-fabric-pipelines-agent.agent.md" -ForegroundColor Green

Write-Host "`n  All agents written." -ForegroundColor Green
Read-Host "`n  Press Enter to continue..."

# =====================================================================
# STEP 7  -- Generate configuration files
# =====================================================================
Show-Step 7 $totalSteps "Writing Configuration Files"

# -- copilot-instructions.md ------------------------------------------
$copilotInstructions = @'
# Copilot Workspace Instructions

This is a Microsoft Fabric development workspace with agentic AI support.

## Agents

The primary agent is **1 - Fabric Workspace Master Agent**, defined in
`.github/agents/1-fabric-workspace-master-agent.agent.md`.
Select it from the Copilot Chat agent dropdown to begin.

Specialist agents are also available in the dropdown for direct access:
- **2 - Fabric Skills Maintainer** -- Updates skill repos, checks pipeline skill freshness
- **3 - Semantic Model Agent** -- TMDL, DAX, measures, columns, relationships
- **4 - Fabric Data Engineer** -- Spark, SQL, pipelines, medallion architecture
- **5 - Fabric Admin** -- Capacity, governance, security, workspace docs
- **6 - Fabric App Dev** -- Python apps, ODBC, XMLA, REST API
- **7 - Fabric Reports Agent** -- PBIR report editing, visuals, themes
- **8 - Fabric Pipelines Agent** -- Data Factory pipeline JSON authoring

## Skills

### Custom skills (embedded by installer  -- source of truth is the PS1)
- `.github/skills/fabric-tmdl/SKILL.md`  -- TMDL syntax, indentation, property ordering
- `.github/skills/fabric-pipelines/SKILL.md`  -- Pipeline JSON structure, activity types

### Microsoft skills (cloned repo  -- auto-updated on session start)
- `skills-for-fabric/skills/`  -- Spark, SQL, Eventhouse, Power BI, Medallion
- `skills-for-fabric/common/`  -- Shared references (COMMON-CLI.md, ITEM-DEFINITIONS-CORE.md)

### Data-goblin skills (cloned repo  -- auto-updated on session start)
- `power-bi-agentic-development/plugins/pbip/skills/`  -- TMDL, PBIR, PBIP validation
- `power-bi-agentic-development/plugins/semantic-models/skills/`  -- DAX, naming conventions
- `power-bi-agentic-development/plugins/reports/skills/`  -- Deneb, themes, visuals
- `power-bi-agentic-development/plugins/fabric-cli/skills/`  -- Fabric CLI operations
- `power-bi-agentic-development/plugins/fabric-admin/skills/`  -- Fabric admin operations

## Workspace conventions
- Fabric items are synced via the Fabric VS Code extension (not managed by agents)
- Agents handle the development workflow: editing, validation, skill-guided authoring
- ALM (pull/push/deploy) is handled by the Fabric extension, not by agents
- Custom skills in `.github/skills/` are the installer's source of truth
'@
Write-ManagedFile "$rootPath\.github\copilot-instructions.md" $copilotInstructions
Write-Host "  Written: .github/copilot-instructions.md" -ForegroundColor Green

# -- AGENTS.md ---------------------------------------------------------
$agentsReadme = @'
# Fabric Agentic Workspace -- Agent Guide

## How to use

Open this folder in VS Code.
In Copilot Chat, select **1 - Fabric Workspace Master Agent** from the agent dropdown.
Type anything to begin. The agent offers to update skills, checks your Azure identity,
and presents a topic menu to route you to the right specialist.

You can also select specialist agents directly from the dropdown
if you know what you need.

---

## Agent architecture

### 1 - Fabric Workspace Master Agent  `.github/agents/1-fabric-workspace-master-agent.agent.md`
Single entry point. On session start: offers skill update (via Maintainer), checks az login,
presents topic selection menu. Can also handle tasks directly by reading skills.

### 2 - Fabric Skills Maintainer  `.github/agents/2-fabric-skills-maintainer.agent.md`
Pulls skill repos, checks pipeline skill freshness against Microsoft docs,
reports new unreferenced skills. Called from Master Agent or directly.

### Specialist agents (also selectable from dropdown)

| # | Agent | Focus | Key skills |
|---|-------|-------|------------|
| 3 | **Semantic Model Agent** | TMDL, DAX, measures, columns | fabric-tmdl, data-goblin pbip/semantic-models |
| 4 | **Fabric Data Engineer** | Spark, SQL, pipelines, medallion | skills-for-fabric spark/sqldw/e2e |
| 5 | **Fabric Admin** | Capacity, governance, docs | skills-for-fabric, fabric-admin |
| 6 | **Fabric App Dev** | Python apps, ODBC, XMLA | skills-for-fabric sqldw-consumption |
| 7 | **Fabric Reports Agent** | PBIR reports, visuals, themes | data-goblin pbip/reports |
| 8 | **Fabric Pipelines Agent** | Pipeline JSON authoring | fabric-pipelines skill |

---

## Skills sources

| Source | Location | Updated |
|--------|----------|---------|
| Custom (TMDL, Pipelines) | `.github/skills/` | Re-run installer |
| Microsoft skills-for-fabric | `skills-for-fabric/` | Auto on session start |
| Data-goblin plugins | `power-bi-agentic-development/` | Auto on session start |
'@
Write-ManagedFile "$rootPath\AGENTS.md" $agentsReadme
Write-Host "  Written: AGENTS.md" -ForegroundColor Green

# -- .gitignore --------------------------------------------------------
$gitignoreContent = @'
# Cloned skill repositories (managed by Fabric Master Agent)
skills-for-fabric/
power-bi-agentic-development/

# VS Code local
.vscode/

# OS
Thumbs.db
.DS_Store

# Fabric local cache
.pbi/
*.pbicache
'@
$gitignorePath = "$rootPath\.gitignore"
# Only write if it does not exist  -- user may have customised it
if (-not (Test-Path $gitignorePath)) {
    Write-ManagedFile $gitignorePath $gitignoreContent
    Write-Host "  Written: .gitignore" -ForegroundColor Green
} else {
    Write-Host "  .gitignore already exists  -- skipping (not overwriting)" -ForegroundColor Yellow
}

# -- .vscode/tasks.json ------------------------------------------------
$tasksJson = @'
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "Initialise Terminal",
            "type": "shell",
            "command": "echo Fabric Agentic Workspace ready",
            "runOptions": { "runOn": "folderOpen" },
            "presentation": {
                "reveal": "silent",
                "panel": "shared",
                "close": true
            },
            "problemMatcher": []
        }
    ]
}
'@
Write-ManagedFile "$rootPath\.vscode\tasks.json" $tasksJson
Write-Host "  Written: .vscode/tasks.json" -ForegroundColor Green

# -- .vscode/settings.json ---------------------------------------------
$settingsJson = @'
{
    "task.allowAutomaticTasks": "on"
}
'@
$settingsPath = "$rootPath\.vscode\settings.json"
if (-not (Test-Path $settingsPath)) {
    Write-ManagedFile $settingsPath $settingsJson
    Write-Host "  Written: .vscode/settings.json" -ForegroundColor Green
} else {
    Write-Host "  .vscode/settings.json already exists  -- skipping" -ForegroundColor Yellow
}

Write-Host "`n  All configuration files ready." -ForegroundColor Green

# =====================================================================
# STEP 8  -- Git init and launch VS Code
# =====================================================================
Show-Step 8 $totalSteps "Finishing Up"

Push-Location $rootPath
try {
    if (-not (Test-Path "$rootPath\.git")) {
        try { & git init 2>&1 | Out-Null } catch { }
        Write-Host "  Initialised git repository" -ForegroundColor Green
    }

    $gitUser  = git config user.name  2>$null
    $gitEmail = git config user.email 2>$null
    if ([string]::IsNullOrWhiteSpace($gitUser) -or [string]::IsNullOrWhiteSpace($gitEmail)) {
        Write-Host "  Warning: git user.name/email not configured  -- skipping initial commit." -ForegroundColor Yellow
    } else {
        try { & git add . 2>&1 | Out-Null } catch { }
        try { & git commit -m "chore: fabric agentic workspace setup" 2>&1 | Out-Null } catch { }
        Write-Host "  Initial commit created." -ForegroundColor Green
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "  Workspace: $rootPath" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  VS Code will now open your workspace." -ForegroundColor White
Write-Host "  Once open, select 1 - Fabric Workspace Master Agent from the" -ForegroundColor White
Write-Host "  Copilot Chat dropdown and type anything to start." -ForegroundColor White
Write-Host ""
Write-Host "  Managed files (overwritten on re-run):" -ForegroundColor DarkGray
Write-Host "    Agents: $($managedAgents -join ', ')" -ForegroundColor DarkGray
Write-Host "    Skills: $($managedSkills -join ', ')" -ForegroundColor DarkGray
Write-Host "  All other files in .github/ are left untouched." -ForegroundColor DarkGray
Write-Host ""
Read-Host "  Press Enter to open VS Code..."

& $vscodeCmd $rootPath
