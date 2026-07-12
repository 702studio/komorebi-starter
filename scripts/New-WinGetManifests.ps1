[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-fA-F0-9]{64}$')]
    [string]$InstallerSha256,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-ReparsePoint {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    return [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Assert-RegularPathAncestors {
    param([string]$Path)

    $cursor = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($cursor)) {
        if ((Test-Path -LiteralPath $cursor) -and (Test-ReparsePoint $cursor)) {
            throw "Manifest output contains a reparse-point ancestor: $cursor"
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) {
            break
        }
        $cursor = $parent
    }
}

$packageIdentifier = '702studio.KomorebiStarter'
$manifestVersion = '1.12.0'
$tag = "v$Version"
$releaseUrl = "https://github.com/702studio/komorebi-starter/releases/tag/$tag"
$installerUrl = "https://github.com/702studio/komorebi-starter/releases/download/$tag/komorebi-starter-setup.exe"
$outputDir = [IO.Path]::GetFullPath($OutputRoot)
$manifestDir = [IO.Path]::GetFullPath((Join-Path $outputDir "manifests\7\702studio\KomorebiStarter\$Version"))
$outputPrefix = $outputDir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $manifestDir.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Manifest directory escaped the requested output root.'
}
Assert-RegularPathAncestors -Path $manifestDir

if (Test-Path -LiteralPath $manifestDir) {
    $item = Get-Item -LiteralPath $manifestDir -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Manifest directory is a reparse point: $manifestDir"
    }
    if (-not $Force) {
        throw "Manifest directory already exists: $manifestDir"
    }
    Remove-Item -LiteralPath $manifestDir -Recurse -Force
}
New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
Assert-RegularPathAncestors -Path $manifestDir

$versionYaml = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.1.12.0.schema.json
PackageIdentifier: $packageIdentifier
PackageVersion: $Version
DefaultLocale: en-US
ManifestType: version
ManifestVersion: $manifestVersion
"@

$localeYaml = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.1.12.0.schema.json
PackageIdentifier: $packageIdentifier
PackageVersion: $Version
PackageLocale: en-US
Publisher: 702studio
PublisherUrl: https://github.com/702studio
PublisherSupportUrl: https://github.com/702studio/komorebi-starter/issues
Author: 702studio
PackageName: Komorebi Starter
PackageUrl: https://github.com/702studio/komorebi-starter
License: MIT
LicenseUrl: https://github.com/702studio/komorebi-starter/blob/$tag/LICENSE
ShortDescription: Agent-friendly komorebi, whkd, masir, and komorebi-bar baseline.
Description: >-
  A transactional, keyboard-driven Windows 11 desktop baseline with deterministic
  configuration, diagnostics, rollback, and a structured command wrapper for agents.
Moniker: komorebi-starter
Tags:
- automation
- komorebi
- powershell
- tiling-window-manager
- whkd
- windows-11
ReleaseNotesUrl: $releaseUrl
ManifestType: defaultLocale
ManifestVersion: $manifestVersion
"@

$installerYaml = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.1.12.0.schema.json
PackageIdentifier: $packageIdentifier
PackageVersion: $Version
Platform:
- Windows.Desktop
MinimumOSVersion: 10.0.22000.0
InstallerType: inno
Scope: user
InstallModes:
- silent
- silentWithProgress
- interactive
InstallerSwitches:
  Custom: /WINGET
UpgradeBehavior: install
Commands:
- wm
Dependencies:
  PackageDependencies:
  - PackageIdentifier: LGUG2Z.komorebi
  - PackageIdentifier: LGUG2Z.whkd
  - PackageIdentifier: LGUG2Z.masir
AppsAndFeaturesEntries:
- DisplayName: Komorebi Starter
  Publisher: 702studio
  ProductCode: '{5FA3F095-B1A1-4B29-BC3F-AA25DDD5902C}_is1'
  InstallerType: inno
Installers:
- Architecture: neutral
  InstallerUrl: $installerUrl
  InstallerSha256: $($InstallerSha256.ToUpperInvariant())
ManifestType: installer
ManifestVersion: $manifestVersion
"@

$utf8NoBom = [Text.UTF8Encoding]::new($false)
$files = [ordered]@{
    "$packageIdentifier.yaml" = $versionYaml
    "$packageIdentifier.locale.en-US.yaml" = $localeYaml
    "$packageIdentifier.installer.yaml" = $installerYaml
}

foreach ($entry in $files.GetEnumerator()) {
    $path = Join-Path $manifestDir $entry.Key
    [IO.File]::WriteAllText($path, $entry.Value.Trim() + "`n", $utf8NoBom)
}

return $manifestDir
