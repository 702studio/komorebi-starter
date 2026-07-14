[CmdletBinding()]
param(
    [ValidateRange(1, 120)]
    [int]$DurationSeconds = 15,

    [string[]]$ProcessName,

    [switch]$IncludeTitles,

    [ValidateRange(1, 5000)]
    [int]$MaxEvents = 1000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Recursive function to check if any object nested under content contains a matching exe
function Test-ContainsMatchingExe {
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        $Filters
    )

    if ($null -eq $Object) {
        return $false
    }

    if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
        foreach ($item in $Object) {
            if (Test-ContainsMatchingExe -Object $item -Filters $Filters) {
                return $true
            }
        }
    } elseif ($Object -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Object.PSObject.Properties) {
            if ($prop.Name -eq 'exe' -and $prop.Value -is [string]) {
                $val = $prop.Value
                if ($val.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
                    $val = $val.Substring(0, $val.Length - 4)
                }
                if ($Filters -contains $val.ToLowerInvariant()) {
                    return $true
                }
            }
            if (Test-ContainsMatchingExe -Object $prop.Value -Filters $Filters) {
                return $true
            }
        }
    }

    return $false
}

# Recursive function to replace every property named 'title' with '[REDACTED]'
function Protect-TitleField {
    param(
        [Parameter(Mandatory = $true)]
        $Object
    )

    if ($null -eq $Object) {
        return
    }

    if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
        foreach ($item in $Object) {
            Protect-TitleField -Object $item
        }
    } elseif ($Object -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Object.PSObject.Properties) {
            if ($prop.Name -eq 'title') {
                $prop.Value = '[REDACTED]'
            } else {
                Protect-TitleField -Object $prop.Value
            }
        }
    }
}

$startedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", [System.Globalization.CultureInfo]::InvariantCulture)

$pipe = $null
$reader = $null
$waitHandle = $null
$subscribed = $false
$events = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList
$pipeName = "komorebi-trace-" + [Guid]::NewGuid().ToString('D')
$exitCode = 0
$outputJson = $null

# Resolve komorebic with Get-Command and fail clearly if absent
$komorebicCmd = Get-Command komorebic -ErrorAction SilentlyContinue
if (-not $komorebicCmd) {
    $finishedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", [System.Globalization.CultureInfo]::InvariantCulture)
    $response = [pscustomobject]@{
        ok              = $false
        startedAt       = $startedAt
        finishedAt      = $finishedAt
        durationSeconds = $DurationSeconds
        processFilter   = @($ProcessName)
        includeTitles   = [bool]$IncludeTitles
        eventCount      = 0
        truncated       = $false
        events          = @()
        warnings        = @("komorebic executable not found in PATH")
        error           = "komorebic executable not found in PATH"
    }
    Write-Output ($response | ConvertTo-Json -Depth 6)
    exit 1
}

$komorebicPath = $komorebicCmd.Source

# Normalize process name filters
$normalizedFilters = @()
if ($ProcessName) {
    foreach ($p in $ProcessName) {
        if ($p) {
            $norm = $p
            if ($norm.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
                $norm = $norm.Substring(0, $norm.Length - 4)
            }
            $normalizedFilters += $norm.ToLowerInvariant()
        }
    }
}
$reportedFilters = [string[]]@($normalizedFilters)

