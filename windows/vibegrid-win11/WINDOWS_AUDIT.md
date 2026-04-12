# VibeGrid Windows/Go Audit Report

Generated 2026-04-11. Updated 2026-04-11 after manual verification of findings.
Covers every Go file in `windows/vibegrid-win11/`.

> **Note**: Several initial audit findings were verified as false positives:
> - icons.go alpha==0: `image.NewNRGBA` zero-initializes pixels; `continue` is correct
> - tray.go GDI leak: cleanup already exists at line 463
> - tray.go double-close: single goroutine with `LockOSThread`, no race
> - hotkey ID collision: `id++` is inside success path, correct
> - getWindowText buffer: `GetWindowTextLengthW` returns 0 on error per MSDN
> - Missing `ready`/`requestState` bridge: already handled at line 1467
>
> Findings below have been verified and reflect ground truth.

## Files

| File | Lines | Purpose |
|------|-------|---------|
| `main.go` | ~2,137 | Core: Win32 thread, hotkey manager, window enumeration, config, HTTP bridge, state |
| `tray.go` | ~478 | System tray icon: class registration, message loop, context menu, icon gradient |
| `overlay.go` | ~556 | Transparent overlay windows: DIB rendering, rounded rects, async command queue |
| `icons.go` | ~245 | Icon extraction and caching: ExtractIconEx, DIB→PNG, background caching |
| `yamlconfig.go` | ~280 | YAML↔JSON bidirectional conversion with hotkey encoding/decoding |
| `yamlconfig_test.go` | ~320 | Parity tests with macOS, round-trip encoding tests |

---

## 1. Bugs

### Verified bugs (fixed)

#### main.go:326-392 — Hotkey loop crash is unrecoverable (FIXED)

If `GetMessageW` returns -1 (Win32 error), the hotkey thread exits permanently. The watchdog at main:1945+ logs warnings but never restarts the thread. Hotkeys are dead until app restart.

**Fix**: Add retry/restart logic like the tray thread has.

---

#### overlay.go:502-509 — Async overlay commands silently dropped

The command channel is buffered at 32 slots. If the overlay thread is stuck on a Win32 call, commands are dropped with no recovery guarantee. The comment claims "next update will correct the state," but no next update is guaranteed if the user stops interacting.

---

### Medium

#### main.go:174-182 — getWorkArea ignores SystemParametersInfo return value

If `SystemParametersInfoW(SPI_GETWORKAREA)` fails, a zero rect is returned, breaking all placement math.

---

#### main.go:920-960 — EnumWindows callback missing return value checks

Several Win32 calls inside the enum callback don't check return values: `GetWindowThreadProcessId`, `GetWindowLongW`, etc. A failed call could produce a zero PID or incorrect style flags.

---

#### tray.go:285-314 — Menu handle leak if appendMenuItem panics

`DestroyMenu(hMenu)` is called at the end of `showContextMenu`, but not via `defer`. If a panic occurs during menu population, the handle leaks.

**Fix**: Use `defer procDestroyMenu.Call(hMenu)`.

---

## 2. Missing Features vs. macOS

### Entire subsystems missing

| Feature | macOS status | Windows status |
|---------|-------------|---------------|
| **iTerm2 activity polling** | Full (screen capture, badges, profile tracking, tints) | Not applicable (no iTerm on Windows) |
| **Window position save/restore** | Full undo/redo stack | Not implemented |
| **Window pinning** | Pin/unpin with persistent overlays | Not implemented |
| **Advanced retile modes** | iTerm-only, non-iTerm, hybrid | Only basic retile + mini retile |
| **Show all hidden windows** | Bulk restore | Not implemented |
| **Window editor** | Dedicated popup for grid editing | Not implemented |
| **Mux session kill** | Async mux kill on window close | Not implemented |

### Bridge message types missing (18 gaps)

These `sendToNative()` calls from `app.js` are unhandled on Windows:

| Message | Impact |
|---------|--------|
| `ready` | **Critical** — frontend initialization depends on this |
| `requestState` | Frontend can't request fresh state |
| `moveEverythingSavePositions` | Position save/restore unavailable |
| `moveEverythingRestorePreviousPositions` | " |
| `moveEverythingRestoreNextPositions` | " |
| `moveEverythingUndoRetile` | No retile undo |
| `moveEverythingShowAllWindows` | Can't bulk-restore hidden windows |
| `pinMoveEverythingWindow` | No pinning |
| `unpinMoveEverythingWindow` | " |
| `moveEverythingITermRetileVisibleWindows` | N/A on Windows |
| `moveEverythingNonITermRetileVisibleWindows` | N/A on Windows |
| `moveEverythingHybridRetileVisibleWindows` | N/A on Windows |
| `saveControlCenterDefaults` | CC position not persisted |
| `resetControlCenterDefaults` | " |
| `windowEditorOpened` | No grid editor popup |
| `windowEditorClosed` | " |
| `requestYaml` | Stubbed via HTTP API instead |
| `toggleMoveEverythingMode` | Handled as no-op |

### Stub implementations (silent no-ops)

These message types are handled but do nothing (main.go:1681-1684):

