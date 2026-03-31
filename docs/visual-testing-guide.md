# VibeGrid Visual Testing Guide

Reference for running computer-use visual smoke tests on VibeGrid's Control Center UI.

## Setup

### Prerequisites
- Computer-use MCP enabled (`/mcp` in Claude Code)
- **Exactly one VibeGrid instance running** (see below)

### Ensuring a Single VibeGrid Instance

Multiple instances cause duplicate Control Centers and confusing state. Always check before starting:

```bash
pgrep VibeGrid   # should return exactly one PID
```

If two PIDs are returned (common if both `make dev` and the installed `.app` are running):

```bash
kill $(pgrep VibeGrid)   # kill all instances
sleep 2
make dev                  # start one clean dev instance (run_in_background: true)
```

Verify only one is running:
```bash
ps aux | grep -i vibegrid | grep -v grep
# Should show exactly one process
```

### Request Access
Call `request_access` with these apps and `systemKeyCombos: true`:
```
["iTerm", "Cursor", "Firefox", "VibeGrid"]
```

**Tier limitations** (as of 2026-03-31):
- **VibeGrid**: full access (click, type, drag)
- **iTerm, Cursor**: "click" tier only (visible + left-click, NO typing/right-click/drag)
- **Firefox**: "read" tier only (visible in screenshots, no interaction)
- For shell commands, use the Bash tool directly, not iTerm

### Resizing the Control Center (CRITICAL)

The Control Center opens in **narrow/compact mode** (~160px wide, single-column window list only). To see the full 3-column layout use **osascript** — it's the most reliable method:

```bash
osascript -e 'tell application "System Events" to tell process "VibeGrid" to set size of window 1 to {1366, 768}'
osascript -e 'tell application "System Events" to tell process "VibeGrid" to set position of window 1 to {0, 25}'
```

**Why not the green zoom button?** If Moom (or another window manager) is installed, it hijacks the green button and shows a tile-picker popover instead of zooming. osascript bypasses this reliably.

**Do NOT try to drag-resize** — the drag endpoint will land on another app's bounds and get rejected by the computer-use tier system.

## UI Layout (Wide/Zoomed Mode)

```
+------------------+---------------------------+-----------------------------+
| SHORTCUTS        | SHORTCUT EDITOR           | RIGHT PANEL                 |
| (left panel)     | (center panel)            | (grid editor OR window list)|
|                  |                           |                             |
| Add / Clone /    | SHORTCUT NAME: [field]    | When editing a shortcut:    |
| Record All       | HOTKEY: [key] Record      |   STEP TITLE, DISPLAY TARGET|
|                  |   Disable / Delete        |   Grid/Freeform toggle      |
| - Left           | Cycle Sequence:           |   Cols/Rows fields          |
| - Left Copy      |   +Grid / +Freeform       |   Interactive grid cells    |
| - Right          |   H-Flip / V-Flip         |                             |
| - Right Copy     |   Step 1: Grid NxM @(x,y) | When Window List active:    |
| - Center         |   Step 2: ...             |   NAMED WINDOWS (N)         |
| - Center Copy    |                           |   VISIBLE WINDOWS (N)       |
| - Top            |                           |   HIDDEN WINDOWS (N)        |
| - Top Copy       |                           |   Each: icon, title, PID,   |
| - Bottom         |                           |     Name/Hide/Exit buttons  |
| - Bottom Copy    |                           |                             |
| - Top Left       |                           |                             |
| - Top Right      |                           |                             |
| - Bottom Left    |                           |                             |
| - Bottom Right   |                           |                             |
| - Mini Left      |                           |                             |
+------------------+---------------------------+-----------------------------+

Top bar (wide mode):
  Open YAML | Reload YAML | Load | Save | Undo | Redo | [Window List] | [Settings] | [Hide] | [Exit]
  (Window List is blue when active, Settings is yellow/orange)

Window List sub-bar:
  Retile All Windows | Mini Retile          Always On Top | Sticky | Move To Bottom
```

### Approximate Coordinates (zoomed/fullscreen)

