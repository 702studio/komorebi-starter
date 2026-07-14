[CmdletBinding()]
param(
    [string[]]$ProcessName,
    [switch]$IncludeTitles,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CollectionFocusedElement {
    param($Collection)

    if ($null -eq $Collection) {
        return $null
    }

    if ($null -ne $Collection.PSObject.Properties['elements']) {
        $elements = @($Collection.elements)
        if ($elements.Count -eq 0 -or $null -eq $Collection.PSObject.Properties['focused']) {
            return $null
        }
        $focused = [int]$Collection.focused
        if ($focused -lt 0 -or $focused -ge $elements.Count) {
            return $null
        }
        return $elements[$focused]
    }

    $rawElements = @($Collection)
    if ($rawElements.Count -eq 1) {
        return $rawElements[0]
    }
    return $null
}

function Get-WindowFromContainer {
    param($Container)

    if ($null -eq $Container) {
        return $null
    }
    if ($null -ne $Container.PSObject.Properties['hwnd']) {
        return $Container
    }
    if ($null -ne $Container.PSObject.Properties['windows']) {
        return Get-CollectionFocusedElement -Collection $Container.windows
    }
    return $null
}

function Get-FocusedKomorebiWindow {
    param([Parameter(Mandatory = $true)]$State)

    if ($null -eq $State.PSObject.Properties['monitors']) {
        return $null
    }
    
    $monitors = @()
    if ($null -ne $State.monitors.PSObject.Properties['elements']) {
        $monitors = @($State.monitors.elements)
    } else {
        $monitors = @($State.monitors)
    }
    
    $focusedMonitorIdx = 0
    if ($null -ne $State.monitors.PSObject.Properties['focused']) {
        $focusedMonitorIdx = [int]$State.monitors.focused
    }
    
    if ($focusedMonitorIdx -lt 0 -or $focusedMonitorIdx -ge $monitors.Count) {
        return $null
    }
    
    $monitor = $monitors[$focusedMonitorIdx]
    if ($null -eq $monitor -or $null -eq $monitor.PSObject.Properties['workspaces']) {
        return $null
    }
    
    $workspaces = @()
    if ($null -ne $monitor.workspaces.PSObject.Properties['elements']) {
        $workspaces = @($monitor.workspaces.elements)
    } else {
        $workspaces = @($monitor.workspaces)
    }
    
    $focusedWorkspaceIdx = 0
    if ($null -ne $monitor.workspaces.PSObject.Properties['focused']) {
        $focusedWorkspaceIdx = [int]$monitor.workspaces.focused
    }
    
    if ($focusedWorkspaceIdx -lt 0 -or $focusedWorkspaceIdx -ge $workspaces.Count) {
        return $null
    }
    
    $workspace = $workspaces[$focusedWorkspaceIdx]
    if ($null -eq $workspace) {
        return $null
    }

    $layer = if ($null -ne $workspace.PSObject.Properties['layer']) { [string]$workspace.layer } else { '' }
    if ($layer -eq 'Floating' -and $null -ne $workspace.PSObject.Properties['floating_windows']) {
        $floating = Get-CollectionFocusedElement -Collection $workspace.floating_windows
        if ($null -ne $floating) {
            return Get-WindowFromContainer -Container $floating
        }
    }

    foreach ($propertyName in @('maximized_window', 'monocle_container')) {
        if ($null -ne $workspace.PSObject.Properties[$propertyName] -and $null -ne $workspace.$propertyName) {
            $window = Get-WindowFromContainer -Container $workspace.$propertyName
            if ($null -ne $window) {
                return $window
            }
        }
    }

    if ($null -ne $workspace.PSObject.Properties['containers']) {
        $container = Get-CollectionFocusedElement -Collection $workspace.containers
        return Get-WindowFromContainer -Container $container
    }
    return $null
}

function Get-WindowsFromContainerObject {
    param($Container)
    if ($null -eq $Container) { return @() }

    if ($null -ne $Container.PSObject.Properties['hwnd']) {
        return @(@{
            hwnd = [long]$Container.hwnd
            title = [string]$Container.title
            exe = [string]$Container.exe
            class = [string]$Container.class
            windowIndex = 0
        })
    }

    if ($null -ne $Container.PSObject.Properties['windows']) {
        $elements = @()
        if ($null -ne $Container.windows.PSObject.Properties['elements']) {
            $elements = @($Container.windows.elements)
        } elseif ($Container.windows -is [System.Array]) {
            $elements = $Container.windows
        } else {
            $elements = @($Container.windows)
        }
        $windows = @()
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $w = $elements[$i]
            if ($null -ne $w -and $null -ne $w.PSObject.Properties['hwnd']) {
                $windows += @{
                    hwnd = [long]$w.hwnd
                    title = [string]$w.title
                    exe = [string]$w.exe
                    class = [string]$w.class
                    windowIndex = $i
                }
            }
        }
        return $windows
    }

    return @()
}

