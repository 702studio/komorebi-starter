Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-FocusInterop {
    if ('KomorebiStarter.NativeFocus' -as [type]) {
        return
    }

    $assemblyPath = Join-Path $PSScriptRoot 'FocusInterop.dll'
    if (Test-Path -LiteralPath $assemblyPath -PathType Leaf) {
        Add-Type -Path $assemblyPath
        return
    }

    $sourcePath = Join-Path $PSScriptRoot 'FocusInterop.cs'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Focus interop source and assembly are missing from $PSScriptRoot"
    }
    Add-Type -Path $sourcePath
}

function ConvertTo-WindowHandle {
    param([Parameter(Mandatory = $true)][long]$Value)

    return [IntPtr]::new($Value)
}

function ConvertFrom-WindowHandle {
    param([Parameter(Mandatory = $true)][IntPtr]$Value)

    return $Value.ToInt64()
}

function Get-RootWindowHandle {
    param([Parameter(Mandatory = $true)][IntPtr]$Window)

    Initialize-FocusInterop
    if ($Window -eq [IntPtr]::Zero) {
        return [IntPtr]::Zero
    }

    $root = [KomorebiStarter.NativeFocus]::GetAncestor($Window, 2)
    if ($root -eq [IntPtr]::Zero) {
        return $Window
    }
    return $root
}

function Get-RootOwnerWindowHandle {
    param([Parameter(Mandatory = $true)][IntPtr]$Window)

    Initialize-FocusInterop
    if ($Window -eq [IntPtr]::Zero) {
        return [IntPtr]::Zero
    }

    $rootOwner = [KomorebiStarter.NativeFocus]::GetAncestor($Window, 3)
    if ($rootOwner -eq [IntPtr]::Zero) {
        return $Window
    }
    return $rootOwner
}

function Get-CursorSnapshot {
    Initialize-FocusInterop
    $point = [KomorebiStarter.NativeFocus+Point]::new()
    $available = [KomorebiStarter.NativeFocus]::GetCursorPos([ref]$point)
    [pscustomobject]@{
        available = $available
        x = $point.X
        y = $point.Y
    }
}

function Test-CursorSnapshotChanged {
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )

    return ($Before.available -and $After.available -and
        ($Before.x -ne $After.x -or $Before.y -ne $After.y))
}

function Get-ActivationTarget {
    param([Parameter(Mandatory = $true)][long]$WindowHandle)

    Initialize-FocusInterop
    $managedWindow = ConvertTo-WindowHandle -Value $WindowHandle
    if ($managedWindow -eq [IntPtr]::Zero -or -not [KomorebiStarter.NativeFocus]::IsWindow($managedWindow)) {
        throw "Invalid managed window handle: $WindowHandle"
    }

    $managedRoot = Get-RootWindowHandle -Window $managedWindow
    $managedRootOwner = Get-RootOwnerWindowHandle -Window $managedRoot
    $activationWindow = $managedRoot
    $modalRedirect = $false
    $blockedReason = $null
    $managedRootEnabled = [KomorebiStarter.NativeFocus]::IsWindowEnabled($managedRoot)

    $exStyle = [KomorebiStarter.NativeFocus]::GetWindowLongPtr($managedRoot, -20).ToInt64()
    $managedRootNoActivate = (($exStyle -band 0x08000000) -ne 0)
    $managedRootMinimized = [KomorebiStarter.NativeFocus]::IsIconic($managedRoot)

    if (-not [KomorebiStarter.NativeFocus]::IsWindowVisible($managedRoot)) {
        $blockedReason = 'managed-root-not-visible'
    } elseif ($managedRootMinimized) {
        $blockedReason = 'managed-root-minimized'
    } elseif ($managedRootNoActivate) {
        $blockedReason = 'managed-root-noactivate'
    } elseif (-not $managedRootEnabled) {
        $popup = [KomorebiStarter.NativeFocus]::GetLastActivePopup($managedRoot)
        if ($popup -eq $managedRoot -or $popup -eq [IntPtr]::Zero) {
            $blockedReason = 'managed-root-disabled'
        } else {
            $popupRootOwner = Get-RootOwnerWindowHandle -Window $popup
            $popupExStyle = [KomorebiStarter.NativeFocus]::GetWindowLongPtr($popup, -20).ToInt64()
            $popupNoActivate = (($popupExStyle -band 0x08000000) -ne 0)
            $popupMinimized = [KomorebiStarter.NativeFocus]::IsIconic($popup)

            $validPopup = ([KomorebiStarter.NativeFocus]::IsWindow($popup) -and
                [KomorebiStarter.NativeFocus]::IsWindowVisible($popup) -and
                [KomorebiStarter.NativeFocus]::IsWindowEnabled($popup) -and
                -not $popupMinimized -and
                -not $popupNoActivate -and
                $popupRootOwner -eq $managedRootOwner)
            if ($validPopup) {
                $activationWindow = $popup
                $modalRedirect = $true
            } else {
                $blockedReason = 'modal-blocked-no-valid-popup'
            }
        }
    }

    [pscustomobject]@{
        managedWindow = $managedWindow
        managedRoot = $managedRoot
        managedRootOwner = $managedRootOwner
        activationWindow = $activationWindow
        expectedRoot = Get-RootWindowHandle -Window $activationWindow
        modalRedirect = $modalRedirect
        managedRootEnabled = $managedRootEnabled
        blockedReason = $blockedReason
    }
}

