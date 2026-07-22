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
$productVersion = '0.6.1'
$workspaceFileName = 'Fabric-Agentic-Workspace.code-workspace'

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
        $vsha = (Get-FileHash -LiteralPath $vp -Algorithm SHA256).Hash
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
  "productVersion": "0.6.1",
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
    {"id":"fabric-workspace-master","displayName":"Fabric Workspace Master","filename":"00-fabric-workspace-master.agent.md","level":"executive","department":"executive","parent":null,"allowedChildren":["Fabric Solution Architect","Integration QA & Change Controller","Semantic Model Team Lead","Reporting Team Lead","Data Engineering Team Lead","Fabric Administration & Governance Team Lead","ALM & DevOps Team Lead","Applications & Integration Team Lead","Capability Maintenance Team Lead"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute"],"primarySkills":["fabric-orchestration","fabric-working-modes","fabric-source-control-safety","fabric-tool-policy"],"artifactTypes":["work orders","consolidated outcomes"],"writePermissions":"orchestration only; delegate implementation","defaultRisk":"high","focus":"Classify intent, select the authoritative write surface, invoke the minimum teams, prevent conflicting writes, and own the final outcome."},
    {"id":"fabric-solution-architect","displayName":"Fabric Solution Architect","filename":"01-fabric-solution-architect.agent.md","level":"executive","department":"executive","parent":"fabric-workspace-master","allowedChildren":["Semantic Model Team Lead","Reporting Team Lead","Data Engineering Team Lead","Fabric Administration & Governance Team Lead","ALM & DevOps Team Lead","Applications & Integration Team Lead"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search"],"primarySkills":["fabric-orchestration","fabric-working-modes"],"artifactTypes":["architecture plans","dependency maps","rollback plans"],"writePermissions":"read-only planning","defaultRisk":"low","focus":"Design artifact boundaries, dependencies, sequence, ownership, validation, rollback, and team assignments without broad implementation."},
    {"id":"integration-qa-change-controller","displayName":"Integration QA & Change Controller","filename":"02-integration-qa-change-controller.agent.md","level":"executive","department":"executive","parent":"fabric-workspace-master","allowedChildren":[],"visibility":"visible","userInvocable":true,"tools":["read","search","execute"],"primarySkills":["fabric-orchestration","fabric-working-modes","fabric-source-control-safety"],"artifactTypes":["acceptance reports","release evidence"],"writePermissions":"read-only validation; return defects to Master","defaultRisk":"low","focus":"Validate cross-artifact references, environment and branch alignment, security, privacy, coherent diffs, rollback, and release readiness."},

    {"id":"semantic-model-team-lead","displayName":"Semantic Model Team Lead","filename":"10-semantic-model-team-lead.agent.md","level":"team-lead","department":"semantic-model","parent":"fabric-workspace-master","allowedChildren":["Model Architecture Agent","Relationships & Storage Mode Agent","TMDL Agent","DAX Agent","Semantic Security & AI Metadata Agent","Semantic Validation & Performance Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-tmdl","fabric-working-modes","fabric-tool-policy"],"conditionalSkills":["Microsoft semantic model and Direct Lake skills","Kurt TMDL, DAX, TE2, BPA, and performance skills"],"artifactTypes":["semantic models","TMDL","DAX"],"focus":"Decompose semantic work, select TE2, Modeling MCP/TOM, TMDL, fab, or sqlcmd, coordinate dependencies, and own model-wide validation."},
    {"id":"model-architecture-agent","displayName":"Model Architecture Agent","filename":"11-model-architecture.agent.md","level":"worker","department":"semantic-model","parent":"semantic-model-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search"],"primarySkills":["fabric-tmdl"],"conditionalSkills":["Microsoft Direct Lake guidance","Kurt semantic architecture skills"],"artifactTypes":["model architecture recommendations"],"writePermissions":"normally read-only","defaultRisk":"low","focus":"Assess grain, fact and dimension boundaries, star schema, Direct Lake versus Import, composites, and calculation-group architecture."},
    {"id":"relationships-storage-mode-agent","displayName":"Relationships & Storage Mode Agent","filename":"12-relationships-storage-mode.agent.md","level":"worker","department":"semantic-model","parent":"semantic-model-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-tmdl"],"conditionalSkills":["Microsoft Direct Lake guidance","Kurt relationship skills"],"artifactTypes":["relationships","storage modes"],"focus":"Implement and validate cardinality, filter direction, ambiguity, bridges, integrity, storage modes, and Direct Lake behavior."},
    {"id":"tmdl-agent","displayName":"TMDL Agent","filename":"13-tmdl.agent.md","level":"worker","department":"semantic-model","parent":"semantic-model-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-tmdl"],"conditionalSkills":["Kurt TMDL and PBIP skills"],"artifactTypes":["TMDL files","semantic model metadata"],"focus":"Inspect before editing tables, columns, hierarchies, partitions, expressions, cultures, and PBIP semantic-model files; preserve house style and validate."},
    {"id":"dax-agent","displayName":"DAX Agent","filename":"14-dax.agent.md","level":"worker","department":"semantic-model","parent":"semantic-model-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-tmdl"],"conditionalSkills":["Kurt DAX skills"],"artifactTypes":["DAX measures","DAX queries","calculation groups"],"focus":"Create and validate measures, time intelligence, calculation groups, context behavior, formats, regression queries, and performance."},
    {"id":"semantic-security-ai-metadata-agent","displayName":"Semantic Security & AI Metadata Agent","filename":"15-semantic-security-ai-metadata.agent.md","level":"worker","department":"semantic-model","parent":"semantic-model-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-tmdl"],"conditionalSkills":["Microsoft semantic security and AI guidance"],"artifactTypes":["RLS","OLS","roles","AI metadata"],"defaultRisk":"high","focus":"Own RLS, OLS, roles, descriptions, synonyms, AI instructions, schemas, verified-answer metadata, and explicit security-impact validation."},
    {"id":"semantic-validation-performance-agent","displayName":"Semantic Validation & Performance Agent","filename":"16-semantic-validation-performance.agent.md","level":"worker","department":"semantic-model","parent":"semantic-model-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-tmdl","fabric-tool-policy"],"conditionalSkills":["Kurt BPA and performance skills"],"artifactTypes":["BPA results","schema checks","performance reports"],"writePermissions":"read-only unless a safe fix is approved","defaultRisk":"low","focus":"Run TE2 BPA, schema, relationship, VertiPaq, Direct Lake, DAX regression, and storage validation."},

    {"id":"reporting-team-lead","displayName":"Reporting Team Lead","filename":"20-reporting-team-lead.agent.md","level":"team-lead","department":"reporting","parent":"fabric-workspace-master","allowedChildren":["Report Planning & UX Agent","PBIR Authoring Agent","Theme & Formatting Agent","Advanced & Custom Visuals Agent","Paginated Reports Agent","Report QA & Desktop Verification Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-working-modes","fabric-tool-policy"],"conditionalSkills":["Kurt PBIR, report, theme, Deneb, custom visual, and paginated skills"],"artifactTypes":["PBIR reports","themes","paginated reports"],"focus":"Turn requirements into a report plan, coordinate PBIR implementation and semantic dependencies, serialize visual/theme ownership, and require report QA."},
    {"id":"report-planning-ux-agent","displayName":"Report Planning & UX Agent","filename":"21-report-planning-ux.agent.md","level":"worker","department":"reporting","parent":"reporting-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search"],"primarySkills":[],"conditionalSkills":["Kurt report planning and UX skills"],"artifactTypes":["report design contracts"],"writePermissions":"read-only planning","defaultRisk":"low","focus":"Define audience, business questions, page plan, navigation, visual selection, accessibility, interactions, and required measures before implementation."},
    {"id":"pbir-authoring-agent","displayName":"PBIR Authoring Agent","filename":"22-pbir-authoring.agent.md","level":"worker","department":"reporting","parent":"reporting-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-tool-policy"],"conditionalSkills":["Kurt pbir-cli and pbir-format skills"],"artifactTypes":["PBIR pages","visuals","bindings","filters","bookmarks"],"focus":"Use pbir first for report structure and visuals, verify current help, validate after each mutation, and use controlled direct PBIR only as fallback."},
    {"id":"theme-formatting-agent","displayName":"Theme & Formatting Agent","filename":"23-theme-formatting.agent.md","level":"worker","department":"reporting","parent":"reporting-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","edit"],"primarySkills":[],"conditionalSkills":["Kurt report theme skills"],"artifactTypes":["report themes","format properties"],"focus":"Own typography, palette, spacing, conditional formatting, branding, and accessibility; never edit the same visual concurrently with PBIR Authoring."},
    {"id":"advanced-custom-visuals-agent","displayName":"Advanced & Custom Visuals Agent","filename":"24-advanced-custom-visuals.agent.md","level":"worker","department":"reporting","parent":"reporting-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","edit"],"primarySkills":[],"conditionalSkills":["Kurt Deneb, SVG, and custom-visual skills"],"artifactTypes":["Deneb specs","SVG","custom visual configuration"],"focus":"Implement Deneb, SVG, Python/R visuals, custom visuals, and advanced interactions only when the design requires them."},
    {"id":"paginated-reports-agent","displayName":"Paginated Reports Agent","filename":"25-paginated-reports.agent.md","level":"worker","department":"reporting","parent":"reporting-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","edit"],"primarySkills":[],"conditionalSkills":["Microsoft and Kurt paginated report skills"],"artifactTypes":["paginated report definitions"],"focus":"Own paginated definitions, parameters, data sources, layout, rendering, and export validation."},
    {"id":"report-qa-desktop-agent","displayName":"Report QA & Desktop Verification Agent","filename":"26-report-qa-desktop-verification.agent.md","level":"worker","department":"reporting","parent":"reporting-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-tool-policy"],"conditionalSkills":["Kurt PBIR validation skills"],"artifactTypes":["report validation evidence","screenshots"],"writePermissions":"read-only verification","defaultRisk":"low","focus":"Run pbir validation and available Desktop refresh/screenshots; detect overlap, truncation, blanks, broken bindings, accessibility, and theme defects."},

    {"id":"data-engineering-team-lead","displayName":"Data Engineering Team Lead","filename":"30-data-engineering-team-lead.agent.md","level":"team-lead","department":"data-engineering","parent":"fabric-workspace-master","allowedChildren":["Notebook & Spark Agent","Lakehouse, Delta & MLV Agent","Warehouse SQL Agent","SQL Database Agent","Dataflows Gen2 Agent","Pipeline Orchestration Agent","Real-Time Intelligence Agent","Fabric Intelligence & Ontology Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-pipelines","fabric-working-modes","fabric-tool-policy"],"conditionalSkills":["Microsoft Fabric engineering skills"],"artifactTypes":["notebooks","lakehouses","warehouses","SQL databases","dataflows","pipelines","RTI"],"focus":"Coordinate source-to-serving engineering and its semantic dependencies, assign one artifact owner, and validate data and orchestration."},
    {"id":"notebook-spark-agent","displayName":"Notebook & Spark Agent","filename":"31-notebook-spark.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":[],"conditionalSkills":["Microsoft Spark and notebook skills"],"artifactTypes":["Fabric notebooks","PySpark","Spark SQL"],"focus":"Author and validate PySpark, Spark SQL, notebooks, sessions, remote execution, dependencies, and notebook quality."},
    {"id":"lakehouse-delta-mlv-agent","displayName":"Lakehouse, Delta & MLV Agent","filename":"32-lakehouse-delta-mlv.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":[],"conditionalSkills":["Microsoft Lakehouse, Delta, medallion, MLV, shortcut, and OneLake skills"],"artifactTypes":["Delta tables","lakehouses","materialized lake views","shortcuts"],"focus":"Own Delta, medallion, MLV, incremental processing, shortcuts, schema evolution, and optimization; request DuckDB only through approval."},
    {"id":"warehouse-sql-agent","displayName":"Warehouse SQL Agent","filename":"33-warehouse-sql.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-tool-policy"],"conditionalSkills":["Microsoft Warehouse skills"],"artifactTypes":["Warehouse DDL","DML","SQL validation"],"focus":"Design and validate Fabric Warehouse and SQL analytics endpoint DDL, DML, serving, and performance using sqlcmd when available."},
    {"id":"sql-database-agent","displayName":"SQL Database Agent","filename":"34-sql-database.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-tool-policy"],"conditionalSkills":["Microsoft Fabric SQL Database skills"],"artifactTypes":["Fabric SQL Database schemas","procedures","queries"],"focus":"Handle Fabric SQL Database OLTP, procedures, temporal, JSON, vectors, security, and diagnostics distinctly from Warehouse work."},
    {"id":"dataflows-gen2-agent","displayName":"Dataflows Gen2 Agent","filename":"35-dataflows-gen2.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":[],"conditionalSkills":["Microsoft Dataflows Gen2 and Power Query skills"],"artifactTypes":["Dataflows Gen2 definitions","Power Query M"],"focus":"Own Power Query M, connectors, previews, destinations, refresh behavior, and failure diagnosis for Dataflows Gen2."},
    {"id":"pipeline-orchestration-agent","displayName":"Pipeline Orchestration Agent","filename":"36-pipeline-orchestration.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-pipelines"],"conditionalSkills":["Microsoft pipeline skills"],"artifactTypes":["Fabric pipeline definitions","schedules"],"focus":"Implement pipeline activities, notebooks, dataflows, copy, variables, schedules, dependencies, retry, and failure handling with schema validation."},
    {"id":"real-time-intelligence-agent","displayName":"Real-Time Intelligence Agent","filename":"37-real-time-intelligence.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":[],"conditionalSkills":["Microsoft Eventhouse, KQL, Eventstream, and Activator skills"],"artifactTypes":["Eventhouse","KQL","Eventstream","Activator"],"focus":"Own real-time Fabric artifacts, KQL behavior, ingestion, monitoring, and operational validation."},
    {"id":"fabric-intelligence-ontology-agent","displayName":"Fabric Intelligence & Ontology Agent","filename":"38-fabric-intelligence-ontology.agent.md","level":"worker","department":"data-engineering","parent":"data-engineering-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":[],"conditionalSkills":["Microsoft FabricIQ, Ontology, and Data Agent skills"],"artifactTypes":["ontologies","FabricIQ assets","Data Agents"],"focus":"Handle FabricIQ, Ontology, Data Agents, and related knowledge capabilities while checking current product behavior."},

    {"id":"fabric-administration-governance-team-lead","displayName":"Fabric Administration & Governance Team Lead","filename":"40-fabric-administration-governance-team-lead.agent.md","level":"team-lead","department":"administration-governance","parent":"fabric-workspace-master","allowedChildren":["Workspace & Capacity Administration Agent","Security, Access & Governance Agent","Monitoring, Catalog & Operations Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-working-modes","fabric-tool-policy"],"conditionalSkills":["Microsoft administration, governance, and monitoring skills"],"artifactTypes":["workspace settings","capacity settings","governance policy","operations evidence"],"defaultRisk":"high","focus":"Coordinate workspace, capacity, access, governance, monitoring, catalog, and operational safety with explicit approval for destructive changes."},
    {"id":"workspace-capacity-administration-agent","displayName":"Workspace & Capacity Administration Agent","filename":"41-workspace-capacity-administration.agent.md","level":"worker","department":"administration-governance","parent":"fabric-administration-governance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-tool-policy"],"conditionalSkills":["Microsoft workspace and capacity skills"],"artifactTypes":["workspace and capacity configuration"],"defaultRisk":"high","focus":"Administer workspaces, capacities, settings, assignments, and cost awareness; require approval for destructive or production-impacting actions."},
    {"id":"security-access-governance-agent","displayName":"Security, Access & Governance Agent","filename":"42-security-access-governance.agent.md","level":"worker","department":"administration-governance","parent":"fabric-administration-governance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":[],"conditionalSkills":["Microsoft security and governance skills"],"artifactTypes":["roles","permissions","governance controls"],"defaultRisk":"high","focus":"Own workspace roles, Entra groups, least privilege, permissions, governance, and security-boundary validation."},
    {"id":"monitoring-catalog-operations-agent","displayName":"Monitoring, Catalog & Operations Agent","filename":"43-monitoring-catalog-operations.agent.md","level":"worker","department":"administration-governance","parent":"fabric-administration-governance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-tool-policy"],"conditionalSkills":["Microsoft monitoring and catalog skills"],"artifactTypes":["inventory","job status","incident findings"],"writePermissions":"read-only diagnosis by default","defaultRisk":"low","focus":"Search catalog and inventory, inspect jobs and refreshes, monitor status, and diagnose failures without unapproved remediation."},

    {"id":"alm-devops-team-lead","displayName":"ALM & DevOps Team Lead","filename":"50-alm-devops-team-lead.agent.md","level":"team-lead","department":"alm-devops","parent":"fabric-workspace-master","allowedChildren":["GitHub Source Control Agent","Azure DevOps Agent","Fabric Git Integration Agent","Deployment & Release Agent","Power BI ALM Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-source-control-safety","fabric-working-modes","fabric-tool-policy"],"conditionalSkills":["Kurt PBIP and pbi-tools skills","Microsoft Fabric Git guidance"],"artifactTypes":["branches","pull requests","pipelines","releases","Fabric Git mappings"],"focus":"Own Git, GitHub, Azure DevOps, Fabric Git integration, release sequencing, and Power BI ALM; tool installation belongs to Maintenance."},
    {"id":"github-source-control-agent","displayName":"GitHub Source Control Agent","filename":"51-github-source-control.agent.md","level":"worker","department":"alm-devops","parent":"alm-devops-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-source-control-safety","fabric-tool-policy"],"artifactTypes":["Git branches","GitHub PRs","Actions","releases"],"focus":"Use Git and gh for authorized branches, commits, pull requests, reviews, Actions, releases, and repository settings; never expose credentials."},
    {"id":"azure-devops-agent","displayName":"Azure DevOps Agent","filename":"52-azure-devops.agent.md","level":"worker","department":"alm-devops","parent":"alm-devops-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-source-control-safety","fabric-tool-policy"],"artifactTypes":["Azure Repos PRs","pipelines","boards","project configuration"],"focus":"Use Git and approved az devops/repos/pipelines/boards commands for Azure DevOps work, respecting repository topology and auth policy."},
    {"id":"fabric-git-integration-agent","displayName":"Fabric Git Integration Agent","filename":"53-fabric-git-integration.agent.md","level":"worker","department":"alm-devops","parent":"alm-devops-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-source-control-safety","fabric-working-modes"],"conditionalSkills":["Microsoft Fabric Git integration guidance"],"artifactTypes":["workspace-branch mappings","Fabric Git status"],"defaultRisk":"high","focus":"Inspect and operate Fabric Git status, commit, update, mapping, and conflict workflows without inferring permission to overwrite either side."},
    {"id":"deployment-release-agent","displayName":"Deployment & Release Agent","filename":"54-deployment-release.agent.md","level":"worker","department":"alm-devops","parent":"alm-devops-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-source-control-safety","fabric-working-modes"],"artifactTypes":["release plans","deployment pipeline evidence","release notes"],"defaultRisk":"high","focus":"Sequence DEV to TEST to PROD, PRs, deployment pipelines, parameters, release checks, rollback, and notes without assuming branch names."},
    {"id":"power-bi-alm-agent","displayName":"Power BI ALM Agent","filename":"55-power-bi-alm.agent.md","level":"worker","department":"alm-devops","parent":"alm-devops-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-tool-policy","fabric-source-control-safety"],"conditionalSkills":["Kurt pbi-tools and PBIP skills"],"artifactTypes":["PBIX extraction","PBIP builds","deployment packages"],"focus":"Use pbi-tools for PBIX/PBIP extraction, build, CI/CD, deployment, and ALM validation—not routine PBIR visual editing."},

    {"id":"applications-integration-team-lead","displayName":"Applications & Integration Team Lead","filename":"60-applications-integration-team-lead.agent.md","level":"team-lead","department":"applications-integration","parent":"fabric-workspace-master","allowedChildren":["Python & Fabric SDK Agent","REST, Authentication & XMLA Agent","SQL, ODBC & Data Access Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-working-modes","fabric-tool-policy"],"conditionalSkills":["Microsoft SDK, REST, SQL consumption, and authentication skills"],"artifactTypes":["applications","SDK utilities","REST integrations","data-access code"],"focus":"Coordinate custom applications, SDK, REST/XMLA, authentication, ODBC, and data access without leaking secrets."},
    {"id":"python-fabric-sdk-agent","displayName":"Python & Fabric SDK Agent","filename":"61-python-fabric-sdk.agent.md","level":"worker","department":"applications-integration","parent":"applications-integration-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":[],"conditionalSkills":["Microsoft Fabric SDK and Python skills"],"artifactTypes":["Python applications","SDK utilities"],"focus":"Build Python applications, SDK clients, Azure Identity integrations, APIs, processing, and local utilities with safe dependency handling."},
    {"id":"rest-authentication-xmla-agent","displayName":"REST, Authentication & XMLA Agent","filename":"62-rest-authentication-xmla.agent.md","level":"worker","department":"applications-integration","parent":"applications-integration-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-tool-policy"],"conditionalSkills":["Microsoft REST and authentication guidance"],"artifactTypes":["REST clients","XMLA operations","authentication configurations"],"defaultRisk":"high","focus":"Handle Fabric/Power BI REST, az rest, audiences, Entra, SPN, managed identity, and XMLA with no secrets in commands or source."},
    {"id":"sql-odbc-data-access-agent","displayName":"SQL, ODBC & Data Access Agent","filename":"63-sql-odbc-data-access.agent.md","level":"worker","department":"applications-integration","parent":"applications-integration-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-tool-policy"],"conditionalSkills":["Microsoft SQL consumption skills"],"artifactTypes":["ODBC clients","SQLAlchemy code","parameterized queries"],"focus":"Own sqlcmd, ODBC, pyodbc, SQLAlchemy, Warehouse/endpoint/database connectivity, bulk operations, and parameterized validation."},

    {"id":"capability-maintenance-team-lead","displayName":"Capability Maintenance Team Lead","filename":"70-capability-maintenance-team-lead.agent.md","level":"team-lead","department":"capability-maintenance","parent":"fabric-workspace-master","allowedChildren":["Upstream Repository Sync Agent","Skill Inventory & Mapping Agent","Agent Coverage & Organization Agent","Environment & Tooling Agent","Installer Health & Regression Agent","Managed File Review Agent"],"visibility":"visible","userInvocable":true,"tools":["agent","read","search","execute","edit"],"primarySkills":["fabric-maintenance","fabric-tool-policy","fabric-source-control-safety"],"artifactTypes":["vendor state","skill inventory","tool status","maintenance reports","installer evidence"],"focus":"Own vendor sync, skill inventory, organization, approved tool installation and updates, failed-install remediation, managed-file review, and workspace regression checks."},
    {"id":"upstream-repository-sync-agent","displayName":"Upstream Repository Sync Agent","filename":"71-upstream-repository-sync.agent.md","level":"worker","department":"capability-maintenance","parent":"capability-maintenance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute"],"primarySkills":["fabric-maintenance"],"artifactTypes":["vendor repository state"],"writePermissions":"clean vendor sync only; never edit, reset, or overwrite vendor content","defaultRisk":"medium","focus":"Inspect the Microsoft and Kurt repositories, preserve the original clean-repository git pull --ff-only workflow, record commits, and report dirty or diverged repositories without resetting them."},
    {"id":"skill-inventory-mapping-agent","displayName":"Skill Inventory & Mapping Agent","filename":"72-skill-inventory-mapping.agent.md","level":"worker","department":"capability-maintenance","parent":"capability-maintenance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-maintenance"],"artifactTypes":["skill inventory","mapping report"],"focus":"Dynamically detect valid, invalid, duplicate, added, removed, renamed, changed, unmapped, and tool-assuming skills and refresh local inventory."},
    {"id":"agent-coverage-organization-agent","displayName":"Agent Coverage & Organization Agent","filename":"73-agent-coverage-organization.agent.md","level":"worker","department":"capability-maintenance","parent":"capability-maintenance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","edit"],"primarySkills":["fabric-maintenance","fabric-orchestration"],"artifactTypes":["coverage analysis","mapping proposals"],"focus":"Evaluate coverage, overlap, overload, gaps, team fit, workers, and teams; auto-apply only obvious low-risk mappings and seek approval for structural changes."},
    {"id":"environment-tooling-agent","displayName":"Environment & Tooling Agent","filename":"74-environment-tooling.agent.md","level":"worker","department":"capability-maintenance","parent":"capability-maintenance-team-lead","allowedChildren":[],"visibility":"hidden","userInvocable":false,"tools":["read","search","execute","edit"],"primarySkills":["fabric-maintenance","fabric-tool-policy"],"artifactTypes":["tool status","installation plans","lockdown remediation reports"],"writePermissions":"approved environment/tool changes only","defaultRisk":"high","optionalToolRequestPermissions":"the only worker allowed to install default or optional tools, always after explicit user approval","focus":"Own current and future default-tool updates, failed installer follow-up, optional installation, locked-down laptop remediation, validation, rollback guidance, and tool-status refresh."},
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
    param([string]$Name, [int]$Retries = 4)
    $isRunnable = {
        param([string]$CommandName)
        $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
        if (-not $cmd) { return $false }
        try {
            $output = & $cmd.Source --version 2>$null | Out-String
            return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($output))
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
        Write-Host "         Or finish it later in VS Code: select '10 - Capability Maintenance" -ForegroundColor DarkGray
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
        $actual = (Get-FileHash $Path -Algorithm SHA256).Hash.ToUpperInvariant()
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
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
            return $true
        } catch {
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $dest -Force }
            throw
        }
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
            try {
                $proc = Start-Process -FilePath $wg.Source -ArgumentList @(
                    'download', '--id', $WingetId, '--exact', '--skip-dependencies',
                    '--disable-interactivity', '--accept-package-agreements',
                    '--accept-source-agreements', '-d', $dl
                ) -NoNewWindow -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
                $exited = $true
                try { $proc | Wait-Process -Timeout $TimeoutSec -ErrorAction Stop } catch { $exited = $false }
                if (-not $exited) { try { $proc | Stop-Process -Force -ErrorAction SilentlyContinue } catch { } }
            } catch { }
            Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
            $fetched = Get-ChildItem $dl -Recurse -File -ErrorAction SilentlyContinue |
                       Where-Object { $_.Extension -in '.msi', '.zip' } | Select-Object -First 1
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
        & $checkOne 'tabularEditor' 'Tabular Editor CLI' (Get-ExeFileVersion (& $probeTarget 'tabularEditor')) (Get-LatestGitHubVersion 'TabularEditor/TabularEditor') `
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

# -- Helper: merge installer-owned keys into existing JSON settings -----
function Merge-JsonSettings ([string]$Path, [hashtable]$Required) {
    $existing = [ordered]@{}
    if (Test-Path $Path) {
        try {
            $parsed = Get-Content $Path -Raw | ConvertFrom-Json
            foreach ($prop in $parsed.PSObject.Properties) {
                $existing[$prop.Name] = $prop.Value
            }
        } catch {
            # Malformed JSON -- back up and start fresh
            Copy-Item $Path "$Path.bak" -Force
            Write-Host "  Backed up malformed settings.json to settings.json.bak" -ForegroundColor Yellow
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
    Set-Content -Path $Path -Value $json -Encoding UTF8
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
        try {
            $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            foreach ($prop in $parsed.PSObject.Properties) { $workspace[$prop.Name] = $prop.Value }
            $folders = @($parsed.folders)
        } catch {
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
        $path = ([string]$folder.path).Replace('\', '/').TrimEnd('/')
        $key = $path.ToLowerInvariant()
        if ($key -eq 'source-control-repositories' -or $key.StartsWith('source-control-repositories/')) { continue }
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
    if ($settings -is [System.Collections.IDictionary]) {
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
if (-not (Test-CliResilient -Name 'fab')) {
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
if ($fabHit) {
    Set-ToolStatus -Key 'fab' -Found $true -Command $fabHit.command -Path $fabHit.path -Version (Get-ToolVersion -Exe 'fab') -Category 'core-cli' -InstallMode 'auto'
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

# Tabular Editor CLI -- semantic-model validation / BPA / automation (Agent 3).
# GUI app -> do not probe --version (would launch the UI).
Invoke-OptionalToolPrompt -Key 'tabularEditor' -Name 'Tabular Editor CLI' `
    -Purpose 'Semantic model validation, Best Practice Analyzer, and automation.' `
    -Provider 'https://tabulareditor.com (TE2 is free; TE3 is paid)' `
    -Aliases @('TabularEditor.exe','TabularEditor2.exe','TabularEditor3.exe','te') `
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
# user decides where -- if anywhere -- to Save Workspace As.
$sessionWorkspaceFilePath = Join-Path ([IO.Path]::GetTempPath()) $workspaceFileName
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
        if (Test-Path -LiteralPath $container) {
            if (Test-Path -LiteralPath $gitDir) {
                $originUrl = (& git --git-dir $gitDir config --get remote.origin.url 2>$null | Select-Object -First 1)
                if (-not $originUrl -or (Get-NormalizedRepositoryUrl $originUrl) -ne (Get-NormalizedRepositoryUrl $plan.cloneUrl)) {
                    Write-Host '    Existing destination is a different Git repository; preserved and skipped.' -ForegroundColor Yellow
                    continue
                }
                Write-Host '    Existing matching mirror found; preserving its worktrees.' -ForegroundColor Green
                $repositoryReady = $true
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
            if (Test-Path -LiteralPath $worktreePath) { $mirroredBranches += $branch; continue }
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
# roots/settings in a prior session file are preserved; only missing managed roots
# are added. Any stale copy previously written into the folder is removed so the
# generated workspace stays clean.
if ($repositoryMapReadable) {
    if (Test-Path -LiteralPath $workspaceFilePath) {
        Remove-Item -LiteralPath $workspaceFilePath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $sessionWorkspaceFilePath) {
        Remove-Item -LiteralPath $sessionWorkspaceFilePath -Force -ErrorAction SilentlyContinue
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

- A Direct Lake model reads Delta from **one specific lakehouse** - the one its source
  expression points at (`Sql.Database(..., <endpointId>)`, "Direct Lake on OneLake").
- When ETL writes Delta into **that** lakehouse, the model reframes on the next query
  and serves new data, usually within seconds, with **no explicit refresh required**.
- The SQL analytics endpoint has a background metadata-sync that can briefly lag a
  write. For **deterministic** freshness, `RefreshSQLEndpoint` on the **model's own
  lakehouse** (not an upstream layer), or trigger a model reframe, then read.
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
   on a Spark kernel; route those to REST/XMLA or the portal query editor, or flag them.
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
'@
Write-ManagedFile $cliPolicySkillPath $cliPolicyContent
Write-Host "  Written: .github/skills/fabric-cli-policy/SKILL.md" -ForegroundColor Green

Read-Host "`n  Press Enter to continue..."

