# KomorebiStarter Common Helper Functions
# Windows PowerShell 5.1 Compatible

$productId = '702studio.komorebi-starter'
$schemaVersion = 1

$stateHome = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'KomorebiStarter'
$backupBase = Join-Path $stateHome 'backups'
$configHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\komorebi'
$installDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\KomorebiStarter'

# Strict allowlist of target files that can be modified/restored
$allowedDestinations = @(
    (Join-Path $configHome 'komorebi.json'),
    (Join-Path $configHome 'applications.json'),
    (Join-Path $configHome 'applications.local.json'),
    (Join-Path $configHome 'komorebi.bar.json'),
    (Join-Path $configHome 'komorebi.bar.jetbrains.json'),
    (Join-Path $configHome 'whkdrc'),
    (Join-Path $installDir 'FocusInterop.cs'),
    (Join-Path $installDir 'FocusInterop.dll'),
    (Join-Path $installDir 'FocusInterop.ps1'),
    (Join-Path $installDir 'focus-diagnostics.ps1'),
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

function Test-Is64Hex {
    param([string]$Hash)
    if ([string]::IsNullOrEmpty($Hash)) { return $false }
    return $Hash -match '^[a-fA-F0-9]{64}$'
}

function Assert-StateValid {
    param(
        $StateObj,
        [string]$ExpectedProductId,
        [int]$ExpectedSchemaVersion
    )
    if ($null -eq $StateObj) {
        throw "State object is null"
    }

    # Validate productId type and value
    $pIdProp = $StateObj.PSObject.Properties['productId']
    if ($null -eq $pIdProp -or $null -eq $pIdProp.Value -or $pIdProp.Value.GetType().FullName -ne 'System.String') {
        throw "Property 'productId' must be a string in state.json"
    }
    if ($pIdProp.Value -ne $ExpectedProductId) {
        throw "Invalid productId in state.json: $($pIdProp.Value)"
    }

    # Validate schemaVersion type and value
    $sVerProp = $StateObj.PSObject.Properties['schemaVersion']
    if ($null -eq $sVerProp -or $null -eq $sVerProp.Value -or ($sVerProp.Value.GetType().FullName -notmatch 'System\.(Int32|Int64)')) {
        throw "Property 'schemaVersion' must be an integer in state.json"
    }
    if ([int]$sVerProp.Value -ne $ExpectedSchemaVersion) {
        throw "Invalid schemaVersion in state.json: $($sVerProp.Value)"
    }

    # environment object validation
    $envProp = $StateObj.PSObject.Properties['environment']
    if ($null -eq $envProp -or $null -eq $envProp.Value) {
        throw "Missing environment object in state.json"
    }
    $envObj = $envProp.Value

    $envProps = @('KOMOREBI_CONFIG_HOME', 'WHKD_CONFIG_HOME', 'Path')
    foreach ($propName in $envProps) {
        $prop = $envObj.PSObject.Properties[$propName]
        if ($null -eq $prop) {
            throw "Missing environment property in state.json: $propName"
        }
        $val = $prop.Value
        if ($null -ne $val -and $val.GetType().FullName -ne 'System.String') {
            throw "Environment property $propName must be null or a string in state.json"
        }
    }

    foreach ($prop in $envObj.PSObject.Properties) {
        if ($envProps -notcontains $prop.Name) {
            throw "Unexpected environment property in state.json: $($prop.Name)"
        }
    }

    # glaze migration booleans, task booleans, process-running boolean
    $boolProps = @('glazeMigrated', 'glazeTaskExisted', 'glazeTaskEnabled', 'glazeProcessRunning', 'starterTaskExisted')
    foreach ($propName in $boolProps) {
        $prop = $StateObj.PSObject.Properties[$propName]
        if ($null -eq $prop) {
            throw "Missing state property in state.json: $propName"
        }
        $val = $prop.Value
        if ($null -eq $val -or $val.GetType().FullName -ne 'System.Boolean') {
            throw "Property $propName must be a boolean in state.json"
        }
    }

    # glazeTaskXmlSha256 validation if BOTH glazeMigrated and glazeTaskExisted are true
    if ($StateObj.glazeMigrated -and $StateObj.glazeTaskExisted) {
        $prop = $StateObj.PSObject.Properties['glazeTaskXmlSha256']
        if ($null -eq $prop) {
            throw "Missing glazeTaskXmlSha256 in state.json when glazeMigrated and glazeTaskExisted are true"
        }
        $val = $prop.Value
        if ($null -eq $val -or -not (Test-Is64Hex $val)) {
            throw "Property glazeTaskXmlSha256 must be a 64-character hex string in state.json when glazeMigrated and glazeTaskExisted are true"
        }
    }

    # Reject if glazeMigrated is false but glazeTaskExisted is true
    if (-not $StateObj.glazeMigrated -and $StateObj.glazeTaskExisted) {
        throw "Inconsistent state: glazeTaskExisted is true when glazeMigrated is false"
    }

    # Reject inconsistent glazeTaskEnabled=true when glazeTaskExisted=false
    if ($StateObj.glazeTaskEnabled -and -not $StateObj.glazeTaskExisted) {
        throw "Inconsistent state: glazeTaskEnabled is true when glazeTaskExisted is false"
    }

    # starterTaskXmlSha256 validation if starterTaskExisted is true
    if ($StateObj.starterTaskExisted) {
        $prop = $StateObj.PSObject.Properties['starterTaskXmlSha256']
        if ($null -eq $prop) {
            throw "Missing starterTaskXmlSha256 in state.json when starterTaskExisted is true"
        }
        $val = $prop.Value
        if ($null -eq $val -or -not (Test-Is64Hex $val)) {
            throw "Property starterTaskXmlSha256 must be a 64-character hex string in state.json when starterTaskExisted is true"
        }
    }
}

function Assert-DestinationSafe {
    param(
        [string]$Src,
        [string]$ConfigHome,
        [string]$InstallDir
    )
    $canonicalSrc = Get-CanonicalPath $Src
    $canonicalConfig = Get-CanonicalPath $ConfigHome
    $canonicalInstall = Get-CanonicalPath $InstallDir

    $root = $null
    if (Test-IsChildOf $canonicalSrc $canonicalConfig) {
        $root = $canonicalConfig
    } elseif (Test-IsChildOf $canonicalSrc $canonicalInstall) {
        $root = $canonicalInstall
    } else {
        # Fallback for unit testing where destination might be in a temporary folder
        $root = Get-CanonicalPath (Split-Path -Parent $canonicalSrc)
    }

    $curr = $canonicalSrc
    while ($true) {
        if (Test-Path -LiteralPath $curr) {
            if (Test-IsReparsePoint $curr) {
                throw "Destination path or ancestor is a reparse point: $curr"
            }
        }

        # Stop once we have checked the root; do not walk above it
        if ($curr -ieq $root) {
            break
        }

        $parent = Split-Path -Parent $curr
        if ($parent -eq $curr -or [string]::IsNullOrEmpty($parent)) {
            break
        }
        $curr = Get-CanonicalPath $parent
    }
}

function Assert-ManifestValid {
    param(
        $ManifestObj,
        [string]$ExpectedProductId,
        [int]$ExpectedSchemaVersion,
        [string]$BackupRoot,
        [string[]]$AllowedDestinations
    )
    if ($null -eq $ManifestObj) {
        throw "Manifest object is null"
    }

    # Validate productId type and value
    $pIdProp = $ManifestObj.PSObject.Properties['productId']
    if ($null -eq $pIdProp -or $null -eq $pIdProp.Value -or $pIdProp.Value.GetType().FullName -ne 'System.String') {
        throw "Property 'productId' must be a string in manifest.json"
    }
    if ($pIdProp.Value -ne $ExpectedProductId) {
        throw "Invalid productId in manifest.json: $($pIdProp.Value)"
    }

    # Validate schemaVersion type and value
    $sVerProp = $ManifestObj.PSObject.Properties['schemaVersion']
    if ($null -eq $sVerProp -or $null -eq $sVerProp.Value -or ($sVerProp.Value.GetType().FullName -notmatch 'System\.(Int32|Int64)')) {
        throw "Property 'schemaVersion' must be an integer in manifest.json"
    }
    if ([int]$sVerProp.Value -ne $ExpectedSchemaVersion) {
        throw "Invalid schemaVersion in manifest.json: $($sVerProp.Value)"
    }

    # Validate files property
    $filesProp = $ManifestObj.PSObject.Properties['files']
    if ($null -eq $filesProp -or $null -eq $filesProp.Value) {
        throw "Missing or null files list in manifest.json"
    }

    $allowedCanonical = @()
    foreach ($dest in $AllowedDestinations) {
        if (-not [string]::IsNullOrEmpty($dest)) {
            $allowedCanonical += Get-CanonicalPath $dest
        }
    }

    $seenDestinations = @{}
    $canonicalBackupRoot = Get-CanonicalPath $BackupRoot

    foreach ($entry in @($filesProp.Value)) {
        if ($null -eq $entry) {
            throw "Null entry in manifest files list"
        }

        # Source must be present and a string
        $srcProp = $entry.PSObject.Properties['Source']
        if ($null -eq $srcProp -or $null -eq $srcProp.Value -or $srcProp.Value.GetType().FullName -ne 'System.String') {
            throw "Manifest entry 'Source' is missing or not a string"
        }
        $src = Get-CanonicalPath $srcProp.Value
        if ($null -eq $src) {
            throw "Manifest entry 'Source' resolves to null"
        }

        # Backup must be present and a string
        $bakProp = $entry.PSObject.Properties['Backup']
        if ($null -eq $bakProp -or $null -eq $bakProp.Value -or $bakProp.Value.GetType().FullName -ne 'System.String') {
            throw "Manifest entry 'Backup' is missing or not a string"
        }
        $bak = Get-CanonicalPath $bakProp.Value
        if ($null -eq $bak) {
            throw "Manifest entry 'Backup' resolves to null"
        }

        # ExistedBefore must be present and type-checked as a JSON Boolean
        $ebProp = $entry.PSObject.Properties['ExistedBefore']
        if ($null -eq $ebProp -or $null -eq $ebProp.Value -or $ebProp.Value.GetType().FullName -ne 'System.Boolean') {
            throw "Manifest entry 'ExistedBefore' is missing or not a boolean"
        }
        $existedBefore = $ebProp.Value

        # InstalledSHA256 must be exactly 64 hex for every product target
        $instShaProp = $entry.PSObject.Properties['InstalledSHA256']
        if ($null -eq $instShaProp -or $null -eq $instShaProp.Value -or -not (Test-Is64Hex $instShaProp.Value)) {
            throw "Manifest entry 'InstalledSHA256' is missing or not a valid 64-character hex string for source: $src"
        }

        # Require exact canonical destination membership
        if ($allowedCanonical -notcontains $src) {
            throw "Destination path is not in the allowed list: $src"
        }

        # Reject if destination leaf or any existing destination ancestor is a reparse point
        Assert-DestinationSafe -Src $src -ConfigHome $configHome -InstallDir $installDir

        # Reject duplicates case-insensitively
        $srcKey = $src.ToLowerInvariant()
        if ($seenDestinations.ContainsKey($srcKey)) {
            throw "Duplicate destination path in manifest: $src"
        }
        $seenDestinations[$srcKey] = $true

        # Backup path is still canonical and inside root
        if (-not (Test-IsChildOf $bak $canonicalBackupRoot)) {
            throw "Backup path is outside the backup root: $bak"
        }

        # Reject if backup path or any existing ancestor of it is a reparse point
        $curr = $bak
        while ($curr.Length -ge $canonicalBackupRoot.Length) {
            if (Test-Path -LiteralPath $curr) {
                if (Test-IsReparsePoint $curr) {
                    throw "Backup path or ancestor is a reparse point: $curr"
                }
            }
            $currParent = Split-Path -Parent $curr
            if ($currParent -eq $curr) { break }
            $curr = Get-CanonicalPath $currParent
        }

        # Validate hash rules based on ExistedBefore
        if ($existedBefore) {
            $shaProp = $entry.PSObject.Properties['SHA256']
            if ($null -eq $shaProp -or $null -eq $shaProp.Value -or -not (Test-Is64Hex $shaProp.Value)) {
                throw "Manifest entry 'SHA256' is missing or not a valid 64-character hex string when ExistedBefore is true"
            }

            if (-not (Test-Path -LiteralPath $bak -PathType Leaf)) {
                throw "Backup file does not exist: $bak"
            }

            $hash = Get-FileSHA256 $bak
            if ($hash -ine $shaProp.Value) {
                throw "Backup file hash mismatch: $bak (Expected: $($shaProp.Value), Actual: $hash)"
            }
        } else {
            $shaProp = $entry.PSObject.Properties['SHA256']
            if ($null -ne $shaProp -and $null -ne $shaProp.Value) {
                throw "Manifest entry 'SHA256' must be null or absent when ExistedBefore is false"
            }
        }
    }
}

function Assert-BackupRootValid {
    param(
        [string]$PathName,
        [string]$PathValue,
        [string]$CanonicalBackupBase
    )
    if ([string]::IsNullOrEmpty($PathValue)) {
        throw "Property '$PathName' is missing or empty"
    }

    $canonicalPath = Get-CanonicalPath $PathValue
    if ($null -eq $canonicalPath) {
        throw "Property '$PathName' resolves to null"
    }

    # Reject equality
    if ([string]::Equals($canonicalPath, $CanonicalBackupBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$PathName '$canonicalPath' is equal to backup base: $CanonicalBackupBase"
    }

    # Must be a direct child (rejects nested children and prefix collisions)
    $parentPath = Get-CanonicalPath (Split-Path -Parent $canonicalPath)
    if (-not [string]::Equals($parentPath, $CanonicalBackupBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$PathName '$canonicalPath' is not a child of backup base: $CanonicalBackupBase"
    }

    # Leaf must match pattern
    $leaf = Split-Path -Leaf $canonicalPath
    if ($leaf -notmatch '^\d{8}-\d{6}(?:_\d+)?$') {
        throw "$PathName leaf '$leaf' must match pattern '^\d{8}-\d{6}(?:_\d+)?$'"
    }

    # Reject reparse points in existing ancestors (prefix/reparse protection)
    $curr = $canonicalPath
    while ($true) {
        if (Test-Path -LiteralPath $curr) {
            if (Test-IsReparsePoint $curr) {
                throw "$PathName or ancestor is a reparse point: $curr"
            }
        }
        if ($curr -ieq $CanonicalBackupBase) {
            break
        }
        $parent = Split-Path -Parent $curr
        if ($parent -eq $curr -or [string]::IsNullOrEmpty($parent)) {
            break
        }
        $curr = Get-CanonicalPath $parent
    }
}

    function Assert-InstallManifestValid {
        param(
            $ManifestObj,
            [string]$ExpectedProductId,
            [int]$ExpectedSchemaVersion,
            [string]$ExpectedInstallDir,
            [string]$ExpectedConfigHome,
            [switch]$VerifyBackupLinkage
        )
        if ($null -eq $ManifestObj) {
            throw "Install manifest object is null"
        }

        # 1. Product ID
        $pIdProp = $ManifestObj.PSObject.Properties['productId']
        if ($null -eq $pIdProp -or $null -eq $pIdProp.Value -or $pIdProp.Value.GetType().FullName -ne 'System.String') {
            throw "Property 'productId' must be a string in install manifest"
        }
        if ($pIdProp.Value -ne $ExpectedProductId) {
            throw "Invalid productId in install manifest: $($pIdProp.Value)"
        }

        # 2. Schema version
        $sVerProp = $ManifestObj.PSObject.Properties['schemaVersion']
        if ($null -eq $sVerProp -or $null -eq $sVerProp.Value -or ($sVerProp.Value.GetType().FullName -notmatch 'System\.(Int32|Int64)')) {
            throw "Property 'schemaVersion' must be an integer in install manifest"
        }
        if ([int]$sVerProp.Value -ne $ExpectedSchemaVersion) {
            throw "Invalid schemaVersion in install manifest: $($sVerProp.Value)"
        }

        # 3. Validate roots
        $instDirProp = $ManifestObj.PSObject.Properties['installDir']
        if ($null -eq $instDirProp -or $null -eq $instDirProp.Value -or $instDirProp.Value.GetType().FullName -ne 'System.String') {
            throw "Property 'installDir' must be a string in install manifest"
        }
        [string]$actualInstallDir = Get-CanonicalPath $instDirProp.Value
        [string]$expectedInstallDirCanonical = Get-CanonicalPath $ExpectedInstallDir
        if (-not [string]::Equals($actualInstallDir, $expectedInstallDirCanonical, [StringComparison]::OrdinalIgnoreCase)) {
            throw "installDir root mismatch in install manifest: $($instDirProp.Value) vs $ExpectedInstallDir"
        }

        $configHomeProp = $ManifestObj.PSObject.Properties['configHome']
        if ($null -eq $configHomeProp -or $null -eq $configHomeProp.Value -or $configHomeProp.Value.GetType().FullName -ne 'System.String') {
            throw "Property 'configHome' must be a string in install manifest"
        }
        [string]$actualConfigHome = Get-CanonicalPath $configHomeProp.Value
        [string]$expectedConfigHomeCanonical = Get-CanonicalPath $ExpectedConfigHome
        if (-not [string]::Equals($actualConfigHome, $expectedConfigHomeCanonical, [StringComparison]::OrdinalIgnoreCase)) {
            throw "configHome root mismatch in install manifest: $($configHomeProp.Value) vs $ExpectedConfigHome"
        }

        # 4. Migrate flag
        $migrateProp = $ManifestObj.PSObject.Properties['migrateFromGlazeWM']
        if ($null -eq $migrateProp -or $null -eq $migrateProp.Value -or $migrateProp.Value.GetType().FullName -ne 'System.Boolean') {
            throw "Property 'migrateFromGlazeWM' must be a boolean in install manifest"
        }

        # 5. Exact task name
        $tasksProp = $ManifestObj.PSObject.Properties['scheduledTasks']
        if ($null -eq $tasksProp -or $null -eq $tasksProp.Value) {
            throw "Property 'scheduledTasks' is missing or null in install manifest"
        }
        $tasksList = @($tasksProp.Value)
        if ($tasksList.Count -ne 1 -or $tasksList[0] -ne 'KomorebiStarter') {
            throw "Invalid scheduledTasks in install manifest. Expected exactly ['KomorebiStarter']"
        }

        # 6. Trusted backup linkage and roots
        $canonicalBackupBase = Get-CanonicalPath $script:backupBase

        $bakRootProp = $ManifestObj.PSObject.Properties['backupRoot']
        Assert-BackupRootValid -PathName 'backupRoot' -PathValue $bakRootProp.Value -CanonicalBackupBase $canonicalBackupBase

        $bakStateProp = $ManifestObj.PSObject.Properties['backupStateSHA256']
        if ($null -eq $bakStateProp -or $null -eq $bakStateProp.Value -or -not (Test-Is64Hex $bakStateProp.Value)) {
            throw "Property 'backupStateSHA256' must be a 64-character hex string in install manifest"
        }
        $bakManifestProp = $ManifestObj.PSObject.Properties['backupManifestSHA256']
        if ($null -eq $bakManifestProp -or $null -eq $bakManifestProp.Value -or -not (Test-Is64Hex $bakManifestProp.Value)) {
            throw "Property 'backupManifestSHA256' must be a 64-character hex string in install manifest"
        }

        # baselineBackupRoot linkage
        $baselineBakRootProp = $ManifestObj.PSObject.Properties['baselineBackupRoot']
        Assert-BackupRootValid -PathName 'baselineBackupRoot' -PathValue $baselineBakRootProp.Value -CanonicalBackupBase $canonicalBackupBase

        $baselineBakStateProp = $ManifestObj.PSObject.Properties['baselineBackupStateSHA256']
        if ($null -eq $baselineBakStateProp -or $null -eq $baselineBakStateProp.Value -or -not (Test-Is64Hex $baselineBakStateProp.Value)) {
            throw "Property 'baselineBackupStateSHA256' must be a 64-character hex string in install manifest"
        }
        $baselineBakManifestProp = $ManifestObj.PSObject.Properties['baselineBackupManifestSHA256']
        if ($null -eq $baselineBakManifestProp -or $null -eq $baselineBakManifestProp.Value -or -not (Test-Is64Hex $baselineBakManifestProp.Value)) {
            throw "Property 'baselineBackupManifestSHA256' must be a 64-character hex string in install manifest"
        }

        # glazeBackupRoot linkage (optional)
        $glazeBakRootProp = $ManifestObj.PSObject.Properties['glazeBackupRoot']
        if ($null -ne $glazeBakRootProp -and $null -ne $glazeBakRootProp.Value) {
            if ($glazeBakRootProp.Value.GetType().FullName -ne 'System.String') {
                throw "Property 'glazeBackupRoot' must be a string or null in install manifest"
            }
            Assert-BackupRootValid -PathName 'glazeBackupRoot' -PathValue $glazeBakRootProp.Value -CanonicalBackupBase $canonicalBackupBase

            $glazeBakStateProp = $ManifestObj.PSObject.Properties['glazeBackupStateSHA256']
            if ($null -eq $glazeBakStateProp -or $null -eq $glazeBakStateProp.Value -or -not (Test-Is64Hex $glazeBakStateProp.Value)) {
                throw "Property 'glazeBackupStateSHA256' must be a 64-character hex string in install manifest when glazeBackupRoot is non-null"
            }
            $glazeBakManifestProp = $ManifestObj.PSObject.Properties['glazeBackupManifestSHA256']
            if ($null -eq $glazeBakManifestProp -or $null -eq $glazeBakManifestProp.Value -or -not (Test-Is64Hex $glazeBakManifestProp.Value)) {
                throw "Property 'glazeBackupManifestSHA256' must be a 64-character hex string in install manifest when glazeBackupRoot is non-null"
            }
        } else {
            $glazeBakStateProp = $ManifestObj.PSObject.Properties['glazeBackupStateSHA256']
            if ($null -ne $glazeBakStateProp -and $null -ne $glazeBakStateProp.Value) {
                throw "Property 'glazeBackupStateSHA256' must be null or absent when glazeBackupRoot is null"
            }
            $glazeBakManifestProp = $ManifestObj.PSObject.Properties['glazeBackupManifestSHA256']
            if ($null -ne $glazeBakManifestProp -and $null -ne $glazeBakManifestProp.Value) {
                throw "Property 'glazeBackupManifestSHA256' must be null or absent when glazeBackupRoot is null"
            }
        }

        # 7. Files array
        $filesProp = $ManifestObj.PSObject.Properties['files']
        if ($null -eq $filesProp -or $null -eq $filesProp.Value) {
            throw "Missing or null files list in install manifest"
        }

        $localAllowedDestinations = @(
            (Join-Path $ExpectedConfigHome 'komorebi.json'),
            (Join-Path $ExpectedConfigHome 'applications.json'),
            (Join-Path $ExpectedConfigHome 'applications.local.json'),
            (Join-Path $ExpectedConfigHome 'komorebi.bar.json'),
            (Join-Path $ExpectedConfigHome 'komorebi.bar.jetbrains.json'),
            (Join-Path $ExpectedConfigHome 'whkdrc'),
            (Join-Path $ExpectedInstallDir 'FocusInterop.cs'),
            (Join-Path $ExpectedInstallDir 'FocusInterop.dll'),
            (Join-Path $ExpectedInstallDir 'FocusInterop.ps1'),
            (Join-Path $ExpectedInstallDir 'focus-diagnostics.ps1'),
            (Join-Path $ExpectedInstallDir 'wm.ps1'),
            (Join-Path $ExpectedInstallDir 'wm.cmd'),
            (Join-Path $ExpectedInstallDir 'wm-resize-mode.ps1'),
            (Join-Path $ExpectedInstallDir 'start.ps1'),
            (Join-Path $ExpectedInstallDir 'change_scale.ps1'),
            (Join-Path $ExpectedInstallDir 'doctor.ps1'),
            (Join-Path $ExpectedInstallDir 'KomorebiStarter.Common.ps1'),
            (Join-Path $ExpectedInstallDir 'restore.ps1'),
            (Join-Path $ExpectedInstallDir 'uninstall.ps1'),
            (Join-Path $ExpectedInstallDir 'agent-manifest.json')
        )
        $allowedCanonical = @()
        foreach ($dest in $localAllowedDestinations) {
            $allowedCanonical += Get-CanonicalPath $dest
        }

        $filesList = @($filesProp.Value)
        $legacyV020Additions = @(
            (Get-CanonicalPath (Join-Path $ExpectedInstallDir 'FocusInterop.cs')),
            (Get-CanonicalPath (Join-Path $ExpectedInstallDir 'FocusInterop.dll')),
            (Get-CanonicalPath (Join-Path $ExpectedInstallDir 'FocusInterop.ps1')),
            (Get-CanonicalPath (Join-Path $ExpectedInstallDir 'focus-diagnostics.ps1'))
        )
        if ([int]$sVerProp.Value -eq 1 -and
            $filesList.Count -ne $allowedCanonical.Count -and
            $filesList.Count -ne ($allowedCanonical.Count - $legacyV020Additions.Count)) {
            throw "File entry count ($($filesList.Count)) does not match expected allowed destinations count ($($allowedCanonical.Count)) or legacy v0.2.0 profile"
        }

        $seenPaths = @{}
        foreach ($entry in $filesList) {
            if ($null -eq $entry) {
                throw "Null file entry in install manifest"
            }

            $pathProp = $entry.PSObject.Properties['path']
            if ($null -eq $pathProp -or $null -eq $pathProp.Value -or $pathProp.Value.GetType().FullName -ne 'System.String') {
                throw "File entry 'path' is missing or not a string in install manifest"
            }
            $canonicalPath = Get-CanonicalPath $pathProp.Value
            if ($null -eq $canonicalPath) {
                throw "File entry 'path' resolves to null in install manifest"
            }

            if ($allowedCanonical -notcontains $canonicalPath) {
                throw "File entry path '$canonicalPath' is not in the allowed destinations list"
            }

            $pathKey = $canonicalPath.ToLowerInvariant()
            if ($seenPaths.ContainsKey($pathKey)) {
                throw "Duplicate file entry path in install manifest: $canonicalPath"
            }
            $seenPaths[$pathKey] = $true

            $shaProp = $entry.PSObject.Properties['sha256']
            if ($null -eq $shaProp -or $null -eq $shaProp.Value -or -not (Test-Is64Hex $shaProp.Value)) {
                throw "File entry 'sha256' is missing or not a valid 64-character hex string for path: $canonicalPath"
            }

            $typeProp = $entry.PSObject.Properties['type']
            if ($null -eq $typeProp -or $null -eq $typeProp.Value -or ($typeProp.Value -ne 'config' -and $typeProp.Value -ne 'program')) {
                throw "File entry 'type' must be 'config' or 'program' in install manifest for path: $canonicalPath"
            }

            # Check type correctness based on location
            if (Test-IsChildOf $canonicalPath $expectedConfigHomeCanonical) {
                if ($typeProp.Value -ne 'config') {
                    throw "File entry type mismatch: path '$canonicalPath' is under configHome and must have type 'config', found '$($typeProp.Value)'"
                }
            } elseif (Test-IsChildOf $canonicalPath $expectedInstallDirCanonical) {
                if ($typeProp.Value -ne 'program') {
                    throw "File entry type mismatch: path '$canonicalPath' is under installDir and must have type 'program', found '$($typeProp.Value)'"
                }
            } else {
                throw "File entry path '$canonicalPath' is neither under configHome nor installDir"
            }
        }

        if ([int]$sVerProp.Value -eq 1) {
            $missingPaths = @($allowedCanonical | Where-Object { -not $seenPaths.ContainsKey($_.ToLowerInvariant()) })
            if ($missingPaths.Count -ne 0) {
                $missingKeys = @($missingPaths | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
                $legacyKeys = @($legacyV020Additions | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
                if (($missingKeys -join '|') -ne ($legacyKeys -join '|')) {
                    throw "Schema-1 install manifest does not match the current or legacy v0.2.0 file profile. Missing: $($missingPaths -join ', ')"
                }
            }
        }

        # 8. Verify Backup Linkage
        if ($VerifyBackupLinkage) {
            $linkages = @()
            $linkages += [pscustomobject]@{
                name = 'backupRoot'
                root = $bakRootProp.Value
                stateHash = $bakStateProp.Value
                manifestHash = $bakManifestProp.Value
            }
            $linkages += [pscustomobject]@{
                name = 'baselineBackupRoot'
                root = $baselineBakRootProp.Value
                stateHash = $baselineBakStateProp.Value
                manifestHash = $baselineBakManifestProp.Value
            }
            if ($null -ne $glazeBakRootProp -and $null -ne $glazeBakRootProp.Value) {
                $linkages += [pscustomobject]@{
                    name = 'glazeBackupRoot'
                    root = $glazeBakRootProp.Value
                    stateHash = $glazeBakStateProp.Value
                    manifestHash = $glazeBakManifestProp.Value
                }
            }

            foreach ($link in $linkages) {
                $r = Get-CanonicalPath $link.root
                $stateFile = Join-Path $r 'state.json'
                $manifestFile = Join-Path $r 'manifest.json'

                if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
                    throw "Linked state.json for $($link.name) does not exist: $stateFile"
                }
                if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
                    throw "Linked manifest.json for $($link.name) does not exist: $manifestFile"
                }

                if (Test-IsReparsePoint $stateFile) {
                    throw "Linked state.json for $($link.name) is a reparse point: $stateFile"
                }
                if (Test-IsReparsePoint $manifestFile) {
                    throw "Linked manifest.json for $($link.name) is a reparse point: $manifestFile"
                }

                $actualStateHash = Get-FileSHA256 $stateFile
                if ($actualStateHash -ine $link.stateHash) {
                    throw "Linked state.json hash mismatch for $($link.name): $stateFile (Expected: $($link.stateHash), Actual: $actualStateHash)"
                }
                $actualManifestHash = Get-FileSHA256 $manifestFile
                if ($actualManifestHash -ine $link.manifestHash) {
                    throw "Linked manifest.json hash mismatch for $($link.name): $manifestFile (Expected: $($link.manifestHash), Actual: $actualManifestHash)"
                }

                $stateObj = $null
                $manifestObj = $null
                try {
                    $stateObj = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
                } catch {
                     throw "Failed to parse linked state.json for $($link.name): $stateFile. $_"
                }
                try {
                    $manifestObj = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
                } catch {
                     throw "Failed to parse linked manifest.json for $($link.name): $manifestFile. $_"
                }

                Assert-StateValid -StateObj $stateObj -ExpectedProductId $ExpectedProductId -ExpectedSchemaVersion $ExpectedSchemaVersion
                Assert-ManifestValid -ManifestObj $manifestObj -ExpectedProductId $ExpectedProductId -ExpectedSchemaVersion $ExpectedSchemaVersion -BackupRoot $r -AllowedDestinations $allowedCanonical

                # Check task XML linkage
                if ($stateObj.starterTaskExisted -eq $true) {
                    $starterXmlPath = Join-Path $r 'KomorebiStarter.xml'
                    if (-not (Test-Path -LiteralPath $starterXmlPath -PathType Leaf)) {
                        throw "KomorebiStarter.xml not found in backup root"
                    }
                    if (Test-IsReparsePoint $starterXmlPath) {
                        throw "KomorebiStarter.xml is a reparse point"
                    }
                    $xmlHash = Get-FileSHA256 $starterXmlPath
                    if ($xmlHash -ine $stateObj.starterTaskXmlSha256) {
                        throw "KomorebiStarter.xml hash mismatch: expected $($stateObj.starterTaskXmlSha256) but got $xmlHash"
                    }
                }

                if ($stateObj.glazeMigrated -eq $true -and $stateObj.glazeTaskExisted -eq $true) {
                    $glazeXmlPath = Join-Path $r 'StartGlazeWM.xml'
                    if (-not (Test-Path -LiteralPath $glazeXmlPath -PathType Leaf)) {
                        throw "StartGlazeWM.xml not found in backup root"
                    }
                    if (Test-IsReparsePoint $glazeXmlPath) {
                        throw "StartGlazeWM.xml is a reparse point"
                    }
                    $xmlHash = Get-FileSHA256 $glazeXmlPath
                    if ($xmlHash -ine $stateObj.glazeTaskXmlSha256) {
                        throw "StartGlazeWM.xml hash mismatch: expected $($stateObj.glazeTaskXmlSha256) but got $xmlHash"
                    }
                }
            }
        }
    }

function Get-CanonicalPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-IsChildOf {
    param(
        [string]$Child,
        [string]$Parent
    )
    $c = Get-CanonicalPath $Child
    $p = Get-CanonicalPath $Parent
    if ($null -eq $c -or $null -eq $p) { return $false }

    $pNormalized = $p
    if (-not $pNormalized.EndsWith([System.IO.Path]::DirectorySeparatorChar.ToString())) {
        $pNormalized += [System.IO.Path]::DirectorySeparatorChar
    }

    $cNormalized = $c
    if (-not $cNormalized.EndsWith([System.IO.Path]::DirectorySeparatorChar.ToString())) {
        $cNormalized += [System.IO.Path]::DirectorySeparatorChar
    }

    return $cNormalized.StartsWith($pNormalized, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-IsReparsePoint {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    }
    return $false
}

function Get-FileSHA256 {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $stream = $null
    $hasher = $null
    try {
        $resolvedPath = Get-CanonicalPath $Path
        $stream = [System.IO.File]::OpenRead($resolvedPath)
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $hasher.ComputeHash($stream)
        return [System.BitConverter]::ToString($hashBytes).Replace('-', '')
    } catch {
        return $null
    } finally {
        if ($null -ne $hasher) {
            $hasher.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Set-UserEnvironmentVariable {
    param(
        [string]$Name,
        [string]$Value
    )
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
}

function Resolve-CommonCommand {
    param([string]$CommandName)

    # 1. Check Get-Command (PATH)
    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($cmd) {
        $path = $cmd.Source
        if ([string]::IsNullOrEmpty($path) -and $cmd.CommandType -eq 'Alias') {
            $path = (Get-Command $cmd.ResolvedCommandName -ErrorAction SilentlyContinue).Source
        }
        if (-not [string]::IsNullOrEmpty($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return Get-CanonicalPath $path
        }
    }

    # 2. Check candidates
    $exeName = if ($CommandName.EndsWith('.exe')) { $CommandName } else { "$CommandName.exe" }

    $localPrograms = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs'
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    if ([string]::IsNullOrEmpty($programFiles)) {
        $programFiles = 'C:\Program Files'
    }

    $searchDirs = @(
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\WinGet\Links'),
        (Join-Path $programFiles 'WinGet\Links'),
        (Join-Path $localPrograms $CommandName),
        (Join-Path $localPrograms 'komorebi'),
        (Join-Path $localPrograms 'whkd'),
        (Join-Path $localPrograms 'masir'),
        (Join-Path $programFiles 'masir\bin'),
        (Join-Path $programFiles 'komorebi\bin'),
        (Join-Path $programFiles 'whkd\bin'),
        (Join-Path $programFiles 'masir'),
        (Join-Path $programFiles 'komorebi'),
        (Join-Path $programFiles 'whkd')
    )

    foreach ($dir in $searchDirs) {
        $candidate = Join-Path $dir $exeName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return Get-CanonicalPath $candidate
        }
    }

    return $null
}

function Get-UniqueBackupRoot {
    param([string]$BaseDir)
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $candidate = Join-Path $BaseDir $timestamp
    $index = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $BaseDir "${timestamp}_$index"
        $index++
    }
    return Get-CanonicalPath $candidate
}

function Test-ScheduledTaskEnabled {
    param($TaskObj)
    if ($null -eq $TaskObj) {
        return $false
    }
    try {
        if ($TaskObj.State -eq 'Disabled' -or $TaskObj.State -eq 1) {
            return $false
        }
    } catch {
        Write-Verbose "Scheduled-task state was unavailable; checking task settings instead: $_"
    }
    try {
        $enabled = $TaskObj.Settings.Enabled
        if ($null -ne $enabled) {
            return [bool]$enabled
        }
    } catch {
        Write-Verbose "Scheduled-task settings were unavailable; treating the task as enabled: $_"
    }
    return $true
}

function Test-GlazeTakeoverAuthorized {
    param(
        [string]$ManifestPath,
        [string]$ExpectedProductId,
        [int]$ExpectedSchemaVersion,
        [string]$ExpectedInstallDir,
        [string]$ExpectedConfigHome
    )
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return $false
    }
    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        Assert-InstallManifestValid -ManifestObj $manifest -ExpectedProductId $ExpectedProductId -ExpectedSchemaVersion $ExpectedSchemaVersion -ExpectedInstallDir $ExpectedInstallDir -ExpectedConfigHome $ExpectedConfigHome -VerifyBackupLinkage
        return [bool]$manifest.migrateFromGlazeWM
    } catch {
        return $false
    }
}

function Test-FontInstalled {
    param([string]$FontName)
    $regPaths = @(
        "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts",
        "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
    )
    foreach ($regPath in $regPaths) {
        if (Test-Path $regPath) {
            $values = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            if ($null -ne $values) {
                foreach ($prop in $values.PSObject.Properties) {
                    if ($prop.Name -like "*$FontName*") {
                        return $true
                    }
                }
            }
        }
    }
    $fontDirs = @(
        (Join-Path $env:windir 'Fonts'),
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\Windows\Fonts')
    )
    foreach ($dir in $fontDirs) {
        if (Test-Path $dir) {
            $files = Get-ChildItem -Path $dir -Filter "*$FontName*" -File -ErrorAction SilentlyContinue
            if ($files) {
                return $true
            }
        }
    }
    return $false
}
