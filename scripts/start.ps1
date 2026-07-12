[CmdletBinding()]
param(
    [switch]$Restart,
    [switch]$StopOnly,
    [switch]$CleanState,
    [ValidateRange(0, 10000)]
    [int]$DelayMilliseconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source common helper
. (Join-Path $PSScriptRoot 'KomorebiStarter.Common.ps1')

if ($DelayMilliseconds -gt 0) {
    Start-Sleep -Milliseconds $DelayMilliseconds
}

$mutex = [Threading.Mutex]::new($false, 'Local\KomorebiStarter.Lifecycle')
if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(30))) {
    $mutex.Dispose()
    throw 'Another window-manager lifecycle operation is still running.'
}

function Stop-ProcessGracefully {
    param([string[]]$Names)

    foreach ($name in $Names) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($_.MainWindowHandle -ne 0) {
                    $null = $_.CloseMainWindow()
                }
            } catch {
                Write-Verbose "Graceful process close failed; forced cleanup remains available: $_"
            }
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = Get-Process -Name $Names -ErrorAction SilentlyContinue
        if (-not $remaining) {
            return
        }
        Start-Sleep -Milliseconds 100
    }

    Stop-Process -Name $Names -Force -ErrorAction SilentlyContinue | Out-Null
}

function Stop-GlazeEnvironment {
    $glazeRunning = [bool](Get-Process -Name glazewm -ErrorAction SilentlyContinue)
    $zebarRunning = [bool](Get-Process -Name zebar -ErrorAction SilentlyContinue)

    if ($glazeRunning -or $zebarRunning) {
        if (-not $migrateFromGlazeWM) {
            throw "Conflict detected: GlazeWM or ZeBar is running, but migration was not authorized. Please run the installer with -MigrateFromGlazeWM."
        }

        if (Get-Process -Name glazewm -ErrorAction SilentlyContinue) {
            $glaze = Resolve-CommonCommand 'glazewm'
            if ($glaze) {
                try {
                    & $glaze command wm-exit 2>$null | Out-Null
                } catch {
                    Write-Verbose "GlazeWM did not accept wm-exit; process cleanup will continue: $_"
                }
            }
        }
        Stop-ProcessGracefully -Names @('glazewm', 'glazewm-watcher', 'zebar')
    }
}

function Stop-KomorebiEnvironment {
    $komorebic = Resolve-CommonCommand 'komorebic'
    if ($komorebic -and (Get-Process -Name komorebi -ErrorAction SilentlyContinue)) {
        try {
            & $komorebic stop --whkd --bar --masir 2>$null | Out-Null
        } catch {
            Write-Verbose "komorebic stop did not complete cleanly; process cleanup will continue: $_"
        }
    }

    Stop-ProcessGracefully -Names @('komorebi', 'komorebi-bar', 'whkd', 'masir')
}

