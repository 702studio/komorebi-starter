# Agent Integration Guide

This document details command-line outputs, recovery protocols, and verification guidelines for automated integrations.

## Machine Contract

Read [`agent-manifest.json`](agent-manifest.json) before installation. After installation, the same contract is available at `%LOCALAPPDATA%\Programs\KomorebiStarter\agent-manifest.json`.

Install the latest verified release non-interactively:

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/702studio/komorebi-starter/main/bootstrap.ps1'))) -Version latest -NonInteractive -Quiet -Json
```

Replace `latest` with an immutable tag such as `v0.3.0` when reproducibility is required. Add `-WhatIf` for a plan, `-MigrateFromGlazeWM` for explicit takeover, or `-InstallFonts` for the optional font. Do not use `-Force` unless foreign or user-edited target files have been reviewed and backed up.

Check for the WinGet package before selecting that route:

```powershell
winget show --exact --id 702studio.KomorebiStarter
```

If discovery succeeds, an unattended agent may install it with:

```powershell
winget install --exact --id 702studio.KomorebiStarter --silent --disable-interactivity --accept-package-agreements --accept-source-agreements
```

If discovery fails, use the remote bootstrap command. Do not infer that a prepared or submitted community manifest is already available in the catalog.

## Command Output Contract
- **Stdout**: `wm state`, `wm global-state`, and `wm visible` return raw upstream JSON. `wm query` returns raw upstream output. Successful `wm` mutations return small JSON envelopes. `install.ps1`, `restore.ps1`, and `uninstall.ps1` provide JSON stdout only when invoked with the `-Json` switch.
- **Stderr**: Diagnostic steps and logs.
- **Exit Codes**: `0` on success, non-zero on failure. Errors may include plain text on `stderr` or throw exceptions in PowerShell.

## State Verification Flow
Agents must follow the structured preflight, execution, and verification flow outlined in the [Preflight, Diagnostics, and Recovery Flow](#preflight-diagnostics-and-recovery-flow) section.

## Safe Operations

### Installation
Run a non-interactive local dry-run to verify the execution plan without network requests or system mutation:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Preset Minimal -WhatIf -NonInteractive -Quiet -Json
```
Run a non-interactive installation:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Preset Minimal -NonInteractive -Json
```

### Diagnostics
Retrieve environment checks, process states, and path resolutions:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1 -Json
```

### Rollback
Perform a clean uninstallation and preserve configurations:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -Quiet -Json
```

Perform a clean uninstallation removing configurations:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveConfig -Force -Quiet -Json
```

Restore from a backup:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\restore.ps1 -Quiet -Json
```

## CLI Wrapper (`wm.ps1`)
The CLI wrapper (`wm.cmd` -> `wm.ps1`) manages execution. It guarantees non-interactive execution and normalizes Komorebi operations.

### Commands
- `wm state`: Returns the raw upstream Komorebi state JSON.
- `wm global-state`: Returns the global state JSON.
- `wm visible`: Returns the visible windows JSON.
- `wm query <state-query>`: Returns raw upstream query output.
- `wm focus <left|right|up|down>`: Verifies the actual Win32 foreground root and returns nonzero if bounded activation repair fails.
- `wm focus-health`: Read-only comparison of Komorebi focus, foreground root, keyboard-focus child, mouse-under root, and modal activation target.
- `wm move <left|right|up|down>`
- `wm workspace <name>`
- `wm send <workspace-name>`
- `wm move-and-follow <workspace-name>`
- `wm workspace-cycle <previous|next>`
- `wm send-cycle <previous|next>`
- `wm active-workspace <previous|next>`
- `wm last-workspace`
- `wm move-workspace <left|right|up|down>`: Returns `{ "noOp": true, "reason": "single-monitor" }` if the system has only one monitor.
- `wm resize <width|height> <signed-percent>`
- `wm resize-mode`
- `wm layout <fair|fair-horizontal|columns|rows|previous|next>`
- `wm tiling-direction`
- `wm cycle-layer`
- `wm float`
- `wm monocle`
- `wm fullscreen`
- `wm maximize`
- `wm minimize`
- `wm close`
- `wm manage`
- `wm unmanage`
- `wm pause` (note: `wm pause-hook` is internal to whkd for state notification and should not be invoked directly by agents)
- `wm retile`
- `wm restore`: Restore minimized windows (upstream restore-windows functionality; not to be confused with the installer's `restore.ps1` recovery tool)
- `wm reload`: Reload configuration through a controlled process restart so removed matching rules cannot remain resident (asynchronous; poll `wm state` with bounded retries)
- `wm restart`: Restart the window manager (asynchronous operation; agents must poll `wm state` with bounded retries to verify completion)
- `wm start`
- `wm stop`
- `wm status`: Returns a path and process snapshot; it is not a full health check.
- `wm launch <terminal|firefox|explorer|obsidian|flow|cursor> [--resolve]`: Dry-runs path resolution with `--resolve` or executes the launcher.
- `wm help`

Display Scaling:
- `change_scale.ps1 status`
- `change_scale.ps1 up`
- `change_scale.ps1 down`

## Testing and Preflight Protocol

### Testing Warnings
Do not stop or start the live window manager during repository tests. Process lifecycle changes can disrupt the active desktop even when filesystem operations are transactional.

### Preflight, Diagnostics, and Recovery Flow
Agents must follow a structured preflight, execution, and verification flow:

1. **Preflight Diagnostics**: Run `doctor.ps1 -Json` to retrieve the environment diagnostic state. Note that `wm status` returns running process lists and paths, but is NOT a comprehensive system health check.
2. **Snapshot**: Capture the current state using `wm state`.
3. **Execution**: Issue the mutating command (e.g., `wm layout columns`).
4. **Bounded Verification**:
   - For synchronous mutations, query and compare state again with `wm state`.
   - For asynchronous mutations (such as `wm reload` or `wm restart`), agents must poll `wm state` with bounded retries to verify completion.
5. **Diagnostics on Failure**: If focus verification fails, run `wm focus-health`; for lifecycle or configuration failures, run `doctor.ps1 -Json`.
6. **Recovery/Rollback**: Invoke recovery or rollback scripts (`restore.ps1` or `uninstall.ps1`) only if a validated installation manifest exists, preventing corruption of pre-existing user configurations.

### Parsec Boundary

Parsec keyboard immersive mode can capture `Alt` shortcuts before `whkd` sees them. Agents must not interpret a missing local shortcut event as a Komorebi focus failure. Ask the user to toggle Parsec immersive mode (default `Ctrl + Shift + I`) or detach Parsec input (default `Ctrl + Alt + Z`), then rerun `wm focus-health`. Do not automate Parsec input detachment because it changes control of the remote session.