# =====================================================================
# STEP 7  -- Generate agent definitions
# =====================================================================
Show-Step 7 $totalSteps "Writing Agent Definitions"

# ----- Master Agent reference docs (in agent-docs, NOT in dropdown) ---
$startingFlowContent = @'
# Starting Flow - Fabric Workspace Master Agent

Run this on the first message of every session. NO EXCEPTIONS.

---

## Phase 0 - Classify the user's message

Classify the user's opening message:

- **GREETING** = a casual hello, hi, good morning, hey, or similar
  with no specific question or task embedded.
- **QUESTION / TASK** = an actual question, request, or instruction
  (e.g. "add a measure", "what environments do I have?", etc.).

**Save the classification and the original message** - you will need them after
topic selection.

**If QUESTION / TASK**, say:
"Got it! I will help with that right after a quick session startup."

**If GREETING**, greet warmly then say:
"Let me run through the session startup first."

Proceed immediately to Phase 1. Do NOT wait for the user to reply.

---

## Phase 1 - Skill maintenance prompt

Show when each skill source was last updated. Use the most HONEST signal available
for each source - never fake, touch, or normalise these dates.

For the two CLONED repos, the real freshness signal is the upstream commit date.
Run (and if `git` errors because the folder is not a git checkout, fall back to the
newest file modification time from the fallback command):

  git -C skills-for-fabric log -1 --format=%cd --date=format-local:"%Y-%m-%d %H:%M" 2>&1
  git -C power-bi-agentic-development log -1 --format=%cd --date=format-local:"%Y-%m-%d %H:%M" 2>&1

  Fallback if not a git checkout (e.g. downloaded as a zip):
  Get-ChildItem "skills-for-fabric" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty LastWriteTime | ForEach-Object { $_.ToString("yyyy-MM-dd HH:mm") }
  Get-ChildItem "power-bi-agentic-development" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty LastWriteTime | ForEach-Object { $_.ToString("yyyy-MM-dd HH:mm") }