function Get-AllWorkspaceWindows {
    param(
        $MonitorIndex,
        $WorkspaceIndex,
        $Workspace,
        $IsFocusedWorkspace
    )

    $results = @()

    # 1. maximized_window
    if ($null -ne $Workspace.PSObject.Properties['maximized_window'] -and $null -ne $Workspace.maximized_window) {
        $maximized = $Workspace.maximized_window
        $windows = Get-WindowsFromContainerObject -Container $maximized
        foreach ($w in $windows) {
            $results += [pscustomobject]@{
                hwnd = $w.hwnd
                title = $w.title
                exe = $w.exe
                class = $w.class
                monitorIndex = $MonitorIndex
                workspaceIndex = $WorkspaceIndex
                isFocusedWorkspace = $IsFocusedWorkspace
                layer = 'Maximized'
                containerIndex = $null
                windowIndex = $w.windowIndex
            }
        }
    }

    # 2. monocle_container
    if ($null -ne $Workspace.PSObject.Properties['monocle_container'] -and $null -ne $Workspace.monocle_container) {
        $monocle = $Workspace.monocle_container
        $windows = Get-WindowsFromContainerObject -Container $monocle
        foreach ($w in $windows) {
            $results += [pscustomobject]@{
                hwnd = $w.hwnd
                title = $w.title
                exe = $w.exe
                class = $w.class
                monitorIndex = $MonitorIndex
                workspaceIndex = $WorkspaceIndex
                isFocusedWorkspace = $IsFocusedWorkspace
                layer = 'Monocle'
                containerIndex = $null
                windowIndex = $w.windowIndex
            }
        }
    }

    # 3. floating_windows
    if ($null -ne $Workspace.PSObject.Properties['floating_windows'] -and $null -ne $Workspace.floating_windows) {
        $elements = @()
        if ($null -ne $Workspace.floating_windows.PSObject.Properties['elements']) {
            $elements = @($Workspace.floating_windows.elements)
        } elseif ($Workspace.floating_windows -is [System.Array]) {
            $elements = $Workspace.floating_windows
        } else {
            $elements = @($Workspace.floating_windows)
        }
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $floatContainer = $elements[$i]
            $windows = Get-WindowsFromContainerObject -Container $floatContainer
            foreach ($w in $windows) {
                $results += [pscustomobject]@{
                    hwnd = $w.hwnd
                    title = $w.title
                    exe = $w.exe
                    class = $w.class
                    monitorIndex = $MonitorIndex
                    workspaceIndex = $WorkspaceIndex
                    isFocusedWorkspace = $IsFocusedWorkspace
                    layer = 'Floating'
                    containerIndex = $i
                    windowIndex = $w.windowIndex
                }
            }
        }
    }

    # 4. containers
    if ($null -ne $Workspace.PSObject.Properties['containers'] -and $null -ne $Workspace.containers) {
        $elements = @()
        if ($null -ne $Workspace.containers.PSObject.Properties['elements']) {
            $elements = @($Workspace.containers.elements)
        } elseif ($Workspace.containers -is [System.Array]) {
            $elements = $Workspace.containers
        } else {
            $elements = @($Workspace.containers)
        }
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $tiledContainer = $elements[$i]
            $windows = Get-WindowsFromContainerObject -Container $tiledContainer
            foreach ($w in $windows) {
                $results += [pscustomobject]@{
                    hwnd = $w.hwnd
                    title = $w.title
                    exe = $w.exe
                    class = $w.class
                    monitorIndex = $MonitorIndex
                    workspaceIndex = $WorkspaceIndex
                    isFocusedWorkspace = $IsFocusedWorkspace
                    layer = 'Tiling'
                    containerIndex = $i
                    windowIndex = $w.windowIndex
                }
            }
        }
    }

    return $results
}

