[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Minimal')]
    [string]$Preset = 'Minimal',

    [switch]$NonInteractive,
    [switch]$Json,
    [switch]$InstallFonts,
    [switch]$MigrateFromGlazeWM,
    [switch]$SkipDependencies,
    [switch]$Force,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    throw 'This installer only supports Windows.'
}

# Dot-source common helper
$helperPath = Join-Path $PSScriptRoot 'scripts\KomorebiStarter.Common.ps1'
if (-not (Test-Path -LiteralPath $helperPath)) {
    $helperPath = Join-Path $PSScriptRoot 'scripts\KomorebiStarter.Common.ps1'
}
. $helperPath

$sourceRoot = $PSScriptRoot
$sourceConfig = Join-Path $sourceRoot 'config'
$sourceScripts = Join-Path $sourceRoot 'scripts'

$IsPlanMode = ($WhatIfPreference -eq $true)
if ($IsPlanMode) {
    $WhatIfPreference = $false
}
$plannedActions = New-Object System.Collections.ArrayList

function Write-Step {
    param([string]$Message)
    if ($Quiet) { return }
    if ($Json -or $IsPlanMode) {
        [Console]::Error.WriteLine($Message)
    } else {
        Write-Host $Message -ForegroundColor Cyan
    }
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
}

function Get-InstalledCommand {
    param([string]$CommandName)
    return Resolve-CommonCommand $CommandName
}

function Ensure-Package {
    param(
        [string]$PackageId,
        [string]$CommandName
    )

    Refresh-ProcessPath
    $resolvedPath = Get-InstalledCommand -CommandName $CommandName
    if ($null -ne $resolvedPath) {
        Write-Step "Dependency $CommandName is already installed at $resolvedPath"
        return
    }

    $actionDesc = "Install package $PackageId"
    if ($IsPlanMode) {
        $null = $plannedActions.Add([pscustomobject]@{
            target = "winget package $PackageId"
            action = $actionDesc
        })
        return
    }

    if ($NonInteractive) {
        Write-Step "Installing dependency $PackageId via winget non-interactively..."
    } else {
        Write-Step "Installing dependency $PackageId via winget..."
    }

    if ($PSCmdlet.ShouldProcess("winget package $PackageId", $actionDesc)) {
        $winget = Get-Command winget -ErrorAction Stop
        $arguments = @('install', '--id', $PackageId, '--exact', '--silent', '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements')
        & $winget.Source $arguments | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "winget failed to install $PackageId (exit $LASTEXITCODE)."
        }
        Refresh-ProcessPath
        $newPath = Get-InstalledCommand -CommandName $CommandName
        if ($null -eq $newPath) {
            throw "Failed to locate $CommandName after winget installation."
        }
    }
}

if (-not (Get-Command Send-EnvironmentChangedMessage -ErrorAction SilentlyContinue -CommandType Function)) {
    function Send-EnvironmentChangedMessage {
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

        if ($PSCmdlet.ShouldProcess("Windows Message Broadcast", "Send WM_SETTINGCHANGE for environment update")) {
            $result = [UIntPtr]::Zero
            $null = [KomorebiEnvironmentBroadcaster]::SendMessageTimeout(
                [IntPtr]0xffff,
                0x001A,
                [UIntPtr]::Zero,
                'Environment',
                0x0002,
                3000,
                [ref]$result)
        }
    }
}

# PREFLIGHT 1: Conflict detection
$glazeRunning = [bool](Get-Process -Name glazewm -ErrorAction SilentlyContinue)
$zebarRunning = [bool](Get-Process -Name zebar -ErrorAction SilentlyContinue)

# Conflict check only inspects GlazeWM scheduled task if -MigrateFromGlazeWM is NOT passed?
# Finding 3: "Do not inspect/export/change Glaze task in default ownership beyond conflict preflight."
$glazeTask = Get-ScheduledTask -TaskName 'StartGlazeWM' -ErrorAction SilentlyContinue
$glazeTaskExisted = $null -ne $glazeTask
$glazeTaskEnabled = if ($glazeTaskExisted) { Test-ScheduledTaskEnabled $glazeTask } else { $false }
$glazeProcessRunning = $glazeRunning

