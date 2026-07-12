# Komorebi Starter

A keyboard-driven Windows 11 desktop baseline for komorebi, whkd, masir, and komorebi-bar.

## Prerequisites
- Windows 11
- Windows PowerShell 5.1
- Winget (for dependency installation; elevation may be requested)

## Quick Start (Raw Bootstrap)
Run the following command in Windows PowerShell to download and execute the bootstrap script.

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; iex ((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/702studio/komorebi-starter/main/bootstrap.ps1'))
```

*Note: The bootstrap fetches from the `main` branch, resolves the latest GitHub Release (failing closed if release metadata, assets, or hash validation fails), verifies the `komorebi-starter.zip` checksum, extracts it, and runs the installer. The raw invoke-expression cannot receive migration flags like `-MigrateFromGlazeWM`. For migration, prefer a clone installation.*

**System changes:**
- Winget ensures `LGUG2Z.komorebi`, `LGUG2Z.whkd`, and `LGUG2Z.masir`; the Komorebi package provides `komorebi-bar`.
- `DEVCOM.JetBrainsMonoNerdFont` is installed only when `-InstallFonts` is passed.
- Configurations deployed to `%USERPROFILE%\.config\komorebi`.
- Programs deployed to `%LOCALAPPDATA%\Programs\KomorebiStarter`.
- Runtime data stored in `%LOCALAPPDATA%\KomorebiStarter`.
- `KomorebiStarter` logon scheduled task created.
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
Perform a dry-run to view the execution plan without network requests or system mutation:
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
| Action | Shortcut |
|---|---|
| Focus up/down | `Alt + Up` / `Alt + Down` |
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
| Reload config | `Alt + Shift + R` |
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

## Licensing
Project scripts and configurations are [MIT Licensed](LICENSE). Komorebi, whkd, and masir use the custom Komorebi License Version 2.0.0 (SPDX NOASSERTION). Its Personal Uses section permits the listed personal uses when there is no anticipated commercial application; commercial use may require a separate license. Review [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the current upstream terms.
