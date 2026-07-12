## Summary

- Describe the focused change.

Closes #

## Validation

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Repository.ps1
```

## Risk And Rollback

- Risk:
- Rollback:

## Checklist
- [ ] The diff is limited to the issue scope and preserves unrelated work.
- [ ] Changes are compatible with Windows PowerShell 5.1.
- [ ] No hardcoded personal directories, usernames, or absolute local paths are introduced.
- [ ] No precompiled third-party binaries are committed.
- [ ] `Test-Repository.ps1` and PSScriptAnalyzer pass locally.
- [ ] User-facing behavior, migration impact, and rollback are documented.