function Get-KomorebiCommandOutput {
    param([string]$Arguments)

    $komorebicPath = $null
    try {
        $cmd = Get-Command 'komorebic' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) {
            $komorebicPath = $cmd.Source
        } else {
            $localPrograms = Join-Path $env:LOCALAPPDATA 'Programs'
            foreach ($candidate in @(
                (Join-Path $localPrograms 'komorebi\komorebic.exe'),
                (Join-Path $localPrograms 'komorebic\komorebic.exe')
            )) {
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $komorebicPath = $candidate
                    break
                }
            }
        }
    } catch {
        return @{
            ok = $false
            error = "Resolution failed: $($_.Exception.Message)"
            output = $null
        }
    }

    if ($null -eq $komorebicPath) {
        return @{
            ok = $false
            error = "komorebic.exe could not be resolved"
            output = $null
        }
    }

    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $komorebicPath
        $psi.Arguments = $Arguments
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        # Wait up to 5 seconds
        if ($proc.WaitForExit(5000)) {
            $stdout = $stdoutTask.Result
            $stderr = $stderrTask.Result
            if ($proc.ExitCode -eq 0) {
                return @{
                    ok = $true
                    error = $null
                    output = $stdout
                }
            } else {
                return @{
                    ok = $false
                    error = "Exit code $($proc.ExitCode). Stderr: $stderr"
                    output = $stdout
                }
            }
        } else {
            $proc.Kill()
            return @{
                ok = $false
                error = "Timeout waiting for komorebic $Arguments"
                output = $null
            }
        }
    } catch {
        return @{
            ok = $false
            error = $_.Exception.Message
            output = $null
        }
    }
}

function Resolve-SafeOutputDirectory {
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) {
        throw "Output directory path is empty"
    }

    $canonicalPath = [System.IO.Path]::GetFullPath($Path)

    # Walk up parent tree to verify none of existing components are reparse points (symlinks/junctions)
    $curr = $canonicalPath
    while ($true) {
        if (Test-Path -LiteralPath $curr) {
            $item = Get-Item -LiteralPath $curr -Force
            $isReparse = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            if ($isReparse) {
                throw "Output directory or its ancestor is a reparse point: $curr"
            }
        }
        $parent = Split-Path -Parent $curr
        if ($parent -eq $curr -or [string]::IsNullOrEmpty($parent)) {
            break
        }
        $curr = $parent
    }

    # Ensure parent folder exists so we only create the single leaf directory
    $parentDir = Split-Path -Parent $canonicalPath
    if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
        throw "Parent directory of the target output directory does not exist: $parentDir"
    }

    if (-not (Test-Path -LiteralPath $canonicalPath)) {
        $null = New-Item -ItemType Directory -Path $canonicalPath -Force
    }

    # Re-check reparse points after creating/resolving it
    $resolvedItem = Get-Item -LiteralPath $canonicalPath -Force
    $isReparseResolved = [bool]($resolvedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    if ($isReparseResolved) {
        throw "Resolved output directory is a reparse point: $canonicalPath"
    }

    return $canonicalPath
}

