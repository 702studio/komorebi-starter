# Support

## Decision Tree
1. **Fails during installation**: Verify you are running Windows 11 and Windows PowerShell 5.1. Ensure `winget` is installed and functioning.
2. **Shortcuts are not responding**: Run `& "$env:LOCALAPPDATA\Programs\KomorebiStarter\wm.ps1" status` to verify `whkd` is running.
3. **Window manager crashes or freezes**: Restart the WM (`Alt + Shift + X`). Use `komorebic log` to check for runtime errors.
4. **UI or bar issues**: Run the installed `doctor.ps1` to verify process health and configurations.

## Diagnostics
Before opening an issue, run the diagnostic tool to identify missing dependencies, configuration paths, or process issues. You can use the installed path or the repository path:

**Installed Diagnostics**
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\KomorebiStarter\doctor.ps1" -Json
```

**Repository Diagnostics**
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1 -Json
```

Additional diagnostic commands:
- `& "$env:LOCALAPPDATA\Programs\KomorebiStarter\wm.ps1" status`
- `& "$env:LOCALAPPDATA\Programs\KomorebiStarter\wm.ps1" state`
- `komorebic check`
- `komorebic --version`
- `whkd --version`
- `masir --version`

Note that `komorebic log` starts an interactive log tail rather than writing to a static file. If requested, include only a short, relevant, redacted excerpt from this command. Never invent log file paths.

## Opening an Issue
When submitting a bug report:
- Include the exact JSON output of `doctor.ps1 -Json`, relevant outputs from `wm status` and `wm state`, the `komorebic check` output, exact tool versions (`komorebic --version`, `whkd --version`, `masir --version`), and a short relevant redacted excerpt of `komorebic log`.
- **Redact secrets**: Ensure any personal paths, usernames, or sensitive data are removed from the output before uploading.
