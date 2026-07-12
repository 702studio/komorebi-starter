[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$RemoveConfig,
    [switch]$Force,
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

$manifestFile = Join-Path $stateHome 'install-manifest.json'
if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
    throw "Install manifest not found at $manifestFile. Cannot proceed with uninstall."
}

try {
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
} catch {
    throw "Malformed install-manifest.json: $_"
}

$expectedInstallDir = Get-CanonicalPath $installDir
$expectedConfigHome = Get-CanonicalPath $configHome

# Validate product/schema/roots using strict assertion before first mutation
Assert-InstallManifestValid -ManifestObj $manifest -ExpectedProductId $productId -ExpectedSchemaVersion $schemaVersion -ExpectedInstallDir $expectedInstallDir -ExpectedConfigHome $expectedConfigHome -VerifyBackupLinkage

$baselineStateFile = Join-Path $manifest.baselineBackupRoot 'state.json'
if (-not (Test-Path -LiteralPath $baselineStateFile -PathType Leaf)) {
    throw "Baseline backup state not found: $baselineStateFile"
}
try {
    $baselineState = Get-Content -LiteralPath $baselineStateFile -Raw | ConvertFrom-Json
} catch {
    throw "Malformed baseline backup state: $_"
}
Assert-StateValid -StateObj $baselineState -ExpectedProductId $productId -ExpectedSchemaVersion $schemaVersion

$prevKomorebiConfigHome = $baselineState.environment.KOMOREBI_CONFIG_HOME
$prevWhkdConfigHome = $baselineState.environment.WHKD_CONFIG_HOME

$baselineManifest = $null
if ($RemoveConfig) {
    $baselineManifestFile = Join-Path $manifest.baselineBackupRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $baselineManifestFile -PathType Leaf)) {
        throw "Baseline backup manifest not found: $baselineManifestFile"
    }
    try {
        $baselineManifest = Get-Content -LiteralPath $baselineManifestFile -Raw | ConvertFrom-Json
    } catch {
        throw "Malformed baseline backup manifest: $_"
    }
    Assert-ManifestValid -ManifestObj $baselineManifest -ExpectedProductId $productId -ExpectedSchemaVersion $schemaVersion -BackupRoot $manifest.baselineBackupRoot -AllowedDestinations $allowedDestinations
}

# Plan mode variables
$IsPlanMode = ($WhatIfPreference -eq $true)
if ($IsPlanMode) {
    $WhatIfPreference = $false
}
$plannedActions = New-Object System.Collections.ArrayList
$skippedModifiedFiles = New-Object System.Collections.ArrayList
$removedFiles = New-Object System.Collections.ArrayList
$removedConfigs = New-Object System.Collections.ArrayList

function Invoke-ShouldProcess {
    param([string]$Target, [string]$Action)
    if ($IsPlanMode) {
        $null = $plannedActions.Add([pscustomobject]@{
            target = $Target
            action = $Action
        })
        return $false
    }
    return $PSCmdlet.ShouldProcess($Target, $Action)
}

# [1] Stop Komorebi environment
Write-Step 'Stopping any running Komorebi environments...'
if (Invoke-ShouldProcess 'Komorebi Stack' 'Stop all processes (komorebi, whkd, masir, komorebi-bar)') {
    Get-Process -Name komorebi, komorebi-bar, whkd, masir -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            if ($_.MainWindowHandle -ne 0) {
                $null = $_.CloseMainWindow()
            }
        } catch {
            Write-Verbose "Graceful process close failed; forced cleanup will continue: $_"
        }
    }
    Start-Sleep -Seconds 1
    Stop-Process -Name komorebi, komorebi-bar, whkd, masir -Force -ErrorAction SilentlyContinue | Out-Null
}

