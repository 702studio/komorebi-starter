[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure paths are absolute and normalized
$realRepoRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$realOutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$repoRootPrefix = $realRepoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

if (-not (Test-Path -LiteralPath $realRepoRoot -PathType Container)) {
    throw "Repository root does not exist or is not a directory: $realRepoRoot"
}

# Helper function to check for reparse point
function Get-IsReparsePoint {
    param([string]$path)
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        return ($item.Attributes -match 'ReparsePoint')
    }
    return $false
}

function Assert-NoReparseAncestors {
    param(
        [string]$PathName,
        [string]$PathValue
    )

    $cursor = [IO.Path]::GetFullPath($PathValue)
    while (-not [string]::IsNullOrEmpty($cursor)) {
        if ((Test-Path -LiteralPath $cursor) -and (Get-IsReparsePoint $cursor)) {
            throw "Security validation failed: $PathName contains a reparse-point ancestor: $cursor"
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) {
            break
        }
        $cursor = $parent
    }
}

Assert-NoReparseAncestors -PathName 'Repository root' -PathValue $realRepoRoot
Assert-NoReparseAncestors -PathName 'Output root' -PathValue $realOutputRoot

# Reject source/output reparse points
if (Get-IsReparsePoint $realRepoRoot) {
    throw "Security validation failed: Repository root is a reparse point: $realRepoRoot"
}
if (Get-IsReparsePoint $realOutputRoot) {
    throw "Security validation failed: Output root is a reparse point: $realOutputRoot"
}