| Element | Coordinates | Notes |
|---|---|---|
| Green zoom button | (33, 37) | Expands to full 3-column |
| Shortcut list area | x: 0-120, y: 88-640 | Left panel |
| Center editor | x: 135-740 | Shortcut details |
| Right panel | x: 755-1366 | Grid or window list |
| Open YAML button | (~1020, 63) | Top bar |
| Reload YAML button | (~1068, 63) | Top bar |
| Load button | (~1115, 63) | Top bar |
| Save button | (~1145, 63) | Top bar |
| Undo button | (~1175, 63) | Top bar |
| Redo button | (~1203, 63) | Top bar |
| Window List button | (~1243, 63) | Blue when active |
| Settings button | (~1293, 63) | Opens modal |
| Hide button | (~1333, 63) | Hides control center |
| Exit button | (~1358, 63) | Exits app |
| Record button | (~229, 120) | Hotkey recording |
| Theme dropdown | (~575, 378) | Inside Settings modal |
| Settings Done button | (~816, 611) | Closes Settings modal |

## Test Run History

### 2026-03-31 — Run 2 (Claude Code visual-test skill)

All 7 core tests **PASSED**:

| Test | Result | Notes |
|---|---|---|
| Control Center | PASS | 3-column layout after `osascript` resize. Left/center/right panels all present |
| Shortcut List | PASS | 15+ shortcuts with names, hotkeys, step counts; clicking "Right Copy" updated center panel |
| Grid Editor | PASS | 6×6 grid rendered with green selection; cell click changed step label live |
| Window List | PASS | Named (2), Visible (14), Hidden (4); hover row highlighted + purple desktop overlay |
| Settings Modal | PASS | Theme, Size, Grid defaults, Gap, Config path, Launch-at-login, Save/Reset Position, Window List Settings |
| Hotkey Recording | PASS | Record → "Press Keys..." with orange highlight confirmed |
| Theme Switch | PASS | System Default (Dark) → Light → System Default (Dark); full UI re-render on each switch |

New findings vs. Run 1:
- **Undo lost after grid cell click (BUG)** — Undo button briefly enables after a cell click then quickly disables; undo state is cleared before it can be used. See Known Issues below.
- **Hotkey recording cancel**: clicking elsewhere (name field, cycle area) does not exit "Press Keys..." state — only a 10-second timeout or an actual key press clears it
- **Setup**: osascript resize is the reliable method; green zoom button hijacked by Moom on this machine

### 2026-03-31 — Run 1 (baseline)

All 7 core tests **PASSED**:

| Test | Result | Notes |
|---|---|---|
| Control Center | PASS | 3-column layout visible after green zoom. Starts narrow by default |
| Shortcut List | PASS | 15+ shortcuts with names, hotkeys, step counts, lock/chevron icons |
| Grid Editor | PASS | 6x6 grid renders. Click modifies placement, step label updates live |
| Window List | PASS | Named/Visible/Hidden sections. Icons, process info, action buttons |
| Settings Modal | PASS | Theme, grid defaults, gap, CC size, config path, launch-at-login |
| Hotkey Recording | PASS | "Record" -> "Press Keys..." with orange highlight |
| Theme Switch | PASS | System Default (Dark) / Light / Dark. Full re-render on switch |

### Known Issues (cumulative)
- **Undo lost after grid cell click (BUG)** — After clicking a grid cell, the Undo button briefly appears enabled then quickly disables itself. The undo state is created but then immediately cleared — likely by a follow-on save or state push that flushes the undo stack. Net effect: grid cell edits cannot be undone. Use Reload YAML to discard unsaved changes instead.
- **Grid edits may auto-save** — related to above; the cell click appears to trigger a config write before Undo can be used, so Reload YAML may restore the already-modified state if done after the save fires.
- **Hotkey recording cancel** — "Press Keys..." state does not cancel on Escape or clicking elsewhere; clears only via 10-second timeout or actual key press
- **App switcher can appear** — clicking near the dock or Cmd-tabbing can trigger macOS app switcher overlay
- **Green zoom button hijacked by Moom** — use osascript resize instead (documented in Setup section above)

## Future Test Plan

