# Fabric Agentic Workspace — One-Click Setup

[![Latest Release](https://img.shields.io/github/v/release/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup?include_prereleases&label=version)](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/releases)

Pre-release — used regularly by the maintainer in real Fabric work, evolving fast.
Contributions and feedback welcome.

**Bootstrap a Fabric-ready Copilot agent workspace for VS Code.**

> **The 30-second version**
> - **What** — a one-click installer that scaffolds an opinionated Microsoft Fabric development workspace in VS Code.
> - **Who it's for** — anyone working in Fabric (semantic models, data engineering, reports, pipelines, admin, app dev, DevOps) who wants Copilot agents that already know the right tools and house conventions.
> - **How to run** — double-click `Setup-FabricAgenticWorkspace.bat`, answer a few prompts, and let it scaffold.
> - **What you get** — nine Copilot agents, three embedded Fabric skills plus two curated open-source skill sources, optional CLI/MCP live tooling, and guidance for a governed DEV→PROD workflow.

> Windows installer (PowerShell + `.bat`); the workspace itself is OS-agnostic
> once created.

---

<p align="center">
  <img src="assets/architecture-overview.png" alt="Fabric Agentic Workspace — Architecture Overview" width="100%"/>
</p>

## Installation demo

The demo video demonstrates the guided installation flow: launch the installer,
answer the setup prompts, let the workspace scaffold, and open the configured
VS Code environment with agents, skills, and optional live tooling ready to use.

<p align="center">
  <img src="assets/Installation-Demo.gif" alt="Installation demo showing the one-click setup flow" width="100%"/>
</p>

In this recording, the main requirements are already installed. If they are not
present on your machine, the installer will attempt to install them
automatically. 

⚠️ The Azure CLI (`az`) is the dependency most likely to take longer
when it needs to be installed from scratch.

---

## Contents

- [Why this exists](#why-this-exists)
- [What is this?](#what-is-this)
  - [What this is / is not](#what-this-is--is-not)
  - [Copilot Chat vs CLI/plugin workflows](#copilot-chat-vs-cliplugin-workflows)
- [What you get](#what-you-get)
- [Agent → tools → skills matrix](#agent--tools--skills-matrix)
  - [Tool coverage](#tool-coverage)
- [Agentic design principles](#agentic-design-principles)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
  - [1. Get the files](#1-get-the-files)
  - [2. Run the installer](#2-run-the-installer)
  - [3. Start working](#3-start-working)
  - [4. Keeping it up to date](#4-keeping-it-up-to-date)
- [What the agents can do](#what-the-agents-can-do)
  - [Guided session startup](#guided-session-startup)
  - [Specialist agents](#specialist-agents)
  - [Skill-based development](#skill-based-development)
- [Workspace structure](#workspace-structure)
- [How it works under the hood](#how-it-works-under-the-hood)
  - [The Fabric development lifecycle (the backbone)](#the-fabric-development-lifecycle-the-backbone)
  - [A bit of history: how Fabric/Power BI work used to flow](#a-bit-of-history-how-fabricpower-bi-work-used-to-flow)
  - [Three ways of working](#three-ways-of-working)
- [FAQ](#faq)
- [Current status (v0.5.0-pre-release)](#current-status-v050-pre-release)
- [Contributing](#contributing)
- [Files in this repository](#files-in-this-repository)
- [License](#license)
- [Third-party notices](#third-party-notices)

---

## Why this exists

This is a personal project — and like most personal projects, it started from a real need.

I was doing a lot of work across **Microsoft Fabric**: building semantic models, doing ETL with Spark notebooks, designing data pipelines, and managing workspaces — all while adapting my workflow to the dynamic and always evolving agentic development.

The **[Microsoft Fabric](https://marketplace.visualstudio.com/items?itemName=fabric.vscode-fabric)** and **[Fabric Data Engineering - Remote](https://marketplace.visualstudio.com/items?itemName=SynapseVSCode.vscode-synapse-remote)** VS Code extensions are great for syncing items locally and running notebooks against remote Spark. But the AI-assisted development experience felt like it could be improved: GitHub Copilot didn't know about my TMDL and DAX best practices — particularly my own conventions around table naming, measure structures, and folder organization. Furthermore data pipeline JSON authoring wasn't really covered anywhere I looked.

So I built a multi-agent workspace that brings everything together. A **master agent** coordinates session startup and routes to **specialist agents** — each focused on a specific Fabric workload (semantic models, data engineering, admin, reports, pipelines, app dev, and DevOps/ALM). They all read from what I consider the best skill repositories from the community — Microsoft's [skills-for-fabric](https://github.com/microsoft/skills-for-fabric) and data-goblin's [power-bi-agentic-development](https://github.com/data-goblin/power-bi-agentic-development) — plus **custom embedded skills** for TMDL and data pipeline authoring that I wrote from scratch and keep updating, based on my job and the problems I face there.

As I went deeper I realised the **agent → tools → skills** chain matters as much as the agents themselves. So each agent now owns a **minimum, deterministic set of tools** — the right CLI for its workload (`fab`, `az`, `sqlcmd`, `pbir`, Tabular Editor CLI, `pbi-tools`, `gh`, `az devops`) and the MCP servers where they help — instead of a vague "all tools to everyone" pile. Tool availability is discovered once and recorded in a machine-specific `tool-status.json` inventory. An agent then checks what's actually installed, uses it if present, and **falls back cleanly when it isn't** — which is what keeps the whole thing working on locked-down corporate PCs. A custom **`fabric-cli-policy`** skill encodes the decision rule: prefer `fab`, with `az` as a documented fallback. And each agent loads **only the skills its current subtask needs** rather than eagerly reading everything.

This is a **starting point, not a finished system.** This release adds the tools layer (the `tool-status.json` inventory and the per-tool opt-in installer), tightens every agent around its minimum tools and the existing `fabric-cli-policy` skill, and introduces a dedicated **DevOps/ALM agent** (Git Integration, Deployment Pipelines, Azure DevOps & GitHub). More is planned — for example a custom `fabric-devops-policy` skill capturing my real DEV→PROD promotion workflow, and continued tuning of which skills each agent reads. The architecture is deliberately additive so new tools, skills, and agents slot in without breaking the existing ones.

Then I thought: *this should be replicable*. Not just for me — for anyone who works with Fabric and wants an AI-powered development workflow. So I packaged everything into a one-click installer and a shareable agent configuration.

---

> **⚠️ Disclaimer — Please read before using**
>
> This is a **personal and community project**, built in my spare time for fun and to share something useful. It is not an official Microsoft product, is not affiliated with Microsoft in any way, and comes with no guarantees of any kind.
>
> **AI involvement:** This project was built with significant help from **GitHub Copilot** in VS Code. Copilot assisted in writing the installer scripts, agent configuration files, custom skills, documentation, and a large portion of the "heavy lifting" — from structuring the codebase and handling edge cases, to generating boilerplate and refining prompts. The core ideas, design decisions, and testing are mine; the speed at which it came together is Copilot's.
>
> **Early stage — use with care:** This is very much a pre-release version. It has been tested and works, but it is at the beginning of its life. Given the level of AI involvement in its creation, there may be bugs, edge cases, or behaviours that do not work as expected in your specific environment. **Do not use this in production environments without fully understanding what the scripts do.** Always review the code before running it.
>
> **Third-party skill dependencies:** This workspace clones and depends on two external repositories — [microsoft/skills-for-fabric](https://github.com/microsoft/skills-for-fabric) and [data-goblin/power-bi-agentic-development](https://github.com/data-goblin/power-bi-agentic-development). These are independent open-source projects maintained by their respective owners. This project has no control over their content, availability, or future changes. The agents are **resilient to these repos restructuring or renaming their internal folders** — skills are discovered dynamically at runtime (list the repo root, search by keyword) rather than from fixed paths. However, if a whole repository is **renamed, moved, or removed** at the GitHub level, or its history diverges so `git pull --ff-only` fails, the clone/update step will break until the references are updated.
>
> **Licensing & provenance:** `skills-for-fabric` is MIT-licensed; `power-bi-agentic-development` is **GPL-3.0** and is used **only as a locally cloned, gitignored reference** that agents read at runtime — it is never copied, AI-rewritten, or redistributed inside this project. The custom embedded skills (`fabric-tmdl`, `fabric-pipelines`, and `fabric-cli-policy`) are **original maintainer-authored works in this repository** — written from scratch (`fabric-tmdl` and `fabric-cli-policy` from my own best practices; `fabric-pipelines` derived from Microsoft sources combined with my working experience). Always check those repos directly for their own licensing terms and usage conditions.
>
> This project is used regularly by the maintainer in real Microsoft Fabric work,
> including local, live, and hybrid workflows on a locked-down corporate Windows
> machine. It is still pre-release: validation is currently manual and
> experience-based rather than backed by a formal automated test suite.
>
> That said — it is a practical starting point, and I hope it saves you time and sparks ideas. Feedback, bug reports, and contributions are very welcome.

---

## What is this?

This is a **guided workspace bootstrapper and multi-agent Copilot configuration**
for Microsoft Fabric development in VS Code. Instead of manually setting up
folders, config files, agent definitions, skill references, and cloning
repositories, you run a single script and everything is ready.

Once set up, a team of custom Copilot agents lives inside your workspace:
a **Master Agent** that coordinates session startup and routing, a **Skills
Maintainer** that keeps everything up to date, and **seven specialist agents**
covering every major Fabric workload — all guided by skills from Microsoft,
the community, and custom embedded knowledge.

### What this is / is not

This project is:

- A VS Code workspace bootstrapper for Microsoft Fabric developers
- A GitHub Copilot Chat / Agent Mode workspace configuration bundle
- A local-first Fabric development accelerator with optional live tooling
- A repeatable way to package the maintainer's real-world Fabric workflow

This project is not:

- An official Microsoft product
- A hosted service or SaaS application
- A GitHub Copilot CLI or Claude Code plugin distribution
- A replacement for Fabric Git integration, deployment review, or workspace governance
- A guarantee that AI-generated edits are correct without human review and testing

### Copilot Chat vs CLI/plugin workflows

This workspace is designed first for **VS Code GitHub Copilot Chat / Agent
Mode**. In that mode, the installer creates local custom agents and embedded
skills, then clones Microsoft and data-goblin repositories as local reference
sources that those agents can search and read at runtime.

The upstream repositories also provide plugin-oriented workflows for GitHub
Copilot CLI, Claude Code, or compatible agent runtimes. This project does not
redistribute, copy, or install those upstream plugin bundles into its own
`.github` structure. If you want those CLI/plugin workflows, install and use the
upstream projects directly:

- [microsoft/skills-for-fabric](https://github.com/microsoft/skills-for-fabric)
- [data-goblin/power-bi-agentic-development](https://github.com/data-goblin/power-bi-agentic-development)

> **Tool vs runtime — don't conflate them.** The **Fabric CLI (`fab`)** is a
> *tool* the agents actively call (including from Copilot Chat) to work live
> against a Fabric workspace — it is central to the live and hybrid modes, not an
> add-on. **GitHub Copilot CLI** and **Claude Code** are something else:
> alternative *runtimes* to VS Code Copilot Chat. This project targets **Copilot
> Chat / Agent Mode** and is intentionally a lean, curated workspace — its
> `.github` holds only the maintainer's agents and skills, with **no plugin
> hooks, manifests, or bundled plugin items**. That curated shape is exactly why
> it fits Chat / Agent Mode rather than a hook-based Copilot CLI plugin
> distribution.

Practical advice: if you work in Copilot CLI or Claude Code plugin mode, avoid
installing every available plugin into one crowded workspace. Plugins can bring
their own agents, skills, hooks, and instructions; too many unrelated plugins can
compete for context and make the agent less focused. Create or open a
task-specific project folder and install only the plugins that match that work.
For example, this is how I would scope a CLI environment, while still deferring
to the upstream documentation for exact install commands and current behavior:

| Project scope | Consider installing |
|---|---|
| PBIP / source-controlled Power BI project | [pbip](https://github.com/data-goblin/power-bi-agentic-development/tree/main/plugins/pbip) |
| Semantic model / DAX / TMDL-heavy work | [semantic-models](https://github.com/data-goblin/power-bi-agentic-development/tree/main/plugins/semantic-models), optionally [tabular-editor](https://github.com/data-goblin/power-bi-agentic-development/tree/main/plugins/tabular-editor) |
| Power BI Desktop live-model work | [pbi-desktop](https://github.com/data-goblin/power-bi-agentic-development/tree/main/plugins/pbi-desktop) |
| Report / PBIR / visual work | [reports](https://github.com/data-goblin/power-bi-agentic-development/tree/main/plugins/reports), optionally [pbip](https://github.com/data-goblin/power-bi-agentic-development/tree/main/plugins/pbip) |
| Fabric CLI / service operations | [fabric-cli](https://github.com/data-goblin/power-bi-agentic-development/tree/main/plugins/fabric-cli) |
| Fabric admin / governance work | [fabric-admin](https://github.com/data-goblin/power-bi-agentic-development/tree/main/plugins/fabric-admin) |

In short: use this installer for the VS Code Copilot Chat / Agent Mode
workspace. For CLI/plugin workflows, use a focused project folder and install
only the upstream plugins that fit the project.

---

## What you get

| Component | Description |
|---|---|
| **Fabric Workspace Master Agent** | Routing hub — handles session startup (skill check, Azure identity, topic menu), then routes to the right specialist or handles tasks directly with dynamic skill discovery. Can also proactively recommend the best specialist for a free-text request |
| **Fabric Skills Maintainer Agent** | Light (quick pull + tool-inventory refresh) or deep (pull + tool-inventory refresh + MS docs freshness check + unreferenced skill scan) maintenance of all skill sources |
| **Semantic Model Agent** | TMDL editing, DAX measures, columns, relationships, partitions — house style from the custom fabric-tmdl skill, syntax/DAX depth from data-goblin (explicit precedence) |
| **Fabric Data Engineer Agent** | Spark notebooks, SQL warehouse, pipelines, medallion architecture — guided by Microsoft's skills-for-fabric |
| **Fabric Admin Agent** | Capacity management, governance, security, workspace documentation |
| **Fabric App Dev Agent** | Python apps, ODBC, XMLA, REST API integration with Fabric data |
| **Fabric Reports Agent** | PBIR report editing, visuals, themes — guided by data-goblin report skills |
| **Fabric Pipelines Agent** | Data Factory pipeline JSON authoring — guided by the custom fabric-pipelines skill |
| **Fabric DevOps Agent** | ALM/DevOps coordination — Fabric Git Integration, Deployment Pipelines, Azure DevOps & GitHub PRs/CI-CD, branch & PR workflows, and conflict resolution on text-based Fabric definitions (not artifact authoring) |
| **Custom TMDL Skill** *(original to this repo)* | Comprehensive embedded skill covering TMDL syntax, indentation rules, property ordering, Direct Lake patterns, lineageTag rules, and post-edit validation. Written from scratch for this project. |
| **Custom Pipelines Skill** *(original to this repo)* | Full pipeline activity type reference with typeProperties, expression syntax, Variable Library integration, and validation checklist. Authored for this project. |
| **Custom CLI Policy Skill** *(original to this repo)* | Embedded decision policy that tells the agents to prefer the Fabric CLI (`fab`) and fall back to `az`/`sqlcmd` only where needed — with `az rest` → `fab api` translation, a fallback matrix for SQL/TDS and non-Fabric tokens, and guardrails. Written from scratch for this project. |
| **Microsoft skills-for-fabric** | Git-cloned from [microsoft/skills-for-fabric](https://github.com/microsoft/skills-for-fabric) — Spark, SQL, Eventhouse, medallion, and more |
| **Data-goblin skills** | Git-cloned from [data-goblin/power-bi-agentic-development](https://github.com/data-goblin/power-bi-agentic-development) by [Kurt Buhler](https://www.linkedin.com/in/kurtbuhler/) — PBIP, DAX, reports, Fabric CLI, Fabric admin |
| **Git Version Control** | Repository initialised with a clean `.gitignore` and first commit out of the box |
| **VS Code Configuration** | Settings and tasks pre-configured for the agentic workflow |

---

## Agent → tools → skills matrix

The workspace is **not skill soup**. Each agent has a **bounded purpose**, owns a
**minimum set of deterministic tools**, and reads **only the skills its current subtask
needs**. CLIs and MCP servers are *not* listed as Copilot frontmatter tools — they are
binaries/servers invoked through `execute`, gated on `.github/agent-docs/tool-status.json`
(a machine-specific, gitignored inventory written by the installer). If a tool is missing,
the agent degrades gracefully; routing is by **topic**, never by tool availability.

| Agent | Capabilities | Tools used (via `execute`, gated on `tool-status.json`) | Skills / docs used (selective) |
| ----- | ------------ | ------------------------------------------------------- | ------------------------------ |
| **1 — Fabric Workspace Master** | Session startup, task classification, routing to specialists, direct handling only when the user stays with Master, anti-soup orchestration | No specialist tool execution by default; reads `tool-status.json` only to inform an inline CLI task | `.github/copilot-instructions.md` + `AGENTS.md` (startup), `agent-docs/starting-flow.md` (startup), `agent-docs/working-flow-reference.md` (direct handling), `fabric-cli-policy` only if handling a CLI task inline |
| **2 — Fabric Skills Maintainer** | Pull/update external skill repos, check freshness, detect new upstream skills, maintain the local tool inventory | `git` (pulls `skills-for-fabric` + `power-bi-agentic-development`); regenerates `tool-status.json`; tool detection only | No domain skills for delivery; reads `skills-for-fabric/skills/check-updates/` for guidance |
| **3 — Semantic Model** | TMDL editing, DAX writing/debugging, naming/audit, model validation/BPA/automation | Tabular Editor CLI (`tabularEditor.found`); Power BI semantic-model MCP server (`powerBiModelMcpServer.found`) | `fabric-tmdl` always; data-goblin `dax` only for DAX; `pbip`/`semantic-model` for extra depth; `standardize-naming-conventions` for naming/audit; `tabular-editor` skills only for TE/BPA tasks |
| **4 — Fabric Data Engineer** | Spark notebooks, SQL warehouse, Eventhouse/KQL, Lakehouse/OneLake/table ops, medallion, pipeline coordination | `fab` (jobs, items, export/import, OneLake); `sqlcmd` (`sqlcmd.found`); `az` non-Fabric fallback; **Fabric MCP server** (`fabricMcpServer.found`) for live item/OneLake reads | `fabric-cli-policy` before any CLI task; **one** relevant `skills-for-fabric` skill per subtask (Spark/SQL/Eventhouse/Medallion); never all at once |
| **5 — Fabric Admin** | Workspace admin, capacity/governance/security, tenant/admin API ops, inventory & docs | `fab api` (workspace/capacity/admin); `az` non-Fabric fallback | `fabric-cli-policy` before any CLI task; one relevant MS admin/governance skill; data-goblin `fabric-admin` selectively |
| **6 — Fabric App Dev** | Fabric REST/API integration, SQL endpoint connectivity, XMLA/live-model integration, Python/ODBC patterns | `fab api`; `sqlcmd` (`sqlcmd.found`); Power BI semantic-model MCP server (`powerBiModelMcpServer.found`); `az`/DefaultAzureCredential | `fabric-cli-policy` before REST/API tasks; `skills-for-fabric` SQL consumption skill for endpoint patterns |
| **7 — Fabric Reports** | PBIR report editing, visual/page/layout changes, binding, themes, design review, report-level DAX, custom visuals | `pbir` CLI (`pbir.found`) for visual/layout/binding/validation; `fab` for report lifecycle (export/import/rebind/clone) | data-goblin `pbir-cli` only with `pbir`; `pbir-format` (in the `pbip` plugin) only for direct JSON edits; `modifying-theme-json` for themes; `pbi-report-design`/`review-report` for design/review; `custom-visuals` for the specific visual; `dax` for report-level DAX |
| **8 — Fabric Pipelines** | Data Factory pipeline JSON authoring, activity editing, expressions/variables/parameters, run/status/export/import | `fab` (run, status, export, import) | `fabric-pipelines` always; `ITEM-DEFINITIONS-CORE.md` only for deep schema validation, not by default |
| **9 — Fabric DevOps** | Fabric Git Integration, Deployment Pipelines, Azure DevOps PRs/CI-CD/boards, GitHub PRs/Actions/releases, PBIP DevOps, ALM conflict/PR review of text-based definitions | `fab` (Git Integration / Deployment Pipelines); **Fabric MCP server** (`fabricMcpServer.found`) for live item GUIDs/inspection; `az devops` (`azureDevOpsCliExtension.found`); `gh` (`gh.found`); `pbi-tools` (`pbiTools.found`); `git` | `fabric-cli-policy` before any tool choice; **read-only** selective use of `fabric-tmdl` / `pbir-format` / `fabric-pipelines` **only** to understand structure when resolving conflicts or reviewing PRs — never to author |

### Tool coverage

Every installed/checked tool has a clear agent-level owner — no orphans:

| Tool | Covered by | Status |
| ---- | ---------- | ------ |
| `fab` | Agents 4, 5, 6, 7, 8, 9 | Covered |
| `az` | Agents 4, 5, 6 | Covered |
| `pbir` | Agent 7 | Covered |
| Tabular Editor CLI (`TabularEditor*.exe`) | Agent 3 | Covered |
| `pbi-tools` | Agent 9 | Covered |
| `sqlcmd` | Agents 4, 6 | Covered |
| `gh` | Agent 9 | Covered |
| Azure DevOps CLI extension (`az devops`) | Agent 9 | Covered |
| Power BI semantic-model MCP server | Agents 3, 6 | Covered |
| Fabric MCP server | Agents 4, 9 | Covered |
| `git` | Agents 2, 9 | Covered |

> **Note on `tool-status.json`:** the installer detects each tool (honoring real command
> names / aliases, e.g. Tabular Editor is `TabularEditor.exe` / `TabularEditor2.exe` /
> `TabularEditor3.exe`, not `te`) and records `found`, `version`, `command`, `path`,
> `category`, `installMode`, and a `reason` when missing. Core tools (Python, `fab`, `az`,
> the two MCP servers) are auto-installed best-effort; the specialist tools (`pbir`,
> Tabular Editor, `pbi-tools`, `sqlcmd`, `gh`, `az devops`) are **detect → explain
> provider/purpose → ask Y/N → best-effort install only on Yes**, so nothing heavy is
> installed silently.

#### Keeping the tool inventory current (auto-detection)

You don't hand-edit `tool-status.json` — it stays current automatically through three
complementary paths, so a tool you install **after** setup is picked up without fuss:

1. **Re-run the installer (update mode).** Detection runs on every run *before* the
   "previously declined" check, so a tool you installed yourself is found and flipped to
   `found: true` on the very next run — even if you'd earlier answered "No" to installing
   it. Re-running is safe (it never touches your Fabric items) and the recommended way to
   refresh the whole inventory.
2. **Ask the Skills Maintainer agent to "refresh the tool inventory".** This re-detects
   every tool live (`Get-Command` / `--version`, `code --list-extensions`,
   `az extension list`) and rewrites `tool-status.json` — a lightweight refresh with no
   full installer run. It only **detects**; it never installs (that stays opt-in).
3. **Runtime self-correction.** If the JSON is momentarily stale, a specialist agent may
   do a single live re-check (`Get-Command` / `--version`) for the one tool it needs
   before falling back — so a freshly installed tool can be used the same session.

---

## Agentic design principles

The agents aren't just prompts with a job title — they're built on a small set of
**agent-design best practices**, and every one of the nine is held to all of them. This
is what keeps the workspace effective on real (often locked-down) machines instead of
falling over the first time a tool is missing or a skill folder gets renamed upstream.

| Principle | What it means | How all nine agents apply it |
| --------- | ------------- | ---------------------------- |
| **Bounded scope, single responsibility** | One agent owns one workload; no two agents fight over the same work | Each specialist has a narrow charter; explicit handoffs (e.g. Agent 4 coordinates pipeline *execution* but hands JSON *authoring* to Agent 8; Agent 9 reviews ALM but hands artifact *design* back to Agents 3/7/8) |
| **Deterministic tool gating** | Never assume a CLI/MCP exists — check first, then use it or fall back | Every agent reads `.github/agent-docs/tool-status.json` and uses a tool only when `<key>.found` is true |
| **Graceful degradation** | A missing tool slows you down, it never blocks you | Every owned tool has a **documented fallback** (e.g. Tabular Editor → fabric-tmdl checklist; `fab` admin → portal + `az rest`; `pbir` → direct PBIR JSON edit) |
| **Minimum-necessary context (anti-soup)** | Load only what the current subtask needs, never "read all skills" | Each specialist has a "Skill loading — minimum necessary" block: identify the subtask, load its **one** skill, act |
| **Topic-based routing** | The right specialist is chosen by *task type*, never by what happens to be installed | Master routes by topic; a missing tool never changes the owner — the specialist falls back instead |
| **Deterministic startup with self-correction** | Initialization is mandatory, repeatable, and recovers from tool errors | Master runs a **mandatory init protocol** (read instructions → self-check every turn → bottom reminder) and a tool warm-up + retry with a clear VS Code-version recovery message |
| **Safety guardrails** | Irreversible actions get a confirmation; secrets never get hardcoded | Confirm-before-destructive on capacity/deploy/Git ops; IDs & secrets externalized; Agent 9 reviews others' definitions **read-only** and never force-pushes |
| **Skill precedence on conflict** | When two sources disagree, the tie-break is explicit | House style (`fabric-tmdl`) wins on *"how we do it here"*; upstream skills win on *"is this valid?"* |
| **Resilient discovery** | Don't fail just because an upstream folder moved | Cloned-repo paths are treated as **last-known hints**: list the repo root, search by keyword for the current `SKILL.md`, pick the closest match |

> **The standout: the Master's startup protocol.** The Master agent assumes the failure
> mode LLMs actually have — *skipping initialization when the user's first message already
> contains a task*. So it wraps init in three reinforcing layers: an **unconditional**
> "read these files first," a **self-check repeated before every response**, and a
> **bottom-of-prompt reminder** that explicitly names the skip-initialization tendency.
> A task in the first message is saved, setup runs to completion, and only then is the
> task answered. This is the single most important reason sessions start consistently.

These principles are deliberately enforced *inside the agent bodies* (the
[Agent → tools → skills matrix](#agent--tools--skills-matrix) above shows the per-agent
result), so they hold no matter which agent you land on.

---

## Prerequisites

Before running the installer, make sure you have:

| Tool | Required? | How to get it |
|---|---|---|
| **VS Code 1.117.0+** | Required | **You install it** — [code.visualstudio.com](https://code.visualstudio.com). The installer checks the version and **stops** if it's missing; older versions have known bugs that break Copilot agent tools. |
| **GitHub Copilot + Agent Mode** | Required | **You install it** — from the VS Code Extensions marketplace. Agent mode must be enabled (`chat.agent.enabled`). The installer does not install or check this; org tenants may need admin to enable it. |
| **Git** | Required | **You install it** — [git-scm.com](https://git-scm.com). The installer checks for Git and **stops** if it's missing; it does not install Git. |
| **[Microsoft Fabric Extension](https://marketplace.visualstudio.com/items?itemName=fabric.vscode-fabric)** | Required | **You install it** — VS Code marketplace or `code --install-extension fabric.vscode-fabric`. Required for the pull/push workflow with Fabric. The installer **checks and warns** if it's missing, but does not install it. |
| **[TMDL Extension](https://marketplace.visualstudio.com/items?itemName=analysis-services.tmdl)** | Recommended | **You install it** — `code --install-extension analysis-services.tmdl`. Syntax highlighting and validation for `.tmdl` files. The installer **checks and reminds you**, but does not install it. |
| **[Fabric Data Engineer Remote](https://marketplace.visualstudio.com/items?itemName=synapsevscode.vscode-synapse-remote)** | Nice to have | **You install it** — run notebook cells against remote Spark from VS Code. The installer mentions it as a tip but does not install it. |
| **Python 3.10–3.13** | Installer auto-installs (if needed) | **Installer installs it where possible** — only if no real Python 3 is found. It attempts Python 3.12 via winget `Python.Python.3.12 --scope user`, then the python.org 3.12.10 per-user installer. Skipped entirely if you already have Python (e.g. Anaconda). Needed only for the `fab`/`az` CLIs. [python.org](https://www.python.org) |
| **Fabric CLI (`fab`)** | Installer auto-installs (recommended) | **Installer installs it where possible** — primary CLI the agents use for Fabric API, jobs, export/import, OneLake & table ops. Once a real Python is available it runs `pip install ms-fabric-cli` with a `--user` retry. Continues if corporate policy, network, or Python/pip blocks it. [Repo](https://github.com/microsoft/fabric-cli) |
| **az CLI** | Installer auto-installs (fallback) | **Installer installs it where possible** — only needed for SQL/TDS (`sqlcmd -G`) and non-Fabric token audiences; `fab` covers the rest. Tries winget `Microsoft.AzureCLI` first, then pip / `--user` pip if Python is available. The winget path may be blocked or require elevation depending on company policy; failure is non-blocking. [Install](https://aka.ms/installazurecli) |
| **Fabric MCP server** | Installer auto-installs (full-live / hybrid) | **Installer installs it where possible** — VS Code extension `fabric.vscode-fabric-mcp-server`, giving agents structured Fabric operations (create/list items, OneLake files & tables, read item definitions). Attempts `code --install-extension ... --force`. Not needed for full-local mode. |
| **Power BI semantic-model MCP server** | Installer auto-installs (full-live / hybrid) | **Installer installs it where possible** — VS Code extension `analysis-services.powerbi-modeling-mcp`, a live XMLA connection to running models (run DAX `EVALUATE` for live comparison, make transactional model edits). Attempts `code --install-extension ... --force`. Not needed for full-local mode. |
| **`sqlcmd`** | Optional — installer detects, asks **Y/N** | Query Fabric Warehouse / SQL endpoints over TDS (Agents 4 & 6). No clean unattended install on locked-down PCs, so on **Yes** the installer points you to the manual download. [go-sqlcmd](https://aka.ms/go-sqlcmd) |
| **Tabular Editor CLI** | Optional — installer detects, asks **Y/N** | Semantic-model validation, Best Practice Analyzer, and automation (Agent 3). Detected as `TabularEditor.exe` / `TabularEditor2.exe` / `TabularEditor3.exe` (not `te`). TE2 is free, TE3 is paid; manual install on **Yes**. [tabulareditor.com](https://tabulareditor.com) |
| **`pbir` CLI** | Optional — installer detects, asks **Y/N** | Explore, edit, format, validate and publish PBIR reports (Agent 7). From data-goblin / Kurt Buhler; manual install on **Yes**. [Repo](https://github.com/data-goblin/power-bi-agentic-development) |
| **`pbi-tools`** | Optional — installer detects, asks **Y/N** | PBIP/PBIX extract-compile DevOps workflows (Agent 9). Manual install on **Yes**. [pbi.tools](https://pbi.tools) |
| **GitHub CLI (`gh`)** | Optional — installer detects, asks **Y/N** | GitHub PRs, Actions, releases and tags (Agent 9). On **Yes**, best-effort `winget install --id GitHub.cli`. [cli.github.com](https://cli.github.com) |
| **Azure DevOps CLI extension** | Optional — installer detects, asks **Y/N** | Azure DevOps PRs, pipelines and boards (Agent 9). An `az` extension (needs `az`); on **Yes**, best-effort `az extension add --name azure-devops`. |

> **Optional specialist tools are opt-in, never silent.** The six tools above power the new specialist agents (Reports, Semantic Model validation, DevOps). The installer **detects** each one, and if it's missing it **explains the tool's provider and purpose and asks Y/N** before any best-effort install — decline and it records that choice and stays quiet on later runs; accept and it installs per-user where it can or shows a manual link. Every result (present or not) is written to the tool inventory below, so the agents know what they can use and how to fall back.

> **CLIs and MCP servers — optional for full-local, required for live & hybrid.** The core full-local workflow — the Fabric extension plus agents editing local files — needs no CLI or MCP server at all. But the **full-live** and **hybrid** ways of working genuinely run on them: the agents call `fab`/`az` and the two MCP servers to read and edit the running workspace (see [Three ways of working](#three-ways-of-working)). The installer **attempts to install** Python, `fab` (recommended), `az` (fallback), and the two MCP server extensions where possible. If your environment blocks an optional install (corporate policy, no winget, no network, no Python/pip, or VS Code extension restrictions), it shows a warning for that item and continues. For a deep dive into what you can do once a CLI is installed — now a two-part catalogue covering `fab`/`az` **and** a chapter for each specialist CLI (`pbir`, Tabular Editor CLI, `pbi-tools`, `sqlcmd`, `gh`, `az devops`) — see [CLI-FUNCTIONALITIES.md](CLI-FUNCTIONALITIES.md).

---

## Quick start

> [!WARNING]
> **What the installer puts on your machine — read before running.** The installer is convenient but it is **not** just a folder creator: it also writes workspace files, clones public repositories, and attempts a small set of tool installs. Everything it touches is listed below so there are no surprises. Optional tool installs are **best-effort and non-blocking** — if your environment blocks one (corporate policy, no winget, no network, no Python/pip, or VS Code extension restrictions), the installer continues and prints what to install later. **Git and VS Code 1.117.0+ are required prerequisites; if they are missing, setup stops.**
>
> **In your chosen workspace folder, it will:**
> - Create the workspace folder and one sub-folder per Fabric workspace you choose to scaffold
> - Write or refresh installer-managed files: agent definitions (9 agents), custom skills (TMDL, Pipelines, CLI policy), Copilot instructions, `AGENTS.md`, `.gitignore`, and VS Code settings/tasks
> - Initialise a Git repository if the folder is not already a repo; create the first commit only if Git `user.name` and `user.email` are configured
> - Clone two public GitHub repositories into the folder if missing, or run `git pull --ff-only` if they already exist: [`microsoft/skills-for-fabric`](https://github.com/microsoft/skills-for-fabric) and [`data-goblin/power-bi-agentic-development`](https://github.com/data-goblin/power-bi-agentic-development). If cloning or pulling is blocked, the installer warns and continues.
>
> **On your system, software is handled in two clearly separate groups — so you know what the script attempts to install and what it only checks:**
>
> **① Attempted automatically for you** *(best-effort; failures are warnings, not setup blockers):*
> - **Python** — only if no real Python 3 executable is found. The installer attempts Python 3.12 via winget `Python.Python.3.12 --scope user`, then the official python.org Python 3.12.10 installer with per-user settings (`InstallAllUsers=0`, `PrependPath=1`, `Include_pip=1`).
> - **Fabric CLI `fab`** — only if `fab` is missing. After a real Python is available, the installer runs `python -m pip install --upgrade ms-fabric-cli`, then retries with `--user` if needed, and adds discovered Python Scripts folders to the user PATH.
> - **Azure CLI `az`** — only if `az` is missing. The installer tries winget `Microsoft.AzureCLI` first; that package may be blocked or may request elevation depending on company policy. If a real Python exists, it then tries `pip install azure-cli` and `pip install --user azure-cli`. Failure is non-blocking.
> - **Two VS Code MCP-server extensions** — only if missing and the VS Code CLI is available: `fabric.vscode-fabric-mcp-server` and `analysis-services.powerbi-modeling-mcp`, via `code --install-extension <id> --force`. These power full-live/hybrid mode; full-local mode does not need them.
>
> **② Checked only — you install these yourself** *(the script does not install them):*
> - **Fabric extension** `fabric.vscode-fabric` — required for the core pull/push file workflow. If missing, the installer shows a prominent warning and continues.
> - **TMDL extension** `analysis-services.tmdl` — recommended for `.tmdl` syntax highlighting and validation. If missing, the installer reminds you and continues.
> - **Fabric Data Engineer Remote** `synapsevscode.vscode-synapse-remote` — optional for running notebook cells against remote Spark. The installer mentions it as a tip; it does not install it.
>
> **③ Optional specialist CLIs — detected, then installed only if you say yes** *(per-tool Y/N prompt; never silent):* for each of `pbir`, **Tabular Editor CLI**, `pbi-tools`, `sqlcmd`, `gh`, and the **Azure DevOps CLI extension** (`az devops`), the installer detects whether it is already present and, if not, explains the tool's provider and purpose and asks **Y/N** before any best-effort install. Decline and it records that choice (and stays quiet on re-runs); accept and it installs per-user where it can, or prints a manual link if the install is blocked. Every result is written to `.github/agent-docs/tool-status.json`, which the agents read to decide which tool to use or how to fall back.
>
> **In short:** the installer attempts to bring the niche pieces that power CLI/live-agent scenarios (Python if needed, `fab`, `az`, and the two MCP server extensions), asks per-tool before installing the optional specialist CLIs, and never forces anything your company environment blocks. The mainstream authoring extensions remain your choice: the script checks and warns, but does not install them.
>
> **Update mode:** if you point it at an existing folder, it refreshes installer-managed files (agents, embedded skills, configs) and updates the cloned skill repositories when possible. Your Fabric item folders, workspace folders, and personal files are left untouched.

#### ⚠️⚠️⚠️ Corporate / locked-down PCs — if tools "install but aren't recognized"

On managed machines you may see optional tools (Python, `fab`, `az`, the MCP extensions) **get installed but still reported as "not found"** in the same run — often with a `pip` line ending in `exit code: -1` or a `WARNING: The script … is installed in '…\Scripts' which is not on PATH`. **This is expected, not a failure.** A freshly installed command isn't on `PATH` yet, and corporate security scanners (EDR/antivirus) add a delay or interrupt the install partway, so it finishes across a couple of runs.

The installer is **idempotent and self-healing**: on every run it refreshes `PATH` from the registry and re-scans the Python Scripts folders, so each run *recognizes what the previous run installed*. Do this, in order:

1. **Close the window and double-click the installer again — 2 to 4 times.** Each run picks up what the last one installed, so the "not found" list shrinks until it clears. (Re-running is safe: it's update mode — your files are never touched.)
2. **If an optional tool is still missing after 3–4 runs**, open the workspace in VS Code, select **1 - Fabric Workspace Master Agent** in Copilot Chat, and paste the prompt below. It covers exactly the optional tools the installer tries to install — the agent re-checks them and installs only the missing ones (per-user, no admin). *(Required tools — Git, VS Code, the Fabric extension — and the recommended TMDL extension you install yourself; see the table above.)*

```text
Please finish setting up this Fabric agentic workspace. The one-click installer already
tried to install a small set of OPTIONAL tools for me, but one or more may have failed on
this corporate PC. Check ONLY the tools listed below, tell me which are present vs missing,
then install ONLY the missing ones. Prefer per-user, no-admin installs and never force
anything that needs elevation.

  1. Python 3.10-3.13 (only if no real Python exists) -> winget install Python.Python.3.12 --scope user
  2. Fabric CLI "fab"            -> python -m pip install --user ms-fabric-cli
  3. Azure CLI "az" (fallback)   -> python -m pip install --user azure-cli
  4. Fabric MCP server           -> code --install-extension fabric.vscode-fabric-mcp-server
  5. Power BI model MCP server   -> code --install-extension analysis-services.powerbi-modeling-mcp

For the Python packages, add the user Scripts folder to PATH if needed, then verify each
tool resolves (run: fab --version, az version). Finish with a clear checklist of what is
now installed and what still needs manual or IT action. Do not run anything destructive.
```

> During its prerequisite step the installer shows each tool's status and a plain warning for anything optional it couldn't install — it does **not** print this prompt. Use the steps above if an optional tool is still missing. None of these optional tools block setup: the full-local workflow runs fine without them.

**Specialist CLIs (`pbir`, Tabular Editor CLI, `pbi-tools`, `sqlcmd`, `gh`, `az devops`) — if you declined them, or one failed.** These are the **opt-in** tools the installer asks about one at a time. Unlike the core tools above, they are **never installed silently** — so if you pressed **N**, or said **Y** but the install was blocked on your locked-down PC, the workspace simply records them as "not found" in `tool-status.json` and the owning agent falls back. You don't have to fix anything for the core workflow. When you *do* want one later — say `pbir` for report editing or `sqlcmd` for SQL queries — open the workspace, select **1 - Fabric Workspace Master Agent**, and paste the prompt below for just the tools you want. (The agent installs only what you list, per-user, then refreshes `tool-status.json` so every agent immediately knows the tool is available.)

```text
Please install the OPTIONAL specialist CLIs I list below for this Fabric agentic
workspace, then refresh the tool inventory. These are opt-in tools I either declined
or that failed to install on this corporate PC. Check each one first, tell me which are
present vs missing, then install ONLY the missing ones I asked for. Prefer per-user,
no-admin installs; if one genuinely needs a manual download (e.g. sqlcmd) or admin
rights, give me the official link instead of forcing it.

  - pbir              (Power BI report CLI, Agent 7)   -> provider: data-goblin pbir-cli
  - Tabular Editor CLI (semantic-model BPA/deploy, Agent 3) -> https://docs.tabulareditor.com
  - pbi-tools         (PBIX/PBIP source control, Agent 9) -> https://pbi.tools
  - sqlcmd            (T-SQL over Fabric SQL, Agents 4 & 6) -> https://aka.ms/go-sqlcmd
  - gh                (GitHub CLI, Agent 9)            -> https://cli.github.com
  - az devops         (Azure DevOps CLI, Agent 9)      -> az extension add --name azure-devops

After installing, update .github/agent-docs/tool-status.json so each tool's "found" flag
reflects reality (you can also just re-run the one-click installer, which re-detects them).
Finish with a checklist of what is now available and what still needs manual or IT action.
Do not run anything destructive.
```

> Tip: simply **re-running the one-click installer** also picks up any specialist CLI you installed yourself — detection runs *before* the "previously declined" check, so a tool that's now present flips to `found: true` automatically, even if you said N the first time.

### 1. Get the files

You need **two files** — keep them in the same folder (ideally as they are in the [fabric-agentic-installer](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/tree/main/fabric-agentic-installer) folder):

```
Setup-FabricAgenticWorkspace.bat    ← double-click this
Setup-FabricAgenticWorkspace.ps1    ← the engine (called by the .bat)
```

### 2. Run the installer

**Double-click `Setup-FabricAgenticWorkspace.bat`.**

You'll see a terminal window:

```
===============================================
 Fabric Agentic Workspace — One-click Setup
===============================================

  Do you already have a local folder where you work with Fabric?
  (e.g. where you sync your Semantic Models, Notebooks, Pipelines)

  [1] Yes — I have an existing folder (I will provide the path)
  [2] No  — Create a new folder for me

  Enter 1 or 2: _
```

Follow the prompts. The script will:

1. Ask for your workspace folder (existing or new)
2. Explain the Fabric development lifecycle and the three ways of working
3. Ask how many Fabric workspaces to scaffold
4. Check all prerequisites (git, VS Code, Fabric extension, TMDL extension), automatically install Python, the `fab`/`az` CLIs, and the two MCP extensions where possible, then detect the optional specialist CLIs (`pbir`, Tabular Editor, `pbi-tools`, `sqlcmd`, `gh`, `az devops`) and ask Y/N before installing any of them. It then offers an optional `y/N` check for newer versions of the tools you already have installed (per-tool Y/N; blocked/offline lookups are skipped)
5. Create the folder structure
6. Clone Microsoft's skills-for-fabric and data-goblin's power-bi-agentic-development
7. Write custom skills (TMDL, Pipelines, CLI policy)
8. Generate all agent definitions (9 agents)
9. Write configuration files (Copilot instructions, AGENTS.md, .gitignore, VS Code settings, and the `tool-status.json` tool inventory)
10. Initialise a git repo with the first commit
11. Open the workspace in VS Code

### 3. Start working

Once VS Code opens:

1. Open **Copilot Chat** (sidebar or `Ctrl+Shift+I`)
2. Select **1 - Fabric Workspace Master Agent** from the agent dropdown
3. In a blank chat type a greeting (e.g., Hi agent!) — the agent takes over from here

On first message the agent will:
- Check when each skill source was last updated
- Offer to run skill maintenance (light or deep)
- Check your identity (`fab auth status`, falling back to `az account show`)
- Present a topic menu to route you to the right specialist

### 4. Keeping it up to date

When a new version is released, updating is the same one step as installing:

1. [Download the latest installer files](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/tree/main/fabric-agentic-installer)
2. **Double-click `Setup-FabricAgenticWorkspace.bat`** and point to the **same folder** you used originally
3. The installer detects the existing folder and switches to **update mode** — it refreshes agent definitions, custom skills, Copilot instructions, and VS Code configs, then pulls the latest skill repositories
4. It also offers an optional per-tool version check — answer **Y** at the `Check installed tools for updates now?` prompt and it upgrades any installed CLI/tool that's behind (best-effort; anything blocked on a locked-down network is skipped)
5. Your Fabric items, workspace folders, and any personal files are **not touched**

That's it. Reopen the workspace in VS Code and you're on the latest version.

---

## What the agents can do

### Guided session startup

You don't configure anything manually. On your **first message** each session, the master agent is instructed to:

1. **Check skill freshness** — show when each skill source was last updated locally
2. **Offer maintenance** — optionally switch to the Skills Maintainer for a light or deep update
3. **Check identity** — run `fab auth status` (falling back to `az account show`) to verify your login
4. **Present topic selection** — route you to the specialist agent for your task

### Specialist agents

Once routed, each specialist handles its domain with a bounded tool set and selective skill loading. For the full breakdown — capabilities, owned CLIs/MCP servers, and which skills each agent reads — see the [Agent → tools → skills matrix](#agent--tools--skills-matrix) above.

### Skill-based development

Every specialist agent reads the relevant skill files **before** generating any code or edits. Skills provide:

- **Exact syntax rules** — TMDL indentation (tabs only), property ordering, lineageTag handling
- **Activity type references** — every pipeline activity with its typeProperties
- **Best practices** — DAX conventions, naming patterns, validation checklists
- **File structure knowledge** — where things go in a Fabric PBIP project

The skills come from three sources:

| Source | What it covers | Updated |
|---|---|---|
| **Custom embedded** (`.github/skills/`) | TMDL syntax, pipeline JSON, CLI policy — original to this repo | Re-run installer or edit directly |
| **Microsoft** (`skills-for-fabric/`) | Spark, SQL, Eventhouse, medallion, CLI | Offered on session start / via Skills Maintainer |
| **Data-goblin** — [Kurt Buhler](https://www.linkedin.com/in/kurtbuhler/) (`power-bi-agentic-development/`) | PBIP, DAX, reports, Fabric CLI/admin | Offered on session start / via Skills Maintainer |

> **Why git clone instead of npm install?** Corporate environments typically
> block npm global installs and require admin approval. This workspace clones
> the skills repos via git — which you already have — so there's zero extra
> tooling or permissions needed.

---

## Workspace structure

After setup, your folder looks like this:

```
Fabric Workspaces/
├── .git/
├── .github/
│   ├── agents/
│   │   ├── 1-fabric-workspace-master-agent.agent.md   ← routing hub
│   │   ├── 2-fabric-skills-maintainer.agent.md        ← skill maintenance
│   │   ├── 3-semantic-model-agent.agent.md            ← TMDL & DAX
│   │   ├── 4-fabric-data-engineer.agent.md            ← Spark, SQL, pipelines
│   │   ├── 5-fabric-admin.agent.md                    ← governance & capacity
│   │   ├── 6-fabric-app-dev.agent.md                  ← apps & integrations
│   │   ├── 7-fabric-reports-agent.agent.md            ← PBIR reports
│   │   ├── 8-fabric-pipelines-agent.agent.md          ← pipeline JSON
│   │   └── 9-fabric-devops-agent.agent.md             ← ALM / Git / DevOps
│   ├── agent-docs/
│   │   ├── starting-flow.md                           ← session startup phases
│   │   ├── working-flow-reference.md                  ← skill discovery table
│   │   └── tool-status.json                           ← tool inventory (gitignored)
│   ├── copilot-instructions.md                        ← workspace-level context
│   └── skills/
│       ├── fabric-tmdl/
│       │   └── SKILL.md                               ← TMDL syntax & rules
│       ├── fabric-pipelines/
│       │   └── SKILL.md                               ← pipeline activity reference
│       └── fabric-cli-policy/
│           └── SKILL.md                               ← fab-first / az-fallback policy
├── .gitignore
├── .vscode/
│   ├── settings.json
│   └── tasks.json
├── AGENTS.md                                          ← quick-reference guide
├── skills-for-fabric/                                 ← Microsoft skills (gitignored)
│   ├── skills/
│   └── common/
├── power-bi-agentic-development/                      ← data-goblin skills (gitignored)
│   └── plugins/
└── <Your Workspace Folders>/                          ← Fabric items synced here
```

Fabric items are synced into workspace sub-folders via the Fabric VS Code
extension. In the default **file-first** mode the agents edit those local files
— TMDL, DAX, pipeline JSON, notebooks — and you push changes back via the
extension; in **full-live** or **hybrid** mode they can also act on the running
workspace directly (REST/XMLA + MCP). See [Three ways of working](#three-ways-of-working).

---

## How it works under the hood

The setup script (`Setup-FabricAgenticWorkspace.ps1`) is fully self-contained.
Every agent definition, custom skill, and config file is embedded directly in
the script — no external templates, no internet dependencies for its own content.
The only things it brings in from outside are the two public skill repositories
(via `git clone`) and the tools it installs on your machine — all of which are
listed in the [install warning above](#quick-start).

The `.bat` wrapper exists solely to bypass Windows PowerShell execution policy
restrictions. It calls the `.ps1` with `-ExecutionPolicy Bypass` so the script
runs regardless of your organisation's policy settings.

The script supports **update mode** — if you run it against an existing folder, it
overwrites all installation-managed files (agent definitions, custom skills, configs)
with the latest versions while leaving your Fabric items, workspace folders, and
personal files completely untouched.

### The Fabric development lifecycle (the backbone)

Everything in this workspace sits on top of one lifecycle. It's the **shared backbone for all [three ways of working](#three-ways-of-working)** — only the *editing* step differs between them; everything from the DEV workspace onward is identical. The lifecycle uses Fabric's native Git integration plus Azure DevOps to take a change safely from idea to production.

<p align="center">
  <img src="assets/fabric-git-workflow.png" alt="Fabric development lifecycle — edit the DEV workspace (3 ways) → commit to Azure DevOps → PR → Azure DevOps PROD → sync → Fabric PROD" width="100%"/>
</p>

**The lifecycle, end to end:**

1. **Fabric DEV workspace** — your live testing ground. However you make a change (see the three ways below), it lands here first and you validate it in the portal.
2. **Commit to Azure DevOps — DEV branch** — in the Fabric portal, go to *Workspace Settings → Git Integration* and commit. This is your versioned safety net: **revert to any previous commit at any time** (it undoes both VS Code and portal changes).
3. **Pull Request: DEV → PROD branch** — when the DEV branch is stable and tested, open a PR in Azure DevOps to promote the changes.
4. **PROD-branch overrides** — the PROD branch holds prod-specific parameters (pipeline schedules turned ON, production connection endpoints, semantic-model parameters). These **persist across merges**, so each new PR brings only the item-logic changes without resetting production configuration.
5. **Sync to the Fabric PROD workspace** — after the PR is approved and merged, sync the PROD branch via Git Integration. Production is now updated.

**Shared safety anchor:** Fabric Git commits capture the validated DEV workspace state. You can review history and revert DEV when needed; PROD is updated only through a deliberate PR + sync.

### A bit of history: how Fabric/Power BI work used to flow

Before the Fabric VS Code extension and AI agents, there were really two places to build — and neither was friendly to source control:

- **In the workspace/portal itself.** The Fabric workspace (and before it, the Power BI Service) *was* the main working place. You created and edited items online, and versioning was largely manual — saving copies, exporting, hoping you could find the last good state.
- **In Power BI Desktop, then publish.** Semantic models and reports were authored locally in **Power BI Desktop** (`.pbix`) and **published** up to the workspace. The `.pbix` was a binary blob: hard to diff, hard to review, awkward to keep in Git.

Two changes opened things up:

- **Fabric Git integration** started exposing item definitions as readable files — TMDL for semantic models, JSON for pipelines, source for notebooks — so a workspace could be backed by Azure DevOps / GitHub with real history.
- **The Fabric VS Code extension** let you **pull** those definitions into a local folder and **push** them back — proper file-based editing and source control.

This workspace uses the final layer: **AI agents** that natively understand TMDL, DAX, pipeline JSON, notebooks, and more — and that can edit either the local files *or* the running workspace directly. That's what makes the three ways of working below possible.

### Three ways of working

You now have **three ways** to make changes to your Fabric DEV environment.
They all share the same promotion path: validate in DEV, commit the workspace
state through Fabric Git integration, review via PR, and sync PROD deliberately.
That shared lifecycle is the safety anchor. Live and hybrid work still require
normal engineering discipline: review the generated changes, test in the portal,
and keep local files aligned with the live workspace.

#### A — Full local (file-first — the default)

Edit Fabric items as files on disk, then push them back. Best for bulk/structured edits, diff-style review, and offline work. **Needs only the Fabric extension + Git.**

1. **Pull** items from your DEV workspace into the local folder using the Fabric extension — semantic models (TMDL), notebooks, pipelines (JSON), reports.
2. **Edit locally** with the AI agents or by hand. The agents understand TMDL, DAX, pipeline JSON, and notebook formats natively, so you can refactor measures, fix pipeline logic, restructure models, etc.
3. **Push** the changes back to the DEV workspace via the Fabric extension — they go live in DEV immediately.
4. **Test in the Fabric portal**, making any manual portal amendments if needed, then commit to Azure DevOps (lifecycle step 2 above).

<p align="center">
  <img src="assets/workflow-mode-local.png" alt="Mode A — Full Local: VS Code local files ↔ Fabric DEV via the Fabric extension, committed to Azure DevOps, promoted to PROD" width="100%"/>
</p>

#### B — Full live (in-workspace — no local round-trip)

Agents act directly on the running DEV workspace, with no files pulled down. Best for **live data comparison**, reading real deployed values, and quick in-place fixes. **Needs the Fabric MCP server + Power BI semantic-model MCP server, plus `fab`/`az`.**

1. The agents connect to the live workspace via **Fabric REST** (`updateDefinition`) and the two **MCP servers**.
2. **Run DAX** (`EVALUATE`) on running models to compare data live — for example, check a measure's result after a logic change, or run the exact queries behind a report's visuals in **both DEV and PROD** to confirm a model change didn't break them. You can also run **SQL** against a Lakehouse or SQL database endpoint, and **read real deployed GUIDs / SQL endpoints** instead of guessing.
3. **Edit definitions in place** and **create items** directly in the workspace.
4. **Test in the portal**, then commit to Azure DevOps as usual (lifecycle step 2).

<p align="center">
  <img src="assets/workflow-mode-live.png" alt="Mode B — Full Live: VS Code agents read/write the live Fabric DEV workspace via REST, XMLA and MCP, committed to Azure DevOps, promoted to PROD" width="100%"/>
</p>

#### C — Hybrid (local + live)

Mix both in one session — some items edited as local files, others touched live. Best for real tasks that naturally span both edit paths. **Needs the local toolset (Fabric extension + Git) and the live toolset (MCP + `fab`/`az`).**

1. **Pull only what you need** locally — just the items you'll edit as files.
2. Do your **mixed work**: file edits for some items, live REST/XMLA/MCP for others. Both edit paths converge on the same DEV workspace and the same commit.
3. **Before starting a new job, re-pull from the live workspace (or clean up local)** so your local folder matches live again.

> **Golden rule — keep local = live workspace.** Each session, pull locally **only** the items you need, do your work, then **re-pull (or clean up local) before a new job** so your local folder exactly matches live and you avoid drift.

<p align="center">
  <img src="assets/workflow-mode-hybrid.png" alt="Mode C — Hybrid: VS Code local files and live tools both converge on Fabric DEV, committed to Azure DevOps, promoted to PROD, with a keep-local-equals-live golden rule" width="100%"/>
</p>

---

## FAQ

**Q: Can I move the workspace folder after creation?**
A: Yes. The workspace is fully portable. Just open the new location in VS Code.

**Q: What if I don't have the Fabric extension installed?**
A: The installer will warn you prominently but still create everything. Install
the extension before using the pull/push workflow with Fabric.

**Q: Does this work on macOS or Linux?**
A: The setup script is Windows-only (PowerShell + .bat). However, the
workspace itself — including all agents and skills — works on any OS once the
files exist. You'd just need to create the folder structure manually or adapt
the script.

**Q: Why does this clone skills via git instead of installing them?**
A: Cloning via git — which you already have as a prerequisite — sidesteps the npm global installs that typically need admin rights or IT approval on corporate machines.

**Q: Can I add my own specialist agents?**
A: Absolutely. Create a new `.agent.md` file in `.github/agents/` and it will
appear in the Copilot Chat dropdown. Follow the existing agent structure.

**Q: How do I update the skills?**
A: The master agent offers skill maintenance at session start. You can also
select the Skills Maintainer directly for light (git pull + tool-inventory
refresh) or deep (pull + freshness check + unreferenced scan + tool-inventory
refresh) maintenance.

**Q: Can multiple people share the same workspace via git?**
A: Yes. Push the workspace to a shared repo. Each team member clones it,
selects the Master Agent, and connects to their own Fabric environment.
The `.gitignore` keeps skill repos and VS Code settings clean.

**Q: Do I have to edit local files, or can the agents work live in the workspace?**
A: Both. There are [three ways of working](#three-ways-of-working) — full local
(file-first), full live (agents act on the running DEV workspace via REST/XMLA +
MCP), and hybrid. They share the same DEV-to-PROD promotion lifecycle, but live
and hybrid work still need review, portal testing, and drift discipline. For
hybrid, follow the golden rule: re-pull (or clean up local) before a new job so
local = live workspace.

**Q: What do I need for full-live / hybrid mode?**
A: The two MCP servers (Fabric MCP + Power BI semantic-model MCP), plus `fab`/`az`.
They are VS Code extensions (`fabric.vscode-fabric-mcp-server` and
`analysis-services.powerbi-modeling-mcp`) that the installer auto-installs for you,
alongside `fab`/`az`. Full-local mode needs none of these.

**Q: What are the optional specialist CLIs, and what happens if I don't install one?**
A: They are the workload-specific tools individual agents can use — `pbir` (reports),
Tabular Editor CLI (semantic-model BPA/deploy), `pbi-tools` (PBIX/PBIP source control),
`sqlcmd` (T-SQL over the Fabric SQL endpoint), `gh` (GitHub) and `az devops` (Azure
DevOps). The installer asks **Y/N** per tool — none is installed silently. If a tool is
missing (you declined, or the install was blocked), nothing breaks: the owning agent
sees `found: false` in `tool-status.json` and uses a documented fallback. You can add any
of them later — the **Corporate / locked-down PCs** steps under [Quick start](#quick-start)
include a ready-to-paste agent prompt for exactly these specialist CLIs.
See [CLI-FUNCTIONALITIES.md](CLI-FUNCTIONALITIES.md) for a per-CLI deep dive.

**Q: How does the workspace know which tools I have installed?**
A: The installer writes `.github/agent-docs/tool-status.json` — a gitignored, machine-specific inventory. Agents read `<tool>.found` before invoking any CLI/MCP and fall back when absent. For how it stays current (re-run, Skills Maintainer, runtime re-check), see [Keeping the tool inventory current](#keeping-the-tool-inventory-current-auto-detection).

---

## Current status (v0.5.0-pre-release)

| Area | Status |
|---|---|
| One-click setup (.bat + .ps1) | **Battle-tested manually** — used by the maintainer on Windows 10/11, including a locked-down corporate laptop |
| Master Agent session startup flow | **Implemented as agent instructions** — skill freshness, `fab`/`az` identity, topic routing, advisory specialist recommendations |
| Specialist agent routing | **Implemented and used regularly** — all 7 specialist agents are configured with dynamic skill discovery for upstream repo restructuring |
| Agent → tools → skills model | **Implemented (new in v0.5.0)** — each agent owns a bounded, deterministic toolset and loads only the skills its subtask needs; documented in the README agent/tool matrix and coverage table |
| Tool inventory (`tool-status.json`) | **Implemented (new in v0.5.0)** — installer detects every tool (real aliases) and writes a gitignored, machine-specific inventory; agents read `<tool>.found` and fall back when absent; Skills Maintainer can refresh it (detect-only) |
| Opt-in specialist CLIs | **Implemented (new in v0.5.0)** — `pbir`, Tabular Editor CLI, `pbi-tools`, `sqlcmd`, `gh`, `az devops` are detect → explain → Y/N → best-effort install; never silent; declined choices remembered |
| Fabric DevOps Agent (Agent 9) | **Implemented (new in v0.5.0)** — ALM coordination (Git Integration, Deployment Pipelines, Azure DevOps & GitHub); reads artifact skills read-only for conflict/PR review, does not author artifacts |
| Skills Maintainer (light + deep) | **Implemented as agent workflow** — pull, MS-docs freshness check, unreferenced scan, tool-inventory refresh |
| Custom TMDL skill | **Used in real work** — comprehensive syntax and validation rules, maintained from practical modelling experience |
| Custom Pipelines skill | **Used in real work** — activity reference plus operational practices from production pipeline work |
| Custom CLI-policy skill | **Used in real work** — `fab`-first / `az`-fallback decision rule that every agent reads before a CLI/REST task |
| CLI deep-dive (`CLI-FUNCTIONALITIES.md`) | **Expanded (new in v0.5.0)** — two-part mini-book: `fab`/`az` workload guide plus a chapter per specialist CLI |
| Three ways of working (local / live / hybrid) | **Documented and maintainer-used** — diagrams, installer guidance, and soft MCP checks; still requires human review/testing |
| Microsoft skills-for-fabric integration | **Implemented** — cloned and updated locally when network/Git access allows |
| Data-goblin skills integration | **Implemented** — cloned and updated locally when network/Git access allows |
| Idempotent re-run (update mode) | **Implemented** — managed files refreshed, user files untouched |
| Custom `fabric-devops-policy` skill | **Planned** — will capture the maintainer's DEV→PROD promotion workflow (branch/PR discipline, rollback patterns); Agent 9 uses `fabric-cli-policy` + selective artifact-skill reads for now |
| Automated regression tests | **Not yet** — validation is currently manual and experience-based |

This is a pre-release. It is genuinely useful today, but expect rough edges. If something breaks, [open an issue](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/issues).

---

## Contributing

This project is open source and actively looking for feedback, ideas, and
improvements from the community. All contributions are welcome — from typo
fixes to new agent workflows to cross-platform support.

See **[CONTRIBUTING.md](CONTRIBUTING.md)** for the full guide — how to set up,
branch naming, commit style, and PR expectations.

Quick links:
- [Report a bug](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/issues/new?template=bug_report.yml)
- [Request a feature](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/issues/new?template=feature_request.yml)
- [Open issues](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/issues)

---

## Files in this repository

| File | Purpose |
|---|---|
| `fabric-agentic-installer/Setup-FabricAgenticWorkspace.bat` | Double-click entry point — share this with your team |
| `fabric-agentic-installer/Setup-FabricAgenticWorkspace.ps1` | The full installer — must be in the same folder as the .bat |
| `CHANGELOG.md` | Version history and release notes |
| `CONTRIBUTING.md` | Guide for contributors |
| `CODE_OF_CONDUCT.md` | Community standards |
| `SECURITY.md` | How to report security vulnerabilities |
| `LICENSE` | MIT License |
| `README.md` | This file |

---

## License

This project is licensed under the MIT License — see the [LICENSE](https://github.com/SteCiu01/Fabric-Agentic-Workspace-One-Click-Setup/blob/main/LICENSE) file for details.

## Third-party notices

This project integrates and references third-party open-source skill repositories
that remain the property of their respective authors and are licensed separately.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution,
repository links, and license information.
