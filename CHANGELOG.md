# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).



## [v0.7.3] - 2026-10-21

A maintenance release improving Windows installation reliability, Git repository mirroring, and Python detection. No changes to the 47-agent architecture, skills, or orchestration protocols.

### Fixed

- **Git worktree long-path failures** — Fabric repositories with deeply nested files could exceed Windows path limits, preventing branches from being mirrored. The installer now enables `core.longpaths=true` in each repository mirror without changing global Git settings.
- **Incorrect branch detection** — Git's `origin/HEAD` reference is no longer mistaken for a real branch, eliminating unnecessary worktree errors.
- **Missing Git diagnostics** — failed worktree operations now display meaningful errors and distinguish missing branches from failed branch creation.
- **Python detection** — existing Python installations are now discovered through PATH, the Windows registry (PEP 514), and common installation directories, avoiding unnecessary reinstalls.
- **Stalled Python installation** — winget installation now has a four-minute timeout and automatically falls back to the python.org installer when unsuccessful.

### Changed

- **Python compatibility** — interpreter selection prioritizes versions supported by the Fabric CLI (Python 3.10–3.14), with clearer messages for incompatible installations.
- **More efficient detection** — Python discovery is cached during setup and refreshed after installation attempts.
- **Safer updates** — repository synchronization is now independently testable and supports idempotent re-runs without altering existing workspace layouts.
- **Long-path guidance** — the installer warns when mirrored files exceed traditional Windows path limits and recommends PowerShell 7 or VS Code for managing affected folders.

### Tests and Validation

- Added `BusinessRepo.Tests.ps1` covering long paths, branch discovery, Git failures, and repeat-installation safety.
- Added `PythonDetection.Tests.ps1` covering interpreter selection, discovery fallbacks, caching, and installation timeouts.
- **GitHub Actions validation passed** on the release commit.

This remains a **prerelease**, focused on making installation and maintenance more reliable across Windows environments.

[Changes since v0.7.2](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/compare/v0.7.2...7d3cd7e699c9626806715875d61a4448dd1dce9d)


## [v0.7.2] - 2026-10-14

One change, driven by a field failure: the agent team must work **however you open the workspace folder** — File > Open Folder, *Add Folder to Workspace* in a blank window, or any `.code-workspace` you saved yourself — and a re-run of the installer must reach every one of those windows without patching files one by one.

### Why

The two VS Code settings the team depends on are **window-scoped**:

- `chat.subagents.allowInvocationsFromSubagents` — without it a Team Lead (itself running as a sub-agent) cannot dispatch its workers; the Master silently ends up doing the work alone.
- `chat.agentSkillsLocations` — registers the Microsoft and data-goblin skill folders so agents see them natively.

VS Code applies window-scoped settings from folder `.vscode/settings.json` **only** in a window opened with *File > Open Folder*. Any window backed by a workspace file — a saved `.code-workspace`, **or the untitled one VS Code creates the moment you *Add Folder to Workspace*** — ignores the folder's `settings.json` for them. v0.7.1 reacted by patching saved workspace files the installer could find; that still left untitled workspaces, files saved after the last run, and anything VS Code had not opened before. Field case (2026-10-14): a workspace file saved at 16:26, installer last run 10-09, Master dispatching workers itself at 16:51.

### Added

- **Step 8 — "Enable the agent team in your VS Code user settings now? (Y/n)"** (default Yes, never silent). On Yes the installer edits `%APPDATA%\Code\User\settings.json` **in place** — your other settings, comments, key order, indentation, line endings and BOM are preserved; only two things change:
  1. `"chat.subagents.allowInvocationsFromSubagents": true` is added, or an explicit `false` is flipped.
  2. The current **workspace-relative** skill folders (`.github/skills`, `skills-for-fabric/skills`, `power-bi-agentic-development/plugins/<plugin>/skills`) are merged into `chat.agentSkillsLocations`; your own entries are kept; a re-run adds only folders that appeared upstream since. Absolute and `~/` paths (the Synapse extension skills) are **never** written at user level.
  The edit is validated before writing (a file that would not parse is never touched) and idempotent (a second run reports "already up to date"). If VS Code Profiles are in use, the profile settings files are listed so you can repeat the two lines there.