For the CUSTOM embedded skills, there is no upstream repo - they are authored in
the installer and written to disk at setup time. Show their REAL on-disk
modification time (this honestly reflects when this workspace last installed or
updated them - the installer no longer overrides it):

  (Get-Item ".github/skills/fabric-tmdl/SKILL.md").LastWriteTime.ToString("yyyy-MM-dd HH:mm")
  (Get-Item ".github/skills/fabric-pipelines/SKILL.md").LastWriteTime.ToString("yyyy-MM-dd HH:mm")

If a source folder or file does not exist, show "not installed" instead of a date.

Then say:
"Welcome to your Fabric Workspace session!

**Skill sources - freshness (local time):**
| Source | Date | Meaning |
|--------|------|---------|
| skills-for-fabric (Microsoft, MIT) | [date or 'not installed'] | upstream commit |
| power-bi-agentic-development (data-goblin, GPL-3.0) | [date or 'not installed'] | upstream commit |
| fabric-tmdl (custom, embedded) | [date] | installed locally |
| fabric-pipelines (custom, embedded) | [date] | installed locally |

Would you like to run capability maintenance?
This switches to the Capability Maintenance Team Lead, which offers light or
deep maintenance, refreshes skills and tool status, and sends you back here.

  [1] Yes - run maintenance now
  [2] No - skip and start working

