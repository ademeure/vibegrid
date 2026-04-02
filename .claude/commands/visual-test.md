---
description: Visual smoke test of VibeGrid — launch, screenshot each feature, report pass/fail
---

You are running a visual smoke test of VibeGrid. Use computer-use tools (screenshot, click, key) to exercise each major feature and verify it works.

## Prerequisites

- VibeGrid must be running as a **debug .app bundle** — NOT via `make dev` (raw binary has no menu bar icon and is invisible to computer-use MCP)
- To launch correctly: `./scripts/run_dev.sh` (kills existing instance, builds debug bundle, opens it)
- To check: `pgrep VibeGrid` — and verify "VibeGrid" appears in the menu bar status area
- Computer-use MCP must be enabled

## Setup: Request Computer-Use Access

Before any screenshot or click, call `request_access` with **all four apps** and `systemKeyCombos: true`:

```
apps: ["iTerm2", "Cursor", "Firefox", "VibeGrid"]
systemKeyCombos: true
reason: "Running visual smoke test of VibeGrid"
```

**Tier limitations** (as of 2026-03-31):
- **VibeGrid**: full access (click, type, drag)
- **iTerm2, Cursor**: click-only (no typing/right-click/drag)
- **Firefox**: read-only (visible in screenshots, no interaction)
- For shell commands, use the Bash tool directly, not iTerm2

Without requesting access to iTerm2/Cursor/Firefox, clicks near their windows will be rejected even when targeting VibeGrid.

## Test Plan

For each test, take a screenshot before and after the action. Report PASS/FAIL with the screenshot evidence.

### Test 1: Control Center opens
- Click the VibeGrid menu bar icon (or use `osascript -e 'tell application "VibeGrid" to activate'`)
- Screenshot — verify the 3-column control center UI is visible
- Check: left panel (shortcut list), center panel (editor), right panel (preview)

### Test 2: Shortcut list
- Screenshot the left panel
- Verify shortcuts are listed with names and enable/disable toggles
- Click a shortcut to select it
- Screenshot — verify the center panel updates to show that shortcut's details

### Test 3: Grid editor
- With a grid-mode shortcut selected, look at the right panel
- Screenshot — verify grid cells are displayed
- Click grid cells to modify the placement
- Screenshot — verify the selection updated

### Test 4: Window List (MoveEverything)
- Click the "Window List" button in the top bar
- Screenshot — verify the window list panel appears
- Check: windows are listed with app icons, titles, and status indicators
- Hover over a window entry
- Screenshot — verify hover state is visible

### Test 5: Settings modal
- Click the Settings (gear) button in the top bar
- Screenshot — verify the settings modal opens
- Check: theme selector, grid defaults, gap setting, launch-at-login toggle
- Close the modal (Escape or close button)

### Test 6: Hotkey recording (visual only)
- Select a shortcut in the left panel
- Click the hotkey field in the center panel
- Screenshot — verify the "recording" state is visible (field highlights or pulses)
- Press Escape to cancel recording

### Test 7: Theme
- Open settings, change theme (dark ↔ light)
- Screenshot — verify the UI re-renders with the new theme
- Change back to original theme

## Report

Summarize results as a table:

| Test | Result | Notes |
|---|---|---|
| Control Center | PASS/FAIL | ... |
| Shortcut list | PASS/FAIL | ... |
| ... | ... | ... |

Flag any failures with screenshot evidence and suspected root cause.

$ARGUMENTS
