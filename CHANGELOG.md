# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed
- Reframed the repository front page around the one-command install, deterministic agent workflow, real Windows focus behavior, and explicit trust boundaries.
- Moved the expanded release-integrity walkthrough into a dedicated verified-installation guide and added a repository-owned product schematic.

### Fixed
- Chrome Downloads and other owned Chromium tool windows remain outside tiling while verified browser and Electron main windows stay managed.
- `wm reload` now uses the controlled restart lifecycle so removed application rules cannot remain resident in Komorebi.

## [0.3.0] - 2026-07-14

### Added
- Read-only focus diagnostics for comparing Komorebi state with Win32 foreground, keyboard-focus, and mouse-under roots.
- A locally compiled, manifest-owned Win32 interop assembly keeps dynamic C# compilation out of the installed focus path.
- Portable window rules for Chromium transients, Office and PowerToys helpers, core desktop applications, Parsec, and Cinema 4D dialogs.

### Fixed
- Directional focus verifies the real Windows foreground root, repairs bounded activation mismatches without moving the cursor, and redirects disabled modal owners to their active popup.
- Upgrades accept the exact v0.2.0 schema-1 file profile while still rejecting partial or forged manifests.
- The short human bootstrap binds installer parameters correctly instead of passing named values positionally.
- Installation verifies runtime health before atomically committing its manifest and can roll back without a loaded interop assembly locking files.
- `komorebi-bar` starts with the selected configuration, durable file-backed logs, and no transient console or parent-pipe lifetime dependency.

### Changed
- Plain `Alt+Arrow` remains available to Windows and File Explorer; directional focus stays available through the agent-friendly `wm focus <direction>` command.

## [0.2.0] - 2026-07-13

### Added
- Short `irm ... | iex` bootstrap command and a version-pinnable JSON agent command.
- Installed `agent-manifest.json` machine contract for unattended automation.
- Per-user Inno Setup installer with silent install, upgrade, and uninstall support.
- WinGet community manifest generation from immutable release assets.

### Changed
- Release automation now publishes installer checksums, WinGet manifests, and provenance attestations.
- Package-manager installs can supply dependencies without invoking nested WinGet operations.

## [0.1.0] - 2026-07-12

### Added
- Initial release of `komorebi-starter`.
- One-command bootstrap with checksum integrity verification via `bootstrap.ps1`.
- Clean idempotent setup via `install.ps1`.
- Clean rollback and uninstallation via `restore.ps1` and `uninstall.ps1`.
- Core command-line wrapper script `wm.ps1` with single-monitor guards.
- Static checks and diagnostic doctor script `doctor.ps1`.
- Ultra-minimal bar layouts for Segoe UI Variable and JetBrains Mono fonts.
- Automatic upstream application rule merging.
