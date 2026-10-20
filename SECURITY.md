# Security Policy

## Supported Versions

Fabric Agentic Workspace — One-Click Setup is currently under active development and distributed as a **prerelease**.

Security fixes and maintenance updates are targeted at the latest prerelease version.

| Version | Supported |
|---|---|
| v0.7.2 (current prerelease) | :white_check_mark: |
| v0.7.1 and earlier prereleases | :x: — Upgrade recommended |

Users are encouraged to keep their workspace up to date by downloading the latest installer and re-running the setup process.

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
