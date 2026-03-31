---
description: Full closed-loop debug workflow for VibeGrid — see, diagnose, fix, verify
---

You are debugging a VibeGrid issue. Follow this closed-loop workflow precisely.

## Context

VibeGrid is a macOS window manager. The user has reported a bug or performance issue.
Key references:
- Engine code: `Sources/VibeGrid/Engine/`
- Web UI: `Sources/VibeGrid/Resources/web/app.js`
- Debug logs: `~/Library/Application Support/VibeGrid/logs/window-list-debug.log`
- Config: `~/Library/Application Support/VibeGrid/config.yaml`
- Tests: `Tests/VibeGridTests/`

## Step 1: Observe — See what's happening

Take a screenshot to see the current state of VibeGrid on screen.

If computer-use MCP is available, use the screenshot tool.
Otherwise: `screencapture -x /tmp/vibegrid-debug.png` then Read the image.

Describe what you see. Note any visual glitches, layout issues, or unexpected state.

## Step 2: Gather diagnostics

Run these in parallel:

1. **Process info**: `pgrep -l VibeGrid` to confirm it's running, get PID
2. **Debug logs**: Read `~/Library/Application Support/VibeGrid/logs/window-list-debug.log` (tail last 100 lines)
3. **System logs**: `log show --predicate 'process == "VibeGrid"' --last 2m --style compact 2>&1 | tail -50`
4. **CPU sample** (if performance issue): `sample $(pgrep VibeGrid) 5 -file /tmp/vibegrid-sample.txt` then read the hot functions

Summarize findings. Identify the likely root cause.

## Step 3: Reproduce (if needed)

If you need to interact with VibeGrid to reproduce the issue:

- Use computer-use tools (click, type, key) to interact with the VibeGrid window
- Take screenshots before and after each interaction
- Try to isolate the exact trigger

## Step 4: Diagnose — Read the relevant code

Based on findings from steps 1-3, read the relevant source files:

- **Window list issues**: `WindowManagerEngine+MoveEverything.swift`
- **Placement/tiling issues**: `WindowManagerEngine+Placement.swift`, `MoveEverythingRetileLayout.swift`
- **Hotkey issues**: `WindowManagerEngine+Keyboard.swift`, `HotKeyManager.swift`
- **AX/focus issues**: `WindowManagerEngine+Accessibility.swift`
- **UI rendering issues**: `app.js`, `styles.css`
- **Overlay issues**: `WindowManagerEngine+Overlays.swift`, `PlacementPreviewOverlayController.swift`
- **Config issues**: `ConfigStore.swift`, `Models.swift`

## Step 5: Fix

Apply the fix. Keep changes minimal and targeted.

## Step 6: Verify — Test the fix

1. **Run unit tests**: `swift test`
2. **Rebuild and relaunch**: `./scripts/run_dev.sh` (kills existing instance, builds debug .app bundle, launches it — use run_in_background). Do NOT use `make dev`; it produces a raw binary with no menu bar icon and is invisible to computer-use MCP.
3. **Wait for launch** (allow ~10s for build), then take a screenshot to verify the fix visually
4. **If performance fix**: re-run `sample` to verify the hot path is resolved
5. **Interact** with the app via computer-use to exercise the fixed behavior

## Step 7: Report

Summarize:
- What was the issue (with screenshot evidence)
- What caused it (code-level explanation)
- What you changed (files and rationale)
- How you verified it (test results, before/after screenshots or profiling data)

If the fix is not clean or has side effects, flag them explicitly.

## User's issue description

$ARGUMENTS