function Protect-TitleField {
    param(
        $InputObject,
        [bool]$IncludeTitles
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($IncludeTitles) {
        return $InputObject
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $newObj = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $name = $prop.Name
            $val = $prop.Value
            if ($name -ieq 'title') {
                $newObj[$name] = '[REDACTED]'
            } else {
                $newObj[$name] = Protect-TitleField -InputObject $val -IncludeTitles $false
            }
        }
        return [pscustomobject]$newObj
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $newDict = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $name = [string]$key
            $val = $InputObject[$key]
            if ($name -ieq 'title') {
                $newDict[$key] = '[REDACTED]'
            } else {
                $newDict[$key] = Protect-TitleField -InputObject $val -IncludeTitles $false
            }
        }
        return $newDict
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $newArray = New-Object System.Collections.Generic.List[System.Object]
        foreach ($item in $InputObject) {
            $newArray.Add((Protect-TitleField -InputObject $item -IncludeTitles $false))
        }
        return $newArray.ToArray()
    }

    return $InputObject
}

$warnings = New-Object System.Collections.Generic.List[string]

# 1. Load C# interop safely
try {
    if (-not ('KomorebiStarter.WindowDiagnostics' -as [type])) {
        $csPath = Join-Path $PSScriptRoot 'WindowDiagnostics.cs'
        if (-not (Test-Path -LiteralPath $csPath -PathType Leaf)) {
            throw "Window diagnostics interop source is missing from $PSScriptRoot"
        }
        Add-Type -Path $csPath -ErrorAction Stop
        if (-not ('KomorebiStarter.WindowDiagnostics' -as [type])) {
            throw "WindowDiagnostics type could not be loaded after compilation."
        }
    }
} catch {
    $errorJson = @{
        ok = $false
        timestamp = [DateTime]::UtcNow.ToString("o")
        error = "Failed to compile interop: $($_.Exception.Message)"
        windows = @()
        anomalies = @()
        warnings = @($warnings)
    } | ConvertTo-Json -Depth 8
    Write-Output $errorJson
    exit 1
}

# 2. Query Windows structures
$windows = @()
$systemDiag = $null
try {
    $windows = [KomorebiStarter.WindowDiagnostics]::CollectWindows()
    $systemDiag = [KomorebiStarter.WindowDiagnostics]::CollectSystemDiagnostics()
} catch {
    $errorJson = @{
        ok = $false
        timestamp = [DateTime]::UtcNow.ToString("o")
        error = "Failed to collect windows or system diagnostics: $($_.Exception.Message)"
        windows = @()
        anomalies = @()
        warnings = @($warnings)
    } | ConvertTo-Json -Depth 8
    Write-Output $errorJson
    exit 1
}

# 3. Query Komorebi best-effort
$stateRaw = Get-KomorebiCommandOutput -Arguments "state"
$globalStateRaw = Get-KomorebiCommandOutput -Arguments "global-state"
$visibleWindowsRaw = Get-KomorebiCommandOutput -Arguments "visible-windows"

$stateObj = $null
$stateError = $null
if ($stateRaw.ok) {
    try {
        $stateObj = $stateRaw.output | ConvertFrom-Json
    } catch {
        $stateError = "JSON parse failed: $($_.Exception.Message)"
    }
} else {
    $stateError = $stateRaw.error
}

$globalStateObj = $null
$globalStateError = $null
if ($globalStateRaw.ok) {
    try {
        $globalStateObj = $globalStateRaw.output | ConvertFrom-Json
    } catch {
        $globalStateError = "JSON parse failed: $($_.Exception.Message)"
    }
} else {
    $globalStateError = $globalStateRaw.error
}

$visibleWindowsObj = $null
$visibleWindowsError = $null
if ($visibleWindowsRaw.ok) {
    try {
        $visibleWindowsObj = $visibleWindowsRaw.output | ConvertFrom-Json
    } catch {
        $visibleWindowsError = "JSON parse failed: $($_.Exception.Message)"
    }
} else {
    $visibleWindowsError = $visibleWindowsRaw.error
}

