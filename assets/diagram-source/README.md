# README diagrams — source

Editable sources of the diagrams in the [README](../../README.md). Each `.html` file here renders to the `.png` of the same name in [`assets/`](..).

| Source | Image | Shown in |
|---|---|---|
| `architecture-overview.html` | `assets/architecture-overview.png` | Top of the README |
| `workflow-mode-local.html` | `assets/workflow-mode-local.png` | [2.2](../../README.md#22-three-ways-of-working), mode A |
| `workflow-mode-live.html` | `assets/workflow-mode-live.png` | [2.2](../../README.md#22-three-ways-of-working), mode B |
| `workflow-mode-hybrid.html` | `assets/workflow-mode-hybrid.png` | [2.2](../../README.md#22-three-ways-of-working), mode C |
| `fabric-git-workflow.html` | `assets/fabric-git-workflow.png` | [2.3](../../README.md#23-the-fabric-development-lifecycle) |
| `diagram.css` | — | Shared style of all five |
| `Render-Diagrams.ps1` | — | Renders the HTML to PNG with a locally installed browser |

The agent organisation diagram ([3.4](../../README.md#34-the-agent-organisation)) has the same style and its own folder: [`agent-organisation-source`](../agent-organisation-source/README.md).

## Regenerate

From the repository root, in Windows PowerShell 5.1 or PowerShell 7:

```powershell
# every diagram
powershell -NoProfile -ExecutionPolicy Bypass -File assets/diagram-source/Render-Diagrams.ps1

# one diagram, as a preview that leaves the published image alone
powershell -NoProfile -ExecutionPolicy Bypass -File assets/diagram-source/Render-Diagrams.ps1 -Name workflow-mode-live -OutDir $env:TEMP
```

Every image is 2000 px wide (a 1000 px page at 2x); the height follows the content.

**Requirements:** Windows with Microsoft Edge (or Google Chrome; pass `-Browser <path>` for another location). The design uses the Segoe UI Variable fonts of Windows 11; other systems fall back to Segoe UI or a system font and render slightly different line widths. Nothing is installed or downloaded: the script starts the browser headless with a throw-away profile in `%TEMP%` and deletes it afterwards.

**GitHub Copilot icon:** the teal agent card shows the GitHub Copilot icon, a third-party trademark that is not stored in this repository. The script takes it from the local VS Code installation (`resources/app/extensions/copilot/assets/copilot.png`), or from `-CopilotIcon <path>`. Without it, a neutral placeholder is drawn and a warning is printed. Do not commit the icon file. No other third-party logo is used.

## Maintain

- **Figures mirror the installer** (`fabric-agentic-installer/Setup-FabricAgenticWorkspace.ps1`). When one changes, change it here and in the README text together:
  - agents: 54 = 3 executives + 8 Team Leads + 43 specialists, and the specialists per Team Lead;
  - custom skills: 11 = 5 for Fabric + 6 for PBIVIZ;
  - tools: 2 recommended CLIs and 6 specialist CLIs, as offered in installer Step 2 and listed in README 2.4;
  - MCP: 5 supported integrations = 2 optional VS Code extensions (Step 2), 1 Microsoft Learn entry configured automatically and 2 Microsoft-hosted data servers (Fabric IQ, Fabric Data Warehouse) configured only on a Yes (Step 8). Keep the line that *supported* does not mean installed, signed in or callable.
- **Texts mirror README 2.2 and 2.3.** The diagrams add no capability the README does not describe. `DEV` and `PROD` are illustrative names.
- **One style.** Colours, type and card shapes live in `diagram.css` and match the agent organisation diagram. Change the style there, not in one page.
- Open an `.html` file in a browser for a quick preview (it shows the placeholder icon), render, then check the PNG in the README before committing.
