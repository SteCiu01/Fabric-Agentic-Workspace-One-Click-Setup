# Agent organisation diagram — source

Editable source of [`assets/agent-organisation.png`](../agent-organisation.png), the hierarchy shown in [README §3.4](../../README.md#34-the-agent-organisation).

| File | Purpose |
|---|---|
| `agent-organisation.html` | The diagram: plain HTML and CSS, no external resources |
| `Render-AgentOrganisation.ps1` | Renders the HTML to PNG with a locally installed browser |

## Regenerate

From the repository root, in Windows PowerShell 5.1 or PowerShell 7:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File assets/agent-organisation-source/Render-AgentOrganisation.ps1
```

This overwrites `assets/agent-organisation.png` (2000 × 2468 px for the current content). To preview without touching the published image, add `-OutFile "$env:TEMP\agent-organisation.preview.png"`.

**Requirements:** Windows with Microsoft Edge (or Google Chrome; pass `-Browser <path>` for another location). The design uses the Segoe UI Variable fonts of Windows 11; other systems fall back to Segoe UI or a system font and render slightly different line widths. Nothing is installed or downloaded: the script starts the browser headless with a throw-away profile in `%TEMP%` and deletes it afterwards.

**GitHub Copilot icon:** the Master card shows the GitHub Copilot icon, a third-party trademark that is not stored in this repository. The script takes it from the local VS Code installation (`resources/app/extensions/copilot/assets/copilot.png`), or from `-CopilotIcon <path>`. Without it, a neutral placeholder is drawn and a warning is printed. Do not commit the icon file.

## Maintain

- **Labels mirror the installer manifest** (`fabric-agentic-installer/Setup-FabricAgenticWorkspace.ps1`): each worker's `displayName` without the `Agent` suffix, grouped under its `parent` Team Lead, in file-number order. PBIVIZ workers also drop the `PBIVIZ` prefix.
- **No numeric prefixes** (000, 010, 081 …) in any label.
- When a worker is added, removed or moved, update its `<li>`, the team's `N specialists` count and, if the total changes, the `43 delegated specialists` pill and README §3.4.
- Keep Team Leads 1–4 in the left column and 5–8 in the right column. The page height is measured automatically, so the PNG grows or shrinks with the content.
- Open `agent-organisation.html` in a browser for a quick preview (it shows the placeholder icon), render, then check the PNG in README §3.4 before committing.
