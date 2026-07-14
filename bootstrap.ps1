[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Minimal')]
    [string]$Preset = 'Minimal',
    [switch]$NonInteractive,
    [switch]$Json,
    [switch]$InstallFonts,
    [switch]$MigrateFromGlazeWM,
    [switch]$Force,
    [switch]$Quiet,
    [ValidatePattern('^(?:latest|[A-Za-z0-9][A-Za-z0-9._-]{0,63})$')]
    [string]$Version = 'latest'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Sanitize-Text {
    param([string]$text)
    if ([string]::IsNullOrEmpty($text)) { return $text }

    foreach ($secret in @($env:GITHUB_TOKEN, $env:GH_TOKEN)) {
        if (-not [string]::IsNullOrEmpty($secret)) {
            $text = $text.Replace($secret, '***')
        }
    }

    $text = $text -replace '(?i)\b(?:github_pat_|gh[pousr]_)[A-Za-z0-9_]+\b', '***'
    $text = $text -replace '(?i)(authorization\s*[:=]\s*(?:bearer|token)\s+)[^\s,;]+', '$1***'
    $text = $text -replace '(?i)\btoken\s+[A-Za-z0-9_\-\.~]+', 'token ***'
    if ($text.Length -gt 4096) {
        $text = $text.Substring(0, 4096) + "`n...[truncated]"
    }
    return $text
}

function Write-Step {
    param([string]$Message)
    if ($Quiet) { return }
    if ($Json) {
        [Console]::Error.WriteLine($Message)
    } else {
        Write-Host $Message -ForegroundColor Cyan
    }
}

# If both -WhatIf and -Json are passed, return the JSON plan immediately
if ($WhatIfPreference -and $Json) {
    $plan = [pscustomobject]@{
        productId = "702studio.komorebi-starter"
        schemaVersion = 1
        ok = $true
        version = $Version
        hash = "planned-whatif-hash"
        installResult = @{
            status = "planned"
            whatIf = $true
            message = "Plan execution: Dry-run requested via -WhatIf and -Json. No network, filesystem, or process actions were performed."
        }
    }
    $plan | ConvertTo-Json -Depth 5
    return
}

# If only -WhatIf is passed, log and exit
if ($WhatIfPreference) {
    Write-Step "Dry-run (-WhatIf) active: skipping real download, verification, extraction, and installation steps."
    return
}

# Unique temp child under TEMP
$tempDir = Join-Path $env:TEMP ("KomorebiStarter-Boot-{0}" -f [Guid]::NewGuid().ToString('N'))

# Helper function to check for reparse point
function Get-IsReparsePoint {
    param([string]$path)
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        return ($item.Attributes -match 'ReparsePoint')
    }
    return $false
}

