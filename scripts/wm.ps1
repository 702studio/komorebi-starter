[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$ArgumentList
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-CommandPath {
    param([string]$CommandName)
    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $localPrograms = Join-Path $env:LOCALAPPDATA 'Programs'
    $candidates = @(
        (Join-Path $localPrograms "$CommandName\$CommandName.exe"),
        (Join-Path $localPrograms "komorebi\$CommandName.exe"),
        (Join-Path $localPrograms "whkd\$CommandName.exe"),
        (Join-Path $localPrograms "masir\$CommandName.exe")
    )
    if ($CommandName -eq 'komorebic') {
        $candidates += (Join-Path $localPrograms 'komorebi\komorebic.exe')
    }

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }
    return $null
}

$komorebicPath = Resolve-CommandPath 'komorebic'
if (-not $komorebicPath) {
    throw 'komorebic.exe is not installed or could not be found'
}

$script:Komorebic = $komorebicPath
$script:ConfigHome = if ($env:KOMOREBI_CONFIG_HOME) {
    $env:KOMOREBI_CONFIG_HOME
} else {
    Join-Path $env:USERPROFILE '.config\komorebi'
}
$script:ConfigPath = Join-Path $script:ConfigHome 'komorebi.json'
$script:RuntimeRoot = Join-Path $env:LOCALAPPDATA 'KomorebiStarter\agent'
$script:StartScript = Join-Path $PSScriptRoot 'start.ps1'
$script:DefaultResizeDelta = 50

function Assert-ArgumentCount {
    param(
        [int]$Minimum,
        [string]$Usage
    )

    if (@($ArgumentList).Count -lt $Minimum) {
        throw "Usage: wm $Usage"
    }
}

function Invoke-KomorebicRaw {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = @(& $script:Komorebic @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw "komorebic $($Arguments -join ' ') failed with exit code $exitCode"
        }
        throw $text
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output = $text
    }
}

function Invoke-KomorebicAction {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $null = Invoke-KomorebicRaw -Arguments $Arguments
}

function Get-KomorebiState {
    $result = Invoke-KomorebicRaw -Arguments @('state')
    try {
        return $result.Output | ConvertFrom-Json
    } catch {
        throw "komorebic state did not return valid JSON: $($result.Output)"
    }
}

function Get-FocusedMonitorContext {
    param([Parameter(Mandatory = $true)]$State)

    $monitors = @($State.monitors.elements)
    if ($monitors.Count -eq 0) {
        throw 'No monitors were found in komorebi state.'
    }

    $focusedIndex = 0
    if ($null -ne $State.monitors.PSObject.Properties['focused']) {
        $focusedIndex = [int]$State.monitors.focused
    } elseif ($null -ne $State.PSObject.Properties['focused_monitor_idx']) {
        $focusedIndex = [int]$State.focused_monitor_idx
    }

    if ($focusedIndex -lt 0 -or $focusedIndex -ge $monitors.Count) {
        $focusedIndex = 0
    }

    $monitor = $monitors[$focusedIndex]
    $workspaces = @($monitor.workspaces.elements)
    $focusedWorkspaceIndex = 0
    if ($null -ne $monitor.workspaces.PSObject.Properties['focused']) {
        $focusedWorkspaceIndex = [int]$monitor.workspaces.focused
    } elseif ($null -ne $monitor.PSObject.Properties['focused_workspace_idx']) {
        $focusedWorkspaceIndex = [int]$monitor.focused_workspace_idx
    }

    [pscustomobject]@{
        MonitorIndex = $focusedIndex
        Monitor = $monitor
        Workspaces = $workspaces
        FocusedWorkspaceIndex = $focusedWorkspaceIndex
    }
}

