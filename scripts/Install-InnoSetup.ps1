[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredVersion = '6.7.3'
$installerUri = 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe'
$expectedSha256 = '9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732'
$expectedCompilerSha256 = '0a8757031b33777e4c9cbffee40f11a5062b36d25cbe144c1db73b6102b80ad7'
$candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
)

foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $compilerSha256 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
        if ($compilerSha256 -ieq $expectedCompilerSha256) {
            return $candidate
        }
    }
}

$tempRoot = Join-Path $env:TEMP ("komorebi-starter-inno-{0}" -f [Guid]::NewGuid().ToString('N'))
$installerPath = Join-Path $tempRoot 'innosetup.exe'

try {
    New-Item -ItemType Directory -Path $tempRoot -ErrorAction Stop | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $installerUri -OutFile $installerPath -UseBasicParsing

    $installer = Get-Item -LiteralPath $installerPath -Force
    if ($installer.Length -le 0 -or $installer.Length -gt (16 * 1024 * 1024)) {
        throw "Inno Setup installer size is outside the allowed range: $($installer.Length) bytes"
    }
    $actualSha256 = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
    if ($actualSha256 -ine $expectedSha256) {
        throw "Inno Setup SHA-256 mismatch. Expected $expectedSha256, actual $actualSha256"
    }

    $process = Start-Process -FilePath $installerPath -ArgumentList @(
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/CURRENTUSER'
    ) -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Inno Setup installation failed with exit code $($process.ExitCode)."
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        $canonicalTempRoot = [IO.Path]::GetFullPath($tempRoot)
        $canonicalTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if ($canonicalTempRoot.StartsWith($canonicalTemp, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $canonicalTempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $compilerSha256 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
        if ($compilerSha256 -ieq $expectedCompilerSha256) {
            return $candidate
        }
    }
}
throw "The compiler from Inno Setup $requiredVersion was not found after installation."
