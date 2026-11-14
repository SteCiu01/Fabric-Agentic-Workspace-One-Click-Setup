# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.8.0]

Introduces end-to-end Power BI custom visual development, from planning and implementation to testing, packaging and controlled release. The organization expands to 54 agents across eight teams.

### Added

- **PBIVIZ Development Team (080–086):** seven specialized agents and six skills covering visual planning, development, testing, review, maintenance and ALM.
- **Optional PBIVIZ environment:** a dedicated development folder with an independent local Git repository, integrated into the existing workspace.
- **Three-level ALM:** local versioning (Level 1), remote collaboration (Level 2) and selective DEV/TEST/PROD promotion (Level 3), with release manifests, integrity verification, provenance and approval gates.
- **Custom visual build and release tooling:** project-local SDK packaging, build evidence, dependency validation and controlled release archives.
- **Microsoft Learn MCP integration:** added without replacing existing MCP configuration.

### Changed

- Custom visual SDK development is assigned to the PBIVIZ team; the Reporting team continues to own in-report visuals and report integration.
- Agent workflows include review-finding carry-forward, improved release validation and explicit approval requirements.

### Fixed

- Improved Azure CLI detection to avoid unnecessary installation attempts.
- Hardened custom visual builds against certificate side effects, unintended dependency downloads, concurrent-build conflicts and incomplete certificate verification.
- Corrected release integrity validation for archive-only promotions and PowerShell 5.1 promotion-gate output.
- Documented safe reconciliation of rejected TEST candidates.

## [v0.7.3] - 2026-10-21

A maintenance release for installation reliability; agents, skills and orchestration are unchanged.

### Added

- `BusinessRepo.Tests.ps1` and `PythonDetection.Tests.ps1` regression suites.

### Changed

- Python selection prefers versions supported by the Fabric CLI (3.10–3.14) and explains incompatible installations.
- The installer warns when mirrored paths exceed the Windows path limit and recommends PowerShell 7 or VS Code for those folders.

### Fixed

- **Long paths in business repositories:** each mirror sets `core.longpaths=true` in its own configuration, so deeply nested Fabric items can be mirrored without changing global Git settings.
- **Branch mirroring:** `origin/HEAD` is no longer treated as a branch, and failed worktree operations show Git's own error.
- **Python detection:** existing installations are found through PATH, the Windows registry (PEP 514) and common folders; winget times out after four minutes and falls back to the python.org installer.

[Changes since v0.7.2](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/compare/v0.7.2...7d3cd7e699c9626806715875d61a4448dd1dce9d)

## [v0.7.2] - 2026-10-14

The agent team now works however the workspace folder is opened — *File > Open Folder*, *Add Folder to Workspace* or any saved `.code-workspace`.

### Added

