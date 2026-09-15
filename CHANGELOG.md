# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.7.0] - 2026-09-13

This release fine-tunes how the 47-agent organisation works together: nested delegation is configured by the installer, every agent becomes a documented specialist, the teams share one work protocol, and the vendor skill refresh is hardened. Verified end-to-end in a real workspace: single-team TMDL work, a multi-team plan (Architect → Semantic + Data Engineering leads → QA) with a live semantic model published to Fabric and regression DAX run against it, and a two-way approval bubble for destructive actions.

### Fixed

- **Vendor skill refresh could silently stop short.** In `Update-VendorClone`, git's normal stderr progress combined with the script-wide `$ErrorActionPreference = 'Stop'` could interrupt the refresh before the `reset --hard origin/HEAD` step, leaving a clone behind upstream without any message. The function now runs with a local `Continue` preference, checks `$LASTEXITCODE`, prints `refreshed: <old> -> <new>` / `already at upstream`, and falls back to `@{upstream}` for clones without `origin/HEAD`. The same stderr handling is applied to `git clone`/`init`/`add`, and a dedicated regression test covers the refresh.
- **Nested delegation is now configured by the installer.** VS Code only lets subagents spawn further subagents when `chat.subagents.allowInvocationsFromSubagents` is `true`; the installer now writes it into both the generated `.code-workspace` (required for multi-root windows) and `.vscode/settings.json`, so the Team Lead → Worker hop is available out of the box. The earlier direct-to-worker fallback on the Master is no longer needed and has been removed.
- **Commit result reporting** at the end of Step 9 now checks whether `HEAD` moved instead of relying on a stale `$LASTEXITCODE`.
- **Manifest skill name** `fabric-tool-policy` corrected to the real custom skill `fabric-cli-policy` across all agents.
- **Maintenance policy wording** aligned between the Capability Maintenance lead and the Upstream Repository Sync worker (stash local edits, then mirror `origin/HEAD`).

### Added

