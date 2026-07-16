# Verified Installation

The short bootstrap already validates release metadata, exact asset names and sizes, and the ZIP SHA-256 before it invokes `install.ps1`. This guide exposes the same trust boundary for users who want to inspect each step before installation.

## What each check proves

| Check | Evidence | Does not prove |
| --- | --- | --- |
| Exact release asset names | The expected files are present once and only once | Who authored the files |
| GitHub metadata size | Downloaded bytes match the published release metadata | File contents are safe |
| SHA-256 | The ZIP bytes match the separately published checksum | Publisher identity |
| GitHub attestation | The artifact was produced by the recorded GitHub Actions workflow | Authenticode publisher identity |
| Repository review | The scripts and configuration match your expectations | Future upstream behavior |

The raw `main` bootstrap is its own trust boundary. For reproducible automation, invoke it with an immutable release tag through the `-Version` parameter rather than `latest`.

## Inspect and install

Run the following in Windows PowerShell. It downloads into a fresh temporary directory, validates the archive, and only then executes the extracted installer.

```powershell
$work = Join-Path $env:TEMP ('KomorebiStarter-Verify-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null

# Resolve the latest release and require one asset of each exact name.
$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/702studio/komorebi-starter/releases/latest'
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

# Optional provenance check with GitHub CLI:
# gh attestation verify $zipPath --repo 702studio/komorebi-starter

# Extract to a fresh directory and invoke the installer.
$payload = Join-Path $work 'payload'
Expand-Archive -LiteralPath $zipPath -DestinationPath $payload
Set-Location $payload
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Preset Minimal
```

## Non-interactive verification

Agents can ask the public bootstrap for a no-mutation plan:

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/702studio/komorebi-starter/main/bootstrap.ps1'))) -Version latest -WhatIf -NonInteractive -Quiet -Json
```

For an actual unattended install, remove `-WhatIf`. Winget or Windows may still request elevation for a dependency.

## After installation

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\KomorebiStarter\doctor.ps1" -Json
wm state
```

The diagnostic result should identify the resolved install, configuration, and state roots. Use the [agent verification protocol](../AGENTS.md#preflight-diagnostics-and-recovery-flow) before any automated mutation.
