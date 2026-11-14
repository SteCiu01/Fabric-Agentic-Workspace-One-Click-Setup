# CLI Functionalities — Deep Dive

> **TL;DR** — The core workspace (Fabric VS Code extension + agents editing local
> files) needs **no CLI**. Installing a CLI adds terminal and control-plane /
> data-plane power on top. This workspace standardises on the **Fabric CLI
> (`fab`)**; **Azure CLI (`az`)** is a documented **fallback** for the few things
> `fab` does not cover (SQL/TDS queries and non-Fabric token audiences). On top of
> those two, a handful of **opt-in specialist CLIs** (`pbir`, Tabular Editor CLI,
> `pbi-tools`, `sqlcmd`, `gh`, `az devops`) give individual agents extra power for
> reports, semantic models, SQL, and ALM — installed only if you say yes at setup.

This document is a practical, opinionated catalogue of the CLI actions that are
most useful in this workspace. It focuses on the commands a Fabric developer is
most likely to reach for during local, live, or hybrid agent-assisted work:
identity checks, item export/import, job runs, REST calls, OneLake/table
operations, Git/ALM tasks, report and model automation, and the few fallback
cases where `az` or `sqlcmd` are still the better tool.

It is not intended to be a permanent exhaustive reference for every Fabric,
Power BI, Azure, or SQL command. Command groups and flags evolve, especially
around newer Fabric APIs and the newer/preview specialist CLIs. Treat the
examples here as the high-value working set, then confirm exact syntax with
`fab --help`, `fab <group> --help`, each specialist tool's own `--help`/`-?`,
the Azure CLI help, or the official references linked below.

### How this document is organized

- **Part I — Fabric platform CLIs (`fab` + `az` fallback).** The original, workload-first
  deep dive (sections 0–21): every way of working may touch these two CLIs.
- **Part II — Specialist CLIs (one chapter each).** Opt-in tools owned by individual
  agents (sections 22–27). Each is detected, explained, and installed Y/N at setup, and
  gated at runtime by `.github/agent-docs/tool-status.json` (`<key>.found`). None is
  required for the core local-editing workflow.

Install / detection:

- **`fab`** (recommended): `pip install ms-fabric-cli` (Python 3.10–3.14). Repo: https://github.com/microsoft/fabric-cli
- **`az`** (fallback): https://aka.ms/installazurecli
- **Specialist CLIs**: the installer detects each, prints its provider + purpose, and
  asks Y/N before a best-effort install (see the README **Prerequisites** table and each
  Part II chapter). Provider links are listed per chapter below.

Official references:

- Microsoft Fabric CLI: https://github.com/microsoft/fabric-cli
- Microsoft Fabric REST API: https://learn.microsoft.com/en-us/rest/api/fabric/
- Microsoft Fabric Git integration: https://learn.microsoft.com/en-us/fabric/cicd/git-integration/intro-to-git-integration
- Microsoft Fabric Data Factory activity overview: https://learn.microsoft.com/en-us/fabric/data-factory/activity-overview
- Microsoft Fabric VS Code extension: https://marketplace.visualstudio.com/items?itemName=fabric.vscode-fabric
- Azure CLI reference: https://learn.microsoft.com/en-us/cli/azure/
- Tabular Editor CLI: https://docs.tabulareditor.com
- pbi-tools: https://pbi.tools
- `pbir` CLI: data-goblin `power-bi-agentic-development` (`reports/skills/pbir-cli`)
- GitHub CLI (`gh`): https://cli.github.com/manual/
- Azure DevOps CLI: https://learn.microsoft.com/en-us/azure/devops/cli/

The agents read `.github/skills/fabric-cli-policy/SKILL.md` for the decision rule
before any CLI/REST task. This file is the human-readable companion to that skill.

---

## Table of contents

**Part I — Fabric platform CLIs (`fab` + `az` fallback)**