function Invoke-ForegroundActivation {
    param(
        [Parameter(Mandatory = $true)][long]$WindowHandle,
        [long]$PreviousForegroundRootHwnd = 0,
        [ValidateRange(1, 3)][int]$MaxAttempts = 3,
        [ValidateRange(50, 500)][int]$DeadlineMilliseconds = 250,
        [ValidateRange(10, 100)][int]$DelayMilliseconds = 25
    )

    Initialize-FocusInterop
    $target = Get-ActivationTarget -WindowHandle $WindowHandle
    $targetProcessId = [int][KomorebiStarter.NativeFocus]::GetWindowProcessId($target.activationWindow)
    $cursorBefore = Get-CursorSnapshot
    $initialForeground = [KomorebiStarter.NativeFocus]::GetForegroundWindow()
    $initialForegroundRoot = Get-RootWindowHandle -Window $initialForeground
    $foreground = $initialForeground
    $foregroundRoot = $initialForegroundRoot
    $keyboardFocus = [KomorebiStarter.NativeFocus]::GetKeyboardFocusWindow()
    $keyboardFocusRoot = Get-RootWindowHandle -Window $keyboardFocus

    $foregroundMatches = ($foregroundRoot -eq $target.expectedRoot)
    $keyboardFocusMatches = ($keyboardFocus -eq [IntPtr]::Zero -or $keyboardFocusRoot -eq $target.expectedRoot)
    $verified = ($foregroundMatches -and $keyboardFocusMatches)
    $initialVerified = $verified
    $attempts = 0
    $setForegroundAccepted = $false
    $reason = $target.blockedReason
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()

    while (-not $verified -and [string]::IsNullOrEmpty($reason) -and $attempts -lt $MaxAttempts) {
        if ($stopwatch.ElapsedMilliseconds -ge $DeadlineMilliseconds) {
            $reason = 'deadline-exceeded'
            break
        }

        $currentCursor = Get-CursorSnapshot
        if (Test-CursorSnapshotChanged -Before $cursorBefore -After $currentCursor) {
            $reason = 'mouse-moved'
            break
        }
        if (-not [KomorebiStarter.NativeFocus]::IsWindow($target.activationWindow) -or
            -not [KomorebiStarter.NativeFocus]::IsWindowVisible($target.activationWindow) -or
            -not [KomorebiStarter.NativeFocus]::IsWindowEnabled($target.activationWindow) -or
            [int][KomorebiStarter.NativeFocus]::GetWindowProcessId($target.activationWindow) -ne $targetProcessId) {
            $reason = 'activation-target-invalidated'
            break
        }

        $foreground = [KomorebiStarter.NativeFocus]::GetForegroundWindow()
        $foregroundRoot = Get-RootWindowHandle -Window $foreground
        $keyboardFocus = [KomorebiStarter.NativeFocus]::GetKeyboardFocusWindow()
        $keyboardFocusRoot = Get-RootWindowHandle -Window $keyboardFocus

        $foregroundMatches = ($foregroundRoot -eq $target.expectedRoot)
        $keyboardFocusMatches = ($keyboardFocus -eq [IntPtr]::Zero -or $keyboardFocusRoot -eq $target.expectedRoot)
        if ($foregroundMatches -and $keyboardFocusMatches) {
            $verified = $true
            break
        }

        if ($PreviousForegroundRootHwnd -ne 0 -and
            $foregroundRoot -ne [IntPtr]::Zero -and
            (ConvertFrom-WindowHandle -Value $foregroundRoot) -ne $PreviousForegroundRootHwnd) {
            $reason = 'foreground-changed'
            break
        }

        $attempts++
        $setForegroundAccepted = [KomorebiStarter.NativeFocus]::SetForegroundWindow($target.activationWindow)
        $remaining = $DeadlineMilliseconds - [int]$stopwatch.ElapsedMilliseconds
        if ($remaining -gt 0) {
            Start-Sleep -Milliseconds ([Math]::Min($DelayMilliseconds, $remaining))
        }

        $foreground = [KomorebiStarter.NativeFocus]::GetForegroundWindow()
        $foregroundRoot = Get-RootWindowHandle -Window $foreground
        $keyboardFocus = [KomorebiStarter.NativeFocus]::GetKeyboardFocusWindow()
        $keyboardFocusRoot = Get-RootWindowHandle -Window $keyboardFocus

        $foregroundMatches = ($foregroundRoot -eq $target.expectedRoot)
        $keyboardFocusMatches = ($keyboardFocus -eq [IntPtr]::Zero -or $keyboardFocusRoot -eq $target.expectedRoot)
        $verified = ($foregroundMatches -and $keyboardFocusMatches)

        $currentCursor = Get-CursorSnapshot
        if (Test-CursorSnapshotChanged -Before $cursorBefore -After $currentCursor) {
            $verified = $false
            $reason = 'mouse-moved'
        }
    }

    $stopwatch.Stop()

    # Final post-loop verify
    $foreground = [KomorebiStarter.NativeFocus]::GetForegroundWindow()
    $foregroundRoot = Get-RootWindowHandle -Window $foreground
    $keyboardFocus = [KomorebiStarter.NativeFocus]::GetKeyboardFocusWindow()
    $keyboardFocusRoot = Get-RootWindowHandle -Window $keyboardFocus

    $foregroundMatches = ($foregroundRoot -eq $target.expectedRoot)
    $keyboardFocusMatches = ($keyboardFocus -eq [IntPtr]::Zero -or $keyboardFocusRoot -eq $target.expectedRoot)
    $verified = ($foregroundMatches -and $keyboardFocusMatches)

    if ($verified) {
        $reason = if ($initialVerified) { 'already-foreground' } else { 'repaired' }
    } elseif ([string]::IsNullOrEmpty($reason)) {
        $reason = if ($stopwatch.ElapsedMilliseconds -ge $DeadlineMilliseconds) { 'deadline-exceeded' } else { 'foreground-denied' }
    }

    $cursorAfter = Get-CursorSnapshot
    $cursorMoved = Test-CursorSnapshotChanged -Before $cursorBefore -After $cursorAfter
    if (-not $verified -and $cursorMoved -and $reason -ne 'mouse-moved') {
        $reason = 'mouse-moved'
    }

    [pscustomobject]@{
        ok = $verified
        reason = $reason
        managedHwnd = ConvertFrom-WindowHandle -Value $target.managedWindow
        managedRootHwnd = ConvertFrom-WindowHandle -Value $target.managedRoot
        activationHwnd = ConvertFrom-WindowHandle -Value $target.activationWindow
        expectedRootHwnd = ConvertFrom-WindowHandle -Value $target.expectedRoot
        initialForegroundHwnd = ConvertFrom-WindowHandle -Value $initialForeground
        initialForegroundRootHwnd = ConvertFrom-WindowHandle -Value $initialForegroundRoot
        foregroundHwnd = ConvertFrom-WindowHandle -Value $foreground
        foregroundRootHwnd = ConvertFrom-WindowHandle -Value $foregroundRoot
        keyboardFocusHwnd = ConvertFrom-WindowHandle -Value $keyboardFocus
        keyboardFocusRootHwnd = ConvertFrom-WindowHandle -Value $keyboardFocusRoot
        foregroundMatches = $foregroundMatches
        keyboardFocusMatches = $keyboardFocusMatches
        repaired = (-not $initialVerified -and $verified)
        modalRedirect = $target.modalRedirect
        managedRootEnabled = $target.managedRootEnabled
        attempts = $attempts
        elapsedMilliseconds = $stopwatch.ElapsedMilliseconds
        setForegroundAccepted = $setForegroundAccepted
        cursorMoved = $cursorMoved
    }
}

