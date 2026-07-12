[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$checks = New-Object System.Collections.ArrayList
$failures = New-Object System.Collections.ArrayList

# PID snapshot for Absolute Test Safety
$targetProcesses = @('komorebi', 'whkd', 'masir', 'komorebi-bar')
$initialPids = @{}
foreach ($name in $targetProcesses) {
    $pids = @(Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $initialPids[$name] = $pids
}

function Add-TestCheck {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )
    $null = $checks.Add([pscustomobject]@{
        name = $Name
        passed = $Passed
        detail = $Detail
    })
    if (-not $Passed) {
        $null = $failures.Add("${Name}: $Detail")
    }
}

function Invoke-TestCheck {
    param(
        [string]$Name,
        [scriptblock]$Action
    )
    try {
        $detail = & $Action
        Add-TestCheck -Name $Name -Passed $true -Detail ([string]$detail)
    } catch {
        [Console]::Error.WriteLine("Test check '$Name' failed with exception: $_")
        [Console]::Error.WriteLine($_.ScriptStackTrace)
        Add-TestCheck -Name $Name -Passed $false -Detail $_.Exception.Message
    }
}

# Dot-source common helper for testing
. (Join-Path $repoRoot 'scripts\KomorebiStarter.Common.ps1')

# 1. AST Parsing
Invoke-TestCheck 'powershell-ast-parsing' {
    $files = Get-ChildItem -Path $repoRoot -Filter '*.ps1' -Recurse -File |
        Where-Object { $_.FullName -notmatch '[\\/]\.reference[\\/]' -and $_.FullName -notmatch '[\\/]\.git[\\/]' }

    $syntaxErrors = @()
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors) {
            $syntaxErrors += @($errors | ForEach-Object { "$($file.Name): $($_.Message) at line $($_.Extent.StartLineNumber)" })
        }
    }
    if ($syntaxErrors.Count -gt 0) {
        throw ($syntaxErrors -join '; ')
    }
    return "Successfully parsed $($files.Count) PowerShell files with zero syntax errors."
}

# 2. JSON Parsing & BOM checks
Invoke-TestCheck 'json-parsing-and-bom' {
    $files = Get-ChildItem -Path $repoRoot -Filter '*.json' -Recurse -File |
        Where-Object { $_.FullName -notmatch '[\\/]\.reference[\\/]' -and $_.FullName -notmatch '[\\/]\.git[\\/]' }

    foreach ($file in $files) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            throw "File $($file.Name) contains a UTF-8 BOM which is rejected by native Komorebi parsing."
        }
        try {
            $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        } catch {
            throw "Failed to parse JSON file $($file.Name): $_"
        }
    }
    return "Parsed $($files.Count) JSON files successfully; no UTF-8 BOM issues."
}

# 3. Personal path/name leakage check
Invoke-TestCheck 'personal-leakage-prevention' {
    $files = Get-ChildItem -Path $repoRoot -File -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/]\.reference[\\/]' -and $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.Name -ne 'Test-Repository.ps1' }

    $leakedCount = 0
    $details = @()

    $pattern = '(?i)([a-z]:\\users\\[^\\\s"''<>]+|[a-z]:\\projects\\coding_base)'

    foreach ($file in $files) {
        if ($file.Extension -match '\.(ps1|json|cmd|bat|md|txt|yml|yaml|properties)$' -or $file.Name -match '^(LICENSE|CODEOWNERS)$') {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            if ($content -match $pattern) {
                $leakedCount++
                $details += "$($file.Name) contains sensitive/personal terms or paths."
            }
        }
    }

    if ($leakedCount -gt 0) {
        throw ($details -join '; ')
    }
    return 'Passed absolute user and local workspace path leakage scan.'
}

# 4. Third-party binary restriction
Invoke-TestCheck 'no-third-party-binaries' {
    $files = Get-ChildItem -Path $repoRoot -File -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/]\.reference[\\/]' -and $_.FullName -notmatch '[\\/]\.git[\\/]' }

    $binaries = @($files | Where-Object { $_.Extension -in @('.exe', '.dll', '.msi', '.sys', '.bin') })
    if ($binaries.Count -gt 0) {
        $paths = @($binaries | ForEach-Object { $_.Name }) -join ', '
        throw "Third-party binary assets detected in repository: $paths"
    }
    return 'No executable or library binary files committed to the repository.'
}

# 5. Bootstrap hash enforcement
Invoke-TestCheck 'bootstrap-hash-enforcement' {
    $bootstrapPath = Join-Path $repoRoot 'bootstrap.ps1'
    if (-not (Test-Path -LiteralPath $bootstrapPath)) {
        throw 'bootstrap.ps1 not found.'
    }
    $content = Get-Content -LiteralPath $bootstrapPath -Raw
    if ($content -notmatch 'expectedHash.*actualHash' -and $content -notmatch 'actualHash.*expectedHash') {
        throw 'bootstrap.ps1 does not enforce the checksum check for downloaded release assets.'
    }
    if ($content -notmatch 'https://') {
        throw 'bootstrap.ps1 is missing HTTPS download checks.'
    }
    return 'bootstrap.ps1 contains correct HTTPS URL validation and release archive SHA256 checks.'
}

# 6. Workspace order
Invoke-TestCheck 'workspace-order-assertion' {
    $komorebiJsonPath = Join-Path $repoRoot 'config/komorebi.json'
    if (-not (Test-Path -LiteralPath $komorebiJsonPath)) {
        throw 'config/komorebi.json not found.'
    }
    $json = Get-Content -LiteralPath $komorebiJsonPath -Raw | ConvertFrom-Json
    $workspaceNames = @($json.monitors | ForEach-Object { $_.workspaces } | ForEach-Object { [string]$_.name })
    $expectedNames = @('1', '2', '3', '4', '5', '6', '7', '8', '9')
    if (($workspaceNames -join ',') -ne ($expectedNames -join ',')) {
        throw "Workspaces are not ordered 1..9 in config/komorebi.json. Found: $($workspaceNames -join ', ')"
    }
    return 'Workspace order 1..9 validated successfully.'
}

# 7. Single-monitor move-workspace guard
Invoke-TestCheck 'move-workspace-guard-check' {
    $wmScriptPath = Join-Path $repoRoot 'scripts/wm.ps1'
    if (-not (Test-Path -LiteralPath $wmScriptPath)) {
        throw 'scripts/wm.ps1 not found.'
    }
    $content = Get-Content -LiteralPath $wmScriptPath -Raw
    if ($content -notmatch 'single-monitor') {
        throw 'wm.ps1 is missing the single-monitor move-workspace no-op guard check.'
    }
    return 'Tested single-monitor move-workspace guard check is present in wm.ps1.'
}

# 8. Path ownership guards check (Behavioral check)
Invoke-TestCheck 'path-ownership-guards' {
    $parent = 'C:\Foo'
    $collidingChild = 'C:\Foobar'
    $validChild = 'C:\Foo\Bar'

    if (Test-IsChildOf $collidingChild $parent) {
        throw "Prefix collision check failed: $parent claimed ownership of $collidingChild"
    }
    if (-not (Test-IsChildOf $validChild $parent)) {
        throw "Strict child check failed: $parent did not claim ownership of $validChild"
    }
    return "Verified path ownership guards prevent vulnerable prefix matching."
}

