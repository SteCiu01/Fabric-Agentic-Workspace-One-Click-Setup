<#
.SYNOPSIS
    Fabric Agentic Workspace  -- One-click bootstrap
.DESCRIPTION
    Run this script to set up a guided Fabric agentic workspace
    with a Fabric Master, executive reviewers, specialist teams, Microsoft & Kurt skills,
    custom TMDL and Pipeline skills, and copilot instructions.
    Once complete it opens the folder in VS Code  -- select Fabric Workspace Master
    from the Copilot Chat dropdown and type anything to start.
.NOTES
    Requirements: git, VS Code 1.117.0+ with GitHub Copilot.
    Optional CLIs (workspace works without them): Fabric CLI `fab` (recommended,
    `pip install ms-fabric-cli`) and Azure CLI `az` (fallback for SQL/TDS and
    non-Fabric token audiences).
    This script is the source of truth for managed agents and skills.
    It will overwrite its own files but leave unmanaged files untouched.
#>

# CI / automation entry points (both optional; normal interactive install ignores them):
#   -EmitAgentsTo <dir>  Dry-run: generate agents + config into <dir> and exit, with NO
#                        prerequisite checks, repo cloning, tool installs or VS Code launch.
#                        Used by tests/Generated.Tests.ps1 to validate real generated output.
#   -VerifyRoot <dir>    Re-hash the managed files in an installed workspace against its
#                        installed-manifest.json and report drift (exit 1 on any drift).
param(
    [string]$EmitAgentsTo,
    [string]$VerifyRoot
)

# Keep the window open on any error so the user can read it
$ErrorActionPreference = 'Stop'
$productVersion = '0.7.2'
$workspaceFileName = 'Fabric-Agentic-Workspace.code-workspace'

# SHA256 helper that does not hard-depend on the Get-FileHash cmdlet. A Windows
# PowerShell 5.1 child launched from PowerShell 7 (as on the CI runner) can
# inherit a PSModulePath that omits the 5.1 Utility module path, leaving
# Get-FileHash unresolved; in that case fall back to .NET so integrity hashing
# always works. Returns an uppercase hex string, matching Get-FileHash.
function Get-Sha256Hex ([string]$LiteralPath) {
    if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) {
        return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

# Force-refresh a vendor clone to its upstream state. The installer treats the
# vendor repositories (skills-for-fabric, power-bi-agentic-development) as
# authoritative-FROM-UPSTREAM: every run mirrors live upstream and any local
# edit is deliberately discarded so the references never drift. To stay
# recoverable, a dirty working tree (including untracked files) is stashed onto
# a timestamped stash BEFORE the hard reset, so nothing is ever silently lost.
function Update-VendorClone ([string]$Repo, [string]$Label, [string]$ExpectedRemote = $null) {
    if (-not (Test-Path -LiteralPath $Repo)) { return }
    # git writes progress to stderr; under the script-wide EAP=Stop, `2>&1` turns
    # that into a terminating error and the reset below would never run.
    $ErrorActionPreference = 'Continue'
    try {
        # Identity guard: the folder must be the ROOT of its own repository. A vendor
        # folder that lost its .git (or a stray directory of the same name) would make
        # git discover the OUTER workspace repository and stash/reset THAT instead.
        $top = (& git -C $Repo rev-parse --show-toplevel 2>$null | Select-Object -First 1)
        $repoFull = [IO.Path]::GetFullPath($Repo).TrimEnd('\', '/')
        $topFull = if ($top) { try { [IO.Path]::GetFullPath(([string]$top).Replace('/', '\')).TrimEnd('\', '/') } catch { '' } } else { '' }
        if (-not $topFull -or -not $topFull.Equals($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "    ${Label}: folder is not the root of its own Git repository -- left untouched (move it aside to let the installer re-clone)." -ForegroundColor Yellow
            return
        }
        if ($ExpectedRemote) {
            $originUrl = (& git -C $Repo config --get remote.origin.url 2>$null | Select-Object -First 1)
            $norm = { param($u) $v = ([string]$u).Trim().Replace('\', '/').TrimEnd('/'); if ($v.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) { $v = $v.Substring(0, $v.Length - 4) }; $v.ToLowerInvariant() }
            if (-not $originUrl -or ((& $norm $originUrl) -ne (& $norm $ExpectedRemote))) {
                Write-Host "    ${Label}: origin is '$originUrl', expected '$ExpectedRemote' -- not the vendor repository; left untouched." -ForegroundColor Yellow
                return
            }
        }
        & git -C $Repo fetch --prune origin 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    ${Label}: fetch failed (offline or blocked) -- keeping the current clone." -ForegroundColor Yellow
            return
        }
        $dirty = @(& git -C $Repo status --porcelain 2>$null)
        $stashName = $null
        if ($dirty.Count -gt 0) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $stashName = "installer-autostash $stamp"
            & git -C $Repo stash push -u -m $stashName 2>$null | Out-Null
            $stashExit = $LASTEXITCODE
            # Never hard-reset over edits we failed to preserve.
            if ($stashExit -ne 0 -or @(& git -C $Repo status --porcelain 2>$null).Count -gt 0) {
                Write-Host "    ${Label}: local edits could not be stashed (git stash exit $stashExit) -- clone left untouched. Commit or discard them, then re-run." -ForegroundColor Yellow
                return
            }
            Write-Host "    $Label had local edits  -- stashed before refresh (recover via 'git -C <repo> stash list')." -ForegroundColor Yellow
        }
        # origin/HEAD tracks the upstream default branch; reset --hard makes the
        # clone identical to live upstream regardless of prior local state.
        $before = (& git -C $Repo rev-parse --short HEAD 2>$null)
        $target = 'origin/HEAD'
        & git -C $Repo reset --hard $target 2>$null | Out-Null
        $resetExit = $LASTEXITCODE
        if ($resetExit -ne 0) {
            # Older clones may lack origin/HEAD; fall back to the current branch's upstream.
            $target = '@{upstream}'
            & git -C $Repo reset --hard $target 2>$null | Out-Null
            $resetExit = $LASTEXITCODE
        }
        # Success = the reset returned 0 AND HEAD really is the resolved upstream commit.
        $targetSha = (& git -C $Repo rev-parse --verify -q $target 2>$null)
        $headSha   = (& git -C $Repo rev-parse --verify -q HEAD 2>$null)
        if ($resetExit -eq 0 -and $targetSha -and $headSha -and $headSha -eq $targetSha) {
            $after = $headSha.Substring(0, 7)
            if ($before -ne $after) { Write-Host "    $Label refreshed: $before -> $after" -ForegroundColor Green }
            else { Write-Host "    $Label already at upstream ($after)." -ForegroundColor DarkGray }
        } else {
            Write-Host "    ${Label}: could not reset to upstream (git reset exit $resetExit) -- clone left as-is." -ForegroundColor Yellow
            if ($stashName) { Write-Host "    ${Label}: your local edits are safe in stash '$stashName' (git -C <repo> stash list / stash pop)." -ForegroundColor Yellow }
        }
    } catch {
        Write-Host "    ${Label}: refresh error -- $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# --- Integrity verification mode (-VerifyRoot) -----------------------
# Self-contained: reads installed-manifest.json and re-computes SHA256 for each
# recorded file, reporting missing/modified managed files. Makes the integrity
# manifest actually verifiable rather than self-attested.
if ($VerifyRoot) {
    $verifyTarget = [System.IO.Path]::GetFullPath($VerifyRoot)
    $verifyManifestPath = Join-Path $verifyTarget '.github\agent-docs\installed-manifest.json'
    if (-not (Test-Path -LiteralPath $verifyManifestPath)) {
        Write-Host "No installed-manifest.json found at $verifyManifestPath" -ForegroundColor Red
        exit 2
    }
    $verifyManifest = Get-Content -LiteralPath $verifyManifestPath -Raw | ConvertFrom-Json
    $verifyDrift = @(); $verifyMissing = @(); $verifyOk = 0
    foreach ($vf in $verifyManifest.files) {
        $vp = Join-Path $verifyTarget ($vf.path -replace '/', '\')
        if (-not (Test-Path -LiteralPath $vp -PathType Leaf)) { $verifyMissing += $vf.path; continue }
        $vsha = Get-Sha256Hex -LiteralPath $vp
        if ($vsha -ne $vf.sha256) { $verifyDrift += $vf.path } else { $verifyOk++ }
    }
    Write-Host "Integrity verification for $verifyTarget" -ForegroundColor Cyan
    Write-Host "  Verified OK : $verifyOk" -ForegroundColor Green
    if ($verifyMissing.Count) {
        Write-Host "  Missing     : $($verifyMissing.Count)" -ForegroundColor Yellow
        $verifyMissing | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkYellow }
    }
    if ($verifyDrift.Count) {
        Write-Host "  Modified    : $($verifyDrift.Count)" -ForegroundColor Red
        $verifyDrift | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkYellow }
    }
    if ($verifyMissing.Count -or $verifyDrift.Count) { exit 1 }
    Write-Host "  All managed files match the manifest." -ForegroundColor Green
    exit 0
}

# =====================================================================
# MAINTAINER MAP  -- where things live in this file (collapse #regions in VS Code)
#   AGENT MANIFEST          embedded JSON source of truth (schema-validated)
#   PACKAGE MANIFEST        list of installer-managed files
#   Helper functions        step banners, managed-file writer, tool detection
#   STEP 1..9               the install flow (folders, skills, agents, config)
# The embedded agent manifest is validated in CI against
#   schema/agent-manifest.schema.json  by  tests/Manifest.Tests.ps1
# Run the tests locally with:  Invoke-Pester   (from the repo root)
# =====================================================================

#region AGENT MANIFEST (embedded source of truth -- keep in sync with schema/agent-manifest.schema.json)
$agentManifestJson = @'
{
  "schemaVersion": 1,
  "productVersion": "0.7.2",
  "defaults": {
    "mode": "both",
    "tools": ["read","search"],
    "conditionalSkills": [],
    "excludedSkills": ["unrelated vendor skills"],
    "artifactTypes": [],
    "writePermissions": "assigned owned paths only; inspect before edit",
    "defaultRisk": "medium",
    "validationResponsibilities": ["validate every mutation and report evidence"],
    "optionalToolRequestPermissions": "request through Team Lead and Master; never install directly",
    "sourceControlPermissions": "no force push, branch deletion, secret commit, or unapproved merge",
    "environmentRestrictions": "PROD read-only by default; unknown environment requires clarification"
  },
  "agents": [
    {"id":"fabric-workspace-master","displayName":"Fabric Workspace Master","filename":"00-fabric-workspace-master.agent.md","level":"executive","department":"executive","parent":null,"allowedChildren":["Fabric Solution Architect","Integration QA & Change Controller","Semantic Model Team Lead","Reporting Team Lead","Data Engineering Team Lead","Fabric Administration & Governance Team Lead","ALM & DevOps Team Lead","Applications & Integration Team Lead","Capability Maintenance Team Lead"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute"],"primarySkills":["fabric-orchestration","fabric-working-modes","fabric-source-control-safety","fabric-cli-policy"],"artifactTypes":["work orders","consolidated outcomes"],"writePermissions":"orchestration only; delegate implementation","defaultRisk":"high","focus":"Classify intent, select the authoritative write surface, invoke the minimum teams, prevent conflicting writes, and own the final outcome."},
    {"id":"fabric-solution-architect","displayName":"Fabric Solution Architect","filename":"01-fabric-solution-architect.agent.md","level":"executive","department":"executive","parent":"fabric-workspace-master","allowedChildren":["Semantic Model Team Lead","Reporting Team Lead","Data Engineering Team Lead","Fabric Administration & Governance Team Lead","ALM & DevOps Team Lead","Applications & Integration Team Lead"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search"],"primarySkills":["fabric-orchestration","fabric-working-modes"],"artifactTypes":["architecture plans","dependency maps","rollback plans"],"writePermissions":"read-only planning","defaultRisk":"low","focus":"Design artifact boundaries, dependencies, sequence, ownership, validation, rollback, and team assignments without broad implementation."},
    {"id":"integration-qa-change-controller","displayName":"Integration QA & Change Controller","filename":"02-integration-qa-change-controller.agent.md","level":"executive","department":"executive","parent":"fabric-workspace-master","allowedChildren":[],"visibility":"visible","userInvocable":true,"tools":["read","search","execute"],"primarySkills":["fabric-orchestration","fabric-working-modes","fabric-source-control-safety"],"artifactTypes":["acceptance reports","release evidence"],"writePermissions":"read-only validation; return defects to Master","defaultRisk":"low","focus":"Validate cross-artifact references, environment and branch alignment, security, privacy, coherent diffs, rollback, and release readiness."},

    {"id":"semantic-model-team-lead","displayName":"Semantic Model Team Lead","filename":"10-semantic-model-team-lead.agent.md","level":"team-lead","department":"semantic-model","parent":"fabric-workspace-master","allowedChildren":["Model Architecture Agent","Relationships & Storage Mode Agent","TMDL Agent","DAX Agent","Semantic Security & AI Metadata Agent","Semantic Validation & Performance Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-tmdl","fabric-working-modes","fabric-cli-policy"],"conditionalSkills":["Microsoft semantic model and Direct Lake skills","Kurt TMDL, DAX, TE2, BPA, and performance skills"],"artifactTypes":["semantic models","TMDL","DAX"],"focus":"Decompose semantic work, select TE2, Modeling MCP/TOM, TMDL, fab, or sqlcmd, coordinate dependencies, and own model-wide validation."},
    {"id":"model-architecture-agent","displayName":"Model Architecture Agent","filename":"11-model-architecture.agent.md","level":"worker","department":"semantic-model","parent":"semantic-model-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search"],"primarySkills":["fabric-tmdl"],"conditionalSkills":["Microsoft Direct Lake guidance","Kurt semantic architecture skills"],"artifactTypes":["model architecture recommendations"],"writePermissions":"normally read-only","defaultRisk":"low","focus":"Assess grain, fact and dimension boundaries, star schema, Direct Lake versus Import, composites, and calculation-group architecture."},
    {"id":"relationships-storage-mode-agent","displayName":"Relationships & Storage Mode Agent","filename":"12-relationships-storage-mode.agent.md","level":"worker","department":"semantic-model","parent":"semantic-model-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-tmdl"],"conditionalSkills":["Microsoft Direct Lake guidance","Kurt relationship skills"],"artifactTypes":["relationships","storage modes"],"focus":"Implement and validate cardinality, filter direction, ambiguity, bridges, integrity, storage modes, and Direct Lake behavior."},
    {"id":"tmdl-agent","displayName":"TMDL Agent","filename":"13-tmdl.agent.md","level":"worker","department":"semantic-model","parent":"semantic-model-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-tmdl"],"conditionalSkills":["Kurt TMDL and PBIP skills"],"artifactTypes":["TMDL files","semantic model metadata"],"focus":"Inspect before editing tables, columns, hierarchies, partitions, expressions, cultures, and PBIP semantic-model files; preserve house style and validate."},
    {"id":"dax-agent","displayName":"DAX Agent","filename":"14-dax.agent.md","level":"worker","department":"semantic-model","parent":"semantic-model-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-tmdl"],"conditionalSkills":["Kurt DAX skills"],"artifactTypes":["DAX measures","DAX queries","calculation groups"],"focus":"Create and validate measures, time intelligence, calculation groups, context behavior, formats, regression queries, and performance."},
    {"id":"semantic-security-ai-metadata-agent","displayName":"Semantic Security & AI Metadata Agent","filename":"15-semantic-security-ai-metadata.agent.md","level":"worker","department":"semantic-model","parent":"semantic-model-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-tmdl"],"conditionalSkills":["Microsoft semantic security and AI guidance"],"artifactTypes":["RLS","OLS","roles","AI metadata"],"defaultRisk":"high","focus":"Own RLS, OLS, roles, descriptions, synonyms, AI instructions, schemas, verified-answer metadata, and explicit security-impact validation."},
    {"id":"semantic-validation-performance-agent","displayName":"Semantic Validation & Performance Agent","filename":"16-semantic-validation-performance.agent.md","level":"worker","department":"semantic-model","parent":"semantic-model-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-tmdl","fabric-cli-policy"],"conditionalSkills":["Kurt BPA and performance skills"],"artifactTypes":["BPA results","schema checks","performance reports"],"writePermissions":"read-only unless a safe fix is approved","defaultRisk":"low","focus":"Run TE2 BPA, schema, relationship, VertiPaq, Direct Lake, DAX regression, and storage validation."},

    {"id":"reporting-team-lead","displayName":"Reporting Team Lead","filename":"20-reporting-team-lead.agent.md","level":"team-lead","department":"reporting","parent":"fabric-workspace-master","allowedChildren":["Report Planning & UX Agent","PBIR Authoring Agent","Theme & Formatting Agent","Advanced & Custom Visuals Agent","Paginated Reports Agent","Report QA & Desktop Verification Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-working-modes","fabric-cli-policy"],"conditionalSkills":["Kurt PBIR, report, theme, Deneb, custom visual, and paginated skills"],"artifactTypes":["PBIR reports","themes","paginated reports"],"focus":"Turn requirements into a report plan, coordinate PBIR implementation and semantic dependencies, serialize visual/theme ownership, and require report QA."},
    {"id":"report-planning-ux-agent","displayName":"Report Planning & UX Agent","filename":"21-report-planning-ux.agent.md","level":"worker","department":"reporting","parent":"reporting-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search"],"primarySkills":[],"conditionalSkills":["Kurt report planning and UX skills"],"artifactTypes":["report design contracts"],"writePermissions":"read-only planning","defaultRisk":"low","focus":"Define audience, business questions, page plan, navigation, visual selection, accessibility, interactions, and required measures before implementation."},
    {"id":"pbir-authoring-agent","displayName":"PBIR Authoring Agent","filename":"22-pbir-authoring.agent.md","level":"worker","department":"reporting","parent":"reporting-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-cli-policy"],"conditionalSkills":["Kurt pbir-cli and pbir-format skills"],"artifactTypes":["PBIR pages","visuals","bindings","filters","bookmarks"],"focus":"Use pbir first for report structure and visuals, verify current help, validate after each mutation, and use controlled direct PBIR only as fallback."},
    {"id":"theme-formatting-agent","displayName":"Theme & Formatting Agent","filename":"23-theme-formatting.agent.md","level":"worker","department":"reporting","parent":"reporting-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","edit"],"primarySkills":[],"conditionalSkills":["Kurt report theme skills"],"artifactTypes":["report themes","format properties"],"focus":"Own typography, palette, spacing, conditional formatting, branding, and accessibility; never edit the same visual concurrently with PBIR Authoring."},
    {"id":"advanced-custom-visuals-agent","displayName":"Advanced & Custom Visuals Agent","filename":"24-advanced-custom-visuals.agent.md","level":"worker","department":"reporting","parent":"reporting-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","edit"],"primarySkills":[],"conditionalSkills":["Kurt Deneb, SVG, and custom-visual skills"],"artifactTypes":["Deneb specs","SVG","custom visual configuration"],"focus":"Implement Deneb, SVG, Python/R visuals, custom visuals, and advanced interactions only when the design requires them."},
    {"id":"paginated-reports-agent","displayName":"Paginated Reports Agent","filename":"25-paginated-reports.agent.md","level":"worker","department":"reporting","parent":"reporting-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","edit"],"primarySkills":[],"conditionalSkills":["Microsoft and Kurt paginated report skills"],"artifactTypes":["paginated report definitions"],"focus":"Own paginated definitions, parameters, data sources, layout, rendering, and export validation."},
    {"id":"report-qa-desktop-agent","displayName":"Report QA & Desktop Verification Agent","filename":"26-report-qa-desktop-verification.agent.md","level":"worker","department":"reporting","parent":"reporting-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-cli-policy"],"conditionalSkills":["Kurt PBIR validation skills"],"artifactTypes":["report validation evidence","screenshots"],"writePermissions":"read-only verification","defaultRisk":"low","focus":"Run pbir validation and available Desktop refresh/screenshots; detect overlap, truncation, blanks, broken bindings, accessibility, and theme defects."},

    {"id":"data-engineering-team-lead","displayName":"Data Engineering Team Lead","filename":"30-data-engineering-team-lead.agent.md","level":"team-lead","department":"data-engineering","parent":"fabric-workspace-master","allowedChildren":["Notebook & Spark Agent","Lakehouse, Delta & MLV Agent","Warehouse SQL Agent","SQL Database Agent","Dataflows Gen2 Agent","Pipeline Orchestration Agent","Real-Time Intelligence Agent","Fabric Intelligence & Ontology Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-pipelines","fabric-working-modes","fabric-cli-policy"],"conditionalSkills":["Microsoft Fabric engineering skills"],"artifactTypes":["notebooks","lakehouses","warehouses","SQL databases","dataflows","pipelines","RTI"],"focus":"Coordinate source-to-serving engineering and its semantic dependencies, assign one artifact owner, and validate data and orchestration."},
    {"id":"notebook-spark-agent","displayName":"Notebook & Spark Agent","filename":"31-notebook-spark.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":[],"conditionalSkills":["Microsoft Spark and notebook skills"],"artifactTypes":["Fabric notebooks","PySpark","Spark SQL"],"focus":"Author and validate PySpark, Spark SQL, notebooks, sessions, remote execution, dependencies, and notebook quality."},
    {"id":"lakehouse-delta-mlv-agent","displayName":"Lakehouse, Delta & MLV Agent","filename":"32-lakehouse-delta-mlv.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":[],"conditionalSkills":["Microsoft Lakehouse, Delta, medallion, MLV, shortcut, and OneLake skills"],"artifactTypes":["Delta tables","lakehouses","materialized lake views","shortcuts"],"focus":"Own Delta, medallion, MLV, incremental processing, shortcuts, schema evolution, and optimization; request DuckDB only through approval."},
    {"id":"warehouse-sql-agent","displayName":"Warehouse SQL Agent","filename":"33-warehouse-sql.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-cli-policy"],"conditionalSkills":["Microsoft Warehouse skills"],"artifactTypes":["Warehouse DDL","DML","SQL validation"],"focus":"Design and validate Fabric Warehouse and SQL analytics endpoint DDL, DML, serving, and performance using sqlcmd when available."},
    {"id":"sql-database-agent","displayName":"SQL Database Agent","filename":"34-sql-database.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-cli-policy"],"conditionalSkills":["Microsoft Fabric SQL Database skills"],"artifactTypes":["Fabric SQL Database schemas","procedures","queries"],"focus":"Handle Fabric SQL Database OLTP, procedures, temporal, JSON, vectors, security, and diagnostics distinctly from Warehouse work."},
    {"id":"dataflows-gen2-agent","displayName":"Dataflows Gen2 Agent","filename":"35-dataflows-gen2.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":[],"conditionalSkills":["Microsoft Dataflows Gen2 and Power Query skills"],"artifactTypes":["Dataflows Gen2 definitions","Power Query M"],"focus":"Own Power Query M, connectors, previews, destinations, refresh behavior, and failure diagnosis for Dataflows Gen2."},
    {"id":"pipeline-orchestration-agent","displayName":"Pipeline Orchestration Agent","filename":"36-pipeline-orchestration.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-pipelines"],"conditionalSkills":["Microsoft pipeline skills"],"artifactTypes":["Fabric pipeline definitions","schedules"],"focus":"Implement pipeline activities, notebooks, dataflows, copy, variables, schedules, dependencies, retry, and failure handling with schema validation."},
    {"id":"real-time-intelligence-agent","displayName":"Real-Time Intelligence Agent","filename":"37-real-time-intelligence.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":[],"conditionalSkills":["Microsoft Eventhouse, KQL, Eventstream, and Activator skills"],"artifactTypes":["Eventhouse","KQL","Eventstream","Activator"],"focus":"Own real-time Fabric artifacts, KQL behavior, ingestion, monitoring, and operational validation."},
    {"id":"fabric-intelligence-ontology-agent","displayName":"Fabric Intelligence & Ontology Agent","filename":"38-fabric-intelligence-ontology.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":[],"conditionalSkills":["Microsoft FabricIQ, Ontology, and Data Agent skills"],"artifactTypes":["ontologies","FabricIQ assets","Data Agents"],"focus":"Handle FabricIQ, Ontology, Data Agents, and related knowledge capabilities while checking current product behavior."},

    {"id":"fabric-administration-governance-team-lead","displayName":"Fabric Administration & Governance Team Lead","filename":"40-fabric-administration-governance-team-lead.agent.md","level":"team-lead","department":"administration-governance","parent":"fabric-workspace-master","allowedChildren":["Workspace & Capacity Administration Agent","Security, Access & Governance Agent","Monitoring, Catalog & Operations Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-working-modes","fabric-cli-policy"],"conditionalSkills":["Microsoft administration, governance, and monitoring skills"],"artifactTypes":["workspace settings","capacity settings","governance policy","operations evidence"],"defaultRisk":"high","focus":"Coordinate workspace, capacity, access, governance, monitoring, catalog, and operational safety with explicit approval for destructive changes."},
    {"id":"workspace-capacity-administration-agent","displayName":"Workspace & Capacity Administration Agent","filename":"41-workspace-capacity-administration.agent.md","level":"worker","department":"administration-governance","parent":"fabric-administration-governance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-cli-policy"],"conditionalSkills":["Microsoft workspace and capacity skills"],"artifactTypes":["workspace and capacity configuration"],"defaultRisk":"high","focus":"Administer workspaces, capacities, settings, assignments, and cost awareness; require approval for destructive or production-impacting actions."},
    {"id":"security-access-governance-agent","displayName":"Security, Access & Governance Agent","filename":"42-security-access-governance.agent.md","level":"worker","department":"administration-governance","parent":"fabric-administration-governance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":[],"conditionalSkills":["Microsoft security and governance skills"],"artifactTypes":["roles","permissions","governance controls"],"defaultRisk":"high","focus":"Own workspace roles, Entra groups, least privilege, permissions, governance, and security-boundary validation."},
    {"id":"monitoring-catalog-operations-agent","displayName":"Monitoring, Catalog & Operations Agent","filename":"43-monitoring-catalog-operations.agent.md","level":"worker","department":"administration-governance","parent":"fabric-administration-governance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-cli-policy"],"conditionalSkills":["Microsoft monitoring and catalog skills"],"artifactTypes":["inventory","job status","incident findings"],"writePermissions":"read-only diagnosis by default","defaultRisk":"low","focus":"Search catalog and inventory, inspect jobs and refreshes, monitor status, and diagnose failures without unapproved remediation."},

    {"id":"alm-devops-team-lead","displayName":"ALM & DevOps Team Lead","filename":"50-alm-devops-team-lead.agent.md","level":"team-lead","department":"alm-devops","parent":"fabric-workspace-master","allowedChildren":["GitHub Source Control Agent","Azure DevOps Agent","Fabric Git Integration Agent","Deployment & Release Agent","Power BI ALM Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-source-control-safety","fabric-working-modes","fabric-cli-policy"],"conditionalSkills":["Kurt PBIP and pbi-tools skills","Microsoft Fabric Git guidance"],"artifactTypes":["branches","pull requests","pipelines","releases","Fabric Git mappings"],"focus":"Own Git, GitHub, Azure DevOps, Fabric Git integration, release sequencing, and Power BI ALM; tool installation belongs to Maintenance."},
    {"id":"github-source-control-agent","displayName":"GitHub Source Control Agent","filename":"51-github-source-control.agent.md","level":"worker","department":"alm-devops","parent":"alm-devops-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-source-control-safety","fabric-cli-policy"],"artifactTypes":["Git branches","GitHub PRs","Actions","releases"],"focus":"Use Git and gh for authorized branches, commits, pull requests, reviews, Actions, releases, and repository settings; never expose credentials."},
    {"id":"azure-devops-agent","displayName":"Azure DevOps Agent","filename":"52-azure-devops.agent.md","level":"worker","department":"alm-devops","parent":"alm-devops-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-source-control-safety","fabric-cli-policy"],"artifactTypes":["Azure Repos PRs","pipelines","boards","project configuration"],"focus":"Use Git and approved az devops/repos/pipelines/boards commands for Azure DevOps work, respecting repository topology and auth policy."},
    {"id":"fabric-git-integration-agent","displayName":"Fabric Git Integration Agent","filename":"53-fabric-git-integration.agent.md","level":"worker","department":"alm-devops","parent":"alm-devops-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-source-control-safety","fabric-working-modes"],"conditionalSkills":["Microsoft Fabric Git integration guidance"],"artifactTypes":["workspace-branch mappings","Fabric Git status"],"defaultRisk":"high","focus":"Inspect and operate Fabric Git status, commit, update, mapping, and conflict workflows without inferring permission to overwrite either side."},
    {"id":"deployment-release-agent","displayName":"Deployment & Release Agent","filename":"54-deployment-release.agent.md","level":"worker","department":"alm-devops","parent":"alm-devops-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-source-control-safety","fabric-working-modes"],"artifactTypes":["release plans","deployment pipeline evidence","release notes"],"defaultRisk":"high","focus":"Sequence DEV to TEST to PROD, PRs, deployment pipelines, parameters, release checks, rollback, and notes without assuming branch names."},
    {"id":"power-bi-alm-agent","displayName":"Power BI ALM Agent","filename":"55-power-bi-alm.agent.md","level":"worker","department":"alm-devops","parent":"alm-devops-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-cli-policy","fabric-source-control-safety"],"conditionalSkills":["Kurt pbi-tools and PBIP skills"],"artifactTypes":["PBIX extraction","PBIP builds","deployment packages"],"focus":"Use pbi-tools for PBIX/PBIP extraction, build, CI/CD, deployment, and ALM validation—not routine PBIR visual editing."},

    {"id":"applications-integration-team-lead","displayName":"Applications & Integration Team Lead","filename":"60-applications-integration-team-lead.agent.md","level":"team-lead","department":"applications-integration","parent":"fabric-workspace-master","allowedChildren":["Python & Fabric SDK Agent","REST, Authentication & XMLA Agent","SQL, ODBC & Data Access Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-working-modes","fabric-cli-policy"],"conditionalSkills":["Microsoft SDK, REST, SQL consumption, and authentication skills"],"artifactTypes":["applications","SDK utilities","REST integrations","data-access code"],"focus":"Coordinate custom applications, SDK, REST/XMLA, authentication, ODBC, and data access without leaking secrets."},
    {"id":"python-fabric-sdk-agent","displayName":"Python & Fabric SDK Agent","filename":"61-python-fabric-sdk.agent.md","level":"worker","department":"applications-integration","parent":"applications-integration-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":[],"conditionalSkills":["Microsoft Fabric SDK and Python skills"],"artifactTypes":["Python applications","SDK utilities"],"focus":"Build Python applications, SDK clients, Azure Identity integrations, APIs, processing, and local utilities with safe dependency handling."},
    {"id":"rest-authentication-xmla-agent","displayName":"REST, Authentication & XMLA Agent","filename":"62-rest-authentication-xmla.agent.md","level":"worker","department":"applications-integration","parent":"applications-integration-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-cli-policy"],"conditionalSkills":["Microsoft REST and authentication guidance"],"artifactTypes":["REST clients","XMLA operations","authentication configurations"],"defaultRisk":"high","focus":"Handle Fabric/Power BI REST, az rest, audiences, Entra, SPN, managed identity, and XMLA with no secrets in commands or source."},
    {"id":"sql-odbc-data-access-agent","displayName":"SQL, ODBC & Data Access Agent","filename":"63-sql-odbc-data-access.agent.md","level":"worker","department":"applications-integration","parent":"applications-integration-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-cli-policy"],"conditionalSkills":["Microsoft SQL consumption skills"],"artifactTypes":["ODBC clients","SQLAlchemy code","parameterized queries"],"focus":"Own sqlcmd, ODBC, pyodbc, SQLAlchemy, Warehouse/endpoint/database connectivity, bulk operations, and parameterized validation."},

    {"id":"capability-maintenance-team-lead","displayName":"Capability Maintenance Team Lead","filename":"70-capability-maintenance-team-lead.agent.md","level":"team-lead","department":"capability-maintenance","parent":"fabric-workspace-master","allowedChildren":["Upstream Repository Sync Agent","Skill Inventory & Mapping Agent","Agent Coverage & Organization Agent","Environment & Tooling Agent","Installer Health & Regression Agent","Managed File Review Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-maintenance","fabric-cli-policy","fabric-source-control-safety"],"artifactTypes":["vendor state","skill inventory","tool status","maintenance reports","installer evidence"],"focus":"Own vendor sync, skill inventory, organization, approved tool installation and updates, failed-install remediation, managed-file review, and workspace regression checks."},
    {"id":"upstream-repository-sync-agent","displayName":"Upstream Repository Sync Agent","filename":"71-upstream-repository-sync.agent.md","level":"worker","department":"capability-maintenance","parent":"capability-maintenance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-maintenance"],"artifactTypes":["vendor repository state"],"writePermissions":"vendor force-refresh to upstream only; stash local edits before hard reset, never hand-edit vendor content","defaultRisk":"medium","focus":"Force-refresh the Microsoft and Kurt vendor repositories to their upstream state so the clones always mirror live upstream, stash any local edits before the hard reset so nothing is lost, record the resulting commits, and report diverged repositories."},
    {"id":"skill-inventory-mapping-agent","displayName":"Skill Inventory & Mapping Agent","filename":"72-skill-inventory-mapping.agent.md","level":"worker","department":"capability-maintenance","parent":"capability-maintenance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-maintenance"],"artifactTypes":["skill inventory","mapping report"],"focus":"Dynamically detect valid, invalid, duplicate, added, removed, renamed, changed, unmapped, and tool-assuming skills and refresh local inventory."},
    {"id":"agent-coverage-organization-agent","displayName":"Agent Coverage & Organization Agent","filename":"73-agent-coverage-organization.agent.md","level":"worker","department":"capability-maintenance","parent":"capability-maintenance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","edit"],"primarySkills":["fabric-maintenance","fabric-orchestration"],"artifactTypes":["coverage analysis","mapping proposals"],"focus":"Evaluate coverage, overlap, overload, gaps, team fit, workers, and teams; auto-apply only obvious low-risk mappings and seek approval for structural changes."},
    {"id":"environment-tooling-agent","displayName":"Environment & Tooling Agent","filename":"74-environment-tooling.agent.md","level":"worker","department":"capability-maintenance","parent":"capability-maintenance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-maintenance","fabric-cli-policy"],"artifactTypes":["tool status","installation plans","lockdown remediation reports"],"writePermissions":"approved environment/tool changes only","defaultRisk":"high","optionalToolRequestPermissions":"the only worker allowed to install default or optional tools, always after explicit user approval","focus":"Own current and future default-tool updates, failed installer follow-up, optional installation, locked-down laptop remediation, validation, rollback guidance, and tool-status refresh."},
    {"id":"installer-health-regression-agent","displayName":"Installer Health & Regression Agent","filename":"75-installer-health-regression.agent.md","level":"worker","department":"capability-maintenance","parent":"capability-maintenance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-maintenance"],"artifactTypes":["test results","installer diagnostics"],"writePermissions":"read-only validation","defaultRisk":"low","focus":"Validate source, manifests, templates, generated installer, clean/update installs, schemas, skills, tools, multi-root behavior, and privacy."},
    {"id":"managed-file-review-agent","displayName":"Managed File Review Agent","filename":"76-managed-file-review.agent.md","level":"worker","department":"capability-maintenance","parent":"capability-maintenance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","edit"],"primarySkills":["fabric-maintenance"],"artifactTypes":["managed-file diffs","review proposals"],"writePermissions":"apply user-requested managed-file changes only after explicit approval","defaultRisk":"high","focus":"Review requested differences between installer-managed files and local customisations without changing the original installer update behaviour; apply an approved amendment only when the user asks."}
  ]
}

'@
$agentManifest = $agentManifestJson | ConvertFrom-Json
#endregion AGENT MANIFEST
trap {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    Read-Host "`nPress Enter to close"
    exit 1
}

# =====================================================================
# PACKAGE MANIFEST  -- files managed by this installer
# These will be created or overwritten. All other files are left alone.
# =====================================================================
# The manifest encodes each agent's team-grouped number as a two-digit filename
# prefix (00, 10, 11, ...). The dropdown label and the written file share ONE
# three-digit form (000, 010, 011, ...) so the picker number always matches the
# file on disk. Derive the managed (written) names in that three-digit form.
$managedAgents = @($agentManifest.agents | ForEach-Object {
    $_.filename -replace '^\d+', ('{0:D3}' -f [int]([regex]::Match([string]$_.filename, '^\d+').Value))
})
$legacyManagedAgents = @(
    '1-fabric-workspace-master-agent.agent.md','2-fabric-skills-maintainer.agent.md',
    '3-semantic-model-agent.agent.md','4-fabric-data-engineer.agent.md',
    '5-fabric-admin.agent.md','6-fabric-app-dev.agent.md',
    '7-fabric-reports-agent.agent.md','8-fabric-pipelines-agent.agent.md',
    '9-fabric-devops-agent.agent.md','76-update-conflict-reconciliation.agent.md'
)
# Earlier 0.6.x builds wrote the same agents with two-digit prefixes. Remove
# those on update so the three-digit files do not create duplicates.
$legacyManagedAgents += @($agentManifest.agents | ForEach-Object { [string]$_.filename })
$managedSkills = @(
    'fabric-tmdl',
    'fabric-pipelines',
    'fabric-cli-policy'
)
$managedConfigs = @(
    '.github\copilot-instructions.md',
    '.github\agent-docs\starting-flow.md',
    '.github\agent-docs\working-flow-reference.md',
    '.github\agent-docs\Get-SessionStatus.ps1',
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
    # Write UTF-8 WITHOUT a BOM. PowerShell 5.1's `Set-Content -Encoding UTF8`
    # prepends a BOM (EF BB BF), which breaks VS Code's YAML frontmatter
    # detection in .agent.md files (the leading BOM sits before `---`, so the
    # header is treated as absent and `user-invocable: false` is ignored,
    # leaving delegated worker agents visible in the Copilot dropdown).
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# -- Helper: locate a REAL, runnable Python interpreter -----------------
# On Windows, `python` / `python3` on PATH are often the Microsoft Store
# "App execution alias" stubs that only print "Python was not found" and exit
# non-zero. Get-Command still finds them, so we must actually RUN --version and
# confirm a real "Python 3.x" before trusting the interpreter for pip installs.
# Returns the usable launcher string (e.g. 'py' / 'python') or $null.
function Find-RealPython {
    foreach ($cand in @('py', 'python', 'python3')) {
        if (-not (Get-Command $cand -ErrorAction SilentlyContinue)) { continue }
        try {
            $v = (& $cand --version 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $v -match 'Python\s+3') { return $cand }
        } catch { }
    }
    return $null
}

# -- Helper: refresh the current-session PATH from Machine + User scopes -
# A freshly installed tool updates the persisted PATH but not the in-memory one,
# which is the usual reason a successful install still reports "not found".
function Update-InstallerPath {
    $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

# -- Helper: add a dir to the session PATH and persist it (User scope) ---
# Idempotent. Ensures a newly installed tool resolves both now and on the next
# VS Code/terminal launch without a manual restart.
function Add-DirToPath {
    param([string]$Dir)
    if (-not $Dir) { return }
    # Always move the requested directory to the front of the current session,
    # even when it already exists later in PATH. Merely checking for presence
    # leaves an older machine-wide executable ahead of a newer per-user one.
    $normalizedDir = $Dir.TrimEnd('\')
    $sessionRest = @($env:Path -split ';' | Where-Object {
        $_ -and ($_.TrimEnd('\') -ine $normalizedDir)
    })
    $env:Path = (@($Dir) + $sessionRest) -join ';'
    try {
        $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
        $userEntries = @($userPath -split ';' | Where-Object { $_ })
        if (-not @($userEntries | Where-Object { $_.TrimEnd('\') -ieq $normalizedDir })) {
            [System.Environment]::SetEnvironmentVariable(
                'Path', ((@($userEntries) + $Dir) -join ';'), 'User')
        }
    } catch { }
}

# -- Helper: make tools installed by THIS or a PREVIOUS run discoverable -
# The #1 reason a freshly-installed CLI still reports "not found" is that its
# folder is not on the in-memory PATH yet. This refreshes PATH from the registry
# (Machine + User) and proactively adds the Python user/script dirs where pip
# drops console scripts (fab.exe, az.exe). Idempotent; safe to call repeatedly.
# Calling it at the START of the prerequisite step is what lets run N recognise
# what run N-1 actually installed -- so the "not found" list shrinks each run.
function Sync-ToolPaths {
    # 1. Pull the persisted PATH (a previous run may have appended to User scope).
    $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'

    # 2. Ask a real Python where it drops scripts and add those dirs.
    $py = Find-RealPython
    if ($py) {
        try {
            $dirs = & $py -c "import site,sys,os; print(os.path.join(sys.prefix,'Scripts')); print(os.path.join(site.getuserbase(),'Scripts'))" 2>$null
            foreach ($d in @($dirs)) { if ($d -and (Test-Path $d)) { Add-DirToPath $d } }
        } catch { }
    }

    # 3. Sweep the common per-user Python Scripts locations -- covers the case
    #    where the interpreter that installed the package is no longer on PATH.
    foreach ($root in @("$env:APPDATA\Python", "$env:LOCALAPPDATA\Programs\Python")) {
        if (Test-Path $root) {
            Get-ChildItem $root -Recurse -Directory -Filter 'Scripts' -ErrorAction SilentlyContinue |
                ForEach-Object { Add-DirToPath $_.FullName }
        }
    }

    # 4. Prefer portable tools installed by this installer. Windows normally
    #    builds a new process PATH as Machine + User, so an older machine-wide
    #    executable (for example C:\Program Files\GitHub CLI\gh.exe) can win over
    #    a newer per-user portable copy even though the update succeeded. Put the
    #    exact installer-managed executable folders first for this run and for the
    #    VS Code process launched at the end of setup.
    $managedPortableTools = @(
        @{ Root = "$env:LOCALAPPDATA\Programs\gh";            Exe = 'gh.exe' },
        @{ Root = "$env:LOCALAPPDATA\Programs\sqlcmd";        Exe = 'sqlcmd.exe' },
        @{ Root = "$env:LOCALAPPDATA\Programs\TabularEditor"; Exe = 'TabularEditor.exe' },
        @{ Root = "$env:LOCALAPPDATA\Programs\pbi-tools";     Exe = 'pbi-tools.exe' }
    )
    foreach ($managed in $managedPortableTools) {
        if (Test-Path $managed.Root) {
            $exe = Get-ChildItem $managed.Root -Recurse -File -Filter $managed.Exe -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($exe) { Add-DirToPath $exe.DirectoryName }
        }
    }
}

# -- Helper: resilient "is this CLI on PATH yet?" check ---------------------
# A just-installed CLI often fails a single Get-Command because its Scripts
# folder is not on the in-memory PATH yet. This re-syncs PATH and retries a few
# times, and as a last resort probes the known Python Scripts dirs on disk for
# the executable directly -- so a tool installed by this OR a previous run is
# recognised in the SAME run, without forcing the user to re-launch the installer.
function Test-CliResilient {
    param([string]$Name, [int]$Retries = 4, [string]$VersionPattern = $null)
    $isRunnable = {
        param([string]$CommandName)
        $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
        if (-not $cmd) { return $false }
        try {
            $output = & $cmd.Source --version 2>$null | Out-String
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) { return $false }
            # Same-named impostors exist (pyinvoke ships a `fab`): require the product's own banner.
            if ($VersionPattern -and ($output -notmatch $VersionPattern)) { return $false }
            return $true
        } catch { return $false }
    }
    for ($i = 0; $i -lt $Retries; $i++) {
        if (& $isRunnable $Name) { return $true }
        Sync-ToolPaths
        if (& $isRunnable $Name) { return $true }
        # Direct on-disk probe: pip drops <name>.exe/.cmd/.bat into a Scripts dir.
        foreach ($root in @("$env:APPDATA\Python", "$env:LOCALAPPDATA\Programs\Python")) {
            if (Test-Path $root) {
                $hit = Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue `
                         -Include "$Name.exe", "$Name.cmd", "$Name.bat" | Select-Object -First 1
                if ($hit) {
                    Add-DirToPath $hit.DirectoryName
                    if (& $isRunnable $Name) { return $true }
                }
            }
        }
        if ($i -lt $Retries - 1) { Start-Sleep -Milliseconds 400 }
    }
    return $false
}

# -- Helper: read VS Code's installed-extension list, resiliently -----------
# `code --list-extensions` can return empty/partial on the first call right
# after an install or on a slow/locked-down machine. Retry until it returns
# something rather than trusting a single (possibly empty) result.
function Get-InstalledVsCodeExtensions {
    param([string]$VsCode, [int]$Retries = 4)
    if (-not $VsCode) { return @() }
    for ($i = 0; $i -lt $Retries; $i++) {
        $list = & $VsCode --list-extensions 2>$null
        if ($list) { return @($list) }
        if ($i -lt $Retries - 1) { Start-Sleep -Milliseconds 400 }
    }
    return @()
}

# -- Helper: is a given VS Code extension present? --------------------------
# Authoritative source is the CLI's --list-extensions output. When that list is
# NON-EMPTY we trust it completely: an id that is absent means the extension is
# genuinely not installed. We deliberately do NOT fall back to a folder scan in
# that case, because an extension uninstalled via the CLI leaves its folder in
# .vscode\extensions (flagged in .obsolete) until VS Code restarts -- scanning
# would then report a removed extension as still installed (a false positive).
# Only when the CLI returns NOTHING (a transient failure on a slow/locked-down
# PC) do we scan on disk, and even then we skip folders marked obsolete.
function Test-VsCodeExtension {
    param([string]$Id, $List)
    if ($List -and @($List).Count -gt 0) {
        return (@($List) -contains $Id)
    }
    $pattern = '^' + [regex]::Escape($Id) + '-\d'
    foreach ($extRoot in @("$env:USERPROFILE\.vscode\extensions", "$env:USERPROFILE\.vscode-insiders\extensions")) {
        if (-not (Test-Path $extRoot)) { continue }
        # Build the set of folders VS Code has marked for removal (.obsolete is a
        # JSON map like { "publisher.id-1.2.3": true }).
        $obsolete = @{}
        $obsoleteFile = Join-Path $extRoot '.obsolete'
        if (Test-Path $obsoleteFile) {
            try {
                (Get-Content $obsoleteFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).PSObject.Properties |
                    ForEach-Object { $obsolete[$_.Name] = $true }
            } catch { }
        }
        $dirs = Get-ChildItem $extRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match $pattern -and -not $obsolete[$_.Name] }
        if ($dirs) { return $true }
    }
    return $false
}

# -- Helper: export the Windows trusted-root store to a PEM bundle ----------
# Locked-down corporate networks run TLS inspection (Zscaler / Netskope / etc.)
# that re-signs HTTPS with an internal root CA. VS Code's CLI downloads
# extensions through Node, which uses its OWN bundled CA list and therefore
# rejects that root with "self signed certificate in certificate chain" -- so
# `code --install-extension` fails even though browsers and pip (which use
# different trust stores) work fine. Exporting the Windows trusted roots (which
# DO include the corporate CA) to a PEM file and pointing Node at it via
# NODE_EXTRA_CA_CERTS lets the download validate. Reading the cert store needs
# no admin. Cached for the run; returns the bundle path or $null.
$script:CaBundlePath = $null
function Get-WindowsCaBundle {
    if ($script:CaBundlePath -and (Test-Path $script:CaBundlePath)) { return $script:CaBundlePath }
    try {
        $certs = Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root -ErrorAction SilentlyContinue
        if (-not $certs) { return $null }
        $sb = New-Object System.Text.StringBuilder
        foreach ($c in $certs) {
            $b64 = [Convert]::ToBase64String($c.RawData, 'InsertLineBreaks')
            [void]$sb.AppendLine('-----BEGIN CERTIFICATE-----')
            [void]$sb.AppendLine($b64)
            [void]$sb.AppendLine('-----END CERTIFICATE-----')
        }
        $path = Join-Path $env:LOCALAPPDATA 'fabric-agentic-ca-bundle.pem'
        Set-Content -Path $path -Value $sb.ToString() -Encoding ascii
        $script:CaBundlePath = $path
        return $path
    } catch { return $null }
}

# -- Helper: force-install a VS Code extension, robustly --------------------
# Replaces a bare `code --install-extension --force` call, fixing the two ways
# it silently fails on a locked-down corporate PC:
#   1. Under $ErrorActionPreference='Stop', the native command's progress text on
#      stderr (merged via 2>&1) is turned into a TERMINATING error -- so even a
#      successful install lands in the catch block and is reported as failed.
#      We run with a function-scoped EAP='Continue' and judge success by the
#      exit code + a --list-extensions check instead.
#   2. A TLS-inspection proxy makes the marketplace download fail the Node cert
#      check; we set NODE_EXTRA_CA_CERTS to the Windows trusted roots up front
#      (harmless off such networks -- it only ADDS already-trusted roots).
# Retries a few times. Returns $true only on a confirmed install.
function Install-VsCodeExtension {
    param([string]$VsCode, [string]$Id, [int]$Retries = 3)
    $ErrorActionPreference = 'Continue'   # function-scoped; native stderr won't throw
    if (-not $VsCode -or -not $Id) { return $false }

    if (-not $env:NODE_EXTRA_CA_CERTS) {
        $bundle = Get-WindowsCaBundle
        if ($bundle) { $env:NODE_EXTRA_CA_CERTS = $bundle }
    }

    for ($i = 0; $i -lt $Retries; $i++) {
        & $VsCode --install-extension $Id --force 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and
            (Test-VsCodeExtension -Id $Id -List (Get-InstalledVsCodeExtensions -VsCode $VsCode))) {
            return $true
        }
        Start-Sleep -Milliseconds 600
    }
    return (Test-VsCodeExtension -Id $Id -List (Get-InstalledVsCodeExtensions -VsCode $VsCode))
}

# -- Helper: ensure a REAL Python is available, installing if missing ----
# The Fabric CLI (fab) is a Python package, so without Python it cannot install.
# This force-installs Python (mirroring the Power Platform twin's pac/.NET
# bootstrap) so the common "fab won't install because Python is missing" case
# resolves itself. Tries, in order:
#   1. An existing real Python (Find-RealPython)
#   2. winget  (Python.Python.3.12, per-user, no admin)
#   3. The official python.org silent installer (pinned), per-user, no admin
# Refreshes PATH after each attempt. Returns a usable launcher string
# ('py'/'python') or $null on total failure -- never throws, never aborts setup.
function Ensure-Python {
    $py = Find-RealPython
    if ($py) { return $py }

    Write-Host "         No real Python found -- attempting to install Python 3.12 (required by the Fabric CLI)..." -ForegroundColor Yellow

    # -- Attempt 1: winget (per-user, no admin) -------------------------
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "         Trying winget: Python.Python.3.12 ..." -ForegroundColor DarkGray
        try {
            & winget install -e --id Python.Python.3.12 --scope user --silent `
                --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        } catch { }
        Update-InstallerPath
        $py = Find-RealPython
        if ($py) { Write-Host "         Python installed (via winget)." -ForegroundColor Green; return $py }
    }

    # -- Attempt 2: official python.org silent installer ----------------
    try {
        $pyVer = '3.12.10'
        $arch  = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'win32' }
        $url   = "https://www.python.org/ftp/python/$pyVer/python-$pyVer-$arch.exe"
        $exe   = Join-Path $env:TEMP "python-$pyVer-$arch.exe"
        Write-Host "         Downloading Python $pyVer from python.org ..." -ForegroundColor DarkGray
        if ((Get-FileBestEffort -Url $url -OutFile $exe) -and
            (Test-PublisherDownload -Url $url -Path $exe) -and
            (Test-StagedExecutable -Path $exe)) {
            Write-Host "         Installing Python silently (per-user, no admin; this can take a minute)..." -ForegroundColor DarkGray
            $proc = Start-Process $exe -ArgumentList '/quiet InstallAllUsers=0 PrependPath=1 Include_pip=1' -Wait -PassThru
            if ($proc.ExitCode -ne 0) { Write-Host "         Python installer exit code: $($proc.ExitCode)." -ForegroundColor DarkGray }
            Remove-Item $exe -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "         Python installer did not pass download/signature verification." -ForegroundColor Yellow
            Remove-Item $exe -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "         Python download/install failed: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
    Update-InstallerPath
    $py = Find-RealPython
    if ($py) { Write-Host "         Python installed (via python.org)." -ForegroundColor Green; return $py }

    return $null
}

# -- Helper: attempt an optional tool install, never fatal --------------
# Prompts the user, then tries each strategy in $Attempts (ordered list of
# @{ Exe = '<exe>'; Args = @(...) }) until $CheckCmd is satisfied. Strategies
# whose Exe is missing are skipped, so a blocked winget or missing pip does not
# stop us trying another route. On total failure it reports the captured cause
# (exit code + output) so the user knows WHY, and always returns control to the
# caller -- a failed optional install never aborts the setup.
function Try-InstallOptionalTool {
    param(
        [string]$Name,        # friendly name, e.g. "Fabric CLI (fab)"
        [string]$CheckCmd,    # command to detect presence, e.g. "fab"
        [array]$Attempts,     # ordered list of @{ Exe=..; Args=@(..) } strategies
        [string]$ManualUrl    # fallback manual install URL
    )
    # Install automatically -- no opt-out prompt. The goal is to set up as much
    # as possible up front; a failed optional install is reported but never fatal.
    Write-Host "    Installing $Name automatically..." -ForegroundColor White

    $anyRan = $false
    foreach ($attempt in $Attempts) {
        $exe = $attempt.Exe
        $eArgs = $attempt.Args
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
        $anyRan = $true
        Write-Host "    Trying: $exe $($eArgs -join ' ') ..." -ForegroundColor White
        $output = ''
        try { $output = & $exe @eArgs 2>&1 | Out-String } catch { $output = $_.Exception.Message }
        $code = $LASTEXITCODE

        # Refresh PATH so a freshly-installed command is visible this session.
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('Path', 'User')
        # pip drops console scripts either in the interpreter's own Scripts dir
        # (sys.prefix\Scripts) or, with --user, in the per-user Scripts dir
        # (%APPDATA%\Python\PythonXY\Scripts). Neither is guaranteed to be on
        # PATH yet -- add both so the CheckCmd test can find the freshly installed tool.
        if ($exe -match '(^|\\)(py|python|python3)(\.exe)?$') {
            try {
                $scriptDirs = & $exe -c "import site, sys, os; print(os.path.join(sys.prefix, 'Scripts')); print(os.path.join(site.getuserbase(), 'Scripts'))" 2>$null
                foreach ($sd in @($scriptDirs)) {
                    if ($sd -and (Test-Path $sd)) { Add-DirToPath $sd }
                }
            } catch { }
        }

        if (Get-Command $CheckCmd -ErrorAction SilentlyContinue) {
            Write-Host "    $Name installed successfully (via $exe)." -ForegroundColor Green
            return $true
        }
        Write-Host "    That method did not succeed (exit code: $code)." -ForegroundColor Yellow
        $reason = ($output -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 3) -join "`n      "
        if ($reason) { Write-Host "      $reason" -ForegroundColor DarkGray }
        Write-Host "    Trying next method if available..." -ForegroundColor DarkGray
    }

    # Last-ditch recovery: the package may have installed but landed in a Scripts
    # dir we didn't compute (e.g. pip reported a different layout). Search the
    # common per-user Python Scripts locations for the tool and add it to PATH.
    foreach ($root in @("$env:APPDATA\Python", "$env:LOCALAPPDATA\Programs\Python")) {
        if (Test-Path $root) {
            $hit = Get-ChildItem $root -Recurse -Filter "$CheckCmd.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) {
                Add-DirToPath $hit.DirectoryName
                if (Get-Command $CheckCmd -ErrorAction SilentlyContinue) {
                    Write-Host "    $Name installed successfully (found in $($hit.DirectoryName))." -ForegroundColor Green
                    return $true
                }
            }
        }
    }

    # Nothing worked -- explain why and how to recover.
    if (-not $anyRan) {
        Write-Host "    Cannot install automatically: no working installer (real Python/pip or winget) is available." -ForegroundColor Yellow
    }
    Write-Host "    Likely causes: corporate security policy blocking installs, no real Python/pip or winget, or no network access." -ForegroundColor DarkGray
    Write-Host "    Install it later when convenient -- either manually ($ManualUrl)," -ForegroundColor DarkGray
    Write-Host "    or just open the workspace and ask the Fabric agent to walk you through it." -ForegroundColor DarkGray
    Write-Host "    Continuing without $Name (the workspace works fine without it)." -ForegroundColor DarkGray
    return $false
}

# -- Helper: install Azure CLI into a dedicated venv at a SHORT path --------
# azure-cli has a very deep package tree (e.g.
#   azure\mgmt\recoveryservicesbackup\activestamp\aio\operations\_..._operations.py)
# that overflows the Windows 260-char MAX_PATH limit when pip unpacks it into the
# Microsoft Store Python's long site-packages path -- the install dies with
# "OSError: [Errno 2] No such file or directory". The fix is a virtual env whose
# base path is short. Crucially the venv must live in the USER-PROFILE ROOT, not
# under %LOCALAPPDATA%: the Store Python virtualizes AppData\Local and silently
# redirects a venv created there back into its long sandbox path, re-triggering
# MAX_PATH. A profile-root folder (%USERPROFILE%\.fabric-az) is not virtualized,
# stays short, and installs cleanly. Idempotent: re-uses an existing venv. Puts
# the venv's Scripts dir on PATH (persisted) so `az` resolves now and later.
# Returns $true if `az` is available afterwards; never throws.
function Install-AzCliViaVenv {
    param([string]$Python)
    $ErrorActionPreference = 'Continue'   # function-scoped; native stderr won't throw
    if (-not $Python) { $Python = Find-RealPython }
    if (-not $Python) { return $false }

    $venv    = Join-Path $env:USERPROFILE '.fabric-az'
    $scripts = Join-Path $venv 'Scripts'
    $venvPy  = Join-Path $scripts 'python.exe'

    # Append the venv Scripts dir to PATH (NOT prepend): the venv carries its own
    # python/pip and an unrelated `fab` (pyinvoke), so prepending would shadow the
    # user's real Python / Fabric CLI. Appending exposes only `az`, which lives
    # nowhere else. Persists to User scope so it survives into VS Code / new shells.
    $addAzToPath = {
        if ($env:Path -notlike "*$scripts*") { $env:Path = "$env:Path;$scripts" }
        try {
            $up = [System.Environment]::GetEnvironmentVariable('Path', 'User')
            if ($up -notlike "*$scripts*") {
                [System.Environment]::SetEnvironmentVariable(
                    'Path', ((@($up, $scripts) | Where-Object { $_ }) -join ';'), 'User')
            }
        } catch { }
    }

    # Already installed by a previous run? Re-use it (fast + idempotent).
    $azExisting = Get-ChildItem $scripts -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^az\.(cmd|bat|exe)$' } | Select-Object -First 1
    if ($azExisting) { & $addAzToPath; return $true }

    Write-Host "    Installing Azure CLI into an isolated environment (sidesteps the Windows" -ForegroundColor White
    Write-Host "    260-char path limit that breaks a normal pip install)... this can take a few minutes." -ForegroundColor White

    if (-not (Test-Path $venvPy)) {
        try { & $Python -m venv $venv 2>&1 | Out-Null } catch { }
    }
    if (-not (Test-Path $venvPy)) {
        Write-Host "    Could not create the isolated environment for Azure CLI." -ForegroundColor Yellow
        return $false
    }

    try { & $venvPy -m pip install --upgrade pip --quiet 2>&1 | Out-Null } catch { }
    try { & $venvPy -m pip install --upgrade --retries 5 --timeout 120 azure-cli 2>&1 | Out-Null } catch { }

    $azWrapper = Get-ChildItem $scripts -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -match '^az\.(cmd|bat|exe)$' } | Select-Object -First 1
    if ($azWrapper) { & $addAzToPath; return $true }
    return $false
}

# =====================================================================
# Tool inventory (tool-status.json) -- detection + per-tool opt-in install
# Agents read .github/agent-docs/tool-status.json and use <key>.found to
# decide whether a deterministic tool is available, then fall back gracefully.
# CLIs (fab/az/sqlcmd/te/pbir/gh/az devops/pbi-tools) are NOT frontmatter tools;
# they are binaries invoked through `execute`. This JSON is the availability gate.
# =====================================================================
$script:ToolStatus = [ordered]@{}

# Best-effort version string for a resolved command. Skipped for GUI tools
# (e.g. Tabular Editor) where a bare --version could launch the UI.
function Get-ToolVersion {
    param([string]$Exe, [string[]]$VersionArgs = @('--version'))
    if (-not $Exe) { return $null }
    try {
        $out = & $Exe @VersionArgs 2>$null | Select-Object -First 1
        if ($out) { return ([string]$out).Trim() }
    } catch { }
    return $null
}

# Resolve the first alias that exists, on PATH or in optional on-disk roots.
# Returns @{ command = <alias>; path = <full path or $null> } or $null.
function Resolve-ToolCommand {
    param([string[]]$Aliases, [string[]]$SearchRoots = @())
    foreach ($a in $Aliases) {
        $cmd = Get-Command $a -ErrorAction SilentlyContinue
        if ($cmd) {
            $p = $null
            try { $p = $cmd.Source } catch { }
            return @{ command = $a; path = $p }
        }
    }
    foreach ($root in $SearchRoots) {
        if (Test-Path $root) {
            foreach ($a in $Aliases) {
                $hit = Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue `
                         -Include "$a.exe", "$a.cmd", "$a.bat" | Select-Object -First 1
                if ($hit) { return @{ command = $a; path = $hit.FullName } }
            }
        }
    }
    return $null
}

# Record a normalized tool-status entry (flat top-level key -> <key>.found).
function Set-ToolStatus {
    param(
        [string]$Key, [bool]$Found,
        [string]$Command = $null, [string]$Path = $null, [string]$Version = $null,
        [string]$Category = 'specialist-cli', [string]$InstallMode = 'ask',
        [string]$Reason = $null, [string]$ExtensionId = $null, [string[]]$AliasesChecked = $null,
        [System.Collections.IDictionary]$Extra = $null
    )
    $entry = [ordered]@{
        found = $Found; version = $Version; command = $Command; path = $Path
        category = $Category; installMode = $InstallMode; reason = $Reason
    }
    if ($ExtensionId)    { $entry['extensionId'] = $ExtensionId }
    if ($AliasesChecked) { $entry['aliasesChecked'] = $AliasesChecked }
    if ($Extra) { foreach ($k in $Extra.Keys) { $entry[$k] = $Extra[$k] } }
    $script:ToolStatus[$Key] = $entry
}

# True if a prior tool-status.json already recorded this tool as declined, so
# re-runs (the installer is meant to be run a few times) stay quiet.
function Test-PriorDeclined {
    param($Prior, [string]$Key)
    if ($Prior -and $Prior.$Key -and ($Prior.$Key.found -eq $false) -and ($Prior.$Key.reason -like '*declined*')) {
        return $true
    }
    return $false
}

# Detect one optional specialist tool; if missing, explain provider/purpose and
# ask Y/N. On Yes run the (optional) install scriptblock best-effort, then
# re-detect. Always records a tool-status entry. Never throws / never blocks setup.
function Invoke-OptionalToolPrompt {
    param(
        [string]$Key, [string]$Name, [string]$Purpose, [string]$Provider,
        [string[]]$Aliases, [string[]]$SearchRoots = @(),
        [scriptblock]$Install = $null, [string]$Category = 'specialist-cli',
        [bool]$ProbeVersion = $true, [string[]]$VersionArgs = @('--version'),
        $Prior = $null
    )
    $hit = Resolve-ToolCommand -Aliases $Aliases -SearchRoots $SearchRoots
    if ($hit) {
        $ver = $null
        $probe = if ($hit.path) { $hit.path } else { $hit.command }
        if ($ProbeVersion) { $ver = Get-ToolVersion -Exe $probe -VersionArgs $VersionArgs }
        Write-Host "  ${Name}: found" -ForegroundColor Green
        Set-ToolStatus -Key $Key -Found $true -Command $hit.command -Path $hit.path -Version $ver -Category $Category -InstallMode 'ask' -AliasesChecked $Aliases
        return
    }
    # Not found: always ask (even if declined on a prior run), so an accidental
    # decline is easy to correct -- just re-run and answer Y.
    Write-Host "  ${Name}: not found (optional)" -ForegroundColor Yellow
    Write-Host "         Purpose:  $Purpose" -ForegroundColor DarkGray
    Write-Host "         Provider: $Provider" -ForegroundColor DarkGray
    $ans = Read-Host "         Install $Name now? (Y/N)"
    if ($ans -notmatch '^(y|yes)$') {
        Write-Host "         Skipped. Install later from: $Provider" -ForegroundColor DarkGray
        Set-ToolStatus -Key $Key -Found $false -Reason 'not found; user declined' -Category $Category -InstallMode 'ask' -AliasesChecked $Aliases
        return
    }
    if (-not $Install) {
        Write-Host "         No reliable unattended install for this tool on a locked-down PC." -ForegroundColor Yellow
        Write-Host "         Please install it manually from: $Provider" -ForegroundColor DarkGray
        Set-ToolStatus -Key $Key -Found $false -Reason 'manual install required' -Category $Category -InstallMode 'ask' -AliasesChecked $Aliases
        return
    }
    Write-Host "         Installing $Name (best-effort, per-user)..." -ForegroundColor White
    try { & $Install | Out-Null } catch { }
    Sync-ToolPaths
    $hit2 = Resolve-ToolCommand -Aliases $Aliases -SearchRoots $SearchRoots
    if ($hit2) {
        $ver = $null
        $probe = if ($hit2.path) { $hit2.path } else { $hit2.command }
        if ($ProbeVersion) { $ver = Get-ToolVersion -Exe $probe -VersionArgs $VersionArgs }
        Write-Host "  ${Name}: installed" -ForegroundColor Green
        Set-ToolStatus -Key $Key -Found $true -Command $hit2.command -Path $hit2.path -Version $ver -Category $Category -InstallMode 'ask' -AliasesChecked $Aliases
    } else {
        Write-Host "  ${Name}: install did not complete -- install manually: $Provider" -ForegroundColor Yellow
        Write-Host "         Or finish it later in VS Code: select '070 - Capability Maintenance" -ForegroundColor DarkGray
        Write-Host "         Team Lead', name this failed tool, and approve its recovery plan." -ForegroundColor DarkGray
        Set-ToolStatus -Key $Key -Found $false -Reason 'install attempted; not detected' -Category $Category -InstallMode 'ask' -AliasesChecked $Aliases
    }
}

# -- Helper: resolve a GitHub release asset URL via the REST API ----------
# The GitHub *API* (api.github.com, JSON) stays reachable on many locked-down
# corporate proxies even where the binary asset host (objects.githubusercontent
# .com) is filtered -- so we resolve the exact "latest" asset URL here and let
# the download helper worry about actual reachability. Never throws.
$script:GitHubAssetVerification = @{}
function Get-GitHubReleaseAssetUrl {
    param([string]$Repo, [string]$NamePattern)
    try {
        $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" `
                 -Headers @{ 'User-Agent' = 'fabric-agentic-installer' } -TimeoutSec 30
        $asset = $rel.assets | Where-Object { $_.name -match $NamePattern } | Select-Object -First 1
        if ($asset) {
            $checksum = $rel.assets | Where-Object {
                $_.name -match '(?i)(sha256|checksums?|hashes)' -and
                $_.name -match '(?i)\.(txt|sha256|sha256sum)$'
            } | Select-Object -First 1
            $script:GitHubAssetVerification[[string]$asset.browser_download_url] = [ordered]@{
                repo        = $Repo
                assetName   = [string]$asset.name
                checksumUrl = if ($checksum) { [string]$checksum.browser_download_url } else { $null }
            }
            return $asset.browser_download_url
        }
    } catch { }
    return $null
}

# Verify a downloaded GitHub release asset against the publisher's checksum file
# when the release provides one. If no checksum asset exists, retain official HTTPS
# release provenance and report that validation is necessarily best-effort.
function Test-PublisherDownload {
    param([string]$Url, [string]$Path, [string]$ExpectedSha256 = $null)
    if (-not $Url -or -not $Path -or -not (Test-Path $Path)) { return $false }
    if (-not ([uri]$Url).Scheme.Equals('https', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "         Refusing a non-HTTPS download." -ForegroundColor Yellow
        return $false
    }
    try {
        $actual = (Get-Sha256Hex -LiteralPath $Path).ToUpperInvariant()
        if ($ExpectedSha256) {
            if ($actual -ne $ExpectedSha256.ToUpperInvariant()) {
                Write-Host "         SHA256 verification failed." -ForegroundColor Yellow
                return $false
            }
            Write-Host "         Verified SHA256 against the pinned publisher value." -ForegroundColor DarkGray
            return $true
        }

        $meta = $script:GitHubAssetVerification[$Url]
        if ($meta -and $meta.checksumUrl) {
            $sumFile = Join-Path $env:TEMP ("fbs_" + [IO.Path]::GetRandomFileName() + '.txt')
            try {
                if (-not (Get-FileBestEffort -Url $meta.checksumUrl -OutFile $sumFile)) {
                    Write-Host "         Publisher checksum file could not be downloaded; rejecting this asset." -ForegroundColor Yellow
                    return $false
                }
                $escapedName = [regex]::Escape([string]$meta.assetName)
                $expected = $null
                foreach ($line in Get-Content -LiteralPath $sumFile -ErrorAction Stop) {
                    if ($line -match "(?i)^\s*([a-f0-9]{64})\s+[* ]?$escapedName\s*$") { $expected = $Matches[1]; break }
                    if ($line -match "(?i)^\s*SHA256\s*\($escapedName\)\s*=\s*([a-f0-9]{64})\s*$") { $expected = $Matches[1]; break }
                }
                if (-not $expected) {
                    Write-Host "         Publisher checksum did not contain the selected asset; rejecting it." -ForegroundColor Yellow
                    return $false
                }
                if ($actual -ne $expected.ToUpperInvariant()) {
                    Write-Host "         Publisher SHA256 verification failed." -ForegroundColor Yellow
                    return $false
                }
                Write-Host "         Verified SHA256 from the official publisher checksum file." -ForegroundColor DarkGray
                return $true
            } finally {
                Remove-Item $sumFile -Force -ErrorAction SilentlyContinue
            }
        }

        $hostName = ([uri]$Url).DnsSafeHost
        Write-Host "         No publisher checksum asset is available; official HTTPS provenance ($hostName) will be combined with executable validation." -ForegroundColor DarkGray
        return $true
    } catch {
        Write-Host "         Download verification failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

# Validate an executable before a staged payload is allowed to replace a live tool.
# Signed executables must have a valid Authenticode signature; unsigned executables
# are accepted only with a non-empty PE image and the provenance/checksum checks above.
function Test-StagedExecutable {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path) -or (Get-Item $Path).Length -lt 2) { return $false }
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { $b0 = $stream.ReadByte(); $b1 = $stream.ReadByte() } finally { $stream.Dispose() }
        if ($b0 -ne 0x4D -or $b1 -ne 0x5A) {
            Write-Host "         Extracted executable is not a valid PE image." -ForegroundColor Yellow
            return $false
        }
        $sig = Get-AuthenticodeSignature -FilePath $Path
        if ($sig.SignerCertificate) {
            if ($sig.Status -ne 'Valid') {
                Write-Host "         Authenticode verification failed: $($sig.Status)." -ForegroundColor Yellow
                return $false
            }
            Write-Host "         Authenticode verified: $($sig.SignerCertificate.Subject)." -ForegroundColor DarkGray
        } else {
            Write-Host "         Executable is unsigned; PE structure and publisher download provenance were validated best-effort." -ForegroundColor DarkGray
        }
        return $true
    } catch { return $false }
}

# -- Helper: download via Delivery Optimization (DoSvc) COM ---------------
# Last-resort transport for TLS-inspection proxies that reset curl/BITS/IWR
# mid-stream. It drives the very same Delivery-Optimization service winget uses,
# directly via COM, so it negotiates the proxy with no admin/UAC. Two things are
# mandatory or DoSvc returns 0x80010123 ("cannot impersonate DCOM client"):
#   (1) run on an MTA thread; (2) CoSetProxyBlanket with IMPERSONATE + dynamic
#   cloaking on both the manager and download interface pointers.
# The IDODownload interface IID differs across Windows builds, so we discover it
# at runtime from the DO proxy-stub DLL (OneCoreCommonProxyStub.dll): find the
# well-known IDOManager IID bytes and read the next 16 bytes; we also try known
# fallbacks. Bounded by an overall timeout AND a no-progress timeout so a severed
# transfer can never hang the installer. Fully best-effort: never throws.
$script:DoBeCompiled = @{}
function Get-FileViaDeliveryOptimization {
    param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 180, [int]$NoProgressSec = 45)
    if (-not $Url) { return $false }
    # Candidate IIDs: runtime-discovered first, then known-good fallbacks.
    $iids = New-Object System.Collections.Generic.List[string]
    try {
        $mgrBytes = ([Guid]'400E2D4A-1431-4C1A-A748-39CA472CFDB1').ToByteArray()
        $dll = Join-Path $env:SystemRoot 'System32\OneCoreCommonProxyStub.dll'
        if (Test-Path $dll) {
            $data = [IO.File]::ReadAllBytes($dll)
            $lim = $data.Length - 32
            for ($i = 0; $i -le $lim; $i++) {
                $m = $true
                for ($j = 0; $j -lt 16; $j++) { if ($data[$i + $j] -ne $mgrBytes[$j]) { $m = $false; break } }
                if ($m) {
                    $nb = New-Object byte[] 16
                    [Array]::Copy($data, $i + 16, $nb, 0, 16)
                    $iids.Add(([Guid][byte[]]$nb).ToString()); break
                }
            }
        }
    } catch { }
    foreach ($fb in @('FBBD7FC0-C147-4727-A38D-827EF071EE77', 'FBBD7FA9-8B12-4E28-A38D-3B4A5B9C8E5A')) {
        if (-not $iids.Contains($fb)) { $iids.Add($fb) }
    }
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { } }
    $tpl = @'
using System; using System.Threading; using System.Runtime.InteropServices;
namespace __NS__ {
  [StructLayout(LayoutKind.Sequential)]
  public struct DO_STATUS { public ulong BytesTotal; public ulong BytesTransferred; public int State; public uint Error; public uint ExtendedError; }
  [ComImport, Guid("__IID__"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IDODownload {
    void Start(IntPtr ranges); void Pause(); void Abort(); void FinalizeDl();
    void GetStatus(out DO_STATUS status);
    void GetProperty(uint prop, [MarshalAs(UnmanagedType.Struct)] out object value);
    void SetProperty(uint prop, [MarshalAs(UnmanagedType.Struct)] ref object value);
  }
  [ComImport, Guid("400E2D4A-1431-4C1A-A748-39CA472CFDB1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IDOManager { void CreateDownload([MarshalAs(UnmanagedType.Interface)] out IDODownload download); void EnumDownloads(IntPtr a, IntPtr b); }
  [ComImport, Guid("5B99FA76-721C-423C-ADAC-56D03C8A8007")]
  public class DOClass { }
  public static class Do {
    [DllImport("ole32.dll")] static extern int CoSetProxyBlanket(IntPtr p, uint a, uint b, IntPtr s, uint c, uint d, IntPtr e, uint f);
    static void Blanket(IntPtr p){ CoSetProxyBlanket(p, 0xFFFFFFFF, 0xFFFFFFFF, (IntPtr)(-1), 0, 3, IntPtr.Zero, 0x40); }
    static string _r;
    static void Worker(object arg){
      object[] a=(object[])arg; string url=(string)a[0]; string lp=(string)a[1]; int to=(int)a[2]; int np=(int)a[3];
      try {
        var mgr=(IDOManager)new DOClass();
        IntPtr pm=Marshal.GetComInterfaceForObject(mgr,typeof(IDOManager)); Blanket(pm); Marshal.Release(pm);
        IDODownload dl; mgr.CreateDownload(out dl);
        IntPtr pd=Marshal.GetComInterfaceForObject(dl,typeof(IDODownload)); Blanket(pd); Marshal.Release(pd);
        object u=url; dl.SetProperty(1,ref u);
        object p=lp; dl.SetProperty(4,ref p);
        try { object fg=true; dl.SetProperty(11,ref fg); } catch {}
        dl.Start(IntPtr.Zero);
        var sw=System.Diagnostics.Stopwatch.StartNew(); var mv=System.Diagnostics.Stopwatch.StartNew();
        DO_STATUS st=new DO_STATUS(); ulong last=0;
        while(true){
          dl.GetStatus(out st);
          if(st.BytesTransferred!=last){ last=st.BytesTransferred; mv.Restart(); }
          if(st.State==2||st.State==3){ try{dl.FinalizeDl();}catch{} _r="OK"; return; }
          if(st.State==4){ _r="ABORT:"+st.BytesTransferred; return; }
          if(sw.Elapsed.TotalSeconds>to || mv.Elapsed.TotalSeconds>np){ try{dl.Abort();}catch{} _r="STALL:"+st.BytesTransferred; return; }
          Thread.Sleep(400);
        }
      } catch(Exception ex){ _r="EXC:"+ex.Message; }
    }
    public static string Download(string url,string lp,int to,int np){
      _r=null; var t=new Thread(new ParameterizedThreadStart(Worker)); t.SetApartmentState(ApartmentState.MTA);
      t.Start(new object[]{url,lp,to,np}); t.Join(); return _r;
    }
  }
}
'@
    $idx = 0
    foreach ($iid in $iids) {
        $idx++
        $ns = "DoBE$idx"
        try {
            $doType = $script:DoBeCompiled[$ns]
            if (-not $doType) {
                $src = $tpl.Replace('__NS__', $ns).Replace('__IID__', $iid)
                $types = Add-Type -TypeDefinition $src -Language CSharp -PassThru -ErrorAction Stop
                $doType = $types | Where-Object { $_.Name -eq 'Do' } | Select-Object -First 1
                $script:DoBeCompiled[$ns] = $doType
            }
            if (-not $doType) { continue }
            # Invoke the static Download via PowerShell's :: syntax (Invoke-Expression on
            # the runtime type name). Reflection .Invoke() mis-marshals PSObject-wrapped
            # string args ("PSObject cannot be converted to String"); :: coerces correctly.
            $res = Invoke-Expression "[$($doType.FullName)]::Download(`$Url, `$OutFile, [int]`$TimeoutSec, [int]`$NoProgressSec)"
            if (($res -eq 'OK') -and (Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) { return $true }
            # If this IID transferred any bytes it is valid; a stall/abort here is the
            # proxy severing the transfer, so trying other IIDs is pointless -- stop.
            if ($res -match '^(STALL|ABORT):(\d+)$' -and [int64]$Matches[2] -gt 0) { return $false }
        } catch { continue }
    }
    return $false
}

# -- Helper: download a file best-effort through corporate proxies --------
# Order: curl.exe (Windows schannel + --ssl-no-revoke, the most proxy-friendly
# option -- avoids CRYPT_E_NO_REVOCATION_CHECK on inspected TLS) with retries,
# then Invoke-WebRequest, then Delivery-Optimization COM (the same transport
# winget uses, which penetrates TLS-inspection proxies that reset the first two).
# Returns $true only on a non-empty file. Never throws.
# Records, per download attempt, which transports were tried and why each failed.
# Consumed by Install-PortableZipTool so a failed optional-tool install can tell
# the user WHICH layer broke (asset URL / curl / IWR / Delivery Optimization)
# instead of a single opaque "install did not complete". Reset on every call.
$script:LastDownloadDiag = @()
function Get-FileBestEffort {
    param([string]$Url, [string]$OutFile)
    $script:LastDownloadDiag = @()
    if (-not $Url) { $script:LastDownloadDiag += 'no download URL (GitHub API did not return a matching asset)'; return $false }
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        try {
            & curl.exe -L --ssl-no-revoke --connect-timeout 15 --max-time 90 --retry 3 --retry-all-errors --fail -s -S -o $OutFile $Url 2>$null
            if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) { return $true }
            $script:LastDownloadDiag += "curl.exe returned no bytes (exit $LASTEXITCODE; proxy reset or filtered)"
        } catch { $script:LastDownloadDiag += "curl.exe error: $($_.Exception.Message)" }
    } else {
        $script:LastDownloadDiag += 'curl.exe not present'
    }
    try {
        # PowerShell 5.1 does not enable TLS 1.2 by default, so IWR to modern
        # CDNs (GitHub, Azure) fails instantly with "connection closed on receive"
        # unless we opt in. Enable TLS 1.2 (and 1.3 where supported) additively.
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 30
        $ProgressPreference = $prev
        if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) { return $true }
        $script:LastDownloadDiag += 'Invoke-WebRequest returned no bytes'
    } catch { $script:LastDownloadDiag += "Invoke-WebRequest error: $($_.Exception.Message)" }
    # Last resort: Delivery Optimization COM (proxy-penetrating, no admin).
    try {
        if (Get-FileViaDeliveryOptimization -Url $Url -OutFile $OutFile) { return $true }
        $script:LastDownloadDiag += 'Delivery Optimization transfer did not complete (stalled or severed by proxy)'
    } catch { $script:LastDownloadDiag += "Delivery Optimization error: $($_.Exception.Message)" }
    return $false
}

# -- Helper: atomically activate a validated portable payload ----------------
# Extraction happens in a sibling staging directory. The currently working tool
# remains untouched until the staged executable passes validation; if activation
# fails after the swap begins, the previous directory is restored.
function Install-StagedToolPayload {
    param([string]$PayloadPath, [string]$PayloadType, [string]$DestName, [string]$ExeName)
    $programs = Join-Path $env:LOCALAPPDATA 'Programs'
    $dest = Join-Path $programs $DestName
    $nonce = [Guid]::NewGuid().ToString('N')
    $stage = "$dest.__staging_$nonce"
    $backup = "$dest.__backup_$nonce"
    $activated = $false
    try {
        New-Item -ItemType Directory -Path $programs -Force | Out-Null
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        if ($PayloadType -eq 'msi') {
            $p = Start-Process msiexec -ArgumentList @('/a', "`"$PayloadPath`"", '/qn', "TARGETDIR=`"$stage`"") -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "MSI extraction failed with exit code $($p.ExitCode)." }
        } else {
            Expand-Archive -LiteralPath $PayloadPath -DestinationPath $stage -Force
        }
        $candidate = Get-ChildItem -LiteralPath $stage -Recurse -File -Filter $ExeName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $candidate -or -not (Test-StagedExecutable -Path $candidate.FullName)) {
            throw "The staged $ExeName payload did not pass validation."
        }

        if (Test-Path -LiteralPath $dest) { Move-Item -LiteralPath $dest -Destination $backup -Force }
        try {
            Move-Item -LiteralPath $stage -Destination $dest -Force
            $installed = Get-ChildItem -LiteralPath $dest -Recurse -File -Filter $ExeName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $installed -or -not (Test-StagedExecutable -Path $installed.FullName)) {
                throw "The activated $ExeName payload could not be revalidated."
            }
            $activated = $true
            Add-DirToPath $installed.DirectoryName
        } catch {
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $dest -Force }
            throw
        }
        # Post-commit housekeeping: a failure here must never roll back the
        # validated replacement (a half-deleted backup is not a restore candidate).
        if (Test-Path -LiteralPath $backup) {
            try { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Stop }
            catch { Write-Host "         Installed, but the previous copy could not be fully removed: $backup (delete it manually)." -ForegroundColor DarkGray }
        }
        return $true
    } catch {
        Write-Host "         Portable activation failed; the previous version was preserved: $($_.Exception.Message)" -ForegroundColor DarkGray
        return $false
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
        if (-not $activated -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $dest)) {
            Move-Item -LiteralPath $backup -Destination $dest -Force -ErrorAction SilentlyContinue
        }
    }
}

# -- Helper: install a portable tool from a .zip into %LOCALAPPDATA% ------
# Downloads and verifies the zip, then delegates staged validation, activation,
# rollback, and PATH registration to Install-StagedToolPayload.
function Install-PortableZipTool {
    param([string]$Url, [string]$DestName, [string]$ExeName, [string]$Sha256 = $null)
    if (-not $Url) {
        Write-Host "         Download layer: no release asset URL was resolved (GitHub API blocked or no matching asset)." -ForegroundColor DarkGray
        return $false
    }
    $tmp = Join-Path $env:TEMP ("fbz_" + [IO.Path]::GetRandomFileName() + ".zip")
    if (-not (Get-FileBestEffort -Url $Url -OutFile $tmp)) {
        $why = if ($script:LastDownloadDiag -and $script:LastDownloadDiag.Count) { $script:LastDownloadDiag -join '; ' } else { 'unknown transport failure' }
        Write-Host "         Download layer failed: $why" -ForegroundColor DarkGray
        return $false
    }
    try {
        if (-not (Test-PublisherDownload -Url $Url -Path $tmp -ExpectedSha256 $Sha256)) {
            Write-Host "         Verification layer failed: publisher checksum/provenance check did not pass." -ForegroundColor DarkGray
            return $false
        }
        $ok = (Install-StagedToolPayload -PayloadPath $tmp -PayloadType 'zip' -DestName $DestName -ExeName $ExeName)
        if (-not $ok) {
            Write-Host "         Extraction/activation layer failed: the downloaded archive could not be unpacked or validated." -ForegroundColor DarkGray
        }
        return $ok
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# -- Helper: install a portable tool from a LOCAL zip the user already has ----
# Last-resort path for locked-down networks where every automated transport is
# blocked but the user's *browser* can reach the publisher. The user downloads
# the official zip once and drops it in Downloads (or next to the installer); we
# pick it up, then stage/validate/activate it exactly like a downloaded copy.
# Provenance here is the user's own authenticated browser download, so we rely on
# the PE + Authenticode validation inside Install-StagedToolPayload. Never throws.
# -- Helper: resolve the REAL Downloads folder --------------------------
# %USERPROFILE%\Downloads is only an assumption; OneDrive "Known Folder Move"
# and corporate redirection can point the shell Downloads folder elsewhere, in
# which case the browser saves there while a naive poll of %USERPROFILE%\Downloads
# sees nothing. The Explorer "Shell Folders" registry value is authoritative.
function Get-DownloadsPath {
    try {
        $p = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' `
                -Name '{374DE290-123F-4565-9164-39C4925E467B}' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($p) { return [Environment]::ExpandEnvironmentVariables($p) }
    } catch { }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

function Install-FromLocalZip {
    param([string]$NamePattern, [string]$DestName, [string]$ExeName)
    $roots = @(
        (Get-DownloadsPath),
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        $env:TEMP,
        $PSScriptRoot,
        (Get-Location).Path
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    foreach ($root in $roots) {
        $hit = Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match $NamePattern } |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) {
            Write-Host "         Found a local copy: $($hit.FullName)" -ForegroundColor DarkGray
            if (Install-StagedToolPayload -PayloadPath $hit.FullName -PayloadType 'zip' -DestName $DestName -ExeName $ExeName) {
                return $true
            }
            Write-Host "         The local copy could not be validated/extracted; is it the official portable zip?" -ForegroundColor DarkGray
        }
    }
    return $false
}

# -- Helper: assisted browser download, then auto-pickup (locked-machine backup) --
# Why: winget's Delivery-Optimization downloader negotiates TLS-inspection
# corporate proxies that reset plain curl/BITS mid-stream, and `winget download`
# only FETCHES the installer -- it never runs it, so there is no UAC/elevation.
# We then extract the fetched installer locally into %LOCALAPPDATA%\Programs\<DestName>:
#   * .msi -> `msiexec /a ... TARGETDIR=` (administrative install = extract only, no admin)
#   * .zip -> Expand-Archive
# then locate <ExeName> inside and append its folder to PATH. --skip-dependencies
# avoids pulling large machine dependencies (e.g. TE2's 82 MB .NET DevPack) that
# stock Windows already satisfies. Retries a few times because the DO transfer can
# be severed by the proxy. Fully best-effort: any failure returns $false so the
# caller can fall back to a direct download or surface the manual link. Never throws.
function Install-ViaWingetDownload {
    param([string]$WingetId, [string]$ExeName, [string]$DestName, [int]$Retries = 2, [int]$TimeoutSec = 90)
    if (-not $WingetId) { return $false }
    $wg = (Get-Command winget -ErrorAction SilentlyContinue)
    if (-not $wg) { return $false }
    $dl = Join-Path $env:TEMP ("wgdl_" + [IO.Path]::GetRandomFileName())
    try {
        $fetched = $null
        for ($i = 1; $i -le $Retries -and -not $fetched; $i++) {
            if (Test-Path $dl) { Remove-Item $dl -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $dl -Force | Out-Null
            # Run winget download with a hard timeout: on TLS-inspection proxies the
            # underlying Delivery-Optimization transfer can stall indefinitely, and a
            # bare `& winget` would hang the whole installer forever. Start-Process +
            # Wait-Process(-Timeout) lets us kill a stalled transfer and fall through.
            $so = Join-Path $env:TEMP ("wgo_" + [IO.Path]::GetRandomFileName() + ".txt")
            $se = "$so.err"
            $completedOk = $false
            try {
                $proc = Start-Process -FilePath $wg.Source -ArgumentList @(
                    'download', '--id', $WingetId, '--exact', '--skip-dependencies',
                    '--disable-interactivity', '--accept-package-agreements',
                    '--accept-source-agreements', '-d', $dl
                ) -NoNewWindow -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
                $exited = $true
                try { $proc | Wait-Process -Timeout $TimeoutSec -ErrorAction Stop } catch { $exited = $false }
                if (-not $exited) { try { $proc | Stop-Process -Force -ErrorAction SilentlyContinue } catch { } }
                # Only a normal, zero exit proves winget finished its manifest/hash checks;
                # a killed or failed run can still leave a partial MSI/ZIP behind.
                $completedOk = ($exited -and $proc.HasExited -and $proc.ExitCode -eq 0)
            } catch { }
            Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
            if ($completedOk) {
                $fetched = Get-ChildItem $dl -Recurse -File -ErrorAction SilentlyContinue |
                           Where-Object { $_.Extension -in '.msi', '.zip' } | Select-Object -First 1
            }
        }
        if (-not $fetched) { return $false }
        Write-Host "         winget verified the publisher manifest and installer hash before extraction." -ForegroundColor DarkGray
        return (Install-StagedToolPayload -PayloadPath $fetched.FullName -PayloadType $fetched.Extension.TrimStart('.') -DestName $DestName -ExeName $ExeName)
    } catch {
        return $false
    } finally {
        if (Test-Path $dl) { Remove-Item $dl -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# =====================================================================
# UPDATE FLOW -- optional per-tool version check + best-effort upgrade
# =====================================================================
# For every managed tool that is already installed, look up the latest published
# version and, ONLY when the installed version is genuinely behind, prompt Y/N to
# upgrade. Upgrading just re-runs the tool's normal install action (which already
# self-adapts to locked-down vs open networks). Fully fail-safe: any lookup that
# is blocked (proxy/offline) or unparseable silently skips that tool -- we never
# nag or error when we cannot positively confirm an update is available.

# Latest version from PyPI (az / fab / pbir). Returns "x.y.z" or $null.
function Get-LatestPyPiVersion {
    param([string]$Package)
    if (-not $Package) { return $null }
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $j = Invoke-RestMethod "https://pypi.org/pypi/$Package/json" -TimeoutSec 20
        if ($j -and $j.info -and $j.info.version) { return [string]$j.info.version }
    } catch { }
    return $null
}

# Latest release tag from GitHub (gh / sqlcmd / TE2 / pbi-tools). Strips a
# leading 'v'. api.github.com stays reachable on many inspected proxies.
function Get-LatestGitHubVersion {
    param([string]$Repo)
    if (-not $Repo) { return $null }
    try {
        $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" `
                 -Headers @{ 'User-Agent' = 'fabric-agentic-installer' } -TimeoutSec 20
        if ($rel -and $rel.tag_name) { return ([string]$rel.tag_name -replace '^[vV]', '') }
    } catch { }
    return $null
}

# Extract the first dotted numeric version (x.y[.z[.w]]) from arbitrary text.
function Get-VersionToken {
    param([string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match([string]$Text, '\d+\.\d+(?:\.\d+){0,2}')
    if ($m.Success) { return $m.Value }
    return $null
}

# File version of an exe WITHOUT launching it (safe for GUI tools like TE2).
function Get-ExeFileVersion {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    try {
        $fi = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        $v = $fi.ProductVersion; if (-not $v) { $v = $fi.FileVersion }
        return (Get-VersionToken $v)
    } catch { }
    return $null
}

# True only when BOTH versions parse AND latest > installed. Any unknown => $false
# (fail-safe: never prompt for an update we cannot positively confirm).
function Test-UpdateAvailable {
    param([string]$Installed, [string]$Latest)
    $vi = Get-VersionToken $Installed; $vl = Get-VersionToken $Latest
    if (-not $vi -or -not $vl) { return $false }
    try { return ([version]$vl -gt [version]$vi) } catch { return $false }
}

# Orchestrator: iterate managed, currently-installed tools; check + offer update.
# Never throws; each tool is independent and best-effort.
function Invoke-ToolUpdateCheck {
    Write-Host ""
    Write-Host "  Checking installed tools for updates (best-effort; blocked lookups are skipped)..." -ForegroundColor Cyan
    $script:UpdOutdated = $false
    $script:UpdChecked = 0
    $script:UpdUnverified = 0

    $py         = Find-RealPython
    $azVenvPy   = Join-Path $env:USERPROFILE '.fabric-az\Scripts\python.exe'
    $pbirVenvPy = Join-Path $env:USERPROFILE '.fabric-pbir\Scripts\python.exe'
    $arch       = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'amd64' }

    # Read the exe/command to probe for a given tool-status key.
    $probeTarget = {
        param([string]$Key)
        $e = $script:ToolStatus[$Key]
        if (-not $e) { return $null }
        if ($e.path) { return $e.path }
        return $e.command
    }

    # Prompt + run one tool's update, then re-detect and refresh its version.
    $checkOne = {
        param([string]$Key, [string]$Name, [string]$Installed, [string]$Latest, [scriptblock]$DoUpdate, [scriptblock]$ReDetect)
        $installedTok = Get-VersionToken $Installed
        if ($installedTok -and $script:ToolStatus[$Key]) {
            $script:ToolStatus[$Key].version = $installedTok
        }
        if (-not $Installed -or -not $Latest) {
            $script:UpdUnverified++
            Write-Host ("    [Unverified] {0} -- installed or latest version could not be confirmed." -f $Name) -ForegroundColor DarkGray
            return
        }
        $script:UpdChecked++
        if (-not (Test-UpdateAvailable $Installed $Latest)) {
            Write-Host ("    [Current] {0} ({1})" -f $Name, (Get-VersionToken $Installed)) -ForegroundColor Green
            return
        }
        $script:UpdOutdated = $true
        Write-Host ("    [Update] {0}: v{1} installed, v{2} available." -f $Name, (Get-VersionToken $Installed), (Get-VersionToken $Latest)) -ForegroundColor Yellow
        $ans = Read-Host ("         Update {0} now? (Y/N)" -f $Name)
        if ($ans -notmatch '^(y|yes)$') { Write-Host "         Skipped." -ForegroundColor DarkGray; return }
        Write-Host ("         Updating {0} (best-effort)..." -f $Name) -ForegroundColor White
        try { & $DoUpdate | Out-Null } catch { }
        Sync-ToolPaths
        $new = $null; if ($ReDetect) { try { $new = & $ReDetect } catch { } }
        $newTok = Get-VersionToken $new
        if ($newTok) {
            if ($script:ToolStatus[$Key]) { $script:ToolStatus[$Key].version = $newTok }
            if (Test-UpdateAvailable $newTok $Latest) {
                Write-Host ("  {0}: still v{1} -- the selected executable was not replaced. Review the install output or try again later." -f $Name, $newTok) -ForegroundColor Yellow
            } else {
                Write-Host ("  {0}: updated to v{1}." -f $Name, $newTok) -ForegroundColor Green
            }
        } else {
            Write-Host ("  {0}: update attempted -- verify on next run." -f $Name) -ForegroundColor DarkGray
        }
    }

    # fab (ms-fabric-cli, PyPI)
    if ($script:ToolStatus['fab'] -and $script:ToolStatus['fab'].found) {
        & $checkOne 'fab' 'Fabric CLI (fab)' (Get-ToolVersion -Exe (& $probeTarget 'fab')) (Get-LatestPyPiVersion 'ms-fabric-cli') `
            { if ($py) { & $py -m pip install --upgrade --disable-pip-version-check ms-fabric-cli 2>$null; & $py -m pip install --user --upgrade --disable-pip-version-check ms-fabric-cli 2>$null } } `
            { Get-ToolVersion -Exe (& $probeTarget 'fab') }
    }

    # az (azure-cli, PyPI) -- prefer the isolated venv, then winget, then pip.
    if ($script:ToolStatus['az'] -and $script:ToolStatus['az'].found) {
        & $checkOne 'az' 'az CLI' (Get-ToolVersion -Exe (& $probeTarget 'az') -VersionArgs @('version','-o','tsv')) (Get-LatestPyPiVersion 'azure-cli') `
            {
                if (Test-Path $azVenvPy) { & $azVenvPy -m pip install --upgrade --disable-pip-version-check azure-cli 2>$null }
                elseif (Get-Command winget -ErrorAction SilentlyContinue) { & winget upgrade --silent --accept-package-agreements --accept-source-agreements -e --id Microsoft.AzureCLI 2>$null }
                elseif ($py) { & $py -m pip install --upgrade --disable-pip-version-check azure-cli 2>$null }
            } `
            { Get-ToolVersion -Exe (& $probeTarget 'az') -VersionArgs @('version','-o','tsv') }
    }

    # pbir (pbir-cli, PyPI) -- lives in its own short venv.
    if ($script:ToolStatus['pbir'] -and $script:ToolStatus['pbir'].found) {
        & $checkOne 'pbir' 'pbir CLI' (Get-ToolVersion -Exe (& $probeTarget 'pbir')) (Get-LatestPyPiVersion 'pbir-cli') `
            { if (Test-Path $pbirVenvPy) { & $pbirVenvPy -m pip install --upgrade --disable-pip-version-check pbir-cli 2>$null } } `
            { Get-ToolVersion -Exe (& $probeTarget 'pbir') }
    }

    # gh (GitHub release) -- authoritative current portable release first;
    # winget-download remains the locked-down/proxy-friendly fallback.
    if ($script:ToolStatus['gh'] -and $script:ToolStatus['gh'].found) {
        & $checkOne 'gh' 'GitHub CLI (gh)' (Get-ToolVersion -Exe (& $probeTarget 'gh')) (Get-LatestGitHubVersion 'cli/cli') `
            {
                $u = Get-GitHubReleaseAssetUrl -Repo 'cli/cli' -NamePattern "gh_.*_windows_$arch\.zip$"
                $portableOk = $false
                if ($u) { $portableOk = Install-PortableZipTool -Url $u -DestName 'gh' -ExeName 'gh.exe' }
                if (-not $portableOk) {
                    Install-ViaWingetDownload -WingetId 'GitHub.cli' -ExeName 'gh.exe' -DestName 'gh' | Out-Null
                }
            } `
            {
                # Do not re-use the pre-update cached path: it may point to an
                # older machine-wide gh while the successful portable update is
                # under the user's profile.
                $h = Resolve-ToolCommand -Aliases @('gh') -SearchRoots @("$env:LOCALAPPDATA\Programs\gh")
                if ($h) {
                    $target = if ($h.path) { $h.path } else { $h.command }
                    $script:ToolStatus['gh'].command = $h.command
                    $script:ToolStatus['gh'].path = $h.path
                    Get-ToolVersion -Exe $target
                } else {
                    Get-ToolVersion -Exe (& $probeTarget 'gh')
                }
            }
    }

    # sqlcmd (GitHub release, go-sqlcmd) -- re-run install action.
    if ($script:ToolStatus['sqlcmd'] -and $script:ToolStatus['sqlcmd'].found) {
        & $checkOne 'sqlcmd' 'sqlcmd' (Get-ToolVersion -Exe (& $probeTarget 'sqlcmd')) (Get-LatestGitHubVersion 'microsoft/go-sqlcmd') `
            {
                if (-not (Install-ViaWingetDownload -WingetId 'Microsoft.Sqlcmd' -ExeName 'sqlcmd.exe' -DestName 'sqlcmd')) {
                    $u = Get-GitHubReleaseAssetUrl -Repo 'microsoft/go-sqlcmd' -NamePattern "sqlcmd-windows-$arch\.zip$"
                    Install-PortableZipTool -Url $u -DestName 'sqlcmd' -ExeName 'sqlcmd.exe' | Out-Null
                }
            } `
            { Get-ToolVersion -Exe (& $probeTarget 'sqlcmd') }
    }

    # Tabular Editor 2 (GitHub release) -- GUI: read exe FileVersion, never launch.
    if ($script:ToolStatus['tabularEditor'] -and $script:ToolStatus['tabularEditor'].found) {
        & $checkOne 'tabularEditor' 'Tabular Editor 2' (Get-ExeFileVersion (& $probeTarget 'tabularEditor')) (Get-LatestGitHubVersion 'TabularEditor/TabularEditor') `
            {
                if (-not (Install-ViaWingetDownload -WingetId 'TabularEditor.TabularEditor.2' -ExeName 'TabularEditor.exe' -DestName 'TabularEditor')) {
                    $u = Get-GitHubReleaseAssetUrl -Repo 'TabularEditor/TabularEditor' -NamePattern 'TabularEditor\.Portable\.zip$'
                    Install-PortableZipTool -Url $u -DestName 'TabularEditor' -ExeName 'TabularEditor.exe' | Out-Null
                }
            } `
            {
                $h = Resolve-ToolCommand -Aliases @('TabularEditor.exe','TabularEditor2.exe') -SearchRoots @("$env:LOCALAPPDATA\Programs\TabularEditor")
                if ($h -and $h.path) { Get-ExeFileVersion $h.path } else { Get-ExeFileVersion (& $probeTarget 'tabularEditor') }
            }
    }

    # pbi-tools (GitHub release) -- read exe FileVersion; re-run zip install.
    if ($script:ToolStatus['pbiTools'] -and $script:ToolStatus['pbiTools'].found) {
        & $checkOne 'pbiTools' 'pbi-tools' (Get-ExeFileVersion (& $probeTarget 'pbiTools')) (Get-LatestGitHubVersion 'pbi-tools/pbi-tools') `
            {
                $u = Get-GitHubReleaseAssetUrl -Repo 'pbi-tools/pbi-tools' -NamePattern '^pbi-tools\.\d+\.\d+\.\d+\.zip$'
                Install-PortableZipTool -Url $u -DestName 'pbi-tools' -ExeName 'pbi-tools.exe' | Out-Null
            } `
            {
                $h = Resolve-ToolCommand -Aliases @('pbi-tools','pbi-tools.core') -SearchRoots @("$env:LOCALAPPDATA\Programs\pbi-tools")
                if ($h -and $h.path) { Get-ExeFileVersion $h.path } else { Get-ExeFileVersion (& $probeTarget 'pbiTools') }
            }
    }

    # azure-devops az extension -- versions and update via az itself.
    if ($script:ToolStatus['azureDevOpsCliExtension'] -and $script:ToolStatus['azureDevOpsCliExtension'].found -and (Get-Command az -ErrorAction SilentlyContinue)) {
        $adoInstalled = $null; $adoLatest = $null
        try { $adoInstalled = (& az extension list --query "[?name=='azure-devops'].version" -o tsv 2>$null | Select-Object -First 1) } catch { }
        try { $adoLatest = (& az extension list-available --query "[?name=='azure-devops'].version" -o tsv 2>$null | Select-Object -First 1) } catch { }
        & $checkOne 'azureDevOpsCliExtension' 'Azure DevOps CLI extension' $adoInstalled $adoLatest `
            { & az extension update --name azure-devops 2>$null } `
            { try { (& az extension list --query "[?name=='azure-devops'].version" -o tsv 2>$null | Select-Object -First 1) } catch { $null } }
    }

    Write-Host ("  Update review complete: {0} version(s) confirmed; {1} lookup(s) unverified." -f $script:UpdChecked, $script:UpdUnverified) -ForegroundColor DarkGray
    Write-Host "  Python is handled separately as a CLI prerequisite, and VS Code manages extension/MCP updates; this review changes neither." -ForegroundColor DarkGray
}

# -- Helper: parse JSON that VS Code accepts (comments, trailing commas) ----
# ConvertFrom-Json rejects JSONC, which is the default dialect of settings.json
# and .code-workspace files. Strip // and /* */ comments outside string literals
# and trailing commas, then parse. Returns $null when the text is genuinely broken.
function ConvertFrom-JsonLenient ([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { }
    try {
        $stripped = [regex]::Replace($Text, '(?s)"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*.*?\*/', { param($m) if ($m.Value.StartsWith('"')) { $m.Value } else { '' } })
        $stripped = [regex]::Replace($stripped, ',(\s*[}\]])', '$1')
        return ($stripped | ConvertFrom-Json)
    } catch { return $null }
}

# -- Helper: merge installer-owned keys into existing JSON settings -----
function Merge-JsonSettings ([string]$Path, [hashtable]$Required) {
    $existing = [ordered]@{}
    if (Test-Path $Path) {
        $raw = Get-Content $Path -Raw
        $parsed = ConvertFrom-JsonLenient $raw
        if ($null -ne $parsed) {
            foreach ($prop in $parsed.PSObject.Properties) {
                $existing[$prop.Name] = $prop.Value
            }
            if ($raw -match '(?m)^\s*//|/\*') { Write-Host "  Note: comments in $(Split-Path $Path -Leaf) are not preserved by the merge (values are)." -ForegroundColor DarkGray }
        } else {
            # Genuinely malformed -- back up and start fresh
            Copy-Item $Path "$Path.bak" -Force
            Write-Host "  Backed up malformed $(Split-Path $Path -Leaf) to $(Split-Path $Path -Leaf).bak" -ForegroundColor Yellow
        }
    }
    foreach ($key in $Required.Keys) {
        $val = $Required[$key]
        if ($val -is [hashtable] -and $existing.Contains($key) -and $existing[$key] -is [PSCustomObject]) {
            # Deep merge: add missing sub-keys, preserve user additions
            foreach ($sk in $val.Keys) {
                $existing[$key] | Add-Member -NotePropertyName $sk -NotePropertyValue $val[$sk] -Force
            }
        } else {
            $existing[$key] = $val
        }
    }
    $json = $existing | ConvertTo-Json -Depth 10
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# -- Helper: canonical form of a chat.agentSkillsLocations key ---------------
# Keys may be workspace-relative, absolute or ~/-prefixed; compare them as one form.
function ConvertTo-SkillLocationKey ([string]$Location, [string]$BaseDir) {
    $p = [string]$Location
    if ($p -match '^~[\\/](.*)$') { $p = Join-Path $env:USERPROFILE $Matches[1] }
    elseif (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $BaseDir $p }
    try { return [IO.Path]::GetFullPath($p).TrimEnd('\').ToLowerInvariant() } catch { return $null }
}

# -- Helper: saved .code-workspace files that open a given root ------------
# `chat.subagents.allowInvocationsFromSubagents` and `chat.agentSkillsLocations`
# are WINDOW-scoped: when VS Code is opened from a multi-root workspace file, the
# folder's .vscode/settings.json is ignored and they must live in THAT file. Users
# commonly keep their own saved workspace files, so find every one VS Code has ever
# opened that includes this root and report what it lacks.
function Get-UserWorkspaceFilesForRoot {
    param([string]$RootPath, [string]$StorageRoot = $null, [string[]]$RequiredSkillLocations = @())
    if (-not $StorageRoot) { $StorageRoot = Join-Path $env:APPDATA 'Code\User\workspaceStorage' }
    $result = @()
    if (-not (Test-Path -LiteralPath $StorageRoot)) { return $result }
    $rootNorm = [IO.Path]::GetFullPath($RootPath).TrimEnd('\').ToLowerInvariant()
    $seen = @{}
    Get-ChildItem -LiteralPath $StorageRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $wj = Join-Path $_.FullName 'workspace.json'
        if (-not (Test-Path -LiteralPath $wj)) { return }
        $w = ConvertFrom-JsonLenient (Get-Content -LiteralPath $wj -Raw -ErrorAction SilentlyContinue)
        if (-not $w -or -not $w.workspace) { return }
        $uri = [string]$w.workspace
        if ($uri -notmatch '^file:///') { return }
        $file = [Uri]::UnescapeDataString($uri.Substring(8)).Replace('/', '\')
        if ($seen.ContainsKey($file.ToLowerInvariant()) -or -not (Test-Path -LiteralPath $file)) { return }
        $seen[$file.ToLowerInvariant()] = $true
        $wsj = ConvertFrom-JsonLenient (Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue)
        if (-not $wsj) { return }
        $dir = Split-Path $file -Parent
        $opensRoot = $false
        foreach ($f in @($wsj.folders)) {
            if (-not $f -or -not $f.path) { continue }
            $p = [string]$f.path
            if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $dir $p }
            try { $p = [IO.Path]::GetFullPath($p).TrimEnd('\').ToLowerInvariant() } catch { continue }
            if ($p -eq $rootNorm) { $opensRoot = $true }
        }
        if (-not $opensRoot) { return }
        $n = $null; if ($wsj.settings) { $n = $wsj.settings.'chat.subagents.allowInvocationsFromSubagents' }
        $have = @{}
        if ($wsj.settings -and $wsj.settings.'chat.agentSkillsLocations') {
            foreach ($prop in $wsj.settings.'chat.agentSkillsLocations'.PSObject.Properties) {
                $k = ConvertTo-SkillLocationKey $prop.Name $RootPath
                if ($k) { $have[$k] = $true }
            }
        }
        $missing = @($RequiredSkillLocations | Where-Object {
            $k = ConvertTo-SkillLocationKey $_ $RootPath
            $k -and -not $have.ContainsKey($k)
        })
        $result += [pscustomobject]@{ Path = $file; NestedDispatch = ($n -eq $true); MissingSkillLocations = $missing }
    }
    return $result
}

# -- Helper: add only what a saved .code-workspace lacks ----------------------
function Update-UserWorkspaceFile {
    param([string]$Path, [string[]]$SkillLocations = @())
    $raw = Get-Content -LiteralPath $Path -Raw
    $wsj = ConvertFrom-JsonLenient $raw
    if (-not $wsj) { throw "unreadable: $Path" }
    if (-not $wsj.settings) { $wsj | Add-Member -NotePropertyName settings -NotePropertyValue ([pscustomobject]@{}) -Force }
    $wsj.settings | Add-Member -NotePropertyName 'chat.subagents.allowInvocationsFromSubagents' -NotePropertyValue $true -Force
    if ($SkillLocations.Count -gt 0) {
        if (-not $wsj.settings.'chat.agentSkillsLocations') {
            $wsj.settings | Add-Member -NotePropertyName 'chat.agentSkillsLocations' -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        foreach ($loc in $SkillLocations) {
            $wsj.settings.'chat.agentSkillsLocations' | Add-Member -NotePropertyName $loc -NotePropertyValue $true -Force
        }
    }
    [IO.File]::WriteAllText($Path, ($wsj | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    # True when the original had comments, which ConvertTo-Json cannot keep.
    return [bool]($raw -match '(?m)^\s*//|/\*')
}

# -- Helper: VS Code user settings.json (default profile) ----------------------
function Get-VsCodeUserSettingsPath {
    if ($env:FABRIC_AGENTIC_USER_SETTINGS) { return $env:FABRIC_AGENTIC_USER_SETTINGS }
    return (Join-Path $env:APPDATA 'Code\User\settings.json')
}

# Settings files of custom VS Code Profiles (each profile has its own settings.json).
function Get-VsCodeProfileSettingsPaths {
    $profiles = Join-Path $env:APPDATA 'Code\User\profiles'
    if (-not (Test-Path -LiteralPath $profiles)) { return @() }
    return @(Get-ChildItem -LiteralPath $profiles -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'settings.json' } | Where-Object { Test-Path -LiteralPath $_ })
}

# Index just past the matching close brace of the object that opens at $OpenIndex,
# skipping string literals and // or /* */ comments. -1 when unbalanced.
function Find-JsonObjectEnd ([string]$Text, [int]$OpenIndex) {
    $depth = 0; $i = $OpenIndex; $n = $Text.Length
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($c -eq '"') {
            $i++
            while ($i -lt $n -and $Text[$i] -ne '"') { if ($Text[$i] -eq '\') { $i++ }; $i++ }
        } elseif ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '/') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        } elseif ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '*') {
            $end = $Text.IndexOf('*/', $i + 2); if ($end -lt 0) { return -1 }; $i = $end + 2; continue
        } elseif ($c -eq '{' -or $c -eq '[') { $depth++ }
        elseif ($c -eq '}' -or $c -eq ']') { $depth--; if ($depth -eq 0) { return $i + 1 } }
        $i++
    }
    return -1
}

# Index of the first `//` outside a string literal in one line, or -1.
function Find-LineCommentStart ([string]$Line) {
    $inStr = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($inStr) { if ($c -eq '\') { $i++ } elseif ($c -eq '"') { $inStr = $false }; continue }
        if ($c -eq '"') { $inStr = $true; continue }
        if ($c -eq '/' -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '/') { return $i }
    }
    return -1
}

# Insert "$Member" as the last property of the object whose closing brace is at
# $CloseIndex, adding the separating comma only when needed. Trailing comments
# before the brace are left where they are.
function Add-JsonMemberBeforeClose ([string]$Text, [int]$CloseIndex, [string]$Member, [string]$Indent, [string]$Nl) {
    $before = $Text.Substring(0, $CloseIndex)
    # Walk back over whitespace and comments (whole-line, trailing and block) to the last value character.
    $probe = $before
    while ($true) {
        $probe = $probe.TrimEnd()
        $ls = $probe.LastIndexOf("`n") + 1
        $ci = Find-LineCommentStart ($probe.Substring($ls))
        if ($ci -ge 0) { $probe = $probe.Substring(0, $ls + $ci); continue }
        $m2 = [regex]::Match($probe, '(?s)/\*(?:(?!\*/).)*\*/$')
        if ($m2.Success) { $probe = $probe.Substring(0, $m2.Index); continue }
        break
    }
    $insertAt = $probe.Length
    $last = if ($insertAt -gt 0) { $probe[$insertAt - 1] } else { '{' }
    $comma = if ($last -eq '{' -or $last -eq ',' -or $last -eq '[') { '' } else { ',' }
    $closeIndent = ''
    $lineStart = $before.LastIndexOf("`n") + 1
    if ($lineStart -le $CloseIndex) { $closeIndent = $before.Substring($lineStart) -replace '[^ \t].*$', '' }
    return $before.Substring(0, $insertAt) + $comma + $Nl + $closeIndent + $Indent + $Member + $before.Substring($insertAt) + $Text.Substring($CloseIndex)
}

# -- Helper: enable the agent team in VS Code USER settings, editing in place -------
# Writes exactly two things and nothing else: `chat.subagents.allowInvocationsFromSubagents`
# = true (window-scoped, so user level is the only scope that reaches every window,
# including untitled/saved multi-root workspaces) and the given WORKSPACE-RELATIVE
# skill locations merged into `chat.agentSkillsLocations` (VS Code resolves relative
# entries against the open workspace folders, so they activate only where this
# workspace is open). Text is edited in place: comments, order and formatting of the
# user's file survive. Idempotent. Returns @{ Changed; FlagAdded; LocationsAdded }.
function Update-UserSettingsInPlace {
    param([string]$Path, [string[]]$SkillLocations = @())
    $flagKey = 'chat.subagents.allowInvocationsFromSubagents'
    $locKey  = 'chat.agentSkillsLocations'
    $result = @{ Changed = $false; FlagAdded = $false; LocationsAdded = @() }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $SkillLocations = @($SkillLocations | Where-Object { $_ -and -not [IO.Path]::IsPathRooted($_) -and $_ -notmatch '^~[\\/]' } | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)

    if (-not (Test-Path -LiteralPath $Path)) {
        $locs = ($SkillLocations | ForEach-Object { "        `"$_`": true" }) -join ",`r`n"
        $body = "{`r`n    `"$flagKey`": true"
        if ($SkillLocations.Count -gt 0) { $body += ",`r`n    `"$locKey`": {`r`n$locs`r`n    }" }
        $body += "`r`n}`r`n"
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($Path, $body, $utf8)
        $result.Changed = $true; $result.FlagAdded = $true; $result.LocationsAdded = $SkillLocations
        return $result
    }

    $bytes = [IO.File]::ReadAllBytes($Path)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [Text.Encoding]::UTF8.GetString($bytes); if ($hadBom) { $text = $text.Substring(1) }
    if ([string]::IsNullOrWhiteSpace($text)) { $text = "{`r`n}`r`n" }
    $parsed = ConvertFrom-JsonLenient $text
    if ($null -eq $parsed) { throw "user settings file is not valid JSON/JSONC: $Path" }
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $indentMatch = [regex]::Match($text, '(?m)^([ \t]+)"')
    $indent = if ($indentMatch.Success) { $indentMatch.Groups[1].Value } else { '    ' }

    # 1) dispatch flag: flip an existing value, or append the key to the root object.
    $flagRx = [regex]::new('"' + [regex]::Escape($flagKey) + '"\s*:\s*(true|false)')
    $fm = $flagRx.Match($text)
    if ($fm.Success) {
        if ($fm.Groups[1].Value -ne 'true') {
            $text = $text.Substring(0, $fm.Groups[1].Index) + 'true' + $text.Substring($fm.Groups[1].Index + $fm.Groups[1].Length)
            $result.Changed = $true; $result.FlagAdded = $true
        }
    } else {
        $rootClose = $text.LastIndexOf('}')
        if ($rootClose -lt 0) { throw "user settings file has no root object: $Path" }
        $text = Add-JsonMemberBeforeClose $text $rootClose ("`"$flagKey`": true") $indent $nl
        $result.Changed = $true; $result.FlagAdded = $true
    }

    # 2) workspace-relative skill locations: merge missing keys into the existing object.
    if ($SkillLocations.Count -gt 0) {
        $existing = @{}
        if ($parsed.PSObject.Properties[$locKey] -and $parsed.$locKey) {
            foreach ($p in $parsed.$locKey.PSObject.Properties) { $existing[$p.Name.Replace('\', '/').ToLowerInvariant()] = $true }
        }
        $missing = @($SkillLocations | Where-Object { -not $existing.ContainsKey($_.ToLowerInvariant()) })
        if ($missing.Count -gt 0) {
            $keyRx = [regex]::new('"' + [regex]::Escape($locKey) + '"\s*:\s*\{')
            $km = $keyRx.Match($text)
            if ($km.Success) {
                $open = $km.Index + $km.Length - 1
                $end = Find-JsonObjectEnd $text $open
                if ($end -lt 0) { throw "could not parse $locKey in $Path" }
                foreach ($loc in $missing) {
                    $end = Find-JsonObjectEnd $text $open
                    $text = Add-JsonMemberBeforeClose $text ($end - 1) ("`"$loc`": true") $indent $nl
                }
            } else {
                $inner = ($missing | ForEach-Object { $indent + $indent + "`"$_`": true" }) -join (',' + $nl)
                $block = "`"$locKey`": {" + $nl + $inner + $nl + $indent + '}'
                $rootClose = $text.LastIndexOf('}')
                $text = Add-JsonMemberBeforeClose $text $rootClose $block $indent $nl
            }
            $result.Changed = $true; $result.LocationsAdded = $missing
        }
    }

    if ($result.Changed) {
        if ($null -eq (ConvertFrom-JsonLenient $text)) { throw "refusing to write: edited user settings would not parse ($Path)" }
        $enc = if ($hadBom) { New-Object System.Text.UTF8Encoding($true) } else { $utf8 }
        [IO.File]::WriteAllText($Path, $text, $enc)
    }
    return $result
}

# Returns workspace-relative (forward-slash) folders that directly contain skill
# subfolders (<container>/<skill>/SKILL.md), for chat.agentSkillsLocations.
function Get-SkillContainerDirs {
    param([string]$RootPath, [string[]]$SearchSubPaths)
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($sub in $SearchSubPaths) {
        $base = Join-Path $RootPath $sub
        if (-not (Test-Path -LiteralPath $base)) { continue }
        Get-ChildItem -LiteralPath $base -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $container = $_.Directory.Parent
            if ($null -eq $container) { return }
            $rel = $container.FullName.Substring($RootPath.TrimEnd('\').Length).TrimStart('\').Replace('\', '/')
            if ($rel -and -not $found.Contains($rel)) { $found.Add($rel) }
        }
    }
    return @($found | Sort-Object)
}

# Synapse VS Code extension ships Copilot skills; the version folder changes on
# every extension update, so resolve it at install time instead of hardcoding.
function Get-SynapseSkillDirs {
    $extRoot = Join-Path $env:USERPROFILE '.vscode\extensions'
    if (-not (Test-Path -LiteralPath $extRoot)) { return @() }
    $dirs = @()
    Get-ChildItem -LiteralPath $extRoot -Directory -Filter 'synapsevscode.synapse-*' -ErrorAction SilentlyContinue | ForEach-Object {
        $skills = Join-Path $_.FullName 'copilot\skills'
        if (Test-Path -LiteralPath $skills) { $dirs += ('~/.vscode/extensions/' + $_.Name + '/copilot/skills') }
    }
    return @($dirs)
}

# -- Helpers: independent business repository onboarding ----------------
function ConvertTo-SafeFolderName {
    param([string]$Name, [string]$Default = 'Repository')
    $value = ([string]$Name).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $value = $value.Replace([string]$c, '-') }
    $value = [regex]::Replace($value, '\s+', ' ').Trim().TrimEnd('.', ' ')
    if ($value -in @('.', '..') -or [string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    return $value
}

function Read-NonNegativeCount {
    param([string]$Prompt, [int]$Default = 0)
    while ($true) {
        $raw = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $count = 0
        if ([int]::TryParse($raw, [ref]$count) -and $count -ge 0 -and $count -le 50) { return $count }
        Write-Host '  Enter a whole number from 0 to 50.' -ForegroundColor Yellow
    }
}

function Test-BusinessRepositoryUrl {
    param([string]$Provider, [string]$Url)
    $value = ([string]$Url).Trim()
    if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith('-') -or $value -match '[\r\n]') { return $false }

    # Local bare repositories are accepted only by the isolated regression harness.
    if ($env:FABRIC_AGENTIC_ALLOW_LOCAL_REPO_FIXTURES -eq '1' -and $value -match '^file://') { return $true }

    if ($value -match '^https?://') {
        try {
            $uri = [Uri]$value
            # Clone URLs are repository identities, not API links. Reject query
            # strings and fragments so tokens cannot be smuggled into the local
            # repository map through an otherwise valid HTTPS URL.
            if (-not [string]::IsNullOrWhiteSpace($uri.Query) -or
                -not [string]::IsNullOrWhiteSpace($uri.Fragment)) { return $false }
            # Never accept an embedded password/token. Azure DevOps HTTPS URLs may
            # legitimately contain a username-like organisation prefix before @.
            if ($uri.UserInfo -match ':') { return $false }
            if ($Provider -eq 'github' -and -not [string]::IsNullOrWhiteSpace($uri.UserInfo)) { return $false }
        } catch { return $false }
    }

    if ($Provider -eq 'github') {
        return ($value -match '^https://github\.com/[^/\s]+/[^/\s]+/?$' -or
                $value -match '^git@github\.com:[^/\s]+/[^/\s]+$' -or
                $value -match '^ssh://git@github\.com/[^/\s]+/[^/\s]+/?$')
    }
    if ($Provider -eq 'azure-devops') {
        return ($value -match '^https://(?:[^/@\s]+@)?dev\.azure\.com/[^/\s]+/[^/\s]+/_git/[^/\s]+/?$' -or
                $value -match '^https://[^./\s]+\.visualstudio\.com/[^/\s]+/_git/[^/\s]+/?$' -or
                $value -match '^git@ssh\.dev\.azure\.com:v3/[^/\s]+/[^/\s]+/[^/\s]+$' -or
                $value -match '^ssh://git@ssh\.dev\.azure\.com/v3/[^/\s]+/[^/\s]+/[^/\s]+/?$')
    }
    return $false
}

function Get-NormalizedRepositoryUrl {
    param([string]$Url)
    $value = ([string]$Url).Trim().Replace('\', '/').TrimEnd('/')
    if ($value.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(0, $value.Length - 4)
    }
    return $value.ToLowerInvariant()
}

function Merge-CodeWorkspace {
    param([string]$Path, [string]$WorkspaceName, [string]$PrimaryRootPath = '.')
    if ([string]::IsNullOrWhiteSpace($WorkspaceName)) { $WorkspaceName = 'Fabric Agentic Workspace' }
    if ([string]::IsNullOrWhiteSpace($PrimaryRootPath)) { $PrimaryRootPath = '.' }
    # The workspace file may live OUTSIDE the workspace folder (e.g. an unsaved
    # session file in TEMP), so the primary root can be an absolute path instead
    # of '.'. Normalise separators so the emitted JSON is portable.
    $primaryPath = if ($PrimaryRootPath -eq '.') { '.' } else { ([string]$PrimaryRootPath).Replace('\', '/').TrimEnd('/') }
    $primaryKey = $primaryPath.ToLowerInvariant()
    $workspace = [ordered]@{}
    $folders = @()
    if (Test-Path -LiteralPath $Path) {
        $parsed = ConvertFrom-JsonLenient (Get-Content -LiteralPath $Path -Raw)
        if ($null -ne $parsed) {
            foreach ($prop in $parsed.PSObject.Properties) { $workspace[$prop.Name] = $prop.Value }
            $folders = @($parsed.folders)
        } else {
            $backup = "$Path.bak"
            Copy-Item -LiteralPath $Path -Destination $backup -Force
            Write-Host "  Backed up malformed workspace file to $([IO.Path]::GetFileName($backup))." -ForegroundColor Yellow
        }
    }

    # A single root, named after the actual workspace folder. Business
    # repositories stay nested under source-control-repositories/ and are NOT
    # added as separate roots; VS Code discovers their branch worktrees through
    # the repository scan settings below.
    $seen = @{}
    $merged = @()
    foreach ($folder in $folders) {
        if (-not $folder -or [string]::IsNullOrWhiteSpace([string]$folder.path)) { continue }
        $folderPath = ([string]$folder.path).Replace('\', '/').TrimEnd('/')
        $key = $folderPath.ToLowerInvariant()
        if ($key -eq 'source-control-repositories' -or $key.StartsWith('source-control-repositories/')) { continue }
        # A relative '.' root from an older in-folder workspace file would resolve
        # against the session file's TEMP location once the primary root is absolute.
        if ($key -eq '.' -and $primaryPath -ne '.') { continue }
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $merged += $folder }
    }
    if ($seen.ContainsKey($primaryKey)) {
        $merged = @($merged | ForEach-Object {
            if (([string]$_.path).Replace('\', '/').TrimEnd('/') -eq $primaryPath) {
                [pscustomobject][ordered]@{ name = $WorkspaceName; path = $primaryPath }
            } else { $_ }
        })
    } else {
        $merged = @([pscustomobject][ordered]@{ name = $WorkspaceName; path = $primaryPath }) + $merged
        $seen[$primaryKey] = $true
    }
    $workspace['folders'] = @($merged)
    if (-not $workspace.Contains('settings') -or $null -eq $workspace['settings']) {
        $workspace['settings'] = [ordered]@{}
    }
    $settings = $workspace['settings']
    # Window-scoped: folder .vscode/settings.json is ignored in multi-root, so it must live here.
    # Forced true (not merge-if-absent) because Team Leads cannot dispatch workers without it.
    if ($settings -is [System.Collections.IDictionary]) {
        $settings['chat.subagents.allowInvocationsFromSubagents'] = $true
        if (-not $settings.Contains('git.autoRepositoryDetection')) {
            $settings['git.autoRepositoryDetection'] = 'subFolders'
        }
        if (-not $settings.Contains('git.repositoryScanIgnoredFolders')) {
            $settings['git.repositoryScanIgnoredFolders'] = @('skills-for-fabric', 'power-bi-agentic-development')
        }
        if (-not $settings.Contains('git.repositoryScanMaxDepth')) {
            $settings['git.repositoryScanMaxDepth'] = 4
        }
    } elseif ($settings -is [PSCustomObject]) {
        if ($settings.PSObject.Properties['chat.subagents.allowInvocationsFromSubagents']) {
            $settings.'chat.subagents.allowInvocationsFromSubagents' = $true
        } else {
            $settings | Add-Member -NotePropertyName 'chat.subagents.allowInvocationsFromSubagents' -NotePropertyValue $true
        }
        if (-not $settings.PSObject.Properties['git.autoRepositoryDetection']) {
            $settings | Add-Member -NotePropertyName 'git.autoRepositoryDetection' -NotePropertyValue 'subFolders'
        }
        if (-not $settings.PSObject.Properties['git.repositoryScanIgnoredFolders']) {
            $settings | Add-Member -NotePropertyName 'git.repositoryScanIgnoredFolders' -NotePropertyValue @('skills-for-fabric', 'power-bi-agentic-development')
        }
        if (-not $settings.PSObject.Properties['git.repositoryScanMaxDepth']) {
            $settings | Add-Member -NotePropertyName 'git.repositoryScanMaxDepth' -NotePropertyValue 4
        }
    }
    Write-ManagedFile -Path $Path -Content ($workspace | ConvertTo-Json -Depth 20)
}

function Add-GitIgnoreRules {
    param([string]$Path, [string]$Heading, [string[]]$Rules)
    $existing = ''
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    }
    $missing = @()
    foreach ($rule in $Rules) {
        if ($existing -notmatch "(?m)^\s*$([regex]::Escape($rule))\s*$") { $missing += $rule }
    }
    if ($missing.Count -eq 0) { return }
    $prefix = if ([string]::IsNullOrWhiteSpace($existing)) { '' } else { "`r`n" }
    $content = $prefix + "# $Heading`r`n" + ($missing -join "`r`n") + "`r`n"
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

$totalSteps = 9

# =====================================================================
# STEP 1  -- Workspace folder configuration
# =====================================================================
Show-Step 1 $totalSteps "Workspace Folder"

if ($EmitAgentsTo) {
    $rootPath = [System.IO.Path]::GetFullPath($EmitAgentsTo)
    if (-not (Test-Path -LiteralPath $rootPath)) { New-Item -ItemType Directory -Path $rootPath -Force | Out-Null }
    Write-Host "  [emit mode] Generating into: $rootPath" -ForegroundColor Cyan
} else {

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
while ($true) {
$choice = (Read-Host "  Enter 1 or 2").Trim()
# Accept the obvious synonyms, re-ask on anything else (an empty or 'y' answer
# used to fall straight into option 2 and surprise the user).
if ($choice -match '^(1|y|yes)$') { $choice = '1' }
elseif ($choice -match '^(2|n|no)$') { $choice = '2' }
else { Write-Host "  Please answer 1 (existing folder) or 2 (create a new one)." -ForegroundColor Yellow; continue }

if ($choice -eq '1') {
    $rootPath = (Read-Host "`n  Enter the full path to your existing Fabric folder").Trim().Trim('"').Trim("'").TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($rootPath)) { Write-Host "  No path given." -ForegroundColor Yellow; continue }
    if (-not [System.IO.Path]::IsPathRooted($rootPath) -or $rootPath.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) {
        Write-Host "  That is not a valid full path (expected something like C:\Users\you\Fabric): $rootPath" -ForegroundColor Red
        continue
    }
    if (-not (Test-Path -LiteralPath $rootPath)) {
        Write-Host "`n  That folder does not exist: $rootPath" -ForegroundColor Red
        $create = Read-Host "  Create it? (y/n)"
        if ($create -notmatch '^(y|yes)$') { Write-Host "  Aborted."; exit 0 }
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
    Write-Host "  (type just a folder name, or a full path like D:\Work\Fabric to put it elsewhere)" -ForegroundColor DarkGray
    $folderName = (Read-Host "  Enter a name (default: $defaultName)").Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($folderName)) { $folderName = $defaultName }
    if ([System.IO.Path]::IsPathRooted($folderName)) {
        # A full path was typed: honour it instead of nesting it under the profile.
        $rootPath = $folderName.TrimEnd('\')
    } else {
        $safeName = ConvertTo-SafeFolderName -Name $folderName -Default $defaultName
        if ($safeName -ne $folderName) { Write-Host "  Folder name adjusted to: $safeName" -ForegroundColor DarkGray }
        $rootPath = Join-Path $defaultParent $safeName
    }
    try { $rootPath = [System.IO.Path]::GetFullPath($rootPath) } catch {
        Write-Host "  That is not a valid folder name or path: $folderName" -ForegroundColor Red
        continue
    }
    if (-not (Test-Path -LiteralPath $rootPath)) {
        New-Item -ItemType Directory -Path $rootPath -Force | Out-Null
        Write-Host "  Created: $rootPath" -ForegroundColor Green
    } else {
        Write-Host "  Folder already exists: $rootPath" -ForegroundColor Yellow
    }
}

    # -- Guard: the workspace target must NOT be the installer's own folder -----
    # Scaffolding on top of the installer would pollute the distributable (the
    # folder that ships only the .bat + .ps1). Reject and loop back for a correct
    # path, as many times as needed.
    $installerFull = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    $rootFull = try { [System.IO.Path]::GetFullPath($rootPath).TrimEnd('\') } catch { '' }
    if ($rootFull -and ($rootFull -ieq $installerFull)) {
        Write-Host ""
        Write-Host "  ================================================================" -ForegroundColor Red
        Write-Host "   FORBIDDEN: that is the installer's own folder -- not allowed." -ForegroundColor Red
        Write-Host "   $installerFull" -ForegroundColor Red
        Write-Host ""
        Write-Host "   The workspace must be a SEPARATE folder, otherwise the setup" -ForegroundColor Red
        Write-Host "   would overwrite the installer itself. Please provide a" -ForegroundColor Red
        Write-Host "   different folder." -ForegroundColor Red
        Write-Host "  ================================================================" -ForegroundColor Red
        Write-Host ""
        continue
    }
    break
}

Write-Host "`n  Workspace target: $rootPath" -ForegroundColor White

# -- Workflow explanation & workspace prompts ---------------------------
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "       HOW THIS WORKSPACE WORKS -- ONE LIFECYCLE, THREE WAYS" -ForegroundColor Cyan
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This local folder is your main working directory for Fabric." -ForegroundColor White
Write-Host "  All work shares ONE safe lifecycle, and you can edit on top of" -ForegroundColor White
Write-Host "  it in THREE ways. Pick whichever fits the task." -ForegroundColor White
Write-Host ""
Write-Host "  THE SHARED LIFECYCLE (common to all three ways):" -ForegroundColor White
Write-Host ""
Write-Host "     Fabric DEV Workspace        <- your changes land here" -ForegroundColor Yellow
Write-Host "            |  commit (Fabric Portal > Git Integration)" -ForegroundColor DarkGray
Write-Host "            v" -ForegroundColor DarkGray
Write-Host "     Azure DevOps (DEV branch)   <- safety net: revert anytime" -ForegroundColor Yellow
Write-Host "            |  Pull Request (DEV -> PROD)" -ForegroundColor DarkGray
Write-Host "            v" -ForegroundColor DarkGray
Write-Host "     Azure DevOps (PROD branch)" -ForegroundColor Yellow
Write-Host "            |  sync" -ForegroundColor DarkGray
Write-Host "            v" -ForegroundColor DarkGray
Write-Host "     Fabric PROD Workspace       <- stable production" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Whatever editing method you use, supported item definitions can" -ForegroundColor White
Write-Host "  follow the same DEV -> Git -> PR -> PROD promotion path. Live and" -ForegroundColor White
Write-Host "  hybrid edits need extra care until they are validated and committed;" -ForegroundColor White
Write-Host "  Git does not restore item data, unsupported items, or every setting." -ForegroundColor White
Write-Host ""
Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  THE THREE WAYS OF WORKING" -ForegroundColor Cyan
Write-Host "  ----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "  A) FULL LOCAL  (file-first -- the default)" -ForegroundColor Green
Write-Host "       Fabric Portal --(extension: pull)--> local files" -ForegroundColor DarkGray
Write-Host "       --> edit with AI agents or by hand --(push)--> Fabric DEV." -ForegroundColor DarkGray
Write-Host "       * Pull items (Semantic Models, Notebooks, Pipelines, ...)" -ForegroundColor DarkGray
Write-Host "         into sub-folders here using the Fabric extension." -ForegroundColor DarkGray
Write-Host "       * Edit locally with Copilot agents & skills (TMDL, DAX," -ForegroundColor DarkGray
Write-Host "         pipeline JSON, notebooks); push back and test in portal." -ForegroundColor DarkGray
Write-Host "       Best for bulk/structured edits, diffs, offline work." -ForegroundColor DarkGray
Write-Host "       Needs only: Fabric extension + Git." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  B) FULL LIVE  (in-workspace -- no local round-trip)" -ForegroundColor Green
Write-Host "       Agents act directly on the live DEV workspace via Fabric" -ForegroundColor DarkGray
Write-Host "       REST (updateDefinition) + the two MCP servers." -ForegroundColor DarkGray
Write-Host "       * Run DAX (EVALUATE) on running models: compare TEST vs PROD." -ForegroundColor DarkGray
Write-Host "       * Read real deployed GUIDs / SQL endpoints; edit in place;" -ForegroundColor DarkGray
Write-Host "         create items." -ForegroundColor DarkGray
Write-Host "       Needs: Fabric MCP + Power BI model MCP servers, plus fab/az." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  C) HYBRID  (local + live)" -ForegroundColor Green
Write-Host "       Mix both in one session -- some items as files, others live." -ForegroundColor DarkGray
Write-Host "       GOLDEN RULE: keep local = live workspace. Each session pull" -ForegroundColor DarkGray
Write-Host "       only what you need, do your mixed work, then re-pull (or" -ForegroundColor DarkGray
Write-Host "       clean up local) before a new job so local = live workspace" -ForegroundColor DarkGray
Write-Host "       and you avoid drift." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Diagrams: assets\workflow-mode-local|live|hybrid.svg  (see README)." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Git versioning: this workspace is initialized with Git, so every" -ForegroundColor White
Write-Host "  local change is tracked with full history and can be reverted." -ForegroundColor White
Write-Host ""
Write-Host "  PRO TIP:" -ForegroundColor Magenta
Write-Host "    Connect your Fabric workspaces to Azure DevOps (or GitHub) for" -ForegroundColor DarkGray
Write-Host "    backup + gated DEV -> TEST -> PROD promotion. Set this up in" -ForegroundColor DarkGray
Write-Host "    Fabric Portal > Workspace Settings > Git Integration." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  PRO TIP:" -ForegroundColor Magenta
Write-Host "    Install the 'Fabric Data Engineer Remote' extension to run" -ForegroundColor DarkGray
Write-Host "    notebook cells against remote Spark from VS Code (agentic" -ForegroundColor DarkGray
Write-Host "    run/inspect loop without leaving the editor)." -ForegroundColor DarkGray
Write-Host "    Install: code --install-extension synapsevscode.vscode-synapse-remote" -ForegroundColor DarkGray
Write-Host ""

# -- Ask how many workspaces to scaffold ---------------------------------
Write-Host "  How many Fabric workspaces will you work with?" -ForegroundColor Yellow
Write-Host "  (The Fabric extension will clone items into separate folders)" -ForegroundColor DarkGray
Write-Host ""
$wsCountInput = Read-Host "  Number of workspaces (default: 1)"
if ([string]::IsNullOrWhiteSpace($wsCountInput)) { $wsCountInput = '1' }
$wsCount = 0
if (-not [int]::TryParse($wsCountInput, [ref]$wsCount) -or $wsCount -lt 0) {
    Write-Host "  Invalid number. Skipping workspace folder creation." -ForegroundColor Yellow
    $wsCount = 0
}

$workspaceNames = @()
if ($wsCount -gt 0) {
    Write-Host ""
    for ($i = 1; $i -le $wsCount; $i++) {
        while ($true) {
            $wsName = Read-Host "  Name for Workspace $i"
            if ([string]::IsNullOrWhiteSpace($wsName)) {
                $wsName = "Workspace $i"
            }
            $wsPath = Join-Path $rootPath $wsName
            if (Test-Path $wsPath) {
                Write-Host "  A folder named '$wsName' already exists in this workspace." -ForegroundColor Red
                Write-Host "  Workspace folders contain your Fabric items and will NOT be overwritten." -ForegroundColor Red
                Write-Host "  Please choose a different name.`n" -ForegroundColor Yellow
            } elseif ($workspaceNames -contains $wsName) {
                Write-Host "  You already used the name '$wsName' for another workspace." -ForegroundColor Red
                Write-Host "  Please choose a different name.`n" -ForegroundColor Yellow
            } else {
                $workspaceNames += $wsName
                break
            }
        }
    }
    Write-Host ""
    Write-Host "  Workspace folders to create:" -ForegroundColor White
    foreach ($name in $workspaceNames) {
        Write-Host "    -> $name (new)" -ForegroundColor Green
    }
}

# -- Ask separately about independent GitHub / Azure DevOps repositories --
$businessRepoPlans = @()
Write-Host ''
Write-Host '  BUSINESS SOURCE CONTROL (OPTIONAL)' -ForegroundColor Cyan
Write-Host '  Clone your own GitHub or Azure DevOps repositories used for Fabric' -ForegroundColor DarkGray
Write-Host '  Git integration or ALM. Each repository keeps its own live branches and' -ForegroundColor DarkGray
Write-Host '  stays independent of this outer workspace repository.' -ForegroundColor DarkGray
Write-Host ''
$repoOnboardingAnswer = Read-Host '  Set up business source control now? (y/N)'
if ($repoOnboardingAnswer -match '^(y|yes)$') {
    $repoCount = Read-NonNegativeCount -Prompt '  How many repositories do you want to clone?'
    $plannedFolderNames = @()
    for ($repoIndex = 1; $repoIndex -le $repoCount; $repoIndex++) {
        Write-Host ''
        Write-Host "  Repository $repoIndex of $repoCount" -ForegroundColor Cyan

        # The clone URL is the only thing we ask for. The provider and a safe
        # folder name are derived from it; live branches are mirrored at clone time.
        $cloneUrl = $null
        $provider = $null
        while (-not $cloneUrl) {
            $candidateUrl = (Read-Host '    Clone URL (no PAT or password)').Trim()
            if ($candidateUrl -match 'github\.com') { $provider = 'github' }
            elseif ($candidateUrl -match 'dev\.azure\.com|\.visualstudio\.com|ssh\.dev\.azure\.com') { $provider = 'azure-devops' }
            else { $provider = $null }
            if ($provider -and (Test-BusinessRepositoryUrl -Provider $provider -Url $candidateUrl)) {
                $cloneUrl = $candidateUrl
            } else {
                Write-Host '    Not a recognised GitHub/Azure DevOps clone URL, or it contains credentials.' -ForegroundColor Yellow
                Write-Host '    Paste the plain HTTPS or SSH clone URL from your repository.' -ForegroundColor DarkGray
            }
        }

        # Derive the repository (folder) name from the last path segment of the URL.
        $leaf = ((($cloneUrl -replace '\.git$', '') -replace '/$', '') -split '[/:]')[-1]
        $defaultFolder = ConvertTo-SafeFolderName -Name $leaf -Default "Repository-$repoIndex"
        $folderName = $defaultFolder
        $suffix = 2
        while ($plannedFolderNames -contains $folderName.ToLowerInvariant()) {
            $folderName = "$defaultFolder-$suffix"
            $suffix++
        }
        $plannedFolderNames += $folderName.ToLowerInvariant()

        $businessRepoPlans += [pscustomobject][ordered]@{
            id          = $folderName.ToLowerInvariant().Replace(' ', '-')
            displayName = $folderName
            provider    = $provider
            cloneUrl    = $cloneUrl
            folderName  = $folderName
            localPath   = "source-control-repositories/$folderName"
        }
        Write-Host "    Will clone into: source-control-repositories/$folderName" -ForegroundColor Green
    }
    Write-Host "`n  $($businessRepoPlans.Count) repository plan(s) collected." -ForegroundColor Green
} else {
    Write-Host '  No business repositories will be cloned. Existing clones remain untouched.' -ForegroundColor DarkGray
}

Read-Host "`n  Press Enter to continue..."
}

# =====================================================================
# STEP 2  -- Prerequisites check
# ====================================================================="
Show-Step 2 $totalSteps "Checking Prerequisites"

if (-not $EmitAgentsTo) {
$missing = @()
$warnings = @()

# Recognise anything a PREVIOUS run already installed (refresh PATH from the
# registry + re-add Python Scripts dirs) so we do not re-attempt tools that are
# in fact present. This is the fix for "installs but shows not found" on locked PCs.
Sync-ToolPaths

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

# Fabric VS Code Extension check
$installedExts = Get-InstalledVsCodeExtensions -VsCode $vscodeCmd
$fabricExtFound = Test-VsCodeExtension -Id 'fabric.vscode-fabric' -List $installedExts
if ($fabricExtFound) {
    Write-Host "  Fabric Extension: found" -ForegroundColor Green
}
if (-not $fabricExtFound) {
    Write-Host "" 
    Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host "  !!                                                        !!" -ForegroundColor Red
    Write-Host "  !!   FABRIC VS CODE EXTENSION NOT DETECTED                !!" -ForegroundColor Red
    Write-Host "  !!                                                        !!" -ForegroundColor Red
    Write-Host "  !!   The Microsoft Fabric extension for VS Code is        !!" -ForegroundColor Red
    Write-Host "  !!   REQUIRED for the pull/push workflow with Fabric.     !!" -ForegroundColor Red
    Write-Host "  !!                                                        !!" -ForegroundColor Red
    Write-Host "  !!   Install it from the VS Code Extensions Marketplace:  !!" -ForegroundColor Red
    Write-Host "  !!   Search 'Microsoft Fabric' or install via:            !!" -ForegroundColor Red
    Write-Host "  !!   code --install-extension fabric.vscode-fabric        !!" -ForegroundColor Red
    Write-Host "  !!                                                        !!" -ForegroundColor Red
    Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host ""
    $warnings += "Fabric VS Code extension not found -- install it before using the workspace"
}

# TMDL extension (optional -- provides syntax highlighting & validation for .tmdl files)
$tmdlExtFound = Test-VsCodeExtension -Id 'analysis-services.tmdl' -List $installedExts
if ($tmdlExtFound) {
    Write-Host "  TMDL Extension: found" -ForegroundColor Green
} else {
    Write-Host "  TMDL Extension: not found (recommended)" -ForegroundColor Yellow
    Write-Host "         Provides syntax highlighting and validation for .tmdl files." -ForegroundColor DarkGray
    Write-Host "         This workspace works heavily with Semantic Model TMDL definitions." -ForegroundColor DarkGray
    Write-Host "         Install via: code --install-extension analysis-services.tmdl" -ForegroundColor DarkGray
}

# Fabric CLI (fab) -- RECOMMENDED (optional). Primary CLI for Fabric control-plane:
# item lifecycle, jobs, export/import, OneLake file ops, table ops. Not required --
# the core workflow (Fabric extension + agents editing local files) needs no CLI.
if (-not (Test-CliResilient -Name 'fab' -VersionPattern '(?im)^\s*fab version')) {
    Write-Host "  Fabric CLI (fab): not found (recommended)" -ForegroundColor Yellow
    Write-Host "         Primary CLI for Fabric API, jobs, export/import, OneLake and table ops." -ForegroundColor DarkGray
    Write-Host "         Needs Python 3.10-3.13. Reference: https://github.com/microsoft/fabric-cli" -ForegroundColor DarkGray
    # Ensure a REAL Python exists (install it if missing), then install fab via pip.
    $realPy = Ensure-Python
    if ($realPy) {
        # Two shots, each resilient to transient network failures (--retries/--timeout):
        #   1. plain install -> lands in the interpreter's own Scripts dir, which is
        #      already on PATH for a winget/python.org per-user Python (the common case)
        #   2. --user fallback -> for system Pythons where the prefix isn't writable
        # Listing both also gives a free retry if the first attempt dies mid-download.
        Try-InstallOptionalTool -Name "Fabric CLI (fab)" -CheckCmd "fab" -Attempts @(
            @{ Exe = $realPy; Args = @("-m", "pip", "install", "--upgrade", "--retries", "5", "--timeout", "60", "ms-fabric-cli") }
            @{ Exe = $realPy; Args = @("-m", "pip", "install", "--user", "--upgrade", "--retries", "5", "--timeout", "60", "ms-fabric-cli") }
        ) -ManualUrl "https://github.com/microsoft/fabric-cli (pip install ms-fabric-cli)" | Out-Null
    } else {
        Write-Host "         Could not install Python automatically (corporate policy, no winget, or no network)." -ForegroundColor DarkGray
        Write-Host "         No problem -- the workspace works fine without it. Open the workspace and ask the" -ForegroundColor DarkGray
        Write-Host "         Fabric agent to walk you through installing Python + the Fabric CLI when convenient." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  Fabric CLI (fab): found" -ForegroundColor Green
}

# az CLI -- OPTIONAL (fallback). Only needed for SQL/TDS (sqlcmd -G) and non-Fabric
# token audiences (Storage, database.windows.net). fab covers the rest.
if (-not (Test-CliResilient -Name 'az')) {
    Write-Host "  az CLI: not found (optional, fallback)" -ForegroundColor Yellow
    Write-Host "         Only needed for SQL/TDS (sqlcmd) and non-Fabric token audiences; fab covers the rest." -ForegroundColor DarkGray
    Write-Host "    Installing az CLI automatically..." -ForegroundColor White

    # 1) winget (per-machine MSI). Silent, no admin where allowed; commonly
    #    blocked with exit 1603 on locked-down PCs, in which case we fall through.
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "    Trying winget: Microsoft.AzureCLI ..." -ForegroundColor White
        try { & winget install --silent --accept-package-agreements --accept-source-agreements -e --id Microsoft.AzureCLI 2>$null | Out-Null } catch { }
        Sync-ToolPaths
    }

    # 2) Isolated-venv pip install -- the reliable no-admin route. A plain
    #    `pip install azure-cli` overflows the Windows 260-char MAX_PATH limit on
    #    the Microsoft Store Python (azure-cli has a very deep package tree); a
    #    venv at a short profile-root path sidesteps it (see Install-AzCliViaVenv).
    if (Test-CliResilient -Name 'az' -Retries 1) {
        Write-Host "  az CLI: installed (via winget)." -ForegroundColor Green
    } elseif (Install-AzCliViaVenv) {
        Write-Host "  az CLI: installed (isolated environment)." -ForegroundColor Green
    } else {
        Write-Host "  az CLI: could not be installed automatically (optional -- the workspace works without it)." -ForegroundColor Yellow
        Write-Host "         Install it later if you need SQL/TDS or non-Fabric tokens: https://aka.ms/installazurecli" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  az CLI: found" -ForegroundColor Green
}

# -- MCP server extensions for full-live / hybrid modes (auto-installed) ------
# These two VS Code extensions provide the MCP servers the agents use for the
# full-live and hybrid ways of working. They are optional for full-LOCAL mode.
Write-Host ""
Write-Host "  Checking MCP server extensions (for full-live / hybrid modes)..." -ForegroundColor Cyan
$mcpExtensions = @(
    @{ Id = 'fabric.vscode-fabric-mcp-server';        Name = 'Fabric MCP server';                  Desc = 'items, OneLake, tables, definitions' },
    @{ Id = 'analysis-services.powerbi-modeling-mcp';  Name = 'Power BI semantic-model MCP server';  Desc = 'live XMLA DAX + model edits' }
)
if (-not $vscodeCmd) {
    Write-Host "  MCP: skipped (VS Code CLI not found)." -ForegroundColor Yellow
    $warnings += "MCP server extensions not checked (VS Code CLI not found) -- needed for full-live/hybrid modes"
} else {
    $installedExts = Get-InstalledVsCodeExtensions -VsCode $vscodeCmd
    foreach ($mcp in $mcpExtensions) {
        $mcpFound = Test-VsCodeExtension -Id $mcp.Id -List $installedExts
        if ($mcpFound) {
            Write-Host "  $($mcp.Name): found" -ForegroundColor Green
        } else {
            Write-Host "  $($mcp.Name): not found -- installing ($($mcp.Desc))..." -ForegroundColor Yellow
            if (Install-VsCodeExtension -VsCode $vscodeCmd -Id $mcp.Id) {
                Write-Host "  $($mcp.Name): installed" -ForegroundColor Green
                $installedExts = Get-InstalledVsCodeExtensions -VsCode $vscodeCmd
            } else {
                Write-Host "  $($mcp.Name): auto-install failed -- install manually:" -ForegroundColor Yellow
                Write-Host "         code --install-extension $($mcp.Id)" -ForegroundColor DarkGray
                Write-Host "         (On a corporate network this is usually a TLS/proxy certificate" -ForegroundColor DarkGray
                Write-Host "          issue -- installing from the VS Code Extensions view works.)" -ForegroundColor DarkGray
                $warnings += "$($mcp.Name) ($($mcp.Id)) auto-install failed -- run: code --install-extension $($mcp.Id)"
            }
        }
    }
    Write-Host "  (MCP servers power full-live / hybrid modes; full-local mode does not need them.)" -ForegroundColor DarkGray
}

# =====================================================================
# Tool inventory -- record core tools and detect/opt-in specialist tools.
# Result is written later to .github/agent-docs/tool-status.json (Step 7).
# Specialists read that file and use deterministic tools when present, else
# fall back gracefully. Detection is honest: we store what was actually found.
# =====================================================================
Write-Host ""
Write-Host "  Building tool inventory for the agents (tool-status.json)..." -ForegroundColor Cyan

# Load any prior inventory so re-runs stay quiet for tools already declined.
$priorToolStatus = $null
$priorToolStatusPath = Join-Path $rootPath ".github\agent-docs\tool-status.json"
if (Test-Path $priorToolStatusPath) {
    try { $priorToolStatus = Get-Content $priorToolStatusPath -Raw | ConvertFrom-Json } catch { }
}

# -- Core tools (auto best-effort above) -- record their final detected state.
$fabHit = Resolve-ToolCommand -Aliases @('fab')
$fabVersion = if ($fabHit) { Get-ToolVersion -Exe $(if ($fabHit.path) { $fabHit.path } else { 'fab' }) } else { $null }
if ($fabHit -and $fabVersion -match '(?im)^\s*fab version') {
    Set-ToolStatus -Key 'fab' -Found $true -Command $fabHit.command -Path $fabHit.path -Version $fabVersion -Category 'core-cli' -InstallMode 'auto'
} elseif ($fabHit) {
    Set-ToolStatus -Key 'fab' -Found $false -Category 'core-cli' -InstallMode 'auto' -Reason "a different 'fab' command is on PATH ($($fabHit.path)); Microsoft Fabric CLI (ms-fabric-cli) not detected"
} else {
    Set-ToolStatus -Key 'fab' -Found $false -Category 'core-cli' -InstallMode 'auto' -Reason 'not installed'
}

$azHit = Resolve-ToolCommand -Aliases @('az')
if ($azHit) {
    Set-ToolStatus -Key 'az' -Found $true -Command $azHit.command -Path $azHit.path -Version (Get-ToolVersion -Exe 'az' -VersionArgs @('version','-o','tsv')) -Category 'core-cli' -InstallMode 'auto'
} else {
    Set-ToolStatus -Key 'az' -Found $false -Category 'core-cli' -InstallMode 'auto' -Reason 'not installed'
}

# -- MCP server extensions -- record final state (advisory; gated by this JSON).
# IMPORTANT: for MCP entries `found` means only "extension installed" -- NOT that
# the MCP tools are callable in the chat session. Both extensions self-register
# their servers via `mcpServerDefinitionProviders` (no mcp.json exists or is
# needed); whether their tools are actually exposed depends on the servers being
# started and selected in the chat tool picker (mind the ~128-tool session limit).
# So we ALSO record `extensionInstalled` (proven here) and `mcpToolsCallable`
# ('unknown' until the agent runs the startup MCP self-test).
$fabMcpFound = Test-VsCodeExtension -Id 'fabric.vscode-fabric-mcp-server' -List $installedExts
$fabMcpReason = $null; if (-not $fabMcpFound) { $fabMcpReason = 'extension not installed' }
Set-ToolStatus -Key 'fabricMcpServer' -Found $fabMcpFound -Category 'mcp-extension' -InstallMode 'auto' -ExtensionId 'fabric.vscode-fabric-mcp-server' -Reason $fabMcpReason -Extra @{ extensionInstalled = $fabMcpFound; mcpToolsCallable = 'unknown' }
$pbiMcpFound = Test-VsCodeExtension -Id 'analysis-services.powerbi-modeling-mcp' -List $installedExts
$pbiMcpReason = $null; if (-not $pbiMcpFound) { $pbiMcpReason = 'extension not installed' }
Set-ToolStatus -Key 'powerBiModelMcpServer' -Found $pbiMcpFound -Category 'mcp-extension' -InstallMode 'auto' -ExtensionId 'analysis-services.powerbi-modeling-mcp' -Reason $pbiMcpReason -Extra @{ extensionInstalled = $pbiMcpFound; mcpToolsCallable = 'unknown' }

# -- Specialist tools -- detect, explain, and ask Y/N per tool.
Write-Host ""
Write-Host "  Specialist tools (optional -- each is detected, explained, and only" -ForegroundColor Cyan
Write-Host "  installed if you say Yes; declining never blocks setup):" -ForegroundColor Cyan

# sqlcmd -- SQL endpoint query execution (Data Engineering / Applications).
# no-admin `winget download` of the go-sqlcmd MSI (proxy-friendly) which we then
# extract with `msiexec /a`; if winget is unavailable/blocked we fall back to the
# portable go-sqlcmd zip from GitHub releases. Either way -> %LOCALAPPDATA%\Programs.
Invoke-OptionalToolPrompt -Key 'sqlcmd' -Name 'sqlcmd' `
    -Purpose 'Run queries against Fabric Warehouse / SQL endpoints (TDS).' `
    -Provider 'https://aka.ms/go-sqlcmd' `
    -Aliases @('sqlcmd') -SearchRoots @("$env:LOCALAPPDATA\Programs\sqlcmd") `
    -Prior $priorToolStatus -Install {
        if (Install-ViaWingetDownload -WingetId 'Microsoft.Sqlcmd' -ExeName 'sqlcmd.exe' -DestName 'sqlcmd') { return }
        $arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'amd64' }
        $u = Get-GitHubReleaseAssetUrl -Repo 'microsoft/go-sqlcmd' -NamePattern "sqlcmd-windows-$arch\.zip$"
        Install-PortableZipTool -Url $u -DestName 'sqlcmd' -ExeName 'sqlcmd.exe' | Out-Null
    }

# Tabular Editor 2 -- semantic-model validation / BPA / automation (free, MIT).
# GUI app -> do not probe --version (would launch the UI). TE3 (paid) and the new
# cross-platform `te` CLI are DIFFERENT products: detected separately below, never
# "updated" with a TE2 release.
Invoke-OptionalToolPrompt -Key 'tabularEditor' -Name 'Tabular Editor 2' `
    -Purpose 'Semantic model validation, Best Practice Analyzer, and automation.' `
    -Provider 'https://tabulareditor.com (TE2 is free; TE3 is paid)' `
    -Aliases @('TabularEditor.exe','TabularEditor2.exe') `
    -SearchRoots @("$env:LOCALAPPDATA\Programs","$env:ProgramFiles","${env:ProgramFiles(x86)}") `
    -ProbeVersion $false -Prior $priorToolStatus -Install {
        # TE2 -- free, open-source (MIT). winget id 'TabularEditor.TabularEditor.2';
        # we NEVER install the paid TE3 (id 'TabularEditor.TabularEditor.3').
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            if (Install-ViaWingetDownload -WingetId 'TabularEditor.TabularEditor.2' -ExeName 'TabularEditor.exe' -DestName 'TabularEditor') { return }
            Write-Host "         winget layer did not yield an installer (fetch stalled/blocked); trying the portable zip." -ForegroundColor DarkGray
        } else {
            Write-Host "         winget layer skipped (winget not present); trying the portable zip." -ForegroundColor DarkGray
        }
        # Portable zip (~7 MB) from the official GitHub release, resolved live via
        # the GitHub API (api.github.com works even on TLS-inspection proxies).
        $u = Get-GitHubReleaseAssetUrl -Repo 'TabularEditor/TabularEditor' -NamePattern 'TabularEditor\.Portable\.zip$'
        if (Install-PortableZipTool -Url $u -DestName 'TabularEditor' -ExeName 'TabularEditor.exe') { return }
        # If the user already placed a portable zip in Downloads/Desktop, pick it up.
        # NOTE: the local-pickup pattern is deliberately looser than the strict GitHub
        # asset pattern above -- a browser re-downloading an existing file saves it as
        # 'TabularEditor.Portable (1).zip', so we allow any suffix before '.zip'.
        if (Install-FromLocalZip -NamePattern 'TabularEditor\.Portable.*\.zip$' -DestName 'TabularEditor' -ExeName 'TabularEditor.exe') { return }
        # Locked-down machines: TLS-inspection proxies serve an EMPTY (0-byte) file from
        # the GitHub release CDN, so in-browser auto-download cannot be trusted. We do NOT
        # attempt it -- instead we give the exact portable link for a clean manual install.
        Write-Host "         Automated download blocked here. Finish Tabular Editor 2 manually (free, portable, no admin):" -ForegroundColor Yellow
        Write-Host "           1. Open  https://github.com/TabularEditor/TabularEditor/releases/latest" -ForegroundColor Yellow
        Write-Host "           2. Download 'TabularEditor.Portable.zip', unzip to  $env:LOCALAPPDATA\Programs\TabularEditor" -ForegroundColor Yellow
        Write-Host "         Note: corporate security may return the zip EMPTY or block it; an IT/download approval can be required." -ForegroundColor Yellow
        Write-Host "         Tip: drop the zip in Downloads and re-run to auto-pick it up, or ask '070 - Capability Maintenance Team Lead' in VS Code." -ForegroundColor DarkGray
    }

# Detect-only siblings of TE2 so agents can tell the three products apart.
# `te` = cross-platform Tabular Editor CLI (preview; separate binary, separate release
# train); TE3 = paid desktop product. Neither is installed or updated by this installer.
$teHit = Resolve-ToolCommand -Aliases @('te') -SearchRoots @("$env:LOCALAPPDATA\Programs\te")
if ($teHit) {
    $teVer = Get-ToolVersion -Exe $(if ($teHit.path) { $teHit.path } else { $teHit.command })
    Write-Host "  Tabular Editor CLI (te): found" -ForegroundColor Green
    Set-ToolStatus -Key 'teCli' -Found $true -Command $teHit.command -Path $teHit.path -Version $teVer -InstallMode 'detect' -AliasesChecked @('te')
} else {
    Set-ToolStatus -Key 'teCli' -Found $false -Reason 'not installed (detect-only; see power-bi-agentic-development te-cli skill)' -InstallMode 'detect' -AliasesChecked @('te')
}
$te3Hit = Resolve-ToolCommand -Aliases @('TabularEditor3.exe') -SearchRoots @("$env:LOCALAPPDATA\Programs\Tabular Editor 3", "$env:ProgramFiles\Tabular Editor 3", "${env:ProgramFiles(x86)}\Tabular Editor 3")
if ($te3Hit) {
    Write-Host "  Tabular Editor 3: found" -ForegroundColor Green
    Set-ToolStatus -Key 'tabularEditor3' -Found $true -Command $te3Hit.command -Path $te3Hit.path -Version (Get-ExeFileVersion $te3Hit.path) -InstallMode 'detect' -AliasesChecked @('TabularEditor3.exe')
} else {
    Set-ToolStatus -Key 'tabularEditor3' -Found $false -Reason 'not installed (paid product; detect-only)' -InstallMode 'detect' -AliasesChecked @('TabularEditor3.exe')
}

# pbir CLI -- Power BI report (PBIR) editing (Agent 7). Installed into a short
# user-profile venv (%USERPROFILE%\.fabric-pbir) to dodge the MAX_PATH overflow
# the deep pbir wheel hits under the long Store-Python user-site prefix.
Invoke-OptionalToolPrompt -Key 'pbir' -Name 'pbir CLI' `
    -Purpose 'Explore, edit, format, validate and publish PBIR reports.' `
    -Provider 'data-goblin / Kurt Buhler -- https://github.com/data-goblin/power-bi-agentic-development (non-commercial license)' `
    -Aliases @('pbir','pbir-cli') -SearchRoots @("$env:USERPROFILE\.fabric-pbir\Scripts") `
    -Prior $priorToolStatus -Install {
        $py = Find-RealPython
        if (-not $py) { return }
        $venv = Join-Path $env:USERPROFILE '.fabric-pbir'
        $vpy  = Join-Path $venv 'Scripts\python.exe'
        if (-not (Test-Path $vpy)) { & $py -m venv $venv 2>$null | Out-Null }
        if (Test-Path $vpy) {
            & $vpy -m pip install --upgrade --disable-pip-version-check pbir-cli 2>$null | Out-Null
            Add-DirToPath (Join-Path $venv 'Scripts')
        }
    }

# pbi-tools -- PBIP DevOps workflows (ALM & DevOps). Portable net472 Desktop build
# (runs on stock Win11; the .core/.net9 builds need an absent .NET runtime).
# pbi-tools is not a winget package, so its only proxy-penetrating transport is
# the Delivery-Optimization fallback baked into Get-FileBestEffort (tried after
# curl/IWR); on unrestricted networks the direct GitHub download just works.
Invoke-OptionalToolPrompt -Key 'pbiTools' -Name 'pbi-tools' `
    -Purpose 'PBIP/PBIX extract-compile DevOps workflows.' `
    -Provider 'https://pbi.tools' `
    -Aliases @('pbi-tools','pbi-tools.core') -SearchRoots @("$env:LOCALAPPDATA\Programs\pbi-tools") `
    -Prior $priorToolStatus -Install {
        $u = Get-GitHubReleaseAssetUrl -Repo 'pbi-tools/pbi-tools' -NamePattern '^pbi-tools\.\d+\.\d+\.\d+\.zip$'
        if (Install-PortableZipTool -Url $u -DestName 'pbi-tools' -ExeName 'pbi-tools.exe') { return }
        # If the user already placed a portable zip in Downloads/Desktop, pick it up.
        # NOTE: looser than the strict GitHub asset pattern above so a browser duplicate
        # like 'pbi-tools.1.2.0 (1).zip' is still picked up (any suffix before '.zip').
        if (Install-FromLocalZip -NamePattern '^pbi-tools\.\d+\.\d+\.\d+.*\.zip$' -DestName 'pbi-tools' -ExeName 'pbi-tools.exe') { return }
        # Locked-down machines: TLS-inspection proxies serve an EMPTY (0-byte) file from
        # the GitHub release CDN, so in-browser auto-download cannot be trusted. We do NOT
        # attempt it -- instead we give the exact portable link for a clean manual install.
        Write-Host "         Automated download blocked here. Finish pbi-tools manually (portable, no admin):" -ForegroundColor Yellow
        Write-Host "           1. Open  https://github.com/pbi-tools/pbi-tools/releases/latest" -ForegroundColor Yellow
        Write-Host "           2. Download 'pbi-tools.<version>.zip' (net472 build), unzip to  $env:LOCALAPPDATA\Programs\pbi-tools" -ForegroundColor Yellow
        Write-Host "         Note: corporate security may return the zip EMPTY or block it; an IT/download approval can be required." -ForegroundColor Yellow
        Write-Host "         Tip: drop the zip in Downloads and re-run to auto-pick it up, or ask '070 - Capability Maintenance Team Lead' in VS Code." -ForegroundColor DarkGray
    }

# gh -- GitHub PRs / Actions / releases. Prefer GitHub's authoritative current
# portable release. The no-admin winget download/extraction path remains the
# corporate proxy / locked-down fallback, but is not allowed to make a fresh
# normal install start one catalog version behind.
Invoke-OptionalToolPrompt -Key 'gh' -Name 'GitHub CLI (gh)' `
    -Purpose 'GitHub PRs, Actions, releases and tags from the CLI.' `
    -Provider 'https://cli.github.com' `
    -Aliases @('gh') -SearchRoots @("$env:LOCALAPPDATA\Programs\gh") `
    -Prior $priorToolStatus -Install {
        $arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'amd64' }
        $u = Get-GitHubReleaseAssetUrl -Repo 'cli/cli' -NamePattern "gh_.*_windows_$arch\.zip$"
        $portableOk = $false
        if ($u) { $portableOk = Install-PortableZipTool -Url $u -DestName 'gh' -ExeName 'gh.exe' }
        if (-not $portableOk) {
            Install-ViaWingetDownload -WingetId 'GitHub.cli' -ExeName 'gh.exe' -DestName 'gh' | Out-Null
        }
    }

# Azure DevOps CLI extension -- bespoke detection (an `az` extension, not a binary).
$azPresent = [bool]$azHit
$adoFound = $false
if ($azPresent) {
    try { if ((& az extension list --query "[].name" -o tsv 2>$null) -match 'azure-devops') { $adoFound = $true } } catch { }
}
if ($adoFound) {
    Write-Host "  Azure DevOps CLI extension: found" -ForegroundColor Green
    Set-ToolStatus -Key 'azureDevOpsCliExtension' -Found $true -Command 'az devops' -Category 'az-extension' -InstallMode 'ask'
} elseif (-not $azPresent) {
    Write-Host "  Azure DevOps CLI extension: skipped (needs az, which is not installed)" -ForegroundColor Yellow
    Set-ToolStatus -Key 'azureDevOpsCliExtension' -Found $false -Command 'az devops' -Category 'az-extension' -InstallMode 'ask' -Reason 'az CLI not installed'
} else {
    Write-Host "  Azure DevOps CLI extension: not found (optional)" -ForegroundColor Yellow
    Write-Host "         Purpose:  Azure DevOps PRs, pipelines and boards from the CLI." -ForegroundColor DarkGray
    Write-Host "         Provider: az extension (azure-devops)" -ForegroundColor DarkGray
    $adoAns = Read-Host "         Install the azure-devops az extension now? (Y/N)"
    if ($adoAns -match '^(y|yes)$') {
        try { & az extension add --name azure-devops 2>$null | Out-Null } catch { }
        $adoFound2 = $false
        try { if ((& az extension list --query "[].name" -o tsv 2>$null) -match 'azure-devops') { $adoFound2 = $true } } catch { }
        if ($adoFound2) {
            Write-Host "  Azure DevOps CLI extension: installed" -ForegroundColor Green
            Set-ToolStatus -Key 'azureDevOpsCliExtension' -Found $true -Command 'az devops' -Category 'az-extension' -InstallMode 'ask'
        } else {
            Write-Host "  Azure DevOps CLI extension: install did not complete." -ForegroundColor Yellow
            Write-Host "         Or finish it later in VS Code: select '070 - Capability Maintenance" -ForegroundColor DarkGray
            Write-Host "         Team Lead', name Azure DevOps CLI, and approve its recovery plan." -ForegroundColor DarkGray
            Set-ToolStatus -Key 'azureDevOpsCliExtension' -Found $false -Command 'az devops' -Category 'az-extension' -InstallMode 'ask' -Reason 'install attempted; not detected'
        }
    } else {
        Write-Host "         Skipped." -ForegroundColor DarkGray
        Set-ToolStatus -Key 'azureDevOpsCliExtension' -Found $false -Command 'az devops' -Category 'az-extension' -InstallMode 'ask' -Reason 'not found; user declined'
    }
}

Write-Host "  Tool inventory built (written to .github/agent-docs/tool-status.json in a later step)." -ForegroundColor DarkGray

# -- Optional: check already-installed tools for newer versions ----------
# One quick gate (default No) so normal runs stay fast; on Yes we look up the
# latest version of each installed tool and offer a per-tool Y/N upgrade. Every
# lookup is best-effort -- blocked/offline lookups are silently skipped.
Write-Host ""
$updAns = Read-Host "  Check installed tools for updates now? (y/N)"
if ($updAns -match '^(y|yes)$') {
    try { Invoke-ToolUpdateCheck } catch { }
} else {
    Write-Host "  Update check skipped." -ForegroundColor DarkGray
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
}

# =====================================================================
# STEP 3  -- Create folder structure
# =====================================================================
Show-Step 3 $totalSteps "Creating Folder Structure"

$dirs = @(
    "$rootPath\.github\agents"
    "$rootPath\.github\agent-docs"
    "$rootPath\.github\skills\fabric-tmdl"
    "$rootPath\.github\skills\fabric-pipelines"
    "$rootPath\.github\skills\fabric-cli-policy"
    "$rootPath\.vscode"
)
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Host "  Created: $($d.Replace($rootPath, '.'))"
    }
}

# Create workspace placeholder folders
if ($workspaceNames.Count -gt 0) {
    Write-Host ""
    foreach ($name in $workspaceNames) {
        $wsPath = Join-Path $rootPath $name
        if (-not (Test-Path $wsPath)) {
            New-Item -ItemType Directory -Path $wsPath -Force | Out-Null
            Write-Host "  Created workspace: $name" -ForegroundColor Green
        } else {
            Write-Host "  Workspace exists:  $name" -ForegroundColor Yellow
        }
    }
}

Write-Host "`n  Folder structure ready." -ForegroundColor Green

# =====================================================================
# STEP 4  -- Onboard independent business source-control repositories
# =====================================================================
Show-Step 4 $totalSteps "Business Source-Control Repositories"

if (-not $EmitAgentsTo) {
$repositoryMapPath = Join-Path $rootPath '.github\agent-docs\local\repository-map.local.json'
$businessRepositoriesRoot = Join-Path $rootPath 'source-control-repositories'
$workspaceFilePath = Join-Path $rootPath $workspaceFileName
# The multi-root workspace is opened UNSAVED so the generated folder stays clean:
# it is written to a session file in TEMP (with an absolute primary root) and the
# user decides where -- if anywhere -- to Save Workspace As. The file is keyed to
# THIS root path so re-runs merge into the right file and two workspaces installed
# on the same machine never inherit each other's roots.
$rootKey = ([BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($rootPath)).ToLowerInvariant()))) -replace '-', '').Substring(0, 8)
$sessionWorkspaceFilePath = Join-Path ([IO.Path]::GetTempPath()) ("$(Split-Path $rootPath -Leaf)-$rootKey.code-workspace")
# Earlier builds used one shared TEMP file name for every workspace; drop it so it
# cannot be launched by mistake.
$legacySessionWorkspace = Join-Path ([IO.Path]::GetTempPath()) $workspaceFileName
if (Test-Path -LiteralPath $legacySessionWorkspace) { Remove-Item -LiteralPath $legacySessionWorkspace -Force -ErrorAction SilentlyContinue }
$allBusinessRepositories = @()
$existingRepositoryMap = $null
$repositoryMapReadable = $true

if (Test-Path -LiteralPath $repositoryMapPath) {
    try {
        $existingRepositoryMap = Get-Content -LiteralPath $repositoryMapPath -Raw | ConvertFrom-Json
        $allBusinessRepositories = @($existingRepositoryMap.repositories)
        Write-Host "  Existing local repository map: $($allBusinessRepositories.Count) entr$(if ($allBusinessRepositories.Count -eq 1) {'y'} else {'ies'})." -ForegroundColor DarkGray
    } catch {
        $repositoryMapReadable = $false
        Write-Host '  Existing repository-map.local.json is malformed.' -ForegroundColor Yellow
        Write-Host '  It will be preserved exactly; new repository onboarding is skipped to avoid data loss.' -ForegroundColor Yellow
    }
}

if ($businessRepoPlans.Count -gt 0 -and $repositoryMapReadable) {
    # Protect nested repositories and company-specific mappings immediately, even
    # if a later optional network operation fails before the configuration step.
    Add-GitIgnoreRules -Path (Join-Path $rootPath '.gitignore') `
        -Heading 'Independent business repositories and machine-specific mappings' `
        -Rules @('source-control-repositories/', '.github/agent-docs/local/', $workspaceFileName)
    if (-not (Test-Path -LiteralPath $businessRepositoriesRoot)) {
        New-Item -ItemType Directory -Path $businessRepositoriesRoot -Force | Out-Null
    }

    $newRepositoryEntries = @()
    foreach ($plan in $businessRepoPlans) {
        Write-Host "`n  Onboarding: $($plan.displayName)" -ForegroundColor Cyan
        $container = [IO.Path]::GetFullPath((Join-Path $rootPath $plan.localPath))
        $safeRoot = [IO.Path]::GetFullPath($businessRepositoriesRoot).TrimEnd('\') + '\'
        if (-not $container.StartsWith($safeRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host '    Unsafe destination rejected; repository was not cloned.' -ForegroundColor Yellow
            continue
        }
        # A hidden bare mirror holds all refs; each live branch becomes its own
        # sibling worktree folder. VS Code scans for '.git', so '.bare' stays
        # invisible while every branch folder shows as its own Source Control repo.
        $gitDir = Join-Path $container '.bare'

        $repositoryReady = $false
        $createdNow = $false
        $doPull = $false
        if (Test-Path -LiteralPath $container) {
            if (Test-Path -LiteralPath $gitDir) {
                $originUrl = (& git --git-dir $gitDir config --get remote.origin.url 2>$null | Select-Object -First 1)
                if (-not $originUrl -or (Get-NormalizedRepositoryUrl $originUrl) -ne (Get-NormalizedRepositoryUrl $plan.cloneUrl)) {
                    Write-Host '    Existing destination is a different Git repository; preserved and skipped.' -ForegroundColor Yellow
                    continue
                }
                Write-Host '    Existing matching mirror found; preserving its worktrees.' -ForegroundColor Green
                $repositoryReady = $true
                # Cloned once already: offer an OPT-IN update. Default is No so a
                # re-run never silently moves the user's working branches. When
                # accepted, only clean worktrees strictly behind upstream are
                # fast-forwarded (never merged/rebased/reset) further below.
                $pullAns = Read-Host '    You already have this repository locally. Pull existing branches so they match online? (y/N)'
                if ($pullAns -match '^\s*(y|yes)\s*$') { $doPull = $true }
            } else {
                $children = @(Get-ChildItem -LiteralPath $container -Force -ErrorAction SilentlyContinue)
                if ($children.Count -gt 0) {
                    Write-Host '    Destination is a non-empty, unrelated folder; preserved and skipped.' -ForegroundColor Yellow
                    continue
                }
            }
        }

        if (-not $repositoryReady) {
            Write-Host '    Cloning once using your established Git credential mechanism...' -ForegroundColor White
            New-Item -ItemType Directory -Path $container -Force | Out-Null
            $ErrorActionPreference = 'Continue'
            try { & git clone --bare -- $plan.cloneUrl $gitDir 2>&1 | Out-Null } catch { }
            $cloneExit = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            if ($cloneExit -ne 0 -or -not (Test-Path -LiteralPath $gitDir)) {
                Write-Host '    Clone did not complete. Check URL access, Git Credential Manager/gh/Entra/SSH, and policy.' -ForegroundColor Yellow
                Write-Host '    No credential was recorded by the installer; continuing with other repositories.' -ForegroundColor DarkGray
                continue
            }
            # Teach the bare mirror to track remote branches under origin/* so the
            # local worktrees behave like a normal clone for fetch/pull/push.
            $ErrorActionPreference = 'Continue'
            try { & git --git-dir $gitDir config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' 2>&1 | Out-Null } catch { }
            $ErrorActionPreference = 'Stop'
            $repositoryReady = $true
            $createdNow = $true
            Write-Host '    Repository cloned.' -ForegroundColor Green
        }

        # Fetch remote references only. This does not pull, merge, reset, or touch
        # existing working-tree files and is safe for a matching existing mirror.
        $ErrorActionPreference = 'Continue'
        try { & git --git-dir $gitDir fetch --prune origin 2>&1 | Out-Null } catch { }
        $ErrorActionPreference = 'Stop'

        # Mirror every live branch except main/master (those are usually the
        # protected promotion targets and rarely edited locally).
        $remoteBranches = @(& git --git-dir $gitDir for-each-ref --format='%(refname:short)' refs/remotes/origin 2>$null |
            ForEach-Object { ($_ -replace '^origin/', '').Trim() } |
            Where-Object { $_ -and $_ -ne 'HEAD' -and $_ -notmatch '^(main|master)$' } |
            Sort-Object -Unique)

        $mirroredBranches = @()
        foreach ($branch in $remoteBranches) {
            $worktreePath = Join-Path $container $branch
            if (Test-Path -LiteralPath $worktreePath) {
                $mirroredBranches += $branch
                if ($doPull) {
                    # Fast-forward this existing worktree to origin/<branch> ONLY
                    # when it is clean and strictly behind. Dirty or diverged
                    # branches are left untouched so no local work is ever lost.
                    $ErrorActionPreference = 'Continue'
                    $dirtyWt = @(& git -C $worktreePath status --porcelain 2>$null)
                    if ($dirtyWt.Count -gt 0) {
                        Write-Host "    $branch has local changes  -- left as-is (no pull)." -ForegroundColor Yellow
                    } else {
                        $ahead = 0; $behind = 0
                        $counts = (& git -C $worktreePath rev-list --left-right --count "HEAD...origin/$branch" 2>$null)
                        if ($counts -and ($counts -match '(\d+)\s+(\d+)')) { $ahead = [int]$Matches[1]; $behind = [int]$Matches[2] }
                        if ($behind -eq 0) {
                            Write-Host "    $branch already up to date." -ForegroundColor DarkGray
                        } elseif ($ahead -gt 0) {
                            Write-Host "    $branch has diverged (local commits)  -- left as-is; pull manually." -ForegroundColor Yellow
                        } else {
                            & git -C $worktreePath merge --ff-only "origin/$branch" 2>&1 | Out-Null
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host "    $branch fast-forwarded to match online." -ForegroundColor Green
                            } else {
                                Write-Host "    $branch could not fast-forward  -- left as-is." -ForegroundColor Yellow
                            }
                        }
                    }
                    $ErrorActionPreference = 'Stop'
                }
                continue
            }
            # Create/point a local branch at origin/<branch> with upstream tracking
            # and check it out in its own worktree, so pull/push behave like a clone.
            $ErrorActionPreference = 'Continue'
            try { & git --git-dir $gitDir worktree add --track -B $branch -- $worktreePath "origin/$branch" 2>&1 | Out-Null } catch { }
            $addExit = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            if ($addExit -eq 0) {
                $mirroredBranches += $branch
                Write-Host "    Branch worktree ready: $branch" -ForegroundColor Green
            } else {
                Write-Host "    Could not create a worktree for '$branch'; skipped." -ForegroundColor Yellow
            }
        }

        if ($mirroredBranches.Count -eq 0) {
            Write-Host '    No non-main/master branches were found to mirror.' -ForegroundColor Yellow
        } else {
            Write-Host "    Live branches mirrored: $($mirroredBranches -join ', ')" -ForegroundColor Green
        }

        $entry = [pscustomobject][ordered]@{
            id               = $plan.id
            displayName      = $plan.displayName
            provider         = $plan.provider
            remoteUrl        = $plan.cloneUrl
            localPath        = $plan.localPath
            mirroredBranches = @($mirroredBranches)
            cloneStatus      = if ($createdNow) { 'cloned' } else { 'reused-existing' }
        }
        $newRepositoryEntries += $entry
    }

    if ($newRepositoryEntries.Count -gt 0) {
        foreach ($entry in $newRepositoryEntries) {
            $allBusinessRepositories = @($allBusinessRepositories | Where-Object {
                ([string]$_.id -ne [string]$entry.id) -and
                (([string]$_.localPath).Replace('\', '/') -ne ([string]$entry.localPath).Replace('\', '/'))
            })
            $allBusinessRepositories += $entry
        }
        $repositoryMap = [ordered]@{
            schemaVersion = 1
            generatedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            generatedBy   = 'installer'
            note          = 'Machine/company-specific and gitignored. Contains no credentials. Business repositories remain independent of the outer workspace repository.'
            repositories  = @($allBusinessRepositories)
        }
        Write-ManagedFile -Path $repositoryMapPath -Content ($repositoryMap | ConvertTo-Json -Depth 20)
        Write-Host "`n  Repository map written locally for $($allBusinessRepositories.Count) independent repositor$(if ($allBusinessRepositories.Count -eq 1) {'y'} else {'ies'})." -ForegroundColor Green
    } else {
        Write-Host "`n  No new repository completed onboarding; any existing map was preserved." -ForegroundColor Yellow
    }
} elseif ($businessRepoPlans.Count -eq 0) {
    Write-Host '  Skipped. Existing business repositories and mappings were not changed.' -ForegroundColor DarkGray
}

# Always (re)build the multi-root workspace, but as an UNSAVED session file kept
# OUTSIDE the generated folder so nothing is committed there. Existing user-added
# roots/settings in a prior session file are preserved by the merge (it is NOT
# deleted first); only missing managed roots/settings are added. Any stale copy
# previously written into the folder is removed so the generated workspace stays clean.
if ($repositoryMapReadable) {
    if (Test-Path -LiteralPath $workspaceFilePath) {
        Remove-Item -LiteralPath $workspaceFilePath -Force -ErrorAction SilentlyContinue
    }
    Merge-CodeWorkspace -Path $sessionWorkspaceFilePath -WorkspaceName (Split-Path $rootPath -Leaf) -PrimaryRootPath $rootPath
    Write-Host "  Workspace ready (opens unsaved -- use File > Save Workspace As to keep it)." -ForegroundColor Green
}

Read-Host "`n  Press Enter to continue..."
}

# =====================================================================
# STEP 5  -- Clone skill repositories
# =====================================================================
Show-Step 5 $totalSteps "Cloning Skill Repositories"

if (-not $EmitAgentsTo) {
# NOTE: We deliberately do NOT clone microsoft/fabric-cli (https://github.com/microsoft/fabric-cli).
# The data-goblin plugin (power-bi-agentic-development/plugins/fabric-cli/) already provides
# rich `fab` references and scripts, and the `fab` tool itself is installed via pip
# (ms-fabric-cli) in Step 2. Cloning the CLI source repo would add no agent-usable skills.

Push-Location $rootPath
try {
    # -- microsoft/skills-for-fabric ----------------------------------
    if (-not (Test-Path "$rootPath\skills-for-fabric")) {
        Write-Host "  Cloning microsoft/skills-for-fabric..." -ForegroundColor White
        try {
            & git clone https://github.com/microsoft/skills-for-fabric.git skills-for-fabric 2>$null | Out-Null
        } catch { }
        if (Test-Path "$rootPath\skills-for-fabric\skills") {
            Write-Host "  skills-for-fabric cloned." -ForegroundColor Green
        } else {
            Write-Host "  Warning: could not clone skills-for-fabric. Clone manually later." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  skills-for-fabric/ already exists  -- force-refreshing to upstream..." -ForegroundColor Green
        Update-VendorClone "$rootPath\skills-for-fabric" 'skills-for-fabric' -ExpectedRemote 'https://github.com/microsoft/skills-for-fabric.git'
    }
    # Touch files so LastWriteTime reflects sync time, not upstream commit time.
    # A freshly-cloned file may still be locked by antivirus/indexer; this touch is
    # purely cosmetic (freshness display), so ignore any transient per-file lock.
    if (Test-Path "$rootPath\skills-for-fabric\skills") {
        Get-ChildItem "$rootPath\skills-for-fabric\skills" -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_.LastWriteTime = Get-Date } catch { } }
    }

    # -- data-goblin/power-bi-agentic-development ---------------------
    if (-not (Test-Path "$rootPath\power-bi-agentic-development")) {
        Write-Host "  Cloning data-goblin/power-bi-agentic-development..." -ForegroundColor White
        try {
            & git clone https://github.com/data-goblin/power-bi-agentic-development.git power-bi-agentic-development 2>$null | Out-Null
        } catch { }
        if (Test-Path "$rootPath\power-bi-agentic-development\plugins") {
            Write-Host "  power-bi-agentic-development cloned." -ForegroundColor Green
        } else {
            Write-Host "  Warning: could not clone power-bi-agentic-development. Clone manually later." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  power-bi-agentic-development/ already exists  -- force-refreshing to upstream..." -ForegroundColor Green
        Update-VendorClone "$rootPath\power-bi-agentic-development" 'power-bi-agentic-development' -ExpectedRemote 'https://github.com/data-goblin/power-bi-agentic-development.git'
    }
    # Touch files so LastWriteTime reflects sync time, not upstream commit time.
    # A freshly-cloned file may still be locked by antivirus/indexer; this touch is
    # purely cosmetic (freshness display), so ignore any transient per-file lock.
    if (Test-Path "$rootPath\power-bi-agentic-development\plugins") {
        Get-ChildItem "$rootPath\power-bi-agentic-development\plugins" -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_.LastWriteTime = Get-Date } catch { } }
    }
} finally {
    Pop-Location
}

Read-Host "`n  Press Enter to continue..."
}

# =====================================================================
# STEP 6  -- Embed custom skills
# =====================================================================
Show-Step 6 $totalSteps "Writing Custom Skills"

# ----- fabric-tmdl/SKILL.md ------------------------------------------
$tmdlSkillPath = "$rootPath\.github\skills\fabric-tmdl\SKILL.md"
Write-Host "  Writing fabric-tmdl skill..."
$tmdlContent = @'
---
name: fabric-tmdl
description: "Use when: editing or creating TMDL files, DAX measures, columns, relationships, partitions, or parameters in Microsoft Fabric Semantic Models, Power BI datasets, or Direct Lake models. Covers TMDL syntax, indentation, lineageTag rules, and Tabular Object Model (TOM) structure."
---

# Fabric TMDL Skill

## Provenance and maintenance

- **Authored from**: real production Power BI / Fabric semantic models (the author's
  own reports). This is a HOUSE-STYLE skill - conventions, property ordering, and
  layout - not a TMDL/DAX language reference.
- **Independent of data-goblin**: this content was written from first-hand production
  work, NOT copied or AI-rewritten from `power-bi-agentic-development` (GPL-3.0).
  For TMDL/DAX language depth and validation, the semantic-model agent reads the
  cloned data-goblin skills separately; this skill layers house style on top.
- **Updating**: edit the PS1 installer (source of truth) and re-run it, or edit this
  file directly. Capability Maintenance does NOT auto-modify it (it is house style,
  not an external API surface).
- **Freshness**: the date shown in the startup table is this file's real on-disk
  modification time (when this workspace last installed/updated it).

---

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
        database.tmdl          <- compatibilityLevel only (preserve the existing value)
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
Nothing else in this file. **Preserve the existing level** - never lower it, and
never bump it "to be safe". `1604` is the Direct Lake baseline (XMLA tools need
1604+ for Direct Lake metadata); newer engine features need higher levels (for
example DAX user-defined functions need 1702+). Change it only when a feature you
are adding requires it, and say so in your result.

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

## Direct Lake: re-pointing a table to a different source -- `sourceLineageTag` MUST follow `entityName`

A Direct Lake model table has **two independent identities**:

1. **Model/display name** -- e.g. `'Table One'`. What DAX, relationships, and report
   visuals reference. Pure label; safe to rename without touching the source.
2. **Source binding** -- the partition's `source.entityName`, e.g. `TABLE_ONE`. The
   physical Lakehouse/Warehouse object the table actually reads.

There is also a **lineage anchor** at table level: `sourceLineageTag: [dbo].[Table One]`.
This is what the web **"Edit tables" / "Manage tables"** dialog uses to reconcile
"is this physical object already in my model?" -- it matches by lineage, **NOT** by the
model name and **NOT** by `entityName`.

### The trap

You have `Table One` in the Lakehouse and `'Table One'` in the model. You then re-point
the model table to a NEW physical object `TABLE_ONE` (rename in LH, or swap to a new
table/view) by editing only the partition:

```tmdl
	partition 'Table One' = entity
		mode: directLake
		source
			entityName: TABLE_ONE        <- changed
			schemaName: dbo
			expressionSource: DatabaseQuery
```

...but you leave the table header stale:

```tmdl
table 'Table One'
	sourceLineageTag: [dbo].[Table One]   <- STILL the OLD physical name -> MISMATCH
```

Now `entityName` (`TABLE_ONE`) and `sourceLineageTag` (`[dbo].[Table One]`) disagree.
The model still queries fine, **but the Edit tables dialog breaks**: it reconciles your
table to the old `[dbo].[Table One]` anchor and lists the real `TABLE_ONE` as a
separate, **unchecked "not added"** entry -- a phantom duplicate. If you then
**uncheck your real table** there you **DELETE it** (its curated/renamed columns AND
every relationship that points at it); **checking the phantom `TABLE_ONE`** adds a bare
table with raw source column names -> every measure/relationship referencing
`'Table One'` (or its friendly column names) **breaks**.

### The fix -- change BOTH, not just the connection source

When you rebind a Direct Lake table to a different physical object, update **all** of:

1. Partition `source.entityName` (and `schemaName`) -> the new physical object.
2. Table-level `sourceLineageTag` -> `[<schema>].[<NEW_PHYSICAL_NAME>]`.
3. Any renamed columns' `sourceColumn` + `sourceLineageTag` -> the new physical
   column names (the friendly `column 'Name'` stays as-is; only the source pointers move).

```tmdl
table 'Table One'
	sourceLineageTag: [dbo].[TABLE_ONE]   <- aligned to entityName
	...
	partition 'Table One' = entity
		mode: directLake
		source
			entityName: TABLE_ONE
			schemaName: dbo
			expressionSource: DatabaseQuery
```

After alignment the dialog recognises `TABLE_ONE` as already-checked and the phantom
duplicate disappears -- while the model keeps the friendly name `'Table One'`.

> **WARNING -- alignment can trigger a silent rename.** Once `sourceLineageTag`
> matches the physical name, the Edit tables dialog reconciles by that anchor and, on
> the next **apply/confirm**, will **rename the model table's display name to the raw
> physical name** (`'Table One'` -> `TABLE_ONE`). The curated columns survive, but every
> measure/relationship that references the **friendly** name now reports
> **`Missing_References`** (e.g. *"(Table One) SomeColumn ... Missing_References"*).
> This is a *rename*, not a delete -- diagnose it with
> `EVALUATE INFO.TABLES()` (look for raw names where friendly ones should be).
> **Fix:** rename the table back to the friendly name in TMDL or via XMLA
> (`table_operations Rename`, `currentName: TABLE_ONE` -> `newName: Table One`);
> `entityName` and `sourceLineageTag` stay on the physical object. After the rename all
> references resolve again. Then **stop using the Edit tables dialog** on these tables.

### Rules of thumb

- **Manage renamed/rebound Direct Lake tables via TMDL, not the Edit tables dialog.**
  That dialog is a blunt add/remove tool; with a friendly-named table whose source was
  swapped it will always offer the raw physical object as "new".
- If you must add a genuinely new LH table, add it via the dialog FIRST, then rename it
  in TMDL afterwards -- never uncheck an existing renamed one.
- `sourceLineageTag` is metadata only (lineage/refresh mapping); editing it does NOT
  change data or DAX, so re-aligning it is a safe, reversible fix.
- A leftover SQL view literally named `[dbo].[Table One]` can still appear unchecked in
  the dialog after alignment -- harmless; just don't tick it.

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

## House modelling decisions

These are the author's standing modelling choices - apply them unless the user
asks otherwise. They are DECISIONS, not syntax (for syntax/DAX depth, the agent
also reads the cloned data-goblin skills).

- **Storage mode**: prefer Direct Lake for fact tables sourced from the Lakehouse/
  Warehouse; use Import only for small calculated/parameter tables that cannot be
  Direct Lake (e.g. field-parameter and disconnected slicer tables).
- **Measure home**: keep measures in dedicated measure-only tables (`X - Measures -`),
  not on fact tables, so the field list stays clean.
- **Folder taxonomy**: organise tables with the numeric-prefix convention (`0.x -`
  system/dimension, `1.x -`..`4.x -` domain areas); group measures with `displayFolder`.
- **Naming**: dimensions `X.X - Dim_Name`, facts `X.X - Facts_Name`; single-quote any
  name containing spaces.
- **Formatting**: set an explicit `formatString` on every numeric measure; never rely
  on the implicit default.
- **Hygiene**: hide key/technical columns (`isHidden`) and surface only business-
  friendly fields; set `summarizeBy: none` on non-additive columns.

For HOW to design star schemas, RLS, calc groups, incremental refresh, time
intelligence, or to tune DAX, defer to the cloned data-goblin skills + Microsoft
docs - this skill intentionally does not duplicate that depth.

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
9. Never change a Direct Lake table's partition `entityName` without also updating its table-level `sourceLineageTag` (see "Direct Lake: re-pointing a table to a different source")

---

## What NOT to edit

| File | Reason |
|------|--------|
| `definition.pbism` | Connection metadata -- editing breaks deployment |
| `.platform` | Fabric platform metadata -- auto-managed |
| `database.tmdl` | Only `compatibilityLevel` - preserve it; raise only for a feature that needs it |
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
- [ ] **Rebound a Direct Lake source?** -> table `sourceLineageTag` aligned to the new `entityName` (`[schema].[PHYSICAL_NAME]`)
- [ ] **Annotations preserved**
- [ ] **changedProperty preserved**
- [ ] **File not in do-not-edit list**
'@
Write-ManagedFile $tmdlSkillPath $tmdlContent
# The on-disk LastWriteTime is left untouched on purpose: it honestly reflects
# when this workspace installed/updated the skill. The freshness display reads
# this real mtime for custom skills (and git commit dates for cloned repos).
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
  and Microsoft Learn docs for Data Factory in Fabric (both Microsoft, MIT-licensed)
- **Independent of data-goblin**: this skill is derived from Microsoft sources and
  Fabric docs only - NOT from `power-bi-agentic-development` (GPL-3.0). That repo is
  used solely as a locally cloned reference and is never copied into this skill.
- **Pipeline JSON schemas** are NOT published at `microsoft/json-schemas` (as of April 2026)
- **Last reviewed against Microsoft docs**: 2026-06-15 (against
  https://learn.microsoft.com/en-us/fabric/data-factory/activity-overview, updated 2026-06-07).
  Added `RefreshMaterializedLakeView` and `Approval` activities at that review.
- **In-house operational addendum**: 2026-06-17 - added "Operational practices
  (battle-tested)" section (RefreshSQLEndpoint placement, Direct Lake freshness,
  Variable Library endpoint/item-id discipline, Wait-buffer smell, pipeline auditing).
  Generalized from production work with all environment-specific identifiers removed;
  no proprietary data - redistributable.
- **To update this skill**: check `skills-for-fabric/common/ITEM-DEFINITIONS-CORE.md` for new
  activity types, and review https://learn.microsoft.com/en-us/fabric/data-factory/
  for updated typeProperties. Then re-run the installer or edit this file directly.
- **Note**: Microsoft's `skills-for-fabric/skills/pipeline-migration` covers migration
  (ADF/Synapse -> Fabric) and expression gotchas; this skill stays the authoring
  reference for `pipeline-content.json`. Read both when migrating.

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
- **Frequently mis-placed.** Only benefits a reader that reads *this* lakehouse over its
  SQL analytics endpoint - see "Operational practices -> RefreshSQLEndpoint: when it
  actually does something" below before adding or keeping one

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

### RefreshMaterializedLakeView (refresh a materialized lake view)
```json
{
  "name": "Refresh MLV",
  "type": "RefreshMaterializedLakeView",
  "dependsOn": [],
  "typeProperties": {
    "workspaceId": "<workspace-guid>",
    "lakehouseId": "<lakehouse-guid>"
  },
  "externalReferences": { "connection": "<connection-guid>" }
}
```
- Refreshes a materialized lake view in a Lakehouse so downstream queries see the latest data
- Typically placed after Copy/Notebook/LakehouseMaintenance steps, or run on a schedule
- Does NOT support SPN or workspace-identity auth (use a user-based connection)
- Exact `type` string and typeProperties are not published in a schema - if authoring
  by hand, confirm them via "View JSON" in the pipeline editor

### Approval (pause for human approve/reject)
```json
{
  "name": "Approve Load",
  "type": "Approval",
  "dependsOn": [],
  "typeProperties": {
    "approvalType": "Teams",
    "title": "Approve production load",
    "description": "Review row counts before publishing"
  },
  "externalReferences": { "connection": "<connection-guid>" }
}
```
- Pauses the pipeline and requests an approve/reject decision from designated reviewers
- `approvalType` is one of `Outlook365`, `Teams`, or a custom endpoint
- Approved -> success path; Rejected or timed out -> failure path (set Timeout on the activity)
- Exact `type` string and typeProperties are not published in a schema - if authoring
  by hand, confirm them via "View JSON" in the pipeline editor

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
- `@variables('VarName')` -- access a pipeline variable (NOT `pipeline().variables`; that accessor does not exist)
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

## Operational practices (battle-tested)

> In-house, field-tested guidance generalized from production Fabric pipelines.
> Contains no environment-specific identifiers (no workspace/lakehouse/model names
> or GUIDs) - safe to redistribute.

### RefreshSQLEndpoint: when it actually does something

`RefreshSQLEndpoint` forces a Lakehouse SQL analytics endpoint to sync its metadata
view to the latest Delta commit. It is easy to add in the wrong place. Before adding
or keeping one, confirm **who reads that endpoint**:

- A `RefreshSQLEndpoint` only benefits a downstream reader that reads **that same
  lakehouse over its SQL analytics endpoint** - e.g. a Dataflow / Script / Lookup, or a
  semantic model whose source is `Sql.Database(<server>, <thisLakehouseEndpointId>)`.
- Refreshing lakehouse **A**'s endpoint does **nothing** for a reader that reads
  lakehouse **B**. A refresh with no matching SQL-endpoint reader downstream is an
  **orphaned no-op** - safe to remove.
- A Spark **notebook** write does **not** trigger SQL-endpoint sync on its own. If a
  later activity reads that table over SQL, a `RefreshSQLEndpoint` between them makes
  the write visible deterministically.
- A **Dataflow Gen2** with a Lakehouse destination **can** sync the endpoint itself
  (the destination's update-metadata option), which can remove the need for a separate
  refresh step after it.

### Direct Lake freshness is not the same as refreshing an upstream lakehouse

A common mistake is to refresh an upstream / "gold" lakehouse endpoint expecting a
**Direct Lake** model to pick up new data. It will not, unless that lakehouse **is the
model's own** lakehouse.

- A Direct Lake model reads Delta from the **specific source(s)** its table partitions
  point at. Two variants exist and behave differently:
  - **Direct Lake on SQL** (`Sql.Database(<endpoint>, <endpointId>)` expression, one
    source): table/permission discovery goes through the SQL analytics endpoint, so
    endpoint metadata sync matters, and unsupported cases fall back to DirectQuery.
  - **Direct Lake on OneLake** (OneLake/`AzureStorage` style source, one or more Fabric
    items): reads Delta directly, never falls back to DirectQuery, and the SQL endpoint
    sync is irrelevant to it.
- New data becomes visible only after the model **reframes** to the newer Delta
  version. With **automatic updates enabled** (the default) this happens shortly after
  the write; with automatic updates **disabled** the model keeps serving the last
  framed version until something refreshes it (`PBISemanticModelRefresh`, REST
  refresh, or a manual refresh). Check the setting before promising "no refresh needed".
- For Direct Lake on SQL, the endpoint has a background metadata-sync that can briefly
  lag a write. For **deterministic** freshness run `RefreshSQLEndpoint` on the
  **model's own** source (not an upstream layer), then refresh/reframe the model, then
  read. For Direct Lake on OneLake the endpoint refresh is a no-op for the model.
- Refreshing a *different* lakehouse's endpoint (e.g. an intermediate layer the model
  does not read) has **zero** effect on the model.

**Verify before trusting a refresh:** map variable -> lakehouse item -> endpoint id,
then confirm a downstream activity actually reads that endpoint. The SQL **endpoint id
is not the lakehouse item id** - resolve both when auditing.

### Centralize environment-specific GUIDs in a Variable Library

Hold per-environment lakehouse / SQL-endpoint / item GUIDs in a Variable Library with
Test/Prod value sets and reference them via `@pipeline().libraryVariables.x`. This keeps
one pipeline definition working across environments.

- Mind the **endpoint id vs item id** distinction: store whichever the consumer needs.
  A `RefreshSQLEndpoint` needs the **lakehouse item id**; a Direct Lake model source
  needs the **SQL endpoint id**. Mixing them silently targets the wrong object.
- Pipelines parameterize cleanly, but the **notebooks / dataflows they call may hardcode
  absolute lakehouse GUIDs** (abfss paths, `default_lakehouse` metadata). Those do not
  rebind across Test/Prod automatically. When promoting, audit the **called ETL items**
  for embedded GUIDs, not just the pipeline.

### Prefer dependencies over fixed Wait buffers

Small fixed `Wait` activities inserted only to "space out" steps (e.g. between
`ExecutePipeline` calls) are brittle - they neither guarantee upstream completion nor
adapt to load. Order work with explicit `dependsOn` chains and `waitOnCompletion: true`
on `ExecutePipeline`. Reserve `Wait` for genuine external-latency situations.

### Auditing an existing pipeline (review-first)

When asked to optimize, trace before touching anything:
1. For each activity, note what it **reads** and **writes**, and the access path:
   SQL endpoint vs Spark/abfss vs `Lakehouse.Contents` (direct).
2. Resolve every variable to a **physical lakehouse item id + endpoint id**.
3. For each refresh / `RefreshSQLEndpoint`, confirm a downstream activity actually
   consumes that endpoint. No consumer -> candidate for removal.
4. Confirm whether Direct Lake models read the same lakehouse the ETL writes. If so,
   upstream endpoint refreshes are usually unnecessary for the model.

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
Write-Host "  Written: .github/skills/fabric-pipelines/SKILL.md" -ForegroundColor Green

# ----- fabric-cli-policy/SKILL.md ------------------------------------
$cliPolicySkillPath = "$rootPath\.github\skills\fabric-cli-policy\SKILL.md"
$cliPolicyContent = @'
---
name: fabric-cli-policy
description: "CLI decision policy for Fabric/Power BI work. Read this BEFORE any terminal CLI or REST API task. Triggers: fabric cli, fab, fab api, call Fabric API, run notebook, run job, export item, import item, deploy item, onelake copy, table load, az rest, sqlcmd, capacity, governance, workspace item CRUD."
---

# Fabric CLI Policy -- prefer `fab`, fall back to `az`

This workspace standardises on the **Fabric CLI (`fab`)** for control-plane and
data-plane Fabric work. `az` (Azure CLI) is retained as a documented **fallback**
for the few things `fab` does not cover. Neither CLI is required for the core
local-editing workflow -- they add terminal/API power on top.

## Decision rule

**Default to `fab`** for:
- Calling the Fabric REST API -> `fab api <endpoint>` (replaces `az rest --resource https://api.fabric.microsoft.com`)
- Running and monitoring jobs -> `fab job run`, `fab job run-sch`, `fab job run-status`
- Exporting / importing items -> `fab export`, `fab import`
- Table operations -> `fab table load`, `fab table optimize`, `fab table schema`
- OneLake file operations -> `fab cp`, `fab ls`, `fab rm` (and shortcuts)
- Workspace / item CRUD -> `fab create`, `fab get`, `fab set`, `fab rm`
- Identity -> `fab auth login`, `fab auth status`

**Fall back to `az` / `sqlcmd` ONLY** for:
- SQL / TDS data-plane queries -> `sqlcmd -G -S <endpoint> -d <db> -Q "<query>"`
- Tokens for **non-Fabric** audiences -> `az account get-access-token --resource <audience>`
  (e.g. Storage `https://storage.azure.com`, SQL `https://database.windows.net`)
- Any Fabric REST endpoint not yet surfaced by `fab api` (rare) -> `az rest` is acceptable

## `az rest` -> `fab api` translation

`fab api` handles auth automatically (no `--resource`, no token juggling) and
supports JMESPath result filtering with `-q`.

| Task | az (old) | fab (preferred) |
|------|----------|-----------------|
| List workspaces | `az rest --method get --resource https://api.fabric.microsoft.com --url https://api.fabric.microsoft.com/v1/workspaces` | `fab api workspaces` |
| Get one item | `az rest --method get --url .../v1/workspaces/<wsId>/items/<id>` | `fab api workspaces/<wsId>/items/<id>` |
| Filter output | `... -q "value[].displayName"` | `fab api workspaces -q "value[].displayName"` |
| Run a notebook job | n/a (raw REST) | `fab job run <workspace>/<notebook>.Notebook` |
| Check job status | raw REST polling | `fab job run-status <workspace>/<item> --id <jobId>` |

Notes:
- `fab api` is not a 1:1 mirror of every `az rest` call. If a specific endpoint
  is not covered by `fab api`, fall back to `az rest` for that single call.
- Use `fab auth status` to confirm identity; `fab auth login` to sign in.

## Where the deep `fab` references live (already cloned)

The data-goblin plugin ships rich `fab` references and scripts -- discover them
dynamically (paths evolve):
- `power-bi-agentic-development/plugins/fabric-cli/skills/fabric-cli/` -- references/ and scripts/
  - e.g. `fab-api.md`, `fab-vs-az-cli.md`, `import-download-deploy.md`, `semantic-models.md`
  - e.g. `export_semantic_model_as_pbip.py`

The Microsoft `skills-for-fabric/common/COMMON-CLI.md` is **az-based** and is the
documented fallback reference for SQL/TDS and non-Fabric token audiences.

## Data Engineering execution channel (notebooks, SQL, Spark)

Data-engineering execution (authoring + running notebooks, Spark, and SQL) is the
most tool-sensitive work in this workspace. **Choose the channel by task type FIRST,**
then degrade gracefully if a channel is unavailable. Never fail a task just because
one tool is blocked.

### Step 1 -- classify the task
- **Notebook / Spark job** (PySpark, Spark SQL, lakehouse transforms) -> the
  **remote Spark kernel is the PRIMARY tool**. SQL/TDS (port 1433) is irrelevant here.
- **Warehouse / SQL-endpoint query** (T-SQL, set-based SQL) -> **`sqlcmd -G` is
  PRIMARY when the endpoint is reachable**.

### Step 2 -- classify a failure before reacting
When a SQL/TDS call fails, decide which of these it is -- they need different fixes:
- **Tool missing** (`sqlcmd` not installed) -> route install to the Capability
  Maintenance team (070); do not self-install.
- **Auth failure** -> re-authenticate (`fab auth login` / `az login`); not a network fallback.
- **Port 1433 blocked** (egress/firewall refuses the TDS connection) -> use the
  fallback ladder below.

> **Port 1433 is NOT universally blocked.** On some locked-down corporate machines
> outbound TDS/1433 to the SQL analytics endpoint is blocked by egress policy, which
> makes `sqlcmd -G` time out. **This is machine-specific -- do NOT assume 1433 is
> always blocked.** On many environments it works fine. Only trigger the fallback
> ladder when you have actually observed a 1433/TDS connection failure on THIS machine.

### Step 3 -- fallback ladder when 1433 is blocked (or for any Spark task)
1. **Author** the notebook/item with `fab` (control-plane over HTTPS -- never touches 1433).
2. **Execute & iterate interactively** on the **Fabric Data Engineering extension
   remote Spark kernel** -- preferred for build -> run -> read -> amend -> rerun loops.
   Spark SQL can query the same lakehouse/tables without touching 1433. Note: Spark
   SQL is not T-SQL -- warehouse-only T-SQL (procs, MERGE, certain DDL) will not run
   on a Spark kernel. XMLA is NOT a T-SQL channel either (it reaches semantic models
   only). When TDS is blocked, run warehouse T-SQL via a Script/Lookup activity in a
   pipeline (`fab job run`) or the portal SQL query editor, or flag it as blocked.
3. **Headless / one-shot run:** trigger the notebook via the Fabric REST
   *run-on-demand* job API (`fab job run ...`), **poll job status**, and read results
   from the **portal run snapshot** or from a Lakehouse output table the notebook
   writes. The API returns job *status*, not cell results -- do not expect data back
   from the trigger call.

### The agent CANNOT set up the remote kernel autonomously
Installing the extension, completing Fabric sign-in (MFA), selecting the remote Spark
kernel, and attaching a Lakehouse are **interactive / approval steps a coding agent
cannot perform**. So:
- **Detect first** whether a remote Spark kernel is already available/attached.
- **If not ready**, either **ask the human to set it up** (give clear, step-by-step
  instructions) or route the install to 070 -- do not self-install or pretend it is ready.
- **Offer the human the trade-off explicitly:**
  - **Kernel (cooperative)** -- best for live, iterative development and eyeballing
    results; needs one-time human setup (sign-in, kernel pick, lakehouse attach).
  - **HTTP REST run-on-demand (autonomous)** -- needs no interactive setup and lets
    the agent iterate on its own, **but** returns job status only; results come from a
    portal snapshot or an output table, so the feedback loop is slower and coarser.
- Once the kernel is attached (or the HTTP path is chosen), the agent drives authoring,
  execution, iteration, and reconciliation itself.

## Guardrails
- Never hardcode tokens, secrets, or IDs -- parameterise (dev/test/prod).
- Confirm before destructive `fab rm` / delete operations.
- Prefer the smallest-scope call; filter with `-q` instead of dumping everything.

## Portal URLs vs REST identifiers (common trap)
- A portal link like `app.powerbi.com/groups/<workspaceGuid>/list?...&subfolderId=168060`
  carries the **workspace GUID** (usable as-is) but a **numeric portal folder id** that
  the REST API does not accept.
- Resolve it first: `fab api "workspaces/<workspaceGuid>/folders"` (or REST
  `GET /v1/workspaces/{ws}/folders`) and match by `displayName`; use the returned folder
  **GUID** in `folderId` when creating items. If more than one folder could match, stop
  and ask -- never guess a target folder for a live create.
- Likewise `datasetId`/`reportId` in portal URLs ARE GUIDs and can be used directly.
'@
Write-ManagedFile $cliPolicySkillPath $cliPolicyContent
Write-Host "  Written: .github/skills/fabric-cli-policy/SKILL.md" -ForegroundColor Green

Read-Host "`n  Press Enter to continue..."

# =====================================================================
# STEP 7  -- Generate agent definitions
# =====================================================================
Show-Step 7 $totalSteps "Writing Agent Definitions"

# ----- Master Agent reference docs (in agent-docs, NOT in dropdown) ---

# One deterministic script replaces the ~8 separate shell probes the Master used
# to run at session start. It also re-checks tool-status.json live so agents do
# not trust a stale install-time snapshot.
$sessionStatusScript = @'
# Get-SessionStatus.ps1 -- one-shot session health for the Fabric Workspace Master.
# Run from the workspace root:  powershell -NoProfile -ExecutionPolicy Bypass -File .github/agent-docs/Get-SessionStatus.ps1
# Prints a compact status block and refreshes .github/agent-docs/tool-status.json in place.
$ErrorActionPreference = 'SilentlyContinue'
# Workspace root = two levels above this script (.github/agent-docs/), so the CWD does not matter.
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not (Test-Path -LiteralPath (Join-Path $root '.github\agents'))) { $root = (Get-Location).Path }
$out = New-Object System.Collections.Generic.List[string]
$out.Add("GENERATED $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) (local) -- a block older than ~1 hour is stale: re-run the script in a NEW terminal")
$out.Add("ROOT     $root")

function Get-RepoDate([string]$rel) {
    $p = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $p)) { return 'not installed' }
    $d = & git -C $p log -1 --format=%cd --date=format-local:"%Y-%m-%d" 2>$null
    if ($d -and $d -notmatch 'fatal') { return [string]$d }
    $f = Get-ChildItem -LiteralPath $p -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return $f.LastWriteTime.ToString('yyyy-MM-dd') + ' (mtime)' }
    return 'unknown'
}
function Get-FileDate([string]$rel) {
    $p = Join-Path $root $rel
    if (Test-Path -LiteralPath $p) { return (Get-Item -LiteralPath $p).LastWriteTime.ToString('yyyy-MM-dd') }
    return 'not installed'
}
function Get-AgeDays([string]$stamp) {
    $m = [regex]::Match($stamp, '^\d{4}-\d{2}-\d{2}')
    if (-not $m.Success) { return -1 }
    return [int]((Get-Date) - [datetime]::ParseExact($m.Value, 'yyyy-MM-dd', $null)).TotalDays
}

# -- Skills freshness --
$ms   = Get-RepoDate 'skills-for-fabric'
$kurt = Get-RepoDate 'power-bi-agentic-development'
$tmdl = Get-FileDate '.github/skills/fabric-tmdl/SKILL.md'
$pipe = Get-FileDate '.github/skills/fabric-pipelines/SKILL.md'
$out.Add("SKILLS   Microsoft skills-for-fabric: $ms | Kurt power-bi-agentic-development: $kurt | custom tmdl: $tmdl | custom pipelines: $pipe")
$stale = @()
foreach ($pair in @(@('Microsoft', $ms), @('Kurt', $kurt))) { $age = Get-AgeDays $pair[1]; if ($age -gt 30) { $stale += "$($pair[0]) ($age d)" } }
if ($stale.Count -gt 0) { $out.Add("         Upstream older than 30 days: $($stale -join ', ') -> say 'run maintenance' to refresh.") }

# -- USER-level settings (reach every window, incl. multi-root/untitled workspaces) --
# Both keys are window-scoped; user level is the only scope that works however the
# folder was opened. Relative skill locations resolve against the open workspace folders.
function ConvertFrom-JsoncText([string]$t) {
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    try { return ($t | ConvertFrom-Json) } catch { }
    try { return (([regex]::Replace($t, '(?s)"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*.*?\*/', { param($m) if ($m.Value.StartsWith('"')) { $m.Value } else { '' } }) -replace ',(\s*[}\]])', '$1') | ConvertFrom-Json) } catch { return $null }
}
$userSettingsPath = if ($env:FABRIC_AGENTIC_USER_SETTINGS) { $env:FABRIC_AGENTIC_USER_SETTINGS } else { Join-Path $env:APPDATA 'Code\User\settings.json' }
$userFlag = $false; $userRelLocs = 0
if (Test-Path -LiteralPath $userSettingsPath) {
    $us = ConvertFrom-JsoncText (Get-Content -LiteralPath $userSettingsPath -Raw)
    if ($us) {
        $userFlag = ($us.'chat.subagents.allowInvocationsFromSubagents' -eq $true)
        $ul = $us.'chat.agentSkillsLocations'
        if ($ul) { $userRelLocs = @($ul.PSObject.Properties | Where-Object { $_.Value -eq $true -and -not [IO.Path]::IsPathRooted([string]$_.Name) -and ([string]$_.Name) -notmatch '^~[\\/]' -and (Test-Path -LiteralPath (Join-Path $root ([string]$_.Name))) }).Count }
    }
}

# -- Registered skill locations (self-heal: register new upstream containers) --
$settingsPath = Join-Path $root '.vscode/settings.json'
$nesting = 'unknown'
$skillLocCount = 0
$newlyRegistered = @()
$folderFlag = $false
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $s = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $loc = $s.'chat.agentSkillsLocations'
        if (-not $loc) { $loc = New-Object PSObject; $s | Add-Member -NotePropertyName 'chat.agentSkillsLocations' -NotePropertyValue $loc -Force }
        foreach ($sub in @('skills-for-fabric\skills', 'power-bi-agentic-development\plugins')) {
            $base = Join-Path $root $sub
            if (-not (Test-Path -LiteralPath $base)) { continue }
            Get-ChildItem -LiteralPath $base -Recurse -Filter 'SKILL.md' -File | ForEach-Object {
                $c = $_.Directory.Parent; if ($null -eq $c) { return }
                $rel = $c.FullName.Substring($root.TrimEnd('\').Length).TrimStart('\').Replace('\', '/')
                if ($rel -and -not $loc.PSObject.Properties[$rel]) { $loc | Add-Member -NotePropertyName $rel -NotePropertyValue $true; $newlyRegistered += $rel }
            }
        }
        if ($newlyRegistered.Count -gt 0) { [IO.File]::WriteAllText($settingsPath, ($s | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false))) }
        $skillLocCount = @($loc.PSObject.Properties | Where-Object { $_.Value -eq $true }).Count
        $folderFlag = ($s.'chat.subagents.allowInvocationsFromSubagents' -eq $true)
    } catch { }
}
$nesting = if ($userFlag) { 'enabled at user level (every VS Code window)' }
           elseif ($folderFlag) { 'enabled in .vscode/settings.json only (File > Open Folder windows; NOT windows opened from a .code-workspace file)' }
           else { 'NOT set -> Team Leads cannot dispatch workers; re-run the installer and answer Y to the user-settings prompt' }
$locSummary = "$skillLocCount in .vscode/settings.json" + $(if ($userRelLocs -gt 0) { " | $userRelLocs workspace-relative in user settings (every window)" } else { '' })
$out.Add("CONFIG   Skill locations registered: $locSummary | Nested dispatch: $nesting")
if ($newlyRegistered.Count -gt 0) { $out.Add("         Newly registered skill folders (reload window to load them): $(($newlyRegistered | Sort-Object -Unique) -join ', ')") }

# -- Saved .code-workspace files that open this root --
# The nesting setting is WINDOW-scoped: opened from a multi-root workspace file, the
# folder's settings.json is ignored and the setting must be in that file. Name the
# culprit so the Master never blames settings.json by mistake.
$storageRoot = if ($env:FABRIC_AGENTIC_WORKSPACE_STORAGE) { $env:FABRIC_AGENTIC_WORKSPACE_STORAGE } else { Join-Path $env:APPDATA 'Code\User\workspaceStorage' }
$wsMissing = @(); $wsOk = @()
if (Test-Path -LiteralPath $storageRoot) {
    $rootNorm = $root.TrimEnd('\').ToLowerInvariant()
    $seenWs = @{}
    Get-ChildItem -LiteralPath $storageRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $wj = Join-Path $_.FullName 'workspace.json'
        if (-not (Test-Path -LiteralPath $wj)) { return }
        try { $w = Get-Content -LiteralPath $wj -Raw | ConvertFrom-Json } catch { return }
        if (-not $w.workspace) { return }
        $uri = [string]$w.workspace
        if ($uri -notmatch '^file:///') { return }
        $file = [Uri]::UnescapeDataString($uri.Substring(8)).Replace('/', '\')
        if ($seenWs.ContainsKey($file.ToLowerInvariant()) -or -not (Test-Path -LiteralPath $file)) { return }
        $seenWs[$file.ToLowerInvariant()] = $true
        $rawWs = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
        $wsj = $null
        try { $wsj = $rawWs | ConvertFrom-Json } catch {
            try { $wsj = ([regex]::Replace($rawWs, '(?s)"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*.*?\*/', { param($m) if ($m.Value.StartsWith('"')) { $m.Value } else { '' } }) -replace ',(\s*[}\]])', '$1') | ConvertFrom-Json } catch { return }
        }
        if (-not $wsj) { return }
        $dir = Split-Path $file -Parent
        $opensRoot = $false
        foreach ($f in @($wsj.folders)) {
            if (-not $f -or -not $f.path) { continue }
            $p = [string]$f.path
            if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $dir $p }
            try { $p = [IO.Path]::GetFullPath($p).TrimEnd('\').ToLowerInvariant() } catch { continue }
            if ($p -eq $rootNorm) { $opensRoot = $true }
        }
        if (-not $opensRoot) { return }
        $n = $null; if ($wsj.settings) { $n = $wsj.settings.'chat.subagents.allowInvocationsFromSubagents' }
        if ($n -eq $true) { $wsOk += $file } else { $wsMissing += $file }
    }
}
if ($userFlag) {
    if ($wsMissing.Count -gt 0) { $out.Add("         Saved workspace file(s) opening this folder need no patch: the user-level setting applies to them ($($wsMissing.Count) file(s)).") }
} elseif ($wsMissing.Count -gt 0) {
    $out.Add("         WARNING: saved workspace file(s) that open this folder LACK the nested-dispatch setting: $($wsMissing -join ' ; ')")
    $out.Add('         If the VS Code title bar ends with "(Workspace)" you opened one of these and Team Leads cannot reach workers. Fix (pick one): re-run the installer and answer Y to "Enable the agent team in your VS Code user settings" (covers every window); or add "chat.subagents.allowInvocationsFromSubagents": true inside that file''s "settings" block; or open the folder directly (File > Open Folder). Then Developer: Reload Window.')
} elseif ($wsOk.Count -gt 0) {
    $out.Add("         Saved workspace file(s) opening this folder carry the setting: $($wsOk -join ' ; ')")
}

# -- Identity (fab first, az fallback; bounded, never blocks) --
# Use the executables recorded by the installer (a bare `fab`/`az` can resolve to a
# different same-named tool) and cap each probe: a stuck SSO/proxy prompt must not
# hang session start.
$toolStatusPath = Join-Path $root '.github/agent-docs/tool-status.json'
$recorded = $null
if (Test-Path -LiteralPath $toolStatusPath) { try { $recorded = Get-Content -LiteralPath $toolStatusPath -Raw | ConvertFrom-Json } catch { } }
function Get-RecordedExe([string]$key, [string]$fallback) {
    $e = if ($recorded) { $recorded.$key } else { $null }
    if (-not $e) { return $fallback }
    if ($e.found -eq $false) { return $null }
    if ($e.path -and (Test-Path -LiteralPath $e.path)) { return [string]$e.path }
    $c = if ($e.command) { Get-Command ([string]$e.command).Split(' ')[0] -ErrorAction SilentlyContinue } else { $null }
    if ($c -and $c.Source) { return [string]$c.Source }
    return $null
}
function Invoke-Bounded([string]$exe, [string[]]$argList, [int]$seconds) {
    if (-not $exe) { return '' }
    try {
        $job = Start-Job -ScriptBlock { param($e, $a) & $e @a 2>&1 | Out-String } -ArgumentList $exe, $argList
        if (Wait-Job $job -Timeout $seconds) { $r = Receive-Job $job -ErrorAction SilentlyContinue | Out-String } else { $r = "(timed out after ${seconds}s)" }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return [string]$r
    } catch { return '' }
}
$identity = 'not logged in (run `fab auth login`, or `az login` for the az fallback)'
$fabStatus = Invoke-Bounded (Get-RecordedExe 'fab' 'fab') @('auth', 'status') 10
if ($fabStatus -match '(?im)^\s*(Account|User|Signed in|Logged in)[^\r\n]*') { $identity = 'fab: ' + $Matches[0].Trim() }
elseif ($fabStatus -match '(?i)[\w.+-]+@[\w.-]+') { $identity = 'fab: ' + $Matches[0] }
else {
    # fab failed, timed out (proxy/SSO) or is absent: az is the documented fallback.
    $azJson = Invoke-Bounded (Get-RecordedExe 'az' 'az') @('account', 'show', '--output', 'json') 20
    if ($azJson -match '"name"') { try { $a = ($azJson -replace '(?s)^.*?(\{.*\}).*$', '$1') | ConvertFrom-Json; $identity = "az: $($a.user.name) on $($a.name)" } catch { } }
    if ($fabStatus -match 'timed out') { $identity += ' (fab auth status timed out - proxy/SSO?)' }
}
$out.Add("IDENTITY $identity")

# -- Live tool re-check + tool-status.json refresh --
$present = @(); $missing = @(); $changed = @(); $mcpInstalled = @(); $mcpMissing = @()
if (Test-Path -LiteralPath $toolStatusPath) {
    try {
        $raw = Get-Content -LiteralPath $toolStatusPath -Raw
        $ts = $raw | ConvertFrom-Json
        foreach ($prop in $ts.PSObject.Properties) {
            if ($prop.Name -eq '_meta') { continue }
            $t = $prop.Value
            # MCP extensions: "installed" is all a file check can prove; connection state is per chat session.
            if ($t.category -eq 'mcp-extension') {
                $label = if ($prop.Name -eq 'powerBiModelMcpServer') { 'Power BI modeling MCP' } elseif ($prop.Name -eq 'fabricMcpServer') { 'Fabric MCP' } else { $prop.Name }
                if ($t.found) { $mcpInstalled += $label } else { $mcpMissing += $label }
                continue
            }
            if ($t.category -eq 'az-extension') { if ($t.found) { $present += $prop.Name }; continue }
            $ok = $false
            if ($t.path -and (Test-Path -LiteralPath $t.path)) { $ok = $true }
            elseif ($t.command) {
                $cmd = Get-Command ($t.command -split ' ')[0] -ErrorAction SilentlyContinue
                # A stale recorded path (tool moved/reinstalled) is replaced by the live one.
                if ($cmd) { $ok = $true; if ($cmd.Source) { $t | Add-Member -NotePropertyName path -NotePropertyValue $cmd.Source -Force } }
            }
            if ($ok -ne [bool]$t.found) {
                $changed += "$($prop.Name): $([bool]$t.found) -> $ok"
                $t.found = $ok
                $t.reason = if ($ok) { '' } else { "not found at session check $(Get-Date -Format yyyy-MM-dd)" }
            }
            # Detect-only products (te CLI, TE3) are reported when present, never nagged about.
            if ($ok) { $present += $prop.Name } elseif ($t.installMode -ne 'detect') { $missing += $prop.Name }
        }
        $ts._meta | Add-Member -NotePropertyName lastSessionCheck -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force
        [IO.File]::WriteAllText($toolStatusPath, ($ts | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    } catch { $out.Add("TOOLS    tool-status.json unreadable: $($_.Exception.Message)") }
    $out.Add("TOOLS    available: $($present -join ', ')")
    if ($missing.Count -gt 0) { $out.Add("         missing: $($missing -join ', ') (fallbacks apply; Capability Maintenance can install)") }
    if ($changed.Count -gt 0) { $out.Add("         changed since install: $($changed -join '; ') -> tool-status.json refreshed") }
    $mcpLine = if ($mcpInstalled.Count -gt 0) { "installed: $($mcpInstalled -join ', ')" } else { 'installed: none' }
    if ($mcpMissing.Count -gt 0) { $mcpLine += " | not installed: $($mcpMissing -join ', ')" }
    $out.Add("MCP      $mcpLine | connected: none yet - the Master opens a Power BI modeling connection (ConnectFabric) in the main chat before dispatching live-model work; installed != callable")
} else { $out.Add('TOOLS    tool-status.json not found -> re-run the installer') }

$out | ForEach-Object { Write-Output $_ }
if ($out.Count -le 1) { Write-Output 'STATUS   script ran but collected nothing - check that .vscode/settings.json and .github/agent-docs exist under ROOT' }
# Persist the block so the Master can read it even when the persistent shell swallows stdout.
try { [IO.File]::WriteAllText((Join-Path $root '.github/agent-docs/session-status.last.txt'), (($out -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false))) } catch { }
'@
Write-ManagedFile "$rootPath\.github\agent-docs\Get-SessionStatus.ps1" $sessionStatusScript
Write-Host "  Written: .github/agent-docs/Get-SessionStatus.ps1" -ForegroundColor Green

$startingFlowContent = @'
# Starting Flow - Fabric Workspace Master Agent

Run once, on the first message of every session. Keep it fast: one script call,
one compact status block, no blocking menus. The user came here to work.

---

## Phase 0 - Classify the opening message

- **GREETING** = hello / hi / good morning with no task in it.
- **TASK** = a question, request, or instruction.

Keep the original message: you will act on it right after Phase 1.

---

## Phase 1 - One-shot session status (single terminal call)

Run exactly this, from the workspace root, in ONE terminal call:

  powershell -NoProfile -ExecutionPolicy Bypass -File .github/agent-docs/Get-SessionStatus.ps1

It prints GENERATED / ROOT / SKILLS / CONFIG / MCP / IDENTITY / TOOLS lines and refreshes
`.github/agent-docs/tool-status.json` live (so the tool inventory is never a stale
install-time snapshot). It also writes the same block to
`.github/agent-docs/session-status.last.txt`. Relay it to the user as a compact block, for example:

"**Session ready.**
- Skills: Microsoft 2026-09-01 | Kurt 2026-08-28 | custom tmdl 2026-07-16 | pipelines 2026-07-16
- Identity: fab: user@contoso.com
- Tools: fab, az, sqlcmd, pbir, gh available | tabularEditor, pbiTools missing (fallbacks apply)
- MCP: Fabric MCP, Power BI modeling installed | connected: none (opened on first live task)
- Nested dispatch: enabled"

Rules:
- The status script resolves the workspace root from its own location, so run it
  exactly as written from any CWD. If it prints nothing, the persistent shell is
  usually wedged: run the same command once more in a NEW terminal. Only if that
  also prints nothing, read `.github/agent-docs/session-status.last.txt`.
- **Staleness guard.** Every block starts with `GENERATED <timestamp>`. Before relaying
  a block you read from the fallback file (or recall from earlier in this chat), compare
  that timestamp with the current time: older than ~1 hour means it predates this
  session (an installer re-run or a settings change since then is invisible in it).
  Say "status file is from <timestamp>, re-running" and run the script in a new
  terminal; never present an old block as the current state. Blocks from previous
  turns of this conversation are NOT a substitute for running the script now.
- Do NOT ask whether to run maintenance. If the script flags upstream skills older
  than 30 days, add ONE line: "Upstream skills are >30 days old - say *run maintenance*
  whenever you want them refreshed." Then move on.
- If the script says nested dispatch is NOT set, warn the user in one line that Team
  Leads cannot reach their workers until it is enabled (re-run the installer and answer Y
  to the user-settings prompt, or open the folder with File > Open Folder), then continue.
- If the CONFIG block carries a WARNING naming saved workspace file(s) that LACK the
  setting, relay that exact file path and the fix options in your status block. The
  setting is window-scoped: `.vscode/settings.json` having it does NOT help when the
  window was opened from a `.code-workspace` file that lacks it; only a USER-level
  setting reaches every window. Never tell the user `settings.json` is missing the
  setting without having read that file. You may offer to add the single line to that
  workspace file yourself - it is a config edit outside the Fabric artifacts, so ask
  for `APPROVED:EDIT:<file>` first, then tell the user to run Developer: Reload Window.
- `enabled at user level` means every window on this machine is covered; no further
  action, and saved workspace files need no patch.
- If the script itself fails, fall back to the two cheapest checks (`fab auth status`,
  then `az account show`) and say the status script was unavailable. Never block.
- Identity is informational: the local file-first workflow needs no CLI login.

---

## Phase 2 - MCP servers: the Master opens the connection, Leads use it

Do NOT probe the MCP servers at startup. `tool-status.json` only proves the
extensions are installed, never that the tools are callable or connected.

When a task needs a LIVE semantic model (live DAX, model metadata, measure edits on
a running model), the **Master opens the connection itself, in the main chat,
BEFORE dispatching** - dispatched agents cannot answer sign-in prompts, and
`ListConnections` on a fresh session is always empty (an empty list is NOT "not
callable"). Steps:

1. `ConnectFabric` needs the **exact display names**, not GUIDs. If the user gave a
   URL or ids (`app.powerbi.com/groups/<workspaceGuid>/datasets/<datasetGuid>`),
   resolve them first: `fab api workspaces/<workspaceGuid>` -> `displayName`, and
   `fab api workspaces/<workspaceGuid>/items/<datasetGuid>` -> `displayName` (REST
   `GET /v1/workspaces/{id}` / `/items/{id}` with an `az` token if `fab` is unusable).
2. Call the Power BI modeling MCP `connection_operations` tool with
   `operation: ConnectFabric`, `workspaceName: <exact workspace name>`,
   `semanticModelName: <exact model name>`. Answer any sign-in prompt. This also
   auto-starts the server on first use. You hold this server **only** for
   connection management and read-only checks - never edit a model through it;
   that is the Semantic Model team's job.
3. On success, note the returned connection name and put it in every WORK ORDER as
   `context: mcp connection: <name> (Power BI modeling MCP, ConnectFabric)`. The Lead
   and its workers pass `connectionName` on every MCP call; MCP is rung 1 of their
   tool ladder.
4. If the tool is not listed at all: ask the user once (Command Palette ->
   `MCP: List Servers` -> start "powerbi-modeling-mcp" / "Fabric MCP"; tick them in
   the chat Tools picker; turn off unrelated tool groups if the ~128-tool budget is
   full), then retry step 2.
5. If it still fails (auth blocked, policy, budget): say so in one line and put
   `context: mcp connection: none - reason: <error> - use REST fallback` in the
   WORK ORDER. Leads treat `none` as final (no probing). REST
   (`az account get-access-token` + Power BI `executeQueries`, `fab api`) covers
   live DAX value reads/compares; metadata comes from `getDefinition` (TMDL), not
   from REST queries.

For Fabric MCP (items, OneLake, definitions) no connection object exists: the owning
Lead makes ONE cheap read-only call (list workspaces) on first use and falls back to
`fab api` / REST if the tool is not callable.

---

## Phase 3 - Go to work

- **TASK**: proceed immediately using `.github/agent-docs/working-flow-reference.md`:
  classify, dispatch the owning Team Lead(s) with a WORK ORDER, consolidate.
- **GREETING**: after the status block ask one open question: "What would you like
  to work on? (semantic models, reports, data engineering & pipelines, administration,
  DevOps/ALM, applications, or maintenance)". No numbered menu, no dropdown switching:
  you route everything through the teams yourself.

The user never has to change agent in the dropdown for normal work. The only
optional switch is capability maintenance (installs/updates need interactive
approval), offered through the handoff button, and only when the user asks for it.
'@
Write-ManagedFile "$rootPath\.github\agent-docs\starting-flow.md" $startingFlowContent
Write-Host "  Written: .github/agent-docs/starting-flow.md" -ForegroundColor Green

$workingFlowContent = @'
# Working Flow Reference - Fabric Workspace organisation

Read by the Master for every request after startup, and by Team Leads, the
Architect and QA when they act. Workers do not read this file: their WORK ORDER
is their complete brief.

---

## Skills - registered natively, read before authoring

All skill sources are registered in `chat.agentSkillsLocations`, so every agent
sees the full skill list (name + description) without listing directories:

- **Custom (house style, always wins on style/conventions):** `.github/skills/`
  -> `fabric-tmdl`, `fabric-pipelines`, `fabric-cli-policy`.
- **Microsoft skills-for-fabric (MIT):** `skills-for-fabric/skills/<skill>/SKILL.md`
  -> Spark, SQL Warehouse/DB, Eventhouse/KQL, Dataflows, pipelines migration,
  medallion, Power BI report authoring/design/management/planning, semantic-model
  authoring/consumption, FabricIQ, migrations. Shared references in
  `skills-for-fabric/common/` (e.g. `COMMON-CLI.md`, `ITEM-DEFINITIONS-CORE.md`).
- **Kurt / data-goblin power-bi-agentic-development (GPL-3.0, read-only reference):**
  `power-bi-agentic-development/plugins/<plugin>/skills/<skill>/SKILL.md` -> DAX,
  semantic-model, naming conventions, lineage, TMDL/PBIP validation, PBIR, themes,
  Deneb/custom visuals, paginated, Tabular Editor, pbi-tools, Fabric CLI, Fabric admin.

Rules: read the relevant SKILL.md (and the references it points to) BEFORE
generating any code, TMDL, DAX, PBIR or JSON. Read both the custom and the
upstream skill for a topic: custom wins on style, upstream wins on syntax/spec.
If a skill you expect is not in your list, re-discover it by keyword under the
two cloned repos (folders may be renamed upstream) - never fail because of a path.

For any terminal CLI or REST API work, read `.github/skills/fabric-cli-policy/SKILL.md` first:
prefer the Fabric CLI (`fab api`, `fab job`, `fab export/import`, OneLake `fab cp`). The
Microsoft `skills-for-fabric/common/COMMON-CLI.md` (az rest) is the documented FALLBACK
for SQL/TDS and non-Fabric token audiences.

---

## Team protocol - how a request flows

The Master never implements. Every request is delivered through the teams:

1. **Classify** - which artifact(s), which department(s), local or live, any
   destructive/PROD/release element.
2. **Architect first only when needed** - dispatch **001 - Fabric Solution
   Architect** BEFORE the teams when the request spans two or more departments,
   changes a design (grain, storage mode, medallion layer, promotion path), or
   needs sequencing/rollback decisions. Single-team, single-artifact work goes
   straight to the Team Lead. The Architect returns a plan (ownership, order,
   validation, rollback); it never writes artifacts.
3. **Dispatch the owning Team Lead(s)** with a WORK ORDER (format below). Leads
   that own independent artifacts can run in parallel; dependent ones run in the
   Architect's order.
4. The **Lead** assigns exactly one worker per artifact, gives it a WORK ORDER,
   validates the returned work (itself or via its validation worker), and returns
   a WORK RESULT. A Lead may dispatch the Architect mid-work for a dependency or
   design question it cannot settle inside its department.
5. **QA after multi-team work** - dispatch **002 - Integration QA & Change
   Controller** when two or more artifacts changed, when anything targets a shared
   environment, or before a release. Not needed for a single validated file edit.
6. **Consolidate** one answer to the user: what changed, where, validation
   evidence, risks, and anything still needing the user's decision.

Routing map (topic -> Team Lead -> workers):
- TMDL / DAX / measures / relationships / live model queries -> **010 - Semantic Model Team Lead** -> 011-016
- PBIR reports / visuals / themes / paginated -> **020 - Reporting Team Lead** -> 021-026
- Spark / notebooks / lakehouse / SQL warehouse & DB / dataflows / pipelines / RTI / FabricIQ -> **030 - Data Engineering Team Lead** -> 031-038
- Capacity / workspaces / access / governance / monitoring -> **040 - Fabric Administration & Governance Team Lead** -> 041-043
- Git / GitHub / Azure DevOps / Fabric Git / deployment pipelines / releases / Power BI ALM -> **050 - ALM & DevOps Team Lead** -> 051-055
- Python / SDK / REST / XMLA / ODBC integrations -> **060 - Applications & Integration Team Lead** -> 061-063
- Documents, decks, briefings and exports built from Fabric data (Word/Excel/PowerPoint/PDF via Python or Office COM) -> **060 - Applications & Integration Team Lead** (061); the data comes from the owning data team first; **002 QA** reviews any document going to a human audience
- Skills, agents, tools, installer health, failed installs, updates -> **070 - Capability Maintenance Team Lead** -> 071-076

Route by TOPIC, not by tool availability: if a tool is missing, the request still
belongs to the same team, which reads `tool-status.json` and degrades gracefully.

### WORK ORDER (parent -> child)

```
WORK ORDER
goal: <one sentence, the user's words preserved>
artifact: <exact file path(s) or live item + workspace>; owner: <this child>
mode: local | live | hybrid
constraints: <style, naming, environment, must-not-touch>
validation expected: <what evidence to return>
approvals granted: <none | literal tokens the user approved>
context: <facts already established: branch, IDs, prior results>
```

### WORK RESULT (child -> parent)

```
WORK RESULT
status: DONE | DONE WITH RISKS | NEEDS APPROVAL | NEEDS INPUT | NEEDS ARCHITECT | OUT OF SCOPE | FAILED
changed: <files / live objects, or none>
validation: <what was run and the outcome>
risks: <or none>
request: <exact approval token, question, design decision, or correct owner - only when status is not DONE>
payload: <Architect: full PLAN block | QA: full VERDICT block | everyone else: omit>
```

The Architect's PLAN and QA's VERDICT travel verbatim in `payload` - the wrapper
is mandatory, the specialist block inside it is never summarised away.

Parents relay a child's `request` upward unchanged. Only the top-level agent asks
the user; it then re-dispatches the same Lead with the answer in `approvals granted`
or `context`. Nobody grants approvals on the user's behalf.

**The WORK RESULT block is the mandatory final message of every dispatched agent.**
A turn that ends without it - including a turn that ends on a statement of intent
("I'll now tighten that page", "next I will...") - counts as `FAILED`. Finish the
step, or end with `NEEDS INPUT` / `FAILED` stating exactly what remains. Parents
handle an empty or block-less return by **re-dispatching the same agent once** with
`context: your previous turn ended without a WORK RESULT; resume from where you
stopped and end with the WORK RESULT block` - never by doing the work themselves.

---

## Independent business repositories

If `.github/agent-docs/local/repository-map.local.json` exists, read it before
GitHub, Azure DevOps, Fabric Git, branch, PR, or release work. Each path under
`source-control-repositories/` is an independent repository with its own `.git`,
remote, branches, credentials, and write policy. It is not a submodule and is
never committed by the outer Fabric Agentic Workspace repository.

- Verify the selected repository, current branch, status, remote and mapped
  environment before changing anything.
- Never assume literal DEV/TEST/PROD branch names; use the local map.
- Never reset, clean, force-push, create/delete a branch, merge, or switch a
  Fabric workspace merely because the repository was onboarded.
- Repository cloning does not authorise a live Fabric connection or mutation.

---

## Working modes (local / live / hybrid)

This workspace can change Fabric in three ways. They share one promotion path,
but not identical risk. Default to file-first. Treat live and hybrid mutations
as uncommitted changes until they are validated and captured in Fabric Git.
Git rollback covers supported item definitions; it does not restore item data,
unsupported items, or every workspace setting.

- **A. Full local (file-first, default).** Pull items to local files, edit them,
  push back via the Fabric extension. Prefer this for versioned items and for bulk
  or structured edits.
- **B. Full live (in-workspace).** Act directly on the live DEV workspace via
  Fabric REST (`fab api ... updateDefinition`) and MCP servers. Use this for live
  DAX data comparison (TEST vs PROD), reading real deployed GUIDs / SQL endpoints,
  quick in-place fixes, and creating items. For live semantic models the **Master
  opens the Power BI modeling MCP connection first** (`connection_operations` ->
  `ConnectFabric`, exact workspace + model names) in the main chat and passes the
  connection name down in `context`; Leads/workers reuse it (`connectionName`) as
  rung 1. If the Master could not connect, the WORK ORDER says so and the REST/CLI
  fallback applies (`az account get-access-token` + Power BI `executeQueries`,
  `fab api ...`). MCP being "installed" is not enough - it must be connected in
  this session, and an empty `ListConnections` means "nobody connected yet", not
  "not callable".
- **C. Hybrid (local + live).** Mix both in one session.

### Read the user's intent before choosing local vs live

When the task implies LIVE / service work, do not silently default to the
file-first / REST-only safe path. The Master opens the MCP connection before
dispatching (see the starting flow, Phase 2); the owning Lead uses that
connection first, and if it still falls back to local or REST, SAYS SO
explicitly ("MCP connection not available this session, using REST/CLI instead")
rather than defaulting quietly. Treat any of
these as a live/MCP-first signal:

- The user pastes a live `app.powerbi.com/groups/<workspaceId>/...` workspace or
  report URL, or a service semantic-model URL / dataset GUID.
- The user says "live", "in the service", "via MCP", "on the running model", or
  asks you to read/compare REAL deployed data.
- The user asks you to go through reports/models that only exist in the workspace
  (not pulled to local files).

In those cases: the Master connects (or records that it could not); if a
connection name is in `context`, go MCP-first; if not, announce the REST/CLI
fallback and proceed - but never present a local-only pass as
if it were the live work the user asked for. When unsure whether local or live is
wanted, surface the choice instead of assuming.

### Hybrid discipline (avoid drift)

- Default to FILE-FIRST for any item that is versioned locally.
- Before a live edit, ANNOUNCE it (which item, which mechanism) so the user knows
  the change is not yet reflected in local files.
- After live edits, RE-PULL the affected items (or tell the user to) so local = live workspace.
- At the start of a NEW job, ensure local = live workspace first: re-pull, or clean up local.
- Never silently edit live an item the user is also editing as local files.

### Live-mode tools

- `fab` CLI: control plane + OneLake/data plane (read the CLI policy skill first).
- `az` CLI: fallback for SQL/TDS and non-Fabric token audiences.
- Fabric MCP server: items, OneLake files/tables, item definitions.
- Power BI semantic-model MCP server: live XMLA - run DAX (`EVALUATE`) and make
  transactional model edits on running models.

**MCP callable != MCP installed != MCP connected.** `tool-status.json`
`found`/`extensionInstalled` only proves the extension exists. Both servers
self-register (no mcp.json); their tools surface only when started and ticked in
the chat Tools picker, and the ~128-tool session budget can drop them. For the
Power BI modeling server a **connection** to the specific model is also required
(`ConnectFabric`), and only the top-level agent can satisfy its sign-in prompt -
which is why the Master connects before dispatching. Decide by the connection
name in `context`, not by the file. If none, use the REST/CLI fallback below.

**Lean live mode (protect the tool budget).** For MCP live work, turn OFF unrelated
tool groups in the chat Tools picker so the Fabric + Power BI MCP tools stay within
the ~128-tool limit. A fat tool list is the usual reason MCP tools go missing.

**REST/CLI fallback - what it covers and what it does not:**
- Live DAX without MCP: `az account get-access-token --resource https://analysis.windows.net/powerbi/api`
  then POST to the Power BI `executeQueries` REST endpoint. Per Microsoft's contract it
  runs **DAX `EVALUATE` queries only** - no MDX, no DMVs, no `INFO.*` functions - with one
  query per call, one result table, max 100,000 rows / 1,000,000 values / 15 MB, 120
  calls per minute, and it needs the tenant setting *Dataset Execute Queries REST API*
  plus Build permission. It covers value comparisons; it does **not** cover metadata.
- Model metadata without MCP: use `fab api ... getDefinition` (TMDL) or
  `power-bi-agentic-development/plugins/fabric-cli/skills/fabric-cli/scripts/export_semantic_model_as_pbip.py`;
  DMVs need an XMLA client (Tabular Editor / `te`), not REST. If an `INFO.VIEW.*`
  query happens to work on your endpoint treat it as a convenience, not a contract.
- Do not pipe REST JSON through `Get-Content -Raw` into `ConvertFrom-Json` blindly:
  PSObject decoration can corrupt it. Capture the raw string and parse that.
- Report what you could NOT verify through the fallback instead of declaring the
  comparison complete.

---

## Working Rules

- Always read the relevant SKILL.md BEFORE generating any code or TMDL
- Read BOTH custom and cloned skills for a topic. On STYLE / convention conflicts
  the custom skill wins; on SYNTAX / spec correctness the cloned (upstream) skill wins
- For validation after TMDL edits, run the post-edit checklist from the TMDL skill
- Keep git history clean if the workspace is a git repo
- Never hardcode IDs or secrets
- Require explicit environment parameterization (dev/test/prod)
- For validation after pipeline edits, run the validation checklist from the pipeline skill

### Terminal & tooling hygiene

- The integrated terminal is ONE shared shell. Parents sequence terminal work (at
  most one child at a time runs commands); a child never runs a command while another
  agent may be using the shell. Do not spawn a new terminal per command.
- Run one simple command per call, synchronously, and read the output it returns.
  The persistent shell corrupts inline `$`-variables in `-Command` strings and a
  multi-statement one-liner can wedge it into a `>>` continuation state (after which
  even built-in cmdlets report "not recognized"). Anything with loops, here-strings
  or more than two statements goes in a `.ps1` under `scripts/` (unique name) and runs
  via `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/<name>.ps1 > scripts/<name>.out.txt 2>&1`;
  then read the `.out.txt`. Agents without `edit` cannot write that file: they keep to
  single statements and ask their Lead for an edit-capable worker when a script is needed.
- "Command produced no output" is NOT proof the shell is wedged (many commands are
  silent). Re-run once with `| Out-String`. Only when built-in cmdlets report "not
  recognized" is the shell wedged: run the command as a child process
  (`powershell -NoProfile -ExecutionPolicy Bypass -File ...`) or open a fresh terminal
  if your tooling offers one; kill the wedged one.
- For fast-changing result/output files, read them with terminal `Get-Content`,
  not the cached file reader - the cache can serve stale content for a file you
  just rewrote. Prefer unique, single-use output file names.

### Who does the work (summary)

- Master = coordinator, never implementer, the only voice to the user. "You fix it"
  means "make the owning team fix it".
- Team Lead = owns the department outcome; assigns exactly one worker per artifact;
  validates before reporting; may consult the Architect mid-work.
- Worker = implements inside its artifact type with its skills and granted tools;
  validates its own change; returns a WORK RESULT; never widens its scope.
- Architect = cross-domain design/sequencing/rollback plans only. QA = cross-artifact
  acceptance only. Neither writes artifacts.
- Delegation is required for every domain change (not only "substantial" ones);
  one writer per artifact, always.
'@
Write-ManagedFile "$rootPath\.github\agent-docs\working-flow-reference.md" $workingFlowContent
Write-Host "  Written: .github/agent-docs/working-flow-reference.md" -ForegroundColor Green

# V0.6 generates the expanded organisation directly from the embedded manifest.
# Numbered display names keep the dropdown in Master -> reviewers -> team-leads
# order while worker agents remain available for delegation.
$orderedAgents = @(
    @($agentManifest.agents | Where-Object { $_.level -eq 'executive' })
    @($agentManifest.agents | Where-Object { $_.level -eq 'team-lead' })
    @($agentManifest.agents | Where-Object { $_.level -eq 'worker' })
)

# One three-digit, team-grouped number per agent, taken from the manifest
# filename prefix, used for BOTH the file name and the dropdown label so they
# always match (000 Master, 001/002 reviewers, 010/020/... leads, 011.. workers).
$displayLabelById = @{}
$threeDigitById = @{}
$agentByDisplayName = @{}
foreach ($entry in $orderedAgents) {
    $num3 = '{0:D3}' -f [int]([regex]::Match([string]$entry.filename, '^\d+').Value)
    $threeDigitById[$entry.id] = $num3
    $displayLabelById[$entry.id] = "$num3 - $($entry.displayName)"
    $agentByDisplayName[$entry.displayName] = $entry
}

# Role-scoped Model Context Protocol (MCP) server grants (least privilege).
# VS Code custom agents treat the `tools:` front matter as an ALLOWLIST: an agent
# can only see and invoke an MCP server's tools when the server wildcard
# `<server name>/*` is present in that list. Without this, agents whose tools are
# restricted to the built-in set (read/search/execute/edit) cannot use the Fabric
# or Power BI Modeling MCP servers at all, even though the extensions self-register.
# Server names below are the runtime labels the two extensions register (verified
# from the extension bundles): analysis-services.powerbi-modeling-mcp registers
# 'powerbi-modeling-mcp'; fabric.vscode-fabric-mcp-server registers 'Fabric MCP'.
# VS Code silently ignores tools that are not available, so listing a server on a
# machine without the extension is safe (no error, no regression). Delegated
# workers do NOT inherit a Team Lead's tools, so every authorised agent is granted
# explicitly here.
$powerBiModelingMcpAgents = @(
    # The Master holds the server only to open/close the connection in the main chat (sign-in prompts).
    'fabric-workspace-master',
    'semantic-model-team-lead', 'model-architecture-agent', 'relationships-storage-mode-agent',
    'tmdl-agent', 'dax-agent', 'semantic-security-ai-metadata-agent', 'semantic-validation-performance-agent'
)
$fabricMcpAgents = @(
    'data-engineering-team-lead', 'notebook-spark-agent', 'lakehouse-delta-mlv-agent', 'warehouse-sql-agent',
    'sql-database-agent', 'dataflows-gen2-agent', 'pipeline-orchestration-agent', 'real-time-intelligence-agent',
    'fabric-intelligence-ontology-agent',
    'fabric-administration-governance-team-lead', 'workspace-capacity-administration-agent',
    'security-access-governance-agent', 'monitoring-catalog-operations-agent',
    'alm-devops-team-lead', 'fabric-git-integration-agent', 'deployment-release-agent',
    'applications-integration-team-lead', 'python-fabric-sdk-agent', 'rest-authentication-xmla-agent',
    'sql-odbc-data-access-agent'
)
$mcpServersById = @{}
foreach ($mcpAgentId in $powerBiModelingMcpAgents) { $mcpServersById[$mcpAgentId] = @('powerbi-modeling-mcp') }
foreach ($mcpAgentId in $fabricMcpAgents) {
    if ($mcpServersById.ContainsKey($mcpAgentId)) { $mcpServersById[$mcpAgentId] += 'Fabric MCP' }
    else { $mcpServersById[$mcpAgentId] = @('Fabric MCP') }
}

function ConvertTo-AgentYamlList {
    param([object[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) { return '[]' }
    $quoted = @($Values | ForEach-Object {
        "'" + ([string]$_).Replace("'", "''") + "'"
    })
    return '[' + ($quoted -join ', ') + ']'
}

# Remove agent files created by earlier installer versions (the original nine
# and the later two-digit set). User-created agents and every other file in
# .github/agents remain untouched.
foreach ($legacyAgent in $legacyManagedAgents) {
    $legacyAgentPath = Join-Path "$rootPath\.github\agents" $legacyAgent
    if (Test-Path -LiteralPath $legacyAgentPath) {
        Remove-Item -LiteralPath $legacyAgentPath -Force
        Write-Host "  Replaced legacy installer agent: $legacyAgent" -ForegroundColor DarkGray
    }
}

# =====================================================================
# Agent knowledge catalog -- what makes each agent a specialist.
# Skill refs are workspace-relative paths resolved at install time; a missing
# path is emitted with a "re-discover by keyword" hint instead of being dropped,
# so renamed upstream folders degrade gracefully.
# =====================================================================
$MS = 'skills-for-fabric/skills'
$MC = 'skills-for-fabric/common'
$KP = 'power-bi-agentic-development/plugins'
$CS = '.github/skills'
$AD = '.github/agent-docs'

$agentKnowledge = @{
    # ---------------- executives ----------------
    'fabric-workspace-master' = @{
        skills = @(
            @{ ref = "$AD/starting-flow.md"; why = 'session startup (once)' },
            @{ ref = "$AD/working-flow-reference.md"; why = 'team protocol, routing map, WORK ORDER / WORK RESULT, working modes' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'only to classify whether a request is CLI/REST work' }
        )
        playbook = @(
            'Run the starting flow once, then act on the request in the same turn.',
            'Classify: artifacts, departments, local/live, destructive/PROD/release elements.',
            'Cross-domain or design change -> dispatch 001 Architect first for a plan; otherwise go straight to the owning Team Lead.',
            'Write one WORK ORDER per Team Lead; independent leads may run in parallel.',
            'Relay NEEDS APPROVAL / NEEDS INPUT to the user verbatim, get the answer, re-dispatch the same Lead with it.',
            'Two or more artifacts changed, or shared environment touched -> dispatch 002 QA before answering.',
            'Consolidate: what changed, where, validation evidence, risks, open decisions. Keep a short session ledger of approvals granted and results so follow-ups reuse them.'
        )
        validate = @('Every Lead result contains validation evidence; never report success from a result that lacks it.', 'One writer per artifact across all dispatched leads.')
        tools = @('agent (dispatch) is your primary tool; read/search only to classify; execute only for the status script.')
        avoid = @('Editing or running anything that changes a Fabric/Power BI artifact yourself.', 'Menus, dropdown-switch instructions, or re-running startup mid-session.', 'Dispatching the Architect for single-team, single-artifact work.')
    }
    'fabric-solution-architect' = @{
        skills = @(
            @{ ref = "$AD/working-flow-reference.md"; why = 'working modes, promotion path, team protocol' },
            @{ ref = "$MS/e2e-medallion-architecture"; why = 'lakehouse layering decisions' },
            @{ ref = "$KP/semantic-models/skills/semantic-model"; why = 'model design principles' },
            @{ ref = "$KP/semantic-models/skills/lineage-analysis"; why = 'impact analysis across artifacts' },
            @{ ref = "$MS/semantic-model-authoring"; why = 'Direct Lake vs Import trade-offs' },
            @{ ref = "$KP/pbip/skills/pbip"; why = 'PBIP project layout and dependencies' }
        )
        playbook = @(
            'Inspect the affected artifacts and their dependencies (lineage, relationships, pipeline references) before proposing anything.',
            'Produce a PLAN: ordered steps, one owning team + worker per step, artifact paths, validation per step, rollback per step, and open decisions for the user.',
            'Name the risks explicitly: grain changes, storage-mode changes, breaking measures/visuals, schedule impacts, PROD exposure.',
            'When a Team Lead consults you mid-work, answer only the design question asked and return control.'
        )
        validate = @('Every step in the plan has an owner, an artifact, a validation and a rollback.', 'No step asks two agents to write the same artifact.')
        tools = @('read/search only. You never edit artifacts and never run commands that change state.', 'You may dispatch Team Leads only when the Master explicitly asks you to run the plan; otherwise return the plan.')
        avoid = @('Implementing anything yourself.', 'Plans without rollback.', 'Assuming DEV/TEST/PROD branch or workspace names - read the local repository map.')
    }
    'integration-qa-change-controller' = @{
        skills = @(
            @{ ref = "$AD/working-flow-reference.md"; why = 'working modes, hybrid discipline, promotion path' },
            @{ ref = "$KP/pbip/skills/pbip"; why = 'PBIP validation' },
            @{ ref = "$KP/reports/skills/review-report"; why = 'report review checklist' },
            @{ ref = "$KP/semantic-models/skills/lineage-analysis"; why = 'cross-artifact impact' },
            @{ ref = "$KP/tabular-editor/skills/bpa-rules"; why = 'model best-practice rules' }
        )
        playbook = @(
            'Collect the WORK RESULTs of every team involved; list all changed artifacts.',
            'Check cross-references: measures used by visuals, tables used by pipelines/notebooks, relationships touched, parameters/environment values.',
            'Check environment and branch alignment against the local repository map; confirm nothing targeted PROD without approval.',
            'Check security and privacy: RLS/OLS intact, no secrets or IDs hardcoded, no credentials in files.',
            'Run or request the cheapest deterministic checks available (pbir validate, TMDL post-edit checklist, pipeline schema check, git diff review).',
            'Return ACCEPT / ACCEPT WITH RISKS / REJECT with the exact defects and the owning team for each.'
        )
        validate = @('Every changed artifact has evidence; every defect names an owner.')
        tools = @('read/search/execute for read-only checks and validators. Never edit artifacts.')
        avoid = @('Fixing defects yourself - send them back to the owning team.', 'Accepting results that only claim success without evidence.')
    }
    # ---------------- semantic model ----------------
    'semantic-model-team-lead' = @{
        skills = @(
            @{ ref = "$CS/fabric-tmdl/SKILL.md"; why = 'house style for TMDL/DAX - wins on conventions' },
            @{ ref = "$KP/semantic-models/skills/semantic-model"; why = 'model design and audit' },
            @{ ref = "$MS/semantic-model-authoring"; why = 'Direct Lake, TMDL deployment, refresh and read-only DAX/metadata via REST' },
            @{ ref = "$KP/tabular-editor/skills/te2-cli"; why = 'Tabular Editor 2 CLI when installed' }
        )
        playbook = @(
            'Decompose the request per artifact: table/column/partition -> 013 TMDL; measure/calc group -> 014 DAX; relationship/storage mode -> 012; RLS/OLS/descriptions/synonyms -> 015; design question -> 011; BPA/performance/regression -> 016.',
            'Choose the mechanism: local TMDL files (default) vs live model via Power BI modeling MCP (use the `mcp connection: <name>` the Master put in your WORK ORDER context; if it says none, use REST executeQueries / fab api getDefinition).',
            'Send one WORK ORDER per worker; never two workers on the same .tmdl file.',
            'After implementation, dispatch 016 for validation (or validate yourself for a single trivial edit), then return a WORK RESULT with evidence.'
        )
        validate = @('TMDL post-edit checklist from fabric-tmdl ran; DAX compiled/evaluated (live or via test query); no orphaned lineageTags; relationships still resolve.')
        tools = @('powerbi-modeling-mcp/* for live models with the Master-opened connectionName from context (never open one yourself); fab api for definitions; Tabular Editor 2 CLI when tool-status says found; sqlcmd only for Direct Lake source checks.')
        avoid = @('Editing TMDL yourself when a worker owns it.', 'Live edits without announcing them and without re-pull guidance.')
    }
    'model-architecture-agent' = @{
        skills = @(
            @{ ref = "$KP/semantic-models/skills/semantic-model"; why = 'star schema, grain, fact/dimension boundaries' },
            @{ ref = "$MS/semantic-model-authoring"; why = 'Direct Lake constraints and Import/composite trade-offs' },
            @{ ref = "$KP/semantic-models/skills/lineage-analysis"; why = 'downstream impact of model changes' },
            @{ ref = "$CS/fabric-tmdl/SKILL.md"; why = 'house conventions the design must fit' }
        )
        playbook = @('Read model.tmdl, relationships.tmdl and the fact tables to establish grain and cardinalities.', 'Assess: star schema compliance, role-playing dimensions, many-to-many, storage mode fit (Direct Lake / Import / DirectQuery / composite), calculation-group architecture.', 'Return a design recommendation with concrete table/relationship changes for 012/013 to implement and the measures 014 must adapt.')
        validate = @('Every recommended relationship has stated cardinality and direction; every storage-mode recommendation names its constraint (e.g. Direct Lake fallback triggers).')
        tools = @('read/search only - you design, others implement.')
        avoid = @('Editing files.', 'Recommending snowflakes or bidirectional filters without a stated reason.')
    }
    'relationships-storage-mode-agent' = @{
        skills = @(
            @{ ref = "$CS/fabric-tmdl/SKILL.md"; why = 'relationships.tmdl layout and house style' },
            @{ ref = "$KP/pbip/skills/tmdl"; why = 'TMDL relationship syntax' },
            @{ ref = "$MS/semantic-model-authoring"; why = 'Direct Lake behaviour and storage modes' },
            @{ ref = "$KP/semantic-models/skills/semantic-model"; why = 'cardinality and filter-direction guidance' }
        )
        playbook = @('Inspect relationships.tmdl and the two tables involved (key columns, data types, uniqueness).', 'Implement in relationships.tmdl only (never inside table files); set cardinality, crossFilteringBehavior, isActive explicitly; keep lineageTag stable.', 'For storage mode changes edit the partition mode and check Direct Lake eligibility (no unsupported transformations).')
        validate = @('Key column types match on both sides; no ambiguous paths introduced; exactly one active relationship per table pair; TMDL post-edit checklist passes.')
        tools = @('local TMDL edit (default); powerbi-modeling-mcp/* relationship operations for live models; fab api getDefinition to read a live model when MCP is unavailable.')
        avoid = @('Bidirectional filters as a default fix.', 'Editing relationships inside table .tmdl files.')
    }
    'tmdl-agent' = @{
        skills = @(
            @{ ref = "$CS/fabric-tmdl/SKILL.md"; why = 'house style: folder layout, indentation, property ordering, lineageTag rules - WINS on style' },
            @{ ref = "$KP/pbip/skills/tmdl"; why = 'TMDL language spec - wins on syntax' },
            @{ ref = "$KP/pbip/skills/pbip"; why = 'PBIP project structure and validation' },
            @{ ref = "$MS/semantic-model-authoring"; why = 'deploying TMDL to a live model via REST' }
        )
        playbook = @('Read the target .tmdl file(s) fully before editing; note existing property order and indentation.', 'Apply the edit preserving house style; new objects get a new GUID lineageTag; never rename lineageTags of existing objects.', 'Keep relationships in relationships.tmdl and expressions in expressions.tmdl.', 'Run the post-edit checklist from fabric-tmdl.')
        validate = @('Tabs vs spaces consistent with the file; every column has dataType and lineageTag; no duplicate object names; file still parses (TE2 CLI or pbir/pbip validation when available).')
        tools = @('read/edit local files (default); Tabular Editor 2 CLI for deploy/validate when found; fab api updateDefinition for live push only on explicit instruction.')
        avoid = @('Reformatting untouched sections.', 'Editing definition.pbism.', 'Touching relationships from inside a table file.')
    }
    'dax-agent' = @{
        skills = @(
            @{ ref = "$KP/semantic-models/skills/dax"; why = 'DAX correctness, context transition, time intelligence patterns - wins on syntax' },
            @{ ref = "$CS/fabric-tmdl/SKILL.md"; why = 'house style for measure placement, formatStrings, display folders' },
            @{ ref = "$KP/semantic-models/skills/standardize-naming-conventions"; why = 'measure naming' },
            @{ ref = "$MS/semantic-model-authoring"; why = 'running EVALUATE queries via REST for regression checks' }
        )
        playbook = @('Read the measure table and the related columns/relationships first; confirm the filter context the measure will run in.', 'Write the measure with explicit formatString and displayFolder per house style; prefer variables and CALCULATE over nested iterators.', 'Build a regression DAX query (EVALUATE with SUMMARIZECOLUMNS on the key dimensions) and run it live if a model is available (MCP dax_query, else executeQueries REST).', 'Report before/after values for changed measures.')
        validate = @('Measure compiles; regression query returns expected totals; no BLANK explosions on key slicers; formatString set; over REST executeQueries use EVALUATE value queries only (no INFO/DMV) and read metadata from getDefinition.')
        tools = @('powerbi-modeling-mcp/* (measure + dax_query operations) with the connectionName from your WORK ORDER context; REST executeQueries via az access token when context says no connection; local TMDL edit when no live model.')
        avoid = @('Measures without a regression query when a live model exists.', 'Calculated columns where a measure is intended.', 'Editing tables or relationships - that is 013/012.')
    }
    'semantic-security-ai-metadata-agent' = @{
        skills = @(
            @{ ref = "$CS/fabric-tmdl/SKILL.md"; why = 'roles, descriptions and synonyms placement' },
            @{ ref = "$MS/semantic-model-authoring"; why = 'permissions and RLS deployment via REST' },
            @{ ref = "$KP/pbip/skills/tmdl"; why = 'role/tablePermission TMDL syntax' },
            @{ ref = "$KP/semantic-models/skills/standardize-naming-conventions"; why = 'consistent business names for AI metadata' }
        )
        playbook = @('Inventory existing roles, tablePermissions, descriptions, synonyms and linguistic schema before changing anything.', 'Implement RLS/OLS as roles with explicit filter expressions; add descriptions/synonyms/AI instructions per table and measure where missing.', 'State the security impact explicitly in the WORK RESULT (who gains/loses visibility).')
        validate = @('Every role has at least one tablePermission; filter DAX compiles; test with a role-scoped EVALUATE when a live model is available; no PII in descriptions.')
        tools = @('local TMDL edit; powerbi-modeling-mcp/* security_role operations on live models; REST for role membership.')
        avoid = @('Changing role membership in PROD without approval.', 'Weakening an existing filter to make a query work.')
    }
    'semantic-validation-performance-agent' = @{
        skills = @(
            @{ ref = "$KP/tabular-editor/skills/bpa-rules"; why = 'Best Practice Analyzer rules' },
            @{ ref = "$KP/tabular-editor/skills/te2-cli"; why = 'running BPA and schema checks from the TE2 CLI' },
            @{ ref = "$KP/semantic-models/skills/semantic-model"; why = 'VertiPaq/size and model audit' },
            @{ ref = "$MS/semantic-model-authoring"; why = 'DAX regression via REST' },
            @{ ref = "$CS/fabric-tmdl/SKILL.md"; why = 'post-edit checklist' }
        )
        playbook = @('Run the fabric-tmdl post-edit checklist on every changed file.', 'If Tabular Editor 2 is found in tool-status, run BPA against the model; otherwise apply the top BPA rules manually (unused columns, missing formatStrings, bidirectional filters, high-cardinality text columns).', 'Run regression DAX queries provided by 014 (or write minimal ones) and compare results.', 'For Direct Lake models check fallback behaviour and column count/size hot spots.')
        validate = @('Report a table: check -> result -> evidence. FAIL any check you could not run; never mark it as passed.')
        tools = @('execute only (TE2 CLI, sqlcmd for source checks, REST); powerbi-modeling-mcp/* trace/dax_query for live diagnostics. You do not edit.')
        avoid = @('Fixing defects yourself - return them to the owning worker via the Lead.')
    }
    # ---------------- reporting ----------------
    'reporting-team-lead' = @{
        skills = @(
            @{ ref = "$KP/reports/skills/pbir-cli"; why = 'pbir CLI - primary report mutation tool' },
            @{ ref = "$KP/pbip/skills/pbir-format"; why = 'PBIR JSON format' },
            @{ ref = "$KP/reports/skills/pbi-report-design"; why = 'design principles' },
            @{ ref = "$MS/powerbi-report-cli"; why = 'Microsoft report lifecycle skill (modes: planning / design / authoring / management via REST) - read the mode reference it points to' }
        )
        playbook = @('Decompose: requirements/pages/visual choice -> 021; visuals and pages -> 022; theme/format -> 023; Deneb/SVG/custom -> 024; paginated -> 025; verification -> 026.', 'Serialize ownership: 022 and 023 never edit the same visual concurrently - sequence them.', 'Tool precedence for report mutation is fixed: pbir CLI first (house standard); Microsoft''s powerbi-report-author CLI only when pbir is missing from tool-status AND the user agrees to install it; direct PBIR JSON editing is the last resort and must be disclosed in the WORK RESULT.', 'Require 026 verification (pbir validate + Desktop check when available) before returning success.')
        validate = @('pbir validate passes on the report folder; no broken field bindings to the semantic model; no overlapping visuals.')
        tools = @('pbir CLI (check tool-status found/path); direct PBIR JSON edit only as a disclosed last resort; semantic dependencies go to 010 via the Master.')
        avoid = @('Inventing measures - request them from 010 through the Master.')
    }
    'report-planning-ux-agent' = @{
        skills = @(
            @{ ref = "$MS/powerbi-report-cli"; why = 'Microsoft planning + design modes (references/planning.md, references/design.md): audience, business questions, archetypes, approval gate' },
            @{ ref = "$KP/reports/skills/pbi-report-design"; why = 'visual selection, layout, accessibility' }
        )
        playbook = @('Capture audience, business questions, KPIs and interactions.', 'Produce a page plan: pages, visuals per page with field bindings, navigation, filters, accessibility notes, and the list of measures that must exist (for 010).', 'Return the plan as the design contract for 022/023/024.')
        validate = @('Every visual maps to an existing or requested measure/column; every page answers a stated question.')
        tools = @('read/search only.')
        avoid = @('Editing report files.')
    }
    'pbir-authoring-agent' = @{
        skills = @(
            @{ ref = "$KP/reports/skills/pbir-cli"; why = 'pbir CLI commands - use FIRST for pages/visuals' },
            @{ ref = "$KP/pbip/skills/pbir-format"; why = 'PBIR JSON schema for controlled direct edits' },
            @{ ref = "$KP/reports/skills/create-pbi-report"; why = 'end-to-end report creation flow' },
            @{ ref = "$MS/powerbi-report-cli"; why = 'Microsoft authoring mode (references/authoring.md) - PBIR semantics and validation; its powerbi-report-author CLI is an alternative to pbir, not an addition' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'CLI usage policy' }
        )
        playbook = @('Check tool-status for pbir; read its current --help before use (commands change).', 'Inspect the report definition (pages, visuals, bindings) before mutating.', 'Apply changes with pbir commands one at a time; validate after EACH mutation.', 'If pbir has no command for a mutation, first check `pbir set` with the dotted property path; only if that cannot express it, edit the PBIR JSON directly, validate immediately after, and state in the WORK RESULT exactly which file you hand-edited and why.')
        validate = @('pbir validate clean after every mutation; field references exist in the semantic model; visual container positions inside page bounds.')
        tools = @('pbir CLI (primary); direct JSON edit (fallback); never Desktop automation - that is 026.')
        avoid = @('Editing theme files (023) or Deneb specs (024).', 'Batch edits without intermediate validation.')
    }
    'theme-formatting-agent' = @{
        skills = @(
            @{ ref = "$KP/reports/skills/modifying-theme-json"; why = 'theme JSON structure and inheritance' },
            @{ ref = "$KP/reports/skills/pbi-report-design"; why = 'typography, palette, spacing, accessibility' },
            @{ ref = "$KP/pbip/skills/pbir-format"; why = 'where formatting lives in PBIR' }
        )
        playbook = @('Read the current theme and the visuals that override it.', 'Prefer theme-level changes over per-visual overrides; document any override you must keep.', 'Check colour contrast for accessibility.')
        validate = @('Theme JSON valid; report still validates; no visual lost its override unintentionally.')
        tools = @('read/edit files only.')
        avoid = @('Editing a visual 022 is currently working on - sequence through the Lead.')
    }
    'advanced-custom-visuals-agent' = @{
        skills = @(
            @{ ref = "$KP/custom-visuals/skills/deneb-visuals"; why = 'Deneb / Vega-Lite specs' },
            @{ ref = "$KP/custom-visuals/skills/svg-visuals"; why = 'SVG measures' },
            @{ ref = "$KP/custom-visuals/skills/python-visuals"; why = 'Python visuals' },
            @{ ref = "$KP/custom-visuals/skills/r-visuals"; why = 'R visuals' },
            @{ ref = "$KP/custom-visuals/skills/powerbi-custom-visuals"; why = 'AppSource/custom visual configuration' }
        )
        playbook = @('Confirm with the design contract that a native visual cannot do the job.', 'Implement the spec/measure; keep data volumes small; document dependencies (custom visual id, Python/R packages).')
        validate = @('Spec parses; bound fields exist; performance acceptable on the expected row count.')
        tools = @('read/edit files only.')
        avoid = @('Using custom visuals for standard charts.')
    }
    'paginated-reports-agent' = @{
        skills = @(
            @{ ref = "$KP/paginated-reports/skills/paginated-report"; why = 'RDL structure, parameters, data sources' }
        )
        playbook = @('Inspect the RDL, data sources and parameters.', 'Implement layout/parameters/datasets; keep connection strings parameterized.', 'Describe how to render/export for verification.')
        validate = @('RDL is well-formed XML; every dataset has a data source; parameters have defaults or prompts.')
        tools = @('read/edit files only.')
        avoid = @('Embedding credentials in data sources.')
    }
    'report-qa-desktop-agent' = @{
        skills = @(
            @{ ref = "$KP/reports/skills/review-report"; why = 'report review checklist' },
            @{ ref = "$KP/pbi-desktop/skills/connect-pbid"; why = 'connecting to a running Power BI Desktop for live checks' },
            @{ ref = "$KP/reports/skills/pbir-cli"; why = 'pbir validate' },
            @{ ref = "$KP/pbip/skills/pbip"; why = 'PBIP validation' }
        )
        playbook = @('Run pbir validate (or PBIP validation) on the report.', 'If Power BI Desktop is running with the report, connect and refresh/screenshot pages when the skill allows.', 'Check: overlapping/out-of-bounds visuals, truncated titles, blank visuals, broken bindings, theme inconsistencies, accessibility basics.', 'Return a defect list with page/visual ids and the owning worker.')
        validate = @('Every defect has a location and an owner; validation output attached.')
        tools = @('execute (pbir CLI, Desktop connection) - read-only; you do not edit.')
        avoid = @('Fixing visuals yourself.')
    }
    # ---------------- data engineering ----------------
    'data-engineering-team-lead' = @{
        skills = @(
            @{ ref = "$MS/e2e-medallion-architecture"; why = 'Bronze/Silver/Gold patterns' },
            @{ ref = "$CS/fabric-pipelines/SKILL.md"; why = 'house pipeline JSON conventions' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'fab-first CLI policy' },
            @{ ref = "$MC/COMMON-CORE.md"; why = 'shared Fabric REST/auth patterns for all Microsoft CLI skills' },
            @{ ref = "$MC/ITEM-DEFINITIONS-CORE.md"; why = 'item definition formats' }
        )
        playbook = @('Decompose by artifact: notebook/Spark -> 031; lakehouse/Delta/MLV/shortcuts -> 032; Warehouse/SQL endpoint -> 033; SQL Database -> 034; Dataflow Gen2 -> 035; pipeline -> 036; Eventhouse/Eventstream/Activator -> 037; FabricIQ/Ontology/Data Agent -> 038.', 'Keep layer decisions consistent (raw / validated / serving) and require environment parameterization.', 'Probe Fabric MCP by first use only when live item access is needed; otherwise fab api / REST.', 'Validate: notebook runs or dry-run, SQL executes, pipeline JSON schema-valid, before returning.')
        validate = @('No hardcoded IDs/secrets; incremental/watermark patterns for loads; validation gates between layers.')
        tools = @('Fabric MCP/* for live items (probe first); fab CLI; sqlcmd for SQL endpoints when found.')
        avoid = @('Treating a cross-workload request as one worker task.')
    }
    'notebook-spark-agent' = @{
        skills = @(
            @{ ref = "$MS/spark-cli"; why = 'notebook authoring, lakehouse access patterns, notebookutils, Livy sessions, job diagnostics' },
            @{ ref = "$MC/SPARK-NOTEBOOK-AUTHORING-CORE.md"; why = 'notebook cell conventions' },
            @{ ref = "$MC/notebook-authoring"; why = 'shared notebook authoring references' },
            @{ ref = "$KP/etl/skills/executing-spark"; why = 'Kurt Spark execution patterns' }
        )
        playbook = @('Read the notebook definition (.py/.ipynb) and its lakehouse attachments.', 'Implement PySpark/Spark SQL with explicit schemas, Delta writes, parameters cell for environment values.', 'Run or dry-run remotely when a session is available; capture the outcome.')
        validate = @('Code parses; parameters cell present; no hardcoded workspace/lakehouse IDs; write mode explicit (append/overwrite/merge).')
        tools = @('Fabric MCP/* for notebook items; fab api / Livy via the Microsoft skills; local file edit for definitions.')
        avoid = @('Using DuckDB or non-Spark engines without approval (032 owns that request).')
    }
    'lakehouse-delta-mlv-agent' = @{
        skills = @(
            @{ ref = "$MS/e2e-medallion-architecture"; why = 'medallion layering' },
            @{ ref = "$MS/spark-cli"; why = 'MLV SQL authoring and refresh, Delta and shortcuts' },
            @{ ref = "$MS/onelake-catalog-govern-cli"; why = 'OneLake catalog and governance operations' },
            @{ ref = "$KP/etl/skills/using-duckdb"; why = 'DuckDB - ONLY with explicit approval' }
        )
        playbook = @('Inspect tables, schemas, shortcuts and existing MLVs (Fabric MCP onelake tools or fab).', 'Implement Delta patterns: schema evolution rules, partitioning, OPTIMIZE/VACUUM cadence, incremental MERGE.', 'For MLVs write the SQL and schedule via the operations skill.')
        validate = @('Table schemas as intended; row counts sane; refresh/schedule returns success.')
        tools = @('Fabric MCP/* onelake tools; fab cp/ls; Spark via 031 when code must run.')
        avoid = @('Full reloads where incremental is possible.', 'DuckDB without user approval.')
    }
    'warehouse-sql-agent' = @{
        skills = @(
            @{ ref = "$MS/sqldw-cli"; why = 'Warehouse T-SQL authoring, read-only analytics, performance diagnostics' },
            @{ ref = "$MC/SQLDW-AUTHORING-CORE.md"; why = 'warehouse T-SQL constraints' },
            @{ ref = "$MC/SQLDW-CONSUMPTION-CORE.md"; why = 'read-only query patterns' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'sqlcmd -G and TDS fallback ladder' }
        )
        playbook = @('Read existing schema (INFORMATION_SCHEMA / sys views) before DDL.', 'Author idempotent scripts (IF NOT EXISTS / CREATE OR ALTER), parameterized by environment.', 'Execute with sqlcmd -G when tool-status says found and TDS is reachable; otherwise return the script with the REST/portal fallback.')
        validate = @('Script executes without error; row counts or object existence confirmed; no cross-database references unsupported by Warehouse.')
        tools = @('sqlcmd (path from tool-status); Fabric MCP/* for warehouse items; fab api for endpoints. If 1433 is blocked on THIS machine, use the fabric-cli-policy fallback and say so.')
        avoid = @('Assuming a TDS block is global.', 'Unsupported T-SQL features (check the core doc).')
    }
    'sql-database-agent' = @{
        skills = @(
            @{ ref = "$MS/sqldb-cli"; why = 'Fabric SQL Database authoring, querying and diagnostics' },
            @{ ref = "$MC/SQLDB-AUTHORING-CORE.md"; why = 'OLTP features: temporal, JSON, vectors' },
            @{ ref = "$MC/SQLDB-CONSUMPTION-CORE.md"; why = 'query patterns' }
        )
        playbook = @('Distinguish OLTP SQL Database from Warehouse - do not apply Warehouse constraints here.', 'Author procedures/temporal/JSON/vector objects idempotently; execute via sqlcmd when available.')
        validate = @('Objects exist; procedures execute; security (roles/permissions) explicit.')
        tools = @('sqlcmd; Fabric MCP/*; fab api.')
        avoid = @('Mixing Warehouse and SQL Database guidance.')
    }
    'dataflows-gen2-agent' = @{
        skills = @(
            @{ ref = "$MS/dataflows-cli"; why = 'create/modify/schedule/monitor Dataflows Gen2 and Gen1 -> Gen2 save-as' },
            @{ ref = "$MC/DATAFLOWS-AUTHORING-CORE.md"; why = 'M and destination rules' },
            @{ ref = "$MC/DATAFLOWS-CONSUMPTION-CORE.md"; why = 'refresh status and definition reading' },
            @{ ref = "$KP/semantic-models/skills/power-query"; why = 'Power Query M correctness' }
        )
        playbook = @('Read the dataflow definition (mashup M, queryMetadata, destinations).', 'Edit M with query folding in mind; set destinations explicitly; parameterize connections.', 'Trigger a refresh and read status when live access exists.')
        validate = @('M parses; destination mapping complete; refresh succeeds or failure diagnosed.')
        tools = @('Fabric MCP/* for items; fab api / REST per the Microsoft skill.')
        avoid = @('Hardcoding credentials or gateway IDs.')
    }
    'pipeline-orchestration-agent' = @{
        skills = @(
            @{ ref = "$CS/fabric-pipelines/SKILL.md"; why = 'house pipeline-content.json conventions, activity types, dependency chaining - wins on style' },
            @{ ref = "$MS/pipeline-migration"; why = 'Microsoft pipeline structure and migration' },
            @{ ref = "$MS/variable-library-cli"; why = 'Variable Library values instead of literals' },
            @{ ref = "$MC/ITEM-DEFINITIONS-CORE.md"; why = 'pipeline item definition format' }
        )
        playbook = @('Read pipeline-content.json fully; map activities and dependsOn chains.', 'Implement activities (Notebook, Dataflow, Copy, ForEach, IfCondition, SetVariable) with typeProperties per the skill; wire Variable Library values instead of literals.', 'Run the validation checklist from fabric-pipelines; schedule/retry/failure paths explicit.')
        validate = @('JSON valid; every dependsOn target exists; no orphan activities; parameters for environment values; retry policy on remote activities.')
        tools = @('local JSON edit (default); Fabric MCP/* or fab api to read/deploy live definitions.')
        avoid = @('Hardcoded workspace/item GUIDs in activities.')
    }
    'real-time-intelligence-agent' = @{
        skills = @(
            @{ ref = "$MS/eventhouse-cli"; why = 'KQL management and read-only queries: tables, ingestion, policies, MVs, functions' },
            @{ ref = "$MS/eventstream-cli"; why = 'Eventstream topology and monitoring' },
            @{ ref = "$MS/eventschemaset-cli"; why = 'event schema sets' },
            @{ ref = "$MS/activator-cli"; why = 'Activator rules and monitoring' },
            @{ ref = "$MC/EVENTHOUSE-CONSUMPTION-CORE.md"; why = 'KQL query patterns' }
        )
        playbook = @('Identify the artifact: Eventhouse/KQL DB, Eventstream, or Activator.', 'Author KQL management commands / topology / rules per the matching skill; keep ingestion mappings explicit.', 'Verify with a read-only query or status call.')
        validate = @('KQL executes; ingestion mapping matches schema; Eventstream status healthy.')
        tools = @('Fabric MCP/*; fab api; KQL via the Microsoft skills.')
        avoid = @('Running .drop or purge commands without approval.')
    }
    'fabric-intelligence-ontology-agent' = @{
        skills = @(
            @{ ref = "$MS/fabriciq"; why = 'FabricIQ concepts and Data Agents' },
            @{ ref = "$MS/fabriciq-ontology-cli"; why = 'Ontology authoring and consumption' },
            @{ ref = "$MS/search-consumption-cli"; why = 'search over Fabric items' }
        )
        playbook = @('These features change quickly: read the skill and check current API behaviour before acting.', 'Author ontology/data-agent definitions per the skill; validate by consumption calls.')
        validate = @('Definitions accepted by the API; a consumption query returns expected entities.')
        tools = @('Fabric MCP/*; fab api.')
        avoid = @('Assuming last-known API shapes without checking.')
    }
    # ---------------- administration & governance ----------------
    'fabric-administration-governance-team-lead' = @{
        skills = @(
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'fab-first for admin operations' },
            @{ ref = "$KP/fabric-admin/skills/audit-tenant-settings"; why = 'tenant settings audit' },
            @{ ref = "$KP/fabric-cli/skills/fabric-cli"; why = 'Fabric CLI operations' },
            @{ ref = "$MS/onelake-catalog-govern-cli"; why = 'OneLake catalog governance' },
            @{ ref = "$MS/e2e-fabric-cost-estimation"; why = 'capacity cost estimation' },
            @{ ref = "$MC/COMMON-CLI.md"; why = 'az rest fallback' }
        )
        playbook = @('Decompose: workspaces/capacities/settings -> 041; roles/Entra/permissions -> 042; catalog/jobs/monitoring -> 043.', 'Everything destructive or production-impacting needs explicit user approval - relay NEEDS APPROVAL upward, never assume.', 'Prefer read/inventory first, then the smallest-scope change.')
        validate = @('Every change has a before/after read; least privilege preserved.')
        tools = @('fab CLI; Fabric MCP/*; az rest fallback.')
        avoid = @('Deleting workspaces/items or changing capacity assignments without approval.')
    }
    'workspace-capacity-administration-agent' = @{
        skills = @(
            @{ ref = "$KP/fabric-cli/skills/fabric-cli"; why = 'fab commands for workspaces/capacities' },
            @{ ref = "$MS/e2e-fabric-cost-estimation"; why = 'capacity SKU cost impact' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'CLI policy' },
            @{ ref = "$MC/COMMON-CLI.md"; why = 'REST fallback' }
        )
        playbook = @('List/inspect the workspace or capacity first (fab ls / fab get).', 'Apply settings or assignments with the smallest scope; record before/after.', 'Cost awareness: note capacity SKU impact of changes.')
        validate = @('Post-change read matches intent.')
        tools = @('fab (path from tool-status); Fabric MCP/*; az rest.')
        avoid = @('Any deletion or capacity reassignment without an approval token in the work order.')
    }
    'security-access-governance-agent' = @{
        skills = @(
            @{ ref = "$KP/fabric-admin/skills/audit-tenant-settings"; why = 'governance/tenant audit' },
            @{ ref = "$KP/fabric-cli/skills/fabric-cli"; why = 'role assignment commands' },
            @{ ref = "$MS/onelake-catalog-govern-cli"; why = 'OneLake catalog governance (labels, endorsement)' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'CLI policy' }
        )
        playbook = @('Inventory current roles/permissions/groups before proposing changes.', 'Apply least privilege: prefer Entra groups over individuals; document each grant.', 'State the security boundary impact in the result.')
        validate = @('No broadening of access beyond the request; every grant has a justification.')
        tools = @('fab; Fabric MCP/*; az rest.')
        avoid = @('Granting Admin where Contributor/Member suffices.')
    }
    'monitoring-catalog-operations-agent' = @{
        skills = @(
            @{ ref = "$MS/search-consumption-cli"; why = 'catalog / item search' },
            @{ ref = "$MS/spark-cli"; why = 'Spark job diagnostics' },
            @{ ref = "$MS/sqldw-cli"; why = 'Warehouse query insights' },
            @{ ref = "$MS/dataflows-cli"; why = 'refresh status' },
            @{ ref = "$MS/azmon-mirroredcatalogs-operations-cli"; why = 'Azure Monitor / mirrored catalog operations' },
            @{ ref = "$MC/SPARK-MONITORING-CORE.md"; why = 'Spark monitoring patterns' },
            @{ ref = "$KP/semantic-models/skills/refresh-semantic-model"; why = 'model refresh history' }
        )
        playbook = @('Inventory items and jobs (fab, MCP list tools, REST).', 'Diagnose failures from job/refresh history; correlate with recent changes.', 'Report findings and the owning team for remediation - do not remediate yourself.')
        validate = @('Evidence for each finding (job id, timestamp, error text).')
        tools = @('read-only: fab ls/get, Fabric MCP/* list tools, REST GETs.')
        avoid = @('Restarting, cancelling or re-running jobs without approval.')
    }
    # ---------------- ALM & DevOps ----------------
    'alm-devops-team-lead' = @{
        skills = @(
            @{ ref = "$AD/local/repository-map.local.json"; why = 'machine-specific repository/branch/environment map - read FIRST when present' },
            @{ ref = "$AD/working-flow-reference.md"; why = 'promotion path and hybrid discipline' },
            @{ ref = "$MS/git-integration-operations-cli"; why = 'Fabric Git integration operations via REST' },
            @{ ref = "$MS/deployment-pipelines-authoring-cli"; why = 'Fabric deployment pipelines' },
            @{ ref = "$KP/pbip/skills/pbip"; why = 'PBIP structure for diffs' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'fab for Fabric Git operations' }
        )
        playbook = @('Identify the repository (source-control-repositories/<repo>), branch, remote and write policy from the local map before anything.', 'Decompose: GitHub -> 051; Azure DevOps -> 052; Fabric Git connect/commit/update -> 053; release sequencing/deployment pipelines -> 054; PBIX/PBIP tooling -> 055.', 'Never infer permission to push, merge, reset, or connect a workspace from the fact that a repo was cloned.')
        validate = @('git status clean or explained; branch matches the mapped environment; PR/commit references returned.')
        tools = @('git; gh (051); az devops (052); fab (053); Fabric MCP/* read for item state.')
        avoid = @('Force-push, reset --hard, branch deletion without approval.')
    }
    'github-source-control-agent' = @{
        skills = @(
            @{ ref = "$AD/local/repository-map.local.json"; why = 'repo topology and write policy' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'CLI hygiene' }
        )
        playbook = @('git status / branch / remote -v first; confirm the mapped branch policy.', 'Use gh (path from tool-status) for PRs, reviews, Actions, releases; commit with clear messages; never bypass hooks.')
        validate = @('Commands succeeded; PR/commit URL returned; no credentials printed.')
        tools = @('git, gh. execute only - you do not edit artifact files.')
        avoid = @('--no-verify, force pushes, amending published commits.')
    }
    'azure-devops-agent' = @{
        skills = @(
            @{ ref = "$AD/local/repository-map.local.json"; why = 'repo topology and write policy' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'CLI hygiene' }
        )
        playbook = @('git status / branch / remote -v first; confirm the mapped branch policy.', 'Use az repos / az pipelines / az boards (az devops extension, check tool-status) for PRs, pipelines and work items.')
        validate = @('Commands succeeded; PR/pipeline ids returned; no PAT or token echoed.')
        tools = @('git, az devops. execute only.')
        avoid = @('Force pushes, policy bypasses, deleting branches without approval.')
    }
    'fabric-git-integration-agent' = @{
        skills = @(
            @{ ref = "$MS/git-integration-operations-cli"; why = 'Fabric Git integration: connect, status, commit, update via REST' },
            @{ ref = "$KP/fabric-cli/skills/fabric-cli"; why = 'fab git commands' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'fab-first policy' },
            @{ ref = "$AD/local/repository-map.local.json"; why = 'which workspace maps to which branch' },
            @{ ref = "$MC/COMMON-CLI.md"; why = 'REST fallback for Git integration endpoints' }
        )
        playbook = @('Read Git status of the workspace (fab / REST getStatus) before any commit or update.', 'Commit workspace -> Git or update Git -> workspace only as instructed; surface conflicts, never auto-resolve by overwriting a side.')
        validate = @('Post-operation status shows the expected state; conflict list returned if any.')
        tools = @('fab; REST via az account get-access-token fallback.')
        avoid = @('Connecting/disconnecting a workspace or choosing a conflict resolution without approval.')
    }
    'deployment-release-agent' = @{
        skills = @(
            @{ ref = "$AD/working-flow-reference.md"; why = 'DEV -> TEST -> PROD promotion path' },
            @{ ref = "$AD/local/repository-map.local.json"; why = 'environment/branch map' },
            @{ ref = "$MS/deployment-pipelines-authoring-cli"; why = 'Fabric deployment pipelines: stages, deploy, rules' },
            @{ ref = "$MS/variable-library-cli"; why = 'per-environment values via Variable Library' },
            @{ ref = "$KP/fabric-cli/skills/fabric-cli"; why = 'deployment pipeline commands' }
        )
        playbook = @('Build the release plan: sequence, parameters per environment, checks before/after, rollback.', 'Execute only the approved step; PROD steps always need an explicit approval token.', 'Produce release notes from the changed artifacts.')
        validate = @('Each stage verified before the next; rollback path stated.')
        tools = @('fab; git; execute only.')
        avoid = @('Assuming literal branch names; deploying to PROD without approval.')
    }
    'power-bi-alm-agent' = @{
        skills = @(
            @{ ref = "$KP/pbip/skills/pbip"; why = 'PBIP extract/build structure' },
            @{ ref = "$KP/tabular-editor/skills/te2-cli"; why = 'TE2 CLI for model build/deploy' },
            @{ ref = "$KP/tabular-editor/skills/te-cli"; why = 'te CLI (preview) when found' }
        )
        playbook = @('Check tool-status for pbi-tools / TE2; use them only for PBIX<->PBIP extraction, builds, CI/CD deployment - not routine visual edits (that is 022).', 'Return the exact commands run and their output.')
        validate = @('Extracted/built artifacts open and validate.')
        tools = @('pbi-tools, Tabular Editor 2 CLI (paths from tool-status); if missing, report and propose Capability Maintenance install.')
        avoid = @('Editing PBIR visuals.')
    }
    # ---------------- applications & integration ----------------
    'applications-integration-team-lead' = @{
        skills = @(
            @{ ref = "$MC/COMMON-CORE.md"; why = 'Fabric REST/auth patterns' },
            @{ ref = "$MC/COMMON-CLI.md"; why = 'az rest and token audiences' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'fab-first policy' },
            @{ ref = "$MS/semantic-model-authoring"; why = 'XMLA/DAX consumption via REST' }
        )
        playbook = @('Decompose: Python apps/SDK -> 061; REST/auth/XMLA -> 062; ODBC/SQL access -> 063.', 'Secrets never appear in code or commands: use Azure Identity / az login / environment variables.')
        validate = @('Sample call succeeds against DEV; no secrets in files.')
        tools = @('Fabric MCP/* for discovery; az/fab for tokens; python.')
        avoid = @('Hardcoding tenant/client secrets.')
    }
    'python-fabric-sdk-agent' = @{
        skills = @(
            @{ ref = "$MC/COMMON-CORE.md"; why = 'REST patterns to wrap' },
            @{ ref = "$MS/semantic-model-authoring"; why = 'DAX/metadata via REST from Python' },
            @{ ref = "$MS/spark-cli"; why = 'Livy from Python' }
        )
        playbook = @('Use a venv; pin dependencies; Azure Identity (DefaultAzureCredential) for auth.', 'Wrap REST with retries/backoff; parameterize workspace/item IDs.', 'Provide a runnable example and a minimal test.')
        validate = @('py_compile passes; example runs against DEV or is clearly marked untested.')
        tools = @('python, pip (venv); Fabric MCP/* for discovery.')
        avoid = @('Global pip installs; secrets in source.')
    }
    'rest-authentication-xmla-agent' = @{
        skills = @(
            @{ ref = "$MC/COMMON-CLI.md"; why = 'az rest, audiences, token acquisition' },
            @{ ref = "$MC/COMMON-CORE.md"; why = 'Fabric REST conventions' },
            @{ ref = "$MS/semantic-model-authoring"; why = 'executeQueries / XMLA read patterns' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'fab api first' }
        )
        playbook = @('Prefer fab api; fall back to az rest with the correct audience (Fabric vs Power BI vs Analysis Services).', 'executeQueries runs DAX EVALUATE only (no INFO/DMV, one query per call, 100k-row cap); metadata comes from getDefinition or an XMLA client.', 'Capture raw JSON strings before parsing.')
        validate = @('Call returns 2xx; response parsed; no token echoed.')
        tools = @('fab, az; Fabric MCP/*; execute only.')
        avoid = @('Printing tokens; storing secrets.')
    }
    'sql-odbc-data-access-agent' = @{
        skills = @(
            @{ ref = "$MS/sqldw-cli"; why = 'Warehouse/SQL endpoint consumption' },
            @{ ref = "$MS/sqldb-cli"; why = 'SQL Database consumption' },
            @{ ref = "$MC/SQLDW-CONSUMPTION-CORE.md"; why = 'query patterns' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'sqlcmd -G and TDS fallback ladder' }
        )
        playbook = @('Use sqlcmd -G / pyodbc / SQLAlchemy with Entra auth; parameterize queries.', 'If TDS 1433 fails on this machine, use the fallback ladder and say so - do not generalize the block.')
        validate = @('Connection succeeds or fallback used; query results sampled.')
        tools = @('sqlcmd (path from tool-status), pyodbc/SQLAlchemy; execute only.')
        avoid = @('String-concatenated SQL; embedded passwords.')
    }
    # ---------------- capability maintenance ----------------
    'capability-maintenance-team-lead' = @{
        skills = @(
            @{ ref = "$AD/tool-status.json"; why = 'current tool inventory' },
            @{ ref = "$AD/Get-SessionStatus.ps1"; why = 'one-call health/freshness check' },
            @{ ref = "$AD/installed-manifest.json"; why = 'managed-file integrity' },
            @{ ref = "$KP/goblin-mode/skills/improve-my-agent-setup"; why = 'Kurt guidance on improving the agent setup' }
        )
        playbook = @('Offer light (repo refresh + tool inventory) or deep (plus skill inventory/mapping, agent coverage, installer health) maintenance.', 'Delegate: repo sync -> 071; skill inventory -> 072; agent coverage -> 073; tool install/update (approval required) -> 074; installer/tests -> 075; managed-file diffs -> 076.', 'Never install or update software without a separate explicit approval.')
        validate = @('Repos at upstream or reported dirty/diverged; tool-status refreshed; skill locations registered.')
        tools = @('git, powershell, installer -VerifyRoot; execute/edit inside .github and vendor clones only as the workers permit.')
        avoid = @('Leaving a vendor clone diverged from upstream.', 'Editing custom skills (house style) without user request.')
    }
    'upstream-repository-sync-agent' = @{
        skills = @(@{ ref = "$AD/working-flow-reference.md"; why = 'vendor repositories are read-only references' })
        playbook = @('For skills-for-fabric and power-bi-agentic-development (vendor read-only references): git fetch --prune origin; record the current and upstream commit hashes.', 'If git status --porcelain shows local edits: git stash push -u -m "maintenance-autostash <timestamp>" and report the stash name so nothing is lost.', 'git reset --hard origin/HEAD so the clone mirrors live upstream exactly (same rule as the installer). Offline/missing repos: report and skip.', 'Report before/after hashes and whether new skill folders appeared (for re-registration).')
        validate = @('HEAD equals origin/HEAD after refresh; any stash name reported; no vendor file edited by hand.')
        tools = @('git; execute only.')
        avoid = @('git push to a vendor repo; hand-editing vendor files; running this on the user''s own business repositories under source-control-repositories/ (those belong to 050).')
    }
    'skill-inventory-mapping-agent' = @{
        skills = @(@{ ref = "$AD/working-flow-reference.md"; why = 'which agent should own which skill topics' })
        playbook = @('Enumerate every SKILL.md under .github/skills, skills-for-fabric/skills, power-bi-agentic-development/plugins/*/skills.', 'Detect: invalid frontmatter, duplicates, added/removed/renamed vs the registered chat.agentSkillsLocations, skills that assume a missing tool.', 'Propose mapping changes to 073; refresh registration by listing missing containers for the installer/074.')
        validate = @('Inventory table produced; each anomaly has a proposed action.')
        tools = @('read/search/execute; may edit only inventory/report files under .github/agent-docs.')
        avoid = @('Editing vendor skills.')
    }
    'agent-coverage-organization-agent' = @{
        skills = @(@{ ref = "$AD/working-flow-reference.md"; why = 'routing map and team boundaries' })
        playbook = @('Compare skill inventory against agent Knowledge sections: gaps, overlaps, overloaded workers.', 'Auto-apply only obvious low-risk mapping notes; propose structural changes (new/merged agents) for approval.')
        validate = @('Every skill has at least one owning agent or a documented reason not to.')
        tools = @('read/search/edit (proposal files only).')
        avoid = @('Renumbering or deleting agents without approval.')
    }
    'environment-tooling-agent' = @{
        skills = @(
            @{ ref = "$AD/tool-status.json"; why = 'inventory to refresh' },
            @{ ref = "$CS/fabric-cli-policy/SKILL.md"; why = 'what each tool is for' },
            @{ ref = "$KP/tabular-editor/skills/te2-cli"; why = 'TE2 install expectations' },
            @{ ref = "$KP/reports/skills/pbir-cli"; why = 'pbir install expectations' }
        )
        playbook = @('Diagnose the exact failure (PATH, proxy block, missing runtime) before proposing an install.', 'Install/update only with explicit approval, user-scope/portable, never admin; validate the real executable; refresh tool-status.json (found/path/version).', 'On locked-down laptops use the documented manual-download fallbacks and report the exact link.')
        validate = @('tool --version succeeds from the recorded path; tool-status updated.')
        tools = @('pip/venv, winget download, portable zips; execute/edit.')
        avoid = @('Installing without the approval token; modifying system PATH.')
    }
    'installer-health-regression-agent' = @{
        skills = @(@{ ref = "$AD/installed-manifest.json"; why = 'integrity manifest' })
        playbook = @('Run the installer with -VerifyRoot to detect drift; run the Pester suite when the source repo is available.', 'Check schema/manifest/generated-file consistency and report failures with file paths.')
        validate = @('Exit codes and test counts reported.')
        tools = @('powershell, installer, Pester; read-only otherwise.')
        avoid = @('Modifying the installer or tests - report to the maintainer.')
    }
    'managed-file-review-agent' = @{
        skills = @(@{ ref = "$AD/installed-manifest.json"; why = 'which files are installer-managed' })
        playbook = @('Diff installer-managed files against on-disk copies; classify differences as intentional local customisation vs drift.', 'Apply an amendment only when the user explicitly asks; otherwise report.')
        validate = @('Every difference listed with a recommendation.')
        tools = @('read/search/edit (approved amendments only).')
        avoid = @('Silently reverting user customisations.')
    }
}

$bt = [string][char]96

# Topic keywords per agent. At install time every upstream SKILL.md (name +
# description) is matched against these, so skills added or renamed upstream
# attach themselves to the right specialist on the next installer run without
# touching the curated list above.
$agentSkillKeywords = @{
    'fabric-solution-architect'                 = @('medallion', 'lineage', 'semantic model', 'star schema', 'direct lake')
    'integration-qa-change-controller'          = @('review-report', 'bpa', 'lineage', 'pbip', 'audit-tenant')
    'semantic-model-team-lead'                  = @('semantic-model', 'tmdl', 'dax', 'te2', 'te-cli', 'refresh-semantic-model', 'bpa')
    'model-architecture-agent'                  = @('semantic-model', 'direct lake', 'star schema', 'lineage', 'grain')
    'relationships-storage-mode-agent'          = @('relationship', 'direct lake', 'storage mode', 'cardinality')
    'tmdl-agent'                                = @('tmdl', 'pbip', 'semantic-model-authoring')
    'dax-agent'                                 = @('dax', 'measure', 'calculation group', 'naming-conventions')
    'semantic-security-ai-metadata-agent'       = @('row-level security', 'rls', 'object-level', 'synonym', 'linguistic schema')
    'semantic-validation-performance-agent'     = @('bpa', 'best practice analyzer', 'vertipaq', 'te2', 'te-cli', 'c-sharp-scripting')
    'reporting-team-lead'                       = @('pbir', 'report-design', 'report-authoring', 'report-planning', 'theme', 'paginated', 'visual')
    'report-planning-ux-agent'                  = @('report-planning', 'report-design', 'accessibility', 'wireframe')
    'pbir-authoring-agent'                      = @('pbir', 'report-authoring', 'create-pbi-report', 'report-design')
    'theme-formatting-agent'                    = @('theme', 'conditional formatting', 'report-design')
    'advanced-custom-visuals-agent'             = @('deneb', 'svg', 'custom visual', 'python-visuals', 'r-visuals', 'vega')
    'paginated-reports-agent'                   = @('paginated', 'rdl')
    'report-qa-desktop-agent'                   = @('review-report', 'connect-pbid', 'pbir-cli', 'screenshot')
    'data-engineering-team-lead'                = @('spark', 'lakehouse', 'sqldw', 'pipeline', 'dataflows', 'medallion', 'eventhouse', 'mlv')
    'notebook-spark-agent'                      = @('spark', 'notebook', 'pyspark', 'livy', 'executing-spark')
    'lakehouse-delta-mlv-agent'                 = @('lakehouse', 'delta', 'materialized lake view', 'mlv', 'shortcut', 'onelake', 'medallion')
    'warehouse-sql-agent'                       = @('sqldw', 'warehouse', 't-sql', 'sql analytics endpoint')
    'sql-database-agent'                        = @('sqldb', 'sql database')
    'dataflows-gen2-agent'                      = @('dataflows', 'dataflow gen2', 'power-query', 'mashup')
    'pipeline-orchestration-agent'              = @('pipeline-migration', 'data pipeline', 'data factory', 'copy activity')
    'real-time-intelligence-agent'              = @('eventhouse', 'kql', 'eventstream', 'activator', 'real-time intelligence')
    'fabric-intelligence-ontology-agent'        = @('fabriciq', 'ontology', 'data agent', 'search-consumption')
    'fabric-administration-governance-team-lead'= @('audit-tenant', 'tenant setting', 'capacity', 'fabric-cli', 'governance', 'onelake-catalog', 'cost-estimation')
    'workspace-capacity-administration-agent'   = @('capacity', 'fabric-cli', 'workspace administration', 'cost-estimation')
    'security-access-governance-agent'          = @('audit-tenant', 'tenant setting', 'permission', 'entra')
    'monitoring-catalog-operations-agent'       = @('operations-cli', 'monitoring', 'diagnos', 'search-consumption', 'refresh-semantic-model', 'query insights', 'azmon')
    'alm-devops-team-lead'                      = @('pbip', 'pbi-tools', 'deployment-pipelines', 'git-integration', 'ci/cd', 'variable-library')
    'github-source-control-agent'               = @('github', 'gh cli')
    'azure-devops-agent'                        = @('azure devops', 'az devops', 'azure repos')
    'fabric-git-integration-agent'              = @('git-integration', 'git integration', 'fabric-cli')
    'deployment-release-agent'                  = @('deployment-pipelines', 'deployment pipeline', 'release', 'promotion', 'variable-library')
    'power-bi-alm-agent'                        = @('pbi-tools', 'pbix', 'pbip', 'te2', 'tabular editor')
    'applications-integration-team-lead'        = @('sdk', 'xmla', 'odbc', 'semantic-model', 'authentication')
    'python-fabric-sdk-agent'                   = @('python sdk', 'sempy', 'semantic-link', 'livy')
    'rest-authentication-xmla-agent'            = @('authentication', 'token', 'xmla', 'executequeries', 'service principal')
    'sql-odbc-data-access-agent'                = @('odbc', 'sqlcmd', 'sqldw', 'sqldb', 'tds')
    'capability-maintenance-team-lead'          = @('check-updates', 'improve-my-agent-setup')
    'skill-inventory-mapping-agent'             = @('check-updates', 'improve-my-agent-setup')
    'environment-tooling-agent'                 = @('check-updates', 'te2-cli', 'pbir-cli', 'fabric-cli')
}

# Index every upstream skill once (folder, name, description) for keyword matching.
$upstreamSkillIndex = @()
foreach ($containerRel in @(Get-SkillContainerDirs -RootPath $rootPath -SearchSubPaths @('skills-for-fabric\skills', 'power-bi-agentic-development\plugins'))) {
    $containerFull = Join-Path $rootPath ($containerRel -replace '/', '\')
    Get-ChildItem -LiteralPath $containerFull -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $skillFile = Join-Path $_.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $skillFile)) { return }
        $head = (Get-Content -LiteralPath $skillFile -TotalCount 40 -ErrorAction SilentlyContinue) -join "`n"
        $fm = [regex]::Match($head, '(?s)^---\s*\n(.*?)\n---')
        $fmText = if ($fm.Success) { $fm.Groups[1].Value } else { '' }
        $nameM = [regex]::Match($fmText, '(?m)^name:\s*["'']?([^\r\n"'']+)')
        $descM = [regex]::Match($fmText, '(?s)description:\s*[>|]?\s*["'']?(.*?)(?=\n[A-Za-z_-]+:|\z)')
        $desc = if ($descM.Success) { ($descM.Groups[1].Value -replace '\s+', ' ').Trim().Trim('"', "'") } else { '' }
        if ($desc.Length -gt 160) { $desc = $desc.Substring(0, 160).TrimEnd() + '...' }
        $upstreamSkillIndex += [pscustomobject]@{
            rel  = "$containerRel/$($_.Name)"
            name = if ($nameM.Success) { $nameM.Groups[1].Value.Trim() } else { $_.Name }
            desc = $desc
            nameHay = ("$($_.Name) " + $(if ($nameM.Success) { $nameM.Groups[1].Value } else { '' })).ToLowerInvariant()
            descHay = $desc.ToLowerInvariant()
        }
    }
}
if ($upstreamSkillIndex.Count -gt 0) { Write-Host "  Indexed $($upstreamSkillIndex.Count) upstream skills for keyword mapping." -ForegroundColor DarkGray }

function Get-AutoDiscoveredSkills {
    param([string]$AgentId, [string[]]$AlreadyPinned, [int]$Max = 6, [int]$MinScore = 2)
    if (-not $agentSkillKeywords.ContainsKey($AgentId) -or $upstreamSkillIndex.Count -eq 0) { return @() }
    $hits = @()
    foreach ($skill in $upstreamSkillIndex) {
        if ($AlreadyPinned -contains $skill.rel) { continue }
        $matched = @(); $score = 0
        foreach ($kw in $agentSkillKeywords[$AgentId]) {
            $k = $kw.ToLowerInvariant().Trim()
            # Prefix match on word boundary (so 'dataflows' also matches 'dataflows-authoring-cli').
            $pattern = '(?<![a-z0-9])' + [regex]::Escape($k)
            # A hit in the skill NAME is strong evidence (2); a description-only hit is weak (1).
            if ($skill.nameHay -match $pattern) { $score += 2; $matched += $kw }
            elseif ($skill.descHay -match $pattern) { $score += 1; $matched += $kw }
        }
        if ($score -ge $MinScore) { $hits += [pscustomobject]@{ skill = $skill; score = $score; matched = $matched } }
    }
    return @($hits | Sort-Object -Property @{Expression='score';Descending=$true}, @{Expression={$_.skill.rel};Descending=$false} | Select-Object -First $Max)
}

function Resolve-KnowledgeRef {
    param([string]$Rel)
    # Installer-managed files are written in this same run (some after the agents), so treat them as present.
    if (($Rel -like '.github/agent-docs/*' -and $Rel -notlike '*/local/*') -or $Rel -like '.github/skills/*') { return "$bt$Rel$bt" }
    if ($Rel -like '*/local/*') { return "$bt$Rel$bt *(optional, machine-specific; skip if absent)*" }
    $full = Join-Path $rootPath ($Rel -replace '/', '\')
    if (Test-Path -LiteralPath $full) { return "$bt$Rel$bt" }
    # Self-heal upstream renames (e.g. spark-authoring-cli -> spark-cli): look for a sibling
    # sharing the first two hyphen tokens (or the first when the name has only one); a unique
    # hit is offered as the closest sibling, clearly labelled so the agent verifies before use.
    $leaf = Split-Path $Rel -Leaf
    $parentRel = ($Rel -replace '/[^/]+$', '')
    $parentFull = Join-Path $rootPath ($parentRel -replace '/', '\')
    if (Test-Path -LiteralPath $parentFull) {
        $tokens = $leaf -split '-'
        $stems = @()
        if ($tokens.Count -ge 2) { $stems += ($tokens[0..1] -join '-') }
        $stems += $tokens[0]
        foreach ($stem in $stems) {
            $candidates = @(Get-ChildItem -LiteralPath $parentFull -Directory -ErrorAction SilentlyContinue |
                Where-Object { ($_.Name -eq $stem -or $_.Name -like "$stem-*") -and (Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md')) })
            if ($candidates.Count -eq 1) {
                return "$bt$parentRel/$($candidates[0].Name)$bt *(upstream no longer has $bt$leaf$bt; closest sibling resolved at install time - confirm it covers the topic before relying on it)*"
            }
            if ($candidates.Count -gt 1) { break }
        }
    }
    return "$bt$Rel$bt *(not present at install time - re-discover by keyword $bt$leaf$bt)*"
}

function New-KnowledgeSection {
    param($Agent, $Knowledge)
    if (-not $Knowledge) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Knowledge and skills')
    [void]$sb.AppendLine('')
    $artifacts = @($Agent.artifactTypes) | Where-Object { $_ }
    if ($artifacts.Count -gt 0) { [void]$sb.AppendLine("Artifacts you own: $($artifacts -join ', ').") }
    $writePerm = if ($Agent.writePermissions) { [string]$Agent.writePermissions }
        elseif (@($Agent.tools) -contains 'edit') { 'edit files inside your owned artifact paths' }
        elseif (@($Agent.tools) -contains 'execute') { 'run commands/CLI; no file edits' }
        else { 'read-only (analysis, plans, reports)' }
    [void]$sb.AppendLine("Write permission: $writePerm.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Read these before acting (custom skills win on style, upstream skills win on syntax/spec):')
    foreach ($s in @($Knowledge.skills)) { [void]$sb.AppendLine("- $(Resolve-KnowledgeRef $s.ref) - $($s.why)") }
    $pinned = @(@($Knowledge.skills) | ForEach-Object { [string]$_.ref })
    $auto = @(Get-AutoDiscoveredSkills -AgentId $Agent.id -AlreadyPinned $pinned)
    if ($auto.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Also relevant - auto-discovered from the upstream skill catalog at install time (re-running the installer refreshes this list):')
        foreach ($h in $auto) {
            $descText = if ($h.skill.desc) { " - $($h.skill.desc)" } else { '' }
            [void]$sb.AppendLine("- $bt$($h.skill.rel)$bt$descText *(matched: $($h.matched -join ', '))*")
        }
    }
    if ($Knowledge.playbook) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('## Playbook'); [void]$sb.AppendLine('')
        $i = 0; foreach ($p in @($Knowledge.playbook)) { $i++; [void]$sb.AppendLine("$i. $p") }
    }
    if ($Knowledge.validate) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('## Validation you must run before reporting'); [void]$sb.AppendLine('')
        foreach ($v in @($Knowledge.validate)) { [void]$sb.AppendLine("- $v") }
    }
    if ($Knowledge.tools) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('## Tool ladder'); [void]$sb.AppendLine('')
        foreach ($t in @($Knowledge.tools)) { [void]$sb.AppendLine("- $t") }
        [void]$sb.AppendLine("- Check $bt.github/agent-docs/tool-status.json$bt first; use the recorded $bt" + 'path' + "$bt; if a tool is missing, use the next rung and say so in your result.")
    }
    if ($Knowledge.avoid) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('## Avoid'); [void]$sb.AppendLine('')
        foreach ($a in @($Knowledge.avoid)) { [void]$sb.AppendLine("- $a") }
    }
    return $sb.ToString().TrimEnd()
}

function New-TeamRoster {
    param($Lead)
    $children = @($Lead.allowedChildren) | Where-Object { $agentByDisplayName.ContainsKey($_) }
    if ($children.Count -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Your team (one owner per artifact)')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Worker | Owns | Tools |')
    [void]$sb.AppendLine('|---|---|---|')
    foreach ($name in $children) {
        $w = $agentByDisplayName[$name]
        $owns = @($w.artifactTypes) | Where-Object { $_ }
        $ownsText = if ($owns.Count -gt 0) { $owns -join ', ' } else { [string]$w.focus }
        $wt = @($w.tools) | Where-Object { $_ }
        [void]$sb.AppendLine("| $($displayLabelById[$w.id]) | $ownsText | $($wt -join ', ') |")
    }
    return $sb.ToString().TrimEnd()
}

foreach ($agent in $orderedAgents) {
    $displayLabel = $displayLabelById[$agent.id]
    $safeDisplayLabel = $displayLabel.Replace("'", "''")
    $safeDescription = ([string]$agent.focus).Replace("'", "''")

    $toolNames = @($agent.tools | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($toolNames.Count -eq 0) { $toolNames = @($agentManifest.defaults.tools) }
    if ($mcpServersById.ContainsKey($agent.id)) {
        foreach ($mcpServerName in $mcpServersById[$agent.id]) {
            $mcpWildcard = "$mcpServerName/*"
            if ($toolNames -notcontains $mcpWildcard) { $toolNames += $mcpWildcard }
        }
    }
    $toolYaml = ConvertTo-AgentYamlList $toolNames

    $childLabels = @()
    foreach ($childName in @($agent.allowedChildren)) {
        if ($agentByDisplayName.ContainsKey($childName)) {
            $childAgent = $agentByDisplayName[$childName]
            $childLabels += $displayLabelById[$childAgent.id]
        }
    }

    # Strict hierarchy: each agent may dispatch only its declared children.
    # (Nested dispatch works because the installer enables
    # chat.subagents.allowInvocationsFromSubagents in the workspace settings.)
    $childrenYaml = ConvertTo-AgentYamlList $childLabels
    $userInvocable = if ($agent.level -eq 'worker') { 'false' } else { 'true' }

    # Capability maintenance needs interactive install approvals, so it is the one
    # legitimate "switch agent" case; expose it as a handoff button on the Master only.
    # List-valued keys must stay LAST in the frontmatter (VS Code parser quirk).
    $handoffsYaml = ''
    if ($agent.id -eq 'fabric-workspace-master') {
        $maintenanceLabel = $displayLabelById['capability-maintenance-team-lead']
        if ($maintenanceLabel) {
            $handoffsYaml = @"

handoffs:
  - label: 'Run capability maintenance'
    agent: '$($maintenanceLabel.Replace("'", "''"))'
    prompt: 'Run light maintenance: refresh the two upstream skill repositories and the tool inventory, then report what changed.'
    send: false
"@
        }
    }

    # Tier-specific guidance: the Master runs the startup flow; Leads use the
    # working-flow reference only; Workers get everything they need in the work order.
    $flowBullet = if ($agent.id -eq 'fabric-workspace-master') {
        '- Follow `.github/copilot-instructions.md`, then `.github/agent-docs/starting-flow.md` (once per session) and `.github/agent-docs/working-flow-reference.md`.'
    } else {
        switch ($agent.level) {
            'executive' { '- Follow `.github/copilot-instructions.md` and `.github/agent-docs/working-flow-reference.md`. Do NOT run the session startup flow: it belongs to the Master. You are normally dispatched by the Master and then cannot ask the user; return open questions and approvals in your report. If the user selected you directly, you may ask them.' }
            'team-lead' { '- Follow `.github/copilot-instructions.md` and `.github/agent-docs/working-flow-reference.md`. Do NOT run the session startup flow: it belongs to the Master. When selected directly by the user you act as the entry point for your department and may ask the user questions; when dispatched by the Master you cannot ask the user, so return open questions in your report.' }
            default     { '- Follow `.github/copilot-instructions.md`. Your WORK ORDER from the Team Lead is your complete brief; do not re-run startup or re-read the flow documents. You cannot ask the user questions: if something is missing or needs approval, return it in your WORK RESULT.' }
        }
    }

    # Workers never delegate and never talk to the user, so they get the lean contract.
    $isWorker = ($agent.level -eq 'worker')
    $contractBullets = New-Object System.Collections.Generic.List[string]
    $contractBullets.Add($flowBullet)
    $contractBullets.Add('- Inspect the current files, branch, workspace, and environment before changing anything.')
    if ($isWorker) {
        $contractBullets.Add('- Read the skills listed in your Knowledge section (and their references) before authoring. Custom skills win on style; upstream skills win on syntax/spec. If a listed skill is missing, re-discover it by keyword under the cloned repos.')
        $contractBullets.Add('- Use `.github/agent-docs/tool-status.json` for tool availability; call the recorded `path`; if a tool is missing, take the next rung of your tool ladder and say so.')
    } else {
        $contractBullets.Add('- Skills are registered natively (custom `.github/skills`, Microsoft `skills-for-fabric`, Kurt `power-bi-agentic-development`): use the skills list you were given and read the relevant SKILL.md (and its references) before authoring. Only if a skill is missing from the list, re-discover it by keyword under the cloned repos. On style conflicts the custom skill wins; on syntax/spec correctness the upstream skill wins.')
        $contractBullets.Add('- Use `.github/agent-docs/tool-status.json` to understand available command-line and live tools. When an entry has a `path`, invoke that exact executable so an older same-named system copy cannot take precedence. If a needed tool is marked missing, do one optional live re-check, then fall back to the documented alternative rather than failing; route any install/update need to the Capability Maintenance team.')
    }
    $contractBullets.Add('- Work only in the artifact paths assigned to you. Never edit downloaded vendor skill repositories.')
    $contractBullets.Add('- Validate every mutation and return concise evidence, risks, and any remaining action.')
    $contractBullets.Add('- Never expose secrets. Treat PROD as read-only unless the user explicitly approves a production change.')
    $hasModelingMcp = ($toolNames -contains 'powerbi-modeling-mcp/*')
    if ($isWorker) {
        $contractBullets.Add('- Destructive, irreversible, security-sensitive, release, PROD and environment-changing actions need an explicit approval token in your WORK ORDER (`approvals granted: <token>`). Deleting or dropping any artifact, table, column, measure, relationship, role, item, branch or file counts as destructive even when the user asked for it in plain words - the user''s phrasing is NOT the token. Without the token: stop, change nothing, return `NEEDS APPROVAL` with the exact action and a proposed token such as `APPROVED:DELETE:<artifact>`.')
        $contractBullets.Add('- Bound every live call with a timeout; on breach switch transport (e.g. Modeling MCP -> REST -> local files) instead of looping. Network blocks are machine-specific - report the failing channel, never assume it is blocked everywhere.')
        if ($hasModelingMcp) { $contractBullets.Add('- Live semantic models: use the `mcp connection: <name>` from your WORK ORDER `context` as `connectionName` on every Power BI modeling MCP call (rung 1). If `context` says `mcp connection: none`, go straight to the REST fallback. Never open a connection yourself - you cannot answer its sign-in prompt.') }
    } else {
        $contractBullets.Add('- Destructive, irreversible, security-sensitive, release, PROD and environment-changing actions need explicit user approval captured as a literal token (e.g. `APPROVED:DELETE:<artifact>`). Deleting/dropping any artifact, table, column, measure, relationship, role, item, branch or file is destructive even when the user asked for it in plain words: the request itself is not the approval. Only the top-level agent (the one the user selected) can ask the user - it confirms once ("This deletes X and Y; reply APPROVED:DELETE:... to proceed"), then puts the token in `approvals granted`. Every dispatched agent without the token must return `NEEDS APPROVAL` with the exact action and let it bubble up.')
        $contractBullets.Add('- **Dispatch health.** If the `agent` tool is missing when you must delegate, or a Lead comes back empty twice, the window was opened without `chat.subagents.allowInvocationsFromSubagents: true` in effect. The setting is WINDOW-scoped: the installer offers to write it into the USER settings (reaches every window) and always writes it into `.vscode/settings.json` and its generated `.code-workspace`; a window opened from a *user-saved* `.code-workspace` ignores `settings.json` entirely, so without the user-level setting that file must carry it. The status script''s CONFIG block says which scope is in effect (`enabled at user level` / `enabled in .vscode/settings.json only` / `NOT set`) and names any saved file that lacks it (`WARNING: saved workspace file(s) ... LACK the nested-dispatch setting`) - quote that and the fix (re-run the installer and answer Y to the user-settings prompt, or add the line to that file''s `settings` block, then reload) instead of guessing; never claim `settings.json` lacks the setting without reading it. Do not improvise the work yourself. Retry-safe failures: transport errors (`ERR_HTTP2_SERVER_REFUSED_STREAM`, dropped streams) and `Requested agent ''<name>'' not found` with an exact frontmatter name (agent-list reload / tool-budget flake) - pause briefly and retry up to 3 times, never substitute a different agent. A child that returns empty or without a WORK RESULT block is re-dispatched ONCE with `context: your previous turn ended without a WORK RESULT; resume and end with the WORK RESULT block` before you conclude anything.')
        $contractBullets.Add('- **Retries must not repeat writes.** A retry is blind only when the failure happened before the child could act (agent not found, stream refused at dispatch). If a write-capable dispatch drops mid-turn or returns without a block, the child may already have created, edited or deployed something: re-dispatch it with `context: your previous attempt may have partially completed - inspect the current state of <artifact> first and do not repeat operations that are already done`, and require the WORK RESULT to list what it found already in place.')
        $contractBullets.Add('- **Parallel dispatch.** Dispatch children in parallel only when their artifacts are independent AND at most one of them needs the terminal; otherwise sequence them (the shell is shared - two agents running commands at once interleave and wedge it). Every child that runs commands must use unique file names (`scripts/<agent>-<purpose>-<yyyyMMdd-HHmmss>.ps1`, matching `.out.txt`) so one agent never overwrites another''s output.')
        if ($hasModelingMcp) { $contractBullets.Add('- **Live semantic models go through the connection the Master opened.** When the WORK ORDER `context` carries `mcp connection: <name>`, pass that `connectionName` on every Power BI modeling MCP call and treat MCP as rung 1; an empty `ListConnections` is not proof of failure. When `context` says `mcp connection: none`, use the REST fallback without probing. Never try to open a connection yourself when dispatched - you cannot answer its sign-in prompt.') }
        $contractBullets.Add('- **Bound every live call; switch transport on breach.** Put a sensible timeout on each live MCP/XMLA/dispatch call. If it hangs or breaches the timeout, abort and switch transport (e.g. drop from Modeling MCP/XMLA to TMDL `getDefinition` or REST) rather than looping on the wedged channel. Network blocks are machine-specific: never assume a failing channel (e.g. SQL/TDS 1433) is blocked everywhere or implies other channels are blocked; use the fallback ladder in `fabric-cli-policy`.')
    }
    if ($toolNames -contains 'execute') {
        if ($toolNames -contains 'edit') {
            $contractBullets.Add('- **Terminal hygiene.** Run ONE simple command per terminal call, synchronously, and read the output it returns; never run commands while another agent may be using the shell (your parent sequences terminal work). Anything with loops, here-strings, `$`-variables or more than two statements goes into `scripts/<agent>-<purpose>-<yyyyMMdd-HHmmss>.ps1` (unique name, never reused) and runs as `powershell -NoProfile -ExecutionPolicy Bypass -File <that file> > <same name>.out.txt 2>&1`; then read the file. `scripts/` is scratch, not a deliverable. No output where output was expected is NOT proof the shell is wedged - re-run once with `| Out-String`; only when built-in cmdlets report "not recognized" is it wedged: then run the command as a child process (`powershell -NoProfile -ExecutionPolicy Bypass -File ...`) or open a fresh terminal if your tooling offers one.')
        } else {
            $contractBullets.Add('- **Terminal hygiene (execute without edit).** You cannot create files, so keep every terminal call to ONE simple statement (a single pipeline with `|` is fine; no loops, here-strings, `$`-variable juggling or multi-statement chains), run it synchronously and read the returned output. Never run commands while another agent may be using the shell. Prefer scripts that already exist (vendor skill `scripts/`, `.github/agent-docs/Get-SessionStatus.ps1`). If a task genuinely needs a multi-step script, hand it to an edit-capable worker (dispatch one if you can delegate; otherwise return `NEEDS INPUT` naming the edit-capable worker who should write it) - do not improvise with inline one-liners. No output is NOT proof the shell is wedged - re-run once with `| Out-String`; only "not recognized" for built-in cmdlets means wedged: then run via `powershell -NoProfile -ExecutionPolicy Bypass -Command "<one statement>"` as a child process.')
        }
    }
    $operatingContract = ($contractBullets -join "`n")

    $agentBody = @"
---
name: '$safeDisplayLabel'
description: '$safeDescription'
user-invocable: $userInvocable
disable-model-invocation: false
tools: $toolYaml
agents: $childrenYaml$handoffsYaml
---

# $($agent.displayName)

$($agent.focus)

## Operating contract

$operatingContract
"@

    if ($agent.id -eq 'fabric-workspace-master') {
        $agentBody += @"

## Mandatory startup and routing

On the first message of a session, read ``.github/copilot-instructions.md``, then follow ``.github/agent-docs/starting-flow.md``: one status-script call, one compact status block, then straight to the user's request. If the opening message already contains work, keep it and act on it right after the status block. Never block the user behind menus. For all subsequent messages use ``.github/agent-docs/working-flow-reference.md``. If a mandatory read fails, retry once; if tools still fail, say so plainly instead of pretending startup completed.

## Your role: coordinator, not implementer

You are the account manager for this workspace. The user is your client and the seven Team Leads are your departments. Every request the user gives you is a *project* you deliver **through the specialist teams**, never by doing the specialist work yourself. Your job is to understand the request, route it across the organisation, keep ownership clear, and consolidate one result back to the client. Treat "you fix it", "you do it", or "handle it" as "make the right team fix it and own the outcome" — the client is authorising the *result*, not asking you personally to touch the artifact.

You do **not** implement domain work yourself. You must delegate, and you must never directly author, edit, refactor, mutate, deploy, publish, run, or refresh any Fabric or Power BI artifact or its live state — this includes semantic models/TMDL/DAX, reports/PBIR, dataflows, pipelines, notebooks, lakehouse/warehouse/SQL objects, workspace/capacity/governance settings, Git/release actions, and application/REST/XMLA/CLI integrations. The specialist **worker** that owns that artifact type performs the change because it holds the right skills; its **Team Lead** reviews and validates it. This holds even when the user tells you to do it directly and even when you already know the fix: knowing the answer is not a reason to bypass the team. The only things you do hands-on are orchestration, reading/searching just enough to classify and route, running the mandatory startup checks, and consolidating evidence.

For every request: (1) classify the intent and which artifact(s) and team(s) it touches; (2) route to the minimum relevant Team Lead(s) with the ``agent`` tool, stating the goal, scope, the owned artifact, any constraints, and the validation you expect back; (3) let each Team Lead assign the skilled worker to implement and then review/validate the change **as a team** before returning; (4) consolidate the returned evidence, risks, and remaining actions into one clear answer for the client. If a request would tempt you to open a terminal or edit a file to change a domain artifact, stop and delegate instead — even for a "quick" or "obvious" change.

Use Fabric Solution Architect only for genuine cross-domain design, dependency, sequencing, ownership, validation, or rollback decisions. Use Integration QA & Change Controller for cross-artifact risk or final acceptance. Keep exactly one writer per artifact, never let a change land without its owning team's review, and confirm destructive, irreversible, production, release, or environment-changing actions with the client before the team executes them.

## You are the only voice to the client

Dispatched agents (Leads, workers, Architect, QA) cannot ask the user anything. Whatever they need from the client comes back to you as ``NEEDS APPROVAL`` or ``NEEDS INPUT`` in their result. You ask the client, then re-dispatch the same Team Lead with the answer included in the work order (for approvals, include the literal approval token the worker asked for). Never grant an approval on the client's behalf.

**Confirm destructive requests up front.** If the client's request itself deletes, drops, overwrites, resets, force-pushes, publishes to PROD or changes security/environment, do not dispatch yet: state in one or two lines exactly what will be destroyed or changed (including likely collateral, e.g. a relationship that references a deleted table) and ask the client to reply with the literal token ``APPROVED:<ACTION>:<artifact>``. Only then dispatch, with that token in ``approvals granted``. "Do it now" or "you are authorised" in plain words is not a token. When you are running as a subagent yourself and cannot ask, return ``NEEDS APPROVAL`` with the proposed token instead of proceeding.

## The three loops you run

1. **Simple (one team, one artifact):** Master -> Team Lead -> worker -> Lead validates -> Master consolidates -> client. No Architect, no QA.
2. **Designed (cross-domain or design change):** Master -> Architect (PLAN) -> Master -> Team Lead(s) in the PLAN's order (parallel where the PLAN allows) -> each Lead -> worker -> Lead validates -> Master -> QA (VERDICT) -> Master consolidates -> client. If QA rejects, re-dispatch only the owning Lead with the defects.
3. **Blocked (approval / input / design question mid-work):** worker -> Lead relays ``request`` -> Master asks the client (or dispatches the Architect for a design question) -> Master re-dispatches the SAME Lead with the answer in ``approvals granted`` / ``context`` -> Lead -> worker resumes.

Rules: pass results down as ``context`` so nobody re-discovers facts; never dispatch two Leads to write the same artifact; when the PLAN says steps are dependent, wait for the WORK RESULT before dispatching the next. Run Leads in parallel only when their artifacts are independent AND at most one of them needs the terminal - otherwise sequence them (parallel agents sharing one shell interleave commands and overwrite each other's output files).

**Live semantic models: connect before you dispatch.** Dispatched agents cannot answer sign-in prompts, so when a request needs a live model (live DAX, metadata, measure edits on a running model) YOU open the Power BI modeling MCP connection first, here in the main chat: resolve any GUIDs to exact display names (``fab api workspaces/<id>``, ``.../items/<id>``), then ``connection_operations`` -> ``ConnectFabric`` with ``workspaceName`` and ``semanticModelName``. You hold this server only for connection management and read-only checks - you never edit a model through it. Put the returned name in every WORK ORDER as ``context: mcp connection: <name>``. If it cannot connect (tool not listed, auth blocked, budget), say so in one line and send ``context: mcp connection: none - reason: <error> - use REST fallback``; Leads treat that as final. Never let a Lead discover "no connection" on its own and misread it as "MCP not callable".

**Empty or block-less returns are not results.** If a Lead comes back with no output or without a WORK RESULT block, re-dispatch the same Lead once with ``context: your previous turn ended without a WORK RESULT; resume from where you stopped and end with the WORK RESULT block``. Only if that also fails do you report the gap to the client - you never fill it by doing the work or the verification yourself.

## Session ledger

Keep a short running ledger in your own responses (not a file): request -> teams dispatched -> artifacts changed -> validation evidence -> approvals granted (tokens) -> MCP connection name (if opened) -> open items. Reuse it: a follow-up request on the same artifact goes to the same Lead with the ledger facts as ``context``, and an approval the client already gave is not asked twice in the same session.
"@
    }

    if ($childLabels.Count -gt 0) {
        $delegationNote = "You may delegate only to: $($childLabels -join '; ')."
        $agentBody += @"

## Delegation

$delegationNote Give each child a bounded artifact or validation responsibility. Avoid overlapping writes, preserve the user's request, and consolidate all returned evidence.
"@
    }
    else {
        $agentBody += @"

## Scope boundary

You are a focused worker. Do not create or invoke additional agents. Return work and evidence to your team lead.

## Refusal and escalation

Stay strictly inside your owned artifact type and your granted tools. Refuse and escalate to your Team Lead instead of improvising when a request: falls outside your artifact scope or belongs to another worker; needs a tool you were not granted (for example editing when you hold only read/search/execute, or running commands when you hold only read/search/edit); requires installing or updating software (route to Capability Maintenance); or would perform a destructive, irreversible, production, release, or environment-changing action without explicit user approval. Never widen your own scope or capabilities to complete a task -- report the blocker and the exact approval or owner required.
"@
    }

    # Per-agent specialist knowledge (skills with resolved paths, playbook, validation, tool ladder).
    $knowledgeSection = New-KnowledgeSection -Agent $agent -Knowledge $agentKnowledge[$agent.id]
    if ($knowledgeSection) { $agentBody += "`n" + $knowledgeSection + "`n" }

    if ($agent.level -eq 'team-lead') {
        $roster = New-TeamRoster -Lead $agent
        if ($roster) { $agentBody += "`n" + $roster + "`n" }
        $agentBody += @"

## How you dispatch

Send each worker exactly one WORK ORDER (format in ``.github/agent-docs/working-flow-reference.md``): goal in the user's words, the exact artifact path or live item, mode (local/live/hybrid), constraints, the validation evidence you expect back, approvals already granted (literal tokens), and the facts already established. Workers are stateless and cannot ask the user: put everything they need in the order. Independent artifacts may be dispatched in parallel; the same file or live object never goes to two workers at once.

When a worker returns ``NEEDS APPROVAL`` / ``NEEDS INPUT`` / ``NEEDS ARCHITECT`` / ``OUT OF SCOPE``, relay the ``request`` upward unchanged in your own WORK RESULT. If a worker returns empty or without a WORK RESULT block, re-dispatch it once with ``context: your previous turn ended without a WORK RESULT; resume and end with the WORK RESULT block`` - do not do its work yourself. If a design or dependency question blocks you and the Master did not provide a plan, you may dispatch **001 - Fabric Solution Architect** yourself with the precise question, then continue. Forward the Master's ``mcp connection: <name>`` (or ``none``) unchanged in every worker WORK ORDER.
"@
    }

    if ($agent.id -eq 'fabric-solution-architect') {
        $agentBody += @"

## Your output: a PLAN

``````
PLAN
summary: <one paragraph: what changes and why this sequence>
steps:
  1. team: <Team Lead> | worker: <owning worker> | artifact: <path or live item> | change: <what> | validate: <how> | rollback: <how>
  2. ...
parallel: <step numbers that may run concurrently>
risks: <grain / storage mode / breaking measures or visuals / schedules / PROD exposure>
decisions for the user: <only genuine choices, with a recommendation each>
``````

Return the PLAN to whoever dispatched you (Master or a Team Lead) **inside your WORK RESULT**: ``status: DONE`` (or ``NEEDS INPUT`` when a decision blocks planning), ``changed: none``, and the complete PLAN block verbatim in the ``payload:`` field. Never send the PLAN without the WORK RESULT wrapper, and never compress it into the other fields. Do not execute it unless the Master explicitly instructs you to run it through the Team Leads.

## Two ways you are used

- **Before work (Master -> you):** produce the PLAN. The Master runs it.
- **Mid-work (a Team Lead -> you):** answer the single design/dependency question asked, in the same PLAN step format for the affected step(s) only, and return. Do not re-plan the whole request.
- **Run mode (explicit only):** when the Master's WORK ORDER says ``run the plan``, you dispatch the Team Leads yourself in PLAN order, relay their WORK RESULTs and any ``request`` upward unchanged, and return one consolidated WORK RESULT. You still never write artifacts.
"@
    }

    if ($agent.id -eq 'integration-qa-change-controller') {
        $agentBody += @"

## Your output: a VERDICT

``````
VERDICT: ACCEPT | ACCEPT WITH RISKS | REJECT
checked: <artifact -> checks run -> evidence>
defects: <artifact | defect | severity | owning team> (or none)
environment/branch: <aligned | mismatch details>
security/privacy: <ok | findings>
remaining approvals: <or none>
``````

Return it **inside your WORK RESULT**: ``status: DONE`` for ACCEPT / ACCEPT WITH RISKS, ``status: DONE WITH RISKS`` for REJECT (the defects are the risks), ``changed: none``, and the complete VERDICT block verbatim in the ``payload:`` field. Never send the VERDICT without the wrapper and never summarise defects away.
"@
    }

    if ($agent.level -eq 'team-lead') {
        $agentBody += @"

## Team lead ownership and validation

You own the outcome for your department, but you deliver it **through your workers**. For every task: assign exactly **one** owning worker per artifact so two agents never write the same file or live object concurrently; give that worker a bounded scope; and **validate the returned work yourself** (or via your validation worker) before you report success upward. Do not sign off unreviewed worker output.

Escalate rather than exceed your remit: send genuinely cross-domain design, sequencing, or ownership questions to Fabric Solution Architect, and cross-artifact risk or final acceptance to Integration QA & Change Controller, via the Master. Obtain explicit user approval before any worker executes a destructive, irreversible, production, release, or environment-changing action, and surface unresolved risks and remaining approvals in your report instead of quietly proceeding.
"@
    }

    if ($agent.department -eq 'alm-devops') {
        $agentBody += @"

## Independent repository safety

Before GitHub, Azure DevOps, branch, PR, Fabric Git, deployment, or release work, read ``.github/agent-docs/local/repository-map.local.json`` when present. Treat every path under ``source-control-repositories/`` as an independent repository: inspect its own status, remote, active branch, mapped environment, PR requirement, and write policy. Never infer permission to switch, create, delete, reset, merge, push, or connect a live Fabric workspace from the fact that the installer cloned it.
"@
    }

    if ($agent.department -eq 'capability-maintenance') {
        $agentBody += @"

## Capability maintenance ownership

This team owns the workspace's established capability lifecycle: upstream Microsoft and Kurt repository refresh, dynamic skill inventory, agent coverage, installer health, and all supported tool detection, installation, update, PATH recovery, and validation.

Preserve the installer-first experience and its locked-down-laptop fallbacks. When setup cannot install or update a tool, diagnose the exact failure, obtain explicit approval before changing software, use the approved user-scope or portable fallback, validate the real executable, and refresh ``.github/agent-docs/tool-status.json``.

**Two kinds of repository, two rules - never mix them up:**

- **Vendor skill clones** (``skills-for-fabric``, ``power-bi-agentic-development``) are mirrors of upstream and are refreshed ONLY by **071 - Upstream Repository Sync Agent**, with the installer's exact rule: first confirm the folder is the root of its own repository (``git rev-parse --show-toplevel`` equals the folder) and that ``origin`` is the expected GitHub URL; then ``git fetch --prune origin``; if ``git status --porcelain`` shows local edits, ``git stash push -u -m "maintenance-autostash <timestamp>"`` and tell the user the stash name; then ``git reset --hard origin/HEAD`` and verify ``HEAD`` equals ``origin/HEAD``. **Stop and report instead of resetting** when: the folder is not its own repository root, ``origin`` is not the expected URL, the fetch fails (offline/blocked), or the stash fails / the tree is still dirty after it. Never push to a vendor repository and never edit its files. After a refresh, re-register skill containers (``chat.agentSkillsLocations``) if new folders appeared (the session status script also does this).
- **Business repositories** under ``source-control-repositories/`` belong to the ALM & DevOps team and are **never** stashed, reset, cleaned or overwritten by this team; a dirty or diverged one is only reported.

When selected directly, first offer:

1. **Light maintenance** — refresh the two vendor clones to live upstream (via 071, rule above), re-register skill folders, then refresh the current tool inventory.
2. **Deep maintenance** — light maintenance plus dynamic skill inventory/mapping, agent coverage review, installed-tool version review, and installer health checks.

For either level, report any repository that hits a stop condition and continue with the unaffected checks. A tool installation or update is never implied by either maintenance level: identify the exact proposed software change and obtain separate explicit approval before delegating it to Environment & Tooling Agent.
"@
    }

    if ($agent.id -eq 'environment-tooling-agent') {
        $agentBody += @"

You are the only worker authorised to perform approved software installation or updates. Every installation or update requires explicit user approval; never infer it from a request to inspect or diagnose.
"@
    }

    if ($agent.id -eq 'fabric-workspace-master') {
        $agentBody += @"

## Return contract (to the user)

One consolidated answer: what changed and where (files / live items), validation evidence per team, risks, and the decisions or approvals you still need from the user. Quote approval requests verbatim. Keep the session ledger (approvals granted, results) so follow-up requests build on it.
"@
    } else {
        $agentBody += @"

## Return contract

**Your final message must be the WORK RESULT block** (format in ``.github/agent-docs/working-flow-reference.md``). A turn that ends without it - or ends on a statement of intent such as "I'll now tighten that page" - is a ``FAILED`` result and forces your parent to re-dispatch you. Finish the step, or end with ``NEEDS INPUT`` / ``FAILED`` stating exactly what remains. Never leave evidence only inside files you wrote: summarise it in the block.

``````
WORK RESULT
status: DONE | DONE WITH RISKS | NEEDS APPROVAL | NEEDS INPUT | NEEDS ARCHITECT | OUT OF SCOPE | FAILED
changed: <files / live objects, or none>
validation: <what was run and the outcome - never claim a check you did not run>
risks: <or none>
request: <exact approval token, question, design decision, or correct owner - only when status is not DONE>
payload: <Architect: the full PLAN block | QA: the full VERDICT block | others: omit>
``````
"@
    }

    $agentFilename = $agent.filename -replace '^\d+', $threeDigitById[$agent.id]
    $agentPath = Join-Path "$rootPath\.github\agents" $agentFilename
    # Normalise: exactly one blank line before every section heading (here-string joins drop it).
    $agentBody = [regex]::Replace($agentBody, '(?<=[^\r\n])\r?\n(?=## )', "`n`n")
    Write-ManagedFile $agentPath $agentBody
    Write-Host "  Written: $agentFilename" -ForegroundColor Green
}

$visibleAgentCount = @($orderedAgents | Where-Object { $_.level -ne 'worker' }).Count
$workerAgentCount = @($orderedAgents | Where-Object { $_.level -eq 'worker' }).Count
Write-Host "`n  $($orderedAgents.Count) agents written: $visibleAgentCount numbered dropdown agents and $workerAgentCount delegated specialists." -ForegroundColor Green
Read-Host "`n  Press Enter to continue..."

# =====================================================================
# STEP 8  -- Generate configuration files
# =====================================================================
Show-Step 8 $totalSteps "Writing Configuration Files"

# -- copilot-instructions.md ------------------------------------------
$copilotInstructions = @'
# Copilot Workspace Instructions

This is a Microsoft Fabric development workspace with agentic AI support.

## Agents

The primary agent is **000 - Fabric Workspace Master**, defined in
`.github/agents/000-fabric-workspace-master.agent.md`.
Select it from the Copilot Chat agent dropdown to begin.

The master agent uses reference docs in `.github/agent-docs/` for its startup
and working flows. These files do NOT appear in the Copilot Chat dropdown:
- `starting-flow.md`  -- Lean session startup: one status-script call, one compact status block, then work
- `Get-SessionStatus.ps1`  -- The status script (skill freshness, identity, MCP installed/connected state, live tool re-check that refreshes `tool-status.json`; also writes `session-status.last.txt`)
- `working-flow-reference.md`  -- Team protocol (WORK ORDER / WORK RESULT), routing map, skills, working modes and rules
- `tool-status.json`  -- Machine-specific tool inventory (gitignored). Agents read `<tool>.found` and prefer its recorded executable `path`
  before invoking any CLI/MCP and degrade gracefully when a tool is absent. Regenerated by the
  installer and by the Capability Maintenance team.
- `local/repository-map.local.json`  -- Optional machine/company-specific GitHub/Azure DevOps
  clone, branch-topology and Fabric mapping inventory (gitignored). ALM agents read it before repository work.

The numbered dropdown remains intentionally compact. It exposes the Master, two
cross-domain reviewers, and seven Team Leads; they delegate to 37 focused workers.
Nested delegation (Master -> Lead -> Worker) requires the VS Code setting
`chat.subagents.allowInvocationsFromSubagents: true`. It is window-scoped, so the
installer offers to write it (plus workspace-relative skill locations) into your VS Code
USER settings - that reaches every window, however this folder is opened (Open Folder,
Add Folder to Workspace, any saved `.code-workspace`). It also writes it into
`.vscode/settings.json` and the generated `.code-workspace` for Open-Folder windows.
At user level the flag applies machine-wide: in another workspace whose own custom
agents delegate, they may nest too; default Copilot chat is unaffected (opt-out per
workspace: set it to `false` in that `.code-workspace`). The session status block says
which scope is in effect. Dispatched agents cannot ask the
user questions: approvals and open questions bubble up to the agent you selected.
- **001 - Fabric Solution Architect** -- cross-domain design and ownership
- **002 - Integration QA & Change Controller** -- cross-artifact acceptance
- **010 - Semantic Model Team Lead** -- TMDL, DAX, security, validation
- **020 - Reporting Team Lead** -- PBIR, themes, visuals, report QA
- **030 - Data Engineering Team Lead** -- notebooks, lakehouse, SQL, pipelines, RTI
- **040 - Fabric Administration & Governance Team Lead** -- capacity, access, governance
- **050 - ALM & DevOps Team Lead** -- Git, GitHub, Azure DevOps, Fabric ALM
- **060 - Applications & Integration Team Lead** -- Python, REST, XMLA, ODBC
- **070 - Capability Maintenance Team Lead** -- skills, agents, installer and tool lifecycle

## Skills

### Custom skills (embedded by installer  -- source of truth is the PS1)
- `.github/skills/fabric-tmdl/SKILL.md`  -- TMDL syntax, indentation, property ordering
- `.github/skills/fabric-pipelines/SKILL.md`  -- Pipeline JSON structure, activity types
- `.github/skills/fabric-cli-policy/SKILL.md`  -- CLI decision policy: prefer `fab`, `az` fallback

## CLI policy

This workspace prefers the **Fabric CLI (`fab`)** for control-plane / data-plane
work; **`az` is a documented fallback** (SQL/TDS via `sqlcmd -G`, non-Fabric token
audiences, uncovered endpoints). Neither CLI is required for the core local-editing
workflow. Before any terminal CLI or REST API task, read
`.github/skills/fabric-cli-policy/SKILL.md`.

Tool availability is gated by `.github/agent-docs/tool-status.json`. Before invoking
any CLI/MCP (`fab`, `az`, `sqlcmd`, `pbir`, Tabular Editor CLI, `pbi-tools`, `gh`,
`az devops`, or the MCP servers), read `<tool>.found`; if false, do one optional live
re-check, then use the documented fallback. Never fail a task solely because a tool is
missing. Inspect current `--help` and use the cloned skill references for command-specific
guidance.

For the two MCP servers, `found`/`extensionInstalled` only means the extension is
installed - NOT that its tools are callable or connected in the chat session. They
self-register (no mcp.json). For live semantic models the **Master** opens the Power BI
modeling connection in the main chat (`ConnectFabric`, where sign-in prompts can be
answered) and passes the connection name down in every WORK ORDER; dispatched agents
reuse it and never try to connect themselves. For Fabric MCP the owning Team Lead
makes one cheap read-only call on first live use. If either is unavailable, the
REST/CLI fallback described in `working-flow-reference.md` applies. Mind the
~128-tool chat picker budget.

### Microsoft skills (cloned repo -- registered natively in `chat.agentSkillsLocations`)
- `skills-for-fabric/skills/`  -- Spark, SQL, Eventhouse, Power BI, Medallion
- `skills-for-fabric/common/`  -- Shared references (COMMON-CLI.md, ITEM-DEFINITIONS-CORE.md)

### Data-goblin skills (cloned repo -- registered natively in `chat.agentSkillsLocations`)
- `power-bi-agentic-development/plugins/pbip/skills/`  -- TMDL, PBIR, PBIP validation
- `power-bi-agentic-development/plugins/semantic-models/skills/`  -- DAX, naming conventions
- `power-bi-agentic-development/plugins/reports/skills/`  -- Deneb, themes, visuals
- `power-bi-agentic-development/plugins/fabric-cli/skills/`  -- Fabric CLI operations
- `power-bi-agentic-development/plugins/fabric-admin/skills/`  -- Fabric admin operations

> Every skill container found at install time is registered, so agents see the full
> skill list natively. If an upstream folder is renamed later, agents re-discover the
> skill by keyword under the cloned repos instead of failing; re-running the installer
> or capability maintenance re-registers the new paths.

## Skill provenance & licensing
- **Custom skills are independent works.** `fabric-tmdl` is authored from the maintainer's
  production reports (house style); `fabric-pipelines` is derived from Microsoft sources
  (skills-for-fabric, MIT, + Fabric docs). Neither is copied or AI-rewritten from data-goblin.
- **skills-for-fabric** (Microsoft) is MIT-licensed.
- **power-bi-agentic-development** (data-goblin) is GPL-3.0. It is used ONLY as a locally
  cloned, gitignored reference that agents read at runtime - never copied or redistributed
  inside this repo or the custom skills.
- **Freshness** shown at startup uses real signals: git commit dates for cloned repos and
  on-disk modification time for custom skills (no faked dates).

## Workspace conventions
- Fabric items are synced via the Fabric VS Code extension (not managed by agents)
- Agents handle the development workflow: editing, validation, skill-guided authoring
- Independent business clones live under `source-control-repositories/`, remain separate Git repositories,
  and appear as separate roots in the local multi-root workspace
- ALM agents may operate an explicitly selected repository within its recorded branch/write policy;
  Fabric item pull/push remains handled by the Fabric extension
- Custom skills in `.github/skills/` are the installer's source of truth
'@
Write-ManagedFile "$rootPath\.github\copilot-instructions.md" $copilotInstructions
Write-Host "  Written: .github/copilot-instructions.md" -ForegroundColor Green

# -- AGENTS.md ---------------------------------------------------------
$agentsReadme = @'
# Fabric Agentic Workspace -- Agent Guide

## How to use

Open this folder any way you like - File > Open Folder, Add Folder to Workspace, or your
own saved `.code-workspace` - provided you accepted the installer's offer to enable the
agent team in your VS Code user settings (nested dispatch + workspace-relative skill
locations; both are window-scoped, so user level is the only scope that reaches every
window). If you declined, use File > Open Folder or the installer-generated workspace
file, or add `"chat.subagents.allowInvocationsFromSubagents": true` to your own
workspace file's `settings` block.
In Copilot Chat, select **000 - Fabric Workspace Master** from the agent dropdown and
describe what you need. The Master runs a one-call session status (skills freshness,
identity, live tool check), then routes your request through the teams itself - you
never need to change agent for normal work. Say *run maintenance* (or use the handoff
button) when you want skills and tools refreshed.

You can also select an executive reviewer or Team Lead directly. Focused workers
are delegated by their leads so the dropdown stays clear.

---

## Agent architecture

| # | Dropdown agent | Focus |
|---|----------------|-------|
| 000 | **Fabric Workspace Master** | Startup, routing, orchestration, final outcome |
| 001 | **Fabric Solution Architect** | Cross-domain design, dependencies, ownership, rollback |
| 002 | **Integration QA & Change Controller** | Cross-artifact checks and final acceptance |
| 010 | **Semantic Model Team Lead** | TMDL, DAX, relationships, security, validation |
| 020 | **Reporting Team Lead** | PBIR, UX, themes, visuals, report QA |
| 030 | **Data Engineering Team Lead** | Spark, lakehouse, SQL, dataflows, pipelines, RTI |
| 040 | **Fabric Administration & Governance Team Lead** | Workspaces, capacity, access, governance, operations |
| 050 | **ALM & DevOps Team Lead** | Git, GitHub, Azure DevOps, Fabric Git and releases |
| 060 | **Applications & Integration Team Lead** | Python, SDK, REST, XMLA, ODBC and data access |
| 070 | **Capability Maintenance Team Lead** | Skills, agents, tools, installer health and recovery |

The seven Team Leads delegate to 37 numbered worker agents. Each worker owns a
bounded artifact type or maintenance responsibility and reports evidence back to
its lead. The Master keeps one writer per artifact and consolidates the result.

Reference docs in `.github/agent-docs/` do not appear in the dropdown.

---

## Source-control layout

- The installation root is the outer **Fabric Agentic Workspace** Git repository.
- Local Fabric workspace folders hold definitions pulled through the Fabric extension.
- Optional GitHub/Azure DevOps business clones live under `source-control-repositories/`.
  Each is independent, ignored by the outer repository, and opened as a separate
  root/Source Control provider through `Fabric-Agentic-Workspace.code-workspace`.
- Machine/company-specific repository and branch mappings are stored in the
  gitignored `.github/agent-docs/local/repository-map.local.json`.

Before repository or ALM work, select **050 - ALM & DevOps Team Lead** and verify
the mapped repository, active branch, status, remote, environment and write policy.

---

## Skills sources

| Source | Location | Updated |
|--------|----------|---------|
| Custom (TMDL, Pipelines, CLI policy) | `.github/skills/` | Re-run installer |
| Microsoft skills-for-fabric | `skills-for-fabric/` | Offered on session start / via Capability Maintenance |
| Kurt/data-goblin plugins | `power-bi-agentic-development/` | Offered on session start / via Capability Maintenance |
'@
Write-ManagedFile "$rootPath\AGENTS.md" $agentsReadme
Write-Host "  Written: AGENTS.md" -ForegroundColor Green

# -- .gitignore --------------------------------------------------------
$gitignoreContent = @'
# Cloned skill repositories (managed by Fabric Master Agent)
skills-for-fabric/
power-bi-agentic-development/

# Independent business repositories (each keeps its own .git/remotes/branches)
source-control-repositories/

# VS Code local
.vscode/
Fabric-Agentic-Workspace.code-workspace

# OS
Thumbs.db
.DS_Store

# Fabric local cache
.pbi/
*.pbicache

# Machine-specific tool inventory (regenerated by the installer each run)
.github/agent-docs/tool-status.json

# Per-session status snapshot written by Get-SessionStatus.ps1
.github/agent-docs/session-status.last.txt

# Machine-specific self-test / guardrail report (regenerated by the installer each run)
.github/agent-docs/guardrail-status.json

# Machine-specific integrity manifest (regenerated by the installer each run)
.github/agent-docs/installed-manifest.json

# Machine/company-specific Fabric and repository mappings
.github/agent-docs/local/
'@
$gitignorePath = "$rootPath\.gitignore"
# Only write the full template if it does not exist  -- user may have customised it
if (-not (Test-Path $gitignorePath)) {
    Write-ManagedFile $gitignorePath $gitignoreContent
    Write-Host "  Written: .gitignore" -ForegroundColor Green
} else {
    Write-Host "  .gitignore already exists  -- preserving its content" -ForegroundColor Yellow
    Add-GitIgnoreRules -Path $gitignorePath -Heading 'Cloned skill repositories' `
        -Rules @('skills-for-fabric/', 'power-bi-agentic-development/')
    Add-GitIgnoreRules -Path $gitignorePath -Heading 'Independent business repositories and local workspace metadata' `
        -Rules @('source-control-repositories/', $workspaceFileName, '.github/agent-docs/local/')
    Add-GitIgnoreRules -Path $gitignorePath -Heading 'VS Code local' -Rules @('.vscode/')
    Add-GitIgnoreRules -Path $gitignorePath -Heading 'Operating-system files' -Rules @('Thumbs.db', '.DS_Store')
    Add-GitIgnoreRules -Path $gitignorePath -Heading 'Fabric local cache' -Rules @('.pbi/', '*.pbicache')
    Add-GitIgnoreRules -Path $gitignorePath -Heading 'Machine-specific tool inventory' `
        -Rules @('.github/agent-docs/tool-status.json', '.github/agent-docs/session-status.last.txt')
    Add-GitIgnoreRules -Path $gitignorePath -Heading 'Machine-specific self-test / guardrail report' `
        -Rules @('.github/agent-docs/guardrail-status.json')
    Add-GitIgnoreRules -Path $gitignorePath -Heading 'Machine-specific integrity manifest' `
        -Rules @('.github/agent-docs/installed-manifest.json')
    Write-Host '  .gitignore: required installer safety rules confirmed' -ForegroundColor Green
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

# -- .vscode/settings.json (merge -- preserves user customisations) -----
# Register every skill container so agents see Microsoft + Kurt + custom skills
# natively (no per-hop directory hunting). skills-for-fabric/plugins is a grouped
# duplicate of skills-for-fabric/skills, so only the canonical folder is registered.
$skillLocations = @{ ".github/skills" = $true }
$discoveredSkillDirs = @(Get-SkillContainerDirs -RootPath $rootPath -SearchSubPaths @('skills-for-fabric\skills', 'power-bi-agentic-development\plugins'))
foreach ($skillDir in $discoveredSkillDirs) { $skillLocations[$skillDir] = $true }
foreach ($synapseDir in @(Get-SynapseSkillDirs)) { $skillLocations[$synapseDir] = $true }
Write-Host "  Skill locations registered: $($skillLocations.Count) ($($discoveredSkillDirs.Count) from cloned repos)" -ForegroundColor DarkGray

$requiredSettings = @{
    "task.allowAutomaticTasks" = "on"
    # Window-scoped; also forced in the .code-workspace. Required for Lead -> Worker dispatch.
    "chat.subagents.allowInvocationsFromSubagents" = $true
    "chat.agentSkillsLocations" = $skillLocations
    "git.ignoreLimitWarning" = $true
    "git.autoRepositoryDetection" = "subFolders"
    "git.repositoryScanMaxDepth" = 4
    "git.repositoryScanIgnoredFolders" = @('skills-for-fabric', 'power-bi-agentic-development')
    "search.exclude" = @{
        "skills-for-fabric/" = $true
        "power-bi-agentic-development/" = $true
    }
}
$settingsPath = "$rootPath\.vscode\settings.json"
$existed = Test-Path $settingsPath
Merge-JsonSettings $settingsPath $requiredSettings
Write-Host "  $(if ($existed) {'Merged'} else {'Written'}): .vscode/settings.json" -ForegroundColor Green

# -- USER-level enablement (reaches every VS Code window) ---------------------
# Both settings below are WINDOW-scoped. A window opened from any .code-workspace
# file (saved, or the untitled one VS Code creates on "Add Folder to Workspace")
# ignores the folder's .vscode/settings.json for them, so the only scope that works
# however the user opens this folder is the USER settings.json. The skill locations
# are written as WORKSPACE-RELATIVE paths: VS Code resolves them against the open
# workspace folders, so they activate only in windows that contain this workspace.
$userLevelEnabled = $false
if (-not $EmitAgentsTo) {
    $relativeSkillLocs = @($skillLocations.Keys | Where-Object { $_ -notmatch '^~[\\/]' -and -not [IO.Path]::IsPathRooted($_) })
    $userSettingsPath = Get-VsCodeUserSettingsPath
    Write-Host ""
    Write-Host "  AGENT TEAM IN EVERY VS CODE WINDOW (recommended)" -ForegroundColor Cyan
    Write-Host "  The two settings that make the team work are window-scoped: VS Code ignores" -ForegroundColor DarkGray
    Write-Host "  .vscode/settings.json for them whenever a window is opened from a .code-workspace" -ForegroundColor DarkGray
    Write-Host "  file - including the untitled one created by 'Add Folder to Workspace'. Adding" -ForegroundColor DarkGray
    Write-Host "  them to your VS Code USER settings makes this folder work however you open it:" -ForegroundColor DarkGray
    Write-Host "    - chat.subagents.allowInvocationsFromSubagents = true" -ForegroundColor DarkGray
    Write-Host "      Lets a custom agent that is itself running as a sub-agent dispatch further" -ForegroundColor DarkGray
    Write-Host "      sub-agents (Master -> Team Lead -> Worker). Applies to EVERY window on this" -ForegroundColor DarkGray
    Write-Host "      machine: in another workspace whose own custom agents delegate, they may now" -ForegroundColor DarkGray
    Write-Host "      nest too. Default Copilot chat and agents that never delegate are unaffected." -ForegroundColor DarkGray
    Write-Host "      Opt-out for one workspace: set it to false in that .code-workspace file." -ForegroundColor DarkGray
    Write-Host "    - chat.agentSkillsLocations += $($relativeSkillLocs.Count) workspace-relative folders" -ForegroundColor DarkGray
    Write-Host "      Resolved against the open workspace folders, so the Fabric skills appear only" -ForegroundColor DarkGray
    Write-Host "      in windows that contain this workspace - never in unrelated projects." -ForegroundColor DarkGray
    Write-Host "  Edited in place (your other settings, comments and formatting are kept):" -ForegroundColor DarkGray
    Write-Host "    $userSettingsPath" -ForegroundColor DarkGray
    $userAns = Read-Host '  Enable the agent team in your VS Code user settings now? (Y/n)'
    if ($userAns -notmatch '^\s*(n|no)\s*$') {
        try {
            $ur = Update-UserSettingsInPlace -Path $userSettingsPath -SkillLocations $relativeSkillLocs
            $userLevelEnabled = $true
            if ($ur.Changed) {
                $what = @()
                if ($ur.FlagAdded) { $what += 'nested dispatch enabled' }
                if ($ur.LocationsAdded.Count -gt 0) { $what += "$($ur.LocationsAdded.Count) skill location(s) added" }
                Write-Host "  Updated user settings: $($what -join '; ')." -ForegroundColor Green
            } else {
                Write-Host "  User settings already up to date." -ForegroundColor DarkGray
            }
            $profileFiles = @(Get-VsCodeProfileSettingsPaths)
            if ($profileFiles.Count -gt 0) {
                Write-Host "  Note: you use VS Code Profiles. A profile has its own settings file; if you open this" -ForegroundColor Yellow
                Write-Host "  workspace under a profile, add the same two settings there:" -ForegroundColor Yellow
                $profileFiles | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
            }
        } catch {
            Write-Host "  Could not update user settings ($($_.Exception.Message))." -ForegroundColor Yellow
            Write-Host "  Add `"chat.subagents.allowInvocationsFromSubagents`": true to that file by hand, or open the folder with File > Open Folder." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Skipped. The team works in windows opened with File > Open Folder or from the installer's" -ForegroundColor DarkGray
        Write-Host "  workspace file; your own saved workspace files are checked below." -ForegroundColor DarkGray
    }
}

# -- Fallback: user-saved .code-workspace files that open this folder ----------
# Only when user-level enablement was declined: patch the saved files VS Code has
# opened before. Only missing entries are added, so a re-run after patching lists nothing.
if (-not $EmitAgentsTo -and -not $userLevelEnabled) {
    $requiredSkillLocs = @($skillLocations.Keys | ForEach-Object {
        if ($_ -match '^~[\\/]' -or [IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $rootPath ($_ -replace '/', '\') }
    })
    $userWsFiles = @(Get-UserWorkspaceFilesForRoot -RootPath $rootPath -RequiredSkillLocations $requiredSkillLocs |
        Where-Object { -not $_.NestedDispatch -or $_.MissingSkillLocations.Count -gt 0 })
    if ($userWsFiles.Count -gt 0) {
        Write-Host ""
        Write-Host "  Saved VS Code workspace file(s) that open this folder are out of date" -ForegroundColor Yellow
        Write-Host "  (opened from one, VS Code ignores .vscode/settings.json):" -ForegroundColor Yellow
        foreach ($uw in $userWsFiles) {
            $why = @()
            if (-not $uw.NestedDispatch) { $why += 'nested-dispatch setting missing (Team Leads cannot dispatch workers)' }
            if ($uw.MissingSkillLocations.Count -gt 0) { $why += "$($uw.MissingSkillLocations.Count) skill location(s) missing" }
            Write-Host "    $($uw.Path)" -ForegroundColor Yellow
            Write-Host "      $($why -join '; ')" -ForegroundColor DarkGray
        }
        $patchAns = Read-Host '  Update their settings block (adds only what is missing)? (Y/n)'
        if ($patchAns -notmatch '^\s*(n|no)\s*$') {
            foreach ($uw in $userWsFiles) {
                try {
                    $hadComments = Update-UserWorkspaceFile -Path $uw.Path -SkillLocations $uw.MissingSkillLocations
                    $note = if ($hadComments) { ' (comments in the file were not preserved)' } else { '' }
                    Write-Host "    Updated: $($uw.Path)$note" -ForegroundColor Green
                } catch {
                    Write-Host "    Could not patch $($uw.Path) -- add the settings by hand." -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host '  Skipped. Open the folder directly (File > Open Folder) or add the settings to that file by hand.' -ForegroundColor DarkGray
        }
    }
}

# -- .github/agent-docs/tool-status.json (machine-specific tool inventory) -----
# Written from the $script:ToolStatus map built during prerequisite detection.
# Agents read this to decide whether a deterministic tool is available.
$toolStatusObj = [ordered]@{
    '_meta' = [ordered]@{
        schemaVersion = 1
        generatedAt   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        generatedBy   = 'installer'
        note          = 'Machine-specific and gitignored. CLIs are invoked via execute; <key>.found gates use vs. fallback, and <key>.path is authoritative when present. Regenerate by re-running the installer or via the Capability Maintenance team.'
    }
}
foreach ($k in $script:ToolStatus.Keys) { $toolStatusObj[$k] = $script:ToolStatus[$k] }
$toolStatusJson = $toolStatusObj | ConvertTo-Json -Depth 6
Write-ManagedFile "$rootPath\.github\agent-docs\tool-status.json" $toolStatusJson
Write-Host "  Written: .github/agent-docs/tool-status.json" -ForegroundColor Green

# -- Post-generation self-test + guardrail-status.json ----------------
# Re-reads what was actually written to disk and re-derives the governance
# invariants from the embedded manifest. This is an honest advisory report:
# it verifies STRUCTURE (files, frontmatter, hierarchy, least-privilege tools)
# but does NOT claim runtime enforcement -- agent behaviour on a locked-down
# Copilot Chat build is advisory, not hook-enforced.
Write-Host "`n  Running post-generation self-test..." -ForegroundColor Cyan
$selfTestChecks = [System.Collections.Generic.List[object]]::new()
function Add-SelfTestCheck([string]$Name, [bool]$Ok, [string]$Detail) {
    $selfTestChecks.Add([ordered]@{ check = $Name; pass = $Ok; detail = $Detail }) | Out-Null
    $icon = if ($Ok) { '[+]' } else { '[x]' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host "    $icon $Name" -ForegroundColor $color
    if (-not $Ok -and $Detail) { Write-Host "        $Detail" -ForegroundColor DarkYellow }
}

$expectedAgentCount = @($agentManifest.agents).Count
$agentsDirPath = Join-Path $rootPath '.github\agents'
$writtenAgentFiles = @(Get-ChildItem -Path $agentsDirPath -Filter '*.agent.md' -File -ErrorAction SilentlyContinue)
# The real invariant is that every MANAGED agent was written -- not that the
# directory contains exactly the manifest count. A user may add their own
# `*.agent.md`; those are never in the manifest, are left untouched, and must
# NOT be reported as a failure. So we assert "all managed agents present" and
# report any extra user-authored agents separately for transparency.
$managedAgentSet = @{}; foreach ($ma in $managedAgents) { $managedAgentSet[$ma] = $true }
$writtenAgentNames = @($writtenAgentFiles | ForEach-Object { $_.Name })
$missingManagedAgents = @($managedAgents | Where-Object { $writtenAgentNames -notcontains $_ })
$extraUserAgents = @($writtenAgentNames | Where-Object { -not $managedAgentSet.ContainsKey($_) })
$agentCountDetail = "found $($writtenAgentFiles.Count) agent file(s); $($managedAgents.Count) managed present"
if ($missingManagedAgents.Count) { $agentCountDetail += "; MISSING managed: $($missingManagedAgents -join ', ')" }
if ($extraUserAgents.Count)      { $agentCountDetail += "; $($extraUserAgents.Count) user-authored agent(s) preserved: $($extraUserAgents -join ', ')" }
Add-SelfTestCheck 'All managed agents present (user agents preserved)' ($missingManagedAgents.Count -eq 0) $agentCountDetail
if ($extraUserAgents.Count) {
    Write-Host "        Note: $($extraUserAgents.Count) user-authored agent file(s) found and left untouched: $($extraUserAgents -join ', ')" -ForegroundColor DarkGray
}

$missingFrontmatter = @($writtenAgentFiles | Where-Object {
    $head = Get-Content $_.FullName -TotalCount 1 -ErrorAction SilentlyContinue
    $head -ne '---'
})
Add-SelfTestCheck 'Every agent file opens with YAML frontmatter' ($missingFrontmatter.Count -eq 0) ($missingFrontmatter | ForEach-Object { $_.Name }) -join ', '

$idSet = @{}; foreach ($a in $agentManifest.agents) { $idSet[$a.id] = $a }
$nameToId = @{}; foreach ($a in $agentManifest.agents) { $nameToId[$a.displayName] = $a.id }
$badParent = @($agentManifest.agents | Where-Object { $_.parent -and -not $idSet.ContainsKey($_.parent) })
Add-SelfTestCheck 'All parents resolve to a known agent' ($badParent.Count -eq 0) (($badParent | ForEach-Object { $_.id }) -join ', ')

$badChild = [System.Collections.Generic.List[string]]::new()
foreach ($a in $agentManifest.agents) {
    foreach ($c in @($a.allowedChildren)) { if (-not $nameToId.ContainsKey($c)) { $badChild.Add("$($a.id)->$c") } }
}
Add-SelfTestCheck 'All allowedChildren resolve to a known display name' ($badChild.Count -eq 0) ($badChild -join ', ')

$badDelegation = @($agentManifest.agents | Where-Object { $_.level -eq 'worker' -and (@($_.tools) -contains 'agent') })
Add-SelfTestCheck 'No worker holds the delegation (agent) tool' ($badDelegation.Count -eq 0) (($badDelegation | ForEach-Object { $_.id }) -join ', ')

$allowedToolTokens = @('agent','read','search','execute','edit')
$badTools = [System.Collections.Generic.List[string]]::new()
foreach ($a in $agentManifest.agents) {
    if (-not $a.PSObject.Properties['tools'] -or $null -eq $a.tools) { $badTools.Add("$($a.id):no-tools") ; continue }
    foreach ($t in @($a.tools)) { if ($allowedToolTokens -notcontains $t) { $badTools.Add("$($a.id):$t") } }
}
Add-SelfTestCheck 'Every agent has explicit, valid tools (least privilege)' ($badTools.Count -eq 0) ($badTools -join ', ')

$defaultTools = @($agentManifest.defaults.tools)
$defaultReadOnly = (@($defaultTools | Sort-Object) -join ',') -eq 'read,search'
Add-SelfTestCheck 'Manifest default capability set is read-only' $defaultReadOnly "default = [$($defaultTools -join ', ')]"

$selfTestPassed = @($selfTestChecks | Where-Object { -not $_.pass }).Count -eq 0
$guardrailStatus = [ordered]@{
    schemaVersion  = 1
    generatedAt    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    generatedBy    = 'installer'
    productVersion = $productVersion
    enforcement    = 'advisory'
    enforcementNote = 'Agent hierarchy and tool scopes are declared in each agent frontmatter and are honoured by the model as guidance. Copilot Chat on locked-down enterprise builds does not hook-enforce these boundaries; they are advisory, not sandboxed. This report validates STRUCTURE, not runtime enforcement.'
    selfTestPassed = $selfTestPassed
    agentCount     = $writtenAgentFiles.Count
    expectedAgentCount = $expectedAgentCount
    checks         = $selfTestChecks
}
$guardrailJson = $guardrailStatus | ConvertTo-Json -Depth 6
Write-ManagedFile "$rootPath\.github\agent-docs\guardrail-status.json" $guardrailJson
Write-Host "  Written: .github/agent-docs/guardrail-status.json" -ForegroundColor Green
if ($selfTestPassed) {
    Write-Host "  Self-test PASSED: generated workspace matches the governance manifest." -ForegroundColor Green
} else {
    Write-Host "  Self-test reported issues (advisory) -- see guardrail-status.json." -ForegroundColor Yellow
}

# -- Integrity manifest (installed-manifest.json) ---------------------
# Records a version stamp and a SHA256 for every generated agent/config file
# so a later run -- or the Capability Maintenance team -- can detect drift
# between what the installer produced and what is on disk. Re-running the
# installer is idempotent: it overwrites these managed files, purges installer
# files it no longer ships (strict manifest-diff, see below), and refreshes
# this manifest.
$integrityFiles = [System.Collections.Generic.List[object]]::new()
$integrityTargets = @()
# Only agents DECLARED by this build are installer-owned. Hashing every file found
# in .github/agents would adopt user-authored agents (and agents retired by this
# release) into the manifest, so the old-minus-new purge below could never remove them.
$integrityTargets += @($managedAgents | ForEach-Object { Join-Path $agentsDirPath $_ })
foreach ($cfgRel in $managedConfigs) {
    $integrityTargets += (Join-Path $rootPath $cfgRel)
}
foreach ($skillName in $managedSkills) {
    $integrityTargets += (Join-Path $rootPath ".github\skills\$skillName\SKILL.md")
}
foreach ($target in $integrityTargets) {
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $rel = $target.Substring($rootPath.Length).TrimStart('\','/').Replace('\','/')
        $sha = Get-Sha256Hex -LiteralPath $target
        $integrityFiles.Add([ordered]@{ path = $rel; sha256 = $sha }) | Out-Null
    }
}

# -- Purge obsolete installer files (strict manifest-diff) ------------
# The manifest is a write-log of exactly what earlier runs shipped. Any path
# the PREVIOUS run recorded but this run did NOT re-ship is an obsolete
# installer artifact (a renamed/removed agent, a superseded config, a dropped
# skill) and is deleted. This is a strict set difference (old - new) over the
# write-log, never a directory sweep, so:
#   * user-authored files (never in any manifest) survive,
#   * workspace folders and business clones (source-control-repositories/,
#     PP env folders, .venv, .fabric-*) are outside .github and never touched,
#   * machine-local state files are explicitly excluded below even if they
#     were ever listed, and the diff is skipped entirely on an unknown schema.
$manifestPath = "$rootPath\.github\agent-docs\installed-manifest.json"
$previousManifestPaths = @()
$purgedPaths = @()
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $prevManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($prevManifest.schemaVersion -eq 1 -and $prevManifest.files) {
            $previousManifestPaths = @($prevManifest.files | ForEach-Object { ([string]$_.path).Replace('\','/') })
        } else {
            Write-Host "  Skipping obsolete-file purge: previous manifest has an unrecognised schema." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Skipping obsolete-file purge: previous manifest could not be read." -ForegroundColor Yellow
    }
}
if ($previousManifestPaths.Count -gt 0) {
    $newManifestPaths = @($integrityFiles | ForEach-Object { ([string]$_.path).Replace('\','/') })
    # Only ever delete inside installer-owned roots; belt-and-braces on top of
    # the diff, which already contains only installer-written paths.
    $purgeAllowedPrefixes = @('.github/agents/', '.github/skills/', '.github/agent-docs/', '.vscode/')
    $purgeAllowedExact    = @('.github/copilot-instructions.md', 'AGENTS.md', '.gitignore')
    # Never delete machine-local / stateful files, even if a stale manifest lists them.
    $purgeExcluded = @(
        '.github/agent-docs/tool-status.json',
        '.github/agent-docs/session-status.last.txt',
        '.github/agent-docs/guardrail-status.json',
        '.github/agent-docs/installed-manifest.json',
        '.github/agent-docs/local/repository-map.local.json'
    )
    $purged = 0
    $rootCanonical = [IO.Path]::GetFullPath($rootPath).TrimEnd('\') + '\'
    foreach ($rel in $previousManifestPaths) {
        if ($newManifestPaths -contains $rel) { continue }
        if ($purgeExcluded -contains $rel) { continue }
        # Reject anything that is not a plain relative path (a tampered manifest
        # must not be able to point the purge outside the installer-owned roots).
        if ($rel -match '(^|[\\/])\.\.([\\/]|$)' -or $rel -match '^[A-Za-z]:' -or $rel.StartsWith('/') -or $rel.StartsWith('\')) { continue }
        $inRoot = ($purgeAllowedExact -contains $rel) -or (@($purgeAllowedPrefixes | Where-Object { $rel.StartsWith($_) }).Count -gt 0)
        if (-not $inRoot) { continue }
        $abs = [IO.Path]::GetFullPath((Join-Path $rootPath ($rel -replace '/', '\')))
        if (-not $abs.StartsWith($rootCanonical, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (Test-Path -LiteralPath $abs -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $abs -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $abs) { throw 'still present after Remove-Item' }
                Write-Host "  Purged obsolete installer file: $rel" -ForegroundColor DarkGray
                $purged++
                $purgedPaths += $rel
            } catch {
                Write-Host "  Could not purge $rel (in use?) -- leaving in place." -ForegroundColor Yellow
            }
        }
    }
    if ($purged -gt 0) {
        Write-Host "  Removed $purged obsolete installer file(s) no longer shipped." -ForegroundColor Green
    }
}

$installedManifest = [ordered]@{
    schemaVersion  = 1
    generatedAt    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    generatedBy    = 'installer'
    productVersion = $productVersion
    fileCount      = $integrityFiles.Count
    files          = $integrityFiles
}
$installedManifestJson = $installedManifest | ConvertTo-Json -Depth 6
Write-ManagedFile "$rootPath\.github\agent-docs\installed-manifest.json" $installedManifestJson
Write-Host "  Written: .github/agent-docs/installed-manifest.json ($($integrityFiles.Count) files hashed)" -ForegroundColor Green

Write-Host "`n  All configuration files ready." -ForegroundColor Green

if ($EmitAgentsTo) {
    if ($selfTestPassed) {
        Write-Host "`n  [emit mode] Generated $($writtenAgentFiles.Count) agent files; self-test PASSED." -ForegroundColor Green
        exit 0
    }
    Write-Host "`n  [emit mode] Self-test FAILED -- see output above." -ForegroundColor Red
    exit 1
}

# =====================================================================
# STEP 9  -- Git init and launch VS Code
# =====================================================================
Show-Step 9 $totalSteps "Finishing Up"

Push-Location $rootPath
try {
    $createdGitRepository = -not (Test-Path "$rootPath\.git")
    if ($createdGitRepository) {
        try { & git init 2>$null | Out-Null } catch { }
        Write-Host "  Initialised git repository" -ForegroundColor Green
    }

    $gitUser  = git config user.name  2>$null
    $gitEmail = git config user.email 2>$null
    if ([string]::IsNullOrWhiteSpace($gitUser) -or [string]::IsNullOrWhiteSpace($gitEmail)) {
        Write-Host "  Warning: git user.name/email not configured  -- skipping initial commit." -ForegroundColor Yellow
    } else {
        $commitPaths = @()
        if ($createdGitRepository) {
            # A newly created repository owns the expected initial workspace snapshot.
            try { & git add -- . 2>$null | Out-Null } catch { }
            $staged = @(& git diff --cached --name-only 2>$null)
        } else {
            # An update owns only files declared by this installer. Never sweep user
            # work into the index, and never include unrelated paths already staged.
            $declaredPaths = @(
                @($managedAgents | ForEach-Object { ".github/agents/$_" })
                @($managedSkills | ForEach-Object { ".github/skills/$_" })
                @($managedConfigs)
                @($legacyManagedAgents | ForEach-Object { ".github/agents/$_" })
                @($purgedPaths)
            ) | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique
            foreach ($path in $declaredPaths) {
                $exists = Test-Path -LiteralPath (Join-Path $rootPath $path)
                # Do not use `ls-files --error-unmatch` here: an intentionally
                # ignored, untracked managed file produces a native Git error on
                # reruns even though excluding that path is the desired result.
                $tracked = @(& git ls-files -- $path 2>$null).Count -gt 0
                # A retired managed file that is still tracked must have its DELETION
                # staged, otherwise the update commit leaves it alive in history.
                if (-not $exists -and -not $tracked) { continue }
                & git check-ignore -q -- $path 2>$null
                $ignored = ($LASTEXITCODE -eq 0)
                if ($tracked -or -not $ignored) { $commitPaths += $path }
            }
            if ($commitPaths.Count -gt 0) {
                try { & git add -- @commitPaths 2>$null | Out-Null } catch { }
            }
            $staged = if ($commitPaths.Count -gt 0) {
                @(& git diff --cached --name-only -- @commitPaths 2>$null)
            } else { @() }
        }
        if ($staged.Count -eq 0) {
            Write-Host "  Git is already current; no new commit was needed." -ForegroundColor DarkGray
        } else {
            # git prints to stderr on success; `2>&1` under EAP=Stop would throw and leave
            # $LASTEXITCODE stale, so judge success by whether HEAD actually moved.
            $headBefore = (& git rev-parse --verify -q HEAD 2>$null)
            if ($createdGitRepository) {
                try { & git commit -m "chore: fabric agentic workspace setup" 2>$null | Out-Null } catch { }
            } else {
                # --only constrains the commit even if the user had unrelated staged work.
                try { & git commit --only -m "chore: fabric agentic workspace setup" -- @commitPaths 2>$null | Out-Null } catch { }
            }
            $headAfter = (& git rev-parse --verify -q HEAD 2>$null)
            if ($headAfter -and $headAfter -ne $headBefore) {
                $commitKind = if ($createdGitRepository) { 'Initial commit' } else { 'Workspace update commit' }
                Write-Host "  $commitKind created ($($headAfter.Substring(0,7)))." -ForegroundColor Green
            } else {
                Write-Host "  Warning: files were staged, but Git could not create the commit." -ForegroundColor Yellow
            }
        }
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Setup complete! v$productVersion" -ForegroundColor Green
Write-Host "  Workspace: $rootPath" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  VS Code will now open your workspace." -ForegroundColor White
Write-Host "  Once open, pick 000 - Fabric Workspace Master from the Copilot" -ForegroundColor White
Write-Host "  Chat agent dropdown and type anything to start." -ForegroundColor White
Write-Host ""
Write-Host "  Tip: if you re-ran the installer with VS Code already open, run" -ForegroundColor Yellow
Write-Host "  'Developer: Reload Window' so the agent dropdown rebuilds." -ForegroundColor Yellow
Write-Host ""
Read-Host "  Press Enter to open VS Code..."

$launchTarget = $rootPath
if ($repositoryMapReadable -and (Test-Path -LiteralPath $sessionWorkspaceFilePath)) {
    $launchTarget = $sessionWorkspaceFilePath
}
if ($env:FABRIC_AGENTIC_SKIP_VSCODE_LAUNCH -eq '1') {
    Write-Host '  VS Code launch skipped by the installer regression harness.' -ForegroundColor DarkGray
} else {
    & $vscodeCmd $launchTarget
}