function Get-NativeWindowDescriptor {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [switch]$IncludeMetadata
    )

    Initialize-FocusInterop
    if ($Window -eq [IntPtr]::Zero -or -not [KomorebiStarter.NativeFocus]::IsWindow($Window)) {
        return $null
    }

    $root = Get-RootWindowHandle -Window $Window
    $descriptor = [ordered]@{
        hwnd = ConvertFrom-WindowHandle -Value $Window
        rootHwnd = ConvertFrom-WindowHandle -Value $root
        visible = [KomorebiStarter.NativeFocus]::IsWindowVisible($Window)
        enabled = [KomorebiStarter.NativeFocus]::IsWindowEnabled($Window)
    }
    if ($IncludeMetadata) {
        $processId = [int][KomorebiStarter.NativeFocus]::GetWindowProcessId($Window)
        $processName = $null
        if ($processId -gt 0) {
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($process) {
                $processName = $process.ProcessName
            }
        }
        $descriptor['processId'] = $processId
        $descriptor['processName'] = $processName
        $descriptor['title'] = [KomorebiStarter.NativeFocus]::ReadWindowText($Window)
        $descriptor['class'] = [KomorebiStarter.NativeFocus]::ReadWindowClass($Window)
    }
    return [pscustomobject]$descriptor
}

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
    $monitor = Get-CollectionFocusedElement -Collection $State.monitors
    if ($null -eq $monitor -or $null -eq $monitor.PSObject.Properties['workspaces']) {
        return $null
    }
    $workspace = Get-CollectionFocusedElement -Collection $monitor.workspaces
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
