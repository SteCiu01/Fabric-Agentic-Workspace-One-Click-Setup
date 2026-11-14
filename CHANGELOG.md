# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.8.0] - Unreleased

Adds Power BI custom visual (`.pbiviz`) development as an eighth team, with three levels of Git versioning for custom visual projects. The organisation grows from 47 to 54 agents: 3 executives, 8 Team Leads and 43 workers.

### Added

- **PBIVIZ Development Team (080–086).** A Team Lead and six workers — Planner (081), Developer (082), Tester (083), Reviewer (084, read-only), Maintainer (085) and ALM & Release (086) — plan, build, test, review, maintain and release custom visual SDK projects. The Master and the Architect route to the new team.
- **Six custom visual skills:** `pbiviz-pbip-reconstruction`, `pbiviz-source-conversion`, `pbiviz-ibcs-semantic-contract`, `pbiviz-interaction-regression`, `pbiviz-release-safety` and `pbiviz-alm-release`.
- **Optional local development environment.** Step 1 offers a PBIVIZ folder (default `0 - PBIVIZ Developing Environment`) that becomes its own Git repository on `main`, ignored by the outer repository. Existing repositories and files are reused and never committed to; OneDrive-synced paths, Git older than 2.28, nested repositories and folders tracked by the outer repository stop with a reason.
- **Three ALM levels**, run by 086 through the deterministic `Pbiviz-Alm.ps1` helper:
  - **Level 1 — local:** checkpoints, restores and release pairs on `main`.
  - **Level 2 — remote:** GitHub or Azure DevOps adoption that keeps both histories (backup refs, conflicts abort with nothing changed, no tags fetched).
  - **Level 3 — team:** selective single-visual promotion across `PBVIZ_Team_Dev`, an optional `PBVIZ_Team_Test` and `PBVIZ_Team_Prod`, through a candidate worktree gated by G0–G6.
- **Release provenance, integrity and approvals.** Releases are append-only pairs (`.pbiviz` + `.release.json`) that record the package identity read from the package content, its SHA-256, the source commit and fingerprint, build evidence, allowlisted shared files and five separate quality labels. Only `validated: true` releases reach Prod; anything with incomplete evidence stays a DEVELOPMENT/TEST CANDIDATE. Provenance is derived after merge, squash or rebase merges, and `Test-PbivizReleaseIntegrity` reports `PASS` only for complete verification (`PARTIAL` / `COMMIT ONLY` otherwise). Installs, remotes, pushes, pull requests, merges, tags, external packages and distribution each require an explicit `APPROVED:` token; the helper never pushes, merges, tags, resets or rewrites history.
- **Reliable release builds.** `Invoke-PbivizBuild` builds the package with the visual's own `powerbi-visuals-tools` from a clean checkout of the source commit and records build evidence that binds the package bytes to that commit, its fingerprint and the toolchain. The build runs under process-tree supervision with a timeout, isolated from the user profile and certificate store (disposable home, certificate-generation guard, offline npm), after a toolchain preflight that blocks any dependency download `pbiviz package` would start or any lockfile mismatch. A failed, interrupted or unverifiable build records no evidence, and archiving is transactional. Packages from outside `<Visual>/dist/` need approval bound to their SHA-256.
- **G4 dependency analysis** classifies every request form the PBIVIZ toolchain resolves — imports, `import()` and `require()` (including template literals and contexts), `new URL(..., import.meta.url)`, LESS/CSS `@import`/`url()` and paths in the visual's JSON configuration — decodes escaped request strings by their language rules, and fails closed when the analysis is incomplete. It is a static classification of the visual's own files with documented limits.
- **Microsoft Learn MCP** (`microsoftDocs`) is added to `.vscode/mcp.json` when missing, by inserting text so existing servers, comments and formatting survive; it is granted to the executives, the Team Leads and the PBIVIZ specialists. `pbiviz/*` is granted to the PBIVIZ team only.
- **Custom visual prerequisites** are detected in Step 2 (Node.js 20.19+, npm, an optional global `pbiviz`, the Git identity; nothing is installed), and the installer summary and session status show a `PBIVIZ` line with the folder, visual count, Git state and level.
- **Expanded testing.** New `PBIVIZ.Alm.Tests.ps1` and `PBIVIZ.Install.Tests.ps1` suites cover the helper and the installer's PBIVIZ setup; every defect listed under Fixed has a regression test; manifest, hierarchy, generated-content and session-status tests cover 54 agents. Acceptance in a real workspace exercised Levels 1–3 with an Azure DevOps remote, `powerbi-visuals-tools` 7.2.1 and Power BI Desktop; see [Validation, compatibility and known limitations](README.md#311-validation-compatibility-and-known-limitations).

