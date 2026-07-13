# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.5.1-pre-release] - 2026-07-13

### Added

- **Optional tool update check** — after building the tool inventory, the installer now asks a single `Check installed tools for updates now? (y/N)` gate (default No, so normal runs stay fast). On Yes it looks up the latest published version of every installed managed tool (PyPI for `fab`/`az`/`pbir`, the GitHub Releases API for `gh`/`sqlcmd`/Tabular Editor/`pbi-tools`, the `az` extension index for `az devops`) and, **only when the installed version is genuinely behind**, prompts a per-tool `Y/N` to upgrade. Upgrading re-runs the tool's normal install action; the refreshed version is written back to `tool-status.json`. Every lookup is best-effort — blocked or offline lookups (common on locked-down/proxied networks) are silently skipped, never nagging or erroring. GUI tools (Tabular Editor) are version-probed via file metadata and are never launched

### Fixed

- **Optional-tool downloads are more robust on locked-down machines** — the winget-download install path now enforces a timeout so a stalled corporate proxy can no longer hang the installer indefinitely; the direct-download fallback now forces TLS 1.2 (PowerShell 5.1 did not enable it by default, causing instant "connection closed" failures against modern CDNs); removed a dead Tabular Editor fallback URL that returned 404

### Changed

- **Specialist-CLI install-failure messages now point to the README** — when an optional specialist CLI (or the Azure DevOps extension) cannot be installed on a locked-down PC, the installer prints a pointer to the README **Corporate / locked-down PCs** section and its ready-to-paste agent prompt, so the tool can be finished via the Master agent

## [v0.5.0-pre-release] - 2026-07-13

### Added

- **Agent → tools → skills optimization** — every agent now has a bounded purpose, owns a minimum set of deterministic tools, and loads **only the skills its current subtask needs** (no more eager "read all skills"). Each specialist body opens with a "Tool availability — read this FIRST" block and a "Skill loading — minimum necessary" block
- **Canonical tool inventory `tool-status.json`** — the installer detects every tool (honoring real command names/aliases, e.g. `TabularEditor.exe`/`TabularEditor2.exe`/`TabularEditor3.exe` rather than `te`) and writes `.github/agent-docs/tool-status.json` (gitignored, machine-specific) with `found`, `version`, `command`, `path`, `category`, `installMode`, and a `reason` when missing. Agents read `<key>.found` before invoking any CLI/MCP and degrade gracefully when a tool is absent
- **Per-specialist-tool opt-in install** — new specialist tools (`pbir`, Tabular Editor CLI, `pbi-tools`, `sqlcmd`, `gh`, `az devops`) are handled as **detect → explain provider/purpose/link → ask Y/N → best-effort install only on Yes → on failure warn + manual link + continue**. Core tools (Python, `fab`, `az`, the two MCP servers) keep their existing auto best-effort behaviour; nothing heavy is installed silently. All six are also listed in the README **Prerequisites** table
- **Skills Maintainer refreshes the tool inventory** — the Fabric Skills Maintainer agent (light and deep modes) now re-detects installed tools live (`Get-Command`/`--version`, `code --list-extensions`, `az extension list`) and rewrites `tool-status.json` (detect-only; never installs). Combined with installer re-runs (detection precedes the "previously declined" check, so a tool you install yourself flips to `found: true` on the next run) and a per-agent runtime re-check, a tool installed after setup is picked up automatically
- **New agent: 9 — Fabric DevOps Agent** — ALM/DevOps coordination for Fabric Git Integration, Deployment Pipelines, Azure DevOps & GitHub PRs/CI-CD/boards, branch & PR workflows, PBIP DevOps, and conflict/PR review of text-based Fabric definitions. It is explicitly **not** an artifact-authoring agent: it may read TMDL/PBIR/pipeline skills read-only to understand structure, then hands design decisions back to Agents 3/7/8
- **README agent → tools → skills matrix and tool-coverage table** — documents each agent's bounded purpose, owned tools, and selective skills, plus a coverage table proving every checked tool has an agent-level owner
- **README "Agentic design principles" section** — a best-practices scorecard (bounded scope, deterministic tool gating, graceful degradation, anti-soup context loading, topic-based routing, deterministic startup, safety guardrails, skill precedence, resilient discovery) showing how all nine agents satisfy each principle, plus a callout on the Master agent's mandatory startup/self-check protocol
- **CLI-FUNCTIONALITIES.md is now a two-part "mini-book"** — Part I keeps the workload-first `fab`/`az` deep dive (sections 0–21); Part II adds an accurate, provider-sourced chapter for each specialist CLI (`pbir`, Tabular Editor CLI, `pbi-tools`, `sqlcmd`, `gh`, `az devops`) using a consistent template (purpose · owning agent · `tool-status.json` key/aliases · common commands · fallback when absent · provider link · caveats)

### Changed

- **Fabric MCP server ownership is now explicit and narrow** — Agents 4 (live OneLake/item reads) and 9 (live workspace item GUIDs/inspection during Git Integration / Deployment Pipeline setup); Power BI semantic-model MCP stays with Agents 3 and 6. MCP usage remains advisory body policy gated on `tool-status.json`, not hard-listed in frontmatter, for corporate-PC resilience
- **Master routes by topic, not tool availability** — a missing tool never changes the correct specialist; the specialist reads `tool-status.json` and falls back. Topic menu and per-request routing now include the DevOps agent ([9])

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