function Get-WorkspaceWindowCount {
    param([Parameter(Mandatory = $true)]$Workspace)

    $count = 0
    if ($null -ne $Workspace.PSObject.Properties['containers']) {
        $count += @($Workspace.containers.elements).Count
    }
    if ($null -ne $Workspace.PSObject.Properties['floating_windows']) {
        $floating = $Workspace.floating_windows
        if ($null -ne $floating.PSObject.Properties['elements']) {
            $count += @($floating.elements).Count
        } else {
            $count += @($floating).Count
        }
    }
    if ($null -ne $Workspace.PSObject.Properties['floating_layer']) {
        $layer = $Workspace.floating_layer
        if ($null -ne $layer.PSObject.Properties['windows']) {
            $count += @($layer.windows).Count
        } elseif ($null -ne $layer.PSObject.Properties['elements']) {
            $count += @($layer.elements).Count
        }
    }
    if ($null -ne $Workspace.PSObject.Properties['monocle_container'] -and $null -ne $Workspace.monocle_container) {
        $count += 1
    }

    return $count
}

function Invoke-ActiveWorkspaceCycle {
    param([ValidateSet('previous', 'next')][string]$Direction)

    $context = Get-FocusedMonitorContext -State (Get-KomorebiState)
    $occupied = @()
    for ($index = 0; $index -lt $context.Workspaces.Count; $index++) {
        if ((Get-WorkspaceWindowCount -Workspace $context.Workspaces[$index]) -gt 0) {
            $occupied += $index
        }
    }

    if ($occupied.Count -eq 0) {
        return
    }

    $current = $context.FocusedWorkspaceIndex
    $position = [Array]::IndexOf([int[]]$occupied, [int]$current)
    if ($position -lt 0) {
        if ($Direction -eq 'next') {
            $target = @($occupied | Where-Object { $_ -gt $current } | Select-Object -First 1)
            $target = if ($target.Count) { $target[0] } else { $occupied[0] }
        } else {
            $target = @($occupied | Where-Object { $_ -lt $current } | Select-Object -Last 1)
            $target = if ($target.Count) { $target[0] } else { $occupied[-1] }
        }
    } else {
        $step = if ($Direction -eq 'next') { 1 } else { -1 }
        $targetPosition = ($position + $step + $occupied.Count) % $occupied.Count
        $target = $occupied[$targetPosition]
    }

    Invoke-KomorebicAction -Arguments @('focus-workspace', [string]$target)
}

function Get-FocusedMonitorDimension {
    param([ValidateSet('width', 'height')][string]$Axis)

    $dimension = 0
    try {
        $context = Get-FocusedMonitorContext -State (Get-KomorebiState)
        $monitor = $context.Monitor
        foreach ($propertyName in @('work_area_size', 'size', 'rect')) {
            if ($null -eq $monitor.PSObject.Properties[$propertyName]) {
                continue
            }
            $rect = $monitor.$propertyName
            $candidateNames = if ($Axis -eq 'width') { @('right', 'width') } else { @('bottom', 'height') }
            foreach ($candidate in $candidateNames) {
                if ($null -ne $rect.PSObject.Properties[$candidate]) {
                    $dimension = [int]$rect.$candidate
                    if ($dimension -gt 0) {
                        return $dimension
                    }
                }
            }
        }
    } catch {
        $dimension = 0
    }

    Add-Type -AssemblyName System.Windows.Forms
    $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
    return if ($Axis -eq 'width') { $screen.WorkingArea.Width } else { $screen.WorkingArea.Height }
}

function Invoke-PercentageResize {
    param(
        [ValidateSet('width', 'height')][string]$Axis,
        [double]$Percentage
    )

    if ($Percentage -eq 0) {
        return
    }

    $dimension = Get-FocusedMonitorDimension -Axis $Axis
    $pixels = [Math]::Max(1, [Math]::Round($dimension * ([Math]::Abs($Percentage) / 100.0)))
    $komorebiAxis = if ($Axis -eq 'width') { 'horizontal' } else { 'vertical' }
    $sizing = if ($Percentage -gt 0) { 'increase' } else { 'decrease' }

    try {
        Invoke-KomorebicAction -Arguments @('resize-delta', [string]$pixels)
        Invoke-KomorebicAction -Arguments @('resize-axis', $komorebiAxis, $sizing)
    } finally {
        $null = Invoke-KomorebicRaw -Arguments @('resize-delta', [string]$script:DefaultResizeDelta) -AllowFailure
    }
}

