# Komorebi Starter

A keyboard-driven Windows 11 desktop baseline for komorebi, whkd, masir, and komorebi-bar.

## Prerequisites
- Windows 11
- Windows PowerShell 5.1
- Winget (for dependency installation; elevation may be requested)

## Quick Start
Run one command in Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/702studio/komorebi-starter/main/bootstrap.ps1 | iex
```

The raw bootstrap resolves the latest GitHub Release, requires exact asset names and sizes, verifies the ZIP SHA-256, extracts it, and runs the installer. The short command uses default options. Use the parameterized agent command below for version pinning, JSON output, font installation, or GlazeWM migration.

When `702studio.KomorebiStarter` becomes discoverable in the WinGet community catalog, the equivalent package-manager command is:

```powershell
winget install --exact --id 702studio.KomorebiStarter
```

Until `winget show --exact --id 702studio.KomorebiStarter` succeeds, use the bootstrap command above. The GitHub Release also provides `komorebi-starter-setup.exe`, a per-user installer with silent install, upgrade, and uninstall support.

The EXE is not Authenticode-signed yet. Release SHA-256 files provide integrity checks and GitHub attestations provide build provenance; neither is a publisher code-signing certificate.

**System changes:**
- Winget ensures `LGUG2Z.komorebi`, `LGUG2Z.whkd`, and `LGUG2Z.masir`; the Komorebi package provides `komorebi-bar`.
- `DEVCOM.JetBrainsMonoNerdFont` is installed only when `-InstallFonts` is passed.
- Configurations deployed to `%USERPROFILE%\.config\komorebi`.
- Programs deployed to `%LOCALAPPDATA%\Programs\KomorebiStarter`.
- Runtime data stored in `%LOCALAPPDATA%\KomorebiStarter`.
- `KomorebiStarter` logon scheduled task created.
- Portable rules handle common transient, modal, tray, Parsec, and Cinema 4D windows without embedding user-specific paths.
- A new terminal may be needed for the updated `PATH` to take effect.

## Verified Installation (Checksum Validation)
To manually verify integrity before installation, run the following executable PowerShell script. A checksum verification confirms asset integrity, while build attestation verifies workflow provenance. The raw main branch remains a separate trust domain.

```powershell
$work = Join-Path $env:TEMP ('KomorebiStarter-Verify-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null

# Retrieve the latest release metadata and require one asset of each exact name.
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/702studio/komorebi-starter/releases/latest"
$zipAssets = @($release.assets | Where-Object { [string]$_.name -ceq 'komorebi-starter.zip' })
$hashAssets = @($release.assets | Where-Object { [string]$_.name -ceq 'komorebi-starter.zip.sha256' })
if ($zipAssets.Count -ne 1 -or $hashAssets.Count -ne 1) {
    throw 'Release must contain exactly one ZIP and one checksum asset.'
}

# Download both assets and compare their sizes with release metadata.
foreach ($asset in @($zipAssets[0], $hashAssets[0])) {
    $destination = Join-Path $work $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $destination -UseBasicParsing
    if ((Get-Item -LiteralPath $destination).Length -ne [int64]$asset.size) {
        throw "Downloaded size mismatch for $($asset.name)."
    }
}

# Require the exact checksum grammar and compare SHA-256.
$zipPath = Join-Path $work 'komorebi-starter.zip'
$checksumPath = Join-Path $work 'komorebi-starter.zip.sha256'
$shaContent = (Get-Content -LiteralPath $checksumPath -Raw).Trim()
if ($shaContent -notmatch '^[a-fA-F0-9]{64}[ \t]+\*?komorebi-starter\.zip$') {
    throw 'Invalid SHA-256 checksum file.'
}
$expectedHash = ($shaContent -split '\s+')[0]
$actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
if ($actualHash -ne $expectedHash) {
    throw "SHA-256 checksum mismatch. Expected: $expectedHash, actual: $actualHash"
}

# Optional: Verify workflow provenance using GitHub CLI
# gh attestation verify $zipPath --repo 702studio/komorebi-starter

# Extract to a fresh folder, enter it, and invoke the installer
$payload = Join-Path $work 'payload'
Expand-Archive -LiteralPath $zipPath -DestinationPath $payload
Set-Location $payload
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Preset Minimal
```

## Direct Clone Installation
Clone the repository and install directly from the source:
```powershell
git clone https://github.com/702studio/komorebi-starter.git
Set-Location komorebi-starter
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Preset Minimal
```

## Migration from GlazeWM
To migrate from GlazeWM, clone the repository and run the installation script from within the repository root (after executing the clone and `Set-Location komorebi-starter` steps shown above). The migration leaves existing GlazeWM configurations and binaries intact, but performs an explicit process takeover by disabling the GlazeWM startup task and registering KomorebiStarter as the startup window manager.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Preset Minimal -MigrateFromGlazeWM
```

## Agent and Unattended Automation
Agents should read [`agent-manifest.json`](agent-manifest.json) before mutation. It defines the fixed paths, parameters, output contract, verification protocol, and recovery commands.

Run a version-pinnable remote installation with JSON-only stdout:

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/702studio/komorebi-starter/main/bootstrap.ps1'))) -Version latest -NonInteractive -Quiet -Json
```

Perform a remote dry-run without network requests beyond fetching the raw bootstrap and without system mutation:

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/702studio/komorebi-starter/main/bootstrap.ps1'))) -Version latest -WhatIf -NonInteractive -Quiet -Json
```

From a clone or extracted release, view the local execution plan without network requests or system mutation:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Preset Minimal -WhatIf -NonInteractive -Quiet -Json
```

Run a non-interactive installation. Winget or Windows may still require elevation for a dependency:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Preset Minimal -NonInteractive -Json
```

## Diagnosis and Recovery
Check system health, path resolutions, and process states using the installed diagnostic script (or the source equivalent at `.\scripts\doctor.ps1`):
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\KomorebiStarter\doctor.ps1" -Json
```

Inspect focus without changing any window, cursor position, or process:
```powershell
& "$env:LOCALAPPDATA\Programs\KomorebiStarter\wm.ps1" focus-health
```

The focus report compares the window selected by Komorebi with the Windows foreground root, keyboard-focus child, window under the mouse, and any active modal popup. Window titles and process names are omitted by default; run `focus-diagnostics.ps1 -Json -IncludeWindowMetadata` only when that detail is needed. A directional `wm focus` command returns a nonzero exit code when Windows does not activate the verified target after bounded repair attempts.

Edit the configuration in `%USERPROFILE%\.config\komorebi\komorebi.json` and reload:
```powershell
& "$env:LOCALAPPDATA\Programs\KomorebiStarter\wm.ps1" reload
```

Restore previous window managers and remove files installed by this package using the installed script (or `.\restore.ps1` in source):
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\KomorebiStarter\restore.ps1"
```

Uninstall and preserve user configuration (or `.\uninstall.ps1` in source):
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\KomorebiStarter\uninstall.ps1"
```

Uninstall and remove configuration files:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\KomorebiStarter\uninstall.ps1" -RemoveConfig
```

## Shortcuts

### Focus
| Action | Control |
|---|---|
| Focus left/right/up/down (CLI/agent) | `wm focus left/right/up/down` |
| Native application navigation | `Alt + Left/Right/Up/Down` (unbound by this setup) |
| Workspace cycle previous/next | `Alt + J` / `Alt + K` |
| Workspace cycle previous/next (alt) | `Ctrl + Alt + Left` / `Ctrl + Alt + Right` |
| Active workspace previous/next | `Alt + A` / `Alt + S` |
| Last workspace | `Alt + D` |
| Focus workspace 1-9 | `Alt + 1-9` |

### Move
| Action | Shortcut |
|---|---|
| Move up/down/left/right | `Alt + Shift + Up/Down/Left/Right` |
| Send cycle previous/next | `Alt + Shift + J` / `Alt + Shift + K` |
| Send cycle previous/next (alt)| `Ctrl + Alt + Shift + Left/Right` |
| Send to workspace 1-9 | `Alt + Shift + 1-9` |
| Move and follow to workspace 1-9 | `Ctrl + Alt + 1-9` |
| Move workspace to monitor | `Alt + Shift + A` (Left) / `Alt + Shift + S` (Down) / `Alt + Shift + D` (Up) / `Alt + Shift + F` (Right) |

### Resize & Layout
| Action | Shortcut |
|---|---|
| Resize width | `Alt + L` (Increase), `Alt + H` (Decrease) |
| Resize height | `Alt + U` (Increase), `Alt + I` (Decrease) |
| Modal resize mode | `Alt + Y` |
| Tiling direction | `Alt + Shift + Space` |
| Layout next/previous | `Ctrl + Alt + Space` / `Ctrl + Alt + Shift + Space` |
| Cycle layer | `Alt + OEM_5` (backslash key) |
| Toggle float | `Alt + Space` or `Alt + T` |
| Toggle fullscreen | `Alt + F` |
| Minimize / Close | `Alt + N` / `Alt + Q` |

### Lifecycle
| Action | Shortcut |
|---|---|
| Stop WM | `Alt + Shift + E` |
| Restart WM | `Alt + Shift + Backspace` or `Alt + Shift + X` |
| Reload config (controlled restart) | `Alt + Shift + R` |
| Retile | `Alt + Shift + W` |
| Pause | `Alt + Shift + P` |

### Launchers
| Action | Shortcut |
|---|---|
| Terminal | `Alt + Return` |
| Firefox | `Alt + B` |
| Explorer | `Alt + E` |
| Obsidian | `Alt + O` |
| Flow Launcher | `Alt + R` |
| Cursor | `Alt + C` |

### Display
| Action | Shortcut |
|---|---|
| Scaling up/down | `Ctrl + Alt + Shift + Up` / `Ctrl + Alt + Shift + Down` |

## Focus Behavior and Parsec

`masir` changes focus only after relative mouse movement. A stationary pointer therefore does not override keyboard-driven WM focus. Plain `Alt + Arrow` remains native to Windows and File Explorer; agents can use `wm focus left/right/up/down`. When an application disables its managed owner for a modal dialog, the focus wrapper activates the visible, enabled last-active popup instead of the disabled owner.

Parsec can capture shortcuts before `whkd` receives them. With Parsec's keyboard immersive mode active, use Parsec's configured **Immersive Mode** hotkey (default `Ctrl + Shift + I`) or **Detach Input** hotkey (default `Ctrl + Alt + Z`) before using local window-manager shortcuts. This input-capture boundary cannot be bypassed reliably by a local window-manager script. See [Parsec Immersive Mode](https://support.parsec.app/hc/en-us/articles/32361385571860-Immersive-Mode-Setting) and [Parsec hotkeys](https://support.parsec.app/hc/en-us/articles/32381778420372-Configure-Hotkeys).

Run the repeatable [focus quality-assurance matrix](docs/FOCUS_QA.md) before reporting or releasing focus changes.

## Licensing
Project scripts and configurations are [MIT Licensed](LICENSE). Komorebi, whkd, and masir use the custom Komorebi License Version 2.0.0 (SPDX NOASSERTION). Its Personal Uses section permits the listed personal uses when there is no anticipated commercial application; commercial use may require a separate license. Review [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the current upstream terms.