try {
    if ($StopOnly) {
        Stop-KomorebiEnvironment
        [pscustomobject]@{
            productId = $productId
            schemaVersion = $schemaVersion
            ok = $true
            stopped = $true
        } | ConvertTo-Json -Depth 5
        return
    }

    # Determine if GlazeWM migration is allowed by reading manifest
    $migrateFromGlazeWM = Test-GlazeTakeoverAuthorized -ManifestPath (Join-Path $stateHome 'install-manifest.json') -ExpectedProductId $productId -ExpectedSchemaVersion $schemaVersion -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome

    # Ensure environment variables are active
    $configHome = if ($env:KOMOREBI_CONFIG_HOME) {
        $env:KOMOREBI_CONFIG_HOME
    } else {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\komorebi'
    }
    $env:KOMOREBI_CONFIG_HOME = $configHome
    $env:WHKD_CONFIG_HOME = $configHome

    $configPath = Join-Path $configHome 'komorebi.json'
    $defaultBarPath = Join-Path $configHome 'komorebi.bar.json'
    $jetBrainsBarPath = Join-Path $configHome 'komorebi.bar.jetbrains.json'

    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Komorebi configuration not found: $configPath"
    }

    $komorebic = Resolve-CommonCommand 'komorebic'
    if (-not $komorebic) { throw 'komorebic was not found.' }

    $bar = Resolve-CommonCommand 'komorebi-bar'
    if (-not $bar) { throw 'komorebi-bar was not found.' }

    $whkd = Resolve-CommonCommand 'whkd'
    if (-not $whkd) { throw 'whkd was not found.' }

    $masir = Resolve-CommonCommand 'masir'
    if (-not $masir) { throw 'masir was not found.' }

    # Verify and stop GlazeWM environment if allowed
    Stop-GlazeEnvironment

    $alreadyRunning = Get-Process -Name komorebi -ErrorAction SilentlyContinue
    if ($Restart -or $alreadyRunning) {
        Stop-KomorebiEnvironment
    }

    $fontNames = @()
    if (Test-Path -LiteralPath $bar) {
        $fontNames = @(& $bar --fonts 2>$null | ForEach-Object { $_.Trim() })
    }

    # Font checking logic matching Segoe UI Variable fallback
    $barConfig = if (($fontNames -contains 'Segoe UI Variable' -or $fontNames -contains 'Segoe UI Variable Text') -and (Test-Path -LiteralPath $defaultBarPath)) {
        $defaultBarPath
    } elseif ((($fontNames -contains 'JetBrains Mono') -or ($fontNames -contains 'JetBrains Mono Regular') -or ($fontNames -contains 'JetBrainsMono NF') -or ($fontNames -contains 'JetBrainsMono Nerd Font')) -and (Test-Path -LiteralPath $jetBrainsBarPath)) {
        $jetBrainsBarPath
    } else {
        $defaultBarPath
    }

    # Temporarily prepend resolved command paths to env:path if not present
    $pathDirs = New-Object System.Collections.ArrayList
    foreach ($cmd in @($komorebic, $whkd, $masir, $bar)) {
        $dir = Split-Path -Parent $cmd
        $pathEntries = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $canonicalDir = Get-CanonicalPath $dir
        $exists = $false
        foreach ($pe in $pathEntries) {
            try {
                if ((Get-CanonicalPath $pe) -eq $canonicalDir) {
                    $exists = $true
                    break
                }
            } catch {
                Write-Verbose "Ignoring malformed PATH entry while resolving command directories: $pe"
            }
        }
        if (-not $exists -and -not $pathDirs.Contains($dir)) {
            $null = $pathDirs.Add($dir)
        }
    }
    if ($pathDirs.Count -gt 0) {
        $allEntries = @($pathDirs) + ($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $env:Path = $allEntries -join ';'
    }

    $startArguments = @('start', '--config', $configPath, '--whkd', '--masir')
    if ($CleanState) {
        $startArguments += '--clean-state'
    }

    $startOutput = @(& $komorebic @startArguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ($startOutput -join [Environment]::NewLine)
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while (-not (Get-Process -Name komorebi -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Get-Process -Name komorebi -ErrorAction SilentlyContinue)) {
        throw 'komorebi.exe did not start within 8 seconds.'
    }

    Start-Process -FilePath $bar -ArgumentList @('--config', ('"{0}"' -f $barConfig)) -WindowStyle Hidden | Out-Null

    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while ([DateTime]::UtcNow -lt $deadline) {
        $wmReady = Get-Process -Name komorebi -ErrorAction SilentlyContinue
        $hotkeysReady = Get-Process -Name whkd -ErrorAction SilentlyContinue
        $barReady = Get-Process -Name komorebi-bar -ErrorAction SilentlyContinue
        if ($wmReady -and $hotkeysReady -and $barReady) {
            break
        }
        Start-Sleep -Milliseconds 100
    }

    $missing = @()
    foreach ($name in @('komorebi', 'whkd', 'masir', 'komorebi-bar')) {
        if (-not (Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $missing += $name
        }
    }
    if ($missing.Count -gt 0) {
        Stop-KomorebiEnvironment
        throw "Startup failed; missing processes: $($missing -join ', ')"
    }

    if (Get-Process -Name glazewm, zebar -ErrorAction SilentlyContinue) {
        Stop-KomorebiEnvironment
        throw 'Conflict detected: GlazeWM or Zebar started while Komorebi was active.'
    }

    [pscustomobject]@{
        productId = $productId
        schemaVersion = $schemaVersion
        ok = $true
        manager = 'komorebi'
        configHome = $configHome
        config = $configPath
        barConfig = $barConfig
        processes = @(Get-Process -Name komorebi, komorebi-bar, whkd, masir -ErrorAction SilentlyContinue |
            Select-Object ProcessName, Id)
    } | ConvertTo-Json -Depth 5
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