function Invoke-LayoutCommand {
    param([string]$Target)

    $layoutNames = @('grid', 'horizontal-stack', 'columns', 'rows')
    $aliases = @{
        fair = 'grid'
        fair_horizontal = 'horizontal-stack'
        'fair-horizontal' = 'horizontal-stack'
        columns = 'columns'
        rows = 'rows'
    }

    $normalized = $Target.ToLowerInvariant()
    if ($aliases.ContainsKey($normalized)) {
        $normalized = $aliases[$normalized]
    }

    if ($normalized -in @('next', 'previous')) {
        $query = Invoke-KomorebicRaw -Arguments @('query', 'focused-workspace-layout')
        $current = $query.Output.Trim().Trim('"').ToLowerInvariant()
        $current = $current -replace 'horizontalstack', 'horizontal-stack'
        $position = [Array]::IndexOf([string[]]$layoutNames, $current)
        if ($position -lt 0) {
            $position = 0
        }
        $step = if ($normalized -eq 'next') { 1 } else { -1 }
        $normalized = $layoutNames[($position + $step + $layoutNames.Count) % $layoutNames.Count]
    }

    if ($normalized -notin $layoutNames) {
        throw "Unknown layout '$Target'. Expected fair, fair-horizontal, columns, rows, next or previous."
    }

    Invoke-KomorebicAction -Arguments @('change-layout', $normalized)
}

function Start-DetachedScript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Arguments = @()
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Script not found: $Path"
    }

    $argumentTokens = @(
        '-NoProfile',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $Path)
    ) + $Arguments

    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentTokens -WindowStyle Hidden | Out-Null
}

function Resolve-ConfiguredApplication {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('terminal', 'firefox', 'explorer', 'obsidian', 'flow', 'cursor')]
        [string]$Name
    )

    $spec = switch ($Name) {
        'terminal' {
            @{
                Commands = @('wt.exe', 'wt')
                Paths = @()
                AppIds = @('Microsoft.WindowsTerminal_8wekyb3d8bbwe!App')
                AppNames = @('Terminal', 'Windows Terminal')
            }
        }
        'firefox' {
            @{
                Commands = @('firefox.exe')
                Paths = @(
                    (Join-Path (Join-Path $env:ProgramFiles 'Mozilla Firefox') 'firefox.exe'),
                    (Join-Path (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Mozilla Firefox') 'firefox.exe')
                )
                AppIds = @('308046B0AF4A39CB')
                AppNames = @('Firefox')
            }
        }
        'explorer' {
            @{
                Commands = @('explorer.exe')
                Paths = @((Join-Path $env:SystemRoot 'explorer.exe'))
                AppIds = @()
                AppNames = @('File Explorer')
            }
        }
        'obsidian' {
            @{
                Commands = @('obsidian.exe')
                Paths = @(
                    (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'Obsidian') 'Obsidian.exe'),
                    (Join-Path (Join-Path $env:LOCALAPPDATA 'Obsidian') 'Obsidian.exe')
                )
                AppIds = @('md.obsidian')
                AppNames = @('Obsidian')
            }
        }
        'flow' {
            @{
                Commands = @('Flow.Launcher.exe')
                Paths = @((Join-Path (Join-Path $env:LOCALAPPDATA 'FlowLauncher') 'Flow.Launcher.exe'))
                AppIds = @('com.squirrel.FlowLauncher.Flow.Launcher')
                AppNames = @('Flow Launcher')
            }
        }
        'cursor' {
            @{
                Commands = @('cursor.exe', 'cursor')
                Paths = @((Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'cursor') 'Cursor.exe'))
                AppIds = @('Anysphere.Cursor', 'com.todesktop.230313mzl4w4u92')
                AppNames = @('Cursor')
            }
        }
    }

    foreach ($path in @($spec.Paths)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [pscustomobject]@{
                name = $Name
                method = 'executable'
                target = [IO.Path]::GetFullPath($path)
            }
        }
    }

    foreach ($commandName in @($spec.Commands)) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and -not [string]::IsNullOrWhiteSpace($command.Source) -and
            (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            return [pscustomobject]@{
                name = $Name
                method = 'executable'
                target = [IO.Path]::GetFullPath($command.Source)
            }
        }
    }

    $startApps = @(Get-StartApps -ErrorAction SilentlyContinue)
    $startApp = $null
    foreach ($appId in @($spec.AppIds)) {
        $startApp = $startApps | Where-Object AppId -EQ $appId | Select-Object -First 1
        if ($startApp) {
            break
        }
    }
    if (-not $startApp) {
        foreach ($appName in @($spec.AppNames)) {
            $startApp = $startApps | Where-Object Name -EQ $appName | Select-Object -First 1
            if ($startApp) {
                break
            }
        }
    }

    if ($startApp) {
        $shell = New-Object -ComObject Shell.Application
        $item = $shell.Namespace('shell:AppsFolder').ParseName([string]$startApp.AppId)
        $targetPath = if ($item) { [string]$item.ExtendedProperty('System.Link.TargetParsingPath') } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($targetPath) -and
            (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            return [pscustomobject]@{
                name = $Name
                method = 'executable'
                target = [IO.Path]::GetFullPath($targetPath)
            }
        }

        return [pscustomobject]@{
            name = $Name
            method = 'apps-folder'
            target = [string]$startApp.AppId
        }
    }

    throw "Unable to resolve the '$Name' application from an executable path or Start menu registration."
}

