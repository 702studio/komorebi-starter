[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$IncludeWindowMetadata
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'FocusInterop.ps1')
Initialize-FocusInterop

function Resolve-KomorebicPath {
    $command = Get-Command 'komorebic' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    $localPrograms = Join-Path $env:LOCALAPPDATA 'Programs'
    foreach ($candidate in @(
        (Join-Path $localPrograms 'komorebi\komorebic.exe'),
        (Join-Path $localPrograms 'komorebic\komorebic.exe')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    throw 'komorebic.exe is not installed or could not be found'
}

$komorebic = Resolve-KomorebicPath
$stateText = @(& $komorebic state 2>&1) -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0) {
    throw "komorebic state failed: $stateText"
}
$state = $stateText | ConvertFrom-Json
$managed = Get-FocusedKomorebiWindow -State $state
$foregroundWindow = [KomorebiStarter.NativeFocus]::GetForegroundWindow()
$foreground = Get-NativeWindowDescriptor -Window $foregroundWindow -IncludeMetadata:$IncludeWindowMetadata
$keyboardWindow = [KomorebiStarter.NativeFocus]::GetKeyboardFocusWindow()
$keyboardFocus = Get-NativeWindowDescriptor -Window $keyboardWindow -IncludeMetadata:$IncludeWindowMetadata
$cursor = Get-CursorSnapshot
$mouseWindow = [IntPtr]::Zero
if ($cursor.available) {
    $point = [KomorebiStarter.NativeFocus+Point]::new()
    $point.X = $cursor.x
    $point.Y = $cursor.y
    $mouseWindow = [KomorebiStarter.NativeFocus]::WindowFromPoint($point)
}
$mouseUnder = Get-NativeWindowDescriptor -Window $mouseWindow -IncludeMetadata:$IncludeWindowMetadata

$classification = 'no-managed-target'
$managedDescriptor = $null
$activationDescriptor = $null
$modalRedirect = $false
$expectedRootHwnd = 0L
$foregroundMatches = $false
$keyboardMatches = $false

if ($null -ne $managed -and $null -ne $managed.PSObject.Properties['hwnd']) {
    $managedHwnd = [long]$managed.hwnd
    $managedDescriptor = Get-NativeWindowDescriptor -Window (ConvertTo-WindowHandle -Value $managedHwnd) -IncludeMetadata:$IncludeWindowMetadata
    $activation = Get-ActivationTarget -WindowHandle $managedHwnd
    $activationDescriptor = Get-NativeWindowDescriptor -Window $activation.activationWindow -IncludeMetadata:$IncludeWindowMetadata
    $modalRedirect = $activation.modalRedirect
    $expectedRootHwnd = ConvertFrom-WindowHandle -Value $activation.expectedRoot
    $foregroundMatches = ($null -ne $foreground -and [long]$foreground.rootHwnd -eq $expectedRootHwnd)
    $keyboardMatches = ($null -eq $keyboardFocus -or [long]$keyboardFocus.rootHwnd -eq $expectedRootHwnd)
    $classification = if (-not [string]::IsNullOrEmpty($activation.blockedReason)) {
        $activation.blockedReason
    } elseif (-not $foregroundMatches) {
        'foreground-mismatch'
    } elseif (-not $keyboardMatches) {
        'keyboard-focus-mismatch'
    } elseif ($modalRedirect) {
        'healthy-modal-redirect'
    } else {
        'healthy'
    }
}

$hints = @()
$foregroundProcessId = if ($foregroundWindow -eq [IntPtr]::Zero) { 0 } else { [int][KomorebiStarter.NativeFocus]::GetWindowProcessId($foregroundWindow) }
$foregroundProcess = if ($foregroundProcessId -gt 0) { Get-Process -Id $foregroundProcessId -ErrorAction SilentlyContinue } else { $null }
$parsecActive = ($null -ne $foregroundProcess -and $foregroundProcess.ProcessName -match '(?i)parsec')
if ($parsecActive) {
    $hints += 'Parsec immersive input can prevent local whkd shortcuts from reaching Windows. Toggle immersive mode or detach input before retrying local focus shortcuts.'
}
if ($classification -eq 'foreground-mismatch') {
    $hints += 'Komorebi focus and the Win32 foreground root disagree. Run wm focus in the intended direction and inspect its verified result.'
}
if ($modalRedirect) {
    $hints += 'The managed owner is disabled by a modal window; the visible enabled last-active popup is the valid activation target.'
}
if ($classification -eq 'modal-blocked-no-valid-popup') {
    $hints += 'The managed owner is disabled, but Windows did not expose a visible enabled last-active popup. Inspect the application-specific modal rule.'
}

$report = [pscustomobject]@{
    ok = ($classification -like 'healthy*')
    classification = $classification
    timestamp = (Get-Date).ToString('o')
    expectedRootHwnd = $expectedRootHwnd
    foregroundMatches = $foregroundMatches
    keyboardMatches = $keyboardMatches
    modalRedirect = $modalRedirect
    parsecForeground = $parsecActive
    includesWindowMetadata = [bool]$IncludeWindowMetadata
    komorebi = if ($null -eq $managed) { $null } else {
        $komorebiWindow = [ordered]@{
            hwnd = [long]$managed.hwnd
        }
        if ($IncludeWindowMetadata) {
            $komorebiWindow['title'] = [string]$managed.title
            $komorebiWindow['exe'] = [string]$managed.exe
            $komorebiWindow['class'] = [string]$managed.class
        }
        [pscustomobject]$komorebiWindow
    }
    managedTarget = $managedDescriptor
    activationTarget = $activationDescriptor
    foreground = $foreground
    keyboardFocus = $keyboardFocus
    mouseUnder = $mouseUnder
    cursor = $cursor
    hints = $hints
}

if ($Json) {
    $report | ConvertTo-Json -Depth 8 -Compress
} else {
    $report | ConvertTo-Json -Depth 8
}
