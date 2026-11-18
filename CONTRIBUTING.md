# Contributing to Fabric Agentic Workspace One-Click Setup

First off — thank you for considering contributing! This project is actively
looking for feedback, ideas, and improvements from the community.

## How can I contribute?

### Reporting bugs

Found something broken? [Open a bug report](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/issues/new?template=bug_report.yml).

Please include:
- Your OS and PowerShell version
- Steps to reproduce
- What you expected vs what happened
- Any terminal output or screenshots

### Suggesting features or improvements

Have an idea? [Open a feature request](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/issues/new?template=feature_request.yml).

All ideas are welcome — from small quality-of-life tweaks to entirely new
agent workflows or specialist agents.

### Submitting code changes

1. **Fork** the repository
2. **Create a branch** from `main`:
   ```
   git checkout -b feature/your-feature-name
   ```
   Use prefixes: `feature/`, `fix/`, `docs/`, `chore/`
3. **Make your changes** — keep commits focused and atomic
4. **Test your changes**:
   - Run the Pester suite: double-click `tests/Run-Tests.bat` (see [tests/README.md](tests/README.md) for focused runs, prerequisites and how to add a regression test)
   - Run the `.bat` installer on a clean folder to verify setup works end-to-end
   - If you modified an agent definition, test it in VS Code Copilot Chat
   - If you modified the PowerShell script, test on both PowerShell 5.1 and PowerShell 7+ if possible
   - The PBIVIZ Git helper has a single source, the `$pbivizAlmScript` heredoc inside the installer: change it there and add a test to `tests/PBIVIZ.Alm.Tests.ps1` that fails without your change
5. **Open a pull request** against `main`

### What's a good first contribution?

Look for issues labelled [`good first issue`](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/labels/good%20first%20issue)
or check [Validation, compatibility and known limitations](README.md#311-validation-compatibility-and-known-limitations)
in the README for areas that have not yet been exercised.

Some ideas:
- Cross-platform setup script (bash/zsh for macOS/Linux)
- Automated tests for the installer script
- Improved error messages or UX in the setup flow
- Additional agent workflows or skill integrations
- New specialist agents for uncovered Fabric workloads
- Documentation improvements

## Development setup

To work on this project locally:

1. Clone your fork:
   ```
   git clone https://github.com/<your-username>/Fabric-Agentic-Workspace-One-Click-Setup.git
   ```
2. The project has no build step — the deliverable is the two installer files
   inside `fabric-agentic-installer/`.
3. To test, double-click `Setup-FabricAgenticWorkspace.bat` or run the `.ps1`
   directly in PowerShell.

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

## Code style

- **PowerShell**: Use full cmdlet names (not aliases), meaningful variable names, and comment non-obvious logic
- **Markdown**: Use ATX headings (`##`), keep lines under 80 characters where practical
- **Agent definitions**: Follow the existing structure in the `.agent.md` files — clear phases, explicit instructions, no ambiguity

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/) style:

```
feat: add macOS setup script
fix: handle spaces in folder names
docs: clarify Fabric extension installation steps
chore: update skills-for-fabric clone URL
```

## Pull request guidelines

- Reference the related issue if one exists (e.g. `Closes #12`)
- Describe what changed and why
- Keep PRs focused — one feature or fix per PR
- Be open to feedback and iteration

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md).
By participating, you agree to uphold it.

## Questions?

Open a [discussion](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/issues)
or reach out via the issue tracker. There are no bad questions.