# 4. Traverse and correlate Komorebi windows
$managedWindowsMap = @{}
if ($null -ne $stateObj) {
    if ($null -ne $stateObj.PSObject.Properties['monitors']) {
        $monitors = @()
        if ($null -ne $stateObj.monitors.PSObject.Properties['elements']) {
            $monitors = @($stateObj.monitors.elements)
        } else {
            $monitors = @($stateObj.monitors)
        }
        for ($mIdx = 0; $mIdx -lt $monitors.Count; $mIdx++) {
            $monitor = $monitors[$mIdx]
            if ($null -ne $monitor -and $null -ne $monitor.PSObject.Properties['workspaces']) {
                $workspaces = @()
                if ($null -ne $monitor.workspaces.PSObject.Properties['elements']) {
                    $workspaces = @($monitor.workspaces.elements)
                } else {
                    $workspaces = @($monitor.workspaces)
                }
                $focusedWorkspaceIndex = 0
                if ($null -ne $monitor.workspaces.PSObject.Properties['focused']) {
                    $focusedWorkspaceIndex = [int]$monitor.workspaces.focused
                } elseif ($null -ne $monitor.PSObject.Properties['focused_workspace_idx']) {
                    $focusedWorkspaceIndex = [int]$monitor.focused_workspace_idx
                }
                for ($wIdx = 0; $wIdx -lt $workspaces.Count; $wIdx++) {
                    $workspace = $workspaces[$wIdx]
                    if ($null -ne $workspace) {
                        $isFocusedWorkspace = ($wIdx -eq $focusedWorkspaceIndex)
                        $wsWindows = Get-AllWorkspaceWindows -MonitorIndex $mIdx -WorkspaceIndex $wIdx -Workspace $workspace -IsFocusedWorkspace $isFocusedWorkspace
                        foreach ($w in $wsWindows) {
                            $hwndVal = [long]$w.hwnd
                            if (-not $managedWindowsMap.ContainsKey($hwndVal)) {
                                $managedWindowsMap[$hwndVal] = $w
                            }
                        }
                    }
                }
            }
        }
    }
}

# 5. Process system context variables
$foregroundHwnd = [long]$systemDiag.ForegroundHwnd
$keyboardFocusHwnd = [long]$systemDiag.KeyboardFocusHwnd
$mouseUnderRootHwnd = [long]$systemDiag.MouseUnderRootHwnd

$foregroundRoot = 0L
if ($foregroundHwnd -ne 0 -and [KomorebiStarter.WindowDiagnostics]::IsWindow([IntPtr]::new($foregroundHwnd))) {
    $foregroundRoot = [KomorebiStarter.WindowDiagnostics]::GetAncestor([IntPtr]::new($foregroundHwnd), 2).ToInt64()
}

$keyboardFocusRoot = 0L
if ($keyboardFocusHwnd -ne 0 -and [KomorebiStarter.WindowDiagnostics]::IsWindow([IntPtr]::new($keyboardFocusHwnd))) {
    $keyboardFocusRoot = [KomorebiStarter.WindowDiagnostics]::GetAncestor([IntPtr]::new($keyboardFocusHwnd), 2).ToInt64()
}

# 6. Build enriched windows list and detect anomalies
$enrichedWindows = New-Object System.Collections.Generic.List[PSCustomObject]
$anomalyRecords = New-Object System.Collections.Generic.List[PSCustomObject]