- **Status script** now reports which scope is in effect — `Nested dispatch: enabled at user level (every VS Code window)` / `enabled in .vscode/settings.json only (File > Open Folder windows; NOT windows opened from a .code-workspace file)` / `NOT set` — and how many workspace-relative skill folders the user settings contribute. With the user-level setting present it no longer warns about saved workspace files (they need no patch). `FABRIC_AGENTIC_USER_SETTINGS` overrides the path for tests.
- **Master rule**: may offer to add the single line to the workspace file you are in (config edit outside the Fabric artifacts → asks for `APPROVED:EDIT:<file>` first, then *Developer: Reload Window*).
- **Stale status can no longer be presented as current.** Field case (2026-10-15, first session after the v0.7.2 re-run): the shared shell swallowed the status script's output, the Master fell back to `session-status.last.txt` as instructed — and relayed a six-day-old block (old skill dates, "enabled in settings.json only", a saved-workspace warning that no longer applied). The block now starts with `GENERATED <local timestamp>` on stdout and in the fallback file; the starting flow tells the Master to retry in a new terminal *before* reading the file, to compare that timestamp with the current time whenever it does read it (or recalls a block from earlier in the chat), and to say "status file is from <timestamp>, re-running" instead of presenting anything older than about an hour as the current state.

### Changed

- The v0.7.1 saved-workspace scan/patch is now a **fallback** that runs only when the user-level prompt is declined.
- Generated `copilot-instructions.md` / `AGENTS.md`, the Master's dispatch-health rule and the README describe the scoping model and the exact effect of the user-level setting.

### What the user-level setting does and does not enable — read this

Because it lives in your **user** settings, `chat.subagents.allowInvocationsFromSubagents: true` is in effect in **every VS Code window on this machine**, not only when the Fabric workspace is open. VS Code offers no per-folder conditional for a window-scoped setting, so this is the only scope that satisfies "works however I open it".

| Situation | Effect of the user-level setting |
|---|---|
| Blank VS Code window, no folder | None. There are no workspace agents; default Copilot chat behaves exactly as before. |
| Any workspace where you use **built-in Copilot chat / agent mode only** | None. The setting only concerns *custom* agents (`.agent.md`) that run as sub-agents. |
| A workspace with custom agents that **never delegate** (no `agents:` list / no sub-agent tool) | None. |
| **Another agentic workspace** (e.g. a Power Platform or app-building team) whose custom agents are **designed to delegate** to each other | **Enabled.** Their Lead-style agents may now dispatch further sub-agents, exactly as the Fabric team does. If that workspace's author expects nested delegation, it now works; if you do not want it there, set `"chat.subagents.allowInvocationsFromSubagents": false` in that workspace's `.code-workspace` (workspace scope overrides user scope). |
| The Fabric workspace, opened any way | **Enabled** — Master → Team Lead → Worker works from the first second. |

What it never does: install agents or skills anywhere, change what built-in Copilot can do, grant any agent new tools, or let an agent act without the approval tokens its own definition requires.

The **skill locations** written at user level are workspace-relative, so they resolve **only** in windows that contain a folder with those sub-paths — in practice, the Fabric workspace. A blank window or an unrelated project resolves them to nothing: no Fabric skills appear there. Verified on 2026-10-14: in a multi-root window where folder-level registration was ignored, one relative user-level entry took the native skill list from 18 to 43, with no reload.

### Tests

- `UpdateSafety.Tests.ps1`: in-place user-settings edit on JSONC fixtures — append flag + relative block preserving comments/order/CRLF; flip `false→true` and merge only missing locations into an existing block keeping user entries (LF preserved); idempotent second run; absolute/`~` paths never written; file created when absent; BOM preserved; broken file refused and left untouched.
- `SessionStatus.Tests.ps1`: user-settings path pinned in all runs; new scenario with a JSONC user file asserting `enabled at user level`, the workspace-relative count (only entries that resolve under the root), and that the saved-file warning is replaced by "need no patch"; the `GENERATED` stamp is asserted on stdout and in the fallback file.
- `Generated.Tests.ps1`: the emitted starting flow carries the staleness guard.

## [v0.7.1] - 2026-10-05

A hardening release driven by two external reviews of v0.7.0/v0.7.1-rc and a further full pass over the installer, the emitted agents, the embedded skills and the tests. No new capabilities; every item below closes a gap between what an agent is told to do and what it can actually do, between what the installer reports and what really happened, or between the embedded guidance and Microsoft's documented behaviour.

### Fixed



