  git: found
  VS Code: 1.123.0
  Fabric Extension: found
  TMDL Extension: not found (recommended)
         Provides syntax highlighting and validation for .tmdl files.
         This workspace works heavily with Semantic Model TMDL definitions.
         Install via: code --install-extension analysis-services.tmdl
  Fabric CLI (fab): not found (recommended)
         Primary CLI for Fabric API, jobs, export/import, OneLake and table ops.
         Needs Python 3.10-3.13. Reference: https://github.com/microsoft/fabric-cli
         No real Python found -- attempting to install Python 3.12 (required by the Fabric CLI)...
         Trying winget: Python.Python.3.12 ...
         Python installed (via winget).
    Installing Fabric CLI (fab) automatically...
    Trying: py -m pip install --user ms-fabric-cli ...
    That method did not succeed (exit code: -1).
        WARNING: The script jsonpath_ng.exe is installed in 'C:\Users\stefa\AppData\Roaming\Python\Python312\Scripts' which is not on PATH.
    Trying next method if available...
    Likely causes: corporate security policy blocking installs, no real Python/pip or winget, or no network access.
    Install it later when convenient -- either manually (https://github.com/microsoft/fabric-cli (pip install ms-fabric-cli)),
    or just open the workspace and ask the Fabric agent to walk you through it.
    Continuing without Fabric CLI (fab) (the workspace works fine without it).
  az CLI: found

  All prerequisites OK.

  Press Enter to continue...: