[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BackupRoot,
    [switch]$NoStart,
    [switch]$Json,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source common helper
$helperPath = Join-Path $PSScriptRoot 'scripts\KomorebiStarter.Common.ps1'
if (-not (Test-Path -LiteralPath $helperPath)) {
    $helperPath = Join-Path $PSScriptRoot 'KomorebiStarter.Common.ps1'
}
. $helperPath

function Write-Step {
    param([string]$Message)
    if ($Quiet) { return }
    if ($Json) {
        [Console]::Error.WriteLine($Message)
    } else {
        Write-Host $Message -ForegroundColor Cyan
    }
}

if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $manifestFile = Join-Path $stateHome 'install-manifest.json'
    if (Test-Path -LiteralPath $manifestFile -PathType Leaf) {
        try {
            $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
            Assert-InstallManifestValid -ManifestObj $manifest -ExpectedProductId $productId -ExpectedSchemaVersion $schemaVersion -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome -VerifyBackupLinkage
            $BackupRoot = $manifest.baselineBackupRoot
            Write-Step "Resolved BackupRoot from install-manifest baseline: $BackupRoot"
        } catch {
            throw "Failed to resolve BackupRoot: install-manifest.json is present but invalid: $_"
        }
    } else {
        $pointerPath = Join-Path $backupBase 'BASELINE.txt'
        if (-not (Test-Path -LiteralPath $pointerPath)) {
            $pointerPath = Join-Path $backupBase 'LATEST.txt'
        }
        if (-not (Test-Path -LiteralPath $pointerPath)) {
            throw "No install-manifest.json found and no baseline or latest backup pointer found under $backupBase"
        }
        $BackupRoot = (Get-Content -LiteralPath $pointerPath -Raw).Trim()
        Write-Step "Resolved BackupRoot from pointer: $BackupRoot"
    }
}

$canonicalBackupRoot = Get-CanonicalPath $BackupRoot
$canonicalBackupBase = Get-CanonicalPath $backupBase

# Verify BackupRoot is a direct timestamped child of backupBase
$parentDir = Get-CanonicalPath (Split-Path -Parent $canonicalBackupRoot)
$leafName = Split-Path -Leaf $canonicalBackupRoot

if ($parentDir -ine $canonicalBackupBase -or $leafName -notmatch '^\d{8}-\d{6}(?:_\d+)?$') {
    throw "Invalid backup root directory: $BackupRoot. It must be a direct timestamped child of $backupBase."
}

if (-not (Test-Path -LiteralPath $canonicalBackupRoot -PathType Container)) {
    throw "Backup directory not found: $canonicalBackupRoot"
}

# Reject backup root if it is a reparse point
if (Test-IsReparsePoint $canonicalBackupRoot) {
    throw "Backup root is a reparse point: $canonicalBackupRoot"
}

$statePath = Join-Path $canonicalBackupRoot 'state.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "Backup state.json not found: $statePath"
}
if (Test-IsReparsePoint $statePath) {
    throw "state.json is a reparse point: $statePath"
}

try {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
} catch {
    throw "Malformed state.json: $_"
}

$manifestPath = Join-Path $canonicalBackupRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Backup manifest.json not found: $manifestPath"
}
if (Test-IsReparsePoint $manifestPath) {
    throw "manifest.json is a reparse point: $manifestPath"
}

try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
} catch {
    throw "Malformed manifest.json: $_"
}

# PREFLIGHT VERIFICATION
Assert-StateValid -StateObj $state -ExpectedProductId $productId -ExpectedSchemaVersion $schemaVersion
Assert-ManifestValid -ManifestObj $manifest -ExpectedProductId $productId -ExpectedSchemaVersion $schemaVersion -BackupRoot $canonicalBackupRoot -AllowedDestinations $allowedDestinations

# If glazeMigrated and glazeTaskExisted are both true, verify exact XML backup before any mutation
if ($state.glazeMigrated -and $state.glazeTaskExisted) {
    $glazeTaskXml = Join-Path $canonicalBackupRoot 'StartGlazeWM.xml'
    if (-not (Test-Path -LiteralPath $glazeTaskXml -PathType Leaf)) {
        throw "StartGlazeWM.xml not found in backup root"
    }
    if (Test-IsReparsePoint $glazeTaskXml) {
        throw "StartGlazeWM.xml is a reparse point"
    }
    $xmlHash = Get-FileSHA256 $glazeTaskXml
    if ($xmlHash -ine $state.glazeTaskXmlSha256) {
        throw "StartGlazeWM.xml hash mismatch: expected $($state.glazeTaskXmlSha256) but got $xmlHash"
    }
}

# If starterTaskExisted is true, verify exact XML backup before any mutation
if ($state.starterTaskExisted) {
    $starterTaskXml = Join-Path $canonicalBackupRoot 'KomorebiStarter.xml'
    if (-not (Test-Path -LiteralPath $starterTaskXml -PathType Leaf)) {
        throw "KomorebiStarter.xml not found in backup root"
    }
    if (Test-IsReparsePoint $starterTaskXml) {
        throw "KomorebiStarter.xml is a reparse point"
    }
    $xmlHash = Get-FileSHA256 $starterTaskXml
    if ($xmlHash -ine $state.starterTaskXmlSha256) {
        throw "KomorebiStarter.xml hash mismatch: expected $($state.starterTaskXmlSha256) but got $xmlHash"
    }
}

# DRY RUN PREPARATION
$isDryRun = $WhatIfPreference -or $PSBoundParameters.ContainsKey('WhatIf')
$plannedActions = New-Object System.Collections.ArrayList
$skippedModifiedFiles = New-Object System.Collections.ArrayList
$restoredFiles = New-Object System.Collections.ArrayList
$restoredGlazeTask = $false
$startedGlaze = $false

function Invoke-ShouldProcess {
    param([string]$Target, [string]$Action)
    if ($isDryRun) {
        $null = $plannedActions.Add([pscustomobject]@{
            target = $Target
            action = $Action
        })
        return $false
    }
    return $PSCmdlet.ShouldProcess($Target, $Action)
}

Write-Step "Stopping Komorebi stack before restoration..."
if (Invoke-ShouldProcess 'Komorebi Stack' 'Stop all running Komorebi processes') {
    Stop-Process -Name komorebi, komorebi-bar, whkd, masir -Force -ErrorAction SilentlyContinue
}

# Perform restorations and removals
foreach ($entry in $manifest.files) {
    $src = Get-CanonicalPath $entry.Source
    $bak = Get-CanonicalPath $entry.Backup
    $existedBefore = [bool]$entry.ExistedBefore

    if ($existedBefore) {
        $parent = Split-Path -Parent $src
        if (Invoke-ShouldProcess $src "Restore file from backup") {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            Copy-Item -LiteralPath $bak -Destination $src -Force
            $null = $restoredFiles.Add($src)
        }
    } else {
        # File did not exist before. Remove only if it matches the installed SHA256 (unchanged).
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            $currentHash = Get-FileSHA256 $src
            # Never remove unless InstalledSHA256 is exactly 64 hex and current hash is exactly 64 hex and equal.
            if ($null -ne $currentHash -and $null -ne $entry.InstalledSHA256 -and (Test-Is64Hex $currentHash) -and (Test-Is64Hex $entry.InstalledSHA256) -and ($currentHash -ieq $entry.InstalledSHA256)) {
                if (Invoke-ShouldProcess $src "Remove unchanged product-created file") {
                    Remove-Item -LiteralPath $src -Force
                }
            } else {
                $null = $skippedModifiedFiles.Add($src)
            }
        }
    }
}