try {
    # Create a NamedPipeServerStream
    $pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
        $pipeName,
        [System.IO.Pipes.PipeDirection]::In,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::Asynchronous
    )

    # Begin accepting before registration so the first event cannot race the
    # server into a connection that has not started waiting yet.
    $waitHandle = $pipe.BeginWaitForConnection($null, $null)

    # Subscribe to pipe
    $subOutput = & $komorebicPath subscribe-pipe $pipeName 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to subscribe named pipe via komorebic: $subOutput"
    }
    $subscribed = $true

    $startTime = [DateTime]::UtcNow
    $endTime = $startTime.AddSeconds($DurationSeconds)
    $readTask = $null
    $truncated = $false

    while ($true) {
        # Check event limit
        if ($events.Count -ge $MaxEvents) {
            $truncated = $true
            break
        }

        # Calculate remaining duration
        $now = [DateTime]::UtcNow
        $remainingMs = [int]($endTime - $now).TotalMilliseconds
        if ($remainingMs -le 0) {
            break
        }

        # Ensure connection
        if (-not $pipe.IsConnected) {
            $waitTimeout = [Math]::Min(500, $remainingMs)
            if ($waitTimeout -le 0) {
                break
            }
            $connected = $waitHandle.AsyncWaitHandle.WaitOne($waitTimeout)
            if ($connected) {
                try {
                    $pipe.EndWaitForConnection($waitHandle)
                    $reader = New-Object System.IO.StreamReader($pipe, [System.Text.Encoding]::UTF8)
                } catch {
                    $null = $warnings.Add("Failed to complete named pipe connection: $_")
                    break
                }
            } else {
                continue
            }
        }

        # Connected, wait for line asynchronously
        if ($null -eq $readTask) {
            $readTask = $reader.ReadLineAsync()
        }

        $readTimeout = [Math]::Min(100, $remainingMs)
        if ($readTimeout -le 0) {
            break
        }

        $taskCompleted = $false
        try {
            $taskCompleted = $readTask.Wait($readTimeout)
        } catch {
            $null = $warnings.Add("Exception waiting for line read: $_")
            break
        }

        if ($taskCompleted) {
            if ($readTask.IsFaulted -or $readTask.IsCanceled) {
                $null = $warnings.Add("Read task faulted or canceled.")
                break
            }

            $line = $readTask.Result
            $readTask = $null # reset for next line

            if ($null -eq $line) {
                # Pipe closed/EOF
                break
            }

            # Parse line
            $parsed = $null
            try {
                $parsed = ConvertFrom-Json $line
            } catch {
                $null = $warnings.Add("Nonfatal: Failed to parse event JSON line.")
                continue
            }

            if ($null -eq $parsed -or $null -eq $parsed.event) {
                $null = $warnings.Add("Nonfatal: Event property missing in parsed JSON.")
                continue
            }

            $evt = $parsed.event
            $evtType = $evt.type
            $evtContent = $evt.content

            # Apply process filter if requested
            if ($normalizedFilters.Count -gt 0) {
                if (-not (Test-ContainsMatchingExe -Object $evtContent -Filters $normalizedFilters)) {
                    continue
                }
            }

            # Redact titles if not explicitly included
            if (-not $IncludeTitles) {
                Protect-TitleField -Object $evtContent
            }

            # Add to captured events with UTC timestamp
            $record = [pscustomobject]@{
                timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", [System.Globalization.CultureInfo]::InvariantCulture)
                type      = $evtType
                content   = $evtContent
            }
            $null = $events.Add($record)
        }
    }

    $finishedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", [System.Globalization.CultureInfo]::InvariantCulture)
    $response = [pscustomobject]@{
        ok              = $true
        startedAt       = $startedAt
        finishedAt      = $finishedAt
        durationSeconds = $DurationSeconds
        processFilter   = $reportedFilters
        includeTitles   = [bool]$IncludeTitles
        eventCount      = $events.Count
        truncated       = $truncated
        events          = $events.ToArray()
        warnings        = [string[]]$warnings
    }
    $outputJson = $response | ConvertTo-Json -Depth 10
} catch {
    $finishedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", [System.Globalization.CultureInfo]::InvariantCulture)
    $response = [pscustomobject]@{
        ok              = $false
        startedAt       = $startedAt
        finishedAt      = $finishedAt
        durationSeconds = $DurationSeconds
        processFilter   = $reportedFilters
        includeTitles   = [bool]$IncludeTitles
        eventCount      = 0
        truncated       = $false
        events          = @()
        warnings        = [string[]]$warnings
        error           = $_.Exception.Message
    }
    $outputJson = $response | ConvertTo-Json -Depth 6
    $exitCode = 1
} finally {
    if ($subscribed) {
        $null = & $komorebicPath unsubscribe-pipe $pipeName 2>&1
    }
    if ($null -ne $reader) {
        $reader.Dispose()
    }
    if ($null -ne $pipe) {
        $pipe.Dispose()
    }
    if ($null -ne $waitHandle -and $null -ne $waitHandle.AsyncWaitHandle) {
        $waitHandle.AsyncWaitHandle.Close()
    }
}

if ($null -ne $outputJson) {
    Write-Output $outputJson
}
exit $exitCode
