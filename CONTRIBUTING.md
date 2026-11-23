# Contributing to Fabric Agentic Workspace — One-Click Setup

Bug reports, ideas and pull requests are welcome.

## Report a bug

[Open a bug report](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/issues/new?template=bug_report.yml)
and include:

- Your OS and PowerShell version
- Steps to reproduce
- What you expected and what happened
- Terminal output or screenshots

Report a security vulnerability privately instead: see
[SECURITY.md](SECURITY.md).

## Suggest a feature or improvement

[Open a feature request](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/issues/new?template=feature_request.yml).
Small tweaks are as welcome as new agent workflows or specialist agents.

## Submit a code change

1. **Fork** the repository and clone your fork:
   ```
   git clone https://github.com/<your-username>/Fabric-Agentic-Workspace-One-Click-Setup.git
   ```
2. **Create a branch** from `main`, with one of the prefixes `feature/`,
   `fix/`, `docs/` or `chore/`:
   ```
   git checkout -b feature/your-feature-name
   ```
3. **Make your changes.** There is no build step: the deliverable is the two
   installer files in `fabric-agentic-installer/`. Keep each commit to one
   change.
4. **Test your changes**:
   - Run the Pester suite: double-click `tests/Run-Tests.bat`.
     [tests/README.md](tests/README.md) covers focused runs, prerequisites
     and how to add a regression test.
   - Run the installer on a clean folder to check that setup works end to
     end: double-click `Setup-FabricAgenticWorkspace.bat` or run the `.ps1`
     in PowerShell.
   - If you changed the PowerShell script, test under Windows PowerShell 5.1
     and, if you can, PowerShell 7 or later.
   - If you changed an agent, install into a test folder and try the agent
     in VS Code Copilot Chat.
   - The PBIVIZ Git helper has a single source, the `$pbivizAlmScript`
     heredoc inside the installer: change it there and add a test to
     `tests/PBIVIZ.Alm.Tests.ps1` that fails without your change.
5. **Open a pull request** against `main`.

## Code style

- **PowerShell**: full cmdlet names (no aliases), meaningful variable names,
  a comment where the logic is not obvious.
- **Markdown**: ATX headings (`##`); lines under 80 characters where
  practical.
- **Agent definitions**: the installer generates the `.agent.md` files, so
  change an agent in `Setup-FabricAgenticWorkspace.ps1`, not in a generated
  file: `$agentManifestJson` holds its identity, hierarchy and tools,
  `$agentKnowledge` its skills and playbook. Follow the structure of the
  existing entries and keep instructions explicit. `-EmitAgentsTo <dir>`
  writes the generated files without installing anything. A change to an
  agent's identity or tools also needs the baseline fixture updated (see
  [tests/README.md](tests/README.md)).

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/) style:

```
feat: add macOS setup script
fix: handle spaces in folder names
docs: clarify Fabric extension installation steps
chore: update skills-for-fabric clone URL
```

## Pull request guidelines

- Reference the related issue if one exists (for example `Closes #12`).
- Describe what changed and why.
- Keep each pull request to one feature or fix.
- Expect review feedback and follow-up changes.

## Good first contributions

Look for issues labelled [`good first issue`](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/labels/good%20first%20issue),
or pick an item from *Not verified end to end* in
[Validation, compatibility and known limitations](README.md#311-validation-compatibility-and-known-limitations).

Some ideas:

- A setup script for macOS or Linux (bash/zsh); the installer runs on
  Windows only
- A regression test for a case the suite does not cover yet
- Clearer error messages or prompts in the setup flow
- More agent workflows or skill integrations
- Specialist agents for Fabric workloads the team does not cover yet
- Documentation improvements

## Maintainer notes: reviewing the upstream skill catalogues

The two vendor skill catalogues change upstream. Deciding what a change means for the agents is
a maintainer task, done in a regular review of this repository. It is **not** something an
installed workspace does: no installation schedules a review, asks its user to map a skill, or
runs anything in the background. A user's installation only applies the outcome (a compatible
catalogue is taken; an incompatible one is held at the last compatible commit).

What a review changes, and where:

1. Read what moved upstream (new, renamed, removed or split skills; new capabilities worth
   pinning). In an installed workspace, **070 - Capability Maintenance Team Lead** can list held
   catalogues and unresolved or newly available skills.
2. In `fabric-agentic-installer/Setup-FabricAgenticWorkspace.ps1`: update pins in the agent
   knowledge catalogue, add a verified rename to `$skillAliases` (never a guess, never across
   providers), and move `approved` in `$vendorCatalogs` to the commits you validated.
3. Refresh `tests/fixtures/skill-catalog.snapshot.json` from a workspace whose clones are at those
   commits, and `tests/fixtures/agent-baseline.json` only if an agent's identity, tools or the
   PBIVIZ team changed on purpose (see [tests/README.md](tests/README.md)).