- **Per-agent specialist knowledge.** Every generated agent now carries a `Knowledge and skills` section (owned artifacts, write permission, the exact custom / Microsoft / Kurt skill paths to read and why), a numbered `Playbook`, `Validation you must run before reporting`, a `Tool ladder` (preferred → fallback → last resort, gated by `tool-status.json`) and `Avoid`. Skill paths are resolved at install time; a renamed upstream folder is self-healed by prefix match (e.g. `spark-authoring-cli` → `spark-cli`) and annotated, a missing one is marked *re-discover by keyword*.
- **Auto-discovered skills.** Each agent has topic keywords; at install time all upstream `SKILL.md` files are indexed (name + description) and matches are appended as *"Also relevant – auto-discovered"* with the skill's own description. New Microsoft/Kurt skills therefore attach to the right specialist on the next installer run without a catalog edit.
- **Native skill registration.** `chat.agentSkillsLocations` now lists every skill container found in both clones (plus the Synapse extension's skills, detected by version), so agents see the full skill catalogue natively instead of `ls`/grep hunting on every hop. `Get-SessionStatus.ps1` re-registers new upstream folders at session start.
- **Team protocol.** `working-flow-reference.md` defines the three loops (Simple, Designed with Architect PLAN + QA VERDICT, Blocked with approval bubble), the routing map, and the `WORK ORDER` / `WORK RESULT` contracts (`DONE | DONE WITH RISKS | NEEDS APPROVAL | NEEDS INPUT | NEEDS ARCHITECT | OUT OF SCOPE | FAILED`). Team Leads get a roster table and dispatch rules; the Architect returns a structured PLAN and may be consulted mid-work by a Lead; QA returns a VERDICT.
- **Strict destructive-action approval.** Deleting or dropping any artifact, table, column, measure, relationship, role, item, branch or file is destructive *even when the user asked for it in plain words*. The Master confirms once and requires a literal `APPROVED:<ACTION>:<artifact>` token; dispatched agents without the token return `NEEDS APPROVAL` and change nothing. Verified: a worker refused to delete a file that the token did not name.
- **`Get-SessionStatus.ps1`** — one deterministic call replaces the previous ~8 startup probes: skill freshness (git commit dates), registered skill locations + self-heal, nested-dispatch check, identity (`fab` → `az`), and a live tool re-check that refreshes `tool-status.json` in place. CWD-independent. Reports MCP servers on their own line as *installed / connected: none yet* (installed is never presented as callable) and persists the block to `.github/agent-docs/session-status.last.txt` so the Master can read it even when the shared shell swallows stdout.
- **Master owns the live-model connection.** Dispatched agents cannot answer sign-in prompts and an empty `ListConnections` on a fresh session is not "not callable", so for live semantic-model work the Master opens the Power BI modeling MCP connection itself (`connection_operations` → `ConnectFabric`) in the main chat and passes `mcp connection: <name>` down in every WORK ORDER; Leads and workers reuse it as rung 1 of their tool ladder and go straight to the REST fallback when the context says `none`. Fabric MCP keeps the lazy first-use probe by the owning Lead.
- **WORK RESULT is the mandatory final message.** A dispatched turn that ends without the block, or ends on a statement of intent, is treated as `FAILED`; parents re-dispatch the same agent once with a resume instruction instead of doing the work themselves. `Requested agent '<name>' not found` with an exact name is documented as a retry-safe registry flake (pause, up to 3 retries, never substitute another agent).
- **Terminal hygiene for every agent that can execute:** multi-statement PowerShell goes into a `.ps1` under `scripts/` and runs with `-File`; results are read from files; a wedged shell means a new terminal.
- **Routing map:** documents, decks and briefings built from Fabric data (Word/Excel/PowerPoint/PDF) are owned by 060 Applications & Integration with QA by 002.
- **Handoff button** on the Master for capability maintenance (the one legitimate "switch agent" case).

### Changed

- **Lean startup.** No blocking menus: one status-script call, one compact status block, then straight to the user's request. MCP servers are probed lazily by the owning Team Lead on first live use instead of at every session start. The topic menu and "switch agent in the dropdown" instructions are gone; the Master routes everything itself.
- **Tier-aware operating contracts.** Workers receive a lean contract (their WORK ORDER is the complete brief; they never re-read flow docs and cannot ask the user); Leads/executives keep the full contract including dispatch-health guidance. The Master lists only its nine children in `agents:`.
- **Skill catalog aligned to upstream restructuring** (Microsoft 2026-09-10): merged `*-authoring/consumption/operations-cli` skills, new `deployment-pipelines-authoring-cli`, `git-integration-operations-cli`, `onelake-catalog-govern-cli`, `variable-library-cli`, `e2e-fabric-cost-estimation`, `eventschemaset-cli`; Kurt `goblin-mode` plugin.
- Generated agent files now carry role-specific guidance in addition to the shared operating contract.

## [v0.6.2] - 2026-07-25

### Added

- **Self-pruning installer** — the installer now removes files it shipped *before* but no longer ships (renamed/removed agents, superseded configs, dropped skills). It reads the previous `installed-manifest.json` write-log, removes only the strict `old − new` set difference scoped to installer-owned roots, and excludes machine-local state (`tool-status.json`, `guardrail-status.json`, `installed-manifest.json`, `repository-map.local.json`). It is never a directory sweep, so user files, Fabric workspace folders and business clones are never touched; the purge is skipped on an unrecognised manifest schema.
- **Opt-in pull for existing business clones** — when a re-run finds a repository already cloned under `source-control-repositories/`, it asks *"Pull existing branches so they match online? (y/N)"* (default No). On accept it fast-forwards **only** clean, strictly-behind branch worktrees; dirty or diverged branches are left as-is for a manual pull. Declining keeps the previous fetch-only behaviour.
- **README "Keeping it up to date" contract** — a new maintainability section documents how updates behave and exactly which files users should and should not edit.

### Changed

- **Authoritative-from-upstream vendor refresh** — `skills-for-fabric/` and `power-bi-agentic-development/` are now force-refreshed to upstream on every run (`fetch --prune` + `reset --hard origin/HEAD`) instead of a fast-forward-only pull. Local edits are auto-stashed onto a timestamped stash first (recoverable via `git stash list`), so the references always mirror live upstream and never silently drift.
- **Self-test respects user-authored agents** — the post-generation check now asserts *all managed agents are present* and reports any extra `*.agent.md` files as preserved, instead of requiring an exact manifest count, so adding your own agent no longer trips a false failure.
- **Re-scoped Capability Maintenance agents** — the Upstream Repository Sync Agent (`071`) and the Environment & Tooling Team Lead (`070`) now describe the force-refresh model rather than the previous "clean-repository `git pull --ff-only`, never reset" behaviour.

## [v0.6.1] - 2026-07-20

### Added

- **Machine-checkable manifest contract** — a draft-07 JSON Schema (`schema/agent-manifest.schema.json`) now defines the embedded 47-agent manifest, with `tools` a required per-agent field.
- **Pester test suite + CI** — `tests/` validates manifest integrity, hierarchy (single root, no cycles, delegation only via the `agent` tool), least-privilege tool scoping and version consistency; a GitHub Actions workflow (`.github/workflows/validate.yml`) runs it on every push and pull request.
- **Installer self-test & integrity manifest** — after generating the agents the installer re-scans them, writes an advisory `guardrail-status.json`, and stamps an `installed-manifest.json` with a SHA-256 of every generated file.
- **Repository `.gitignore`** — excludes the local virtual environment, test artifacts and generated runtime status files.

### Changed

- **Least-privilege tools** — all 47 agents now declare an explicit minimum `tools` set; the manifest default is read-only (`read`, `search`), so `edit`/`execute`/`agent` (delegation) are granted only where a role needs them.

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