Enter 1 or 2:"

**STOP HERE and wait for the user to reply.**

**If the user chooses 1:**
Say: "Please select **070 - Capability Maintenance Team Lead** in the Copilot
Chat agent dropdown. It will offer light or deep maintenance, handle skill and
tool upkeep (including approved recovery from failed installs), and tell you
when to come back here."
Then STOP and wait. When the user returns and sends another message,
continue to Phase 2.

**If the user chooses 2 (or anything else):**
Continue to Phase 2 immediately.

---

## Phase 2 - Check identity

Prefer the Fabric CLI for identity. Try `fab` first; fall back to `az` only if
`fab` is not installed.

1. Run: fab auth status 2>&1
   - If it reports a signed-in account: "Logged in to Fabric as [account]."
   - If `fab` is not found OR not logged in, continue to step 2.
2. Fallback - run: az account show --query "{name:name, user:user.name}" --output table 2>&1
   - If successful: "Logged in as [user] on tenant [name]."
   - If it fails: "Not logged in. Run `fab auth login` (preferred) or `az login` if you need Fabric API access."

Do NOT block on this - many tasks work without any CLI login. The core workflow
(Fabric extension + local file editing) needs no CLI at all.

---

## Phase 2b - Start and verify the MCP servers

The two MCP servers (Fabric MCP, Power BI modeling) should be RUNNING before live
work begins. They self-register (no mcp.json), and VS Code starts a provider MCP
server on demand the first time one of its tools is invoked - so the Master starts
them by USING them, and only asks the user to intervene if that cannot happen.
`tool-status.json` only proves the extensions are INSTALLED
(`extensionInstalled: true`, `mcpToolsCallable: "unknown"`); it cannot prove the
tools are callable in THIS chat session. Decide by testing, every session:

