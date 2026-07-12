# Contributing

## Workflow
1. **Issue**: Open an issue describing the proposed change.
2. **Branch**: Fork the repository and create a branch from `main`.
3. **Commit**: Make focused, atomic changes.
4. **Checks**: Run the required tests and formatters locally.
5. **Pull Request**: Submit a pull request referencing the issue.

## Local Checks
All contributions must pass the following checks before submission. Execute these commands in a Windows PowerShell 5.1 environment:

**Run Tests**
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Repository.ps1
```

**Run Linter**
```powershell
$results = @(Invoke-ScriptAnalyzer -Path . -Settings .\PSScriptAnalyzerSettings.psd1 -Recurse)
if ($results.Count -gt 0) {
    $results | Format-Table
    throw "PSScriptAnalyzer reported $($results.Count) issue(s)."
}
```

**Run Packaging**
To build a deterministic package archive, ensure the `OutputRoot` is set outside the repository. The process generates `komorebi-starter.zip` and its checksum (e.g. `komorebi-starter.zip.sha256`) as the expected outputs:
```powershell
$outputRoot = Join-Path $env:TEMP ('KomorebiStarter-Package-' + [guid]::NewGuid().ToString('N'))
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\New-ReleasePackage.ps1 -RepositoryRoot . -OutputRoot $outputRoot
```

## Guidelines
- Keep PowerShell scripts compatible with Windows PowerShell 5.1. Do not use PowerShell Core (`pwsh`) specific features.
- Avoid introducing third-party binaries unless strictly necessary.
- Ensure no personal paths or secrets are leaked in test data or logs.
- Never run mutating install, start, restore, or uninstall paths in repository tests. Use temporary fixtures and `-WhatIf`; do not alter live WM processes, scheduled tasks, installed files, or user configuration.