4. Run `tests/SkillMap.Tests.ps1` (with `FABRIC_AGENTIC_CATALOG_ROOT` set to that workspace) and
   `tests/SkillCompat.Tests.ps1`, then the whole suite.
5. Date-stamped product facts inside the house skills (`fabric-pipelines`,
   `fabric-cli-policy`, `fabric-ai-readiness`) are re-read against Microsoft Learn in the same
   review; change the date only when the text was actually re-checked.

## Keeping the documentation current

The documents follow one house style,
`.github/skills/product-communication/SKILL.md`: what each document is for,
the changelog rules and the accuracy checks. Read it before you change one.

Maintainer tooling in `.github/` checks that the documents still match the
source when you work with a coding agent. The installer ships none of it.

- **Communication Writer** (`.github/agents/communication-writer.agent.md`): a
  reviewer that other agents run as a subagent. It compares the documents with
  the source, updates them and records a verdict. It may change five files:
  `README.md`, `CHANGELOG.md`, `CLI-FUNCTIONALITIES.md`, `CONTRIBUTING.md` and
  `tests/README.md`.
- **End-of-task hook** (`.github/hooks/documentation-review.json`, which runs
  `.github/hooks/Doc-Review.ps1`): when a task changed a file the review
  covers, it asks the agent to run the Writer before the task ends. It asks at
  most twice, then reports the review as incomplete: it can ask an agent to
  continue, but cannot make it delegate. The hook needs Windows PowerShell and
  does nothing on other systems.

**What a review covers.** A review is stale as soon as one of these files
differs from what was reviewed (a file added to or removed from the three
folders counts), and valid again when the reviewed content is restored:

- everything under `fabric-agentic-installer/`, `schema/` and `assets/` (the
  images)
- the Writer's five documents and the four policy and legal documents
- the review controls: the Writer agent file, the `product-communication`
  skill, `Doc-Review.ps1`, `documentation-review.json` and
  `policy-approvals.json`

**How a review is recorded.**

- When a Writer run starts, the hook gives it a run id. The Writer records its
  verdict with that id, as its last action:
  ```
  powershell -NoProfile -ExecutionPolicy Bypass -File .github/hooks/Doc-Review.ps1 -Attest -Run <run id> -Verdict complete -Summary "<one sentence>"
  ```
  Use `-Verdict incomplete` when the review could not be finished. A verdict
  without a run id, with an unknown id or for a closed run is refused, so
  running the script by hand never records a review.
- The review is recorded when the hook of the same session sees that run
  finish with the verdict `complete`. The record names the run, the session
  and the agent.
- The hook compares the whole repository before and after the run. If anything
  outside the five documents was changed, added or removed, the review is not
  recorded and the files are named. Nothing is reverted.
- A review belongs to the session that produced it: it ends that session's
  end-of-task request, never another session's.

For a change nobody can observe (refactoring, comments), the agent can record
that instead, with the session id printed in the end-of-task request:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .github/hooks/Doc-Review.ps1 -NoImpact -Session <session id> -Reason "<one sentence>"
```

This quiets that session only and is never a review: the gate still needs one.

Records are kept in `.git/doc-review/` (under TEMP if the checkout has no
`.git` folder), so they are never committed.

**Policy and legal documents.** `SECURITY.md`, `CODE_OF_CONDUCT.md`, `LICENSE`
and `THIRD_PARTY_NOTICES.md` change only by the owner's decision. The Writer
never edits them, not even a typo: it proposes the exact text.
`.github/hooks/policy-approvals.json` records, for each document, the SHA-256
of the text the owner approved (UTF-8, LF line ends). After the owner decided
on a change, record the decision from the repository root:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .github/hooks/Doc-Review.ps1 -ApprovePolicy -File <document> -ApprovedBy "<who decided>" -Reason "<the decision>"
```

The approval covers that exact text only, so a later edit needs its own.
`tests/DocReview.Tests.ps1` checks in CI that the four documents match the
approvals file.

**Release gate.** Before a release, run the gate from the repository root:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .github/hooks/Doc-Review.ps1 -Gate
```

It looks at the files only, whichever session reviewed them. It prints
`DOC GATE: PASS` and returns exit code 0 only when all of this holds:

- a recorded review matches the current files
- each policy and legal document holds the text its owner approved
- the hook configuration, the Writer and the skill are in place

Otherwise it prints `DOC GATE: FAIL` with the reason and returns 1. For a
missing or stale review, ask your agent to run a Communication Writer review,
then run the gate again. A review cannot settle a policy or legal document
that differs from its approved text: restore it, or have the owner approve the
new text.

`-Status` instead of `-Gate` shows the same state without the pass or fail,
including the latest Writer run when it was rejected.

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md).
By participating, you agree to uphold it.

## Questions?

Ask in the [issue tracker](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/issues).