1. START-BY-USE: attempt ONE cheap, read-only call against EACH server to make
   VS Code auto-start it:
   - Fabric MCP -> a "list workspaces / list items" style tool.
   - Power BI modeling MCP -> a "list connections" style tool.
   Accept any trust/start prompt VS Code shows; the first call can take a few
   seconds while the server process launches.
2. If the calls succeed -> announce "MCP servers running - using MCP for live work"
   and go MCP-first for live tasks.
3. If the MCP tools are NOT listed at all (server never started, so there is
   nothing to invoke), proactively ask the user to start them ONCE - this is
   expected on a brand-new workspace - then re-test:
   - Command Palette -> `MCP: List Servers` -> Start "Fabric MCP" and
     "powerbi-modeling-mcp"; accept the trust prompt and any sign-in.
   - In the Chat Tools picker, tick the Fabric + Power BI MCP tools; if the picker
     is full (~128 tools), turn OFF unrelated tool groups so they fit.
   Then re-run step 1. VS Code remembers the started/trusted state, so later
   sessions in this workspace come up with the servers already running.
4. If they still will not start (auth blocked, corporate policy, or the ~128-tool
   budget) -> announce plainly and continue on the REST/CLI fallback
   (`az account get-access-token` + Power BI `executeQueries`, `fab api`).

Do NOT block on MCP - REST/CLI fully covers live read/compare work - but DO attempt
the start every session so the live tools are ready when work begins.

---

## Phase 3 - Topic selection

Say:
"What would you like to work on?

  [3] Semantic Models - TMDL, DAX, measures, columns, relationships
  [4] Data Engineering - Spark notebooks, SQL warehouse, pipelines, medallion
  [5] Administration - Capacity, governance, workspace documentation
  [6] App Development - Python apps, ODBC, XMLA, REST API integration
  [7] Reports - PBIR report editing, visuals, themes
  [8] Pipelines - Data Factory pipeline JSON authoring
  [9] DevOps / ALM - Git Integration, Deployment Pipelines, Azure DevOps / GitHub PRs
  [0] Stay here - I will describe what I need and you route for me

Enter a number or describe your task:"

**If user picks 3-9:** Say "Please switch to the corresponding agent in the dropdown:
- 3 -> **010 - Semantic Model Team Lead**
- 4 -> **030 - Data Engineering Team Lead**
- 5 -> **040 - Fabric Administration & Governance Team Lead**
- 6 -> **060 - Applications & Integration Team Lead**
- 7 -> **020 - Reporting Team Lead**
- 8 -> **030 - Data Engineering Team Lead** (which delegates pipeline authoring)
- 9 -> **050 - ALM & DevOps Team Lead**"

**If user picks 0 or describes a task:** Read `.github/agent-docs/working-flow-reference.md`
and handle the request directly.

**Recall Phase 0:** If the user's first message was a QUESTION / TASK that you
acknowledged at the start, now handle it. Read the relevant skills and respond.
'@
Write-ManagedFile "$rootPath\.github\agent-docs\starting-flow.md" $startingFlowContent
Write-Host "  Written: .github/agent-docs/starting-flow.md" -ForegroundColor Green

$workingFlowContent = @'
# Working Flow Reference - Fabric Workspace Master Agent

This file is read by the agent when handling tasks directly (user chose [0]
in topic selection or described their task).

---

## Skill Discovery - ALWAYS Dynamic (resilient to upstream changes)

Skills live in multiple repositories that rename and restructure folders
frequently. **NEVER assume you know what skills exist or where they are**, and
never hardcode a deep path. Every path in this file is a LAST-KNOWN HINT as of
install time, not a guarantee.

**Before performing any skill-based task:**

1. Identify which skill source is relevant (see table below)
2. List the repo ROOT first (e.g. `ls power-bi-agentic-development`), find the
   skills container (today `plugins/` or `skills/`), then list it
3. Search downward by KEYWORD (e.g. "tmdl", "dax", "spark", "pipeline") to locate
   the current SKILL.md - if a hinted folder was renamed, pick the closest match
