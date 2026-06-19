# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.4.0-pre-release] - 2026-06-19

### Added

- **Three ways of working documented** — full local (file-first), full live (agents act directly on the live DEV workspace via Fabric REST `updateDefinition` + MCP, enabling live DAX TEST-vs-PROD comparison, reading real deployed GUIDs/endpoints, and in-place edits), and hybrid. Clarified that all three are equally safe because the Azure DevOps commit captures workspace state regardless of the edit mechanism; the only hybrid concern is local-folder drift, mitigated by the "keep local = live workspace" golden rule
- **MCP server auto-install** — the Fabric MCP server and the Power BI semantic-model MCP server are VS Code extensions (`fabric.vscode-fabric-mcp-server` and `analysis-services.powerbi-modeling-mcp`); the installer now **detects them via `code --list-extensions` and auto-installs any that are missing** (non-blocking; only needed for full-live / hybrid modes). Replaces the earlier `mcp.json`/`settings.json` check, which produced false negatives

### Fixed

- **Optimised and fine-tuned several `fab`/`az` CLI and MCP-extension installation bugs** — hardened the optional-tool install paths so they are more reliable on corporate/locked-down machines (PATH refresh, idempotent re-runs, and more resilient `az`/MCP install handling)

### Changed

- Installer startup print now explains the three working modes; the master working-flow reference gained a **Working modes** section with explicit hybrid drift-discipline rules and a live-mode tools list

## [v0.3.0-pre-release] - 2026-06-17

### Changed

- **fabric-pipelines skill enhanced after real-world usage** — added a "Operational practices (battle-tested)" section generalized from production pipeline work: `RefreshSQLEndpoint` placement semantics (when it is an orphaned no-op), Direct Lake freshness vs upstream lakehouse refresh, the SQL endpoint-id vs lakehouse item-id distinction, Variable Library environment-promotion caveats, the fixed-`Wait`-buffer anti-pattern, and a review-first pipeline-auditing checklist. All environment-specific identifiers removed — no proprietary data, redistributable

## [v0.2.0-pre-release] - 2026-06-15

### Changed

- Skill freshness display now uses **real signals** — git commit dates for the cloned repos and honest on-disk modification time for the custom skills (the installer no longer overrides/fakes file dates)
- Specialist agents and the master working-flow are now **resilient to upstream folder renames/restructuring** — skills are discovered dynamically from the repo root by keyword instead of relying on hardcoded deep paths
- Master agent can now **proactively recommend the best specialist** for a free-text request (per-request routing advice), while still offering to handle it inline
- Semantic Model Agent now applies **explicit skill precedence** — the custom fabric-tmdl skill wins on house style/conventions, the cloned data-goblin skills win on TMDL/DAX syntax and correctness

### Added

- **House modelling decisions** section in the fabric-tmdl skill (storage-mode choices, measure home, folder taxonomy, naming, formatting, hygiene)
- **Provenance & licensing notes** across the custom skills, the Skills Maintainer, and `copilot-instructions.md` — the custom skills are independent works (`fabric-tmdl` from production reports; `fabric-pipelines` from Microsoft sources, MIT), and data-goblin's GPL-3.0 repo is used only as a locally cloned reference, never copied or redistributed
- **fabric-pipelines skill refreshed against Microsoft docs (review 2026-06-15)** — added the `RefreshMaterializedLakeView` and `Approval` activities now listed in the [Fabric Data Factory activity overview](https://learn.microsoft.com/en-us/fabric/data-factory/activity-overview); recorded a "last reviewed" date in the skill's provenance block

## [v0.1.0-pre-release] - 2026-05-04

### Added

- One-click setup via `Setup-FabricAgenticWorkspace.bat` + `.ps1` (Windows)
- **Fabric Workspace Master Agent** — slim routing hub that handles session startup, skill checks, identity (`fab auth status`, falling back to `az account show`), and topic-based routing to specialist agents
- **Fabric Skills Maintainer** — light (quick pull) and deep (pull + MS docs freshness check + unreferenced skill scan) maintenance modes
- **Semantic Model Agent** — TMDL editing, DAX measures, columns, relationships, partitions
- **Fabric Data Engineer** — Spark notebooks, SQL warehouse, pipelines, medallion architecture
- **Fabric Admin** — capacity management, governance, security, workspace documentation
- **Fabric App Dev** — Python apps, ODBC, XMLA, REST API integration
- **Fabric Reports Agent** — PBIR report editing, visuals, themes
- **Fabric Pipelines Agent** — Data Factory pipeline JSON authoring
- Custom **fabric-tmdl** skill (embedded) — comprehensive TMDL syntax, indentation rules, property ordering, Direct Lake patterns
- Custom **fabric-pipelines** skill (embedded) — full pipeline activity type reference with typeProperties and expression syntax
- Custom **fabric-cli-policy** skill (embedded) — the `fab`-first / `az`-fallback decision rule and `az rest` → `fab api` translation table
- Git-cloned [microsoft/skills-for-fabric](https://github.com/microsoft/skills-for-fabric) integration — Spark, SQL, Eventhouse, medallion skills
- Git-cloned [data-goblin/power-bi-agentic-development](https://github.com/data-goblin/power-bi-agentic-development) integration — PBIP, DAX, report, Fabric CLI skills
- Organised workspace folder structure (`.github/agents/`, `.github/skills/`, `.github/agent-docs/`, `.vscode/`)
- Git repository initialisation with clean `.gitignore` and first commit
- Workspace-level Copilot instructions (`.github/copilot-instructions.md`)
- `AGENTS.md` quick-reference guide
- VS Code settings and tasks auto-configuration
- CLI standardisation on the **Fabric CLI (`fab`)** for control-plane / data-plane work, with **`az` (Azure CLI) as a documented fallback** (SQL/TDS via `sqlcmd -G` and non-Fabric token audiences)
- Optional, resilient CLI installation — the installer offers to install `fab` and `az`, trying multiple methods (`py`/`python`/`pip --user`, and `winget` for `az`) and reporting the likely cause when an install fails (e.g. corporate security policy, missing Python/winget)
- [CLI-FUNCTIONALITIES.md](CLI-FUNCTIONALITIES.md) — categorised deep-dive of what you can do with the CLIs, with a small example per item
- Prerequisite checks for git, VS Code, Fabric extension, TMDL extension, and the optional `fab` (recommended) and `az` (fallback) CLIs
- Interactive workspace folder selection (existing folder or new)
- Multi-workspace scaffolding support
- Idempotent installer — safe to re-run on existing folders (managed files overwritten, user files untouched)
- Fabric Git integration workflow explanation during setup

### Known limitations

- Setup script is Windows-only (PowerShell + .bat)
- No automated tests yet
- Pipeline skill is manually maintained — deep maintenance mode checks freshness against Microsoft docs
- Dependency on open source repositories
- Fabric extension must be installed separately (installer checks and warns)
