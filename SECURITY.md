
# Security Policy

## Supported Versions

Fabric Agentic Workspace — One-Click Setup is currently under active development and distributed as a **prerelease**.

Security fixes and maintenance updates are targeted at the latest **published** prerelease.

| Version | Status | Supported |
|---|---|---|
| v0.7.3 | Latest published prerelease (the current baseline) | :white_check_mark: |
| v0.8.0 | Unreleased development candidate on the `feature/v0.8.0-pbiviz` branch: implemented, manual (Canary) acceptance done, final release checks pending, **not published** | Not yet — becomes supported only when it is released |
| v0.7.2 and earlier prereleases | Superseded | :x: — upgrade to v0.7.3 |

When v0.8.0 is released, this table is updated in the same release: v0.8.0 becomes the supported version and v0.7.3 moves to "upgrade recommended".

Users are encouraged to keep their workspace up to date by downloading the latest published installer and re-running the setup process.

**Note:** Prerelease status indicates that the project is still evolving. Security and reliability improvements are ongoing, and production readiness is not guaranteed.

## Reporting a Vulnerability

If you discover a security vulnerability in this project, **please do not open a public GitHub issue** or disclose the vulnerability publicly before it has been reviewed.

Instead, report it privately to the project maintainer.

**Security contact:** [stefano.ciurlia01@gmail.com](mailto:stefano.ciurlia01@gmail.com)

Please include:

- A clear description of the vulnerability.
- Steps to reproduce the issue.
- The affected component and version.
- The potential security impact.
- Any relevant logs, screenshots, or proof-of-concept details, excluding sensitive credentials or confidential information.

The maintainer aims to acknowledge security reports within **48 hours** and will work with the reporter to investigate, assess, and address confirmed vulnerabilities.

Responsible disclosure is appreciated.

## Security Scope

This project provides a locally installed, GitHub Copilot–based agentic development environment for Microsoft Fabric and Power BI.

Its architecture includes a PowerShell-based installer, generated VS Code configurations, hierarchical GitHub Copilot agents, MCP integrations, and externally maintained specialist skill repositories.

Security concerns within scope include:

- **Installer security** — unintended command execution, unsafe filesystem operations, path traversal, or installation failures that could compromise existing user files.
- **Configuration integrity** — unintended modification or loss of VS Code user settings, workspace configurations, or existing development environments.
- **Agent permissions and orchestration** — excessive tool privileges, unauthorized operations, unsafe delegation, or bypassing documented approval requirements.
- **Credential and token protection** — accidental exposure of authentication tokens, connection strings, secrets, or sensitive configuration values.
- **MCP integration security** — unsafe interactions with MCP servers, inappropriate tool access, or operations performed without sufficient authorization.
- **Supply-chain security** — compromised upstream skill repositories, unsafe Git operations, untrusted dependencies, or insecure external downloads.
- **Update and maintenance safety** — unintended overwrites, deletion of user-authored content, loss of local changes, or corruption of workspace configurations.
- **Generated artifact integrity** — unexpected modifications to generated agent definitions, skill registrations, manifests, or operational scripts.

## Security Design Principles

The project aims to follow these security principles:

1. **Least privilege** — agents should receive only the permissions and tools required for their responsibilities.
2. **Explicit authorization** — sensitive, destructive, or production-impacting operations should require appropriate user approval.
3. **Non-destructive updates** — installer updates should preserve user-authored files, configurations, and unrelated development work.
4. **Integrity verification** — managed files and generated configurations should be verifiable through the project's integrity mechanisms.
5. **Controlled delegation** — agent orchestration should respect defined roles, permissions, approval requirements, and execution boundaries.
6. **Transparent failures** — security-relevant failures should be reported clearly rather than silently ignored.
7. **Safe maintenance** — upstream repository refreshes and workspace updates should include safeguards against accidental data loss.

These principles describe the project's intended security model and do not constitute a guarantee that every implementation is free from vulnerabilities.

## Custom visual (PBIVIZ) development — what the safeguards cover (v0.8.0 candidate)