- `setMoveEverythingAlwaysOnTop`
- `setMoveEverythingShowOverlays`
- `setMoveEverythingMoveToBottom`
- `setMoveEverythingDontMoveVibeGrid`
- `setMoveEverythingNarrowMode`
- `openSettings`

The UI thinks these features work but they have no effect.

### Hardcoded state in buildFullState (main.go:1434-1461)

```go
"moveEverythingActive":           true,   // Always on
"moveEverythingAlwaysOnTop":      false,  // Always off
"moveEverythingMoveToBottom":     false,  // Always off
"moveEverythingDontMoveVibeGrid": false,  // Always off
"moveEverythingShowOverlays":     false,  // Always off
```

These should track actual application state.

---

## 3. Windows API Issues

### DPI awareness missing

No call to `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`. On displays with scaling > 100%:

- `GetWindowRect` returns physical pixels
- `SystemParametersInfo(SPI_GETWORKAREA)` returns logical pixels
- Coordinate mismatch causes incorrect window placement

This is the most impactful API issue for real-world usage.

### UpdateLayeredWindow parameter fragility (overlay.go:291-315)

The function call works but passes `0` for the dirty region parameter. Some Windows versions or GPU drivers may interpret this differently.

### Missing error checks on Win32 calls

Several critical Win32 calls ignore return values:
- `SystemParametersInfoW` in `getWorkArea()` (main.go:175)
- `GetWindowThreadProcessId` in enum callback (main.go:922-960)
- `GetWindowLongW` for style flags (main.go:935)

---

## 4. Concurrency

### Goroutine lifecycle

| Goroutine | Started | Stops on shutdown? |
|-----------|---------|-------------------|
| Win32 thread | main.go:100 | No (OS kills it) |
| Hotkey loop | main.go:326 | No (no stop channel) |
| Tray loop | tray.go:176 | No (restarts on crash) |
| Overlay loop | overlay.go:419 | No (no stop channel) |
| Refresh ticker | main.go:1902 | No (no stop channel) |
| Icon extractors | icons.go:91 | Yes (fire-and-forget, terminates naturally) |

None of the long-running goroutines have graceful shutdown. This is acceptable for a tray app (OS kills everything on exit), but prevents clean testing and restart.

### Channel safety

- `overlay.go:cmdChan` — never closed; panic if read after close
- `win32Chan` (main.go:101) — 16-slot buffer; blocks callers when full (intentional backpressure)
- `tray ready` channel — double-close risk (see bug above)

### Lock discipline

`AppState.mu` (RWMutex) is used consistently via `getConfig()`/`saveConfig()`. No direct field access found. Correct.

`HotkeyManager` uses its own mutex for `hoveredWindow` and `focusedWindow`. Access patterns are correct.

`IconCache.mu` (RWMutex) with double-check locking. Benign race allows duplicate extraction work but no data corruption.

---

## 5. Architecture Differences from macOS

| Aspect | macOS | Windows |
|--------|-------|---------|
| **UI bridge** | WKWebView + native message handlers (synchronous) | HTTP server + polling (2s latency) |
| **Window management** | AXUIElement API (accessibility) | Win32 `SetWindowPos`, `ShowWindow` |
| **Hotkeys** | Carbon Events via `RegisterEventHotKey` | Win32 `RegisterHotKey` |
| **Overlays** | NSWindow with CoreGraphics drawing | Layered windows with GDI DIB sections |
| **Tray** | NSStatusItem (menu bar) | Shell_NotifyIconW (system tray) |
| **Config location** | `~/Library/Application Support/VibeGrid/` | `%APPDATA%\VibeGrid\` |
| **Process model** | Single process, main thread for UI | Multiple goroutines, Win32 thread for API calls |

The HTTP polling bridge is the biggest architectural difference. It introduces 1-2 second latency for all UI updates, making features like live hover preview and hotkey capture noticeably slower than macOS.

---

## 6. Build & Deployment

- **Go version**: 1.24+ required (go.mod)
- **Dependencies**: `gopkg.in/yaml.v3` (indirect)
- **CGO**: Not required (pure `syscall` Win32 access)
- **Cross-compilation**: Not possible (Windows-only `syscall` usage, expected)
- **Embedded assets**: `//go:embed web/*` — build must include web directory
- **No version embedding**: No `-ldflags "-X main.Version=..."` usage

---

## 7. Recommended Priorities

### P0 — Bugs causing crashes or data corruption
1. Fix division by zero in icon alpha conversion
2. Fix double-close panic on tray ready channel
3. Fix hotkey ID collision on registration failure
4. Fix GDI resource leak in tray icon creation

### P1 — Reliability
5. Add hotkey loop crash recovery (restart on GetMessageW failure)
6. Add DPI awareness for high-resolution displays
7. Add error checking for critical Win32 calls (getWorkArea, getWindowText)
8. Handle `ready` and `requestState` bridge messages

### P2 — Feature parity
9. Implement window position save/restore
10. Implement window pinning
11. Implement show-all-hidden-windows
12. Wire up MoveEverything toggle state (not hardcoded)
13. Implement stub message handlers (AlwaysOnTop, MoveToBottom, etc.)

### P3 — Architecture
14. Replace HTTP polling with WebSocket or named pipe for lower latency
15. Add graceful shutdown for goroutines
16. Add build version embedding
