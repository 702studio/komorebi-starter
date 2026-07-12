# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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