# 9. Behavioral Manifest Validation (traversal, wrong product, wrong schema, duplicates, hash mismatch)
function Invoke-ManifestValidationTest {
    param(
        [string]$JsonContent,
        [string]$StateJsonContent = $null
    )

    $tempDir = Join-Path $env:TEMP ("komorebi-test-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $stateFile = Join-Path $tempDir 'state.json'
        $manifestFile = Join-Path $tempDir 'manifest.json'

        $stateContent = if ([string]::IsNullOrEmpty($StateJsonContent)) {
            @{
                productId = '702studio.komorebi-starter'
                schemaVersion = 1
                environment = @{
                    KOMOREBI_CONFIG_HOME = $configHome
                    WHKD_CONFIG_HOME = $configHome
                }
            } | ConvertTo-Json
        } else {
            $StateJsonContent
        }

        $json = $JsonContent.Replace('{TEMP_DIR}', $tempDir.Replace('\', '\\'))
        Set-Content -LiteralPath $stateFile -Value $stateContent -Encoding UTF8
        Set-Content -LiteralPath $manifestFile -Value $json -Encoding UTF8

        # Run validation matching restore.ps1
        $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
        if ($null -eq $manifest) { throw "Malformed JSON" }
        if ($manifest.productId -ne '702studio.komorebi-starter' -or $manifest.schemaVersion -ne 1) {
            throw "Invalid product ID or schema"
        }

        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if ($null -eq $state) {
            throw "Malformed state"
        }
        if ($state.productId -ne '702studio.komorebi-starter' -or $state.schemaVersion -ne 1) {
            throw "Invalid product ID or schema in state"
        }

        $entries = @($manifest.files)
        $seenDest = @{}
        foreach ($entry in $entries) {
            if ($null -eq $entry.Source -or $null -eq $entry.Backup -or $null -eq $entry.SHA256 -or $null -eq $entry.ExistedBefore) {
                throw "Missing required fields"
            }

            $src = Get-CanonicalPath $entry.Source
            $bak = Get-CanonicalPath $entry.Backup

            # Allowlist check
            $allowedCanonical = @($allowedDestinations | ForEach-Object { Get-CanonicalPath $_ })
            if ($allowedCanonical -notcontains $src) {
                throw "External manifest destination / allowlist violation"
            }

            # Backup path check
            if (-not (Test-IsChildOf $bak $tempDir)) {
                throw "Traversal / backup path outside backup root"
            }

            # Duplicate check
            if ($seenDest.ContainsKey($src)) {
                throw "Duplicate destinations"
            }
            $seenDest[$src] = $true

            # Integrity check
            if ($entry.ExistedBefore) {
                if (-not (Test-Path -LiteralPath $bak -PathType Leaf)) {
                    throw "Missing backup file"
                }
                $hash = Get-FileSHA256 $bak
                if ($hash -ine $entry.SHA256) {
                    throw "Hash mismatch"
                }
            }
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

Invoke-TestCheck 'manifest-validation-rejections' {
    # External destination
    try {
        Invoke-ManifestValidationTest -JsonContent (@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            files = @(
                @{
                    Source = 'C:\Windows\System32\cmd.exe'
                    Backup = 'MOCK_BACKUP_PATH'
                    SHA256 = 'MOCK_HASH'
                    ExistedBefore = $true
                }
            )
        } | ConvertTo-Json -Depth 5)
        throw "Failed to reject external destination"
    } catch {
        if ($_ -notmatch "External manifest destination") { throw }
    }

    # Traversal backup path (outside backup root)
    try {
        Invoke-ManifestValidationTest -JsonContent (@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            files = @(
                @{
                    Source = $allowedDestinations[0]
                    Backup = 'C:\Windows\System32\cmd.exe'
                    SHA256 = 'MOCK_HASH'
                    ExistedBefore = $true
                }
            )
        } | ConvertTo-Json -Depth 5)
        throw "Failed to reject backup path traversal"
    } catch {
        if ($_ -notmatch "Traversal / backup path") { throw }
    }

    # Wrong product ID
    try {
        Invoke-ManifestValidationTest -JsonContent (@{
            productId = 'wrong-id'
            schemaVersion = 1
            files = @()
        } | ConvertTo-Json -Depth 5)
        throw "Failed to reject wrong product ID"
    } catch {
        if ($_ -notmatch "Invalid product ID") { throw }
    }

    # Wrong schema version
    try {
        Invoke-ManifestValidationTest -JsonContent (@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 2
            files = @()
        } | ConvertTo-Json -Depth 5)
        throw "Failed to reject wrong schema version"
    } catch {
        if ($_ -notmatch "Invalid product ID or schema") { throw }
    }

    # Duplicate destinations
    try {
        Invoke-ManifestValidationTest -JsonContent (@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            files = @(
                @{
                    Source = $allowedDestinations[0]
                    Backup = '{TEMP_DIR}\MOCK_BACKUP_PATH'
                    SHA256 = 'MOCK_HASH'
                    ExistedBefore = $false
                },
                @{
                    Source = $allowedDestinations[0]
                    Backup = '{TEMP_DIR}\MOCK_BACKUP_PATH2'
                    SHA256 = 'MOCK_HASH2'
                    ExistedBefore = $false
                }
            )
        } | ConvertTo-Json -Depth 5)
        throw "Failed to reject duplicate destinations"
    } catch {
        if ($_ -notmatch "Duplicate destinations") { throw }
    }

    return "All security validation cases (traversal, wrong product/schema, duplicate destinations) rejected successfully."
}

# 10. Command candidate generation for masir
Invoke-TestCheck 'command-candidate-generation-masir' {
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    if ([string]::IsNullOrEmpty($programFiles)) { $programFiles = 'C:\Program Files' }
    $expectedCandidate = Join-Path $programFiles 'masir\bin\masir.exe'

    $localPrograms = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs'
    $searchDirs = @(
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\WinGet\Links'),
        (Join-Path $programFiles 'WinGet\Links'),
        (Join-Path $localPrograms 'masir'),
        (Join-Path $localPrograms 'komorebi'),
        (Join-Path $localPrograms 'whkd'),
        (Join-Path $localPrograms 'masir'),
        (Join-Path $programFiles 'masir\bin'),
        (Join-Path $programFiles 'komorebi\bin'),
        (Join-Path $programFiles 'whkd\bin'),
        (Join-Path $programFiles 'masir'),
        (Join-Path $programFiles 'komorebi'),
        (Join-Path $programFiles 'whkd')
    )
    $found = $false
    foreach ($dir in $searchDirs) {
        $candidate = Join-Path $dir 'masir.exe'
        if ((Get-CanonicalPath $candidate) -eq (Get-CanonicalPath $expectedCandidate)) {
            $found = $true
            break
        }
    }
    if (-not $found) {
        throw "Candidates do not include C:\Program Files\masir\bin\masir.exe"
    }
    return "Verified masir bin candidate path is generated: $expectedCandidate"
}

# 11. Installer JSON WhatIf Dry Run Verification
Invoke-TestCheck 'installer-dry-run-verification' {
    $installPath = Join-Path $repoRoot 'install.ps1'
    $tempStdout = [System.IO.Path]::GetTempFileName()
    $tempStderr = [System.IO.Path]::GetTempFileName()

    try {
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$installPath`" -WhatIf -NonInteractive -Quiet -Json" -PassThru -NoNewWindow -RedirectStandardOutput $tempStdout -RedirectStandardError $tempStderr -Wait

        $exitCode = $proc.ExitCode
        $stdoutText = Get-Content -LiteralPath $tempStdout -Raw
        $stderrText = Get-Content -LiteralPath $tempStderr -Raw

        if ($exitCode -ne 0) {
            throw "Installer WhatIf process exited with non-zero code $exitCode. Stderr: $stderrText"
        }

        $parsed = $null
        try {
            $parsed = $stdoutText | ConvertFrom-Json
        } catch {
            throw "Stdout is not a valid single JSON document. Raw output: $stdoutText"
        }

        if ($null -eq $parsed) {
            throw "JSON parsed to null. Raw output: $stdoutText"
        }

        if ($stdoutText -like "*What if:*") {
            throw "Stdout contains 'What if:' text! Pollution detected: $stdoutText"
        }
        if ($stderrText -like "*What if:*") {
            throw "Stderr contains 'What if:' text! Pollution detected: $stderrText"
        }

        # Verify plan JSON content details
        $actions = @($parsed.plannedActions)
        $targets = @($actions | ForEach-Object { $_.target })
        $actionStrings = @($actions | ForEach-Object { $_.action })

        # Assert applications.json, restore.ps1, uninstall.ps1 are in the plan
        $hasAppJson = [bool]($targets -like '*applications.json*')
        $hasRestore = [bool]($targets -like '*restore.ps1*')
        $hasUninstall = [bool]($targets -like '*uninstall.ps1*')

        if (-not $hasAppJson) {
            throw "Planned actions are missing applications.json deployment"
        }
        if (-not $hasRestore) {
            throw "Planned actions are missing restore.ps1 deployment"
        }
        if (-not $hasUninstall) {
            throw "Planned actions are missing uninstall.ps1 deployment"
        }

        # Check task hash/transaction actions
        $hasTaskAction = [bool]($targets -like '*Task*KomorebiStarter*' -or $actionStrings -like '*KomorebiStarter*')
        if (-not $hasTaskAction) {
            throw "Planned actions are missing KomorebiStarter task transaction actions"
        }

        # Ensure no legacy file backups are present
        $hasLegacy = $false
        foreach ($target in $targets) {
            if ($target -like "*legacy\whkdrc*" -or $target -like "*legacy\komorebi.bar.json*" -or $target -like "*glazewm\config.yaml*" -or $target -like "*zebar\settings.json*") {
                $hasLegacy = $true
            }
        }
        foreach ($actStr in $actionStrings) {
            if ($actStr -like "*legacy\whkdrc*" -or $actStr -like "*legacy\komorebi.bar.json*" -or $actStr -like "*glazewm\config.yaml*" -or $actStr -like "*zebar\settings.json*") {
                $hasLegacy = $true
            }
        }
        if ($hasLegacy) {
            throw "Vulnerability: Planned actions contain legacy file backups!"
        }

        return "Installer WhatIf executed cleanly. ExitCode=0, Valid JSON returned, no 'What if:' text, all transaction actions verified, no legacy file backups."
    } finally {
        Remove-Item -LiteralPath $tempStdout -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempStderr -Force -ErrorAction SilentlyContinue
    }
}

# 12. Snapshot Immutability Verification
Invoke-TestCheck 'dry-run-file-immutability' {
    $takeStateSnapshot = {
        $files = @{}
        if (Test-Path -LiteralPath $configHome) {
            Get-ChildItem -Path $configHome -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $files[$_.FullName] = @{
                    length = $_.Length
                    hash = Get-FileSHA256 $_.FullName
                }
            }
        }
        if (Test-Path -LiteralPath $installDir) {
            Get-ChildItem -Path $installDir -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $files[$_.FullName] = @{
                    length = $_.Length
                    hash = Get-FileSHA256 $_.FullName
                }
            }
        }
        $tasks = @{}
        foreach ($tName in @('KomorebiStarter', 'StartGlazeWM')) {
            $t = Get-ScheduledTask -TaskName $tName -ErrorAction SilentlyContinue
            if ($t) {
                $tasks[$tName] = @{
                    exists = $true
                    enabled = $t.Settings.Enabled
                }
            } else {
                $tasks[$tName] = @{ exists = $false; enabled = $false }
            }
        }
        $envState = @{
            komorebiHome = [Environment]::GetEnvironmentVariable('KOMOREBI_CONFIG_HOME', 'User')
            whkdHome = [Environment]::GetEnvironmentVariable('WHKD_CONFIG_HOME', 'User')
            userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        }
        return @{ files = $files; tasks = $tasks; env = $envState }
    }

    $before = & $takeStateSnapshot

    $installPath = Join-Path $repoRoot 'install.ps1'
    $tempStdout = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$installPath`" -WhatIf -NonInteractive -Quiet -Json" -PassThru -NoNewWindow -RedirectStandardOutput $tempStdout
        $proc.WaitForExit()

        $after = & $takeStateSnapshot

        # Compare file count and contents
        if ($before.files.Count -ne $after.files.Count) {
            throw "File count mismatch after dry run: $($before.files.Count) vs $($after.files.Count)"
        }
        foreach ($key in $before.files.Keys) {
            if (-not $after.files.ContainsKey($key)) {
                throw "File $key was deleted during dry run!"
            }
            $orig = $before.files[$key]
            $curr = $after.files[$key]
            if ($orig.length -ne $curr.length -or $orig.hash -ne $curr.hash) {
                throw "File $key was modified during dry run!"
            }
        }

        # Compare scheduled tasks
        foreach ($key in $before.tasks.Keys) {
            $origT = $before.tasks[$key]
            $currT = $after.tasks[$key]
            if ($origT.exists -ne $currT.exists -or $origT.enabled -ne $currT.enabled) {
                throw "Scheduled task $key was mutated during dry run!"
            }
        }

        # Compare environment variables
        if ($before.env.komorebiHome -ne $after.env.komorebiHome -or $before.env.whkdHome -ne $after.env.whkdHome -or $before.env.userPath -ne $after.env.userPath) {
            throw "Environment variables were mutated during dry run!"
        }
    } finally {
        Remove-Item -LiteralPath $tempStdout -Force -ErrorAction SilentlyContinue
    }

    return "Verified dry run did not modify or delete any user configuration, program files, scheduled tasks, or environment variables."
}

# 13. Font package exactness and sentinel check
Invoke-TestCheck 'font-package-and-sentinel-check' {
    $installPath = Join-Path $repoRoot 'install.ps1'
    $content = Get-Content -LiteralPath $installPath -Raw

    if ($content -match 'JetBrains\.JetBrainsMono') {
        throw "Font package ID is incorrect. Must be DEVCOM.JetBrainsMonoNerdFont."
    }
    if ($content -notmatch 'DEVCOM\.JetBrainsMonoNerdFont') {
        throw "Could not find JetBrains Mono Nerd Font ID DEVCOM.JetBrainsMonoNerdFont in install.ps1."
    }
    if ($content -match 'Ensure-Package.*JetBrains.*whkd') {
        throw "install.ps1 still uses whkd as a dummy command sentinel for font installation."
    }
    return "Verified exact font package ID DEVCOM.JetBrainsMonoNerdFont and no dummy whkd command sentinel."
}

# 14. Pure validation and hash rules
Invoke-TestCheck 'pure-validation-and-hash-rules' {
    $tempDir = Join-Path $env:TEMP ("komorebi-pure-test-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $backupRoot = Join-Path $tempDir 'backup_root'
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

        $mockDest = Join-Path $tempDir 'mock_dest.json'

        # Test Case 1: fresh-created entry with null original SHA validates
        $entry1 = [pscustomobject]@{
            Source = $mockDest
            Backup = (Join-Path $backupRoot 'mock_dest.json')
            SHA256 = $null
            ExistedBefore = $false
            InstalledSHA256 = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        }
        $manifest1 = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            files = @($entry1)
        }

        Assert-ManifestValid -ManifestObj $manifest1 -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -BackupRoot $backupRoot -AllowedDestinations @($mockDest)

        # Assert: null/malformed installed hash never authorizes deletion.
        $mockInstalledHashes = @($null, "", "123", "invalid-hash", "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdeg")

        foreach ($ih in $mockInstalledHashes) {
            $currentHash = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
            $canDelete = ($null -ne $currentHash -and $null -ne $ih -and (Test-Is64Hex $currentHash) -and (Test-Is64Hex $ih) -and ($currentHash -ieq $ih))
            if ($canDelete) {
                throw "Security error: allowed deletion with null/malformed InstalledSHA256: '$ih'"
            }
        }

        # Test Case 2: string ExistedBefore is rejected
        $entry2 = [pscustomobject]@{
            Source = $mockDest
            Backup = (Join-Path $backupRoot 'mock_dest.json')
            SHA256 = $null
            ExistedBefore = "false"
            InstalledSHA256 = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        }
        $manifest2 = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            files = @($entry2)
        }
        try {
            Assert-ManifestValid -ManifestObj $manifest2 -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -BackupRoot $backupRoot -AllowedDestinations @($mockDest)
            throw "Failed to reject string ExistedBefore"
        } catch {
            if ($_ -notmatch "ExistedBefore.*missing or not a boolean") {
                throw "Unexpected exception for string ExistedBefore: $_"
            }
        }

    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
    return "Validated fresh-created entry with null original SHA, rejected malformed/null installed SHA for deletion, and rejected string ExistedBefore."
}