if ($glazeRunning -or $zebarRunning -or $glazeTaskEnabled) {
    if (-not $MigrateFromGlazeWM -and -not $IsPlanMode) {
        throw "Conflict detected: GlazeWM or ZeBar is running or its scheduled task is enabled. To migrate, run the installer with the -MigrateFromGlazeWM switch."
    }
}

# Find if previous KomorebiStarter scheduled task exists
$starterTask = Get-ScheduledTask -TaskName 'KomorebiStarter' -ErrorAction SilentlyContinue
$starterTaskExisted = $null -ne $starterTask

# PREFLIGHT 2: User-edited or foreign configuration overwrite check
$existingManifest = $null
$manifestFile = Join-Path $stateHome 'install-manifest.json'
if (Test-Path -LiteralPath $manifestFile -PathType Leaf) {
    try {
        $parsed = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
        if ($null -ne $parsed) {
            Assert-InstallManifestValid -ManifestObj $parsed -ExpectedProductId $productId -ExpectedSchemaVersion $schemaVersion -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome -VerifyBackupLinkage
            $existingManifest = $parsed
        }
    } catch {
        throw "Preflight Error: Existing install-manifest.json is invalid or corrupt: $_"
    }
}

# Target files subject to safety checks
$targetFiles = @(
    (Join-Path $configHome 'komorebi.json'),
    (Join-Path $configHome 'applications.json'),
    (Join-Path $configHome 'applications.local.json'),
    (Join-Path $configHome 'komorebi.bar.json'),
    (Join-Path $configHome 'komorebi.bar.jetbrains.json'),
    (Join-Path $configHome 'whkdrc'),
    (Join-Path $installDir 'wm.ps1'),
    (Join-Path $installDir 'wm.cmd'),
    (Join-Path $installDir 'wm-resize-mode.ps1'),
    (Join-Path $installDir 'start.ps1'),
    (Join-Path $installDir 'change_scale.ps1'),
    (Join-Path $installDir 'doctor.ps1'),
    (Join-Path $installDir 'KomorebiStarter.Common.ps1'),
    (Join-Path $installDir 'restore.ps1'),
    (Join-Path $installDir 'uninstall.ps1'),
    (Join-Path $installDir 'agent-manifest.json')
)

foreach ($file in $targetFiles) {
    $canonicalFile = Get-CanonicalPath $file
    if (Test-Path -LiteralPath $canonicalFile -PathType Leaf) {
        $isProductOwned = $false
        $isUnchanged = $false

        if ($null -ne $existingManifest) {
            $foundEntry = $null
            foreach ($f in $existingManifest.files) {
                if (Get-CanonicalPath $f.path -eq $canonicalFile) {
                    $foundEntry = $f
                    break
                }
            }
            if ($null -ne $foundEntry) {
                $isProductOwned = $true
                $currentHash = Get-FileSHA256 $canonicalFile
                if ($currentHash -ieq $foundEntry.sha256) {
                    $isUnchanged = $true
                }
            }
        }

        if (-not $isProductOwned) {
            if (-not $Force -and -not $IsPlanMode) {
                throw "Preflight Error: Existing foreign file detected at $canonicalFile. Use -Force to overwrite foreign configurations after backing them up."
            }
        } else {
            if (-not $isUnchanged -and -not $Force -and -not $IsPlanMode) {
                throw "Preflight Error: User-edited configuration detected at $canonicalFile. Use -Force to overwrite user-edited files."
            }
        }
    }
}

# Initialize variables for transaction
$tempFetchRoot = Join-Path $env:TEMP ("komorebi-starter-temp-{0}" -f [Guid]::NewGuid().ToString('N'))
$backupRoot = $null
$backupCommitted = $false
$startupResult = $null
$doctorResult = $null