foreach ($w in $windows) {
    $hwnd = [long]$w.Hwnd
    
    # Process filter
    if ($null -ne $ProcessName -and $ProcessName.Count -gt 0) {
        if ($null -eq $w.ProcessName -or $ProcessName -notcontains $w.ProcessName) {
            continue
        }
    }

    # Redact title if not requested
    $title = if ($IncludeTitles) { $w.Title } else { "[REDACTED]" }

    # Retrieve correlation from Komorebi
    $isManaged = $managedWindowsMap.ContainsKey($hwnd)
    $komorebiContext = $null
    $isManagedOnFocusedWorkspace = $false
    if ($isManaged) {
        $komorebiContext = $managedWindowsMap[$hwnd]
        $isManagedOnFocusedWorkspace = [bool]$komorebiContext.isFocusedWorkspace
    }

    # Check classifications
    $ownedPopup = ($w.OwnerHwnd -ne 0)
    $toolWindow = $w.WsExToolWindow
    $noActivate = $w.WsExNoActivate
    $layered = $w.WsExLayered
    $hidden = -not $w.IsVisible
    $cloaked = $w.IsCloaked
    $minimized = $w.IsMinimized
    $offscreen = $w.IsOffscreen
    $zeroArea = $w.IsZeroArea
    
    $isForeground = ($w.RootHwnd -ne 0 -and $foregroundRoot -ne 0 -and $w.RootHwnd -eq $foregroundRoot)
    $isKeyboardFocus = ($w.RootHwnd -ne 0 -and $keyboardFocusRoot -ne 0 -and $w.RootHwnd -eq $keyboardFocusRoot)
    $isMouseUnderRoot = ($w.RootHwnd -ne 0 -and $mouseUnderRootHwnd -ne 0 -and $w.RootHwnd -eq $mouseUnderRootHwnd)

    # Determine activation candidate
    # - Must not be a child window (top-level)
    # - Must be visible and enabled
    # - Must not be cloaked
    # - Must not have WS_EX_NOACTIVATE or WS_EX_TOOLWINDOW (unless it has WS_EX_APPWINDOW)
    # - Must not be zero area
    $isActivationCandidate = (-not $w.WsChild -and $w.IsVisible -and $w.IsEnabled -and -not $w.IsMinimized -and -not $w.IsCloaked -and -not $w.IsOffscreen -and -not $w.IsZeroArea -and -not $w.WsExNoActivate -and (-not $w.WsExToolWindow -or $w.WsExAppWindow))

    $classifications = @()
    if ($isManaged) { $classifications += "managed" }
    if ($isManagedOnFocusedWorkspace) { $classifications += "managed-on-focused-workspace" }
    if ($ownedPopup) { $classifications += "owned-popup" }
    if ($toolWindow) { $classifications += "tool-window" }
    if ($noActivate) { $classifications += "no-activate" }
    if ($layered) { $classifications += "layered" }
    if ($hidden) { $classifications += "hidden" }
    if ($cloaked) { $classifications += "cloaked" }
    if ($minimized) { $classifications += "minimized" }
    if ($offscreen) { $classifications += "offscreen" }
    if ($zeroArea) { $classifications += "zero-area" }
    if ($isForeground) { $classifications += "foreground" }
    if ($isKeyboardFocus) { $classifications += "keyboard-focus" }
    if ($isMouseUnderRoot) { $classifications += "mouse-under-root" }
    if ($isActivationCandidate) { $classifications += "activation-candidate" }

    $descriptor = [ordered]@{
        hwnd = $hwnd
        processId = $w.ProcessId
        processName = $w.ProcessName
        processPath = $w.ProcessPath
        title = $title
        class = $w.ClassName
        ownerHwnd = $w.OwnerHwnd
        rootHwnd = $w.RootHwnd
        rootOwnerHwnd = $w.RootOwnerHwnd
        lastActivePopupHwnd = $w.LastActivePopupHwnd
        visible = $w.IsVisible
        enabled = $w.IsEnabled
        minimized = $w.IsMinimized
        maximized = $w.IsMaximized
        hung = $w.IsHung
        cloaked = $w.IsCloaked
        cloakType = $w.CloakType
        rect = [ordered]@{
            left = $w.Left
            top = $w.Top
            right = $w.Right
            bottom = $w.Bottom
            width = $w.Width
            height = $w.Height
            area = $w.Area
        }
        style = $w.Style
        styleHex = "0x{0:X8}" -f $w.Style
        exStyle = $w.ExStyle
        exStyleHex = "0x{0:X8}" -f $w.ExStyle
        styleFlags = [ordered]@{
            WS_CHILD = $w.WsChild
            WS_DISABLED = $w.WsDisabled
            WS_MINIMIZE = $w.WsMinimize
            WS_VISIBLE = $w.WsVisible
            WS_EX_TOOLWINDOW = $w.WsExToolWindow
            WS_EX_NOACTIVATE = $w.WsExNoActivate
            WS_EX_LAYERED = $w.WsExLayered
            WS_EX_APPWINDOW = $w.WsExAppWindow
            WS_EX_TRANSPARENT = $w.WsExTransparent
        }
        classifications = $classifications
        komorebiCorrelation = if ($isManaged) {
            [ordered]@{
                monitorIndex = $komorebiContext.monitorIndex
                workspaceIndex = $komorebiContext.workspaceIndex
                layer = $komorebiContext.layer
                containerIndex = $komorebiContext.containerIndex
                windowIndex = $komorebiContext.windowIndex
            }
        } else {
            $null
        }
        error = $w.Error
    }

    $enrichedWindows.Add([pscustomobject]$descriptor)

    # 1. Managed focused-workspace window minimized but still occupying a tiling container index
    if ($isManagedOnFocusedWorkspace -and $minimized -and $komorebiContext.layer -ne "Floating") {
        $anomalyRecords.Add([pscustomobject]@{
            code = "MINIMIZED_BUT_TILED"
            hwnd = $hwnd
            message = "Managed window on focused workspace is minimized but still occupies a tiling container index $($komorebiContext.containerIndex)"
        })
    }

    # 2. Managed WS_EX_NOACTIVATE windows
    if ($isManaged -and $noActivate) {
        $anomalyRecords.Add([pscustomobject]@{
            code = "MANAGED_NOACTIVATE"
            hwnd = $hwnd
            message = "Window is managed by Komorebi but has WS_EX_NOACTIVATE style"
        })
    }

    # 3. Managed tool/owned-popup windows
    if ($isManaged -and ($toolWindow -or $ownedPopup)) {
        $anomalyRecords.Add([pscustomobject]@{
            code = "MANAGED_TOOL_OR_OWNED_POPUP"
            hwnd = $hwnd
            message = "Window is managed by Komorebi but is a tool window or owned popup"
        })
    }
}