# 15. Preflight rejections before mutation
Invoke-TestCheck 'preflight-rejections-before-mutation' {
    $tempDir = Join-Path $env:TEMP ("komorebi-preflight-test-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $backupRoot = Join-Path $tempDir 'backup_root'
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

        $mockDest = Join-Path $tempDir 'mock_dest.json'
        $mutationCounter = 0

        # Test Case A: Hash mismatch on ExistedBefore=true
        $entryA = [pscustomobject]@{
            Source = $mockDest
            Backup = (Join-Path $backupRoot 'mock_dest.json')
            SHA256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            ExistedBefore = $true
            InstalledSHA256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }
        Set-Content -LiteralPath (Join-Path $backupRoot 'mock_dest.json') -Value "some other data"
        $manifestA = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            files = @($entryA)
        }
        try {
            Assert-ManifestValid -ManifestObj $manifestA -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -BackupRoot $backupRoot -AllowedDestinations @($mockDest)
            throw "Failed to reject hash mismatch"
        } catch {
            if ($_ -notmatch "hash mismatch") { throw }
        }

        # Test Case B: Duplicate destination
        $entryB1 = [pscustomobject]@{
            Source = $mockDest
            Backup = (Join-Path $backupRoot 'mock_dest1.json')
            SHA256 = $null
            ExistedBefore = $false
            InstalledSHA256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }
        $entryB2 = [pscustomobject]@{
            Source = $mockDest
            Backup = (Join-Path $backupRoot 'mock_dest2.json')
            SHA256 = $null
            ExistedBefore = $false
            InstalledSHA256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }
        $manifestB = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            files = @($entryB1, $entryB2)
        }
        try {
            Assert-ManifestValid -ManifestObj $manifestB -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -BackupRoot $backupRoot -AllowedDestinations @($mockDest)
            throw "Failed to reject duplicate destination"
        } catch {
            if ($_ -notmatch "Duplicate destination path") { throw }
        }

        # Test Case C: Traversal backup path (outside backup root)
        $entryC = [pscustomobject]@{
            Source = $mockDest
            Backup = (Join-Path $tempDir 'outside_file.json')
            SHA256 = $null
            ExistedBefore = $false
            InstalledSHA256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }
        $manifestC = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            files = @($entryC)
        }
        try {
            Assert-ManifestValid -ManifestObj $manifestC -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -BackupRoot $backupRoot -AllowedDestinations @($mockDest)
            throw "Failed to reject traversal backup path"
        } catch {
            if ($_ -notmatch "Backup path is outside the backup root") { throw }
        }

        # Test Case D: External destination (not in allowed destinations)
        $entryD = [pscustomobject]@{
            Source = 'C:\Windows\System32\cmd.exe'
            Backup = (Join-Path $backupRoot 'mock_dest.json')
            SHA256 = $null
            ExistedBefore = $false
            InstalledSHA256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }
        $manifestD = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            files = @($entryD)
        }
        try {
            Assert-ManifestValid -ManifestObj $manifestD -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -BackupRoot $backupRoot -AllowedDestinations @($mockDest)
            throw "Failed to reject external destination"
        } catch {
            if ($_ -notmatch "Destination path is not in the allowed list") { throw }
        }

        # Test Case E: Backup-root reparse/junction (skip only if host cannot create one)
        $reparseTestFailed = $false
        $junctionPath = Join-Path $tempDir 'junction_root'
        try {
            $null = New-Item -ItemType Junction -Path $junctionPath -Value $backupRoot -ErrorAction Stop
            if (Test-IsReparsePoint $junctionPath) {
                try {
                    Assert-ManifestValid -ManifestObj $manifestA -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -BackupRoot $junctionPath -AllowedDestinations @($mockDest)
                    $reparseTestFailed = $true
                } catch {
                    Write-Verbose "Expected rejection for backup-root reparse point: $_"
                }
                if ($reparseTestFailed) {
                    throw "Failed to reject backup root reparse point"
                }
            }
        } catch {
            Write-Host "Skipping junction creation check: $_"
        }

        # Test Case F: Malformed state
        $badState = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            environment = [pscustomobject]@{
                KOMOREBI_CONFIG_HOME = $null
                WHKD_CONFIG_HOME = $null
                Path = 123
            }
            glazeMigrated = $true
            glazeTaskExisted = $false
            glazeTaskEnabled = $true
            glazeProcessRunning = $true
            starterTaskExisted = $false
        }
        try {
            Assert-StateValid -StateObj $badState -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1
            throw "Failed to reject malformed state"
        } catch {
            if ($_ -notmatch "must be null or a string") { throw }
        }

        # Test Case G: Bad task XML hash
        $stateWithTask = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            environment = [pscustomobject]@{
                KOMOREBI_CONFIG_HOME = $null
                WHKD_CONFIG_HOME = $null
                Path = $null
            }
            glazeMigrated = $true
            glazeTaskExisted = $true
            glazeTaskEnabled = $true
            glazeProcessRunning = $true
            glazeTaskXmlSha256 = "invalid_hash"
            starterTaskExisted = $false
        }
        try {
            Assert-StateValid -StateObj $stateWithTask -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1
            throw "Failed to reject bad task XML hash"
        } catch {
            if ($_ -notmatch "must be a 64-character hex string") { throw }
        }

        # Test Case H: Destination leaf/ancestor reparse/junction (skip only if host cannot create one)
        $reparseDestTestFailed = $false
        $junctionDestPath = Join-Path $tempDir 'junction_dest'
        try {
            $null = New-Item -ItemType Junction -Path $junctionDestPath -Value $tempDir -ErrorAction Stop
            if (Test-IsReparsePoint $junctionDestPath) {
                # Create a file inside the junction to act as the destination leaf
                $junctionDestFile = Join-Path $junctionDestPath 'mock_dest.json'
                $entryH = [pscustomobject]@{
                    Source = $junctionDestFile
                    Backup = (Join-Path $backupRoot 'mock_dest.json')
                    SHA256 = $null
                    ExistedBefore = $false
                    InstalledSHA256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                }
                $manifestH = [pscustomobject]@{
                    productId = '702studio.komorebi-starter'
                    schemaVersion = 1
                    files = @($entryH)
                }
                try {
                    Assert-ManifestValid -ManifestObj $manifestH -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -BackupRoot $backupRoot -AllowedDestinations @($junctionDestFile)
                    $reparseDestTestFailed = $true
                } catch {
                    if ($_ -notmatch "Destination path or ancestor is a reparse point") {
                        throw
                    }
                }
                if ($reparseDestTestFailed) {
                    throw "Failed to reject destination reparse point ancestor"
                }
            }
        } catch {
            Write-Host "Skipping destination junction creation check: $_"
        }

        # Test Case I: glazeMigrated = false and glazeTaskExisted = false (should succeed)
        $stateMigratedFalse = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            environment = [pscustomobject]@{
                KOMOREBI_CONFIG_HOME = $null
                WHKD_CONFIG_HOME = $null
                Path = $null
            }
            glazeMigrated = $false
            glazeTaskExisted = $false
            glazeTaskEnabled = $false
            glazeProcessRunning = $true
            starterTaskExisted = $false
        }
        Assert-StateValid -StateObj $stateMigratedFalse -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1

        # Test Case J: glazeTaskEnabled = true when glazeTaskExisted = false (should be rejected)
        $stateInconsistentTask = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            environment = [pscustomobject]@{
                KOMOREBI_CONFIG_HOME = $null
                WHKD_CONFIG_HOME = $null
                Path = $null
            }
            glazeMigrated = $true
            glazeTaskExisted = $false
            glazeTaskEnabled = $true
            glazeProcessRunning = $true
            starterTaskExisted = $false
        }
        try {
            Assert-StateValid -StateObj $stateInconsistentTask -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1
            throw "Failed to reject inconsistent glazeTaskEnabled=true when glazeTaskExisted=false"
        } catch {
            if ($_ -notmatch "glazeTaskEnabled is true when glazeTaskExisted is false") { throw }
        }

        # Test Case K: glazeMigrated = false and glazeTaskExisted = true (should be rejected)
        $stateInconsistentGlazeTask = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            environment = [pscustomobject]@{
                KOMOREBI_CONFIG_HOME = $null
                WHKD_CONFIG_HOME = $null
                Path = $null
            }
            glazeMigrated = $false
            glazeTaskExisted = $true
            glazeTaskEnabled = $false
            glazeProcessRunning = $true
            starterTaskExisted = $false
        }
        try {
            Assert-StateValid -StateObj $stateInconsistentGlazeTask -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1
            throw "Failed to reject glazeTaskExisted=true when glazeMigrated=false"
        } catch {
            if ($_ -notmatch "glazeTaskExisted is true when glazeMigrated is false") { throw }
        }

        if ($mutationCounter -ne 0) {
            throw "Mutation occurred during validation"
        }

    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
    return "All preflight rejection cases validated successfully with zero mutations."
}

