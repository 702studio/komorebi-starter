[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-ReparsePoint {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    return [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Assert-RegularPathAncestors {
    param([string]$PathName, [string]$Path)

    $cursor = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($cursor)) {
        if ((Test-Path -LiteralPath $cursor) -and (Test-ReparsePoint $cursor)) {
            throw "$PathName contains a reparse-point ancestor: $cursor"
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) {
            break
        }
        $cursor = $parent
    }
}

$repoRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$outputDir = [IO.Path]::GetFullPath($OutputRoot)
$repoPrefix = $repoRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar

if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
    throw "Repository root does not exist: $repoRoot"
}
if ($outputDir -eq $repoRoot -or $outputDir.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Output root cannot equal or be nested below the repository root.'
}

Assert-RegularPathAncestors -PathName 'Repository root' -Path $repoRoot
Assert-RegularPathAncestors -PathName 'Output root' -Path $outputDir

$innoSource = Join-Path $repoRoot 'installer\KomorebiStarter.iss'
if (-not (Test-Path -LiteralPath $innoSource -PathType Leaf)) {
    throw "Inno Setup source not found: $innoSource"
}

$isccCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
)
$iscc = $isccCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($iscc)) {
    throw 'ISCC.exe was not found. Install JRSoftware.InnoSetup 6.7.3 first.'
}
$expectedCompilerSha256 = '0a8757031b33777e4c9cbffee40f11a5062b36d25cbe144c1db73b6102b80ad7'
$compilerSha256 = (Get-FileHash -LiteralPath $iscc -Algorithm SHA256).Hash
if ($compilerSha256 -ine $expectedCompilerSha256) {
    throw 'ISCC.exe does not match the compiler shipped by the pinned Inno Setup 6.7.3 installer.'
}

if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $outputDir -PathType Container) -or (Test-ReparsePoint $outputDir)) {
    throw "Output root is not a regular directory: $outputDir"
}

$installerPath = Join-Path $outputDir 'komorebi-starter-setup.exe'
$checksumPath = Join-Path $outputDir 'komorebi-starter-setup.exe.sha256'
foreach ($path in @($installerPath, $checksumPath)) {
    if (Test-Path -LiteralPath $path) {
        if ((Test-ReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Output path is not a regular file: $path"
        }
        Remove-Item -LiteralPath $path -Force
    }
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $compilerOutput = @(& $iscc '/Qp' "/DAppVersion=$Version" "/DSourceRoot=$repoRoot" "/DOutputRoot=$outputDir" $innoSource 2>&1)
    $compilerExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($compilerExitCode -ne 0) {
    throw "Inno Setup compilation failed:`n$($compilerOutput -join [Environment]::NewLine)"
}
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf) -or (Test-ReparsePoint $installerPath)) {
    throw "Installer was not created as a regular file: $installerPath"
}

$installer = Get-Item -LiteralPath $installerPath -Force
if ($installer.Length -le 0 -or $installer.Length -gt (50 * 1024 * 1024)) {
    throw "Installer size is outside the allowed range: $($installer.Length) bytes"
}

$stream = [IO.File]::OpenRead($installerPath)
try {
    if ($stream.ReadByte() -ne 0x4D -or $stream.ReadByte() -ne 0x5A) {
        throw 'Installer does not have a Windows PE MZ header.'
    }
} finally {
    $stream.Dispose()
}

$hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksum = "$hash *komorebi-starter-setup.exe"
[IO.File]::WriteAllText($checksumPath, $checksum, [Text.Encoding]::ASCII)

return $hash