- **User-level enablement (Step 8, default Yes):** the nested-dispatch flag and the workspace-relative skill folders are added to the VS Code user `settings.json`, edited in place with comments, formatting and BOM preserved. Its effect is described in [README Step 8](README.md#step-8-of-9--writing-configuration-files).
- **Status reporting** of the settings scope in effect, and a `GENERATED` timestamp so an outdated status block is never presented as current.
- The Master can add the setting to the open workspace file after `APPROVED:EDIT:<file>`.

### Changed

- Patching individual saved workspace files is now the fallback when the user-level option is declined.

## [v0.7.1] - 2026-10-05

A hardening release from two external reviews and a full internal pass; no new capabilities.

### Changed

- One vendor-refresh policy with explicit stop conditions, run only by 071; business repositories are never touched.
- Dispatch rules for a single shared terminal: retries never repeat writes, and parallel work requires independent artifacts.
- The Architect's PLAN and QA's VERDICT travel in a WORK RESULT `payload:` field.
- Report skills realigned to Microsoft's `powerbi-report-cli`, with `pbir` as the preferred tool.
- New `SessionStatus.Tests.ps1` and `UpdateSafety.Tests.ps1` suites.

### Fixed

- Saved `.code-workspace` files missing the window-scoped settings are detected and can be patched.
- Step 1 accepts `y`/`n` and full paths instead of crashing.
- Vendor refresh verifies the repository root and `origin`, never resets after a failed stash and reports its result accurately.
- Session workspace and JSONC settings are merged instead of rebuilt or discarded.
- Safer portable installs, winget downloads and purging of obsolete installer files.
- The Master is granted the modeling MCP connection tools and resolves workspace and item GUIDs before connecting.
- Embedded skills corrected against Microsoft documentation (pipeline variables, `compatibilityLevel`, Direct Lake modes, Warehouse fallbacks, `executeQueries` limits).
- More precise tool identity (`fab`; Tabular Editor 2, TE3 and `te`) and time-bounded status probes.

## [v0.7.0] - 2026-09-13

Makes the 47-agent organisation work as a team. Verified end to end in a real workspace, including a live semantic model publish and an approval-gated destructive action.

### Added

- **Specialist agents:** each agent carries knowledge, playbook, validation, tool-ladder and avoid sections; skill paths are resolved at install time and new upstream skills attach by keyword.
- **Native skill registration** of both cloned skill repositories in `chat.agentSkillsLocations`.
- **Team protocol:** Simple, Designed (Architect PLAN, QA VERDICT) and Blocked loops with a shared WORK ORDER / WORK RESULT contract; the WORK RESULT is the mandatory final message.
- **Approval tokens:** deleting or dropping anything requires a literal `APPROVED:<ACTION>:<artifact>` token.
- **`Get-SessionStatus.ps1`:** one deterministic startup check of skills, settings, identity, tools and MCP servers.
- **Master-owned live-model connection** passed to the teams, with a REST fallback.
- Routing for documents built from Fabric data (060) and a capability-maintenance handoff button.

### Changed

- Lean startup without menus, tier-aware agent contracts, and a skill catalog aligned to Microsoft's restructured skills.

### Fixed

- Vendor skill refresh no longer stops silently before reaching upstream.
- The installer configures nested delegation, so Team Lead → Worker dispatch works out of the box.
- Step 9 reports the commit result accurately; the `fabric-cli-policy` skill name is corrected.

## [v0.6.2] - 2026-07-25

### Added

- **Self-pruning updates:** files a previous version shipped but the current one no longer ships are removed through a strict `installed-manifest.json` difference; user files, Fabric folders and business clones are never touched.
- **Opt-in pull** for existing business clones, fast-forwarding only clean, strictly-behind branches.
- README section on keeping the workspace up to date.

### Changed

- Vendor skill repositories are force-refreshed to upstream on every run, with local edits stashed first.
- The self-test accepts user-authored agents.

## [v0.6.1] - 2026-07-20

### Added

- **Manifest JSON Schema** (`schema/agent-manifest.schema.json`) with `tools` required per agent.
- **Pester test suite and CI** for manifest integrity, hierarchy, least-privilege tools and version consistency.
- **Installer self-test and integrity manifest** (`guardrail-status.json`, SHA-256 `installed-manifest.json`).
- Repository `.gitignore`.

### Changed

- **Least-privilege tools:** every agent declares an explicit minimum `tools` set; the default is read-only.

## [v0.6.0] - 2026-07-15

### Added

- **47-agent organisation:** a Master coordinator, two executive reviewers, seven Team Leads and 37 delegated workers on a stable three-digit dropdown scheme.
- **Capability Maintenance team** for vendor refresh, skill coverage, tool detection and approved installs.
- **Cross-domain governance:** a Solution Architect, Integration QA and one writer per artifact.
- **Optional GitHub/Azure DevOps onboarding** recorded in the machine-local `repository-map.local.json` and opened as a multi-root workspace.

### Changed

- The Master is a strict coordinator and never edits an artifact itself.
- MCP availability is verified rather than assumed, with REST/CLI fallbacks.
- Tabular Editor 2 and `pbi-tools` print a portable download link on locked-down networks.
- Tool update review shows `Current` / `Update` / `Unverified` per installed CLI.
- Ownership-scoped commits, transactional portable installs, publisher-verified downloads and isolated business clones (no stored PAT, excluded from outer commits).

### Fixed

- **Agents can use the MCP servers:** the generator grants `powerbi-modeling-mcp/*` or `Fabric MCP/*` to the 27 agents that need them.

## [v0.5.1-pre-release] - 2026-07-13

### Added

- **Optional tool update check** — a single `Check for updates? (y/N)` gate looks up the latest versions of installed managed tools and offers per-tool upgrades; best-effort and silently skipped when blocked/offline.

### Changed

- **Install-failure messages point to the README** — locked-down specialist-CLI failures reference the README recovery section and its ready-to-paste agent prompt.

### Fixed

- **More robust locked-down downloads** — the winget-download path enforces a timeout, the direct-download fallback forces TLS 1.2, and a dead Tabular Editor URL was removed.

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

### Changed

- **Working-modes guidance** — startup and the working-flow reference explain the three modes and hybrid drift discipline.

### Fixed

- **Hardened `fab`/`az`/MCP installs** — more reliable PATH refresh and idempotent re-runs on corporate/locked-down machines.

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