# 4. Komorebi HWNDs that are no longer valid (either not found in enumeration or IsWindow is false)
foreach ($hwndKey in $managedWindowsMap.Keys) {
    $existsInEnum = $false
    foreach ($enumWin in $windows) {
        if ([long]$enumWin.Hwnd -eq [long]$hwndKey) {
            $existsInEnum = $true
            break
        }
    }
    $isValid = [KomorebiStarter.WindowDiagnostics]::IsWindow([IntPtr]::new($hwndKey))
    if (-not $existsInEnum -or -not $isValid) {
        $context = $managedWindowsMap[$hwndKey]
        $anomalyRecords.Add([pscustomobject]@{
            code = "INVALID_KOMOREBI_HWND"
            hwnd = [long]$hwndKey
            message = "HWND $hwndKey tracked in Komorebi state (Monitor: $($context.monitorIndex), Workspace: $($context.workspaceIndex)) is no longer a valid Win32 window"
        })
    }
}

# 5. Mismatch between Komorebi's focused window root, Win32 foreground root, and keyboard-focus root
$focusedKomorebiWin = $null
if ($null -ne $stateObj) {
    $focusedKomorebiWin = Get-FocusedKomorebiWindow -State $stateObj
}
$komorebiFocusedRoot = 0L
if ($null -ne $focusedKomorebiWin -and $null -ne $focusedKomorebiWin.PSObject.Properties['hwnd']) {
    $komorebiFocusedHwnd = [long]$focusedKomorebiWin.hwnd
    foreach ($enumWin in $windows) {
        if ([long]$enumWin.Hwnd -eq $komorebiFocusedHwnd) {
            $komorebiFocusedRoot = $enumWin.RootHwnd
            break
        }
    }
    if ($komorebiFocusedRoot -eq 0 -and [KomorebiStarter.WindowDiagnostics]::IsWindow([IntPtr]::new($komorebiFocusedHwnd))) {
        $komorebiFocusedRoot = [KomorebiStarter.WindowDiagnostics]::GetAncestor([IntPtr]::new($komorebiFocusedHwnd), 2).ToInt64()
    }
}