function Start-ConfiguredApplication {
    param([Parameter(Mandatory = $true)]$Resolution)

    if ($Resolution.method -eq 'executable') {
        Start-Process -FilePath $Resolution.target | Out-Null
        return
    }
    if ($Resolution.method -eq 'apps-folder') {
        $explorer = Join-Path $env:SystemRoot 'explorer.exe'
        Start-Process -FilePath $explorer -ArgumentList @("shell:AppsFolder\$($Resolution.target)") | Out-Null
        return
    }

    throw "Unsupported application launch method '$($Resolution.method)'."
}

function Write-ActionResult {
    param([string]$Name)

    [pscustomobject]@{
        ok = $true
        command = $Name
        arguments = @($ArgumentList)
        timestamp = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress
}

$normalizedCommand = $Command.ToLowerInvariant()

switch ($normalizedCommand) {
    'state' {
        (Invoke-KomorebicRaw -Arguments @('state')).Output
    }
    'global-state' {
        (Invoke-KomorebicRaw -Arguments @('global-state')).Output
    }
    'visible' {
        (Invoke-KomorebicRaw -Arguments @('visible-windows')).Output
    }
    'query' {
        Assert-ArgumentCount -Minimum 1 -Usage 'query <state-query>'
        (Invoke-KomorebicRaw -Arguments @('query', $ArgumentList[0])).Output
    }
    'focus' {
        Assert-ArgumentCount -Minimum 1 -Usage 'focus <left|right|up|down>'
        Invoke-KomorebicAction -Arguments @('focus', $ArgumentList[0])
        Write-ActionResult -Name $normalizedCommand
    }
    'move' {
        Assert-ArgumentCount -Minimum 1 -Usage 'move <left|right|up|down>'
        Invoke-KomorebicAction -Arguments @('move', $ArgumentList[0])
        Write-ActionResult -Name $normalizedCommand
    }
    'workspace' {
        Assert-ArgumentCount -Minimum 1 -Usage 'workspace <name>'
        Invoke-KomorebicAction -Arguments @('focus-named-workspace', $ArgumentList[0])
        Write-ActionResult -Name $normalizedCommand
    }
    'send' {
        Assert-ArgumentCount -Minimum 1 -Usage 'send <workspace-name>'
        Invoke-KomorebicAction -Arguments @('send-to-named-workspace', $ArgumentList[0])
        Write-ActionResult -Name $normalizedCommand
    }
    'move-and-follow' {
        Assert-ArgumentCount -Minimum 1 -Usage 'move-and-follow <workspace-name>'
        Invoke-KomorebicAction -Arguments @('move-to-named-workspace', $ArgumentList[0])
        Write-ActionResult -Name $normalizedCommand
    }
    'workspace-cycle' {
        Assert-ArgumentCount -Minimum 1 -Usage 'workspace-cycle <previous|next>'
        Invoke-KomorebicAction -Arguments @('cycle-workspace', $ArgumentList[0])
        Write-ActionResult -Name $normalizedCommand
    }
    'send-cycle' {
        Assert-ArgumentCount -Minimum 1 -Usage 'send-cycle <previous|next>'
        Invoke-KomorebicAction -Arguments @('cycle-move-to-workspace', $ArgumentList[0])
        Write-ActionResult -Name $normalizedCommand
    }
    'active-workspace' {
        Assert-ArgumentCount -Minimum 1 -Usage 'active-workspace <previous|next>'
        Invoke-ActiveWorkspaceCycle -Direction $ArgumentList[0]
        Write-ActionResult -Name $normalizedCommand
    }
    'last-workspace' {
        Invoke-KomorebicAction -Arguments @('focus-last-workspace')
        Write-ActionResult -Name $normalizedCommand
    }
    'launch' {
        Assert-ArgumentCount -Minimum 1 -Usage 'launch <terminal|firefox|explorer|obsidian|flow|cursor> [--resolve]'
        if (@($ArgumentList).Count -gt 2 -or
            (@($ArgumentList).Count -eq 2 -and $ArgumentList[1] -ne '--resolve')) {
            throw 'Usage: wm launch <terminal|firefox|explorer|obsidian|flow|cursor> [--resolve]'
        }

        $resolution = Resolve-ConfiguredApplication -Name $ArgumentList[0].ToLowerInvariant()
        if (@($ArgumentList).Count -eq 2) {
            $resolution | ConvertTo-Json -Compress
        } else {
            Start-ConfiguredApplication -Resolution $resolution
            [pscustomobject]@{
                ok = $true
                command = 'launch'
                application = $resolution.name
                method = $resolution.method
                target = $resolution.target
                timestamp = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress
        }
    }
    'move-workspace' {
        Assert-ArgumentCount -Minimum 1 -Usage 'move-workspace <left|right|up|down>'
        $direction = $ArgumentList[0].ToLowerInvariant()
        if ($direction -notin @('left', 'right', 'up', 'down')) {
            throw "Invalid monitor direction '$direction'."
        }
        $state = Get-KomorebiState
        $monitorsElements = if ($null -ne $state.monitors.PSObject.Properties['elements']) {
            $state.monitors.elements
        } else {
            $state.monitors
        }
        $monitorCount = @($monitorsElements).Count
        if ($monitorCount -lt 2) {
            [pscustomobject]@{
                ok = $true
                command = 'move-workspace'
                noOp = $true
                reason = 'single-monitor'
                requestedDirection = $direction
                timestamp = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress
        } else {
            $cycleDirection = if ($direction -in @('left', 'up')) { 'previous' } else { 'next' }
            Invoke-KomorebicAction -Arguments @('cycle-move-workspace-to-monitor', $cycleDirection)
            Write-ActionResult -Name $normalizedCommand
        }
    }
    'resize' {
        Assert-ArgumentCount -Minimum 2 -Usage 'resize <width|height> <signed-percent>'
        $percentage = 0.0
        if (-not [double]::TryParse($ArgumentList[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$percentage)) {
            throw "Invalid percentage '$($ArgumentList[1])'."
        }
        Invoke-PercentageResize -Axis $ArgumentList[0] -Percentage $percentage
        Write-ActionResult -Name $normalizedCommand
    }
    'resize-mode' {
        Start-DetachedScript -Path (Join-Path $PSScriptRoot 'wm-resize-mode.ps1')
        Write-ActionResult -Name $normalizedCommand
    }
    'layout' {
        Assert-ArgumentCount -Minimum 1 -Usage 'layout <fair|fair-horizontal|columns|rows|previous|next>'
        Invoke-LayoutCommand -Target $ArgumentList[0]
        Write-ActionResult -Name $normalizedCommand
    }
    'tiling-direction' {
        New-Item -ItemType Directory -Path $script:RuntimeRoot -Force | Out-Null
        $statePath = Join-Path $script:RuntimeRoot 'preselect-direction.txt'
        $current = if (Test-Path -LiteralPath $statePath) { (Get-Content -LiteralPath $statePath -Raw).Trim() } else { 'down' }
        $next = if ($current -eq 'right') { 'down' } else { 'right' }
        Set-Content -LiteralPath $statePath -Value $next -Encoding ascii
        Invoke-KomorebicAction -Arguments @('preselect-direction', $next)
        Write-ActionResult -Name $normalizedCommand
    }
    'cycle-layer' {
        Invoke-KomorebicAction -Arguments @('toggle-workspace-layer')
        Write-ActionResult -Name $normalizedCommand
    }
    'float' {
        Invoke-KomorebicAction -Arguments @('toggle-float')
        Write-ActionResult -Name $normalizedCommand
    }
    'monocle' {
        Invoke-KomorebicAction -Arguments @('toggle-monocle')
        Write-ActionResult -Name $normalizedCommand
    }
    'fullscreen' {
        Invoke-KomorebicAction -Arguments @('toggle-maximize')
        Write-ActionResult -Name $normalizedCommand
    }
    'maximize' {
        Invoke-KomorebicAction -Arguments @('toggle-maximize')
        Write-ActionResult -Name $normalizedCommand
    }
    'minimize' {
        Invoke-KomorebicAction -Arguments @('minimize')
        Write-ActionResult -Name $normalizedCommand
    }
    'close' {
        Invoke-KomorebicAction -Arguments @('close')
        Write-ActionResult -Name $normalizedCommand
    }
    'manage' {
        Invoke-KomorebicAction -Arguments @('manage')
        Write-ActionResult -Name $normalizedCommand
    }
    'unmanage' {
        Invoke-KomorebicAction -Arguments @('unmanage')
        Write-ActionResult -Name $normalizedCommand
    }
    { $_ -in @('pause', 'pause-hook') } {
        Invoke-KomorebicAction -Arguments @('toggle-pause')
        Write-ActionResult -Name $normalizedCommand
    }
    'retile' {
        Invoke-KomorebicAction -Arguments @('retile')
        Write-ActionResult -Name $normalizedCommand
    }
    'restore' {
        Invoke-KomorebicAction -Arguments @('restore-windows')
        Write-ActionResult -Name $normalizedCommand
    }
    'reload' {
        if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
            throw "Komorebi configuration not found: $script:ConfigPath"
        }
        Invoke-KomorebicAction -Arguments @('replace-configuration', $script:ConfigPath)
        Start-DetachedScript -Path $script:StartScript -Arguments @('-Restart', '-DelayMilliseconds', '300')
        Write-ActionResult -Name $normalizedCommand
    }
    'restart' {
        Start-DetachedScript -Path $script:StartScript -Arguments @('-Restart', '-DelayMilliseconds', '300')
        Write-ActionResult -Name $normalizedCommand
    }
    'start' {
        Start-DetachedScript -Path $script:StartScript
        Write-ActionResult -Name $normalizedCommand
    }
    'stop' {
        Start-DetachedScript -Path $script:StartScript -Arguments @('-StopOnly', '-DelayMilliseconds', '300')
        Write-ActionResult -Name $normalizedCommand
    }
    'status' {
        $processes = Get-Process -Name komorebi, komorebi-bar, whkd, masir, glazewm, zebar -ErrorAction SilentlyContinue |
            Select-Object ProcessName, Id, StartTime
        [pscustomobject]@{
            configHome = $script:ConfigHome
            config = $script:ConfigPath
            processes = @($processes)
        } | ConvertTo-Json -Depth 5
    }
    'help' {
        @'
wm state
wm global-state
wm visible
wm query <state-query>
wm focus <left|right|up|down>
wm move <left|right|up|down>
wm workspace <name>
wm send <name>
wm move-and-follow <name>
wm active-workspace <previous|next>
wm move-workspace <left|right|up|down>
wm launch <terminal|firefox|explorer|obsidian|flow|cursor> [--resolve]
wm resize <width|height> <signed-percent>
wm layout <fair|fair-horizontal|columns|rows|previous|next>
wm float | fullscreen | monocle | manage | unmanage | pause | reload | restore
wm start | stop | restart | status
'@
    }
    default {
        throw "Unknown command '$Command'. Run 'wm help'."
    }
}