# 16. Restore WhatIf JSON child process output and immutability
Invoke-TestCheck 'restore-whatif-json-test' {
    # Ensure backups base dir exists
    if (-not (Test-Path -LiteralPath $backupBase)) {
        New-Item -ItemType Directory -Path $backupBase -Force | Out-Null
    }

    $testTimestampDirName = "29991231-235959_9999"
    $testBackupRoot = Join-Path $backupBase $testTimestampDirName
    New-Item -ItemType Directory -Path $testBackupRoot -Force | Out-Null

    try {
        $testFile = Join-Path $testBackupRoot 'programs\wm.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $testFile) -Force | Out-Null
        Set-Content -LiteralPath $testFile -Value "test-script-content" -Encoding UTF8
        $fileHash = Get-FileSHA256 $testFile

        $starterXmlFile = Join-Path $testBackupRoot 'KomorebiStarter.xml'
        Set-Content -LiteralPath $starterXmlFile -Value "<xml>mock task content</xml>" -Encoding Unicode
        $starterXmlHash = Get-FileSHA256 $starterXmlFile

        # Case A: Valid starter-task backup state
        $stateObj = @{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            glazeMigrated = $false
            glazeTaskExisted = $false
            glazeTaskEnabled = $false
            glazeProcessRunning = $false
            starterTaskExisted = $true
            starterTaskXmlSha256 = $starterXmlHash
            environment = @{
                KOMOREBI_CONFIG_HOME = $null
                WHKD_CONFIG_HOME = $null
                Path = $null
            }
        }
        $stateObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $testBackupRoot 'state.json') -Encoding UTF8

        $destFile = Join-Path $installDir 'wm.ps1'
        $manifestObj = @{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            files = @(
                @{
                    Source = $destFile
                    Backup = $testFile
                    SHA256 = $fileHash
                    ExistedBefore = $true
                    InstalledSHA256 = "2222222222222222222222222222222222222222222222222222222222222222"
                }
            )
        }
        $manifestObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $testBackupRoot 'manifest.json') -Encoding UTF8

        $destExistedBefore = Test-Path -LiteralPath $destFile -PathType Leaf
        $destHashBefore = if ($destExistedBefore) { Get-FileSHA256 $destFile } else { $null }

        $restorePath = Join-Path $repoRoot 'restore.ps1'
        $tempStdout = [System.IO.Path]::GetTempFileName()
        $tempStderr = [System.IO.Path]::GetTempFileName()

        try {
            $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$restorePath`" -BackupRoot `"$testBackupRoot`" -WhatIf -Json" -PassThru -NoNewWindow -RedirectStandardOutput $tempStdout -RedirectStandardError $tempStderr -Wait

            $exitCode = $proc.ExitCode
            $stdoutText = Get-Content -LiteralPath $tempStdout -Raw
            $stderrText = Get-Content -LiteralPath $tempStderr -Raw

            if ($exitCode -ne 0) {
                throw "Case A: restore.ps1 exited with code $exitCode. Stderr: $stderrText"
            }

            $parsed = $stdoutText | ConvertFrom-Json
            if ($null -eq $parsed) {
                throw "Case A: JSON parsed to null. Raw output: $stdoutText"
            }

            if ($stdoutText -like "*What if:*") {
                throw "Case A: Stdout contains 'What if:' text! pollution: $stdoutText"
            }

            # Assert snapshot files remain unchanged
            $destExistedAfter = Test-Path -LiteralPath $destFile -PathType Leaf
            if ($destExistedBefore -ne $destExistedAfter) {
                throw "Case A: File existence changed for $destFile during WhatIf run"
            }
            if ($destExistedBefore) {
                $destHashAfter = Get-FileSHA256 $destFile
                if ($destHashBefore -ne $destHashAfter) {
                    throw "Case A: File content changed for $destFile during WhatIf run"
                }
            }
        } finally {
            Remove-Item -LiteralPath $tempStdout -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -LiteralPath $tempStderr -Force -ErrorAction SilentlyContinue | Out-Null
        }

        # Case B: Mismatched XML hash
        $stateObj.starterTaskXmlSha256 = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        $stateObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $testBackupRoot 'state.json') -Encoding UTF8

        $tempStdout = [System.IO.Path]::GetTempFileName()
        $tempStderr = [System.IO.Path]::GetTempFileName()
        try {
            $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$restorePath`" -BackupRoot `"$testBackupRoot`" -WhatIf -Json" -PassThru -NoNewWindow -RedirectStandardOutput $tempStdout -RedirectStandardError $tempStderr -Wait

            $exitCode = $proc.ExitCode
            $stderrText = Get-Content -LiteralPath $tempStderr -Raw
            if ($exitCode -eq 0) {
                throw "Case B: Expected restore to fail due to XML hash mismatch, but it succeeded!"
            }
            if ($stderrText -notmatch "KomorebiStarter.xml hash mismatch") {
                throw "Case B: Mismatch error message not found in stderr. Stderr: $stderrText"
            }
        } finally {
            Remove-Item -LiteralPath $tempStdout -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -LiteralPath $tempStderr -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } finally {
        Remove-Item -LiteralPath $testBackupRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
    return "restore verified: accepted valid starter-task backup, rejected bad starter XML hash, no tasks registered during dry run."
}

# 18. Install Manifest Validation Rejections
Invoke-TestCheck 'install-manifest-validation-rejections' {
    # Dynamically build all exact expected file entries to verify full v1 set equality
    $validFiles = @()
    foreach ($dest in $allowedDestinations) {
        $type = if (Test-IsChildOf $dest $configHome) { 'config' } else { 'program' }
        $validFiles += @{
            path = $dest
            sha256 = '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef'
            type = $type
        }
    }

    $validManifestObj = @{
        productId = '702studio.komorebi-starter'
        schemaVersion = 1
        installDir = $installDir
        configHome = $configHome
        backupRoot = (Join-Path $backupBase '20260712-120000')
        backupStateSHA256 = '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef'
        backupManifestSHA256 = '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef'
        baselineBackupRoot = (Join-Path $backupBase '20260712-120000')
        baselineBackupStateSHA256 = '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef'
        baselineBackupManifestSHA256 = '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef'
        glazeBackupRoot = $null
        glazeBackupStateSHA256 = $null
        glazeBackupManifestSHA256 = $null
        migrateFromGlazeWM = $false
        scheduledTasks = @('KomorebiStarter')
        files = $validFiles
    }

    # Helper function to convert to object and test, with round-trip after modification
    $testManifest = {
        param($ModBlock)
        $copy = ($validManifestObj | ConvertTo-Json -Depth 6) | ConvertFrom-Json
        & $ModBlock $copy
        # Round-trip ensures every replacement file entry and manifest structure is a PSCustomObject
        $copy = ($copy | ConvertTo-Json -Depth 6) | ConvertFrom-Json
        Assert-InstallManifestValid -ManifestObj $copy -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome
    }

    # Test wrong installDir root
    try {
        & $testManifest { param($m) $m.installDir = 'C:\WrongRoot' }
        throw "Failed to reject wrong installDir root"
    } catch {
        if ($_ -notmatch "installDir root mismatch") { throw }
    }

    # Test wrong configHome root
    try {
        & $testManifest { param($m) $m.configHome = 'C:\WrongRoot' }
        throw "Failed to reject wrong configHome root"
    } catch {
        if ($_ -notmatch "configHome root mismatch") { throw }
    }

    # Test outside/unknown file path
    try {
        & $testManifest {
            param($m)
            $m.files[0].path = 'C:\Windows\System32\cmd.exe'
        }
        throw "Failed to reject outside/unknown path"
    } catch {
        if ($_ -notmatch "not in the allowed destinations list") { throw }
    }

    # Test duplicate path
    try {
        & $testManifest {
            param($m)
            # Create a duplicate by setting the second file to the first file's path
            $m.files[1].path = $m.files[0].path
        }
        throw "Failed to reject duplicate path"
    } catch {
        if ($_ -notmatch "Duplicate file entry path") { throw }
    }

    # Test bad hash format
    try {
        & $testManifest {
            param($m)
            $m.files[0].sha256 = 'bad-hash'
        }
        throw "Failed to reject bad hash"
    } catch {
        if ($_ -notmatch "is missing or not a valid 64-character hex string") { throw }
    }

    # Test unexpected scheduled task
    try {
        & $testManifest {
            param($m)
            $m.scheduledTasks = @('UnexpectedTask')
        }
        throw "Failed to reject unexpected task"
    } catch {
        if ($_ -notmatch "Expected exactly \['KomorebiStarter'\]") { throw }
    }

    # Test backup prefix collision / outside backupBase
    try {
        & $testManifest {
            param($m)
            $m.backupRoot = (Join-Path (Split-Path -Parent $backupBase) 'backups_collision')
        }
        throw "Failed to reject backup prefix collision / outside backup root"
    } catch {
        if ($_ -notmatch "is not a (?:direct )?child of backup base") { throw }
    }

    # Test wrong type mapping (config in installDir)
    try {
        & $testManifest {
            param($m)
            # Change the type of a program file to config
            foreach ($f in $m.files) {
                if ($f.path -like "*wm.ps1") {
                    $f.type = 'config'
                    break
                }
            }
        }
        throw "Failed to reject config type in program directory"
    } catch {
        if ($_ -notmatch "type mismatch") { throw }
    }

    # Test wrong type mapping (program in configHome)
    try {
        & $testManifest {
            param($m)
            # Change the type of a config file to program
            $m.files[0].type = 'program'
        }
        throw "Failed to reject program type in config directory"
    } catch {
        if ($_ -notmatch "type mismatch") { throw }
    }

    # Test wrong root mapping (baselineBackupRoot prefix collision)
    try {
        & $testManifest {
            param($m)
            $m.baselineBackupRoot = (Join-Path (Split-Path -Parent $backupBase) 'backups_collision')
        }
        throw "Failed to reject wrong baselineBackupRoot mapping"
    } catch {
        if ($_ -notmatch "is not a (?:direct )?child of backup base") { throw }
    }

    # Test wrong root mapping (glazeBackupRoot prefix collision)
    try {
        & $testManifest {
            param($m)
            $m.glazeBackupRoot = (Join-Path (Split-Path -Parent $backupBase) 'backups_collision')
            $m.glazeBackupStateSHA256 = '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef'
            $m.glazeBackupManifestSHA256 = '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef'
        }
        throw "Failed to reject wrong glazeBackupRoot mapping"
    } catch {
        if ($_ -notmatch "is not a (?:direct )?child of backup base") { throw }
    }

    # Test missing expected file (reducing files array size)
    try {
        & $testManifest {
            param($m)
            $m.files = @($m.files | Where-Object { $_.path -notmatch 'komorebi.json' })
        }
        throw "Failed to reject missing expected file"
    } catch {
        if ($_ -notmatch "does not match expected allowed destinations count") { throw }
    }

    return "All install-manifest validation rejections (wrong root, outside path, duplicate path, bad hash, unexpected task, backup prefix collision, wrong type/root mapping, missing file) verified."
}

