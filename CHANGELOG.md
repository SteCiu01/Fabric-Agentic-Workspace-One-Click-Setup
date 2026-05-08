# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet — next changes will appear here._

## [v0.1.0-pre-release] - 2026-05-04

### Added

- One-click setup via `Setup-FabricAgenticWorkspace.bat` + `.ps1` (Windows)
- **Fabric Workspace Master Agent** — slim routing hub that handles session startup, skill checks, Azure identity, and topic-based routing to specialist agents
- **Fabric Skills Maintainer** — light (quick pull) and deep (pull + MS docs freshness check + unreferenced skill scan) maintenance modes
- **Semantic Model Agent** — TMDL editing, DAX measures, columns, relationships, partitions
- **Fabric Data Engineer** — Spark notebooks, SQL warehouse, pipelines, medallion architecture
- **Fabric Admin** — capacity management, governance, security, workspace documentation
- **Fabric App Dev** — Python apps, ODBC, XMLA, REST API integration
- **Fabric Reports Agent** — PBIR report editing, visuals, themes
- **Fabric Pipelines Agent** — Data Factory pipeline JSON authoring
- Custom **fabric-tmdl** skill (embedded) — comprehensive TMDL syntax, indentation rules, property ordering, Direct Lake patterns
- Custom **fabric-pipelines** skill (embedded) — full pipeline activity type reference with typeProperties and expression syntax
- Git-cloned [microsoft/skills-for-fabric](https://github.com/microsoft/skills-for-fabric) integration — Spark, SQL, Eventhouse, medallion skills
- Git-cloned [data-goblin/power-bi-agentic-development](https://github.com/data-goblin/power-bi-agentic-development) integration — PBIP, DAX, report, Fabric CLI skills
- Organised workspace folder structure (`.github/agents/`, `.github/skills/`, `.github/agent-docs/`, `.vscode/`)
- Git repository initialisation with clean `.gitignore` and first commit
- Workspace-level Copilot instructions (`.github/copilot-instructions.md`)
- `AGENTS.md` quick-reference guide
- VS Code settings and tasks auto-configuration
- Prerequisite checks for git, VS Code, Fabric extension, TMDL extension, and az CLI
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
