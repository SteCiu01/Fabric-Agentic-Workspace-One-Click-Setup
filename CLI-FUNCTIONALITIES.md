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

- **`fab`** (recommended): `pip install ms-fabric-cli` (Python 3.10–3.13). Repo: https://github.com/microsoft/fabric-cli
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

> **One workspace contract for every tool above.** Read `tool-status.json` →
> if `<key>.found` use the tool → else one optional live re-check → else the documented
> fallback. Never fail a task **solely** because a specialist CLI is missing; the core
> local-editing workflow needs none of them.