### Changed

- **024 - Advanced & Custom Visuals Agent** now covers in-report Deneb, SVG, Python and R visuals only; `.pbiviz` SDK work goes to 080.
- **Reporting** imports custom visual packages only from a visual's `releases/` folder; **050 - ALM & DevOps** leaves the PBIVIZ repository's Git work to 086.
- **Custom visual tooling** follows one rule: detect first, obtain approval before installation or download, prefer the project-local toolchain, and never silently acquire or execute missing packages.
- **Reviews carry forward:** 080 keeps every REVIEW VERDICT and passes previous findings into each re-review; 084 numbers its findings and answers each previous one by id.
- The session status script skips informational `pbiviz-info` entries when re-checking tools.

### Fixed

Defects found during acceptance testing in a real workspace, each now covered by a regression test:

- The installer no longer reinstalls an Azure CLI that is already present when `az --version` writes a warning to stderr.
- Release builds no longer touch the user's `pbiviz-certs` folder or certificate store, and a same-named `pwsh` in a visual folder can no longer bypass the certificate-generation guard.
- Release builds never trigger the dependency download `pbiviz package` starts when the installed API package does not match `pbiviz.json`.
- A short build no longer removes the working folder of a longer build still running in the same repository.
- Integrity checks now pass for releases that reached Prod through an archive-only promotion.
- `Test-PbivizPromotionGates` returns a gate list that Windows PowerShell 5.1 can read.
- The Test stage and the reconciliation of a candidate rejected in Test (`test-sync`) are documented.

## [v0.7.3] - 2026-10-21

A maintenance release improving installation reliability, Git repository mirroring and Python detection. The 47-agent architecture, skills and orchestration are unchanged.

### Added

- `BusinessRepo.Tests.ps1` and `PythonDetection.Tests.ps1`.

### Changed

- Interpreter selection prefers Python versions supported by the Fabric CLI (3.10–3.14), with clear messages for incompatible installations; discovery is cached and refreshed after installation attempts.
- Repository synchronization supports idempotent re-runs without altering existing workspace layouts, and the installer warns when mirrored paths exceed the Windows path limit (use PowerShell 7 or VS Code for those folders).

### Fixed

- **Long paths in business repositories.** Each repository mirror gets `core.longpaths=true` in its own configuration (global Git settings are untouched), so deeply nested Fabric items no longer exceed the Windows path limit.
- **Branch detection and diagnostics.** `origin/HEAD` is no longer mistaken for a branch, and failed worktree operations show Git's own error, distinguishing missing branches from failed branch creation.
- **Python detection and installation.** Existing installations are found through PATH, the Windows registry (PEP 514) and common folders; the winget attempt times out after four minutes and falls back to the python.org installer.

[Changes since v0.7.2](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/compare/v0.7.2...7d3cd7e699c9626806715875d61a4448dd1dce9d)

## [v0.7.2] - 2026-10-14

The agent team now works however the workspace folder is opened — *File > Open Folder*, *Add Folder to Workspace* or any saved `.code-workspace` — and an installer re-run reaches all of those windows. The two VS Code settings the team depends on (`chat.subagents.allowInvocationsFromSubagents` and `chat.agentSkillsLocations`) are window-scoped, and only user-level settings reach every window.

### Added

