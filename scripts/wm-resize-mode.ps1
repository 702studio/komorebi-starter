[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$createdNew = $false
$mutex = [Threading.Mutex]::new($true, 'Local\KomorebiStarter.ResizeMode', [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    return
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class KomorebiResizeHotkeys
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Point
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Message
    {
        public IntPtr HWnd;
        public uint Msg;
        public UIntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public Point Pt;
        public uint Private;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern bool PeekMessage(out Message message, IntPtr hWnd, uint min, uint max, uint remove);
}
'@

$wm = Join-Path $PSScriptRoot 'wm.ps1'
$modifierNoRepeat = 0x4000
$wmHotkeyMessage = 0x0312
$removeMessage = 0x0001

$bindings = [ordered]@{
    1 = @{ Key = 0x48; Axis = 'width'; Percent = -2 } # H
    2 = @{ Key = 0x25; Axis = 'width'; Percent = -2 } # Left
    3 = @{ Key = 0x4C; Axis = 'width'; Percent = 2 }  # L
    4 = @{ Key = 0x27; Axis = 'width'; Percent = 2 }  # Right
    5 = @{ Key = 0x4B; Axis = 'height'; Percent = 2 } # K
    6 = @{ Key = 0x26; Axis = 'height'; Percent = 2 } # Up
    7 = @{ Key = 0x4A; Axis = 'height'; Percent = -2 } # J
    8 = @{ Key = 0x28; Axis = 'height'; Percent = -2 } # Down
    9 = @{ Key = 0x1B; Exit = $true }                 # Escape
    10 = @{ Key = 0x0D; Exit = $true }                # Enter
}

$registered = @()
try {
    foreach ($entry in $bindings.GetEnumerator()) {
        $id = [int]$entry.Key
        $virtualKey = [uint32]$entry.Value.Key
        if (-not [KomorebiResizeHotkeys]::RegisterHotKey([IntPtr]::Zero, $id, $modifierNoRepeat, $virtualKey)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Unable to register resize-mode hotkey id $id (Win32 error $errorCode)."
        }
        $registered += $id
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $running = $true
    $message = [KomorebiResizeHotkeys+Message]::new()

    while ($running -and [DateTime]::UtcNow -lt $deadline) {
        while ([KomorebiResizeHotkeys]::PeekMessage([ref]$message, [IntPtr]::Zero, 0, 0, $removeMessage)) {
            if ($message.Msg -ne $wmHotkeyMessage) {
                continue
            }

            $id = [int]$message.WParam.ToUInt32()
            $binding = $bindings[$id]
            if ($binding.Exit) {
                $running = $false
                break
            }

            & $wm resize $binding.Axis ([string]$binding.Percent) | Out-Null
        }

        Start-Sleep -Milliseconds 10
    }
} finally {
    foreach ($id in $registered) {
        $null = [KomorebiResizeHotkeys]::UnregisterHotKey([IntPtr]::Zero, $id)
    }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
