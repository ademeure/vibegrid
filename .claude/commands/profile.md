---
description: Performance profiling workflow for VibeGrid — capture, analyze, fix, verify improvement
---

You are profiling VibeGrid performance. Follow this workflow to find and fix performance bottlenecks.

## Context

VibeGrid's known performance-sensitive areas:
- **Window inventory refresh** (`refreshWindowInventory`): AX API iteration over all windows
- **iTerm2 activity polling**: `osascript -l JavaScript` subprocess per refresh
- **Overlay z-order manipulation**: CoreGraphics SPI calls on hover
- **app.js render cycle**: pub/sub DOM re-renders with large window lists
- **AX messaging**: individual AXUIElement queries can block (configurable timeout)

## Step 1: Baseline — See and measure current state

Run these in parallel:

1. **Screenshot**: Take a screenshot to see current VibeGrid state
2. **PID**: `pgrep VibeGrid` (abort if not running — tell user to launch it)
3. **CPU sample (10s)**: `sample $(pgrep VibeGrid) 10 -file /tmp/vibegrid-profile-before.txt`
4. **Memory**: `heap $(pgrep VibeGrid) 2>&1 | head -50 > /tmp/vibegrid-heap-before.txt`
5. **Debug logs**: Read tail of `~/Library/Application Support/VibeGrid/logs/window-list-debug.log`

## Step 2: Analyze the CPU sample

Read `/tmp/vibegrid-profile-before.txt`. Focus on:

1. **Heaviest stack traces** — which functions consume the most samples?
2. **Thread distribution** — is work happening on the main thread that shouldn't be?
3. **AX API calls** — look for `AXUIElement*` functions; these are often the bottleneck
4. **osascript** — look for `NSTask`/`Process` calls indicating iTerm polling overhead
5. **WebKit** — look for `WKWebView`/`evaluateJavaScript` indicating JS bridge overhead
6. **CoreGraphics SPI** — look for `CGS*` calls indicating overlay overhead

Summarize the top 3-5 hotspots with their approximate sample percentages.

## Step 3: Analyze memory (if relevant)

Read `/tmp/vibegrid-heap-before.txt`. Look for:
- Unexpectedly large object counts
- Growing allocations that suggest leaks
- Large image/icon data caches

## Step 4: Targeted investigation

Based on the hotspots identified, read the relevant source code:

| Hotspot pattern | File to read |
|---|---|
| `AXUIElement`, `refreshWindowInventory` | `WindowManagerEngine+MoveEverything.swift` |
| `osascript`, `NSTask`, `Process` | `ITermWindowInventoryResolver.swift` |
| `CGSSetWindowLevel`, `CGSOrderWindow` | `WindowManagerEngine+Overlays.swift` |
| `evaluateJavaScript`, `WKWebView` | `UIBridge.swift`, `ControlCenterWindowController.swift` |
| `renderWindowList`, DOM operations | `app.js` (search for render functions) |
| `PlacementMath`, grid calculations | `WindowManagerEngine+Placement.swift` |

Read the code around the hot functions. Identify why they're slow.

## Step 5: Fix

Apply targeted optimizations. Common fixes:
- **Batch AX queries** instead of per-window individual calls
- **Cache** window data that hasn't changed
- **Debounce** rapid re-renders in JS
- **Move work off main thread** where safe
- **Reduce osascript frequency** or cache iTerm data
- **Minimize DOM updates** — diff before re-rendering

Keep changes minimal. Don't refactor unrelated code.

## Step 6: Verify improvement

1. **Run tests**: `swift test` to ensure nothing broke
2. **Rebuild and launch**: `make dev` (run_in_background), wait for startup
3. **Re-profile**: `sample $(pgrep VibeGrid) 10 -file /tmp/vibegrid-profile-after.txt`
4. **Compare**: Read both sample files. Quantify the improvement in the hot functions.
5. **Screenshot**: Take a screenshot to verify the app still looks and works correctly
6. **Interact**: Use computer-use to exercise the profiled code paths (e.g., open window list, hover over windows, trigger retile)

## Step 7: Report

Present a before/after comparison:
- Hot functions and their sample counts (before vs after)
- What you changed and why
- Any trade-offs (e.g., slightly stale data in exchange for responsiveness)
- Whether further optimization is warranted

## User's performance concern

$ARGUMENTS
