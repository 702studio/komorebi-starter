[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$NoExitCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source common helper
. (Join-Path $PSScriptRoot 'KomorebiStarter.Common.ps1')

# Resolve paths using common command resolver
$komorebicPath = Resolve-CommonCommand 'komorebic'
$whkdPath = Resolve-CommonCommand 'whkd'
$masirPath = Resolve-CommonCommand 'masir'
$barPath = Resolve-CommonCommand 'komorebi-bar'

$configFiles = @('komorebi.json', 'applications.json', 'applications.local.json', 'whkdrc', 'komorebi.bar.json')
$fileChecks = [ordered]@{}

foreach ($file in $configFiles) {
    $path = Join-Path $configHome $file
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    $validJson = $false

    if ($exists -and $file -like '*.json') {
        try {
            $null = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $validJson = $true
        } catch {
            $validJson = $false
        }
    } else {
        $validJson = $null
    }

    $fileChecks[$file] = [ordered]@{
        exists = $exists
        validJson = $validJson
    }

}

# Process check
$processes = @('komorebi', 'komorebi-bar', 'whkd', 'masir', 'glazewm', 'zebar')
$processChecks = [ordered]@{}
foreach ($proc in $processes) {
    $processChecks[$proc] = [bool](Get-Process -Name $proc -ErrorAction SilentlyContinue)
}

# Manifest validation (without mutating)
$manifestFile = Join-Path $stateHome 'install-manifest.json'
$manifestValid = $false
$manifestError = $null
$migrateFromGlazeWM = $false
if (Test-Path -LiteralPath $manifestFile -PathType Leaf) {
    try {
        $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
        Assert-InstallManifestValid -ManifestObj $manifest -ExpectedProductId $productId -ExpectedSchemaVersion $schemaVersion -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome -VerifyBackupLinkage
        $manifestValid = $true
        $migrateFromGlazeWM = [bool]$manifest.migrateFromGlazeWM
    } catch {
        $manifestValid = $false
        $manifestError = $_.Exception.Message
    }
} else {
    $manifestValid = $false
    $manifestError = "install-manifest.json not found"
}

# Task check
$task = Get-ScheduledTask -TaskName 'KomorebiStarter' -ErrorAction SilentlyContinue
$taskOk = Test-ScheduledTaskEnabled $task

# Conflict status
$glazeRunning = [bool]$processChecks.glazewm
$zebarRunning = [bool]$processChecks.zebar
$glazeTask = Get-ScheduledTask -TaskName 'StartGlazeWM' -ErrorAction SilentlyContinue
$glazeTaskEnabled = Test-ScheduledTaskEnabled $glazeTask

$glazeConflict = ($glazeRunning -or $zebarRunning -or $glazeTaskEnabled) -and (-not $migrateFromGlazeWM)
$conflictDetected = [bool]($glazeConflict -or (($glazeRunning -or $zebarRunning) -and $processChecks.komorebi))

$conflictStatus = [ordered]@{
    glazeRunning = $glazeRunning
    zebarRunning = $zebarRunning
    glazeTaskEnabled = $glazeTaskEnabled
    migrationAuthorized = $migrateFromGlazeWM
    conflict = $conflictDetected
}

# Issue codes
$issueCodes = New-Object System.Collections.ArrayList
if ($null -eq $komorebicPath) { $null = $issueCodes.Add("DEP_KOMOREBIC_MISSING") }
if ($null -eq $whkdPath) { $null = $issueCodes.Add("DEP_WHKD_MISSING") }
if ($null -eq $masirPath) { $null = $issueCodes.Add("DEP_MASIR_MISSING") }
if ($null -eq $barPath) { $null = $issueCodes.Add("DEP_BAR_MISSING") }

foreach ($file in $configFiles) {
    $fc = $fileChecks[$file]
    if (-not $fc.exists) {
        $null = $issueCodes.Add("CONFIG_FILE_MISSING")
    } elseif ($file -like '*.json' -and -not $fc.validJson) {
        $null = $issueCodes.Add("CONFIG_JSON_INVALID")
    }
}

if (-not $processChecks.komorebi) { $null = $issueCodes.Add("PROCESS_KOMOREBI_STOPPED") }
if (-not $processChecks.whkd) { $null = $issueCodes.Add("PROCESS_WHKD_STOPPED") }
if (-not $processChecks.masir) { $null = $issueCodes.Add("PROCESS_MASIR_STOPPED") }
if (-not $processChecks.'komorebi-bar') { $null = $issueCodes.Add("PROCESS_BAR_STOPPED") }

if (-not $taskOk) { $null = $issueCodes.Add("TASK_DISABLED_OR_MISSING") }

if ($conflictDetected) { $null = $issueCodes.Add("GLAZE_CONFLICT") }
if (-not $manifestValid) { $null = $issueCodes.Add("MANIFEST_INVALID") }

# Deduplicate issueCodes while preserving order
$uniqueCodes = New-Object System.Collections.ArrayList
foreach ($code in $issueCodes) {
    if (-not $uniqueCodes.Contains($code)) {
        [void]$uniqueCodes.Add($code)
    }
}
$issueCodes = $uniqueCodes

$ok = ($issueCodes.Count -eq 0)

$report = [pscustomobject]@{
    schemaVersion = $schemaVersion
    productId = $productId
    ok = $ok
    environment = [ordered]@{
        KOMOREBI_CONFIG_HOME = $env:KOMOREBI_CONFIG_HOME
        WHKD_CONFIG_HOME = $env:WHKD_CONFIG_HOME
    }
    dependencies = [ordered]@{
        komorebic = [ordered]@{ installed = ($null -ne $komorebicPath); path = $komorebicPath }
        whkd = [ordered]@{ installed = ($null -ne $whkdPath); path = $whkdPath }
        masir = [ordered]@{ installed = ($null -ne $masirPath); path = $masirPath }
        komorebiBar = [ordered]@{ installed = ($null -ne $barPath); path = $barPath }
    }
    processes = $processChecks
    files = $fileChecks
    scheduledTask = [ordered]@{
        installed = ($null -ne $task)
        enabled = $taskOk
    }
    manifest = [ordered]@{
        valid = $manifestValid
        error = $manifestError
    }
    conflictStatus = $conflictStatus
    issueCodes = @($issueCodes)
}

if ($Json) {
    $report | ConvertTo-Json -Depth 5
} else {
    Write-Host "Komorebi Starter Doctor Diagnosis" -ForegroundColor Cyan
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host "Overall Health: $(if ($ok) { 'HEALTHY' } else { 'UNHEALTHY' })" -ForegroundColor (if ($ok) { 'Green' } else { 'Red' })
    Write-Host ""
    Write-Host "Environment Variables:"
    Write-Host "  KOMOREBI_CONFIG_HOME: $($env:KOMOREBI_CONFIG_HOME)"
    Write-Host "  WHKD_CONFIG_HOME:     $($env:WHKD_CONFIG_HOME)"
    Write-Host ""
    Write-Host "Dependencies:"
    $report.dependencies.PSObject.Properties | ForEach-Object {
        Write-Host "  $($_.Name): $(if ($_.Value.installed) { 'Found (' + $_.Value.path + ')' } else { 'MISSING' })" -ForegroundColor (if ($_.Value.installed) { 'Green' } else { 'Red' })
    }
    Write-Host ""
    Write-Host "Processes:"
    $report.processes.PSObject.Properties | ForEach-Object {
        Write-Host "  $($_.Name): $(if ($_.Value) { 'RUNNING' } else { 'STOPPED' })" -ForegroundColor (if ($_.Name -in @('glazewm', 'zebar')) { if ($_.Value) { 'Yellow' } else { 'Gray' } } else { if ($_.Value) { 'Green' } else { 'Red' } })
    }
    Write-Host ""
    Write-Host "Configuration Files (in $configHome):"
    $report.files.PSObject.Properties | ForEach-Object {
        $statusStr = "Exists: $($_.Value.exists)"
        if ($_.Value.validJson -ne $null) {
            $statusStr += ", Valid JSON: $($_.Value.validJson)"
        }
        $fileOk = $_.Value.exists -and ($_.Value.validJson -eq $null -or $_.Value.validJson)
        Write-Host "  $($_.Name): $statusStr" -ForegroundColor (if ($fileOk) { 'Green' } else { 'Red' })
    }
    Write-Host ""
    Write-Host "Scheduled Task:"
    Write-Host "  KomorebiStarter: $(if ($report.scheduledTask.installed) { 'Installed (Enabled: ' + $report.scheduledTask.enabled + ')' } else { 'MISSING' })" -ForegroundColor (if ($report.scheduledTask.enabled) { 'Green' } else { 'Red' })
    Write-Host ""
    Write-Host "Manifest validity:"
    Write-Host "  Valid: $($report.manifest.valid)$(if ($null -ne $report.manifest.error) { ' (' + $report.manifest.error + ')' })" -ForegroundColor (if ($report.manifest.valid) { 'Green' } else { 'Red' })
    Write-Host ""
    Write-Host "Conflict status:"
    Write-Host "  Conflict detected: $($report.conflictStatus.conflict)" -ForegroundColor (if ($report.conflictStatus.conflict) { 'Red' } else { 'Green' })
    if ($report.issueCodes.Count -gt 0) {
        Write-Host ""
        Write-Host "Active issue codes:" -ForegroundColor Red
        $report.issueCodes | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    }
}

if ($NoExitCode) {
    return
}
if ($ok) {
    exit 0
} else {
    exit 1
}