try {
    # [2] Ensuring winget dependencies
    if ($SkipDependencies) {
        Write-Step '[2/8] Using dependencies supplied by the package manager'
    } else {
        Write-Step '[2/8] Ensuring Komorebi, whkd and masir packages'
        Ensure-Package -PackageId 'LGUG2Z.komorebi' -CommandName 'komorebic'
        Ensure-Package -PackageId 'LGUG2Z.whkd' -CommandName 'whkd'
        Ensure-Package -PackageId 'LGUG2Z.masir' -CommandName 'masir'
    }

    if ($InstallFonts) {
        Write-Step 'Ensuring JetBrains Mono Nerd Font via winget...'
        $fontInstalled = (Test-FontInstalled -FontName 'JetBrainsMonoNerdFont') -or (Test-FontInstalled -FontName 'JetBrains Mono')
        if ($fontInstalled) {
            Write-Step "JetBrains Mono Nerd Font is already installed."
        } else {
            $actionDesc = "Install JetBrains Mono Nerd Font"
            if ($IsPlanMode) {
                $null = $plannedActions.Add([pscustomobject]@{
                    target = "winget package DEVCOM.JetBrainsMonoNerdFont"
                    action = $actionDesc
                })
            } else {
                if ($PSCmdlet.ShouldProcess("winget package DEVCOM.JetBrainsMonoNerdFont", $actionDesc)) {
                    $winget = Get-Command winget -ErrorAction Stop
                    $arguments = @('install', '--id', 'DEVCOM.JetBrainsMonoNerdFont', '--exact', '--silent', '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements')
                    & $winget.Source $arguments | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        throw "winget failed to install DEVCOM.JetBrainsMonoNerdFont (exit $LASTEXITCODE)."
                    }
                }
            }
        }
    }

    # [3] Construct merged applications.json in unique temp folder
    Write-Step 'Constructing merged applications.json in a temp folder...'
    if (-not $IsPlanMode) {
        New-Item -ItemType Directory -Path $tempFetchRoot -Force | Out-Null
    }
    $tempApplicationsJson = Join-Path $tempFetchRoot 'applications.json'

    $fetchSuccessful = $false
    if (-not $IsPlanMode) {
        $oldKomorebiConfigHome = $env:KOMOREBI_CONFIG_HOME
        try {
            $env:KOMOREBI_CONFIG_HOME = $tempFetchRoot
            $komorebicExe = Get-InstalledCommand -CommandName 'komorebic'
            if ($null -ne $komorebicExe) {
                $fetchOutput = @(& $komorebicExe fetch-app-specific-configuration 2>&1)
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tempApplicationsJson -PathType Leaf)) {
                    $fetchSuccessful = $true
                } else {
                    Write-Verbose "Upstream application database fetch failed: $($fetchOutput -join [Environment]::NewLine)"
                }
            }
        } catch {
            Write-Verbose "Upstream application database fetch raised an exception; local rules will be used: $_"
        } finally {
            $env:KOMOREBI_CONFIG_HOME = $oldKomorebiConfigHome
        }
    }

    $baseObj = [pscustomobject]@{}
    if ($fetchSuccessful) {
        $baseObj = Get-Content -LiteralPath $tempApplicationsJson -Raw | ConvertFrom-Json
    } else {
        if (-not $IsPlanMode) {
            Write-Step 'Warning: Failed to fetch upstream applications database. Using local rules only.'
        }
    }

    # Load local overlay applications.local.json
    $localOverlaySource = Join-Path $sourceConfig 'applications.local.json'
    $overlayObj = Get-Content -LiteralPath $localOverlaySource -Raw | ConvertFrom-Json
    $merged = [ordered]@{}

    foreach ($property in $baseObj.PSObject.Properties) {
        $merged[$property.Name] = $property.Value
    }
    foreach ($property in $overlayObj.PSObject.Properties) {
        if ($property.Name -eq '$schema') {
            if ($fetchSuccessful) {
                continue
            }
        }
        $merged[$property.Name] = $property.Value
    }

    $mergedJson = [pscustomobject]$merged | ConvertTo-Json -Depth 100
    if (-not $IsPlanMode) {
        [IO.File]::WriteAllText($tempApplicationsJson, $mergedJson, [Text.UTF8Encoding]::new($false))
    }

    # [4] Calculate every desired installed hash
    $installActions = @(
        @{ name = 'komorebi.json'; source = (Join-Path $sourceConfig 'komorebi.json'); dest = (Join-Path $configHome 'komorebi.json'); type = 'config' },
        @{ name = 'applications.local.json'; source = (Join-Path $sourceConfig 'applications.local.json'); dest = (Join-Path $configHome 'applications.local.json'); type = 'config' },
        @{ name = 'komorebi.bar.json'; source = (Join-Path $sourceConfig 'komorebi.bar.json'); dest = (Join-Path $configHome 'komorebi.bar.json'); type = 'config' },
        @{ name = 'komorebi.bar.jetbrains.json'; source = (Join-Path $sourceConfig 'komorebi.bar.jetbrains.json'); dest = (Join-Path $configHome 'komorebi.bar.jetbrains.json'); type = 'config' },
        @{ name = 'whkdrc'; source = (Join-Path $sourceConfig 'whkdrc'); dest = (Join-Path $configHome 'whkdrc'); type = 'config' },
        @{ name = 'applications.json'; source = $tempApplicationsJson; dest = (Join-Path $configHome 'applications.json'); type = 'config' },

        @{ name = 'wm.ps1'; source = (Join-Path $sourceScripts 'wm.ps1'); dest = (Join-Path $installDir 'wm.ps1'); type = 'program' },
        @{ name = 'wm.cmd'; source = (Join-Path $sourceScripts 'wm.cmd'); dest = (Join-Path $installDir 'wm.cmd'); type = 'program' },
        @{ name = 'wm-resize-mode.ps1'; source = (Join-Path $sourceScripts 'wm-resize-mode.ps1'); dest = (Join-Path $installDir 'wm-resize-mode.ps1'); type = 'program' },
        @{ name = 'start.ps1'; source = (Join-Path $sourceScripts 'start.ps1'); dest = (Join-Path $installDir 'start.ps1'); type = 'program' },
        @{ name = 'change_scale.ps1'; source = (Join-Path $sourceScripts 'change_scale.ps1'); dest = (Join-Path $installDir 'change_scale.ps1'); type = 'program' },
        @{ name = 'doctor.ps1'; source = (Join-Path $sourceScripts 'doctor.ps1'); dest = (Join-Path $installDir 'doctor.ps1'); type = 'program' },
        @{ name = 'KomorebiStarter.Common.ps1'; source = (Join-Path $sourceScripts 'KomorebiStarter.Common.ps1'); dest = (Join-Path $installDir 'KomorebiStarter.Common.ps1'); type = 'program' },
        @{ name = 'restore.ps1'; source = (Join-Path $sourceRoot 'restore.ps1'); dest = (Join-Path $installDir 'restore.ps1'); type = 'program' },
        @{ name = 'uninstall.ps1'; source = (Join-Path $sourceRoot 'uninstall.ps1'); dest = (Join-Path $installDir 'uninstall.ps1'); type = 'program' },
        @{ name = 'agent-manifest.json'; source = (Join-Path $sourceRoot 'agent-manifest.json'); dest = (Join-Path $installDir 'agent-manifest.json'); type = 'program' }
    )

    foreach ($act in $installActions) {
        if ($act.name -eq 'applications.json' -and $IsPlanMode) {
            $act.sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
        } else {
            $act.sha256 = Get-FileSHA256 $act.source
        }
    }

    # Verify source existence and desired SHA256 format before backup/mutations
    foreach ($act in $installActions) {
        $skipSrcCheck = ($act.name -eq 'applications.json' -and $IsPlanMode)
        if (-not $skipSrcCheck) {
            if (-not (Test-Path -LiteralPath $act.source -PathType Leaf)) {
                throw "Install source file does not exist: $($act.source)"
            }
        }
        if (-not (Test-Is64Hex $act.sha256)) {
            throw "Desired SHA256 is null or invalid for $($act.name) (Source: $($act.source))"
        }
    }

    # [5] Create complete backups/state/backup manifest and task XML hashes
    Write-Step '[1/8] Capturing a reversible machine backup'
    if ($IsPlanMode) {
        $backupRoot = Join-Path $backupBase "20990101-000000_9999"
    } else {
        $backupRoot = Get-UniqueBackupRoot $backupBase
        if ($PSCmdlet.ShouldProcess($backupRoot, "Create backup folder")) {
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        }
    }

    $backupEntries = New-Object System.Collections.ArrayList
    foreach ($act in $installActions) {
        $dest = $act.dest
        $existed = Test-Path -LiteralPath $dest -PathType Leaf

        $relativeBackup = Join-Path $act.type $act.name
        $backupDest = Join-Path $backupRoot $relativeBackup
        $hash = $null

        if ($existed) {
            $hash = Get-FileSHA256 $dest
            if ($IsPlanMode) {
                $null = $plannedActions.Add([pscustomobject]@{
                    target = $dest
                    action = "Backup existing file to $backupDest"
                })
            } else {
                New-Item -ItemType Directory -Path (Split-Path -Parent $backupDest) -Force | Out-Null
                Copy-Item -LiteralPath $dest -Destination $backupDest -Force
            }
        }

        $null = $backupEntries.Add([ordered]@{
            Source = $dest
            Backup = $backupDest
            SHA256 = $hash
            ExistedBefore = $existed
            InstalledSHA256 = $act.sha256
        })
    }

    # Backup GlazeWM task only if MigrateFromGlazeWM is true
    $glazeTaskXmlSha256 = $null
    if ($MigrateFromGlazeWM -and $glazeTaskExisted) {
        $xmlPath = Join-Path $backupRoot "StartGlazeWM.xml"
        if ($IsPlanMode) {
            $null = $plannedActions.Add([pscustomobject]@{
                target = "Scheduled Task StartGlazeWM"
                action = "Export task configuration to $xmlPath"
            })
            $glazeTaskXmlSha256 = '0000000000000000000000000000000000000000000000000000000000000000'
        } else {
            Export-ScheduledTask -TaskName 'StartGlazeWM' | Set-Content -LiteralPath $xmlPath -Encoding Unicode
            $glazeTaskXmlSha256 = Get-FileSHA256 $xmlPath
        }
    }

    # Backup KomorebiStarter task if it existed
    $starterTaskXmlSha256 = $null
    if ($starterTaskExisted) {
        $xmlPath = Join-Path $backupRoot "KomorebiStarter.xml"
        if ($IsPlanMode) {
            $null = $plannedActions.Add([pscustomobject]@{
                target = "Scheduled Task KomorebiStarter"
                action = "Export task configuration to $xmlPath"
            })
            $starterTaskXmlSha256 = '0000000000000000000000000000000000000000000000000000000000000000'
        } else {
            Export-ScheduledTask -TaskName 'KomorebiStarter' | Set-Content -LiteralPath $xmlPath -Encoding Unicode
            $starterTaskXmlSha256 = Get-FileSHA256 $xmlPath
        }
    }

    $previousKomorebiConfigHome = [Environment]::GetEnvironmentVariable('KOMOREBI_CONFIG_HOME', 'User')
    $previousWhkdConfigHome = [Environment]::GetEnvironmentVariable('WHKD_CONFIG_HOME', 'User')
    $previousUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')

    $stateObj = [ordered]@{
        productId = $productId
        schemaVersion = $schemaVersion
        createdAt = (Get-Date).ToString('o')
        repositoryRoot = $sourceRoot
        glazeMigrated = [bool]$MigrateFromGlazeWM
        glazeTaskExisted = [bool]($MigrateFromGlazeWM -and $glazeTaskExisted)
        glazeTaskEnabled = [bool]($MigrateFromGlazeWM -and $glazeTaskEnabled)
        glazeProcessRunning = [bool]$glazeProcessRunning
        starterTaskExisted = [bool]$starterTaskExisted
    }
    if ($null -ne $glazeTaskXmlSha256) {
        $stateObj['glazeTaskXmlSha256'] = $glazeTaskXmlSha256
    }
    if ($null -ne $starterTaskXmlSha256) {
        $stateObj['starterTaskXmlSha256'] = $starterTaskXmlSha256
    }
    $stateObj['environment'] = [ordered]@{
        KOMOREBI_CONFIG_HOME = $previousKomorebiConfigHome
        WHKD_CONFIG_HOME = $previousWhkdConfigHome
        Path = $previousUserPath
    }
    $stateObj['runningProcesses'] = @(Get-Process -Name glazewm, zebar, komorebi, komorebi-bar, whkd, masir -ErrorAction SilentlyContinue | Select-Object ProcessName, Id)

    $backupManifestObj = [ordered]@{
        productId = $productId
        schemaVersion = $schemaVersion
        files = @($backupEntries)
    }

    $backupStateSHA256 = '0000000000000000000000000000000000000000000000000000000000000000'
    $backupManifestSHA256 = '0000000000000000000000000000000000000000000000000000000000000000'

    if ($IsPlanMode) {
        $null = $plannedActions.Add([pscustomobject]@{
            target = "Backup state and manifest files"
            action = "Write state.json and manifest.json to backup folder"
        })
    } else {
        $stateJsonPath = Join-Path $backupRoot 'state.json'
        $stateObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateJsonPath -Encoding UTF8
        $backupStateSHA256 = Get-FileSHA256 $stateJsonPath

        $manifestJsonPath = Join-Path $backupRoot 'manifest.json'
        $backupManifestObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestJsonPath -Encoding UTF8
        $backupManifestSHA256 = Get-FileSHA256 $manifestJsonPath

        Set-Content -LiteralPath (Join-Path $backupBase 'LATEST.txt') -Value $backupRoot -Encoding ASCII
        $baselinePointer = Join-Path $backupBase 'BASELINE.txt'
        if (-not (Test-Path -LiteralPath $baselinePointer)) {
            Set-Content -LiteralPath $baselinePointer -Value $backupRoot -Encoding ASCII
        }
    }

    # Backup commit point
    if (-not $IsPlanMode) {
        $backupCommitted = $true
    }

    # [6] Deploy files
    Write-Step '[3/8] Deploying configuration and agent commands'
    if ($IsPlanMode) {
        $null = $plannedActions.Add([pscustomobject]@{
            target = $configHome
            action = "Create configuration directory"
        })
        $null = $plannedActions.Add([pscustomobject]@{
            target = $installDir
            action = "Create program installation directory"
        })
    } else {
        if (-not (Test-Path -LiteralPath $configHome)) {
            New-Item -ItemType Directory -Path $configHome -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        }
    }

    $installedFiles = New-Object System.Collections.ArrayList
    foreach ($act in $installActions) {
        $src = $act.source
        $dest = $act.dest

        if ($IsPlanMode) {
            $null = $plannedActions.Add([pscustomobject]@{
                target = $dest
                action = "Deploy $($act.type) file $($act.name)"
            })
        } else {
            Copy-Item -LiteralPath $src -Destination $dest -Force
            if ($act.type -eq 'program') {
                Unblock-File -LiteralPath $dest -ErrorAction SilentlyContinue
            }
        }

        $null = $installedFiles.Add([ordered]@{
            path = Get-CanonicalPath $dest
            sha256 = $act.sha256
            type = $act.type
        })
    }

    # [7] Set up environment variables
    if ($IsPlanMode) {
        $null = $plannedActions.Add([pscustomobject]@{
            target = "User Environment Variables"
            action = "Set KOMOREBI_CONFIG_HOME and WHKD_CONFIG_HOME"
        })
        $null = $plannedActions.Add([pscustomobject]@{
            target = "User Path"
            action = "Add $installDir to User Path"
        })
        $null = $plannedActions.Add([pscustomobject]@{
            target = "Windows Message Broadcast"
            action = "Send WM_SETTINGCHANGE for environment update"
        })
    } else {
        Set-UserEnvironmentVariable 'KOMOREBI_CONFIG_HOME' $configHome
        Set-UserEnvironmentVariable 'WHKD_CONFIG_HOME' $configHome
        $env:KOMOREBI_CONFIG_HOME = $configHome
        $env:WHKD_CONFIG_HOME = $configHome

        # Update Path Entry
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $entries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $exists = @($entries | Where-Object { $_.TrimEnd('\') -ieq $installDir.TrimEnd('\') }).Count -gt 0
        if (-not $exists) {
            $newPath = (@($entries) + $installDir) -join ';'
            Set-UserEnvironmentVariable 'Path' $newPath
        }
        $env:Path = @($env:Path, $installDir) -join ';'

        Send-EnvironmentChangedMessage
    }

    # [8] Migrate from GlazeWM if specified
    if ($MigrateFromGlazeWM) {
        Write-Step '[4/8] Disabling GlazeWM startup scheduled task'
        if ($glazeTaskExisted -and $glazeTaskEnabled) {
            if ($IsPlanMode) {
                $null = $plannedActions.Add([pscustomobject]@{
                    target = "Scheduled Task StartGlazeWM"
                    action = "Disable GlazeWM logon scheduled task"
                })
            } else {
                Disable-ScheduledTask -TaskName 'StartGlazeWM' -ErrorAction Stop | Out-Null
            }
        }
    }

    # [9] Scheduled task creation for KomorebiStarter
    Write-Step '[5/8] Creating KomorebiStarter logon scheduled task'
    if ($IsPlanMode) {
        $null = $plannedActions.Add([pscustomobject]@{
            target = "Scheduled Task KomorebiStarter"
            action = "Register logon scheduled task for KomorebiStarter"
        })
    } else {
        $taskScript = Join-Path $installDir 'start.ps1'
        $actionArguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$taskScript`" -DelayMilliseconds 1500"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
        $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName 'KomorebiStarter' -Description 'Start Komorebi starter stack dynamically.' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    }

    # [10] Start the stack
    Write-Step '[7/8] Switching the live desktop to Komorebi Starter'
    if ($IsPlanMode) {
        $null = $plannedActions.Add([pscustomobject]@{
            target = "live desktop"
            action = "Start the Komorebi Starter stack"
        })
    } else {
        $startScriptFile = Join-Path $installDir 'start.ps1'
        if (Test-Path -LiteralPath $startScriptFile) {
            $startupText = (& $startScriptFile -Restart -CleanState 2>&1 | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
            try {
                $startupResult = $startupText | ConvertFrom-Json
            } catch {
                throw "Startup did not output valid JSON: $startupText"
            }
            if ($null -eq $startupResult -or $startupResult.ok -ne $true) {
                throw "Startup failed with unhealthy status."
            }
        }
    }

    # [11] Health check / Doctor
    Write-Step '[8/8] Running local verification'
    if ($IsPlanMode) {
        $null = $plannedActions.Add([pscustomobject]@{
            target = "health diagnostic"
            action = "Run doctor check"
        })
    } else {
        $doctorScriptFile = Join-Path $installDir 'doctor.ps1'
        if (Test-Path -LiteralPath $doctorScriptFile) {
            $doctorText = (& $doctorScriptFile -Json -NoExitCode 2>&1 | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
            try {
                $doctorResult = $doctorText | ConvertFrom-Json
            } catch {
                throw "Doctor did not output valid JSON: $doctorText"
            }
            if ($null -eq $doctorResult -or $doctorResult.ok -ne $true) {
                throw "Doctor failed with unhealthy status."
            }
        }
    }

    # Calculate versioned ancestry fields for the install manifest
    $newBaselineBackupRoot = $null
    $baselineBackupStateSHA256 = $null
    $baselineBackupManifestSHA256 = $null

    if ($null -ne $existingManifest -and $null -ne $existingManifest.baselineBackupRoot) {
        $newBaselineBackupRoot = $existingManifest.baselineBackupRoot
        $baselineBackupStateSHA256 = $existingManifest.baselineBackupStateSHA256
        $baselineBackupManifestSHA256 = $existingManifest.baselineBackupManifestSHA256
    } else {
        $newBaselineBackupRoot = $backupRoot
        $baselineBackupStateSHA256 = $backupStateSHA256
        $baselineBackupManifestSHA256 = $backupManifestSHA256
    }

    $newGlazeBackupRoot = $null
    $glazeBackupStateSHA256 = $null
    $glazeBackupManifestSHA256 = $null

    if ($null -ne $existingManifest -and $null -ne $existingManifest.glazeBackupRoot) {
        $newGlazeBackupRoot = $existingManifest.glazeBackupRoot
        $glazeBackupStateSHA256 = $existingManifest.glazeBackupStateSHA256
        $glazeBackupManifestSHA256 = $existingManifest.glazeBackupManifestSHA256
    } elseif ($MigrateFromGlazeWM) {
        $newGlazeBackupRoot = $backupRoot
        $glazeBackupStateSHA256 = $backupStateSHA256
        $glazeBackupManifestSHA256 = $backupManifestSHA256
    }

    # [12] Write install-manifest.json last
    $manifestObj = [ordered]@{
        productId = $productId
        schemaVersion = $schemaVersion
        installDir = $installDir
        configHome = $configHome
        backupRoot = $backupRoot
        backupStateSHA256 = $backupStateSHA256
        backupManifestSHA256 = $backupManifestSHA256
        baselineBackupRoot = $newBaselineBackupRoot
        baselineBackupStateSHA256 = $baselineBackupStateSHA256
        baselineBackupManifestSHA256 = $baselineBackupManifestSHA256
        glazeBackupRoot = $newGlazeBackupRoot
        glazeBackupStateSHA256 = $glazeBackupStateSHA256
        glazeBackupManifestSHA256 = $glazeBackupManifestSHA256
        migrateFromGlazeWM = [bool]$MigrateFromGlazeWM
        scheduledTasks = @('KomorebiStarter')
        files = @($installedFiles)
    }

    if ($IsPlanMode) {
        $null = $plannedActions.Add([pscustomobject]@{
            target = $manifestFile
            action = "Write install-manifest.json"
        })
    } else {
        $manifestObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestFile -Encoding UTF8
    }

} catch {
    $originalException = $_
    if ($backupCommitted) {
        Write-Step "Installation failed. Initiating transaction rollback..."
        try {
            $restoreScript = Join-Path $sourceRoot 'restore.ps1'
            & $restoreScript -BackupRoot $backupRoot -NoStart -Quiet | Out-Null
        } catch {
            throw "Installation failed: $($originalException.Exception.Message). Rollback also failed: $($_.Exception.Message)"
        }
    }
    throw $originalException
} finally {
    if (-not $IsPlanMode -and $null -ne $tempFetchRoot -and (Test-Path -LiteralPath $tempFetchRoot)) {
        $canonicalTempRoot = Get-CanonicalPath $tempFetchRoot
        $canonicalTempEnv = Get-CanonicalPath $env:TEMP
        if (Test-IsChildOf $canonicalTempRoot $canonicalTempEnv) {
            if (-not (Test-IsReparsePoint $canonicalTempRoot)) {
                Remove-Item -LiteralPath $canonicalTempRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
}

if ($IsPlanMode) {
    $result = [pscustomobject]@{
        ok = $true
        preset = $Preset
        installDir = $installDir
        configHome = $configHome
        backup = $backupRoot
        planned = $true
        plannedActions = @($plannedActions)
    }
} else {
    $result = [pscustomobject]@{
        ok = if ($null -ne $doctorResult) { $doctorResult.ok } else { $true }
        preset = $Preset
        installDir = $installDir
        configHome = $configHome
        backup = $backupRoot
        started = ($null -ne $startupResult)
        startup = $startupResult
        doctor = $doctorResult
    }
}

if ($Json -or $IsPlanMode) {
    $result | ConvertTo-Json -Depth 8
} else {
    Write-Host "Installation completed successfully!" -ForegroundColor Green
    $result | ConvertTo-Json -Depth 3
}