### Window Management (functional)
- Trigger a hotkey and verify a window actually moves/resizes to the grid position
- Press same hotkey twice — verify cycle sequence advances to step 2
- Test Horizontal Flip / Vertical Flip on a cycle step
- Test "Retile All Windows" — verify all windows reposition according to config
- Test "Mini Retile" button
- Test "Move To Side" / "Move To Bottom" window list placement modes
- Test "Always On Top" / "Sticky" toggles on window list entries

### Shortcut CRUD
- Add new shortcut via "Add" button — verify it appears in list
- Clone an existing shortcut — verify copy is created with "(Copy)" suffix
- Delete a shortcut — verify removal from list
- Rename a shortcut — verify left panel label updates
- Disable a shortcut — verify hotkey stops working
- "Record All Hotkeys" — batch recording flow end-to-end

### Grid Editor (deeper)
- Drag across multiple cells to select a rectangular region
- Change cols/rows values — verify grid redraws with new dimensions
- Switch between Grid and Freeform placement modes
- Add multiple cycle steps via "+Grid" / "+Freeform" and reorder with arrow buttons
- Delete a step — verify removal from cycle sequence
- Test display target dropdown (multi-monitor scenarios)
- Test "Flip All" checkbox behavior

### Window List Interactions
- Click "Name" to assign a named window — verify it moves to Named section
- Click "Hide" — verify window hides and moves to Hidden section
- Click "Exit" — verify window closes (careful: irreversible)
- Click "Max" on a hidden window — verify it un-hides and maximizes
- Click "Show" on a hidden window — verify it un-hides
- Hover over a window entry — verify overlay preview appears on desktop
- Scroll the window list with 20+ windows — verify performance
- Verify iTerm session/tmux names appear correctly in window titles

### Config Management
- Open YAML, edit manually, Reload YAML — verify UI reflects changes
- Save, then Reload — verify roundtrip preserves config
- "Reveal Config in Finder" — verify Finder opens to correct path
- "Copy Config Path" — verify clipboard contains correct path
- "Reset Position & Defaults" — verify window position and settings reset
- "Save Position & Defaults" — verify window position persists across restarts

### Settings Deep Dive
- Change Control Center size (60 -> 80) — click "Apply Size" — verify UI scales
- Toggle "Larger fonts (+2pt)" — verify font size change
- Modify default grid cols/rows — verify new shortcuts use updated defaults
- Change gap (px) value — verify grid spacing updates
- Toggle "Launch VibeGrid automatically at login" — verify Login Items
- "Window List Settings" button — verify opens Window List config panel
- "Restore Defaults" — verify all settings reset

### Edge Cases
- Resize window to narrow mode — verify graceful degradation to compact layout
- Resize back to wide — verify 3-column layout restores
- Test with no visible windows (hide everything)
- Test with many windows (30+) — scroll performance and refresh speed
- Open/close Settings modal rapidly
- Toggle Window List on/off rapidly
- Theme switch while recording a hotkey
- Multiple displays: verify display target dropdown, cross-display placement

### Keyboard Navigation
- Tab through shortcut list items
- Escape to cancel recording / close modals
- Verify VibeGrid's own hotkeys work while Control Center is focused
- Test hotkey suspension: editing a text field should suspend global hotkeys

### Performance
- Window list refresh speed with 20+ windows (check `refreshWindowInventory`)
- Grid editor responsiveness with large grids (12x12)
- Theme switch rendering time
- CPU usage: idle with Control Center open vs. closed
- iTerm2 activity polling overhead (osascript subprocess per cycle)

### Accessibility
- VoiceOver reads shortcut names and button states
- Color contrast ratios in both Light and Dark themes
- Focus indicators on all interactive elements
- Screen reader labels on grid cells

## Tips for Computer-Use Testing

1. **Always zoom first** — click green button before any other interaction
2. **Use `computer_batch`** for predictable sequences (click, wait, screenshot)
3. **Reload YAML after grid edits** — undo is unreliable for grid changes
4. **Check frontmost app** — clicks are rejected if they land on a non-granted or wrong-tier app
5. **Drag limitations** — endpoint coordinate is checked against app boundaries; use zoom button instead of drag-resize
6. **Screenshot after every action** — don't assume the UI updated as expected
7. **Avoid clicking near window edges** — can hit underlying windows instead
8. **The "Press Keys..." state** may need a click elsewhere to cancel, not just Escape