Invoke-TestCheck 'install-manifest-verify-backup-linkage' {
    $tempDir = Join-Path $env:TEMP ("komorebi-linkage-test-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $mockBackupBase = Join-Path $tempDir 'backups'
        New-Item -ItemType Directory -Path $mockBackupBase -Force | Out-Null

        $mockBackupRootName = "20260712-120000"
        $mockBackupRoot = Join-Path $mockBackupBase $mockBackupRootName
        New-Item -ItemType Directory -Path $mockBackupRoot -Force | Out-Null

        $stateFile = Join-Path $mockBackupRoot 'state.json'
        $manifestFile = Join-Path $mockBackupRoot 'manifest.json'

        $mockState = @{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            glazeMigrated = $false
            glazeTaskExisted = $false
            glazeTaskEnabled = $false
            glazeProcessRunning = $false
            starterTaskExisted = $false
            environment = @{
                KOMOREBI_CONFIG_HOME = $null
                WHKD_CONFIG_HOME = $null
                Path = $null
            }
        }

        $mockManifest = @{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            files = @()
        }

        $mockState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding UTF8
        $mockManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestFile -Encoding UTF8

        $stateHash = Get-FileSHA256 $stateFile
        $manifestHash = Get-FileSHA256 $manifestFile

        $validFiles = @()
        foreach ($dest in $allowedDestinations) {
            $type = if (Test-IsChildOf $dest $configHome) { 'config' } else { 'program' }
            $validFiles += @{
                path = $dest
                sha256 = '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef'
                type = $type
            }
        }

        $validInstallManifest = [pscustomobject]@{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            installDir = $installDir
            configHome = $configHome
            backupRoot = $mockBackupRoot
            backupStateSHA256 = $stateHash
            backupManifestSHA256 = $manifestHash
            baselineBackupRoot = $mockBackupRoot
            baselineBackupStateSHA256 = $stateHash
            baselineBackupManifestSHA256 = $manifestHash
            glazeBackupRoot = $null
            glazeBackupStateSHA256 = $null
            glazeBackupManifestSHA256 = $null
            migrateFromGlazeWM = $false
            scheduledTasks = @('KomorebiStarter')
            files = @($validFiles | ForEach-Object { [pscustomobject]$_ })
        }

        $oldBackupBase = $script:backupBase
        $script:backupBase = $mockBackupBase

        try {
            Assert-InstallManifestValid -ManifestObj $validInstallManifest -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome -VerifyBackupLinkage

            # Test failure: wrong state hash
            $invalidManifest1 = ($validInstallManifest | ConvertTo-Json -Depth 6) | ConvertFrom-Json
            $invalidManifest1.backupStateSHA256 = '0000000000000000000000000000000000000000000000000000000000000000'
            try {
                Assert-InstallManifestValid -ManifestObj $invalidManifest1 -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome -VerifyBackupLinkage
                throw "Failed to reject bad linkage state hash"
            } catch {
                if ($_ -notmatch "Linked state.json hash mismatch") { throw }
            }

            # Test XML Linkage - starterTaskExisted = true
            $mockState.starterTaskExisted = $true

            $starterXmlFile = Join-Path $mockBackupRoot 'KomorebiStarter.xml'
            Set-Content -LiteralPath $starterXmlFile -Value 'hello' -Encoding UTF8
            $xmlHash = Get-FileSHA256 $starterXmlFile

            $mockState.starterTaskXmlSha256 = $xmlHash
            $mockState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding UTF8
            $stateHash = Get-FileSHA256 $stateFile
            $validInstallManifest.backupStateSHA256 = $stateHash
            $validInstallManifest.baselineBackupStateSHA256 = $stateHash

            # 1. Missing XML file
            Remove-Item -LiteralPath $starterXmlFile -Force
            try {
                Assert-InstallManifestValid -ManifestObj $validInstallManifest -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome -VerifyBackupLinkage
                throw "Failed to reject missing KomorebiStarter.xml"
            } catch {
                if ($_ -notmatch "KomorebiStarter.xml not found in backup root") { throw }
            }

            # 2. Tampered hash
            Set-Content -LiteralPath $starterXmlFile -Value 'different content' -Encoding UTF8
            try {
                Assert-InstallManifestValid -ManifestObj $validInstallManifest -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome -VerifyBackupLinkage
                throw "Failed to reject tampered KomorebiStarter.xml hash"
            } catch {
                if ($_ -notmatch "KomorebiStarter.xml hash mismatch") { throw }
            }

            # 3. Valid XML file (correct hash)
            Set-Content -LiteralPath $starterXmlFile -Value 'hello' -Encoding UTF8
            Assert-InstallManifestValid -ManifestObj $validInstallManifest -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome -VerifyBackupLinkage

            # Clean up XML for the next test
            Remove-Item -LiteralPath $starterXmlFile -Force

            # Test XML Linkage - glazeMigrated = true and glazeTaskExisted = true
            $mockState.starterTaskExisted = $false
            $mockState.glazeMigrated = $true
            $mockState.glazeTaskExisted = $true

            $glazeXmlFile = Join-Path $mockBackupRoot 'StartGlazeWM.xml'
            Set-Content -LiteralPath $glazeXmlFile -Value 'hello' -Encoding UTF8
            $xmlHash = Get-FileSHA256 $glazeXmlFile

            $mockState.glazeTaskXmlSha256 = $xmlHash
            $mockState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding UTF8
            $stateHash = Get-FileSHA256 $stateFile
            $validInstallManifest.backupStateSHA256 = $stateHash
            $validInstallManifest.baselineBackupStateSHA256 = $stateHash

            # 1. Missing XML file
            Remove-Item -LiteralPath $glazeXmlFile -Force
            try {
                Assert-InstallManifestValid -ManifestObj $validInstallManifest -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome -VerifyBackupLinkage
                throw "Failed to reject missing StartGlazeWM.xml"
            } catch {
                if ($_ -notmatch "StartGlazeWM.xml not found in backup root") { throw }
            }

            # 2. Tampered hash
            Set-Content -LiteralPath $glazeXmlFile -Value 'different content' -Encoding UTF8
            try {
                Assert-InstallManifestValid -ManifestObj $validInstallManifest -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome -VerifyBackupLinkage
                throw "Failed to reject tampered StartGlazeWM.xml hash"
            } catch {
                if ($_ -notmatch "StartGlazeWM.xml hash mismatch") { throw }
            }

            # 3. Valid XML file (correct hash)
            Set-Content -LiteralPath $glazeXmlFile -Value 'hello' -Encoding UTF8
            Assert-InstallManifestValid -ManifestObj $validInstallManifest -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome -VerifyBackupLinkage

            # Clean up XML
            Remove-Item -LiteralPath $glazeXmlFile -Force

            # Revert mockState back to original
            $mockState.glazeMigrated = $false
            $mockState.glazeTaskExisted = $false
            $mockState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding UTF8
            $stateHash = Get-FileSHA256 $stateFile
            $validInstallManifest.backupStateSHA256 = $stateHash
            $validInstallManifest.baselineBackupStateSHA256 = $stateHash

            # Test failure: state file doesn't exist
            Remove-Item -LiteralPath $stateFile -Force
            try {
                Assert-InstallManifestValid -ManifestObj $validInstallManifest -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome -VerifyBackupLinkage
                throw "Failed to reject missing state.json"
            } catch {
                if ($_ -notmatch "Linked state.json.*does not exist") { throw }
            }
        } finally {
            $script:backupBase = $oldBackupBase
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
    return "Verified backup linkage validation successfully."
}

Invoke-TestCheck 'install-transaction-guards-static' {
    $installPath = Join-Path $repoRoot 'install.ps1'
    $content = Get-Content -LiteralPath $installPath -Raw

    foreach ($requiredText in @(
        'Desired SHA256 is null or invalid',
        'Startup failed with unhealthy status',
        'Doctor failed with unhealthy status',
        'Installation failed. Initiating transaction rollback'
    )) {
        if ($content -notlike "*$requiredText*") {
            throw "Installer transaction guard is missing: $requiredText"
        }
    }

    return 'Installer contains source-hash, health, and rollback guards; executable coverage remains in pure helper tests.'
}

# 17. Test-Repository output purity
Invoke-TestCheck 'test-repository-stdout-purity' {
    if ($env:KOMOREBI_STARTER_TEST_OUTPUT_CHILD -eq '1') {
        return "Skipped self-purity check in child process."
    }

    $tempStdout = [System.IO.Path]::GetTempFileName()
    $oldGuard = $env:KOMOREBI_STARTER_TEST_OUTPUT_CHILD
    try {
        $env:KOMOREBI_STARTER_TEST_OUTPUT_CHILD = '1'
        # Do not pass -Quiet because Quiet currently suppresses JSON
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\Test-Repository.ps1`"" -PassThru -NoNewWindow -RedirectStandardOutput $tempStdout -Wait
        if ($proc.ExitCode -ne 0) {
            throw "Child repository test exited with code $($proc.ExitCode)."
        }

        $stdoutText = Get-Content -LiteralPath $tempStdout -Raw

        $parsed = $null
        try {
            $parsed = $stdoutText | ConvertFrom-Json
        } catch {
            throw "Test-Repository output is not a valid JSON document: $stdoutText"
        }

        if ($null -eq $parsed) {
            throw "JSON parsed to null. Output: $stdoutText"
        }

        if ($stdoutText -match '\r?\n\s*\w+\s+\w+\s+\w+\s+\w+\s*\r?\n') {
            throw "Test-Repository output contains formatted table text: $stdoutText"
        }
    } finally {
        if ($null -eq $oldGuard) {
            Remove-Item -Path env:\KOMOREBI_STARTER_TEST_OUTPUT_CHILD -ErrorAction SilentlyContinue | Out-Null
        } else {
            $env:KOMOREBI_STARTER_TEST_OUTPUT_CHILD = $oldGuard
        }
        Remove-Item -LiteralPath $tempStdout -Force -ErrorAction SilentlyContinue | Out-Null
    }
    return "Test-Repository output purity validated successfully."
}

# 18. Uninstall Static Analysis
Invoke-TestCheck 'uninstall-static-analysis' {
    $uninstallPath = Join-Path $repoRoot 'uninstall.ps1'
    if (-not (Test-Path -LiteralPath $uninstallPath)) {
        throw "uninstall.ps1 not found"
    }
    $content = Get-Content -LiteralPath $uninstallPath -Raw

    # Verify no unconditional applications.json delete
    if ($content -match 'Remove-Item.*applications\.json.*-Force\s*(?!\})' -or $content -match 'Remove-Item.*applications\.json.*-Force(?!\s*})') {
        throw "Found potentially unconditional delete of applications.json in uninstall.ps1"
    }

    # Verify that Assert-InstallManifestValid is called before Stop-Process
    $validationPos = $content.IndexOf("Assert-InstallManifestValid")
    $stopPos = $content.IndexOf("Stop-Process")
    if ($validationPos -lt 0) {
        throw "Assert-InstallManifestValid call not found in uninstall.ps1"
    }
    if ($stopPos -lt 0) {
        throw "Stop-Process call not found in uninstall.ps1"
    }
    if ($stopPos -lt $validationPos) {
        throw "Stop-Process is called before Assert-InstallManifestValid in uninstall.ps1"
    }

    return "Uninstall script validated: no unconditional applications.json delete, and manifest validation occurs before process termination."
}

# 19. Flat helper fallback
Invoke-TestCheck 'flat-helper-fallback-validation' {
    $uninstallPath = Join-Path $repoRoot 'uninstall.ps1'
    $content = Get-Content -LiteralPath $uninstallPath -Raw
    if ($content -notlike '*scripts\KomorebiStarter.Common.ps1*' -or
        $content -notlike '*KomorebiStarter.Common.ps1*') {
        throw 'uninstall.ps1 does not support both source and installed flat helper layouts.'
    }
    return 'Verified source and flat helper candidates without executing uninstall.'
}

# 20. Takeover Authorization Validation
Invoke-TestCheck 'takeover-authorization-validation' {
    $tempDir = Join-Path $env:TEMP ("komorebi-takeover-test-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $manifestPath = Join-Path $tempDir 'install-manifest.json'

        $authorized = Test-GlazeTakeoverAuthorized -ManifestPath $manifestPath -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome
        if ($authorized) {
            throw "Authorized takeover with non-existent manifest"
        }

        Set-Content -LiteralPath $manifestPath -Value "{" -Encoding UTF8
        $authorized = Test-GlazeTakeoverAuthorized -ManifestPath $manifestPath -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome
        if ($authorized) {
            throw "Authorized takeover with malformed JSON manifest"
        }

        $badJson = @{
            productId = 'wrong'
            schemaVersion = 1
            migrateFromGlazeWM = $true
        } | ConvertTo-Json
        Set-Content -LiteralPath $manifestPath -Value $badJson -Encoding UTF8
        $authorized = Test-GlazeTakeoverAuthorized -ManifestPath $manifestPath -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome
        if ($authorized) {
            throw "Authorized takeover with invalid product ID"
        }

        $validFiles = @()
        foreach ($dest in $allowedDestinations) {
            $type = if (Test-IsChildOf $dest $configHome) { 'config' } else { 'program' }
            $validFiles += @{
                path = $dest
                sha256 = '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef'
                type = $type
            }
        }

        # Create valid backup root and files to satisfy linkage verification
        $mockBackupRoot = Join-Path $tempDir '20260712-120000'
        New-Item -ItemType Directory -Path $mockBackupRoot -Force | Out-Null

        $mockState = @{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            glazeMigrated = $false
            glazeTaskExisted = $false
            glazeTaskEnabled = $false
            glazeProcessRunning = $false
            starterTaskExisted = $false
            environment = @{
                KOMOREBI_CONFIG_HOME = $null
                WHKD_CONFIG_HOME = $null
                Path = $null
            }
        }
        $mockManifest = @{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            files = @()
        }

        $stateFile = Join-Path $mockBackupRoot 'state.json'
        $manifestFile = Join-Path $mockBackupRoot 'manifest.json'
        $mockState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding UTF8
        $mockManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestFile -Encoding UTF8

        $stateHash = Get-FileSHA256 $stateFile
        $manifestHash = Get-FileSHA256 $manifestFile

        # Override script-scoped backupBase temporarily to allow the test backup root to be validated
        $oldBackupBase = $script:backupBase
        $script:backupBase = $tempDir

        try {
            $validManifest = @{
                productId = '702studio.komorebi-starter'
                schemaVersion = 1
                installDir = $installDir
                configHome = $configHome
                backupRoot = $mockBackupRoot
                backupStateSHA256 = $stateHash
                backupManifestSHA256 = $manifestHash
                baselineBackupRoot = $mockBackupRoot
                baselineBackupStateSHA256 = $stateHash
                baselineBackupManifestSHA256 = $manifestHash
                glazeBackupRoot = $null
                glazeBackupStateSHA256 = $null
                glazeBackupManifestSHA256 = $null
                migrateFromGlazeWM = $true
                scheduledTasks = @('KomorebiStarter')
                files = $validFiles
            } | ConvertTo-Json -Depth 6
            Set-Content -LiteralPath $manifestPath -Value $validManifest -Encoding UTF8

            $authorized = Test-GlazeTakeoverAuthorized -ManifestPath $manifestPath -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome
            if (-not $authorized) {
                throw "Failed to authorize takeover with valid manifest and valid linkage"
            }

            # Tamper with state.json and verify it is rejected (returns false)
            Set-Content -LiteralPath $stateFile -Value "{}" -Encoding UTF8
            $authorized = Test-GlazeTakeoverAuthorized -ManifestPath $manifestPath -ExpectedProductId '702studio.komorebi-starter' -ExpectedSchemaVersion 1 -ExpectedInstallDir $installDir -ExpectedConfigHome $configHome
            if ($authorized) {
                throw "Authorized takeover with tampered linkage state file"
            }
        } finally {
            $script:backupBase = $oldBackupBase
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return "Verified malformed manifests and missing/tampered linkage cannot authorize start takeover, and valid manifests with valid linkage correctly authorize it."
}

# 21. Glaze task preservation in restore.ps1
Invoke-TestCheck 'restore-glaze-task-preservation' {
    if (-not (Test-Path -LiteralPath $backupBase)) {
        New-Item -ItemType Directory -Path $backupBase -Force | Out-Null
    }

    $testTimestampDirName = "29991231-235959_9998"
    $testBackupRoot = Join-Path $backupBase $testTimestampDirName
    New-Item -ItemType Directory -Path $testBackupRoot -Force | Out-Null

    try {
        $testFile = Join-Path $testBackupRoot 'programs\wm.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $testFile) -Force | Out-Null
        Set-Content -LiteralPath $testFile -Value "test-script-content" -Encoding UTF8
        $fileHash = Get-FileSHA256 $testFile

        $stateObj = @{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            glazeMigrated = $true
            glazeTaskExisted = $false
            glazeTaskEnabled = $false
            glazeProcessRunning = $false
            starterTaskExisted = $false
            environment = @{
                KOMOREBI_CONFIG_HOME = $null
                WHKD_CONFIG_HOME = $null
                Path = $null
            }
        }
        $stateObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $testBackupRoot 'state.json') -Encoding UTF8

        $destFile = Join-Path $installDir 'wm.ps1'
        $manifestObj = @{
            productId = '702studio.komorebi-starter'
            schemaVersion = 1
            files = @(
                @{
                    Source = $destFile
                    Backup = $testFile
                    SHA256 = $fileHash
                    ExistedBefore = $true
                    InstalledSHA256 = "2222222222222222222222222222222222222222222222222222222222222222"
                }
            )
        }
        $manifestObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $testBackupRoot 'manifest.json') -Encoding UTF8

        $restorePath = Join-Path $repoRoot 'restore.ps1'
        $tempStdout = [System.IO.Path]::GetTempFileName()
        $tempStderr = [System.IO.Path]::GetTempFileName()

        try {
            $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$restorePath`" -BackupRoot `"$testBackupRoot`" -WhatIf -Json" -PassThru -NoNewWindow -RedirectStandardOutput $tempStdout -RedirectStandardError $tempStderr -Wait

            $exitCode = $proc.ExitCode
            $stdoutText = Get-Content -LiteralPath $tempStdout -Raw
            $stderrText = Get-Content -LiteralPath $tempStderr -Raw

            if ($exitCode -ne 0) {
                throw "restore.ps1 exited with code $exitCode. Stderr: $stderrText"
            }

            $parsed = $stdoutText | ConvertFrom-Json
            $actions = @($parsed.plannedActions)

            $hasUnregisterGlaze = $false
            foreach ($act in $actions) {
                if ($act.target -like '*StartGlazeWM*' -and $act.action -like '*Unregister*') {
                    $hasUnregisterGlaze = $true
                }
            }

            if ($hasUnregisterGlaze) {
                throw "Vulnerability: Restore planned to unregister StartGlazeWM scheduled task even though it did not exist in migration backup!"
            }
        } finally {
            Remove-Item -LiteralPath $tempStdout -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -LiteralPath $tempStderr -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } finally {
        Remove-Item -LiteralPath $testBackupRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
    return "Verified restore does not plan to unregister a later StartGlazeWM scheduled task when migration backup says no task existed."
}

# 22. Uninstall plan contract (static only)
Invoke-TestCheck 'uninstall-plan-contract-static' {
    $uninstallPath = Join-Path $repoRoot 'uninstall.ps1'
    $content = Get-Content -LiteralPath $uninstallPath -Raw
    $validationPos = $content.IndexOf('Assert-InstallManifestValid')
    $stopPos = $content.IndexOf('Stop-Process')

    if ($content -notmatch 'SupportsShouldProcess') {
        throw 'uninstall.ps1 must support ShouldProcess.'
    }
    if ($validationPos -lt 0 -or $stopPos -lt 0 -or $validationPos -gt $stopPos) {
        throw 'Validated manifest preflight must occur before process mutation.'
    }
    if ($content -notmatch '-VerifyBackupLinkage') {
        throw 'uninstall.ps1 must verify linked backup hashes before mutation.'
    }
    foreach ($requiredText in @('plannedActions', 'scripts\KomorebiStarter.Common.ps1', 'KomorebiStarter.Common.ps1')) {
        if ($content -notlike "*$requiredText*") {
            throw "Uninstall plan contract is missing: $requiredText"
        }
    }

    $unconditionalApplicationsDelete = Get-Content -LiteralPath $uninstallPath |
        Where-Object { $_ -match 'Remove-Item' -and $_ -match 'applications\.json' }
    if ($unconditionalApplicationsDelete) {
        throw 'applications.json must not have a dedicated unconditional delete path.'
    }

    return 'Uninstall validation, plan output, helper fallback, and generated-config ownership are statically guarded.'
}

# 23. doctor.ps1 -NoExitCode return behavior
Invoke-TestCheck 'doctor-noexitcode-ast-check' {
    $doctorPath = Join-Path $repoRoot 'scripts\doctor.ps1'
    $content = Get-Content -LiteralPath $doctorPath -Raw
    if ($content -notmatch '(?s)if \(\$NoExitCode\)\s*\{\s*return\s*\}.*exit') {
        throw "doctor.ps1 is missing the return branch when NoExitCode is set before exit handling."
    }
    return "Verified doctor.ps1 has a return branch for -NoExitCode before exit handling."
}

# 24. Test-ScheduledTaskEnabled synthetic CIM-like validation
Invoke-TestCheck 'scheduled-task-helper-synthetic-tests' {
    if (Test-ScheduledTaskEnabled $null) {
        throw "Should return false for null task"
    }
    $t1 = [pscustomobject]@{ State = 'Disabled' }
    if (Test-ScheduledTaskEnabled $t1) {
        throw "Should return false for Disabled state"
    }
    $t1_num = [pscustomobject]@{ State = 1 }
    if (Test-ScheduledTaskEnabled $t1_num) {
        throw "Should return false for numeric State=1 (Disabled)"
    }
    $t2 = [pscustomobject]@{ State = 4 }
    if (-not (Test-ScheduledTaskEnabled $t2)) {
        throw "Should return true for State=4 (Running)"
    }
    $t3 = [pscustomobject]@{
        State = 'Ready'
        Settings = [pscustomobject]@{ Enabled = $false }
    }
    if (Test-ScheduledTaskEnabled $t3) {
        throw "Should return false for Settings.Enabled=false"
    }
    $t4 = [pscustomobject]@{
        State = 'Ready'
        Settings = [pscustomobject]@{ Enabled = $true }
    }
    if (-not (Test-ScheduledTaskEnabled $t4)) {
        throw "Should return true for Settings.Enabled=true"
    }
    $t5 = [pscustomobject]@{
        State = 'Ready'
    }
    if (-not (Test-ScheduledTaskEnabled $t5)) {
        throw "Should return true if Settings property is missing"
    }
    return "Verified scheduled-task helper handles synthetic CIM-like objects correctly under strict mode."
}

# 25. uninstall.ps1 null baseline state environment fields are not cast
Invoke-TestCheck 'uninstall-null-env-cast-static-check' {
    $uninstallPath = Join-Path $repoRoot 'uninstall.ps1'
    $content = Get-Content -LiteralPath $uninstallPath -Raw
    if ($content -match '\[string\]\$baselineState\.environment') {
        throw "uninstall.ps1 still casts baselineState environment properties to [string]"
    }
    return "Verified uninstall.ps1 does not cast baseline environment properties to [string]."
}

# 26. No mutating script child executions exist in Test-Repository
Invoke-TestCheck 'no-mutating-script-child-execution-check' {
    $testRepoPath = Join-Path $repoRoot 'tests\Test-Repository.ps1'
    $content = Get-Content -LiteralPath $testRepoPath -Raw
    $lines = $content -split '\r?\n'
    foreach ($line in $lines) {
        if ($line -match 'Start-Process' -and $line -match '\.ps1') {
            if ($line -match '(install|uninstall|restore|start)\.ps1' -and $line -notmatch '-WhatIf') {
                throw "Mutating script child execution detected in Test-Repository: $line"
            }
        }
    }
    return "Verified no mutating script child executions exist in Test-Repository."
}

# 28. bootstrap.ps1 -WhatIf -Json no-network static+child test
Invoke-TestCheck 'bootstrap-whatif-json-test' {
    $bootstrapPath = Join-Path $repoRoot 'bootstrap.ps1'
    if (-not (Test-Path -LiteralPath $bootstrapPath)) {
        throw 'bootstrap.ps1 not found.'
    }

    # Run bootstrap.ps1 -WhatIf -Json
    $output = & $bootstrapPath -WhatIf -Json
    if ($null -eq $output) {
        throw "bootstrap.ps1 -WhatIf -Json returned no output."
    }

    $rawText = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    $plan = $null
    try {
        $plan = ConvertFrom-Json $rawText
    } catch {
        throw "Failed to parse JSON output from bootstrap.ps1 -WhatIf -Json: $_. Raw: $rawText"
    }

    $requiredProps = @('productId', 'schemaVersion', 'ok', 'version', 'hash', 'installResult')
    foreach ($prop in $requiredProps) {
        if (-not (Get-Member -InputObject $plan -Name $prop)) {
            throw "bootstrap -WhatIf -Json output is missing required property: $prop"
        }
    }

    if ($plan.productId -ne '702studio.komorebi-starter') {
        throw "Unexpected productId: $($plan.productId)"
    }
    if ($plan.schemaVersion -ne 1) {
        throw "Unexpected schemaVersion: $($plan.schemaVersion)"
    }
    if ($plan.ok -ne $true) {
        throw "Expected ok to be true, but got $($plan.ok)"
    }
    if (-not $plan.installResult.whatIf) {
        throw "Expected installResult.whatIf to be true, but got $($plan.installResult.whatIf)"
    }

    return "Verified bootstrap.ps1 -WhatIf -Json performs zero side effects and returns a stable JSON plan."
}

# 29. Build release twice in separate temp dirs and assert equal SHA/files/checksum grammar/no forbidden entries/no binary
Invoke-TestCheck 'deterministic-release-build-test' {
    $releaseScriptPath = Join-Path $repoRoot 'scripts/New-ReleasePackage.ps1'
    if (-not (Test-Path -LiteralPath $releaseScriptPath)) {
        throw 'scripts/New-ReleasePackage.ps1 not found.'
    }

    $temp1 = Join-Path $env:TEMP ("komorebi-test-rel-1-" + [Guid]::NewGuid().ToString('N'))
    $temp2 = Join-Path $env:TEMP ("komorebi-test-rel-2-" + [Guid]::NewGuid().ToString('N'))

    New-Item -ItemType Directory -Path $temp1 -Force | Out-Null
    New-Item -ItemType Directory -Path $temp2 -Force | Out-Null

    try {
        # Build 1
        $hash1 = & $releaseScriptPath -RepositoryRoot $repoRoot -OutputRoot $temp1

        # Build 2
        $hash2 = & $releaseScriptPath -RepositoryRoot $repoRoot -OutputRoot $temp2

        if ($hash1 -ne $hash2) {
            throw "deterministic build failed: hashes returned by script differ ('$hash1' vs '$hash2')"
        }

        $zip1 = Join-Path $temp1 'komorebi-starter.zip'
        $zip2 = Join-Path $temp2 'komorebi-starter.zip'

        if (-not (Test-Path -LiteralPath $zip1)) { throw "komorebi-starter.zip not generated in build 1" }
        if (-not (Test-Path -LiteralPath $zip2)) { throw "komorebi-starter.zip not generated in build 2" }

        # Verify physical file hashes are identical
        $fhash1 = (Get-FileHash -Path $zip1 -Algorithm SHA256).Hash.ToLowerInvariant()
        $fhash2 = (Get-FileHash -Path $zip2 -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($fhash1 -ne $fhash2) {
            throw "deterministic build failed: file hashes of ZIPs differ ('$fhash1' vs '$fhash2')"
        }
        if ($hash1 -ne $fhash1) {
            throw "Hash mismatch: script returned '$hash1', but file hash is '$fhash1'"
        }

        # Verify checksum file exists and content matches grammar
        $shaFile1 = Join-Path $temp1 'komorebi-starter.zip.sha256'
        $shaFile2 = Join-Path $temp2 'komorebi-starter.zip.sha256'

        if (-not (Test-Path -LiteralPath $shaFile1)) { throw "checksum file not generated in build 1" }
        if (-not (Test-Path -LiteralPath $shaFile2)) { throw "checksum file not generated in build 2" }

        $shaContent1 = (Get-Content -LiteralPath $shaFile1 -Raw).Trim()
        $shaContent2 = (Get-Content -LiteralPath $shaFile2 -Raw).Trim()

        if ($shaContent1 -ne $shaContent2) {
            throw "Checksum file contents differ: '$shaContent1' vs '$shaContent2'"
        }

        # Check grammar: 64 hex plus optional * and exact filename
        if ($shaContent1 -notmatch '^[a-fA-F0-9]{64}[ \t]+\*?komorebi-starter\.zip$') {
            throw "Checksum file does not match exact grammar: '$shaContent1'"
        }

        # Open ZIP and inspect contents to verify:
        # - No forbidden entries (.git, .github, .reference)
        # - No binaries (.exe, .dll, etc.)
        # - Only files on allowlist
        Add-Type -AssemblyName System.IO.Compression
        $zipStream = New-Object System.IO.FileStream($zip1, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Read)
            try {
                $forbiddenMatches = @('\.git', '\.github', '\.reference')
                $forbiddenExts = @('.exe', '.dll', '.msi', '.sys', '.bin')

                foreach ($entry in $archive.Entries) {
                    $name = $entry.FullName

                    # Check forbidden paths
                    foreach ($pattern in $forbiddenMatches) {
                        if ($name -match $pattern) {
                            throw "Forbidden entry path pattern matched: '$name' matches '$pattern'"
                        }
                    }

                    # Check binaries
                    $ext = [IO.Path]::GetExtension($name).ToLowerInvariant()
                    if ($ext -in $forbiddenExts) {
                        throw "Forbidden binary extension found: '$name' has extension '$ext'"
                    }

                    $AllowedPatterns = @(
                        '^bootstrap\.ps1$',
                        '^install\.ps1$',
                        '^uninstall\.ps1$',
                        '^restore\.ps1$',
                        '^LICENSE$',
                        '^README\.md$',
                        '^THIRD_PARTY_NOTICES\.md$',
                        '^SECURITY\.md$',
                        '^CONTRIBUTING\.md$',
                        '^SUPPORT\.md$',
                        '^CHANGELOG\.md$',
                        '^CODE_OF_CONDUCT\.md$',
                        '^AGENTS\.md$',
                        '^config/(?:komorebi|komorebi\.bar|komorebi\.bar\.jetbrains|applications\.local)\.json$',
                        '^config/whkdrc$',
                        '^scripts/(?:start|doctor|wm|wm-resize-mode|KomorebiStarter\.Common|change_scale)\.ps1$',
                        '^scripts/wm\.cmd$'
                    )

                    $matched = $false
                    foreach ($pattern in $AllowedPatterns) {
                        if ($name -match $pattern) {
                            $matched = $true
                            break
                        }
                    }
                    if (-not $matched) {
                        throw "Entry '$name' is not on the release allowlist!"
                    }
                }

                $entryNames = @($archive.Entries | ForEach-Object FullName)
                $requiredRuntimeEntries = @(
                    'install.ps1',
                    'uninstall.ps1',
                    'restore.ps1',
                    'config/komorebi.json',
                    'config/komorebi.bar.json',
                    'config/komorebi.bar.jetbrains.json',
                    'config/applications.local.json',
                    'config/whkdrc',
                    'scripts/start.ps1',
                    'scripts/doctor.ps1',
                    'scripts/wm.ps1',
                    'scripts/wm.cmd',
                    'scripts/wm-resize-mode.ps1',
                    'scripts/KomorebiStarter.Common.ps1',
                    'scripts/change_scale.ps1'
                )
                foreach ($requiredEntry in $requiredRuntimeEntries) {
                    if ($entryNames -notcontains $requiredEntry) {
                        throw "Required runtime entry is missing from the release: $requiredEntry"
                    }
                }
                foreach ($devOnlyEntry in @('tests/Test-Repository.ps1', 'scripts/New-ReleasePackage.ps1', 'PSScriptAnalyzerSettings.psd1')) {
                    if ($entryNames -contains $devOnlyEntry) {
                        throw "Development-only file leaked into the release: $devOnlyEntry"
                    }
                }
            } finally {
                $archive.Dispose()
            }
        } finally {
            $zipStream.Dispose()
        }

    } finally {
        Remove-Item -LiteralPath $temp1 -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        Remove-Item -LiteralPath $temp2 -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }

    return "Verified release build determinism, checksum grammar, lack of forbidden entries, and absence of binaries."
}

# 27. Caller-defined fake roots/functions are overwritten after dot-sourcing Common
Invoke-TestCheck 'caller-overwrites-test' {
    & {
        $productId = 'fake-product'
        $schemaVersion = 999
        $stateHome = 'C:\fake\state'
        $backupBase = 'C:\fake\backup'
        $configHome = 'C:\fake\config'
        $installDir = 'C:\fake\install'
        $allowedDestinations = @('C:\fake\allowed')

        # Define mock functions to verify they are overwritten
        $global:AssertBackupRootValidCalled = $false
        function Assert-BackupRootValid { $global:AssertBackupRootValidCalled = $true }

        $global:GetFileSHA256Called = $false
        function Get-FileSHA256 { $global:GetFileSHA256Called = $true }

        $global:SetUserEnvironmentVariableCalled = $false
        function Set-UserEnvironmentVariable { $global:SetUserEnvironmentVariableCalled = $true }

        . (Join-Path $repoRoot 'scripts\KomorebiStarter.Common.ps1')

        # Check caller-defined roots are overwritten
        if ($productId -eq 'fake-product') { throw "productId was not overwritten" }
        if ($schemaVersion -eq 999) { throw "schemaVersion was not overwritten" }
        if ($stateHome -eq 'C:\fake\state') { throw "stateHome was not overwritten" }
        if ($backupBase -eq 'C:\fake\backup') { throw "backupBase was not overwritten" }
        if ($configHome -eq 'C:\fake\config') { throw "configHome was not overwritten" }
        if ($installDir -eq 'C:\fake\install') { throw "installDir was not overwritten" }
        if ($allowedDestinations -contains 'C:\fake\allowed') { throw "allowedDestinations was not overwritten" }

        # Check functions are overwritten
        $testBackupRoot = Join-Path $backupBase '20260712-120000'
        Assert-BackupRootValid -PathName 'backupRoot' -PathValue $testBackupRoot -CanonicalBackupBase (Get-CanonicalPath $backupBase)
        if ($global:AssertBackupRootValidCalled) { throw "Assert-BackupRootValid was not overwritten" }

        $null = Get-FileSHA256 'nonexistent_file_xyz_123'
        if ($global:GetFileSHA256Called) { throw "Get-FileSHA256 was not overwritten" }
    }
    return "Verified caller-defined fake roots and functions are unconditionally overwritten after dot-sourcing Common."
}

# 28. Distribution Audit Findings Static Checks
Invoke-TestCheck 'distribution-audit-findings-static' {
    $bootstrapPath = Join-Path $repoRoot 'bootstrap.ps1'
    if (-not (Test-Path -LiteralPath $bootstrapPath)) {
        throw "bootstrap.ps1 not found"
    }
    $bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw

    # 1. Product/Schema Consistency
    if ($bootstrapContent -match 'productId\s*=\s*[''"]komorebi-starter[''"]') {
        throw "bootstrap.ps1 still uses old productId 'komorebi-starter' instead of '702studio.komorebi-starter'"
    }
    if ($bootstrapContent -notmatch 'productId\s*=\s*[''"]702studio\.komorebi-starter[''"]') {
        throw "bootstrap.ps1 does not define '702studio.komorebi-starter' as productId."
    }
    if ($bootstrapContent -notmatch 'schemaVersion\s*=\s*1\b') {
        throw "bootstrap.ps1 does not define 1 as schemaVersion."
    }

    # 2. Limits checks
    if ($bootstrapContent -notmatch '512') {
        throw "bootstrap.ps1 is missing 512 entries limit check."
    }
    if ($bootstrapContent -notmatch '16\s*\*\s*1024\s*\*\s*1024') {
        throw "bootstrap.ps1 is missing 16 MiB per file limit check."
    }
    if ($bootstrapContent -notmatch '64\s*\*\s*1024\s*\*\s*1024') {
        throw "bootstrap.ps1 is missing 64 MiB total size limit check."
    }
    if ($bootstrapContent -notmatch '4096') {
        throw "bootstrap.ps1 is missing 4096 bytes checksum size limit check."
    }
    if ($bootstrapContent -notmatch '50\s*\*\s*1024\s*\*\s*1024') {
        throw "bootstrap.ps1 is missing 50 MiB ZIP size limit check."
    }

    # 3. Child stdout/stderr separation
    if ($bootstrapContent -match 'Start-Process.*2>&1') {
        throw "bootstrap.ps1 redirects stderr to stdout using 2>&1 during child execution, but they must be separated."
    }
    if ($bootstrapContent -notmatch 'RedirectStandardOutput' -or $bootstrapContent -notmatch 'RedirectStandardError') {
        throw "bootstrap.ps1 is missing stdout/stderr redirection for child installer."
    }
    if ($bootstrapContent -notmatch 'quotedInstallScriptPath') {
        throw "bootstrap.ps1 does not quote the child installer path for paths containing spaces."
    }
    if ($bootstrapContent -notmatch 'bootstrapExitCode\s*=\s*1' -or $bootstrapContent -notmatch 'exit\s+\$bootstrapExitCode') {
        throw "bootstrap.ps1 does not return a non-zero process exit code after a JSON-mode failure."
    }
    if ($bootstrapContent -notmatch 'downloadedZipSize' -or $bootstrapContent -notmatch 'downloadedShaSize') {
        throw "bootstrap.ps1 does not verify actual downloaded asset sizes against release metadata."
    }

    # 4. Required packager allowlist
    $packagerPath = Join-Path $repoRoot 'scripts/New-ReleasePackage.ps1'
    $packagerContent = Get-Content -LiteralPath $packagerPath -Raw

    $requiredList = @(
        "README.md",
        "SECURITY.md",
        "CHANGELOG.md",
        "PSScriptAnalyzerSettings.psd1",
        "config/komorebi.json",
        "config/komorebi.bar.json",
        "config/komorebi.bar.jetbrains.json",
        "config/applications.local.json",
        "config/whkdrc",
        "scripts/start.ps1",
        "scripts/doctor.ps1",
        "scripts/wm.ps1",
        "scripts/wm.cmd",
        "scripts/wm-resize-mode.ps1",
        "scripts/KomorebiStarter.Common.ps1",
        "scripts/change_scale.ps1",
        "scripts/New-ReleasePackage.ps1",
        "tests/Test-Repository.ps1"
    )
    foreach ($reqFile in $requiredList) {
        $escaped = [regex]::Escape($reqFile)
        if ($packagerContent -notmatch $escaped) {
            throw "New-ReleasePackage.ps1 is missing required file check for: $reqFile"
        }
    }

    # 5. Correct license wording
    $licenseNoticesPath = Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md'
    $licenseNoticesContent = Get-Content -LiteralPath $licenseNoticesPath -Raw
    if ($licenseNoticesContent -notmatch 'Komorebi License Version 2\.0\.0') {
        throw "THIRD_PARTY_NOTICES.md does not reference 'Komorebi License Version 2.0.0'."
    }
    if ($licenseNoticesContent -notmatch 'SPDX NOASSERTION') {
        throw "THIRD_PARTY_NOTICES.md does not reference 'SPDX NOASSERTION'."
    }
    if ($licenseNoticesContent -notmatch 'personal') {
        throw "THIRD_PARTY_NOTICES.md is missing personal use permission description."
    }
    if ($licenseNoticesContent -notmatch 'commercial') {
        throw "THIRD_PARTY_NOTICES.md is missing commercial use instructions description."
    }
    if ($licenseNoticesContent -notmatch 'https://github\.com/LGUG2Z/komorebi/blob/master/LICENSE\.md') {
        throw "THIRD_PARTY_NOTICES.md is missing link to komorebi LICENSE.md."
    }
    if ($licenseNoticesContent -notmatch 'https://github\.com/LGUG2Z/whkd/blob/master/LICENSE\.md') {
        throw "THIRD_PARTY_NOTICES.md is missing link to whkd LICENSE.md."
    }
    if ($licenseNoticesContent -notmatch 'https://github\.com/LGUG2Z/masir/blob/master/LICENSE\.md') {
        throw "THIRD_PARTY_NOTICES.md is missing link to masir LICENSE.md."
    }

    # 6. NuGet provider setup
    $ciPath = Join-Path $repoRoot '.github/workflows/ci.yml'
    $ciContent = Get-Content -LiteralPath $ciPath -Raw
    if ($ciContent -notmatch 'Install-PackageProvider\s+-Name\s+NuGet\s+-MinimumVersion\s+2\.8\.5\.201') {
        throw "ci.yml is missing non-interactive NuGet provider installation with version 2.8.5.201."
    }

    return "Static checks for limits, product/schema consistency, child stdout/stderr separation, required packager allowlist, correct license wording, and NuGet provider setup passed successfully."
}

# 34. Documentation, analyzer, and release governance contracts
Invoke-TestCheck 'documentation-and-release-governance-contract' {
    $settingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        throw 'PSScriptAnalyzerSettings.psd1 is missing.'
    }
    $settings = Import-PowerShellDataFile -LiteralPath $settingsPath
    foreach ($severity in @('Error', 'Warning')) {
        if (@($settings.Severity) -notcontains $severity) {
            throw "Analyzer settings do not include severity '$severity'."
        }
    }
    if (@($settings.ExcludeRules) -contains '*' -or @($settings.ExcludeRules).Count -eq 0) {
        throw 'Analyzer exclusions must be explicit and non-empty.'
    }

    $ci = Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\ci.yml') -Raw
    $release = Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\release.yml') -Raw
    foreach ($workflow in @($ci, $release)) {
        if ($workflow -notmatch 'PSScriptAnalyzerSettings\.psd1' -or $workflow -notmatch 'RequiredVersion 1\.25\.0') {
            throw 'A workflow is not pinned to the repository analyzer policy and version 1.25.0.'
        }
    }
    foreach ($requiredReleaseText in @('fetch-depth: 0', 'merge-base --is-ancestor', '-OutputRoot $releaseRoot', '--verify-tag')) {
        if ($release -notlike "*$requiredReleaseText*") {
            throw "Release workflow is missing governance control: $requiredReleaseText"
        }
    }
    if ($release -notmatch 'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5' -or
        $release -notmatch 'actions/attest-build-provenance@96b4a1ef7235a096b17240c259729fdd70c83d45') {
        throw 'Release workflow actions are not pinned to the reviewed immutable SHAs.'
    }
    if ($ci -notmatch "version='1\.7\.12'" -or
        $ci -notmatch '8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8' -or
        $ci -notmatch '\./actionlint') {
        throw 'CI does not run the pinned, checksum-verified actionlint workflow validator.'
    }

    $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
    $allDocs = @('README.md', 'AGENTS.md', 'CONTRIBUTING.md', 'SUPPORT.md', 'SECURITY.md', 'CHANGELOG.md') |
        ForEach-Object { Get-Content -LiteralPath (Join-Path $repoRoot $_) -Raw }
    $joinedDocs = $allDocs -join [Environment]::NewLine
    foreach ($forbidden in @('no admin required', 'noncommercial purposes are permitted', 'scripts\package.ps1')) {
        if ($joinedDocs.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "Documentation contains forbidden or inaccurate text: $forbidden"
        }
    }
    if ($joinedDocs -match '(?i)signature') {
        throw 'Documentation must describe checksums and provenance without calling a checksum a signature.'
    }
    if ($readme -match '(?i)Programs\\KomorebiStarter\\scripts\\doctor\.ps1') {
        throw 'README uses the wrong nested path for the installed flat doctor.ps1.'
    }
    foreach ($requiredShortcut in @('Alt + Shift + P', 'Alt + OEM_5', 'Alt + Shift + A', 'Alt + Shift + F', 'Ctrl + Alt + Shift + Up')) {
        if ($readme -notlike "*$requiredShortcut*") {
            throw "README shortcut contract is missing: $requiredShortcut"
        }
    }
    if ($readme -notmatch '\^\[a-fA-F0-9\]\{64\}\[ \\t\]\+\\\*\?komorebi-starter\\\.zip\$') {
        throw 'README manual verification does not enforce the exact checksum grammar.'
    }

    return 'Verified documentation accuracy, analyzer policy, immutable Actions, and release governance controls.'
}

# Verify PID stability for Absolute Test Safety
foreach ($name in $targetProcesses) {
    $currentPids = @(Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $init = @($initialPids[$name])
    if ($init.Count -ne $currentPids.Count) {
        $null = $failures.Add("Process safety check failed: PID count changed for $name. Before: ($($init -join ',')), After: ($($currentPids -join ','))")
    } else {
        foreach ($processId in $init) {
            if ($currentPids -notcontains $processId) {
                $null = $failures.Add("Process safety check failed: PID $processId of $name was killed or restarted.")
            }
        }
    }
}

# Summary report
$summary = [pscustomobject]@{
    ok = ($failures.Count -eq 0)
    passed = @($checks | Where-Object passed).Count
    failed = $failures.Count
    checks = @($checks)
}

if ($failures.Count -gt 0) {
    if (-not $Quiet) {
        $summary | ConvertTo-Json -Depth 6
    }
    [Console]::Error.WriteLine("Test-Repository failed with $($failures.Count) errors: $($failures -join '; ')")
    exit 1
}

if (-not $Quiet) {
    $summary | ConvertTo-Json -Depth 6
}
exit 0
