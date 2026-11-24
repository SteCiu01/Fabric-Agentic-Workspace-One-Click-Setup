# Test suite

These [Pester](https://pester.dev) tests check the installer
(`Setup-FabricAgenticWorkspace.ps1`): the agent manifest embedded in it
(`$agentManifestJson`), the files it generates, the helpers it ships and the documents of
this repository. They run offline and install nothing. Start with
[Suites at a glance](#suites-at-a-glance); the sections after it hold the detail for each area.

- [Run the tests](#run-the-tests)
- [Suites at a glance](#suites-at-a-glance)
- [How the tests start the installer](#how-the-tests-start-the-installer)
- Details by area: [Agent manifest and tools](#agent-manifest-and-tools),
  [Generated files](#generated-files),
  [Skill map and vendor catalogues](#skill-map-and-vendor-catalogues),
  [Installer prompts and consent](#installer-prompts-and-consent),
  [Update safety](#update-safety), [Session status](#session-status),
  [Housekeeping](#housekeeping), [Pipeline definition check](#pipeline-definition-check),
  [AI readiness and tooling](#ai-readiness-and-tooling), [PBIVIZ](#pbiviz),
  [Versions, documents and neutrality](#versions-documents-and-neutrality),
  [Documentation workflow](#documentation-workflow), [Shared helpers](#shared-helpers)
- [Add a regression test](#add-a-regression-test)
- [Fixtures](#fixtures)
- [What these tests do not cover](#what-these-tests-do-not-cover)

## Run the tests

**Launcher.** Double-click `Run-Tests.bat` in this folder. It runs every suite and ends
with `RESULT: PASSED - no test failed ...`, or with `RESULT: FAILED` when a test failed or the
run did not start (for example because PowerShell could not be started). The exit code is 0
only when no test failed. Skipped and not-run tests are counted in Pester's summary, just
above the result line. The batch file takes the path from its own location, so it works from
any clone.

**All suites**, from any terminal:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester; Invoke-Pester -Path '<path-to>\tests' -Output Detailed"
```

**One suite**, from the repository root:

```powershell
Invoke-Pester -Path .\tests\Consent.Tests.ps1 -Output Detailed
```

**One test or one group**, by a name filter:

```powershell
$cfg = New-PesterConfiguration
$cfg.Run.Path = '.\tests\PBIVIZ.Alm.Tests.ps1'
$cfg.Filter.FullName = 'Build isolation*'     # any Describe or It name, wildcards allowed
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
```

Expect no failed test. The full run takes from several minutes to more than an hour,
depending on the machine; `PBIVIZ.Alm.Tests.ps1` is the longest file.

### Requirements

- Windows PowerShell 5.1 or PowerShell 7. The tests run on both: 5.1 is the installer's
  runtime, and CI runs PowerShell 7. Behaviour that exists only in 5.1 (for example
  `@($list)` on a `List[object]`) is pinned by an explicit test.
- Pester 5. CI installs Pester 5.5.0 or later.
- Git 2.28 or later, the minimum the PBIVIZ helper accepts. Tests such as `VendorClone`,
  `SkillCompat`, `BusinessRepo` and both `PBIVIZ` files create repositories under TEMP.
- Node.js on PATH for the PBIVIZ build tests (the stand-in CLI is a Node script).
- No administrator rights, no network and no real remote. What a test creates, it creates
  under TEMP and removes afterwards.

### Skipped tests

A test skips itself when its precondition is missing. Pester counts it as skipped, not failed.

- `Manifest.Tests.ps1`: the JSON Schema validation needs `Test-Json -Schema`, which Windows
  PowerShell 5.1 does not have. It runs in CI.
- `SkillMap.Tests.ps1`: the live check of every pin runs only when
  `FABRIC_AGENTIC_CATALOG_ROOT` points at a workspace with the cloned vendor catalogues.
- `Consent.Tests.ps1`: the PowerShell 7 end-of-input case needs `pwsh`.
- `BusinessRepo.Tests.ps1`: the precondition case (a plain `worktree add` fails on a long
  path) is skipped where Git already checks out paths beyond 260 characters without
  `core.longpaths`.
- `UpdateSafety.Tests.ps1`: two cases need real Git; one of them is also skipped when Git
  cannot create a repository under TEMP.

### Continuous integration

GitHub Actions runs the suite on Windows with PowerShell 7 on every push and pull request
that touches the installer, the schema, the tests, the documents the workflow lists or the
maintainer tooling in `.github/hooks`, `.github/agents` and `.github/skills` (see
`.github/workflows/validate.yml`).

## Suites at a glance

| File | What it checks | Details |
|------|----------------|---------|
| `Manifest.Tests.ps1` | The embedded agent manifest is valid, complete and free of duplicates. | [Agent manifest and tools](#agent-manifest-and-tools) |
| `Hierarchy.Tests.ps1` | The delegation tree has one root, no loop and no dangling reference. | [Agent manifest and tools](#agent-manifest-and-tools) |
| `Tools.Tests.ps1` | Agents use only known tool tokens, and workers cannot delegate. | [Agent manifest and tools](#agent-manifest-and-tools) |
| `Tools.LeastPrivilege.Tests.ps1` | Every agent declares its own tools; nothing broad comes from the default. | [Agent manifest and tools](#agent-manifest-and-tools) |
| `Generated.Tests.ps1` | The files a dry run of the installer writes match the manifest and carry the required rules. | [Generated files](#generated-files) |
| `SkillMap.Tests.ps1` | Pinned skill references resolve without guessing, and the generated organisation matches its baseline. | [Skill map and vendor catalogues](#skill-map-and-vendor-catalogues) |
| `SkillCompat.Tests.ps1` | An upstream change that breaks a pinned skill holds the catalogue at a compatible commit. | [Skill map and vendor catalogues](#skill-map-and-vendor-catalogues) |
| `VendorClone.Tests.ps1` | Refreshing a vendor skill clone keeps local edits and touches no other repository. | [Skill map and vendor catalogues](#skill-map-and-vendor-catalogues) |
| `Step1Prompts.Tests.ps1` | The Step 1 folder prompts handle every answer, and a prompt test cannot install anything. | [Installer prompts and consent](#installer-prompts-and-consent) |
| `Consent.Tests.ps1` | Only a typed Yes installs or updates software; an unanswered question does not. | [Installer prompts and consent](#installer-prompts-and-consent) |
| `PythonDetection.Tests.ps1` | Python and the optional CLIs are detected without a hang or a needless reinstall. | [Installer prompts and consent](#installer-prompts-and-consent) |
| `SetupHonesty.Tests.ps1` | The installer reports skipped steps, Git refusals and broken tools as what they are. | [Installer prompts and consent](#installer-prompts-and-consent) |
| `UpdateSafety.Tests.ps1` | A re-run keeps the user's settings, workspace file and own agents. | [Update safety](#update-safety) |
| `BusinessRepo.Tests.ps1` | Business repository branches are mirrored as worktrees, also with paths beyond 260 characters. | [Update safety](#update-safety) |
| `SessionStatus.Tests.ps1` | The generated status script reports the workspace correctly, offline. | [Session status](#session-status) |
| `Housekeeping.Tests.ps1` | The working-files helper previews, moves and restores files without losing one. | [Housekeeping](#housekeeping) |
| `Pipeline.Tests.ps1` | The offline pipeline check blocks unsafe definitions and never claims more than it checked. | [Pipeline definition check](#pipeline-definition-check) |
| `AiReadiness.Tests.ps1` | The AI readiness skill separates what agents change, draft and leave to a person. | [AI readiness and tooling](#ai-readiness-and-tooling) |
| `Tooling.Tests.ps1` | Remote MCP servers are detected, never assumed, and added only on an explicit Yes; optional tools are detected, never assumed. | [AI readiness and tooling](#ai-readiness-and-tooling) |
| `PBIVIZ.Install.Tests.ps1` | The installer sets up the PBIVIZ folder without damaging an existing folder or repository. | [PBIVIZ](#pbiviz) |
| `PBIVIZ.Alm.Tests.ps1` | The adoption, promotion, release and build safeguards of the PBIVIZ helper hold. | [PBIVIZ](#pbiviz) |
| `Version.Tests.ps1` | Version numbers, documents and launchers agree with the installer. | [Versions, documents and neutrality](#versions-documents-and-neutrality) |
| `Neutrality.Tests.ps1` | No file of the repository identifies a machine, tenant or organisation. | [Versions, documents and neutrality](#versions-documents-and-neutrality) |
| `DocReview.Tests.ps1` | The maintainer documentation hook records a review only when one took place. | [Documentation workflow](#documentation-workflow) |
| `Manifest.Helpers.ps1` | Not a test: shared helpers that most test files load. | [Shared helpers](#shared-helpers) |

Three terms used below:

- **Stand-in**: a fake program or function that a test puts in place of a real one (Git,
  Python, `winget`, the PBIVIZ toolchain). The test controls its answers, and nothing real
  is called.
- **In-process**: the test loads functions from the parsed installer and calls them. It
  starts no installer and no other program.
- **Single source**: a helper the installer ships is stored once, as a here-string in the
  installer. The tests load it from there, so they test the text that ships.

## How the tests start the installer

Two kinds of test start the real installer script as a
child process. Neither can install anything.

- *Dry-run tests* (`Generated`, `SessionStatus`, `SkillMap`, `SkillCompat` and the installer
  side of `Housekeeping`) pass `-EmitAgentsTo`. The installer generates files and returns
  before any prerequisite, clone, install or launch code. `SkillMap` and `SkillCompat` then
  run `-VerifyRoot` on that output, which only re-hashes the generated files and exits.
- *Prompt tests* (`Step1Prompts` and the Step 1 part of `PBIVIZ.Install`) pass
  `-StopAfterStep1` through `Invoke-InstallerPromptCheck` in `Manifest.Helpers.ps1`. Three
  independent safeguards apply:
  1. The installer exits **by itself** at the end of Step 1, and again at script level before
     the prerequisite step.
  2. Before every launch the helper parses the script and **refuses to start it** unless
     everything reachable before that exit is on a short allow-list: no process start,
     download, package manager, registry or environment write, `Invoke-Expression` or
     installer function. `Step1Prompts.Tests.ps1` proves the refusal with unsafe variants of
     the script.
  3. Every optional install is behind a question that only a typed Yes passes, and the
     child's input is closed.

  The child also gets a throwaway `USERPROFILE` and a PATH holding only Windows folders plus
  tripwire stand-ins for `winget`, `pip`, `python`, `code`, `git`, `npm` and other commands.
  A stand-in records the call and fails; the tests assert that none was called. A timeout
  stops a hanging child as an emergency only; it is not what prevents installs.

Never add a test that runs the installer without one of these switches. `Consent` starts
a child PowerShell too, but it holds the consent functions only, not the installer.

### What the suite needs from the machine

PowerShell must be able to start `powershell.exe`
(and `cmd.exe` to start PowerShell, for the dry-run tests), and Git must accept repositories it
creates under TEMP. Where endpoint policy blocks either for the calling process, the tests that
need it fail for that reason. The files that work in-process still run, apart from their few
cases that start a process or real Git: `Manifest`, `Hierarchy`, `Tools*`, `Version`,
`Neutrality`, `UpdateSafety`, `Pipeline`, `AiReadiness`, `Tooling`, `Consent`,
`PythonDetection`, `SetupHonesty`. Run the whole suite from an ordinary terminal with
`Run-Tests.bat`.

## Agent manifest and tools

These four files run in-process on the manifest embedded in the installer.

- `Manifest.Tests.ps1`: the manifest parses as JSON, declares a `schemaVersion` and a
  semantic `productVersion`, and defines exactly 54 agents: 3 executive, 8 team-lead and
  43 worker. Ids, display names, file names and numeric file-name prefixes are unique, and
  ids are lowercase kebab-case. The manifest also validates against
  `schema/agent-manifest.schema.json` where `Test-Json -Schema` exists.
- `Hierarchy.Tests.ps1`: there is exactly one root, the Master. Every `parent` resolves and
  reaches the Master without a cycle, and every `allowedChildren` entry resolves. Only agents
  that hold the `agent` tool delegate, workers never do, and the Master reaches every team
  lead and executive reviewer. Executives and team leads are visible and user-invocable;
  workers are hidden and not user-invocable.
- `Tools.Tests.ps1`: the `tools` entries of every agent and of the manifest default use only
  known capability tokens, without duplicates. The delegation tool (`agent`) is never granted
  to a worker or by the default set.
- `Tools.LeastPrivilege.Tests.ps1`: every agent declares an explicit `tools` array, so
  nothing relies on the default. The default is read-only (`read`, `search`), only executives
  and team leads hold the `agent` tool, read-only diagnostic roles never get `edit`, and no
  agent holds a token outside the approved set.

## Generated files

`Generated.Tests.ps1` runs the installer as a dry run (`-EmitAgentsTo`) into a temporary
folder and checks the files it really writes, not only the manifest.

- **Agents.** All 54 exist with the file names, frontmatter and `tools` the manifest
  declares. Each has its `Knowledge and skills`, `Playbook` and `Validation` sections and ends
  with the WORK RESULT contract. Every tool an agent's text tells it to use is granted in its
  frontmatter. The Master lists only its children, workers never delegate, and the
  delegation, approval-token, terminal-hygiene and vendor-refresh rules sit on the agents they
  apply to. A static guard keeps agent files free of constructs specific to one chat harness;
  it is not a runtime proof.
- **Configuration.** `starting-flow.md`, `working-flow-reference.md`, `Get-SessionStatus.ps1`
  and `.vscode/settings.json` are emitted as designed.
- **PBIVIZ.** The emitted `Pbiviz-Alm.ps1` is byte-identical to its source and holds no
  destructive Git command. All six `pbiviz-*` skills are emitted, `.vscode/mcp.json` carries
  `microsoftDocs`, and emit mode creates no PBIVIZ folder or mapping.
- **Downloads and releases.** Documents, skills and agents name a download-capable npm
  command only as a prohibition or behind `APPROVED:INSTALL`. The release-correctness rules
  reach the release skills, agents 080 and 086 and the CLI guide.

## Skill map and vendor catalogues

The agents pin skills from two cloned vendor catalogues. These files check that a pin never
drifts onto a wrong skill and that a refresh never damages a clone or the user's work.
`SkillCompat` and `VendorClone` use throwaway local bare repositories as the upstream. To
refresh the two fixtures, see [Fixtures](#fixtures).

`SkillMap.Tests.ps1` reads every pinned skill reference from the installer and checks it
against a synthetic catalogue built from `fixtures/skill-catalog.snapshot.json`:

- Every pin exists in the snapshot or follows an alias that records its evidence. No pin uses
  a retired name. The approved fallback commit of each catalogue is the commit the snapshot
  was recorded from.
- The resolver never guesses. A missing skill with a similarly named sibling stays *not
  resolved*, a same-named skill is followed only inside the same provider and only when
  unambiguous, and review candidates go to the maintainer only. Keyword suggestions stay
  reference-only.
- The file then emits the organisation (`-EmitAgentsTo`), compares it with
  `fixtures/agent-baseline.json`, checks the guardrail texts and runs `-VerifyRoot`. A re-run
  keeps user customisations, and the output does not depend on the workspace path.

`SkillCompat.Tests.ps1` loads the vendor-catalogue functions from the installer and checks
the compatibility hold:

- A compatible upstream (a new skill, a moved reference file) is accepted.
- An upstream that renames, deletes or splits a pinned skill, deletes a skill behind a pinned
  reference file or deletes a shared file puts the whole clone back on the commit it was on:
  clean tree, references unchanged, nothing from the rejected commit kept.
- A first install falls back to the approved commit, which is also used when the previous
  commit does not fit. With no fitting commit the clone stays on upstream and the reference is
  marked *not resolved*.
- A vendor-named folder inside another repository, a wrong origin, a dirty clone and an
  unknown commit are never moved.
- The maintenance refresh gives the same outcomes against the paths recorded in
  `skill-catalog-state.json`. A hold repeats while upstream is incompatible and lifts by
  itself afterwards, advisory files never hold, and local edits are kept in a named stash.
- The emitted `Skill-Compat.ps1` parses, carries the installer's function statements
  unchanged and the approved commits, has no side effect when dot-sourced and skips
  non-vendor folders offline with exit code 0. It holds a catalogue end to end after upstream
  deletes a skill a generated agent references (agents byte-identical, `-VerifyRoot` passing).
- Negative controls: the same rename without the hold leaves an unresolved reference; without
  recorded pins it is a plain refresh.

`VendorClone.Tests.ps1` loads `Update-VendorClone` from the installer:

- A stale clone reaches `origin/HEAD` under `$ErrorActionPreference = 'Stop'`, local edits
  are stashed and not lost, a second call changes nothing, the caller's error preference is
  kept, and a missing path is skipped.
- A failed stash leaves the clone untouched (no reset). An unresolvable upstream is reported
  as *could not reset*, never as *already at upstream*. A clone that lacks only `origin/HEAD`
  still refreshes through the `@{upstream}` fallback.
- A vendor-named folder that is not its own repository root is refused, so the enclosing
  repository is neither stashed nor reset. A repository with the wrong `origin` is refused;
  `.git`, slash and case differences in the expected remote are tolerated.
- Project Osmos auth output left inside a clone is excluded locally before the stash, stays
  in place and is never stashed.

## Installer prompts and consent

These files check that a question the user did not answer with Yes never installs software,
and that the installer says what it found and what it skipped.

`Step1Prompts.Tests.ps1` runs the real installer through Step 1 only, with scripted answers
(see [How the tests start the installer](#how-the-tests-start-the-installer)):

- Prompts: `y` at *Enter 1 or 2* behaves as option 1. A full path typed at the *name* prompt
  is used as it is and never crashes `Join-Path` with `The given path's format is not
  supported`. An invalid folder name is sanitised. An unrecognised choice and a relative path
  for option 1 are asked again. A missing folder is created only on an explicit Yes; Enter,
  `n`, other text and end of input do not create it.
- Harness safety: every run ends by itself with the stop marker and exit code 0, also at end
  of input. It never reaches the prerequisite step, calls none of the tripwire commands,
  leaves no process behind and writes only inside its disposable folder. The static analysis
  of the shipped installer finds nothing unsafe before the stop.
- Negative controls: unsafe variants of the script (the stop removed or made conditional; an
  install, a download, a process start, an environment write and others placed before it) are
  each refused before launch. The emergency timeout stops a deliberately hanging stand-in and
  its child.

`Consent.Tests.ps1` loads the consent functions from the installer (`Test-ExplicitYes`,
`Read-ExplicitYes`, `Read-DefaultYes`, `Invoke-OptionalToolPrompt`, `Invoke-ToolUpdateOffer`,
`Ensure-Python`) with stand-ins for everything around the decision:

- Only `Y` or `YES`, in any case and with surrounding spaces, is a Yes. `$null`, empty,
  whitespace, `N`, `NO`, `yess`, `ok`, `sure`, `1`, `true`, a non-string and a read that
  throws are not.
- Real end of input gives No. It is tested in a child PowerShell that holds the consent
  functions only, on Windows PowerShell 5.1 and on PowerShell 7 when installed. As a negative
  control, the condition shipped up to v0.8.0 reproduces the install at end of input.
- An optional tool's install block and an update block run only on Yes, a No is not
  remembered, and a tool that is present is not asked about. Python is installed only on Yes,
  and an existing supported Python is reused without a question.
- Static, on the syntax tree: every install route in the prerequisite step (pip, winget,
  extension install, portable zip, venv) sits behind `Read-ExplicitYes` or inside an
  `Invoke-OptionalToolPrompt -Install` block. No tool is recorded with install mode `auto`,
  detect-only tools have no install block, and looking for tools changes the PATH of the
  session only.

`PythonDetection.Tests.ps1` loads `Get-FabPythonRangeLabel`, `Get-PythonVersionOf`,
`Find-RealPython` and their constants from the installer and drives them with fake `.cmd`
interpreters on a private PATH. No real Python is needed, and PATH is restored after every
test:

- Detection: the Microsoft Store alias stub (stderr and exit code 9009) is rejected and never
  returned. A banner parses to a `[version]`. A supported `py` beats an unsupported `python`
  found earlier on PATH. The probe looks beyond PATH (registry and the usual install
  folders). The result is cached, and only `-Refresh` runs the interpreter again. A PATH
  holding only an unsupported Python never yields null. The session directories of a cached
  hit are applied again after a PATH rebuild.
- Static: the winget attempt in `Ensure-Python` is `Start-Process` with
  `Wait-Process -Timeout`, non-interactive and killed on timeout, never a bare
  `& winget install`. `Ensure-Python` accepts only a supported interpreter and probes again
  after an install. Step 2 prints the range derived from the constants.
- Optional CLIs (`Test-CliResilient` and `Get-CliProbeState` with a fake `az.cmd`): a warning
  on stderr with exit code 0 is *runnable*, a failing probe on PATH is *unhealthy* and never
  reinstalled, an absent CLI is *missing*, and Step 2 reaches winget or the isolated venv only
  in the *missing* branch.
- `Invoke-OptionalToolPrompt` asks again after an earlier No, installs only on an explicit
  Yes, and has no parameter or helper that could carry an earlier answer.

`SetupHonesty.Tests.ps1` runs in-process. Git is a stand-in function and the PBIVIZ helper is
pointed at a file that is not a program, so no working Git, Python or network is needed:

- Git: its answer is classified (missing folder and no `.git` without asking Git; refusal,
  start-up failure, exception, not a repository, other error; own and enclosing top level). A
  refusal is never worded as a missing repository.
- Vendor refresh: a clone Git refuses gets no move-aside advice and no fetch, stash or reset.
  It is recorded as `blocked` with the reason and the last recorded commits, at install time
  and in maintenance. A wrong origin is still skipped with no state written, and a plain
  folder stays `unmanaged`. Vendor file dates move only after a real clone or refresh, and the
  status script and the maintenance command name a blocked catalogue.
- Optional installs: success needs exit code 0 and a working tool. An already satisfied
  requirement is reported as such, an exit-0 install of a tool that does not run is reported,
  the Fabric CLI install is verified by running it, and a broken `fab` keeps its exit code and
  error line.
- PBIVIZ: the message is `git could not be started`, not `git not found`. The status line
  separates a folder without `.git` from a `.git` Git could not read. The mapping keeps the
  last recorded git block with a `lastCheck` note (unknown values `null`, never 0).
- End of run: `Setup complete!` and `All prerequisites OK.` appear only without warnings;
  otherwise the warnings are listed.

## Update safety

The user's workspace file, settings, own agents and repositories must survive every re-run.

`UpdateSafety.Tests.ps1` loads `ConvertFrom-JsonLenient`, `Merge-JsonSettings` and
`Merge-CodeWorkspace` from the parsed installer and exercises `Update-UserSettingsInPlace` on
JSONC fixtures:

- JSONC (comments, trailing commas) parses, and user keys survive the settings merge without
  a `.bak`. An existing session workspace keeps the user's roots and settings.
- A user-saved `.code-workspace` that opens the root is found from a fake `workspaceStorage`;
  only the settings it lacks are reported and patched.
- User settings are edited in place: comments, order, line endings and a BOM are kept, a
  second run is a no-op, absolute and `~` paths are never written, and a broken file is left
  untouched.
- Static: only declared agents are hashed into the manifest, the purge rejects `..` and
  absolute entries, update commits stage retired files, and the session workspace is never
  deleted before merging.
- Final step: `Test-GitWorkTreeUsable` is true for a repository real Git has just initialised
  and false, without throwing, for anything else. The installer commits only after that check
  and reports a skipped commit as a warning.

`BusinessRepo.Tests.ps1` loads `Sync-BusinessRepositoryWorktrees` from the installer and runs
it against a throwaway local upstream whose tree holds a relative path of about 200
characters, mirrored as Step 4 does. The developer's global and system Git configuration is
hidden (`GIT_CONFIG_GLOBAL` set to an empty file, `GIT_CONFIG_NOSYSTEM`), because a
developer's own `core.longpaths=true` would hide the defect:

- Precondition: on default Git a plain `worktree add` fails with `too long`.
- Mirroring: one worktree per non-main branch, `core.longpaths=true` written to the mirror
  and nowhere else, the file beyond 260 characters really checked out, and
  `refs/remotes/origin/HEAD` never treated as a branch.
- A forced failure prints Git's own error under the skipped branch. A second run reuses the
  worktrees. `-Pull` fast-forwards a clean worktree that is behind and leaves a dirty one
  untouched. The caller's `ErrorActionPreference` survives, and a missing mirror returns
  nothing.
- Static: Step 4 has a single implementation, which enumerates full ref names.

The long paths are removed with `rmdir \\?\`.

## Session status

The status block is the Master's only startup input. `SessionStatus.Tests.ps1` proves that
the script behaves offline, on a machine that is not the developer's. It emits a scratch
workspace, plants fake skill folders, a minimal `tool-status.json` (no command resolvable, so
no identity probe leaves the machine) and extra settings keys, then runs the emitted
`Get-SessionStatus.ps1` from an unrelated working directory:

- The block names the scratch root, prints every section, reports MCP as *installed* /
  *connected: none* and never as a CLI, flips missing tools to `found: false`, registers a new
  skill folder while existing keys and comments survive, and writes `session-status.last.txt`.
- With a fake workspace-storage tree (`FABRIC_AGENTIC_WORKSPACE_STORAGE`) it names a
  user-saved `.code-workspace` that lacks nested dispatch.
- Every run pins the user settings path (`FABRIC_AGENTIC_USER_SETTINGS`), so the developer's
  real `%APPDATA%` cannot change the outcome. A user file is edited only after earlier consent
  and stays byte-identical otherwise.
- A held skills catalogue is reported as held, and the PBIVIZ line comes from the shipped
  helper.
- Each session keeps its own snapshot in `session-status/<id>.txt`: concurrent runs do not
  mix, old snapshots are removed, and an id is never used as a path.

## Housekeeping

Agent working files must not pile up in the user's workspace, and cleaning them must never
cost the user a file they wanted. `Housekeeping.Tests.ps1` loads the working-files helper
from its single source (the `$agentWorkspaceScript` here-string) and runs it against
throwaway workspaces under TEMP:

- Task folders: closing one removes exactly the named files and refuses anything outside it.
- Preview: classifies files as safe, ambiguous, secret-flagged or protected, follows no link,
  writes only its report and never shows the value of a possible secret. Nothing is safe when
  the Git state cannot be read.
- Execute: moves nothing without a token bound to that plan, skips a file changed since the
  preview, refuses a tampered plan or a preview older than seven days, and changes nothing on
  a second run.
- Restore puts every file back without overwriting; purge needs its own token.
- Paths with spaces, beyond 260 characters and with non-ASCII or special characters work
  throughout.
- Also: the ignore rules for Power BI project files, the command line as agents run it in
  Windows PowerShell 5.1, and the installer side (the emitted helper is byte-identical to its
  source, every agent carries the working-files rule, 075 previews and 074 executes).

## Pipeline definition check

A pipeline change must not break an existing pipeline or bind it to another environment or to
the wrong kind of item, and a template must never claim more evidence than it has.
`Pipeline.Tests.ps1` loads the offline check from its single source (the
`$pipelineCheckScript` here-string) and runs it in-process on synthetic definitions under
`fixtures/pipelines/`. They hold placeholder ids only, and nothing calls Fabric:

- A correct definition passes only with the target workspace and its inventory. Without them
  the result is *UNCHECKED*, never *PASS*.
- Blocked: the endpoint-refresh template shipped with v0.8.0 (negative control), an id of
  another workspace, an id that is not in the inventory or names an item of the wrong type,
  removed or unverified activity types, broken dependencies, undeclared parameters and
  variables, and credential-like values, which are never printed.
- What the inventory cannot decide stays *UNCHECKED*. So does every reference written as an
  expression, listed one per line as `PD088`; the running workspace,
  `@pipeline().DataFactory`, is the exception.
- A definition from another workspace needs the target's current definition and gets a change
  plan.
- Unreadable input ends with exit code 2, and no file is ever written.
- The file also pins the `fabric-pipelines` skill (evidence classes, the same activity types
  as the check), the safeguards of agent 036 and the installer wiring.

## AI readiness and tooling

Both files check shipped text and detection logic. No server is contacted.

`AiReadiness.Tests.ps1` reads the `fabric-ai-readiness` house skill from its single source
(the `$aiReadinessContent` here-string) and the knowledge text of the semantic-model agents.
An agent must not call a model ready for Copilot, and a check must not be reported at a level
it was not run at:

- The skill is a managed skill written by the installer.
- Classes of change: exactly three (agent-editable, user-configured as a draft only, human
  setting). AI instructions, the AI data schema and verified answers are draft only.
- The skill never promises that such content can be written or deployed through TMDL, REST,
  XMLA or Git, never lets an agent report a model as AI ready or approved, and keeps the
  `Copilot/` folder and linguistic metadata byte-identical.
- Validation ladder: four levels (offline files, local tool, live model, Desktop or service).
  *Offline* means the first level only, and a check that was not run is NOT RUN.
- Product facts carry a source tag and the date they were read. The security text covers
  RLS/OLS and metadata exposure.
- Routing: the skill is pinned to 010, 015 and 016, the earlier guardrails of those agents
  are still present, and no semantic-model agent gained a tool.

`Tooling.Tests.ps1` loads `Get-RemoteMcpServers` and the Step 8 offer (`Invoke-RemoteMcpOffer`)
from the installer and reads the
`fabric-cli-policy` skill, the tool inventory code and the agent texts. *Documented*,
*configured* and *callable* stay apart, and a tool being present never becomes permission to
use it:

- Remote MCP servers: both are detected by URL from `mcp.json` (Fabric IQ on the public and
  the private-link endpoint, Fabric Data Warehouse on the global and an item-scoped
  endpoint). Look-alike URLs and servers without a URL are not taken for them. A server saved
  under a key the agents hold no grant for is reported as such. The status script carries the
  identical function and never lists a remote server as connected.
- The Step 8 offer, run on temporary files with mocked answers: only `Y` or `YES` adds an
  entry, and it holds only the type and URL. No answer, `N`, other text, a malformed JSONC
  file, a key conflict, an endpoint already present under any key and a re-run change
  nothing. Item scope writes the validated identifiers; invalid or missing identifiers never
  fall back to the global endpoint, which needs its own confirmation. Comments and existing
  servers survive, and tool-status then reads *configured*, never callable.
- Grants: Fabric IQ for 038 and 043 only, the write-capable warehouse server for 033 only.
- Policy skill: it names the five evidence states in order and does not claim a VS Code setup
  Microsoft does not document.
- SQL: five permission classes, a tool is never permission, an unclassifiable statement
  counts as a change, the route order, and read-only roles stop at data reads. No Warehouse
  MCP tool name is shipped: 033 takes the tool from the server's list in the session, and a
  missing or ambiguous tool is reported, never guessed.
- Other tools: Tabular Editor 2, Tabular Editor 3 and the `te` CLI are three keys. Only TE2
  is offered, TE3 is never inferred from TE2, and neither TE3 nor `te` is ever installed or
  updated. `pbir` stays the report tool, and Microsoft's report CLI is only detected.
- Fabric Agentic Workspace never starts Project Osmos by itself. Osmos needs the user's
  token, and its local state is ignored by Git and kept out of vendor stashes.

## PBIVIZ

`PBIVIZ.Alm.Tests.ps1` is the longest file. While you work on the helper, run it alone or
one `Describe` block (see [Run the tests](#run-the-tests)); add `PBIVIZ.Install.Tests.ps1`
for the installer side.

**What the tests create and leave alone.**

- Repositories, bare remotes, junctions (`mklink /J`), deny-list ACLs and the stand-in
  toolchain are created under TEMP and removed afterwards.
- The developer's global and system Git configuration is hidden, and the build tests restore
  every environment variable they touch.
- No test reads or writes a real certificate store entry or the real
  `%USERPROFILE%\pbiviz-certs` folder. The certificate-store check is simulated by replacing
  the helper's read-only store probe.

**Stand-in versus real SDK.** Every build in these tests uses a stand-in for the visual's
project-local `powerbi-visuals-tools`, a Node script. Its modes reproduce the behaviours
that matter: the SDK's certificate check and `pwsh` call, a shell-less spawn, an API install
attempt, hangs and detached children. The real SDK, a real Azure DevOps remote, Power BI
Desktop and the multi-agent flow are outside this suite (README
[3.11](../README.md#311-validation-compatibility-and-known-limitations)).

`PBIVIZ.Install.Tests.ps1` has two parts. The installer must never damage an existing folder
or repository while setting up Level 1.

- **Step 1 prompt.** Drives the real installer through Step 1 only (`-StopAfterStep1`) as a
  child process with scripted answers. Declining or end of input creates nothing. An empty
  name gives the default folder. A custom or existing folder is accepted and its contents
  left untouched. Paths, traversal, reserved and device names are rejected, and after five
  invalid names nothing is configured. A mapping with `enabled:false` asks again, an enabled
  folder that exists is kept without a question, a missing one offers Recreate, Choose or
  Disable, and an unreadable mapping is preserved byte for byte.
- **Functions.** Loads the PBIVIZ helper from its single source and
  `Get-PbivizFolderNameProblem`, `Get-JsoncTokens`, `Add-McpServerText`, `Merge-McpJson`,
  `Add-GitIgnoreRules`, `Write-ManagedFile` and `ConvertFrom-JsonLenient` from the installer,
  and runs them in-process against throwaway folders with real Git.
  - Folder names are validated against a table.
  - Level 1 initialises an empty folder on `main` with a baseline commit (trailer,
    `core.longpaths`), makes no commit for a folder that already had files or without a Git
    identity, and reuses the repository on a rerun. It skips below the Git floor (injected
    version string) and reports a missing folder as `FAILED` without throwing.
  - It stops with nothing changed on a nested repository (found at any depth and as a `.git`
    file, `node_modules` skipped), a `.git` file or an empty `.git` folder, a folder the
    outer repository already tracks, and a scan made incomplete by a junction or an
    unreadable folder. A OneDrive path is skipped unless allowed.
  - The outer ignore rule is written once, before Step 9, and works for a folder name with
    spaces. The mapping is written without a BOM and keeps unknown keys.
  - `mcp.json` is created, a second run changes nothing, and existing servers and inputs are
    kept. The entry is inserted as text, so JSONC comments, CRLF and a BOM survive byte for
    byte. The Learn server is recognised under another key or URL spelling. A malformed file,
    a conflicting key and a layout that cannot be patched verifiably are left untouched, the
    last with a manual instruction.
  - The status line separates missing, uninitialised, Level 1 and unborn folders.

`PBIVIZ.Alm.Tests.ps1` loads the PBIVIZ helper from its single source (the `$pbivizAlmScript`
here-string) and runs it against throwaway repositories and `git init --bare` remotes under
TEMP, with the developer's Git configuration and OneDrive variables hidden. An `AfterAll`
guard proves every remote URL is a temp path.

- Git is called binary-safe (quoting, literal pathspecs, Unicode names), and unsafe input is
  rejected before Git runs, with nothing changed.
- Adopting a remote keeps both histories and aborts on a conflict with nothing changed.
- A promotion moves one visual only, targets the current production revision, blocks an
  undeclared shared dependency (the dependency scan fails closed on every request form it
  cannot classify) and never touches the release archive or the user's checkout.
- Releases: Level 3 accepts only `validated: true` pairs, backed by evidence read from the
  package and bound to the source revision. Integrity keeps complete, partial and commit-only
  verification apart and fails on a manipulated claim. Archiving is transactional, and
  candidate cleanup checks identity and state before it removes anything.
- Builds run isolated: a disposable profile, the caller's certificate material untouched, no
  dependency download, the environment restored, and stale build homes swept only when their
  build has ended.
- Also covered: Test-stage reconciliation, provenance after merge, squash and rebase, and
  gate output in Windows PowerShell 5.1.

## Versions, documents and neutrality

`Version.Tests.ps1` keeps a version written in several places from drifting, keeps the
documents in line with the installer, and makes sure a failed run cannot look like a success:

- **Version.** The installer's `$productVersion`, the manifest `productVersion`, the README
  `**Version:**` line, the `.bat` banner and window title, and the newest CHANGELOG entry
  (`## [vX.Y.Z]`, neutral or with its real release date) agree. CHANGELOG versions are unique
  and descending, and every earlier entry carries its date. The README names no other
  version, `SECURITY.md` names none and points to the GitHub release listing, and none of the
  three carries a release-status claim such as *unreleased* or *not yet published*.
- **Documentation.** The README states the real number of house skills and names each one.
  The generated workspace guide names every Fabric house skill and counts the PBIVIZ ones
  correctly. The README quotes the install questions the installer really asks. The
  documented switches (`-EmitAgentsTo`, `-VerifyRoot`, `-StopAfterStep1`) exist. The README,
  the CLI guide and this file never say that a tool is installed without a question. Every
  `*.Tests.ps1` file is named in this file.
- **Launchers.** `Setup-FabricAgenticWorkspace.bat` and `Run-Tests.bat` return the exit code
  of the run and say when it failed or could not start. Copies of both are run through `cmd`
  with stand-in scripts, in a TEMP folder whose name holds a space; the real installer is not
  involved.
- **Encoding.** The installer and its launcher hold ASCII characters only. Windows PowerShell
  5.1 reads a script without a byte order mark in the ANSI code page, so any other character
  would reach the agent files garbled.

`Neutrality.Tests.ps1` is a static scan of the text files of the repository (installer,
documentation, tests, fixtures, schema, CI). The repository is public and must not
identify the machines, tenants or organisations it was built and tested on:

- Every GUID is a placeholder or one of the documented Windows constants.
- There is no portal folder number, no user-profile path naming an account, no synced-drive
  path naming an organisation, no staff-style account id, and no word on a private deny-list,
  which is kept as SHA-256 hashes.
- The installer's shipped text uses neutral provenance wording, and the PBIVIZ house skills
  name chart types, not private project folders.
- Negative controls prove that the GUID rule and the hash routine can fail.

## Documentation workflow

`DocReview.Tests.ps1` covers the maintainer documentation workflow in `.github/`, which the
installer does not ship: the `product-communication` skill, the Communication Writer agent,
the hook configuration and `Doc-Review.ps1`. It runs the real script as a child process
against a throwaway repository under TEMP, with hook events on standard input as the editor
sends them. A documentation review must be evidence about the files as they are now, not a
claim:

- The files are valid and short, and the installer and the agent baseline name none of them.
- At the end of a task a changed source file or document asks for a Writer review, at most
  twice. A changed test or workflow asks for nothing. The prompt text is never stored.
- Binding: a verdict needs the id of a run the hook started and counts only for that run,
  session and agent. A review is never recorded by running the script by hand, by another
  agent finishing, by the verdict `incomplete`, or by a verdict copied or reused from another
  run. A review of one session does not end another session's request, and two sessions whose
  hooks run at the same moment keep their own runs and readable state.
- Allowlist: a run that changed, added or removed anything outside the Writer's five
  documents is rejected and the file is named, with nothing reverted.
- Policy approvals: an unapproved edit of `SECURITY.md`, `CODE_OF_CONDUCT.md`, `LICENSE` or
  `THIRD_PARTY_NOTICES.md` fails the gate even when a review exists. An approval covers one
  exact text whatever the line ends, the Writer cannot approve its own change, and the four
  documents of this repository match `.github/hooks/policy-approvals.json`.
- Staleness: the gate passes for the reviewed files and fails after a later change to a
  source file, a document, an image under `assets/` or a review control. Restoring the
  reviewed content restores the review. The gate also fails when the hook configuration or
  the Writer agent is missing.

These tests prove what the script does. They do not prove that an editor session fires the
events or that an agent delegates.

## Shared helpers

`Manifest.Helpers.ps1` is not a test, and you never run it directly; most test files load
it. Its helpers:

- locate the installer and read the embedded manifest and the schema;
- hold the allowed tool set;
- load installer functions from the parsed script (`Get-InstallerFunctionLoader`);
- build the skill-catalogue fixture and the agent record that `SkillMap` compares
  (`New-SkillCatalogFixture`, `Get-GeneratedAgentRecord`);
- start the installer for prompt checks, and are the only way tests do so:
  `Invoke-BoundedChild` (closed input, bounded wait), `Get-PromptCheckAnalysis` and
  `Assert-PromptCheckSafe` (static allow-list check) and `Invoke-InstallerPromptCheck`
  (`-StopAfterStep1`, replaced profile and PATH, tripwires).

## Add a regression test

Reproduce the failure first, in the file that owns the code:

- PBIVIZ helper behaviour: `PBIVIZ.Alm.Tests.ps1`. Build fixtures with `New-TRepo`,
  `New-TVisual`, `Save-TAll` and `Install-TFakeTools -Mode <mode>`; for Level 3 use `New-TL3`
  and `Invoke-TPromotion`. The helper's single source is the `$pbivizAlmScript` here-string in
  the installer; the tests load it from there.
- Installer functions: load them from the parsed installer (see `PythonDetection.Tests.ps1`).
- Generated content: `Generated.Tests.ps1`.

Keep the test offline and under TEMP, restore what you change, and quote Git flags that look
like `TGit` parameters (`'-r'`, `'-D'`). Never weaken an existing assertion to make a run
green.

## Fixtures

`tests/fixtures/` holds recorded input for the tests. `pipelines/` holds the synthetic
definitions and the inventory for the [pipeline definition check](#pipeline-definition-check).

`skill-catalog.snapshot.json` and `agent-baseline.json` are committed evidence. Refresh them
on purpose and review the diff; never refresh them to make a run green.

- `skill-catalog.snapshot.json` is recorded from an installed workspace whose two clones are
  at the upstream commits you intend to support. It holds the relative path of every folder
  with a `SKILL.md` that sits directly in a skill container, any pinned reference that is not
  such a folder (for example a `references/*.md` file) with its type, and the two clone
  commits: identifiers only, no upstream text. Refresh it when a pin or alias changes, and
  only when every pin exists in that catalogue. To check that, first run `SkillMap.Tests.ps1`
  with `FABRIC_AGENTIC_CATALOG_ROOT` set to that workspace.
- `agent-baseline.json` is the identity baseline. For each of the 54 agents it records the
  name, description, invocability, tools, delegation targets and write permission. For 080-086
  it also records the pinned and suggested skills and a SHA-256 of the text from `## Playbook`
  to the end (LF-normalised). `Get-GeneratedAgentRecord` in `Manifest.Helpers.ps1` computes
  the same fields. Change the file only together with an intended change to an agent's
  identity, tools, hierarchy or the PBIVIZ team, and say so in the change description.

## What these tests do not cover

- **A real installation.** No test runs the installer end to end against a real Fabric or
  VS Code environment: no network, no tool installs.
- **How well an agent behaves.** The tests check the structure, required sections and safety
  rules of an agent file, not the quality of its prompt. That is judged in real use and by the
  installer's post-generation self-test (`guardrail-status.json`).
- **Remote services.** No test starts, signs in to or calls a remote MCP server, applies
  *Prep data for AI* content in Power BI or asks Copilot a question. `AiReadiness` and
  `Tooling` check the shipped text, the grants and the detection logic.
- **The real PBIVIZ toolchain.** See [PBIVIZ](#pbiviz).