$hasMismatch = $false
if ($komorebiFocusedRoot -ne 0) {
    if ($foregroundRoot -ne 0 -and $komorebiFocusedRoot -ne $foregroundRoot) {
        $hasMismatch = $true
    }
    if ($keyboardFocusRoot -ne 0 -and $komorebiFocusedRoot -ne $keyboardFocusRoot) {
        $hasMismatch = $true
    }
}
if ($foregroundRoot -ne 0 -and $keyboardFocusRoot -ne 0 -and $foregroundRoot -ne $keyboardFocusRoot) {
    $hasMismatch = $true
}

if ($hasMismatch) {
    $anomalyRecords.Add([pscustomobject]@{
        code = "FOCUS_MISMATCH"
        hwnd = $komorebiFocusedRoot
        message = "Focus mismatch detected: KomorebiFocusedRoot=$komorebiFocusedRoot, ForegroundRoot=$foregroundRoot, KeyboardFocusRoot=$keyboardFocusRoot"
    })
}

# 7. Assemble final report
$redactedState = Protect-TitleField -InputObject $stateObj -IncludeTitles $IncludeTitles
$redactedGlobalState = Protect-TitleField -InputObject $globalStateObj -IncludeTitles $IncludeTitles
$redactedVisibleWindows = Protect-TitleField -InputObject $visibleWindowsObj -IncludeTitles $IncludeTitles

$report = [ordered]@{
    ok = $true
    timestamp = [DateTime]::UtcNow.ToString("o")
    system = [ordered]@{
        foregroundHwnd = $foregroundHwnd
        keyboardFocusHwnd = $keyboardFocusHwnd
        cursorX = if ($systemDiag.CursorAvailable) { $systemDiag.CursorX } else { $null }
        cursorY = if ($systemDiag.CursorAvailable) { $systemDiag.CursorY } else { $null }
        cursorAvailable = $systemDiag.CursorAvailable
        mouseUnderHwnd = if ($systemDiag.CursorAvailable) { $systemDiag.MouseUnderHwnd } else { $null }
        mouseUnderRootHwnd = if ($systemDiag.CursorAvailable) { $systemDiag.MouseUnderRootHwnd } else { $null }
    }
    komorebi = [ordered]@{
        state = $redactedState
        stateError = $stateError
        globalState = $redactedGlobalState
        globalStateError = $globalStateError
        visibleWindows = $redactedVisibleWindows
        visibleWindowsError = $visibleWindowsError
    }
    windows = $enrichedWindows
    anomalies = $anomalyRecords
    warnings = $warnings
    outputPath = $null
}

# 8. Resolve output directory and atomically write json if requested
if (-not [string]::IsNullOrEmpty($OutputDirectory)) {
    $tempFilePath = $null
    try {
        $safeDir = Resolve-SafeOutputDirectory -Path $OutputDirectory
        $timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")
        $fileName = "window-diagnostics-$timestamp.json"
        $filePath = Join-Path $safeDir $fileName
        
        # Set outputPath in report before serialization so it is included in the written file
        $report.outputPath = $filePath
        $jsonContent = [pscustomobject]$report | ConvertTo-Json -Depth 8 -Compress
        
        $tempFileName = "$([guid]::NewGuid().ToString()).tmp"
        $tempFilePath = Join-Path $safeDir $tempFileName
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempFilePath, $jsonContent, $utf8NoBom)
        
        if (Test-Path -LiteralPath $filePath) {
            throw "Target diagnostic file already exists: $filePath"
        }
        [System.IO.File]::Move($tempFilePath, $filePath)
    } catch {
        $warnings.Add("Failed to write diagnostic file to output directory: $($_.Exception.Message)")
        if ($null -ne $tempFilePath -and (Test-Path -LiteralPath $tempFilePath)) {
            Remove-Item -LiteralPath $tempFilePath -Force -ErrorAction SilentlyContinue
        }
        $report.outputPath = $null
    }
}

# 9. Output single JSON object to stdout
$finalJson = [pscustomobject]$report | ConvertTo-Json -Depth 8
Write-Output $finalJson