4. Read the relevant SKILL.md
5. Read any references/ docs mentioned in the SKILL.md
6. Follow the SKILL.md instructions step by step

If a hinted path is missing, do NOT fail - re-list the parent (or the repo root)
and re-discover. The cloned repos are EXPECTED to move things around over time.

### Skill sources

| Topic | Source directory | How to discover |
|-------|-----------------|-----------------|
| TMDL / Semantic Models | `.github/skills/fabric-tmdl/` | Always exists (custom skill) |
| Pipelines | `.github/skills/fabric-pipelines/` | Always exists (custom skill) |
| TMDL depth / DAX / PBIR | `power-bi-agentic-development/plugins/` | `ls power-bi-agentic-development/plugins/` then explore |
| Spark / Notebooks | `skills-for-fabric/skills/` | `ls skills-for-fabric/skills/` |
| SQL Warehouse | `skills-for-fabric/skills/` | `ls skills-for-fabric/skills/` |
| Eventhouse / KQL | `skills-for-fabric/skills/` | `ls skills-for-fabric/skills/` |
| Reports / Visuals | `power-bi-agentic-development/plugins/` | `ls power-bi-agentic-development/plugins/` |
| Medallion architecture | `skills-for-fabric/skills/` | `ls skills-for-fabric/skills/` |
| REST API / CLI | `.github/skills/fabric-cli-policy/` + `skills-for-fabric/skills/` | Read policy skill first (prefer `fab`) |
| Admin / Governance | Both repos | List both skill directories |

For any terminal CLI or REST API work, read `.github/skills/fabric-cli-policy/SKILL.md` first:
prefer the Fabric CLI (`fab api`, `fab job`, `fab export/import`, OneLake `fab cp`). The
Microsoft `skills-for-fabric/common/COMMON-CLI.md` (az rest) is the documented FALLBACK
for SQL/TDS and non-Fabric token audiences.

### Discovery workflow example

User asks: "Add a measure to my semantic model"
1. Topic = TMDL -> read `.github/skills/fabric-tmdl/SKILL.md` (house style)
2. For DAX depth -> `ls power-bi-agentic-development` -> find the skills container
   -> search it for a "dax" skill -> read that SKILL.md (syntax / correctness)
3. Follow BOTH skills: house style from yours, DAX correctness from theirs

---

## Per-request routing advice

You can answer most things here, but specialists give deeper results. When a
request maps strongly to one specialist topic, proactively tell the user and
offer to switch - then still handle it inline if they decline. Example:

> "I can do this here, but you'll get deeper results from
> **010 - Semantic Model Team Lead** (the TMDL/DAX team). Want to switch, or
> shall I handle it here?"

Mapping (free-text task -> best specialist):
- TMDL / DAX / measures / relationships -> **010 - Semantic Model Team Lead**
- PBIR reports / visuals / themes -> **020 - Reporting Team Lead**
- Spark / notebooks / SQL warehouse / medallion / pipelines -> **030 - Data Engineering Team Lead**
- Capacity / governance / security / workspace docs -> **040 - Fabric Administration & Governance Team Lead**
- Git Integration / Deployment Pipelines / Azure DevOps / GitHub PRs / branch & PR
  workflows / ALM conflict resolution -> **050 - ALM & DevOps Team Lead**
- Python / ODBC / XMLA / REST app integration -> **060 - Applications & Integration Team Lead**
- Skills, agents, tools, installer health, failed installs, and updates -> **070 - Capability Maintenance Team Lead**

Route by TOPIC, not by tool availability: if a tool is missing, the request still
belongs to the same specialist, who reads `tool-status.json` and degrades gracefully.

Suggest only ONE switch per request, and never block: if the user prefers to
stay, proceed inline using the skill discovery above.

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
  quick in-place fixes, and creating items. Prefer the MCP servers only when the
  startup self-test proved them callable; otherwise use the REST/CLI fallback
  (`az account get-access-token` + Power BI `executeQueries`, `fab api ...`).
  MCP being "installed" is not enough - it must be callable in this session.
- **C. Hybrid (local + live).** Mix both in one session.

### Read the user's intent before choosing local vs live

