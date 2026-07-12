# Security Policy

## Supported Versions
Only the latest release of `komorebi-starter` is actively supported for security updates.

## Reporting a Vulnerability
If you identify a security vulnerability, do not open a public issue. Report it privately using the repository's security advisory form: https://github.com/702studio/komorebi-starter/security/advisories/new

## Trust Boundaries
- **Raw-main trust**: The one-liner executes `bootstrap.ps1` from the mutable `main` branch. That script is not authenticated by the release checksum; review it or pin a trusted commit before execution when stronger control is required.
- **Checksum integrity**: The bootstrap script verifies the downloaded `komorebi-starter.zip` against the `komorebi-starter.zip.sha256` checksum file. This provides integrity verification, not cryptographic identity.
- **Actions provenance**: GitHub Actions build provenance (`release.yml`) attests the release assets.

## Asset Verification
- External executables (such as `SetDpi.exe`) are fetched over secure HTTPS connections.
- Binaries are verified against hardcoded SHA-256 checksums before execution.
- If checksum or download verification fails for a component like `SetDpi.exe`, execution of the downloaded payload is prevented. The `change_scale.ps1 status` command will report the tool as unavailable, and `change_scale.ps1 up` or `change_scale.ps1 down` will throw errors, while the core Window Manager remains installed.