# Restore environment variables and user Path
$prevKomorebiConfigHome = $state.environment.KOMOREBI_CONFIG_HOME
$prevWhkdConfigHome = $state.environment.WHKD_CONFIG_HOME
$prevUserPath = $state.environment.Path

if (Invoke-ShouldProcess "User environment variables", "Restore original environment values") {
    [Environment]::SetEnvironmentVariable('KOMOREBI_CONFIG_HOME', $prevKomorebiConfigHome, 'User')
    [Environment]::SetEnvironmentVariable('WHKD_CONFIG_HOME', $prevWhkdConfigHome, 'User')
    if ($null -ne $prevUserPath) {
        [Environment]::SetEnvironmentVariable('Path', $prevUserPath, 'User')
    }
}

# Restore or remove KomorebiStarter scheduled task
if ($state.starterTaskExisted) {
    $starterTaskXml = Join-Path $canonicalBackupRoot 'KomorebiStarter.xml'
    if (Invoke-ShouldProcess 'KomorebiStarter scheduled task' 'Register original KomorebiStarter scheduled task') {
        Register-ScheduledTask -TaskName 'KomorebiStarter' -Xml (Get-Content -LiteralPath $starterTaskXml -Raw) -Force -ErrorAction Stop | Out-Null
    }
} else {
    $hasKomorebiTask = $false
    try {
        if (Get-ScheduledTask -TaskName 'KomorebiStarter' -ErrorAction SilentlyContinue) {
            $hasKomorebiTask = $true
        }
    } catch {
        Write-Verbose "Could not query the KomorebiStarter scheduled task; no removal will be planned: $_"
    }

    if ($hasKomorebiTask) {
        if (Invoke-ShouldProcess 'KomorebiStarter scheduled task' 'Unregister startup task') {
            Unregister-ScheduledTask -TaskName 'KomorebiStarter' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

# Restore GlazeWM state only if it was migrated/changed by this install
if ($state.glazeMigrated) {
    # Restore scheduled task if both migrated and existed are true
    if ($state.glazeMigrated -and $state.glazeTaskExisted) {
        $glazeTaskXml = Join-Path $canonicalBackupRoot 'StartGlazeWM.xml'
        if (Invoke-ShouldProcess 'StartGlazeWM scheduled task' 'Register original GlazeWM startup task') {
            Register-ScheduledTask -TaskName 'StartGlazeWM' -Xml (Get-Content -LiteralPath $glazeTaskXml -Raw) -Force -ErrorAction Stop | Out-Null
            if (-not $state.glazeTaskEnabled) {
                Disable-ScheduledTask -TaskName 'StartGlazeWM' -ErrorAction SilentlyContinue | Out-Null
            }
            $restoredGlazeTask = $true
        }
    }

    # Start GlazeWM if it was running before and -NoStart is not supplied
    if (-not $NoStart -and $state.glazeProcessRunning) {
        $glazeCmd = Resolve-CommonCommand 'glazewm'
        if ($glazeCmd) {
            if (Invoke-ShouldProcess 'GlazeWM process' 'Start GlazeWM window manager') {
                Stop-Process -Name glazewm, glazewm-watcher, zebar -Force -ErrorAction SilentlyContinue
                Start-Process -FilePath $glazeCmd -WindowStyle Hidden | Out-Null
                $startedGlaze = $true
            }
        }
    }
}

$restoreReport = [ordered]@{
    ok = $true
    productId = $productId
    schemaVersion = $schemaVersion
    planned = $isDryRun
    plannedActions = @($plannedActions)
    skippedModifiedFiles = @($skippedModifiedFiles)
    backup = $canonicalBackupRoot
    restoredFiles = @($restoredFiles)
    restoredGlazeTask = $restoredGlazeTask
    startedGlaze = $startedGlaze
}

if ($Json) {
    $restoreReport | ConvertTo-Json -Depth 5
} else {
    Write-Host "Restoration completed successfully!" -ForegroundColor Green
    $restoreReport | ConvertTo-Json -Depth 2
}
