# CLI Functionalities — Deep Dive

> **TL;DR** — The core workspace (Fabric VS Code extension + agents editing local
> files) needs **no CLI**. Installing a CLI adds terminal and control-plane /
> data-plane power on top. This workspace standardises on the **Fabric CLI
> (`fab`)**; **Azure CLI (`az`)** is a documented **fallback** for the few things
> `fab` does not cover (SQL/TDS queries and non-Fabric token audiences).

This document is a practical, opinionated catalogue of the CLI actions that are
most useful in this workspace. It focuses on the commands a Fabric developer is
most likely to reach for during local, live, or hybrid agent-assisted work:
identity checks, item export/import, job runs, REST calls, OneLake/table
operations, Git/ALM tasks, and the few fallback cases where `az` or `sqlcmd` are
still the better tool.

It is not intended to be a permanent exhaustive reference for every Fabric,
Power BI, Azure, or SQL command. Command groups and flags evolve, especially
around newer Fabric APIs and preview features. Treat the examples here as the
high-value working set, then confirm exact syntax with `fab --help`,
`fab <group> --help`, the Azure CLI help, or the official Microsoft references
linked below.

- **Install `fab`** (recommended): `pip install ms-fabric-cli` (Python 3.10–3.13). Repo: https://github.com/microsoft/fabric-cli
- **Install `az`** (fallback): https://aka.ms/installazurecli

Official references:

- Microsoft Fabric CLI: https://github.com/microsoft/fabric-cli
- Microsoft Fabric REST API: https://learn.microsoft.com/en-us/rest/api/fabric/
- Microsoft Fabric Git integration: https://learn.microsoft.com/en-us/fabric/cicd/git-integration/intro-to-git-integration
- Microsoft Fabric Data Factory activity overview: https://learn.microsoft.com/en-us/fabric/data-factory/activity-overview
- Microsoft Fabric VS Code extension: https://marketplace.visualstudio.com/items?itemName=fabric.vscode-fabric
- Azure CLI reference: https://learn.microsoft.com/en-us/cli/azure/

The agents read `.github/skills/fabric-cli-policy/SKILL.md` for the decision rule
before any CLI/REST task. This file is the human-readable companion to that skill.

---

## Table of contents

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

---

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