- **User-saved `.code-workspace` files are now detected and can be updated.** `chat.subagents.allowInvocationsFromSubagents` and `chat.agentSkillsLocations` are window-scoped: a window opened from a user's own saved workspace file ignores the folder's `.vscode/settings.json`, so Team Leads silently lost the ability to dispatch workers and new vendor skill folders never reached those sessions, even though the installer had written both settings. Field symptom: the Master reported *settings.json is missing the setting* (false) after a Lead returned empty twice. Step 8 now scans VS Code's workspace storage for saved files that open the target folder, lists exactly what each lacks and offers (`Y/n`) to add only the missing entries, so a re-run after patching reports nothing; `Get-SessionStatus.ps1` names any such file still lacking the dispatch setting with a one-line fix, and the Master's dispatch-health rule tells it to quote that path instead of blaming `settings.json`. `settings.json` is also written without a UTF-8 BOM. The README (*Start working*), the generated `copilot-instructions.md` and `AGENTS.md` explain the window-scoped caveat and the manual fix.
- **Step 1 no longer crashes on natural answers.** Answering `y` at *Enter 1 or 2* silently selected option 2, and typing a full path at the *Enter a name* prompt crashed with *The given path's format is not supported* (`Join-Path` cannot take a rooted path). `y`/`yes` and `n`/`no` now map to 1/2, anything else re-asks; a full path typed at the name prompt is honoured as-is, a plain name is sanitised of invalid characters, and option 1 validates that the input is a real rooted path before continuing. A new `Step1Prompts.Tests.ps1` drives the real installer through these sequences.
- **Vendor refresh can no longer touch the wrong repository.** `Update-VendorClone` now requires the folder to be the *root* of its own Git repository (`git rev-parse --show-toplevel`) and, when the installer calls it, that `origin` is the expected GitHub URL. A vendor-named folder that lost its `.git` previously let Git discover the *outer workspace repository* and stash/reset that instead. On a failed reset the stash name is printed so edits are recoverable. Tests cover the orphan-folder, wrong-remote and normalised-remote cases.
- **The session workspace file is merged, not rebuilt.** Step 4 deleted the TEMP session `.code-workspace` *before* calling the merge, so user-added roots and settings were lost on every re-run; inside `Merge-CodeWorkspace` the loop variable `$path` also shadowed the `$Path` parameter (PowerShell names are case-insensitive), sending a genuine merge to the wrong destination. Both fixed; the session file is now keyed to the workspace path (`<folder>-<hash>.code-workspace`) so two workspaces on one machine never inherit each other's roots, and a stale relative `.` root from older in-folder files is dropped when the primary root is absolute.
- **JSONC settings are no longer treated as malformed.** `settings.json` / `.code-workspace` files with comments or trailing commas (VS Code's default dialect) were backed up and their keys discarded. A lenient parser now strips comments outside string literals and trailing commas before parsing; only genuinely broken JSON is backed up.
- **Portable tool activation cannot destroy a good install.** Backup cleanup ran *inside* the rollback block, so a partially failed `Remove-Item` on the old copy could delete the validated replacement and restore an incomplete backup. Cleanup now happens after activation is committed and a cleanup failure only reports the leftover folder.
- **winget payloads are accepted only after a clean exit.** A timed-out or failed `winget download` could leave a partial MSI/ZIP that was then "verified" and extracted. The helper now requires a normal exit code 0 before using anything it finds.
- **Obsolete installer files are actually purged.** The integrity manifest hashed *every* file in `.github/agents`, so retired or user-authored agents were adopted as "current" and the old-minus-new purge could never remove them. Only declared managed agents are hashed now; the purge additionally rejects `..`/absolute entries and checks canonical containment, counts a file only after verifying it is gone, and the update commit stages deletions of retired tracked files (including legacy names).
- **The Master can now open the connection it is told to open.** v0.7.0 instructed the Master to call `connection_operations` → `ConnectFabric` before dispatching live semantic-model work, but its frontmatter did not grant `powerbi-modeling-mcp/*`. The Master is now in the modeling-MCP grant list (connection management and read-only checks only; modelling stays with 010's team), and a new test fails whenever any agent's body references a tool its `tools:` list does not include.
- **A failed stash no longer leads to a hard reset.** `Update-VendorClone` checks the exit code of `git stash push` and re-checks that the working tree is clean; if either fails it prints *local edits could not be stashed … clone left untouched* and returns without resetting.
- **A failed reset is no longer reported as "already at upstream".** The reset exit code was previously overwritten by the following `rev-parse`. Success is now claimed only when the reset returned 0 **and** `HEAD` equals the resolved upstream commit; otherwise the function prints *could not reset to upstream (git reset exit N)*. Regression tests cover a blocked stash, an unresolvable upstream and the `@{upstream}` fallback.
- **GUIDs in Power BI URLs.** `ConnectFabric` needs exact display names; the Master's connect step now resolves workspace and item GUIDs first (`fab api workspaces/<id>`, `.../items/<id>`, REST fallback) instead of passing the GUID through and failing.
- **Embedded skills corrected against Microsoft documentation.** Pipeline variables are `@variables('Name')` (the `@pipeline().variables` accessor does not exist); `compatibilityLevel` is preserved rather than forced to 1604 (newer features need higher levels); the Direct Lake freshness guidance now distinguishes Direct Lake on SQL from Direct Lake on OneLake, automatic updates vs explicit reframing, and endpoint sync; XMLA is no longer listed as a Warehouse T-SQL fallback; the REST fallback states the documented `executeQueries` contract (DAX `EVALUATE` only, no INFO/DMV, row/size/rate limits) instead of promising an `INFO.VIEW` workaround and "full" live coverage.
- **Tool identity.** `fab` detection now requires the Microsoft Fabric CLI banner (`fab version …`) so a same-named command (pyinvoke's `fab`) is reported as *a different 'fab' is on PATH* instead of satisfying the check. Tabular Editor 2 is no longer conflated with TE3 or the new `te` CLI: those are detected separately (`tabularEditor3`, `teCli`, detect-only, never "updated" with a TE2 release).
- **Status script.** Identity probes run through the recorded executables with a timeout (a stuck SSO/proxy prompt cannot hang session start), a stale recorded `path` is replaced when the command is rediscovered, and detect-only tools are not reported as missing. Its test fixture is now fully offline.

### Changed

- **One vendor-refresh policy for the maintenance team.** The capability-maintenance contract said both *stash then reset to upstream* and *never reset or overwrite a dirty/diverged repository*. It now states one rule with explicit stop conditions (not a repository root, wrong `origin`, fetch failed, stash failed/still dirty) executed only by 071, and a separate, absolute protection for business repositories under `source-control-repositories/`.
- **Terminal rules match the tooling.** The shell is one shared terminal: parents sequence terminal work, agents run one simple command per call, multi-statement work goes into a uniquely named `.ps1`, and "no output" is no longer treated as proof of a wedged shell. Agents with `execute` but no `edit` get a variant that keeps them to single statements and routes any needed script to an edit-capable worker instead of asking them to create files they cannot create.
- **PLAN and VERDICT travel inside the WORK RESULT.** The block gained a `payload:` field; the Architect and QA return their specialist block verbatim inside the mandatory wrapper, removing the ambiguity that previously caused needless re-dispatches or summarised-away defects.
- **Report skills realigned to upstream.** Microsoft consolidated `powerbi-report-planning/authoring/management/design` into `powerbi-report-cli` (modes); the catalog now points at it with the mode references, and the reporting team's tool precedence is explicit: `pbir` first (house standard), Microsoft's `powerbi-report-author` only when `pbir` is absent and the user agrees, direct PBIR JSON editing as a disclosed last resort (try `pbir set` first).
- **Retries never repeat writes.** A blind retry is allowed only when the failure happened before the child could act (agent not found, stream refused at dispatch). If a write-capable dispatch drops mid-turn, the parent re-dispatches with an *inspect the current state first, do not repeat what is already done* context and requires the WORK RESULT to list what it found in place.
- **Parallel dispatch is bounded.** Children run in parallel only when their artifacts are independent **and** at most one needs the terminal; every executing agent uses unique file names (`scripts/<agent>-<purpose>-<timestamp>.ps1` with a matching `.out.txt`) so one agent never overwrites another's output.
- **MCP-connection guidance only where it applies.** The *reuse the Master-opened connection* bullet is emitted only to agents that hold `powerbi-modeling-mcp/*`; agents without the grant no longer carry an instruction they cannot follow. Connection failures are passed down as `mcp connection: none - reason: <error>` and Leads treat `none` as final (no re-probing).
- **Renamed upstream skills resolve more precisely.** `Resolve-KnowledgeRef` tries a two-token prefix before a one-token one and only self-heals when exactly one candidate remains; the annotation now says *closest sibling resolved at install time – confirm it covers the topic*.
- **Status script under test.** A new `SessionStatus.Tests.ps1` runs the emitted `Get-SessionStatus.ps1` against a scratch workspace from an unrelated working directory and asserts the block it prints, the self-registration of a new upstream skill container, the preservation of existing settings keys, the honest MCP line (*installed*, never *connected*) and the persisted `session-status.last.txt`. A new `UpdateSafety.Tests.ps1` covers JSONC parsing, workspace-merge preservation and the purge/manifest/commit invariants; CI now also runs on README/CHANGELOG changes (the version-parity tests read them).

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

- **Lean startup.** No blocking menus: one status-script call, one compact status block, then straight to the user's request. MCP servers are no longer probed at every session start: the Master opens the Power BI modeling connection itself when a live model is in scope, and Fabric MCP is checked by the owning Team Lead on first live use. The topic menu and "switch agent in the dropdown" instructions are gone; the Master routes everything itself.
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
