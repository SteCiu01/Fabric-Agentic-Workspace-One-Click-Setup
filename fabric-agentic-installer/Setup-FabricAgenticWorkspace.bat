@echo off
title Fabric Agentic Workspace Setup v0.9.0
echo.
echo  ===============================================
echo   Fabric Agentic Workspace -- One-click Setup v0.9.0
echo  ===============================================
echo.
:: -ExecutionPolicy Bypass is required because many organisations restrict
:: PowerShell script execution by default (e.g. AllSigned or Restricted).
:: This flag applies only to this single process -- it does not change the
:: machine-wide or user-level policy. Once the window closes, the override
:: is gone. The .ps1 script is fully readable and open source.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-FabricAgenticWorkspace.ps1"
set "SETUP_EXIT=%ERRORLEVEL%"
echo.
:: A window that only shows the banner used to look like a finished setup.
if not "%SETUP_EXIT%"=="0" echo  Setup did NOT complete: exit code %SETUP_EXIT%.
if not "%SETUP_EXIT%"=="0" echo  If no setup text appeared above, Windows PowerShell could not be started from this window
if not "%SETUP_EXIT%"=="0" echo  and nothing was installed or changed.
if not "%SETUP_EXIT%"=="0" echo.
pause
exit /b %SETUP_EXIT%