- **Step 8 user-settings option** ("Enable the agent team in your VS Code user settings now? (Y/n)", default Yes, never silent). It edits `%APPDATA%\Code\User\settings.json` in place: the nested-dispatch flag is set to `true` and the current workspace-relative skill folders are merged into `chat.agentSkillsLocations`. Comments, key order, formatting, line endings and BOM are preserved; the file is validated before writing; re-runs are idempotent; absolute and `~/` paths are never written at user level. VS Code profile settings files are listed for manual update. What the setting does and does not enable is described in [README Step 8](README.md#step-8-of-9--writing-configuration-files).
- **Status script** reports which scope is in effect (user level, folder `settings.json` only, or not set) and how many workspace-relative skill folders resolve, and stops warning about saved workspace files once the user-level setting is present (`FABRIC_AGENTIC_USER_SETTINGS` overrides the path for tests).
- **Stale status protection.** Every status block starts with `GENERATED <timestamp>`; the Master retries in a new terminal before reading the saved copy and never presents a block older than about an hour as current.
- The Master can offer to add the setting to the open workspace file after `APPROVED:EDIT:<file>`.
- Tests for the in-place user-settings edit (JSONC, BOM, idempotency, refused broken files), the scope reporting and the status timestamp.

### Changed

- The v0.7.1 saved-workspace patching is now a fallback, used only when the user-level option is declined.
- Generated `copilot-instructions.md` / `AGENTS.md`, the Master's dispatch-health rule and the README describe the scoping model.

## [v0.7.1] - 2026-10-05

A hardening release driven by two external reviews and a full internal pass over the installer, the generated agents, the embedded skills and the tests. It adds no new capabilities: it aligns what agents are told with what they can do, what the installer reports with what happened, and the embedded guidance with Microsoft's documented behaviour.

### Changed

- **One vendor-refresh policy** for the maintenance team, with explicit stop conditions (not a repository root, wrong `origin`, fetch or stash failed), executed only by 071; business repositories under `source-control-repositories/` are never touched.
- **Terminal rules for a single shared terminal:** parents sequence terminal work, multi-statement work goes into uniquely named `scripts/<agent>-<purpose>-<timestamp>.ps1` files, "no output" is not treated as a wedged shell, and agents without `edit` get a single-statement variant.
- **WORK RESULT `payload:` field** carries the Architect's PLAN and QA's VERDICT verbatim inside the mandatory wrapper.
- **Report skills realigned** to Microsoft's consolidated `powerbi-report-cli`, with explicit tool precedence: `pbir` first, Microsoft's `powerbi-report-author` only when `pbir` is absent and the user agrees, direct PBIR JSON editing as a disclosed last resort.
- **Safer dispatch:** retries never repeat writes (an interrupted write dispatch is resumed inspect-first); parallel dispatch requires independent artifacts and at most one terminal user; MCP connection guidance is emitted only to agents that hold the grant, and a failed connection is passed down as final.
- **Renamed upstream skills** resolve by a two-token, then one-token prefix, only when exactly one candidate remains.
- **Tests:** new `SessionStatus.Tests.ps1` (the emitted status script, offline) and `UpdateSafety.Tests.ps1` (JSONC parsing, workspace merges, purge and commit invariants); CI also runs on README and CHANGELOG changes.

### Fixed

- **Saved workspace files.** A window opened from a user-saved `.code-workspace` ignores the folder's window-scoped settings, so Team Leads could not dispatch workers. Step 8 now detects saved files that open the folder and offers to add only the missing entries; the status script names any file still lacking the dispatch setting. `settings.json` is written without a BOM.
- **Step 1 prompts.** `y`/`n` map to options 1/2, invalid input re-asks, and a full path at the name prompt is accepted instead of crashing (`Step1Prompts.Tests.ps1`).
- **Vendor refresh safety.** A vendor folder must be the root of its own repository with the expected `origin`; a failed stash never leads to a hard reset, and success is reported only when `HEAD` equals the upstream commit.
- **Workspace and settings merges.** The session workspace file is merged instead of rebuilt and keyed per workspace folder; JSONC settings with comments or trailing commas are parsed instead of discarded.
- **Install integrity.** Portable tool activation can no longer delete a good install; winget payloads are used only after exit code 0; obsolete installer files are purged reliably with path-containment checks, and retired files are staged in the update commit.
- **Live connections.** The Master is granted the Power BI modeling MCP for connection management, and resolves workspace and item GUIDs to display names before `ConnectFabric`; a test fails when an agent references a tool it is not granted.
- **Skills corrected against Microsoft documentation:** pipeline variables use `@variables('Name')`; `compatibilityLevel` is preserved; Direct Lake on SQL and on OneLake are distinguished; XMLA is no longer a Warehouse T-SQL fallback; the documented `executeQueries` limits replace an over-broad live-coverage claim.
- **Tool identity and status.** `fab` detection requires the Microsoft Fabric CLI banner; Tabular Editor 2, TE3 and the `te` CLI are detected separately; identity probes are bounded by a timeout, stale paths are replaced and detect-only tools are not reported as missing.

## [v0.7.0] - 2026-09-13

Refines how the 47-agent organisation works as a team: nested delegation is configured by the installer, every agent becomes a documented specialist, the teams share one work protocol, and the vendor skill refresh is hardened. Verified end to end in a real workspace, including a multi-team plan with a live semantic model published to Fabric and an approval-gated destructive action.

### Added

- **Per-agent specialist knowledge.** Every agent carries Knowledge and skills (owned artifacts, write permission, the skill paths to read and why), Playbook, Validation, Tool ladder and Avoid sections. Skill paths are resolved at install time; renamed upstream folders are self-healed by prefix match and missing ones marked for keyword re-discovery.
- **Auto-discovered skills.** Upstream `SKILL.md` files are indexed at install time and matched to agents by keyword, so new Microsoft or Kurt skills attach to the right specialist on the next installer run.
- **Native skill registration.** Every skill folder from both clones (and the Synapse extension) is registered in `chat.agentSkillsLocations`; `Get-SessionStatus.ps1` registers new upstream folders at session start.
- **Team protocol.** Three loops (Simple; Designed, with an Architect PLAN and a QA VERDICT; Blocked, with an approval bubble), a routing map and the WORK ORDER / WORK RESULT contract (`DONE | DONE WITH RISKS | NEEDS APPROVAL | NEEDS INPUT | NEEDS ARCHITECT | OUT OF SCOPE | FAILED`); Team Leads get rosters and dispatch rules.
- **Strict destructive-action approval.** Deleting or dropping any artifact is destructive even when requested in plain words; it requires a literal `APPROVED:<ACTION>:<artifact>` token, and agents without it return `NEEDS APPROVAL`.
- **`Get-SessionStatus.ps1`.** One deterministic startup call replaces about eight probes: skill freshness, skill registration, nested-dispatch check, identity (`fab` → `az`) and a live tool re-check. MCP servers are reported as installed, never as connected, and the block is saved to `session-status.last.txt`.
- **Master-owned live-model connection.** The Master opens the Power BI modeling MCP connection in the main chat and passes it down in every WORK ORDER; Leads and workers reuse it or go straight to the REST fallback. Fabric MCP is probed lazily by the owning Lead.
- **Reliable dispatch.** The WORK RESULT is the mandatory final message (a missing one is treated as `FAILED` and re-dispatched once); `Requested agent '<name>' not found` is retried safely; executing agents follow terminal hygiene rules.
- **Routing for documents** built from Fabric data (Word, Excel, PowerPoint, PDF) to 060 with QA by 002, and a Master handoff button for capability maintenance.

### Changed

- **Lean startup:** no menus — one status call, one status block, then the request. MCP servers are no longer probed at every session start, and the Master routes everything itself.
- **Tier-aware operating contracts:** workers receive a lean contract built around their WORK ORDER; Leads and executives keep the full contract. The Master lists only its nine children.
- **Skill catalog** aligned to Microsoft's restructuring of 2026-09-10 (merged `*-cli` skills; new deployment-pipeline, Git-integration, OneLake catalog, variable-library, cost-estimation and event-schema skills) and Kurt's `goblin-mode` plugin.

### Fixed

- **Vendor skill refresh** could stop silently before resetting to upstream because Git's stderr progress tripped `ErrorActionPreference = 'Stop'`. It now reports `refreshed: <old> -> <new>` or `already at upstream` and falls back to `@{upstream}`; `git clone`/`init`/`add` get the same handling.
- **Nested delegation** is written by the installer to the generated `.code-workspace` and `.vscode/settings.json`, so Team Lead → Worker dispatch works out of the box; the Master's direct-to-worker fallback was removed.
- **Step 9** reports the commit result by checking whether `HEAD` moved.
- The manifest skill name `fabric-tool-policy` is corrected to `fabric-cli-policy`, and the maintenance policy wording is aligned between 070 and 071.

## [v0.6.2] - 2026-07-25

### Added

- **Self-pruning installer.** Files a previous version shipped but the current one does not are removed using the strict difference between the old and new `installed-manifest.json`, scoped to installer-owned paths. It is never a folder sweep: user files, Fabric folders, business clones and machine-local state are never touched, and the purge is skipped for an unrecognised manifest schema.
- **Opt-in pull for existing business clones** (`Pull existing branches so they match online? (y/N)`): only clean, strictly-behind branches are fast-forwarded.
- **README "Keeping it up to date"** section describing update behaviour and which files to edit.

### Changed

- **Vendor skill repositories are force-refreshed to upstream** on every run (`fetch --prune` + `reset --hard origin/HEAD`); local edits are stashed first and remain recoverable with `git stash list`.
- **The self-test respects user-authored agents:** it requires every managed agent and reports extra agent files as preserved.
- **Capability Maintenance agents (070, 071)** describe the force-refresh model.

## [v0.6.1] - 2026-07-20

### Added

- **Manifest JSON Schema** (`schema/agent-manifest.schema.json`, draft-07) for the embedded 47-agent manifest, with `tools` required per agent.
- **Pester test suite and CI** validating manifest integrity, hierarchy (single root, no cycles, delegation only through the `agent` tool), least-privilege tools and version consistency on every push and pull request.
- **Installer self-test and integrity manifest:** `guardrail-status.json` and a SHA-256 `installed-manifest.json` of every generated file.
- **Repository `.gitignore`** for the local virtual environment, test artifacts and generated status files.

### Changed

- **Least-privilege tools:** all 47 agents declare an explicit minimum `tools` set; the default is read-only, and `edit`, `execute` and `agent` are granted only where a role needs them.

## [v0.6.0] - 2026-07-15

### Added

- **47-agent organisation:** a Master coordinator (`000`), two executive reviewers (`001`, `002`), seven Team Leads (`010`–`070`) and 37 delegated workers on a stable three-digit dropdown scheme.
- **Capability Maintenance team** for vendor refresh, skill and agent coverage, installer health, tool detection and approved installs or recovery on locked-down machines.
- **Cross-domain governance:** a Solution Architect for cross-domain design, Integration QA for cross-artifact validation, and one writer per artifact.
- **Optional GitHub/Azure DevOps onboarding** that records repository metadata, branch topology and write policy in the machine-local `repository-map.local.json` and opens the clones as a multi-root workspace.

### Changed

- **The Master is a strict coordinator:** it routes every request to the owning team and never edits an artifact itself.
- **MCP availability is verified, not assumed:** both servers self-register (no `mcp.json`), `tool-status.json` records installed and callable state, the Master runs a startup self-test, and agents fall back to REST/CLI when MCP tools are not exposed.
- **Locked-down installs:** Tabular Editor 2 and `pbi-tools` print the exact portable download link instead of fetching an empty ZIP through a TLS-inspection proxy.
- **Tool update review** shows `Current` / `Update` / `Unverified` per installed CLI and records confirmed versions.
- **Git and safety boundaries:** ownership-scoped commits, accurate commit messages, transactional portable installs, publisher-verified downloads, and README warnings on initial-commit scope and Fabric Git limits. Business clones are cloned once, fetched without pull or reset (dirty folders preserved), never store a PAT and are excluded from outer commits; multi-root re-runs keep user configuration.
- README updated for the new organisation and installer behaviour.

### Fixed

- **Agents can use the MCP servers.** The per-agent `tools:` allowlist excluded extension-provided MCP tools; the generator now grants `powerbi-modeling-mcp/*` or `Fabric MCP/*` to the 27 agents that need them (ignored where the extension is absent).

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