# Reject OutputRoot equal to or nested below RepositoryRoot. Otherwise generated
# artifacts can become inputs to the same build and undermine reproducibility.
if ($realOutputRoot -eq $realRepoRoot -or $realOutputRoot.StartsWith($repoRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Security validation failed: Output root cannot equal or be nested below repository root."
}

# Validate required files exist
$RequiredFiles = @(
    "bootstrap.ps1",
    "install.ps1",
    "uninstall.ps1",
    "restore.ps1",
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "README.md",
    "SECURITY.md",
    "CHANGELOG.md",
    "docs/FOCUS_QA.md",
    "docs/VERIFY_INSTALL.md",
    "docs/assets/readme-hero.svg",
    "docs/assets/readme-hero-mobile.svg",
    "agent-manifest.json",
    "PSScriptAnalyzerSettings.psd1",
    "config/komorebi.json",
    "config/komorebi.bar.json",
    "config/komorebi.bar.jetbrains.json",
    "config/applications.local.json",
    "config/whkdrc",
    "scripts/start.ps1",
    "scripts/doctor.ps1",
    "scripts/FocusInterop.cs",
    "scripts/FocusInterop.ps1",
    "scripts/focus-diagnostics.ps1",
    "scripts/wm.ps1",
    "scripts/wm.cmd",
    "scripts/wm-resize-mode.ps1",
    "scripts/KomorebiStarter.Common.ps1",
    "scripts/change_scale.ps1",
    "scripts/New-ReleasePackage.ps1",
    "tests/Test-Repository.ps1"
)

foreach ($req in $RequiredFiles) {
    $reqPath = Join-Path $realRepoRoot $req
    if (-not (Test-Path -LiteralPath $reqPath -PathType Leaf)) {
        throw "Required file '$req' is missing from repository root."
    }
}

# Validate required directories exist
$RequiredDirs = @(
    "config",
    "scripts",
    "docs",
    "docs/assets"
)
foreach ($rd in $RequiredDirs) {
    $rdPath = Join-Path $realRepoRoot $rd
    if (-not (Test-Path -LiteralPath $rdPath -PathType Container)) {
        throw "Required directory '$rd' is missing from repository root."
    }
}

# Explicit allowlist of allowed files/patterns
# Excludes .git, .reference, .github, unowned generated assets, and third-party binaries.
$AllowedPatterns = @(
    '^bootstrap\.ps1$',
    '^install\.ps1$',
    '^uninstall\.ps1$',
    '^restore\.ps1$',
    '^LICENSE$',
    '^README\.md$',
    '^THIRD_PARTY_NOTICES\.md$',
    '^SECURITY\.md$',
    '^CONTRIBUTING\.md$',
    '^SUPPORT\.md$',
    '^CHANGELOG\.md$',
    '^CODE_OF_CONDUCT\.md$',
    '^docs/FOCUS_QA\.md$',
    '^docs/VERIFY_INSTALL\.md$',
    '^docs/assets/readme-hero\.svg$',
    '^docs/assets/readme-hero-mobile\.svg$',
    '^AGENTS\.md$',
    '^agent-manifest\.json$',
    '^config/(?:komorebi|komorebi\.bar|komorebi\.bar\.jetbrains|applications\.local)\.json$',
    '^config/whkdrc$',
    '^scripts/FocusInterop\.cs$',
    '^scripts/(?:start|doctor|FocusInterop|focus-diagnostics|wm|wm-resize-mode|KomorebiStarter\.Common|change_scale)\.ps1$',
    '^scripts/wm\.cmd$'
)

# Helper function to compute relative path under RepositoryRoot with forward slashes
function Get-NormalizedRelativePath {
    param(
        [string]$BasePath,
        [string]$Path
    )
    $base = [IO.Path]::GetFullPath($BasePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $full.Substring($base.Length)
        return $relative.Replace('\', '/')
    } else {
        throw "Path '$Path' is not under base path '$BasePath'"
    }
}

function Get-SHA256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $hasher = $null
    try {
        $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
        $hasher = [Security.Cryptography.SHA256]::Create()
        return [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $hasher) {
            $hasher.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

Write-Verbose "Scanning repository files..."
$allFiles = Get-ChildItem -Path $realRepoRoot -Recurse -File
$includedFiles = @()
$totalSourceBytes = [int64]0

foreach ($file in $allFiles) {
    # Check if the file is a reparse point
    if (Get-IsReparsePoint $file.FullName) {
        throw "Security validation failed: Source file is a reparse point: $($file.FullName)"
    }

    # Check all parent directories up to $realRepoRoot for reparse points
    $parent = $file.Directory
    while ($null -ne $parent -and $parent.FullName -ne $realRepoRoot) {
        if (Get-IsReparsePoint $parent.FullName) {
            throw "Security validation failed: Source ancestor directory is a reparse point: $($parent.FullName)"
        }
        $parent = $parent.Parent
    }

    $relPath = Get-NormalizedRelativePath -BasePath $realRepoRoot -Path $file.FullName

    # Reject files containing .git, .github, .reference explicitly
    if ($relPath -match '(^|/)\.(git|github|reference)(/|$)') {
        continue
    }

    # Match against allowlist
    $isAllowed = $false
    foreach ($pattern in $AllowedPatterns) {
        if ($relPath -match $pattern) {
            $isAllowed = $true
            break
        }
    }

    if ($isAllowed) {
        # Reject any file with a binary extension
        $ext = [System.IO.Path]::GetExtension($file.FullName)
        if ($ext -match '^\.(exe|dll|bin|zip|7z|tar|gz|rar|msi|png|jpg|jpeg|gif|bmp|ico|sys|cab|lib|a|so|dylib|obj|o|pyc)$') {
            throw "Security validation failed: Included file '$relPath' has an invalid binary extension: $ext"
        }
        if ($file.Length -gt (16 * 1024 * 1024)) {
            throw "Security validation failed: Included file '$relPath' exceeds 16 MiB."
        }
        $totalSourceBytes += [int64]$file.Length
        if ($totalSourceBytes -gt (64 * 1024 * 1024)) {
            throw "Security validation failed: Included source files exceed 64 MiB in total."
        }
        $includedFiles += $relPath
    }
}

if ($includedFiles.Count -eq 0) {
    throw "Security validation failed: Zero files were included in the package."
}

# Sort normalized relative paths ordinally
$sortedFiles = [System.Collections.Generic.List[string]]::new()
foreach ($file in $includedFiles) {
    $sortedFiles.Add($file)
}
$sortedFiles.Sort([System.StringComparer]::Ordinal)

# Ensure output directory exists
if (-not (Test-Path -LiteralPath $realOutputRoot)) {
    New-Item -ItemType Directory -Path $realOutputRoot -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $realOutputRoot -PathType Container) -or (Get-IsReparsePoint $realOutputRoot)) {
    throw "Security validation failed: Output root is not a regular directory: $realOutputRoot"
}

$zipPath = Join-Path $realOutputRoot "komorebi-starter.zip"
$shaPath = Join-Path $realOutputRoot "komorebi-starter.zip.sha256"
foreach ($outputPath in @($zipPath, $shaPath)) {
    if (Test-Path -LiteralPath $outputPath) {
        if (Get-IsReparsePoint $outputPath) {
            throw "Security validation failed: Output file path is a reparse point: $outputPath"
        }
        if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw "Security validation failed: Output file path is not a regular file: $outputPath"
        }
        Remove-Item -LiteralPath $outputPath -Force
    }
}

try {
    Write-Verbose "Creating ZIP archive at $zipPath..."
    Add-Type -AssemblyName System.IO.Compression

    $zipStream = New-Object System.IO.FileStream($zipPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create, $false, [System.Text.Encoding]::UTF8)
        try {
            # Fixed timestamp: 2026-01-01T00:00:00Z
            $fixedTimestamp = [DateTimeOffset]([DateTime]"2026-01-01T00:00:00Z")

            foreach ($relPath in $sortedFiles) {
                $sourceFile = Join-Path $realRepoRoot ($relPath.Replace('/', [IO.Path]::DirectorySeparatorChar))
                if (Get-IsReparsePoint $sourceFile) {
                    throw "Security validation failed: Source file became a reparse point during packaging: $relPath"
                }
                Write-Verbose "Adding entry: $relPath"

                $entry = $archive.CreateEntry($relPath, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $fixedTimestamp

                $entryStream = $entry.Open()
                try {
                    $fileStream = New-Object System.IO.FileStream($sourceFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
                    try {
                        $fileStream.CopyTo($entryStream)
                    } finally {
                        $fileStream.Dispose()
                    }
                } finally {
                    $entryStream.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $zipStream.Dispose()
    }

    Write-Verbose "ZIP archive created successfully. Computing SHA256..."
    if ((Get-Item -LiteralPath $zipPath -Force).Length -gt (50 * 1024 * 1024)) {
        throw "Security validation failed: Generated ZIP exceeds 50 MiB."
    }
    $hash = Get-SHA256Hex -Path $zipPath
    $shaContent = "$hash *komorebi-starter.zip"

    # Write exact checksum grammar as ASCII without BOM or a trailing newline.
    $shaBytes = [System.Text.Encoding]::ASCII.GetBytes($shaContent)
    $shaStream = New-Object System.IO.FileStream($shaPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
        $shaStream.Write($shaBytes, 0, $shaBytes.Length)
    } finally {
        $shaStream.Dispose()
    }
    Write-Verbose "Checksum file created at $shaPath with content: $shaContent"
} catch {
    foreach ($outputPath in @($zipPath, $shaPath)) {
        if ((Test-Path -LiteralPath $outputPath -PathType Leaf) -and -not (Get-IsReparsePoint $outputPath)) {
            Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        }
    }
    throw
}

# Return the hash
return $hash
