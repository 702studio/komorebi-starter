# Focus Quality Assurance

Use this matrix before a focus-related release. Keep the pointer stationary during keyboard cases unless the case explicitly asks for mouse movement.

## Evidence Capture

Capture a baseline without changing focus:

```powershell
wm focus-health
wm state
```

`wm focus-health` omits titles and process names by default. Use the installed `focus-diagnostics.ps1 -Json -IncludeWindowMetadata` only when application identity is necessary, then redact titles and paths before sharing output.

## Acceptance Matrix

| Case | Steps | Pass criteria |
|---|---|---|
| Four-way focus command | Arrange at least four tiled windows. Run `wm focus left`, `right`, `up`, and `down` from an agent or terminal. | Each valid direction changes immediately. The final `focus-health` classification is `healthy` or `healthy-modal-redirect`. |
| Stationary mouse authority | Leave the pointer over window A. Use `wm focus <direction>` to focus window B without moving the pointer. | Window B keeps keyboard input; the stationary pointer does not return focus to A. |
| Real mouse movement | After focusing B by keyboard, physically move the pointer into A. | `masir` moves focus to A only after real relative movement. |
| Chrome keyboard input | Focus Chrome from another tile, then use `Ctrl+L`, `Ctrl+Tab`, and normal typing. | Chrome receives keyboard input without a bar click. Foreground and keyboard-focus roots in diagnostics agree with Chrome. |
| Photos to Chrome | Open an image in Windows Photos, focus another tile, then focus Chrome. | Keyboard input follows the selected tile; Photos does not retain input after the transition. |
| Native modal | Open a Save As, Open, or Preferences dialog whose owner is managed. Focus its application from another tile. | Diagnostics reports `healthy-modal-redirect`; the enabled dialog receives input, not its disabled owner. |
| Broken modal ownership | Reproduce an application with a disabled owner and no visible enabled last-active popup. | Focus fails closed with `modal-blocked-no-valid-popup`; no unrelated window is activated. |
| Parsec, immersive off | Keep Parsec windowed with keyboard immersive mode off. Focus into and away from Parsec with `wm focus <direction>`. | Focus follows the local window graph and the Parsec surface receives input when selected. |
| Parsec, immersive on | Enable Parsec keyboard immersive mode and press a local WM shortcut. | The shortcut may be sent to the host. This is classified as a Parsec input boundary, not a local focus-repair failure. |
| Parsec recovery | Use Parsec's configured immersive toggle or detach-input hotkey, then retry a configured local WM shortcut. | Local shortcuts work again. Defaults are `Ctrl+Shift+I` and `Ctrl+Alt+Z`; user settings may differ. |

## Failure Triage

1. Run `wm focus-health` before clicking another window.
2. Record the exact shortcut, pointer movement, application, modal state, and Parsec immersive state.
3. Compare `expectedRootHwnd`, `foreground.rootHwnd`, and `keyboardFocus.rootHwnd`.
4. Treat `foreground-mismatch` as a Windows activation failure and `keyboard-focus-mismatch` as diagnostic evidence, not proof that foreground activation failed.
5. Reproduce with Parsec immersive mode off before filing a local focus bug.

Windows can legally deny `SetForegroundWindow`. Komorebi Starter uses bounded retries and reports that denial; it does not inject keyboard or mouse input, move the cursor, reorder windows, or attach input queues.
