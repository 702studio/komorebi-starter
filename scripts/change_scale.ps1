[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('up', 'down', 'status')]
    [string]$Direction
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pinnedHash = '31F9A42027C8F936C114E4C200F05B0677AFFA93AB035801C0C2AB02FBF7DBA1'
$setDpiPath = Join-Path $PSScriptRoot 'SetDpi.exe'
$licensePath = Join-Path $PSScriptRoot 'SetDpi.license.txt'

function Ensure-SetDpi {
    if (Test-Path -LiteralPath $setDpiPath -PathType Leaf) {
        return $true
    }

    try {
        $url = 'https://github.com/imniko/SetDPI/releases/download/v1.0/SetDpi.exe'
        $tempFile = Join-Path $env:TEMP ("SetDpi-{0}.exe" -f [Guid]::NewGuid().ToString('N'))

        # Ensure TLS 1.2 is enabled
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $tempFile -UseBasicParsing -TimeoutSec 30

        $hash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash
        if ($hash -ne $pinnedHash) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            throw "SHA-256 checksum verification failed. Expected: $pinnedHash, actual: $hash"
        }

        # Write Unlicense notice
        $unlicenseText = @"
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or
distribute this software, either in source code form or as a compiled
binary, for any purpose, commercial or non-commercial, and by any
means.

In jurisdictions that recognize copyright laws, the author or authors
of this software dedicate any and all copyright interest in the
software to the public domain. We make this dedication for the benefit
of the public at large and to the detriment of our heirs and
successors. We intend this dedication to be an overt act of
relinquishment in perpetuity of all present and future rights to this
software under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

For more information, please refer to <http://unlicense.org/>
"@
        [IO.File]::WriteAllText($licensePath, $unlicenseText, [Text.Encoding]::ASCII)

        # Deploy SetDpi.exe
        New-Item -ItemType Directory -Path (Split-Path -Parent $setDpiPath) -Force | Out-Null
        Move-Item -LiteralPath $tempFile -Destination $setDpiPath -Force
        return $true
    } catch {
        return $false
    }
}

$available = Ensure-SetDpi

if (-not $available) {
    if ($Direction -eq 'status') {
        [pscustomobject]@{
            ok = $false
            error = 'SetDpi.exe is missing and could not be downloaded/verified'
        } | ConvertTo-Json -Compress
        return
    } else {
        throw 'Display scaling utility (SetDpi.exe) is missing and download/verification failed. Scaling shortcuts are disabled.'
    }
}

$output = & $setDpiPath get
if ($output -match "(\d+)") {
    $current = [int]$Matches[1]
} else {
    throw "SetDpi.exe returned an unreadable scale value: $output"
}

if ($Direction -eq 'status') {
    [pscustomobject]@{
        ok = $true
        scale = $current
        executable = $setDpiPath
    } | ConvertTo-Json -Compress
    return
}

$scales = @(100, 125, 150, 175, 200)
$index = $scales.IndexOf($current)

if ($index -lt 0) {
    $closestIndex = 0
    $minDiff = [int]::MaxValue
    for ($i = 0; $i -lt $scales.Count; $i++) {
        $diff = [Math]::Abs($scales[$i] - $current)
        if ($diff -lt $minDiff) {
            $minDiff = $diff
            $closestIndex = $i
        }
    }
    $index = $closestIndex
}

if ($Direction -eq 'up') {
    if ($index -lt ($scales.Count - 1)) {
        $newScale = $scales[$index + 1]
    } else {
        $newScale = $scales[$index]
    }
} elseif ($Direction -eq 'down') {
    if ($index -gt 0) {
        $newScale = $scales[$index - 1]
    } else {
        $newScale = $scales[$index]
    }
}

if ($null -eq $newScale) {
    throw "Could not calculate a target scale for direction '$Direction'."
}

$setOutput = & $setDpiPath $newScale
$verifyOutput = & $setDpiPath get
if ($verifyOutput -notmatch '(\d+)') {
    throw "Could not verify the display scale after SetDpi.exe returned: $setOutput"
}

[pscustomobject]@{
    ok = $true
    direction = $Direction
    previous = $current
    requested = $newScale
    current = [int]$Matches[1]
} | ConvertTo-Json -Compress
