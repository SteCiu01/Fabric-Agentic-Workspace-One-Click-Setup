# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.6.0] - 2026-07-15

### Added

- **47-agent organisation** — Master coordinator (`000`), 2 executive reviewers (`001`/`002`), 7 Team Leads (`010`–`070`) and 37 delegated workers, on a stable 3-digit dropdown scheme.
- **Capability Maintenance team** — owns vendor-repo refresh, skill inventory/mapping, agent coverage, installer health, tool detection and approved installs/recovery on locked-down machines.
- **Cross-domain governance** — Solution Architect for cross-domain design, Integration QA for cross-artifact validation, one writer per artifact.
- **Optional GitHub/Azure DevOps onboarding** — collects repo metadata, branch topology and write policy into machine-local `repository-map.local.json`, opened as a multi-root workspace.

### Changed

- **Master is a strict coordinator** — it routes every request to the owning team and never mutates an artifact itself; the specialist worker implements and its Team Lead reviews.
- **MCP availability is verified, not assumed** — both servers self-register (no `mcp.json`); `tool-status.json` records install + callable state, the Master runs a startup self-test and falls back to REST/CLI when tools aren't exposed.
- **Honest locked-down installs** — Tabular Editor 2 and `pbi-tools` (GitHub-release ZIPs often blocked by TLS-inspection proxies) now print the exact portable link instead of fetching a broken empty ZIP.
- **Explicit tool update review** — each installed CLI shows `Current`/`Update`/`Unverified`; confirmed versions are written back to `tool-status.json`.
- **Truthful Git + safety boundaries** — ownership-scoped commits, honest commit-result messages, transactional portable installs, publisher-verified downloads, and README warnings on initial-commit scope and Fabric Git limits.
- **Isolated business clones** — cloned once, branch refs fetched without pull/reset, dirty folders preserved, no PAT stored, excluded from outer commits; multi-root re-runs preserve user config.
- **README evolved in place** — updated agent map, maintenance ownership and installer behaviour for v0.6.0.

### Fixed

- **Agents can now actually use the MCP servers** — the per-agent `tools:` allowlist silently excluded extension-contributed MCP tools; the generator now grants `powerbi-modeling-mcp/*` (Semantic Model) or `Fabric MCP/*` (Data Eng, Admin, Fabric ALM, Apps) to the 27 relevant agents, and VS Code ignores the wildcard where the extension is absent.

## [v0.5.1-pre-release] - 2026-07-13

### Added

- **Optional tool update check** — a single `Check for updates? (y/N)` gate looks up the latest versions of installed managed tools and offers per-tool upgrades; best-effort and silently skipped when blocked/offline.

### Fixed

- **More robust locked-down downloads** — the winget-download path enforces a timeout, the direct-download fallback forces TLS 1.2, and a dead Tabular Editor URL was removed.

### Changed

- **Install-failure messages point to the README** — locked-down specialist-CLI failures reference the README recovery section and its ready-to-paste agent prompt.

## [v0.5.0-pre-release] - 2026-07-13

### Added

- **Agent → tools → skills optimization** — every agent has a bounded purpose, a minimum tool set, and loads only the skills its subtask needs.
- **Canonical tool inventory `tool-status.json`** — the installer detects each tool by its real command names/aliases and records `found`/`version`/`path`/etc.; agents read it before invoking any CLI and degrade gracefully when a tool is absent.
- **Per-specialist-tool opt-in install** — `pbir`, Tabular Editor CLI, `pbi-tools`, `sqlcmd`, `gh`, `az devops` follow detect → explain → ask Y/N → best-effort install; core tools keep their auto behaviour.
- **Skills Maintainer refreshes the tool inventory** — re-detects installed tools live and rewrites `tool-status.json` (detect-only, never installs).
- **New agent: Fabric DevOps** — ALM/DevOps coordination (Git integration, deployment pipelines, PRs/CI-CD); not an artifact-authoring agent.
- **README matrix + CLI-FUNCTIONALITIES Part II** — agent → tools → skills tables plus a provider-sourced chapter per specialist CLI.

### Changed

- **Narrow MCP ownership** — Fabric MCP with the live-read/DevOps agents, Power BI MCP with the semantic-model agents; gated on `tool-status.json`.
- **Master routes by topic, not tool availability** — a missing tool never changes the correct specialist.

## [v0.4.0-pre-release] - 2026-06-19

### Added

- **Three ways of working documented** — full local, full live (REST `updateDefinition` + MCP) and hybrid; all safe because the DevOps commit captures workspace state regardless of edit mechanism.
- **MCP server auto-install** — detects the two MCP extensions via `code --list-extensions` and installs any missing (non-blocking; only needed for live/hybrid modes).

### Fixed

- **Hardened `fab`/`az`/MCP installs** — more reliable PATH refresh and idempotent re-runs on corporate/locked-down machines.

### Changed

- **Working-modes guidance** — startup and the working-flow reference explain the three modes and hybrid drift discipline.

## [v0.3.0-pre-release] - 2026-06-17

### Changed

- **fabric-pipelines skill — battle-tested practices** — added production-generalised notes on `RefreshSQLEndpoint` semantics, Direct Lake freshness, endpoint-vs-item ids, Variable Library promotion and a pipeline-audit checklist (no proprietary data).

## [v0.2.0-pre-release] - 2026-06-15

### Added

- **House modelling decisions** in the fabric-tmdl skill (storage mode, measure home, folder taxonomy, naming, hygiene).
- **Provenance & licensing notes** across the custom skills — independent works; data-goblin's GPL-3.0 repo used only as a local reference.
- **fabric-pipelines refreshed against Microsoft docs** — added the `RefreshMaterializedLakeView` and `Approval` activities.

### Changed

- **Real freshness signals** — git commit dates for cloned repos, on-disk time for custom skills (no faked dates).
- **Resilient skill discovery** — skills found dynamically by keyword, surviving upstream folder renames.
- **Per-request routing** — the Master recommends the best specialist for free-text requests.
- **Explicit skill precedence** — custom fabric-tmdl wins on house style, data-goblin wins on TMDL/DAX correctness.

## [v0.1.0-pre-release] - 2026-05-04

### Added

- **One-click Windows setup** (`.bat` + `.ps1`) — interactive folder choice, multi-workspace scaffolding, idempotent re-runs.
- **Initial agent set** — Master + Skills Maintainer, Semantic Model, Data Engineer, Admin, App Dev, Reports and Pipelines specialists.
- **Custom embedded skills** — fabric-tmdl, fabric-pipelines and fabric-cli-policy.
- **Cloned skill sources** — microsoft/skills-for-fabric and data-goblin/power-bi-agentic-development.
- **CLI standardisation** — `fab`-first with `az` fallback, optional resilient CLI install, and the CLI-FUNCTIONALITIES.md deep dive.
- **Workspace scaffolding** — `.github/` structure, Copilot instructions, `AGENTS.md`, VS Code settings/tasks, Git init and prerequisite checks.

### Known limitations

- Windows-only setup; no automated tests yet; the pipeline skill is manually maintained; depends on open-source repos; the Fabric extension is installed separately (the installer checks and warns).
