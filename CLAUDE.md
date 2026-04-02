# VibeGrid

macOS/Windows window manager for ultrawide and multi-monitor setups. Native Swift on macOS, native Go on Windows, with a shared WebKit/HTML control center UI.

## Build & Run

```bash
./scripts/run_dev.sh  # PREFERRED: build debug .app bundle, kill existing, launch — use this for all testing/debugging
make dev-app          # same as run_dev.sh but without killing existing instance first
make dev              # swift run only — NO menu bar icon, NOT visible to computer-use MCP; use only for quick CLI iteration
make build            # swift build only
make run-app          # build release .app bundle and launch it
make install-app      # install to ~/Applications
swift test            # run all tests
```

> **Important:** Always use `./scripts/run_dev.sh` (or `make dev-app`) when testing or debugging with computer-use.
> `make dev` runs as a raw binary with no `.app` bundle — macOS hides its menu bar icon and the computer-use MCP cannot see its windows.

Requires macOS 13+, Swift 5.9+, SPM. No external Swift dependencies (except swift-testing for tests).

## Architecture

- **Entry**: `AppMain.swift` — NSApplication in accessory mode (menu bar only, no dock icon)
- **AppState**: owns ConfigStore, WindowManagerEngine, ControlCenterWindowController
- **Engine** (`Engine/WindowManagerEngine*.swift`): hotkeys (Carbon Events), window placement (AX API), MoveEverything window list, overlay previews
- **UI Bridge**: WKWebView loads `Resources/web/{index.html,app.js,styles.css}`. JS↔Swift communication via `UIBridge.swift` message handlers and `evaluateJavaScript`
- **Config**: YAML-first (`~/Library/Application Support/VibeGrid/config.yaml`), custom parser in `YAML.swift`

### Key subsystems

| File | Responsibility |
|---|---|
| `WindowManagerEngine+Accessibility.swift` | AXUIElement queries, window move/resize |
| `WindowManagerEngine+Placement.swift` | Grid→pixel math, display targeting |
| `WindowManagerEngine+MoveEverything.swift` | Live window list, hover/focus/close |
| `WindowManagerEngine+Keyboard.swift` | Hotkey suspend/resume during editing |
| `HotKeyManager.swift` | Carbon Event hotkey registration |
| `UIBridge.swift` | JS↔Swift message bridge |
| `app.js` | ~3500-line pub/sub control center UI |

### Private APIs

The engine uses CoreGraphics SPI (`@_silgen_name`) for window z-order manipulation:
- `CGSMainConnectionID`, `CGSGetWindowLevel`, `CGSSetWindowLevel`, `CGSOrderWindow`

## Testing

Tests live in `Tests/VibeGridTests/`. Run with `swift test`.

- **ConfigStoreTests** — load/save/migration roundtrips
- **YAMLParityTests** — encode/decode parity with Go implementation
- **AppConfigNormalizationTests** — config validation and defaults
- **PlacementMathTests** — grid cell → pixel calculations
- **RetileLayoutTests** — auto-tiling algorithm (JSON fixtures)
- **KeyCodeMapTests** — Carbon hotkey code mapping

No UI tests currently. The app requires Accessibility permission to function.

## Debugging & Profiling

### Logs
- Debug logs: `~/Library/Application Support/VibeGrid/logs/window-list-debug.log`
- NSLog output: `log show --predicate 'process == "VibeGrid"' --last 5m`
- JS console: logged via bridge to NSLog with `[jsLog]` prefix

### Profiling (no Xcode required)
```bash
# CPU call stack sampling (10 seconds)
sample $(pgrep VibeGrid) 10 -file /tmp/vibegrid-sample.txt

# Memory snapshot
leaks $(pgrep VibeGrid) > /tmp/vibegrid-leaks.txt 2>&1
heap $(pgrep VibeGrid) > /tmp/vibegrid-heap.txt 2>&1
```

### Screenshots (requires Screen Recording permission for terminal)
```bash
screencapture -x /tmp/vibegrid-screenshot.png
```

### GUI automation
```bash
# osascript for keyboard/menu interaction
osascript -e 'tell application "System Events" to ...'

# cliclick for mouse control (brew install cliclick)
cliclick c:100,200    # click at coordinates
cliclick m:100,200    # move to coordinates
```

## Performance-Sensitive Areas

- **Window inventory refresh** (`refreshWindowInventory` in MoveEverything): iterates all windows via AX API, can be slow with many windows
- **iTerm2 activity polling**: runs `osascript -l JavaScript` subprocess per refresh cycle
- **Overlay rendering**: CoreGraphics z-order manipulation on every hover
- **app.js render cycle**: pub/sub re-renders; large DOM with many windows can be sluggish

## Slash Commands for Debugging

These are project-specific Claude Code commands in `.claude/commands/`:

- **`/debug <description>`** — Full closed-loop debug workflow: screenshot the issue, gather logs + CPU samples, read code, apply fix, rebuild, verify visually
- **`/profile <description>`** — Performance profiling: baseline with `sample`, analyze hotspots, fix, measure improvement, compare before/after
- **`/visual-test`** — Smoke test all major features via computer-use: control center, shortcut list, grid editor, window list, settings, theme

All commands that rebuild and relaunch VibeGrid must use `./scripts/run_dev.sh` (not `make dev`).

These commands assume **computer-use MCP is enabled** (`/mcp` → enable `computer-use`). Without it, screenshots fall back to `screencapture` and interactions fall back to `osascript`/`cliclick`.

## Config Location

- macOS: `~/Library/Application Support/VibeGrid/config.yaml`
- Override: `VIBEGRID_CONFIG_PATH` env var
- Activity state: `~/Library/Application Support/VibeGrid/window-list-activity.json`
