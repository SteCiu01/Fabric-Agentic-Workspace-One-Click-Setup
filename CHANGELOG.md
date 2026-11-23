# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.9.0]

Refreshed upstream skills are checked against what the agents rely on, agent working files get one home and a guarded clean-up, a pipeline definition is checked offline before it is saved, and no tool is installed without a typed Yes.

**Upgrading:** re-run the installer over your workspace to get the new skills and the regenerated agents. Optional tools are installed only after you answer `Y` or `YES`, so an unattended run now only detects tools. A PBIVIZ repository with a remote needs it reachable to promote.

### Added

- **Skills compatibility hold.** After each refresh, the installer and Capability Maintenance check every skill path the agents pin. If upstream renamed, removed or split one, the catalogue stays on its last compatible commit until a later refresh fits; you are asked nothing, and the session status names a held catalogue.
- **Agent working folder** `0 - Team of Agents Local Files/` (git-ignored) and the **`fabric-housekeeping` skill**: agents work in one task folder per request, clean up at the end, never touch another session's folder and keep credentials out of files. The installer creates the folder and never moves or removes existing content; a root `scripts/` folder is no longer used for scratch work.
- **Housekeeping in Capability Maintenance** (`Agent-Workspace.ps1`): a read-only preview classifies working files and prints approval tokens; execute moves approved files to a quarantine you can restore from, and a purge needs a second token. Git-tracked files are never moved, and a possible secret is reported by path, never by value.
- **`Test-PipelineDefinition.ps1`**: an offline, read-only check of a pipeline definition, with the result `PASS`, `UNCHECKED` (something could not be checked) or `BLOCKED`. It checks activity types, dependencies, expressions, credential-like values, and workspace, item and connection ids against the target workspace's inventory (`-InventoryPath`), and prints a change plan. A reference to an item of the wrong type is `BLOCKED`. A reference written as an expression (a parameter, a variable, a Variable Library value) is `UNCHECKED` (`PD088`), because its value exists only when the pipeline runs; `@pipeline().DataFactory` as the workspace id is the one exception.
- **Deployment safeguards for the pipeline agent (036).** A save needs the approval token `APPROVED:DEPLOY:<pipeline name>` and a `PASS`, or your decision on each `UNCHECKED` point. `BLOCKED` is never saved, and a definition read from one workspace is never sent to another.
- **`fabric-ai-readiness` skill** for preparing a semantic model for Copilot and Fabric data agents. It separates what agents change in the model, what they only draft for you (AI instructions, AI data schema, verified answers) and the settings only a person changes (Q&A, *Approved for Copilot*, tenant settings); a check that was not run is reported as NOT RUN.
- **SQL permission classes** in the `fabric-cli-policy` skill, from `S0` (definition work) to `S4` (administration), decided before the route (`sqlcmd -G` first, then the Fabric Data Warehouse MCP server); a SQL tool being present is never permission. A data or schema change (`S3`) needs an approval token that names the statement and the object, such as `APPROVED:INSERT:dbo.Stage`.
- **Remote MCP servers are detected, not assumed.** `tool-status.json` and the session status say whether `.vscode/mcp.json` holds an entry for the Fabric IQ or the Fabric Data Warehouse MCP server; the installer adds, configures and signs in to neither. Agents name the state they can prove: documented, configured, callable, signed in or executed.
- `-StopAfterStep1`: runs the Step 1 questions and exits before anything is detected, installed or generated.
- **Documentation workflow for maintainers** (in `.github/`, not shipped by the installer): a review is bound to one Communication Writer run and one session, the Writer may change five documents only, policy and legal documents need a recorded owner approval of their exact text, and `Doc-Review.ps1 -Gate` is the release gate. See [CONTRIBUTING](CONTRIBUTING.md#keeping-the-documentation-current).

### Changed

- **Every optional install asks first.** The Fabric CLI, Python, the Azure CLI and the two MCP extensions are each offered with a `(Y/N)` question and installed only on `Y` or `YES`; tools you already have are detected as before. A No is not remembered: a tool that is still missing is offered again on the next run.
- Looking for a tool no longer changes the user PATH: a tool found outside PATH is used for the current run only.
- **`fabric-pipelines` skill rewritten** against Microsoft Learn. Every activity and template carries an evidence class, and new sections cover the SQL analytics endpoint refresh, system variables, what moves between environments and how to change a deployed pipeline safely.
- Project Osmos: its auth and routing files stay in the workspace's `.dataprojects/` and survive a skills refresh. `tool-status.json` records the detected Python version and whether it meets the 3.11 requirement.
- A reference file that moved inside a skill that is still present points the agent at the skill folder instead of counting as unresolved.
- The session status script registers new skill folders in place, so comments and formatting in `.vscode/settings.json` survive.
- **`.gitignore` for Power BI project files:** a new workspace ignores the two per-machine files (`**/.pbi/localSettings.json`, `**/.pbi/cache.abf`) instead of every `.pbi/` folder, so `editorSettings.json` and `unappliedChanges.json` stay visible to Git. An existing `.gitignore` keeps every line it has.
- The Warehouse (033), SQL database (034), SQL data access (063), Fabric intelligence (038) and monitoring (043) agents state the SQL class and the MCP state they reached. 033 holds the tool grant for the Fabric Data Warehouse MCP server, 038 and 043 the read-only Fabric IQ grant; a grant has no effect until you add that server to `.vscode/mcp.json` yourself. No tool of the Fabric Data Warehouse MCP server is named: 033 uses a tool the server itself lists for running T-SQL and reports a missing or ambiguous tool instead of guessing.
- Microsoft's `powerbi-report-author` CLI is described as a detect-only companion to `pbir`, never as a second way to edit a report.
- House skills describe their origin in neutral words, and examples use placeholder identifiers.
- **README diagrams** (the overview, the three working modes and the lifecycle) are rebuilt in one style from editable HTML sources in `assets/diagram-source/`. The overview now shows 11 custom skills.

### Fixed

- **An unanswered install question could count as Yes.** When input ended before an install or update question was answered (a closed window, redirected input, an unattended run), the installer went on to install or update. Only `Y` or `YES` (any case) now does.
- At end of input the workspace-name question in Step 1 no longer repeats forever when the default folder name already exists; the workspace is skipped.
- **The launchers gave no sign of a failed run.** `Setup-FabricAgenticWorkspace.bat` now says when setup did not complete and returns the exit code. `tests/Run-Tests.bat` ends with `RESULT: PASSED` or `RESULT: FAILED` and returns a non-zero exit code when a test failed or the run did not start.
- **Setup ended with "Setup complete!" after skipped steps.** When something was skipped, the final message is now "Setup finished with N warning(s)" with the list. These are warnings, so the exit code stays 0.
- **An optional install was reported as successful when the command was only on PATH.** Success now needs exit code 0 from the install command and a working tool (the Fabric CLI must answer `fab --version`).
- **A Git refusal ended setup with a raw error.** When Git refuses the workspace folder (for example an ownership check), the commit is skipped with a warning that names Git's reason, and the PBIVIZ step says that Git could not be started instead of `git not found`.
- **A skills clone that Git refused to open was called "not the root of its own Git repository".** The installer and Capability Maintenance now say what Git said (for example `detected dubious ownership`), keep the folder and record the catalogue as `blocked`.
- **Skipped refreshes looked fresh.** The session status showed today's date for a skills catalogue that had not been refreshed. The date now moves only after a clone or refresh that took place.
- **SQL analytics endpoint refresh template:** it used the type `RefreshSQLEndpoint` with the lakehouse id, which Fabric rejects. The activity is `RefreshSqlEndpoint` with `workspaceId`, `sqlEndpointId` (the endpoint item, not the lakehouse) and a connection.
- Eleven further pipeline templates used activity type identifiers that the published definition does not have (`DataflowGen2`, `KQL`, `Webhook`, `StoredProcedure`, `SQLScript`, `HDInsightActivity`, `FunctionsActivity`, `CopyJob`, `AzureBatch`, `AzureDatabricks`, `Deactivate`); they are replaced by the published ones or removed. Three templates whose JSON is not published (lakehouse maintenance, materialized lake view refresh, approval) are no longer offered as templates.
- Pipeline guidance said `pipeline().Pipeline` is the pipeline name (it is its id) and mapped Variable Library `Number` values to `Double` (pipelines cannot use them).
- **Dashes reached some agent files as garbled characters**, in the description of the Power BI ALM agent and in the instructions of the Master and the Capability Maintenance team. The installer now holds ASCII characters only, because Windows PowerShell 5.1 reads a script without a byte order mark in the ANSI code page.
- **A PBIVIZ promotion could start from an outdated Prod.** The target must now be the current production revision, read from the remote's `PBVIZ_Team_Prod` (or from the local branch when the repository has no remote); a stale or different target, or a revision that cannot be verified, is refused before anything is written. New optional parameters: `-Remote` (default `origin`) and `-ProdBranch`.
- **Chat sessions overwrote each other's session status.** `Get-SessionStatus.ps1` now takes `-SessionId <id>` and also saves its block to `.github/agent-docs/session-status/<id>.txt`; `session-status.last.txt` remains the latest run of any session. Snapshots older than seven days are removed.
- The starting flow now tells the Master to give the full path of the status script when the terminal is not in the workspace root (a window with several folders).

### Removed

- The installation demo GIF (`assets/Installation-Demo.gif`).

## [v0.8.0] - 2026-11-16

Introduces end-to-end Power BI custom visual development, from planning and implementation to testing, packaging and controlled release. The organisation expands to 54 agents across eight teams.

### Added

- **PBIVIZ Development Team (080–086):** seven specialised agents and six skills covering visual planning, development, testing, review, maintenance and ALM.
- **Optional PBIVIZ environment:** a dedicated development folder with an independent local Git repository, integrated into the existing workspace.
- **Three-level ALM:** local versioning (Level 1), remote collaboration (Level 2) and selective DEV/TEST/PROD promotion (Level 3), with release manifests, integrity verification, provenance and approval gates.
- **Custom visual build and release tooling:** project-local SDK packaging, build evidence, dependency validation and controlled release archives.
- **Microsoft Learn MCP integration:** added without replacing existing MCP configuration.
- **Guidance for newer upstream skills:** Project Osmos routing with approval tokens, staged semantic-model organisation and Prep data for AI readiness, OneLake catalog audit and curation modes, Database Hub, capacity, governance policies, FabricIQ and Ontology.
- **PBIR edit policy** in the CLI-policy skill, and report QA through `pbir desktop` that stops when the target Desktop instance has unsaved changes.
- **Skill map regression suite** (`tests/SkillMap.Tests.ps1`) with a committed skill-catalogue snapshot and an agent identity baseline.
- Detect-only recording of Microsoft's `powerbi-report-author` CLI; it is never offered or installed.

### Changed

- Custom visual SDK development is assigned to the PBIVIZ team; the Reporting team continues to own in-report visuals and report integration.
- Agent workflows include review-finding carry-forward, improved release validation and explicit approval requirements.
- Keyword-matched upstream skills are listed as reference only, with narrower keywords and out-of-scope skills excluded; every agent states that skills inform but never authorise.
- The generated `.gitignore` excludes `.dataprojects/` (Project Osmos authentication and routing files).
- Documentation separates skills that are discovered, registered, pinned or suggested from tools that are installed, configured or actually called.

### Fixed

- Improved Azure CLI detection to avoid unnecessary installation attempts.
- Hardened custom visual builds against certificate side effects, unintended dependency downloads, concurrent-build conflicts and incomplete certificate verification.
- Corrected release integrity validation for archive-only promotions and PowerShell 5.1 promotion-gate output.
- Documented safe reconciliation of rejected TEST candidates.
- Updated skill references renamed or retired upstream (`onelake-catalog-govern-cli`, `fabriciq-ontology-cli`, `standardize-naming-conventions`).
- Skill resolution no longer substitutes a similarly named skill; only verified renames are followed, and unresolved references are reported.

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

- **Hardened `fab`/`az`/MCP installs** — more reliable PATH refresh and idempotent re-runs on locked-down machines.

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