# Safe recursive cleanup of temp directory
function Safe-CleanupDirectory {
    param([string]$targetDir)
    if (-not (Test-Path -LiteralPath $targetDir)) { return }

    $dirItem = Get-Item -LiteralPath $targetDir -Force -ErrorAction SilentlyContinue
    if ($null -eq $dirItem) { return }
    if ($dirItem.Attributes -match 'ReparsePoint') {
        throw "Security hazard: Directory is a reparse point: $targetDir"
    }

    $items = Get-ChildItem -LiteralPath $targetDir -Recurse -Force
    foreach ($item in $items) {
        if ($item.Attributes -match 'ReparsePoint') {
            throw "Security hazard: Reparse point detected inside temp directory: $($item.FullName)"
        }
    }
    Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Validate temp boundary
$canonicalTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$canonicalTempDir = [IO.Path]::GetFullPath($tempDir)
if (-not $canonicalTempDir.StartsWith($canonicalTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Security validation failed: Temporary directory path is outside the system TEMP directory boundary."
}

$repo = '702studio/komorebi-starter'
if ($Version -eq 'latest') {
    $releaseUrl = "https://api.github.com/repos/$repo/releases/latest"
} else {
    $escapedVersion = [Uri]::EscapeDataString($Version)
    $releaseUrl = "https://api.github.com/repos/$repo/releases/tags/$escapedVersion"
}

$expectedHash = $null
$actualVersion = $Version
$stdoutFile = $null
$stderrFile = $null
$bootstrapExitCode = 0

try {
    Write-Step "Resolving release details from GitHub for $repo (version: $Version)..."
    $headers = @{ 'User-Agent' = 'KomorebiStarter-Bootstrap' }
    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "token $env:GITHUB_TOKEN"
    }

    $release = $null
    try {
        $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers -Method Get -TimeoutSec 15
    } catch {
        throw "Failed to query release metadata from GitHub: $($_.Exception.Message)"
    }

    if ($null -eq $release -or $null -eq $release.assets) {
        throw "No assets found in the release of $repo."
    }

    $actualVersion = [string]$release.tag_name
    if ([string]::IsNullOrWhiteSpace($actualVersion) -or $actualVersion -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "Security validation failed: Release metadata contains an invalid tag name."
    }
    if ($Version -ne 'latest' -and $actualVersion -cne $Version) {
        throw "Security validation failed: Requested tag '$Version' resolved to unexpected tag '$actualVersion'."
    }

    # Require exactly one zip and one sha256
    $zipAssets = @()
    $shaAssets = @()
    foreach ($asset in $release.assets) {
        if ($asset.name -eq 'komorebi-starter.zip') {
            $zipAssets += $asset
        } elseif ($asset.name -eq 'komorebi-starter.zip.sha256') {
            $shaAssets += $asset
        }
    }

    if ($zipAssets.Count -ne 1) {
        throw "Security validation failed: Expected exactly one asset named 'komorebi-starter.zip', but found $($zipAssets.Count)."
    }
    if ($shaAssets.Count -ne 1) {
        throw "Security validation failed: Expected exactly one asset named 'komorebi-starter.zip.sha256', but found $($shaAssets.Count)."
    }

    $zipAsset = $zipAssets[0]
    $shaAsset = $shaAssets[0]

    if ($shaAsset.size -lt 1 -or $shaAsset.size -gt 4096) {
        throw "Security validation failed: Checksum asset size ($($shaAsset.size) bytes) is outside allowed range 1..4096 bytes."
    }
    if ($zipAsset.size -lt 1 -or $zipAsset.size -gt (50 * 1024 * 1024)) {
        throw "Security validation failed: ZIP asset size ($($zipAsset.size) bytes) is outside allowed range 1 byte..50 MiB."
    }

    $zipUrl = $zipAsset.browser_download_url
    $shaUrl = $shaAsset.browser_download_url

    # Helper to validate URL host and HTTPS
    function Test-SecureUrl {
        param([string]$url)
        if ($url -notlike 'https://*') { return $false }
        try {
            $uri = New-Object System.Uri $url
            $allowedHosts = @(
                'github.com',
                'objects.githubusercontent.com',
                'release-assets.githubusercontent.com'
            )
            if ($uri.Host -in $allowedHosts) {
                return $true
            }
        } catch {
            return $false
        }
        return $false
    }

    if (-not (Test-SecureUrl $zipUrl)) {
        throw "Security validation failed: Invalid or untrusted browser download URL for ZIP: $zipUrl"
    }
    if (-not (Test-SecureUrl $shaUrl)) {
        throw "Security validation failed: Invalid or untrusted browser download URL for SHA256: $shaUrl"
    }

    # Create temporary directory
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $zipPath = Join-Path $tempDir 'komorebi-starter.zip'
    $shaPath = Join-Path $tempDir 'komorebi-starter.zip.sha256'
    $extractPath = Join-Path $tempDir 'extracted'

    Write-Step "Downloading release archive..."
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120

    Write-Step "Downloading checksum file..."
    Invoke-WebRequest -Uri $shaUrl -OutFile $shaPath -UseBasicParsing -TimeoutSec 30

    $downloadedZipSize = (Get-Item -LiteralPath $zipPath -Force).Length
    $downloadedShaSize = (Get-Item -LiteralPath $shaPath -Force).Length
    if ($downloadedZipSize -lt 1 -or $downloadedZipSize -gt (50 * 1024 * 1024) -or $downloadedZipSize -ne [int64]$zipAsset.size) {
        throw "Security validation failed: Downloaded ZIP size ($downloadedZipSize bytes) does not match the validated release metadata ($($zipAsset.size) bytes)."
    }
    if ($downloadedShaSize -lt 1 -or $downloadedShaSize -gt 4096 -or $downloadedShaSize -ne [int64]$shaAsset.size) {
        throw "Security validation failed: Downloaded checksum size ($downloadedShaSize bytes) does not match the validated release metadata ($($shaAsset.size) bytes)."
    }

    # Validate checksum grammar
    $shaContent = (Get-Content -LiteralPath $shaPath -Raw).Trim()
    if ($shaContent -notmatch '^[a-fA-F0-9]{64}[ \t]+\*?komorebi-starter\.zip$') {
        throw "Checksum validation failed: Checksum file grammar is invalid or contains extra lines."
    }

    $expectedHash = ($shaContent -split '\s+')[0].ToUpperInvariant()
    $actualHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()

    if ($expectedHash -ne $actualHash) {
        throw "SHA-256 checksum verification failed. Expected: $expectedHash, actual: $actualHash"
    }
    Write-Step 'SHA-256 checksum verified successfully.'

    # Safe extraction
    Write-Step 'Extracting package archive...'
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    $canonicalExtractRoot = [IO.Path]::GetFullPath($extractPath)
    $canonicalExtractRootPrefix = $canonicalExtractRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    Add-Type -AssemblyName System.IO.Compression
    $zipStream = New-Object System.IO.FileStream($zipPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Read)
        try {
            if ($archive.Entries.Count -gt 512) {
                throw "Security validation failed: Archive exceeds maximum allowed entries (512)."
            }

            $totalUncompressed = 0
            foreach ($entry in $archive.Entries) {
                $totalUncompressed += $entry.Length
            }
            if ($totalUncompressed -gt (64 * 1024 * 1024)) {
                throw "Security validation failed: Archive total uncompressed size ($totalUncompressed bytes) exceeds maximum allowed (64 MiB)."
            }

            $extractedCanonicalPaths = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

            foreach ($entry in $archive.Entries) {
                $name = $entry.FullName

                # Reject empty names
                if ([string]::IsNullOrWhiteSpace($name)) {
                    throw "Security validation failed: Empty entry name."
                }

                # Reject backslashes
                if ($name -like '*\*') {
                    throw "Security validation failed: Entry name contains backslash: $name"
                }

                # Reject colons / ADS
                if ($name -like '*:*') {
                    throw "Security validation failed: Entry name contains alternate data stream colon: $name"
                }

                # Reject rooted paths
                if ($name.StartsWith('/') -or $name -match '^[a-zA-Z]:') {
                    throw "Security validation failed: Rooted path in zip entry: $name"
                }

                # Split segments to validate traversal and trailing dots/spaces
                $segments = $name.Split('/')
                for ($i = 0; $i -lt $segments.Length; $i++) {
                    $segment = $segments[$i]
                    if ($segment -eq '') {
                        # Reject empty interior segments (but allow empty trailing segment for directories ending in '/')
                        if ($i -ne ($segments.Length - 1) -or -not $name.EndsWith('/')) {
                            throw "Security validation failed: Empty interior segment in entry: $name"
                        }
                    }
                    if ($segment -eq '.' -or $segment -eq '..') {
                        throw "Security validation failed: Directory traversal segment ($segment) in entry: $name"
                    }
                    if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) {
                        throw "Security validation failed: Segment '$segment' has trailing dot or space in entry: $name"
                    }
                    if ($segment -ne '') {
                        if ($segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                            throw "Security validation failed: Segment '$segment' contains invalid Windows filename characters in entry: $name"
                        }
                        $deviceName = ($segment -split '\.', 2)[0]
                        if ($deviceName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
                            throw "Security validation failed: Segment '$segment' uses a reserved Windows device name in entry: $name"
                        }
                    }
                }

                # Resolve canonical destination path
                $normalizedRel = $name.Replace('/', [IO.Path]::DirectorySeparatorChar)
                $destPath = Join-Path $canonicalExtractRoot $normalizedRel
                $canonicalDest = [IO.Path]::GetFullPath($destPath)

                # Reject canonical destination collisions case-insensitively
                $canonicalCollisionKey = $canonicalDest.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
                if ($extractedCanonicalPaths.Contains($canonicalCollisionKey)) {
                    throw "Security validation failed: Duplicate canonical destination detected (case-insensitive collision): $canonicalDest"
                }
                $null = $extractedCanonicalPaths.Add($canonicalCollisionKey)

                # Reject outside extraction root
                if (-not $canonicalDest.StartsWith($canonicalExtractRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Security validation failed: Entry '$name' resolves outside extraction root."
                }

                # Create parent directories
                $parentDir = Split-Path -Parent $canonicalDest
                if (-not (Test-Path -LiteralPath $parentDir)) {
                    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
                }

                if ($name.EndsWith('/')) {
                    continue
                }

                # Max 16 MiB per file
                if ($entry.Length -gt (16 * 1024 * 1024)) {
                    throw "Security validation failed: Entry '$name' size ($($entry.Length) bytes) exceeds maximum allowed per file (16 MiB)."
                }

                # Extract file
                $entryStream = $entry.Open()
                try {
                    $destStream = New-Object System.IO.FileStream($canonicalDest, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
                    try {
                        $entryStream.CopyTo($destStream)
                        if ($destStream.Length -ne $entry.Length) {
                            throw "Security validation failed: Extracted size for '$name' does not match the archive entry size."
                        }
                    } finally {
                        $destStream.Dispose()
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

    # Require exact root-level install.ps1 and invoke only it
    $installScriptPath = Join-Path $canonicalExtractRoot 'install.ps1'
    if (-not (Test-Path -LiteralPath $installScriptPath -PathType Leaf)) {
        throw "Security validation failed: Root-level 'install.ps1' is missing in the release package."
    }

    Write-Step "Invoking installer: $installScriptPath..."
    $installParameters = @{
        Preset = $Preset
    }
    $childInstallArgs = @('-Preset', $Preset)
    foreach ($switchName in @('NonInteractive', 'Json', 'InstallFonts', 'MigrateFromGlazeWM', 'Force', 'Quiet')) {
        if (Get-Variable -Name $switchName -ValueOnly) {
            $installParameters[$switchName] = $true
            $childInstallArgs += "-$switchName"
        }
    }

    $prevCwd = Get-Location
    $success = $false
    $parsedResult = $null
    $stdoutFile = Join-Path $tempDir 'install-stdout.log'
    $stderrFile = Join-Path $tempDir 'install-stderr.log'

    try {
        Set-Location $canonicalExtractRoot
        if ($Json) {
            $quotedInstallScriptPath = '"' + $installScriptPath.Replace('"', '\"') + '"'
            $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $quotedInstallScriptPath)
            foreach ($arg in $childInstallArgs) {
                $argList += $arg
            }

            $process = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
            if ($null -eq $process) {
                throw "Failed to start child installer process."
            }
            if ($process.ExitCode -ne 0) {
                throw "Installer process exited with non-zero exit code: $($process.ExitCode)"
            }

            if (-not (Test-Path -LiteralPath $stdoutFile)) {
                throw "Installer stdout file not found."
            }
            $rawStdout = Get-Content -LiteralPath $stdoutFile -Raw
            $trimmedStdout = $rawStdout.Trim()
            if (-not ($trimmedStdout.StartsWith('{') -and $trimmedStdout.EndsWith('}'))) {
                throw "Installer stdout is not a single JSON object."
            }

            $parsedResult = ConvertFrom-Json $trimmedStdout
            if ($null -eq $parsedResult) {
                throw "Failed to parse installer stdout as JSON."
            }
            if ($parsedResult.GetType().IsArray) {
                throw "Installer stdout parsed as multiple JSON objects."
            }
            if ($parsedResult.ok -ne $true -and $parsedResult.ok -ne 'true') {
                throw "Installer returned failure status (ok is not true)."
            }

            $success = $true
        } else {
            & $installScriptPath @installParameters
            $success = $true
        }
    } catch {
        if ($Json) {
            throw $_
        } else {
            throw $_
        }
    } finally {
        Set-Location $prevCwd
    }

    if ($Json) {
        $outObj = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            ok = $success
            version = $actualVersion
            hash = $expectedHash
            installResult = $parsedResult
        }
        $outObj | ConvertTo-Json -Depth 10
    }

} catch {
    $errMessage = $_.Exception.Message
    if ($Json) {
        $installResult = [ordered]@{
            error = Sanitize-Text $errMessage
        }
        if ($null -ne $stderrFile -and $stderrFile -ne '' -and (Test-Path -LiteralPath $stderrFile)) {
            $rawStderr = Get-Content -LiteralPath $stderrFile -Raw
            $sanitizedStderr = Sanitize-Text $rawStderr
            if ($null -ne $sanitizedStderr -and $sanitizedStderr.Trim() -ne '') {
                $installResult['stderr'] = $sanitizedStderr
            }
        }
        $outObj = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            ok = $false
            version = $actualVersion
            hash = $expectedHash
            installResult = $installResult
        }
        $outObj | ConvertTo-Json -Depth 10
        $bootstrapExitCode = 1
    } else {
        $sanitizedStderr = $null
        if ($null -ne $stderrFile -and $stderrFile -ne '' -and (Test-Path -LiteralPath $stderrFile)) {
            $rawStderr = Get-Content -LiteralPath $stderrFile -Raw
            $sanitizedStderr = Sanitize-Text $rawStderr
        }
        $msg = "Bootstrap failed: $(Sanitize-Text $errMessage)"
        if ($null -ne $sanitizedStderr -and $sanitizedStderr.Trim() -ne '') {
            $msg += "`nStderr:`n$sanitizedStderr"
        }
        throw $msg
    }
} finally {
    try {
        Safe-CleanupDirectory -targetDir $tempDir
    } catch {
        if (-not $Json) {
            Write-Warning "Cleanup warning: $_"
        }
    }
}

if ($bootstrapExitCode -ne 0) {
    exit $bootstrapExitCode
}