# [2] Remove scheduled tasks (allowlist only!)
if ($baselineState.starterTaskExisted) {
    $starterTaskXml = Join-Path $manifest.baselineBackupRoot 'KomorebiStarter.xml'
    if (Invoke-ShouldProcess 'KomorebiStarter scheduled task' 'Restore original KomorebiStarter scheduled task') {
        Register-ScheduledTask -TaskName 'KomorebiStarter' -Xml (Get-Content -LiteralPath $starterTaskXml -Raw) -Force -ErrorAction Stop | Out-Null
    }
} else {
    if (Get-ScheduledTask -TaskName 'KomorebiStarter' -ErrorAction SilentlyContinue) {
        if (Invoke-ShouldProcess 'KomorebiStarter scheduled task' 'Remove scheduled task') {
            Unregister-ScheduledTask -TaskName 'KomorebiStarter' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

# [3] Remove files
$manifestFiles = @($manifest.files)
foreach ($fileEntry in $manifestFiles) {
    $filePath = Get-CanonicalPath $fileEntry.path
    if ($fileEntry.type -eq 'program') {
        # Ensure path is strictly under the fixed install root
        if (Test-IsChildOf $filePath $expectedInstallDir) {
            if (Test-Path -LiteralPath $filePath -PathType Leaf) {
                $currentHash = Get-FileSHA256 $filePath
                $manifestHash = $fileEntry.sha256
                $isUnchanged = ($null -ne $currentHash -and $null -ne $manifestHash -and (Test-Is64Hex $currentHash) -and ($currentHash -ieq $manifestHash))

                if ($isUnchanged -or $Force) {
                    if (Invoke-ShouldProcess $filePath "Delete installed file") {
                        Remove-Item -LiteralPath $filePath -Force
                        $null = $removedFiles.Add($filePath)
                    }
                } else {
                    $null = $skippedModifiedFiles.Add($filePath)
                }
            }
        }
    } elseif ($fileEntry.type -eq 'config') {
        if ($RemoveConfig) {
            # Ensure path is strictly under the fixed config root
            if (Test-IsChildOf $filePath $expectedConfigHome) {
                if (Test-Path -LiteralPath $filePath -PathType Leaf) {
                    $currentHash = Get-FileSHA256 $filePath
                    $manifestHash = $fileEntry.sha256
                    $isUnchanged = ($null -ne $currentHash -and $null -ne $manifestHash -and (Test-Is64Hex $currentHash) -and ($currentHash -ieq $manifestHash))

                    # Find corresponding baseline entry
                    $baselineEntry = $null
                    foreach ($be in $baselineManifest.files) {
                        $canonicalSource = Get-CanonicalPath $be.Source
                        if ([string]::Equals($canonicalSource, $filePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $baselineEntry = $be
                            break
                        }
                    }
                    if ($null -eq $baselineEntry) {
                        throw "Config file $filePath not found in baseline backup manifest."
                    }

                    $existedBefore = [bool]$baselineEntry.ExistedBefore
                    if ($existedBefore) {
                        if ($isUnchanged -or $Force) {
                            if (Invoke-ShouldProcess $filePath "Restore original config from baseline backup") {
                                $parent = Split-Path -Parent $filePath
                                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                                Copy-Item -LiteralPath $baselineEntry.Backup -Destination $filePath -Force
                                $null = $removedConfigs.Add($filePath)
                            }
                        } else {
                            $null = $skippedModifiedFiles.Add($filePath)
                        }
                    } else {
                        if ($isUnchanged -or $Force) {
                            if (Invoke-ShouldProcess $filePath "Delete configuration file") {
                                Remove-Item -LiteralPath $filePath -Force
                                $null = $removedConfigs.Add($filePath)
                            }
                        } else {
                            $null = $skippedModifiedFiles.Add($filePath)
                        }
                    }
                }
            }
        }
    }
}

# [4] Restore environment variables
if (Invoke-ShouldProcess "User environment variables", "Restore to previous or null values") {
    [Environment]::SetEnvironmentVariable('KOMOREBI_CONFIG_HOME', $prevKomorebiConfigHome, 'User')
    [Environment]::SetEnvironmentVariable('WHKD_CONFIG_HOME', $prevWhkdConfigHome, 'User')
}

# [5] Restore GlazeWM startup task if it was migrated/changed by this install
if ($null -ne $manifest.glazeBackupRoot) {
    $glazeStateFile = Join-Path $manifest.glazeBackupRoot 'state.json'
    if (Test-Path -LiteralPath $glazeStateFile -PathType Leaf) {
        $glazeState = Get-Content -LiteralPath $glazeStateFile -Raw | ConvertFrom-Json
        # Call Assert-StateValid on the glaze state
        Assert-StateValid -StateObj $glazeState -ExpectedProductId $productId -ExpectedSchemaVersion $schemaVersion

        if ($glazeState.glazeTaskExisted) {
            $glazeTaskXml = Join-Path $manifest.glazeBackupRoot 'StartGlazeWM.xml'
            if (-not (Test-Path -LiteralPath $glazeTaskXml -PathType Leaf)) {
                throw "Original GlazeWM task backup file not found: $glazeTaskXml"
            }
            # Verify StartGlazeWM.xml hash equals glazeTaskXmlSha256 before any task mutation
            $xmlHash = Get-FileSHA256 $glazeTaskXml
            if ($xmlHash -ine $glazeState.glazeTaskXmlSha256) {
                throw "StartGlazeWM.xml hash mismatch: expected $($glazeState.glazeTaskXmlSha256), actual $xmlHash"
            }

            if (Invoke-ShouldProcess 'StartGlazeWM scheduled task' 'Restore original GlazeWM startup task') {
                Register-ScheduledTask -TaskName 'StartGlazeWM' -Xml (Get-Content -LiteralPath $glazeTaskXml -Raw) -Force -ErrorAction Stop | Out-Null
                if (-not $glazeState.glazeTaskEnabled) {
                    Disable-ScheduledTask -TaskName 'StartGlazeWM' -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }
    }
}

# [6] Clean User Path (boundary-safe and preserving post-install entries)
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$entries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$newEntries = @()
foreach ($entry in $entries) {
    $isMatch = $false
    try {
        $canonicalEntry = [System.IO.Path]::GetFullPath($entry)
        if ($canonicalEntry -ieq $expectedInstallDir) {
            $isMatch = $true
        }
    } catch {
        Write-Verbose "Keeping malformed user PATH entry unchanged: $entry"
    }
    if (-not $isMatch) {
        $newEntries += $entry
    }
}
if ($entries.Count -ne $newEntries.Count) {
    if (Invoke-ShouldProcess "Path environment variable", "Remove $expectedInstallDir from User Path") {
        $newPath = $newEntries -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }
}

# [7] Cleanup empty program directory and manifest file
if (Test-Path -LiteralPath $expectedInstallDir -PathType Container) {
    $files = Get-ChildItem -LiteralPath $expectedInstallDir -Force -ErrorAction SilentlyContinue
    if ($null -eq $files -or $files.Count -eq 0) {
        if (Invoke-ShouldProcess $expectedInstallDir "Remove empty program directory") {
            Remove-Item -LiteralPath $expectedInstallDir -Force
        }
    }
}

if (Invoke-ShouldProcess $manifestFile "Remove manifest file") {
    Remove-Item -LiteralPath $manifestFile -Force
}

# [8] Send change broadcast
if (Invoke-ShouldProcess "Broadcast message", "Notify environment changed") {
    if (-not ('KomorebiEnvironmentBroadcaster' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class KomorebiEnvironmentBroadcaster
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint message,
        UIntPtr wParam,
        string lParam,
        uint flags,
        uint timeout,
        out UIntPtr result);
}
'@
    }
    $resultMsg = [UIntPtr]::Zero
    $null = [KomorebiEnvironmentBroadcaster]::SendMessageTimeout(
        [IntPtr]0xffff,
        0x001A,
        [UIntPtr]::Zero,
        'Environment',
        0x0002,
        3000,
        [ref]$resultMsg)
}

$uninstallReport = [pscustomobject]@{
    ok = $true
    planned = $IsPlanMode
    plannedActions = @($plannedActions)
    removedFiles = @($removedFiles)
    removedConfigs = @($removedConfigs)
    skippedModifiedFiles = @($skippedModifiedFiles)
    restoredKomorebiHome = $prevKomorebiConfigHome
    restoredWhkdHome = $prevWhkdConfigHome
    backupRoot = $manifest.backupRoot
    baselineBackupRoot = $manifest.baselineBackupRoot
    glazeBackupRoot = $manifest.glazeBackupRoot
}

if ($Json) {
    $uninstallReport | ConvertTo-Json -Depth 5
} else {
    Write-Host "Uninstallation completed successfully!" -ForegroundColor Green
    $uninstallReport | ConvertTo-Json -Depth 2
}