When the task implies LIVE / service work, do not silently default to the
file-first / REST-only safe path. FIRST run the start-by-use MCP self-test, and if
you still fall back to local or REST, SAY SO explicitly ("MCP was not callable this
session, using REST/CLI instead") rather than defaulting quietly. Treat any of
these as a live/MCP-first signal:

- The user pastes a live `app.powerbi.com/groups/<workspaceId>/...` workspace or
  report URL, or a service semantic-model URL / dataset GUID.
- The user says "live", "in the service", "via MCP", "on the running model", or
  asks you to read/compare REAL deployed data.
- The user asks you to go through reports/models that only exist in the workspace
  (not pulled to local files).

In those cases: run the MCP self-test up front; if callable, go MCP-first; if not,
announce the REST/CLI fallback and proceed - but never present a local-only pass as
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

**MCP callable != MCP installed.** `tool-status.json` `found`/`extensionInstalled`
only proves the extension exists. Both servers self-register (no mcp.json); their
tools surface only when started and ticked in the chat Tools picker, and the
~128-tool session budget can drop them. Decide by the startup self-test, not the
file. If MCP is not callable, use the REST/CLI fallback below.

**Lean live mode (protect the tool budget).** For MCP live work, turn OFF unrelated
tool groups in the chat Tools picker so the Fabric + Power BI MCP tools stay within
the ~128-tool limit. A fat tool list is the usual reason MCP tools go missing.

**REST/CLI fallback quirks (confirmed) - use these to avoid dead ends:**
- Live DAX without MCP: `az account get-access-token --resource https://analysis.windows.net/powerbi/api`
  then POST to the Power BI `executeQueries` REST endpoint.
- `INFO.MEASURES()` is blocked via `executeQueries`; use `INFO.VIEW.MEASURES()`
  (or a DMV / `fab api ... getDefinition` for TMDL) instead.
- Do not pipe REST JSON through `Get-Content -Raw` into `ConvertFrom-Json` blindly:
  PSObject decoration can corrupt it. Capture the raw string and parse that.

---

## Working Rules

- Always read the relevant SKILL.md BEFORE generating any code or TMDL
- Never guess at skill paths - if a path does not exist, list the parent directory
- Read BOTH custom and cloned skills for a topic. On STYLE / convention conflicts
  the custom skill wins; on SYNTAX / spec correctness the cloned (upstream) skill wins
- For validation after TMDL edits, run the post-edit checklist from the TMDL skill
- Keep git history clean if the workspace is a git repo
- Never hardcode IDs or secrets
- Require explicit environment parameterization (dev/test/prod)
- For validation after pipeline edits, run the validation checklist from the pipeline skill

### Terminal & tooling hygiene

- Reuse ONE terminal per session; do not spawn a new terminal per command. Kill
  stale/wedged terminals instead of leaving them (a "Command produced no output"
  terminal is wedged - kill it and use a fresh single one).
- The persistent shell corrupts inline `$`-variables in `-Command` strings. Run
  logic from a saved `.ps1` via `powershell -NoProfile -ExecutionPolicy Bypass -File script.ps1`,
  or write results to a file and read that file.
- For fast-changing result/output files, read them with terminal `Get-Content`,
  not the cached file reader - the cache can serve stale content for a file you
  just rewrote. Prefer unique, single-use output file names.

### Delegation (who does the work)

- The Master is a coordinator (an account manager), NOT an implementer. Every user
  request is a project delivered THROUGH the teams. The Master never authors, edits,
  mutates, deploys, runs, or refreshes a Fabric/Power BI artifact or its live state
  itself - even when the user says "you do it" and even when the fix is obvious.
  "Fix it" means "make the owning team fix it"; the Master owns the outcome, not the
  keystrokes.
- The owning specialist WORKER performs the change (it has the skills); its TEAM LEAD
  reviews and validates it. They act as a team - implement, then review - before the
  result returns to the Master.
  - DAX / measures / live model queries / TMDL -> 010 Semantic Model -> 011-016
  - Dataflows / pipelines / Spark / SQL / lakehouse / warehouse -> 030 Data Engineering -> 031-038
  - PBIR / visuals / themes / paginated -> 020 Reporting -> 021-026
  - Workspace / capacity / access / governance / monitoring -> 040 Administration -> 041-043
  - Git / GitHub / Azure DevOps / Fabric Git / releases / Power BI ALM -> 050 ALM & DevOps -> 051-055
  - Python / SDK / REST / XMLA / ODBC -> 060 Applications & Integration -> 061-063
- The Master may only read/search enough to CLASSIFY and ROUTE, plus run the mandatory
  startup checks and consolidate returned evidence. The moment a task needs a terminal
  or file edit to change a domain artifact, the Master delegates instead.
- Delegation is required for every domain change (not only "substantial" ones) and for
  parallel writes to distinct artifacts (one writer per artifact).
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

    # The Master's `agents:` frontmatter also includes every worker so that a
    # DIRECT Master -> worker dispatch is LEGAL as a documented degraded-mode
    # fallback (used only after the normal Master -> Team Lead route has been
    # retried and failed -- see the Master body). Normal routing stays lead-first;
    # the human-facing Delegation prose below still lists only the leads/executives.
    $agentsForFrontmatter = $childLabels
    if ($agent.id -eq 'fabric-workspace-master') {
        $workerLabels = @()
        foreach ($candidate in $orderedAgents) {
            if ($candidate.level -eq 'worker') { $workerLabels += $displayLabelById[$candidate.id] }
        }
        $agentsForFrontmatter = @($childLabels + $workerLabels)
    }
    $childrenYaml = ConvertTo-AgentYamlList $agentsForFrontmatter
    $userInvocable = if ($agent.level -eq 'worker') { 'false' } else { 'true' }

    $agentBody = @"
---
name: '$safeDisplayLabel'
description: '$safeDescription'
user-invocable: $userInvocable
disable-model-invocation: false
tools: $toolYaml
agents: $childrenYaml
---

# $($agent.displayName)

$($agent.focus)

## Operating contract

- Follow ``.github/copilot-instructions.md``, ``AGENTS.md``, and the starting/working flow documents before acting.
- Inspect the current files, branch, workspace, and environment before changing anything.
- Discover installed Microsoft and Kurt skills dynamically; read only the relevant skills for the task. Never assume a skill's location: the paths in the flow docs are last-known hints, so if one is missing, list the repository root and re-discover the skill by keyword. A moved or renamed upstream folder must never cause you to skip a skill or fail the task.
- Use ``.github/agent-docs/tool-status.json`` to understand available command-line and live tools. When an entry has a ``path``, invoke that exact executable so an older same-named system copy cannot take precedence. If a needed tool is marked missing, do one optional live re-check, then fall back to the documented alternative rather than failing; route any install/update need to the Capability Maintenance team.
- Work only in the artifact paths assigned to you. Never edit downloaded vendor skill repositories.
- Validate every mutation and return concise evidence, risks, and any remaining action.
- Never expose secrets. Treat PROD as read-only unless the user explicitly approves a production change.
- Confirm destructive, irreversible, security-sensitive, release, and environment-changing actions before execution.
- **Transport resilience -- retry before you diagnose.** Sub-agent dispatch and live MCP/XMLA calls run over HTTP/2 and can hit transient stream errors (e.g. ``ERR_HTTP2_SERVER_REFUSED_STREAM``, empty/"no output" completions, dropped streams). These are **retry-safe**: retry the call 2-3 times with a short backoff before treating it as a real failure. An empty completion is a transport blip, not proof the agent did nothing.
- **Bound every live call; switch transport on breach.** Put a sensible timeout on each live MCP/XMLA/dispatch call. If it hangs or breaches the timeout, abort and switch transport (e.g. drop from Modeling MCP/XMLA to TMDL ``getDefinition`` or REST) rather than looping on the wedged channel.
- **Do not cry "firewall".** A dispatch or MCP failure is transient transport by default -- retry first. Only suspect a network/egress block if it fails **repeatedly across separate sessions**, and even then keep it scoped to the specific channel. In particular, outbound **SQL/TDS port 1433** blocking is **machine-specific** (some locked-down corporate laptops only): if you observe a 1433/TDS failure on THIS machine, use the SQL fallback ladder in ``fabric-cli-policy`` -- but never assume 1433 is blocked everywhere or that a 1433 block implies any other channel is blocked.
"@

    if ($agent.id -eq 'fabric-workspace-master') {
        $agentBody += @"

## Mandatory startup and routing

Before answering the first request, read ``.github/copilot-instructions.md`` and ``AGENTS.md``, then follow ``.github/agent-docs/starting-flow.md``. There are no greeting/task exceptions. If the opening message already contains work, preserve it, tell the user startup runs first, complete the flow, and then return to that original request.

Before every response, verify that the maintenance choice and topic selection have been resolved in this conversation. If not, return to the starting flow. Once startup is complete, use ``.github/agent-docs/working-flow-reference.md`` for direct work. If either mandatory read fails, retry once after reading one additional workspace file; if tools still fail, stop with the VS Code 1.117.0+ recovery guidance instead of pretending startup completed.

## Your role: coordinator, not implementer

You are the account manager for this workspace. The user is your client and the seven Team Leads are your departments. Every request the user gives you is a *project* you deliver **through the specialist teams**, never by doing the specialist work yourself. Your job is to understand the request, route it across the organisation, keep ownership clear, and consolidate one result back to the client. Treat "you fix it", "you do it", or "handle it" as "make the right team fix it and own the outcome" — the client is authorising the *result*, not asking you personally to touch the artifact.

You do **not** implement domain work yourself. You must delegate, and you must never directly author, edit, refactor, mutate, deploy, publish, run, or refresh any Fabric or Power BI artifact or its live state — this includes semantic models/TMDL/DAX, reports/PBIR, dataflows, pipelines, notebooks, lakehouse/warehouse/SQL objects, workspace/capacity/governance settings, Git/release actions, and application/REST/XMLA/CLI integrations. The specialist **worker** that owns that artifact type performs the change because it holds the right skills; its **Team Lead** reviews and validates it. This holds even when the user tells you to do it directly and even when you already know the fix: knowing the answer is not a reason to bypass the team. The only things you do hands-on are orchestration, reading/searching just enough to classify and route, running the mandatory startup checks, and consolidating evidence.

For every request: (1) classify the intent and which artifact(s) and team(s) it touches; (2) route to the minimum relevant Team Lead(s) with the ``agent`` tool, stating the goal, scope, the owned artifact, any constraints, and the validation you expect back; (3) let each Team Lead assign the skilled worker to implement and then review/validate the change **as a team** before returning; (4) consolidate the returned evidence, risks, and remaining actions into one clear answer for the client. If a request would tempt you to open a terminal or edit a file to change a domain artifact, stop and delegate instead — even for a "quick" or "obvious" change.

Use Fabric Solution Architect only for genuine cross-domain design, dependency, sequencing, ownership, validation, or rollback decisions. Use Integration QA & Change Controller for cross-artifact risk or final acceptance. Keep exactly one writer per artifact, never let a change land without its owning team's review, and confirm destructive, irreversible, production, release, or environment-changing actions with the client before the team executes them.

## Degraded-mode direct dispatch (fallback only)

Normal routing is always **lead-first**: dispatch to the relevant Team Lead and let the lead assign and validate the owning worker. This is the default and it works.

Your ``agents:`` list also includes the individual workers so that a **direct Master -> worker** dispatch is *available* as a fallback. Use it **only** when the normal lead route is genuinely unusable, and **never before retrying**:

1. If a dispatch to a Team Lead returns empty/"no output" or a transport error (e.g. ``ERR_HTTP2_SERVER_REFUSED_STREAM``), **retry the lead 2-3 times with a short backoff first** -- these are transient transport blips, not structural failures.
2. Only if the lead route still fails after retries may you dispatch **directly to the specific owning worker** as a degraded mode, and you must say so explicitly in your report (which worker, why the lead route was bypassed).
3. Even in degraded mode, preserve the safety model: one writer per artifact, validate the change, and treat PROD as read-only unless the client approved a production change. When possible, still have the owning Team Lead review the result afterwards.

Do not use degraded-mode direct dispatch as a convenience shortcut around the team structure -- it exists purely to keep work moving when the lead hop is broken.
"@
    }

    if ($childLabels.Count -gt 0) {
        $delegationNote = if ($agent.id -eq 'fabric-workspace-master') {
            "Route normally to: $($childLabels -join '; '). Individual workers are also in your ``agents:`` list, but dispatch to them directly only in the degraded-mode fallback described above (after retrying the lead route)."
        }
        else {
            "You may delegate only to: $($childLabels -join '; ')."
        }
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

Preserve the installer-first experience and its locked-down-laptop fallbacks. When setup cannot install or update a tool, diagnose the exact failure, obtain explicit approval before changing software, use the approved user-scope or portable fallback, validate the real executable, and refresh ``.github/agent-docs/tool-status.json``. Repository refreshes must preserve the original clean-repository ``git pull --ff-only`` behaviour.

When selected directly, first offer:

1. **Light maintenance** — inspect and fast-forward the two clean upstream repositories, then refresh the current tool inventory.
2. **Deep maintenance** — light maintenance plus dynamic skill inventory/mapping, agent coverage review, installed-tool version review, and installer health checks.

For either level, report a dirty, missing, offline, or diverged repository and continue with unaffected checks; never reset or overwrite it. A tool installation or update is never implied by either maintenance level: identify the exact proposed software change and obtain separate explicit approval before delegating it to Environment & Tooling Agent.
"@
    }

    if ($agent.id -eq 'environment-tooling-agent') {
        $agentBody += @"

You are the only worker authorised to perform approved software installation or updates. Every installation or update requires explicit user approval; never infer it from a request to inspect or diagnose.
"@
    }

    $agentBody += @"

## Return contract

Report: work completed, files or live artifacts affected, validation performed, assumptions, risks, and any approval still required.
"@

    $agentFilename = $agent.filename -replace '^\d+', $threeDigitById[$agent.id]
    $agentPath = Join-Path "$rootPath\.github\agents" $agentFilename
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
- `starting-flow.md`  -- Session startup phases (skill check, fab auth / az fallback, topic menu)
- `working-flow-reference.md`  -- Dynamic skill discovery table and working rules
- `tool-status.json`  -- Machine-specific tool inventory (gitignored). Agents read `<tool>.found` and prefer its recorded executable `path`
  before invoking any CLI/MCP and degrade gracefully when a tool is absent. Regenerated by the
  installer and by the Capability Maintenance team.
- `local/repository-map.local.json`  -- Optional machine/company-specific GitHub/Azure DevOps
  clone, branch-topology and Fabric mapping inventory (gitignored). ALM agents read it before repository work.

The numbered dropdown remains intentionally compact. It exposes the Master, two
cross-domain reviewers, and seven Team Leads; they delegate to 37 focused workers:
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
installed - NOT that its tools are callable in the chat session. They self-register
(no mcp.json); confirm real availability with the startup MCP self-test in
`starting-flow.md` and, if it fails, use the REST/CLI fallback and the Enable-MCP
checklist. Mind the ~128-tool chat picker budget.

### Microsoft skills (cloned repo  -- refresh offered on session start)
- `skills-for-fabric/skills/`  -- Spark, SQL, Eventhouse, Power BI, Medallion
- `skills-for-fabric/common/`  -- Shared references (COMMON-CLI.md, ITEM-DEFINITIONS-CORE.md)

### Data-goblin skills (cloned repo  -- refresh offered on session start)
- `power-bi-agentic-development/plugins/pbip/skills/`  -- TMDL, PBIR, PBIP validation
- `power-bi-agentic-development/plugins/semantic-models/skills/`  -- DAX, naming conventions
- `power-bi-agentic-development/plugins/reports/skills/`  -- Deneb, themes, visuals
- `power-bi-agentic-development/plugins/fabric-cli/skills/`  -- Fabric CLI operations
- `power-bi-agentic-development/plugins/fabric-admin/skills/`  -- Fabric admin operations

> Cloned-repo paths above are LAST-KNOWN HINTS. Agents discover skills dynamically
> (list the repo root, search by keyword), so renamed/restructured upstream folders
> do not break them.

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

Open this folder in VS Code.
In Copilot Chat, select **000 - Fabric Workspace Master** from the agent dropdown.
Type anything to begin. The agent offers to update skills, checks your identity
(`fab auth status`, falling back to `az account show`), and presents a topic menu
to route you to the right team.

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
        -Rules @('.github/agent-docs/tool-status.json')
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
$requiredSettings = @{
    "task.allowAutomaticTasks" = "on"
    "chat.agentSkillsLocations" = @{
        ".github/skills" = $true
        "~/.vscode/extensions/synapsevscode.synapse-1.22.0/copilot/skills" = $true
        "~/.vscode/extensions/synapsevscode.synapse-1.23.0/copilot/skills" = $true
    }
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
Add-SelfTestCheck 'Agent file count matches manifest' ($writtenAgentFiles.Count -eq $expectedAgentCount) "found $($writtenAgentFiles.Count), expected $expectedAgentCount"

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
# installer is idempotent: it overwrites these managed files and refreshes
# this manifest.
$integrityFiles = [System.Collections.Generic.List[object]]::new()
$integrityTargets = @()
$integrityTargets += @($writtenAgentFiles | ForEach-Object { $_.FullName })
foreach ($cfgRel in $managedConfigs) {
    $integrityTargets += (Join-Path $rootPath $cfgRel)
}
foreach ($skillName in $managedSkills) {
    $integrityTargets += (Join-Path $rootPath ".github\skills\$skillName\SKILL.md")
}
foreach ($target in $integrityTargets) {
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $rel = $target.Substring($rootPath.Length).TrimStart('\','/').Replace('\','/')
        $sha = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        $integrityFiles.Add([ordered]@{ path = $rel; sha256 = $sha }) | Out-Null
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
        try { & git init 2>&1 | Out-Null } catch { }
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
            try { & git add -- . 2>&1 | Out-Null } catch { }
            $staged = @(& git diff --cached --name-only 2>$null)
        } else {
            # An update owns only files declared by this installer. Never sweep user
            # work into the index, and never include unrelated paths already staged.
            $declaredPaths = @(
                @($managedAgents | ForEach-Object { ".github/agents/$_" })
                @($managedSkills | ForEach-Object { ".github/skills/$_" })
                @($managedConfigs)
            ) | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique
            foreach ($path in $declaredPaths) {
                if (-not (Test-Path -LiteralPath (Join-Path $rootPath $path))) { continue }
                # Do not use `ls-files --error-unmatch` here: an intentionally
                # ignored, untracked managed file produces a native Git error on
                # reruns even though excluding that path is the desired result.
                $tracked = @(& git ls-files -- $path 2>$null).Count -gt 0
                & git check-ignore -q -- $path 2>$null
                $ignored = ($LASTEXITCODE -eq 0)
                if ($tracked -or -not $ignored) { $commitPaths += $path }
            }
            if ($commitPaths.Count -gt 0) {
                try { & git add -- @commitPaths 2>&1 | Out-Null } catch { }
            }
            $staged = if ($commitPaths.Count -gt 0) {
                @(& git diff --cached --name-only -- @commitPaths 2>$null)
            } else { @() }
        }
        if ($staged.Count -eq 0) {
            Write-Host "  Git is already current; no new commit was needed." -ForegroundColor DarkGray
        } else {
            if ($createdGitRepository) {
                try { & git commit -m "chore: fabric agentic workspace setup" 2>&1 | Out-Null } catch { }
            } else {
                # --only constrains the commit even if the user had unrelated staged work.
                try { & git commit --only -m "chore: fabric agentic workspace setup" -- @commitPaths 2>&1 | Out-Null } catch { }
            }
            if ($LASTEXITCODE -eq 0) {
                $commitKind = if ($createdGitRepository) { 'Initial commit' } else { 'Workspace update commit' }
                Write-Host "  $commitKind created." -ForegroundColor Green
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