**User approval boundaries.** Agents stop and ask for an explicit token before they install or download packages (`APPROVED:INSTALL:<visual>`), connect a remote, push, open or merge a pull request, tag, distribute a release, archive a package from outside the build output (bound to its SHA-256) or discard an uncommitted release candidate. A request in plain words is not a token. A merge additionally needs every required review and check reported satisfied by the provider.

**Local Git safeguards.** All repository work goes through the deterministic helper `Pbiviz-Alm.ps1`: inputs are validated before Git runs, pathspecs are literal, a branch is never moved by force, there is no `reset --hard`, `clean` or force-push, a backup ref is written before remote adoption changes a branch, release archives are append-only and a release candidate is built in a separate worktree.

**Remote mutation controls.** The helper itself never pushes, opens pull requests, merges, tags or distributes; those are separate agent actions, each gated by its own token. After a merge nothing is written to the production branch: provenance and integrity are derived and re-checked.

**Local build isolation.** A release build (`Invoke-PbivizBuild`) runs the visual's own `powerbi-visuals-tools` with a disposable profile in the repository's Git directory, a public-only placeholder certificate, a guard that stops the SDK's certificate generation (also against a same-named file in the visual folder), offline npm with a disposable cache and a private TEMP, under process-tree supervision with a timeout. It is blocked before the CLI starts when the SDK would itself download or change dependencies, and it fails without evidence on any sign of a certificate change, a new certificate in the current user's store or an attempted dependency install. The caller's environment is restored and the disposable folder removed.

**Certificate and profile side effects.** Release builds do not use the user's `%USERPROFILE%\pbiviz-certs` folder or create certificates; the current user's certificate store is only read. *Development* commands run outside the helper (`pbiviz start`, a development `pbiviz package`) behave as the SDK intends: they use and may regenerate the developer certificate in the real profile and, with PowerShell 7 installed, may add a certificate to the current user's store.

**What is not guaranteed.** The build isolation contains the SDK's known side effects; it is **not** an operating-system sandbox. The visual's toolchain (the CLI, ESLint, webpack and every package in `node_modules`) runs with the user's rights and can read or write anything the user can; the SDK's certificate check starts Windows PowerShell, which loads the user's PowerShell profile. Recorded lint, unit and review results are attestations by the agents that reported them, not evidence the helper produced. The dependency check (G4) is a static classification of the visual's own files, not a proof about the bundle, and does not inspect `node_modules`.

**Risks of third-party development tools.** Installing a visual's dependencies (`npm ci`, `pbiviz new`) executes and downloads third-party code from the npm registry. Review a visual's dependencies and lockfile like any other code before approving an install, and keep Node.js and `powerbi-visuals-tools` up to date.

## Third-Party Components

This project integrates with external tools and repositories, including Microsoft Fabric, Power BI, Visual Studio Code, GitHub Copilot, MCP servers, and upstream agent skill collections.

These components are maintained independently and may introduce security considerations outside the direct control of this repository.

Users should:

- Obtain software and dependencies from trusted sources.
- Keep relevant development tools and extensions updated.
- Review permissions requested by external integrations.
- Avoid storing secrets directly in source-controlled files.
- Follow their organization's security and access-control policies.

## Security Limitations

This project does not replace organizational security controls, Microsoft Fabric permissions, GitHub authentication, or existing enterprise governance requirements.

Agent-generated commands and modifications should be reviewed according to their potential impact, particularly when interacting with production environments or sensitive organizational data.

The project is provided without any guarantee of complete security. Users remain responsible for evaluating its suitability for their environment and applying appropriate safeguards.

## Security Updates

Confirmed vulnerabilities affecting maintained versions may be addressed through subsequent prerelease updates.

Security-related fixes will be documented in the project's changelog or release notes when disclosure is appropriate.

For the latest available version, see the [GitHub Releases](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/releases) page.

---

Thank you for helping improve the security, reliability, and maintainability of Fabric Agentic Workspace — One-Click Setup.