- [0. Authentication & identity](#0-authentication--identity)
- [1. Power BI / semantic model authoring](#1-power-bi--semantic-model-authoring)
- [2. Report development](#2-report-development)
- [3. Notebooks & Spark](#3-notebooks--spark)
- [4. Dataflows & pipelines (orchestration)](#4-dataflows--pipelines-orchestration)
- [5. Tables & OneLake (data plane)](#5-tables--onelake-data-plane)
- [6. Admin & governance](#6-admin--governance)
- [7. Raw REST API access](#7-raw-rest-api-access)
- [8. SQL / TDS query (az / sqlcmd fallback)](#8-sql--tds-query-az--sqlcmd-fallback)
- [9. Tokens for non-Fabric audiences (az fallback)](#9-tokens-for-non-fabric-audiences-az-fallback)
- [10. Interactive shell & navigation](#10-interactive-shell--navigation)
- [11. Workspace & item lifecycle](#11-workspace--item-lifecycle)
- [12. Lakehouses, warehouses & SQL databases](#12-lakehouses-warehouses--sql-databases)
- [13. Real-Time Intelligence (Eventhouse / KQL / Eventstream)](#13-real-time-intelligence-eventhouse--kql--eventstream)
- [14. Environments, Spark pools & libraries](#14-environments-spark-pools--libraries)
- [15. ALM: Git integration & deployment pipelines](#15-alm-git-integration--deployment-pipelines)
- [16. Domains](#16-domains)
- [17. Connections, gateways & credentials](#17-connections-gateways--credentials)
- [18. ML models & experiments](#18-ml-models--experiments)
- [19. Capacity management](#19-capacity-management)
- [20. Item permissions & sensitivity labels](#20-item-permissions--sensitivity-labels)
- [21. Config & scripting tips](#21-config--scripting-tips)
- [Quick reference: `az rest` → `fab api`](#quick-reference-az-rest--fab-api)

**Part II — Specialist CLIs (opt-in, agent-owned)**

- [22. `pbir` — Power BI report CLI](#22-pbir--power-bi-report-cli)
- [23. Tabular Editor CLI — semantic-model validation & deployment](#23-tabular-editor-cli--semantic-model-validation--deployment)
- [24. `pbi-tools` — PBIX/PBIP source control & build](#24-pbi-tools--pbixpbip-source-control--build)
- [25. `sqlcmd` — T-SQL over the Fabric SQL endpoint](#25-sqlcmd--t-sql-over-the-fabric-sql-endpoint)
- [26. `gh` — GitHub CLI](#26-gh--github-cli)
- [27. `az devops` — Azure DevOps CLI](#27-az-devops--azure-devops-cli)
- [28. `pbiviz` — Power BI custom visual tools](#28-pbiviz--power-bi-custom-visual-tools)
- [29. Git for the PBIVIZ repository — `Pbiviz-Alm.ps1`](#29-git-for-the-pbiviz-repository--pbiviz-almps1)

---

# Part I — Fabric platform CLIs (`fab` + `az` fallback)

The sections below are the original, **workload-first** deep dive. `fab` is the
default for control-plane and data-plane work; `az` (and `sqlcmd`) appear only in
the documented fallback cases. Every way of working — local, live, or hybrid — may
touch these two CLIs.

## 0. Authentication & identity

| What | Example |
|------|---------|
| Sign in interactively | `fab auth login` |
| Sign in with a service principal | `fab auth login -u <appId> -p <secret> --tenant <tenantId>` |
| Check who you are | `fab auth status` |
| Sign out | `fab auth logout` |
| **Fallback** — Azure login | `az login` |
| **Fallback** — check Azure identity | `az account show --output table` |

> `fab` and `az` keep separate token caches. For Fabric work, `fab auth login` is
> enough — you do not also need `az login` unless you hit a fallback case.

---

## 1. Power BI / semantic model authoring

Most semantic-model *authoring* happens by editing local **TMDL** files (the agents
+ TMDL extension). The CLI shines for **moving** models in and out of the service.

| What | Example |
|------|---------|
| List semantic models in a workspace | `fab api workspaces/<wsId>/semanticModels -q "value[].displayName"` |
| Export a semantic model as a PBIP/TMDL definition | `fab export <ws>/<model>.SemanticModel -o ./export` |
| Import / deploy a local model definition | `fab import <ws>/<model>.SemanticModel -i ./model` |
| Get a model's definition payload | `fab api workspaces/<wsId>/semanticModels/<id>/getDefinition --method post` |
| Trigger a dataset refresh | `fab api workspaces/<wsId>/semanticModels/<id>/refreshes --method post` |
| Check refresh history | `fab api workspaces/<wsId>/semanticModels/<id>/refreshes -q "value[0]"` |
| Bind to a gateway / data source | `fab api ... --method post --input gateway-binding.json` |

> For DAX/TMDL *editing* depth, the agents use the `fabric-tmdl` skill and the
> data-goblin `semantic-models` plugin — no CLI needed.

---

## 2. Report development

Report authoring is **PBIR** file editing (data-goblin `reports` skill). The CLI
handles deployment and lifecycle.

| What | Example |
|------|---------|
| List reports | `fab api workspaces/<wsId>/reports -q "value[].displayName"` |
| Export a report definition (PBIR) | `fab export <ws>/<report>.Report -o ./export` |
| Import / deploy a report | `fab import <ws>/<report>.Report -i ./report` |
| Rebind a report to another semantic model | `fab api workspaces/<wsId>/reports/<id>/rebind --method post --input rebind.json` |
| Clone a report | `fab api workspaces/<wsId>/reports/<id>/clone --method post --input clone.json` |

---

## 3. Notebooks & Spark

| What | Example |
|------|---------|
| List notebooks | `fab api workspaces/<wsId>/notebooks -q "value[].displayName"` |
| Run a notebook on demand | `fab job run <ws>/<notebook>.Notebook` |
| Run with parameters | `fab job run <ws>/<notebook>.Notebook --input params.json` |
| Check a notebook run status | `fab job run-status <ws>/<notebook>.Notebook --id <jobInstanceId>` |
| Schedule a notebook job | `fab job run-sch <ws>/<notebook>.Notebook --input schedule.json` |
| Export a notebook definition | `fab export <ws>/<notebook>.Notebook -o ./export` |
| Import a notebook | `fab import <ws>/<notebook>.Notebook -i ./notebook` |
| List Spark livy sessions | `fab api workspaces/<wsId>/spark/livySessions -q "value[].state"` |

---

## 4. Dataflows & pipelines (orchestration)

Pipeline JSON authoring is local (the `fabric-pipelines` skill). The CLI triggers
and monitors runs.

| What | Example |
|------|---------|
| List data pipelines | `fab api workspaces/<wsId>/dataPipelines -q "value[].displayName"` |
| Run a pipeline | `fab job run <ws>/<pipeline>.DataPipeline` |
| Run a pipeline with parameters | `fab job run <ws>/<pipeline>.DataPipeline --input params.json` |
| Check pipeline run status | `fab job run-status <ws>/<pipeline>.DataPipeline --id <jobId>` |
| Cancel a running job | `fab job run-cancel <ws>/<item> --id <jobId>` |
| List dataflows (Gen2) | `fab api workspaces/<wsId>/dataflows -q "value[].displayName"` |
| Refresh a dataflow | `fab job run <ws>/<dataflow>.Dataflow` |
| Export a pipeline definition | `fab export <ws>/<pipeline>.DataPipeline -o ./export` |

---

## 5. Tables & OneLake (data plane)

| What | Example |
|------|---------|
| List OneLake files in a lakehouse | `fab ls <ws>/<lakehouse>.Lakehouse/Files` |
| Copy a local file into OneLake | `fab cp ./data.csv <ws>/<lakehouse>.Lakehouse/Files/raw/data.csv` |
| Copy a file out of OneLake | `fab cp <ws>/<lakehouse>.Lakehouse/Files/raw/data.csv ./data.csv` |
| Remove a OneLake file | `fab rm <ws>/<lakehouse>.Lakehouse/Files/raw/old.csv` |
| List delta tables | `fab ls <ws>/<lakehouse>.Lakehouse/Tables` |
| Load a file into a delta table | `fab table load <ws>/<lakehouse>.Lakehouse/Tables/sales --file Files/raw/sales.csv` |
| Optimize a delta table | `fab table optimize <ws>/<lakehouse>.Lakehouse/Tables/sales` |
| Vacuum a delta table | `fab table vacuum <ws>/<lakehouse>.Lakehouse/Tables/sales --retain-hours 168` |
| Inspect a table schema | `fab table schema <ws>/<lakehouse>.Lakehouse/Tables/sales` |
| Create / manage a shortcut | `fab api workspaces/<wsId>/items/<id>/shortcuts --method post --input shortcut.json` |

---

## 6. Admin & governance

| What | Example |
|------|---------|
| List all workspaces you can see | `fab api workspaces -q "value[].displayName"` |
| Get workspace details | `fab api workspaces/<wsId>` |
| List role assignments (RBAC) | `fab api workspaces/<wsId>/roleAssignments -q "value[].{p:principal.displayName,r:role}"` |
| Assign a workspace role | `fab api workspaces/<wsId>/roleAssignments --method post --input role.json` |
| List capacities | `fab api capacities -q "value[].{name:displayName,sku:sku}"` |
| Assign a workspace to a capacity | `fab api workspaces/<wsId>/assignToCapacity --method post --input capacity.json` |
| List all items in a workspace | `fab api workspaces/<wsId>/items -q "value[].{name:displayName,type:type}"` |
| Admin: tenant-wide item scan | `fab api admin/workspaces -q "value[].name"` |
| Admin: list tenant settings | `fab api admin/tenantsettings -q "tenantSettings[].settingName"` |
| Get activity / audit events | `fab api admin/activityEvents --method get` |

> Admin endpoints require the appropriate Fabric/Power BI admin role.

---

## 7. Raw REST API access

When a specific endpoint is not surfaced by a higher-level `fab` command, call it
directly. `fab api` handles auth automatically and supports JMESPath filtering.

| What | Example |
|------|---------|
| GET any Fabric endpoint | `fab api workspaces/<wsId>/items/<id>` |
| POST with a JSON body | `fab api workspaces/<wsId>/items --method post --input item.json` |
| PATCH an item | `fab api workspaces/<wsId>/items/<id> --method patch --input update.json` |
| DELETE an item | `fab api workspaces/<wsId>/items/<id> --method delete` |
| Filter the response | `fab api workspaces -q "value[?type=='Lakehouse'].displayName"` |
| **Fallback** — uncovered endpoint via `az` | `az rest --method get --url https://api.fabric.microsoft.com/v1/<endpoint> --resource https://api.fabric.microsoft.com` |

---

## 8. SQL / TDS query (az / sqlcmd fallback)

`fab` does not run T-SQL queries against the SQL endpoint. Use `sqlcmd` with an
AAD/Entra token (`-G`), or your preferred SQL client.

| What | Example |
|------|---------|
| Query a Warehouse / Lakehouse SQL endpoint | `sqlcmd -G -S <endpoint>.datawarehouse.fabric.microsoft.com -d <db> -Q "SELECT TOP 10 * FROM dbo.sales"` |
| Run a SQL script file | `sqlcmd -G -S <endpoint> -d <db> -i script.sql` |
| Python (pyodbc) with Entra token | `conn = pyodbc.connect(connstr, attrs_before={1256: token})` |

---

## 9. Tokens for non-Fabric audiences (az fallback)

`fab` issues tokens for the Fabric audience. For **other** Azure audiences, use `az`.

| What | Example |
|------|---------|
| Storage (ADLS / Blob) token | `az account get-access-token --resource https://storage.azure.com` |
| Azure SQL Database token | `az account get-access-token --resource https://database.windows.net` |
| Azure Key Vault token | `az account get-access-token --resource https://vault.azure.net` |
| Generic resource token | `az account get-access-token --resource <audience-uri> -q accessToken -o tsv` |

---

## 10. Interactive shell & navigation

`fab` works both as one-shot commands (`fab <command>`) and as an interactive
shell where you navigate workspaces/items like a filesystem.

| What | Example |
|------|---------|
| Open the interactive shell | `fab` |
| List items at the current level | `fab ls` |
| Change "directory" into a workspace | `fab cd <ws>.Workspace` |
| Show current location | `fab pwd` |
| Inspect an item's properties | `fab get <ws>/<item>.Notebook -q .` |
| Set an item property | `fab set <ws>/<item>.Notebook -q displayName -i "New name"` |
| Open an item in the browser | `fab open <ws>/<item>.Report` |
| Show help for any command | `fab <command> --help` |
| Run a one-shot command from a script | `fab -c "api workspaces -q value[].displayName"` |

---

## 11. Workspace & item lifecycle

| What | Example |
|------|---------|
| Create a workspace | `fab create <name>.Workspace` |
| Create a workspace on a capacity | `fab create <name>.Workspace -P capacityName=<cap>` |
| Create an item (generic) | `fab create <ws>/<item>.Lakehouse` |
| Rename / update an item | `fab set <ws>/<item>.Notebook -q displayName -i "Renamed"` |
| Delete an item | `fab rm <ws>/<item>.Notebook` |
| Delete a workspace | `fab rm <ws>.Workspace` |
| Copy an item between workspaces | `fab cp <src-ws>/<item>.Notebook <dst-ws>/<item>.Notebook` |
| Export any item definition | `fab export <ws>/<item>.<Type> -o ./export` |
| Import any item definition | `fab import <ws>/<item>.<Type> -i ./folder` |

---

## 12. Lakehouses, warehouses & SQL databases

| What | Example |
|------|---------|
| Create a lakehouse | `fab create <ws>/sales.Lakehouse` |
| Create a lakehouse with schemas enabled | `fab create <ws>/sales.Lakehouse -P enableSchemas=true` |
| Create a warehouse | `fab create <ws>/dw.Warehouse` |
| Create a Fabric SQL database | `fab create <ws>/appdb.SQLDatabase` |
| Get a warehouse SQL connection string | `fab get <ws>/dw.Warehouse -q properties.connectionString` |
| List mirrored databases | `fab api workspaces/<wsId>/mirroredDatabases -q "value[].displayName"` |
| Start mirroring | `fab api workspaces/<wsId>/mirroredDatabases/<id>/startMirroring --method post` |
| Get mirroring status | `fab api workspaces/<wsId>/mirroredDatabases/<id>/getMirroringStatus --method post` |

> Running T-SQL **queries** against these endpoints is a fallback case — see
> [section 8](#8-sql--tds-query-az--sqlcmd-fallback).

---

## 13. Real-Time Intelligence (Eventhouse / KQL / Eventstream)

| What | Example |
|------|---------|
| Create an eventhouse | `fab create <ws>/rt.Eventhouse` |
| List KQL databases | `fab api workspaces/<wsId>/kqlDatabases -q "value[].displayName"` |
| Create a KQL database | `fab create <ws>/telemetry.KQLDatabase` |
| Export a KQL queryset definition | `fab export <ws>/<qs>.KQLQueryset -o ./export` |
| List eventstreams | `fab api workspaces/<wsId>/eventstreams -q "value[].displayName"` |
| Get an eventstream topology | `fab api workspaces/<wsId>/eventstreams/<id>/topology` |
| Pause / resume an eventstream source | `fab api workspaces/<wsId>/eventstreams/<id>/sources/<srcId>/pause --method post` |
| List reflex (Activator) items | `fab api workspaces/<wsId>/reflexes -q "value[].displayName"` |

---

## 14. Environments, Spark pools & libraries

| What | Example |
|------|---------|
| List environments | `fab api workspaces/<wsId>/environments -q "value[].displayName"` |
| Create an environment | `fab create <ws>/spark-env.Environment` |
| Publish an environment | `fab api workspaces/<wsId>/environments/<id>/staging/publish --method post` |
| Get published Spark compute settings | `fab api workspaces/<wsId>/environments/<id>/sparkcompute` |
| Upload a custom library to an environment | `fab api workspaces/<wsId>/environments/<id>/staging/libraries --method post --input lib.json` |
| List custom (workspace) Spark pools | `fab api workspaces/<wsId>/spark/pools -q "value[].name"` |
| Get workspace Spark settings | `fab api workspaces/<wsId>/spark/settings` |

---

## 15. ALM: Git integration & deployment pipelines

| What | Example |
|------|---------|
| Connect a workspace to Git | `fab api workspaces/<wsId>/git/connect --method post --input git.json` |
| Get Git connection status | `fab api workspaces/<wsId>/git/connection` |
| Get incoming/outgoing changes | `fab api workspaces/<wsId>/git/status` |
| Commit workspace changes to Git | `fab api workspaces/<wsId>/git/commitToGit --method post --input commit.json` |
| Update workspace from Git | `fab api workspaces/<wsId>/git/updateFromGit --method post --input update.json` |
| List deployment pipelines | `fab api deploymentPipelines -q "value[].displayName"` |
| Get pipeline stages | `fab api deploymentPipelines/<id>/stages -q "value[].displayName"` |
| Deploy between stages | `fab api deploymentPipelines/<id>/deploy --method post --input deploy.json` |

---

## 16. Domains

| What | Example |
|------|---------|
| List domains | `fab api admin/domains -q "value[].displayName"` |
| Create a domain | `fab api admin/domains --method post --input domain.json` |
| List workspaces in a domain | `fab api admin/domains/<id>/workspaces -q "value[].displayName"` |
| Assign workspaces to a domain | `fab api admin/domains/<id>/assignWorkspaces --method post --input assign.json` |
| Assign domain contributors | `fab api admin/domains/<id>/roleAssignments/bulkAssign --method post --input roles.json` |

---

## 17. Connections, gateways & credentials

| What | Example |
|------|---------|
| List connections | `fab api connections -q "value[].displayName"` |
| Create a connection | `fab api connections --method post --input connection.json` |
| List gateways | `fab api gateways -q "value[].displayName"` |
| Get gateway members | `fab api gateways/<id>/members -q "value[].displayName"` |
| List a connection's role assignments | `fab api connections/<id>/roleAssignments` |
| Delete a connection | `fab api connections/<id> --method delete` |

> Store secrets outside the repo (Key Vault / env vars). Never commit credentials.

---

## 18. ML models & experiments

| What | Example |
|------|---------|
| List ML models | `fab api workspaces/<wsId>/mlModels -q "value[].displayName"` |
| Create an ML model | `fab create <ws>/churn.MLModel` |
| List ML experiments | `fab api workspaces/<wsId>/mlExperiments -q "value[].displayName"` |
| Create an experiment | `fab create <ws>/exp1.MLExperiment` |
| List notebook-backed Spark job definitions | `fab api workspaces/<wsId>/sparkJobDefinitions -q "value[].displayName"` |
| Run a Spark job definition | `fab job run <ws>/<sjd>.SparkJobDefinition` |

---

## 19. Capacity management

Listing/assigning Fabric capacities is `fab`. **Pausing/resuming or scaling** the
underlying Azure capacity resource is an Azure control-plane action → use `az`.

| What | Example |
|------|---------|
| List Fabric capacities | `fab api capacities -q "value[].{name:displayName,sku:sku,state:state}"` |
| Assign a workspace to a capacity | `fab api workspaces/<wsId>/assignToCapacity --method post --input cap.json` |
| Unassign a workspace from capacity | `fab api workspaces/<wsId>/unassignFromCapacity --method post` |
| **az** — pause a capacity | `az fabric capacity suspend --resource-group <rg> --capacity-name <cap>` |
| **az** — resume a capacity | `az fabric capacity resume --resource-group <rg> --capacity-name <cap>` |
| **az** — scale a capacity SKU | `az fabric capacity update --resource-group <rg> --capacity-name <cap> --sku F4` |

---

## 20. Item permissions & sensitivity labels

| What | Example |
|------|---------|
| Get item role assignments / shares | `fab api workspaces/<wsId>/items/<id>/dataAccessRoles` |
| Set workspace role for a user | `fab api workspaces/<wsId>/roleAssignments --method post --input role.json` |
| Apply a sensitivity label (admin) | `fab api admin/items/setLabels --method post --input labels.json` |
| Remove sensitivity labels (admin) | `fab api admin/items/removeLabels --method post --input items.json` |
| Get item tags | `fab api workspaces/<wsId>/items/<id> -q "tags"` |

---

## 21. Config & scripting tips

| What | Example |
|------|---------|
| Show/Set CLI config | `fab config get` / `fab config set <key> <value>` |
| Default output to JSON | `fab config set output_format json` |
| Filter any response with JMESPath | `fab api workspaces -q "value[?type=='Lakehouse'].displayName"` |
| Capture a value into a variable (PowerShell) | `$ws = fab api workspaces -q "value[0].id"` |
| Loop over items in a script | `fab api workspaces -q "value[].id" \| ForEach-Object { fab api "workspaces/$_" }` |
| Suppress prompts in automation | use explicit IDs/paths and `--input <file>` instead of interactive prompts |

> Command names and flags evolve — always confirm with `fab <group> --help`.

---

## Quick reference: `az rest` → `fab api`

| Task | az (old) | fab (preferred) |
|------|----------|-----------------|
| List workspaces | `az rest --method get --resource https://api.fabric.microsoft.com --url https://api.fabric.microsoft.com/v1/workspaces` | `fab api workspaces` |
| Get one item | `az rest --method get --url .../v1/workspaces/<wsId>/items/<id>` | `fab api workspaces/<wsId>/items/<id>` |
| Filter output | `... -q "value[].displayName"` | `fab api workspaces -q "value[].displayName"` |
| Run a notebook job | n/a (raw REST polling) | `fab job run <ws>/<notebook>.Notebook` |
| Check job status | raw REST polling | `fab job run-status <ws>/<item> --id <jobId>` |

> Command names and flags evolve. Run `fab --help`, `fab <group> --help`, or check
> the data-goblin references under
> `power-bi-agentic-development/plugins/fabric-cli/skills/fabric-cli/` for the
> current syntax. When in doubt, the agents discover the exact commands dynamically.

---

# Part II — Specialist CLIs (opt-in, agent-owned)

The tools below sit **on top of** `fab`/`az`. Each is an opt-in specialist: the
installer detects it, prints its provider and purpose, and asks **Y/N** before a
best-effort install (see the README **Prerequisites** table). Each is **owned by one
team/worker agent** and gated at runtime by `.github/agent-docs/tool-status.json` — an
agent reads `<key>.found` first, optionally does one live `--version`/`Get-Command`
re-check, then falls back gracefully when the tool is absent. **None of these is
required for the core local-editing workflow.**

> Exceptions: the custom visual toolchain (§28) is **detected only** — the installer never
> installs Node.js, npm or `pbiviz` — and §29 is a script the installer ships, not a CLI.

> The newer/niche tools (`pbir`, the Tabular Editor CLI, `pbi-tools`) move quickly and
> some are in preview. The tables below are an accurate **working set** taken from each
> provider's own docs — always confirm exact flags with the tool's `--help`/`-?` and the
> linked provider reference before scripting against them.

---

## 22. `pbir` — Power BI report CLI

**Purpose** — Create, explore, edit, format, validate and publish **PBIR** reports
(`.pbir`/`.pbip`, or PBIX-with-PBIR-metadata) from the terminal, plus a Windows-only
bridge that drives an open Power BI Desktop (reload the canvas, screenshot pages).

| | |
|---|---|
| **Owned by** | **020 Reporting Team Lead**, via **022 PBIR Authoring Agent**. **055 Power BI ALM Agent** may *read* the `pbir-format` skill for PR/conflict review only — it does not author reports. |
| **tool-status.json key** | `pbir` (aliases checked: `pbir`, `pbir-cli`) |
| **Provider** | data-goblin / Kurt Buhler — see the `reports/skills/pbir-cli` skill in `power-bi-agentic-development` |
| **When to use** | Any structured report edit. The skill's rule: **always** use `pbir` when available; only edit PBIR JSON directly (with the `pbir-format` skill) if `pbir` fails three times in a row. |

| What | Example |
|------|---------|
| Validate after every change | `pbir validate "Sales.Report"` (add `--qa`, `--fields`, or `--all`) |
| Read a property / raw JSON | `pbir get "Sales.Report/Overview.Page/Card.Visual.title.fontSize"` · `pbir cat "Sales.Report"` |
| Set a property (glob + filter) | `pbir set "Sales.Report/**/*.Visual.title.show" --value false -f` |
| New thin report bound to a model | `pbir new report "Sales.Report" -c "Workspace/Model.SemanticModel"` |
| Add a visual | `pbir add visual card "Sales.Report/Overview.Page" --title "Revenue" -d "Values:Sales.Revenue" --y 120` |
| Add a filter / bookmark | `pbir add filter Date Year -r "Sales.Report"` · `pbir add bookmark "Sales.Report" "Q1 View"` |
| Discover data roles for a visual | `pbir add visual --list` · `pbir visuals bind --list-roles` |
| Publish to a Fabric workspace | `pbir publish "Sales.Report" "Workspace.Workspace/Sales.Report" -f` (positional args, **not** `--workspace`) |
| Desktop bridge (Windows only) | `pbir desktop list` → `pbir desktop refresh "Sales.Report"` → `pbir desktop screenshot "Sales.Report/Overview.Page" -o verify.png` |

- **Path syntax** is filesystem-like with required type suffixes
  (`Report.Report/Page.Page/Visual.Visual`); glob (`**/*.Visual`) for bulk ops (needs `-f`).
  **Top-level flags go before the subcommand**: `pbir -q new report ...`, not `pbir new report -q`.
- **Fallback when absent** — edit PBIR JSON directly using the **`pbir-format` skill (in the
  `pbip` plugin, not the reports plugin)**; never hand-edit PBIR without it.
- **Caveats** — `pbir desktop` is Windows-only (every call fails on macOS/Linux) and needs the
  Desktop "external tool access" preview setting on; `pbir desktop refresh` reloads PBIP/PBIR
  definitions, not PBIX. `validate` checks structure, not rendering — confirm visually via the
  Desktop screenshot loop or a sandbox `pbir publish`.

---

## 23. Tabular Editor CLI — semantic-model validation & deployment

**Purpose** — Headless semantic-model operations for CI/CD: Best Practice Analyzer
(BPA), C# scripts/macros, schema validation, deploy via XMLA, and (new CLI) diffing,
testing, refresh and VertiPaq analysis.

| | |
|---|---|
| **Owned by** | **010 Semantic Model Team Lead**, via **016 Semantic Validation & Performance Agent** |
| **tool-status.json key** | `tabularEditor` (aliases checked: `te`, `TabularEditor.exe`, `TabularEditor2.exe`, `TabularEditor3.exe`) |
| **Provider** | Tabular Editor — https://docs.tabulareditor.com |
| **Two binaries** | `TabularEditor.exe` (TE2 CLI) — stable, Windows-only, free, production-ready. `te` — the new cross-platform CLI, in Limited Public Preview. |

**`TabularEditor.exe` (TE2 — use for production pipelines today):**

| What | Example |
|------|---------|
| Run, waiting for completion | `start /wait TabularEditor.exe "model.bim" -S script.csx` |
| Run BPA, fail build on issues | `start /wait TabularEditor.exe "model.bim" -A rules.json -V` (`-G` for GitHub annotations) |
| Run a C# script | `... -S script.csx` |
| Deploy to a workspace via XMLA | `... -D "Provider=MSOLAP;Data Source=powerbi://...;" "DatabaseName" -O -C -P -R` |
| Emit XMLA/TMSL without deploying | `... -X out.xmla` |

> `TabularEditor.exe` is a WinForms app — **always** wrap CLI runs in `start /wait` so the
> console waits for the task to finish. Running it in CI does **not** need a TE3 licence.

**`te` (new CLI — cross-platform, preview, no `start /wait` needed):**

| What | Example |
|------|---------|
| Validate / run BPA | `te validate ...` · `te bpa run --fail-on warning` |
| Deploy with fine-grained flags | `te deploy --deploy-roles --deploy-partitions ...` (`--dry-run`, `--xmla <file>`) |
| Run scripts / format DAX | `te script ...` · `te format` |
| Inspect / diff / dependencies | `te ls`, `te find`, `te diff` (exit `2` on difference), `te deps --unused` |
| Refresh / test / VertiPaq | `te refresh --table ...` · `te test run --trx out.trx` · `te vertipaq` |

- **Fallback when absent** — author/validate TMDL by hand via the `fabric-tmdl` (house style)
  + data-goblin DAX/naming skills; BPA rules live in the data-goblin `bpa-rules` skill.
- **Caveats** — the `te` preview is time-limited (expires 2026-09-30); TE3 **desktop** needs a
  paid licence but the CLIs in CI do not. `te` is **not** a real exe name for TE2 — detection
  checks all four aliases and stores what was actually found.
- **Install strategy** — setup tries an automated portable install first (works on open networks);
  if that fails it prints the exact link (`releases/latest` → `TabularEditor.Portable.zip`, unzip to
  `%LOCALAPPDATA%\Programs\TabularEditor`). **Corporate security can return that zip empty or block it
  outright** (deep content inspection of executables); an IT/download approval may be required. Drop the
  zip in Downloads and re-run to auto-pick it up, or ask **070 - Capability Maintenance Team Lead**.
- **If it can't be installed** — the **016 Semantic Validation & Performance Agent** falls back to the
  `fabric-tmdl` (house style) + data-goblin DAX/naming skills and the `bpa-rules` skill: it authors and
  reviews TMDL/DAX and applies BPA rules by hand. You lose only the *automated* headless BPA/VertiPaq run,
  not the modelling capability.

---

## 24. `pbi-tools` — PBIX/PBIP source control & build

**Purpose** — Extract a PBIX/PBIT into a source-controllable folder, compile sources
back into a PBIX/PBIT, convert between serialization formats, and deploy.

| | |
|---|---|
| **Owned by** | **055 Power BI ALM Agent** — for ALM/round-tripping of legacy PBIX in Git |
| **tool-status.json key** | `pbiTools` (command `pbi-tools`) |
| **Provider** | https://pbi.tools |
| **When to use** | Round-tripping classic **PBIX** into Git when the source isn't already PBIP/PBIR. For native PBIP/PBIR reports prefer `pbir` (§22); for models prefer TMDL / Tabular Editor (§23). |

| Action | Example |
|------|---------|
| Inspect running Desktop instances | `pbi-tools info` |
| Extract a PBIX to a source folder | `pbi-tools extract ".\Sales.pbix"` (default TMDL model serialization) |
| Compile sources back to PBIX/PBIT | `pbi-tools compile ".\Sales" -format PBIT` |
| Convert serialization in place | `pbi-tools convert ".\Sales" -modelSerialization Tmdl` |
| Export table data to CSV | `pbi-tools export-data -pbixPath ".\Sales.pbix"` |
| Deploy via a manifest profile | `pbi-tools deploy ".\Sales" <label> -environment Development` |

- **Fallback when absent** — use the Fabric VS Code extension / `pbir` for PBIR reports;
  manual PBIP serialization for models.
- **Caveats** — Windows-centric (it talks to Power BI Desktop internals). `compile` to PBIX is
  supported only for "thin" report-only projects; use the **PBIT** format when the project
  contains a data model.
- **Install strategy** — setup tries an automated portable install first (works on open networks);
  if that fails it prints the exact link (`releases/latest` → `pbi-tools.<version>.zip` net472, unzip to
  `%LOCALAPPDATA%\Programs\pbi-tools`). **Corporate security can return that zip empty or block it
  outright** (deep content inspection of executables); an IT/download approval may be required. Drop the
  zip in Downloads and re-run to auto-pick it up, or ask **070 - Capability Maintenance Team Lead**.
- **If it can't be installed** — the **055 Power BI ALM Agent** falls back to the Fabric VS Code
  extension / `fab export`/`import` and `pbir` (§22) for PBIR reports, and manual PBIP/TMDL serialization
  for models. You lose only classic-**PBIX** round-tripping into Git; native PBIP/PBIR ALM is unaffected.

---

## 25. `sqlcmd` — T-SQL over the Fabric SQL endpoint

**Purpose** — Run T-SQL against a Fabric Warehouse / Lakehouse SQL analytics endpoint
(or Azure SQL). This is the one thing `fab` does **not** do. See also §8.

| | |
|---|---|
| **Owned by** | **033 Warehouse SQL Agent** & **063 SQL, ODBC & Data Access Agent** |
| **tool-status.json key** | `sqlcmd` |
| **Provider** | Microsoft — modern `go-sqlcmd` (https://aka.ms/go-sqlcmd) |
| **When to use** | Any T-SQL query/script against a Fabric SQL endpoint, when `fab` data-plane commands aren't enough. |

| What | Example |
|------|---------|
| Query an endpoint with Entra auth | `sqlcmd -G -S <ep>.datawarehouse.fabric.microsoft.com -d <db> -Q "SELECT TOP 10 * FROM dbo.sales"` |
| Run a SQL script file | `sqlcmd -G -S <ep> -d <db> -i script.sql` |
| CSV-style output | add `-s "," -W` to the query |

- **Fallback when absent** — Python `pyodbc` with an Entra token
  (`conn = pyodbc.connect(connstr, attrs_before={1256: token})`), or any SQL client.
  Get the token via `az account get-access-token --resource https://database.windows.net`.
- **Caveats** — `-G` uses Entra ID auth. The modern `go-sqlcmd` and the legacy ODBC `sqlcmd`
  differ on some flags — confirm with `sqlcmd -?`.

---

## 26. `gh` — GitHub CLI

**Purpose** — Drive GitHub from the terminal: repos, pull requests, issues, Actions
runs, releases, and raw API calls. Used for the GitHub side of the DevOps workflow.

| | |
|---|---|
| **Owned by** | **051 GitHub Source Control Agent** |
| **tool-status.json key** | `gh` |
| **Provider** | https://cli.github.com/manual/ |
| **When to use** | When the repo's remote is GitHub: PR creation/review, CI status, releases. For Azure DevOps remotes use `az devops` (§27). |

| What | Example |
|------|---------|
| Sign in / check status | `gh auth login` · `gh auth status` |
| View / clone a repo | `gh repo view` · `gh repo clone <owner>/<repo>` |
| List / create a PR | `gh pr list` · `gh pr create --base prod --head dev --fill` |
| Check out / review a PR | `gh pr checkout <n>` · `gh pr review --approve` |
| CI status / merge a PR | `gh pr checks <n>` · `gh pr merge <n> --squash` |
| Watch / view Actions runs | `gh run list` · `gh run watch <id>` |
| Create a release | `gh release create v1.0.0 --notes "..."` |
| Raw API call | `gh api repos/<owner>/<repo>/pulls` |

- **Fallback when absent** — plain `git` for branch/commit/push, plus the GitHub web UI for
  PRs/Actions; the ALM & DevOps team coordinates the Fabric-side ALM regardless.
- **Caveats** — needs an authenticated session (`gh auth login`) or a `GH_TOKEN`/`GITHUB_TOKEN`
  env var; org SSO may require an extra authorization step.

---

## 27. `az devops` — Azure DevOps CLI

**Purpose** — Drive Azure DevOps from the terminal: repos & PRs, branch policies,
pipelines (build/release), boards work items, and artifacts.

| | |
|---|---|
| **Owned by** | **052 Azure DevOps Agent** |
| **tool-status.json key** | `azureDevOpsCliExtension` (command `az devops`) |
| **Provider** | https://learn.microsoft.com/en-us/azure/devops/cli/ |
| **When to use** | When the repo's remote / CI is Azure DevOps. For GitHub remotes use `gh` (§26). |

| What | Example |
|------|---------|
| Install the extension | `az extension add --name azure-devops` |
| Set org/project defaults | `az devops configure --defaults organization=https://dev.azure.com/<org> project=<proj>` |
| List / create a PR | `az repos pr list` · `az repos pr create --source-branch dev --target-branch prod` |
| Inspect branch policies | `az repos policy list` |
| Run / list pipelines | `az pipelines run --name <pipeline>` · `az pipelines list` |
| Show build status | `az pipelines build list` |
| Boards work items | `az boards work-item show --id <n>` |

- **Fallback when absent** — plain `git` plus the Azure DevOps web UI; the **053 Fabric Git
  Integration Agent** still coordinates Fabric Git Integration / Deployment Pipelines via `fab`.
- **Caveats** — `az devops` is an **extension on top of `az`**: if the `az` key is missing this
  tool cannot exist (that's why its `tool-status.json` `reason` reads "az missing"). Auth via
  `az login` or a PAT in `AZURE_DEVOPS_EXT_PAT`.

---

## 28. `pbiviz` — Power BI custom visual tools

**Purpose** — Create, run, package and inspect Power BI custom visual SDK projects
(`powerbi-visuals-tools`). Used only inside the optional PBIVIZ folder.

| | |
|---|---|
| **Owned by** | **080 PBIVIZ Development Team Lead** (082 Developer, 083 Tester, 085 Maintainer run it) |
| **tool-status.json keys** | `node`, `npm`, `pbivizCli` (category `pbiviz-toolchain`, detect only) |
| **Provider** | https://learn.microsoft.com/power-bi/developer/visuals/ |
| **When to use** | For `.pbiviz` SDK projects. In-report Deneb, SVG, Python and R visuals are 024's and need no CLI. |

**Rule — detect first, obtain approval before installation or download, prefer the
project-local toolchain, and never silently acquire or execute missing packages.** In a
non-interactive terminal plain `npx <name>` downloads a missing package without asking, so
agents use only the forms below.

| What | Example (run inside the visual folder unless noted) |
|------|---------|
| Detect the project-local CLI (no download) | `Test-Path .\node_modules\.bin\pbiviz.cmd` · `npx --no pbiviz --version` (`--no` refuses to download) |
| Run the project-local CLI | `npx --no pbiviz start` · `npx --no pbiviz package` · `npx --no pbiviz info` |
| Restore the dependencies of an existing visual (downloads) | only after `APPROVED:INSTALL:<visual>`: `npm ci` (lockfile present) |
| New visual (`pbiviz new` downloads the CLI and the template's dependencies) | only after `APPROVED:INSTALL:<visual>`, in the PBIVIZ folder: `npm exec --yes --package=powerbi-visuals-tools@<pinned version> -- pbiviz new <VisualName>` |
| Per-project MCP server | write `<visual>/.vscode/mcp.json` with the project-local command below. `npx --no pbiviz mcp --init` generates `npx -y powerbi-visuals-tools mcp` instead: never keep that generated command, it would download a missing package |

Project-local `pbiviz` MCP configuration (`<visual>/.vscode/mcp.json`, the visual folder
opened as a workspace root); it starts only the installed package and fails instead of
downloading when it is missing:

```json
{
  "servers": {
    "pbiviz": {
      "type": "stdio",
      "command": "node",
      "args": ["${workspaceFolder}/node_modules/powerbi-visuals-tools/bin/pbiviz.js", "mcp"]
    }
  }
}
```

- **Fallback when absent** — Node.js is required to build; without it agents can still plan,
  review and edit source, and report every build/test step as `NOT RUN`.
- **Caveats** — Node.js 20.19.0+ for current `powerbi-visuals-tools` (each project's
  installed version decides). A global `pbiviz` is not required and is never installed by
  agents. The `pbiviz` MCP server is callable only when that visual folder is
  opened as a workspace root; it is never configured by the installer. Packages are
  imported into reports only from `<Visual>/releases/`.

---

## 29. Git for the PBIVIZ repository — `Pbiviz-Alm.ps1`

**Purpose** — Deterministic Git operations for the PBIVIZ repository across the three
levels (local, remote, team). Shipped as `.github/agent-docs/Pbiviz-Alm.ps1`; every
Git call goes through one function with literal pathspecs, UTF-8 output and no prompts.

| | |
|---|---|
| **Owned by** | **086 PBIVIZ ALM & Release Agent** (via 080). **050** keeps Fabric repositories and organisation-level GitHub/Azure DevOps administration. |
| **Requires** | Git 2.28+; a Git identity for commits |
| **Load** | `. .\.github\agent-docs\Pbiviz-Alm.ps1` |

| What | Function |
|------|----------|
| State and level of the folder | `Get-PbivizRepoState -Root <folder>` · `Get-PbivizStatusLine -Root <folder> -RelativePath <name>` |
| Level 1 initialisation (installer) | `Initialize-PbivizRepository -Root <folder> -FolderWasEmpty` |
| Level 2: adopt a remote, keeping both histories | `Connect-PbivizRemoteHistory -Root <folder> -Remote origin -Branch main -Fetch` |
| Level 3: candidate for one visual | `New-PbivizPromotionCandidate -Root <folder> -Visual <Name> -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod [-Allowlist <paths>]` |
| Level 3: gates G0-G6 | `Test-PbivizPromotionGates -Worktree <candidate> -Visual <Name> -TargetRef PBVIZ_Team_Prod [-Allowlist <the candidate's paths>]` |
| Release build with build evidence | Level 1/2: `Invoke-PbivizBuild -Root <folder> -Visual <Name>` (clean checkout whose HEAD is the source commit) · Level 3: `Invoke-PbivizBuild -Worktree <candidate> -Visual <Name>` · optional `-TimeoutSeconds` (default 900) |
| Release pair (`.pbiviz` + `.release.json`) | Level 1/2: `Add-PbivizRelease -Root <folder> -Visual <Name> -SourceSha <HEAD>` · Level 3: `Add-PbivizRelease -Worktree <candidate> -Visual <Name> -SourceSha <candidate source>` · optional `-Tests @{ lint='PASS'; unit='PASS'; host='NOT RUN'; certification='NOT RUN' }`, `-Review @{ reviewer=...; verdict='APPROVE'; sourceSha=<source commit> }`, `-PackagePath <path>`, `-ExternalPackageApproval 'APPROVED:EXTERNAL-PACKAGE:<Name>:<sha256>'`; `-ToolsVersion` / `-NodeVersion` only cross-check the build evidence |
| One-time legacy archive of `dist/` packages | `Add-PbivizLegacyArchive -Root <folder> -Visual <Name>` |
| After your PR is merged | `Get-PbivizReleaseProvenance -Root <folder> -Visual <Name> -Version <v> -ProdRef PBVIZ_Team_Prod` · `Test-PbivizReleaseIntegrity -Root <folder> -Visual <Name> -Version <v> -Commit <prod commit>` |
| Clean up a helper worktree | `Remove-PbivizPromotionWorktree -Root <folder> -WorktreeDir <candidate>` (a committed candidate, without force) · an uncommitted candidate only with `-DiscardApproval 'APPROVED:DISCARD-CANDIDATE:<branch>'` |

Pass absolute folder paths (`(Resolve-Path <folder>).ProviderPath`): the helper starts Git and
Node with the path it is given, not with the PowerShell location.

### 29.0 The three levels in practice

The level is derived from the repository (`Get-PbivizRepoState -Root $root`: `main` without a
remote = 1, a remote = 2, `PBVIZ_Team_*` branches = 3), never assumed. 086 runs every step below;
the Git commands are plain Git, the rest are helper functions.

**Level 1 - local repository.**
- Created by the installer (Step 8) with `Initialize-PbivizRepository`: `git init -b main`, a
  repository-local `core.longpaths`, `.gitignore` and `.gitattributes`, and - only for a brand-new
  empty folder with a Git identity - one configuration-only baseline commit. An existing
  repository is reused and never committed to.
- A new visual is created by 082 (`pbiviz new`, section 28, only after `APPROVED:INSTALL:<Name>`).
- Checkpoint - one visual per commit, after checking the Git identity:

```powershell
git -C $root status --short -- 'Bar'
git -C $root add -- 'Bar'
git -C $root diff --cached --name-only       # only Bar/ paths; unstage and stop if another visual appears
git -C $root commit -m 'Bar: first working version (v1.0.0.0)'
```

- Restore: `git -C $root restore --source=<sha> -- Bar` (working tree only) or
  `git -C $root revert <sha>` (a new commit). Releases: 29.2. Level 1 has no off-device copy.

**Level 2 - remote collaboration** (after `APPROVED:CONNECT:<url>`):

```powershell
Test-PbivizRemoteUrl -Url $url               # True only for a GitHub / Azure DevOps repository URL
git -C $root remote add origin $url
$a = Connect-PbivizRemoteHistory -Root $root -Remote origin -Branch main -Fetch
$a.Status, $a.Case, $a.Reason, $a.BackupRef, ($a.ConflictPaths -join ', '), ($a.Collisions -join ', ')
```

`Case` is one of: `empty-remote` (nothing changed; push `main` only with `APPROVED:PUSH:main`),
`up-to-date`, `fast-forward` (related history), `unrelated-merge` (an independent remote merged
with both root commits kept), `tracking-checkout` (an empty local repository takes the remote
branch), `conflict` (the merge was aborted and HEAD, index, tracked files and untracked/ignored
files are exactly as before - the paths are listed; resolving them in local files needs
`APPROVED:MERGE-LOCAL:<paths>`), `needs-checkpoint` (commit local files first),
`needs-merge-decision` (diverged history: a merge needs approval) or `blocked` (for example a local
untracked or ignored file at a path the remote tracks - move it aside, nothing was changed).
Before any branch moves a backup ref `refs/pbiviz-backup/connect-<utc>` is written; afterwards the
helper asserts that the old local tip is an ancestor of the new one and that no other ref changed.
Tags are never fetched. Daily sync is the same call (one-branch fetch, fast-forward only).

**Level 3 - DEV / (TEST) / PROD** (after `APPROVED:BRANCHES:<repo>`, clean and up-to-date `main`):
`PBVIZ_Team_Dev` at `origin/main`, `PBVIZ_Team_Prod` at the commit the user confirms (or empty),
`PBVIZ_Team_Test` on request; the local checkout switches to Dev and `main` stays untouched. Branch
policies start as a checklist and are applied only with `APPROVED:POLICY:<branch>`. Releases made
before Level 3 reach an empty Prod through an archive-only promotion
(`New-PbivizPromotionCandidate -ArchiveOnly`, gates with `-ArchiveOnly`), which admits validated
releases and labelled legacy history only. Releases: 29.3; with a Test branch: 29.7.

### 29.1 Release classes and the evidence behind them

| Term | Exactly what it means |
|---|---|
| **OFFICIAL RELEASE** | The manifest says `validated: true`, which the helper sets only when all of these hold: the package identity was verified from its content, the helper's build evidence binds those exact bytes to the source commit, lint and unit are recorded as PASS, the `powerbi-visuals-tools` and Node versions are recorded, and an `APPROVE` (or `APPROVE WITH NONBLOCKING NOTES`) review is recorded for the exact source commit. It never implies host testing or any certification. |
| **Recorded attestations** (`tests`, `review`) | The lint/unit/host/certification results and the review verdict are recorded exactly as the caller supplies them (normally 083 and 084 through 086). `Add-PbivizRelease` checks their vocabulary, that the review names the release source commit and that nothing FAILED or was BLOCKED; it does **not** run the tests, read their logs or authenticate the reviewer. A recorded PASS is an attestation by the agent that reported it, not execution evidence produced by the helper. Only the build evidence and the package identity are established by the helper itself. |
| **DEVELOPMENT/TEST CANDIDATE** | `validated: false`, with every missing item listed in `validationGaps`. Allowed at Level 1/2 only; Level 3 never promotes it (`Add-PbivizRelease -Worktree` blocks it before writing, G6 blocks it in the candidate). It is never presented or distributed as a production release. |
| **Verified local build** (`BuildEvidence = VERIFIED`) | The helper's own build record exists for exactly these package bytes: `Invoke-PbivizBuild` ran the visual's project-local CLI on this machine on the source revision. It is what the helper observed here, not a reproducible-build attestation, and it does not vouch for the contents of `node_modules`. |
| **Package identity inspection** (`package.identity = VERIFIED`) | GUID, version and resource read from the `.pbiviz` content (`package.json` and `resources/<guid>.pbiviz.json`) and matched against `pbiviz.json` at the source commit. It says nothing about how or from what the package was built: BUILT is never derived from package metadata. |

A FAIL test result, a `BLOCK` review, an invented `package` result, a review of another commit or a
package built from another commit is BLOCKED; a missing result is a gap, never filled with PASS.

### 29.2 Release workflow - Level 1 and Level 2 (clean checkout)

Preconditions, each checked by the helper (BLOCKED otherwise, nothing written):
- the PBIVIZ repository root, HEAD on a branch (not detached) and equal to the commit you release;
  no uncommitted change, no untracked file in the visual, no `assume-unchanged` / `skip-worktree`
  entry, no ignored file in the visual other than build output;
- the visual's own `powerbi-visuals-tools` is installed in `<Name>/node_modules`. The helper never
  downloads: when it is missing the result is BLOCKED and names `APPROVED:INSTALL:<Name>` - restore
  the locked dependencies (section 28) only after the user gives that token;
- the toolchain preflight passes (29.6): `pbiviz package` must not need to download or change
  dependencies itself;
- `node` is on PATH, `pbiviz.json` has a valid GUID and version at that commit, and
  `<Name>/dist/<guid>.<version>.pbiviz` does not exist yet (a package is never overwritten);
- the version exceeds every archived version of the visual, validated and legacy (checked by
  `Add-PbivizRelease`).

```powershell
. .\.github\agent-docs\Pbiviz-Alm.ps1                    # from the workspace root
$root = (Resolve-Path '<PBIVIZ folder>').ProviderPath
$b = Invoke-PbivizBuild -Root $root -Visual 'Bar'
$b.Status, $b.Reason       # PASS -> $b.PackagePath, $b.Sha256, $b.SourceSha, $b.RecordPath
# 083 reports lint/unit for $b.SourceSha; 084 reviews exactly $b.SourceSha.
$r = Add-PbivizRelease -Root $root -Visual 'Bar' -SourceSha $b.SourceSha `
       -Tests  @{ lint = 'PASS'; unit = 'PASS'; host = 'NOT RUN'; certification = 'NOT RUN' } `
       -Review @{ reviewer = '084 PBIVIZ Reviewer'; verdict = 'APPROVE'; sourceSha = $b.SourceSha
                  reviewedAt = '2026-11-14T10:00:00Z'; reference = '080 WORK RESULT, review of Bar 1.0.0.1' }
$r.Status, $r.Validated, $r.ReleaseClass, $r.BuildEvidence, ($r.ValidationGaps -join '; ')
$r.Staged                  # exactly Bar/releases/<guid>.<version>.pbiviz and .release.json
```

Expected outcomes:
- `Invoke-PbivizBuild` PASS: `dist/<guid>.<version>.pbiviz` exists and the build record
  `<git common dir>/pbiviz-builds/<sha256>.json` (plus the build log) binds those bytes to the
  source commit, its fingerprint, the tools and Node versions and the command
  `node node_modules/powerbi-visuals-tools/bin/pbiviz.js package`. FAILED (no evidence) when the
  build fails, times out, leaves processes running, changes the repository state, or produces no
  package or a package with another identity.
- `Add-PbivizRelease` PASS: the pair is written and staged, `BuildEvidence = VERIFIED`,
  `PackageSource = build output`. With the complete recorded evidence above, `Validated = True` and
  `ReleaseClass = OFFICIAL RELEASE`; with anything missing (for example no review),
  `Validated = False`, `ReleaseClass = DEVELOPMENT/TEST CANDIDATE` and `ValidationGaps` lists it.
  `Validated = True` therefore rests on the helper's own build evidence plus the attestations it
  was given; report the lint, unit and review results as attested by 083 and 084.
- Then commit exactly the two staged files (the helper never commits), and check the release
  commit: `Test-PbivizReleaseIntegrity -Root $root -Visual 'Bar' -Version <v> -Commit HEAD`. Report
  an official release only for `Status = PASS`, `Verification = COMPLETE`,
  `ReleaseClass = OFFICIAL RELEASE`.

### 29.3 Release workflow - Level 3 (one visual, Dev to Prod)

```powershell
$c = New-PbivizPromotionCandidate -Root $root -Visual 'Bar' -SourceRef PBVIZ_Team_Dev -TargetRef PBVIZ_Team_Prod
$b = Invoke-PbivizBuild -Worktree $c.Worktree -Visual 'Bar'
$r = Add-PbivizRelease -Worktree $c.Worktree -Visual 'Bar' -SourceSha $c.Source -Tests $tests -Review $review
$g = Test-PbivizPromotionGates -Worktree $c.Worktree -Visual 'Bar' -TargetRef PBVIZ_Team_Prod
$g.Status; $g.Gates | Format-Table Gate, Pass, Detail
```

- `$tests` / `$review` are the same evidence as in 29.2, for `$c.Source`. Only `validated: true`
  is accepted: an incomplete release is BLOCKED before anything is written.
- Every gate must PASS. Then commit on the release branch (trailer
  `Pbiviz-Release: <visual>@<version>`); push and open the pull request only with
  `APPROVED:PUSH` and `APPROVED:PR`; merge only with `APPROVED:MERGE` and every required review
  and check satisfied. After the merge nothing is written to Prod:
  `Get-PbivizReleaseProvenance` derives the Prod commit and `Test-PbivizReleaseIntegrity` re-checks
  the release there. Remove the candidate with `Remove-PbivizPromotionWorktree`.
- Alternative build: build the source commit on the clean Dev checkout (29.2) and pass that
  `dist/` package with `-PackagePath`; it is still a worktree of this repository.

### 29.4 External packages - `APPROVED:EXTERNAL-PACKAGE:<Name>:<sha256>`

A package anywhere other than `<Name>/dist/<guid>.<version>.pbiviz` of a worktree of this
repository (or reached through a junction) is external. `Add-PbivizRelease -PackagePath <file>`
then returns BLOCKED and quotes the exact token for those bytes,
`-ExternalPackageApproval 'APPROVED:EXTERNAL-PACKAGE:Bar:<64-character sha256 of the file>'`. Ask the user; only after
they give that token, re-run with it. The token binds the SHA-256 of the bytes: another file, or
the same file changed, needs a new approval. An approved external package carries build evidence
only when its bytes are identical to a helper build record; otherwise `BuildEvidence = NONE`, it
stays a DEVELOPMENT/TEST CANDIDATE and Level 3 refuses it.

### 29.5 Integrity results - how to report them

| `Status` | `Verification` | `CommitEvidence` / `SourceRevision` | Report as |
|---|---|---|---|
| `PASS` | `COMPLETE` | `VERIFIED` / `VERIFIED` | verified; an official release only if `ReleaseClass = OFFICIAL RELEASE` |
| `PARTIAL` | `COMMIT ONLY` | `VERIFIED` / `NOT AVAILABLE` | "commit evidence verified; source revision not verified" - never as a verified release; fetch the Dev history and re-run |
| `FAILED` | `NONE` | `MISMATCH` (commit or source revision), or no single release manifest at that commit | not a valid release |

COMMIT evidence: fingerprint, shared-file blobs, package hash, size, content claims, build evidence
and validation claim at the given commit. SOURCE-REVISION evidence: the Dev commit named in the
manifest still yields the same fingerprint and shared blobs.

### 29.6 Build supervision, isolation, transactional archiving and G4 limits

- **Toolchain preflight** - before the CLI starts, `Invoke-PbivizBuild` refuses (BLOCKED, nothing
  run or written) every case in which `pbiviz package` would itself download or change
  dependencies. `powerbi-visuals-tools` (verified with 7.2.1) runs `npm list powerbi-visuals-api` on every package and
  install that package over the network, rewriting `package.json`, `package-lock.json` and
  `node_modules`, when `node_modules/powerbi-visuals-api` is missing, `pbiviz.json` has no
  `apiVersion` (then `@latest`) or the installed major.minor differs from `apiVersion` (then
  `~<apiVersion>`). The preflight blocks those three cases and, when the visual has a
  `package-lock.json`, also a lockfile that disagrees with `package.json` on `powerbi-visuals-tools`
  / `powerbi-visuals-api` or locks other versions than the installed ones. The fix is the user's
  `APPROVED:INSTALL:<Name>` and `npm ci`, or a source commit that corrects `apiVersion` - never a
  helper workaround. Another patch of the same API major.minor is accepted, as the SDK accepts it.
- **Isolation of the CLI** - the SDK verifies a dev-server certificate under
  `os.homedir()\<certificateFolder>` on every package (through Windows PowerShell) and, when that
  fails, deletes the certificate files and creates a new certificate with
  `pwsh New-SelfSignedCertificate -CertStoreLocation Cert:\CurrentUser\My`. A package needs no TLS
  material, so the helper runs the CLI with:

  | Child setting | Value |
  |---|---|
  | `USERPROFILE` / `HOME` | `<git dir>\pbiviz-build-home\home-<id>\profile`, holding a public-only placeholder PFX (ephemeral key, nothing imported into any store) at the SDK's `certificateFolder` / `pfx` / `passphrase` names |
  | `PATH` | a guard folder with `pwsh.cmd` first (it records the call and fails), then the caller's PATH without folders that hold `pwsh.exe` / `pwsh.com` |
  | `PATHEXT` · `NoDefaultCurrentDirectoryInExePath` | `.CMD` guaranteed · `1`, so a same-named `pwsh.*` in the visual folder never runs before the guard |
  | `npm_config_cache` · `npm_config_offline` · `npm_config_update_notifier` | a disposable cache (npm logs included) · `true` · `false`; `npm_config_userconfig` keeps the caller's user npmrc |
  | `TEMP` / `TMP` | a folder inside the disposable home |

  The guard folder, its marker, `owner.lock`, the npm cache and TEMP sit beside `profile\`, and each
  SDK certificate setting (`certificateFolder`, `certificate`, `privateKey`, `pfx`, `passphrase`
  in the toolchain's `config.json`) must be a single safe file name, distinct from the others,
  whose resolved path lies directly in the disposable certificate folder - otherwise BLOCKED. The
  build is FAILED with no evidence when the guard was called, the SDK rejected or regenerated the
  certificate, the placeholder changed, a new certificate appeared in `Cert:\CurrentUser\My` (the
  store is only read; the helper never deletes a certificate), or the SDK tried to install a
  dependency. The caller's environment is restored and the home removed in every case.
- **What isolation does not cover** - it contains the SDK's known side effects; it is not an
  operating-system sandbox. The CLI, ESLint, webpack and every package in `node_modules` run with
  the user's rights and can read or write anything the user can. The SDK's certificate check starts
  Windows PowerShell, which loads the user's PowerShell profile and keeps its own caches under
  `%LOCALAPPDATA%`. Review the dependencies of a visual like any other code you run.
- **Network and approvals** - who may reach the network:

  | Command | Network | Needs |
  |---|---|---|
  | `pbiviz new` (082) and dependency restore (082/085) | yes, npm registry | `APPROVED:INSTALL:<Name>` |
  | `pbiviz package` / `pbiviz start` in a development build (082/083/085) | only when the API package is missing or mismatching - check first, otherwise NOT RUN | `APPROVED:INSTALL:<Name>` for the repair |
  | `Invoke-PbivizBuild` (086) | no: preflight blocks, npm runs offline | - |
  | `Connect-PbivizRemoteHistory -Fetch`, `git fetch` (086) | yes, the Git remote | `APPROVED:CONNECT:<url>` once |
  | `git push`, pull requests, merges, tags (086) | yes, the Git provider | `APPROVED:PUSH` / `PR` / `MERGE` / `TAG` |

- **Timeout and cleanup** - `-TimeoutSeconds` (default 900) bounds the CLI. Disposable homes are
  owned through `owner.lock`, which the running build holds open: the next build removes only homes
  whose lock is free (a finished or killed build) and lockless homes older than 24 hours, never a
  live build's home and never through a link. A linked `pbiviz-build-home` folder is refused.
  Recovery after a crash needs nothing: the next build sweeps the left-over home.
- **Build supervision** - `pbiviz package` runs under process-tree supervision (Windows job
  object): the CLI starts suspended inside the job, stdin is `NUL`, stdout/stderr are drained into
  bounded buffers (4 MB per stream; the excess is counted in the log, not kept). When the CLI exits
  or the timeout expires, every process of its tree still running - detached descendants
  included - is counted and terminated before the call returns, so nothing can write a package
  afterwards (the console host Windows attaches to the CLI is not counted). A timeout, a descendant still running after the CLI exited, or output that could not
  be collected is FAILED with no build evidence.
- **Transactional archiving** - `Add-PbivizRelease` and `Add-PbivizLegacyArchive` write each new
  file to a temporary file and rename it into place (never over an existing file), and record
  every folder and file they create. If anything fails after the first write - package, manifest,
  staging or the post-staging candidate check - they unstage what they staged, delete what they
  wrote while it still holds the bytes they wrote, and remove folders they created when empty; the
  reason ends with `rolled back: nothing this call wrote or staged was left behind`. Pre-existing
  releases and user files are never touched. If a written file changed meanwhile it is left in
  place and the result is FAILED with `ROLLBACK INCOMPLETE` naming it. A release file that exists
  but is not tracked is reported (never deleted) for you to inspect.
- **G4 (dependencies stay inside the visual)** - analyses the visual's own code, styles and JSON
  configuration as the PBIVIZ toolchain (webpack 5, ts-loader, less-loader, css-loader) resolves
  them: `import` / `export ... from`, side-effect imports, `import()` (template literals by their
  static prefix), `require()`, `require.resolve()`, `require.context()`,
  `import.meta.webpackContext()`, `new URL(<request>, import.meta.url)`, triple-slash references,
  LESS/CSS `@import` and `url()`, and relative or absolute path strings in the visual's JSON files
  (for example `extends`, `baseUrl` and `paths` in `tsconfig.json`, `file:` dependencies in
  `package.json` and the lockfile, paths in `pbiviz.json`). A request
  reaching a file outside the visual that is not allowlisted, a folder request (context or
  template) outside the visual, npm workspaces at the repository root, or an absolute path BLOCK
  the gate. It fails closed (`analysis incomplete`) on a computed request, a package the visual's
  own `package.json` / `package-lock.json` does not declare or lock, inline loader syntax,
  `#` subpath imports, an executable `pbiviz.mjs` / `tsconfig.mjs` / `capabilities.mjs`, a
  `node_modules` folder at the repository root, unreadable or oversized files, junctions and
  links. Limits: the contents of `node_modules` are not analysed; TypeScript automatic `@types`
  inclusion from folders above the repository, pnpm/Yarn layouts, lockfile version 1 and R scripts
  are not resolved; text inside JSX that looks like a comment can hide a computed import from the
  lexer (static relative requests are still caught by a raw scan). G4 is a static classification,
  not a proof that the bundle contains nothing from outside the visual.

- **Cleanup** — only helper-created candidates (record, folder and `release/pbiviz/*` branch
  must match) are removed; unexpected staged, unstaged or untracked data and operations in
  progress are refused, with or without approval. The release branch is always kept.

- **Never (helper or agent)** — force (`switch -C`, `checkout -B`, `branch -f`,
  `push --force`), `reset --hard`, `clean -f`, admin/policy bypass, writing to Prod after a
  merge, or editing a file under any `releases/` folder. The one forced operation in the
  helper is discarding an uncommitted, helper-created candidate worktree, and only with
  `APPROVED:DISCARD-CANDIDATE:<branch>`.
- **Approval-gated (agent only)** — push, pull request and merge are separate agent actions,
  each gated by an explicit approval token (`APPROVED:PUSH`, `APPROVED:PR`, `APPROVED:MERGE`
  with every required review and check satisfied); the helper performs none of them.
- **Results** — every function returns a status (`PASS`, `BLOCKED`, `NEEDS INPUT`,
  `NEEDS CHECKPOINT`, `CONFLICT`, `FAILED`; integrity: also `PARTIAL`; provenance: `DERIVED` /
  `NOT DERIVABLE`) with a reason and evidence; agents report it verbatim.

### 29.7 Test stage - one candidate per release, rejected releases and `test-sync`

With `PBVIZ_Team_Test` the release branch name stays `release/pbiviz/<Name>/<version>`, so there is
**one candidate per visual and version, always cut from the Prod tip** (a second candidate for the
same version is refused). Flow:

1. Create, build, gate and commit the candidate against Prod (29.3); push it (`APPROVED:PUSH`).
2. Pull request 1: the release branch -> `PBVIZ_Team_Test` (`APPROVED:PR`, then `APPROVED:MERGE`).
3. `Test-PbivizReleaseIntegrity` on the Test merge commit; host-test the package from Test's archive.
4. Pull request 2: the **same, unchanged** release branch -> `PBVIZ_Team_Prod`; then provenance and
   integrity on the Prod merge commit (29.5). Only the Prod result makes an OFFICIAL RELEASE
   distributable.

A release rejected in Test is fixed with a new Dev commit and a **new version** - never by editing
the release branch. The rejected pair stays in Test's archive as history and is never promoted.
Test then still holds the rejected source of that visual, so pull request 1 of the next version may
conflict, or merge cleanly yet leave rejected files behind (step 3 then FAILS on the fingerprint).
The rule: on Test, the visual's whole source scope (plus the allowlisted shared files - the
`sharedFiles` paths in this version's `.release.json`) must equal the release branch. 086
reconciles it on a local integration branch, never in the provider's web conflict editor (that
would commit the resolution onto the release branch):

```powershell
$rel = 'release/pbiviz/Bar/1.0.0.3'
git -C $root switch -c 'test-sync/Bar/1.0.0.3' PBVIZ_Team_Test
git -C $root merge --no-ff --no-commit $rel                 # may report conflicts: expected
git -C $root checkout $rel -- Bar                          # plus each allowlisted shared file
# remove every Bar file outside Bar/releases/ that exists only on Test:
$keep  = git -C $root ls-tree -r --name-only $rel -- Bar
$extra = git -C $root ls-files -- Bar | Where-Object { $_ -notlike 'Bar/releases/*' -and $keep -notcontains $_ }
foreach ($p in $extra) { git -C $root rm -q -- $p }
git -C $root diff --name-only --diff-filter=U               # must be empty
git -C $root diff --cached --name-only PBVIZ_Team_Test      # must list Bar/ paths only
git -C $root commit -m "Merge $rel into Test via test-sync/Bar/1.0.0.3"
```

Then push the integration branch and use it for pull request 1 (`APPROVED:PUSH`, `APPROVED:PR`,
`APPROVED:MERGE`). Step 3 must now show `Status = PASS` with the merge commit's fingerprint equal to
the manifest's. **Stop and report** - do not resolve by hand - when a path outside the visual (and its
allowlisted shared files) differs from a clean merge, when an unmerged path remains, or when a
release pair of another version would change: release pairs that exist only on Test stay as they
are (the archive is append-only). Never merge Test into the release branch or into Prod. This
procedure is plain Git (no helper function); it is covered by an automated regression test and was
rehearsed on local branches, not yet against a provider's pull-request UI.

---

> **One workspace contract for every tool above.** Read `tool-status.json` →
> if `<key>.found` use the tool → else one optional live re-check → else the documented
> fallback. Never fail a task **solely** because a specialist CLI is missing; the core
> local-editing workflow needs none of them.
